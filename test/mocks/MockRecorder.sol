// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IPackRegistry, IJackpotRegistry, ILeaderboardRegistry } from "../../src/interfaces/IRegistries.sol";

/// @notice Test double for the game registries as seen from QpullTaxHook: records the last
///         notification and can be switched to revert (to prove the hook's try/catch keeps the
///         canonical pool trading when a registry faults).
contract MockRecorder is IPackRegistry, IJackpotRegistry, ILeaderboardRegistry {
    address public lastTrader;
    uint256 public lastGross;
    uint256 public calls;
    bool public revertAll;

    function setRevert(bool v) external {
        revertAll = v;
    }

    function recordBuy(address buyer, uint256 grossValue)
        external
        override(IPackRegistry, ILeaderboardRegistry)
    {
        _rec(buyer, grossValue);
    }

    function recordTrade(address trader, uint256 grossValue) external override {
        _rec(trader, grossValue);
    }

    function _rec(address a, uint256 g) internal {
        if (revertAll) revert("recorder down");
        lastTrader = a;
        lastGross = g;
        ++calls;
    }
}
