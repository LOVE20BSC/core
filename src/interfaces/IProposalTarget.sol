// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

interface IProposalTarget {
    function onProposalCreated(
        address tokenAddress,
        uint256 proposalId,
        bytes calldata creationData
    ) external;
    function onProposalSubmitted(
        address tokenAddress,
        uint256 round,
        uint256 proposalId,
        uint256 submitterId,
        bytes calldata submitData
    ) external;
    function onProposalVoted(
        address tokenAddress,
        uint256 round,
        uint256 proposalId,
        uint256 voterId,
        uint256 voteAmount,
        bytes calldata voteData
    ) external;
}
