// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

interface IMintEvents {
    event RewardPrepared(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 govReward,
        uint256 proposalReward,
        uint256 eligibleProposalVotes,
        uint256 rewardReserved,
        uint256 rewardBurned
    );
    event GovernanceRewardMinted(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 indexed memberId,
        uint256 voteReward,
        uint256 boostReward,
        uint256 burnReward
    );
    event ProposalRewardMinted(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 indexed proposalId,
        address target,
        uint256 amount
    );
    event RewardBurned(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 amount,
        bytes32 reason
    );
}

interface IMintErrors {
    error AlreadyInitialized();
    error NoRewardAvailable();
    error AlreadyMinted();
    error RoundNotReadyToMint();
    error NotEnoughReward();
    error NotEnoughRewardToBurn();
    error NotMemberOwner(uint256 memberId);
    error InvalidAddress();
    error InvalidAmount();
    error UnauthorizedCaller();
}

interface IMint is IMintEvents, IMintErrors {
    function voteAddress() external view returns (address);
    function submitAddress() external view returns (address);
    function launchAddress() external view returns (address);
    function memberNFTAddress() external view returns (address);

    function PROPOSAL_REWARD_MIN_VOTE_PER_THOUSAND() external view returns (uint256);
    function ROUND_REWARD_GOV_PER_THOUSAND() external view returns (uint256);
    function ROUND_REWARD_PROPOSAL_PER_THOUSAND() external view returns (uint256);
    function MAX_GOV_BOOST_REWARD_MULTIPLIER() external view returns (uint256);
    function initialized() external view returns (bool);
    function init(
        address voteAddress,
        address submitAddress,
        address launchAddress,
        address memberNFTAddress,
        uint256 proposalRewardMinVotePerThousand,
        uint256 roundRewardGovPerThousand,
        uint256 roundRewardProposalPerThousand,
        uint256 maxGovBoostRewardMultiplier
    ) external;
    function mintProposalReward(address tokenAddress, uint256 round, uint256 proposalId)
        external returns (uint256 amount);
    function mintGovReward(address tokenAddress, uint256 memberId, uint256 round)
        external returns (uint256 voteReward, uint256 boostReward, uint256 burnReward);
    function mintGovRewards(address tokenAddress, uint256 memberId, uint256[] calldata rounds)
        external returns (
            uint256[] memory voteRewards,
            uint256[] memory boostRewards,
            uint256[] memory burnRewards
        );
    function rewardReserved(address tokenAddress) external view returns (uint256);
    function rewardMinted(address tokenAddress) external view returns (uint256);
    function rewardBurned(address tokenAddress) external view returns (uint256);
    function isRewardPrepared(address tokenAddress, uint256 round) external view returns (bool);
    function govReward(address tokenAddress, uint256 round) external view returns (uint256);
    function proposalReward(address tokenAddress, uint256 round) external view returns (uint256);
    function eligibleProposalVotes(address tokenAddress, uint256 round)
        external view returns (uint256);
    function proposalRewardByProposalId(address tokenAddress, uint256 round, uint256 proposalId)
        external view returns (uint256 amount, bool minted);
    function govRewardByMemberId(address tokenAddress, uint256 round, uint256 memberId)
        external view returns (
            uint256 voteReward,
            uint256 boostReward,
            uint256 burnReward,
            bool minted
        );
    function isProposalIdWithReward(address tokenAddress, uint256 round, uint256 proposalId)
        external view returns (bool);
    function rewardAvailable(address tokenAddress) external view returns (uint256);
    function reservedAvailable(address tokenAddress) external view returns (uint256);
    function launchCredit(address tokenAddress, uint256 memberId) external view returns (uint256);
}
