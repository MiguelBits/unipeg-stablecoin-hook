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
    function getSlot0(PoolId id) external view returns (uint160 sqrtPriceX96, int24 tick, uint16 protocolFee, uint8 swapFee, uint8 tickSpacing, uint8 minLiquidity, uint8 extensionLength) {
        return (poolPrices[id], 0, 0, 0, 0, 0, 0);
    }
} 