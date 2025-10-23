// SPDX-License-Identifier: BSD-3-Clause
pragma solidity =0.7.6;

import "./ICToken.sol";

/**
 * @title IPriceOracle
 * @notice Interface for price oracles
 */
interface IPriceOracle {
    /**
     * @notice Get the underlying price of a cToken asset
     * @param cToken The cToken to get the underlying price of
     * @return The underlying asset price mantissa (scaled by 1e18)
     */
    function getUnderlyingPrice(ICToken cToken) external view returns (uint256);
}
