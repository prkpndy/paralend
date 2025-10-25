// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import "./interfaces/ILendingRequestStore.sol";
import "./SimplifiedComptroller.sol";
import "../CompoundV2/CToken.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

/**
 * @title LendingCore
 * @notice Core lending operations with netting logic
 * @dev Processes batched requests and applies netting to minimize state updates
 *
 * Netting Examples:
 *
 * Supply Operations:
 * - 10 users deposit 1000 tokens total
 * - 5 users withdraw 400 tokens total
 * - Net: +600 tokens (single totalSupply update vs 15 updates)
 *
 * Borrow Operations:
 * - 8 users borrow 500 tokens total
 * - 4 users repay 200 tokens total
 * - Net: +300 borrows (single totalBorrows update vs 12 updates)
 */
contract LendingCore {
    using SafeERC20 for IERC20;

    /// @notice Address of the LendingEngine that queues operations
    address public lendingEngine;

    /// @notice Comptroller for collateral and liquidity checks
    SimplifiedComptroller public comptroller;

    event DepositProcessed(
        address indexed user,
        address indexed market,
        uint256 amount,
        uint256 mintedTokens
    );
    event WithdrawProcessed(
        address indexed user,
        address indexed market,
        uint256 amount,
        uint256 burnedTokens
    );
    event BorrowProcessed(
        address indexed user,
        address indexed market,
        uint256 amount
    );
    event RepayProcessed(
        address indexed user,
        address indexed market,
        uint256 amount
    );

    // Tracks which markets have accrued interest this block (prevents double accrual)
    mapping(address => uint256) private lastAccrualBlock;

    /**
     * @notice Constructor - sets the LendingEngine address
     * @param _lendingEngine Address of the LendingEngine contract
     */
    constructor(address _lendingEngine) {
        require(_lendingEngine != address(0), "invalid lending engine");
        lendingEngine = _lendingEngine;
    }

    /**
     * @notice Sets the comptroller address (can only be set once)
     * @param _comptroller Address of the SimplifiedComptroller
     */
    function setComptroller(address _comptroller) external {
        require(address(comptroller) == address(0), "comptroller already set");
        require(_comptroller != address(0), "invalid comptroller");
        comptroller = SimplifiedComptroller(_comptroller);
    }

    /**
     * @notice Accrues interest for a market ONCE per block
     * @dev Called before processing any operations for a market
     * @param market CToken market address
     */
    function accrueInterestOnce(address market) external {
        if (lastAccrualBlock[market] == block.number) {
            return; // Already accrued this block
        }

        CToken(market).accrueInterest();
        lastAccrualBlock[market] = block.number;
    }

    /**
     * @notice Processes deposit and withdraw operations with netting
     * @dev Applies net change to totalSupply, then processes individual requests
     * @param depositStore All deposit requests for this market
     * @param withdrawStore All withdraw requests for this market
     * @param market CToken market address
     * @param netDeposit Total deposit amount
     * @param netWithdraw Total withdraw amount
     */
    function processSupplyOperations(
        ILendingRequestStore depositStore,
        ILendingRequestStore withdrawStore,
        address market,
        // TODO: Check if netDeposit and netWithdraw arguments can be removed
        uint256 netDeposit,
        uint256 netWithdraw
    ) external {
        CToken cToken = CToken(market);

        // Process deposits
        if (address(depositStore) != address(0)) {
            uint256 depositCount = depositStore.fullLength();
            for (uint256 i = 0; i < depositCount; i++) {
                if (!depositStore.exists(i)) continue;

                (, address user, uint256 amount) = depositStore.get(i);
                _processDeposit(cToken, user, amount);
            }
        }

        // Process withdraws
        if (address(withdrawStore) != address(0)) {
            uint256 withdrawCount = withdrawStore.fullLength();
            for (uint256 i = 0; i < withdrawCount; i++) {
                if (!withdrawStore.exists(i)) continue;

                (, address user, uint256 amount) = withdrawStore.get(i);
                _processWithdraw(cToken, user, amount);
            }
        }
    }

    /**
     * @notice Processes borrow and repay operations with netting
     * @dev Applies net change to totalBorrows, then processes individual requests
     * @param borrowStore All borrow requests for this market
     * @param repayStore All repay requests for this market
     * @param market CToken market address
     * @param netBorrow Total borrow amount
     * @param netRepay Total repay amount
     */
    function processBorrowOperations(
        ILendingRequestStore borrowStore,
        ILendingRequestStore repayStore,
        address market,
        // TODO: Check if netBorrow and netWithdraw arguments can be removed
        uint256 netBorrow,
        uint256 netRepay
    ) external {
        CToken cToken = CToken(market);

        // Process borrows
        if (address(borrowStore) != address(0)) {
            uint256 borrowCount = borrowStore.fullLength();
            for (uint256 i = 0; i < borrowCount; i++) {
                if (!borrowStore.exists(i)) continue;

                (, address user, uint256 amount) = borrowStore.get(i);
                _processBorrow(cToken, user, amount);
            }
        }

        // Process repays
        if (address(repayStore) != address(0)) {
            uint256 repayCount = repayStore.fullLength();
            for (uint256 i = 0; i < repayCount; i++) {
                if (!repayStore.exists(i)) continue;

                (, address user, uint256 amount) = repayStore.get(i);
                _processRepay(cToken, user, amount);
            }
        }
    }

    /**
     * @notice Internal: processes a single deposit
     * @dev Transfers tokens from LendingEngine to CToken and mints cTokens
     */
    function _processDeposit(
        CToken cToken,
        address user,
        uint256 amount
    ) internal {
        // Transfer underlying from LendingEngine to CToken
        address underlying = cToken.underlying();
        IERC20(underlying).safeTransferFrom(lendingEngine, address(cToken), amount);

        // Calculate cTokens to mint using current exchange rate
        uint256 exchangeRate = cToken.exchangeRateStored();
        uint256 mintTokens = (amount * 1e18) / exchangeRate;

        // Call CToken to update state (mint cTokens to user)
        cToken.mintFromLendingCore(user, mintTokens);

        emit DepositProcessed(user, address(cToken), amount, mintTokens);
    }

    /**
     * @notice Internal: processes a single withdraw
     * @dev Burns cTokens and transfers underlying to user
     */
    function _processWithdraw(
        CToken cToken,
        address user,
        uint256 redeemTokens
    ) internal {
        // Call CToken to update state (burn cTokens) and get redeem amount
        uint256 redeemAmount = cToken.redeemFromLendingCore(user, redeemTokens);

        // Transfer underlying from CToken to user
        address underlying = cToken.underlying();
        IERC20(underlying).safeTransferFrom(address(cToken), user, redeemAmount);

        emit WithdrawProcessed(user, address(cToken), redeemAmount, redeemTokens);
    }

    /**
     * @notice Internal: processes a single borrow
     * @dev Updates user's borrow balance and transfers tokens
     */
    function _processBorrow(
        CToken cToken,
        address user,
        uint256 amount
    ) internal {
        // Check collateral using comptroller
        require(address(comptroller) != address(0), "comptroller not set");
        require(
            comptroller.borrowAllowed(address(cToken), user, amount),
            "insufficient collateral"
        );

        // Call CToken to update borrow state
        cToken.borrowFromLendingCore(user, amount);

        // Transfer underlying from CToken to user
        address underlying = cToken.underlying();
        IERC20(underlying).safeTransferFrom(address(cToken), user, amount);

        emit BorrowProcessed(user, address(cToken), amount);
    }

    /**
     * @notice Internal: processes a single repay
     * @dev Updates user's borrow balance and receives tokens
     */
    function _processRepay(
        CToken cToken,
        address user,
        uint256 amount
    ) internal {
        // Transfer underlying from LendingEngine to CToken
        address underlying = cToken.underlying();
        IERC20(underlying).safeTransferFrom(lendingEngine, address(cToken), amount);

        // Call CToken to update repay state (handles capping at user's borrow)
        cToken.repayFromLendingCore(user, amount);

        emit RepayProcessed(user, address(cToken), amount);
    }
}
