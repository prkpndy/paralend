// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import "../CompoundV2/CToken.sol";
import "../CompoundV2/libraries/ExponentialNoError.sol";

/**
 * @title SimplifiedComptroller
 * @notice Manages collateral and liquidity calculations for the lending protocol
 * @dev Simplified version of Compound's Comptroller for MVP
 *
 * Key Features:
 * - Tracks which markets users have entered for collateral
 * - Calculates account liquidity (collateral value - borrow value)
 * - Enforces collateral requirements for borrows
 * - Simple price oracle with settable prices
 *
 * Collateral Factor: 75% (can borrow 75% of collateral value)
 * Liquidation Threshold: 80% (liquidated when debt > 80% of collateral)
 */
contract SimplifiedComptroller is ExponentialNoError {
    /**
     * @notice Collateral factor: 0.75 = 75%
     * @dev Users can borrow up to 75% of their collateral value
     */
    uint256 public constant collateralFactorMantissa = 0.75e18;

    /**
     * @notice Liquidation threshold: 0.80 = 80%
     * @dev Users are liquidated when debt exceeds 80% of collateral value
     */
    uint256 public constant liquidationThresholdMantissa = 0.80e18;

    /**
     * @notice Close factor: 0.5 = 50%
     * @dev Liquidators can repay up to 50% of a borrower's debt
     */
    uint256 public constant closeFactorMantissa = 0.5e18;

    /**
     * @notice Liquidation incentive: 1.08 = 108%
     * @dev Liquidators receive 108% of repaid value in collateral (8% bonus)
     */
    uint256 public constant liquidationIncentiveMantissa = 1.08e18;

    /**
     * @notice Oracle prices for each market (price per underlying token, scaled by 1e18)
     * @dev For MVP: Prices are set manually. In production, use Chainlink/Uniswap oracles
     */
    mapping(address => uint256) public oraclePrices;

    /**
     * @notice Tracks which markets a user has entered for collateral
     * @dev accountMembership[user][cToken] = true if market is used as collateral
     */
    mapping(address => mapping(address => bool)) public accountMembership;

    /**
     * @notice List of all markets in the protocol
     */
    address[] public allMarkets;

    /**
     * @notice Maps market address to whether it exists
     */
    mapping(address => bool) public marketExists;

    /**
     * @notice Admin address (can set prices and add markets)
     */
    address public admin;

    event MarketEntered(address cToken, address account);
    event MarketExited(address cToken, address account);
    event MarketListed(address cToken);
    event PriceUpdated(address cToken, uint256 newPrice);

    constructor() {
        admin = msg.sender;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin");
        _;
    }

    /**
     * @notice Add a market to the protocol
     * @param cToken The CToken address to add
     */
    function supportMarket(address cToken) external onlyAdmin {
        require(!marketExists[cToken], "market already exists");

        marketExists[cToken] = true;
        allMarkets.push(cToken);

        emit MarketListed(cToken);
    }

    /**
     * @notice Set oracle price for a market
     * @param cToken The CToken address
     * @param price Price per underlying token (scaled by 1e18)
     * @dev Example: If 1 DAI = $1, set price = 1e18
     */
    function setPrice(address cToken, uint256 price) external onlyAdmin {
        require(marketExists[cToken], "market not listed");
        require(price > 0, "invalid price");

        oraclePrices[cToken] = price;

        emit PriceUpdated(cToken, price);
    }

    /**
     * @notice Enter markets to use as collateral
     * @param cTokens Array of CToken addresses to enter
     * @return Array of error codes (0 = success)
     */
    function enterMarkets(address[] calldata cTokens) external returns (uint256[] memory) {
        uint256[] memory results = new uint256[](cTokens.length);

        for (uint256 i = 0; i < cTokens.length; i++) {
            results[i] = _enterMarket(cTokens[i], msg.sender);
        }

        return results;
    }

    /**
     * @notice Internal function to enter a market
     * @param cToken The market to enter
     * @param borrower The account entering the market
     * @return 0 on success, error code otherwise
     */
    function _enterMarket(address cToken, address borrower) internal returns (uint256) {
        if (!marketExists[cToken]) {
            return 1; // Market not listed
        }

        if (accountMembership[borrower][cToken]) {
            return 0; // Already entered
        }

        accountMembership[borrower][cToken] = true;

        emit MarketEntered(cToken, borrower);

        return 0;
    }

    /**
     * @notice Exit a market (stop using as collateral)
     * @param cToken The market to exit
     * @return 0 on success, error code otherwise
     */
    function exitMarket(address cToken) external returns (uint256) {
        if (!accountMembership[msg.sender][cToken]) {
            return 0; // Not in market
        }

        // Check if user has outstanding borrows in this market
        (, , uint256 borrowBalance, ) = CToken(cToken).getAccountSnapshot(msg.sender);
        if (borrowBalance > 0) {
            return 1; // Cannot exit with outstanding borrows
        }

        // Check if removing collateral would make account insolvent
        // Calculate hypothetical liquidity if we remove this collateral
        (uint256 err, , uint256 shortfall) = getHypotheticalAccountLiquidity(
            msg.sender,
            cToken,
            type(uint256).max, // Hypothetically redeem all
            0
        );

        if (err != 0) {
            return err;
        }

        if (shortfall > 0) {
            return 2; // Insufficient liquidity to exit
        }

        accountMembership[msg.sender][cToken] = false;

        emit MarketExited(cToken, msg.sender);

        return 0;
    }

    /**
     * @notice Calculate account liquidity
     * @param account The account to check
     * @return error Error code (0 = success)
     * @return liquidity Excess collateral value (if positive)
     * @return shortfall Deficit value (if negative)
     */
    function getAccountLiquidity(address account)
        public
        view
        returns (
            uint256 error,
            uint256 liquidity,
            uint256 shortfall
        )
    {
        return getHypotheticalAccountLiquidity(account, address(0), 0, 0);
    }

    /**
     * @notice Calculate hypothetical account liquidity if user redeems/borrows
     * @param account The account to check
     * @param cTokenModify The market to hypothetically modify
     * @param redeemTokens Amount of cTokens to hypothetically redeem
     * @param borrowAmount Amount to hypothetically borrow
     * @return error Error code (0 = success)
     * @return liquidity Excess collateral value (if positive)
     * @return shortfall Deficit value (if negative)
     */
    function getHypotheticalAccountLiquidity(
        address account,
        address cTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    )
        public
        view
        returns (
            uint256 error,
            uint256 liquidity,
            uint256 shortfall
        )
    {
        uint256 sumCollateral = 0;
        uint256 sumBorrowPlusEffects = 0;

        // Loop through all markets
        for (uint256 i = 0; i < allMarkets.length; i++) {
            (uint256 err, uint256 collateralValue, uint256 borrowValue) = _getMarketValues(
                account,
                allMarkets[i],
                cTokenModify,
                redeemTokens,
                borrowAmount
            );

            if (err != 0) {
                return (err, 0, 0);
            }

            sumCollateral = add_(sumCollateral, collateralValue);
            sumBorrowPlusEffects = add_(sumBorrowPlusEffects, borrowValue);
        }

        // Calculate final liquidity or shortfall
        if (sumCollateral > sumBorrowPlusEffects) {
            return (0, sumCollateral - sumBorrowPlusEffects, 0);
        } else {
            return (0, 0, sumBorrowPlusEffects - sumCollateral);
        }
    }

    /**
     * @notice Internal helper to calculate collateral and borrow values for a single market
     * @dev Reduces stack depth in getHypotheticalAccountLiquidity
     */
    function _getMarketValues(
        address account,
        address cToken,
        address cTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    )
        internal
        view
        returns (
            uint256 error,
            uint256 collateralValue,
            uint256 borrowValue
        )
    {
        // Get user's balance in this market
        (uint256 err, uint256 cTokenBalance, uint256 borrowBalance, uint256 exchangeRateMantissa) =
            CToken(cToken).getAccountSnapshot(account);

        if (err != 0) {
            return (err, 0, 0);
        }

        // Get oracle price
        uint256 oraclePrice = oraclePrices[cToken];
        if (oraclePrice == 0) {
            return (3, 0, 0); // Price error
        }

        // Calculate underlying balance and apply hypothetical changes
        uint256 underlyingBalance = mul_ScalarTruncate(
            Exp({mantissa: exchangeRateMantissa}),
            cTokenBalance
        );

        if (cToken == cTokenModify) {
            uint256 redeemAmount = mul_ScalarTruncate(
                Exp({mantissa: exchangeRateMantissa}),
                redeemTokens
            );
            underlyingBalance = sub_(underlyingBalance, redeemAmount);
            borrowBalance = add_(borrowBalance, borrowAmount);
        }

        // Calculate collateral value if market is entered
        collateralValue = 0;
        if (accountMembership[account][cToken]) {
            collateralValue = mul_(underlyingBalance, oraclePrice) / 1e18;
            collateralValue = mul_(collateralValue, collateralFactorMantissa) / 1e18;
        }

        // Calculate borrow value
        borrowValue = mul_(borrowBalance, oraclePrice) / 1e18;

        return (0, collateralValue, borrowValue);
    }

    /**
     * @notice Check if a borrow is allowed
     * @param cToken The market to borrow from
     * @param borrower The account borrowing
     * @param borrowAmount The amount to borrow
     * @return true if allowed, false otherwise
     */
    function borrowAllowed(
        address cToken,
        address borrower,
        uint256 borrowAmount
    ) external view returns (bool) {
        // Check if market exists
        if (!marketExists[cToken]) {
            return false;
        }

        // Get oracle price
        uint256 price = oraclePrices[cToken];
        if (price == 0) {
            return false; // No price set
        }

        // Calculate borrow value
        uint256 borrowValue = mul_(borrowAmount, price) / 1e18;

        // Get account liquidity
        (uint256 err, uint256 liquidity, uint256 shortfall) = getHypotheticalAccountLiquidity(
            borrower,
            cToken,
            0,
            borrowAmount
        );

        if (err != 0) {
            return false;
        }

        // Must have no shortfall after borrow
        return shortfall == 0;
    }

    /**
     * @notice Check if account is underwater (eligible for liquidation)
     * @param account The account to check
     * @return true if underwater (shortfall > 0)
     */
    function isUnderwater(address account) external view returns (bool) {
        (, , uint256 shortfall) = getAccountLiquidity(account);
        return shortfall > 0;
    }

    /**
     * @notice Calculate how many collateral tokens to seize in liquidation
     * @param cTokenBorrowed The market where debt is being repaid
     * @param cTokenCollateral The market where collateral is being seized
     * @param repayAmount The amount being repaid
     * @return error Error code (0 = success)
     * @return seizeTokens Amount of cTokens to seize
     */
    function liquidateCalculateSeizeTokens(
        address cTokenBorrowed,
        address cTokenCollateral,
        uint256 repayAmount
    ) external view returns (uint256 error, uint256 seizeTokens) {
        // Get prices
        uint256 priceBorrowed = oraclePrices[cTokenBorrowed];
        uint256 priceCollateral = oraclePrices[cTokenCollateral];

        if (priceBorrowed == 0 || priceCollateral == 0) {
            return (1, 0); // Price error
        }

        // Get exchange rate of collateral
        uint256 exchangeRateMantissa = CToken(cTokenCollateral).exchangeRateStored();

        // Calculate seizeTokens
        // seizeTokens = (repayAmount * liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)

        uint256 numerator = mul_(repayAmount, liquidationIncentiveMantissa);
        numerator = mul_(numerator, priceBorrowed) / 1e18;

        uint256 denominator = mul_(priceCollateral, exchangeRateMantissa) / 1e18;

        seizeTokens = div_(numerator, denominator);

        return (0, seizeTokens);
    }

    /**
     * @notice Get all markets
     * @return Array of all CToken addresses
     */
    function getAllMarkets() external view returns (address[] memory) {
        return allMarkets;
    }

    /**
     * @notice Get price of underlying asset
     * @param cToken The CToken market
     * @return Price scaled by 1e18
     */
    function getPrice(address cToken) external view returns (uint256) {
        return oraclePrices[cToken];
    }
}
