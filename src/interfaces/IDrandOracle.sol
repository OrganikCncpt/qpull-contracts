// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IDrandOracle
/// @notice The randomness source for every game (raffle tiers, hourly draws, jackpot).
/// @dev    This interface is the seam that isolates the §13.2 unknown. Ship either:
///           - BlsDrandOracle    (if the EIP-2537 precompile is live on RH), or
///           - RelayerDrandOracle (permissionless relayer + on-chain challenge window).
///         Nothing downstream of randomness cares which one is deployed.
interface IDrandOracle {
    /// @return true once a verified beacon for `round` is stored.
    function isAvailable(uint64 round) external view returns (bool);

    /// @notice The verified 32-byte randomness for `round`.
    /// @dev    MUST revert if `round` is not yet available — callers rely on this to
    ///         enforce sealed-then-revealed (spec §6): a future round has no answer.
    function randomness(uint64 round) external view returns (bytes32);

    /// @notice The drand round whose scheduled publish time is the first at/after `timestamp`.
    /// @dev    Pure function of drand's genesis + period; used to bind a pack to a FUTURE round.
    function roundAt(uint256 timestamp) external view returns (uint64);
}
