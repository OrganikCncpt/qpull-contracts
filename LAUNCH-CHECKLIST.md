# QPULL — Official Launch Verification Checklist (Robinhood Chain mainnet)

<!-- ═══════════════════════════════════════════════════════════════════════════
     PINNED — PRE-MAINNET CRITICAL GATES.  Do NOT remove or reorder.
     This is the "cannot be forgotten" list. Every box below must be TRUE before
     the mainnet deploy is broadcast. Details for each live in the sections cited.
     ═══════════════════════════════════════════════════════════════════════════ -->

> ## ⛔ PRE-MAINNET CRITICAL GATES (pinned — read first, every time)
>
> Nothing broadcasts to mainnet until **every** box here is checked. Each links to its detail section.
>
> **A. Deploy the RIGHT code (cadence + oracle are structural, not config)**
> - [x] **Game cadences auto-correct to mainnet.** RESOLVED — no hand-edit exists to forget. Every engine's
>       cadence is a `virtual` getter defaulting to the real value on the base contract
>       (`RaffleEngine`/`PackRegistry` `DAY()` = **1 day**,
>       `HolderDrawEngine`/`LeaderboardEngine`/`LeaderboardRegistry` `WEEK()` = **7 d**). The short-clock values
>       live ONLY in `src/testnet/TestnetShortClock.sol` subclasses, referenced ONLY by `DeployTestnet.s.sol`.
> - [ ] **Mainnet uses `script/Deploy.s.sol` (base contracts).** It constructs the plain engines — NEVER a
>       `*Testnet` subclass. If any `new *Testnet(` appears in the mainnet path, STOP. (verify: `grep -n "Testnet" script/Deploy.s.sol` → nothing)
> - [ ] **Real randomness.** `Deploy.s.sol` deploys `BlsDrandOracle` (time-locked drand-BLS), NOT the
>       `MockDrandOracle`. `MOCK_ORACLE` is a testnet-only knob; confirm it is unset/false for mainnet. → §5
>
> **B. External addresses (immutable — a wrong one burns funds forever)**
> - [ ] **Re-verify EVERY address on-chain at launch** with §2 commands; all §3 cross-checks hold. → §1–§4
>
> **C. Randomness / sequencer safety**
> - [x] **EIP-2537 precompiles live** on the mainnet target — CONFIRMED via "Random Run" (2026-09-02): a
>       read-only `eth_call` to RH mainnet's `PAIRING` (0x0f) verified a REAL drand quicknet beacon (round 1000)
>       → returned identity (valid), and a tampered sig was rejected (not-on-curve). `G1ADD`/`PAIRING`/`MAP_FP_TO_G1`
>       all present and return the exact values the oracle constructor's fail-closed gate requires. → §5
> - [ ] **F20 crypto-review + v4-hook sign-off** attached (same audit satisfies the Uniswap form). → §6a
> - [ ] **Sequencer `delaySeconds` < REVEAL_LAG** (HolderDraw 4.5 d). → §5
>
> **D. QUOTRON trust surface**
> - [ ] **Gate check** — the 3 `BaseVault`s, `ClaimManager`, `Treasury` are not QUOTRON-blacklisted /
>       codehash-banned; confirm who controls QUOTRON `paused`/blacklist/fee. → §4, §5
>
> **E. Config fail-closed**
> - [ ] **All three `*_MIN_POT` (raffle/leaderboard/holder) + `RAFFLE`/`LEADERBOARD` `*_POT_CAP` + `HOLDER_POT_CAP`/`_CEILING` set** or the deploy reverts. → §5
> - [ ] **`GENESIS` set and REQUIRED at deploy** (`vm.envUint`, no `block.timestamp` default) = the scheduled go-live
>       timestamp; read back equal on all four genesis-bearing contracts. → §6b step 1
> - [ ] **Both convert caps set at go-live** (`setMaxConvertPerCall` + `setMaxWethConvertPerCall`), read back
>       `!= 0 && != type(uint256).max`. They ship fail-closed: `convert()` reverts `NotConfigured` until then. → §6b step 2
>
> **F. Post-deploy locks & wiring (before trading opens)**
> - [ ] **`owner()` == Timelock+multisig** on every ownable contract. → §5
> - [ ] **`lockEngines()` (F1) armed by Deploy**; both adapters' `setTreasury`/`setPoolKey` set. **`lockRouting()` (F2)
>       is NOT armed by Deploy: it is the FINAL go-live step**, after both adapter legs are fork-verified. → §5, §6b step 6
> - [ ] **QPULL hook low-14-bits == `0x1A44`** (`require(hook == mined)` guards it). → §5
>
> **G. Go-live mechanics**
> - [ ] **`genesis` pinned to go-live time** (the 48h first-raffle clock + 2h holder gate start there). → §6
> - [ ] **`initialize` + seed LP THROUGH `QpullLiquidityLock` via `script/GoLiveMainnet.s.sol`, back-to-back, signed
>       by the initializer key.** Read back `lock.seeded() == true`, position owner == the lock,
>       `QPULL.balanceOf(deployer) == 0`. NEVER a direct add from the deployer (that position is removable). → §6b step 3
> - [ ] **Both adapter legs fork-verified end-to-end against the LIVE pools BEFORE `lockRouting()`.** → §6b step 4
> - [ ] **Keeper convert quoting wired + fork dry-run green BEFORE `ENABLE_CONVERT=true`.** → §6b step 5
> - [ ] **Swaps route via the Universal Router (mainnet), NOT `TestnetSwapRouter`**; keeper `convert()` carries a
>       live `minQuotronOut` (QUOTRON fee is dynamic — never hardcode 3%). → §4, §6a
> - [ ] **Uniswap hook-allowlist form submitted IN PARALLEL** — an upgrade, never a launch gate. → §6, §6a
>
> **H. The NFT mint (the raise), happens BEFORE go-live; pass-11 tiered mint = NEW audit surface**
> - [ ] **Read back the mint constants on-chain** and confirm each matches the FINAL value settled in item J:
>       `MAX_SUPPLY() == 3500`, `mintPrice() == 7500000000000000` (0.0075 ETH), `GTD_CAP() == 3`,
>       `OVERFLOW_CAP() == 8`, `PUBLIC_CAP() == 20` (pass-13; NOT the old 10), and the four virtual windows `GTD_WINDOW() == 21600` (6h),
>       `OVERFLOW_WINDOW() == 64800` (18h), `PUBLIC_MINT_WINDOW() == 86400` (24h), `LAUNCH_BACKSTOP() == 2592000`
>       (30d). Caps are `constant` and the base contract's windows are the mainnet values; a wrong value means a
>       FRESH NFT deploy, never a setter. **Confirm the deployed contract is `NFTCollection`, NOT
>       `NFTCollectionTestnet`** (the subclass shortens the windows to 3m/9m/12m/2h and must never reach
>       mainnet). → §7, item J
> - [ ] **`setRecipients` BEFORE the mint starts**: three DISTINCT addresses (lp / seed / team). They freeze at
>       `totalMinted > 0`, an unset one reverts every mint AND `openAllowlistMint()`, and `lp == seed == team` is
>       rejected. → §7
> - [ ] **`reserveMint(qty, treasury)` (the treasury reserve, `RESERVE_CAP() == 25`) runs AFTER `setRecipients`
>       and BEFORE `openAllowlistMint()`**: one-shot, free, ids `1..qty`, counts against `MAX_SUPPLY`. It stamps
>       `reserveAt`, which starts the `LAUNCH_BACKSTOP()` rescue clock while `mintStart == 0`. **RULE: open the
>       allowlist mint within `LAUNCH_BACKSTOP()` (30 days) of `reserveMint`, or a stranger may `finalizeLaunch()`
>       the collection reserved-only** (`launchBackstopExpired()` fires from `reserveAt` until the mint starts).
>       Read back `reserveMinted() == true`, `reserveAt() != 0`, `totalMinted() == qty`. → §7
> - [ ] **`setAllowlistRoot(root)` BEFORE the start**, then dry-run a real proof against the deployed root. The
>       root FREEZES the instant `mintStart` is stamped; leaf = `keccak256(abi.encodePacked(wallet))`. → §7
> - [ ] **`openAllowlistMint()` is the SINGLE, irreversible starting gun.** It requires `mintOpen == true`,
>       `mintStart == 0`, a set root, and recipients; it stamps `mintStart` once and can never be re-called,
>       extended, or rewound. From that instant the windows advance by elapsed time: GTD 6h @ cap 3 (allowlist) →
>       overflow 18h @ cap 8 (allowlist) → public 24h @ cap 20 (open) → closed. **There is NO `openPublicMint`**:
>       public activates on the clock at `publicOpensAt()`. **pass-12 soft-close:** a mint in the last 10m of
>       overflow auto-extends overflow +5m (cap +6h, borrowed from public), so `publicOpensAt()` shifts LATER under
>       late demand while the CLOSE stays FIXED at `mintStart + 48h` (public shrinks, 24h down to a floor of 18h;
>       bounded; the owner cannot do this, and it only ever moves later). Announce the public OPEN as approximate;
>       the close is exact and announceable. → §7
> - [ ] **Auto-close verified, not assumed:** `publicMintClosesAt() = mintStart + GTD + OVERFLOW + PUBLIC`
>       (start + 48h, FIXED, independent of the soft-close). Past
>       it BOTH mint paths revert and `finalizeLaunch()` goes **permissionless** (also on `launchBackstopExpired()`
>       at 30d). `setMintOpen(false)` is a kill switch that can pause but NEVER extend a window; because
>       `mintStart` keeps running while paused, a pause only shortens the usable window. → §7
> - [ ] **Sell-out needs ≥ 175 distinct wallets** (3500 / 20, the public cap being the max any wallet can hold).
>       Confirm that is the intended distribution bar for a 3500-piece drop before deploying. Note that a wallet
>       minting only in the GTD window holds ≤ 3, below `HolderDrawEngine.MIN_HOLD = 4`, so it is NOT holder-draw
>       eligible until it tops up in overflow or public (intentional, see §7b). → §7
>
> **I. RESOLVED: the holder-draw gas blocker (Option C shipped); pre-deploy proofs remain below**
> - [x] **The sold-out snapshot gas blocker is CLOSED.** The atomic ownership snapshot is REMOVED. The weekly
>       holder draw is now a snapshot-free, supply-independent O(1) beacon draw (bounded rejection sampling,
>       `MAX_REROLLS = 256`, 5 flat winners) with an `ownerSince` eligibility freeze stamped in the NFT.
>       Measured cost is 639,023 gas at n=10 AND at n=2000 (supply-independent), against RH's measured
>       **32,000,000** per-tx ceiling; the deleted snapshot cost **59,961,132** gas (187% of the ceiling). → §7c
> - [x] **The `HolderDrawEngine.SUPPLY == MAX_SUPPLY` coupling is GONE.** Option C's engine reads, stores and
>       assumes NO supply number, so the unfixable-post-deploy constant coupling that used to sit here no longer
>       exists. Nothing to match. → §7c
> - [x] **`holderDrawVault` is now TAX-FUNDED** (funding changed from seed-only): Treasury routes the **6.25%
>       holder share** of the trade tax here on every `convert()` (the slot the removed standalone jackpot used
>       to take). It starts empty at launch and fills from that share after go-live; an optional one-time seed can
>       be sent post-deploy for a bigger opening pot. → §7c
> - [ ] **Run the user-signed testnet gas-ceiling proof** in `GAS-CEILING-TEST.md`: watch the 32,000,000 clamp
>       fire in a mined block (expected Outcome B, ~32M gas burned, failed status). Outcome C (a ~38M-gas
>       success) REFUTES the ceiling and reopens the whole Option C verdict, so STOP and escalate. → §7c, GAS-CEILING-TEST.md
> - [ ] **Re-check `maxTxGasLimit` immediately before the mainnet deploy** (it is a LIVE governance parameter,
>       `ArbOwner.SetMaxTxGasLimit`, and can move DOWN): confirm `ArbGasInfo.getMaxTxGasLimit()` still returns
>       `0x1e84800` (32,000,000), and keep a periodic monitor on it. → §7c
> - [ ] **Obtain the auditor rulings** recorded verbatim in §8 before deploying the holder draw. → §8
>
> **J. OPEN DECISIONS: settle before the NFT constants are frozen (they have no setters)**
> - [x] **Final supply: 3500.** Drives the raise size and the distinct-wallet sell-out bar (item H). The O(1)
>       holder draw is supply-independent, so this no longer touches the gas budget. → §7a, item H
> - [x] **Mint price: 0.0075 ETH** (`7500000000000000` wei). Raise at sell-out **26.25 ETH**, split 80/10/10 →
>       **21 ETH LP / 2.625 ETH prize seed / 2.625 ETH ops**. → §7a
> - [ ] **Whether the holder draw requires holding 5+ passes** (a floated eligibility threshold). The shipped
>       value is `MIN_HOLD = 4`; note the `GTD_CAP = 3` interplay (a GTD-only wallet cannot reach it). Decide
>       before deploy: it is engine behavior, not a post-deploy setter. → §8
- [x] **NFT royalties: FINAL = 0%.** The user first floated 10% to the holder pot, then decided **0%**. No
      royalty standard is implemented (no `EIP-2981`), so the collection reports 0% to every marketplace by
      absence. Nothing to build; the securities concern is moot at 0%. → §7d

> Get one external address wrong and funds route to the void, permanently (the hook + adapters bake
> several of these in as immutables). **Re-verify EVERY address on-chain immediately before the mainnet
> deploy** using the commands in §2 — do not trust the values in this file blindly; the commands re-derive
> them live. This file is operational and stays in the MAIN repo (not the public contracts repo).

## 1. External addresses — verified 2026-08-30 on RH mainnet (chainId 4663); RE-VERIFY at launch

| Address | Role | On-chain verification |
|---|---|---|
| `0x42024fCFdB4F3089Dd619A0cEF0Cd24E7b841C18` | **Quotron Canonical ETH router** — the contract you call (`buyExactEth`) to **buy QUOTRON** | has code; `router.quotron()` == the QUOTRON below |
| `0x5a86828Efd322bfb16d93cFeD16EE9BC14940D7F` | **QUOTRON token** (`Quotron404V2`, 18 dec) — the prize/payout token; the thing `convert()` acquires | **must equal `router.quotron()`**; verified source on RH Blockscout |
| `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` | **WETH** (RH mainnet) — the QPULL pool's quote asset + `convert()` intermediate | == `router.poolKey().currency0` |
| `0x8366a39CC670B4001A1121B8F6A443A643e40951` | **Uniswap V4 PoolManager** (RH) — hosts the canonical QPULL/WETH pool + our hook | has code |
| `0x62E200Cc8e4D95cf622f40Dd70f407C883EcB0cc` | **QUOTRON's `floorHook`** — sets/charges QUOTRON's **dynamic** trade fee on the QUOTRON buy | == `router.poolKey().hooks` |
| `0x4e59b44847b379578588920cA78FbF26c0B4956C` | **Deterministic CREATE2 deployer** — mines the QPULL hook to its `0x1A44` flag address (pass-6 L1; **never `0x1844`**) | has code (Arachnid deployer) |
| `0xBd0D173EEb87D57A09521c24388a12789F33ba96` | **RH `SequencerInbox`** (on **Ethereum L1**, not RH) — source of `maxTimeVariation.delaySeconds` (M-7) | `maxTimeVariation().delaySeconds` |

## 2. Verify commands (run against RH mainnet immediately before deploy)

```bash
RPC=https://rpc.mainnet.chain.robinhood.com
ROUTER=0x42024fCFdB4F3089Dd619A0cEF0Cd24E7b841C18

# QUOTRON token (authoritative — derived from the router, not hardcoded)
cast call $ROUTER "quotron()(address)" --rpc-url $RPC
# QUOTRON/WETH pool: currency0, currency1, fee, tickSpacing, hook
cast call $ROUTER "poolKey()(address,address,uint24,int24,address)" --rpc-url $RPC
# code present on the critical externals
for A in $ROUTER 0x8366a39CC670B4001A1121B8F6A443A643e40951 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73; do
  cast code $A --rpc-url $RPC | head -c 12; echo "  <- $A"
done
```

## 3. Cross-checks that MUST hold (else abort)

- `router.quotron()` **==** `0x5a86…0D7F` (the QUOTRON you expect). If it differs, the router is not the one you think — STOP.
- `router.poolKey()` currencies **== (WETH `0x0Bd7…AD73`, QUOTRON `0x5a86…0D7F`)`.
- `router.poolKey().hooks` **==** `0x62E2…B0cc` (QUOTRON's floorHook).
- The QUOTRON/WETH pool **fee == `0x800000`** — this is the **dynamic-fee flag**, see §4.

## 4. KEY DETAIL — QUOTRON's fee is DYNAMIC, not a fixed 3%

The QUOTRON/WETH pool's fee reads `0x800000` (8388608) = Uniswap V4's **dynamic-fee** sentinel. That means the
fee on every QUOTRON buy is set at swap time by **QUOTRON's `floorHook`** (`0x62E2…B0cc`), which QUOTRON's team
controls — it is **not** a protocol constant and QUOTRON's admin can change it. It presents as ~3% today, but:
- Do **not** hardcode 3% anywhere. `convert()` protects itself with the keeper's off-chain `minQuotronOut`
  (which already prices in the live fee).
- This is part of the QUOTRON-admin trust surface (see SECURITY.md §10 / §12 F3): QUOTRON's hook can move the
  fee, pause, blacklist, or ban our vault codehash. Confirm who controls it before launch.

## 5. Other launch-critical checks (beyond addresses)

- [ ] **EIP-2537 precompiles live** on the final target (H-4): run `script/bls_precompile_check.sh` against the
      mainnet RPC. (BlsDrandOracle's constructor also self-checks and reverts if absent — pass-5 F10.)
- [ ] **`delaySeconds`** (M-7): `SequencerInbox.maxTimeVariation().delaySeconds` on L1 must stay **below** the
      code REVEAL_LAG (HolderDraw 4.5d). If RH raised it, review before launch.
- [ ] **QUOTRON gate check** (§9): the three `BaseVault`s, `ClaimManager`, and `Treasury` addresses/codehashes are
      NOT on QUOTRON's blacklist / `bannedVenueCodehash`; confirm who controls QUOTRON `paused`/blacklist.
- [ ] **Deploy env fail-closed**: all three `*_MIN_POT` (raffle/leaderboard/holder) and the `RAFFLE`/`LEADERBOARD` `*_POT_CAP` plus `HOLDER_POT_CAP`/`_CEILING` set (pass-5 F14) or the deploy reverts.
- [ ] **After deploy**: **`lockEngines()`** (F1) armed; both adapters' `setTreasury`/`setPoolKey` set. `setRouting(prizeVault, holderDrawVault, leaderboardVault, team)` fixes the trade-tax split **raffle 61.25% / leaderboard 12.5% / holder draw 6.25% / team 20%** (the 6.25% is the former standalone-jackpot slot, now routed to the holder draw).
      **`lockRouting()` (F2) is NOT armed by Deploy any more: it is the FINAL go-live step (§6b step 6).** Move
      `owner()` to the Timelock+multisig on every ownable contract only AFTER that step: the two cap setters and
      `lockRouting()` are owner-gated, and running them through a 48h timelock stalls go-live.
- [ ] **QPULL hook address**: low-14-bits **== `0x1A44`** (afterInitialize | beforeAddLiquidity |
      beforeRemoveLiquidity | afterSwap | afterSwapReturnsDelta — pass-6 L1 added the remove gate);
      `require(hook == mined)` guards this at deploy.
- [ ] **Go-live**: `initialize` then seed LP **through `QpullLiquidityLock`** via `script/GoLiveMainnet.s.sol`,
      **back-to-back**, the **seed tx signed by the deployer/initializer key** (the `beforeAddLiquidity` gate requires
      `tx.origin == initializer`, pass-5 F6). The ordered steps with their on-chain post-conditions are §6b.

## 6. Launch sequence & timing (canonical order)

**"LIVE" = the token sale opens** — i.e. go-live (LP seeded + hook active + trading open). The NFT mint is the
*raise* and happens BEFORE this. **The 2-hour holder gate (`GATE_DURATION()`), the 48h sell-tax decay, and the
48h first-raffle clock all start at go-live.**

> ⚠️ **THREE different clocks, do not conflate them.** (1) the **whole mint**, a fixed 48h span from `mintStart`
> that runs BEFORE go-live: 24h of allowlist legs (GTD 6h + overflow 18h) then a 24h `PUBLIC_MINT_WINDOW`,
> auto-closing the raise at `mintStart + 48h` (the soft-close borrows from public but never moves that close, §7);
> (2) the **sell-tax decay** (`SELL_DECAY`), a 48h clock that starts at `initialize()` and
> steps sells 20 → 16 → 12 → 8 → 4% every 12h; (3) the **first-raffle clock**, measured from `genesis`, which is
> why the first `runDraw(1)` lands at `genesis + 48h`. They start at different moments and govern different
> contracts.

Order of operations:
1. **NFT mint (the raise):** **3500 passes at 0.0075 ETH = 26.25 ETH**, auto-split 80/10/10 on every mint into
   **21 ETH LP / 2.625 ETH prize seed / 2.625 ETH ops**. One owner start, then GTD 6h → overflow 18h → public 24h,
   all by elapsed time, auto-closing at a fixed `mintStart + 48h`. Not "live" yet. → §7
2. **Go-live = LIVE** — `initialize` the canonical QPULL/WETH pool, then seed LP **through the permanent
   `QpullLiquidityLock`** back-to-back via `script/GoLiveMainnet.s.sol` (both signed by the initializer key).
   Trading opens. **The launch gate + 48h raffle clock start HERE.** Ordered steps + post-conditions: §6b.
3. **Submit the hook for Uniswap routing review — IN PARALLEL.** You can only submit once a live, seeded pool
   exists (see the hook-allowlist notes). Form: `developers.uniswap.org/hook-allowlist` (mandatory — QPULL's
   hook carries `afterSwapReturnsDelta`).
4. **Approval (whenever it lands) is an UPGRADE, not a gate** — app.uniswap.org begins routing the pool. No SLA,
   no timeline, no appeal. **Do NOT hold the launch for it.**

Pre-approval the **QPULL website is the trading venue** (it routes directly to the PoolManager); the on-chain
pool is permissionless so aggregators / direct calls also work, but mainstream interfaces won't auto-route until
approved. Site-first is the intended, normal state for a tax-hook token.

### 6a. Uniswap hook-allowlist submission — the form (verified 2026-09-01)

> Two separate layers: the **Universal Router contract** can already route any v4 pool (hooked included) — so
> mainnet swaps go through it, NOT the testnet `TestnetSwapRouter`. What the form unlocks is the **Uniswap web
> interface (app.uniswap.org) surfacing/routing THIS pool**. It's a UI-convenience upgrade, never a launch gate.

- **Is the form required?** Most hooks are auto-allowlisted; you must submit ONLY if the hook uses a **delta
  flag**, its address starts with `0x91`, or it targets a major pair (ETH<>USDC). **QPULL → MANDATORY**: the
  hook carries `afterSwapReturnsDelta` (it takes the tax as an afterSwap delta).
- **Approval criteria (prioritized):** audited · **immutable** (QPULL ✓) · differentiated · has/likely traction ·
  **no custom-data inputs** (QPULL ✓). **Rejected: upgradable hooks, or hooks requiring custom data.**
- **Form fields to have ready** (`developers.uniswap.org/hook-allowlist`):
  1. Contact — name, email, Telegram
  2. Hook — name, one-line description, deployed **hook address** (`0x…`, mainnet)
  3. **A live, seeded pool** ID/address with at least minimal liquidity (so submit AFTER go-live)
  4. Target chain(s) — Robinhood Chain mainnet (chainId 4663)
  5. **Source code** (required) — public repo `github.com/OrganikCncpt/qpull-contracts`
  6. **Audit links** (field accepts any; no rule against AI scans, but Labs *prioritizes* a credible manual
     audit — attach the strongest one you have; the same audit covers the F20 crypto-review gate)
  7. Website (optional) · agree to Uniswap Labs ToS
- **Review time varies — no SLA, no appeal.** Do NOT hold the launch for it (see step 4 above).

- [ ] **`genesis` == launch (go-live) time.** The 48h first-raffle window is measured from `genesis`; if genesis
      drifts earlier than go-live the first draw lands sooner than 48h-after-launch. Pin RaffleEngine/registry
      genesis to the launch timestamp (or keep deploy + go-live close together).
- [ ] **First raffle draw is structural at `genesis + 48h`** — day-0 buys → `runDraw(1)` only fires at
      `currentDay == 2`. Nothing to configure; just verify genesis is pinned to launch.
- [ ] **Do NOT gate go-live on Uniswap approval** — approval requires a live pool (chicken-and-egg) and has no
      timeline. Launch site-first; approval turns Uniswap routing on later.

### 6b. Mainnet go-live: the mandatory ORDERED steps and their on-chain post-conditions

Source: the 2026-09-07 internal pre-audit (`docs/PREAUDIT-REPORT.md`). Both of its MEDIUM findings live in this
sequence (convert caps shipping uncapped and unwired; LP seeded outside the permanent lock). **Run the steps in
this order. Do not start a step until the previous step's post-condition reads back TRUE on-chain.** The script
for step 3 is `script/GoLiveMainnet.s.sol` (the mainnet twin of `GoLiveTestnet._goLive` steps 1-2, with NO
`TestnetSwapRouter` and NO `LiquiditySeeder`). Steps 2 and 6 are owner-gated: run them from the deployer/owner
key and move `owner()` to the Timelock + multisig only after step 6 (§5).

**Step 0. Preconditions (read back, do not assume).**
- [ ] `nft.launched() == true` (`finalizeLaunch` done; the hook's `afterInitialize` reverts `MintStillOpen`
      otherwise) and `withdrawProceeds()` has paid the LP bucket (recipient `lp`) into the key that will seed.
- [ ] `ClaimManager.enginesLocked() == true` with `engineVault(raffle) == prizeVault`,
      `engineVault(leaderboardEng) == leaderboardVault`, `engineVault(holderDrawEngine) == holderDrawVault`.
- [ ] `Treasury.routingLocked() == false` (routing stays OPEN until step 6); `Treasury.qpullWeth()` /
      `wethQuotron()` == the two deployed adapters; `prizeVault() / holderVault() / leaderboardVault() / team()` ==
      the intended four.
- [ ] `QpullWethAdapter.treasury() == Treasury`, `poolKeySet() == true` with the canonical key,
      `QuotronRouterAdapter.treasury() == Treasury`, `hook.exemptSender() == QpullWethAdapter`.
- [ ] `Treasury.isKeeper(keeper) == true`; `Treasury.convertThreshold() != 0`.

**Step 1. `GENESIS` pinned to the go-live timestamp, REQUIRED at deploy.**
- `Deploy.s.sol` reads `GENESIS` with `vm.envUint` (fail-closed; the old `block.timestamp` default is gone). Set
  it to the scheduled `initialize` timestamp BEFORE running Deploy. Deploy runs after the raise closes and can
  precede go-live by days; a deploy-time genesis would start the 48h accumulation clock early.
- [ ] Post-condition: `RaffleEngine.genesis() == PackRegistry.genesis() == HolderDrawEngine.genesis() ==
      LeaderboardRegistry.genesis() == GENESIS`, and `GENESIS >=` the `finalizeLaunch()` block timestamp (§8 Q7).
- Rule at go-live: `initialize` at `block.timestamp >= GENESIS`, as close to it as practical, never before.
  Before `GENESIS` every `(block.timestamp - genesis)` day/week computation underflows (draws revert; the hook's
  try/catch drops buy recording); after it, every second of slip shrinks the 48h opening-accumulation window.

**Step 2. Set BOTH convert caps (owner), pool-sized.**
- `Treasury.setMaxConvertPerCall(qpullSlice)`: max QPULL sold into the canonical pool per `convert()`; size to
  the step-3 seed depth. `Treasury.setMaxWethConvertPerCall(wethSlice)`: max WETH pushed through the SHALLOW
  QUOTRON pool per call; size to that pool's live depth (§4). Both reject `0`.
- [ ] Post-condition: `maxConvertPerCall() != 0 && != type(uint256).max`,
      `maxWethConvertPerCall() != 0 && != type(uint256).max`, and `maxConvertPerCall() >= convertThreshold()`
      (else the QPULL leg strands; owner-fixable). The caps are fail-closed: `convert()` reverts `NotConfigured`
      until both are set. They stay owner-mutable and are deliberately NOT frozen by step 6 (they bound keeper
      MEV per call; they cannot redirect funds or change the split).

**Step 3. Seed LP THROUGH `QpullLiquidityLock` (deployer = initializer key), `script/GoLiveMainnet.s.sol`.**
- Inputs: `SQRT_PRICE`, `LP_ETH` (the realized LP bucket, 21 ETH at sell-out), `LP_LIQUIDITY`, sized so ~100% of
  supply is TRADEABLE at the intended opening price. The lock has no collect / withdraw path, so any excess
  is stranded forever: rehearse the exact three numbers on testnet first (§7a; not the testnet defaults).
- The script, in one broadcast, back-to-back: `poolManager.initialize(canonicalKey, sqrtPrice)` (stamps
  `launchTime`, opens the launch gate) -> `new QpullLiquidityLock(...)` -> wrap + transfer `LP_ETH` WETH and the
  deployer's ENTIRE QPULL balance into the lock -> `lock.seed(liq)` -> `require(QPULL.balanceOf(deployer) == 0)`.
- [ ] Post-condition: `lock.seeded() == true`; the canonical pool's position keyed
      `(lock, tickLower, tickUpper)` holds liquidity `== LP_LIQUIDITY` and there is NO position keyed to the
      deployer; `QPULL.balanceOf(deployer) == 0`; `hook.launchTime() != 0`;
      `grep -n "LiquiditySeeder\|TestnetSwapRouter" script/GoLiveMainnet.s.sol` returns nothing.
- Never seed with a direct `modifyLiquidity` from the deployer: `_onlyProtocolLp` admits add AND remove for
  `tx.origin == initializer`, so that position is REMOVABLE. The gate restricts WHO, only the lock guarantees
  no-remove.

**Step 4. Fork-verify BOTH adapter legs end-to-end against the LIVE pools (before anything is locked).**
- Fork RH mainnet at a block after step 3. Leg 1: `Treasury -> QpullWethAdapter -> canonical QPULL/WETH pool`
  (`test/fork/QpullWethPoolFork.t.sol`; fee-exempt via `exemptSender`). Leg 2: `Treasury -> QuotronRouterAdapter
  -> QUOTRON router` (`test/fork/ConvertSplitFork.t.sol`). Then one full `convert(minWeth, minQuotron)` with
  keeper-quoted floors under the step-2 caps.
- [ ] Post-condition: the fork `convert()` lands the 61.25 / 6.25 / 12.5 / 20 split (QUOTRON deltas on
      `prizeVault` / `holderDrawVault` / `leaderboardVault`, WETH to `team`) with no `SwapShortfall`, and
      `QuotronRouterAdapter` holds no residual ETH afterwards.
- If either leg fails: FIX NOW. Routing is still open (`setAdapters` works), the adapter bindings are
  write-once, and after step 6 nothing can be rebound.

**Step 5. Keeper convert quoting prerequisites (before `ENABLE_CONVERT=true`).**
- `keeper/.env`: `VIEW_QUOTER=0xb8960fdC8A0Be155d196C2795b75747763562df2` (Quotron View quoter, §1),
  `WETH_QUOTRON_ADAPTER=<deployed QuotronRouterAdapter>`, `QPULL_QUOTER=<Uniswap v4 Quoter>`, and the canonical
  key fields `QPULL_POOL_FEE`, `QPULL_POOL_TICK_SPACING`, `QPULL_POOL_HOOK` (equal to the hook's canonical
  PoolKey, NOT Quotron's pool); plus `TREASURY`, `QPULL`, `WETH`, `ORACLE`, `GENESIS`, `REVEAL_DELAY`. Leave
  `CONVERT_SLIPPAGE_BPS=100`; never loosen it to "make it go through".
- Dry run: on an anvil fork of RH mainnet at the live block (keeper key authorized on the fork), run
  `ENABLE_CONVERT=true node keeper.js --once` and confirm `treasury.convert: sent ... confirmed` plus the
  step-4 vault deltas. With `ENABLE_CONVERT=false` the keeper never quotes, and `fire()` skips silently when
  the simulation reverts, so a live-chain `--once` proves nothing about the floors.
- [ ] Post-condition: fork dry run green; only then set `ENABLE_CONVERT=true` on the live process.

**Step 6. `Treasury.lockRouting()` (owner), the FINAL step.**
- Preconditions: steps 2, 3, 4, 5 all read back TRUE. `lockRouting()` requires adapters + all four
  destinations set; it does NOT check the caps, which is why step 2 comes first.
- [ ] Post-condition: `routingLocked() == true`; `setAdapters` / `setRouting` revert `RoutingAlreadyLocked`;
      `qpullWeth()` / `wethQuotron()` == the two deployed adapters and `prizeVault() / holderVault() /
      leaderboardVault() / team()` == the intended four. From here nothing about convert's path is changeable
      except the keeper set and the two caps.
- Then: transfer `owner()` on every ownable contract to the Timelock + multisig (§5); renounce where nothing
  further is expected. The hook and the lock have no owner.

## 7. The raise: mint economics, the tiered time-boxed mint, and the auto-close

Supersedes the earlier 250 @ $125 model (written when supply was 250) and the interim 2000-supply model.
**Every number below is a `constant` or an `immutable` constructor arg on `NFTCollection`; there is no setter
for any of them, so a wrong value is a fresh NFT deploy, not a fix.**

### 7a. Economics (sell-out case)

| Parameter | Value at sell-out |
|---|---|
| Supply (`MAX_SUPPLY`) | **3500 passes** |
| Price (`mintPrice`) | **0.0075 ETH** = `7500000000000000` wei |
| **Gross raise at sell-out** | **26.25 ETH** (≈ **$63k** @ ~$2400/ETH) |
| → **LP** (`LP_BPS = 8000`, 80%) | **21 ETH** (≈ **$50k**) |
| → **Prize seed** (`SEED_BPS = 1000`, 10%) | **2.625 ETH** (buys QUOTRON, seeds the vaults) |
| → **Ops / team** (remainder, 10%) | **2.625 ETH** |
| Per-wallet cap (cumulative, tier-gated) | **3 GTD → 8 overflow → 20 public** ⇒ **≥ 175 distinct wallets** to sell out |
| Rarity mix (70 / 20 / 8 / 2, probabilistic) | ≈ **2450 Common / 700 Uncommon / 280 Rare / 70 Super Rare** |

- The split is enforced **per mint**, on-chain, into three reserves, not at the end, and not by trust. Team
  takes the **exact** 10%; **LP absorbs the rounding dust**, so team is never `> 10%` (audit L-17).
- **Under-sell scales the buckets down linearly:** LP is 80% of *whatever is actually raised*, not 21 ETH.
  If the drop does not sell out, either top the LP up from ops or accept a thinner opening pool; decide which
  BEFORE go-live, because `LP_ETH` is a go-live input.
- **Go-live LP inputs are NOT the testnet defaults.** `GoLiveTestnet.s.sol` defaults `LP_QPULL = 10_000e18`
  and `LP_ETH = 0.5 ether`, both testnet placeholders. Mainnet seeds **`LP_QPULL` = the full
  `1_000_000_000e18`** (100% of supply, fair launch) against the realized LP bucket (21 ETH at sell-out).
- Ongoing prizes are funded by the **trade tax**, not the raise; the raise only seeds the opening pot.
- **The per-wallet cap is cumulative** via `mintedBy`, ceilinged by whichever tier is live: a wallet may take
  3 in GTD, top up to 8 in overflow, and to 20 in public. The `≥ 175` sell-out bar uses the 20 public ceiling.

### 7b. The tiered time-boxed mint (pass-11)

The mint is **tiered and self-closing**, driven entirely by elapsed time from a **single owner start**. This
replaces the old pass-9 owner-triggered `CLOSED → ALLOWLIST → PUBLIC` phase machine: there is no
`openPublicMint`, no stored `phase`, and no `MAX_PER_WALLET`. Setup, then one start action:

1. **`setRecipients(lp, seed, team)`:** three DISTINCT addresses, BEFORE the start. They freeze at the first
   mint; an unset recipient reverts every mint AND the start (audit H-1/H-12, M-15).
   Then, optionally, **`reserveMint(qty, treasury)`** (one-shot, `qty <= RESERVE_CAP = 25`, free, ids `1..qty`):
   it stamps `reserveAt` and starts the 30-day `LAUNCH_BACKSTOP()` rescue clock, so the allowlist mint MUST open
   within 30 days of it or a stranger may finalize the collection reserved-only (pinned gate H).
2. **`setAllowlistRoot(root)`:** leaf = `keccak256(abi.encodePacked(wallet))`. The root **freezes the instant
   the mint starts** (`AllowlistLocked`); starting with an unset root is refused (`AllowlistRootUnset`). Test a
   real proof against the deployed root before starting.
3. **`setMintOpen(true)`:** the kill switch, REQUIRED before the start (`openAllowlistMint` reverts
   `MintClosed` without it, so the timed windows can never start against a paused mint). Mid-mint the owner may
   `setMintOpen(false)` to pause; because `mintStart` keeps running, a pause only **shortens** the usable
   window and can **never extend** any deadline.
4. **`openAllowlistMint()`: the SINGLE, irreversible starting gun.** It requires `!launched`, `mintStart == 0`
   (`AlreadyStarted` otherwise), a set root, `mintOpen == true`, and recipients. It stamps `mintStart` once and
   emits `MintStarted`. From that instant, purely by elapsed time (`phase()` and `currentCap()` derive it all):
   - **GTD**, `[mintStart, +6h)`: `allowlistMint(qty, proof)` only, cumulative cap **3** (`GTD_CAP`).
   - **Overflow**, `[+6h, +24h)`: `allowlistMint` only, cumulative cap **8** (`OVERFLOW_CAP`).
   - **Public**, `[+24h, +48h]`: open `mint()` / `mintBatch(qty)` (and `allowlistMint` still works), cumulative
     cap **20** (`PUBLIC_CAP`, raised from 10 by pass-13). `publicOpensAt() = mintStart + 24h` (nominal; = `overflowEnd`, which the
     soft-close can push later, never the close), `publicMintClosesAt() = mintStart + 48h` (FIXED).
5. **Auto-close.** Past `publicMintClosesAt()`, **both** mint paths revert with **no owner action**, and
   **`finalizeLaunch()` becomes permissionless** (also once `launchBackstopExpired()`, `mintStart + 30d`, is
   true); the launch cannot stall on an absent owner.
6. **`finalizeLaunch()`** seals rarity (`revealRound`), then **`withdrawProceeds()`** pays the three buckets
   **independently**, so one reverting recipient blocks neither the others nor the reveal (audit H-13).

**The window lengths are VIRTUAL view functions** (`GTD_WINDOW`, `OVERFLOW_WINDOW`, `PUBLIC_MINT_WINDOW`,
`LAUNCH_BACKSTOP`) returning the mainnet 6h / 18h / 24h / 30d on the base `NFTCollection`, and are overridden
**only** by the never-mainnet `NFTCollectionTestnet` subclass (3m / 9m / 12m / 2h) so the flow is walkable in
minutes. The caps (3/8/20) are compile-time constants either way.

**Intentional hook: `GTD_CAP = 3 < HolderDrawEngine.MIN_HOLD = 4`.** A wallet that mints ONLY in the guaranteed
window holds at most 3 passes and is therefore not holder-draw eligible until it tops up to 4+ in overflow or
public. Guaranteed access alone does not buy a weekly holder-draw entry; this is by design, not an oversight.

- [ ] **Do NOT conflate the three 48h clocks:** the whole mint (a fixed 48h span from `mintStart`, whose open
      leg is the 24h `PUBLIC_MINT_WINDOW`, pre-go-live), the sell-tax decay (`SELL_DECAY`, from `initialize()`),
      and the first-raffle clock (from `genesis`). See the ⚠️ note in §6.
- [ ] **Rehearse the whole tiered sequence on testnet, including letting the public window lapse**, and confirm
      a permissionless `finalizeLaunch()` from a non-owner key. The windows are immutable (base contract); there
      is no second try on mainnet.

### 7c. The holder-draw gas blocker: RESOLVED by Option C (decision trail)

The 250 to 2000 supply bump made the OLD holder draw's atomic ownership snapshot 8x more expensive and turned
it into a hard launch blocker. That mechanism has been REMOVED. This section is the full decision trail, kept
because the reasoning conditions the pre-deploy gates that remain.

**The blocker (old design).** The old `HolderDrawEngine` took an atomic snapshot of all ownership before each
weekly draw, writing one slot per token. At 2000 tokens the sold-out first-fill cost was measured at
**59,961,132** gas. The real per-transaction ceiling on Robinhood Chain is **32,000,000** gas (measured, see
below), so the sold-out snapshot was **187% of the ceiling**: it could not be mined. The failure mode was
liveness-only (funds safe, pot rolls forward) but permanent, and it would bite exactly as the collection filled.

**The measured ceiling (do NOT re-derive).**
- **32,000,000** = `ArbGasInfo.getMaxTxGasLimit()` at `0x000000000000000000000000000000000000006C` (selector
  `0xaae1cd4c`) returns `0x1e84800`, enforced on ArbOS 61 (past the ArbOS 50 clamp branch). Corroborated: the
  largest real RH mainnet tx used 24,237,366 gas, submitted with a limit of exactly 32,000,000.
- The block-header `gasLimit` of `2^50` (`0x4000000000000`) is the Nitro `GethBlockGasLimit` compat constant,
  NOT a spendable budget. `50,000,000` is go-ethereum's default `rpc.gascap`, an `eth_call` bound on the public
  endpoint only, NOT a chain limit.
- `maxTxGasLimit` is a LIVE governance parameter, writable via `ArbOwner.SetMaxTxGasLimit`, and can move DOWN,
  so it needs a pre-launch check and a periodic monitor.

**The fix: Option C, shipped.** The atomic snapshot, its double buffer, `snapshot()`, `snapComplete()`,
`snapshotOwnerOf()`, `SUPPLY` and `SNAP_WINDOW` are all deleted. The weekly draw is now a snapshot-free,
supply-independent O(1) beacon draw:
- `NFTCollection` stamps `ownerSince[tokenId]` in `_update` on every REAL change of hands (mint included),
  guarded so a self-transfer writes nothing (a griefing guard).
- `HolderDrawEngine.runDraw` derives 5 winners from the drand beacon by bounded rejection sampling
  (`MAX_REROLLS = 256`), skipping duplicate or ineligible candidates; unseated slots roll forward. Each seated
  slot is paid a flat `pot / WINNERS`.
- Eligibility is `ownerSince[tokenId] <= snapDeadline(week)`, which closes the buy-after-reveal front-run
  without any snapshot. `previewDraw` and `isEligible` share the exact selection code.
- Measured draw gas is **SUPPLY-INDEPENDENT: 639,023 gas at n=10 AND at n=2000** (the deleted snapshot cost
  59,961,132). The launch blocker is closed.

**`holderDrawVault` is now TAX-FUNDED (funding changed from seed-only).** Treasury routes the **6.25% holder
share** of the trade tax to it on every `convert()` (the slot the removed standalone jackpot used to take). It
is constructed and wired in `script/Deploy.s.sol` and starts empty at launch, then fills from that share after
go-live; an optional one-time seed can be sent to `holderDrawVault` post-deploy if a bigger opening pot is wanted.

**Related launch parameters (verify at deploy).**
- The proceeds split is now **80 / 10 / 10** (`SEED_BPS = 1000`; it was `1500`, i.e. the old 80/15/5). See §7a.
- `LAUNCH_BACKSTOP() = 30 days` (a virtual view function, mainnet value): `finalizeLaunch()` arms
  permissionlessly on `publicMintExpired()` OR `launchBackstopExpired()`, which closes the abandonment
  fund-lock (an owner who starts the mint and then vanishes). Confirmed present as
  `NFTCollection.LAUNCH_BACKSTOP()`; the testnet subclass overrides it to 2h.
- `HOLDER_POT_CAP` / `HOLDER_POT_CEILING` come from env in `script/Deploy.s.sol` (~lines 108 to 124). Check the
  ACTUAL values against the `potCap <= 5 * pass floor price` invariant before deploy (auditor question 6, §8).

**Pre-deploy gates that remain (do NOT skip):**
- [ ] **Run the user-signed testnet gas-ceiling proof** in `GAS-CEILING-TEST.md`. It deploys a gas-burner whose
      honest work needs ~38,000,000 gas and calls it with `--gas-limit 40000000` on RH testnet (chainId 46630).
      Expected **Outcome B**: mined, failed, ~32,000,000 gas burned, i.e. the clamp fired in real block
      production. **Outcome C** (mined, succeeded, ~38,021,191 gas) REFUTES the 32,000,000 ceiling and reopens
      the entire Option C verdict: STOP and escalate. The user signs and sends every command; no key is handled.
- [ ] **Re-check `maxTxGasLimit` immediately before the mainnet deploy** (it can move DOWN): read
      `ArbGasInfo.getMaxTxGasLimit()` and confirm it still returns `0x1e84800` (32,000,000). Keep a periodic
      monitor.
- [ ] **Obtain the auditor rulings in §8** before deploying the holder draw. They are recorded verbatim and are
      NOT resolved in this file.

### 7d. NFT royalties: FINAL = 0% (decided)

The user first floated **10% NFT royalties routed to the holder raffle pot**, then **decided 0%.** Nothing is
implemented and nothing needs to be: `NFTCollection` declares no royalty standard (no `EIP-2981`), so every
marketplace reads the collection as 0% by absence.

For the record, had 10% been pursued it would have needed (a) an explicit override of the standing "no
revenue-share to NFT holders (securities risk)" rule with counsel sign-off, and (b) an ETH -> QUOTRON convert
path (the pot pays QUOTRON; `EIP-2981` is only a marketplace signal, not enforcement). At 0% all of that is
moot. If royalties are ever revisited it is a fresh, separately-audited feature, not a config change.

## 8. Auditor questions (recorded verbatim, NOT resolved here)

These are the open questions the Option C author left for the auditor. They are reproduced verbatim and are
deliberately left unresolved in this file: each needs an explicit auditor ruling or signature before the holder
draw is deployed. Do not treat any of them as settled.

**Q1. THE CRUX RULING**, and it needs an explicit signature: a holder who sells or moves a pass AFTER
snapDeadline(w) but before runDraw executes forfeits a win they would have kept under the snapshot design, and
the buyer gets nothing either. Both sides of a post-freeze trade are zero and the share re-rolls to a third
party. There is NO way to soften this without storing ownership history, which is the 60M-gas loop being
deleted. SECURITY.md's H-5 row currently states the audit's 're-verify ownerOf at draw' recommendation was
REJECTED because it would reintroduce the buy-after-reveal front-run; Option C ADOPTS that recommendation and
closes the front-run with the ownerSince <= snapDeadline test instead. That row's rationale inverts and must be
rewritten. Sign it or reject Option C.

**Q2. THE UN-EXCLUSION LEVER AND MY REPLACEMENT ENCODING.** Moving the exclusion read past the beacon exposes a
lever the snapshot was hiding: setExcluded(a, false) takes effect INSTANTLY and retroactively, so the owner
could see a barred confederate holding a drawn tokenId and lift the bar in the same transaction as runDraw.
Designer B's fix (add-only, irreversible) and designer C's fix (two-stamp interval) were both rejected: C's own
sketch reintroduces the lever, because with f=4/t=11 a setExcluded(a,true) during week 11 takes the else branch
and sets f=12, flipping week 10's answer from true to FALSE. My replacement keeps both existing mappings and the
existing signature, reinterprets the pair as one scheduled toggle, and adds a strict cooldown (currentPeriod()
<= e reverts). Proof is in exact_spec. Please check the proof independently, and confirm you accept the two new
reverts (a no-op toggle and a toggle inside the cooldown now revert, where today they silently succeed). The
practical cost is one exclusion change per address per two weeks.

**Q3. THE FLAT SHARE VERSUS REDISTRIBUTION.** I chose share = pot/WINNERS with unseated slots rolling forward,
over designer A's share = pot/filled. The EV delta is ~2e-7 * pot per week because the branch requires >90% of
the collection to be ineligible. My reasons: the claim amount stays a flat auditable pot/5; the existing dust
guard pot/WINNERS == 0 is written for a fixed divisor; and pot/filled concentrates hardest exactly when the
eligible set is smallest, which is the regime cheapest to engineer at a thin launch, where filled == 1 hands one
tokenId the entire weekly pot (a genuinely new maximum, not the existing five-winners-one-wallet case). If you
prefer redistribution the change is one line and nothing else moves.

**Q4. MEASURE THE GAS BEFORE QUOTING IT.** Every figure I carried forward is analytically derived from EVM
constants, not measured end to end against the real OZ ERC721 + real ClaimManager + real BaseVault. Needs forge
test --isolate on: (a) runDraw seating 5 immediately; (b) runDraw forced to the full 256 candidates; (c)
mintBatch(20) before and after the ownerSince stamp; (d) a plain secondary transfer before and after; (e) a
self-transfer before and after (must show NO ownerSince SSTORE with the guard). My budget for (b) is 1.5M
against the real 32,000,000 ceiling.

**Q5. TESTNET CANNOT CURRENTLY EXECUTE A HOLDER DRAW AT ALL**, which directly conditions the decision to sign
one testnet transaction to prove the gas clamp. src/testnet/TestnetShortClock.sol:52-66 overrides WEEK() to 10
minutes but does NOT override REVEAL_LAG(), which stays 4 days 12 hours, so drawRound(w) binds to a beacon 4.5
days out while the runDraw window (currentPeriod() == w+1) is only 10 minutes wide. It runs today only because
script/DeployMint.s.sol wires a settable MockDrandOracle on non-mainnet chain ids. Consequences: the signed
transaction WILL prove the gas clamp in real block production, which is what it was chosen for, but it proves
NOTHING about G2 or G3 because the time-locked reveal ordering is mocked. REVEAL_LAG() is internal view virtual,
so the fix is one line in HolderDrawEngineTestnet. Pre-existing, not caused by this refactor, but it must be
written down before the transaction is sent.

**Q6. potCap <= 5 * (pass floor price).** This is the invariant that makes the post-reveal knockout buy
unprofitable even for an attacker owning the entire float: gain = f * potCap/5, cost = the round-trip cost of
the knockout purchase. At the planned $125 mint that is roughly $625 of QUOTRON per weekly pot. HOLDER_POT_CAP
and HOLDER_POT_CEILING come from env in script/Deploy.s.sol (lines ~108-124), so CHECK THE ACTUAL VALUES BEFORE
DEPLOY. If potCap must exceed 5F, the fallback is operational: an immediate-reveal keeper plus a runbook line
telling holders to cancel listings during the draw window.

**Q7. DEPLOY-TIME ASSERT:** genesis >= the timestamp at which finalizeLaunch() will run, so the first drawable
week cannot overlap an open mint. Belt and braces behind the launched() gate. NOTE, correcting the briefing
material: there is NO SUPPLY assert in script/Deploy.s.sol to delete (both designer B and the blast-radius
inventory claim one). The only HolderDraw assert is genesis() == RaffleEngine.genesis() at Deploy.s.sol:270-273
(audit L4), which is unaffected. Also note the coupling the launched() gate creates: if finalizeLaunch() never
runs the holder draw voids forever. It is permissionless once publicMintExpired(), and the whole protocol is
dead without it anyway (rarityOf reverts, PackRegistry.claimFreeEntries reverts, the pool cannot open), so I
judge this safe. Confirm against the LAUNCH_BACKSTOP = 30 days decision, which I did not see implemented.

**Q8. REORG SENSITIVITY**, a genuinely NEW property. The winner set is now determined by live state at runDraw
execution rather than by a snapshot frozen days earlier, so a sequencer reorg that reorders a transfer against
the runDraw transaction changes the winners. Claims are registered atomically in the same transaction so a reorg
re-executes consistently and there is no partial state, but the OUTCOME is no longer reorg-invariant the way a
days-old snapshot was. I do not think this needs a fix on a single-sequencer chain with no MEV auction, but it
should be named rather than discovered.

**Q9. os <= snapDeadline(w) versus os <.** I kept the pinned <= rather than diverging on a cosmetic point. It
puts one boundary block in both weeks; the beacon is 4.5 days away at that instant so nobody has information,
and exploitability is zero either way. Using < would align exactly with currentPeriod()'s half-open interval.
Your call, but decide it before two agents implement different signs.

**Q10. setExcluded(0x...dEaD, true) and the other common burn addresses at launch.** A pass at a dead or
lost-key address is fully eligible and can win a share nobody claims; it then expires after CLAIM_WINDOW and
sweepExpired returns it to the vault, so it is a one-week delay of (dead/E) * pot, not a loss. Identical to
today's behaviour, but more visible now that the eligible set is smaller. Note the new cooldown means these must
be set early, not reactively.
