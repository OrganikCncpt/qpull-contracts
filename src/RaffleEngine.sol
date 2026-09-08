// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { NonRenounceableOwnable2Step } from "./utils/NonRenounceableOwnable2Step.sol";
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
contract RaffleEngine is NonRenounceableOwnable2Step, ReentrancyGuard {
    IDrandOracle public immutable drand;
    PackRegistry public immutable packs;
    IVault public immutable vault;
    IClaimManager public immutable claimManager;
    uint256 public immutable genesis;

    // Daily-draw cadence. `virtual` so the TESTNET-ONLY subclass shortens it; MAINNET uses the real 1 day
    // automatically (no "revert before mainnet" hand-edit — that footgun is gone). Mirrors the jackpot/
    // holder/leaderboard cadence getters. MUST equal PackRegistry.DAY() (both default 1 day) — enforced at
    // construction against PackRegistry.dayLength() (pre-audit cadence cross-check, mirrors the genesis one).
    function DAY() internal view virtual returns (uint256) { return 1 days; }
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
    uint256 internal constant MAX_ADJ_BPS = 2500; // audit M4 (job-745): potCap re-peg bounded to +/-25%/cooldown
    // ── launch accumulation window (spec §16.x): NO draws for the first 48h — packs + pool build, then the
    // one-time opening draw runs, then normal daily draws. ACCUM_DAYS * DAY = 48h on mainnet (DAY=1d) and
    // 10 min on the short-day testnet (DAY=5m), so it scales automatically with DAY. ──
    uint256 internal constant ACCUM_DAYS = 2; // accumulation window length, in days
    uint256 public constant OPENING_WINNERS = 5; // the opening draw splits the built-up pool 5 ways

    uint256 public winnersPerDay; // K
    // Owner-set MINIMUM pot below which a draw voids WITHOUT consuming the day or burning tickets — closes
    // the dust-donation grief where anyone raises freeBalance() to force a draw that burns live tickets for
    // ~1-wei prizes (audit C-1). Default 0 => MUST be set at launch (runbook).
    uint256 public minPot;
    // Owner-set bound on a single day's payout (audit H-3): RaffleEngine was the only draw engine without a
    // potCap, so a known winner could DELAY runDraw while convert() kept funding this vault, then draw an
    // inflated pot (the tier-bucket split caps the winner's FRACTION, never the pot's absolute size).
    // audit F14 (pass-5): REQUIRED (> 0) at construction now — matches minPot and HolderDrawEngine. No more
    // type(uint256).max fail-open default that let a sole entrant capture a whole rolled-forward balance
    // before the owner remembered to setPotCap. Excess over the cap rolls forward.
    uint256 public potCap;
    uint64 public lastPotAdjust; // audit M4 (job-745): timestamp of the last setPotCap (cooldown anchor)
    uint64 public lastMinPotAdjust; // audit L-10 (pass-7): cooldown anchor for setMinPot
    uint64 public lastWinnersAdjust; // audit H-4 (pass-8): cooldown anchor for setWinnersPerDay
    mapping(uint32 => bool) public drawn;
    bool public openingDone; // set by runOpeningDraw(); daily runDraw() unlocks only after it

    event WinnersPerDaySet(uint256 k);
    event DrawExecuted(uint32 indexed day, uint256 pot, uint256 winners);
    /// @notice One per winning pack. Lets the website's draw log show the ticket, its tier, and the prize
    ///         per win (DrawExecuted only carries the count). day 0 = the one-time opening sweep.
    event WinnerPaid(uint32 indexed day, uint256 indexed packId, address owner, uint8 tier, uint256 prize, uint256 claimId);
    event MinPotSet(uint256 minPot);
    event PotCapSet(uint256 potCap);

    error AlreadyDrawn();
    error BadDay();
    error OutsideWindow();
    error BadK();
    error GenesisMismatch();
    error CadenceMismatch(); // pre-audit: PackRegistry.dayLength() != this DAY() (mis-paired mainnet/testnet deploy)
    error BadPotCap();
    error BadMinPot(); // audit F5
    error AdjustTooSoon(); // audit M4 (job-745)
    error AdjustOutOfBounds(); // audit M4 (job-745)
    error OpeningPending(); // runDraw() called before the opening draw
    error OpeningAlreadyDone();
    error Accumulating(); // opening called before the 48h window closed

    constructor(
        address drand_,
        address packs_,
        address vault_,
        address claim_,
        uint256 genesis_,
        uint256 k_,
        uint256 minPot_,
        uint256 potCap_,
        address initialOwner
    ) Ownable(initialOwner) {
        // audit F14 (pass-5): potCap is REQUIRED (> 0) at construction — no fail-open type(uint256).max
        // default. audit F5: minPot is REQUIRED (> 0) and now cross-checked <= potCap at construction too
        // (the config-independent guard only floors at ~10*winnersPerDay wei — far too low). Fail-closed
        // on-chain exactly like HolderDrawEngine.
        if (potCap_ == 0) revert BadPotCap();
        if (minPot_ == 0 || minPot_ > potCap_) revert BadMinPot();
        drand = IDrandOracle(drand_);
        packs = PackRegistry(packs_);
        vault = IVault(vault_);
        claimManager = IClaimManager(claim_);
        if (PackRegistry(packs_).genesis() != genesis_) revert GenesisMismatch(); // audit H-8
        // pre-audit (cadence cross-check): drawRound/currentDay here and _today/revealRound in the registry all
        // assume ONE day length. Only genesis was cross-checked before, so a mainnet engine wired to a short-
        // clock registry (or vice versa) deployed fine and silently desynced every reveal-before-cutoff window.
        // DAY() dispatches to the most-derived override, so the testnet pair (5m/5m) passes exactly like 1d/1d.
        if (PackRegistry(packs_).dayLength() != DAY()) revert CadenceMismatch();
        genesis = genesis_;
        if (k_ == 0 || k_ > MAX_K) revert BadK();
        winnersPerDay = k_;
        minPot = minPot_;
        potCap = potCap_;
    }

    function setWinnersPerDay(uint256 k) external onlyOwner {
        if (k == 0 || k > MAX_K) revert BadK();
        // audit H-4 (pass-8): cooldown + the same +/-25% band as setPotCap. drawFrom's selection for K is a
        // strict prefix of K+1, so before this an owner could atomically re-pick K after a beacon revealed to
        // re-target who wins. Now K moves at most ~25%/draw-day (a day-open snapshot would be stronger, but
        // this matches the sibling knobs). audit M-7: band never collapses to a point.
        if (block.timestamp < uint256(lastWinnersAdjust) + DAY()) revert AdjustTooSoon();
        uint256 lo = (winnersPerDay * (BPS - MAX_ADJ_BPS)) / BPS;
        uint256 hi = (winnersPerDay * (BPS + MAX_ADJ_BPS)) / BPS;
        if (hi <= winnersPerDay) hi = winnersPerDay + 1;
        if (k < lo || k > hi) revert AdjustOutOfBounds();
        lastWinnersAdjust = uint64(block.timestamp);
        winnersPerDay = k;
        emit WinnersPerDaySet(k);
    }

    /// @notice Set the minimum pot below which a draw voids without consuming the day (audit C-1).
    ///         Cross-checked against potCap (audit L-3): minPot > potCap would silently void every draw.
    function setMinPot(uint256 m) external onlyOwner {
        if (m == 0 || m > potCap) revert BadMinPot(); // audit F5: never 0, never above potCap
        // audit L-10 (pass-7): cooldown. audit H-3 (pass-8): add setPotCap's +/-25% band so the owner can't
        // reactively jump minPot up to potCap after a beacon reveals to force every draw into the void branch.
        // audit M-7 (pass-8): floor hi at minPot+1 so the band never collapses to a point (minPot <= 3).
        if (block.timestamp < uint256(lastMinPotAdjust) + DAY()) revert AdjustTooSoon();
        uint256 lo = (minPot * (BPS - MAX_ADJ_BPS)) / BPS;
        uint256 hi = (minPot * (BPS + MAX_ADJ_BPS)) / BPS;
        if (hi <= minPot) hi = minPot + 1;
        if (m < lo || m > hi) revert AdjustOutOfBounds();
        lastMinPotAdjust = uint64(block.timestamp);
        minPot = m;
        emit MinPotSet(m);
    }

    /// @notice Bound a single day's payout (audit H-3). Excess over the cap rolls forward.
    /// @dev    audit M4 (job-745): rate-limited to +/-25% per draw-day and one change per day (matching
    ///         HolderDrawEngine), so an owner can no longer front-run a determined draw and slam potCap to
    ///         minPot to shrink a known winner's prize. Larger moves take several days.
    function setPotCap(uint256 c) external onlyOwner {
        if (c == 0 || c < minPot) revert BadPotCap(); // audit L-3: never below the minPot floor (checked first)
        if (block.timestamp < uint256(lastPotAdjust) + DAY()) revert AdjustTooSoon();
        uint256 lo = (potCap * (BPS - MAX_ADJ_BPS)) / BPS;
        uint256 hi = (potCap * (BPS + MAX_ADJ_BPS)) / BPS;
        if (hi <= potCap) hi = potCap + 1; // audit M-7 (pass-8): band never collapses to a point
        if (c < lo || c > hi) revert AdjustOutOfBounds();
        lastPotAdjust = uint64(block.timestamp);
        potCap = c;
        emit PotCapSet(c);
    }

    /// @notice The drand round whose beacon settles day `day` — publishes REVEAL_LAG after day+1 opens,
    ///         so it is unknowable while any in-window ticket is still being bought.
    function drawRound(uint32 day) public view returns (uint64) {
        return drand.roundAt(genesis + (uint256(day) + 1) * DAY() + REVEAL_LAG);
    }

    function currentDay() public view returns (uint32) {
        if (block.timestamp <= genesis) return 0;
        return uint32((block.timestamp - genesis) / DAY());
    }

    /// @notice Tier bucket share in bps. 0=Common,1=Uncommon,2=Rare,3=SuperRare.
    function bucketBps(uint8 tier) public pure returns (uint256) {
        if (tier == 3) return 4500; // Super Rare 45%
        if (tier == 2) return 2500; // Rare 25%
        if (tier == 1) return 2000; // Uncommon 20%
        return 1000; // Common 10%
    }

    /// @notice The one-time OPENING draw. After the 48h accumulation window (ACCUM_DAYS), split the built-up
    ///         pool among OPENING_WINNERS winners drawn from ALL packs bought during the window — the rolling
    ///         draw window for drawDay ACCUM_DAYS already spans cohorts [0, ACCUM_DAYS-1], so no cohort voids.
    ///         Daily draws (runDraw) unlock only after this runs. Same pot/tier logic as a normal draw.
    ///         VOID-ON-MISS (pre-audit L, opening-draw liveness): if the pot is below `minPot` (or too small to
    ///         pay every opening winner at least 1 wei) when this is called at/after the window close, the
    ///         opening is FORGONE, not deferred. It still settles (openingDone = true) so the daily draws
    ///         unlock, but pays nobody and burns no tickets; the whole pot rolls forward into the daily draws,
    ///         which cover the same cohorts and self-void under minPot until the vault is funded. Deferring
    ///         used to leave openingDone=false, and since runDraw is gated on it, EVERY daily draw stayed
    ///         blocked until the vault cleared minPot. Runbook: fund the vault above minPot before the
    ///         accumulation window closes so the opening actually pays.
    /// @dev    NOTE (finding-2 review): cohorts [0, ACCUM_DAYS-1] are NOT consumed whole here — the opening
    ///         pops only OPENING_WINNERS packs, and those cohorts stay eligible for the normal 7-day window
    ///         (including a later runDraw(ACCUM_DAYS)). A forgone opening pops nothing at all, so those cohorts
    ///         keep every ticket for that window. `potCap` bounds EACH draw independently; it is a
    ///         per-draw cap plus rollover, not a per-cohort-lifetime cap. No pack or wei is ever paid twice:
    ///         popped packs are marked spent, and each draw reserves its own snapshotted pot.
    function runOpeningDraw() external nonReentrant {
        if (openingDone) revert OpeningAlreadyDone();
        if (currentDay() < ACCUM_DAYS) revert Accumulating(); // pool still building — no draw during the window

        uint256 pot = vault.freeBalance();
        if (pot > potCap) pot = potCap; // audit H-3: bound the payout; excess rolls forward
        if (pot < minPot || (pot * bucketBps(0)) / BPS < OPENING_WINNERS) {
            // pre-audit L (opening-draw liveness): too small to pay every opening winner >= 1 wei. This used to
            // return WITHOUT settling ("retry when funded"), but runDraw is gated on openingDone, so an under-
            // minPot vault at window close blocked every daily draw until someone funded it and re-called this.
            // Now the opening is FORGONE (void-on-miss): settle it so the daily draws unlock, pay nobody, burn
            // no tickets (no sweep, so cohorts [0, ACCUM_DAYS-1] keep every ticket for the daily rolling window
            // that already spans them), read no beacon (a forgone opening must not depend on drand being on
            // time), and let the pot roll forward: the daily draws self-void under minPot until funded.
            // This branch is reachable only once currentDay() >= ACCUM_DAYS (the Accumulating guard above) AND
            // the pot is unpayable at this instant, so a payable opening can never be skipped through it: any
            // pot >= minPot (and >= OPENING_WINNERS wei in the Common bucket) takes the paid path below, unchanged.
            openingDone = true;
            emit DrawExecuted(0, pot, 0);
            return;
        }
        // beacon settles right after the window closes: round at genesis + ACCUM_DAYS*DAY + REVEAL_LAG
        bytes32 beacon = drand.randomness(drawRound(uint32(ACCUM_DAYS - 1)));
        // PAID-ONLY (finding-2): the opening beacon is already public relative to a day-ACCUM_DAYS free freeze,
        // so the free block must be structurally excluded here regardless of when this permissionless call lands.
        uint256[] memory winners = packs.drawFromPaidOnly(beacon, uint32(ACCUM_DAYS), OPENING_WINNERS); // sweeps [0, ACCUM_DAYS-1]
        // audit (opening-brick fix): mark the opening settled the moment the sweep runs, REGARDLESS of whether
        // the accumulation window held any tickets. The window [0, ACCUM_DAYS-1] can never be back-filled once
        // it has passed, so an empty window that returned early here used to leave openingDone=false forever —
        // permanently bricking every daily draw when nobody bought in the first ACCUM_DAYS. The pot-too-small
        // guard above settles as well now (pre-audit L), so once the window has closed EVERY exit from this
        // function leaves openingDone=true and the daily draws unlocked.
        openingDone = true;
        if (winners.length == 0) {
            emit DrawExecuted(0, pot, 0);
            return; // opening settled with no early tickets — daily draws now sweep later cohorts
        }
        _payWinners(0, pot, winners); // day 0 = the one-time opening sweep
        emit DrawExecuted(0, pot, winners.length);
    }

    function runDraw(uint32 day) external nonReentrant {
        if (!openingDone) revert OpeningPending(); // daily draws start only after the opening sweep
        if (drawn[day]) revert AlreadyDrawn();
        if (day < ACCUM_DAYS) revert BadDay(); // the window's days were settled by the opening draw
        if (currentDay() != day + 1) revert OutsideWindow(); // the day after only — else void

        // Snapshot the pot BEFORE touching tickets. If nothing is payable, do NOT run the draw: drawFrom
        // marks tickets spent, so drawing on a zero pot would burn ticket eligibility for no payout (audit
        // fix). We also don't mark the day drawn — a retry can still pay out if the vault is funded later
        // within this window; missing the whole window voids the day and the pot rolls forward.
        uint256 pot = vault.freeBalance();
        if (pot > potCap) pot = potCap; // audit H-3: bound the single-day payout; excess rolls forward
        // Skip (WITHOUT burning tickets or marking the day drawn) when the pot is too small to pay even a full
        // field of winners in the SMALLEST tier bucket. Guarantees every drawn winner receives >=1 wei (audit H-17).
        if (pot < minPot || (pot * bucketBps(0)) / BPS < winnersPerDay) {
            emit DrawExecuted(day, pot, 0);
            return; // retry when funded (audit C-1: sub-minPot dust never consumes the day or burns tickets)
        }

        bytes32 beacon = drand.randomness(drawRound(day)); // reverts if beacon missing (retry within window)
        uint256[] memory winners = packs.drawFrom(beacon, day, winnersPerDay);
        if (winners.length == 0) {
            // audit F16: an empty ticket window pops nothing — do NOT consume the day, so a later retry can draw.
            emit DrawExecuted(day, pot, 0);
            return;
        }
        drawn[day] = true;
        _payWinners(day, pot, winners);
        emit DrawExecuted(day, pot, winners.length);
    }

    /// @dev Resolve each winner's tier, then write a claim for its equal share of its tier bucket. Single
    ///      combined division (audit L-14) — (pot·bps)/(BPS·count). Unpaid buckets stay in the vault.
    function _payWinners(uint32 day, uint256 pot, uint256[] memory winners) internal {
        uint256 n = winners.length;
        uint8[] memory tiers = new uint8[](n);
        uint256[4] memory counts;
        for (uint256 i; i < n; ++i) {
            uint8 t = packs.tierOf(winners[i]);
            tiers[i] = t;
            unchecked {
                counts[t] += 1;
            }
        }
        uint64 deadline = uint64(block.timestamp + CLAIM_WINDOW);
        for (uint256 i; i < n; ++i) {
            uint8 t = tiers[i];
            uint256 prize = (pot * bucketBps(t)) / (BPS * counts[t]);
            if (prize == 0) continue;
            address owner = packs.ownerOf(winners[i]);
            uint256 claimId = claimManager.registerClaim(address(vault), owner, prize, deadline);
            emit WinnerPaid(day, winners[i], owner, t, prize, claimId); // per-win record for the draw log
        }
    }
}
