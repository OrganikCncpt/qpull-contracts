// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { QpullWethAdapter } from "../../src/adapters/QpullWethAdapter.sol";
import { QpullTaxHook } from "../../src/hooks/QpullTaxHook.sol";
import {
    IPoolManager,
    IUnlockCallback,
    PoolKey,
    Currency,
    BalanceDelta,
    BalanceDeltaLib
} from "../../src/interfaces/IPoolManager.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockNFT } from "../mocks/MockNFT.sol";
import { MockRecorder } from "../mocks/MockRecorder.sol";

// v4-core types for the swap-router test double (same ABI as our hand-written ones)
import { IPoolManager as IV4PoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks as IV4Hooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey as V4PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency as V4Currency } from "v4-core/types/Currency.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";

interface IWETHDeposit {
    function deposit() external payable;
}

/// @notice Minimal V4 liquidity provider: initializes + seeds a QPULL/WETH pool on the real PoolManager
///         so the adapter has something to swap against. Settles both currencies inside unlock.
contract V4LiquidityHelper is IUnlockCallback {
    using BalanceDeltaLib for BalanceDelta;

    IPoolManager public immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function addLiquidity(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 liq) external {
        pm.unlock(abi.encode(key, tickLower, tickUpper, int256(uint256(liq))));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (PoolKey memory key, int24 tl, int24 tu, int256 liq) =
            abi.decode(data, (PoolKey, int24, int24, int256));
        (BalanceDelta delta,) =
            pm.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(tl, tu, liq, bytes32(0)), "");
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    function _settle(Currency c, int128 amt) internal {
        if (amt < 0) {
            pm.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(pm), uint256(uint128(-amt)));
            pm.settle();
        } else if (amt > 0) {
            pm.take(c, address(this), uint256(uint128(amt)));
        }
    }
}

/// @notice Forks Robinhood Chain and drives the LAUNCH SHAPE end-to-end on the REAL Uniswap-V4
///         PoolManager: canonical pool created WITH QpullTaxHook (audit H-2), adapter bound to it,
///         a public swap paying the 4%, and the Treasury conversion path swapping fee-exempt.
contract QpullWethPoolForkTest is Test {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    string RPC = vm.envOr("RH_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));

    uint160 constant SQRT_1_1 = 79_228_162_514_264_337_593_543_950_336; // 2**96 -> price 1:1
    uint160 constant FLAGS = (1 << 12) | (1 << 11) | (1 << 6) | (1 << 2); // +beforeAddLiquidity (0x1844)
    uint160 constant MIN_PRICE_P1 = 4_295_128_739 + 1;
    uint160 constant MAX_PRICE_M1 = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342 - 1;

    MockERC20 qpull;
    MockRecorder rec;
    address feeSink;
    address hookAddr;
    address c0;
    address c1;

    function test_createHookedPoolAndSwapThroughAdapter() public {
        vm.createSelectFork(RPC);
        IPoolManager pm = IPoolManager(POOL_MANAGER);

        // "QPULL" stand-in: a plain ERC20 — exactly what the real (stripped, H-2) QPULLToken is.
        qpull = new MockERC20();
        MockNFT nft = new MockNFT();
        rec = new MockRecorder();
        feeSink = makeAddr("feeSink");

        // Production order: adapter first, then the hook naming it fee-exempt (an immutable).
        QpullWethAdapter adapter = new QpullWethAdapter(POOL_MANAGER, address(qpull), WETH, address(this));
        hookAddr = address(uint160((0xF0 << 16) | FLAGS));
        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(
                QpullTaxHook.HookConfig({
                    poolManager: POOL_MANAGER,
                    qpull: address(qpull),
                    weth: WETH,
                    fee: 3000,
                    tickSpacing: 60,
                    treasury: feeSink,
                    packRegistry: address(rec),
                    jackpotRegistry: address(rec),
                    leaderboardRegistry: address(rec),
                    nft: address(nft),
                    exemptSender: address(adapter),
                    initializer: address(this)
                })
            ),
            hookAddr
        );

        // V4 requires currency0 < currency1.
        (c0, c1) = WETH < address(qpull) ? (WETH, address(qpull)) : (address(qpull), WETH);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 3000, // 0.3% static
            tickSpacing: 60,
            hooks: hookAddr
        });
        pm.initialize(key, SQRT_1_1); // sender = this = initializer; stamps launchTime on the REAL chain
        assertEq(QpullTaxHook(hookAddr).launchTime(), block.timestamp, "launch stamped");

        // Seed deep, full-range liquidity via the helper. audit F6: liquidity-add is now gated to the
        // initializer (tx.origin) — prank so the protocol's seed passes the beforeAddLiquidity check.
        V4LiquidityHelper lp = new V4LiquidityHelper(pm);
        vm.deal(address(this), 60_000 ether);
        IWETHDeposit(WETH).deposit{ value: 60_000 ether }();
        IERC20(WETH).transfer(address(lp), 60_000 ether);
        qpull.mint(address(lp), 200_000 ether);
        vm.prank(address(this), address(this));
        lp.addLiquidity(key, -887_220, 887_220, uint128(20_000 ether)); // full range (multiples of 60)

        // Bind the adapter — setPoolKey verifies the hook exempts it, on-chain.
        adapter.setPoolKey(key);
        adapter.setTreasury(address(this)); // audit H-1: this test acts as the Treasury caller

        // 1. The Treasury conversion path: QPULL -> WETH through the HOOKED pool, fee-exempt.
        address dest = makeAddr("dest");
        uint256 amountIn = 500 ether;
        qpull.mint(address(this), amountIn);
        IERC20(qpull).approve(address(adapter), amountIn);
        uint256 out = adapter.swapExactIn(address(qpull), WETH, amountIn, 1, dest);

        emit log_named_uint("WETH out for 500 QPULL (exempt)", out);
        assertGt(out, 0, "received WETH through the real V4 pool");
        assertEq(IERC20(WETH).balanceOf(dest), out, "delivered in full - no fee on the exempt path");
        assertEq(IERC20(WETH).balanceOf(feeSink), 0, "no fee for the conversion swap");

        // 2. A PUBLIC buy through a router: pays the 4% to the treasury on the real PoolManager.
        _publicTaxedBuy();
    }

    function _publicTaxedBuy() internal {
        vm.warp(block.timestamp + 2 hours); // past the first-hour gate
        PoolSwapTest router = new PoolSwapTest(IV4PoolManager(POOL_MANAGER));
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 200 ether);
        vm.startPrank(buyer, buyer);
        IWETHDeposit(WETH).deposit{ value: 100 ether }();
        IERC20(WETH).approve(address(router), type(uint256).max);
        bool buyZeroForOne = c0 == WETH; // WETH in, QPULL out
        router.swap(
            V4PoolKey(V4Currency.wrap(c0), V4Currency.wrap(c1), 3000, 60, IV4Hooks(hookAddr)),
            IV4PoolManager.SwapParams(buyZeroForOne, -100 ether, buyZeroForOne ? MIN_PRICE_P1 : MAX_PRICE_M1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();

        uint256 fee = qpull.balanceOf(feeSink);
        uint256 got = qpull.balanceOf(buyer);
        emit log_named_uint("buyer QPULL out (taxed)", got);
        emit log_named_uint("treasury QPULL fee", fee);
        assertGt(fee, 0, "4% taken on the public buy");
        assertEq(fee, ((got + fee) * 400) / 10_000, "fee = 4% of pre-fee output");
        assertEq(rec.lastTrader(), buyer, "registries credited to the signer");
    }
}
