// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { ICreditAgentTypes } from "./interfaces/ICreditAgent.sol";

/**
 * @title CreditAgent storage version 1
 * @author CloudWalk Inc. (See https://cloudwalk.io)
 */
abstract contract CreditAgentStorageV1 is ICreditAgentTypes {
    /// @dev The address of the related Cashier contract.
    address internal _cashier;

    /// @dev The address of the related lending market contract.
    address internal _lendingMarket;

    /// @dev The mapping of the credit structure for a related operation identifier.
    mapping(bytes32 => Credit) internal _credits;

    /// @dev The state of this agent contract.
    AgentState internal _agentState;

    /// @dev The mapping of the installment credit structure for a related operation identifier.
    mapping(bytes32 => InstallmentCredit) internal _installmentCredits;
}

/**
 * @title CreditAgent storage
 * @author CloudWalk Inc. (See https://cloudwalk.io)
 * @dev Contains storage variables of the {CreditAgent} contract.
 *
 * We are following Compound's approach of upgrading new contract implementations.
 * See https://github.com/compound-finance/compound-protocol.
 * When we need to add new storage variables, we create a new version of CreditStorage
 * e.g. CreditStorage<versionNumber>, so finally it would look like
 * "contract CreditStorage is CreditStorageV1, CreditStorageV2".
 */
abstract contract CreditAgentStorage is CreditAgentStorageV1 {
    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     */
    uint256[45] private __gap;
}
