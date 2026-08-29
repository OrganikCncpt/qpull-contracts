// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IDrandOracle } from "./interfaces/IDrandOracle.sol";
import { IPackRegistry } from "./interfaces/IRegistries.sol";
import { INFTCollection } from "./interfaces/INFTCollection.sol";

/// @title  PackRegistry
/// @notice Mints raffle tickets on buys (fixed whole-ticket schedule, spec §4), seals each to a
///         future drand round for its tier (spec §6), and maintains the live-ticket set as daily
///         cohorts so the RaffleEngine can draw a fixed K winners in O(K) regardless of how many
///         tickets exist (spec §7, fully-on-chain model).
///
/// @dev    Cadence: DAILY. Ticket life: 7 days. A cohort minted on day D is eligible for the
///         draws on days D+1 .. D+7 (7 shots), then falls out of the sliding window. Expiry is
///         therefore free — an aged cohort is simply never in-window again; no per-ticket cleanup.
contract PackRegistry is IPackRegistry, Ownable2Step {
    // ─── tiers ───────────────────────────────────────────────────────────────
    uint8 internal constant COMMON = 0;
    uint8 internal constant UNCOMMON = 1;
    uint8 internal constant RARE = 2;
    uint8 internal constant SUPER_RARE = 3;

    // ─── config (immutable) ──────────────────────────────────────────────────
    IDrandOracle public immutable drand;
    uint256 public immutable genesis; // launch timestamp; day 0 begins here
    uint256 public immutable revealDelay; // seconds ahead to seal the tier round (sealed-then-revealed)
    uint32 public constant LIFE_DAYS = 7; // ticket lifetime in daily draws
    uint256 internal constant DAY = 1 days;

    // ─── ticket price (§13.4) ─────────────────────────────────────────────────
    // QPULL per ticket, in base units (1e18 = 1 QPULL). Seeded to ~$10 of QPULL at launch. The owner
    // re-pegs it to hold ~$10 as QPULL's market price drifts — but ONLY within tight bounds (≤ ±25% per
    // change, ≤ once per day) so the knob can never zero-out (mint-farm) or moon (brick) the raffle, and
    // every move is slow + observable. No on-chain price is read: a live USD oracle off QPULL's own pool
    // would be a single-tx manipulation vector (pump the pool → mint extra tickets).
    uint256 public ticketPrice;
    uint256 public constant MAX_ADJ_BPS = 2500; // max ±25% per re-peg
    uint256 public constant ADJUST_COOLDOWN = 1 days; // min gap between re-pegs
    uint64 public lastTicketAdjust; // last re-peg timestamp (0 = never)

    // ─── wiring ──────────────────────────────────────────────────────────────
    address public recorder; // QpullTaxHook — only caller of recordBuy
    address public engine; // RaffleEngine — only caller of drawFrom
    // Gas bound on per-buy minting. At ~73k gas/pack a cap of 1000 needed ~73M gas — above the L2 block
    // limit, so an ordinary large buy reverted (audit H-18). 100 keeps a full-cap buy well within a block;
    // value above the cap is banked and mints on the buyer's next trade.
    uint256 public constant MAX_TICKETS_CEILING = 200;
    uint256 public maxTicketsPerBuy = 100;

    // ─── ticket state ────────────────────────────────────────────────────────
    struct Pack {
        address owner;
        uint64 revealRound; // drand round the tier is sealed against
        uint32 cohortDay; // day minted
        bool spent; // drawn (won) — burned
    }

    uint256 public nextPackId = 1;
    mapping(uint256 => Pack) public packs;
    mapping(uint32 => uint256[]) internal cohortLive; // cohortDay => live pack ids
    mapping(uint256 => uint256) internal packLiveIndex; // pack id => index within its cohort array
    mapping(address => uint256) public bankedRemainder; // sub-ticket QPULL carried forward (§4)

    // ─── free daily entries for NFT holders (spec §16) ───────────────────────
    INFTCollection public nft;
    uint256 public constant FREE_CAP_BPS = 2000; // free entries ≤ 20% of a day's PAID tickets
    mapping(uint32 => uint256) public paidToday; // day => paid tickets minted (buys)
    mapping(uint32 => uint256) public freeToday; // day => free tickets minted (NFT perk)
    mapping(uint256 => mapping(uint32 => bool)) public freeClaimed; // nft tokenId => day => claimed

    // ─── events / errors ─────────────────────────────────────────────────────
    event RecorderSet(address recorder);
    event EngineSet(address engine);
    event NftSet(address nft);
    event PackMinted(uint256 indexed id, address indexed owner, uint32 cohortDay, uint64 revealRound);
    event Drawn(uint32 indexed drawDay, uint256 count);
    event FreeEntriesClaimed(address indexed holder, uint32 indexed day, uint256 entries);
    event TicketPriceSet(uint256 oldPrice, uint256 newPrice);
    event MaxTicketsPerBuySet(uint256 m);

    error NotRecorder();
    error NotEngine();
    error NotStarted();
    error NoNft();
    error NotNftOwner();
    error TicketPriceZero();
    error AdjustTooSoon();
    error AdjustOutOfBounds();
    error ZeroDrand();
    error BadMaxTickets();
    error BadRevealDelay();

    modifier onlyRecorder() {
        if (msg.sender != recorder) revert NotRecorder();
        _;
    }

    modifier onlyEngine() {
        if (msg.sender != engine) revert NotEngine();
        _;
    }

    constructor(
        address drand_,
        uint256 ticketPrice_,
        uint256 genesis_,
        uint256 revealDelay_,
        address initialOwner
    ) Ownable(initialOwner) {
        if (ticketPrice_ == 0) revert TicketPriceZero();
        if (drand_ == address(0)) revert ZeroDrand(); // audit M-17: oracle sits on the taxed-buy hot path
        // audit H-7: seal margin must be >= the engines' REVEAL_LAG (1h) so a cohort's tier round isn't
        // near-public before the buy window closes, and < 1 day so it reveals within the cohort's draw window.
        if (revealDelay_ < 1 hours || revealDelay_ >= 1 days) revert BadRevealDelay();
        drand = IDrandOracle(drand_);
        ticketPrice = ticketPrice_;
        genesis = genesis_;
        revealDelay = revealDelay_;
    }

    function setRecorder(address t) external onlyOwner {
        recorder = t;
        emit RecorderSet(t);
    }

    function setEngine(address e) external onlyOwner {
        engine = e;
        emit EngineSet(e);
    }

    function setNft(address n) external onlyOwner {
        nft = INFTCollection(n);
        emit NftSet(n);
    }

    function setMaxTicketsPerBuy(uint256 m) external onlyOwner {
        if (m == 0 || m > MAX_TICKETS_CEILING) revert BadMaxTickets(); // audit H-18/L-5: bounded + event
        maxTicketsPerBuy = m;
        emit MaxTicketsPerBuySet(m);
    }

    /// @notice Re-peg the ticket price to hold ~$10 of QPULL per ticket as QPULL's market price drifts
    ///         (spec §13.4). Deliberately constrained — at most ±25% per change and at most once per day
    ///         — so the knob can never mint-farm (price→0) or brick (price→∞) the raffle, and every move
    ///         is slow and observable. The owner (ideally a timelock/multisig) computes the QPULL amount
    ///         currently worth ~$10 off-chain and sets it within these bounds. No price is read on-chain.
    function setTicketPrice(uint256 newPrice) external onlyOwner {
        if (newPrice == 0) revert TicketPriceZero();
        if (block.timestamp < uint256(lastTicketAdjust) + ADJUST_COOLDOWN) revert AdjustTooSoon();
        uint256 cur = ticketPrice;
        uint256 lo = (cur * (10_000 - MAX_ADJ_BPS)) / 10_000; // −25%
        uint256 hi = (cur * (10_000 + MAX_ADJ_BPS)) / 10_000; // +25%
        if (newPrice < lo || newPrice > hi) revert AdjustOutOfBounds();
        lastTicketAdjust = uint64(block.timestamp);
        ticketPrice = newPrice;
        emit TicketPriceSet(cur, newPrice);
    }

    // ─── minting (buys only) ─────────────────────────────────────────────────

    /// @inheritdoc IPackRegistry
    function recordBuy(address buyer, uint256 grossValue) external override onlyRecorder {
        uint256 avail = bankedRemainder[buyer] + grossValue;
        uint256 n = avail / ticketPrice;
        if (n > maxTicketsPerBuy) n = maxTicketsPerBuy; // cap gas; the excess value stays banked for later buys
        bankedRemainder[buyer] = avail - n * ticketPrice;
        if (n == 0) return;

        uint32 cday = _today();
        paidToday[cday] += n;
        _mintPacks(buyer, n, cday);
    }

    /// @notice NFT holders claim their rarity-weighted free daily entries (spec §16). Once per NFT
    ///         per day, and only while free entries stay ≤ 20% of the day's PAID tickets — so the
    ///         perk never lets holders dominate the pool. Claim after some paid volume has accrued
    ///         that day; tokens that would breach the cap are skipped and can be claimed later.
    function claimFreeEntries(uint256[] calldata tokenIds) external {
        if (address(nft) == address(0)) revert NoNft();
        uint32 cday = _today();
        uint256 cap = (paidToday[cday] * FREE_CAP_BPS) / 10_000;
        uint256 free = freeToday[cday];
        uint256 granted;
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 tid = tokenIds[i];
            if (nft.ownerOf(tid) != msg.sender) revert NotNftOwner();
            if (freeClaimed[tid][cday]) continue; // already claimed today
            uint256 e = _freeEntries(nft.rarityOf(tid)); // reverts if rarity not yet revealed
            if (free + granted + e > cap) break; // cap reached — remaining tokens retry later
            freeClaimed[tid][cday] = true;
            granted += e;
        }
        if (granted == 0) return;
        freeToday[cday] = free + granted;
        _mintPacks(msg.sender, granted, cday);
        emit FreeEntriesClaimed(msg.sender, cday, granted);
    }

    function _freeEntries(uint8 rarity) internal pure returns (uint256) {
        if (rarity == SUPER_RARE) return 10;
        if (rarity == RARE) return 4;
        if (rarity == UNCOMMON) return 2;
        return 1; // Common
    }

    function _mintPacks(address to, uint256 n, uint32 cday) internal {
        // Quantized reveal round (BLS keeper efficiency): ALL packs minted on day `cday` share ONE reveal
        // round — the round at (start of the next day + revealDelay). Still a FUTURE, time-locked round
        // (unknowable at mint — the audit #2 fix under a time-locked oracle), but ONE per day instead of
        // one per beacon, so the keeper posts ~1 tier beacon/day. Revealed before the cohort's first draw.
        uint64 rr = drand.roundAt(genesis + (uint256(cday) + 1) * DAY + revealDelay);
        uint256[] storage arr = cohortLive[cday];
        uint256 id = nextPackId;
        for (uint256 i; i < n; ++i) {
            packs[id] = Pack({ owner: to, revealRound: rr, cohortDay: cday, spent: false });
            packLiveIndex[id] = arr.length;
            arr.push(id);
            emit PackMinted(id, to, cday, rr);
            unchecked {
                ++id;
            }
        }
        nextPackId = id;
    }

    // ─── drawing (engine only) ───────────────────────────────────────────────

    /// @notice Draw up to `k` distinct winners from the live window for `drawDay`, mark them spent,
    ///         and return their ids. O(k · window) with window ≤ 7. Selection uses the day's beacon.
    /// @dev    Live window for day d = cohorts [d-7 .. d-1] (each cohort gets exactly 7 draws).
    function drawFrom(bytes32 beacon, uint32 drawDay, uint256 k)
        external
        onlyEngine
        returns (uint256[] memory winners)
    {
        if (drawDay == 0) revert NotStarted();
        uint32 from = drawDay > LIFE_DAYS ? drawDay - LIFE_DAYS : 0;
        uint32 to = drawDay - 1;

        uint256 total;
        for (uint32 c = from; c <= to; ++c) {
            total += cohortLive[c].length;
        }

        winners = new uint256[](k);
        uint256 got;
        for (uint256 j; j < k && total > 0; ++j) {
            uint256 r = uint256(keccak256(abi.encode(beacon, drawDay, j))) % total;
            for (uint32 c = from; c <= to; ++c) {
                uint256 len = cohortLive[c].length;
                if (r < len) {
                    winners[got++] = _popAt(c, r);
                    break;
                }
                r -= len;
            }
            unchecked {
                --total;
            }
        }

        // shrink the returned array to the number actually drawn
        assembly {
            mstore(winners, got)
        }
        emit Drawn(drawDay, got);
    }

    function _popAt(uint32 c, uint256 li) internal returns (uint256 pickedId) {
        uint256[] storage arr = cohortLive[c];
        uint256 last = arr.length - 1;
        pickedId = arr[li];
        if (li != last) {
            uint256 lastId = arr[last];
            arr[li] = lastId;
            packLiveIndex[lastId] = li;
        }
        arr.pop();
        packs[pickedId].spent = true;
    }

    // ─── tier derivation (verifiable, spec §6) ───────────────────────────────

    /// @notice The tier of a pack, derived from its sealed beacon. Reverts until the round reveals.
    ///         Anyone can recompute this — the "verify this rip" affordance.
    function tierOf(uint256 packId) public view returns (uint8) {
        Pack storage p = packs[packId];
        require(p.owner != address(0), "no pack");
        bytes32 beacon = drand.randomness(p.revealRound); // reverts if not yet revealed
        uint256 roll = uint256(keccak256(abi.encodePacked(beacon, packId))) % 10_000;
        if (roll < 100) return SUPER_RARE; // 1%
        if (roll < 500) return RARE; // 4%
        if (roll < 2000) return UNCOMMON; // 15%
        return COMMON; // 80%
    }

    // ─── views ───────────────────────────────────────────────────────────────

    function _today() internal view returns (uint32) {
        if (block.timestamp <= genesis) return 0;
        return uint32((block.timestamp - genesis) / DAY);
    }

    function today() external view returns (uint32) {
        return _today();
    }

    function ownerOf(uint256 packId) external view returns (address) {
        return packs[packId].owner;
    }

    function cohortSize(uint32 cohortDay) external view returns (uint256) {
        return cohortLive[cohortDay].length;
    }

    /// @notice Total live tickets eligible for the draw on `drawDay`.
    function liveCount(uint32 drawDay) external view returns (uint256 total) {
        if (drawDay == 0) return 0;
        uint32 from = drawDay > LIFE_DAYS ? drawDay - LIFE_DAYS : 0;
        for (uint32 c = from; c <= drawDay - 1; ++c) {
            total += cohortLive[c].length;
        }
    }
}
