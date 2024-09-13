// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { PausableExtUpgradeable } from "./base/PausableExtUpgradeable.sol";
import { RescuableUpgradeable } from "./base/RescuableUpgradeable.sol";
import { AccessControlExtUpgradeable } from "./base/AccessControlExtUpgradeable.sol";

import { PixCreditAgentStorage } from "./PixCreditAgentStorage.sol";
import { SafeCast } from "./libraries/SafeCast.sol";

import { ILendingMarket } from "./interfaces/ILendingMarket.sol";
import { ICashier } from "./interfaces/ICashier.sol";
import { IPixCreditAgent } from "./interfaces/IPixCreditAgent.sol";
import { IPixCreditAgentConfiguration } from "./interfaces/IPixCreditAgent.sol";
import { IPixCreditAgentPrimery } from "./interfaces/IPixCreditAgent.sol";
import { ICashierHook } from "./interfaces/ICashierHook.sol";
import { ICashierHookable } from "./interfaces/ICashierHookable.sol";
import { ICashierHookableTypes } from "./interfaces/ICashierHookable.sol";

/**
 * @title PixCreditAgent contract
 * @author CloudWalk Inc. (See https://cloudwalk.io)
 * @dev Wrapper contract for PIX credit operations.
 *
 * Only accounts that have {CASHIER_ROLE} role can execute the cash-in operations and process the cash-out operations.
 * About roles see https://docs.openzeppelin.com/contracts/4.x/api/access#AccessControl.
 */
contract PixCreditAgent is
    PixCreditAgentStorage,
    AccessControlExtUpgradeable,
    PausableExtUpgradeable,
    RescuableUpgradeable,
    UUPSUpgradeable,
    IPixCreditAgent,
    ICashierHook
{
    using SafeCast for uint256;

    // ------------------ Constants ------------------------------- //

    /// @dev The role of this contract owner.
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");

    /// @dev The role of admin that is allowed to configure the contract.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @dev The role of manager that is allowed to initialize and cancel PIX credit operations.
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
            revert PixCreditAgent_CashierHookCallerUnauthorized(_msgSender());
        }
        _;
    }

    // ------------------ Initializers ---------------------------- //

    /**
     * @dev The initialize function of the upgradable contract.
     * See details https://docs.openzeppelin.com/upgrades-plugins/1.x/writing-upgradeable
     */
    function initialize() external initializer {
        __PixCreditAgent_init();
    }

    /**
     * @dev The internal initializer of the upgradable contract.
     *
     * See {PixCreditAgent-initialize}.
     */
    function __PixCreditAgent_init() internal onlyInitializing {
        __Context_init_unchained();
        __ERC165_init_unchained();
        __AccessControl_init_unchained();
        __AccessControlExt_init_unchained();
        __Pausable_init_unchained();
        __PausableExt_init_unchained(OWNER_ROLE);
        __Rescuable_init_unchained(OWNER_ROLE);

        __PixCreditAgent_init_unchained();
    }

    /**
     * @dev The internal unchained initializer of the upgradable contract.
     *
     * See {PixCreditAgent-initialize}.
     */
    function __PixCreditAgent_init_unchained() internal onlyInitializing {
        _setRoleAdmin(OWNER_ROLE, OWNER_ROLE);
        _setRoleAdmin(ADMIN_ROLE, OWNER_ROLE);
        _setRoleAdmin(MANAGER_ROLE, OWNER_ROLE);

        _grantRole(OWNER_ROLE, _msgSender());
        _grantRole(ADMIN_ROLE, _msgSender());
    }

    // ------------------ Functions ------------------------------- //

    /**
     * @inheritdoc IPixCreditAgentConfiguration
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
            revert PixCreditAgent_AlreadyConfigured();
        }

        _cashier = newCashier;
        _updateConfiguredState();

        emit CashierChanged(newCashier, oldCashier);
    }

    /**
     * @inheritdoc IPixCreditAgentConfiguration
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
            revert PixCreditAgent_AlreadyConfigured();
        }

        _lendingMarket = newLendingMarket;
        _updateConfiguredState();

        emit LendingMarketChanged(newLendingMarket, oldLendingMarket);
    }

    /**
     * @inheritdoc IPixCreditAgentPrimery
     *
     * @dev Requirements:
     *
     * - The contract must not be paused.
     * - The caller must have the {MANAGER_ROLE} role.
     * - The contract must be configured.
     * - The provided `txId`, `borrower`, `programId`, `durationInPeriods`, `loanAmount` must not be zeros.
     * - The PIX credit with the provided `txId` must have the `Nonexistent` or `Reversed` status.
     */
    function initiatePixCredit(
        bytes32 txId, // Tools: this comment prevents Prettier from formatting into a single line.
        address borrower,
        uint256 programId,
        uint256 durationInPeriods,
        uint256 loanAmount,
        uint256 loanAddon
    ) external whenNotPaused onlyRole(MANAGER_ROLE) {
        if (!_agentState.configured) {
            revert PixCreditAgent_ContractNotConfigured();
        }
        if (txId == bytes32(0)) {
            revert PixCreditAgent_PixTxIdZero();
        }
        if (borrower == address(0)) {
            revert PixCreditAgent_BorrowerAddressZero();
        }
        if (programId == 0) {
            revert PixCreditAgent_ProgramIdZero();
        }
        if (durationInPeriods == 0) {
            revert PixCreditAgent_LoanDurationZero();
        }
        if (loanAmount == 0) {
            revert PixCreditAgent_LoanAmountZero();
        }

        PixCredit storage pixCredit = _pixCredits[txId];
        PixCreditStatus oldStatus = pixCredit.status;
        if (oldStatus != PixCreditStatus.Nonexistent && oldStatus != PixCreditStatus.Reversed) {
            revert PixCreditAgent_PixCreditStatusInappropriate(txId, oldStatus);
        }

        pixCredit.borrower = borrower;
        pixCredit.programId = programId.toUint32();
        pixCredit.loanAmount = loanAmount.toUint64();
        pixCredit.loanAddon = loanAddon.toUint64();
        pixCredit.durationInPeriods = durationInPeriods.toUint32();

        if (oldStatus != PixCreditStatus.Nonexistent) {
            pixCredit.loanId = 0;
        }

        _changePixCreditStatus(
            txId,
            pixCredit,
            PixCreditStatus.Initiated, // newStatus
            PixCreditStatus.Nonexistent // oldStatus
        );

        ICashierHookable(_cashier).configureCashOutHooks(txId, address(this), REQUIRED_CASHIER_CASH_OUT_HOOK_FLAGS);
    }

    /**
     * @inheritdoc IPixCreditAgentPrimery
     *
     * @dev Requirements:
     *
     * - The contract must not be paused.
     * - The caller must have the {MANAGER_ROLE} role.
     * - The provided `txId` must not be zero.
     * - The PIX credit with the provided `txId` must have the `Initiated` status.
     */
    function revokePixCredit(bytes32 txId) external whenNotPaused onlyRole(MANAGER_ROLE) {
        if (txId == bytes32(0)) {
            revert PixCreditAgent_PixTxIdZero();
        }

        PixCredit storage pixCredit = _pixCredits[txId];
        if (pixCredit.status != PixCreditStatus.Initiated) {
            revert PixCreditAgent_PixCreditStatusInappropriate(txId, pixCredit.status);
        }

        _changePixCreditStatus(
            txId,
            pixCredit,
            PixCreditStatus.Nonexistent, // newStatus
            PixCreditStatus.Initiated // oldStatus
        );

        delete _pixCredits[txId];

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
            revert PixCreditAgent_CashierHookIndexUnexpected(hookIndex, txId, _msgSender());
        }
    }

    // ------------------ View functions -------------------------- //

    /**
     * @inheritdoc IPixCreditAgentConfiguration
     */
    function cashier() external view returns (address) {
        return _cashier;
    }

    /**
     * @inheritdoc IPixCreditAgentConfiguration
     */
    function lendingMarket() external view returns (address) {
        return _lendingMarket;
    }

    /**
     * @inheritdoc IPixCreditAgentPrimery
     */
    function getPixCredit(bytes32 txId) external view returns (PixCredit memory) {
        return _pixCredits[txId];
    }

    /**
     * @inheritdoc IPixCreditAgentPrimery
     */
    function agentState() external view returns (AgentState memory) {
        return _agentState;
    }

    // ------------------ Internal functions ---------------------- //

    /**
     * @dev Checks the permission to configure this agent contract.
     */
    function _checkConfiguringPermission() internal view {
        if (_agentState.initiatedCreditCounter > 0 || _agentState.pendingCreditCounter > 0) {
            revert PixCreditAgent_ConfiguringProhibited();
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
     * @dev Changes the status of a PIX credit with event emitting and counters updating.
     *
     * @param txId The unique identifier of the related cash-out operation.
     * @param pixCredit The storage reference to the credit to be updated.
     * @param newStatus The current status of the credit.
     * @param oldStatus The previous status of the credit.
     */
    function _changePixCreditStatus(
        bytes32 txId, // Tools: this comment prevents Prettier from formatting into a single line.
        PixCredit storage pixCredit,
        PixCreditStatus newStatus,
        PixCreditStatus oldStatus
    ) internal {
        emit PixCreditStatusChanged(
            txId,
            pixCredit.borrower,
            newStatus,
            oldStatus,
            pixCredit.loanId,
            pixCredit.programId,
            pixCredit.durationInPeriods,
            pixCredit.loanAmount,
            pixCredit.loanAddon
        );

        unchecked {
            if (oldStatus == PixCreditStatus.Initiated) {
                _agentState.initiatedCreditCounter -= uint64(1);
            } else if (oldStatus == PixCreditStatus.Pending) {
                _agentState.pendingCreditCounter -= uint64(1);
            }
        }

        if (newStatus == PixCreditStatus.Initiated) {
            _agentState.initiatedCreditCounter += uint64(1);
        } else if (newStatus == PixCreditStatus.Pending) {
            _agentState.pendingCreditCounter += uint64(1);
        } else if (newStatus == PixCreditStatus.Nonexistent) {
            // Skip the other actions because the PixCredit structure will be deleted
            return;
        }

        pixCredit.status = newStatus;
    }

    /**
     * @dev Processes the cash-out request before hook.
     *
     * @param txId The unique identifier of the related cash-out operation.
     */
    function _processCashierHookCashOutRequestBefore(bytes32 txId) internal {
        PixCredit storage pixCredit = _pixCredits[txId];
        if (pixCredit.status != PixCreditStatus.Initiated) {
            revert PixCreditAgent_PixCreditStatusInappropriate(txId, pixCredit.status);
        }

        address borrower = pixCredit.borrower;
        uint256 loanAmount = pixCredit.loanAmount;

        _checkCashierCashOutState(txId, borrower, loanAmount);

        pixCredit.loanId = ILendingMarket(_lendingMarket).takeLoanFor(
            borrower,
            pixCredit.programId,
            loanAmount,
            pixCredit.loanAddon,
            pixCredit.durationInPeriods
        );

        _changePixCreditStatus(
            txId,
            pixCredit,
            PixCreditStatus.Pending, // newStatus
            PixCreditStatus.Initiated // oldStatus
        );
    }

    /**
     * @dev Processes the cash-out confirmation after hook.
     *
     * @param txId The unique identifier of the related cash-out operation.
     */
    function _processCashierHookCashOutConfirmationAfter(bytes32 txId) internal {
        PixCredit storage pixCredit = _pixCredits[txId];
        if (pixCredit.status != PixCreditStatus.Pending) {
            revert PixCreditAgent_PixCreditStatusInappropriate(txId, pixCredit.status);
        }

        _changePixCreditStatus(
            txId,
            pixCredit,
            PixCreditStatus.Confirmed, // newStatus
            PixCreditStatus.Pending // oldStatus
        );
    }

    /**
     * @dev Processes the cash-out reversal after hook.
     *
     * @param txId The unique identifier of the related cash-out operation.
     */
    function _processCashierHookCashOutReversalAfter(bytes32 txId) internal {
        PixCredit storage pixCredit = _pixCredits[txId];
        if (pixCredit.status != PixCreditStatus.Pending) {
            revert PixCreditAgent_PixCreditStatusInappropriate(txId, pixCredit.status);
        }

        ILendingMarket(_lendingMarket).revokeLoan(pixCredit.loanId);

        _changePixCreditStatus(
            txId,
            pixCredit,
            PixCreditStatus.Reversed, // newStatus
            PixCreditStatus.Pending // oldStatus
        );
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
            revert PixCreditAgent_CashierCashOutInappropriate(txId);
        }
    }

    /**
     * @dev The upgrade authorization function for UUPSProxy.
     */
    function _authorizeUpgrade(address newImplementation) internal view override onlyRole(OWNER_ROLE) {
        newImplementation; // Suppresses a compiler warning about the unused variable
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
