# Main Changes

- Merged the `CreditStatusChanged` and `InstallmentCreditStatusChanged` events into a single simplified `CreditRequestStatusChanged` event.
- Removed the `CreditAgent_TxIdAlreadyUsed` error that was previously used to cross-check ID uniqueness across the two credit request types.
- Renamed the `CreditAgent_BorrowerAddressZero` error to `CreditAgent_AccountAddressZero`.
- Renamed the following errors to their `CreditAgentCapybaraV1_*` counterparts:
  - `CreditAgent_LoanAmountZero`
  - `CreditAgent_LoanDurationZero`
  - `CreditAgent_InputArraysInvalid`
  - `CreditAgent_ProgramIdZero`
- Added the `CreditAgent_LendingMarketNotContract` error to validate the lending market contract address.
- Fixed initialization from the `Reversed` state so that it emits the correct `CreditRequestStatusChanged.oldStatus = Reversed` value.
- Removed the `CreditAgent_FailedToProcessCashOutConfirmationAfter` error.
- Replaced the `CreditAgent_FailedToProcessCashOutRequestBefore` error with `CreditAgent_CallTakeLoanFailed`.
- Replaced the `CreditAgent_FailedToProcessCashOutReversalAfter` error with `CreditAgent_CallRevokeLoanFailed`.

## Technical changes

- Solc updated to 0.8.28 and evmVersion to cancun. IR compilation enabled.
- Storage location moved to ERC-7201: Namespaced Storage Layout slot calculation.

## Migration Steps

- Contract requires redeploy because storage layout changed.

# 1.3.0

old changelog
