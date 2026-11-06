// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Test} from "@forge-std/Test.sol";
import {Vm} from "@forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Stake} from "../src/Stake.sol";
import {LOVE20Token} from "../src/LOVE20Token.sol";
import {MemberNFT} from "../src/MemberNFT.sol";
import {IStakeEvents} from "../src/interfaces/IStake.sol";
import {MockLaunch, MockPairFactory, MockPhase, MockSubmit, MockVote} from "./utils/StakeMocks.sol";

interface IPairToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Faithful subset of an Uniswap V2 pair: `getReserves()` is a stored snapshot that only
/// mint/burn/sync refreshes, so a bare transfer into the pair stays invisible until someone calls
/// sync() — which is permissionless in V2.
contract V2PairLike {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;
    uint32 public blockTimestampLast;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function sync() external {
        _update();
    }

    function skim(address to) external {
        uint256 b0 = IPairToken(token0).balanceOf(address(this));
        uint256 b1 = IPairToken(token1).balanceOf(address(this));
        if (b0 > uint256(reserve0)) IPairToken(token0).transfer(to, b0 - uint256(reserve0));
        if (b1 > uint256(reserve1)) IPairToken(token1).transfer(to, b1 - uint256(reserve1));
    }

    function mint(address to) external returns (uint256 liquidity) {
        uint256 b0 = IPairToken(token0).balanceOf(address(this));
        uint256 b1 = IPairToken(token1).balanceOf(address(this));
        uint256 amount0 = b0 - uint256(reserve0);
        uint256 amount1 = b1 - uint256(reserve1);

        if (totalSupply == 0) {
            liquidity = _sqrt(amount0 * amount1);
        } else {
            liquidity = _min((amount0 * totalSupply) / uint256(reserve0), (amount1 * totalSupply) / uint256(reserve1));
        }
        require(liquidity > 0, "INSUFFICIENT_LIQUIDITY_MINTED");

        balanceOf[to] += liquidity;
        totalSupply += liquidity;
        reserve0 = uint112(b0);
        reserve1 = uint112(b1);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        require(amount0Out > 0 || amount1Out > 0, "INSUFFICIENT_OUTPUT_AMOUNT");
        if (amount0Out > 0) IPairToken(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IPairToken(token1).transfer(to, amount1Out);
        _update();
    }

    function burn(address to) external returns (uint256 amount0, uint256 amount1) {
        uint256 liquidity = balanceOf[address(this)];
        uint256 b0 = IPairToken(token0).balanceOf(address(this));
        uint256 b1 = IPairToken(token1).balanceOf(address(this));
        require(liquidity > 0, "INSUFFICIENT_LIQUIDITY");

        amount0 = (liquidity * b0) / totalSupply;
        amount1 = (liquidity * b1) / totalSupply;
        require(amount0 > 0 && amount1 > 0, "INSUFFICIENT_LIQUIDITY_BURNED");

        balanceOf[address(this)] = 0;
        totalSupply -= liquidity;
        IPairToken(token0).transfer(to, amount0);
        IPairToken(token1).transfer(to, amount1);

        _update();
    }

    function _update() private {
        reserve0 = uint112(IPairToken(token0).balanceOf(address(this)));
        reserve1 = uint112(IPairToken(token1).balanceOf(address(this)));
    }

    function _sqrt(uint256 y) private pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}

/// @notice Constant-product router that settles against the pair and re-syncs its reserves.
contract PoCRouter {
    address public pairAddress;

    function setPair(address pair) external {
        pairAddress = pair;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts)
    {
        V2PairLike pair = V2PairLike(pairAddress);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool inputIsToken0 = path[0] == pair.token0();
        uint256 reserveIn = inputIsToken0 ? r0 : r1;
        uint256 reserveOut = inputIsToken0 ? r1 : r0;
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = (amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997);
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        IPairToken input = IPairToken(path[0]);
        V2PairLike pair = V2PairLike(pairAddress);
        amounts = this.getAmountsOut(amountIn, path);
        require(amounts[1] >= amountOutMin, "INSUFFICIENT_OUTPUT_AMOUNT");
        input.transferFrom(msg.sender, pairAddress, amountIn);
        if (path[1] == pair.token0()) {
            pair.swap(amounts[1], 0, to, "");
        } else {
            pair.swap(0, amounts[1], to, "");
        }
    }
}

contract StakeDonationTest is Test {
    uint256 internal constant FEE_SETTLEMENT_RATIO = 25e14; // 0.25%, current profile
    uint256 internal constant SEED = 100_000e18;
    uint256 internal constant STAKE_AMOUNT = 20_000e18;
    uint256 internal constant DONATION = 900_000e18;

    bytes32 internal constant FEE_RECLASSIFIED_TOPIC =
        keccak256("FeeReclassified(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256)");
    bytes32 internal constant LIQUIDITY_STAKED_TOPIC = keccak256(
        "LiquidityStaked(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
    );
    bytes32 internal constant STAKE_WITHDRAWN_TOPIC = keccak256(
        "StakeWithdrawn(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
    );
    bytes32 internal constant FEES_SETTLED_TOPIC =
        keccak256("FeesSettled(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256)");

    struct LedgerFold {
        uint256 fee;
        uint256 withdrawable;
        bool seenFeeReclassified;
        bool seenLiquidityStaked;
        bool seenStakeWithdrawn;
        bool seenFeesSettled;
    }

    Stake internal stake;
    MemberNFT internal memberNFT;
    MockPhase internal phase;
    MockLaunch internal launch;
    PoCRouter internal router;
    MockPairFactory internal pairFactory;
    V2PairLike internal pair;

    LOVE20Token internal parentToken;
    LOVE20Token internal childToken;

    address internal staker = address(0xA11CE);
    address internal attacker = makeAddr("attacker");
    uint256 internal stakerMemberId;

    function setUp() public {
        phase = new MockPhase();
        phase.setPhase(1);
        launch = new MockLaunch();
        router = new PoCRouter();
        pairFactory = new MockPairFactory();

        MockVote vote = new MockVote();
        vote.setSubmitAddress(address(new MockSubmit()));

        parentToken = new LOVE20Token(
            "Parent Token", "PARENT", 1_000_000e18, 2_000_000e18, address(this), address(this), address(this)
        );
        memberNFT = new MemberNFT(1e8, 7, 10, 32, address(parentToken));

        childToken = new LOVE20Token(
            "Child Token", "CHILD", 1_000_000e18, 100_000_000e18, address(this), address(this), address(parentToken)
        );
        launch.register(address(childToken));

        pair = new V2PairLike(address(childToken), address(parentToken));
        pairFactory.setPair(address(childToken), address(parentToken), address(pair));
        router.setPair(address(pair));

        stake = new Stake(
            address(phase),
            address(memberNFT),
            address(vote),
            address(launch),
            address(router),
            address(pairFactory),
            1,
            100,
            FEE_SETTLEMENT_RATIO,
            2,
            5
        );

        childToken.transfer(address(pair), SEED);
        parentToken.transfer(address(pair), SEED);
        pair.sync();

        childToken.transfer(staker, 200_000e18);
        parentToken.transfer(staker, 200_000e18);
        childToken.mint(attacker, DONATION);

        vm.prank(staker);
        parentToken.approve(address(memberNFT), type(uint256).max);
        vm.prank(staker);
        (stakerMemberId,) = memberNFT.mint("staker");

        vm.startPrank(staker);
        childToken.approve(address(stake), type(uint256).max);
        parentToken.approve(address(stake), type(uint256).max);
        stake.stakeLiquidity(address(childToken), STAKE_AMOUNT, STAKE_AMOUNT, 1e18, 1, stakerMemberId);
        vm.stopPrank();
    }

    function _withdrawableLp() internal view returns (uint256 withdrawable) {
        (,, withdrawable,,,,) = stake.totalStake(address(childToken));
    }

    function _feeLp() internal view returns (uint256 fee) {
        (,,, fee,,,) = stake.totalStake(address(childToken));
    }

    function _stakedLpSqrtK(uint256 lpAmount) internal view returns (uint256) {
        (uint112 reserveChild, uint112 reserveParent,) = pair.getReserves();
        return Math.sqrt(uint256(reserveChild) * uint256(reserveParent)) * lpAmount / pair.totalSupply();
    }

    function _stakeLogIndex(Vm.Log[] memory logs, bytes32 topic) internal view returns (uint256) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(stake) && logs[i].topics[0] == topic) return i;
        }
        return type(uint256).max;
    }

    /// Control: with no donation, withdrawing pays the pro-rata share of the pair.
    function testWithdrawPaysProRataWhenReservesOnlyMoveWithLiquidity() public {
        uint256 lp = IPairToken(address(pair)).balanceOf(address(stake));
        assertEq(_feeLp(), 0, "no fee without swap volume");
        assertEq(_withdrawableLp(), lp, "staker LP fully withdrawable");

        uint256 expectedChild = lp * childToken.balanceOf(address(pair)) / pair.totalSupply();
        uint256 expectedParent = lp * parentToken.balanceOf(address(pair)) / pair.totalSupply();
        uint256 childPaid = childToken.balanceOf(staker);
        uint256 parentPaid = parentToken.balanceOf(staker);

        vm.prank(staker);
        stake.unstake(address(childToken), stakerMemberId);
        phase.setPhase(3);
        vm.prank(staker);
        stake.withdraw(address(childToken), stakerMemberId);

        assertApproxEqRel(childToken.balanceOf(staker) - childPaid, expectedChild, 1e15, "child side pro-rata");
        assertApproxEqRel(parentToken.balanceOf(staker) - parentPaid, expectedParent, 1e15, "parent side pro-rata");
    }

    /// Donate + sync + settleFees: the growth is reclassified, while the staker's baseline
    /// principal value (sqrtK basis) is preserved.
    function testDonationThenSyncReclassifiesGrowthPreservingPrincipalValue() public {
        uint256 withdrawableBefore = _withdrawableLp();
        assertEq(_feeLp(), 0);
        uint256 baselineSqrtK = _stakedLpSqrtK(withdrawableBefore);

        vm.prank(attacker);
        childToken.transfer(address(pair), DONATION);
        pair.sync();

        uint256 currentSqrtK = _stakedLpSqrtK(withdrawableBefore);
        uint256 settlementUnit = Math.mulDiv(pair.totalSupply(), FEE_SETTLEMENT_RATIO, 1e18);
        stake.settleFees(address(childToken));

        uint256 withdrawableAfter = _withdrawableLp();
        assertLt(withdrawableAfter, withdrawableBefore * 5 / 10, "withdrawable LP quantity reclassified");
        assertGt(_feeLp(), withdrawableBefore / 2, "majority of the staker LP quantity reclassified as fee");
        assertApproxEqRel(
            withdrawableAfter * currentSqrtK,
            withdrawableBefore * baselineSqrtK,
            1e15,
            "principal sqrtK value preserved"
        );
        assertEq(
            _feeLp() + settlementUnit + withdrawableAfter,
            withdrawableBefore,
            "fee ledger accounts for the reclassified LP"
        );
    }

    function testFeeReclassifiedEvent() public {
        uint256 withdrawableBefore = _withdrawableLp();
        uint256 baselineSqrtK = _stakedLpSqrtK(withdrawableBefore);

        vm.prank(attacker);
        childToken.transfer(address(pair), DONATION);
        pair.sync();

        uint256 currentSqrtK = _stakedLpSqrtK(withdrawableBefore);
        uint256 expectedWithdrawable = withdrawableBefore * baselineSqrtK / currentSqrtK;
        uint256 delta = withdrawableBefore - expectedWithdrawable;

        vm.expectEmit(true, true, false, true, address(stake));
        emit IStakeEvents.FeeReclassified({
            tokenAddress: address(childToken),
            round: 1,
            feeLpAdded: delta,
            withdrawableLpRemoved: delta,
            totalFeeLp: delta,
            totalWithdrawableLp: expectedWithdrawable,
            sqrtKOfLp: currentSqrtK,
            pairTotalSupply: pair.totalSupply()
        });
        stake.settleFees(address(childToken));
    }

    function testFeeReclassifiedOnNewStake() public {
        uint256 withdrawableBefore = _withdrawableLp();
        uint256 baselineSqrtK = _stakedLpSqrtK(withdrawableBefore);

        vm.prank(attacker);
        childToken.transfer(address(pair), DONATION);
        pair.sync();

        uint256 currentSqrtK = _stakedLpSqrtK(withdrawableBefore);
        uint256 delta = withdrawableBefore - withdrawableBefore * baselineSqrtK / currentSqrtK;
        uint256 expectedWithdrawable = withdrawableBefore - delta;

        address newbie = makeAddr("newbie");
        childToken.transfer(newbie, 200_000e18);
        parentToken.transfer(newbie, 20_000e18);

        vm.startPrank(newbie);
        parentToken.approve(address(memberNFT), type(uint256).max);
        (uint256 newMemberId,) = memberNFT.mint("newbie");
        childToken.approve(address(stake), type(uint256).max);
        parentToken.approve(address(stake), type(uint256).max);

        vm.expectEmit(true, true, false, true, address(stake));
        emit IStakeEvents.FeeReclassified({
            tokenAddress: address(childToken),
            round: 1,
            feeLpAdded: delta,
            withdrawableLpRemoved: delta,
            totalFeeLp: delta,
            totalWithdrawableLp: expectedWithdrawable,
            sqrtKOfLp: currentSqrtK,
            pairTotalSupply: pair.totalSupply()
        });
        stake.stakeLiquidity(address(childToken), 85_000e18, 10_000e18, 1e18, 1, newMemberId);
        vm.stopPrank();
    }

    /// With an opening fee balance the increment and the post total differ, pinning the two
    /// fields apart; a fixture that starts from a zero fee cannot tell them apart.
    function testFeeReclassifiedCarriesPostTotalAfterPriorFee() public {
        vm.prank(attacker);
        childToken.transfer(address(pair), DONATION);
        pair.sync();
        stake.settleFees(address(childToken));

        uint256 feeBefore = _feeLp();
        uint256 withdrawableBefore = _withdrawableLp();
        assertGt(feeBefore, 0, "first settlement booked a fee");

        uint256 totalLpBefore = feeBefore + withdrawableBefore;
        uint256 baselineSqrtK = _stakedLpSqrtK(totalLpBefore);

        childToken.mint(attacker, DONATION);
        vm.prank(attacker);
        childToken.transfer(address(pair), DONATION);
        pair.sync();

        uint256 currentSqrtK = _stakedLpSqrtK(totalLpBefore);
        uint256 expectedWithdrawable = withdrawableBefore * baselineSqrtK / currentSqrtK;
        uint256 delta = withdrawableBefore - expectedWithdrawable;
        assertGt(delta, 0, "second donation reclassifies");

        phase.setPhase(2);
        vm.expectEmit(true, true, false, true, address(stake));
        emit IStakeEvents.FeeReclassified({
            tokenAddress: address(childToken),
            round: 2,
            feeLpAdded: delta,
            withdrawableLpRemoved: delta,
            totalFeeLp: feeBefore + delta,
            totalWithdrawableLp: expectedWithdrawable,
            sqrtKOfLp: currentSqrtK,
            pairTotalSupply: pair.totalSupply()
        });
        stake.settleFees(address(childToken));
    }

    /// `withdraw` reclassifies in its settlement segment; the event must fire there too.
    function testFeeReclassifiedOnWithdraw() public {
        uint256 withdrawableBefore = _withdrawableLp();
        uint256 baselineSqrtK = _stakedLpSqrtK(withdrawableBefore);

        vm.prank(attacker);
        childToken.transfer(address(pair), DONATION);
        pair.sync();

        uint256 currentSqrtK = _stakedLpSqrtK(withdrawableBefore);
        uint256 expectedWithdrawable = withdrawableBefore * baselineSqrtK / currentSqrtK;
        uint256 delta = withdrawableBefore - expectedWithdrawable;

        vm.prank(staker);
        stake.unstake(address(childToken), stakerMemberId);
        phase.setPhase(3);

        vm.expectEmit(true, true, false, true, address(stake));
        emit IStakeEvents.FeeReclassified({
            tokenAddress: address(childToken),
            round: 3,
            feeLpAdded: delta,
            withdrawableLpRemoved: delta,
            totalFeeLp: delta,
            totalWithdrawableLp: expectedWithdrawable,
            sqrtKOfLp: currentSqrtK,
            pairTotalSupply: pair.totalSupply()
        });
        vm.prank(staker);
        stake.withdraw(address(childToken), stakerMemberId);
    }

    /// No growth, no event: `settleFees` alone does not fabricate a reclassification.
    function testNoFeeReclassifiedWithoutGrowth() public {
        vm.recordLogs();
        stake.settleFees(address(childToken));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0) continue;
            assertTrue(logs[i].topics[0] != FEE_RECLASSIFIED_TOPIC, "unexpected FeeReclassified");
        }
    }

    /// Once reserves are re-read the donation is sunk, but it still counts as fee.
    function testDonationIsSunkAfterSync() public {
        uint256 withdrawableBefore = _withdrawableLp();

        // While the reserves are stale the donation is skimmable and settleFees is inert.
        vm.prank(attacker);
        childToken.transfer(address(pair), DONATION);
        vm.prank(attacker);
        pair.skim(attacker);
        assertEq(childToken.balanceOf(attacker), DONATION, "reversible while reserves are stale");
        stake.settleFees(address(childToken));
        assertEq(_withdrawableLp(), withdrawableBefore, "no fake fee yet");

        // A second donation that gets folded into reserves can no longer be recovered by its sender.
        vm.prank(attacker);
        childToken.transfer(address(pair), DONATION);
        assertEq(childToken.balanceOf(attacker), 0);
        pair.sync();
        vm.prank(attacker);
        pair.skim(attacker);
        assertEq(childToken.balanceOf(attacker), 0, "locked in once reserves were re-read");
        stake.settleFees(address(childToken));
        assertLt(_withdrawableLp(), withdrawableBefore, "fee booked");
    }

    /// No explicit sync() is needed: any later mint/swap/burn by anyone folds the donation into reserves.
    function testThirdPartyMintAlsoTriggersReclassification() public {
        uint256 withdrawableBefore = _withdrawableLp();

        vm.prank(attacker);
        childToken.transfer(address(pair), DONATION);

        address thirdParty = makeAddr("thirdParty");
        childToken.mint(thirdParty, 10_000e18);
        parentToken.transfer(thirdParty, 90_000e18);
        // An ordinary liquidity add: V2 mint() re-reads balances, so the donation becomes a reserve.
        vm.startPrank(thirdParty);
        childToken.transfer(address(pair), 10_000e18);
        parentToken.transfer(address(pair), 90_000e18);
        pair.mint(thirdParty);
        vm.stopPrank();

        stake.settleFees(address(childToken));

        assertLt(_withdrawableLp(), withdrawableBefore / 2, "third-party mint triggered reclassification");
        assertGt(_feeLp(), withdrawableBefore / 2, "growth LP booked");
    }

    /// Repeating the donation in later rounds keeps reclassifying growth: there is no per-round cap.
    function testDonationCanRepeat() public {
        uint256 withdrawable = _withdrawableLp();
        uint256 lastWithdrawable = withdrawable;

        for (uint256 round = 2; round <= 6; round++) {
            phase.setPhase(round);
            childToken.mint(attacker, DONATION / 10);
            vm.prank(attacker);
            childToken.transfer(address(pair), DONATION / 10);
            pair.sync();
            stake.settleFees(address(childToken));

            assertLt(_withdrawableLp(), lastWithdrawable, "withdrawable LP shrinks every round");
            lastWithdrawable = _withdrawableLp();
        }

        assertLt(lastWithdrawable, withdrawable * 7 / 10, "staker LP quantity keeps shrinking");
    }

    /// Release is sized off the pair's LP supply; once the remaining fee LP covers one unit it
    /// keeps burning after the last staker leaves, with no new deposit.
    function testFeeLpKeepsReleasingWithoutStake() public {
        vm.prank(attacker);
        childToken.transfer(address(pair), DONATION);
        pair.sync();
        stake.settleFees(address(childToken));

        vm.prank(staker);
        stake.unstake(address(childToken), stakerMemberId);
        phase.setPhase(3);
        vm.prank(staker);
        stake.withdraw(address(childToken), stakerMemberId);

        uint256 stranded = _feeLp();
        assertEq(_withdrawableLp(), 0, "no withdrawable LP left");
        assertGt(stranded, 0, "fee LP left over");
        assertEq(IPairToken(address(pair)).balanceOf(address(stake)), stranded, "only the fee LP remains");

        uint256 fee = stranded;
        for (uint256 round = 4; round <= 14; round++) {
            phase.setPhase(round);
            uint256 unit = Math.mulDiv(pair.totalSupply(), FEE_SETTLEMENT_RATIO, 1e18);
            stake.settleFees(address(childToken));
            assertEq(_feeLp(), fee - unit, "one unit released from the fee ledger");
            fee -= unit;
        }

        assertLt(fee, stranded, "fee LP keeps shrinking without new stake");
        assertEq(_withdrawableLp(), 0, "withdrawable stays zero");
        assertEq(IPairToken(address(pair)).balanceOf(address(stake)), fee, "only the fee LP remains");
    }

    /// A new deposit joins the accounted total, so the release continues and its unit covers
    /// the restored withdrawable base as well.
    function testNewStakeAfterStrandedFeeKeepsReleasing() public {
        vm.prank(attacker);
        childToken.transfer(address(pair), DONATION);
        pair.sync();
        stake.settleFees(address(childToken));

        vm.prank(staker);
        stake.unstake(address(childToken), stakerMemberId);
        phase.setPhase(3);
        vm.prank(staker);
        stake.withdraw(address(childToken), stakerMemberId);

        uint256 stranded = _feeLp();
        phase.setPhase(4);
        stake.settleFees(address(childToken));
        assertLt(_feeLp(), stranded, "released without a stake");

        address newbie = makeAddr("newbie");
        childToken.transfer(newbie, 200_000e18);
        parentToken.transfer(newbie, 20_000e18);
        (uint112 reserveChild, uint112 reserveParent,) = pair.getReserves();
        uint256 depositParent = 10_000e18;
        uint256 depositChild = depositParent * uint256(reserveChild) / uint256(reserveParent);

        vm.startPrank(newbie);
        parentToken.approve(address(memberNFT), type(uint256).max);
        (uint256 newMemberId,) = memberNFT.mint("newbie");
        childToken.approve(address(stake), type(uint256).max);
        parentToken.approve(address(stake), type(uint256).max);
        stake.stakeLiquidity(address(childToken), depositChild, depositParent, 1e18, 1, newMemberId);
        vm.stopPrank();

        uint256 feeBefore = _feeLp();
        uint256 withdrawable = _withdrawableLp();
        assertGt(withdrawable, 0, "new stake restored the withdrawable base");

        phase.setPhase(5);
        uint256 settlementUnit = Math.mulDiv(pair.totalSupply(), FEE_SETTLEMENT_RATIO, 1e18);
        stake.settleFees(address(childToken));
        uint256 released = feeBefore - _feeLp();

        assertApproxEqRel(released, settlementUnit, 1e15, "0.25% of the pair LP supply");
    }

    /// The fee ledger is bounded by the community's accounted LP. When the community owns less
    /// than `FEE_SETTLEMENT_RATIO` of the pair supply, the unit is larger than the whole ledger:
    /// `settleFees` reclassifies but can never burn, even if every staked LP were fee LP.
    function testSmallStakeStaysBelowSettlementUnit() public {
        LOVE20Token smallToken = new LOVE20Token(
            "Small Token", "SMALL", 1_000_000e18, 100_000_000e18, address(this), address(this), address(parentToken)
        );
        launch.register(address(smallToken));

        V2PairLike smallPair = new V2PairLike(address(smallToken), address(parentToken));
        pairFactory.setPair(address(smallToken), address(parentToken), address(smallPair));
        router.setPair(address(smallPair));

        smallToken.transfer(address(smallPair), SEED);
        parentToken.transfer(address(smallPair), SEED);
        smallPair.sync();

        // A dominant LP position keeps the staker's share below the settlement ratio.
        smallToken.transfer(address(smallPair), SEED);
        parentToken.transfer(address(smallPair), SEED);
        smallPair.mint(address(this));

        smallToken.transfer(staker, 1_000e18);
        vm.startPrank(staker);
        smallToken.approve(address(stake), type(uint256).max);
        stake.stakeLiquidity(address(smallToken), 100e18, 100e18, 1e18, 1, stakerMemberId);
        vm.stopPrank();

        (uint256 totalLiquidityShares, uint256 totalLp,, uint256 feeLpBefore,,,) =
            stake.totalStake(address(smallToken));
        uint256 settlementUnit = Math.mulDiv(smallPair.totalSupply(), FEE_SETTLEMENT_RATIO, 1e18);
        assertGt(totalLiquidityShares, 0, "stake booked");
        assertLt(totalLp, settlementUnit, "community LP below one settlement unit");
        assertEq(feeLpBefore, 0, "no fee before growth");

        smallToken.mint(attacker, DONATION);
        vm.prank(attacker);
        smallToken.transfer(address(smallPair), DONATION);
        smallPair.sync();

        vm.recordLogs();
        stake.settleFees(address(smallToken));

        (, uint256 totalLpAfter, uint256 withdrawableAfter, uint256 feeLpAfter,,,) =
            stake.totalStake(address(smallToken));
        assertGt(feeLpAfter, 0, "growth reclassified");
        assertLt(feeLpAfter, settlementUnit, "fee still below one unit");
        assertEq(withdrawableAfter + feeLpAfter, totalLpAfter, "ledger total unchanged");
        assertEq(stake.totalBurnedToken(address(smallToken)), 0, "nothing burned");
        assertEq(IPairToken(address(smallPair)).balanceOf(address(stake)), totalLp, "stake keeps its LP");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seenReclassified;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(stake) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == FEE_RECLASSIFIED_TOPIC) seenReclassified = true;
            assertTrue(logs[i].topics[0] != FEES_SETTLED_TOPIC, "no FeesSettled below one unit");
        }
        assertTrue(seenReclassified, "reclassification still emits");
    }

    /// `s < r` does not by itself prevent settlement: `L = floor(S * r / 1e18)` still meets the
    /// trigger. This pins the exact integer boundary the prose used to overstate.
    function testSettlementAtFloorBoundary() public {
        LOVE20Token boundaryToken = new LOVE20Token(
            "Boundary Token", "BND", 1_000_000e18, 100_000_000e18, address(this), address(this), address(parentToken)
        );
        launch.register(address(boundaryToken));

        V2PairLike boundaryPair = new V2PairLike(address(boundaryToken), address(parentToken));
        pairFactory.setPair(address(boundaryToken), address(parentToken), address(boundaryPair));
        router.setPair(address(boundaryPair));

        // Dominant LP 400, community LP 1: S = 401, so s = 1/401 < r = 1/400 while
        // floor(S * r / 1e18) == 1 == L.
        boundaryToken.transfer(address(boundaryPair), 400);
        parentToken.transfer(address(boundaryPair), 400);
        boundaryPair.mint(address(this));

        boundaryToken.transfer(staker, 1);
        vm.startPrank(staker);
        boundaryToken.approve(address(stake), type(uint256).max);
        stake.stakeLiquidity(address(boundaryToken), 1, 1, 1e18, 1, stakerMemberId);
        vm.stopPrank();

        (uint256 totalLiquidityShares, uint256 totalLp,, uint256 feeLpBefore,,,) =
            stake.totalStake(address(boundaryToken));
        uint256 settlementUnit = Math.mulDiv(boundaryPair.totalSupply(), FEE_SETTLEMENT_RATIO, 1e18);
        assertEq(totalLiquidityShares, 1, "community shares");
        assertEq(totalLp, 1, "community LP");
        assertEq(feeLpBefore, 0, "no fee before growth");
        assertEq(settlementUnit, 1, "one-unit settlement at the floor boundary");
        assertLt(totalLp * 1e18, boundaryPair.totalSupply() * FEE_SETTLEMENT_RATIO, "s below r");

        // Any growth reclassifies the whole 1 LP as fee; feeLp == settlementUnit still settles.
        boundaryToken.transfer(address(boundaryPair), 1e18);
        boundaryPair.sync();

        vm.recordLogs();
        stake.settleFees(address(boundaryToken));

        (, uint256 totalLpAfter, uint256 withdrawableAfter, uint256 feeLpAfter,,,) =
            stake.totalStake(address(boundaryToken));
        assertEq(feeLpAfter, 0, "fee settled");
        assertEq(withdrawableAfter, 0, "no withdrawable LP left");
        assertEq(totalLpAfter, 0, "ledger cleared");
        assertGt(stake.totalBurnedToken(address(boundaryToken)), 0, "settlement burned");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(_stakeLogIndex(logs, FEE_RECLASSIFIED_TOPIC) != type(uint256).max, "FeeReclassified missing");
        assertTrue(_stakeLogIndex(logs, FEES_SETTLED_TOPIC) != type(uint256).max, "FeesSettled missing");
    }

    /// A stake that triggers reclassification emits `FeeReclassified` before `LiquidityStaked`.
    function testFeeReclassifiedPrecedesLiquidityStaked() public {
        vm.prank(attacker);
        childToken.transfer(address(pair), DONATION);
        pair.sync();

        address newbie = makeAddr("orderNewbie");
        childToken.transfer(newbie, 50_000e18);
        parentToken.transfer(newbie, 10_000e18);
        vm.startPrank(newbie);
        parentToken.approve(address(memberNFT), type(uint256).max);
        (uint256 newbieMemberId,) = memberNFT.mint("orderNewbie");
        childToken.approve(address(stake), type(uint256).max);
        parentToken.approve(address(stake), type(uint256).max);
        vm.recordLogs();
        stake.stakeLiquidity(address(childToken), 50_000e18, 5_000e18, 1e18, 1, newbieMemberId);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 reclassified = _stakeLogIndex(logs, FEE_RECLASSIFIED_TOPIC);
        uint256 staked = _stakeLogIndex(logs, LIQUIDITY_STAKED_TOPIC);
        assertTrue(reclassified != type(uint256).max, "FeeReclassified missing");
        assertTrue(staked != type(uint256).max, "LiquidityStaked missing");
        assertLt(reclassified, staked, "reclassification must precede the stake event");
    }

    /// A withdrawal that settles emits `FeeReclassified` before `FeesSettled` and `StakeWithdrawn`.
    function testFeeReclassifiedPrecedesSettlementAndWithdrawal() public {
        vm.prank(attacker);
        childToken.transfer(address(pair), DONATION);
        pair.sync();

        vm.prank(staker);
        stake.unstake(address(childToken), stakerMemberId);
        phase.setPhase(3);
        vm.recordLogs();
        vm.prank(staker);
        stake.withdraw(address(childToken), stakerMemberId);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 reclassified = _stakeLogIndex(logs, FEE_RECLASSIFIED_TOPIC);
        uint256 settled = _stakeLogIndex(logs, FEES_SETTLED_TOPIC);
        uint256 withdrawn = _stakeLogIndex(logs, STAKE_WITHDRAWN_TOPIC);
        assertTrue(reclassified != type(uint256).max, "FeeReclassified missing");
        assertTrue(settled != type(uint256).max, "FeesSettled missing");
        assertTrue(withdrawn != type(uint256).max, "StakeWithdrawn missing");
        assertLt(reclassified, settled, "reclassification must precede settlement");
        assertLt(settled, withdrawn, "settlement must precede withdrawal");
    }

    /// Where the reclassified growth LP goes: an unrelated LP holder's position is valued across
    /// the same `settleFees`, so "the burn re-distributes to the other LP holders" is measured.
    function testDonationIsBurnedAndNotRedistributedToOtherLpHolders() public {
        address bystander = makeAddr("bystander");
        childToken.transfer(bystander, 10_000e18);
        parentToken.transfer(bystander, 10_000e18);
        vm.startPrank(bystander);
        childToken.transfer(address(pair), 10_000e18);
        parentToken.transfer(address(pair), 10_000e18);
        pair.mint(bystander);
        vm.stopPrank();
        uint256 bystanderLp = IPairToken(address(pair)).balanceOf(bystander);

        uint256 withdrawableBefore = _withdrawableLp();

        vm.prank(attacker);
        childToken.transfer(address(pair), DONATION);
        pair.sync();

        (uint256 valueBefore,,) = _bystanderValue(bystanderLp);
        uint256 childSupplyBefore = childToken.totalSupply();
        uint256 parentSupplyBefore = parentToken.totalSupply();
        uint256 stakeLpBefore = IPairToken(address(pair)).balanceOf(address(stake));
        uint256 poolLpBefore = pair.totalSupply();

        stake.settleFees(address(childToken));

        (uint256 valueAfter,,) = _bystanderValue(bystanderLp);

        // The attacker ends up holding nothing: the donation is sunk and no output comes back to them.
        assertEq(childToken.balanceOf(attacker), 0, "attacker takes no child token");
        assertEq(parentToken.balanceOf(attacker), 0, "attacker takes no parent token");
        assertEq(IPairToken(address(pair)).balanceOf(attacker), 0, "attacker takes no LP");

        // No redistribution: the bystander's LP balance is untouched; the residual value move
        // is the settlement's price impact, bounded by FEE_SETTLEMENT_RATIO.
        assertEq(IPairToken(address(pair)).balanceOf(bystander), bystanderLp, "no LP transfer to bystander");
        assertApproxEqRel(valueAfter, valueBefore, 5e15, "bystander value moves only by the bounded price impact");

        // The reclassified growth LP leaves via Stake's own balance; what it converts into is burned.
        assertLt(IPairToken(address(pair)).balanceOf(address(stake)), stakeLpBefore, "Stake's LP was burned");
        assertLt(pair.totalSupply(), poolLpBefore, "pair LP supply shrank");
        assertEq(childToken.balanceOf(address(stake)), 0, "Stake keeps no child token");
        assertEq(parentToken.balanceOf(address(stake)), 0, "Stake keeps no parent token");
        assertEq(parentToken.totalSupply(), parentSupplyBefore, "parent is swapped, not burned");
        assertLt(childToken.totalSupply(), childSupplyBefore, "child supply shrank; value left the system");

        // And the staker's booked claim collapses by the same single action.
        assertLt(_withdrawableLp(), withdrawableBefore * 5 / 10, "staker LP quantity reclassified; principal value preserved");
    }

    /// Every mutation point carries the post total, so replaying Stake events over a pre-recorded
    /// snapshot reproduces both LP ledgers without the share formula or Pair logs.
    function testLedgerFoldsFromEventsOnly() public {
        LedgerFold memory fold;
        fold.fee = _feeLp();
        fold.withdrawable = _withdrawableLp();

        vm.recordLogs();

        vm.prank(attacker);
        childToken.transfer(address(pair), DONATION);
        pair.sync();
        stake.settleFees(address(childToken));

        address newbie = makeAddr("foldNewbie");
        childToken.transfer(newbie, 50_000e18);
        parentToken.transfer(newbie, 10_000e18);
        vm.startPrank(newbie);
        parentToken.approve(address(memberNFT), type(uint256).max);
        (uint256 newbieMemberId,) = memberNFT.mint("foldNewbie");
        childToken.approve(address(stake), type(uint256).max);
        parentToken.approve(address(stake), type(uint256).max);
        stake.stakeLiquidity(address(childToken), 50_000e18, 5_000e18, 1e18, 1, newbieMemberId);
        vm.stopPrank();

        vm.prank(staker);
        stake.unstake(address(childToken), stakerMemberId);
        phase.setPhase(3);
        vm.prank(staker);
        stake.withdraw(address(childToken), stakerMemberId);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(stake)) continue;
            bytes32 topic = logs[i].topics[0];
            if (topic == FEE_RECLASSIFIED_TOPIC) {
                (, , uint256 totalFeeLp, uint256 totalWithdrawableLp, , ) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
                fold.fee = totalFeeLp;
                fold.withdrawable = totalWithdrawableLp;
                fold.seenFeeReclassified = true;
            } else if (topic == LIQUIDITY_STAKED_TOPIC) {
                (,,,,,,,,, uint256 totalWithdrawableLp) = abi.decode(
                    logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256)
                );
                fold.withdrawable = totalWithdrawableLp;
                fold.seenLiquidityStaked = true;
            } else if (topic == STAKE_WITHDRAWN_TOPIC) {
                (,,,,,,,,, uint256 totalWithdrawableLp) = abi.decode(
                    logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256)
                );
                fold.withdrawable = totalWithdrawableLp;
                fold.seenStakeWithdrawn = true;
            } else if (topic == FEES_SETTLED_TOPIC) {
                (,,,,, uint256 totalFeeLp) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
                fold.fee = totalFeeLp;
                fold.seenFeesSettled = true;
            }
        }

        assertTrue(fold.seenFeeReclassified, "FeeReclassified missing");
        assertTrue(fold.seenLiquidityStaked, "LiquidityStaked missing");
        assertTrue(fold.seenStakeWithdrawn, "StakeWithdrawn missing");
        assertTrue(fold.seenFeesSettled, "FeesSettled missing");
        assertEq(fold.fee, _feeLp(), "fee ledger mismatch");
        assertEq(fold.withdrawable, _withdrawableLp(), "withdrawable ledger mismatch");
    }

    /// The bystander's pro-rata claim on the pair's actual balances, totalled in child-token units at
    /// the pool's marginal price. A settlement moves this only by its bounded price impact.
    function _bystanderValue(uint256 bystanderLp)
        internal
        view
        returns (uint256 valueInChildUnits, uint256 claimChild, uint256 claimParent)
    {
        uint256 poolLp = pair.totalSupply();
        claimChild = bystanderLp * childToken.balanceOf(address(pair)) / poolLp;
        claimParent = bystanderLp * parentToken.balanceOf(address(pair)) / poolLp;
        valueInChildUnits = claimChild
            + claimParent * childToken.balanceOf(address(pair)) / parentToken.balanceOf(address(pair));
    }
}
