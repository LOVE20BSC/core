// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {LOVE20Token} from "../../src/LOVE20Token.sol";
import {MemberNFT} from "../../src/MemberNFT.sol";
import {Phase} from "../../src/Phase.sol";
import {Launch} from "../../src/Launch.sol";

contract DeployCore is Script {
    struct DeploymentAddresses {
        address token;
        address memberNFT;
        address phase;
        address launch;
    }

    function run() external returns (DeploymentAddresses memory addrs) {
        vm.startBroadcast();

        addrs = _deployContracts();

        vm.stopBroadcast();

        _verifyDeployment(addrs);
        _logDeploymentSummary(addrs);

        if (vm.envOr("WRITE_ADDRESS_FILE", false)) {
            _writeAddressFile(addrs);
        }
    }

    function _deployContracts() private returns (DeploymentAddresses memory addrs) {
        // 部署 MemberNFT
        addrs.memberNFT = address(_deployMemberNFT());
        console2.log("MemberNFT deployed at:", addrs.memberNFT);

        // 部署 Phase
        addrs.phase = address(_deployPhase());
        console2.log("Phase deployed at:", addrs.phase);

        // 部署 Launch
        addrs.launch = address(new Launch());
        console2.log("Launch deployed at:", addrs.launch);

        // 部署首个 LOVE20Token
        addrs.token = address(_deployToken());
        console2.log("LOVE20Token deployed at:", addrs.token);
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

    function _deployToken() private returns (LOVE20Token) {
        return new LOVE20Token(
            vm.envString("TOKEN_NAME"),
            vm.envString("TOKEN_SYMBOL"),
            vm.envUint("INITIAL_SUPPLY"),
            vm.envUint("MAX_SUPPLY"),
            vm.envAddress("DISTRIBUTOR"),
            vm.envAddress("MINTER"),
            vm.envAddress("PARENT_TOKEN")
        );
    }

    function _verifyDeployment(DeploymentAddresses memory addrs) private view {
        // 验证 LOVE20Token 配置
        LOVE20Token token = LOVE20Token(addrs.token);
        require(
            keccak256(bytes(token.name())) == keccak256(bytes(vm.envString("TOKEN_NAME"))),
            "Token name mismatch"
        );
        require(
            keccak256(bytes(token.symbol())) == keccak256(bytes(vm.envString("TOKEN_SYMBOL"))),
            "Token symbol mismatch"
        );
        require(token.minter() == vm.envAddress("MINTER"), "Token minter mismatch");
        require(token.parentTokenAddress() == vm.envAddress("PARENT_TOKEN"), "Token parentToken mismatch");

        // 验证 MemberNFT 配置
        MemberNFT memberNFT = MemberNFT(addrs.memberNFT);
        require(memberNFT.BASE_DIVISOR() == vm.envUint("MEMBER_BASE_DIVISOR"), "MemberNFT baseDivisor mismatch");
        require(
            memberNFT.BYTES_THRESHOLD() == vm.envUint("MEMBER_BYTES_THRESHOLD"),
            "MemberNFT bytesThreshold mismatch"
        );

        // 验证 Phase 配置
        Phase phase = Phase(addrs.phase);
        require(phase.TARGET_SECONDS() == vm.envUint("PHASE_TARGET_SECONDS"), "Phase TARGET_SECONDS mismatch");
    }

    function _logDeploymentSummary(DeploymentAddresses memory addrs) private pure {
        console2.log("\n=== Deployment Summary ===");
        console2.log("LOVE20TOKEN_ADDRESS=", addrs.token);
        console2.log("MEMBERNFT_ADDRESS=", addrs.memberNFT);
        console2.log("PHASE_ADDRESS=", addrs.phase);
        console2.log("LAUNCH_ADDRESS=", addrs.launch);
    }

    function _writeAddressFile(DeploymentAddresses memory addrs) private {
        string memory network = vm.envOr("network", string("anvil31337_dev"));
        string memory path = string.concat("script/network/", network, "/addresses.core.params");
        vm.writeFile(
            path,
            string.concat(
                "LOVE20TOKEN_ADDRESS=", vm.toString(addrs.token), "\n",
                "MEMBERNFT_ADDRESS=", vm.toString(addrs.memberNFT), "\n",
                "PHASE_ADDRESS=", vm.toString(addrs.phase), "\n",
                "LAUNCH_ADDRESS=", vm.toString(addrs.launch), "\n",
                "STAKE_ADDRESS=\n",
                "SUBMIT_ADDRESS=\n",
                "VOTE_ADDRESS=\n",
                "MINT_ADDRESS=\n"
            )
        );
    }
}
