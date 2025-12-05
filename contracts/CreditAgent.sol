// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { PausableExtUpgradeable } from "./base/PausableExtUpgradeable.sol";
import { RescuableUpgradeable } from "./base/RescuableUpgradeable.sol";
import { AccessControlExtUpgradeable } from "./base/AccessControlExtUpgradeable.sol";
import { UUPSExtUpgradeable } from "./base/UUPSExtUpgradeable.sol";
import { Versionable } from "./base/Versionable.sol";

import { CreditAgentStorageLayout } from "./CreditAgentStorageLayout.sol";
import { SafeCast } from "./libraries/SafeCast.sol";

import { ILendingMarket } from "./interfaces/ILendingMarket.sol";
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
 * Each credit is represented by a separate structure named {Credit} in the CreditAgent contract and
 * the related loan with an ID in the lending market contract.
 * The loan ID can be found in the `Credit` structure and initially equals zero until the related loan is really taken.
 *
 * Credits are identified by the off-chain transaction ID `txId` of the related cash-out operations
 * that happens on the cashier contract.
 * To initiate a credit, revoke it or get information about it the corresponding `txId` should be passed to
 * CreditAgent as a function argument. The same for the cashier contract.
 *
 * The possible statuses of a credit are defined by the {CreditStatus} enumeration.
 *
 * Several roles are used to control access to the CreditAgent contract.
 * About roles see https://docs.openzeppelin.com/contracts/5.x/api/access#AccessControl.
 */
contract CreditAgent is
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
    function initialize() external initializer {
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
        if (oldLendingMarket == newLendingMarket) {
            revert CreditAgent_AlreadyConfigured();
        }

        $.lendingMarket = newLendingMarket;
        _updateConfiguredState();

        emit LendingMarketChanged(newLendingMarket, oldLendingMarket);
    }

    /**
     * @inheritdoc ICreditAgentPrimary
     *
     * @dev Requirements:
     *
     * - The contract must not be paused.
     * - The caller must have the {MANAGER_ROLE} role.
     * - The contract must be configured.
     * - The provided `txId` must not be used for any other credit.
     * - The provided `txId`, `borrower`, `programId`, `durationInPeriods`, `loanAmount` must not be zeros.
     * - The credit with the provided `txId` must have the `Nonexistent` or `Reversed` status.
     */
    function initiateCredit(
        bytes32 txId, // Tools: prevent Prettier one-liner
        address borrower,
        uint256 programId,
        uint256 durationInPeriods,
        uint256 loanAmount,
        uint256 loanAddon
    ) external whenNotPaused onlyRole(MANAGER_ROLE) {
        CreditAgentStorage storage $ = _getCreditAgentStorage();

        if (!$.agentState.configured) {
            revert CreditAgent_ContractNotConfigured();
        }
        if (txId == bytes32(0)) {
            revert CreditAgent_TxIdZero();
        }
        if (borrower == address(0)) {
            revert CreditAgent_BorrowerAddressZero();
        }
        if (programId == 0) {
            revert CreditAgent_ProgramIdZero();
        }
        if (durationInPeriods == 0) {
            revert CreditAgent_LoanDurationZero();
        }
        if (loanAmount == 0) {
            revert CreditAgent_LoanAmountZero();
        }
        // some validation for the arguments
        loanAmount.toUint64();
        loanAddon.toUint64();
        durationInPeriods.toUint32();

        _createCreditRequest(
            txId,
            borrower,
            loanAmount,
            ILendingMarket.takeLoanFor.selector,
            ILendingMarket.revokeLoan.selector,
            abi.encode(borrower, programId.toUint32(), loanAmount, loanAddon, durationInPeriods)
        );

        // DEPRECATAD staff
        $.agentState.initiatedCreditCounter++;
        emit CreditStatusChanged(
            txId,
            borrower,
            CreditStatus.Initiated, // newStatus
            CreditStatus.Nonexistent, // oldStatus
            0, // loanId
            programId,
            durationInPeriods,
            loanAmount,
            loanAddon
        );
    }

    /**
     * @inheritdoc ICreditAgentPrimary
     *
     * @dev Requirements:
     *
     * - The contract must not be paused.
     * - The caller must have the {MANAGER_ROLE} role.
     * - The contract must be configured.
     * - The provided `txId` must not be used for any other credit.
     * - The provided `txId`, `borrower`, `programId` must not be zeros.
     * - The provided `durationsInPeriods`, `borrowAmounts`, `addonAmounts` arrays must have the same length.
     * - The provided `durationsInPeriods` and `borrowAmounts` arrays must contain only non-zero values.
     * - The credit with the provided `txId` must have the `Nonexistent` or `Reversed` status.
     */
    function initiateInstallmentCredit(
        bytes32 txId, // Tools: prevent Prettier one-liner
        address borrower,
        uint256 programId,
        uint256[] calldata durationsInPeriods,
        uint256[] calldata borrowAmounts,
        uint256[] calldata addonAmounts
    ) external whenNotPaused onlyRole(MANAGER_ROLE) {
        CreditAgentStorage storage $ = _getCreditAgentStorage();

        if (!$.agentState.configured) {
            revert CreditAgent_ContractNotConfigured();
        }
        if (txId == bytes32(0)) {
            revert CreditAgent_TxIdZero();
        }
        if (borrower == address(0)) {
            revert CreditAgent_BorrowerAddressZero();
        }
        if (programId == 0) {
            revert CreditAgent_ProgramIdZero();
        }
        if (
            durationsInPeriods.length == 0 ||
            durationsInPeriods.length != borrowAmounts.length ||
            durationsInPeriods.length != addonAmounts.length
        ) {
            revert CreditAgent_InputArraysInvalid();
        }
        for (uint256 i = 0; i < borrowAmounts.length; i++) {
            if (durationsInPeriods[i] == 0) {
                revert CreditAgent_LoanDurationZero();
            }
            if (borrowAmounts[i] == 0) {
                revert CreditAgent_LoanAmountZero();
            }
            borrowAmounts[i].toUint64();
            addonAmounts[i].toUint64();
            durationsInPeriods[i].toUint32();
        }

        _createCreditRequest(
            txId,
            borrower,
            _sumArray(borrowAmounts),
            ILendingMarket.takeInstallmentLoanFor.selector,
            ILendingMarket.revokeInstallmentLoan.selector,
            abi.encode(borrower, programId.toUint32(), borrowAmounts, addonAmounts, durationsInPeriods)
        );

        // deprecated staff
        $.agentState.initiatedInstallmentCreditCounter++;
        emit InstallmentCreditStatusChanged(
            txId,
            borrower,
            CreditStatus.Initiated, // newStatus
            CreditStatus.Nonexistent, // oldStatus
            0, // firstInstallmentId
            programId,
            durationsInPeriods[durationsInPeriods.length - 1], // lastDurationInPeriods
            _sumArray(borrowAmounts), // totalBorrowAmount
            _sumArray(addonAmounts), // totalAddonAmount
            durationsInPeriods.length
        );
    }

    /**
     * @inheritdoc ICreditAgentPrimary
     *
     * @dev Requirements:
     *
     * - The contract must not be paused.
     * - The caller must have the {MANAGER_ROLE} role.
     * - The provided `txId` must not be zero.
     * - The credit with the provided `txId` must have the `Initiated` status.
     */
    function revokeCredit(bytes32 txId) external whenNotPaused onlyRole(MANAGER_ROLE) {
        bytes memory takeLoanData = _removeCreditRequest(txId);

        // deprecated staff for tests
        (address borrower, uint256 programId, uint256 loanAmount, uint256 loanAddon, uint256 durationInPeriods) = abi
            .decode(takeLoanData, (address, uint256, uint256, uint256, uint256));
        _getCreditAgentStorage().agentState.initiatedCreditCounter--;
        emit CreditStatusChanged(
            txId,
            borrower,
            CreditStatus.Nonexistent, // newStatus,
            CreditStatus.Initiated, // oldStatus
            0,
            programId,
            durationInPeriods,
            loanAmount,
            loanAddon
        );
    }

    /**
     * @inheritdoc ICreditAgentPrimary
     *
     * @dev Requirements:
     *
     * - The contract must not be paused.
     * - The caller must have the {MANAGER_ROLE} role.
     * - The provided `txId` must not be zero.
     * - The credit with the provided `txId` must have the `Initiated` status.
     */
    function revokeInstallmentCredit(bytes32 txId) external whenNotPaused onlyRole(MANAGER_ROLE) {
        bytes memory takeLoanData = _removeCreditRequest(txId);

        // deprecated staff for tests
        (
            address borrower,
            uint256 programId,
            uint256[] memory borrowAmounts,
            uint256[] memory addonAmounts,
            uint256[] memory durationsInPeriods
        ) = abi.decode(takeLoanData, (address, uint256, uint256[], uint256[], uint256[]));

        _getCreditAgentStorage().agentState.initiatedInstallmentCreditCounter--;
        emit InstallmentCreditStatusChanged(
            txId,
            borrower,
            CreditStatus.Nonexistent, // newStatus
            CreditStatus.Initiated, // oldStatus
            0, // firstInstallmentId
            programId,
            durationsInPeriods[durationsInPeriods.length - 1], // lastDurationInPeriods
            _sumArray(borrowAmounts), // totalBorrowAmount
            _sumArray(addonAmounts), // totalAddonAmount
            durationsInPeriods.length
        );
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
    function lendingMarket() external view returns (address) {
        CreditAgentStorage storage $ = _getCreditAgentStorage();
        return $.lendingMarket;
    }

    /**
     * @inheritdoc ICreditAgentPrimary
     */
    function getCredit(bytes32 txId) external view returns (Credit memory result) {
        CreditAgentStorage storage $ = _getCreditAgentStorage();
        CreditRequest storage creditRequest = $.creditRequests[txId];
        if (creditRequest.takeLoanData.length != 0) {
            (
                address borrower,
                uint256 programId,
                uint256 loanAmount,
                uint256 loanAddon,
                uint256 durationInPeriods
            ) = abi.decode(creditRequest.takeLoanData, (address, uint32, uint256, uint256, uint256));
            result = Credit(
                borrower,
                programId,
                durationInPeriods,
                creditRequest.status,
                loanAmount,
                loanAddon,
                creditRequest.loanId
            );
        }
        // else empty object
    }

    /**
     * @inheritdoc ICreditAgentPrimary
     */
    function getInstallmentCredit(bytes32 txId) external view returns (InstallmentCredit memory result) {
        CreditAgentStorage storage $ = _getCreditAgentStorage();
        CreditRequest storage creditRequest = $.creditRequests[txId];
        if (creditRequest.takeLoanData.length != 0) {
            (
                address borrower,
                uint256 programId,
                uint256[] memory borrowAmounts,
                uint256[] memory addonAmounts,
                uint256[] memory durationsInPeriods
            ) = abi.decode(creditRequest.takeLoanData, (address, uint256, uint256[], uint256[], uint256[]));
            result = InstallmentCredit(
                borrower,
                programId,
                creditRequest.status,
                durationsInPeriods,
                borrowAmounts,
                addonAmounts,
                creditRequest.loanId
            );
        }
        // else empty object
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
        address borrower,
        uint256 cashOutAmount,
        bytes4 takeLoanSelector,
        bytes4 revokeLoanSelector,
        bytes memory takeLoanData
    ) internal {
        CreditAgentStorage storage $ = _getCreditAgentStorage();
        CreditRequest storage creditRequest = $.creditRequests[txId];

        CreditStatus oldStatus = creditRequest.status;

        if (oldStatus != CreditStatus.Nonexistent && oldStatus != CreditStatus.Reversed) {
            revert CreditAgent_CreditStatusInappropriate(txId, oldStatus);
        }

        creditRequest.status = CreditStatus.Initiated;
        creditRequest.borrower = borrower;
        delete creditRequest.loanId; // clean up if status was Reversed
        creditRequest.cashOutAmount = uint64(cashOutAmount);
        creditRequest.takeLoanData = takeLoanData;
        creditRequest.takeLoanSelector = takeLoanSelector;
        creditRequest.revokeLoanSelector = revokeLoanSelector;

        emit CreditRequestStatusChanged(
            txId,
            borrower,
            CreditStatus.Initiated, // newStatus
            oldStatus,
            cashOutAmount
        );

        ICashierHookable($.cashier).configureCashOutHooks(txId, address(this), REQUIRED_CASHIER_CASH_OUT_HOOK_FLAGS);
    }

    // TODO remove return values it is used only for depecated event now
    function _removeCreditRequest(bytes32 txId) internal returns (bytes memory takeLoanData) {
        if (txId == bytes32(0)) {
            revert CreditAgent_TxIdZero();
        }

        CreditAgentStorage storage $ = _getCreditAgentStorage();
        CreditRequest storage creditRequest = $.creditRequests[txId];
        takeLoanData = creditRequest.takeLoanData;
        if (creditRequest.status != CreditStatus.Initiated) {
            revert CreditAgent_CreditStatusInappropriate(txId, creditRequest.status);
        }
        CreditStatus oldStatus = creditRequest.status;
        emit CreditRequestStatusChanged(
            txId,
            creditRequest.borrower,
            CreditStatus.Nonexistent,
            oldStatus,
            creditRequest.cashOutAmount
        );
        delete $.creditRequests[txId];

        ICashierHookable($.cashier).configureCashOutHooks(txId, address(0), 0);
    }

    /**
     * @dev Checks the permission to configure this agent contract.
     */
    function _checkConfiguringPermission() internal view {
        CreditAgentStorage storage $ = _getCreditAgentStorage();

        if (
            $.agentState.initiatedCreditCounter > 0 ||
            $.agentState.pendingCreditCounter > 0 ||
            $.agentState.initiatedInstallmentCreditCounter > 0 ||
            $.agentState.pendingInstallmentCreditCounter > 0
        ) {
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

    /// @dev Calculates the sum of all elements in a memory array.
    /// @param values Array of amounts to sum.
    /// @return The total sum of all array elements.
    function _sumArray(uint256[] memory values) internal pure returns (uint256) {
        uint256 len = values.length;
        uint256 sum = 0;
        for (uint256 i = 0; i < len; ++i) {
            sum += values[i];
        }
        return sum;
    }

    /**
     * @dev Converts an array of uint64 values to an array of uint256 values.
     * @param values The array of uint64 values to convert.
     * @return The array of uint256 values.
     */
    function _toUint256Array(uint64[] storage values) internal view returns (uint256[] memory) {
        uint256 len = values.length;
        uint256[] memory result = new uint256[](len);
        for (uint256 i = 0; i < len; ++i) {
            result[i] = uint256(values[i]);
        }
        return result;
    }

    /**
     * @dev Converts an array of uint32 values to an array of uint256 values.
     * @param values The array of uint32 values to convert.
     * @return The array of uint256 values.
     */
    function _toUint256Array(uint32[] storage values) internal view returns (uint256[] memory) {
        uint256 len = values.length;
        uint256[] memory result = new uint256[](len);
        for (uint256 i = 0; i < len; ++i) {
            result[i] = uint256(values[i]);
        }
        return result;
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

        if (creditRequest.status == CreditStatus.Nonexistent) {
            return false;
        }

        if (creditRequest.status != CreditStatus.Initiated) {
            revert CreditAgent_CreditStatusInappropriate(txId, creditRequest.status);
        }

        address borrower = creditRequest.borrower;
        uint256 loanAmount = creditRequest.cashOutAmount;

        _checkCashierCashOutState(txId, borrower, loanAmount); // TODO: TO WE NEED THIS

        (bool success, bytes memory result) = $.lendingMarket.call(
            abi.encodePacked(creditRequest.takeLoanSelector, creditRequest.takeLoanData)
        );
        if (!success) {
            return false;
        }

        uint256 loanId = abi.decode(result, (uint256));

        creditRequest.loanId = loanId;
        creditRequest.status = CreditStatus.Pending;

        emit CreditRequestStatusChanged(
            txId,
            borrower,
            CreditStatus.Pending, // newStatus
            CreditStatus.Initiated, // oldStatus
            loanAmount
        );

        // DEPRECATED STAFF FOR TESTS
        if (creditRequest.takeLoanSelector == ILendingMarket.takeLoanFor.selector) {
            $.agentState.initiatedCreditCounter--;
            $.agentState.pendingCreditCounter++;
            (
                address _borrower,
                uint256 programId,
                uint256 _loanAmount,
                uint256 loanAddon,
                uint256 durationInPeriods
            ) = abi.decode(creditRequest.takeLoanData, (address, uint32, uint256, uint256, uint256));
            emit CreditStatusChanged(
                txId,
                borrower,
                CreditStatus.Pending, // newStatus
                CreditStatus.Initiated, // oldStatus,
                creditRequest.loanId,
                programId,
                durationInPeriods,
                loanAmount,
                loanAddon
            );
        } else if (creditRequest.takeLoanSelector == ILendingMarket.takeInstallmentLoanFor.selector) {
            $.agentState.initiatedInstallmentCreditCounter--;
            $.agentState.pendingInstallmentCreditCounter++;
            (
                address _borrower,
                uint256 programId,
                uint256[] memory borrowAmounts,
                uint256[] memory addonAmounts,
                uint256[] memory durationsInPeriods
            ) = abi.decode(creditRequest.takeLoanData, (address, uint256, uint256[], uint256[], uint256[]));
            emit InstallmentCreditStatusChanged(
                txId,
                borrower,
                CreditStatus.Pending, // newStatus
                CreditStatus.Initiated, // oldStatus
                loanId,
                programId,
                durationsInPeriods[durationsInPeriods.length - 1], // lastDurationInPeriods
                _sumArray(borrowAmounts), // totalBorrowAmount
                _sumArray(addonAmounts), // totalAddonAmount
                durationsInPeriods.length
            );
        }
        //

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

        if (creditRequest.status == CreditStatus.Nonexistent) {
            return false;
        }

        if (creditRequest.status != CreditStatus.Pending) {
            revert CreditAgent_CreditStatusInappropriate(txId, creditRequest.status);
        }

        creditRequest.status = CreditStatus.Confirmed;

        emit CreditRequestStatusChanged(
            txId,
            creditRequest.borrower,
            CreditStatus.Confirmed, // newStatus
            CreditStatus.Pending, // oldStatus
            creditRequest.cashOutAmount
        );

        // DEPRECATED STAFF FOR TESTS
        if (creditRequest.takeLoanSelector == ILendingMarket.takeLoanFor.selector) {
            $.agentState.pendingCreditCounter--;
            (
                address borrower,
                uint256 programId,
                uint256 loanAmount,
                uint256 loanAddon,
                uint256 durationInPeriods
            ) = abi.decode(creditRequest.takeLoanData, (address, uint32, uint256, uint256, uint256));
            emit CreditStatusChanged(
                txId,
                borrower,
                CreditStatus.Confirmed, // newStatus
                CreditStatus.Pending, // oldStatus,
                creditRequest.loanId,
                programId,
                durationInPeriods,
                loanAmount,
                loanAddon
            );
        } else if (creditRequest.takeLoanSelector == ILendingMarket.takeInstallmentLoanFor.selector) {
            $.agentState.pendingInstallmentCreditCounter--;
            (
                address borrower,
                uint256 programId,
                uint256[] memory borrowAmounts,
                uint256[] memory addonAmounts,
                uint256[] memory durationsInPeriods
            ) = abi.decode(creditRequest.takeLoanData, (address, uint256, uint256[], uint256[], uint256[]));
            emit InstallmentCreditStatusChanged(
                txId,
                borrower,
                CreditStatus.Confirmed, // newStatus
                CreditStatus.Pending, // oldStatus
                creditRequest.loanId,
                programId,
                durationsInPeriods[durationsInPeriods.length - 1], // lastDurationInPeriods
                _sumArray(borrowAmounts), // totalBorrowAmount
                _sumArray(addonAmounts), // totalAddonAmount
                durationsInPeriods.length
            );
        }
        //
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

        if (creditRequest.status == CreditStatus.Nonexistent) {
            return false;
        }

        if (creditRequest.status != CreditStatus.Pending) {
            revert CreditAgent_CreditStatusInappropriate(txId, creditRequest.status);
        }

        (bool success, ) = $.lendingMarket.call(
            abi.encodeWithSelector(creditRequest.revokeLoanSelector, creditRequest.loanId)
        );
        if (!success) {
            return false;
        }

        emit CreditRequestStatusChanged(
            txId,
            creditRequest.borrower,
            CreditStatus.Reversed, // newStatus
            CreditStatus.Pending, // oldStatus
            creditRequest.cashOutAmount
        );

        creditRequest.status = CreditStatus.Reversed;

        // DEPRECATED STAFF FOR TESTS
        if (creditRequest.takeLoanSelector == ILendingMarket.takeLoanFor.selector) {
            $.agentState.pendingCreditCounter--;
            (
                address borrower,
                uint256 programId,
                uint256 loanAmount,
                uint256 loanAddon,
                uint256 durationInPeriods
            ) = abi.decode(creditRequest.takeLoanData, (address, uint32, uint256, uint256, uint256));
            emit CreditStatusChanged(
                txId,
                creditRequest.borrower,
                CreditStatus.Reversed, // newStatus
                CreditStatus.Pending, // oldStatus
                creditRequest.loanId,
                programId,
                durationInPeriods,
                loanAmount,
                loanAddon
            );
        } else if (creditRequest.takeLoanSelector == ILendingMarket.takeInstallmentLoanFor.selector) {
            $.agentState.pendingInstallmentCreditCounter--;
            (
                address borrower,
                uint256 programId,
                uint256[] memory borrowAmounts,
                uint256[] memory addonAmounts,
                uint256[] memory durationsInPeriods
            ) = abi.decode(creditRequest.takeLoanData, (address, uint256, uint256[], uint256[], uint256[]));
            emit InstallmentCreditStatusChanged(
                txId,
                borrower,
                CreditStatus.Confirmed, // newStatus
                CreditStatus.Pending, // oldStatus
                creditRequest.loanId,
                programId,
                durationsInPeriods[durationsInPeriods.length - 1], // lastDurationInPeriods
                _sumArray(borrowAmounts), // totalBorrowAmount
                _sumArray(addonAmounts), // totalAddonAmount
                durationsInPeriods.length
            );
        }
        //
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
