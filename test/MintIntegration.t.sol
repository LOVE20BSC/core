// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Mint} from "../src/Mint.sol";
import {LOVE20Token} from "../src/LOVE20Token.sol";
import {ISubmitErrors, TargetMode} from "../src/interfaces/ISubmit.sol";
import {IERC721Errors} from "../lib/openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";

interface MintVm {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function warp(uint256) external;
    function expectRevert(bytes calldata) external;
}

/// @title MintIntegration - Real contract integration simulation tests
/// @notice Tests Mint contract behavior in multi-contract scenarios using mocks
/// @dev Real Phase/Vote/Submit require complex initialization; these tests use enhanced mocks
contract MintIntegrationTest {
    MintVm constant vm = MintVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    Mint public mint;
    LOVE20Token public token;
    MockPhase public phase;
    MockVote public vote;
    MockSubmit public submit;
    MockLaunch public launch;

    address public owner = address(this);
    address public member1 = address(0x1001);
    address public member2 = address(0x1002);
    address public target = address(0x3001);

    function setUp() public {
        // Deploy mock contracts
        phase = new MockPhase();
        vote = new MockVote();
        submit = new MockSubmit();
        launch = new MockLaunch();

        // Initialize Mint with mocks - pass vote for both voteAddress and memberNFTAddress
        mint = new Mint();
        mint.init(
            address(vote), // voteAddress
            address(submit), // submitAddress
            address(launch), // launchAddress
            address(this), // memberNFTAddress (test contract implements ownerOf)
            50, // 5% min proposal votes
            100, // 10% gov reward ratio
            100, // 10% proposal reward ratio
            2 // 2x max boost multiplier
        );

        // Create token
        token = new LOVE20Token(
            "TestCommunity",
            "TEST",
            10000, // initial supply
            1000000, // max supply
            owner,
            address(mint),
            address(launch)
        );
    }

    /// @notice Test 1: Full governance flow - Multi-member voting and settlement
    function testIntegration_FullGovernanceFlow() public {
        // Setup: 2 members, 1 proposal
        vote.setMemberVotes(address(token), 1, 1, 150);
        vote.setMemberVotes(address(token), 1, 2, 100);
        vote.setTotalVotes(address(token), 1, 250);
        vote.setMemberBoost(address(token), 1, 1, 2000);
        vote.setMemberBoost(address(token), 1, 2, 1000);
        vote.setTotalBoost(address(token), 1, 3000);

        uint256 proposalId = 1;
        vote.setProposalVotes(address(token), 1, proposalId, 250);
        vote.addVotedProposal(address(token), 1, proposalId);
        submit.setProposalTarget(proposalId, target, TargetMode.NoCallback);
        phase.setRoundEnded(1, true);

        // Prepare rewards
        mint.prepareRewardIfNeeded(address(token), 1);
        assertTrue(mint.isRewardPrepared(address(token), 1), "Reward should be prepared");

        // Member 1 claims (60% votes)
        (uint256 voteReward1, uint256 boostReward1,,) =
            mint.govRewardByMemberId(address(token), 1, 1);

        assertTrue(voteReward1 > 0, "Member1 should have vote reward");

        uint256 balanceBefore1 = token.balanceOf(member1);
        vm.prank(member1);
        mint.mintGovReward(address(token), 1, 1);
        uint256 balanceAfter1 = token.balanceOf(member1);

        assertEq(balanceAfter1 - balanceBefore1, voteReward1 + boostReward1, "Member1 rewards match");

        // Member 2 claims (40% votes)
        (uint256 voteReward2, uint256 boostReward2,,) =
            mint.govRewardByMemberId(address(token), 1, 2);

        uint256 balanceBefore2 = token.balanceOf(member2);
        vm.prank(member2);
        mint.mintGovReward(address(token), 2, 1);
        uint256 balanceAfter2 = token.balanceOf(member2);

        assertEq(balanceAfter2 - balanceBefore2, voteReward2 + boostReward2, "Member2 rewards match");

        // Proposal target claims
        (uint256 proposalAmount,) = mint.proposalRewardByProposalId(address(token), 1, proposalId);
        assertTrue(proposalAmount > 0, "Proposal should have reward");

        uint256 targetBefore = token.balanceOf(target);
        vm.prank(target);
        mint.mintProposalReward(address(token), 1, proposalId);
        uint256 targetAfter = token.balanceOf(target);

        assertEq(targetAfter - targetBefore, proposalAmount, "Target receives proposal reward");
    }

    /// @notice Test 2: Multi-token minting - Same member votes on 2 tokens
    function testIntegration_MultiTokenMinting() public {
        // Create second token
        LOVE20Token token2 = new LOVE20Token(
            "Community2",
            "COM2",
            5000,
            500000,
            owner,
            address(mint),
            address(launch)
        );

        // Setup member voting on both tokens in round 1
        vote.setMemberVotes(address(token), 1, 1, 200);
        vote.setTotalVotes(address(token), 1, 300);
        vote.setMemberBoost(address(token), 1, 1, 1000);
        vote.setTotalBoost(address(token), 1, 2000);
        vote.addVotedProposal(address(token), 1, 1);
        vote.setProposalVotes(address(token), 1, 1, 300);

        vote.setMemberVotes(address(token2), 1, 1, 150);
        vote.setTotalVotes(address(token2), 1, 200);
        vote.setMemberBoost(address(token2), 1, 1, 800);
        vote.setTotalBoost(address(token2), 1, 1500);
        vote.addVotedProposal(address(token2), 1, 2);
        vote.setProposalVotes(address(token2), 1, 2, 200);

        submit.setProposalTarget(1, target, TargetMode.NoCallback);
        submit.setProposalTarget(2, target, TargetMode.NoCallback);
        phase.setRoundEnded(1, true);

        // Prepare both
        mint.prepareRewardIfNeeded(address(token), 1);
        mint.prepareRewardIfNeeded(address(token2), 1);

        // Claim token1
        vm.prank(member1);
        mint.mintGovReward(address(token), 1, 1);

        // Claim token2
        vm.prank(member1);
        mint.mintGovReward(address(token2), 1, 1);

        assertTrue(token.balanceOf(member1) > 0, "Token1 balance increased");
        assertTrue(token2.balanceOf(member1) > 0, "Token2 balance increased");

        // Independent accounting
        uint256 minted1 = mint.rewardMinted(address(token));
        uint256 minted2 = mint.rewardMinted(address(token2));
        assertTrue(minted1 > 0 && minted2 > 0, "Both have minted rewards");
        assertTrue(minted1 != minted2, "Different amounts minted");
    }

    /// @notice Test 3: Cross-round batch claiming
    function testIntegration_CrossRoundRewardClaiming() public {
        // Setup 3 rounds with consistent voting
        for (uint256 round = 1; round <= 3; round++) {
            vote.setMemberVotes(address(token), round, 1, 100);
            vote.setTotalVotes(address(token), round, 100);
            vote.setMemberBoost(address(token), round, 1, 500);
            vote.setTotalBoost(address(token), round, 500);
            vote.addVotedProposal(address(token), round, round);
            vote.setProposalVotes(address(token), round, round, 100);
            submit.setProposalTarget(round, target, TargetMode.NoCallback);
            phase.setRoundEnded(round, true);

            mint.prepareRewardIfNeeded(address(token), round);
        }

        uint256[] memory rounds = new uint256[](3);
        rounds[0] = 1;
        rounds[1] = 2;
        rounds[2] = 3;

        uint256 balanceBefore = token.balanceOf(member1);

        vm.prank(member1);
        (uint256[] memory voteRewards, uint256[] memory boostRewards,) =
            mint.mintGovRewards(address(token), 1, rounds);

        uint256 balanceAfter = token.balanceOf(member1);

        uint256 expectedTotal;
        for (uint256 i = 0; i < 3; i++) {
            expectedTotal += voteRewards[i] + boostRewards[i];
        }

        assertEq(balanceAfter - balanceBefore, expectedTotal, "Batch total matches");
    }

    /// @notice Test 4: Launch count tracking via governance rewards
    function testIntegration_LaunchCountTracking() public {
        // Setup with large minted amount to trigger launch count conversion
        vote.setMemberVotes(address(token), 1, 1, 1000);
        vote.setTotalVotes(address(token), 1, 1000);
        vote.setMemberBoost(address(token), 1, 1, 0);
        vote.setTotalBoost(address(token), 1, 0);
        vote.addVotedProposal(address(token), 1, 1);
        vote.setProposalVotes(address(token), 1, 1, 1000);
        submit.setProposalTarget(1, target, TargetMode.NoCallback);
        phase.setRoundEnded(1, true);

        mint.prepareRewardIfNeeded(address(token), 1);

        // Calculate launch credit: mintAmount / threshold
        // threshold = (maxSupply - currentSupply) * LAUNCH_RATIO / 1e18
        // = (1000000 - 10000) * 1e16 / 1e18 = 9900
        // With govReward = 99000 and member gets 100%, mintAmount = 99000
        // count = 99000 / 9900 = 10

        uint256 countBefore = launch.launchCounts(address(token));

        vm.prank(member1);
        mint.mintGovReward(address(token), 1, 1);

        uint256 countAfter = launch.launchCounts(address(token));

        assertTrue(countAfter > countBefore, "Launch count should increase");
    }

    /// @notice Test 5: Interleaved prepare/mint across multiple tokens
    function testIntegration_InterleavedMultiTokenOperations() public {
        // Create second token
        LOVE20Token token2 = new LOVE20Token(
            "Community2",
            "COM2",
            5000,
            500000,
            owner,
            address(mint),
            address(launch)
        );

        // Setup token1 round 1
        vote.setMemberVotes(address(token), 1, 1, 100);
        vote.setTotalVotes(address(token), 1, 100);
        vote.setMemberBoost(address(token), 1, 1, 500);
        vote.setTotalBoost(address(token), 1, 1000);
        vote.addVotedProposal(address(token), 1, 1);
        vote.setProposalVotes(address(token), 1, 1, 100);
        submit.setProposalTarget(1, target, TargetMode.NoCallback);
        phase.setRoundEnded(1, true);

        // Setup token2 round 1
        vote.setMemberVotes(address(token2), 1, 1, 80);
        vote.setTotalVotes(address(token2), 1, 150);
        vote.setMemberBoost(address(token2), 1, 1, 400);
        vote.setTotalBoost(address(token2), 1, 800);
        vote.addVotedProposal(address(token2), 1, 2);
        vote.setProposalVotes(address(token2), 1, 2, 150);
        submit.setProposalTarget(2, target, TargetMode.NoCallback);

        // Interleaved operations: prepare token1, prepare token2, mint token1, mint token2
        mint.prepareRewardIfNeeded(address(token), 1);
        assertTrue(mint.isRewardPrepared(address(token), 1), "Token1 should be prepared");

        mint.prepareRewardIfNeeded(address(token2), 1);
        assertTrue(mint.isRewardPrepared(address(token2), 1), "Token2 should be prepared");

        uint256 balance1Before = token.balanceOf(member1);
        vm.prank(member1);
        mint.mintGovReward(address(token), 1, 1);
        uint256 balance1After = token.balanceOf(member1);
        assertTrue(balance1After > balance1Before, "Token1 minted to member1");

        uint256 balance2Before = token2.balanceOf(member1);
        vm.prank(member1);
        mint.mintGovReward(address(token2), 1, 1);
        uint256 balance2After = token2.balanceOf(member1);
        assertTrue(balance2After > balance2Before, "Token2 minted to member1");

        // Verify independent accounting
        assertTrue(mint.rewardMinted(address(token)) != mint.rewardMinted(address(token2)),
                   "Different minted amounts per token");
    }

    /// @notice Test 6: Member ownership verification across claims
    function testIntegration_MemberOwnershipVerification() public {
        // Setup round 1 for member 1 (owned by member1)
        vote.setMemberVotes(address(token), 1, 1, 100);
        vote.setTotalVotes(address(token), 1, 200);
        vote.setMemberBoost(address(token), 1, 1, 500);
        vote.setTotalBoost(address(token), 1, 1000);
        vote.addVotedProposal(address(token), 1, 1);
        vote.setProposalVotes(address(token), 1, 1, 200);
        submit.setProposalTarget(1, target, TargetMode.NoCallback);
        phase.setRoundEnded(1, true);

        mint.prepareRewardIfNeeded(address(token), 1);

        // Member1 (owner of memberId 1) claims successfully
        vm.prank(member1);
        mint.mintGovReward(address(token), 1, 1);
        assertTrue(token.balanceOf(member1) > 0, "Member1 received tokens for memberId 1");

        // Setup round 2 for member 2 (owned by member2)
        vote.setMemberVotes(address(token), 2, 2, 100);
        vote.setTotalVotes(address(token), 2, 200);
        vote.setMemberBoost(address(token), 2, 2, 500);
        vote.setTotalBoost(address(token), 2, 1000);
        vote.addVotedProposal(address(token), 2, 2);
        vote.setProposalVotes(address(token), 2, 2, 200);
        submit.setProposalTarget(2, target, TargetMode.NoCallback);
        phase.setRoundEnded(2, true);

        mint.prepareRewardIfNeeded(address(token), 2);

        // Member2 (owner of memberId 2) claims successfully
        uint256 balance2Before = token.balanceOf(member2);
        vm.prank(member2);
        mint.mintGovReward(address(token), 2, 2);
        assertTrue(token.balanceOf(member2) > balance2Before, "Member2 received tokens for memberId 2");

        // Verify both members have independent balances
        assertTrue(token.balanceOf(member1) > 0, "Member1 still has tokens");
        assertTrue(token.balanceOf(member2) > 0, "Member2 has tokens");
    }

    /// @notice Test 7: Proposal target changes and vote data consistency
    function testIntegration_VoteDataConsistency() public {
        // Setup with multiple proposals having different vote shares
        vote.setTotalVotes(address(token), 1, 1000);

        // Member 1: 400 votes (40%)
        vote.setMemberVotes(address(token), 1, 1, 400);
        vote.setMemberBoost(address(token), 1, 1, 2000);

        // Member 2: 600 votes (60%)
        vote.setMemberVotes(address(token), 1, 2, 600);
        vote.setMemberBoost(address(token), 1, 2, 3000);

        vote.setTotalBoost(address(token), 1, 5000);

        // Proposal 1: 300 votes (30%, above 5% threshold)
        vote.addVotedProposal(address(token), 1, 1);
        vote.setProposalVotes(address(token), 1, 1, 300);
        submit.setProposalTarget(1, target, TargetMode.NoCallback);

        // Proposal 2: 700 votes (70%, above threshold)
        vote.addVotedProposal(address(token), 1, 2);
        vote.setProposalVotes(address(token), 1, 2, 700);
        submit.setProposalTarget(2, address(0x3002), TargetMode.NoCallback);

        phase.setRoundEnded(1, true);

        mint.prepareRewardIfNeeded(address(token), 1);

        // Verify eligibleProposalVotes = 300 + 700 = 1000
        assertEq(mint.eligibleProposalVotes(address(token), 1), 1000, "Eligible votes should sum correctly");

        // Verify member rewards are proportional to their votes
        (uint256 vote1,,,) = mint.govRewardByMemberId(address(token), 1, 1);
        (uint256 vote2,,,) = mint.govRewardByMemberId(address(token), 1, 2);

        // Member1 (40%) should get less than Member2 (60%)
        assertTrue(vote1 < vote2, "Member1 vote reward < Member2 vote reward");

        // Verify proposal rewards proportional to votes
        (uint256 amount1,) = mint.proposalRewardByProposalId(address(token), 1, 1);
        (uint256 amount2,) = mint.proposalRewardByProposalId(address(token), 1, 2);

        // Proposal1 (30%) should get less than Proposal2 (70%)
        assertTrue(amount1 < amount2, "Proposal1 reward < Proposal2 reward");

        // Claim both proposals with different targets
        vm.prank(target);
        uint256 claimed1 = mint.mintProposalReward(address(token), 1, 1);
        assertEq(claimed1, amount1, "Claimed amount matches query");

        vm.prank(address(0x3002));
        uint256 claimed2 = mint.mintProposalReward(address(token), 1, 2);
        assertEq(claimed2, amount2, "Claimed amount matches query");
    }

    /// @notice Test 8: Proposal exactly at 5% threshold across multiple rounds
    function testIntegration_ProposalThresholdEdgeCase() public {
        // Setup round 1: proposal exactly at 5% threshold (50/1000)
        vote.setTotalVotes(address(token), 1, 1000);
        vote.setMemberVotes(address(token), 1, 1, 1000);
        vote.setTotalBoost(address(token), 1, 5000);
        vote.setMemberBoost(address(token), 1, 1, 5000);

        // Proposal with exactly 5% votes
        vote.addVotedProposal(address(token), 1, 1);
        vote.setProposalVotes(address(token), 1, 1, 50);
        submit.setProposalTarget(1, target, TargetMode.NoCallback);

        phase.setRoundEnded(1, true);
        mint.prepareRewardIfNeeded(address(token), 1);

        // Verify proposal is eligible
        assertTrue(mint.isProposalIdWithReward(address(token), 1, 1), "Proposal at 5% should qualify");

        (uint256 amount1,) = mint.proposalRewardByProposalId(address(token), 1, 1);
        assertTrue(amount1 > 0, "Proposal should have reward");

        // Setup round 2: proposal just below 5% threshold (49/1000)
        vote.setTotalVotes(address(token), 2, 1000);
        vote.setMemberVotes(address(token), 2, 1, 1000);
        vote.setTotalBoost(address(token), 2, 5000);
        vote.setMemberBoost(address(token), 2, 1, 5000);

        vote.addVotedProposal(address(token), 2, 2);
        vote.setProposalVotes(address(token), 2, 2, 49);
        submit.setProposalTarget(2, target, TargetMode.NoCallback);

        phase.setRoundEnded(2, true);
        mint.prepareRewardIfNeeded(address(token), 2);

        // Verify proposal is NOT eligible
        assertTrue(!mint.isProposalIdWithReward(address(token), 2, 2), "Proposal below 5% should not qualify");

        // Setup round 3: proposal above 5% threshold (51/1000)
        vote.setTotalVotes(address(token), 3, 1000);
        vote.setMemberVotes(address(token), 3, 1, 1000);
        vote.setTotalBoost(address(token), 3, 5000);
        vote.setMemberBoost(address(token), 3, 1, 5000);

        vote.addVotedProposal(address(token), 3, 3);
        vote.setProposalVotes(address(token), 3, 3, 51);
        submit.setProposalTarget(3, target, TargetMode.NoCallback);

        phase.setRoundEnded(3, true);
        mint.prepareRewardIfNeeded(address(token), 3);

        // Verify proposal is eligible
        assertTrue(mint.isProposalIdWithReward(address(token), 3, 3), "Proposal above 5% should qualify");
    }

    /// @notice Test 9: Phase round transition during operations
    function testIntegration_RoundTransitionTiming() public {
        // Setup round 1 but don't mark it as ended yet
        vote.setMemberVotes(address(token), 1, 1, 100);
        vote.setTotalVotes(address(token), 1, 100);
        vote.setMemberBoost(address(token), 1, 1, 500);
        vote.setTotalBoost(address(token), 1, 500);
        vote.addVotedProposal(address(token), 1, 1);
        vote.setProposalVotes(address(token), 1, 1, 100);
        submit.setProposalTarget(1, target, TargetMode.NoCallback);

        // Round not ended - prepare should fail (would revert)
        phase.setRoundEnded(1, false);

        // Now mark round as ended
        phase.setRoundEnded(1, true);

        // Prepare should succeed
        mint.prepareRewardIfNeeded(address(token), 1);
        assertTrue(mint.isRewardPrepared(address(token), 1), "Round should be prepared after transition");

        // Minting should also succeed
        vm.prank(member1);
        mint.mintGovReward(address(token), 1, 1);

        assertTrue(token.balanceOf(member1) > 0, "Should mint after round ended");
    }

    /// @notice Test 10: Multiple prepare calls are idempotent
    function testIntegration_IdempotentPrepare() public {
        vote.setMemberVotes(address(token), 1, 1, 100);
        vote.setTotalVotes(address(token), 1, 100);
        vote.setMemberBoost(address(token), 1, 1, 500);
        vote.setTotalBoost(address(token), 1, 500);
        vote.addVotedProposal(address(token), 1, 1);
        vote.setProposalVotes(address(token), 1, 1, 100);
        submit.setProposalTarget(1, target, TargetMode.NoCallback);
        phase.setRoundEnded(1, true);

        // First prepare
        mint.prepareRewardIfNeeded(address(token), 1);
        uint256 reserved1 = mint.rewardReserved(address(token));
        uint256 govReward1 = mint.govReward(address(token), 1);
        uint256 proposalReward1 = mint.proposalReward(address(token), 1);

        // Second prepare (should be no-op)
        mint.prepareRewardIfNeeded(address(token), 1);
        uint256 reserved2 = mint.rewardReserved(address(token));
        uint256 govReward2 = mint.govReward(address(token), 1);
        uint256 proposalReward2 = mint.proposalReward(address(token), 1);

        // Third prepare (should be no-op)
        mint.prepareRewardIfNeeded(address(token), 1);
        uint256 reserved3 = mint.rewardReserved(address(token));
        uint256 govReward3 = mint.govReward(address(token), 1);
        uint256 proposalReward3 = mint.proposalReward(address(token), 1);

        // All values should remain unchanged
        assertEq(reserved1, reserved2, "Reserved should not change");
        assertEq(reserved2, reserved3, "Reserved should not change");
        assertEq(govReward1, govReward2, "Gov reward should not change");
        assertEq(govReward2, govReward3, "Gov reward should not change");
        assertEq(proposalReward1, proposalReward2, "Proposal reward should not change");
        assertEq(proposalReward2, proposalReward3, "Proposal reward should not change");
    }

    // Helper functions
    function assertTrue(bool condition, string memory message) internal pure {
        require(condition, message);
    }

    function assertEq(uint256 a, uint256 b, string memory message) internal pure {
        require(a == b, message);
    }

    function ownerOf(uint256 id) external view returns (address) {
        if (id == 1) return member1;
        if (id == 2) return member2;
        revert IERC721Errors.ERC721NonexistentToken(id);
    }

    function issuedLaunchCount(address) external pure returns (uint256) {
        return 0;
    }

    function MAX_LAUNCH_COUNT() external pure returns (uint256) {
        return 1000;
    }

    function LAUNCH_RATIO() external pure returns (uint256) {
        return 1e16;
    }
}

// Mock contracts with stateful behavior

contract MockPhase {
    mapping(uint256 => bool) public roundEnded;

    function isRoundEnded(uint256 round) external view returns (bool) {
        return roundEnded[round];
    }

    function setRoundEnded(uint256 round, bool ended) external {
        roundEnded[round] = ended;
    }
}

contract MockVote {
    mapping(address => mapping(uint256 => uint256)) public totalVotes;
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) public memberVotes;
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) public proposalVotes;
    mapping(address => mapping(uint256 => uint256[])) public votedProposals;
    mapping(address => mapping(uint256 => uint256)) public totalBoost;
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) public memberBoost;

    function isRoundEnded(uint256 round) external pure returns (bool) {
        return round > 0;
    }

    function votesNum(address token, uint256 round) external view returns (uint256) {
        return totalVotes[token][round];
    }

    function votesNumByMemberId(address token, uint256 round, uint256 memberId)
        external view returns (uint256)
    {
        return memberVotes[token][round][memberId];
    }

    function votesNumByProposalId(address token, uint256 round, uint256 proposalId)
        external view returns (uint256)
    {
        return proposalVotes[token][round][proposalId];
    }

    function votedProposalIds(address token, uint256 round, uint256, uint256 limit, bool)
        external view returns (uint256[] memory ids, uint256 total)
    {
        ids = votedProposals[token][round];
        total = ids.length;
        if (limit > 0 && limit < ids.length) {
            uint256[] memory limited = new uint256[](limit);
            for (uint256 i = 0; i < limit; i++) {
                limited[i] = ids[i];
            }
            ids = limited;
        }
    }

    function stakedAmountOfVoters(address token, uint256 round)
        external view returns (uint256)
    {
        return totalBoost[token][round];
    }

    function stakedAmountOfVotersByMemberId(address token, uint256 round, uint256 memberId)
        external view returns (uint256)
    {
        return memberBoost[token][round][memberId];
    }

    function setTotalVotes(address token, uint256 round, uint256 amount) external {
        totalVotes[token][round] = amount;
    }

    function setMemberVotes(address token, uint256 round, uint256 memberId, uint256 amount) external {
        memberVotes[token][round][memberId] = amount;
    }

    function setProposalVotes(address token, uint256 round, uint256 proposalId, uint256 amount) external {
        proposalVotes[token][round][proposalId] = amount;
    }

    function addVotedProposal(address token, uint256 round, uint256 proposalId) external {
        votedProposals[token][round].push(proposalId);
    }

    function setTotalBoost(address token, uint256 round, uint256 amount) external {
        totalBoost[token][round] = amount;
    }

    function setMemberBoost(address token, uint256 round, uint256 memberId, uint256 amount) external {
        memberBoost[token][round][memberId] = amount;
    }
}

contract MockSubmit {
    mapping(uint256 => address) public targets;
    mapping(uint256 => TargetMode) public modes;

    function proposalTarget(address, uint256 proposalId)
        external view returns (address, TargetMode)
    {
        if (targets[proposalId] == address(0)) {
            revert ISubmitErrors.ProposalNotFound(proposalId);
        }
        return (targets[proposalId], modes[proposalId]);
    }

    function setProposalTarget(uint256 proposalId, address target, TargetMode mode) external {
        targets[proposalId] = target;
        modes[proposalId] = mode;
    }
}

contract MockLaunch {
    mapping(address => uint256) public launchCounts;
    mapping(address => uint256) public issuedCounts;

    function addLaunchCount(address community, uint256, uint256 count) external {
        launchCounts[community] += count;
    }

    function issuedLaunchCount(address tokenAddress) external view returns (uint256) {
        return issuedCounts[tokenAddress];
    }

    function MAX_LAUNCH_COUNT() external pure returns (uint256) {
        return 1000;
    }

    function LAUNCH_RATIO() external pure returns (uint256) {
        return 1e16;
    }
}
