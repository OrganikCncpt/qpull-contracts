// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { console2 } from "forge-std/console2.sol";
import { PledgeFloodBase } from "./NFTIntegration.t.sol";

/// @notice Measures the ACTUAL gas of the daily draw's selection loop against the Robinhood Chain block
///         ceiling. Two open questions depend on these numbers and nothing else:
///
///         (1) RaffleEngine F-8 (external audit): `MAX_K = 200` carries a "one-block-safe, ~120-140k
///             gas/winner" comment, but `PackRegistry.SAFE_FREE_K = 150` says anything above 150 ships
///             WITHOUT a confirmed margin when the virtual free-entry block is active. RaffleEngine never
///             reads SAFE_FREE_K, so `winnersPerDay` may legally sit in (150, 200]. Is that range safe?
///
///         (2) FS-3b: the preferred fix prunes invalid pledges out of `wb`, which adds an O(pledgeList) pass
///             to every draw. The alternative (terminal void) costs nothing but leaves q > 0. The prune is
///             only takeable if the headroom measured here absorbs it.
///
/// @dev    Assertion-light on purpose: these are measurements, not invariants. The only hard assert is
///         against the chain ceiling, with margin. Run with `-vv` to read the table.
contract GasBenchmarkTest is PledgeFloodBase {
    /// Robinhood Chain (Arbitrum Orbit L2) per-block gas ceiling, measured for the holder-draw work.
    uint256 constant RH_BLOCK_CEILING = 32_000_000;
    /// Leave real headroom: a draw that needs more than half a block is not "one-block-safe" in practice.
    uint256 constant SAFE_FRACTION_BPS = 5000;

    function _measureDrawFrom(uint256 k, bytes32 beacon) internal returns (uint256 used) {
        uint256 before = gasleft();
        vm.prank(address(engine));
        packs.drawFrom(beacon, D, k);
        used = before - gasleft();
    }

    /// @notice Q1 — does the (150, 200] band RaffleEngine allows actually fit in a block?
    function test_gas_drawFrom_acrossK() public {
        _srs(9);                       // full Super Rare set
        _pledgeRares(honest, HONEST_BASE, 90); // 90 Rares pledged, weight 4 each
        _warpToDraw();

        console2.log("=== drawFrom gas vs k (free block ACTIVE, 9 SR + 90 pledged Rares) ===");
        console2.log("RH block ceiling:", RH_BLOCK_CEILING);
        uint256[4] memory ks = [uint256(50), 100, 150, 200];
        uint256 last;
        for (uint256 i; i < ks.length; ++i) {
            uint256 used = _measureDrawFrom(ks[i], keccak256(abi.encode("k", ks[i])));
            console2.log("  k =", ks[i]);
            console2.log("    gas used      :", used);
            console2.log("    gas per winner:", used / ks[i]);
            console2.log("    % of a block  :", (used * 100) / RH_BLOCK_CEILING);
            last = used;
        }
        // The hard gate: k = MAX_K must fit comfortably, since RaffleEngine permits it.
        assertLt(last, (RH_BLOCK_CEILING * SAFE_FRACTION_BPS) / 10_000, "k=200 exceeds half a block");
    }

    /// @notice Q2 — how does cost scale with the pledge list? This is the surface an FS-3b `wb` prune
    ///         would have to walk on every draw, so its slope is the prune's per-draw price.
    function test_gas_drawFrom_pledgeScaling() public {
        _srs(9);
        _warpToPledgeDay();
        console2.log("=== drawFrom gas vs pledged-Rare count at k = 200 ===");
        // grow the pledge population and re-measure
        uint256[4] memory counts = [uint256(25), 50, 100, 200];
        uint256 base = HONEST_BASE;
        uint256 planted;
        for (uint256 i; i < counts.length; ++i) {
            uint256 add = counts[i] - planted;
            _pledgeRares(honest, base + planted, add);
            planted = counts[i];
            uint256 snap = vm.snapshotState();
            _warpToDraw();
            uint256 used = _measureDrawFrom(200, keccak256(abi.encode("p", counts[i])));
            console2.log("  pledged Rares:", counts[i]);
            console2.log("    pledge copies (weight 4):", counts[i] * 4);
            console2.log("    gas used                :", used);
            vm.revertToState(snap);
        }
    }

    /// @notice The pathological case: a large flood inflates `pledgeList` with entries that are all invalid
    ///         at draw time. This is the population an FS-3b prune exists to remove, so it bounds the
    ///         prune's worst-case cost AND shows what the current code pays to reject them one seat at a time.
    function test_gas_drawFrom_underFlood() public {
        _srs(9);
        _pledgeRares(honest, HONEST_BASE, 50);
        _flood(200); // 200 Rares pledged then handed off: 800 invalid copies in pledgeList
        _warpToDraw();
        uint256 used = _measureDrawFrom(200, keccak256("flood"));
        console2.log("=== drawFrom gas at k=200 UNDER FLOOD (50 honest + 200 flooded Rares) ===");
        console2.log("  pledgeList copies:", uint256(250 * 4));
        console2.log("  gas used         :", used);
        console2.log("  % of a block     :", (used * 100) / RH_BLOCK_CEILING);
        assertLt(used, RH_BLOCK_CEILING, "flooded draw exceeds a whole block");
    }
}

// ─────────────────────────────────────────────────────────────────────────────────────────────────────

import { Test } from "forge-std/Test.sol";
import { PackRegistry } from "../src/PackRegistry.sol";
import { BaseVault } from "../src/BaseVault.sol";
import { ClaimManager } from "../src/ClaimManager.sol";
import { RaffleEngine } from "../src/RaffleEngine.sol";
import { MockDrandOracle } from "./mocks/MockDrandOracle.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockNFT } from "./mocks/MockNFT.sol";

/// @notice THE deciding measurement for RaffleEngine F-8. The benchmark above times `drawFrom` in
///         isolation, which is precisely the O(k) cost the `MAX_K = 200` comment leaves out. The comment's
///         own estimate is "~120-140k gas/winner" for the PAYOUT loop. If both are real, k = 200 would be
///         200 * (140k + 33k) = ~34.6M, i.e. OVER a 32M block. This measures the whole `runDraw` in one
///         transaction — selection loop, payout loop, tier reads, vault reserves and claim registration —
///         so the question is settled by a number rather than by adding two estimates together.
contract RaffleEndToEndGasTest is Test {
    PackRegistry packs;
    BaseVault vault;
    ClaimManager claimMgr;
    RaffleEngine raffle;
    MockDrandOracle oracle;
    MockERC20 quotron;
    MockNFT nft;

    address token = makeAddr("token");
    address buyer = makeAddr("buyer");
    address pledger = makeAddr("pledger");

    uint256 constant GENESIS = 1_000_000;
    uint256 constant TICKET = 10e18;
    uint256 constant DAY = 1 days;
    uint256 constant POT = 1_000_000e18;
    uint256 constant RH_BLOCK_CEILING = 32_000_000;

    function _build(uint256 k) internal {
        vm.warp(GENESIS);
        oracle = new MockDrandOracle(GENESIS, 30);
        quotron = new MockERC20();
        nft = new MockNFT();
        packs = new PackRegistry(address(oracle), TICKET, GENESIS, 1 hours, address(this));
        vault = new BaseVault(address(quotron), address(this));
        claimMgr = new ClaimManager(address(this));
        raffle = new RaffleEngine(
            address(oracle), address(packs), address(vault), address(claimMgr),
            GENESIS, k, 1, POT, address(this)
        );
        packs.setRecorder(token);
        packs.setEngine(address(raffle));
        packs.setNft(address(nft));
        claimMgr.setEngine(address(raffle), address(vault));
        vault.setController(address(claimMgr));
        quotron.mint(address(vault), POT);

        // deep paid pool in cohort 0 so k winners are all drawable
        for (uint256 i; i < 20; ++i) {
            vm.prank(token);
            packs.recordBuy(buyer, 500 * TICKET); // 500 tickets each
        }
        // Super Rares + pledged Rares so the VIRTUAL free-entry block is active during the daily draw
        uint256[] memory srs = new uint256[](9);
        for (uint256 i; i < 9; ++i) { nft.set(1 + i, pledger, 3); srs[i] = 1 + i; }
        packs.registerSuperRare(srs);
    }

    function _bootstrapOpening() internal {
        (, uint64 rr,,) = packs.packs(1);
        oracle.setBeacon(rr, keccak256("reveal"));
        oracle.setBeacon(raffle.drawRound(1), keccak256("opening"));
        vm.warp(GENESIS + 2 * DAY + 1);
        raffle.runOpeningDraw();
    }

    function _pledge(uint256 n) internal {
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) { nft.set(100 + i, pledger, 2); ids[i] = 100 + i; }
        vm.prank(pledger);
        packs.pledge(ids);
    }

    function _runDayDraw(uint32 day) internal returns (uint256 used) {
        oracle.setBeacon(raffle.drawRound(day), keccak256(abi.encode("day", day)));
        vm.warp(GENESIS + (uint256(day) + 1) * DAY + 2 hours);
        uint256 before = gasleft();
        raffle.runDraw(day);
        used = before - gasleft();
    }

    function _bench(uint256 k) internal returns (uint256) {
        _build(k);
        _bootstrapOpening();       // currentDay() == 2
        _pledge(90);               // pledges land on day 2, before its freeze
        uint256 used = _runDayDraw(2);
        console2.log("  k =", k);
        console2.log("    FULL runDraw gas :", used);
        console2.log("    gas per winner   :", used / k);
        console2.log("    %% of a 32M block :", (used * 100) / RH_BLOCK_CEILING);
        return used;
    }

    function test_gas_runDraw_endToEnd_k150() public {
        console2.log("=== FULL runDraw (selection + payout + claims), free block ACTIVE ===");
        uint256 used = _bench(150); // PackRegistry.SAFE_FREE_K
        assertLt(used, RH_BLOCK_CEILING, "k=150 (SAFE_FREE_K) exceeds a block");
    }

    function test_gas_runDraw_endToEnd_k200() public {
        console2.log("=== FULL runDraw at MAX_K, the value RaffleEngine actually permits ===");
        uint256 used = _bench(200); // RaffleEngine.MAX_K
        assertLt(used, RH_BLOCK_CEILING, "k=200 (MAX_K) exceeds a 32M block -- F-8 CONFIRMED");
    }
}
