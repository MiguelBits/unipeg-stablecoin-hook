// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24; import "forge-std/console.sol";

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

import {ThreeCRV69} from "./3CRV69.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMsgSender {
    function msgSender() external view returns (address);
}

contract StabilityHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    // NOTE: ---------------------------------------------------------
    // state variables should typically be unique to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------

    mapping(PoolId => uint256 count) public beforeSwapCount;
    mapping(PoolId => uint256 count) public afterSwapCount;

    ThreeCRV69 public threeCRV69_contract;

    constructor(IPoolManager _poolManager, ThreeCRV69 _threeCRV69) BaseHook(_poolManager) {
        threeCRV69_contract = _threeCRV69;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------

    function _beforeSwap(
        address _manager,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {

        address sender = IMsgSender(_manager).msgSender();

        // Decode which stablecoin we're dealing with
        (uint256 token0_id) = abi.decode(hookData, (uint256));
        address token0 = threeCRV69_contract.getToken(token0_id);
        IERC20 token0Contract = IERC20(token0);

        // If swapping token0 (stablecoin) for token1
        if (params.zeroForOne) {
            uint256 amount0 = uint256(-params.amountSpecified);  // Convert to positive
            
            // Take stablecoin from user and mint 3CRV69
            token0Contract.transferFrom(sender, address(this), amount0);
            //approve & mint 3crv69 to the user
            token0Contract.approve(address(threeCRV69_contract), amount0);
            threeCRV69_contract.mint(amount0, token0_id, sender);
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        console.log("afterSwap");

        // If receiving token0 (3CRV69)
        if (delta.amount0() > 0) {
            uint256 amount0_uint = uint256(int256(delta.amount0()));
            
            // Take 3CRV69 from pool
            poolManager.take(key.currency0, address(this), amount0_uint);

            // Decode which stablecoin to return
            (uint256 token0_id) = abi.decode(hookData, (uint256));
            
            // Burn 3CRV69 to return stablecoin
            threeCRV69_contract.burn(amount0_uint, token0_id, sender);
            poolManager.settle();
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    function _beforeAddLiquidity(
        address _manager,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {

        address sender = IMsgSender(_manager).msgSender();

        //decode the params into address
        (uint256 token0_id) = abi.decode(hookData, (uint256));
        address token0 = threeCRV69_contract.getToken(token0_id);

        uint256 token0_amount = uint256(params.liquidityDelta);
        IERC20 token0Contract = IERC20(token0);

        //check if the token0 is the threeCRV69 contract
        if (token0 != address(0)) {
            //transfer token0 to the pool
            token0Contract.transferFrom(sender, address(this), token0_amount);

            //approve & mint 3crv69 to the user
            token0Contract.approve(address(threeCRV69_contract), token0_amount);
            threeCRV69_contract.mint(token0_amount, token0_id, sender);
        }

        return BaseHook.beforeAddLiquidity.selector;
    }

    function _afterRemoveLiquidity(
        address _manager,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata /*params*/,
        BalanceDelta delta,
        BalanceDelta /*feesAccrued*/,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {

        // Encode operation parameters
        address sender = IMsgSender(_manager).msgSender();
        
        // Convert delta.amount0() to uint256
        uint256 amount0_uint = uint256(int256(delta.amount0()));
        
        // Decode which original stablecoin to return
        (uint256 token0_id) = abi.decode(hookData, (uint256));

        //Pool accounting
        poolManager.take(key.currency0, address(this), amount0_uint);

        //Burn 3CRV69 tokens to return original stablecoin to sender
        threeCRV69_contract.burn(amount0_uint, token0_id, sender);
        //IERC20 token0Contract = IERC20(threeCRV69_contract.getToken(token0_id));
        //console.log("alice balance", token0Contract.balanceOf(0xBf0b5A4099F0bf6c8bC4252eBeC548Bae95602Ea));

        //New delta //toBalanceDelta
        int128 amount0 = delta.amount0();
        int128 amount1 = 0;
        BalanceDelta hookDelta = toBalanceDelta(amount0, amount1);

        return (BaseHook.afterRemoveLiquidity.selector, hookDelta);
    }

}