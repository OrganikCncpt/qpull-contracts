// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { NonRenounceableOwnable2Step } from "./utils/NonRenounceableOwnable2Step.sol";
import { ISwapAdapter } from "./interfaces/ISwapAdapter.sol";

/// @title  Treasury
/// @notice Receives the 4% trade tax from QpullTaxHook — in QPULL (buys) AND WETH (exact-in sells,
///         audit H-2) — and, on a batched `convert()`, turns it into prize inventory: QPULL → WETH
///         (via adapter), team takes 20% of all WETH, the remaining 80% → QUOTRON and is split to
///         the three prize vaults (spec §3). Batching keeps Quotron's 3% hook fee (§9) off every
///         trade — it is paid once per conversion.
///
/// @dev    Split, in bps of total tax: raffle 6125 / holder 625 / leaderboard 1250 / team 2000.
///         Swaps route through ISwapAdapter with slippage bounds, keeper-gated (see convert()).
///         The QpullWethAdapter is fee-exempt on the hook (exemptSender), so the protocol-side
///         QPULL→WETH conversion swap is itself untaxed.
contract Treasury is NonRenounceableOwnable2Step, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    IERC20 public immutable qpull;
    IERC20 public immutable weth;
    IERC20 public immutable quotron;

    uint256 internal constant BPS = 10_000;
    uint256 public constant TEAM_BPS = 2000; // 20% of tax
    uint256 public constant HOURLY_BPS = 6125; // 61.25% (daily raffle)
    uint256 public constant HOLDER_BPS = 625; // 6.25% (weekly holder draw)
    uint256 public constant LEADERBOARD_BPS = 1250; // 12.5% (doubled from 6.25%)
    uint256 internal constant PRIZE_BPS = HOURLY_BPS + HOLDER_BPS + LEADERBOARD_BPS; // 8000

    ISwapAdapter public qpullWeth; // QPULL -> WETH
    ISwapAdapter public wethQuotron; // WETH -> QUOTRON
    address public prizeVault;
    address public holderVault;
    address public leaderboardVault;
    address public team;

    uint256 public convertThreshold; // min QPULL balance before convert() proceeds
    // Max QPULL swapped per convert() call. The owner sets a pool-sized ceiling at go-live so an untaxed
    // donation that inflates the balance beyond pool depth can't permanently brick convert() — the keeper
    // just drains the excess over several pool-sized slices (audit H-3). Excess stays as QPULL balance.
    // pre-audit MEDIUM (treasury-convert): this used to DEFAULT to type(uint256).max (fail-OPEN) and no
    // deploy/go-live script ever armed it, silently nullifying H-3. It now defaults to 0 = "not configured"
    // and convert() reverts NotConfigured until BOTH caps are armed (script/GoLiveMainnet.s.sol, step 1).
    // The setter already rejects 0, so 0 is an unambiguous "never set" sentinel.
    uint256 public maxConvertPerCall; // 0 = not configured (fail-closed); see convert()
    // Max WETH swapped per convert() call — the mirror of maxConvertPerCall for the SECOND leg (audit H-1).
    // Since the V4 hook now delivers sell-tax as WETH straight to this Treasury, WETH is a donation-inflatable
    // balance too: without a cap, one large WETH donation would force the whole balance through the shallow
    // QUOTRON pool in a single swap, and a revert there (oversized input) reverts the entire nonReentrant
    // convert() — stranding the QPULL leg too, since convert() is the ONLY path that moves WETH out. Same
    // fail-closed default as maxConvertPerCall: 0 until the owner arms a pool-sized ceiling at go-live.
    uint256 public maxWethConvertPerCall; // 0 = not configured (fail-closed); see convert()
    mapping(address => bool) public isKeeper; // only an authorized keeper may trigger convert()
    mapping(address => uint256) public quotronOwed; // M-2 (pass-7): QUOTRON stuck on a failed vault send, retried to THAT vault

    // audit F2 (pass-5): setRouting sets convert()'s unconditional payout destinations (the three prize
    // vaults + the 20% team cut). It was freely re-settable, so a compromised owner could redirect ALL
    // converted prize funding to attacker addresses. We keep it mutable through staged launch wiring, then
    // the owner calls lockRouting() ONCE to freeze the destinations forever. The keeper role stays mutable
    // on purpose — it is a rotatable hot key whose only residual is the bounded, cap-limited convert MEV.
    bool public routingLocked;

    event AdaptersSet(address qpullWeth, address wethQuotron);
    event RoutingSet(address prizeVault, address holderVault, address leaderboardVault, address team);
    event RoutingLocked();
    event ConvertThresholdSet(uint256 convertThreshold);
    event MaxConvertPerCallSet(uint256 maxConvertPerCall);
    event MaxWethConvertPerCallSet(uint256 maxWethConvertPerCall);
    event KeeperSet(address indexed keeper, bool authorized);
    event Converted(uint256 qpullIn, uint256 wethOut, uint256 quotronOut, uint256 teamWeth);

    error NotConfigured();
    error BelowThreshold();
    error NotKeeper();
    error SwapShortfall();
    error RoutingAlreadyLocked(); // audit F2 (pass-5)
    error VaultsNotDistinct(); // external audit F-1: aliased vaults double-count in owedTotal
    error OwedBeforeReroute(); // external audit F-1: a reroute would orphan the outgoing vault's owed slice
    error CapTooLarge(); // external audit F-5: the go-live script's != max assertion, moved on-chain
    error UnexpectedNft(); // pre-submission N-4 variant: only QUOTRON's own auto-mint may push a 721 here

    modifier onlyKeeper() {
        if (!isKeeper[msg.sender]) revert NotKeeper();
        _;
    }

    constructor(address qpull_, address weth_, address quotron_, address initialOwner) Ownable(initialOwner) {
        // external audit F-9: these three bindings are immutable with no re-deploy path, so a zero address
        // here is permanent and bricks convert() unconditionally — balanceOf on a codeless address returns
        // EMPTY returndata and the decoder rejects it (the extcodesize check is skipped when return data is
        // expected). Fail at construction rather than at the first convert().
        if (qpull_ == address(0) || weth_ == address(0) || quotron_ == address(0)) revert NotConfigured();
        qpull = IERC20(qpull_);
        weth = IERC20(weth_);
        quotron = IERC20(quotron_);
    }

    /// @notice Authorize/deauthorize a keeper allowed to call convert(). Gating convert() is the fix for
    ///         the audit finding that a permissionless convert() with a caller-supplied slippage floor is
    ///         sandwichable — only a trusted keeper that computes a tight off-chain minOut may trigger it.
    function setKeeper(address k, bool v) external onlyOwner {
        isKeeper[k] = v;
        emit KeeperSet(k, v);
    }

    /// @dev audit L3 (job-745): the swap adapters custody QPULL/WETH mid-convert(), so lockRouting() freezes
    ///      them too — every convert() binding is now under the one-way launch lock, no asymmetric exception.
    function setAdapters(address qpullWeth_, address wethQuotron_) external onlyOwner {
        if (routingLocked) revert RoutingAlreadyLocked();
        if (qpullWeth_ == address(0) || wethQuotron_ == address(0)) revert NotConfigured(); // audit L-5
        qpullWeth = ISwapAdapter(qpullWeth_);
        wethQuotron = ISwapAdapter(wethQuotron_);
        emit AdaptersSet(qpullWeth_, wethQuotron_);
    }

    function setRouting(address prize_, address holder_, address leaderboard_, address team_)
        external
        onlyOwner
    {
        if (routingLocked) revert RoutingAlreadyLocked(); // audit F2 (pass-5): destinations are final
        if (
            prize_ == address(0) || holder_ == address(0) || leaderboard_ == address(0)
                || team_ == address(0)
        ) {
            revert NotConfigured(); // audit M-1: no zero routing destinations
        }
        // external audit F-1 (a): convert() computes owedTotal by summing quotronOwed at the three CURRENT
        // role addresses. If two roles share an address that sum double-counts it, permanently under-computing
        // `splittable` for every later convert(). Nothing else in the file rejects aliasing. `team` is exempt:
        // it takes WETH, never QUOTRON, and is not part of owedTotal.
        if (prize_ == holder_ || holder_ == leaderboard_ || prize_ == leaderboard_) revert VaultsNotDistinct();
        // external audit F-1 (b): quotronOwed is keyed by raw address. Rerouting a role away from a vault that
        // still holds an owed slice makes that slice invisible to owedTotal forever — it is folded into the
        // next `splittable` and paid to whichever vaults are current, which is exactly the silent
        // redistribution the M-2 retry mechanism exists to prevent. The launch order (Deploy wires routing,
        // GoLive arms the caps then locks) means this is unreachable today; this makes it unreachable by
        // CONSTRUCTION rather than by procedure.
        if (
            quotronOwed[prizeVault] != 0 || quotronOwed[holderVault] != 0
                || quotronOwed[leaderboardVault] != 0
        ) revert OwedBeforeReroute();
        prizeVault = prize_;
        holderVault = holder_;
        leaderboardVault = leaderboard_;
        team = team_;
        emit RoutingSet(prize_, holder_, leaderboard_, team_);
    }

    /// @notice One-way, irreversible: freeze convert()'s payout destinations forever (audit F2, pass-5).
    ///         The owner calls this once at launch after setRouting is verified. After this, no owner (or
    ///         compromised owner key) can redirect prize funding or the team cut. The keeper role is left
    ///         rotatable by design (setKeeper); its only residual is the bounded, cap-limited convert MEV.
    function lockRouting() external onlyOwner {
        // audit L2 (job-745): refuse to freeze an INCOMPLETE config — locking before wiring would brick
        // convert() forever. Require exactly what convert() demands (adapters + all four destinations).
        if (
            address(qpullWeth) == address(0) || address(wethQuotron) == address(0) || prizeVault == address(0)
                || holderVault == address(0) || leaderboardVault == address(0) || team == address(0)
        ) revert NotConfigured();
        // external audit F-8: convert() ALSO requires both caps (see its own NotConfigured check), so a lock
        // that verifies only the six addresses promises a completeness it does not check. Callers must arm the
        // caps first. NOTE: this reorders script/DeployTestnet.s.sol, which used to lock in-deploy and leave
        // the caps to GoLiveTestnet; it now arms them immediately before the lock, matching GoLiveMainnet.
        if (maxConvertPerCall == 0 || maxWethConvertPerCall == 0) revert NotConfigured();
        routingLocked = true;
        emit RoutingLocked();
    }

    function setConvertThreshold(uint256 t) external onlyOwner {
        // L-6 (pass-7): intentionally NOT frozen by lockRouting — pool-sized conversion limits are tuned at
        // go-live (after the pool exists) and may need ongoing tuning; the owner-griefing risk is bounded and
        // reversible, and mitigated by the timelock+multisig owner migration (see SECURITY.md).
        convertThreshold = t;
        emit ConvertThresholdSet(t);
    }

    /// @notice Ceiling on QPULL swapped per convert() call (audit H-3). Lets the keeper drain a donation-
    ///         inflated balance in pool-sized slices instead of bricking on a single oversized swap.
    function setMaxConvertPerCall(uint256 m) external onlyOwner {
        if (m == 0) revert BelowThreshold();
        if (m == type(uint256).max) revert CapTooLarge(); // external audit F-5, see setMaxWethConvertPerCall
        maxConvertPerCall = m;
        emit MaxConvertPerCallSet(m);
    }

    /// @notice Ceiling on WETH swapped per convert() call (audit H-1) — the mirror of maxConvertPerCall for
    ///         the WETH→QUOTRON leg, so a WETH donation can't force an oversized single swap that bricks the
    ///         whole pipeline. The keeper drains the excess in pool-sized slices.
    function setMaxWethConvertPerCall(uint256 m) external onlyOwner {
        // external audit F-5: SECURITY.md 16.6 claimed these caps "are not a rug lever" because they cannot
        // redirect funds or change the split. True, and beside the point — value leaves through swap SLIPPAGE
        // without any destination changing. setKeeper is likewise never lock-gated (deliberately, a rotatable
        // hot key), so post-lock a compromised owner could set this to max, self-grant keeper, and call
        // convert(0,0) to sandwich an uncapped slice through the shallow QUOTRON pool. The != max bound that
        // was supposed to prevent that lived in script/GoLiveMainnet.s.sol, which has ALREADY RUN by then.
        // Moving it on-chain makes it survive the script. Ordinary re-tuning (caps must track pool depth as
        // the locked LP accrues fees) is unaffected: only the literal max is refused.
        if (m == 0) revert BelowThreshold();
        if (m == type(uint256).max) revert CapTooLarge();
        maxWethConvertPerCall = m;
        emit MaxWethConvertPerCallSet(m);
    }

    /// @notice Batch-convert accumulated QPULL tax into prize inventory + team WETH. KEEPER-ONLY.
    /// @param  minWethOut     slippage floor for QPULL→WETH, computed OFF-CHAIN by the keeper
    /// @param  minQuotronOut  slippage floor for WETH→QUOTRON, computed OFF-CHAIN
    /// @dev    Keeper-gated (onlyKeeper): the off-chain slippage floors are only trustworthy from a keeper
    ///         that computes them tightly. A permissionless convert() would let an adversary pass a nominal
    ///         floor (minOut=1) and sandwich the whole batch through the shallow pool — the audit finding
    ///         this gate closes. The keeper account should be a bot key the team controls (rotatable).
    function convert(uint256 minWethOut, uint256 minQuotronOut) external nonReentrant onlyKeeper {
        if (
            address(qpullWeth) == address(0) || address(wethQuotron) == address(0) || prizeVault == address(0)
                || holderVault == address(0) || leaderboardVault == address(0) || team == address(0)
        ) revert NotConfigured(); // audit M-1: holder/leaderboard vaults are unconditional transfer targets
        // pre-audit MEDIUM (treasury-convert): both per-call caps ship as 0 = "not configured", and convert()
        // refuses to run until the owner arms BOTH pool-sized ceilings — H-1/H-3 fail CLOSED instead of
        // silently uncapped. The setters reject 0, so a 0 here can only mean "never set".
        if (maxConvertPerCall == 0 || maxWethConvertPerCall == 0) revert NotConfigured();

        // Tax arrives in TWO currencies since the V4 hook (audit H-2): buys pay QPULL, exact-in sells
        // pay WETH — QpullTaxHook take()s both straight to this Treasury. QPULL converts via leg 1;
        // WETH already held merges into the flow after it.
        uint256 qpullBal = qpull.balanceOf(address(this));
        uint256 wethHeld = weth.balanceOf(address(this));
        // Gate on the RAW balance, THEN cap the slice. convertThreshold is a MIN-BATCH gate ("enough tax
        // accumulated to amortize the swap"); maxConvertPerCall is a MAX-SLICE safety ("don't swap more
        // than pool depth per call", audit H-3). These are independent — testing the threshold against
        // the already-capped slice would let any config with maxConvertPerCall < convertThreshold strand
        // the QPULL leg forever (H-2 review, hardened): the slice can never reach the threshold, so the
        // QPULL→WETH conversion never runs even with a huge balance.
        // audit F10: also skip the QPULL leg when a full WETH slice is already backed up (wethHeld >=
        // maxWethConvertPerCall). The QPULL leg's WETH OUTPUT is bounded only by the deep QPULL/WETH pool,
        // not by maxWethConvertPerCall (which is sized for the shallow QUOTRON pool), so without this a
        // single call's QPULL→WETH output can exceed the WETH cap and the unprocessed WETH grows every
        // call instead of draining. Draining the WETH backlog first keeps the two legs from diverging.
        bool qpullLeg = qpullBal > 0 && qpullBal >= convertThreshold && wethHeld < maxWethConvertPerCall;
        uint256 qpullIn = qpullBal > maxConvertPerCall ? maxConvertPerCall : qpullBal; // pool-sized slice
        // Sub-threshold QPULL waits for more tax; a WETH-only sweep is always allowed (threshold is an
        // anti-dust backstop for the QPULL swap leg, and convert() is keeper-gated anyway).
        if (!qpullLeg && wethHeld == 0) revert BelowThreshold();

        // 1. QPULL -> WETH. Trust the MEASURED balance delta, not the adapter's return value (audit H-14):
        //    a malicious/buggy adapter could take the approved QPULL and return a fabricated number.
        if (qpullLeg) {
            uint256 wethBefore = weth.balanceOf(address(this));
            qpull.forceApprove(address(qpullWeth), qpullIn);
            qpullWeth.swapExactIn(address(qpull), address(weth), qpullIn, minWethOut, address(this));
            qpull.forceApprove(address(qpullWeth), 0); // audit L-10: leave no residual allowance
            if (weth.balanceOf(address(this)) - wethBefore < minWethOut) revert SwapShortfall();
        } else {
            qpullIn = 0; // nothing swapped this call
        }

        // 2. team slice — 20% of the WETH processed THIS batch. wethOut is capped to a pool-sized slice
        //    (audit H-1): the remainder stays as WETH balance and drains over subsequent convert() calls,
        //    so a WETH donation can never force an oversized single QUOTRON swap that bricks the pipeline.
        uint256 wethOut = weth.balanceOf(address(this)); // swapped + hook-fee WETH; all of it is tax
        if (wethOut > maxWethConvertPerCall) wethOut = maxWethConvertPerCall;
        uint256 teamWeth = (wethOut * TEAM_BPS) / BPS;
        if (teamWeth > 0) weth.safeTransfer(team, teamWeth); // audit job-745 info: zero-guard like the QUOTRON legs
        uint256 prizeWeth = wethOut - teamWeth;

        // 3. prize WETH -> QUOTRON — measured delta again (audit H-14). external audit F-10: skip the swap
        //    entirely on a zero slice, mirroring the zero-guards the team leg (L229) and the vault sends
        //    (_trySendQuotron) already have. prizeWeth reaches 0 only when leg 1 produced no WETH against a
        //    keeper-supplied minWethOut of 0, but whether the adapter tolerates amountIn == 0 is an
        //    out-of-scope property we should not depend on. The shortfall check stays OUTSIDE the guard so a
        //    keeper that asked for output it cannot get still reverts rather than silently succeeding.
        uint256 qOut;
        if (prizeWeth > 0) {
            uint256 qBefore = quotron.balanceOf(address(this));
            weth.forceApprove(address(wethQuotron), prizeWeth);
            wethQuotron.swapExactIn(address(weth), address(quotron), prizeWeth, minQuotronOut, address(this));
            weth.forceApprove(address(wethQuotron), 0); // audit L-10: leave no residual allowance
            qOut = quotron.balanceOf(address(this)) - qBefore; // THIS-swap delta — the floor check keys on it
        }
        if (qOut < minQuotronOut) revert SwapShortfall();

        // 4. Split the NEWLY-CONVERTED QUOTRON across the prize vaults (of the 8000 prize bps). The three sends
        //    are per-vault ISOLATED (best-effort) so a QUOTRON per-address blacklist of ONE vault can no longer
        //    revert the whole convert() and starve the other two + the team/QPULL legs. audit M-2 (pass-7): a
        //    failed send is credited to quotronOwed[vault] and retried ONLY to that same vault on the next
        //    convert() — so a stuck slice is never silently redistributed to its sibling games (the earlier
        //    "rides the next full-balance split" behaviour leaked ~92% of a stuck slice to the wrong vaults).
        //    We therefore split only `splittable` (balance minus already-owed), and _trySendQuotron folds each
        //    vault's own owed back in. (This does NOT defend the shared-codehash bannedVenueCodehash ban or a
        //    global QUOTRON pause, which hit all four vaults at once — an accepted external-admin trust boundary;
        //    see SECURITY.md.) Zero-value legs are skipped (audit M-5): a thin batch floors the small legs to 0.
        uint256 qBal = quotron.balanceOf(address(this));
        uint256 owedTotal = quotronOwed[prizeVault] + quotronOwed[holderVault] + quotronOwed[leaderboardVault];
        uint256 splittable = qBal > owedTotal ? qBal - owedTotal : 0; // only the fresh conversion is split by ratio
        uint256 toHolder = (splittable * HOLDER_BPS) / PRIZE_BPS;
        uint256 toLeaderboard = (splittable * LEADERBOARD_BPS) / PRIZE_BPS;
        uint256 toHourly = splittable - toHolder - toLeaderboard;
        _trySendQuotron(prizeVault, toHourly);
        _trySendQuotron(holderVault, toHolder);
        _trySendQuotron(leaderboardVault, toLeaderboard);

        emit Converted(qpullIn, wethOut, qOut, teamWeth);
    }

    /// @dev audit M-2 (pass-7): best-effort QUOTRON send that retries to the SAME vault. Sends `amount` PLUS any
    ///      previously-owed slice for `to` (a prior blacklisted send); on failure the whole total is re-credited
    ///      to quotronOwed[to], so a stuck vault's funds always retry to IT — never redistributed to siblings
    ///      (the M-2 fix). A per-address-blacklisted recipient thus can't brick convert() OR misallocate its
    ///      game's funding. Reentrancy-safe: convert() is nonReentrant, these sends are its LAST step (nothing
    ///      runs after them), and real QUOTRON auto-exempts contract recipients from the ERC-404 callback.
    function _trySendQuotron(address to, uint256 amount) private {
        uint256 total = amount + quotronOwed[to];
        if (total == 0) return; // preserves the M-5 zero-value skip
        quotronOwed[to] = 0; // clear first; re-set below if the send still fails
        // audit M-1 (pass-8): a standards-compliant ERC-20 may signal a blacklisted/failed transfer by
        // RETURNING false rather than reverting — in which case the low-level call still reports ok==true.
        // Decode and require the boolean (SafeERC20 discipline) so a non-reverting false re-owes to THIS
        // vault instead of silently leaving the tokens un-owed for the next convert() to re-split to siblings.
        // external audit F-2 + F-7, fixed together because they share one line. The previous form was
        //   (bool ok, bytes memory ret) = ...call(...);  bool success = ok && (ret.length == 0 || abi.decode(ret,(bool)));
        // which had two defects, both defeating the per-vault isolation this helper exists to provide:
        //   F-2: abi.decode REVERTS on return data that is neither empty nor a well-formed 32-byte bool.
        //        Measured, not assumed: a 1..31-byte buffer reverts on out-of-bounds decoding and a 32-byte
        //        non-boolean panics. That revert propagates out of the nonReentrant convert() and unwinds the
        //        whole batch — the entire failure mode M-1/M-2 were written to eliminate, reached by a third
        //        shape. (0, 32-byte bool and 64-byte-with-leading-bool all behaved correctly and still do.)
        //   F-7: capturing `bytes memory ret` copies the ENTIRE return buffer, so a callee returning a huge
        //        payload forces quadratic memory expansion on the caller — a return-data bomb.
        // Reading returndatasize() and copying at most one word closes both: it never reverts on a malformed
        // reply (the slice is simply re-owed and retried next convert) and never copies more than 32 bytes.
        (bool ok,) = address(quotron).call(abi.encodeCall(IERC20.transfer, (to, total)));
        bool success;
        if (ok) {
            uint256 rds;
            assembly ("memory-safe") {
                rds := returndatasize()
            }
            if (rds == 0) {
                success = true; // a non-standard token that returns nothing on success
            } else if (rds >= 32) {
                uint256 word;
                assembly ("memory-safe") {
                    returndatacopy(0x00, 0x00, 32) // scratch space; never more than one word
                    word := mload(0x00)
                }
                success = (word == 1); // anything else (incl. a 32-byte non-boolean) counts as failure
            }
            // 1..31 bytes: malformed. Leave success false so the slice is re-owed, and do NOT revert.
        }
        if (!success) quotronOwed[to] = total; // still blocked: owe the full slice to THIS vault, retry next convert
    }

    /// @notice ERC-404 terminal-mint safety (§13.3), defense-in-depth. A convert() batch that buys ≥1
    ///         whole QUOTRON unit crosses a whole-unit boundary on receipt. test/fork/QuotronWholeUnitFork
    ///         shows real QUOTRON does NOT fire a receiver callback on a plain contract (it appears to
    ///         auto-exempt contracts from the NFT side), so convert() is safe without this. We implement
    ///         it anyway — zero cost, uniform with the vaults, and a hedge if that exemption ever changes.
    /// @dev VARIANT of pre-submission review N-4 (found on BaseVault, swept here). This hook was
    ///      unconditional, and Treasury has NO ERC-721 egress either — no transferFrom, no rescue, no
    ///      sweep — so any 721 sent here was destroyed. The Treasury address is published deploy output,
    ///      making a misdirected safeTransferFrom a realistic accident rather than an attack. Gating on
    ///      msg.sender keeps the entire documented §13.3 purpose (QUOTRON's ERC-404 auto-mint always calls
    ///      with msg.sender == quotron) and restores the revert ERC-721's _checkOnERC721Received would
    ///      otherwise have given the sender.
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        view
        override
        returns (bytes4)
    {
        if (msg.sender != address(quotron)) revert UnexpectedNft();
        return IERC721Receiver.onERC721Received.selector;
    }
}
