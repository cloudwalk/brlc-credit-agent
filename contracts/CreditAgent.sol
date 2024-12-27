// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { PausableExtUpgradeable } from "./base/PausableExtUpgradeable.sol";
import { RescuableUpgradeable } from "./base/RescuableUpgradeable.sol";
import { AccessControlExtUpgradeable } from "./base/AccessControlExtUpgradeable.sol";
import { UUPSExtUpgradeable } from "./base/UUPSExtUpgradeable.sol";
import { Versionable } from "./base/Versionable.sol";

import { CreditAgentStorage } from "./CreditAgentStorage.sol";
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
 * @author CloudWalk Inc. (See https://cloudwalk.io)
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
    CreditAgentStorage,
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

    /// @dev The role of this contract owner.
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");

    /// @dev The role of admin that is allowed to configure the contract.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @dev The role of manager that is allowed to initialize and cancel credit operations.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @dev The bit flags that represent the required hooks for cash-out operations.
    uint256 private constant REQUIRED_CASHIER_CASH_OUT_HOOK_FLAGS =
        (1 << uint256(ICashierHookableTypes.HookIndex.CashOutRequestBefore)) +
        (1 << uint256(ICashierHookableTypes.HookIndex.CashOutConfirmationAfter)) +
        (1 << uint256(ICashierHookableTypes.HookIndex.CashOutReversalAfter));

    // ------------------ Modifiers ------------------------------- //

    /**
     * @dev Modifier that checks that an account has a specific role. Reverts
     * with an {AccessControlUnauthorizedAccount} error including the required role.
     */
    modifier onlyCashier() {
        if (_msgSender() != _cashier) {
            revert CreditAgent_CashierHookCallerUnauthorized(_msgSender());
        }
        _;
    }

    // ------------------ Initializers ---------------------------- //

    /**
     * @dev The initialize function of the upgradable contract.
     * See details https://docs.openzeppelin.com/upgrades-plugins/1.x/writing-upgradeable
     */
    function initialize() external initializer {
        __CreditAgent_init();
    }

    /**
     * @dev The internal initializer of the upgradable contract.
     *
     * See {CreditAgent-initialize}.
     */
    function __CreditAgent_init() internal onlyInitializing {
        __Context_init_unchained();
        __ERC165_init_unchained();
        __AccessControl_init_unchained();
        __AccessControlExt_init_unchained();
        __Pausable_init_unchained();
        __PausableExt_init_unchained(OWNER_ROLE);
        __Rescuable_init_unchained(OWNER_ROLE);

        __CreditAgent_init_unchained();
    }

    /**
     * @dev The internal unchained initializer of the upgradable contract.
     *
     * See {CreditAgent-initialize}.
     */
    function __CreditAgent_init_unchained() internal onlyInitializing {
        _setRoleAdmin(OWNER_ROLE, OWNER_ROLE);
        _setRoleAdmin(ADMIN_ROLE, OWNER_ROLE);
        _setRoleAdmin(MANAGER_ROLE, OWNER_ROLE);

        _grantRole(OWNER_ROLE, _msgSender());
        _grantRole(ADMIN_ROLE, _msgSender());
    }

    // ------------------ Functions ------------------------------- //

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

        address oldCashier = _cashier;
        if (oldCashier == newCashier) {
            revert CreditAgent_AlreadyConfigured();
        }

        _cashier = newCashier;
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

        address oldLendingMarket = _lendingMarket;
        if (oldLendingMarket == newLendingMarket) {
            revert CreditAgent_AlreadyConfigured();
        }

        _lendingMarket = newLendingMarket;
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
        bytes32 txId, // Tools: this comment prevents Prettier from formatting into a single line.
        address borrower,
        uint256 programId,
        uint256 durationInPeriods,
        uint256 loanAmount,
        uint256 loanAddon
    ) external whenNotPaused onlyRole(MANAGER_ROLE) {
        if (!_agentState.configured) {
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

        if (_installmentCredits[txId].status != CreditStatus.Nonexistent) {
            revert CreditAgent_TxIdAlreadyUsed();
        }

        Credit storage credit = _credits[txId];

        CreditStatus oldStatus = credit.status;
        if (oldStatus != CreditStatus.Nonexistent && oldStatus != CreditStatus.Reversed) {
            revert CreditAgent_CreditStatusInappropriate(txId, oldStatus);
        }
        if (oldStatus != CreditStatus.Nonexistent) {
            credit.loanId = 0;
        }

        credit.borrower = borrower;
        credit.programId = programId.toUint32();
        credit.loanAmount = loanAmount.toUint64();
        credit.loanAddon = loanAddon.toUint64();
        credit.durationInPeriods = durationInPeriods.toUint32();

        _changeCreditStatus(
            txId,
            credit,
            CreditStatus.Initiated, // newStatus
            CreditStatus.Nonexistent // oldStatus
        );

        ICashierHookable(_cashier).configureCashOutHooks(txId, address(this), REQUIRED_CASHIER_CASH_OUT_HOOK_FLAGS);
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
        bytes32 txId, // Tools: this comment prevents Prettier from formatting into a single line.
        address borrower,
        uint256 programId,
        uint256[] calldata durationsInPeriods,
        uint256[] calldata borrowAmounts,
        uint256[] calldata addonAmounts
    ) external whenNotPaused onlyRole(MANAGER_ROLE) {
        if (!_agentState.configured) {
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
        }

        if (_credits[txId].status != CreditStatus.Nonexistent) {
            revert CreditAgent_TxIdAlreadyUsed();
        }

        InstallmentCredit storage installmentCredit = _installmentCredits[txId];

        CreditStatus oldStatus = installmentCredit.status;
        if (oldStatus != CreditStatus.Nonexistent && oldStatus != CreditStatus.Reversed) {
            revert CreditAgent_CreditStatusInappropriate(txId, oldStatus);
        }
        if (oldStatus != CreditStatus.Nonexistent) {
            installmentCredit.firstInstallmentId = 0;
            delete installmentCredit.durationsInPeriods;
            delete installmentCredit.borrowAmounts;
            delete installmentCredit.addonAmounts;
        }

        installmentCredit.borrower = borrower;
        installmentCredit.programId = programId.toUint32();
        _storeToUint32Array(durationsInPeriods, installmentCredit.durationsInPeriods);
        _storeToUint64Array(borrowAmounts, installmentCredit.borrowAmounts);
        _storeToUint64Array(addonAmounts, installmentCredit.addonAmounts);

        _changeInstallmentCreditStatus(
            txId,
            installmentCredit,
            CreditStatus.Initiated, // newStatus
            CreditStatus.Nonexistent // oldStatus
        );

        ICashierHookable(_cashier).configureCashOutHooks(txId, address(this), REQUIRED_CASHIER_CASH_OUT_HOOK_FLAGS);
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
        if (txId == bytes32(0)) {
            revert CreditAgent_TxIdZero();
        }

        Credit storage credit = _credits[txId];
        if (credit.status != CreditStatus.Initiated) {
            revert CreditAgent_CreditStatusInappropriate(txId, credit.status);
        }

        _changeCreditStatus(
            txId,
            credit,
            CreditStatus.Nonexistent, // newStatus
            CreditStatus.Initiated // oldStatus
        );

        delete _credits[txId];

        ICashierHookable(_cashier).configureCashOutHooks(txId, address(0), 0);
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
        if (txId == bytes32(0)) {
            revert CreditAgent_TxIdZero();
        }

        InstallmentCredit storage installmentCredit = _installmentCredits[txId];
        if (installmentCredit.status != CreditStatus.Initiated) {
            revert CreditAgent_CreditStatusInappropriate(txId, installmentCredit.status);
        }

        _changeInstallmentCreditStatus(
            txId,
            installmentCredit,
            CreditStatus.Nonexistent, // newStatus
            CreditStatus.Initiated // oldStatus
        );

        delete _installmentCredits[txId];

        ICashierHookable(_cashier).configureCashOutHooks(txId, address(0), 0);
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
        return _cashier;
    }

    /**
     * @inheritdoc ICreditAgentConfiguration
     */
    function lendingMarket() external view returns (address) {
        return _lendingMarket;
    }

    /**
     * @inheritdoc ICreditAgentPrimary
     */
    function getCredit(bytes32 txId) external view returns (Credit memory) {
        return _credits[txId];
    }

    /**
     * @inheritdoc ICreditAgentPrimary
     */
    function getInstallmentCredit(bytes32 txId) external view returns (InstallmentCredit memory) {
        return _installmentCredits[txId];
    }

    /**
     * @inheritdoc ICreditAgentPrimary
     */
    function agentState() external view returns (AgentState memory) {
        return _agentState;
    }

    // ------------------ Pure functions -------------------------- //

    /**
     * @inheritdoc ICreditAgentPrimary
     */
    function proveCreditAgent() external pure {}

    // ------------------ Internal functions ---------------------- //

    /**
     * @dev Checks the permission to configure this agent contract.
     */
    function _checkConfiguringPermission() internal view {
        if (
            _agentState.initiatedCreditCounter > 0 ||
            _agentState.pendingCreditCounter > 0 ||
            _agentState.initiatedInstallmentCreditCounter > 0 ||
            _agentState.pendingInstallmentCreditCounter > 0
        ) {
            revert CreditAgent_ConfiguringProhibited();
        }
    }

    /**
     * @dev Changes the configured state of this agent contract if necessary.
     */
    function _updateConfiguredState() internal {
        if (_lendingMarket != address(0) && _cashier != address(0)) {
            if (!_agentState.configured) {
                _agentState.configured = true;
            }
        } else {
            if (_agentState.configured) {
                _agentState.configured = false;
            }
        }
    }

    /**
     * @dev Changes the status of a credit with event emitting and counters updating.
     *
     * @param txId The unique identifier of the related cash-out operation.
     * @param credit The storage reference to the credit to be updated.
     * @param newStatus The current status of the credit.
     * @param oldStatus The previous status of the credit.
     */
    function _changeCreditStatus(
        bytes32 txId, // Tools: this comment prevents Prettier from formatting into a single line.
        Credit storage credit,
        CreditStatus newStatus,
        CreditStatus oldStatus
    ) internal {
        emit CreditStatusChanged(
            txId,
            credit.borrower,
            newStatus,
            oldStatus,
            credit.loanId,
            credit.programId,
            credit.durationInPeriods,
            credit.loanAmount,
            credit.loanAddon
        );

        unchecked {
            if (oldStatus == CreditStatus.Initiated) {
                _agentState.initiatedCreditCounter -= uint32(1);
            } else if (oldStatus == CreditStatus.Pending) {
                _agentState.pendingCreditCounter -= uint32(1);
            }
        }

        if (newStatus == CreditStatus.Initiated) {
            _agentState.initiatedCreditCounter += uint32(1);
        } else if (newStatus == CreditStatus.Pending) {
            _agentState.pendingCreditCounter += uint32(1);
        } else if (newStatus == CreditStatus.Nonexistent) {
            // Skip the other actions because the Credit structure will be deleted
            return;
        }

        credit.status = newStatus;
    }

    /**
     * @dev Changes the status of an installment credit with event emitting and counters updating.
     *
     * @param txId The unique identifier of the related cash-out operation.
     * @param installmentCredit The storage reference to the installment credit to be updated.
     * @param newStatus The current status of the credit.
     * @param oldStatus The previous status of the credit.
     */
    function _changeInstallmentCreditStatus(
        bytes32 txId, // Tools: this comment prevents Prettier from formatting into a single line.
        InstallmentCredit storage installmentCredit,
        CreditStatus newStatus,
        CreditStatus oldStatus
    ) internal {
        uint256 installmentCount = installmentCredit.durationsInPeriods.length;
        emit InstallmentCreditStatusChanged(
            txId,
            installmentCredit.borrower,
            newStatus,
            oldStatus,
            installmentCredit.firstInstallmentId,
            installmentCredit.programId,
            installmentCredit.durationsInPeriods[installmentCount - 1], // lastDurationInPeriods
            _sumArray(installmentCredit.borrowAmounts), // totalBorrowAmount
            _sumArray(installmentCredit.addonAmounts), // totalAddonAmount
            installmentCount
        );

        unchecked {
            if (oldStatus == CreditStatus.Initiated) {
                _agentState.initiatedInstallmentCreditCounter -= uint32(1);
            } else if (oldStatus == CreditStatus.Pending) {
                _agentState.pendingInstallmentCreditCounter -= uint32(1);
            }
        }

        if (newStatus == CreditStatus.Initiated) {
            _agentState.initiatedInstallmentCreditCounter += uint32(1);
        } else if (newStatus == CreditStatus.Pending) {
            _agentState.pendingInstallmentCreditCounter += uint32(1);
        } else if (newStatus == CreditStatus.Nonexistent) {
            // Skip the other actions because the Credit structure will be deleted
            return;
        }

        installmentCredit.status = newStatus;
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

        if (_processTakeInstallmentLoanFor(txId)) {
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

        if (_processChangeInstallmentCreditStatus(txId)) {
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

        if (_processRevokeInstallmentLoan(txId)) {
            return;
        }

        revert CreditAgent_FailedToProcessCashOutReversalAfter(txId);
    }

    /// @dev Calculates the sum of all elements in an memory array.
    /// @param values Array of amounts to sum.
    /// @return The total sum of all array elements.
    function _sumArray(uint64[] storage values) internal view returns (uint256) {
        uint256 len = values.length;
        uint256 sum = 0;
        for (uint256 i = 0; i < len; ++i) {
            sum += values[i];
        }
        return sum;
    }

    /**
     * @dev Stores an array of uint256 values to an array of uint32 values.
     * @param inputValues The array of uint256 values to convert.
     * @param storeValues The array of uint32 values to store.
     */
    function _storeToUint32Array(uint256[] calldata inputValues, uint32[] storage storeValues) internal {
        uint256 len = inputValues.length;
        for (uint256 i = 0; i < len; ++i) {
            storeValues.push(inputValues[i].toUint32());
        }
    }

    /**
     * @dev Stores an array of uint256 values to an array of uint64 values.
     * @param inputValues The array of uint256 values to convert.
     * @param storeValues The array of uint64 values to store.
     */
    function _storeToUint64Array(uint256[] calldata inputValues, uint64[] storage storeValues) internal {
        uint256 len = inputValues.length;
        for (uint256 i = 0; i < len; ++i) {
            storeValues.push(inputValues[i].toUint64());
        }
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
        bytes32 txId, // Tools: this comment prevents Prettier from formatting into a single line.
        address expectedAccount,
        uint256 expectedAmount
    ) internal view {
        ICashier.CashOutOperation memory operation = ICashier(_cashier).getCashOut(txId);
        if (operation.account != expectedAccount || operation.amount != expectedAmount) {
            revert CreditAgent_CashOutParametersInappropriate(txId);
        }
    }

    /**
     * @dev Tries to process the cash-out request before hook by taking a ordinary loan.
     *
     * @param txId The unique identifier of the related cash-out operation.
     * @return true if the operation was successful, false otherwise.
     */
    function _processTakeLoanFor(bytes32 txId) internal returns (bool) {
        Credit storage credit = _credits[txId];

        if (credit.status == CreditStatus.Nonexistent) {
            return false;
        }

        if (credit.status != CreditStatus.Initiated) {
            revert CreditAgent_CreditStatusInappropriate(txId, credit.status);
        }

        address borrower = credit.borrower;
        uint256 loanAmount = credit.loanAmount;

        _checkCashierCashOutState(txId, borrower, loanAmount);

        credit.loanId = ILendingMarket(_lendingMarket).takeLoanFor(
            borrower,
            credit.programId,
            loanAmount,
            credit.loanAddon,
            credit.durationInPeriods
        );

        _changeCreditStatus(
            txId,
            credit,
            CreditStatus.Pending, // newStatus
            CreditStatus.Initiated // oldStatus
        );

        return true;
    }

    /**
     * @dev Tries to process the cash-out request before hook by taking an installment loan.
     *
     * @param txId The unique identifier of the related cash-out operation.
     * @return true if the operation was successful, false otherwise.
     */
    function _processTakeInstallmentLoanFor(bytes32 txId) internal returns (bool) {
        InstallmentCredit storage installmentCredit = _installmentCredits[txId];

        if (installmentCredit.status == CreditStatus.Nonexistent) {
            return false;
        }

        if (installmentCredit.status != CreditStatus.Initiated) {
            revert CreditAgent_CreditStatusInappropriate(txId, installmentCredit.status);
        }

        address borrower = installmentCredit.borrower;

        _checkCashierCashOutState(txId, borrower, _sumArray(installmentCredit.borrowAmounts));

        (uint256 firstInstallmentId, ) = ILendingMarket(_lendingMarket).takeInstallmentLoanFor(
            borrower,
            installmentCredit.programId,
            _toUint256Array(installmentCredit.borrowAmounts),
            _toUint256Array(installmentCredit.addonAmounts),
            _toUint256Array(installmentCredit.durationsInPeriods)
        );

        installmentCredit.firstInstallmentId = firstInstallmentId;

        _changeInstallmentCreditStatus(
            txId,
            installmentCredit,
            CreditStatus.Pending, // newStatus
            CreditStatus.Initiated // oldStatus
        );

        return true;
    }

    /**
     * @dev Tries to process the cash-out confirmation after hook by changing the credit status to Confirmed.
     *
     * @param txId The unique identifier of the related cash-out operation.
     * @return true if the operation was successful, false otherwise.
     */
    function _processChangeCreditStatus(bytes32 txId) internal returns (bool) {
        Credit storage credit = _credits[txId];

        if (credit.status == CreditStatus.Nonexistent) {
            return false;
        }

        if (credit.status != CreditStatus.Pending) {
            revert CreditAgent_CreditStatusInappropriate(txId, credit.status);
        }

        _changeCreditStatus(
            txId,
            credit,
            CreditStatus.Confirmed, // newStatus
            CreditStatus.Pending // oldStatus
        );

        return true;
    }

    /**
     * @dev Tries to process the cash-out confirmation after hook by changing the installment credit status to Confirmed.
     *
     * @param txId The unique identifier of the related cash-out operation.
     * @return true if the operation was successful, false otherwise.
     */
    function _processChangeInstallmentCreditStatus(bytes32 txId) internal returns (bool) {
        InstallmentCredit storage installmentCredit = _installmentCredits[txId];

        if (installmentCredit.status == CreditStatus.Nonexistent) {
            return false;
        }

        if (installmentCredit.status != CreditStatus.Pending) {
            revert CreditAgent_CreditStatusInappropriate(txId, installmentCredit.status);
        }

        _changeInstallmentCreditStatus(
            txId,
            installmentCredit,
            CreditStatus.Confirmed, // newStatus
            CreditStatus.Pending // oldStatus
        );

        return true;
    }

    /**
     * @dev Tries to process the cash-out reversal after hook by revoking a ordinary loan.
     *
     * @param txId The unique identifier of the related cash-out operation.
     * @return true if the operation was successful, false otherwise.
     */
    function _processRevokeLoan(bytes32 txId) internal returns (bool) {
        Credit storage credit = _credits[txId];

        if (credit.status == CreditStatus.Nonexistent) {
            return false;
        }

        if (credit.status != CreditStatus.Pending) {
            revert CreditAgent_CreditStatusInappropriate(txId, credit.status);
        }

        ILendingMarket(_lendingMarket).revokeLoan(credit.loanId);

        _changeCreditStatus(
            txId,
            credit,
            CreditStatus.Reversed, // newStatus
            CreditStatus.Pending // oldStatus
        );

        return true;
    }

    /**
     * @dev Tries to process the cash-out reversal after hook by revoking an installment loan.
     *
     * @param txId The unique identifier of the related cash-out operation.
     * @return true if the operation was successful, false otherwise.
     */
    function _processRevokeInstallmentLoan(bytes32 txId) internal returns (bool) {
        InstallmentCredit storage installmentCredit = _installmentCredits[txId];

        if (installmentCredit.status == CreditStatus.Nonexistent) {
            return false;
        }

        if (installmentCredit.status != CreditStatus.Pending) {
            revert CreditAgent_CreditStatusInappropriate(txId, installmentCredit.status);
        }

        ILendingMarket(_lendingMarket).revokeInstallmentLoan(installmentCredit.firstInstallmentId);

        _changeInstallmentCreditStatus(
            txId,
            installmentCredit,
            CreditStatus.Reversed, // newStatus
            CreditStatus.Pending // oldStatus
        );

        return true;
    }

    /**
     * @dev The upgrade validation function for the UUPSExtUpgradeable contract.
     * @param newImplementation The address of the new implementation.
     */
    function _validateUpgrade(address newImplementation) internal view override onlyRole(OWNER_ROLE) {
        try ICreditAgentPrimary(newImplementation).proveCreditAgent() {} catch {
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
