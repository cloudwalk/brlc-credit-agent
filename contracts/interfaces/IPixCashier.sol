// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @title IPixCashier interface
 * @author CloudWalk Inc. (See https://cloudwalk.io)
 * @dev Defines the needed functions of the PIX cashier contract.
 */
interface IPixCashier {
    /**
     * @dev Possible statuses of a cash-out operation as an enum.
     *
     * The possible values:
     * - Nonexistent - The operation does not exist (the default value).
     * - Pending ----- The status immediately after the operation requesting.
     * - Reversed ---- The operation was reversed.
     * - Confirmed --- The operation was confirmed.
     * - Internal ---- The operation executed internally
     */
    enum CashOutStatus {
        Nonexistent, // 0
        Pending,     // 1
        Reversed,    // 2
        Confirmed,   // 3
        Internal     // 4
    }

    /// @dev Structure with data of a single cash-out operation.
    struct CashOutOperation {
        CashOutStatus status;  // The status of the cash-out operation according to the {CashOutStatus} enum.
        address account;       // The owner of tokens to cash-out.
        uint64 amount;         // The amount of tokens to cash-out.
        uint8 flags;           // The bit field of flags for the operation. See {CashOutFlagIndex}.
        // uint16 __reserved;  // Reserved for future use until the end of the storage slot.
    }

    /**
     * @dev Returns the data of a single cash-out operation.
     * @param txId The off-chain transaction identifier of the operation.
     */
    function getCashOut(bytes32 txId) external view returns (CashOutOperation memory);
}
