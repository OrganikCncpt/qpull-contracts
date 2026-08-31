// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IVault } from "./interfaces/IVault.sol";
import { IClaimManager } from "./interfaces/IClaimManager.sol";

/// @title  ClaimManager
/// @notice Pull-payment claims for all three games (spec §8). An authorized engine registers a
///         prize — which reserves it against the vault's free balance — and the winner claims within
///         the 30-day window. An unclaimed prize is swept back to the vault and rolls into future pots.
/// @dev    This contract is the sole authorized controller on the vaults. It never holds funds.
contract ClaimManager is IClaimManager, Ownable2Step, ReentrancyGuard {
    struct Claim {
        address vault;
        address recipient;
        uint256 amount;
        uint64 deadline;
        bool settled;
    }

    mapping(uint256 => Claim) public claims;
    uint256 public nextClaimId;
    // audit M-1: each engine is bound to the ONE vault it may touch (0 = unauthorized). Previously a bare
    // bool allowlist let any authorized engine reserve/pay against ANY vault — so a single compromised or
    // mis-added engine could drain all four prize vaults, silently defeating BaseVault's much-emphasized
    // immutable single-controller guarantee (the controller's OWN delegated authority was unscoped). With a
    // per-vault binding, an engine's blast radius is its own game's vault and no more.
    mapping(address => address) public engineVault;

    // audit F1 (pass-5): every other authority binding in the system is write-once (BaseVault.controller,
    // the registries' recorder, PackRegistry.engine/nft, the adapters' poolKey). setEngine was the lone
    // re-settable authority gate — a compromised owner could rebind an engine to an attacker contract and
    // drain each vault's FREE balance via registerClaim->reserve->claim. We keep the four bindings mutable
    // during launch wiring (and the M-1 de-auth-to-zero lever) up until the owner calls lockEngines() ONCE,
    // after which the engine<->vault map is frozen forever — the same "immutable after launch" posture as
    // BaseVault.controller (M-14/H-10). Deploy arms this at the end of wiring.
    bool public enginesLocked;

    event EngineSet(address indexed engine, address indexed vault);
    event EnginesLocked();
    event ClaimRegistered(
        uint256 indexed id, address vault, address recipient, uint256 amount, uint64 deadline
    );
    event Claimed(uint256 indexed id, address indexed recipient, uint256 amount);
    event Swept(uint256 indexed id, uint256 amount);

    error NotEngine();
    error WrongVault();
    error NotRecipient();
    error AlreadySettled();
    error Expired();
    error NotExpired();
    error ZeroRecipient();
    error BadDeadline();
    error NotRegistered();
    error EnginesAlreadyLocked(); // audit F1 (pass-5)
    error OnlySelf(); // audit L5 (job-745): settleSelf is an internal self-call only
    error IncompleteBindings(); // audit L2 (job-745): lockEngines refuses an incomplete engine map

    constructor(address initialOwner) Ownable(initialOwner) { }

    /// @notice Authorize `e` to register claims AGAINST `vault` only (audit M-1). Pass `vault = address(0)`
    ///         to de-authorize. An engine may be bound to exactly one vault; re-binding overwrites.
    /// @dev    audit F1 (pass-5): reverts once lockEngines() has been called — the bindings are then final.
    function setEngine(address e, address vault) external onlyOwner {
        if (enginesLocked) revert EnginesAlreadyLocked();
        engineVault[e] = vault;
        emit EngineSet(e, vault);
    }

    /// @notice One-way, irreversible: freeze the engine<->vault bindings forever (audit F1, pass-5). Called
    ///         once by the owner after all engines are wired and verified at launch. After this, no owner (or
    ///         compromised owner key) can rebind an engine to drain a vault's free balance — the same
    ///         immutability BaseVault.controller already has, extended to ClaimManager's delegated map.
    /// @dev    audit L2 (job-745): the caller passes the EXACT expected (engine, vault) pairs and each is
    ///         verified live before the freeze — so a lock issued before wiring is complete reverts instead
    ///         of permanently bricking an unbound game's registerClaim.
    function lockEngines(address[] calldata engines, address[] calldata vaults) external onlyOwner {
        uint256 n = engines.length;
        if (n == 0 || n != vaults.length) revert IncompleteBindings();
        for (uint256 i; i < n; ++i) {
            if (vaults[i] == address(0) || engineVault[engines[i]] != vaults[i]) revert IncompleteBindings();
        }
        enginesLocked = true;
        emit EnginesLocked();
    }

    /// @inheritdoc IClaimManager
    function registerClaim(address vault, address recipient, uint256 amount, uint64 deadline)
        external
        override
        nonReentrant // audit L-1: defense-in-depth on the reserve path
        returns (uint256 id)
    {
        address bound = engineVault[msg.sender];
        if (bound == address(0)) revert NotEngine();
        if (vault != bound) revert WrongVault(); // audit M-1: an engine can only touch its own vault
        if (recipient == address(0)) revert ZeroRecipient(); // audit L-1
        if (deadline <= block.timestamp) revert BadDeadline(); // audit L-1
        IVault(vault).reserve(amount); // reserves against free balance — reverts if insufficient
        id = ++nextClaimId;
        claims[id] = Claim(vault, recipient, amount, deadline, false);
        emit ClaimRegistered(id, vault, recipient, amount, deadline);
    }

    function claim(uint256 id) external nonReentrant {
        Claim storage c = claims[id];
        if (c.settled) revert AlreadySettled();
        if (msg.sender != c.recipient) revert NotRecipient();
        if (block.timestamp > c.deadline) revert Expired();
        _settle(id, c); // single claim: a failed payout reverts (the caller wants to know)
    }

    /// @notice Claim MANY prizes in one transaction (the "claim all" path). An id that is not the caller's,
    ///         already settled, or past its 30-day window is SKIPPED — never reverted — so a single stale id
    ///         can't brick the whole batch. audit L5 (job-745): a claim whose PAYOUT reverts (its vault
    ///         paused/blacklisted by QUOTRON) is also skipped — the failed settleSelf() self-call reverts
    ///         atomically, rolling back its `settled`/`release`, so that claim stays unsettled + reserved
    ///         (retryable via single claim()), while the caller's OTHER healthy claims still pay. Only the
    ///         caller's own claims are ever paid. Returns how many were actually paid.
    function claimBatch(uint256[] calldata ids) external nonReentrant returns (uint256 claimed) {
        uint256 n = ids.length;
        for (uint256 i; i < n; ++i) {
            uint256 id = ids[i];
            Claim storage c = claims[id];
            if (c.settled || msg.sender != c.recipient || block.timestamp > c.deadline) continue;
            try this.settleSelf(id) {
                unchecked {
                    ++claimed;
                }
            } catch {
                // payout reverted (e.g. a QUOTRON-blacklisted vault): leave the claim unsettled+reserved, skip
            }
        }
    }

    /// @dev External self-only wrapper so claimBatch can `try/catch` a reverting payout. MUST NOT be
    ///      nonReentrant: the parent (claim/claimBatch) is already ENTERED, so a nonReentrant modifier here
    ///      would make every self-call revert. Reentrancy is still fully covered — the external entrypoints
    ///      carry the guard and this does not reset it, so an ERC-404 receiver-hook re-entry still reverts.
    function settleSelf(uint256 id) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _settle(id, claims[id]);
    }

    /// @dev Effects-before-interactions: mark settled, release the reserve, then pay out.
    function _settle(uint256 id, Claim storage c) private {
        c.settled = true;
        IVault(c.vault).release(c.amount);
        IVault(c.vault).payOut(c.recipient, c.amount);
        emit Claimed(id, c.recipient, c.amount);
    }

    /// @notice After the window closes, return an unclaimed prize to the vault (rolls into future pots).
    function sweepExpired(uint256 id) external nonReentrant {
        Claim storage c = claims[id];
        if (c.vault == address(0)) revert NotRegistered(); // audit L-2: explicit guard, not an incidental revert
        if (c.settled) revert AlreadySettled();
        if (block.timestamp <= c.deadline) revert NotExpired();
        c.settled = true;
        IVault(c.vault).release(c.amount);
        emit Swept(id, c.amount);
    }
}
