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

    //////////////////////////////////////
    /////// TESTS - Distributing
    //////////////////////////////////////

    //////////////////////////////////////
    /////// TESTS - View Functions
    //////////////////////////////////////
}
