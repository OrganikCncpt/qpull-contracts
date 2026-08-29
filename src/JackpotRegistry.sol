// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IJackpotRegistry } from "./interfaces/IRegistries.sol";

/// @title  JackpotRegistry
/// @notice Records pari-mutuel jackpot entries for the current period (spec §10). The jackpot draws
///         every **14 days**. Both buys and sells mint entries ∝ trade size, so entries ∝ tax
///         contribution — the property that makes the pot self-policing (a wash round-trip recovers
///         at most a small fraction of its tax).
///
/// @dev    Weighted selection uses an append-only segment array per period: each trade appends one
///         segment ending at the running cumulative total. The winner for target `r` is the first
///         segment whose cumulative end exceeds `r` — found by binary search, O(log trades).
contract JackpotRegistry is IJackpotRegistry, Ownable2Step {
    uint256 public immutable genesis;
    uint256 public constant PERIOD = 14 days;

    address public token; // QPULLToken — only caller of recordTrade

    struct Seg {
        uint256 cumEnd; // running cumulative entry total up to and including this trade
        address trader;
    }

    mapping(uint256 => Seg[]) internal segs; // period => segments
    mapping(uint256 => uint256) public periodTotal; // period => total entries

    event TokenSet(address token);
    event Entry(uint256 indexed period, address indexed trader, uint256 amount, uint256 periodTotal);

    error NotToken();

    modifier onlyToken() {
        if (msg.sender != token) revert NotToken();
        _;
    }

    constructor(uint256 genesis_, address initialOwner) Ownable(initialOwner) {
        genesis = genesis_;
    }

    function setToken(address t) external onlyOwner {
        token = t;
        emit TokenSet(t);
    }

    /// @inheritdoc IJackpotRegistry
    function recordTrade(address trader, uint256 grossValue) external override onlyToken {
        if (grossValue == 0) return;
        uint256 p = _period();
        uint256 newTotal = periodTotal[p] + grossValue;
        periodTotal[p] = newTotal;
        segs[p].push(Seg({ cumEnd: newTotal, trader: trader }));
        emit Entry(p, trader, grossValue, newTotal);
    }

    /// @notice The entrant whose cumulative range contains target `r ∈ [0, periodTotal[period])`.
    function winnerAt(uint256 period, uint256 r) public view returns (address) {
        Seg[] storage s = segs[period];
        uint256 lo;
        uint256 hi = s.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) >> 1;
            if (s[mid].cumEnd > r) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        return s[lo].trader;
    }

    function segmentCount(uint256 period) external view returns (uint256) {
        return segs[period].length;
    }

    function _period() internal view returns (uint256) {
        if (block.timestamp <= genesis) return 0;
        return (block.timestamp - genesis) / PERIOD;
    }

    function currentPeriod() external view returns (uint256) {
        return _period();
    }
}
