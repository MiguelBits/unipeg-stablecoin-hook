// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {StableToken} from "../src/StableToken.sol";

contract StableTokenTest is Test {
    StableToken stableToken;
    address public ENGINE = makeAddr("engine");
    address public USER = makeAddr("user");
    uint256 public constant INITIAL_AMOUNT = 100 ether;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        stableToken = new StableToken(ENGINE);
    }

    //////////////////
    // Constructor //
    //////////////////
    
    function test_Constructor_SetsEngineCorrectly() public {
        assertEq(stableToken.engine(), ENGINE);
        assertEq(stableToken.name(), "$CASHMONEY");
        assertEq(stableToken.symbol(), "$CASHMONEY");
    }

    ////////////////
    // mint() //
    ////////////////
    
    function test_Mint_RevertIfNotEngine() public {
        vm.startPrank(USER);
        vm.expectRevert("Only engine can call this function");
        stableToken.mint(USER, INITIAL_AMOUNT);
        vm.stopPrank();
    }
    
    function test_Mint_WorksIfEngine() public {
        vm.startPrank(ENGINE);
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), USER, INITIAL_AMOUNT);
        stableToken.mint(USER, INITIAL_AMOUNT);
        vm.stopPrank();
        
        assertEq(stableToken.balanceOf(USER), INITIAL_AMOUNT);
        assertEq(stableToken.totalSupply(), INITIAL_AMOUNT);
    }

    ////////////////
    // burn() //
    ////////////////
    
    function test_Burn_RevertIfNotEngine() public {
        // First mint some tokens
        vm.prank(ENGINE);
        stableToken.mint(ENGINE, INITIAL_AMOUNT);
        
        vm.startPrank(USER);
        vm.expectRevert("Only engine can call this function");
        stableToken.burn(INITIAL_AMOUNT);
        vm.stopPrank();
    }
    
    function test_Burn_WorksIfEngine() public {
        // First mint some tokens
        vm.prank(ENGINE);
        stableToken.mint(ENGINE, INITIAL_AMOUNT);
        
        vm.startPrank(ENGINE);
        vm.expectEmit(true, true, false, true);
        emit Transfer(ENGINE, address(0), INITIAL_AMOUNT);
        stableToken.burn(INITIAL_AMOUNT);
        vm.stopPrank();
        
        assertEq(stableToken.balanceOf(ENGINE), 0);
        assertEq(stableToken.totalSupply(), 0);
    }
    
    ////////////////
    // give() //
    ////////////////
    
    function test_Give_RevertIfNotEngine() public {
        vm.startPrank(USER);
        vm.expectRevert("Only engine can call this function");
        stableToken.give(USER, INITIAL_AMOUNT);
        vm.stopPrank();
    }
    
    function test_Give_WorksIfEngine() public {
        vm.startPrank(ENGINE);
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), USER, INITIAL_AMOUNT);
        stableToken.give(USER, INITIAL_AMOUNT);
        vm.stopPrank();
        
        assertEq(stableToken.balanceOf(USER), INITIAL_AMOUNT);
        assertEq(stableToken.totalSupply(), INITIAL_AMOUNT);
    }

    ////////////////
    // take() //
    ////////////////
    
    function test_Take_RevertIfNotEngine() public {
        // First mint some tokens
        vm.prank(ENGINE);
        stableToken.mint(ENGINE, INITIAL_AMOUNT);
        
        vm.startPrank(USER);
        vm.expectRevert("Only engine can call this function");
        stableToken.take(INITIAL_AMOUNT);
        vm.stopPrank();
    }
    
    function test_Take_WorksIfEngine() public {
        // First mint some tokens
        vm.prank(ENGINE);
        stableToken.mint(ENGINE, INITIAL_AMOUNT);
        
        vm.startPrank(ENGINE);
        vm.expectEmit(true, true, false, true);
        emit Transfer(ENGINE, address(0), INITIAL_AMOUNT);
        stableToken.take(INITIAL_AMOUNT);
        vm.stopPrank();
        
        assertEq(stableToken.balanceOf(ENGINE), 0);
        assertEq(stableToken.totalSupply(), 0);
    }
} 