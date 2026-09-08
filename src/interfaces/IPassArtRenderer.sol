// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IPassArtRenderer
/// @notice Builds an NFTCollection pass's full on-chain `data:application/json;base64,...` token URI.
/// @dev    Called by NFTCollection.tokenURI. `revealed` is false while the pass is sealed (returns the
///         sealed art); once true, `rarity` (0=Common..3=Super rare) selects the revealed tier art.
interface IPassArtRenderer {
    function tokenURI(uint256 tokenId, bool revealed, uint8 rarity) external view returns (string memory);
}
