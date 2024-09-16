import fs from "fs";
import path from "path";
import { DeployHelper } from "../helpers/DeployHelper";
import hre, { network } from "hardhat";

async function main() {
  const stateAddress = "0x134B1BE34911E39A8397ec6289782989729807a4";
  const validators: ("mtpV2" | "sigV2" | "v3")[] = ["v3"];
  const deployHelper = await DeployHelper.initialize(null, true);

  const deployInfo: any = [];
  for (const v of validators) {
    const { validator, verifierWrapper } = await deployHelper.deployValidatorContracts(
      v,
      stateAddress,
      "create2",
    );
    deployInfo.push({
      validatorType: v,
      validator: await validator.getAddress(),
      verifier: await verifierWrapper.getAddress(),
    });
  }

  const chainId = parseInt(await network.provider.send("eth_chainId"), 16);
  const networkName = hre.network.name;
  const pathOutputJson = path.join(
    __dirname,
    `./deploy_validator_output_${chainId}_${networkName}.json`,
  );
  const outputJson = {
    info: deployInfo,
    network: process.env.HARDHAT_NETWORK,
    chainId,
  };
  fs.writeFileSync(pathOutputJson, JSON.stringify(outputJson, null, 1));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
