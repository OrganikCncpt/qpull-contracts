// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IDrandOracle } from "./interfaces/IDrandOracle.sol";
import { IVault } from "./interfaces/IVault.sol";
import { IClaimManager } from "./interfaces/IClaimManager.sol";
import { PackRegistry } from "./PackRegistry.sol";

/// @title  RaffleEngine
/// @notice Runs the DAILY draw (spec §7). Snapshots the PrizeVault's free QUOTRON as the pot,
///         splits it into fixed tier buckets, draws a fixed K winners from the live set, and writes
///         a claim to each winner for its tier's share. Fully on-chain, O(K).
///
/// @dev    Tier buckets (of the pot): SuperRare 45% / Rare 25% / Uncommon 20% / Common 10%.
///         A tier with no winner this day isn't paid — its share stays in the vault and swells the
///         next snapshot (the Super-Rare rollover/climb). A lone SR winner takes at most the 45%
///         bucket; the other 55% is guaranteed to the lower tiers — the per-tier bucket IS the cap.
///         Void-on-miss (§14): a day is drawable ONLY during the following day; miss it and its pot
///         simply stays in the vault. No catch-up — that would hand the keeper a timing advantage.
contract RaffleEngine is Ownable2Step, ReentrancyGuard {
    IDrandOracle public immutable drand;
    PackRegistry public immutable packs;
    IVault public immutable vault;
    IClaimManager public immutable claimManager;
    uint256 public immutable genesis;

    uint256 internal constant DAY = 1 days;
    uint256 public constant CLAIM_WINDOW = 30 days;
    // Settling beacon reveals REVEAL_LAG after the day closes, so it is unknowable while any in-day ticket
    // is still buyable — otherwise a last-second buyer could grind entries against a now-public beacon
    // (audit-2 root cause; mirrors PackRegistry's revealDelay).
    // AUDIT M-7 residual (documented, accepted): RH's sequencer may back-date block.timestamp by up to
    // maxTimeVariation.delaySeconds = 4 days (confirmed on-chain). A DAILY cadence structurally cannot set
    // REVEAL_LAG above ~1 day (it must leave a same-following-day draw window), so — unlike the 14-day
    // jackpot and weekly holder draw, which DO exceed the 4-day bound — the daily raffle cannot code-
    // enforce this against a maximally back-dating sequencer. It relies on the standard trusted-sequencer
    // assumption every Arbitrum L2 already requires for all timestamp logic. The residual is bounded: the
    // daily pot is small and split across tier buckets among K winners (far lower value than the winner-
    // take-all jackpot), and the attack requires the RH-operated sequencer to catastrophically mis-stamp
    // time — which would break the whole chain, not just this raffle. See SECURITY.md §10 (M-7).
    uint256 internal constant REVEAL_LAG = 1 hours;
    uint256 public constant MAX_K = 200; // audit M-3: one-block-safe (was 1000; ~120-140k gas/winner)
    uint256 internal constant BPS = 10_000;

    uint256 public winnersPerDay; // K
    // Owner-set MINIMUM pot below which a draw voids WITHOUT consuming the day or burning tickets — closes
    // the dust-donation grief where anyone raises freeBalance() to force a draw that burns live tickets for
    // ~1-wei prizes (audit C-1). Default 0 => MUST be set at launch (runbook).
    uint256 public minPot;
    // Owner-set bound on a single day's payout (audit H-3): RaffleEngine was the only draw engine without a
    // potCap, so a known winner could DELAY runDraw while convert() kept funding this vault, then draw an
    // inflated pot (the tier-bucket split caps the winner's FRACTION, never the pot's absolute size). Default
    // uncapped for back-compat; owner sets a concrete cap at launch. Excess over the cap rolls forward.
    uint256 public potCap = type(uint256).max;
    mapping(uint32 => bool) public drawn;

    event WinnersPerDaySet(uint256 k);
    event DrawExecuted(uint32 indexed day, uint256 pot, uint256 winners);
    event MinPotSet(uint256 minPot);
    event PotCapSet(uint256 potCap);

    error AlreadyDrawn();
    error BadDay();
    error OutsideWindow();
    error BadK();
    error GenesisMismatch();
    error BadPotCap();

    constructor(
        address drand_,
        address packs_,
        address vault_,
        address claim_,
        uint256 genesis_,
        uint256 k_,
        address initialOwner
    ) Ownable(initialOwner) {
        drand = IDrandOracle(drand_);
        packs = PackRegistry(packs_);
        vault = IVault(vault_);
        claimManager = IClaimManager(claim_);
        if (PackRegistry(packs_).genesis() != genesis_) revert GenesisMismatch(); // audit H-8
        genesis = genesis_;
        if (k_ == 0 || k_ > MAX_K) revert BadK();
        winnersPerDay = k_;
    }

    function setWinnersPerDay(uint256 k) external onlyOwner {
        if (k == 0 || k > MAX_K) revert BadK();
        winnersPerDay = k;
        emit WinnersPerDaySet(k);
    }

    /// @notice Set the minimum pot below which a draw voids without consuming the day (audit C-1).
    ///         Cross-checked against potCap (audit L-3): minPot > potCap would silently void every draw.
    function setMinPot(uint256 m) external onlyOwner {
        if (m > potCap) revert BadPotCap();
        minPot = m;
        emit MinPotSet(m);
    }

    /// @notice Bound a single day's payout (audit H-3). Excess over the cap rolls forward.
    function setPotCap(uint256 c) external onlyOwner {
        if (c == 0 || c < minPot) revert BadPotCap(); // audit L-3: never below the minPot floor
        potCap = c;
        emit PotCapSet(c);
    }

    /// @notice The drand round whose beacon settles day `day` — publishes REVEAL_LAG after day+1 opens,
    ///         so it is unknowable while any in-window ticket is still being bought.
    function drawRound(uint32 day) public view returns (uint64) {
        return drand.roundAt(genesis + (uint256(day) + 1) * DAY + REVEAL_LAG);
    }

    function currentDay() public view returns (uint32) {
        if (block.timestamp <= genesis) return 0;
        return uint32((block.timestamp - genesis) / DAY);
    }

    /// @notice Tier bucket share in bps. 0=Common,1=Uncommon,2=Rare,3=SuperRare.
    function bucketBps(uint8 tier) public pure returns (uint256) {
        if (tier == 3) return 4500; // Super Rare 45%
        if (tier == 2) return 2500; // Rare 25%
        if (tier == 1) return 2000; // Uncommon 20%
        return 1000; // Common 10%
    }

    function runDraw(uint32 day) external nonReentrant {
        if (drawn[day]) revert AlreadyDrawn();
        if (day == 0) revert BadDay();
        if (currentDay() != day + 1) revert OutsideWindow(); // the day after only — else void

        // Snapshot the pot BEFORE touching tickets. If nothing is payable, do NOT run the draw: drawFrom
        // marks tickets spent, so drawing on a zero pot would burn ticket eligibility for no payout (audit
        // fix). We also don't mark the day drawn — a retry can still pay out if the vault is funded later
        // within this window; missing the whole window voids the day and the pot rolls forward.
        uint256 pot = vault.freeBalance();
        if (pot > potCap) pot = potCap; // audit H-3: bound the single-day payout; excess rolls forward
        // Skip (WITHOUT burning tickets or marking the day drawn) when the pot is too small to pay even a full
        // field of winners in the SMALLEST tier bucket. This guarantees every drawn winner receives >=1 wei,
        // so no ticket is ever spent for a zero payout (audit H-17; subsumes the old pot==0 guard). The
        // smallest bucket is Common = pot*bucketBps(0)/BPS = pot/10; dividing it among up to winnersPerDay
        // winners is >=1 exactly when smallestBucket >= winnersPerDay.
        if (pot < minPot || (pot * bucketBps(0)) / BPS < winnersPerDay) {
            emit DrawExecuted(day, pot, 0);
            return; // retry when funded (audit C-1: sub-minPot dust never consumes the day or burns tickets)
        }

        bytes32 beacon = drand.randomness(drawRound(day)); // reverts if beacon missing (retry within window)
        drawn[day] = true;

        uint256[] memory winners = packs.drawFrom(beacon, day, winnersPerDay);
        uint256 n = winners.length;
        if (n == 0) {
            emit DrawExecuted(day, pot, 0);
            return;
        }

        // Pass 1: resolve tiers and count winners per tier.
        uint8[] memory tiers = new uint8[](n);
        uint256[4] memory counts;
        for (uint256 i; i < n; ++i) {
            uint8 t = packs.tierOf(winners[i]);
            tiers[i] = t;
            unchecked {
                counts[t] += 1;
            }
        }

        // Pass 2: write a claim to each winner for its equal share of its tier bucket. Single combined
        // division (audit L-14) — (pot·bps)/(BPS·count) — avoids the extra floor of a two-step divide.
        // Unpaid buckets (tiers with no winner) simply stay in the vault → next snapshot.
        uint64 deadline = uint64(block.timestamp + CLAIM_WINDOW);
        for (uint256 i; i < n; ++i) {
            uint8 t = tiers[i];
            uint256 prize = (pot * bucketBps(t)) / (BPS * counts[t]);
            if (prize == 0) continue;
            claimManager.registerClaim(address(vault), packs.ownerOf(winners[i]), prize, deadline);
        }
        emit DrawExecuted(day, pot, n);
    }
}
