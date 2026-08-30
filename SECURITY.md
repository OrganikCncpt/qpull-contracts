# QPULL — Audit Remediation & Security Model

This document tracks the external LeftClaw AI audits of `qpull-contracts` across three passes:

- **Pass 1** (commit `47d9c4f`, 20H/24M/17L) — remediation in §§1–5.
- **Pass 2 / job 737** (commit `6dd4dec`, 1C/8H/18M) — remediation in **§7**.
- **H-2, the architecture change** — the 4% transfer tax was structurally incompatible with Uniswap-V4
  flash accounting and has been **re-built as a V4 hook**; see **§8**. That revision also passed an
  internal adversarial multi-agent review (§8) and added the hook's test suite plus vendored `v4-core`
  v4.0.0 so the hook can be verified against the real `PoolManager`.
- **Pass 3, an independent audit** (commit `9518c02`, 0C/4H/8M/18L) — remediation in **§10**. Every
  code-fixable finding is fixed (local suite: 136 tests green).

Every High/Medium/Low finding is mapped below to one of: **fixed in code**, **resolved by governance**,
**accepted (bounded)**, **removed**, or **false positive**. The local test suite is green after all code
changes (`forge test --no-match-path 'test/fork/*'`).

---

## Security model & reviewer guidance

Two standing assumptions to adopt when reviewing:

- **Owner = `TimelockController` (delay ≥ 48h) + multisig**, with ownership renounced where possible after
  launch (see §2). No privileged setter is instant.
- **QUOTRON is an external ERC-404** whose exact whole-unit / receiver-hook semantics **cannot be verified
  from this repo**. Treat its behavior as adversarial wherever the protocol relies on it, and flag any
  assumption rather than skipping it.

The whole tree is in scope, but these four surfaces carry the largest blast radius — a defect here is
catastrophic rather than bounded, so they warrant the deepest attention:

**1. Randomness — the fairness root.** *Invariant:* no draw or reveal beacon is knowable or forgeable before
its cutoff. *Defenses:* trustless on-chain BLS verification of drand quicknet (`BlsDrandOracle`);
future-bound reveal rounds with a `REVEAL_LAG` buffer; `roundAt` returns the first round at/after a cutoff
(ceil). *Please double-check:* (a) can the BLS verifier accept an invalid signature? — one false-accept makes
every outcome forgeable; (b) is any consumer's reveal round knowable before its entry/snapshot window closes
(`RaffleEngine`, `JackpotEngine`, `HolderDrawEngine`, `PackRegistry`, `NFTCollection`)? A dedicated
cryptographic review of the verifier remains recommended.

**2. Value bridge — `Treasury.convert()` + the swap adapters.** *Invariant:* every unit of tax reaches the
prize vaults or the team, less only real slippage; no path drains or bricks the flow. *Defenses:*
keeper-gated `convert` with off-chain slippage floors; balance-delta accounting rather than trusting adapter
return values; adapters callable only by the Treasury. Tax now arrives in **two currencies** (QPULL on buys,
WETH on exact-in sells — see §8); `convert()` swaps the QPULL leg and sweeps held WETH, taking the team's 20%
of the combined WETH. *Please double-check:* the Uniswap-V4 `unlock/settle/take` accounting, the residual
sandwich surface within the keeper floor, the min-batch-threshold vs. per-call-slice-cap interaction, and any
way to strand or divert a batch.

**3. Solvency — `BaseVault` + `ClaimManager`.** *Invariant:* `unclaimedReserve ≤ balance` at all times; each
prize is paid at most once; reserved funds are never drainable. *Defenses:* reserve-against-free-balance;
pull-claims with a 30-day window; `payOut` refuses to touch the reserve; `nonReentrant` + CEI. *Please
double-check:* any path that lowers balance without a matching `release`, cross-vault reachability via an
authorized engine, and ERC-404 whole-unit receipt / reentrancy on the payout leg.

**4. The tax hook — `QpullTaxHook` (the trade hot path).** As of H-2 (§8) the 4% tax is a **Uniswap-V4 hook**
on the canonical QPULL/WETH pool, **not** a token transfer hook — `QPULLToken` is now a clean, ownerless
ERC-20. *Invariant:* every canonical-pool trade pays exactly 4%, credits the intended game entries to the
real swapper, and no trade can brick the pool; plain (non-trade) transfers are untaxed. *Defenses:* the hook
is fully immutable (no owner/setters); the fee is taken inside the locked context via `take()`; attribution
uses `tx.origin`; registry fan-out is `try/catch` so a reverting registry costs only that trade's rewards;
`afterInitialize` restricts pool creation to the deployer's canonical pool. *Please double-check:* the
`afterSwap` delta sign/currency for all four swap shapes, that `take(fee)` + the returned `+fee` delta always
net to a settled unlock, the `exemptSender` (conversion) path, and any way to farm registry rewards or evade
the fee. This surface received a dedicated internal adversarial review (§8) but a **human V4-hook specialist
sign-off is still recommended before mainnet** — hooks are V4's most dangerous surface.

The **accepted, bounded risks** are catalogued in §3 — we welcome disagreement with our reasoning there.

---

## 1. Fixed in code

| # | Finding | Change |
|---|---|---|
| **H-1** | Public, tax-exempt adapter = 0% sell-tax bypass | Both adapters gated to the Treasury (`setTreasury` + `require(msg.sender == treasury)`) in `QpullWethAdapter` / `QuotronRouterAdapter`. |
| **H-2** | Leaderboard unbounded catch-up + flag-before-check | Window-bound to `currentWeek()==week+1`; `distributed=true` moved below the empty-pot guard. |
| **H-3** | Jackpot flag-before-check | `drawn=true` moved below the `total/pot==0` guard. |
| **H-3B / M-9** | Jackpot timing-absorption / oversized-prize gas | Added `potCap` (owner-set, default uncapped) clamping a single draw's payout; excess rolls forward. |
| **H-7** | HolderDraw `setExcluded` post-beacon re-roll | Exclusion frozen into the snapshot (excluded owners captured as `address(0)`); no live read at draw. |
| **H-8** | `payOut` could drain reserved prizes | `payOut` now reverts if it would dip into `unclaimedReserve`; reserved (owed) funds are protected unconditionally. Header corrected. |
| **H-12** | `setRecipients` re-settable, redirect mint proceeds | Frozen once `totalMinted > 0` + zero-address checks. |
| **H-13** | `finalizeLaunch` couples rarity seal to ETH payout | Split: `finalizeLaunch()` seals rarity only (no ETH); `withdrawProceeds()` pays each bucket **independently** (a reverting recipient can't block the reveal or the other buckets). |
| **H-14** | `convert()` trusts adapter return values | Measures actual WETH/QUOTRON balance deltas and checks them against the floors (`SwapShortfall`). |
| **H-17** | Dust-pot raffle burns tickets for 0 payout | Guarded: draw is skipped (no ticket burn, day not consumed) unless the smallest tier bucket can pay a full field ≥1 wei. |
| **H-18** | `maxTicketsPerBuy = 1000` exceeds block gas | Lowered to 100, `MAX_TICKETS_CEILING = 200` bound on the setter. |
| **H-20** | Leaderboard √-weighting is sybil-positive | Switched to **linear pro-rata** — sybil-neutral (splitting a wallet's points yields the same total). |
| **M-1** | `convert` config gate omits jackpot/leaderboard vaults | Added to the gate; `setRouting` now rejects zero destinations. |
| **M-3** | Router adapter didn't enforce `minOut` locally | Local `if (amountOut < minOut) revert` after the router call. |
| **M-17** | Oracle address unchecked on the hot path | `require(drand_ != address(0))` in the PackRegistry constructor. |
| **L-1, L-2** | Claim input validation | `registerClaim` rejects zero recipient / past deadline; `sweepExpired` rejects unregistered ids. |
| **L-5, L-7, L-9, L-14, I-5, I-6** | Events / bounds / flag-order / precision / stale comments | Added events; bounded the deadline buffer; HolderDraw `<5`-void no longer consumes the week; single-division prize; corrected stale team-split and √ comments. |

---

## 2. Resolved by governance (owner = Timelock + Multisig)

The audit's "malicious-owner" findings are resolved by the deployment's ownership model, not by code: **every
`onlyOwner` setter is held by a `TimelockController` (minimum delay ≥ 48 hours) controlled by a multisig**,
and ownership of the game contracts is **renounced** after launch config is locked. A timelock delay far
exceeding any draw window (raffle 1 day, holder 1 week, jackpot 14 days) removes the ability to change a
knob **reactively** in response to a now-public beacon — which is the mechanism behind every finding here.

| # | Finding | Why the timelock/multisig resolves it |
|---|---|---|
| **H-6** | `setWinnersPerDay` grind after beacon public | Timelock delay > the 1-day draw window ⇒ K cannot be changed reactively within a draw. |
| **H-9** | Rogue authorized engine → cross-vault drain | `setEngine` is timelocked + observable; engines are the protocol's own audited contracts. |
| **H-10** | Owner de-authorizes controller, locks prizes | Controller-management is timelocked (delay > 30-day claim window) and renounced post-launch. |
| **H-11** | `setToken`/`setEngine` unbounded; `drawFrom` beacon param | `token`/`engine` set once at deploy then renounced; `drawFrom` is `onlyEngine` (the RaffleEngine). |
| **H-14** (setters) | `setAdapters`/`setKeeper` unbounded | Timelocked; balance-delta verification (§1) already neutralizes a malicious adapter's *return value*. |
| **M-13** | No timelock on any setter | This section is the resolution: a `TimelockController` + multisig owns all privileged setters. |
| **M-24** | `setAmm`/`setTaxExempt` owner abuse | Timelocked + observable; AMM/exempt sets are one-time launch wiring. |

**Deploy requirement:** transfer ownership of `QPULLToken`, `Treasury`, all vaults, `ClaimManager`, all
registries, all engines, `NFTCollection`, and the adapters to the `TimelockController` immediately after
launch wiring; renounce where no further changes are expected.

---

## 3. Accepted, bounded risks

| # | Finding | Rationale |
|---|---|---|
| **H-5** | HolderDraw single-block ownership "rental" | Not a guaranteed win — the settling beacon is unknown during the snapshot window, so a renter only buys a *proportional* chance for one block. There is no NFT flash-loan for a bespoke 250-piece collection, so acquiring a large share is real, illiquid capital, and the payout is bounded by `potCap`. The design deliberately pays the **snapshot** owner (never live `ownerOf`); the audit's "re-verify `ownerOf` at draw" was **rejected** — it would reintroduce the buy-after-reveal front-run the design closes. A future multi-block/multi-sample snapshot is the path if stronger holding-time enforcement is ever wanted. |
| **M-6** | Distinct-5 dedup is per-address, sybil-able | A holder splitting `k` NFTs across `k` wallets earns ~`5k/250` slots — i.e. **proportional to holdings**, which is fair for a holder draw. The distinct-5 rule caps only naive single-wallet concentration. Any per-address scheme is sybil-able; `potCap` bounds the absolute exposure. |
| **M-7** | Raffle draw-time pot absorption (mild) | Milder variant of H-3B; the per-tier bucket split already bounds any single winner's share, and void-on-miss means a delayed call risks forfeiting the day entirely. |
| **M-20** | 1-hour `REVEAL_LAG` vs L2 sequencer clock | The reveal lag is sized against RH's (Arbitrum-family) documented `block.timestamp` bounds; sealed-then-revealed holds as long as the sequencer clock stays within those bounds, which is a chain-level assumption shared by all time-based L2 logic. |

---

## 4. Removed (findings no longer applicable)

`CommitteeDrandOracle`, `DerpOracle`, `IVrngConductor`, and their tests/mocks were **deleted** — the protocol
deploys only the trustless, time-locked `BlsDrandOracle`. This removes **H-4, H-16, M-12, M-21, M-23** (and
the DERP/committee halves of M-15/M-16) outright, since the affected code no longer exists.

---

## 5. False positives / already mitigated

- **M-2** — the V4 swap uses the extreme price limit; input is always fully consumed, so the "partial-fill settles nominal" path cannot occur.
- **H-19** — reentry into `claim` is blocked by `nonReentrant` + CEI (settle/release before payOut); the fork test confirms real QUOTRON fires no receiver hook.
- **L-4** — the role mappings are deliberately multi-member, not a capped single-member pattern.
- **L-15** — `sha256` is precompile `0x02`, infallible and fixed-length; the compiler checks call success.
- **L-16** — `isAvailable()` is intentional off-chain keeper/frontend surface, not dead code.

---

## 7. Second re-audit (LeftClaw job 737, commit `6dd4dec`) — 1C / 8H / 18M

The stronger re-audit surfaced a Critical the first pass missed and re-opened several first-round fixes as
incomplete. All confirmed and cheap-deploy findings are fixed (local suite green).

| # | Severity | Finding | Change |
|---|---|---|---|
| **C-1** | Critical | **Dust-donation consumes a draw.** `freeBalance()` is donation-raisable and wei-scale guards let anyone trigger a draw for a few wei across all four engines (the Raffle variant also burned live tickets). | Owner-set **`minPot`** floor on Raffle/Jackpot/HolderDraw/Leaderboard: `pot < minPot` **voids without consuming** (no ticket burn, day/period not flagged). Leaderboard sets `distributed=true` only after `paid>0`; HolderDraw guard is `pot<minPot || pot/WINNERS==0`. **Must be set at launch** (default 0). |
| **H-1** | High | My pass-1 H-12/H-13 fix **created a brick**: a mint before `setRecipients` locked proceeds + the reveal forever. | `mint()` now reverts unless recipients are set. |
| **H-3** | High | `convert()` unbounded; a donation-inflated balance could brick the pipeline on one oversized swap. | **`maxConvertPerCall`** cap — the keeper drains in pool-sized slices. |
| **H-4** | High | Holder-draw sybil: distinct-**wallet** selection rewards splitting NFTs across wallets. | `runDraw` selects **5 distinct tokenId slots** (swap-pop), payout linear in tokens held — splitting confers no advantage; one wallet can win multiple slots; voids only if `<5` eligible **tokens**. |
| **H-5** | High | My pass-1 H-20 linear fix was **incomplete**: pro-rata over the capped 25-slot board is sybil-positive (splitting evicts incumbents, shrinks the denominator, captures 100%). | `LeaderboardRegistry` now tracks **`totalPoints[week]`** (all buyers); `distribute` divides by that, so off-board weight rolls forward and a split can never exceed its true share. |
| **H-6 / L-11** | High/Low | `BlsDrandOracle` drand genesis/period unvalidated. | Constructor requires `genesis==1_692_803_367 && period==3`. |
| **H-7** | High | `PackRegistry` / `NFTCollection` `revealDelay` unvalidated. | Require `>= 1 hour` (PackRegistry also `< 1 day`) — the reveal margin can't be set below the engines' `REVEAL_LAG`. |
| **H-8** | High | Engine `genesis` vs. its registry's `genesis` uncross-checked. | Jackpot/Raffle constructors require `registry.genesis() == genesis_`. |
| **M-1** | Med | Adapter settled the nominal `amountIn`, not the **consumed** delta → a partial fill reverts `convert()`. | Settle the consumed delta + refund the unconsumed remainder. |
| **M-3** | Med | `RaffleEngine.MAX_K = 1000` (gas). | Lowered to 200. |
| **M-8** | Med | `setPoolKey` re-settable / unvalidated. | Write-once + pair-checked (and, post-H-2, verifies the bound hook exempts the adapter — see §8). |
| **M-13** | Med | `setNft` unchecked zero. | Zero-address check. |
| **L-17** | Low | NFT split rounding dust went to team. | Dust rounds to LP; team is never `> 5%`. |

**Owner-trust cluster** (M-2, M-6, M-10, M-11, M-18, L-5): resolved by the same governance model as §2.
**False positives:** L-9 (`<5`-void already correct), L-10.

The **immutable-controller** change (single one-shot `BaseVault.controller`, never revocable) closes the
job-737 **M-14** and the residual halves of **H-10 / M-5** in code rather than by governance.

---

## 8. H-2 — the 4% tax re-built as a Uniswap-V4 hook

**The finding.** A 4%-transfer-tax token is structurally incompatible with Uniswap V4's flash accounting:
a token that skims transfers leaves a non-zero delta on `settle()` (`CurrencyNotSettled`), bricking every
router that trades it; exempting a router to avoid that nullifies both the tax and the game entries. This
gated launch and could not be patched at the token level.

**The fix.** The tax is now a **trade tax collected by a hook** (`src/hooks/QpullTaxHook.sol`), and
`QPULLToken` is a clean, **ownerless** ERC-20 (which independently closes the pass-2 owner-exemption **M-9**
and setter **M-13**). Properties:

- **Immutable** — no owner, no setters; the 4% and the first-hour gate are constants. A hook governs the
  protocol's only liquid pool, so it deliberately holds **no admin lever**.
- **`afterSwap`** takes 4% of the swap's *unspecified* currency (QPULL on buys, WETH on exact-in sells) via
  `poolManager.take(feeCurrency, treasury, fee)` and returns it as a positive hook delta — v4-core makes the
  swapper pay it (`Hooks.sol`: "the caller has to pay for the hook's delta"); the `take()` clears the hook's
  own credit inside the same unlock. Verified against **vendored v4-core v4.0.0** for all four swap shapes.
- **First-hour NFT-holder gate** enforced on buys, keyed to `tx.origin` (an unspoofable identity; `hookData`
  is ignored as caller-supplied). Known, accepted limits: a holder using a **smart-contract wallet** is gated
  during hour 1 (hold the NFT on the signing EOA, or wait for expiry); the gate window starts at
  `initialize()`, so LP must be **seeded immediately after** (runbook §6).
- **Game fan-out** to the three registries with `tx.origin`, wrapped in `try/catch` — an immutable hook must
  never let a registry fault brick the pool (a failed record costs only that trade's rewards, `RecordFailed`).
- **`afterInitialize`** restricts pool creation: only the deployer may create the canonical pool (no
  front-run of the gate window) and no other pool may attach the hook (no reward-farm pools).
- **Address flags** (`AFTER_INITIALIZE | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA = 0x1044`) are mined with a
  CREATE2 salt (`script/HookMiner.sol`); `test/HookMiner.t.sol` proves the miner target and the constructor's
  own `BadFlags` self-check agree (a launch-day revert if they ever drift).
- The Treasury's `QpullWethAdapter` is the hook's **`exemptSender`** (conversion swaps pay no fee);
  `setPoolKey` verifies that binding on-chain.

**Internal adversarial review.** This revision was reviewed by a multi-agent pass across four lenses
(V4 delta/settlement accounting, economic evasion, DoS/gate/pool-creation, cross-contract integration), each
finding handed to an independent verifier to refute. **One finding survived, at LOW severity, and is fixed:**
`Treasury.convert()` compared the min-batch `convertThreshold` against the already-capped per-call slice, so a
misconfiguration where `maxConvertPerCall < convertThreshold` could strand the QPULL leg (owner-recoverable).
Fixed: gate on the raw balance, then size the slice. No settlement, sign, fee-evasion, gate-bypass, or
reentrancy issue survived verification.

**Residual recommendation.** An internal review plus real-`PoolManager` tests is necessary, not sufficient:
a **human V4-hook specialist sign-off remains recommended before mainnet.**

---

## 9. Launch runbook — critical operator steps

Required steps not wired by `Deploy.s.sol`:

1. **`Treasury.convert()` tax currency:** the QpullWethAdapter is the hook's `exemptSender`; `Deploy` wires
   `setTreasury` + `setPoolKey` for it. Confirm the WETH→QUOTRON adapter's `setTreasury` too. *(H-1 pass-1)*
2. **`setMinPot(<floor>)`** on **all four** engines (Raffle, Jackpot, HolderDraw, Leaderboard) and
   **`Treasury.setMaxConvertPerCall(<pool-sized>)`** — both default to a permissive value and **must** be set
   to concrete, pool-sized bounds at launch. *(C-1, H-3)*
3. **`JackpotEngine.setPotCap`** / **`HolderDrawEngine`** constructor cap — concrete per-draw bounds. *(H-3B/M-9)*
4. After the NFT mint closes: **`finalizeLaunch()`** (seals rarity), then **`withdrawProceeds()`**. *(H-13)*
5. **GO-LIVE (H-2):** from the deployer key, `poolManager.initialize(canonicalPoolKey, sqrtPriceX96)` **then
   seed LP immediately** (back-to-back, ideally one multicall/block). Initialize stamps `launchTime` and opens
   the first-hour gate; a gap between initialize and LP silently shortens the effective gate.
6. Transfer all ownership to the **Timelock + multisig**; renounce where no further changes are expected. The
   tax hook has no owner, so nothing to transfer there. *(§2)*
7. Verify the keeper is posting drand beacons on-chain before the first draw window closes.
8. **QUOTRON gate check (§10, M-6/M-8 trust note):** confirm the four `BaseVault`s, `ClaimManager`, and
   `Treasury` addresses/codehashes are not on QUOTRON's blacklist or `bannedVenueCodehash` list, and
   confirm who controls QUOTRON's `paused`/blacklist (ideally timelocked) before relying on it for prizes.

---

## 10. Third pass — independent audit (commit `9518c02`) — 0C / 4H / 8M / 18L

An independent three-phase audit of the H-2 revision. No Critical. Every code-fixable finding is fixed
(local suite green, 136 tests, incl. a regression per fix); the rest are governance-covered, conditioned on
external facts this repo cannot verify (QUOTRON's ERC-404 semantics; Robinhood Chain's precompile/clock
config), or accepted with rationale.

### Fixed in code

| # | Sev | Finding | Change |
|---|---|---|---|
| **H-1** | High | `convert()`'s WETH→QUOTRON leg had no per-call cap — a WETH donation could brick the whole pipeline (the H-2 rework introduced WETH as a second, donation-inflatable tax currency) | Added `maxWethConvertPerCall`, symmetric to `maxConvertPerCall`; the WETH slice is capped and the remainder drains over later calls. |
| **H-2** | High | `minPot` shipped at an unsafe `0` default on Jackpot/HolderDraw (their only config-independent guard voids at 1 / 5 wei), so a missed runbook step re-opened the C-1 dust-grief | `minPot` is now a **required (> 0) constructor argument** on `JackpotEngine`/`HolderDrawEngine` (fail-closed on-chain); `Deploy` also wires every engine's floor so it never depends on a post-deploy step. |
| **H-3** | High | `RaffleEngine` was the only draw engine without a `potCap` — a delaying winner could inflate their own payout | Added an owner-set `potCap` (clamp identical to the sibling engines); excess rolls forward. |
| **M-1** | Med | `ClaimManager`'s bool engine allowlist had no per-vault binding — one authorized/compromised engine could drain **all four** vaults, defeating `BaseVault`'s immutable-controller guarantee | `engineVault` binds each engine to exactly **one** vault; `registerClaim` reverts `WrongVault` otherwise. Blast radius is now a single game's vault. |
| **M-4** | Med | `setExcluded` could run mid-snapshot, freezing an internally-inconsistent owner set | Reverts `SnapshotInProgress` while the current week's snapshot is partway done. |
| **M-5** | Med | A rounded-to-zero split leg would revert `convert()` under a zero-value-reverting QUOTRON | Each of the three split transfers is guarded with `if (amount > 0)`; zeroed legs' value rides in the hourly remainder. |
| **L-1** | Low | `nonReentrant` missing on 3 draw functions + `registerClaim` | Added to `RaffleEngine.runDraw`, `JackpotEngine.runDraw`, `LeaderboardEngine.distribute`, `ClaimManager.registerClaim` (defense-in-depth). |
| **L-2** | Low | `LeaderboardEngine` missing the sibling engines' genesis cross-check | Added `GenesisMismatch` against `LeaderboardRegistry.genesis()`. |
| **L-3** | Low | `minPot`/`potCap` setters didn't cross-validate (`potCap < minPot` silently voids every draw) | All engine setters now enforce `minPot <= potCap` both directions. |
| **L-5** | Low | `Treasury.setAdapters` missing the zero-address guard `setRouting` has | Added. |
| **L-10** | Low | `forceApprove` in `convert()` left a residual allowance | Reset to `0` after each swap. |
| **L-16** | Low | `roundAt(ts <= drandGenesis)` returned round 1 (fail-open) | Now reverts `TimestampBeforeGenesis` (fail-closed; unreachable in normal use). |
| **I-7** | Info | Misplaced NatSpec on `JackpotEngine.setPotCap` | Corrected. |

### Governance-covered, conditional, or accepted

| # | Sev | Disposition |
|---|---|---|
| **H-4** | High | **Operational, verified separately.** The EIP-2537 precompiles (`0x0b`/`0x0f`/`0x10`) were confirmed live on the actual Robinhood Chain RPC via a direct precompile probe during development (not inferred from `evm_version`), and the code is fail-closed if they were ever absent. Re-confirm on the final deploy target as a launch gate. |
| **M-2** | Med | **Accepted / mitigated.** No trustworthy on-chain price reference exists (QPULL's only price is its own pool, so a TWAP is itself manipulable). Mitigated by the keeper gate (rotatable key) plus `maxConvertPerCall` **and now `maxWethConvertPerCall`**, which bound a single-slice sandwich; documented. |
| **M-3** | Med | **Governance (§2)** — the timelock+multisig model is the resolution for re-settable bindings; the missing zero-check portion is fixed as L-5. |
| **M-6, M-8** | Med | **Verified against QUOTRON's source and resolved.** QUOTRON's verified source (`Quotron404V2`, 18 dec, on the RH Blockscout explorer) was read directly. **M-6 (fee-on-transfer): does not apply** — `_transfer` does `balanceOf[to] += amount` with no skim; recipients receive the full amount (reflections pay out in a separate stock token, never a cut of QUOTRON). **M-8 (external balance reduction): does not apply** — the whole-unit rebalance (`_syncDown`/`_syncUp`) mutates only the NFT layer (`_darkOwned`/`_ownerOf`/pool), **not** `balanceOf`, so third-party trading around a vault cannot reduce its fractional balance; `balanceOf` only decreases via the holder's own `_transfer`/`hardwire` (or QUOTRON-admin recovery — see the trust note). |

**QUOTRON is a trusted, admin-controlled external dependency (learned from reading its source; not a code issue in this repo).** `Quotron404V2._checkTransferAllowed` gates every transfer on: a **`paused`** flag, a **blacklist** (`from`/`to`/`msg.sender`), a **`bannedVenueCodehash`** check (transfers revert if any party's contract codehash is banned — the four `BaseVault`s share one codehash), and an **`adminTransferTerminal`** recovery power that can move a whole unit out of any account. Prize *liveness* therefore depends on trusting QUOTRON's admin not to pause, blacklist, or ban-codehash the protocol's vaults / `ClaimManager` / winners. This is the same class as trusting QUOTRON to be a real prize token at all, and is surfaced here as an explicit assumption. **Launch check (added to §9):** confirm the protocol's vault / ClaimManager / Treasury addresses and codehashes are not on QUOTRON's blacklist or `bannedVenueCodehash` list, and understand who controls QUOTRON's pause/blacklist and whether it is timelocked.
| **M-7** | Med | **Confirmed and addressed by cadence.** RH's `maxTimeVariation.delaySeconds` was read directly from its SequencerInbox on Ethereum L1 (`0xBd0D173EEb87D57A09521c24388a12789F33ba96` → `delaySeconds = 345_600 = 4 days`; `futureSeconds = 3_600 = 1h`). The sealed-then-revealed guarantee is code-enforced iff `REVEAL_LAG > delaySeconds`. **`REVEAL_LAG` is now sized per cadence: JackpotEngine = 5 days and HolderDrawEngine = 4.5 days — both exceed the 4-day bound, so the two highest-value randomized draws (jackpot winner-take-all; weekly holder draw) are fully code-enforced** even against a maximally back-dating sequencer (their 14-day / 7-day windows absorb the lag). The **daily raffle** (and per-cohort pack-tier reveal) structurally cannot set `REVEAL_LAG` above ~1 day, so those remain `1h` and rely on the standard trusted-sequencer assumption every Arbitrum L2 already requires; the residual is bounded (a daily bucket-split pot is far lower value than the jackpot, and the attack needs the RH-operated sequencer to catastrophically mis-stamp time — which breaks the whole chain, not just this raffle). |
| **L-4** | Low | **Runbook** — do not `renounceOwnership` on contracts that need ongoing hot-key rotation (keeper) or before mandatory bindings are set; set bindings first. |
| **L-6, L-7** | Low | **Owner-trust / accepted** — mint-recipient choice and `baseURI` mutability are owner responsibilities; on-chain rarity is immutable regardless. |
| **L-8, L-12** | Low | **Accepted (perk-only, immutable hook)** — the first-hour gate is anti-snipe, not fund-safety; `tx.origin` and the launch-time window are the deliberate design (§8). No fund impact. |
| **L-9** | Low | **N/A** — QUOTRON is 18-decimal. |
| **L-11** | Low | **Accepted design** — void-on-miss denies the keeper a timing advantage; a skipped window rolls funds forward (liveness, not loss). |
| **L-13, L-14, L-15, L-17, L-18** | Low/Info | **Accepted** — single-chain deploy; adapter ETH is self-harm only; free-entry cap is a bounded shared allowance; the pairing subgroup check is standard precompile reliance (crypto review already recommended); OOG-vs-invalid-sig both revert with no state change. |

---

*This remediation was prepared with AI assistance and is not a substitute for an independent human security
review. A dedicated cryptographic review of `BlsDrandOracle` and a **V4-hook specialist review of
`QpullTaxHook`** remain recommended before mainnet. QUOTRON's ERC-404 semantics (M-6/M-8), Robinhood
Chain's EIP-2537 support (H-4), and its sequencer `delaySeconds` (M-7) have all been verified on-chain /
against source and are addressed above; the residual QUOTRON-admin trust surface is documented and gated
by the §9 launch check.*
