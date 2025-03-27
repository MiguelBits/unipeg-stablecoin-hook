// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ThreeCRV69} from "../src/3CRV69.sol";
import {ERC20Mock} from "./utils/mocks/ERC20Mock.sol";

contract ThreeCRV69Test is Test {

    ThreeCRV69 threeCRV69;
    ERC20Mock usdt;
    ERC20Mock usdc;
    ERC20Mock dai;

    function setUp() public {
        usdt = new ERC20Mock("USDT", "USDT");
        usdc = new ERC20Mock("USDC", "USDC");
        dai = new ERC20Mock("DAI", "DAI");
        usdt.setDecimals(6);
        usdc.setDecimals(6);
        dai.setDecimals(18);
        
        threeCRV69 = new ThreeCRV69(
            address(usdt), address(usdc), address(dai));

        usdt.mint(address(this), 1000e6);
        usdc.mint(address(this), 1000e6);
        dai.mint(address(this), 1000e18);

        usdt.approve(address(threeCRV69), 1000e6);
        usdc.approve(address(threeCRV69), 1000e6);
        dai.approve(address(threeCRV69), 1000e18);
    }

    function test_constructor() public view {
        assertEq(threeCRV69.tokens(0), address(usdt));
        assertEq(threeCRV69.tokens(1), address(usdc));
        assertEq(threeCRV69.tokens(2), address(dai));
    }

    function test_mint() public {

        console.log("usdt balance", usdt.balanceOf(address(this)));
        threeCRV69.mint(1000e6, 0, address(this));
        assertEq(threeCRV69.balanceOf(address(this)), 1000e18);
        assertEq(usdt.balanceOf(address(threeCRV69)), 1000e6);

        console.log("usdc balance", usdc.balanceOf(address(this)));
        threeCRV69.mint(1000e6, 1, address(this));
        assertEq(threeCRV69.balanceOf(address(this)), 2000e18);
        assertEq(usdc.balanceOf(address(threeCRV69)), 1000e6);

        console.log("dai balance", dai.balanceOf(address(this)));
        threeCRV69.mint(1000e18, 2, address(this));
        assertEq(threeCRV69.balanceOf(address(this)), 3000e18);
        assertEq(dai.balanceOf(address(threeCRV69)), 1000e18);
    }

    function test_burn() public {
        threeCRV69.mint(1000e6, 0, address(this));
        threeCRV69.mint(1000e6, 1, address(this));
        threeCRV69.mint(1000e18, 2, address(this));

        console.log("usdt balance", usdt.balanceOf(address(this)));
        threeCRV69.burn(1000e18, 0, address(this));
        assertEq(threeCRV69.balanceOf(address(this)), 2000e18);

        console.log("usdc balance", usdc.balanceOf(address(this)));
        threeCRV69.burn(1000e18, 1, address(this));
        assertEq(threeCRV69.balanceOf(address(this)), 1000e18);

        console.log("dai balance", dai.balanceOf(address(this)));
        threeCRV69.burn(1000e18, 2, address(this));
        assertEq(threeCRV69.balanceOf(address(this)), 0);
    }
}