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
    /// `amount` token amount the user has provided.
    /// `scaledBalance` scaled balance of the user.
    /// `lastDepositedAt` The timestamp of the last deposit.
    struct UserInfo {
        uint256 amount;
        uint256 scaledBalance;
        uint256 lastDepositedAt;
    }

    uint256 private constant ONE = 1e18;

    /// @notice Address of the staking token.
    IERC20Upgradeable public token;

    /// @notice reward treasury wallet
    address public rewardTreasury;

    /********************** Status ***********************/

    /// @notice Amount of reward token allocated per second
    uint256 public rewardPerSecond;

    /// @notice reward index
    uint256 public accRewardIndex;

    /// @notice total staked token amount
    uint256 public totalStaked;

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
    event Claim(address indexed user, uint256 amount);

    event LogUpdatePool(uint256 lastRewardTime, uint256 totalStaked, uint256 accRewardIndex);
    event LogRewardPerSecond(uint256 rewardPerSecond);
    event LogRewardTreasury(address indexed treasury);
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
        accRewardIndex = ONE;
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
        rewardInTreasury = token.balanceOf(rewardTreasury);
        rewardAllowedForThisPool = token.allowance(rewardTreasury, address(this));
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
     * @notice View function to see balance of a user.
     * @dev It doens't update accRewardIndex, it's just a view function.
     *
     *  user balance = user.scaledBalance * current index
     *
     * @param _user Address of user.
     * @return pending reward for a given user.
     */
    function pendingReward(address _user) external view returns (uint256 pending) {
        UserInfo storage user = userInfo[_user];
        uint256 accRewardIndex_ = accRewardIndex;

        if (block.timestamp > lastRewardTime && totalStaked != 0) {
            uint256 newReward = (block.timestamp - lastRewardTime) * rewardPerSecond;
            accRewardIndex_ = accRewardIndex_ * (ONE + (newReward * ONE) / totalStaked) / ONE;
        }
        pending = user.scaledBalance * accRewardIndex_ / ONE - user.amount;
    }

    /**
     * @notice Update reward variables.
     * @dev Updates accRewardIndex, totalStaked and lastRewardTime.
     */
    function updatePool() public {
        if (block.timestamp > lastRewardTime) {
            if (totalStaked > 0) {
                uint256 newReward = (block.timestamp - lastRewardTime) * rewardPerSecond;
                accRewardIndex = accRewardIndex * (ONE + (newReward * ONE) / totalStaked) / ONE;
                totalStaked = totalStaked + newReward;
            }
            lastRewardTime = block.timestamp;
            emit LogUpdatePool(lastRewardTime, totalStaked, accRewardIndex);
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
        user.lastDepositedAt = block.timestamp;
        user.amount = user.amount + amount;
        totalStaked = totalStaked + amount;
        user.scaledBalance = user.scaledBalance + amount * ONE / accRewardIndex;

        emit Deposit(msg.sender, amount, to);

        token.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Withdraw tokens and claim rewards to `to`.
     * @param amount token amount to withdraw.
     * @param to Receiver of the tokens and rewards.
     */
    function withdraw(uint256 amount, address to) public {
        updatePool();
        UserInfo storage user = userInfo[msg.sender];
        uint256 balance = (user.scaledBalance * accRewardIndex) / ONE;
        uint256 _pendingReward = balance - user.amount;

        // Effects
        user.scaledBalance = user.scaledBalance - (amount * ONE / accRewardIndex);
        user.amount = user.amount - amount;
        totalStaked = totalStaked - amount;

        emit Withdraw(msg.sender, amount, to);
        emit Claim(msg.sender, _pendingReward);

        // Interactions
        if (isEarlyWithdrawal(user.lastDepositedAt)) {
            uint256 penaltyAmount = _pendingReward * penaltyRate / 10000;
            token.safeTransferFrom(rewardTreasury, to, _pendingReward - penaltyAmount);
        } else {
            token.safeTransferFrom(rewardTreasury, to, _pendingReward);
        }
        token.safeTransfer(to, amount);
    }

    /**
     * @notice Claim rewards and send to `to`.
     * @dev Here comes the formula to calculate reward token amount
     * @param to Receiver of rewards.
     */
    function claim(address to) public {
        updatePool();
        UserInfo storage user = userInfo[msg.sender];
        uint256 balance = (user.scaledBalance * accRewardIndex) / ONE;
        uint256 _pendingReward = balance - user.amount;

        // Effects
        user.scaledBalance = user.scaledBalance - (_pendingReward * ONE / accRewardIndex);
        totalStaked = totalStaked - _pendingReward;

        emit Claim(msg.sender, _pendingReward);

        // Interactions
        if (_pendingReward != 0) {
            if (isEarlyWithdrawal(user.lastDepositedAt)) {
                uint256 penaltyAmount = _pendingReward * penaltyRate / 10000;
                token.safeTransferFrom(rewardTreasury, to, _pendingReward - penaltyAmount);
            } else {
                token.safeTransferFrom(rewardTreasury, to, _pendingReward);
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
        uint256 balance = (user.scaledBalance * accRewardIndex) / ONE;
        totalStaked = totalStaked - balance;
        user.amount = 0;
        user.scaledBalance = 0;

        emit EmergencyWithdraw(msg.sender, amount, to);

        // Note: transfer can fail or succeed if `amount` is zero.
        token.safeTransfer(to, amount);
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
