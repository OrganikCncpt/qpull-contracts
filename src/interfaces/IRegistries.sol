// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Buys mint raffle tickets on the fixed whole-ticket schedule (spec §4).
///         `grossValue` is the WETH-in (ETH-side) amount of the buy in wei — the hook's `grossWeth`, the
///         ETH going INTO the swap, NOT the QPULL received. PackRegistry prices tickets in WETH
///         (`ticketPrice`), so tickets = grossValue / ticketPrice: oracle-free, independent of pool depth /
///         slippage, and immune to the spot-price flash-manipulation a value oracle would invite.
interface IPackRegistry {
    function recordBuy(address buyer, uint256 grossValue) external;
}

/// @notice Buys accrue leaderboard points for the current weekly period (spec §11). Non-winning ripped
///         packs also accrue points, rarity-weighted, via recordXp (called by PackRegistry.claimRipXp).
///         `grossValue` is the same WETH-in amount the hook passes to IPackRegistry.recordBuy.
interface ILeaderboardRegistry {
    function recordBuy(address buyer, uint256 grossValue) external;
    function recordXp(address who, uint256 amount) external;
}
