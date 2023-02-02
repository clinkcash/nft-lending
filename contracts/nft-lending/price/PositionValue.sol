// SPDX-License-Identifier: MIT
pragma solidity >=0.4.0 <0.8.0;

import "../libraries/PositionValueLib.sol";

/// @title NFT USD Price helper
contract PositionValue {
    function computeAddress(
        address factory,
        address token0,
        address token1,
        uint24 fee
    ) external pure returns (address pool) {
        return
            PoolAddress.computeAddress(
                factory,
                PoolAddress.PoolKey({token0: token0, token1: token1, fee: fee})
            );
    }

    function total(
        IUNIV3NFT univ3nft,
        uint256 tokenId,
        uint160 sqrtRatioX96
    ) external view returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = PositionValueLib.total(
            univ3nft,
            tokenId,
            sqrtRatioX96
        );
    }
}
