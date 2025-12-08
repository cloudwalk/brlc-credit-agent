// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import { ICreditAgentTypes } from "./ICreditAgent.sol";

/**
 * @title ICreditAgentCapybaraV1Types interface
 * @author CloudWalk Inc. (See https://www.cloudwalk.io)
 * @dev Defines the types used in the credit agent for capybara v1 contract.
 */
interface ICreditAgentCapybaraV1Types {
    /**
     * @dev The view of a single credit.
     *
     * Fields:
     *
     * - status ------------- The status of the credit, see {CreditRequestStatus}.
     * - borrower ----------- The address of the borrower.
     * - programId ---------- The unique identifier of a lending program for the credit.
     * - durationInPeriods -- The duration of the credit in periods.
     * - loanAmount --------- The amount of the related loan.
     * - loanAddon ---------- The addon amount (extra charges or fees) of the related loan.
     * - loanId ------------- The unique ID of the related loan on the lending market or zero if not taken.
     */
    struct Credit {
        ICreditAgentTypes.CreditRequestStatus status;
        address borrower;
        uint256 programId;
        uint256 durationInPeriods;
        uint256 loanAmount;
        uint256 loanAddon;
        uint256 loanId;
    }

    /**
     * @dev The view of a single installment credit.
     *
     * Fields:
     *
     * - status -------------- The status of the credit, see {CreditRequestStatus}.
     * - borrower ------------ The address of the borrower.
     * - programId ----------- The unique identifier of a lending program for the credit.
     * - durationsInPeriods -- The duration of each installment in periods.
     * - borrowAmounts ------- The amounts of each installment.
     * - addonAmounts -------- The addon amounts of each installment.
     * - firstInstallmentId -- The unique ID of the related first installment loan on the market or zero if not taken.
     */
    struct InstallmentCredit {
        ICreditAgentTypes.CreditRequestStatus status;
        address borrower;
        uint256 programId;
        uint256[] durationsInPeriods;
        uint256[] borrowAmounts;
        uint256[] addonAmounts;
        uint256 firstInstallmentId;
    }
}

/**
 * @title ICreditAgentCapybaraV1Primary interface
 * @author CloudWalk Inc. (See https://www.cloudwalk.io)
 * @dev The primary part of the credit agent for capybara v1 contract interface.
 */
interface ICreditAgentCapybaraV1Primary is ICreditAgentCapybaraV1Types {
    // ------------------ Functions ------------------------------- //

    /**
     * @dev Initiates a credit.
     *
     * This function is expected to be called by a limited number of accounts.
     *
     * @param txId The unique identifier of the related cash-out operation.
     * @param borrower The address of the borrower.
     * @param programId The unique identifier of the lending program for the credit.
     * @param durationInPeriods The duration of the credit in periods. The period length is defined outside.
     * @param loanAmount The amount of the related loan.
     * @param loanAddon The addon amount (extra charges or fees) of the related loan.
     */
    function initiateCredit(
        bytes32 txId, // Tools: prevent Prettier one-liner
        address borrower,
        uint256 programId,
        uint256 durationInPeriods,
        uint256 loanAmount,
        uint256 loanAddon
    ) external;

    /**
     * @dev Initiates an installment credit.
     *
     * This function is expected to be called by a limited number of accounts.
     *
     * @param txId The unique identifier of the related cash-out operation.
     * @param borrower The address of the borrower.
     * @param programId The unique identifier of the lending program for the credit.
     * @param durationsInPeriods The duration of each installment in periods.
     * @param borrowAmounts The amounts of each installment.
     * @param addonAmounts The addon amounts of each installment.
     */
    function initiateInstallmentCredit(
        bytes32 txId,
        address borrower,
        uint256 programId,
        uint256[] calldata durationsInPeriods,
        uint256[] calldata borrowAmounts,
        uint256[] calldata addonAmounts
    ) external;

    /**
     * @dev Revokes a credit.
     *
     * This function is expected to be called by a limited number of accounts.
     *
     * @param txId The unique identifier of the related cash-out operation.
     */
    function revokeCredit(bytes32 txId) external;

    /**
     * @dev Revokes an installment credit.
     *
     * This function is expected to be called by a limited number of accounts.
     *
     * @param txId The unique identifier of the related cash-out operation.
     */
    function revokeInstallmentCredit(bytes32 txId) external;

    /**
     * @dev Returns a credit structure by its unique identifier.
     * @param txId The unique identifier of the related cash-out operation.
     * @return The credit structure.
     */
    function getCredit(bytes32 txId) external view returns (Credit memory);

    /**
     * @dev Returns an installment credit structure by its unique identifier.
     * @param txId The unique identifier of the related cash-out operation.
     * @return The installment credit structure.
     */
    function getInstallmentCredit(bytes32 txId) external view returns (InstallmentCredit memory);
}

/**
 * @title ICreditAgentCapybaraV1Errors interface
 * @author CloudWalk Inc. (See https://www.cloudwalk.io)
 * @dev Defines the custom errors used in the credit agent for capybara v1 contract.
 */
interface ICreditAgentCapybaraV1Errors {
    /// @dev The lending market contract is not compatible with the capybara v1 interface.
    error CreditAgentCapybaraV1_LendingMarketIncompatible();

    /// @dev The zero loan amount has been passed as a function argument.
    error CreditAgentCapybaraV1_LoanAmountZero();

    /// @dev The zero loan duration has been passed as a function argument.
    error CreditAgentCapybaraV1_LoanDurationZero();

    /// @dev The input arrays are empty or have different lengths.
    error CreditAgentCapybaraV1_InputArraysInvalid();

    /// @dev The zero program ID has been passed as a function argument.
    error CreditAgentCapybaraV1_ProgramIdZero();
}

/**
 * @title ICreditAgent interface
 * @author CloudWalk Inc. (See https://www.cloudwalk.io)
 * @dev The full interface of the credit agent for capybara v1 contract.
 */
interface ICreditAgentCapybaraV1 is ICreditAgentCapybaraV1Primary, ICreditAgentCapybaraV1Errors {}
