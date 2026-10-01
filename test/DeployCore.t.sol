// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Test} from "forge-std/Test.sol";
import {DeployCore} from "../script/deploy/DeployCore.s.sol";

contract DeployCoreTest is Test {
    // 单个函数内顺序断言：vm.setEnv 在并行执行的用例之间共享，拆成多个用例会互相覆盖。
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

        // DEX 依赖地址必须是已部署合约：PARENT_TOKEN 只被记录、ROUTER_ADDRESS 只在提现时使用，
        // 两者配错时模拟阶段不会回滚，会白广播 8 个合约，直到 99_check.sh 才拦下。
        vm.setEnv("LAUNCH_RATIO", "1000000000000000000");
        address rootParent = makeAddr("rootParent");
        address factory = makeAddr("factory");
        address router = makeAddr("router");
        vm.setEnv("PARENT_TOKEN", vm.toString(rootParent));
        vm.setEnv("FACTORY_ADDRESS", vm.toString(factory));
        vm.setEnv("ROUTER_ADDRESS", vm.toString(router));

        vm.expectRevert("WBNB must be a deployed contract");
        deployer.run();

        vm.etch(rootParent, hex"00");
        vm.expectRevert("Factory must be a deployed contract");
        deployer.run();

        vm.etch(factory, hex"00");
        vm.expectRevert("Router must be a deployed contract");
        deployer.run();
    }
}
