// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {IPhase} from "./interfaces/IPhase.sol";

contract Phase is IPhase {
    uint256 public immutable originBlocks;
    uint256 public immutable phaseBlocks;

    constructor(uint256 originBlocks_, uint256 phaseBlocks_) {
        originBlocks = originBlocks_;
        phaseBlocks = phaseBlocks_;
    }

    function currentRound() public view returns (uint256) {
        return roundByBlockNumber(block.number);
    }

    function roundByBlockNumber(
        uint256 blockNumber
    ) public view returns (uint256) {
        if (blockNumber < originBlocks) revert RoundNotStarted();
        uint256 offset = blockNumber - originBlocks;
        return offset / phaseBlocks; // round : [start, start + phaseBlocks-1]
    }
}
