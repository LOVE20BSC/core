// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

interface IVoteErrors {
    error AlreadyInitialized();
    error InvalidTargetDataLength();
    error ProposalNotSubmitted();
    error CannotVote();
    error NotEnoughVotesLeft();
    error VotesMustBeGreaterThanZero();
    error InvalidAddress();
    error NotMemberOwner(uint256 memberId);
}

interface IVoteEvents {
    event Voted(
        address indexed tokenAddress,
        uint256 round,
        uint256 indexed voterId,
        uint256 indexed proposalId,
        uint256 votes
    );
}

interface IVote is IVoteErrors, IVoteEvents {
    function initialized() external view returns (bool);
    function phaseAddress() external view returns (address);
    function stakeAddress() external view returns (address);
    function submitAddress() external view returns (address);
    function memberNFTAddress() external view returns (address);
    function mintAddress() external view returns (address);

    function init(
        address phaseAddress_,
        address stakeAddress_,
        address submitAddress_,
        address memberNFTAddress_,
        address mintAddress_
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
        external
        view
        returns (uint256);

    function votesNumByMemberId(address tokenAddress, uint256 round, uint256 memberId) external view returns (uint256);

    function votesNumByMemberIdByProposalId(address tokenAddress, uint256 round, uint256 memberId, uint256 proposalId)
        external
        view
        returns (uint256);

    function isProposalIdVoted(address tokenAddress, uint256 round, uint256 proposalId) external view returns (bool);

    function votedProposalIds(address tokenAddress, uint256 round, uint256 offset, uint256 limit, bool reverse)
        external
        view
        returns (uint256[] memory proposalIds, uint256 total);

    function votedProposalIdsByMemberId(
        address tokenAddress,
        uint256 round,
        uint256 memberId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory proposalIds, uint256 total);

    function voterIdsByProposalId(
        address tokenAddress,
        uint256 round,
        uint256 proposalId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory voterIds, uint256 total);

    function votesNumsByMemberId(
        address tokenAddress,
        uint256 round,
        uint256 memberId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory proposalIds, uint256[] memory votes, uint256 total);

    function votesNumsByMemberIdByProposalIds(
        address tokenAddress,
        uint256 round,
        uint256 memberId,
        uint256[] calldata proposalIds
    ) external view returns (uint256[] memory votes);

    function stakedAmountOfVotersByMemberId(address tokenAddress, uint256 round, uint256 memberId)
        external
        view
        returns (uint256);

    function stakedAmountOfVoters(address tokenAddress, uint256 round) external view returns (uint256);
}
