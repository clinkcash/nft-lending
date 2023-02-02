// SPDX-License-Identifier: MIT
pragma solidity >=0.4.0;

import "../interfaces/IUNIV3NFT.sol";

interface IPositionValue {
    function computeAddress(
        address factory,
        address token0,
        address token1,
        uint24 fee
    ) external pure returns (address pool);

    function total(
        IUNIV3NFT univ3nft,
        uint256 tokenId,
        uint160 sqrtRatioX96
    ) external view returns (uint256 amount0, uint256 amount1);
}
