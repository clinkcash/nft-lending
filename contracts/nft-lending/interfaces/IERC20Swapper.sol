// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20Swapper {
    function swap(
        address fromToken,
        address toToken,
        address recipient,
        uint256 amountIn
    ) external returns (uint256 amountTo);
}
