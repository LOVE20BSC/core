// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

interface IVoteEvents {
    event VoteCast(
        address indexed tokenAddress,
        uint256 round,
        uint256 indexed voterId,
        uint256 indexed proposalId,
        uint256 votes
    );
}

interface IVote is IVoteEvents {
    function stakeAddress() external view returns (address);
    function submitAddress() external view returns (address);
    function init(
        address phaseAddress,
        address stakeAddress,
        address submitAddress,
        address memberNFTAddress,
        address mintAddress
    ) external;
    function vote(
        address tokenAddress,
        uint256 memberId,
        uint256[] calldata proposalIds,
        uint256[] calldata votes,
        bytes[][] calldata targetData
    ) external;
    function currentRound() external view returns (uint256);
    function isRoundEnded(uint256 round) external view returns (bool);
    function canVote(address tokenAddress, uint256 memberId) external view returns (bool);
    function maxVotesNum(address tokenAddress, uint256 memberId) external view returns (uint256);
    function votesNum(address tokenAddress, uint256 round) external view returns (uint256);
    function votesNumByProposalId(address tokenAddress, uint256 round, uint256 proposalId)
        external view returns (uint256);
    function votesNumByAccount(address tokenAddress, uint256 round, uint256 memberId)
        external view returns (uint256);
    function votesNumByAccountByProposalId(
        address tokenAddress,
        uint256 round,
        uint256 memberId,
        uint256 proposalId
    ) external view returns (uint256);
    function isProposalIdVoted(address tokenAddress, uint256 round, uint256 proposalId)
        external view returns (bool);
    function accountVotedProposalIdsCount(address tokenAddress, uint256 round, uint256 memberId)
        external view returns (uint256);
    function accountVotedProposalIdsAtIndex(address tokenAddress, uint256 round,
        uint256 memberId, uint256 index) external view returns (uint256 proposalId);
    function votesNumsByMemberId(address tokenAddress, uint256 round, uint256 memberId)
        external view returns (uint256[] memory proposalIds, uint256[] memory votes);
    function votesNumsByMemberIdByProposalIds(address tokenAddress, uint256 round,
        uint256 memberId, uint256[] calldata proposalIds)
        external view returns (uint256[] memory votes);
    function accountsByProposalIdCount(address tokenAddress, uint256 round, uint256 proposalId)
        external view returns (uint256);
    function accountsByProposalIdAtIndex(address tokenAddress, uint256 round,
        uint256 proposalId, uint256 index) external view returns (uint256 memberId);
    function stakedAmountOfVotersByMemberId(
        address tokenAddress,
        uint256 round,
        uint256 memberId
    ) external view returns (uint256);
    function stakedAmountOfVoters(address tokenAddress, uint256 round)
        external view returns (uint256);
    function votedProposalIdsCount(address tokenAddress, uint256 round)
        external view returns (uint256);
    function votedProposalIdsAtIndex(address tokenAddress, uint256 round, uint256 index)
        external view returns (uint256 proposalId);

    error AlreadyInitialized();
    error InvalidTargetDataLength();
    error ProposalNotSubmitted();
    error CannotVote();
    error NotEnoughVotesLeft();
    error VotesMustBeGreaterThanZero();
}
