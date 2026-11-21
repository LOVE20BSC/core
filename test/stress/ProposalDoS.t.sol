// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Test} from "@forge-std/Test.sol";
import {Mint} from "../../src/Mint.sol";
import {Stake} from "../../src/Stake.sol";
import {DexConfig} from "../../src/interfaces/IStake.sol";
import {Submit} from "../../src/Submit.sol";
import {Vote} from "../../src/Vote.sol";
import {Phase} from "../../src/Phase.sol";
import {MemberNFT} from "../../src/MemberNFT.sol";
import {Launch} from "../../src/Launch.sol";
import {LOVE20Token} from "../../src/LOVE20Token.sol";
import {LaunchInitParams} from "../../src/interfaces/ILaunch.sol";
import {ProposalBody, TargetMode} from "../../src/interfaces/ISubmit.sol";
import {MockPair, MockRouter} from "../Stake.t.sol";
import {MockPairFactory} from "../utils/StakeMocks.sol";

contract StressPairFactory is MockPairFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        pair = address(new MockPair(tokenA, tokenB));
        this.setPair(tokenA, tokenB, pair);
    }
}

/// @dev Real core contracts, mocked DEX. Gas is a local regression budget, not a BSC block limit.
contract ProposalDoSTest is Test {
    Mint private mint;
    Stake private stake;
    Submit private submit;
    Vote private vote;
    Phase private phase;
    MemberNFT private memberNFT;
    LOVE20Token private token;
    LOVE20Token private parent;
    address private actor;

    function setUp() public {
        vm.roll(1);
        actor = makeAddr("proposal-owner");
        phase = new Phase(1, 1000, 300, 1e18, 10);
        StressPairFactory factory = new StressPairFactory();
        parent = new LOVE20Token("Parent", "PAR", 1e27, 1e28, actor, address(this), address(this));
        MockRouter router = new MockRouter();

        uint256 nonce = vm.getNonce(address(this));
        address predictedMember = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedVote = vm.computeCreateAddress(address(this), nonce + 4);
        address predictedMint = vm.computeCreateAddress(address(this), nonce + 5);

        Launch launch = new Launch(LaunchInitParams({
            mintAddress: predictedMint,
            memberNFTAddress: predictedMember,
            rootParentTokenAddress: address(parent),
            pairFactoryAddress: address(factory),
            distributor: actor,
            launchCountThresholdRatio: 1e18,
            maxLaunchCount: 1000,
            tokenSymbolLength: 4,
            launchAmount: 1e27,
            maxSupply: 1e28,
            name: "Stress",
            symbol: "STRS"
        }));
        token = LOVE20Token(launch.FIRST_TOKEN_ADDRESS());
        memberNFT = new MemberNFT(1e18, 1, 1, 32, address(token));
        stake = new Stake(
                address(phase),
                address(memberNFT),
                predictedVote,
                address(launch),
                DexConfig({router: address(router), pairFactory: address(factory), swapFeeForLpRatio: 2500000000000000, swapFeeForProtocolRatio: 500000000000000}),
                1,
                100,
                3e15,
                2,
                5
            );
        submit = new Submit(address(phase), address(stake), address(memberNFT), 1);
        vote = new Vote(address(phase), address(stake), address(submit), address(memberNFT), predictedMint);
        mint = new Mint(address(phase), address(vote), address(submit), address(launch), address(memberNFT), 5e16, 1e17, 1e17);
        vm.startPrank(actor);
        token.approve(address(memberNFT), type(uint256).max);
        token.approve(address(stake), type(uint256).max);
        parent.approve(address(stake), type(uint256).max);
        vm.stopPrank();
    }

    function testBurnUnusedBoostWith10Proposals() public { _measureBoostBurn(10); }
    function testBurnUnusedBoostWith300Proposals() public { _measureBoostBurn(300); }
    function testBurnUnusedBoostWith1000Proposals() public { _measureBoostBurn(1000); }

    function _measureBoostBurn(uint256 count) private {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        // Build the history of many transactions without consuming the single test-call gas budget.
        vm.pauseGasMetering();
        vm.startPrank(actor);
        uint256[] memory memberIds = new uint256[](count);
        uint256 expectedPool;
        for (uint256 i; i < count; i++) {
            (uint256 memberId,) = memberNFT.mint(string.concat("member", vm.toString(i)));
            memberIds[i] = memberId;
            uint256 amount = i == 0 ? count * 1e18 : 1e18;
            stake.stakeLiquidity(address(token), amount, amount, 1, memberId, type(uint256).max);
            ids[0] = submit.submitNewProposal(address(token), memberId, ProposalBody({
                title: "Stress proposal",
                details: "",
                target: actor,
                targetMode: TargetMode.NoCallback,
                creationData: ""
            }), "");
            amounts[0] = amount;
            if (i == 0) expectedPool = mint.rewardAvailable(address(token)) / 10;
            vote.vote(address(token), memberId, ids, amounts, new bytes[](0));
            assertEq(stake.govVotes(address(token), 1, memberId), amount);
        }
        vm.roll(1001);
        for (uint256 i; i < count; i++) {
            stake.unstake(address(token), memberIds[i]);
        }
        // The unlock lands in a later round, so round 1 keeps its peak and only the live round clears.
        assertEq(stake.totalGovVotes(address(token), 1), (2 * count - 1) * 1e18);
        assertEq(stake.totalGovVotes(address(token), phase.currentPhase()), 0);
        vm.stopPrank();
        vm.resumeGasMetering();
        (, uint256 actualCount) = vote.votedProposalIds(address(token), 1, 0, 0, false);
        assertEq(actualCount, count);
        assertEq(vote.totalVoteAmount(address(token), 1), (2 * count - 1) * 1e18);

        address launchAddress = mint.LAUNCH_ADDRESS();
        // A fresh external call models cold reads instead of reusing warmed setup slots.
        vm.cool(address(mint));
        vm.cool(address(vote));
        vm.cool(address(phase));
        vm.cool(launchAddress);
        uint256 beforeGas = gasleft();
        mint.burnUnusedBoostReward{gas: 160_000}(address(token), 1);
        uint256 burnGas = beforeGas - gasleft();
        emit log_named_uint("proposals", count);
        emit log_named_uint("unused boost burn gas", burnGas);
        assertLt(burnGas, 160_000, "local unused boost burn gas budget exceeded");
        assertEq(mint.totalRewardBurned(address(token)), expectedPool - expectedPool / 2);
        assertEq(mint.govReward(address(token), 1), expectedPool);

        uint256 reserved = mint.totalRewardReserved(address(token));
        vm.startPrank(actor);
        (uint256 govReward,) = mint.mintGovReward(address(token), 1, 1, actor);
        assertGt(govReward, 0);

        uint256 reward = mint.mintProposalReward(address(token), 1, 1, actor);
        vm.stopPrank();
        assertEq(reward, expectedPool * count / (2 * count - 1));
        assertEq(mint.totalRewardReserved(address(token)), reserved, "settlement changed total reserved");
    }
}
