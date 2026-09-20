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
import {LaunchInitParams} from "../../src/interfaces/ILaunch.sol";
import {TargetMode} from "../../src/interfaces/ISubmit.sol";

interface TestVm {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function warp(uint256) external;
    function roll(uint256) external;
}

/// @title MintRealIntegration - Real contract integration tests
/// @notice Tests Mint with actual Phase/Vote/Submit/Stake/Launch contracts
/// @dev Uses real contracts to verify complete governance flow
contract MintRealIntegrationTest {
    TestVm constant vm = TestVm(address(uint160(uint256(keccak256("hevm cheat code")))));

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
            launchAmount: 50000,         // initial supply (increased for test transfers)
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
            50,   // proposalRewardMinVotePerThousand: 5%
            100,  // roundRewardGovPerThousand: 10%
            100,  // roundRewardProposalPerThousand: 10%
            2     // maxGovBoostRewardMultiplier: 2x
        );

        // ========== Phase 3: Setup test state ==========

        // MemberNFT is already initialized with the new token by Launch.init()
        // Members need to have the new token to pay for NFT minting
        // Transfer some new tokens to members from distributor
        vm.prank(address(0x9001)); // distributor has initial supply
        token.transfer(member1, 5000);

        vm.prank(address(0x9001));
        token.transfer(member2, 5000);

        // Mint member NFTs for test accounts using the new token
        vm.prank(member1);
        token.approve(address(memberNFT), 10000);
        vm.prank(member1);
        (uint256 memberId1,) = memberNFT.mint("Alice");
        assertEq(memberId1, 1, "Member1 should have ID 1");

        vm.prank(member2);
        token.approve(address(memberNFT), 10000);
        vm.prank(member2);
        (uint256 memberId2,) = memberNFT.mint("Bob");
        assertEq(memberId2, 2, "Member2 should have ID 2");
    }

    /// @notice Test 1: Complete governance flow with real contracts
    function testRealIntegration_FullGovernanceFlow() public {
        // ========== Step 0: Advance past round 0 (staking not allowed at round 0) ==========

        vm.roll(block.number + 200); // Advance past round 0

        // ========== Step 1: Members stake liquidity ==========

        // Members need to add liquidity to stake (token-rootToken pair)
        // For simplicity, we'll give them both tokens first
        vm.prank(address(0x9001)); // distributor
        token.transfer(member1, 10000);

        vm.prank(address(0x9001));
        token.transfer(member2, 10000);

        // Give members rootToken for staking
        vm.prank(owner);
        rootToken.transfer(member1, 10000);

        vm.prank(owner);
        rootToken.transfer(member2, 10000);

        // Member1 stakes liquidity
        vm.startPrank(member1);
        token.approve(address(stake), 10000);
        rootToken.approve(address(stake), 10000);
        stake.stakeLiquidity(
            address(token),
            5000,                    // tokenAmount
            5000,                    // parentTokenAmount
            1e18,                    // slippage: 100%
            1,                       // promisedWaitingPhases
            1                        // memberId
        );
        vm.stopPrank();

        // Member2 stakes liquidity
        vm.startPrank(member2);
        token.approve(address(stake), 10000);
        rootToken.approve(address(stake), 10000);
        stake.stakeLiquidity(
            address(token),
            3000,                    // tokenAmount
            3000,                    // parentTokenAmount
            1e18,                    // slippage: 100%
            1,                       // promisedWaitingPhases
            2                        // memberId
        );
        vm.stopPrank();

        // ========== Step 2: Submit proposals ==========

        address proposalTarget = address(0x4001);

        vm.prank(member1);
        uint256 proposalId = submit.submitNewProposal(
            address(token),
            1,      // memberId
            ProposalBody({
                title: "Proposal 1",
                details: "Description",
                target: proposalTarget,
                targetMode: TargetMode.NoCallback,
                targetData: new bytes[](0)
            })
        );
        assertEq(proposalId, 1, "First proposal should have ID 1");

        // ========== Step 3: Members vote on proposals ==========

        uint256[] memory proposalIds = new uint256[](1);
        proposalIds[0] = proposalId;

        uint256[] memory amounts1 = new uint256[](1);
        amounts1[0] = 100; // member1 votes 100

        vm.prank(member1);
        vote.vote(address(token), 1, proposalIds, amounts1, new bytes[][](0));

        uint256[] memory amounts2 = new uint256[](1);
        amounts2[0] = 60; // member2 votes 60

        vm.prank(member2);
        vote.vote(address(token), 2, proposalIds, amounts2, new bytes[][](0));

        // ========== Step 4: Advance to next round ==========

        // Get current round and advance blocks to end it
        uint256 currentRound = phase.currentPhase();

        // Move to next round by rolling forward blocks
        vm.roll(block.number + 1000); // advance 1000 blocks

        uint256 nextRound = phase.currentPhase();
        assertTrue(nextRound > currentRound, "Round should have advanced");

        // ========== Step 5: Prepare rewards using real Mint ==========

        mint.prepareRewardIfNeeded(address(token), currentRound);
        assertTrue(mint.isRewardPrepared(address(token), currentRound), "Rewards should be prepared");

        // ========== Step 6: Verify and claim governance rewards ==========

        _verifyAndClaimGovRewards(currentRound);

        // ========== Step 7: Verify and claim proposal rewards ==========

        _verifyAndClaimProposalRewards(currentRound, proposalId, proposalTarget);
    }

    function _verifyAndClaimGovRewards(uint256 currentRound) internal {
        (uint256 voteReward1, uint256 boostReward1,,) =
            mint.govRewardByMemberId(address(token), currentRound, 1);

        assertTrue(voteReward1 > 0, "Member1 should have vote rewards");

        uint256 balanceBefore1 = token.balanceOf(member1);
        vm.prank(member1);
        mint.mintGovReward(address(token), 1, currentRound);
        uint256 balanceAfter1 = token.balanceOf(member1);

        assertEq(balanceAfter1 - balanceBefore1, voteReward1 + boostReward1,
                 "Member1 should receive vote + boost rewards");

        // Member2 claims
        (uint256 voteReward2, uint256 boostReward2,,) =
            mint.govRewardByMemberId(address(token), currentRound, 2);

        uint256 balanceBefore2 = token.balanceOf(member2);
        vm.prank(member2);
        mint.mintGovReward(address(token), 2, currentRound);
        uint256 balanceAfter2 = token.balanceOf(member2);

        assertEq(balanceAfter2 - balanceBefore2, voteReward2 + boostReward2,
                 "Member2 should receive vote + boost rewards");

        // Verify proportions: Member1 voted 100, Member2 voted 60
        assertTrue(voteReward1 > voteReward2, "Member1 should get more vote rewards than Member2");
    }

    function _verifyAndClaimProposalRewards(uint256 currentRound, uint256 proposalId, address proposalTarget) internal {
        (uint256 proposalAmount,) = mint.proposalRewardByProposalId(address(token), currentRound, proposalId);
        assertTrue(proposalAmount > 0, "Proposal should have rewards");

        uint256 targetBalanceBefore = token.balanceOf(proposalTarget);
        vm.prank(proposalTarget);
        uint256 claimed = mint.mintProposalReward(address(token), currentRound, proposalId);
        uint256 targetBalanceAfter = token.balanceOf(proposalTarget);

        assertEq(claimed, proposalAmount, "Claimed amount should match");
        assertEq(targetBalanceAfter - targetBalanceBefore, proposalAmount,
                 "Proposal target should receive rewards");

        // Proposal should be eligible (>5% votes)
        assertTrue(mint.isProposalIdWithReward(address(token), currentRound, proposalId),
                   "Proposal with >5% votes should be eligible");
    }

    // Helper functions
    function assertTrue(bool condition, string memory message) internal pure {
        require(condition, message);
    }

    function assertEq(uint256 a, uint256 b, string memory message) internal pure {
        require(a == b, message);
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
        // Simple mock: mint 1000 LP tokens
        liquidity = 1000;
        _totalSupply += liquidity;
        // Update reserves based on balance
        reserve0 = 5000;
        reserve1 = 5000;
        blockTimestampLast = uint32(block.timestamp);
        return liquidity;
    }

    function burn(address /* to */) external returns (uint256 amount0, uint256 amount1) {
        // Simple mock: return proportional amounts
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
}

contract MockUniswapV2Router {
    function addLiquidity(
        address,
        address,
        uint256,
        uint256,
        uint256,
        uint256,
        address,
        uint256
    ) external pure returns (uint256, uint256, uint256) {
        return (0, 0, 0);
    }

    function removeLiquidity(
        address,
        address,
        uint256,
        uint256,
        uint256,
        address,
        uint256
    ) external pure returns (uint256, uint256) {
        return (0, 0);
    }
}
