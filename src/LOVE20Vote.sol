// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {Phase} from "./Phase.sol";
import {ILOVE20Stake} from "./interfaces/ILOVE20Stake.sol";
import {ILOVE20Submit, ActionSubmitInfo} from "./interfaces/ILOVE20Submit.sol";
import {ILOVE20Vote} from "./interfaces/ILOVE20Vote.sol";

contract LOVE20Vote is Phase, ILOVE20Vote {
    bool public initialized;
    address public stakeAddress;
    address public submitAddress;

    // ------ votesNums ----
    // tokenAddress => round => votesNum
    mapping(address => mapping(uint256 => uint256)) public votesNum;
    // tokenAddress => round => actionId => votesNum
    mapping(address => mapping(uint256 => mapping(uint256 => uint256)))
        public votesNumByActionId;

    // tokenAddress => round => account => votesNum
    mapping(address => mapping(uint256 => mapping(address => uint256)))
        public votesNumByAccount;
    // tokenAddress => round => account => actionId => votesNum
    mapping(address => mapping(uint256 => mapping(address => mapping(uint256 => uint256))))
        public votesNumByAccountByActionId;

    // ------ votedActionIds ------
    // tokenAddress => round => actionIds
    mapping(address => mapping(uint256 => uint256[])) internal _votedActionIds;
    // tokenAddress => round => account => actionIds
    mapping(address => mapping(uint256 => mapping(address => uint256[])))
        internal _accountVotedActionIds;

    // ------- voters ------
    // tokenAddress => round => actionId => account[]
    mapping(address => mapping(uint256 => mapping(uint256 => address[])))
        internal _accountsByActionId;

    constructor(
        uint256 originBlocks,
        uint256 phaseBlocks
    ) Phase(originBlocks, phaseBlocks) {}

    function initialize(
        address stakeAddress_,
        address submitAddress_
    ) external {
        if (initialized) {
            revert AlreadyInitialized();
        }
        initialized = true;
        stakeAddress = stakeAddress_;
        submitAddress = submitAddress_;
    }

    function vote(
        address tokenAddress,
        uint256[] calldata actionIds,
        uint256[] calldata votes
    ) external {
        if (!canVote(tokenAddress, msg.sender)) {
            revert CannotVote();
        }

        uint256 round = currentRound();

        for (uint256 i = 0; i < actionIds.length; i++) {
            _vote(tokenAddress, round, actionIds[i], votes[i]);
        }
    }

    function canVote(
        address tokenAddress,
        address account
    ) public view returns (bool) {
        return maxVotesNum(tokenAddress, account) > 0;
    }

    function maxVotesNum(
        address tokenAddress,
        address account
    ) public view returns (uint256) {
        return ILOVE20Stake(stakeAddress).validGovVotes(tokenAddress, account);
    }

    function isActionIdVoted(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external view returns (bool) {
        return votesNumByActionId[tokenAddress][round][actionId] > 0;
    }

    function votedActionIdsCount(
        address tokenAddress,
        uint256 round
    ) external view returns (uint256) {
        return _votedActionIds[tokenAddress][round].length;
    }

    function votedActionIdsAtIndex(
        address tokenAddress,
        uint256 round,
        uint256 index
    ) external view returns (uint256) {
        return _votedActionIds[tokenAddress][round][index];
    }

    function accountVotedActionIdsCount(
        address tokenAddress,
        uint256 round,
        address account
    ) external view returns (uint256) {
        return _accountVotedActionIds[tokenAddress][round][account].length;
    }

    function accountVotedActionIdsAtIndex(
        address tokenAddress,
        uint256 round,
        address account,
        uint256 index
    ) external view returns (uint256) {
        return _accountVotedActionIds[tokenAddress][round][account][index];
    }

    // votesNum functions for account

    function votesNumsByAccount(
        address tokenAddress,
        uint256 round,
        address account
    )
        external
        view
        returns (uint256[] memory actionIds, uint256[] memory votes)
    {
        actionIds = _accountVotedActionIds[tokenAddress][round][account];
        votes = votesNumsByAccountByActionIds(
            tokenAddress,
            round,
            account,
            actionIds
        );
        return (actionIds, votes);
    }

    function votesNumsByAccountByActionIds(
        address tokenAddress,
        uint256 round,
        address account,
        uint256[] memory actionIds
    ) public view returns (uint256[] memory votes) {
        votes = new uint256[](actionIds.length);
        for (uint256 i = 0; i < actionIds.length; i++) {
            votes[i] = votesNumByAccountByActionId[tokenAddress][round][
                account
            ][actionIds[i]];
        }
        return votes;
    }

    function _vote(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 votes
    ) internal {
        if (
            !ILOVE20Submit(submitAddress).isSubmitted(
                tokenAddress,
                round,
                actionId
            )
        ) {
            revert ActionNotSubmitted();
        }

        if (votes == 0) {
            revert VotesMustBeGreaterThanZero();
        }

        if (votesNumByActionId[tokenAddress][round][actionId] == 0) {
            _votedActionIds[tokenAddress][round].push(actionId);
        }
        votesNum[tokenAddress][round] += votes;
        votesNumByActionId[tokenAddress][round][actionId] += votes;

        if (
            votesNumByAccountByActionId[tokenAddress][round][msg.sender][
                actionId
            ] == 0
        ) {
            _accountVotedActionIds[tokenAddress][round][msg.sender].push(
                actionId
            );
            _accountsByActionId[tokenAddress][round][actionId].push(msg.sender);
        }

        votesNumByAccount[tokenAddress][round][msg.sender] += votes;
        votesNumByAccountByActionId[tokenAddress][round][msg.sender][
            actionId
        ] += votes;

        if (
            votesNumByAccount[tokenAddress][round][msg.sender] >
            maxVotesNum(tokenAddress, msg.sender)
        ) {
            revert NotEnoughVotesLeft();
        }

        emit Vote({
            tokenAddress: tokenAddress,
            round: round,
            voter: msg.sender,
            actionId: actionId,
            votes: votes
        });
    }

    function accountsByActionIdCount(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external view returns (uint256) {
        return _accountsByActionId[tokenAddress][round][actionId].length;
    }

    function accountsByActionIdAtIndex(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        uint256 index
    ) external view returns (address) {
        return _accountsByActionId[tokenAddress][round][actionId][index];
    }
}
