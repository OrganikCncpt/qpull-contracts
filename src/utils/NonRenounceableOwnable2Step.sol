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
///         CORRECTED (pre-submission review N-3, 2026-09-08): BaseVault was on that exempt list, justified
///         as "vestigial AFTER setController". The justification is ORDER-DEPENDENT but the exemption was
///         UNCONDITIONAL, and script/Deploy.s.sol constructs the vaults in one transaction and wires the
///         controller in a later one. Anything that reverts in that window — or a compromised deployer key,
///         for which this is the cheapest one-shot kill — could renounce and leave setController
///         permanently uncallable, onlyController permanently unsatisfiable, and every QUOTRON later routed
///         there permanently frozen with no sweep and no rescue. BaseVault now uses this base. It costs
///         nothing after setController, precisely because the owner genuinely has no powers left.
abstract contract NonRenounceableOwnable2Step is Ownable2Step {
    error OwnershipCannotBeRenounced();

    /// @dev Overrides OZ `Ownable.renounceOwnership` to revert unconditionally.
    function renounceOwnership() public view override onlyOwner {
        revert OwnershipCannotBeRenounced();
    }
}
