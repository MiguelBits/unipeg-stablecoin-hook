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
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------

    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        beforeSwapCount[key.toId()]++;
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        afterSwapCount[key.toId()]++;
        return (BaseHook.afterSwap.selector, 0);
    }

    function _beforeAddLiquidity(
        address _manager,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {

        console.log("beforeAddLiquidity");

        address sender = IMsgSender(_manager).msgSender();
        console.log("sender", sender);

        //decode the params into address
        (uint256 token0_id) = abi.decode(hookData, (uint256));
        address token0 = threeCRV69_contract.getToken(token0_id);
        console.log("token0", token0);

        uint256 token0_amount = uint256(params.liquidityDelta);
        console.log("token0_amount", token0_amount);
        IERC20 token0Contract = IERC20(token0);

        //check if the token0 is the threeCRV69 contract
        if (token0 != address(0)) {
            //transfer token0 to the pool
            token0Contract.transferFrom(sender, address(this), token0_amount);
            console.log("balance of token0", token0Contract.balanceOf(address(this)));

            //approve & mint 3crv69 to the user
            token0Contract.approve(address(threeCRV69_contract), token0_amount);
            threeCRV69_contract.mint(token0_amount, token0_id, sender);
        }

        return BaseHook.beforeAddLiquidity.selector;
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata /*params*/,
        BalanceDelta delta,
        BalanceDelta /*feesAccrued*/,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {

        console.log("afterRemoveLiquidity");

        return (BaseHook.afterRemoveLiquidity.selector, delta);
    }
}