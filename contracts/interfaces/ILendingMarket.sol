// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @title ILendingMarket interface
 * @author CloudWalk Inc. (See https://cloudwalk.io)
 * @dev Defines the needed functions of the lending market contract.
 */
interface ILendingMarket {
    /**
     * @dev Takes a common loan for a provided account.
     * @param borrower The account for whom the loan is taken.
     * @param programId The identifier of the program to take the loan from.
     * @param borrowAmount The desired amount of tokens to borrow.
     * @param addonAmount The off-chain calculated addon amount for the loan.
     * @param durationInPeriods The desired duration of the loan in periods.
     * @return The unique identifier of the loan.
     */
    function takeLoanFor(
        address borrower,
        uint32 programId,
        uint256 borrowAmount,
        uint256 addonAmount,
        uint256 durationInPeriods
    ) external returns (uint256);

    /**
     * @dev Takes an installment loan with multiple sub-loans for a provided account.
     * @param borrower The account for whom the loan is taken.
     * @param programId The identifier of the program to take the loan from.
     * @param borrowAmounts The desired amounts of tokens to borrow for each installment.
     * @param addonAmounts The off-chain calculated addon amounts for each installment.
     * @param durationsInPeriods The desired duration of each installment in periods.
     * @return firstInstallmentId The unique identifier of the first sub-loan of the installment loan.
     * @return installmentCount The total number of installments.
     */
    function takeInstallmentLoanFor(
        address borrower,
        uint32 programId,
        uint256[] calldata borrowAmounts,
        uint256[] calldata addonAmounts,
        uint256[] calldata durationsInPeriods
    ) external returns (uint256 firstInstallmentId, uint256 installmentCount);

    /**
     * @dev Revokes a loan.
     * @param loanId The unique identifier of the loan to revoke.
     */
    function revokeLoan(uint256 loanId) external;

    /**
     * @dev Revokes an installment loan by revoking all of its sub-loans.
     * @param loanId The unique identifier of any sub-loan of the installment loan to revoke.
     */
    function revokeInstallmentLoan(uint256 loanId) external;
}
