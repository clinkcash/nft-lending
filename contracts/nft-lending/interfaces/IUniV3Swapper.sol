// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IUniV3Swapper {
    function swap(
        address nft,
        uint256 tokenId,
        uint256 debtAmount,
        address positionOwner
    ) external returns (uint256 extraAmount);
}
