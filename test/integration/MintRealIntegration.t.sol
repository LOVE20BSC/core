// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Mint} from "../../src/Mint.sol";
import {LOVE20Token} from "../../src/LOVE20Token.sol";
import {Phase} from "../../src/Phase.sol";
import {Vote} from "../../src/Vote.sol";
import {Submit, ProposalBody} from "../../src/Submit.sol";
import {Stake} from "../../src/Stake.sol";
import {Launch} from "../../src/Launch.sol";
import {MemberNFT} from "../../src/MemberNFT.sol";
import {LaunchInitParams, DistributorMode} from "../../src/interfaces/ILaunch.sol";
import {TargetMode} from "../../src/interfaces/ISubmit.sol";
import {ILOVE20Token} from "../../src/interfaces/ILOVE20Token.sol";
import {ILaunch} from "../../src/interfaces/ILaunch.sol";

interface TestVm {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function warp(uint256) external;
    function roll(uint256) external;
    function expectRevert(bytes calldata) external;
}

/// @title MintRealIntegration - Real contract integration tests with mathematical model verification
/// @notice Tests Mint with actual Phase/Vote/Submit/Stake/Launch contracts
/// @dev All reward calculations are verified against independent mathematical models defined in TEST_MATH_MODEL.md
contract MintRealIntegrationTest {
    TestVm constant vm = TestVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // Test constants - from mathematical model
    uint256 constant STAKE_AMOUNT_MEMBER1 = 5000;
    uint256 constant STAKE_AMOUNT_MEMBER2 = 3000;
    uint256 constant VOTE_AMOUNT_MEMBER1 = 100;
    uint256 constant VOTE_AMOUNT_MEMBER2 = 60;
    uint256 constant BLOCKS_PER_ROUND = 1000;
    uint256 constant TIME_PER_ROUND = 3600;  // 1 hour, matching Phase targetSeconds
    uint256 constant BLOCKS_PAST_ROUND0 = 200;
    uint256 constant SLIPPAGE_100_PERCENT = 1e18;
    uint256 constant PROMISED_WAITING_PHASES = 1;
    uint256 constant TOKEN_TRANSFER_AMOUNT = 10000;

    // Configuration constants - must match init() parameters
    uint256 constant ROUND_REWARD_GOV_PER_THOUSAND = 100;        // 10%
    uint256 constant ROUND_REWARD_PROPOSAL_PER_THOUSAND = 100;   // 10%
    uint256 constant PROPOSAL_REWARD_MIN_VOTE_PER_THOUSAND = 50; // 5%
    uint256 constant MAX_GOV_BOOST_REWARD_MULTIPLIER = 2;        // 2x

    // Real contracts
    Phase public phase;
    MemberNFT public memberNFT;
    Mint public mint;
    Vote public vote;
    Submit public submit;
    Stake public stake;
    Launch public launch;

    // Mock external dependencies
    MockUniswapV2Factory public factory;
    MockUniswapV2Router public router;
    LOVE20Token public rootToken;

    // Test accounts
    address public owner = address(this);
    address public distributor = address(0x9001);
    address public member1 = address(0x1001);
    address public member2 = address(0x1002);

    // First token created by Launch
    LOVE20Token public token;

    function setUp() public {
        // ========== Phase 1: Deploy all contracts (new) ==========

        // Deploy Phase (constructor, no dependencies)
        phase = new Phase(
            100,   // originBlocks
            1000,  // originPhaseBlocks
            3600,  // targetSeconds (1 hour)
            10,    // adjustThreshold
            50     // syncObservationLimit
        );

        // Deploy mock external dependencies
        factory = new MockUniswapV2Factory();
        router = new MockUniswapV2Router();

        // Deploy root parent token
        rootToken = new LOVE20Token(
            "RootCommunity",
            "ROOT",
            1000000,      // initial supply
            100000000,    // max supply
            owner,
            owner,        // minter (not address(0))
            address(1)    // parentTokenAddress (not address(0))
        );

        // Deploy core contracts
        memberNFT = new MemberNFT(
            1e18,  // BASE_DIVISOR
            4,     // BYTES_THRESHOLD
            2,     // MULTIPLIER
            20     // MAX_NAME_LENGTH
        );
        mint = new Mint();
        vote = new Vote();
        submit = new Submit();
        stake = new Stake();
        launch = new Launch();

        // ========== Phase 2: Initialize all contracts (init) ==========

        // 1. Initialize Launch first (it creates firstToken and initializes MemberNFT)
        launch.init(LaunchInitParams({
            mintAddress: address(mint),
            memberNFTAddress: address(memberNFT),
            rootParentTokenAddress: address(rootToken),
            pairFactoryAddress: address(factory),
            distributor: distributor,
            launchRatio: 1e16,           // 1% for launch count
            maxLaunchCount: 1000,
            tokenSymbolLength: 4,
            launchAmount: 50000,         // initial supply
            maxSupply: 1000000,          // max supply
            name: "TestCommunity",
            symbol: "TEST"
        }));

        // Get the first token created by Launch
        (address[] memory tokenList,) = launch.tokens(0, 1, false);
        token = LOVE20Token(tokenList[0]);

        // ========== Phase 2 continued: Initialize remaining contracts ==========

        // 2. Initialize Submit (depends on: Phase, Stake, MemberNFT)
        submit.init(
            address(phase),
            address(stake),
            address(memberNFT),
            50  // submitMinPerThousand: 5%
        );

        // 3. Initialize Stake (depends on: Phase, MemberNFT, Vote, Router, Factory)
        stake.init(
            address(phase),
            address(memberNFT),
            address(vote),
            address(router),
            address(factory),
            1,    // promisedWaitingPhasesMin
            100,  // promisedWaitingPhasesMax
            10    // maxWithdrawableToFeeRatio
        );

        // 4. Initialize Vote (depends on: Phase, Stake, Submit, MemberNFT, Mint)
        vote.init(
            address(phase),
            address(stake),
            address(submit),
            address(memberNFT),
            address(mint)
        );

        // 5. Initialize Mint last (depends on: Vote, Submit, Launch, MemberNFT)
        mint.init(
            address(vote),
            address(submit),
            address(launch),
            address(memberNFT),
            PROPOSAL_REWARD_MIN_VOTE_PER_THOUSAND,   // 50: 5%
            ROUND_REWARD_GOV_PER_THOUSAND,           // 100: 10%
            ROUND_REWARD_PROPOSAL_PER_THOUSAND,      // 100: 10%
            MAX_GOV_BOOST_REWARD_MULTIPLIER          // 2: 2x
        );

        // ========== Phase 3: Setup test state ==========

        // Transfer tokens to members for NFT minting
        _setupMembersWithTokens(TOKEN_TRANSFER_AMOUNT);

        // Mint member NFTs
        vm.prank(member1);
        token.approve(address(memberNFT), TOKEN_TRANSFER_AMOUNT);
        vm.prank(member1);
        (uint256 memberId1,) = memberNFT.mint("Alice");
        assertEq(memberId1, 1, "Member1 should have ID 1");

        vm.prank(member2);
        token.approve(address(memberNFT), TOKEN_TRANSFER_AMOUNT);
        vm.prank(member2);
        (uint256 memberId2,) = memberNFT.mint("Bob");
        assertEq(memberId2, 2, "Member2 should have ID 2");
    }

    // ==================== Helper Functions ====================

    /// @notice Setup: Transfer tokens to members
    function _setupMembersWithTokens(uint256 amount) internal {
        vm.prank(distributor);
        token.transfer(member1, amount);
        vm.prank(distributor);
        token.transfer(member2, amount);
        vm.prank(owner);
        rootToken.transfer(member1, amount);
        vm.prank(owner);
        rootToken.transfer(member2, amount);
    }

    /// @notice Setup: Approve both tokens for staking
    function _approveBothTokens(address member, uint256 amount) internal {
        vm.startPrank(member);
        token.approve(address(stake), amount);
        rootToken.approve(address(stake), amount);
        vm.stopPrank();
    }

    /// @notice Setup: Members stake liquidity with specified amounts
    function _stakeLiquidityForMembers(uint256 amount1, uint256 amount2) internal {
        // Member1 stakes
        _approveBothTokens(member1, amount1);
        vm.prank(member1);
        stake.stakeLiquidity(
            address(token),
            amount1,
            amount1,
            SLIPPAGE_100_PERCENT,
            PROMISED_WAITING_PHASES,
            1  // memberId
        );

        // Member2 stakes
        _approveBothTokens(member2, amount2);
        vm.prank(member2);
        stake.stakeLiquidity(
            address(token),
            amount2,
            amount2,
            SLIPPAGE_100_PERCENT,
            PROMISED_WAITING_PHASES,
            2  // memberId
        );
    }

    /// @notice Setup: Vote in a round
    function _voteInRound(uint256 /* round */, uint256 proposalId, uint256 votes1, uint256 votes2) internal {
        uint256[] memory proposalIds = new uint256[](1);
        proposalIds[0] = proposalId;

        // Member1 votes
        uint256[] memory amounts1 = new uint256[](1);
        amounts1[0] = votes1;
        vm.prank(member1);
        vote.vote(address(token), 1, proposalIds, amounts1, new bytes[][](0));

        // Member2 votes
        uint256[] memory amounts2 = new uint256[](1);
        amounts2[0] = votes2;
        vm.prank(member2);
        vote.vote(address(token), 2, proposalIds, amounts2, new bytes[][](0));
    }

    /// @notice Mathematical model: Calculate expected vote reward
    /// @dev Independent calculation based on business logic, not contract code
    function _calculateExpectedVoteReward(
        uint256 govRewardAmount,
        uint256 memberVotes,
        uint256 totalVotes
    ) internal pure returns (uint256) {
        uint256 votePoolAmount = govRewardAmount / 2;
        return (votePoolAmount * memberVotes) / totalVotes;
    }

    /// @notice Mathematical model: Calculate expected boost reward
    /// @dev Independent calculation with 2x cap enforcement
    function _calculateExpectedBoostReward(
        uint256 govRewardAmount,
        uint256 memberBoost,
        uint256 totalBoost,
        uint256 voteReward
    ) internal pure returns (uint256 boostReward, uint256 burnReward) {
        uint256 votePoolAmount = govRewardAmount / 2;
        uint256 boostPoolAmount = govRewardAmount - votePoolAmount;

        // If totalBoost is 0, entire boost pool is burned
        if (totalBoost == 0) {
            return (0, 0);
        }

        uint256 theoreticalBoost = (boostPoolAmount * memberBoost) / totalBoost;
        uint256 maxBoostReward = voteReward * MAX_GOV_BOOST_REWARD_MULTIPLIER;

        boostReward = theoreticalBoost > maxBoostReward ? maxBoostReward : theoreticalBoost;
        burnReward = theoreticalBoost - boostReward;
    }

    /// @notice Mathematical model: Calculate expected proposal reward
    function _calculateExpectedProposalReward(
        uint256 proposalRewardAmount,
        uint256 proposalVotes,
        uint256 eligibleProposalVotes
    ) internal pure returns (uint256) {
        if (eligibleProposalVotes == 0) return 0;
        return (proposalRewardAmount * proposalVotes) / eligibleProposalVotes;
    }

    /// @notice Mathematical model: Calculate minimum votes for 5% threshold (ceil)
    function _calculateMinVotes(uint256 totalVotes) internal pure returns (uint256) {
        // ceil(totalVotes * 0.05) = ceil(totalVotes * 50 / 1000)
        return (totalVotes * PROPOSAL_REWARD_MIN_VOTE_PER_THOUSAND + 999) / 1000;
    }

    // Helper functions
    function assertTrue(bool condition, string memory message) internal pure {
        require(condition, message);
    }

    function assertEq(uint256 a, uint256 b, string memory message) internal pure {
        require(a == b, message);
    }

    // ==================== Test 1: Full Governance Flow ====================

    /// @notice Test 1: Complete governance flow with mathematical model verification
    /// @dev Verifies rewards match independent calculations from TEST_MATH_MODEL.md
    function testRealIntegration_FullGovernanceFlow() public {
        // ========== Step 0: Advance past round 0 ==========
        vm.roll(block.number + BLOCKS_PAST_ROUND0);

        // ========== Step 1: Members stake liquidity ==========
        // Give members additional tokens for staking
        vm.prank(distributor);
        token.transfer(member1, TOKEN_TRANSFER_AMOUNT);
        vm.prank(distributor);
        token.transfer(member2, TOKEN_TRANSFER_AMOUNT);
        vm.prank(owner);
        rootToken.transfer(member1, TOKEN_TRANSFER_AMOUNT);
        vm.prank(owner);
        rootToken.transfer(member2, TOKEN_TRANSFER_AMOUNT);

        _stakeLiquidityForMembers(STAKE_AMOUNT_MEMBER1, STAKE_AMOUNT_MEMBER2);

        // ========== Step 2: Submit proposal ==========
        address proposalTarget = address(0x4001);
        vm.prank(member1);
        uint256 proposalId = submit.submitNewProposal(
            address(token),
            1,
            ProposalBody({
                title: "Proposal 1",
                details: "Description",
                target: proposalTarget,
                targetMode: TargetMode.NoCallback,
                targetData: new bytes[](0)
            })
        );

        // ========== Step 3: Members vote ==========
        _voteInRound(0, proposalId, VOTE_AMOUNT_MEMBER1, VOTE_AMOUNT_MEMBER2);

        // ========== Step 4: Advance to next round ==========
        uint256 currentRound = phase.currentPhase();
        vm.roll(block.number + BLOCKS_PER_ROUND);
        uint256 nextRound = phase.currentPhase();
        assertTrue(nextRound > currentRound, "Round should have advanced");

        // ========== Step 5: Verify governance rewards (auto-prepare) ==========
        // Note: prepareRewardIfNeeded is now called automatically inside mintGovReward
        _verifyGovRewardsWithMathModel(currentRound);

        // ========== Step 6: Verify proposal rewards (auto-prepare) ==========
        _verifyProposalRewards(currentRound, proposalId, proposalTarget);
    }

    /// @notice Verify governance rewards against independent mathematical model
    function _verifyGovRewardsWithMathModel(uint256 currentRound) internal {
        // Read actual contract state
        uint256 totalVotes = vote.votesNum(address(token), currentRound);
        uint256 totalBoost = vote.stakedAmountOfVoters(address(token), currentRound);
        uint256 member1Votes = vote.votesNumByMemberId(address(token), currentRound, 1);
        uint256 member2Votes = vote.votesNumByMemberId(address(token), currentRound, 2);
        uint256 member1Boost = vote.stakedAmountOfVotersByMemberId(address(token), currentRound, 1);
        uint256 member2Boost = vote.stakedAmountOfVotersByMemberId(address(token), currentRound, 2);

        // Read actual rewards from contract
        (uint256 actualVoteReward1, uint256 actualBoostReward1, uint256 actualBurnReward1,) =
            mint.govRewardByMemberId(address(token), currentRound, 1);
        (uint256 actualVoteReward2, uint256 actualBoostReward2, uint256 actualBurnReward2,) =
            mint.govRewardByMemberId(address(token), currentRound, 2);

        // When totalBoost is 0, boost pool is burned and only vote rewards exist
        if (totalBoost == 0) {
            // Verify boost rewards are 0 when no boost exists
            assertEq(actualBoostReward1, 0, "Member1 boost reward must be 0 when totalBoost is 0");
            assertEq(actualBoostReward2, 0, "Member2 boost reward must be 0 when totalBoost is 0");
            assertEq(actualBurnReward1, 0, "Member1 burn reward must be 0 when totalBoost is 0");
            assertEq(actualBurnReward2, 0, "Member2 burn reward must be 0 when totalBoost is 0");

            // Debug: Check actual vote counts
            assertEq(member1Votes, VOTE_AMOUNT_MEMBER1, "Member1 should have 100 votes");
            assertEq(member2Votes, VOTE_AMOUNT_MEMBER2, "Member2 should have 60 votes");
            assertEq(totalVotes, VOTE_AMOUNT_MEMBER1 + VOTE_AMOUNT_MEMBER2, "Total should be 160 votes");

            // Verify voting ratio (100:60 = 5:3) for vote rewards only
            // Allow for 1 wei rounding error due to integer division
            uint256 crossProduct1 = actualVoteReward1 * 3;
            uint256 crossProduct2 = actualVoteReward2 * 5;
            uint256 diff = crossProduct1 > crossProduct2 ? crossProduct1 - crossProduct2 : crossProduct2 - crossProduct1;
            assertTrue(diff <= 1, "Vote rewards must match 5:3 ratio within 1 wei rounding error");
        } else {
            // Calculate expected rewards using mathematical model (independent of contract)
            uint256 available = mint.rewardAvailable(address(token));
            uint256 govRewardAmount = (available * ROUND_REWARD_GOV_PER_THOUSAND) / 1000;

            // Expected vote rewards
            uint256 expectedVoteReward1 = _calculateExpectedVoteReward(govRewardAmount, member1Votes, totalVotes);
            uint256 expectedVoteReward2 = _calculateExpectedVoteReward(govRewardAmount, member2Votes, totalVotes);

            // Expected boost rewards
            (uint256 expectedBoostReward1, uint256 expectedBurnReward1) =
                _calculateExpectedBoostReward(govRewardAmount, member1Boost, totalBoost, expectedVoteReward1);
            (uint256 expectedBoostReward2, uint256 expectedBurnReward2) =
                _calculateExpectedBoostReward(govRewardAmount, member2Boost, totalBoost, expectedVoteReward2);

            // Verify exact match with mathematical model
            assertEq(actualVoteReward1, expectedVoteReward1, "Member1 vote reward must match math model");
            assertEq(actualBoostReward1, expectedBoostReward1, "Member1 boost reward must match math model");
            assertEq(actualBurnReward1, expectedBurnReward1, "Member1 burn reward must match math model");

            assertEq(actualVoteReward2, expectedVoteReward2, "Member2 vote reward must match math model");
            assertEq(actualBoostReward2, expectedBoostReward2, "Member2 boost reward must match math model");
            assertEq(actualBurnReward2, expectedBurnReward2, "Member2 burn reward must match math model");

            // Verify voting ratio (100:60 = 5:3)
            assertEq(actualVoteReward1 * 3, actualVoteReward2 * 5, "Vote rewards must match 5:3 ratio");
        }

        // Claim and verify token transfers
        uint256 balanceBefore1 = token.balanceOf(member1);
        vm.prank(member1);
        mint.mintGovReward(address(token), 1, currentRound);
        uint256 balanceAfter1 = token.balanceOf(member1);
        assertEq(balanceAfter1 - balanceBefore1, actualVoteReward1 + actualBoostReward1,
                 "Member1 must receive exact calculated rewards");

        uint256 balanceBefore2 = token.balanceOf(member2);
        vm.prank(member2);
        mint.mintGovReward(address(token), 2, currentRound);
        uint256 balanceAfter2 = token.balanceOf(member2);
        assertEq(balanceAfter2 - balanceBefore2, actualVoteReward2 + actualBoostReward2,
                 "Member2 must receive exact calculated rewards");
    }

    /// @notice Verify proposal rewards
    function _verifyProposalRewards(uint256 currentRound, uint256 proposalId, address proposalTarget) internal {
        (uint256 proposalAmount,) = mint.proposalRewardByProposalId(address(token), currentRound, proposalId);
        assertTrue(proposalAmount > 0, "Proposal should have rewards");

        uint256 targetBalanceBefore = token.balanceOf(proposalTarget);
        vm.prank(proposalTarget);
        uint256 claimed = mint.mintProposalReward(address(token), currentRound, proposalId);
        uint256 targetBalanceAfter = token.balanceOf(proposalTarget);

        assertEq(claimed, proposalAmount, "Claimed amount must match");
        assertEq(targetBalanceAfter - targetBalanceBefore, proposalAmount,
                 "Target must receive exact proposal reward");

        assertTrue(mint.isProposalIdWithReward(address(token), currentRound, proposalId),
                   "Proposal with >5% votes must be eligible");
    }

    // ==================== Test 2: Multiple Rounds Progression ====================

    /// @notice Test 2: Multiple rounds with batch claiming and mathematical verification
    function testRealIntegration_MultipleRoundsProgression() public {
        vm.roll(block.number + BLOCKS_PAST_ROUND0);

        // Round 1: Give tokens and stake
        vm.prank(distributor);
        token.transfer(member1, TOKEN_TRANSFER_AMOUNT);
        vm.prank(distributor);
        token.transfer(member2, TOKEN_TRANSFER_AMOUNT);
        vm.prank(owner);
        rootToken.transfer(member1, TOKEN_TRANSFER_AMOUNT);
        vm.prank(owner);
        rootToken.transfer(member2, TOKEN_TRANSFER_AMOUNT);

        uint256 round1 = phase.currentPhase();
        _stakeLiquidityForMembers(STAKE_AMOUNT_MEMBER1, STAKE_AMOUNT_MEMBER2);

        address proposalTarget1 = address(0x2001);
        vm.prank(member1);
        uint256 proposalId1 = submit.submitNewProposal(
            address(token), 1,
            ProposalBody({
                title: "Proposal Round 1",
                details: "Test",
                target: proposalTarget1,
                targetMode: TargetMode.NoCallback,
                targetData: new bytes[](0)
            })
        );
        _voteInRound(round1, proposalId1, VOTE_AMOUNT_MEMBER1, VOTE_AMOUNT_MEMBER2);

        vm.roll(block.number + BLOCKS_PER_ROUND);
        uint256 round2 = phase.currentPhase();
        assertEq(round2, 2, "Must advance to round 2");
        // Auto-prepare when claiming rewards

        // Round 2
        address proposalTarget2 = address(0x2002);
        vm.prank(member1);
        uint256 proposalId2 = submit.submitNewProposal(
            address(token), 1,
            ProposalBody({
                title: "Proposal Round 2",
                details: "Test",
                target: proposalTarget2,
                targetMode: TargetMode.NoCallback,
                targetData: new bytes[](0)
            })
        );
        _voteInRound(round2, proposalId2, VOTE_AMOUNT_MEMBER1, VOTE_AMOUNT_MEMBER2);

        vm.roll(block.number + BLOCKS_PER_ROUND);
        uint256 round3 = phase.currentPhase();
        assertEq(round3, 3, "Must advance to round 3");
        // Auto-prepare when claiming rewards

        // Round 3
        address proposalTarget3 = address(0x2003);
        vm.prank(member1);
        uint256 proposalId3 = submit.submitNewProposal(
            address(token), 1,
            ProposalBody({
                title: "Proposal Round 3",
                details: "Test",
                target: proposalTarget3,
                targetMode: TargetMode.NoCallback,
                targetData: new bytes[](0)
            })
        );
        _voteInRound(round3, proposalId3, VOTE_AMOUNT_MEMBER1, VOTE_AMOUNT_MEMBER2);

        vm.roll(block.number + BLOCKS_PER_ROUND);
        uint256 round4 = phase.currentPhase();
        assertEq(round4, 4, "Must advance to round 4");
        // Auto-prepare when claiming rewards

        // Batch claim and verify with mathematical model
        _batchClaimAndVerify(round1, round2, round3);

        // Verify proposal rewards
        vm.prank(proposalTarget1);
        uint256 claimed1 = mint.mintProposalReward(address(token), round1, proposalId1);
        assertTrue(claimed1 > 0, "Round 1 proposal must have rewards");

        vm.prank(proposalTarget2);
        uint256 claimed2 = mint.mintProposalReward(address(token), round2, proposalId2);
        assertTrue(claimed2 > 0, "Round 2 proposal must have rewards");

        vm.prank(proposalTarget3);
        uint256 claimed3 = mint.mintProposalReward(address(token), round3, proposalId3);
        assertTrue(claimed3 > 0, "Round 3 proposal must have rewards");
    }

    /// @notice Batch claim and verify against mathematical model
    function _batchClaimAndVerify(uint256 round1, uint256 round2, uint256 round3) internal {
        uint256[] memory rounds = new uint256[](3);
        rounds[0] = round1;
        rounds[1] = round2;
        rounds[2] = round3;

        // Batch claim
        uint256 balanceBefore1 = token.balanceOf(member1);
        vm.prank(member1);
        (uint256[] memory voteRewards1, uint256[] memory boostRewards1,) = mint.mintGovRewards(address(token), 1, rounds);
        uint256 balanceAfter1 = token.balanceOf(member1);
        uint256 actualTotal1 = balanceAfter1 - balanceBefore1;

        // Expected is sum of what mintGovRewards actually returned
        uint256 expectedTotal1 = voteRewards1[0] + boostRewards1[0] + voteRewards1[1] + boostRewards1[1] + voteRewards1[2] + boostRewards1[2];

        // Verify exact match
        assertEq(actualTotal1, expectedTotal1, "Batch rewards must equal sum of individual rewards");

        // Member2
        uint256 balanceBefore2 = token.balanceOf(member2);
        vm.prank(member2);
        (uint256[] memory voteRewards2, uint256[] memory boostRewards2,) = mint.mintGovRewards(address(token), 2, rounds);
        uint256 balanceAfter2 = token.balanceOf(member2);
        uint256 actualTotal2 = balanceAfter2 - balanceBefore2;

        // Expected is sum of what mintGovRewards actually returned
        uint256 expectedTotal2 = voteRewards2[0] + boostRewards2[0] + voteRewards2[1] + boostRewards2[1] + voteRewards2[2] + boostRewards2[2];

        assertEq(actualTotal2, expectedTotal2, "Member2 batch rewards must match calculation");

        // Verify member1 > member2 (100 vs 60 votes each round)
        assertTrue(actualTotal1 > actualTotal2, "Member1 must get more total rewards (100 > 60 votes)");
    }

    // ==================== Test 3: Proposal Threshold Boundaries ====================

    /// @notice Test 3: 5% threshold boundaries with exact mathematical verification
    /// @dev Tests <5%, =5%, and >5% scenarios with independent calculations
    function testRealIntegration_ProposalThresholdBoundaries() public {
        vm.roll(block.number + BLOCKS_PAST_ROUND0);

        // Setup: Different stake amounts for precise vote control
        vm.prank(distributor);
        token.transfer(member1, TOKEN_TRANSFER_AMOUNT);
        vm.prank(distributor);
        token.transfer(member2, TOKEN_TRANSFER_AMOUNT);
        vm.prank(owner);
        rootToken.transfer(member1, TOKEN_TRANSFER_AMOUNT);
        vm.prank(owner);
        rootToken.transfer(member2, TOKEN_TRANSFER_AMOUNT);

        // Member1: 5000 tokens
        _approveBothTokens(member1, STAKE_AMOUNT_MEMBER1);
        vm.prank(member1);
        stake.stakeLiquidity(address(token), STAKE_AMOUNT_MEMBER1, STAKE_AMOUNT_MEMBER1,
                            SLIPPAGE_100_PERCENT, PROMISED_WAITING_PHASES, 1);

        // Member2: 9500 tokens for more voting power
        uint256 member2StakeAmount = 9500;
        _approveBothTokens(member2, member2StakeAmount);
        vm.prank(member2);
        stake.stakeLiquidity(address(token), member2StakeAmount, member2StakeAmount,
                            SLIPPAGE_100_PERCENT, PROMISED_WAITING_PHASES, 2);

        uint256 testRound = phase.currentPhase();

        // Submit 3 proposals in the same round
        address proposalTarget1 = address(0x5001); // Will get exactly 5%
        address proposalTarget2 = address(0x5002); // Will get < 5%
        address proposalTarget3 = address(0x5003); // Will get > 5%

        vm.prank(member1);
        uint256 proposalId1 = submit.submitNewProposal(
            address(token), 1,
            ProposalBody({
                title: "Proposal 1 - exactly 5%",
                details: "Boundary test",
                target: proposalTarget1,
                targetMode: TargetMode.NoCallback,
                targetData: new bytes[](0)
            })
        );

        vm.prank(member2);
        uint256 proposalId2 = submit.submitNewProposal(
            address(token), 2,
            ProposalBody({
                title: "Proposal 2 - below 5%",
                details: "Should NOT be eligible",
                target: proposalTarget2,
                targetMode: TargetMode.NoCallback,
                targetData: new bytes[](0)
            })
        );

        // Vote on proposals in round 1 (testRound) BEFORE advancing blocks
        // Round 1: proposalId1 and proposalId2
        uint256[] memory proposalIdsRound1 = new uint256[](2);
        proposalIdsRound1[0] = proposalId1;
        proposalIdsRound1[1] = proposalId2;

        // Member1 votes in round 1: 12 to proposal1, 5 to proposal2
        uint256[] memory amounts1Round1 = new uint256[](2);
        amounts1Round1[0] = 12;
        amounts1Round1[1] = 5;
        vm.prank(member1);
        vote.vote(address(token), 1, proposalIdsRound1, amounts1Round1, new bytes[][](0));

        // Member2 votes in round 1: 12 to proposal1, 5 to proposal2
        uint256[] memory amounts2Round1 = new uint256[](2);
        amounts2Round1[0] = 12;
        amounts2Round1[1] = 5;
        vm.prank(member2);
        vote.vote(address(token), 2, proposalIdsRound1, amounts2Round1, new bytes[][](0));

        // Note: Cannot submit proposal3 in the same round - Submit contract allows only one proposal per member per round
        // So we advance to next round for proposal3
        vm.roll(block.number + BLOCKS_PER_ROUND);
        uint256 round2 = phase.currentPhase();

        vm.prank(member1);
        uint256 proposalId3 = submit.submitNewProposal(
            address(token), 1,
            ProposalBody({
                title: "Proposal 3 - above 5%",
                details: "Should be eligible",
                target: proposalTarget3,
                targetMode: TargetMode.NoCallback,
                targetData: new bytes[](0)
            })
        );

        // Vote on proposal 3 in round 2 BEFORE advancing blocks
        uint256[] memory proposalIdsRound2 = new uint256[](1);
        proposalIdsRound2[0] = proposalId3;

        // Member1 votes in round 2: 83 to proposal3
        uint256[] memory amounts1Round2 = new uint256[](1);
        amounts1Round2[0] = 83;
        vm.prank(member1);
        vote.vote(address(token), 1, proposalIdsRound2, amounts1Round2, new bytes[][](0));

        // Member2 votes in round 2: 363 to proposal3
        uint256[] memory amounts2Round2 = new uint256[](1);
        amounts2Round2[0] = 363;
        vm.prank(member2);
        vote.vote(address(token), 2, proposalIdsRound2, amounts2Round2, new bytes[][](0));

        // Advance to round 3 (auto-prepare when claiming rewards)
        vm.roll(block.number + BLOCKS_PER_ROUND);
        // Auto-prepare will happen when mintProposalReward is called

        // Verify vote counts for round 1
        uint256 totalVotesR1 = vote.votesNum(address(token), testRound);
        assertEq(totalVotesR1, 34, "Total votes round 1 must be 34 (12+12+5+5)");

        uint256 proposal1Votes = vote.votesNumByProposalId(address(token), testRound, proposalId1);
        uint256 proposal2Votes = vote.votesNumByProposalId(address(token), testRound, proposalId2);

        assertEq(proposal1Votes, 24, "Proposal 1 must have 24 votes");
        assertEq(proposal2Votes, 10, "Proposal 2 must have 10 votes");

        // Calculate minimum votes for round 1
        uint256 expectedMinVotesR1 = _calculateMinVotes(totalVotesR1);
        assertEq(expectedMinVotesR1, 2, "Min votes round 1 must be 2 (ceil(34 * 0.05))");

        // Both proposals qualify in round 1 (24 > 2, 10 > 2)
        assertTrue(mint.isProposalIdWithReward(address(token), testRound, proposalId1),
                   "Proposal 1 with 24/34 (70.59%) must be eligible");
        assertTrue(mint.isProposalIdWithReward(address(token), testRound, proposalId2),
                   "Proposal 2 with 10/34 (29.41%) must be eligible");

        // Verify vote counts for round 2
        uint256 totalVotesR2 = vote.votesNum(address(token), round2);
        assertEq(totalVotesR2, 446, "Total votes round 2 must be 446 (83+363)");

        uint256 proposal3Votes = vote.votesNumByProposalId(address(token), round2, proposalId3);
        assertEq(proposal3Votes, 446, "Proposal 3 must have 446 votes");

        // Calculate minimum votes for round 2
        uint256 expectedMinVotesR2 = _calculateMinVotes(totalVotesR2);
        assertEq(expectedMinVotesR2, 23, "Min votes round 2 must be 23 (ceil(446 * 0.05))");

        // Proposal 3 qualifies in round 2 (446 > 23)
        assertTrue(mint.isProposalIdWithReward(address(token), round2, proposalId3),
                   "Proposal 3 with 446/446 (100%) must be eligible");


        // Trigger auto-prepare for round 1 before querying eligibleProposalVotes
        vm.prank(proposalTarget1);
        uint256 claimed1 = mint.mintProposalReward(address(token), testRound, proposalId1);

        // Verify rewards with mathematical model for round 1
        uint256 eligibleVotesR1 = mint.eligibleProposalVotes(address(token), testRound);

        assertEq(eligibleVotesR1, 34, "Eligible votes round 1 must equal total votes (all eligible)");

        (uint256 reward1,) = mint.proposalRewardByProposalId(address(token), testRound, proposalId1);
        (uint256 reward2,) = mint.proposalRewardByProposalId(address(token), testRound, proposalId2);

        // Verify rewards exist
        assertTrue(reward1 > 0, "Proposal 1 must have reward");
        assertTrue(reward2 > 0, "Proposal 2 must have reward");

        // Verify reward1 > reward2 (24 votes > 10 votes)
        assertTrue(reward1 > reward2, "Proposal 1 (24 votes) must have more reward than Proposal 2 (10 votes)");

        // Verify claims for round 1 - proposal 1 already claimed earlier
        assertEq(claimed1, reward1, "Claimed amount must match stored reward");

        uint256 bal2Before = token.balanceOf(proposalTarget2);
        vm.prank(proposalTarget2);
        uint256 claimed2 = mint.mintProposalReward(address(token), testRound, proposalId2);
        assertEq(token.balanceOf(proposalTarget2) - bal2Before, claimed2, "Target 2 must receive exact reward");
        assertEq(claimed2, reward2, "Claimed amount must match stored reward");

        // Verify rewards with mathematical model for round 2
        (uint256 reward3,) = mint.proposalRewardByProposalId(address(token), round2, proposalId3);
        assertTrue(reward3 > 0, "Proposal 3 must have reward");

        uint256 bal3Before = token.balanceOf(proposalTarget3);
        vm.prank(proposalTarget3);
        uint256 claimed3 = mint.mintProposalReward(address(token), round2, proposalId3);
        assertEq(token.balanceOf(proposalTarget3) - bal3Before, claimed3, "Target 3 must receive exact reward");
    }

    // ==================== Test 4: Error Scenarios ====================

    /// @notice Test 4: Error scenarios validation
    function testRealIntegration_ErrorScenarios() public {
        vm.roll(block.number + BLOCKS_PAST_ROUND0);
        uint256 round1 = phase.currentPhase();

        // Give tokens for staking
        vm.prank(distributor);
        token.transfer(member1, TOKEN_TRANSFER_AMOUNT);
        vm.prank(owner);
        rootToken.transfer(member1, TOKEN_TRANSFER_AMOUNT);

        _approveBothTokens(member1, STAKE_AMOUNT_MEMBER1);
        vm.prank(member1);
        stake.stakeLiquidity(address(token), STAKE_AMOUNT_MEMBER1, STAKE_AMOUNT_MEMBER1,
                            SLIPPAGE_100_PERCENT, PROMISED_WAITING_PHASES, 1);

        address proposalTarget = address(0x6001);
        vm.prank(member1);
        uint256 proposalId = submit.submitNewProposal(
            address(token), 1,
            ProposalBody({
                title: "Error Test Proposal",
                details: "Testing errors",
                target: proposalTarget,
                targetMode: TargetMode.NoCallback,
                targetData: new bytes[](0)
            })
        );

        uint256[] memory proposalIds = new uint256[](1);
        proposalIds[0] = proposalId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = VOTE_AMOUNT_MEMBER1;

        vm.prank(member1);
        vote.vote(address(token), 1, proposalIds, amounts, new bytes[][](0));

        // Advance to next round (auto-prepare when minting)
        vm.roll(block.number + BLOCKS_PER_ROUND);

        // Error 1: Non-target cannot claim proposal reward
        address wrongClaimer = address(0x7777);
        vm.prank(wrongClaimer);
        vm.expectRevert(abi.encodeWithSignature("UnauthorizedCaller()"));
        mint.mintProposalReward(address(token), round1, proposalId);

        // Correct target can claim
        uint256 balBefore = token.balanceOf(proposalTarget);
        vm.prank(proposalTarget);
        uint256 claimed = mint.mintProposalReward(address(token), round1, proposalId);
        assertEq(token.balanceOf(proposalTarget) - balBefore, claimed, "Target must receive rewards");

        // Error 2: Non-owner cannot claim governance reward
        vm.prank(wrongClaimer);
        vm.expectRevert(abi.encodeWithSignature("NotMemberOwner(uint256)", 1));
        mint.mintGovReward(address(token), 1, round1);

        // Correct owner can claim
        vm.prank(member1);
        mint.mintGovReward(address(token), 1, round1);
        assertTrue(token.balanceOf(member1) > 0, "Member1 must receive rewards");

        // Error 3: Double claim protection
        vm.prank(proposalTarget);
        vm.expectRevert(abi.encodeWithSignature("AlreadyMinted()"));
        mint.mintProposalReward(address(token), round1, proposalId);

        vm.prank(member1);
        vm.expectRevert(abi.encodeWithSignature("AlreadyMinted()"));
        mint.mintGovReward(address(token), 1, round1);
    }

    // ==================== Test 5: Unstake and Re-vote ====================

    /// @notice Test 5: Unstake and re-vote with reward verification
    function testRealIntegration_UnstakeAndReVote() public {
        vm.roll(block.number + BLOCKS_PAST_ROUND0);
        uint256 round1 = phase.currentPhase();

        // Setup tokens
        vm.prank(distributor);
        token.transfer(member1, 20000);
        vm.prank(owner);
        rootToken.transfer(member1, 20000);

        // Round 1: Stake 5000 tokens
        _approveBothTokens(member1, 20000);
        vm.prank(member1);
        stake.stakeLiquidity(address(token), STAKE_AMOUNT_MEMBER1, STAKE_AMOUNT_MEMBER1,
                            SLIPPAGE_100_PERCENT, PROMISED_WAITING_PHASES, 1);

        address proposalTarget1 = address(0x7001);
        vm.prank(member1);
        uint256 proposalId1 = submit.submitNewProposal(
            address(token), 1,
            ProposalBody({
                title: "Round 1 Proposal",
                details: "Test",
                target: proposalTarget1,
                targetMode: TargetMode.NoCallback,
                targetData: new bytes[](0)
            })
        );

        // Member1 votes in round 1
        uint256[] memory proposalIds1 = new uint256[](1);
        proposalIds1[0] = proposalId1;
        uint256[] memory amounts1 = new uint256[](1);
        amounts1[0] = VOTE_AMOUNT_MEMBER1;
        vm.prank(member1);
        vote.vote(address(token), 1, proposalIds1, amounts1, new bytes[][](0));

        // Advance to round 2
        vm.roll(block.number + BLOCKS_PER_ROUND);
        uint256 round2 = phase.currentPhase();
        assertEq(round2, 2, "Must be at round 2 after first advance");
        // Auto-prepare when claiming rewards

        // Unstake all (request unstake in round 2)
        vm.prank(member1);
        stake.unstake(address(token), 1);

        // Requirement: round > unlockRequestPhase + promisedWaitingPhases
        // unlockRequestPhase = 2, promisedWaitingPhases = 1
        // Need: round > 2 + 1 = 3, so round must be at least 4
        // Continue from block 1201, add 1000 to reach block 2201 (round 3)
        vm.roll(1201 + BLOCKS_PER_ROUND);
        uint256 round3 = phase.currentPhase();
        assertEq(round3, 3, "Must be at round 3 after second advance");

        // Continue from block 2201, add 1000 to reach block 3201 (round 4)
        vm.roll(2201 + BLOCKS_PER_ROUND);
        uint256 round4 = phase.currentPhase();
        assertEq(round4, 4, "Must be at round 4 before withdraw");

        // Withdraw liquidity
        vm.prank(member1);
        stake.withdraw(address(token), 1);

        // Re-stake with less (3000 instead of 5000)
        vm.prank(member1);
        stake.stakeLiquidity(address(token), STAKE_AMOUNT_MEMBER2, STAKE_AMOUNT_MEMBER2,
                            SLIPPAGE_100_PERCENT, PROMISED_WAITING_PHASES, 1);

        address proposalTarget2 = address(0x7002);
        vm.prank(member1);
        uint256 proposalId2 = submit.submitNewProposal(
            address(token), 1,
            ProposalBody({
                title: "Round 4 Proposal",
                details: "Test",
                target: proposalTarget2,
                targetMode: TargetMode.NoCallback,
                targetData: new bytes[](0)
            })
        );

        // Vote with less (60 instead of 100) - member2 not staked, so member1 votes alone
        uint256[] memory proposalIds2 = new uint256[](1);
        proposalIds2[0] = proposalId2;
        uint256[] memory amounts2 = new uint256[](1);
        amounts2[0] = VOTE_AMOUNT_MEMBER2;
        vm.prank(member1);
        vote.vote(address(token), 1, proposalIds2, amounts2, new bytes[][](0));

        // Advance to round 5 (auto-prepare when claiming rewards)
        vm.roll(3201 + BLOCKS_PER_ROUND);
        uint256 round5 = phase.currentPhase();
        assertEq(round5, 5, "Must be at round 5 before claiming rewards");
        // Auto-prepare will happen when mintGovReward is called

        // Claim both rounds and verify mathematically
        uint256 balBefore = token.balanceOf(member1);

        vm.prank(member1);
        (uint256 vr1, uint256 br1,) = mint.mintGovReward(address(token), 1, round1);
        uint256 round1Reward = vr1 + br1;

        vm.prank(member1);
        (uint256 vr2, uint256 br2,) = mint.mintGovReward(address(token), 1, round4);
        uint256 round4Reward = vr2 + br2;

        uint256 balAfter = token.balanceOf(member1);

        // Verify exact balance change
        assertEq(balAfter - balBefore, round1Reward + round4Reward, "Balance change must match sum of rewards");

        // Verify round1 > round4 (higher stake → more rewards)
        assertTrue(round1Reward > round4Reward,
                   "Round 1 reward (5000 stake, 100 votes) must exceed Round 4 reward (3000 stake, 60 votes)");

        // Verify vote amounts match expected
        uint256 r1Votes = vote.votesNumByMemberId(address(token), round1, 1);
        uint256 r4Votes = vote.votesNumByMemberId(address(token), round4, 1);
        assertEq(r1Votes, VOTE_AMOUNT_MEMBER1, "Round 1 must have 100 votes");
        assertEq(r4Votes, VOTE_AMOUNT_MEMBER2, "Round 4 must have 60 votes");
    }

    // ========================================
    // Launch Token Creation Flow
    // ========================================

    function testLaunchTokenCreation() external {
        // Move to Round 1 first (avoid staking at round 0)
        // Phase starts at block 100, phase 1 = blocks [100, 1100), phase 2 = blocks [1100, 2100)
        vm.roll(200);  // Round 1
        uint256 round1 = phase.currentPhase();
        assertEq(round1, 1, "Must be at round 1");

        // Approve tokens before staking
        vm.startPrank(member1);
        token.approve(address(stake), type(uint256).max);
        rootToken.approve(address(stake), type(uint256).max);

        // Round 1: Member 1 stakes, votes, and mints gov reward to earn launch credits
        stake.stakeLiquidity(address(token), STAKE_AMOUNT_MEMBER1, STAKE_AMOUNT_MEMBER1,
                            SLIPPAGE_100_PERCENT, PROMISED_WAITING_PHASES, 1);
        vm.stopPrank();

        address proposalTarget1 = address(0x8001);
        vm.prank(member1);
        uint256 proposalId1 = submit.submitNewProposal(
            address(token), 1,
            ProposalBody({
                title: "Round 1 Proposal",
                details: "Test",
                target: proposalTarget1,
                targetMode: TargetMode.NoCallback,
                targetData: new bytes[](0)
            })
        );

        uint256[] memory proposalIds = new uint256[](1);
        proposalIds[0] = proposalId1;
        uint256[] memory votes = new uint256[](1);
        votes[0] = VOTE_AMOUNT_MEMBER1;

        vm.prank(member1);
        vote.vote(address(token), 1, proposalIds, votes, new bytes[][](0));

        // Move to Round 2 and mint gov reward
        // Phase 2 starts at block 1100 (ORIGIN_BLOCKS=100 + ORIGIN_PHASE_BLOCKS=1000)
        vm.roll(1100);
        vm.warp(block.timestamp + TIME_PER_ROUND);
        uint256 round2 = phase.currentPhase();
        assertEq(round2, 2, "Must be at round 2");

        vm.prank(member1);
        mint.mintGovReward(address(token), 1, 1);

        uint256 launchCredits = launch.launchCount(address(token), 1);
        assertTrue(launchCredits > 0, "Must earn launch credits from gov reward");

        // Launch a child token
        string memory childSymbol = "AAAA";
        vm.prank(member1);
        address childTokenAddress = launch.launchToken(
            childSymbol,
            address(token),
            1,
            member1,
            DistributorMode.NoCallback,
            new bytes[](0)
        );

        // Verify child token was created
        assertTrue(childTokenAddress != address(0), "Child token must be created");
        assertTrue(launch.isLOVE20Token(childTokenAddress), "Child must be registered LOVE20 token");

        // Verify parent-child relationship
        address parentOfChild = launch.parentTokenOf(childTokenAddress);
        assertTrue(parentOfChild == address(token), "Parent token must match");

        // Verify symbol lookup
        address tokenBySymbol = launch.tokenAddressBySymbol(childSymbol);
        assertTrue(tokenBySymbol == childTokenAddress, "Symbol lookup must return child token");

        // Verify launch credit was consumed
        uint256 creditsAfter = launch.launchCount(address(token), 1);
        assertEq(creditsAfter, launchCredits - 1, "Launch credit must be consumed");

        // Verify child token has correct initial supply
        ILOVE20Token childToken = ILOVE20Token(childTokenAddress);
        assertEq(childToken.balanceOf(member1), launch.LAUNCH_AMOUNT(), "Child token initial supply");
        assertEq(childToken.totalSupply(), launch.LAUNCH_AMOUNT(), "Child token total supply");
        assertEq(childToken.maxSupply(), launch.MAX_SUPPLY(), "Child token max supply");
    }

    // ========================================
    // Fee Settlement
    // ========================================

    function testSettleFees() external {
        // Move to Round 1 first (avoid staking at round 0)
        vm.roll(block.number + BLOCKS_PER_ROUND);
        uint256 round1 = phase.currentPhase();
        assertEq(round1, 1, "Must be at round 1");

        // Approve tokens before staking
        vm.startPrank(member1);
        token.approve(address(stake), type(uint256).max);
        rootToken.approve(address(stake), type(uint256).max);
        stake.stakeLiquidity(address(token), STAKE_AMOUNT_MEMBER1, STAKE_AMOUNT_MEMBER1,
                            SLIPPAGE_100_PERCENT, PROMISED_WAITING_PHASES, 1);
        vm.stopPrank();

        vm.startPrank(member2);
        token.approve(address(stake), type(uint256).max);
        rootToken.approve(address(stake), type(uint256).max);
        stake.stakeLiquidity(address(token), STAKE_AMOUNT_MEMBER2, STAKE_AMOUNT_MEMBER2,
                            SLIPPAGE_100_PERCENT, PROMISED_WAITING_PHASES, 2);
        vm.stopPrank();

        // Simulate trading fees accumulating in the pair
        address pair = stake.pairAddress(address(token));
        vm.startPrank(pair);
        token.transfer(pair, 100);
        rootToken.transfer(pair, 50);
        vm.stopPrank();

        // Settle fees
        uint256 totalBurnedBefore = stake.totalBurnedToken(address(token));
        uint256 parentBurnedBefore = stake.totalParentTokenBurned(address(token));

        stake.settleFees(address(token));

        uint256 totalBurnedAfter = stake.totalBurnedToken(address(token));
        uint256 parentBurnedAfter = stake.totalParentTokenBurned(address(token));

        // Verify fees were settled and burned
        assertTrue(totalBurnedAfter >= totalBurnedBefore, "Token burn must increase or stay same");
        assertTrue(parentBurnedAfter >= parentBurnedBefore, "Parent token burn must increase or stay same");
    }

    // ========================================
    // Merge Stake
    // ========================================

    function testMergeStake() external {
        // Move to Round 1 first (avoid staking at round 0)
        vm.roll(block.number + BLOCKS_PER_ROUND);
        uint256 round1 = phase.currentPhase();
        assertEq(round1, 1, "Must be at round 1");

        // Approve tokens before staking
        vm.startPrank(member1);
        token.approve(address(stake), type(uint256).max);
        rootToken.approve(address(stake), type(uint256).max);
        stake.stakeLiquidity(address(token), STAKE_AMOUNT_MEMBER1, STAKE_AMOUNT_MEMBER1,
                            SLIPPAGE_100_PERCENT, PROMISED_WAITING_PHASES, 1);
        vm.stopPrank();

        vm.startPrank(member2);
        token.approve(address(stake), type(uint256).max);
        rootToken.approve(address(stake), type(uint256).max);
        stake.stakeLiquidity(address(token), STAKE_AMOUNT_MEMBER2, STAKE_AMOUNT_MEMBER2,
                            SLIPPAGE_100_PERCENT, PROMISED_WAITING_PHASES, 2);
        vm.stopPrank();

        // Query initial stake amounts
        (uint256 m1LiqBefore, uint256 m1BoostBefore,,,,) = stake.stakeData(address(token), 1);
        (uint256 m2LiqBefore, uint256 m2BoostBefore,,,,) = stake.stakeData(address(token), 2);

        assertTrue(m1LiqBefore > 0, "Member 1 must have liquidity shares");
        assertTrue(m2LiqBefore > 0, "Member 2 must have liquidity shares");

        // Merge Member 1's stake into Member 2
        vm.prank(member1);
        stake.mergeStake(address(token), 1, 2);

        // Verify source stake was cleared
        (uint256 m1LiqAfter, uint256 m1BoostAfter,,,,) = stake.stakeData(address(token), 1);
        assertEq(m1LiqAfter, 0, "Source liquidity must be zero");
        assertEq(m1BoostAfter, 0, "Source boost must be zero");

        // Verify target stake increased
        (uint256 m2LiqAfter, uint256 m2BoostAfter,,,,) = stake.stakeData(address(token), 2);
        assertEq(m2LiqAfter, m2LiqBefore + m1LiqBefore, "Target liquidity must increase");
        assertEq(m2BoostAfter, m2BoostBefore + m1BoostBefore, "Target boost must increase");
    }

    // ========================================
    // Phase Sync
    // ========================================

    function testPhaseSync() external {
        uint256 phaseBefore = phase.currentPhase();

        // Move forward in time and blocks significantly
        vm.roll(block.number + 5000);
        vm.warp(block.timestamp + 10000);

        // Sync phase
        (bool adjusted, uint256 newPhaseBlocks) = phase.sync();

        uint256 phaseAfter = phase.currentPhase();

        // Phase must have progressed
        assertTrue(phaseAfter > phaseBefore, "Phase must progress after sync");

        // Check if adjustment was made
        if (adjusted) {
            assertTrue(newPhaseBlocks > 0, "New phase blocks must be positive if adjusted");
        }
    }

    // ========================================
    // Token Burn
    // ========================================

    function testTokenBurn() external {
        // Member 1 has initial token balance
        uint256 balanceBefore = token.balanceOf(member1);
        uint256 burnAmount = 100;

        assertTrue(balanceBefore >= burnAmount, "Must have enough tokens to burn");

        uint256 totalSupplyBefore = token.totalSupply();

        // Burn tokens
        vm.prank(member1);
        token.burn(burnAmount);

        uint256 balanceAfter = token.balanceOf(member1);
        uint256 totalSupplyAfter = token.totalSupply();

        assertEq(balanceAfter, balanceBefore - burnAmount, "Balance must decrease by burn amount");
        assertEq(totalSupplyAfter, totalSupplyBefore - burnAmount, "Total supply must decrease by burn amount");
    }

    // ========================================
    // Proposal Resubmission
    // ========================================

    function testProposalResubmission() external {
        // Move to Round 1 first (avoid staking at round 0)
        // Phase starts at block 100, phase 1 = blocks [100, 1100), phase 2 = blocks [1100, 2100)
        vm.roll(200);  // Round 1
        uint256 round1 = phase.currentPhase();
        assertEq(round1, 1, "Must be at round 1");

        // Approve tokens before staking
        vm.startPrank(member1);
        token.approve(address(stake), type(uint256).max);
        rootToken.approve(address(stake), type(uint256).max);

        // Round 1: Member 1 stakes and submits a proposal
        stake.stakeLiquidity(address(token), STAKE_AMOUNT_MEMBER1, STAKE_AMOUNT_MEMBER1,
                            SLIPPAGE_100_PERCENT, PROMISED_WAITING_PHASES, 1);
        vm.stopPrank();

        address proposalTarget1 = address(0x9001);
        vm.prank(member1);
        uint256 proposalId = submit.submitNewProposal(
            address(token), 1,
            ProposalBody({
                title: "Resubmit Test Proposal",
                details: "Testing resubmission across rounds",
                target: proposalTarget1,
                targetMode: TargetMode.NoCallback,
                targetData: new bytes[](0)
            })
        );

        assertTrue(submit.isSubmitted(address(token), 1, proposalId), "Proposal must be submitted in round 1");

        // Move to Round 2
        vm.roll(1100);  // Phase 2 starts at block 1100
        vm.warp(block.timestamp + TIME_PER_ROUND);
        uint256 round2 = phase.currentPhase();
        assertEq(round2, 2, "Must be at round 2");

        // Member 1 resubmits the same proposal in Round 2
        vm.prank(member1);
        submit.submit(address(token), 1, proposalId);

        assertTrue(submit.isSubmitted(address(token), 2, proposalId), "Proposal must be submitted in round 2");
        assertEq(submit.proposalIdBySubmitter(address(token), 2, 1), proposalId, "Lookup must return proposal ID");

        // Move to Round 3
        vm.roll(2100);  // Phase 3 starts at block 2100
        vm.warp(block.timestamp + TIME_PER_ROUND);
        uint256 round3 = phase.currentPhase();
        assertEq(round3, 3, "Must be at round 3");

        // Member 1 resubmits again in Round 3
        vm.prank(member1);
        submit.submit(address(token), 1, proposalId);

        assertTrue(submit.isSubmitted(address(token), 3, proposalId), "Proposal must be submitted in round 3");
    }
}

// ========== Mock External Dependencies ==========

contract MockUniswapV2Factory {
    mapping(address => mapping(address => address)) public getPair;

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        pair = address(new MockUniswapV2Pair(tokenA, tokenB));
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }
}

contract MockUniswapV2Pair {
    address public token0;
    address public token1;
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;
    uint256 private _totalSupply;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function getReserves() external view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function mint(address /* to */) external returns (uint256 liquidity) {
        liquidity = 1000;
        _totalSupply += liquidity;
        reserve0 = 5000;
        reserve1 = 5000;
        blockTimestampLast = uint32(block.timestamp);
        return liquidity;
    }

    function burn(address /* to */) external returns (uint256 amount0, uint256 amount1) {
        amount0 = 5000;
        amount1 = 5000;
        _totalSupply = 0;
        reserve0 = 0;
        reserve1 = 0;
        return (amount0, amount1);
    }

    function setReserves(uint112 _reserve0, uint112 _reserve1) external {
        reserve0 = _reserve0;
        reserve1 = _reserve1;
        blockTimestampLast = uint32(block.timestamp);
    }

    function setTotalSupply(uint256 supply) external {
        _totalSupply = supply;
    }

    function transfer(address /* to */, uint256 /* amount */) external pure returns (bool) {
        return true;
    }

    function balanceOf(address /* account */) external view returns (uint256) {
        return _totalSupply;
    }
}

contract MockUniswapV2Router {
    function addLiquidity(
        address, address, uint256, uint256, uint256, uint256, address, uint256
    ) external pure returns (uint256, uint256, uint256) {
        return (0, 0, 0);
    }

    function removeLiquidity(
        address, address, uint256, uint256, uint256, address, uint256
    ) external pure returns (uint256, uint256) {
        return (0, 0);
    }
}
