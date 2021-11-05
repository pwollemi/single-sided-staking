// SPDX-License-Identifier: MIT

pragma solidity 0.8.0;
pragma abicoder v2;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

/// @title Staking Contract
/// @notice You can use this contract for staking LP tokens
/// @dev All function calls are currently implemented without side effects
contract Staking is Initializable, OwnableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeCastUpgradeable for int256;
    using SafeCastUpgradeable for uint256;

    /// @notice Info of each user.
    /// `amount` LP token amount the user has provided.
    /// `rewardDebt` The amount of reward entitled to the user.
    /// `lastDepositedAt` The timestamp of the last deposit.
    struct UserInfo {
        uint256 amount;
        int256 rewardDebt;
        uint256 lastDepositedAt;
    }

    uint256 private constant ACC_REWARD_PRECISION = 1e12;

    /// @notice Address of reward token contract.
    IERC20Upgradeable public rewardToken;

    /// @notice Address of the LP token.
    IERC20Upgradeable public lpToken;

    /// @notice reward treasury wallet
    address public rewardTreasury;

    /// @notice Amount of reward token allocated per second.
    uint256 public rewardPerSecond;

    /// @notice reward amount allocated per LP token.
    uint256 public accRewardPerShare;

    /// @notice Last time that the reward is calculated.
    uint256 public lastRewardTime;

    /// @notice Info of each user that stakes LP tokens.
    mapping(address => UserInfo) public userInfo;

    /// @notice withdraw tax fee with 2 dp (e.g. 1000)
    uint256 public withdrawTaxFee;

    /// @notice Duration for unstake/claim penalty
    uint256 public earlyWithdrawal;

    /// @notice Penalty rate with 2 dp (e.g. 1000 = 10%)
    uint256 public penaltyRate;

    event Deposit(address indexed user, uint256 amount, address indexed to);
    event Withdraw(address indexed user, uint256 amount, address indexed to);
    event EmergencyWithdraw(address indexed user, uint256 amount, address indexed to);
    event Claim(address indexed user, uint256 amount);

    event LogUpdatePool(uint256 lastRewardTime, uint256 lpSupply, uint256 accRewardPerShare);
    event LogRewardPerSecond(uint256 rewardPerSecond);
    event LogRewardTreasury(address indexed treasury);
    event LogWithdrawTaxFee(uint256 taxFee);
    event LogPenaltyParams(uint256 earlyWithdrawal, uint256 penaltyRate);

    /**
     * @param _reward The reward token contract address.
     * @param _lpToken The LP token contract address.
     */
    function initialize(
        IERC20Upgradeable _reward,
        IERC20Upgradeable _lpToken
    ) external initializer {
        require(address(_reward) != address(0), "initialize: reward token address cannot be zero");
        require(address(_lpToken) != address(0), "initialize: LP token address cannot be zero");

        __Ownable_init();

        rewardToken = _reward;
        lpToken = _lpToken;
        accRewardPerShare = 0;
        lastRewardTime = block.timestamp;

        earlyWithdrawal = 7 days;
        penaltyRate = 5000;
    }

    /**
     * @notice Sets the  per second to be distributed. Can only be called by the owner.
     * @dev Its decimals count is ACC_REWARD_PRECISION
     * @param _rewardPerSecond The amount of reward to be distributed per second.
     */
    function setRewardPerSecond(uint256 _rewardPerSecond) public onlyOwner {
        updatePool();
        rewardPerSecond = _rewardPerSecond;
        emit LogRewardPerSecond(_rewardPerSecond);
    }

    /**
     * @notice Sets reward treasury wallet address.
     * @param _rewardTreasury treasury.
     */
    function setRewardTreasury(address _rewardTreasury) public onlyOwner {
        rewardTreasury = _rewardTreasury;
        emit LogRewardTreasury(_rewardTreasury);
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
     * @notice return available reward amount
     * @return rewardInTreasury reward amount in treasury
     * @return rewardAllowedForThisPool allowed reward amount to be spent by this pool
     */
    function availableReward() public view returns (uint256 rewardInTreasury, uint256 rewardAllowedForThisPool) {
        rewardInTreasury = rewardToken.balanceOf(rewardTreasury);
        rewardAllowedForThisPool = rewardToken.allowance(rewardTreasury, address(this));
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
     * @notice View function to see pending reward on frontend.
     * @dev It doens't update accRewardPerShare, it's just a view function.
     *
     *  pending reward = (user.amount * pool.accRewardPerShare) - user.rewardDebt
     *
     * @param _user Address of user.
     * @return pending reward for a given user.
     */
    function pendingReward(address _user) external view returns (uint256 pending) {
        UserInfo storage user = userInfo[_user];
        uint256 lpSupply = lpToken.balanceOf(address(this));
        uint256 accRewardPerShare_ = accRewardPerShare;

        if (block.timestamp > lastRewardTime && lpSupply != 0) {
            uint256 newReward = (block.timestamp - lastRewardTime) * rewardPerSecond;
            accRewardPerShare_ =
                accRewardPerShare_ +
                ((newReward * ACC_REWARD_PRECISION) / lpSupply);
        }
        pending = (((user.amount * accRewardPerShare_) / ACC_REWARD_PRECISION).toInt256() -
            user.rewardDebt).toUint256();
    }

    /**
     * @notice Update reward variables.
     * @dev Updates accRewardPerShare and lastRewardTime.
     */
    function updatePool() public {
        if (block.timestamp > lastRewardTime) {
            uint256 lpSupply = lpToken.balanceOf(address(this));
            if (lpSupply > 0) {
                uint256 newReward = (block.timestamp - lastRewardTime) * rewardPerSecond;
                accRewardPerShare =
                    accRewardPerShare +
                    ((newReward * ACC_REWARD_PRECISION) / lpSupply);
            }
            lastRewardTime = block.timestamp;
            emit LogUpdatePool(lastRewardTime, lpSupply, accRewardPerShare);
        }
    }

    /**
     * @notice Deposit LP tokens for reward allocation.
     * @param amount LP token amount to deposit.
     * @param to The receiver of `amount` deposit benefit.
     */
    function deposit(uint256 amount, address to) public {
        updatePool();
        UserInfo storage user = userInfo[to];

        // Effects
        user.lastDepositedAt = block.timestamp;
        user.amount = user.amount + amount;
        user.rewardDebt =
            user.rewardDebt +
            ((amount * accRewardPerShare) / ACC_REWARD_PRECISION).toInt256();

        emit Deposit(msg.sender, amount, to);

        lpToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Withdraw LP tokens and claim rewards to `to`.
     * @param amount LP token amount to withdraw.
     * @param to Receiver of the LP tokens and rewards.
     */
    function withdraw(uint256 amount, address to) public {
        updatePool();
        UserInfo storage user = userInfo[msg.sender];
        int256 accumulatedReward = ((user.amount * accRewardPerShare) / ACC_REWARD_PRECISION)
            .toInt256();
        uint256 _pendingReward = (accumulatedReward - user.rewardDebt).toUint256();

        // Effects
        user.rewardDebt =
            accumulatedReward -
            ((amount * accRewardPerShare) / ACC_REWARD_PRECISION).toInt256();
        user.amount = user.amount - amount;

        emit Withdraw(msg.sender, amount, to);
        emit Claim(msg.sender, _pendingReward);

        // Interactions
        if (isEarlyWithdrawal(user.lastDepositedAt)) {
            uint256 penaltyAmount = _pendingReward * penaltyRate / 10000;
            rewardToken.safeTransferFrom(rewardTreasury, to, _pendingReward - penaltyAmount);
        } else {
            rewardToken.safeTransferFrom(rewardTreasury, to, _pendingReward);
        }
        lpToken.safeTransfer(to, amount);
    }

    /**
     * @notice Claim rewards and send to `to`.
     * @dev Here comes the formula to calculate reward token amount
     * @param to Receiver of rewards.
     */
    function claim(address to) public {
        updatePool();
        UserInfo storage user = userInfo[msg.sender];
        int256 accumulatedReward = ((user.amount * accRewardPerShare) / ACC_REWARD_PRECISION)
            .toInt256();
        uint256 _pendingReward = (accumulatedReward - user.rewardDebt).toUint256();

        // Effects
        user.rewardDebt = accumulatedReward;

        emit Claim(msg.sender, _pendingReward);

        // Interactions
        if (_pendingReward != 0) {
            if (isEarlyWithdrawal(user.lastDepositedAt)) {
                uint256 penaltyAmount = _pendingReward * penaltyRate / 10000;
                rewardToken.safeTransferFrom(rewardTreasury, to, _pendingReward - penaltyAmount);
            } else {
                rewardToken.safeTransferFrom(rewardTreasury, to, _pendingReward);
            }
        }
    }

    /**
     * @notice Withdraw without caring about rewards. EMERGENCY ONLY.
     * @param to Receiver of the LP tokens.
     */
    function emergencyWithdraw(address to) public {
        UserInfo storage user = userInfo[msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;

        emit EmergencyWithdraw(msg.sender, amount, to);

        // Note: transfer can fail or succeed if `amount` is zero.
        lpToken.safeTransfer(to, amount);
    }

    /**
     * @notice check if user in penalty period
     * @return isEarly
     */
    function isEarlyWithdrawal(uint256 lastDepositedTime) internal view returns (bool isEarly) {
        isEarly = block.timestamp <= lastDepositedTime + earlyWithdrawal;
    }

    function renounceOwnership() public override onlyOwner {
        revert();
    }
}
