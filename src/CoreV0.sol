// SPDX-License-Identifier: GPL-2.0-only
pragma solidity =0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// ============================================
// ==              CUSTOM ERRORS             ==
// ============================================
error DurationNotPassed();
error InsufficientRewards();
error InvalidAddress();
error InvalidAmount();
error InvalidConstructor();
error InvalidDuration();
error NoTribute();
error NotGuardian();
error NotWhitelisted();

/// @title TimeRift
/// @author Possum Labs
/// @notice Users can stake LP tokens in this contract to receive rewards and participate in governance
/* Users choose a staking duration for their tokens when staking
/* The longer the chosen duration, the higher the PSM reward APR for the staker
/* Upon staking, a tribute is taken from the staked LP that can be withdrawn by the Guardian
/* Staked LP tokens can be unstaked anytime irrespective of the chosen stake duration
/* If a stake is withdrawn before the stake duration expires, all rewards are forfeited
/* If users unstake after the stake expired, they get their remaining LP tokens and all accrued rewards
/* Users can add more LP tokens to their stake but must stake at least for as long as the remaining stake duration
/* Stakers earn the right to distribute PSM incentives over time
/* These incentives can be distributed to allowed addresses that are listed by the Guardian address
/* Distributing incentives increases the governance level of users
/* A higher governance level allows to distribute even more incentives over time
/* The governance level has no direct influence on rewards earned from stakings
*/
contract CoreV0 is ReentrancyGuard {
    constructor(uint256 _PSM_IN_LP, uint256 _LP_TOTAL_SUPPLY) {
        if (_PSM_IN_LP == 0) {
            revert InvalidConstructor();
        }
        if (_LP_TOTAL_SUPPLY == 0) {
            revert InvalidConstructor();
        }
        PSM_IN_LP = _PSM_IN_LP;
        LP_TOTAL_SUPPLY = _LP_TOTAL_SUPPLY;
    }

    // ============================================
    // ==            GLOBAL VARIABLES            ==
    // ============================================
    using SafeERC20 for IERC20;
    uint256 private immutable PSM_IN_LP;
    uint256 private immutable LP_TOTAL_SUPPLY;
    uint256 private constant SECONDS_PER_YEAR = 31536000;
    address private constant HLP_PORTAL =
        0x24b7d3034C711497c81ed5f70BEE2280907Ea1Fa;

    address public constant GUARDIAN =
        0xAb845D09933f52af5642FC87Dd8FBbf553fd7B33;
    address public constant PSM_ADDRESS =
        0x17A8541B82BF67e10B0874284b4Ae66858cb1fd5;
    address public constant STAKING_TOKEN =
        0x8BfAa6260FF474536f2f76EFdB4A2A782f98C798;

    uint256 public constant TRIBUTE_PERCENT = 5;
    uint256 public constant MAX_STAKE_DURATION = 31536000;
    uint256 public constant MAX_APR = 50;

    uint256 public stakedTokensTotal; // The LP tokens users have staked
    uint256 public withdrawableTokensTotal; // The LP tokens users can withdraw, rest is available to the Guardian
    uint256 public reservedRewardsTotal; // Amount of PSM reserved for all stakers
    uint256 public distributedIncentives; // Amount of PSM distributed to allowed addresses

    struct Stake {
        uint256 stakedBalance;
        uint256 reservedRewards;
        uint256 incentivesDistributed;
        uint256 savedIncentives;
        uint256 stakeEndTime;
        uint256 lastDistributionTime;
    }

    mapping(address user => Stake) public stakes; // associate users with their stake
    mapping(address user => uint256 level) public userLevels; // associate users with their governance level
    mapping(address => bool allowed) public whitelist; // addresses that can receive PSM incentives

    // ============================================
    // ==                EVENTS                  ==
    // ============================================
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardsSent(address indexed user, uint256 amount);
    event IncentivesDistributed(
        address indexed user,
        address indexed destination,
        uint256 amount
    );

    event WhitelistUpdated(address destination, bool listed);

    // ============================================
    // ==               MODIFIERS                ==
    // ============================================
    modifier onlyGuardian() {
        if (msg.sender != GUARDIAN) {
            revert NotGuardian();
        }
        _;
    }

    // ============================================
    // ==           STAKING & UNSTAKING          ==
    // ============================================
    /// @notice Users stake LP tokens for a chosen duration to gain rewards and control over incentives
    /// @dev This function allows a specific LP token to be staked
    /// @dev Upon staking, a fee is applied on the principal that can be withdrawn by the Guardian
    /// @dev Users can add to stakes at any time which may prolong the duration until rewards can be claimed
    /// @dev The rewards for stakers are reserved immediately to ensure payouts at maturity
    /// @dev New stakes are only accepted if sufficient rewards are available
    /// @param _amount The amount of LP tokens staked
    /// @param _duration The number of seconds until rewards can be claimed upon unstaking
    /// @param _minAddedRewards The minimum number of (additional) PSM rewards accepted
    function stake(
        uint256 _amount,
        uint256 _duration,
        uint256 _minAddedRewards
    ) external {
        /// @dev Check that the amount is valid
        if (_amount == 0) {
            revert InvalidAmount();
        }

        /// @dev Set helper variables for conditions
        uint256 time = block.timestamp;
        uint256 endTime = time + _duration;

        Stake storage userStake = stakes[msg.sender];
        uint256 stakedBalance = userStake.stakedBalance + _amount;
        uint256 oldRewards = userStake.reservedRewards;
        uint256 addedRewards = getRewardsForStake(_amount, _duration);
        uint256 newRewards = oldRewards + addedRewards;

        /// @dev Only allow extending the stake duration
        if (endTime < userStake.stakeEndTime) {
            revert InvalidDuration();
        }

        /// @dev Ensure that user receives the desired rewards
        if (addedRewards < _minAddedRewards) {
            revert InsufficientRewards();
        }

        /// @dev Update the user's stake information
        userStake.stakedBalance = stakedBalance;
        userStake.reservedRewards = newRewards;
        userStake.stakeEndTime = endTime;
        userStake.savedIncentives += getUserAvailableIncentives(msg.sender);
        userStake.lastDistributionTime = time;

        /// @dev Update the global stake information
        stakedTokensTotal += _amount;
        withdrawableTokensTotal += (_amount * (100 - TRIBUTE_PERCENT)) / 100;
        reservedRewardsTotal += addedRewards;

        /// @dev Transfer tokens to contract
        IERC20(STAKING_TOKEN).safeTransferFrom(
            msg.sender,
            address(this),
            _amount
        );

        /// @dev Emit the event with updated stake information
        emit Staked(msg.sender, _amount);
    }

    /// @notice Enable users to withdraw their stake and claim rewards if stake is mature
    /// @dev Withdraw the staked amount of LP tokens less tribute
    /// @dev If the stake duration has passed, claim all rewards, otherwise forfeit
    function unstakeAndClaimRewards() external {
        /// @dev Check that the stake duration has passed
        if (1 == 1) {
            revert DurationNotPassed();
        }
    }

    // ============================================
    // ==        DISTRIBUTE INCENTIVES           ==
    // ============================================
    function distributeIncentives(
        address _destination,
        uint256 _amount
    ) external {
        /// @dev Check that the destination is valid
        if (!whitelist[_destination]) {
            revert InvalidAddress();
        }

        /// @dev Load user stake data and calculate distributable incentives
        uint256 availableIncentives = getUserAvailableIncentives(msg.sender);

        /// @dev Check that the amount is valid
        if (availableIncentives < _amount || _amount == 0) {
            revert InvalidAmount();
        }

        /// @dev Check that enough PSM are available for distribution
        uint256 availableRewards = getAvailableRewards();
        if (_amount > availableRewards) {
            revert InsufficientRewards();
        }

        /// @dev Update user stake data
        Stake storage _stake = stakes[msg.sender];
        _stake.lastDistributionTime = block.timestamp;
        _stake.incentivesDistributed += _amount;

        /// @dev Check if saved incentives must be used
        uint256 floatingIncentives = availableIncentives -
            _stake.savedIncentives;
        uint256 deductible = (floatingIncentives < _amount)
            ? _amount - floatingIncentives
            : 0;
        _stake.savedIncentives -= deductible;

        /// @dev Update user governance level
        /// @dev Staked value is normed to the LP value in PSM at deployment of this contract, not real time
        /// @dev Active participants can gain roughly 200 levels in the first year (exponential growth)
        uint256 stakedValue = (2 * PSM_IN_LP * _stake.stakedBalance) /
            LP_TOTAL_SUPPLY;
        userLevels[msg.sender] =
            (_stake.incentivesDistributed * 630) /
            stakedValue;

        /// @dev Update global tracker of distributed incentives
        distributedIncentives += _amount;

        /// @dev Transfer incentives to destination
        IERC20(PSM_ADDRESS).transfer(_destination, _amount);

        /// @dev Emit event that incentives have been distributed
        emit IncentivesDistributed(msg.sender, _destination, _amount);
    }

    // ============================================
    // ==           GUARDIAN FUNCTIONS           ==
    // ============================================
    /// @notice Withdraw an ERC20 token to the Guardian
    /// @dev The function transfers a non-essential token from the contract to the Guardian
    /// @param _token The address of the token to recycle
    function recoverToken(address _token) external onlyGuardian {
        if (
            _token == STAKING_TOKEN ||
            _token == PSM_ADDRESS ||
            _token == address(0)
        ) {
            revert InvalidAddress();
        }

        uint256 balance = IERC20(_token).balanceOf(address(this));
        if (balance == 0) {
            revert InvalidAmount();
        }

        IERC20(_token).safeTransfer(GUARDIAN, balance);
    }

    /// @notice Add or remove an address from the whitelist
    /// @dev Allow the guardian to update the whitelist mapping
    /// @param _destination The address added or removed from the whitelist
    function updateWhitelist(
        address _destination,
        bool _listed
    ) external onlyGuardian {
        if (_destination == address(0)) {
            revert InvalidAddress();
        }

        whitelist[_destination] = _listed;

        /// @dev Emit the event that the whitelist was updated
        emit WhitelistUpdated(_destination, _listed);
    }

    /// @notice Enable the Guardian to withdraw accrued tributes
    /// @dev Withdraw accrued tributes in LP tokens to Guardian address
    function withdrawTribute() external onlyGuardian {
        /// @dev Check that there are accrued fees
        if (withdrawableTokensTotal >= stakedTokensTotal) {
            revert NoTribute();
        }

        /// @dev Withdraw the fees to the Guardian address
        uint256 tribute = stakedTokensTotal - withdrawableTokensTotal;
        IERC20(STAKING_TOKEN).transfer(GUARDIAN, tribute);
    }

    // ============================================
    // ==            VIEW FUNCTIONS              ==
    // ============================================
    /// @notice Return the number of available PSM rewards for new stakes
    /// @dev Return the available PSM rewards for new stakes
    /// @return availableRewards The rewards that can be reserved by new stakes
    function getAvailableRewards()
        public
        view
        returns (uint256 availableRewards)
    {
        availableRewards =
            IERC20(PSM_ADDRESS).balanceOf(address(this)) -
            reservedRewardsTotal;
    }

    /// @notice Display the potential rewards a user can get on a particular stake
    /// @dev Calculate staking rewards for a new stake
    /// @return rewards The amount of PSM reserved for this stake
    function getRewardsForStake(
        uint256 _amount,
        uint256 _duration
    ) public view returns (uint256 rewards) {
        /// @dev Ensure that duration is valid
        if (_duration > MAX_STAKE_DURATION) {
            revert InvalidDuration();
        }

        /// @dev Get the available rewards in contract
        uint256 availableRewards = getAvailableRewards();

        /// @dev reward APR increases linear with stake duration, hence rewards increase exponential
        uint256 grossRewards = ((2 * PSM_IN_LP * MAX_APR * _duration ** 2) *
            _amount) /
            (LP_TOTAL_SUPPLY * SECONDS_PER_YEAR * MAX_STAKE_DURATION * 100);

        /// @dev Ensure that rewards cannot be greater than available rewards
        rewards = (grossRewards > availableRewards)
            ? availableRewards
            : grossRewards;
    }

    /// @notice Return the amount of PSM that the user can distribute as incentives
    /// @dev Return the amount of PSM that the user can distribute as incentives
    /// @return availableIncentives The PSM that can be distributed by the user
    function getUserAvailableIncentives(
        address _user
    ) public view returns (uint256 availableIncentives) {
        /// @dev Input validation
        if (_user == address(0)) {
            revert InvalidAddress();
        }

        /// @dev Load user stake data into memory
        Stake memory userStake = stakes[_user];

        /// @dev Get the governance level of the user and calculate incentive accrual rate
        /// @dev Level 100 users can distribute roughly 31% of their staked value per year in incentives
        /// @dev Staked value is normed to the LP value in PSM at deployment of this contract, not real time
        uint256 level = (userLevels[_user] > 100) ? userLevels[_user] : 100;
        uint256 stakedValue = (2 * PSM_IN_LP * userStake.stakedBalance) /
            LP_TOTAL_SUPPLY;
        uint256 accrualRate = (stakedValue * level) / 1e10;
        uint256 timePassed = userStake.lastDistributionTime - block.timestamp;

        /// @dev check if the user has an active stake and calculate available incentives
        if (userStake.lastDistributionTime > 0) {
            availableIncentives =
                userStake.savedIncentives +
                (timePassed * accrualRate);
        }
    }
}
