// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { NonRenounceableOwnable2Step } from "./utils/NonRenounceableOwnable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IDrandOracle } from "./interfaces/IDrandOracle.sol";
import { IVault } from "./interfaces/IVault.sol";
import { IClaimManager } from "./interfaces/IClaimManager.sol";
import { INFTCollection } from "./interfaces/INFTCollection.sol";

/// @title  HolderDrawEngine, the weekly NFT-holder jackpot: 5 distinct winners, even split
/// @notice A weekly draw over the pass collection. Each week the engine picks 5 distinct winning tokenId
///         SLOTS out of the minted id space and pays each slot's owner pot/5 in QUOTRON from a dedicated
///         vault. Only tokens whose owner held >= MIN_HOLD passes continuously since the week's freeze instant
///         are eligible (frozen via the NFT's qualifiedSince stamp, not a live balanceOf). Selection is
///         per-token (sybil-neutral, G1), so a wallet's expected slots scale with the eligible passes it
///         holds. This is the funded holder jackpot: the vault is topped up on an ongoing basis
///         by the 6.25% holder share of the trade tax (Treasury's HOLDER_BPS), routed in on every
///         convert(), plus any optional mint-time seed. Each weekly pot is still min(freeBalance, potCap)
///         under POT_CAP_CEILING, and every unpaid share simply rolls forward inside the vault (void-on-miss).
///
/// @dev    DESIGN: BOUNDED REJECTION SAMPLING. COST IS O(1) IN SUPPLY.
///         There is no snapshot any more, and nothing in this file reads, stores or assumes a supply number.
///         The previous design froze `ownerOf` for every tokenId into storage once a week. Measured against
///         the real OpenZeppelin ERC721, sold out at the then-current MAX_SUPPLY, that cost 59,961,132 gas.
///         That is 187% of Robinhood Chain's real per-transaction ceiling of 32,000,000 gas (read from
///         consensus state: ArbGasInfo.getMaxTxGasLimit at 0x000000000000000000000000000000000000006C,
///         selector 0xaae1cd4c; NOT the 2^50 geth-compat header field, and NOT geth's 50M rpc.gascap). It was
///         unmineable at sell-out, and it bricked far earlier than that: roughly 300 new tokenIds minted
///         between two snapshots of the same parity buffer was enough. That loop, its double buffer and its
///         SUPPLY constant are deleted.
///
///         What replaces it rests on two facts about the collection:
///           1. NFTCollection stamps `ownerSince[tokenId]` on every REAL change of hands (mint included, a
///              self transfer excluded), so continuous holding since an instant is a single SLOAD to prove.
///           2. Ids are minted SEQUENTIALLY from 1, so the minted set is exactly 1..nft.totalMinted(), and
///              `launched()` is one way and closes every mint path, so that bound is frozen before any
///              beacon for a drawable week exists.
///         The draw therefore walks a beacon-derived candidate sequence over 1..n, silently discards a
///         duplicate or ineligible candidate and re-rolls, up to a hard compile-time budget of MAX_REROLLS
///         candidates SHARED across all five slots, with an early exit once five are seated. Worst-case cost
///         is a compile-time constant: independent of MAX_SUPPLY, of turnover, and of anything an adversary
///         can do. Moving MAX_SUPPLY does not touch this contract, and no number here has to be kept in
///         step with it.
///
///         The four guardrails from the design red team all still hold:
///         G1 (proportional 5 slots, SYBIL-NEUTRAL): the draw picks 5 distinct tokenId SLOTS uniformly over
///           the eligible set, so a wallet's expected slots are LINEAR in the eligible passes it holds. Dedup
///           is per-TOKEN, NOT per-wallet: a per-wallet cap would let a holder split a holding across cheap
///           wallets to win MORE slots (each 4-pass wallet a separate winner), which is strictly +EV and
///           inverts H-4. Per-token keeps splitting neutral (8 passes are 8 eligible ids whether in one wallet
///           or two), and a wallet holding several winning tokenIds simply wins several shares. The MIN_HOLD
///           gate only filters WHICH ids are eligible; it does not change this linearity.
///         G2 (unpredictable): the seed is a TIME-LOCKED drand BLS round that publishes REVEAL_LAG after
///           the freeze instant snapDeadline(W), so it cannot be known while eligibility is still movable.
///           MUST be a BlsDrandOracle: DERP's on-demand model breaks this.
///         G3 (no front-run): eligibility is BOTH `ownerSince[tokenId] <= snapDeadline(W)` (the token was
///           held across the freeze) AND `qualifiedSince[owner] <= snapDeadline(W)` (the owner held >= MIN_HOLD
///           across the freeze), and the beacon publishes REVEAL_LAG after that instant. So neither buying a
///           winning pass NOR topping up to MIN_HOLD after the reveal buys anything: both gates are frozen.
///           THE CRUX RULING, stated plainly because it is a real behaviour change: the SELLER of a pass
///           moved after the freeze instant is not paid either. Both sides of a post-freeze trade are zero
///           and the slot re-rolls to a third party. Softening that would need stored ownership history,
///           which is the 60M gas loop being deleted.
///         G4 (bounded, negative EV to farm): the pot is min(freeBalance, potCap) under an immutable
///           POT_CAP_CEILING, so per-pass EV stays bounded with no rolled-over honeypot. The knockout-buy
///           arithmetic wants potCap <= 5 * pass floor price; see LAUNCH-CHECKLIST.md.
///         Reuses the protocol's void-on-miss rollover, pull-claims (ClaimManager) and no-owner-drain vault.
contract HolderDrawEngine is NonRenounceableOwnable2Step, ReentrancyGuard {
    IDrandOracle public immutable drand; // MUST be the time-locked BlsDrandOracle
    INFTCollection public immutable nft;
    IVault public immutable vault; // dedicated HolderDraw vault (its own QUOTRON inventory)
    IClaimManager public immutable claimManager;
    uint256 public immutable genesis;
    uint256 public immutable POT_CAP_CEILING; // hard, immutable upper bound on any weekly pot

    // `virtual` so a TESTNET-ONLY subclass can shorten these; mainnet + the full test suite keep the real
    // values (so the reveal-lag > sequencer-bound proof and the 7-day cadence stay exercised).
    function WEEK() public view virtual returns (uint256) { return 7 days; }
    // The settling beacon reveals REVEAL_LAG AFTER the freeze instant (snapDeadline), so no transfer that
    // still counts for the week can ever have seen it. SIZED TO ROBINHOOD CHAIN'S SEQUENCER CLOCK (audit
    // M-7): RH's SequencerInbox reports maxTimeVariation.delaySeconds = 345_600 (4 days, confirmed
    // on-chain), the maximum by which the sequencer may back-date block.timestamp. REVEAL_LAG must exceed
    // it to be code-enforced rather than a trusted-sequencer assumption: 4.5 days > 4 days. The 7-day draw
    // window absorbs this and still leaves roughly 2.5 days to call runDraw after the beacon reveals.
    // Closes M-7 for the weekly holder draw.
    // ANY SUBCLASS THAT SHORTENS WEEK() MUST ALSO SHORTEN THIS, or drawRound binds to a beacon further out
    // than the draw window is wide and the week can never be drawn. See src/testnet/TestnetShortClock.sol.
    function REVEAL_LAG() internal view virtual returns (uint256) { return 4 days + 12 hours; }

    uint256 internal constant WINNERS = 5;
    /// @dev Hard ceiling on beacon re-rolls in ONE draw, shared across all five slots. NOT a tuning knob:
    ///      it is the only thing making runDraw's cost independent of supply, of turnover, and of anything
    ///      an adversary can do. Sized so the exhaustion branch stays unreachable while >= 10% of passes
    ///      are eligible (P ~ 2.5e-7 per week at E/n = 0.10; ~3e-49 at 0.50).
    uint256 internal constant MAX_REROLLS = 256;
    /// @notice The holder draw is holder-only: a winning tokenId's owner must have held at least this many
    ///         passes CONTINUOUSLY SINCE the week's freeze instant, proven by the NFT's qualifiedSince stamp
    ///         (not a live balanceOf, which a holder could top up after the beacon reveals). It is a per-token
    ///         eligibility FILTER, not a per-wallet cap, so selection stays sybil-neutral (G1): 8 passes are 8
    ///         eligible ids whether held in one wallet or split across two. MUST equal NFTCollection.MIN_HOLD
    ///         (cross-checked in the constructor), since the NFT stamps qualifiedSince off its own copy.
    uint256 public constant MIN_HOLD = 4;

    uint256 public constant CLAIM_WINDOW = 30 days;
    uint256 internal constant MAX_ADJ_BPS = 2500; // potCap re-peg: at most +/-25% per change
    uint256 internal constant BPS = 10_000;

    uint256 public potCap; // owner re-pegs within bounds; clamped by POT_CAP_CEILING
    uint64 public lastPotAdjust;
    uint64 public lastMinPotAdjust; // audit L-10 (pass-7): cooldown anchor for setMinPot
    // MINIMUM pot below which a draw voids WITHOUT consuming the week. Closes the dust-donation grief where
    // anyone raises freeBalance() by a few wei to force a near-zero payout that burns the week (audit C-1).
    // REQUIRED (> 0) at construction (audit H-2): the only config-independent guard here is pot/WINNERS==0
    // (voids below 5 wei), so a 0 default left a live 5-wei dust-grief. Owner re-tunes via setMinPot.
    uint256 public minPot;

    mapping(uint256 => bool) public drawn; // week => drawn
    // EXCLUSION, read as ONE SCHEDULED TOGGLE (audit H-5, extended to un-exclusion). `excluded[a]` is the
    // value in force FROM `exclEffectiveWeek[a]` onward and `!excluded[a]` is the value before it, so a
    // write can only ever change the answer for weeks strictly after the week it lands in. See _excludedAt
    // and setExcluded: moving the exclusion read past the beacon reveal (it used to be frozen into the
    // snapshot) would otherwise expose an INSTANT, RETROACTIVE un-exclusion lever, letting the owner see a
    // barred confederate holding a drawn tokenId and lift the bar in the same transaction as runDraw.
    mapping(address => bool) public excluded; // optional: protocol/escrow addresses barred from winning
    mapping(address => uint64) public exclEffectiveWeek; // the week from which `excluded[a]` is in force

    event Drawn(uint256 indexed week, uint256 pot, uint256 winners);
    event SlotWon(uint256 indexed week, uint256 slot, uint256 tokenId, address winner);
    event Voided(uint256 indexed week, uint256 pot);
    event PotCapSet(uint256 oldCap, uint256 newCap);
    event MinPotSet(uint256 minPot);
    event ExcludedSet(address indexed account, bool excluded);

    error BadPotCap();
    error PotCapZero();
    error AbovePotCeiling();
    error AdjustTooSoon();
    error AdjustOutOfBounds();
    error AlreadyDrawn();
    error OutsideWindow();
    error BadMinPot();
    error NoExclusionChange();
    error ExclusionChangePending();
    error NotExcluded();
    error MinHoldMismatch(); // the NFT stamps qualifiedSince off its own MIN_HOLD; the two must agree

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
        // The frozen holder-count gate reads nft.qualifiedSince, which the NFT stamps off ITS MIN_HOLD. If the
        // two thresholds disagree, the engine's MIN_HOLD (and isEligible's contract) would be a lie. Pin them.
        if (INFTCollection(nft_).MIN_HOLD() != MIN_HOLD) revert MinHoldMismatch();
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
        return (block.timestamp - genesis) / WEEK();
    }

    /// @notice THE FREEZE INSTANT for `week`: the end of week W, which is also the start of week W+1.
    ///         A pass counts for week W's draw only if it last changed hands at or before this instant, so
    ///         eligibility for W stops moving here even though the draw itself runs during W+1. The settling
    ///         beacon is bound REVEAL_LAG PAST this instant, so it provably cannot publish while eligibility
    ///         is still movable. Kept under its old name so every deploy script, keeper and test that reads
    ///         it keeps working; it no longer closes a snapshot window, because there is no snapshot.
    function snapDeadline(uint256 week) public view returns (uint256) {
        return genesis + (week + 1) * WEEK();
    }

    /// @notice The drand round settling `week`. It reveals REVEAL_LAG after the freeze instant, i.e. strictly
    ///         after eligibility for `week` has stopped moving (the G2/G3 anti-front-run invariant).
    function drawRound(uint256 week) public view returns (uint64) {
        return drand.roundAt(snapDeadline(week) + REVEAL_LAG());
    }

    /// @notice Is `tokenId` in `week`'s draw? This is the public eligibility check that audit F3 asked for:
    ///         a prospective buyer must be able to see whether a pass is already frozen out of a week BEFORE
    ///         purchasing. It answers for ANY week, including future ones, which the old snapshot getter
    ///         could not, and it applies the exact same four tests the draw itself applies.
    function isEligible(uint256 week, uint256 tokenId) public view returns (bool) {
        if (!nft.launched()) return false;
        if (tokenId == 0 || tokenId > nft.totalMinted()) return false;
        uint64 os = nft.ownerSince(tokenId);
        if (os == 0 || uint256(os) > snapDeadline(week)) return false;
        address o;
        try nft.ownerOf(tokenId) returns (address o_) { o = o_; } catch { return false; }
        if (o == address(0) || _excludedAt(o, week)) return false;
        // holder-only draw, FROZEN at the freeze instant: the owner must have held >= MIN_HOLD continuously
        // since at or before snapDeadline(week). Reads the NFT's qualifiedSince stamp, NOT a live balanceOf,
        // so a holder cannot top up to MIN_HOLD after the settling beacon is public to sneak into the week.
        uint64 qs = nft.qualifiedSince(o);
        return qs != 0 && uint256(qs) <= snapDeadline(week);
    }

    /// @notice Simulate `week`'s draw exactly. It calls the SAME selector runDraw calls, so the two can
    ///         never disagree. Reverts with the oracle until drawRound(week) reveals.
    function previewDraw(uint256 week)
        external
        view
        returns (uint256[WINNERS] memory won, address[WINNERS] memory winner, uint256 filled)
    {
        if (!nft.launched()) return (won, winner, filled);
        uint256 n = nft.totalMinted();
        if (n < WINNERS) return (won, winner, filled);
        return _selectWinners(week, drand.randomness(drawRound(week)), n);
    }

    // ─── selection (shared by runDraw and previewDraw) ───────────────────────

    /// @dev The complete candidate sequence and eligibility filter for `week`. A pure function of
    ///      (beacon, week, n) and chain state. Writes nothing.
    ///
    ///      REJECTION CAUSES, ALL HANDLED BY `continue`, NEVER BY REVERT AND NEVER BY VOIDING THE WEEK.
    ///      Any one of them reverting would let a single bad tokenId brick the draw permanently.
    ///        a. DUPLICATE: this id is already seated in this draw, so the "5 distinct winning tokenIds" promise
    ///           (G1) holds even at a tiny minted count. Deliberately per-TOKEN, not per-wallet: a per-wallet
    ///           cap would reward splitting a holding across cheap wallets (sybil), inverting H-4. See G1.
    ///        b. TOO LATE: never minted, or the token changed hands after the freeze instant.
    ///        c. INELIGIBLE OWNER: ownerOf reverts, or returns address(0), or the owner is excluded.
    ///        d. NOT QUALIFIED: the owner's qualifiedSince is 0 or later than the freeze instant, i.e. it did
    ///           NOT hold >= MIN_HOLD continuously since the freeze (holder-only draw, FROZEN not live).
    ///      Checked cheapest-reject-first: memory scan, then one SLOAD, then the ownerOf/qualifiedSince staticcalls.
    ///
    ///      TERMINATION: `j` is bounded by a compile-time constant and `continue` still runs the for-update
    ///      expression, so this executes at most MAX_REROLLS iterations in EVERY state. If anyone ever
    ///      rewrites it as a `while`, the increment must sit where no `continue` can skip it.
    ///      `nft` is immutable, so both staticcalls hit a fixed address with fixed selectors and 32-byte
    ///      returndata: no gas bomb, no returndata bomb, and no proxy anyone can swap underneath it.
    function _selectWinners(uint256 week, bytes32 beacon, uint256 n)
        internal
        view
        returns (uint256[WINNERS] memory won, address[WINNERS] memory winner, uint256 filled)
    {
        uint256 freeze = snapDeadline(week);
        for (uint256 j; j < MAX_REROLLS; ++j) {
            // PINNED: abi.encode (NOT encodePacked) of (bytes32 beacon, uint256 week, uint256 j). All three
            // are fixed-width, so there is no ambiguity to exploit, and the sequence is reproducible
            // off-chain by anyone.
            uint256 tid = (uint256(keccak256(abi.encode(beacon, week, j))) % n) + 1;

            bool dup; // (a) 5 DISTINCT TOKENS. Memory only, so it is the cheapest reject.
            for (uint256 k; k < filled; ++k) {
                if (won[k] == tid) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;

            uint64 os = nft.ownerSince(tid); // (b) one staticcall, one cold SLOAD
            if (os == 0 || uint256(os) > freeze) continue;

            address o; // (c) ownerOf may revert on a burned or non-existent id
            try nft.ownerOf(tid) returns (address o_) {
                o = o_;
            } catch {
                continue;
            }
            // try/catch does NOT cover a ZERO RETURN, and an ERC721 that answers address(0) instead of
            // reverting is legal. Without this line that zero reaches ClaimManager.registerClaim, which
            // reverts ZeroRecipient, and the week is bricked permanently. MANDATORY, not decoration.
            if (o == address(0)) continue;
            if (_excludedAt(o, week)) continue; // `week`, NEVER currentPeriod()
            // (d) HOLDER-ONLY, FROZEN: the owner must have held >= MIN_HOLD continuously since the freeze
            //     instant. qualifiedSince is stamped by the NFT off ITS MIN_HOLD (cross-checked at
            //     construction); a live balanceOf here would let a holder top up to MIN_HOLD AFTER the beacon
            //     is public to sneak in, the exact front-run this whole freeze-before-beacon design forbids.
            uint64 qs = nft.qualifiedSince(o);
            if (qs == 0 || uint256(qs) > freeze) continue;

            won[filled] = tid;
            winner[filled] = o;
            unchecked {
                ++filled;
            }
            if (filled == WINNERS) break;
        }
    }

    // ─── draw (following week only; void-on-miss) ────────────────────────────

    /// @notice Draw `week`, permissionless, callable only during week+1. Ineligible or duplicate candidates
    ///         are re-rolled, never reverted on. Each seated slot is paid a flat pot/WINNERS; the share of
    ///         any slot the re-roll budget failed to seat is simply never reserved, so it stays in
    ///         vault.freeBalance() and rolls into next week's pot.
    function runDraw(uint256 week) external nonReentrant {
        if (drawn[week]) revert AlreadyDrawn();
        if (currentPeriod() != week + 1) revert OutsideWindow(); // the following week only, else void

        // The domain 1..n MUST be frozen before the beacon exists. `launched` is one-way and closes every
        // mint path, so totalMinted is constant from that instant forever. Without this gate a post-reveal
        // mint would move n and `% n` would reshuffle the WHOLE candidate sequence.
        if (!nft.launched()) {
            emit Voided(week, 0);
            return; // do NOT mark drawn
        }
        uint256 n = nft.totalMinted();
        if (n < WINNERS) {
            emit Voided(week, 0);
            return; // do NOT mark drawn; this also guards the `% n` below against n == 0
        }

        // Read the pot BEFORE anything else; a zero pot does not consume the draw (retry if funded in-window).
        uint256 pot = vault.freeBalance();
        if (pot > potCap) pot = potCap;
        if (pot < minPot || pot / WINNERS == 0) {
            emit Drawn(week, pot, 0);
            return; // do NOT mark drawn (audit C-1: sub-minPot or per-winner-zero dust never burns the week)
        }

        bytes32 beacon = drand.randomness(drawRound(week)); // reverts until the time-locked round reveals

        (uint256[WINNERS] memory won, address[WINNERS] memory winner, uint256 filled) =
            _selectWinners(week, beacon, n);

        if (filled == 0) {
            emit Voided(week, pot);
            return; // do NOT mark drawn (audit L-9: consistent with every other miss branch)
        }

        drawn[week] = true;

        // FLAT SHARE. The dust (pot % WINNERS) and any unseated slot's share stay unreserved and roll
        // forward via freeBalance. NEVER pot/filled: the re-roll makes filled == WINNERS with probability
        // ~1, so pot/filled would buy ~2e-7 * pot per week of expected value while creating the one branch
        // where an attacker's effort has a super-linear payoff (filled == 1 handing one tokenId the entire
        // weekly pot, which is a genuinely new maximum, and cheapest to engineer at a thin launch).
        uint256 share = pot / WINNERS;
        uint64 deadline = uint64(block.timestamp + CLAIM_WINDOW);
        for (uint256 i; i < filled; ++i) {
            claimManager.registerClaim(address(vault), winner[i], share, deadline);
            emit SlotWon(week, i, won[i], winner[i]);
        }
        emit Drawn(week, pot, filled);
    }

    // ─── admin (owner = timelock/multisig) ───────────────────────────────────

    /// @notice Re-peg the per-week pot cap, bounded like the ticket price: at most +/-25% per change, at
    ///         most once a week, and never above the immutable POT_CAP_CEILING, so the knob can neither farm
    ///         nor brick.
    function setPotCap(uint256 newCap) external onlyOwner {
        if (newCap == 0) revert PotCapZero();
        if (newCap < minPot) revert BadMinPot(); // audit L-3: cap can never sit below the minPot floor
        if (newCap > POT_CAP_CEILING) revert AbovePotCeiling();
        if (block.timestamp < uint256(lastPotAdjust) + WEEK()) revert AdjustTooSoon();
        uint256 cur = potCap;
        uint256 lo = (cur * (BPS - MAX_ADJ_BPS)) / BPS;
        uint256 hi = (cur * (BPS + MAX_ADJ_BPS)) / BPS;
        if (hi <= cur) hi = cur + 1; // audit M-7 (pass-8): band never collapses to a point
        if (newCap < lo || newCap > hi) revert AdjustOutOfBounds();
        lastPotAdjust = uint64(block.timestamp);
        potCap = newCap;
        emit PotCapSet(cur, newCap);
    }

    /// @notice Set the minimum pot below which a draw voids without consuming the week (audit C-1).
    ///         Must stay > 0 and <= potCap (audit H-2/L-3).
    function setMinPot(uint256 m) external onlyOwner {
        if (m == 0 || m > potCap) revert BadMinPot();
        // audit L-10 (pass-7): cooldown. audit H-3 (pass-8): +/-25% band (as setPotCap). audit M-7: band
        // never collapses to a point. Stops a reactive minPot->potCap jump to force the void branch.
        if (block.timestamp < uint256(lastMinPotAdjust) + WEEK()) revert AdjustTooSoon();
        uint256 lo = (minPot * (BPS - MAX_ADJ_BPS)) / BPS;
        uint256 hi = (minPot * (BPS + MAX_ADJ_BPS)) / BPS;
        if (hi <= minPot) hi = minPot + 1;
        if (m < lo || m > hi) revert AdjustOutOfBounds();
        lastMinPotAdjust = uint64(block.timestamp);
        minPot = m;
        emit MinPotSet(m);
    }

    /// @notice Was `a` excluded AS OF `week`. Immune to owner writes in BOTH directions: every write lands at
    ///         currentPeriod()+1, and setExcluded's cooldown guarantees no write can alter the answer for any
    ///         week <= currentPeriod(). Replaces _excludedNow (audit H-5, extended to un-exclusion).
    function _excludedAt(address a, uint256 week) internal view returns (bool) {
        uint64 e = exclEffectiveWeek[a];
        if (e == 0) return false; // never configured
        return week >= uint256(e) ? excluded[a] : !excluded[a];
    }

    /// @notice Bar an address (protocol/escrow) from winning, or lift the bar. Either way the change takes
    ///         effect the FOLLOWING week (audit H-5), and because a week is drawn during the week after it,
    ///         the effective public notice is two weeks.
    /// @dev    WHY BOTH DIRECTIONS NOW NEED NOTICE. Under the old snapshot design exclusion was frozen into
    ///         the snapshot, days before the beacon. Reading it at draw time instead would expose an instant,
    ///         retroactive UN-exclusion lever: the owner could watch a barred confederate's tokenId come up
    ///         and call setExcluded(a, false) in the same transaction as runDraw. The pair of mappings is
    ///         therefore read as ONE SCHEDULED TOGGLE by _excludedAt, and this function enforces that a
    ///         pending change has been in force a full week before another can be scheduled.
    ///
    ///         PROOF that a write at week P can only change the answer for weeks >= P+1. The write sets
    ///         e_new = P+1, and a draw only ever queries W = currentPeriod()-1, so W <= P.
    ///           - After the write, the answer for any w <= P is `!v_new`, since w < e_new.
    ///           - NoExclusionChange forces v_new != v_old. The cooldown forces P > e_old, hence P-1 >= e_old,
    ///             so the pre-write answer for every w in [e_old, P] was v_old == !v_new. IDENTICAL.
    ///           - First-ever write: the pre-write answer is false (e == 0), v_new must be true, and the
    ///             post-write answer `!v_new` is false. IDENTICAL.
    ///         Two writes that silently succeeded before now revert: a no-op repeat of the same value, and a
    ///         toggle inside the cooldown. The practical cost is one exclusion change per address per two
    ///         weeks, so burn and dead addresses must be barred EARLY rather than reactively.
    function setExcluded(address account, bool v) external onlyOwner {
        uint64 e = exclEffectiveWeek[account];
        if (e == 0) {
            // A first write of `false` is meaningless, and it would make the `!excluded[a]` branch of
            // _excludedAt answer TRUE for every past week. Reject it.
            if (!v) revert NotExcluded();
        } else {
            if (excluded[account] == v) revert NoExclusionChange(); // must be a real toggle
            // the prior change must have been in force a FULL week before another is scheduled
            if (currentPeriod() <= uint256(e)) revert ExclusionChangePending();
        }
        excluded[account] = v;
        exclEffectiveWeek[account] = uint64(currentPeriod() + 1);
        emit ExcludedSet(account, v);
    }
}
