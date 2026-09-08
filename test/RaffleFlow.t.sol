// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { BaseVault } from "../src/BaseVault.sol";
import { ClaimManager } from "../src/ClaimManager.sol";
import { RaffleEngine } from "../src/RaffleEngine.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/// End-to-end: buy tickets → fund vault → run the daily draw → winner claims.
/// Also asserts the solvency invariant (reserved ≤ pot) and the void-on-miss window.
contract RaffleFlowTest is Test {
    PackRegistry packs;
    BaseVault vault;
    ClaimManager claimMgr;
    RaffleEngine raffle;
    MockDrandOracle oracle;
    MockERC20 quotron;

    address token = makeAddr("token");
    address alice = makeAddr("alice");

    uint256 constant GENESIS = 1_000_000;
    uint256 constant PERIOD = 30;
    uint256 constant TICKET = 10e18;
    uint256 constant DAY = 1 days; // base cadence (RaffleEngine/PackRegistry.DAY() default); tests are scale-invariant (warp N*DAY)
    uint256 constant POT = 1000e18;
    uint256 constant K = 3;

    function setUp() public {
        vm.warp(GENESIS);
        oracle = new MockDrandOracle(GENESIS, PERIOD);
        quotron = new MockERC20();

        packs = new PackRegistry(address(oracle), TICKET, GENESIS, 1 hours, address(this));
        vault = new BaseVault(address(quotron), address(this));
        claimMgr = new ClaimManager(address(this));
        raffle = new RaffleEngine(
            address(oracle),
            address(packs),
            address(vault),
            address(claimMgr),
            GENESIS,
            K,
            1,
            POT, // audit M4 (job-745): finite ctor potCap so the ±25% rate-limit can't overflow in setUp
            address(this)
        );

        // wiring
        packs.setRecorder(token);
        packs.setEngine(address(raffle));
        claimMgr.setEngine(address(raffle), address(vault));
        vault.setController(address(claimMgr));

        // fund the prize vault
        quotron.mint(address(vault), POT);
    }

    function _buy(address who, uint256 grossQpull) internal {
        vm.prank(token);
        packs.recordBuy(who, grossQpull);
    }

    // RaffleEngine is two-phase: a one-time runOpeningDraw() (which sweeps the accumulation cohorts
    // [0, ACCUM_DAYS-1]) must run before any daily runDraw(). This posts the opening beacon + the
    // cohort-0 tier reveal, warps past the 2-day accumulation window, and runs the opening draw.
    // Requires >=1 live ticket already bought in cohort 0/1 and a funded vault.
    function _bootstrapOpening() internal {
        (, uint64 revRound,,) = packs.packs(1); // all day-0 packs share one quantized reveal round
        oracle.setBeacon(revRound, keccak256("reveal"));
        oracle.setBeacon(raffle.drawRound(1), keccak256("opening")); // drawRound(ACCUM_DAYS-1)
        vm.warp(GENESIS + 2 * DAY + 1); // currentDay() >= ACCUM_DAYS (2)
        raffle.runOpeningDraw();
        assertTrue(raffle.openingDone(), "opening draw bootstrapped");
    }

    function test_endToEnd_buyDrawClaim() public {
        _buy(alice, 100e18); // 10 tickets, cohort 0

        // The one-time opening draw sweeps the accumulation cohorts [0,1] and pays OPENING_WINNERS.
        // Alice is the sole buyer, so every opening winner is alice.
        _bootstrapOpening();
        assertEq(raffle.currentDay(), 2);

        // claims were written; solvency: reserved ≤ pot
        uint256 nClaims = claimMgr.nextClaimId();
        assertGt(nClaims, 0, "at least one prize");
        assertLe(vault.unclaimedReserve(), POT, "never reserve more than the pot");

        // alice (sole buyer) claims her first prize
        (,, uint256 amount,, bool settled) = claimMgr.claims(1);
        assertGt(amount, 0);
        assertFalse(settled);

        uint256 balBefore = quotron.balanceOf(alice);
        uint256 reserveBefore = vault.unclaimedReserve();
        vm.prank(alice);
        claimMgr.claim(1);

        assertEq(quotron.balanceOf(alice), balBefore + amount, "paid out");
        assertEq(vault.unclaimedReserve(), reserveBefore - amount, "reserve released");
    }

    // audit H-3: a delaying winner can't inflate the pot — potCap bounds a single day's payout.
    function test_H3_potCapBoundsPayout() public {
        _buy(alice, 100e18);

        quotron.mint(address(vault), 9 * POT); // vault now holds 10*POT; a delayer waited while it grew
        // audit M4 (job-745): potCap is now the finite ctor value (POT) — no setPotCap needed to bound it.
        // The opening draw is bounded by potCap exactly like a daily draw.
        _bootstrapOpening();

        // the draw only ever sees `potCap`, so at most POT is reserved and the 9*POT excess rolls forward.
        assertLe(vault.unclaimedReserve(), POT, "payout bounded by potCap, not the inflated balance");
        assertGe(vault.freeBalance(), 9 * POT, "the excess above the cap stays in the vault");
    }

    function test_H3_setPotCapRejectsZeroAndBelowMinPot() public {
        // audit M4 (job-745): setMinPot is now bounded to ±25%/call, so a high minPot can't be reached via
        // the setter from the ctor default of 1 — deploy with the high minPot (500e18) at CONSTRUCTION
        // instead, then prove setPotCap rejects 0 and any value below that minPot floor.
        RaffleEngine r = new RaffleEngine(
            address(oracle), address(packs), address(vault), address(claimMgr), GENESIS, K, 500e18, 1000e18, address(this)
        );
        vm.expectRevert(RaffleEngine.BadPotCap.selector);
        r.setPotCap(0);
        vm.expectRevert(RaffleEngine.BadPotCap.selector);
        r.setPotCap(400e18); // below the minPot floor (500e18)
    }

    // audit F5: minPot is REQUIRED (> 0) at construction — no unsafe 0 default that a dust donation exploits.
    function test_F5_constructorRejectsZeroMinPot() public {
        vm.expectRevert(RaffleEngine.BadMinPot.selector);
        new RaffleEngine(
            address(oracle),
            address(packs),
            address(vault),
            address(claimMgr),
            GENESIS,
            K,
            0,
            type(uint256).max,
            address(this)
        );
    }

    // audit F14 (pass-5): potCap is REQUIRED (> 0) at construction now — no fail-open uncapped default.
    function test_F14_constructorRejectsZeroPotCap() public {
        vm.expectRevert(RaffleEngine.BadPotCap.selector);
        new RaffleEngine(
            address(oracle), address(packs), address(vault), address(claimMgr), GENESIS, K, 1, 0, address(this)
        );
    }

    function test_F14_constructorRejectsMinPotAbovePotCap() public {
        vm.expectRevert(RaffleEngine.BadMinPot.selector);
        new RaffleEngine(
            address(oracle),
            address(packs),
            address(vault),
            address(claimMgr),
            GENESIS,
            K,
            100e18,
            10e18,
            address(this)
        );
    }

    function test_F5_setMinPotRejectsZero() public {
        vm.expectRevert(RaffleEngine.BadMinPot.selector);
        raffle.setMinPot(0);
    }

    // audit M4 (job-745): setPotCap is bounded to ±25% per DAY cooldown — no single-tx pot re-peg
    // that would let a compromised owner inflate/deflate a day's payout in one shot.
    function test_M4_setPotCapRateLimitedAndBounded() public {
        assertEq(raffle.potCap(), POT, "starts at the ctor cap");

        // a +33% jump is outside the ±25% band → rejected
        vm.expectRevert(RaffleEngine.AdjustOutOfBounds.selector);
        raffle.setPotCap(1_330e18);

        // a +20% move is within band → allowed (first adjust; cooldown anchor started at 0)
        raffle.setPotCap(1_200e18);
        assertEq(raffle.potCap(), 1_200e18, "in-band re-peg applied");

        // a second adjust before the DAY cooldown elapses → AdjustTooSoon
        vm.expectRevert(RaffleEngine.AdjustTooSoon.selector);
        raffle.setPotCap(1_250e18);

        // after the cooldown, another in-band move succeeds
        vm.warp(block.timestamp + DAY + 1);
        raffle.setPotCap(1_450e18); // +20.8% from 1200
        assertEq(raffle.potCap(), 1_450e18, "second re-peg after the cooldown");
    }

    // audit L-10 (pass-7): setMinPot is rate-limited like setPotCap (its unguarded twin no longer).
    function test_L10_setMinPotRateLimited() public {
        raffle.setMinPot(2); // first adjust ok (cooldown anchor started at 0; GENESIS > DAY)
        vm.expectRevert(RaffleEngine.AdjustTooSoon.selector);
        raffle.setMinPot(3); // a second change within the DAY cooldown is rejected
        vm.warp(block.timestamp + DAY + 1);
        raffle.setMinPot(3); // after the cooldown it succeeds
        assertEq(raffle.minPot(), 3);
    }

    function test_voidWindow_cannotDrawEarly() public {
        _buy(alice, 100e18);
        // After the opening draw unlocks daily draws, drawing day 2 while it's still day 2 is too early:
        // day 2's window is day 3. (Before openingDone this would revert OpeningPending first.)
        _bootstrapOpening(); // leaves currentDay() == 2
        vm.expectRevert(RaffleEngine.OutsideWindow.selector);
        raffle.runDraw(2);
    }

    function test_voidWindow_noCatchUp() public {
        _buy(alice, 100e18);
        _bootstrapOpening(); // openingDone; currentDay() == 2
        // jump to day 4 — day 2's window (day 3) has passed → void, no catch-up
        vm.warp(GENESIS + 4 * DAY + 1);
        vm.expectRevert(RaffleEngine.OutsideWindow.selector);
        raffle.runDraw(2);
    }

    function test_cannotDrawTwice() public {
        _buy(alice, 100e18); // cohort 0
        _bootstrapOpening(); // opening sweeps [0,1]; alice's remaining cohort-0 tickets stay live
        // a normal daily draw for day 2 (window [0,1] still holds alice's remaining tickets)
        quotron.mint(address(vault), POT); // top up so the day-2 pot clears minPot after the opening reserve
        oracle.setBeacon(raffle.drawRound(2), keccak256("d2"));
        vm.warp(GENESIS + 3 * DAY + 1); // currentDay() == day+1 == 3
        raffle.runDraw(2);
        vm.expectRevert(RaffleEngine.AlreadyDrawn.selector);
        raffle.runDraw(2);
    }

    /// Audit fix: a draw on a ZERO pot must not consume tickets (drawFrom marks them spent). It also
    /// must not mark the day drawn, so a retry pays out if the vault is funded later within the window.
    function test_zeroPotDoesNotBurnTickets() public {
        // A fresh raffle with a HIGH minPot (POT) set at construction. The one-time opening draw is
        // bootstrapped with exactly `minPot` of funding, which the opening partly RESERVES — leaving the
        // free balance BELOW minPot. The subsequent DAILY draw therefore sees a sub-minPot pot and must
        // hit the audit-C1/H-17 guard: do NOT burn tickets, register claims, or mark the day drawn.
        // (A truly-zero pot can't survive bootstrapping — the opening itself needs a nonzero pot — so the
        // sub-minPot floor exercises the identical `pot < minPot` guard branch on the daily draw.)
        MockDrandOracle o2 = new MockDrandOracle(GENESIS, PERIOD);
        PackRegistry p2 = new PackRegistry(address(o2), TICKET, GENESIS, 1 hours, address(this));
        BaseVault v2 = new BaseVault(address(quotron), address(this));
        ClaimManager c2 = new ClaimManager(address(this));
        RaffleEngine r2 = new RaffleEngine(
            address(o2),
            address(p2),
            address(v2),
            address(c2),
            GENESIS,
            K,
            POT, // minPot floor
            type(uint256).max, // potCap uncapped
            address(this)
        );
        p2.setRecorder(token);
        p2.setEngine(address(r2));
        c2.setEngine(address(r2), address(v2));
        v2.setController(address(c2));

        vm.prank(token);
        p2.recordBuy(alice, 100e18); // 10 tickets, cohort 0
        assertEq(p2.liveCount(1), 10, "10 tickets live");

        // bootstrap the opening draw with exactly minPot of funding (opening reserves some → free < minPot)
        (, uint64 revRound2,,) = p2.packs(1);
        o2.setBeacon(revRound2, keccak256("reveal"));
        o2.setBeacon(r2.drawRound(1), keccak256("opening"));
        o2.setBeacon(r2.drawRound(2), keccak256("d2"));
        quotron.mint(address(v2), POT);
        vm.warp(GENESIS + 2 * DAY + 1);
        r2.runOpeningDraw();
        assertTrue(r2.openingDone(), "opening bootstrapped");

        // day-2 daily draw with a sub-minPot pot → must not burn tickets, register claims, or mark drawn.
        vm.warp(GENESIS + 3 * DAY + 1); // currentDay() == day+1 == 3
        uint256 liveBefore = p2.liveCount(2);
        uint256 claimsBefore = c2.nextClaimId();
        assertGt(liveBefore, 0, "cohort-0 tickets still live for the day-2 window");
        assertLt(v2.freeBalance(), r2.minPot(), "free balance sits below minPot after the opening reserve");

        r2.runDraw(2);
        assertEq(p2.liveCount(2), liveBefore, "tickets NOT burned on a sub-minPot pot");
        assertEq(c2.nextClaimId(), claimsBefore, "no claims registered");
        assertFalse(r2.drawn(2), "day not marked drawn -> retry allowed once funded");

        // fund above minPot, retry within the same window → now it pays out.
        quotron.mint(address(v2), POT);
        r2.runDraw(2);
        assertGt(c2.nextClaimId(), claimsBefore, "draw pays out once funded");
        assertTrue(r2.drawn(2), "now marked drawn");
    }

    // ─── pre-audit L (opening-draw liveness): a sub-minPot pot at window close FORGOES the opening ────────
    // (void-on-miss) instead of leaving openingDone=false and blocking every daily draw behind it.

    /// Fresh harness with a HIGH minPot: the setUp one uses 1 wei, so its vault can never sit under minPot.
    /// Replaces the harness fields in place so the shared helpers (_buy, _bootstrapOpening) keep working.
    /// potCap is uncapped so `pot` equals the vault's free balance exactly.
    function _redeployWithMinPot(uint256 minPot_, uint256 fund) internal {
        oracle = new MockDrandOracle(GENESIS, PERIOD);
        packs = new PackRegistry(address(oracle), TICKET, GENESIS, 1 hours, address(this));
        vault = new BaseVault(address(quotron), address(this));
        claimMgr = new ClaimManager(address(this));
        raffle = new RaffleEngine(
            address(oracle),
            address(packs),
            address(vault),
            address(claimMgr),
            GENESIS,
            K,
            minPot_,
            type(uint256).max,
            address(this)
        );
        packs.setRecorder(token);
        packs.setEngine(address(raffle));
        claimMgr.setEngine(address(raffle), address(vault));
        vault.setController(address(claimMgr));
        if (fund > 0) quotron.mint(address(vault), fund);
    }

    /// (1) Small pot at window close: the opening SETTLES (openingDone) with no payout and no burned tickets,
    ///     the first daily day becomes callable (it was OpeningPending before the fix), voids under minPot,
    ///     and pays once the vault is funded above minPot. (3) The forgone opening can never run again.
    function test_L_openingSmallPot_settlesForgoneAndUnlocksDailyDraws() public {
        _redeployWithMinPot(POT, POT / 2); // vault holds POT/2 < minPot (POT)
        _buy(alice, 100e18); // 10 tickets, cohort 0
        (, uint64 revRound,,) = packs.packs(1);
        oracle.setBeacon(revRound, keccak256("reveal"));
        // Deliberately NO opening beacon (drawRound(1)): a forgone opening must settle WITHOUT reading drand.
        // The mock reverts "unavailable" on a missing round, so this test fails if the small-pot path reads it.

        vm.warp(GENESIS + 2 * DAY + 1); // currentDay() == ACCUM_DAYS: the window has closed
        assertLt(vault.freeBalance(), raffle.minPot(), "pot sits under minPot at window close");
        uint256 liveBefore = packs.liveCount(2);
        assertEq(liveBefore, 10, "all 10 cohort-0 tickets live for the day-2 window");

        vm.expectEmit(true, false, false, true, address(raffle));
        emit RaffleEngine.DrawExecuted(0, POT / 2, 0); // day 0 = opening, snapshotted pot, 0 winners
        raffle.runOpeningDraw();

        assertTrue(raffle.openingDone(), "opening SETTLED (forgone) on a sub-minPot pot");
        assertEq(claimMgr.nextClaimId(), 0, "nobody is paid under minPot");
        assertEq(vault.unclaimedReserve(), 0, "nothing reserved");
        assertEq(packs.liveCount(2), liveBefore, "no tickets burned: cohorts [0,1] keep every ticket");
        assertEq(vault.freeBalance(), POT / 2, "the pot rolls forward untouched");

        // (3) never twice: the forgone opening is settled for good
        vm.expectRevert(RaffleEngine.OpeningAlreadyDone.selector);
        raffle.runOpeningDraw();

        // the first daily day (ACCUM_DAYS) is now CALLABLE ...
        oracle.setBeacon(raffle.drawRound(2), keccak256("d2"));
        vm.warp(GENESIS + 3 * DAY + 1); // currentDay() == day+1 == 3
        raffle.runDraw(2);
        // ... and self-voids under minPot: no payout, no burn, day not consumed (audit C-1/H-17 unchanged)
        assertEq(claimMgr.nextClaimId(), 0, "daily draw voids under minPot");
        assertFalse(raffle.drawn(2), "a void does not consume the day");
        assertEq(packs.liveCount(2), liveBefore, "a void burns nothing");

        // fund above minPot within the window -> the retry pays K winners from the rolled-forward pot
        quotron.mint(address(vault), POT); // free = 1.5*POT >= minPot
        raffle.runDraw(2);
        assertEq(claimMgr.nextClaimId(), K, "daily draw pays exactly K winners once funded");
        assertTrue(raffle.drawn(2), "the paying draw consumes the day");
        assertLe(vault.unclaimedReserve(), POT + POT / 2, "solvency: reserved <= pot");
        (, address recip, uint256 amount,,) = claimMgr.claims(1);
        assertEq(recip, alice, "sole buyer wins");
        assertGt(amount, 0, "a real prize");
    }

    /// Anti-skip: the forgone-settle is only reachable once the window has CLOSED. An under-minPot call inside
    /// the window is still Accumulating (openingDone stays false), and an opening that is payable by the time
    /// the window closes pays exactly as before. So openingDone=true can never skip a legitimate opening.
    function test_L_openingSmallPot_cannotForgoBeforeWindowClose() public {
        _redeployWithMinPot(POT, 0); // EMPTY vault
        _buy(alice, 100e18); // 10 tickets, cohort 0
        (, uint64 revRound,,) = packs.packs(1);
        oracle.setBeacon(revRound, keccak256("reveal"));

        vm.warp(GENESIS + 2 * DAY - 1); // currentDay() == 1 < ACCUM_DAYS
        vm.expectRevert(RaffleEngine.Accumulating.selector);
        raffle.runOpeningDraw();
        assertFalse(raffle.openingDone(), "not settled before the window closes, funded or not");

        // funded above minPot by window close -> the LEGITIMATE opening pays OPENING_WINNERS (paid path, unchanged)
        quotron.mint(address(vault), POT); // free = POT == minPot
        oracle.setBeacon(raffle.drawRound(1), keccak256("opening")); // drawRound(ACCUM_DAYS-1)
        vm.warp(GENESIS + 2 * DAY + 1);
        raffle.runOpeningDraw();
        assertTrue(raffle.openingDone(), "settled by the paid path");
        assertEq(claimMgr.nextClaimId(), raffle.OPENING_WINNERS(), "a payable opening is never skipped");
    }

    /// (2) Normal path: pot >= minPot pays exactly OPENING_WINNERS from the accumulation cohorts, popping
    ///     exactly that many tickets, and (3) can never run twice.
    function test_L_openingNormalPath_paysExactlyOpeningWinners() public {
        _buy(alice, 100e18); // 10 tickets, cohort 0; setUp funded the vault with POT >= minPot (1 wei)
        uint256 liveBefore = packs.liveCount(2);
        _bootstrapOpening(); // pot >= minPot: the PAID path
        uint256 n = raffle.OPENING_WINNERS();
        assertEq(claimMgr.nextClaimId(), n, "exactly OPENING_WINNERS claims written");
        assertEq(packs.liveCount(2), liveBefore - n, "exactly OPENING_WINNERS tickets popped");
        assertGt(vault.unclaimedReserve(), 0, "the opening reserved its payout");
        assertLe(vault.unclaimedReserve(), POT, "solvency: reserved <= pot");
        vm.expectRevert(RaffleEngine.OpeningAlreadyDone.selector);
        raffle.runOpeningDraw();
    }

    // ─── (c) WinnerPaid event: one per paid winner, tied to the ClaimManager claim ──

    function test_WinnerPaid_emittedPerWinner_matchesClaims() public {
        _buy(alice, 100e18); // 10 tickets, cohort 0 (alice is the sole buyer)

        vm.recordLogs();
        _bootstrapOpening(); // runs the one-time opening draw; day 0 = the opening sweep
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 sig = RaffleEngine.WinnerPaid.selector;
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig || logs[i].emitter != address(raffle)) continue;
            ++seen;
            uint32 day = uint32(uint256(logs[i].topics[1])); // indexed day
            uint256 packId = uint256(logs[i].topics[2]); // indexed packId
            (address owner, uint8 tier, uint256 prize, uint256 claimId) =
                abi.decode(logs[i].data, (address, uint8, uint256, uint256));

            assertEq(day, 0, "opening sweep is day 0");
            assertTrue(packId >= 1 && packId < packs.nextPackId(), "a real packId");
            assertEq(owner, alice, "sole buyer owns every winning pack");
            assertEq(tier, packs.tierOf(packId), "tier == packs.tierOf(packId)");
            assertGt(prize, 0, "a paid winner receives >0");

            // the claimId matches the ClaimManager claim registered for this win
            assertTrue(claimId >= 1 && claimId <= claimMgr.nextClaimId(), "claimId in range");
            (, address recip, uint256 amount,, bool settled) = claimMgr.claims(claimId);
            assertEq(recip, owner, "claim recipient == WinnerPaid owner");
            assertEq(amount, prize, "claim amount == WinnerPaid prize");
            assertFalse(settled, "freshly registered, not yet claimed");
        }

        assertGt(seen, 0, "at least one WinnerPaid emitted");
        assertEq(seen, claimMgr.nextClaimId(), "one WinnerPaid per registered claim");
    }

    function test_expiredClaimSweepsBackToVault() public {
        _buy(alice, 100e18);
        _bootstrapOpening(); // opening draw writes alice's claims (claim id 1)

        (,, uint256 amount,,) = claimMgr.claims(1);
        uint256 freeBefore = vault.freeBalance();

        // let the 30-day CLAIM_WINDOW (real days, not the short DAY) lapse, then sweep
        vm.warp(block.timestamp + 31 days);
        claimMgr.sweepExpired(1);

        assertEq(vault.freeBalance(), freeBefore + amount, "unclaimed prize rolled back into the pot");

        // and it can no longer be claimed
        vm.prank(alice);
        vm.expectRevert(ClaimManager.AlreadySettled.selector);
        claimMgr.claim(1);
    }

    // ─── pre-audit: the paired DAY() cadence is cross-checked at construction (only genesis was before) ──

    function test_cadence_dayLengthExposesBaseCadence() public view {
        assertEq(packs.dayLength(), 1 days, "base PackRegistry cadence is 1 day");
    }

    function test_cadence_mismatchedPairRevertsAtConstruction() public {
        // a short-clock engine wired to the mainnet-cadence registry (same genesis, so only cadence differs)
        vm.expectRevert(RaffleEngine.CadenceMismatch.selector);
        new RaffleEngineFiveMin(
            address(oracle), address(packs), address(vault), address(claimMgr), GENESIS, K, 1, POT, address(this)
        );

        // and the mirror image: a mainnet-cadence engine wired to a short-clock registry
        PackRegistryFiveMin p5 = new PackRegistryFiveMin(address(oracle), TICKET, GENESIS, 1 hours, address(this));
        assertEq(p5.dayLength(), 5 minutes, "short-clock registry reports its override");
        vm.expectRevert(RaffleEngine.CadenceMismatch.selector);
        new RaffleEngine(
            address(oracle), address(p5), address(vault), address(claimMgr), GENESIS, K, 1, POT, address(this)
        );
    }

    function test_cadence_matchedShortClockPairConstructs() public {
        PackRegistryFiveMin p5 = new PackRegistryFiveMin(address(oracle), TICKET, GENESIS, 1 hours, address(this));
        RaffleEngineFiveMin r5 = new RaffleEngineFiveMin(
            address(oracle), address(p5), address(vault), address(claimMgr), GENESIS, K, 1, POT, address(this)
        );
        assertEq(p5.dayLength(), 5 minutes, "matched pair: registry on the 5-minute clock");
        // both halves count days on the same clock
        vm.warp(GENESIS + 5 minutes + 1);
        assertEq(r5.currentDay(), 1, "engine counts 5-minute days");
        assertEq(p5.today(), 1, "registry counts the same 5-minute days");
    }
}

// ─── pre-audit (cadence cross-check) fixtures: short-clock halves of the RaffleEngine/PackRegistry pair ────
// Local 5-minute overrides (the same shape as src/testnet/TestnetShortClock.sol) so the tests can pair and
// mis-pair the halves without importing the testnet file.
contract PackRegistryFiveMin is PackRegistry {
    constructor(address drand_, uint256 ticketPrice_, uint256 genesis_, uint256 revealDelay_, address o)
        PackRegistry(drand_, ticketPrice_, genesis_, revealDelay_, o)
    { }

    function DAY() internal pure override returns (uint256) {
        return 5 minutes;
    }
}

contract RaffleEngineFiveMin is RaffleEngine {
    constructor(
        address drand_,
        address packs_,
        address vault_,
        address claim_,
        uint256 genesis_,
        uint256 k_,
        uint256 minPot_,
        uint256 potCap_,
        address o
    ) RaffleEngine(drand_, packs_, vault_, claim_, genesis_, k_, minPot_, potCap_, o) { }

    function DAY() internal pure override returns (uint256) {
        return 5 minutes;
    }
}
