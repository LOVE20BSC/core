// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IVote} from "./interfaces/IVote.sol";
import {ISubmit} from "./interfaces/ISubmit.sol";
import {ILaunch} from "./interfaces/ILaunch.sol";
import {IPhase} from "./interfaces/IPhase.sol";
import {IMemberNFT} from "./interfaces/IMemberNFT.sol";
import {ILOVE20Token} from "./interfaces/ILOVE20Token.sol";
import {IMint, BurnReason} from "./interfaces/IMint.sol";

contract Mint is IMint {
    uint256 private constant PRECISION = 1e18;
    uint256 private constant VOTE_POOL_DIVISOR = 2;

    mapping(address => uint256) internal _totalRewardReserved;
    mapping(address => uint256) internal _totalRewardMinted;
    mapping(address => uint256) internal _totalRewardBurned;

    mapping(address => mapping(uint256 => uint256)) internal _govReward;
    mapping(address => mapping(uint256 => uint256)) internal _proposalReward;
    mapping(address => mapping(uint256 => uint256)) internal _eligibleProposalVoteAmountByRound;
    mapping(address => mapping(uint256 => bool)) internal _isRewardPrepared;

    mapping(address => mapping(uint256 => mapping(uint256 => bool))) internal _proposalMinted;
    mapping(address => mapping(uint256 => mapping(uint256 => bool))) internal _govMinted;

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

    function eligibleProposalVoteAmount(address tokenAddress, uint256 round) external view returns (uint256) {
        return _eligibleProposalVoteAmountByRound[tokenAddress][round];
    }

    function isRewardPrepared(address tokenAddress, uint256 round) external view returns (bool) {
        return _isRewardPrepared[tokenAddress][round];
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

    function _isRoundEnded(uint256 round) private view returns (bool) {
        return round != 0 && IPhase(PHASE_ADDRESS).currentPhase() > round;
    }

    function prepareRewardIfNeeded(address tokenAddress, uint256 round) external {
        _prepareRewardIfNeeded(tokenAddress, round);
    }

    function _prepareRewardIfNeeded(address tokenAddress, uint256 round) internal {
        if (_isRewardPrepared[tokenAddress][round]) {
            return;
        }

        // forge-lint: disable-next-line(calls-loop)
        if (!_isRoundEnded(round)) {
            // forge-lint: disable-next-line(require-revert-in-loop)
            revert RoundNotEnded(round);
        }

        // forge-lint: disable-next-line(calls-loop)
        uint256 totalVoteAmount = IVote(VOTE_ADDRESS).totalVoteAmount(tokenAddress, round);

        uint256 govRewardAmount = 0;
        uint256 proposalRewardAmount = 0;
        uint256 eligibleVoteAmount = 0;

        if (totalVoteAmount != 0) {
            uint256 minVoteAmount = _minProposalVoteAmount(totalVoteAmount);
            eligibleVoteAmount = _calculateEligibleProposalVoteAmount(tokenAddress, round, minVoteAmount);

            uint256 available = rewardAvailable(tokenAddress);
            govRewardAmount = Math.mulDiv(available, ROUND_REWARD_GOV_RATIO, PRECISION);
            proposalRewardAmount = Math.mulDiv(available, ROUND_REWARD_PROPOSAL_RATIO, PRECISION);

            _totalRewardReserved[tokenAddress] += govRewardAmount + proposalRewardAmount;

            // forge-lint: disable-next-line(calls-loop)
            uint256 totalVoterBoost = IVote(VOTE_ADDRESS).totalVoterBoost(tokenAddress, round);

            if (totalVoterBoost == 0) {
                uint256 boostPoolAmount = govRewardAmount - (govRewardAmount / VOTE_POOL_DIVISOR);
                _burnCancelledPool(tokenAddress, round, boostPoolAmount, BurnReason.BoostPoolCancelled);
            }

            if (eligibleVoteAmount == 0) {
                _burnCancelledPool(tokenAddress, round, proposalRewardAmount, BurnReason.ProposalPoolCancelled);
            }
        }

        _govReward[tokenAddress][round] = govRewardAmount;
        _proposalReward[tokenAddress][round] = proposalRewardAmount;
        _eligibleProposalVoteAmountByRound[tokenAddress][round] = eligibleVoteAmount;
        // forge-lint: disable-next-line(missing-events-access-control)
        _isRewardPrepared[tokenAddress][round] = true;

        // slither-disable-next-line reentrancy-events
        emit RewardPrepared({
            tokenAddress: tokenAddress,
            round: round,
            govReward: govRewardAmount,
            proposalReward: proposalRewardAmount,
            eligibleProposalVoteAmount: eligibleVoteAmount,
            totalRewardReserved: _totalRewardReserved[tokenAddress],
            totalRewardBurned: _totalRewardBurned[tokenAddress]
        });
    }

    function _burnCancelledPool(address tokenAddress, uint256 round, uint256 amount, BurnReason reason) private {
        if (amount == 0) return;
        _totalRewardBurned[tokenAddress] += amount;
        // slither-disable-next-line reentrancy-events
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

        _prepareRewardIfNeeded(tokenAddress, round);

        if (_proposalMinted[tokenAddress][round][proposalId]) {
            revert ProposalRewardAlreadyMinted(tokenAddress, round, proposalId);
        }

        (amount, ) = _proposalRewardCalculation(tokenAddress, round, proposalId);
        if (amount == 0) {
            (uint256 voteAmount, , uint256 minVoteAmount) =
                _proposalVoteTally(tokenAddress, round, proposalId);
            if (voteAmount < minVoteAmount) {
                revert ProposalBelowThreshold(tokenAddress, round, proposalId, voteAmount, minVoteAmount);
            }
            if (_proposalReward[tokenAddress][round] == 0) {
                revert ProposalPoolEmpty(tokenAddress, round);
            }
            revert ProposalRewardRoundedToZero(tokenAddress, round, proposalId);
        }

        _proposalMinted[tokenAddress][round][proposalId] = true;
        _totalRewardMinted[tokenAddress] += amount;

        ILOVE20Token(tokenAddress).mint(recipient, amount);

        // forge-lint: disable-next-line(reentrancy-events)
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

    function _calculateEligibleProposalVoteAmount(
        address tokenAddress,
        uint256 round,
        uint256 minVoteAmount
    ) internal view returns (uint256 eligibleVoteAmount) {
        // slither-disable-next-line calls-loop
        (uint256[] memory proposalIds, uint256 totalProposalCount) = IVote(VOTE_ADDRESS).votedProposalIds(
            tokenAddress,
            round,
            0,
            0,
            false
        );

        if (totalProposalCount > 0) {
            // slither-disable-next-line unused-return
            (proposalIds, ) = IVote(VOTE_ADDRESS).votedProposalIds(
                tokenAddress,
                round,
                0,
                totalProposalCount,
                false
            );

            for (uint256 i = 0; i < proposalIds.length; i++) {
                // forge-lint: disable-next-line(calls-loop)
                uint256 voteAmount = IVote(VOTE_ADDRESS).voteAmountByProposalId(
                    tokenAddress,
                    round,
                    proposalIds[i]
                );
                if (voteAmount > 0 && voteAmount >= minVoteAmount) {
                    eligibleVoteAmount += voteAmount;
                }
            }
        }

        return eligibleVoteAmount;
    }

    function _proposalRewardCalculation(
        address tokenAddress,
        uint256 round,
        uint256 proposalId
    ) internal view returns (uint256 amount, bool minted) {
        minted = _proposalMinted[tokenAddress][round][proposalId];

        (uint256 proposalVoteAmount, uint256 totalVoteAmount, uint256 minVoteAmount) =
            _proposalVoteTally(tokenAddress, round, proposalId);

        if (totalVoteAmount == 0 || proposalVoteAmount == 0) {
            return (0, minted);
        }

        if (proposalVoteAmount < minVoteAmount) {
            return (0, minted);
        }

        uint256 proposalRewardAmount;
        uint256 eligibleVoteAmount;

        if (_isRewardPrepared[tokenAddress][round]) {
            proposalRewardAmount = _proposalReward[tokenAddress][round];
            eligibleVoteAmount = _eligibleProposalVoteAmountByRound[tokenAddress][round];
        } else {
            uint256 available = rewardAvailable(tokenAddress);
            proposalRewardAmount = Math.mulDiv(available, ROUND_REWARD_PROPOSAL_RATIO, PRECISION);
            eligibleVoteAmount = _calculateEligibleProposalVoteAmount(tokenAddress, round, minVoteAmount);
        }

        if (eligibleVoteAmount == 0) {
            return (0, minted);
        }

        // forge-lint: disable-next-line(divide-before-multiply)
        amount = (proposalRewardAmount * proposalVoteAmount) / eligibleVoteAmount;

        return (amount, minted);
    }

    function proposalRewardByProposalId(
        address tokenAddress,
        uint256 round,
        uint256 proposalId
    ) external view returns (uint256 amount, bool minted) {
        // forge-lint: disable-next-line(unused-return)
        ISubmit(SUBMIT_ADDRESS).proposalTarget(tokenAddress, proposalId);

        return _proposalRewardCalculation(tokenAddress, round, proposalId);
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

        uint256 govRewardAmount;
        if (_isRewardPrepared[tokenAddress][round]) {
            govRewardAmount = _govReward[tokenAddress][round];
        } else {
            uint256 available = rewardAvailable(tokenAddress);
            govRewardAmount = Math.mulDiv(available, ROUND_REWARD_GOV_RATIO, PRECISION);
        }

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
        uint256 boostReward,
        bool minted
    ) {
        // forge-lint: disable-next-line(unused-return)
        IMemberNFT(MEMBER_NFT_ADDRESS).ownerOf(memberId);

        return _govRewardCalculation(tokenAddress, round, memberId);
    }

    function isProposalIdWithReward(
        address tokenAddress,
        uint256 round,
        uint256 proposalId
    ) external view returns (bool) {
        if (_isRewardPrepared[tokenAddress][round]) {
            uint256 eligibleVoteAmount = _eligibleProposalVoteAmountByRound[tokenAddress][round];
            if (eligibleVoteAmount == 0) {
                return false;
            }
        }

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
    }

    function rewardAvailable(address tokenAddress) public view returns (uint256) {
        ILOVE20Token token = ILOVE20Token(tokenAddress);
        // forge-lint: disable-next-line(calls-loop)
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

        _prepareRewardIfNeeded(tokenAddress, round);

        if (_govMinted[tokenAddress][round][memberId]) {
            revert MemberRewardAlreadyMinted(tokenAddress, round, memberId);
        }

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
