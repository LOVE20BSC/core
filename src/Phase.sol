// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IPhase} from "./interfaces/IPhase.sol";
import {OrderedHistoryIndex} from "../lib/libs/src/OrderedHistoryIndex.sol";
import {Pagination} from "../lib/libs/src/Pagination.sol";
import {Math} from "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

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

    constructor(uint256 ORIGIN_BLOCKS_, uint256 ORIGIN_PHASE_BLOCKS_, uint256 TARGET_SECONDS_, uint256 ADJUST_THRESHOLD_, uint256 SYNC_OBSERVATION_LIMIT_) {
        require(ORIGIN_BLOCKS_ > 0 && ORIGIN_PHASE_BLOCKS_ > 0 && TARGET_SECONDS_ > 0 && ADJUST_THRESHOLD_ > 0 && SYNC_OBSERVATION_LIMIT_ > 0);
        ORIGIN_BLOCKS = ORIGIN_BLOCKS_;
        ORIGIN_PHASE_BLOCKS = ORIGIN_PHASE_BLOCKS_;
        TARGET_SECONDS = TARGET_SECONDS_;
        ADJUST_THRESHOLD = ADJUST_THRESHOLD_;
        SYNC_OBSERVATION_LIMIT = SYNC_OBSERVATION_LIMIT_;
        _recordSegment(Segment(1, ORIGIN_BLOCKS_, ORIGIN_PHASE_BLOCKS_));
    }

    function currentPhaseBlocks() public view returns (uint256) {
        uint256 phase = currentPhase();
        if (phase == 0) revert InvalidPhase(0);
        return _phaseBlocks(phase);
    }

    function currentPhase() public view returns (uint256) { return phaseAtBlock(block.number); }

    function phaseInfo(uint256 phaseNumber) public view returns (uint256 startBlock, uint256 phaseBlocks_) {
        if (phaseNumber == 0) revert InvalidPhase(phaseNumber);
        (bool found, uint256 key) = _segmentPhaseIndex.nearest(phaseNumber);
        require(found);
        Segment memory segment = _segmentByPhase[key];
        startBlock = segment.startBlock + (phaseNumber - segment.phase) * segment.phaseBlocks;
        phaseBlocks_ = segment.phaseBlocks;
    }

    function phaseAtBlock(uint256 blockNumber) public view returns (uint256) {
        if (blockNumber < ORIGIN_BLOCKS) return 0;
        (bool found, uint256 key) = _segmentStartBlockIndex.nearest(blockNumber);
        if (!found) return 0;
        Segment memory segment = _segmentByStartBlock[key];
        return segment.phase + (blockNumber - segment.startBlock) / segment.phaseBlocks;
    }

    function syncObservations(uint256 offset, uint256 limit, bool reverse)
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
        if (phase == 0) revert InvalidPhase(0);
        uint256 currentPhaseBlocks_ = _phaseBlocks(phase);
        if (_lastSyncPhase == phase) {
            // No adjustment occurred before this idempotent sync; return false explicitly.
            // forge-lint: disable-next-line(boolean-cst)
            return (false, currentPhaseBlocks_);
        }
        _lastSyncPhase = phase;
        uint256 selected = type(uint256).max;
        uint256 count = _observationBlocks.length;
        uint256 from = count > SYNC_OBSERVATION_LIMIT ? count - SYNC_OBSERVATION_LIMIT : 0;
        for (uint256 i = count; i > from; ) {
            --i;
            if (block.number - _observationBlocks[i] > currentPhaseBlocks_) { selected = i; break; }
        }
        if (selected == type(uint256).max && block.number > currentPhaseBlocks_) {
            uint256 cutoffBlock = block.number - currentPhaseBlocks_ - 1;
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
                uint256 difference = observed > currentPhaseBlocks_ ? observed - currentPhaseBlocks_ : currentPhaseBlocks_ - observed;
                uint256 deviation = Math.mulDiv(difference, 1e18, currentPhaseBlocks_);
                if (deviation > ADJUST_THRESHOLD) {
                    newPhaseBlocks = observed == 0 ? 1 : observed;
                    _recordNextSegment(phase, currentPhaseBlocks_, newPhaseBlocks);
                    emit PhaseAdjusted(phase + 1, currentPhaseBlocks_, newPhaseBlocks);
                    adjusted = true;
                }
            }
        }
        if (!adjusted) newPhaseBlocks = currentPhaseBlocks_;
        emit PhaseSynchronized(phase, block.number, block.timestamp, adjusted, newPhaseBlocks);
    }

    function _phaseBlocks(uint256 phase) private view returns (uint256) {
        (bool found, uint256 key) = _segmentPhaseIndex.nearest(phase);
        require(found);
        return _segmentByPhase[key].phaseBlocks;
    }

    function _recordSegment(Segment memory segment) private {
        _segmentPhaseIndex.record(segment.phase);
        _segmentStartBlockIndex.record(segment.startBlock);
        _segmentByPhase[segment.phase] = segment;
        _segmentByStartBlock[segment.startBlock] = segment;
    }

    function _recordNextSegment(uint256 phase, uint256 phaseBlocks_, uint256 newPhaseBlocks) private {
        (bool found, uint256 key) = _segmentPhaseIndex.latest();
        require(found);
        Segment memory previous = _segmentByPhase[key];
        _recordSegment(Segment(
            phase + 1,
            previous.startBlock + (phase - previous.phase + 1) * phaseBlocks_,
            newPhaseBlocks
        ));
    }

}
