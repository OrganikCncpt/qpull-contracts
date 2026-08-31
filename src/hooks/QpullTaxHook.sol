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
import { IPackRegistry, IJackpotRegistry, ILeaderboardRegistry } from "../interfaces/IRegistries.sol";
import { INFTCollection } from "../interfaces/INFTCollection.sol";

/// @title  QpullTaxHook — the 4% trade tax as a Uniswap-V4 hook (audit H-2 fix)
/// @notice Replaces QPULLToken's transfer tax, which is STRUCTURALLY INCOMPATIBLE with V4's flash
///         accounting: a token that skims transfers breaks `settle()` (CurrencyNotSettled) for every
///         router that trades it. Instead, the canonical QPULL/WETH pool deploys WITH this hook, and
///         the tax becomes a swap fee taken inside the locked context:
///           - afterSwap takes 4% of the swap's UNSPECIFIED currency and sends it to the Treasury
///             (buys pay in QPULL, exact-in sells pay in WETH — the Treasury converts both, spec §3);
///           - the game registries are notified exactly as the token used to do (spec §4/§10/§11):
///             buy -> pack tickets + leaderboard points + jackpot entry; sell -> jackpot entry;
///           - the first-hour NFT-holder gate (spec §16) is enforced on buys.
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
///             first-hour gate. tx.origin cannot be spoofed; the cost is that ERC-4337 buys credit
///             the bundler (acceptable: rewards mis-credit, never mis-charge — the fee itself is
///             always paid by the actual swapper via the hook delta). SAME TRADEOFF, KNOWN LIMIT:
///             during the first hour a holder who holds the NFT in a SMART-CONTRACT WALLET (Safe/AA)
///             is gated, because balanceOf(tx.origin=signer) is 0 — the NFT is the wallet's. This is
///             an accepted first-hour-only cost of using an unspoofable identity; such holders buy
///             freely once the gate self-expires (and can hold the NFT on the signing EOA to buy in
///             the first hour). Widening the gate to any contract's balance would reopen the spoof;
///           - the first-hour window is measured from POOL CREATION (afterInitialize), because that
///             is the only launch instant the hook can observe. Liquidity can only be added AFTER the
///             pool exists, so the runbook seeds LP immediately after initialize() — a long gap would
///             silently shorten the effective gate (no trading is possible until LP exists anyway);
///           - registry notification is try/catch: this hook is immutable, so a reverting registry
///             must only ever cost that trade's rewards (RecordFailed event), never brick the pool.
///             The fee take() and the gate are NOT try/caught — fee delivery and the gate fail closed.
///           - afterSwap is `nonReentrant` (transient guard). Reentrancy is already prevented by the
///             PoolManager's unlock-lock, onlyPoolManager, and trusted storage-only registries, and the
///             hook has NO mutable per-swap state to corrupt — so this is belt-and-braces (a Certora
///             hook-checklist item). It does NOT block multi-hop routing (sequential afterSwap calls,
///             not nested); it only bars a true nested re-entry, which cannot happen anyway.
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
///             launch, stamping launchTime early and burning the first-hour gate), and no other
///             PoolKey may attach this hook at all (otherwise a QPULL/junk pool could farm registry
///             rewards through afterSwap).
contract QpullTaxHook is ReentrancyGuardTransient {
    using BalanceDeltaLib for BalanceDelta;

    // ─── constants ───────────────────────────────────────────────────────────
    uint256 public constant TAX_BPS = 400; // 4% — immutable by construction, no owner can change it
    uint256 internal constant BPS = 10_000;
    uint256 public constant GATE_DURATION = 1 hours; // spec §16 first-hour holder gate

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
    IJackpotRegistry public immutable jackpotRegistry;
    ILeaderboardRegistry public immutable leaderboardRegistry;
    INFTCollection public immutable nft; // first-hour gate membership
    address public immutable exemptSender; // the Treasury's QpullWethAdapter: convert() sells untaxed
    address public immutable initializer; // the ONLY address allowed to create the canonical pool

    uint256 public launchTime; // stamped by afterInitialize — opens the first-hour gate window

    struct HookConfig {
        address poolManager;
        address qpull;
        address weth;
        uint24 fee;
        int24 tickSpacing;
        address treasury;
        address packRegistry;
        address jackpotRegistry;
        address leaderboardRegistry;
        address nft;
        address exemptSender;
        address initializer;
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
    error Gated();
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
                || c.treasury == address(0) || c.packRegistry == address(0) || c.jackpotRegistry == address(0)
                || c.leaderboardRegistry == address(0) || c.nft == address(0) || c.exemptSender == address(0)
                || c.initializer == address(0)
        ) revert ZeroAddress();
        if (c.fee > 1_000_000) revert BadFee(); // static LP fee only, <= 100% (dynamic sentinel 0x800000 > 1M)
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
        jackpotRegistry = IJackpotRegistry(c.jackpotRegistry);
        leaderboardRegistry = ILeaderboardRegistry(c.leaderboardRegistry);
        nft = INFTCollection(c.nft);
        exemptSender = c.exemptSender;
        initializer = c.initializer;
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
    ///         signing through a router) — the same unspoofable identity the first-hour gate uses. Fails
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
    ///         first-hour holder gate on buys, and notifies the game registries.
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

        // Trade facts, all derived from swap params + the pool's own delta (pre-hook-fee, so `gross`
        // matches the old token semantics of "gross trade size in QPULL"). None are caller-claimable.
        bool isBuy = qpullIs0 ? !params.zeroForOne : params.zeroForOne; // buy = QPULL flows out to swapper
        int128 qpullSigned = qpullIs0 ? delta.amount0() : delta.amount1();
        uint256 grossQpull = _abs(qpullSigned);

        // First-hour holder gate (spec §16), buys only. tx.origin — not hookData, not `sender` — is the
        // one identity a sniper cannot delegate away: the EOA that signed this transaction. Fails closed.
        if (isBuy && launchTime != 0 && block.timestamp < launchTime + GATE_DURATION) {
            if (nft.balanceOf(tx.origin) == 0) revert Gated();
        }

        // 4% of the unspecified currency: the output on exact-input swaps, the input on exact-output
        // swaps (v4-core Hooks.sol mapping). Positive return = swapper pays; hook is credited and
        // clears its credit by take()-ing the fee to the Treasury inside this same unlock.
        bool unspecifiedIs1 = (params.amountSpecified < 0) == params.zeroForOne;
        int128 unspecified = unspecifiedIs1 ? delta.amount1() : delta.amount0();
        uint256 fee = (_abs(unspecified) * TAX_BPS) / BPS;
        Currency feeCurrency = unspecifiedIs1 ? key.currency1 : key.currency0;
        if (fee > 0) {
            poolManager.take(feeCurrency, treasury, fee);
        }

        // Game notifications (spec §4/§10/§11), credited to the signer. try/catch: an immutable hook
        // must never let a registry fault brick the canonical pool — a failed record costs only that
        // trade's rewards and is surfaced via RecordFailed.
        if (grossQpull > 0 && fee > 0) { // audit L-2 (pass-7): a zero-tax (sub-25-unit dust) swap earns no game credit
            if (isBuy) {
                try packRegistry.recordBuy(tx.origin, grossQpull) { }
                catch {
                    emit RecordFailed("pack", tx.origin, grossQpull);
                }
                try leaderboardRegistry.recordBuy(tx.origin, grossQpull) { }
                catch {
                    emit RecordFailed("leaderboard", tx.origin, grossQpull);
                }
            }
            try jackpotRegistry.recordTrade(tx.origin, grossQpull) { }
            catch {
                emit RecordFailed("jackpot", tx.origin, grossQpull);
            }
        }

        emit TaxTaken(tx.origin, isBuy, grossQpull, Currency.unwrap(feeCurrency), fee);

        // fee <= |unspecified| / 25 and |unspecified| fits int128, so the cast cannot overflow.
        return (this.afterSwap.selector, int128(int256(fee)));
    }

    function _abs(int128 x) internal pure returns (uint256) {
        // promote before negating so type(int128).min cannot overflow
        return x < 0 ? uint256(-int256(x)) : uint256(int256(x));
    }
}
