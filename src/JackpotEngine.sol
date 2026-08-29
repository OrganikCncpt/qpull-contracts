// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IDrandOracle } from "./interfaces/IDrandOracle.sol";
import { IVault } from "./interfaces/IVault.sol";
import { IClaimManager } from "./interfaces/IClaimManager.sol";
import { JackpotRegistry } from "./JackpotRegistry.sol";

/// @title  JackpotEngine
/// @notice Runs the **14-day** pari-mutuel jackpot draw (spec §10): one winner, weighted by entries,
///         takes the whole pot. Winner-takes-all drains the vault each period, so in the normal case
///         the pot equals that period's contributions and the farm cap holds.
/// @dev    Void-on-miss (§14): drawable only during the following period; miss it and the pot stays
///         in the vault. (A void period's rollover is a known edge for the hardening pass.)
contract JackpotEngine is Ownable2Step {
    IDrandOracle public immutable drand;
    JackpotRegistry public immutable registry;
    IVault public immutable vault;
    IClaimManager public immutable claimManager;
    uint256 public immutable genesis;

    uint256 public constant PERIOD = 14 days;
    uint256 public constant CLAIM_WINDOW = 30 days;
    // The settling beacon is bound to a drand round REVEAL_LAG after entries close, so it is unknowable
    // while the last entry of the period is still recordable — even under block.timestamp manipulation
    // (a searcher would have to push block.timestamp a full hour into the past). Mirrors PackRegistry's
    // revealDelay. Without it, a last-second trader could size their entry to a now-public beacon and
    // deterministically capture the whole 14-day pot (audit-2 finding).
    uint256 internal constant REVEAL_LAG = 1 hours;

    mapping(uint256 => bool) public drawn;

    event DrawExecuted(uint256 indexed period, uint256 pot, address indexed winner);

    error AlreadyDrawn();
    error OutsideWindow();

    constructor(
        address drand_,
        address registry_,
        address vault_,
        address claim_,
        uint256 genesis_,
        address o
    ) Ownable(o) {
        drand = IDrandOracle(drand_);
        registry = JackpotRegistry(registry_);
        vault = IVault(vault_);
        claimManager = IClaimManager(claim_);
        genesis = genesis_;
    }

    /// @notice The drand round settling `period` — reveals REVEAL_LAG AFTER the period closes, so it is
    ///         unknowable while any in-period entry can still be recorded.
    function jackpotRound(uint256 period) public view returns (uint64) {
        return drand.roundAt(genesis + (period + 1) * PERIOD + REVEAL_LAG);
    }

    function currentPeriod() public view returns (uint256) {
        if (block.timestamp <= genesis) return 0;
        return (block.timestamp - genesis) / PERIOD;
    }

    function runDraw(uint256 period) external {
        if (drawn[period]) revert AlreadyDrawn();
        if (currentPeriod() != period + 1) revert OutsideWindow();

        bytes32 beacon = drand.randomness(jackpotRound(period));
        drawn[period] = true;

        uint256 total = registry.periodTotal(period);
        uint256 pot = vault.freeBalance();
        if (total == 0 || pot == 0) {
            emit DrawExecuted(period, pot, address(0));
            return;
        }

        uint256 r = uint256(beacon) % total;
        address winner = registry.winnerAt(period, r);
        claimManager.registerClaim(address(vault), winner, pot, uint64(block.timestamp + CLAIM_WINDOW));
        emit DrawExecuted(period, pot, winner);
    }
}
