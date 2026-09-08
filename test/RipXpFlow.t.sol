// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { LeaderboardRegistry } from "../src/LeaderboardRegistry.sol";
import { BaseVault } from "../src/BaseVault.sol";
import { ClaimManager } from "../src/ClaimManager.sol";
import { RaffleEngine } from "../src/RaffleEngine.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockNFT } from "./mocks/MockNFT.sol";

/// @notice rip-XP (feature a) end-to-end + the re-audit fix regressions H-1 / M-1 / M-2.
///         PackRegistry.claimRipXp banks rarity-weighted XP for FINAL non-winning ripped packs into
///         LeaderboardRegistry (PackRegistry is that registry's write-once xpRecorder). Mirrors the
///         RaffleFlow harness (short-day DAY=5m, MockDrandOracle beacons, _bootstrap-style warps).
contract RipXpFlowTest is Test {
    PackRegistry packs;
    LeaderboardRegistry board;
    BaseVault vault;
    ClaimManager claimMgr;
    RaffleEngine raffle;
    MockDrandOracle oracle;
    MockERC20 quotron;
    MockNFT nft;

    address token = makeAddr("token"); // the recorder (stands in for QpullTaxHook)
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant GENESIS = 1_000_000;
    uint256 constant PERIOD = 30;
    uint256 constant TICKET = 10e18;
    uint256 constant DAY = 1 days; // base cadence (RaffleEngine/PackRegistry.DAY() default); tests are scale-invariant (warp N*DAY)
    uint256 constant POT = 1000e18;
    uint256 constant K = 3;

    // rip-XP weight units (mirror PackRegistry constants for expected-value assertions)
    uint256 constant UNIT = 1e15; // RIP_XP_UNIT

    function setUp() public {
        vm.warp(GENESIS);
        oracle = new MockDrandOracle(GENESIS, PERIOD);
        quotron = new MockERC20();
        nft = new MockNFT();

        packs = new PackRegistry(address(oracle), TICKET, GENESIS, 1 hours, address(this));
        board = new LeaderboardRegistry(GENESIS, address(this));
        vault = new BaseVault(address(quotron), address(this));
        claimMgr = new ClaimManager(address(this));
        raffle = new RaffleEngine(
            address(oracle), address(packs), address(vault), address(claimMgr), GENESIS, K, 1, POT, address(this)
        );

        // wiring
        packs.setRecorder(token);
        packs.setEngine(address(raffle));
        packs.setNft(address(nft));
        packs.setLeaderboard(address(board)); // rip-XP sink (write-once)
        board.setXpRecorder(address(packs)); // PackRegistry is the ONLY recordXp caller (write-once)
        board.setRecorder(token); // buys path (unused by most tests but mirrors production wiring)
        claimMgr.setEngine(address(raffle), address(vault));
        vault.setController(address(claimMgr));
    }

    // ─── helpers ──────────────────────────────────────────────────────────────

    function _buy(address who, uint256 grossQpull) internal {
        vm.prank(token);
        packs.recordBuy(who, grossQpull);
    }

    function _revealCohort0() internal {
        (, uint64 rr,,) = packs.packs(1); // all day-0 packs share one reveal round
        oracle.setBeacon(rr, keccak256("reveal-c0"));
    }

    function _ids1(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }

    // mirrors PackRegistry.ripXpWeight (Common 1x / Uncommon 2x / Rare 4x / SR 10x)
    function _weight(uint8 tier) internal pure returns (uint256) {
        if (tier == 3) return UNIT * 10;
        if (tier == 2) return UNIT * 4;
        if (tier == 1) return UNIT * 2;
        return UNIT;
    }

    // ─── (a) rip-XP happy path ─────────────────────────────────────────────────

    /// A taxed-buy pack that is revealed, never drawn, and past cohortDay+LIFE_DAYS+1 banks
    /// rarity-weighted XP into the leaderboard week, returns that total, emits RipXpClaimed, sets granted.
    function test_ripXp_happyPath_banksWeightedXp() public {
        _buy(alice, 100e18); // 10 taxed packs, cohort 0 (ids 1..10)
        _revealCohort0();

        vm.warp(GENESIS + 9 * DAY + 1); // today()=9: inside cohort-0 rip window (settled 8, window (8,15])
        uint256 wk = board.currentWeek();

        uint256[] memory ids = new uint256[](10);
        uint256 expected;
        for (uint256 i; i < 10; ++i) {
            ids[i] = i + 1;
            expected += _weight(packs.tierOf(i + 1));
        }
        assertGt(expected, 0, "some XP is earnable");

        uint256 before = board.points(wk, alice);
        vm.expectEmit(true, false, false, true, address(packs));
        emit PackRegistry.RipXpClaimed(alice, 10, expected);
        vm.prank(alice);
        uint256 got = packs.claimRipXp(ids);

        assertEq(got, expected, "returns the weighted total");
        assertEq(board.points(wk, alice), before + expected, "banked into leaderboard week points");
        assertEq(board.totalPoints(wk), before + expected, "all-buyer denominator credited too");
        for (uint256 i; i < 10; ++i) {
            assertTrue(packs.ripXpGranted(i + 1), "granted flag set");
        }
    }

    /// Once-only: a second claim on already-granted packs banks 0.
    function test_ripXp_onceOnly_secondClaimGrantsZero() public {
        _buy(alice, 100e18);
        _revealCohort0();
        vm.warp(GENESIS + 9 * DAY + 1);

        uint256[] memory ids = new uint256[](10);
        for (uint256 i; i < 10; ++i) {
            ids[i] = i + 1;
        }
        vm.prank(alice);
        uint256 first = packs.claimRipXp(ids);
        assertGt(first, 0, "first claim pays");

        uint256 wk = board.currentWeek();
        uint256 mid = board.points(wk, alice);
        vm.prank(alice);
        uint256 second = packs.claimRipXp(ids);
        assertEq(second, 0, "second claim grants nothing");
        assertEq(board.points(wk, alice), mid, "board unchanged on the re-claim");
    }

    /// Mixed batch never reverts: only the eligible pack is credited; owned/unowned, revealed/unrevealed,
    /// in-window/out-of-window, and spent/not-spent are all tolerated in one call.
    function test_ripXp_mixedBatch_creditsOnlyEligible() public {
        // day 0: alice buys 10 in cohort 0 (ids 1..10)
        _buy(alice, 100e18);
        _revealCohort0();

        // day 1: draw cohort 0 (only alice's packs are live) to create SPENT alice packs
        oracle.setBeacon(raffle.drawRound(1), keccak256("d1")); // not needed by drawFrom-directly, kept for parity
        vm.warp(GENESIS + 1 * DAY + 1); // today()=1
        vm.prank(address(raffle)); // engine-only entrypoint; raffle is the bound engine
        uint256[] memory won = packs.drawFrom(keccak256("spend"), 1, 3); // 3 alice packs now spent
        assertEq(won.length, 3, "3 packs spent");

        // day 1: bob buys (cohort 1) -> UNOWNED-by-alice packs (ids 11..12)
        _buy(bob, 20e18);
        uint256 bobId = 11;
        // day 1: alice buys (cohort 1) -> UNREVEALED + not-yet-in-window packs (ids 13..14)
        _buy(alice, 20e18);
        uint256 aliceUnrevealed = 13;

        // a surviving (not spent) alice cohort-0 pack is the ONLY eligible one at day 9
        uint256 eligible;
        for (uint256 id = 1; id <= 10; ++id) {
            (,,, bool spent) = packs.packs(id);
            if (!spent) {
                eligible = id;
                break;
            }
        }
        assertTrue(eligible != 0, "found a surviving cohort-0 pack");

        vm.warp(GENESIS + 9 * DAY + 1); // today()=9: cohort 0 in window; cohort 1 (settled 9) NOT yet, unrevealed

        uint256[] memory batch = new uint256[](4);
        batch[0] = eligible; // owned + revealed + in-window + not-spent -> credited
        batch[1] = won[0]; // owned + SPENT -> skipped
        batch[2] = bobId; // UNOWNED (bob) -> skipped
        batch[3] = aliceUnrevealed; // owned but UNREVEALED + out-of-window -> skipped

        uint256 wk = board.currentWeek();
        uint256 before = board.points(wk, alice);
        uint256 expected = _weight(packs.tierOf(eligible));

        vm.prank(alice);
        uint256 got = packs.claimRipXp(batch); // must NOT revert

        assertEq(got, expected, "only the eligible pack credited");
        assertEq(board.points(wk, alice), before + expected, "board credited by exactly one pack");
        assertTrue(packs.ripXpGranted(eligible), "eligible pack granted");
        assertFalse(packs.ripXpGranted(bobId), "unowned pack untouched");
        assertFalse(packs.ripXpGranted(aliceUnrevealed), "unrevealed pack untouched");
    }

    // ─── access control (recordXp / write-once bindings) ───────────────────────

    function test_recordXp_revertsForNonXpRecorder() public {
        vm.expectRevert(LeaderboardRegistry.NotXpRecorder.selector);
        board.recordXp(alice, 1); // caller = this (not the xpRecorder)
    }

    function test_setXpRecorder_writeOnce_andRejectsZero() public {
        // already set to `packs` in setUp -> a re-set reverts
        vm.expectRevert(LeaderboardRegistry.AlreadySet.selector);
        board.setXpRecorder(makeAddr("attacker"));

        // fresh registry: zero-addr set is refused (same combined guard)
        LeaderboardRegistry fresh = new LeaderboardRegistry(GENESIS, address(this));
        vm.expectRevert(LeaderboardRegistry.AlreadySet.selector);
        fresh.setXpRecorder(address(0));
    }

    function test_setLeaderboard_writeOnce_andRejectsZero() public {
        // already set to `board` in setUp -> a re-set reverts
        vm.expectRevert(PackRegistry.AlreadySet.selector);
        packs.setLeaderboard(makeAddr("attacker"));

        // fresh registry: zero-addr set is refused (same combined guard)
        PackRegistry fresh = new PackRegistry(address(oracle), TICKET, GENESIS, 1 hours, address(this));
        vm.expectRevert(PackRegistry.AlreadySet.selector);
        fresh.setLeaderboard(address(0));
    }

    // ─── re-audit H-1: a pack can never be BOTH rip-XP'd AND a draw winner ──────

    function test_H1_rippedPackCannotAlsoBeDrawn() public {
        // The one-time opening draw is permissionless and nobody calls it, so it stays PENDING (openingDone
        // never set) while the cohort-0 packs settle and get ripped, popping them from the live draw pool.
        // When the vault is finally funded and the opening draw runs, the ripped packs are gone — never spent,
        // never paid — proving the fix that _removeLiveById leaves nothing for a draw to pay.
        // (pre-audit L, opening-draw liveness: this scenario used to reach the pending state through an
        // UNFUNDED runOpeningDraw call, which returned without settling. That call now settles the opening as
        // FORGONE, see RaffleFlow.t.sol, so an uncalled opening is the only way it stays pending past the
        // window. The H-1 invariant proven below is unchanged.)
        _buy(alice, 100e18); // 10 packs, cohort 0
        _revealCohort0();

        vm.warp(GENESIS + 2 * DAY + 1); // currentDay()=2 >= ACCUM_DAYS: the opening is callable but uncalled
        assertFalse(raffle.openingDone(), "opening still pending: nobody has called it");

        // warp into the rip window and rip every cohort-0 pack
        vm.warp(GENESIS + 9 * DAY + 1); // today()=9, cohort-0 window (8,15]
        uint256[] memory ids = new uint256[](10);
        for (uint256 i; i < 10; ++i) {
            ids[i] = i + 1;
        }
        vm.prank(alice);
        uint256 got = packs.claimRipXp(ids);
        assertGt(got, 0, "packs were ripped for XP");
        assertEq(packs.cohortSize(0), 0, "all ripped packs popped from the live pool");

        // NOW fund the vault and finally run the opening draw
        quotron.mint(address(vault), POT);
        oracle.setBeacon(raffle.drawRound(1), keccak256("opening")); // drawRound(ACCUM_DAYS-1)
        raffle.runOpeningDraw();

        // the ripped packs are NOT winners, NOT spent, and nothing was paid
        assertEq(claimMgr.nextClaimId(), 0, "no claim registered -> no winner paid");
        // opening-brick fix: an empty opening sweep now SETTLES (openingDone=true) so daily draws unlock and
        // sweep later cohorts — but it still pays nobody here (the ripped packs are gone). The H-1 invariant
        // (a ripped pack is never also drawn/paid) is proven by the no-claim / not-spent / zero-reserve checks.
        assertTrue(raffle.openingDone(), "empty opening sweep settles instead of bricking (opening-brick fix)");
        for (uint256 i; i < 10; ++i) {
            (,,, bool spent) = packs.packs(i + 1);
            assertFalse(spent, "a ripped pack is never marked spent by a later draw");
            assertTrue(packs.ripXpGranted(i + 1), "the pack was rip-XP'd, not drawn");
        }
        assertEq(vault.unclaimedReserve(), 0, "nothing reserved for the ripped packs");
    }

    // NOTE (re-audit M-1): the old free (untaxed) NFT-perk packs were removed with claimFreeEntries. Under the
    // VIRTUAL entry model a free win is never a Pack (nothing enters cohortLive), so "free entries never earn
    // rip-XP" is now STRUCTURAL rather than a ripXpIneligible flag — there is no pack to rip. Test deleted.

    // ─── re-audit M-2: rip-XP is claimable only inside the one-week settle window ─

    function test_M2_ripWindowBoundaries() public {
        _buy(alice, 30e18); // 3 packs (ids 1..3), cohort 0
        _revealCohort0();

        // BEFORE settle: today()=8 == cohortDay+LIFE_DAYS+1 -> NOT yet claimable
        vm.warp(GENESIS + 8 * DAY + 1);
        assertFalse(packs.isRipXpClaimable(1), "not claimable at/ before settle");
        vm.prank(alice);
        assertEq(packs.claimRipXp(_ids1(1)), 0, "grants 0 before the window opens");
        assertFalse(packs.ripXpGranted(1), "a skipped pack is not consumed");

        // INSIDE window: today()=9 -> nonzero
        vm.warp(GENESIS + 9 * DAY + 1);
        uint256 wk = board.currentWeek(); // the leaderboard week the day-9 claim banks into
        assertTrue(packs.isRipXpClaimable(2), "claimable inside the window");
        vm.prank(alice);
        uint256 got = packs.claimRipXp(_ids1(2));
        assertGt(got, 0, "nonzero inside the window");
        assertEq(board.points(wk, alice), got, "banked exactly the in-window XP");

        // last in-window day: today()=15 == settled+RIP_XP_WINDOW -> still claimable
        vm.warp(GENESIS + 15 * DAY + 1);
        assertTrue(packs.isRipXpClaimable(3), "day 15 (settled+7) is the last in-window day");

        // AFTER window: today()=16 -> 0
        vm.warp(GENESIS + 16 * DAY + 1);
        assertFalse(packs.isRipXpClaimable(3), "not claimable after the window closes");
        vm.prank(alice);
        assertEq(packs.claimRipXp(_ids1(3)), 0, "grants 0 after the window closes");
        assertEq(board.points(wk, alice), got, "no extra credit outside the window");
    }
}
