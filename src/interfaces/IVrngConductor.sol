// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IVrngConductor
/// @notice Minimal interface to Robinhood Chain's DERP randomness conductor (VRNG). Request → the
///         certified prints land → fulfill → read the word. Commit-first: the word is derived from
///         prints that publish AFTER the request, so it is unknowable at request time.
interface IVrngConductor {
    function requestFee() external view returns (uint256);
    /// @param prints number of certified entropy prints to combine
    /// @param salt caller domain-separation salt (committed with the request)
    function request(uint256 prints, bytes32 salt) external payable returns (uint256 id);
    function fulfill(uint256 id) external;
    function isReady(uint256 id) external view returns (bool);
    function wordOf(uint256 id) external view returns (bytes32);
}
