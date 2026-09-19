// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IVote} from "./interfaces/IVote.sol";
import {IPhase} from "./interfaces/IPhase.sol";
import {IStake} from "./interfaces/IStake.sol";
import {ISubmit, ProposalInfo, TargetMode} from "./interfaces/ISubmit.sol";
import {IMemberNFT} from "./interfaces/IMemberNFT.sol";
import {IProposalTarget} from "./interfaces/IProposalTarget.sol";
import {Pagination} from "../lib/libs/src/Pagination.sol";

contract Vote is IVote {
    using Pagination for uint256[];

    bool internal _initialized;
    address internal _stakeAddress;
    address internal _submitAddress;
    address internal _phaseAddress;
    address internal _memberNFTAddress;
    address internal _mintAddress;

    // ------ votesNums ----
    // tokenAddress => round => votesNum
    mapping(address => mapping(uint256 => uint256)) internal _votesNum;
    // tokenAddress => round => proposalId => votesNum
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) internal _votesNumByProposalId;

    // tokenAddress => round => memberId => votesNum
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) internal _votesNumByMemberId;
    // tokenAddress => round => memberId => proposalId => votesNum
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) internal
        _votesNumByMemberIdByProposalId;

    // ------ votedProposalIds ------
    // tokenAddress => round => proposalIds
    mapping(address => mapping(uint256 => uint256[])) internal _votedProposalIds;
    // tokenAddress => round => memberId => proposalIds
    mapping(address => mapping(uint256 => mapping(uint256 => uint256[]))) internal _votedProposalIdsByMemberId;

    // ------- voters ------
    // tokenAddress => round => proposalId => memberIds
    mapping(address => mapping(uint256 => mapping(uint256 => uint256[]))) internal _voterIdsByProposalId;

    // ------- stakedBoostOfVoters snapshots ------
    // tokenAddress => round => memberId => boostShares at first vote in round
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) internal _stakedBoostOfVotersByMemberId;
    // tokenAddress => round => totalBoostShares
    mapping(address => mapping(uint256 => uint256)) internal _stakedBoostOfVoters;

    function initialized() external view returns (bool) {
        return _initialized;
    }

    function stakeAddress() external view returns (address) {
        return _stakeAddress;
    }

    function submitAddress() external view returns (address) {
        return _submitAddress;
    }

    function phaseAddress() external view returns (address) {
        return _phaseAddress;
    }

    function memberNFTAddress() external view returns (address) {
        return _memberNFTAddress;
    }

    function mintAddress() external view returns (address) {
        return _mintAddress;
    }

    function init(
        address phaseAddress_,
        address stakeAddress_,
        address submitAddress_,
        address memberNFTAddress_,
        address mintAddress_
    ) external {
        if (_initialized) {
            revert AlreadyInitialized();
        }
        if (phaseAddress_ == address(0)) {
            revert InvalidAddress();
        }
        if (stakeAddress_ == address(0)) {
            revert InvalidAddress();
        }
        if (submitAddress_ == address(0)) {
            revert InvalidAddress();
        }
        if (memberNFTAddress_ == address(0)) {
            revert InvalidAddress();
        }
        if (mintAddress_ == address(0)) {
            revert InvalidAddress();
        }
        _initialized = true;
        _stakeAddress = stakeAddress_;
        _submitAddress = submitAddress_;
        _phaseAddress = phaseAddress_;
        _memberNFTAddress = memberNFTAddress_;
        _mintAddress = mintAddress_;
    }

    function vote(
        address tokenAddress,
        uint256 memberId,
        uint256[] calldata proposalIds,
        uint256[] calldata votes,
        bytes[][] calldata targetData
    ) external {
        if (IMemberNFT(_memberNFTAddress).ownerOf(memberId) != msg.sender) {
            revert NotMemberOwner(memberId);
        }
        if (!canVote(tokenAddress, memberId)) {
            revert CannotVote();
        }
        if (proposalIds.length != votes.length || proposalIds.length != targetData.length) {
            revert InvalidTargetDataLength();
        }

        uint256 round = currentRound();
        uint256 maxVotes = maxVotesNum(tokenAddress, memberId);

        for (uint256 i = 0; i < proposalIds.length; i++) {
            _vote(tokenAddress, round, memberId, proposalIds[i], votes[i], maxVotes, targetData[i]);
        }
    }

    function currentRound() public view returns (uint256) {
        return IPhase(_phaseAddress).currentPhase();
    }

    function isRoundEnded(uint256 round) public view returns (bool) {
        if (round == 0) {
            return false;
        }
        return IPhase(_phaseAddress).currentPhase() > round;
    }

    function canVote(address tokenAddress, uint256 memberId) public view returns (bool) {
        return maxVotesNum(tokenAddress, memberId) > 0;
    }

    function maxVotesNum(address tokenAddress, uint256 memberId) public view returns (uint256) {
        return IStake(_stakeAddress).validGovVotes(tokenAddress, memberId);
    }

    function votesNum(address tokenAddress, uint256 round) external view returns (uint256) {
        return _votesNum[tokenAddress][round];
    }

    function votesNumByProposalId(address tokenAddress, uint256 round, uint256 proposalId)
        external
        view
        returns (uint256)
    {
        return _votesNumByProposalId[tokenAddress][round][proposalId];
    }

    function votesNumByMemberId(address tokenAddress, uint256 round, uint256 memberId) external view returns (uint256) {
        return _votesNumByMemberId[tokenAddress][round][memberId];
    }

    function votesNumByMemberIdByProposalId(address tokenAddress, uint256 round, uint256 memberId, uint256 proposalId)
        external
        view
        returns (uint256)
    {
        return _votesNumByMemberIdByProposalId[tokenAddress][round][memberId][proposalId];
    }

    function isProposalIdVoted(address tokenAddress, uint256 round, uint256 proposalId) external view returns (bool) {
        return _votesNumByProposalId[tokenAddress][round][proposalId] > 0;
    }

    function votedProposalIds(address tokenAddress, uint256 round, uint256 offset, uint256 limit, bool reverse)
        external
        view
        returns (uint256[] memory proposalIds, uint256 total)
    {
        return _votedProposalIds[tokenAddress][round].paginate(offset, limit, reverse);
    }

    function votedProposalIdsByMemberId(
        address tokenAddress,
        uint256 round,
        uint256 memberId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory proposalIds, uint256 total) {
        return _votedProposalIdsByMemberId[tokenAddress][round][memberId].paginate(offset, limit, reverse);
    }

    function voterIdsByProposalId(
        address tokenAddress,
        uint256 round,
        uint256 proposalId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory voterIds, uint256 total) {
        return _voterIdsByProposalId[tokenAddress][round][proposalId].paginate(offset, limit, reverse);
    }

    function votesNumsByMemberId(
        address tokenAddress,
        uint256 round,
        uint256 memberId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory proposalIds, uint256[] memory votes, uint256 total) {
        (proposalIds, total) =
            _votedProposalIdsByMemberId[tokenAddress][round][memberId].paginate(offset, limit, reverse);
        votes = new uint256[](proposalIds.length);
        for (uint256 i = 0; i < proposalIds.length; i++) {
            votes[i] = _votesNumByMemberIdByProposalId[tokenAddress][round][memberId][proposalIds[i]];
        }
    }

    function votesNumsByMemberIdByProposalIds(
        address tokenAddress,
        uint256 round,
        uint256 memberId,
        uint256[] calldata proposalIds
    ) external view returns (uint256[] memory votes) {
        votes = new uint256[](proposalIds.length);
        for (uint256 i = 0; i < proposalIds.length; i++) {
            votes[i] = _votesNumByMemberIdByProposalId[tokenAddress][round][memberId][proposalIds[i]];
        }
    }

    function stakedAmountOfVotersByMemberId(address tokenAddress, uint256 round, uint256 memberId)
        external
        view
        returns (uint256)
    {
        return _stakedBoostOfVotersByMemberId[tokenAddress][round][memberId];
    }

    function stakedAmountOfVoters(address tokenAddress, uint256 round) external view returns (uint256) {
        return _stakedBoostOfVoters[tokenAddress][round];
    }

    function _vote(
        address tokenAddress,
        uint256 round,
        uint256 memberId,
        uint256 proposalId,
        uint256 votes,
        uint256 maxVotes,
        bytes[] calldata targetData
    ) internal {
        // Batch voting validates each proposal individually; the call cannot be moved outside the loop.
        // forge-lint: disable-next-item(calls-loop)
        if (!ISubmit(_submitAddress).isSubmitted(tokenAddress, round, proposalId)) {
            // forge-lint: disable-next-line(require-revert-in-loop)
            revert ProposalNotSubmitted();
        }

        if (votes == 0) {
            // forge-lint: disable-next-line(require-revert-in-loop)
            revert VotesMustBeGreaterThanZero();
        }

        // Update boost snapshot: check and add delta if member staked more
        uint256 currentBoost = _stakedBoostOfVotersByMemberId[tokenAddress][round][memberId];
        // forge-lint: disable-next-line(calls-loop, unused-return)
        uint256 actualBoost = IStake(_stakeAddress).cumulatedBoostShares(tokenAddress, round, memberId);

        if (currentBoost == 0) {
            // First vote in this round: record snapshot
            _stakedBoostOfVotersByMemberId[tokenAddress][round][memberId] = actualBoost;
            _stakedBoostOfVoters[tokenAddress][round] += actualBoost;
        } else if (actualBoost > currentBoost) {
            // Member staked more: record delta
            uint256 delta = actualBoost - currentBoost;
            _stakedBoostOfVotersByMemberId[tokenAddress][round][memberId] = actualBoost;
            _stakedBoostOfVoters[tokenAddress][round] += delta;
        }

        bool isNewProposal = _votesNumByMemberIdByProposalId[tokenAddress][round][memberId][proposalId] == 0;

        _votesNum[tokenAddress][round] += votes;
        _votesNumByProposalId[tokenAddress][round][proposalId] += votes;
        _votesNumByMemberId[tokenAddress][round][memberId] += votes;
        _votesNumByMemberIdByProposalId[tokenAddress][round][memberId][proposalId] += votes;

        if (isNewProposal) {
            if (_votesNumByProposalId[tokenAddress][round][proposalId] == votes) {
                _votedProposalIds[tokenAddress][round].push(proposalId);
            }
            _votedProposalIdsByMemberId[tokenAddress][round][memberId].push(proposalId);
            _voterIdsByProposalId[tokenAddress][round][proposalId].push(memberId);
        }

        if (_votesNumByMemberId[tokenAddress][round][memberId] > maxVotes) {
            // forge-lint: disable-next-line(require-revert-in-loop)
            revert NotEnoughVotesLeft();
        }

        // forge-lint: disable-next-item(reentrancy-events)
        emit Voted({
            tokenAddress: tokenAddress,
            round: round,
            voterId: memberId,
            proposalId: proposalId,
            votes: votes
        });

        // Callback to proposal target if configured (after event emission to follow CEI pattern)
        // forge-lint: disable-next-item(calls-loop, reentrancy-events)
        ProposalInfo memory proposal = ISubmit(_submitAddress).proposalInfosByIds(
            tokenAddress,
            _asSingletonArray(proposalId)
        )[0];

        if (proposal.body.targetMode == TargetMode.Callback && proposal.body.target != address(0)) {
            // forge-lint: disable-next-item(calls-loop, reentrancy-events)
            IProposalTarget(proposal.body.target).onProposalVoted(
                tokenAddress,
                round,
                proposalId,
                memberId,
                votes,
                targetData
            );
        }
    }

    function _asSingletonArray(uint256 element) private pure returns (uint256[] memory array) {
        // forge-lint: disable-next-line(calls-loop)
        array = new uint256[](1);
        array[0] = element;
    }
}
