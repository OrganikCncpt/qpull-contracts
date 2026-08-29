// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IDrandOracle } from "./interfaces/IDrandOracle.sol";
import { INFTCollection } from "./interfaces/INFTCollection.sol";

/// @title  NFTCollection — the launch NFT ("pack-rip mint")
/// @notice 250-piece collection. Mint price is paid in ETH and AUTO-SPLIT on every mint into three
///         locked buckets — 80% LP / 15% prize seed / 5% team (spec §16). Rarity is sealed at mint
///         and revealed against a future drand round (a "pack rip"), and drives the holder's free
///         daily raffle entries. The team can never withdraw more than its 5% — the split is enforced
///         on-chain; rarities are sealed at `finalizeLaunch()` and the buckets are pulled to their purpose
///         separately via `withdrawProceeds()` (so a bad payout recipient can never block the reveal).
/// @dev    Rarity is probabilistic (Common 70 / Uncommon 20 / Rare 8 / Super Rare 2), so final tier
///         counts are approximate, not exact — a fair rip. (Exact counts would need a drand-seeded
///         shuffle; flagged as an option, not built.)
contract NFTCollection is INFTCollection, ERC721, Ownable2Step, ReentrancyGuard {
    uint8 internal constant COMMON = 0;
    uint8 internal constant UNCOMMON = 1;
    uint8 internal constant RARE = 2;
    uint8 internal constant SUPER_RARE = 3;

    uint256 public constant MAX_SUPPLY = 250;
    uint256 internal constant BPS = 10_000;
    uint256 public constant LP_BPS = 8000; // 80%
    uint256 public constant SEED_BPS = 1500; // 15%
    // team = remainder (5%)

    uint256 public immutable mintPrice;
    IDrandOracle public immutable drand;
    uint256 public immutable revealDelay;

    uint256 public totalMinted;
    uint64 public revealRound; // ONE round sealing ALL rarities — set at finalizeLaunch (quantized for BLS)

    uint256 public lpReserve;
    uint256 public seedReserve;
    uint256 public teamReserve;

    bool public mintOpen;
    bool public launched;
    string internal _base;

    address public lpTreasury; // receives LP ETH (should be a locker, for trustlessness)
    address public seedTreasury; // receives seed ETH → buys QUOTRON → seeds the vaults
    address public team;

    event MintOpenSet(bool open);
    event RecipientsSet(address lpTreasury, address seedTreasury, address team);
    event Minted(uint256 indexed tokenId, address indexed to);
    event Launched(uint256 lp, uint256 seed, uint256 team);

    error MintClosed();
    error SoldOut();
    error BadPrice();
    error AlreadyLaunched();
    error AlreadyMinting();
    error RecipientsUnset();
    error NotLaunched();
    error NoToken();
    error ZeroDrand();
    error BadRevealDelay();

    constructor(uint256 mintPrice_, address drand_, uint256 revealDelay_, address initialOwner)
        ERC721("QPULL Terminal", "QPULLN")
        Ownable(initialOwner)
    {
        if (drand_ == address(0)) revert ZeroDrand(); // audit L-7
        if (revealDelay_ < 1 hours) revert BadRevealDelay(); // audit H-7: seal margin >= the engines' REVEAL_LAG
        mintPrice = mintPrice_;
        drand = IDrandOracle(drand_);
        revealDelay = revealDelay_;
    }

    // ─── config (owner, at launch) ───────────────────────────────────────────

    function setMintOpen(bool v) external onlyOwner {
        mintOpen = v;
        emit MintOpenSet(v);
    }

    function setRecipients(address lp, address seed, address team_) external onlyOwner {
        if (totalMinted > 0) revert AlreadyMinting(); // audit H-12: destinations freeze before any ETH flows
        if (lp == address(0) || seed == address(0) || team_ == address(0)) revert RecipientsUnset();
        lpTreasury = lp;
        seedTreasury = seed;
        team = team_;
        emit RecipientsSet(lp, seed, team_);
    }

    function setBaseURI(string calldata b) external onlyOwner {
        _base = b; // art can drop in any time
    }

    // ─── mint (pack rip) ─────────────────────────────────────────────────────

    function mint() external payable nonReentrant {
        if (!mintOpen || launched) revert MintClosed();
        // audit H-1: recipients MUST be set before any mint — otherwise the first mint freezes setRecipients
        // (AlreadyMinting) and finalizeLaunch (RecipientsUnset) forever, permanently locking proceeds AND the
        // rarity reveal (which cascades into PackRegistry.claimFreeEntries reverting for every holder).
        if (lpTreasury == address(0) || seedTreasury == address(0) || team == address(0)) {
            revert RecipientsUnset();
        }
        if (totalMinted >= MAX_SUPPLY) revert SoldOut();
        if (msg.value != mintPrice) revert BadPrice();

        uint256 id = ++totalMinted; // ids 1..250 (rarity is sealed collection-wide at finalizeLaunch)

        // Split 80/15/5. Team is the EXACT 5%; LP absorbs any rounding dust so team is never > 5% (audit L-17).
        uint256 seed = (msg.value * SEED_BPS) / BPS;
        uint256 teamCut = (msg.value * (BPS - LP_BPS - SEED_BPS)) / BPS;
        lpReserve += msg.value - seed - teamCut;
        seedReserve += seed;
        teamReserve += teamCut;

        _safeMint(msg.sender, id);
        emit Minted(id, msg.sender);
    }

    /// @inheritdoc INFTCollection
    function rarityOf(uint256 tokenId) public view override returns (uint8) {
        if (_ownerOf(tokenId) == address(0)) revert NoToken();
        require(revealRound != 0, "not revealed"); // sealed until finalizeLaunch sets the reveal round
        bytes32 beacon = drand.randomness(revealRound); // reverts until that round's beacon is posted
        uint256 roll = uint256(keccak256(abi.encodePacked(beacon, tokenId, "nft"))) % BPS;
        if (roll < 200) return SUPER_RARE; // 2%
        if (roll < 1000) return RARE; // 8%
        if (roll < 3000) return UNCOMMON; // 20%
        return COMMON; // 70%
    }

    // ─── launch ──────────────────────────────────────────────────────────────

    /// @notice Seal ALL rarities to ONE future, time-locked round and close the launch. Deliberately moves
    ///         NO ETH (audit H-13): the reveal — and therefore rarityOf and holder free-entries — can never
    ///         be blocked by a reverting payout recipient. Proceeds are pulled separately via withdrawProceeds.
    /// @dev    The round is unknowable during the mint (it didn't exist yet), revealed revealDelay later;
    ///         one beacon reveals the whole collection (BLS keeper efficiency, the audit #4 fix under a
    ///         time-locked oracle).
    function finalizeLaunch() external onlyOwner nonReentrant {
        if (launched) revert AlreadyLaunched();
        if (lpTreasury == address(0) || seedTreasury == address(0) || team == address(0)) {
            revert RecipientsUnset();
        }
        launched = true;
        revealRound = drand.roundAt(block.timestamp + revealDelay);
        emit Launched(lpReserve, seedReserve, teamReserve);
    }

    /// @notice Disburse the three launch buckets to their (frozen) recipients — each INDEPENDENTLY (audit
    ///         H-13): a recipient that reverts leaves only its own bucket for a later retry and never blocks
    ///         the others or the reveal. Permissionless once launched; destinations are fixed.
    function withdrawProceeds() external nonReentrant {
        if (!launched) revert NotLaunched();
        uint256 lp = lpReserve;
        if (lp > 0) {
            lpReserve = 0;
            (bool ok,) = lpTreasury.call{ value: lp }("");
            if (!ok) lpReserve = lp; // restore for retry; other buckets still flow
        }
        uint256 seed = seedReserve;
        if (seed > 0) {
            seedReserve = 0;
            (bool ok,) = seedTreasury.call{ value: seed }("");
            if (!ok) seedReserve = seed;
        }
        uint256 t = teamReserve;
        if (t > 0) {
            teamReserve = 0;
            (bool ok,) = team.call{ value: t }("");
            if (!ok) teamReserve = t;
        }
    }

    // INFTCollection.ownerOf/balanceOf are inherited from ERC721.
    function ownerOf(uint256 tokenId) public view override(ERC721, INFTCollection) returns (address) {
        return super.ownerOf(tokenId);
    }

    function balanceOf(address owner) public view override(ERC721, INFTCollection) returns (uint256) {
        return super.balanceOf(owner);
    }

    function _baseURI() internal view override returns (string memory) {
        return _base;
    }
}
