// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Math} from "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IVote} from "./interfaces/IVote.sol";
import {ISubmit} from "./interfaces/ISubmit.sol";
import {ILaunch} from "./interfaces/ILaunch.sol";
import {IMemberNFT} from "./interfaces/IMemberNFT.sol";
import {ILOVE20Token} from "./interfaces/ILOVE20Token.sol";
import {IMint} from "./interfaces/IMint.sol";

contract Mint is IMint {
    // ------ 累计账本 ------
    mapping(address => uint256) internal _rewardReserved;
    mapping(address => uint256) internal _rewardMinted;
    mapping(address => uint256) internal _rewardBurned;

    // ------ 轮次池与准备状态 ------
    mapping(address => mapping(uint256 => uint256)) internal _govReward;
    mapping(address => mapping(uint256 => uint256)) internal _proposalReward;
    mapping(address => mapping(uint256 => uint256)) internal _eligibleProposalVotes;
    mapping(address => mapping(uint256 => bool)) internal _isRewardPrepared;

    // ------ 铸造状态位 ------
    mapping(address => mapping(uint256 => mapping(uint256 => bool))) internal _proposalMinted;
    mapping(address => mapping(uint256 => mapping(uint256 => bool))) internal _govMinted;

    // ------ 发射额度账本 ------
    mapping(address => mapping(uint256 => uint256)) internal _launchCredit;

    // ------ 初始化与依赖 ------
    bool public initialized;
    address public voteAddress;
    address public submitAddress;
    address public launchAddress;
    address public memberNFTAddress;
    uint256 public PROPOSAL_REWARD_MIN_VOTE_PER_THOUSAND;
    uint256 public ROUND_REWARD_GOV_PER_THOUSAND;
    uint256 public ROUND_REWARD_PROPOSAL_PER_THOUSAND;
    uint256 public MAX_GOV_BOOST_REWARD_MULTIPLIER;

    // ------ 显式 getter ------
    function rewardReserved(address tokenAddress) external view returns (uint256) {
        return _rewardReserved[tokenAddress];
    }

    function rewardMinted(address tokenAddress) external view returns (uint256) {
        return _rewardMinted[tokenAddress];
    }

    function rewardBurned(address tokenAddress) external view returns (uint256) {
        return _rewardBurned[tokenAddress];
    }

    function govReward(address tokenAddress, uint256 round) external view returns (uint256) {
        return _govReward[tokenAddress][round];
    }

    function proposalReward(address tokenAddress, uint256 round) external view returns (uint256) {
        return _proposalReward[tokenAddress][round];
    }

    function eligibleProposalVotes(address tokenAddress, uint256 round) external view returns (uint256) {
        return _eligibleProposalVotes[tokenAddress][round];
    }

    function isRewardPrepared(address tokenAddress, uint256 round) external view returns (bool) {
        return _isRewardPrepared[tokenAddress][round];
    }

    function launchCredit(address tokenAddress, uint256 memberId) external view returns (uint256) {
        return _launchCredit[tokenAddress][memberId];
    }

    function init(
        address voteAddress_,
        address submitAddress_,
        address launchAddress_,
        address memberNFTAddress_,
        uint256 proposalRewardMinVotePerThousand_,
        uint256 roundRewardGovPerThousand_,
        uint256 roundRewardProposalPerThousand_,
        uint256 maxGovBoostRewardMultiplier_
    ) external {
        if (initialized) {
            revert AlreadyInitialized();
        }
        initialized = true;

        if (
            voteAddress_ == address(0) ||
            submitAddress_ == address(0) ||
            launchAddress_ == address(0) ||
            memberNFTAddress_ == address(0)
        ) {
            revert InvalidAddress();
        }

        if (proposalRewardMinVotePerThousand_ > 1000) {
            revert InvalidAmount();
        }

        if (roundRewardGovPerThousand_ + roundRewardProposalPerThousand_ > 1000) {
            revert InvalidAmount();
        }

        if (maxGovBoostRewardMultiplier_ == 0 || maxGovBoostRewardMultiplier_ > 1000) {
            revert InvalidAmount();
        }

        voteAddress = voteAddress_;
        submitAddress = submitAddress_;
        launchAddress = launchAddress_;
        memberNFTAddress = memberNFTAddress_;
        PROPOSAL_REWARD_MIN_VOTE_PER_THOUSAND = proposalRewardMinVotePerThousand_;
        ROUND_REWARD_GOV_PER_THOUSAND = roundRewardGovPerThousand_;
        ROUND_REWARD_PROPOSAL_PER_THOUSAND = roundRewardProposalPerThousand_;
        MAX_GOV_BOOST_REWARD_MULTIPLIER = maxGovBoostRewardMultiplier_;
    }

    function _prepareRewardIfNeeded(address tokenAddress, uint256 round) internal {
        if (_isRewardPrepared[tokenAddress][round]) {
            return;
        }

        // Called from mintGovReward/mintProposalReward; cannot hoist out of batch loop.
        // forge-lint: disable-next-line(calls-loop)
        if (!IVote(voteAddress).isRoundEnded(round)) {
            // Early validation; reverts before state changes in batch operations.
            // forge-lint: disable-next-line(require-revert-in-loop)
            revert RoundNotReadyToMint();
        }

        // Vote data changes per round; cannot be cached across batch iterations.
        // forge-lint: disable-next-line(calls-loop)
        uint256 totalVotes = IVote(voteAddress).votesNum(tokenAddress, round);

        if (totalVotes == 0) {
            _govReward[tokenAddress][round] = 0;
            _proposalReward[tokenAddress][round] = 0;
            _eligibleProposalVotes[tokenAddress][round] = 0;
            // RewardPrepared event emission below provides sufficient audit trail.
            // forge-lint: disable-next-line(missing-events-access-control)
            _isRewardPrepared[tokenAddress][round] = true;
            // slither-disable-next-line reentrancy-events
            emit RewardPrepared(
                tokenAddress, round, 0, 0, 0, _rewardReserved[tokenAddress], _rewardBurned[tokenAddress]
            );
            return;
        }

        uint256 minVotes = _minProposalVotes(totalVotes);
        uint256 eligibleVotes = _calculateEligibleProposalVotes(tokenAddress, round, minVotes);

        uint256 available = rewardAvailable(tokenAddress);
        uint256 govRewardAmount = (available * ROUND_REWARD_GOV_PER_THOUSAND) / 1000;
        uint256 proposalRewardAmount = (available * ROUND_REWARD_PROPOSAL_PER_THOUSAND) / 1000;

        _rewardReserved[tokenAddress] += govRewardAmount + proposalRewardAmount;
        _govReward[tokenAddress][round] = govRewardAmount;
        _proposalReward[tokenAddress][round] = proposalRewardAmount;
        _eligibleProposalVotes[tokenAddress][round] = eligibleVotes;
        // RewardPrepared event emission below provides sufficient audit trail.
        // forge-lint: disable-next-line(missing-events-access-control)
        _isRewardPrepared[tokenAddress][round] = true;

        // Boost data changes per round; cannot be cached across batch iterations.
        // forge-lint: disable-next-line(calls-loop)
        uint256 totalBoost = IVote(voteAddress).stakedAmountOfVoters(tokenAddress, round);

        if (totalBoost == 0) {
            uint256 boostPoolAmount = govRewardAmount - (govRewardAmount / 2);
            _rewardBurned[tokenAddress] += boostPoolAmount;
            if (boostPoolAmount > 0) {
                // slither-disable-next-line reentrancy-events
                emit RewardBurned(
                    tokenAddress,
                    round,
                    boostPoolAmount,
                    keccak256("boostPoolCancelled")
                );
            }
        }

        if (eligibleVotes == 0) {
            _rewardBurned[tokenAddress] += proposalRewardAmount;
            if (proposalRewardAmount > 0) {
                // slither-disable-next-line reentrancy-events
                emit RewardBurned(
                    tokenAddress,
                    round,
                    proposalRewardAmount,
                    keccak256("proposalPoolCancelled")
                );
            }
        }

        uint256 finalRewardReserved = _rewardReserved[tokenAddress];
        uint256 finalRewardBurned = _rewardBurned[tokenAddress];

        // slither-disable-next-line reentrancy-events
        emit RewardPrepared(
            tokenAddress,
            round,
            govRewardAmount,
            proposalRewardAmount,
            eligibleVotes,
            finalRewardReserved,
            finalRewardBurned
        );
    }

    function mintProposalReward(
        address tokenAddress,
        uint256 round,
        uint256 proposalId
    ) external returns (uint256 amount) {
        // Target mode governs Vote callbacks, not Mint authorization.
        // forge-lint: disable-next-line(unused-return)
        (address target, ) = ISubmit(submitAddress).proposalTarget(tokenAddress, proposalId);

        if (msg.sender != target) {
            revert UnauthorizedCaller();
        }

        if (!IVote(voteAddress).isRoundEnded(round)) {
            revert RoundNotReadyToMint();
        }

        // Automatically prepare rewards if not already done
        _prepareRewardIfNeeded(tokenAddress, round);

        if (_proposalMinted[tokenAddress][round][proposalId]) {
            revert AlreadyMinted();
        }

        // Existence already verified above; skip redundant check in query.
        (amount, ) = _proposalRewardCalculation(tokenAddress, round, proposalId);
        if (amount == 0) {
            revert NoRewardAvailable();
        }

        _proposalMinted[tokenAddress][round][proposalId] = true;
        _rewardMinted[tokenAddress] += amount;

        ILOVE20Token(tokenAddress).mint(target, amount);

        // LOVE20Token.mint has no callbacks; report only after it succeeds.
        // forge-lint: disable-next-line(reentrancy-events)
        emit ProposalRewardMinted(tokenAddress, round, proposalId, target, amount);

        return amount;
    }

    // Batch settlement repeats all checks and interactions per round; any failure reverts the batch.
    // forge-lint: disable-next-item(calls-loop, require-revert-in-loop)
    function mintGovReward(
        address tokenAddress,
        uint256 memberId,
        uint256 round
    ) public returns (uint256 voteReward, uint256 boostReward, uint256 burnReward) {
        if (IMemberNFT(memberNFTAddress).ownerOf(memberId) != msg.sender) {
            revert NotMemberOwner(memberId);
        }

        if (!IVote(voteAddress).isRoundEnded(round)) {
            revert RoundNotReadyToMint();
        }

        // Automatically prepare rewards if not already done
        _prepareRewardIfNeeded(tokenAddress, round);

        if (_govMinted[tokenAddress][round][memberId]) {
            revert AlreadyMinted();
        }

        // Existence already verified above; skip redundant check in query.
        (voteReward, boostReward, burnReward, ) = _govRewardCalculation(tokenAddress, round, memberId);

        if (voteReward + boostReward + burnReward == 0) {
            revert NoRewardAvailable();
        }

        // GovernanceRewardMinted below records this member/round settlement.
        // forge-lint: disable-next-line(missing-events-access-control)
        _govMinted[tokenAddress][round][memberId] = true;

        uint256 mintAmount = voteReward + boostReward;
        _rewardMinted[tokenAddress] += mintAmount;
        // Positive burns emit RewardBurned below; a zero burn changes nothing.
        // forge-lint: disable-next-line(missing-events-access-control)
        _rewardBurned[tokenAddress] += burnReward;

        if (mintAmount > 0) {
            ILOVE20Token(tokenAddress).mint(msg.sender, mintAmount);
            _updateLaunchCredit(tokenAddress, memberId, mintAmount);
        }

        if (burnReward > 0) {
            // Token minting and Launch.addLaunchCount have no callbacks; all changes are atomic.
            // forge-lint: disable-next-line(reentrancy-events)
            emit RewardBurned(tokenAddress, round, burnReward, keccak256("boostOverflow"));
        }

        // Report settlement after the callback-free Token and Launch interactions succeed.
        // forge-lint: disable-next-line(reentrancy-events)
        emit GovernanceRewardMinted(tokenAddress, round, memberId, voteReward, boostReward, burnReward);

        return (voteReward, boostReward, burnReward);
    }

    function mintGovRewards(
        address tokenAddress,
        uint256 memberId,
        uint256[] calldata rounds
    ) external returns (
        uint256[] memory voteRewards,
        uint256[] memory boostRewards,
        uint256[] memory burnRewards
    ) {
        uint256 length = rounds.length;
        voteRewards = new uint256[](length);
        boostRewards = new uint256[](length);
        burnRewards = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            (voteRewards[i], boostRewards[i], burnRewards[i]) =
                mintGovReward(tokenAddress, memberId, rounds[i]);
        }

        return (voteRewards, boostRewards, burnRewards);
    }

    function burnUnmintedProposalReward(
        address tokenAddress,
        uint256 round,
        uint256 proposalId
    ) external returns (uint256 amount) {
        // Only the proposal's registered Target may cancel its unminted incentive.
        // forge-lint: disable-next-line(unused-return)
        (address target, ) = ISubmit(submitAddress).proposalTarget(tokenAddress, proposalId);

        if (msg.sender != target) {
            revert UnauthorizedCaller();
        }

        if (!IVote(voteAddress).isRoundEnded(round)) {
            revert RoundNotReadyToMint();
        }

        // Automatically prepare rewards if not already done
        _prepareRewardIfNeeded(tokenAddress, round);

        if (_proposalMinted[tokenAddress][round][proposalId]) {
            revert AlreadyMinted();
        }

        // Existence already verified above; skip redundant check in query.
        (amount, ) = _proposalRewardCalculation(tokenAddress, round, proposalId);
        if (amount == 0) {
            revert NoRewardAvailable();
        }

        // Settle-by-burn: the proposal can never mint afterward; the reserved share
        // returns to availability through the burned ledger.
        _proposalMinted[tokenAddress][round][proposalId] = true;
        _rewardBurned[tokenAddress] += amount;

        emit RewardBurned(tokenAddress, round, amount, keccak256("proposalRewardUnallocatable"));

        return amount;
    }

    function _calculateEligibleProposalVotes(
        address tokenAddress,
        uint256 round,
        uint256 minVotes
    ) internal view returns (uint256 eligibleVotes) {
        // Proposal scanning happens once per round during prepare; cannot be hoisted.
        // slither-disable-next-line calls-loop
        (uint256[] memory proposalIds, uint256 totalProposalCount) = IVote(voteAddress).votedProposalIds(
            tokenAddress,
            round,
            0,
            0,
            false
        );

        if (totalProposalCount > 0) {
            // slither-disable-next-line unused-return
            (proposalIds, ) = IVote(voteAddress).votedProposalIds(
                tokenAddress,
                round,
                0,
                totalProposalCount,
                false
            );

            for (uint256 i = 0; i < proposalIds.length; i++) {
                // forge-lint: disable-next-line(calls-loop)
                uint256 votes = IVote(voteAddress).votesNumByProposalId(
                    tokenAddress,
                    round,
                    proposalIds[i]
                );
                if (votes > 0 && votes >= minVotes) {
                    eligibleVotes += votes;
                }
            }
        }

        return eligibleVotes;
    }

    function _proposalRewardCalculation(
        address tokenAddress,
        uint256 round,
        uint256 proposalId
    ) internal view returns (uint256 amount, bool minted) {
        minted = _proposalMinted[tokenAddress][round][proposalId];

        uint256 proposalVotes = IVote(voteAddress).votesNumByProposalId(tokenAddress, round, proposalId);
        uint256 totalVotes = IVote(voteAddress).votesNum(tokenAddress, round);

        if (totalVotes == 0 || proposalVotes == 0) {
            return (0, minted);
        }

        uint256 minVotes = _minProposalVotes(totalVotes);
        if (proposalVotes < minVotes) {
            return (0, minted);
        }

        // Calculate or read proposal pool
        uint256 proposalRewardAmount;
        uint256 eligibleVotes;

        if (_isRewardPrepared[tokenAddress][round]) {
            // Read cached values
            proposalRewardAmount = _proposalReward[tokenAddress][round];
            eligibleVotes = _eligibleProposalVotes[tokenAddress][round];
        } else {
            // Real-time calculation: scan all proposals
            uint256 available = rewardAvailable(tokenAddress);
            proposalRewardAmount = (available * ROUND_REWARD_PROPOSAL_PER_THOUSAND) / 1000;
            eligibleVotes = _calculateEligibleProposalVotes(tokenAddress, round, minVotes);
        }

        if (eligibleVotes == 0) {
            return (0, minted);
        }

        // Proportional distribution rounds down; dust stays in the pool.
        // forge-lint: disable-next-line(divide-before-multiply)
        amount = (proposalRewardAmount * proposalVotes) / eligibleVotes;

        return (amount, minted);
    }

    function proposalRewardByProposalId(
        address tokenAddress,
        uint256 round,
        uint256 proposalId
    ) external view returns (uint256 amount, bool minted) {
        // This read is only an existence check; Submit reverts for an invalid proposal ID.
        // forge-lint: disable-next-line(unused-return)
        ISubmit(submitAddress).proposalTarget(tokenAddress, proposalId);

        return _proposalRewardCalculation(tokenAddress, round, proposalId);
    }

    // Each batch round has its own frozen votes and boost weights; these reads cannot be hoisted.
    // forge-lint: disable-next-item(calls-loop)
    function _govRewardCalculation(
        address tokenAddress,
        uint256 round,
        uint256 memberId
    ) internal view returns (
        uint256 voteReward,
        uint256 boostReward,
        uint256 burnReward,
        bool minted
    ) {
        minted = _govMinted[tokenAddress][round][memberId];

        uint256 memberVotes = IVote(voteAddress).votesNumByMemberId(tokenAddress, round, memberId);
        if (memberVotes == 0) {
            return (0, 0, 0, minted);
        }

        uint256 totalVotes = IVote(voteAddress).votesNum(tokenAddress, round);
        if (totalVotes == 0) {
            return (0, 0, 0, minted);
        }

        // Calculate or read governance pool
        uint256 govRewardAmount;
        if (_isRewardPrepared[tokenAddress][round]) {
            govRewardAmount = _govReward[tokenAddress][round];
        } else {
            uint256 available = rewardAvailable(tokenAddress);
            govRewardAmount = (available * ROUND_REWARD_GOV_PER_THOUSAND) / 1000;
        }

        uint256 votePoolAmount = govRewardAmount / 2;
        uint256 boostPoolAmount = govRewardAmount - votePoolAmount;

        // The spec floors the vote half before distributing it; odd units belong to boost.
        // forge-lint: disable-next-line(divide-before-multiply)
        voteReward = (votePoolAmount * memberVotes) / totalVotes;

        uint256 totalBoost = IVote(voteAddress).stakedAmountOfVoters(tokenAddress, round);
        if (totalBoost == 0) {
            boostReward = 0;
            burnReward = 0;
        } else {
            uint256 memberBoost = IVote(voteAddress).stakedAmountOfVotersByMemberId(
                tokenAddress,
                round,
                memberId
            );
            uint256 theoreticalBoost = (boostPoolAmount * memberBoost) / totalBoost;
            // The cap is based on the already-rounded vote reward, not its fractional value.
            // forge-lint: disable-next-line(divide-before-multiply)
            uint256 maxBoostReward = voteReward * MAX_GOV_BOOST_REWARD_MULTIPLIER;
            boostReward = theoreticalBoost > maxBoostReward ? maxBoostReward : theoreticalBoost;
            burnReward = theoreticalBoost - boostReward;
        }

        return (voteReward, boostReward, burnReward, minted);
    }

    function govRewardByMemberId(
        address tokenAddress,
        uint256 round,
        uint256 memberId
    ) external view returns (
        uint256 voteReward,
        uint256 boostReward,
        uint256 burnReward,
        bool minted
    ) {
        // Only existence is needed here; ownerOf reverts for a nonexistent member.
        // forge-lint: disable-next-line(unused-return)
        IMemberNFT(memberNFTAddress).ownerOf(memberId);

        return _govRewardCalculation(tokenAddress, round, memberId);
    }

    function isProposalIdWithReward(
        address tokenAddress,
        uint256 round,
        uint256 proposalId
    ) external view returns (bool) {
        // Prepared: use cached eligibleVotes for fast rejection (whole-round optimization).
        if (_isRewardPrepared[tokenAddress][round]) {
            uint256 eligibleVotes = _eligibleProposalVotes[tokenAddress][round];
            if (eligibleVotes == 0) {
                return false;
            }
        }

        // Prepared or unprepared: read real-time Vote data to determine eligibility.
        uint256 proposalVotes = IVote(voteAddress).votesNumByProposalId(tokenAddress, round, proposalId);
        uint256 totalVotes = IVote(voteAddress).votesNum(tokenAddress, round);
        uint256 minVotes = _minProposalVotes(totalVotes);

        return proposalVotes > 0 && proposalVotes >= minVotes;
    }

    function _minProposalVotes(uint256 totalVotes) internal view returns (uint256) {
        return Math.mulDiv(totalVotes, PROPOSAL_REWARD_MIN_VOTE_PER_THOUSAND, 1000, Math.Rounding.Ceil);
    }

    function rewardAvailable(address tokenAddress) public view returns (uint256) {
        ILOVE20Token token = ILOVE20Token(tokenAddress);
        // Each batch round calls this; supply changes cannot be hoisted.
        // forge-lint: disable-next-line(calls-loop)
        return (token.maxSupply() - token.totalSupply()) - reservedAvailable(tokenAddress);
    }

    function reservedAvailable(address tokenAddress) public view returns (uint256) {
        return _rewardReserved[tokenAddress] - _rewardMinted[tokenAddress] - _rewardBurned[tokenAddress];
    }

    // Earlier rounds change supply, credit and issued count; each batch round must reread them.
    // forge-lint: disable-next-item(calls-loop)
    function _updateLaunchCredit(
        address tokenAddress,
        uint256 memberId,
        uint256 mintedAmount
    ) internal {
        ILaunch launch = ILaunch(launchAddress);
        uint256 issuedCount = launch.issuedLaunchCount(tokenAddress);
        uint256 maxCount = launch.MAX_LAUNCH_COUNT();
        if (issuedCount >= maxCount) {
            return;
        }

        ILOVE20Token token = ILOVE20Token(tokenAddress);
        uint256 totalSupplyBeforeMint = token.totalSupply() - mintedAmount;
        uint256 threshold = Math.mulDiv(
            token.maxSupply() - totalSupplyBeforeMint, launch.LAUNCH_RATIO(), 1e18, Math.Rounding.Ceil
        );
        if (threshold == 0) {
            return;
        }

        // GovernanceRewardMinted records this credit increment; Launch emits converted counts.
        // forge-lint: disable-next-line(missing-events-access-control)
        _launchCredit[tokenAddress][memberId] += mintedAmount;

        uint256 maxNewCount = maxCount - issuedCount;
        uint256 count = _launchCredit[tokenAddress][memberId] / threshold;
        if (count > maxNewCount) {
            count = maxNewCount;
        }

        if (count > 0) {
            // Remove only the whole thresholds converted, preserving fractional credit.
            // forge-lint: disable-next-line(divide-before-multiply)
            _launchCredit[tokenAddress][memberId] -= count * threshold;
            launch.addLaunchCount(tokenAddress, memberId, count);
        }
    }
}
