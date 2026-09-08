// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { LeaderboardRegistry } from "../src/LeaderboardRegistry.sol";
import { LeaderboardEngine } from "../src/LeaderboardEngine.sol";
import { BaseVault } from "../src/BaseVault.sol";
import { ClaimManager } from "../src/ClaimManager.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract LeaderboardFlowTest is Test {
    LeaderboardRegistry reg;
    LeaderboardEngine eng;
    BaseVault vault;
    ClaimManager claimMgr;
    MockERC20 quotron;

    address token = makeAddr("token");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant GENESIS = 1_000_000;
    uint256 constant WEEK = 7 days;

    function setUp() public {
        vm.warp(GENESIS);
        quotron = new MockERC20();
        reg = new LeaderboardRegistry(GENESIS, address(this));
        vault = new BaseVault(address(quotron), address(this));
        claimMgr = new ClaimManager(address(this));
        eng =
        new LeaderboardEngine(
            address(reg), address(vault), address(claimMgr), GENESIS, 1, type(uint256).max, address(this)
        );

        reg.setRecorder(token);
        claimMgr.setEngine(address(eng), address(vault));
        vault.setController(address(claimMgr));
    }

    function _buy(address who, uint256 amt) internal {
        vm.prank(token);
        reg.recordBuy(who, amt);
    }

    function test_pointsAccumulate() public {
        _buy(alice, 100);
        _buy(alice, 50);
        assertEq(reg.points(0, alice), 150);
        assertTrue(reg.isOnBoard(0, alice));
    }

    function test_boardKeepsTop25_evictsMin() public {
        // 26 buyers with points 1..26
        for (uint256 i = 1; i <= 26; ++i) {
            _buy(vm.addr(i), i);
        }
        assertEq(reg.boardCount(0), 25, "board capped at 25");
        assertFalse(reg.isOnBoard(0, vm.addr(1)), "lowest (1) evicted");
        assertTrue(reg.isOnBoard(0, vm.addr(26)), "highest (26) present");
        assertTrue(reg.isOnBoard(0, vm.addr(2)), "second-lowest survives");
    }

    function test_linearWeightedDistribution() public {
        _buy(alice, 100); // linear weight 100
        _buy(bob, 400); // linear weight 400 -> weights 100:400 = 1:4 (audit H-20: pro-rata, not √)
        quotron.mint(address(vault), 900);

        vm.warp(GENESIS + WEEK + 1); // week 1
        eng.distribute(0);

        // slot 0 = alice (inserted first), slot 1 = bob
        (, address r1, uint256 a1,,) = claimMgr.claims(1);
        (, address r2, uint256 a2,,) = claimMgr.claims(2);
        assertEq(r1, alice);
        assertEq(a1, 180, "alice 1/5 of 900");
        assertEq(r2, bob);
        assertEq(a2, 720, "bob 4/5 of 900");
        assertEq(a1 + a2, 900, "fully allocated");

        vm.prank(bob);
        claimMgr.claim(2);
        assertEq(quotron.balanceOf(bob), 720);
    }

    // audit H-20: splitting one wallet's points across many wallets is now NEUTRAL (no √ bonus).
    function test_H20_splittingIsNeutral() public {
        // One actor with 400 points in a single wallet vs. the same 400 split across 4 wallets.
        _buy(alice, 400);
        _buy(bob, 400); // an honest peer of equal size
        quotron.mint(address(vault), 800);
        vm.warp(GENESIS + WEEK + 1);
        eng.distribute(0);
        (,, uint256 aliceShare,,) = claimMgr.claims(1);
        assertEq(aliceShare, 400, "single wallet: 400/800 = half");

        // Fresh week: alice splits her 400 across 4 wallets of 100 each (current week = 2 after the warp).
        vm.warp(GENESIS + 2 * WEEK + 1); // week 2 board
        for (uint256 i; i < 4; ++i) {
            _buy(vm.addr(9000 + i), 100);
        }
        _buy(bob, 400);
        quotron.mint(address(vault), 800);
        vm.warp(GENESIS + 3 * WEEK + 1);
        eng.distribute(2);
        // alice's four 100-wallets each get 100/800; summed = 400/800 = half — identical to the single wallet.
        uint256 split;
        uint256 n = claimMgr.nextClaimId();
        for (uint256 id = 2; id <= n; ++id) {
            (, address r, uint256 amt,,) = claimMgr.claims(id);
            for (uint256 i; i < 4; ++i) {
                if (r == vm.addr(9000 + i)) split += amt;
            }
        }
        assertEq(split, 400, "split across 4 wallets earns the same 400/800 - no bonus (H-20)");
    }

    // audit H-2: distribution is window-only (the following week). A late call is rejected and the pot
    // rolls forward — a stale, thinly-populated week can NO LONGER grab the whole running vault balance.
    function test_H2_lateDistributionRejected_noVaultGrab() public {
        _buy(alice, 1e18); // week 0: one tiny buyer
        vm.warp(GENESIS + 2 * WEEK + 1); // now week 2 — week 0's window (week 1) has passed
        quotron.mint(address(vault), 30_000e18); // vault holds multiple weeks' accrual
        vm.expectRevert(LeaderboardEngine.OutsideWindow.selector);
        eng.distribute(0); // old behavior grabbed all 30k for alice; now rejected
        assertEq(vault.freeBalance(), 30_000e18, "vault untouched - nothing grabbed");
    }

    // audit H-2: a zero-pot / empty in-window week does NOT consume the week (retry allowed once funded).
    function test_H2_zeroPotDoesNotConsumeWeek() public {
        _buy(alice, 100);
        vm.warp(GENESIS + WEEK + 1); // week 1 — in window, but vault empty
        eng.distribute(0);
        assertFalse(eng.distributed(0), "not consumed on an empty pot");
        quotron.mint(address(vault), 100);
        eng.distribute(0); // retry within the window now pays
        assertTrue(eng.distributed(0));
        (, address r,,,) = claimMgr.claims(1);
        assertEq(r, alice);
    }

    // audit H-5: payout divides by ALL buyers' points, not the 25-member board sum. So a splitter filling the
    // board can capture at most (board points / all points) of the pot — off-board weight rolls forward.
    function test_H5_offBoardWeightRollsForward_noFullCapture() public {
        for (uint256 i = 1; i <= 30; ++i) {
            _buy(vm.addr(i), 1000); // 30 buyers, board caps at 25
        }
        assertEq(reg.boardCount(0), 25, "board full at 25");
        assertEq(reg.totalPoints(0), 30_000, "all-buyer total tracked");
        quotron.mint(address(vault), 30_000);
        vm.warp(GENESIS + WEEK + 1);
        eng.distribute(0);
        // board = 25 wallets x 1000 -> share each = 30000 * 1000 / 30000 = 1000 -> 25,000 reserved.
        assertEq(vault.unclaimedReserve(), 25_000, "board paid 25/30 of the pot (not 100%)");
        assertEq(vault.freeBalance(), 5_000, "off-board buyers' 5/30 rolls forward, un-captured");
    }

    function test_cannotDistributeOpenWeek() public {
        _buy(alice, 100);
        vm.expectRevert(LeaderboardEngine.OutsideWindow.selector);
        eng.distribute(0); // still week 0
    }

    function test_cannotDistributeTwice() public {
        _buy(alice, 100);
        quotron.mint(address(vault), 100);
        vm.warp(GENESIS + WEEK + 1);
        eng.distribute(0);
        vm.expectRevert(LeaderboardEngine.AlreadyDistributed.selector);
        eng.distribute(0);
    }

    function test_onlyTokenCanRecord() public {
        vm.expectRevert(LeaderboardRegistry.NotRecorder.selector);
        reg.recordBuy(alice, 1);
    }

    // audit F5: minPot REQUIRED (> 0) at construction; setter rejects 0.
    function test_F5_constructorRejectsZeroMinPot() public {
        vm.expectRevert(LeaderboardEngine.BadMinPot.selector);
        new LeaderboardEngine(
            address(reg), address(vault), address(claimMgr), GENESIS, 0, type(uint256).max, address(this)
        );
    }

    // audit F14 (pass-5): potCap is REQUIRED (> 0) at construction now.
    function test_F14_constructorRejectsZeroPotCap() public {
        vm.expectRevert(LeaderboardEngine.BadPotCap.selector);
        new LeaderboardEngine(address(reg), address(vault), address(claimMgr), GENESIS, 1, 0, address(this));
    }

    function test_F5_setMinPotRejectsZero() public {
        vm.expectRevert(LeaderboardEngine.BadMinPot.selector);
        eng.setMinPot(0);
    }

    // audit F14: recorder is write-once — a re-set is rejected (forged-entry lever closed).
    function test_F14_setRecorderWriteOnce() public {
        vm.expectRevert(LeaderboardRegistry.AlreadySet.selector);
        reg.setRecorder(makeAddr("attacker"));
    }

    // ─── (b) Sunday-anchored weekly leaderboard ────────────────────────────────

    // A known NON-Sunday genesis. Unix epoch is a Thursday, so Sunday 00:00 UTC satisfies
    // (ts % 7 days == 3 days). 1_700_000_000 is a Tuesday, ~2.9 days after the prior Sunday.
    uint256 constant G_NON_SUNDAY = 1_700_000_000;

    function test_b_weekAnchorIsMostRecentSundayAtOrBeforeGenesis() public {
        LeaderboardRegistry r = new LeaderboardRegistry(G_NON_SUNDAY, address(this));
        uint256 wa = r.weekAnchor();

        assertLe(wa, G_NON_SUNDAY, "anchor <= genesis");
        assertEq(wa % 7 days, 3 days, "anchor is a Sunday 00:00 UTC (epoch+3d)");
        assertLt(G_NON_SUNDAY - wa, 7 days, "the MOST recent such Sunday (within one week)");
        assertGt(G_NON_SUNDAY - wa, 0, "genesis is genuinely not a Sunday");
    }

    function test_b_registryAndEngineWeeksAgree_acrossRollover() public {
        LeaderboardRegistry r = new LeaderboardRegistry(G_NON_SUNDAY, address(this));
        LeaderboardEngine e = new LeaderboardEngine(
            address(r), address(vault), address(claimMgr), G_NON_SUNDAY, 1, type(uint256).max, address(this)
        );
        assertEq(e.weekAnchor(), r.weekAnchor(), "engine and registry share the Sunday anchor");

        uint256 wa = r.weekAnchor();
        // week boundaries land exactly on Sunday 00:00 UTC
        assertEq((wa + WEEK) % 7 days, 3 days, "week-1 boundary is a Sunday");
        assertEq((wa + 5 * WEEK) % 7 days, 3 days, "week-5 boundary is a Sunday");

        uint256[7] memory tps = [
            wa, // week 0 opens
            wa + 1, // still week 0
            wa + WEEK - 1, // last second of week 0
            wa + WEEK, // exact rollover -> week 1
            wa + WEEK + 1, // week 1
            G_NON_SUNDAY, // week 0 (genesis sits inside week 0)
            wa + 3 * WEEK // week 3
        ];
        uint256[7] memory expected = [uint256(0), 0, 0, 1, 1, 0, 3];
        for (uint256 i; i < tps.length; ++i) {
            vm.warp(tps[i]);
            assertEq(r.currentWeek(), e.currentWeek(), "registry.currentWeek == engine.currentWeek");
            assertEq(r.currentWeek(), expected[i], "Sunday-aligned week index");
        }
    }

    function test_b_sundayAnchor_distributeWindowOpensAndCloses() public {
        // an isolated, fully-wired leaderboard at the Sunday-anchored genesis
        MockERC20 q2 = new MockERC20();
        LeaderboardRegistry r = new LeaderboardRegistry(G_NON_SUNDAY, address(this));
        BaseVault v2 = new BaseVault(address(q2), address(this));
        ClaimManager cm2 = new ClaimManager(address(this));
        LeaderboardEngine e = new LeaderboardEngine(
            address(r), address(v2), address(cm2), G_NON_SUNDAY, 1, type(uint256).max, address(this)
        );
        r.setRecorder(token);
        cm2.setEngine(address(e), address(v2));
        v2.setController(address(cm2));
        uint256 wa = r.weekAnchor();

        // accrue in week 0, fund the pot
        vm.warp(G_NON_SUNDAY);
        assertEq(r.currentWeek(), 0, "genesis sits in week 0");
        vm.prank(token);
        r.recordBuy(alice, 100);
        q2.mint(address(v2), 100);

        // too early: still week 0 (the following-week window has not opened)
        vm.expectRevert(LeaderboardEngine.OutsideWindow.selector);
        e.distribute(0);

        // window opens exactly at the week-1 Sunday boundary -> distribute(0) succeeds
        vm.warp(wa + WEEK + 1);
        assertEq(r.currentWeek(), 1);
        assertEq(e.currentWeek(), 1);
        e.distribute(0);
        assertTrue(e.distributed(0), "distributed in the following-week window");
        (, address recip,,,) = cm2.claims(1);
        assertEq(recip, alice, "the sole board member is paid");

        // window closes: accrue in week 1, skip week 1's window (week 2), land in week 3 -> rejected
        vm.prank(token);
        r.recordBuy(bob, 100); // recorded in week 1 (current)
        vm.warp(wa + 3 * WEEK + 1);
        assertEq(r.currentWeek(), 3);
        vm.expectRevert(LeaderboardEngine.OutsideWindow.selector);
        e.distribute(1); // window (week 2) has passed; the pot rolls forward, not grabbed
    }

    // ─── pre-audit: paired WEEK() + weekAnchor are cross-checked at construction (only genesis was before) ─

    function test_cadence_mismatchedWeekRevertsAtConstruction() public {
        // a short-clock engine wired to the mainnet-cadence registry (same genesis, so only cadence differs)
        vm.expectRevert(LeaderboardEngine.CadenceMismatch.selector);
        new LeaderboardEngineTenMin(
            address(reg), address(vault), address(claimMgr), GENESIS, 1, type(uint256).max, address(this)
        );

        // and the mirror image: a mainnet-cadence engine wired to a short-clock registry
        LeaderboardRegistryTenMin r10 = new LeaderboardRegistryTenMin(GENESIS, address(this));
        vm.expectRevert(LeaderboardEngine.CadenceMismatch.selector);
        new LeaderboardEngine(
            address(r10), address(vault), address(claimMgr), GENESIS, 1, type(uint256).max, address(this)
        );
    }

    function test_cadence_anchorOnlyMismatchReverts() public {
        // the "half a pair" mistake: WEEK matches (7d/7d) but the registry anchors to genesis while the
        // engine anchors to the prior Sunday, so week numbering would silently diverge
        LeaderboardRegistryAnchorOnly ra = new LeaderboardRegistryAnchorOnly(GENESIS, address(this));
        assertEq(ra.WEEK(), eng.WEEK(), "same WEEK on both halves");
        assertTrue(ra.weekAnchor() != reg.weekAnchor(), "but a different anchor");
        vm.expectRevert(LeaderboardEngine.CadenceMismatch.selector);
        new LeaderboardEngine(
            address(ra), address(vault), address(claimMgr), GENESIS, 1, type(uint256).max, address(this)
        );
    }

    function test_cadence_matchedShortClockPairConstructs() public {
        LeaderboardRegistryTenMin r10 = new LeaderboardRegistryTenMin(GENESIS, address(this));
        LeaderboardEngineTenMin e10 = new LeaderboardEngineTenMin(
            address(r10), address(vault), address(claimMgr), GENESIS, 1, type(uint256).max, address(this)
        );
        assertEq(e10.WEEK(), 10 minutes, "engine on the 10-minute week");
        assertEq(e10.WEEK(), r10.WEEK(), "matched cadence");
        assertEq(e10.weekAnchor(), r10.weekAnchor(), "matched anchor");
        assertEq(e10.weekAnchor(), GENESIS, "genesis-anchored short clock");
        vm.warp(GENESIS + 10 minutes + 1);
        assertEq(e10.currentWeek(), 1, "engine counts 10-minute weeks");
        assertEq(r10.currentWeek(), 1, "registry counts the same 10-minute weeks");
    }
}

// ─── pre-audit (cadence cross-check) fixtures: short-clock halves of the LeaderboardEngine/Registry pair ────
// Local 10-minute, genesis-anchored overrides (the same shape as src/testnet/TestnetShortClock.sol) so the
// tests can pair and mis-pair the halves without importing the testnet file.
contract LeaderboardRegistryTenMin is LeaderboardRegistry {
    constructor(uint256 genesis_, address o) LeaderboardRegistry(genesis_, o) { }

    function WEEK() public pure override returns (uint256) {
        return 10 minutes;
    }

    function _deriveWeekAnchor(uint256 genesis_) internal pure override returns (uint256) {
        return genesis_;
    }
}

contract LeaderboardEngineTenMin is LeaderboardEngine {
    constructor(
        address registry_,
        address vault_,
        address claim_,
        uint256 genesis_,
        uint256 minPot_,
        uint256 potCap_,
        address o
    ) LeaderboardEngine(registry_, vault_, claim_, genesis_, minPot_, potCap_, o) { }

    function WEEK() public pure override returns (uint256) {
        return 10 minutes;
    }

    function _deriveWeekAnchor(uint256 genesis_) internal pure override returns (uint256) {
        return genesis_;
    }
}

/// @dev A registry that overrides ONLY the anchor derivation (WEEK stays 7 days): the half-a-pair mistake.
contract LeaderboardRegistryAnchorOnly is LeaderboardRegistry {
    constructor(uint256 genesis_, address o) LeaderboardRegistry(genesis_, o) { }

    function _deriveWeekAnchor(uint256 genesis_) internal pure override returns (uint256) {
        return genesis_;
    }
}
