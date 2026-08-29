// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { ISwapAdapter } from "../interfaces/ISwapAdapter.sol";
import {
    IPoolManager,
    IUnlockCallback,
    PoolKey,
    Currency,
    BalanceDelta,
    BalanceDeltaLib
} from "../interfaces/IPoolManager.sol";

/// @title  QpullWethAdapter — production QPULL→WETH adapter (first convert() leg, spec §3)
/// @notice RH's DEX is Uniswap V4, so this swaps QPULL for WETH by talking to the V4 PoolManager
///         directly (unlock → swap → settle QPULL in → take WETH out). It does NOT use the QUOTRON
///         "Canonical ETH router", which is hard-wired to the QUOTRON pool and hook-gated. The QPULL/WETH
///         pool is created at launch; its `PoolKey` (sorted currencies, fee, tickSpacing, hook) is set
///         once via `setPoolKey`. `minOut` is the off-chain slippage floor — enforced here after the swap.
/// @dev    Launch the QPULL pool with a permissive/absent hook so this direct-core swap is allowed. The
///         PoolManager address is immutable; the PoolKey is the only launch-time binding (data, not code).
contract QpullWethAdapter is ISwapAdapter, IUnlockCallback, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using BalanceDeltaLib for BalanceDelta;

    // V4 price-limit sentinels: swapping to the extreme means "no limit, take what the pool gives".
    uint160 internal constant MIN_SQRT_PRICE_P1 = 4_295_128_739 + 1;
    uint160 internal constant MAX_SQRT_PRICE_M1 =
        1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342 - 1;

    IPoolManager public immutable poolManager;
    address public immutable qpull;
    address public immutable weth;

    PoolKey public poolKey; // the QPULL/WETH pool — set at launch, once it exists
    bool public poolKeySet;

    event PoolKeySet(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks);

    error UnsupportedPath();
    error MinOutRequired();
    error PoolKeyUnset();
    error NotPoolManager();
    error Slippage();

    constructor(address poolManager_, address qpull_, address weth_, address initialOwner)
        Ownable(initialOwner)
    {
        poolManager = IPoolManager(poolManager_);
        qpull = qpull_;
        weth = weth_;
    }

    /// @notice Bind the QPULL/WETH pool once it exists at launch. currency0/currency1 must be the
    ///         address-sorted (QPULL, WETH) pair, exactly as the pool was initialized.
    function setPoolKey(PoolKey calldata k) external onlyOwner {
        poolKey = k;
        poolKeySet = true;
        emit PoolKeySet(
            Currency.unwrap(k.currency0), Currency.unwrap(k.currency1), k.fee, k.tickSpacing, k.hooks
        );
    }

    /// @inheritdoc ISwapAdapter
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        external
        override
        nonReentrant
        returns (uint256 amountOut)
    {
        if (tokenIn != qpull || tokenOut != weth) revert UnsupportedPath();
        if (minOut == 0) revert MinOutRequired(); // never swap unguarded
        if (!poolKeySet) revert PoolKeyUnset();

        IERC20(qpull).safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = abi.decode(poolManager.unlock(abi.encode(amountIn, to)), (uint256));
        if (amountOut < minOut) revert Slippage();
    }

    /// @notice V4 unlock callback — the only place swap/settle/take are legal.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (uint256 amountIn, address to) = abi.decode(data, (uint256, address));

        bool zeroForOne = Currency.unwrap(poolKey.currency0) == qpull; // is QPULL currency0?
        BalanceDelta delta = poolManager.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn), // exact input
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_P1 : MAX_SQRT_PRICE_M1
            }),
            ""
        );

        // Pay QPULL in: sync, transfer, settle.
        poolManager.sync(Currency.wrap(qpull));
        IERC20(qpull).safeTransfer(address(poolManager), amountIn);
        poolManager.settle();

        // Take WETH out (the positive side of the delta).
        int128 out128 = zeroForOne ? delta.amount1() : delta.amount0();
        uint256 out = uint256(uint128(out128));
        poolManager.take(Currency.wrap(weth), to, out);

        return abi.encode(out);
    }

    /// @inheritdoc ISwapAdapter
    /// @dev Quoting is off-chain (compute minOut from the canonical quoter, pass it to swapExactIn).
    function quote(address, address, uint256) external pure override returns (uint256) {
        revert("quote off-chain: pass minOut to swapExactIn");
    }
}
