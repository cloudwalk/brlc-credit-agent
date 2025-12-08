// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { PausableExtUpgradeable } from "./base/PausableExtUpgradeable.sol";
import { RescuableUpgradeable } from "./base/RescuableUpgradeable.sol";
import { AccessControlExtUpgradeable } from "./base/AccessControlExtUpgradeable.sol";
import { UUPSExtUpgradeable } from "./base/UUPSExtUpgradeable.sol";
import { Versionable } from "./base/Versionable.sol";

import { CreditAgentStorageLayout } from "./CreditAgentStorageLayout.sol";
import { SafeCast } from "./libraries/SafeCast.sol";

import { ICashier } from "./interfaces/ICashier.sol";
import { ICreditAgent } from "./interfaces/ICreditAgent.sol";
import { ICreditAgentConfiguration } from "./interfaces/ICreditAgent.sol";
import { ICreditAgentPrimary } from "./interfaces/ICreditAgent.sol";
import { ICashierHook } from "./interfaces/ICashierHook.sol";
import { ICashierHookable } from "./interfaces/ICashierHookable.sol";
import { ICashierHookableTypes } from "./interfaces/ICashierHookable.sol";

/**
 * @title CreditAgent contract
 * @author CloudWalk Inc. (See https://www.cloudwalk.io)
 * @dev Wrapper contract for credit operations.
 *
 * This contract links together a cashier contract with a lending market contract
 * to provide credits to customers during cash-out operations on the cashier contract
 * with the help of hooks mechanism.
 *
 * When one of cash-out processing functions of the cashier contract is called
 * the appropriate hook is triggered and the cashier contract calls the `onCashierHook()` function of CreditAgent
 * just before or after the related token transfers.
 * The `onCashierHook()` function selects and calls the appropriate internal function to process the hook and
 * execute the additional actions to provide a credit or revoke it if needed.
 *
 * Each credit request is represented by a separate structure named {CreditRequest} in the CreditAgent contract and
 * the related loan with an ID in the lending market contract.
 * The loan ID can be found in the `CreditRequest` structure and initially equals zero until the related loan
 * is really taken.
 *
 * Credit requests are identified by the off-chain transaction ID `txId` of the related cash-out operations
 * that happens on the cashier contract.
 *
 * To initiate a credit request, revoke it or get information about it the corresponding wrapper contract should
 * be used. (For example, {CreditAgentCapybaraV1})
 *
 * The possible statuses of a credit request are defined by the {CreditRequestStatus} enumeration.
 *
 * Several roles are used to control access to the CreditAgent contract.
 * About roles see https://docs.openzeppelin.com/contracts/5.x/api/access#AccessControl.
 */
abstract contract CreditAgent is
    CreditAgentStorageLayout,
    AccessControlExtUpgradeable,
    PausableExtUpgradeable,
    RescuableUpgradeable,
    UUPSExtUpgradeable,
    ICreditAgent,
    ICashierHook,
    Versionable
{
    using SafeCast for uint256;

    // ------------------ Constants ------------------------------- //

    /// @dev The role of an admin that is allowed to configure the contract.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @dev The role of a manager that is allowed to initialize and cancel credit operations.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @dev The bit flags that represent the required hooks for cash-out operations.
    uint256 private constant REQUIRED_CASHIER_CASH_OUT_HOOK_FLAGS =
        // prettier-ignore
        (1 << uint256(ICashierHookableTypes.HookIndex.CashOutRequestBefore)) +
        (1 << uint256(ICashierHookableTypes.HookIndex.CashOutConfirmationAfter)) +
        (1 << uint256(ICashierHookableTypes.HookIndex.CashOutReversalAfter));

    // ------------------ Modifiers ------------------------------- //

    /**
     * @dev Modifier that checks that an account has a specific role. Reverts
     * with an {AccessControlUnauthorizedAccount} error including the required role.
     */
    modifier onlyCashier() {
        CreditAgentStorage storage $ = _getCreditAgentStorage();
        if (_msgSender() != $.cashier) {
            revert CreditAgent_CashierHookCallerUnauthorized(_msgSender());
        }
        _;
    }

    // ------------------ Constructor ----------------------------- //

    /**
     * @dev Constructor that prohibits the initialization of the implementation of the upgradeable contract.
     *
     * See details:
     * https://docs.openzeppelin.com/upgrades-plugins/writing-upgradeable#initializing_the_implementation_contract
     *
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor() {
        _disableInitializers();
    }

    // ------------------ Initializers ---------------------------- //

    /**
     * @dev Initializer of the upgradeable contract.
     *
     * See details: https://docs.openzeppelin.com/upgrades-plugins/writing-upgradeable
     */
    function initialize() external virtual initializer {
        __AccessControlExt_init_unchained();
        __PausableExt_init_unchained();
        __Rescuable_init_unchained();
        __UUPSExt_init_unchained(); // This is needed only to avoid errors during coverage assessment

        _setRoleAdmin(ADMIN_ROLE, GRANTOR_ROLE);
        _setRoleAdmin(MANAGER_ROLE, GRANTOR_ROLE);

        _grantRole(OWNER_ROLE, _msgSender());
        _grantRole(ADMIN_ROLE, _msgSender());
    }

    // ------------------ Transactional functions ----------------- //

    /**
     * @inheritdoc ICreditAgentConfiguration
     *
     * @dev Requirements:
     *
     * - The contract must not be paused.
     * - The caller must have the {ADMIN_ROLE} role.
     * - The new cashier contract address must differ from the previously set one.
     */
    function setCashier(address newCashier) external whenNotPaused onlyRole(ADMIN_ROLE) {
        _checkConfiguringPermission();

        CreditAgentStorage storage $ = _getCreditAgentStorage();
        address oldCashier = $.cashier;
        if (oldCashier == newCashier) {
            revert CreditAgent_AlreadyConfigured();
        }

        $.cashier = newCashier;
        _updateConfiguredState();

        emit CashierChanged(newCashier, oldCashier);
    }

    /**
     * @inheritdoc ICreditAgentConfiguration
     *
     * @dev Requirements:
     *
     * - The contract must not be paused.
     * - The caller must have the {ADMIN_ROLE} role.
     * - The new lending market contract address must differ from the previously set one.
     */
    function setLendingMarket(address newLendingMarket) external whenNotPaused onlyRole(ADMIN_ROLE) {
        _checkConfiguringPermission();

        CreditAgentStorage storage $ = _getCreditAgentStorage();
        address oldLendingMarket = $.lendingMarket;
        if (newLendingMarket != address(0) && newLendingMarket.code.length == 0) {
            revert CreditAgent_LendingMarketNotContract();
        }
        if (oldLendingMarket == newLendingMarket) {
            revert CreditAgent_AlreadyConfigured();
        }
        // TODO: check for code length
        $.lendingMarket = newLendingMarket;
        _updateConfiguredState();

        emit LendingMarketChanged(newLendingMarket, oldLendingMarket);
    }

    /**
     * @inheritdoc ICashierHook
     *
     * @dev Requirements:
     *
     * - The contract must not be paused.
     * - The caller must be the configured cashier contract.
     */
    function onCashierHook(uint256 hookIndex, bytes32 txId) external whenNotPaused onlyCashier {
        if (hookIndex == uint256(ICashierHookableTypes.HookIndex.CashOutRequestBefore)) {
            _processCashierHookCashOutRequestBefore(txId);
        } else if (hookIndex == uint256(ICashierHookableTypes.HookIndex.CashOutConfirmationAfter)) {
            _processCashierHookCashOutConfirmationAfter(txId);
        } else if (hookIndex == uint256(ICashierHookableTypes.HookIndex.CashOutReversalAfter)) {
            _processCashierHookCashOutReversalAfter(txId);
        } else {
            revert CreditAgent_CashierHookIndexUnexpected(hookIndex, txId, _msgSender());
        }
    }

    // ------------------ View functions -------------------------- //

    /**
     * @inheritdoc ICreditAgentConfiguration
     */
    function cashier() external view returns (address) {
        CreditAgentStorage storage $ = _getCreditAgentStorage();
        return $.cashier;
    }

    /**
     * @inheritdoc ICreditAgentConfiguration
     */
    function lendingMarket() public view returns (address) {
        CreditAgentStorage storage $ = _getCreditAgentStorage();
        return $.lendingMarket;
    }

    /**
     * @inheritdoc ICreditAgentPrimary
     */
    function agentState() external view returns (AgentState memory) {
        CreditAgentStorage storage $ = _getCreditAgentStorage();
        return $.agentState;
    }

    // ------------------ Pure functions -------------------------- //

    /**
     * @inheritdoc ICreditAgent
     */
    function proveCreditAgent() external pure {}

    // ------------------ Internal functions ---------------------- //

    function _createCreditRequest(
        bytes32 txId, // Tools: prevent Prettier one-liner
        address account,
        uint256 cashOutAmount,
        bytes4 takeLoanSelector,
        bytes4 revokeLoanSelector,
        bytes memory takeLoanData
    ) internal {
        CreditAgentStorage storage $ = _getCreditAgentStorage();

        if (account == address(0)) {
            revert CreditAgent_AccountAddressZero();
        }

        if (!$.agentState.configured) {
            revert CreditAgent_ContractNotConfigured();
        }

        if (txId == bytes32(0)) {
            revert CreditAgent_TxIdZero();
        }

        CreditRequest storage creditRequest = $.creditRequests[txId];

        CreditRequestStatus oldStatus = creditRequest.status;

        if (oldStatus != CreditRequestStatus.Nonexistent && oldStatus != CreditRequestStatus.Reversed) {
            revert CreditAgent_CreditRequestStatusInappropriate(txId, oldStatus);
        }

        creditRequest.status = CreditRequestStatus.Initiated;
        creditRequest.account = account;
        delete creditRequest.loanId; // clean up if status was Reversed
        creditRequest.cashOutAmount = uint64(cashOutAmount);
        creditRequest.takeLoanData = takeLoanData;
        creditRequest.takeLoanSelector = takeLoanSelector;
        creditRequest.revokeLoanSelector = revokeLoanSelector;

        emit CreditRequestStatusChanged(
            txId,
            account,
            CreditRequestStatus.Initiated, // newStatus
            oldStatus,
            cashOutAmount
        );

        $.agentState.initiatedRequestCounter++;
        ICashierHookable($.cashier).configureCashOutHooks(txId, address(this), REQUIRED_CASHIER_CASH_OUT_HOOK_FLAGS);
    }

    /**
     * @dev Removes a credit request.
     *
     * @param txId The unique identifier of the related cash-out operation.
     */
    function _removeCreditRequest(bytes32 txId) internal {
        if (txId == bytes32(0)) {
            revert CreditAgent_TxIdZero();
        }

        CreditAgentStorage storage $ = _getCreditAgentStorage();
        CreditRequest storage creditRequest = $.creditRequests[txId];
        if (creditRequest.status != CreditRequestStatus.Initiated) {
            revert CreditAgent_CreditRequestStatusInappropriate(txId, creditRequest.status);
        }
        CreditRequestStatus oldStatus = creditRequest.status;
        emit CreditRequestStatusChanged(
            txId,
            creditRequest.account,
            CreditRequestStatus.Nonexistent,
            oldStatus,
            creditRequest.cashOutAmount
        );
        delete $.creditRequests[txId];
        $.agentState.initiatedRequestCounter--;

        ICashierHookable($.cashier).configureCashOutHooks(txId, address(0), 0);
    }

    /**
     * @dev Checks the permission to configure this agent contract.
     */
    function _checkConfiguringPermission() internal view {
        CreditAgentStorage storage $ = _getCreditAgentStorage();

        if ($.agentState.initiatedRequestCounter > 0 || $.agentState.pendingRequestCounter > 0) {
            revert CreditAgent_ConfiguringProhibited();
        }
    }

    /**
     * @dev Changes the configured state of this agent contract if necessary.
     */
    function _updateConfiguredState() internal {
        CreditAgentStorage storage $ = _getCreditAgentStorage();

        if ($.lendingMarket != address(0) && $.cashier != address(0)) {
            if (!$.agentState.configured) {
                $.agentState.configured = true;
            }
        } else {
            if ($.agentState.configured) {
                $.agentState.configured = false;
            }
        }
    }

    /**
     * @dev Processes the cash-out request before hook.
     *
     * @param txId The unique identifier of the related cash-out operation.
     */
    function _processCashierHookCashOutRequestBefore(bytes32 txId) internal {
        if (_processTakeLoanFor(txId)) {
            return;
        }

        revert CreditAgent_FailedToProcessCashOutRequestBefore(txId);
    }

    /**
     * @dev Processes the cash-out confirmation after hook.
     *
     * @param txId The unique identifier of the related cash-out operation.
     */
    function _processCashierHookCashOutConfirmationAfter(bytes32 txId) internal {
        if (_processChangeCreditStatus(txId)) {
            return;
        }

        revert CreditAgent_FailedToProcessCashOutConfirmationAfter(txId);
    }

    /**
     * @dev Processes the cash-out reversal after hook.
     *
     * @param txId The unique identifier of the related cash-out operation.
     */
    function _processCashierHookCashOutReversalAfter(bytes32 txId) internal {
        if (_processRevokeLoan(txId)) {
            return;
        }

        revert CreditAgent_FailedToProcessCashOutReversalAfter(txId);
    }

    /**
     * @dev Checks the state of a related cash-out operation to be matched with the expected values.
     *
     * @param txId The unique identifier of the related cash-out operation.
     * @param expectedAccount The expected account of the operation.
     * @param expectedAmount The expected amount of the operation.
     */
    function _checkCashierCashOutState(
        bytes32 txId, // Tools: prevent Prettier one-liner
        address expectedAccount,
        uint256 expectedAmount
    ) internal view {
        CreditAgentStorage storage $ = _getCreditAgentStorage();

        ICashier.CashOutOperation memory operation = ICashier($.cashier).getCashOut(txId);
        if (operation.account != expectedAccount || operation.amount != expectedAmount) {
            revert CreditAgent_CashOutParametersInappropriate(txId);
        }
    }

    /**
     * @dev Tries to process the cash-out request before hook by taking an ordinary loan.
     *
     * @param txId The unique identifier of the related cash-out operation.
     * @return true if the operation was successful, false otherwise.
     */
    function _processTakeLoanFor(bytes32 txId) internal returns (bool) {
        CreditAgentStorage storage $ = _getCreditAgentStorage();

        CreditRequest storage creditRequest = $.creditRequests[txId];

        if (creditRequest.status == CreditRequestStatus.Nonexistent) {
            return false;
        }

        if (creditRequest.status != CreditRequestStatus.Initiated) {
            revert CreditAgent_CreditRequestStatusInappropriate(txId, creditRequest.status);
        }

        _checkCashierCashOutState(txId, creditRequest.account, creditRequest.cashOutAmount);

        (bool success, bytes memory result) = $.lendingMarket.call(
            bytes.concat(creditRequest.takeLoanSelector, creditRequest.takeLoanData)
        );
        if (!success) {
            return false;
        }

        uint256 loanId = abi.decode(result, (uint256));

        creditRequest.loanId = loanId;
        creditRequest.status = CreditRequestStatus.Pending;

        emit CreditRequestStatusChanged(
            txId,
            creditRequest.account,
            CreditRequestStatus.Pending, // newStatus
            CreditRequestStatus.Initiated, // oldStatus
            creditRequest.cashOutAmount
        );

        $.agentState.initiatedRequestCounter--;
        $.agentState.pendingRequestCounter++;

        return true;
    }

    /**
     * @dev Tries to process the cash-out confirmation after hook by changing the credit status to Confirmed.
     *
     * @param txId The unique identifier of the related cash-out operation.
     * @return true if the operation was successful, false otherwise.
     */
    function _processChangeCreditStatus(bytes32 txId) internal returns (bool) {
        CreditAgentStorage storage $ = _getCreditAgentStorage();

        CreditRequest storage creditRequest = $.creditRequests[txId];

        if (creditRequest.status == CreditRequestStatus.Nonexistent) {
            return false;
        }

        if (creditRequest.status != CreditRequestStatus.Pending) {
            revert CreditAgent_CreditRequestStatusInappropriate(txId, creditRequest.status);
        }

        creditRequest.status = CreditRequestStatus.Confirmed;

        emit CreditRequestStatusChanged(
            txId,
            creditRequest.account,
            CreditRequestStatus.Confirmed, // newStatus
            CreditRequestStatus.Pending, // oldStatus
            creditRequest.cashOutAmount
        );

        $.agentState.pendingRequestCounter--;

        return true;
    }

    /**
     * @dev Tries to process the cash-out reversal after hook by revoking an ordinary loan.
     *
     * @param txId The unique identifier of the related cash-out operation.
     * @return true if the operation was successful, false otherwise.
     */
    function _processRevokeLoan(bytes32 txId) internal returns (bool) {
        CreditAgentStorage storage $ = _getCreditAgentStorage();

        CreditRequest storage creditRequest = $.creditRequests[txId];

        if (creditRequest.status == CreditRequestStatus.Nonexistent) {
            return false;
        }

        if (creditRequest.status != CreditRequestStatus.Pending) {
            revert CreditAgent_CreditRequestStatusInappropriate(txId, creditRequest.status);
        }

        (bool success, ) = $.lendingMarket.call(
            abi.encodeWithSelector(creditRequest.revokeLoanSelector, creditRequest.loanId)
        );
        if (!success) {
            return false;
        }

        emit CreditRequestStatusChanged(
            txId,
            creditRequest.account,
            CreditRequestStatus.Reversed, // newStatus
            CreditRequestStatus.Pending, // oldStatus
            creditRequest.cashOutAmount
        );

        creditRequest.status = CreditRequestStatus.Reversed;

        $.agentState.pendingRequestCounter--;

        return true;
    }

    /**
     * @dev The upgrade validation function for the UUPSExtUpgradeable contract.
     * @param newImplementation The address of the new implementation.
     */
    function _validateUpgrade(address newImplementation) internal view override onlyRole(OWNER_ROLE) {
        try ICreditAgent(newImplementation).proveCreditAgent() {} catch {
            revert CreditAgent_ImplementationAddressInvalid();
        }
    }

    // ------------------ Service functions ----------------------- //

    /**
     * @dev The version of the standard upgrade function without the second parameter for backward compatibility.
     * @custom:oz-upgrades-unsafe-allow-reachable delegatecall
     */
    function upgradeTo(address newImplementation) external {
        upgradeToAndCall(newImplementation, "");
    }
}
