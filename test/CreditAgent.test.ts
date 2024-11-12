import { ethers, network, upgrades } from "hardhat";
import { expect } from "chai";
import { Contract, ContractFactory, TransactionResponse } from "ethers";
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { checkContractUupsUpgrading, connect, getAddress, proveTx } from "../test-utils/eth";

const ADDRESS_ZERO = ethers.ZeroAddress;

enum CreditStatus {
  Nonexistent = 0,
  Initiated = 1,
  Pending = 2,
  Confirmed = 3,
  Reversed = 4
}

enum HookIndex {
  Unused = 1,
  CashOutRequestBefore = 6,
  CashOutConfirmationAfter = 9,
  CashOutReversalAfter = 11
}

interface Credit {
  borrower: string;
  programId: number;
  durationInPeriods: number;
  status: CreditStatus;
  loanAmount: bigint;
  loanAddon: bigint;
  loanId: bigint;

  // Indexing signature to ensure that fields are iterated over in a key-value style
  [key: string]: bigint | string | number;
}

interface Fixture {
  creditAgent: Contract;
  cashierMock: Contract;
  lendingMarketMock: Contract;
  loanIdStub: bigint;
}

interface AgentState {
  configured: boolean;
  initiatedCreditCounter: bigint;
  pendingCreditCounter: bigint;

  // Indexing signature to ensure that fields are iterated over in a key-value style
  [key: string]: bigint | boolean;
}

interface CashOut {
  account: string;
  amount: bigint;
  status: number;
  flags: number;
}

interface Version {
  major: number;
  minor: number;
  patch: number;

  [key: string]: number; // Indexing signature to ensure that fields are iterated over in a key-value style
}

const initialAgentState: AgentState = {
  configured: false,
  initiatedCreditCounter: 0n,
  pendingCreditCounter: 0n
};

const initialCredit: Credit = {
  borrower: ADDRESS_ZERO,
  programId: 0,
  durationInPeriods: 0,
  status: CreditStatus.Nonexistent,
  loanAmount: 0n,
  loanAddon: 0n,
  loanId: 0n
};

const initialCashOut: CashOut = {
  account: ADDRESS_ZERO,
  amount: 0n,
  status: 0,
  flags: 0
};

function checkEquality<T extends Record<string, unknown>>(actualObject: T, expectedObject: T) {
  Object.keys(expectedObject).forEach(property => {
    const value = actualObject[property];
    if (typeof value === "undefined" || typeof value === "function" || typeof value === "object") {
      throw Error(`Property "${property}" is not found`);
    }
    expect(value).to.eq(
      expectedObject[property],
      `Mismatch in the "${property}" property`
    );
  });
}

async function setUpFixture<T>(func: () => Promise<T>): Promise<T> {
  if (network.name === "hardhat") {
    return loadFixture(func);
  } else {
    return func();
  }
}

describe("Contract 'CreditAgent'", async () => {
  const TX_ID_STUB = ethers.encodeBytes32String("STUB_TRANSACTION_ID1");
  const TX_ID_ZERO = ethers.ZeroHash;
  const LOAN_PROGRAM_ID_STUB = 0xFFFF_ABCD;
  const LOAN_DURATION_IN_SECONDS_STUB = 0xFFFF_DCBA;
  const LOAN_AMOUNT_STUB: bigint = BigInt("0xFFFFFFFFFFFF1234");
  const LOAN_ADDON_STUB: bigint = BigInt("0xFFFFFFFFFFFF4321");
  const NEEDED_CASHIER_CASH_OUT_HOOK_FLAGS =
    (1 << HookIndex.CashOutRequestBefore) +
    (1 << HookIndex.CashOutConfirmationAfter) +
    (1 << HookIndex.CashOutReversalAfter);
  const EXPECTED_VERSION: Version = {
    major: 1,
    minor: 0,
    patch: 0
  };

  // Errors of the lib contracts
  const REVERT_ERROR_IF_CONTRACT_INITIALIZATION_IS_INVALID = "InvalidInitialization";
  const REVERT_ERROR_IF_CONTRACT_IS_PAUSED = "EnforcedPause";
  const REVERT_ERROR_IF_UNAUTHORIZED_ACCOUNT = "AccessControlUnauthorizedAccount";

  // Errors of the contracts under test
  const REVERT_ERROR_IF_ALREADY_CONFIGURED = "CreditAgent_AlreadyConfigured";
  const REVERT_ERROR_IF_BORROWER_ADDRESS_ZERO = "CreditAgent_BorrowerAddressZero";
  const REVERT_ERROR_IF_CASH_OUT_PARAMETERS_INAPPROPRIATE = "CreditAgent_CashOutParametersInappropriate";
  const REVERT_ERROR_IF_CASHIER_HOOK_CALLER_UNAUTHORIZED = "CreditAgent_CashierHookCallerUnauthorized";
  const REVERT_ERROR_IF_CASHIER_HOOK_INDEX_UNEXPECTED = "CreditAgent_CashierHookIndexUnexpected";
  const REVERT_ERROR_IF_CONFIGURING_PROHIBITED = "CreditAgent_ConfiguringProhibited";
  const REVERT_ERROR_IF_CONTRACT_NOT_CONFIGURED = "CreditAgent_ContractNotConfigured";
  const REVERT_ERROR_IF_CREDIT_STATUS_INAPPROPRIATE = "CreditAgent_CreditStatusInappropriate";
  const REVERT_ERROR_IF_IMPLEMENTATION_ADDRESS_INVALID = "CreditAgent_ImplementationAddressInvalid";
  const REVERT_ERROR_IF_LOAN_AMOUNT_ZERO = "CreditAgent_LoanAmountZero";
  const REVERT_ERROR_IF_LOAN_DURATION_ZERO = "CreditAgent_LoanDurationZero";
  const REVERT_ERROR_IF_PROGRAM_ID_ZERO = "CreditAgent_ProgramIdZero";
  const REVERT_ERROR_IF_SAFE_CAST_OVERFLOWED_UINT_DOWNCAST = "SafeCast_OverflowedUintDowncast";
  const REVERT_ERROR_IF_TX_ID_ZERO = "CreditAgent_TxIdZero";

  const EVENT_NAME_MOCK_CONFIGURE_CASH_OUT_HOOKS_CALLED = "MockConfigureCashOutHooksCalled";
  const EVENT_NAME_MOCK_REVOKE_LOAN_CALLED = "MockRevokeLoanCalled";
  const EVENT_NAME_MOCK_TAKE_LOAN_FOR_CALLED = "MockTakeLoanForCalled";
  const EVENT_NAME_LENDING_MARKET_CHANGED = "LendingMarketChanged";
  const EVENT_NAME_CASHIER_CHANGED = "CashierChanged";
  const EVENT_NAME_CREDIT_STATUS_CHANGED = "CreditStatusChanged";

  let creditAgentFactory: ContractFactory;
  let cashierMockFactory: ContractFactory;
  let lendingMarketMockFactory: ContractFactory;
  let deployer: HardhatEthersSigner;
  let admin: HardhatEthersSigner;
  let manager: HardhatEthersSigner;
  let borrower: HardhatEthersSigner;

  const ownerRole: string = ethers.id("OWNER_ROLE");
  const pauserRole: string = ethers.id("PAUSER_ROLE");
  const rescuerRole: string = ethers.id("RESCUER_ROLE");
  const adminRole: string = ethers.id("ADMIN_ROLE");
  const managerRole: string = ethers.id("MANAGER_ROLE");

  before(async () => {
    creditAgentFactory = await ethers.getContractFactory("CreditAgent");
    cashierMockFactory = await ethers.getContractFactory("CashierMock");
    lendingMarketMockFactory = await ethers.getContractFactory("LendingMarketMock");

    [deployer, admin, manager, borrower] = await ethers.getSigners();
  });

  async function deployCashierMock(): Promise<Contract> {
    const cashierMock: Contract = await cashierMockFactory.deploy() as Contract;
    await cashierMock.waitForDeployment();

    return cashierMock;
  }

  async function deployLendingMarketMock(): Promise<Contract> {
    const lendingMarketMock: Contract = await lendingMarketMockFactory.deploy() as Contract;
    await lendingMarketMock.waitForDeployment();

    return lendingMarketMock;
  }

  async function deployCreditAgent(): Promise<Contract> {
    const creditAgent: Contract = await upgrades.deployProxy(creditAgentFactory);
    await creditAgent.waitForDeployment();

    return creditAgent;
  }

  async function deployAndConfigureCreditAgent(): Promise<Contract> {
    const creditAgent: Contract = await deployCreditAgent();
    await proveTx(creditAgent.grantRole(adminRole, admin.address));
    await proveTx(creditAgent.grantRole(managerRole, manager.address));
    await proveTx(creditAgent.grantRole(pauserRole, deployer.address));

    return creditAgent;
  }

  async function deployAndConfigureContracts(): Promise<Fixture> {
    const cashierMock = await deployCashierMock();
    const lendingMarketMock = await deployLendingMarketMock();
    const creditAgent = await deployAndConfigureCreditAgent();

    await proveTx(creditAgent.setCashier(getAddress(cashierMock)));
    await proveTx(creditAgent.setLendingMarket(getAddress(lendingMarketMock)));
    const loanIdStub = await lendingMarketMock.LOAN_ID_STAB();

    return { creditAgent, cashierMock, lendingMarketMock, loanIdStub };
  }

  async function deployAndConfigureContractsThenInitiateCredit(): Promise<{
    fixture: Fixture;
    txId: string;
    initCredit: Credit;
    initCashOut: CashOut;
  }> {
    const fixture = await deployAndConfigureContracts();
    const { creditAgent, cashierMock } = fixture;
    const initCredit = defineCredit();
    const txId = TX_ID_STUB;
    const initCashOut: CashOut = {
      ...initialCashOut,
      account: borrower.address,
      amount: initCredit.loanAmount
    };

    await proveTx(initiateCredit(creditAgent, { txId }));
    await proveTx(cashierMock.setCashOut(txId, initCashOut));

    return { fixture, txId, initCredit, initCashOut };
  }

  function defineCredit(props: {
    borrowerAddress?: string;
    programId?: number;
    durationInPeriods?: number;
    status?: CreditStatus;
    loanAmount?: bigint;
    loanAddon?: bigint;
    loanId?: bigint;
  } = {}): Credit {
    const borrowerAddress: string = props.borrowerAddress ?? borrower.address;
    const programId: number = props.programId ?? LOAN_PROGRAM_ID_STUB;
    const durationInPeriods: number = props.durationInPeriods ?? LOAN_DURATION_IN_SECONDS_STUB;
    const status = props.status ?? CreditStatus.Nonexistent;
    const loanAmount = props.loanAmount ?? LOAN_AMOUNT_STUB;
    const loanAddon = props.loanAddon ?? LOAN_ADDON_STUB;
    const loanId = props.loanId ?? 0n;
    return {
      borrower: borrowerAddress,
      programId,
      durationInPeriods,
      status,
      loanAmount,
      loanAddon,
      loanId
    };
  }

  function initiateCredit(creditAgent: Contract, props: {
    txId?: string;
    credit?: Credit;
    caller?: HardhatEthersSigner;
  } = {}): Promise<TransactionResponse> {
    const caller = props.caller ?? manager;
    const txId = props.txId ?? TX_ID_STUB;
    const credit = props.credit ?? defineCredit();
    return connect(creditAgent, caller).initiateCredit(
      txId,
      credit.borrower,
      credit.programId,
      credit.durationInPeriods,
      credit.loanAmount,
      credit.loanAddon
    );
  }

  async function checkCreditInitiation(fixture: Fixture, props: {
    tx: Promise<TransactionResponse>;
    txId: string;
    credit: Credit;
  }) {
    const { creditAgent, cashierMock } = fixture;
    const { tx, txId, credit } = props;
    await expect(tx).to.emit(creditAgent, EVENT_NAME_CREDIT_STATUS_CHANGED).withArgs(
      txId,
      credit.borrower,
      CreditStatus.Initiated, // newStatus
      CreditStatus.Nonexistent, // oldStatus
      credit.loanId,
      credit.programId,
      credit.durationInPeriods,
      credit.loanAmount,
      credit.loanAddon
    );
    await expect(tx).to.emit(cashierMock, EVENT_NAME_MOCK_CONFIGURE_CASH_OUT_HOOKS_CALLED).withArgs(
      txId,
      getAddress(creditAgent), // newCallableContract,
      NEEDED_CASHIER_CASH_OUT_HOOK_FLAGS // newHookFlags
    );
    credit.status = CreditStatus.Initiated;
    checkEquality(await creditAgent.getCredit(txId) as Credit, credit);
  }

  describe("Function 'initialize()'", async () => {
    it("Configures the contract as expected", async () => {
      const creditAgent = await setUpFixture(deployCreditAgent);

      // Role hashes
      expect(await creditAgent.OWNER_ROLE()).to.equal(ownerRole);
      expect(await creditAgent.PAUSER_ROLE()).to.equal(pauserRole);
      expect(await creditAgent.RESCUER_ROLE()).to.equal(rescuerRole);
      expect(await creditAgent.ADMIN_ROLE()).to.equal(adminRole);
      expect(await creditAgent.MANAGER_ROLE()).to.equal(managerRole);

      // The role admins
      expect(await creditAgent.getRoleAdmin(ownerRole)).to.equal(ownerRole);
      expect(await creditAgent.getRoleAdmin(pauserRole)).to.equal(ownerRole);
      expect(await creditAgent.getRoleAdmin(rescuerRole)).to.equal(ownerRole);
      expect(await creditAgent.getRoleAdmin(adminRole)).to.equal(ownerRole);
      expect(await creditAgent.getRoleAdmin(managerRole)).to.equal(ownerRole);

      // The deployer should have the owner role and admin role, but not the other roles
      expect(await creditAgent.hasRole(ownerRole, deployer.address)).to.equal(true);
      expect(await creditAgent.hasRole(adminRole, deployer.address)).to.equal(true);
      expect(await creditAgent.hasRole(pauserRole, deployer.address)).to.equal(false);
      expect(await creditAgent.hasRole(rescuerRole, deployer.address)).to.equal(false);
      expect(await creditAgent.hasRole(managerRole, deployer.address)).to.equal(false);

      // The initial contract state is unpaused
      expect(await creditAgent.paused()).to.equal(false);

      // The initial settings
      expect(await creditAgent.cashier()).to.equal(ADDRESS_ZERO);
      expect(await creditAgent.lendingMarket()).to.equal(ADDRESS_ZERO);
      checkEquality(await creditAgent.agentState() as AgentState, initialAgentState);
    });

    it("Is reverted if it is called a second time", async () => {
      const creditAgent = await setUpFixture(deployCreditAgent);
      await expect(
        creditAgent.initialize()
      ).to.be.revertedWithCustomError(creditAgent, REVERT_ERROR_IF_CONTRACT_INITIALIZATION_IS_INVALID);
    });
  });

  describe("Function '$__VERSION()'", async () => {
    it("Returns expected values", async () => {
      const creditAgent = await setUpFixture(deployCreditAgent);
      const creditAgentVersion = await creditAgent.$__VERSION();
      checkEquality(creditAgentVersion, EXPECTED_VERSION);
    });
  });

  describe("Function 'upgradeToAndCall()'", async () => {
    it("Executes as expected", async () => {
      const creditAgent = await setUpFixture(deployCreditAgent);
      await checkContractUupsUpgrading(creditAgent, creditAgentFactory);
    });

    it("Is reverted if the caller is not the owner", async () => {
      const creditAgent = await setUpFixture(deployCreditAgent);

      await expect(connect(creditAgent, admin).upgradeToAndCall(creditAgent, "0x"))
        .to.be.revertedWithCustomError(creditAgent, REVERT_ERROR_IF_UNAUTHORIZED_ACCOUNT);
    });
  });

  describe("Function 'upgradeTo()'", async () => {
    it("Executes as expected", async () => {
      const creditAgent = await setUpFixture(deployCreditAgent);
      await checkContractUupsUpgrading(creditAgent, creditAgentFactory, "upgradeTo(address)");
    });

    it("Is reverted if the caller is not the owner", async () => {
      const creditAgent = await setUpFixture(deployCreditAgent);

      await expect(connect(creditAgent, admin).upgradeTo(creditAgent))
        .to.be.revertedWithCustomError(creditAgent, REVERT_ERROR_IF_UNAUTHORIZED_ACCOUNT);
    });

    it("Is reverted if the provided implementation address is not a credit agent contract", async () => {
      const { creditAgent, cashierMock } = await setUpFixture(deployAndConfigureContracts);

      await expect(creditAgent.upgradeTo(cashierMock))
        .to.be.revertedWithCustomError(creditAgent, REVERT_ERROR_IF_IMPLEMENTATION_ADDRESS_INVALID);
    });
  });

  describe("Function 'setCashier()'", async () => {
    it("Executes as expected in different cases", async () => {
      const creditAgent = await setUpFixture(deployAndConfigureCreditAgent);
      const cashierStubAddress1 = borrower.address;
      const cashierStubAddress2 = admin.address;

      expect(await creditAgent.cashier()).to.equal(ADDRESS_ZERO);

      // Change the initial configuration
      await expect(
        connect(creditAgent, admin).setCashier(cashierStubAddress1)
      ).to.emit(
        creditAgent,
        EVENT_NAME_CASHIER_CHANGED
      ).withArgs(
        cashierStubAddress1,
        ADDRESS_ZERO
      );
      expect(await creditAgent.cashier()).to.equal(cashierStubAddress1);
      checkEquality(await creditAgent.agentState() as AgentState, initialAgentState);

      // Change to a new non-zero address
      await expect(
        connect(creditAgent, admin).setCashier(cashierStubAddress2)
      ).to.emit(
        creditAgent,
        EVENT_NAME_CASHIER_CHANGED
      ).withArgs(
        cashierStubAddress2,
        cashierStubAddress1
      );
      expect(await creditAgent.cashier()).to.equal(cashierStubAddress2);
      checkEquality(await creditAgent.agentState() as AgentState, initialAgentState);

      // Set the zero address
      await expect(
        connect(creditAgent, admin).setCashier(ADDRESS_ZERO)
      ).to.emit(
        creditAgent,
        EVENT_NAME_CASHIER_CHANGED
      ).withArgs(
        ADDRESS_ZERO,
        cashierStubAddress2
      );
      expect(await creditAgent.cashier()).to.equal(ADDRESS_ZERO);
      checkEquality(await creditAgent.agentState() as AgentState, initialAgentState);

      // Set the lending market address, then the cashier address to check the logic of configured status
      const lendingMarketStubAddress = borrower.address;
      await proveTx(connect(creditAgent, admin).setLendingMarket(lendingMarketStubAddress));
      await proveTx(connect(creditAgent, admin).setCashier(cashierStubAddress1));
      expect(await creditAgent.cashier()).to.equal(cashierStubAddress1);
      const expectedAgentState = { ...initialAgentState, configured: true };
      checkEquality(await creditAgent.agentState() as AgentState, expectedAgentState);

      // Set another cashier address must not change the configured status of the agent contract
      await proveTx(connect(creditAgent, admin).setCashier(cashierStubAddress2));
      expect(await creditAgent.cashier()).to.equal(cashierStubAddress2);
      checkEquality(await creditAgent.agentState() as AgentState, expectedAgentState);

      // Resetting the address must change the configured status appropriately
      await proveTx(connect(creditAgent, admin).setCashier(ADDRESS_ZERO));
      expectedAgentState.configured = false;
      checkEquality(await creditAgent.agentState() as AgentState, expectedAgentState);
    });

    it("Is reverted if the contract is paused", async () => {
      const creditAgent = await setUpFixture(deployAndConfigureCreditAgent);
      const cashierMockAddress = borrower.address;

      await proveTx(creditAgent.pause());
      await expect(
        connect(creditAgent, admin).setCashier(cashierMockAddress)
      ).to.be.revertedWithCustomError(creditAgent, REVERT_ERROR_IF_CONTRACT_IS_PAUSED);
    });

    it("Is reverted if the caller does not have the admin role", async () => {
      const creditAgent = await setUpFixture(deployAndConfigureCreditAgent);
      const cashierMockAddress = borrower.address;

      await expect(
        connect(creditAgent, manager).setCashier(cashierMockAddress)
      ).to.be.revertedWithCustomError(
        creditAgent,
        REVERT_ERROR_IF_UNAUTHORIZED_ACCOUNT
      ).withArgs(manager.address, adminRole);
    });

    it("Is reverted if the configuration is unchanged", async () => {
      const creditAgent = await setUpFixture(deployAndConfigureCreditAgent);
      const cashierMockAddress = borrower.address;

      // Try to set the default value
      await expect(
        connect(creditAgent, admin).setCashier(ADDRESS_ZERO)
      ).to.be.revertedWithCustomError(creditAgent, REVERT_ERROR_IF_ALREADY_CONFIGURED);

      // Try to set the same value twice
      await proveTx(connect(creditAgent, admin).setCashier(cashierMockAddress));
      await expect(
        connect(creditAgent, admin).setCashier(cashierMockAddress)
      ).to.be.revertedWithCustomError(creditAgent, REVERT_ERROR_IF_ALREADY_CONFIGURED);
    });

    // Additional more complex checks are in the other sections
  });

  describe("Function 'setLendingMarket()'", async () => {
    it("Executes as expected in different cases", async () => {
      const creditAgent = await setUpFixture(deployAndConfigureCreditAgent);
      const lendingMarketStubAddress1 = borrower.address;
      const lendingMarketStubAddress2 = admin.address;

      expect(await creditAgent.lendingMarket()).to.equal(ADDRESS_ZERO);

      // Change the initial configuration
      await expect(
        connect(creditAgent, admin).setLendingMarket(lendingMarketStubAddress1)
      ).to.emit(
        creditAgent,
        EVENT_NAME_LENDING_MARKET_CHANGED
      ).withArgs(
        lendingMarketStubAddress1,
        ADDRESS_ZERO
      );
      expect(await creditAgent.lendingMarket()).to.equal(lendingMarketStubAddress1);
      checkEquality(await creditAgent.agentState() as AgentState, initialAgentState);

      // Change to a new non-zero address
      await expect(
        connect(creditAgent, admin).setLendingMarket(lendingMarketStubAddress2)
      ).to.emit(
        creditAgent,
        EVENT_NAME_LENDING_MARKET_CHANGED
      ).withArgs(
        lendingMarketStubAddress2,
        lendingMarketStubAddress1
      );
      expect(await creditAgent.lendingMarket()).to.equal(lendingMarketStubAddress2);
      checkEquality(await creditAgent.agentState() as AgentState, initialAgentState);

      // Set the zero address
      await expect(
        connect(creditAgent, admin).setLendingMarket(ADDRESS_ZERO)
      ).to.emit(
        creditAgent,
        EVENT_NAME_LENDING_MARKET_CHANGED
      ).withArgs(
        ADDRESS_ZERO,
        lendingMarketStubAddress2
      );
      expect(await creditAgent.lendingMarket()).to.equal(ADDRESS_ZERO);
      checkEquality(await creditAgent.agentState() as AgentState, initialAgentState);

      // Set the cashier address, then the lending market address to check the logic of configured status
      const cashierStubAddress = borrower.address;
      await proveTx(connect(creditAgent, admin).setCashier(cashierStubAddress));
      await proveTx(connect(creditAgent, admin).setLendingMarket(lendingMarketStubAddress1));
      expect(await creditAgent.lendingMarket()).to.equal(lendingMarketStubAddress1);
      const expectedAgentState = { ...initialAgentState, configured: true };
      checkEquality(await creditAgent.agentState() as AgentState, expectedAgentState);

      // Set another lending market address must not change the configured status of the agent contract
      await proveTx(connect(creditAgent, admin).setLendingMarket(lendingMarketStubAddress2));
      expect(await creditAgent.lendingMarket()).to.equal(lendingMarketStubAddress2);
      checkEquality(await creditAgent.agentState() as AgentState, expectedAgentState);

      // Resetting the address must change the configured status appropriately
      await proveTx(connect(creditAgent, admin).setLendingMarket(ADDRESS_ZERO));
      expectedAgentState.configured = false;
      checkEquality(await creditAgent.agentState() as AgentState, expectedAgentState);
    });

    it("Is reverted if the contract is paused", async () => {
      const creditAgent = await setUpFixture(deployAndConfigureCreditAgent);
      const lendingMarketMockAddress = borrower.address;

      await proveTx(creditAgent.pause());
      await expect(
        connect(creditAgent, admin).setLendingMarket(lendingMarketMockAddress)
      ).to.be.revertedWithCustomError(creditAgent, REVERT_ERROR_IF_CONTRACT_IS_PAUSED);
    });

    it("Is reverted if the caller does not have the admin role", async () => {
      const creditAgent = await setUpFixture(deployAndConfigureCreditAgent);
      const lendingMarketMockAddress = borrower.address;

      await expect(
        connect(creditAgent, manager).setLendingMarket(lendingMarketMockAddress)
      ).to.be.revertedWithCustomError(
        creditAgent,
        REVERT_ERROR_IF_UNAUTHORIZED_ACCOUNT
      ).withArgs(manager.address, adminRole);
    });

    it("Is reverted if the configuration is unchanged", async () => {
      const creditAgent = await setUpFixture(deployAndConfigureCreditAgent);
      const lendingMarketMockAddress = borrower.address;

      // Try to set the default value
      await expect(
        connect(creditAgent, admin).setLendingMarket(ADDRESS_ZERO)
      ).to.be.revertedWithCustomError(creditAgent, REVERT_ERROR_IF_ALREADY_CONFIGURED);

      // Try to set the same value twice
      await proveTx(connect(creditAgent, admin).setLendingMarket(lendingMarketMockAddress));
      await expect(
        connect(creditAgent, admin).setLendingMarket(lendingMarketMockAddress)
      ).to.be.revertedWithCustomError(creditAgent, REVERT_ERROR_IF_ALREADY_CONFIGURED);
    });

    // Additional more complex checks are in the other sections
  });

  describe("Function 'initiateCredit()", async () => {
    describe("Executes as expected if", async () => {
      it("The 'loanAddon' value is not zero", async () => {
        const fixture = await setUpFixture(deployAndConfigureContracts);
        const credit = defineCredit({ loanAddon: LOAN_ADDON_STUB });
        const txId = TX_ID_STUB;
        const tx = initiateCredit(fixture.creditAgent, { txId, credit });
        await checkCreditInitiation(fixture, { tx, txId, credit });
      });

      it("The 'loanAddon' value is zero", async () => {
        const fixture = await setUpFixture(deployAndConfigureContracts);
        const credit = defineCredit({ loanAddon: 0n });
        const txId = TX_ID_STUB;
        const tx = initiateCredit(fixture.creditAgent, { txId, credit });
        await checkCreditInitiation(fixture, { tx, txId, credit });
      });
    });

    describe("Is reverted if", async () => {
      it("The contract is paused", async () => {
        const { creditAgent } = await setUpFixture(deployAndConfigureContracts);
        await proveTx(creditAgent.pause());

        await expect(
          initiateCredit(creditAgent)
        ).to.be.revertedWithCustomError(creditAgent, REVERT_ERROR_IF_CONTRACT_IS_PAUSED);
      });

      it("The caller does not have the manager role", async () => {
        const { creditAgent } = await setUpFixture(deployAndConfigureContracts);

        await expect(
          initiateCredit(creditAgent, { caller: deployer })
        ).to.be.revertedWithCustomError(
          creditAgent,
          REVERT_ERROR_IF_UNAUTHORIZED_ACCOUNT
        ).withArgs(deployer.address, managerRole);
      });

      it("The 'Cashier' contract address is not configured", async () => {
        const { creditAgent } = await setUpFixture(deployAndConfigureContracts);
        await proveTx(creditAgent.setCashier(ADDRESS_ZERO));

        await expect(
          initiateCredit(creditAgent)
        ).to.be.revertedWithCustomError(creditAgent, REVERT_ERROR_IF_CONTRACT_NOT_CONFIGURED);
      });

      it("The 'LendingMarket' contract address is not configured", async () => {
        const { creditAgent } = await setUpFixture(deployAndConfigureContracts);
        await proveTx(creditAgent.setLendingMarket(ADDRESS_ZERO));

        await expect(
          initiateCredit(creditAgent)
        ).to.be.revertedWithCustomError(creditAgent, REVERT_ERROR_IF_CONTRACT_NOT_CONFIGURED);
      });

      it("The provided 'txId' value is zero", async () => {
        const { creditAgent } = await setUpFixture(deployAndConfigureContracts);
        const credit = defineCredit({});

        await expect(
          initiateCredit(creditAgent, { txId: TX_ID_ZERO, credit })
        ).to.be.revertedWithCustomError(creditAgent, REVERT_ERROR_IF_TX_ID_ZERO);
      });

      it("The provided borrower address is zero", async () => {
        const { creditAgent } = await setUpFixture(deployAndConfigureContracts);
        const credit = defineCredit({ borrowerAddress: ADDRESS_ZERO });

        await expect(
          initiateCredit(creditAgent, { credit })
        ).to.be.revertedWithCustomError(creditAgent, REVERT_ERROR_IF_BORROWER_ADDRESS_ZERO);
      });

      it("The provided program ID is zero", async () => {
        const { creditAgent } = await setUpFixture(deployAndConfigureContracts);
        const credit = defineCredit({ programId: 0 });

        await expect(
          initiateCredit(creditAgent, { credit })
        ).to.be.revertedWithCustomError(creditAgent, REVERT_ERROR_IF_PROGRAM_ID_ZERO);
      });

      it("The provided loan duration is zero", async () => {
        const { creditAgent } = await setUpFixture(deployAndConfigureContracts);
        const credit = defineCredit({ durationInPeriods: 0 });

        await expect(
          initiateCredit(creditAgent, { credit })
        ).to.be.revertedWithCustomError(creditAgent, REVERT_ERROR_IF_LOAN_DURATION_ZERO);
      });

      it("The provided loan amount is zero", async () => {
        const { creditAgent } = await setUpFixture(deployAndConfigureContracts);
        const credit = defineCredit({ loanAmount: 0n });

        await expect(
          initiateCredit(creditAgent, { credit })
        ).to.be.revertedWithCustomError(creditAgent, REVERT_ERROR_IF_LOAN_AMOUNT_ZERO);
      });

      it("A credit is already initiated for the provided transaction ID", async () => {
        const { creditAgent } = await setUpFixture(deployAndConfigureContracts);
        const credit = defineCredit();
        const txId = TX_ID_STUB;
        await proveTx(initiateCredit(creditAgent, { txId, credit }));

        await expect(
          initiateCredit(creditAgent, { txId, credit })
        ).to.be.revertedWithCustomError(
          creditAgent,
          REVERT_ERROR_IF_CREDIT_STATUS_INAPPROPRIATE
        ).withArgs(
          txId,
          CreditStatus.Initiated // status
        );
      });

      it("The 'programId' argument is greater than unsigned 32-bit integer", async () => {
        const { creditAgent } = await setUpFixture(deployAndConfigureContracts);
        const credit = defineCredit({ programId: Math.pow(2, 32) });
        await expect(
          initiateCredit(creditAgent, { credit })
        ).to.be.revertedWithCustomError(
          creditAgent,
          REVERT_ERROR_IF_SAFE_CAST_OVERFLOWED_UINT_DOWNCAST
        ).withArgs(32, credit.programId);
      });

      it("The 'durationInPeriods' argument is greater than unsigned 32-bit integer", async () => {
        const { creditAgent } = await setUpFixture(deployAndConfigureContracts);
        const credit = defineCredit({ durationInPeriods: Math.pow(2, 32) });
        await expect(
          initiateCredit(creditAgent, { credit })
        ).to.be.revertedWithCustomError(
          creditAgent,
          REVERT_ERROR_IF_SAFE_CAST_OVERFLOWED_UINT_DOWNCAST
        ).withArgs(32, credit.durationInPeriods);
      });

      it("The 'loanAmount' argument is greater than unsigned 64-bit integer", async () => {
        const { creditAgent } = await setUpFixture(deployAndConfigureContracts);
        const credit = defineCredit({ loanAmount: 2n ** 64n });
        await expect(
          initiateCredit(creditAgent, { credit })
        ).to.be.revertedWithCustomError(
          creditAgent,
          REVERT_ERROR_IF_SAFE_CAST_OVERFLOWED_UINT_DOWNCAST
        ).withArgs(64, credit.loanAmount);
      });

      it("The 'loanAddon' argument is greater than unsigned 64-bit integer", async () => {
        const { creditAgent } = await setUpFixture(deployAndConfigureContracts);
        const credit = defineCredit({ loanAddon: 2n ** 64n });
        await expect(
          initiateCredit(creditAgent, { credit })
        ).to.be.revertedWithCustomError(
          creditAgent,
          REVERT_ERROR_IF_SAFE_CAST_OVERFLOWED_UINT_DOWNCAST
        ).withArgs(64, credit.loanAddon);
      });

      // Additional more complex checks are in the other sections
    });
  });

  describe("Function 'revokeCredit()", async () => {
    it("Executes as expected", async () => {
      const { creditAgent, cashierMock } = await setUpFixture(deployAndConfigureContracts);
      const credit = defineCredit();
      const txId = TX_ID_STUB;
      await proveTx(initiateCredit(creditAgent, { txId }));

      const tx = connect(creditAgent, manager).revokeCredit(txId);
      await expect(tx).to.emit(creditAgent, EVENT_NAME_CREDIT_STATUS_CHANGED).withArgs(
        txId,
        credit.borrower,
        CreditStatus.Nonexistent, // newStatus
        CreditStatus.Initiated, // oldStatus
        credit.loanId,
        credit.programId,
        credit.durationInPeriods,
        credit.loanAmount,
        credit.loanAddon
      );
      await expect(tx).to.emit(cashierMock, EVENT_NAME_MOCK_CONFIGURE_CASH_OUT_HOOKS_CALLED).withArgs(
        txId,
        ADDRESS_ZERO, // newCallableContract,
        0 // newHookFlags
      );
      checkEquality(await creditAgent.getCredit(txId) as Credit, initialCredit);
    });

    it("Is reverted if the contract is paused", async () => {
      const { creditAgent } = await setUpFixture(deployAndConfigureContracts);
      await proveTx(creditAgent.pause());

      await expect(
        connect(creditAgent, manager).revokeCredit(TX_ID_STUB)
      ).to.be.revertedWithCustomError(creditAgent, REVERT_ERROR_IF_CONTRACT_IS_PAUSED);
    });

    it("Is reverted if the caller does not have the manager role", async () => {
      const { creditAgent } = await setUpFixture(deployAndConfigureContracts);

      await expect(
        connect(creditAgent, deployer).revokeCredit(TX_ID_STUB)
      ).to.be.revertedWithCustomError(
        creditAgent,
        REVERT_ERROR_IF_UNAUTHORIZED_ACCOUNT
      ).withArgs(deployer.address, managerRole);
    });

    it("Is reverted if the provided 'txId' value is zero", async () => {
      const { creditAgent } = await setUpFixture(deployAndConfigureContracts);

      await expect(
        connect(creditAgent, manager).revokeCredit(TX_ID_ZERO)
      ).to.be.revertedWithCustomError(creditAgent, REVERT_ERROR_IF_TX_ID_ZERO);
    });

    it("Is reverted if the credit does not exist", async () => {
      const { creditAgent } = await setUpFixture(deployAndConfigureContracts);

      await expect(
        connect(creditAgent, manager).revokeCredit(TX_ID_STUB)
      ).to.be.revertedWithCustomError(
        creditAgent,
        REVERT_ERROR_IF_CREDIT_STATUS_INAPPROPRIATE
      ).withArgs(
        TX_ID_STUB,
        CreditStatus.Nonexistent // status
      );
    });

    // Additional more complex checks are in the other sections
  });

  describe("Function 'onCashierHook()", async () => {
    async function checkCashierHookCalling(fixture: Fixture, props: {
      txId: string;
      credit: Credit;
      hookIndex: HookIndex;
      newCreditStatus: CreditStatus;
      oldCreditStatus: CreditStatus;
    }) {
      const { creditAgent, cashierMock, lendingMarketMock } = fixture;
      const { credit, txId, hookIndex, newCreditStatus, oldCreditStatus } = props;

      const tx = cashierMock.callCashierHook(getAddress(creditAgent), hookIndex, txId);

      credit.status = newCreditStatus;

      if (oldCreditStatus !== newCreditStatus) {
        await expect(tx).to.emit(creditAgent, EVENT_NAME_CREDIT_STATUS_CHANGED).withArgs(
          txId,
          credit.borrower,
          newCreditStatus,
          oldCreditStatus,
          credit.loanId,
          credit.programId,
          credit.durationInPeriods,
          credit.loanAmount,
          credit.loanAddon
        );
        if (newCreditStatus == CreditStatus.Pending) {
          await expect(tx).to.emit(lendingMarketMock, EVENT_NAME_MOCK_TAKE_LOAN_FOR_CALLED).withArgs(
            credit.borrower,
            credit.programId,
            credit.loanAmount, // borrowAmount,
            credit.loanAddon, // addonAmount,
            credit.durationInPeriods
          );
        } else {
          await expect(tx).not.to.emit(lendingMarketMock, EVENT_NAME_MOCK_TAKE_LOAN_FOR_CALLED);
        }

        if (newCreditStatus == CreditStatus.Reversed) {
          await expect(tx).to.emit(lendingMarketMock, EVENT_NAME_MOCK_REVOKE_LOAN_CALLED).withArgs(credit.loanId);
        } else {
          await expect(tx).not.to.emit(lendingMarketMock, EVENT_NAME_MOCK_REVOKE_LOAN_CALLED);
        }
      } else {
        await expect(tx).not.to.emit(creditAgent, EVENT_NAME_CREDIT_STATUS_CHANGED);
      }

      checkEquality(await creditAgent.getCredit(txId) as Credit, credit);
    }

    describe("Executes as expected if", async () => {
      it("A cash-out requested and then confirmed with other proper conditions", async () => {
        const { fixture, txId, initCredit } = await setUpFixture(deployAndConfigureContractsThenInitiateCredit);
        const expectedAgentState: AgentState = {
          ...initialAgentState,
          initiatedCreditCounter: 1n,
          configured: true
        };
        checkEquality(await fixture.creditAgent.agentState() as AgentState, expectedAgentState);
        const credit: Credit = { ...initCredit, loanId: fixture.loanIdStub };

        // Emulate cash-out request
        await checkCashierHookCalling(
          fixture,
          {
            txId,
            credit,
            hookIndex: HookIndex.CashOutRequestBefore,
            newCreditStatus: CreditStatus.Pending,
            oldCreditStatus: CreditStatus.Initiated
          }
        );
        expectedAgentState.initiatedCreditCounter = 0n;
        expectedAgentState.pendingCreditCounter = 1n;
        checkEquality(await fixture.creditAgent.agentState() as AgentState, expectedAgentState);

        // Emulate cash-out confirmation
        await checkCashierHookCalling(
          fixture,
          {
            txId,
            credit,
            hookIndex: HookIndex.CashOutConfirmationAfter,
            newCreditStatus: CreditStatus.Confirmed,
            oldCreditStatus: CreditStatus.Pending
          }
        );
        expectedAgentState.pendingCreditCounter = 0n;
        checkEquality(await fixture.creditAgent.agentState() as AgentState, expectedAgentState);
      });

      it("A cash-out requested and then reversed with other proper conditions", async () => {
        const { fixture, txId, initCredit } = await setUpFixture(deployAndConfigureContractsThenInitiateCredit);
        const credit: Credit = { ...initCredit, loanId: fixture.loanIdStub };

        // Emulate cash-out request
        await checkCashierHookCalling(
          fixture,
          {
            txId,
            credit,
            hookIndex: HookIndex.CashOutRequestBefore,
            newCreditStatus: CreditStatus.Pending,
            oldCreditStatus: CreditStatus.Initiated
          }
        );
        const expectedAgentState: AgentState = {
          ...initialAgentState,
          pendingCreditCounter: 1n,
          configured: true
        };
        checkEquality(await fixture.creditAgent.agentState() as AgentState, expectedAgentState);

        // Emulate cash-out reversal
        await checkCashierHookCalling(
          fixture,
          {
            txId,
            credit,
            hookIndex: HookIndex.CashOutReversalAfter,
            newCreditStatus: CreditStatus.Reversed,
            oldCreditStatus: CreditStatus.Pending
          }
        );
        expectedAgentState.pendingCreditCounter = 0n;
        checkEquality(await fixture.creditAgent.agentState() as AgentState, expectedAgentState);
      });
    });

    describe("Is reverted if", async () => {
      async function checkCashierHookInappropriateStatusError(fixture: Fixture, props: {
        txId: string;
        hookIndex: HookIndex;
        CreditStatus: CreditStatus;
      }) {
        const { creditAgent, cashierMock } = fixture;
        const { txId, hookIndex, CreditStatus } = props;
        await expect(
          cashierMock.callCashierHook(getAddress(creditAgent), hookIndex, TX_ID_STUB)
        ).to.be.revertedWithCustomError(
          creditAgent,
          REVERT_ERROR_IF_CREDIT_STATUS_INAPPROPRIATE
        ).withArgs(
          txId,
          CreditStatus // status
        );
      }

      it("The contract is paused", async () => {
        const { fixture } = await setUpFixture(deployAndConfigureContractsThenInitiateCredit);
        const { creditAgent, cashierMock } = fixture;
        const hookIndex = HookIndex.CashOutRequestBefore;
        await proveTx(creditAgent.pause());

        await expect(
          cashierMock.callCashierHook(getAddress(creditAgent), hookIndex, TX_ID_STUB)
        ).to.be.revertedWithCustomError(creditAgent, REVERT_ERROR_IF_CONTRACT_IS_PAUSED);
      });

      it("The caller is not the configured 'Cashier' contract", async () => {
        const { fixture } = await setUpFixture(deployAndConfigureContractsThenInitiateCredit);
        const { creditAgent } = fixture;
        const hookIndex = HookIndex.CashOutRequestBefore;

        await expect(
          connect(creditAgent, deployer).onCashierHook(hookIndex, TX_ID_STUB)
        ).to.be.revertedWithCustomError(creditAgent, REVERT_ERROR_IF_CASHIER_HOOK_CALLER_UNAUTHORIZED);
      });

      it("The credit status is inappropriate to the provided hook index. Part 1", async () => {
        const { fixture, txId } = await setUpFixture(deployAndConfigureContractsThenInitiateCredit);
        const { creditAgent, cashierMock } = fixture;

        // Try for a credit with the initiated status
        await checkCashierHookInappropriateStatusError(fixture, {
          txId,
          hookIndex: HookIndex.CashOutConfirmationAfter,
          CreditStatus: CreditStatus.Initiated
        });
        await checkCashierHookInappropriateStatusError(fixture, {
          txId,
          hookIndex: HookIndex.CashOutReversalAfter,
          CreditStatus: CreditStatus.Initiated
        });

        // Try for a credit with the pending status
        await proveTx(cashierMock.callCashierHook(getAddress(creditAgent), HookIndex.CashOutRequestBefore, txId));
        await checkCashierHookInappropriateStatusError(fixture, {
          txId,
          hookIndex: HookIndex.CashOutRequestBefore,
          CreditStatus: CreditStatus.Pending
        });

        // Try for a credit with the confirmed status
        await proveTx(
          cashierMock.callCashierHook(getAddress(creditAgent), HookIndex.CashOutConfirmationAfter, txId)
        );
        await checkCashierHookInappropriateStatusError(fixture, {
          txId,
          hookIndex: HookIndex.CashOutRequestBefore,
          CreditStatus: CreditStatus.Confirmed
        });
        await checkCashierHookInappropriateStatusError(fixture, {
          txId,
          hookIndex: HookIndex.CashOutConfirmationAfter,
          CreditStatus: CreditStatus.Confirmed
        });
        await checkCashierHookInappropriateStatusError(fixture, {
          txId,
          hookIndex: HookIndex.CashOutReversalAfter,
          CreditStatus: CreditStatus.Confirmed
        });
      });

      it("The credit status is inappropriate to the provided hook index. Part 2", async () => {
        const { fixture, txId } = await setUpFixture(deployAndConfigureContractsThenInitiateCredit);
        const { creditAgent, cashierMock } = fixture;

        // Try for a credit with the reversed status
        await proveTx(cashierMock.callCashierHook(getAddress(creditAgent), HookIndex.CashOutRequestBefore, txId));
        await proveTx(cashierMock.callCashierHook(getAddress(creditAgent), HookIndex.CashOutReversalAfter, txId));
        await checkCashierHookInappropriateStatusError(fixture, {
          txId,
          hookIndex: HookIndex.CashOutRequestBefore,
          CreditStatus: CreditStatus.Reversed
        });
        await checkCashierHookInappropriateStatusError(fixture, {
          txId,
          hookIndex: HookIndex.CashOutConfirmationAfter,
          CreditStatus: CreditStatus.Reversed
        });
        await checkCashierHookInappropriateStatusError(fixture, {
          txId,
          hookIndex: HookIndex.CashOutReversalAfter,
          CreditStatus: CreditStatus.Reversed
        });
      });

      it("The cash-out account is not match the credit borrower before taking a loan", async () => {
        const { fixture, txId, initCashOut } = await setUpFixture(deployAndConfigureContractsThenInitiateCredit);
        const { creditAgent, cashierMock } = fixture;
        const cashOut: CashOut = {
          ...initCashOut,
          account: deployer.address
        };
        await proveTx(cashierMock.setCashOut(txId, cashOut));

        await expect(
          cashierMock.callCashierHook(getAddress(creditAgent), HookIndex.CashOutRequestBefore, txId)
        ).to.revertedWithCustomError(
          creditAgent,
          REVERT_ERROR_IF_CASH_OUT_PARAMETERS_INAPPROPRIATE
        ).withArgs(txId);
      });

      it("The cash-out amount is not match the credit amount before taking a loan", async () => {
        const { fixture, txId, initCashOut } = await setUpFixture(deployAndConfigureContractsThenInitiateCredit);
        const { creditAgent, cashierMock } = fixture;
        const cashOut: CashOut = {
          ...initCashOut,
          amount: initCashOut.amount + 1n
        };
        await proveTx(cashierMock.setCashOut(txId, cashOut));

        await expect(
          cashierMock.callCashierHook(getAddress(creditAgent), HookIndex.CashOutRequestBefore, txId)
        ).to.revertedWithCustomError(
          creditAgent,
          REVERT_ERROR_IF_CASH_OUT_PARAMETERS_INAPPROPRIATE
        ).withArgs(txId);
      });

      it("The provided hook index is unexpected", async () => {
        const { fixture } = await setUpFixture(deployAndConfigureContractsThenInitiateCredit);
        const { creditAgent, cashierMock } = fixture;
        const hookIndex = HookIndex.Unused;

        await expect(
          cashierMock.callCashierHook(getAddress(creditAgent), hookIndex, TX_ID_STUB)
        ).to.be.revertedWithCustomError(
          creditAgent,
          REVERT_ERROR_IF_CASHIER_HOOK_INDEX_UNEXPECTED
        ).withArgs(
          hookIndex,
          TX_ID_STUB,
          getAddress(cashierMock)
        );
      });
    });
  });

  describe("Complex scenarios", async () => {
    it("A revoked credit can be re-initiated", async () => {
      const { fixture, txId, initCredit } = await setUpFixture(deployAndConfigureContractsThenInitiateCredit);
      const { creditAgent } = fixture;
      const expectedAgentState: AgentState = {
        ...initialAgentState,
        initiatedCreditCounter: 1n,
        configured: true
      };
      const credit: Credit = { ...initCredit };
      checkEquality(await fixture.creditAgent.agentState() as AgentState, expectedAgentState);

      await proveTx(connect(creditAgent, manager).revokeCredit(txId));
      expectedAgentState.initiatedCreditCounter = 0n;
      checkEquality(await fixture.creditAgent.agentState() as AgentState, expectedAgentState);

      const tx = initiateCredit(creditAgent, { txId, credit });
      await checkCreditInitiation(fixture, { tx, txId, credit });
      expectedAgentState.initiatedCreditCounter = 1n;
      checkEquality(await fixture.creditAgent.agentState() as AgentState, expectedAgentState);
    });

    it("A reversed credit can be re-initiated", async () => {
      const { fixture, txId, initCredit } = await setUpFixture(deployAndConfigureContractsThenInitiateCredit);
      const { creditAgent, cashierMock } = fixture;
      const credit: Credit = { ...initCredit };

      await proveTx(cashierMock.callCashierHook(getAddress(creditAgent), HookIndex.CashOutRequestBefore, txId));
      await proveTx(cashierMock.callCashierHook(getAddress(creditAgent), HookIndex.CashOutReversalAfter, txId));

      const tx = initiateCredit(creditAgent, { txId, credit });
      await checkCreditInitiation(fixture, { tx, txId, credit });
      const expectedAgentState: AgentState = {
        initiatedCreditCounter: 1n,
        pendingCreditCounter: 0n,
        configured: true
      };
      checkEquality(await fixture.creditAgent.agentState() as AgentState, expectedAgentState);
    });

    it("A pending or confirmed credit cannot be re-initiated", async () => {
      const { fixture, txId, initCredit } = await setUpFixture(deployAndConfigureContractsThenInitiateCredit);
      const { creditAgent, cashierMock } = fixture;
      const credit: Credit = { ...initCredit };

      // Try for a credit with the pending status
      await proveTx(cashierMock.callCashierHook(getAddress(creditAgent), HookIndex.CashOutRequestBefore, txId));
      await expect(
        initiateCredit(creditAgent, { txId, credit })
      ).to.be.revertedWithCustomError(
        creditAgent,
        REVERT_ERROR_IF_CREDIT_STATUS_INAPPROPRIATE
      ).withArgs(
        txId,
        CreditStatus.Pending // status
      );

      // Try for a credit with the confirmed status
      await proveTx(
        cashierMock.callCashierHook(getAddress(creditAgent), HookIndex.CashOutConfirmationAfter, txId)
      );
      await expect(
        initiateCredit(creditAgent, { txId, credit })
      ).to.be.revertedWithCustomError(
        creditAgent,
        REVERT_ERROR_IF_CREDIT_STATUS_INAPPROPRIATE
      ).withArgs(
        txId,
        CreditStatus.Confirmed // status
      );
    });

    it("A credit with any status except initiated cannot be revoked", async () => {
      const { fixture, txId, initCredit } = await setUpFixture(deployAndConfigureContractsThenInitiateCredit);
      const { creditAgent, cashierMock } = fixture;
      const credit: Credit = { ...initCredit };

      // Try for a credit with the pending status
      await proveTx(cashierMock.callCashierHook(getAddress(creditAgent), HookIndex.CashOutRequestBefore, txId));
      await expect(
        connect(creditAgent, manager).revokeCredit(txId)
      ).to.be.revertedWithCustomError(
        creditAgent,
        REVERT_ERROR_IF_CREDIT_STATUS_INAPPROPRIATE
      ).withArgs(
        txId,
        CreditStatus.Pending // status
      );

      // Try for a credit with the reversed status
      await proveTx(cashierMock.callCashierHook(getAddress(creditAgent), HookIndex.CashOutReversalAfter, txId));
      await expect(
        connect(creditAgent, manager).revokeCredit(txId)
      ).to.be.revertedWithCustomError(
        creditAgent,
        REVERT_ERROR_IF_CREDIT_STATUS_INAPPROPRIATE
      ).withArgs(
        txId,
        CreditStatus.Reversed // status
      );

      // Try for a credit with the confirmed status
      await proveTx(initiateCredit(creditAgent, { txId, credit }));
      await proveTx(cashierMock.callCashierHook(getAddress(creditAgent), HookIndex.CashOutRequestBefore, txId));
      await proveTx(
        cashierMock.callCashierHook(getAddress(creditAgent), HookIndex.CashOutConfirmationAfter, txId)
      );
      await expect(
        connect(creditAgent, manager).revokeCredit(txId)
      ).to.be.revertedWithCustomError(
        creditAgent,
        REVERT_ERROR_IF_CREDIT_STATUS_INAPPROPRIATE
      ).withArgs(
        txId,
        CreditStatus.Confirmed // status
      );
    });

    it("Configuring is prohibited when not all credits are processed", async () => {
      const { fixture, txId, initCredit } = await setUpFixture(deployAndConfigureContractsThenInitiateCredit);
      const { creditAgent, cashierMock, lendingMarketMock } = fixture;
      const credit: Credit = { ...initCredit };

      async function checkConfiguringProhibition() {
        await expect(
          connect(creditAgent, admin).setCashier(ADDRESS_ZERO)
        ).to.be.revertedWithCustomError(creditAgent, REVERT_ERROR_IF_CONFIGURING_PROHIBITED);
        await expect(
          connect(creditAgent, admin).setLendingMarket(ADDRESS_ZERO)
        ).to.be.revertedWithCustomError(creditAgent, REVERT_ERROR_IF_CONFIGURING_PROHIBITED);
      }

      async function checkConfiguringAllowance() {
        await proveTx(connect(creditAgent, admin).setCashier(ADDRESS_ZERO));
        await proveTx(connect(creditAgent, admin).setLendingMarket(ADDRESS_ZERO));
        await proveTx(connect(creditAgent, admin).setCashier(getAddress(cashierMock)));
        await proveTx(connect(creditAgent, admin).setLendingMarket(getAddress(lendingMarketMock)));
      }

      // Configuring is prohibited if a credit is initiated
      await checkConfiguringProhibition();

      // Configuring is allowed when no credit is initiated
      await proveTx(connect(creditAgent, manager).revokeCredit(txId));
      await checkConfiguringAllowance();

      // Configuring is prohibited if a credit is pending
      await proveTx(initiateCredit(creditAgent, { txId, credit }));
      await proveTx(cashierMock.callCashierHook(getAddress(creditAgent), HookIndex.CashOutRequestBefore, txId));
      await checkConfiguringProhibition();

      // Configuring is allowed if a credit is reversed and no more active credits exist
      await proveTx(cashierMock.callCashierHook(getAddress(creditAgent), HookIndex.CashOutReversalAfter, txId));
      await checkConfiguringAllowance();

      // Configuring is prohibited if a credit is initiated
      await proveTx(initiateCredit(creditAgent, { txId, credit }));
      await checkConfiguringProhibition();

      // Configuring is allowed if credits are reversed or confirmed and no more active credits exist
      await proveTx(cashierMock.callCashierHook(getAddress(creditAgent), HookIndex.CashOutRequestBefore, txId));
      await proveTx(
        cashierMock.callCashierHook(getAddress(creditAgent), HookIndex.CashOutConfirmationAfter, txId)
      );
      await checkConfiguringAllowance();
    });
  });
});
