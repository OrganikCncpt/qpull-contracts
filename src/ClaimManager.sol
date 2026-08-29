// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IVault } from "./interfaces/IVault.sol";
import { IClaimManager } from "./interfaces/IClaimManager.sol";

/// @title  ClaimManager
/// @notice Pull-payment claims for all three games (spec §8). An authorized engine registers a
///         prize — which reserves it against the vault's free balance — and the winner claims within
///         the 30-day window. An unclaimed prize is swept back to the vault and rolls into future pots.
/// @dev    This contract is the sole authorized controller on the vaults. It never holds funds.
contract ClaimManager is IClaimManager, Ownable2Step, ReentrancyGuard {
    struct Claim {
        address vault;
        address recipient;
        uint256 amount;
        uint64 deadline;
        bool settled;
    }

    mapping(uint256 => Claim) public claims;
    uint256 public nextClaimId;
    mapping(address => bool) public isEngine;

    event EngineSet(address indexed engine, bool authorized);
    event ClaimRegistered(
        uint256 indexed id, address vault, address recipient, uint256 amount, uint64 deadline
    );
    event Claimed(uint256 indexed id, address indexed recipient, uint256 amount);
    event Swept(uint256 indexed id, uint256 amount);

    error NotEngine();
    error NotRecipient();
    error AlreadySettled();
    error Expired();
    error NotExpired();

    constructor(address initialOwner) Ownable(initialOwner) { }

    function setEngine(address e, bool authorized) external onlyOwner {
        isEngine[e] = authorized;
        emit EngineSet(e, authorized);
    }

    /// @inheritdoc IClaimManager
    function registerClaim(address vault, address recipient, uint256 amount, uint64 deadline)
        external
        override
        returns (uint256 id)
    {
        if (!isEngine[msg.sender]) revert NotEngine();
        IVault(vault).reserve(amount); // reserves against free balance — reverts if insufficient
        id = ++nextClaimId;
        claims[id] = Claim(vault, recipient, amount, deadline, false);
        emit ClaimRegistered(id, vault, recipient, amount, deadline);
    }

    function claim(uint256 id) external nonReentrant {
        Claim storage c = claims[id];
        if (c.settled) revert AlreadySettled();
        if (msg.sender != c.recipient) revert NotRecipient();
        if (block.timestamp > c.deadline) revert Expired();
        _settleAndPay(id, c);
    }

    /// @notice Claim MANY prizes in one transaction (the "claim all" path). An id that is not the caller's,
    ///         already settled, or past its 30-day window is SKIPPED — never reverted — so a single stale id
    ///         can't brick the whole batch. Only the caller's own claims are ever paid (recipient check is
    ///         enforced per id), and each still runs full CEI. Returns how many were actually paid; the
    ///         caller sizes `ids` to stay within the block gas limit.
    function claimBatch(uint256[] calldata ids) external nonReentrant returns (uint256 claimed) {
        uint256 n = ids.length;
        for (uint256 i; i < n; ++i) {
            uint256 id = ids[i];
            Claim storage c = claims[id];
            if (c.settled || msg.sender != c.recipient || block.timestamp > c.deadline) continue;
            _settleAndPay(id, c);
            unchecked {
                ++claimed;
            }
        }
    }

    /// @dev Effects-before-interactions: mark settled, release the reserve, then pay out. nonReentrant on the
    ///      external entrypoints backs up CEI against an ERC-404 receiver-hook reentry.
    function _settleAndPay(uint256 id, Claim storage c) private {
        c.settled = true;
        IVault(c.vault).release(c.amount);
        IVault(c.vault).payOut(c.recipient, c.amount);
        emit Claimed(id, c.recipient, c.amount);
    }

    /// @notice After the window closes, return an unclaimed prize to the vault (rolls into future pots).
    function sweepExpired(uint256 id) external nonReentrant {
        Claim storage c = claims[id];
        if (c.settled) revert AlreadySettled();
        if (block.timestamp <= c.deadline) revert NotExpired();
        c.settled = true;
        IVault(c.vault).release(c.amount);
        emit Swept(id, c.amount);
    }
}
