// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {LOVE20Token} from "../../src/LOVE20Token.sol";
import {MemberNFT} from "../../src/MemberNFT.sol";
import {Phase} from "../../src/Phase.sol";
import {Launch} from "../../src/Launch.sol";

contract DeployCore is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // 部署 MemberNFT
        uint256 memberBaseDivisor = vm.envUint("MEMBER_BASE_DIVISOR");
        uint256 memberBytesThreshold = vm.envUint("MEMBER_BYTES_THRESHOLD");
        uint256 memberMultiplier = vm.envUint("MEMBER_MULTIPLIER");
        uint256 memberMaxNameLength = vm.envUint("MEMBER_MAX_NAME_LENGTH");
        MemberNFT memberNFT = new MemberNFT(
            memberBaseDivisor,
            memberBytesThreshold,
            memberMultiplier,
            memberMaxNameLength
        );
        console2.log("MemberNFT deployed at:", address(memberNFT));

        // 部署 Phase
        uint256 phaseOriginBlocks = vm.envUint("PHASE_ORIGIN_BLOCKS");
        uint256 phaseOriginPhaseBlocks = vm.envUint("PHASE_ORIGIN_PHASE_BLOCKS");
        uint256 phaseTargetSeconds = vm.envUint("PHASE_TARGET_SECONDS");
        uint256 phaseAdjustThreshold = vm.envUint("PHASE_ADJUST_THRESHOLD");
        uint256 phaseSyncObservationLimit = vm.envUint("PHASE_SYNC_OBSERVATION_LIMIT");
        Phase phase = new Phase(
            phaseOriginBlocks,
            phaseOriginPhaseBlocks,
            phaseTargetSeconds,
            phaseAdjustThreshold,
            phaseSyncObservationLimit
        );
        console2.log("Phase deployed at:", address(phase));

        // 部署 Launch
        Launch launch = new Launch();
        console2.log("Launch deployed at:", address(launch));

        // 部署首个 LOVE20Token
        string memory tokenName = vm.envString("TOKEN_NAME");
        string memory tokenSymbol = vm.envString("TOKEN_SYMBOL");
        uint256 initialSupply = vm.envUint("INITIAL_SUPPLY");
        uint256 maxSupply = vm.envUint("MAX_SUPPLY");
        address distributor = vm.envAddress("DISTRIBUTOR");
        address minter = vm.envAddress("MINTER");
        address parentToken = vm.envAddress("PARENT_TOKEN");

        LOVE20Token token = new LOVE20Token(
            tokenName,
            tokenSymbol,
            initialSupply,
            maxSupply,
            distributor,
            minter,
            parentToken
        );
        console2.log("LOVE20Token deployed at:", address(token));

        vm.stopBroadcast();

        // 输出部署地址供写入 addresses.core.params
        console2.log("\n=== Deployment Summary ===");
        console2.log("LOVE20TOKEN_ADDRESS=", address(token));
        console2.log("MEMBERNFT_ADDRESS=", address(memberNFT));
        console2.log("PHASE_ADDRESS=", address(phase));
        console2.log("LAUNCH_ADDRESS=", address(launch));
    }
}
