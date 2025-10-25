// SPDX-License-Identifier: BSD-3-Clause
pragma solidity =0.7.6;

import "./interfaces/IInterestRateModel.sol";
import "./interfaces/IComptroller.sol";
import "./libraries/ExponentialNoError.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

/**
 * @title CToken
 * @notice Simplified Compound V2 CToken - lending market for a single asset
 * @dev This is the ORIGINAL implementation - will be refactored for parallel execution
 */
contract CToken is ExponentialNoError {
    using SafeERC20 for IERC20;

    string public name;
    string public symbol;
    uint8 public constant decimals = 8;

    /**
     * @notice Underlying asset for this CToken
     */
    address public underlying;

    /**
     * @notice Comptroller contract which oversees all markets
     */
    IComptroller public comptroller;

    /**
     * @notice Interest rate model
     */
    IInterestRateModel public interestRateModel;

    // Initial exchange rate used when minting the first CTokens (scaled by 1e18)
    uint256 internal constant initialExchangeRateMantissa = 2e26; // 0.02

    /**
     * @notice Fraction of interest currently set aside for reserves (scaled by 1e18)
     */
    uint256 public reserveFactorMantissa = 0.1e18; // 10%

    /**
     * @notice Block number that interest was last accrued at
     */
    uint256 public accrualBlockNumber;

    /**
     * @notice Accumulator of the total earned interest rate since the opening of the market (scaled by 1e18)
     */
    uint256 public borrowIndex = 1e18;

    /**
     * @notice Total amount of outstanding borrows of the underlying in this market
     */
    uint256 public totalBorrows;

    /**
     * @notice Total amount of reserves of the underlying held in this market
     */
    uint256 public totalReserves;

    /**
     * @notice Total number of tokens in circulation
     */
    uint256 public totalSupply;

    // Official record of token balances for each account
    mapping(address => uint256) internal accountTokens;

    /**
     * @notice Container for borrow balance information
     * @member principal Total balance (with accrued interest), after applying the most recent balance-changing action
     * @member interestIndex Global borrowIndex as of the most recent balance-changing action
     */
    struct BorrowSnapshot {
        uint256 principal;
        uint256 interestIndex;
    }

    mapping(address => BorrowSnapshot) internal accountBorrows;

    event Mint(address minter, uint256 mintAmount, uint256 mintTokens);
    event Redeem(address redeemer, uint256 redeemAmount, uint256 redeemTokens);
    event Borrow(
        address borrower,
        uint256 borrowAmount,
        uint256 accountBorrows,
        uint256 totalBorrows
    );
    event RepayBorrow(
        address payer,
        address borrower,
        uint256 repayAmount,
        uint256 accountBorrows,
        uint256 totalBorrows
    );
    event AccrueInterest(
        uint256 cashPrior,
        uint256 interestAccumulated,
        uint256 borrowIndex,
        uint256 totalBorrows
    );

    constructor(
        address underlying_,
        IComptroller comptroller_,
        IInterestRateModel interestRateModel_,
        string memory name_,
        string memory symbol_
    ) {
        underlying = underlying_;
        comptroller = comptroller_;
        interestRateModel = interestRateModel_;
        name = name_;
        symbol = symbol_;
        accrualBlockNumber = block.number;
    }

    /**
     * @notice Get the token balance of the `owner`
     * @param owner The address of the account to query
     * @return The number of tokens owned by `owner`
     */
    function balanceOf(address owner) external view returns (uint256) {
        return accountTokens[owner];
    }

    /**
     * @notice Get account snapshot for comptroller
     * @param account The account to get snapshot for
     * @return error Error code (0 = success)
     * @return cTokenBalance The cToken balance
     * @return borrowBalance The borrow balance (with accrued interest)
     * @return exchangeRateMantissa The current exchange rate
     */
    function getAccountSnapshot(address account)
        external
        view
        returns (
            uint256 error,
            uint256 cTokenBalance,
            uint256 borrowBalance,
            uint256 exchangeRateMantissa
        )
    {
        cTokenBalance = accountTokens[account];
        borrowBalance = borrowBalanceStored(account);
        exchangeRateMantissa = exchangeRateStored();

        return (0, cTokenBalance, borrowBalance, exchangeRateMantissa);
    }

    /**
     * @notice Get cash balance of this cToken in the underlying asset
     * @return The quantity of underlying asset owned by this contract
     */
    function getCash() public view returns (uint256) {
        return IERC20(underlying).balanceOf(address(this));
    }

    /**
     * @notice Applies accrued interest to total borrows and reserves
     * @dev This calculates interest accrued from the last checkpointed block
     *   up to the current block and writes new checkpoint to storage.
     */
    function accrueInterest() public returns (uint256) {
        uint256 currentBlockNumber = block.number;
        uint256 accrualBlockNumberPrior = accrualBlockNumber;

        if (accrualBlockNumberPrior == currentBlockNumber) {
            return 0;
        }

        uint256 cashPrior = getCash();
        uint256 borrowsPrior = totalBorrows;
        uint256 reservesPrior = totalReserves;
        uint256 borrowIndexPrior = borrowIndex;

        uint256 borrowRateMantissa = interestRateModel.getBorrowRate(
            cashPrior,
            borrowsPrior,
            reservesPrior
        );
        require(borrowRateMantissa <= 0.0005e18, "borrow rate too high"); // Max 0.05% per block

        uint256 blockDelta = currentBlockNumber - accrualBlockNumberPrior;

        // simpleInterestFactor = borrowRate * blockDelta
        Exp memory simpleInterestFactor = Exp({
            mantissa: mul_(borrowRateMantissa, blockDelta)
        });

        // interestAccumulated = simpleInterestFactor * borrowsPrior
        uint256 interestAccumulated = mul_ScalarTruncate(
            simpleInterestFactor,
            borrowsPrior
        );

        // totalBorrowsNew = interestAccumulated + borrowsPrior
        uint256 totalBorrowsNew = add_(interestAccumulated, borrowsPrior);

        // totalReservesNew = interestAccumulated * reserveFactor + reservesPrior
        uint256 totalReservesNew = mul_ScalarTruncateAddUInt(
            Exp({mantissa: reserveFactorMantissa}),
            interestAccumulated,
            reservesPrior
        );

        // borrowIndexNew = simpleInterestFactor * borrowIndexPrior + borrowIndexPrior
        uint256 borrowIndexNew = mul_ScalarTruncateAddUInt(
            simpleInterestFactor,
            borrowIndexPrior,
            borrowIndexPrior
        );

        accrualBlockNumber = currentBlockNumber;
        borrowIndex = borrowIndexNew;
        totalBorrows = totalBorrowsNew;
        totalReserves = totalReservesNew;

        emit AccrueInterest(
            cashPrior,
            interestAccumulated,
            borrowIndexNew,
            totalBorrowsNew
        );

        return 0;
    }

    /**
     * @notice Calculates the exchange rate from the underlying to the CToken
     * @return Calculated exchange rate scaled by 1e18
     */
    function exchangeRateStored() public view returns (uint256) {
        if (totalSupply == 0) {
            return initialExchangeRateMantissa;
        } else {
            uint256 totalCash = getCash();
            uint256 cashPlusBorrowsMinusReserves = sub_(
                add_(totalCash, totalBorrows),
                totalReserves
            );
            uint256 exchangeRate = (cashPlusBorrowsMinusReserves * expScale) /
                totalSupply;
            return exchangeRate;
        }
    }

    /**
     * @notice Return the borrow balance of account based on stored data
     * @param account The address whose balance should be calculated
     * @return The calculated balance
     */
    function borrowBalanceStored(
        address account
    ) public view returns (uint256) {
        BorrowSnapshot storage borrowSnapshot = accountBorrows[account];

        if (borrowSnapshot.principal == 0) {
            return 0;
        }

        uint256 principalTimesIndex = mul_(
            borrowSnapshot.principal,
            borrowIndex
        );
        uint256 result = principalTimesIndex / borrowSnapshot.interestIndex;
        return result;
    }

    /**
     * @notice Sender supplies assets into the market and receives cTokens in exchange
     * @param mintAmount The amount of the underlying asset to supply
     * @return uint 0=success, otherwise a failure
     */
    function mint(uint256 mintAmount) external returns (uint256) {
        accrueInterest();

        IERC20(underlying).safeTransferFrom(
            msg.sender,
            address(this),
            mintAmount
        );

        Exp memory exchangeRate = Exp({mantissa: exchangeRateStored()});
        uint256 mintTokens = div_(mintAmount, exchangeRate);

        totalSupply = add_(totalSupply, mintTokens);
        accountTokens[msg.sender] = add_(accountTokens[msg.sender], mintTokens);

        emit Mint(msg.sender, mintAmount, mintTokens);

        return 0;
    }

    /**
     * @notice Sender redeems cTokens in exchange for the underlying asset
     * @param redeemTokens The number of cTokens to redeem into underlying
     * @return uint 0=success, otherwise a failure
     */
    function redeem(uint256 redeemTokens) external returns (uint256) {
        accrueInterest();

        Exp memory exchangeRate = Exp({mantissa: exchangeRateStored()});
        uint256 redeemAmount = mul_ScalarTruncate(exchangeRate, redeemTokens);

        totalSupply = sub_(totalSupply, redeemTokens);
        accountTokens[msg.sender] = sub_(
            accountTokens[msg.sender],
            redeemTokens
        );

        IERC20(underlying).safeTransfer(msg.sender, redeemAmount);

        emit Redeem(msg.sender, redeemAmount, redeemTokens);

        return 0;
    }

    /**
     * @notice Sender borrows assets from the protocol
     * @param borrowAmount The amount of the underlying asset to borrow
     * @return uint 0=success, otherwise a failure
     */
    function borrow(uint256 borrowAmount) external returns (uint256) {
        accrueInterest();

        uint256 accountBorrowsPrev = borrowBalanceStored(msg.sender);
        uint256 accountBorrowsNew = add_(accountBorrowsPrev, borrowAmount);
        uint256 totalBorrowsNew = add_(totalBorrows, borrowAmount);

        accountBorrows[msg.sender].principal = accountBorrowsNew;
        accountBorrows[msg.sender].interestIndex = borrowIndex;
        totalBorrows = totalBorrowsNew;

        IERC20(underlying).safeTransfer(msg.sender, borrowAmount);

        emit Borrow(
            msg.sender,
            borrowAmount,
            accountBorrowsNew,
            totalBorrowsNew
        );

        return 0;
    }

    /**
     * @notice Sender repays their own borrow
     * @param repayAmount The amount to repay
     * @return uint 0=success, otherwise a failure
     */
    function repayBorrow(uint256 repayAmount) external returns (uint256) {
        accrueInterest();

        uint256 accountBorrowsPrev = borrowBalanceStored(msg.sender);

        if (repayAmount > accountBorrowsPrev) {
            repayAmount = accountBorrowsPrev;
        }

        IERC20(underlying).safeTransferFrom(
            msg.sender,
            address(this),
            repayAmount
        );

        uint256 accountBorrowsNew = sub_(accountBorrowsPrev, repayAmount);
        uint256 totalBorrowsNew = sub_(totalBorrows, repayAmount);

        accountBorrows[msg.sender].principal = accountBorrowsNew;
        accountBorrows[msg.sender].interestIndex = borrowIndex;
        totalBorrows = totalBorrowsNew;

        emit RepayBorrow(
            msg.sender,
            msg.sender,
            repayAmount,
            accountBorrowsNew,
            totalBorrowsNew
        );

        return 0;
    }

    // ============================================
    // PARALEND INTEGRATION - LENDING CORE ACCESS
    // ============================================

    /**
     * @notice Address of the LendingCore contract that can batch process operations
     */
    address public lendingCore;

    /**
     * @notice Sets the lending core address (can only be set once)
     * @param _lendingCore Address of the LendingCore contract
     */
    function setLendingCore(address _lendingCore) external {
        require(lendingCore == address(0), "lending core already set");
        require(_lendingCore != address(0), "invalid address");
        lendingCore = _lendingCore;
    }

    /**
     * @notice Mints cTokens to a user (called by LendingCore during batch processing)
     * @dev Skips interest accrual and checks - those are done by LendingCore
     * @param user Address to mint tokens to
     * @param mintTokens Amount of cTokens to mint
     */
    function mintFromLendingCore(address user, uint256 mintTokens) external {
        require(msg.sender == lendingCore, "unauthorized: only lending core");

        totalSupply = add_(totalSupply, mintTokens);
        accountTokens[user] = add_(accountTokens[user], mintTokens);

        emit Mint(user, 0, mintTokens); // amount=0 since already transferred
    }

    /**
     * @notice Redeems cTokens from a user (called by LendingCore during batch processing)
     * @dev Skips interest accrual and checks - those are done by LendingCore
     * @param user Address to redeem tokens from
     * @param redeemTokens Amount of cTokens to redeem
     * @return redeemAmount Amount of underlying returned
     */
    function redeemFromLendingCore(address user, uint256 redeemTokens) external returns (uint256) {
        require(msg.sender == lendingCore, "unauthorized: only lending core");

        Exp memory exchangeRate = Exp({mantissa: exchangeRateStored()});
        uint256 redeemAmount = mul_ScalarTruncate(exchangeRate, redeemTokens);

        totalSupply = sub_(totalSupply, redeemTokens);
        accountTokens[user] = sub_(accountTokens[user], redeemTokens);

        emit Redeem(user, redeemAmount, redeemTokens);

        return redeemAmount;
    }

    /**
     * @notice Records a borrow for a user (called by LendingCore during batch processing)
     * @dev Skips interest accrual and checks - those are done by LendingCore
     * @param user Address borrowing
     * @param borrowAmount Amount being borrowed
     */
    function borrowFromLendingCore(address user, uint256 borrowAmount) external {
        require(msg.sender == lendingCore, "unauthorized: only lending core");

        uint256 accountBorrowsPrev = borrowBalanceStored(user);
        uint256 accountBorrowsNew = add_(accountBorrowsPrev, borrowAmount);
        uint256 totalBorrowsNew = add_(totalBorrows, borrowAmount);

        accountBorrows[user].principal = accountBorrowsNew;
        accountBorrows[user].interestIndex = borrowIndex;
        totalBorrows = totalBorrowsNew;

        emit Borrow(user, borrowAmount, accountBorrowsNew, totalBorrowsNew);
    }

    /**
     * @notice Records a repayment for a user (called by LendingCore during batch processing)
     * @dev Skips interest accrual and checks - those are done by LendingCore
     * @param user Address repaying
     * @param repayAmount Amount being repaid
     */
    function repayFromLendingCore(address user, uint256 repayAmount) external {
        require(msg.sender == lendingCore, "unauthorized: only lending core");

        uint256 accountBorrowsPrev = borrowBalanceStored(user);

        // Cap repayAmount at user's actual borrow
        if (repayAmount > accountBorrowsPrev) {
            repayAmount = accountBorrowsPrev;
        }

        uint256 accountBorrowsNew = sub_(accountBorrowsPrev, repayAmount);
        uint256 totalBorrowsNew = sub_(totalBorrows, repayAmount);

        accountBorrows[user].principal = accountBorrowsNew;
        accountBorrows[user].interestIndex = borrowIndex;
        totalBorrows = totalBorrowsNew;

        emit RepayBorrow(address(0), user, repayAmount, accountBorrowsNew, totalBorrowsNew);
    }
}
