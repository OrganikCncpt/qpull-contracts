// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IDrandOracle } from "../interfaces/IDrandOracle.sol";
import { IVrngConductor } from "../interfaces/IVrngConductor.sol";

/// @title  DerpOracle — Robinhood Chain native randomness (DERP/VRNG) behind IDrandOracle
/// @notice Bridges DERP's request→fulfill→word model onto the protocol's round model, so it drops
///         into the exact same IDrandOracle slot as BlsDrandOracle. The keeper requests one word per
///         round; DERP fills it from future certified prints; the protocol reads it like any beacon.
///
/// @dev    GRIND-PROOF BY CONSTRUCTION (no one can steer an outcome):
///         1. **One immutable word per round.** `requestRound` can be called once per round; the id
///            is frozen. Nobody can re-request to fish for a better word.
///         2. **Deterministic salt.** The request salt is `keccak(round)`, not caller-chosen — so a
///            keeper can't grind the salt against known prints.
///         3. **No pre-requesting the far future.** `requestRound` is bounded to the current/next
///            round, so a future round a pack is sealed against can't already be resolved.
///         4. **The keeper never picks the word.** DERP determines it from certified prints; fulfill
///            only lands the word DERP already decided.
///         The word's unpredictability at mint time comes from DERP's commit-first design.
contract DerpOracle is IDrandOracle, Ownable2Step {
    IVrngConductor public immutable conductor;
    uint256 public immutable genesis;
    uint256 public immutable period;
    uint256 public immutable prints;
    uint64 public constant MAX_AHEAD = 1; // request only the current or next round (sealing guard)

    mapping(uint64 => bool) public requested;
    mapping(uint64 => uint256) public requestIdOf;

    event RoundRequested(uint64 indexed round, uint256 id);

    error AlreadyRequested();
    error TooFarAhead();
    error NotRequested();

    constructor(address conductor_, uint256 genesis_, uint256 period_, uint256 prints_, address initialOwner)
        Ownable(initialOwner)
    {
        conductor = IVrngConductor(conductor_);
        genesis = genesis_;
        period = period_;
        prints = prints_;
    }

    /// @notice Fund the oracle with ETH to pay DERP request fees.
    receive() external payable { }

    function currentRound() public view returns (uint64) {
        if (block.timestamp <= genesis) return 1;
        return uint64((block.timestamp - genesis) / period) + 1;
    }

    /// @notice Permissionless: request the DERP word for `round` (once). Salt is deterministic.
    function requestRound(uint64 round) external returns (uint256 id) {
        if (requested[round]) revert AlreadyRequested();
        if (round > currentRound() + MAX_AHEAD) revert TooFarAhead();
        requested[round] = true; // effects before the external call
        id = conductor.request{ value: conductor.requestFee() }(prints, keccak256(abi.encode("QPULL", round)));
        requestIdOf[round] = id;
        emit RoundRequested(round, id);
    }

    /// @notice Permissionless: land the word once DERP's deciding print has published.
    function fulfillRound(uint64 round) external {
        if (!requested[round]) revert NotRequested();
        uint256 id = requestIdOf[round];
        if (!conductor.isReady(id)) conductor.fulfill(id);
    }

    // ─── IDrandOracle ────────────────────────────────────────────────────────

    function isAvailable(uint64 round) external view returns (bool) {
        return requested[round] && conductor.isReady(requestIdOf[round]);
    }

    function randomness(uint64 round) external view returns (bytes32) {
        require(requested[round] && conductor.isReady(requestIdOf[round]), "unavailable");
        return conductor.wordOf(requestIdOf[round]);
    }

    function roundAt(uint256 timestamp) external view returns (uint64) {
        if (timestamp <= genesis) return 1;
        // CEIL: first round publishing at/AFTER `timestamp` (see BlsDrandOracle for why floor is unsafe).
        return uint64((timestamp - genesis + period - 1) / period) + 1;
    }
}
