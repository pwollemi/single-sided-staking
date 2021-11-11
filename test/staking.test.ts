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
const { expect, assert } = chai;

describe("Staking Pool", () => {
  const totalSupply = getBigNumber("100000000");

  // to avoid complex calculation of decimals, we set an easy value
  const rewardPerSecond = BigNumber.from("100000000000000000");

  let staking: Staking;
  let token: CustomToken;

  let deployer: SignerWithAddress;
  let bob: SignerWithAddress;
  let alice: SignerWithAddress;

  before(async () => {
    [deployer, bob, alice] = await ethers.getSigners();
  });

  beforeEach(async () => {
    token = <CustomToken>(
      await deployContract(
        "CustomToken",
        "Reward-USDC QS LP token",
        "REWARD-USDC",
        totalSupply
      )
    );
    staking = <Staking>(
      await deployProxy(
        "Staking",
        token.address,
      )
    );

    await staking.setRewardPerSecond(rewardPerSecond);
    await token.transfer(staking.address, totalSupply.div(2));
    await token.approve(staking.address, ethers.constants.MaxUint256);
    await token.connect(bob).approve(staking.address, ethers.constants.MaxUint256);
    await token.connect(alice).approve(staking.address, ethers.constants.MaxUint256);
  });

  describe("initialize", async () => {
    it("Validiation of initilize params", async () => {
      const now = await getLatestBlockTimestamp();
      await expect(
        deployProxy(
          "Staking",
          ethers.constants.AddressZero,
        )
      ).to.be.revertedWith("initialize: token address cannot be zero");
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

  describe("Balance of user", () => {
    it("Should be zero when lp supply is zero", async () => {
      await staking.deposit(getBigNumber(0), alice.address);
      await advanceTime(86400);
      await staking.updatePool();
      expect(await staking.balanceOf(alice.address)).to.be.equal(0);
    });

    it("Balance of the user gradually increases by auto compounding", async () => {
      const aliceDeposit = getBigNumber(1);
      await staking.deposit(aliceDeposit, alice.address);
      await advanceTime(86400);
      await mineBlock();
      const expectedBalance = aliceDeposit.add(rewardPerSecond.mul(86400));
      expect(await staking.balanceOf(alice.address)).to.be.equal(expectedBalance);

      // stake 1/4 of alice's current balance, thus 1/5 of total shares
      const nextReserve = expectedBalance.add(rewardPerSecond.mul(10));
      await advanceTime(10);
      await staking.deposit(nextReserve.div(4), bob.address);
      await advanceTime(86400);
      await mineBlock();
      const expectedAliceBalance = nextReserve.add(rewardPerSecond.mul(86400).mul(4).div(5));
      const expectedBobBalance = nextReserve.div(4).add(rewardPerSecond.mul(86400).div(5));
      expect(await staking.balanceOf(alice.address)).to.be.equal(expectedAliceBalance);
      expect(await staking.balanceOf(bob.address)).to.be.equal(expectedBobBalance);
    });
  });

  describe("Total reserves", () => {
    it("Total reserve is updated by the time goes", async () => {
      expect(await staking.totalReservesCurrent()).to.be.equal(0);
      await staking.deposit(getBigNumber(1), alice.address);
      const start = await getLatestBlockTimestamp();
      await advanceTime(86400);
      await mineBlock();
      expect(await staking.totalReservesCurrent()).to.be.equal(getBigNumber(1).add(rewardPerSecond.mul(86400)));
      await staking.deposit(getBigNumber(1), bob.address);
      await advanceTime(86400);
      await mineBlock();
      const now = await getLatestBlockTimestamp();
      expect(await staking.totalReservesCurrent()).to.be.equal(getBigNumber(2).add(rewardPerSecond.mul(now - start)));
    });

    it("Total reserve is always zero if zero staked", async () => {
      expect(await staking.totalReservesCurrent()).to.be.equal(0);
      await advanceTime(86400);
      await mineBlock();
      expect(await staking.totalReservesCurrent()).to.be.equal(0);
      await advanceTime(86400);
      await mineBlock();
      expect(await staking.totalReservesCurrent()).to.be.equal(0);
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
          await staking.totalReserves(),
          await staking.totalShares()
        );
    });
  });

  describe("Withdraw", () => {
    it("Should give back the correct amount of lp token and claim rewards(withdraw whole amount)", async () => {
      // assume alice's current balance is zero
      assert((await token.balanceOf(alice.address)).isZero());

      const depositAmount = getBigNumber(1);
      const withdrawAmount = getBigNumber(2);
      const period = duration.days(31).toNumber();
      const expectedReward = rewardPerSecond.mul(period);

      // 1. deposit tokens
      await staking.deposit(depositAmount, alice.address);
      await advanceTime(period);
      await mineBlock();

      // 2. check reward of the user
      const rewardOf = await staking.rewardOf(alice.address);
      expect(rewardOf).to.be.equal(expectedReward);

      // 3. withdraw user (!!!! 10 more second has passed)
      await advanceTime(10);
      await staking.connect(alice).withdraw(withdrawAmount, alice.address);
      expect(await token.balanceOf(alice.address)).to.be.equal(withdrawAmount);

      // 4. remaining balances are depositAmount + rewardOf + 10 seconds rewards - withdrawAmount
      expect(await staking.balanceOf(alice.address)).to.be.equal(rewardOf.add(depositAmount).add(rewardPerSecond.mul(10)).sub(withdrawAmount));
    });

    it("Penalty applied", async () => {
      // assume alice's current balance is zero
      assert((await token.balanceOf(alice.address)).isZero());

      // 50 % penalty in 20 days
      await staking.setPenaltyInfo(duration.days(20), 5000);

      const depositAmount = getBigNumber(1);
      const period = duration.days(10).toNumber();

      await staking.deposit(depositAmount, alice.address);
      await advanceTime(period);
      await staking.connect(alice).withdraw(depositAmount, alice.address);

      // remaining balances are half of rewards
      const remainingBalance = rewardPerSecond.mul(period).div(2);
      expect(await staking.balanceOf(alice.address)).to.be.equal(remainingBalance);
    });

    it("Withraw 0", async () => {
      await staking.deposit(getBigNumber(1), alice.address);
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
