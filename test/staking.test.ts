/* eslint-disable no-await-in-loop */
import { ethers } from "hardhat";
import { solidity } from "ethereum-waffle";
import chai from "chai";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/dist/src/signer-with-address";
import { BigNumber } from "ethers";
import { CustomToken, Staking } from "../typechain";
import {
  getLatestBlockTimestamp,
  mineBlock,
  advanceTime,
  duration,
  getBigNumber,
  advanceTimeAndBlock,
} from "../helper/utils";
import { deployContract, deployProxy } from "../helper/deployer";

chai.use(solidity);
const { expect } = chai;

describe("Staking Pool", () => {
  const totalSupply = getBigNumber("100000000");
  const totalAmount = getBigNumber("20000000");
  const totalRewardAmount = getBigNumber("2500000");

  // to avoid complex calculation of decimals, we set an easy value
  const rewardPerSecond = BigNumber.from("100000000000000000");

  let staking: Staking;
  let lpToken: CustomToken;
  let rewardToken: CustomToken;

  let deployer: SignerWithAddress;
  let bob: SignerWithAddress;
  let alice: SignerWithAddress;

  before(async () => {
    [deployer, bob, alice] = await ethers.getSigners();
  });

  beforeEach(async () => {
    lpToken = <CustomToken>(
      await deployContract(
        "CustomToken",
        "Reward-USDC QS LP token",
        "REWARD-USDC",
        totalSupply
      )
    );
    rewardToken = <CustomToken>(
      await deployContract("CustomToken", "Reward token", "REWARD", totalSupply)
    );
    staking = <Staking>(
      await deployProxy(
        "Staking",
        rewardToken.address,
        lpToken.address,
      )
    );

    await staking.setRewardPerSecond(rewardPerSecond);
    await staking.setRewardTreasury(deployer.address);

    await rewardToken.approve(staking.address, ethers.constants.MaxUint256);

    await lpToken.transfer(bob.address, totalAmount.div(5));
    await lpToken.transfer(alice.address, totalAmount.div(5));

    await lpToken.approve(staking.address, ethers.constants.MaxUint256);
    await lpToken
      .connect(bob)
      .approve(staking.address, ethers.constants.MaxUint256);
    await lpToken
      .connect(alice)
      .approve(staking.address, ethers.constants.MaxUint256);
  });

  describe("initialize", async () => {
    it("Validiation of initilize params", async () => {
      const now = await getLatestBlockTimestamp();
      await expect(
        deployProxy(
          "Staking",
          ethers.constants.AddressZero,
          lpToken.address,
        )
      ).to.be.revertedWith("initialize: reward token address cannot be zero");
      await expect(
        deployProxy(
          "Staking",
          rewardToken.address,
          ethers.constants.AddressZero,
        )
      ).to.be.revertedWith("initialize: LP token address cannot be zero");
    });
  });

  describe("Set Reward per second", () => {
    const newRewardPerSecond = 100;

    it("Only owner can do these operation", async () => {
      await expect(
        staking.connect(bob).setRewardPerSecond(newRewardPerSecond)
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });

    it("It correctly updates information", async () => {
      await staking.setRewardPerSecond(newRewardPerSecond);
      expect(await staking.rewardPerSecond()).to.be.equal(newRewardPerSecond);
    });
  });

  describe("Deposit", () => {
    it("Deposit 0 amount", async () => {
      await expect(staking.deposit(getBigNumber(0), bob.address))
        .to.emit(staking, "Deposit")
        .withArgs(deployer.address, 0, bob.address);
    });

    it("Staking amount increases", async () => {
      const stakeAmount1 = ethers.utils.parseUnits("10", 18);
      const stakeAmount2 = ethers.utils.parseUnits("4", 18);

      await staking.deposit(stakeAmount1, bob.address);

      // user info
      const userInfo1 = await staking.userInfo(bob.address);
      expect(userInfo1.amount).to.be.equal(stakeAmount1);

      await staking.deposit(stakeAmount2, bob.address);

      // user info
      const userInfo2 = await staking.userInfo(bob.address);
      expect(userInfo2.amount).to.be.equal(stakeAmount1.add(stakeAmount2));
    });
  });

  describe("PendingReward", () => {
    it("Should be zero when lp supply is zero", async () => {
      await staking.deposit(getBigNumber(0), alice.address);
      await advanceTime(86400);
      await staking.updatePool();
      expect(await staking.pendingReward(alice.address)).to.be.equal(0);
    });

    it("PendingRward should equal ExpectedReward", async () => {
      await staking.deposit(getBigNumber(1), alice.address);
      await advanceTime(86400);
      await mineBlock();
      const expectedReward = rewardPerSecond.mul(86400);
      expect(await staking.pendingReward(alice.address)).to.be.equal(
        expectedReward
      );
    });
  });

  describe("Update Pool", () => {
    it("LogUpdatePool event is emitted", async () => {
      await advanceTimeAndBlock(100);
      await staking.deposit(getBigNumber(1), alice.address);
      await expect(staking.updatePool())
        .to.emit(staking, "LogUpdatePool")
        .withArgs(
          await staking.lastRewardTime(),
          await lpToken.balanceOf(staking.address),
          await staking.accRewardPerShare()
        );
    });
  });

  describe("Claim", () => {
    it("Should give back the correct amount of REWARD", async () => {
      const period = duration.days(31).toNumber();
      const expectedReward = rewardPerSecond.mul(period);

      await staking.deposit(getBigNumber(1), alice.address);
      await advanceTime(period);
      await staking.connect(alice).claim(alice.address);

      expect(await rewardToken.balanceOf(alice.address)).to.be.equal(
        expectedReward
      );
      expect((await staking.userInfo(alice.address)).rewardDebt).to.be.equal(
        expectedReward
      );
      expect(await staking.pendingReward(alice.address)).to.be.equal(0);
    });

    it("Claim with empty user balance", async () => {
      await staking.connect(alice).claim(alice.address);
    });
  });

  describe("Withdraw", () => {
    it("Should give back the correct amount of lp token and claim rewards(withdraw whole amount)", async () => {
      const depositAmount = getBigNumber(1);
      const period = duration.days(31).toNumber();
      const expectedReward = rewardPerSecond.mul(period);

      await staking.deposit(depositAmount, alice.address);
      await advanceTime(period);
      const balance0 = await lpToken.balanceOf(alice.address);
      await staking.connect(alice).withdraw(depositAmount, alice.address);
      const balance1 = await lpToken.balanceOf(alice.address);

      expect(depositAmount).to.be.equal(balance1.sub(balance0));
      expect(await rewardToken.balanceOf(alice.address)).to.be.equal(
        expectedReward
      );

      // remainging reward should be zero
      expect(await staking.pendingReward(alice.address)).to.be.equal(0);
      // remaing debt should be zero
      expect((await staking.userInfo(alice.address)).rewardDebt).to.be.equal(0);
    });

    it("Withraw 0", async () => {
      await expect(staking.connect(alice).withdraw(0, bob.address))
        .to.emit(staking, "Withdraw")
        .withArgs(alice.address, 0, bob.address);
    });
  });

  describe("EmergencyWithdraw", () => {
    it("Should emit event EmergencyWithdraw", async () => {
      await staking.deposit(getBigNumber(1), bob.address);
      await expect(staking.connect(bob).emergencyWithdraw(bob.address))
        .to.emit(staking, "EmergencyWithdraw")
        .withArgs(bob.address, getBigNumber(1), bob.address);
    });
  });

  describe("Renoucne Ownership", () => {
    it("Should revert when call renoucne ownership", async () => {
      await expect(staking.connect(deployer).renounceOwnership()).to.be
        .reverted;
    });
  });
});
