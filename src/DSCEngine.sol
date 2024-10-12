// SPDX-License-Identifier;

pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
// import {OracleLib, AggregatorV3Interface } from "src/Oracle.sol";
import {AggregatorV3Interface} from
    "lib/chainlink-brownie-contracts/contracts/src/v0.4/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSC Engine
 * @author Deeney
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a
 * 1 token == $1 peg
 * This stablecoin has the properties;
 *  - Exogenous Collateral
 *  - Dollar pegged
 *  - Algorithmically stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral <= the $ backed value of all the DSC.
 * @notice This contract is the core of the DSC System. It handles all the logic for mining
 * and redeeming DSC, as well as depositing @ withdrawing collateral
 * @notice This contract is VERY loosely based on the MAKERDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    /**
     * Error
     */
    error DSCEngine__AmountMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken(address token);
    error DSCEngine__TransferFromFailed();
    error DSCEngine__UserHealthFactorTooLow(uint256 userHealthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BurnDscFailed();
    error DSCEngine__UserHealthFactorIsOkay();
    error DSCEngine__HealthFactorNotImproved();

    /**
     * State Variables
     */
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDAION_THRESHOLD = 50; // 200% overcollaterized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DscMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    /**
     * Event
     */
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    /**
     * Modifier
     */
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__AmountMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken(token);
        }
        _;
    }

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        // For example ETH/USD, BTC/USD etc
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /**
     * External functions
     */
    /**
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of token to deposit
     * @param amountToMint The amount of DSC to mint
     * @notice This function is used to deposit collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountToMint)
        external
    {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountToMint);
    }

    /**
     * @param tokenCollateralAddress The collateral address to redeem
     * @param amountOfCollateral The amount collateral to redeem
     * @param amountDscToBurn The amount of DSC to burn
     * @notice This function is used to burn DSC and redeem collateral in one transaction
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountOfCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountOfCollateral);
        // Redeem collateral already checks health factor.
    }

    /**
     * Public functions
     */
    /**
     *
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of token to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool transfered = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!transfered) {
            revert DSCEngine__TransferFromFailed();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // In order to redeem collateral
    // 1. Health factor muct be over 1 AFTER COLLATERAL PULLED
    function redeemCollateral(address tokenCollateralAddress, uint256 amountOfCollateral)
        public
        moreThanZero(amountOfCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountOfCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     *
     * @param amountDscToMint Amount of decentralized stable coin to mint
     * @notice they must have enough collateral value to mint the DSC
     * @notice this function is view, so it does not mint, it only returns the amount of DSC to mint
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        i_dsc.burn(amount);
    }

    // If we do start nearing liquidation, we need somone to liquidate positions
    // If someone is almost undercollateralized, we will pay you to liquidate them!
    // Liquidator will be a contract that will take the users collateral(ETH) and burns off the DSC.
    /**
     * @param collateralToken The address of the ERC20 to liquidate from the user
     * @param user The address of the user who has broken the health factor. _Health factor should be below the MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve the health factor
     * @notice You can partially liquidate a user
     * @notice You can only liquidate users that are undercollateralized
     * @notice You will get the collateral back, and the DSC will be burned
     */
    function liquidate(address collateralToken, address user, uint256 debtToCover)
        external
        nonReentrant
        moreThanZero(debtToCover)
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__UserHealthFactorIsOkay();
        }
        // we want to burn their DSC debt, and want their collateral back
        // Bad User: $140 ETH collateral, debt $100 DSC debt
        // $100 DSC debt =
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateralToken, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateralToken, totalCollateralToRedeem);
        _burnDsc(debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }
    /**
     * Private & Internal view functions
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DscMinted[onBehalfOf] -= amountDscToBurn;
        bool burned = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!burned) {
            revert DSCEngine__BurnDscFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountOfCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountOfCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountOfCollateral);
        bool redeemed = IERC20(tokenCollateralAddress).transfer(to, amountOfCollateral);
        if (!redeemed) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
    {
        totalDscMinted = s_DscMinted[user];
        totalCollateralValueInUsd = getAccountCollateralValue(user);
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, totalCollateralValueInUsd);
    }

    /**
     * Returns how close  to liquidation the user is
     * If the user goes below 1, then they can be liquidated
     */
    function _calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    ) internal pure returns(uint256) {
        // total DSCminted
        // total collateral value
        if(totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDAION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    // 1. Check if user has enough collateral. if not, revert.
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__UserHealthFactorTooLow(userHealthFactor);
        }
    }

    /**
     * Public & External view functions
     */
    
    function getTokenAmountFromUsd(address token, uint256 usdAmount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((usdAmount * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through all the collateral token, get the amount they have deposited, and map it to
        // the price, to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amountDeposited = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValueOfCollateral(token, amountDeposited);
        }
    }

    function getUsdValueOfCollateral(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        uint256 adjustedPrice = (uint256(price) * ADDITIONAL_FEED_PRECISION);
        uint256 usdValue = (adjustedPrice * amount) / PRECISION;
        return usdValue;
    }

    function calculateHealthFactor(
        uint256 totalDscMinted, uint256 collateralValueInUsd) 
        external pure returns(uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getAccountInformation(address user) external view 
    returns(uint256 totalDscMinted, uint256 totalCollateralValueInUsd) 
    {
       (totalDscMinted, totalCollateralValueInUsd) = _getAccountInformation(user);
    }

    function getPriceFeed(address token) external view returns (address){
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256){
        return _healthFactor(user);
    }

    function getCollateralTokens() external view returns (address[] memory){
        return s_collateralTokens;
    }

    function getAdditionalFeedPrecision () external pure returns(uint256){
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecision() external pure returns(uint256){
    return PRECISION;
   }

   function getCollateralBalanceOfUser(address user, address token) external view returns(uint256){
    return s_collateralDeposited[user][token];
   }

   function getCollateralTokenPriceFeed(address token)
   external view returns(address)
   {
    return s_priceFeeds[token];
   }

   function getLiquidationThreshold() external pure returns(uint256){
    return LIQUIDAION_THRESHOLD;
   }

   function getLiquidationPrecision() external pure returns(uint256){
    return LIQUIDATION_PRECISION;
   }

   function getMinimumHealthFactor() external pure returns(uint256){
    return MIN_HEALTH_FACTOR;
   }

}







