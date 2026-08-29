# QPULL — protocol contracts (audit source)

On-chain, fully self-custodial **pack-raffle protocol**. `QPULL` is a clean, ownerless ERC-20;
a **4% trade tax is collected by a Uniswap-V4 hook** on the canonical QPULL/WETH pool and funds
three prize games. All prizes are paid in **QUOTRON** (a native ERC-404 on the target chain).
No admin can drain a prize vault; winners pull their own claims.

- **Chain:** Robinhood Chain (Arbitrum-based L2, chainId 4663). DEX is Uniswap V4.
- **Status:** **UNAUDITED, pre-launch.** This repo is published for an independent
  security review. Not yet deployed.
- **Toolchain:** Foundry · Solc 0.8.26 · `evm_version = prague` (enables the EIP-2537
  BLS12-381 precompiles used by the drand oracle) · OpenZeppelin Contracts 5.1.0 · Uniswap
  v4-core v4.0.0 (vendored, see Build).

## Please focus a review on

1. **The tax hook — `hooks/QpullTaxHook.sol` (highest priority).** The 4% tax is a **V4 hook**,
   not a token transfer tax (a transfer tax breaks V4 flash accounting — that was the finding
   this rework fixes). It is **immutable** (no owner/setters), takes the fee inside the locked
   context via `take()`, gates the first hour to NFT holders, and fans out game entries to the
   registries. Scrutinize the `afterSwap` delta sign/currency across all four swap shapes, that
   `take(fee)` + the returned `+fee` delta net to a settled unlock, the `exemptSender` conversion
   path, and pool-creation control in `afterInitialize`. Verified against the vendored real
   `PoolManager` in `test/QpullTaxHook.t.sol` — **but a human V4-hook specialist review is still
   recommended.**
2. **Randomness / reveal timing.** All draw and reveal randomness is a **time-locked
   drand (quicknet, BLS-on-G1) beacon**, verified fully on-chain via EIP-2537
   (`oracle/BlsDrandOracle.sol`). Sealed-then-revealed: each draw binds to a *future*
   round so the seed is unknowable while entries/snapshots are still open. Scrutinize the
   round-binding math (`roundAt`, per-engine reveal lag) and any window where a beacon
   could be public before its cutoff.
3. **Access control** — engine/keeper/owner boundaries (`ClaimManager` engine allowlist,
   `Treasury.convert` keeper gate, `Ownable2Step` admins, per-registry `onlyRecorder`, the
   immutable single-`controller` `BaseVault`).
4. **Accounting / solvency** — the vault `reserve` vs `freeBalance` invariant, pull-claim
   lifecycle and the 30-day window, void-on-miss rollover (no double-pay, no stuck funds), the
   owner-set `minPot` floors, and the two-currency `Treasury.convert()`.
5. **ERC-404 (QUOTRON) receipt** — whole-unit ("terminal mint") transfer handling into
   contracts (vaults / treasury) and the receiver-hook defense.

## Layout

```
src/
  hooks/QpullTaxHook.sol   the 4% tax as an immutable V4 hook (fee + gate + game fan-out)
  QPULLToken.sol           clean, ownerless ERC-20 (no transfer tax — the hook taxes trades)
  Treasury.sol             collects tax (QPULL + WETH), keeper-gated convert() to prize inventory
  BaseVault.sol            holds QUOTRON prize inventory; reserve/release/payOut; single controller
  ClaimManager.sol         pull-payment claims (single + claimBatch), 30-day window
  PackRegistry.sol         pack mint, daily cohorts, sealed tiers
  RaffleEngine.sol         daily tier-bucket raffle draw
  JackpotEngine.sol        periodic pari-mutuel jackpot draw
  Leaderboard*.sol         linear pro-rata top-N leaderboard
  HolderDrawEngine.sol     weekly NFT-holder draw (5 tokenId slots, snapshot-before-beacon)
  NFTCollection.sol        limited NFT collection w/ rarity reveal
  adapters/                Uniswap V4 (QPULL/WETH) + router (WETH/QUOTRON) swappers
  oracle/                  BlsDrandOracle (the sole time-locked randomness source)
  interfaces/              shared interfaces (incl. a hand-written minimal V4 IPoolManager subset)
script/HookMiner.sol       CREATE2 salt search for the hook's flag-encoded address
test/                      the tax-hook test suite (QpullTaxHook, HookMiner, fork) + mocks
```

## Audit remediation

This tree incorporates fixes from three review passes — see **[SECURITY.md](SECURITY.md)**, which maps every
finding to its resolution (fixed in code / resolved by the timelock+multisig governance model /
accepted-bounded / removed / false-positive), documents the **H-2 V4-hook rework (§8)** and the internal
adversarial review of it, and lists the launch-time operator steps.

## Build

`v4-core` v4.0.0 is **vendored** under `lib/v4-core` (so the tax-hook tests compile against the real
`PoolManager`). OpenZeppelin and forge-std are installed via `forge install`:

```bash
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts@v5.1.0
forge build
forge test --no-match-path 'test/fork/*'    # local suite; fork tests need an RH RPC (RH_RPC_URL)
```

## Scope note

This is a **contracts-only** export **plus the tax-hook test suite** (the evidence for the H-2 rework).
The other engines' tests, deployment scripts, the keeper bot, and design docs are intentionally not
included. Happy to share those directly with a reviewer.

## License

MIT — see [LICENSE](LICENSE). (Each source file also carries an `SPDX-License-Identifier: MIT`.)
Vendored `lib/v4-core` is Uniswap Labs' code under its own license (see `lib/v4-core/licenses/`).
