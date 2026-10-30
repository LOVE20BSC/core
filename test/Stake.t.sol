// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Stake} from "../src/Stake.sol";
import {IStakeErrors} from "../src/interfaces/IStake.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LOVE20Token} from "../src/LOVE20Token.sol";
import {MemberNFT} from "../src/MemberNFT.sol";

/// @notice Mock contracts for testing

/// Mock Phase contract
contract MockPhase {
    uint256 private _currentPhase;

    function currentPhase() external view returns (uint256) {
        return _currentPhase;
    }

    function setPhase(uint256 phase) external {
        _currentPhase = phase;
    }

    function sync(address, uint256) external {}
}

/// Mock Vote contract
contract MockVote {
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) private _voteAmounts;
    address public SUBMIT_ADDRESS;

    function setSubmitAddress(address submitAddress) external {
        SUBMIT_ADDRESS = submitAddress;
    }

    function voteAmountByMemberId(address tokenAddress, uint256 round, uint256 memberId)
        external
        view
        returns (uint256)
    {
        return _voteAmounts[tokenAddress][round][memberId];
    }

    function setVoteAmount(address tokenAddress, uint256 round, uint256 memberId, uint256 voteAmount) external {
        _voteAmounts[tokenAddress][round][memberId] = voteAmount;
    }
}

contract MockLaunch {
    mapping(address => bool) public isLOVE20Token;

    function register(address token) external {
        isLOVE20Token[token] = true;
    }
}

contract MockSubmit {
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) private _proposalIdBySubmitter;

    function proposalIdBySubmitter(address tokenAddress, uint256 round, uint256 submitterId)
        external
        view
        returns (uint256)
    {
        return _proposalIdBySubmitter[tokenAddress][round][submitterId];
    }

    function setProposalIdBySubmitter(address tokenAddress, uint256 round, uint256 submitterId, uint256 proposalId)
        external
    {
        _proposalIdBySubmitter[tokenAddress][round][submitterId] = proposalId;
    }
}

/// Mock Router for swapping
contract MockRouter {
    function getAmountsOut(uint256 amountIn, address[] calldata) external pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn; // 1:1 swap for simplicity
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256,
        address[] calldata,
        address,
        uint256
    ) external pure returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn;
    }
}

/// Mock Pair contract
contract MockPair {
    address public token0;
    address public token1;
    uint256 private _reserve0;
    uint256 private _reserve1;
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) {
        reserve0 = uint112(_reserve0);
        reserve1 = uint112(_reserve1);
        blockTimestampLast = uint32(block.timestamp);
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }

    function setReserves(uint256 reserve0_, uint256 reserve1_) external {
        _reserve0 = reserve0_;
        _reserve1 = reserve1_;
    }

    function mint(address to) external returns (uint256 liquidity) {
        // Simple LP minting: sqrt(token0 * token1)
        LOVE20Token token0Contract = LOVE20Token(token0);
        LOVE20Token token1Contract = LOVE20Token(token1);

        uint256 balance0 = token0Contract.balanceOf(address(this));
        uint256 balance1 = token1Contract.balanceOf(address(this));

        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        if (_totalSupply == 0) {
            liquidity = _sqrt(amount0 * amount1);
        } else {
            liquidity = _min(
                (amount0 * _totalSupply) / _reserve0,
                (amount1 * _totalSupply) / _reserve1
            );
        }

        require(liquidity > 0, "INSUFFICIENT_LIQUIDITY_MINTED");

        _reserve0 = balance0;
        _reserve1 = balance1;
        _totalSupply += liquidity;
        _balances[to] += liquidity;

        return liquidity;
    }

    function burn(address to) external returns (uint256 amount0, uint256 amount1) {
        LOVE20Token token0Contract = LOVE20Token(token0);
        LOVE20Token token1Contract = LOVE20Token(token1);

        uint256 liquidity = _balances[address(this)];
        require(liquidity > 0, "INSUFFICIENT_LIQUIDITY");

        // Calculate amounts proportional to liquidity
        amount0 = (liquidity * _reserve0) / _totalSupply;
        amount1 = (liquidity * _reserve1) / _totalSupply;

        require(amount0 > 0 && amount1 > 0, "INSUFFICIENT_LIQUIDITY_BURNED");

        _balances[address(this)] -= liquidity;
        _totalSupply -= liquidity;
        _reserve0 -= amount0;
        _reserve1 -= amount1;

        // Transfer tokens out
        require(token0Contract.transfer(to, amount0), "Transfer failed");
        require(token1Contract.transfer(to, amount1), "Transfer failed");
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

/// Mock Pair Factory
contract MockPairFactory {
    mapping(address => mapping(address => address)) private _pairs;

    function getPair(address tokenA, address tokenB) external view returns (address) {
        return _pairs[tokenA][tokenB];
    }

    function setPair(address tokenA, address tokenB, address pair) external {
        _pairs[tokenA][tokenB] = pair;
        _pairs[tokenB][tokenA] = pair;
    }
}


contract StakeTest {
    // Constants
    uint256 private constant BASE_DIVISOR = 1e8;
    uint256 private constant BYTES_THRESHOLD = 7;
    uint256 private constant MULTIPLIER = 10;
    uint256 private constant MAX_NAME_LENGTH = 32;
    uint256 private constant PROMISED_WAITING_PHASES_MIN = 1;
    uint256 private constant PROMISED_WAITING_PHASES_MAX = 100;
    uint256 private constant FEE_SETTLEMENT_RATIO = 1e15;

    // Core contracts
    Stake public stake;
    MemberNFT public memberNFT;
    MockPhase public phase;
    MockVote public vote;
    MockSubmit public mockSubmit;
    MockLaunch public mockLaunch;
    MockRouter public router;
    MockPairFactory public pairFactory;

    // Tokens
    LOVE20Token public parentToken;
    LOVE20Token public childToken;
    MockPair public pair;

    // Test accounts
    address public owner1 = address(0x1001);
    address public owner2 = address(0x1002);

    uint256 public memberId1;
    uint256 public memberId2;
    uint256 public memberId3;

    function setUp() public {
        // Deploy mock dependencies
        phase = new MockPhase();
        phase.setPhase(1);

        vote = new MockVote();
        mockSubmit = new MockSubmit();
        mockLaunch = new MockLaunch();
        vote.setSubmitAddress(address(mockSubmit));
        router = new MockRouter();
        pairFactory = new MockPairFactory();

        // Deploy MemberNFT
        memberNFT = new MemberNFT(BASE_DIVISOR, BYTES_THRESHOLD, MULTIPLIER, MAX_NAME_LENGTH);

        // Deploy Stake
        stake = new Stake();

        // Deploy parent token (root token)
        parentToken = new LOVE20Token(
            "Parent Token",
            "PARENT",
            1000000e18, // initial supply
            2000000e18, // max supply
            address(this), // distributor
            address(this), // minter
            address(this) // parent is a code-bearing test contract
        );

        // Initialize MemberNFT with parent token as fee token
        memberNFT.init(address(parentToken));

        // Deploy child token
        childToken = new LOVE20Token(
            "Child Token",
            "CHILD",
            1000000e18,
            2000000e18,
            address(this),
            address(this),
            address(parentToken) // parent token
        );
        mockLaunch.register(address(childToken));

        // Deploy pair
        pair = new MockPair(address(childToken), address(parentToken));
        pair.setReserves(100000e18, 100000e18);

        // Register pair in factory
        pairFactory.setPair(address(childToken), address(parentToken), address(pair));

        // Initialize Stake
        stake.init(
            address(phase),
            address(memberNFT),
            address(vote),
            address(mockLaunch),
            address(router),
            address(pairFactory),
            PROMISED_WAITING_PHASES_MIN,
            PROMISED_WAITING_PHASES_MAX,
            FEE_SETTLEMENT_RATIO
        );

        // Fund test accounts
        parentToken.transfer(owner1, 100000e18);
        parentToken.transfer(owner2, 100000e18);
        childToken.transfer(owner1, 100000e18);
        childToken.transfer(owner2, 100000e18);

        // Transfer initial liquidity to pair
        childToken.transfer(address(pair), 100000e18);
        parentToken.transfer(address(pair), 100000e18);

        // Mint member NFTs
        vm().prank(owner1);
        parentToken.approve(address(memberNFT), type(uint256).max);
        vm().prank(owner1);
        (memberId1, ) = memberNFT.mint("owner1");

        vm().prank(owner2);
        parentToken.approve(address(memberNFT), type(uint256).max);
        vm().prank(owner2);
        (memberId2, ) = memberNFT.mint("owner2");

        vm().prank(owner1);
        (memberId3, ) = memberNFT.mint("owner3");
    }

    // ============ Helper Functions ============

    function vm() private pure returns (Vm) {
        return Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    }

    function stakeAsOwner(
        address owner,
        uint256 memberId,
        uint256 tokenAmount,
        uint256 parentAmount,
        uint256 promisedPhases
    ) internal returns (uint256 govVotesAdded, uint256 liquiditySharesAdded) {
        vm().prank(owner);
        childToken.approve(address(stake), tokenAmount);
        vm().prank(owner);
        parentToken.approve(address(stake), parentAmount);

        vm().prank(owner);
        return stake.stakeLiquidity(
            address(childToken),
            tokenAmount,
            parentAmount,
            0.05e18, // 5% slippage
            promisedPhases,
            memberId
        );
    }

    function _validGovVotes(address tokenAddress, uint256 memberId) internal view returns (uint256) {
        return stake.validGovVotes(tokenAddress, phase.currentPhase(), memberId);
    }

    function _totalValidGovVotes(address tokenAddress) internal view returns (uint256) {
        return stake.totalValidGovVotes(tokenAddress, phase.currentPhase());
    }

    /// @dev `StakeWithdrawn` payload order: promisedWaitingPhases, liquidityShares, the two token
    ///      amounts, boostShares, lpBurned, lpToMember, totalLiquidityShares, totalBoostShares.
    function _withdrawnLp(bytes memory data) internal pure returns (uint256 lpBurned, uint256 lpToMember) {
        (,,,,, lpBurned, lpToMember, , ) =
            abi.decode(data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256));
    }

    function _expectRevertData(
        address target,
        bytes memory callData,
        bytes memory expected,
        string memory note
    ) private {
        (bool success, bytes memory data) = target.call(callData);
        require(!success, note);
        require(keccak256(data) == keccak256(expected), note);
    }

    function _revertedWith(address caller, bytes memory callData, bytes memory expected)
        private
        returns (bool)
    {
        vm().prank(caller);
        (bool success, bytes memory data) = address(stake).call(callData);
        return !success && keccak256(data) == keccak256(expected);
    }

    function _initCall(
        address phase_,
        address memberNFT_,
        address vote_,
        address launch_,
        address router_,
        address pairFactory_,
        uint256 min_,
        uint256 max_,
        uint256 ratio_
    ) private pure returns (bytes memory) {
        return abi.encodeWithSelector(
            Stake.init.selector, phase_, memberNFT_, vote_, launch_, router_, pairFactory_, min_, max_, ratio_
        );
    }

    // ============ Init Tests ============

    function testInitializesCorrectly() external view {
        require(stake.initialized(), "Should be initialized");
        require(stake.PHASE_ADDRESS() == address(phase), "Phase address mismatch");
        require(stake.MEMBER_NFT_ADDRESS() == address(memberNFT), "MemberNFT address mismatch");
        require(stake.VOTE_ADDRESS() == address(vote), "Vote address mismatch");
        require(stake.LAUNCH_ADDRESS() == address(mockLaunch), "Launch address mismatch");
        require(stake.ROUTER_ADDRESS() == address(router), "Router address mismatch");
        require(stake.PAIR_FACTORY_ADDRESS() == address(pairFactory), "PairFactory address mismatch");
        require(stake.PROMISED_WAITING_PHASES_MIN() == PROMISED_WAITING_PHASES_MIN, "Min phases mismatch");
        require(stake.PROMISED_WAITING_PHASES_MAX() == PROMISED_WAITING_PHASES_MAX, "Max phases mismatch");
        require(stake.FEE_SETTLEMENT_RATIO() == FEE_SETTLEMENT_RATIO, "Fee ratio mismatch");
    }


    function testInitRevertsIfAlreadyInitialized() external {
        _expectRevertData(
            address(stake),
            _initCall(
                address(phase),
                address(memberNFT),
                address(vote),
                address(mockLaunch),
                address(router),
                address(pairFactory),
                PROMISED_WAITING_PHASES_MIN,
                PROMISED_WAITING_PHASES_MAX,
                FEE_SETTLEMENT_RATIO
            ),
            abi.encodeWithSelector(IStakeErrors.AlreadyInitialized.selector),
            "Should revert on double init"
        );
    }

    // ============ Stake Liquidity Tests ============

    function testStakeLiquidityBasic() external {
        (uint256 govVotesAdded, uint256 liquiditySharesAdded) =
            stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        require(govVotesAdded > 0, "Gov votes should be added");
        require(liquiditySharesAdded > 0, "Liquidity shares should be added");

        (uint256 shares, , uint256 promisedPhases, , , ) =
            stake.memberStake(address(childToken), memberId1);

        require(shares == liquiditySharesAdded, "Shares mismatch");
        require(promisedPhases == 10, "Promised phases mismatch");
    }


    function testStakeLiquidityRevertsAtRoundZero() external {
        phase.setPhase(0);

        vm().prank(owner1);
        childToken.approve(address(stake), 1000e18);
        vm().prank(owner1);
        parentToken.approve(address(stake), 1000e18);

        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(
                Stake.stakeLiquidity.selector, address(childToken), 1000e18, 1000e18, 0.05e18, 10, memberId1
            ),
            abi.encodeWithSelector(IStakeErrors.NotAllowedToStakeAtRoundZero.selector),
            "Should revert at round zero"
        );
    }

    function testStakeLiquidityRevertsWithInvalidPromisedPhases() external {
        // Too low
        vm().prank(owner1);
        childToken.approve(address(stake), 1000e18);
        vm().prank(owner1);
        parentToken.approve(address(stake), 1000e18);

        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(
                Stake.stakeLiquidity.selector, address(childToken), 1000e18, 1000e18, 0.05e18, 0, memberId1
            ),
            abi.encodeWithSelector(IStakeErrors.InvalidPromisedWaitingPhases.selector, 0, 1, 100),
            "Should revert with promised phases too low"
        );

        // Too high
        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(
                Stake.stakeLiquidity.selector, address(childToken), 1000e18, 1000e18, 0.05e18, 101, memberId1
            ),
            abi.encodeWithSelector(IStakeErrors.InvalidPromisedWaitingPhases.selector, 101, 1, 100),
            "Should revert with promised phases too high"
        );
    }

    function testStakeLiquidityRevertsWithZeroAmount() external {
        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(
                Stake.stakeLiquidity.selector, address(childToken), 0, 1000e18, 0.05e18, 10, memberId1
            ),
            abi.encodeWithSelector(IStakeErrors.ZeroTokenAmount.selector),
            "Should revert with zero token amount"
        );

        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(
                Stake.stakeLiquidity.selector, address(childToken), 1000e18, 0, 0.05e18, 10, memberId1
            ),
            abi.encodeWithSelector(IStakeErrors.ZeroParentTokenAmount.selector),
            "Should revert with zero parent amount"
        );
    }

    function testStakeLiquidityIncreasesPromisedPhases() external {
        // First stake with 5 phases
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 5);

        (uint256 shares1, , uint256 phases1, , , ) = stake.memberStake(address(childToken), memberId1);
        require(phases1 == 5, "Should have 5 promised phases");

        uint256 govVotes1 = _validGovVotes(address(childToken), memberId1);
        require(govVotes1 == shares1 * 5, "Gov votes should match shares * phases");

        // Stake again with 10 phases (increase)
        (uint256 govVotesAdded, uint256 sharesAdded) = stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        (uint256 shares2, , uint256 phases2, , , ) = stake.memberStake(address(childToken), memberId1);
        require(phases2 == 10, "Should have updated to 10 promised phases");
        require(shares2 == shares1 + sharesAdded, "Shares should accumulate");

        uint256 govVotes2 = _validGovVotes(address(childToken), memberId1);
        require(govVotes2 == shares2 * 10, "Gov votes should reflect new phases");
        require(govVotesAdded == shares2 * 10 - shares1 * 5, "Gov votes added should be correct");
    }

    function testStakeLiquidityRevertsWhenDecreasingPromisedPhases() external {
        // First stake with 10 phases
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        // Try to stake again with 5 phases (decrease)
        vm().prank(owner1);
        childToken.approve(address(stake), 1000e18);
        vm().prank(owner1);
        parentToken.approve(address(stake), 1000e18);

        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(
                Stake.stakeLiquidity.selector, address(childToken), 1000e18, 1000e18, 0.05e18, 5, memberId1
            ),
            abi.encodeWithSelector(IStakeErrors.PromisedWaitingPhasesDecreased.selector, 5, 10),
            "Should revert when decreasing promised phases"
        );
    }

    // ============ Boost Tests ============

    function testStakeBoostBasic() external {
        // First stake some liquidity
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        uint256 boostAmount = 500e18;
        vm().prank(owner1);
        childToken.approve(address(stake), boostAmount);

        vm().prank(owner1);
        uint256 govVotesAdded = stake.stakeBoost(address(childToken), boostAmount, 10, memberId1);

        require(govVotesAdded == 0, "No gov votes added when phases don't increase");

        (uint256 shares, uint256 boostShares, , , , ) = stake.memberStake(address(childToken), memberId1);
        require(boostShares == boostAmount, "Boost shares should match amount");
        require(shares > 0, "Liquidity shares should remain");
    }


    function testStakeBoostRevertsWithoutLiquidity() external {
        vm().prank(owner1);
        childToken.approve(address(stake), 500e18);

        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(Stake.stakeBoost.selector, address(childToken), 500e18, 10, memberId1),
            abi.encodeWithSelector(IStakeErrors.NoStakedLiquidity.selector, address(childToken), memberId1),
            "Should revert when no liquidity staked"
        );
    }

    function testStakeBoostIncreasesGovVotes() external {
        // First stake with 5 phases
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 5);

        (uint256 shares, , , , , ) = stake.memberStake(address(childToken), memberId1);
        uint256 govVotesBefore = _validGovVotes(address(childToken), memberId1);

        // Boost with increased phases
        vm().prank(owner1);
        childToken.approve(address(stake), 500e18);

        vm().prank(owner1);
        uint256 govVotesAdded = stake.stakeBoost(address(childToken), 500e18, 10, memberId1);

        uint256 govVotesAfter = _validGovVotes(address(childToken), memberId1);
        require(govVotesAdded == shares * 5, "Should add gov votes for phase increase");
        require(govVotesAfter == govVotesBefore + govVotesAdded, "Gov votes should increase");
    }

    // ============ Unstake Tests ============

    function testUnstakeMarksForWithdrawal() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        (, , , uint256 unlockBefore, , ) = stake.memberStake(address(childToken), memberId1);
        require(unlockBefore == 0, "Should not be unlocking yet");

        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);

        (, , , uint256 unlockAfter, , ) = stake.memberStake(address(childToken), memberId1);
        require(unlockAfter == 1, "Should mark unlock at current phase");

        uint256 govVotes = _validGovVotes(address(childToken), memberId1);
        require(govVotes == 0, "Gov votes should be zero after unstake");
    }

    function testUnstakeRevertsIfAlreadyRequested() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);

        require(_revertedWith(
            owner1,
            abi.encodeWithSelector(Stake.unstake.selector, address(childToken), memberId1),
            abi.encodeWithSelector(IStakeErrors.UnstakeAlreadyRequested.selector, address(childToken), memberId1)
        ), "Should revert on second unstake request");
    }

    function testUnstakeRevertsIfMemberVotedInCurrentRound() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        vote.setVoteAmount(address(childToken), 1, memberId1, 100);

        vm().prank(owner1);
        vm().expectRevert(
            abi.encodeWithSelector(IStakeErrors.StakeRightsUsed.selector, address(childToken), 1, memberId1)
        );
        stake.unstake(address(childToken), memberId1);

        (, , , uint256 unlockPhase, , ) = stake.memberStake(address(childToken), memberId1);
        require(unlockPhase == 0, "Unlock must not be recorded");
        require(_validGovVotes(address(childToken), memberId1) > 0, "Vote weight must stay live");
    }

    function testUnstakeRevertsIfMemberSubmittedInCurrentRound() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        mockSubmit.setProposalIdBySubmitter(address(childToken), 1, memberId1, 7);

        require(
            _revertedWith(
                owner1,
                abi.encodeWithSelector(Stake.unstake.selector, address(childToken), memberId1),
                abi.encodeWithSelector(IStakeErrors.StakeRightsUsed.selector, address(childToken), 1, memberId1)
            ),
            "Should revert when the member submitted in the current round"
        );
    }

    function testUnstakeSucceedsWhenStakeRightsWereUsedInAPreviousRound() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        vote.setVoteAmount(address(childToken), 1, memberId1, 100);
        phase.setPhase(2);

        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);

        (, , , uint256 unlockPhase, , ) = stake.memberStake(address(childToken), memberId1);
        require(unlockPhase == 2, "Unlock should be recorded in the current round");
    }

    // ============ Withdraw Tests ============

    function testWithdrawRevertsBeforeWaitingPeriod() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);

        // Try to withdraw before waiting period ends
        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(Stake.withdraw.selector, address(childToken), memberId1),
            abi.encodeWithSelector(IStakeErrors.InsufficientWaitingPhases.selector, 1, 11),
            "Should revert before waiting period"
        );
    }

    function testWithdrawAtExactWaitingPeriodEndReverts() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        // Unstake at phase 1
        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);

        // Move to phase 11 (exactly unlockRequestPhase + promisedWaitingPhases)
        phase.setPhase(11);

        // Should still revert at exact boundary
        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(Stake.withdraw.selector, address(childToken), memberId1),
            abi.encodeWithSelector(IStakeErrors.InsufficientWaitingPhases.selector, 11, 11),
            "Should revert at exact waiting period boundary"
        );
    }

    function testWithdrawSucceedsAfterWaitingPeriod() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);

        // Move to phase 12 (one phase after the boundary)
        phase.setPhase(12);

        // Should succeed
        vm().prank(owner1);
        stake.withdraw(address(childToken), memberId1);

        // Verify cleared
        (uint256 shares, , , , , ) = stake.memberStake(address(childToken), memberId1);
        require(shares == 0, "Shares should be cleared after withdraw");
    }

    function testDustWithdrawalReturnsBoostAndClearsShares() external {
        stakeAsOwner(owner1, memberId1, 100e18, 100e18, 1);
        (, uint256 tinyShares) = stakeAsOwner(owner1, memberId3, 1001, 1001, 1);
        require(tinyShares == 1, "expected one LP share");
        vm().prank(owner1);
        childToken.approve(address(stake), 1e18);
        vm().prank(owner1);
        stake.stakeBoost(address(childToken), 1e18, 1, memberId3);

        childToken.transfer(address(pair), 1001);
        parentToken.transfer(address(pair), 1001);
        pair.setReserves(100100e18 + 2002, 100100e18 + 2002);
        vm().prank(owner1);
        stake.unstake(address(childToken), memberId3);
        phase.setPhase(3);

        (uint256 totalSharesBefore,, uint256 withdrawableBefore,, uint256 totalBoostBefore,,) =
            stake.totalStake(address(childToken));
        require(tinyShares * withdrawableBefore / totalSharesBefore == 0, "expected zero LP payout");
        uint256 balanceBefore = childToken.balanceOf(owner1);
        uint256 lpBefore = pair.balanceOf(address(stake));
        vm().prank(owner1);
        stake.withdraw(address(childToken), memberId3);
        require(childToken.balanceOf(owner1) == balanceBefore + 1e18, "boost must be returned");
        require(pair.balanceOf(address(stake)) == lpBefore, "zero payout must not consume LP");
        {
            (uint256 shares, uint256 boost, uint256 waiting, uint256 requested,,) =
                stake.memberStake(address(childToken), memberId3);
            require(shares == 0 && boost == 0 && waiting == 0 && requested == 0, "position must be cleared");
        }
        (uint256 totalSharesAfter,, uint256 withdrawableAfter,, uint256 totalBoostAfter,,) =
            stake.totalStake(address(childToken));
        require(totalSharesAfter + tinyShares == totalSharesBefore, "only exiting shares are removed");
        require(withdrawableAfter == withdrawableBefore, "remaining LP must stay in the ledger");
        require(totalBoostAfter + 1e18 == totalBoostBefore, "boost liability must be removed");
    }


    function testWithdrawHandsOverLpWhenItCannotBeSplit() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 1);
        (, uint256 shares) = stakeAsOwner(owner1, memberId3, 1001, 1001, 1);
        require(shares > 0, "expected shares");
        vm().prank(owner1);
        childToken.approve(address(stake), 1e18);
        vm().prank(owner1);
        stake.stakeBoost(address(childToken), 1e18, 1, memberId3);

        vm().prank(owner1);
        stake.unstake(address(childToken), memberId3);
        phase.setPhase(3);

        (uint256 totalShares,, uint256 withdrawable,,,,) = stake.totalStake(address(childToken));
        uint256 lpAmount = shares * withdrawable / totalShares;
        require(lpAmount > 0, "expected a positive LP payout");
        require(lpAmount < pair.totalSupply(), "payout must stay below the pair supply");

        // Both reserves are now below `pairSupply / lpAmount`, so `pair.burn` would floor one side
        // to zero and revert. The withdrawal has to hand the LP over unburned instead of reverting.
        pair.setReserves(1, 1);

        uint256 tokenBefore = childToken.balanceOf(owner1);
        uint256 parentBefore = parentToken.balanceOf(owner1);
        uint256 lpStakeBefore = pair.balanceOf(address(stake));
        uint256 lpUserBefore = pair.balanceOf(owner1);
        vm().recordLogs();
        vm().prank(owner1);
        stake.withdraw(address(childToken), memberId3);

        require(childToken.balanceOf(owner1) == tokenBefore + 1e18, "boost must be returned");
        require(parentToken.balanceOf(owner1) == parentBefore, "no parent payout");
        require(pair.balanceOf(owner1) == lpUserBefore + lpAmount, "LP must be handed to the withdrawer");
        require(pair.balanceOf(address(stake)) == lpStakeBefore - lpAmount, "contract LP must match the ledger");

        // The same branch seen from the event: nothing burned, the whole converted LP handed over.
        Vm.Log[] memory logs = vm().getRecordedLogs();
        bytes32 topic = keccak256(
            "StakeWithdrawn(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
        );
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(stake) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != topic) continue;
            require(logs[i].topics[3] == bytes32(memberId3), "event member");
            (uint256 lpBurned, uint256 lpToMember) = _withdrawnLp(logs[i].data);
            require(lpBurned == 0, "the handover branch burns nothing");
            require(lpToMember == lpAmount, "the whole converted LP goes to the member");
            found = true;
        }
        require(found, "missing StakeWithdrawn");
        (uint256 sharedAfter, uint256 boostAfter, uint256 waitingAfter, uint256 requestedAfter,,) =
            stake.memberStake(address(childToken), memberId3);
        require(
            sharedAfter == 0 && boostAfter == 0 && waitingAfter == 0 && requestedAfter == 0, "position cleared"
        );
        (uint256 sharesLeft,,,,,) = stake.memberStake(address(childToken), memberId1);
        require(sharesLeft == 1000e18, "other position untouched");

        // The handed-over LP is a live claim: once the pair can be split again the withdrawer exits it directly.
        pair.setReserves(1000e18, 1000e18);
        vm().prank(owner1);
        pair.transfer(address(pair), lpAmount);
        vm().prank(owner1);
        (uint256 burned0, uint256 burned1) = pair.burn(owner1);
        require(burned0 > 0 && burned1 > 0, "LP must be redeemable after recovery");
        require(childToken.balanceOf(owner1) > tokenBefore + 1e18, "redeemed child tokens");
    }

    function testCanWithdrawMatchesWithdrawBehavior() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        // Before unstake
        require(!stake.canWithdraw(address(childToken), memberId1), "Should not be withdrawable before unstake");

        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);

        // At phase 1 (unstake phase)
        require(!stake.canWithdraw(address(childToken), memberId1), "Should not be withdrawable at unstake phase");

        // At phase 11 (exact boundary)
        phase.setPhase(11);
        require(!stake.canWithdraw(address(childToken), memberId1), "Should not be withdrawable at exact boundary");

        // At phase 12 (after boundary)
        phase.setPhase(12);
        require(stake.canWithdraw(address(childToken), memberId1), "Should be withdrawable after boundary");
    }

    function testCanWithdrawReturnsFalse() external {
        require(!stake.canWithdraw(address(childToken), memberId1), "Should not be withdrawable initially");

        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);
        require(!stake.canWithdraw(address(childToken), memberId1), "Should not be withdrawable before unstake");

        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);
        require(!stake.canWithdraw(address(childToken), memberId1), "Should not be withdrawable immediately");

        phase.setPhase(11);
        require(!stake.canWithdraw(address(childToken), memberId1), "Should not be withdrawable at phase 11");

        phase.setPhase(12);
        require(stake.canWithdraw(address(childToken), memberId1), "Should be withdrawable at phase 12");
    }

    // ============ Merge Tests ============

    function testMergeStakeBasic() external {
        // Stake in source
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        (uint256 sourceShares, , , , , ) = stake.memberStake(address(childToken), memberId1);
        require(sourceShares > 0, "Source should have shares");

        // Merge to empty target
        vm().prank(owner1);
        stake.mergeStake(address(childToken), memberId1, memberId3);

        (uint256 sourceSharesAfter, , , , , ) = stake.memberStake(address(childToken), memberId1);
        (uint256 targetShares, , uint256 targetPhases, , , ) = stake.memberStake(address(childToken), memberId3);

        require(sourceSharesAfter == 0, "Source should be cleared");
        require(targetShares == sourceShares, "Target should receive all shares");
        require(targetPhases == 10, "Target should inherit promised phases");
    }

    function testMergeStakeRejectsMissingTargetMember() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);
        (uint256 sourceSharesBefore, , , , , ) = stake.memberStake(address(childToken), memberId1);

        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(Stake.mergeStake.selector, address(childToken), memberId1, 999999),
            abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(999999)),
            "Should reject a missing target member"
        );

        (uint256 sourceSharesAfter, , , , , ) = stake.memberStake(address(childToken), memberId1);
        (uint256 missingTargetShares, , , , , ) = stake.memberStake(address(childToken), 999999);
        require(sourceSharesAfter == sourceSharesBefore, "Source stake must remain intact");
        require(missingTargetShares == 0, "Missing target must not receive stake");
    }

    function testMergeStakeRevertsIfSourceVoted() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        // Simulate vote
        vote.setVoteAmount(address(childToken), 1, memberId1, 100);

        vm().prank(owner1);
        vm().expectRevert(
            abi.encodeWithSelector(IStakeErrors.StakeRightsUsed.selector, address(childToken), 1, memberId1)
        );
        stake.mergeStake(address(childToken), memberId1, memberId3);
    }

    function testMergeStakeRevertsIfTargetPhasesTooShort() external {
        // Stake in source with 10 phases
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        // Stake in target with 5 phases
        stakeAsOwner(owner1, memberId3, 500e18, 500e18, 5);

        // Try to merge (should fail because target phases < source phases)
        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(Stake.mergeStake.selector, address(childToken), memberId1, memberId3),
            abi.encodeWithSelector(IStakeErrors.TargetPromisedWaitingPhasesTooShort.selector, 5, 10),
            "Should revert when target phases are shorter"
        );
    }

    function testMergeStakeSucceedsWhenTargetPhasesLonger() external {
        // Stake in source with 5 phases
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 5);

        (uint256 sourceShares, , , , , ) = stake.memberStake(address(childToken), memberId1);

        // Stake in target with 10 phases
        stakeAsOwner(owner1, memberId3, 500e18, 500e18, 10);

        (uint256 targetSharesBefore, , , , , ) = stake.memberStake(address(childToken), memberId3);

        // Merge should succeed
        vm().prank(owner1);
        stake.mergeStake(address(childToken), memberId1, memberId3);

        (uint256 sourceSharesAfter, , , , , ) = stake.memberStake(address(childToken), memberId1);
        (uint256 targetSharesAfter, , uint256 targetPhases, , , ) = stake.memberStake(address(childToken), memberId3);

        require(sourceSharesAfter == 0, "Source should be cleared");
        require(targetSharesAfter == targetSharesBefore + sourceShares, "Target should accumulate shares");
        require(targetPhases == 10, "Target should keep its phases");
    }


    // ============ Fee Settlement Tests ============

    function testSettleFeesReclassifiesLP() external {
        // Stake to create withdrawable LP
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        // Simulate trading fees by increasing reserves
        childToken.transfer(address(pair), 50e18);
        parentToken.transfer(address(pair), 50e18);
        pair.setReserves(101050e18, 101050e18);

        // Settle fees (reclassification happens)
        vm().prank(owner1);
        stake.settleFees(address(childToken));

        // Check that fees were classified
        (, uint256 totalLp, uint256 withdrawableLp, uint256 feeLp, , , ) =
            stake.totalStake(address(childToken));

        require(withdrawableLp > 0, "Withdrawable LP should exist");
        require(feeLp > 0, "Fee LP should be classified");
        require(totalLp == withdrawableLp + feeLp, "Total should equal sum");
    }

    function testSettleFeesMultipleTimes() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        // Simulate fees
        childToken.transfer(address(pair), 10e18);
        parentToken.transfer(address(pair), 10e18);
        pair.setReserves(101010e18, 101010e18);

        // First settlement
        vm().prank(owner1);
        stake.settleFees(address(childToken));

        // Second settlement in same phase should not revert
        vm().prank(owner1);
        stake.settleFees(address(childToken));

        // Move to next phase and settle again
        phase.setPhase(2);

        vm().prank(owner1);
        stake.settleFees(address(childToken));

        // Should complete without reverting
        require(true, "Should handle multiple settlements");
    }

    // ============ Share Calculation Tests ============

    function testSharesCalculationFirstDeposit() external {
        // First deposit should get shares equal to LP minted
        (uint256 govVotes, uint256 shares) = stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        require(shares > 0, "Should mint shares");
        require(govVotes == shares * 10, "Gov votes should be shares * phases");

        (, , uint256 withdrawableLp, , , , ) = stake.totalStake(address(childToken));
        require(withdrawableLp > 0, "Should have withdrawable LP");
    }

    function testSharesCalculationSecondDeposit() external {
        // First deposit
        (, uint256 shares1) = stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        // Second deposit by different user with same amount
        (, uint256 shares2) = stakeAsOwner(owner2, memberId2, 1000e18, 1000e18, 10);

        // Both deposits should get non-zero shares
        require(shares1 > 0, "First deposit should get shares");
        require(shares2 > 0, "Second deposit should get shares");

        // The exact ratio depends on LP mechanics, just verify both are reasonable
        // First deposit typically gets more due to being first liquidity provider
        require(shares2 < shares1 * 2, "Second deposit shares should be in reasonable range");
    }

    // ============ Slippage Tests ============

    function testSlippageProtectionWorks() external {
        // Stake to create initial reserves
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        // Try to stake with mismatched amounts and tight slippage
        vm().prank(owner2);
        childToken.approve(address(stake), 1000e18);
        vm().prank(owner2);
        parentToken.approve(address(stake), 900e18); // Less parent

        vm().prank(owner2);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(
                Stake.stakeLiquidity.selector, address(childToken), 1000e18, 900e18, 0.01e18, 10, memberId2
            ),
            abi.encodeWithSelector(IStakeErrors.SlippageExceeded.selector, 100e18, 10e18),
            "Should revert with slippage exceeded"
        );
    }

    function testSlippageAllowsReasonableDeviation() external {
        // Stake to create initial reserves
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        // Stake with slightly mismatched amounts but loose slippage
        vm().prank(owner2);
        childToken.approve(address(stake), 1000e18);
        vm().prank(owner2);
        parentToken.approve(address(stake), 950e18);

        vm().prank(owner2);
        (, uint256 shares) = stake.stakeLiquidity(
            address(childToken),
            1000e18,
            950e18,
            0.1e18, // 10% slippage
            10,
            memberId2
        );

        require(shares > 0, "Should succeed with reasonable slippage");
    }

    // ============ Edge Cases ============

    function testStakeRevertsWithNonMemberOwner() external {
        vm().prank(owner2); // owner2 trying to use owner1's member
        childToken.approve(address(stake), 1000e18);
        vm().prank(owner2);
        parentToken.approve(address(stake), 1000e18);

        vm().prank(owner2);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(
                Stake.stakeLiquidity.selector, address(childToken), 1000e18, 1000e18, 0.05e18, 10, memberId1
            ),
            abi.encodeWithSelector(IStakeErrors.NotMemberOwner.selector, memberId1),
            "Should revert when not member owner"
        );
    }


    function testBoostHistoryTracking() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        uint256 boostBefore = stake.validBoostShares(address(childToken), 1, memberId1);
        require(boostBefore == 0, "Should have no boost initially");

        // Add boost
        vm().prank(owner1);
        childToken.approve(address(stake), 500e18);
        vm().prank(owner1);
        stake.stakeBoost(address(childToken), 500e18, 10, memberId1);

        uint256 boostAfter = stake.validBoostShares(address(childToken), 1, memberId1);
        require(boostAfter == 500e18, "Should track boost shares");
        require(
            stake.totalValidBoostShares(address(childToken), 1) == boostAfter,
            "the only booster's valid shares are the community total"
        );

    }

    function testValidGovVotesLedgerSplitsIntoAddedAndRemoved() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);
        uint256 afterStake = _totalValidGovVotes(address(childToken));

        // Raising the waiting phases raises the same member's votes, so the community total grows.
        vm().prank(owner1);
        childToken.approve(address(stake), 500e18);
        vm().prank(owner1);
        stake.stakeBoost(address(childToken), 500e18, 12, memberId1);
        uint256 memberVoteAmount = _validGovVotes(address(childToken), memberId1);
        require(memberVoteAmount > afterStake, "the boost raises the member's votes");

        // A second member keeps the community total from dropping to zero on the unlock below.
        stakeAsOwner(owner2, memberId2, 400e18, 400e18, 10);
        uint256 peak = _totalValidGovVotes(address(childToken));
        require(peak > memberVoteAmount, "two members hold more than one");

        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);

        uint256 round = phase.currentPhase();
        require(stake.totalValidGovVotesAdded(address(childToken), round) == peak, "added equals the peak");
        require(
            stake.totalValidGovVotesRemoved(address(childToken), round) == memberVoteAmount,
            "removed equals what the unlocked member held"
        );
        require(
            _totalValidGovVotes(address(childToken)) == peak - memberVoteAmount,
            "total is added minus removed"
        );
        require(_validGovVotes(address(childToken), memberId1) == 0, "the unlocked member holds no votes");
        require(
            _validGovVotes(address(childToken), memberId2) == peak - memberVoteAmount,
            "the remaining member holds the rest"
        );
    }

    function testValidBoostSharesLedgerSplitsIntoAddedAndRemoved() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);
        vm().prank(owner1);
        childToken.approve(address(stake), 300e18);
        vm().prank(owner1);
        stake.stakeBoost(address(childToken), 300e18, 10, memberId1);

        stakeAsOwner(owner2, memberId2, 1000e18, 1000e18, 10);
        vm().prank(owner2);
        childToken.approve(address(stake), 200e18);
        vm().prank(owner2);
        stake.stakeBoost(address(childToken), 200e18, 10, memberId2);

        uint256 round = phase.currentPhase();
        require(stake.totalValidBoostSharesAdded(address(childToken), round) == 500e18, "added is the sum");
        require(stake.totalValidBoostSharesRemoved(address(childToken), round) == 0, "nothing removed yet");

        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);
        require(stake.totalValidBoostSharesRemoved(address(childToken), round) == 300e18, "removed is the unlock");
        require(stake.totalValidBoostShares(address(childToken), round) == 200e18, "total is added minus removed");
        require(stake.validBoostShares(address(childToken), round, memberId1) == 0, "the unlocked member is out");
        require(stake.validBoostShares(address(childToken), round, memberId2) == 200e18, "the other keeps its own");
    }

    function testValidGovVotesHistoryKeepsPastRounds() external {
        (, uint256 shares) = stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);
        uint256 roundOneVotes = shares * 10;

        phase.setPhase(2);
        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);

        require(
            stake.validGovVotes(address(childToken), 1, memberId1) == roundOneVotes,
            "round 1 keeps the weight the member had"
        );
        require(stake.validGovVotes(address(childToken), 2, memberId1) == 0, "round 2 records the unlock");
        require(stake.totalValidGovVotes(address(childToken), 1) == roundOneVotes, "round 1 total is frozen");
        require(stake.totalValidGovVotes(address(childToken), 2) == 0, "round 2 total follows the unlock");
        require(
            stake.totalValidGovVotesRemoved(address(childToken), 2) == roundOneVotes,
            "the removal is recorded in round 2"
        );
        require(
            stake.totalValidGovVotesAdded(address(childToken), 1)
                == stake.totalValidGovVotesAdded(address(childToken), 2),
            "round 2 adds nothing"
        );
        require(stake.totalValidGovVotesRemoved(address(childToken), 1) == 0, "round 1 removes nothing");
    }

    function testRoundGatedGettersRevertForFutureRound() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        vm().prank(owner1);
        childToken.approve(address(stake), 500e18);
        vm().prank(owner1);
        stake.stakeBoost(address(childToken), 500e18, 10, memberId1);

        // Every point-in-time read is gated the same way, so no getter can report the latest record as
        // if it belonged to a round that has not started.
        bytes4[2] memory memberScoped = [stake.validGovVotes.selector, stake.validBoostShares.selector];
        for (uint256 i; i < memberScoped.length; ++i) {
            _expectRevertData(
                address(stake),
                abi.encodeWithSelector(memberScoped[i], address(childToken), 999, memberId1),
                abi.encodeWithSelector(IStakeErrors.RoundNotStarted.selector, 999, 1),
                "the member ledger rejects a future round"
            );
        }

        bytes4[6] memory communityScoped = [
            stake.totalValidGovVotes.selector,
            stake.totalValidGovVotesAdded.selector,
            stake.totalValidGovVotesRemoved.selector,
            stake.totalValidBoostShares.selector,
            stake.totalValidBoostSharesAdded.selector,
            stake.totalValidBoostSharesRemoved.selector
        ];
        for (uint256 i; i < communityScoped.length; ++i) {
            _expectRevertData(
                address(stake),
                abi.encodeWithSelector(communityScoped[i], address(childToken), 999),
                abi.encodeWithSelector(IStakeErrors.RoundNotStarted.selector, 999, 1),
                "the community ledger rejects the same future round"
            );
        }
    }

    function testTotalStakeReturnsZeroForUnregisteredToken() external view {
        address fakeToken = address(0xdead);
        (uint256 totalShares, uint256 totalLp, uint256 withdrawableLp, uint256 feeLp, , , ) =
            stake.totalStake(fakeToken);

        require(totalShares == 0, "Should return zero total shares");
        require(totalLp == 0, "Should return zero total LP");
        require(withdrawableLp == 0, "Should return zero withdrawable LP");
        require(feeLp == 0, "Should return zero fee LP");
    }

    function testWithdrawClearsAllState() external {
        // Stake with boost
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        vm().prank(owner1);
        childToken.approve(address(stake), 500e18);
        vm().prank(owner1);
        stake.stakeBoost(address(childToken), 500e18, 10, memberId1);

        (uint256 sharesBefore, uint256 boostBefore, , , , ) =
            stake.memberStake(address(childToken), memberId1);
        require(sharesBefore > 0, "Should have shares");
        require(boostBefore > 0, "Should have boost");

        // Unstake and withdraw
        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);

        phase.setPhase(12);

        vm().prank(owner1);
        stake.withdraw(address(childToken), memberId1);

        (uint256 sharesAfter, uint256 boostAfter, uint256 phases, uint256 unlock, , ) =
            stake.memberStake(address(childToken), memberId1);

        require(sharesAfter == 0, "Shares should be cleared");
        require(boostAfter == 0, "Boost should be cleared");
        require(phases == 0, "Phases should be cleared");
        require(unlock == 0, "Unlock should be cleared");
    }

    // Test basic scenario
    function testFullStakingCycle() external {
        // Stake
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        // Verify stake
        (uint256 shares, , , , , ) = stake.memberStake(address(childToken), memberId1);
        require(shares > 0, "Should have shares");

        // Unstake
        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);

        // Advance phases
        phase.setPhase(12);

        // Withdraw
        vm().prank(owner1);
        stake.withdraw(address(childToken), memberId1);

        // Verify cleared
        (shares, , , , , ) = stake.memberStake(address(childToken), memberId1);
        require(shares == 0, "Shares should be cleared");
    }

    // ============ Pair Caching Tests ============

    function testPairReadAndCache() external {
        // First stake should read from factory and cache
        address pairBefore = stake.pairAddress(address(childToken));
        require(pairBefore == address(0), "Pair should not be cached yet");

        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        address pairAfter = stake.pairAddress(address(childToken));
        require(pairAfter == address(pair), "Pair should be cached");

        // Second stake should use cached pair (no factory access)
        stakeAsOwner(owner2, memberId2, 500e18, 500e18, 10);

        address pairStillCached = stake.pairAddress(address(childToken));
        require(pairStillCached == address(pair), "Pair should remain cached");
    }


    function testUnregisteredTokenRevertsAllEntries() external {
        // Create a token without pair
        LOVE20Token orphanToken = new LOVE20Token(
            "Orphan Token",
            "ORPHAN",
            1000000e18,
            2000000e18,
            address(this),
            address(this),
            address(parentToken)
        );

        orphanToken.transfer(owner1, 10000e18);

        // Try stakeLiquidity - should revert
        vm().prank(owner1);
        orphanToken.approve(address(stake), 1000e18);
        vm().prank(owner1);
        parentToken.approve(address(stake), 1000e18);

        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(
                Stake.stakeLiquidity.selector, address(orphanToken), 1000e18, 1000e18, 0.05e18, 10, memberId1
            ),
            abi.encodeWithSelector(IStakeErrors.TokenNotRegistered.selector, address(orphanToken)),
            "Should revert for unregistered token"
        );

        // Try settleFees - should revert
        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(Stake.settleFees.selector, address(orphanToken)),
            abi.encodeWithSelector(IStakeErrors.TokenNotRegistered.selector, address(orphanToken)),
            "settleFees should revert for unregistered token"
        );
    }

    function testMissingPairReverts() external {
        LOVE20Token noPairToken = new LOVE20Token(
            "No Pair Token",
            "NOPAIR",
            1000000e18,
            2000000e18,
            address(this),
            address(this),
            address(parentToken)
        );
        mockLaunch.register(address(noPairToken));
        noPairToken.transfer(owner1, 10000e18);

        vm().prank(owner1);
        noPairToken.approve(address(stake), 1000e18);
        vm().prank(owner1);
        parentToken.approve(address(stake), 1000e18);

        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(
                Stake.stakeLiquidity.selector, address(noPairToken), 1000e18, 1000e18, 0.05e18, 10, memberId1
            ),
            abi.encodeWithSelector(IStakeErrors.PairMissing.selector, address(noPairToken)),
            "Should revert when the community has no pair"
        );

        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(Stake.settleFees.selector, address(noPairToken)),
            abi.encodeWithSelector(IStakeErrors.PairMissing.selector, address(noPairToken)),
            "settleFees should revert when the community has no pair"
        );
    }

    function testStakeLiquidityRevertsWhenTransferReturnsFalse() external {
        FalseReturningToken falseToken = new FalseReturningToken(address(parentToken));
        mockLaunch.register(address(falseToken));
        MockPair falsePair = new MockPair(address(falseToken), address(parentToken));
        pairFactory.setPair(address(falseToken), address(parentToken), address(falsePair));

        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(
                Stake.stakeLiquidity.selector, address(falseToken), 1000e18, 1000e18, 0.05e18, 10, memberId1
            ),
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(falseToken)),
            "Should revert when the token transfer returns false"
        );
    }

    function testStakeLiquidityRevertsWhenAlreadyUnlocking() external {
        // Stake first
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        // Request unstake
        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);

        // Try to stake again while unlocking - should revert
        vm().prank(owner1);
        childToken.approve(address(stake), 1000e18);
        vm().prank(owner1);
        parentToken.approve(address(stake), 1000e18);

        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(
                Stake.stakeLiquidity.selector, address(childToken), 1000e18, 1000e18, 0.05e18, 10, memberId1
            ),
            abi.encodeWithSelector(IStakeErrors.UnstakeAlreadyRequested.selector, address(childToken), memberId1),
            "Should revert when already unlocking"
        );
    }

    function testStakeBoostRevertsWhenAlreadyUnlocking() external {
        // Stake first
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        // Request unstake
        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);

        // Try to boost while unlocking - should revert
        vm().prank(owner1);
        childToken.approve(address(stake), 500e18);

        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(Stake.stakeBoost.selector, address(childToken), 500e18, 10, memberId1),
            abi.encodeWithSelector(IStakeErrors.UnstakeAlreadyRequested.selector, address(childToken), memberId1),
            "Should revert when already unlocking"
        );
    }

    function testStakeBoostRevertsWithDecreasingPhases() external {
        // Stake with 10 phases
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        // Try to boost with 5 phases - should revert
        vm().prank(owner1);
        childToken.approve(address(stake), 500e18);

        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(Stake.stakeBoost.selector, address(childToken), 500e18, 5, memberId1),
            abi.encodeWithSelector(IStakeErrors.PromisedWaitingPhasesDecreased.selector, 5, 10),
            "Should revert when decreasing promised phases"
        );
    }

    function testWithdrawRevertsAfterPositionCleared() external {
        // Stake and unstake
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);

        // Advance time
        phase.setPhase(12);

        // Withdraw
        vm().prank(owner1);
        stake.withdraw(address(childToken), memberId1);

        // Verify shares are cleared
        (uint256 shares, , , , , ) = stake.memberStake(address(childToken), memberId1);
        require(shares == 0, "Shares should be zero");

        // Try to withdraw again; the position was cleared, so no unlock request remains.
        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(Stake.withdraw.selector, address(childToken), memberId1),
            abi.encodeWithSelector(IStakeErrors.UnstakeNotRequested.selector, address(childToken), memberId1),
            "Should revert with no unlock request"
        );
    }

    function testMergeStakeRevertsWithEmptySource() external {
        // Only stake in target, not source
        stakeAsOwner(owner1, memberId3, 1000e18, 1000e18, 10);

        // Try to merge from empty source - should revert
        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(Stake.mergeStake.selector, address(childToken), memberId1, memberId3),
            abi.encodeWithSelector(IStakeErrors.NoStakedLiquidity.selector, address(childToken), memberId1),
            "Should revert with empty source"
        );
    }

    function testMergeStakeRevertsWithWrongOwner() external {
        // Stake with owner1's memberId1
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        // Try to merge using owner2 (who doesn't own memberId1) - should revert
        vm().prank(owner2);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(Stake.mergeStake.selector, address(childToken), memberId1, memberId2),
            abi.encodeWithSelector(IStakeErrors.NotMemberOwner.selector, memberId1),
            "Should revert when not member owner"
        );
    }

    function testStakeBoostRevertsWithZeroAmount() external {
        // Stake first
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        // Try to boost with zero amount - should revert
        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(Stake.stakeBoost.selector, address(childToken), 0, 10, memberId1),
            abi.encodeWithSelector(IStakeErrors.ZeroBoostAmount.selector),
            "Should revert with zero boost amount"
        );
    }

    function testSettleFeesRespectsPhaseGuard() external {
        // Stake large amount to ensure settlementUnit is meaningful
        stakeAsOwner(owner1, memberId1, 10000e18, 10000e18, 10);

        // Simulate significant fees and fund stake contract for burn
        childToken.transfer(address(stake), 10000e18);
        parentToken.transfer(address(stake), 10000e18);
        childToken.transfer(address(pair), 5000e18);
        parentToken.transfer(address(pair), 5000e18);
        pair.setReserves(115000e18, 115000e18);

        // First settlement in phase 1
        vm().prank(owner1);
        stake.settleFees(address(childToken));

        uint256 burnedAfterFirst = stake.totalBurnedToken(address(childToken));
        require(burnedAfterFirst > 0, "Should burn in first settlement");

        // Add more fees in same phase
        childToken.transfer(address(stake), 10000e18);
        parentToken.transfer(address(stake), 10000e18);
        childToken.transfer(address(pair), 5000e18);
        parentToken.transfer(address(pair), 5000e18);
        pair.setReserves(120000e18, 120000e18);

        // Second settlement in same phase - should execute but phase guard prevents _realizeFees
        vm().prank(owner1);
        stake.settleFees(address(childToken));

        uint256 burnedAfterSecond = stake.totalBurnedToken(address(childToken));

        // No additional burn should happen due to phase guard
        require(burnedAfterSecond == burnedAfterFirst, "Should not burn again in same phase");
    }

    // ============ Boost History Round Boundary Tests ============

    function testBoostHistoryCompletedRound() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        // Add boost at round 1
        vm().prank(owner1);
        childToken.approve(address(stake), 500e18);
        vm().prank(owner1);
        stake.stakeBoost(address(childToken), 500e18, 10, memberId1);

        uint256 boostAtRound1 = stake.validBoostShares(address(childToken), 1, memberId1);
        require(boostAtRound1 == 500e18, "Should have boost at round 1");

        // Move to round 5
        phase.setPhase(5);

        // Query completed round 1
        uint256 boostStillAtRound1 = stake.validBoostShares(address(childToken), 1, memberId1);
        require(boostStillAtRound1 == 500e18, "Should still have boost at round 1");
    }

    function testBoostHistoryNoRecordRound() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        // Add boost at round 1
        vm().prank(owner1);
        childToken.approve(address(stake), 500e18);
        vm().prank(owner1);
        stake.stakeBoost(address(childToken), 500e18, 10, memberId1);

        // Move to round 5
        phase.setPhase(5);

        // Query round 3 (no record, should return latest not later than round 3)
        uint256 boostAtRound3 = stake.validBoostShares(address(childToken), 3, memberId1);
        require(boostAtRound3 == 500e18, "Should return latest boost not later than round 3");
    }

    function testBoostHistoryExplicitZeroRound() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        // Add boost at round 1
        vm().prank(owner1);
        childToken.approve(address(stake), 500e18);
        vm().prank(owner1);
        stake.stakeBoost(address(childToken), 500e18, 10, memberId1);

        // Unstake at round 1 (decreases boost history to 0)
        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);

        // Query should return 0
        uint256 boostAfterUnstake = stake.validBoostShares(address(childToken), 1, memberId1);
        require(boostAfterUnstake == 0, "Should return 0 after unstake");
    }

    // ============ Fee Settlement Guard Tests ============

    function testSettleFeesThresholdUnit() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        // Simulate fees by increasing reserves
        uint256 feeAmount = 100e18;
        childToken.transfer(address(pair), feeAmount);
        parentToken.transfer(address(pair), feeAmount);
        pair.setReserves(101100e18, 101100e18);

        vm().prank(owner1);
        stake.settleFees(address(childToken));

        // Check that some fees were processed
        (, , , uint256 feeLpAfter, , , ) = stake.totalStake(address(childToken));
        require(feeLpAfter > 0, "Should have remaining fee LP");
    }

    function testSettleFeesLimitedToOncePerPhase() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        // Simulate fees
        childToken.transfer(address(pair), 100e18);
        parentToken.transfer(address(pair), 100e18);
        pair.setReserves(101100e18, 101100e18);

        // First settlement in phase 1
        vm().prank(owner1);
        stake.settleFees(address(childToken));

        (, , , uint256 feeLpAfterFirst, , , ) = stake.totalStake(address(childToken));

        // Second settlement in same phase (should have no effect on feeLp)
        vm().prank(owner1);
        stake.settleFees(address(childToken));

        (, , , uint256 feeLpAfterSecond, , , ) = stake.totalStake(address(childToken));
        require(feeLpAfterSecond == feeLpAfterFirst, "Second settlement should not change feeLp in same phase");
    }


    function testSettleFeesSkipsWhenBelowThreshold() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        // Simulate tiny fees (below threshold)
        childToken.transfer(address(pair), 1e18);
        parentToken.transfer(address(pair), 1e18);
        pair.setReserves(101001e18, 101001e18);

        vm().prank(owner1);
        stake.settleFees(address(childToken));

        // Fees should be reclassified but not realized
        (, , , uint256 feeLp, , , ) = stake.totalStake(address(childToken));
        require(feeLp > 0, "Should have fee LP");

        uint256 totalBurnedBefore = stake.totalBurnedToken(address(childToken));

        // Advance phase and settle again
        phase.setPhase(2);
        vm().prank(owner1);
        stake.settleFees(address(childToken));

        uint256 totalBurnedAfter = stake.totalBurnedToken(address(childToken));
        require(totalBurnedAfter == totalBurnedBefore, "Should not burn when below threshold");
    }

    function testSettleFeesNewPhaseAllowsNewSettlement() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        // Simulate fees
        childToken.transfer(address(pair), 10000e18);
        parentToken.transfer(address(pair), 10000e18);
        // Provide tokens for swap
        childToken.transfer(address(stake), 10000e18);
        pair.setReserves(111000e18, 111000e18);

        // First settlement in phase 1
        vm().prank(owner1);
        stake.settleFees(address(childToken));

        uint256 totalBurnedPhase1 = stake.totalBurnedToken(address(childToken));

        // Add more fees and move to phase 2
        childToken.transfer(address(pair), 10000e18);
        parentToken.transfer(address(pair), 10000e18);
        // Provide more tokens for second swap
        childToken.transfer(address(stake), 10000e18);
        pair.setReserves(122000e18, 122000e18);
        phase.setPhase(2);

        // Second settlement should work in new phase
        vm().prank(owner1);
        stake.settleFees(address(childToken));

        uint256 totalBurnedPhase2 = stake.totalBurnedToken(address(childToken));
        require(totalBurnedPhase2 > totalBurnedPhase1, "Should burn more in new phase");
    }

    // ============ Boost History Attribution Tests ============

    function testBoostUnlockAttributionRemainsOnMember() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        vm().prank(owner1);
        childToken.approve(address(stake), 500e18);
        vm().prank(owner1);
        stake.stakeBoost(address(childToken), 500e18, 10, memberId1);

        uint256 boostBefore = stake.validBoostShares(address(childToken), 1, memberId1);
        require(boostBefore == 500e18, "Should have 500 boost");

        // Unstake decreases boost history
        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);

        uint256 boostAfterUnstake = stake.validBoostShares(address(childToken), 1, memberId1);
        require(boostAfterUnstake == 0, "Boost should be removed from history");
    }

    function testMergeMovesBoostHistory() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        vm().prank(owner1);
        childToken.approve(address(stake), 500e18);
        vm().prank(owner1);
        stake.stakeBoost(address(childToken), 500e18, 10, memberId1);

        uint256 sourceBoostBefore = stake.validBoostShares(address(childToken), 1, memberId1);
        uint256 targetBoostBefore = stake.validBoostShares(address(childToken), 1, memberId3);
        require(sourceBoostBefore == 500e18, "Source should have boost");
        require(targetBoostBefore == 0, "Target should have no boost");

        // Merge
        vm().prank(owner1);
        stake.mergeStake(address(childToken), memberId1, memberId3);

        uint256 sourceBoostAfter = stake.validBoostShares(address(childToken), 1, memberId1);
        uint256 targetBoostAfter = stake.validBoostShares(address(childToken), 1, memberId3);

        require(sourceBoostAfter == 0, "Source boost should be moved");
        require(targetBoostAfter == 500e18, "Target should receive boost");
    }

    // ============ Reserve Boundary Tests ============

    function testReservesZeroBeforeFirstStake() external view {
        (uint256 totalShares, uint256 totalLp, , , , , ) = stake.totalStake(address(childToken));
        require(totalShares == 0, "Should have no shares initially");
        require(totalLp == 0, "Should have no LP initially");
    }

    function testPairReservesUpdateAfterStake() external {
        (uint112 reserve0Before, uint112 reserve1Before, ) = pair.getReserves();

        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        (uint112 reserve0After, uint112 reserve1After, ) = pair.getReserves();
        require(reserve0After > reserve0Before, "Reserve0 should increase");
        require(reserve1After > reserve1Before, "Reserve1 should increase");
    }


    // ============ NFT Ownership Tests ============

    function testStakeRevertsWithZeroMemberId() external {
        vm().prank(owner1);
        childToken.approve(address(stake), 1000e18);
        vm().prank(owner1);
        parentToken.approve(address(stake), 1000e18);

        vm().prank(owner1);
        vm().expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(0))
        );
        stake.stakeLiquidity(address(childToken), 1000e18, 1000e18, 0.05e18, 10, 0);
    }

    function testStakeChecksOwnerBeforeAmount() external {
        vm().prank(address(0xBEEF));
        vm().expectRevert(abi.encodeWithSelector(IStakeErrors.NotMemberOwner.selector, memberId1));
        stake.stakeLiquidity(address(childToken), 0, 0, 0.05e18, 10, memberId1);
    }

    function testStakeBoostChecksOwnerBeforeAmount() external {
        vm().prank(owner2);
        vm().expectRevert(abi.encodeWithSelector(IStakeErrors.NotMemberOwner.selector, memberId1));
        stake.stakeBoost(address(childToken), 0, 10, memberId1);
    }

    function testUnstakeChecksOwnerBeforeToken() external {
        vm().prank(owner2);
        vm().expectRevert(abi.encodeWithSelector(IStakeErrors.NotMemberOwner.selector, memberId1));
        stake.unstake(address(0xDEAD), memberId1);
    }

    function testWithdrawChecksOwnerBeforeToken() external {
        vm().prank(owner2);
        vm().expectRevert(abi.encodeWithSelector(IStakeErrors.NotMemberOwner.selector, memberId1));
        stake.withdraw(address(0xDEAD), memberId1);
    }

    function testMergeRevertsWhenSourceEqualsTarget() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        vm().prank(owner1);
        vm().expectRevert(
            abi.encodeWithSelector(
                IStakeErrors.SourceAndTargetMemberIdsMustBeDifferent.selector, memberId1, memberId1
            )
        );
        stake.mergeStake(address(childToken), memberId1, memberId1);
    }

    function testMergeRevertsWithZeroTargetMemberId() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        vm().prank(owner1);
        vm().expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(0))
        );
        stake.mergeStake(address(childToken), memberId1, 0);
    }

    function testMergeRevertsWithZeroSourceMemberId() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        vm().prank(owner1);
        vm().expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, uint256(0))
        );
        stake.mergeStake(address(childToken), 0, memberId1);
    }


    // ============ Extreme Value Boundary Tests ============

    function testStakeLiquidityWithMinimumPromisedPhases() external {
        (uint256 govVotes, uint256 shares) = stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 1);
        require(shares > 0, "Should mint shares");
        require(govVotes == shares * 1, "Gov votes should be shares * 1");
    }

    function testStakeLiquidityWithMaximumPromisedPhases() external {
        (uint256 govVotes, uint256 shares) = stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 100);
        require(shares > 0, "Should mint shares");
        require(govVotes == shares * 100, "Gov votes should be shares * 100");
    }

    function testMultipleStakesAccumulate() external {
        stakeAsOwner(owner1, memberId1, 100e18, 100e18, 10);
        (uint256 shares1, , , , , ) = stake.memberStake(address(childToken), memberId1);

        stakeAsOwner(owner1, memberId1, 100e18, 100e18, 10);
        (uint256 shares2, , , , , ) = stake.memberStake(address(childToken), memberId1);

        require(shares2 > shares1, "Shares should accumulate");
    }

    function testGlobalGovVotesTracking() external {
        uint256 govVotesBefore = _totalValidGovVotes(address(childToken));
        require(govVotesBefore == 0, "Should start at zero");

        (uint256 govVotesAdded, ) = stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        uint256 govVotesAfter = _totalValidGovVotes(address(childToken));
        require(govVotesAfter == govVotesAdded, "Global votes should match added");
    }

    function testGlobalGovVotesDecreasesOnUnstake() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);
        uint256 govVotesBefore = _totalValidGovVotes(address(childToken));

        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);

        uint256 govVotesAfter = _totalValidGovVotes(address(childToken));
        require(govVotesAfter == 0, "Global votes should be zero after unstake");
        require(govVotesBefore > 0, "Should have had votes before");
    }

    // ============ Precise Withdraw Validation Tests ============

    function testWithdrawReturnsCorrectTokenAmounts() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        uint256 childBalanceBefore = childToken.balanceOf(owner1);
        uint256 parentBalanceBefore = parentToken.balanceOf(owner1);

        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);
        phase.setPhase(12);

        vm().prank(owner1);
        stake.withdraw(address(childToken), memberId1);

        uint256 childBalanceAfter = childToken.balanceOf(owner1);
        uint256 parentBalanceAfter = parentToken.balanceOf(owner1);

        require(childBalanceAfter > childBalanceBefore, "Should receive child tokens");
        require(parentBalanceAfter > parentBalanceBefore, "Should receive parent tokens");
    }

    function testMemberStakeShowsCorrectAmountsBeforeWithdraw() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        (
            uint256 liquidityShares,
            uint256 boostShares,
            uint256 promisedPhases,
            uint256 unlockPhase,
            uint256 tokenAmount,
            uint256 parentTokenAmount
        ) = stake.memberStake(address(childToken), memberId1);

        require(liquidityShares > 0, "Should have liquidity shares");
        require(boostShares == 0, "Should have no boost shares");
        require(promisedPhases == 10, "Should have 10 promised phases");
        require(unlockPhase == 0, "Should not be unlocking");
        require(tokenAmount > 0, "Should show token amount");
        require(parentTokenAmount > 0, "Should show parent token amount");
    }

    // ============ Complete Fee Cycle Tests ============

    function testFeeCycleFromStakeToSettlement() external {
        // Initial stake
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        uint256 totalBurnedBefore = stake.totalBurnedToken(address(childToken));
        uint256 parentBurnedBefore = stake.totalParentTokenBurned(address(childToken));

        // Simulate trading fees (much larger to exceed threshold)
        // Need to provide enough tokens to MockRouter for the swap
        childToken.transfer(address(pair), 10000e18);
        parentToken.transfer(address(pair), 10000e18);
        // Also give stake contract enough tokens for burn after swap
        childToken.transfer(address(stake), 10000e18);
        pair.setReserves(111000e18, 111000e18);

        // Settle fees
        vm().prank(owner1);
        stake.settleFees(address(childToken));

        uint256 totalBurnedAfter = stake.totalBurnedToken(address(childToken));
        uint256 parentBurnedAfter = stake.totalParentTokenBurned(address(childToken));

        require(totalBurnedAfter > totalBurnedBefore, "Should burn tokens");
        require(parentBurnedAfter > parentBurnedBefore, "Should burn parent tokens");
    }

    function testFeeClassificationMaintainsTotalLp() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        stake.totalStake(address(childToken));

        // Simulate fees
        childToken.transfer(address(pair), 50e18);
        parentToken.transfer(address(pair), 50e18);
        pair.setReserves(101050e18, 101050e18);

        // Settle (reclassifies but may not burn if below threshold)
        vm().prank(owner1);
        stake.settleFees(address(childToken));

        (, uint256 totalLpAfter, uint256 withdrawableLp, uint256 feeLp, , , ) =
            stake.totalStake(address(childToken));

        require(totalLpAfter == withdrawableLp + feeLp, "Total should equal sum of parts");
    }


    // ============ Additional Error Path Tests ============

    function testUnstakeRevertsWithoutLiquidity() external {
        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(Stake.unstake.selector, address(childToken), memberId1),
            abi.encodeWithSelector(IStakeErrors.NoStakedLiquidity.selector, address(childToken), memberId1),
            "Should revert when no liquidity staked"
        );
    }

    function testWithdrawRevertsWithoutUnstake() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(Stake.withdraw.selector, address(childToken), memberId1),
            abi.encodeWithSelector(IStakeErrors.UnstakeNotRequested.selector, address(childToken), memberId1),
            "Should revert when unstake not requested"
        );
    }

    function testMergeRevertsWhenTargetUnlocking() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);
        stakeAsOwner(owner1, memberId3, 500e18, 500e18, 10);

        // Target starts unstaking
        vm().prank(owner1);
        stake.unstake(address(childToken), memberId3);

        // Try to merge into unlocking target
        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(Stake.mergeStake.selector, address(childToken), memberId1, memberId3),
            abi.encodeWithSelector(IStakeErrors.UnstakeAlreadyRequested.selector, address(childToken), memberId3),
            "Should revert when target is unlocking"
        );
    }

    function testMergeRevertsWhenSourceUnlocking() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        // Source starts unstaking
        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);

        // Try to merge from unlocking source
        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(Stake.mergeStake.selector, address(childToken), memberId1, memberId3),
            abi.encodeWithSelector(IStakeErrors.UnstakeAlreadyRequested.selector, address(childToken), memberId1),
            "Should revert when source is unlocking"
        );
    }

    // ============ Advanced Coverage Tests ============

    function testStakeLiquidityEmitsCorrectEvent() external {
        // A second member keeps `liquidityShares` and `totalLiquidityShares` apart.
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);
        vm().recordLogs();
        (uint256 govVotes, uint256 shares) = stakeAsOwner(owner2, memberId2, 1000e18, 1000e18, 10);
        require(govVotes > 0, "Should add gov votes");
        require(shares > 0, "Should add shares");

        (uint256 totalLiquidityShares, , , , , , ) = stake.totalStake(address(childToken));
        uint256 totalValidGovVotes = _totalValidGovVotes(address(childToken));
        Vm.Log[] memory logs = vm().getRecordedLogs();
        bytes32 topic = keccak256(
            "LiquidityStaked(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
        );
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(stake) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != topic) continue;
            require(logs[i].topics.length == 4, "three indexed arguments");
            require(logs[i].topics[1] == bytes32(uint256(uint160(address(childToken)))), "event token");
            require(logs[i].topics[2] == bytes32(uint256(1)), "event round");
            require(logs[i].topics[3] == bytes32(memberId2), "event member");
            (
                ,
                ,
                ,
                ,
                uint256 promisedWaitingPhases,
                ,
                ,
                ,
                uint256 liquidityShares,
                uint256 totalLiquidityShares_,
                uint256 totalValidGovVotes_
            ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256));
            require(promisedWaitingPhases == 10, "event promised phases");
            require(liquidityShares == shares, "event member shares");
            require(totalLiquidityShares_ == totalLiquidityShares, "event global shares");
            require(totalValidGovVotes_ == totalValidGovVotes, "event global votes");
            found = true;
        }
        require(found, "missing LiquidityStaked");
    }

    function testSettleFeesEmitsCorrectEvent() external {
        stakeAsOwner(owner1, memberId1, 10000e18, 10000e18, 10);
        childToken.transfer(address(stake), 10000e18);
        parentToken.transfer(address(stake), 10000e18);
        childToken.transfer(address(pair), 5000e18);
        parentToken.transfer(address(pair), 5000e18);
        pair.setReserves(115000e18, 115000e18);

        vm().recordLogs();
        vm().prank(owner1);
        stake.settleFees(address(childToken));

        Vm.Log[] memory logs = vm().getRecordedLogs();
        bytes32 topic = keccak256("FeesSettled(address,uint256,uint256,uint256,uint256,uint256,uint256)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(stake) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != topic) continue;
            require(logs[i].topics.length == 3, "two indexed arguments");
            require(logs[i].topics[1] == bytes32(uint256(uint160(address(childToken)))), "event token");
            require(uint256(logs[i].topics[2]) == 1, "event round");
            (uint256 feeLp, uint256 tokenBurned, , uint256 burnedTotal, uint256 parentBurnedTotal) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
            require(feeLp > 0 || tokenBurned > 0, "event fee or burn");
            require(burnedTotal == stake.totalBurnedToken(address(childToken)), "event burned total");
            require(
                parentBurnedTotal == stake.totalParentTokenBurned(address(childToken)),
                "event parent burned total"
            );
            found = true;
        }
        require(found, "missing FeesSettled");
    }

    function testStakeBoostEmitsCorrectEvent() external {
        stakeAsOwner(owner2, memberId2, 1000e18, 1000e18, 10);
        vm().prank(owner2);
        childToken.approve(address(stake), 1000e18);

        // A warm-up stake gives the measured call a non-zero history and a non-zero vote delta.
        vm().prank(owner2);
        stake.stakeBoost(address(childToken), 250e18, 10, memberId2);

        // A member that unlocks before the measured call keeps `totalBoostShares` and
        // `totalValidBoostShares` apart: the balance still counts it, the round history does not.
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);
        vm().prank(owner1);
        childToken.approve(address(stake), 1000e18);
        vm().prank(owner1);
        stake.stakeBoost(address(childToken), 1000e18, 10, memberId1);
        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);

        // A still-active booster keeps the global cumulated total off the measured member's balance.
        stakeAsOwner(owner1, memberId3, 1000e18, 1000e18, 10);
        vm().prank(owner1);
        childToken.approve(address(stake), 400e18);
        vm().prank(owner1);
        stake.stakeBoost(address(childToken), 400e18, 10, memberId3);

        vm().recordLogs();
        vm().prank(owner2);
        stake.stakeBoost(address(childToken), 500e18, 12, memberId2);

        Vm.Log[] memory logs = vm().getRecordedLogs();
        bytes32 topic = keccak256(
            "BoostStaked(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
        );
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(stake) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != topic) continue;
            require(logs[i].topics.length == 4, "three indexed arguments");
            require(logs[i].topics[2] == bytes32(uint256(1)), "event round");
            require(logs[i].topics[3] == bytes32(memberId2), "event member");
            (
                uint256 boostAmount,
                uint256 promisedWaitingPhases,
                uint256 govVotesAdded,
                uint256 govVotes,
                uint256 boostShares,
                uint256 totalBoostShares,
                uint256 totalValidBoostShares,
                uint256 totalValidGovVotes
            ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256));
            require(boostAmount == 500e18, "event boost amount");
            require(promisedWaitingPhases == 12, "event promised waiting phases");
            require(govVotesAdded > 0 && govVotes > govVotesAdded, "event vote delta and total");
            require(boostShares == 750e18, "event member boost");
            require(totalBoostShares == 2150e18, "event global boost");
            (, , , , uint256 balanceBoostTotal, , ) = stake.totalStake(address(childToken));
            require(totalBoostShares == balanceBoostTotal, "the event balance total matches totalStake");
            require(totalValidBoostShares == 1150e18, "event global valid boost");
            require(
                totalValidBoostShares == stake.totalValidBoostShares(address(childToken), 1),
                "event total matches the community ledger"
            );
            require(totalValidGovVotes == _totalValidGovVotes(address(childToken)), "event global votes");
            found = true;
        }
        require(found, "missing BoostStaked");
    }

    function testUnstakeEmitsCorrectEvent() external {
        // A member that unlocked earlier keeps the balance total above the round history, and a member
        // that did not keeps the global cumulated boost non-zero: the four readings stay distinct.
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);
        vm().prank(owner1);
        childToken.approve(address(stake), 300e18);
        vm().prank(owner1);
        stake.stakeBoost(address(childToken), 300e18, 10, memberId1);
        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);

        stakeAsOwner(owner1, memberId3, 1000e18, 1000e18, 10);
        vm().prank(owner1);
        childToken.approve(address(stake), 100e18);
        vm().prank(owner1);
        stake.stakeBoost(address(childToken), 100e18, 10, memberId3);

        stakeAsOwner(owner2, memberId2, 1000e18, 1000e18, 10);

        vm().recordLogs();
        vm().prank(owner2);
        stake.unstake(address(childToken), memberId2);

        (uint256 shares, , , uint256 unlock, , ) = stake.memberStake(address(childToken), memberId2);
        require(shares > 0, "Shares should still exist");
        require(unlock == 1, "Unlock should be marked");

        (, , , , uint256 balanceBoost, , ) = stake.totalStake(address(childToken));
        require(balanceBoost == 400e18, "the unlocked boost still counts in the balance total");

        Vm.Log[] memory logs = vm().getRecordedLogs();
        bytes32 topic = keccak256("Unstaked(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(stake) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != topic) continue;
            require(logs[i].topics.length == 4, "three indexed arguments");
            require(logs[i].topics[2] == bytes32(uint256(1)), "event round");
            require(logs[i].topics[3] == bytes32(memberId2), "event member");
            (
                uint256 promisedWaitingPhases,
                uint256 removedVotes,
                uint256 liquidityShares,
                uint256 boostShares,
                uint256 totalValidBoostShares,
                uint256 totalValidGovVotes
            ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
            require(promisedWaitingPhases == 10, "event promised phases");
            require(liquidityShares == shares, "event member shares");
            require(removedVotes == liquidityShares * 10, "event removed votes");
            require(boostShares == 0, "event member boost");
            require(totalValidBoostShares == 100e18, "event global valid boost");
            require(
                totalValidBoostShares == stake.totalValidBoostShares(address(childToken), 1),
                "event total matches the community ledger"
            );
            require(totalValidGovVotes == _totalValidGovVotes(address(childToken)), "event global votes");
            require(totalValidGovVotes != totalValidBoostShares, "vote and boost totals stay apart");
            found = true;
        }
        require(found, "missing Unstaked");
    }

    function testWithdrawEmitsCorrectEvent() external {
        stakeAsOwner(owner2, memberId2, 1000e18, 1000e18, 10);
        (uint256 sharesBefore, , , , , ) = stake.memberStake(address(childToken), memberId2);
        vm().prank(owner2);
        childToken.approve(address(stake), 500e18);
        vm().prank(owner2);
        stake.stakeBoost(address(childToken), 500e18, 10, memberId2);

        vm().prank(owner2);
        stake.unstake(address(childToken), memberId2);

        phase.setPhase(12);

        (uint256 totalSharesBefore, , uint256 withdrawableBefore, , , , ) =
            stake.totalStake(address(childToken));
        uint256 expectedLp = (sharesBefore * withdrawableBefore) / totalSharesBefore;
        require(expectedLp > 0, "the fixture must burn a non-zero LP");

        vm().recordLogs();
        vm().prank(owner2);
        stake.withdraw(address(childToken), memberId2);

        (uint256 shares, , , , , ) = stake.memberStake(address(childToken), memberId2);
        require(shares == 0, "Shares should be cleared");

        Vm.Log[] memory logs = vm().getRecordedLogs();
        bytes32 topic = keccak256(
            "StakeWithdrawn(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
        );
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(stake) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != topic) continue;
            require(logs[i].topics.length == 4, "three indexed arguments");
            require(logs[i].topics[2] == bytes32(uint256(12)), "event round");
            require(logs[i].topics[3] == bytes32(memberId2), "event member");
            (
                uint256 promisedWaitingPhases,
                uint256 liquidityShares,
                ,
                ,
                uint256 boostShares,
                uint256 lpBurned,
                uint256 lpToMember,
                uint256 totalLiquidityShares,
                uint256 totalBoostShares
            ) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256));
            require(promisedWaitingPhases == 10, "event promised phases");
            require(liquidityShares == sharesBefore, "event liquidity shares");
            require(boostShares == 500e18, "event boost shares");
            require(lpBurned == expectedLp, "lp burned equals the converted share");
            require(lpToMember == 0, "the burn branch hands nothing to the member");
            require(totalLiquidityShares == 0, "event global liquidity shares");
            require(totalBoostShares == 0, "event global boost shares");
            found = true;
        }
        require(found, "missing StakeWithdrawn");
    }

    function testFeesSettledPrecedesStakeWithdrawn() external {
        stakeAsOwner(owner1, memberId1, 10000e18, 10000e18, 10);
        childToken.transfer(address(stake), 10000e18);
        parentToken.transfer(address(stake), 10000e18);
        childToken.transfer(address(pair), 5000e18);
        parentToken.transfer(address(pair), 5000e18);
        pair.setReserves(115000e18, 115000e18);

        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);
        phase.setPhase(12);

        vm().recordLogs();
        vm().prank(owner1);
        stake.withdraw(address(childToken), memberId1);

        Vm.Log[] memory logs = vm().getRecordedLogs();
        bytes32 feesTopic = keccak256("FeesSettled(address,uint256,uint256,uint256,uint256,uint256,uint256)");
        bytes32 withdrawnTopic = keccak256(
            "StakeWithdrawn(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
        );
        uint256 feesIndex = type(uint256).max;
        uint256 withdrawnIndex = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(stake) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == feesTopic && feesIndex == type(uint256).max) feesIndex = i;
            if (logs[i].topics[0] == withdrawnTopic && withdrawnIndex == type(uint256).max) withdrawnIndex = i;
        }
        require(feesIndex != type(uint256).max, "missing FeesSettled");
        require(withdrawnIndex != type(uint256).max, "missing StakeWithdrawn");
        require(feesIndex < withdrawnIndex, "fees must settle before withdraw");
    }

    struct StakesMergedPayload {
        uint256 round;
        uint256 liquiditySharesMerged;
        uint256 boostSharesMerged;
        uint256 targetGovVotes;
        uint256 targetLiquidityShares;
        uint256 targetBoostShares;
        uint256 targetPromisedWaitingPhases;
        uint256 prevSourceGovVotes;
        uint256 prevSourcePromisedWaitingPhases;
        uint256 totalValidGovVotes;
    }

    function testMergeStakeEmitsTargetPostState() external {
        (, uint256 shares) = stakeAsOwner(owner2, memberId2, 1000e18, 1000e18, 10);
        // A non-empty target keeps `liquiditySharesMerged` and `targetLiquidityShares` apart.
        (, uint256 targetSharesBefore) = stakeAsOwner(owner1, memberId3, 500e18, 500e18, 10);
        vm().prank(owner1);
        childToken.approve(address(stake), 200e18);
        vm().prank(owner1);
        stake.stakeBoost(address(childToken), 200e18, 10, memberId3);
        // A third position keeps `targetGovVotes` and `totalValidGovVotes` apart.
        stakeAsOwner(owner1, memberId1, 400e18, 400e18, 10);

        vm().recordLogs();
        vm().prank(owner2);
        stake.mergeStake(address(childToken), memberId2, memberId3);

        Vm.Log[] memory logs = vm().getRecordedLogs();
        bytes32 topic = keccak256(
            "StakesMerged(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
        );
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(stake) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != topic) continue;
            require(logs[i].topics.length == 4, "three indexed arguments");
            require(logs[i].topics[1] == bytes32(uint256(uint160(address(childToken)))), "event token");
            require(logs[i].topics[2] == bytes32(memberId2), "event source member");
            require(logs[i].topics[3] == bytes32(memberId3), "event target member");
            StakesMergedPayload memory payload = abi.decode(logs[i].data, (StakesMergedPayload));
            require(payload.round == 1, "event round is not indexed");
            require(payload.liquiditySharesMerged == shares, "event merged shares");
            require(payload.boostSharesMerged == 0, "event merged boost");
            require(payload.targetLiquidityShares == shares + targetSharesBefore, "event target shares");
            require(payload.targetBoostShares == 200e18, "event target boost");
            require(payload.targetPromisedWaitingPhases == 10, "event target phases");
            require(payload.targetGovVotes == (shares + targetSharesBefore) * 10, "event target gov votes");
            require(payload.prevSourceGovVotes == shares * 10, "event source votes before the merge");
            require(payload.prevSourcePromisedWaitingPhases == 10, "event source phases before the merge");
            require(
                payload.totalValidGovVotes == _totalValidGovVotes(address(childToken)),
                "event global votes after the merge"
            );
            require(payload.totalValidGovVotes != payload.targetGovVotes, "global and target votes stay apart");
            found = true;
        }
        require(found, "missing StakesMerged");

        // The community total is not maintained on its own: it has to equal the sum of the members at
        // every write point, and the merge is the only one where the two ledgers move by different
        // amounts (the source is removed at its own waiting phases, the target is re-priced at its own).
        uint256 memberSum = _validGovVotes(address(childToken), memberId1)
            + _validGovVotes(address(childToken), memberId2) + _validGovVotes(address(childToken), memberId3);
        require(memberSum > 0, "the fixture keeps the sum non-zero");
        require(
            _totalValidGovVotes(address(childToken)) == memberSum, "the community total equals the sum of members"
        );
        require(_validGovVotes(address(childToken), memberId2) == 0, "the merged source holds no votes");
    }

    function testBoostIncreasesGlobalBoostShares() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        (, , , , uint256 globalBoostBefore, , ) = stake.totalStake(address(childToken));

        vm().prank(owner1);
        childToken.approve(address(stake), 500e18);
        vm().prank(owner1);
        stake.stakeBoost(address(childToken), 500e18, 10, memberId1);

        (, , , , uint256 globalBoostAfter, , ) = stake.totalStake(address(childToken));

        require(globalBoostAfter == globalBoostBefore + 500e18, "Global boost should increase");
    }

    function testWithdrawDecreasesGlobalBoostShares() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        vm().prank(owner1);
        childToken.approve(address(stake), 500e18);
        vm().prank(owner1);
        stake.stakeBoost(address(childToken), 500e18, 10, memberId1);

        (, , , , uint256 globalBoostBefore, , ) = stake.totalStake(address(childToken));

        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);
        phase.setPhase(12);

        vm().prank(owner1);
        stake.withdraw(address(childToken), memberId1);

        (, , , , uint256 globalBoostAfter, , ) = stake.totalStake(address(childToken));

        require(globalBoostAfter == 0, "Global boost should be zero");
        require(globalBoostBefore > 0, "Should have had boost before");
    }


    // ============ View Function Coverage Tests ============

    function testPairAddressReturnsZeroForUnregistered() external view {
        address fakeToken = address(0xdead);
        address cachedPair = stake.pairAddress(fakeToken);
        require(cachedPair == address(0), "Should return zero for unregistered token");
    }

    function testValidGovVotesReturnsZeroAfterUnstake() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        uint256 votesBefore = _validGovVotes(address(childToken), memberId1);
        require(votesBefore > 0, "Should have votes before unstake");

        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);

        uint256 votesAfter = _validGovVotes(address(childToken), memberId1);
        require(votesAfter == 0, "Should have zero votes after unstake");
    }

    function testValidGovVotesForNonExistentStake() external view {
        uint256 votes = _validGovVotes(address(childToken), 999);
        require(votes == 0, "Should return zero for non-existent stake");
    }

    function testTotalStakeWithNoStakes() external view {
        (
            uint256 totalShares,
            uint256 totalLp,
            uint256 withdrawableLp,
            uint256 feeLp,
            uint256 totalBoost,
            uint256 tokenAmount,
            uint256 parentAmount
        ) = stake.totalStake(address(childToken));

        require(totalShares == 0, "Total shares should be zero");
        require(totalLp == 0, "Total LP should be zero");
        require(withdrawableLp == 0, "Withdrawable LP should be zero");
        require(feeLp == 0, "Fee LP should be zero");
        require(totalBoost == 0, "Total boost should be zero");
        require(tokenAmount == 0, "Token amount should be zero");
        require(parentAmount == 0, "Parent amount should be zero");
    }

    function testMemberStakeWithNoStake() external view {
        (
            uint256 shares,
            uint256 boost,
            uint256 phases,
            uint256 unlock,
            uint256 tokenAmount,
            uint256 parentAmount
        ) = stake.memberStake(address(childToken), memberId1);

        require(shares == 0, "Shares should be zero");
        require(boost == 0, "Boost should be zero");
        require(phases == 0, "Phases should be zero");
        require(unlock == 0, "Unlock should be zero");
        require(tokenAmount == 0, "Token amount should be zero");
        require(parentAmount == 0, "Parent amount should be zero");
    }

    function testTotalBurnedTokenStartsAtZero() external view {
        uint256 burned = stake.totalBurnedToken(address(childToken));
        require(burned == 0, "Should start at zero");
    }

    function testTotalParentTokenBurnedStartsAtZero() external view {
        uint256 burned = stake.totalParentTokenBurned(address(childToken));
        require(burned == 0, "Should start at zero");
    }

    function testGlobalGovVotesStartsAtZero() external view {
        uint256 votes = _totalValidGovVotes(address(childToken));
        require(votes == 0, "Should start at zero");
    }

    // ============ Multi-User Interaction Tests ============

    function testTwoUsersStakeIndependently() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);
        stakeAsOwner(owner2, memberId2, 1000e18, 1000e18, 10);

        (uint256 shares1, , , , , ) = stake.memberStake(address(childToken), memberId1);
        (uint256 shares2, , , , , ) = stake.memberStake(address(childToken), memberId2);

        require(shares1 > 0, "User 1 should have shares");
        require(shares2 > 0, "User 2 should have shares");
    }

    function testTotalStakeReflectsMultipleUsers() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);
        stakeAsOwner(owner2, memberId2, 500e18, 500e18, 10);

        (uint256 totalShares, , , , , , ) = stake.totalStake(address(childToken));
        (uint256 shares1, , , , , ) = stake.memberStake(address(childToken), memberId1);
        (uint256 shares2, , , , , ) = stake.memberStake(address(childToken), memberId2);

        require(totalShares == shares1 + shares2, "Global shares should equal sum");
    }

    function testOneUserWithdrawDoesNotAffectOther() external {
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);
        stakeAsOwner(owner2, memberId2, 1000e18, 1000e18, 10);

        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);
        phase.setPhase(12);

        vm().prank(owner1);
        stake.withdraw(address(childToken), memberId1);

        (uint256 shares1, , , , , ) = stake.memberStake(address(childToken), memberId1);
        (uint256 shares2, , , , , ) = stake.memberStake(address(childToken), memberId2);

        require(shares1 == 0, "User 1 should have no shares");
        require(shares2 > 0, "User 2 should still have shares");
    }

    // ============ Phase Transition Tests ============

    function testPhaseTransitionDoesNotBreakStake() external {
        phase.setPhase(1);
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        phase.setPhase(5);
        stakeAsOwner(owner1, memberId1, 500e18, 500e18, 10);

        (uint256 shares, , , , , ) = stake.memberStake(address(childToken), memberId1);
        require(shares > 0, "Should accumulate shares across phases");
    }

    function testUnstakeInLaterPhaseWorks() external {
        phase.setPhase(1);
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        phase.setPhase(5);

        vm().prank(owner1);
        stake.unstake(address(childToken), memberId1);

        (, , , uint256 unlock, , ) = stake.memberStake(address(childToken), memberId1);
        require(unlock == 5, "Unlock should be at phase 5");
    }

    // Test token ordering: when childToken is token1 (not token0)
    function testStakeWithTokenAsToken1() external {
        // Deploy new child token that will use a reversed pair
        LOVE20Token newChild = new LOVE20Token(
            "New Child",
            "NCHILD",
            1000000e18,
            2000000e18,
            address(this),
            address(this),
            address(parentToken)
        );
        mockLaunch.register(address(newChild));

        // Create a new pair with reversed token order (parent is token0, child is token1)
        MockPair reversedPair = new MockPair(address(parentToken), address(newChild));

        // Register the reversed pair in factory BEFORE any transfers
        pairFactory.setPair(address(newChild), address(parentToken), address(reversedPair));

        // Initialize pair reserves to 0 first
        reversedPair.setReserves(0, 0);

        // Transfer initial liquidity to pair
        parentToken.transfer(address(reversedPair), 100000e18);
        newChild.transfer(address(reversedPair), 100000e18);

        // Update reserves after transfer
        reversedPair.setReserves(100000e18, 100000e18);

        // Transfer tokens to owner1
        newChild.transfer(owner1, 100000e18);
        parentToken.transfer(owner1, 100000e18);

        // Stake with the reversed pair
        vm().prank(owner1);
        newChild.approve(address(stake), 1000e18);
        vm().prank(owner1);
        parentToken.approve(address(stake), 1000e18);

        vm().prank(owner1);
        (, uint256 shares) = stake.stakeLiquidity(
            address(newChild),
            1000e18,
            1000e18,
            0.05e18,
            10,
            memberId1
        );

        require(shares > 0, "Should stake with reversed token order");

        // Withdraw to hit the else branch in _burnLp (line 689)
        vm().prank(owner1);
        stake.unstake(address(newChild), memberId1);

        phase.setPhase(12);

        // Fund the stake contract for withdrawal
        newChild.transfer(address(stake), 10000e18);

        vm().prank(owner1);
        stake.withdraw(address(newChild), memberId1);
    }

    // Test staking to empty pool (covers line 628)
    function testStakeToEmptyPool() external {
        // Create a new token with empty pair
        LOVE20Token emptyToken = new LOVE20Token(
            "Empty Token",
            "EMPTY",
            1000000e18,
            2000000e18,
            address(this),
            address(this),
            address(parentToken)
        );
        mockLaunch.register(address(emptyToken));

        MockPair emptyPair = new MockPair(address(emptyToken), address(parentToken));
        // Set reserves to 0 to simulate empty pool
        emptyPair.setReserves(0, 0);
        pairFactory.setPair(address(emptyToken), address(parentToken), address(emptyPair));

        emptyToken.transfer(owner1, 100000e18);

        vm().prank(owner1);
        emptyToken.approve(address(stake), 1000e18);
        vm().prank(owner1);
        parentToken.approve(address(stake), 1000e18);

        vm().prank(owner1);
        (, uint256 shares) = stake.stakeLiquidity(
            address(emptyToken),
            1000e18,
            1000e18,
            0.05e18,
            10,
            memberId1
        );

        require(shares > 0, "Should handle empty pool");
    }


    // ============ Additional Error Path Coverage Tests ============

    function testStakeLiquidityRevertsWithInvalidToken() external {
        // Create a mock token that returns address(0) for parentTokenAddress
        // Unregistered tokens are rejected before Pair lookup.
        MockInvalidToken invalidToken = new MockInvalidToken();

        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(
                Stake.stakeLiquidity.selector, address(invalidToken), 1000e18, 1000e18, 0.05e18, 10, memberId1
            ),
            abi.encodeWithSelector(IStakeErrors.TokenNotRegistered.selector, address(invalidToken)),
            "Should revert with invalid token"
        );
    }

    function testAddLiquidityRevertsWithZeroLpMinted() external {
        // Create a pair that returns 0 LP when minting
        LOVE20Token zeroLpToken = new LOVE20Token(
            "Zero LP Token",
            "ZEROLP",
            1000000e18,
            2000000e18,
            address(this),
            address(this),
            address(parentToken)
        );
        mockLaunch.register(address(zeroLpToken));

        MockPairZeroMint zeroMintPair = new MockPairZeroMint(address(zeroLpToken), address(parentToken));
        pairFactory.setPair(address(zeroLpToken), address(parentToken), address(zeroMintPair));

        zeroLpToken.transfer(owner1, 100000e18);

        vm().prank(owner1);
        zeroLpToken.approve(address(stake), 1000e18);
        vm().prank(owner1);
        parentToken.approve(address(stake), 1000e18);

        vm().prank(owner1);
        _expectRevertData(
            address(stake),
            abi.encodeWithSelector(
                Stake.stakeLiquidity.selector, address(zeroLpToken), 1000e18, 1000e18, 0.05e18, 10, memberId1
            ),
            abi.encodeWithSelector(IStakeErrors.ZeroLiquidityMinted.selector),
            "Should revert with zero LP minted"
        );
    }

    // Test first branch of _optimalAmounts (line 632): excess parent token
    function testStakeWithExcessParentToken() external {
        // First stake to create reserves
        stakeAsOwner(owner1, memberId1, 1000e18, 1000e18, 10);

        // Second stake with MORE parent than needed (triggers first branch)
        vm().prank(owner2);
        childToken.approve(address(stake), 1000e18);
        vm().prank(owner2);
        parentToken.approve(address(stake), 1200e18); // Excess parent

        vm().prank(owner2);
        (, uint256 shares) = stake.stakeLiquidity(
            address(childToken),
            1000e18,
            1200e18, // More parent than optimal
            0.2e18, // 20% slippage to allow deviation
            10,
            memberId2
        );

        require(shares > 0, "Should stake with excess parent token");
    }
}

/// Mock token that returns address(0) for parentTokenAddress
contract MockInvalidToken {
    function PARENT_TOKEN_ADDRESS() external pure returns (address) {
        return address(0);
    }
}

/// Mock token whose transfers report failure instead of reverting
contract FalseReturningToken {
    address private immutable _parentTokenAddress;

    constructor(address parentTokenAddress_) {
        _parentTokenAddress = parentTokenAddress_;
    }

    function PARENT_TOKEN_ADDRESS() external view returns (address) {
        return _parentTokenAddress;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

/// Mock pair that returns 0 when minting LP
contract MockPairZeroMint {
    address public token0;
    address public token1;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (0, 0, uint32(block.timestamp));
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function mint(address) external pure returns (uint256) {
        return 0; // Always return 0 to trigger the error
    }
}

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function prank(address) external;
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
}
