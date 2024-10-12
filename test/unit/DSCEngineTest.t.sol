// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {AggregatorV3Interface} from
    "lib/chainlink-brownie-contracts/contracts/src/v0.4/interfaces/AggregatorV3Interface.sol";
import {ERC20Mock} from "lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.t.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;
    HelperConfig helperConfig;

    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;
    uint256 deployerKey;

    address public USER = makeAddr("USER");
    uint256 public AMOUNT_COLLATERAL = 10 ether;
    uint256 public AMOUNT_MINT = 100 ether;
    uint256 public STARTING_ERC20_BALANCE = 10 ether;
    
    function setUp() public {
        deployer = new DeployDSC();
        (dscEngine, dsc, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = helperConfig.activeNetworkConfig();

        vm.deal(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);

    }
    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_MINT);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

     /////////////////////
    // Constructor Test //
    /////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertIfTokenLengthDoesntMatchPriceFeedLength() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    function testConstructorInitializesCorrectly() public view {
        assertEq(dscEngine.getPriceFeed(weth), ethUsdPriceFeed);
        assertEq(dscEngine.getPriceFeed(wbtc), btcUsdPriceFeed);

        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
        assertEq(collateralTokens[1], wbtc);
        assertEq(collateralTokens.length, 2);
    }

    ////////////////
    // Price Test //
    ////////////////

    function testGetUsdValueOfCollateral() public view {
        uint256 ethAmount = 15e18; // 15 ETH
        uint256 ethPrice = 2000e8; // 2000 USD
        // Expected eth value in USD
        // 15 ETH * 2000 USD/ ETH price = 30000 USD
        uint256 expectedUsd = (ethAmount * ethPrice) / 1e8; //30000 USD
        uint256 actualUsd = dscEngine.getUsdValueOfCollateral(weth, ethAmount);
        assertEq(actualUsd, expectedUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 15 ether; // 15 ETH
        //  $15 ETH / $2000 usd
        uint256 expectedWethAmount = 0.0075 ether;
        uint256 actualWethAmount = dscEngine.getTokenAmountFromUsd(weth,usdAmount);
        assertEq(actualWethAmount, expectedWethAmount);
    }

    //////////////////////////////
    // Deposit collateral test //
    /////////////////////////////

    function testRevertIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__AmountMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertwithUnApprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__NotAllowedToken.selector, address(ranToken)));
        dscEngine.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) =
        dscEngine.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dscEngine.getTokenAmountFromUsd(weth, totalCollateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assert(AMOUNT_COLLATERAL == expectedDepositAmount); 
    }

    //////////////////////////////
    /////// Mint DSC test ////////
    /////////////////////////////

    function testMintDscSuccessfully() public depositedCollateral {
        vm.prank(USER);
        dscEngine.mintDsc(AMOUNT_MINT);
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, AMOUNT_MINT);
    }

    function testMintRevertIfItIsZero() public depositedCollateral {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__AmountMoreThanZero.selector);
        dscEngine.mintDsc(0);  
    }

    
     //////////////////////////////////
    /////// Health Factor test ////////
    //////////////////////////////////
    function testHealthFactorWhenNoDscMinted() public {
        vm.mockCall(
            address(dscEngine), 
            abi.encodeWithSignature("getAccountInformation(address)", USER),
            abi.encode(0, 1000 * dscEngine.getPrecision())
        );
        uint256 healthFactor = dscEngine.getHealthFactor(USER);
        assertEq(healthFactor, type(uint256).max, "Health factor should be max when no dsc minted");
    }

    function testProperlyReportHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = dscEngine.getHealthFactor(USER);
        assertEq(expectedHealthFactor, healthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsc {
        int256 ethUsdUpdatedPrice = 18e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = dscEngine.getHealthFactor(USER);
        assertEq(userHealthFactor, 0.9 ether);
    }

     //////////////////////
    //// Burn DSC test ///
    //////////////////////

    function testRevertIfBurnAmountisZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine),AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__AmountMoreThanZero.selector);
        dscEngine.burnDsc(0);
        vm.stopPrank();
    }

    function testCanBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        dscEngine.burnDsc(AMOUNT_COLLATERAL);
    }

}

