# QpullLiquidityLock: Permanent LP Lock

Status: BUILT + unit-tested (7/7). Adversarial review in flight. Makes "100% of supply to LP, can't rug" a bytecode fact instead of a procedural promise.

## Why

The QPULL token mints 100% of supply to the deployer, and the go-live seeds it into the canonical v4 pool. Nothing in the contracts *forced* that liquidity to stay: the hook restricts LP add/remove to the `initializer` (the deployer), but there was **no lock** — the deployer could pull it. `QpullLiquidityLock` closes that.

## The mechanism (guarantee = absence of code)

In Uniswap v4 a liquidity position is owned by the address that called `modifyLiquidity` to create it, and **only that owner can ever modify or remove it.** The lock exploits this:

- The lock calls `modifyLiquidity` to seed, so **the lock owns the position.**
- The lock's bytecode contains **no** function that removes, withdraws, collects, or sweeps: no negative `liquidityDelta`, no fee-collect, no token transfer-out, no owner, no setter, no delegatecall, no selfdestruct.
- Therefore **no transaction can ever pull the liquidity** — removal isn't restricted, it does not exist in the code. Verifiable by reading the (small, immutable) contract.

The deployer stays the hook's `initializer` (no deploy-circularity, no wiring setter). The lock is **not** the initializer; the hook's LP gate admits the lock's one-time add because the deployer is `tx.origin` when it calls `seed`. None of that affects the guarantee, which rests solely on position ownership + no-remove-code.

## Decisions (locked)

- **Permanent, no removal ever.** No timelock escape hatch. Strongest guarantee; matches the immutable/ownerless ethos.
- **LP fees stay with the position, never collected.** The pool's 0.30% Uniswap LP fee (distinct from the protocol's 4% trade tax) accrues to the locked position and is deliberately never harvested — there is no collect path. This keeps the contract to a single entrypoint (max auditability); the 4% trade tax funds the prize games separately. Residual token dust after seeding also stays locked.

## Interface (the entire surface)

- `seed(uint128 liquidity)` — the ONE state-changing entrypoint. `opener`-only, one-shot (`AlreadySeeded` latch). Adds full-range liquidity from the contract's balance and locks it. Requires the pool already initialized (deployer) and the lock pre-funded with QPULL + WETH.
- `unlockCallback(bytes)` — v4 callback, pool-manager-only; reachable only via `seed`, always a positive add.
- Views: `poolKey()`, `seeded`, `tickLower/tickUpper`, immutables. No others.

Immutables: `poolManager, qpull, weth, fee, tickSpacing, hook, opener`, full-range ticks (aligned to `tickSpacing`), `qpullIs0`.

## Deploy / go-live wiring

`GoLiveTestnet` now: deployer `initialize`s the pool, then deploys `QpullLiquidityLock(opener = deployer)`, transfers the launch QPULL + WETH to it, and calls `lock.seed(liquidity)`. It reports the lock address.

**Mainnet:** `script/GoLiveMainnet.s.sol` is the reviewed mainnet twin. It seeds **100% of supply** (the deployer's entire QPULL balance plus the LP WETH) through `QpullLiquidityLock` and enforces the post-conditions onchain in the same broadcast: `lock.seeded() == true`, the position keyed `(lock, tickLower, tickUpper)` holds exactly `LP_LIQUIDITY` and equals the pool's whole liquidity, deployer residual QPULL `== 0`, and the residual stranded in the lock is `<= MAX_LOCK_RESIDUAL_BPS` per side (the script reverts otherwise). `LiquiditySeeder` is removed from the mainnet path (testnet-only if retained).

## How to verify onchain (the "can't rug" proof)

1. The lock's source has no remove/withdraw/collect/sweep function (read it).
2. `lock.seeded() == true` and the pool holds the launch liquidity.
3. The position at `(lock, tickLower, tickUpper)` holds it, and no other address can modify it (v4 ownership).
4. Deployer residual QPULL ≈ 0 (all supply went into the lock's position).

## Tests

`test/QpullLiquidityLock.t.sol` (7): seed adds + latches, one-shot, opener-only, callback pool-manager-only, no remove/withdraw/collect selectors exist, constructor zero-guards, full-range tick alignment. Real-v4 seed proven on the live testnet via go-live.

## Open

- Adversarial review verdict (in flight) — must be clean before mainnet use.
- **CLOSED (2026-09-07):** mainnet go-live script adopts the lock — `script/GoLiveMainnet.s.sol` seeds 100% of supply through `QpullLiquidityLock` with the onchain post-conditions listed above (pre-audit MEDIUM "go-live omits the lock").
- **CLOSED (2026-09-07):** deployer residual QPULL `== 0` post-seed is asserted onchain by `GoLiveMainnet` (`require`, not a checklist read-back) and is also a pinned gate + `LAUNCH-CHECKLIST.md` §6b step 3 post-condition.
