// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ISwapAdapter } from "../interfaces/ISwapAdapter.sol";
import { IQuotronRouter, IWETH } from "../interfaces/IQuotronRouter.sol";

/// @title  QuotronRouterAdapter — production WETH→QUOTRON adapter
/// @notice The concrete `ISwapAdapter` for the QUOTRON leg (spec §13.1: router-gated). Pulls WETH,
///         unwraps to native ETH, and buys QUOTRON through Quotron's Canonical ETH router (the 3%
///         fee hook charges automatically). `minOut` is supplied by the caller (the Treasury computes
///         it off-chain — a standard MEV/slippage guard that needs no on-chain quoter).
/// @dev    Only the WETH→QUOTRON path is supported; the QPULL→WETH leg uses a separate adapter for
///         QPULL's own pool (created at launch).
contract QuotronRouterAdapter is ISwapAdapter, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IQuotronRouter public immutable router;
    address public immutable weth;
    address public immutable quotron;
    address public treasury; // the ONLY authorized caller of swapExactIn (audit H-1)
    uint256 public deadlineBuffer = 15 minutes;
    uint256 internal constant MAX_DEADLINE_BUFFER = 1 hours; // bound (audit L-7)

    event DeadlineBufferSet(uint256 seconds_);
    event TreasurySet(address treasury);
    event SweptETH(address indexed to, uint256 amount);
    event RefundForwarded(address indexed to, uint256 amount); // pre-audit: unexpected router refund recaptured

    error UnsupportedPath();
    error MinOutRequired();
    error NotTreasury();
    error Slippage();
    error BadBuffer();
    error TreasuryAlreadySet(); // audit F5 (pass-5)
    error ZeroAddress();
    error SweepFailed();

    constructor(address router_, address weth_, address quotron_, address initialOwner)
        Ownable(initialOwner)
    {
        router = IQuotronRouter(router_);
        weth = weth_;
        quotron = quotron_;
    }

    /// @notice Authorize the Treasury as the sole caller of swapExactIn (audit H-1). WRITE-ONCE
    ///         (audit F5, pass-5): re-pointing `treasury` would DoS convert(); mirrors the write-once
    ///         intent the comment always stated. Until set, swapExactIn is closed (fail-safe).
    function setTreasury(address t) external onlyOwner {
        if (treasury != address(0)) revert TreasuryAlreadySet();
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
        emit TreasurySet(t);
    }

    /// @notice Owner-only rescue for native ETH stranded in this adapter (audit F7, pass-5). In normal
    ///         operation the adapter holds no ETH (WETH is unwrapped and forwarded to the router in the
    ///         same tx); this recovers force-sent ETH. A router refund no longer strands here — swapExactIn
    ///         re-wraps and forwards it to the Treasury in the same call (pre-audit). Touches no
    ///         WETH/QUOTRON accounting — the adapter never holds those between calls.
    function sweepETH(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = address(this).balance;
        (bool ok,) = to.call{ value: bal }("");
        if (!ok) revert SweepFailed();
        emit SweptETH(to, bal);
    }

    function setDeadlineBuffer(uint256 s) external onlyOwner {
        if (s == 0 || s > MAX_DEADLINE_BUFFER) revert BadBuffer(); // audit L-7: no overflow / zero deadline
        deadlineBuffer = s;
        emit DeadlineBufferSet(s);
    }

    /// @inheritdoc ISwapAdapter
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external
        override
        nonReentrant
        returns (uint256 amountOut)
    {
        if (msg.sender != treasury) revert NotTreasury(); // audit H-1
        if (tokenIn != weth || tokenOut != quotron) revert UnsupportedPath();
        if (minOut == 0) revert MinOutRequired(); // the router rejects minOut==0 (InvalidAmount) — always set a floor
        IERC20(weth).safeTransferFrom(msg.sender, address(this), amountIn);
        // Snapshot BEFORE unwrapping so any pre-existing force-sent balance (sweepETH's domain) is not
        // mistaken for this call's refund.
        uint256 ethBefore = address(this).balance;
        IWETH(weth).withdraw(amountIn); // WETH → native ETH
        amountOut = router.buyExactEth{ value: amountIn }(minOut, to, block.timestamp + deadlineBuffer);
        if (amountOut < minOut) revert Slippage(); // audit M-3: enforce the floor locally, not only via the router
        // pre-audit (router ETH refund): buyExactEth is exact-ETH-in — the live router wraps the FULL msg.value
        // and settles it as the v4 exact-input amount (fork-verified, test/fork/QuotronSwapFork.t.sol), so a
        // refund is never expected. Should one ever arrive it lands on receive() below and, without this, would
        // strand here outside convert()'s QUOTRON-only shortfall check until an owner sweepETH. We RECAPTURE
        // rather than revert: `treasury` is write-once and Treasury.lockRouting() freezes the adapter binding,
        // so a revert-on-refund would turn any future dust refund into a PERMANENT convert() brick (no prize
        // funding, no fix path), whereas forwarding keeps convert() live and puts the value back into the
        // pipeline (it becomes next batch's wethHeld). The refund is re-wrapped to WETH because the Treasury
        // has no receive(); it goes to msg.sender (the Treasury, the only caller — audit H-1), never to `to`.
        // Bounded: the minOut floor above already caps how much of amountIn could come back unconverted.
        uint256 refund = address(this).balance - ethBefore; // >= 0: ETH only leaves via the value call above
        if (refund > 0) {
            IWETH(weth).deposit{ value: refund }();
            IERC20(weth).safeTransfer(msg.sender, refund);
            emit RefundForwarded(msg.sender, refund);
        }
    }

    /// @inheritdoc ISwapAdapter
    /// @dev Quoting is done OFF-CHAIN (compute minOut from the canonical View quoter and pass it to
    ///      swapExactIn). This avoids relying on an on-chain quoter that can be manipulated within a
    ///      block. Reverts to make the off-chain expectation explicit.
    function quote(address, address, uint256) external pure override returns (uint256) {
        revert("quote off-chain: pass minOut to swapExactIn");
    }

    receive() external payable { } // ETH from WETH.withdraw (and any router refund, forwarded in swapExactIn)
}
