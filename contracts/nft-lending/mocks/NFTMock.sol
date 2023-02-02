// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/presets/ERC721PresetMinterPauserAutoId.sol";

contract NFTMock is ERC721PresetMinterPauserAutoId {
    constructor(string memory name_, string memory symbol_)
        ERC721PresetMinterPauserAutoId(name_, symbol_, "")
    {}

    using Counters for Counters.Counter;
    Counters.Counter private _tokenIdTracker;

    function mint(address to) public virtual override {
        _mint(to, _tokenIdTracker.current());
        _tokenIdTracker.increment();
    }
}
