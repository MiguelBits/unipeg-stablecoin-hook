// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol"; 

contract ThreeCRV69 is ERC20 {

    mapping(uint256 tokenId => address token) public tokens;

    modifier certifiedToken(uint256 tokenId) {
        require(tokens[tokenId] != address(0), "Invalid tokenId");
        _;
    }

    constructor(address _usdt, address _usdc, address _dai) ERC20("3CRV69", "3CRV69") {
        tokens[0] = _usdt;
        tokens[1] = _usdc;
        tokens[2] = _dai;
    }

    function mint(uint256 _amount, uint256 _tokenId, address _to) public certifiedToken(_tokenId) {
        ERC20 token = ERC20(tokens[_tokenId]);
        //transfer tokenId to this contract
        token.transferFrom(msg.sender, address(this), _amount);

        //get token decimals
        uint8 tokenDecimals = token.decimals();
        uint256 amount18;
        if (tokenDecimals != 18) {
            //convert _amount to 18 decimals
            amount18 = _amount * 10 ** (18 - tokenDecimals);
        } else {
            amount18 = _amount;
        }

        //mint 3crv69 to to
        _mint(_to, amount18);
    }

    function burn(uint256 _amount, uint256 _tokenId, address _to) public certifiedToken(_tokenId) {
        ERC20 token = ERC20(tokens[_tokenId]);
        //burn 3crv69 from from
        _burn(msg.sender, _amount);

        //get token decimals
        uint8 tokenDecimals = token.decimals();
        uint256 amountDecimals;
        if (tokenDecimals != 18) {
            //convert _amount to 18 decimals
            amountDecimals = _amount / 10 ** (18 - tokenDecimals);
        } else {
            amountDecimals = _amount;
        }

        //transfer tokenId to from
        token.transfer(_to, amountDecimals);
    }

    function getToken(uint256 _tokenId) public view returns (address) {
        return tokens[_tokenId];
    }

}
