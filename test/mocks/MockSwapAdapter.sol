// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ISwapAdapter } from "../../src/interfaces/ISwapAdapter.sol";
import { MockERC20 } from "./MockERC20.sol";

/// @notice Test adapter: pulls tokenIn and mints tokenOut. `quoteRate` drives quote(); `fillRate`
///         drives the actual delivery — set fillRate < quoteRate to simulate slippage/under-fill.
///         Rates scaled 1e18 (1e18 = 1:1). Stands in for the real DEX adapter (§13.1).
contract MockSwapAdapter is ISwapAdapter {
    uint256 public quoteRate;
    uint256 public fillRate;

    constructor(uint256 quoteRate_, uint256 fillRate_) {
        quoteRate = quoteRate_;
        fillRate = fillRate_;
    }

    function quote(address, address, uint256 amountIn) external view returns (uint256) {
        return (amountIn * quoteRate) / 1e18;
    }

    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 amountOut)
    {
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        amountOut = (amountIn * fillRate) / 1e18;
        require(amountOut >= minOut, "slippage");
        MockERC20(tokenOut).mint(to, amountOut);
    }
}
