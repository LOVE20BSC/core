// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IVote} from "./interfaces/IVote.sol";
import {IPhase} from "./interfaces/IPhase.sol";
import {IStake} from "./interfaces/IStake.sol";
import {ISubmit, TargetMode} from "./interfaces/ISubmit.sol";
import {IMemberNFT} from "./interfaces/IMemberNFT.sol";
import {IProposalTarget} from "./interfaces/IProposalTarget.sol";
import {Pagination} from "@libs/Pagination.sol";

contract Vote is IVote {
    using Pagination for uint256[];

    bool public initialized;
    address public STAKE_ADDRESS;
    address public SUBMIT_ADDRESS;
    address public PHASE_ADDRESS;
    address public MEMBER_NFT_ADDRESS;

    // ------ vote amounts ------
    // tokenAddress => round => totalVoteAmount
    mapping(address => mapping(uint256 => uint256)) internal _totalVoteAmountByRound;
    // tokenAddress => round => proposalId => voteAmount
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) internal _voteAmountByProposalId;

    // tokenAddress => round => memberId => voteAmount
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) internal _voteAmountByMemberId;
    // tokenAddress => round => memberId => proposalId => voteAmount
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256)))) internal
        _voteAmountByMemberIdByProposalId;

    // ------ votedProposalIds ------
    // tokenAddress => round => proposalIds
    mapping(address => mapping(uint256 => uint256[])) internal _votedProposalIds;
    // tokenAddress => round => memberId => proposalIds
    mapping(address => mapping(uint256 => mapping(uint256 => uint256[]))) internal _votedProposalIdsByMemberId;

    // ------- voters ------
    // tokenAddress => round => proposalId => memberIds
    mapping(address => mapping(uint256 => mapping(uint256 => uint256[]))) internal _voterIdsByProposalId;

    // ------- voter boost snapshots ------
    // tokenAddress => round => memberId => boostShares at first vote in round
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) internal _voterBoostByMemberId;
    // tokenAddress => round => totalVoterBoost
    mapping(address => mapping(uint256 => uint256)) internal _totalVoterBoostByRound;

    // forge-lint: disable-next-item(missing-zero-check)
    function init(
        address phaseAddress,
        address stakeAddress,
        address submitAddress,
        address memberNFTAddress
    ) external {
        if (initialized) {
            revert AlreadyInitialized();
        }
        initialized = true;
        STAKE_ADDRESS = stakeAddress;
        SUBMIT_ADDRESS = submitAddress;
        PHASE_ADDRESS = phaseAddress;
        MEMBER_NFT_ADDRESS = memberNFTAddress;
    }

    modifier onlyMemberOwner(uint256 memberId) {
        if (IMemberNFT(MEMBER_NFT_ADDRESS).ownerOf(memberId) != msg.sender) {
            revert NotMemberOwner(memberId);
        }
        _;
    }

    function vote(
        address tokenAddress,
        uint256 memberId,
        uint256[] calldata proposalIds,
        uint256[] calldata voteAmounts,
        bytes[][] calldata targetData
    ) external onlyMemberOwner(memberId) {
        if (!canVote(tokenAddress, memberId)) {
            revert NoVotingPower(tokenAddress, memberId);
        }
        if (proposalIds.length == 0) {
            revert ProposalIdsEmpty();
        }
        if (proposalIds.length != voteAmounts.length) {
            revert ProposalVoteAmountsLengthMismatch(proposalIds.length, voteAmounts.length);
        }
        if (targetData.length != 0 && targetData.length != proposalIds.length) {
            revert TargetDataLengthMismatch(proposalIds.length, targetData.length);
        }

        uint256 round = currentRound();
        uint256 voteLimit = maxVoteAmount(tokenAddress, memberId);

        // An empty outer array means every callback gets empty Target Data; a supplied one lines up
        // with the proposals, entry by entry.
        bytes[] memory noTargetData = new bytes[](0);

        for (uint256 i = 0; i < proposalIds.length; i++) {
            bytes[] memory itemTargetData = noTargetData;
            if (targetData.length != 0) {
                itemTargetData = targetData[i];
            }
            _vote(tokenAddress, round, memberId, proposalIds[i], voteAmounts[i], voteLimit, itemTargetData);
        }
    }

    function currentRound() public view returns (uint256) {
        return IPhase(PHASE_ADDRESS).currentPhase();
    }

    function isRoundEnded(uint256 round) public view returns (bool) {
        if (round == 0) {
            return false;
        }
        return IPhase(PHASE_ADDRESS).currentPhase() > round;
    }

    function canVote(address tokenAddress, uint256 memberId) public view returns (bool) {
        return maxVoteAmount(tokenAddress, memberId) > 0;
    }

    function maxVoteAmount(address tokenAddress, uint256 memberId) public view returns (uint256) {
        return IStake(STAKE_ADDRESS).validGovVotes(tokenAddress, currentRound(), memberId);
    }

    function totalVoteAmount(address tokenAddress, uint256 round) external view returns (uint256) {
        return _totalVoteAmountByRound[tokenAddress][round];
    }

    function voteAmountByProposalId(address tokenAddress, uint256 round, uint256 proposalId)
        external
        view
        returns (uint256)
    {
        return _voteAmountByProposalId[tokenAddress][round][proposalId];
    }

    function voteAmountByMemberId(address tokenAddress, uint256 round, uint256 memberId)
        external
        view
        returns (uint256)
    {
        return _voteAmountByMemberId[tokenAddress][round][memberId];
    }

    function voteAmountByMemberIdByProposalId(address tokenAddress, uint256 round, uint256 memberId, uint256 proposalId)
        external
        view
        returns (uint256)
    {
        return _voteAmountByMemberIdByProposalId[tokenAddress][round][memberId][proposalId];
    }

    function isProposalIdVoted(address tokenAddress, uint256 round, uint256 proposalId) external view returns (bool) {
        return _voteAmountByProposalId[tokenAddress][round][proposalId] > 0;
    }

    function votedProposalIds(address tokenAddress, uint256 round, uint256 offset, uint256 limit, bool reverse)
        external
        view
        returns (uint256[] memory proposalIds, uint256 total)
    {
        return _votedProposalIds[tokenAddress][round].paginate(offset, limit, reverse);
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

    function votedProposalIdsByMemberId(
        address tokenAddress,
        uint256 round,
        uint256 memberId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory proposalIds, uint256[] memory voteAmounts, uint256 total) {
        (proposalIds, total) =
            _votedProposalIdsByMemberId[tokenAddress][round][memberId].paginate(offset, limit, reverse);
        voteAmounts = new uint256[](proposalIds.length);
        for (uint256 i = 0; i < proposalIds.length; i++) {
            voteAmounts[i] = _voteAmountByMemberIdByProposalId[tokenAddress][round][memberId][proposalIds[i]];
        }
    }

    function voteAmountsByMemberIdByIds(
        address tokenAddress,
        uint256 round,
        uint256 memberId,
        uint256[] calldata proposalIds
    ) external view returns (uint256[] memory voteAmounts) {
        voteAmounts = new uint256[](proposalIds.length);
        for (uint256 i = 0; i < proposalIds.length; i++) {
            voteAmounts[i] = _voteAmountByMemberIdByProposalId[tokenAddress][round][memberId][proposalIds[i]];
        }
    }

    function voterBoost(address tokenAddress, uint256 round, uint256 memberId)
        external
        view
        returns (uint256)
    {
        return _voterBoostByMemberId[tokenAddress][round][memberId];
    }

    function totalVoterBoost(address tokenAddress, uint256 round) external view returns (uint256) {
        return _totalVoterBoostByRound[tokenAddress][round];
    }

    function _vote(
        address tokenAddress,
        uint256 round,
        uint256 memberId,
        uint256 proposalId,
        uint256 voteAmount,
        uint256 voteLimit,
        bytes[] memory targetData
    ) internal {
        // Batch voting validates each proposal individually; the call cannot be moved outside the loop.
        // forge-lint: disable-next-item(calls-loop)
        if (!ISubmit(SUBMIT_ADDRESS).isSubmitted(tokenAddress, round, proposalId)) {
            // forge-lint: disable-next-line(require-revert-in-loop)
            revert ProposalNotSubmitted(tokenAddress, round, proposalId);
        }

        if (voteAmount == 0) {
            // forge-lint: disable-next-line(require-revert-in-loop)
            revert ZeroVoteAmount(proposalId);
        }

        // Update boost snapshot: check and add delta if member staked more
        {
            uint256 currentVoterBoost = _voterBoostByMemberId[tokenAddress][round][memberId];
            // forge-lint: disable-next-line(calls-loop, unused-return)
            uint256 actualVoterBoost = IStake(STAKE_ADDRESS).validBoostShares(tokenAddress, round, memberId);

            if (currentVoterBoost == 0) {
                // First vote in this round: record snapshot
                _voterBoostByMemberId[tokenAddress][round][memberId] = actualVoterBoost;
                _totalVoterBoostByRound[tokenAddress][round] += actualVoterBoost;
            } else if (actualVoterBoost > currentVoterBoost) {
                // Member staked more: record delta
                uint256 delta = actualVoterBoost - currentVoterBoost;
                _voterBoostByMemberId[tokenAddress][round][memberId] = actualVoterBoost;
                _totalVoterBoostByRound[tokenAddress][round] += delta;
            }
        }

        {
            bool isNewProposal = _voteAmountByMemberIdByProposalId[tokenAddress][round][memberId][proposalId] == 0;

            _totalVoteAmountByRound[tokenAddress][round] += voteAmount;
            _voteAmountByProposalId[tokenAddress][round][proposalId] += voteAmount;
            _voteAmountByMemberId[tokenAddress][round][memberId] += voteAmount;
            _voteAmountByMemberIdByProposalId[tokenAddress][round][memberId][proposalId] += voteAmount;

            if (isNewProposal) {
                if (_voteAmountByProposalId[tokenAddress][round][proposalId] == voteAmount) {
                    _votedProposalIds[tokenAddress][round].push(proposalId);
                }
                _votedProposalIdsByMemberId[tokenAddress][round][memberId].push(proposalId);
                _voterIdsByProposalId[tokenAddress][round][proposalId].push(memberId);
            }

            if (_voteAmountByMemberId[tokenAddress][round][memberId] > voteLimit) {
                // forge-lint: disable-next-item(require-revert-in-loop)
                revert VoteLimitExceeded(
                    tokenAddress, round, memberId, _voteAmountByMemberId[tokenAddress][round][memberId], voteLimit
                );
            }
        }

        // forge-lint: disable-next-item(reentrancy-events)
        emit VoteCast({
            tokenAddress: tokenAddress,
            round: round,
            voterId: memberId,
            proposalId: proposalId,
            voteAmount: voteAmount,
            voterBoost: _voterBoostByMemberId[tokenAddress][round][memberId],
            totalVoterBoost: _totalVoterBoostByRound[tokenAddress][round]
        });

        // forge-lint: disable-next-item(calls-loop, reentrancy-events)
        (address target, TargetMode targetMode) = ISubmit(SUBMIT_ADDRESS).proposalTarget(tokenAddress, proposalId);

        if (targetMode == TargetMode.Callback && target != address(0)) {
            // forge-lint: disable-next-item(calls-loop, reentrancy-events)
            IProposalTarget(target).onProposalVoted(tokenAddress, round, proposalId, memberId, voteAmount, targetData);
        }
    }
}
