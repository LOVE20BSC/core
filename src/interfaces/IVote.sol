// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {IPhase} from "./IPhase.sol";

interface ILOVE20VoteErrors {
    error AlreadyInitialized();
    error ActionNotSubmitted();
    error CannotVote();
    error NotEnoughVotesLeft();
    error VotesMustBeGreaterThanZero();
}

interface ILOVE20VoteEvents {
    event Vote(
        address indexed tokenAddress,
        uint256 round,
        address indexed voter,
        uint256 indexed actionId,
        uint256 votes
    );
}

interface ILOVE20Vote is IPhase, ILOVE20VoteErrors, ILOVE20VoteEvents {
    function stakeAddress() external view returns (address);
    function submitAddress() external view returns (address);

    function votesNum(
        address tokenAddress,
        uint256 round
    ) external view returns (uint256);
    function votesNumByActionId(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external view returns (uint256);
    function votesNumByAccount(
        address tokenAddress,
        uint256 round,
        address account
    ) external view returns (uint256);
    function votesNumByAccountByActionId(
        address tokenAddress,
        uint256 round,
        address account,
        uint256 actionId
    ) external view returns (uint256);

    function vote(
        address tokenAddress,
        uint256[] calldata actionIds,
        uint256[] calldata votes
    ) external;

    function canVote(
        address tokenAddress,
        address account
    ) external view returns (bool);

    function maxVotesNum(
        address tokenAddress,
        address account
    ) external view returns (uint256);

    function isActionIdVoted(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external view returns (bool);

    function votedActionIdsCount(
        address tokenAddress,
        uint256 round
    ) external view returns (uint256);

    function votedActionIdsAtIndex(
        address tokenAddress,
        uint256 round,
        uint256 index
    ) external view returns (uint256);

    function accountVotedActionIdsCount(
        address tokenAddress,
        uint256 round,
        address account
    ) external view returns (uint256);

    function accountVotedActionIdsAtIndex(
        address tokenAddress,
        uint256 round,
        address account,
        uint256 index
    ) external view returns (uint256);

    function votesNumsByAccount(
        address tokenAddress,
        uint256 round,
        address account
    )
        external
        view
        returns (uint256[] memory actionIds, uint256[] memory votes);

    function votesNumsByAccountByActionIds(
        address tokenAddress,
        uint256 round,
        address account,
        uint256[] memory actionIds
    ) external view returns (uint256[] memory votes);

    function accountsByActionIdCount(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external view returns (uint256);

    function accountsByActionIdAtIndex(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 index
    ) external view returns (address);
}
