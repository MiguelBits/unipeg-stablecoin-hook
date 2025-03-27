// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Engine} from "../src/Engine.sol";
import {StableToken} from "../src/StableToken.sol";
import {ERC20Mock} from "./utils/mocks/ERC20Mock.sol";
import {MockPoolManager} from "./mocks/MockPoolManager.sol";

// Import Uniswap V4 types
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract EngineTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Engine engine;
    StableToken stableToken;
    ERC20Mock weth;
    ERC20Mock wbtc;
    ERC20Mock usdc;
    MockPoolManager mockPoolManager;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_USER_BALANCE = 100 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant UNIPEG_AMOUNT_TO_MINT = 100 ether;
    
    // Uniswap V4 price values
    uint160 public constant ETH_USDC_SQRT_PRICE = 1771845812000000000000000; // ~$2000 ETH/USDC
    uint160 public constant BTC_USDC_SQRT_PRICE = 6864909800000000000000000; // ~$30000 BTC/USDC
    
    // Pool IDs
    PoolId wethPoolId;
    PoolId wbtcPoolId;
    
    // Events to test
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event UnipegMinted(address indexed user, uint256 amount);
    event CollateralRedeemed(address indexed from, address indexed to, address indexed token, uint256 amount);
    event UnipegBurned(address indexed user, uint256 principalAmount, uint256 interestAmount);
    event CollateralLiquidated(address indexed user, address indexed liquidator, address indexed token, uint256 amount, uint256 unipegAmount);

    function setUp() public {
        // Deploy mock tokens
        weth = new ERC20Mock("Wrapped Ether", "WETH", USER, STARTING_USER_BALANCE);
        wbtc = new ERC20Mock("Wrapped Bitcoin", "WBTC", USER, STARTING_USER_BALANCE);
        usdc = new ERC20Mock("USD Coin", "USDC", USER, STARTING_USER_BALANCE);
        
        // Deploy mock pool manager
        mockPoolManager = new MockPoolManager();
        
        // Create pool keys
        PoolKey memory wethPoolKey = PoolKey({
            currency0: Currency.wrap(address(weth)),
            currency1: Currency.wrap(address(usdc)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        
        PoolKey memory wbtcPoolKey = PoolKey({
            currency0: Currency.wrap(address(wbtc)),
            currency1: Currency.wrap(address(usdc)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        
        wethPoolId = wethPoolKey.toId();
        wbtcPoolId = wbtcPoolKey.toId();
        
        // Set up mock pool data
        mockPoolManager.setPoolPrice(wethPoolId, ETH_USDC_SQRT_PRICE);
        mockPoolManager.setPoolPrice(wbtcPoolId, BTC_USDC_SQRT_PRICE);
        
        // Deploy StableToken first
        vm.startPrank(address(this));
        stableToken = new StableToken(address(this)); // Engine address will be set later
        
        // Create arrays for Engine constructor
        address[] memory tokenAddresses = new address[](2);
        tokenAddresses[0] = address(weth);
        tokenAddresses[1] = address(wbtc);
        
        PoolKey[] memory poolKeys = new PoolKey[](2);
        poolKeys[0] = wethPoolKey;
        poolKeys[1] = wbtcPoolKey;
        
        bool[] memory isToken0Array = new bool[](2);
        isToken0Array[0] = true;  // weth is token0 in weth-usdc pool
        isToken0Array[1] = true;  // wbtc is token0 in wbtc-usdc pool
        
        // Deploy Engine
        engine = new Engine(
            tokenAddresses, 
            poolKeys, 
            isToken0Array,
            address(stableToken),
            address(mockPoolManager)
        );
        
        vm.stopPrank();
        
        // Give USER some tokens to work with
        vm.startPrank(USER);
        weth.approve(address(engine), STARTING_USER_BALANCE);
        wbtc.approve(address(engine), STARTING_USER_BALANCE);
        vm.stopPrank();
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////
    
    function test_Constructor_SetsValuesCorrectly() public {
        // Check if tokens are properly set
        address[] memory collateralTokens = engine.getCollateralTokens();
        assertEq(collateralTokens.length, 2);
        assertEq(collateralTokens[0], address(weth));
        assertEq(collateralTokens[1], address(wbtc));
        
        // Check if pool IDs are properly set
        (bytes32 wethPool, , bool isWethToken0) = engine.getCollateralInfo(address(weth));
        (bytes32 wbtcPool, , bool isWbtcToken0) = engine.getCollateralInfo(address(wbtc));
        
        assertEq(wethPool, wethPoolId);
        assertEq(wbtcPool, wbtcPoolId);
        assertTrue(isWethToken0);
        assertTrue(isWbtcToken0);
    }

    /////////////////////////
    // depositCollateral() //
    /////////////////////////
    
    function test_DepositCollateral_RevertIfZero() public {
        vm.startPrank(USER);
        vm.expectRevert();
        engine.depositCollateral(address(weth), 0);
        vm.stopPrank();
    }
    
    function test_DepositCollateral_RevertIfNotAllowedToken() public {
        ERC20Mock randomToken = new ERC20Mock("Random", "RND", USER, STARTING_USER_BALANCE);
        
        vm.startPrank(USER);
        vm.expectRevert();
        engine.depositCollateral(address(randomToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }
    
    function test_DepositCollateral_UpdatesCollateralBalances() public {
        vm.startPrank(USER);
        vm.expectEmit(true, true, false, true);
        emit CollateralDeposited(USER, address(weth), AMOUNT_COLLATERAL);
        engine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
        vm.stopPrank();
        
        uint256 userCollateral = engine.getUserCollateral(USER, address(weth));
        assertEq(userCollateral, AMOUNT_COLLATERAL);
    }

    ////////////////
    // mintUnipeg() //
    ////////////////
    
    function test_MintUnipeg_RevertIfZero() public {
        vm.startPrank(USER);
        vm.expectRevert();
        engine.mintUnipeg(0);
        vm.stopPrank();
    }
    
    function test_MintUnipeg_RevertIfHealthFactorBroken() public {
        // Try to mint without any collateral
        vm.startPrank(USER);
        vm.expectRevert();
        engine.mintUnipeg(1 ether);
        vm.stopPrank();
    }
    
    function test_MintUnipeg_IncreaseUserDebt() public {
        // First deposit collateral
        vm.startPrank(USER);
        engine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
        
        // Now mint UNIPEG
        vm.expectEmit(true, false, false, true);
        emit UnipegMinted(USER, UNIPEG_AMOUNT_TO_MINT);
        engine.mintUnipeg(UNIPEG_AMOUNT_TO_MINT);
        vm.stopPrank();
        
        // Get user debt info using the corrected function
        (uint256 principal, ) = engine.getUserDebtInfo(USER);
        assertEq(principal, UNIPEG_AMOUNT_TO_MINT);
        assertEq(stableToken.balanceOf(USER), UNIPEG_AMOUNT_TO_MINT);
    }
    
    ///////////////////////////////////
    // depositCollateralAndMintUnipeg() //
    ///////////////////////////////////
    
    function test_DepositCollateralAndMintUnipeg_UpdatesBalancesCorrectly() public {
        vm.startPrank(USER);
        engine.depositCollateralAndMintUnipeg(address(weth), AMOUNT_COLLATERAL, UNIPEG_AMOUNT_TO_MINT);
        vm.stopPrank();
        
        uint256 userCollateral = engine.getUserCollateral(USER, address(weth));
        (uint256 principal, ) = engine.getUserDebtInfo(USER);
        
        assertEq(userCollateral, AMOUNT_COLLATERAL);
        assertEq(principal, UNIPEG_AMOUNT_TO_MINT);
        assertEq(stableToken.balanceOf(USER), UNIPEG_AMOUNT_TO_MINT);
    }

    //////////////////////
    // redeemCollateral() //
    //////////////////////
    
    function test_RedeemCollateral_RevertIfZero() public {
        vm.startPrank(USER);
        vm.expectRevert();
        engine.redeemCollateral(address(weth), 0);
        vm.stopPrank();
    }
    
    function test_RedeemCollateral_RevertIfHealthFactorBroken() public {
        // Setup: Deposit collateral and mint maximum UNIPEG
        vm.startPrank(USER);
        engine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
        engine.mintUnipeg(UNIPEG_AMOUNT_TO_MINT);
        
        // Try to redeem all collateral (should fail due to health factor)
        vm.expectRevert();
        engine.redeemCollateral(address(weth), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }
    
    function test_RedeemCollateral_UpdatesBalancesCorrectly() public {
        // Setup: Deposit collateral
        vm.startPrank(USER);
        engine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
        
        // Redeem part of the collateral
        uint256 redeemAmount = 1 ether;
        vm.expectEmit(true, true, true, true);
        emit CollateralRedeemed(USER, USER, address(weth), redeemAmount);
        engine.redeemCollateral(address(weth), redeemAmount);
        vm.stopPrank();
        
        uint256 userCollateral = engine.getUserCollateral(USER, address(weth));
        assertEq(userCollateral, AMOUNT_COLLATERAL - redeemAmount);
        assertEq(weth.balanceOf(USER), STARTING_USER_BALANCE - AMOUNT_COLLATERAL + redeemAmount);
    }

    ////////////////
    // burnUnipeg() //
    ////////////////
    
    function test_BurnUnipeg_RevertIfZero() public {
        vm.startPrank(USER);
        vm.expectRevert();
        engine.burnUnipeg(0);
        vm.stopPrank();
    }
    
    function test_BurnUnipeg_UpdatesBalancesCorrectly() public {
        // Setup: Deposit collateral and mint UNIPEG
        vm.startPrank(USER);
        engine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
        engine.mintUnipeg(UNIPEG_AMOUNT_TO_MINT);
        
        // Approve engine to burn UNIPEG
        stableToken.approve(address(engine), UNIPEG_AMOUNT_TO_MINT);
        
        // Burn part of the UNIPEG
        uint256 burnAmount = 10 ether;
        vm.expectEmit(true, false, false, true);
        emit UnipegBurned(USER, burnAmount, 0); // Assuming no interest has accrued
        engine.burnUnipeg(burnAmount);
        vm.stopPrank();
        
        (uint256 principal, ) = engine.getUserDebtInfo(USER);
        assertEq(principal, UNIPEG_AMOUNT_TO_MINT - burnAmount);
        assertEq(stableToken.balanceOf(USER), UNIPEG_AMOUNT_TO_MINT - burnAmount);
    }

    //////////////////////////////
    // redeemCollateralForUnipeg() //
    //////////////////////////////
    
    function test_RedeemCollateralForUnipeg_UpdatesBalancesCorrectly() public {
        // Setup: Deposit collateral and mint UNIPEG
        vm.startPrank(USER);
        engine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
        engine.mintUnipeg(UNIPEG_AMOUNT_TO_MINT);
        
        // Approve engine to burn UNIPEG
        stableToken.approve(address(engine), UNIPEG_AMOUNT_TO_MINT);
        
        // Redeem collateral for UNIPEG
        uint256 redeemAmount = 1 ether;
        uint256 burnAmount = 10 ether;
        engine.redeemCollateralForUnipeg(address(weth), redeemAmount, burnAmount);
        vm.stopPrank();
        
        uint256 userCollateral = engine.getUserCollateral(USER, address(weth));
        (uint256 principal, ) = engine.getUserDebtInfo(USER);
        
        assertEq(userCollateral, AMOUNT_COLLATERAL - redeemAmount);
        assertEq(principal, UNIPEG_AMOUNT_TO_MINT - burnAmount);
        assertEq(weth.balanceOf(USER), STARTING_USER_BALANCE - AMOUNT_COLLATERAL + redeemAmount);
        assertEq(stableToken.balanceOf(USER), UNIPEG_AMOUNT_TO_MINT - burnAmount);
    }

    /////////////////
    // liquidate() //
    /////////////////
    
    function test_Liquidate_RevertsIfHealthFactorOk() public {
        // Setup: Deposit collateral and mint UNIPEG
        vm.startPrank(USER);
        engine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
        engine.mintUnipeg(UNIPEG_AMOUNT_TO_MINT / 10); // Mint a small amount
        vm.stopPrank();
        
        // Try to liquidate with good health factor
        vm.startPrank(LIQUIDATOR);
        vm.expectRevert();
        engine.liquidate(USER, address(weth), 1 ether);
        vm.stopPrank();
    }
    
    function test_Liquidate_WorksWithBadHealthFactor() public {
        // Setup: Deposit collateral and mint maximum UNIPEG
        vm.startPrank(USER);
        engine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
        engine.mintUnipeg(UNIPEG_AMOUNT_TO_MINT);
        
        // Make ETH price drop to trigger bad health factor
        mockPoolManager.setPoolPrice(wethPoolId, ETH_USDC_SQRT_PRICE / 2);
        vm.stopPrank();
        
        // Setup liquidator
        deal(address(stableToken), LIQUIDATOR, UNIPEG_AMOUNT_TO_MINT);
        
        vm.startPrank(LIQUIDATOR);
        stableToken.approve(address(engine), UNIPEG_AMOUNT_TO_MINT);
        
        uint256 debtToCover = 10 ether;
        vm.expectEmit(true, true, true, false);
        emit CollateralLiquidated(USER, LIQUIDATOR, address(weth), 1 ether, debtToCover);
        engine.liquidate(USER, address(weth), debtToCover);
        vm.stopPrank();
        
        // Check balances after liquidation
        assertTrue(engine.getHealthFactor(USER) > 1e18); // Health factor should be improved
    }

    ////////////////////////////
    // View Function Tests //
    ////////////////////////////
    
    function test_GetHealthFactor_ReturnsCorrectValue() public {
        // Setup: Deposit collateral and mint UNIPEG
        vm.startPrank(USER);
        engine.depositCollateral(address(weth), AMOUNT_COLLATERAL);
        engine.mintUnipeg(UNIPEG_AMOUNT_TO_MINT);
        vm.stopPrank();
        
        // 10 ETH * $2000 = $20,000 total collateral
        // With 150% requirement, can mint up to $13,333 of UNIPEG
        // If minted $100, health factor should be about 1.33
        uint256 healthFactor = engine.getHealthFactor(USER);
        
        // Expected health factor: $20,000 / 150% / $100 = 1.33 * 1e18
        uint256 expectedHealthFactor = 1.33e18;
        
        // Allow for some rounding error
        assertApproxEqRel(healthFactor, expectedHealthFactor, 0.01e18); // 1% tolerance
    }

    function test_GetTokenPrice_ReturnsCorrectValue() public {
        uint256 ethPrice = engine.getTokenPrice(address(weth));
        uint256 btcPrice = engine.getTokenPrice(address(wbtc));
        
        // Price calculation from sqrtPriceX96 is complex, so we check approximate values
        assertApproxEqRel(ethPrice, 2000e18, 0.05e18); // Within 5% of $2000
        assertApproxEqRel(btcPrice, 30000e18, 0.05e18); // Within 5% of $30000
    }

    ///////////////////////////
    // Interest Rate Tests //
    ///////////////////////////
    
    function test_GetAnnualInterestRate_Returns5Percent() public {
        uint256 interestRate = engine.getAnnualInterestRate();
        assertEq(interestRate, 5e16); // 5% as fixed rate
    }

    ///////////////////
    // Admin Tests //
    ///////////////////
    
    function test_AddCollateralToken_OnlyOwnerCanCall() public {
        ERC20Mock newToken = new ERC20Mock("New Token", "NEW", USER, STARTING_USER_BALANCE);
        
        // Create new pool key
        PoolKey memory newPoolKey = PoolKey({
            currency0: Currency.wrap(address(newToken)),
            currency1: Currency.wrap(address(usdc)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        
        PoolId newPoolId = newPoolKey.toId();
        mockPoolManager.setPoolPrice(newPoolId, 500e18); // $500 token price
        
        vm.startPrank(USER);
        vm.expectRevert();
        engine.addCollateralToken(address(newToken), newPoolKey, true, 15000);
        vm.stopPrank();
        
        vm.startPrank(address(this));
        engine.addCollateralToken(address(newToken), newPoolKey, true, 15000);
        vm.stopPrank();
        
        address[] memory collateralTokens = engine.getCollateralTokens();
        assertEq(collateralTokens.length, 3);
        assertEq(collateralTokens[2], address(newToken));
        
        (bytes32 poolId, uint256 liquidationThreshold, bool isToken0) = engine.getCollateralInfo(address(newToken));
        assertEq(poolId, newPoolId);
        assertEq(liquidationThreshold, 15000);
        assertTrue(isToken0);
    }
    
    function test_UpdateLiquidationThreshold_OnlyOwnerCanCall() public {
        vm.startPrank(USER);
        vm.expectRevert();
        engine.updateLiquidationThreshold(address(weth), 20000);
        vm.stopPrank();
        
        vm.startPrank(address(this));
        engine.updateLiquidationThreshold(address(weth), 20000);
        vm.stopPrank();
        
        (, uint256 liquidationThreshold,) = engine.getCollateralInfo(address(weth));
        assertEq(liquidationThreshold, 20000);
    }
} 