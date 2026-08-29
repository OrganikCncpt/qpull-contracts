// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IVault } from "./interfaces/IVault.sol";
import { IClaimManager } from "./interfaces/IClaimManager.sol";
import { LeaderboardRegistry } from "./LeaderboardRegistry.sol";

/// @title  LeaderboardEngine
/// @notice Distributes the weekly leaderboard pot to the top-25 buyers PRO-RATA by points (spec §11).
///         Linear weighting is sybil-NEUTRAL: splitting one wallet's points across many wallets yields
///         the same total share, so there is no incentive to split. (√-weighting was replaced — the audit
///         (H-20) showed it is sybil-POSITIVE: splitting wins MORE, and one actor filling all 25 slots
///         takes 100%.) A whale still earns proportional to its volume, which is the nature of a volume
///         board; concentration is limited only by the top-25 cap, not by the weighting curve.
/// @dev    Deterministic — no beacon. Drawable ONLY during the immediately following week (void-on-miss,
///         like the sibling engines): the pot is a live freeBalance snapshot, so unbounded catch-up would
///         let a stale week grab the whole running vault balance (audit H-2). A missed week's accrual simply
///         rolls forward into the next distributed week's pot.
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
    error OutsideWindow();

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
        if (currentWeek() != week + 1) revert OutsideWindow(); // the following week only — else void (audit H-2)

        // Snapshot the pot and guards BEFORE marking distributed, so an empty/zero-weight week is NOT
        // consumed (matches RaffleEngine/HolderDrawEngine — a funded retry can still pay within the window).
        uint256 cnt = registry.boardCount(week);
        uint256 pot = vault.freeBalance();
        if (cnt == 0 || pot == 0) {
            emit Distributed(week, pot, 0);
            return; // do NOT mark distributed
        }

        // Total points across the board - linear / pro-rata, sybil-neutral (audit H-20).
        uint256 totalW;
        for (uint256 i; i < cnt; ++i) {
            (, uint256 p) = registry.boardAt(week, i);
            totalW += p;
        }
        if (totalW == 0) {
            emit Distributed(week, pot, 0);
            return; // do NOT mark distributed
        }

        distributed[week] = true; // audit H-2: flag only once a real payout is committed
        uint64 deadline = uint64(block.timestamp + CLAIM_WINDOW);
        uint256 paid;
        for (uint256 i; i < cnt; ++i) {
            (address a, uint256 p) = registry.boardAt(week, i);
            uint256 share = (pot * p) / totalW;
            if (share == 0) continue;
            claimManager.registerClaim(address(vault), a, share, deadline);
            unchecked {
                ++paid;
            }
        }
        emit Distributed(week, pot, paid);
    }
}
