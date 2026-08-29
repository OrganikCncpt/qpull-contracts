// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Buys mint raffle tickets on the fixed whole-ticket schedule (spec §4).
///         `grossValue` is the gross QPULL amount of the buy (token-denominated issuance —
///         oracle-free, and immune to the spot-price flash-manipulation a value oracle would invite).
interface IPackRegistry {
    function recordBuy(address buyer, uint256 grossValue) external;
}

/// @notice Both buys and sells mint pari-mutuel jackpot entries, ∝ trade size (spec §10).
interface IJackpotRegistry {
    function recordTrade(address trader, uint256 grossValue) external;
}

/// @notice Buys accrue leaderboard points for the current weekly period (spec §11).
interface ILeaderboardRegistry {
    function recordBuy(address buyer, uint256 grossValue) external;
}
