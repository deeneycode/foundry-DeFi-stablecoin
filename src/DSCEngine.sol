// SPDX-License-Identifier;

pragma solidity ^0.8.19;

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
 * @notice This contract is the core of the DSC System. It handles all the logic for mining
 * and redeeming DSC, as well as depositing @ withdrawing collateral 
 * @notice This contract is VERY loosely based on the MAKERDAO DSS (DAI) system.
 */

contract DSCEngine {}