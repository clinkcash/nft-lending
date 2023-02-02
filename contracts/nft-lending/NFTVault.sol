// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-IERC20Permit.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";
import "./interfaces/IPriceHelper.sol";
import "./interfaces/IInitialization.sol";
import "./interfaces/IUniV3Swapper.sol";
import "../clink/IERC20BurnMintable.sol";

/// @title NFT lending vault
/// @notice This contracts allows users to borrow CLK using NFTs as collateral.
contract NFTVault is Ownable, ReentrancyGuard, IInitialization, Multicall {
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Permit;
    using EnumerableSet for EnumerableSet.UintSet;

    event PositionOpened(address indexed owner, uint256 indexed index);
    event Borrowed(address indexed owner, uint256 indexed index, uint256 amount);
    event Repaid(address indexed owner, uint256 indexed index, uint256 amount);
    event PositionClosed(address indexed owner, uint256 indexed index);
    event Liquidated(address indexed liquidator, address indexed owner, uint256 indexed index);
    event LogFeeTo(address indexed newFeeTo);
    event MaxPrincipal(uint256 amount);
    event MaxTotalPrincipal(uint256 amount);

    struct Position {
        uint256 debtPrincipal;
        uint256 debtPortion; //
    }

    struct Rate {
        uint128 numerator;
        uint128 denominator;
    }

    struct VaultSettings {
        Rate debtInterestApr;
        Rate creditLimitRate;
        Rate liquidationLimitRate;
        Rate organizationFeeRate;
        Rate liquidationFeeRate;
    }

    address public immutable clink;
    NFTVault public immutable masterContract;

    // MasterContract variables
    address public feeTo;

    IERC721 public nftContract;
    IPriceHelper public priceHelper;

    /// @notice Total outstanding debt
    uint256 public totalDebtAmount;
    /// @dev Last time debt was accrued. See {accrue} for more info
    uint256 public totalDebtAccruedAt;
    uint256 public totalFeeCollected;
    uint256 public totalDebtPortion;

    uint256 public maxPrincipal;
    uint256 public maxTotalPrincipal;
    uint256 public curTotalPrincipal;

    VaultSettings public settings;

    /// @dev Keeps track of all the NFTs used as collateral for positions
    EnumerableSet.UintSet private positionIndexes;

    mapping(uint256 => Position) private positions;
    mapping(uint256 => address) public positionOwner;

    /// @dev Checks if the provided NFT index is valid
    /// @param nftIndex The index to check
    modifier validNFTIndex(uint256 nftIndex) {
        //The standard OZ ERC721 implementation of ownerOf reverts on a non existing nft isntead of returning address(0)
        require(nftContract.ownerOf(nftIndex) != address(0), "invalid_nft");
        _;
    }

    modifier onlyMasterContractOwner() {
        require(msg.sender == masterContract.owner(), "Caller is not the owner");
        _;
    }

    constructor(address _clink, address _owner) {
        clink = _clink;
        masterContract = this;
        transferOwnership(_owner);
    }

    /// @notice Serves as the constructor for clones, as clones can't have a regular constructor
    /// @dev `data` is abi encoded in the format
    function init(bytes calldata data) public payable override {
        require(address(nftContract) == address(0), "NFTVault: already initialized");

        (VaultSettings memory _settings, IERC721 _nftContract, IPriceHelper _priceHelper) = abi.decode(
            data,
            (VaultSettings, IERC721, IPriceHelper)
        );

        _validateRate(_settings.debtInterestApr);
        _validateRate(_settings.creditLimitRate);
        _validateRate(_settings.liquidationLimitRate);
        _validateRate(_settings.organizationFeeRate);
        _validateRate(_settings.liquidationFeeRate);

        require(_greaterThan(_settings.liquidationLimitRate, _settings.creditLimitRate), "invalid_liquidation_limit");

        nftContract = _nftContract;
        priceHelper = _priceHelper;
        settings = _settings;
        require(address(nftContract) != address(0), "NFTVault: bad pair");
    }

    /// @dev The {accrue} function updates the contract's state by calculating
    /// the additional interest accrued since the last state update
    function accrue() public {
        uint256 additionalInterest = _calculateAdditionalInterest();

        totalDebtAccruedAt = block.timestamp;

        totalDebtAmount += additionalInterest;
        totalFeeCollected += additionalInterest;
    }

    /// @dev Checks if `r1` is greater than `r2`.
    function _greaterThan(Rate memory _r1, Rate memory _r2) internal pure returns (bool) {
        return _r1.numerator * _r2.denominator > _r2.numerator * _r1.denominator;
    }

    /// @dev Validates a rate. The denominator must be greater than zero and greater than or equal to the numerator.
    /// @param rate The rate to validate
    function _validateRate(Rate memory rate) internal pure {
        require(rate.denominator != 0 && rate.denominator >= rate.numerator, "invalid_rate");
    }

    struct NFTInfo {
        uint256 index;
        address owner;
        uint256 nftValueUSD;
    }

    /// @notice Returns data relative to the NFT at index `_tokenId`
    /// @param _tokenId The NFT index
    /// @return nftInfo The data relative to the NFT
    function getNFTInfo(uint256 _tokenId) external view returns (NFTInfo memory nftInfo) {
        nftInfo = NFTInfo(_tokenId, nftContract.ownerOf(_tokenId), _getNFTValueUSD(_tokenId));
    }

    /// @dev Returns the credit limit of an NFT
    /// @param _tokenId The NFT to return credit limit of
    /// @return The NFT credit limit
    function _getCreditLimit(uint256 _tokenId) internal view returns (uint256) {
        uint256 value = _getNFTValueUSD(_tokenId);
        return (value * settings.creditLimitRate.numerator) / settings.creditLimitRate.denominator;
    }

    /// @dev Returns the minimum amount of debt necessary to liquidate an NFT
    /// @param _tokenId The index of the NFT
    /// @return The minimum amount of debt to liquidate the NFT
    function _getLiquidationLimit(uint256 _tokenId) internal view returns (uint256) {
        uint256 value = _getNFTValueUSD(_tokenId);
        return (value * settings.liquidationLimitRate.numerator) / settings.liquidationLimitRate.denominator;
    }

    /// @dev Calculates current outstanding debt of an NFT
    /// @param _tokenId The NFT to calculate the outstanding debt of
    /// @return The outstanding debt value
    function _getDebtAmount(uint256 _tokenId) internal view returns (uint256) {
        uint256 calculatedDebt = _calculateDebt(totalDebtAmount, positions[_tokenId].debtPortion, totalDebtPortion);

        uint256 principal = positions[_tokenId].debtPrincipal;

        //_calculateDebt is prone to rounding errors that may cause
        //the calculated debt amount to be 1 or 2 units less than
        //the debt principal when the accrue() function isn't called
        //in between the first borrow and the _calculateDebt call.
        return principal > calculatedDebt ? principal : calculatedDebt;
    }

    /// @dev Calculates the total debt of a position given the global debt, the user's portion of the debt and the total user portions
    /// @param total The global outstanding debt
    /// @param userPortion The user's portion of debt
    /// @param totalPortion The total user portions of debt
    /// @return The outstanding debt of the position
    function _calculateDebt(
        uint256 total,
        uint256 userPortion,
        uint256 totalPortion
    ) internal pure returns (uint256) {
        return totalPortion == 0 ? 0 : (total * userPortion) / totalPortion;
    }

    /// @dev Opens a position
    /// Emits a {PositionOpened} event
    /// @param _owner The owner of the position to open
    /// @param _tokenId The NFT used as collateral for the position
    function _openPosition(address _owner, uint256 _tokenId) internal {
        positionOwner[_tokenId] = _owner;
        positionIndexes.add(_tokenId);

        nftContract.transferFrom(_owner, address(this), _tokenId);

        emit PositionOpened(_owner, _tokenId);
    }

    /// @dev Calculates the additional global interest since last time the contract's state was updated by calling {accrue}
    /// @return The additional interest value
    function _calculateAdditionalInterest() internal view returns (uint256) {
        // Number of seconds since {accrue} was called
        uint256 elapsedTime = block.timestamp - totalDebtAccruedAt;
        if (elapsedTime == 0) {
            return 0;
        }

        uint256 totalDebt = totalDebtAmount;
        if (totalDebt == 0) {
            return 0;
        }

        // Accrue interest
        return
            (elapsedTime * totalDebt * settings.debtInterestApr.numerator) /
            settings.debtInterestApr.denominator /
            365 days;
    }

    /// @notice Returns the number of open positions
    /// @return The number of open positions
    function totalPositions() external view returns (uint256) {
        return positionIndexes.length();
    }

    /// @notice Returns all open position NFT indexes
    /// @return The open position NFT indexes
    function openPositionsIndexes() external view returns (uint256[] memory) {
        return positionIndexes.values();
    }

    function _getNFTValueUSD(uint256 _tokenId) public view returns (uint256) {
        return priceHelper.getNFTValueUSD(address(nftContract), _tokenId);
    }

    struct PositionPreview {
        address owner;
        uint256 nftIndex;
        uint256 nftValueUSD;
        VaultSettings vaultSettings;
        uint256 creditLimit;
        uint256 debtPrincipal;
        uint256 debtPortion;
        uint256 debtInterest;
        bool liquidatable;
    }

    /// @notice Returns data relative to a postition, existing or not
    /// @param _tokenId The index of the NFT used as collateral for the position
    /// @return preview See assignment below
    function showPosition(uint256 _tokenId)
        external
        view
        validNFTIndex(_tokenId)
        returns (PositionPreview memory preview)
    {
        address posOwner = positionOwner[_tokenId];

        Position storage position = positions[_tokenId];
        uint256 debtPrincipal = position.debtPrincipal;
        //calculate updated debt
        uint256 debtAmount = _calculateDebt(
            totalDebtAmount + _calculateAdditionalInterest(),
            position.debtPortion,
            totalDebtPortion
        );

        //_calculateDebt is prone to rounding errors that may cause
        //the calculated debt amount to be 1 or 2 units less than
        //the debt principal if no time has elapsed in between the first borrow
        //and the _calculateDebt call.
        if (debtPrincipal > debtAmount) debtAmount = debtPrincipal;

        unchecked {
            preview = PositionPreview({
                owner: posOwner, //the owner of the position, `address(0)` if the position doesn't exists
                nftIndex: _tokenId, //the NFT used as collateral for the position
                nftValueUSD: _getNFTValueUSD(_tokenId), //the value in USD of the NFT
                vaultSettings: settings, //the current vault's settings
                creditLimit: _getCreditLimit(_tokenId), //the NFT's credit limit
                debtPrincipal: debtPrincipal, //the debt principal for the position, `0` if the position doesn't exists
                debtPortion: position.debtPortion,
                debtInterest: debtAmount - debtPrincipal, //the interest of the position
                liquidatable: debtAmount >= _getLiquidationLimit(_tokenId) //if the position can be liquidated
            });
        }
    }

    /// @notice Allows users to open positions and borrow using an NFT
    /// @dev emits a {Borrowed} event
    /// @param _tokenId The index of the NFT to be used as collateral
    /// @param _amount The amount of PUSD to be borrowed. Note that the user will receive less than the amount requested,
    /// the borrow fee automatically get removed from the amount borrowed
    function borrow(uint256 _tokenId, uint256 _amount) external validNFTIndex(_tokenId) nonReentrant {
        accrue();

        require(msg.sender == positionOwner[_tokenId] || address(0) == positionOwner[_tokenId], "unauthorized");
        require(_amount != 0, "invalid_amount");

        Position storage position = positions[_tokenId];

        uint256 creditLimit = _getCreditLimit(_tokenId);
        uint256 debtAmount = _getDebtAmount(_tokenId);
        require(debtAmount + _amount <= creditLimit, "insufficient_credit");

        //calculate the borrow fee
        uint256 organizationFee = (_amount * settings.organizationFeeRate.numerator) /
            settings.organizationFeeRate.denominator;

        uint256 feeAmount = organizationFee;
        totalFeeCollected += feeAmount;

        uint256 debtPortion = totalDebtPortion;
        // update debt portion
        if (debtPortion == 0) {
            totalDebtPortion = _amount;
            position.debtPortion = _amount;
        } else {
            //debtPortion =100,totalDebtAmount=200,_amount=100,
            //plusPortion = (100 * 100) / 200 = 50
            // plusPortion :debtPortion = _amount:totalDebtAmount = 1/2
            uint256 plusPortion = (debtPortion * _amount) / totalDebtAmount;
            totalDebtPortion = debtPortion + plusPortion;
            position.debtPortion += plusPortion;
        }

        position.debtPrincipal += _amount;
        if (maxTotalPrincipal > 0) {
            require(curTotalPrincipal + _amount <= maxTotalPrincipal, "total principal limit");
        }
        curTotalPrincipal += _amount;
        if (maxPrincipal > 0) {
            require(position.debtPrincipal <= maxPrincipal, "principal limit");
        }
        totalDebtAmount += _amount;

        if (positionOwner[_tokenId] == address(0)) {
            _openPosition(msg.sender, _tokenId);
        }

        IERC20BurnMintable(clink).mint(msg.sender, _amount - feeAmount);

        emit Borrowed(msg.sender, _tokenId, _amount);
    }

    /// @notice Allows users to repay a portion/all of their debt. Note that since interest increases every second,
    /// a user wanting to repay all of their debt should repay for an amount greater than their current debt to account for the
    /// additional interest while the repay transaction is pending, the contract will only take what's necessary to repay all the debt
    /// @dev Emits a {Repaid} event
    /// @param _tokenId The NFT used as collateral for the position
    /// @param _amount The amount of debt to repay. If greater than the position's outstanding debt, only the amount necessary to repay all the debt will be taken
    function repay(uint256 _tokenId, uint256 _amount) external validNFTIndex(_tokenId) nonReentrant {
        accrue();

        require(msg.sender == positionOwner[_tokenId], "unauthorized");
        require(_amount != 0, "invalid_amount");

        Position storage position = positions[_tokenId];

        uint256 debtAmount = _getDebtAmount(_tokenId);
        require(debtAmount != 0, "position_not_borrowed");

        uint256 debtPrincipal = position.debtPrincipal;
        uint256 debtInterest = debtAmount - debtPrincipal;
        _amount = _amount > debtAmount ? debtAmount : _amount;
        uint256 paidPrincipal;
        unchecked {
            paidPrincipal = _amount > debtInterest ? _amount - debtInterest : 0;
        }

        IERC20(clink).safeTransferFrom(msg.sender, address(this), _amount);

        // burn only paidPrincipal, the interest will be collected
        if (paidPrincipal > 0) {
            IERC20BurnMintable(clink).burn(paidPrincipal);
        }

        uint256 totalPortion = totalDebtPortion;
        uint256 totalDebt = totalDebtAmount;
        uint256 minusPortion = paidPrincipal == debtPrincipal
            ? position.debtPortion
            : (totalPortion * _amount) / totalDebt;

        totalDebtPortion = totalPortion - minusPortion;
        position.debtPortion -= minusPortion;
        position.debtPrincipal -= paidPrincipal;
        totalDebtAmount = totalDebt - _amount;

        curTotalPrincipal = paidPrincipal > curTotalPrincipal ? 0 : (curTotalPrincipal - paidPrincipal);
        emit Repaid(msg.sender, _tokenId, _amount);
    }

    /// @notice Allows a user to close a position and get their collateral back, if the position's outstanding debt is 0
    /// @dev Emits a {PositionClosed} event
    /// @param _tokenId The index of the NFT used as collateral
    function closePosition(uint256 _tokenId) external validNFTIndex(_tokenId) nonReentrant {
        accrue();

        require(msg.sender == positionOwner[_tokenId], "unauthorized");
        require(_getDebtAmount(_tokenId) == 0, "position_not_repaid");

        positionOwner[_tokenId] = address(0);
        delete positions[_tokenId];
        positionIndexes.remove(_tokenId);

        // transfer nft back to owner if nft was deposited
        if (nftContract.ownerOf(_tokenId) == address(this)) {
            nftContract.safeTransferFrom(address(this), msg.sender, _tokenId);
        }

        emit PositionClosed(msg.sender, _tokenId);
    }

    /// @notice Positions can only be liquidated
    /// once their debt amount exceeds the minimum liquidation debt to collateral value rate.
    /// In order to liquidate a position, the liquidator needs to repay the user's outstanding debt.
    /// If the position is not insured, it's closed immediately and the collateral is sent to `_recipient`.
    /// If the position is insured, the position remains open (interest doesn't increase) and the owner of the position has a certain amount of time
    /// (`insuranceRepurchaseTimeLimit`) to fully repay the liquidator and pay an additional liquidation fee (`insuranceLiquidationPenaltyRate`), if this
    /// is done in time the user gets back their collateral and their position is automatically closed. If the user doesn't repurchase their collateral
    /// before the time limit passes, the liquidator can claim the liquidated NFT and the position is closed
    /// @dev Emits a {Liquidated} event
    /// @param _tokenId The NFT to liquidate
    /// @param swapper The address to send the NFT to swap for CLK
    function liquidate(
        uint256 _tokenId,
        IUniV3Swapper swapper,
        address receiver
    ) external validNFTIndex(_tokenId) nonReentrant {
        accrue();

        address posOwner = positionOwner[_tokenId];
        require(posOwner != address(0), "position_not_exist");

        Position storage position = positions[_tokenId];

        uint256 debtAmount = _getDebtAmount(_tokenId);
        uint256 maxToLiquidator = (debtAmount * settings.liquidationFeeRate.numerator) /
            settings.liquidationFeeRate.denominator;

        uint256 nftValue = _getNFTValueUSD(_tokenId);
        uint256 liquidationLimit = (nftValue * settings.liquidationLimitRate.numerator) /
            settings.liquidationLimitRate.denominator;
        require(debtAmount >= liquidationLimit, "position_not_liquidatable");
        uint256 leftToOwner;
        if (nftValue > maxToLiquidator + debtAmount) {
            leftToOwner = nftValue - debtAmount - maxToLiquidator;
        }

        // transfer nft to swapper
        uint256 before = IERC20(clink).balanceOf(address(this));
        nftContract.transferFrom(address(this), address(swapper), _tokenId);
        swapper.swap(address(nftContract), _tokenId, debtAmount + leftToOwner, posOwner);
        uint256 _after = IERC20(clink).balanceOf(address(this));
        require(_after >= before + debtAmount + leftToOwner, "no enough");
        // burn all debtPrincipal
        // the interest fee (debtAmount - debtPrincipal) will be collected
        if (position.debtPrincipal > 0) {
            IERC20BurnMintable(clink).burn(position.debtPrincipal);
            curTotalPrincipal = position.debtPrincipal > curTotalPrincipal
                ? 0
                : (curTotalPrincipal - position.debtPrincipal);
        }
        if (_after > before + debtAmount + leftToOwner) {
            IERC20(clink).transfer(receiver, _after - before - debtAmount - leftToOwner);
        }
        if (leftToOwner > 0) {
            IERC20(clink).transfer(posOwner, leftToOwner);
        }

        // update debt portion
        totalDebtPortion -= position.debtPortion;
        totalDebtAmount -= debtAmount;
        position.debtPortion = 0;

        positionOwner[_tokenId] = address(0);
        delete positions[_tokenId];
        positionIndexes.remove(_tokenId);
        emit Liquidated(msg.sender, posOwner, _tokenId);
    }

    function getDebtAmount(uint256 _tokenId) public view returns (uint256) {
        return _getDebtAmount(_tokenId);
    }

    function liquidatable(uint256 _tokenId) public view returns (bool) {
        return _getDebtAmount(_tokenId) >= _getLiquidationLimit(_tokenId);
    }

    function collect() external nonReentrant {
        address _feeTo = masterContract.feeTo();
        require(_feeTo != address(0), "addr err");
        accrue();
        IERC20(clink).transfer(_feeTo, IERC20(clink).balanceOf(address(this)));
        totalFeeCollected = 0;
    }

    /// @notice Sets the beneficiary of interest accrued.
    /// MasterContract Only Admin function.
    /// @param newFeeTo The address of the receiver.
    function setFeeTo(address newFeeTo) public onlyOwner {
        feeTo = newFeeTo;
        emit LogFeeTo(newFeeTo);
    }

    function changeMaxPrincipal(uint256 _maxPrincipal) public onlyMasterContractOwner {
        maxPrincipal = _maxPrincipal;
        emit MaxPrincipal(maxPrincipal);
    }

    function changeMaxTotalPrincipal(uint256 _maxTotalPrincipal) public onlyMasterContractOwner {
        maxTotalPrincipal = _maxTotalPrincipal;
        emit MaxTotalPrincipal(maxTotalPrincipal);
    }

    function approveClick(
        address owner_,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        IERC20Permit(clink).safePermit(owner_, spender, value, deadline, v, r, s);
    }

    function tokenIds(uint256 start, uint256 limit) public view returns (uint256[] memory ids) {
        uint256 length = positionIndexes.length();
        if (start >= length) {
            return ids;
        }
        if (length < start + limit) {
            limit = length - start;
        }
        ids = new uint256[](limit);
        for (uint256 i = 0; i < limit; i++) {
            ids[i] = positionIndexes.at(i + start);
        }
    }
}
