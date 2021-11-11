// SPDX-License-Identifier: MIT

pragma solidity 0.8.0;
pragma abicoder v2;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

/// @title Auto compounding Single Side Staking Contract
/// @notice You can use this contract for staking LP tokens
/// @dev All function calls are currently implemented without side effects
contract Staking is Initializable, OwnableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeCastUpgradeable for int256;
    using SafeCastUpgradeable for uint256;

    /// @notice Info of each user.
    /// `amount` token amount the user has provided by calling `deposit`.
    /// `share` share of the user in the reserve pool.
    /// `lastDepositedAt` The timestamp of the last deposit.
    struct UserInfo {
        uint256 amount;
        uint256 share;
        uint256 lastDepositedAt;
    }

    /// @notice Address of the staking token.
    IERC20Upgradeable public token;

    /********************** Status ***********************/

    /// @notice Amount of reward token allocated per second
    uint256 public rewardPerSecond;

    /// @notice total shares
    uint256 public totalShares;

    /// @notice total staked token amount
    ///  - this includes the staked tokens of the user and the distributed rewards
    ///  - this value should be always less than the total balance of the pool
    uint256 public totalReserves;

    /// @notice Last time that the reward is calculated
    uint256 public lastRewardTime;

    /// @notice Info of each user that stakes tokens.
    mapping(address => UserInfo) public userInfo;

    /********************** Staking Params ***********************/

    /// @notice withdraw tax fee with 2 dp (e.g. 1000)
    uint256 public withdrawTaxFee;

    /// @notice Duration for unstake/claim penalty
    uint256 public earlyWithdrawal;

    /// @notice Penalty rate with 2 dp (e.g. 1000 = 10%)
    uint256 public penaltyRate;

    /********************** Events ***********************/

    event Deposit(address indexed user, uint256 amount, address indexed to);
    event Withdraw(address indexed user, uint256 amount, address indexed to);
    event EmergencyWithdraw(address indexed user, uint256 amount, address indexed to);

    event LogUpdatePool(uint256 lastRewardTime, uint256 totalReserves, uint256 totalShares);
    event LogRewardPerSecond(uint256 rewardPerSecond);
    event LogWithdrawTaxFee(uint256 taxFee);
    event LogPenaltyParams(uint256 earlyWithdrawal, uint256 penaltyRate);

    /**
     * @param _token The token contract address for SSS.
     */
    function initialize(
        IERC20Upgradeable _token
    ) external initializer {
        require(address(_token) != address(0), "initialize: token address cannot be zero");

        __Ownable_init();

        token = _token;
        lastRewardTime = block.timestamp;

        earlyWithdrawal = 7 days;
        penaltyRate = 5000;
    }

    /**
     * @notice Sets the  per second to be distributed. Can only be called by the owner.
     * @dev Its decimals count is ONE
     * @param _rewardPerSecond The amount of reward to be distributed per second.
     */
    function setRewardPerSecond(uint256 _rewardPerSecond) public onlyOwner {
        updatePool();
        rewardPerSecond = _rewardPerSecond;
        emit LogRewardPerSecond(_rewardPerSecond);
    }

    /**
     * @notice Set the penalty information
     * @param _earlyWithdrawal The new earlyWithdrawal
     * @param _penaltyRate The new penaltyRate
     */
    function setPenaltyInfo(uint256 _earlyWithdrawal, uint256 _penaltyRate) external onlyOwner {
        earlyWithdrawal = _earlyWithdrawal;
        penaltyRate = _penaltyRate;
        emit LogPenaltyParams(_earlyWithdrawal, _penaltyRate);
    }

    /**
     * @notice Sets tax fee.
     * @param _withdrawTaxFee withdraw tax fee.
     */
    function setWithdrawTaxFee(uint256 _withdrawTaxFee) public onlyOwner {
        withdrawTaxFee = _withdrawTaxFee;
        emit LogWithdrawTaxFee(_withdrawTaxFee);
    }

    /**
     * @notice Total reserves.
     * @return newReserve current reserve.
     */
    function totalReservesCurrent() public view returns (uint256 newReserve) {
        newReserve = totalReserves;
        if (block.timestamp > lastRewardTime && totalShares > 0) {
            uint256 newReward = (block.timestamp - lastRewardTime) * rewardPerSecond;
            newReserve = newReserve + newReward;
        }
    }

    /**
     * @notice View function to see balance of a user.
     * @dev It doens't update anything, it's just a view function.
     *
     *  user balance = user.share * totalReserves / totalShares
     *
     * @param _user Address of user.
     * @return balance of a given user.
     */
    function balanceOf(address _user) external view returns (uint256 balance) {
        UserInfo memory user = userInfo[_user];
        balance = totalShares > 0 ? user.share * totalReservesCurrent() / totalShares : 0;
    }

    /**
     * @notice View function to see reward of a user.
     * @dev It doens't update anything, it's just a view function.
     *
     *  user balance = user.share * totalReserves / totalShares
     *  user reward = user balance - last deposited amount
     *
     * @param _user Address of user.
     * @return reward of a given user.
     */
    function rewardOf(address _user) external view returns (uint256 reward) {
        UserInfo memory user = userInfo[_user];
        uint256 balance = totalShares > 0 ? user.share * totalReservesCurrent() / totalShares : 0;
        reward = balance > user.amount ? balance - user.amount : 0;
    }

    /**
     * @notice Update reward variables.
     * @dev Updates totalReserves and lastRewardTime.
     */
    function updatePool() public {
        if (block.timestamp > lastRewardTime) {
            if (totalShares > 0) {
                uint256 newReward = (block.timestamp - lastRewardTime) * rewardPerSecond;
                totalReserves = totalReserves + newReward;
            }
            lastRewardTime = block.timestamp;
            emit LogUpdatePool(lastRewardTime, totalReserves, totalShares);
        }
    }

    /**
     * @notice Deposit tokens for reward allocation.
     * @param amount token amount to deposit.
     * @param to The receiver of `amount` deposit benefit.
     */
    function deposit(uint256 amount, address to) public {
        updatePool();
        UserInfo storage user = userInfo[to];

        // Effects
        uint256 share;
        if (totalShares > 0) {
            share = reserveToShare(amount);
        } else {
            share = amount;
        }
        totalShares = totalShares + share;
        totalReserves = totalReserves + amount;

        user.share = user.share + share;
        user.lastDepositedAt = block.timestamp;
        user.amount = user.amount + amount;

        emit Deposit(msg.sender, amount, to);

        token.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Withdraw tokens and claim rewards to `to`.
     * @dev if user is doing early withdrawal, then 50% of reward amount is deducted, reward is the amount that increased from the last stake
     * @param amount token amount to withdraw.
     * @param to Receiver of the tokens and rewards.
     */
    function withdraw(uint256 amount, address to) public {
        updatePool();
        if (totalShares == 0 || totalReserves == 0) return;

        UserInfo storage user = userInfo[msg.sender];
        uint256 balance = shareToReserve(user.share);

        // if early withdrawal, we decrease the user balance first
        uint256 penaltyAmount;
        uint256 reward = balance > user.amount ? balance - user.amount : 0;
        if (isEarlyWithdrawal(user.lastDepositedAt)) {
            penaltyAmount = reward * penaltyRate / 10000;
            uint256 penaltyShare = reserveToShare(penaltyAmount);
            user.share = user.share - penaltyShare;
            
            totalShares = totalShares - penaltyShare;
            totalReserves = totalReserves - penaltyAmount;
        }

        // if the withdraw balance is larger than current available amount, then withdraws maximum
        uint256 shareFromAmount = reserveToShare(amount);
        if (shareFromAmount > user.share) {
            shareFromAmount = user.share;
            amount = shareToReserve(shareFromAmount);
        }

        // Effects
        user.share = user.share - shareFromAmount;
        user.amount = shareToReserve(user.share); // user's amount became the remaining balance, but no update to deposit time

        totalShares = totalShares - shareFromAmount;
        totalReserves = totalReserves - amount;

        emit Withdraw(msg.sender, amount, to);

        // Interactions
        if (penaltyAmount > 0) {
            // Burn the penalty amount
            token.safeTransfer(address(0xdead), penaltyAmount);
        }
        token.safeTransfer(to, amount);
    }

    /**
     * @notice Withdraw without caring about rewards. EMERGENCY ONLY.
     * @param to Receiver of the LP tokens.
     */
    function emergencyWithdraw(address to) public {
        UserInfo storage user = userInfo[msg.sender];
        uint256 amount = user.amount;
        uint256 balance = shareToReserve(user.share);
        totalReserves = totalReserves - balance;
        totalShares = totalShares - user.share;
        user.amount = 0;
        user.share = 0;

        emit EmergencyWithdraw(msg.sender, amount, to);

        // Note: transfer can fail or succeed if `amount` is zero.
        token.safeTransfer(to, amount);
    }

    /**
     * @notice deposit reward
     * @param amount to deposit
     */
    function depositReward(uint256 amount) external onlyOwner {
        token.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice withdraw reward
     * @param amount to withdraw
     */
    function withdrawReward(uint256 amount) external onlyOwner {
        token.safeTransfer(msg.sender, amount);
    }

    /**
     * @notice check if user in penalty period
     * @return isEarly
     */
    function isEarlyWithdrawal(uint256 lastDepositedTime) internal view returns (bool isEarly) {
        isEarly = block.timestamp <= lastDepositedTime + earlyWithdrawal;
    }

    /**
     * @notice convert share amount to reserve balance
     * @param share if user in penalty period
     * @return balance
     */
    function shareToReserve(uint256 share) internal view returns (uint256 balance) {
        balance = totalShares > 0 ? share * totalReserves / totalShares : 0;
    }

    /**
     * @notice convert reserve amount to share
     * @param reserve if user in penalty period
     * @return share
     */
    function reserveToShare(uint256 reserve) internal view returns (uint256 share) {
        share = totalReserves > 0 ? reserve * totalShares / totalReserves : 0;
    }

    function renounceOwnership() public override onlyOwner {
        revert();
    }
}
