// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IERC20BurnMintable  {
    function mint(address to, uint256 amount) external;

    function burn(uint256 amount) external;

    function burnFrom(address account, uint256 amount) external;
}
