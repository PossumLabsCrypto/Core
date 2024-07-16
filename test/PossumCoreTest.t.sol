// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PossumCore} from "src/PossumCore.sol";

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

contract PossumCoreTest is Test {
    uint256 private constant SECONDS_PER_YEAR = 31536000;
    address private constant GUARDIAN = 0xAb845D09933f52af5642FC87Dd8FBbf553fd7B33;
    address private constant PSM_ADDRESS = 0x17A8541B82BF67e10B0874284b4Ae66858cb1fd5;

    address private constant PERMANENT_I = 0xAb845D09933f52af5642FC87Dd8FBbf553fd7B33; // PSM Treasury
    address private constant PERMANENT_II = 0x24b7d3034C711497c81ed5f70BEE2280907Ea1Fa; // HLP Portal
    address private constant PERMANENT_III = 0x212Bbd56F6D4F999B2845adebd8cec147851E383; // PortalsV2 VirtualLP

    uint256 public constant MAX_STAKE_DURATION = 31536000;
    uint256 public constant MAX_APR = 7000; // Accrual rate of GP at maximum stake duration (10000 = 100%)
    uint256 public constant MIN_APR = 2000; // Accrual rate of GP at stake duration = 0 (10000 = 100%)
    uint256 private constant APR_SCALING = 10000;

    // time
    uint256 timestamp;
    uint256 tenDaysLater;

    // prank addresses
    address payable Alice = payable(0x46340b20830761efd32832A74d7169B29FEB9758);
    address payable Bob = payable(0xDD56CFdDB0002f4d7f8CC0563FD489971899cb79);
    address payable Karen = payable(0x3A30aaf1189E830b02416fb8C513373C659ed748);

    // Token Instances
    IERC20 psm = IERC20(PSM_ADDRESS);

    // Possum Core contract
    PossumCore public coreContract;

    // PSM Treasury
    address psmSender = 0xAb845D09933f52af5642FC87Dd8FBbf553fd7B33;

    // starting token amounts
    uint256 psmAmount = 1e25; // 10M PSM

    //////////////////////////////////////
    /////// SETUP
    //////////////////////////////////////
    function setUp() public {
        // Create main net fork
        vm.createSelectFork({urlOrAlias: "alchemy_arbitrum_api", blockNumber: 200000000});

        // Create instance of Possum Core
        coreContract = new PossumCore();

        // creation time
        timestamp = block.timestamp;
        tenDaysLater = timestamp + 864000;

        // Deal tokens to addresses
        vm.deal(Alice, 1 ether);
        vm.prank(psmSender);
        psm.transfer(Alice, psmAmount);

        vm.deal(Bob, 1 ether);
        vm.prank(psmSender);
        psm.transfer(Bob, psmAmount);

        vm.deal(Karen, 1 ether);
        vm.prank(psmSender);
        psm.transfer(Karen, psmAmount);

        // Load the Core with tokens
        vm.prank(psmSender);
        psm.transfer(address(coreContract), psmAmount);
    }

    //////////////////////////////////////
    /////// HELPER FUNCTIONS
    //////////////////////////////////////
    function helper_listKaren() public {
        vm.prank(GUARDIAN);
        coreContract.updateWhitelist(Karen, true);
    }

    function helper_stake_Bob() public {
        vm.startPrank(Bob);
        psm.approve(address(coreContract), 1e55);

        coreContract.stake(1e24, SECONDS_PER_YEAR); // stake 1M
        vm.stopPrank();
    }

    function helper_stake_Alice() public {
        vm.startPrank(Alice);
        psm.approve(address(coreContract), 1e55);

        coreContract.stake(1e18, 0); // stake 1 PSM
        vm.stopPrank();
    }

    //////////////////////////////////////
    /////// TESTS - Guardian Functions
    //////////////////////////////////////
    function testRevert_updateWhitelist_prohibited() public {
        vm.expectRevert(NotGuardian.selector);
        coreContract.updateWhitelist(Karen, true);

        assertFalse(coreContract.whitelist(Karen));
    }

    function testRevert_updateWhitelist_falseAddress() public {
        vm.startPrank(GUARDIAN);

        vm.expectRevert(InvalidAddress.selector);
        coreContract.updateWhitelist(address(0), true);

        coreContract.updateWhitelist(PERMANENT_I, false);
        coreContract.updateWhitelist(PERMANENT_II, false);
        vm.expectRevert(PermanentDestination.selector);
        coreContract.updateWhitelist(PERMANENT_III, false);
        vm.stopPrank();

        assertFalse(coreContract.whitelist(PERMANENT_I));
        assertFalse(coreContract.whitelist(PERMANENT_II));
        assertTrue(coreContract.whitelist(PERMANENT_III));
        assertFalse(coreContract.whitelist(address(0)));
    }

    function testSuccess_updateWhitelist() public {
        vm.prank(GUARDIAN);
        coreContract.updateWhitelist(Karen, true);

        assertTrue(coreContract.whitelist(Karen));
    }

    //////////////////////////////////////
    /////// TESTS - Staking & Unstaking
    //////////////////////////////////////
    function testRevert_stake() public {
        vm.startPrank(Alice);

        psm.approve(address(coreContract), 1e55);

        vm.expectRevert(InvalidAmount.selector);
        coreContract.stake(0, 0);

        uint256 duration = coreContract.MAX_COMMITMENT() + 1;
        vm.expectRevert(InvalidDuration.selector);
        coreContract.stake(111, duration);
        vm.stopPrank();

        helper_stake_Bob();

        uint256 timeForward = 60 * 60 * 24 * 365 * 100 + block.timestamp;
        vm.warp(timeForward);

        uint256 fragments = coreContract.getFragments(Bob);

        vm.prank(Bob);
        coreContract.distributeCoreFragments(PERMANENT_I, fragments);

        vm.prank(Alice);
        vm.expectRevert(InsufficientRewards.selector);
        coreContract.stake(1e18, MAX_STAKE_DURATION);
    }

    function testSuccess_stake() public {
        uint256 amount = 1e18;
        uint256 duration = 60 * 60 * 24 * 14; // 14 days

        vm.startPrank(Alice);
        psm.approve(address(coreContract), 1e55);
        coreContract.stake(amount, duration);
        vm.stopPrank();

        uint256 contractBalance = psm.balanceOf(address(coreContract));
        uint256 availablePSM = coreContract.getAvailableTokens();

        (uint256 stakeAmount, uint256 commitmentEnd,,, uint256 lastDistributionTime, uint256 CoreFragmentsAPR) =
            coreContract.stakes(Alice);
        uint256 checkAPR = coreContract.MIN_APR()
            + ((coreContract.MAX_APR() - coreContract.MIN_APR()) * duration) / coreContract.MAX_COMMITMENT();

        assertEq(contractBalance, psmAmount + amount);
        assertEq(availablePSM, psmAmount);
        assertEq(stakeAmount, amount);
        assertEq(commitmentEnd, block.timestamp + duration);
        assertEq(lastDistributionTime, block.timestamp);
        assertEq(CoreFragmentsAPR, checkAPR);
    }

    function testSuccess_stake_sequence() public {
        helper_stake_Bob();

        uint256 amount = 1e24;
        uint256 duration = coreContract.MAX_COMMITMENT();

        // skip half the staking time
        uint256 timePassed = duration / 2;
        uint256 later = block.timestamp + timePassed;
        vm.warp(later);

        uint256 fragmentsSaved = coreContract.getFragments(Bob);

        // stake a second time but don´t prolong staking end time
        vm.prank(Bob);
        coreContract.stake(amount / 2, timePassed);

        (
            uint256 stakeBalance,
            uint256 commitmentEnd,
            uint256 reservedRewards,
            uint256 storedCoreFragments,
            uint256 lastDistributionTime,
            uint256 coreFragmentsAPR
        ) = coreContract.stakes(Bob);

        uint256 stakeSum = amount + amount / 2;

        uint256 checkAPR = 6200;
        uint256 contractBalanceCheck = psmAmount + stakeSum;
        uint256 availablePSM = coreContract.getAvailableTokens();

        assertEq(psm.balanceOf(address(coreContract)), contractBalanceCheck);
        assertEq(availablePSM, psmAmount);

        assertEq(stakeBalance, stakeSum);
        assertEq(reservedRewards, 0);
        assertEq(storedCoreFragments, fragmentsSaved);
        assertEq(commitmentEnd, block.timestamp + timePassed);
        assertEq(lastDistributionTime, block.timestamp);
        assertEq(coreFragmentsAPR, checkAPR);
    }

    function testRevert_unstakeAndClaim() public {
        vm.prank(Bob);
        vm.expectRevert(NoStake.selector);
        coreContract.unstakeAndClaim(2);

        helper_stake_Bob();

        vm.prank(Bob);
        vm.expectRevert(InvalidAmount.selector);
        coreContract.unstakeAndClaim(0);

        uint256 amountStaked = 1e24;
        uint256 amountUnstake = 2; // unstake 2 WEI
        uint256 duration = coreContract.MAX_COMMITMENT();

        // pass half the staking time
        uint256 timePassed = duration / 2;
        uint256 later = block.timestamp + timePassed;
        vm.warp(later);

        uint256 fragments = coreContract.getFragments(Bob);

        vm.startPrank(Bob);
        coreContract.distributeCoreFragments(PERMANENT_I, fragments); // Bob gets rewards

        vm.expectRevert(InvalidAmount.selector);
        coreContract.unstakeAndClaim(amountUnstake); // fail because (2 * rewards) = 720k. 720k / 1M < 1

        uint256 affectedRewards = (fragments * amountUnstake) / amountStaked; // 0
        assertEq(affectedRewards, 0);
    }

    function testSuccess_unstakeAndClaim() public {
        helper_stake_Bob();

        uint256 amountStaked = 1e24;
        uint256 amountUnstake = 1e23;
        uint256 duration = coreContract.MAX_COMMITMENT();

        // pass half the staking time
        uint256 timePassed = duration / 2;
        uint256 later = block.timestamp + timePassed;
        vm.warp(later);

        uint256 fragmentsSaved = coreContract.getFragments(Bob);

        vm.prank(Bob);
        coreContract.unstakeAndClaim(amountUnstake);

        (uint256 stakeBalance,,, uint256 storedCoreFragments, uint256 lastDistributionTime,) = coreContract.stakes(Bob);
        uint256 coreFragmentsCheck = fragmentsSaved - (fragmentsSaved * amountUnstake) / amountStaked;

        uint256 contractBalanceCheck = psmAmount + amountStaked - amountUnstake;
        uint256 availablePSM = coreContract.getAvailableTokens();

        assertEq(psm.balanceOf(address(coreContract)), contractBalanceCheck);
        assertEq(availablePSM, psmAmount); // initial amount
        assertEq(stakeBalance, amountStaked - amountUnstake); // 9e23
        assertEq(storedCoreFragments, coreFragmentsCheck); //
        assertEq(lastDistributionTime, block.timestamp);
    }

    // distribute to get rewards, then withdraw before end of commitment period
    function testSuccess_unstakeAndClaim_forfeit_partialRewards() public {
        helper_stake_Bob();

        uint256 amountStaked = 1e24;
        uint256 amountUnstake = 1e23;
        uint256 duration = coreContract.MAX_COMMITMENT();

        // pass half the staking time
        uint256 timePassed = duration / 2;
        uint256 later = block.timestamp + timePassed;
        vm.warp(later);

        uint256 fragments = coreContract.getFragments(Bob); // Bob has 360k fragments

        vm.startPrank(Bob);
        coreContract.distributeCoreFragments(PERMANENT_I, fragments); // Bob gets 360k PSM rewards

        (,, uint256 reservedRewardsBefore,,,) = coreContract.stakes(Bob);
        uint256 forfeitedRewards = (amountUnstake * reservedRewardsBefore) / amountStaked;

        coreContract.unstakeAndClaim(amountUnstake);
        vm.stopPrank();

        (
            uint256 stakeBalance,
            ,
            uint256 reservedRewardsAfter,
            uint256 storedCoreFragments,
            uint256 lastDistributionTime,
        ) = coreContract.stakes(Bob);

        uint256 contractBalanceCheck = psmAmount + amountStaked - (amountUnstake + fragments);
        uint256 availablePSM = coreContract.getAvailableTokens();
        uint256 stakeCheck = amountStaked - amountUnstake;

        assertEq(psm.balanceOf(address(coreContract)), contractBalanceCheck);
        assertEq(availablePSM, psmAmount + forfeitedRewards - (2 * fragments)); // initial amount + forfeited - distributed - reserved rewards

        assertEq(psm.balanceOf(Bob), psmAmount - stakeBalance);

        assertEq(stakeBalance, stakeCheck); // 9e23
        assertEq(reservedRewardsAfter, reservedRewardsBefore - forfeitedRewards); // 360k - 36k = 324k
        assertEq(storedCoreFragments, 0); // spent to get rewards
        assertEq(lastDistributionTime, block.timestamp);
    }

    // distribute to get rewards, then withdraw after end of commitment period
    function testSuccess_unstakeAndClaim_claim_partialRewards() public {
        helper_stake_Bob();

        uint256 amountStaked = 1e24;
        uint256 amountUnstake = 1e23;
        uint256 duration = coreContract.MAX_COMMITMENT();

        // pass the staking time
        uint256 timePassed = duration;
        uint256 later = block.timestamp + timePassed;
        vm.warp(later);

        uint256 fragments = coreContract.getFragments(Bob); // Bob has 720k fragments

        vm.startPrank(Bob);
        coreContract.distributeCoreFragments(PERMANENT_I, fragments); // Bob gets 720k PSM rewards

        (,, uint256 reservedRewardsBefore,,,) = coreContract.stakes(Bob);
        uint256 withdrawnRewards = (amountUnstake * reservedRewardsBefore) / amountStaked;

        coreContract.unstakeAndClaim(amountUnstake);
        vm.stopPrank();

        (
            uint256 stakeBalance,
            ,
            uint256 reservedRewardsAfter,
            uint256 storedCoreFragments,
            uint256 lastDistributionTime,
        ) = coreContract.stakes(Bob);

        uint256 contractBalanceCheck = psmAmount + amountStaked - (amountUnstake + fragments + withdrawnRewards);
        uint256 availablePSM = coreContract.getAvailableTokens();
        uint256 stakeCheck = amountStaked - amountUnstake;

        assertEq(psm.balanceOf(address(coreContract)), contractBalanceCheck);
        assertEq(availablePSM, psmAmount - (2 * fragments)); // initial amount - distributed - reserved rewards

        assertEq(psm.balanceOf(Bob), psmAmount - stakeBalance + withdrawnRewards); // 9.172M
        assertEq(psm.balanceOf(Bob), 9.172e24);

        assertEq(stakeBalance, stakeCheck); // 9e23
        assertEq(reservedRewardsAfter, reservedRewardsBefore - withdrawnRewards); // 360k - 36k = 324k
        assertEq(storedCoreFragments, 0); // spent to get rewards
        assertEq(lastDistributionTime, block.timestamp);
    }

    //////////////////////////////////////
    /////// TESTS - Distribution
    //////////////////////////////////////
    function testRevert_distributeCoreFragments() public {
        helper_stake_Bob();

        uint256 duration = coreContract.MAX_COMMITMENT();
        uint256 later = block.timestamp + duration / 2;

        // pass half the staking time
        vm.warp(later);
        vm.startPrank(Bob);

        // distribute to wrong address
        vm.expectRevert(NotWhitelisted.selector);
        coreContract.distributeCoreFragments(Alice, 1000);

        // distribute 0
        vm.expectRevert(InvalidAmount.selector);
        coreContract.distributeCoreFragments(PERMANENT_I, 0);

        // distribute more Fragments than user owns
        vm.expectRevert(InvalidAmount.selector);
        coreContract.distributeCoreFragments(PERMANENT_I, 1e55);
    }

    function testSuccess_distributeCoreFragments() public {
        helper_stake_Bob();

        uint256 duration = coreContract.MAX_COMMITMENT();
        uint256 later = block.timestamp + duration / 2;

        // pass half the staking time
        vm.warp(later);
        uint256 fragmentsBefore = coreContract.getFragments(Bob);

        // distribute 1k CF to a valid address
        uint256 amountDistributed = 1e21;
        vm.prank(Bob);
        coreContract.distributeCoreFragments(PERMANENT_I, amountDistributed);

        uint256 fragmentsAfter = coreContract.getFragments(Bob);

        (,, uint256 reservedRewards, uint256 storedCoreFragments, uint256 lastDistributionTime,) =
            coreContract.stakes(Bob);

        assertEq(fragmentsAfter, fragmentsBefore - amountDistributed);
        assertEq(reservedRewards, amountDistributed);
        assertEq(storedCoreFragments, fragmentsAfter);
        assertEq(lastDistributionTime, block.timestamp);
    }

    function testSuccess_distributeCoreFragments_compound() public {
        helper_stake_Bob();

        uint256 amount = 1e24;
        uint256 duration = coreContract.MAX_COMMITMENT();
        uint256 later = block.timestamp + duration / 2;
        uint256 end = block.timestamp + duration;

        // pass half the staking time
        vm.warp(later);

        // distribute 200k CF to a valid address
        uint256 amountDistributed = 2e23;
        vm.startPrank(Bob);

        coreContract.distributeCoreFragments(PERMANENT_I, amountDistributed);
        uint256 fragmentsAfter = coreContract.getFragments(Bob);

        (,, uint256 reservedRewards,,, uint256 apr) = coreContract.stakes(Bob);

        // pass to the end time of the stake
        vm.warp(end);

        // get compounded fragments
        uint256 fragmentsEnd = coreContract.getFragments(Bob);
        uint256 earningBalance = amount + reservedRewards;

        uint256 fragmentsValidation =
            fragmentsAfter + (earningBalance * duration * apr) / (2 * APR_SCALING * SECONDS_PER_YEAR);

        uint256 plainYield = (apr * amount) / APR_SCALING;
        uint256 compoundingEffect = (fragmentsEnd + reservedRewards) - plainYield;

        assertEq(fragmentsEnd, fragmentsValidation);
        assertTrue(compoundingEffect > 0);
    }

    // Distribute more CF than 1/2 available PSM in contract (full rewards, less distribution)
    function testSuccess_distributeCoreFragments_edgeCase1() public {
        helper_stake_Bob();

        uint256 duration = coreContract.MAX_COMMITMENT();
        uint256 later = block.timestamp + duration * 10;

        // pass 10 years
        vm.warp(later);

        uint256 amountDistributed = coreContract.getFragments(Bob);
        uint256 balanceBefore = psm.balanceOf(PERMANENT_I);

        // distribute 7.2M CF to valid address -> requires 14.4M PSM which is more than 10M available
        // Bob should get 7.2M PSM rewards and address receives 2.8M PSM
        vm.startPrank(Bob);

        coreContract.distributeCoreFragments(PERMANENT_I, amountDistributed);
        uint256 fragmentsAfter = coreContract.getFragments(Bob);

        (,, uint256 reservedRewards, uint256 storedCoreFragments, uint256 lastDistributionTime,) =
            coreContract.stakes(Bob);

        uint256 balanceAfter = psm.balanceOf(PERMANENT_I);
        uint256 availableAfter = coreContract.getAvailableTokens();
        uint256 reservedRewardsTotal = coreContract.reservedRewardsTotal();

        assertEq(availableAfter, 0);
        assertEq(balanceAfter, balanceBefore + 2.8e24);

        assertEq(fragmentsAfter, 0);
        assertEq(reservedRewards, amountDistributed); // rewards claimable, not yet claimed
        assertEq(storedCoreFragments, fragmentsAfter); // 0
        assertEq(storedCoreFragments, 0); // 0
        assertEq(lastDistributionTime, block.timestamp);
        assertEq(reservedRewardsTotal, reservedRewards); // 7.2M
    }

    // distribute more CF than available PSM in contract (only rewards paid)
    function testSuccess_distributeCoreFragments_edgeCase2() public {
        helper_stake_Bob();

        uint256 duration = coreContract.MAX_COMMITMENT();
        uint256 later = block.timestamp + duration * 100;
        uint256 available = coreContract.getAvailableTokens();

        // pass 100 years
        vm.warp(later);

        uint256 amountDistributed = coreContract.getFragments(Bob);
        uint256 balanceBefore = psm.balanceOf(PERMANENT_I);

        // distribute 72M CF to valid address -> requires more than the 10M available
        // Bob should get 10M PSM rewards and address receives 0 PSM
        vm.startPrank(Bob);

        coreContract.distributeCoreFragments(PERMANENT_I, amountDistributed);
        uint256 fragmentsAfter = coreContract.getFragments(Bob);

        (,, uint256 reservedRewards, uint256 storedCoreFragments, uint256 lastDistributionTime,) =
            coreContract.stakes(Bob);

        uint256 balanceAfter = psm.balanceOf(PERMANENT_I);
        uint256 availableAfter = coreContract.getAvailableTokens();

        assertEq(availableAfter, 0);
        assertEq(balanceAfter, balanceBefore);

        assertEq(fragmentsAfter, 62e24); // 62M
        assertEq(reservedRewards, available); // rewards claimable, not yet claimed. 10M PSM (full balance)
        assertEq(storedCoreFragments, fragmentsAfter); // remainder, 62M CF
        assertEq(storedCoreFragments, 62e24); // 62M
        assertEq(lastDistributionTime, block.timestamp);
    }

    //////////////////////////////////////
    /////// TESTS - View Functions
    //////////////////////////////////////
    function testSuccess_getAvailableTokens() public view {
        uint256 test = coreContract.getAvailableTokens();
        uint256 check = IERC20(PSM_ADDRESS).balanceOf(address(coreContract)) - coreContract.stakedTokensTotal()
            - coreContract.reservedRewardsTotal();

        assertTrue(test == check);
    }

    function testRevert_getFragments() public {
        vm.expectRevert(InvalidAddress.selector);
        coreContract.getFragments(address(0));
    }

    function testSuccess_getFragments_zero() public view {
        uint256 fragments = coreContract.getFragments(Bob);

        assertTrue(fragments == 0);
    }

    function testSuccess_getFragments_staked() public {
        helper_stake_Bob();

        // verify that fragments start at zero after staking
        uint256 fragments = coreContract.getFragments(Bob);
        assertTrue(fragments == 0);

        // pass 10 days and evaluate fragments
        vm.warp(tenDaysLater);
        fragments = coreContract.getFragments(Bob);
        uint256 externValidated = 19726.027397260273972602e18;

        assertTrue(fragments == externValidated);

        // pass 1 second and evaluate fragments
        vm.warp(tenDaysLater + 1);
        fragments = coreContract.getFragments(Bob);
        externValidated = 19726.050228310502283105e18;

        assertTrue(fragments == externValidated);
    }

    function testSuccess_getFragments_staked_edgeCase() public {
        helper_stake_Alice();

        // verify that fragments start at zero after staking
        uint256 fragments = coreContract.getFragments(Alice);
        assertTrue(fragments == 0);

        // pass 1 second and evaluate fragments
        vm.warp(block.timestamp + 1);
        fragments = coreContract.getFragments(Alice);
        uint256 externValidated = 3805175038;

        assertTrue(fragments == externValidated);
    }
}
