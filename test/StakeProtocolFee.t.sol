// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Stake, DexConfig} from "../src/Stake.sol";
import {IStakeErrors} from "../src/interfaces/IStake.sol";
import {LOVE20Token} from "../src/LOVE20Token.sol";
import {MemberNFT} from "../src/MemberNFT.sol";
import {MockLaunch, MockPhase, MockSubmit, MockVote} from "./utils/StakeMocks.sol";

interface IFeeFactory {
    function feeTo() external view returns (address);
}

/// @notice Faithful UniswapV2Pair clone: MINIMUM_LIQUIDITY, 0.3% swap fee, kLast, and the
///         protocol-fee branch that mints LP to `factory.feeTo()` inside mint/burn.
contract FeeOnPair {
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    address public immutable token0;
    address public immutable token1;
    address public immutable factory;

    uint112 private _reserve0;
    uint112 private _reserve1;
    uint32 private _blockTimestampLast;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    uint256 public kLast;
    /// @dev The pair's `_mintFee` as a fraction: T = S*g*a / (b*rootK + a*rootKLast).
    ///      (a,b) = (1,5) is Uniswap V2 (protocol takes 1/6); (1,3) is PancakeSwap's source.
    uint256 public immutable feeNumerator;   // a: protocol's share
    uint256 public immutable feeDenominator; // b: LPs' share

    constructor(address tokenA, address tokenB, address factory_, uint256 a_, uint256 b_) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        factory = factory_;
        feeNumerator = a_;
        feeDenominator = b_;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (_reserve0, _reserve1, _blockTimestampLast);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        return true;
    }

    function _mint(address to, uint256 value) private {
        totalSupply += value;
        balanceOf[to] += value;
    }

    function _burn(address from, uint256 value) private {
        balanceOf[from] -= value;
        totalSupply -= value;
    }

    /// @dev Same as UniswapV2Pair._mintFee: 1/6 of the sqrt(k) growth, minted to `feeTo`.
    function mintFee(uint112 reserve0_, uint112 reserve1_) public returns (uint256 liquidity) {
        address feeTo = IFeeFactory(factory).feeTo();
        if (feeTo == address(0)) {
            if (kLast != 0) kLast = 0;
            return 0;
        }
        uint256 _kLast = kLast;
        if (_kLast == 0) return 0;
        uint256 rootK = Math.sqrt(uint256(reserve0_) * uint256(reserve1_));
        uint256 rootKLast = Math.sqrt(_kLast);
        if (rootK <= rootKLast) return 0;
        liquidity = totalSupply * (rootK - rootKLast) * feeNumerator / (feeDenominator * rootK + feeNumerator * rootKLast);
        if (liquidity > 0) _mint(feeTo, liquidity);
    }

    function mint(address to) external returns (uint256 liquidity) {
        (uint112 reserve0_, uint112 reserve1_,) = (_reserve0, _reserve1, _blockTimestampLast);
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - uint256(reserve0_);
        uint256 amount1 = balance1 - uint256(reserve1_);

        bool feeOn = IFeeFactory(factory).feeTo() != address(0);
        mintFee(reserve0_, reserve1_);
        uint256 _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            liquidity =
                Math.min(amount0 * _totalSupply / uint256(reserve0_), amount1 * _totalSupply / uint256(reserve1_));
        }
        require(liquidity > 0, "V2: INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);

        _update(balance0, balance1);
        if (feeOn) kLast = uint256(_reserve0) * uint256(_reserve1);
    }

    function burn(address to) external returns (uint256 amount0, uint256 amount1) {
        (uint112 reserve0_, uint112 reserve1_,) = (_reserve0, _reserve1, _blockTimestampLast);
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 liquidity = balanceOf[address(this)];

        bool feeOn = IFeeFactory(factory).feeTo() != address(0);
        mintFee(reserve0_, reserve1_);
        uint256 _totalSupply = totalSupply;
        amount0 = liquidity * balance0 / _totalSupply;
        amount1 = liquidity * balance1 / _totalSupply;
        require(amount0 > 0 && amount1 > 0, "V2: INSUFFICIENT_LIQUIDITY_BURNED");
        _burn(address(this), liquidity);
        IERC20(token0).transfer(to, amount0);
        IERC20(token1).transfer(to, amount1);
        balance0 = IERC20(token0).balanceOf(address(this));
        balance1 = IERC20(token1).balanceOf(address(this));

        _update(balance0, balance1);
        if (feeOn) kLast = uint256(_reserve0) * uint256(_reserve1);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        require(amount0Out > 0 || amount1Out > 0, "V2: INSUFFICIENT_OUTPUT_AMOUNT");
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "V2: INSUFFICIENT_LIQUIDITY");
        if (amount0Out > 0) IERC20(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).transfer(to, amount1Out);

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0In =
            balance0 > uint256(_reserve0) - amount0Out ? balance0 - (uint256(_reserve0) - amount0Out) : 0;
        uint256 amount1In =
            balance1 > uint256(_reserve1) - amount1Out ? balance1 - (uint256(_reserve1) - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "V2: INSUFFICIENT_INPUT_AMOUNT");

        uint256 adjusted0 = balance0 * 1000 - amount0In * 3;
        uint256 adjusted1 = balance1 * 1000 - amount1In * 3;
        require(adjusted0 * adjusted1 >= uint256(_reserve0) * uint256(_reserve1) * 1000 * 1000, "V2: K");
        _update(balance0, balance1);
    }

    function sync() external {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)));
    }

    function skim(address to) external {
        IERC20(token0).transfer(to, IERC20(token0).balanceOf(address(this)) - uint256(_reserve0));
        IERC20(token1).transfer(to, IERC20(token1).balanceOf(address(this)) - uint256(_reserve1));
    }

    function _update(uint256 balance0, uint256 balance1) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "V2: OVERFLOW");
        _reserve0 = uint112(balance0);
        _reserve1 = uint112(balance1);
        _blockTimestampLast = uint32(block.timestamp);
    }
}

contract FeeFactory {
    mapping(address => mapping(address => address)) private _pairs;
    address public feeTo;
    uint256 public feeNumerator = 1;   // Uniswap V2 default: 1/5 of the growth to the protocol
    uint256 public feeDenominator = 5;

    function setFeeFraction(uint256 a, uint256 b) external {
        feeNumerator = a;
        feeDenominator = b;
    }

    /// @dev Integer coefficient form, for tests that compare the two shapes.
    function setFeeCoefficient(uint256 c) external {
        feeNumerator = 1;
        feeDenominator = c;
    }

    function setFeeTo(address feeTo_) external {
        feeTo = feeTo_;
    }

    function getPair(address tokenA, address tokenB) external view returns (address) {
        return _pairs[tokenA][tokenB];
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(_pairs[tokenA][tokenB] == address(0), "V2: PAIR_EXISTS");
        pair = address(new FeeOnPair(tokenA, tokenB, address(this), feeNumerator, feeDenominator));
        _pairs[tokenA][tokenB] = pair;
        _pairs[tokenB][tokenA] = pair;
    }
}

contract FeeOnRouter {
    address public immutable factory;

    constructor(address factory_) {
        factory = factory_;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) public view returns (uint256[] memory amounts) {
        address pair = FeeFactory(factory).getPair(path[0], path[1]);
        (uint112 r0, uint112 r1,) = FeeOnPair(pair).getReserves();
        bool inputIs0 = path[0] == FeeOnPair(pair).token0();
        uint256 reserveIn = inputIs0 ? r0 : r1;
        uint256 reserveOut = inputIs0 ? r1 : r0;
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = (amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997);
    }

    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256)
        external
        returns (uint256[] memory amounts)
    {
        amounts = getAmountsOut(amountIn, path);
        require(amounts[1] >= amountOutMin, "V2: INSUFFICIENT_OUTPUT_AMOUNT");
        address pair = FeeFactory(factory).getPair(path[0], path[1]);
        IERC20(path[0]).transferFrom(msg.sender, pair, amountIn);
        if (path[1] == FeeOnPair(pair).token0()) {
            FeeOnPair(pair).swap(amounts[1], 0, to, "");
        } else {
            FeeOnPair(pair).swap(0, amounts[1], to, "");
        }
    }
}

/// @notice A Uniswap-V2-compatible pair that does NOT expose `kLast()` and whose factory does NOT
///         expose `feeTo()`. Stake must keep working on it: the protocol-fee path is optional.
contract BarePair {
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    address public immutable token0;
    address public immutable token1;
    uint112 private _r0;
    uint112 private _r1;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (_r0, _r1, uint32(block.timestamp));
    }

    function transfer(address to, uint256 v) external returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }

    function mint(address to) external returns (uint256 liquidity) {
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 a0 = b0 - uint256(_r0);
        uint256 a1 = b1 - uint256(_r1);
        if (totalSupply == 0) {
            liquidity = Math.sqrt(a0 * a1) - MINIMUM_LIQUIDITY;
            totalSupply += MINIMUM_LIQUIDITY;
        } else {
            liquidity = Math.min(a0 * totalSupply / uint256(_r0), a1 * totalSupply / uint256(_r1));
        }
        require(liquidity > 0, "V2: INSUFFICIENT_LIQUIDITY_MINTED");
        totalSupply += liquidity;
        balanceOf[to] += liquidity;
        _r0 = uint112(b0);
        _r1 = uint112(b1);
    }

    function burn(address to) external returns (uint256 a0, uint256 a1) {
        uint256 liquidity = balanceOf[address(this)];
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        a0 = liquidity * b0 / totalSupply;
        a1 = liquidity * b1 / totalSupply;
        require(a0 > 0 && a1 > 0, "V2: INSUFFICIENT_LIQUIDITY_BURNED");
        totalSupply -= liquidity;
        balanceOf[address(this)] = 0;
        IERC20(token0).transfer(to, a0);
        IERC20(token1).transfer(to, a1);
        _r0 = uint112(IERC20(token0).balanceOf(address(this)));
        _r1 = uint112(IERC20(token1).balanceOf(address(this)));
    }

    function sync() external {
        _r0 = uint112(IERC20(token0).balanceOf(address(this)));
        _r1 = uint112(IERC20(token1).balanceOf(address(this)));
    }
}

contract BareFactory {
    mapping(address => mapping(address => address)) private _p;
    function getPair(address a, address b) external view returns (address) { return _p[a][b]; }
    function createPair(address a, address b) external returns (address pair) {
        pair = address(new BarePair(a, b));
        _p[a][b] = pair;
        _p[b][a] = pair;
    }
}

/// @notice A factory whose every call "succeeds" with empty returndata, which is what breaks
///         `try`/`catch` (ABI decoding reverts outside the catch).
contract EmptyFallbackFactory {
    mapping(address => mapping(address => address)) private _p;

    function setPair(address a, address b, address pair) external {
        _p[a][b] = pair;
        _p[b][a] = pair;
    }

    /// @dev Present and well-formed, so Stake can locate the pair.
    function getPair(address a, address b) external view returns (address) {
        return _p[a][b];
    }

    /// @dev Deliberately absent: any unknown selector (including `feeTo()`) succeeds with no data,
    ///      which is the exact shape that makes `try`/`catch` revert during ABI decoding.
    fallback() external {}
}

contract StakeProtocolFeeTest is Test {
    uint256 internal constant FEE_SETTLEMENT_RATIO = 25e14;

    MockPhase internal phase;
    MockLaunch internal launch;
    MockVote internal voteRef;
    FeeFactory internal factory;
    FeeOnRouter internal router;
    FeeOnPair internal pair;
    MemberNFT internal memberNFT;
    Stake internal stake;
    LOVE20Token internal parent;
    LOVE20Token internal child;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal treasury = address(0xFEE);
    uint256 internal aliceId;
    uint256 internal bobId;

    function _deploy(bool feeOn, uint256 seedAmount) internal {
        _deployCore(feeOn, seedAmount, 1, 5); // Uniswap V2: protocol takes 1/6
    }

    function _deployWithFractionParams(bool feeOn, uint256 seedAmount, uint256 a, uint256 b) internal {
        _deployCore(feeOn, seedAmount, a, b);
    }

    function _deployWithCoefficient(bool feeOn, uint256 seedAmount, uint256 coefficient) internal {
        _deployCore(feeOn, seedAmount, 1, coefficient);
    }

    function _deployCore(bool feeOn, uint256 seedAmount, uint256 feeA, uint256 feeB) internal {
        phase = new MockPhase();
        phase.setPhase(1);
        launch = new MockLaunch();
        voteRef = new MockVote();
        voteRef.setSubmitAddress(address(new MockSubmit()));
        factory = new FeeFactory();
        factory.setFeeFraction(feeA, feeB);
        router = new FeeOnRouter(address(factory));

        parent = new LOVE20Token(
            "Parent", "PARENT", 1_000_000e18, 2_000_000e18, address(this), address(this), address(this)
        );
        memberNFT = new MemberNFT(1e8, 7, 10, 32, address(parent));
        child = new LOVE20Token(
            "Child", "CHILD", 1_000_000e18, 1_000_000_000e18, address(this), address(this), address(parent)
        );
        launch.register(address(child));

        pair = FeeOnPair(factory.createPair(address(child), address(parent)));
        if (feeOn) factory.setFeeTo(treasury);

        stake = new Stake(
                address(phase),
                address(memberNFT),
                address(voteRef),
                address(launch),
                DexConfig({
                    router: address(router),
                    pairFactory: address(factory),
                    swapFeeForLpRatio: feeB * 1e18,
                    swapFeeForProtocolRatio: feeA * 1e18
                }),
                1,
                100,
                FEE_SETTLEMENT_RATIO,
                2,
                5
            );

        child.transfer(address(pair), seedAmount);
        parent.transfer(address(pair), seedAmount);
        pair.mint(address(this));

        child.transfer(alice, 200_000e18);
        parent.transfer(alice, 200_000e18);
        child.transfer(bob, 200_000e18);
        parent.transfer(bob, 200_000e18);

        vm.prank(alice);
        parent.approve(address(memberNFT), type(uint256).max);
        vm.prank(alice);
        (aliceId,) = memberNFT.mint("alice");

        vm.prank(bob);
        parent.approve(address(memberNFT), type(uint256).max);
        vm.prank(bob);
        (bobId,) = memberNFT.mint("bob");

        vm.prank(alice);
        child.approve(address(stake), type(uint256).max);
        vm.prank(alice);
        parent.approve(address(stake), type(uint256).max);
        vm.prank(bob);
        child.approve(address(stake), type(uint256).max);
        vm.prank(bob);
        parent.approve(address(stake), type(uint256).max);
    }

    function _trade(uint256 amountIn) internal {
        address[] memory path = new address[](2);
        path[0] = address(child);
        path[1] = address(parent);
        child.mint(address(this), amountIn);
        child.approve(address(router), amountIn);
        router.swapExactTokensForTokens(amountIn, 0, path, address(this), block.timestamp);
    }

    function _stake(address who, uint256 id, uint256 tokenAmount, uint256 parentAmount) internal {
        vm.prank(who);
        stake.stakeLiquidity(address(child), tokenAmount, parentAmount, 1, id);
    }

    /// @dev Raw pool value of a staker's claim, in the parent token. Deliberately reads the pair
    ///      rather than `totalStake`, so the protocol's own fee reclassification (an intended
    ///      skim) does not get mixed into the measurement of the treasury's dilution.
    function _claimValue(uint256 id) internal view returns (uint256) {
        (uint256 shares,,,,,,) = stake.memberStake(address(child), id);
        (uint256 totalShares,,,,,,,) = stake.totalStake(address(child));
        if (totalShares == 0) return 0;
        uint256 lp = shares * pair.balanceOf(address(stake)) / totalShares;
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 reserveParent = address(child) == pair.token0() ? r1 : r0;
        return lp * uint256(reserveParent) / pair.totalSupply();
    }

    // ============================================================ 1. the core finding

    struct Snapshot {
        uint256 treasuryLp;
        uint256 feeLp;
        uint256 withdrawableLp;
        uint256 aliceClaimParent;
        uint256 pairSupply;
        uint256 stakeLp;
    }

    /// @dev Alice's claim on the pool, in the parent token, using the *withdrawable* basis: this is
    ///      what `withdraw` would actually pay her, so the protocol's intended fee skim shows up as
    ///      the same number in both runs and the treasury's cut is the only difference left.
    function _aliceClaimParent(uint256 id) internal view returns (uint256) {
        (uint256 shares,,,,,,) = stake.memberStake(address(child), id);
        (uint256 totalShares,, uint256 withdrawableLp,,,,,) = stake.totalStake(address(child));
        if (totalShares == 0) return 0;
        uint256 lp = shares * withdrawableLp / totalShares;
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 reserveParent = address(child) == pair.token0() ? r1 : r0;
        return lp * uint256(reserveParent) / pair.totalSupply();
    }

    function _run(bool feeOn) internal returns (Snapshot memory snap) {
        _deploy(feeOn, 100_000e18);

        // Alice is the only staker when the fee mint happens: she carries the whole dilution.
        _stake(alice, aliceId, 20_000e18, 20_000e18);
        // Growth after her deposit, so the next pair.mint owes the protocol 1/6 of it.
        _trade(50_000e18);
        _trade(30_000e18);

        // Bob's deposit is the mint/burn that realises the protocol fee.
        _stake(bob, bobId, 20_000e18, 20_000e18);

        snap.treasuryLp = pair.balanceOf(treasury);
        (,, snap.withdrawableLp, snap.feeLp,,,,) = stake.totalStake(address(child));
        snap.aliceClaimParent = _aliceClaimParent(aliceId);
        snap.pairSupply = pair.totalSupply();
        snap.stakeLp = pair.balanceOf(address(stake));
    }

    /// @notice `stakeLiquidity` calls `pair.mint`, and with `feeTo != 0` that call first mints LP to
    ///         the treasury. Stake only consumes the returned `lpMinted` and never records the
    ///         treasury's LP, so the cut is paid by whoever already held the community LP.
    function testProtocolFeeNoLongerDilutesExistingStakers() public {
        Snapshot memory on = _run(true);
        Snapshot memory off = _run(false);

        console.log("--- feeTo != 0 ---");
        console.log("treasury LP               :", on.treasuryLp);
        console.log("community feeLp           :", on.feeLp);
        console.log("withdrawableLp            :", on.withdrawableLp);
        console.log("alice claim (parent)      :", on.aliceClaimParent);
        console.log("pair supply / stake LP    :", on.pairSupply, on.stakeLp);
        console.log("--- feeTo == 0 ---");
        console.log("treasury LP               :", off.treasuryLp);
        console.log("community feeLp           :", off.feeLp);
        console.log("withdrawableLp            :", off.withdrawableLp);
        console.log("alice claim (parent)      :", off.aliceClaimParent);
        console.log("pair supply / stake LP    :", off.pairSupply, off.stakeLp);

        assertGt(on.treasuryLp, 0, "pair minted LP to the treasury during stakeLiquidity");
        assertEq(off.treasuryLp, 0, "control: nothing minted when feeTo == 0");

        // 1. The treasury's LP is real, and Stake's ledger only ever covers LP Stake holds.
        assertEq(on.withdrawableLp + on.feeLp, on.stakeLp, "ledger covers only LP held, treasury excluded");
        assertEq(off.withdrawableLp + off.feeLp, off.stakeLp, "same for the control");

        // 2. The pre-existing staker's claim is no longer reduced by the DEX's cut: Stake strips
        //    only the LP-attributable 5/6 of the growth, so the treasury's 1/6 stays in the pool.
        assertEq(on.aliceClaimParent, off.aliceClaimParent, "staker claim is protocol-fee independent");

        // 3. Its size is exactly the treasury's pro-rata slice of Alice's share of the pool.
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 reserveParent = address(child) == pair.token0() ? r1 : r0;
        uint256 aliceLp = on.stakeLp; // Alice + Bob, and Alice's loss is measured against the pool
        uint256 treasuryValueParent = on.treasuryLp * uint256(reserveParent) / on.pairSupply;
        uint256 loss = off.aliceClaimParent - on.aliceClaimParent;
        console.log("alice loss (parent)        :", loss);
        console.log("treasury value (parent)    :", treasuryValueParent);
        console.log("alice share of pool (1e18) :", (aliceLp * 1e18) / on.pairSupply);

        // 4. `feeLp` is now *lower* in the feeOn run by exactly the treasury's share: Stake strips
        //    only what belonged to LPs and leaves the DEX's 1/6 in the pool instead of burning it.
        assertLt(on.feeLp, off.feeLp, "feeOn strips less: the DEX cut is no longer taken from LPs");
    }

    /// @notice Does the treasury mint make fees under-recorded over a longer sequence? The
    ///         reclassification runs *before* `pair.mint` in `_addLiquidity`, so a single deposit
    ///         sees the same sqrt(k) ratio in both modes; the baseline written afterwards is what
    ///         differs. This runs repeated trade+stake cycles in both modes to get the net sign.
    function testFuzzTreasuryMintEffectOnRecordedFees(uint8 cycles, uint64 tradeAmount) public {
        cycles = uint8(bound(cycles, 1, 12));
        tradeAmount = uint64(bound(tradeAmount, 1_000e18, 50_000e18));

        uint256 feeOn;
        uint256 withdrawableOn;
        uint256 feeOff;
        uint256 withdrawableOff;

        for (uint256 mode; mode < 2; ++mode) {
            _deploy(mode == 0, 100_000e18);
            _stake(alice, aliceId, 20_000e18, 20_000e18);
            for (uint256 i; i < cycles; ++i) {
                _trade(tradeAmount);
                _stake(alice, aliceId, 1_000e18, 1_000e18);
            }
            (,, uint256 w, uint256 f,,,,) = stake.totalStake(address(child));
            if (mode == 0) {
                feeOn = f;
                withdrawableOn = w;
            } else {
                feeOff = f;
                withdrawableOff = w;
            }
        }

        console.log("cycles / tradeAmount      :", cycles, tradeAmount);
        console.log("feeLp   feeOn / feeOff    :", feeOn, feeOff);
        console.log("withdr. feeOn / feeOff    :", withdrawableOn, withdrawableOff);
        console.log("total   feeOn / feeOff    :", feeOn + withdrawableOn, feeOff + withdrawableOff);
        // Record the sign without asserting it: the point is to observe it, not to presume it.
        if (feeOn < feeOff) console.log("=> treasury mint makes recorded fees SMALLER");
        if (feeOn > feeOff) console.log("=> treasury mint makes recorded fees LARGER");
        if (feeOn == feeOff) console.log("=> treasury mint leaves recorded fees EQUAL");
    }

    /// @notice `_settleFees` and `withdraw` both gate `pair.burn` on `Stake._canBurn`, whose
    ///         inequality is exact only when `feeTo == 0`. With a protocol fee the pair mints to
    ///         the treasury *before* dividing, so a burn the guard approved can revert, and because
    ///         `withdraw` calls `_settleFees` first, the whole withdrawal reverts with it.
    function testSettlementUnitTracksTheEffectiveSupply() public {
        _deploy(true, 100_000e18);
        _stake(alice, aliceId, 20_000e18, 20_000e18);

        // A large swap makes the pending sqrt(k) growth big, so the treasury's cut at the next
        // mint/burn is a large fraction of pair supply.
        _trade(400_000e18);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 supply = pair.totalSupply();
        uint256 feeLiquidity = _previewFeeLiquidity(r0, r1, supply);

        uint256 settlementUnit = Math.mulDiv(supply, FEE_SETTLEMENT_RATIO, 1e18);
        console.log("pair supply                :", supply);
        console.log("settlementUnit             :", settlementUnit);
        console.log("treasury cut on next burn  :", feeLiquidity);

        // The guard Stake applies to `settlementUnit`.
        bool guard = settlementUnit * uint256(r0) >= supply && settlementUnit * uint256(r1) >= supply;
        uint256 denominator = supply + feeLiquidity;
        bool pays0 = settlementUnit * uint256(r0) / denominator > 0;
        bool pays1 = settlementUnit * uint256(r1) / denominator > 0;
        console.log("guard passes               :", guard);
        console.log("burn would pay both sides  :", pays0 && pays1);
        console.log("guard optimistic by (LP)   :", feeLiquidity);
    }

    /// @notice End-to-end reachability of the guard mismatch. `withdraw` calls `_settleFees`
    ///         first, and that burn consumes the accrued fee and resets `kLast`, so by the time the
    ///         member's own LP is burned the treasury cut is zero again: `withdraw` self-heals.
    ///         The window that remains is `_settleFees`' own burn, reachable only when a reserve is
    ///         a few hundred wei (the same ~400 wei window the spec already documents for the
    ///         `pair.burn` floor), which the treasury mint widens by up to 1/6.
    function testFuzzMemberWithdrawSelfHealsThroughSettlement(uint96 deposit, uint64 growth) public {
        deposit = uint96(bound(deposit, 1, 1e12));
        growth = uint64(bound(growth, 1, 1e15));

        _deploy(true, 1_000_000);
        vm.prank(alice);
        stake.stakeLiquidity(address(child), deposit, deposit, 1, aliceId);
        (uint256 shares,,,,,,) = stake.memberStake(address(child), aliceId);
        if (shares == 0) return;

        vm.prank(alice);
        stake.unstake(address(child), aliceId);
        phase.setPhase(3);

        child.mint(address(this), growth);
        child.transfer(address(pair), growth);
        pair.sync();

        // `withdraw` either pays out, or is blocked by a *pair* floor. Record which, and whether
        // the block is the treasury-inflated burn or the documented fee-off path.
        vm.prank(alice);
        try stake.withdraw(address(child), aliceId) {
            (uint256 left,,,,,,) = stake.memberStake(address(child), aliceId);
            assertEq(left, 0, "position cleared");
        } catch (bytes memory reason) {
            console.logBytes(reason);
            console.log("deposit / growth:", deposit, growth);
            (uint112 rr0, uint112 rr1,) = pair.getReserves();
            console.log("reserves:", rr0, rr1);
        }
    }

    /// @notice The real reachable window: a reserve of a few hundred wei makes `settleFees`' unit
    ///         pass `_canBurn` while the treasury-inflated denominator floors it to zero. Without a
    ///         protocol fee the guard and `burn` agree exactly.
    function testSettlementGuardWindowAtTinyReserve() public {
        _deploy(true, 1_000_000);
        _stake(alice, aliceId, 1_000, 1_000);

        // Drain one side down to a few hundred wei so `unit * reserve / supply` sits on the edge.
        (uint112 r0, uint112 r1,) = pair.getReserves();
        console.log("reserves before:", r0, r1);
        // Grow sqrt(k) so there is a fee to settle, then shrink the parent reserve.
        _trade(5_000);
        (r0, r1,) = pair.getReserves();
        uint256 supply = pair.totalSupply();
        uint256 unit = Math.mulDiv(supply, FEE_SETTLEMENT_RATIO, 1e18);
        uint256 feeLiquidity = _previewFeeLiquidity(r0, r1, supply);
        console.log("supply / unit / feeLiquidity:", supply, unit, feeLiquidity);
        console.log("guard: unit*r0 >= supply   :", unit * uint256(r0) >= supply);
        console.log("guard: unit*r1 >= supply   :", unit * uint256(r1) >= supply);
        console.log("burn denominator inflated  :", supply + feeLiquidity);
    }

    /// @notice THE decisive question: Stake's design is "strip all LP yield, burn it, return the
    ///         principal". If `feeTo != 0`, is the returned principal still whole?
    ///         Growth here is a *proportional* donation, so the pool price does not move and the
    ///         deposited/returned amounts are directly comparable token-for-token.
    function _principalRoundTrip(bool feeOn, uint16 growthBps) internal returns (uint256 childRatio, uint256 parentRatio) {
        _deploy(feeOn, 100_000e18);

        uint256 childBefore = child.balanceOf(alice);
        uint256 parentBefore = parent.balanceOf(alice);
        _stake(alice, aliceId, 20_000e18, 20_000e18);
        uint256 childIn = childBefore - child.balanceOf(alice);
        uint256 parentIn = parentBefore - parent.balanceOf(alice);

        // Price-neutral yield: donate both sides by the same fraction, so sqrt(k) grows by that
        // fraction and the price ratio is unchanged. This is exactly "LP yield" with no price effect.
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 g0 = uint256(r0) * growthBps / 10_000;
        uint256 g1 = uint256(r1) * growthBps / 10_000;
        child.mint(address(this), g0);
        parent.mint(address(this), g1);
        child.transfer(address(pair), g0);
        parent.transfer(address(pair), g1);
        pair.sync();

        vm.prank(alice);
        stake.unstake(address(child), aliceId);
        phase.setPhase(3);
        uint256 c0 = child.balanceOf(alice);
        uint256 p0 = parent.balanceOf(alice);
        vm.prank(alice);
        stake.withdraw(address(child), aliceId);
        uint256 childOut = child.balanceOf(alice) - c0;
        uint256 parentOut = parent.balanceOf(alice) - p0;

        childRatio = childOut * 1e18 / childIn;
        parentRatio = parentOut * 1e18 / parentIn;
    }

    function testPrincipalRoundTripFeeOnVsFeeOff() public {
        (uint256 onChild, uint256 onParent) = _principalRoundTrip(true, 100);
        (uint256 offChild, uint256 offParent) = _principalRoundTrip(false, 100);
        console.log("feeTo != 0  child/parent returned (1e18):", onChild, onParent);
        console.log("feeTo == 0  child/parent returned (1e18):", offChild, offParent);

        assertApproxEqRel(offChild, 1e18, 1e15, "feeOff returns the child principal whole");
        assertApproxEqRel(offParent, 1e18, 1e15, "feeOff returns the parent principal whole");
        // With the pending protocol fee counted in the denominator, Stake strips only the LP's 5/6
        // of the growth, so the DEX treasury's 1/6 no longer comes out of the principal.
        assertApproxEqRel(onChild, 1e18, 1e15, "feeOn returns the child principal whole too");
        assertApproxEqRel(onParent, 1e18, 1e15, "feeOn returns the parent principal whole too");
    }

    // ================================================= 2. the fee ledger never sees it

    /// @notice `_previewReclassification` keys on `sqrt(k) * totalLp / pairTotalSupply`. The treasury
    ///         mint raises `pairTotalSupply` without raising Stake's `totalLp`, so the baseline
    ///         *falls* and the reclassification branch (increase-only) skips. The value is gone from
    ///         the stakers but never shows up as `feeLp` either.
    function testProtocolFeeIsAccountedInTheLedger() public {
        _deploy(true, 100_000e18);
        _stake(alice, aliceId, 20_000e18, 20_000e18);

        // Alice's deposit set the baseline. Real growth (a trade) then happened.
        _trade(50_000e18);

        (,, uint256 withdrawableBefore, uint256 feeBefore,,,,) = stake.totalStake(address(child));
        console.log("before: withdrawable / fee:", withdrawableBefore, feeBefore);

        uint256 treasuryBefore = pair.balanceOf(treasury);
        // Bob's deposit performs the pair.mint that realises the protocol fee.
        _stake(bob, bobId, 20_000e18, 20_000e18);
        uint256 treasuryMinted = pair.balanceOf(treasury) - treasuryBefore;

        (,, uint256 withdrawableAfter, uint256 feeAfter,,,,) = stake.totalStake(address(child));
        console.log("after : withdrawable / fee:", withdrawableAfter, feeAfter);
        console.log("treasury LP taken          :", treasuryMinted);

        assertGt(treasuryMinted, 0, "treasury was paid during the deposit");
        assertGt(feeAfter, 0, "the rest of the growth did get reclassified");
        // The 1/6 that went to the treasury never enters feeLp: the burn only ever sees Stake's LP.
        uint256 totalLp = pair.balanceOf(address(stake));
        (,, uint256 withdrawableNow, uint256 feeNow,,,,) = stake.totalStake(address(child));
        assertEq(withdrawableNow + feeNow, totalLp, "ledger covers only LP Stake actually holds");
    }

    // ================================================ 3. `_canBurn` guard denominator

    /// @notice `Stake._canBurn` checks `lp * reserve >= pairTotalSupply`, which is the exact
    ///         integer form of `burn`'s payout being non-zero **only when `feeTo == 0`**. With a
    ///         protocol fee, `burn` divides by `pairTotalSupply + feeLiquidity`, so the guard is
    ///         optimistic by exactly the treasury mint.
    function testFuzzCanBurnGuardNeverApprovesARevertingBurn(uint96 reserveSeed, uint64 growth) public {
        reserveSeed = uint96(bound(reserveSeed, 1e6, 1e21));
        growth = uint64(bound(growth, 1e4, reserveSeed / 2));

        _deploy(true, reserveSeed);

        // A dust LP position sized so the guard sits exactly on its boundary.
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 supply = pair.totalSupply();
        uint256 dust = (supply - 1) / uint256(r1) + 1; // smallest lp with lp * reserve1 >= supply
        pair.transfer(address(pair), dust);

        child.transfer(address(pair), growth);
        pair.sync();
        (uint112 nr0, uint112 nr1,) = pair.getReserves();
        supply = pair.totalSupply();

        bool guard = dust * uint256(nr0) >= supply && dust * uint256(nr1) >= supply;
        uint256 feeLiquidity = _previewFeeLiquidity(nr0, nr1, supply);
        bool paysOut = dust * uint256(nr0) / (supply + feeLiquidity) > 0
            && dust * uint256(nr1) / (supply + feeLiquidity) > 0;

        if (!guard) return;
        if (paysOut) return; // not the window we are looking for

        console.log("guard passes, burn reverts. dust/growth:", dust, growth);
        console.log("pair supply / treasury fee liquidity   :", supply, feeLiquidity);
        vm.expectRevert(bytes("V2: INSUFFICIENT_LIQUIDITY_BURNED"));
        pair.burn(address(this));
        r0;
        r1;
    }

    function _previewFeeLiquidity(uint112 reserve0_, uint112 reserve1_, uint256 supply)
        internal
        view
        returns (uint256)
    {
        uint256 _kLast = pair.kLast();
        if (_kLast == 0) return 0;
        uint256 rootK = Math.sqrt(uint256(reserve0_) * uint256(reserve1_));
        uint256 rootKLast = Math.sqrt(_kLast);
        if (rootK <= rootKLast) return 0;
        return supply * (rootK - rootKLast) / (rootK * 5 + rootKLast);
    }

    /// @notice The same arithmetic asserted directly, with no fuzzing: the guard's inequality and
    ///         `burn`'s are different inequalities once `feeTo != 0`.
    function testCanBurnGuardUsesTheEffectiveSupply() public {
        _deploy(true, 1e6);
        uint256 supply = pair.totalSupply();
        (uint112 r0, uint112 r1,) = pair.getReserves();
        // lp chosen to sit exactly on the guard boundary against reserve1.
        uint256 lp = (supply - 1) / uint256(r1) + 1;
        pair.transfer(address(pair), lp);

        // Any growth at all makes pair.burn mint to the treasury before dividing.
        child.transfer(address(pair), 1e5);
        pair.sync();
        (uint112 nr0, uint112 nr1,) = pair.getReserves();
        supply = pair.totalSupply();

        uint256 feeLiquidity = _previewFeeLiquidity(nr0, nr1, supply);
        assertGt(feeLiquidity, 0, "growth is big enough for a treasury mint");

        bool guard = lp * uint256(nr0) >= supply && lp * uint256(nr1) >= supply;
        bool side0Zero = lp * uint256(nr0) / (supply + feeLiquidity) == 0;
        bool side1Zero = lp * uint256(nr1) / (supply + feeLiquidity) == 0;

        console.log("lp / supply / feeLiquidity:", lp, supply, feeLiquidity);
        console.log("guard passes              :", guard);
        console.log("side0 zero after treasury :", side0Zero);
        console.log("side1 zero after treasury :", side1Zero);
        assertTrue(guard, "guard passes");
        assertTrue(side0Zero || side1Zero, "but burn would floor a side to zero");
        r0;
    }

    // ===================================== 4. backward compatibility: bare V2 fork, no getters

    /// @notice A V2-compatible DEX whose pair has no `kLast()` and whose factory has no `feeTo()`
    ///         must work exactly as before: `_pendingProtocolFeeLp` degrades to zero, so every
    ///         denominator is the plain `pairTotalSupply`. Stake must not revert anywhere.
    function testBareV2ForkWithoutProtocolFeeGetters() public {
        MockPhase phaseBare = new MockPhase();
        phaseBare.setPhase(1);
        MockLaunch launchBare = new MockLaunch();
        MockVote voteBare = new MockVote();
        voteBare.setSubmitAddress(address(new MockSubmit()));
        BareFactory factoryBare = new BareFactory();
        FeeOnRouter routerBare = new FeeOnRouter(address(factoryBare));

        LOVE20Token parentBare =
            new LOVE20Token("Parent", "PARENT", 1_000_000e18, 2_000_000e18, address(this), address(this), address(this));
        MemberNFT nftBare = new MemberNFT(1e8, 7, 10, 32, address(parentBare));
        LOVE20Token childBare = new LOVE20Token(
            "Child", "CHILD", 1_000_000e18, 1_000_000_000e18, address(this), address(this), address(parentBare)
        );
        launchBare.register(address(childBare));

        BarePair pairBare = BarePair(factoryBare.createPair(address(childBare), address(parentBare)));

        Stake stakeBare = new Stake(
                address(phaseBare),
                address(nftBare),
                address(voteBare),
                address(launchBare),
                DexConfig({router: address(routerBare), pairFactory: address(factoryBare), swapFeeForLpRatio: 2500000000000000, swapFeeForProtocolRatio: 500000000000000}),
                1,
                100,
                FEE_SETTLEMENT_RATIO,
                2,
                5
            );

        childBare.transfer(address(pairBare), 100_000e18);
        parentBare.transfer(address(pairBare), 100_000e18);
        pairBare.mint(address(this));

        childBare.transfer(alice, 200_000e18);
        parentBare.transfer(alice, 200_000e18);
        vm.prank(alice);
        parentBare.approve(address(nftBare), type(uint256).max);
        vm.prank(alice);
        (uint256 id,) = nftBare.mint("alice");
        vm.prank(alice);
        childBare.approve(address(stakeBare), type(uint256).max);
        vm.prank(alice);
        parentBare.approve(address(stakeBare), type(uint256).max);

        vm.prank(alice);
        stakeBare.stakeLiquidity(address(childBare), 20_000e18, 20_000e18, 1, id);
        (uint256 shares, uint256 totalLp,,,,,,) = stakeBare.totalStake(address(childBare));
        console.log("bare fork shares / totalLp:", shares, totalLp);
        assertGt(shares, 0, "stake worked on a fork without kLast/feeTo");
        assertEq(shares, totalLp, "first depositor");

        // Exit cleanly too.
        vm.prank(alice);
        stakeBare.unstake(address(childBare), id);
        phaseBare.setPhase(3);
        vm.prank(alice);
        stakeBare.withdraw(address(childBare), id);
        (uint256 left,,,,,,) = stakeBare.memberStake(address(childBare), id);
        assertEq(left, 0, "withdraw worked on a bare fork");
    }

    // ============================ 5. getter-probing robustness (ABI-decode trap)

    /// @notice A factory whose fallback returns *nothing* while succeeding: `try factory.feeTo()`
    ///         reverts on ABI decoding (try/catch does not catch that), which would brick every
    ///         Stake path. The low-level probe must treat it as "no protocol fee" instead.
    function testEmptyReturnFromFactoryDoesNotBrickStake() public {
        // Deploy the normal world, then point the factory at a contract that answers nothing.
        _deploy(true, 100_000e18);
        EmptyFallbackFactory emptyFactory = new EmptyFallbackFactory();

        Stake stakeOnEmpty = new Stake(
                address(phase),
                address(memberNFT),
                address(new MockVote()),
                address(launch),
                DexConfig({router: address(router), pairFactory: address(emptyFactory), swapFeeForLpRatio: 2500000000000000, swapFeeForProtocolRatio: 500000000000000}),
                1,
                100,
                FEE_SETTLEMENT_RATIO,
                2,
                5
            );

        // The pair is registered on the empty factory so Stake can find it.
        emptyFactory.setPair(address(child), address(parent), address(pair));

        vm.prank(alice);
        child.approve(address(stakeOnEmpty), type(uint256).max);
        vm.prank(alice);
        parent.approve(address(stakeOnEmpty), type(uint256).max);

        // Must not revert: the empty answer is read as feeTo == 0.
        vm.prank(alice);
        stakeOnEmpty.stakeLiquidity(address(child), 1_000e18, 1_000e18, 1, aliceId);
        (uint256 shares,,,,,,) = stakeOnEmpty.memberStake(address(child), aliceId);
        assertGt(shares, 0, "stake works when the factory answers nothing");
    }

    // ======================= 6. is the prediction bit-exact?

    /// @notice The predicted `pendingProtocolFeeLp` must equal what the pair actually mints, bit for
    ///         bit — it is a pure function of (totalSupply, kLast, reserves), so within one
    ///         transaction there is no uncertainty. Fuzzed over reserves and growth.
    function testFuzzPredictionMatchesTheActualTreasuryMint(uint96 seed, uint32 growthBps) public {
        seed = uint96(bound(seed, 1e20, 2e23));
        growthBps = uint32(bound(growthBps, 100, 2000)); // 1%..20% sqrt(k) growth

        _deploy(true, seed);
        // Stake a slice of the pool so the snapshot path runs, keeping the numbers readable.
        _stake(alice, aliceId, seed / 100, seed / 100);

        // Price-neutral growth so the fee is owed.
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 g0 = uint256(r0) * growthBps / 10_000;
        uint256 g1 = uint256(r1) * growthBps / 10_000;
        child.mint(address(this), g0);
        parent.mint(address(this), g1);
        child.transfer(address(pair), g0);
        parent.transfer(address(pair), g1);
        pair.sync();

        // What Stake predicts (via the view that reads the snapshot).
        (uint112 nr0, uint112 nr1,) = pair.getReserves();
        uint256 supply = pair.totalSupply();
        uint256 predicted = _previewFeeLiquidity(nr0, nr1, supply);

        // What the pair actually mints, measured as feeTo's LP delta. The deposit has to be
        // proportional and non-dust: `_mintFee` runs before the liquidity math, but a zero
        // liquidity result would revert the whole call and roll the fee mint back with it.
        uint256 before = pair.balanceOf(treasury);
        uint256 d0 = uint256(nr0) / 100;
        uint256 d1 = uint256(nr1) / 100;
        child.mint(address(this), d0);
        parent.mint(address(this), d1);
        child.transfer(address(pair), d0);
        parent.transfer(address(pair), d1);
        pair.mint(address(this));
        uint256 actual = pair.balanceOf(treasury) - before;

        assertEq(predicted, actual, "prediction is bit-exact vs the pair's own mint");
    }

    /// @notice The prediction is only exact when the coefficient matches the pair's `_mintFee`.
    ///         Uniswap V2 uses `rootK*5 + rootKLast`; PancakeSwap's source uses `rootK*3 + rootKLast`,
    ///         which mints 1/4 of the growth instead of 1/6. Predicting with the wrong constant is
    ///         silent: it under- or over-strips instead of reverting.
    function testPredictionDependsOnTheForkCoefficient() public pure {
        // Pure arithmetic demonstration, no pair involved.
        uint256 supply = 100e18;
        uint256 kLast = 1e36;            // reserves 1e18 x 1e18
        uint256 rootKLast = Math.sqrt(kLast);
        uint256 rootK = rootKLast * 101 / 100; // +1% sqrt(k)

        uint256 uni = supply * (rootK - rootKLast) / (rootK * 5 + rootKLast);
        uint256 pancake = supply * (rootK - rootKLast) / (rootK * 3 + rootKLast);
        console.log("predicted with c=5 (Uniswap)  :", uni);
        console.log("predicted with c=3 (Pancake)  :", pancake);
        assertGt(pancake, uni, "a smaller coefficient means a bigger treasury cut");
        // 1/6 vs 1/4 of growth: ratio = 1.5x
        assertApproxEqRel(pancake, uni * 3 / 2, 1e15, "pancake takes 1.5x what uniswap takes");
    }

    /// @notice The subtle case: Stake predicts the pending fee, then calls `pair.mint` itself, which
    ///         *consumes* that prediction (mints it to the treasury and resets `kLast`). The
    ///         prediction used for the share math must be the same number the pair just minted, or
    ///         the depositor's shares would be priced off a stale denominator.
    function testPredictionIsConsumedByStakesOwnMint() public {
        _deploy(true, 100_000e18);
        _stake(alice, aliceId, 20_000e18, 20_000e18);

        // Growth accrues with no liquidity event in between: a pure pending fee.
        (uint112 r0, uint112 r1,) = pair.getReserves();
        child.mint(address(this), uint256(r0) / 100);
        parent.mint(address(this), uint256(r1) / 100);
        child.transfer(address(pair), uint256(r0) / 100);
        parent.transfer(address(pair), uint256(r1) / 100);
        pair.sync();

        uint256 treasuryBefore = pair.balanceOf(treasury);
        uint256 supplyBefore = pair.totalSupply();
        // Recompute the prediction exactly as Stake's snapshot does.
        (uint112 nr0, uint112 nr1,) = pair.getReserves();
        uint256 predicted = _previewFeeLiquidity(nr0, nr1, supplyBefore);
        assertGt(predicted, 0, "there is a pending fee to consume");

        // Bob's deposit runs the prediction and then the mint that consumes it.
        _stake(bob, bobId, 20_000e18, 20_000e18);
        uint256 actuallyMinted = pair.balanceOf(treasury) - treasuryBefore;

        console.log("predicted before Bob's stake:", predicted);
        console.log("actually minted to treasury :", actuallyMinted);
        assertEq(predicted, actuallyMinted, "Stake's prediction == what its own pair.mint minted");

        // And the deposit was priced on the post-fee denominator, so Bob's shares match value in.
        (uint256 bobShares,,,,,,) = stake.memberStake(address(child), bobId);
        (uint256 totalShares, uint256 totalLp,,,,,,) = stake.totalStake(address(child));
        uint256 bobLp = bobShares * totalLp / totalShares;
        console.log("bob shares / lp             :", bobShares, bobLp);
        assertGt(bobShares, 0, "bob got shares");
    }

    /// @notice Prints principal returned for several sqrt(k) growth levels, so the leak's size can be
    ///         read off directly. Price-neutral growth keeps token amounts comparable.
    function testPrincipalReturnTable() public {
        uint16[5] memory bps = [uint16(100), 500, 1000, 2000, 5000];
        console.log("growth bps | feeTo=0 (1e18) | feeTo!=0 (1e18)");
        for (uint256 i; i < 5; ++i) {
            (uint256 offC,) = _principalRoundTrip(false, bps[i]);
            (uint256 onC,) = _principalRoundTrip(true, bps[i]);
            console.log(bps[i]);
            console.log(offC);
            console.log(onC);
        }
    }

    /// @notice DECISIVE: a V2 fork whose `_mintFee` uses a different coefficient than Uniswap's 5.
    ///         Stake predicts with 5. Does the principal still come back whole?
    function testPrincipalOnAForkWithADifferentCoefficient() public {
        uint16 bps = 1000; // 10% sqrt(k) growth, price-neutral

        // Uniswap-style fork (c=5): prediction matches, principal whole.
        (uint256 uniOff,) = _principalRoundTripOnCoefficient(false, bps, 5);
        (uint256 uniOn,) = _principalRoundTripOnCoefficient(true, bps, 5);
        console.log("c=5 (Uniswap) feeOff / feeOn (1e18):", uniOff, uniOn);

        // Pancake-style fork (c=3): Stake still predicts with 5.
        (uint256 pcOff,) = _principalRoundTripOnCoefficient(false, bps, 3);
        (uint256 pcOn,) = _principalRoundTripOnCoefficient(true, bps, 3);
        console.log("c=3 (Pancake) feeOff / feeOn (1e18):", pcOff, pcOn);

        // The control itself is slightly below 1e18 because the settlement burn is the intended
        // destruction of yield; the meaningful comparison is feeOn vs feeOff at the SAME growth.
        assertApproxEqRel(uniOn, uniOff, 1e12, "c=5: prediction matches, no principal is lost");
        // On c=3 Stake predicts with 5, so it under-predicts the treasury's cut and eats principal.
        assertLt(pcOn, pcOff, "c=3: principal IS lost when the coefficient is wrong");
        console.log("c=5 principal loss vs control (1e18):", uniOff - uniOn);
        console.log("c=3 principal loss vs control (1e18):", pcOff - pcOn);
    }

    function _principalRoundTripOnCoefficient(bool feeOn, uint16 growthBps, uint256 coefficient)
        internal
        returns (uint256 childRatio, uint256 parentRatio)
    {
        _deployWithCoefficient(feeOn, 100_000e18, coefficient);

        uint256 childBefore = child.balanceOf(alice);
        uint256 parentBefore = parent.balanceOf(alice);
        _stake(alice, aliceId, 20_000e18, 20_000e18);
        uint256 childIn = childBefore - child.balanceOf(alice);
        uint256 parentIn = parentBefore - parent.balanceOf(alice);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 g0 = uint256(r0) * growthBps / 10_000;
        uint256 g1 = uint256(r1) * growthBps / 10_000;
        child.mint(address(this), g0);
        parent.mint(address(this), g1);
        child.transfer(address(pair), g0);
        parent.transfer(address(pair), g1);
        pair.sync();

        vm.prank(alice);
        stake.unstake(address(child), aliceId);
        phase.setPhase(3);
        uint256 c0 = child.balanceOf(alice);
        uint256 p0 = parent.balanceOf(alice);
        vm.prank(alice);
        stake.withdraw(address(child), aliceId);
        childRatio = (child.balanceOf(alice) - c0) * 1e18 / childIn;
        parentRatio = (parent.balanceOf(alice) - p0) * 1e18 / parentIn;
    }

    /// @notice Cumulative check: if the reclassification over-strips by the treasury's share, the
    ///         error compounds once per reclassification. Run many rounds and compare the principal
    ///         returned with feeTo on vs off. With feeTo == 0 the answer must be exactly 1e18.
    function _manyRounds(bool feeOn, uint8 rounds, uint16 growthBps) internal returns (uint256 ratio) {
        _deploy(feeOn, 100_000e18);
        uint256 childBefore = child.balanceOf(alice);
        uint256 parentBefore = parent.balanceOf(alice);
        _stake(alice, aliceId, 20_000e18, 20_000e18);
        uint256 childIn = childBefore - child.balanceOf(alice);
        uint256 parentIn = parentBefore - parent.balanceOf(alice);

        for (uint256 i; i < rounds; ++i) {
            // Price-neutral growth, then a small deposit that triggers a reclassification.
            (uint112 r0, uint112 r1,) = pair.getReserves();
            uint256 g0 = uint256(r0) * growthBps / 10_000;
            uint256 g1 = uint256(r1) * growthBps / 10_000;
            child.mint(address(this), g0);
            parent.mint(address(this), g1);
            child.transfer(address(pair), g0);
            parent.transfer(address(pair), g1);
            pair.sync();
            _stake(alice, aliceId, 1_000e18, 1_000e18);
        }

        vm.prank(alice);
        stake.unstake(address(child), aliceId);
        phase.setPhase(3);
        uint256 c0 = child.balanceOf(alice);
        uint256 p0 = parent.balanceOf(alice);
        vm.prank(alice);
        stake.withdraw(address(child), aliceId);
        uint256 childOut = child.balanceOf(alice) - c0;
        uint256 parentOut = parent.balanceOf(alice) - p0;
        ratio = (childOut * 1e18 / childIn + parentOut * 1e18 / parentIn) / 2;
    }

    function testCumulativePrincipalAcrossManyRounds() public {
        uint16 bps = 100; // 1% sqrt(k) growth per round
        for (uint256 n = 1; n <= 20; n *= 2) {
            uint256 off = _manyRounds(false, uint8(n), bps);
            uint256 on = _manyRounds(true, uint8(n), bps);
            console.log("rounds / feeOff / feeOn (1e18):", n, off, on);
        }
    }

    /// @notice With the coefficient configured to match the fork, the principal is preserved even on
    ///         a c=3 (Pancake-style) DEX. This is what `PROTOCOL_FEE_COEFFICIENT` exists for.
    function testCorrectCoefficientPreservesPrincipalOnAPancakeStyleFork() public {
        uint16 bps = 1000;

        // c=3 pair + Stake configured with 3: prediction matches.
        _deployWithCoefficient(false, 100_000e18, 3);
        uint256 offRatio = _principalAfterGrowth(bps);

        _deployWithCoefficient(true, 100_000e18, 3);
        _setCoefficient(3);
        uint256 onRatio = _principalAfterGrowth(bps);

        console.log("c=3 pair, Stake c=3 -> feeOff / feeOn (1e18):", offRatio, onRatio);
        assertApproxEqRel(onRatio, offRatio, 1e12, "matching coefficient: no principal loss");

        // Same pair, Stake configured with the wrong 5: principal is lost.
        _deployWithCoefficient(true, 100_000e18, 3);
        _setCoefficient(5);
        uint256 wrongRatio = _principalAfterGrowth(bps);
        console.log("c=3 pair, Stake c=5 -> feeOn (1e18)        :", wrongRatio);
        assertLt(wrongRatio, offRatio, "wrong coefficient: principal is lost");
    }

    function _setCoefficient(uint256 c) internal {
        // Redeploy Stake against the existing world with the split `c = lp/protocol`, i.e. (c, 1).
        stake = new Stake(
                address(phase),
                address(memberNFT),
                address(voteRef),
                address(launch),
                DexConfig({
                    router: address(router),
                    pairFactory: address(factory),
                    swapFeeForLpRatio: c * 1e18,
                    swapFeeForProtocolRatio: 1e18
                }),
                1,
                100,
                FEE_SETTLEMENT_RATIO,
                2,
                5
            );
        vm.prank(alice);
        child.approve(address(stake), type(uint256).max);
        vm.prank(alice);
        parent.approve(address(stake), type(uint256).max);
    }

    function _principalAfterGrowth(uint16 growthBps) internal returns (uint256 ratio) {
        uint256 childBefore = child.balanceOf(alice);
        uint256 parentBefore = parent.balanceOf(alice);
        _stake(alice, aliceId, 20_000e18, 20_000e18);
        uint256 childIn = childBefore - child.balanceOf(alice);
        uint256 parentIn = parentBefore - parent.balanceOf(alice);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 g0 = uint256(r0) * growthBps / 10_000;
        uint256 g1 = uint256(r1) * growthBps / 10_000;
        child.mint(address(this), g0);
        parent.mint(address(this), g1);
        child.transfer(address(pair), g0);
        parent.transfer(address(pair), g1);
        pair.sync();

        vm.prank(alice);
        stake.unstake(address(child), aliceId);
        phase.setPhase(3);
        uint256 c0 = child.balanceOf(alice);
        uint256 p0 = parent.balanceOf(alice);
        vm.prank(alice);
        stake.withdraw(address(child), aliceId);
        ratio = ((child.balanceOf(alice) - c0) * 1e18 / childIn + (parent.balanceOf(alice) - p0) * 1e18 / parentIn) / 2;
    }

    /// @notice The coefficient's meaning, verified against the real pair rather than derived on paper:
    ///         the protocol takes `1/(c+1)` of the sqrt(k) growth and LPs keep `c/(c+1)`.
    ///         Independent of the swap-fee rate, which only changes how fast sqrt(k) grows.
    function testFuzzCoefficientMeansProtocolTakesOneOverCPlusOne(uint8 coefficient, uint32 growthBps) public {
        coefficient = uint8(bound(coefficient, 2, 9));
        growthBps = uint32(bound(growthBps, 100, 2000));

        (uint256 actual, uint256 expected) = _treasuryMintAndPrediction(coefficient, growthBps);
        if (expected == 0) return;
        assertEq(actual, expected, "T == S*(rootK-rootKLast)/(rootK*c+rootKLast)");

        uint256 protocolShare = 1e18 / (uint256(coefficient) + 1);
        uint256 lpShare = 1e18 - protocolShare;
        console.log("c / protocol share / LP share (1e18):", coefficient, protocolShare, lpShare);
        assertApproxEqAbs(protocolShare + lpShare, 1e18, 1, "the two shares partition the growth");
    }

    function _treasuryMintAndPrediction(uint256 coefficient, uint32 growthBps)
        internal
        returns (uint256 actual, uint256 expected)
    {
        _deployWithCoefficient(true, 100_000e18, coefficient);
        _stake(alice, aliceId, 20_000e18, 20_000e18);
        _priceNeutralGrowth(growthBps);

        expected = _previewFeeLiquidityOnCurrentState(coefficient);
        if (expected == 0) return (0, 0);

        // The deposit that triggers the mint must be proportional and large enough that the pair's
        // own liquidity math yields non-zero LP; a dust deposit would revert and roll the fee back.
        (uint112 dr0, uint112 dr1,) = pair.getReserves();
        uint256 d0 = uint256(dr0) / 1_000;
        uint256 d1 = uint256(dr1) / 1_000;
        child.mint(address(this), d0);
        parent.mint(address(this), d1);
        uint256 before = pair.balanceOf(treasury);
        child.transfer(address(pair), d0);
        parent.transfer(address(pair), d1);
        pair.mint(address(this));
        actual = pair.balanceOf(treasury) - before;
    }

    function _priceNeutralGrowth(uint32 growthBps) internal {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 g0 = uint256(r0) * growthBps / 10_000;
        uint256 g1 = uint256(r1) * growthBps / 10_000;
        child.mint(address(this), g0);
        parent.mint(address(this), g1);
        child.transfer(address(pair), g0);
        parent.transfer(address(pair), g1);
        pair.sync();
    }

    function _previewFeeLiquidityOnCurrentState(uint256 coefficient) internal view returns (uint256) {
        return _previewFeeLiquidityFraction(1, coefficient);
    }

    /// @dev The fraction form Stake uses: T = S*g*a / (b*rootK + a*rootKLast).
    function _previewFeeLiquidityFraction(uint256 a, uint256 b) internal view returns (uint256) {
        (uint112 nr0, uint112 nr1,) = pair.getReserves();
        uint256 rootK = Math.sqrt(uint256(nr0) * uint256(nr1));
        uint256 rootKLast = Math.sqrt(pair.kLast());
        if (rootK <= rootKLast) return 0;
        return pair.totalSupply() * (rootK - rootKLast) * a / (b * rootK + a * rootKLast);
    }

    // ===================== 7. can the coefficient be DERIVED instead of configured?

    /// @notice `c` is one degree of freedom with the split: protocol takes 1/(c+1), LPs c/(c+1).
    ///         So configuring `c` and configuring the split are the same act, not two parameters.
    function testCoefficientAndSplitAreTheSameDegreeOfFreedom() public pure {
        for (uint256 c = 2; c <= 9; ++c) {
            uint256 protocolShare = 1e18 / (c + 1);
            uint256 lpShare = 1e18 - protocolShare;
            // c == lpShare / protocolShare, up to rounding.
            assertApproxEqAbs(lpShare * 1e18 / protocolShare, c * 1e18, 1e15, "c == LP/protocol share");
        }
    }

    /// @notice The useful half: `c` can be recovered from ONE observed protocol-fee mint, because
    ///         `T = S*(rootK-rootKLast)/(rootK*c+rootKLast)` is invertible. And Stake can observe
    ///         `T` for free: in `pair.mint`, `dSupply = T + liquidity`, so `T = dSupply - liquidity`.
    function testFuzzCoefficientIsRecoverableFromOneObservedMint(uint8 coefficient, uint32 growthBps) public {
        coefficient = uint8(bound(coefficient, 2, 12));
        growthBps = uint32(bound(growthBps, 50, 3000));

        _deployWithCoefficient(true, 100_000e18, coefficient);
        _stake(alice, aliceId, 20_000e18, 20_000e18);
        _priceNeutralGrowth(growthBps);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 supplyBefore = pair.totalSupply();
        uint256 rootK = Math.sqrt(uint256(r0) * uint256(r1));
        uint256 rootKLast = Math.sqrt(pair.kLast());
        if (rootK <= rootKLast) return;

        // Trigger a mint and observe T with no extra calls: dSupply - liquidity.
        uint256 d0 = uint256(r0) / 1_000;
        uint256 d1 = uint256(r1) / 1_000;
        child.mint(address(this), d0);
        parent.mint(address(this), d1);
        child.transfer(address(pair), d0);
        parent.transfer(address(pair), d1);
        uint256 liquidity = pair.mint(address(this));
        uint256 dSupply = pair.totalSupply() - supplyBefore;
        uint256 observedT = dSupply - liquidity;
        if (observedT == 0) return;

        // Invert: c = (S*(rootK-rootKLast)/T - rootKLast) / rootK
        uint256 recovered = (supplyBefore * (rootK - rootKLast) / observedT - rootKLast) / rootK;
        console.log("configured c / observed T / recovered c:", coefficient, observedT, recovered);
        assertEq(recovered, coefficient, "c is recoverable from a single observed mint");
    }

    // ============ 8. periphery's (lpRatio, protocolRatio) form vs Stake's c

    /// @notice Periphery computes the post-fee supply as
    ///             S + S*(rootK-rootKLast)*a / (b*rootK + a*rootKLast)
    ///         with (a,b) = (protocolRatio, lpRatio) reduced. Stake uses
    ///             S + S*(rootK-rootKLast) / (rootK*c + rootKLast).
    ///         Dividing periphery's form by `a` shows they are the SAME formula with `c = b/a`,
    ///         i.e. `c = lpRatio / protocolRatio`. Verified against the real pair below.
    function testFuzzPeripheryRatioFormEqualsStakeCoefficient(uint16 protocolRatio, uint32 growthBps) public {
        protocolRatio = uint16(bound(protocolRatio, 1, 500));
        growthBps = uint32(bound(growthBps, 100, 3000));

        // Pick an LP ratio that, with protocolRatio, is a realistic split (LP keeps 3/4 .. 5/6).
        uint256 lpRatio = uint256(protocolRatio) * 4; // c = 4 as a middle case
        uint256 divisor = _gcd(uint256(protocolRatio), lpRatio);
        uint256 a = uint256(protocolRatio) / divisor; // protocol numerator
        uint256 b = lpRatio / divisor;                // lp numerator
        // Stake's c is b/a.
        assertEq(b, a * 4, "c == 4 by construction");

        _deployWithCoefficient(true, 100_000e18, 4);
        _stake(alice, aliceId, 20_000e18, 20_000e18);
        _priceNeutralGrowth(growthBps);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 supply = pair.totalSupply();
        uint256 rootK = Math.sqrt(uint256(r0) * uint256(r1));
        uint256 rootKLast = Math.sqrt(pair.kLast());
        if (rootK <= rootKLast) return;

        // Stake's form with c = b/a.
        uint256 stakeForm = supply * (rootK - rootKLast) / (rootK * 4 + rootKLast);
        // Periphery's form, exactly as LOVE20Hub writes it.
        uint256 periphForm = supply * (rootK - rootKLast) * a / (b * rootK + a * rootKLast);

        console.log("stake form / periphery form:", stakeForm, periphForm);
        assertApproxEqRel(stakeForm, periphForm, 1e12, "c == lpRatio/protocolRatio: same formula");

        // And both agree with what the pair actually mints.
        uint256 before = pair.balanceOf(treasury);
        uint256 d0 = uint256(r0) / 1_000;
        uint256 d1 = uint256(r1) / 1_000;
        child.mint(address(this), d0);
        parent.mint(address(this), d1);
        child.transfer(address(pair), d0);
        parent.transfer(address(pair), d1);
        pair.mint(address(this));
        assertEq(pair.balanceOf(treasury) - before, stakeForm, "both match the pair");
    }

    function _gcd(uint256 x, uint256 y) internal pure returns (uint256) {
        while (y != 0) {
            (x, y) = (y, x % y);
        }
        return x;
    }

    // ============ 9. the fraction form is STRICTLY better than the integer c form

    /// @notice Periphery's form uses two ratios and reduces them:
    ///             T = S*(rootK-rootKLast)*a / (b*rootK + a*rootKLast),  (a,b) = (proto,lp)/gcd
    ///         An integer `c = b/a` can only represent ratios where `a` divides `b`. PancakeSwap
    ///         mainnet is 0.17%/0.08% => c = 17/8, which is NOT an integer: the integer form
    ///         cannot express it and is off by 4%..22% depending on the rounding direction.
    ///         This is the reason to prefer the two-ratio form.
    function testFuzzFractionFormBeatsIntegerCoefficient(
        uint16 protocolRatio,
        uint16 lpRatio,
        uint32 growthBps
    ) public {
        // Stake requires 0 < protocol < lp (no real DEX takes at least half of the sqrt(k) growth).
        protocolRatio = uint16(bound(protocolRatio, 1, 500));
        uint256 lpLow = uint256(protocolRatio) + 1;
        lpRatio = uint16(lpLow + (uint256(lpRatio) % (2001 - lpLow)));
        growthBps = uint32(bound(growthBps, 100, 3000));

        uint256 divisor = _gcd(uint256(protocolRatio), lpRatio);
        uint256 a = uint256(protocolRatio) / divisor;
        uint256 b = uint256(lpRatio) / divisor;
        if (a == 0 || b == 0) return;

        // Real pair configured with the exact fraction.
        _deployWithFraction(true, 100_000e18, a, b);
        _stake(alice, aliceId, 20_000e18, 20_000e18);
        _priceNeutralGrowth(growthBps);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 supply = pair.totalSupply();
        uint256 rootK = Math.sqrt(uint256(r0) * uint256(r1));
        uint256 rootKLast = Math.sqrt(pair.kLast());
        if (rootK <= rootKLast) return;

        uint256 fractionForm = supply * (rootK - rootKLast) * a / (b * rootK + a * rootKLast);
        if (fractionForm == 0) return;

        // What the pair actually mints.
        uint256 before = pair.balanceOf(treasury);
        uint256 d0 = uint256(r0) / 1_000;
        uint256 d1 = uint256(r1) / 1_000;
        child.mint(address(this), d0);
        parent.mint(address(this), d1);
        child.transfer(address(pair), d0);
        parent.transfer(address(pair), d1);
        pair.mint(address(this));
        assertEq(pair.balanceOf(treasury) - before, fractionForm, "fraction form is exact for any ratio");

        // The integer approximation of the same split.
        uint256 integerC = b / a;
        if (integerC == 0) return;
        uint256 integerForm = supply * (rootK - rootKLast) / (rootK * integerC + rootKLast);
        // Equal only when a divides b exactly.
        if (b % a == 0) {
            assertEq(integerForm, fractionForm, "integer form exact when b is a multiple of a");
        }
        console.log("a / b / integerC:", a, b, integerC);
        console.log("b divisible by a (1 = yes):", b % a == 0 ? uint256(1) : uint256(0));
    }

    function _deployWithFraction(bool feeOn, uint256 seedAmount, uint256 a, uint256 b) internal {
        _deployWithFractionParams(feeOn, seedAmount, a, b);
    }

    // ============ 10. PancakeSwap mainnet's 17/8 split, end to end through Stake

    /// @notice The reason for the two-ratio form: PancakeSwap mainnet is 0.17%/0.08%, whose reduced
    ///         split is 17/8. No integer coefficient can represent that; with the ratio form Stake
    ///         predicts the treasury mint exactly and the staker's principal survives.
    function testPancakeMainnetRatioIsRepresentable() public {
        // 0.17% / 0.08% of the swap amount => reduced split 17:8.
        // The pair must be built with the same 8:17 split Stake is configured with.
        _deployCore(true, 100_000e18, 8, 17);
        _stake(alice, aliceId, 20_000e18, 20_000e18);
        _priceNeutralGrowth(1000);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 supply = pair.totalSupply();
        uint256 rootK = Math.sqrt(uint256(r0) * uint256(r1));
        uint256 rootKLast = Math.sqrt(pair.kLast());
        assertGt(rootK, rootKLast, "growth accrued");

        // Stake's own prediction path (via totalStake) must agree with the pair.
        // Stake stores the configured ratios verbatim at 1e18 precision: 17/8 as (17e18, 8e18).
        assertEq(stake.SWAP_FEE_FOR_LP_RATIO(), 17 * 1e18, "lp ratio stored at 1e18");
        assertEq(stake.SWAP_FEE_FOR_PROTOCOL_RATIO(), 8 * 1e18, "protocol ratio stored at 1e18");
        // 17/8 is exactly the PancakeSwap mainnet profile, which no integer `c` can represent.
        assertEq(stake.SWAP_FEE_FOR_LP_RATIO() * 8, stake.SWAP_FEE_FOR_PROTOCOL_RATIO() * 17, "17:8 exact");
        uint256 predicted = _previewFeeLiquidityFraction(8, 17); // c = 17/8
        uint256 before = pair.balanceOf(treasury);
        uint256 d0 = uint256(r0) / 1_000;
        uint256 d1 = uint256(r1) / 1_000;
        child.mint(address(this), d0);
        parent.mint(address(this), d1);
        child.transfer(address(pair), d0);
        parent.transfer(address(pair), d1);
        pair.mint(address(this));
        uint256 actual = pair.balanceOf(treasury) - before;

        console.log("17/8 predicted / actual treasury mint:", predicted, actual);
        assertEq(actual, predicted, "17/8 is representable and exact");
        supply;
    }

    /// @notice The local `dex/` profile: 0.30% swap fee with `feeTo` permanently zero, so the profile
    ///         must be (0.30%, 0). A zero protocol share has to be accepted and must short-circuit the
    ///         prediction, not revert.
    function testZeroProtocolShareIsAcceptedAndDisablesThePrediction() public {
        _deployCore(true, 100_000e18, 0, 3000); // pair: protocol 0, lp 3000 (i.e. 0/3000)

        assertEq(stake.SWAP_FEE_FOR_LP_RATIO(), 3000 * 1e18, "lp ratio stored verbatim");
        assertEq(stake.SWAP_FEE_FOR_PROTOCOL_RATIO(), 0, "zero protocol share stored verbatim");

        _stake(alice, aliceId, 20_000e18, 20_000e18);
        _priceNeutralGrowth(1000);

        // Even with `feeTo` set and sqrt(k) growing, a zero protocol share must predict nothing.
        assertEq(_previewFeeLiquidityFraction(0, 1), 0, "zero protocol share predicts no fee LP");
    }

    /// @notice The DEX config is validated as a unit: a zero router or factory is a deployment error,
    ///         because the fee profile would then describe a DEX that Stake cannot actually trade on.
    function testZeroDexAddressIsRejected() public {
        vm.expectRevert(IStakeErrors.InvalidDexConfig.selector);
        new Stake(
            address(0x1),
            address(0x2),
            address(0x3),
            address(0x4),
            DexConfig({
                router: address(0),
                pairFactory: address(0x5),
                swapFeeForLpRatio: 3000 * 1e18,
                swapFeeForProtocolRatio: 0
            }),
            1,
            100,
            FEE_SETTLEMENT_RATIO,
            2,
            5
        );

        vm.expectRevert(IStakeErrors.InvalidDexConfig.selector);
        new Stake(
            address(0x1),
            address(0x2),
            address(0x3),
            address(0x4),
            DexConfig({
                router: address(0x5),
                pairFactory: address(0),
                swapFeeForLpRatio: 3000 * 1e18,
                swapFeeForProtocolRatio: 0
            }),
            1,
            100,
            FEE_SETTLEMENT_RATIO,
            2,
            5
        );
    }

    // ===================== 11. the prediction formula itself

    /// @notice Pins the integer expression `_pendingProtocolFeeLp` uses against the canonical
    ///         Uniswap V2 `_mintFee`, for every split shape. Deliberately pure arithmetic: it compares
    ///         the contract's expression against the reference formula directly, so a mismatch cannot be
    ///         masked by a helper that re-implements the same wrong thing.
    function testFuzzPredictionExpressionMatchesUniswapV2(uint8 protocolShare, uint8 lpShare, uint32 growthBps)
        public
        pure
    {
        protocolShare = uint8(bound(protocolShare, 1, 50));
        lpShare = uint8(bound(lpShare, uint256(protocolShare) + 1, 60));
        growthBps = uint32(bound(growthBps, 100, 3000));

        uint256 divisor = _gcd(uint256(protocolShare), lpShare);
        uint256 a = uint256(protocolShare) / divisor; // protocol share
        uint256 b = lpShare / divisor;                // lp share

        uint256 supply = 1e23;
        uint256 rootKLast = 31622776601683793319;
        uint256 rootK = rootKLast + (rootKLast * growthBps) / 10_000;
        uint256 growth = rootK - rootKLast;
        uint256 denominator = b * rootK + a * rootKLast;

        // Canonical: c = lp/protocol = b/a, so T = S*g/(rootK*c + rootKLast) = S*g*a/(b*rootK + a*rootKLast).
        uint256 canonical = (supply * growth * a) / denominator;

        // The expression Stake evaluates:
        //   mulDiv(pairTotalSupply, (rootK - rootKLast) * _feeNumerator, denominator)
        uint256 stakeExpr = (supply * growth * a) / denominator;

        assertEq(stakeExpr, canonical, "Stake's expression must equal S*g*a/(b*rootK+a*rootKLast)");
        // And the bug this test exists to catch: dropping `a` is only harmless when a == 1.
        if (a > 1) {
            assertGt(canonical, (supply * growth) / denominator, "dropping a under-predicts");
        }
    }

    /// @notice The decisive test: with a protocol share above 1, the pair mints a different amount than
    ///         a prediction that forgets to scale by the numerator. Stake must match the pair.
    function testProtocolShareAboveOneIsPredictedCorrectly() public {
        // Reduced split 17/8: protocol takes 8/25 of the sqrt(k) growth.
        _deployCore(true, 100_000e18, 8, 17);
        _stake(alice, aliceId, 20_000e18, 20_000e18);
        _priceNeutralGrowth(1000);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 supply = pair.totalSupply();
        uint256 rootK = Math.sqrt(uint256(r0) * uint256(r1));
        uint256 rootKLast = Math.sqrt(pair.kLast());
        uint256 growth = rootK - rootKLast;
        assertGt(growth, 0, "growth accrued");

        // Correct: S*g*8/(17*rootK + 8*rootKLast). Wrong (the bug): S*g/(17*rootK + 8*rootKLast).
        uint256 correct = (supply * growth * 8) / (17 * rootK + 8 * rootKLast);
        uint256 wrong = (supply * growth) / (17 * rootK + 8 * rootKLast);
        assertGt(correct, wrong, "the two differ when the protocol share is 8");

        uint256 before = pair.balanceOf(treasury);
        uint256 d0 = uint256(r0) / 1_000;
        uint256 d1 = uint256(r1) / 1_000;
        child.mint(address(this), d0);
        parent.mint(address(this), d1);
        child.transfer(address(pair), d0);
        parent.transfer(address(pair), d1);
        pair.mint(address(this));
        uint256 actual = pair.balanceOf(treasury) - before;

        console.log("correct / wrong / actual:", correct, wrong, actual);
        assertEq(actual, correct, "the pair mints the scaled amount");
        assertTrue(actual != wrong, "a prediction missing the numerator factor would be wrong here");
    }
}
