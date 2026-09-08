// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {
    IPoolManager,
    PoolKey,
    Currency,
    BalanceDelta,
    BalanceDeltaLib
} from "../interfaces/IPoolManager.sol";
import { IPackRegistry, ILeaderboardRegistry } from "../interfaces/IRegistries.sol";
import { INFTCollection } from "../interfaces/INFTCollection.sol";

/// @title  QpullTaxHook — the 4% trade tax as a Uniswap-V4 hook (audit H-2 fix)
/// @notice Replaces QPULLToken's transfer tax, which is STRUCTURALLY INCOMPATIBLE with V4's flash
///         accounting: a token that skims transfers breaks `settle()` (CurrencyNotSettled) for every
///         router that trades it. Instead, the canonical QPULL/WETH pool deploys WITH this hook, and
///         the tax becomes a swap fee taken inside the locked context:
///           - afterSwap takes 4% of the swap's UNSPECIFIED currency and sends it to the Treasury
///             (buys pay in QPULL, exact-in sells pay in WETH — the Treasury converts both, spec §3);
///           - the game registries are notified exactly as the token used to do (spec §4/§11):
///             buy -> pack tickets + leaderboard points; sells record nothing game-side;
///           - the 2-hour launch NFT-holder gate (spec §16, GATE_DURATION()) is enforced on buys, together
///             with the same-window anti-sniper throttle (per-wallet buy cooldown, per-wallet early-buy count,
///             per-buy WETH size cap) described under TRUST MODEL below.
///         QPULLToken itself is now a CLEAN, ownerless ERC-20 — plain transfers are untaxed and
///         V4 settlement paths never break.
///
/// @dev    TRUST MODEL — this contract is fully immutable: no owner, no setters, constants for the
///         tax and the gate. A hook governs the protocol's only liquid pool, so any admin power here
///         would be a rug/DoS lever; there is none. Consequences, accepted and documented:
///           - the 4% applies only to the canonical hooked pool. Anyone may spin up a hookless QPULL
///             pool and trade untaxed there, but ALL protocol-owned liquidity (80% of NFT-mint ETH)
///             sits in the canonical pool, so real flow routes here (SECURITY.md "hook-fee scope");
///           - trader attribution uses tx.origin (the transaction signer). hookData is IGNORED — it
///             is caller-supplied and unauthenticated, so crediting it would let buyers spoof the
///             launch gate. tx.origin cannot be spoofed; the cost is that ERC-4337 buys credit
///             the bundler (acceptable: rewards mis-credit, never mis-charge — the fee itself is
///             always paid by the actual swapper via the hook delta). SAME TRADEOFF, KNOWN LIMIT:
///             during the 2-hour gate window a holder who holds the NFT in a SMART-CONTRACT WALLET (Safe/AA)
///             is gated, because balanceOf(tx.origin=signer) is 0 — the NFT is the wallet's. This is
///             an accepted gate-window-only cost of using an unspoofable identity; such holders buy
///             freely once the gate self-expires (and can hold the NFT on the signing EOA to buy in
///             the gate window). Widening the gate to any contract's balance would reopen the spoof.
///             THE SAME LIMIT APPLIES TO THE LAUNCH THROTTLE (cooldown, early-buy count, size cap):
///             it is keyed on tx.origin too, deliberately, so the gate and the throttle can never
///             disagree about who a buyer is. Both therefore see the signer, not the wallet: under
///             EIP-7702 / ERC-4337 an account-abstraction wallet's buys are counted against its signer,
///             and buys that share a signer (a bundler batching several users, one EOA signing for
///             several beneficiaries) share one cooldown and one buy counter. Accepted, gate window (2h) only;
///           - the 2-hour gate window (GATE_DURATION()) is measured from POOL CREATION (afterInitialize), because that
///             is the only launch instant the hook can observe. Liquidity can only be added AFTER the
///             pool exists, so the runbook seeds LP immediately after initialize() — a long gap would
///             silently shorten the effective gate (no trading is possible until LP exists anyway);
///           - LAUNCH THROTTLE (anti-sniper), active ONLY inside that same gate window and on BUYS.
///             A holder who passes the gate must also satisfy two limits, each with its own error so an
///             integrator can tell them apart: at least BUY_COOLDOWN between two of their buys (BuyCooldown),
///             and, for a wallet's FIRST EARLY_BUY_COUNT buys only, at most `earlyBuyCapWei` of WETH on any
///             one of them (EarlyBuyTooLarge). There is NO hard buy count: buys after the first
///             EARLY_BUY_COUNT are allowed, just uncapped. Sells, and every
///             buy after the window closes, are untouched: no counter is read or written outside the
///             window, so post-launch swaps carry none of this gas. All three are immutable by
///             construction: two constants and one constructor immutable, no owner, no setter;
///           - THE SIZE CAP IS A FIXED AMOUNT OF ETH, NOT A DOLLAR FIGURE. `earlyBuyCapWei` is a wei
///             amount frozen at deploy. There is deliberately NO USD conversion: this chain has no price
///             feed the hook can trust, and reading the pool's own price would hand the cap to the very
///             snipers it exists to stop (they can move that price inside the same block, and a
///             QPULL-denominated cap is meaningless once the pool floats). The deployed value is picked
///             by hand from the ETH/USD price on deploy day (0.25 ether, set in script/Deploy.s.sol; the
///             USD figure it represents is re-derived at deploy time, not recorded here) and it DOES NOT
///             TRACK USD AFTERWARDS: if ETH doubles before launch, the cap is worth twice as many dollars,
///             and nobody can change it. Drift is bounded by the fact that the cap only lives for the
///             gate window (2 hours) after pool creation. Re-check the number against the ETH price immediately
///             before deploying;
///           - the cap measures the WETH the buyer actually spends, computed exactly from this swap's own
///             delta, never estimated (see `_buyWethIn`);
///           - registry notification is try/catch: this hook is immutable, so a reverting registry
///             must only ever cost that trade's rewards (RecordFailed event), never brick the pool.
///             The fee take() and the gate are NOT try/caught — fee delivery and the gate fail closed.
///           - afterSwap is `nonReentrant` (transient guard). Reentrancy is already prevented by the
///             PoolManager's unlock-lock, onlyPoolManager, and trusted storage-only registries, and the
///             only mutable state a swap writes is the launch-throttle counter, which is checked and
///             written in one uninterrupted internal call with no external call between them, so it
///             cannot be re-entered mid-update. The guard is belt-and-braces (a Certora hook-checklist
///             item). It does NOT block multi-hop routing (sequential afterSwap calls, not nested); it
///             only bars a true nested re-entry, which cannot happen anyway.
///
///         V4 mechanics (verified against vendored v4-core v4.0.0):
///           - address flag bits: AFTER_INITIALIZE (1<<12) | BEFORE_ADD_LIQUIDITY (1<<11) |
///             BEFORE_REMOVE_LIQUIDITY (1<<9) | AFTER_SWAP (1<<6) | AFTER_SWAP_RETURNS_DELTA (1<<2) = 0x1A44
///             — the deployer mines a CREATE2 salt so the hook address carries exactly these bits
///             (script/HookMiner.sol);
///           - afterSwap returns (selector, int128 hookDeltaUnspecified). POSITIVE means the swapper
///             pays the hook that amount of the unspecified currency (Hooks.sol: "the caller has to
///             pay for the hook's delta"; swapDelta -= hookDelta). The hook's credit is settled by
///             take()-ing the fee to the Treasury inside the callback — same unlock, nets to zero;
///           - the unspecified currency is currency1 when (exactInput == zeroForOne), else currency0;
///           - PoolManager.initialize is PERMISSIONLESS, so afterInitialize restricts pool creation:
///             only INITIALIZER may create the canonical pool (otherwise an attacker front-runs the
///             launch, stamping launchTime early and burning the 2-hour gate window), and no other
///             PoolKey may attach this hook at all (otherwise a QPULL/junk pool could farm registry
///             rewards through afterSwap).
contract QpullTaxHook is ReentrancyGuardTransient {
    using BalanceDeltaLib for BalanceDelta;

    // ─── constants ───────────────────────────────────────────────────────────
    uint256 public constant TAX_BPS = 400; // 4% — immutable by construction, no owner can change it
    uint256 internal constant BPS = 10_000;
    // Launch anti-dump (SELL-ONLY): sells are taxed on a decaying schedule for the launch window — 20% for the
    // first step, dropping 4pp per step to the 4% floor (20/16/12/8 -> 4%). Buys are ALWAYS 4%. The elevated
    // tax routes to the same Treasury/prize vaults, so early sells seed a bigger opening pot. The time getters
    // are `virtual` so a TESTNET-ONLY subclass can COMPRESS them; mainnet keeps the real 48h/12h/2h schedule.
    // No owner can change any of these — a testnet subclass hardcodes short values, mainnet is fixed at 48h/etc.
    // The schedule SATURATES at TAX_BPS (afterSwap) and the constructor refuses a zero SELL_STEP(), so no
    // decay/step ratio a subclass picks can ever make a sell revert.
    uint256 public constant SELL_TAX_START_BPS = 2000; // 20% at launch
    uint256 public constant SELL_STEP_BPS = 400; // -4pp per step
    function SELL_STEP() public view virtual returns (uint256) { return 12 hours; } // step length
    function SELL_DECAY() public view virtual returns (uint256) { return 48 hours; } // window the elevated sell tax decays over
    function GATE_DURATION() public view virtual returns (uint256) { return 2 hours; } // spec §16 launch holder gate + transfer-lock window

    // Launch anti-sniper throttle. Applies ONLY to BUYS and ONLY while the holder gate above is open, on the
    // same tx.origin identity the gate uses. BUY_COOLDOWN is `virtual` (testnet compression). EARLY_BUY_COUNT
    // is the number of a wallet's FIRST buys the size cap applies to — NOT a hard limit; later buys are uncapped.
    function BUY_COOLDOWN() public view virtual returns (uint256) { return 2 minutes; } // min spacing between one wallet's gated buys
    uint256 public constant EARLY_BUY_COUNT = 10; // size cap covers a wallet's first 10 buys; buys after that are uncapped

    // Hook address flag bits this contract requires (v4-core Hooks.sol bit layout).
    // AFTER_INITIALIZE (1<<12) | BEFORE_ADD_LIQUIDITY (1<<11) | BEFORE_REMOVE_LIQUIDITY (1<<9) | AFTER_SWAP
    // (1<<6) | AFTER_SWAP_RETURNS_DELTA (1<<2). The two liquidity bits (audit F6 / pass-4 F4, and the
    // SYMMETRIC remove gate for audit L1 / job-745) make the PoolManager invoke this hook on every LP add
    // AND remove, restricting BOTH to the protocol — closing the untaxed LP side-door with no phishing-slip.
    uint160 public constant REQUIRED_FLAGS = (1 << 12) | (1 << 11) | (1 << 9) | (1 << 6) | (1 << 2); // 0x1A44
    uint160 internal constant ALL_FLAG_MASK = (1 << 14) - 1;

    // ─── immutable wiring (no owner, no setters) ─────────────────────────────
    IPoolManager public immutable poolManager;
    address public immutable qpull;
    address public immutable weth;
    bool internal immutable qpullIs0; // address-sort order of the canonical pair
    uint24 public immutable canonicalFee;
    int24 public immutable canonicalTickSpacing;
    address public immutable treasury; // receives the 4% (QPULL and/or WETH)
    IPackRegistry public immutable packRegistry;
    ILeaderboardRegistry public immutable leaderboardRegistry;
    INFTCollection public immutable nft; // launch-gate (2h) membership
    address public immutable exemptSender; // the Treasury's QpullWethAdapter: convert() sells untaxed
    address public immutable initializer; // the ONLY address allowed to create the canonical pool

    /// @notice Largest amount of WETH one wallet may spend on a single buy while the 2-hour launch gate is
    ///         open. A FIXED WEI AMOUNT, frozen at deploy, with NO USD tracking of any kind: there is no
    ///         price feed on this chain the hook could trust, and the pool's own price is exactly what a
    ///         sniper can move, so pricing the cap in dollars on-chain is not possible. The deploy value
    ///         is chosen by hand from that day's ETH/USD price (0.25 ether, set in script/Deploy.s.sol;
    ///         the USD figure is re-derived at deploy time, never recorded here) and its dollar value
    ///         drifts with ETH from that moment on. Immutable: no owner and no setter can move it, and it
    ///         stops mattering GATE_DURATION() (2 hours) after pool creation.
    uint256 public immutable earlyBuyCapWei;

    uint256 public launchTime; // stamped by afterInitialize — opens the 2-hour gate window (GATE_DURATION())

    /// @notice Per-wallet gate-window buy record. One storage slot: written only inside the gate window,
    ///         never read or written after it closes.
    struct EarlyBuyer {
        uint64 lastBuyAt; // timestamp of this wallet's most recent gated buy (0 = none yet)
        uint32 buys; // gated buys made so far, capped at EARLY_BUY_COUNT
    }

    /// @notice Gated-window buy record per tx.origin. Public so a front end can show a buyer their
    ///         remaining buys and cooldown instead of letting the swap revert.
    mapping(address => EarlyBuyer) public earlyBuyer;

    struct HookConfig {
        address poolManager;
        address qpull;
        address weth;
        uint24 fee;
        int24 tickSpacing;
        address treasury;
        address packRegistry;
        address leaderboardRegistry;
        address nft;
        address exemptSender;
        address initializer;
        // Gate-window (2h) per-buy WETH cap, in wei. Fixed at deploy from that day's ETH price (0.25 ether, set in
        // script/Deploy.s.sol; the USD worth is re-derived at deploy time, not recorded here). NOT a USD
        // figure and it never becomes one, see `earlyBuyCapWei`.
        uint256 earlyBuyCapWei;
    }

    event Launched(uint256 launchTime);
    event TaxTaken(address indexed trader, bool isBuy, uint256 grossQpull, address feeCurrency, uint256 fee);
    event RecordFailed(bytes32 indexed which, address indexed trader, uint256 grossQpull);

    error ZeroAddress();
    error BadFee();
    error BadFlags();
    error NotPoolManager();
    error NotCanonicalPool();
    error NotInitializer();
    error Gated(); // gate-window (2h) buy by a wallet holding no pass
    error BadEarlyBuyCap(); // constructor: a zero cap would block every gated buy for the whole 2-hour gate window
    error BadSellSchedule(); // constructor: zero SELL_STEP() (sells divide by zero) or start rate < TAX_BPS
    error BuyCooldown(); // gated buy less than BUY_COOLDOWN after this wallet's previous one
    error EarlyBuyTooLarge(); // one of a wallet's first EARLY_BUY_COUNT gated buys spends more than earlyBuyCapWei of WETH
    error MintStillOpen(); // pool creation blocked until the NFT mint is closed (finalizeLaunch)
    error LiquidityRestricted(); // audit F6/pass-4 F4: only the protocol may provide liquidity

    modifier onlyPoolManager() {
        // Both callbacks mutate protocol state (launchTime, registry records) — if anyone could call
        // them directly they could stamp the gate window early or mint free tickets/points/entries.
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(HookConfig memory c) {
        if (
            c.poolManager == address(0) || c.qpull == address(0) || c.weth == address(0)
                || c.treasury == address(0) || c.packRegistry == address(0)
                || c.leaderboardRegistry == address(0) || c.nft == address(0) || c.exemptSender == address(0)
                || c.initializer == address(0)
        ) revert ZeroAddress();
        if (c.fee > 1_000_000) revert BadFee(); // static LP fee only, <= 100% (dynamic sentinel 0x800000 > 1M)
        // A zero cap would reject every buy for the whole 2-hour gate window (any buy spends more than 0), so it
        // is refused at deploy rather than discovered at launch. There is no upper bound to check: a cap
        // larger than the pool can absorb simply never binds.
        if (c.earlyBuyCapWei == 0) revert BadEarlyBuyCap();
        // Sell-schedule config invariant (pre-audit hardening). The decaying sell tax divides by SELL_STEP()
        // and saturates at TAX_BPS. SELL_STEP()/SELL_DECAY() are virtual, and Solidity dispatches a virtual
        // call from a base constructor to the most-derived override, so this sees the subclass's values.
        // Refuse at deploy the two edits the saturating schedule cannot absorb: a zero step (division by zero
        // on every launch-window sell) and a start rate below the floor (the saturation bound
        // `SELL_TAX_START_BPS - TAX_BPS` would itself underflow). The decay/step RATIO is deliberately
        // unconstrained: the schedule floors at TAX_BPS for any ratio, so a longer decay can only mean more
        // time at the flat 4%.
        if (SELL_STEP() == 0 || SELL_TAX_START_BPS < TAX_BPS) revert BadSellSchedule();
        // The deployer must have mined a salt giving this address EXACTLY the required flag bits —
        // extra bits would make the PoolManager invoke callbacks this contract does not implement.
        if (uint160(address(this)) & ALL_FLAG_MASK != REQUIRED_FLAGS) revert BadFlags();
        poolManager = IPoolManager(c.poolManager);
        qpull = c.qpull;
        weth = c.weth;
        qpullIs0 = c.qpull < c.weth;
        canonicalFee = c.fee;
        canonicalTickSpacing = c.tickSpacing;
        treasury = c.treasury;
        packRegistry = IPackRegistry(c.packRegistry);
        leaderboardRegistry = ILeaderboardRegistry(c.leaderboardRegistry);
        nft = INFTCollection(c.nft);
        exemptSender = c.exemptSender;
        initializer = c.initializer;
        earlyBuyCapWei = c.earlyBuyCapWei;
    }

    /// @notice True iff `key` is the one pool this hook serves: address-sorted QPULL/WETH at the
    ///         canonical fee/tickSpacing. (key.hooks == this always holds inside our callbacks —
    ///         the PoolManager dispatches to key.hooks.)
    function isCanonical(PoolKey calldata key) public view returns (bool) {
        (address lo, address hi) = qpullIs0 ? (qpull, weth) : (weth, qpull);
        return Currency.unwrap(key.currency0) == lo && Currency.unwrap(key.currency1) == hi
            && key.fee == canonicalFee && key.tickSpacing == canonicalTickSpacing;
    }

    // ─── V4 callbacks ────────────────────────────────────────────────────────

    /// @notice Pool creation control + launch stamp. initialize() is permissionless on the PoolManager,
    ///         so this is where the hook decides which pools may exist with it attached: exactly one —
    ///         the canonical pool, created by the deployer. Reverting here reverts initialize().
    function afterInitialize(address sender, PoolKey calldata key, uint160, int24)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (!isCanonical(key)) revert NotCanonicalPool(); // no QPULL/junk reward-farm pools
        if (sender != initializer) revert NotInitializer(); // no front-run burning the gate window
        if (!nft.launched()) revert MintStillOpen(); // swap/pool cannot open until the mint is closed (finalizeLaunch)
        // initialize() can only succeed once per pool id, so launchTime is written exactly once.
        launchTime = block.timestamp;
        emit Launched(block.timestamp);
        return this.afterInitialize.selector;
    }

    /// @notice Liquidity provision is restricted to the protocol (audit F6 / pass-4 F4). The 4% tax fires on
    ///         SWAPS (afterSwap); adding/removing liquidity is NOT a swap, so V4 charges no tax on it. Left
    ///         open, that is an untaxed side-door to acquire/dispose QPULL: seed single-sided liquidity just
    ///         off spot, let other traders' TAXED swaps push price through the range so the position converts
    ///         (WETH->QPULL to buy, QPULL->WETH to sell), then withdraw — QPULL moved at 0% instead of 4%,
    ///         starving the prize funding. BOTH add and remove are gated to the pool's `initializer` (audit
    ///         L1 / job-745 added the symmetric remove gate): gating add restricts who can create a position,
    ///         and gating remove is defense-in-depth so that even if a position were ever slipped in via a
    ///         phished-initializer add (the tx.origin branch), a non-initializer still cannot withdraw it.
    ///         Identity is `sender` (a protocol LP-manager contract) OR `tx.origin` (the initializer EOA
    ///         signing through a router) — the same unspoofable identity the launch gate uses. Fails
    ///         closed. Trade-off (accepted): no permissionless community LP; protocol LP withdrawal must also
    ///         be signed by / routed as the initializer.
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        _onlyProtocolLp(sender, key);
        return this.beforeAddLiquidity.selector;
    }

    /// @notice Symmetric to beforeAddLiquidity (audit L1 / job-745): removing liquidity is also gated to the
    ///         protocol, so a position that ever slipped in cannot be withdrawn untaxed by a non-initializer.
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4) {
        _onlyProtocolLp(sender, key);
        return this.beforeRemoveLiquidity.selector;
    }

    /// @dev Shared LP gate: canonical pool only, and the liquidity provider must be the protocol — either a
    ///      protocol LP-manager contract calling modifyLiquidity directly (sender) or the initializer EOA
    ///      signing through a router (tx.origin). A third party is neither.
    function _onlyProtocolLp(address sender, PoolKey calldata key) internal view {
        if (!isCanonical(key)) revert NotCanonicalPool(); // this hook serves exactly one pool
        if (sender != initializer && tx.origin != initializer) revert LiquidityRestricted();
    }

    /// @notice The tax. Takes 4% of the swap's unspecified currency for the Treasury, enforces the
    ///         2-hour launch holder gate on buys, and notifies the game registries.
    /// @param  sender The address that called PoolManager.swap (a router — NOT the human swapper).
    /// @return selector + the hook's fee as a positive unspecified-currency delta (the swapper pays it).
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata // hookData: deliberately IGNORED — caller-supplied, cannot be trusted for identity
    ) external onlyPoolManager nonReentrant returns (bytes4, int128) {
        if (!isCanonical(key)) revert NotCanonicalPool(); // unreachable (afterInitialize), defense-in-depth

        // The protocol's own conversion path (Treasury -> QpullWethAdapter -> this pool) is exempt:
        // taxing it would just loop Treasury money back to the Treasury minus slippage. `sender` is the
        // PoolManager's msg.sender — the adapter contract itself — so this cannot be impersonated.
        if (sender == exemptSender) return (this.afterSwap.selector, 0);

        // Trade facts, all derived from swap params + the pool's own delta. None are caller-claimable.
        // `grossWeth` is the ETH-side value of the trade (WETH paid on a buy, WETH received on a sell).
        // Game credit — packs, leaderboard XP — is priced off THIS, not the QPULL amount:
        // a ticket costs a fixed amount of ETH-in regardless of pool depth or slippage (1 ticket per
        // `ticketPrice` of WETH, e.g. ~$10). This makes ticketing predictable and pool-independent.
        bool isBuy = qpullIs0 ? !params.zeroForOne : params.zeroForOne; // buy = QPULL flows out to swapper
        uint256 grossQpull = _abs(qpullIs0 ? delta.amount0() : delta.amount1()); // QPULL trade size (TaxTaken event)
        uint256 grossWeth = _abs(qpullIs0 ? delta.amount1() : delta.amount0()); // ETH-in value — basis for game credit

        // Launch holder gate (spec §16, GATE_DURATION() = 2h), buys only. tx.origin — not hookData, not `sender` — is the
        // one identity a sniper cannot delegate away: the EOA that signed this transaction. Fails closed.
        // Inside that same window a holder is also throttled: a size cap, a per-wallet buy count and a
        // per-wallet cooldown, all on the SAME tx.origin so gate and throttle cannot disagree on identity.
        if (isBuy && launchTime != 0 && block.timestamp < launchTime + GATE_DURATION()) {
            if (nft.balanceOf(tx.origin) == 0) revert Gated();
            _throttleEarlyBuy(tx.origin, _buyWethIn(params.amountSpecified, grossWeth));
        }

        // 4% of the unspecified currency: the output on exact-input swaps, the input on exact-output
        // swaps (v4-core Hooks.sol mapping). Positive return = swapper pays; hook is credited and
        // clears its credit by take()-ing the fee to the Treasury inside this same unlock.
        bool unspecifiedIs1 = (params.amountSpecified < 0) == params.zeroForOne;
        int128 unspecified = unspecifiedIs1 ? delta.amount1() : delta.amount0();
        // Buys are flat 4%. Sells decay from 20% to 4% over the first 48h (-4pp per 12h step) — a sell-only
        // launch anti-dump. After 48h, both sides are 4%.
        uint256 taxBps = TAX_BPS;
        if (!isBuy && launchTime != 0 && block.timestamp < launchTime + SELL_DECAY()) {
            uint256 step = (block.timestamp - launchTime) / SELL_STEP(); // 0..3 across the shipped 48h/12h
            // SATURATING schedule (pre-audit hardening): floor at TAX_BPS instead of a bare subtraction.
            // With the shipped 48h/12h (and testnet 20m/5m) values the max step is 3, so the result is
            // UNCHANGED: 2000 / 1600 / 1200 / 800. But SELL_DECAY() and SELL_STEP() are virtual and nothing
            // ties them to the two BPS constants: a subclass with a longer decay or a smaller step (e.g.
            // 60m/5m -> step 11) would drive `SELL_TAX_START_BPS - step * SELL_STEP_BPS` below zero, and
            // the 0.8 checked underflow would REVERT every sell in the window tail — a silent sell DoS this
            // immutable hook could never fix. Flooring cannot underflow: a mis-set subclass degrades to the
            // flat 4% early, never to a dead pool, and the sell tax never dips below the buy tax either way.
            uint256 decayBps = step * SELL_STEP_BPS;
            taxBps = decayBps >= SELL_TAX_START_BPS - TAX_BPS ? TAX_BPS : SELL_TAX_START_BPS - decayBps;
        }
        uint256 fee = (_abs(unspecified) * taxBps) / BPS;
        Currency feeCurrency = unspecifiedIs1 ? key.currency1 : key.currency0;
        if (fee > 0) {
            poolManager.take(feeCurrency, treasury, fee);
        }

        // Game notifications (spec §4/§11), credited to the signer, on BUYS ONLY — sells record nothing
        // game-side. try/catch: an immutable hook must never let a registry fault brick the canonical pool
        // — a failed record costs only that trade's rewards and is surfaced via RecordFailed.
        if (isBuy && grossWeth > 0 && fee > 0) { // audit L-2 (pass-7): a zero-tax (sub-25-unit dust) swap earns no game credit
            try packRegistry.recordBuy(tx.origin, grossWeth) { } // tickets = grossWeth / ticketPrice(WETH)
            catch {
                emit RecordFailed("pack", tx.origin, grossWeth);
            }
            try leaderboardRegistry.recordBuy(tx.origin, grossWeth) { }
            catch {
                emit RecordFailed("leaderboard", tx.origin, grossWeth);
            }
        }

        emit TaxTaken(tx.origin, isBuy, grossQpull, Currency.unwrap(feeCurrency), fee);

        // fee <= |unspecified| / 5 (taxBps peaks at SELL_TAX_START_BPS = 20% during the launch sell window;
        // / 25 at the flat 4% otherwise) and |unspecified| fits int128, so the cast cannot overflow.
        return (this.afterSwap.selector, int128(int256(fee)));
    }

    /// @notice The WETH a buyer actually spends on this buy, measured exactly from the swap's own delta.
    ///         No oracle, no pool price, no approximation, and nothing the caller can claim.
    /// @dev    Two paths, and only two, because V4 has only two swap kinds. Buys always pay WETH in:
    ///           - EXACT INPUT (amountSpecified < 0): WETH is the SPECIFIED currency, so the WETH half of
    ///             `delta` is the whole input (it is what actually moved, which is the right number even
    ///             when a price limit part-fills the swap and less than amountSpecified is spent). The 4%
    ///             hook fee on this path is taken from the QPULL output, not from WETH, so the wallet's
    ///             WETH outlay is exactly `poolWeth`;
    ///           - EXACT OUTPUT (amountSpecified > 0): QPULL is specified, so WETH is the UNSPECIFIED
    ///             currency and afterSwap's positive return charges the fee IN WETH ON TOP of the WETH
    ///             `delta` (v4-core: swapDelta -= hookDelta, the swapper pays it). The wallet therefore
    ///             parts with `poolWeth` plus that fee. Buys are flat TAX_BPS (the decaying sell schedule
    ///             never applies here), so this reproduces the fee computed below EXACTLY, to the wei;
    ///             the two must be read together, and both round down identically.
    ///         amountSpecified == 0 cannot reach us: v4-core rejects it (SwapAmountCannotBeZero).
    ///         Every buy path is therefore measurable in afterSwap. The one thing that is NOT knowable
    ///         here is WHO is behind a buy when several buyers share a signer, see the tx.origin note in
    ///         the contract header, and that is an identity limit, not a measurement one.
    function _buyWethIn(int256 amountSpecified, uint256 poolWeth) internal pure returns (uint256) {
        if (amountSpecified < 0) return poolWeth; // exact input: the fee is charged in QPULL
        return poolWeth + (poolWeth * TAX_BPS) / BPS; // exact output: the fee is charged in WETH on top
    }

    /// @notice Launch throttle for one buyer. Runs ONLY inside the 2-hour gate window, only on buys, and
    ///         only for a wallet that already passed the holder gate.
    /// @dev    Checks then effects, in one internal call with no external call in between, so the counter
    ///         cannot be observed half-updated. Each rejection has its own error: an integrator, or a
    ///         front end, can tell "too big" from "too soon" from "out of buys" without guessing.
    ///         Deliberately keyed on tx.origin, matching the gate exactly, with the account-abstraction
    ///         limitation documented in the contract header.
    function _throttleEarlyBuy(address buyer, uint256 wethIn) internal {
        EarlyBuyer memory s = earlyBuyer[buyer];
        // Size cap covers only a wallet's FIRST EARLY_BUY_COUNT buys of the window; buys after that are uncapped
        // (no hard buy limit). The cooldown still spaces EVERY gated buy, and the holder gate still applies.
        if (s.buys < EARLY_BUY_COUNT && wethIn > earlyBuyCapWei) revert EarlyBuyTooLarge();
        if (s.lastBuyAt != 0 && block.timestamp < uint256(s.lastBuyAt) + BUY_COOLDOWN()) revert BuyCooldown();
        // uint64 holds timestamps past year 2500; buys just counts up (uint32 cannot overflow in one window).
        earlyBuyer[buyer] = EarlyBuyer({ lastBuyAt: uint64(block.timestamp), buys: s.buys + 1 });
    }

    function _abs(int128 x) internal pure returns (uint256) {
        // promote before negating so type(int128).min cannot overflow
        return x < 0 ? uint256(-int256(x)) : uint256(int256(x));
    }
}
