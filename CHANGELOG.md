# Main Changes

- `CreditStatusChanged` and `InstallmentCreditStatusChanged` are merged into one simplified `CreditRequestStatusChanged`
- Removed `CreditAgent_TxIdAlreadyUsed` error that was previously used to crosscheck ids uniqness in 2 types of credit requests.
- `CreditAgent_BorrowerAddressZero` error renamed `CreditAgent_AccountAddressZero`
- Next errors renamed to `CreditAgentCapybaraV1_*`:
  - `CreditAgent_LoanAmountZero`
  - `CreditAgent_LoanDurationZero`
  - `CreditAgent_InputArraysInvalid`
  - `CreditAgent_ProgramIdZero`
- Added `CreditAgent_LendingMarketNotContract` error for validate lendingMarking contract.
- Initialize request from reversed state emits correct `CreditRequestStatusChanged.oldStatus` = `Reversed` value
- `CreditAgent_FailedToProcessCashOutConfirmationAfter` error removed
- `CreditAgent_FailedToProcessCashOutRequestBefore` error replaced by `CreditAgent_CallTakeLoanFailed`
- `CreditAgent_FailedToProcessCashOutReversalAfter` error replaced by `CreditAgent_CallRevokeLoanFailed`

## Technical changes

- Solc updated to 0.8.28 and evmVersion to cancun. IR compilation enabled.
- Storage location moved to ERC-7201: Namespaced Storage Layout slot calculation.

## Migration Steps

- Contract requires redeploy because storage layout changed.

# 1.3.0

old changelog
