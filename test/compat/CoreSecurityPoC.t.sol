// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Stake} from "../../src/Stake.sol";
import {Mint} from "../../src/Mint.sol";
import {Vote} from "../../src/Vote.sol";
import {Submit} from "../../src/Submit.sol";
import {Launch} from "../../src/Launch.sol";
import {MemberNFT} from "../../src/MemberNFT.sol";
import {Phase} from "../../src/Phase.sol";
import {LOVE20Token} from "../../src/LOVE20Token.sol";
import {LaunchInitParams, DistributorMode} from "../../src/interfaces/ILaunch.sol";
import {ProposalBody, TargetMode} from "../../src/interfaces/ISubmit.sol";
import {IStakeErrors} from "../../src/interfaces/IStake.sol";
import {IMemberNFTErrors} from "../../src/interfaces/IMemberNFT.sol";
import {IProposalTarget} from "../../src/interfaces/IProposalTarget.sol";
import {RealV2Factory, RealV2Pair, RealV2Router} from "./RealV2.sol";

interface Vm {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function roll(uint256) external;
    function warp(uint256) external;
    function expectRevert(bytes calldata) external;
    function getNonce(address) external view returns (uint256);
    function computeCreateAddress(address, uint256) external view returns (address);
}

/// @notice Member that is a contract: owns an NFT, submits a Callback proposal and tries to merge
///         its own stake from inside `onProposalCreated`.
contract ProposalBot is IProposalTarget {
    Stake private immutable STAKE;
    Submit private immutable SUBMIT;
    address private immutable TOKEN;

    uint256 public botId;
    uint256 public targetId;
    bool public mergeAttempted;
    bytes public mergeRevertData;

    constructor(Stake stakeAddress, Submit submitAddress, address tokenAddress) {
        STAKE = stakeAddress;
        SUBMIT = submitAddress;
        TOKEN = tokenAddress;
    }

    function configure(uint256 botMemberId, uint256 mergeTargetId) external {
        botId = botMemberId;
        targetId = mergeTargetId;
    }

    function approveAll(address tokenAddress, address spender, uint256 amount) external {
        IERC20(tokenAddress).approve(spender, amount);
    }

    function stakeLiquidity(uint256 amount, uint256 phases) external {
        STAKE.stakeLiquidity(TOKEN, amount, amount, 1e18, phases, botId);
    }

    function mergeStake() external {
        STAKE.mergeStake(TOKEN, botId, targetId);
    }

    function submitProposal(ProposalBody calldata body) external returns (uint256 proposalId) {
        return SUBMIT.submitNewProposal(TOKEN, botId, body);
    }

    function onProposalCreated(address tokenAddress, uint256, bytes[] calldata) external {
        mergeAttempted = true;
        require(tokenAddress == TOKEN, "unexpected token");
        try STAKE.mergeStake(TOKEN, botId, targetId) {
            mergeRevertData = "";
        } catch (bytes memory reason) {
            mergeRevertData = reason;
        }
    }

    function onProposalSubmitted(address, uint256, uint256, bytes[] calldata) external {}

    function onProposalVoted(address, uint256, uint256, uint256, uint256, bytes[] calldata) external {}

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/// @notice Regression witnesses for the security fixes from the init-era audit and for the
///         accounting paths they touch. The DEX is the faithful V2 subset from RealV2.sol.
contract CoreSecurityPoC {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant BLOCKS_PER_PHASE = 1000;
    uint256 private constant WAIT_MIN = 1;
    uint256 private constant WAIT_MAX = 100;
    uint256 private constant SUBMIT_MIN_RATIO = 5e16;
    uint256 private constant PROPOSAL_MIN_VOTE_RATIO = 5e16;
    uint256 private constant GOV_RATIO = 1e17;
    uint256 private constant PROPOSAL_RATIO = 1e17;
    uint256 private constant FEE_RATIO = 2.5e15;
    uint256 private constant SLIPPAGE_ANY = 1e18;
    uint256 private constant LAUNCH_AMOUNT = 1e24;
    uint256 private constant MAX_SUPPLY = 1e27;

    Phase private phase;
    MemberNFT private nft;
    Mint private mint;
    Vote private vote;
    Submit private submit;
    Stake private stake;
    Launch private launch;

    RealV2Factory private factory;
    RealV2Router private router;
    LOVE20Token private root;
    LOVE20Token private token;
    RealV2Pair private pair;

    address private m1 = address(0xA11CE);
    address private m2 = address(0xB0B);
    address private m3 = address(0xCA401);
    address private m4 = address(0xDA4E);

    function setUp() public {
        factory = new RealV2Factory();
        router = new RealV2Router(address(factory));

        root = new LOVE20Token("Wrapped BNB", "WBNB", 1e27, 1e28, address(this), address(this), address(this));

        phase = new Phase(0, BLOCKS_PER_PHASE, BLOCKS_PER_PHASE, 1e18, 50);

        uint256 nonce = vm.getNonce(address(this));
        address predictedMember = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedVote = vm.computeCreateAddress(address(this), nonce + 4);
        address predictedMint = vm.computeCreateAddress(address(this), nonce + 5);

        launch = new Launch(
            LaunchInitParams({
                mintAddress: predictedMint,
                memberNFTAddress: predictedMember,
                rootParentTokenAddress: address(root),
                pairFactoryAddress: address(factory),
                distributor: address(this),
                launchCountThresholdRatio: 1e16,
                maxLaunchCount: 1000,
                tokenSymbolLength: 4,
                launchAmount: LAUNCH_AMOUNT,
                maxSupply: MAX_SUPPLY,
                name: "TestCommunity",
                symbol: "LOVE"
            })
        );

        token = LOVE20Token(launch.FIRST_TOKEN_ADDRESS());
        pair = RealV2Pair(factory.getPair(address(token), address(root)));

        nft = new MemberNFT(1e18, 7, 2, 32, address(token));
        stake = new Stake(
            address(phase), address(nft), predictedVote, address(launch), address(router), address(factory),
            WAIT_MIN, WAIT_MAX, FEE_RATIO, 2, 5
        );
        submit = new Submit(address(phase), address(stake), address(nft), SUBMIT_MIN_RATIO);
        vote = new Vote(address(phase), address(stake), address(submit), address(nft));
        mint = new Mint(
            address(phase), address(vote), address(submit), address(launch), address(nft),
            PROPOSAL_MIN_VOTE_RATIO, GOV_RATIO, PROPOSAL_RATIO
        );

        address[4] memory members = [m1, m2, m3, m4];
        for (uint256 i = 0; i < members.length; i++) {
            token.transfer(members[i], 1e23);
            root.transfer(members[i], 1e23);
        }
    }


    function _mintMember(address who, string memory name) internal returns (uint256 memberId) {
        vm.startPrank(who);
        token.approve(address(nft), type(uint256).max);
        (memberId,) = nft.mint(name);
        vm.stopPrank();
    }

    function _stake(address who, uint256 memberId, uint256 amount, uint256 phases) internal {
        vm.startPrank(who);
        token.approve(address(stake), type(uint256).max);
        root.approve(address(stake), type(uint256).max);
        stake.stakeLiquidity(address(token), amount, amount, SLIPPAGE_ANY, phases, memberId);
        vm.stopPrank();
    }

    function _advancePhase() internal {
        vm.roll(block.number + BLOCKS_PER_PHASE);
        vm.warp(block.timestamp + BLOCKS_PER_PHASE);
    }

    function _eq(uint256 a, uint256 b, string memory what) internal pure {
        require(a == b, what);
    }

    function _true(bool v, string memory what) internal pure {
        require(v, what);
    }

    function _eqAddr(address a, address b, string memory what) internal pure {
        require(a == b, what);
    }

    function _eqBytes32(bytes32 a, bytes32 b, string memory what) internal pure {
        require(a == b, what);
    }

    /// @notice Launch reuses a pair that already exists for the predicted token address: the token
    ///         is still registered and stakeable, and no second pair is created.
    /// @notice Load-bearing: the submit gate is a live-denominator check, so raising a single
    ///         member's promised waiting period with 1 wei of boost lifts the threshold above every
    ///         smaller member's weight. This pins the accepted design (competitive, both sides can
    ///         raise their own lock), not a defect: changing the multiplier or the threshold basis
    ///         must update this expectation deliberately.
    function test_oneWeiBoostRaisesTheSubmitGateAboveOtherMembers() public {
        _mintMember(m1, "Alice");
        _mintMember(m2, "Bob");
        _mintMember(m3, "Carol");
        _mintMember(m4, "Dave");
        _stake(m1, 1, 1e20, WAIT_MIN);
        _stake(m2, 2, 1e20, WAIT_MIN);
        _stake(m3, 3, 1e20, WAIT_MIN);
        _stake(m4, 4, 1e20, WAIT_MIN);

        uint256 round = phase.currentPhase();
        _true(submit.canSubmit(address(token), 2), "m2 may submit before");

        vm.startPrank(m1);
        token.approve(address(stake), 1);
        stake.stakeBoost(address(token), 1, WAIT_MAX, 1);
        vm.stopPrank();

        uint256 total = stake.totalValidGovVotes(address(token), round);
        _true(stake.validGovVotes(address(token), round, 1) * 100 >= total * 90, "m1 holds >= 90%");
        _true(submit.canSubmit(address(token), 1), "m1 keeps the gate");
        _true(!submit.canSubmit(address(token), 2), "m2 lost the gate");
        _true(!submit.canSubmit(address(token), 3), "m3 lost the gate");
        _true(!submit.canSubmit(address(token), 4), "m4 lost the gate");

        _advancePhase();
        _true(!submit.canSubmit(address(token), 2), "m2 still excluded next round");
    }

    function test_launchReusesPrecreatedPair() public {
        _mintMember(m1, "Alice");
        vm.prank(address(mint));
        launch.addLaunchCount(address(token), 1, 1);

        uint256 nonce = vm.getNonce(address(launch));
        address predicted = vm.computeCreateAddress(address(launch), nonce);
        factory.preCreatePair(predicted, address(token));

        uint256 pairsBefore = factory.createdPairCount();
        vm.prank(m1);
        address child = launch.launchToken(
            "ABCD", address(token), 1, address(this), DistributorMode.NoCallback, new bytes[](0)
        );

        _eqAddr(child, predicted, "child token address is predictable");
        _eq(factory.createdPairCount(), pairsBefore, "Launch created no second pair");
        _eqAddr(launch.parentToken(child), address(token), "child registered with its parent");
        _true(launch.isLOVE20Token(child), "child is registered");

        LOVE20Token(child).transfer(m1, 1e22);
        vm.startPrank(m1);
        LOVE20Token(child).approve(address(stake), type(uint256).max);
        token.approve(address(stake), type(uint256).max);
        (uint256 votesAdded, uint256 sharesAdded) =
            stake.stakeLiquidity(child, 1e18, 1e18, SLIPPAGE_ANY, WAIT_MIN, 1);
        vm.stopPrank();
        _true(sharesAdded > 0 && votesAdded > 0, "stake into the reused pair succeeds");
    }

    /// @notice `onProposalCreated` runs after the round's submit record is written, so a member
    ///         cannot merge its stake inside the callback; the same merge succeeds next round.
    function test_mergeInsideProposalCreatedIsBlockedByWrittenState() public {
        _mintMember(m1, "Alice");
        ProposalBot bot = new ProposalBot(stake, submit, address(token));
        token.transfer(address(bot), 1e23);
        root.transfer(address(bot), 1e23);
        uint256 botId = _mintMember(address(bot), "Bot");
        bot.configure(botId, 1);
        bot.approveAll(address(token), address(stake), type(uint256).max);
        bot.approveAll(address(root), address(stake), type(uint256).max);
        bot.stakeLiquidity(1e20, WAIT_MIN);

        uint256 round = phase.currentPhase();
        ProposalBody memory body = ProposalBody({
            title: "bot proposal",
            details: "",
            target: address(bot),
            targetMode: TargetMode.Callback,
            targetData: new bytes[](0)
        });
        bot.submitProposal(body);

        _true(bot.mergeAttempted(), "callback ran");
        _eqBytes32(
            keccak256(bot.mergeRevertData()),
            keccak256(abi.encodeWithSelector(IStakeErrors.StakeRightsUsed.selector, address(token), round, botId)),
            "merge reverted with StakeRightsUsed"
        );

        _advancePhase();
        bot.mergeStake();
        (uint256 sharesAfterMerge,,,,,,) = stake.memberStake(address(token), botId);
        _eq(sharesAfterMerge, 0, "merge succeeds in a fresh round");
    }

    /// @notice Boost deposits stay in the contract: a settlement burns only what the pair just paid
    ///         out, so the balance never drops below the recorded boost.
    function test_settlementNeverTouchesBoostBacking() public {
        _mintMember(m1, "Alice");
        _mintMember(m2, "Bob");
        _stake(m1, 1, 1e20, WAIT_MIN);
        _stake(m2, 2, 1e20, WAIT_MIN);

        vm.startPrank(m1);
        token.approve(address(stake), 1e18);
        stake.stakeBoost(address(token), 1.5e17, WAIT_MIN, 1);
        vm.stopPrank();
        vm.startPrank(m2);
        token.approve(address(stake), 1e18);
        stake.stakeBoost(address(token), 1.5e17, WAIT_MIN, 2);
        vm.stopPrank();

        (, , , , uint256 totalBoostShares, ,,) = stake.totalStake(address(token));
        _eq(totalBoostShares, 3e17, "boost recorded");
        _eq(token.balanceOf(address(stake)), 3e17, "boost is held");

        token.transfer(address(pair), 3e20);
        pair.sync();

        stake.settleFees(address(token));

        (, , , , uint256 boostAfter, ,,) = stake.totalStake(address(token));
        _eq(boostAfter, 3e17, "boost record untouched by settlement");
        _true(token.balanceOf(address(stake)) >= 3e17, "boost still fully backed after settlement");
    }

    /// @notice `_canBurn` blocks a `pair.burn` that would floor to zero; the member receives the LP
    ///         instead of the transaction reverting.
    function test_zeroValueBurnFallsBackToLpTransfer() public {
        _mintMember(m1, "Alice");
        _mintMember(m2, "Bob");

        vm.startPrank(m1);
        token.approve(address(stake), type(uint256).max);
        root.approve(address(stake), type(uint256).max);
        stake.stakeLiquidity(address(token), 1e6, 1e7, SLIPPAGE_ANY, WAIT_MIN, 1);
        vm.stopPrank();

        vm.startPrank(m2);
        token.approve(address(stake), type(uint256).max);
        root.approve(address(stake), type(uint256).max);
        (, uint256 dustShares) = stake.stakeLiquidity(address(token), 1, 10, SLIPPAGE_ANY, WAIT_MIN, 2);
        vm.stopPrank();
        _true(dustShares > 0 && dustShares <= 3, "dust share count");

        vm.prank(m2);
        stake.unstake(address(token), 2);
        _advancePhase();
        _advancePhase();

        uint256 tokenBalanceBefore = token.balanceOf(m2);
        vm.prank(m2);
        stake.withdraw(address(token), 2);

        _eq(token.balanceOf(m2), tokenBalanceBefore, "no token payout");
        _eq(pair.balanceOf(m2), dustShares, "LP handed to the member instead of burning");
    }
}
