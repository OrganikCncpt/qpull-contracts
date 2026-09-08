// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager, PoolKey, Currency } from "../src/interfaces/IPoolManager.sol";
import { IPoolManager as IV4PoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolId } from "v4-core/types/PoolId.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { Position } from "v4-core/libraries/Position.sol";
import { QpullLiquidityLock } from "../src/QpullLiquidityLock.sol";
import { QpullTaxHook } from "../src/hooks/QpullTaxHook.sol";
import { Treasury } from "../src/Treasury.sol";

/// @dev The one real-WETH9 call this script makes (wrap only; there is no unwrap path in a go-live).
interface IWETH {
    function deposit() external payable;
}

/// @notice GO-LIVE (MAINNET). The single reviewed script that takes the Deploy.s.sol protocol live. It
///         closes the two pre-audit MEDIUMs (convert caps never armed; LP not routed through the permanent
///         lock) and the lockRouting-in-deploy-tx info by doing, IN THIS ORDER, from the deployer key:
///
///           1. Treasury.setMaxConvertPerCall + setMaxWethConvertPerCall   (pool-sized; convert() is
///              fail-CLOSED / NotConfigured until both are armed)
///           2. deploy QpullLiquidityLock (opener = this deployer; the ONLY key that can trigger its seed)
///           3. poolManager.initialize(canonicalKey, SQRT_PRICE_X96)   <- afterInitialize stamps launchTime:
///              the first-hour holder gate + sell-tax decay clocks start HERE
///           4. wrap LP_ETH -> WETH, move it + 100% of the deployer's QPULL into the lock, lock.seed(LP_LIQUIDITY)
///              (the lock owns the full-range position and has NO remove/withdraw/collect path: unremovable)
///           5. on-chain asserts: lock.seeded()==true; the canonical position keyed by (lock, tickLower,
///              tickUpper) holds exactly LP_LIQUIDITY and equals the pool's whole liquidity; deployer residual
///              QPULL == 0; stranded residual in the lock <= MAX_LOCK_RESIDUAL_BPS per side; launchTime != 0;
///              both caps != 0 && != type(uint256).max
///           6. Treasury.lockRouting()   <- LAST: the adapters/PoolKey/destinations are frozen only once the
///              pool exists and everything above has been checked
///
///         RUN FROM THE DEPLOYER KEY (= the hook's `initializer` = the Treasury owner = the QPULL holder):
///           forge script script/GoLiveMainnet.s.sol --tc GoLiveMainnet --rpc-url rh --account deployer
///           forge script script/GoLiveMainnet.s.sol --tc GoLiveMainnet --rpc-url rh --account deployer --broadcast
///         `msg.sender` MUST be the initializer: `initialize` is initializer-gated (NotInitializer) and the
///         hook's beforeAddLiquidity gate admits the lock's seed only because `tx.origin == initializer`.
///         --account sets the sender; with a raw --private-key add `--sender <deployer>` as well.
///
///         PREREQUISITE: the pass mint is CLOSED, i.e. NFTCollection.finalizeLaunch() has run (nft.launched()
///         == true). The hook's afterInitialize reverts MintStillOpen otherwise; preflight (c) reads the NFT
///         through the hook's immutable `nft` (no extra env) and refuses first with a readable error.
///
///         ENV (ALL REQUIRED - vm.envAddress/vm.envUint revert if unset, so a missing input fails closed):
///           POOL_MANAGER, QPULL, WETH, TREASURY, HOOK   addresses from the Deploy.s.sol output (each is
///                                                       cross-checked against the hook's immutables)
///           LP_ETH                      wei of the deployer's ETH wrapped into the WETH side of the LP
///           SQRT_PRICE_X96              initial pool price: sqrt(currency1 per currency0) * 2^96, with the
///                                       currencies address-sorted exactly as the canonical key
///           LP_LIQUIDITY                v4 liquidity units, sized OFF-CHAIN so a full-range position at
///                                       SQRT_PRICE_X96 consumes LP_ETH AND 100% of the QPULL supply
///           MAX_CONVERT_PER_CALL        pool-sized QPULL ceiling per convert() (audit H-3)
///           MAX_WETH_CONVERT_PER_CALL   pool-sized WETH ceiling per convert() (audit H-1)
///         fee / tickSpacing are NOT env: the hook admits exactly one key (isCanonical), so they are read
///         from its immutables. Anything else would be a footgun.
///
///         WETH CHOICE: this script WRAPS the LP ETH from the broadcaster's own balance (IWETH.deposit on
///         the real WETH). The pass mint pays the deployer in ETH, so no pre-held WETH is required and any
///         WETH the deployer already holds is left untouched. Hold LP_ETH + gas before running.
///
///         SIZING: the lock has NO path out, so whatever the seed does not consume is stranded forever.
///         Pick SQRT_PRICE_X96 from the LP_ETH : supply ratio and LP_LIQUIDITY to consume both; the script
///         refuses (step 5) if more than MAX_LOCK_RESIDUAL_BPS of either side would be left in the lock.
///
///         ATOMICITY: forge simulates the whole run before broadcasting, so a failed require sends NOTHING.
///         If a tx reverts on-chain after simulation passed, continue by hand: `initialize` cannot be
///         repeated, and a re-run refuses (launchTime != 0) rather than re-seeding.
contract GoLiveMainnet is Script {
    uint256 internal constant BPS = 10_000;
    /// @dev Max the seed may leave STRANDED in the lock, per side, in bps of what was sent. A correctly
    ///      sized full-range seed leaves rounding dust (wei); a mis-sized one would lock a large share of
    ///      the supply as untradeable, unrecoverable dust. 0.5% is a generous upper bound on "dust".
    uint256 internal constant MAX_LOCK_RESIDUAL_BPS = 50;

    // Env + hook-derived config packed into a struct (stack-too-deep hygiene, as in GoLiveTestnet).
    struct GL {
        address poolManager;
        address qpull;
        address weth;
        address treasury;
        address hook;
        uint24 fee; // from the hook's canonicalFee (not env)
        int24 tickSpacing; // from the hook's canonicalTickSpacing (not env)
        uint160 sqrtPriceX96;
        uint256 lpEth;
        uint128 liq;
        uint256 maxConvertPerCall;
        uint256 maxWethConvertPerCall;
    }

    function run() external {
        GL memory g = _env();
        address me = msg.sender; // deployer = hook initializer = Treasury owner = lock opener (see header)
        _preflight(g, me);
        PoolKey memory key = _canonicalKey(g);
        QpullLiquidityLock lock = _goLive(g, key, me);
        _report(g, address(lock));
    }

    function _env() internal view returns (GL memory g) {
        // Every value is REQUIRED: vm.envAddress / vm.envUint revert when unset, so the go-live fails closed
        // in simulation before a single tx is broadcast.
        g.poolManager = vm.envAddress("POOL_MANAGER");
        g.qpull = vm.envAddress("QPULL");
        g.weth = vm.envAddress("WETH");
        g.treasury = vm.envAddress("TREASURY");
        g.hook = vm.envAddress("HOOK");
        uint256 sqrtP = vm.envUint("SQRT_PRICE_X96");
        require(sqrtP > 0 && sqrtP <= type(uint160).max, "go-live: SQRT_PRICE_X96 out of uint160 range");
        // casting to 'uint160' is safe because the require above bounds it to the uint160 range
        // forge-lint: disable-next-line(unsafe-typecast)
        g.sqrtPriceX96 = uint160(sqrtP);
        g.lpEth = vm.envUint("LP_ETH");
        require(g.lpEth > 0, "go-live: LP_ETH must be > 0");
        uint256 liq = vm.envUint("LP_LIQUIDITY");
        require(liq > 0 && liq <= type(uint128).max, "go-live: LP_LIQUIDITY out of uint128 range");
        // casting to 'uint128' is safe because the require above bounds it to the uint128 range
        // forge-lint: disable-next-line(unsafe-typecast)
        g.liq = uint128(liq);
        g.maxConvertPerCall = vm.envUint("MAX_CONVERT_PER_CALL");
        g.maxWethConvertPerCall = vm.envUint("MAX_WETH_CONVERT_PER_CALL");
        // The canonical fee/tickSpacing are the hook's immutables (the only key it admits). Read the source
        // of truth rather than trusting an env copy of it.
        g.fee = QpullTaxHook(g.hook).canonicalFee();
        g.tickSpacing = QpullTaxHook(g.hook).canonicalTickSpacing();
    }

    /// @dev Everything that must be true BEFORE any tx is sent. All view; reverts fail the simulation.
    function _preflight(GL memory g, address me) internal view {
        QpullTaxHook h = QpullTaxHook(g.hook);
        Treasury t = Treasury(g.treasury);
        // (a) the broadcaster IS the hook's initializer: initialize() is gated to it, the lock's seed passes
        //     the LP gate via tx.origin == initializer, and the lock's opener is pinned to it below.
        require(h.initializer() == me, "go-live: sender is not the hook initializer (use --account / --sender)");
        // (b) the env addresses agree with what the hook was built against (a mistyped env fails closed).
        require(address(h.poolManager()) == g.poolManager, "go-live: POOL_MANAGER != hook.poolManager");
        require(h.qpull() == g.qpull, "go-live: QPULL != hook.qpull");
        require(h.weth() == g.weth, "go-live: WETH != hook.weth");
        require(h.treasury() == g.treasury, "go-live: TREASURY != hook.treasury");
        // (c) the mint is closed, not already live, and the Treasury is ours to finish and lock. The NFT is the
        //     hook's immutable (not env): afterInitialize would revert MintStillOpen on a premature run, so
        //     refuse here, before any tx, with a message that names the missing step.
        require(h.nft().launched(), "go-live: NFT mint not finalized (run NFTCollection.finalizeLaunch first)");
        require(h.launchTime() == 0, "go-live: pool already initialized (launchTime != 0)");
        require(t.owner() == me, "go-live: sender is not the Treasury owner");
        require(!t.routingLocked(), "go-live: Treasury routing already locked");
        // (d) the caps are real pool-sized ceilings: never 0 (the setter rejects it) and never the old
        //     fail-open type(uint256).max.
        require(
            g.maxConvertPerCall != 0 && g.maxConvertPerCall != type(uint256).max,
            "go-live: MAX_CONVERT_PER_CALL must be a pool-sized value"
        );
        require(
            g.maxWethConvertPerCall != 0 && g.maxWethConvertPerCall != type(uint256).max,
            "go-live: MAX_WETH_CONVERT_PER_CALL must be a pool-sized value"
        );
        // (e) "100% of supply to LP" starts with 100% of supply in the deployer's hands; and the ETH to wrap.
        require(
            IERC20(g.qpull).balanceOf(me) == IERC20(g.qpull).totalSupply(),
            "go-live: deployer does not hold 100% of the QPULL supply"
        );
        require(me.balance >= g.lpEth, "go-live: deployer ETH balance < LP_ETH (gas is on top)");
    }

    /// @dev The canonical QPULL/WETH key: address-sorted currencies + the hook's fee/tickSpacing + the hook.
    function _canonicalKey(GL memory g) internal view returns (PoolKey memory key) {
        (address c0, address c1) = g.qpull < g.weth ? (g.qpull, g.weth) : (g.weth, g.qpull); // V4: currency0 < currency1
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: g.fee,
            tickSpacing: g.tickSpacing,
            hooks: g.hook
        });
        require(QpullTaxHook(g.hook).isCanonical(key), "go-live: key is not the hook's canonical pool");
    }

    function _goLive(GL memory g, PoolKey memory key, address me) internal returns (QpullLiquidityLock lock) {
        Treasury t = Treasury(g.treasury);
        vm.startBroadcast();

        // 1. ARM THE CONVERT CAPS (pre-audit MEDIUM). convert() reverts NotConfigured until both are set, so
        //    the H-1/H-3 donation-brick + keeper-MEV bounds can never be silently left off at launch.
        t.setMaxConvertPerCall(g.maxConvertPerCall);
        t.setMaxWethConvertPerCall(g.maxWethConvertPerCall);

        // 2. THE PERMANENT LOCK. opener = the deployer: the only key that can trigger its one-shot seed.
        lock = new QpullLiquidityLock(
            IPoolManager(g.poolManager), g.qpull, g.weth, g.fee, g.tickSpacing, g.hook, me
        );

        // 3. CREATE THE POOL WITH THE HOOK (sender = initializer). afterInitialize stamps launchTime: the
        //    first-hour holder gate and the sell-tax decay start now, so the seed follows back-to-back.
        IPoolManager(g.poolManager).initialize(key, g.sqrtPriceX96);

        // 4. SEED 100% OF SUPPLY THROUGH THE LOCK (never a direct add: a deployer-owned position would be
        //    removable via the hook's tx.origin == initializer branch; the lock's position is not).
        IWETH(g.weth).deposit{ value: g.lpEth }(); // wrap the deployer's ETH -> real WETH
        require(IERC20(g.weth).transfer(address(lock), g.lpEth), "go-live: WETH transfer to lock failed");
        // The deployer's ENTIRE QPULL balance (== total supply, asserted in preflight), not a hand-typed
        // amount, so under-seeding is impossible.
        require(
            IERC20(g.qpull).transfer(address(lock), IERC20(g.qpull).balanceOf(me)),
            "go-live: QPULL transfer to lock failed"
        );
        lock.seed(g.liq); // one-shot; the position is owned by the lock and permanently unremovable

        // 5. ON-CHAIN ASSERTS (evaluated in simulation against the post-seed state; any failure = no broadcast)
        _assertSeeded(g, key, lock, me);

        // 6. LOCK ROUTING - LAST. Freezes the adapters, their PoolKey binding and the four payout
        //    destinations forever, only now that the pool exists and the seed has been verified.
        t.lockRouting();
        vm.stopBroadcast();

        require(t.routingLocked(), "go-live: routing not locked");
    }

    /// @dev The post-seed facts the "can't rug" + "bounded convert" guarantees rest on, checked on-chain.
    function _assertSeeded(GL memory g, PoolKey memory key, QpullLiquidityLock lock, address me) internal view {
        IV4PoolManager pm = IV4PoolManager(g.poolManager);
        // (i) the one-shot latch fired
        require(lock.seeded(), "go-live: lock.seeded() != true");
        // (ii) the canonical position is OWNED BY THE LOCK. v4 keys positions by (owner, tickLower, tickUpper,
        //      salt) and only the owner can ever modify one, so a position of exactly `liq` under the lock's
        //      key IS the ownership proof. PoolId = keccak256(abi.encode(key)) (v4 PoolIdLibrary.toId; the
        //      local PoolKey struct mirrors v4's field-for-field).
        PoolId poolId = PoolId.wrap(keccak256(abi.encode(key)));
        bytes32 posKey = Position.calculatePositionKey(address(lock), lock.tickLower(), lock.tickUpper(), bytes32(0));
        require(
            StateLibrary.getPositionLiquidity(pm, poolId, posKey) == g.liq,
            "go-live: canonical position is not owned by the lock"
        );
        // (iii) ...and it is the ONLY liquidity in the pool: no removable side position slipped in. (Full
        //       range is always in range, so the pool's active liquidity equals the lock's position.)
        require(StateLibrary.getLiquidity(pm, poolId) == g.liq, "go-live: pool liquidity != the lock's position");
        // (iv) the deployer holds NO QPULL: 100% of supply left it for the no-remove lock.
        require(IERC20(g.qpull).balanceOf(me) == 0, "go-live: QPULL not 100% seeded to the lock");
        // (v) sizing: the seed CONSUMED the balances. Whatever stays in the lock is stranded forever, so a
        //     residual above dust means LP_LIQUIDITY / SQRT_PRICE_X96 were mis-sized. Refuse.
        require(
            IERC20(g.qpull).balanceOf(address(lock)) <= (IERC20(g.qpull).totalSupply() * MAX_LOCK_RESIDUAL_BPS) / BPS,
            "go-live: QPULL residual stranded in the lock exceeds dust (LP_LIQUIDITY / SQRT_PRICE_X96 mis-sized)"
        );
        require(
            IERC20(g.weth).balanceOf(address(lock)) <= (g.lpEth * MAX_LOCK_RESIDUAL_BPS) / BPS,
            "go-live: WETH residual stranded in the lock exceeds dust (LP_LIQUIDITY / SQRT_PRICE_X96 mis-sized)"
        );
        // (vi) launch stamped, and both convert caps armed to real values.
        require(QpullTaxHook(g.hook).launchTime() != 0, "go-live: launchTime not stamped by initialize");
        Treasury t = Treasury(g.treasury);
        require(
            t.maxConvertPerCall() != 0 && t.maxConvertPerCall() != type(uint256).max,
            "go-live: maxConvertPerCall not armed"
        );
        require(
            t.maxWethConvertPerCall() != 0 && t.maxWethConvertPerCall() != type(uint256).max,
            "go-live: maxWethConvertPerCall not armed"
        );
    }

    function _report(GL memory g, address lock) internal view {
        console2.log("GO-LIVE (mainnet) complete. Pool created; 100% of supply seeded into the PERMANENT lock.");
        console2.log("  hook (initializer-gated)                         ", g.hook);
        console2.log("  LIQUIDITY LOCK (owns the position, no remove path)", lock);
        console2.log("  seeded WETH (wei)                                ", g.lpEth);
        console2.log("  liquidity units                                  ", uint256(g.liq));
        console2.log("  sqrtPriceX96                                     ", uint256(g.sqrtPriceX96));
        console2.log("  QPULL left in the lock (stranded dust, wei)      ", IERC20(g.qpull).balanceOf(lock));
        console2.log("  WETH left in the lock (stranded dust, wei)       ", IERC20(g.weth).balanceOf(lock));
        console2.log("  Treasury.maxConvertPerCall                       ", g.maxConvertPerCall);
        console2.log("  Treasury.maxWethConvertPerCall                   ", g.maxWethConvertPerCall);
        console2.log("  Treasury.routingLocked                           ", Treasury(g.treasury).routingLocked());
        console2.log("NOTE: the first-hour holder gate is now OPEN. Start the keeper; convert() is armed and routing is final.");
    }
}
