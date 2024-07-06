import { ethers, upgrades } from "hardhat";
import { getAddress } from "../test-utils/eth";

async function main() {
  const CONTRACT_NAME: string = "PixCreditAgent"; // TBD: Enter contract name

  const factory = await ethers.getContractFactory(CONTRACT_NAME);
  const proxy = await upgrades.deployProxy(
    factory,
    [],
    { kind: "uups" }
  );
  await proxy.waitForDeployment();

  console.log("Proxy deployed to:", getAddress(proxy));
}

main().then().catch(err => {
  throw err;
});
