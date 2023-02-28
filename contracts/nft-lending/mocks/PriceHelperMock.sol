// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "../interfaces/IPriceHelper.sol";

/// @title NFT USD Price helper
contract PriceHelperMock is IPriceHelper {
    // nft address,token id -> usd price
    mapping(address => mapping(uint256 => uint256)) public _priceMap;

    /// @dev Returns the value in USD of the NFT at index `_tokenId`
    /// @param _tokenId The NFT to return the value of
    /// @return The value of the NFT in USD, 18 decimals
    function getNFTValueUSD(address _nftContract, uint256 _tokenId) public view override returns (uint256) {
        return _priceMap[_nftContract][_tokenId];
    }

    function isOpen(address _nftContract, uint256 _tokenId) public view override returns (bool) {
        return true;
    }

    function setPrice(
        address _nftContract,
        uint256 _tokenId,
        uint256 _price
    ) public {
        _priceMap[_nftContract][_tokenId] = _price;
    }
}
