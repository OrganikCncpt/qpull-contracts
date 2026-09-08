# QuoPull external-checklist fused audit

**Date:** 2026-09-07
**Target:** `/Users/user/Desktop/QUOPULL` (branch `feat/allowlist-reserve-delegate`)
**Readiness verdict:** `minor-fixes-first`

## Method

This pass runs the QuoPull tree against six external firm checklists rather than re-deriving
vulnerabilities from scratch. The six-skill roster:

1. **evm-audit-skills** (EVM/Solidity vulnerability patterns)
2. **scv-scan** (smart-contract-vuln static rules: timestamp-dependence, assembly, etc.)
3. **QuillShield** (checklist-driven review)
4. **Hacken** checklist sources
5. **Cyfrin** checklist sources (also loaded here as the Solidity standards lens)
6. **OpenZeppelin** develop-secure-contracts + the EVM security pre-deploy checklist (standards lens)

Twelve specialists each ran the full roster against one slice of the protocol (AMM/flash-loan,
oracle/randomness, chain-specific/L2, ERC721, assembly/precompile, treasury/convert, access/failsafe,
games/claims, mint/delegate, swap-hook, solvency/vault, and a cross-cutting standards reviewer). Each
raw finding was handed to an independent verifier to refute against the code before it reached this
synthesis. This document dedupes the confirmed medium-and-above plus carried low/info findings by root
cause, classifies each against the internal pre-audit (`docs/PREAUDIT-REPORT.md`) and the accepted
residuals in `SECURITY.md` section 16, then applies a standards lens over the whole tree.

Each finding below was re-verified against the current source at synthesis time (file and line cited).

## Classification summary

Eight raw specialist findings dedupe to **five** distinct root causes. Two of the five were each caught
independently by two specialists.

| # | Root cause | Severity | Class | Specialists |
|---|---|---|---|---|
| 1 | Onchain art immutability not enforced in the NFT constructor | low | **NET-NEW** | erc721 |
| 2 | Oracle deploy gate omits MODEXP (0x05) and SHA-256 (0x02) probes | info | **NET-NEW** | oracle-random, assembly |
| 3 | `RaffleEngine` combined `runDraw` gas unmeasured at `MAX_K` (drawFrom leg omitted from the safety estimate) | info | **NET-NEW** | chain-specific |
| 4 | `QuotronRouterAdapter` swap deadline is `block.timestamp + buffer` (cosmetic) | info | **NET-NEW** | amm-flashloan |
| 5 | Daily raffle `REVEAL_LAG` (1h) below the 4-day sequencer back-dating bound | low | **ACCEPTED-RESIDUAL** (16.2) | oracle-random, chain-specific |

Zero critical, zero high, zero medium. No attacker-triggerable loss-of-funds path was found. Every
net-new item is a hardening or coverage gap, not a live exploit.

---

## NET-NEW findings

### [LOW] Onchain art immutability guarantee is not enforced onchain: the renderer lock is a runbook step, not a constructor invariant

- **Skill fired:** evm-audit-skills (ERC721 / immutability-guarantee lens), QuillShield (trust-assumption checklist)
- **File:** `src/NFTCollection.sol:251` (constructor); `src/nft/PassArtRenderer.sol:45-54` (`addChunk` / `lock`)

**Verified.** The `NFTCollection` constructor accepts any non-zero renderer address and stores it as
`immutable` (line 251 checks only `renderer_ == address(0)`). It never checks
`IPassArtRenderer(renderer_).locked()`. The NatSpec claims the reveal display "can never be changed or
forgotten (no setBaseURI)", but that guarantee actually rests on `PassArtRenderer.lock()` having been
called: `addChunk` (line 45) reverts only once `locked` is true, and `lock()` (line 52) is a separate
owner call. `_readSlot` concatenates every chunk in a slot in order, so an unlocked renderer whose owner
calls `addChunk(tierSlot, attackerBytes)` after mint injects attacker-chosen SVG into the `tokenURI`
image of every already-revealed pass.

**Failure scenario.** A deployer wires an `NFTCollection` to a `PassArtRenderer` whose `lock()` was never
called (a deviation from `DeployPassArt.s.sol`, which does lock at deploy). After passes mint and reveal,
the renderer owner appends markup to a tier slot and silently alters the art and marketplace metadata of
every minted pass.

**Bounded by.** Art/metadata only, no fund loss; requires a malicious or careless owner; publicly
detectable (`locked()` is a public view); fully mitigated when `DeployPassArt.s.sol` calls
`renderer.lock()` at deploy, which the shipped script does.

**Fix.** Make the trustless-immutability claim structural: have the `NFTCollection` constructor
`require(IPassArtRenderer(renderer_).locked())`, or renounce the renderer's ownership after lock, or add
a launch-checklist gate asserting `renderer.locked() == true` onchain post-wire. A constructor check is
strongest because it cannot be forgotten.

### [INFO] Oracle fail-closed deploy gate omits MODEXP (0x05) and SHA-256 (0x02), which the same beacon-verification path also requires

- **Skill fired:** scv-scan (assembly / precompile-dependency rule), evm-audit-skills (oracle-precompile completeness)
- **File:** `src/oracle/BlsDrandOracle.sol:87-95` (gate); `:130` (sha256), `:193-197` (`_expandMessageXmd`), `:209-210` (`_toFp` modexp)

**Verified.** The constructor gate probes exactly the three EIP-2537 precompiles: `BLS_G1ADD` (0x0b,
lines 87-88), `BLS_PAIRING` (0x0f, 89-90), and `BLS_MAP_FP_TO_G1` (0x10, 94-95), stating the oracle "can
NEVER be deployed where they are missing." But the same verification path also hard-depends on **MODEXP
(0x05)**, called by `_toFp` to reduce each 64-byte chunk mod p (staticcall at line 209-210), and on the
**SHA-256 precompile (0x02)**, used for the round message `sha256(abi.encodePacked(round))` (line 130)
and throughout `_expandMessageXmd` (lines 193-197). Neither is probed. On a chain with the BLS
precompiles but missing 0x05 or 0x02, the gate passes yet every `submitBeacon` reverts.

**Failure scenario.** Deploy succeeds on a chain lacking 0x05/0x02; the first `submitBeacon` reverts at
the length check (`PrecompileFailed`), so no beacon is ever recorded and all draws, reveals, and holder
settlement are permanently unavailable.

**Bounded by.** Practical likelihood is negligible: 0x02 (Frontier) and 0x05 (Byzantium/EIP-198, 2017)
predate EIP-2537 and are universal on every EVM chain including Arbitrum Orbit, so a chain with the BLS
precompiles but not these does not exist. It also fails **closed** at the first `submitBeacon` (never a
silent bad-randomness path), and the repo already carries an off-chain `script/bls_precompile_check.sh`.
Note MODEXP is EIP-198, arguably outside the gate's narrowly stated EIP-2537 scope. This is a
completeness note, not a defect.

**Fix.** Add a 0x05 probe (`modexp(base=1, exp=1, mod=1)` expecting a 1-byte `0x01`) and a 0x02 probe to
the same fail-closed gate, so the stated "can never be deployed where a required precompile is missing"
guarantee covers the full set the oracle actually calls.

### [INFO] `RaffleEngine` one-block gas safety at `MAX_K = 200` is unmeasured: the stated estimate omits the `drawFrom` leg in the same transaction

- **Skill fired:** Hacken/Cyfrin chain-specific checklist (Arbitrum per-tx L2 gas ceiling), evm-audit-skills (DoS via gas)
- **File:** `src/RaffleEngine.sol:49` (`MAX_K = 200`), `:279` (`packs.drawFrom`), `:286` (`_payWinners`); `src/PackRegistry.sol` (`drawFrom` O(k) with per-seat cohort loop + swap-pop)

**Verified (as a coverage gap).** `MAX_K = 200` is annotated "one-block-safe (~120-140k gas/winner)",
which accounts for `_payWinners` (~28M at 200 winners) but not for `packs.drawFrom(beacon, day,
winnersPerDay)`, which `runDraw` calls at line 279 **before** `_payWinners` at line 286. `drawFrom` is
O(k) with an inner per-seat cohort loop over up to `LIFE_DAYS` cohorts plus a storage swap-pop per paid
pick, none of which is in the per-winner estimate. Robinhood Chain's per-tx ceiling is 32M
(`ArbGasInfo.getMaxTxGasLimit`, the same ceiling that forced the `HolderDrawEngine` O(1) redesign). A
grep of `test/` finds no gas snapshot exercising `runDraw`/`drawFrom` at `winnersPerDay` near `MAX_K` on
a full cohort window, so one-block safety at the ceiling K is asserted but never proven.

**Failure scenario.** An owner sets `winnersPerDay` near 200 with ~200 live tickets; the combined
`drawFrom` + `_payWinners` for one day crosses 32M; `runDraw` becomes un-mineable; because `drawn[day]`
is set only after a successful `_payWinners` (line 285), every retry reverts, the day's window elapses,
and that day's draw voids (pot rolls forward, no fund loss). It recurs daily while K stays extreme.

**Bounded by.** No fund loss (void-on-miss), owner-controlled parameter, requires K set near the extreme.

**Fix.** Add a Foundry gas snapshot of `runDraw` at `winnersPerDay == MAX_K` over a full
`LIFE_DAYS`-cohort live window; if worst-case gas exceeds ~30M, lower `MAX_K` accordingly or bound
`setWinnersPerDay` against a measured ceiling. This closes the one remaining place where the 32M chain
parameter the rest of the system was engineered around is not backed by a test.

### [INFO] `QuotronRouterAdapter` swap deadline is computed onchain (`block.timestamp + buffer`), so it never expires

- **Skill fired:** evm-audit-skills (AMM / Dacian DeFi-slippage: "block.timestamp deadline gives no protection"), OZ security checklist (MEV/slippage)
- **File:** `src/adapters/QuotronRouterAdapter.sol:95-96`

**Verified.** `swapExactIn` passes `deadline = block.timestamp + deadlineBuffer` to `router.buyExactEth`
(line 95). Because the deadline is derived from the inclusion block's own timestamp, it is always in the
future no matter when the tx is mined, so it never expires and provides zero staleness/MEV protection.
This is the classic anti-pattern: a real deadline is a caller-supplied absolute future timestamp.

**Bounded by (fully mitigated).** There is no incremental loss or DoS. The local `Slippage` floor
(line 96, `amountOut < minOut` revert) plus the router's own `minOut`, both keyed on the keeper's
off-chain-computed `minQuotronOut`, bound any late execution to the intended slippage tolerance; and
`convert()` is keeper-only, not permissionlessly grief-able. The impact of a delayed inclusion is
already caught by the price floor, so the deadline parameter is cosmetic rather than load-bearing.

**Fix (optional hardening).** Have the Treasury/keeper pass an absolute `deadline` into `swapExactIn`
rather than the adapter deriving one from `block.timestamp`, so the parameter becomes meaningful. Low
priority given the floor already provides the real protection.

---

## Confirmations (already handled by the internal pre-audit)

These fired on the external checklists and are confirmed accurate, but each matches an item the internal
pre-audit already dispositioned. Listed for completeness; no new action.

| Finding | Severity | Disposition | Pointer |
|---|---|---|---|
| Daily raffle `REVEAL_LAG` (1h) below the 4-day sequencer back-dating bound (grind against a now-public beacon under a maximally back-dating sequencer) | low | **ACCEPTED-RESIDUAL** | `SECURITY.md` 16.2 = M-7; pre-audit LOW (randomness-oracle, chain-specific) closed to residual. Weekly holder draw is code-enforced (`REVEAL_LAG` 4.5d > 4d); daily cadence structurally cannot clear the bound. Bounded pot, trusted-sequencer assumption every Arbitrum L2 already carries. |

### Related residuals the same specialists re-confirmed (no re-report needed)

The randomness, treasury, and access specialists also re-touched, and confirmed unchanged, several
residuals already closed or accepted in the pre-audit: immutable drand dependency with the non-discretionary
one-shot NFT reveal fallback ladder (`SECURITY.md` 16.4), the no-pause/no-kill-switch posture
(`SECURITY.md` 16.1), the uncapped early-accumulation throttle tail (16.5), `lockRouting`/write-once
adapter permanence (16.6), the rip-XP two-week choice (16.7), and the pledge-flood bound (16.8). None
produced a new root cause.

---

## False positives

**Count: 0.** No finding in this pass was contradicted by the code. The four net-new items are genuine
(verified against source) hardening or coverage gaps rather than exploits, and the one carried finding
matches an accepted residual.

## Standards lens

Cross-checking the whole tree against the OpenZeppelin develop-secure-contracts skill, the EVM security
pre-deploy checklist, and the Cyfrin Solidity standards surfaced **no coverage gap beyond the four
net-new findings above**: reentrancy is guarded by `nonReentrant` plus CEI throughout, token moves use
`SafeERC20`, swap paths carry explicit off-chain `minOut`/`minQuotronOut` floors (the deadline item is
the one MEV-checklist gap, captured as finding 4), residual approvals are reset to zero, inputs are
zero-address and bounds checked, the contracts are immutable-by-design with no proxy or `delegatecall`
surface, and the absence of a pause is a deliberate, documented decision (`SECURITY.md` 16.1) that the
checklists themselves endorse flagging as a censorship-vector tradeoff rather than a missing control.
