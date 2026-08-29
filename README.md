# QPULL — protocol contracts (audit source)

On-chain, fully self-custodial **pack-raffle protocol**. `QPULL` is an ERC-20 with a
two-sided transfer tax that funds three prize games; all prizes are paid in **QUOTRON**
(a native ERC-404 on the target chain). No admin can drain a prize vault; winners pull
their own claims.

- **Chain:** Robinhood Chain (Arbitrum-based L2, chainId 4663). DEX is Uniswap V4.
- **Status:** **UNAUDITED, pre-launch.** This repo is published for an independent
  first-pass security review. Not yet deployed.
- **Toolchain:** Foundry · Solc 0.8.26 · `evm_version = prague` (enables the EIP-2537
  BLS12-381 precompiles used by the drand oracle) · OpenZeppelin Contracts 5.1.0.

## Please focus a review on

1. **Randomness / reveal timing.** All draw and reveal randomness is a **time-locked
   drand (quicknet, BLS-on-G1) beacon**, verified fully on-chain via EIP-2537
   (`oracle/BlsDrandOracle.sol`). Sealed-then-revealed: each draw binds to a *future*
   round so the seed is unknowable while entries/snapshots are still open. Scrutinize the
   round-binding math (`roundAt`, per-engine reveal lag) and any window where a beacon
   could be public before its cutoff.
2. **Access control** — engine/keeper/owner boundaries (`ClaimManager` engine allowlist,
   `Treasury.convert` keeper gate, `Ownable2Step` admins, per-registry `onlyToken`).
3. **Accounting / solvency** — the vault `reserve` vs `freeBalance` invariant, pull-claim
   lifecycle and the 30-day window, void-on-miss rollover (no double-pay, no stuck funds).
4. **ERC-404 (QUOTRON) receipt** — whole-unit ("terminal mint") transfer handling into
   contracts (vaults / treasury) and the receiver-hook defense.
5. **Economic safety** — every buy-side reward is designed to be −EV to farm; check for
   grind/sandwich/front-run surfaces in mint, draw, and `convert`.

## Layout

```
src/
  QPULLToken.sol         ERC-20 + two-sided tax; routes entries to the registries
  Treasury.sol           collects tax, keeper-gated convert() to prize inventory
  BaseVault.sol          holds QUOTRON prize inventory; reserve/release/payOut
  ClaimManager.sol       pull-payment claims (single + claimBatch), 30-day window
  PackRegistry.sol       pack mint, daily cohorts, sealed tiers
  RaffleEngine.sol       daily tier-bucket raffle draw
  JackpotEngine.sol      periodic pari-mutuel jackpot draw
  Leaderboard*.sol       weighted top-N leaderboard
  HolderDrawEngine.sol   weekly NFT-holder draw (snapshot-before-beacon)
  NFTCollection.sol      limited NFT collection w/ rarity reveal
  adapters/              Uniswap V4 (QPULL/WETH) + router (WETH/QUOTRON) swappers
  oracle/                BlsDrandOracle (the sole time-locked randomness source)
  interfaces/            shared interfaces
```

## Audit remediation

This tree incorporates the fixes from a first-pass review — see **[SECURITY.md](SECURITY.md)**, which maps
every finding to its resolution (fixed in code / resolved by the timelock+multisig governance model /
accepted-bounded / removed / false-positive) and lists the launch-time operator steps.

## Build

```bash
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts@v5.1.0
forge build
```

## Scope note

This is a **contracts-only** export. Tests, deployment scripts, the keeper bot, and design
docs are intentionally not included. Happy to share those directly with a reviewer.

## License

MIT — see [LICENSE](LICENSE). (Each source file also carries an `SPDX-License-Identifier: MIT`.)
