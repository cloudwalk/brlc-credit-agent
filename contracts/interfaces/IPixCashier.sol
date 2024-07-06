// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @title IPixCashier interface
 * @author CloudWalk Inc. (See https://cloudwalk.io)
 * @dev Defines the needed functions of the PIX cashier contract.
 */
interface IPixCashier {
    /**
     * @dev Returns the account and amount of a single cash-out operation.
     * @param txId The off-chain transaction identifier of the operation.
     */
    function getCashOutAccountAndAmount(bytes32 txId) external view returns (address account, uint256 amount);
}
