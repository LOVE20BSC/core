// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

struct MemberStake {
    uint256 liquidityShares;
    uint256 boostShares;
    uint256 promisedWaitingPhases;
    uint256 unlockRequestPhase;
    uint256 firstGovVoteRound;
}

struct TotalStake {
    uint256 totalLiquidityShares;
    uint256 lastWithdrawableLp;
    uint256 lastFeeLp;
    uint256 lastSqrtKOfLp;
    uint256 totalBoostShares;
    uint256 firstGovVoteRound;
}

interface IStakeErrors {
    error StakeNotStarted();
    error ZeroTokenAmount();
    error ZeroParentTokenAmount();
    error ZeroBoostAmount();
    error InvalidPromisedWaitingPhases(
        uint256 value,
        uint256 minPhases,
        uint256 maxPhases
    );
    error PromisedWaitingPhasesDecreased(
        uint256 requested,
        uint256 current
    );
    error UnstakeAlreadyRequested(
        address tokenAddress,
        uint256 memberId
    );
    error UnstakeNotRequested(
        address tokenAddress,
        uint256 memberId
    );
    error NoStakedLiquidity(
        address tokenAddress,
        uint256 memberId
    );
    error UnlockRoundNotReached(
        uint256 currentRound,
        uint256 unlockRound
    );
    error NotMemberOwner(uint256 memberId);
    error StakeRightsUsed(
        address tokenAddress,
        uint256 round,
        uint256 memberId
    );
    error SourceEqualsTarget(uint256 sourceMemberId);
    error TargetPromisedWaitingPhasesTooShort(
        uint256 targetPhases,
        uint256 sourcePhases
    );
    error TokenNotRegistered(address tokenAddress);
    error PairMissing(address tokenAddress);
    error ZeroLiquidityMinted();
    error RoundNotStarted(
        uint256 requestedRound,
        uint256 currentRound
    );
    error BoostCapExceeded(
        address tokenAddress,
        uint256 memberId,
        uint256 requested,
        uint256 allowed
    );
}

interface IStakeEvents {
    event LiquidityStaked(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 indexed memberId,
        address caller,
        address memberOwner,
        uint256 tokenAmount,
        uint256 parentTokenAmount,
        uint256 promisedWaitingPhases,
        uint256 prevPromisedWaitingPhases,
        uint256 govVotesAdded,
        uint256 liquiditySharesAdded,
        uint256 liquidityShares,
        uint256 totalLiquidityShares,
        uint256 totalValidGovVotes,
        uint256 totalWithdrawableLp
    );
    event BoostStaked(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 indexed memberId,
        address caller,
        address memberOwner,
        uint256 boostAmount,
        uint256 promisedWaitingPhases,
        uint256 prevPromisedWaitingPhases,
        uint256 govVotesAdded,
        uint256 govVotes,
        uint256 boostShares,
        uint256 totalBoostShares,
        uint256 totalValidBoostShares,
        uint256 totalValidGovVotes
    );
    event Unstaked(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 indexed memberId,
        uint256 promisedWaitingPhases,
        uint256 govVotes,
        uint256 liquidityShares,
        uint256 boostShares,
        uint256 totalValidBoostShares,
        uint256 totalValidGovVotes
    );
    event StakeWithdrawn(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 indexed memberId,
        uint256 promisedWaitingPhases,
        uint256 liquidityShares,
        uint256 tokenAmountForLiquidity,
        uint256 parentTokenAmountForLiquidity,
        uint256 boostShares,
        uint256 withdrawableLpBurned,
        uint256 withdrawableLpToMember,
        uint256 totalLiquidityShares,
        uint256 totalBoostShares,
        uint256 totalWithdrawableLp
    );
    event FeesSettled(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 feeLpBurned,
        uint256 tokenBurned,
        uint256 parentTokenBurned,
        uint256 totalBurnedToken,
        uint256 totalParentTokenBurned,
        uint256 totalFeeLp
    );
    event FeeReclassified(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 feeLpAdded,
        uint256 withdrawableLpRemoved,
        uint256 totalFeeLp,
        uint256 totalWithdrawableLp,
        uint256 sqrtKOfLp,
        uint256 pairTotalSupply
    );
    event StakesMerged(
        address indexed tokenAddress,
        uint256 round,
        uint256 indexed sourceMemberId,
        uint256 indexed targetMemberId,
        uint256 liquiditySharesMerged,
        uint256 boostSharesMerged,
        uint256 targetGovVotes,
        uint256 targetLiquidityShares,
        uint256 targetBoostShares,
        uint256 targetPromisedWaitingPhases,
        uint256 prevSourceGovVotes,
        uint256 prevSourcePromisedWaitingPhases,
        uint256 totalValidGovVotes
    );
}

interface IStake is IStakeErrors, IStakeEvents {
    function PHASE_ADDRESS() external view returns (address);
    function MEMBER_NFT_ADDRESS() external view returns (address);
    function VOTE_ADDRESS() external view returns (address);
    function LAUNCH_ADDRESS() external view returns (address);
    function ROUTER_ADDRESS() external view returns (address);
    function PAIR_FACTORY_ADDRESS() external view returns (address);
    function settleFees(address tokenAddress) external;
    function stakeLiquidity(
        address tokenAddress,
        uint256 tokenAmount,
        uint256 parentTokenAmount,
        uint256 promisedWaitingPhases,
        uint256 memberId
    ) external returns (uint256 govVotesAdded, uint256 liquiditySharesAdded);
    function stakeBoost(
        address tokenAddress,
        uint256 boostAmount,
        uint256 promisedWaitingPhases,
        uint256 memberId
    ) external returns (uint256 govVotesAdded);
    function unstake(address tokenAddress, uint256 memberId) external;
    function withdraw(address tokenAddress, uint256 memberId) external;
    function mergeStake(address tokenAddress, uint256 sourceMemberId, uint256 targetMemberId) external;

    function PROMISED_WAITING_PHASES_MIN() external view returns (uint256);
    function PROMISED_WAITING_PHASES_MAX() external view returns (uint256);
    function FEE_SETTLEMENT_RATIO() external view returns (uint256);
    function BOOST_STAKE_SUPPLY_FACTOR() external view returns (uint256);
    function BOOST_STAKE_MULTIPLIER() external view returns (uint256);
    function LIQUIDITY_TOKEN_EQUIVALENCE_FACTOR() external view returns (uint256);
    function liquidityTokenAmount(address tokenAddress) external view returns (uint256);
    function boostStakeCap(address tokenAddress, uint256 memberId)
        external view returns (uint256 memberCap, uint256 memberUsed);
    function pairAddress(address tokenAddress) external view returns (address);
    function totalBurnedToken(address tokenAddress) external view returns (uint256);
    function totalParentTokenBurned(address tokenAddress) external view returns (uint256);
    function memberStake(address tokenAddress, uint256 memberId)
        external view returns (
            uint256 liquidityShares,
            uint256 boostShares,
            uint256 promisedWaitingPhases,
            uint256 unlockRequestPhase,
            uint256 tokenAmountForLiquidity,
            uint256 parentTokenAmountForLiquidity,
            uint256 firstGovVoteRound
        );
    function validGovVotes(address tokenAddress, uint256 round, uint256 memberId) external view returns (uint256);
    function totalValidGovVotes(address tokenAddress, uint256 round) external view returns (uint256);
    function totalValidGovVotesAdded(address tokenAddress, uint256 round) external view returns (uint256);
    function totalValidGovVotesRemoved(address tokenAddress, uint256 round) external view returns (uint256);
    function totalStake(address tokenAddress)
        external view returns (
            uint256 totalLiquidityShares,
            uint256 totalLp,
            uint256 withdrawableLp,
            uint256 feeLp,
            uint256 totalBoostShares,
            uint256 tokenAmountForLiquidity,
            uint256 parentTokenAmountForLiquidity,
            uint256 firstGovVoteRound
        );
    function canWithdraw(address tokenAddress, uint256 memberId) external view returns (bool);
    function validBoostShares(
        address tokenAddress,
        uint256 round,
        uint256 memberId
    ) external view returns (uint256);
    function totalValidBoostShares(address tokenAddress, uint256 round) external view returns (uint256);
    function totalValidBoostSharesAdded(address tokenAddress, uint256 round) external view returns (uint256);
    function totalValidBoostSharesRemoved(address tokenAddress, uint256 round) external view returns (uint256);
}
