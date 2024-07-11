// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

/**
 * @title IPixCreditAgentTypes interface
 * @author CloudWalk Inc. (See https://cloudwalk.io)
 * @dev Defines the types used in the PIX credit agent contract.
 */
interface IPixCreditAgentTypes {
    /**
     * @dev The status of a PIX credit.
     *
     * The possible values:
     *
     * - Nonexistent - The credit does not exist. The default value.
     * - Initiated --- The credit is initiated by a manager, waiting for the related PIX cash-out operation request.
     * - Pending ----- The credit is pending due to the related PIX operation request, waiting for further actions.
     * - Confirmed --- The credit is confirmed as the related PIX operation was confirmed.
     * - Reversed ---- The credit is reversed as the related PIX operation was reversed.
     *
     * The possible status transitions are:
     *
     * - Nonexistent => Initiated (by a manager)
     * - Initiated => Pending (due to requesting the related PIX cash-out operation)
     * - Pending => Confirmed (due to confirming the related PIX cash-out operation)
     * - Pending => Reversed (due to reversing the related PIX cash-out operation)
     * - Reversed => Initiated (by a manager)
     *
     * Matching the state of the related loan on the lending market depending on the status:
     *
     * - Nonexistent: The loan does not exist.
     * - Initiated: The loan does not exist.
     * - Pending: The loan is taken but can be revoked.
     * - Confirmed: The loan is taken and cannot be revoked.
     * - Reversed: The loan is revoked.
     */
    enum PixCreditStatus {
        Nonexistent, // 0
        Initiated,   // 1
        Pending,     // 2
        Confirmed,   // 3
        Reversed     // 4
    }

    /// @dev The PIX credit structure.
    struct PixCredit {
        // Slot 1
        address borrower;         // The address of the borrower.
        uint32 programId;         // The unique identifier of a lending program for the credit.
        uint32 durationInPeriods; // The duration of the credit in periods. The period length is defined outside.
        PixCreditStatus status;   // The status of the credit, see {PixCreditStatus}.
        // uint24 __reserved;     // Reserved for future use until the end of the storage slot.

        // Slot 2
        uint64 loanAmount;        // The amount of the related loan.
        uint64 loanAddon;         // The addon amount (extra charges or fees) of the related loan.
        // uint128 __reserved;    // Reserved for future use until the end of the storage slot.

        // Slot 3
        uint256 loanId;            // The unique ID of the related loan on the lending market or zero if not taken.
    }

    /// @dev This agent contract state structure.
    struct AgentState {
        // Slot 1
        bool configured;               // True if the agent is properly configured.
        uint64 initiatedCreditCounter; // The counter of initiated credits.
        uint64 pendingCreditCounter;   // The counter of pending credits.
        // uint120 __reserved;         // Reserved for future use until the end of the storage slot.
    }
}

/**
 * @title IPixCreditAgentTypes interface
 * @author CloudWalk Inc. (See https://cloudwalk.io)
 * @dev Defines the custom errors used in the PIX credit agent contract.
 */
interface IPixCreditAgentErrors is IPixCreditAgentTypes {
    /// @dev The value of a configuration parameter is the same as previously set one.
    error PixCreditAgent_AlreadyConfigured();

    /// @dev The zero borrower address has been passed as a function argument.
    error PixCreditAgent_BorrowerAddressZero();

    /// @dev Configuring is prohibited due to at least one unprocessed PIX credit exists or other conditions.
    error PixCreditAgent_ConfiguringProhibited();

    /// @dev This agent contract is not configured yet.
    error PixCreditAgent_ContractNotConfigured();

    /// @dev The zero loan amount has been passed as a function argument.
    error PixCreditAgent_LoanAmountZero();

    /// @dev The zero loan duration has been passed as a function argument.
    error PixCreditAgent_LoanDurationZero();

    /// @dev The related PIX cash-out operation has inappropriate parameters (e.g. account, amount values).
    error PixCreditAgent_PixCashOutInappropriate(bytes32 pixTxId);

    /**
     * @dev The related PIX credit has inappropriate status to execute the requested operation.
     * @param pixTxId The PIX off-chain transaction identifiers of the operation.
     * @param status The current status of the credit.
     */
    error PixCreditAgent_PixCreditStatusInappropriate(bytes32 pixTxId, PixCreditStatus status);

    /// @dev The caller is not allowed to execute the hook function.
    error PixCreditAgent_PixHookCallerUnauthorized(address caller);

    /// @dev The the hook function is called with unexpected hook index.
    error PixCreditAgent_PixHookIndexUnexpected(uint256 hookIndex, bytes32 pixTxId, address caller);

    /// @dev The zero PIX off-chain transaction identifier has been passed as a function argument.
    error PixCreditAgent_PixTxIdZero();

    /// @dev The zero program ID has been passed as a function argument.
    error PixCreditAgent_ProgramIdZero();
}

/**
 * @title PixCreditAgent main interface
 * @author CloudWalk Inc. (See https://cloudwalk.io)
 * @dev The main part of the contract interface for PIX credit operations.
 */
interface IPixCreditAgentMain is IPixCreditAgentTypes {
    // ------------------ Events ---------------------------------- //

    /// @dev Emitted when the status of a PIX credit is changed.
    event PixCreditStatusChanged(
        bytes32 indexed pixTxId,   // The unique identifier of the related PIX cash-out operation.
        address indexed borrower,  // The address of the borrower.
        PixCreditStatus newStatus, // The current status of the credit.
        PixCreditStatus oldStatus, // The previous status of the credit.
        uint256 loanId,            // The unique ID of the related loan on the lending market or zero if not taken.
        uint256 programId,         // The unique identifier of the lending program for the credit.
        uint256 durationInPeriods, // The duration of the credit in periods.
        uint256 loanAmount,        // The amount of the related loan.
        uint256 loanAddon          // The addon amount of the related loan.
    );

    // ------------------ Functions ------------------------------- //

    /**
     * @dev Initiates a PIX credit.
     *
     * This function is expected to be called by a limited number of accounts.
     *
     * @param pixTxId The unique identifier of the related PIX cash-out operation.
     * @param borrower The address of the borrower.
     * @param programId The unique identifier of the lending program for the credit.
     * @param durationInPeriods The duration of the credit in periods. The period length is defined outside.
     * @param loanAmount The amount of the related loan.
     * @param loanAddon The addon amount (extra charges or fees) of the related loan.
     */
    function initiatePixCredit(
        bytes32 pixTxId, // Tools: this comment prevents Prettier from formatting into a single line.
        address borrower,
        uint256 programId,
        uint256 durationInPeriods,
        uint256 loanAmount,
        uint256 loanAddon
    ) external;

    /**
     * @dev Revokes a PIX credit.
     *
     * This function is expected to be called by a limited number of accounts.
     *
     * @param pixTxId The unique identifier of the related PIX cash-out operation.
     */
    function revokePixCredit(bytes32 pixTxId) external;

    /**
     * @dev Returns a PIX credit structure by its unique identifier.
     * @param pixTxId The unique identifier of the related PIX cash-out operation.
     * @return The PIX credit structure.
     */
    function getPixCredit(bytes32 pixTxId) external view returns (PixCredit memory);

    /**
     * @dev Returns the state of this agent contract.
     */
    function agentState() external view returns (AgentState memory);
}

/**
 * @title PixCreditAgent configuration interface
 * @author CloudWalk Inc. (See https://cloudwalk.io)
 * @dev The configuration part of the contract interface for PIX credit operations.
 */
interface IPixCreditAgentConfiguration is IPixCreditAgentTypes {
    // ------------------ Events ---------------------------------- //

    /// @dev Emitted when the configured PIX cashier contract address is changed.
    event PixCashierChanged(address newPixCashier, address oldPixCashier);

    /// @dev Emitted when the configured lending market contract address is changed.
    event LendingMarketChanged(address newLendingMarket, address oldLendingMarket);

    // ------------------ Functions ------------------------------- //

    /**
     * @dev Sets the address of the PIX cashier contract in this contract configuration.
     * @param newPixCashier The address of the new PIX cashier contract to set.
     */
    function setPixCashier(address newPixCashier) external;

    /**
     * @dev Sets the address of the lending market contract in this contract configuration.
     * @param newLendingMarket The address of the new lending market contract to set.
     */
    function setLendingMarket(address newLendingMarket) external;

    /**
     * @dev Returns the address of the currently configured PIX cashier contract.
     */
    function pixCashier() external view returns (address);

    /**
     * @dev Returns the address of the currently configured lending market contract.
     */
    function lendingMarket() external view returns (address);
}

/**
 * @title PixCreditAgent full interface
 * @author CloudWalk Inc. (See https://cloudwalk.io)
 * @dev The full interface of the contract for PIX credit operations.
 */
interface IPixCreditAgent is IPixCreditAgentErrors, IPixCreditAgentMain, IPixCreditAgentConfiguration {}
