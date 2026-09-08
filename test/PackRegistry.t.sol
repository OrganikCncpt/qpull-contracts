// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";

contract PackRegistryTest is Test {
    PackRegistry reg;
    MockDrandOracle oracle;

    address token = makeAddr("token");
    address engine = makeAddr("engine");
    address alice = makeAddr("alice");

    uint256 constant GENESIS = 1_000_000;
    uint256 constant TICKET = 10e18; // 10 QPULL per ticket
    uint256 constant DAY = 1 days; // base cadence (RaffleEngine/PackRegistry.DAY() default); tests are scale-invariant (warp N*DAY)

    function setUp() public {
        vm.warp(GENESIS);
        oracle = new MockDrandOracle(GENESIS, 30); // 30s drand period
        reg = new PackRegistry(address(oracle), TICKET, GENESIS, 1 hours, address(this));
        reg.setRecorder(token);
        reg.setEngine(engine);
    }

    function _buy(address who, uint256 grossQpull) internal {
        vm.prank(token);
        reg.recordBuy(who, grossQpull);
    }

    // audit F14/F15: reward-gating bindings are write-once (recorder / engine / nft).
    function test_F14_setRecorderWriteOnce() public {
        vm.expectRevert(PackRegistry.AlreadySet.selector);
        reg.setRecorder(makeAddr("attacker"));
    }

    function test_F15_setEngineWriteOnce() public {
        vm.expectRevert(PackRegistry.AlreadySet.selector);
        reg.setEngine(makeAddr("attacker"));
    }

    function test_F15_setNftWriteOnce() public {
        reg.setNft(makeAddr("nft")); // first set OK
        vm.expectRevert(PackRegistry.AlreadySet.selector);
        reg.setNft(makeAddr("nft2"));
    }

    // audit F15: drawFrom clamps k to MAX_TICKETS_CEILING internally, so even the (write-once) engine —
    // or a hypothetical hostile one — cannot pop more than the ceiling of live tickets per call.
    function test_F15_drawFromClampsK() public {
        // 300 live tickets in cohort 0 (per-buy cap is 100, so three buys).
        _buy(alice, 1000e18);
        _buy(makeAddr("b1"), 1000e18);
        _buy(makeAddr("b2"), 1000e18);
        assertEq(reg.liveCount(1), 300, "300 live tickets for the day-1 draw");

        vm.warp(GENESIS + DAY + 1);
        vm.prank(engine);
        uint256[] memory won = reg.drawFrom(keccak256("b"), 1, type(uint256).max); // ask for "all 300+"
        assertEq(won.length, reg.MAX_TICKETS_CEILING(), "k clamped to the 200 ceiling, not 300");
        assertEq(reg.liveCount(1), 100, "only the clamped 200 were popped; 100 survive");
    }

    function test_mint_floorsAndBanksRemainder() public {
        _buy(alice, 25e18); // 25/10 = 2 tickets, 5 remainder
        assertEq(reg.nextPackId(), 3, "two ids minted");
        assertEq(reg.bankedRemainder(alice), 5e18, "5 banked");

        _buy(alice, 5e18); // 5 banked + 5 = 10 -> 1 ticket
        assertEq(reg.nextPackId(), 4, "third minted");
        assertEq(reg.bankedRemainder(alice), 0, "bank cleared");
    }

    function test_dustBelowMinMintsNothing() public {
        _buy(alice, 9e18); // below 10 -> 0 tickets, all banked
        assertEq(reg.nextPackId(), 1, "no ids");
        assertEq(reg.bankedRemainder(alice), 9e18);
    }

    function test_cohortAssignment() public {
        _buy(alice, 100e18); // 10 tickets, day 0
        assertEq(reg.cohortSize(0), 10);

        vm.warp(GENESIS + 1 * DAY + 1);
        _buy(alice, 50e18); // 5 tickets, day 1
        assertEq(reg.today(), 1);
        assertEq(reg.cohortSize(1), 5);
        assertEq(reg.cohortSize(0), 10);
    }

    function test_drawSelectsDistinctFromWindow() public {
        _buy(alice, 100e18); // 10 tickets, cohort 0
        vm.warp(GENESIS + 1 * DAY + 1); // day 1

        vm.prank(engine);
        uint256[] memory w = reg.drawFrom(keccak256("d1"), 1, 4);

        assertEq(w.length, 4, "drew 4");
        for (uint256 i; i < 4; ++i) {
            assertTrue(w[i] >= 1 && w[i] <= 10, "in range");
            for (uint256 j = i + 1; j < 4; ++j) {
                assertTrue(w[i] != w[j], "distinct");
            }
        }
        assertEq(reg.liveCount(1), 6, "6 remain live");
    }

    function test_drawCapsAtAvailable() public {
        _buy(alice, 30e18); // 3 tickets
        vm.warp(GENESIS + 1 * DAY + 1);
        vm.prank(engine);
        uint256[] memory w = reg.drawFrom(keccak256("d1"), 1, 10); // ask 10, only 3 live
        assertEq(w.length, 3, "capped at live count");
        assertEq(reg.liveCount(1), 0);
    }

    function test_expiryWindowSlides() public {
        _buy(alice, 100e18); // cohort 0, eligible days 1..7
        assertEq(reg.liveCount(7), 10, "still live on last eligible day");

        vm.warp(GENESIS + 8 * DAY + 1);
        assertEq(reg.liveCount(8), 0, "expired: cohort 0 out of window on day 8");
    }

    function test_tierDerivationSealedThenRevealed() public {
        _buy(alice, 10e18); // pack 1
        (, uint64 rr,,) = reg.packs(1); // the pack's actual (quantized) reveal round

        vm.expectRevert(); // sealed: round not yet published
        reg.tierOf(1);

        oracle.setBeacon(rr, keccak256("beacon"));
        uint8 t = reg.tierOf(1);
        assertLe(t, 3, "valid tier");
    }

    /// Fuzz: draws never exceed the live set and never repeat a pack across a day's draw.
    function testFuzz_drawNeverExceedsOrRepeats(uint256 buyAmt, uint256 k) public {
        buyAmt = bound(buyAmt, TICKET, 500 * TICKET); // up to 500 tickets requested
        k = bound(k, 1, 100);
        _buy(alice, buyAmt);
        uint256 minted = buyAmt / TICKET;
        uint256 cap = reg.maxTicketsPerBuy(); // audit H-18: a buy mints at most the cap; rest is banked
        if (minted > cap) minted = cap;

        vm.warp(GENESIS + 1 * DAY + 1);
        vm.prank(engine);
        uint256[] memory w = reg.drawFrom(keccak256("fuzz"), 1, k);

        assertLe(w.length, minted, "never more than minted");
        assertLe(w.length, k, "never more than requested");
        // uniqueness
        for (uint256 i; i < w.length; ++i) {
            for (uint256 j = i + 1; j < w.length; ++j) {
                assertTrue(w[i] != w[j], "no repeats");
            }
        }
        assertEq(reg.liveCount(1), minted - w.length, "live set decremented exactly");
    }

    // ─── bounded ticket-price re-peg (§13.4) ─────────────────────────────────

    function test_setTicketPrice_withinBoundsUpdatesAndEmits() public {
        uint256 up = TICKET * 125 / 100; // +25% exactly (upper bound)
        vm.expectEmit(true, true, true, true);
        emit PackRegistry.TicketPriceSet(TICKET, up);
        reg.setTicketPrice(up);
        assertEq(reg.ticketPrice(), up, "price updated to +25%");

        vm.warp(GENESIS + 1 days + 1); // clear cooldown
        uint256 down = up * 75 / 100; // −25% exactly (lower bound)
        reg.setTicketPrice(down);
        assertEq(reg.ticketPrice(), down, "price updated to -25%");
    }

    function test_setTicketPrice_revertsAboveBound() public {
        vm.expectRevert(PackRegistry.AdjustOutOfBounds.selector);
        reg.setTicketPrice(TICKET * 125 / 100 + 1); // one wei above +25%
    }

    function test_setTicketPrice_revertsBelowBound() public {
        vm.expectRevert(PackRegistry.AdjustOutOfBounds.selector);
        reg.setTicketPrice(TICKET * 75 / 100 - 1); // one wei below −25%
    }

    function test_setTicketPrice_cooldownEnforced() public {
        reg.setTicketPrice(TICKET + 1e18); // first re-peg ok (within +25%)
        vm.expectRevert(PackRegistry.AdjustTooSoon.selector);
        reg.setTicketPrice(TICKET + 2e18); // same day → too soon

        vm.warp(GENESIS + 1 days + 1);
        reg.setTicketPrice(TICKET + 2e18); // a day later → ok
        assertEq(reg.ticketPrice(), TICKET + 2e18);
    }

    function test_setTicketPrice_zeroReverts() public {
        vm.expectRevert(PackRegistry.TicketPriceZero.selector);
        reg.setTicketPrice(0);
    }

    function test_setTicketPrice_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(); // Ownable: caller is not the owner
        reg.setTicketPrice(TICKET + 1e18);
    }

    function test_setTicketPrice_takesEffectOnMinting() public {
        // Under the launch price (10 QPULL), a 25-QPULL buy = 2 tickets + 5 banked.
        // After re-pegging to 12.5 QPULL, the same 25-QPULL buy = 2 tickets + 0 banked.
        reg.setTicketPrice(125e17); // 12.5e18, +25%
        _buy(alice, 25e18);
        assertEq(reg.nextPackId(), 3, "2 tickets at the new price");
        assertEq(reg.bankedRemainder(alice), 0, "no remainder at 12.5 (proves new price in effect)");
    }

    function test_constructor_zeroTicketPriceReverts() public {
        vm.expectRevert(PackRegistry.TicketPriceZero.selector);
        new PackRegistry(address(oracle), 0, GENESIS, 1 hours, address(this));
    }

    // ─── (c) rollOf / tierAndRollOf (verifiable rip) ──────────────────────────

    // mirrors PackRegistry._tierFromRoll (the fixed, published rarity bands)
    function _tierFromRoll(uint256 roll) internal pure returns (uint8) {
        if (roll < 100) return 3; // SUPER_RARE 1%
        if (roll < 500) return 2; // RARE 4%
        if (roll < 2000) return 1; // UNCOMMON 15%
        return 0; // COMMON 80%
    }

    function test_rollOf_revertsBeforeReveal() public {
        _buy(alice, 10e18); // pack 1
        vm.expectRevert(); // sealed: the reveal round's beacon is not yet published
        reg.rollOf(1);
    }

    function test_rollOf_inRangeAndMatchesTier() public {
        _buy(alice, 100e18); // 10 packs, cohort 0
        (, uint64 rr,,) = reg.packs(1); // all day-0 packs share one reveal round
        oracle.setBeacon(rr, keccak256("beacon"));

        for (uint256 id = 1; id <= 10; ++id) {
            uint256 roll = reg.rollOf(id);
            assertLt(roll, 10_000, "roll in [0,10000)");
            // _tierFromRoll(rollOf(id)) == tierOf(id)
            assertEq(_tierFromRoll(roll), reg.tierOf(id), "tier derived from the roll matches tierOf");

            // tierAndRollOf returns the matching (tier, roll) pair
            (uint8 t, uint256 r) = reg.tierAndRollOf(id);
            assertEq(r, roll, "tierAndRollOf roll matches rollOf");
            assertEq(t, reg.tierOf(id), "tierAndRollOf tier matches tierOf");
        }
    }

    function test_tierAndRollOf_revertsBeforeReveal() public {
        _buy(alice, 10e18);
        vm.expectRevert(); // rollOf() reverts until the round reveals
        reg.tierAndRollOf(1);
    }
}
