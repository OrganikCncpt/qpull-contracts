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
/// @dev    Deliberately has NO owner-drain path. The only owner power is authorizing controllers
///         (set at launch, then renounce). This removes the obvious rug vector for an auditor.
contract BaseVault is IVault, IERC721Receiver, Ownable2Step {
    using SafeERC20 for IERC20;

    IERC20 public immutable quotron;
    mapping(address => bool) public isController; // engine(s) + claim manager
    uint256 public override unclaimedReserve;

    event ControllerSet(address indexed controller, bool authorized);
    event PaidOut(address indexed to, uint256 amount);
    event Reserved(uint256 amount, uint256 totalReserve);
    event Released(uint256 amount, uint256 totalReserve);

    error NotController();
    error ReserveUnderflow();
    error InsufficientFree();

    modifier onlyController() {
        if (!isController[msg.sender]) revert NotController();
        _;
    }

    constructor(address quotron_, address initialOwner) Ownable(initialOwner) {
        quotron = IERC20(quotron_);
    }

    function setController(address c, bool authorized) external onlyOwner {
        isController[c] = authorized;
        emit ControllerSet(c, authorized);
    }

    /// @inheritdoc IVault
    function freeBalance() public view override returns (uint256) {
        uint256 bal = quotron.balanceOf(address(this));
        return bal > unclaimedReserve ? bal - unclaimedReserve : 0;
    }

    /// @inheritdoc IVault
    function payOut(address to, uint256 amount) external override onlyController {
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
