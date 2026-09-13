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
    uint256 private constant TARGET_DAYS = 1;
    uint256 private constant THRESHOLD = 2e17;
    uint256 private constant OBSERVATION_LIMIT = 10;

    function testConstructorAndStartupBoundaries() external {
        uint256 origin = block.number + 10;
        Phase phase = new Phase(origin, PHASE_BLOCKS, TARGET_DAYS, THRESHOLD, OBSERVATION_LIMIT);
        require(phase.ORIGIN_BLOCKS() == origin);
        require(phase.ORIGIN_PHASE_BLOCKS() == PHASE_BLOCKS);
        require(phase.TARGET_SECONDS() == TARGET_DAYS * 86400);
        require(phase.ADJUST_THRESHOLD() == THRESHOLD);
        require(phase.SYNC_OBSERVATION_LIMIT() == OBSERVATION_LIMIT);
        require(phase.phaseAtBlock(origin - 1) == 0);
        require(phase.currentPhase() == 0);
        (bool ok, bytes memory data) = address(phase).call(
            abi.encodeWithSelector(IPhase.currentPhaseBlocks.selector)
        );
        require(!ok && _selector(data) == IPhaseErrors.InvalidPhase.selector);
        vm.roll(origin);
        require(phase.currentPhase() == 1);
        require(phase.currentPhaseBlocks() == PHASE_BLOCKS);
        (uint256 start, uint256 length) = phase.phaseInfo(1);
        require(start == origin && length == PHASE_BLOCKS);
    }

    function testSyncBeforeOriginReverts() external {
        Phase phase = new Phase(block.number + 10, PHASE_BLOCKS, TARGET_DAYS, THRESHOLD, OBSERVATION_LIMIT);
        (bool ok, bytes memory data) = address(phase).call(abi.encodeWithSelector(IPhase.sync.selector));
        require(!ok && _selector(data) == IPhaseErrors.InvalidPhase.selector);
        require(_observationsCount(phase) == 0);
    }

    function testSyncRecordsOncePerPhaseAndAdjustsNextPhase() external {
        uint256 origin = block.number + 1;
        Phase phase = new Phase(origin, PHASE_BLOCKS, TARGET_DAYS, THRESHOLD, OBSERVATION_LIMIT);
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
        (adjusted, length) = phase.sync();
        require(adjusted && length > PHASE_BLOCKS);
        require(_observationsCount(phase) == 2);
        require(phase.phaseAtBlock(origin + PHASE_BLOCKS) == 2);
        (uint256 start, uint256 phaseLength) = phase.phaseInfo(2);
        require(start == origin + PHASE_BLOCKS && phaseLength == PHASE_BLOCKS);
        (start, phaseLength) = phase.phaseInfo(3);
        require(start == origin + 2 * PHASE_BLOCKS && phaseLength == length);
    }

    function testThresholdCanSuppressAdjustment() external {
        uint256 origin = block.number + 1;
        Phase phase = new Phase(origin, PHASE_BLOCKS, TARGET_DAYS, 100e18, OBSERVATION_LIMIT);
        uint256 timestamp = block.timestamp + 1000;
        vm.roll(origin);
        vm.warp(timestamp);
        phase.sync();
        vm.roll(origin + PHASE_BLOCKS + 1);
        vm.warp(timestamp + 1000);
        (bool adjusted, uint256 length) = phase.sync();
        require(!adjusted && length == PHASE_BLOCKS);
        require(phase.phaseAtBlock(origin + PHASE_BLOCKS) == 2);
        require(phase.currentPhaseBlocks() == PHASE_BLOCKS);
    }

    function testObservationFallbackUsesOrderedIndex() external {
        uint256 origin = block.number + 1;
        Phase phase = new Phase(origin, 10, TARGET_DAYS, THRESHOLD, 1);
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
        Phase phase = new Phase(origin, PHASE_BLOCKS, TARGET_DAYS, THRESHOLD, OBSERVATION_LIMIT);
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
        Phase phase = new Phase(origin, PHASE_BLOCKS, TARGET_DAYS, THRESHOLD, OBSERVATION_LIMIT);
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
        Phase phase = new Phase(origin, PHASE_BLOCKS, TARGET_DAYS, THRESHOLD, OBSERVATION_LIMIT);
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
        Phase phase = new Phase(origin, 10, TARGET_DAYS, type(uint256).max, OBSERVATION_LIMIT);
        vm.roll(origin);
        vm.warp(block.timestamp + 1000);
        phase.sync();
        vm.roll(origin + 35);
        vm.warp(block.timestamp + 1000);
        phase.sync();
        (uint256 start, uint256 blocks_) = phase.phaseInfo(4);
        require(start == origin + 30 && blocks_ == 10);
        (start, blocks_) = phase.phaseInfo(5);
        require(start == origin + 40 && blocks_ == 10);
    }

    function testDuplicateSyncEmitsNoEvent() external {
        uint256 origin = block.number + 1;
        Phase phase = new Phase(origin, PHASE_BLOCKS, TARGET_DAYS, THRESHOLD, OBSERVATION_LIMIT);
        vm.roll(origin);
        vm.warp(block.timestamp + 1000);
        vm.recordLogs();
        phase.sync();
        require(vm.getRecordedLogs().length == 1);
        vm.recordLogs();
        phase.sync();
        require(vm.getRecordedLogs().length == 0);
    }

    function testObservationPaginationBounds() external {
        uint256 origin = block.number + 1;
        Phase phase = new Phase(origin, PHASE_BLOCKS, TARGET_DAYS, THRESHOLD, OBSERVATION_LIMIT);

        // Empty history: empty page with the true count.
        (uint256[] memory blockNumbers, uint256[] memory blockTimestamps, uint256 totalCount) =
            phase.syncObservations(0, OBSERVATION_LIMIT, false);
        require(blockNumbers.length == 0 && blockTimestamps.length == 0 && totalCount == 0);

        vm.roll(origin);
        vm.warp(block.timestamp + 1000);
        phase.sync();

        // Out-of-range offset: empty page, no revert, true count.
        (blockNumbers, blockTimestamps, totalCount) = phase.syncObservations(1, OBSERVATION_LIMIT, false);
        require(blockNumbers.length == 0 && blockTimestamps.length == 0 && totalCount == 1);

        // Limit larger than the remaining entries is clamped to the remaining entries.
        (blockNumbers,, totalCount) = phase.syncObservations(0, OBSERVATION_LIMIT, false);
        require(blockNumbers.length == 1 && blockNumbers[0] == origin && totalCount == 1);

        // Reverse returns the newest observation first.
        (blockNumbers,, ) = phase.syncObservations(0, 1, true);
        require(blockNumbers.length == 1 && blockNumbers[0] == origin);

        (bool ok, bytes memory data) = address(phase).call(abi.encodeWithSelector(IPhase.phaseInfo.selector, 0));
        require(!ok && _selector(data) == IPhaseErrors.InvalidPhase.selector);
    }

    function _observationsCount(Phase phase) private view returns (uint256) {
        (,, uint256 totalCount) = phase.syncObservations(0, 0, false);
        return totalCount;
    }

    function _selector(bytes memory data) private pure returns (bytes4 selector) {
        if (data.length < 4) return bytes4(0);
        assembly { selector := mload(add(data, 32)) }
    }
}
