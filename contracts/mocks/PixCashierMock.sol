// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { IPixHook } from "../interfaces/IPixHook.sol";
import { IPixHookableTypes } from "../interfaces/IPixHookable.sol";

/**
 * @title PixCashierMock contract
 * @author CloudWalk Inc. (See https://cloudwalk.io)
 * @dev A simplified version of the PixCashier contract to use in tests for other contracts.
 */
contract PixCashierMock is IPixHookableTypes {
    /// @dev A mock cash-out operation structure
    struct MockCashOutOperation {
        address account;
        uint256 amount;
    }

    /// @dev The mapping of a cash-out operation structure for a given off-chain transaction identifier.
    mapping(bytes32 => MockCashOutOperation) internal _mockCashOutOperations;

    /// @dev Emitted when the `configureCashOutHooks()` function is called with the parameters of the function.
    event MockConfigureCashOutHooksCalled(
        bytes32 txId, // Tools: This comment prevents Prettier from formatting into a single line.
        address newCallableContract,
        uint256 newHookFlags
    );

    /// @dev Imitates the same-name function of the {IPixHookable} interface. Just emits an event about the call.
    function configureCashOutHooks(bytes32 txId, address newCallableContract, uint256 newHookFlags) external {
        emit MockConfigureCashOutHooksCalled(
            txId, // Tools: This comment prevents Prettier from formatting into a single line.
            newCallableContract,
            newHookFlags
        );
    }

    /// @dev Calls the `IPixHook.pixHook()` function for a provided contract with provided parameters.
    function callPixHook(address callableContract, uint256 hookIndex, bytes32 txId) external {
        IPixHook(callableContract).pixHook(hookIndex, txId);
    }

    /// @dev Sets the account and amount fields of a single cash-out operation for a provided PIX transaction ID.
    function setCashOutAccountAndAmount(bytes32 txId, address account, uint256 amount) external {
        MockCashOutOperation storage cashOut = _mockCashOutOperations[txId];
        cashOut.account = account;
        cashOut.amount = amount;
    }

    /// @dev Returns the previously set account and amount of a single cash-out operation by a PIX transaction ID.
    function getCashOutAccountAndAmount(bytes32 txId) external view returns (address account, uint256 amount) {
        MockCashOutOperation storage cashOut = _mockCashOutOperations[txId];
        account = cashOut.account;
        amount = cashOut.amount;
    }
}
