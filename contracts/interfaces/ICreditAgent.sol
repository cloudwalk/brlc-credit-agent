// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

/**
 * @title ICreditAgentTypes interface
 * @author CloudWalk Inc. (See https://www.cloudwalk.io)
 * @dev Defines the types used in the credit abstract agent contract.
 */
interface ICreditAgentTypes {
    /**
     * @dev The status of a credit request.
     *
     * The possible values:
     *
     * - Nonexistent = 0 -- The credit request does not exist. The default value.
     * - Initiated = 1 ---- The credit request is initiated by a manager, waiting for the related cash-out operation request.
     * - Pending = 2 ------ The credit request is pending due to the related operation request, waiting for further actions.
     * - Confirmed = 3 ---- The credit request is confirmed as the related operation was confirmed.
     * - Reversed = 4 ----- The credit request is reversed as the related operation was reversed.
     *
     * The possible status transitions are:
     *
     * - Nonexistent => Initiated (by a manager)
     * - Initiated => Nonexistent (by a manager)
     * - Initiated => Pending (due to requesting the related cash-out operation)
     * - Pending => Confirmed (due to confirming the related cash-out operation)
     * - Pending => Reversed (due to reversing the related cash-out operation)
     * - Reversed => Initiated (by a manager)
     *
     * Matching the statuses with the states of the related loan on the lending market:
     *
     * - Nonexistent: The loan does not exist.
     * - Initiated: The loan does not exist.
     * - Pending: The loan is taken but can be revoked.
     * - Confirmed: The loan is taken and cannot be revoked.
     * - Reversed: The loan is revoked.
     */
    enum CreditRequestStatus {
        Nonexistent,
        Initiated,
        Pending,
        Confirmed,
        Reversed
    }

    /**
     * @dev The data of a single credit request.
     *
     * Fields:
     *
     * - status ------------- The status of the credit request, see {CreditRequestStatus}.
     * - account ------------ The account of the related cash-out operation.
     * - cashOutAmount ------ The amount of the related cash-out operation.
     * - revokeLoanSelector - The selector of the function in lending market contract to revoke the loan.
     *   It should accept the loan ID as a single argument.
     * - takeLoanSelector --- The selector of the function in lending market contract to take the loan.
     *   It may accept any arguments, because arguments are encoded in the {takeLoanData} field.
     * - takeLoanData ------- The arguments to call the {takeLoanSelector} function.
     * - loanId ------------- The unique ID of the related loan on the lending market or zero if not taken.
     */
    struct CreditRequest {
        // Slot 1
        CreditRequestStatus status;
        address account;
        uint64 cashOutAmount;
        bytes4 revokeLoanSelector;
        bytes4 takeLoanSelector;
        // uint16 __reserved; // Reserved until the end of the storage slot

        // Slot 3
        bytes takeLoanData;
        // uint24 __reserved; // Reserved until the end of the storage slot

        // Slot 2
        uint256 loanId; // maybe bytes32?
    }

    /**
     * @dev The state of this agent contract.
     *
     * Fields:
     *
     * - configured ------------------------- True if the agent is properly configured.
     * - initiatedCreditCounter ------------- The counter of initiated credit requests.
     * - pendingCreditCounter --------------- The counter of pending credit requests.
     */
    struct AgentState {
        // Slot 1
        bool configured;
        uint32 initiatedRequestCounter;
        uint32 pendingRequestCounter;
        // uint184 __reserved; // Reserved until the end of the storage slot
    }
}

/**
 * @title ICreditAgentPrimary interface
 * @author CloudWalk Inc. (See https://www.cloudwalk.io)
 * @dev The primary part of the credit agent contract interface.
 */
interface ICreditAgentPrimary is ICreditAgentTypes {
    // ------------------ Events ---------------------------------- //

    /**
     * @dev Emitted when the status of an installment credit is changed.
     * @param txId The unique identifier of the related cash-out operation.
     * @param account The account of the related cash-out operation.
     * @param newStatus The current status of the credit.
     * @param oldStatus The previous status of the credit.
     * @param totalBorrowAmount The total amount of all installments.
     */
    event CreditRequestStatusChanged(
        bytes32 indexed txId,
        address indexed account,
        CreditRequestStatus newStatus,
        CreditRequestStatus oldStatus,
        uint256 totalBorrowAmount
    );

    // ------------------ Functions ------------------------------- //

    /**
     * @dev Returns the state of this agent contract.
     */
    function agentState() external view returns (AgentState memory);
}

/**
 * @title ICreditAgentConfiguration interface
 * @author CloudWalk Inc. (See https://www.cloudwalk.io)
 * @dev The configuration part of the credit agent contract interface.
 */
interface ICreditAgentConfiguration is ICreditAgentTypes {
    // ------------------ Events ---------------------------------- //

    /**
     * @dev Emitted when the configured cashier contract address is changed.
     * @param newCashier The address of the new cashier contract.
     * @param oldCashier The address of the old cashier contract.
     */
    event CashierChanged(address newCashier, address oldCashier);

    /**
     * @dev Emitted when the configured lending market contract address is changed.
     * @param newLendingMarket The address of the new lending market contract.
     * @param oldLendingMarket The address of the old lending market contract.
     */
    event LendingMarketChanged(address newLendingMarket, address oldLendingMarket);

    // ------------------ Transactional functions ----------------- //

    /**
     * @dev Sets the address of the cashier contract in this contract configuration.
     * @param newCashier The address of the new cashier contract to set.
     */
    function setCashier(address newCashier) external;

    /**
     * @dev Sets the address of the lending market contract in this contract configuration.
     * @param newLendingMarket The address of the new lending market contract to set.
     */
    function setLendingMarket(address newLendingMarket) external;

    /**
     * @dev Returns the address of the currently configured cashier contract.
     */
    function cashier() external view returns (address);

    /**
     * @dev Returns the address of the currently configured lending market contract.
     */
    function lendingMarket() external view returns (address);
}

/**
 * @title ICreditAgentErrors interface
 * @author CloudWalk Inc. (See https://www.cloudwalk.io)
 * @dev Defines the custom errors used in the credit agent contract.
 */
interface ICreditAgentErrors is ICreditAgentTypes {
    /// @dev The value of a configuration parameter is the same as previously set one.
    error CreditAgent_AlreadyConfigured();

    /// @dev The zero borrower address has been passed as a function argument.
    error CreditAgent_AccountAddressZero();

    /// @dev Thrown if the provided new implementation address is not of a credit agent contract.
    error CreditAgent_ImplementationAddressInvalid();

    /**
     * @dev The caller is not allowed to execute the hook function.
     * @param caller The address of the caller.
     */
    error CreditAgent_CashierHookCallerUnauthorized(address caller);

    /**
     * @dev The the hook function is called with unexpected hook index.
     * @param hookIndex The index of the hook.
     * @param txId The off-chain transaction identifier of the operation.
     * @param caller The address of the caller.
     */
    error CreditAgent_CashierHookIndexUnexpected(uint256 hookIndex, bytes32 txId, address caller);

    /**
     * @dev The related cash-out operation has inappropriate parameters (e.g. account, amount values).
     * @param txId The off-chain transaction identifiers of the operation.
     */
    error CreditAgent_CashOutParametersInappropriate(bytes32 txId);

    /// @dev Configuring is prohibited due to at least one unprocessed credit exists or other conditions.
    error CreditAgent_ConfiguringProhibited();

    /// @dev This agent contract is not configured yet.
    error CreditAgent_ContractNotConfigured();

    /**
     * @dev The related credit has inappropriate status to execute the requested operation.
     * @param txId The off-chain transaction identifiers of the operation.
     * @param status The current status of the credit.
     */
    error CreditAgent_CreditRequestStatusInappropriate(bytes32 txId, CreditRequestStatus status);

    /// @dev The zero off-chain transaction identifier has been passed as a function argument.
    error CreditAgent_TxIdZero();

    /**
     * @dev The related cash-out operation has failed to be processed by the cashier hook.
     * @param txId The off-chain transaction identifier of the operation.
     */
    error CreditAgent_FailedToProcessCashOutRequestBefore(bytes32 txId);

    /**
     * @dev The related cash-out operation has failed to be processed by the cashier hook.
     * @param txId The off-chain transaction identifier of the operation.
     */
    error CreditAgent_FailedToProcessCashOutConfirmationAfter(bytes32 txId);

    /**
     * @dev The related cash-out operation has failed to be processed by the cashier hook.
     * @param txId The off-chain transaction identifier of the operation.
     */
    error CreditAgent_FailedToProcessCashOutReversalAfter(bytes32 txId);

    /**
     * @dev The provided lending market contract is not a contract.
     */
    error CreditAgent_LendingMarketNotContract();
}

/**
 * @title ICreditAgent interface
 * @author CloudWalk Inc. (See https://www.cloudwalk.io)
 * @dev The full interface of the credit agent contract.
 */
interface ICreditAgent is ICreditAgentPrimary, ICreditAgentConfiguration, ICreditAgentErrors {
    /**
     * @dev Proves that the contract is the credit agent contract.
     */
    function proveCreditAgent() external pure;
}
