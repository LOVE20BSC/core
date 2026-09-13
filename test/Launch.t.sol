// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Launch} from "../src/Launch.sol";
import {LaunchInitParams} from "../src/interfaces/ILaunch.sol";
import {LOVE20Token} from "../src/LOVE20Token.sol";

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
}

contract MemberInitMock {
    address public firstToken;

    function init(address firstTokenAddress) external {
        firstToken = firstTokenAddress;
    }
}

contract LaunchTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant MINT = address(0x1234);
    address private constant ROOT = address(0x5678);
    address private constant DISTRIBUTOR = address(0x9ABC);

    function testInitCreatesFirstTokenWithoutFactory() public {
        Launch launch = new Launch();
        MemberInitMock member = new MemberInitMock();

        vm.recordLogs();
        launch.init(
            LaunchInitParams({
                mintAddress: MINT,
                memberNFTAddress: address(member),
                rootParentTokenAddress: ROOT,
                distributor: DISTRIBUTOR,
                launchRatio: 1e16,
                maxLaunchCount: 100,
                tokenSymbolLength: 3,
                launchAmount: 100 ether,
                maxSupply: 200 ether,
                name: "LOVE20",
                symbol: "LOVE"
            })
        );

        require(launch.initialized(), "initialized");
        require(launch.mintAddress() == MINT, "mint");
        require(launch.LAUNCH_AMOUNT() == 100 ether, "launch amount");
        require(launch.MAX_SUPPLY() == 200 ether, "max supply");
        require(member.firstToken() != address(0), "member init");
        require(launch.isLOVE20Token(member.firstToken()), "registered");

        LOVE20Token token = LOVE20Token(member.firstToken());
        require(token.balanceOf(DISTRIBUTOR) == 100 ether, "distribution");
        require(token.minter() == MINT, "minter");
        require(token.parentTokenAddress() == ROOT, "parent");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSelector = keccak256("TokenLaunched(address,address,uint256,address,string,string)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(launch) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != eventSelector) continue;
            require(logs[i].topics[1] == bytes32(uint256(uint160(member.firstToken()))), "event token");
            require(logs[i].topics[2] == bytes32(uint256(uint160(ROOT))), "event parent");
            require(logs[i].topics[3] == bytes32(0), "event launcher");
            (address distributor, string memory name, string memory symbol) =
                abi.decode(logs[i].data, (address, string, string));
            require(distributor == DISTRIBUTOR, "event distributor");
            require(keccak256(bytes(name)) == keccak256(bytes("LOVE20")), "event name");
            require(keccak256(bytes(symbol)) == keccak256(bytes("LOVE")), "event symbol");
            found = true;
        }
        require(found, "missing launch event");
    }
}
