// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

struct MemberStake {
    uint256 liquidityShares;
    uint256 boostShares;
    uint256 promisedWaitingPhases;
    uint256 unlockRequestPhase;
}

struct GlobalStake {
    uint256 totalLiquidityShares;
    uint256 totalLp;
    uint256 lastWithdrawableLp;
    uint256 lastFeeLp;
    uint256 lastSqrtKOfLp;
    uint256 totalBoostShares;
}

interface IStakeErrors {
    error AlreadyInitialized();
    error NotAllowedToStakeAtRoundZero();
    error ZeroTokenAmount();
    error ZeroParentTokenAmount();
    error ZeroBoostAmount();
    error InvalidPromisedWaitingPhases(uint256 value, uint256 min, uint256 max);
    error PromisedWaitingPhasesDecreased(uint256 requested, uint256 current);
    error UnstakeAlreadyRequested(address tokenAddress, uint256 memberId);
    error UnstakeNotRequested(address tokenAddress, uint256 memberId);
    error NoStakedLiquidity(address tokenAddress, uint256 memberId);
    error InsufficientWaitingPhases(uint256 currentRound, uint256 unlockRound);
    error NotMemberOwner(uint256 memberId);
    error StakeRightsUsed(address tokenAddress, uint256 round, uint256 memberId);
    error SlippageExceeded(uint256 actualDeviation, uint256 maxDeviation);
    error SourceAndTargetMemberIdsMustBeDifferent(uint256 sourceMemberId, uint256 targetMemberId);
    error TargetPromisedWaitingPhasesTooShort(uint256 targetPhases, uint256 sourcePhases);
    error TokenNotRegistered(address tokenAddress);
    error PairMissing(address tokenAddress);
    error ZeroLiquidityMinted();
    error RoundNotStarted(uint256 requestedRound, uint256 currentRound);
}

interface IStakeEvents {
    event StakeLiquidity(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 indexed memberId,
        uint256 tokenAmountDesired,
        uint256 parentTokenAmountDesired,
        uint256 tokenAmount,
        uint256 parentTokenAmount,
        uint256 promisedWaitingPhases,
        uint256 govVotesAdded,
        uint256 govVotes,
        uint256 liquiditySharesAdded,
        uint256 liquidityShares
    );
    event StakeBoost(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 indexed memberId,
        uint256 boostAmount,
        uint256 promisedWaitingPhases,
        uint256 govVotesAdded,
        uint256 govVotes,
        uint256 boostSharesAdded,
        uint256 boostShares
    );
    event Unstake(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 indexed memberId,
        uint256 promisedWaitingPhases,
        uint256 govVotes,
        uint256 liquidityShares,
        uint256 boostShares
    );
    event Withdraw(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 indexed memberId,
        uint256 promisedWaitingPhases,
        uint256 liquidityShares,
        uint256 tokenAmountForLiquidity,
        uint256 parentTokenAmountForLiquidity,
        uint256 boostShares
    );
    event FeesSettled(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 feeLp,
        uint256 tokenBurned,
        uint256 parentTokenBurned
    );
    event StakeMerged(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 indexed sourceMemberId,
        uint256 targetMemberId,
        uint256 liquiditySharesMerged,
        uint256 boostSharesMerged
    );
}

interface IStake is IStakeErrors, IStakeEvents {
    function initialized() external view returns (bool);
    function phaseAddress() external view returns (address);
    function memberNFTAddress() external view returns (address);
    function voteAddress() external view returns (address);
    function launchAddress() external view returns (address);
    function routerAddress() external view returns (address);
    function pairFactoryAddress() external view returns (address);
    function init(
        address phaseAddress,
        address memberNFTAddress,
        address voteAddress,
        address launchAddress,
        address routerAddress,
        address pairFactoryAddress,
        uint256 promisedWaitingPhasesMin,
        uint256 promisedWaitingPhasesMax,
        uint256 feeSettlementRatio
    ) external;
    function settleFees(address tokenAddress) external;
    function stakeLiquidity(
        address tokenAddress,
        uint256 tokenAmount,
        uint256 parentTokenAmount,
        uint256 slippage,
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
    function pairAddress(address tokenAddress) external view returns (address);
    function totalBurnedToken(address tokenAddress) external view returns (uint256);
    function totalParentTokenBurned(address tokenAddress) external view returns (uint256);
    function globalGovVotes(address tokenAddress) external view returns (uint256);
    function stakeData(address tokenAddress, uint256 memberId)
        external view returns (
            uint256 liquidityShares,
            uint256 boostShares,
            uint256 promisedWaitingPhases,
            uint256 unlockRequestPhase,
            uint256 tokenAmountForLiquidity,
            uint256 parentTokenAmountForLiquidity
        );
    function validGovVotes(address tokenAddress, uint256 memberId) external view returns (uint256);
    function globalStakeData(address tokenAddress)
        external view returns (
            uint256 totalLiquidityShares,
            uint256 totalLp,
            uint256 withdrawableLp,
            uint256 feeLp,
            uint256 totalBoostShares,
            uint256 tokenAmountForLiquidity,
            uint256 parentTokenAmountForLiquidity
        );
    function canWithdraw(address tokenAddress, uint256 memberId) external view returns (bool);
    function cumulatedBoostShares(
        address tokenAddress,
        uint256 round,
        uint256 memberId
    ) external view returns (uint256);
    function globalBoostUpdatedRounds(address tokenAddress, uint256 offset, uint256 limit, bool reverse)
        external view returns (uint256[] memory rounds, uint256 totalCount);
    function boostUpdatedRounds(
        address tokenAddress,
        uint256 memberId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory rounds, uint256 totalCount);
}
