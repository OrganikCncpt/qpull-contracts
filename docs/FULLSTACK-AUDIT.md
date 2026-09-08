# QuoPull full-stack audit

**Date:** 2026-09-07
**Models:** Claude Opus 4.8 (resumed specialists and lead synthesis); the first contracts batch ran on Fable 5.1.
**Scope:** contracts (`src/`, `script/`), web app + swap path (`web/`, `tools/`), keeper (`keeper/`), deploy / ops / tests (`script/`, `test/`, `docs/`, `.env.example`), and a dedicated red-team lane.
**Method:** 33 blind specialists across 5 tracks. Every medium-or-higher candidate was verified by two independent lenses (a code-trace lens and a baseline-classification lens against `quopull-known-state.md` and SECURITY.md section 16), then survivors were synthesized per track and deduped across tracks here.

## Roster (33 specialists)

- **Contracts (12):** v4-hook, amm-flashloan, oracle-random, precision-invariant, plus eight further contract lenses covering accounting, access control, draw safety, reentrancy, gas/DoS, upgrade/immutability, token integration, and go-live scripting.
- **Web app + swap path (9):** web-wallet-signing, web-tx-construction, web-allowlist-merkle, web-state-ux-safety, web-rpc-chain-config, web-swap-path, web-xss-dom, web-supply-chain-csp, web-oracle-display.
- **Keeper (4):** keeper-convert-slippage, keeper-beacon-trust, keeper-liveness, keeper-config-drift.
- **Deploy / ops / tests (4):** testnet-mainnet-drift, test-coverage-gaps, deploy-config, ops-runbook.
- **Red team (4):** redteam-steal, redteam-brick, redteam-user, e2e-seam-tracer.

## Verdict

The codebase is fundamentally healthy and no critical, high, or fund-theft path survived synthesis. Two prior audits closed 23 findings, and the core onchain invariants (Treasury tax split, hook flag word 0x1A44, drand-BLS randomness, measured-balance accounting, the permanent LP lock, void-on-miss draws) all still hold in code. What this wider pass adds is not a drain but a small cluster of launch-process and configuration defects that fire the instant the site is unlocked and the mainnet scripts are run: one genuinely important config drift that would silently brick the daily raffle for roughly two months, a documented anti-sandwich floor that is quietly 5x to 21x looser than advertised, a free-entry draw geometry that is steerable against its own in-code non-steerable invariant, and a custody vault whose guards are correct but untested. Everything else is low or info hardening, concentrated in the never-run go-live artifacts and the off-chain runbooks that lag the hardened onchain core. Net assessment: minor-to-moderate fixes before an external audit, weighted almost entirely on the deploy/config and go-live sequence rather than on the settled core logic.

## NET-NEW findings (most severe first)

### FS-1 (MEDIUM) Mainnet deploy prices tickets in QPULL base units while the runtime divides WETH-in wei, so following the shipped guidance bricks the daily raffle for about two months

- **Track:** deploy + red team (deduped: `testnet-mainnet-drift` and `e2e-seam-tracer` independently found the same drift)
- **File:** `script/Deploy.s.sol:106` (constructor call `:144`); reinforced by `.env.example:36`, `QTIP-handoff-spec-v2.md:379`, `TESTNET-RUNBOOK.md` ~`:402`, and spec section 13.4
- **Specialists:** testnet-mainnet-drift, e2e-seam-tracer
- **Failure scenario:** `PackRegistry.ticketPrice` is the ETH-in (WETH) value per ticket in wei: `recordBuy` computes `n = (bankedRemainder + grossValue) / ticketPrice` (`PackRegistry.sol:290-296`), the denomination is stated at `:52-60` ("WETH per ticket ... the ETH-in VALUE of a buy, in wei ... e.g. 0.003 ETH"), and `QpullTaxHook.afterSwap` credits off `grossWeth`. The testnet path was migrated correctly (`DeployTestnet.s.sol:100-101` reads `TICKET_PRICE_WETH`, default `0.003 ether`). The never-run mainnet artifact `Deploy.s.sol:106` still reads `vm.envUint("TICKET_PRICE_QPULL")` and passes it unconverted into `new PackRegistry(...)`; the constructor only rejects `ticketPrice == 0` (no magnitude guard). The shipped operator docs actively instruct a QPULL-base-units value (`20000e18`, "NOT ETH"). An operator who follows them sets `ticketPrice` on the order of `1e22` wei while a real ~$10 buy delivers `grossWeth` on the order of `3e15` wei, so `n` floors to 0: every buy mints zero raffle tickets, silently (value banks in `bankedRemainder`, no revert, no event). `setTicketPrice` is bounded to +/-25% per day (`PackRegistry.sol:275-286`), so unwinding a roughly 6.7e6x overshoot takes about two months. This is a half-completed migration, not covered by any section 16 residual or the known-state baseline.
- **Fix:** On the mainnet path, price `ticketPrice` in WETH wei exactly as `DeployTestnet` does: read `TICKET_PRICE_WETH` (default `0.003 ether`), rename the var at `Deploy.s.sol:106`, add a "wei of WETH-in per ticket (~0.003 ether)" comment, and rewrite `.env.example:36-38`, `QTIP-handoff-spec-v2.md:379`, `TESTNET-RUNBOOK.md`, and spec section 13.4 to the WETH-in (value-based) denomination. A go-live dry-run with one real test buy asserting a nonzero pack mint catches any residual drift.

### FS-2 (MEDIUM) Keeper derives the convert leg-1 slippage floor from a taxed v4 quoter path while the real swap is tax-exempt, loosening the documented 1% anti-sandwich floor to about 5% steady and 21% at launch

- **Track:** contracts + keeper (deduped: same defect, contracts rated medium, keeper rated low; carried at medium)
- **File:** `keeper/keeper.js:299-301` (propagates into leg-2 basis at `:312`)
- **Specialists:** v4-hook, amm-flashloan, keeper-convert-slippage
- **Failure scenario:** `quoteConvert()` prices leg 1 (QPULL to WETH) with `quoteExactInputSingle.staticCall` on the canonical `poolKey` whose `hooks = QpullTaxHook`, then sets `minWeth = withConvertSlippage(outWeth) = 0.99 * quote`. The v4 Quoter simulates the swap with `sender` = the Quoter contract, so `QpullTaxHook.afterSwap`'s exemption (`sender == exemptSender`, hook `:343`) does not fire and the full sell tax is deducted from the simulated output (`TAX_BPS = 400` steady, `2000/1600/1200/800` during the 48h launch decay). The real convert runs through `QpullWethAdapter`, which is the `exemptSender` and pays 0%, and `Treasury.convert` only enforces `measured >= minWethOut`. No gross-up exists in `keeper.js`, so the effective floor is `0.99 * (1 - taxBps/10000) * fair`: about 4.96% below fair in steady state forever and about 20.8% below fair in the first 12h, versus the intended 1%. It never reverts (quote <= true output, so `SwapShortfall` cannot mis-trip); the only harm is a permanently loosened anti-sandwich floor on the prize-funding leg. Realized loss is capped by `maxConvertPerCall`, by convert shipping disabled by default, and by the single-sequencer Orbit L2 with no public mempool, which is why it lands at medium rather than high; the control is nonetheless 5x to 21x looser than documented and reopens under organic volatility or any forced-inclusion / sequencer change. Distinct from the accepted section 16.6 convert-caps residual and from the CLOSED pre-audit leg-2 sizing low (which was the inverse, too-tight direction).
- **Fix:** In `quoteConvert()`, gross the leg-1 quote up by the hook's live schedule before applying slippage: `minWeth = withConvertSlippage(outWeth * 10000 / (10000 - taxBps))`, where `taxBps` is computed from `launchTime` / the `SELL_*` getters (or add a pure `sellTaxBpsAt(ts)` view to the hook, or `eth_call` the exempt adapter's `swapExactIn` as `from: TREASURY`). Add a keeper self-test asserting executed leg-1 output lands within about 1-2% of the floor.

### FS-3 (MEDIUM) Free-entry Super Rare set is rebuilt and compacted live at draw time, so a post-beacon transfer changes the sampling modulus and re-rolls every virtual seat (preview != draw)

- **Track:** contracts
- **File:** `src/PackRegistry.sol:487-490` (`_buildSrList`), `:510` (`_buildFreeCfg` weight base), `:543-545` (`_pickVirtual`); violates the in-code guarantee at `:565-569` and `docs/PLEDGE-ENTRY-SPEC.md`
- **Specialists:** oracle-random, precision-invariant
- **Failure scenario:** `_buildSrList` evaluates SR eligibility LIVE at draw time: it drops any pass with `nft.ownerSince(tid) > freeze` (`:487-488`) and COMPACTS survivors into `srList[srCount++]` (`:490`). `_buildFreeCfg` sets `wb = srCount*SR_WEIGHT + pledgeList[day].length` (`:510`), and `_pickVirtual` seats each slot as `srList[(keccak(beacon,day,1,seat,roll) % wb) % srCount]` (`:543-545`). `NFTCollection` stamps `ownerSince` on every transfer and the launch transfer-lock has latched off by ordinary draw days, so after the settling beacon is public (`REVEAL_LAG` 1h) and before the permissionless `runDraw` (~23h window) a holder of several eligible SR/pledged passes can replay `_drawCore` off-chain for each subset she transfers to an alt, then execute the transfers and run the draw in the configuration that seats her retained passes into the most and highest-VTIER seats (best-of-2^a grind, always at least as good as honest). This contradicts the in-code non-steerable guarantee at `:565-569` and `docs/PLEDGE-ENTRY-SPEC.md` ("SR set immutable once randomness is public", "preview == draw"): the prior fixes froze only the ADD direction (`srRegisteredAt <= freeze`) and VTIER on `(tid, winIdx)`, but WHICH `tid` a seat resolves to stays attacker-selectable. Distinct from the accepted section 16.8 pledge-flood (append-only `pledgeList` keeps `wb` fixed there; the SR weight is rebuilt live and is thus mutable). The sibling `HolderDrawEngine` avoids this by sampling `%n` with `n = totalMinted` (frozen modulus) and skipping ineligible forward. Impact is bounded to the free block (at most about 9.09% design ceiling) and is self-costly per toggled pass, but it is low-cost, repeatable daily, and breaks an explicit non-steerable-randomness invariant.
- **Fix:** Build `srList` from all ids with `srRegisteredAt <= freeze` WITHOUT the `ownerSince` compaction, set `srCount` to that fixed length, and in `_pickVirtual` VOID a seat (roll forward to the vault) when the picked SR has `ownerSince > freeze` instead of dropping and re-indexing (the exact pledge-void / `HolderDrawEngine` skip-forward pattern). Then `srCount`, `wb`, and `srList` indices are invariant post-freeze and any post-beacon transfer can only destroy the mover's own seat. Alternatively snapshot `(srList, wb)` per day via a permissionless `freezeDay(D)` before the beacon and refuse an unfrozen draw. Add a test transferring an SR after the beacon and asserting all other virtual winners are unchanged.

### FS-4 (MEDIUM) BaseVault custody access control has zero negative tests

- **Track:** deploy
- **File:** `src/BaseVault.sol:43-46` (`onlyController`), `:54-59` (write-once `setController`); no `test/BaseVault.t.sol` exists
- **Specialists:** test-coverage-gaps
- **Failure scenario:** `BaseVault` is the sole custodian of all prize QUOTRON and its load-bearing guards are `onlyController` (hardened by audit M-14/H-10) and a write-once `setController` with `ControllerAlreadySet` + `address(0)` checks (M-5/H-8), plus `InsufficientFree` on `payOut`/`reserve` and `ReserveUnderflow` on `release`. Verified: those four custom errors (`NotController`, `ControllerAlreadySet`, `ReserveUnderflow`, `InsufficientFree`) appear ONLY in `src/BaseVault.sol` and nowhere in `test/`; there is no `BaseVault.t.sol`; every `setController` call in the suite is a one-time happy-path `setUp` bind; and no test calls `vault.payOut`/`reserve`/`release` directly. So none of the custody guards is asserted by any test. The guards are correct today (no live drain path), but a future refactor that loosened `onlyController` (a second setter, an owner escape hatch) or dropped the write-once / zero guard could let a malicious controller call `release(unclaimedReserve)` then `payOut()` to drain every winner's owed prize, and the entire suite would still pass green. Rated medium purely on custodial criticality, not on a live exploit.
- **Fix:** Add `BaseVault.t.sol` with negative tests: a stranger and the owner calling `payOut`/`reserve`/`release` revert `NotController`; a second `setController` reverts `ControllerAlreadySet`; `setController(address(0))` reverts `NotController`; `release(amount > reserve)` reverts `ReserveUnderflow`; `payOut`/`reserve` beyond `freeBalance` revert `InsufficientFree`.

### FS-5 (LOW) Go-live is not atomic: the empty canonical pool can be re-priced between initialize() and lock.seed(), reverting the one-shot seed and burning the holder-gate window

- **Track:** contracts
- **File:** `script/GoLiveMainnet.s.sol:200` (initialize), `:212` (seed)
- **Specialists:** v4-hook, amm-flashloan
- **Failure scenario:** `_goLive` wraps `initialize` (`:200`), the WETH/QPULL transfers, and `lock.seed` (`:212`) in one broadcast, but forge emits each as a separate sequential-nonce tx (no onchain atomicity, no slot0 assertion at seed). `afterInitialize` stamps `launchTime` and the flag word (0x1A44) has no beforeSwap bit, so between the two txs the zero-liquidity pool is observable and freely re-priceable: a sell-direction swap on L=0 walks `sqrtPriceX96` to the caller's limit at zero token cost, and `afterSwap` admits it (holder gate is buy-only, fee=0 so no `take()`). `lock.seed` then sizes `modifyLiquidity` from the moved slot0 price against balances pre-funded for `SQRT_PRICE_X96`, so `QpullLiquidityLock._settle`'s `safeTransfer` reverts. Result: pool live with `launchTime` ticking, 100% supply + LP ETH inside a no-exit lock, and seed re-tries are a race the griefer wins for gas while the deployer's price-correcting BUY is itself gated / cooldown-limited inside the 2h window. No theft, recoverable, but the documented "gate from pool creation, LP seeded back-to-back" guarantee is DoS-able. Not covered by known-state 16.3 (hookless pool) nor by the two pre-audit go-live mediums, which `GoLiveMainnet` already closes.
- **Fix:** Make pool creation and the seed one transaction: precompute the lock address, pass it as the hook initializer (the hook already accepts a contract initializer at `afterInitialize` via `sender == initializer` and `_onlyProtocolLp`), and have `seed()` call `poolManager.initialize` immediately before `modifyLiquidity` so no empty-pool state is observable. Defense in depth: revert `afterSwap` while pool liquidity == 0 (permanent lock liquidity makes this safe post-seed). At minimum assert `slot0.sqrtPriceX96 == SQRT_PRICE_X96` in the same tx as the seed and document the reverted-seed recovery.

### FS-6 (LOW) Accepted residual 16.7 (rip-XP two-week choice) rests on a stale premise: leaderboard points are grossWeth, so rip XP is about 45% of per-pack buy points, not negligible

- **Track:** contracts
- **File:** `src/PackRegistry.sol:80-82`; companion stale comments at `LeaderboardRegistry.sol:10` and the `TICKET_PRICE_QPULL` env name
- **Specialists:** precision-invariant
- **Failure scenario:** Section 16.7 was accepted because "RIP_XP_UNIT=1e15 is negligible next to buy points at gross-QPULL scale ~1e18+". That premise no longer matches the code: `QpullTaxHook.afterSwap` passes `grossWeth` (WETH-in wei) to both registries' `recordBuy`, and the mainnet ticket is about $10 of ETH (~0.003 ETH = 3e15 wei). With `RIP_XP_UNIT=1e15` and weights 1/2/4/10 over the 80/15/4/1 bands, expected rip XP per non-winning pack = `1.36e15` = about 45% of the `3e15` buy points that pack represents (not ~3e-9). `isRipXpClaimable` admits a 7-day window over Sunday-aligned weeks (straddles exactly one boundary) and `LeaderboardRegistry` books XP into the call-time week, so a holder banks about 45%-of-volume XP into the quieter of two adjacent weeks after observing that week's `totalPoints`, diluting honest buyers. Per the known-state gating rule ("a 16.x residual is a false positive unless the code no longer matches the rationale"), the stale grossQPULL premise makes this NET-NEW. Impact is redistribution within the 12.5% leaderboard bucket (no fund loss), the choice spans only two adjacent weeks, and only the rip-XP portion is timeable, hence low.
- **Fix:** Correct the SECURITY.md 16.7 rationale, the `PackRegistry.sol:80-82` and `LeaderboardRegistry.sol:10` comments, and the `TICKET_PRICE_QPULL` env name to the real WETH scale, then re-decide the residual: either credit rip XP to the pack's settlement-week and gate the claim window before that week's `distribute()`, or rescale `RIP_XP_UNIT` relative to `ticketPrice` (e.g. `ticketPrice*weight/100`), or cap per-address rip XP per week at a small fraction of that address's buy points.

### FS-7 (LOW) Swap widget buy/sell ABI has no mainnet router counterpart; the ROUTER route is undefined for mainnet and wire-web never wires it

- **Track:** web
- **File:** `web/index.html:3035-3038`
- **Specialists:** web-tx-construction, web-swap-path
- **Failure scenario:** `index.html:3035-3038` hardcodes `ROUTER` + `ROUTER_ABI` `buy(uint256 minOut) payable` / `sell(uint256,uint256)`; the only contract with that ABI is the `TestnetSwapRouter` in `script/GoLiveTestnet.s.sol`, header-labelled NOT for mainnet (mainnet is documented to route through Uniswap's Universal Router, an incompatible ABI). `GoLiveMainnet.s.sol` deploys and prints no router and `wire-web.mjs` has no `ROUTER` key (its regex only rewrites quoted `var=0x..` address constants). At launch the Swap step of Swap/Rip/Claim is either dead (staticCall hits a codeless/stale address, quote stays 0, `swGo` refuses) or the team hot-deploys the script-embedded testnet router outside `src/` and audit scope. Distinct from the accepted "re-point addresses" residual: the target contract type does not exist on mainnet.
- **Fix:** Decide the mainnet route before launch: promote a reviewed router into `src/` with tests and print/wire its address from `GoLiveMainnet` (add `ROUTER` to wire-web's MAP and fail the build if any money-path address is unset), or rebuild the widget around Universal Router + Permit2.

### FS-8 (LOW) Mainnet NFT setup runbook and scripts never call setDelegateRegistry, so delegatedAllowlistMint reverts DelegationDisabled at launch

- **Track:** web
- **File:** `LAUNCH-CHECKLIST.md:392` (section 7b); mainnet-shaped `DeployNFT.s.sol`; `NFTCollection.sol:571`
- **Specialists:** web-allowlist-merkle
- **Failure scenario:** `delegate.html` tells allowlisted holders to keep the vault cold and pre-delegate a hot wallet. LAUNCH-CHECKLIST section 7b (`setRecipients`/`reserveMint`/`setAllowlistRoot`/`setMintOpen`/`openAllowlistMint`) and the mainnet-shaped `DeployNFT.s.sol` never wire the delegate registry; only the testnet-only `DeployTestnet.s.sol` does. With `delegateRegistry == address(0)` every `delegatedAllowlistMint` reverts `DelegationDisabled` (`NFTCollection.sol:571`) during the GTD window, while `delegate.html` reads the registry directly and still shows the vault as eligible. Recoverable mid-mint (no `mintStart` gate on the setter) but only once diagnosed.
- **Fix:** Add `setDelegateRegistry(<canonical delegate.xyz v2 address>)` BEFORE `openAllowlistMint` to section 7b and the mainnet NFT deploy script; have `delegate.html` read `nft.delegateRegistry()` and show "delegated minting not enabled yet" when it is zero.

### FS-9 (LOW) Manual beacon CLIs print a stale 2-arg submitBeacon cast command against the 3-arg oracle, so the copy-pasted call reverts and the manual draw path stalls

- **Track:** keeper
- **File:** `keeper/prep-draw.js:71,79`; `keeper/submit-beacon.js:24,28`; oracle `BlsDrandOracle.sol:139`
- **Specialists:** keeper-beacon-trust
- **Failure scenario:** `BlsDrandOracle` exposes only `submitBeacon(uint64,bytes,bytes)` (round, sig, comp) at `:139`, with no fallback/receive. `keeper.js` is correct (3-arg ABI at line 63, called with `[round, sig, comp]` at line 158). But both documented operator CLIs are stale: `prep-draw.js:71` destructures only `{ sig }` and line 79 prints `cast send ... "submitBeacon(uint64,bytes)" <round> <sig>`, and `submit-beacon.js:24,28` do the same, dropping `comp`. That calldata carries the selector for a 2-arg function that does not exist onchain; with no fallback the call reverts and the beacon is never posted. `keeper/README.md` markets `prep-draw.js` as the turnkey path and `submit-beacon.js` for spot posting during a `MOCK_ORACLE=false` dress rehearsal, the mainnet opening draw, or a keeper outage, so the broken command lands exactly when the manual path is relied on. No fund loss (void-on-miss rolls the pot forward) and the failure is a loud immediate revert, but any draw depending on the un-posted round reverts inside `drand.randomness(round)` until the operator diagnoses the ABI drift. SECURITY.md L-8 credits `prep-draw.js` with posting in-window beacons but does not flag the malformed command, so NET-NEW.
- **Fix:** Update both CLIs to the 3-arg ABI: destructure `{ round, sig, comp }` and print `cast send <oracle> "submitBeacon(uint64,bytes,bytes)" <round> <sig> <comp>`. Add a smoke test asserting the printed signature matches `BlsDrandOracle.submitBeacon`'s selector so the tools cannot silently drift again.

### FS-10 (LOW) delegate.html signs delegate.xyz delegations/mints without re-verifying the wallet's actual chain after switch/add

- **Track:** web
- **File:** `web/delegate.html:602-611` (`ensureChain`), `:682-701` (`doDelegate`)
- **Specialists:** web-wallet-signing
- **Failure scenario:** `ensureChain()` fires `wallet_switchEthereumChain` and, on 4902, `wallet_addEthereumChain`, but never re-reads `eth_chainId` to confirm the wallet landed on the target chain. Some wallets add a network without switching (no `chainChanged` fires, so the reload at `:854-855` never runs). All eligibility/vault reads go through the direct RPC `ro()` (`:535`, `:643`, `:728-737`), so `refreshHolder`/`refreshDelegate` enable the Delegate/Mint buttons regardless of the wallet's real chain (there is no `getNetwork()` gate like `index.html` has). `doDelegate` then writes `delegateContract` on the WRONG chain; the delegate.xyz v2 registry is the same address on every chain, so the delegation grants nothing on Robinhood Chain and the allowlisted holder's allocation is silently unprotected at the real mint. Currently inert (`LOCKED=true`, `:528`); materializes the moment the page is unlocked. WEB-SECURITY.md T3 acknowledges wrong-network but its stated mitigation does not cover the add-without-switch silent-failure path.
- **Fix:** Re-read `eth_chainId` at the end of `ensureChain()` and throw if it is not the target; re-check `provider.getNetwork() === CHAIN.chainId` immediately before signing in `doDelegate`/`doMint`, mirroring `index.html`'s mint gate.

### FS-11 (LOW) index.html allowlist mint lacks the stale-root guard delegate.html has; a mismatched allowlist.json enables a reverting mint

- **Track:** web
- **File:** `web/index.html:1517-1531` (`loadAllowlist`/`proofFor`), `:1879` (root read), `~:1934-1944`
- **Specialists:** web-tx-construction, web-allowlist-merkle, web-state-ux-safety, web-rpc-chain-config
- **Failure scenario:** `loadAllowlist()`/`proofFor()` use `allowlist.json` as-is; the onchain `allowlistRoot()` read at `:1879` is used only to word the "not set yet" message, never compared to `_alData.root`. In the ALLOWLIST phase any wallet present in the file gets `mintMode='allowlist'` and an enabled button. `delegate.html` by contrast latches `_alStale` on a root mismatch (`:585-592`) and blocks signing. If the deployed file and the frozen onchain root disagree (root is frozen at `mintStart` per `NFTCollection.sol:291`), every affected wallet is shown "can mint now", signs, and `allowlistMint` reverts `NotAllowlisted` with an undecoded error, burning gas and GTD-window time. No fund loss; safe revert.
- **Fix:** After `loadAllowlist()`, compare `_alData.root` to `nft.allowlistRoot()` case-insensitively and disable the allowlist button with a stale-file note on mismatch, as `delegate.html` does.

### FS-12 (LOW) delegate.html enables a doomed delegatedAllowlistMint after the mint closes by time (currentCap stays 20 while phase is CLOSED)

- **Track:** web
- **File:** `web/delegate.html:732`, `:752`, `:790-813` (`updateMintBtn`)
- **Specialists:** web-tx-construction
- **Failure scenario:** `refreshDelegate` sets `cap=currentCap()` (`:732`) and `remaining=cap-mintedBy[vault]` (`:752`); `updateMintBtn` gates on `_alStale`/`_launchedNft`/`_mintOpen`/`remaining`/`price` but consults `phase` only in the `remaining<=0` branch. `NFTCollection.currentCap()` returns `PUBLIC_CAP` (20) for any `t >= overflowEnd` including after the window closes, while `phase()` is CLOSED and `_requireMintable` reverts. Between the time close and `finalizeLaunch` a delegate sees "N left of cap" and a live "Mint N for vault" button (the clock says "Mint closed" but the button is enabled), signs, and the tx reverts with gas lost. `index.html` handles this correctly (`:1913-1918`).
- **Fix:** In `refreshDelegate`/`updateMintBtn` read `phase()` and `publicMintExpired()`/`launchBackstopExpired()` and disable the button with "Mint closed" when phase is CLOSED, mirroring `index.html`.

### FS-13 (LOW) Mint/pledge/rip/claim reverts are not decoded (only swap is); wrong-phase or capped actions show a cryptic error after gas is spent

- **Track:** web
- **File:** `web/index.html:2966-2968` (mint), `:2082` (ripMany), `:2372` (claimMany); decoder only at `:3216-3231`
- **Specialists:** web-state-ux-safety
- **Failure scenario:** The ABIs list no error fragments and the mint/pledge/rip/claim catches slice the raw message. Only swap maps selectors (`_decodeSwapErr`). So `WalletLimit`/`SoldOut`/`NotAllowlisted`/`MintClosed`/`MintWindowClosed`/`BadPledge`/`AlreadySettled` surface as "unknown custom error". Combined with the >=2s refresh debounce (`:1547-1551`), the mint button stays stale-enabled seconds after the window closes; a click then reverts `MintClosed` with gas lost and no readable reason.
- **Fix:** Add the `src/` custom-error selectors to a shared decoder used by mint/pledge/rip/claim, mirroring `_decodeSwapErr`.

### FS-14 (LOW) No in-flight guard on Claim all / Rip all / Pledge; a double-click sends a second batch tx that pays nothing but burns gas

- **Track:** web
- **File:** `web/index.html:2351` (claimMany), `:2054` (ripMany), `:2090` (pledgeTokens)
- **Specialists:** web-state-ux-safety
- **Failure scenario:** `claimMany`, `ripMany`, and `pledgeTokens` have no busy flag and their buttons are not disabled during a pending tx, unlike mint (`:2948`) and `swGo` (`swBusy` `:3289`). A double-click yields two wallet prompts; the second costs gas but does nothing (`claimBatch` skips settled ids, `claimRipXp` skips granted packs, a repeat same-day pledge is a no-op).
- **Fix:** Add a shared in-flight flag disabling the claim/rip/pledge buttons until the tx resolves, as `swGo`/mint already do.

### FS-15 (LOW) Mint page and swap copy promise a "first-hour" holder gate that self-expires after one hour while the hook enforces a 2-hour gate

- **Track:** web
- **File:** `web/index.html:1210-1211`, `:838`, `:851`, comments at `:3166`
- **Specialists:** web-swap-path
- **Failure scenario:** `index.html:1210-1211` ("self-expires after one hour") and related copy describe a one-hour gate; `QpullTaxHook GATE_DURATION` is 2h and the pass transfer-lock is the same 2h; `docs.html:545` correctly says 2 hours. A non-holder who reads the mint page waits 61 minutes, buys through the widget, and reverts `Gated` (the widget's own onchain countdown at `:3195-3204` reads `GATE_DURATION` and will contradict the page). Buyers of the pass were sold a 1-hour perk that is actually 2 hours. Not covered by WEB-SECURITY.md.
- **Fix:** Replace every "first hour"/"one hour" in `web/index.html` with a value read from `HOOK.GATE_DURATION()` (already fetched) or the literal "2 hours", matching `docs.html`.

### FS-16 (LOW) Swap "Sell tax" detail row computes a flat 4% and understates the decaying launch sell tax (up to 20%) at the moment of decision

- **Track:** web
- **File:** `web/index.html:3270` (`swDoQuote` sell branch)
- **Specialists:** web-swap-path, web-state-ux-safety
- **Failure scenario:** `swDoQuote`'s sell branch reconstructs the tax as `g2=o2*100n/96n, t2=g2-o2` (flat 4%), while `QpullTaxHook` charges 20/16/12/8% over the first 48h. `swSetDir` never calls `updateSellTaxUI` (the only writer of the "Sell tax (X%)" label and the `#sw-selltax` box, run only at init and on a 60s timer). Thirty minutes after launch the details row can read "Tax (4%)" on a real 20% fee. "You receive" and `minOut` come from the staticCall and are correct, and the confirm intent names `sellTaxNow()`, so no value is lost beyond the disclosed net, but the fee row a user reads to judge cost contradicts the schedule.
- **Fix:** Derive the displayed sell tax from `sellTaxNow()`: `tax = o2*pct/(100-pct)`; call `updateSellTaxUI()` inside `swSetDir` and at the top of `swDoQuote` so the label/meter/box follow the active tab immediately.

### FS-17 (LOW) Swap buy intent never discloses that a gated buy transfer-locks all of the buyer's passes for the rest of the window

- **Track:** web
- **File:** `web/index.html:3319-3322` (intent text), pre-check at `:3172-3193`; onchain `NFTCollection.sol:743-761`
- **Specialists:** web-swap-path
- **Failure scenario:** `NFTCollection.sol:743-761` reverts `PassLockedDuringLaunch` on any transfer from a wallet whose hook `earlyBuyer.buys>0` until `launchTime+GATE_DURATION`, triggered by the very buy the widget sends. The launch pre-check at `:3172-3193` already knows `st.active`, yet the intent text at `:3319-3322` mentions only amount, `minOut`, and slippage; the lock is documented only in `docs.html:482`. A holder who buys 0.01 ETH of QPULL to mint a ticket then finds a marketplace sale of their pass reverting, with no prior warning from the page that caused it.
- **Fix:** When `st.active`, add to the buy intent "Buying now locks all your Art Passes from transfer until <gate end time>", and surface `PassLockedDuringLaunch` in the error decoder.

### FS-18 (LOW) delegate.html loadAllowlist() returns null to an early Connect while the initial fetch is in flight, showing a false "not eligible" that persists until reload

- **Track:** web
- **File:** `web/delegate.html:584-585`, init call at `:918`
- **Specialists:** web-allowlist-merkle
- **Failure scenario:** When `LOCKED` is flipped false, `init` calls `loadAllowlist()` un-awaited (`:918`) while the ~1MB `allowlist.json` downloads. A user who clicks Connect in that window hits `await loadAllowlist()`, which sees `_alTried=true` and returns `_al=null` immediately (`:584-585`); `refreshHolder` prints "not on the mint allowlist" and `refreshDelegate` drops every vault. Nothing re-renders when the fetch completes, so the false negative stays until manual reload, during the GTD window. The `_alStale` check is also skipped for that render.
- **Fix:** Cache the in-flight promise (`_alP`) instead of the result and re-run `refreshHolder`/`refreshDelegate` when it resolves after connect.

### FS-19 (LOW) Allowlist builder counts every RPC/batch error as an empty/burned id and reads unpinned live state, so a rate-limited scan can silently drop holders into a root that then freezes

- **Track:** web
- **File:** `tools/build-allowlist.js:203-208`
- **Specialists:** web-allowlist-merkle
- **Failure scenario:** `build-allowlist.js:203-208` catches any `ownerOf` error as `gaps++` (indistinguishable from a nonexistent id) at concurrency 40/40/20 against public RPCs; ethers v6 batches concurrent calls, so a single 429/timeout rejects a whole batch and every id in it is treated as empty. A holder whose ids fall in a failed batch is dropped from the allowlist or below the top-N cutoff; the operator sees only an already-expected `gaps` count, then `setAllowlistRoot` freezes the root. `ownerOf` is also not pinned with `blockTag`, so the published snapshot blocks cannot reproduce the list.
- **Fix:** Distinguish `CALL_EXCEPTION` (token absent) from transport errors (429/timeout/SERVER_ERROR): retry transport errors with backoff and abort if any remain; pass `{blockTag:block}` to every `ownerOf`; lower concurrency or set `batchMaxCount:1` for public RPCs.

### FS-20 (LOW) delegate.html lists rights-tagged ALL delegations as QuoPull delegations and its Revoke is a silent no-op for them (reports success)

- **Track:** web
- **File:** `web/delegate.html:646-652` (`refreshHolder`), `:711` (revoke)
- **Specialists:** web-tx-construction
- **Failure scenario:** `refreshHolder` classifies any `getOutgoingDelegations` entry of type ALL as a QuoPull delegation regardless of `d.rights`, and revoke always calls `delegateAll(to, bytes32(0), false)`. delegate.xyz v2 keys a delegation by `(from,rights,to)`, so a wide grant made elsewhere with a non-zero rights tag is untouched; the call still returns and toasts "Revoked". The holder believes a wide "All" grant is revoked while it stays active for every dapp honoring that rights tag. QuoPull itself honors only `rights=0` (`NFTCollection.sol:575`), so this misreports rather than affects the mint; the row re-appears on next refresh.
- **Fix:** Filter listed rows to `d.rights==bytes32(0)`, or pass `d.rights` through to `delegateAll`/`delegateContract` on revoke and label rights-tagged rows.

### FS-21 (LOW) No Strict-Transport-Security header on a wallet-signing site (first-visit SSL-strip / phishing-signature path)

- **Track:** web
- **File:** `web/vercel.json:8` (headers block)
- **Specialists:** web-supply-chain-csp
- **Failure scenario:** `vercel.json`'s headers block sets `X-Content-Type-Options`, `Referrer-Policy`, `X-Frame-Options`, and `Permissions-Policy` but no `Strict-Transport-Security` (confirmed absent). Once the delegate/mint flow is unlocked, a user reaching the apex over `http://` on a hostile network can be SSL-stripped before the HTTPS redirect and served a look-alike delegate page prompting `delegateAll(attacker)`. `upgrade-insecure-requests` in the meta CSP only upgrades subresources of an already-HTTPS document, not the top-level navigation, and without HSTS the browser has no pinned-HTTPS memory on first visit.
- **Fix:** Add `Strict-Transport-Security: max-age=63072000; includeSubDomains; preload` to the `/(.*)` headers and submit the apex to the HSTS preload list.

### FS-22 (LOW) HolderDraw/Leaderboard pot-cap governance knobs and RaffleEngine.setWinnersPerDay have no rate-limit test coverage

- **Track:** deploy
- **File:** `src/HolderDrawEngine.sol:366` (`setPotCap`), `:383` (`setMinPot`); `src/LeaderboardEngine.sol:99`, `:113`; `src/RaffleEngine.sol:132` (`setWinnersPerDay`)
- **Specialists:** test-coverage-gaps
- **Failure scenario:** The +/-25% band + per-period cooldown on the owner pot knobs (audit M4/H-3/H-4/L-10, added to stop a compromised owner front-running a determined draw to re-target or shrink a known winner's prize) is triplicated but tested in only one copy. `RaffleEngine.setPotCap`/`setMinPot` are covered (`test_M4`, `test_L10`); the identical logic in `HolderDrawEngine` (incl. its unique `PotCapZero`/`AbovePotCeiling` branches), `LeaderboardEngine`, and `RaffleEngine.setWinnersPerDay` (`BadK`/`AdjustTooSoon`/`AdjustOutOfBounds`) is exercised by no test. The code is correct in all copies today; a copy-paste regression that dropped a cooldown or widened a band in an untested copy would ship with a green suite.
- **Fix:** Mirror `RaffleFlow`'s `test_M4_setPotCapRateLimitedAndBounded` and `test_L10_setMinPotRateLimited` for `HolderDrawEngine` and `LeaderboardEngine`, and add a `setWinnersPerDay` rate-limit/`BadK` test for `RaffleEngine` (also cover HolderDraw `AbovePotCeiling`/`PotCapZero`).

### FS-23 (LOW) LeaderboardEngine per-week potCap clamp branch is never exercised; sibling engines both test theirs

- **Track:** deploy
- **File:** `src/LeaderboardEngine.sol:146` (`distribute` clamp)
- **Specialists:** test-coverage-gaps
- **Failure scenario:** `distribute()` clamps a week's payout with `if (pot > potCap) pot = potCap` (audit M-7) so a thin/stale week cannot reserve the whole running vault balance. Every `LeaderboardEngine` construction in the suite passes `potCap = type(uint256).max` (LeaderboardFlow setUp + cadence fixtures, `FullSystem.t.sol:111`), so the clamp is provably never taken and no test proves the leaderboard weekly pot is bounded. The two sibling engines DO unit-test their clamp with a finite cap over a funded vault. The shipped clamp is correct; a regression removing or inverting it would let a funded-but-thin week over-reserve and the suite would stay green.
- **Fix:** Add a test that constructs the engine with a finite `potCap`, funds the leaderboard vault well above it, distributes, and asserts total reserved == `potCap` with the excess left in `freeBalance` (mirroring `HolderDrawFlow.test_potCapRespected`).

### FS-24 (INFO) ABI drift: ORACLE_ABI names gen()/per() that BlsDrandOracle does not expose, so the reveal countdown never renders for enumerated sealed packs

- **Track:** web
- **File:** `web/index.html:2046`, read at `:2532`
- **Specialists:** web-tx-construction
- **Failure scenario:** `index.html:2046` declares `gen()`/`per()` but `BlsDrandOracle` exposes `drandGenesis`/`drandPeriod`, so the read at `:2532` always throws into its catch, `_drandGen`/`_drandPer` stay null, `revealTsFor()` returns 0 and sealed packs discovered via the enumeration fallback (`mintTs=0`) show "reveal pending" forever instead of a countdown. `rollOf` is also declared `uint16` while `PackRegistry` returns `uint256` (input-only selector, value < 10000, decoding unaffected). Display only; no transaction is built from either value.
- **Fix:** Rename to `drandGenesis()`/`drandPeriod()` and `rollOf(uint256) view returns (uint256)`.

## Confirmations (external checklists re-derived what was already closed or accepted)

| Title | Classification | Reference |
|---|---|---|
| Daily raffle REVEAL_LAG (1h) below the 4-day sequencer back-dating bound | ACCEPTED-RESIDUAL | SECURITY.md 16.2 (re-audit M-7) |
| Reveal liveness fallback lets first caller choose between two already-public beacons | ACCEPTED-RESIDUAL | SECURITY.md 16.4 (non-discretionary reveal fallback ladder) |
| Treasury revenue path hard-depends on Quotron's admin-gated router with no recovery lever | ACCEPTED-RESIDUAL | SECURITY.md 16.6 (write-once adapters + lockRouting permanent by design) |
| Pledge-flood dilution of the free-entry pledge region | ACCEPTED-RESIDUAL | SECURITY.md 16.8 (q^6 void-share bound, SR-first pick, seat-nonce cascade fix) |
| SLIP_BPS=12% swap slippage default ships to mainnet | KNOWN-RESIDUAL | WEB-SECURITY.md gap 6 (verified at index.html:3073; revisit at launch) |
| Testnet CHAIN/CSP/ROUTER/addresses; wire-web rewrites only address vars | KNOWN-RESIDUAL | WEB-SECURITY.md gap 4 + section 5; index.html/app.html excluded by web/.vercelignore |
| Single hardcoded RPC, no in-app fallback; O(N) enumeration; RPC IP-correlates identity | KNOWN-RESIDUAL | WEB-SECURITY.md gaps 7 and 9; SECURITY.md 16.9 |
| ~43 innerHTML sinks fed from chain data / undecoded revert strings under a meta CSP | KNOWN-RESIDUAL | WEB-SECURITY.md gaps 1 and 2 (revert text reaches sink ethers-decoded; no injection demonstrated) |
| web/app.html is a stale standalone mint console pinned to an old NFT address | KNOWN-HANDLED | Excluded from deploy by web/.vercelignore (must stay ignored or be deleted at launch) |
| runOpeningDraw() missing from the mainnet keeper (raffle stays OpeningPending) | KNOWN-DOCUMENTED | docs/OPERATIONS-BACKEND.md:157 + go-live checklist :186; runOpeningDraw is permissionless |
| GoLiveMainnet stamps launchTime at initialize without asserting it agrees with GENESIS | KNOWN-ACCEPTED | PREAUDIT genesis-default (closed low; GENESIS required via vm.envUint at Deploy.s.sol:105) |

## Low / info hardening list (deduped)

Items below are real cleanup work carried from the tracks that did not rise to a numbered finding. None threatens funds; the recurring theme is that the launch artifacts and off-chain runbooks lag the hardened onchain core.

- Go-live / deploy scripts: no `chainid` assert; unbounded `tickSpacing`; orphaned-hook write-once binding risk; single-EOA ownership at launch with no timelock handoff; non-payable recipient stranding; `GoLiveMainnet` routing-destination lock with no team-address cross-check.
- Deploy config: `.env.example` KEEPER "blank => deployer" comment contradicts the code (authorizes `address(0)`); align it with the fail-closed keeper requirement.
- Test coverage (defense-in-depth branches, code correct today): `ClaimManager` single-claim/sweep revert paths untested; `Treasury.convert` `SwapShortfall` untested.
- Keeper liveness: env-derived reveal-round math (`keeper.js:214`, GENESIS/REVEAL_DELAY plus a hardcoded DAY) can silently stall daily draws on config drift, whereas `prep-draw.js` reads the cadence from the contract; `fire()`'s unbounded `tx.wait()` (`keeper.js:143`) can wedge the whole loop on one stuck transaction.
- Operational griefing: permissionless `runOpeningDraw` must be called once at launch (documented, but no keeper step); the per-cohort pack-tier reveal has no fallback ladder unlike the one-shot NFT reveal.
- Metadata: the "Pool share" trait is misleading; no ERC-4906 metadata-update signal is emitted at reveal.
- Web wiring: `wire-web.mjs` leaves `delegate.html` on testnet config (it rewrites only quoted address constants); ensure the mainnet build path covers CHAIN/CSP/ROUTER for every shipped page or keep non-shipping pages in `.vercelignore`.

## Per-track health

**Contracts (12/12 specialists, 5 survivors, 3 refuted, 1 false positive, ~17 lows carried).** Fundamentally healthy: no fund-theft path survived, and every core invariant holds in code. Four net-new items survive dedupe, all launch-process hardening or bounded redistribution rather than a drain: go-live is non-atomic (FS-5, low), the keeper convert floor is quoted through the taxing hook (FS-2, medium), the free-entry SR set is rebuilt live and is steerable against its own non-steerable invariant (FS-3, medium, the one genuinely surprising deviation), and accepted residual 16.7 rests on a now-stale grossQPULL premise (FS-6, low). The one false positive was the "convert MEV is not bounded" claim, refuted by both lenses since the fail-closed per-call caps bound it per 16.6. Three refuted items were correctly matched to accepted residuals 16.2/16.4/16.6 and one to 16.8.

**Web app + swap path (9/9, 3 survivors, 10 refuted, 10 false positives, 15 lows carried).** No medium-or-higher survives. All three findings that cleared the survival gate were adjusted to low by the verify lenses and confirmed by spot-check. The "12% slippage" surviving candidate was reclassified into WEB-SECURITY.md gap 6 (already accepted with a launch revisit note) and moved to confirmations. The web track ships its own accepted-residuals doc (WEB-SECURITY.md) that absorbs most of the noise: the testnet-wiring cluster is gap 4 + the mainnet-gate checklist, the single-RPC/enumeration/privacy cluster is gaps 7/9, and the innerHTML/XSS cluster is gaps 1/2, which is why the ten refuted medium-tier findings are genuine false positives (two, the swap route and the slippage, had a real low core carried down or moved to confirmations). Real residual risk is a cluster of pre-launch operational and UX-parity lows (FS-7 through FS-21, FS-24), none exploitable today because the delegate flow is `LOCKED=true` and index.html/app.html are excluded from the pre-launch deploy, but all fire the instant the site is unlocked. Money-path fundamentals are clean: exact-amount approvals (never MaxUint256), quote-freshness and non-zero-minOut refusal before signing, exact `msg.value` enforced onchain, all shipped allowlist proofs re-derive to the shipped root, and ethers is SRI-pinned with a fail-closed banner.

**Keeper (4/4, 2 survivors, 1 refuted, 2 false positives, 2 lows carried).** In good shape on the primary automated path and weak only on secondary manual tooling and a slippage-quoting detail. The leg-1 convert floor is genuinely quoted through the taxing hook while the real adapter swap is fee-exempt (FS-2), but it never reverts, is bounded by `maxConvertPerCall`, ships disabled by default, and runs on a single-sequencer Orbit L2 with no public mempool. The manual beacon CLIs print a stale 2-arg `submitBeacon` command (FS-9); the automated `keeper.js` beacon path is correct, so the impact is confined to the operator copy-paste path and the failure is loud and fund-safe. Two lows carried (reveal-round env drift, unbounded `tx.wait()`). The refuted `runOpeningDraw` finding is a true false positive: the keeper does not call it and `runDraw` is gated on `openingDone`, but `runOpeningDraw` is permissionless and a one-time launch bootstrap, so daily draws are only pending that documented step, not permanently frozen.

**Deploy / ops / tests (4/4, 4 survivors, 5 refuted, 2 false positives, 6 lows carried).** No live fund-loss path; both prior audits' verdict still holds for shipped runtime behavior. The one net-new item that matters is the ticket-price denomination drift (FS-1), a genuine half-completed migration that would silently zero every paid raffle ticket for the launch window if the operator follows the shipped docs; the pre-audit closure of this denomination issue was comment-only and never touched the mainnet env-var name. The other three net-new items are test-coverage/regression gaps over already-correct code (FS-4 BaseVault custody, FS-22 pot-cap knobs, FS-23 leaderboard clamp). False positives: the `ClaimManager.settleSelf` test claim (double-refuted) and the web/index.html mainnet-chain claim (rewritten by `wire-web.mjs`, so the testnet address never ships).

**Red team (4/4, 1 survivor, 3 refuted, 3 false positives, 0 lows).** Clean on its core mandate: no value-extraction, brick, or freeze path survived. Every attack constructed (Treasury drain, vault theft, claim theft, beacon bias/replay, draw-steering, sybil/wash, pledge-flood, untaxed LP side-door, gate/throttle/7702 bypass, convert MEV, reveal-ladder grief, flash-loan) was killed by an explicit, load-bearing control. The only survivor is the ticket-price config footgun (deduped into FS-1). The three refuted medium candidates (keeper never calls runOpeningDraw; mainnet web ships a testnet router; wire-web leaves CHAIN/CSP on testnet) are false positives in this lane; the router/CHAIN mismatch is a real web/ops correctness issue (carried as FS-7 and confirmations) but is not a value-extraction path.

**Total false positives refuted across all tracks: 18** (contracts 1, web 10, keeper 2, deploy 2, red team 3).

## Coverage

The per-track synthesis payloads reported all 33 specialists as completed (contracts 12/12, web 9/9, keeper 4/4, deploy 4/4, red team 4/4) and did not surface individual sub-full coverage notes. The structural coverage limits that bound this pass, stated plainly:

- **Secrets excluded by hard rule:** `keeper/.env` and any keystore were never opened; keeper analysis used `keeper/.env.example` for variable names only. Any defect that depends on the live private key's handling is out of scope by design.
- **Allowlist data inspected for structure only:** `web/allowlist.json` and `tools/inputs/*` were examined for root, leaf format, and counts; no wallet addresses were enumerated or printed, so per-address allowlist correctness beyond the root-derivation check (all shipped proofs re-derive to the shipped root) was not exhaustively re-walked.
- **`GoLiveMainnet.s.sol` has never run against a real PoolManager:** FS-5 and the go-live lows are reasoned from the script and hook source, not from an executed fork run. A dry-run on an anvil fork before go-live is the intended confirmation and is a launch-checklist prerequisite, not an audit deliverable.
- **The convert() / WETH-to-QUOTRON leg is never-onchain:** FS-2 and the convert lows are traced through `keeper.js`, `Treasury`, and the adapters against the verified Quotron addresses; no live convert was executed.
- **Read-only audit:** no file was modified and no test was run as part of this pass, so the test-coverage findings (FS-4, FS-22, FS-23) are derived from static inspection of `test/` for the presence of asserting cases, not from a coverage-instrumented run.
