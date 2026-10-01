// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Test} from "forge-std/Test.sol";
import {DeployCore} from "../script/deploy/DeployCore.s.sol";

contract DeployCoreTest is Test {
    function testRejectsUnsafeConfigurationBeforeBroadcast() public {
        DeployCore deployer = new DeployCore();
        vm.setEnv("CHAIN_ID", vm.toString(block.chainid + 1));
        vm.expectRevert("Chain ID mismatch");
        deployer.run();

        vm.setEnv("CHAIN_ID", vm.toString(block.chainid));
        vm.setEnv("MIN_PROPOSAL_VOTES", "1001");
        vm.expectRevert("Proposal threshold exceeds 1000");
        deployer.run();

        vm.setEnv("MIN_PROPOSAL_VOTES", "1000");
        vm.setEnv("LAUNCH_RATIO", "1000000000000000001");
        vm.expectRevert("Launch ratio exceeds 1e18");
        deployer.run();
    }
}
