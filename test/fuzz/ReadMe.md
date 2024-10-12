// SPDX-License-Identifier: MIT
// // Have our invariant aka properties

// // What are our invariants?

// // 1. The total supply of dsc should be less than the total supply of collateral
// // 2. Getter view functions should ner revert <-- evergreen invariant
// pragma solidity ^0.8.19;

// import {Test, console} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DeployDSC} from "script/DeployDSC.s.sol";
// import {DSCEngine} from "src/DSCEngine.sol";
// import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
// import {HelperConfig} from "script/HelperConfig.s.sol";
// import {ERC20Mock} from "lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";


// contract OpenInvariantTest is StdInvariant, Test {
//     DSCEngine dsce;
//     DeployDSC deployer;
//     DecentralizedStableCoin dsc;
//     HelperConfig helperConfig;

//     // address ethUsdPriceFeed;
//     // address btcUsdPriceFeed;
//     address weth;
//     address wbtc;
//     // uint256 deployer;

//     function setUp() public {
//         deployer = new DeployDSC();
//         (dsce, dsc, helperConfig) = deployer.run();
//         (,, weth, wbtc,) = helperConfig.activeNetworkConfig();
//         targetContract(address(dsce));
//     }

//     function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
//         // get the value of all the collateral in the protocol
//         // compare it to all the debt(dsc)
//         uint256 totalSupply = dsc.totalSupply();
//         uint256 totalWethDeposited = ERC20Mock(weth).balanceOf(address(dsce));
//         uint256 totalWbtcDeposited = ERC20Mock(wbtc).balanceOf(address(dsce));

//         uint256 wethValue = dsce.getUsdValueOfCollateral(weth, totalWethDeposited);
//         uint256 wbtcValue = dsce.getUsdValueOfCollateral(wbtc, totalWbtcDeposited);

//         console.log("weth value ", wethValue);
//         console.log("wbtc value: ", wbtcValue);
//         console.log("total supply: ", totalSupply);

//         assert(wethValue +wbtcValue >= totalSupply);

//     }

// }