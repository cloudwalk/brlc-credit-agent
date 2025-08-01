// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/**
 * @title LendingMarketMock contract
 * @author CloudWalk Inc. (See https://www.cloudwalk.io)
 * @dev A simplified version of a lending market contract to use in tests for other contracts.
 */
contract LendingMarketMock {
    // ------------------ Constants ------------------------------- //

    /// @dev A constant value to return as a fake loan identifier.
    uint256 public constant LOAN_ID_STAB = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFDE;

    /// @dev A constant value to return as a fake installment loan count.
    uint256 public constant INSTALLMENT_COUNT_STAB = 12;

    // ------------------ Events ---------------------------------- //

    /// @dev Emitted when the `takeLoanFor()` function is called with the parameters of the function.
    event MockTakeLoanForCalled(
        address borrower, // Tools: prevent Prettier one-liner
        uint256 programId,
        uint256 borrowAmount,
        uint256 addonAmount,
        uint256 durationInPeriods
    );

    /// @dev Emitted when the `takeInstallmentLoanFor()` function is called with the parameters of the function.
    event MockTakeInstallmentLoanForCalled(
        address borrower, // Tools: prevent Prettier one-liner
        uint256 programId,
        uint256[] borrowAmounts,
        uint256[] addonAmounts,
        uint256[] durationsInPeriods
    );

    /// @dev Emitted when the `revokeLoan()` function is called with the parameters of the function.
    event MockRevokeLoanCalled(uint256 loanId);

    /// @dev Emitted when the `revokeInstallmentLoan()` function is called with the parameters of the function.
    event MockRevokeInstallmentLoanCalled(uint256 loanId);

    // ------------------ Transactional functions ----------------- //

    /**
     * @dev Imitates the same-name function of a lending market contract.
     *      Just emits an event about the call and returns a constant.
     */
    function takeLoanFor(
        address borrower, // Tools: prevent Prettier one-liner
        uint32 programId,
        uint256 borrowAmount,
        uint256 addonAmount,
        uint256 durationInPeriods
    ) external returns (uint256) {
        emit MockTakeLoanForCalled(
            borrower, // Tools: prevent Prettier one-liner
            programId,
            borrowAmount,
            addonAmount,
            durationInPeriods
        );
        return LOAN_ID_STAB;
    }

    /**
     * @dev Imitates the same-name function of a lending market contract.
     *      Just emits an event about the call and returns a constant.
     */
    function takeInstallmentLoanFor(
        address borrower, // Tools: prevent Prettier one-liner
        uint32 programId,
        uint256[] memory borrowAmounts,
        uint256[] memory addonAmounts,
        uint256[] memory durationsInPeriods
    ) external returns (uint256, uint256) {
        emit MockTakeInstallmentLoanForCalled(
            borrower, // Tools: prevent Prettier one-liner
            programId,
            borrowAmounts,
            addonAmounts,
            durationsInPeriods
        );
        return (LOAN_ID_STAB, INSTALLMENT_COUNT_STAB);
    }

    /// @dev Imitates the same-name function of a lending market contract. Just emits an event about the call.
    function revokeLoan(uint256 loanId) external {
        emit MockRevokeLoanCalled(loanId);
    }

    /// @dev Imitates the same-name function of a lending market contract. Just emits an event about the call.
    function revokeInstallmentLoan(uint256 loanId) external {
        emit MockRevokeInstallmentLoanCalled(loanId);
    }
}
