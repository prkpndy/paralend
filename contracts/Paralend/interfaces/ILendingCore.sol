// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import "./ILendingRequestStore.sol";

/**
 * @title ILendingCore
 * @notice Interface for core lending operations with netting capabilities
 */
interface ILendingCore {
    /**
     * @notice Processes deposit and withdraw requests with netting
     * @param depositStore Store containing deposit requests
     * @param withdrawStore Store containing withdraw requests
     * @param market Address of the CToken market
     * @param netDeposit Net deposit amount after netting
     * @param netWithdraw Net withdraw amount after netting
     */
    function processSupplyOperations(
        ILendingRequestStore depositStore,
        ILendingRequestStore withdrawStore,
        address market,
        uint256 netDeposit,
        uint256 netWithdraw
    ) external;

    /**
     * @notice Processes borrow and repay requests with netting
     * @param borrowStore Store containing borrow requests
     * @param repayStore Store containing repay requests
     * @param market Address of the CToken market
     * @param netBorrow Net borrow amount after netting
     * @param netRepay Net repay amount after netting
     */
    function processBorrowOperations(
        ILendingRequestStore borrowStore,
        ILendingRequestStore repayStore,
        address market,
        uint256 netBorrow,
        uint256 netRepay
    ) external;

    /**
     * @notice Accrues interest for a market ONCE per block
     * @param market Address of the CToken market
     */
    function accrueInterestOnce(address market) external;
}
