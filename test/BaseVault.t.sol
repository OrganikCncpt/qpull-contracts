// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { BaseVault } from "../src/BaseVault.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice FS-4 (fullstack audit): BaseVault is the sole custodian of all prize QUOTRON, and its guards
///         (onlyController, the pay-out-never-dips-into-reserve invariant, reserve/release accounting) were
///         only ever exercised indirectly through integration flows — no test asserted the revert branches.
///         This suite pins every negative path plus the freeBalance / reserve math directly.
contract BaseVaultTest is Test {
    BaseVault vault;
    MockERC20 quotron;

    address owner = makeAddr("owner");
    address controller = makeAddr("controller");
    address stranger = makeAddr("stranger");
    address winner = makeAddr("winner");

    uint256 constant FUND = 1_000e18;

    function setUp() public {
        quotron = new MockERC20();
        vm.prank(owner);
        vault = new BaseVault(address(quotron), owner);
        vm.prank(owner);
        vault.setController(controller);
        quotron.mint(address(vault), FUND);
    }

    // ─── setController (write-once, owner-only, non-zero) ─────────────────────

    function test_setController_revertsForNonOwner() public {
        BaseVault fresh = _freshUnset();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        fresh.setController(controller);
    }

    function test_setController_revertsOnZero() public {
        BaseVault fresh = _freshUnset();
        vm.prank(owner);
        vm.expectRevert(BaseVault.NotController.selector);
        fresh.setController(address(0));
    }

    function test_setController_revertsOnSecondSet() public {
        // vault already has its controller bound in setUp
        vm.prank(owner);
        vm.expectRevert(BaseVault.ControllerAlreadySet.selector);
        vault.setController(stranger);
    }

    // ─── payOut (onlyController, never dips into reserve) ─────────────────────

    function test_payOut_revertsForNonController() public {
        vm.prank(stranger);
        vm.expectRevert(BaseVault.NotController.selector);
        vault.payOut(winner, 1e18);
    }

    function test_payOut_revertsWhenAmountExceedsBalance() public {
        vm.prank(controller);
        vm.expectRevert(BaseVault.InsufficientFree.selector);
        vault.payOut(winner, FUND + 1);
    }

    function test_payOut_cannotDipIntoReserve() public {
        // reserve 600 of the 1000 held; only 400 is free
        vm.prank(controller);
        vault.reserve(600e18);
        assertEq(vault.freeBalance(), 400e18);

        // paying 401 (into the reserved 600) must revert; 400 (exactly free) must pass
        vm.prank(controller);
        vm.expectRevert(BaseVault.InsufficientFree.selector);
        vault.payOut(winner, 400e18 + 1);

        vm.prank(controller);
        vault.payOut(winner, 400e18);
        assertEq(quotron.balanceOf(winner), 400e18);
        assertEq(vault.unclaimedReserve(), 600e18); // reserve untouched
    }

    // ─── reserve (onlyController, only free balance) ──────────────────────────

    function test_reserve_revertsForNonController() public {
        vm.prank(stranger);
        vm.expectRevert(BaseVault.NotController.selector);
        vault.reserve(1e18);
    }

    function test_reserve_revertsAboveFreeBalance() public {
        vm.prank(controller);
        vm.expectRevert(BaseVault.InsufficientFree.selector);
        vault.reserve(FUND + 1);
    }

    function test_reserve_cannotDoubleReserveSameFunds() public {
        vm.prank(controller);
        vault.reserve(FUND); // reserves everything -> freeBalance 0
        assertEq(vault.freeBalance(), 0);
        vm.prank(controller);
        vm.expectRevert(BaseVault.InsufficientFree.selector);
        vault.reserve(1); // nothing free left
    }

    // ─── release (onlyController, cannot underflow) ───────────────────────────

    function test_release_revertsForNonController() public {
        vm.prank(controller);
        vault.reserve(100e18);
        vm.prank(stranger);
        vm.expectRevert(BaseVault.NotController.selector);
        vault.release(100e18);
    }

    function test_release_revertsOnUnderflow() public {
        vm.prank(controller);
        vault.reserve(100e18);
        vm.prank(controller);
        vm.expectRevert(BaseVault.ReserveUnderflow.selector);
        vault.release(100e18 + 1);
    }

    function test_release_freesReservedBalance() public {
        vm.prank(controller);
        vault.reserve(300e18);
        vm.prank(controller);
        vault.release(300e18);
        assertEq(vault.unclaimedReserve(), 0);
        assertEq(vault.freeBalance(), FUND);
    }

    // ─── freeBalance math (floors at 0, never negative) ───────────────────────

    function test_freeBalance_floorsAtZeroWhenReserveExceedsBalance() public {
        // reserve all, then drain the held balance out from under the reservation via a raw transfer;
        // freeBalance must report 0 (bal < reserve), never revert or wrap.
        vm.prank(controller);
        vault.reserve(FUND);
        vm.prank(address(vault));
        quotron.transfer(stranger, FUND); // simulate balance leaving (e.g. a prior payout accounting)
        assertEq(vault.freeBalance(), 0);
    }

    // ─── onERC721Received (ERC-404 whole-unit terminal receipt never reverts) ─

    function test_onERC721Received_returnsSelector() public view {
        bytes4 sel = vault.onERC721Received(address(0), address(0), 1, "");
        assertEq(sel, BaseVault.onERC721Received.selector);
    }

    function _freshUnset() internal returns (BaseVault v) {
        vm.prank(owner);
        v = new BaseVault(address(quotron), owner);
    }
}
