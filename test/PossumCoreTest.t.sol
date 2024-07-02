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
    address private constant GUARDIAN = 0xa0BFD02a7a47CBCA7230E03fbf04A196C3E771E3;
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

        vm.expectRevert(PermanentDestination.selector);
        coreContract.updateWhitelist(PERMANENT_I, false);
        vm.stopPrank();

        assertTrue(coreContract.whitelist(PERMANENT_I));
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
    function testRevert_stake() public {}

    function testSuccess_stake() public {}

    function testSuccess_stake_sequence() public {}

    function testSuccess_stake_compounding() public {}

    function testRevert_unstakeAndClaim() public {}

    function testSuccess_unstakeAndClaim_forfeit() public {}

    function testSuccess_unstakeAndClaim_claim() public {}

    function testSuccess_unstakeAndClaim_sequence() public {}

    //////////////////////////////////////
    /////// TESTS - Distributing
    //////////////////////////////////////
    function testRevert_distributeCoreFragments() public {}

    function testSuccess_distributeCoreFragments() public {}

    //////////////////////////////////////
    /////// TESTS - View Functions
    //////////////////////////////////////
    function testSuccess_getAvailableTokens() public view {
        uint256 test = coreContract.getAvailableTokens();
        uint256 check = IERC20(PSM_ADDRESS).balanceOf(address(this)) - coreContract.stakedTokensTotal()
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
