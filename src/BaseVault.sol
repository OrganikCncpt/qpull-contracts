// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IVault } from "./interfaces/IVault.sol";

/// @title  BaseVault
/// @notice Holds QUOTRON as pure prize inventory (spec §9) and pays it out fractionally ONLY on
///         the instruction of an authorized controller (an engine or the claim manager).
///         Tracks `unclaimedReserve` so `freeBalance` never counts prizes already owed (spec §8) —
///         the invariant that makes a pot structurally impossible to over-state.
/// @dev    payOut reverts if it would dip into `unclaimedReserve`, so the HONEST controller (ClaimManager,
///         which pairs one release with one payOut per claim) can never pay out funds already owed to a
///         winner. This protection is NOT unconditional (audit M-5): `release` takes a bare amount with no
///         claim binding, so a MALICIOUS controller could call release(unclaimedReserve) then payOut(...) to
///         drain owed funds. The sole controller (ClaimManager) is bound ONCE and is then immutable (audit
///         M-14/H-10/M-5): the owner can neither revoke it nor add a second, malicious controller, so this
///         reduces to trusting ClaimManager's own release/payOut pairing — which it does one-for-one per claim.
contract BaseVault is IVault, IERC721Receiver, Ownable2Step {
    using SafeERC20 for IERC20;

    IERC20 public immutable quotron;
    // The SINGLE controller (ClaimManager). Set ONCE, then immutable — never a second controller, never
    // revoked (audit M-14/H-10): the owner can neither lock prizes by de-authorizing nor add a malicious
    // controller, and the ">30-day interruption forfeits claims" scenario cannot arise.
    address public controller;
    uint256 public override unclaimedReserve;

    event ControllerSet(address indexed controller);
    event PaidOut(address indexed to, uint256 amount);
    event Reserved(uint256 amount, uint256 totalReserve);
    event Released(uint256 amount, uint256 totalReserve);

    error NotController();
    error ControllerAlreadySet();
    error ReserveUnderflow();
    error InsufficientFree();

    modifier onlyController() {
        if (msg.sender != controller) revert NotController();
        _;
    }

    constructor(address quotron_, address initialOwner) Ownable(initialOwner) {
        quotron = IERC20(quotron_);
    }

    /// @notice Bind the single controller (ClaimManager) ONCE — it can never be changed or revoked after
    ///         (audit M-14/H-10). Keep behind the timelock and set correctly at launch.
    function setController(address c) external onlyOwner {
        if (controller != address(0)) revert ControllerAlreadySet();
        if (c == address(0)) revert NotController();
        controller = c;
        emit ControllerSet(c);
    }

    /// @inheritdoc IVault
    function freeBalance() public view override returns (uint256) {
        uint256 bal = quotron.balanceOf(address(this));
        return bal > unclaimedReserve ? bal - unclaimedReserve : 0;
    }

    /// @inheritdoc IVault
    function payOut(address to, uint256 amount) external override onlyController {
        // audit H-8: never move reserved balance. On the normal claim path release() runs first (lowering
        // unclaimedReserve), so a legitimate payOut of a just-released claim still passes; a rogue controller
        // can at most reach free balance and can NEVER touch funds already owed to winners.
        if (amount + unclaimedReserve > quotron.balanceOf(address(this))) revert InsufficientFree();
        quotron.safeTransfer(to, amount);
        emit PaidOut(to, amount);
    }

    /// @inheritdoc IVault
    /// @dev Reserves against a written prize claim. Can only reserve genuinely free balance,
    ///      so total reservations can never exceed the held balance.
    function reserve(uint256 amount) external override onlyController {
        if (amount > freeBalance()) revert InsufficientFree();
        unclaimedReserve += amount;
        emit Reserved(amount, unclaimedReserve);
    }

    /// @inheritdoc IVault
    /// @dev Releases a reservation on claim (paired with payOut) or on claim-window expiry rollover.
    function release(uint256 amount) external override onlyController {
        if (amount > unclaimedReserve) revert ReserveUnderflow();
        unclaimedReserve -= amount;
        emit Released(amount, unclaimedReserve);
    }

    /// @notice Accept ERC-721 terminal mints (§13.3): QUOTRON is a custom ERC-404 whose auto-mint may
    ///         call this on a whole-unit crossing. Implementing it means such a receipt can never
    ///         revert — the vault safely holds whole units. The terminals are inert (never hardwired).
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }
}
