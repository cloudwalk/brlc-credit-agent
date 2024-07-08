// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { PausableExtUpgradeable } from "./base/PausableExtUpgradeable.sol";
import { RescuableUpgradeable } from "./base/RescuableUpgradeable.sol";
import { AccessControlExtUpgradeable } from "./base/AccessControlExtUpgradeable.sol";

import { PixCreditAgentStorage } from "./PixCreditAgentStorage.sol";
import { SafeCast } from "./libraries/SafeCast.sol";

import { ILendingMarket } from "./interfaces/ILendingMarket.sol";
import { IPixCashier } from "./interfaces/IPixCashier.sol";
import { IPixCreditAgent } from "./interfaces/IPixCreditAgent.sol";
import { IPixCreditAgentConfiguration } from "./interfaces/IPixCreditAgent.sol";
import { IPixCreditAgentMain } from "./interfaces/IPixCreditAgent.sol";
import { IPixHook } from "./interfaces/IPixHook.sol";
import { IPixHookable } from "./interfaces/IPixHookable.sol";
import { IPixHookableTypes } from "./interfaces/IPixHookable.sol";

/**
 * @title PixCashier contract
 * @author CloudWalk Inc. (See https://cloudwalk.io)
 * @dev Wrapper contract for PIX cash-in and cash-out operations.
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
    IPixHook
{
    using SafeCast for uint256;

    // ------------------ Constants ------------------------------- //

    /// @dev The role of this contract owner.
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");

    /// @dev The role of admin that is allowed to configure the contract.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @dev The role of manager that is allowed to initialize and cancel PIX credit operations.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @dev The bit flags that represent the required hooks for PIX cash-out operations.
    uint256 private constant NEEDED_PIX_CASH_OUT_HOOK_FLAGS =
        (1 << uint256(IPixHookableTypes.HookIndex.CashOutRequestBefore)) +
        (1 << uint256(IPixHookableTypes.HookIndex.CashOutConfirmationAfter)) +
        (1 << uint256(IPixHookableTypes.HookIndex.CashOutReversalAfter));

    // ------------------ Errors ---------------------------------- //
    /// @dev The zero PIX off-chain transaction identifier has been passed as a function argument.
    error PixCreditAgent_PixTxIdZero();

    /// @dev The zero borrower address has been passed as a function argument.
    error PixCreditAgent_BorrowerAddressZero();

    /// @dev The zero program ID has been passed as a function argument.
    error PixCreditAgent_ProgramIdZero();

    /// @dev The zero loan amount has been passed as a function argument.
    error PixCreditAgent_LoanAmountZero();

    /// @dev The zero loan duration has been passed as a function argument.
    error PixCreditAgent_LoanDurationZero();

    /**
     * @dev The related PIX credit has inappropriate status to execute the requested operation.
     * @param pixTxId The PIX off-chain transaction identifiers of the operation.
     * @param status The current status of the credit.
     */
    error PixCreditAgent_PixCreditStatusInappropriate(bytes32 pixTxId, PixCreditStatus status);

    /// @dev The related PIX cash-out operation has inappropriate parameters (e.g. account, amount values).
    error PixCreditAgent_PixCashOutInappropriate(bytes32 pixTxId);

    /// @dev Configuring is prohibited due to at least one unprocessed PIX credit exists or other conditions.
    error PixCreditAgent_ConfiguringProhibited();

    /// @dev The value of a configuration parameter is the same as previously set one.
    error PixCreditAgent_AlreadyConfigured();

    /// @dev The caller is not allowed to execute the hook function.
    error PixCreditAgent_PixHookCallerUnauthorized(address caller);

    /// @dev This agent contract is not configured yet.
    error PixCreditAgent_ContractNotConfigured();

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
     * - The new PIX cashier contract address must differ from the previously set one.
     */
    function setPixCashier(address newPixCashier) external whenNotPaused onlyRole(ADMIN_ROLE) {
        _checkConfiguringPermission();
        address oldPixCashier = _pixCashier;
        if (oldPixCashier == newPixCashier) {
            revert PixCreditAgent_AlreadyConfigured();
        }

        _pixCashier = newPixCashier;
        _changeConfiguredState();

        emit PixCashierChanged(newPixCashier, oldPixCashier);
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
        _changeConfiguredState();

        emit LendingMarketChanged(newLendingMarket, oldLendingMarket);
    }

    /**
     * @inheritdoc IPixCreditAgentMain
     *
     * @dev Requirements:
     *
     * - The contract must not be paused.
     * - The caller must have the {MANAGER_ROLE} role.
     * - The contract must be configured.
     * - The provided `pixTxId`, `borrower`, `programId`, `durationInPeriods`, `loanAmount` must not be zeros.
     * - The PIX credit with the provided `pixTxId` must have the `Nonexistent` or `Reversed` status.
     */
    function initiatePixCredit(
        bytes32 pixTxId, // Tools: This comment prevents Prettier from formatting into a single line.
        address borrower,
        uint256 programId,
        uint256 durationInPeriods,
        uint256 loanAmount,
        uint256 loanAddon
    ) external whenNotPaused onlyRole(MANAGER_ROLE) {
        if (!_agentState.configured) {
            revert PixCreditAgent_ContractNotConfigured();
        }
        if (pixTxId == bytes32(0)) {
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

        PixCredit storage pixCredit = _pixCredits[pixTxId];
        if (pixCredit.status != PixCreditStatus.Nonexistent && pixCredit.status != PixCreditStatus.Reversed) {
            revert PixCreditAgent_PixCreditStatusInappropriate(pixTxId, pixCredit.status);
        }

        IPixHookable(_pixCashier).configureCashOutHooks(pixTxId, address(this), NEEDED_PIX_CASH_OUT_HOOK_FLAGS);

        pixCredit.borrower = borrower;
        pixCredit.programId = programId.toUint32();
        pixCredit.loanAmount = loanAmount.toUint64();
        pixCredit.loanAddon = loanAddon.toUint64();
        pixCredit.durationInPeriods = durationInPeriods.toUint32();

        if (pixCredit.loanId != 0) {
            pixCredit.loanId = 0;
        }

        _changePixCreditStatus(
            pixTxId,
            pixCredit,
            PixCreditStatus.Initiated, // newStatus
            PixCreditStatus.Nonexistent // oldStatus
        );
    }

    /**
     * @inheritdoc IPixCreditAgentMain
     *
     * @dev Requirements:
     *
     * - The contract must not be paused.
     * - The caller must have the {MANAGER_ROLE} role.
     * - The provided `pixTxId` must not be zero.
     * - The PIX credit with the provided `pixTxId` must have the `Initiated` status.
     */
    function revokePixCredit(bytes32 pixTxId) external whenNotPaused onlyRole(MANAGER_ROLE) {
        if (pixTxId == bytes32(0)) {
            revert PixCreditAgent_PixTxIdZero();
        }
        PixCredit storage pixCredit = _pixCredits[pixTxId];
        if (pixCredit.status != PixCreditStatus.Initiated) {
            revert PixCreditAgent_PixCreditStatusInappropriate(pixTxId, pixCredit.status);
        }

        IPixHookable(_pixCashier).configureCashOutHooks(pixTxId, address(0), 0);

        _changePixCreditStatus(
            pixTxId,
            pixCredit,
            PixCreditStatus.Nonexistent, // newStatus
            PixCreditStatus.Initiated // oldStatus
        );

        delete _pixCredits[pixTxId];
    }

    /**
     * @inheritdoc IPixHook
     *
     * @dev Requirements:
     *
     * - The contract must not be paused.
     * - The caller must be the configured PIX cashier contract.
     */
    function pixHook(uint256 hookIndex, bytes32 txId) external whenNotPaused {
        _checkPixHookCaller();
        if (hookIndex == uint256(IPixHookableTypes.HookIndex.CashOutRequestBefore)) {
            _processPixHookCashOutRequestBefore(txId);
        } else if (hookIndex == uint256(IPixHookableTypes.HookIndex.CashOutConfirmationAfter)) {
            _processPixHookCashOutConfirmationAfter(txId);
        } else if (hookIndex == uint256(IPixHookableTypes.HookIndex.CashOutReversalAfter)) {
            _processPixHookCashOutReversalAfter(txId);
        }
    }

    // ------------------ View functions -------------------------- //

    /**
     * @inheritdoc IPixCreditAgentConfiguration
     */
    function pixCashier() external view returns (address) {
        return _pixCashier;
    }

    /**
     * @inheritdoc IPixCreditAgentConfiguration
     */
    function lendingMarket() external view returns (address) {
        return _lendingMarket;
    }

    /**
     * @inheritdoc IPixCreditAgentMain
     */
    function getPixCredit(bytes32 pixTxId) external view returns (PixCredit memory) {
        return _pixCredits[pixTxId];
    }

    /**
     * @inheritdoc IPixCreditAgentMain
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
    function _changeConfiguredState() internal {
        if (_lendingMarket != address(0) && _pixCashier != address(0)) {
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
     * @param pixTxId The unique identifier of the related PIX cash-out operation.
     * @param pixCredit The storage reference to the PIX credit to be updated.
     * @param newStatus The current status of the credit.
     * @param oldStatus The previous status of the credit.
     */
    function _changePixCreditStatus(
        bytes32 pixTxId, // Tools: This comment prevents Prettier from formatting into a single line.
        PixCredit storage pixCredit,
        PixCreditStatus newStatus,
        PixCreditStatus oldStatus
    ) internal {
        emit PixCreditStatusChanged(
            pixTxId,
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
        } else if (newStatus == PixCreditStatus.Confirmed || newStatus == PixCreditStatus.Reversed) {
            _agentState.processedCreditCounter += uint64(1);
        } else {
            return;
        }

        pixCredit.status = newStatus;
    }

    /**
     * @dev Processes the PIX cash-out request before hook.
     *
     * @param pixTxId The unique identifier of the related PIX cash-out operation.
     */
    function _processPixHookCashOutRequestBefore(bytes32 pixTxId) internal {
        PixCredit storage pixCredit = _pixCredits[pixTxId];
        if (pixCredit.status != PixCreditStatus.Initiated) {
            revert PixCreditAgent_PixCreditStatusInappropriate(pixTxId, pixCredit.status);
        }

        address borrower = pixCredit.borrower;
        uint256 loanAmount = pixCredit.loanAmount;

        _checkPixCashOutState(pixTxId, borrower, loanAmount);

        pixCredit.loanId = ILendingMarket(_lendingMarket).takeLoanFor(
            borrower,
            pixCredit.programId,
            loanAmount,
            pixCredit.loanAddon,
            pixCredit.durationInPeriods
        );

        _changePixCreditStatus(
            pixTxId,
            pixCredit,
            PixCreditStatus.Pending, // newStatus
            PixCreditStatus.Initiated // oldStatus
        );
    }

    /**
     * @dev Processes the PIX cash-out confirmation after hook.
     *
     * @param pixTxId The unique identifier of the related PIX cash-out operation.
     */
    function _processPixHookCashOutConfirmationAfter(bytes32 pixTxId) internal {
        PixCredit storage pixCredit = _pixCredits[pixTxId];
        if (pixCredit.status != PixCreditStatus.Pending) {
            revert PixCreditAgent_PixCreditStatusInappropriate(pixTxId, pixCredit.status);
        }

        _changePixCreditStatus(
            pixTxId,
            pixCredit,
            PixCreditStatus.Confirmed, // newStatus
            PixCreditStatus.Pending // oldStatus
        );
    }

    /**
     * @dev Processes the PIX cash-out reversal after hook.
     *
     * @param pixTxId The unique identifier of the related PIX cash-out operation.
     */
    function _processPixHookCashOutReversalAfter(bytes32 pixTxId) internal {
        PixCredit storage pixCredit = _pixCredits[pixTxId];
        if (pixCredit.status != PixCreditStatus.Pending) {
            revert PixCreditAgent_PixCreditStatusInappropriate(pixTxId, pixCredit.status);
        }

        ILendingMarket(_lendingMarket).revokeLoan(pixCredit.loanId);

        _changePixCreditStatus(
            pixTxId,
            pixCredit,
            PixCreditStatus.Reversed, // newStatus
            PixCreditStatus.Pending // oldStatus
        );
    }

    /**
     * @dev Checks the caller of the hook function.
     */
    function _checkPixHookCaller() internal view {
        address sender = _msgSender();
        if (sender != _pixCashier) {
            revert PixCreditAgent_PixHookCallerUnauthorized(sender);
        }
    }

    /**
     * @dev Checks the state of a related PIX cash-out operation to be matched with the expected values.
     *
     * @param pixTxId The unique identifier of the related PIX cash-out operation.
     * @param expectedAccount The expected account of the PIX operation.
     * @param expectedAmount The expected amount of the PIX operation.
     */
    function _checkPixCashOutState(
        bytes32 pixTxId, // Tools: This comment prevents Prettier from formatting into a single line.
        address expectedAccount,
        uint256 expectedAmount
    ) internal view {
        (address actualAccount, uint256 actualAmount) = IPixCashier(_pixCashier).getCashOutAccountAndAmount(pixTxId);
        if (actualAccount != expectedAccount || actualAmount != expectedAmount) {
            revert PixCreditAgent_PixCashOutInappropriate(pixTxId);
        }
    }

    /**
     * @dev The upgrade authorization function for UUPSProxy.
     */
    function _authorizeUpgrade(address newImplementation) internal view override {
        newImplementation; // Suppresses a compiler warning about the unused variable
        _checkRole(OWNER_ROLE);
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
