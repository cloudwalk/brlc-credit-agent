// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { IPixHook } from "../interfaces/ICashierHook.sol";
import { IPixHookableTypes } from "../interfaces/ICashierHookable.sol";
import { IPixCashier } from "../interfaces/ICashier.sol";

/**
 * @title PixCashierMock contract
 * @author CloudWalk Inc. (See https://cloudwalk.io)
 * @dev A simplified version of the PixCashier contract to use in tests for other contracts.
 */
contract PixCashierMock is IPixHookableTypes, IPixCashier {
    /// @dev The mapping of a cash-out operation structure for a given off-chain transaction identifier.
    mapping(bytes32 => CashOutOperation) internal _mockCashOutOperations;

    /// @dev Emitted when the `configureCashOutHooks()` function is called with the parameters of the function.
    event MockConfigureCashOutHooksCalled(
        bytes32 txId, // Tools: this comment prevents Prettier from formatting into a single line.
        address newCallableContract,
        uint256 newHookFlags
    );

    /// @dev Imitates the same-name function of the {IPixHookable} interface. Just emits an event about the call.
    function configureCashOutHooks(bytes32 txId, address newCallableContract, uint256 newHookFlags) external {
        emit MockConfigureCashOutHooksCalled(
            txId, // Tools: this comment prevents Prettier from formatting into a single line.
            newCallableContract,
            newHookFlags
        );
    }

    /// @dev Calls the `IPixHook.onPixHook()` function for a provided contract with provided parameters.
    function callPixHook(address callableContract, uint256 hookIndex, bytes32 txId) external {
        IPixHook(callableContract).onPixHook(hookIndex, txId);
    }

    /// @dev Sets a single cash-out operation for a provided PIX transaction ID.
    function setCashOut(bytes32 txId, CashOutOperation calldata operation) external {
        _mockCashOutOperations[txId] = operation;
    }

    /// @dev Returns a cash-out operation by a PIX transaction ID.
    function getCashOut(bytes32 txId) external view returns (CashOutOperation memory) {
        return _mockCashOutOperations[txId];
    }
}
