# UNIPEG - Decentralized Stablecoin on Uniswap V4

![UniPeg Logo](https://via.placeholder.com/150) <!-- Replace with actual logo URL -->

**UNI PEG** is a cutting-edge decentralized stablecoin built on Uniswap V4 using Solidity and Foundry. The UNIPEG token (UNIPEG) aims to maintain a $1 peg through a dual-pool hook system: a **Stability Pool Hook** for low-slippage stablecoin trading and fee generation, and then **Leverage Pool Hooks** for overcollateralized lending against volatile assets like ETH.  
Implementing Uniswap V4 hooks with a stablecoin offers stability, yield generation, and lending into a single robust ecosystem.

## Table of Contents
- [Overview](#overview)
- [Key Features](#key-features)
- [Architecture](#architecture)
- [Peg Maintenance](#peg-maintenance)
- [Yield Generation](#yield-generation)
- [Technical Details](#technical-details)
- [Getting Started](#getting-started)
- [Contributing](#contributing)
- [License](#license)

## Overview

**UNIPEG** introduces a hybrid stablecoin model that blends stablecoin pools with overcollateralized lending. Built on Uniswap V4, it uses custom hooks to manage liquidity, fees, and collateral, offering a scalable and efficient solution for DeFi users. The project draws inspiration from efficient stablecoin trading pools and advanced lending protocols, aiming to be the premier stablecoin for stability and utility. It just makes complete sense for a stablecoin to co-exist with its liquidity together in the same rules and conditions.

- **Stability Pool**: A Uniswap V4 pool for trading UNIPEG alongside DAI, USDC, and USDT, collecting fees to maintain the peg and generate yields.
- **Leverage Pool**: A lending pool where users deposit volatile assets (e.g., ETH) to mint UNIP, governed by the `Engine.sol` contract.
- **Treasury**: Accumulates fees to intervene in the market and stabilize UNIP’s peg when needed.

## Key Features

- **Peg Stability**: Maintained through arbitrage, treasury buybacks, and overcollateralization.
- **Efficient Trading**: Stability Pool offers low-slippage swaps between UNIPEG and major stablecoins, inspired by Curve Finance’s design.
- **Lending & Leverage**: Single-sided deposits of volatile assets enable UNIPEG minting with customizable leverage, managed by smart contract rules.
- **Yield Opportunities**: Fees from the Stability Pool are redistributed to liquidity providers or used for peg maintenance.
- **Uniswap V4 Hooks**: Custom logic for fee collection, collateral management, and liquidation, leveraging the latest in DeFi infrastructure.

## Architecture

### Components

1. **UNIPEG Token**  
   - ERC-20 token representing UNI PEG.
   - Minted and burned via hooks in the Leverage Pool, with supply controlled by collateral and stability mechanisms.

2. **Treasury**  
   - Collects fees from the Stability Pool.
   - Buys back UNIPEG when it trades below $1, ensuring peg stability.
   - Other strategy actions

3. **Engine.sol**  
   - Sets parameters like collateral ratios (e.g., 150% for ETH), interest rates, and liquidation triggers.
   - Sets which contracts can create UNIPEG strategies like leveraged pools.

### Uniswap V4 Hooks
- **Stability Hook**: Triggers allows management of liquity and swaps using any stable token (usdc/usdt/dai) against UNIPEG and peg maintenance through arbitrage swaps and buybacks.
- **Leverage Hook**: Manages collateral deposits, UNIP minting, and liquidations. Ensures overcollateralization and system solvency.

## Peg Maintenance

UNIPEG maintains its $1 peg through a multi-layered approach:

1. **Arbitrage Swap Incentives**  
   - Custom Fees for arbitrage swaps, can arbitrage price by minting UNIPEG and giving profit to treasury, this is distributed to stability pool users.
     
2. **Treasury Buybacks**  
   - Fees from the Stability Pool fund Treasury buybacks of UNIPEG when it falls below peg, stabilizing the market.
3. **Overcollateralization**  
   - Leverage Pool requires collateral (e.g., 150% ETH value) to mint UNIPEG. Liquidations occur if collateral value drops below the threshold, ensuring backing.

4. **Leveraged Collateral Token** *(Enhancement)*  
   - Inspired by advanced stablecoin models, `Engine.sol` can adjust collateral ratios based on collateral’s price action (e.g., increase to leverage as price goes up, and repay debt and price moves downwards), balancing supply and demand dynamically, creating unliquidatable positions, and not allow overleverage or under leverage by asserting the same leverage for all pools users.

## Yield Generation

- **Trading Pools Fees**: Trading fees (e.g., 0.05%) are collected and either redistributed to liquidity providers or sent to the Treasury for peg maintenance.
- **Lending Interest**: Users borrowing UNIPEG from the Leverage Pool pay interest, which can be distributed to collateral providers or used to enhance system stability.
- **Strategy Deployment** *(Enhancement)*  
   - Treasury funds can be deployed into yield-generating strategies (e.g., lending on Aave or staking), with profits used to bolster UNIP’s peg or reward holders.

## Technical Details

### Smart Contracts
- **StableToken.sol**: ERC-20 token with mint/burn functions restricted to hooks.
- **Treasury.sol**: Manages fee collection and buyback operations.
- **Engine.sol**: Sets and enforces Leverage Pool rules (collateral ratios, liquidation thresholds).
- **StabilityHook.sol**: Custom hook for fee collection and Treasury updates.
- **LeverageHook.sol**: Custom hook for collateral management and liquidation.

### Development Stack
- **Solidity**: Smart contract language.
- **Foundry**: Testing, deployment, and scripting framework.
- **Uniswap V4**: Core infrastructure for pools and hooks.
- **EigenLayer**: Leverage management.

### Example Hook Logic
```solidity
// Stability Hook (simplified)
function afterSwap(address sender, uint256 amountIn, uint256 amountOut) external {
    uint256 fee = calculateFee(amountIn);
    treasury.transfer(fee);
    if (unipPrice() < 1e18) { // 1 USD in wei
        treasury.triggerBuyback();
    }
}

// Leverage Hook (simplified)
function afterDeposit(address user, address asset, uint256 amount) external {
    uint256 unipToMint = engine.calculateMintAmount(asset, amount);
    unip.mint(user, unipToMint);
    engine.updateCollateral(user, asset, amount);
}
