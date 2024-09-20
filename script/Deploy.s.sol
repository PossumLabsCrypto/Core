// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.19;

import {Script, console} from "lib/forge-std/src/Script.sol";
import {PossumCore} from "src/PossumCore.sol";

contract Deploy is Script {
    function setUp() public {}

    function run() public returns (address coreAddress) {
        vm.startBroadcast();

        // Configure optimizer settings
        vm.store(address(this), bytes32("optimizer"), bytes32("true"));
        vm.store(address(this), bytes32("optimizerRuns"), bytes32(uint256(1000)));

        PossumCore possumCore = new PossumCore();
        coreAddress = address(possumCore);

        vm.stopBroadcast();
    }
}

// forg script script/Deploy.s.sol:Deploy --rpc-url $ARB_MAINNET_URL --private-key $PRIVATE_KEY --broadcast --verify --verifier etherscan --etherscan-api-key $ARBISCAN_API_KEY --optimize --optimizer-runs 1000
