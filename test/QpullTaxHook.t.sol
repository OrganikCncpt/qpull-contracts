// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

// ─── the REAL Uniswap V4 core (vendored, tag v4.0.0) — the hook is tested against actual
//     PoolManager semantics, not a mock ────────────────────────────────────────────────────
import { PoolManager } from "v4-core/PoolManager.sol";
import { IPoolManager as IV4PoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks as IV4Hooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey as V4PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency as V4Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta as V4BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { CustomRevert } from "v4-core/libraries/CustomRevert.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";

// ─── ours ────────────────────────────────────────────────────────────────────────────────
import { QpullTaxHook } from "../src/hooks/QpullTaxHook.sol";
import { QpullWethAdapter } from "../src/adapters/QpullWethAdapter.sol";
import {
    IPoolManager as ourIPM,
    PoolKey,
    Currency,
    BalanceDelta as OurBalanceDelta
} from "../src/interfaces/IPoolManager.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { LeaderboardRegistry } from "../src/LeaderboardRegistry.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockNFT } from "./mocks/MockNFT.sol";
import { MockRecorder } from "./mocks/MockRecorder.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";

/// @notice QpullTaxHook (audit H-2) against the REAL v4-core PoolManager: fee mechanics in all four
///         swap shapes, first-hour gate, exemption, registry fan-out + try/catch, pool-creation
///         control, and the adapter's hooked-pool binding.
contract QpullTaxHookTest is Test {
    uint160 constant FLAGS = (1 << 12) | (1 << 11) | (1 << 9) | (1 << 6) | (1 << 2); // add+remove LP gate (0x1A44)
    uint160 constant SQRT_1_1 = 79_228_162_514_264_337_593_543_950_336; // 1:1
    uint160 constant MIN_PRICE_P1 = 4_295_128_739 + 1;
    uint160 constant MAX_PRICE_M1 = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342 - 1;
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    int24 constant FULL_LO = -887_220; // full range at spacing 60
    int24 constant FULL_HI = 887_220;

    PoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest liqRouter;

    MockERC20 qpull;
    MockERC20 weth;
    MockNFT nft;
    MockRecorder packRec;
    MockRecorder boardRec;

    QpullTaxHook hook;
    address hookAddr = address(uint160((0xAA << 16) | FLAGS));
    QpullWethAdapter adapter;

    address feeSink = makeAddr("feeSink"); // the hook's treasury (fee recipient)
    address treasury = makeAddr("treasury"); // the adapter's authorized swap caller
    address alice; // NFT holder
    address sniper; // not a holder

    bool qpullIs0;
    V4PoolKey key; // v4-core-typed key (routers/manager)

    function setUp() public {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IV4PoolManager(address(manager)));
        liqRouter = new PoolModifyLiquidityTest(IV4PoolManager(address(manager)));

        qpull = new MockERC20();
        weth = new MockERC20();
        qpullIs0 = address(qpull) < address(weth);
        nft = new MockNFT();
        packRec = new MockRecorder();
        boardRec = new MockRecorder();

        alice = makeAddr("alice");
        sniper = makeAddr("sniper");
        nft.set(1, alice, 0); // alice holds an NFT; sniper does not

        // production order: adapter first, then the hook naming it exemptSender (an immutable)
        adapter = new QpullWethAdapter(address(manager), address(qpull), address(weth), address(this));
        adapter.setTreasury(treasury);

        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(_cfg(address(packRec), address(boardRec), address(adapter))),
            hookAddr
        );
        hook = QpullTaxHook(hookAddr);

        key = V4PoolKey({
            currency0: V4Currency.wrap(qpullIs0 ? address(qpull) : address(weth)),
            currency1: V4Currency.wrap(qpullIs0 ? address(weth) : address(qpull)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IV4Hooks(hookAddr)
        });

        // liquidity + trader funding
        qpull.mint(address(this), 1e27);
        weth.mint(address(this), 1e27);
        qpull.approve(address(liqRouter), type(uint256).max);
        weth.approve(address(liqRouter), type(uint256).max);
        qpull.approve(address(swapRouter), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        for (uint256 i; i < 2; ++i) {
            address who = i == 0 ? alice : sniper;
            qpull.mint(who, 1e24);
            weth.mint(who, 1e24);
            vm.startPrank(who);
            qpull.approve(address(swapRouter), type(uint256).max);
            weth.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }

        manager.initialize(key, SQRT_1_1); // sender = this = the hook's initializer
        // audit F6: LP is now gated to the initializer via tx.origin — prank so tx.origin == this for the seed
        vm.prank(address(this), address(this));
        liqRouter.modifyLiquidity(key, IV4PoolManager.ModifyLiquidityParams(FULL_LO, FULL_HI, 1e24, 0), "");
    }

    function _cfg(address p, address b, address exempt)
        internal
        view
        returns (QpullTaxHook.HookConfig memory)
    {
        return QpullTaxHook.HookConfig({
            poolManager: address(manager),
            qpull: address(qpull),
            weth: address(weth),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            treasury: feeSink,
            packRegistry: p,
            leaderboardRegistry: b,
            nft: address(nft),
            exemptSender: exempt,
            initializer: address(this),
            // First-hour buy-size cap left effectively off in this fixture: the existing gate tests buy
            // 1e21 inside the window, and the throttle deserves its own dedicated suite.
            earlyBuyCapWei: type(uint256).max
        });
    }

    function _swap(address as_, bool zeroForOne, int256 amountSpecified) internal returns (V4BalanceDelta) {
        if (as_ != address(this)) vm.prank(as_, as_); // msg.sender AND tx.origin = the trader
        return swapRouter.swap(
            key,
            IV4PoolManager.SwapParams(zeroForOne, amountSpecified, zeroForOne ? MIN_PRICE_P1 : MAX_PRICE_M1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _buyZeroForOne() internal view returns (bool) {
        return !qpullIs0; // buy = QPULL flows out
    }

    function _pastGate() internal {
        vm.warp(block.timestamp + hook.GATE_DURATION() + 1);
    }

    // Warp past the 48h sell-tax decay window so sells settle at the flat 4% floor (and past the gate).
    function _pastSellDecay() internal {
        vm.warp(hook.launchTime() + hook.SELL_DECAY() + 1);
    }

    // ─── wiring sanity ───────────────────────────────────────────────────────

    /// The hook's hand-written callback signatures MUST hash to v4-core's IHooks selectors — this is
    /// what makes the PoolManager's calls land. Cross-checked against the vendored interface.
    function test_selectorsMatchV4Core() public pure {
        assertEq(QpullTaxHook.afterSwap.selector, IV4Hooks.afterSwap.selector, "afterSwap selector");
        assertEq(
            QpullTaxHook.afterInitialize.selector,
            IV4Hooks.afterInitialize.selector,
            "afterInitialize selector"
        );
    }

    function test_initializeStampsLaunchTime() public view {
        assertEq(hook.launchTime(), block.timestamp, "launchTime = pool creation");
    }

    function test_callbacksRejectNonPoolManager() public {
        vm.expectRevert(QpullTaxHook.NotPoolManager.selector);
        // a fake "buy" — if this were accepted, anyone could mint themselves tickets/points
        hook.afterSwap(
            address(this),
            _ourKey(),
            ourIPM.SwapParams(_buyZeroForOne(), -1e18, 0),
            OurBalanceDelta.wrap(0),
            ""
        );
        vm.expectRevert(QpullTaxHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), _ourKey(), SQRT_1_1, 0);
    }

    // ─── pool-creation control ───────────────────────────────────────────────

    function test_nonCanonicalPoolCannotAttachHook() public {
        V4PoolKey memory bad = key;
        bad.fee = 500; // wrong fee => not the canonical pool
        vm.expectRevert(); // NotCanonicalPool, wrapped by v4-core's hook-revert bubbling
        manager.initialize(bad, SQRT_1_1);
    }

    // audit F6 / pass-4 F4: liquidity provision is restricted to the protocol (the pool's initializer),
    // closing the untaxed LP side-door for acquiring/disposing QPULL.
    function test_F6_nonInitializerCannotAddLiquidity() public {
        address stranger = makeAddr("lpStranger");
        qpull.mint(stranger, 1e24);
        weth.mint(stranger, 1e24);
        vm.startPrank(stranger, stranger); // msg.sender AND tx.origin = stranger (not the initializer)
        qpull.approve(address(liqRouter), type(uint256).max);
        weth.approve(address(liqRouter), type(uint256).max);
        vm.expectRevert(); // LiquidityRestricted, wrapped by v4-core's hook-revert bubbling
        liqRouter.modifyLiquidity(key, IV4PoolManager.ModifyLiquidityParams(FULL_LO, FULL_HI, 1e24, 0), "");
        vm.stopPrank();
    }

    function test_F6_initializerCanAddLiquidity() public {
        // the protocol (initializer == this) can still provide liquidity — tx.origin == initializer
        qpull.mint(address(this), 1e24);
        weth.mint(address(this), 1e24);
        qpull.approve(address(liqRouter), type(uint256).max);
        weth.approve(address(liqRouter), type(uint256).max);
        vm.prank(address(this), address(this));
        liqRouter.modifyLiquidity(key, IV4PoolManager.ModifyLiquidityParams(FULL_LO, FULL_HI, 1e23, 0), "");
    }

    // audit L1 (job-745): removal is gated symmetrically to add — a third party cannot pull protocol
    // liquidity out of the canonical pool (beforeRemoveLiquidity applies the same initializer gate).
    function test_L1_nonInitializerCannotRemoveLiquidity() public {
        // setUp already seeded LP as the initializer; a stranger attempting a withdrawal hits the gate.
        address stranger = makeAddr("lpRemover");
        vm.startPrank(stranger, stranger); // msg.sender AND tx.origin = stranger (not the initializer)
        vm.expectRevert(); // LiquidityRestricted, wrapped by v4-core's hook-revert bubbling
        liqRouter.modifyLiquidity(key, IV4PoolManager.ModifyLiquidityParams(FULL_LO, FULL_HI, -1e23, 0), "");
        vm.stopPrank();
    }

    function test_L1_initializerCanRemoveLiquidity() public {
        // the protocol (initializer == this) withdraws its own seeded liquidity — tx.origin == initializer
        vm.prank(address(this), address(this));
        liqRouter.modifyLiquidity(key, IV4PoolManager.ModifyLiquidityParams(FULL_LO, FULL_HI, -1e23, 0), "");
    }

    function test_initializeFrontRunBlocked() public {
        // a second canonical-shaped pool cannot exist (same id), so demonstrate on a fresh hook:
        // an attacker initializing before the deployer would burn the gate window — refused.
        address hook2Addr = address(uint160((0xBB << 16) | FLAGS));
        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(_cfg(address(packRec), address(boardRec), address(adapter))),
            hook2Addr
        );
        V4PoolKey memory k2 = key;
        k2.hooks = IV4Hooks(hook2Addr);
        vm.prank(sniper, sniper);
        vm.expectRevert(); // NotInitializer, wrapped
        manager.initialize(k2, SQRT_1_1);
    }

    // ─── the 4% fee, all four swap shapes ────────────────────────────────────

    function test_buyExactIn_taxedInQpull() public {
        _pastGate();
        uint256 before = qpull.balanceOf(alice);
        V4BalanceDelta d = _swap(alice, _buyZeroForOne(), -1e21); // spend exactly 1e21 WETH
        uint256 userOut = qpull.balanceOf(alice) - before;
        uint256 fee = qpull.balanceOf(feeSink);

        assertGt(fee, 0, "fee taken");
        assertEq(fee, ((userOut + fee) * 400) / 10_000, "fee = 4% of pre-fee QPULL output");
        assertEq(weth.balanceOf(feeSink), 0, "no WETH fee on a buy");
        // the delta the swapper sees is post-fee
        int128 qd = qpullIs0 ? _a0(d) : _a1(d);
        assertEq(uint256(uint128(qd)), userOut, "router delta = delivered amount");
    }

    function test_sellExactIn_taxedInWeth() public {
        _pastSellDecay(); // sells decay 20%->4% over 48h; assert the 4% floor past the window
        uint256 amountIn = 1e21;
        uint256 before = weth.balanceOf(alice);
        _swap(alice, !_buyZeroForOne(), -int256(amountIn)); // sell exactly 1e21 QPULL
        uint256 userOut = weth.balanceOf(alice) - before;
        uint256 fee = weth.balanceOf(feeSink);

        assertGt(fee, 0, "fee taken");
        assertEq(fee, ((userOut + fee) * 400) / 10_000, "fee = 4% of pre-fee WETH output");
        assertEq(qpull.balanceOf(feeSink), 0, "no QPULL fee on an exact-in sell");
    }

    function test_buyExactOut_taxedInWeth() public {
        _pastGate();
        uint256 wantOut = 1e21;
        uint256 qBefore = qpull.balanceOf(alice);
        uint256 wBefore = weth.balanceOf(alice);
        _swap(alice, _buyZeroForOne(), int256(wantOut)); // receive exactly 1e21 QPULL
        uint256 paid = wBefore - weth.balanceOf(alice);
        uint256 fee = weth.balanceOf(feeSink);

        assertEq(qpull.balanceOf(alice) - qBefore, wantOut, "exact output delivered in full");
        assertGt(fee, 0, "fee taken");
        assertEq(fee, ((paid - fee) * 400) / 10_000, "fee = 4% of the pool's WETH input, paid on top");
    }

    function test_sellExactOut_taxedInQpull() public {
        _pastSellDecay(); // sells decay 20%->4% over 48h; assert the 4% floor past the window
        uint256 wantOut = 1e21;
        uint256 qBefore = qpull.balanceOf(alice);
        _swap(alice, !_buyZeroForOne(), int256(wantOut)); // receive exactly 1e21 WETH
        uint256 paid = qBefore - qpull.balanceOf(alice);
        uint256 fee = qpull.balanceOf(feeSink);

        assertGt(fee, 0, "fee taken");
        assertEq(fee, ((paid - fee) * 400) / 10_000, "fee = 4% of the pool's QPULL input, paid on top");
    }

    // ─── first-hour holder gate ──────────────────────────────────────────────

    function test_gate_blocksNonHolderBuysFirstHour() public {
        vm.expectRevert(); // Gated, wrapped by v4-core's hook-revert bubbling
        _swap(sniper, _buyZeroForOne(), -1e21);
    }

    function test_gate_allowsHolderBuysFirstHour() public {
        _swap(alice, _buyZeroForOne(), -1e21);
        assertGt(qpull.balanceOf(feeSink), 0, "holder buy went through, taxed");
    }

    function test_gate_sellsUnaffectedFirstHour() public {
        _swap(sniper, !_buyZeroForOne(), -1e21); // non-holder SELL during the gate: allowed
        assertGt(weth.balanceOf(feeSink), 0, "sell taxed as usual");
    }

    function test_gate_expiresAfterOneHour() public {
        _pastGate();
        _swap(sniper, _buyZeroForOne(), -1e21);
        assertGt(qpull.balanceOf(feeSink), 0, "post-gate buy by non-holder OK");
    }

    // ─── registry fan-out ────────────────────────────────────────────────────

    function test_buyNotifiesPackAndBoard_creditedToSigner() public {
        _pastGate();
        // Game credit is priced off the ETH-in side of the trade (grossWeth), not the QPULL amount.
        // On an exact-in buy of 1e21 WETH the pool consumes exactly 1e21 WETH and no WETH fee is
        // taken on a buy, so the recorded gross == the WETH spent. The standalone jackpot registry is
        // gone: buys now notify exactly the pack and leaderboard registries.
        uint256 wBefore = weth.balanceOf(alice);
        _swap(alice, _buyZeroForOne(), -1e21);
        uint256 grossWeth = wBefore - weth.balanceOf(alice);

        assertEq(packRec.calls(), 1, "pack notified");
        assertEq(packRec.lastTrader(), alice, "credited to tx.origin");
        assertEq(packRec.lastGross(), grossWeth, "gross = WETH-in volume");
        assertEq(boardRec.calls(), 1, "leaderboard notified");
        assertEq(boardRec.lastTrader(), alice, "leaderboard trader");
        assertEq(boardRec.lastGross(), grossWeth, "leaderboard gross = WETH-in volume");
    }

    function test_sellRecordsNothingGameSide() public {
        _pastGate();
        // Sells are taxed (the fee arrives in WETH) but record NOTHING game-side: the standalone
        // jackpot game that used to take sell entries is deleted, and the hook only ever credits the
        // pack + leaderboard registries on BUYS. The sell tax funds the games purely via Treasury.convert().
        uint256 wBefore = weth.balanceOf(alice);
        _swap(alice, !_buyZeroForOne(), -1e21);
        assertGt(weth.balanceOf(feeSink) + (weth.balanceOf(alice) - wBefore), 0, "sell executed"); // sanity
        assertGt(weth.balanceOf(feeSink), 0, "sell still taxed in WETH");
        assertEq(packRec.calls(), 0, "no pack tickets on sells");
        assertEq(boardRec.calls(), 0, "no leaderboard points on sells");
    }

    /// The hook is immutable: a faulting registry must cost only that trade's rewards — the swap and
    /// the fee must still succeed, or a registry bug would brick the protocol's only liquid pool.
    function test_registryRevertNeverBlocksTrading() public {
        _pastGate();
        packRec.setRevert(true);
        boardRec.setRevert(true);

        uint256 before = qpull.balanceOf(alice);
        _swap(alice, _buyZeroForOne(), -1e21); // must NOT revert
        assertGt(qpull.balanceOf(alice) - before, 0, "trade delivered");
        assertGt(qpull.balanceOf(feeSink), 0, "fee still taken");
        assertEq(packRec.calls(), 0, "record dropped, not retried");
    }

    // ─── exemption: the Treasury's conversion path ───────────────────────────

    function test_adapterSwapsExemptFromFeeGateAndRecords() public {
        // convert() sells during the FIRST HOUR with a keeper EOA that holds no NFT — the exemption
        // must bypass fee, gate, and records entirely.
        adapter.setPoolKey(_ourKey());
        address sink = makeAddr("sink");
        qpull.mint(treasury, 1e21);
        vm.startPrank(treasury, treasury);
        qpull.approve(address(adapter), 1e21);
        uint256 out = adapter.swapExactIn(address(qpull), address(weth), 1e21, 1, sink);
        vm.stopPrank();

        assertGt(out, 0, "swap executed through the hooked pool");
        assertEq(weth.balanceOf(sink), out, "full output delivered - no 4% skim");
        assertEq(weth.balanceOf(feeSink), 0, "no fee");
        assertEq(qpull.balanceOf(feeSink), 0, "no fee");
        assertEq(packRec.calls(), 0, "no records for protocol conversions");
        assertEq(boardRec.calls(), 0, "no records for protocol conversions");
    }

    // ─── adapter poolKey binding ─────────────────────────────────────────────

    function test_adapterRejectsHooklessKey() public {
        PoolKey memory k = _ourKey();
        k.hooks = address(0);
        vm.expectRevert(QpullWethAdapter.BadPoolKey.selector);
        adapter.setPoolKey(k);
    }

    function test_adapterRejectsHookThatDoesNotExemptIt() public {
        // a canonical-shaped hook whose exemptSender is someone else — binding it would let the pool
        // skim every convert(); the self-referential check refuses.
        address hook3Addr = address(uint160((0xCC << 16) | FLAGS));
        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(_cfg(address(packRec), address(boardRec), makeAddr("other"))),
            hook3Addr
        );
        PoolKey memory k = _ourKey();
        k.hooks = hook3Addr;
        vm.expectRevert(QpullWethAdapter.BadPoolKey.selector);
        adapter.setPoolKey(k);
    }

    // ─── pool-init gate: mint must be closed first (MintStillOpen) ─────────────

    /// afterInitialize refuses to open the canonical pool until the NFT collection is launched()
    /// (finalizeLaunch). Asserts the TYPED MintStillOpen selector through v4-core's ERC-7751 wrapping,
    /// not a bare expectRevert().
    function test_MintStillOpen_poolInitRevertsUntilNftLaunched() public {
        address hAddr = address(uint160((0xEE << 16) | FLAGS));
        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(_cfg(address(packRec), address(boardRec), address(adapter))),
            hAddr
        );
        nft.setLaunched(false); // mint still open -> the pool cannot be created yet

        V4PoolKey memory k2 = key;
        k2.hooks = IV4Hooks(hAddr);
        // sender == initializer (this) and the key is canonical, so afterInitialize reaches the launched() gate
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                hAddr,
                IV4Hooks.afterInitialize.selector,
                abi.encodeWithSelector(QpullTaxHook.MintStillOpen.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(k2, SQRT_1_1);
    }

    /// Once the mint is closed the same pool initializes cleanly (the gate is launch-only).
    function test_MintStillOpen_poolInitSucceedsOnceLaunched() public {
        address hAddr = address(uint160((0xEF << 16) | FLAGS));
        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(_cfg(address(packRec), address(boardRec), address(adapter))),
            hAddr
        );
        nft.setLaunched(true);
        V4PoolKey memory k2 = key;
        k2.hooks = IV4Hooks(hAddr);
        manager.initialize(k2, SQRT_1_1); // no revert
        assertEq(QpullTaxHook(hAddr).launchTime(), block.timestamp, "launchTime stamped on a launched pool");
    }

    /// Tightened twin of test_gate_blocksNonHolderBuysFirstHour: assert the TYPED Gated selector
    /// through v4-core's ERC-7751 wrapping (the swap dispatches afterSwap, which reverts Gated).
    function test_gate_blocksNonHolderBuysFirstHour_typedSelector() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                hookAddr,
                IV4Hooks.afterSwap.selector,
                abi.encodeWithSelector(QpullTaxHook.Gated.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        _swap(sniper, _buyZeroForOne(), -1e21);
    }

    // ─── real registries end-to-end ──────────────────────────────────────────

    /// One full-path check with the REAL registries (not mocks): swap -> hook -> tickets/points.
    function test_realRegistriesRecordThroughHook() public {
        MockDrandOracle oracle = new MockDrandOracle(block.timestamp, 3);
        PackRegistry packs = new PackRegistry(address(oracle), 1e20, block.timestamp, 1 hours, address(this));
        LeaderboardRegistry board = new LeaderboardRegistry(block.timestamp, address(this));

        address hook4Addr = address(uint160((0xDD << 16) | FLAGS));
        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(_cfg(address(packs), address(board), address(adapter))),
            hook4Addr
        );
        packs.setRecorder(hook4Addr);
        board.setRecorder(hook4Addr);

        V4PoolKey memory k4 = key;
        k4.hooks = IV4Hooks(hook4Addr);
        manager.initialize(k4, SQRT_1_1);
        vm.prank(address(this), address(this)); // audit F6: tx.origin == initializer for the LP seed
        liqRouter.modifyLiquidity(k4, IV4PoolManager.ModifyLiquidityParams(FULL_LO, FULL_HI, 1e24, 0), "");
        vm.warp(block.timestamp + 2 hours); // past the gate

        vm.prank(alice, alice);
        swapRouter.swap(
            k4,
            IV4PoolManager.SwapParams(
                _buyZeroForOne(), -1e21, _buyZeroForOne() ? MIN_PRICE_P1 : MAX_PRICE_M1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );

        assertGt(packs.paidToday(packs.today()), 0, "raffle tickets minted");
        assertGt(board.totalPoints(board.currentWeek()), 0, "leaderboard points accrued");
    }

    // ─── launch sell-tax schedule: shipped ladder unchanged + saturation at TAX_BPS (pre-audit) ─────

    /// The SHIPPED mainnet schedule (48h decay, 12h step) is exactly what it was before the saturating
    /// rewrite of afterSwap: 2000 / 1600 / 1200 / 800 bps at steps 0..3 (the last second of the window
    /// is still step 3), then the flat 400 once the window closes. Saturation never engages here.
    function test_sellSchedule_shippedMainnetLadderUnchanged() public {
        assertEq(hook.SELL_DECAY(), 48 hours, "mainnet decay");
        assertEq(hook.SELL_STEP(), 12 hours, "mainnet step");
        uint256 t0 = hook.launchTime();
        _assertSellTaxBps(key, 2000, "step 0: 20%");
        vm.warp(t0 + 12 hours);
        _assertSellTaxBps(key, 1600, "step 1: 16%");
        vm.warp(t0 + 24 hours);
        _assertSellTaxBps(key, 1200, "step 2: 12%");
        vm.warp(t0 + 36 hours);
        _assertSellTaxBps(key, 800, "step 3: 8%");
        vm.warp(t0 + 48 hours - 1);
        _assertSellTaxBps(key, 800, "last second of the window is still step 3: 8%");
        vm.warp(t0 + 48 hours);
        _assertSellTaxBps(key, 400, "window closed: flat 4%");
    }

    /// The SHIPPED testnet subclass (20m decay, 5m step; src/testnet/TestnetShortClock.sol) walks the same
    /// four rates: its max step is also 3, so the compressed ladder is unchanged too.
    function test_sellSchedule_shippedTestnetLadderUnchanged() public {
        (QpullTaxHook h, V4PoolKey memory k) =
            _openPoolWith("src/testnet/TestnetShortClock.sol:QpullTaxHookTestnet", 0x51);
        assertEq(h.SELL_DECAY(), 20 minutes, "testnet decay");
        assertEq(h.SELL_STEP(), 5 minutes, "testnet step");
        uint256 t0 = h.launchTime();
        _assertSellTaxBps(k, 2000, "step 0: 20%");
        vm.warp(t0 + 5 minutes);
        _assertSellTaxBps(k, 1600, "step 1: 16%");
        vm.warp(t0 + 10 minutes);
        _assertSellTaxBps(k, 1200, "step 2: 12%");
        vm.warp(t0 + 15 minutes);
        _assertSellTaxBps(k, 800, "step 3: 8%");
        vm.warp(t0 + 20 minutes - 1);
        _assertSellTaxBps(k, 800, "last second of the window is still step 3: 8%");
        vm.warp(t0 + 20 minutes);
        _assertSellTaxBps(k, 400, "window closed: flat 4%");
    }

    /// SATURATION. A subclass whose decay/step ratio pushes `step` past 3 (60m / 5m -> steps 0..11). With the
    /// pre-fix formula `SELL_TAX_START_BPS - step * SELL_STEP_BPS` step 5 was a 0% (free) sell and step 6+
    /// underflow-REVERTED, DoS-ing every sell in the window tail. The schedule now floors at TAX_BPS: the
    /// shipped part of the ladder is identical, and every later step clears at the flat 4%.
    function test_sellSchedule_saturatesAtTaxBpsForLargeStep() public {
        (QpullTaxHook h, V4PoolKey memory k) =
            _openPoolWith("test/QpullTaxHook.t.sol:LongDecaySellHook", 0x52);
        uint256 t0 = h.launchTime();
        _assertSellTaxBps(k, 2000, "step 0: 20%");
        vm.warp(t0 + 15 minutes);
        _assertSellTaxBps(k, 800, "step 3: 8% (shipped part of the ladder unchanged)");
        vm.warp(t0 + 20 minutes); // step 4: 2000 - 1600 = 400 exactly; subtraction and floor agree
        _assertSellTaxBps(k, 400, "step 4: floors at 4%");
        vm.warp(t0 + 25 minutes); // step 5: the old formula gave 0%
        _assertSellTaxBps(k, 400, "step 5: still 4%, never a free sell");
        vm.warp(t0 + 30 minutes); // step 6: the old formula underflow-reverted
        _assertSellTaxBps(k, 400, "step 6: sells still clear at 4%");
        vm.warp(t0 + 60 minutes - 1); // step 11: last second of the window
        _assertSellTaxBps(k, 400, "step 11: sells still clear at 4%");
        vm.warp(t0 + 60 minutes);
        _assertSellTaxBps(k, 400, "window closed: flat 4%");
    }

    /// Constructor invariant. A subclass with SELL_STEP() == 0 would divide by zero on every launch-window
    /// sell, a DoS the saturating schedule cannot absorb, so the constructor refuses it with the TYPED error.
    /// (The virtual getter is dispatched to the subclass even from the base constructor, which is what makes
    /// the check meaningful.)
    function test_sellSchedule_zeroStepRefusedAtDeploy() public {
        address hAddr = address(uint160((0x53 << 16) | FLAGS));
        // deployCodeTo hides the constructor's revert data behind its own require, so run the init code by
        // hand exactly the way it does: etch creationCode ++ args at the flag-carrying address and call it.
        vm.etch(
            hAddr,
            abi.encodePacked(
                vm.getCode("test/QpullTaxHook.t.sol:ZeroStepSellHook"),
                abi.encode(_cfg(address(packRec), address(boardRec), address(adapter)))
            )
        );
        (bool ok, bytes memory ret) = hAddr.call("");
        assertFalse(ok, "a zero SELL_STEP must not deploy");
        assertEq(ret, abi.encodeWithSelector(QpullTaxHook.BadSellSchedule.selector), "typed BadSellSchedule");
    }

    // ─── helpers ─────────────────────────────────────────────────────────────

    /// Deploys the hook artifact `what` (base or a subclass) at a fresh flag-carrying address, opens its
    /// canonical pool as the initializer (stamping launchTime = now) and seeds full-range LP.
    function _openPoolWith(string memory what, uint8 tag)
        internal
        returns (QpullTaxHook h, V4PoolKey memory k)
    {
        address hAddr = address((uint160(tag) << 16) | FLAGS);
        deployCodeTo(what, abi.encode(_cfg(address(packRec), address(boardRec), address(adapter))), hAddr);
        h = QpullTaxHook(hAddr);
        k = key;
        k.hooks = IV4Hooks(hAddr);
        manager.initialize(k, SQRT_1_1); // sender = this = the initializer
        vm.prank(address(this), address(this)); // audit F6: tx.origin == initializer for the LP seed
        liqRouter.modifyLiquidity(k, IV4PoolManager.ModifyLiquidityParams(FULL_LO, FULL_HI, 1e24, 0), "");
    }

    /// Exact-in sell of 1e21 QPULL by alice through pool `k`; asserts the WETH fee equals `expectedBps` of
    /// the pool's pre-fee WETH output TO THE WEI. fee = floor(U * bps / 10000) and userOut = U - fee, so
    /// userOut + fee reconstructs U exactly and the comparison has no rounding slack.
    function _assertSellTaxBps(V4PoolKey memory k, uint256 expectedBps, string memory why) internal {
        uint256 sinkBefore = weth.balanceOf(feeSink);
        uint256 userBefore = weth.balanceOf(alice);
        bool zeroForOne = !_buyZeroForOne(); // sell = QPULL flows in
        vm.prank(alice, alice);
        swapRouter.swap(
            k,
            IV4PoolManager.SwapParams(zeroForOne, -1e21, zeroForOne ? MIN_PRICE_P1 : MAX_PRICE_M1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        uint256 fee = weth.balanceOf(feeSink) - sinkBefore;
        uint256 preFeeOut = (weth.balanceOf(alice) - userBefore) + fee;
        assertGt(fee, 0, "sell taxed");
        assertEq(fee, (preFeeOut * expectedBps) / 10_000, why);
    }

    function _ourKey() internal view returns (PoolKey memory k) {
        k = PoolKey({
            currency0: Currency.wrap(qpullIs0 ? address(qpull) : address(weth)),
            currency1: Currency.wrap(qpullIs0 ? address(weth) : address(qpull)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: hookAddr
        });
    }

    function _a0(V4BalanceDelta d) internal pure returns (int128 a) {
        assembly {
            a := sar(128, d)
        }
    }

    function _a1(V4BalanceDelta d) internal pure returns (int128 a) {
        assembly {
            a := signextend(15, d)
        }
    }
}

/// @dev Deliberately MIS-SET sell schedule (60m decay, 5m step -> steps 0..11). With the pre-fix formula
///      `SELL_TAX_START_BPS - step * SELL_STEP_BPS` this reached 0% at step 5 and underflow-reverted from
///      step 6 on. Exists only to prove the schedule saturates at TAX_BPS. NOT a deployable configuration.
contract LongDecaySellHook is QpullTaxHook {
    constructor(QpullTaxHook.HookConfig memory c) QpullTaxHook(c) { }

    function SELL_STEP() public pure override returns (uint256) {
        return 5 minutes;
    }

    function SELL_DECAY() public pure override returns (uint256) {
        return 60 minutes;
    }
}

/// @dev A zero step length: `(now - launchTime) / SELL_STEP()` would panic (division by zero) on every sell
///      inside the window. The constructor invariant must refuse it at deploy.
///      The zero is read from a never-written storage slot rather than written as a literal on purpose: a
///      constant 0 makes the base constructor's BadSellSchedule revert unconditional, and solc (via_ir) then
///      refuses to compile such a subclass at all, since its immutables would be "read from but never
///      assigned" (error 1284). That is an even stronger form of the guard (a literal-zero subclass cannot
///      even be built), but a storage read keeps this one compilable so the runtime revert is testable.
contract ZeroStepSellHook is QpullTaxHook {
    uint256 internal stepLen; // never written: stays 0

    constructor(QpullTaxHook.HookConfig memory c) QpullTaxHook(c) { }

    function SELL_STEP() public view override returns (uint256) {
        return stepLen;
    }
}
