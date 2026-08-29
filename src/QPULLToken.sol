// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IPackRegistry, IJackpotRegistry, ILeaderboardRegistry } from "./interfaces/IRegistries.sol";
import { INFTCollection } from "./interfaces/INFTCollection.sol";

/// @title  QPULLToken
/// @notice ERC-20 with a fixed 4% buy / 4% sell tax (spec §2). Tax is taken in QPULL and routed
///         to the Treasury; the Treasury batches conversion to QUOTRON (spec §3). On every taxed
///         trade the token notifies the game registries:
///           - buy  -> raffle tickets (PackRegistry) + leaderboard points + jackpot entry
///           - sell -> jackpot entry only
///         (Spec §4: buys-only tickets & points. §10: jackpot entries on both sides.)
/// @dev    Tax rates are immutable constants — no owner can raise or weaponize them. The only
///         owner powers are launch wiring (treasury, registries, AMM pairs, exemptions), intended
///         to be set once and then have ownership renounced.
contract QPULLToken is ERC20, Ownable2Step {
    // ─── taxes (immutable) ───────────────────────────────────────────────────
    uint256 public constant BUY_TAX_BPS = 400; // 4%
    uint256 public constant SELL_TAX_BPS = 400; // 4%
    uint256 internal constant BPS = 10_000;

    // ─── wiring ──────────────────────────────────────────────────────────────
    address public treasury;
    IPackRegistry public packRegistry;
    IJackpotRegistry public jackpotRegistry;
    ILeaderboardRegistry public leaderboardRegistry;

    mapping(address => bool) public isAmm; // QPULL trading pools: buy = from AMM, sell = to AMM
    mapping(address => bool) public isTaxExempt; // treasury, this contract, owner, routers

    bool public hooksLive; // once true, registry hooks fire on trades (flip at launch)
    bool private _hooking; // reentrancy guard for the hook fan-out

    // ─── first-hour launch gate (spec §16) ───────────────────────────────────
    INFTCollection public nft; // only NFT holders may buy in the first hour
    uint256 public launchTime; // stamped when hooks go live
    uint256 public constant GATE_DURATION = 1 hours;

    // ─── events ──────────────────────────────────────────────────────────────
    event TreasurySet(address indexed treasury);
    event RegistriesSet(address pack, address jackpot, address leaderboard);
    event AmmSet(address indexed pair, bool isPair);
    event TaxExemptSet(address indexed account, bool exempt);
    event HooksLive(bool live);
    event NftSet(address nft);
    event TaxTaken(address indexed trader, bool isBuy, uint256 grossAmount, uint256 tax);

    error ZeroAddress();
    error Gated();

    constructor(uint256 initialSupply, address initialOwner) ERC20("QPULL", "QPULL") Ownable(initialOwner) {
        isTaxExempt[initialOwner] = true;
        isTaxExempt[address(this)] = true;
        _mint(initialOwner, initialSupply);
    }

    // ─── launch wiring (owner, then renounce) ────────────────────────────────

    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
        isTaxExempt[t] = true;
        emit TreasurySet(t);
    }

    function setRegistries(address pack, address jackpot, address leaderboard) external onlyOwner {
        if (pack == address(0) || jackpot == address(0) || leaderboard == address(0)) revert ZeroAddress();
        packRegistry = IPackRegistry(pack);
        jackpotRegistry = IJackpotRegistry(jackpot);
        leaderboardRegistry = ILeaderboardRegistry(leaderboard);
        emit RegistriesSet(pack, jackpot, leaderboard);
    }

    function setAmm(address pair, bool v) external onlyOwner {
        if (pair == address(0)) revert ZeroAddress();
        isAmm[pair] = v;
        emit AmmSet(pair, v);
    }

    function setTaxExempt(address a, bool v) external onlyOwner {
        isTaxExempt[a] = v;
        emit TaxExemptSet(a, v);
    }

    function setHooksLive(bool v) external onlyOwner {
        hooksLive = v;
        if (v && launchTime == 0) launchTime = block.timestamp; // opens the first-hour gate window
        emit HooksLive(v);
    }

    function setNft(address n) external onlyOwner {
        nft = INFTCollection(n);
        emit NftSet(n);
    }

    // ─── transfer hook: tax + game notifications ─────────────────────────────

    function _update(address from, address to, uint256 value) internal override {
        bool buy = isAmm[from] && !isTaxExempt[to];
        bool sell = isAmm[to] && !isTaxExempt[from];

        // First-hour launch gate (spec §16): only NFT holders may buy. Self-expires; anti-snipe.
        if (
            buy && address(nft) != address(0) && launchTime != 0
                && block.timestamp < launchTime + GATE_DURATION && nft.balanceOf(to) == 0
        ) {
            revert Gated();
        }

        // Non-trade transfers (wallet<->wallet, mint, burn) pass through untaxed.
        if (!buy && !sell) {
            super._update(from, to, value);
            return;
        }

        // Tax only applies once treasury is wired; pre-launch trades are untaxed by construction.
        uint256 tax;
        if (treasury != address(0)) {
            tax = (value * (buy ? BUY_TAX_BPS : SELL_TAX_BPS)) / BPS;
        }
        if (tax > 0) {
            super._update(from, treasury, tax);
        }
        super._update(from, to, value - tax);

        emit TaxTaken(buy ? to : from, buy, value, tax);

        // Game hooks. `value` is the GROSS trade size (spec §4 "gross buy").
        // Guarded against re-entry; registries are trusted, minimal, storage-only.
        if (hooksLive && !_hooking) {
            _hooking = true;
            if (buy) {
                packRegistry.recordBuy(to, value);
                leaderboardRegistry.recordBuy(to, value);
                jackpotRegistry.recordTrade(to, value);
            } else {
                jackpotRegistry.recordTrade(from, value);
            }
            _hooking = false;
        }
    }
}
