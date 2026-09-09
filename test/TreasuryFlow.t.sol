// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { Treasury } from "../src/Treasury.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockSwapAdapter } from "./mocks/MockSwapAdapter.sol";
import { MockRevertZeroERC20 } from "./mocks/MockRevertZeroERC20.sol";
import { MockBlacklistERC20 } from "./mocks/MockBlacklistERC20.sol";

contract TreasuryFlowTest is Test {
    Treasury treasury;
    MockERC20 qpull;
    MockERC20 weth;
    MockERC20 quotron;
    MockSwapAdapter qpullWeth;
    MockSwapAdapter wethQuotron;

    address prizeVault = makeAddr("prizeVault");
    address holderVault = makeAddr("holderVault");
    address leaderboardVault = makeAddr("leaderboardVault");
    address team = makeAddr("team");

    // The per-call caps ship FAIL-CLOSED (0 = NotConfigured, pre-audit medium). Tests that do not exercise the
    // caps arm them wide open so the rest of the convert() behaviour is unchanged; cap tests set their own.
    // external audit F-5: setMax*PerCall now rejects type(uint256).max on-chain (the bound used to live
    // only in script/GoLiveMainnet.s.sol, which has already run by the time a compromised owner would
    // use it). These fixtures used max as shorthand for "uncapped for this test", not as an assertion
    // about max itself, so a large finite sentinel preserves the intent.
    uint256 constant UNCAPPED = type(uint256).max / 2;

    function setUp() public {
        qpull = new MockERC20();
        weth = new MockERC20();
        quotron = new MockERC20();
        qpullWeth = new MockSwapAdapter(1e18, 1e18);
        wethQuotron = new MockSwapAdapter(1e18, 1e18);

        treasury = new Treasury(address(qpull), address(weth), address(quotron), address(this));
        treasury.setAdapters(address(qpullWeth), address(wethQuotron));
        treasury.setRouting(prizeVault, holderVault, leaderboardVault, team);
        treasury.setConvertThreshold(0);
        treasury.setMaxConvertPerCall(UNCAPPED); // caps must be armed before convert() runs (fail-closed)
        treasury.setMaxWethConvertPerCall(UNCAPPED);
        treasury.setKeeper(address(this), true); // convert() is keeper-gated (audit fix)
    }

    // ─── pre-audit MEDIUM (treasury-convert): both per-call caps ship fail-CLOSED ────────────────

    /// Both caps default to 0 = "not configured". A fully wired Treasury (adapters + routing + keeper) must
    /// still refuse to convert until BOTH pool-sized ceilings are armed, so the H-1/H-3 donation-brick and
    /// keeper-MEV bounds can never be silently left off at launch (they used to default to type(uint256).max
    /// and no deploy/go-live script set them).
    function test_capsUnsetConvertRevertsNotConfigured() public {
        Treasury t = new Treasury(address(qpull), address(weth), address(quotron), address(this));
        t.setAdapters(address(qpullWeth), address(wethQuotron));
        t.setRouting(prizeVault, holderVault, leaderboardVault, team);
        t.setKeeper(address(this), true);
        assertEq(t.maxConvertPerCall(), 0, "QPULL cap defaults to 0 (not configured)");
        assertEq(t.maxWethConvertPerCall(), 0, "WETH cap defaults to 0 (not configured)");
        qpull.mint(address(t), 10_000e18);

        vm.expectRevert(Treasury.NotConfigured.selector);
        t.convert(0, 0);

        // arming only ONE cap is still not configured: both legs must be bounded
        t.setMaxConvertPerCall(1_000e18);
        vm.expectRevert(Treasury.NotConfigured.selector);
        t.convert(0, 0);
        t.setMaxConvertPerCall(UNCAPPED); // reset, then try the other one alone
        // (setter cannot return a cap to 0, so build a fresh Treasury for the WETH-only case)
        Treasury t2 = new Treasury(address(qpull), address(weth), address(quotron), address(this));
        t2.setAdapters(address(qpullWeth), address(wethQuotron));
        t2.setRouting(prizeVault, holderVault, leaderboardVault, team);
        t2.setKeeper(address(this), true);
        t2.setMaxWethConvertPerCall(1_000e18);
        qpull.mint(address(t2), 10_000e18);
        vm.expectRevert(Treasury.NotConfigured.selector);
        t2.convert(0, 0);

        // arming both opens the pipeline, and the first slice honours the QPULL cap
        t.setMaxConvertPerCall(1_000e18);
        t.setMaxWethConvertPerCall(1_000e18);
        t.convert(0, 0);
        assertEq(qpull.balanceOf(address(t)), 9_000e18, "one 1000-slice converted once both caps are armed");
        assertEq(weth.balanceOf(team), 200e18, "team 20% of the capped slice");
    }

    /// The 0 sentinel is only meaningful because the setter refuses it (mirror of the WETH test below).
    /// VARIANT of pre-submission review N-4, found on BaseVault and swept to Treasury: both had an
    /// unconditional onERC721Received and neither has ANY ERC-721 egress, so a misdirected safeTransferFrom
    /// to a published deploy address destroyed the token instead of reverting.
    function test_n4variant_treasuryRejectsNftFromAnyoneButQuotron() public {
        address stranger = makeAddr("nftStranger");
        vm.prank(stranger);
        vm.expectRevert(Treasury.UnexpectedNft.selector);
        treasury.onERC721Received(stranger, stranger, 1, "");
        // QUOTRON's own terminal mint is still accepted, which is the documented purpose
        vm.prank(address(quotron));
        bytes4 sel = treasury.onERC721Received(address(quotron), address(treasury), 7, "");
        assertEq(sel, Treasury.onERC721Received.selector, "QUOTRON auto-mint still accepted");
    }

    // ── Wave 1 external-audit fixes: each of these FAILS against pre-fix code ──────────────────────

    /// external audit F-5. The only bound on the convert caps lived in script/GoLiveMainnet.s.sol, which has
    /// already run by the time a compromised owner would raise them. Post-lock: cap -> max, self-grant keeper,
    /// convert(0,0) sandwiches an uncapped slice through the shallow QUOTRON pool. Destinations hold; value
    /// leaves as slippage. The bound has to survive the script, so it lives in the setter now.
    function test_f5_caps_rejectMaxUint() public {
        vm.expectRevert(Treasury.CapTooLarge.selector);
        treasury.setMaxConvertPerCall(type(uint256).max);
        vm.expectRevert(Treasury.CapTooLarge.selector);
        treasury.setMaxWethConvertPerCall(type(uint256).max);
        // one below max is still allowed: ordinary re-tuning must keep working, since the caps have to track
        // pool depth as the permanently-locked LP accrues fees.
        treasury.setMaxConvertPerCall(type(uint256).max - 1);
        assertEq(treasury.maxConvertPerCall(), type(uint256).max - 1, "finite caps still settable");
    }

    /// external audit F-1(a). owedTotal sums quotronOwed at the three CURRENT role addresses, so two roles
    /// sharing an address double-counts it and permanently under-computes `splittable`.
    function test_f1_setRouting_rejectsAliasedVaults() public {
        Treasury t = new Treasury(address(qpull), address(weth), address(quotron), address(this));
        vm.expectRevert(Treasury.VaultsNotDistinct.selector);
        t.setRouting(prizeVault, prizeVault, leaderboardVault, team);
        vm.expectRevert(Treasury.VaultsNotDistinct.selector);
        t.setRouting(prizeVault, holderVault, holderVault, team);
        vm.expectRevert(Treasury.VaultsNotDistinct.selector);
        t.setRouting(prizeVault, holderVault, prizeVault, team);
        // team may still equal a vault: it takes WETH, never QUOTRON, so it is not part of owedTotal.
        t.setRouting(prizeVault, holderVault, leaderboardVault, prizeVault);
        assertEq(t.team(), prizeVault, "team is not constrained by the distinctness rule");
    }

    /// external audit F-9. The three token bindings are immutable with no re-deploy path.
    function test_f9_constructor_rejectsZeroTokens() public {
        vm.expectRevert(Treasury.NotConfigured.selector);
        new Treasury(address(0), address(weth), address(quotron), address(this));
        vm.expectRevert(Treasury.NotConfigured.selector);
        new Treasury(address(qpull), address(0), address(quotron), address(this));
        vm.expectRevert(Treasury.NotConfigured.selector);
        new Treasury(address(qpull), address(weth), address(0), address(this));
    }

    /// external audit F-8. convert() requires both caps, so a lock that verified only the six addresses
    /// promised a completeness it did not check.
    function test_f8_lockRouting_requiresCapsArmed() public {
        Treasury t = new Treasury(address(qpull), address(weth), address(quotron), address(this));
        t.setAdapters(address(qpullWeth), address(wethQuotron));
        t.setRouting(prizeVault, holderVault, leaderboardVault, team);
        vm.expectRevert(Treasury.NotConfigured.selector);
        t.lockRouting(); // caps unarmed
        t.setMaxConvertPerCall(1_000e18);
        vm.expectRevert(Treasury.NotConfigured.selector);
        t.lockRouting(); // only one armed
        t.setMaxWethConvertPerCall(1_000e18);
        t.lockRouting();
        assertTrue(t.routingLocked(), "locks once both caps are armed");
    }

    function test_setMaxConvertPerCall_rejectsZero() public {
        vm.expectRevert(Treasury.BelowThreshold.selector);
        treasury.setMaxConvertPerCall(0);
    }

    /// lockRouting() deliberately does NOT require the caps (they are pool-sized, tuned at go-live, and stay
    /// owner-mutable after the lock, audit L-6) — but a locked Treasury with unset caps still fails closed.
    /// SUPERSEDED IN PART by external audit F-8 (2026-09-08). This used to lock routing with the caps UNSET
    /// and assert convert() then reverted NotConfigured. lockRouting() now refuses that state outright
    /// (see test_f8_lockRouting_requiresCapsArmed), so that half of the old assertion is unreachable by
    /// construction, which is strictly stronger. The OTHER half is still load-bearing and is what this test
    /// now pins: the caps are deliberately NOT frozen by the routing lock. SECURITY.md 16.6 depends on that
    /// — the caps must keep tracking pool depth as the permanently-locked LP accrues fees — and F-5's fix
    /// (rejecting type(uint256).max) must NOT have turned ordinary post-lock re-tuning into a revert.
    function test_capsRemainMutableAfterLockRouting() public {
        Treasury t = new Treasury(address(qpull), address(weth), address(quotron), address(this));
        t.setAdapters(address(qpullWeth), address(wethQuotron));
        t.setRouting(prizeVault, holderVault, leaderboardVault, team);
        t.setKeeper(address(this), true);
        t.setMaxConvertPerCall(1_000e18); // F-8: both caps must be armed BEFORE the lock
        t.setMaxWethConvertPerCall(1_000e18);
        t.lockRouting();

        // routing itself is frozen forever
        vm.expectRevert(Treasury.RoutingAlreadyLocked.selector);
        t.setRouting(prizeVault, holderVault, leaderboardVault, team);

        // ...but the caps are not, in EITHER direction: they must track pool depth over time.
        t.setMaxConvertPerCall(UNCAPPED);
        t.setMaxWethConvertPerCall(UNCAPPED);
        assertEq(t.maxConvertPerCall(), UNCAPPED, "cap raised post-lock");
        t.setMaxConvertPerCall(500e18);
        assertEq(t.maxConvertPerCall(), 500e18, "cap lowered post-lock");

        // and the pipeline works with the re-tuned caps
        qpull.mint(address(t), 1e18);
        t.convert(0, 0);
        assertEq(qpull.balanceOf(address(t)), 0, "converts with post-lock re-tuned caps");
    }

    function test_convertSplitsCorrectly() public {
        qpull.mint(address(treasury), 10_000e18);

        treasury.convert(0, 0);

        // team = 20% in WETH
        assertEq(weth.balanceOf(team), 2_000e18, "team 20% WETH");
        // prize = 8000 QUOTRON, split 6125/625/1250
        assertEq(quotron.balanceOf(prizeVault), 6_125e18, "raffle 61.25%");
        assertEq(quotron.balanceOf(holderVault), 625e18, "holder 6.25%");
        assertEq(quotron.balanceOf(leaderboardVault), 1_250e18, "leaderboard 12.5%");
        assertEq(qpull.balanceOf(address(treasury)), 0, "all QPULL consumed");
    }

    function test_onlyKeeperCanConvert() public {
        qpull.mint(address(treasury), 10_000e18);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Treasury.NotKeeper.selector);
        treasury.convert(0, 0);
    }

    // ─── audit F2 (pass-5): lockRouting() freezes convert()'s destinations; keeper stays rotatable ──

    function test_F2_lockRoutingFreezesSetRouting() public {
        treasury.lockRouting();
        assertTrue(treasury.routingLocked(), "locked");
        vm.expectRevert(Treasury.RoutingAlreadyLocked.selector);
        treasury.setRouting(makeAddr("a"), makeAddr("b"), makeAddr("c"), makeAddr("attackerTeam"));
    }

    function test_F2_keeperStillRotatableAfterRoutingLock() public {
        treasury.lockRouting();
        // the keeper (a hot key) is deliberately NOT locked — it can still be rotated
        address newKeeper = makeAddr("newKeeper");
        treasury.setKeeper(newKeeper, true);
        assertTrue(treasury.isKeeper(newKeeper), "keeper still settable after routing lock");
        // and convert still routes to the frozen destinations
        qpull.mint(address(treasury), 10_000e18);
        treasury.convert(0, 0);
        assertEq(quotron.balanceOf(prizeVault), 6_125e18, "still routes to the locked prizeVault");
    }

    function test_F2_lockRoutingOnlyOwner() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        treasury.lockRouting();
    }

    function test_belowThresholdReverts() public {
        treasury.setConvertThreshold(1_000e18);
        qpull.mint(address(treasury), 500e18);
        vm.expectRevert(Treasury.BelowThreshold.selector);
        treasury.convert(0, 0);
    }

    function test_notConfiguredReverts() public {
        Treasury t = new Treasury(address(qpull), address(weth), address(quotron), address(this));
        t.setKeeper(address(this), true); // pass the keeper gate so we reach the NotConfigured check
        qpull.mint(address(t), 1e18);
        vm.expectRevert(Treasury.NotConfigured.selector);
        t.convert(0, 0);
    }

    function test_offChainSlippageFloorEnforced() public {
        // WETH→QUOTRON adapter fills only 0.9:1 → demanding the full amount trips the floor
        MockSwapAdapter shortFill = new MockSwapAdapter(1e18, 0.9e18);
        treasury.setAdapters(address(qpullWeth), address(shortFill));
        qpull.mint(address(treasury), 1_000e18);
        // 1000 QPULL → 1000 WETH; team 250; prize 750 WETH; shortFill delivers 675 < demanded 750
        vm.expectRevert("slippage");
        treasury.convert(0, 750e18);
    }

    // ─── H-2: the hook now delivers sell-tax as WETH directly to the Treasury ─────────────────

    function test_wethOnlyTaxIsSweptWithNoQpull() public {
        // A batch of pure sell-tax: WETH sits in the Treasury, zero QPULL. convert() must still run
        // (team 20% + prize 80% -> QUOTRON), not revert.
        weth.mint(address(treasury), 1_000e18);
        treasury.convert(0, 0);
        // team 20% -> 200 WETH; prize 800 WETH -> 800 QUOTRON split over PRIZE_BPS(8000):
        // holder 800*625/8000=62.5, leaderboard 800*1250/8000=125, raffle = remainder 612.5
        assertEq(weth.balanceOf(team), 200e18, "team 20% of the WETH-only batch");
        assertEq(quotron.balanceOf(prizeVault), 612.5e18, "raffle 76.5625% of the 800 prize");
        assertEq(quotron.balanceOf(holderVault), 62.5e18, "holder 7.8125% of the prize");
        assertEq(quotron.balanceOf(leaderboardVault), 125e18, "leaderboard 15.625% of the prize");
    }

    function test_bothCurrencySweep_teamTakes20pctOfAll() public {
        // buys paid 400 QPULL, sells paid 600 WETH: after leg 1 (400 QPULL -> 400 WETH) the Treasury
        // holds 1000 WETH; team gets 20% of the whole 1000, not just the swapped 400.
        qpull.mint(address(treasury), 400e18);
        weth.mint(address(treasury), 600e18);
        treasury.convert(0, 0);
        assertEq(weth.balanceOf(team), 200e18, "team 20% of BOTH tax currencies combined");
        assertEq(qpull.balanceOf(address(treasury)), 0, "QPULL leg ran");
    }

    /// The confirmed H-2-review LOW: a min-batch threshold ABOVE the per-call slice cap must NOT strand
    /// the QPULL leg. Gate is on the raw balance; the cap only sizes the slice.
    function test_thresholdAboveSliceCapStillConverts() public {
        treasury.setConvertThreshold(1_000e18); // min batch
        treasury.setMaxConvertPerCall(500e18); // smaller per-call slice (H-3 pool-sized)
        qpull.mint(address(treasury), 5_000e18); // well above threshold

        treasury.convert(0, 0); // must NOT revert BelowThreshold, must swap a 500 slice
        assertEq(qpull.balanceOf(address(treasury)), 4_500e18, "one 500 slice converted, remainder waits");
        assertEq(weth.balanceOf(team), 100e18, "team 20% of the 500 slice");
    }

    function test_belowRawThresholdStillWaits() public {
        // guard the other direction: a raw balance under the threshold still waits (no WETH held)
        treasury.setConvertThreshold(1_000e18);
        treasury.setMaxConvertPerCall(500e18);
        qpull.mint(address(treasury), 800e18); // under the 1000 threshold
        vm.expectRevert(Treasury.BelowThreshold.selector);
        treasury.convert(0, 0);
    }

    // ─── audit H-1: the WETH leg is capped per call, symmetric to maxConvertPerCall ─────────────

    function test_H1_wethDonationDrainsInSlicesNotBrick() public {
        // A large WETH donation (as a sell-tax batch, or an outright donation) must not force the whole
        // balance through the shallow QUOTRON pool in one swap. With a per-call cap, only a slice is
        // processed and the remainder waits for the next convert().
        treasury.setMaxWethConvertPerCall(1_000e18);
        weth.mint(address(treasury), 5_000e18);

        treasury.convert(0, 0);

        // one 1000-WETH slice processed: team 200, prize 800 -> QUOTRON; remaining 4000 WETH stays.
        assertEq(weth.balanceOf(team), 200e18, "team 20% of the CAPPED slice only");
        assertEq(weth.balanceOf(address(treasury)), 4_000e18, "excess WETH waits for the next slice");
        assertEq(
            quotron.balanceOf(prizeVault) + quotron.balanceOf(holderVault)
                + quotron.balanceOf(leaderboardVault),
            800e18,
            "prize QUOTRON = the 800 from this slice"
        );
    }

    function test_setMaxWethConvertPerCall_rejectsZero() public {
        vm.expectRevert(Treasury.BelowThreshold.selector);
        treasury.setMaxWethConvertPerCall(0);
    }

    // ─── audit M-5: zero-value split-transfer legs are skipped (adversarial 0-revert QUOTRON) ────

    function test_M5_thinBatchDoesNotBrickOnZeroTransferQuotron() public {
        // QUOTRON reverts on any zero-value transfer. A thin batch floors toHolder/toLeaderboard to 0;
        // convert() must SKIP those legs (their value rides in toHourly) instead of reverting.
        MockRevertZeroERC20 rz = new MockRevertZeroERC20();
        Treasury t = new Treasury(address(qpull), address(weth), address(rz), address(this));
        MockSwapAdapter qw = new MockSwapAdapter(1e18, 1e18);
        MockSwapAdapter wq = new MockSwapAdapter(1e18, 1e18);
        t.setAdapters(address(qw), address(wq));
        t.setRouting(prizeVault, holderVault, leaderboardVault, team);
        t.setMaxConvertPerCall(UNCAPPED); // caps are fail-closed; arm them
        t.setMaxWethConvertPerCall(UNCAPPED);
        t.setKeeper(address(this), true);

        qpull.mint(address(t), 7); // qOut ends at 6: both holder (6*625/8000=0) and leaderboard (=0) floor to 0
        t.convert(0, 0); // must NOT revert on the two zero-value QUOTRON transfers
        assertEq(rz.balanceOf(prizeVault), 6, "all prize QUOTRON rode into the hourly leg");
        assertEq(rz.balanceOf(holderVault), 0, "zero holder leg skipped, not reverted");
        assertEq(rz.balanceOf(leaderboardVault), 0, "zero leaderboard leg skipped, not reverted");
    }

    // ─── audit L-5: setAdapters rejects zero addresses (matching setRouting) ─────────────────────

    function test_L5_setAdaptersRejectsZero() public {
        vm.expectRevert(Treasury.NotConfigured.selector);
        treasury.setAdapters(address(0), address(wethQuotron));
        vm.expectRevert(Treasury.NotConfigured.selector);
        treasury.setAdapters(address(qpullWeth), address(0));
    }

    // ─── audit M3 (job-745): one blacklisted prize vault must NOT brick the whole convert() ──────

    /// QUOTRON can blacklist an address. If the holder vault were blacklisted, a naive `safeTransfer`
    /// split would revert and strand ALL prize routing. The fix routes each leg through `_trySendQuotron`
    /// (a low-level call that swallows a failed transfer) and splits the FULL balance, so a stuck slice
    /// stays in the Treasury and is retried on the next convert() rather than being lost.
    function test_M3_blacklistedVaultDoesNotBrickConvert() public {
        MockBlacklistERC20 q = new MockBlacklistERC20();
        MockSwapAdapter qw = new MockSwapAdapter(1e18, 1e18);
        MockSwapAdapter wq = new MockSwapAdapter(1e18, 1e18);
        Treasury t = new Treasury(address(qpull), address(weth), address(q), address(this));
        t.setAdapters(address(qw), address(wq));
        t.setRouting(prizeVault, holderVault, leaderboardVault, team);
        t.setConvertThreshold(0);
        t.setMaxConvertPerCall(UNCAPPED); // caps are fail-closed; arm them
        t.setMaxWethConvertPerCall(UNCAPPED);
        t.setKeeper(address(this), true);

        q.setBlacklisted(holderVault, true); // QUOTRON refuses any transfer to this vault

        qpull.mint(address(t), 10_000e18);
        t.convert(0, 0); // (a) must NOT revert despite the blacklisted destination

        // (b) every OTHER destination is funded correctly...
        assertEq(weth.balanceOf(team), 2_000e18, "team WETH still paid");
        assertEq(q.balanceOf(prizeVault), 6_125e18, "raffle slice paid");
        assertEq(q.balanceOf(leaderboardVault), 1_250e18, "leaderboard slice paid");
        // (c) ...the blacklisted vault got nothing, and its slice is retained (not lost)
        assertEq(q.balanceOf(holderVault), 0, "blacklisted holder vault received nothing");
        assertEq(q.balanceOf(address(t)), 625e18, "stuck holder slice stays in the Treasury");

        // (d) M-2 (pass-7): the stuck slice is credited to quotronOwed[holder] and retried to holder ITSELF,
        //     never redistributed to its sibling games.
        assertEq(t.quotronOwed(holderVault), 625e18, "stuck slice owed to the holder vault");
        q.setBlacklisted(holderVault, false);
        qpull.mint(address(t), 10_000e18);
        t.convert(0, 0);
        assertEq(q.balanceOf(holderVault), 1_250e18, "holder recovers its FULL owed 625 + the new 625 (M-2)");
        assertEq(t.quotronOwed(holderVault), 0, "owed cleared");
        // siblings got ONLY their two normal shares — the stuck 625 did NOT leak to them (the M-2 bug)
        assertEq(q.balanceOf(prizeVault), 12_250e18, "raffle: exactly 2x its normal share, no leaked slice");
        assertEq(q.balanceOf(leaderboardVault), 2_500e18, "leaderboard: exactly 2x its normal share");
        assertEq(q.balanceOf(address(t)), 0, "no QUOTRON left stranded in the Treasury");
    }

    // ─── audit L3 (job-745): setAdapters is frozen by lockRouting, same as setRouting ────────────

    function test_L3_setAdaptersFrozenByLockRouting() public {
        treasury.lockRouting();
        vm.expectRevert(Treasury.RoutingAlreadyLocked.selector);
        treasury.setAdapters(address(qpullWeth), address(wethQuotron));
    }
}
