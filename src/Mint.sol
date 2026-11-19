// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IVote} from "./interfaces/IVote.sol";
import {ISubmit} from "./interfaces/ISubmit.sol";
import {ILaunch} from "./interfaces/ILaunch.sol";
import {IPhase} from "./interfaces/IPhase.sol";
import {IMemberNFT} from "./interfaces/IMemberNFT.sol";
import {ILOVE20Token} from "./interfaces/ILOVE20Token.sol";
import {IMint, BurnReason, ProposalRewardStatus} from "./interfaces/IMint.sol";

contract Mint is IMint {
    uint256 private constant PRECISION = 1e18;
    uint256 private constant VOTE_POOL_DIVISOR = 2;

    struct ProposalBurnState {
        uint256 voteAmount;
        uint256 amount;
    }

    // tokenAddress => cumulative reward reserved across rounds
    mapping(address => uint256) internal _totalRewardReserved;
    // tokenAddress => cumulative reward minted across rounds
    mapping(address => uint256) internal _totalRewardMinted;
    // tokenAddress => cumulative reward burned across rounds
    mapping(address => uint256) internal _totalRewardBurned;

    // tokenAddress => round => governance reward pool
    mapping(address => mapping(uint256 => uint256)) internal _govReward;
    // tokenAddress => round => proposal reward pool
    mapping(address => mapping(uint256 => uint256)) internal _proposalReward;
    // tokenAddress => round => whether the unused boost pool has been burned
    mapping(address => mapping(uint256 => bool)) internal _unusedBoostRewardBurned;
    // tokenAddress => round => whether the reward pools have been reserved
    mapping(address => mapping(uint256 => bool)) internal _isRewardReserved;

    // tokenAddress => round => proposalId => reward settlement status
    mapping(address => mapping(uint256 => mapping(uint256 => ProposalRewardStatus))) internal _proposalRewardStatus;
    // tokenAddress => round => votes and floored shares processed by proposal burns
    mapping(address => mapping(uint256 => ProposalBurnState)) internal _proposalBurnProgress;
    // tokenAddress => round => memberId => whether the governance reward is settled
    mapping(address => mapping(uint256 => mapping(uint256 => bool))) internal _govMinted;

    // tokenAddress => memberId => minted reward credit not yet converted into launch count
    mapping(address => mapping(uint256 => uint256)) internal _launchCredit;

    address public VOTE_ADDRESS;
    address public SUBMIT_ADDRESS;
    address public LAUNCH_ADDRESS;
    address public MEMBER_NFT_ADDRESS;
    address public PHASE_ADDRESS;
    uint256 public PROPOSAL_REWARD_MIN_VOTE_RATIO;
    uint256 public ROUND_REWARD_GOV_RATIO;
    uint256 public ROUND_REWARD_PROPOSAL_RATIO;

    function totalRewardReserved(address tokenAddress) external view returns (uint256) {
        return _totalRewardReserved[tokenAddress];
    }

    function totalRewardMinted(address tokenAddress) external view returns (uint256) {
        return _totalRewardMinted[tokenAddress];
    }

    function totalRewardBurned(address tokenAddress) external view returns (uint256) {
        return _totalRewardBurned[tokenAddress];
    }

    function govReward(address tokenAddress, uint256 round) external view returns (uint256) {
        return _govReward[tokenAddress][round];
    }

    function proposalReward(address tokenAddress, uint256 round) external view returns (uint256) {
        return _proposalReward[tokenAddress][round];
    }

    function launchCredit(address tokenAddress, uint256 memberId) external view returns (uint256) {
        return _launchCredit[tokenAddress][memberId];
    }

    // forge-lint: disable-next-item(missing-zero-check)
    constructor(
        address phaseAddress,
        address voteAddress,
        address submitAddress,
        address launchAddress,
        address memberNFTAddress,
        uint256 proposalRewardMinVoteRatio,
        uint256 roundRewardGovRatio,
        uint256 roundRewardProposalRatio
    ) {
        VOTE_ADDRESS = voteAddress;
        SUBMIT_ADDRESS = submitAddress;
        LAUNCH_ADDRESS = launchAddress;
        MEMBER_NFT_ADDRESS = memberNFTAddress;
        PHASE_ADDRESS = phaseAddress;
        PROPOSAL_REWARD_MIN_VOTE_RATIO = proposalRewardMinVoteRatio;
        ROUND_REWARD_GOV_RATIO = roundRewardGovRatio;
        ROUND_REWARD_PROPOSAL_RATIO = roundRewardProposalRatio;
    }

    modifier onlyVote() {
        if (msg.sender != VOTE_ADDRESS) revert NotVoteContract(msg.sender);
        _;
    }

    function reserveRoundReward(address tokenAddress, uint256 round) external onlyVote {
        uint256 current = IPhase(PHASE_ADDRESS).currentPhase();
        if (round == 0 || round != current) revert RoundNotCurrent(round, current);
        if (!ILaunch(LAUNCH_ADDRESS).isLOVE20Token(tokenAddress)) revert TokenNotRegistered(tokenAddress);
        if (_isRewardReserved[tokenAddress][round]) return;

        uint256 available = rewardAvailable(tokenAddress);
        uint256 gov = Math.mulDiv(available, ROUND_REWARD_GOV_RATIO, PRECISION);
        uint256 proposal = Math.mulDiv(available, ROUND_REWARD_PROPOSAL_RATIO, PRECISION);
        _govReward[tokenAddress][round] = gov;
        _proposalReward[tokenAddress][round] = proposal;
        _totalRewardReserved[tokenAddress] += gov + proposal;
        _isRewardReserved[tokenAddress][round] = true;
        // forge-lint: disable-next-item(reentrancy-events)
        emit RoundRewardReserved({
            tokenAddress: tokenAddress,
            round: round,
            govReward: gov,
            proposalReward: proposal,
            totalRewardReserved: _totalRewardReserved[tokenAddress]
        });
    }

    function burnUnusedBoostReward(address tokenAddress, uint256 round) external {
        _checkSettlementRound(tokenAddress, round);
        _burnUnusedBoostReward(tokenAddress, round);
    }

    function _checkSettlementRound(address tokenAddress, uint256 round) private view {
        // forge-lint: disable-next-item(calls-loop, require-revert-in-loop)
        if (!ILaunch(LAUNCH_ADDRESS).isLOVE20Token(tokenAddress)) revert TokenNotRegistered(tokenAddress);

        // forge-lint: disable-next-item(calls-loop, require-revert-in-loop)
        if (round == 0 || IPhase(PHASE_ADDRESS).currentPhase() <= round) {
            revert RoundNotEnded(round);
        }
    }

    function _burnUnusedBoostReward(address tokenAddress, uint256 round) private {
        uint256 govRewardAmount = _govReward[tokenAddress][round];
        if (govRewardAmount == 0 || _unusedBoostRewardBurned[tokenAddress][round]) return;
        // forge-lint: disable-next-item(calls-loop)
        if (IVote(VOTE_ADDRESS).totalVoterBoost(tokenAddress, round) != 0) return;

        _unusedBoostRewardBurned[tokenAddress][round] = true;
        uint256 boostPoolAmount = govRewardAmount - (govRewardAmount / VOTE_POOL_DIVISOR);
        _burnCancelledPool(tokenAddress, round, boostPoolAmount, BurnReason.BoostPoolCancelled);
    }

    function burnProposalReward(
        address tokenAddress,
        uint256 round,
        uint256 proposalId
    ) external {
        _checkSettlementRound(tokenAddress, round);
        {
            ProposalRewardStatus status = _proposalRewardStatus[tokenAddress][round][proposalId];
            if (status == ProposalRewardStatus.Minted) {
                revert ProposalRewardAlreadyMinted(tokenAddress, round, proposalId);
            }
            if (status == ProposalRewardStatus.Burned) return;
        }

        _burnUnusedBoostReward(tokenAddress, round);
        (uint256 voteAmount, uint256 totalVoteAmount, uint256 minVoteAmount) =
            _proposalVoteTally(tokenAddress, round, proposalId);
        if (voteAmount == 0 || voteAmount >= minVoteAmount) return;

        uint256 pool = _proposalReward[tokenAddress][round];
        uint256 amount = _proposalRewardShare(pool, voteAmount, totalVoteAmount);
        _proposalRewardStatus[tokenAddress][round][proposalId] = ProposalRewardStatus.Burned;

        ProposalBurnState storage progress = _proposalBurnProgress[tokenAddress][round];
        progress.voteAmount += voteAmount;
        progress.amount += amount;
        _totalRewardBurned[tokenAddress] += amount;

        emit ProposalRewardBurned({
            tokenAddress: tokenAddress,
            round: round,
            proposalId: proposalId,
            amount: amount,
            totalRewardBurned: _totalRewardBurned[tokenAddress]
        });

        // Load-bearing: Counting each below-threshold proposal once makes equality proof that only rounding dust remains.
        if (progress.voteAmount == totalVoteAmount) {
            _burnCancelledPool(tokenAddress, round, pool - progress.amount, BurnReason.ProposalPoolCancelled);
        }
    }

    function _burnCancelledPool(address tokenAddress, uint256 round, uint256 amount, BurnReason reason) private {
        if (amount == 0) return;
        _totalRewardBurned[tokenAddress] += amount;
        // slither-disable-next-line reentrancy-events
        // forge-lint: disable-next-item(reentrancy-events)
        emit RewardBurned({
            tokenAddress: tokenAddress,
            round: round,
            amount: amount,
            totalRewardBurned: _totalRewardBurned[tokenAddress],
            reason: reason
        });
    }

    modifier onlyProposalTarget(
        address tokenAddress,
        uint256 proposalId
    ) {
        // forge-lint: disable-next-item(unused-return)
        (address target, ) = ISubmit(SUBMIT_ADDRESS).proposalTarget(tokenAddress, proposalId);
        if (msg.sender != target) {
            revert NotProposalTarget(msg.sender, target);
        }
        _;
    }

    function mintProposalReward(
        address tokenAddress,
        uint256 round,
        uint256 proposalId,
        address recipient
    ) external onlyProposalTarget(tokenAddress, proposalId) returns (uint256 amount) {
        if (recipient == address(0)) {
            revert ZeroRecipientAddress();
        }

        _checkSettlementRound(tokenAddress, round);
        {
            ProposalRewardStatus status = _proposalRewardStatus[tokenAddress][round][proposalId];
            if (status == ProposalRewardStatus.Minted) {
                revert ProposalRewardAlreadyMinted(tokenAddress, round, proposalId);
            }
            if (status == ProposalRewardStatus.Burned) {
                revert ProposalRewardAlreadyBurned(tokenAddress, round, proposalId);
            }
        }

        _burnUnusedBoostReward(tokenAddress, round);
        {
            uint256 pool = _proposalReward[tokenAddress][round];
            (uint256 voteAmount, uint256 totalVoteAmount, uint256 minVoteAmount) =
                _proposalVoteTally(tokenAddress, round, proposalId);
            if (voteAmount < minVoteAmount) {
                revert ProposalBelowThreshold(tokenAddress, round, proposalId, voteAmount, minVoteAmount);
            }
            if (pool == 0) {
                revert ProposalPoolEmpty(tokenAddress, round);
            }
            amount = _proposalRewardShare(pool, voteAmount, totalVoteAmount);
            if (amount == 0) {
                revert ProposalRewardRoundedToZero(tokenAddress, round, proposalId);
            }
        }

        _proposalRewardStatus[tokenAddress][round][proposalId] = ProposalRewardStatus.Minted;
        _totalRewardMinted[tokenAddress] += amount;

        ILOVE20Token(tokenAddress).mint(recipient, amount);

        // forge-lint: disable-next-item(reentrancy-events)
        emit ProposalRewardMinted({
            tokenAddress: tokenAddress,
            round: round,
            proposalId: proposalId,
            recipient: recipient,
            amount: amount,
            totalRewardMinted: _totalRewardMinted[tokenAddress]
        });

        return amount;
    }

    // forge-lint: disable-next-item(require-revert-in-loop)
    modifier onlyMemberOwner(uint256 memberId) {
        if (IMemberNFT(MEMBER_NFT_ADDRESS).ownerOf(memberId) != msg.sender) {
            revert NotMemberOwner(memberId);
        }
        _;
    }

    function mintGovReward(
        address tokenAddress,
        uint256 round,
        uint256 memberId,
        address recipient
    ) external onlyMemberOwner(memberId) returns (uint256 voteReward, uint256 boostReward) {
        return _mintGovReward(tokenAddress, round, memberId, recipient);
    }

    function mintGovRewards(
        address tokenAddress,
        uint256[] calldata rounds,
        uint256 memberId,
        address recipient
    ) external onlyMemberOwner(memberId) returns (
        uint256[] memory voteRewards,
        uint256[] memory boostRewards
    ) {
        uint256 length = rounds.length;
        voteRewards = new uint256[](length);
        boostRewards = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            (voteRewards[i], boostRewards[i]) = _mintGovReward(tokenAddress, rounds[i], memberId, recipient);
        }

        return (voteRewards, boostRewards);
    }

    function _proposalRewardShare(
        uint256 pool,
        uint256 voteAmount,
        uint256 totalVoteAmount
    ) private pure returns (uint256) {
        if (totalVoteAmount == 0) return 0;
        return Math.mulDiv(pool, voteAmount, totalVoteAmount);
    }

    function proposalRewardSettlement(
        address tokenAddress,
        uint256 round,
        // forge-lint: disable-next-item(unused-return)
        uint256 proposalId
    ) external view returns (uint256 amount, ProposalRewardStatus status) {
        ISubmit(SUBMIT_ADDRESS).proposalTarget(tokenAddress, proposalId);

        status = _proposalRewardStatus[tokenAddress][round][proposalId];
        (uint256 voteAmount, uint256 totalVoteAmount, uint256 minVoteAmount) =
            _proposalVoteTally(tokenAddress, round, proposalId);
        if (status == ProposalRewardStatus.Burned || voteAmount >= minVoteAmount) {
            amount = _proposalRewardShare(_proposalReward[tokenAddress][round], voteAmount, totalVoteAmount);
        }
    }

    // forge-lint: disable-next-item(calls-loop)
    function _govRewardCalculation(
        address tokenAddress,
        uint256 round,
        uint256 memberId
    ) internal view returns (
        uint256 voteReward,
        uint256 boostReward,
        bool minted
    ) {
        minted = _govMinted[tokenAddress][round][memberId];

        uint256 memberVoteAmount = IVote(VOTE_ADDRESS).voteAmountByMemberId(tokenAddress, round, memberId);
        if (memberVoteAmount == 0) {
            return (0, 0, minted);
        }

        uint256 totalVoteAmount = IVote(VOTE_ADDRESS).totalVoteAmount(tokenAddress, round);
        if (totalVoteAmount == 0) {
            return (0, 0, minted);
        }

        uint256 govRewardAmount = _govReward[tokenAddress][round];
        uint256 votePoolAmount = govRewardAmount / VOTE_POOL_DIVISOR;
        uint256 boostPoolAmount = govRewardAmount - votePoolAmount;

        // forge-lint: disable-next-line(divide-before-multiply)
        voteReward = (votePoolAmount * memberVoteAmount) / totalVoteAmount;

        uint256 totalVoterBoost = IVote(VOTE_ADDRESS).totalVoterBoost(tokenAddress, round);
        if (totalVoterBoost == 0) {
            boostReward = 0;
        } else {
            uint256 voterBoost = IVote(VOTE_ADDRESS).voterBoost(
                tokenAddress,
                round,
                memberId
            );
            boostReward = (boostPoolAmount * voterBoost) / totalVoterBoost;
        }

        return (voteReward, boostReward, minted);
    }

    function govRewardByMemberId(
        address tokenAddress,
        uint256 round,
        uint256 memberId
    ) external view returns (
        uint256 voteReward,
        // forge-lint: disable-next-item(unused-return)
        uint256 boostReward,
        bool minted
    ) {
        IMemberNFT(MEMBER_NFT_ADDRESS).ownerOf(memberId);

        return _govRewardCalculation(tokenAddress, round, memberId);
    }

    function isProposalIdWithReward(
        address tokenAddress,
        uint256 round,
        uint256 proposalId
    ) external view returns (bool) {
        (uint256 proposalVoteAmount, , uint256 minVoteAmount) =
            _proposalVoteTally(tokenAddress, round, proposalId);

        return proposalVoteAmount > 0 && proposalVoteAmount >= minVoteAmount;
    }

    function _proposalVoteTally(
        address tokenAddress,
        uint256 round,
        uint256 proposalId
    ) private view returns (uint256 voteAmount, uint256 totalVoteAmount, uint256 minVoteAmount) {
        voteAmount = IVote(VOTE_ADDRESS).voteAmountByProposalId(tokenAddress, round, proposalId);
        totalVoteAmount = IVote(VOTE_ADDRESS).totalVoteAmount(tokenAddress, round);
        minVoteAmount = _minProposalVoteAmount(totalVoteAmount);
    }

    function _minProposalVoteAmount(uint256 totalVoteAmount) internal view returns (uint256) {
        return Math.mulDiv(totalVoteAmount, PROPOSAL_REWARD_MIN_VOTE_RATIO, PRECISION, Math.Rounding.Ceil);
    // forge-lint: disable-next-item(calls-loop)
    }

    function rewardAvailable(address tokenAddress) public view returns (uint256) {
        ILOVE20Token token = ILOVE20Token(tokenAddress);
        return (token.MAX_SUPPLY() - token.totalSupply()) - reservedAvailable(tokenAddress);
    }

    function reservedAvailable(address tokenAddress) public view returns (uint256) {
        return _totalRewardReserved[tokenAddress] - _totalRewardMinted[tokenAddress] - _totalRewardBurned[tokenAddress];
    }

    // forge-lint: disable-next-item(calls-loop)
    function _updateLaunchCredit(
        address tokenAddress,
        uint256 memberId,
        uint256 mintedAmount
    ) internal {
        ILaunch launch = ILaunch(LAUNCH_ADDRESS);
        uint256 issuedCount = launch.issuedLaunchCount(tokenAddress);
        uint256 maxCount = launch.MAX_LAUNCH_COUNT();
        if (issuedCount >= maxCount) {
            return;
        }

        ILOVE20Token token = ILOVE20Token(tokenAddress);
        uint256 totalSupplyBeforeMint = token.totalSupply() - mintedAmount;
        uint256 threshold = Math.mulDiv(
            token.MAX_SUPPLY() - totalSupplyBeforeMint, launch.LAUNCH_COUNT_THRESHOLD_RATIO(), PRECISION, Math.Rounding.Ceil
        );
        if (threshold == 0) {
            return;
        }

        // forge-lint: disable-next-line(missing-events-access-control)
        _launchCredit[tokenAddress][memberId] += mintedAmount;

        uint256 maxNewCount = maxCount - issuedCount;
        uint256 count = _launchCredit[tokenAddress][memberId] / threshold;
        if (count > maxNewCount) {
            count = maxNewCount;
        }

        if (count > 0) {
            // forge-lint: disable-next-line(divide-before-multiply)
            _launchCredit[tokenAddress][memberId] -= count * threshold;
            launch.addLaunchCount(tokenAddress, memberId, count);
        }
    }
    // forge-lint: disable-next-item(calls-loop, require-revert-in-loop)
    function _mintGovReward(
        address tokenAddress,
        uint256 round,
        uint256 memberId,
        address recipient
    ) private returns (uint256 voteReward, uint256 boostReward) {
        if (recipient == address(0)) {
            revert ZeroRecipientAddress();
        }

        _checkSettlementRound(tokenAddress, round);

        if (_govMinted[tokenAddress][round][memberId]) {
            revert MemberRewardAlreadyMinted(tokenAddress, round, memberId);
        }

        _burnUnusedBoostReward(tokenAddress, round);
        (voteReward, boostReward, ) = _govRewardCalculation(tokenAddress, round, memberId);

        if (voteReward + boostReward == 0) {
            if (IVote(VOTE_ADDRESS).voteAmountByMemberId(tokenAddress, round, memberId) == 0) {
                revert MemberHasNoVote(tokenAddress, round, memberId);
            }
            if (_govReward[tokenAddress][round] == 0) {
                revert MemberRewardPoolEmpty(tokenAddress, round);
            }
            revert MemberRewardRoundedToZero(tokenAddress, round, memberId);
        }

        // forge-lint: disable-next-line(missing-events-access-control)
        _govMinted[tokenAddress][round][memberId] = true;

        uint256 mintAmount = voteReward + boostReward;
        _totalRewardMinted[tokenAddress] += mintAmount;

        if (mintAmount > 0) {
            ILOVE20Token(tokenAddress).mint(recipient, mintAmount);
            _updateLaunchCredit(tokenAddress, memberId, mintAmount);
        }

        _emitGovRewardMinted(tokenAddress, round, memberId, voteReward, boostReward);

        return (voteReward, boostReward);
    }

    function _emitGovRewardMinted(
        address tokenAddress,
        uint256 round,
        uint256 memberId,
        uint256 voteReward,
        uint256 boostReward
    ) private {
        // forge-lint: disable-next-item(reentrancy-events)
        emit GovRewardMinted({
            tokenAddress: tokenAddress,
            round: round,
            memberId: memberId,
            voteReward: voteReward,
            boostReward: boostReward,
            totalRewardMinted: _totalRewardMinted[tokenAddress]
        });
    }
}
