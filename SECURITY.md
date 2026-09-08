# QPULL — Audit Remediation & Security Model

This document tracks the external AI audits of `qpull-contracts` across seven written-up passes (pass 6 in
**§13**, the latest 3-phase multi-agent pass in **§14**). **Pass-8 remediation, the pass-9 launch overhaul, and
the pass-11 tiered time-boxed mint have since landed in code and are indexed, not yet fully written up, in
§15; read it before treating §§1-14 as a complete picture of the current tree.** **§16 states, in one place,
the accepted residuals and the operational posture (no pause, no kill switch, lock timing, drand fallback);
auditors should read it first.**

> ## POST-AUDIT CHANGE: standalone jackpot removed (read before the findings below)
>
> After the last written-up pass, the standalone trade-based jackpot game was deleted: `JackpotEngine.sol`,
> `JackpotRegistry.sol`, the `IJackpotRegistry` interface, and the `jackpotVault` no longer exist, and
> `QpullTaxHook` no longer records jackpot entries (its `HookConfig.jackpotRegistry` field is gone; the hook's
> `REQUIRED_FLAGS` stay `0x1A44`). The jackpot's **6.25% tax share** (the former `JACKPOT_BPS = 625`) is
> redirected to the **holder draw**: `Treasury` renames that slot to `holderVault` / `HOLDER_BPS = 625` and
> routes the share there on every `convert()`. This makes the weekly holder draw (`HolderDrawEngine`)
> **tax-funded** (it was seed-only before) and removes a duplicate game.
>
> **Final trade-tax split:** daily raffle 61.25% (`HOURLY_BPS = 6125`), leaderboard 12.5%
> (`LEADERBOARD_BPS = 1250`), holder draw 6.25% (`HOLDER_BPS = 625`), team 20% (`TEAM_BPS = 2000`).
> `PRIZE_BPS = 6125 + 625 + 1250 = 8000` and `TEAM_BPS = 2000` are unchanged; only the jackpot slot became the
> holder slot, so the split math is identical. `Treasury.setRouting(prize, holder, leaderboard, team)` keeps
> its positional argument order.
>
> **How to read the findings below:** every finding that references `JackpotEngine`, `JackpotRegistry`,
> `IJackpotRegistry`, or `jackpotVault` is retained for the audit record but **no longer describes deployed
> code**. Compound findings once applied across "all four engines" (Raffle / Jackpot / Leaderboard /
> HolderDraw) now apply to the **three** that remain (Raffle / Leaderboard / HolderDraw); their fixes are
> unchanged on those three. The standalone jackpot's own reveal-lag, pot-cap, and dust-floor findings are moot.

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
  `0x1844` with a `beforeAddLiquidity` gate — **superseded by pass-6 L1 below**, which adds the symmetric
  remove gate and re-mines to the current **`0x1A44`**).
- **Pass 6, an independent audit** (commit `24a36cc`, 0C/0H/4M/12L/15I) — remediation in **§13**. No Critical
  or High. Every code-fixable finding is fixed (local suite: **186 tests green**): convert() no longer bricks
  if one prize vault is QUOTRON-blacklisted (M3), pot-cap re-pegs are rate-limited to ±25%/cooldown (M4),
  the LP gate now also covers **remove** (L1, hook re-mined `0x1844`→`0x1A44`), and `claimBatch` survives a
  single reverting payout (L5).
- **Pass 7, an independent 3-phase multi-agent audit** (commit `a428ef4`, 0C/0H/4M/12L/17I) — remediation in
  **§14**. No Critical or High; one genuinely new Med (a flaw in pass-6's own M3 convert fix).
- **Pass 8 remediation, the pass-9 launch overhaul, and the pass-11 tiered time-boxed mint** landed in code
  **after** the §14 write-up; indexed in **§15**, dispositions still owed. `MAX_SUPPLY` 250 to **3500**, the
  tiered time-boxed self-closing mint (one owner start, then GTD to overflow to public by elapsed time,
  superseding pass-9's owner-triggered phase machine), and the matching removal of the old
  `HolderDrawEngine.SUPPLY` coupling are **new, un-audited surface**.

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
(`RaffleEngine`, `HolderDrawEngine`, `PackRegistry`, `NFTCollection`)? A dedicated
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
ERC-20. *Invariant:* every canonical-pool trade pays exactly the scheduled rate — **4% on buys always, and
4% on sells except inside the immutable 48h launch anti-dump decay (20/16/12/8% → 4%, §8)** — credits the
intended game entries to the real swapper, and no trade can brick the pool; plain (non-trade) transfers are
untaxed. *Defenses:* the hook
is fully immutable (no owner/setters); the fee is taken inside the locked context via `take()`; attribution
uses `tx.origin`; registry fan-out is `try/catch` so a reverting registry costs only that trade's rewards;
`afterInitialize` restricts pool creation to the deployer's canonical pool. *Please double-check:* the
`afterSwap` delta sign/currency for all four swap shapes, that `take(fee)` + the returned `+fee` delta always
net to a settled unlock, the `exemptSender` (conversion) path, and any way to farm registry rewards or evade
the fee. This surface received a dedicated internal adversarial review (§8) but a **human V4-hook specialist
sign-off is still recommended before mainnet** — hooks are V4's most dangerous surface.

The **accepted, bounded risks** are catalogued in §3 — we welcome disagreement with our reasoning there.
Before writing findings, please also read the two sections immediately below: **Out of scope** (features that
are discussed elsewhere but deliberately **not built**) and **External dependency assumptions** (three
off-repo facts already evidenced on-chain, offered so the engagement is not spent re-deriving them).

---

## Out of scope — deliberately deferred (do NOT assume this code exists)

Two features are discussed in the product thread and in pass-7's closing note (§14) but are **not built and
not in this tree**. They are listed here so no finding is written against imagined code, and so their absence
reads as a decision rather than an oversight. Neither is a partial implementation: there is **no dormant
code, no unset flag, no disabled branch, and no storage slot** reserved for either. If a review turns up
anything that looks like a stub or hook for them, that itself is a finding.

| Deferred feature | What ships instead | Why it is deferred |
|---|---|---|
| **NFT standing-entry model ("Option B").** A pass would confer a *standing* daily-raffle entry for as long as it is held — entries computed from NFT ownership **at draw time**, no claim tx, no gas, no keeper — with per-rarity counts raised to **SR 12 / Rare 6 / Uncommon 4 / Common 3**. | The **claim model only**: `PackRegistry.claimFreeEntries(tokenIds)` mints that day's free tickets on demand, rarity-weighted **SR 10 / Rare 4 / Uncommon 2 / Common 1** (`_freeEntries`), each holder claiming per day, bounded by `FREE_CAP_BPS` (free ≤ 20% of that day's paid tickets). The draw pulls from **minted, burnable tickets** in `cohortLive`. | Option B replaces the draw's entry source with an ownership-weighted computation at draw time, i.e. a second perpetual entry class that is not a burnable ticket, with its own snapshot/eligibility semantics. That is a rewrite of the audited raffle-draw path, not a parameter change — it needs a fresh deploy and its own audit, not a rushed pre-audit edit. |
| **Launch-window buy cap + cooldown** ("fair phase"; originally scoped as "first-hour", the window is 2h). **SUPERSEDED: this was later BUILT** as the spec §16 launch throttle (`QpullTaxHook._throttleEarlyBuy`), so it is no longer out of scope; the row stays so the "deferred" references in §14 resolve. | The shipped hook enforces, inside `GATE_DURATION()` (2h): the NFT-holder gate keyed to `tx.origin`, a `BUY_COOLDOWN()` (2 min) between one wallet's gated buys, a per-buy WETH size cap (`earlyBuyCapWei`, 0.25 ether) on a wallet's first `EARLY_BUY_COUNT = 10` gated buys, and the flag-on-buy pass transfer-lock; plus the immutable 48h decaying **sell** tax (20/16/12/8% → 4%). Buys after the tenth stay paced by the cooldown but are uncapped in size (accepted ceiling, §16.5). | The mutable per-wallet state now lives inside `afterSwap` by design and is covered by the hook test suite. It is new surface relative to the §§1-14 write-ups and needs the same V4-hook specialist attention as the rest of the hook. |

**Scope consequence for the auditor:** the launch gate + throttle is a **perk, not fund-safety** (§10 L-8/L-12,
§11 F7). The per-buy size cap covers only a wallet's first 10 gated buys, so "a holder can still accumulate a
large position inside the 2h window" is the shipped, documented ceiling, not a missing control (§16.5). Findings
on the still-deferred standing-entry model are welcome as **design input for the next pass**, but it is not
remediable in this codebase.

---

## External dependency assumptions — verify as evidence, do not re-derive

Three facts sit **outside this repo** and the code is written against them. Each has already been checked
against the live chain or against verified third-party source; the artifacts are cited so a reviewer can
**confirm the evidence** rather than spend the engagement re-deriving it. All three are also **launch gates**
in `LAUNCH-CHECKLIST.md` (§5) and must be re-confirmed against the final deploy target.

**1. EIP-2537 BLS precompiles exist on the target chain.** `BlsDrandOracle` is the fairness root and calls
`G1ADD (0x0b)`, `MAP_FP_TO_G1 (0x10)`, and `PAIRING (0x0f)` directly. A staticcall to an *absent* precompile
returns `success` with **empty** data, so absence is silent rather than a revert.
*Evidence to verify, not reproduce:* **confirmed live on RH mainnet on 2026-09-02** by a **read-only**
`eth_call` pairing check against a **real drand quicknet beacon** (round 1000) — the valid signature verified
to the pairing identity, and a tampered signature was rejected as not-on-curve. `G1ADD` / `PAIRING` /
`MAP_FP_TO_G1` are all present and return exactly what the oracle's constructor gate requires.
*Code-side defense:* the constructor **probes all three and reverts `PrecompileUnavailable`** (pass-5 F10,
pass-6 L9), so a chain missing any of them fails the deploy closed rather than the first draw.
*Still open (F20):* the **subgroup / canonical-encoding validation property** of `0x0f` is delegated, not
proven here — that is the dedicated cryptographic review still recommended.

**2. RH `SequencerInbox.maxTimeVariation.delaySeconds` stays below the `REVEAL_LAG` margins.** The
sealed-then-revealed guarantee is code-enforced **iff** `REVEAL_LAG > delaySeconds`, because an
Arbitrum-family sequencer may back-date `block.timestamp` by up to that bound.
*Evidence to verify, not reproduce:* read directly from the inbox **on Ethereum L1** (not on RH) at
`0xBd0D173EEb87D57A09521c24388a12789F33ba96` → `delaySeconds = 345_600` (**4 days**), `futureSeconds = 3_600`
(1h). *Margin as shipped:* `HolderDrawEngine.REVEAL_LAG() = 4 days + 12 hours` (**12-hour margin**) exceeds the
bound, so the highest-value randomized draw (the weekly holder draw) is code-enforced even against a maximally
back-dating sequencer. (The standalone jackpot that formerly carried a 5-day `REVEAL_LAG` has been removed; see
the post-audit banner at the top.)
*The documented residual:* `RaffleEngine.REVEAL_LAG = 1 hours` and the pack-tier reveal (≤ 1 day)
**structurally cannot** clear a 4-day bound without breaking the daily cadence, so they rest on the standard
trusted-sequencer assumption every Arbitrum L2 already carries (= M-7 / pass-5 F4 / pass-7 M-1).
*Operational:* an L2 cannot read its own L1 inbox, so there is **no dynamic fix** — an increase to
`delaySeconds` is a **governance event to monitor**, not something the contracts can detect (pass-5 F9).

**3. QUOTRON's admin controls can freeze payouts.** QUOTRON is an **external, admin-controlled ERC-404**
(`Quotron404V2`, 18 dec, verified source on RH Blockscout). `_checkTransferAllowed` gates **every** transfer
on a global **`paused`** flag, a per-address **blacklist** (`from` / `to` / `msg.sender`), and a
**`bannedVenueCodehash`** check — and `adminTransferTerminal` can move a whole unit out of any account.
*What this repo depends on:* the four `BaseVault`s (which **share one codehash**), `ClaimManager`, and
`Treasury` must all be transfer-eligible or prize *liveness* stops. Funds are never lost, only frozen until
unpause (§13 L6).
*Evidence to verify, not reproduce:* QUOTRON's source was read directly and two feared behaviors were
**refuted** — it is **not fee-on-transfer** (`_transfer` credits the full amount; reflections pay in a
separate stock token), and the whole-unit rebalance (`_syncDown`/`_syncUp`) mutates only the NFT layer, not
`balanceOf`, so third-party trading cannot reduce a vault's fractional balance (§10 M-6 / M-8).
*The irreducible residual:* whoever controls QUOTRON's pause / blacklist / codehash-ban can freeze all
payouts. **No owner rescue is added deliberately** — a rescue path would reintroduce the vault-drain lever
the immutable-controller design removes (§12 F3). Per-vault distinct bytecode is *not* a mitigation either:
the pause is global and the blacklist is per-address.
*Launch gate (§9 step 8):* confirm the vault / `ClaimManager` / `Treasury` **addresses and codehashes** are
not blacklisted or codehash-banned, and establish **who controls those switches and whether they are
timelocked**, before relying on QUOTRON for prizes.

> A fourth external is documented in `LAUNCH-CHECKLIST.md` §4 rather than here because it is a config fact,
> not a safety assumption: QUOTRON's own pool carries Uniswap's **dynamic-fee sentinel** (`0x800000`), so its
> trade fee is set at swap time by QUOTRON's `floorHook` and is **not** a fixed 3%. Nothing in this repo may
> hardcode it; `convert()` relies on the keeper's live off-chain `minQuotronOut`.

---

## 1. Fixed in code

| # | Finding | Change |
|---|---|---|
| **H-1** | Public, tax-exempt adapter = 0% sell-tax bypass | Both adapters gated to the Treasury (`setTreasury` + `require(msg.sender == treasury)`) in `QpullWethAdapter` / `QuotronRouterAdapter`. |
| **H-2** | Leaderboard unbounded catch-up + flag-before-check | Window-bound to `currentWeek()==week+1`; `distributed=true` moved below the empty-pot guard. |
| **H-3** | Jackpot flag-before-check | `drawn=true` moved below the `total/pot==0` guard. |
| **H-3B / M-9** | Jackpot timing-absorption / oversized-prize gas | Added `potCap` (owner-set, default uncapped) clamping a single draw's payout; excess rolls forward. |
| **H-7** | HolderDraw `setExcluded` post-beacon re-roll | Originally fixed by freezing exclusion into the snapshot; under Option C the snapshot is gone, so this is now enforced by making `setExcluded` a scheduled toggle that takes effect only the following period (1-week cooldown), which blocks any same-tx-as-`runDraw` re-roll (§15 pass-8 H-5, §3 H-5). |
| **H-8** | `payOut` could drain reserved prizes | `payOut` now reverts if it would dip into `unclaimedReserve`; reserved (owed) funds are protected unconditionally. Header corrected. |
| **H-12** | `setRecipients` re-settable, redirect mint proceeds | Frozen once `totalMinted > 0` + zero-address checks. |
| **H-13** | `finalizeLaunch` couples rarity seal to ETH payout | Split: `finalizeLaunch()` seals rarity only (no ETH); `withdrawProceeds()` pays each of the three **80/10/10** buckets (LP 80 / prize-seed 10 / team 10) **independently** (a reverting recipient can't block the reveal or the other buckets). |
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
| **H-5** | HolderDraw single-block ownership "rental" | Not a guaranteed win: the settling beacon is unknown before `snapDeadline`, so a holder only ever buys a *proportional* chance. There is no NFT flash-loan for a bespoke 3500-piece collection, so acquiring a large share is real, illiquid capital, and the payout is bounded by `potCap`. **Option C inverts the earlier disposition here.** The snapshot loop is deleted. `NFTCollection` stamps `ownerSince[tokenId]` in `_update` (only when `from != to`, a load-bearing self-transfer griefing guard), and `runDraw` derives 5 tokenIds from the beacon in O(1), paying live `ownerOf(tid)` **only if `ownerSince[tid] <= snapDeadline(week)`**. That is exactly the audit's "re-verify `ownerOf` at draw" recommendation, which earlier passes **rejected** as reopening the buy-after-reveal front-run. Option C **adopts** it and closes that front-run with the `ownerSince` test: a pass moved *after* `snapDeadline` but before `runDraw` makes the buyer ineligible (their `ownerSince` is too recent) AND the seller ineligible (they no longer own it), so that slot goes unseated and its flat share rolls forward. **New property the auditor must name: reorg sensitivity.** Winners are now decided by live state at `runDraw`, not a days-old snapshot. Claims register atomically, so there is no partial state, but the outcome is no longer reorg-invariant. This is acceptable on RH's single sequencer, but it is a real change from the snapshot design and is called out here rather than buried. |
| **M-6** | Distinct-5 dedup is per-address, sybil-able | A holder splitting `k` NFTs across `k` wallets earns ~`5k/SUPPLY` slots (`SUPPLY` = 3500 at launch; the ratio, not the constant, is the argument) — i.e. **proportional to holdings**, which is fair for a holder draw. The distinct-5 rule caps only naive single-wallet concentration. Any per-address scheme is sybil-able; `potCap` bounds the absolute exposure. |
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

- **Immutable** — no owner, no setters; the 4%, the launch sell-tax schedule, and the 2-hour launch holder gate
  (`GATE_DURATION()`) are all fixed by construction. A hook governs the protocol's only liquid pool, so it
  deliberately holds **no admin lever**.
- **Launch anti-dump (SELL-ONLY, 48h, immutable).** Buys are **always** `TAX_BPS = 400` (4%). Sells are taxed
  on a decaying schedule for the first 48h after `initialize()` stamps `launchTime`:
  `SELL_TAX_START_BPS = 2000` (20%) stepping down `SELL_STEP_BPS = 400` (4pp) every `SELL_STEP = 12 hours`
  — **20 / 16 / 12 / 8% → 4%** at `SELL_DECAY = 48 hours`. The elevated cut routes to the same
  Treasury/prize vaults, so early sells seed a bigger opening pot. No owner can change or extend the
  schedule; it is arithmetic over `launchTime`, with no stored per-trade state. The step arithmetic
  **saturates at `TAX_BPS`** (pre-audit hardening): a subclass decay/step ratio that would once have driven
  the subtraction below zero now floors at the flat 4% instead of underflow-reverting sells, and the
  constructor refuses a zero `SELL_STEP()` or a start rate below `TAX_BPS` (`BadSellSchedule`). *Please
  double-check:* the buy path never picks up a sell rate.
- **`afterSwap`** takes the scheduled rate (4%, or the decaying sell rate above) of the swap's *unspecified*
  currency (QPULL on buys, WETH on exact-in sells) via
  `poolManager.take(feeCurrency, treasury, fee)` and returns it as a positive hook delta — v4-core makes the
  swapper pay it (`Hooks.sol`: "the caller has to pay for the hook's delta"); the `take()` clears the hook's
  own credit inside the same unlock. Verified against **vendored v4-core v4.0.0** for all four swap shapes.
- **Launch NFT-holder gate (2 hours, `GATE_DURATION()`)** enforced on buys, keyed to `tx.origin` (an
  unspoofable identity; `hookData` is ignored as caller-supplied). Known, accepted limits: a holder using a
  **smart-contract wallet** is gated for the 2-hour window (hold the NFT on the signing EOA, or wait for
  expiry); the gate window starts at
  `initialize()`, so LP must be **seeded immediately after** (runbook §6).
- **Game fan-out** to the three registries with `tx.origin`, wrapped in `try/catch` — an immutable hook must
  never let a registry fault brick the pool (a failed record costs only that trade's rewards, `RecordFailed`).
- **`afterInitialize`** restricts pool creation: only the deployer may create the canonical pool (no
  front-run of the gate window) and no other pool may attach the hook (no reward-farm pools).
- **Address flags — `REQUIRED_FLAGS = 0x1A44`** (`AFTER_INITIALIZE (1<<12) | BEFORE_ADD_LIQUIDITY (1<<11) |
  BEFORE_REMOVE_LIQUIDITY (1<<9) | AFTER_SWAP (1<<6) | AFTER_SWAP_RETURNS_DELTA (1<<2)`), mined with a CREATE2
  salt (`script/HookMiner.sol`); `test/HookMiner.t.sol` proves the miner target and the constructor's own
  `BadFlags` self-check agree (a launch-day revert if they ever drift). **`0x1A44` is the current, shipped
  value — `src/hooks/QpullTaxHook.sol` is authoritative, and every deploy script and test `FLAGS` constant
  matches it.** The two liquidity bits arrived in sequence and each forced a re-mine, so older text in this
  file quotes older values: `BEFORE_ADD_LIQUIDITY` in pass-5 F6 (`0x1044`→`0x1844`, §12), then
  `BEFORE_REMOVE_LIQUIDITY` in pass-6 L1 (`0x1844`→**`0x1A44`**, §13). **Nothing is at `0x1844` any more.**
- **`beforeAddLiquidity` AND `beforeRemoveLiquidity`** both run the same `_onlyProtocolLp(sender, key)` gate:
  the pool must be canonical, and the liquidity provider must be the protocol (`sender == initializer` for a
  contract LP-manager, or `tx.origin == initializer` for the deployer EOA via a router) — else
  `LiquidityRestricted`. This closes the untaxed LP acquire/dispose side-door **on both legs** (pass-6 L1 added
  the remove half; before it, remove ran no hook code). **Operational notes (accepted):** (1) the gate keys on
  the initializer identity, so that key must never sign a transaction that calls untrusted code — during such a
  tx an attacker contract could add a position; it could **not** later withdraw it, because remove is now gated
  to the same identity, so a slipped-in position is stranded rather than an untaxed exit; (2) because the hook
  is immutable and the shipped `initializer` is the deployer EOA, all future LP adds **and removes** are
  permanently bound to that EOA (not migratable to the launch timelock/multisig) — keep it secured, and note
  the symmetric gate means losing that key strands the protocol's own LP. Permissionless community LP is
  disabled by design (the pool is protocol-owned liquidity; permissionless LP in a taxed-swap pool is itself
  the exploit).
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
3. **`Treasury.setMaxConvertPerCall` / `setMaxWethConvertPerCall` are FAIL-CLOSED (pre-audit 2026-09-07):** an
   unset cap (`0`) means "not configured" and `convert()` refuses to run until BOTH are set to pool-sized
   ceilings (the QPULL slice sized to the canonical pool, the WETH slice sized to the shallow QUOTRON pool).
   Set them at go-live and read back that both are `!= 0` and `!= type(uint256).max`. `Deploy` auto-arms
   **`ClaimManager.lockEngines()`** (pass-5 F1) with the exact three engine/vault pairs. **`Treasury.lockRouting()`
   is NO LONGER armed by `Deploy`:** it is the FINAL go-live step, run only after both adapter legs are
   fork-verified end-to-end against the live pools (§16.6; the ordered steps with their on-chain post-conditions
   are `LAUNCH-CHECKLIST.md` §6b). *(H-1/H-3, pass-5 F1/F2, pre-audit MEDIUM "convert caps unwired")*
4. After the NFT mint closes: **`finalizeLaunch()`** (seals rarity), then **`withdrawProceeds()`**. *(H-13)*
5. **GO-LIVE (H-2), THROUGH THE PERMANENT LOCK:** from the deployer key, run `script/GoLiveMainnet.s.sol`,
   which does `poolManager.initialize(canonicalPoolKey, sqrtPriceX96)` and then seeds LP **through
   `QpullLiquidityLock`** back-to-back (deploy the lock, move the LP WETH plus the deployer's ENTIRE QPULL
   balance into it, `lock.seed(liq)`). The lock owns the full-range position and has no remove / withdraw /
   collect path, so "can't rug" is a bytecode fact, not operator discipline. Post-conditions to read back:
   `lock.seeded() == true`, the canonical position is owned by the lock, `QPULL.balanceOf(deployer) == 0`
   (the script reverts otherwise). Initialize stamps `launchTime` and opens the launch gate; a gap between
   initialize and the seed silently shortens the effective gate. **LP is gated (pass-5 F6, pass-6 L1): the
   seed tx must be signed by the `initializer` EOA (the deployer), since `beforeAddLiquidity` /
   `beforeRemoveLiquidity` pass only for `tx.origin == initializer`.** Never seed LP directly from the deployer:
   that yields a REMOVABLE position (the hook gate restricts WHO may add or remove, not that liquidity flows
   through the no-remove lock). Permissionless community LP is disabled by design. *(pre-audit MEDIUM "go-live
   omits the lock"; `docs/LIQUIDITY-LOCK-SPEC.md`)*
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
| **M-4** | Med | `setExcluded` could run mid-snapshot, freezing an internally-inconsistent owner set | Reverted `SnapshotInProgress` while a snapshot was partway done. **Obsolete under Option C:** the snapshot (and `SnapshotInProgress`) are deleted; `setExcluded` is now a scheduled toggle taking effect the following period under a 1-week cooldown (§15 pass-8 H-5, §3 H-5), so there is no mid-snapshot window to guard. |
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
| **L-8, L-12** | Low | **Accepted (perk-only, immutable hook)** — the 2-hour launch gate is anti-snipe, not fund-safety; `tx.origin` and the launch-time window are the deliberate design (§8). No fund impact. |
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
| **F3** | High | `HolderDrawEngine.snapshot()` was permissionless + **chunked**, so an attacker could choose each token's freeze instant (buy, then `snapshot(1)`, then sell, serially) and capture draw slots with transient capital (~250x), or a seller could freeze a buyer out | **Superseded by Option C: the snapshot is DELETED entirely** (`snapshot()`, `snapComplete()`, `snapshotOwnerOf()`, `SUPPLY`, and `SNAP_WINDOW` are all removed). There is no cursor and no freeze buffer left to grief. `runDraw` derives its 5 tokenIds from the beacon in O(1) and reads live `ownerOf`, gated by the per-token `ownerSince[tid] <= snapDeadline(week)` test stamped in `NFTCollection._update` (see §3 H-5). The pass-4 remediation here was an ATOMIC snapshot (one tx freezing all `SUPPLY` tokens); atomizing the loop then hit the measured per-tx gas ceiling at `SUPPLY = 2000` (old §12 F12), which is why Option C removed the loop rather than atomize it. The holding-duration eligibility test now lives in the NFT, not a snapshot buffer, so both the chunked griefing vector and the gas blocker are closed at once. |
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
| **F11** | Med | `setWinnersPerDay` has no cooldown (unlike `setTicketPrice`). Owner-trust: a reactive retune after a public beacon needs the owner key; the §2 timelock (delay > the 1-day draw window) prevents in-window reaction. Documented; not code-hardened at this pass (a cooldown wouldn't fully close it while the owner can set it before the window). **Superseded — pass-8 H-4 added a cooldown AND the ±25% band to `setWinnersPerDay` (`lastWinnersAdjust`); see §15.** |

### RESOLVED in pass-5 (§12 F6) — was an open design decision

| # | Sev | Decision → resolution |
|---|---|---|
| **F4** | High | `QpullTaxHook` implemented only swap callbacks (`0x1044`), so **adding/removing concentrated liquidity bypassed the 4% tax and the 2-hour launch gate** — a single-sided LP position was an untaxed route to acquire/dispose of QPULL, undermining the tax that funds the games. **Decided + built (pass-5 F6): restrict LP to the protocol.** The hook gained the `BEFORE_ADD_LIQUIDITY` flag (`REQUIRED_FLAGS` `0x1044`→`0x1844` **at that time — now `0x1A44`, see §13 L1**) and a `beforeAddLiquidity` callback that reverts unless `tx.origin == initializer`; the hook address was re-mined. Pass-5's reasoning was that gating add alone closes both directions (no third party can hold a position to remove); pass-6 L1 made the gate **symmetric** anyway so the remove path is not un-hooked. Trade-off (accepted): no permissionless community LP; the canonical pool's depth is protocol-provided. |

### Accepted / verified against source / conditional

| # | Sev | Disposition |
|---|---|---|
| **F6, F8** | MH/Med | `tx.origin` reward attribution (a relayer/bundler captures the batch's rewards; reward base is always QPULL). Accepted tradeoff (§8): `tx.origin` is the one unspoofable identity for the gate; rewards can mis-credit but never mis-charge, and every buy-side reward is **−EV to farm** by design, which bounds the "reward discount" economically. Not patchable (immutable hook). |
| **F7** | Med | Launch-gate (2h) rentability via a transferable NFT — accepted, perk-only, immutable (§8, §10). |
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
| **F2** | High | `Treasury.setRouting` was re-settable, so a compromised owner could redirect **all** converted prize funding + the 20% team cut | Added one-way **`lockRouting()`**. **It is no longer armed by the deploy scripts (pre-audit 2026-09-07):** it is the FINAL step of `script/GoLiveMainnet.s.sol`, run only after both convert caps are set, LP is seeded through the lock, and both adapter legs are fork-verified end-to-end (§16.6, `LAUNCH-CHECKLIST.md` §6b step 6). The keeper role is left rotatable by design (its only residual is the bounded, cap-limited convert MEV — F9/M-2). |
| **F5** | Med | Both adapters' `setTreasury` were re-settable despite a "set once" comment; since `QpullWethAdapter` is the hook's immutable `exemptSender`, re-pointing it grants a permanent **0%-tax** QPULL→WETH route (or DoSes `convert()`) | `setTreasury` is now **write-once** (+ zero-check) on both adapters, mirroring `setPoolKey`. |
| **F14** | Low | `potCap` defaulted to `type(uint256).max` in Raffle/Jackpot/Leaderboard (only HolderDraw required it), and the deploy scripts never capped Jackpot/Leaderboard at all — a sole entrant in a quiet period could capture a whole rolled-forward vault balance | `potCap` is now a **required (> 0) constructor argument** in all four engines, cross-checked `minPot ≤ potCap`, matching HolderDraw + `minPot`. `Deploy` reads `RAFFLE_/JACKPOT_/LEADERBOARD_POT_CAP` (fail-closed `vm.envUint`) and passes them at construction. |
| **F7** | Low | `QuotronRouterAdapter` accepted ETH (`receive`) with no rescue — a router refund or force-sent ETH would strand | Added owner-only **`sweepETH(to)`** (touches no WETH/QUOTRON accounting — the adapter holds neither between calls). **Pre-audit 2026-09-07 update:** a router ETH refund is now **re-wrapped to WETH and forwarded to the Treasury inside the same `swapExactIn` call** (`RefundForwarded`), so it can neither strand nor escape `convert()`'s shortfall check; `sweepETH` now covers **force-sent ETH only**. |
| **F10** | Low | The whole randomness system is a hard liveness dependency on the EIP-2537 precompiles; a staticcall to a missing precompile returns success with **empty** data (silent) | `BlsDrandOracle`'s constructor now **probes G1ADD + PAIRING and reverts `PrecompileUnavailable`** if absent — an on-chain fail-closed deploy gate (the script `bls_precompile_check.sh` made mandatory in code). |
| **F13** | Low | `renounceOwnership` was callable everywhere; renouncing a contract that still needs its owner (engine `setPotCap`, `PackRegistry` re-peg, `Treasury` keeper rotation) permanently bricks those knobs | New `NonRenounceableOwnable2Step` base reverts renounce on the six contracts needing a live owner (engines, `PackRegistry`, `Treasury`); two-step transfer to the launch timelock is unaffected. Contracts whose owner is vestigial post-launch (vaults, registries, NFT, adapters) keep the standard base. |
| **F6** | Low→High | LP add/remove ran no hook code (flags `0x1044`), so the 4% tax + launch gate didn't cover liquidity ops — an untaxed side-door to acquire/dispose QPULL (also **pass-4's open F4**). **Restrict LP to the protocol:** the hook gained `BEFORE_ADD_LIQUIDITY` (`REQUIRED_FLAGS` `0x1044`→`0x1844` **as of this pass; the shipped value is now `0x1A44` — §13 L1**) and a `beforeAddLiquidity` gate reverting unless `tx.origin == initializer`; the CREATE2 hook address was re-mined; deploy scripts + all hook tests updated. Gating **add** alone was argued to close both directions (no non-protocol position can exist to remove); pass-6 L1 gated **remove** too rather than rely on that argument. Trade-off (accepted): no permissionless community LP. |

### Confirmed but accepted / documented (no code change)

| # | Sev | Disposition |
|---|---|---|
| **F3** | High | External QUOTRON admin (pause / blacklist / `bannedVenueCodehash`) can freeze all payouts. Already documented (§9 launch check, §10 trust note). Options weighed: a rescue path re-introduces the vault-drain lever the immutable-controller design removed (rejected); "distinct bytecode per vault" is defeated by QUOTRON's **global** pause and per-address blacklist (security theater). **Doc, not code.** |
| **F4** | Med | Raffle (1h) + pack-tier (≤1d) reveal-lag structurally cannot exceed the sequencer's 4-day back-dating bound — the daily cadence must leave a same-following-day draw window. This is the documented **M-7** trusted-sequencer residual (Jackpot 5d / HolderDraw 4.5d are code-enforced). No in-scope fix without changing the game cadence. |
| ~~**F6**~~ | — | **Moved to Fixed in code above** (protocol-only LP built; hook re-mined to `0x1844` in this pass, then to the current **`0x1A44`** by pass-6 L1). This was pass-4's open F4. |
| **F8** | Low | Single-block (transient) holding eligibility. **Under Option C there is no snapshot at all:** eligibility is the `ownerSince[tokenId] <= snapDeadline(week)` test, read at `runDraw` against live `ownerOf`. A wallet that acquires a pass *before* `snapDeadline` and still holds it at the draw is eligible; one that acquires *after* is not, so a transient flash-hold spanning only the draw block no longer qualifies, and `ownerSince` supplies a minimum holding duration the instant snapshot never gave. The beacon is time-locked, so a holder buys only a proportional chance, bounded by `potCap`. Documented (§3 H-5). |
| **F9** | Low | Jackpot/HolderDraw `REVEAL_LAG` is hardcoded against the L1 `SequencerInbox.maxTimeVariation` (re-verified on-chain = 4 days; margins 1d / 0.5d). An L2 can't read its own L1 inbox, so no dynamic fix — **runbook: monitor `maxTimeVariation` and treat an increase as a governance event.** |
| **F11** | Low | **Refuted as a DoS.** The `ReentrancyGuardTransient` guard is redundant given `onlyPoolManager` + the PoolManager's unlock-lock, and TSTORE is **proven live on both RH chains** (V4 PoolManager, which requires it, runs there). Kept as belt-and-braces; dropping it would force a hook re-mine for zero gain. |
| **F12** | Low (RESOLVED) | **Pass-5's refutation was wrong and is struck.** Pass-5 "refuted" the snapshot-gas concern by probing the block header `gasLimit` = `0x4000000000000` (2^50) on both RH chains and concluding the snapshot fit with orders of magnitude of headroom. That number is **not a spendable budget**: `0x4000000000000` is the Nitro constant `GethBlockGasLimit`, a geth-compatibility header field, not a per-tx gas ceiling. (Neither is `50,000,000`, which some tooling reports: that is go-ethereum's default `--rpc.gascap`, an `eth_call` bound on the public endpoint only.) **The real per-transaction ceiling on RH is `32,000,000`, measured three independent ways (2026-09-02):** `ArbGasInfo.getMaxTxGasLimit()` at `0x...006C` (selector `0xaae1cd4c`) returns `0x1e84800` = 32,000,000; `ArbSys.arbOSVersion()` places the chain at ArbOS 61, past the ArbOS 50 clamp branch; and an injected gas burner estimates clean at ~31.98M and is refused at ~32.06M. Corroborated: the largest real RH mainnet tx used 24,237,366 gas under a limit of exactly 32,000,000. Against that ceiling the sold-out atomic snapshot at `SUPPLY = 2000` cost **59,961,132 gas = 187% of 32,000,000**, so it genuinely **did not fit**: a launch blocker, not a "competing reading." **RESOLVED by Option C** (landed after this pass): `HolderDrawEngine.snapshot()` and its `SUPPLY` loop are deleted, and `runDraw` is now bounded rejection sampling that is **supply-independent**, measured at **639,023 gas at n=10 and again at n=2000** (see §3 H-5, §11 F3). The blocker is closed in code, not left to a premise. **One live operational item:** `maxTxGasLimit` is a **live governance parameter** writable via `ArbOwner.SetMaxTxGasLimit` and **can move DOWN**, so it needs a pre-launch re-check against the final deploy target and periodic monitoring thereafter (a governance event to watch, the same class as the sequencer `delaySeconds` monitor). |

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
| **M4** | Med | `setPotCap` let the owner re-peg a single day's payout arbitrarily in one tx (a compromised-owner inflate/deflate lever). **Fix:** re-pegs are bounded to **±25% per cooldown** (`MAX_ADJ_BPS = 2500`; cooldown = DAY raffle / 14d jackpot / 7d leaderboard), via `lastPotAdjust` + errors `AdjustTooSoon` / `AdjustOutOfBounds`. `BadPotCap` (≥ minPot) is still checked first. **`setMinPot` was NOT rate-limited at this pass — that gap was closed later**: pass-7 L-10 added the cooldown (§14) and pass-8 H-3 added the same ±25% band (§15), so today both knobs are banded on all four engines. |
| **L1** | Low | The LP gate (pass-5 F6) covered **add** but not **remove**, so the remove path ran no hook code. **Fix:** added `beforeRemoveLiquidity` applying the same `_onlyProtocolLp` initializer gate; `REQUIRED_FLAGS` gains `BEFORE_REMOVE_LIQUIDITY (1<<9)` → **`0x1844`→`0x1A44`**, hook re-mined, deploy scripts + all `FLAGS` test constants updated. |
| **L2** | Low | `lockEngines()` could freeze an **incomplete/mismatched** binding set. **Fix:** it now requires `n != 0 && n == vaults.length` and that every `engineVault[engines[i]] == vaults[i]` (non-zero) before locking — else `IncompleteBindings`. **Pre-audit 2026-09-07 completeness fix:** the supplied list must also equal the FULL bound-engine set — `engines.length == engineCount` (a counter `setEngine` maintains on every 0-to-bound / bound-to-0 change) with no repeated engine — so a bound engine can no longer be silently omitted from the lock list. (A never-bound engine is still caught only by the deploy script binding all three games before locking.) |
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
| **L8** | Low | Holder-draw eligibility. **Under Option C** it reads live `ownerOf` at `runDraw`, gated by `ownerSince[tokenId] <= snapDeadline(week)`, so a flash-hold acquired after the freeze instant does **not** qualify (§3 H-5). Accepted: the eligibility semantics are documented. **Post-audit update:** the draw is now **tax-funded** by the 6.25% holder share (not seed-only); see the post-audit banner at the top. |
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

*Local suite: **188 tests green** after pass-7 (+ regression tests: M-2 own-vault retry, L-10 cooldown, per-wallet cap). Two co-requested features — the NFT standing-entry model (Option B) and a launch-window buy cap+cooldown — were **deferred** at this pass: they materially change the raffle-draw / hook-swap paths and warrant dedicated design + test work, not a rushed pre-audit change. **Both are itemised in the "Out of scope — deliberately deferred" section near the top of this document, with what ships in their place. UPDATE: the buy cap + cooldown has since been BUILT** (`QpullTaxHook._throttleEarlyBuy`: the spec §16 launch throttle inside the 2-hour `GATE_DURATION()` window, §16.5); **only the standing-entry model still has no code, flag, or storage in this tree.***

---

## 15. Pass-8 remediation + the pass-9 launch overhaul — IN FLIGHT, write-up pending

**Read this before trusting §§1–14 as a complete picture of the current tree.** Code carrying `pass-8` and
`pass-9` markers has landed **after** the §14 write-up, so this section is an **honest index of what is in
the source right now**, not a finished remediation table: the per-finding dispositions and the suite figures
are still owed. It is here so the auditor is not left inferring, from bare in-code markers, whether a pass
happened. **The source, not this document, is authoritative for anything in this section.**

Grep the tree for `pass-8` / `pass-9` to see every site.

**Pass-8 (audit remediation).** Markers present in `src/`:

| Marker | Where | What the code does |
|---|---|---|
| **H-3** | Raffle / Jackpot / Leaderboard / HolderDraw | `setMinPot` gains `setPotCap`'s **±25% band**, so the owner cannot slam the floor in one step (pass-7 L-10 added only the cooldown). |
| **H-4** | `RaffleEngine` | `setWinnersPerDay` gains a **cooldown + ±25% band**, anchored by a new `lastWinnersAdjust` — closes the last un-banded draw knob (was the §11 F11 documented residual). |
| **H-5** | `HolderDrawEngine` | `setExcluded` takes effect the **FOLLOWING week** (`effectiveWeek = currentPeriod() + 1`); before this, an owner could exclude every rival and `snapshot()` in ONE tx. |
| **M-7** | Raffle / Jackpot / Leaderboard / HolderDraw / PackRegistry | The ±25% adjust band is floored so it **never collapses to a point** at tiny values (`if (hi <= cur) hi = cur + 1`). |
| **M-1** | `Treasury` | A standards-compliant ERC-20 may signal a blacklisted/failed transfer by **returning false** rather than reverting — handled on the QUOTRON send path. |
| **M-15** | `NFTCollection` | `setRecipients` requires the three destinations be **distinct**, so the mint-proceeds split cannot be collapsed to 100% into one owner-chosen address. The split is **80/10/10** (LP 80 / prize-seed 10 / team 10, `SEED_BPS = 1000`), changed from the earlier 80/15/5. |
| **L-22** | `NFTCollection` | Constructor rejects `mintPrice == 0` (a free mint would zero all three buckets). |

**Pass-9 (launch overhaul, a feature change, not an audit finding).** New, un-audited surface at the time:
`MAX_SUPPLY` **250 → 2000** (later **→ 3500**, pass-11); `mintPrice` **0.0075 ETH**; `MAX_PER_WALLET` **5 → 20**
(later **removed**, pass-11); a **phased, self-closing mint** (`CLOSED → ALLOWLIST → PUBLIC`, monotonic,
owner-triggered, merkle-gated allowlist with a root that freezes on the first phase open, and a one-shot
public-mint-window deadline of 48h under pass-9; pass-11 below makes `PUBLIC_MINT_WINDOW()` a 24h leg of a
fixed 48h envelope); and `HolderDrawEngine.SUPPLY` was bumped **250 → 2000** to match
`MAX_SUPPLY` (that constant and its coupling were **later removed by Option C**, which makes the holder draw
supply-independent, see §12 F12 and §3 H-5). **Pass-9's owner-triggered phase machine was itself replaced by
the pass-11 tiered time-boxed mint below**, so `openPublicMint`, the stored `phase` var, `mintPhaseOpenedAt`,
`publicMintClosesAt` (as a stored var), `MAX_PER_WALLET`, and the `MintPhaseAdvanced` event no longer exist.

**Pass-11 (tiered time-boxed mint, a feature change, not an audit finding).** New, un-audited surface. The
owner starts the mint **exactly once** with `openAllowlistMint()` (requires `!launched`, `mintStart == 0` else
`AlreadyStarted`, `allowlistRoot != 0`, `mintOpen == true`, and recipients set); it stamps `mintStart` and
emits `MintStarted`. From that one stamp, three windows advance **purely by elapsed time**, with no further
owner action; no OWNER action can extend, rewind, or re-open any of them (the overflow window does auto-extend
under late allowlist demand, via the pass-12 soft-close below, but only later, never earlier, and only up to a
hard cap):

- `[mintStart, +GTD_WINDOW())`: **GTD**, allowlist-only, cumulative per-wallet cap `GTD_CAP = 3`.
- `[+GTD_WINDOW(), overflowEnd)`: **overflow**, allowlist-only, cumulative cap `OVERFLOW_CAP = 8`.
- `[overflowEnd = publicOpensAt(), publicMintClosesAt()]`: **public**, open to all, cumulative cap `PUBLIC_CAP = 20` (raised from 10 by pass-13, commit `eb06131`).

**pass-12 auction soft-close.** `overflowEnd` starts at `mintStart + GTD + OVERFLOW` (the nominal
allowlist->public boundary). A mint in the last `EXTENSION_TRIGGER()` (mainnet 10m) of the overflow window
pushes `overflowEnd` forward by `EXTENSION_STEP()` (5m), capped at `MAX_EXTENSION()` (6h) beyond nominal.
**The close is FIXED:** `publicMintClosesAt() = mintStart + GTD + OVERFLOW + PUBLIC` does not reference
`overflowEnd`, so the extension **borrows from public** rather than shifting the end. `publicOpensAt()`
(= `overflowEnd`), `phase()` and `currentCap()` derive the allowlist->public boundary from `overflowEnd`, so a
late allowlist mint delays the public OPEN while the announceable close stays put: public runs
`[overflowEnd, fixed close]`, i.e. 24h nominal shrinking to a floor of 18h at the full +6h extension. It is
reachable only on the allowlist path (during overflow the open path is refused), never moves the boundary
earlier, and hard-stops at the cap, so `overflowEnd` can never reach `publicMintClosesAt()` (public never
vanishes). `mintStart` and `LAUNCH_BACKSTOP` are unaffected. These three durations are also virtual
(testnet 2m/1m/3m).

`MAX_SUPPLY = 3500`, `GTD_CAP`/`OVERFLOW_CAP`/`PUBLIC_CAP` are compile-time constants (no setter). The three
window lengths and `LAUNCH_BACKSTOP` are **virtual view functions** returning mainnet 6h / 18h / 24h / 30 days
on the base contract, overridden **only** by the never-mainnet `NFTCollectionTestnet` subclass (3m/9m/12m/2h)
so the full flow is walkable in minutes. `phase()` and `currentCap()` derive everything from `mintStart` and
`block.timestamp`; `publicMintClosesAt() = mintStart + GTD + OVERFLOW + PUBLIC` (mainnet: start + 48h, fixed). The
per-wallet cap is **cumulative** via `mintedBy`: a wallet that takes its 3 in GTD can reach 8 in overflow and
20 in public. `finalizeLaunch()` is owner-callable any time and **permissionless** once
`publicMintExpired()` OR `launchBackstopExpired()` (30 days) is true; both boundaries also hard-close every
mint path, so the permissionless finalize can never race a live mint.

**Interplay to name: `GTD_CAP = 3` is deliberately below `HolderDrawEngine.MIN_HOLD = 4`.** A wallet that
mints only in the GTD window holds at most 3 passes and is therefore **not** eligible for the weekly holder
draw (which requires `balanceOf >= 4`) until it tops up to 4+ in the overflow or public window. This is an
intentional hook, not an oversight: the guaranteed round alone does not buy holder-draw entry.

**Consequences the auditor should treat as live questions, not settled history:**

1. **The tiered time-boxed mint is new code on the value path:** it decides who may mint, for how long, and
   when proceeds finalize, entirely off one `mintStart` stamp and the wall clock. Nothing in §§1-14 covers it,
   and it replaced the pass-9 phase machine wholesale (no stored phase, no `openPublicMint`).
2. **§12 F12 (atomic snapshot gas) is now CLOSED by Option C, not a live question.** The measured RH per-tx
   gas ceiling is `32,000,000`, the old sold-out snapshot cost 59,961,132 gas (187% of it) and did not fit, and
   Option C deletes the snapshot so `runDraw` is supply-independent (639,023 gas). What stays live is Option C's
   own draw path (§3 H-5, §11 F3) and monitoring `maxTxGasLimit`, a downward-movable governance parameter, as a
   launch gate (`LAUNCH-CHECKLIST.md`).

---

## 16. Accepted residuals and operational posture (read first, auditors)

This section states, in plain terms, every residual that is accepted **by design**, so it is read as a decision
and not as an oversight. Each was independently re-confirmed by the 13-agent internal pre-audit of 2026-09-07
(`docs/PREAUDIT-REPORT.md`: 0 critical, 0 high, 2 medium, both in the go-live process and both closed by the
remediation described in 16.6 and `LAUNCH-CHECKLIST.md` §6b). Where a residual was mitigated during that
remediation the mitigation is described; where it is deliberately unmitigated, the reason no code change is
wanted is stated. Disagreement with the reasoning is welcome; re-deriving the facts is not needed.

| # | Residual | Class | Posture |
|---|---|---|---|
| 16.1 | No pause / circuit breaker on draws or claims; no kill switch | Design decision | Accepted, will not be added |
| 16.2 | Daily raffle `REVEAL_LAG` (1h) below the 4-day sequencer back-dating bound | Chain trust assumption | Accepted, bounded; weekly games unaffected |
| 16.3 | Hook-fee scope: a hookless parallel pool trades untaxed | Inherent to V4 per-pool hooks | Accepted, monitored |
| 16.4 | Immutable drand dependency | External liveness | Recurring draws fail safe; one-shot NFT reveal gets a non-discretionary fallback ladder |
| 16.5 | Launch throttle: uncapped early-accumulation tail | Documented design ceiling | Accepted, immutable |
| 16.6 | `lockRouting()` + write-once adapters are permanent | Immutability trade-off | Accepted; lock timing moved to the final verified go-live step |
| 16.7 | Rip-XP claim window lets a holder pick one of two adjacent leaderboard weeks (M-2) | Negligible-value gameable choice | Accepted; comment corrected, code deliberately unchanged |
| 16.8 | Pledge-flood against the free-entry pledge region (pre-audit LOW) | Bounded, non-profitable griefing | Accepted, bounded (void share `q^6` per seat, seats independent since the seat-nonce cascade fix); SR seats made immune by the SR-first pick; pruning the flood out of `wb` deferred to the external audit |

### 16.1 No pause, no circuit breaker, no kill switch (by design)

- `RaffleEngine.runDraw` / `runOpeningDraw`, `HolderDrawEngine.runDraw`, `LeaderboardEngine.distribute`,
  `ClaimManager.claim` / `claimBatch`, and `BaseVault.payOut` carry no `whenNotPaused`, no owner gate, and no
  pause state anywhere. This is deliberate: a pause on the draw or claim path is itself a lever that freezes
  winners, which is exactly the capability the immutable-controller design exists to remove.
- **Consequence, stated plainly for incident response: there is NO on-chain stop.** The ONLY operational lever
  is `Treasury.setKeeper(k, false)`, which de-authorizes a convert keeper. That halts NEW `convert()` funding
  of the prize vaults and nothing else: already-funded vault balances, already-registered claims, and every
  permissionless draw keep running exactly as coded. Operators must not plan an incident around a stop that
  does not exist. The blast radius of an undiscovered engine bug is bounded by the frozen engine-to-vault
  bindings (`lockEngines`, M-1 / F1: an engine can only register claims against its own vault) and by the
  reserve accounting (`unclaimedReserve <= balance`), not by any stop.
- Decision recorded: **do not add a pause.** (pre-audit INFO "no global pause")

### 16.2 Daily raffle: the trusted-sequencer residual (M-7)

- RH's sequencer may back-date `block.timestamp` by up to `SequencerInbox.maxTimeVariation.delaySeconds =
  4 days` (read from the L1 inbox, §10 M-7). `RaffleEngine.REVEAL_LAG = 1 hours` is below that bound, and a
  daily cadence structurally cannot raise it above ~1 day (it must leave a same-following-day draw window).
  So daily-raffle fairness against a MAXIMALLY back-dating sequencer rests on the standard trusted-sequencer
  assumption every Arbitrum-family L2 already carries for all timestamp logic. The per-cohort pack-tier reveal
  (`revealDelay` <= 1 day) shares this residual.
- **The weekly games are not exposed.** `HolderDrawEngine.REVEAL_LAG() = 4 days + 12 hours` exceeds the
  4-day bound, so its sealed-then-revealed property is code-enforced even against a maximally back-dating
  sequencer. `LeaderboardEngine.distribute` has no settling beacon at all (it ranks accrued points), so there
  is nothing to grind against.
- Bound: the daily pot is small and bucket-split across K winners, and the attack requires the RH-operated
  sequencer to catastrophically mis-stamp time, which breaks the whole chain, not just this raffle. Runbook:
  monitor `delaySeconds` as a governance event; an increase past 4.5 days would reach the holder draw.
- Decision recorded: no oracle change; residual documented here and at `RaffleEngine.sol` line ~38.

### 16.3 Hook-fee scope: a hookless parallel pool trades untaxed

- The 4% buy tax, the 48h sell anti-dump decay, the launch gate + throttle, and all game-entry recording live
  in `QpullTaxHook.afterSwap` on the ONE canonical hooked QPULL/WETH pool (`isCanonical`). `QPULLToken` is a
  clean, ownerless ERC-20 with no transfer hook, so anyone can fund a separate QPULL/WETH pool (hookless, or
  with a different hook) that trades at 0% and feeds no game; arbitrage against it leaks value from the taxed
  pool.
- Accepted: a transfer-level tax was rejected for V4 settle compatibility (H-2, §8). The mitigation is
  economic, not code: 100% of protocol liquidity sits in the canonical pool behind the permanent
  `QpullLiquidityLock`, so a parallel pool has to be funded from the open market. Post-launch: monitor for
  externally funded pools and off-pool routing.

### 16.4 Immutable drand dependency, and the one-shot NFT reveal fallback ladder

- `BlsDrandOracle` pins the drand quicknet public key, genesis, and period, and every consumer
  (`RaffleEngine`, `HolderDrawEngine`, `PackRegistry`, `NFTCollection`) holds the oracle as an `immutable`
  with no setter. External liveness of drand quicknet is therefore a hard dependency, by design: a swappable
  oracle is a fairness-root lever, and beacons are archival and permissionlessly postable forever once
  produced, so the only failure that matters is a round that is NEVER produced.
- **Recurring draws: unchanged, fail safe.** A missing beacon voids that window and the pot rolls forward
  (void-on-miss). Nothing is lost, nothing is re-rolled, and no one can choose an alternative beacon.
- **One-shot NFT reveal: mitigated by a NON-DISCRETIONARY permissionless fallback ladder.** `revealRound` is
  written once in `finalizeLaunch` and `rarityOf` needs that single beacon, so a never-produced round would
  have permanently sealed rarity (pre-audit LOW). The remediation adds a ladder with these properties:
  (1) it is armed only after a long backstop past the bound round with no beacon posted; (2) after that,
  ANYONE may advance the reveal to a later round that is fixed purely by time arithmetic from the original
  binding and the backstop (not chosen by the caller, not settable by the owner, no discretionary input);
  (3) it can never re-roll a reveal that has already resolved: a posted beacon for the bound round is final,
  and the ladder only steps while no beacon for the current binding exists. It adds liveness without adding
  a rarity lever. The recurring draws deliberately get no ladder; void-on-miss is their backstop.

### 16.5 Launch throttle: the uncapped early-accumulation tail

- Inside the launch window the hook enforces the NFT-holder gate (`GATE_DURATION()`, 2h), `BUY_COOLDOWN()`
  (2 min) between one wallet's gated buys, and a per-buy WETH size cap (`earlyBuyCapWei`, 0.25 ether) that
  applies ONLY to a wallet's first `EARLY_BUY_COUNT = 10` gated buys. Buys after the tenth remain paced by the
  cooldown but are uncapped in size, so over the 2h window (~60 cooldown slots) a single pass holder can build
  a large position.
- This is a documented design ceiling, not a bug (hook header: "there is NO hard buy count"). The throttle
  bounds sniping speed and the earliest fills, not a wallet's aggregate position over the window. The hook is
  immutable, so the ceiling is not tunable post-deploy. (pre-audit INFO)
- `earlyBuyCapWei` is a wei constant, never a USD figure; re-check it against the ETH price immediately before
  deploy. The deployed value is 0.25 ether (the hook's older "0.15 ether / ~$500" comments were stale and are
  corrected in the pre-audit doc-drift pass).

### 16.6 `lockRouting()` and write-once adapters are immutable by design; lock timing

- `Treasury.lockRouting()` is one-way: after it, `setAdapters` and `setRouting` revert `RoutingAlreadyLocked`
  forever. `QpullWethAdapter.setTreasury` / `setPoolKey` and `QuotronRouterAdapter.setTreasury` are
  write-once. Together they bind `convert()` to exactly those adapter contracts, that canonical PoolKey, and
  those four destinations with no upgrade path, so a post-lock adapter, PoolKey, or external-router defect is
  permanently unfixable. That is the intended trade: it is what makes "no owner can redirect prize funding"
  a bytecode fact (pass-5 F2, pass-6 L3).
- **Timing change (pre-audit remediation): `lockRouting()` is NO LONGER part of the deploy transaction.** It
  runs ONLY as the final go-live step, after (a) both convert caps are set, (b) LP is seeded through the lock,
  and (c) BOTH adapter legs (QPULL to WETH on the live canonical pool; WETH to QUOTRON via the live router)
  are fork-verified end-to-end. While routing is still open a bad binding can be corrected; after the lock it
  cannot. The ordered steps and their on-chain post-conditions are `LAUNCH-CHECKLIST.md` §6b.
- **The convert MEV caps are owner-mutable and intentionally NOT frozen by `lockRouting`.**
  `maxConvertPerCall` / `maxWethConvertPerCall` bound how much a single keeper call may push through each pool
  (keeper MEV and donation-brick, H-1 / H-3 / M-2) and must track pool depth over time. They cannot redirect
  funds or change the split, so they are not a rug lever. They are now **fail-closed**: `0` means "not
  configured" and `convert()` reverts `NotConfigured` until both are set; the go-live sequence asserts both
  are `!= 0` and `!= type(uint256).max` before routing is locked.

### 16.7 Rip-XP: the two-week choice (re-audit M-2, pre-audit LOW)

- `PackRegistry.claimRipXp` is claimable for `RIP_XP_WINDOW = 7` genesis-days after a pack settles as a
  non-winner, and `LeaderboardRegistry` books the XP into the week current at CALL time. A 7-day window over
  7-day Sunday-aligned weeks straddles exactly one week boundary, so the holder can bank the XP into the
  settlement week or the one immediately after: a **two-week choice, not zero choice**. The earlier M-2
  comment ("cannot choose which week") overstated this; **the comment in `PackRegistry.sol` is corrected**
  to say the window bounds the choice to two adjacent weeks.
- **Code deliberately unchanged.** The exact alternative (credit the leaderboard week that contains the
  settlement instant, regardless of claim time) was considered and rejected: a claim made after that week's
  `distribute()` would credit an already-paid week and the XP would be **silently lost**. Shortening the
  window below a week trades the same choice for a tighter claim deadline with no fairness gain.
- Residual is negligible: `RIP_XP_UNIT = 1e15` (x1..x10 by rarity) against buy points at gross-QPULL scale
  (~1e18+), so the timing choice barely moves top-25 standings and no funds are at risk.

### 16.8 Pledge-flood against the free-entry pledge region (pre-audit LOW; accepted, bounded)

- **Mechanism.** `PackRegistry.pledgeList[day]` is append-only: `pledge()` pushes a pass's weight-expanded
  copies (Common 1 / Uncommon 2 / Rare 4) once per token per day, and a copy is voided only when the draw rolls
  it (`pledgerOf[tid][day] != ownerOf(tid)`, or `ownerSince > freeze`). An owner who pledges passes and then
  transfers them to a wallet that never re-pledges leaves INVALID weight `F` in the virtual sampling region
  `wb = 8s + Pv + F` (`s` eligible Super Rares at `SR_WEIGHT = 8`, `Pv` valid pledge weight). Every invalid
  copy that is rolled burns one of the seat's `MAX_REJECTS_PER_SEAT = 6` rolls and one of the draw's shared
  `MAX_VDRAW_ROLLS = 256`. The earlier code comment claimed the per-seat cap "kills the flood vector"; it
  bounds gas, not the flood. The comment is corrected in `src/PackRegistry.sol` (at `MAX_REJECTS_PER_SEAT`).
- **Fix taken (decision 2a, contained): Super Rare seats are immune.** `_pickVirtual` now resolves the SR band
  FIRST on every roll, before the shared budget is consulted and before `pledgeList` is read. An SR-band roll
  is always valid, costs no budget, and can no longer be voided or pre-empted. Previously the budget check
  preceded a seat's first roll, so a spent budget voided SR autos too (and a seat that burnt the last roll
  voided instead of seating an SR on its next roll). Only the pledge region is budget-gated and validated. The
  pick stays a pure function of the beacon and frozen state (`previewDraw == drawFrom`; pinned by
  `PledgeFloodTest` in `test/NFTIntegration.t.sol`).
- **Second fix (re-verification): the seat-nonce cascade.** A re-verification of this section with real
  `drawFrom` calls found a PRE-EXISTING defect that made the flood far worse than the per-seat figure below.
  `_pickVirtual` keys every roll on `(beacon, day, 1, seat, roll)`, but `seat` advanced only when a seat was
  FILLED. A voided seat was therefore re-rolled with the identical six values against unchanged storage at
  every later virtual slot of the draw, and voided again: ONE void ended the free block for the rest of the
  draw. The measured lost share of the free block was 16% / 85% / 96% at q = 0.5 / 0.8 / 0.9, against the
  `q^6` per-seat figure (1.6% / 26% / 53%) this section and the `MAX_REJECTS_PER_SEAT` comment claimed at the
  time. The harness tests sampled `_pickVirtual` with an explicit nonce per sample, so they modelled
  independent seats and could not see it. Fix taken, contained: `seat` now advances on a void as well as on a
  fill, identically in `_drawCore` and `_replayVirtual` (they stay in lockstep, so `previewDraw == drawFrom`
  still holds). `seat` was only ever the synthetic id's uniqueness nonce and the per-slot roll key, so the
  ids stay unique (a gap in the nonce sequence is a void, never a reuse), the pick order (SR band first, then
  the 8 : 4/2/1 pledge ladder) is unchanged, and winner selection stays a pure deterministic function of the
  beacon. Every virtual slot now rolls fresh values: seats are independent and a void costs exactly that
  seat. Pinned on the real `drawFrom` / `previewDraw` path by `PledgeCascadeTest` in
  `test/NFTIntegration.t.sol`: seated share of the free slots over 40 draws of K = 200 measured 98.6% /
  75.1% / 48.0% at q = 0.5 / 0.8 / 0.9 against the `1 - q^6` expectation of 98.4% / 73.8% / 46.9%; a voided
  slot is followed by seated slots in the same draw; the seated slot indices match an independent per-slot
  replay exactly; preview equals the draw across voids. Against the pre-fix code the same tests measure 87.5%
  / 18.5% / 4.9% seated and fail.
- **What a flood can still do, quantified (post-fix bound).** With `q = F / wb` the invalid fraction, per
  free seat, seats independent: `P(seated SR) = 8s/(8s+Pv) * (1 - q^6)`,
  `P(seated valid pledge) = Pv/(8s+Pv) * (1 - q^6)`, `P(void) = q^6`. The 8 : 4/2/1 ladder is therefore
  exact among SEATED seats; the flood's only lever is the void share `q^6`, which rolls forward to the vault
  and, because a void no longer cascades, is also the expected lost share of the whole free block: 1.6% of
  free seats at q = 0.5, 26% at q = 0.8, 53% at q = 0.9. Reaching q = 0.9 costs `F = 9x` the honest weight:
  against 30 SR alone (weight 240) that is ~540 Rares (more than the ~120 that exist in a 3k mint) or ~2,160
  Commons (~90% of the ~2,400 that exist); against a 250-pass launch (2 to 3 SR, weight ~20) it is ~45 Rares
  or ~180 Commons, again most of that supply. The absolute loss is bounded by the free block itself:
  `vPool = cap` = 10% of the paid window, so a draw seats at most `cap` and about `K/11` free seats (~18 at
  K = 200), and only the `q^6` share of those voids. The shared 256-roll budget is a gas backstop, not a live
  limit: spending it needs at least 43 fully-rejecting free seats in ONE draw against ~18 seated (a ~1e-6
  tail even under a total flood); if it were spent, a pledge-band roll voids without validation while an
  SR-band roll still seats, so SR falls to `8s/wb` per seat, never to zero.
- **Why it is accepted.** Pure griefing, non-profitable: a voided seat rolls forward to the vault, never to
  the flooder, and paid winners are untouched (a void does not consume `paidRemaining`). The flooder must own
  the passes at pledge time and a token's copies are pushed once per day (a re-pledge by a new owner reuses
  them), so the capital bar scales with the whole C/U/R supply and the attack buys nothing but transfer gas.
  Voiding a failed pledge seat, rather than handing it to SR, is deliberate: a fallback would let an SR holder
  PROFIT from flooding, turning griefing into an exploit.
- **Deferred to the external audit, deliberately.** Excluding transferred-away copies from `wb` (realized-valid
  weight tracking, or compacting `pledgeList` on a `pledgerOf` mismatch) and a pledge-only reject budget would
  remove the `q^6` term entirely, but they change the sampling denominator and the gas profile of the audited
  draw path (`_drawCore` / `_replayVirtual`). That is a design change for the auditors to weigh, not a
  pre-audit edit; the two contained fixes above (SR-first pick, independent seat nonces) are what ship.

---

*This remediation was prepared with AI assistance and is not a substitute for an independent human security
review. A dedicated cryptographic review of `BlsDrandOracle` and a **V4-hook specialist review of
`QpullTaxHook`** remain recommended before mainnet. QUOTRON's ERC-404 semantics (M-6/M-8), Robinhood
Chain's EIP-2537 support (H-4), and its sequencer `delaySeconds` (M-7) have all been verified on-chain /
against source and are addressed above; the residual QUOTRON-admin trust surface is documented and gated
by the §9 launch check. Pass-4's F4 / pass-5's F6 (V4 liquidity-callback tax gap) is now **resolved** —
liquidity provision is restricted to the protocol, with the gate covering both ADD and REMOVE after
pass-6's L1 (hook re-mined to `0x1A44`, §12–13).*
