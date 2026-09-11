// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

interface IPhaseErrors {
    error RoundNotStarted();
}

interface IPhase is IPhaseErrors {
    function originBlocks() external view returns (uint256);
    function phaseBlocks() external view returns (uint256);
    function currentRound() external view returns (uint256);

    function roundByBlockNumber(
        uint256 blockNumber
    ) external view returns (uint256);
}
