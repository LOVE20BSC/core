// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {LaunchDeployFixture, AirdropVm} from "./utils/LaunchDeployFixture.sol";
import {
    IAirdropDistributor,
    IAirdropDistributorErrors,
    IAirdropDistributorEvents,
    AirdropInfo
} from "../src/interfaces/distributor/IAirdropDistributor.sol";
import {ILaunchDistributor} from "../src/interfaces/distributor/ILaunchDistributor.sol";
import {LOVE20Token} from "../src/LOVE20Token.sol";

/// 事件断言：逐字段核对 topic 与 data，不使用 expectEmit 的高层包装
contract AirdropDistributorEventsTest is LaunchDeployFixture {
    bytes32 internal constant GENESIS_ROOT = keccak256("genesis root");
    bytes32 internal constant CONFIGURED_TOPIC = keccak256("AirdropConfigured(address,bytes32,uint256)");
    bytes32 internal constant CLAIMED_TOPIC = keccak256("AirdropClaimed(address,address,uint256,uint256,uint256)");
    bytes32 internal constant SNAPSHOT_URI_UPDATED_TOPIC =
        keccak256("AirdropSnapshotUriUpdated(address,string,string)");

    function setUp() public {
        _deploySystem(GENESIS_ROOT, 0);
    }

    // ============ 25. 首币配置也发 AirdropConfigured（构造函数内） ============

    function testGenesisConfigurationEmitsAirdropConfiguredFromConstructor() external {
        vm.recordLogs();
        address firstTokenAddress = _redeployForEventCapture();

        AirdropVm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(distributor) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != CONFIGURED_TOPIC) continue;

            require(logs[i].topics.length == 2, "only tokenAddress indexed");
            require(
                logs[i].topics[1] == bytes32(uint256(uint160(firstTokenAddress))), "constructor event token"
            );
            (bytes32 merkleRoot, uint256 claimableFromRound) = abi.decode(logs[i].data, (bytes32, uint256));
            require(merkleRoot == GENESIS_ROOT, "constructor event root");
            require(claimableFromRound == 1, "constructor event round");
            found = true;
        }
        require(found, "genesis AirdropConfigured missing");
    }

    function testGenesisConfigurationEventIsTheOnlyLogOfTheDistributorConstructor() external {
        vm.recordLogs();
        _redeployForEventCapture();

        AirdropVm.Log[] memory logs = vm.getRecordedLogs();
        uint256 configuredCount;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(distributor)) continue;
            require(logs[i].topics[0] == CONFIGURED_TOPIC, "unexpected distributor log in constructor");
            configuredCount += 1;
        }
        require(configuredCount == 1, "exactly one configuration event");
    }

    // ============ 23. 普通发射的 AirdropConfigured 三字段 ============

    function testSubTokenConfigurationEmitsAirdropConfiguredWithExactFields() external {
        _rollToPhase(3);
        bytes32 merkleRoot = keccak256("sub root");
        bytes[] memory data = _distributorData(merkleRoot, 2);

        vm.recordLogs();
        address subToken = _launchSubToken(ALICE, aliceMemberId, "SUB", data);
        AirdropVm.Log[] memory logs = vm.getRecordedLogs();

        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(distributor) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != CONFIGURED_TOPIC) continue;

            require(logs[i].topics.length == 2, "one indexed argument");
            require(logs[i].topics[1] == bytes32(uint256(uint160(subToken))), "event tokenAddress");
            (bytes32 emittedRoot, uint256 emittedRound) = abi.decode(logs[i].data, (bytes32, uint256));
            require(emittedRoot == merkleRoot, "event merkleRoot");
            require(emittedRound == 5, "event claimableFromRound");
            require(emittedRound == distributor.airdropInfo(subToken).claimableFromRound, "event matches state");
            found = true;
        }
        require(found, "missing AirdropConfigured");
    }

    function testSubTokenConfigurationEmitsExactlyOneConfiguredEvent() external {
        vm.recordLogs();
        _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(keccak256("sub"), 0));

        AirdropVm.Log[] memory logs = vm.getRecordedLogs();
        uint256 configuredCount;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(distributor)) continue;
            if (logs[i].topics[0] != CONFIGURED_TOPIC) continue;
            configuredCount += 1;
        }
        require(configuredCount == 1, "one configuration event per launch");
    }

    // ============ 24. AirdropClaimed 五字段 ============

    function testClaimEmitsAirdropClaimedWithEveryField() external {
        _rollToPhase(1);

        bytes32[] memory leaves = _threeLeaves();
        bytes32[] memory proof = _merkleProof(leaves, 1);
        address subToken =
            _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(_merkleRoot(leaves), 0));

        uint256 pool = LOVE20Token(subToken).balanceOf(address(distributor));
        uint256 expectedAmount = pool * BOB_SHARE / TOTAL_SHARE;

        vm.recordLogs();
        _claimAs(BOB, subToken, BOB_SHARE, proof);
        AirdropVm.Log[] memory logs = vm.getRecordedLogs();

        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(distributor) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != CLAIMED_TOPIC) continue;

            require(logs[i].topics.length == 3, "two indexed arguments");
            require(logs[i].topics[1] == bytes32(uint256(uint160(subToken))), "event tokenAddress");
            require(logs[i].topics[2] == bytes32(uint256(uint160(BOB))), "event claimer");

            (uint256 share, uint256 amount, uint256 remainingShare) =
                abi.decode(logs[i].data, (uint256, uint256, uint256));
            require(share == BOB_SHARE, "event share");
            require(amount == expectedAmount, "event amount");
            require(remainingShare == TOTAL_SHARE - BOB_SHARE, "event remainingShare is post-claim");
            require(
                remainingShare == distributor.airdropInfo(subToken).totalRemainingShare, "event remaining matches state"
            );
            require(amount == distributor.claimedAmount(subToken, BOB), "amount state");
            found = true;
        }
        require(found, "missing AirdropClaimed");
    }

    function testClaimEventRemainingShareIsPostClaimValue() external {
        _rollToPhase(1);

        bytes32[] memory leaves = _threeLeaves();
        address subToken =
            _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(_merkleRoot(leaves), 0));

        // 第一次领取：remainingShare 应为 1e18 - 1e17
        vm.recordLogs();
        _claimAs(ALICE, subToken, ALICE_SHARE, _merkleProof(leaves, 0));
        (, , uint256 firstRemaining) = _readClaimEvent(vm.getRecordedLogs(), subToken, ALICE);
        require(firstRemaining == TOTAL_SHARE - ALICE_SHARE, "first event post-claim remaining");

        // 第二次领取：remainingShare 继续递减，且等于上一笔事件的 remainingShare 减去本笔 share
        vm.recordLogs();
        _claimAs(BOB, subToken, BOB_SHARE, _merkleProof(leaves, 1));
        (, , uint256 secondRemaining) = _readClaimEvent(vm.getRecordedLogs(), subToken, BOB);
        require(secondRemaining == firstRemaining - BOB_SHARE, "second event post-claim remaining");
        require(secondRemaining == TOTAL_SHARE - ALICE_SHARE - BOB_SHARE, "second remaining value");
    }

    function testClaimEventIsEmittedAfterTheTransfer() external {
        _rollToPhase(1);

        bytes32[] memory leaves = _threeLeaves();
        address subToken =
            _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(_merkleRoot(leaves), 0));

        vm.recordLogs();
        _claimAs(ALICE, subToken, ALICE_SHARE, _merkleProof(leaves, 0));
        AirdropVm.Log[] memory logs = vm.getRecordedLogs();

        // CEI：transfer 先于 AirdropClaimed
        uint256 transferIndex = type(uint256).max;
        uint256 claimedIndex = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
            bool isTransfer = logs[i].emitter == address(subToken) && logs[i].topics[0] == transferTopic;
            if (isTransfer && transferIndex == type(uint256).max) transferIndex = i;
            if (logs[i].emitter == address(distributor) && logs[i].topics[0] == CLAIMED_TOPIC) {
                claimedIndex = i;
            }
        }
        require(transferIndex != type(uint256).max, "transfer emitted");
        require(claimedIndex != type(uint256).max, "claim event emitted");
        require(transferIndex < claimedIndex, "state transfer precedes the claim event");
    }

    function testEveryClaimEmitsExactlyOneEvent() external {
        _rollToPhase(1);

        bytes32[] memory leaves = _threeLeaves();
        address subToken =
            _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(_merkleRoot(leaves), 0));

        vm.recordLogs();
        _claimAs(ALICE, subToken, ALICE_SHARE, _merkleProof(leaves, 0));
        AirdropVm.Log[] memory logs = vm.getRecordedLogs();

        uint256 claimedCount;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(distributor) && logs[i].topics[0] == CLAIMED_TOPIC) claimedCount += 1;
        }
        require(claimedCount == 1, "one claim event");

        // 重复领取不应产生任何事件（整笔回滚）
        logs = new AirdropVm.Log[](0);
        vm.recordLogs();
        (bool ok, ) = _callAs(
            ALICE, abi.encodeCall(IAirdropDistributor.claim, (subToken, ALICE_SHARE, _merkleProof(leaves, 0)))
        );
        require(!ok, "second claim reverts");
        logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            require(logs[i].topics.length == 0 || logs[i].topics[0] != CLAIMED_TOPIC, "no event on revert");
        }
    }

    // ============ 27. AirdropSnapshotUriUpdated 三字段（1 indexed + 2 string） ============

    function _launchSub(address launcher, uint256 memberId, string memory symbol) private returns (address) {
        return _launchSubToken(launcher, memberId, symbol, _distributorData(keccak256("snapshot root"), 0));
    }

    function testSnapshotUriUpdatedEventHasOneIndexedAndTwoStringFields() external {
        address subToken = _launchSub(ALICE, aliceMemberId, "SUB");
        string memory uri = "https://love20bsc.github.io/docs/snapshot.json";

        vm.recordLogs();
        vm.prank(ALICE);
        distributor.updateSnapshotUri(subToken, uri);
        AirdropVm.Log[] memory logs = vm.getRecordedLogs();

        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(distributor) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != SNAPSHOT_URI_UPDATED_TOPIC) continue;

            // 1 indexed + 2 string：topic[0] 签名、topic[1] tokenAddress，data 为两个动态 string 的 abi.encode
            require(logs[i].topics.length == 2, "only tokenAddress indexed");
            require(logs[i].topics[1] == bytes32(uint256(uint160(subToken))), "event tokenAddress");
            (string memory snapshotUri, string memory prevSnapshotUri) =
                abi.decode(logs[i].data, (string, string));
            require(keccak256(bytes(snapshotUri)) == keccak256(bytes(uri)), "event snapshotUri");
            require(keccak256(bytes(prevSnapshotUri)) == keccak256(bytes("")), "first update prev is empty");
            found = true;
        }
        require(found, "missing AirdropSnapshotUriUpdated");
    }

    function testSnapshotUriUpdatedEventCarriesPreviousValueOnSecondUpdate() external {
        address subToken = _launchSub(ALICE, aliceMemberId, "SUB");
        string memory first = "ipfs://snapshot-v1";
        string memory second = "https://love20bsc.github.io/docs/snapshot-v2.json";

        vm.prank(ALICE);
        distributor.updateSnapshotUri(subToken, first);

        vm.recordLogs();
        vm.prank(ALICE);
        distributor.updateSnapshotUri(subToken, second);
        AirdropVm.Log[] memory logs = vm.getRecordedLogs();

        (string memory snapshotUri, string memory prevSnapshotUri) =
            _readSnapshotUriUpdatedEvent(logs, subToken);
        require(keccak256(bytes(snapshotUri)) == keccak256(bytes(second)), "event snapshotUri is second");
        require(keccak256(bytes(prevSnapshotUri)) == keccak256(bytes(first)), "prevSnapshotUri is first");
    }

    function testEverySnapshotUriUpdateEmitsExactlyOneEvent() external {
        address subToken = _launchSub(ALICE, aliceMemberId, "SUB");

        vm.recordLogs();
        vm.prank(ALICE);
        distributor.updateSnapshotUri(subToken, "https://one");
        AirdropVm.Log[] memory logs = vm.getRecordedLogs();
        require(_countSnapshotUriEvents(logs) == 1, "one event for first update");

        vm.recordLogs();
        vm.prank(ALICE);
        distributor.updateSnapshotUri(subToken, "https://two");
        logs = vm.getRecordedLogs();
        require(_countSnapshotUriEvents(logs) == 1, "one event for second update");

        // 失败的更新（空 uri / 非发射者）不产生任何事件
        vm.recordLogs();
        (bool ok, ) = _callAs(
            ALICE, abi.encodeCall(IAirdropDistributor.updateSnapshotUri, (subToken, ""))
        );
        require(!ok, "empty uri reverts");
        logs = vm.getRecordedLogs();
        require(_countSnapshotUriEvents(logs) == 0, "no event on empty uri revert");

        vm.recordLogs();
        (ok, ) = _callAs(
            BOB, abi.encodeCall(IAirdropDistributor.updateSnapshotUri, (subToken, "https://bob"))
        );
        require(!ok, "non-launcher reverts");
        logs = vm.getRecordedLogs();
        require(_countSnapshotUriEvents(logs) == 0, "no event on auth revert");
    }

    function testSnapshotUriUpdatedEventMatchesStateAfterEachUpdate() external {
        address subToken = _launchSub(ALICE, aliceMemberId, "SUB");
        string memory first = "https://one";
        string memory second = "https://two";

        vm.recordLogs();
        vm.prank(ALICE);
        distributor.updateSnapshotUri(subToken, first);
        AirdropVm.Log[] memory logs = vm.getRecordedLogs();
        (string memory emittedUri, ) = _readSnapshotUriUpdatedEvent(logs, subToken);
        require(
            keccak256(bytes(emittedUri)) == keccak256(bytes(distributor.airdropInfo(subToken).snapshotUri)),
            "event matches state after first update"
        );

        vm.recordLogs();
        vm.prank(ALICE);
        distributor.updateSnapshotUri(subToken, second);
        logs = vm.getRecordedLogs();
        (emittedUri, ) = _readSnapshotUriUpdatedEvent(logs, subToken);
        require(
            keccak256(bytes(emittedUri)) == keccak256(bytes(distributor.airdropInfo(subToken).snapshotUri)),
            "event matches state after second update"
        );
        require(keccak256(bytes(emittedUri)) == keccak256(bytes(second)), "state is the latest uri");
    }

    // ============ Helpers ============

    /// 重新部署一套系统，使构造函数的日志可被 vm.recordLogs 捕获。
    /// 返回新系统的首币地址；distributor/launch/phase 等成员变量同时被替换。
    function _redeployForEventCapture() private returns (address) {
        _deploySystem(GENESIS_ROOT, 0);
        return launch.FIRST_TOKEN_ADDRESS();
    }

    function _readClaimEvent(
        AirdropVm.Log[] memory logs,
        address tokenAddress,
        address claimer
    ) private pure returns (uint256 share, uint256 amount, uint256 remainingShare) {
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != CLAIMED_TOPIC) continue;
            if (logs[i].topics[1] != bytes32(uint256(uint160(tokenAddress)))) continue;
            if (logs[i].topics[2] != bytes32(uint256(uint160(claimer)))) continue;
            (share, amount, remainingShare) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            found = true;
        }
        require(found, "missing AirdropClaimed for the token/claimer pair");
    }

    function _readSnapshotUriUpdatedEvent(AirdropVm.Log[] memory logs, address tokenAddress)
        private
        pure
        returns (string memory snapshotUri, string memory prevSnapshotUri)
    {
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != SNAPSHOT_URI_UPDATED_TOPIC) continue;
            if (logs[i].topics[1] != bytes32(uint256(uint160(tokenAddress)))) continue;
            (snapshotUri, prevSnapshotUri) = abi.decode(logs[i].data, (string, string));
            found = true;
        }
        require(found, "missing AirdropSnapshotUriUpdated");
    }

    function _countSnapshotUriEvents(AirdropVm.Log[] memory logs) private pure returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == SNAPSHOT_URI_UPDATED_TOPIC) count += 1;
        }
    }
}
