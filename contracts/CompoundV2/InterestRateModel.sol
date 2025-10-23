// SPDX-License-Identifier: BSD-3-Clause
pragma solidity =0.7.6;

import "./interfaces/IInterestRateModel.sol";

/**
 * @title JumpRateModel
 * @notice Simple interest rate model with a kink (jump) at optimal utilization
 * @dev Based on Compound's JumpRateModelV2
 */
contract JumpRateModel is IInterestRateModel {
    uint256 public constant blocksPerYear = 2102400; // Assuming 15 second blocks

    /**
     * @notice The multiplier of utilization rate that gives the slope of the interest rate (scaled by 1e18)
     */
    uint256 public multiplierPerBlock;

    /**
     * @notice The base interest rate which is the y-intercept when utilization rate is 0 (scaled by 1e18)
     */
    uint256 public baseRatePerBlock;

    /**
     * @notice The multiplier after hitting a specified utilization point (scaled by 1e18)
     */
    uint256 public jumpMultiplierPerBlock;

    /**
     * @notice The utilization point at which the jump multiplier is applied (scaled by 1e18)
     */
    uint256 public kink;

    constructor(
        uint256 baseRatePerYear,
        uint256 multiplierPerYear,
        uint256 jumpMultiplierPerYear,
        uint256 kink_
    ) {
        baseRatePerBlock = baseRatePerYear / blocksPerYear;
        multiplierPerBlock = multiplierPerYear / blocksPerYear;
        jumpMultiplierPerBlock = jumpMultiplierPerYear / blocksPerYear;
        kink = kink_;
    }

    /**
     * @notice Calculates the utilization rate of the market: `borrows / (cash + borrows - reserves)`
     * @param cash The amount of cash in the market
     * @param borrows The amount of borrows in the market
     * @param reserves The amount of reserves in the market (currently unused)
     * @return The utilization rate as a mantissa between [0, 1e18]
     */
    function utilizationRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves
    ) public pure returns (uint256) {
        // utilization rate is 0 when there are no borrows
        if (borrows == 0) {
            return 0;
        }

        return (borrows * 1e18) / (cash + borrows - reserves);
    }

    /**
     * @notice Calculates the current borrow rate per block
     * @param cash The amount of cash in the market
     * @param borrows The amount of borrows in the market
     * @param reserves The amount of reserves in the market
     * @return The borrow rate percentage per block as a mantissa (scaled by 1e18)
     */
    function getBorrowRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves
    ) public view override returns (uint256) {
        uint256 util = utilizationRate(cash, borrows, reserves);

        if (util <= kink) {
            return ((util * multiplierPerBlock) / 1e18) + baseRatePerBlock;
        } else {
            uint256 normalRate = ((kink * multiplierPerBlock) / 1e18) +
                baseRatePerBlock;
            uint256 excessUtil = util - kink;
            return ((excessUtil * jumpMultiplierPerBlock) / 1e18) + normalRate;
        }
    }

    /**
     * @notice Calculates the current supply rate per block
     * @param cash The amount of cash in the market
     * @param borrows The amount of borrows in the market
     * @param reserves The amount of reserves in the market
     * @param reserveFactorMantissa The current reserve factor for the market
     * @return The supply rate percentage per block as a mantissa (scaled by 1e18)
     */
    function getSupplyRate(
        uint256 cash,
        uint256 borrows,
        uint256 reserves,
        uint256 reserveFactorMantissa
    ) public view override returns (uint256) {
        uint256 oneMinusReserveFactor = 1e18 - reserveFactorMantissa;
        uint256 borrowRate = getBorrowRate(cash, borrows, reserves);
        uint256 rateToPool = (borrowRate * oneMinusReserveFactor) / 1e18;
        return (utilizationRate(cash, borrows, reserves) * rateToPool) / 1e18;
    }
}
