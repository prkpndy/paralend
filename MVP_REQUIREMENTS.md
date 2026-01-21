# Paralend MVP Requirements Analysis

## Current Implementation Status

### ✅ What We Have (Complete)

**Architecture Layer:**
- ✅ LendingEngine.sol - Parallel batching orchestrator
- ✅ LendingCore.sol - Netting processor (skeleton)
- ✅ LendingRequestStore.sol - Thread-safe storage
- ✅ Two-phase execution pattern
- ✅ 20-thread multiprocessing
- ✅ Deferred execution registration
- ✅ Request collection and aggregation

**Compound V2 Base:**
- ✅ CToken.sol - Core lending market
- ✅ InterestRateModel.sol - Jump rate model
- ✅ ExponentialNoError.sol - Math library
- ✅ All interfaces defined

**What Works:**
- ✅ Parallel request collection
- ✅ Batch processing trigger
- ✅ Interest accrual once per market
- ✅ Basic event emission

---

## ❌ What's Missing for MVP

### Critical (Must Have for E2E Demo)

#### 1. **Actual CToken State Updates in LendingCore** 🔴

**Current Issue:**
```solidity
// LendingCore._processDeposit() - Line 166-175
function _processDeposit(CToken cToken, address user, uint256 amount) internal {
    address underlying = cToken.underlying();
    IERC20(underlying).safeTransferFrom(user, address(cToken), amount);

    uint256 exchangeRate = cToken.exchangeRateStored();
    uint256 mintTokens = (amount * 1e18) / exchangeRate;

    // ❌ MISSING: Actual minting logic!
    // Note: This is simplified - in production, need to handle internal accounting

    emit DepositProcessed(user, address(cToken), amount, mintTokens);
}
```

**What's Missing:**
- No actual cToken minting to user
- No totalSupply update
- No user balance update in CToken
- Just emits event and does nothing

**What Needs to Be Added:**
```solidity
function _processDeposit(CToken cToken, address user, uint256 amount) internal {
    // 1. Transfer already handled by LendingEngine (tokens in engine)
    // 2. Calculate mint tokens
    uint256 exchangeRate = cToken.exchangeRateStored();
    uint256 mintTokens = (amount * 1e18) / exchangeRate;

    // ✅ ADD: Update CToken state directly (we need special access)
    cToken.mintInternal(user, mintTokens, amount);
    // This should:
    //   - totalSupply += mintTokens
    //   - accountTokens[user] += mintTokens
    //   - Transfer underlying from LendingEngine to CToken
}
```

**Problem:** CToken doesn't have `mintInternal()` - we need to add it!

---

#### 2. **Token Flow Management** 🔴

**Current Issue:**
Tokens are transferred in the wrong places:

```solidity
// LendingEngine.queueDeposit() - Line 137
depositRequests[market].push(pid, msg.sender, amount);
depositTotals[market].add(amount);
// ❌ MISSING: Transfer tokens from user to LendingEngine!

// LendingCore._processDeposit() - Line 166
IERC20(underlying).safeTransferFrom(user, address(cToken), amount);
// ❌ WRONG: Tokens not in user's wallet at this point!
```

**Correct Flow Should Be:**
```
Phase 1 (queueDeposit):
  User → LendingEngine (transfer tokens immediately)

Phase 2 (_processDeposit):
  LendingEngine → CToken (batch transfer)
```

**What Needs to Be Added:**
```solidity
// In LendingEngine.queueDeposit()
function queueDeposit(address market, uint256 amount) external returns (uint256) {
    // ... existing code ...

    // ✅ ADD: Transfer tokens from user to this contract
    address underlying = CToken(market).underlying();
    IERC20(underlying).safeTransferFrom(msg.sender, address(this), amount);

    depositRequests[market].push(pid, msg.sender, amount);
    depositTotals[market].add(amount);
    // ...
}

// In LendingCore._processDeposit()
function _processDeposit(CToken cToken, address user, uint256 amount) internal {
    // ✅ CHANGE: Transfer from LendingEngine (not user)
    address underlying = cToken.underlying();
    IERC20(underlying).safeTransferFrom(
        lendingEngine,  // ← From engine
        address(cToken),
        amount
    );
    // ... mint logic ...
}
```

**Problem:** LendingCore doesn't know about LendingEngine address!

---

#### 3. **LendingCore Needs Access to CToken Internals** 🔴

**Current Issue:**
```solidity
// LendingCore can't call CToken internal functions
cToken.mintInternal(...)  // ❌ Doesn't exist
cToken.totalSupply += x   // ❌ Can't access private state
```

**Solutions (Pick One):**

**Option A: Add Special Functions to CToken** (Recommended)
```solidity
// In CToken.sol
function mintFromLendingCore(address user, uint256 mintTokens) external {
    require(msg.sender == lendingCore, "unauthorized");
    totalSupply = add_(totalSupply, mintTokens);
    accountTokens[user] = add_(accountTokens[user], mintTokens);
}

function redeemFromLendingCore(address user, uint256 redeemTokens) external {
    require(msg.sender == lendingCore, "unauthorized");
    totalSupply = sub_(totalSupply, redeemTokens);
    accountTokens[user] = sub_(accountTokens[user], redeemTokens);
}

function borrowFromLendingCore(address user, uint256 borrowAmount) external {
    require(msg.sender == lendingCore, "unauthorized");
    uint256 accountBorrowsPrev = borrowBalanceStored(user);
    uint256 accountBorrowsNew = add_(accountBorrowsPrev, borrowAmount);

    accountBorrows[user].principal = accountBorrowsNew;
    accountBorrows[user].interestIndex = borrowIndex;
    totalBorrows = add_(totalBorrows, borrowAmount);
}

function repayFromLendingCore(address user, uint256 repayAmount) external {
    require(msg.sender == lendingCore, "unauthorized");
    uint256 accountBorrowsPrev = borrowBalanceStored(user);
    uint256 accountBorrowsNew = sub_(accountBorrowsPrev, repayAmount);

    accountBorrows[user].principal = accountBorrowsNew;
    accountBorrows[user].interestIndex = borrowIndex;
    totalBorrows = sub_(totalBorrows, repayAmount);
}
```

**Option B: Make CToken Inherit from Base and Expose Internal Functions**
More complex, not recommended for MVP.

---

#### 4. **Comptroller for Collateral Checks** 🔴

**Current Issue:**
```solidity
// LendingCore._processBorrow() - Line 188-202
function _processBorrow(CToken cToken, address user, uint256 amount) internal {
    // Note: In production, need to:
    // 1. Check collateral ratio  ❌ MISSING!
    // 2. Update accountBorrows mapping
    // 3. Update totalBorrows
    // 4. Transfer tokens to user
}
```

**What's Missing:**
- No collateral check
- User can borrow without deposits
- No health factor calculation
- System is completely unsafe

**What Needs to Be Added:**

Create **SimplifiedComptroller.sol**:
```solidity
contract SimplifiedComptroller {
    // Collateral factor: 75% (user can borrow 75% of collateral value)
    uint256 public constant collateralFactorMantissa = 0.75e18;

    // Liquidation threshold: 80% (liquidated when debt > 80% of collateral)
    uint256 public constant liquidationThresholdMantissa = 0.80e18;

    // Maps user -> market -> whether market is used as collateral
    mapping(address => mapping(address => bool)) public accountMembership;

    // Price oracle (simplified - just use fixed prices for demo)
    mapping(address => uint256) public prices;

    function enterMarket(address cToken) external {
        accountMembership[msg.sender][cToken] = true;
    }

    function getAccountLiquidity(address user) public view returns (
        uint256 error,
        uint256 liquidity,
        uint256 shortfall
    ) {
        // Calculate total collateral value
        uint256 totalCollateral = 0;
        uint256 totalBorrows = 0;

        // Loop through all markets (hardcode for demo)
        // totalCollateral = sum(deposits * price * collateralFactor)
        // totalBorrows = sum(borrows * price)

        if (totalCollateral > totalBorrows) {
            liquidity = totalCollateral - totalBorrows;
            shortfall = 0;
        } else {
            liquidity = 0;
            shortfall = totalBorrows - totalCollateral;
        }

        return (0, liquidity, shortfall);
    }

    function borrowAllowed(
        address cToken,
        address borrower,
        uint256 borrowAmount
    ) external view returns (bool) {
        (uint256 err, uint256 liquidity, uint256 shortfall) =
            getAccountLiquidity(borrower);

        // Check if user has enough collateral
        // borrowAmount * price <= liquidity
        uint256 price = prices[cToken];
        uint256 borrowValue = (borrowAmount * price) / 1e18;

        return borrowValue <= liquidity;
    }
}
```

**Integration:**
```solidity
// In LendingCore._processBorrow()
function _processBorrow(CToken cToken, address user, uint256 amount) internal {
    // ✅ ADD: Check collateral
    require(
        comptroller.borrowAllowed(address(cToken), user, amount),
        "insufficient collateral"
    );

    // ... rest of borrow logic ...
}
```

---

#### 5. **Liquidation Engine** 🔴

**Current Status:**
- ❌ No liquidation implementation at all
- ❌ Interface defined but not implemented

**What Needs to Be Added:**

Create **LiquidationEngine.sol**:
```solidity
contract LiquidationEngine {
    address public lendingCore;
    address public comptroller;

    // Liquidation requests (collected in parallel)
    mapping(address => LiquidationRequestStore) public liquidationRequests;

    struct LiquidationRequest {
        address liquidator;
        address borrower;
        address cTokenBorrowed;
        address cTokenCollateral;
        uint256 repayAmount;
    }

    function queueLiquidation(
        address borrower,
        address cTokenBorrowed,
        address cTokenCollateral,
        uint256 repayAmount
    ) external {
        // Check if borrower is underwater
        (, , uint256 shortfall) = comptroller.getAccountLiquidity(borrower);
        require(shortfall > 0, "borrower not underwater");

        // Store liquidation request
        bytes32 pid = abi.decode(Runtime.pid(), (bytes32));
        liquidationRequests[cTokenBorrowed].push(
            pid,
            msg.sender,  // liquidator
            borrower,
            repayAmount
        );

        // In deferred phase, process liquidations
        if (Runtime.isInDeferred()) {
            _processLiquidations();
        }
    }

    function _processLiquidations() internal {
        // Sort by health factor (most underwater first)
        // Process all liquidations in parallel
        // Seize collateral and repay debt
    }
}
```

---

## 📋 Complete TODO List for MVP

### Priority 1: Make Basic Operations Work 🔴

#### TODO 1: Add CToken State Update Functions
**File:** `contracts/CompoundV2/CToken.sol`

**Add these functions:**
```solidity
address public lendingCore;

function setLendingCore(address _lendingCore) external {
    require(lendingCore == address(0), "already set");
    lendingCore = _lendingCore;
}

function mintFromLendingCore(address user, uint256 mintTokens) external {
    require(msg.sender == lendingCore, "unauthorized");
    totalSupply = add_(totalSupply, mintTokens);
    accountTokens[user] = add_(accountTokens[user], mintTokens);
}

function redeemFromLendingCore(address user, uint256 redeemTokens) external {
    require(msg.sender == lendingCore, "unauthorized");
    totalSupply = sub_(totalSupply, redeemTokens);
    accountTokens[user] = sub_(accountTokens[user], redeemTokens);
}

function borrowFromLendingCore(address user, uint256 borrowAmount) external {
    require(msg.sender == lendingCore, "unauthorized");
    uint256 accountBorrowsPrev = borrowBalanceStored(user);
    uint256 accountBorrowsNew = add_(accountBorrowsPrev, borrowAmount);
    accountBorrows[user].principal = accountBorrowsNew;
    accountBorrows[user].interestIndex = borrowIndex;
    totalBorrows = add_(totalBorrows, borrowAmount);
}

function repayFromLendingCore(address user, uint256 repayAmount) external {
    require(msg.sender == lendingCore, "unauthorized");
    uint256 accountBorrowsPrev = borrowBalanceStored(user);
    uint256 accountBorrowsNew = sub_(accountBorrowsPrev, repayAmount);
    accountBorrows[user].principal = accountBorrowsNew;
    accountBorrows[user].interestIndex = borrowIndex;
    totalBorrows = sub_(totalBorrows, repayAmount);
}
```

**Effort:** 30 minutes
**Lines:** ~50 LOC

---

#### TODO 2: Fix Token Transfers in LendingEngine
**File:** `contracts/Paralend/LendingEngine.sol`

**Changes needed:**
```solidity
// Line 127-136: In queueDeposit()
function queueDeposit(address market, uint256 amount) external returns (uint256) {
    bytes32 pid = abi.decode(Runtime.pid(), (bytes32));

    // ✅ ADD: Get underlying token
    address underlying = CToken(market).underlying();

    // ✅ ADD: Transfer tokens from user to this contract
    IERC20(underlying).safeTransferFrom(msg.sender, address(this), amount);

    activeMarkets.set(abi.encodePacked(market));
    depositRequests[market].push(pid, msg.sender, amount);
    depositTotals[market].add(amount);

    if (Runtime.isInDeferred()) {
        _processBatch();
    }
    return 0;
}

// Similar for queueBorrow, queueRepay
```

**Effort:** 1 hour
**Lines:** ~20 LOC

---

#### TODO 3: Update LendingCore to Call CToken Functions
**File:** `contracts/Paralend/LendingCore.sol`

**Changes needed:**
```solidity
// Line 158-176: In _processDeposit()
function _processDeposit(CToken cToken, address user, uint256 amount) internal {
    // Transfer underlying from LendingEngine to CToken
    address underlying = cToken.underlying();
    IERC20(underlying).safeTransferFrom(
        lendingEngine,  // ✅ ADD: Need to store this address
        address(cToken),
        amount
    );

    // Calculate mint tokens
    uint256 exchangeRate = cToken.exchangeRateStored();
    uint256 mintTokens = (amount * 1e18) / exchangeRate;

    // ✅ CHANGE: Call CToken function
    cToken.mintFromLendingCore(user, mintTokens);

    emit DepositProcessed(user, address(cToken), amount, mintTokens);
}

// Similar for withdraw, borrow, repay
```

**Effort:** 1 hour
**Lines:** ~40 LOC

---

#### TODO 4: Store LendingEngine Address in LendingCore
**File:** `contracts/Paralend/LendingCore.sol`

**Add:**
```solidity
address public lendingEngine;

constructor(address _lendingEngine) {
    lendingEngine = _lendingEngine;
}
```

**In LendingEngine.init():**
```solidity
function init(address _lendingCore) external {
    lendingCore = _lendingCore;
    // ✅ ADD: Pass this contract's address to LendingCore
}
```

**Effort:** 15 minutes
**Lines:** ~10 LOC

---

### Priority 2: Add Collateral System 🟡

#### TODO 5: Create SimplifiedComptroller
**File:** `contracts/Paralend/SimplifiedComptroller.sol` (NEW)

Create a minimal comptroller that:
- Tracks user deposits across markets
- Calculates collateral value (deposit * collateralFactor)
- Checks if borrow is allowed
- Calculates health factor for liquidations

**Effort:** 2-3 hours
**Lines:** ~150 LOC

See detailed implementation in section 4 above.

---

#### TODO 6: Integrate Comptroller into LendingCore
**File:** `contracts/Paralend/LendingCore.sol`

**Add:**
```solidity
SimplifiedComptroller public comptroller;

function setComptroller(address _comptroller) external {
    comptroller = SimplifiedComptroller(_comptroller);
}

function _processBorrow(CToken cToken, address user, uint256 amount) internal {
    // ✅ ADD: Check collateral
    require(
        comptroller.borrowAllowed(address(cToken), user, amount),
        "insufficient collateral"
    );

    // ... existing borrow logic ...
}
```

**Effort:** 30 minutes
**Lines:** ~20 LOC

---

### Priority 3: Add Liquidations 🟡

#### TODO 7: Create LiquidationEngine
**File:** `contracts/Paralend/LiquidationEngine.sol` (NEW)

Minimal liquidation engine:
- Collect liquidation requests in parallel
- Check if borrower is underwater
- Process liquidations in deferred phase
- Seize collateral, repay debt

**Effort:** 3-4 hours
**Lines:** ~200 LOC

See detailed implementation in section 5 above.

---

#### TODO 8: Add Liquidation Function to CToken
**File:** `contracts/CompoundV2/CToken.sol`

**Add:**
```solidity
function liquidateFromLendingCore(
    address liquidator,
    address borrower,
    uint256 repayAmount,
    CToken cTokenCollateral
) external {
    require(msg.sender == lendingCore, "unauthorized");

    // Repay borrower's debt
    uint256 accountBorrowsPrev = borrowBalanceStored(borrower);
    uint256 accountBorrowsNew = sub_(accountBorrowsPrev, repayAmount);
    accountBorrows[borrower].principal = accountBorrowsNew;
    accountBorrows[borrower].interestIndex = borrowIndex;
    totalBorrows = sub_(totalBorrows, repayAmount);

    // Calculate collateral to seize (repayAmount * 1.08 / exchangeRate)
    uint256 seizeTokens = comptroller.liquidateCalculateSeizeTokens(
        address(this),
        address(cTokenCollateral),
        repayAmount
    );

    // Transfer collateral from borrower to liquidator
    cTokenCollateral.seizeFromLendingCore(liquidator, borrower, seizeTokens);
}
```

**Effort:** 1 hour
**Lines:** ~30 LOC

---

### Priority 4: Testing & Integration 🟢

#### TODO 9: Update Test File
**File:** `test/test-paralend.js`

Add actual e2e tests:
```javascript
it("Should handle complete lending flow", async function() {
    // 1. User1 deposits 1000 DAI
    await dai.mint(user1.address, parseEther("1000"));
    await dai.connect(user1).approve(lendingEngine.address, parseEther("1000"));
    await lendingEngine.connect(user1).queueDeposit(daiMarket.address, parseEther("1000"));

    // 2. User1 enters market (collateral)
    await comptroller.connect(user1).enterMarket(daiMarket.address);

    // 3. User1 borrows 500 DAI
    await lendingEngine.connect(user1).queueBorrow(daiMarket.address, parseEther("500"));

    // 4. Check balances
    expect(await daiMarket.balanceOf(user1.address)).to.be.gt(0);
    expect(await daiMarket.borrowBalanceStored(user1.address)).to.equal(parseEther("500"));

    // 5. User1 repays 100 DAI
    await lendingEngine.connect(user1).queueRepay(daiMarket.address, parseEther("100"));

    // 6. User2 liquidates User1 if underwater
    // ...
});
```

**Effort:** 2-3 hours
**Lines:** ~200 LOC

---

## 📊 Summary: MVP Checklist

| Priority | Task | File | Status | Effort | Critical? |
|----------|------|------|--------|--------|-----------|
| 🔴 P1 | Add CToken state update functions | CToken.sol | ❌ TODO | 30 min | ✅ YES |
| 🔴 P1 | Fix token transfers in LendingEngine | LendingEngine.sol | ❌ TODO | 1 hour | ✅ YES |
| 🔴 P1 | Update LendingCore to call CToken | LendingCore.sol | ❌ TODO | 1 hour | ✅ YES |
| 🔴 P1 | Store LendingEngine address | LendingCore.sol | ❌ TODO | 15 min | ✅ YES |
| 🟡 P2 | Create SimplifiedComptroller | NEW FILE | ❌ TODO | 2-3 hours | ⚠️ For Borrow |
| 🟡 P2 | Integrate Comptroller | LendingCore.sol | ❌ TODO | 30 min | ⚠️ For Borrow |
| 🟡 P3 | Create LiquidationEngine | NEW FILE | ❌ TODO | 3-4 hours | ⚠️ For Liquidation |
| 🟡 P3 | Add liquidation to CToken | CToken.sol | ❌ TODO | 1 hour | ⚠️ For Liquidation |
| 🟢 P4 | Write e2e tests | test/ | ❌ TODO | 2-3 hours | Nice to have |

**Total Effort for Minimal MVP (Deposit + Withdraw only):** ~3 hours
**Total Effort for Full MVP (+ Borrow + Repay):** ~6-7 hours
**Total Effort for Complete MVP (+ Liquidation):** ~11-13 hours

---

## 🎯 Recommended Implementation Order

### Phase 1: Make Deposits Work (3 hours)
1. TODO 1: Add CToken state update functions
2. TODO 2: Fix token transfers
3. TODO 3: Update LendingCore
4. TODO 4: Store engine address
5. Test: deposit + withdraw only

### Phase 2: Add Borrowing (3-4 hours)
6. TODO 5: Create SimplifiedComptroller
7. TODO 6: Integrate Comptroller
8. Test: deposit + borrow + repay

### Phase 3: Add Liquidations (4-5 hours)
9. TODO 7: Create LiquidationEngine
10. TODO 8: Add liquidation to CToken
11. Test: full liquidation flow

### Phase 4: Polish (2-3 hours)
12. TODO 9: Complete e2e tests
13. Add net amount optimization (use the netDeposit/netWithdraw params)
14. Documentation updates

---

## 🚀 Quick Start (MVP Phase 1)

To get a working demo ASAP, implement **only Priority 1 tasks**:

```bash
# 1. Add functions to CToken.sol (30 min)
# 2. Fix LendingEngine.sol token transfers (1 hour)
# 3. Update LendingCore.sol to call CToken (1 hour)
# 4. Store addresses properly (15 min)

# Result: Working deposit + withdraw demo in ~3 hours!
```

This gives you a functional parallel lending protocol that demonstrates:
✅ Parallel deposit collection
✅ Batch processing
✅ Single interest accrual
✅ Netting architecture (even if not fully optimized yet)

Then iterate to add borrowing, collateral checks, and liquidations.
