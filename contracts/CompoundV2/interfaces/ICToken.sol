// SPDX-License-Identifier: BSD-3-Clause
pragma solidity =0.7.6;

/**
 * @title ICToken
 * @notice Interface for Compound V2 CToken contracts
 */
interface ICToken {
    function mint(uint256 mintAmount) external returns (uint256);

    function redeem(uint256 redeemTokens) external returns (uint256);

    function borrow(uint256 borrowAmount) external returns (uint256);

    function repayBorrow(uint256 repayAmount) external returns (uint256);

    function liquidateBorrow(
        address borrower,
        uint256 repayAmount,
        ICToken cTokenCollateral
    ) external returns (uint256);

    function balanceOf(address owner) external view returns (uint256);

    function borrowBalanceCurrent(address account) external returns (uint256);

    function getAccountSnapshot(
        address account
    ) external view returns (uint256, uint256, uint256, uint256);

    function accrueInterest() external returns (uint256);

    function exchangeRateCurrent() external returns (uint256);

    function getCash() external view returns (uint256);

    function underlying() external view returns (address);
}
