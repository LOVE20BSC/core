// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Mint} from "../src/Mint.sol";
import {LOVE20Token} from "../src/LOVE20Token.sol";
import {IMintErrors} from "../src/interfaces/IMint.sol";
import {ISubmitErrors, TargetMode} from "../src/interfaces/ISubmit.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @title MintInvariant - accounting invariants for Mint over a stateful Vote / Submit / Launch
/// @dev Load-bearing: the handler must keep the vote ledgers internally consistent
///      (`totalVoteAmount == Σ member votes == Σ proposal votes`, `totalVoterBoost == Σ member
///      snapshots`) and must only rewrite the round in progress. Otherwise the invariants recompute
///      a different expected value than Mint sees and fail spuriously, which is how the previous
///      stateless stubs ended up proving nothing.
contract MintInvariantTest {
    uint256 private constant PRECISION = 1e18;
    uint256 private constant VOTE_POOL_DIVISOR = 2;

    uint256 private constant MAX_ROUNDS = 5;
    uint256 private constant MAX_MEMBERS = 4;
    uint256 private constant MAX_PROPOSALS = 6;
    uint256 private constant MAX_LAUNCH = 3;

    uint256 private constant PROPOSAL_MIN_VOTE_RATIO = 2e17; // 20%, so a thin spread can miss
    uint256 private constant ROUND_GOV_RATIO = 1e17; // 10% of available
    uint256 private constant ROUND_PROPOSAL_RATIO = 1e17; // 10% of available
    uint256 private constant LAUNCH_THRESHOLD_RATIO = 1e17; // 10% of the unminted supply

    Mint public mint;
    LOVE20Token public token;

    uint256 public currentRound = 1;

    mapping(uint256 => uint256) private _totalVotes; // round => votes
    mapping(uint256 => mapping(uint256 => uint256)) private _proposalVotes; // round => proposalId => votes
    mapping(uint256 => mapping(uint256 => uint256)) private _memberVotes; // round => memberId => votes
    mapping(uint256 => mapping(uint256 => bool)) private _proposalVoted; // round => proposalId
    mapping(uint256 => uint256[]) private _votedIds; // round => proposalIds
    mapping(uint256 => uint256) private _totalBoost; // round => boost shares
    mapping(uint256 => mapping(uint256 => uint256)) private _memberBoost; // round => memberId => boost shares

    uint256 public issuedLaunchCountTotal;
    bool public launchCapViolation;

    // ============ Setup ============

    function setUp() public {
        mint = new Mint(
            address(this), // phase
            address(this), // vote
            address(this), // submit
            address(this), // launch
            address(this), // memberNFT
            PROPOSAL_MIN_VOTE_RATIO,
            ROUND_GOV_RATIO,
            ROUND_PROPOSAL_RATIO
        );
        token = new LOVE20Token("Test", "TST", 1e24, 1e28, address(this), address(mint), address(this));

        castVotes(0x0000_0100_0000_0200_0000_0300_0000_0400, 0x0000_0005_0000_0006_0000_0007_0000_0008);
    }

    function targetContracts() public view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(this);
    }

    // ============ Handler ============

    function castVotes(uint256 weightsSeed, uint256 boostSeed) public {
        _seedVotes(weightsSeed, boostSeed, true);
    }

    function castVotesWithoutBoost(uint256 weightsSeed) public {
        _seedVotes(weightsSeed, 0, false);
    }

    function castThinVotes() public {
        uint256 round = currentRound;
        _clearRound(round);
        for (uint256 proposalId = 1; proposalId <= MAX_PROPOSALS; proposalId++) {
            _proposalVotes[round][proposalId] = 1;
            _proposalVoted[round][proposalId] = true;
            _votedIds[round].push(proposalId);
            _totalVotes[round] += 1;
        }
        _memberVotes[round][1] = MAX_PROPOSALS;
    }

    function advanceRound(uint256 count) public {
        uint256 steps = bound(count, 1, 2);
        if (currentRound + steps > MAX_ROUNDS) {
            return;
        }
        currentRound += steps;
    }

    function prepareRound(uint256 round) public {
        round = bound(round, 1, MAX_ROUNDS);
        try mint.prepareRewardIfNeeded(address(token), round) {} catch {}
    }

    function settleGov(uint256 round, uint256 memberId) public {
        round = bound(round, 1, MAX_ROUNDS);
        memberId = bound(memberId, 1, MAX_MEMBERS);
        try mint.mintGovReward(address(token), round, memberId, address(this)) {} catch {}
    }

    function settleProposal(uint256 round, uint256 proposalId) public {
        round = bound(round, 1, MAX_ROUNDS);
        proposalId = bound(proposalId, 1, MAX_PROPOSALS);
        try mint.mintProposalReward(address(token), round, proposalId, address(this)) {} catch {}
    }

    function batchSettle(uint256[] calldata rounds, uint256 memberId) public {
        memberId = bound(memberId, 1, MAX_MEMBERS);
        if (rounds.length == 0 || rounds.length > MAX_ROUNDS) {
            return;
        }
        uint256[] memory boundedRounds = new uint256[](rounds.length);
        for (uint256 i = 0; i < rounds.length; i++) {
            boundedRounds[i] = bound(rounds[i], 1, MAX_ROUNDS);
        }
        try mint.mintGovRewards(address(token), boundedRounds, memberId, address(this)) {} catch {}
    }

    // ============ Invariants: reservation and issuance ============

    /// @notice The reservation always covers everything that has left it.
    function invariant_ReservedCoversMintedAndBurned() public view {
        uint256 reserved = mint.totalRewardReserved(address(token));
        uint256 minted = mint.totalRewardMinted(address(token));
        uint256 burned = mint.totalRewardBurned(address(token));
        assert(reserved >= minted + burned);
    }

    /// @notice Untouched reservation never exceeds the unminted supply, i.e. `rewardAvailable`
    ///         (which subtracts it) can never underflow. This is the property that keeps every later
    ///         prepare and settlement from reverting forever.
    function invariant_ReservedAvailableFitsInTheUnmintedSupply() public view {
        uint256 reservedAvailable = mint.reservedAvailable(address(token));
        assert(reservedAvailable + token.totalSupply() <= token.MAX_SUPPLY());
    }

    /// @notice `reserved` is exactly the sum of the frozen pools: it is only ever increased at
    ///         prepare, so a second increase for the same round would break this identity.
    function invariant_ReservedEqualsSumOfFrozenPools() public view {
        uint256 expected;
        for (uint256 round = 1; round <= MAX_ROUNDS; round++) {
            if (!mint.isRewardPrepared(address(token), round)) continue;
            expected += mint.govReward(address(token), round) + mint.proposalReward(address(token), round);
        }
        assert(mint.totalRewardReserved(address(token)) == expected);
    }

    /// @notice `burned` is exactly the sum of the pools cancelled at prepare time: the boost half when
    ///         nobody who voted has a boost snapshot, and the whole proposal pool when no proposal
    ///         clears the threshold. This is the invariant that pins both cancel branches.
    function invariant_BurnedEqualsSumOfCancelledPools() public view {
        uint256 expected;
        for (uint256 round = 1; round <= MAX_ROUNDS; round++) {
            if (!mint.isRewardPrepared(address(token), round)) continue;
            uint256 govReward = mint.govReward(address(token), round);
            uint256 proposalReward = mint.proposalReward(address(token), round);
            if (_totalBoost[round] == 0) {
                expected += govReward - (govReward / VOTE_POOL_DIVISOR);
            }
            if (mint.eligibleProposalVoteAmount(address(token), round) == 0) {
                expected += proposalReward;
            }
        }
        assert(mint.totalRewardBurned(address(token)) == expected);
    }

    /// @notice `minted` is exactly the sum of the settled entries, recomputed from the frozen pools.
    ///         A double spend, a pool read that drifted, or an over-issue would break this identity.
    function invariant_MintedEqualsSumOfSettledRewards() public view {
        uint256 expected;
        for (uint256 round = 1; round <= MAX_ROUNDS; round++) {
            if (!mint.isRewardPrepared(address(token), round)) continue;

            for (uint256 memberId = 1; memberId <= MAX_MEMBERS; memberId++) {
                (uint256 voteReward, uint256 boostReward, bool minted) =
                    mint.govRewardByMemberId(address(token), round, memberId);
                if (minted) {
                    expected += voteReward + boostReward;
                }
            }

            uint256[] storage proposalIds = _votedIds[round];
            for (uint256 i = 0; i < proposalIds.length; i++) {
                (uint256 amount, bool minted) =
                    mint.proposalRewardByProposalId(address(token), round, proposalIds[i]);
                if (minted) {
                    expected += amount;
                }
            }
        }
        assert(mint.totalRewardMinted(address(token)) == expected);
    }

    /// @notice Supply can never exceed the cap, no matter how many rounds settled.
    function invariant_SupplyNeverExceedsMaxSupply() public view {
        assert(token.totalSupply() <= token.MAX_SUPPLY());
    }

    // ============ Invariants: per-round distribution ============

    /// @notice The sum over all members never exceeds the round's governance pool. The single-member
    ///         bound alone cannot catch an over-issue that is spread across members.
    function invariant_GovRewardsSumNeverExceedsPool() public view {
        for (uint256 round = 1; round <= MAX_ROUNDS; round++) {
            if (!mint.isRewardPrepared(address(token), round)) continue;
            uint256 govReward = mint.govReward(address(token), round);
            uint256 sum;
            for (uint256 memberId = 1; memberId <= MAX_MEMBERS; memberId++) {
                (uint256 voteReward, uint256 boostReward,) =
                    mint.govRewardByMemberId(address(token), round, memberId);
                sum += voteReward + boostReward;
            }
            assert(sum <= govReward);
        }
    }

    /// @notice The sum over all proposals never exceeds the round's proposal pool.
    function invariant_ProposalRewardsSumNeverExceedsPool() public view {
        for (uint256 round = 1; round <= MAX_ROUNDS; round++) {
            if (!mint.isRewardPrepared(address(token), round)) continue;
            uint256 proposalReward = mint.proposalReward(address(token), round);
            uint256 sum;
            uint256[] storage proposalIds = _votedIds[round];
            for (uint256 i = 0; i < proposalIds.length; i++) {
                (uint256 amount,) = mint.proposalRewardByProposalId(address(token), round, proposalIds[i]);
                sum += amount;
            }
            assert(sum <= proposalReward);
        }
    }

    /// @notice No boost reward may be paid for a round whose boost pool was cancelled.
    function invariant_CancelledBoostPoolPaysNothing() public view {
        for (uint256 round = 1; round <= MAX_ROUNDS; round++) {
            if (!mint.isRewardPrepared(address(token), round)) continue;
            if (_totalBoost[round] != 0) continue;
            for (uint256 memberId = 1; memberId <= MAX_MEMBERS; memberId++) {
                (, uint256 boostReward,) = mint.govRewardByMemberId(address(token), round, memberId);
                assert(boostReward == 0);
            }
        }
    }

    /// @notice The frozen eligible-proposal vote total is exactly the sum of the voted proposals that
    ///         clear the threshold, computed from the votes actually cast in that round.
    function invariant_EligibleVotesMatchTheFrozenRule() public view {
        for (uint256 round = 1; round <= MAX_ROUNDS; round++) {
            if (!mint.isRewardPrepared(address(token), round)) continue;
            uint256 minVoteAmount =
                Math.mulDiv(_totalVotes[round], PROPOSAL_MIN_VOTE_RATIO, PRECISION, Math.Rounding.Ceil);
            uint256 expected;
            uint256[] storage proposalIds = _votedIds[round];
            for (uint256 i = 0; i < proposalIds.length; i++) {
                uint256 votes = _proposalVotes[round][proposalIds[i]];
                if (votes > 0 && votes >= minVoteAmount) {
                    expected += votes;
                }
            }
            assert(mint.eligibleProposalVoteAmount(address(token), round) == expected);
        }
    }

    // ============ Invariants: round boundary and launch ledger ============

    /// @notice A round that has not ended can never be prepared, by any caller and any round,
    ///         including round 0 and any round at or after the one in progress.
    function invariant_UnendedRoundsAreNeverPrepared() public view {
        assert(!mint.isRewardPrepared(address(token), 0));
        for (uint256 round = currentRound; round <= MAX_ROUNDS; round++) {
            assert(!mint.isRewardPrepared(address(token), round));
        }
    }

    /// @notice Mint never asks Launch to issue more counts than the community cap allows.
    function invariant_LaunchCountCapRespected() public view {
        assert(!launchCapViolation);
        assert(issuedLaunchCountTotal <= MAX_LAUNCH);
    }

    // ============ Reachability witnesses ============
    //
    // The invariants above only prove something if the fuzzer actually reaches the branches they
    // describe. These example-based witnesses pin one concrete path per branch, so the suite can
    // never silently degrade into "all invariants pass because nothing happened".

    /// @notice Nobody who voted holds a boost snapshot: prepare cancels exactly the boost half.
    function test_boostPoolIsCancelledWhenNoVoterHasBoost() public {
        castVotesWithoutBoost(0x0000_0100_0000_0200_0000_0300_0000_0400);
        require(_totalVotes[currentRound] > 0, "votes must be present");

        advanceRound(1);
        uint256 round = currentRound - 1;
        prepareRound(round);

        require(mint.isRewardPrepared(address(token), round), "round prepared");
        uint256 govReward = mint.govReward(address(token), round);
        require(govReward > 0, "gov pool frozen");

        // Cancelled amount is the ceil half of the governance pool; the vote half stays payable.
        require(
            mint.totalRewardBurned(address(token)) == govReward - (govReward / VOTE_POOL_DIVISOR),
            "boost half cancelled"
        );
        require(
            mint.eligibleProposalVoteAmount(address(token), round) > 0, "proposal pool stays intact"
        );
        invariant_BurnedEqualsSumOfCancelledPools();
    }

    /// @notice Votes exist but no proposal clears the threshold: prepare cancels the proposal pool
    ///         (and, with no boost snapshots, the boost half as well).
    function test_proposalPoolIsCancelledWhenNoProposalClearsTheThreshold() public {
        castThinVotes();
        uint256 votedRound = currentRound;
        require(_totalVotes[votedRound] == MAX_PROPOSALS, "thin spread seeded");

        advanceRound(1);
        prepareRound(votedRound);

        require(mint.isRewardPrepared(address(token), votedRound), "round prepared");
        uint256 govReward = mint.govReward(address(token), votedRound);
        uint256 proposalReward = mint.proposalReward(address(token), votedRound);
        require(govReward > 0 && proposalReward > 0, "both pools frozen");
        require(mint.eligibleProposalVoteAmount(address(token), votedRound) == 0, "nothing eligible");

        require(
            mint.totalRewardBurned(address(token))
                == (govReward - (govReward / VOTE_POOL_DIVISOR)) + proposalReward,
            "both cancelled pools burned"
        );
        invariant_BurnedEqualsSumOfCancelledPools();
        invariant_EligibleVotesMatchTheFrozenRule();
    }

    /// @notice The round in progress is rejected by prepare, by every path (direct and internal).
    function test_prepareRejectsTheRoundInProgress() public {
        uint256 round = currentRound;
        (bool ok, bytes memory reason) =
            address(mint).call(abi.encodeCall(mint.prepareRewardIfNeeded, (address(token), round)));
        require(!ok, "prepare must reject the round in progress");
        require(
            bytes4(reason) == IMintErrors.RoundNotEnded.selector, "expected RoundNotEnded"
        );
        require(!mint.isRewardPrepared(address(token), round), "round must stay unprepared");

        // Round 0 is rejected as well.
        (ok, reason) = address(mint).call(abi.encodeCall(mint.prepareRewardIfNeeded, (address(token), 0)));
        require(!ok, "prepare must reject round 0");
    }

    /// @notice A settled round cannot be settled twice, and its pool is not re-frozen.
    function test_settledRoundIsNotDoubleSpent() public {
        castVotes(0x0000_0100_0000_0200_0000_0300_0000_0400, 0x0000_0005_0000_0006_0000_0007_0000_0008);
        advanceRound(1);
        uint256 round = currentRound - 1;

        mint.mintGovReward(address(token), round, 1, address(this));
        uint256 mintedAfterFirst = mint.totalRewardMinted(address(token));
        uint256 reservedAfterFirst = mint.totalRewardReserved(address(token));
        require(mintedAfterFirst > 0, "first settlement must pay");

        (bool ok,) =
            address(mint).call(abi.encodeCall(mint.mintGovReward, (address(token), round, 1, address(this))));
        require(!ok, "second settlement must revert");
        require(
            mint.totalRewardMinted(address(token)) == mintedAfterFirst, "nothing extra minted"
        );
        require(
            mint.totalRewardReserved(address(token)) == reservedAfterFirst, "pool not re-reserved"
        );
        invariant_ReservedEqualsSumOfFrozenPools();
        invariant_MintedEqualsSumOfSettledRewards();
    }

    // ============ Handler internals ============

    function _seedVotes(uint256 weightsSeed, uint256 boostSeed, bool withBoost) private {
        uint256 round = currentRound;
        _clearRound(round);

        for (uint256 i = 0; i < MAX_MEMBERS; i++) {
            uint256 weight = (weightsSeed >> (i * 16)) & 0xFFFF;
            if (weight == 0) continue;

            uint256 proposalId = (i % MAX_PROPOSALS) + 1;
            _memberVotes[round][i + 1] = weight;
            _proposalVotes[round][proposalId] += weight;
            _totalVotes[round] += weight;
            if (!_proposalVoted[round][proposalId]) {
                _proposalVoted[round][proposalId] = true;
                _votedIds[round].push(proposalId);
            }

            if (withBoost) {
                uint256 boost = (boostSeed >> (i * 16)) & 0xFFFF;
                _memberBoost[round][i + 1] = boost;
                _totalBoost[round] += boost;
            }
        }
    }

    function _clearRound(uint256 round) private {
        delete _totalVotes[round];
        delete _totalBoost[round];
        delete _votedIds[round];
        for (uint256 memberId = 1; memberId <= MAX_MEMBERS; memberId++) {
            delete _memberVotes[round][memberId];
            delete _memberBoost[round][memberId];
        }
        for (uint256 proposalId = 1; proposalId <= MAX_PROPOSALS; proposalId++) {
            delete _proposalVotes[round][proposalId];
            delete _proposalVoted[round][proposalId];
        }
    }

    function bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (x < min || x > max) {
            return min + (x % (max - min + 1));
        }
        return x;
    }

    // ============ Mocks: Phase ============

    function currentPhase() external view returns (uint256) {
        return currentRound;
    }

    function PHASE_ADDRESS() external view returns (address) {
        return address(this);
    }

    // ============ Mocks: MemberNFT ============

    function ownerOf(uint256 memberId) external view returns (address) {
        if (memberId == 0 || memberId > MAX_MEMBERS) revert IERC721Errors.ERC721NonexistentToken(memberId);
        return address(this);
    }

    // ============ Mocks: Vote ============

    function totalVoteAmount(address, uint256 round) external view returns (uint256) {
        return _totalVotes[round];
    }

    function voteAmountByMemberId(address, uint256 round, uint256 memberId) external view returns (uint256) {
        return _memberVotes[round][memberId];
    }

    function voteAmountByProposalId(address, uint256 round, uint256 proposalId) external view returns (uint256) {
        return _proposalVotes[round][proposalId];
    }

    function totalVoterBoost(address, uint256 round) external view returns (uint256) {
        return _totalBoost[round];
    }

    function voterBoost(address, uint256 round, uint256 memberId) external view returns (uint256) {
        return _memberBoost[round][memberId];
    }

    function votedProposalIds(address, uint256 round, uint256 offset, uint256 limit, bool reverse)
        external
        view
        returns (uint256[] memory proposalIds, uint256 totalCount)
    {
        uint256[] storage all = _votedIds[round];
        totalCount = all.length;
        if (offset >= totalCount) {
            return (new uint256[](0), totalCount);
        }
        uint256 count = totalCount - offset;
        if (count > limit) {
            count = limit;
        }
        proposalIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            proposalIds[i] = all[reverse ? totalCount - 1 - offset - i : offset + i];
        }
    }

    function isRoundEnded(uint256 round) external view returns (bool) {
        return round != 0 && currentRound > round;
    }

    // ============ Mocks: Submit ============

    function proposalTarget(address tokenAddress, uint256 proposalId)
        external
        view
        returns (address target, TargetMode targetMode)
    {
        if (proposalId == 0 || proposalId > MAX_PROPOSALS) {
            revert ISubmitErrors.ProposalNotFound(tokenAddress, proposalId);
        }
        return (address(this), TargetMode.NoCallback);
    }

    // ============ Mocks: Launch ============

    function issuedLaunchCount(address) external view returns (uint256) {
        return issuedLaunchCountTotal;
    }

    function MAX_LAUNCH_COUNT() external pure returns (uint256) {
        return MAX_LAUNCH;
    }

    function LAUNCH_COUNT_THRESHOLD_RATIO() external pure returns (uint256) {
        return LAUNCH_THRESHOLD_RATIO;
    }

    /// @dev Load-bearing: a revert here would be reverted by Mint too and leave no trace, so the
    ///      violation is recorded instead of raised; `invariant_LaunchCountCapRespected` reads it.
    function addLaunchCount(address, uint256, uint256 count) external {
        require(msg.sender == address(mint), "only the minter may add counts");
        uint256 remaining = MAX_LAUNCH - issuedLaunchCountTotal;
        if (count > remaining) {
            launchCapViolation = true;
            count = remaining;
        }
        issuedLaunchCountTotal += count;
    }
}
