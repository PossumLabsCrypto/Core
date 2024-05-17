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
error DurationTooLong();
error DurationTooShort();
error InsufficientRewards();
error InvalidAddress();
error InvalidAmount();
error InvalidConstructor();
error InvalidDuration();
error NoStake();
error NotGuardian();
error NotWhitelisted();
error PermanentDestination();

/// @title Possum Core
/// @author Possum Labs
/// @notice This governance contract allows PSM stakers to collectively control incentive distributions and be rewarded
/* Users make a committment to stake for a chosen duration upon staking
/* The longer the chosen duration, the higher the Core Fragments (CF) accrual APR
/* CF can be spent to distribute PSM incentives to allowed addresses that are listed by the Guardian
/* Every 1 CF spent provides 1 PSM in rewards to the user
/* The CF accrual APR is applied to the combined balance of staked PSM and earned rewards which enables compounding
/* Staked PSM can be unstaked anytime irrespective of the chosen stake duration
/* If a stake is withdrawn before the stake duration passed, all accumulated rewards are forfeited
/* If users unstake after the stake expired, they get their stake and all accrued rewards
/* Users can add more PSM to their existing stake but must stake at least as long as the remaining stake duration
/* Users can remain staked and accrue CF after their stake duration has passed
*/
contract PossumCore is ReentrancyGuard {
    constructor() {}

    // ============================================
    // ==            GLOBAL VARIABLES            ==
    // ============================================
    using SafeERC20 for IERC20;

    uint256 private constant SECONDS_PER_YEAR = 31536000;
    address private constant GUARDIAN = 0xa0BFD02a7a47CBCA7230E03fbf04A196C3E771E3;
    address private constant PSM_ADDRESS = 0x17A8541B82BF67e10B0874284b4Ae66858cb1fd5;

    address private constant PERMANENT_I = 0xAb845D09933f52af5642FC87Dd8FBbf553fd7B33; // PSM Treasury
    address private constant PERMANENT_II = 0x24b7d3034C711497c81ed5f70BEE2280907Ea1Fa; // HLP Portal
    address private constant PERMANENT_III = 0x212Bbd56F6D4F999B2845adebd8cec147851E383; // PortalsV2 VirtualLP

    uint256 public constant MAX_STAKE_DURATION = 31536000;
    uint256 public constant MAX_APR = 7000; // Accrual rate of GP at maximum stake duration (10000 = 100%)
    uint256 public constant MIN_APR = 2000; // Accrual rate of GP at stake duration = 0 (10000 = 100%)
    uint256 private constant APR_SCALING = 10000;

    uint256 public stakedTokensTotal; // The PSM tokens users have staked
    uint256 public reservedRewardsTotal; // Amount of PSM reserved for all stakers
    uint256 public distributed_PSM; // Amount of PSM distributed to allowed addresses

    struct Stake {
        uint256 stakedBalance;
        uint256 stakeEndTime;
        uint256 reservedRewards;
        uint256 savedCoreFragments;
        uint256 lastDistributionTime;
        uint256 CoreFragmentsAPR;
    }

    mapping(address user => Stake) public stakes; // associate users with their stake
    mapping(address destination => bool allowed) public whitelist; // addresses that can receive PSM incentives

    // ============================================
    // ==                EVENTS                  ==
    // ============================================
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount, uint256 rewards);
    event CoreFragmentsPosted(address indexed user, address indexed destination, uint256 amount);

    event WhitelistUpdated(address indexed destination, bool listed);

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
    /// @notice Users stake PSM for a chosen duration to earn Governance Power
    /// @dev This function allows PSM to be staked to earn GP
    /// @dev Users can add to their stake at any time which may prolong the stake duration
    /// @dev New stakes are only accepted if rewards are available
    /// @param _amount The amount of tokens staked
    /// @param _duration The number of seconds until rewards can be claimed upon unstaking
    function stake(uint256 _amount, uint256 _duration) external nonReentrant {
        /// @dev Check that the amount is valid
        if (_amount == 0) {
            revert InvalidAmount();
        }

        /// @dev Check that the duration is valid
        if (_duration > MAX_STAKE_DURATION) revert InvalidDuration();

        /// @dev Cache variables
        uint256 duration = _duration;
        uint256 amount = _amount;
        Stake storage userStake = stakes[msg.sender];

        /// @dev Calculate and update the new stake balance
        uint256 oldStakedBalance = userStake.stakedBalance;
        userStake.stakedBalance = oldStakedBalance + amount;

        /// @dev Calculate and update the stake end time, using the greater of existing or prolonged end time
        uint256 newEndTime = block.timestamp + duration;
        uint256 oldEndTime = userStake.stakeEndTime;
        userStake.stakeEndTime = (newEndTime > oldEndTime) ? newEndTime : oldEndTime;

        /// @dev Ensure that the user stake duration used for calculations is at least the remaining duration
        /// @dev This avoids earning potential being lost when new stakes are added with a low stake duration
        duration = (newEndTime >= oldEndTime) ? duration : oldEndTime - block.timestamp;

        /// @dev Save current Core Fragments of the user & update time
        userStake.savedCoreFragments = getFragments(msg.sender);
        userStake.lastDistributionTime = block.timestamp;

        /// @dev Update the Core Fragments accrual rate (APR)
        uint256 currentAPR = userStake.CoreFragmentsAPR;
        uint256 earningBalance = oldStakedBalance + userStake.reservedRewards;
        userStake.CoreFragmentsAPR = _getFragmentsAPR(earningBalance, amount, duration, currentAPR);

        /// @dev Update the global stake information
        stakedTokensTotal += amount;

        /// @dev Transfer tokens to contract
        IERC20(PSM_ADDRESS).transferFrom(msg.sender, address(this), amount);

        /// @dev Emit the event with updated stake information
        emit Staked(msg.sender, amount);
    }

    /// @notice Enable users to withdraw their stake and claim all rewards if the stake is matured
    /// @dev Update global stake data
    /// @dev Delete the user stake data
    /// @dev If the stake duration has passed, claim all rewards to user, otherwise forfeit all rewards
    /// @dev Withdraw the staked amount of LP tokens and rewards if applicable
    function unstakeAndClaim() external nonReentrant {
        /// @dev Load user stake data
        Stake memory userStake = stakes[msg.sender];
        uint256 rewards = userStake.reservedRewards;

        /// @dev Check that the user has a stake
        if (userStake.stakedBalance == 0) {
            revert NoStake();
        }

        /// @dev Update global stake & reward trackers
        stakedTokensTotal -= userStake.stakedBalance;
        reservedRewardsTotal -= rewards;

        /// @dev Delete the user stake
        delete stakes[msg.sender];

        /// @dev Add rewards to the unstaked amount if the stake duration has passed
        /// @dev If duration has not passed, PSM rewards become available in the contract (forfeited)
        uint256 amount = userStake.stakedBalance;
        if (block.timestamp >= userStake.stakeEndTime) {
            amount += rewards;
        }

        /// @dev Transfer stake and potential rewards to user
        IERC20(PSM_ADDRESS).transfer(msg.sender, amount);

        /// @dev Emit event that a stake was withdrawn and rewards claimed
        emit Unstaked(msg.sender, amount, rewards);
    }

    // ============================================
    // ==        DISTRIBUTE INCENTIVES           ==
    // ============================================
    /// @notice Users can distribute Core Fragments (PSM) to whitelisted addresses
    /// @dev Allow stakers to distribute PSM to whitelisted addresses and get rewards in return
    /// @dev Validity checks on inputs and available Core Fragments of the user
    /// @dev Reward the user for distributing Core Fragments with an equal amount
    /// @dev Prioritize rewarding the user if the contract is short on PSM
    function distributeCoreFragments(address _destination, uint256 _amount) external nonReentrant {
        /// @dev Check that the destination is valid
        if (!whitelist[_destination]) {
            revert NotWhitelisted();
        }

        /// @dev Calculate PSM tokens available for distributions and rewards
        uint256 availablePSM = getAvailableTokens();

        /// @dev Check that PSM tokens are available
        if (availablePSM == 0) revert InsufficientRewards();

        /// @dev Initialize and cache parameters
        uint256 amount = _amount;
        address destination = _destination;
        uint256 rewards;
        uint256 distributed;

        /// @dev Load user stake data and calculate available Core Fragments
        Stake storage userStake = stakes[msg.sender];
        uint256 userFragments = getFragments(msg.sender);

        /// @dev Check that the amount to distribute is valid
        if (userFragments < amount || amount == 0) {
            revert InvalidAmount();
        }

        /// @dev Calculate the amount of rewards for the user, new fragments balance and distributed tokens
        /// @dev The user earns as many PSM as Core Fragments distributed in normal situations
        /// @dev The increase of user rewards has priority over distributing tokens to the destination
        if (availablePSM < amount * 2) {
            if (availablePSM <= amount) {
                userFragments -= availablePSM;
                rewards = availablePSM;
                distributed = 0;
            } else {
                userFragments -= amount;
                rewards = amount;
                distributed = availablePSM - amount;
            }
        } else {
            userFragments -= amount;
            rewards = amount;
            distributed = amount;
        }

        /// @dev Update user stake data
        userStake.savedCoreFragments = userFragments;
        userStake.reservedRewards += rewards;
        userStake.lastDistributionTime = block.timestamp;

        /// @dev Update global tracker of rewards and distributed tokens
        reservedRewardsTotal += rewards;
        distributed_PSM += distributed;

        /// @dev Transfer incentives to destination
        if (distributed > 0) {
            IERC20(PSM_ADDRESS).transfer(destination, distributed);
        }

        /// @dev Emit event that incentives have been distributed
        emit CoreFragmentsPosted(msg.sender, destination, distributed);
    }

    // ============================================
    // ==            VIEW FUNCTIONS              ==
    // ============================================
    /// @notice Return the number of available PSM for distribution & rewards
    /// @return availableTokens PSM amount that can be distributed or reserved as rewards
    function getAvailableTokens() public view returns (uint256 availableTokens) {
        availableTokens = IERC20(PSM_ADDRESS).balanceOf(address(this)) - stakedTokensTotal - reservedRewardsTotal;
    }

    ///////////// OVERHAUL //////////////////////
    ////////////////////////////////////////////
    ///////////////////////////////////////////

    /// @notice Return the amount of Core Fragements (PSM) that the user can distribute as incentives
    /// @dev Return the total amount of PSM that the user can distribute as incentives
    /// @return availableFragments The PSM that can be distributed by the user to the whitelist
    function getFragments(address _user) public view returns (uint256 availableFragments) {
        /// @dev Load user stake into memory
        Stake memory userStake = stakes[_user];

        /// @dev Check for valid user
        if (_user == address(0)) {
            revert InvalidAddress();
        }

        /// @dev Get the parameters necessary to calculate the accrued fragments
        uint256 timePassed = block.timestamp - userStake.lastDistributionTime;
        uint256 earningBalance = userStake.stakedBalance + userStake.reservedRewards;

        /// @dev Calculate the available Core Fragments of the user
        availableFragments = userStake.savedCoreFragments
            + (earningBalance * timePassed * userStake.CoreFragmentsAPR) / (APR_SCALING * SECONDS_PER_YEAR);
    }

    /// @dev Calculate and return the weighted Core Fragments accrual rate (APR) for compounding stakes
    function _getFragmentsAPR(uint256 _earningBalance, uint256 _newAmount, uint256 _newDuration, uint256 _currentAPR)
        internal
        pure
        returns (uint256 fragmentsAPR)
    {
        /// @dev Calculate APR for the new stake amount
        uint256 newAPR = MIN_APR + (((MAX_APR - MIN_APR) * _newDuration) / MAX_STAKE_DURATION);

        /// @dev Calculate the APR weight of old and new stake
        uint256 newStakeWeight = newAPR * _newAmount;
        uint256 oldStakeWeight = _currentAPR * _earningBalance;

        /// @dev Calculate weighted average of both APRs
        fragmentsAPR = (newStakeWeight + oldStakeWeight) / (_newAmount + _earningBalance);
    }

    // ============================================
    // ==           GUARDIAN FUNCTIONS           ==
    // ============================================
    /// @notice Add or remove an address from the whitelist
    /// @dev Allow the Guardian to update the whitelist mapping
    /// @param _destination The address added or removed from the whitelist
    function updateWhitelist(address _destination, bool _listed) external onlyGuardian {
        if (_destination == address(0)) {
            revert InvalidAddress();
        }

        /// @dev Prevent updating the status of unchangeable destinations
        if (_destination == PERMANENT_I || _destination == PERMANENT_II || _destination == PERMANENT_III) {
            revert PermanentDestination();
        }

        whitelist[_destination] = _listed;

        /// @dev Emit the event that the whitelist was updated
        emit WhitelistUpdated(_destination, _listed);
    }
}
