// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "../interfaces/IPriceHelper.sol";
import "../interfaces/IPositionValue.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "../interfaces/IUNIV3NFT.sol";
import "../interfaces/IAggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title NFT USD Price helper
contract UniLPPriceHelperMock is Ownable, IPriceHelper {
    event WhiteList(address token);

    mapping(address => IAggregatorV3Interface) public tokenAggregator;
    mapping(address => bool) public whiteList;

    IUNIV3NFT public nft;
    IPositionValue public positionValue;

    uint256 public rate = 100;

    /// @dev Checks if the provided NFT index is valid
    /// @param nftIndex The index to check
    modifier validNFTIndex(address nftContract, uint256 nftIndex) {
        require(nftContract == address(nft));
        //The standard OZ ERC721 implementation of ownerOf reverts on a non existing nft isntead of returning address(0)
        require(IUNIV3NFT(nftContract).ownerOf(nftIndex) != address(0), "invalid_nft");
        _;
    }

    constructor(IUNIV3NFT _nft, IPositionValue _positionValue) {
        nft = _nft;
        positionValue = _positionValue;
    }

    /// @dev Returns the value in USD of the NFT at index `_tokenId`
    /// @param _tokenId The NFT to return the value of
    /// @return The value of the NFT in USD, 18 decimals
    function getNFTValueUSD(address _nftContract, uint256 _tokenId)
        public
        view
        override
        validNFTIndex(_nftContract, _tokenId)
        returns (uint256)
    {
        (, , address token0, address token1, uint24 fee, , , , , , , ) = nft.positions(_tokenId);

        address poolAddr = positionValue.computeAddress(nft.factory(), token0, token1, fee);

        IUniswapV3Pool pool = IUniswapV3Pool(poolAddr);
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();

        (uint256 amount0, uint256 amount1) = positionValue.total(nft, _tokenId, sqrtRatioX96);
        uint256 totalValue;
        if (whiteList[token0] && address(tokenAggregator[token0]) != address(0)) {
            totalValue += amount0 * tokenPrice(tokenAggregator[token0]);
        }
        if (whiteList[token1] && address(tokenAggregator[token1]) != address(0)) {
            totalValue += amount1 * tokenPrice(tokenAggregator[token1]);
        }
        return (totalValue * rate) / 1e20;
    }

    struct tokenInfoView {
        address addr;
        string symbol;
        uint256 amount;
        uint256 price;
        uint256 usdValue;
    }

    function tokenInfo(address _nftContract, uint256 _tokenId)
        public
        view
        validNFTIndex(_nftContract, _tokenId)
        returns (tokenInfoView[2] memory info, uint256 totalUsdValue)
    {
        (, , address token0, address token1, uint24 fee, , , , , , , ) = nft.positions(_tokenId);

        address poolAddr = positionValue.computeAddress(nft.factory(), token0, token1, fee);

        IUniswapV3Pool pool = IUniswapV3Pool(poolAddr);
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();

        (uint256 amount0, uint256 amount1) = positionValue.total(nft, _tokenId, sqrtRatioX96);
        info[0] = tokenInfoView({
            addr: token0,
            symbol: IERC20Metadata(token0).symbol(),
            amount: amount0,
            price: 0,
            usdValue: 0
        });
        info[1] = tokenInfoView({
            addr: token1,
            symbol: IERC20Metadata(token1).symbol(),
            amount: amount1,
            price: 0,
            usdValue: 0
        });

        if (whiteList[token0] && address(tokenAggregator[token0]) != address(0)) {
            info[0].price = tokenPrice(tokenAggregator[token0]);
            info[0].usdValue = (amount0 * info[0].price) / 1e18;
        }
        if (whiteList[token1] && address(tokenAggregator[token1]) != address(0)) {
            info[1].price = tokenPrice(tokenAggregator[token1]);
            info[1].usdValue = (amount1 * info[1].price) / 1e18;
        }
        totalUsdValue = info[0].usdValue + info[1].usdValue;
        totalUsdValue = (totalUsdValue * rate) / 100;
    }

    function isOpen(address _nftContract, uint256 _tokenId)
        public
        view
        override
        validNFTIndex(_nftContract, _tokenId)
        returns (bool)
    {
        return true;
    }

    function addToken(address[] memory tokens, IAggregatorV3Interface[] memory aggregators) public onlyOwner {
        require(tokens.length == aggregators.length, "add token err");
        for (uint256 i = 0; i < tokens.length; i++) {
            require(address(tokenAggregator[tokens[i]]) == address(0), "already set");
            whiteList[tokens[i]] = true;
            emit WhiteList(tokens[i]);
            tokenAggregator[tokens[i]] = aggregators[i];
        }
    }

    function removeToken(address[] memory tokens) public onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            whiteList[tokens[i]] = false;
        }
    }

    /// @dev Returns the current ETH price in USD
    /// @return The current ETH price, 18 decimals
    function tokenPrice(IAggregatorV3Interface aggregator) public view returns (uint256) {
        return _normalizeAggregatorAnswer(aggregator);
    }

    /// @dev Fetches and converts to 18 decimals precision the latest answer of a Chainlink aggregator
    /// @param aggregator The aggregator to fetch the answer from
    /// @return The latest aggregator answer, normalized
    function _normalizeAggregatorAnswer(IAggregatorV3Interface aggregator) internal view returns (uint256) {
        (, int256 answer, , uint256 timestamp, ) = aggregator.latestRoundData();

        require(answer > 0, "invalid_oracle_answer");
        require(timestamp != 0, "round_incomplete");

        uint8 decimals = aggregator.decimals();

        unchecked {
            //converts the answer to have 18 decimals
            return decimals > 18 ? uint256(answer) / 10**(decimals - 18) : uint256(answer) * 10**(18 - decimals);
        }
    }

    function setRate(uint256 _rate) public {
        rate = _rate;
    }
}
