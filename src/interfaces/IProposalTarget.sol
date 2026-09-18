// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

interface IProposalTarget {
    function onProposalCreated(
        address tokenAddress,
        uint256 proposalId,
        bytes[] calldata targetData
    ) external;

    function onProposalSubmitted(
        address tokenAddress,
        uint256 proposalId,
        uint256 submitterId,
        bytes[] calldata targetData
    ) external;
}
