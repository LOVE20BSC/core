// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {MemberNFT} from "../../src/MemberNFT.sol";
import {Phase} from "../../src/Phase.sol";
import {Launch} from "../../src/Launch.sol";
import {Mint} from "../../src/Mint.sol";
import {Vote} from "../../src/Vote.sol";
import {Submit} from "../../src/Submit.sol";
import {Stake} from "../../src/Stake.sol";
import {LaunchInitParams} from "../../src/interfaces/ILaunch.sol";

contract DeployCore is Script {
    struct DeploymentAddresses {
        address token;
        address memberNFT;
        address phase;
        address launch;
        address mint;
        address vote;
        address submit;
        address stake;
    }

    function run() external returns (DeploymentAddresses memory addrs) {
        require(block.chainid == vm.envUint("CHAIN_ID"), "Chain ID mismatch");
        require(vm.envUint("MIN_PROPOSAL_VOTES") <= 1000, "Proposal threshold exceeds 1000");
        require(vm.envUint("LAUNCH_RATIO") <= 1e18, "Launch ratio exceeds 1e18");

        // DEX 依赖必须是已部署合约。PARENT_TOKEN 只被记录、ROUTER_ADDRESS 只在提现时使用，
        // 两者配错时模拟阶段不会回滚，会白广播 8 个合约（要到 99_check.sh 才拦下）。
        address rootParent = vm.envAddress("PARENT_TOKEN");
        address factory = vm.envAddress("FACTORY_ADDRESS");
        address router = vm.envAddress("ROUTER_ADDRESS");
        require(rootParent.code.length != 0, "WBNB must be a deployed contract");
        require(factory.code.length != 0, "Factory must be a deployed contract");
        require(router.code.length != 0, "Router must be a deployed contract");

        vm.startBroadcast();

        addrs = _deployContracts();

        vm.stopBroadcast();

        _logDeploymentSummary(addrs);
    }

    function _deployContracts() private returns (DeploymentAddresses memory addrs) {
        // 部署 MemberNFT
        addrs.memberNFT = address(_deployMemberNFT());
        console2.log("MemberNFT deployed at:", addrs.memberNFT);

        // 部署 Phase
        addrs.phase = address(_deployPhase());
        console2.log("Phase deployed at:", addrs.phase);

        // 部署 Mint（未初始化）
        addrs.mint = address(new Mint());
        console2.log("Mint deployed at:", addrs.mint);

        // 部署 Launch
        addrs.launch = address(new Launch());
        console2.log("Launch deployed at:", addrs.launch);

        // 调用 Launch.init() 创建首个代币
        LaunchInitParams memory launchParams = LaunchInitParams({
            mintAddress: addrs.mint,
            memberNFTAddress: addrs.memberNFT,
            rootParentTokenAddress: vm.envAddress("PARENT_TOKEN"),
            pairFactoryAddress: vm.envAddress("FACTORY_ADDRESS"),
            launchRatio: vm.envUint("LAUNCH_RATIO"),
            maxLaunchCount: vm.envUint("MAX_LAUNCH_COUNT"),
            tokenSymbolLength: vm.envUint("TOKEN_SYMBOL_LENGTH"),
            launchAmount: vm.envUint("INITIAL_SUPPLY"),
            maxSupply: vm.envUint("MAX_SUPPLY"),
            distributor: vm.envAddress("DISTRIBUTOR"),
            name: vm.envString("TOKEN_NAME"),
            symbol: vm.envString("TOKEN_SYMBOL")
        });
        Launch(addrs.launch).init(launchParams);

        // 从 Launch 获取首个代币地址
        (address[] memory tokens,) = Launch(addrs.launch).tokens(0, 1, false);
        addrs.token = tokens[0];
        console2.log("First LOVE20Token created at:", addrs.token);

        // 部署 Stake（未初始化）
        addrs.stake = address(new Stake());
        console2.log("Stake deployed at:", addrs.stake);

        // 部署 Submit（未初始化）
        addrs.submit = address(new Submit());
        console2.log("Submit deployed at:", addrs.submit);

        // 部署 Vote（未初始化）
        addrs.vote = address(new Vote());
        console2.log("Vote deployed at:", addrs.vote);

        // 初始化 Stake
        Stake(addrs.stake).init(
            addrs.phase,
            addrs.memberNFT,
            addrs.vote,
            addrs.launch,
            vm.envAddress("ROUTER_ADDRESS"),
            vm.envAddress("FACTORY_ADDRESS"),
            vm.envUint("PROMISED_WAITING_PHASES_MIN"),
            vm.envUint("PROMISED_WAITING_PHASES_MAX"),
            vm.envUint("MAX_WITHDRAWABLE_TO_FEE_RATIO")
        );
        console2.log("Stake initialized");

        // 初始化 Submit
        Submit(addrs.submit).init(
            addrs.phase,
            addrs.stake,
            addrs.memberNFT,
            vm.envUint("SUBMIT_MIN_PER_THOUSAND")
        );
        console2.log("Submit initialized");

        // 初始化 Vote
        Vote(addrs.vote).init(
            addrs.phase,
            addrs.stake,
            addrs.submit,
            addrs.memberNFT
        );
        console2.log("Vote initialized");

        // 初始化 Mint（需要所有合约地址）
        Mint(addrs.mint).init(
            addrs.vote,
            addrs.submit,
            addrs.launch,
            addrs.memberNFT,
            vm.envUint("MIN_PROPOSAL_VOTES"),
            vm.envUint("GOV_REWARD_RATIO"),
            vm.envUint("PROPOSAL_REWARD_RATIO"),
            vm.envUint("MAX_BOOST_MULTIPLIER")
        );
        console2.log("Mint initialized");
    }

    function _deployMemberNFT() private returns (MemberNFT) {
        return new MemberNFT(
            vm.envUint("MEMBER_BASE_DIVISOR"),
            vm.envUint("MEMBER_BYTES_THRESHOLD"),
            vm.envUint("MEMBER_MULTIPLIER"),
            vm.envUint("MEMBER_MAX_NAME_LENGTH")
        );
    }

    function _deployPhase() private returns (Phase) {
        return new Phase(
            vm.envUint("PHASE_ORIGIN_BLOCKS"),
            vm.envUint("PHASE_ORIGIN_PHASE_BLOCKS"),
            vm.envUint("PHASE_TARGET_SECONDS"),
            vm.envUint("PHASE_ADJUST_THRESHOLD"),
            vm.envUint("PHASE_SYNC_OBSERVATION_LIMIT")
        );
    }

    function _logDeploymentSummary(DeploymentAddresses memory addrs) private pure {
        console2.log("\n=== Deployment Summary ===");
        console2.log("LOVE20TOKEN_ADDRESS=", addrs.token);
        console2.log("MEMBERNFT_ADDRESS=", addrs.memberNFT);
        console2.log("PHASE_ADDRESS=", addrs.phase);
        console2.log("LAUNCH_ADDRESS=", addrs.launch);
        console2.log("MINT_ADDRESS=", addrs.mint);
        console2.log("STAKE_ADDRESS=", addrs.stake);
        console2.log("SUBMIT_ADDRESS=", addrs.submit);
        console2.log("VOTE_ADDRESS=", addrs.vote);
    }
}
