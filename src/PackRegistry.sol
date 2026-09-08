// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { NonRenounceableOwnable2Step } from "./utils/NonRenounceableOwnable2Step.sol";
import { IDrandOracle } from "./interfaces/IDrandOracle.sol";
import { IPackRegistry, ILeaderboardRegistry } from "./interfaces/IRegistries.sol";
import { INFTCollection } from "./interfaces/INFTCollection.sol";

/// @dev Minimal read view of the write-once RaffleEngine, so previewDraw can read the same daily beacon
///      round and winner count without a circular import.
interface IEngineRound {
    function drawRound(uint32 day) external view returns (uint64);
    function winnersPerDay() external view returns (uint256);
}

/// @title  PackRegistry
/// @notice Mints raffle tickets on buys (fixed whole-ticket schedule, spec §4), seals each to a
///         future drand round for its tier (spec §6), and maintains the live-ticket set as daily
///         cohorts so the RaffleEngine can draw a fixed K winners in O(K) regardless of how many
///         tickets exist (spec §7, fully-on-chain model).
///
/// @dev    Cadence: DAILY. Ticket life: 7 days. A cohort minted on day D is eligible for the
///         draws on days D+1 .. D+7 (7 shots), then falls out of the sliding window. Expiry is
///         therefore free — an aged cohort is simply never in-window again; no per-ticket cleanup.
contract PackRegistry is IPackRegistry, NonRenounceableOwnable2Step {
    // ─── tiers ───────────────────────────────────────────────────────────────
    uint8 internal constant COMMON = 0;
    uint8 internal constant UNCOMMON = 1;
    uint8 internal constant RARE = 2;
    uint8 internal constant SUPER_RARE = 3;

    // ─── config (immutable) ──────────────────────────────────────────────────
    IDrandOracle public immutable drand;
    uint256 public immutable genesis; // launch timestamp; day 0 begins here
    uint256 public immutable revealDelay; // seconds ahead to seal the tier round (sealed-then-revealed)
    uint32 public constant LIFE_DAYS = 7; // ticket lifetime in daily draws
    // Cohort/day cadence. `virtual` so the TESTNET-ONLY subclass shortens it; MAINNET uses the real 1 day
    // automatically (footgun removed). MUST equal RaffleEngine.DAY() (both default 1 day) — enforced on-chain:
    // RaffleEngine's constructor reverts (CadenceMismatch) unless dayLength() below equals its own DAY().
    function DAY() internal view virtual returns (uint256) { return 1 days; }

    /// @notice The cohort/day cadence in seconds. Pre-audit (cadence cross-check): exposed so RaffleEngine can
    ///         assert at construction that the paired cadences match, exactly as genesis is cross-checked —
    ///         a mis-paired deploy (mainnet engine on a short-clock registry, or vice versa) would otherwise
    ///         silently desync every reveal-before-cutoff window. DAY() itself stays `internal`: the testnet
    ///         subclass overrides it as `internal pure`, so widening its visibility would break that pair.
    function dayLength() external view returns (uint256) {
        return DAY();
    }

    // ─── ticket price (§13.4) ─────────────────────────────────────────────────
    // WETH per ticket — the ETH-in VALUE of a buy, in wei (1e18 = 1 ETH). Seeded to ~$10 of ETH at
    // launch (e.g. 0.003 ETH). Tickets are priced off the ETH going IN to a buy (`grossWeth` in the hook),
    // NOT the QPULL received — so pool depth / slippage never change how many tickets a given spend earns,
    // and there is no pool-price read to game (pumping the pool cannot mint extra tickets). Example spend →
    // tickets: $10→1, $100→10, $1,000→100, $10,000→1,000. The owner may re-peg to hold ~$10 as ETH's USD
    // price drifts, but ONLY within tight bounds (≤ ±25% per change, ≤ once/day) so the knob can never
    // zero-out (mint-farm) or moon (brick) the raffle; every move is slow + observable.
    uint256 public ticketPrice;
    uint256 public constant MAX_ADJ_BPS = 2500; // max ±25% per re-peg
    uint256 public constant ADJUST_COOLDOWN = 1 days; // min gap between re-pegs
    uint64 public lastTicketAdjust; // last re-peg timestamp (0 = never)

    // ─── wiring ──────────────────────────────────────────────────────────────
    address public recorder; // QpullTaxHook — only caller of recordBuy
    address public engine; // RaffleEngine — only caller of drawFrom
    ILeaderboardRegistry public leaderboard; // rip-XP sink (claimRipXp -> recordXp); write-once
    mapping(uint256 => bool) public ripXpGranted; // pack id => rip XP already banked (once per pack)
    mapping(uint256 => bool) public ripXpIneligible; // free (untaxed) NFT-perk packs never earn rip XP (re-audit M-1)

    // Base XP a Common non-winning rip banks; higher tiers scale it. Kept separate from the buy-XP
    // grossWeth scale — a deliberate balance knob (Common 1x .. Super rare 10x).
    uint256 public constant RIP_XP_UNIT = 1e15;
    // rip XP is claimable only within this many days AFTER a pack settles as a final non-winner. This BOUNDS
    // the holder's choice of leaderboard week; it does not remove it (re-audit M-2, wording corrected in the
    // pre-audit): a 7-day window over 7-day Sunday-aligned weeks straddles exactly one week boundary, so the
    // XP can land only in the settlement week or the one immediately after — never a hoarded later week.
    // Exact settlement-week banking (credit the week containing the settlement instant regardless of claim
    // time) was considered and deferred: a claim made after that week's distribute() would then credit an
    // already-paid week and the XP would be silently lost. The residual choice is immaterial: RIP_XP_UNIT is
    // negligible next to buy points (gross QPULL, ~1e18+ scale), so timing barely moves top-25 standings.
    uint32 public constant RIP_XP_WINDOW = 7;
    // Gas bound on per-buy minting. At ~73k gas/pack a cap of 1000 needed ~73M gas — above the L2 block
    // limit, so an ordinary large buy reverted (audit H-18). 100 keeps a full-cap buy well within a block;
    // value above the cap is banked and mints on the buyer's next trade.
    uint256 public constant MAX_TICKETS_CEILING = 200;
    uint256 public maxTicketsPerBuy = 100;

    // ─── ticket state ────────────────────────────────────────────────────────
    struct Pack {
        address owner;
        uint64 revealRound; // drand round the tier is sealed against
        uint32 cohortDay; // day minted
        bool spent; // drawn (won) — burned
    }

    /// @dev In-memory config for the virtual free-entry block, bundled so drawFrom/previewDraw stay under
    ///      the stack limit. Built once per draw by _buildFreeCfg.
    struct FreeCfg {
        uint256[] srList; // eligible Super Rare token ids (bounded by MAX_SR_SCAN)
        uint256 srCount; // number of valid entries in srList
        uint256 wb; // base weight of the eligible pool = srCount*SR_WEIGHT + pledge copies (incl. transferred-away ones)
        uint256 freeze; // the day's freeze instant (a pass must be held at or before this)
        uint256 vPool; // weight added to the draw total (= cap when any pass is eligible, else 0)
    }

    uint256 public nextPackId = 1;
    mapping(uint256 => Pack) public packs;
    mapping(uint32 => uint256[]) internal cohortLive; // cohortDay => live pack ids
    mapping(uint256 => uint256) internal packLiveIndex; // pack id => index within its cohort array
    mapping(address => uint256) public bankedRemainder; // sub-ticket QPULL carried forward (§4)

    // ─── virtual free daily entries for NFT holders (spec §16, VIRTUAL model) ─
    // Art Passes enter the daily raffle DIRECTLY and VIRTUALLY: nothing is minted, nothing is stored per
    // entry. The whole free-eligible block enters drawFrom as ONE integer weight (`vPool`) added to the
    // sampling total, and at most K winners are resolved lazily at draw time as self-describing synthetic
    // ids. Super Rare = passive auto-entry (first claim on the cap); Common/Uncommon/Rare = opt-in pledge
    // (weight 1/2/4). Cap = 10% of the LIVE PAID window, linear, no clamp. See docs/PLEDGE-ENTRY-SPEC.md.
    INFTCollection public nft;
    uint256 public constant FREE_CAP_BPS = 1000; // free entries ≤ 10% of the LIVE PAID window; no hard clamp
    mapping(uint32 => uint256) public paidToday; // day => paid tickets minted (buys) — UI/analytics only

    // Top bit tags a synthetic virtual-winner id; real pack ids (sequential from 1) never set it.
    uint256 internal constant VIRTUAL_FLAG = 1 << 255;
    uint256 internal constant MAX_SR_SCAN = 128; // bounded SR-index scan per draw (never the 3k token space)
    uint256 internal constant MAX_VDRAW_ROLLS = 256; // shared pledge-rejection budget per draw (gas backstop, see _pickVirtual)
    // Per-seat pledge-rejection sub-cap. It bounds GAS, not the flood (pre-audit LOW "pledge-flood", decision 2a,
    // SECURITY.md 16.8). pledgeList is append-only and a copy is voided only when it is rolled, so an owner who
    // pledges passes and then transfers them away (no re-pledge) leaves INVALID weight F in the sampling region
    // wb = 8s + Pv + F (s eligible Super Rares at SR_WEIGHT, Pv valid pledge weight). Bound per free seat, with
    // q = F / wb the invalid fraction (each roll lands SR / valid / invalid independently and the seat resolves
    // on its first non-invalid roll within this cap):
    //   P(seated SR) = 8s/(8s+Pv) * (1 - q^6)   P(seated valid pledge) = Pv/(8s+Pv) * (1 - q^6)   P(void) = q^6
    // So the 8 : 4/2/1 ladder is EXACT among seated seats and the flood's only lever is the void share q^6
    // (rolls forward to the vault, never to the flooder): 1.6% at q=0.5, 26% at q=0.8, 53% at q=0.9, and
    // q=0.9 costs F = 9x the honest weight (against 30 SR alone: ~540 Rares or ~2,160 Commons held and
    // pledged-then-transferred, i.e. most of the supply).
    // SEATS ARE INDEPENDENT (cascade fix): this per-seat figure is ALSO the expected lost share of the whole
    // free block only because every virtual slot rolls its own fresh values. _pickVirtual keys each roll on
    // (beacon, day, 1, seat, roll) and `seat` advances on a VOID as well as on a fill (identically in _drawCore
    // and _replayVirtual). Before that fix `seat` advanced only on a fill, so a voided seat was re-rolled with
    // the IDENTICAL six values against unchanged storage at every later virtual slot and voided again: ONE
    // void ended the free block for the rest of the draw, and the measured lost share of the free block was
    // 16% / 85% / 96% at q = 0.5 / 0.8 / 0.9, not q^6. With independent seats a void costs exactly that seat.
    // SR-band rolls are immune to the BUDGET: _pickVirtual resolves them before it, so a flood can never void a
    // seat that rolled SR. Pruning F out of wb (the deeper rework) is deliberately deferred to the external
    // audit.
    uint256 internal constant MAX_REJECTS_PER_SEAT = 6;
    uint256 public constant SAFE_FREE_K = 150; // winnersPerDay ≤ this ships with full gas margin (else gas-test)
    uint256 public constant SR_WEIGHT = 8; // Super Rare draw weight (ladder Common 1 / Uncommon 2 / Rare 4 / SR 8)
    uint256 internal constant NOT_SEATED = type(uint256).max; // _pickVirtual sentinel (never a real token id)

    // Super Rare index: trustless, append-only, verified on submit. The ONLY set iterated for SR autos.
    uint256[] public superRareIds;
    mapping(uint256 => bool) public srIndexed;
    // audit (pass-9, finding-1): the SR draw SET is frozen per draw exactly like ownerSince. An id is eligible
    // for a draw only if it was registered at or before that draw's freeze, so a late registerSuperRare (after
    // the day's settling beacon is already public) cannot inject an SR into that day's draw to steer a win or
    // its VTIER; a late registration simply counts from the next day onward. 0 = never registered.
    mapping(uint256 => uint64) public srRegisteredAt;

    // Per-day pledge pool for Common/Uncommon/Rare. pledgeList holds weight-expanded copies (1/2/4), and the
    // draw picks uniformly over it (SR copies weighted alongside) so selection is tier-weighted. The pool's
    // realized WEIGHT into the draw is bounded by vPool=cap (10% of the paid window), NOT by pledgeList.length,
    // so a pledge-then-transfer flood cannot inflate the free SHARE; pledgerOf voids a pledge at draw time if the
    // pass has changed hands. The list is append-only (a transferred-away pass's copies stay in it), so such a
    // flood CAN dilute the pool's seating: the bound is stated at MAX_REJECTS_PER_SEAT and the pick order that
    // keeps Super Rare seats immune to it at _pickVirtual. pledgeDistinct counts distinct first-pledges per day and feeds ONLY the
    // pledgeCount() view (an UPPER bound — not decremented on transfer; previewDraw gives realized winners).
    mapping(uint32 => uint256[]) internal pledgeList;
    mapping(uint256 => mapping(uint32 => address)) public pledgerOf;
    mapping(uint32 => uint256) public pledgeDistinct;

    // ─── events / errors ─────────────────────────────────────────────────────
    event RecorderSet(address recorder);
    event EngineSet(address engine);
    event NftSet(address nft);
    event PackMinted(uint256 indexed id, address indexed owner, uint32 cohortDay, uint64 revealRound);
    event LeaderboardSet(address leaderboard);
    event RipXpClaimed(address indexed owner, uint256 packCount, uint256 xp);
    event Drawn(uint32 indexed drawDay, uint256 count);
    event FreeEntryDrawn(uint32 indexed day, uint256 indexed passTokenId, address owner, uint8 tier, uint256 seat);
    event Pledged(uint256 indexed tokenId, uint32 indexed day, address pledger);
    event SuperRareRegistered(uint256 indexed tokenId);
    event TicketPriceSet(uint256 oldPrice, uint256 newPrice);
    event MaxTicketsPerBuySet(uint256 m);

    error NotRecorder();
    error NotEngine();
    error NotStarted();
    error NoNft();
    error NotNftOwner();
    error TicketPriceZero();
    error AdjustTooSoon();
    error AdjustOutOfBounds();
    error ZeroDrand();
    error BadMaxTickets();
    error BadRevealDelay();
    error AlreadySet(); // audit F14/F15: reward-gating bindings are write-once
    error VirtualId(); // rollOf/tierAndRollOf called on a synthetic virtual-winner id (no on-chain roll)
    error BadPledge(); // pledging a Super Rare (they auto-enter) or a non-owned pass

    modifier onlyRecorder() {
        if (msg.sender != recorder) revert NotRecorder();
        _;
    }

    modifier onlyEngine() {
        if (msg.sender != engine) revert NotEngine();
        _;
    }

    constructor(
        address drand_,
        uint256 ticketPrice_,
        uint256 genesis_,
        uint256 revealDelay_,
        address initialOwner
    ) Ownable(initialOwner) {
        if (ticketPrice_ == 0) revert TicketPriceZero();
        if (drand_ == address(0)) revert ZeroDrand(); // audit M-17: oracle sits on the taxed-buy hot path
        // audit H-7: seal margin must be >= the engines' REVEAL_LAG (1h) so a cohort's tier round isn't
        // near-public before the buy window closes, and < 1 day so it reveals within the cohort's draw window.
        if (revealDelay_ < 1 hours || revealDelay_ >= 1 days) revert BadRevealDelay();
        drand = IDrandOracle(drand_);
        ticketPrice = ticketPrice_;
        genesis = genesis_;
        revealDelay = revealDelay_;
    }

    // audit F14: write-once. The recorder gates recordBuy (mints tickets + points); a re-settable
    // recorder let a compromised owner point it at an EOA, forge unlimited entries, then restore it.
    function setRecorder(address t) external onlyOwner {
        if (t == address(0) || recorder != address(0)) revert AlreadySet();
        recorder = t;
        emit RecorderSet(t);
    }

    // audit F15: write-once. drawFrom is onlyEngine; a re-settable engine let a compromised owner
    // register a malicious engine and pop every live ticket. (drawFrom also clamps k internally now.)
    function setEngine(address e) external onlyOwner {
        if (e == address(0) || engine != address(0)) revert AlreadySet();
        engine = e;
        emit EngineSet(e);
    }

    // Write-once (mirrors setEngine): the leaderboard is the only sink claimRipXp mints XP into. PackRegistry
    // must be set as that leaderboard's xpRecorder (write-once there) for claimRipXp to succeed.
    function setLeaderboard(address lb) external onlyOwner {
        if (lb == address(0) || address(leaderboard) != address(0)) revert AlreadySet();
        leaderboard = ILeaderboardRegistry(lb);
        emit LeaderboardSet(lb);
    }

    // audit F15-lead: write-once. A re-settable nft let a compromised owner substitute a fake NFT to
    // farm free entries; freezing it closes that lever.
    function setNft(address n) external onlyOwner {
        if (n == address(0) || address(nft) != address(0)) revert AlreadySet();
        nft = INFTCollection(n);
        emit NftSet(n);
    }

    function setMaxTicketsPerBuy(uint256 m) external onlyOwner {
        if (m == 0 || m > MAX_TICKETS_CEILING) revert BadMaxTickets(); // audit H-18/L-5: bounded + event
        maxTicketsPerBuy = m;
        emit MaxTicketsPerBuySet(m);
    }

    /// @notice Re-peg the ticket price to hold ~$10 of QPULL per ticket as QPULL's market price drifts
    ///         (spec §13.4). Deliberately constrained — at most ±25% per change and at most once per day
    ///         — so the knob can never mint-farm (price→0) or brick (price→∞) the raffle, and every move
    ///         is slow and observable. The owner (ideally a timelock/multisig) computes the QPULL amount
    ///         currently worth ~$10 off-chain and sets it within these bounds. No price is read on-chain.
    function setTicketPrice(uint256 newPrice) external onlyOwner {
        if (newPrice == 0) revert TicketPriceZero();
        if (block.timestamp < uint256(lastTicketAdjust) + ADJUST_COOLDOWN) revert AdjustTooSoon();
        uint256 cur = ticketPrice;
        uint256 lo = (cur * (10_000 - MAX_ADJ_BPS)) / 10_000; // −25%
        uint256 hi = (cur * (10_000 + MAX_ADJ_BPS)) / 10_000; // +25%
        if (hi <= cur) hi = cur + 1; // audit M-7 (pass-8): band never collapses to a point
        if (newPrice < lo || newPrice > hi) revert AdjustOutOfBounds();
        lastTicketAdjust = uint64(block.timestamp);
        ticketPrice = newPrice;
        emit TicketPriceSet(cur, newPrice);
    }

    // ─── minting (buys only) ─────────────────────────────────────────────────

    /// @inheritdoc IPackRegistry
    function recordBuy(address buyer, uint256 grossValue) external override onlyRecorder {
        uint256 avail = bankedRemainder[buyer] + grossValue;
        uint256 n = avail / ticketPrice;
        if (n > maxTicketsPerBuy) n = maxTicketsPerBuy; // cap gas; the excess value stays banked for later buys
        bankedRemainder[buyer] = avail - n * ticketPrice;
        if (n == 0) return;

        uint32 cday = _today();
        paidToday[cday] += n;
        _mintPacks(buyer, n, cday, false); // taxed buy — rip-XP eligible
    }

    // ─── virtual free entries: register (Super Rare) + pledge (Common/Uncommon/Rare) ─────────

    /// @notice Add verified Super Rare token ids to the auto-entry index. Permissionless and trustless:
    ///         each id is checked on-chain (rarityOf == SUPER_RARE); non-SR / unrevealed / duplicate ids are
    ///         skipped, so anyone can complete or repair the index. One mandatory bulk call at reveal (see
    ///         docs/PLEDGE-ENTRY-SPEC.md); after that the set is fixed (post-reveal rarities are immutable).
    function registerSuperRare(uint256[] calldata ids) external {
        if (address(nft) == address(0)) revert NoNft();
        if (!nft.launched()) revert NotStarted();
        for (uint256 i; i < ids.length; ++i) {
            uint256 tid = ids[i];
            if (srIndexed[tid]) continue;
            try nft.rarityOf(tid) returns (uint8 r) {
                if (r == SUPER_RARE) {
                    srIndexed[tid] = true;
                    srRegisteredAt[tid] = uint64(block.timestamp); // freeze-cutoff anchor (finding-1)
                    superRareIds.push(tid);
                    emit SuperRareRegistered(tid);
                }
            } catch { /* unrevealed / nonexistent — skip, retry after reveal */ }
        }
    }

    /// @notice Opt Common/Uncommon/Rare passes into TODAY's virtual daily raffle (Super Rare is automatic).
    ///         Weight-expanded 1/2/4 by tier so the draw is tier-weighted. Default is NOT entered (the pool
    ///         stays thin), and a pledge is voided at draw time if the pass has since changed hands.
    function pledge(uint256[] calldata tokenIds) external {
        if (address(nft) == address(0)) revert NoNft();
        if (!nft.launched()) revert NotStarted();
        uint32 day = _today();
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 tid = tokenIds[i];
            if (nft.ownerOf(tid) != msg.sender) revert NotNftOwner();
            uint8 r = nft.rarityOf(tid); // reverts if not yet revealed
            if (r == SUPER_RARE) revert BadPledge(); // Super Rare auto-enters; never pledged
            address cur = pledgerOf[tid][day];
            if (cur == address(0)) {
                uint256 w = _entryWeight(r);
                uint256[] storage pl = pledgeList[day];
                for (uint256 j; j < w; ++j) pl.push(tid);
                pledgerOf[tid][day] = msg.sender;
                unchecked { ++pledgeDistinct[day]; }
                emit Pledged(tid, day, msg.sender);
            } else if (cur != msg.sender) {
                pledgerOf[tid][day] = msg.sender; // re-pledge by the new owner: reuse copies, no over-weight
                emit Pledged(tid, day, msg.sender);
            }
            // else same pledger this day: no-op
        }
    }

    /// @dev Pledge weight by tier (Common 1 / Uncommon 2 / Rare 4). Super Rare is auto with SR_WEIGHT, not here.
    function _entryWeight(uint8 rarity) internal pure returns (uint256) {
        if (rarity == RARE) return 4;
        if (rarity == UNCOMMON) return 2;
        return 1; // Common
    }

    function _mintPacks(address to, uint256 n, uint32 cday, bool free) internal {
        // Quantized reveal round (BLS keeper efficiency): ALL packs minted on day `cday` share ONE reveal
        // round — the round at (start of the next day + revealDelay). Still a FUTURE, time-locked round
        // (unknowable at mint — the audit #2 fix under a time-locked oracle), but ONE per day instead of
        // one per beacon, so the keeper posts ~1 tier beacon/day. Revealed before the cohort's first draw.
        uint64 rr = drand.roundAt(genesis + (uint256(cday) + 1) * DAY() + revealDelay);
        uint256[] storage arr = cohortLive[cday];
        uint256 id = nextPackId;
        for (uint256 i; i < n; ++i) {
            packs[id] = Pack({ owner: to, revealRound: rr, cohortDay: cday, spent: false });
            if (free) ripXpIneligible[id] = true; // untaxed perk pack — excluded from rip XP (re-audit M-1)
            packLiveIndex[id] = arr.length;
            arr.push(id);
            emit PackMinted(id, to, cday, rr);
            unchecked {
                ++id;
            }
        }
        nextPackId = id;
    }

    // ─── drawing (engine only) ───────────────────────────────────────────────

    /// @notice Draw up to `k` winners for `drawDay` from the live PAID window PLUS the virtual free-entry
    ///         block. Paid winners are popped (marked spent) and returned as their real pack ids; free
    ///         winners are returned as self-describing synthetic ids (top bit set; owner+tier packed in —
    ///         see ownerOf/tierOf), so RaffleEngine._payWinners handles both verbatim. The free block is
    ///         weighted into the sampling total as ONE integer (`vPool`); nothing is materialized.
    /// @dev    Paid window for day d = cohorts [d-7 .. d-1]. Free entries (Super Rare autos at SR_WEIGHT +
    ///         pledged C/U/R at 1/2/4, MULTI-SHOT: fill the full 10% cap by weighted repeats) begin only
    ///         AFTER the day's freeze instant, so the one-time opening sweep is paid-only. See
    ///         docs/PLEDGE-ENTRY-SPEC.md.
    function drawFrom(bytes32 beacon, uint32 drawDay, uint256 k)
        external
        onlyEngine
        returns (uint256[] memory winners)
    {
        return _drawCore(beacon, drawDay, k, true); // daily draw: the virtual free-entry block is active
    }

    /// @notice PAID-ONLY draw for the one-time opening sweep. Structurally excludes the virtual free block
    ///         (finding-2). The opening's settling beacon reveals ~1h after day (ACCUM_DAYS-1) closes, but a
    ///         free block folded at drawDay=ACCUM_DAYS would freeze a full cadence LATER — i.e. against an
    ///         already-public beacon. Making paid-only a code property (not a timing accident) guarantees a
    ///         late opening call can never activate free entries. A later daily runDraw(ACCUM_DAYS) still uses
    ///         drawFrom and keeps its free block, so this is a distinct entrypoint, not a drawDay special-case.
    function drawFromPaidOnly(bytes32 beacon, uint32 drawDay, uint256 k)
        external
        onlyEngine
        returns (uint256[] memory winners)
    {
        return _drawCore(beacon, drawDay, k, false);
    }

    function _drawCore(bytes32 beacon, uint32 drawDay, uint256 k, bool allowFree)
        internal
        returns (uint256[] memory winners)
    {
        if (drawDay == 0) revert NotStarted();
        if (k > MAX_TICKETS_CEILING) k = MAX_TICKETS_CEILING; // audit F15: clamp independent of the caller
        uint32 from = drawDay > LIFE_DAYS ? drawDay - LIFE_DAYS : 0;
        uint32 to = drawDay - 1;

        uint256 paidRemaining;
        for (uint32 c = from; c <= to; ++c) {
            paidRemaining += cohortLive[c].length;
        }

        // virtual free-entry block: ONE integer weight (cfg.vPool) into the draw, never materialized
        FreeCfg memory cfg = _buildFreeCfg(drawDay, paidRemaining, allowFree);
        uint256 total = paidRemaining + cfg.vPool;
        winners = new uint256[](k);
        uint256[] memory wonTids = new uint256[](k); // per-draw tids of virtual winners, in win order (VTIER entropy)
        uint256 got;
        // virtual SLOT counter: advances on every virtual slot, filled OR voided (cascade fix, see
        // MAX_REJECTS_PER_SEAT). It is the per-slot roll nonce in _pickVirtual, which is what makes the seats
        // independent, and the uniqueness nonce in each synthetic id. MUST move in lockstep with _replayVirtual.
        uint256 seat;
        uint256 rejects; // shared pledge-rejection budget across the whole draw

        for (uint256 j; j < k && total > 0; ++j) {
            uint256 r = uint256(keccak256(abi.encode(beacon, drawDay, j))) % total;
            if (r < paidRemaining) {
                for (uint32 c = from; c <= to; ++c) {
                    uint256 len = cohortLive[c].length;
                    if (r < len) { winners[got++] = _popAt(c, r); break; }
                    r -= len;
                }
                unchecked { --paidRemaining; }
            } else {
                // virtual free draw (multi-shot): weighted pick over Super Rare + pledge copies, repeats
                // allowed; SR always valid, pledges validated under a bounded rejection budget.
                (uint256 tid, uint256 nr) = _pickVirtual(beacon, drawDay, cfg, seat, rejects);
                rejects = nr;
                if (tid != NOT_SEATED) {
                    address passOwner = _safeOwnerOf(tid);
                    if (passOwner != address(0)) {
                        uint256 winIdx = _tidWinIndex(wonTids, seat, tid); // this tid's k-th win in THIS draw
                        uint256 vid = _encodeVirtual(beacon, drawDay, seat, tid, winIdx, passOwner);
                        winners[got++] = vid;
                        wonTids[seat] = tid;
                        emit FreeEntryDrawn(drawDay, tid, passOwner, uint8((vid >> 160) & 3), seat);
                    }
                }
                // a voided slot leaves wonTids[seat] == 0 (never a token id) and still consumes its nonce, so
                // the NEXT virtual slot rolls fresh values instead of replaying this slot's void
                unchecked { ++seat; }
            }
            unchecked { --total; }
        }

        assembly { mstore(winners, got) }
        emit Drawn(drawDay, got);
    }

    /// @dev Build the in-memory list of Super Rare passes eligible for a draw (held before `freeze`).
    ///      Iterates ONLY the SR index (bounded by MAX_SR_SCAN), never the full token space, and never calls
    ///      rarityOf (SR-ness is the index), so the draw is reveal-independent and one bad token can't brick it.
    function _buildSrList(uint256 freeze) internal view returns (uint256[] memory srList, uint256 srCount) {
        uint256 n = superRareIds.length;
        if (n > MAX_SR_SCAN) n = MAX_SR_SCAN;
        srList = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 tid = superRareIds[i];
            uint64 ra = srRegisteredAt[tid];
            if (ra == 0 || uint256(ra) > freeze) continue; // registered after this draw's freeze (beacon already public) — not this draw (finding-1)
            uint64 os = nft.ownerSince(tid);
            if (os == 0 || uint256(os) > freeze) continue; // never held, or acquired after the freeze
            if (_safeOwnerOf(tid) == address(0)) continue;
            srList[srCount++] = tid;
        }
    }

    /// @dev ownerOf that never reverts (a burned/nonexistent ERC721 id can revert); returns 0 instead.
    function _safeOwnerOf(uint256 tid) internal view returns (address) {
        try nft.ownerOf(tid) returns (address o) { return o; } catch { return address(0); }
    }

    /// @dev Build the virtual free-entry config for a draw (freeze, eligible SR list, base weight, vPool).
    ///      vPool = cap (10% of the paid window) whenever any pass is eligible — MULTI-SHOT holds the 10% at
    ///      every volume by weighted repeats. Empty (vPool 0) before the freeze, on a zero-buy day, or with
    ///      no eligible passes, in which case drawFrom degenerates to today's paid-only behavior.
    function _buildFreeCfg(uint32 drawDay, uint256 paidRemaining, bool allowFree) internal view returns (FreeCfg memory cfg) {
        cfg.freeze = genesis + (uint256(drawDay) + 1) * DAY();
        if (!allowFree) return cfg; // opening sweep: paid-only by construction, independent of call timing (finding-2)
        if (address(nft) == address(0) || block.timestamp <= cfg.freeze) return cfg;
        uint256 cap = (paidRemaining * FREE_CAP_BPS) / 10_000;
        if (cap == 0) return cfg;
        (cfg.srList, cfg.srCount) = _buildSrList(cfg.freeze);
        cfg.wb = cfg.srCount * SR_WEIGHT + pledgeList[drawDay].length;
        if (cfg.wb > 0) cfg.vPool = cap;
    }

    /// @dev Resolve one virtual free seat: weighted pick over Super Rare (weight SR_WEIGHT each) + the
    ///      weight-expanded pledge copies, repeats allowed. Shared by drawFrom (commit) and previewDraw (view);
    ///      a pure function of (beacon, day, seat, frozen state), so preview == draw. Returns the running shared
    ///      rejection count so the caller threads it, and tid == NOT_SEATED (type(uint256).max, never a real
    ///      token id) when the seat voids (rolls forward). `seat` is the caller's virtual SLOT index, advanced
    ///      by the caller on a void as well as on a fill, so no two slots of a draw ever share a roll key and a
    ///      void never repeats at the next slot (cascade fix, MAX_REJECTS_PER_SEAT).
    ///
    ///      Pick order (pre-audit LOW "pledge-flood", decision 2a, SR FIRST, contained): on EVERY roll the
    ///      Super Rare band [0, srWeightTotal) is resolved BEFORE the shared budget is consulted and BEFORE
    ///      pledgeList is read. SR autos are always valid, so an SR-band roll is seated unconditionally: it
    ///      costs no budget, and neither a spent budget nor any number of invalid pledge copies can void or
    ///      pre-empt it (the budget check no longer precedes the seat's first roll, which used to void SR seats
    ///      too). Only a roll that lands in the pledge region is budget-gated and validated (a transfer voids
    ///      the pledge); an invalid copy burns one shared roll and the seat re-rolls over the WHOLE region,
    ///      which is what keeps the 8 : 4/2/1 ladder exact among seated seats (bound at MAX_REJECTS_PER_SEAT).
    ///      If the shared budget is ever spent (needs >= 43 fully-rejecting free seats in ONE draw, while a
    ///      K=200 draw seats ~K/11 = 18 free seats, so it is a gas backstop and not a live limit), a
    ///      pledge-band roll voids without validation while an SR-band roll still seats: SR falls to 8s/wb per
    ///      seat, never to zero. Voiding rather than handing a failed pledge seat to SR is deliberate: a
    ///      fallback would let an SR holder PROFIT from flooding; a void only rolls forward to the vault.
    function _pickVirtual(bytes32 beacon, uint32 day, FreeCfg memory cfg, uint256 seat, uint256 rejects)
        internal
        view
        returns (uint256 tid, uint256 rejectsOut)
    {
        rejectsOut = rejects;
        uint256 srWeightTotal = cfg.srCount * SR_WEIGHT;
        for (uint256 roll; roll < MAX_REJECTS_PER_SEAT; ++roll) {
            uint256 x = uint256(keccak256(abi.encode(beacon, day, uint256(1), seat, roll))) % cfg.wb;
            // 1. Super Rare band FIRST: always valid, budget-free, pledgeList never read.
            if (x < srWeightTotal) return (cfg.srList[x % cfg.srCount], rejectsOut);
            // 2. Pledge region: gated by the shared budget. A spent budget voids THIS pledge attempt only.
            if (rejectsOut >= MAX_VDRAW_ROLLS) return (NOT_SEATED, rejectsOut);
            uint256 cand = pledgeList[day][x - srWeightTotal];
            if (pledgerOf[cand][day] == _safeOwnerOf(cand) && nft.ownerSince(cand) <= cfg.freeze) {
                return (cand, rejectsOut);
            }
            unchecked { ++rejectsOut; } // invalid (transferred-away) copy: one shared roll burnt, re-roll
        }
        return (NOT_SEATED, rejectsOut);
    }

    /// @dev Encode a virtual free winner as a self-describing synthetic id: top bit set, seat + a fresh
    ///      beacon-rolled tier (VTIER, on the pack bands) + the passholder address packed in. Decoded by
    ///      ownerOf/tierOf so RaffleEngine._payWinners pays the passholder in the right tier bucket verbatim.
    function _encodeVirtual(bytes32 beacon, uint32 day, uint256 seat, uint256 tid, uint256 winIdx, address passOwner)
        internal
        pure
        returns (uint256)
    {
        // VTIER is keyed on the FROZEN winning-pass identity (tid) plus this token's own win-index within the
        // draw (winIdx) — NOT the live-mutable global seat counter (finding-3). Two independent properties:
        //   * Non-steerable: a token's k-th win ALWAYS rolls keccak(beacon,day,2,tid,k). A post-beacon
        //     transfer / pledge-void / seat reshuffle cannot reassign which roll a win gets, and every win is
        //     paid, so there is no cherry-pick and no bucket upgrade.
        //   * Variance-correct (regression fix): under multi-shot a token can win many seats; winIdx makes
        //     each of those wins an INDEPENDENT roll over the 1/4/15/80 bands instead of all sharing one tier,
        //     so a lone pass in a thin market can no longer concentrate the whole SR bucket — realized free
        //     value-share re-converges to ~9.09%. `seat` stays ONLY as the synthetic-id uniqueness nonce (the
        //     virtual slot index, which also advances over voided slots; gaps in it are voids, not reuse).
        uint8 vtier = _tierFromRoll(uint256(keccak256(abi.encode(beacon, day, uint256(2), tid, winIdx))) % 10_000);
        return VIRTUAL_FLAG | (seat << 168) | (uint256(vtier) << 160) | uint256(uint160(passOwner));
    }

    /// @dev How many of the first `count` virtual SLOTS (memory list, in slot order) were won by `tid`. This
    ///      is that token's win-index for its NEXT win. A voided slot holds 0, which is never a token id (the
    ///      collection mints 1..totalMinted), so voids never count. O(count) memory scan, count <= K <= 200;
    ///      identical in the commit (_drawCore) and view (_replayVirtual) paths so preview == draw holds.
    function _tidWinIndex(uint256[] memory wonTids, uint256 count, uint256 tid) internal pure returns (uint256 idx) {
        for (uint256 i; i < count; ++i) {
            if (wonTids[i] == tid) { unchecked { ++idx; } }
        }
    }

    function _popAt(uint32 c, uint256 li) internal returns (uint256 pickedId) {
        uint256[] storage arr = cohortLive[c];
        uint256 last = arr.length - 1;
        pickedId = arr[li];
        if (li != last) {
            uint256 lastId = arr[last];
            arr[li] = lastId;
            packLiveIndex[lastId] = li;
        }
        arr.pop();
        packs[pickedId].spent = true;
    }

    /// @dev Remove a pack from its cohort's live draw pool (swap-pop, mirrors _popAt) WITHOUT marking it
    ///      spent — a ripped non-winner leaves the pool but was never "won" (re-audit H-1). Only called for
    ///      packs still live (isRipXpClaimable requires !spent), so packLiveIndex[id] is valid.
    function _removeLiveById(uint256 id) internal {
        uint256[] storage arr = cohortLive[packs[id].cohortDay];
        uint256 li = packLiveIndex[id];
        uint256 last = arr.length - 1;
        if (li != last) {
            uint256 lastId = arr[last];
            arr[li] = lastId;
            packLiveIndex[lastId] = li;
        }
        arr.pop();
    }

    // ─── tier derivation (verifiable, spec §6) ───────────────────────────────

    /// @notice The tier of a pack, derived from its sealed beacon. Reverts until the round reveals.
    ///         Anyone can recompute this — the "verify this rip" affordance.
    function tierOf(uint256 packId) public view returns (uint8) {
        if (packId & VIRTUAL_FLAG != 0) return uint8((packId >> 160) & 3); // synthetic free-winner id: tier packed in
        return _tierFromRoll(rollOf(packId));
    }

    /// @notice The raw 0..9999 roll a pack revealed, keccak256(beacon, packId) % 10000. Reverts until
    ///         the round reveals. Anyone can recompute it off-chain — the "verify this rip" affordance,
    ///         and what the website's draw log / cards display next to the tier.
    function rollOf(uint256 packId) public view returns (uint256) {
        if (packId & VIRTUAL_FLAG != 0) revert VirtualId(); // synthetic free-winner id has no on-chain roll
        Pack storage p = packs[packId];
        require(p.owner != address(0), "no pack");
        bytes32 beacon = drand.randomness(p.revealRound); // reverts if not yet revealed
        return uint256(keccak256(abi.encodePacked(beacon, packId))) % 10_000;
    }

    /// @notice Tier + roll in one call (saves the consumer a second read).
    function tierAndRollOf(uint256 packId) external view returns (uint8 tier, uint256 roll) {
        roll = rollOf(packId);
        tier = _tierFromRoll(roll);
    }

    /// @dev The fixed, published rarity bands. SUPER_RARE 1% / RARE 4% / UNCOMMON 15% / COMMON 80%.
    function _tierFromRoll(uint256 roll) internal pure returns (uint8) {
        if (roll < 100) return SUPER_RARE; // 1%
        if (roll < 500) return RARE; // 4%
        if (roll < 2000) return UNCOMMON; // 15%
        return COMMON; // 80%
    }

    // ─── rip XP (non-winning packs) ──────────────────────────────────────────

    /// @notice XP a non-winning rip of `tier` banks. Common 1x / Uncommon 2x / Rare 4x / Super rare 10x.
    function ripXpWeight(uint8 tier) public pure returns (uint256) {
        if (tier == SUPER_RARE) return RIP_XP_UNIT * 10;
        if (tier == RARE) return RIP_XP_UNIT * 4;
        if (tier == UNCOMMON) return RIP_XP_UNIT * 2;
        return RIP_XP_UNIT; // COMMON
    }

    /// @notice A pack is a FINAL non-winner once it is revealed, never drawn (not spent), and past the last
    ///         draw that could ever include it (cohortDay + LIFE_DAYS, drawn the following day). Only then
    ///         is its outcome settled, so rip XP can't double-count a pack that still might win.
    function isRipXpClaimable(uint256 id) public view returns (bool) {
        Pack storage p = packs[id];
        if (p.owner == address(0) || p.spent || ripXpGranted[id] || ripXpIneligible[id]) return false;
        uint32 settled = uint32(p.cohortDay) + LIFE_DAYS + 1; // last day it could be drawn has passed
        uint32 t = _today();
        if (t <= settled || t > settled + RIP_XP_WINDOW) return false; // one-week window: bounds the bankable week to two adjacent weeks (M-2)
        return drand.isAvailable(p.revealRound); // revealed (tier is known)
    }

    /// @notice Bank rarity-weighted XP for your final non-winning ripped packs. Skips anything not yours /
    ///         already banked / still drawable / unrevealed, so a mixed batch never reverts. This is the
    ///         on-chain "rip" the site fires; it credits the weekly leaderboard and returns the XP gained so
    ///         the UI can show it. Checks-effects-interactions: ripXpGranted is set before the single external
    ///         call, and the leaderboard sink has no callback into this contract.
    function claimRipXp(uint256[] calldata packIds) external returns (uint256 total) {
        uint256 cnt;
        for (uint256 i; i < packIds.length; ++i) {
            uint256 id = packIds[i];
            if (packs[id].owner != msg.sender || !isRipXpClaimable(id)) continue;
            ripXpGranted[id] = true; // effect before interaction
            _removeLiveById(id); // re-audit H-1: leave the live draw pool so no draw can also pay this pack
            total += ripXpWeight(tierOf(id));
            unchecked {
                ++cnt;
            }
        }
        if (total > 0) leaderboard.recordXp(msg.sender, total);
        emit RipXpClaimed(msg.sender, cnt, total);
    }

    // ─── views ───────────────────────────────────────────────────────────────

    function _today() internal view returns (uint32) {
        if (block.timestamp <= genesis) return 0;
        return uint32((block.timestamp - genesis) / DAY());
    }

    function today() external view returns (uint32) {
        return _today();
    }

    function ownerOf(uint256 packId) external view returns (address) {
        if (packId & VIRTUAL_FLAG != 0) return address(uint160(packId)); // synthetic free-winner id: owner packed in
        return packs[packId].owner;
    }

    function cohortSize(uint32 cohortDay) external view returns (uint256) {
        return cohortLive[cohortDay].length;
    }

    /// @notice Total live PAID tickets eligible for the draw on `drawDay`.
    function liveCount(uint32 drawDay) external view returns (uint256) {
        return _liveCount(drawDay);
    }

    function _liveCount(uint32 drawDay) internal view returns (uint256 total) {
        if (drawDay == 0) return 0;
        uint32 from = drawDay > LIFE_DAYS ? drawDay - LIFE_DAYS : 0;
        for (uint32 c = from; c <= drawDay - 1; ++c) {
            total += cohortLive[c].length;
        }
    }

    /// @notice The virtual free-entry cap for `day` = 10% of that day's live PAID window. In the multi-shot
    ///         model the realized free weight equals this whenever any pass is eligible, so it is also the
    ///         honest "spots today" figure for the UI.
    function capOf(uint32 day) external view returns (uint256) {
        return (_liveCount(day) * FREE_CAP_BPS) / 10_000;
    }

    function superRareCount() external view returns (uint256) {
        return superRareIds.length;
    }

    /// @notice Upper bound on the distinct passes pledged for `day` (counts first-pledges). NOT decremented
    ///         when a pledged pass transfers, so it can over-report the still-eligible pledges; use
    ///         previewDraw(day) for the realized free winners once the beacon reveals.
    function pledgeCount(uint32 day) external view returns (uint256) {
        return pledgeDistinct[day];
    }

    /// @notice Read-only replay of a day's virtual free winners (synthetic ids), for the UI. Uses the SAME
    ///         beacon and logic as drawFrom, so its output equals drawFrom's virtual subset. Reverts until the
    ///         day's beacon reveals. Paid winners are not identified here (only their count drives routing).
    function previewDraw(uint32 day) external view returns (uint256[] memory) {
        if (day == 0 || engine == address(0) || address(nft) == address(0)) return new uint256[](0);
        uint256 k = IEngineRound(engine).winnersPerDay();
        if (k > MAX_TICKETS_CEILING) k = MAX_TICKETS_CEILING;
        bytes32 beacon = drand.randomness(IEngineRound(engine).drawRound(day)); // reverts until revealed
        uint256 paidRemaining = _liveCount(day);
        FreeCfg memory cfg = _buildFreeCfg(day, paidRemaining, true); // previewDraw mirrors the daily (free-enabled) path
        return _replayVirtual(beacon, day, k, paidRemaining, cfg);
    }

    /// @dev View-only replay of a day's virtual winners (paid hits only decrement the counter, since only
    ///      their count affects routing). Kept as its own function to stay under the stack limit.
    function _replayVirtual(bytes32 beacon, uint32 day, uint256 k, uint256 paidRemaining, FreeCfg memory cfg)
        internal
        view
        returns (uint256[] memory vwinners)
    {
        uint256 total = paidRemaining + cfg.vPool;
        vwinners = new uint256[](k);
        uint256[] memory wonTids = new uint256[](k); // mirrors _drawCore so preview == draw (VTIER winIdx)
        uint256 got;
        uint256 seat; // virtual SLOT counter, advanced on fill AND void exactly as in _drawCore (lockstep)
        uint256 rejects;
        for (uint256 j; j < k && total > 0; ++j) {
            uint256 r = uint256(keccak256(abi.encode(beacon, day, j))) % total;
            if (r < paidRemaining) {
                unchecked { --paidRemaining; }
            } else {
                (uint256 tid, uint256 nr) = _pickVirtual(beacon, day, cfg, seat, rejects);
                rejects = nr;
                if (tid != NOT_SEATED) {
                    address passOwner = _safeOwnerOf(tid);
                    if (passOwner != address(0)) {
                        uint256 winIdx = _tidWinIndex(wonTids, seat, tid);
                        vwinners[got++] = _encodeVirtual(beacon, day, seat, tid, winIdx, passOwner);
                        wonTids[seat] = tid;
                    }
                }
                unchecked { ++seat; } // void or fill: same nonce advance as _drawCore
            }
            unchecked { --total; }
        }
        assembly { mstore(vwinners, got) }
    }
}
