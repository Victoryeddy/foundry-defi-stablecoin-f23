// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions
//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

/**
 * @title DSCEngine
 * @author Victory Ndu
 * @notice This is designed to have a token to be pegged to $1
 * It is similar to DAI if DAI was not governed, no fees and was backed by wEth and wBTC
 * It is the core of the DSC system .It handles all the logic for mining and redeeming DSC, as well as depositing and withdrawing collateral
 * Our DSC system should be overcollaterized meaning we should have more collateral than DSC
 */

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "../src/libraries/OracleLib.sol";

contract DSCEngine is ReentrancyGuard {
    // Errors
    error DSCEngine__AmountMustBeMoreThanZero();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__MintFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    // Type
    using OracleLib for AggregatorV3Interface;

    // State Variables
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    uint256 private constant LIQUIDATION_BONUS = 10;

    address[] private s_collateralTokens;
    DecentralizedStableCoin private immutable i_dscAddress;

    // Event
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );
    // Modifiers

    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) revert DSCEngine__AmountMustBeMoreThanZero();
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) revert DSCEngine__NotAllowedToken();
        _;
    }

    // Functions
    /**
     * Since we are dealing with two blockchains wETH and wBTC
     * the parameters in this constructor enables us to enter both blockchains consecutively when we run this contract
     */
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        //   For example ETH > USD, BTC > USD , MKR > USD
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i]; //We are tracking the token address in ETH or other currency to their price feed addresses
            s_collateralTokens.push(tokenAddresses[i]); // We use to get the total amount of collateral deposited by a user
        }
        i_dscAddress = DecentralizedStableCoin(dscAddress);
    }

    // External Functions
    /**
     *
     * @param tokenCollateralAddress The address of the token to deposit
     * @param amount The amount of collateral to deposit
     * @param amountDscToMint The amount of decentralized stablecoin(dsc) to mint
     * @notice This function will deposit collateral and mint DSC in one transaction.
     */
    function depositCollateralAndMintDsc(address tokenCollateralAddress, uint256 amount, uint256 amountDscToMint)
        external
    {
        depositCollateral(tokenCollateralAddress, amount);
        mintDsc(amountDscToMint);
    }

    /**
     *
     * @param tokenCollateralAddress: The address of token to deposit as collateral
     * @param amountCollateral: The amount of collateral  to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) revert DSCEngine__TransferFailed();
    }

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountOfDscToBurn)
        external
    {
        burnDsc(amountOfDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    // In order to redeem collateral we need to check the user health factor if its above 1 they can redeem their collateral

    // Sometimes we do break the CEI pattern
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     *
     * @param amountDscToMint : If a user has $200 it means he/she can choose an amount to mint e.g 20 DSC
     * @notice the collateral must be more than amount to mint
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dscAddress.mint(msg.sender, amountDscToMint); //Assigning the msg.sender the amountDSCToMint
        if (!minted) revert DSCEngine__MintFailed();
    }

    /**
     * @notice We take the amount they want to burn and deduct it from their total DSC minted instead
     * of transferring to a zero address we send it to our contract
     */
    function burnDsc(uint256 _amount) public moreThanZero(_amount) {
        _burnDSC(_amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //The liquidate function works like this:
    //Lets say we deposit $100 worth of ETH we should be in a better position to withdraw $50 worth of DSC
    // But any value greater than our withdrawal amount will cause the liquidate function to trigger and the protocol will liquidate us

    /**
     * @param collateral: The address of token to liquidate from the user
     * @param user: The user who has broken the _healthFactor. Their _healthFactor should be below the minimum health factor
     * @param debtToCover: The amount of DSC to burn to improve users health and cover user's debt
     * @notice You will get a liquidation bonus for taking users func and you can partially liquidate a user
     * @notice This function working assumes the protocol will be roughly 200% overcollaterized in order for this to work
     * @notice The reentrant is used since we are passing token around
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // Checking health factor of user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        // We want to burn their DSC "debt" and take their collateral
        // A picture of a bad user: $140 ETh , $100 DSC
        //This user has a $100 debt to cover
        //We find out how much in $ is the token ($100 == ??? ETH) --- about 0.5 ether
        // As a reward for paying of $100 of DSC , the liquidator is rewarded $110 for $100 of DSC
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

        //Then implement a feature to liquidate in the event the protocol is insolvent

        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);

        _burnDSC(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);

        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        /// If the use that tries to liquidate gets affected too it will revert the liquidate function
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //  With this function we can see an overview of people collateral ratio level
    // Imagine depositing $100 worth of ETH into the system and the threshold is set to 150%
    // You need to have at least 75 dollar worth of ETH remaining in your vault
    function getHealthFactor() external view {}

    // Private and Internal View Functions

    /**
     *
     * @param amountDSCToBurn Amount of debt to burn
     * @param onBehalfOf  The user that is undercollaterized and cant pay back
     * @param dscFrom  The liiquidator who helps contribute his quota to the protocol
     */
    function _burnDSC(uint256 amountDSCToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDSCToBurn;
        bool success = i_dscAddress.transferFrom(dscFrom, address(this), amountDSCToBurn);
        if (!success) revert DSCEngine__TransferFailed();
        i_dscAddress.burn(amountDSCToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDSCMinted, uint256 collateralValueInUsd)
    {
        totalDSCMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     *
     * @notice The function below returns how close to liquidation a user is
     * If a user goes below 1 then they can get liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDSCMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDSCMinted, collateralValueInUsd);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) revert DSCEngine__BreaksHealthFactor(userHealthFactor);
    }

    // Public & External View Pure Functions

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        //price of ETH (Token)
        // So if we have a price of $2000 per ETH and we put $1000 --- $1000 / $2000 which is 0.5 eth
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    /**
     * This function below returns the token value in USD so we can us it in the _healthFactor function , _getAccountInformation function
     */
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        //Over here we loop through collateral token , get the amount they deposited and map it to the price of USD

        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token]; //This will return the amount a user has assigned to a token
            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // 1 ETH = 1000 USD
        // The returned value from Chainlink will be 1000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        // We want to have everything in terms of WEI, so we add 10 zeros at the end
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInformation(user);
    }

    function getUsdValue(
        address token,
        uint256 amount // in WEI
    ) external view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dscAddress);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }
}
