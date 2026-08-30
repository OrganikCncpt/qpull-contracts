// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IDrandOracle } from "./interfaces/IDrandOracle.sol";
import { IVault } from "./interfaces/IVault.sol";
import { IClaimManager } from "./interfaces/IClaimManager.sol";
import { INFTCollection } from "./interfaces/INFTCollection.sol";

/// @title  HolderDrawEngine — weekly NFT-holder jackpot, 5 distinct winners, even split
/// @notice A weekly draw over the 250-piece NFT collection: each week it FREEZES who owns each tokenId
///         (on-chain, BEFORE the beacon exists), then draws 5 winning tokenId slots and pays each slot's owner pot/5
///         in QUOTRON from a dedicated vault. Funded once from the NFT-mint prize-seed (finite, bounded).
///
/// @dev    The four guardrails (from the design red-team) all hold, and are the reason to build it this way:
///         G1 (proportional 5 slots): the draw picks 5 distinct tokenId SLOTS, so a wallet's expected slots
///           are LINEAR in the tokens it holds — splitting a holding across wallets confers no advantage
///           (sybil-neutral; audit H-4). A wallet holding several winning tokenIds wins several shares.
///         G2 (unpredictable): the seed is a TIME-LOCKED drand-BLS round that publishes REVEAL_LAG AFTER
///           snapDeadline(W); it cannot be known while the snapshot is open. MUST be a BlsDrandOracle —
///           DERP's on-demand model breaks this.
///         G3 (no front-run): every snapshot write happens strictly before snapDeadline(W), and the beacon
///           publishes strictly after it (REVEAL_LAG margin), AND claims pay the SNAPSHOT owner, never live
///           ownerOf — buying a winning NFT after the reveal buys nothing.
///         G4 (-EV / bounded): the pot is min(freeBalance, potCap) under an immutable POT_CAP_CEILING, so
///           per-NFT EV <= pot/250 with no super-linear splitting gain and no rolled-over honeypot.
///         Reuses the protocol's void-on-miss rollover, pull-claims (ClaimManager), and no-owner-drain vault.
contract HolderDrawEngine is Ownable2Step, ReentrancyGuard {
    IDrandOracle public immutable drand; // MUST be the time-locked BlsDrandOracle
    INFTCollection public immutable nft;
    IVault public immutable vault; // dedicated HolderDraw vault (its own QUOTRON inventory)
    IClaimManager public immutable claimManager;
    uint256 public immutable genesis;
    uint256 public immutable POT_CAP_CEILING; // hard, immutable upper bound on any weekly pot

    uint256 internal constant WEEK = 7 days;
    uint256 internal constant SNAP_WINDOW = 2 days; // snapshot only in the last 2 days of the week
    // Settling beacon reveals REVEAL_LAG AFTER the snapshot hard-closes (snapDeadline), so no snapshot
    // write can ever see it. SIZED TO ROBINHOOD CHAIN'S SEQUENCER CLOCK (audit M-7): RH's SequencerInbox
    // reports maxTimeVariation.delaySeconds = 345_600 (4 days, confirmed on-chain) — the max the sequencer
    // may back-date block.timestamp. REVEAL_LAG must exceed it to be code-enforced rather than a
    // trusted-sequencer assumption: 4.5 days > 4 days. The 7-day draw window absorbs this (leaves a
    // ~2.5-day window to draw after the beacon reveals); the snapshot closes even further before the
    // beacon (extra G3 margin). Closes M-7 for the weekly holder draw.
    uint256 internal constant REVEAL_LAG = 4 days + 12 hours;
    uint256 internal constant WINNERS = 5;
    uint256 internal constant SUPPLY = 250;
    uint256 public constant CLAIM_WINDOW = 30 days;
    uint256 internal constant MAX_ADJ_BPS = 2500; // potCap re-peg: <= +/-25% per change
    uint256 internal constant BPS = 10_000;

    uint256 public potCap; // owner re-pegs within bounds; clamped by POT_CAP_CEILING
    uint64 public lastPotAdjust;
    // MINIMUM pot below which a draw voids WITHOUT consuming the week — closes the dust-donation grief where
    // anyone raises freeBalance() by a few wei to force a near-zero payout that burns the week (audit C-1).
    // REQUIRED (> 0) at construction (audit H-2): the only config-independent guard here is pot/WINNERS==0
    // (voids below 5 wei), so a 0 default left a live 5-wei dust-grief. Owner re-tunes via setMinPot (<= potCap).
    uint256 public minPot;

    // Double-buffered by week parity so week W+1's snapshot can't clobber week W's frozen buffer.
    mapping(uint256 => mapping(uint256 => address)) internal snapOwner; // [W&1][tokenId] => frozen owner
    uint256[2] internal snapEpochOf; // [buf] => W+1 sentinel (0 = unset, disambiguates week 0)
    uint16[2] internal snapCursorOf; // [buf] => tokenIds captured so far (SUPPLY == complete)

    mapping(uint256 => bool) public drawn; // week => drawn
    mapping(address => bool) public excluded; // optional: protocol/escrow addresses barred from winning

    event Snapshotted(uint256 indexed week, uint256 cursor);
    event Drawn(uint256 indexed week, uint256 pot, uint256 winners);
    event Voided(uint256 indexed week, uint256 pot);
    event PotCapSet(uint256 oldCap, uint256 newCap);
    event MinPotSet(uint256 minPot);
    event ExcludedSet(address indexed account, bool excluded);

    error BadPotCap();
    error PotCapZero();
    error AbovePotCeiling();
    error AdjustTooSoon();
    error AdjustOutOfBounds();
    error SnapshotClosed();
    error AlreadyDrawn();
    error OutsideWindow();
    error BadMinPot();

    constructor(
        address drand_,
        address nft_,
        address vault_,
        address claim_,
        uint256 genesis_,
        uint256 potCap_,
        uint256 potCapCeiling_,
        uint256 minPot_,
        address initialOwner
    ) Ownable(initialOwner) {
        if (potCap_ == 0 || potCapCeiling_ == 0 || potCap_ > potCapCeiling_) {
            revert BadPotCap();
        }
        if (minPot_ == 0 || minPot_ > potCap_) revert BadMinPot(); // audit H-2/L-3: no unsafe 0 default
        drand = IDrandOracle(drand_);
        nft = INFTCollection(nft_);
        vault = IVault(vault_);
        claimManager = IClaimManager(claim_);
        genesis = genesis_;
        potCap = potCap_;
        POT_CAP_CEILING = potCapCeiling_;
        minPot = minPot_;
    }

    // ─── views (mirror the sibling engines) ──────────────────────────────────

    function currentPeriod() public view returns (uint256) {
        if (block.timestamp <= genesis) return 0;
        return (block.timestamp - genesis) / WEEK;
    }

    /// @notice End of week W = start of week W+1, and the instant the snapshot for W hard-closes (the
    ///         currentPeriod gate flips here). The settling beacon is bound to REVEAL_LAG PAST this, so it
    ///         provably cannot publish until after every snapshot write for W is done.
    function snapDeadline(uint256 week) public view returns (uint256) {
        return genesis + (week + 1) * WEEK;
    }

    /// @notice The drand round settling `week` — reveals REVEAL_LAG after snapDeadline(week), i.e. strictly
    ///         after the snapshot window has closed (the G2/G3 anti-front-run invariant).
    function drawRound(uint256 week) public view returns (uint64) {
        return drand.roundAt(snapDeadline(week) + REVEAL_LAG);
    }

    function snapComplete(uint256 week) public view returns (bool) {
        uint256 buf = week & 1;
        return snapEpochOf[buf] == week + 1 && snapCursorOf[buf] == SUPPLY;
    }

    // ─── snapshot (open in the last SNAP_WINDOW of the week, before the beacon) ─

    /// @notice Freeze ownerOf over tokenIds 1..SUPPLY for the CURRENT week, chunked by `maxCount`. Unminted
    ///         ids are captured as address(0) via try/catch so a partial sellout can never brick the game.
    ///         Set-once per week: once the buffer is complete it is frozen until the week rolls over.
    /// @notice Freeze ownerOf over ALL tokenIds 1..SUPPLY for the current week in ONE transaction.
    /// @dev    ATOMIC by design (audit F3). A chunked snapshot with a persisted cursor let whoever advanced
    ///         the cursor choose each token's freeze instant independently — so an attacker could buy a
    ///         tokenId, `snapshot` past it to freeze itself as that token's owner, then sell, serially,
    ///         capturing draw slots with transient (buy→snapshot→sell) capital instead of sustained holding
    ///         (a ~250x capital reduction) and letting a seller freeze a buyer out of the draw. Freezing
    ///         every token at a single block instead means eligibility requires actually holding the NFTs at
    ///         that one instant. ~250 ownerOf reads + writes fit comfortably in one L2 block.
    function snapshot() external {
        uint256 week = currentPeriod();
        // Only in the last SNAP_WINDOW of the week. The currentPeriod gate closes writes at snapDeadline(week),
        // and the settling beacon does not publish until snapDeadline(week)+REVEAL_LAG — so no snapshot write
        // can ever observe it (the anti-front-run invariant).
        if (block.timestamp < snapDeadline(week) - SNAP_WINDOW) revert SnapshotClosed();

        uint256 buf = week & 1;
        if (snapEpochOf[buf] == week + 1 && snapCursorOf[buf] == SUPPLY) revert SnapshotClosed(); // set-once
        snapEpochOf[buf] = week + 1;

        for (uint256 tid = 1; tid <= SUPPLY; ++tid) {
            try nft.ownerOf(tid) returns (address o) {
                // Freeze exclusion at snapshot time (audit H-7): an excluded owner is captured as address(0).
                snapOwner[buf][tid] = excluded[o] ? address(0) : o;
            } catch {
                snapOwner[buf][tid] = address(0);
            }
        }
        snapCursorOf[buf] = uint16(SUPPLY);
        emit Snapshotted(week, SUPPLY);
    }

    /// @notice The frozen snapshot owner of `tokenId` for `week` (0 = not eligible / not yet snapshotted).
    ///         A public getter (audit F3) so a prospective NFT buyer can check whether a token is already
    ///         frozen out of the current week's draw before purchasing.
    function snapshotOwnerOf(uint256 week, uint256 tokenId) external view returns (address) {
        return snapOwner[week & 1][tokenId];
    }

    // ─── draw (following week only; void-on-miss) ────────────────────────────

    function runDraw(uint256 week) external nonReentrant {
        if (drawn[week]) revert AlreadyDrawn();
        if (currentPeriod() != week + 1) revert OutsideWindow(); // the following week only — else void

        uint256 buf = week & 1;
        // No complete snapshot for this exact week → un-drawable; pot rolls forward via freeBalance.
        if (!(snapEpochOf[buf] == week + 1 && snapCursorOf[buf] == SUPPLY)) {
            emit Voided(week, 0);
            return; // do NOT mark drawn
        }

        // Snapshot pot BEFORE anything else; a zero pot doesn't consume the draw (retry if funded in-window).
        uint256 pot = vault.freeBalance();
        if (pot > potCap) pot = potCap;
        if (pot < minPot || pot / WINNERS == 0) {
            emit Drawn(week, pot, 0);
            return; // do NOT mark drawn (audit C-1: sub-minPot or per-winner-zero dust never consumes the week)
        }

        bytes32 beacon = drand.randomness(drawRound(week)); // reverts until the time-locked round reveals

        // Build the eligible pool: tokenIds with a real, non-excluded snapshot owner.
        uint256[] memory pool = new uint256[](SUPPLY);
        uint256 len;
        for (uint256 tid = 1; tid <= SUPPLY; ++tid) {
            address o = snapOwner[buf][tid];
            if (o != address(0)) {
                // exclusion was already frozen into the snapshot (excluded owners were captured as 0) — audit H-7
                pool[len++] = tid;
            }
        }

        // Select WINNERS distinct tokenId SLOTS by swap-pop (audit H-4). Payout is linear in tokens held, so
        // splitting a holding across wallets confers NO advantage (sybil-neutral) — unlike the old distinct-
        // wallet rule, which paradoxically rewarded splitting. A wallet owning several winning tokenIds simply
        // wins several pot/WINNERS shares, which is fair: it holds more of the collection.
        if (len < WINNERS) {
            // Fewer than 5 eligible tokenIds this week — pay nobody; the pot rolls forward.
            emit Voided(week, pot);
            return; // do NOT mark drawn (audit L-9: consistent with the zero-pot / incomplete-snapshot branches)
        }
        uint256[WINNERS] memory wonTids;
        for (uint256 i; i < WINNERS; ++i) {
            uint256 r = uint256(keccak256(abi.encode(beacon, week, i))) % len;
            wonTids[i] = pool[r];
            pool[r] = pool[len - 1];
            unchecked {
                --len;
            }
        }

        drawn[week] = true;

        uint256 share = pot / WINNERS; // dust (pot % WINNERS) stays unreserved and rolls forward
        uint64 deadline = uint64(block.timestamp + CLAIM_WINDOW);
        for (uint256 i; i < WINNERS; ++i) {
            claimManager.registerClaim(address(vault), snapOwner[buf][wonTids[i]], share, deadline);
        }
        emit Drawn(week, pot, WINNERS);
    }

    // ─── admin (owner = timelock/multisig) ───────────────────────────────────

    /// @notice Re-peg the per-week pot cap, bounded like the ticket price: <= +/-25% per change, <= once a
    ///         week, and never above the immutable POT_CAP_CEILING — so the knob can neither farm nor brick.
    function setPotCap(uint256 newCap) external onlyOwner {
        if (newCap == 0) revert PotCapZero();
        if (newCap < minPot) revert BadMinPot(); // audit L-3: cap can never sit below the minPot floor
        if (newCap > POT_CAP_CEILING) revert AbovePotCeiling();
        if (block.timestamp < uint256(lastPotAdjust) + WEEK) revert AdjustTooSoon();
        uint256 cur = potCap;
        uint256 lo = (cur * (BPS - MAX_ADJ_BPS)) / BPS;
        uint256 hi = (cur * (BPS + MAX_ADJ_BPS)) / BPS;
        if (newCap < lo || newCap > hi) revert AdjustOutOfBounds();
        lastPotAdjust = uint64(block.timestamp);
        potCap = newCap;
        emit PotCapSet(cur, newCap);
    }

    /// @notice Set the minimum pot below which a draw voids without consuming the week (audit C-1).
    ///         Must stay > 0 and <= potCap (audit H-2/L-3).
    function setMinPot(uint256 m) external onlyOwner {
        if (m == 0 || m > potCap) revert BadMinPot();
        minPot = m;
        emit MinPotSet(m);
    }

    /// @notice Bar an address (protocol/escrow) from winning. Forbidden while the CURRENT week's snapshot is
    ///         partway done (audit M-4): exclusion is frozen per-token as each chunk runs, so a mid-snapshot
    ///         change would freeze an internally-inconsistent owner set (some of the account's tokens captured
    ///         as owner, others as address(0)). Change it before the snapshot starts or after it completes.
    /// @notice Bar an address (protocol/escrow) from winning. Exclusion is read atomically inside the
    ///         single-tx snapshot (audit F3), so it can no longer be applied inconsistently mid-scan — the
    ///         old mid-snapshot guard (and its griefing vector) are gone with the chunked snapshot.
    function setExcluded(address account, bool v) external onlyOwner {
        excluded[account] = v;
        emit ExcludedSet(account, v);
    }
}
