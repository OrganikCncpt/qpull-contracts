// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { BaseVault } from "../src/BaseVault.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { NonRenounceableOwnable2Step } from "../src/utils/NonRenounceableOwnable2Step.sol";

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

    // ─── pre-submission review fixes (both FAIL against pre-fix code) ─────────

    /// N-3. BaseVault was on NonRenounceableOwnable2Step's EXEMPT list, justified as "vestigial AFTER
    /// setController". The justification is order-dependent; the exemption was not. Deploy.s.sol constructs
    /// the vaults in one transaction and wires the controller in a LATER one, so a revert in between (or a
    /// compromised deployer key, for which this is the cheapest one-shot kill) could renounce and leave
    /// setController permanently uncallable and every QUOTRON later routed here permanently frozen.
    function test_n3_cannotRenounceBeforeController() public {
        BaseVault fresh = _freshUnset();
        vm.prank(owner);
        vm.expectRevert(NonRenounceableOwnable2Step.OwnershipCannotBeRenounced.selector);
        fresh.renounceOwnership();
        // still wireable, which is the whole point
        vm.prank(owner);
        fresh.setController(controller);
        assertEq(fresh.controller(), controller, "vault still wireable after the refused renounce");
    }

    /// N-3, after wiring: still refused. Harmless either way (the owner has no powers left), but the
    /// guarantee should not depend on WHEN it is called.
    function test_n3_cannotRenounceAfterController() public {
        vm.prank(owner);
        vm.expectRevert(NonRenounceableOwnable2Step.OwnershipCannotBeRenounced.selector);
        vault.renounceOwnership();
        assertEq(vault.owner(), owner, "owner intact");
    }

    /// N-4. The 721 hook accepted ANY token from ANY sender. There is exactly one outbound call in this
    /// contract (quotron.safeTransfer), no transferFrom, no rescue and nothing virtual, so anything else
    /// that landed here was destroyed — and parking >= MIN_HOLD passes made qualifiedSince[vault]
    /// permanently un-clearable, turning the vault into a forever-eligible holder-draw candidate whose
    /// claims can never be settled. All three vault addresses are published deploy output.
    function test_n4_rejectsNftFromAnyoneButQuotron() public {
        vm.prank(stranger);
        vm.expectRevert(BaseVault.UnexpectedNft.selector);
        vault.onERC721Received(stranger, stranger, 1, "");

        // a plausible accident: someone safeTransferFrom's a real pass to a published vault address
        address passCollection = makeAddr("NFTCollection");
        vm.prank(passCollection);
        vm.expectRevert(BaseVault.UnexpectedNft.selector);
        vault.onERC721Received(passCollection, winner, 42, "");
    }

    /// N-4 must not break the documented §13.3 purpose: QUOTRON's own ERC-404 auto-mint always calls with
    /// msg.sender == quotron, and that path still has to be accepted or a whole-unit crossing could revert.
    function test_n4_stillAcceptsQuotronsOwnAutoMint() public {
        vm.prank(address(quotron));
        bytes4 sel = vault.onERC721Received(address(quotron), address(vault), 7, "");
        assertEq(sel, IERC721Receiver.onERC721Received.selector, "QUOTRON terminal mint still accepted");
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

    /// NARROWED by pre-submission review N-4: the hook used to return the selector for ANY caller, which is
    /// what made the vault a one-way ERC-721 sink. The selector contract still holds, but only for QUOTRON —
    /// see test_n4_rejectsNftFromAnyoneButQuotron for the branch this test used to cover by accident.
    function test_onERC721Received_returnsSelectorForQuotron() public {
        vm.prank(address(quotron));
        bytes4 sel = vault.onERC721Received(address(0), address(0), 1, "");
        assertEq(sel, BaseVault.onERC721Received.selector);
    }

    function _freshUnset() internal returns (BaseVault v) {
        vm.prank(owner);
        v = new BaseVault(address(quotron), owner);
    }
}
