// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ISwapAdapter
/// @notice Abstracts a single exact-in swap so the DEX specifics (Uniswap v4 unlock/settle,
///         a v2-style router, whatever RH exposes) live in a deploy-time adapter, not in the
///         Treasury. The Treasury uses this for QPULL->WETH and WETH->QUOTRON conversions (§3).
/// @dev    The concrete adapter for the QUOTRON/WETH leg is gated by §13.1 (pool-side vs
///         router-gated). Either way it implements this interface.
interface ISwapAdapter {
    /// @param tokenIn   asset sold
    /// @param tokenOut  asset bought
    /// @param amountIn  exact input amount (adapter pulls it from msg.sender)
    /// @param minOut    slippage floor; adapter MUST revert if the output is below this
    /// @param to        recipient of tokenOut
    /// @return amountOut delivered to `to`
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 amountOut);

    /// @notice A slippage-reference quote for `amountIn` (spot/last, adapter-defined).
    /// @dev    Used only to derive `minOut`; not a security boundary on its own.
    function quote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256);
}
