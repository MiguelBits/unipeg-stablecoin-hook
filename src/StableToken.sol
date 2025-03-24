// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {Engine} from './Engine.sol';

contract StableToken is ERC20 {

    address public engine;

    modifier onlyEngine() {
        require(msg.sender == engine, 'Only engine can call this function');
        _;
    }

    constructor(address _engine) ERC20('$CASHMONEY', '$CASHMONEY') {
        engine = _engine;
    }

    function mint(address to, uint256 amount) external onlyEngine {
        _mint(to, amount);
    }

    function burn(uint256 amount) external onlyEngine {
        _burn(msg.sender, amount);
    }

    function give(address to, uint256 amount) external onlyEngine {
        _mint(to, amount);
    }

    function take(uint256 amount) external onlyEngine {
        _burn(msg.sender, amount);
    }
}