// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
import "../interfaces/IAggregatorV3Interface.sol";

contract AggregatorMock is IAggregatorV3Interface {
    int256 public _answer;

    constructor(int256 __answer) {
        _answer = __answer;
    }

    function decimals() external pure override returns (uint8) {
        return 6;
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        roundId = 1;
        startedAt = 1;
        updatedAt = 1;
        answeredInRound = 1;
        answer = _answer;
    }

    function setAnswer(int256 __answer) public {
        _answer = __answer;
    }
}
