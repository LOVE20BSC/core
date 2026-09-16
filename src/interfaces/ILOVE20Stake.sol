// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {IPhase} from "./IPhase.sol";

struct AccountStakeStatus {
    uint256 slAmount;
    uint256 stAmount;
    uint256 promisedWaitingPhases;
    uint256 requestedUnstakeRound;
    uint256 govVotes;
}

interface ILOVE20StakeErrors {
    error AlreadyInitialized();
    error NotAllowedToStakeAtRoundZero();
    error InvalidToAddress();
    error StakeAmountMustBeSet();
    error UnstakeAlreadyRequested();
    error UnstakeNotRequested();
    error PromisedWaitingPhasesOutOfRange();
    error PromisedWaitingPhasesMustBeGreaterOrEqualThanBefore();
    error NoStakedLiquidity();
    error NotEnoughWaitingBlocks();
    error RoundHasNotStartedYet();
}

interface ILOVE20StakeEvents {
    event StakeLiquidity(
        address indexed tokenAddress,
        uint256 indexed round,
        address indexed account,
        uint256 tokenAmountForLP,
        uint256 parentTokenAmountForLP,
        uint256 promisedWaitingPhases,
        uint256 govVotesAdded,
        uint256 govVotes,
        uint256 slAmountAdded,
        uint256 slAmount
    );

    event StakeToken(
        address indexed tokenAddress,
        uint256 indexed round,
        address indexed account,
        uint256 tokenAmount,
        uint256 promisedWaitingPhases,
        uint256 govVotesAdded,
        uint256 govVotes,
        uint256 stAmount
    );
    event Unstake(
        address indexed tokenAddress,
        uint256 indexed round,
        address indexed account,
        uint256 promisedWaitingPhases,
        uint256 govVotes,
        uint256 slAmount,
        uint256 stAmount
    );
    event Withdraw(
        address indexed tokenAddress,
        uint256 indexed round,
        address indexed account,
        uint256 promisedWaitingPhases,
        uint256 slAmount,
        uint256 tokenAmountForLp,
        uint256 parentTokenAmountForLp,
        uint256 stAmount
    );
}

interface ILOVE20Stake is ILOVE20StakeErrors, ILOVE20StakeEvents, IPhase {
    function PROMISED_WAITING_PHASES_MIN() external view returns (uint256);
    function PROMISED_WAITING_PHASES_MAX() external view returns (uint256);
    function govVotesNum(address tokenAddress) external view returns (uint256);
    function accountStakeStatus(
        address tokenAddress,
        address account
    ) external view returns (AccountStakeStatus memory);
    function validGovVotes(
        address tokenAddress,
        address account
    ) external view returns (uint256);

    function stakeLiquidity(
        address tokenAddress,
        uint256 tokenAmountForLP,
        uint256 parentTokenAmountForLP,
        uint256 promisedWaitingPhases,
        address to
    ) external returns (uint256 govVotesAdded, uint256 slAmountAdded);
    function stakeToken(
        address tokenAddress,
        uint256 tokenAmount,
        uint256 promisedWaitingPhases,
        address to
    ) external returns (uint256 govVotesAdded);
    function unstake(address tokenAddress) external;
    function withdraw(address tokenAddress) external;
    function initialStakeRound(
        address tokenAddress
    ) external view returns (uint256);
    function caculateGovVotes(
        uint256 lpAmount,
        uint256 promisedWaitingPhases
    ) external pure returns (uint256);
    function cumulatedTokenAmount(
        address tokenAddress,
        uint256 round
    ) external view returns (uint256 tokenAmount);
    function cumulatedTokenAmountByAccount(
        address tokenAddress,
        uint256 round,
        address account
    ) external view returns (uint256 tokenAmount);

    function stakeTokenUpdatedRoundsCount(
        address tokenAddress
    ) external view returns (uint256);
    function stakeTokenUpdatedRoundsAtIndex(
        address tokenAddress,
        uint256 index
    ) external view returns (uint256);

    function stakeTokenUpdatedRoundsByAccountCount(
        address tokenAddress,
        address account
    ) external view returns (uint256);
    function stakeTokenUpdatedRoundsByAccountAtIndex(
        address tokenAddress,
        address account,
        uint256 index
    ) external view returns (uint256);
}
