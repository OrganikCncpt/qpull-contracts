# QPULL — Audit Remediation & Security Model

This document responds to the external LeftClaw AI first-pass audit (repo `qpull-contracts`, commit
`47d9c4f`). Every High/Medium/Low finding is mapped below to one of: **fixed in code**, **resolved by
governance**, **accepted (bounded)**, **removed**, or **false positive**. The test suite is green after all
code changes (`forge test`, local suites).

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
return values; adapters callable only by the Treasury. *Please double-check:* the Uniswap-V4
`unlock/settle/take` accounting, the residual sandwich surface within the keeper floor, and any way to strand
or divert a batch.

**3. Solvency — `BaseVault` + `ClaimManager`.** *Invariant:* `unclaimedReserve ≤ balance` at all times; each
prize is paid at most once; reserved funds are never drainable. *Defenses:* reserve-against-free-balance;
pull-claims with a 30-day window; `payOut` refuses to touch the reserve; `nonReentrant` + CEI. *Please
double-check:* any path that lowers balance without a matching `release`, cross-vault reachability via an
authorized engine, and ERC-404 whole-unit receipt / reentrancy on the payout leg.

**4. Token hot path — `QPULLToken._update`.** *Invariant:* buys/sells are taxed and mint exactly the intended
game entries; no untaxed route exists; no route can brick all transfers. *Defenses:* AMM-classified tax; a
tax-exempt set limited to protocol contracts; the oracle guarded off the zero address. *Please double-check:*
any exempt or router path that avoids tax or the registry fan-out, and any registry/oracle revert that would
propagate to every transfer.

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

## 6. Launch runbook — critical operator steps

These steps are **required** and are not wired by `Deploy.s.sol` (the adapters and NFT are deployed
separately):

1. **`adapter.setTreasury(<Treasury>)`** on BOTH swap adapters — else `convert()` fail-closes (reverts). *(H-1)*
2. **`JackpotEngine.setPotCap(<cap>)`** and **`HolderDrawEngine.setPotCap`** / constructor cap — set concrete bounds. *(H-3B/M-9)*
3. Create the QPULL/WETH V4 pool **hookless**, then `adapter.setPoolKey(...)`.
4. After the NFT mint closes: **`finalizeLaunch()`** (seals rarity), then **`withdrawProceeds()`** (pays the buckets). *(H-13)*
5. Transfer all ownership to the **Timelock + multisig**; renounce where no further changes are expected. *(§2)*
6. Verify the keeper is posting drand beacons on-chain before the first draw window closes.

---

*This remediation was prepared with AI assistance and is not a substitute for an independent human security
review. A dedicated cryptographic review of `BlsDrandOracle` and confirmation of QUOTRON's ERC-404 transfer
semantics remain recommended before mainnet.*
