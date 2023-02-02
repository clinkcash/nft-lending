// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IPriceHelper {
    function getNFTValueUSD(address _nftContract, uint256 _tokenId) external view returns (uint256);

    function isOpen(address _nftContract, uint256 _tokenId) external view returns (bool);
}
