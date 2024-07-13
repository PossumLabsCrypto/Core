// SPDX-License-Identifier: GPL-2.0-only
pragma solidity =0.8.19;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// ============================================
// ==              CUSTOM ERRORS             ==
// ============================================
error InsufficientRewards();
error InvalidAddress();
error InvalidAmount();
error InvalidDuration();
error NoStake();
error NotGuardian();
error NotWhitelisted();
error PermanentDestination();

/// @title Possum Core
/// @author Possum Labs
/// @notice This governance contract allows PSM stakers to collectively control incentive distributions and be rewarded
/* Users make a committment to stake PSM at least for a chosen duration upon staking
/* The longer the commitment period, the higher the Core Fragments (CF) accrual APR
/* CF can be spent to distribute PSM incentives to allowed addresses that are listed by the Guardian
/* The Guardian can list and delist addresses. There will be at least 1 permanent address that cannot be delisted.
/* Every 1 CF spent provides 1 PSM in rewards to the staker.(if there are enough rewards)
/* The CF accrual APR is applied to the combined balance of staked PSM and earned rewards which enables compounding
/* Staked PSM can be unstaked anytime irrespective of the chosen stake duration
/* If a stake is withdrawn before the stake duration passed, accumulated rewards are forfeited proportionally
/* If users unstake after the stake expired, they receive their original stake and all accrued rewards
/* Users can add more PSM to their existing stake but must stake at least as long as the remaining commitment period
/* Users can remain staked to accrue CF and compound rewards after their commitment period has passed
*/
contract PossumCore {
    constructor() {
        whitelist[PERMANENT_I] = true;
        whitelist[PERMANENT_II] = true;
        whitelist[PERMANENT_III] = true;
    }

    // ============================================
    // ==            GLOBAL VARIABLES            ==
    // ============================================
    address private constant GUARDIAN = 0xAb845D09933f52af5642FC87Dd8FBbf553fd7B33; // PSM multi-sig
    address private constant PSM_ADDRESS = 0x17A8541B82BF67e10B0874284b4Ae66858cb1fd5;

    address private constant PERMANENT_I = 0xAb845D09933f52af5642FC87Dd8FBbf553fd7B33; // PSM Treasury
    address private constant PERMANENT_II = 0x24b7d3034C711497c81ed5f70BEE2280907Ea1Fa; // HLP Portal
    address private constant PERMANENT_III = 0x212Bbd56F6D4F999B2845adebd8cec147851E383; // PortalsV2 VirtualLP

    uint256 public constant SECONDS_PER_YEAR = 31536000; // Max stake duration
    uint256 public constant MAX_APR = 7200; // Accrual rate of CF at maximum stake duration (10000 = 100%)
    uint256 public constant MIN_APR = 1200; // Accrual rate of CF at stake duration = 0 (10000 = 100%)
    uint256 public constant DIFF_APR = 6000;
    uint256 private constant APR_SCALING = 10000;

    uint256 public stakedTokensTotal; // The PSM tokens deposited by stakers
    uint256 public reservedRewardsTotal; // Amount of PSM reserved for all stakers
    uint256 public distributed_PSM; // Amount of PSM distributed to allowed addresses (info only)
    uint256 public ativeParticipants; // Number of stakers who have done at least 1 distribution (info only)

    struct Stake {
        uint256 stakedBalance;
        uint256 stakeEndTime;
        uint256 reservedRewards;
        uint256 storedCoreFragments;
        uint256 lastDistributionTime;
        uint256 coreFragmentsAPR;
    }

    mapping(address user => Stake) public stakes; // associate users with their stake
    mapping(address user => uint256 distributedCF) public fragmentsDistributed; // CF sent to destinations (info only)
    mapping(address destination => bool allowed) public whitelist; // addresses that can receive PSM incentives

    // ============================================
    // ==                EVENTS                  ==
    // ============================================
    event Staked(address indexed user, uint256 amount);
    event UnstakeAndClaimed(address indexed user, uint256 amountWithdrawn, uint256 rewardsClaimed);
    event UnstakeAndForfeited(address indexed user, uint256 amountWithdrawn, uint256 rewardsForfeited);
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
    /// @notice Users stake PSM for a chosen duration to earn Core Fragments
    /// @dev This function allows PSM to be staked to earn CF
    /// @dev Users can add to their stake at any time which may prolong the stake duration
    /// @dev New stakes are only accepted if PSM are available in the contract
    /// @param _amount The amount of tokens staked
    /// @param _duration The number of seconds until rewards can be claimed after unstaking
    function stake(uint256 _amount, uint256 _duration) external {
        /// @dev Check that the amount is valid
        if (_amount == 0) {
            revert InvalidAmount();
        }

        /// @dev Check that the duration is valid
        if (_duration > SECONDS_PER_YEAR) revert InvalidDuration();

        /// @dev Check that PSM is available
        uint256 availablePSM = getAvailableTokens();
        if (availablePSM == 0) revert InsufficientRewards();

        /// @dev Cache variables
        uint256 duration = _duration;
        uint256 amount = _amount;
        Stake storage userStake = stakes[msg.sender];

        /// @dev Calculate and update the new stake balance
        uint256 oldStakedBalance = userStake.stakedBalance;

        /// @dev Calculate and cache the stake end time
        uint256 newEndTime = block.timestamp + duration; //@audit unchecked
        uint256 oldEndTime = userStake.stakeEndTime;

        /// @dev Ensure that the user stake duration used for calculations is at least the remaining duration
        /// @dev This avoids earning potential being lost when new stakes are added with a low stake duration
        duration = (newEndTime >= oldEndTime) ? duration : oldEndTime - block.timestamp;

        /// @dev Calculate the current Core Fragments of the user
        uint256 coreFragments = getFragments(msg.sender);

        /// @dev Calculate the new average Core Fragments accrual rate (APR)
        uint256 currentAPR = userStake.CoreFragmentsAPR;
        uint256 earningBalance = oldStakedBalance + userStake.reservedRewards;
        uint256 fragmentsAPR = _getFragmentsAPR(earningBalance, amount, duration, currentAPR);

        /// @dev Update User stake struct
        userStake.stakedBalance = oldStakedBalance + amount; //@audit unchecked
        userStake.stakeEndTime = (newEndTime > oldEndTime) ? newEndTime : oldEndTime;
        userStake.storedCoreFragments = coreFragments;
        userStake.lastDistributionTime = block.timestamp;
        userStake.CoreFragmentsAPR = fragmentsAPR;

        /// @dev Update the global stake information
        stakedTokensTotal = stakedTokensTotal + amount; //@audit unchecked

        /// @dev Transfer tokens to contract
        IERC20(PSM_ADDRESS).transferFrom(msg.sender, address(this), amount);

        /// @dev Emit the event with updated stake information
        emit Staked(msg.sender, amount);
    }

    /// @notice Enable users to withdraw their stake and claim rewards if the stake is matured
    /// @notice Allow partial withdrawals which affects the accumulated rewards proportionally
    /// @dev Update the user stake data
    /// @dev Update global stake data
    /// @dev If the stake duration has passed, transfer rewards to user, otherwise forfeit (back to contract)
    /// @dev Withdraw the amount and proportional rewards if applicable
    function unstakeAndClaim(uint256 _amount) external {
        if (_amount == 0) {
            revert InvalidAmount();
        }

        /// @dev Load user stake data & cache variables
        Stake storage userStake = stakes[msg.sender];

        uint256 balance = userStake.stakedBalance;
        /// @dev Check that the user has a stake
        if (balance == 0) revert NoStake();

        uint256 rewards = userStake.reservedRewards;
        uint256 amount = (_amount > balance) ? balance : _amount;
        uint256 affectedRewards = (rewards * amount) / balance;
        /// @dev Ensure that staker cannot withdraw without affecting some rewards if accrued
        /// @dev Prevent circumventing the forfeit logic by withdrawing small amounts & cause rounding to 0
        if (affectedRewards == 0 && rewards > 0) revert InvalidAmount();

        uint256 endTime = userStake.stakeEndTime;

        /// @dev Update the user stake
        uint256 fragments = getFragments(msg.sender);
        userStake.stakedBalance = userStake.stakedBalance - amount; //@audit unchecked
        userStake.reservedRewards = userStake.reservedRewards - affectedRewards; //@audit unchecked
        userStake.storedCoreFragments = fragments;
        userStake.lastDistributionTime = block.timestamp;

        /// @dev reset the stake end time if the user withdraws all to not conflict with new stakes
        if (userStake.stakedBalance == 0) userStake.stakeEndTime = 0;

        /// @dev Update global stake & reward trackers
        stakedTokensTotal = stakedTokensTotal - amount; //@audit unchecked
        reservedRewardsTotal = reservedRewardsTotal - affectedRewards; //@audit unchecked

        /// @dev If the stake duration has passed, add rewards to the amount to withdraw
        /// @dev If duration has not passed, rewards are forfeited and become available to other stakers
        uint256 amountToWithdraw = amount;
        if (block.timestamp >= endTime) {
            amountToWithdraw += affectedRewards; //@audit unchecked
        }

        /// @dev Transfer stake and potential rewards to user
        IERC20(PSM_ADDRESS).transfer(msg.sender, amountToWithdraw);

        /// @dev Emit event that a stake was withdrawn and rewards are claimed or forfeited
        if (block.timestamp >= endTime) {
            emit UnstakeAndClaimed(msg.sender, amountToWithdraw, affectedRewards);
        } else {
            emit UnstakeAndForfeited(msg.sender, amountToWithdraw, affectedRewards);
        }
    }

    // ============================================
    // ==        DISTRIBUTE INCENTIVES           ==
    // ============================================
    /// @notice Users can distribute Core Fragments (PSM) to allowed addresses
    /// @dev Allow stakers to distribute PSM to listed addresses and get rewards in return
    /// @dev Validity checks on inputs and available Core Fragments of the user
    /// @dev Reward the user for distributing Core Fragments with an equal amount of PSM
    /// @dev Prioritize rewarding the user if the contract is short on PSM
    /// @dev Track distributed rewards by the user in mapping (info only for later use)
    function distributeCoreFragments(address _destination, uint256 _amount) external {
        /// @dev Check that the destination is valid
        if (!whitelist[_destination]) {
            revert NotWhitelisted();
        }

        /// @dev calculate available Core Fragments
        uint256 userFragments = getFragments(msg.sender);
        /// @dev Check that the amount to distribute is valid
        if (userFragments < _amount || _amount == 0) {
            revert InvalidAmount();
        }

        /// @dev Calculate PSM tokens in contract that are available for distributions and rewards
        uint256 availablePSM = getAvailableTokens();

        /// @dev Check that PSM tokens are available
        if (availablePSM == 0) revert InsufficientRewards();

        /// @dev Initialize and cache parameters
        uint256 amount = _amount;
        address destination = _destination;
        uint256 rewards;
        uint256 distributed;

        /// @dev Calculate the amount of rewards for the user, new fragments balance and distributed tokens
        /// @dev The user earns as many PSM as Core Fragments distributed in normal situations
        /// @dev The increase of user rewards has priority over distributing tokens to the destination
        if (availablePSM < amount * 2) {
            if (availablePSM <= amount) {
                userFragments -= availablePSM; //@audit unchecked
                rewards = availablePSM;
                distributed = 0;
            } else {
                userFragments -= amount; //@audit unchecked
                rewards = amount;
                distributed = availablePSM - amount; //@audit unchecked
            }
        } else {
            userFragments -= amount; //@audit unchecked
            rewards = amount;
            distributed = amount;
        }

        /// @dev Load user stake data
        Stake storage userStake = stakes[msg.sender];
        /// @dev Update user stake data
        userStake.storedCoreFragments = userFragments;
        userStake.reservedRewards = userStake.reservedRewards + rewards; //@audit unchecked
        userStake.lastDistributionTime = block.timestamp;

        /// @dev Update tracking of distributed fragments & active participants
        if (fragmentsDistributed[msg.sender] == 0) ativeParticipants = ativeParticipants + 1;
        fragmentsDistributed[msg.sender] = fragmentsDistributed[msg.sender] + distributed;

        /// @dev Update global tracker of rewards and distributed tokens
        reservedRewardsTotal = reservedRewardsTotal + rewards; //@audit unchecked blocks
        distributed_PSM = distributed_PSM + distributed; //@audit unchecked blocks

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
    /// @return availableTokens is the PSM amount that can be distributed or reserved as rewards
    function getAvailableTokens() public view returns (uint256 availableTokens) {
        unchecked {
            availableTokens = IERC20(PSM_ADDRESS).balanceOf(address(this)) - stakedTokensTotal - reservedRewardsTotal;
        } //@audit unchecked
    }

    /// @notice Return the amount of Core Fragments that the user can distribute
    /// @dev Return the total amount of CF that the user can distribute
    /// @return availableFragments The CF that can be distributed by the user to the whitelist
    function getFragments(address _user) public view returns (uint256 availableFragments) {
        /// @dev Check for valid user
        if (_user == address(0)) {
            revert InvalidAddress();
        }

        /// @dev Load user stake into memory
        Stake memory userStake = stakes[_user];

        /// @dev Get the parameters necessary to calculate the accrued fragments
        uint256 timePassed = block.timestamp - userStake.lastDistributionTime; //@audit unchecked
        uint256 earningBalance = userStake.stakedBalance + userStake.reservedRewards;

        /// @dev Calculate the available Core Fragments of the user
        availableFragments = userStake.storedCoreFragments
            + (earningBalance * timePassed * userStake.coreFragmentsAPR) / (APR_SCALING * SECONDS_PER_YEAR);
    }

    /// @dev Calculate and return the weighted Core Fragments accrual rate (APR) for compounding stakes
    /// @dev CF accrue at the weighted average APR over time
    function _getFragmentsAPR(uint256 _earningBalance, uint256 _newAmount, uint256 _newDuration, uint256 _currentAPR)
        internal
        pure
        returns (uint256 fragmentsAPR)
    {
        /// @dev Calculate APR for the new stake amount
        uint256 newAPR = MIN_APR + ((DIFF_APR * _newDuration) / SECONDS_PER_YEAR);

        /// @dev Calculate the APR weight of old and new stake
        uint256 newStakeWeight = newAPR * _newAmount;
        uint256 oldStakeWeight = _currentAPR * _earningBalance;

        /// @dev Calculate weighted average of both APRs
        /// @dev Ensure users are not negatively affected by past low APRs when extending the lock
        fragmentsAPR = (newStakeWeight + oldStakeWeight) / (_newAmount + _earningBalance);
        fragmentsAPR = (fragmentsAPR > newAPR) ? fragmentsAPR : newAPR;
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

        whitelist[_destination] = _listed;

        /// @dev Emit the event that the whitelist was updated
        emit WhitelistUpdated(_destination, _listed);

        /// @dev Guarantee at least one of the permanent addresses to remain
        if (!whitelist[PERMANENT_I] && !whitelist[PERMANENT_II] && !whitelist[PERMANENT_III]) {
            revert PermanentDestination();
        }
    }
}
