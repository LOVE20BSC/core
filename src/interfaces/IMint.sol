// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

enum BurnReason {
    BoostPoolCancelled,
    ProposalPoolCancelled,
    BoostOverflow
}

interface IMintEvents {
    event RewardPrepared(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 govReward,
        uint256 proposalReward,
        uint256 eligibleProposalVoteAmount,
        uint256 rewardReserved,
        uint256 rewardBurned
    );
    event GovRewardMinted(
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
        address recipient,
        uint256 amount
    );
    event RewardBurned(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 amount,
        BurnReason reason
    );
}

interface IMintErrors {
    error AlreadyInitialized();
    error NotProposalTarget(
        address caller,
        address expectedTarget
    );
    error ZeroRecipientAddress();
    error RoundNotEnded(uint256 round);
    error ProposalRewardAlreadyMinted(
        address tokenAddress,
        uint256 round,
        uint256 proposalId
    );
    error MemberRewardAlreadyMinted(
        address tokenAddress,
        uint256 round,
        uint256 memberId
    );
    error ProposalRewardUnavailable(
        address tokenAddress,
        uint256 round,
        uint256 proposalId
    );
    error MemberRewardUnavailable(
        address tokenAddress,
        uint256 round,
        uint256 memberId
    );
    error NotMemberOwner(uint256 memberId);
}

interface IMint is IMintEvents, IMintErrors {
    function VOTE_ADDRESS() external view returns (address);
    function SUBMIT_ADDRESS() external view returns (address);
    function LAUNCH_ADDRESS() external view returns (address);
    function MEMBER_NFT_ADDRESS() external view returns (address);
    function PHASE_ADDRESS() external view returns (address);

    function PROPOSAL_REWARD_MIN_VOTE_RATIO() external view returns (uint256);
    function ROUND_REWARD_GOV_RATIO() external view returns (uint256);
    function ROUND_REWARD_PROPOSAL_RATIO() external view returns (uint256);
    function MAX_GOV_BOOST_REWARD_MULTIPLIER() external view returns (uint256);
    function initialized() external view returns (bool);
    function init(
        address voteAddress,
        address submitAddress,
        address launchAddress,
        address memberNFTAddress,
        uint256 proposalRewardMinVoteRatio,
        uint256 roundRewardGovRatio,
        uint256 roundRewardProposalRatio,
        uint256 maxGovBoostRewardMultiplier
    ) external;
    function mintProposalReward(
        address tokenAddress,
        uint256 round,
        uint256 proposalId,
        address recipient
    ) external returns (uint256 amount);
    function mintGovReward(address tokenAddress, uint256 memberId, uint256 round, address recipient)
        external returns (uint256 voteReward, uint256 boostReward, uint256 burnReward);
    function mintGovRewards(
        address tokenAddress,
        uint256 memberId,
        uint256[] calldata rounds,
        address recipient
    )
        external
        returns (
            uint256[] memory voteRewards,
            uint256[] memory boostRewards,
            uint256[] memory burnRewards
        );
    function rewardReserved(address tokenAddress) external view returns (uint256);
    function rewardMinted(address tokenAddress) external view returns (uint256);
    function rewardBurned(address tokenAddress) external view returns (uint256);
    function govReward(address tokenAddress, uint256 round) external view returns (uint256);
    function proposalReward(address tokenAddress, uint256 round) external view returns (uint256);
    function eligibleProposalVoteAmount(address tokenAddress, uint256 round)
        external view returns (uint256);
    function isRewardPrepared(address tokenAddress, uint256 round) external view returns (bool);
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
