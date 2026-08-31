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
/// @dev    Split, in bps of total tax: raffle 6125 / jackpot 625 / leaderboard 1250 / team 2000.
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
    uint256 public constant JACKPOT_BPS = 625; // 6.25%
    uint256 public constant LEADERBOARD_BPS = 1250; // 12.5% (doubled from 6.25%)
    uint256 internal constant PRIZE_BPS = HOURLY_BPS + JACKPOT_BPS + LEADERBOARD_BPS; // 8000

    ISwapAdapter public qpullWeth; // QPULL -> WETH
    ISwapAdapter public wethQuotron; // WETH -> QUOTRON
    address public prizeVault;
    address public jackpotVault;
    address public leaderboardVault;
    address public team;

    uint256 public convertThreshold; // min QPULL balance before convert() proceeds
    // Max QPULL swapped per convert() call. Default uncapped; the owner sets a pool-sized ceiling at launch so
    // an untaxed donation that inflates the balance beyond pool depth can't permanently brick convert() — the
    // keeper just drains the excess over several pool-sized slices (audit H-3). Excess stays as QPULL balance.
    uint256 public maxConvertPerCall = type(uint256).max;
    // Max WETH swapped per convert() call — the mirror of maxConvertPerCall for the SECOND leg (audit H-1).
    // Since the V4 hook now delivers sell-tax as WETH straight to this Treasury, WETH is a donation-inflatable
    // balance too: without a cap, one large WETH donation would force the whole balance through the shallow
    // QUOTRON pool in a single swap, and a revert there (oversized input) reverts the entire nonReentrant
    // convert() — stranding the QPULL leg too, since convert() is the ONLY path that moves WETH out. Default
    // uncapped; owner sets a pool-sized ceiling at launch and the keeper drains the excess over several calls.
    uint256 public maxWethConvertPerCall = type(uint256).max;
    mapping(address => bool) public isKeeper; // only an authorized keeper may trigger convert()
    mapping(address => uint256) public quotronOwed; // M-2 (pass-7): QUOTRON stuck on a failed vault send, retried to THAT vault

    // audit F2 (pass-5): setRouting sets convert()'s unconditional payout destinations (the three prize
    // vaults + the 20% team cut). It was freely re-settable, so a compromised owner could redirect ALL
    // converted prize funding to attacker addresses. We keep it mutable through staged launch wiring, then
    // the owner calls lockRouting() ONCE to freeze the destinations forever. The keeper role stays mutable
    // on purpose — it is a rotatable hot key whose only residual is the bounded, cap-limited convert MEV.
    bool public routingLocked;

    event AdaptersSet(address qpullWeth, address wethQuotron);
    event RoutingSet(address prizeVault, address jackpotVault, address leaderboardVault, address team);
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

    modifier onlyKeeper() {
        if (!isKeeper[msg.sender]) revert NotKeeper();
        _;
    }

    constructor(address qpull_, address weth_, address quotron_, address initialOwner) Ownable(initialOwner) {
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

    function setRouting(address prize_, address jackpot_, address leaderboard_, address team_)
        external
        onlyOwner
    {
        if (routingLocked) revert RoutingAlreadyLocked(); // audit F2 (pass-5): destinations are final
        if (
            prize_ == address(0) || jackpot_ == address(0) || leaderboard_ == address(0)
                || team_ == address(0)
        ) {
            revert NotConfigured(); // audit M-1: no zero routing destinations
        }
        prizeVault = prize_;
        jackpotVault = jackpot_;
        leaderboardVault = leaderboard_;
        team = team_;
        emit RoutingSet(prize_, jackpot_, leaderboard_, team_);
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
                || jackpotVault == address(0) || leaderboardVault == address(0) || team == address(0)
        ) revert NotConfigured();
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
        maxConvertPerCall = m;
        emit MaxConvertPerCallSet(m);
    }

    /// @notice Ceiling on WETH swapped per convert() call (audit H-1) — the mirror of maxConvertPerCall for
    ///         the WETH→QUOTRON leg, so a WETH donation can't force an oversized single swap that bricks the
    ///         whole pipeline. The keeper drains the excess in pool-sized slices.
    function setMaxWethConvertPerCall(uint256 m) external onlyOwner {
        if (m == 0) revert BelowThreshold();
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
                || jackpotVault == address(0) || leaderboardVault == address(0) || team == address(0)
        ) revert NotConfigured(); // audit M-1: jackpot/leaderboard vaults are unconditional transfer targets

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

        // 3. prize WETH -> QUOTRON — measured delta again (audit H-14)
        uint256 qBefore = quotron.balanceOf(address(this));
        weth.forceApprove(address(wethQuotron), prizeWeth);
        wethQuotron.swapExactIn(address(weth), address(quotron), prizeWeth, minQuotronOut, address(this));
        weth.forceApprove(address(wethQuotron), 0); // audit L-10: leave no residual allowance
        uint256 qOut = quotron.balanceOf(address(this)) - qBefore; // THIS-swap delta — the floor check keys on it
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
        uint256 owedTotal = quotronOwed[prizeVault] + quotronOwed[jackpotVault] + quotronOwed[leaderboardVault];
        uint256 splittable = qBal > owedTotal ? qBal - owedTotal : 0; // only the fresh conversion is split by ratio
        uint256 toJackpot = (splittable * JACKPOT_BPS) / PRIZE_BPS;
        uint256 toLeaderboard = (splittable * LEADERBOARD_BPS) / PRIZE_BPS;
        uint256 toHourly = splittable - toJackpot - toLeaderboard;
        _trySendQuotron(prizeVault, toHourly);
        _trySendQuotron(jackpotVault, toJackpot);
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
        (bool ok,) = address(quotron).call(abi.encodeCall(IERC20.transfer, (to, total)));
        if (!ok) quotronOwed[to] = total; // still blocked: owe the full slice to THIS vault, retry next convert
    }

    /// @notice ERC-404 terminal-mint safety (§13.3), defense-in-depth. A convert() batch that buys ≥1
    ///         whole QUOTRON unit crosses a whole-unit boundary on receipt. test/fork/QuotronWholeUnitFork
    ///         shows real QUOTRON does NOT fire a receiver callback on a plain contract (it appears to
    ///         auto-exempt contracts from the NFT side), so convert() is safe without this. We implement
    ///         it anyway — zero cost, uniform with the vaults, and a hedge if that exemption ever changes.
    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }
}
