// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Stake} from "../src/Stake.sol";
import {Submit} from "../src/Submit.sol";
import {Vote} from "../src/Vote.sol";
import {Phase} from "../src/Phase.sol";
import {MemberNFT} from "../src/MemberNFT.sol";
import {LOVE20Token} from "../src/LOVE20Token.sol";
import {RealV2Factory, RealV2Pair, RealV2Router} from "./compat/RealV2.sol";

interface StakeVm {
    function roll(uint256 blockNumber) external;
    function warp(uint256 timestamp) external;
    function prank(address sender) external;
    function startPrank(address sender) external;
    function stopPrank() external;
    function getNonce(address account) external view returns (uint256);
    function computeCreateAddress(address deployer, uint256 nonce) external view returns (address);
}

contract MockLaunchRegistry {
    mapping(address => bool) public isLOVE20Token;

    function register(address tokenAddress) external {
        isLOVE20Token[tokenAddress] = true;
    }
}

/// @title StakeInvariant - share, vote and asset ledgers of Stake over a real V2 pair
/// @notice The handler below is the only writer: it stakes, boosts, unlocks, withdraws, merges and
///         settles against the real Stake on a faithful Uniswap V2 subset, so every invariant is
///         checked on states the protocol can actually reach.
/// @dev Load-bearing: every member is a fixed identity in `_memberIds` and the handler never mints
///      new ones, because the invariants compare community totals against the sum over members. A
///      handler that could add identities would have to extend that sum too.
contract StakeInvariantTest {
    StakeVm private constant vm = StakeVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant BLOCKS_PER_PHASE = 100;
    uint256 private constant WAIT_MIN = 1;
    uint256 private constant WAIT_MAX = 8;
    uint256 private constant FEE_RATIO = 2.5e15;

    uint256 private constant MEMBER_COUNT = 4;
    uint256 private constant TOKEN_INITIAL_SUPPLY = 1e24;
    uint256 private constant TOKEN_MAX_SUPPLY = 1e27;
    uint256 private constant MEMBER_TOKEN_BALANCE = 1e22;
    uint256 private constant MEMBER_ROOT_BALANCE = 1e23;

    Phase private phase;
    MemberNFT private nft;
    Stake private stake;
    Submit private submit;
    Vote private vote;
    MockLaunchRegistry private registry;
    LOVE20Token private token;
    LOVE20Token private root;
    RealV2Factory private factory;
    RealV2Pair private pair;

    address[] private _members;
    uint256[] private _memberIds;

    function setUp() public {
        factory = new RealV2Factory();
        RealV2Router router = new RealV2Router(address(factory));

        root = new LOVE20Token("Wrapped BNB", "WBNB", 1e27, 1e28, address(this), address(this), address(this));
        token = new LOVE20Token(
            "Community", "CMTY", TOKEN_INITIAL_SUPPLY, TOKEN_MAX_SUPPLY, address(this), address(this), address(root)
        );

        phase = new Phase(0, BLOCKS_PER_PHASE, BLOCKS_PER_PHASE, 1e18, 50);
        registry = new MockLaunchRegistry();
        registry.register(address(token));
        nft = new MemberNFT(1e18, 7, 2, 32, address(token));

        uint256 nonce = vm.getNonce(address(this));
        address predictedVote = vm.computeCreateAddress(address(this), nonce + 2);

        stake = new Stake(
            address(phase),
            address(nft),
            predictedVote,
            address(registry),
            address(router),
            address(factory),
            WAIT_MIN,
            WAIT_MAX,
            FEE_RATIO,
            2,
            5
        );
        submit = new Submit(address(phase), address(stake), address(nft), 1e16);
        vote = new Vote(address(phase), address(stake), address(submit), address(nft));
        require(address(vote) == predictedVote, "predicted vote address");

        factory.createPair(address(token), address(root));
        pair = RealV2Pair(factory.getPair(address(token), address(root)));

        _members.push(address(0xA11CE));
        _members.push(address(0xB0B));
        _members.push(address(0xCA401));
        _members.push(address(0xDA4E));

        string[4] memory names = ["alice", "bob", "carol", "dave"];
        for (uint256 i = 0; i < MEMBER_COUNT; i++) {
            address member = _members[i];
            token.transfer(member, MEMBER_TOKEN_BALANCE);
            root.transfer(member, MEMBER_ROOT_BALANCE);

            vm.startPrank(member);
            token.approve(address(nft), type(uint256).max);
            (uint256 memberId,) = nft.mint(names[i]);
            token.approve(address(stake), type(uint256).max);
            root.approve(address(stake), type(uint256).max);
            vm.stopPrank();

            _memberIds.push(memberId);
        }
    }

    function targetContracts() public view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(this);
    }

    // ============ Handler ============

    function stakeLiquidity(uint256 memberIndex, uint256 tokenAmount, uint256 parentAmount, uint256 phases) public {
        memberIndex = bound(memberIndex, 0, MEMBER_COUNT - 1);
        uint256 memberId = _memberIds[memberIndex];
        (, , uint256 currentPhases, uint256 unlockRequestPhase, , ,) = stake.memberStake(address(token), memberId);
        if (unlockRequestPhase != 0) return;

        tokenAmount = bound(tokenAmount, 1e15, 1e20);
        parentAmount = bound(parentAmount, 1e15, 1e20);
        phases = bound(phases, currentPhases < WAIT_MIN ? WAIT_MIN : currentPhases, WAIT_MAX);

        vm.prank(_members[memberIndex]);
        stake.stakeLiquidity(address(token), tokenAmount, parentAmount, phases, memberId);
    }

    function stakeBoost(uint256 memberIndex, uint256 boostAmount, uint256 phases) public {
        memberIndex = bound(memberIndex, 0, MEMBER_COUNT - 1);
        uint256 memberId = _memberIds[memberIndex];
        (uint256 liquidityShares, , uint256 currentPhases, uint256 unlockRequestPhase, , ,) =
            stake.memberStake(address(token), memberId);
        if (liquidityShares == 0 || unlockRequestPhase != 0) return;

        boostAmount = bound(boostAmount, 1, 1e20);
        phases = bound(phases, currentPhases < WAIT_MIN ? WAIT_MIN : currentPhases, WAIT_MAX);

        vm.prank(_members[memberIndex]);
        stake.stakeBoost(address(token), boostAmount, phases, memberId);
    }

    function unlock(uint256 memberIndex) public {
        memberIndex = bound(memberIndex, 0, MEMBER_COUNT - 1);
        uint256 memberId = _memberIds[memberIndex];
        (uint256 liquidityShares, , , uint256 unlockRequestPhase, , ,) = stake.memberStake(address(token), memberId);
        if (liquidityShares == 0 || unlockRequestPhase != 0) return;

        vm.prank(_members[memberIndex]);
        stake.unstake(address(token), memberId);
    }

    function withdraw(uint256 memberIndex) public {
        memberIndex = bound(memberIndex, 0, MEMBER_COUNT - 1);
        uint256 memberId = _memberIds[memberIndex];
        if (!stake.canWithdraw(address(token), memberId)) return;

        vm.prank(_members[memberIndex]);
        stake.withdraw(address(token), memberId);
    }

    function merge(uint256 sourceIndex, uint256 targetIndex) public {
        sourceIndex = bound(sourceIndex, 0, MEMBER_COUNT - 1);
        targetIndex = bound(targetIndex, 0, MEMBER_COUNT - 1);
        if (sourceIndex == targetIndex) return;

        uint256 sourceMemberId = _memberIds[sourceIndex];
        (uint256 liquidityShares, , , uint256 unlockRequestPhase, , ,) =
            stake.memberStake(address(token), sourceMemberId);
        if (liquidityShares == 0 || unlockRequestPhase != 0) return;

        vm.prank(_members[sourceIndex]);
        stake.mergeStake(address(token), sourceMemberId, _memberIds[targetIndex]);
    }

    function settleFees() public {
        stake.settleFees(address(token));
    }

    function advanceRound(uint256 count) public {
        uint256 steps = bound(count, 1, 2);
        vm.roll(block.number + BLOCKS_PER_PHASE * steps);
        vm.warp(block.timestamp + BLOCKS_PER_PHASE * steps);
    }

    // ============ Invariants: shares ============

    /// @notice The community liquidity-share total is the sum of the member shares, so a merge or a
    ///         withdrawal can never leave one side of that identity behind.
    function invariant_LiquiditySharesMatchMemberSum() public view {
        uint256 sum;
        for (uint256 i = 0; i < MEMBER_COUNT; i++) {
            (uint256 liquidityShares,,,,,,) = stake.memberStake(address(token), _memberIds[i]);
            sum += liquidityShares;
        }
        (uint256 totalLiquidityShares,,,,,,,) = stake.totalStake(address(token));
        assert(sum == totalLiquidityShares);
    }

    function invariant_BoostSharesMatchMemberSum() public view {
        uint256 sum;
        for (uint256 i = 0; i < MEMBER_COUNT; i++) {
            (, uint256 boostShares,,,,,) = stake.memberStake(address(token), _memberIds[i]);
            sum += boostShares;
        }
        (,,,, uint256 totalBoostShares,,,) = stake.totalStake(address(token));
        assert(sum == totalBoostShares);
    }

    /// @notice Every recorded boost share is still backed by a token the contract actually holds.
    function invariant_BoostSharesAreFullyBacked() public view {
        (,,,, uint256 totalBoostShares,,,) = stake.totalStake(address(token));
        assert(token.balanceOf(address(stake)) >= totalBoostShares);
    }

    // ============ Invariants: the LP ledger vs the real balance ============

    /// @notice The accounted LP can never exceed the LP the contract holds. Donations only widen the
    ///         gap; nothing may narrow it below zero.
    function invariant_AccountedLpWithinHeldBalance() public view {
        (, uint256 totalLp,,,,,,) = stake.totalStake(address(token));
        assert(totalLp <= pair.balanceOf(address(stake)));
    }

    /// @notice The principal ledger (used as the boost-cap base) can never exceed what was deposited
    ///         net of withdrawals, which itself can never exceed the token balance held for boosts
    ///         plus the pair's token reserve attributable to the stake.
    function invariant_PrincipalLedgerWithinHeldTokens() public view {
        uint256 principal = stake.liquidityTokenAmount(address(token));
        (uint256 reserveToken,,) = pair.getReserves();
        (,,,, uint256 totalBoostShares,,,) = stake.totalStake(address(token));
        assert(principal + totalBoostShares <= token.balanceOf(address(stake)) + reserveToken);
    }

    // ============ Invariants: the round ledgers ============

    /// @notice `Added - Removed` is the same thing as the sum over members of the round's valid votes.
    function invariant_ValidGovVotesMatchMemberSum() public view {
        uint256 round = phase.currentPhase();
        uint256 sum;
        for (uint256 i = 0; i < MEMBER_COUNT; i++) {
            sum += stake.validGovVotes(address(token), round, _memberIds[i]);
        }
        assert(stake.totalValidGovVotes(address(token), round) == sum);
    }

    function invariant_ValidBoostSharesMatchMemberSum() public view {
        uint256 round = phase.currentPhase();
        uint256 sum;
        for (uint256 i = 0; i < MEMBER_COUNT; i++) {
            sum += stake.validBoostShares(address(token), round, _memberIds[i]);
        }
        assert(stake.totalValidBoostShares(address(token), round) == sum);
    }

    /// @notice Both cumulative ledgers are monotone by construction, so their difference is never
    ///         negative for any round that has started.
    function invariant_RemovedNeverExceedsAdded() public view {
        uint256 currentRound = phase.currentPhase();
        for (uint256 round = 1; round <= currentRound; round++) {
            assert(
                stake.totalValidGovVotesAdded(address(token), round)
                    >= stake.totalValidGovVotesRemoved(address(token), round)
            );
            assert(
                stake.totalValidBoostSharesAdded(address(token), round)
                    >= stake.totalValidBoostSharesRemoved(address(token), round)
            );
        }
    }

    /// @notice A position with an unlock request in flight has no vote weight and no valid boost left,
    ///         which is what makes "vote, then unlock, then vote again" impossible.
    function invariant_UnlockZeroesTheCurrentRound() public view {
        uint256 round = phase.currentPhase();
        for (uint256 i = 0; i < MEMBER_COUNT; i++) {
            (, , , uint256 unlockRequestPhase,,,) = stake.memberStake(address(token), _memberIds[i]);
            if (unlockRequestPhase == 0) continue;
            assert(stake.validGovVotes(address(token), round, _memberIds[i]) == 0);
            assert(stake.validBoostShares(address(token), round, _memberIds[i]) == 0);
        }
    }

    /// @notice Boosting never adds vote weight on its own: only raising the promised waiting period
    ///         does, and that path is bounded by the same per-round ledger as staking.
    function invariant_BoostDoesNotMintVotesWithoutLiquidity() public view {
        uint256 round = phase.currentPhase();
        for (uint256 i = 0; i < MEMBER_COUNT; i++) {
            (uint256 liquidityShares,,,,,,) = stake.memberStake(address(token), _memberIds[i]);
            if (liquidityShares != 0) continue;
            assert(stake.validGovVotes(address(token), round, _memberIds[i]) == 0);
        }
    }

    /// @notice The withdraw path is the one the fuzzer reaches least: it needs a matured unlock
    ///         request, which costs several round advances. Walk it once and re-check every invariant
    ///         afterwards, so "accounted LP never exceeds held LP" is not only asserted on states the
    ///         fuzzer happens to reach.
    function test_withdrawPathHoldsEveryInvariant() public {
        stakeLiquidity(0, 5e17, 5e17, WAIT_MIN);
        stakeLiquidity(1, 1e18, 3e17, WAIT_MIN);

        (, , , uint256 unlockRequestPhase,,,) = stake.memberStake(address(token), _memberIds[0]);
        require(unlockRequestPhase == 0, "position open");

        unlock(0);
        (, , , unlockRequestPhase,,,) = stake.memberStake(address(token), _memberIds[0]);
        require(unlockRequestPhase != 0, "unlock recorded");

        advanceRound(1);
        advanceRound(1);
        require(stake.canWithdraw(address(token), _memberIds[0]), "unlock matured");

        uint256 balanceBefore = pair.balanceOf(address(stake));
        withdraw(0);
        require(pair.balanceOf(address(stake)) < balanceBefore, "withdraw moved liquidity");

        invariant_LiquiditySharesMatchMemberSum();
        invariant_BoostSharesMatchMemberSum();
        invariant_BoostSharesAreFullyBacked();
        invariant_AccountedLpWithinHeldBalance();
        invariant_PrincipalLedgerWithinHeldTokens();
        invariant_ValidGovVotesMatchMemberSum();
        invariant_ValidBoostSharesMatchMemberSum();
        invariant_RemovedNeverExceedsAdded();
        invariant_UnlockZeroesTheCurrentRound();
        invariant_BoostDoesNotMintVotesWithoutLiquidity();
    }

    function bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (x < min || x > max) {
            return min + (x % (max - min + 1));
        }
        return x;
    }
}
