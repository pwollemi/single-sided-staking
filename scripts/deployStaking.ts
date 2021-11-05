import { ethers } from "hardhat";
import { CustomToken, Staking } from "../typechain";
import {
  duration,
  getBigNumber,
  getLatestBlockTimestamp,
} from "../helper/utils";
import {
  deployContract,
  deployProxy,
  verifyContract,
} from "../helper/deployer";

async function main() {
  const totalSupply = getBigNumber("100000000");
  const totalRewardAmount = getBigNumber("2500000");
  const rewardPerSecond = totalRewardAmount.div(duration.days(90));

  const lpToken = <CustomToken>(
    await deployContract(
      "CustomToken",
      "Reward-USDC QS LP token",
      "REWARD-USDC",
      totalSupply
    )
  );
  const rewardToken = <CustomToken>(
    await deployContract("CustomToken", "Reward token", "REWARD", totalSupply)
  );
  const staking = <Staking>(
    await deployProxy(
      "Staking",
      rewardToken.address,
      lpToken.address,
    )
  );

  await staking.setRewardPerSecond(rewardPerSecond);

  console.log(lpToken.address);
  console.log(rewardToken.address);
  console.log(staking.address);

  await verifyContract(
    lpToken.address,
    "Reward-USDC QS LP token",
    "REWARD-USDC",
    totalSupply
  );
  await verifyContract(
    rewardToken.address,
    "Reward token",
    "REWARD",
    totalSupply
  );
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
