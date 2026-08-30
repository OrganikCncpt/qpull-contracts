// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
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
contract JackpotEngine is Ownable2Step, ReentrancyGuard {
    IDrandOracle public immutable drand;
    JackpotRegistry public immutable registry;
    IVault public immutable vault;
    IClaimManager public immutable claimManager;
    uint256 public immutable genesis;

    uint256 public constant PERIOD = 14 days;
    uint256 public constant CLAIM_WINDOW = 30 days;
    // Owner-set bound on a single draw's payout (audit H-3B/M-9). Default uncapped for back-compat; the
    // owner sets a concrete cap at launch (behind the timelock). Caps how much a delaying known-winner can
    // absorb from the next period, and keeps a single QUOTRON prize within one-transfer gas. Excess rolls
    // forward in the vault, like HolderDrawEngine's potCap.
    uint256 public potCap = type(uint256).max;
    // MINIMUM pot below which a draw voids WITHOUT consuming the period — closes the dust-donation grief
    // where anyone raises freeBalance() by a few wei to force a 1-wei winner and roll the real 14-day pot
    // forward (audit C-1). REQUIRED (> 0) at construction (audit H-2): unlike RaffleEngine/LeaderboardEngine,
    // this engine has no config-independent floor, so a 0 default here was the live dust-grief. Owner re-tunes
    // via setMinPot (bounded by potCap, audit L-3).
    uint256 public minPot;
    // The settling beacon is bound to a drand round REVEAL_LAG after entries close, so it is unknowable
    // while the last entry of the period is still recordable. Without it, a last-second trader could size
    // their entry to a now-public beacon and deterministically capture the whole 14-day pot (audit-2).
    // SIZED TO ROBINHOOD CHAIN'S SEQUENCER CLOCK (audit M-7): RH's SequencerInbox reports
    // maxTimeVariation.delaySeconds = 345_600 (4 days) — the max the sequencer may stamp block.timestamp
    // BEHIND real time (confirmed on-chain). To make the guarantee CODE-ENFORCED rather than a
    // trusted-sequencer assumption, REVEAL_LAG must exceed that bound: 5 days > 4 days, with a 1-day
    // buffer. The 14-day draw window easily absorbs this (leaves a ~9-day window to draw). This closes
    // M-7 for the jackpot — the highest-value target (winner-take-all).
    uint256 internal constant REVEAL_LAG = 5 days;

    mapping(uint256 => bool) public drawn;

    event DrawExecuted(uint256 indexed period, uint256 pot, address indexed winner);
    event PotCapSet(uint256 potCap);
    event MinPotSet(uint256 minPot);

    error AlreadyDrawn();
    error OutsideWindow();
    error BadPotCap();
    error BadMinPot();
    error GenesisMismatch();

    constructor(
        address drand_,
        address registry_,
        address vault_,
        address claim_,
        uint256 genesis_,
        uint256 minPot_,
        address o
    ) Ownable(o) {
        if (minPot_ == 0) revert BadMinPot(); // audit H-2: no unsafe 0 default — enforced on-chain at deploy
        drand = IDrandOracle(drand_);
        registry = JackpotRegistry(registry_);
        vault = IVault(vault_);
        claimManager = IClaimManager(claim_);
        if (JackpotRegistry(registry_).genesis() != genesis_) revert GenesisMismatch(); // audit H-8
        genesis = genesis_;
        minPot = minPot_;
    }

    /// @notice Bound a single draw's payout (audit H-3B/M-9). Never below the minPot floor (audit L-3).
    function setPotCap(uint256 c) external onlyOwner {
        if (c == 0 || c < minPot) revert BadPotCap();
        potCap = c;
        emit PotCapSet(c);
    }

    /// @notice Set the minimum pot below which a draw voids without consuming the period (audit C-1).
    ///         Must stay > 0 and <= potCap (audit H-2/L-3).
    function setMinPot(uint256 m) external onlyOwner {
        if (m == 0 || m > potCap) revert BadMinPot();
        minPot = m;
        emit MinPotSet(m);
    }

    function jackpotRound(uint256 period) public view returns (uint64) {
        return drand.roundAt(genesis + (period + 1) * PERIOD + REVEAL_LAG);
    }

    function currentPeriod() public view returns (uint256) {
        if (block.timestamp <= genesis) return 0;
        return (block.timestamp - genesis) / PERIOD;
    }

    function runDraw(uint256 period) external nonReentrant {
        if (drawn[period]) revert AlreadyDrawn();
        if (currentPeriod() != period + 1) revert OutsideWindow();

        bytes32 beacon = drand.randomness(jackpotRound(period));

        // Snapshot pot/total BEFORE marking drawn: for a winner-take-all jackpot, freeBalance()==0 is the
        // normal state during a claim window, so marking drawn first would permanently void the period on a
        // zero pot with no retry (audit H-3; matches RaffleEngine/HolderDrawEngine's deliberate handling).
        uint256 total = registry.periodTotal(period);
        uint256 pot = vault.freeBalance();
        if (pot > potCap) pot = potCap; // audit H-3B/M-9: bound the single-draw payout; excess rolls forward
        if (total == 0 || pot == 0 || pot < minPot) {
            emit DrawExecuted(period, pot, address(0));
            return; // do NOT mark drawn (audit C-1: a sub-minPot dust pot never consumes the period)
        }
        drawn[period] = true;

        uint256 r = uint256(beacon) % total;
        address winner = registry.winnerAt(period, r);
        claimManager.registerClaim(address(vault), winner, pot, uint64(block.timestamp + CLAIM_WINDOW));
        emit DrawExecuted(period, pot, winner);
    }
}
