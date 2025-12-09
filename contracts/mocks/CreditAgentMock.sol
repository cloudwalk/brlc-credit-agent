// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import { CreditAgent } from "../CreditAgent.sol";

import { LendingMarketMock } from "./LendingMarketMock.sol";

/**
 * @title CreditAgentMock contract
 * @author CloudWalk Inc. (See https://www.cloudwalk.io)
 * @dev Wrapper contract for credit operations.
 *
 * This is simpleest version of the CreditAgent contract for testing purposes.
 * It does not have any specific lending market contract interactions and used to deploy abstract CreditAgent contract.
 *
 * @custom:oz-upgrades-unsafe-allow missing-initializer
 */
contract CreditAgentMock is CreditAgent {
    /// @dev close to the original implementation of verification mechanism for lending market contract.
    function _validateLendingMarket(address lendingMarket) internal view override returns (bool) {
        try LendingMarketMock(lendingMarket).proveLendingMarket() {
            return true;
        } catch {
            return false;
        }
    }

    function createCreditRequestWithFailedTakeLoan(bytes32 txId, address account) external {
        _createCreditRequest(
            txId,
            account,
            100,
            LendingMarketMock.failExecution.selector,
            LendingMarketMock.revokeLoan.selector,
            abi.encode(100)
        );
    }

    function createCreditRequestWithFailedRevokeLoan(bytes32 txId, address account) external {
        _createCreditRequest(
            txId,
            account,
            100,
            LendingMarketMock.takeLoanFor.selector,
            LendingMarketMock.failExecution.selector,
            abi.encode(account, uint32(100), 100, 100, 100)
        );
    }
}
