// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IDrandOracle } from "../interfaces/IDrandOracle.sol";

/// @title  CommitteeDrandOracle
/// @notice The §13.2 FALLBACK oracle: an M-of-N relayer committee finalizes each drand beacon. A
///         beacon for a round is accepted only once `threshold` distinct relayers submit the SAME
///         value, so no single relayer can forge an outcome. Works with NO on-chain BLS precompile.
///
/// @dev    This is strictly weaker than on-chain BLS verification (it trusts that ≥ threshold
///         relayers won't collude), but far stronger than an operator-held secret — the whole reason
///         drand was chosen. If §13.2 confirms the EIP-2537 precompile, deploy BlsDrandOracle instead
///         (fully trustless) behind this same IDrandOracle interface — no other contract changes.
contract CommitteeDrandOracle is IDrandOracle, Ownable2Step {
    uint256 public immutable drandGenesis; // drand network genesis (seconds)
    uint256 public immutable drandPeriod; // drand round period (seconds)

    uint256 public threshold; // M
    uint256 public relayerCount; // N
    mapping(address => bool) public isRelayer;

    mapping(uint64 => bytes32) public finalized;
    mapping(uint64 => bool) public isFinal;
    mapping(uint64 => mapping(bytes32 => uint256)) public votes; // round => value => count
    mapping(uint64 => mapping(address => bool)) public voted; // round => relayer => voted

    event RelayerSet(address indexed relayer, bool authorized);
    event ThresholdSet(uint256 threshold);
    event Submitted(uint64 indexed round, bytes32 value, address indexed relayer, uint256 count);
    event Finalized(uint64 indexed round, bytes32 value);

    error NotRelayer();
    error AlreadyFinal();
    error AlreadyVoted();
    error BadThreshold();

    constructor(uint256 drandGenesis_, uint256 drandPeriod_, address initialOwner) Ownable(initialOwner) {
        drandGenesis = drandGenesis_;
        drandPeriod = drandPeriod_;
    }

    function setRelayer(address r, bool authorized) external onlyOwner {
        if (isRelayer[r] != authorized) {
            isRelayer[r] = authorized;
            relayerCount = authorized ? relayerCount + 1 : relayerCount - 1;
            emit RelayerSet(r, authorized);
        }
    }

    function setThreshold(uint256 m) external onlyOwner {
        if (m == 0 || m > relayerCount) revert BadThreshold();
        threshold = m;
        emit ThresholdSet(m);
    }

    /// @notice A relayer submits its view of `round`'s randomness. Finalizes on the M-th matching vote.
    function submit(uint64 round, bytes32 value) external {
        if (!isRelayer[msg.sender]) revert NotRelayer();
        if (isFinal[round]) revert AlreadyFinal();
        if (voted[round][msg.sender]) revert AlreadyVoted();
        voted[round][msg.sender] = true;
        uint256 c = votes[round][value] + 1;
        votes[round][value] = c;
        emit Submitted(round, value, msg.sender, c);
        if (c >= threshold) {
            finalized[round] = value;
            isFinal[round] = true;
            emit Finalized(round, value);
        }
    }

    /// @inheritdoc IDrandOracle
    function isAvailable(uint64 round) external view returns (bool) {
        return isFinal[round];
    }

    /// @inheritdoc IDrandOracle
    function randomness(uint64 round) external view returns (bytes32) {
        require(isFinal[round], "unavailable");
        return finalized[round];
    }

    /// @inheritdoc IDrandOracle
    function roundAt(uint256 timestamp) external view returns (uint64) {
        if (timestamp <= drandGenesis) return 1;
        // CEIL: first round publishing at/AFTER `timestamp` (see BlsDrandOracle for why floor is unsafe).
        return uint64((timestamp - drandGenesis + drandPeriod - 1) / drandPeriod) + 1;
    }
}
