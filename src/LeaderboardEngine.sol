// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IVault } from "./interfaces/IVault.sol";
import { IClaimManager } from "./interfaces/IClaimManager.sol";
import { LeaderboardRegistry } from "./LeaderboardRegistry.sol";

/// @title  LeaderboardEngine
/// @notice Distributes the weekly leaderboard pot to the top-25 buyers, weighted by √points
///         (spec §11). √-weighting blunts whale dominance and, with the 0.5% funded slice, keeps
///         the board –EV to farm.
/// @dev    Deterministic — no beacon. Per spec §15 a missed run is safely re-runnable, so this
///         allows catch-up for any closed, not-yet-distributed week (no timing advantage exists).
contract LeaderboardEngine is Ownable2Step {
    LeaderboardRegistry public immutable registry;
    IVault public immutable vault;
    IClaimManager public immutable claimManager;
    uint256 public immutable genesis;

    uint256 internal constant WEEK = 7 days;
    uint256 public constant CLAIM_WINDOW = 30 days;

    mapping(uint256 => bool) public distributed;

    event Distributed(uint256 indexed week, uint256 pot, uint256 winners);

    error AlreadyDistributed();
    error NotClosed();

    constructor(address registry_, address vault_, address claim_, uint256 genesis_, address o) Ownable(o) {
        registry = LeaderboardRegistry(registry_);
        vault = IVault(vault_);
        claimManager = IClaimManager(claim_);
        genesis = genesis_;
    }

    function currentWeek() public view returns (uint256) {
        if (block.timestamp <= genesis) return 0;
        return (block.timestamp - genesis) / WEEK;
    }

    function distribute(uint256 week) external {
        if (distributed[week]) revert AlreadyDistributed();
        if (currentWeek() <= week) revert NotClosed(); // closed weeks only; catch-up allowed
        distributed[week] = true;

        uint256 cnt = registry.boardCount(week);
        uint256 pot = vault.freeBalance();
        if (cnt == 0 || pot == 0) {
            emit Distributed(week, pot, 0);
            return;
        }

        // Total √-weight across the board.
        uint256 totalW;
        for (uint256 i; i < cnt; ++i) {
            (, uint256 p) = registry.boardAt(week, i);
            totalW += Math.sqrt(p);
        }
        if (totalW == 0) {
            emit Distributed(week, pot, 0);
            return;
        }

        uint64 deadline = uint64(block.timestamp + CLAIM_WINDOW);
        uint256 paid;
        for (uint256 i; i < cnt; ++i) {
            (address a, uint256 p) = registry.boardAt(week, i);
            uint256 share = (pot * Math.sqrt(p)) / totalW;
            if (share == 0) continue;
            claimManager.registerClaim(address(vault), a, share, deadline);
            unchecked {
                ++paid;
            }
        }
        emit Distributed(week, pot, paid);
    }
}
