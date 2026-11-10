// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Phase} from "../src/Phase.sol";
import {IPhase, IPhaseErrors} from "../src/interfaces/IPhase.sol";

interface Vm {
    struct Log { bytes32[] topics; bytes data; address emitter; }
    function roll(uint256 blockNumber) external;
    function warp(uint256 timestamp) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
}

contract PhaseTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant PHASE_BLOCKS = 100;
    uint256 private constant TARGET_SECONDS = 86400;
    uint256 private constant THRESHOLD = 2e17;
    uint256 private constant OBSERVATION_LIMIT = 10;

    function testConstructorAndStartupBoundaries() external {
        uint256 origin = block.number + 10;
        Phase phase = new Phase(origin, PHASE_BLOCKS, TARGET_SECONDS, THRESHOLD, OBSERVATION_LIMIT);
        require(phase.ORIGIN_BLOCKS() == origin);
        require(phase.ORIGIN_PHASE_BLOCKS() == PHASE_BLOCKS);
        require(phase.TARGET_SECONDS() == TARGET_SECONDS);
        require(phase.ADJUST_THRESHOLD() == THRESHOLD);
        require(phase.SYNC_OBSERVATION_LIMIT() == OBSERVATION_LIMIT);
        require(phase.phaseAtBlock(origin - 1) == 0);
        require(phase.currentPhase() == 0);
        (bool ok, bytes memory data) = address(phase).call(
            abi.encodeWithSelector(IPhase.currentPhaseBlocks.selector)
        );
        require(!ok && _selector(data) == IPhaseErrors.PhaseNotStarted.selector);
        vm.roll(origin);
        require(phase.currentPhase() == 1);
        require(phase.currentPhaseBlocks() == PHASE_BLOCKS);
        (uint256 start, uint256 length) = phase.phaseInfo(1);
        require(start == origin && length == PHASE_BLOCKS);
    }

    function testSyncBeforeOriginReverts() external {
        Phase phase = new Phase(block.number + 10, PHASE_BLOCKS, TARGET_SECONDS, THRESHOLD, OBSERVATION_LIMIT);
        (bool ok, bytes memory data) = address(phase).call(abi.encodeWithSelector(IPhase.sync.selector));
        require(!ok && _selector(data) == IPhaseErrors.PhaseNotStarted.selector);
        require(_observationsCount(phase) == 0);
    }

    function testSyncRecordsOncePerPhaseAndAdjustsNextPhase() external {
        uint256 origin = block.number + 1;
        Phase phase = new Phase(origin, PHASE_BLOCKS, TARGET_SECONDS, THRESHOLD, OBSERVATION_LIMIT);
        uint256 timestamp = block.timestamp + 1000;
        vm.roll(origin);
        vm.warp(timestamp);
        (bool adjusted, uint256 length) = phase.sync();
        require(!adjusted && length == PHASE_BLOCKS);
        require(_observationsCount(phase) == 1);

        (adjusted, length) = phase.sync();
        require(!adjusted && length == PHASE_BLOCKS);
        require(_observationsCount(phase) == 1);

        vm.roll(origin + PHASE_BLOCKS + 1);
        vm.warp(timestamp + 1000);
        vm.recordLogs();
        (adjusted, length) = phase.sync();
        require(adjusted && length > PHASE_BLOCKS);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 1, "one snapshot per synchronization");
        require(logs[0].topics.length == 2, "only phase is indexed");
        require(logs[0].topics[0] == keccak256("PhaseSynchronized(uint256,uint256,uint256)"), "event signature");
        require(logs[0].topics[1] == bytes32(uint256(2)), "event phase");
        (uint256 currentBlocks, uint256 nextBlocks) = abi.decode(logs[0].data, (uint256, uint256));
        require(currentBlocks == PHASE_BLOCKS, "current segment");
        require(nextBlocks == 8726, "next segment");
        require(nextBlocks == length, "event matches return value");
        require(_observationsCount(phase) == 2);
        require(phase.phaseAtBlock(origin + PHASE_BLOCKS) == 2);
        (uint256 start, uint256 phaseLength) = phase.phaseInfo(2);
        require(start == origin + PHASE_BLOCKS && phaseLength == PHASE_BLOCKS);
        (start, phaseLength) = phase.phaseInfo(3);
        require(start == origin + 2 * PHASE_BLOCKS && phaseLength == length);
    }

    function testThresholdCanSuppressAdjustment() external {
        uint256 origin = block.number + 1;
        Phase phase = new Phase(origin, PHASE_BLOCKS, TARGET_SECONDS, 1e18, OBSERVATION_LIMIT);
        uint256 timestamp = block.timestamp + 1000;
        vm.roll(origin);
        vm.warp(timestamp);
        phase.sync();
        vm.roll(origin + PHASE_BLOCKS + 1);
        vm.warp(timestamp + 50000);
        (bool adjusted, uint256 length) = phase.sync();
        require(!adjusted && length == PHASE_BLOCKS);
        require(phase.phaseAtBlock(origin + PHASE_BLOCKS) == 2);
        require(phase.currentPhaseBlocks() == PHASE_BLOCKS);
    }

    function testObservationFallbackUsesOrderedIndex() external {
        uint256 origin = block.number + 1;
        Phase phase = new Phase(origin, 10, TARGET_SECONDS, THRESHOLD, 1);
        vm.roll(origin);
        vm.warp(block.timestamp + 1000);
        phase.sync();
        vm.roll(origin + 10);
        vm.warp(block.timestamp + 1000);
        phase.sync();
        vm.roll(origin + 20);
        vm.warp(block.timestamp + 1000);
        (bool adjusted, uint256 newBlocks) = phase.sync();
        require(adjusted && newBlocks > 10);
        require(_observationsCount(phase) == 3);
    }

    function testStrictObservationBoundaryDoesNotAdjust() external {
        uint256 origin = block.number + 1;
        Phase phase = new Phase(origin, PHASE_BLOCKS, TARGET_SECONDS, THRESHOLD, OBSERVATION_LIMIT);
        vm.roll(origin);
        vm.warp(block.timestamp + 1000);
        phase.sync();
        vm.roll(origin + PHASE_BLOCKS);
        vm.warp(block.timestamp + 1000);
        (bool adjusted, uint256 newBlocks) = phase.sync();
        require(!adjusted && newBlocks == PHASE_BLOCKS);
    }

    function testZeroElapsedSecondsDoesNotAdjust() external {
        uint256 origin = block.number + 1;
        Phase phase = new Phase(origin, PHASE_BLOCKS, TARGET_SECONDS, THRESHOLD, OBSERVATION_LIMIT);
        uint256 timestamp = block.timestamp + 1000;
        vm.roll(origin);
        vm.warp(timestamp);
        phase.sync();
        vm.roll(origin + PHASE_BLOCKS + 1);
        vm.warp(timestamp);
        (bool adjusted, uint256 newBlocks) = phase.sync();
        require(!adjusted && newBlocks == PHASE_BLOCKS);
    }

    function testEqualThresholdDoesNotAdjust() external {
        uint256 origin = block.number + 1;
        Phase phase = new Phase(origin, PHASE_BLOCKS, TARGET_SECONDS, THRESHOLD, OBSERVATION_LIMIT);
        uint256 timestamp = block.timestamp + 1000;
        vm.roll(origin);
        vm.warp(timestamp);
        phase.sync();
        vm.roll(origin + PHASE_BLOCKS + 1);
        vm.warp(timestamp + 72720);
        (bool adjusted, uint256 newBlocks) = phase.sync();
        require(!adjusted && newBlocks == PHASE_BLOCKS);
    }

    function testCrossesEmptyPhasesWithoutRewritingHistory() external {
        uint256 origin = block.number + 1;
        Phase phase = new Phase(origin, 10, TARGET_SECONDS, 1e18, OBSERVATION_LIMIT);
        vm.roll(origin);
        vm.warp(block.timestamp + 1000);
        phase.sync();
        vm.roll(origin + 35);
        vm.warp(block.timestamp + 200000);
        phase.sync();
        (uint256 start, uint256 blocks_) = phase.phaseInfo(4);
        require(start == origin + 30 && blocks_ == 10);
        (start, blocks_) = phase.phaseInfo(5);
        require(start == origin + 40 && blocks_ == 10);
    }

    function testDuplicateSyncEmitsNoEvent() external {
        uint256 origin = block.number + 1;
        Phase phase = new Phase(origin, PHASE_BLOCKS, TARGET_SECONDS, THRESHOLD, OBSERVATION_LIMIT);
        vm.roll(origin);
        vm.warp(block.timestamp + 1000);
        vm.recordLogs();
        phase.sync();
        require(vm.getRecordedLogs().length == 1);
        vm.recordLogs();
        phase.sync();
        require(vm.getRecordedLogs().length == 0);
    }

    function testPhaseSynchronizedCarriesSegmentSnapshot() external {
        uint256 origin = block.number + 1;
        Phase phase = new Phase(origin, PHASE_BLOCKS, TARGET_SECONDS, THRESHOLD, OBSERVATION_LIMIT);
        vm.roll(origin);
        vm.warp(block.timestamp + 1000);

        vm.recordLogs();
        phase.sync();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 1, "one synchronization event");
        require(logs[0].topics.length == 2, "only phase is indexed");
        require(logs[0].topics[0] == keccak256("PhaseSynchronized(uint256,uint256,uint256)"), "event signature");
        require(logs[0].topics[1] == bytes32(uint256(1)), "event phase");
        (uint256 currentBlocks, uint256 nextBlocks) = abi.decode(logs[0].data, (uint256, uint256));
        require(currentBlocks == PHASE_BLOCKS, "current segment");
        require(nextBlocks == PHASE_BLOCKS, "next segment");
    }

    function testAdjacentSyncsChainSegmentLengths() external {
        uint256 origin = block.number + 1;
        Phase phase = new Phase(origin, 10, TARGET_SECONDS, THRESHOLD, OBSERVATION_LIMIT);
        uint256 timestamp = block.timestamp + 1000;
        vm.roll(origin);
        vm.warp(timestamp);
        phase.sync();

        vm.roll(origin + 11);
        vm.warp(timestamp + 1000);
        (bool adjusted, uint256 adjustedBlocks) = phase.sync();
        require(adjusted && adjustedBlocks > 10);

        (uint256 start, uint256 phaseBlocks) = phase.phaseInfo(3);
        require(start == origin + 20 && phaseBlocks == adjustedBlocks);

        vm.roll(start + 2 * phaseBlocks);
        vm.warp(timestamp + 2000);
        require(phase.currentPhase() == 5, "empty phases are skipped");
        vm.recordLogs();
        phase.sync();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 1, "one synchronization event");
        (uint256 currentBlocks,) = abi.decode(logs[0].data, (uint256, uint256));
        require(currentBlocks == adjustedBlocks, "current segment follows the previous next segment");
    }

    function testClampedAdjustmentWritesAnEqualSegment() external {
        uint256 origin = block.number + 1;
        Phase phase = new Phase(origin, 1, TARGET_SECONDS, THRESHOLD, OBSERVATION_LIMIT);
        uint256 timestamp = block.timestamp + 1000;
        vm.roll(origin);
        vm.warp(timestamp);
        phase.sync();

        vm.roll(origin + 11);
        vm.warp(timestamp + 1000000);
        require(phase.currentPhase() == 12);
        vm.recordLogs();
        (bool adjusted, uint256 newBlocks) = phase.sync();
        require(adjusted && newBlocks == 1);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length == 1, "one synchronization event");
        require(logs[0].topics[1] == bytes32(uint256(12)), "event phase");
        (uint256 currentBlocks, uint256 nextBlocks) = abi.decode(logs[0].data, (uint256, uint256));
        require(currentBlocks == 1, "current segment");
        require(nextBlocks == 1, "next segment");

        (uint256 start, uint256 phaseBlocks) = phase.phaseInfo(13);
        require(start == origin + 12 && phaseBlocks == 1);
    }

    function testObservationPaginationBounds() external {
        uint256 origin = block.number + 1;
        Phase phase = new Phase(origin, PHASE_BLOCKS, TARGET_SECONDS, THRESHOLD, OBSERVATION_LIMIT);

        // Empty history: empty page with the true count.
        (uint256[] memory blockNumbers, uint256[] memory blockTimestamps, uint256 totalCount) =
            phase.observations(0, OBSERVATION_LIMIT, false);
        require(blockNumbers.length == 0 && blockTimestamps.length == 0 && totalCount == 0);

        vm.roll(origin);
        vm.warp(block.timestamp + 1000);
        phase.sync();

        // Out-of-range offset: empty page, no revert, true count.
        (blockNumbers, blockTimestamps, totalCount) = phase.observations(1, OBSERVATION_LIMIT, false);
        require(blockNumbers.length == 0 && blockTimestamps.length == 0 && totalCount == 1);

        // Limit larger than the remaining entries is clamped to the remaining entries.
        (blockNumbers,, totalCount) = phase.observations(0, OBSERVATION_LIMIT, false);
        require(blockNumbers.length == 1 && blockNumbers[0] == origin && totalCount == 1);

        // Reverse returns the newest observation first.
        (blockNumbers,, ) = phase.observations(0, 1, true);
        require(blockNumbers.length == 1 && blockNumbers[0] == origin);

        (bool ok, bytes memory data) = address(phase).call(abi.encodeWithSelector(IPhase.phaseInfo.selector, 0));
        require(!ok && _selector(data) == IPhaseErrors.PhaseNotStarted.selector);
    }

    function testObservationPaginationWindows() external {
        uint256 origin = block.number + 1;
        Phase phase = new Phase(origin, PHASE_BLOCKS, TARGET_SECONDS, THRESHOLD, OBSERVATION_LIMIT);

        uint256 count = 5;
        uint256[] memory expected = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            vm.roll(origin + i * PHASE_BLOCKS);
            vm.warp(block.timestamp + TARGET_SECONDS);
            expected[i] = block.number;
            phase.sync();
        }

        (uint256[] memory blockNumbers,, uint256 totalCount) = phase.observations(0, count, false);
        require(blockNumbers.length == count && totalCount == count, "forward page size");
        for (uint256 i = 0; i < count; i++) {
            require(blockNumbers[i] == expected[i], "forward order");
        }

        (blockNumbers,, ) = phase.observations(0, count, true);
        for (uint256 i = 0; i < count; i++) {
            require(blockNumbers[i] == expected[count - 1 - i], "reverse order");
        }

        (blockNumbers,, ) = phase.observations(1, count, true);
        require(blockNumbers.length == count - 1, "reverse offset page size");
        for (uint256 i = 0; i < count - 1; i++) {
            require(blockNumbers[i] == expected[count - 2 - i], "reverse offset order");
        }

        (blockNumbers,, totalCount) = phase.observations(count, count, false);
        require(blockNumbers.length == 0 && totalCount == count, "offset at total");

        (blockNumbers,, totalCount) = phase.observations(count, count, true);
        require(blockNumbers.length == 0 && totalCount == count, "reverse offset at total");

        (blockNumbers,, totalCount) = phase.observations(0, 0, false);
        require(blockNumbers.length == 0 && totalCount == count, "zero limit");

        (blockNumbers,, totalCount) = phase.observations(0, 0, true);
        require(blockNumbers.length == 0 && totalCount == count, "reverse zero limit");
    }

    function _observationsCount(Phase phase) private view returns (uint256) {
        (,, uint256 totalCount) = phase.observations(0, 0, false);
        return totalCount;
    }

    /// 用裸 CREATE 的返回值判定构造是否成功：成功返回非零地址，回滚返回 address(0)。
    /// 不使用 vm.expectRevert：`new` 构造一旦回滚，测试函数会在此终止并被判 PASS，
    /// 其后语句全部成为死代码。
    function _deploys(
        uint256 originBlocks,
        uint256 originPhaseBlocks,
        uint256 targetSeconds,
        uint256 adjustThreshold,
        uint256 observationLimit
    ) private returns (bool) {
        bytes memory bytecode = abi.encodePacked(
            type(Phase).creationCode,
            abi.encode(originBlocks, originPhaseBlocks, targetSeconds, adjustThreshold, observationLimit)
        );
        address deployed;
        assembly {
            deployed := create(0, add(bytecode, 32), mload(bytecode))
        }
        return deployed != address(0);
    }

    function _deployRevert(
        uint256 originBlocks,
        uint256 originPhaseBlocks,
        uint256 targetSeconds,
        uint256 adjustThreshold,
        uint256 observationLimit
    ) private returns (bytes memory data) {
        bytes memory bytecode = abi.encodePacked(
            type(Phase).creationCode,
            abi.encode(originBlocks, originPhaseBlocks, targetSeconds, adjustThreshold, observationLimit)
        );
        address deployed;
        uint256 size;
        assembly {
            deployed := create(0, add(bytecode, 32), mload(bytecode))
            size := returndatasize()
        }
        require(deployed == address(0), "deploy should revert");
        data = new bytes(size);
        assembly {
            returndatacopy(add(data, 32), 0, size)
        }
    }

    function _revertEquals(bytes memory data, bytes memory expected) private pure returns (bool) {
        return keccak256(data) == keccak256(expected);
    }

    function _selector(bytes memory data) private pure returns (bytes4 selector) {
        if (data.length < 4) return bytes4(0);
        assembly { selector := mload(add(data, 32)) }
    }
}
