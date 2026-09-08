// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    IPoolManager,
    IUnlockCallback,
    PoolKey,
    Currency,
    BalanceDelta,
    BalanceDeltaLib
} from "./interfaces/IPoolManager.sol";

/// @title  QpullLiquidityLock
/// @notice A PERMANENT, one-way liquidity lock for the QuoPull canonical QPULL/WETH pool. The launch
///         liquidity (the fair-launch supply + its paired WETH) is added to a single full-range position
///         owned by THIS contract, exactly once, and can then NEVER be removed.
///
/// @dev    THE GUARANTEE IS THE ABSENCE OF CODE, NOT A GATE. In Uniswap v4 a position is owned by the
///         address that called `modifyLiquidity` to create it (this contract). Only that owner can ever
///         modify or remove it. This contract:
///           - adds liquidity EXACTLY ONCE (`seed`, opener-only, latched), and
///           - contains NO function that removes, withdraws, collects, or otherwise reduces the position
///             (no negative `liquidityDelta`, no fee-collect, no token sweep-out, no owner, no setter, no
///             delegatecall, no selfdestruct).
///         Therefore no transaction can ever pull the liquidity: removal is not restricted, it does not
///         exist in the bytecode. Anyone can verify this by reading this (small, immutable) contract.
///
///         LP fees (the pool's 0.30% Uniswap fee, distinct from the protocol's 4% trade tax) accrue to
///         this locked position and are DELIBERATELY never collected: there is no collect path, so they
///         stay with the locked position forever. The 4% trade tax funds the prize games separately.
///
///         The pool itself is created by the deployer (the hook gates `initialize` to its `initializer`);
///         this lock only provides the liquidity. The hook's LP gate admits this add because the opener
///         (the initializer EOA) is `tx.origin` when it calls `seed`. None of that affects the guarantee
///         above, which rests solely on this contract owning the position and never exposing a removal.
contract QpullLiquidityLock is IUnlockCallback {
    using BalanceDeltaLib for BalanceDelta;
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    address public immutable qpull;
    address public immutable weth;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    address public immutable hook;
    address public immutable opener; // the ONLY address allowed to trigger the one-time seed
    int24 public immutable tickLower; // full range, aligned to tickSpacing
    int24 public immutable tickUpper;
    bool internal immutable qpullIs0; // address-sort order of the canonical pair

    bool public seeded; // one-shot latch: true after `seed`, so it can never run twice

    event Seeded(uint128 liquidity, int24 tickLower, int24 tickUpper);

    error NotOpener();
    error AlreadySeeded();
    error NotPoolManager();
    error ZeroAddress();
    error ZeroLiquidity();

    constructor(
        IPoolManager poolManager_,
        address qpull_,
        address weth_,
        uint24 fee_,
        int24 tickSpacing_,
        address hook_,
        address opener_
    ) {
        if (
            address(poolManager_) == address(0) || qpull_ == address(0) || weth_ == address(0)
                || hook_ == address(0) || opener_ == address(0)
        ) revert ZeroAddress();
        poolManager = poolManager_;
        qpull = qpull_;
        weth = weth_;
        fee = fee_;
        tickSpacing = tickSpacing_;
        hook = hook_;
        opener = opener_;
        qpullIs0 = qpull_ < weth_;
        // Widest range aligned to tickSpacing (the v4 usable-tick bound is 887272).
        int24 maxUsable = int24((int256(887_272) / int256(tickSpacing_)) * int256(tickSpacing_));
        tickLower = -maxUsable;
        tickUpper = maxUsable;
    }

    /// @notice The canonical pool key this lock serves (currencies sorted, carrying the tax hook).
    function poolKey() public view returns (PoolKey memory) {
        (address c0, address c1) = qpullIs0 ? (qpull, weth) : (weth, qpull);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hook
        });
    }

    /// @notice Add the launch liquidity to the pool, ONCE, and lock it forever. The pool must already be
    ///         initialized (by the deployer), and this contract must already hold the QPULL and WETH to
    ///         seed (transferred in by the opener). `liquidity` is sized off-chain to consume those
    ///         balances at the pool's price. After this call there is no remaining privileged action, and
    ///         nothing this contract holds (the position, its fees, or any residual token dust) can ever
    ///         leave. THIS IS THE ONLY STATE-CHANGING ENTRYPOINT.
    function seed(uint128 liquidity) external {
        if (msg.sender != opener) revert NotOpener();
        if (seeded) revert AlreadySeeded();
        if (liquidity == 0) revert ZeroLiquidity(); // no-op seed would latch and strand the pre-funded tokens
        seeded = true; // effects before interactions; permanent one-shot latch
        poolManager.unlock(abi.encode(liquidity)); // -> unlockCallback adds the liquidity
        emit Seeded(liquidity, tickLower, tickUpper);
    }

    /// @dev V4 unlock callback: add the liquidity and pay both currencies from this contract's balance.
    ///      ONLY the pool manager can call it, and it is reachable ONLY via `seed` (guarded above), so it
    ///      can never be driven to remove liquidity (liquidityDelta is always the positive `seed` amount).
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        uint128 liquidity = abi.decode(data, (uint128));
        PoolKey memory key = poolKey();
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(tickLower, tickUpper, int256(uint256(liquidity)), bytes32(0)),
            ""
        );
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    /// @dev Pay the pool manager what the add owes (delta < 0). The `amt > 0` branch (manager owes us)
    ///      cannot occur on a pure add, but is handled defensively by taking it back into this locked
    ///      contract (it stays locked here; there is still no path out).
    function _settle(Currency c, int128 amt) internal {
        if (amt < 0) {
            poolManager.sync(c);
            IERC20(Currency.unwrap(c)).safeTransfer(address(poolManager), uint256(uint128(-amt)));
            poolManager.settle();
        } else if (amt > 0) {
            poolManager.take(c, address(this), uint256(uint128(amt)));
        }
    }
}
