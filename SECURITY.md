# QPULL — Audit Remediation & Security Model

This document tracks the external AI audits of `qpull-contracts` across seven passes (pass 6 in **§13**, the
latest 3-phase multi-agent pass in **§14**):

- **Pass 1** (commit `47d9c4f`, 20H/24M/17L) — remediation in §§1–5.
- **Pass 2 / job 737** (commit `6dd4dec`, 1C/8H/18M) — remediation in **§7**.
- **H-2, the architecture change** — the 4% transfer tax was structurally incompatible with Uniswap-V4
  flash accounting and has been **re-built as a V4 hook**; see **§8**. That revision also passed an
  internal adversarial multi-agent review (§8) and added the hook's test suite plus vendored `v4-core`
  v4.0.0 so the hook can be verified against the real `PoolManager`.
- **Pass 3, an independent audit** (commit `9518c02`, 0C/4H/8M/18L) — remediation in **§10**.
- **Pass 4, a deep multi-agent audit** (commit `93e5790`, 1C/4H/1MH/9M/4L/1I) — remediation in **§11**.
- **Pass 5, a 20-agent three-phase audit** (commit `7db9056`, 3H/2M/9L/6I) — remediation in **§12**. Every
  code-fixable finding is fixed (local suite: **179 tests green**), including the previously-open LP/tax gap
  (pass-4 F4 / pass-5 F6): **liquidity provision is now restricted to the protocol** (hook re-mined to
  `0x1844` with a `beforeAddLiquidity` gate).
- **Pass 6, an independent audit** (commit `24a36cc`, 0C/0H/4M/12L/15I) — remediation in **§13**. No Critical
  or High. Every code-fixable finding is fixed (local suite: **186 tests green**): convert() no longer bricks
  if one prize vault is QUOTRON-blacklisted (M3), pot-cap re-pegs are rate-limited to ±25%/cooldown (M4),
  the LP gate now also covers **remove** (L1, hook re-mined `0x1844`→`0x1A44`), and `claimBatch` survives a
  single reverting payout (L5).

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

The audit's "malicious-owner" findings are resolved by the deployment's ownership model, **not by code**. To
be precise about what that means on-chain (audit pass-4, Finding 2): there is **no built-in timelock or pause
anywhere in these contracts** — every `onlyOwner` setter takes effect in the same block it is called. The
mitigation is a **deployment step**: at launch, ownership of each contract is transferred to an external
OpenZeppelin `TimelockController` (delay ≥ 48h) controlled by a multisig, and renounced where no further
changes are needed. So the "timelock" is an *owner the contracts are handed to*, not a mechanism inside them.
**Integrators and users must verify, on-chain post-launch, that each contract's `owner()` is in fact that
timelock** (and that mandatory bindings were set before any `renounceOwnership`) — until that transfer, and if
it is skipped, the control model is same-block multisig with the full blast radius the audit enumerates
(drain vaults, forge entries, etc.). A timelock delay far exceeding any draw window (raffle 1 day, holder 1
week, jackpot 14 days) is what removes the ability to change a knob **reactively** in response to a now-public
beacon. Several highest-value owner levers are ALSO hardened in code now (write-once bindings, §11) so they do
not depend on governance alone.

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
- **Address flags** (`AFTER_INITIALIZE | BEFORE_ADD_LIQUIDITY | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA =
  0x1844`) are mined with a CREATE2 salt (`script/HookMiner.sol`); `test/HookMiner.t.sol` proves the miner
  target and the constructor's own `BadFlags` self-check agree (a launch-day revert if they ever drift). The
  `BEFORE_ADD_LIQUIDITY` bit (pass-5 F6) restricts liquidity provision to the protocol — see §12.
- **`beforeAddLiquidity`** reverts unless the liquidity provider is the protocol (`sender == initializer` for
  a contract LP-manager, or `tx.origin == initializer` for the deployer EOA via a router), closing the
  untaxed LP acquire/dispose side-door. **Operational notes (accepted):** (1) the gate keys on the initializer
  identity, so that key must never sign a transaction that calls untrusted code — during such a tx an attacker
  contract could add a position (and, since removes are ungated, later withdraw it); (2) because the hook is
  immutable and the shipped `initializer` is the deployer EOA, all future LP adds are permanently bound to
  that EOA (not migratable to the launch timelock/multisig) — keep it secured; the protocol can always
  *remove* its own LP (removes are ungated). Permissionless community LP is disabled by design (the pool is
  protocol-owned liquidity; permissionless LP in a taxed-swap pool is itself the exploit).
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
2. **Engine floors + caps are now constructor-required (pass-5 F14, F5).** `Deploy.s.sol` reads
   `RAFFLE_/JACKPOT_/LEADERBOARD_/HOLDER_MIN_POT` **and** `RAFFLE_/JACKPOT_/LEADERBOARD_POT_CAP` (+ the
   HolderDraw cap/ceiling) via fail-closed `vm.envUint` and passes them at construction — set every one to a
   concrete, pool-sized value or the deploy reverts. *(C-1, H-3, pass-5 F14)*
3. **`Treasury.setMaxConvertPerCall` / `setMaxWethConvertPerCall`** still default permissive — set both to
   pool-sized ceilings at launch. `Deploy` auto-arms **`ClaimManager.lockEngines()`** and
   **`Treasury.lockRouting()`** at the end of wiring (pass-5 F1/F2) — verify the four engine↔vault bindings
   and the routing destinations on-chain **before** relying on them being final. *(H-1/H-3, pass-5 F1/F2)*
4. After the NFT mint closes: **`finalizeLaunch()`** (seals rarity), then **`withdrawProceeds()`**. *(H-13)*
5. **GO-LIVE (H-2):** from the deployer key, `poolManager.initialize(canonicalPoolKey, sqrtPriceX96)` **then
   seed LP immediately** (back-to-back, ideally one multicall/block). Initialize stamps `launchTime` and opens
   the first-hour gate; a gap between initialize and LP silently shortens the effective gate. **LP is now
   gated (pass-5 F6): the seed tx must be signed by the `initializer` EOA (the deployer) — `beforeAddLiquidity`
   reverts unless `tx.origin == initializer`.** Any later LP adds must likewise come from that key;
   permissionless community LP is disabled by design (the canonical pool's depth is protocol-provided).
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

## 11. Fourth pass — independent audit (commit `93e5790`) — 1C / 4H / 1MH / 9M / 4L / 1I (20 findings)

A deep multi-agent audit. Every code-fixable finding is fixed (local suite: **157 tests green**, a
regression per fix); the rest are governance-covered (now partly hardened in code), a documented design
decision, verified against QUOTRON's source, or pre-mainnet operational/crypto checks.

### Fixed in code

| # | Sev | Finding | Change |
|---|---|---|---|
| **F3** | High | `HolderDrawEngine.snapshot()` was permissionless + **chunked**, so an attacker could choose each token's freeze instant (buy → `snapshot(1)` → sell, serially) and capture draw slots with transient capital (~250×), or a seller could freeze a buyer out | Snapshot is now **ATOMIC** — one transaction freezes all 250 tokens at a single block, so eligibility requires actually holding the NFTs at that instant. Added a public `snapshotOwnerOf` getter so a buyer can check. The old chunked griefing vector (pinning the cursor to block `setExcluded`) is gone with it. |
| **F5** | High | `RaffleEngine`/`LeaderboardEngine` `minPot` defaulted to `0` and setters accepted `0` (unlike Jackpot/HolderDraw) — the config-independent guard only floored at wei-scale, so a dust donation could consume a draw window, and on Raffle **destroy real purchased tickets** | `minPot` is now a **required (> 0) constructor argument** on both, and the setters reject `0` — fail-closed on-chain like the sibling engines. |
| **F10** | Med | `Treasury.convert()`'s QPULL leg output (bounded by the deep pool) could exceed the WETH-leg cap (sized for the shallow QUOTRON pool), so unprocessed WETH grew every call instead of draining | The QPULL leg now also skips when a full WETH slice is already backed up (`wethHeld >= maxWethConvertPerCall`), draining the WETH backlog first so the two legs can't diverge. |
| **F14** | Med | Three registries' `setRecorder` were re-settable — a compromised owner could point the recorder at an EOA, forge unlimited game entries, then restore it | `setRecorder` is **write-once** (+ zero-check) on all three registries. |
| **F15** | Med | `PackRegistry.setEngine` was re-settable and `drawFrom`'s `k` had no internal cap — a re-registered malicious engine could pop **every** live ticket | `setEngine`/`setNft` are **write-once**, and `drawFrom` **clamps `k`** to `MAX_TICKETS_CEILING` internally (independent of the caller). |
| **F16** | Low | `RaffleEngine.runDraw`'s zero-winner branch set `drawn[day]=true` before returning (unlike the siblings), permanently forgoing a day on an empty window | `drawn[day]=true` is moved **after** the zero-winner check, allowing a retry. |

### Governance-covered (now partly hardened in code)

| # | Sev | Disposition |
|---|---|---|
| **F1** | Critical* | `ClaimManager.setEngine` is owner-settable — a compromised owner could bind an EOA as an "engine" and drain a vault. *Owner-trust* (needs the owner key). Blast radius is now reduced in code — an engine is bound to **one** vault (M-1), the `PackRegistry` engine/recorder bindings are **write-once** (F14/F15), and `drawFrom`'s `k` is clamped (F15) — but `ClaimManager.setEngine` itself stays re-settable (it must bind four engines at deploy) so the residual is the governance model (§2) + renouncing `ClaimManager` ownership after wiring. Rated Critical by the auditor **on the premise that the §2 timelock is not in code** — which §2 now states plainly. |
| **F2** | High | **Corrected in §2.** There is no on-chain timelock/pause; the model is "transfer ownership to an external timelock+multisig at launch, verify on-chain." The doc no longer implies a code-level timelock. |
| **F11** | Med | `setWinnersPerDay` has no cooldown (unlike `setTicketPrice`). Owner-trust: a reactive retune after a public beacon needs the owner key; the §2 timelock (delay > the 1-day draw window) prevents in-window reaction. Documented; not code-hardened (a cooldown wouldn't fully close it while the owner can set it before the window). |

### RESOLVED in pass-5 (§12 F6) — was an open design decision

| # | Sev | Decision → resolution |
|---|---|---|
| **F4** | High | `QpullTaxHook` implemented only swap callbacks (`0x1044`), so **adding/removing concentrated liquidity bypassed the 4% tax and the first-hour gate** — a single-sided LP position was an untaxed route to acquire/dispose of QPULL, undermining the tax that funds the games. **Decided + built (pass-5 F6): restrict LP to the protocol.** The hook now carries the `BEFORE_ADD_LIQUIDITY` flag (`REQUIRED_FLAGS = 0x1844`) and a `beforeAddLiquidity` callback that reverts unless `tx.origin == initializer`; the hook address was re-mined. Because no third party can ADD liquidity, none can hold a position to exploit — so gating add alone closes both directions. Trade-off (accepted): no permissionless community LP; the canonical pool's depth is protocol-provided. |

### Accepted / verified against source / conditional

| # | Sev | Disposition |
|---|---|---|
| **F6, F8** | MH/Med | `tx.origin` reward attribution (a relayer/bundler captures the batch's rewards; reward base is always QPULL). Accepted tradeoff (§8): `tx.origin` is the one unspoofable identity for the gate; rewards can mis-credit but never mis-charge, and every buy-side reward is **−EV to farm** by design, which bounds the "reward discount" economically. Not patchable (immutable hook). |
| **F7** | Med | First-hour gate rentability via a transferable NFT — accepted, perk-only, immutable (§8, §10). |
| **F9** | Med | `Treasury.convert()` keeper slippage / team-cut-before-swap — keeper-trust (M-2): no trustworthy on-chain QUOTRON price reference (shallow pool → manipulable TWAP); mitigated by the keeper gate (rotatable), `maxConvertPerCall`, and `maxWethConvertPerCall`. Documented. |
| **F12, F13, F17** | Med/Low | QUOTRON-dependent (codehash-ban across the shared-codehash vaults; `payOut` shortfall; oversized-pot whole-unit gas). **Verified against QUOTRON's source (§10):** it is not fee-on-transfer and does not reduce balances outside a holder's own transfer, so M-6/M-8 don't apply in normal operation; the residual is the QUOTRON-admin trust surface documented in §10 and gated by the §9 launch check. No owner rescue is added deliberately (it would contradict "no admin can drain a vault"). |
| **F18, F19** | Low | `runDraw` gas at `MAX_K=200` (fork-test against real QUOTRON pre-mainnet); `withdrawProceeds` return-data-bomb (recipients are **frozen, owner-chosen** — self-harm, not attacker-reachable). Documented as pre-mainnet checks. |
| **F20** | Info | BLS soundness rests on the `0x0f` precompile's subgroup check. The precompile is **confirmed present and correct for valid inputs on both RH mainnet and testnet** (§ H-4, direct `eth_call`); the specific subgroup-validation property still warrants the dedicated cryptographic review the code's NatSpec already requests. |

*F1 severity reflects the auditor's timelock-absent premise; under the §2 governance model it is owner-trust.

---

## 12. Fifth pass — independent audit (commit `7db9056`) — 3H / 2M / 9L / 6I (20-agent, 3-phase)

An independent 20-agent, three-phase audit (context → 8 breadth domains → 12 blind depth agents). Its finding
IDs (F1–F14) are this pass's own and are **unrelated to pass-4's F-numbers**. Every finding was
adversarially re-verified against source (and the live RH chain where relevant) before action; the
convergent theme was the codebase's own **write-once pattern not being applied to a few authority bindings**.
Local suite: **179 tests green** (+22 regressions). Its F6 (the LP/tax gap = pass-4's open F4) was actioned
this pass — restrict LP to the protocol — so it is in **Fixed in code**, not accepted.

### Fixed in code

| # | Sev | Finding | Change |
|---|---|---|---|
| **F1** | High | `ClaimManager.setEngine` was the lone re-settable authority gate (every sibling binding is write-once), so a compromised owner could rebind an engine to an attacker contract and drain each vault's **free** balance | Added one-way **`lockEngines()`** — the four engine↔vault bindings stay mutable through launch wiring (preserving the M-1 de-auth lever), then the owner freezes them forever. `Deploy`/`DeployTestnet` arm it at the end of wiring. Reserved winner claims were never reachable (the `payOut` guard). |
| **F2** | High | `Treasury.setRouting` was re-settable, so a compromised owner could redirect **all** converted prize funding + the 20% team cut | Added one-way **`lockRouting()`**, armed by the deploy scripts after `setRouting`. The keeper role is left rotatable by design (its only residual is the bounded, cap-limited convert MEV — F9/M-2). |
| **F5** | Med | Both adapters' `setTreasury` were re-settable despite a "set once" comment; since `QpullWethAdapter` is the hook's immutable `exemptSender`, re-pointing it grants a permanent **0%-tax** QPULL→WETH route (or DoSes `convert()`) | `setTreasury` is now **write-once** (+ zero-check) on both adapters, mirroring `setPoolKey`. |
| **F14** | Low | `potCap` defaulted to `type(uint256).max` in Raffle/Jackpot/Leaderboard (only HolderDraw required it), and the deploy scripts never capped Jackpot/Leaderboard at all — a sole entrant in a quiet period could capture a whole rolled-forward vault balance | `potCap` is now a **required (> 0) constructor argument** in all four engines, cross-checked `minPot ≤ potCap`, matching HolderDraw + `minPot`. `Deploy` reads `RAFFLE_/JACKPOT_/LEADERBOARD_POT_CAP` (fail-closed `vm.envUint`) and passes them at construction. |
| **F7** | Low | `QuotronRouterAdapter` accepted ETH (`receive`) with no rescue — a router refund or force-sent ETH would strand | Added owner-only **`sweepETH(to)`** (touches no WETH/QUOTRON accounting — the adapter holds neither between calls). |
| **F10** | Low | The whole randomness system is a hard liveness dependency on the EIP-2537 precompiles; a staticcall to a missing precompile returns success with **empty** data (silent) | `BlsDrandOracle`'s constructor now **probes G1ADD + PAIRING and reverts `PrecompileUnavailable`** if absent — an on-chain fail-closed deploy gate (the script `bls_precompile_check.sh` made mandatory in code). |
| **F13** | Low | `renounceOwnership` was callable everywhere; renouncing a contract that still needs its owner (engine `setPotCap`, `PackRegistry` re-peg, `Treasury` keeper rotation) permanently bricks those knobs | New `NonRenounceableOwnable2Step` base reverts renounce on the six contracts needing a live owner (engines, `PackRegistry`, `Treasury`); two-step transfer to the launch timelock is unaffected. Contracts whose owner is vestigial post-launch (vaults, registries, NFT, adapters) keep the standard base. |
| **F6** | Low→High | LP add/remove ran no hook code (flags `0x1044`), so the 4% tax + first-hour gate didn't cover liquidity ops — an untaxed side-door to acquire/dispose QPULL (also **pass-4's open F4**). **Restrict LP to the protocol:** the hook now carries `BEFORE_ADD_LIQUIDITY` (`REQUIRED_FLAGS = 0x1844`) and a `beforeAddLiquidity` gate reverting unless `tx.origin == initializer`; the CREATE2 hook address was re-mined; deploy scripts + all hook tests updated. Gating **add** alone closes both directions (no non-protocol position can exist to remove). Trade-off (accepted): no permissionless community LP. |

### Confirmed but accepted / documented (no code change)

| # | Sev | Disposition |
|---|---|---|
| **F3** | High | External QUOTRON admin (pause / blacklist / `bannedVenueCodehash`) can freeze all payouts. Already documented (§9 launch check, §10 trust note). Options weighed: a rescue path re-introduces the vault-drain lever the immutable-controller design removed (rejected); "distinct bytecode per vault" is defeated by QUOTRON's **global** pause and per-address blacklist (security theater). **Doc, not code.** |
| **F4** | Med | Raffle (1h) + pack-tier (≤1d) reveal-lag structurally cannot exceed the sequencer's 4-day back-dating bound — the daily cadence must leave a same-following-day draw window. This is the documented **M-7** trusted-sequencer residual (Jackpot 5d / HolderDraw 4.5d are code-enforced). No in-scope fix without changing the game cadence. |
| ~~**F6**~~ | — | **Moved to Fixed in code above** (protocol-only LP built; hook re-mined to `0x1844`). This was pass-4's open F4. |
| **F8** | Low | `HolderDrawEngine.snapshot()` permits single-block (transient) holding eligibility — inherent to any instant snapshot. The atomic snapshot (pass-4 F3) closed the *serial* exploit; the beacon is time-locked so a renter buys only a proportional chance, bounded by `potCap`. Documented (§3 H-5); a multi-block snapshot is future work. |
| **F9** | Low | Jackpot/HolderDraw `REVEAL_LAG` is hardcoded against the L1 `SequencerInbox.maxTimeVariation` (re-verified on-chain = 4 days; margins 1d / 0.5d). An L2 can't read its own L1 inbox, so no dynamic fix — **runbook: monitor `maxTimeVariation` and treat an increase as a governance event.** |
| **F11** | Low | **Refuted as a DoS.** The `ReentrancyGuardTransient` guard is redundant given `onlyPoolManager` + the PoolManager's unlock-lock, and TSTORE is **proven live on both RH chains** (V4 PoolManager, which requires it, runs there). Kept as belt-and-braces; dropping it would force a hook re-mine for zero gain. |
| **F12** | Low | **Refuted for RH.** Probed block `gasLimit` = `0x4000000000000` (2⁵⁰) on both chains — the ~6.4M snapshot and K=200 draw fit with orders of magnitude of headroom (loops are hard-bounded at SUPPLY=250 / MAX_K=200). |

**Leads** (sub-threshold, flagged): keeper-self-sandwich (= F9/M-2, governance), `claimBatch` payout-revert coupling (self-mitigable — the caller drops the bad id / uses single `claim`), fee-on-transfer solvency (QUOTRON verified non-FoT), Treasury no-rescue-if-QUOTRON-pool-illiquid (same disposition as F3 — no owner rescue by design). **Informational** I1–I6 (rounding favors the trader <1 wei; `setEngine` framing = F1; ETH-sweep = F7; void-window availability; `roundAt` convention pending the crypto review; JackpotEngine reads the beacon before its void checks — a gracefulness asymmetry, retryable either way) all accepted.

---

## 13. Sixth pass — independent audit (job 745, commit `24a36cc`) — 0C / 0H / 4M / 12L / 15I

No Critical and no High. Every code-fixable finding is fixed; the local suite is **186 tests green** after
remediation (was 179). New regression tests: `test_M3_*`, `test_M4_*`, `test_L1_*`, `test_L2_*`, `test_L3_*`,
`test_L5_*`, plus mocks `MockBlacklistERC20` and `MockRevertOnAmountERC20`.

### Fixed in code

| # | Sev | Finding & fix |
|---|-----|---------------|
| **M3** | Med | `Treasury.convert()` split the prize QUOTRON with three `safeTransfer`s — if QUOTRON **blacklisted any one prize vault**, the whole conversion reverted and *all* prize routing bricked. **Fix:** each leg now goes through `_trySendQuotron` (a low-level `call` that swallows a failed transfer), and the split is taken on the **full** QUOTRON balance (`qBal`), not the swap delta — so a stuck slice stays in the Treasury and is **auto-retried on the next convert()**, never lost. The `minQuotronOut` floor still keys on the this-swap delta. |
| **M4** | Med | `setPotCap` let the owner re-peg a single day's payout arbitrarily in one tx (a compromised-owner inflate/deflate lever). **Fix:** re-pegs are bounded to **±25% per cooldown** (`MAX_ADJ_BPS = 2500`; cooldown = DAY raffle / 14d jackpot / 7d leaderboard), via `lastPotAdjust` + errors `AdjustTooSoon` / `AdjustOutOfBounds`. `BadPotCap` (≥ minPot) is still checked first; `setMinPot` is not rate-limited. |
| **L1** | Low | The LP gate (pass-5 F6) covered **add** but not **remove**, so the remove path ran no hook code. **Fix:** added `beforeRemoveLiquidity` applying the same `_onlyProtocolLp` initializer gate; `REQUIRED_FLAGS` gains `BEFORE_REMOVE_LIQUIDITY (1<<9)` → **`0x1844`→`0x1A44`**, hook re-mined, deploy scripts + all `FLAGS` test constants updated. |
| **L2** | Low | `lockEngines()` could freeze an **incomplete/mismatched** binding set. **Fix:** it now requires `n != 0 && n == vaults.length` and that every `engineVault[engines[i]] == vaults[i]` (non-zero) before locking — else `IncompleteBindings`. |
| **L3** | Low | `lockRouting()` froze `setRouting` but **not `setAdapters`**, leaving a post-lock way to redirect conversion through a swapped adapter. **Fix:** `setAdapters` now reverts `RoutingAlreadyLocked` once routing is locked. |
| **L4** | Low | Deploy did not assert the HolderDraw and Raffle engines share a `genesis`. **Fix:** `Deploy.s.sol` / `DeployTestnet.s.sol` add `require(HolderDrawEngine.genesis() == RaffleEngine.genesis())`. |
| **L5** | Low | A single reverting payout inside `claimBatch` reverted the **whole batch** (griefing). **Fix:** each payout runs as `try this.settleSelf(id) { ++claimed } catch {}`; a reverting claim is left **unsettled + still reserved** for a plain retry, and every other claim in the batch still pays. `settleSelf` deliberately carries **no** `nonReentrant` (the batch already holds the guard). |
| **L7** | Low | `QpullWethAdapter` negated an `int128` before widening, mishandling the `type(int128).min` edge. **Fix:** promote to `int256` before negation. |
| **L9** | Low | `BlsDrandOracle` probed only the `PAIRING` precompile at construction. **Fix:** also `staticcall` `MAP_FP_TO_G1` and require a 128-byte reply, else `PrecompileUnavailable`. |
| **Info** | Info | `convert()` skips the team-WETH transfer when the computed team cut is 0 (`if (teamWeth > 0)`), avoiding a needless zero-value transfer. |

### Accepted / documented (no code change)

| # | Sev | Disposition |
|---|-----|-------------|
| **M1** | Med | The `convert()` **keeper is a hot key** by design (rotatable, deliberately not frozen by `lockRouting`). Trust is bounded to *timing* — it cannot change destinations (routing is lockable) or amounts (fixed BPS). Runbook item; same class as F9/M-2. |
| **M2** | Med | Sequencer `delaySeconds` / oracle liveness (= pass-5 M-7). Re-verified on-chain (RH `SequencerInbox.maxTimeVariation.delaySeconds` = 4 days); `REVEAL_LAG` margins hold. Monitored as a governance event. |
| **L6** | Low | A QUOTRON pause would stall `convert()`. Same disposition as F3 — no owner rescue by design; funds are never lost, only delayed until unpause. |
| **L8** | Low | Holder-draw eligibility reads live balances (a flash-hold could momentarily qualify). Accepted: the draw is **mint-seeded**, not tax-funded, and the snapshot semantics are documented. |
| **L10–L12 / I1–I15** | Low/Info | Refuted or documented (rounding <1 wei favors the trader; framing duplicates of F1/F7; convention/gracefulness notes). No code impact. |

*Residual pre-mainnet recommendations are unchanged: a dedicated cryptographic review of `BlsDrandOracle`
and a **V4-hook specialist review of `QpullTaxHook`** — the latter also being the artifact a Uniswap-interface
hook-allowlist submission would require.*

---

## 14. Seventh pass — independent 3-phase multi-agent audit (commit `a428ef4`) — 0C / 0H / 4M / 12L / 17I

An independent three-phase pipeline (context → 8 breadth agents → 12 attacker-mindset agents → synthesis) on
the pushed pass-6 code. **No Critical, no High.** Most findings independently re-confirmed residuals we had
already documented; three were genuinely new — one a real flaw in the pass-6 M3 convert fix.

### Fixed in code (pass-7)
| # | Sev | Finding & fix |
|---|-----|---------------|
| **M-2** | Med | `convert()`'s M3 blacklist-isolation retried a stuck vault's QUOTRON slice via the next call's FULL-balance split, redistributing ~92% of it to the sibling games. **Fix:** a per-vault `quotronOwed` ledger — a failed send is credited to that vault and retried ONLY to it (`_trySendQuotron` folds each vault's own `owed` back in; the split now applies to `splittable` = balance − owed). Stuck slices reach their own game, never siblings. |
| **L-10** | Low | `setMinPot` was the unguarded twin of the rate-limited `setPotCap` — an owner could slam `minPot` above a known winner's pot to force the void branch. **Fix:** `setMinPot` now carries the same per-engine cooldown (`lastMinPotAdjust`) on all four engines. |
| **L-11** | Low | `HolderDrawEngine.setExcluded` NatSpec had two contradictory blocks (one describing a mid-snapshot guard removed in the atomic-snapshot redesign). **Fix:** one accurate block; documents that exclusion only affects weeks whose snapshot hasn't run. |
| **L-2** | Low | Sub-25-unit dust swaps round the 4% fee to 0 yet earned game credit. **Fix:** game-registry credit gated on `fee > 0` (kept the round-DOWN so the exact-4% invariant holds). |
| **new** | feat | `NFTCollection`: `MAX_PER_WALLET = 5` per-wallet mint cap (`mintedBy` tracking + `WalletLimit`) for fairer distribution. |

### Accepted / documented (no code change)
| # | Sev | Disposition |
|---|-----|-------------|
| **M-1** | Med | Daily-raffle/tier/rarity reveal-lag (1h) can't exceed RH's 4-day sequencer back-date bound (daily cadence needs a same-following-day window) — trusted-sequencer residual (= our M-7/F4). Jackpot (5d)/HolderDraw (4.5d) exceed it, code-enforced. |
| **M-3** | Med | `convert()` off-chain slippage + never-lockable keeper = our keeper-trust (M-2); bounded by `maxConvertPerCall`, mitigated by the timelock migration. |
| **M-4** | Med | Pre-migration EOA-owner window could cement a bad config — resolved by transferring ownership to the timelock+multisig *before* setting/locking bindings (runbook). |
| **L-6** | Low | Conversion sizing knobs intentionally NOT frozen by `lockRouting` — tuned to pool depth at go-live and may need ongoing tuning; owner-griefing is bounded/reversible, mitigated by the timelock. |
| **L-8** | Low | `runDraw` reverting on an un-posted cohort tier beacon is fail-closed + retryable (no tickets consumed); a "skip" would consume the ticket for no payout. Keeper (`prep-draw.js`) posts all in-window beacons first. |
| **L-12** | Low | `HolderDrawEngine` has no on-chain registry peer to constructor-cross-check `genesis`; cross-checked at deploy (`Deploy` asserts `HolderDraw.genesis() == Raffle.genesis()`, pass-6 L4). |
| **L-1/L-3/L-5** | Low | HolderDraw flash-hold (=H-5/F8), QUOTRON freeze no-rescue (=F3/L6), immutable oracle (=L5) — prior accepted residuals. |
| L-4/L-7/L-9/I* | Low/Info | Adapter on-chain deadline (backstopped by `minOut`), renounce-before-wiring ordering (runbook), jackpot rollover-farming (Lead, needs live-data), + informationals — accepted/documented. |

*Local suite: **188 tests green** after pass-7 (+ regression tests: M-2 own-vault retry, L-10 cooldown, per-wallet cap). Two co-requested features — the NFT standing-entry model (Option B) and a first-hour buy cap+cooldown — are **deferred** to a separate pass: they materially change the raffle-draw / hook-swap paths and warrant dedicated design + test work, not a rushed pre-audit change.*

---

*This remediation was prepared with AI assistance and is not a substitute for an independent human security
review. A dedicated cryptographic review of `BlsDrandOracle` and a **V4-hook specialist review of
`QpullTaxHook`** remain recommended before mainnet. QUOTRON's ERC-404 semantics (M-6/M-8), Robinhood
Chain's EIP-2537 support (H-4), and its sequencer `delaySeconds` (M-7) have all been verified on-chain /
against source and are addressed above; the residual QUOTRON-admin trust surface is documented and gated
by the §9 launch check. Pass-4's F4 / pass-5's F6 (V4 liquidity-callback tax gap) is now **resolved** —
liquidity provision is restricted to the protocol, with the gate covering both ADD and REMOVE after
pass-6's L1 (hook re-mined to `0x1A44`, §12–13).*
