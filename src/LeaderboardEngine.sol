// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { NonRenounceableOwnable2Step } from "./utils/NonRenounceableOwnable2Step.sol";
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
contract LeaderboardEngine is NonRenounceableOwnable2Step, ReentrancyGuard {
    LeaderboardRegistry public immutable registry;
    IVault public immutable vault;
    IClaimManager public immutable claimManager;
    uint256 public immutable genesis;
    uint256 public immutable weekAnchor; // Sunday 00:00 UTC anchor, derived from genesis (matches registry)

    // `virtual` so a TESTNET-ONLY subclass can shorten the week; mainnet + tests keep 7 days (Sunday-aligned).
    // MUST equal LeaderboardRegistry.WEEK() — enforced at construction (pre-audit cadence cross-check).
    function WEEK() public view virtual returns (uint256) { return 7 days; }
    uint256 public constant CLAIM_WINDOW = 30 days;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_ADJ_BPS = 2500; // audit M4 (job-745): potCap re-peg bounded to +/-25%/week

    // audit M-7: bound a single week's payout; excess rolls forward. audit F14 (pass-5): REQUIRED (> 0) at
    // construction now (no fail-open type(uint256).max default) — a sole board member in a quiet week is
    // 100% of totalPoints, so uncapped it could take a whole rolled-forward vault balance in one distribute.
    uint256 public potCap;
    uint256 public minPot; // audit C-1: floor below which distribute voids WITHOUT consuming the week
    uint64 public lastPotAdjust; // audit M4 (job-745): timestamp of the last setPotCap (cooldown anchor)
    uint64 public lastMinPotAdjust; // audit L-10 (pass-7): cooldown anchor for setMinPot
    mapping(uint256 => bool) public distributed;

    event Distributed(uint256 indexed week, uint256 pot, uint256 winners);
    event PotCapSet(uint256 potCap);
    event MinPotSet(uint256 minPot);

    error AlreadyDistributed();
    error OutsideWindow();
    error BadPotCap();
    error BadMinPot(); // audit F5
    error GenesisMismatch();
    error CadenceMismatch(); // pre-audit: registry WEEK()/weekAnchor differ from this engine's (mis-paired deploy)
    error AdjustTooSoon(); // audit M4 (job-745)
    error AdjustOutOfBounds(); // audit M4 (job-745)

    constructor(
        address registry_,
        address vault_,
        address claim_,
        uint256 genesis_,
        uint256 minPot_,
        uint256 potCap_,
        address o
    ) Ownable(o) {
        // audit F14 (pass-5): potCap REQUIRED (> 0) at construction; audit F5: minPot REQUIRED (> 0) and
        // cross-checked <= potCap — the config-independent guard only floors at ~5-20 wei, so a 0 default let
        // a dust donation consume a whole week's top-25 payout. Fail-closed on-chain like HolderDrawEngine.
        if (potCap_ == 0) revert BadPotCap();
        if (minPot_ == 0 || minPot_ > potCap_) revert BadMinPot();
        registry = LeaderboardRegistry(registry_);
        vault = IVault(vault_);
        claimManager = IClaimManager(claim_);
        // audit L-2: cross-check the registry's genesis (mirrors RaffleEngine/JackpotEngine's H-8 check) —
        // a divergence would desync the distribute() window from the registry's accrual-week numbering.
        if (LeaderboardRegistry(registry_).genesis() != genesis_) revert GenesisMismatch();
        // pre-audit (cadence cross-check): genesis alone does not pin the week numbering — WEEK() and the anchor
        // derivation are both `virtual`, so a mainnet engine on a short-clock registry (or a subclass that
        // overrides only one half of the pair) would deploy fine and desync accrual weeks from distribute
        // windows. Assert both halves live, exactly as genesis is asserted. WEEK() dispatches to the most-
        // derived override, so the testnet pair (10m/10m, genesis-anchored) passes exactly like 7d/7d.
        if (LeaderboardRegistry(registry_).WEEK() != WEEK()) revert CadenceMismatch();
        genesis = genesis_;
        // Same Sunday derivation as the registry — identical genesis (checked above) => identical weekAnchor,
        // so currentWeek() here and in the registry stay byte-for-byte in sync (audit note: (b) desync risk).
        // Derivation is `virtual` so the TESTNET-ONLY subclass can anchor to genesis with a short week; the
        // registry subclass overrides it identically, preserving that byte-for-byte sync — now a checked fact.
        uint256 wa = _deriveWeekAnchor(genesis_);
        if (LeaderboardRegistry(registry_).weekAnchor() != wa) revert CadenceMismatch();
        weekAnchor = wa;
        minPot = minPot_;
        potCap = potCap_;
    }

    /// @notice Bound a single week's payout (audit M-7). Never below the minPot floor (audit L-3).
    /// @dev    audit M4 (job-745): rate-limited to +/-25% per week (one change per week), so an owner cannot
    ///         front-run a determined weekly distribute to shrink a known winner's payout.
    function setPotCap(uint256 c) external onlyOwner {
        if (c == 0 || c < minPot) revert BadPotCap();
        if (block.timestamp < uint256(lastPotAdjust) + WEEK()) revert AdjustTooSoon();
        uint256 lo = (potCap * (BPS - MAX_ADJ_BPS)) / BPS;
        uint256 hi = (potCap * (BPS + MAX_ADJ_BPS)) / BPS;
        if (hi <= potCap) hi = potCap + 1; // audit M-7 (pass-8): band never collapses to a point
        if (c < lo || c > hi) revert AdjustOutOfBounds();
        lastPotAdjust = uint64(block.timestamp);
        potCap = c;
        emit PotCapSet(c);
    }

    /// @notice Set the minimum pot below which distribute voids without consuming the week (audit C-1).
    ///         Cross-checked against potCap (audit L-3): minPot > potCap would silently void every week.
    function setMinPot(uint256 m) external onlyOwner {
        if (m == 0 || m > potCap) revert BadMinPot(); // audit F5: never 0, never above potCap
        // audit L-10 (pass-7): cooldown. audit H-3 (pass-8): +/-25% band (as setPotCap). audit M-7: band never
        // collapses to a point. Stops a reactive minPot->potCap jump after the week's (public) outcome is known.
        if (block.timestamp < uint256(lastMinPotAdjust) + WEEK()) revert AdjustTooSoon();
        uint256 lo = (minPot * (BPS - MAX_ADJ_BPS)) / BPS;
        uint256 hi = (minPot * (BPS + MAX_ADJ_BPS)) / BPS;
        if (hi <= minPot) hi = minPot + 1;
        if (m < lo || m > hi) revert AdjustOutOfBounds();
        lastMinPotAdjust = uint64(block.timestamp);
        minPot = m;
        emit MinPotSet(m);
    }

    /// @notice Most-recent Sunday 00:00 UTC at/before genesis (payouts land on Sundays). `virtual` so the
    ///         TESTNET-ONLY subclass can anchor to genesis with a short week; MUST mirror the registry's.
    function _deriveWeekAnchor(uint256 genesis_) internal view virtual returns (uint256) {
        return genesis_ >= 3 days ? genesis_ - ((genesis_ - 3 days) % 7 days) : 0;
    }

    function currentWeek() public view returns (uint256) {
        if (block.timestamp < weekAnchor) return 0;
        return (block.timestamp - weekAnchor) / WEEK(); // Sunday-aligned, matches registry._week()
    }

    function distribute(uint256 week) external nonReentrant {
        if (distributed[week]) revert AlreadyDistributed();
        if (currentWeek() != week + 1) revert OutsideWindow(); // the following week only — else void (audit H-2)

        // Snapshot the pot and guards BEFORE marking distributed, so an empty/zero-weight week is NOT
        // consumed (matches RaffleEngine/HolderDrawEngine — a funded retry can still pay within the window).
        uint256 cnt = registry.boardCount(week);
        uint256 pot = vault.freeBalance();
        if (pot > potCap) pot = potCap; // audit M-7: bound the single-week payout; excess rolls forward
        // audit H-5: divide by ALL buyers' points this week, NOT the 25-member board sum — otherwise splitting
        // a stake across 25 wallets that evict every incumbent shrinks the denominator to the attacker's own
        // wallets and captures 100% of the pot. Non-board buyers' weight simply stays in the vault and rolls
        // forward. So the top-25 collectively receive (their points / all points) of the pot.
        uint256 totalW = registry.totalPoints(week);
        if (cnt == 0 || pot == 0 || pot < minPot || totalW == 0) {
            emit Distributed(week, pot, 0);
            return; // do NOT mark distributed (audit C-1: a sub-minPot dust pot never consumes the week)
        }

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
        if (paid == 0) {
            emit Distributed(week, pot, 0);
            return; // audit C-1: do NOT consume the week if every share floored to zero
        }
        distributed[week] = true; // audit C-1: flag only AFTER >=1 nonzero claim is registered
        emit Distributed(week, pot, paid);
    }
}
