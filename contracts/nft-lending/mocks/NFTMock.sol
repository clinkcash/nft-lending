// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/presets/ERC721PresetMinterPauserAutoId.sol";

contract NFTMock is ERC721PresetMinterPauserAutoId {
    constructor(string memory name_, string memory symbol_) ERC721PresetMinterPauserAutoId(name_, symbol_, "") {}
}
