// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { INFTCollection } from "../../src/interfaces/INFTCollection.sol";

/// @notice Test double for the NFT: set ownership + rarity directly (no mint/drand needed).
contract MockNFT is INFTCollection {
    mapping(uint256 => address) internal _owner;
    mapping(address => uint256) internal _bal;
    mapping(uint256 => uint8) internal _rarity;

    function set(uint256 id, address owner_, uint8 rarity_) external {
        address prev = _owner[id];
        if (prev != address(0)) _bal[prev] -= 1;
        _owner[id] = owner_;
        _bal[owner_] += 1;
        _rarity[id] = rarity_;
    }

    function ownerOf(uint256 id) external view returns (address) {
        return _owner[id];
    }

    function balanceOf(address o) external view returns (uint256) {
        return _bal[o];
    }

    function rarityOf(uint256 id) external view returns (uint8) {
        return _rarity[id];
    }
}
