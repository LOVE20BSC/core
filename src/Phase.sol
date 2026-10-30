// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IPhase} from "./interfaces/IPhase.sol";
import {OrderedHistoryIndex} from "@libs/OrderedHistoryIndex.sol";
import {Pagination} from "@libs/Pagination.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract Phase is IPhase {
    using OrderedHistoryIndex for OrderedHistoryIndex.Index;

    struct Segment {
        uint256 phase;
        uint256 startBlock;
        uint256 phaseBlocks;
    }

    uint256 public immutable ORIGIN_BLOCKS;
    uint256 public immutable ORIGIN_PHASE_BLOCKS;
    uint256 public immutable TARGET_SECONDS;
    uint256 public immutable ADJUST_THRESHOLD;
    uint256 public immutable SYNC_OBSERVATION_LIMIT;
    uint256 private _lastSyncPhase;
    uint256[] private _observationBlocks;
    uint256[] private _observationTimestamps;
    OrderedHistoryIndex.Index private _observationBlockIndex;
    mapping(uint256 => uint256) private _observationIdByBlock;
    OrderedHistoryIndex.Index private _segmentPhaseIndex;
    OrderedHistoryIndex.Index private _segmentStartBlockIndex;
    mapping(uint256 => Segment) private _segmentByPhase;
    mapping(uint256 => Segment) private _segmentByStartBlock;

    constructor(
        uint256 originBlocks,
        uint256 originPhaseBlocks,
        uint256 targetSeconds,
        uint256 adjustThreshold,
        uint256 syncObservationLimit
    ) {
        ORIGIN_BLOCKS = originBlocks;
        ORIGIN_PHASE_BLOCKS = originPhaseBlocks;
        TARGET_SECONDS = targetSeconds;
        ADJUST_THRESHOLD = adjustThreshold;
        SYNC_OBSERVATION_LIMIT = syncObservationLimit;
        _recordSegment(Segment(1, originBlocks, originPhaseBlocks));
    }

    function currentPhaseBlocks() public view returns (uint256) {
        uint256 phase = currentPhase();
        if (phase == 0) revert PhaseNotStarted();
        return _phaseBlocks(phase);
    }

    function currentPhase() public view returns (uint256) { return phaseAtBlock(block.number); }

    function phaseInfo(uint256 phaseNumber) public view returns (uint256 startBlock, uint256 phaseBlocks) {
        if (phaseNumber == 0) revert PhaseNotStarted();
        (bool found, uint256 key) = _segmentPhaseIndex.nearest(phaseNumber);
        assert(found);
        Segment memory segment = _segmentByPhase[key];
        startBlock = segment.startBlock + (phaseNumber - segment.phase) * segment.phaseBlocks;
        phaseBlocks = segment.phaseBlocks;
    }

    function phaseAtBlock(uint256 blockNumber) public view returns (uint256) {
        if (blockNumber < ORIGIN_BLOCKS) return 0;
        (bool found, uint256 key) = _segmentStartBlockIndex.nearest(blockNumber);
        if (!found) return 0;
        Segment memory segment = _segmentByStartBlock[key];
        return segment.phase + (blockNumber - segment.startBlock) / segment.phaseBlocks;
    }

    function observations(uint256 offset, uint256 limit, bool reverse)
        external view returns (uint256[] memory blockNumbers, uint256[] memory blockTimestamps, uint256 totalCount)
    {
        totalCount = _observationBlocks.length;
        uint256[] memory indices = Pagination.paginateIndices(totalCount, offset, limit, reverse);
        blockNumbers = new uint256[](indices.length);
        blockTimestamps = new uint256[](indices.length);
        for (uint256 i = 0; i < indices.length; i++) {
            blockNumbers[i] = _observationBlocks[indices[i]];
            blockTimestamps[i] = _observationTimestamps[indices[i]];
        }
    }

    function sync() external returns (bool adjusted, uint256 newPhaseBlocks) {
        uint256 phase = currentPhase();
        if (phase == 0) revert PhaseNotStarted();
        uint256 phaseBlocks = _phaseBlocks(phase);
        if (_lastSyncPhase == phase) {
            // No adjustment occurred before this idempotent sync; return false explicitly.
            // forge-lint: disable-next-line(boolean-cst)
            return (false, phaseBlocks);
        }
        _lastSyncPhase = phase;
        uint256 selected = type(uint256).max;
        uint256 count = _observationBlocks.length;
        uint256 from = count > SYNC_OBSERVATION_LIMIT ? count - SYNC_OBSERVATION_LIMIT : 0;
        for (uint256 i = count; i > from; ) {
            --i;
            if (block.number - _observationBlocks[i] > phaseBlocks) { selected = i; break; }
        }
        if (selected == type(uint256).max && block.number > phaseBlocks) {
            uint256 cutoffBlock = block.number - phaseBlocks - 1;
            (bool found, uint256 nearestBlock) = _observationBlockIndex.nearest(cutoffBlock);
            if (found) selected = _observationIdByBlock[nearestBlock] - 1;
        }
        _observationBlocks.push(block.number);
        _observationTimestamps.push(block.timestamp);
        _observationBlockIndex.record(block.number);
        _observationIdByBlock[block.number] = _observationBlocks.length;
        if (selected != type(uint256).max) {
            uint256 elapsedBlocks = block.number - _observationBlocks[selected];
            uint256 elapsedSeconds = block.timestamp - _observationTimestamps[selected];
            // forge-lint: disable-next-line(block-timestamp)
            if (elapsedBlocks > 0 && elapsedSeconds > 0) {
                uint256 observed = Math.mulDiv(elapsedBlocks, TARGET_SECONDS, elapsedSeconds);
                uint256 difference = observed > phaseBlocks ? observed - phaseBlocks : phaseBlocks - observed;
                uint256 deviation = Math.mulDiv(difference, 1e18, phaseBlocks);
                if (deviation > ADJUST_THRESHOLD) {
                    newPhaseBlocks = observed == 0 ? 1 : observed;
                    _recordNextSegment(phase, phaseBlocks, newPhaseBlocks);
                    emit PhaseAdjusted({
                        effectivePhase: phase + 1,
                        oldPhaseBlocks: phaseBlocks,
                        newPhaseBlocks: newPhaseBlocks
                    });
                    adjusted = true;
                }
            }
        }
        if (!adjusted) newPhaseBlocks = phaseBlocks;
        emit PhaseSynchronized({
            phase: phase,
            phaseBlocks: newPhaseBlocks
        });
    }

    function _phaseBlocks(uint256 phase) private view returns (uint256) {
        (bool found, uint256 key) = _segmentPhaseIndex.nearest(phase);
        assert(found);
        return _segmentByPhase[key].phaseBlocks;
    }

    function _recordSegment(Segment memory segment) private {
        _segmentPhaseIndex.record(segment.phase);
        _segmentStartBlockIndex.record(segment.startBlock);
        _segmentByPhase[segment.phase] = segment;
        _segmentByStartBlock[segment.startBlock] = segment;
    }

    function _recordNextSegment(uint256 phase, uint256 phaseBlocks, uint256 newPhaseBlocks) private {
        (bool found, uint256 key) = _segmentPhaseIndex.latest();
        assert(found);
        Segment memory previous = _segmentByPhase[key];
        _recordSegment(Segment(
            phase + 1,
            previous.startBlock + (phase - previous.phase + 1) * phaseBlocks,
            newPhaseBlocks
        ));
    }

}
