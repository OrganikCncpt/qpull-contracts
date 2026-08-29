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
    uint256 public deadlineBuffer = 15 minutes;

    event DeadlineBufferSet(uint256 seconds_);

    error UnsupportedPath();
    error MinOutRequired();

    constructor(address router_, address weth_, address quotron_, address initialOwner)
        Ownable(initialOwner)
    {
        router = IQuotronRouter(router_);
        weth = weth_;
        quotron = quotron_;
    }

    function setDeadlineBuffer(uint256 s) external onlyOwner {
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
        if (tokenIn != weth || tokenOut != quotron) revert UnsupportedPath();
        if (minOut == 0) revert MinOutRequired(); // the router rejects minOut==0 (InvalidAmount) — always set a floor
        IERC20(weth).safeTransferFrom(msg.sender, address(this), amountIn);
        IWETH(weth).withdraw(amountIn); // WETH → native ETH
        amountOut = router.buyExactEth{ value: amountIn }(minOut, to, block.timestamp + deadlineBuffer);
    }

    /// @inheritdoc ISwapAdapter
    /// @dev Quoting is done OFF-CHAIN (compute minOut from the canonical View quoter and pass it to
    ///      swapExactIn). This avoids relying on an on-chain quoter that can be manipulated within a
    ///      block. Reverts to make the off-chain expectation explicit.
    function quote(address, address, uint256) external pure override returns (uint256) {
        revert("quote off-chain: pass minOut to swapExactIn");
    }

    receive() external payable { } // ETH from WETH.withdraw
}
