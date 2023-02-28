// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20FlashMint.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/IERC20BurnMintable.sol";

// @title Clink
contract Clink is
    IERC20BurnMintable,
    ERC20Permit,
    ERC20FlashMint,
    ERC20Burnable,
    AccessControl
{
    bytes32 public constant WL_ROLE = keccak256("WL_ROLE");

    constructor(address owner)
        payable
        ERC20("Clink stable coin", "CLK")
        ERC20Permit("Clink stable coin")
    {
        _grantRole(DEFAULT_ADMIN_ROLE, owner);
        _grantRole(WL_ROLE, owner);
    }

    function mint(address to, uint256 amount)
        public
        override
        onlyRole(WL_ROLE)
    {
        _mint(to, amount);
    }

    function burn(uint256 amount)
        public
        override(IERC20BurnMintable, ERC20Burnable)
    {
        ERC20Burnable.burn(amount);
    }

    function burnFrom(address account, uint256 amount)
        public
        override(IERC20BurnMintable, ERC20Burnable)
    {
        ERC20Burnable.burnFrom(account, amount);
    }

    function addWL(address _wl) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(WL_ROLE, _wl);
    }
}
