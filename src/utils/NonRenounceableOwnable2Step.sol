// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title  NonRenounceableOwnable2Step
/// @notice Ownable2Step whose ownership can NEVER be renounced (audit F13, pass-5).
/// @dev    OZ's `Ownable` ships a single-step `renounceOwnership()` that sets the owner to address(0).
///         For the contracts that need a permanently-live owner — the engines (setPotCap / setMinPot /
///         setWinnersPerDay), PackRegistry (setTicketPrice re-peg), and Treasury (setKeeper rotation) —
///         renouncing would irreversibly brick those knobs. Two-step transfer of ownership to the launch
///         TimelockController + multisig is preserved; only the accidental/"decentralization-theater"
///         renounce path is closed. Contracts whose owner is vestigial after launch (BaseVault after
///         setController, the write-once registries, NFTCollection, the adapters) deliberately do NOT use
///         this base — renouncing them post-wiring is harmless.
abstract contract NonRenounceableOwnable2Step is Ownable2Step {
    error OwnershipCannotBeRenounced();

    /// @dev Overrides OZ `Ownable.renounceOwnership` to revert unconditionally.
    function renounceOwnership() public view override onlyOwner {
        revert OwnershipCannotBeRenounced();
    }
}
