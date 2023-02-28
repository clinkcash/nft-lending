// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";

/// @title NFT lending vault
/// @notice This contracts allows users to borrow CLK using NFTs as collateral.
contract NFTSwapperMock {
    using SafeERC20 for IERC20;

    address public clink;

    constructor(address _clink) {
        clink = _clink;
    }

    function swap(
        address _nft,
        uint256 tokenId,
        uint256 debtAmount,
        address positionOwner
    ) external returns (uint256 extraAmount) {
        IERC20(clink).transfer(msg.sender, debtAmount);
    }
}
