// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title INFTCollection
/// @notice The launch NFT. Rarity (Common/Uncommon/Rare/Super Rare) is revealed via drand and
///         drives the holder's free daily raffle entries (spec §16). Consumed by QPULLToken (the
///         first-hour gated-buy check) and PackRegistry (rarity-weighted free entries).
interface INFTCollection {
    function ownerOf(uint256 tokenId) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
    /// @return tier 0=Common,1=Uncommon,2=Rare,3=Super Rare. Reverts until the token's round reveals.
    function rarityOf(uint256 tokenId) external view returns (uint8);
}
