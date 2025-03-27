// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/**
 * @title MockPoolManager
 * @notice Mock for Uniswap V4 Pool Manager
 */
contract MockPoolManager {
    // Store prices as sqrtPriceX96 values
    mapping(PoolId => uint160) public poolPrices;
    
    // Set a pool's price
    function setPoolPrice(PoolId poolId, uint160 sqrtPriceX96) external {
        poolPrices[poolId] = sqrtPriceX96;
    }
    
    // Mock of the getSlot0 function that returns price data
    function getSlot0(PoolId id) external view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 protocolFee,
        uint8 swapFee,
        uint8 tickSpacing
    ) {
        return (poolPrices[id], 0, 0, 0, 0);
    }
    
    // Other functions from IPoolManager interface
    // These are just stubs since we only care about getSlot0 for our tests
    
    function initialize(PoolKey calldata, uint160, bytes calldata) external returns (int24) {
        return 0;
    }
    
    function unlock(bytes calldata lockData) external pure {}
    
    function modifyLiquidity(PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata) external returns (BalanceDelta) {
        return BalanceDelta(0, 0);
    }
    
    function swap(PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata) external returns (BalanceDelta) {
        return BalanceDelta(0, 0);
    }
    
    function donate(PoolKey calldata, uint256, uint256, bytes calldata) external returns (BalanceDelta) {
        return BalanceDelta(0, 0);
    }
    
    function take(Currency, address, uint256) external returns (uint256) {
        return 0;
    }
    
    function settle(Currency) external returns (uint256) {
        return 0;
    }
    
    function mint(Currency, address, uint256) external {}
    
    function burn(Currency, uint256) external {}
} 