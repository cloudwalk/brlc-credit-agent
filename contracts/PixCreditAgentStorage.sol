// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { IPixCreditAgentTypes } from "./interfaces/IPixCreditAgent.sol";

/**
 * @title PixCreditAgent storage version 1
 * @author CloudWalk Inc. (See https://cloudwalk.io)
 */
abstract contract PixCreditAgentStorageV1 is IPixCreditAgentTypes {
    /// @dev The address of the related Cashier contract.
    address internal _cashier;

    /// @dev The address of the related lending market contract.
    address internal _lendingMarket;

    /// @dev The mapping of the credit structure for a related operation identifier.
    mapping(bytes32 => PixCredit) internal _pixCredits;

    /// @dev The state of this agent contract.
    AgentState internal _agentState;
}

/**
 * @title PixCreditAgent storage
 * @author CloudWalk Inc. (See https://cloudwalk.io)
 * @dev Contains storage variables of the {PixCreditAgent} contract.
 *
 * We are following Compound's approach of upgrading new contract implementations.
 * See https://github.com/compound-finance/compound-protocol.
 * When we need to add new storage variables, we create a new version of PixCreditStorage
 * e.g. PixCreditStorage<versionNumber>, so finally it would look like
 * "contract PixCreditStorage is PixCreditStorageV1, PixCreditStorageV2".
 */
abstract contract PixCreditAgentStorage is PixCreditAgentStorageV1 {
    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     */
    uint256[46] private __gap;
}
