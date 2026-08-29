// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ILeaderboardRegistry } from "./interfaces/IRegistries.sol";

/// @title  LeaderboardRegistry
/// @notice Tallies buy points per weekly period (buys only, spec §11) and maintains the running
///         top-25 board. Points = gross QPULL bought. Sells never touch this — a redistributive
///         top-N pool must not be fed by sells (they'd spend others' money to buy rank).
///
/// @dev    Board maintenance is O(1) when the buyer is already on the board or the board isn't full,
///         and O(25) only when a newcomer displaces the current minimum. The board is unsorted —
///         rank order doesn't matter because the payout √-weights all 25 members.
contract LeaderboardRegistry is ILeaderboardRegistry, Ownable2Step {
    uint256 public immutable genesis;
    uint256 internal constant WEEK = 7 days;
    uint256 public constant BOARD_SIZE = 25;

    address public token; // QPULLToken — only caller of recordBuy

    struct Entry {
        address addr;
        uint256 points;
    }

    mapping(uint256 => Entry[BOARD_SIZE]) internal board; // week => top-25
    mapping(uint256 => uint256) public boardCount; // week => filled slots (≤ 25)
    mapping(uint256 => mapping(address => uint256)) public points; // week => addr => points
    mapping(uint256 => mapping(address => uint256)) internal boardIndex; // week => addr => (slot+1); 0 = off-board

    event TokenSet(address token);
    event PointsAdded(uint256 indexed week, address indexed buyer, uint256 amount, uint256 total);

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

    /// @inheritdoc ILeaderboardRegistry
    function recordBuy(address buyer, uint256 grossValue) external override onlyToken {
        if (grossValue == 0) return;
        uint256 w = _week();
        uint256 p = points[w][buyer] + grossValue;
        points[w][buyer] = p;
        _updateBoard(w, buyer, p);
        emit PointsAdded(w, buyer, grossValue, p);
    }

    function _updateBoard(uint256 w, address addr, uint256 p) internal {
        uint256 idx = boardIndex[w][addr];
        if (idx != 0) {
            board[w][idx - 1].points = p; // already on board — bump points, keep slot
            return;
        }
        uint256 cnt = boardCount[w];
        if (cnt < BOARD_SIZE) {
            board[w][cnt] = Entry(addr, p);
            boardIndex[w][addr] = cnt + 1;
            boardCount[w] = cnt + 1;
            return;
        }
        // board full: locate the current minimum
        uint256 minI;
        uint256 minP = type(uint256).max;
        for (uint256 i; i < BOARD_SIZE; ++i) {
            uint256 pp = board[w][i].points;
            if (pp < minP) {
                minP = pp;
                minI = i;
            }
        }
        if (p > minP) {
            address evicted = board[w][minI].addr;
            boardIndex[w][evicted] = 0;
            board[w][minI] = Entry(addr, p);
            boardIndex[w][addr] = minI + 1;
        }
    }

    function boardAt(uint256 w, uint256 i) external view returns (address addr, uint256 pts) {
        Entry storage e = board[w][i];
        return (e.addr, e.points);
    }

    function isOnBoard(uint256 w, address a) external view returns (bool) {
        return boardIndex[w][a] != 0;
    }

    function _week() internal view returns (uint256) {
        if (block.timestamp <= genesis) return 0;
        return (block.timestamp - genesis) / WEEK;
    }

    function currentWeek() external view returns (uint256) {
        return _week();
    }
}
