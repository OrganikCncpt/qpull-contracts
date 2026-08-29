// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ISwapAdapter } from "./interfaces/ISwapAdapter.sol";

/// @title  Treasury
/// @notice Receives the 4% trade tax from QpullTaxHook — in QPULL (buys) AND WETH (exact-in sells,
///         audit H-2) — and, on a batched `convert()`, turns it into prize inventory: QPULL → WETH
///         (via adapter), team takes 20% of all WETH, the remaining 80% → QUOTRON and is split to
///         the three prize vaults (spec §3). Batching keeps Quotron's 3% hook fee (§9) off every
///         trade — it is paid once per conversion.
///
/// @dev    Split, in bps of total tax: raffle 6125 / jackpot 625 / leaderboard 1250 / team 2000.
///         Swaps route through ISwapAdapter with slippage bounds, keeper-gated (see convert()).
///         The QpullWethAdapter is fee-exempt on the hook (exemptSender), so the protocol-side
///         QPULL→WETH conversion swap is itself untaxed.
contract Treasury is Ownable2Step, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    IERC20 public immutable qpull;
    IERC20 public immutable weth;
    IERC20 public immutable quotron;

    uint256 internal constant BPS = 10_000;
    uint256 public constant TEAM_BPS = 2000; // 20% of tax
    uint256 public constant HOURLY_BPS = 6125; // 61.25% (daily raffle)
    uint256 public constant JACKPOT_BPS = 625; // 6.25%
    uint256 public constant LEADERBOARD_BPS = 1250; // 12.5% (doubled from 6.25%)
    uint256 internal constant PRIZE_BPS = HOURLY_BPS + JACKPOT_BPS + LEADERBOARD_BPS; // 8000

    ISwapAdapter public qpullWeth; // QPULL -> WETH
    ISwapAdapter public wethQuotron; // WETH -> QUOTRON
    address public prizeVault;
    address public jackpotVault;
    address public leaderboardVault;
    address public team;

    uint256 public convertThreshold; // min QPULL balance before convert() proceeds
    // Max QPULL swapped per convert() call. Default uncapped; the owner sets a pool-sized ceiling at launch so
    // an untaxed donation that inflates the balance beyond pool depth can't permanently brick convert() — the
    // keeper just drains the excess over several pool-sized slices (audit H-3). Excess stays as QPULL balance.
    uint256 public maxConvertPerCall = type(uint256).max;
    mapping(address => bool) public isKeeper; // only an authorized keeper may trigger convert()

    event AdaptersSet(address qpullWeth, address wethQuotron);
    event RoutingSet(address prizeVault, address jackpotVault, address leaderboardVault, address team);
    event ConvertThresholdSet(uint256 convertThreshold);
    event MaxConvertPerCallSet(uint256 maxConvertPerCall);
    event KeeperSet(address indexed keeper, bool authorized);
    event Converted(uint256 qpullIn, uint256 wethOut, uint256 quotronOut, uint256 teamWeth);

    error NotConfigured();
    error BelowThreshold();
    error NotKeeper();
    error SwapShortfall();

    modifier onlyKeeper() {
        if (!isKeeper[msg.sender]) revert NotKeeper();
        _;
    }

    constructor(address qpull_, address weth_, address quotron_, address initialOwner) Ownable(initialOwner) {
        qpull = IERC20(qpull_);
        weth = IERC20(weth_);
        quotron = IERC20(quotron_);
    }

    /// @notice Authorize/deauthorize a keeper allowed to call convert(). Gating convert() is the fix for
    ///         the audit finding that a permissionless convert() with a caller-supplied slippage floor is
    ///         sandwichable — only a trusted keeper that computes a tight off-chain minOut may trigger it.
    function setKeeper(address k, bool v) external onlyOwner {
        isKeeper[k] = v;
        emit KeeperSet(k, v);
    }

    function setAdapters(address qpullWeth_, address wethQuotron_) external onlyOwner {
        qpullWeth = ISwapAdapter(qpullWeth_);
        wethQuotron = ISwapAdapter(wethQuotron_);
        emit AdaptersSet(qpullWeth_, wethQuotron_);
    }

    function setRouting(address prize_, address jackpot_, address leaderboard_, address team_)
        external
        onlyOwner
    {
        if (
            prize_ == address(0) || jackpot_ == address(0) || leaderboard_ == address(0)
                || team_ == address(0)
        ) {
            revert NotConfigured(); // audit M-1: no zero routing destinations
        }
        prizeVault = prize_;
        jackpotVault = jackpot_;
        leaderboardVault = leaderboard_;
        team = team_;
        emit RoutingSet(prize_, jackpot_, leaderboard_, team_);
    }

    function setConvertThreshold(uint256 t) external onlyOwner {
        convertThreshold = t;
        emit ConvertThresholdSet(t);
    }

    /// @notice Ceiling on QPULL swapped per convert() call (audit H-3). Lets the keeper drain a donation-
    ///         inflated balance in pool-sized slices instead of bricking on a single oversized swap.
    function setMaxConvertPerCall(uint256 m) external onlyOwner {
        if (m == 0) revert BelowThreshold();
        maxConvertPerCall = m;
        emit MaxConvertPerCallSet(m);
    }

    /// @notice Batch-convert accumulated QPULL tax into prize inventory + team WETH. KEEPER-ONLY.
    /// @param  minWethOut     slippage floor for QPULL→WETH, computed OFF-CHAIN by the keeper
    /// @param  minQuotronOut  slippage floor for WETH→QUOTRON, computed OFF-CHAIN
    /// @dev    Keeper-gated (onlyKeeper): the off-chain slippage floors are only trustworthy from a keeper
    ///         that computes them tightly. A permissionless convert() would let an adversary pass a nominal
    ///         floor (minOut=1) and sandwich the whole batch through the shallow pool — the audit finding
    ///         this gate closes. The keeper account should be a bot key the team controls (rotatable).
    function convert(uint256 minWethOut, uint256 minQuotronOut) external nonReentrant onlyKeeper {
        if (
            address(qpullWeth) == address(0) || address(wethQuotron) == address(0) || prizeVault == address(0)
                || jackpotVault == address(0) || leaderboardVault == address(0) || team == address(0)
        ) revert NotConfigured(); // audit M-1: jackpot/leaderboard vaults are unconditional transfer targets

        // Tax arrives in TWO currencies since the V4 hook (audit H-2): buys pay QPULL, exact-in sells
        // pay WETH — QpullTaxHook take()s both straight to this Treasury. QPULL converts via leg 1;
        // WETH already held merges into the flow after it.
        uint256 qpullBal = qpull.balanceOf(address(this));
        uint256 wethHeld = weth.balanceOf(address(this));
        // Gate on the RAW balance, THEN cap the slice. convertThreshold is a MIN-BATCH gate ("enough tax
        // accumulated to amortize the swap"); maxConvertPerCall is a MAX-SLICE safety ("don't swap more
        // than pool depth per call", audit H-3). These are independent — testing the threshold against
        // the already-capped slice would let any config with maxConvertPerCall < convertThreshold strand
        // the QPULL leg forever (H-2 review, hardened): the slice can never reach the threshold, so the
        // QPULL→WETH conversion never runs even with a huge balance.
        bool qpullLeg = qpullBal > 0 && qpullBal >= convertThreshold;
        uint256 qpullIn = qpullBal > maxConvertPerCall ? maxConvertPerCall : qpullBal; // pool-sized slice
        // Sub-threshold QPULL waits for more tax; a WETH-only sweep is always allowed (threshold is an
        // anti-dust backstop for the QPULL swap leg, and convert() is keeper-gated anyway).
        if (!qpullLeg && wethHeld == 0) revert BelowThreshold();

        // 1. QPULL -> WETH. Trust the MEASURED balance delta, not the adapter's return value (audit H-14):
        //    a malicious/buggy adapter could take the approved QPULL and return a fabricated number.
        if (qpullLeg) {
            uint256 wethBefore = weth.balanceOf(address(this));
            qpull.forceApprove(address(qpullWeth), qpullIn);
            qpullWeth.swapExactIn(address(qpull), address(weth), qpullIn, minWethOut, address(this));
            if (weth.balanceOf(address(this)) - wethBefore < minWethOut) revert SwapShortfall();
        } else {
            qpullIn = 0; // nothing swapped this call
        }

        // 2. team slice — 20% of ALL tax revenue this batch, whichever currency it arrived in
        uint256 wethOut = weth.balanceOf(address(this)); // swapped + hook-fee WETH; all of it is tax
        uint256 teamWeth = (wethOut * TEAM_BPS) / BPS;
        weth.safeTransfer(team, teamWeth);
        uint256 prizeWeth = wethOut - teamWeth;

        // 3. prize WETH -> QUOTRON — measured delta again (audit H-14)
        uint256 qBefore = quotron.balanceOf(address(this));
        weth.forceApprove(address(wethQuotron), prizeWeth);
        wethQuotron.swapExactIn(address(weth), address(quotron), prizeWeth, minQuotronOut, address(this));
        uint256 qOut = quotron.balanceOf(address(this)) - qBefore;
        if (qOut < minQuotronOut) revert SwapShortfall();

        // 4. split QUOTRON across the prize vaults (of the 8000 prize bps)
        uint256 toJackpot = (qOut * JACKPOT_BPS) / PRIZE_BPS;
        uint256 toLeaderboard = (qOut * LEADERBOARD_BPS) / PRIZE_BPS;
        uint256 toHourly = qOut - toJackpot - toLeaderboard;
        quotron.safeTransfer(prizeVault, toHourly);
        quotron.safeTransfer(jackpotVault, toJackpot);
        quotron.safeTransfer(leaderboardVault, toLeaderboard);

        emit Converted(qpullIn, wethOut, qOut, teamWeth);
    }

    /// @notice ERC-404 terminal-mint safety (§13.3), defense-in-depth. A convert() batch that buys ≥1
    ///         whole QUOTRON unit crosses a whole-unit boundary on receipt. test/fork/QuotronWholeUnitFork
    ///         shows real QUOTRON does NOT fire a receiver callback on a plain contract (it appears to
    ///         auto-exempt contracts from the NFT side), so convert() is safe without this. We implement
    ///         it anyway — zero cost, uniform with the vaults, and a hedge if that exemption ever changes.
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }
}
