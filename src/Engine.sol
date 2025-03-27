// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StableToken} from "./StableToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// Uniswap V4 imports
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/**
 * @title Engine
 * @author UNIPEG Team
 * @notice This contract is the core of the UNIPEG system. It handles:
 * - Collateral management
 * - UNIPEG minting and burning
 * - Liquidations
 * - Parameter management
 * - Interest accrual
 * It uses Uniswap V4 pools for price determination.
 */
contract Engine is ReentrancyGuard, Ownable {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    ///////////////////
    // Errors
    ///////////////////
    error Engine__NeedsMoreThanZero();
    error Engine__TokenPoolsAndLiquidationThresholdsMustBeSameLength();
    error Engine__NotAllowedToken();
    error Engine__TransferFailed();
    error Engine__BreaksHealthFactor(uint256 healthFactor);
    error Engine__MintFailed();
    error Engine__HealthFactorOk();
    error Engine__HealthFactorNotImproved();
    error Engine__PoolNotFound();
    error Engine__PriceError();

    ///////////////////
    // Types
    ///////////////////
    struct CollateralInfo {
        PoolId poolId;           // Uniswap V4 pool ID for price reference
        uint256 liquidationThreshold; // 150% = 15000, 200% = 20000
        bool isToken0;           // Whether the collateral is token0 or token1 in the pool
    }

    struct UserDebtInfo {
        uint256 principal;       // Original borrowed amount
        uint256 lastAccrueTime;  // Last time interest was accrued
    }

    ///////////////////
    // State Variables
    ///////////////////
    uint256 private constant LIQUIDATION_THRESHOLD = 150; // 150% collateralization ratio
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus for liquidators
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant PRECISION = 1e18;
    
    // Interest rate constants
    uint256 private constant SECONDS_PER_YEAR = 31536000; // 365 days
    uint256 private constant INTEREST_RATE = 5e16; // 5% annual interest rate (scaled by 1e18)

    /// @notice The UNIPEG stablecoin
    StableToken private immutable i_unipeg;
    
    /// @notice The Uniswap V4 Pool Manager
    IPoolManager private immutable i_poolManager;

    /// @notice Mapping of token address to collateral info
    mapping(address collateralToken => CollateralInfo) private s_collateralInfo;
    /// @notice List of allowed collateral tokens
    address[] private s_collateralTokens;

    /// @notice Mapping of user to token to amount of collateral deposited
    mapping(address user => mapping(address collateralToken => uint256)) private s_userCollateral;
    /// @notice Mapping of user to their debt info
    mapping(address user => UserDebtInfo) private s_userDebt;

    // Protocol-wide tracking
    uint256 private s_totalPrincipal;
    uint256 private s_totalInterestAccrued;

    ///////////////////
    // Events
    ///////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(address indexed from, address indexed to, address indexed token, uint256 amount);
    event UnipegMinted(address indexed user, uint256 amount);
    event UnipegBurned(address indexed user, uint256 principalAmount, uint256 interestAmount);
    event InterestAccrued(address indexed user, uint256 interestAmount);
    event CollateralLiquidated(
        address indexed user, address indexed liquidator, address indexed token, uint256 amount, uint256 unipegAmount
    );
    event CollateralTokenAdded(address indexed token, PoolId indexed poolId, bool isToken0, uint256 liquidationThreshold);
    event LiquidationThresholdUpdated(address indexed token, uint256 oldThreshold, uint256 newThreshold);

    ///////////////////
    // Modifiers
    ///////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert Engine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_collateralInfo[token].poolId == bytes32(0)) {
            revert Engine__NotAllowedToken();
        }
        _;
    }

    ///////////////////
    // Constructor
    ///////////////////
    constructor(
        address[] memory tokenAddresses, 
        PoolKey[] memory poolKeys,
        bool[] memory isToken0Array,
        address unipegAddress, 
        address poolManagerAddress
    ) Ownable(msg.sender) {
        if (tokenAddresses.length != poolKeys.length || tokenAddresses.length != isToken0Array.length) {
            revert Engine__TokenPoolsAndLiquidationThresholdsMustBeSameLength();
        }
        
        i_poolManager = IPoolManager(poolManagerAddress);
        
        // Default liquidation threshold is 150%
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_collateralInfo[tokenAddresses[i]] = CollateralInfo({
                poolId: poolKeys[i].toId(),
                liquidationThreshold: LIQUIDATION_THRESHOLD * LIQUIDATION_PRECISION,
                isToken0: isToken0Array[i]
            });
            s_collateralTokens.push(tokenAddresses[i]);
            emit CollateralTokenAdded(
                tokenAddresses[i], 
                poolKeys[i].toId(), 
                isToken0Array[i],
                LIQUIDATION_THRESHOLD * LIQUIDATION_PRECISION
            );
        }
        i_unipeg = StableToken(unipegAddress);
    }

    ///////////////////
    // External Functions
    ///////////////////
    
    /**
     * @notice Deposits collateral and mints UNIPEG in one transaction
     * @param tokenCollateral The address of the collateral token
     * @param amountCollateral The amount of collateral to deposit
     * @param amountUnipegToMint The amount of UNIPEG to mint
     */
    function depositCollateralAndMintUnipeg(
        address tokenCollateral,
        uint256 amountCollateral,
        uint256 amountUnipegToMint
    ) external {
        depositCollateral(tokenCollateral, amountCollateral);
        mintUnipeg(amountUnipegToMint);
    }

    /**
     * @notice Deposits collateral into the system
     * @param tokenCollateral The address of the collateral token
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateral, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateral)
        nonReentrant
    {
        s_userCollateral[msg.sender][tokenCollateral] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateral, amountCollateral);
        bool success = IERC20(tokenCollateral).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert Engine__TransferFailed();
        }
    }

    /**
     * @notice Redeems collateral from the system
     * @param tokenCollateral The address of the collateral token
     * @param amountCollateral The amount of collateral to redeem
     */
    function redeemCollateral(address tokenCollateral, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        // Accrue interest before checking health factor
        _accrueInterest(msg.sender);
        
        _redeemCollateral(msg.sender, msg.sender, tokenCollateral, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Burns UNIPEG and redeems collateral in one transaction
     * @param tokenCollateral The address of the collateral token
     * @param amountCollateral The amount of collateral to redeem
     * @param amountUnipegToBurn The amount of UNIPEG to burn
     */
    function redeemCollateralForUnipeg(
        address tokenCollateral,
        uint256 amountCollateral,
        uint256 amountUnipegToBurn
    ) external {
        burnUnipeg(amountUnipegToBurn);
        redeemCollateral(tokenCollateral, amountCollateral);
    }

    /**
     * @notice Mints UNIPEG stablecoin
     * @param amountUnipegToMint The amount of UNIPEG to mint
     */
    function mintUnipeg(uint256 amountUnipegToMint) public moreThanZero(amountUnipegToMint) nonReentrant {
        // Accrue interest before minting
        _accrueInterest(msg.sender);
        
        // Update user's debt info
        UserDebtInfo storage userDebt = s_userDebt[msg.sender];
        userDebt.principal += amountUnipegToMint;
        userDebt.lastAccrueTime = block.timestamp;
        
        // Update total principal
        s_totalPrincipal += amountUnipegToMint;
        
        // Check if the health factor is broken
        _revertIfHealthFactorIsBroken(msg.sender);
        
        // Mint the UNIPEG
        bool minted = i_unipeg.mint(msg.sender, amountUnipegToMint);
        if (!minted) {
            revert Engine__MintFailed();
        }
        emit UnipegMinted(msg.sender, amountUnipegToMint);
    }

    /**
     * @notice Burns UNIPEG stablecoin
     * @param amount The amount of UNIPEG to burn
     */
    function burnUnipeg(uint256 amount) public moreThanZero(amount) nonReentrant {
        _accrueInterest(msg.sender);
        
        // Calculate current total debt
        UserDebtInfo storage userDebt = s_userDebt[msg.sender];
        uint256 totalDebt = getCurrentDebt(msg.sender);
        
        // Determine how much goes to principal vs interest
        uint256 interestPortion = totalDebt > userDebt.principal ? 
            (amount > (totalDebt - userDebt.principal) ? totalDebt - userDebt.principal : amount) : 
            0;
        uint256 principalPortion = amount - interestPortion;
        
        // Make sure we don't burn more principal than exists
        if (principalPortion > userDebt.principal) {
            principalPortion = userDebt.principal;
        }
        
        // Update user's debt info
        userDebt.principal -= principalPortion;
        userDebt.lastAccrueTime = block.timestamp;
        
        // Update global accounting
        s_totalPrincipal -= principalPortion;
        s_totalInterestAccrued -= interestPortion;
        
        // Transfer tokens from user to this contract
        bool success = IERC20(address(i_unipeg)).transferFrom(msg.sender, address(this), amount);
        if (!success) {
            revert Engine__TransferFailed();
        }
        
        // Burn the tokens
        i_unipeg.burn(amount);
        emit UnipegBurned(msg.sender, principalPortion, interestPortion);
    }

    /**
     * @notice Liquidates a user's position if their health factor is below MIN_HEALTH_FACTOR
     * @param user The user to liquidate
     * @param tokenCollateral The collateral token to liquidate
     * @param debtToCover The amount of debt to cover (in UNIPEG)
     */
    function liquidate(address user, address tokenCollateral, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // Accrue interest for the user being liquidated
        _accrueInterest(user);
        
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert Engine__HealthFactorOk();
        }
        
        // Calculate the amount of collateral to seize
        uint256 tokenAmountFromDebtCovered = _getTokenAmountFromUsd(tokenCollateral, debtToCover);
        // Add the liquidation bonus
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToSeize = tokenAmountFromDebtCovered + bonusCollateral;
        
        // Ensure we don't seize more than the user has
        uint256 userCollateral = s_userCollateral[user][tokenCollateral];
        if (totalCollateralToSeize > userCollateral) {
            totalCollateralToSeize = userCollateral;
        }
        
        // Redeem the collateral to the liquidator
        _redeemCollateral(user, msg.sender, tokenCollateral, totalCollateralToSeize);
        
        // Determine how much to repay from principal vs interest
        UserDebtInfo storage userDebt = s_userDebt[user];
        uint256 totalDebt = getCurrentDebt(user);
        
        uint256 interestPortion = totalDebt > userDebt.principal ? 
            (debtToCover > (totalDebt - userDebt.principal) ? totalDebt - userDebt.principal : debtToCover) : 
            0;
        uint256 principalPortion = debtToCover - interestPortion;
        
        // Update user's debt info
        if (principalPortion > userDebt.principal) {
            principalPortion = userDebt.principal;
        }
        userDebt.principal -= principalPortion;
        userDebt.lastAccrueTime = block.timestamp;
        
        // Update global accounting
        s_totalPrincipal -= principalPortion;
        s_totalInterestAccrued -= interestPortion;
        
        // Transfer tokens from liquidator to this contract and burn
        bool success = IERC20(address(i_unipeg)).transferFrom(msg.sender, address(this), debtToCover);
        if (!success) {
            revert Engine__TransferFailed();
        }
        
        // Burn the tokens
        i_unipeg.burn(debtToCover);
        
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert Engine__HealthFactorNotImproved();
        }
        
        emit CollateralLiquidated(user, msg.sender, tokenCollateral, totalCollateralToSeize, debtToCover);
    }

    ///////////////////
    // Admin Functions
    ///////////////////
    
    /**
     * @notice Adds a new collateral token to the system
     * @param tokenAddress The address of the token
     * @param poolKey The Uniswap V4 pool key for price reference
     * @param isToken0 Whether the collateral is token0 or token1 in the pool
     * @param liquidationThreshold The liquidation threshold (e.g. 150% = 15000)
     */
    function addCollateralToken(
        address tokenAddress,
        PoolKey memory poolKey,
        bool isToken0,
        uint256 liquidationThreshold
    ) external onlyOwner {
        PoolId poolId = poolKey.toId();
        
        // Check if token is already added
        if (s_collateralInfo[tokenAddress].poolId != bytes32(0)) {
            // Update existing token info
            emit LiquidationThresholdUpdated(
                tokenAddress, 
                s_collateralInfo[tokenAddress].liquidationThreshold, 
                liquidationThreshold
            );
            s_collateralInfo[tokenAddress].liquidationThreshold = liquidationThreshold;
            s_collateralInfo[tokenAddress].poolId = poolId;
            s_collateralInfo[tokenAddress].isToken0 = isToken0;
        } else {
            // Add new token
            s_collateralInfo[tokenAddress] = CollateralInfo({
                poolId: poolId,
                liquidationThreshold: liquidationThreshold,
                isToken0: isToken0
            });
            s_collateralTokens.push(tokenAddress);
            emit CollateralTokenAdded(tokenAddress, poolId, isToken0, liquidationThreshold);
        }
    }

    /**
     * @notice Updates the liquidation threshold for a collateral token
     * @param tokenAddress The address of the token
     * @param newLiquidationThreshold The new liquidation threshold
     */
    function updateLiquidationThreshold(address tokenAddress, uint256 newLiquidationThreshold) external onlyOwner {
        if (s_collateralInfo[tokenAddress].poolId == bytes32(0)) {
            revert Engine__NotAllowedToken();
        }
        
        emit LiquidationThresholdUpdated(
            tokenAddress, 
            s_collateralInfo[tokenAddress].liquidationThreshold, 
            newLiquidationThreshold
        );
        s_collateralInfo[tokenAddress].liquidationThreshold = newLiquidationThreshold;
    }

    ///////////////////
    // Internal Functions
    ///////////////////
    
    /**
     * @dev Accrues interest for a user
     * @param user The user address
     */
    function _accrueInterest(address user) internal {
        UserDebtInfo storage userDebt = s_userDebt[user];
        
        // If no debt or just created debt, no interest to accrue
        if (userDebt.principal == 0 || userDebt.lastAccrueTime == block.timestamp) {
            userDebt.lastAccrueTime = block.timestamp;
            return;
        }
        
        uint256 timeElapsed = block.timestamp - userDebt.lastAccrueTime;
        if (timeElapsed == 0) return;
        
        // Calculate interest: principal * rate * timeElapsed / secondsPerYear
        uint256 interestAccrued = (userDebt.principal * INTEREST_RATE * timeElapsed) / (SECONDS_PER_YEAR * PRECISION);
        
        // Update the global interest counter
        s_totalInterestAccrued += interestAccrued;
        
        // Update last accrue time
        userDebt.lastAccrueTime = block.timestamp;
        
        emit InterestAccrued(user, interestAccrued);
    }
    
    /**
     * @dev Redeems collateral from a user
     * @param from The address to redeem from
     * @param to The address to send the collateral to
     * @param tokenCollateral The collateral token
     * @param amountCollateral The amount of collateral
     */
    function _redeemCollateral(address from, address to, address tokenCollateral, uint256 amountCollateral) internal {
        s_userCollateral[from][tokenCollateral] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateral, amountCollateral);
        
        bool success = IERC20(tokenCollateral).transfer(to, amountCollateral);
        if (!success) {
            revert Engine__TransferFailed();
        }
    }

    /**
     * @dev Reverts if a user's health factor is broken
     * @param user The user to check
     */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert Engine__BreaksHealthFactor(userHealthFactor);
        }
    }

    /**
     * @dev Calculates a user's health factor
     * @param user The user to calculate for
     * @return The health factor (scaled by 1e18)
     */
    function _healthFactor(address user) internal view returns (uint256) {
        uint256 totalDebt = getCurrentDebt(user);
        uint256 collateralValueInUsd = _getAccountCollateralValue(user);
        
        if (totalDebt == 0) return type(uint256).max;
        
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_PRECISION) / LIQUIDATION_THRESHOLD;
        return (collateralAdjustedForThreshold * PRECISION) / totalDebt;
    }

    /**
     * @dev Gets the value of a user's collateral in USD
     * @param user The user to get collateral value for
     * @return The value of the user's collateral in USD
     */
    function _getAccountCollateralValue(address user) internal view returns (uint256) {
        uint256 totalCollateralValueInUsd = 0;
        
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_userCollateral[user][token];
            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }
        
        return totalCollateralValueInUsd;
    }

    /**
     * @dev Gets the USD value of a token amount using Uniswap V4 pool price
     * @param token The token address
     * @param amount The token amount
     * @return The USD value (in 1e18 precision)
     */
    function _getUsdValue(address token, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        
        CollateralInfo memory info = s_collateralInfo[token];
        if (info.poolId == bytes32(0)) {
            revert Engine__NotAllowedToken();
        }
        
        // Get the price from Uniswap V4 pool using our wrapper function
        uint160 sqrtPriceX96 = getPoolPrice(info.poolId);
        
        // Calculate price based on sqrtPriceX96
        // The price formula depends on whether token is token0 or token1
        uint256 price;
        if (info.isToken0) {
            // If token is token0, price = 1/token0Price = token1/token0
            // price = (2^96)^2 / (sqrtPriceX96)^2 * (10^18)
            price = (1 << 192) / uint256(sqrtPriceX96) ** 2;
        } else {
            // If token is token1, price = token0/token1
            // price = (sqrtPriceX96)^2 / (2^96)^2 * (10^18)
            price = (uint256(sqrtPriceX96) ** 2 * PRECISION) / (1 << 192);
        }
        
        // We assume the other side of the pool is a stable token worth $1
        // So the price is directly in USD terms
        return (amount * price) / PRECISION;
    }

    /**
     * @dev Gets the token amount from a USD value
     * @param token The token address
     * @param usdAmount The USD amount
     * @return The token amount
     */
    function _getTokenAmountFromUsd(address token, uint256 usdAmount) internal view returns (uint256) {
        if (usdAmount == 0) return 0;
        
        CollateralInfo memory info = s_collateralInfo[token];
        if (info.poolId == bytes32(0)) {
            revert Engine__NotAllowedToken();
        }
        
        // Get the price from Uniswap V4 pool using our wrapper function
        uint160 sqrtPriceX96 = getPoolPrice(info.poolId);
        
        // Calculate token amount based on USD amount and sqrtPriceX96
        uint256 price;
        if (info.isToken0) {
            // If token is token0, price = 1/token0Price = token1/token0
            price = (1 << 192) / uint256(sqrtPriceX96) ** 2;
        } else {
            // If token is token1, price = token0/token1
            price = (uint256(sqrtPriceX96) ** 2 * PRECISION) / (1 << 192);
        }
        
        return (usdAmount * PRECISION) / price;
    }

    ///////////////////
    // View Functions
    ///////////////////
    
    /**
     * @notice Gets the current debt for a user including accrued interest
     * @param user The user address
     * @return The total debt including interest
     */
    function getCurrentDebt(address user) public view returns (uint256) {
        UserDebtInfo memory userDebt = s_userDebt[user];
        
        if (userDebt.principal == 0) return 0;
        
        uint256 timeElapsed = block.timestamp - userDebt.lastAccrueTime;
        
        // Calculate interest: principal * rate * timeElapsed / secondsPerYear
        uint256 interestAccrued = (userDebt.principal * INTEREST_RATE * timeElapsed) / (SECONDS_PER_YEAR * PRECISION);
        
        return userDebt.principal + interestAccrued;
    }
    
    /**
     * @notice Gets the price of the collateral in USD
     * @param token The token address
     * @return The price in USD (scaled by 1e18)
     */
    function getTokenPrice(address token) external view returns (uint256) {
        CollateralInfo memory info = s_collateralInfo[token];
        if (info.poolId == bytes32(0)) {
            revert Engine__NotAllowedToken();
        }
        
        // Get the price from Uniswap V4 pool using our wrapper function
        uint160 sqrtPriceX96 = getPoolPrice(info.poolId);
        
        // Calculate price based on sqrtPriceX96
        if (info.isToken0) {
            // If token is token0, price = 1/token0Price = token1/token0
            return (1 << 192) / uint256(sqrtPriceX96) ** 2;
        } else {
            // If token is token1, price = token0/token1
            return (uint256(sqrtPriceX96) ** 2 * PRECISION) / (1 << 192);
        }
    }

    /**
     * @notice Gets a user's health factor
     * @param user The user address
     * @return The health factor (scaled by 1e18)
     */
    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    /**
     * @notice Gets a user's collateral balance
     * @param user The user address
     * @param token The token address
     * @return The collateral balance
     */
    function getUserCollateral(address user, address token) external view returns (uint256) {
        return s_userCollateral[user][token];
    }

    /**
     * @notice Gets a user's debt info
     * @param user The user address
     * @return principal The principal amount
     * @return lastAccrueTime The last time interest was accrued
     */
    function getUserDebtInfo(address user) external view returns (uint256 principal, uint256 lastAccrueTime) {
        UserDebtInfo memory userDebt = s_userDebt[user];
        return (userDebt.principal, userDebt.lastAccrueTime);
    }

    /**
     * @notice Gets the list of collateral tokens
     * @return The list of collateral tokens
     */
    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    /**
     * @notice Gets the collateral information for a token
     * @param token The token address
     * @return poolId The Uniswap V4 pool ID
     * @return liquidationThreshold The liquidation threshold
     * @return isToken0 Whether the token is token0 in the pool
     */
    function getCollateralInfo(address token) external view returns (bytes32, uint256, bool) {
        CollateralInfo memory info = s_collateralInfo[token];
        return (info.poolId, info.liquidationThreshold, info.isToken0);
    }

    /**
     * @notice Gets the total principal and interest accrued
     * @return totalPrincipal The total principal
     * @return totalInterestAccrued The total interest accrued
     */
    function getTotalDebt() external view returns (uint256 totalPrincipal, uint256 totalInterestAccrued) {
        return (s_totalPrincipal, s_totalInterestAccrued);
    }
    
    /**
     * @notice Gets the annual interest rate
     * @return The annual interest rate (scaled by 1e18)
     */
    function getAnnualInterestRate() external pure returns (uint256) {
        return INTEREST_RATE;
    }

    // NEW FUNCTION: Wrapper for getting pool price
    /**
     * @notice Gets sqrt price from pool
     * @dev This function should be implemented according to how Uniswap V4 provides price information
     * @param poolId The pool ID
     * @return The sqrtPriceX96 value
     */
    function getPoolPrice(PoolId poolId) internal view returns (uint160) {
        // Replace this implementation with the actual way to get price from Uniswap V4
        // This could be a direct call, using a periphery contract, or another approach
        
        // Example implementation (replace with actual V4 mechanism)
        (uint160 sqrtPriceX96,,,,,) = i_poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) {
            revert Engine__PriceError();
        }
        return sqrtPriceX96;
    }
}

