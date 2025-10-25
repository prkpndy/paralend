// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

import "@arcologynetwork/concurrentlib/lib/core/Primitive.sol";
import "@arcologynetwork/concurrentlib/lib/core/Const.sol";

/**
 * @title LendingRequestStore
 * @notice Thread-safe storage for lending operation requests (deposit/withdraw/borrow/repay)
 * @dev Similar to SwapRequestStore but for lending operations
 */
contract LendingRequestStore is Base {
    struct LendingRequest {
        bytes32 txhash; // Transaction identifier
        address user; // User making the request
        uint256 amount; // Amount for the operation
    }

    constructor(bool isTransient) Base(Const.BYTES, isTransient) {}

    /**
     * @notice Stores a new lending request
     * @param txhash Transaction hash
     * @param user User address
     * @param amount Operation amount
     */
    function push(bytes32 txhash, address user, uint256 amount) public {
        LendingRequest memory request = LendingRequest({
            txhash: txhash,
            user: user,
            amount: amount
        });

        Base._set(uuid(), abi.encode(request));
    }

    /**
     * @notice Retrieves a lending request by index
     * @param idx Entry index
     * @return txhash Transaction hash
     * @return user User address
     * @return amount Operation amount
     */
    function get(
        uint256 idx
    ) public virtual returns (bytes32, address, uint256) {
        (, bytes memory data) = Base._get(idx);
        LendingRequest memory request = abi.decode(data, (LendingRequest));
        return (request.txhash, request.user, request.amount);
    }

    // Note: fullLength(), exists(uint256), and clear() are inherited from Base
    // and match the ILendingRequestStore interface requirements
}
