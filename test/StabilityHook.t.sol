// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {SortTokens, MockERC20} from "v4-core/test/utils/SortTokens.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolModifyLiquidityTestNoChecks} from "v4-core/src/test/PoolModifyLiquidityTestNoChecks.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {PoolTakeTest} from "v4-core/src/test/PoolTakeTest.sol";
import {PoolClaimsTest} from "v4-core/src/test/PoolClaimsTest.sol";
import {PoolNestedActionsTest} from "v4-core/src/test/PoolNestedActionsTest.sol";
import {ActionsRouter} from "v4-core/src/test/ActionsRouter.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {StabilityHook, ThreeCRV69} from "../src/StabilityHook.sol";
import {StableToken} from "../src/StableToken.sol";
import {Engine} from "../src/Engine.sol";

import {ERC20Mock} from "./utils/ERC20Mock.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract StabilityHookTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    StabilityHook hook;
    PoolId poolId;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    ERC20 usdt = ERC20(USDT);
    ERC20 usdc = ERC20(USDC);
    ERC20 dai = ERC20(DAI);

    ThreeCRV69 threeCRV69;
    StableToken stableToken;
    Engine engine_contract;

    // Mainnet deployed addresses
    address constant POOL_MANAGER_ADDRESS = address(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant POSITION_MANAGER_ADDRESS = address(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);

    // Mainnet RPC URL environment variable name
    string constant MAINNET_RPC_URL = "MAINNET_RPC_URL";
    // Block number to fork from - you might want to adjust this
    uint256 constant FORK_BLOCK_NUMBER = 21961311; // 2nd March 2025 block number

    address alice = makeAddr("Alice");
    address bob = makeAddr("Bob");

    function setUp() public {

        // Create and select the fork
        vm.createSelectFork(vm.envString(MAINNET_RPC_URL), FORK_BLOCK_NUMBER);
        
        vm.label(POOL_MANAGER_ADDRESS, "PoolManager");
        vm.label(POSITION_MANAGER_ADDRESS, "PositionManager");
        vm.label(alice, "Alice");
        console.log("alice", alice);
        vm.label(bob, "Bob");
        console.log("bob", bob);
        vm.label(address(this), "this test contract");
        //console.log("this", address(this));

        // Use the deployed PoolManager
        manager = IPoolManager(POOL_MANAGER_ADDRESS);
        // Use the deployed PositionManager
        posm = IPositionManager(POSITION_MANAGER_ADDRESS);
        
        // Initialize test routers with the real manager
        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        modifyLiquidityNoChecks = new PoolModifyLiquidityTestNoChecks(manager);
        donateRouter = new PoolDonateTest(manager);
        takeRouter = new PoolTakeTest(manager);
        claimsRouter = new PoolClaimsTest(manager);
        nestedActionRouter = new PoolNestedActionsTest(manager);
        feeController = makeAddr("feeController");
        actionsRouter = new ActionsRouter(manager);

        //deal(USDT, alice, 1000e6);
        vm.label(USDT, "USDT");
        //deal(USDC, alice, 1000e6);
        vm.label(USDC, "USDC");
        //deal(DAI, alice,  1000e18);
        vm.label(DAI, "DAI");

        threeCRV69 = new ThreeCRV69(
            USDT,
            USDC,
            DAI
        );
        vm.label(address(threeCRV69), "3CRV");

        console.log("usdt balance", usdt.balanceOf(alice));
        console.log("usdc balance", usdc.balanceOf(alice));
        console.log("dai balance", dai.balanceOf(alice));

        engine_contract = new Engine();
        stableToken = new StableToken(address(engine_contract));  //TODO: change to the correct address
        //deal(address(stableToken), alice, 1000e18);
        //console.log("stableToken balance", stableToken.balanceOf(alice));

        Currency currency0 = Currency.wrap(address(stableToken));
        Currency currency1 = Currency.wrap(address(threeCRV69));

        (currency0, currency1) =
            SortTokens.sort(MockERC20(Currency.unwrap(currency0)), MockERC20(Currency.unwrap(currency1)));

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(manager, threeCRV69); //Add all the necessary constructor arguments from the hook
        deployCodeTo("StabilityHook.sol:StabilityHook", constructorArgs, flags);
        hook = StabilityHook(flags);
        vm.label(address(hook), "hook");

        // Create the pool key
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        // Provide full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        console.log("tickLower", tickLower);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        console.log("tickUpper", tickUpper);

        uint256 amount0Desired = 100e18;
        uint256 amount1Desired = 100e18;

        uint128 liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Desired,
            amount1Desired
        );
        console.log("liquidityAmount", liquidityAmount);
        console.log("amount0Desired ", amount0Desired + 1);
        console.log("amount1Desired ", amount1Desired + 2);

        deal(address(stableToken), alice, amount0Desired + 1);
        deal(DAI, alice, amount1Desired + 10); //dai to mint within the hook with 3crv69
        console.log("dai balance   ", dai.balanceOf(alice));

        uint256 _3crvTokenId = 2;
        bytes memory HOOK_ARGS = abi.encode(_3crvTokenId, alice);

        //mint liquidity
        vm.startPrank(alice);        
            console.log("token approvals");
            // Setup approvals for PositionManager (as Alice)
            etchPermit2();
            ERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
            ERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
            permit2.approve(Currency.unwrap(currency0), address(posm), type(uint160).max, type(uint48).max);
            permit2.approve(Currency.unwrap(currency1), address(posm), type(uint160).max, type(uint48).max);
            // Add approvals for swap router
            ERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
            ERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
            
            dai.approve(address(hook), amount1Desired + 10);
            console.log("balance of currency0", ERC20(Currency.unwrap(currency0)).balanceOf(alice));
            console.log("balance of currency1", ERC20(Currency.unwrap(currency1)).balanceOf(alice));

            console.log("minting liquidity");
            (tokenId,) = posm.mint(
                key,
                tickLower,
                tickUpper,
                liquidityAmount,
                amount0Desired * 101 / 100, // Add 1% slippage tolerance
                amount1Desired * 101 / 100, // Add 1% slippage tolerance
                alice,
                block.timestamp,
                HOOK_ARGS
            );
        vm.stopPrank();
    }

    function testVariables() public {
        console.log("Weasy");
    }

    function testHooks() public {
        // positions were created in setup()
        assertEq(hook.beforeAddLiquidityCount(poolId), 1);
        assertEq(hook.afterRemoveLiquidityCount(poolId), 0);

        assertEq(hook.beforeSwapCount(poolId), 0);
        assertEq(hook.afterSwapCount(poolId), 0);

        // Perform a test swap //
        bool zeroForOne = true;
        int256 amountSpecified = -1e18; // negative number indicates exact input swap!
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        // ------------------- //

        assertEq(int256(swapDelta.amount0()), amountSpecified);

        assertEq(hook.beforeSwapCount(poolId), 1);
        assertEq(hook.afterSwapCount(poolId), 1);
    }

    function testLiquidityHooks() public {
        //log token balances before adding liquidity
        uint256 token0BalanceBefore = ERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 token1BalanceBefore = ERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        // positions were created in setup()
        assertEq(hook.beforeAddLiquidityCount(poolId), 1);
        assertEq(hook.afterRemoveLiquidityCount(poolId), 0);

        // remove liquidity
        uint256 liquidityToRemove = 1e18;
        posm.decreaseLiquidity(
            tokenId,
            liquidityToRemove,
            MAX_SLIPPAGE_REMOVE_LIQUIDITY,
            MAX_SLIPPAGE_REMOVE_LIQUIDITY,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );

        assertEq(hook.beforeAddLiquidityCount(poolId), 1);
        assertEq(hook.afterRemoveLiquidityCount(poolId), 1);

        //log token balances after removing liquidity
        uint256 token0BalanceAfter = ERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 token1BalanceAfter = ERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        
        //console log both balances 
        //console.log("token0 balance after  removing liquidity", token0BalanceAfter);
        //console.log("token0 balance before removing liquidity", token0BalanceBefore);
        //console.log("token1 balance after  removing liquidity", token1BalanceAfter);
        //console.log("token1 balance before removing liquidity", token1BalanceBefore);

        //console log the difference
        console.log("token0 balance difference", token0BalanceAfter - token0BalanceBefore);
        console.log("token1 balance difference", token1BalanceAfter - token1BalanceBefore);
    }
}