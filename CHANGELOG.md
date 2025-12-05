# Main Changes

- Solc updated to 0.8.28 and evmVersion to cancun
- Storage location moved to ERC-7201: Namespaced Storage Layout slot calculation.
- CreditStatusChanged and InstallmentCreditStatusChanged are merged into one simplified CreditRequestStatusChanged

## Migration Steps

- Contract requires redeploy because storage layout changed.

# 1.3.0

old changelog
