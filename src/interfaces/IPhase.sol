// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

interface IPhaseErrors {
    error InvalidPhase(uint256 phaseNumber);
    error InvalidKeyOrder();
}

interface IPhaseEvents {
    event PhaseSynchronized(
        uint256 indexed phase,
        uint256 blockNumber,
        uint256 timestamp,
        bool adjusted,
        uint256 phaseBlocks
    );
    event PhaseAdjusted(
        uint256 indexed effectivePhase,
        uint256 oldPhaseBlocks,
        uint256 newPhaseBlocks
    );
}

interface IPhase is IPhaseErrors, IPhaseEvents {
    function ORIGIN_BLOCKS() external view returns (uint256);
    function ORIGIN_PHASE_BLOCKS() external view returns (uint256);
    function TARGET_SECONDS() external view returns (uint256);
    function ADJUST_THRESHOLD() external view returns (uint256);
    function SYNC_OBSERVATION_LIMIT() external view returns (uint256);
    function currentPhaseBlocks() external view returns (uint256);
    function currentPhase() external view returns (uint256);
    function phaseInfo(uint256 phaseNumber)
        external view returns (uint256 startBlock, uint256 phaseBlocks_);
    function phaseAtBlock(uint256 blockNumber) external view returns (uint256);
    function syncObservations(uint256 offset, uint256 limit, bool reverse)
        external view returns (uint256[] memory blockNumbers, uint256[] memory blockTimestamps, uint256 totalCount);
    function sync() external returns (bool adjusted, uint256 newPhaseBlocks);
}
