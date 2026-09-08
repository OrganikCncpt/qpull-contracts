// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { QpullLiquidityLock } from "../src/QpullLiquidityLock.sol";
import {
    IPoolManager,
    IUnlockCallback,
    PoolKey,
    Currency,
    BalanceDelta
} from "../src/interfaces/IPoolManager.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/// @notice Minimal PoolManager stand-in for the lock's NEW logic (access control + one-shot latch + settle).
///         The seed mechanics themselves (unlock -> modifyLiquidity -> settle) are the same sequence as the
///         proven V4LiquidityHelper in test/fork/QpullWethPoolFork.t.sol and are exercised end-to-end on real
///         v4 by the go-live path (GoLiveTestnet / GoLiveMainnet, which seed ONLY through this lock; the old
///         self-owned LiquiditySeeder was deleted from GoLiveTestnet in the pre-audit pass because a
///         deployer-owned position is removable); here we only need a deterministic manager that drives the
///         unlock callback and reports what the add owes.
contract StubPM {
    uint128 public lastLiquidity;
    int128 public owe0; // amount the add "owes" for currency0 (positive; charged as negative delta)
    int128 public owe1;
    bool public rejectRemove = true; // assert the lock never asks to remove

    function setOwe(int128 a0, int128 a1) external {
        owe0 = a0;
        owe1 = a1;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function initialize(PoolKey memory, uint160) external pure returns (int24) {
        return 0;
    }

    function modifyLiquidity(PoolKey memory, IPoolManager.ModifyLiquidityParams memory p, bytes calldata)
        external
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        require(!(rejectRemove && p.liquidityDelta < 0), "stub: lock tried to REMOVE");
        lastLiquidity = uint128(uint256(p.liquidityDelta));
        // The add owes tokens -> negative deltas to the caller (the lock pays them in _settle).
        callerDelta = _delta(-owe0, -owe1);
        feesAccrued = _delta(0, 0);
    }

    function sync(Currency) external { }
    function settle() external payable returns (uint256) {
        return 0;
    }
    function take(Currency c, address to, uint256 amt) external {
        IERC20(Currency.unwrap(c)).transfer(to, amt);
    }

    function _delta(int128 a0, int128 a1) internal pure returns (BalanceDelta) {
        return BalanceDelta.wrap(int256((uint256(uint128(a0)) << 128) | uint256(uint128(a1))));
    }
}

contract QpullLiquidityLockTest is Test {
    StubPM pm;
    MockERC20 qpull;
    MockERC20 weth;
    QpullLiquidityLock lock;

    address opener = address(this); // the deployer/initializer that seeds once
    address stranger = makeAddr("stranger");
    address hook = makeAddr("hook");

    uint128 constant LIQ = 1e21;
    int128 constant OWE0 = 4e20; // tokens the add pulls for each side (arbitrary, < funded balance)
    int128 constant OWE1 = 3e20;

    function setUp() public {
        pm = new StubPM();
        qpull = new MockERC20();
        weth = new MockERC20();
        lock = new QpullLiquidityLock(
            IPoolManager(address(pm)), address(qpull), address(weth), 3000, 60, hook, opener
        );
        pm.setOwe(OWE0, OWE1);
        // fund the lock with the launch liquidity to seed
        qpull.mint(address(lock), 1e24);
        weth.mint(address(lock), 1e24);
    }

    // ── the ONE entrypoint works: seeds once, latches, pays from the lock's balance ──
    function test_seed_addsLiquidity_andLatches() public {
        assertFalse(lock.seeded());
        uint256 q0 = qpull.balanceOf(address(lock));
        uint256 w0 = weth.balanceOf(address(lock));

        lock.seed(LIQ);

        assertTrue(lock.seeded(), "latched");
        assertEq(pm.lastLiquidity(), LIQ, "liquidity added");
        // the lock paid the owed amounts into the manager (currency0 = lower address of {qpull,weth})
        (address c0, address c1) =
            address(qpull) < address(weth) ? (address(qpull), address(weth)) : (address(weth), address(qpull));
        uint256 owe0 = uint256(uint128(OWE0));
        uint256 owe1 = uint256(uint128(OWE1));
        assertEq(IERC20(c0).balanceOf(address(pm)), owe0, "currency0 paid to manager");
        assertEq(IERC20(c1).balanceOf(address(pm)), owe1, "currency1 paid to manager");
        // residual stays LOCKED in the lock (no path out) - just confirm it did not vanish
        assertEq(qpull.balanceOf(address(lock)) + IERC20(address(qpull)).balanceOf(address(pm)), q0, "no qpull leaked");
        assertEq(weth.balanceOf(address(lock)) + IERC20(address(weth)).balanceOf(address(pm)), w0, "no weth leaked");
    }

    // ── one-shot: a second seed can never run ──
    function test_seed_isOneShot() public {
        lock.seed(LIQ);
        vm.expectRevert(QpullLiquidityLock.AlreadySeeded.selector);
        lock.seed(LIQ);
    }

    // ── seed(0) is rejected: a no-op seed would latch and strand the pre-funded tokens ──
    function test_seed_rejectsZeroLiquidity() public {
        vm.expectRevert(QpullLiquidityLock.ZeroLiquidity.selector);
        lock.seed(0);
        assertFalse(lock.seeded(), "a rejected seed must not latch");
    }

    // ── opener-only: no one else can trigger the seed ──
    function test_seed_onlyOpener() public {
        vm.prank(stranger);
        vm.expectRevert(QpullLiquidityLock.NotOpener.selector);
        lock.seed(LIQ);
    }

    // ── the unlock callback is pool-manager-only (no one can drive it directly) ──
    function test_unlockCallback_onlyPoolManager() public {
        vm.prank(stranger);
        vm.expectRevert(QpullLiquidityLock.NotPoolManager.selector);
        lock.unlockCallback(abi.encode(LIQ));
    }

    // ── the CORE GUARANTEE, at the ABI level: the lock exposes NO way to remove/withdraw/collect. Any such
    //    call reverts because the function simply does not exist on the contract (empty returndata / revert).
    //    This is belt-and-suspenders for the source-level fact that there is no negative-liquidity path. ──
    function test_noRemoveOrWithdrawSelectorsExist() public {
        lock.seed(LIQ);
        address L = address(lock);
        string[7] memory sigs = [
            "removeLiquidity(uint128)",
            "withdraw(uint256)",
            "withdrawAll()",
            "collect()",
            "collectFees()",
            "unlockAndRemove(uint128)",
            "sweep(address)"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            (bool ok,) = L.call(abi.encodeWithSignature(sigs[i]));
            assertFalse(ok, string.concat("unexpected removal path present: ", sigs[i]));
        }
        // and after seeding, the position liquidity the lock created is still recorded (never reduced here)
        assertEq(pm.lastLiquidity(), LIQ, "liquidity intact");
    }

    // ── constructor rejects zero wiring ──
    function test_constructor_rejectsZero() public {
        vm.expectRevert(QpullLiquidityLock.ZeroAddress.selector);
        new QpullLiquidityLock(IPoolManager(address(pm)), address(0), address(weth), 3000, 60, hook, opener);
    }

    // ── full-range ticks are aligned to tickSpacing ──
    function test_fullRangeTicksAligned() public view {
        int24 ts = 60;
        int24 expected = int24((int256(887_272) / int256(ts)) * int256(ts));
        assertEq(lock.tickUpper(), expected);
        assertEq(lock.tickLower(), -expected);
    }
}
