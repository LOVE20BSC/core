// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Test} from "forge-std/Test.sol";
import {Mint} from "../../src/Mint.sol";
import {Stake} from "../../src/Stake.sol";
import {Submit} from "../../src/Submit.sol";
import {Vote} from "../../src/Vote.sol";
import {Phase} from "../../src/Phase.sol";
import {MemberNFT} from "../../src/MemberNFT.sol";
import {Launch} from "../../src/Launch.sol";
import {LOVE20Token} from "../../src/LOVE20Token.sol";
import {LaunchInitParams} from "../../src/interfaces/ILaunch.sol";
import {ProposalBody, TargetMode} from "../../src/interfaces/ISubmit.sol";
import {MockPair, MockPairFactory, MockRouter} from "../Stake.t.sol";

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
        memberNFT = new MemberNFT(1e18, 1, 1, 32);
        mint = new Mint();
        stake = new Stake();
        submit = new Submit();
        vote = new Vote();
        Launch launch = new Launch();
        StressPairFactory factory = new StressPairFactory();
        parent = new LOVE20Token("Parent", "PAR", 1e27, 1e28, actor, address(this), address(1));
        launch.init(LaunchInitParams({
            mintAddress: address(mint),
            memberNFTAddress: address(memberNFT),
            rootParentTokenAddress: address(parent),
            pairFactoryAddress: address(factory),
            distributor: actor,
            launchRatio: 1e18,
            maxLaunchCount: 1000,
            tokenSymbolLength: 4,
            launchAmount: 1e27,
            maxSupply: 1e28,
            name: "Stress",
            symbol: "STRS"
        }));
        (address[] memory tokens,) = launch.tokens(0, 1, false);
        token = LOVE20Token(tokens[0]);
        stake.init(address(phase), address(memberNFT), address(vote), address(launch),
            address(new MockRouter()), address(factory), 1, 100, 1000);
        submit.init(address(phase), address(stake), address(memberNFT), 10);
        vote.init(address(phase), address(stake), address(submit), address(memberNFT));
        mint.init(address(vote), address(submit), address(launch), address(memberNFT), 50, 100, 100, 2);
        vm.startPrank(actor);
        token.approve(address(memberNFT), type(uint256).max);
        token.approve(address(stake), type(uint256).max);
        parent.approve(address(stake), type(uint256).max);
        vm.stopPrank();
    }

    function testPrepare10Proposals() public { _measurePreparation(10); }
    function testPrepare300Proposals() public { _measurePreparation(300); }
    function testPrepare1000Proposals() public { _measurePreparation(1000); }

    function _measurePreparation(uint256 count) private {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        // Build the history of many transactions without consuming the single test-call gas budget.
        vm.pauseGasMetering();
        vm.startPrank(actor);
        for (uint256 i; i < count; i++) {
            (uint256 memberId,) = memberNFT.mint(string.concat("member", vm.toString(i)));
            uint256 amount = i == 0 ? count * 1e18 : 1e18;
            stake.stakeLiquidity(address(token), amount, amount, 0, 1, memberId);
            ids[0] = submit.submitNewProposal(address(token), memberId, ProposalBody({
                title: "Stress proposal",
                details: "",
                target: actor,
                targetMode: TargetMode.NoCallback,
                targetData: new bytes[](0)
            }));
            amounts[0] = amount;
            vote.vote(address(token), memberId, ids, amounts, new bytes[][](0));
            stake.unstake(address(token), memberId);
            assertEq(stake.globalGovVotes(address(token)), 0);
        }
        vm.stopPrank();
        vm.resumeGasMetering();
        (, uint256 actualCount) = vote.votedProposalIds(address(token), 1, 0, 0, false);
        assertEq(actualCount, count);
        assertEq(vote.votesNum(address(token), 1), (2 * count - 1) * 1e18);

        vm.roll(1001);
        uint256 available = mint.rewardAvailable(address(token));
        address launchAddress = mint.launchAddress();
        // A fresh external call models cold reads instead of reusing warmed setup slots.
        vm.cool(address(mint));
        vm.cool(address(vote));
        vm.cool(address(phase));
        vm.cool(address(memberNFT));
        vm.cool(address(token));
        vm.cool(launchAddress);
        vm.startPrank(actor);
        uint256 beforeGas = gasleft();
        (uint256 govReward,,) = mint.mintGovReward{gas: 8_000_000}(address(token), 1, 1);
        uint256 preparationGas = beforeGas - gasleft();
        vm.stopPrank();
        emit log_named_uint("proposals", count);
        emit log_named_uint("first mint gas", preparationGas);
        assertLt(preparationGas, 8_000_000, "local preparation gas budget exceeded");
        assertTrue(mint.isRewardPrepared(address(token), 1));
        uint256 eligibleVotes = count <= 10 ? (2 * count - 1) * 1e18 : count * 1e18;
        assertEq(mint.eligibleProposalVotes(address(token), 1), eligibleVotes);
        assertEq(mint.govReward(address(token), 1), available / 10);
        assertGt(govReward, 0);

        uint256 reserved = mint.rewardReserved(address(token));
        vm.prank(actor);
        uint256 reward = mint.mintProposalReward(address(token), 1, 1);
        assertEq(reward, (available / 10) * count * 1e18 / eligibleVotes);
        assertEq(mint.rewardReserved(address(token)), reserved, "prepared twice");
    }
}
