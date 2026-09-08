// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
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
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockNFT } from "./mocks/MockNFT.sol";
import { MockRecorder } from "./mocks/MockRecorder.sol";

/// Dedicated first-hour anti-sniper THROTTLE probe (cap / count / cooldown) — the code path the shipped
/// suite leaves untested (its fixture pins earlyBuyCapWei = type(uint256).max).
contract AdvHookThrottle is Test {
    uint160 constant FLAGS = (1 << 12) | (1 << 11) | (1 << 9) | (1 << 6) | (1 << 2);
    uint160 constant SQRT_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 constant MIN_PRICE_P1 = 4_295_128_739 + 1;
    uint160 constant MAX_PRICE_M1 = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342 - 1;
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    int24 constant FULL_LO = -887_220;
    int24 constant FULL_HI = 887_220;

    uint256 constant CAP = 0.15 ether;

    PoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest liqRouter;
    MockERC20 qpull;
    MockERC20 weth;
    MockNFT nft;
    QpullTaxHook hook;
    QpullWethAdapter adapter;
    address hookAddr = address(uint160((0xBB << 16) | FLAGS));
    address feeSink = makeAddr("feeSink");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob"); // second holder (sybil)
    bool qpullIs0;
    V4PoolKey key;

    function setUp() public {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IV4PoolManager(address(manager)));
        liqRouter = new PoolModifyLiquidityTest(IV4PoolManager(address(manager)));
        qpull = new MockERC20();
        weth = new MockERC20();
        qpullIs0 = address(qpull) < address(weth);
        nft = new MockNFT();
        nft.set(1, alice, 0);
        nft.set(2, bob, 0);

        adapter = new QpullWethAdapter(address(manager), address(qpull), address(weth), address(this));
        adapter.setTreasury(makeAddr("t"));

        deployCodeTo(
            "src/hooks/QpullTaxHook.sol:QpullTaxHook",
            abi.encode(
                QpullTaxHook.HookConfig({
                    poolManager: address(manager),
                    qpull: address(qpull),
                    weth: address(weth),
                    fee: FEE,
                    tickSpacing: TICK_SPACING,
                    treasury: feeSink,
                    packRegistry: address(new MockRecorder()),
                    leaderboardRegistry: address(new MockRecorder()),
                    nft: address(nft),
                    exemptSender: address(adapter),
                    initializer: address(this),
                    earlyBuyCapWei: CAP
                })
            ),
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

        qpull.mint(address(this), 1e27);
        weth.mint(address(this), 1e27);
        qpull.approve(address(liqRouter), type(uint256).max);
        weth.approve(address(liqRouter), type(uint256).max);
        for (uint256 i; i < 2; ++i) {
            address who = i == 0 ? alice : bob;
            qpull.mint(who, 1e24);
            weth.mint(who, 1e24);
            vm.startPrank(who);
            qpull.approve(address(swapRouter), type(uint256).max);
            weth.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }

        manager.initialize(key, SQRT_1_1);
        vm.prank(address(this), address(this));
        liqRouter.modifyLiquidity(key, IV4PoolManager.ModifyLiquidityParams(FULL_LO, FULL_HI, 1e24, 0), "");
    }

    function _buyZeroForOne() internal view returns (bool) {
        return !qpullIs0;
    }

    function _swap(address who, bool zeroForOne, int256 amt) internal returns (V4BalanceDelta) {
        vm.prank(who, who);
        return swapRouter.swap(
            key,
            IV4PoolManager.SwapParams(zeroForOne, amt, zeroForOne ? MIN_PRICE_P1 : MAX_PRICE_M1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    // small under-cap buy (exact input of WETH)
    function _smallBuy(address who) internal {
        _swap(who, _buyZeroForOne(), -int256(0.01 ether));
    }

    // ── CAP: an exact-INPUT buy over the WETH cap reverts ──
    function test_cap_exactInput_overCap_reverts() public {
        vm.expectRevert(); // wraps QpullTaxHook.EarlyBuyTooLarge via PoolManager custom-revert
        _swap(alice, _buyZeroForOne(), -int256(1 ether)); // 1 ETH WETH-in >> 0.15 cap
    }

    // ── CAP: an exact-OUTPUT buy that would spend > cap of WETH is ALSO blocked (no dodge) ──
    function test_cap_exactOutput_overCap_reverts() public {
        // request ~1e18 QPULL out (needs ~>=1e18 WETH in at 1:1) -> WETH-in+fee >> cap
        vm.expectRevert();
        _swap(alice, _buyZeroForOne(), int256(1 ether));
    }

    // ── CAP: a just-under-cap exact-input buy succeeds ──
    function test_cap_underCap_ok() public {
        _smallBuy(alice); // 0.01 ETH < 0.15 cap
        assertGt(qpull.balanceOf(alice), 1e24, "alice received QPULL");
    }

    // ── COOLDOWN: two gated buys in the same block by one wallet -> 2nd reverts ──
    function test_cooldown_sameBlock_reverts() public {
        _smallBuy(alice);
        vm.expectRevert();
        _smallBuy(alice); // < BUY_COOLDOWN (2 min) later
    }

    // ── CAP SCOPE: the size cap covers only a wallet's first EARLY_BUY_COUNT buys; the next buy is uncapped ──
    function test_cap_appliesToFirstN_thenUncapped() public {
        uint256 n = hook.EARLY_BUY_COUNT();
        for (uint256 i; i < n; ++i) {
            _smallBuy(alice); // under-cap, cooldown-spaced -> all allowed
            vm.warp(block.timestamp + hook.BUY_COOLDOWN() + 1);
            require(block.timestamp < hook.launchTime() + hook.GATE_DURATION(), "fixture gate too short");
        }
        // the (n+1)th buy is OVER the 0.15 cap, but past the first N it must now SUCCEED (cap no longer applies)
        uint256 before = qpull.balanceOf(alice);
        _swap(alice, _buyZeroForOne(), -int256(0.2 ether)); // 0.2 ETH WETH-in > 0.15 cap
        assertGt(qpull.balanceOf(alice), before, "over-cap buy allowed after the first EARLY_BUY_COUNT buys");
    }

    // ── SYBIL is per-wallet by design: bob (a second NFT holder) is unthrottled by alice's buys ──
    function test_sybil_perWalletKeyed() public {
        _smallBuy(alice);
        _smallBuy(bob); // same block, different tx.origin: NOT subject to alice's cooldown
        assertGt(qpull.balanceOf(bob), 1e24, "bob's independent wallet buys freely (documented sybil cost)");
    }

    // ── after the gate closes, the throttle is inert (large buy, rapid repeats all OK) ──
    function test_postGate_throttleInert() public {
        vm.warp(hook.launchTime() + hook.GATE_DURATION() + 1);
        _swap(alice, _buyZeroForOne(), -int256(1 ether)); // over "cap" but gate closed
        _swap(alice, _buyZeroForOne(), -int256(1 ether)); // rapid repeat, no cooldown
        assertTrue(true);
    }
}
