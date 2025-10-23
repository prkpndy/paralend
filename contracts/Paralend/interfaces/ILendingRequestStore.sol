// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

/**
 * @title ILendingRequestStore
 * @notice Interface for request storage containers
 */
interface ILendingRequestStore {
    function push(bytes32 txhash, address user, uint256 amount) external;

    function get(uint256 idx) external returns (bytes32, address, uint256);

    function exists(uint256 idx) external returns (bool);

    function fullLength() external returns (uint256);

    function clear() external;
}
