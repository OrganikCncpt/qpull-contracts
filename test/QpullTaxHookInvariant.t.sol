// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

// Real vendored Uniswap v4 core (tag v4.0.0) — fuzz against actual PoolManager semantics, not a mock.
import { PoolManager } from "v4-core/PoolManager.sol";
import { IPoolManager as IV4PoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks as IV4Hooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey as V4PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency as V4Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta as V4BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";

import { QpullTaxHook } from "../src/hooks/QpullTaxHook.sol";
import { QpullWethAdapter } from "../src/adapters/QpullWethAdapter.sol";
import { PoolKey, Currency } from "../src/interfaces/IPoolManager.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockNFT } from "./mocks/MockNFT.sol";
import { MockRecorder } from "./mocks/MockRecorder.sol";

/// @notice Shared launch-shape setUp: canonical QPULL/WETH pool created WITH QpullTaxHook on the REAL
///         PoolManager, deep liquidity seeded, gate warped past. Reused by the fuzz and invariant suites.
abstract contract HookFuzzBase is Test {
    uint160 constant FLAGS = (1 << 12) | (1 << 11) | (1 << 6) | (1 << 2); // +beforeAddLiquidity (0x1844)
    uint160 constant SQRT_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 constant MIN_PRICE_P1 = 4_295_128_739 + 1;
    uint160 constant MAX_PRICE_M1 = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342 - 1;
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    int24 constant FULL_LO = -887_220;
    int24 constant FULL_HI = 887_220;
    uint256 constant TAX_BPS = 400;
    uint256 constant BPS = 10_000;

    PoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest liqRouter;
    MockERC20 qpull;
    MockERC20 weth;
    MockNFT nft;
    MockRecorder rec;
    QpullTaxHook hook;
    QpullWethAdapter adapter;
    address hookAddr = address(uint160((0xADD << 16) | FLAGS));
    address feeSink = makeAddr("feeSink"); // the hook's treasury (fee recipient)
    bool qpullIs0;
    V4PoolKey key;

    function _baseSetUp() internal {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IV4PoolManager(address(manager)));
        liqRouter = new PoolModifyLiquidityTest(IV4PoolManager(address(manager)));
        qpull = new MockERC20();
        weth = new MockERC20();
        qpullIs0 = address(qpull) < address(weth);
        nft = new MockNFT();
        rec = new MockRecorder();

        adapter = new QpullWethAdapter(address(manager), address(qpull), address(weth), address(this));
        adapter.setTreasury(address(this));

        QpullTaxHook.HookConfig memory hc = QpullTaxHook.HookConfig({
            poolManager: address(manager),
            qpull: address(qpull),
            weth: address(weth),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            treasury: feeSink,
            packRegistry: address(rec),
            jackpotRegistry: address(rec),
            leaderboardRegistry: address(rec),
            nft: address(nft),
            exemptSender: address(adapter),
            initializer: address(this)
        });
        deployCodeTo("src/hooks/QpullTaxHook.sol:QpullTaxHook", abi.encode(hc), hookAddr);
        hook = QpullTaxHook(hookAddr);

        key = V4PoolKey({
            currency0: V4Currency.wrap(qpullIs0 ? address(qpull) : address(weth)),
            currency1: V4Currency.wrap(qpullIs0 ? address(weth) : address(qpull)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IV4Hooks(hookAddr)
        });

        qpull.mint(address(this), 1e30);
        weth.mint(address(this), 1e30);
        qpull.approve(address(liqRouter), type(uint256).max);
        weth.approve(address(liqRouter), type(uint256).max);

        manager.initialize(key, SQRT_1_1);
        vm.prank(address(this), address(this)); // audit F6: tx.origin == initializer for the LP seed
        liqRouter.modifyLiquidity(key, IV4PoolManager.ModifyLiquidityParams(FULL_LO, FULL_HI, 1e24, 0), "");
        vm.warp(block.timestamp + 2 hours); // past the first-hour gate — fuzz actors need not hold an NFT
    }

    function _buyZeroForOne() internal view returns (bool) {
        return !qpullIs0; // buy = QPULL flows out to the swapper
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

/// @notice Stateless fuzz: the 4% fee is exact across the full input space, the exempt path never pays,
///         swaps always settle, and a round trip never profits.
contract QpullTaxHookFuzzTest is HookFuzzBase {
    address trader = makeAddr("trader");

    function setUp() public {
        _baseSetUp();
        qpull.mint(trader, 1e30);
        weth.mint(trader, 1e30);
        vm.startPrank(trader);
        qpull.approve(address(swapRouter), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal returns (V4BalanceDelta) {
        vm.prank(trader, trader);
        return swapRouter.swap(
            key,
            IV4PoolManager.SwapParams(zeroForOne, amountSpecified, zeroForOne ? MIN_PRICE_P1 : MAX_PRICE_M1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    /// The output on an exact-input buy is taxed exactly 4% of the pool's pre-fee QPULL output.
    function testFuzz_buyExactIn_feeIsExactly4Percent(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e12, 5e22); // dust..big, within the 1e24-liquidity pool
        uint256 qBefore = qpull.balanceOf(trader);
        _swap(_buyZeroForOne(), -int256(amountIn));
        uint256 received = qpull.balanceOf(trader) - qBefore; // post-fee delivery
        uint256 fee = qpull.balanceOf(feeSink);
        uint256 gross = received + fee; // pool's pre-fee output
        assertEq(fee, (gross * TAX_BPS) / BPS, "fee != 4% of gross QPULL output");
        assertEq(weth.balanceOf(feeSink), 0, "no WETH fee on a buy");
    }

    /// The output on an exact-input sell is taxed exactly 4% of the pool's pre-fee WETH output.
    function testFuzz_sellExactIn_feeIsExactly4Percent(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e12, 5e22);
        uint256 wBefore = weth.balanceOf(trader);
        _swap(!_buyZeroForOne(), -int256(amountIn));
        uint256 received = weth.balanceOf(trader) - wBefore;
        uint256 fee = weth.balanceOf(feeSink);
        uint256 gross = received + fee;
        assertEq(fee, (gross * TAX_BPS) / BPS, "fee != 4% of gross WETH output");
        assertEq(qpull.balanceOf(feeSink), 0, "no QPULL fee on an exact-in sell");
    }

    /// Exact-output buy: the WETH input is taxed exactly 4% of the pool's pre-fee WETH input (paid on top).
    function testFuzz_buyExactOut_feeIsExactly4Percent(uint256 wantOut) public {
        wantOut = bound(wantOut, 1e12, 1e22);
        uint256 wBefore = weth.balanceOf(trader);
        _swap(_buyZeroForOne(), int256(wantOut));
        uint256 paid = wBefore - weth.balanceOf(trader);
        uint256 fee = weth.balanceOf(feeSink);
        uint256 poolInput = paid - fee; // the unspecified input the pool actually consumed
        assertEq(fee, (poolInput * TAX_BPS) / BPS, "fee != 4% of the pool's WETH input");
    }

    /// Any fuzzed swap through the hooked pool SETTLES — the take()+returned-delta never leaves an
    /// unsettled balance (no CurrencyNotSettled). If it reverted, this test would fail.
    function testFuzz_swapAlwaysSettles(uint256 amountIn, bool zeroForOne, bool exactIn) public {
        amountIn = bound(amountIn, 1e12, 5e22);
        int256 spec = exactIn ? -int256(amountIn) : int256(bound(amountIn, 1e12, 1e22));
        _swap(zeroForOne, spec);
        // reaching here means the unlock settled cleanly for an arbitrary swap shape
        assertTrue(true);
    }

    /// A buy-then-sell round trip can NEVER return more than was put in — no value is created from the
    /// accounting alone (it loses the 4% x2, the LP fee x2, and slippage).
    function testFuzz_roundTripNeverProfits(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e15, 1e22);
        uint256 wStart = weth.balanceOf(trader);

        // buy: spend `amountIn` WETH for QPULL
        uint256 qBefore = qpull.balanceOf(trader);
        _swap(_buyZeroForOne(), -int256(amountIn));
        uint256 qGot = qpull.balanceOf(trader) - qBefore;

        // sell all the QPULL received back for WETH
        _swap(!_buyZeroForOne(), -int256(qGot));

        assertLe(weth.balanceOf(trader), wStart, "round trip created value from accounting");
    }

    /// The exempt conversion path (the Treasury's adapter) pays ZERO fee for any fuzzed size.
    function testFuzz_exemptSenderNeverPaysFee(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e12, 5e22);
        adapter.setPoolKey(_ourKey());
        address sink = makeAddr("sink");
        qpull.mint(address(this), amountIn);
        qpull.approve(address(adapter), amountIn);
        uint256 out = adapter.swapExactIn(address(qpull), address(weth), amountIn, 1, sink);
        assertGt(out, 0, "exempt swap executed");
        assertEq(weth.balanceOf(sink), out, "full output delivered, no skim");
        assertEq(weth.balanceOf(feeSink), 0, "exempt path pays no fee");
        assertEq(qpull.balanceOf(feeSink), 0, "exempt path pays no fee");
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
}

/// @notice The invariant handler: performs bounded random exact-input buys/sells and accumulates, per
///         fee currency, the MEASURED treasury fee and the EXPECTED fee (4% of the pool's pre-fee gross,
///         floored per swap). The invariant asserts the two sums stay equal across a long random sequence
///         — catching any per-swap drift/rounding leak (the Bunni-class failure) over many small trades.
contract HookInvariantHandler is Test {
    PoolSwapTest swapRouter;
    MockERC20 qpull;
    MockERC20 weth;
    address feeSink;
    V4PoolKey key;
    bool qpullIs0;

    uint160 constant MIN_PRICE_P1 = 4_295_128_739 + 1;
    uint160 constant MAX_PRICE_M1 = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342 - 1;
    uint256 constant TAX_BPS = 400;
    uint256 constant BPS = 10_000;

    uint256 public measuredFeeQpull;
    uint256 public expectedFeeQpull;
    uint256 public measuredFeeWeth;
    uint256 public expectedFeeWeth;
    uint256 public swaps;
    uint256 public reverts;

    constructor(
        PoolSwapTest swapRouter_,
        MockERC20 qpull_,
        MockERC20 weth_,
        address feeSink_,
        V4PoolKey memory key_,
        bool qpullIs0_
    ) {
        swapRouter = swapRouter_;
        qpull = qpull_;
        weth = weth_;
        feeSink = feeSink_;
        key = key_;
        qpullIs0 = qpullIs0_;
        qpull.mint(address(this), 1e30);
        weth.mint(address(this), 1e30);
        qpull.approve(address(swapRouter), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
    }

    // buy = QPULL flows out; fee is taken in QPULL (the output/unspecified currency).
    function buy(uint256 amountIn) external {
        amountIn = bound(amountIn, 1e12, 2e22);
        bool zeroForOne = !qpullIs0;
        uint256 qBefore = qpull.balanceOf(address(this));
        uint256 feeBefore = qpull.balanceOf(feeSink);
        try swapRouter.swap(
            key,
            IV4PoolManager.SwapParams(
                zeroForOne, -int256(amountIn), zeroForOne ? MIN_PRICE_P1 : MAX_PRICE_M1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) {
            uint256 received = qpull.balanceOf(address(this)) - qBefore;
            uint256 fee = qpull.balanceOf(feeSink) - feeBefore;
            uint256 gross = received + fee;
            measuredFeeQpull += fee;
            expectedFeeQpull += (gross * TAX_BPS) / BPS;
            ++swaps;
        } catch {
            ++reverts;
        }
    }

    // sell = WETH flows out; fee is taken in WETH.
    function sell(uint256 amountIn) external {
        amountIn = bound(amountIn, 1e12, 2e22);
        bool zeroForOne = qpullIs0;
        uint256 wBefore = weth.balanceOf(address(this));
        uint256 feeBefore = weth.balanceOf(feeSink);
        try swapRouter.swap(
            key,
            IV4PoolManager.SwapParams(
                zeroForOne, -int256(amountIn), zeroForOne ? MIN_PRICE_P1 : MAX_PRICE_M1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        ) {
            uint256 received = weth.balanceOf(address(this)) - wBefore;
            uint256 fee = weth.balanceOf(feeSink) - feeBefore;
            uint256 gross = received + fee;
            measuredFeeWeth += fee;
            expectedFeeWeth += (gross * TAX_BPS) / BPS;
            ++swaps;
        } catch {
            ++reverts;
        }
    }
}

contract QpullTaxHookInvariantTest is HookFuzzBase {
    HookInvariantHandler handler;

    function setUp() public {
        _baseSetUp();
        handler = new HookInvariantHandler(swapRouter, qpull, weth, feeSink, key, qpullIs0);
        // Only drive swaps through the handler.
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = HookInvariantHandler.buy.selector;
        selectors[1] = HookInvariantHandler.sell.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    /// Over any random sequence of buys/sells, the treasury's collected QPULL fee equals the sum of the
    /// per-swap 4%-of-gross expectations — no cumulative drift (the Bunni-style attack) can bleed value.
    function invariant_qpullFeesExactlyFourPercent() public view {
        assertEq(
            handler.measuredFeeQpull(), handler.expectedFeeQpull(), "cumulative QPULL fee drifted from 4%"
        );
    }

    /// Same conservation for the WETH (sell-side) fee.
    function invariant_wethFeesExactlyFourPercent() public view {
        assertEq(handler.measuredFeeWeth(), handler.expectedFeeWeth(), "cumulative WETH fee drifted from 4%");
    }
}
