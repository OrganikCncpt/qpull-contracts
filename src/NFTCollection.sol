// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { NonRenounceableOwnable2Step } from "./utils/NonRenounceableOwnable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { IDrandOracle } from "./interfaces/IDrandOracle.sol";
import { INFTCollection } from "./interfaces/INFTCollection.sol";
import { IPassArtRenderer } from "./interfaces/IPassArtRenderer.sol";
import { IDelegateRegistry } from "./interfaces/IDelegateRegistry.sol";

/// @notice Minimal view surface of QpullTaxHook the NFT needs for the launch transfer-lock (flag-on-buy).
///         Read-only, so a call from _update can never reenter or move any NFT state.
interface ITaxHook {
    function launchTime() external view returns (uint256);
    function GATE_DURATION() external view returns (uint256);
    function earlyBuyer(address) external view returns (uint64 lastBuyAt, uint32 buys);
}

/// @title  NFTCollection, the launch NFT ("pack-rip mint")
/// @notice A MAX_SUPPLY-piece collection. Mint price is paid in ETH and AUTO-SPLIT on every mint into three
///         locked buckets: 80% LP / 10% prize seed / 10% team (spec §16). Rarity is sealed at mint
///         and revealed against a future drand round (a "pack rip"), and drives the holder's free
///         daily raffle entries. The team can never withdraw more than its 10%, because the split is
///         enforced on-chain; rarities are sealed at `finalizeLaunch()` and the buckets are pulled to their
///         purpose separately via `withdrawProceeds()` (so a bad payout recipient can never block the reveal).
/// @dev    Rarity is probabilistic (Common 70 / Uncommon 20 / Rare 8 / Super Rare 2), so final tier
///         counts are approximate, not exact, which is a fair rip. (Exact counts would need a drand-seeded
///         shuffle; flagged as an option, not built.)
/// @dev    pass-11 (launch overhaul): the mint is TIERED, TIME-BOXED and self-closing, started by ONE owner
///         action. openAllowlistMint() (requires mintOpen, recipients, a set allowlist root) stamps
///         `mintStart`; from there every window advances on the clock with NO further owner action:
///           [start, +GTD_WINDOW)                 GTD:      allowlist proof path only, cumulative cap 3
///           [+GTD, overflowEnd)                  OVERFLOW: allowlist proof path only, cumulative cap 8
///           [overflowEnd, +PUBLIC_MINT_WINDOW]   PUBLIC:   open path + proof path,    cumulative cap PUBLIC_CAP (20)
///           after that                           CLOSED by time; finalizeLaunch() permissionless.
///         `phase()` and `currentCap()` are DERIVED from time; there is no stored phase to advance, and no
///         separate openPublicMint (public activates on the clock). `mintOpen` stays the owner's kill switch.
/// @dev    pass-12: AUCTION SOFT-CLOSE. A mint in the last EXTENSION_TRIGGER() of the overflow window pushes
///         `overflowEnd` (and so the public open, close and finalize, which all derive from it) back by
///         EXTENSION_STEP(), capped at MAX_EXTENSION() beyond the nominal end. It only moves the end LATER,
///         never earlier, and the GTD boundary and the mintStart-based LAUNCH_BACKSTOP() are unaffected.
/// @dev    pass-10: LAUNCH_BACKSTOP() is the outer self-closing clock from mintStart. See `launchBackstopExpired()`.
/// @dev    preaudit: the backstop ALSO runs from `reserveAt` while the mint is unstarted (reserve-then-abandon
///         rescue, see `launchBackstopExpired()`), openAllowlistMint() asserts the soft-close invariant
///         MAX_EXTENSION() < PUBLIC_MINT_WINDOW(), and the one-shot reveal has a permissionless, time-
///         predetermined liveness fallback (`advanceRevealFallback()`) for a reveal round drand never produces.
contract NFTCollection is INFTCollection, ERC721, NonRenounceableOwnable2Step, ReentrancyGuard {
    uint8 internal constant COMMON = 0;
    uint8 internal constant UNCOMMON = 1;
    uint8 internal constant RARE = 2;
    uint8 internal constant SUPER_RARE = 3;

    /// @notice The ONLY place the collection size is written. Every other reference, in code, in comments and
    ///         downstream, must read this symbol or a formula over it: the number itself is still open and may
    ///         move before deploy. Nothing in the protocol is coupled to its value (the holder draw selects
    ///         over 1..totalMinted with a supply-independent budget), so changing it here is a one-line change.
    uint256 public constant MAX_SUPPLY = 3500;
    // pass-11: TIERED, TIME-BOXED MINT. The owner starts the mint ONCE (openAllowlistMint, stamping
    // `mintStart`); everything after is driven by elapsed time, no further owner action. Three windows:
    //   [start,               start+GTD_WINDOW())                    GTD:      allowlist only, cap GTD_CAP
    //   [start+GTD_WINDOW(),     start+GTD_WINDOW()+OVERFLOW_WINDOW())   OVERFLOW: allowlist only, cap OVERFLOW_CAP
    //   [publicOpensAt,        publicMintClosesAt)                 PUBLIC:   open to all,     cap PUBLIC_CAP
    // The per-wallet cap RISES over time and `mintedBy` is cumulative, so a wallet that took its GTD 3 can
    // reach 8 in overflow and 20 in public. All caps are immutable compile-time constants (no setter).
    uint256 public constant GTD_CAP = 3; // per-wallet cap in the GTD window
    uint256 public constant OVERFLOW_CAP = 8; // cumulative per-wallet cap in the overflow window (GTD 3 + 5)
    uint256 public constant PUBLIC_CAP = 20; // cumulative per-wallet cap in the public window (overflow 8 + 12 more)
    uint256 public constant RESERVE_CAP = 25; // max passes the owner can pre-mint to the treasury (see reserveMint)
    // The three window lengths and the backstop are VIRTUAL getters, not constants, exactly like the engines'
    // cadence (see TestnetShortClock): they return the real mainnet durations here and are overridden ONLY by
    // the never-mainnet testnet subclass so the full tiered flow can be walked in minutes. A mainnet deploy
    // uses this base contract, so the durations are as trustless as a constant (no setter, redeploy to change).
    function GTD_WINDOW() public view virtual returns (uint256) { return 6 hours; } // guaranteed allowlist window
    function OVERFLOW_WINDOW() public view virtual returns (uint256) { return 18 hours; } // allowlist top-up (ends +24h)
    function PUBLIC_MINT_WINDOW() public view virtual returns (uint256) { return 24 hours; } // NOMINAL open window
    // The TOTAL mint always ends at mintStart + GTD + OVERFLOW + PUBLIC (a FIXED, announceable instant). The
    // auction soft-close moves the overflow->public boundary (`overflowEnd`) later WITHIN that fixed envelope,
    // so a late overflow mint shortens the public window rather than extending the end: public runs from
    // `overflowEnd` to the fixed close, i.e. PUBLIC_MINT_WINDOW() minus however much overflow soft-closed.
    /// @notice pass-10: the OUTER self-closing clock, measured from `mintStart`. Covers the case the public
    ///         window cannot: an owner who starts the mint and then vanishes. At this boundary every mint path
    ///         hard-closes and finalizeLaunch() goes permissionless, so a stranger can always rescue the
    ///         protocol. 30 days >> the ~50h GTD+overflow+public span, so it never binds in an honest launch.
    function LAUNCH_BACKSTOP() public view virtual returns (uint256) { return 30 days; }
    // pass-12: AUCTION SOFT-CLOSE on the overflow window. A mint in the last EXTENSION_TRIGGER() of overflow
    // pushes the overflow end (and so the public open, close, and finalize) back by EXTENSION_STEP(), up to a
    // hard cap of MAX_EXTENSION() beyond the nominal end. Inert on a normal mint; only bites under sustained
    // allowlist demand at the boundary. Virtual like the windows, so the testnet subclass runs them short.
    function EXTENSION_TRIGGER() public view virtual returns (uint256) { return 10 minutes; } // late-mint trigger
    function EXTENSION_STEP() public view virtual returns (uint256) { return 5 minutes; } // push per triggering mint
    function MAX_EXTENSION() public view virtual returns (uint256) { return 6 hours; } // hard cap over nominal end (borrows from public)
    // preaudit: REVEAL LIVENESS FALLBACK cadence. If the bound reveal round is never producible (drand skipped
    // it), `advanceRevealFallback()` may re-bind to a round PREDETERMINED by this step from `revealBoundAt`,
    // one rung per elapsed step. Long by design: the honest path (keeper or anyone posts the beacon) has a
    // whole week per rung, and the fallback can never touch a round whose beacon has landed. Virtual like the
    // windows, so the testnet subclass can run it short.
    function REVEAL_FALLBACK_STEP() public view virtual returns (uint256) { return 7 days; }
    uint256 internal constant BPS = 10_000;
    uint256 public constant LP_BPS = 8000; // 80%
    uint256 public constant SEED_BPS = 1000; // 10%
    // team = remainder (10%)

    uint256 public immutable mintPrice;
    IDrandOracle public immutable drand;
    uint256 public immutable revealDelay;
    // Fully on-chain art (SSTORE2). Immutable: the reveal display can never be changed or forgotten (no
    // setBaseURI). tokenURI delegates here; the flip from sealed to tier art is driven by rarityOf (below).
    IPassArtRenderer public immutable renderer;

    /// @notice Passes minted so far. Ids are handed out SEQUENTIALLY from 1 and are never burned by this
    ///         contract, so the minted set is exactly 1..totalMinted, and it is frozen the moment `launched`
    ///         flips (every mint path checks that flag). HolderDrawEngine relies on both facts: it draws
    ///         uniformly over 1..totalMinted and can therefore never select an id that was never minted.
    uint256 public totalMinted;
    /// @notice Unix time this pass last changed hands. The mint counts as a change; a self-transfer does not.
    ///         Read by HolderDrawEngine: a pass that moved after a week's freeze instant is out of that week.
    mapping(uint256 => uint64) public ownerSince;
    /// @notice The holder-draw eligibility threshold: a wallet must hold at least this many passes to enter
    ///         the weekly holder draw. Baked in here (not just in the engine) because THIS contract stamps
    ///         `qualifiedSince` off it; the HolderDrawEngine cross-checks its own MIN_HOLD against this.
    uint256 public constant MIN_HOLD = 4;
    /// @notice Unix time `owner`'s balance last CROSSED UP to MIN_HOLD and has stayed >= MIN_HOLD since; 0 while
    ///         below. The frozen, O(1) counterpart of a live balanceOf gate: `qualifiedSince(o) != 0 &&
    ///         qualifiedSince(o) <= freeze` proves "held >= MIN_HOLD continuously since the freeze", so a holder
    ///         cannot top up to MIN_HOLD after the settling beacon is public to sneak into that week's draw.
    ///         Monotone per streak: set on the up-crossing, cleared to 0 on the down-crossing, untouched between.
    mapping(address => uint64) public qualifiedSince;
    mapping(address => uint256) public mintedBy; // per-wallet mint count, cumulative; capped by the active tier
    uint64 public revealRound; // ONE round sealing ALL rarities, set at finalizeLaunch (quantized for BLS)
    /// @notice preaudit: Unix time the reveal was first bound (finalizeLaunch). The ONLY anchor of the reveal
    ///         fallback ladder: rung k re-binds to `drand.roundAt(revealBoundAt + k * REVEAL_FALLBACK_STEP())`,
    ///         a round fixed by this stamp and pure arithmetic, never by when anyone calls. Set once, never moves.
    uint256 public revealBoundAt;
    /// @notice preaudit: how many fallback rungs have been taken (0 = still on the finalizeLaunch round).
    uint256 public revealFallbackRung;

    uint256 public lpReserve;
    uint256 public seedReserve;
    uint256 public teamReserve;

    bool public mintOpen;
    bool public launched;

    /// @notice The delegate.xyz v2 registry, wired once (setDelegateRegistry) before the mint. Enables
    ///         `delegatedAllowlistMint`: an allowlisted wallet A can delegate a hot wallet B (on delegate.xyz,
    ///         never this site) and B mints A's allocation. Unset (0) => delegated minting is simply off.
    IDelegateRegistry public delegateRegistry;

    /// @notice The swap tax hook, wired once after it is deployed (setTaxHook). Enables the launch
    ///         transfer-lock: while the hook's launch buy-gate is open, a wallet that has made a gated buy
    ///         cannot transfer its passes out, so one pass can never be shuffled to unlock a second buying
    ///         wallet. Zero until wired; a collection with no hook set simply has no transfer-lock (fail-open).
    ITaxHook public taxHook;
    /// @notice Latched true by the first transfer after the gate window ends, so later transfers stop reading
    ///         the hook. One-way: the lock only ever loosens, never re-arms.
    bool public launchLockLifted;

    /// @notice The mint phase, DERIVED from elapsed time by `phase()` (there is no stored phase to advance).
    ///         CLOSED before the mint starts and again after it closes by time; ALLOWLIST during the GTD and
    ///         overflow windows; PUBLIC during the open window.
    enum MintPhase {
        CLOSED,
        ALLOWLIST,
        PUBLIC
    }

    /// @notice Merkle root of the community allowlist. Leaf = keccak256(abi.encodePacked(wallet)).
    bytes32 public allowlistRoot;
    /// @notice pass-11: Unix time the mint was started (openAllowlistMint), 0 before. This ONE stamp drives
    ///         every window, cap, the derived public deadline, and the LAUNCH_BACKSTOP(). It is set once and
    ///         never moves, so no owner action can extend or rewind any window.
    uint256 public mintStart;
    /// @notice pass-12: the CURRENT end of the overflow (allowlist) window, i.e. when the public window opens.
    ///         Initialized at start to mintStart + GTD_WINDOW() + OVERFLOW_WINDOW() and pushed later by the
    ///         auction soft-close (never earlier, never past the MAX_EXTENSION() cap). 0 before the mint starts.
    ///         Every public-side time (publicOpensAt / publicMintClosesAt / finalize) derives from THIS, so a
    ///         late-overflow mint delays public. mintStart and the LAUNCH_BACKSTOP are unaffected.
    uint256 public overflowEnd;

    address public lpTreasury; // receives LP ETH (should be a locker, for trustlessness)
    address public seedTreasury; // receives seed ETH → buys QUOTRON → seeds the vaults
    address public team;

    bool public reserveMinted; // pass-13: one-shot latch, true once the owner has taken the treasury reserve
    /// @notice preaudit: Unix time the treasury reserve was taken (reserveMint), 0 if never. Arms the
    ///         LAUNCH_BACKSTOP() for a collection that minted its reserve but never opened (see
    ///         `launchBackstopExpired()`), the one state where real tokens exist with no rescue clock running.
    uint256 public reserveAt;

    event MintOpenSet(bool open);
    event TaxHookSet(address hook);
    event DelegateRegistrySet(address registry);
    event DelegatedMint(address indexed vault, address indexed delegate, uint256 qty);
    event RecipientsSet(address lpTreasury, address seedTreasury, address team);
    event Minted(uint256 indexed tokenId, address indexed to);
    event Launched(uint256 lp, uint256 seed, uint256 team);
    event AllowlistRootSet(bytes32 root);
    event MintStarted(uint256 mintStart); // pass-11: the one-shot start; all windows derive from this stamp
    event OverflowExtended(uint256 newOverflowEnd); // pass-12: auction soft-close pushed the overflow end
    event ReserveMinted(address indexed to, uint256 qty); // pass-13: owner treasury reserve (ids 1..qty)
    /// @notice preaudit: the reveal fallback re-bound the collection from `fromRound` (never produced) to
    ///         `toRound` = drand.roundAt(`rungTime`), the round predetermined for `rung`.
    event RevealFallbackAdvanced(uint256 indexed rung, uint64 fromRound, uint64 toRound, uint256 rungTime);

    error MintClosed();
    error SoldOut();
    error WalletLimit();
    error BadPrice();
    error AlreadyLaunched();
    error AlreadyMinting();
    error RecipientsUnset();
    error NotLaunched();
    error NoToken();
    error ZeroDrand();
    error BadRevealDelay();
    error ZeroRenderer();
    error MintWindowClosed(); // pass-9/pass-10: a closed-by-time boundary passed (the 48h public window
    // or the 30d launch backstop), so every mint path is closed
    error AlreadyStarted(); // pass-11: the mint starts exactly once; mintStart never moves
    error AllowlistLocked(); // pass-9: the root is frozen the moment the mint starts
    error AllowlistRootUnset(); // pass-9: refuse to open a merkle-gated phase nobody could ever pass
    error NotAllowlisted(); // pass-9: proof does not put msg.sender in allowlistRoot
    error HookAlreadySet(); // setTaxHook is write-once
    error PassLockedDuringLaunch(); // a launch buyer's pass can't transfer while the hook's gate window is open
    error RegistryAlreadySet(); // setDelegateRegistry is write-once
    error DelegationDisabled(); // delegatedAllowlistMint called before a registry was wired
    error NotDelegated(); // caller is not delegated by the allowlisted vault in the registry
    error ReserveLocked(); // pass-13: reserve is one-shot and only before the mint starts
    error ReserveTooLarge(); // pass-13: qty is 0 or exceeds RESERVE_CAP
    error SoftCloseEatsPublicWindow(); // preaudit: MAX_EXTENSION() >= PUBLIC_MINT_WINDOW() (mis-set subclass)
    error RevealNotBound(); // preaudit: advanceRevealFallback before finalizeLaunch bound a reveal round
    error RevealAlreadyResolved(); // preaudit: the bound round's beacon has landed; the reveal can never re-roll
    error RevealFallbackNotDue(); // preaudit: the next fallback rung's instant has not been reached yet
    error RevealDelayExceedsFallbackStep(); // preaudit: revealDelay_ >= REVEAL_FALLBACK_STEP() (rung 1 due before the reveal round)

    constructor(uint256 mintPrice_, address drand_, uint256 revealDelay_, address renderer_, address initialOwner)
        ERC721("QuoPull", "QUOPULL")
        Ownable(initialOwner)
    {
        if (mintPrice_ == 0) revert BadPrice(); // audit L-22 (pass-8): a zero price = free mint + zeroed buckets
        if (drand_ == address(0)) revert ZeroDrand(); // audit L-7
        if (revealDelay_ < 1 hours) revert BadRevealDelay(); // audit H-7: seal margin >= the engines' REVEAL_LAG
        // preaudit: the reveal round is roundAt(revealBoundAt + revealDelay) and fallback rung 1 falls due at
        // revealBoundAt + REVEAL_FALLBACK_STEP(). The rung must never be due before the original round even
        // exists, or a reveal nobody could have posted yet could be "fallen back" from. Shipped: 1h << 7d.
        // (Virtual getter: a subclass that shortens the step is held to the same rule at construction.)
        if (revealDelay_ >= REVEAL_FALLBACK_STEP()) revert RevealDelayExceedsFallbackStep();
        if (renderer_ == address(0)) revert ZeroRenderer(); // art must be wired at deploy (immutable, no setter)
        mintPrice = mintPrice_;
        drand = IDrandOracle(drand_);
        revealDelay = revealDelay_;
        renderer = IPassArtRenderer(renderer_);
    }

    // ─── config (owner, at launch) ───────────────────────────────────────────

    function setMintOpen(bool v) external onlyOwner {
        mintOpen = v;
        emit MintOpenSet(v);
    }

    function setRecipients(address lp, address seed, address team_) external onlyOwner {
        if (totalMinted > 0) revert AlreadyMinting(); // audit H-12: destinations freeze before any ETH flows
        if (lp == address(0) || seed == address(0) || team_ == address(0)) revert RecipientsUnset();
        // audit M-15 (pass-8): the three destinations must be distinct, so the 80/10/10 split can't be collapsed
        // into 100% to one owner-chosen address. (Verifying lp/seed are the locked treasuries is a runbook step.)
        if (lp == team_ || seed == team_ || lp == seed) revert RecipientsUnset();
        lpTreasury = lp;
        seedTreasury = seed;
        team = team_;
        emit RecipientsSet(lp, seed, team_);
    }

    // ─── mint phases (pass-9) ────────────────────────────────────────────────

    /// @notice Set the community allowlist root. Leaf = keccak256(abi.encodePacked(wallet)); build the tree
    ///         with OZ's sorted-pair hashing (the default in the openzeppelin/merkle-tree JS library).
    /// @dev    FROZEN once the mint starts (`AllowlistLocked`), so the owner can never swap the allowlist out
    ///         from under a live mint (the proof path stays open through PUBLIC too). Set it BEFORE
    ///         openAllowlistMint(). A single-hash leaf is safe here because the preimage is a fixed 20-byte
    ///         address, which can never collide with a 64-byte internal node.
    function setAllowlistRoot(bytes32 root) external onlyOwner {
        if (mintStart != 0) revert AllowlistLocked();
        allowlistRoot = root;
        emit AllowlistRootSet(root);
    }

    /// @notice Wire the swap tax hook once (write-once), enabling the launch transfer-lock. Call AFTER the
    ///         hook is deployed and BEFORE go-live. The hook is constructed with this NFT's address, so this
    ///         is the return leg of that wiring. A zero address or a second call reverts.
    function setTaxHook(address h) external onlyOwner {
        if (h == address(0) || address(taxHook) != address(0)) revert HookAlreadySet();
        taxHook = ITaxHook(h);
        emit TaxHookSet(h);
    }

    /// @notice Wire the delegate.xyz v2 registry once (write-once), enabling `delegatedAllowlistMint`. Set it
    ///         BEFORE the mint opens so allowlisted holders can delegate ahead of time. A zero address or a
    ///         second call reverts, so the registry can never be swapped for a malicious one mid-mint.
    function setDelegateRegistry(address r) external onlyOwner {
        if (r == address(0) || address(delegateRegistry) != address(0)) revert RegistryAlreadySet();
        delegateRegistry = IDelegateRegistry(r);
        emit DelegateRegistrySet(r);
    }

    /// @dev pass-10: the payout destinations must be frozen BEFORE the mint starts, not merely before the
    ///      first mint. openAllowlistMint stamps a clock that cannot be rewound, and a mint into unset
    ///      recipients reverts (RecipientsUnset), so starting without them burns window against a dead mint.
    function _requireRecipientsSet() internal view {
        if (lpTreasury == address(0) || seedTreasury == address(0) || team == address(0)) {
            revert RecipientsUnset();
        }
    }

    /// @notice pass-11: START THE MINT. This is the ONLY mint-lifecycle action the owner takes: it stamps
    ///         `mintStart`, and from that instant the GTD -> overflow -> public windows advance purely by time
    ///         (see the tier constants). There is no separate openPublicMint(): public activates on the clock.
    /// @dev    REQUIRES mintOpen == true, because this call starts every timed window at once. If it could run
    ///         against a paused mint, the GTD and overflow windows would burn in real time while nobody could
    ///         mint. The owner may still pause mid-mint with setMintOpen(false) (a kill switch that shortens
    ///         the usable window, never extends any deadline). Requires recipients and a set allowlist root,
    ///         and is one-shot: `mintStart` never moves, so no window can be extended, rewound, or re-opened.
    /// @notice pass-13: TREASURY RESERVE. Mint `qty` passes (ids 1..qty) to `to`, FREE, BEFORE the mint opens,
    ///         so they take the first ids and never consume a sale slot. One-shot, bounded by RESERVE_CAP, and
    ///         it counts against MAX_SUPPLY (sale supply becomes MAX_SUPPLY - qty). No price, no per-wallet cap,
    ///         no proceeds split (nothing is paid). Must run AFTER setRecipients (which then freezes, keeping the
    ///         audit H-1 "recipients set before any mint" invariant) and BEFORE openAllowlistMint. The reserved
    ///         passes are ordinary NFTs afterwards: transferable, and their rarity is sealed by id at launch like
    ///         any other. BY DESIGN (user, 2026-09-06) the reserved passes are FULL participants in every game: the
    ///         daily pack raffle (all super-rares registered, passes enter like any other, keeping the raffle odds
    ///         computed over the complete super-rare set) and the weekly holder draw. The treasury is treated as a
    ///         normal stakeholder; any winnings recycle to it. (HolderDrawEngine.setExcluded exists if that choice
    ///         is ever reversed, but it is intentionally NOT wired.)
    function reserveMint(uint256 qty, address to) external onlyOwner nonReentrant {
        if (launched) revert AlreadyLaunched();
        if (mintStart != 0) revert AlreadyStarted(); // the reserve is the FIRST mint, before any window opens
        if (reserveMinted) revert ReserveLocked(); // one-shot
        if (qty == 0 || qty > RESERVE_CAP) revert ReserveTooLarge();
        if (totalMinted + qty > MAX_SUPPLY) revert SoldOut(); // defensive; always true this early
        _requireRecipientsSet(); // enforce setRecipients-first ordering; preserves the H-1 invariant
        reserveMinted = true; // CEI: latch before the external _safeMint calls (blocks any reentry)
        // preaudit: start the rescue clock. Real tokens exist from here on, so if the owner never opens the
        // mint the LAUNCH_BACKSTOP() now runs from THIS stamp (see launchBackstopExpired). Open the mint within
        // LAUNCH_BACKSTOP() of the reserve; past it a stranger may finalize the collection as reserved-only.
        reserveAt = block.timestamp;
        for (uint256 i; i < qty; ++i) {
            uint256 id = ++totalMinted; // 1..qty, since this is the first mint
            _safeMint(to, id);
            emit Minted(id, to);
        }
        emit ReserveMinted(to, qty);
    }

    function openAllowlistMint() external onlyOwner {
        if (launched) revert AlreadyLaunched();
        if (mintStart != 0) revert AlreadyStarted(); // one-shot: the mint starts exactly once
        if (allowlistRoot == bytes32(0)) revert AllowlistRootUnset(); // else the GTD window admits nobody
        if (!mintOpen) revert MintClosed(); // never start the timed windows against a paused mint
        _requireRecipientsSet();
        // preaudit: SOFT-CLOSE INVARIANT. _maybeExtendOverflow caps overflowEnd at nominal + MAX_EXTENSION()
        // while the close is fixed at nominal + PUBLIC_MINT_WINDOW(), so the public window is only non-empty
        // when MAX_EXTENSION() < PUBLIC_MINT_WINDOW(). The durations are virtual (subclass-overridable), so
        // assert it here, where they are first read together, and fail LOUDLY rather than let a mis-set
        // subclass silently shrink the open window to zero. Inert for the base and every shipped subclass.
        if (MAX_EXTENSION() >= PUBLIC_MINT_WINDOW()) revert SoftCloseEatsPublicWindow();
        mintStart = block.timestamp;
        overflowEnd = block.timestamp + GTD_WINDOW() + OVERFLOW_WINDOW(); // nominal end; the soft-close may push it
        emit MintStarted(mintStart);
    }

    /// @notice The mint phase RIGHT NOW, derived from elapsed time. CLOSED before the start and after the
    ///         public window; ALLOWLIST across the GTD and overflow windows; PUBLIC in the open window.
    function phase() public view returns (MintPhase) {
        uint256 s = mintStart;
        if (s == 0) return MintPhase.CLOSED;
        uint256 t = block.timestamp;
        uint256 oe = overflowEnd; // pass-12: the (possibly extended) allowlist -> public boundary
        if (t < oe) return MintPhase.ALLOWLIST;
        // FIXED close from mintStart (pass-12b): the soft-close moves `oe` LATER inside this envelope, so
        // public runs [oe, fixed close] and shortens under late overflow demand rather than extending the end.
        if (t <= s + GTD_WINDOW() + OVERFLOW_WINDOW() + PUBLIC_MINT_WINDOW()) return MintPhase.PUBLIC;
        return MintPhase.CLOSED; // closed by time
    }

    /// @notice The cumulative per-wallet cap active RIGHT NOW (0 before the mint starts). Rises GTD_CAP ->
    ///         OVERFLOW_CAP -> PUBLIC_CAP (3 -> 8 -> 20) across the GTD, overflow and public windows;
    ///         `mintedBy` is checked against it.
    function currentCap() public view returns (uint256) {
        uint256 s = mintStart;
        if (s == 0) return 0;
        uint256 t = block.timestamp;
        if (t < s + GTD_WINDOW()) return GTD_CAP; // [start, +GTD): fixed guaranteed window
        if (t < overflowEnd) return OVERFLOW_CAP; // [+GTD, overflowEnd): the extendable overflow window
        return PUBLIC_CAP; // public window
    }

    /// @notice Unix time the public window opens (= the possibly-extended overflow end). 0 before start. The
    ///         soft-close pushes THIS later under late demand; the close below is fixed, so public just shortens.
    function publicOpensAt() public view returns (uint256) {
        return overflowEnd; // 0 before start
    }

    /// @notice Unix time the whole mint closes. FIXED at mintStart + GTD + OVERFLOW + PUBLIC (an announceable
    ///         end), independent of the soft-close, which only moves publicOpensAt() inside this envelope.
    function publicMintClosesAt() public view returns (uint256) {
        return mintStart == 0 ? 0 : mintStart + GTD_WINDOW() + OVERFLOW_WINDOW() + PUBLIC_MINT_WINDOW();
    }

    /// @notice True once the public window has run out: EVERY mint path is closed and finalizeLaunch() is
    ///         permissionless. False before the mint starts.
    /// @dev    Strict `>`, matching the mint gate exactly (see phase()'s `<=`): at t == publicMintClosesAt the
    ///         mint is still live and the permissionless finalize is not yet armed, so the two never overlap.
    function publicMintExpired() public view returns (bool) {
        return mintStart != 0 && block.timestamp > publicMintClosesAt();
    }

    /// @notice pass-10: true once LAUNCH_BACKSTOP() has elapsed since `mintStart`. Like `publicMintExpired()` it
    ///         closes every mint path and makes finalizeLaunch() permissionless. It is the outer safety for
    ///         the one hole the public window cannot cover: an owner who starts the mint and then loses the
    ///         key. 30 days >> the ~50h honest span, so a stranger can rescue the protocol but never races a
    ///         live mint. Strict `>`, exactly as publicMintExpired().
    /// @dev    preaudit: RESERVE-THEN-ABANDON. Before the mint starts the same clock ALSO runs from `reserveAt`,
    ///         so an owner who took the treasury reserve (real, transferable tokens) and then lost the key
    ///         before openAllowlistMint no longer bricks the whole protocol (rarityOf, the pool gate on
    ///         `launched`). Once the mint starts, ONLY the mintStart clock counts (it is always the later of
    ///         the two, and every mint path additionally needs phase() != CLOSED, i.e. mintStart != 0), so the
    ///         reserve clock can never close or race a live mint. Same strict `>`.
    function launchBackstopExpired() public view returns (bool) {
        uint256 s = mintStart;
        if (s != 0) return block.timestamp > s + LAUNCH_BACKSTOP();
        uint256 r = reserveAt;
        return r != 0 && block.timestamp > r + LAUNCH_BACKSTOP();
    }

    // ─── mint (pack rip) ─────────────────────────────────────────────────────

    /// @dev pass-9 phase/deadline gate, shared by every mint path. `proofPath` = the merkle-gated path, live
    ///      in BOTH ALLOWLIST and PUBLIC; the open path needs PUBLIC. The stamped deadline then closes both.
    ///      `mintOpen` (owner kill switch) and `launched` gate exactly as they did before pass-9.
    /// @dev pass-10: TWO closed-by-time boundaries now, and they are the SAME two that arm the permissionless
    ///      finalize. That symmetry is the safety property: a mint path is live for exactly the instants in
    ///      which finalizeLaunch() is owner-only, so a stranger can never seal the collection out from under
    ///      a live mint, and a live mint can never outlast the launch rescue.
    function _requireMintable(bool proofPath) internal view {
        if (!mintOpen || launched) revert MintClosed();
        MintPhase p = phase(); // derived from time: CLOSED before start and after the public window
        // CLOSED (not started, or closed by time) mints nothing; the open (no-proof) path needs PUBLIC, while
        // the merkle path is live in BOTH ALLOWLIST and PUBLIC (an allowlisted wallet never loses its path).
        if (p == MintPhase.CLOSED || (!proofPath && p != MintPhase.PUBLIC)) revert MintClosed();
        // belt-and-suspenders (phase()==CLOSED already covers these): nothing mints past either deadline.
        if (publicMintExpired() || launchBackstopExpired()) revert MintWindowClosed();
    }

    /// @dev pass-12 auction soft-close. A mint landing in the last EXTENSION_TRIGGER() of the (current)
    ///      overflow window pushes `overflowEnd` back by EXTENSION_STEP(), capped at MAX_EXTENSION() beyond the
    ///      NOMINAL end (mintStart + GTD + OVERFLOW). Reachable only on an allowlist-path mint, because during
    ///      overflow block.timestamp < overflowEnd, which is exactly when the open path is refused. Never moves
    ///      the end earlier and never past the cap, so it cannot be used to grief the public window open shut.
    function _maybeExtendOverflow() internal {
        uint256 s = mintStart;
        uint256 oe = overflowEnd;
        uint256 t = block.timestamp;
        // must be inside the overflow window (past GTD, before the current end) AND inside the trigger tail
        if (t < s + GTD_WINDOW() || t >= oe) return; // not in overflow (GTD, or already public)
        if (t < oe - EXTENSION_TRIGGER()) return; // not yet in the last EXTENSION_TRIGGER()
        uint256 hardCap = s + GTD_WINDOW() + OVERFLOW_WINDOW() + MAX_EXTENSION();
        if (oe >= hardCap) return; // already at the cap, no more extensions
        uint256 newEnd = oe + EXTENSION_STEP();
        if (newEnd > hardCap) newEnd = hardCap;
        overflowEnd = newEnd;
        emit OverflowExtended(newEnd);
    }

    /// @dev The mint body shared by mint / mintBatch / allowlistMint, so the caps, the exact-price check and
    ///      the 80/10/10 split can never drift between the paths. All state is written BEFORE _safeMint (CEI);
    ///      every external entry point additionally carries nonReentrant.
    /// @dev Shared mint core. `account` is the wallet whose per-wallet cap + allocation this mint consumes
    ///      (msg.sender for a normal mint; the allowlisted VAULT for a delegated mint); `recipient` is where
    ///      the passes land (msg.sender for both normal and delegated mints - the delegate holds them). The
    ///      payer is always msg.sender (msg.value).
    function _mintCommon(uint256 qty, address account, address recipient) internal {
        // audit H-1: recipients MUST be set before any mint, otherwise the first mint freezes setRecipients
        // (AlreadyMinting) and finalizeLaunch (RecipientsUnset) forever, permanently locking proceeds AND the
        // rarity reveal (which cascades into PackRegistry.claimFreeEntries reverting for every holder).
        // pass-10: both phase openers check this too, so in practice it is already true by the first mint.
        _requireRecipientsSet();
        // pass-11: the per-wallet cap is the TIER active right now (GTD_CAP 3 / OVERFLOW_CAP 8 / PUBLIC_CAP 20),
        // and mintedBy is ONE cumulative counter across every window, so a wallet's total holding is bounded by
        // whatever tier is live when it mints. A GTD wallet (cap 3) can top up to 8 in overflow, 20 in public.
        uint256 cap = currentCap();
        if (qty == 0 || qty > cap) revert WalletLimit();
        if (totalMinted + qty > MAX_SUPPLY) revert SoldOut();
        if (mintedBy[account] + qty > cap) revert WalletLimit(); // cap keyed to `account` (the vault, if delegated)
        if (msg.value != mintPrice * qty) revert BadPrice();

        mintedBy[account] += qty;
        _maybeExtendOverflow(); // pass-12: auction soft-close (state write before _safeMint, CEI-safe)

        // pass-10: the split is 80/10/10 (LP / prize seed / team). Applied to the TOTAL value, so a batch
        // splits exactly as the same number of single mints would. Team is the EXACT remainder bps and LP
        // absorbs every wei of rounding dust, so team can never exceed its 10% (audit L-17).
        uint256 seed = (msg.value * SEED_BPS) / BPS;
        uint256 teamCut = (msg.value * (BPS - LP_BPS - SEED_BPS)) / BPS;
        lpReserve += msg.value - seed - teamCut;
        seedReserve += seed;
        teamReserve += teamCut;

        for (uint256 i; i < qty; ++i) {
            // Ids are SEQUENTIAL, 1..MAX_SUPPLY, never reused and never burned, so the minted set is always
            // exactly 1..totalMinted. HolderDrawEngine draws over that range. (Rarity is sealed collection-wide
            // at finalizeLaunch, so a token's id says nothing about its tier.)
            uint256 id = ++totalMinted;
            _safeMint(recipient, id);
            emit Minted(id, recipient);
        }
    }

    /// @notice Mint ONE pass. PUBLIC phase only, and only before BOTH closed-by-time boundaries:
    ///         `publicMintClosesAt` (pass-9) and the LAUNCH_BACKSTOP (pass-10).
    function mint() external payable nonReentrant {
        _requireMintable(false);
        _mintCommon(1, msg.sender, msg.sender);
    }

    /// @notice Mint `qty` passes (1..currentCap()) in ONE transaction / one signature. Identical checks, split,
    ///         and per-wallet cap as mint(); ids stay sequential 1..MAX_SUPPLY and rarity is still sealed
    ///         collection-wide at finalizeLaunch. Added post-c8e0bf3 (pass-8 candidate) for batch-mint UX.
    ///         PUBLIC phase only, and only before both closed-by-time boundaries (pass-9, pass-10).
    function mintBatch(uint256 qty) external payable nonReentrant {
        _requireMintable(false);
        _mintCommon(qty, msg.sender, msg.sender);
    }

    /// @notice Community-allowlist mint: `qty` passes for a wallet proving membership in `allowlistRoot`.
    ///         Live in the ALLOWLIST phase AND throughout PUBLIC (an allowlisted wallet never loses its
    ///         path), but never past `publicMintClosesAt` and never past the LAUNCH_BACKSTOP(). Same supply
    ///         cap, same per-wallet cap (shared with the public path), same exact price, same 80/10/10 split.
    /// @param  qty   passes to mint, 1..currentCap() and within this wallet's remaining cumulative allocation.
    /// @param  proof merkle proof for leaf = keccak256(abi.encodePacked(msg.sender)).
    function allowlistMint(uint256 qty, bytes32[] calldata proof) external payable nonReentrant {
        _requireMintable(true);
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
        if (!MerkleProof.verifyCalldata(proof, allowlistRoot, leaf)) revert NotAllowlisted();
        _mintCommon(qty, msg.sender, msg.sender);
    }

    /// @notice Delegated allowlist mint: a hot wallet (msg.sender) mints the allocation of an allowlisted
    ///         VAULT it has been delegated by, so the vault never has to connect here or hold the mint. The
    ///         vault authorizes the delegate ONCE on delegate.xyz (an on-chain delegation, off this site);
    ///         this checks that delegation in the registry. Same phases/price/split as allowlistMint. The
    ///         per-wallet cap and allocation are keyed to the VAULT (shared with the vault's own direct mint,
    ///         so a delegate can never exceed the vault's cap and multiple delegates of one vault share it);
    ///         the passes are minted to the delegate (msg.sender), which pays.
    /// @param  qty   passes to mint, within the vault's remaining allocation at the current cap.
    /// @param  proof merkle proof for leaf = keccak256(abi.encodePacked(vault)).
    /// @param  vault the allowlisted wallet being minted for; the delegate must be delegated by it.
    function delegatedAllowlistMint(uint256 qty, bytes32[] calldata proof, address vault)
        external
        payable
        nonReentrant
    {
        _requireMintable(true);
        if (address(delegateRegistry) == address(0)) revert DelegationDisabled();
        bytes32 leaf = keccak256(abi.encodePacked(vault));
        if (!MerkleProof.verifyCalldata(proof, allowlistRoot, leaf)) revert NotAllowlisted();
        // caller (delegate) must be delegated by `vault` for this contract; v2 also admits a broader "all" delegation
        if (!delegateRegistry.checkDelegateForContract(msg.sender, vault, address(this), bytes32(0))) {
            revert NotDelegated();
        }
        _mintCommon(qty, vault, msg.sender); // cap keyed to the vault; passes to the delegate
        emit DelegatedMint(vault, msg.sender, qty);
    }

    /// @inheritdoc INFTCollection
    function rarityOf(uint256 tokenId) public view override returns (uint8) {
        if (_ownerOf(tokenId) == address(0)) revert NoToken();
        // preaudit: always the CURRENT revealRound (storage, never cached), so a fallback re-bind is honored.
        // Nothing downstream can hold a stale tier: this only succeeds once the bound beacon has landed, and
        // that is exactly the state in which advanceRevealFallback() is blocked forever (RevealAlreadyResolved).
        require(revealRound != 0, "not revealed"); // sealed until finalizeLaunch sets the reveal round
        bytes32 beacon = drand.randomness(revealRound); // reverts until that round's beacon is posted
        uint256 roll = uint256(keccak256(abi.encodePacked(beacon, tokenId, "nft"))) % BPS;
        if (roll < 200) return SUPER_RARE; // 2%
        if (roll < 1000) return RARE; // 8%
        if (roll < 3000) return UNCOMMON; // 20%
        return COMMON; // 70%
    }

    // ─── launch ──────────────────────────────────────────────────────────────

    /// @notice Seal ALL rarities to ONE future, time-locked round and close the launch. Deliberately moves
    ///         NO ETH (audit H-13): the reveal, and therefore rarityOf and holder free-entries, can never
    ///         be blocked by a reverting payout recipient. Proceeds are pulled separately via withdrawProceeds.
    /// @dev    The round is unknowable during the mint (it didn't exist yet), revealed revealDelay later;
    ///         one beacon reveals the whole collection (BLS keeper efficiency, the audit #4 fix under a
    ///         time-locked oracle).
    /// @dev    pass-9: owner-callable AT ANY TIME (as before), and PERMISSIONLESS once the 48h public window
    ///         has expired. A lost or absent owner can no longer strand the collection unrevealed (rarityOf
    ///         reverts until this runs, which would brick PackRegistry.claimFreeEntries) or keep the pool
    ///         shut (QpullTaxHook gates pool creation on `launched`). Every existing invariant is preserved:
    ///         recipients must be set, the flag is one-shot, and NO ETH moves here (audit H-13).
    /// @dev    pass-10: the permissionless arming now also fires on `launchBackstopExpired()`, which covers the
    ///         case pass-9 could not: an owner who opened only the ALLOWLIST phase and then vanished, so the
    ///         48h deadline was never stamped and `publicMintExpired()` stays false forever. Both boundaries
    ///         also hard-close every mint path (see `_requireMintable`), so the permissionless finalize can
    ///         never race a live mint, and neither can be walked back once armed (see `openPublicMint`).
    function finalizeLaunch() external nonReentrant {
        if (msg.sender != owner() && !publicMintExpired() && !launchBackstopExpired()) {
            revert OwnableUnauthorizedAccount(msg.sender);
        }
        if (launched) revert AlreadyLaunched();
        _requireRecipientsSet();
        launched = true;
        revealRound = drand.roundAt(block.timestamp + revealDelay);
        revealBoundAt = block.timestamp; // preaudit: anchors the reveal fallback ladder (see advanceRevealFallback)
        emit Launched(lpReserve, seedReserve, teamReserve);
    }

    /// @notice preaudit: REVEAL LIVENESS FALLBACK, permissionless and NON-DISCRETIONARY. If the bound reveal
    ///         round is never produced (drand skipped it), rarity would otherwise be bricked forever, because
    ///         `revealRound` was written exactly once. This walks a ladder of rounds fixed at finalizeLaunch:
    ///         rung k is `drand.roundAt(revealBoundAt + k * REVEAL_FALLBACK_STEP())`, callable only once that
    ///         instant has passed AND the currently bound round is still unavailable. Nobody chooses a round
    ///         (no owner, no keeper, no caller): the round is pure time math off the one-shot `revealBoundAt`,
    ///         and the call's own timing selects nothing, so two callers anywhere inside the same rung window
    ///         bind the SAME round. Repeated calls walk successive rungs while rounds stay unavailable; the
    ///         moment ANY bound round's beacon lands, (a) below blocks this forever and rarity resolves from it.
    /// @dev    (a) `!drand.isAvailable(revealRound)` is the safety property: a reveal that has resolved can
    ///         never be re-rolled, and the oracle only ever adds beacons, so a resolved reveal stays resolved.
    ///         Rungs cannot be skipped: the first call always binds rung 1, whatever the time.
    /// @dev    RESIDUAL (stated plainly): beacon posting is permissionless (BlsDrandOracle.submitBeacon), so
    ///         "unavailable" past a rung instant means the beacon was never posted for a whole
    ///         REVEAL_FALLBACK_STEP(). The honest path is trivial (anyone posts the produced beacon, the keeper
    ///         does so routinely) and closes the fallback for good; the lever only exists for a round drand
    ///         itself never produced. Operators should post the reveal beacon promptly as a matter of course.
    function advanceRevealFallback() external {
        uint64 cur = revealRound;
        if (cur == 0) revert RevealNotBound(); // finalizeLaunch has not bound a reveal yet
        if (drand.isAvailable(cur)) revert RevealAlreadyResolved(); // (a): a resolved reveal never re-rolls
        uint256 rung = revealFallbackRung + 1;
        uint256 rungTime = revealBoundAt + rung * REVEAL_FALLBACK_STEP(); // predetermined: stamp + arithmetic
        if (block.timestamp < rungTime) revert RevealFallbackNotDue(); // (b): the rung's instant must have passed
        uint64 next = drand.roundAt(rungTime); // (c): the round AT the rung instant, never at the call
        revealFallbackRung = rung;
        revealRound = next;
        emit RevealFallbackAdvanced(rung, cur, next, rungTime);
    }

    /// @notice Disburse the three launch buckets to their (frozen) recipients, each INDEPENDENTLY (audit
    ///         H-13): a recipient that reverts leaves only its own bucket for a later retry and never blocks
    ///         the others or the reveal. Permissionless once launched; destinations are fixed.
    function withdrawProceeds() external nonReentrant {
        if (!launched) revert NotLaunched();
        uint256 lp = lpReserve;
        if (lp > 0) {
            lpReserve = 0;
            (bool ok,) = lpTreasury.call{ value: lp }("");
            if (!ok) lpReserve = lp; // restore for retry; other buckets still flow
        }
        uint256 seed = seedReserve;
        if (seed > 0) {
            seedReserve = 0;
            (bool ok,) = seedTreasury.call{ value: seed }("");
            if (!ok) seedReserve = seed;
        }
        uint256 t = teamReserve;
        if (t > 0) {
            teamReserve = 0;
            (bool ok,) = team.call{ value: t }("");
            if (!ok) teamReserve = t;
        }
    }

    // INFTCollection.ownerOf/balanceOf are inherited from ERC721.
    function ownerOf(uint256 tokenId) public view override(ERC721, INFTCollection) returns (address) {
        return super.ownerOf(tokenId);
    }

    function balanceOf(address owner) public view override(ERC721, INFTCollection) returns (uint256) {
        return super.balanceOf(owner);
    }

    // ─── ownership clock (pass-10, holder draw) ──────────────────────────────

    /// @notice Stamp `ownerSince[tokenId]` on every REAL change of hands, and only on a real one.
    /// @dev    HolderDrawEngine reads this as the whole of its eligibility test: a pass whose stamp is later
    ///         than a week's freeze instant is out of that week, which is what stops a buy-after-reveal
    ///         front-run without storing any ownership history.
    /// @dev    `super` runs FIRST so `from` is knowable. That order is safe: OZ v5 `_update` makes no external
    ///         call (it clears one approval, adjusts two balances, writes one owner slot and emits Transfer),
    ///         and the `onERC721Received` hook lives in `_checkOnERC721Received`, which `_safeMint` and
    ///         `_safeTransfer` invoke only AFTER `_update` returns. So the stamp is committed before any
    ///         external call and no receiver hook can ever observe a stale value.
    /// @dev    THE `from != to` GUARD IS LOAD BEARING, DO NOT REMOVE IT. A self-transfer is fully legal in
    ///         OZ v5 and costs about 35k gas: `_checkAuthorized` admits the owner, a single-token approvee AND
    ///         any `setApprovalForAll` operator, and `to == from` nets out to no ownership change at all.
    ///         Stamping unconditionally would therefore hand every marketplace operator a wallet has ever
    ///         approved a repeatable kill switch: call transferFrom(victim, victim, id) after the freeze
    ///         instant and the victim silently leaves that week's draw, while the pass never moves, the
    ///         balance never changes and the only trace is a self-Transfer. Worse than a grief, it is
    ///         directly profitable, because the draw's candidate order is public once the beacon reveals, so
    ///         an operator can knock out exactly the winning ids it is approved for and promote candidates it
    ///         holds itself. The guard also makes the invariant EXACT rather than weaker:
    ///         `ownerSince[id] <= T` if and only if the current owner has held `id` continuously since T.
    /// @dev    The guard cannot be turned around to GAIN eligibility: the field is only ever assigned
    ///         `uint64(block.timestamp)`, so it is monotone non-decreasing per token, and the guard skips the
    ///         write only when there was no ownership change to record. Mint (from == address(0) != to) and
    ///         burn (to == address(0) != from) both satisfy `from != to` and stamp. Approvals never reach
    ///         `_update`, so approve / setApprovalForAll can never move the clock either.
    /// @dev    RESIDUAL, stated plainly: an approved operator can still perform a REAL transfer to itself.
    ///         That is theft, it takes custody and loses the eligibility with it, and it was already the risk
    ///         of granting the approval. The guard reduces "every approval is a free weekly kill switch" to
    ///         "every approval is a theft risk", which it always was.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (from != to) {
            ownerSince[tokenId] = uint64(block.timestamp);
            // Holder-draw qualification clock. super._update already adjusted both balances, so balanceOf here
            // is the POST-transfer count. Stamp the up-crossing (a wallet reaching MIN_HOLD starts its streak)
            // and clear the down-crossing (dropping below MIN_HOLD breaks it). Untouched while it stays >= or <
            // MIN_HOLD, so the stamp marks continuous qualification since that instant. Mint (from==0) only
            // raises `to`; burn (to==0) only lowers `from`; a real transfer touches both. The `from != to` guard
            // means a self-transfer never moves it (balance is unchanged anyway); same anti-griefing reasoning
            // as ownerSince above. `qualifiedSince(o) <= freeze` is then the frozen holder-count gate the draw reads.
            if (to != address(0) && qualifiedSince[to] == 0 && balanceOf(to) >= MIN_HOLD) {
                qualifiedSince[to] = uint64(block.timestamp);
            }
            if (from != address(0) && qualifiedSince[from] != 0 && balanceOf(from) < MIN_HOLD) {
                qualifiedSince[from] = 0;
            }
        }
        // Launch transfer-lock (flag-on-buy). Placed AFTER the stamp so the "stamp committed before any
        // external read" invariant above still holds; a revert here rolls the stamp back with the whole tx.
        // Only real transfers (mint/burn excluded), and only via a read-only hook call that cannot reenter.
        if (from != to && from != address(0) && to != address(0)) _enforceLaunchLock(from);
    }

    /// @dev Reverts a real transfer whose sender made a gated buy while the hook's launch gate is still open,
    ///      so a pass cannot be shuffled to unlock a second buying wallet (spec §16 anti-Sybil). Latches
    ///      `launchLockLifted` once the window has passed, to stop reading the hook on every later transfer.
    ///      Fail-open when the hook is unwired (taxHook == 0) or before launch.
    function _enforceLaunchLock(address from) internal {
        if (launchLockLifted) return;
        ITaxHook h = taxHook;
        if (address(h) == address(0)) return; // hook not wired — no lock
        uint256 lt = h.launchTime();
        if (lt == 0) return; // not launched yet: the gate window has not started
        if (block.timestamp >= lt + h.GATE_DURATION()) {
            launchLockLifted = true; // window over: latch off so future transfers skip the hook reads
            return;
        }
        (, uint32 buys) = h.earlyBuyer(from);
        if (buys > 0) revert PassLockedDuringLaunch(); // `from` is a committed launch buyer
    }

    // ─── metadata: FULLY ON-CHAIN, auto-revealing ────────────────────────────

    /// @notice True once rarities are revealed: finalizeLaunch has set the round AND its drand beacon is
    ///         posted. tokenURI uses this to flip every pass from the sealed art to its tier art at once.
    function isRevealed() public view returns (bool) {
        return revealRound != 0 && drand.isAvailable(revealRound);
    }

    /// @notice Fully on-chain token URI (a `data:application/json;base64` blob whose image is a
    ///         `data:image/svg+xml` blob). No IPFS, no baseURI: the renderer serves the sealed art until
    ///         the beacon lands, then the token's tier art (from rarityOf), a trustless auto-reveal.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId); // reverts ERC721NonexistentToken if the id was never minted
        bool revealed = isRevealed();
        uint8 rarity = revealed ? rarityOf(tokenId) : 0;
        return renderer.tokenURI(tokenId, revealed, rarity);
    }
}
