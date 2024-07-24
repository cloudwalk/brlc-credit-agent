// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @title ILendingMarket interface
 * @author CloudWalk Inc. (See https://cloudwalk.io)
 * @dev Defines the needed functions of the lending market contract.
 */
interface ILendingMarket {
    /**
     * @dev Takes a loan for a provided account. Can be called only by an account with a special role.
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
     * @dev Revokes a loan.
     * @param loanId The unique identifier of the loan to revoke.
     */
    function revokeLoan(uint256 loanId) external;
}
