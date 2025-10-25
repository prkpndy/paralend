// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import "@arcologynetwork/concurrentlib/lib/runtime/Runtime.sol";
import "@arcologynetwork/concurrentlib/lib/commutative/U256Cum.sol";
import "@arcologynetwork/concurrentlib/lib/multiprocess/Multiprocess.sol";
import "@arcologynetwork/concurrentlib/lib/orderedset/OrderedSet.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./LendingRequestStore.sol";
import "./SimplifiedComptroller.sol";
import "./interfaces/ILendingCore.sol";
import "./interfaces/ILendingRequestStore.sol";
import "../CompoundV2/CToken.sol";

/**
 * @title LendingEngine
 * @notice Parallel execution engine for lending operations with deposit/withdraw and borrow/repay netting
 * @dev Architecture mirrors NettingEngine from the swap protocol
 *
 * Key Innovation:
 * - Collects all lending operations in parallel (Phase 1)
 * - Calculates net flows per market (deposits-withdraws, borrows-repays)
 * - Accrues interest ONCE per market instead of per transaction
 * - Processes all operations in parallel using 20 threads (Phase 2)
 *
 * Example:
 * Phase 1: Collect
 *   - 100 users deposit 1000 ETH total
 *   - 60 users withdraw 400 ETH total
 *   - 50 users borrow 300 ETH total
 *   - 30 users repay 100 ETH total
 *
 * Phase 2: Process
 *   - Accrue interest ONCE
 *   - Net deposit = 1000 - 400 = 600 ETH (single state update)
 *   - Net borrow = 300 - 100 = 200 ETH (single state update)
 *   - Process 240 operations in parallel across 20 threads
 */
contract LendingEngine {
    using SafeERC20 for IERC20;

    // Address of core lending logic contract
    address private lendingCore;

    // Address of comptroller for liquidation checks
    SimplifiedComptroller public comptroller;

    /// @notice Event emitted after batch processing
    event BatchProcessed(
        address indexed market,
        uint256 deposits,
        uint256 withdraws,
        uint256 borrows,
        uint256 repays
    );

    // Multiprocessor with 20 threads for parallel market processing
    Multiprocess private mp = new Multiprocess(20);

    // Set of active markets in current batch
    BytesOrderedSet private activeMarkets = new BytesOrderedSet(false);

    // Deposit requests per market
    mapping(address => LendingRequestStore) private depositRequests;

    // Withdraw requests per market
    mapping(address => LendingRequestStore) private withdrawRequests;

    // Borrow requests per market
    mapping(address => LendingRequestStore) private borrowRequests;

    // Repay requests per market
    mapping(address => LendingRequestStore) private repayRequests;

    // Cumulative deposit totals per market
    mapping(address => U256Cumulative) private depositTotals;

    // Cumulative withdraw totals per market
    mapping(address => U256Cumulative) private withdrawTotals;

    // Cumulative borrow totals per market
    mapping(address => U256Cumulative) private borrowTotals;

    // Cumulative repay totals per market
    mapping(address => U256Cumulative) private repayTotals;

    // Liquidation requests per market pair (borrowMarket => collateralMarket => store)
    mapping(address => mapping(address => LendingRequestStore)) private liquidationRequests;

    // Cumulative liquidation repay totals per borrow market
    mapping(address => U256Cumulative) private liquidationRepayTotals;

    // Cumulative liquidation seize totals per collateral market
    mapping(address => U256Cumulative) private liquidationSeizeTotals;

    // TODO: Check if we can remove this or if we should add the function string in constant
    // Function signatures for deferred execution
    // bytes4 private constant DEPOSIT_SIGN =
    //     bytes4(keccak256("queueDeposit(address,uint256)"));
    // bytes4 private constant WITHDRAW_SIGN =
    //     bytes4(keccak256("queueWithdraw(address,uint256)"));
    // bytes4 private constant BORROW_SIGN =
    //     bytes4(keccak256("queueBorrow(address,uint256)"));
    // bytes4 private constant REPAY_SIGN =
    //     bytes4(keccak256("queueRepay(address,uint256)"));

    constructor() {
        // Register deferred execution for all operation types
        Runtime.defer("queueDeposit(address,uint256)", 300000);
        Runtime.defer("queueWithdraw(address,uint256)", 300000);
        Runtime.defer("queueBorrow(address,uint256)", 300000);
        Runtime.defer("queueRepay(address,uint256)", 300000);
        Runtime.defer("queueLiquidation(address,address,address,uint256)", 300000);
    }

    /**
     * @notice Initializes the lending core contract
     * @dev Deployment order:
     *      1. Deploy LendingEngine
     *      2. Deploy LendingCore(lendingEngineAddress)
     *      3. Call LendingEngine.init(lendingCoreAddress)
     *      4. For each CToken: call cToken.setLendingCore(lendingCoreAddress)
     */
    function init(address _lendingCore) external {
        require(lendingCore == address(0), "already initialized");
        require(_lendingCore != address(0), "invalid address");
        lendingCore = _lendingCore;
    }

    /**
     * @notice Sets the comptroller address
     * @param _comptroller Address of the SimplifiedComptroller
     */
    function setComptroller(address _comptroller) external {
        require(address(comptroller) == address(0), "comptroller already set");
        require(_comptroller != address(0), "invalid comptroller");
        comptroller = SimplifiedComptroller(_comptroller);
    }

    /**
     * @notice Registers a new market and initializes storage structures
     */
    function initMarket(address market) external {
        depositRequests[market] = new LendingRequestStore(false);
        withdrawRequests[market] = new LendingRequestStore(false);
        borrowRequests[market] = new LendingRequestStore(false);
        repayRequests[market] = new LendingRequestStore(false);

        depositTotals[market] = new U256Cumulative(0, type(uint256).max);
        withdrawTotals[market] = new U256Cumulative(0, type(uint256).max);
        borrowTotals[market] = new U256Cumulative(0, type(uint256).max);
        repayTotals[market] = new U256Cumulative(0, type(uint256).max);
    }

    /**
     * @notice Queues a deposit request for batch processing
     * @dev Phase 1: Collect requests in parallel, Phase 2: Process batch
     * @param market CToken market address
     * @param amount Deposit amount
     */
    function queueDeposit(
        address market,
        uint256 amount
    ) external returns (uint256) {
        bytes32 pid = abi.decode(Runtime.pid(), (bytes32));

        // Get underlying token and transfer from user to this contract
        address underlying = CToken(market).underlying();
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), amount);

        // Track active market
        activeMarkets.set(abi.encodePacked(market));

        // Store request
        depositRequests[market].push(pid, msg.sender, amount);

        // Accumulate total
        depositTotals[market].add(amount);

        // If in deferred phase, process all markets
        if (Runtime.isInDeferred()) {
            _processBatch();
        }

        return 0;
    }

    /**
     * @notice Queues a withdraw request for batch processing
     * @param market CToken market address
     * @param amount Withdraw amount (in cTokens)
     */
    function queueWithdraw(
        address market,
        uint256 amount
    ) external returns (uint256) {
        bytes32 pid = abi.decode(Runtime.pid(), (bytes32));

        activeMarkets.set(abi.encodePacked(market));
        withdrawRequests[market].push(pid, msg.sender, amount);
        withdrawTotals[market].add(amount);

        if (Runtime.isInDeferred()) {
            _processBatch();
        }

        return 0;
    }

    /**
     * @notice Queues a borrow request for batch processing
     * @param market CToken market address
     * @param amount Borrow amount
     */
    function queueBorrow(
        address market,
        uint256 amount
    ) external returns (uint256) {
        bytes32 pid = abi.decode(Runtime.pid(), (bytes32));

        activeMarkets.set(abi.encodePacked(market));
        borrowRequests[market].push(pid, msg.sender, amount);
        borrowTotals[market].add(amount);

        if (Runtime.isInDeferred()) {
            _processBatch();
        }

        return 0;
    }

    /**
     * @notice Queues a repay request for batch processing
     * @param market CToken market address
     * @param amount Repay amount
     */
    function queueRepay(
        address market,
        uint256 amount
    ) external returns (uint256) {
        bytes32 pid = abi.decode(Runtime.pid(), (bytes32));

        // Get underlying token and transfer from user to this contract
        address underlying = CToken(market).underlying();
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), amount);

        activeMarkets.set(abi.encodePacked(market));
        repayRequests[market].push(pid, msg.sender, amount);
        repayTotals[market].add(amount);

        if (Runtime.isInDeferred()) {
            _processBatch();
        }

        return 0;
    }

    /**
     * @notice Queues a liquidation request for batch processing
     * @dev Liquidator repays borrower's debt and receives collateral
     * @param borrower The underwater borrower to liquidate
     * @param cTokenBorrowed The market where debt is being repaid
     * @param cTokenCollateral The market where collateral is being seized
     * @param repayAmount Amount to repay (will be capped at close factor)
     */
    function queueLiquidation(
        address borrower,
        address cTokenBorrowed,
        address cTokenCollateral,
        uint256 repayAmount
    ) external returns (uint256) {
        bytes32 pid = abi.decode(Runtime.pid(), (bytes32));

        // Verify borrower is underwater using comptroller
        require(address(comptroller) != address(0), "comptroller not set");
        require(comptroller.isUnderwater(borrower), "borrower not underwater");

        // Get underlying token for borrowed market and transfer from liquidator
        address underlying = CToken(cTokenBorrowed).underlying();
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), repayAmount);

        // Initialize request store if needed
        if (address(liquidationRequests[cTokenBorrowed][cTokenCollateral]) == address(0)) {
            liquidationRequests[cTokenBorrowed][cTokenCollateral] = new LendingRequestStore(false);
        }

        // Initialize totals if needed
        if (address(liquidationRepayTotals[cTokenBorrowed]) == address(0)) {
            liquidationRepayTotals[cTokenBorrowed] = new U256Cumulative(0, type(uint256).max);
        }
        if (address(liquidationSeizeTotals[cTokenCollateral]) == address(0)) {
            liquidationSeizeTotals[cTokenCollateral] = new U256Cumulative(0, type(uint256).max);
        }

        // Track both markets as active
        activeMarkets.set(abi.encodePacked(cTokenBorrowed));
        activeMarkets.set(abi.encodePacked(cTokenCollateral));

        // Pack borrower address and repayAmount into single uint256
        // Upper 160 bits: borrower address, Lower 96 bits: repayAmount (truncated)
        uint256 packedData = (uint256(uint160(borrower)) << 96) | (repayAmount & ((1 << 96) - 1));

        // Store liquidation request (liquidator as user, packed data as amount)
        liquidationRequests[cTokenBorrowed][cTokenCollateral].push(pid, msg.sender, packedData);

        // Accumulate repay total
        liquidationRepayTotals[cTokenBorrowed].add(repayAmount);

        // Calculate and accumulate seize amount
        (uint256 err, uint256 seizeTokens) = comptroller.liquidateCalculateSeizeTokens(
            cTokenBorrowed,
            cTokenCollateral,
            repayAmount
        );
        require(err == 0, "seize calculation failed");
        liquidationSeizeTotals[cTokenCollateral].add(seizeTokens);

        // If in deferred phase, process all markets
        if (Runtime.isInDeferred()) {
            _processBatch();
        }

        return 0;
    }

    /**
     * @notice Processes all markets in parallel during deferred phase
     * @dev Creates one job per active market, runs on 20 parallel threads
     */
    function _processBatch() internal {
        uint256 length = activeMarkets.Length();

        for (uint256 idx = 0; idx < length; idx++) {
            mp.addJob(
                1000000000,
                0,
                address(this),
                abi.encodeWithSignature(
                    "processMarket(address)",
                    _parseAddr(activeMarkets.get(idx))
                )
            );
        }

        mp.run();
        activeMarkets.clear();
    }

    /**
     * @notice Processes all operations for a single market
     * @dev Called in parallel for each market
     * @param market CToken market address
     */
    function processMarket(address market) public {
        // Step 1: Accrue interest ONCE for this market
        ILendingCore(lendingCore).accrueInterestOnce(market);

        // Step 2: Get net amounts
        uint256 totalDeposits = depositTotals[market].get();
        uint256 totalWithdraws = withdrawTotals[market].get();
        uint256 totalBorrows = borrowTotals[market].get();
        uint256 totalRepays = repayTotals[market].get();

        // Step 3: Process supply operations (deposits/withdraws) with netting
        ILendingCore(lendingCore).processSupplyOperations(
            ILendingRequestStore(address(depositRequests[market])),
            ILendingRequestStore(address(withdrawRequests[market])),
            market,
            totalDeposits,
            totalWithdraws
        );

        // Step 4: Process borrow operations (borrows/repays) with netting
        ILendingCore(lendingCore).processBorrowOperations(
            ILendingRequestStore(address(borrowRequests[market])),
            ILendingRequestStore(address(repayRequests[market])),
            market,
            totalBorrows,
            totalRepays
        );

        emit BatchProcessed(
            market,
            totalDeposits,
            totalWithdraws,
            totalBorrows,
            totalRepays
        );

        // Step 5: Reset for next batch
        _resetMarket(market);
    }

    /**
     * @notice Resets all tracking for a market
     */
    function _resetMarket(address market) internal {
        depositRequests[market].clear();
        withdrawRequests[market].clear();
        borrowRequests[market].clear();
        repayRequests[market].clear();

        // Reset cumulative totals by creating new instances
        depositTotals[market] = new U256Cumulative(0, type(uint256).max);
        withdrawTotals[market] = new U256Cumulative(0, type(uint256).max);
        borrowTotals[market] = new U256Cumulative(0, type(uint256).max);
        repayTotals[market] = new U256Cumulative(0, type(uint256).max);
    }

    /**
     * @notice Converts encoded bytes to address
     */
    function _parseAddr(bytes memory rawdata) internal pure returns (address) {
        bytes20 resultAdr;
        for (uint256 i = 0; i < 20; i++) {
            resultAdr |= bytes20(rawdata[i]) >> (i * 8);
        }
        return address(uint160(resultAdr));
    }
}
