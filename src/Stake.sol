// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {RoundHistoryUint256} from "@libs/RoundHistoryUint256.sol";
import {IPhase} from "./interfaces/IPhase.sol";
import {ILaunch} from "./interfaces/ILaunch.sol";
import {ISubmit} from "./interfaces/ISubmit.sol";
import {ILOVE20Token} from "./interfaces/ILOVE20Token.sol";
import {IMemberNFT} from "./interfaces/IMemberNFT.sol";
import {IUniswapV2Pair} from "./interfaces/UniswapV2/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "./interfaces/UniswapV2/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "./interfaces/UniswapV2/IUniswapV2Router02.sol";
import {IVote} from "./interfaces/IVote.sol";
import {IStake, MemberStake, TotalStake} from "./interfaces/IStake.sol";

struct AddedLiquidity {
    uint256 tokenAmount;
    uint256 parentTokenAmount;
    uint256 lpMinted;
    uint256 withdrawableLpBefore;
}

struct MergedStake {
    uint256 liquidityShares;
    uint256 boostShares;
    uint256 prevSourceGovVotes;
    uint256 prevSourcePromisedWaitingPhases;
    uint256 targetGovVotes;
    uint256 targetLiquidityShares;
    uint256 targetBoostShares;
    uint256 targetPromisedWaitingPhases;
    uint256 totalValidGovVotes;
}

struct PairSnapshot {
    uint256 reserveToken;
    uint256 reserveParent;
    uint256 pairTotalSupply;
}

/// @dev Write-time context of an increase: the event carries both the caller-visible roles and the
///      old/new waiting period, and keeping them in one memory slot is what keeps the entry points
///      inside the stack limit.
struct StakeWrite {
    uint256 round;
    uint256 memberId;
    address memberOwner;
    uint256 promisedWaitingPhases;
    uint256 prevPromisedWaitingPhases;
}

/// @dev Staging struct for the `LiquidityStaked` payload. The event carries sixteen fields, so the values
///      are collected in memory first and the emit only touches this one pointer.
struct LiquidityStakedPayload {
    address tokenAddress;
    uint256 round;
    uint256 memberId;
    address caller;
    address memberOwner;
    uint256 tokenAmount;
    uint256 parentTokenAmount;
    uint256 promisedWaitingPhases;
    uint256 prevPromisedWaitingPhases;
    uint256 govVotesAdded;
    uint256 liquiditySharesAdded;
    uint256 liquidityShares;
    uint256 totalLiquidityShares;
    uint256 totalValidGovVotes;
    uint256 totalWithdrawableLp;
}

/// @dev Staging struct for the `BoostStaked` payload, same reason as `LiquidityStakedPayload`.
struct BoostStakedPayload {
    address tokenAddress;
    uint256 round;
    uint256 memberId;
    address caller;
    address memberOwner;
    uint256 boostAmount;
    uint256 promisedWaitingPhases;
    uint256 prevPromisedWaitingPhases;
    uint256 govVotesAdded;
    uint256 govVotes;
    uint256 boostShares;
    uint256 totalBoostShares;
    uint256 totalValidBoostShares;
    uint256 totalValidGovVotes;
}

contract Stake is IStake {
    using RoundHistoryUint256 for RoundHistoryUint256.History;
    using SafeERC20 for IERC20;

    uint256 private constant PRECISION = 1e18;
    uint256 public constant LIQUIDITY_TOKEN_EQUIVALENCE_FACTOR = 2;

    address public PHASE_ADDRESS;
    address public MEMBER_NFT_ADDRESS;
    address public VOTE_ADDRESS;
    address public LAUNCH_ADDRESS;
    address public ROUTER_ADDRESS;
    address public PAIR_FACTORY_ADDRESS;
    uint256 public PROMISED_WAITING_PHASES_MIN;
    uint256 public PROMISED_WAITING_PHASES_MAX;
    uint256 public FEE_SETTLEMENT_RATIO;
    uint256 public BOOST_STAKE_SUPPLY_FACTOR;
    uint256 public BOOST_STAKE_MULTIPLIER;

    mapping(address => address) internal _pairAddressByTokenAddress;
    mapping(address => TotalStake) internal _totalStake;
    mapping(address => mapping(uint256 => MemberStake)) internal _memberStake;
    mapping(address => uint256) internal _totalBurnedToken;
    mapping(address => uint256) internal _totalParentTokenBurned;
    mapping(address => RoundHistoryUint256.History) internal _totalValidGovVotesAdded;
    mapping(address => RoundHistoryUint256.History) internal _totalValidGovVotesRemoved;
    mapping(address => RoundHistoryUint256.History) internal _totalValidBoostSharesAdded;
    mapping(address => RoundHistoryUint256.History) internal _totalValidBoostSharesRemoved;
    mapping(address => mapping(uint256 => RoundHistoryUint256.History)) internal _validGovVotesByMember;
    mapping(address => mapping(uint256 => RoundHistoryUint256.History)) internal _validBoostSharesByMember;
    // tokenAddress => phase of the last realised settlement; one settlement per community per phase
    mapping(address => uint256) internal _lastSettlePhase;
    mapping(address => uint256) internal _totalLiquidityTokenAmount;

    // forge-lint: disable-next-item(missing-zero-check)
    constructor(
        address phaseAddress,
        address memberNFTAddress,
        address voteAddress,
        address launchAddress,
        address routerAddress,
        address pairFactoryAddress,
        uint256 promisedWaitingPhasesMin,
        uint256 promisedWaitingPhasesMax,
        uint256 feeSettlementRatio,
        uint256 boostStakeSupplyFactor,
        uint256 boostStakeMultiplier
    ) {
        PHASE_ADDRESS = phaseAddress;
        MEMBER_NFT_ADDRESS = memberNFTAddress;
        VOTE_ADDRESS = voteAddress;
        LAUNCH_ADDRESS = launchAddress;
        ROUTER_ADDRESS = routerAddress;
        PAIR_FACTORY_ADDRESS = pairFactoryAddress;
        PROMISED_WAITING_PHASES_MIN = promisedWaitingPhasesMin;
        PROMISED_WAITING_PHASES_MAX = promisedWaitingPhasesMax;
        FEE_SETTLEMENT_RATIO = feeSettlementRatio;
        BOOST_STAKE_SUPPLY_FACTOR = boostStakeSupplyFactor;
        BOOST_STAKE_MULTIPLIER = boostStakeMultiplier;
    }

    function settleFees(address tokenAddress) external {
        _checkToken(tokenAddress);
        _settleFees(tokenAddress, _pairFor(tokenAddress), _currentRound());
    }

    modifier onlyMemberOwner(uint256 memberId) {
        if (IMemberNFT(MEMBER_NFT_ADDRESS).ownerOf(memberId) != msg.sender) revert NotMemberOwner(memberId);
        _;
    }

    function stakeLiquidity(
        address tokenAddress,
        uint256 tokenAmount,
        uint256 parentTokenAmount,
        uint256 promisedWaitingPhases,
        uint256 memberId
    ) external returns (uint256 govVotesAdded, uint256 liquiditySharesAdded) {
        if (tokenAmount == 0) revert ZeroTokenAmount();
        if (parentTokenAmount == 0) revert ZeroParentTokenAmount();
        _checkPromisedWaitingPhases(promisedWaitingPhases);
        // Only existence is checked: anyone may add to an existing position (unpermissioned increase).
        address memberOwner = IMemberNFT(MEMBER_NFT_ADDRESS).ownerOf(memberId);
        _checkToken(tokenAddress);
        address pair = _pairFor(tokenAddress);
        uint256 round = _checkActiveRound();

        MemberStake storage member = _memberStake[tokenAddress][memberId];
        _checkNoUnstakeRequest(member, tokenAddress, memberId);
        _checkPromisedWaitingPhasesNotRewritten(member, memberOwner, promisedWaitingPhases);

        AddedLiquidity memory added = _addLiquidity(tokenAddress, pair, round, tokenAmount, parentTokenAmount);
        StakeWrite memory write = StakeWrite({
            round: round,
            memberId: memberId,
            memberOwner: memberOwner,
            promisedWaitingPhases: promisedWaitingPhases,
            prevPromisedWaitingPhases: member.promisedWaitingPhases
        });
        return _creditLiquidity(tokenAddress, pair, write, added);
    }

    function stakeBoost(address tokenAddress, uint256 boostAmount, uint256 promisedWaitingPhases, uint256 memberId)
        external
        returns (uint256 govVotesAdded)
    {
        if (boostAmount == 0) revert ZeroBoostAmount();
        _checkPromisedWaitingPhases(promisedWaitingPhases);
        // Only existence is checked: anyone may add to an existing position (unpermissioned increase).
        address memberOwner = IMemberNFT(MEMBER_NFT_ADDRESS).ownerOf(memberId);
        _checkToken(tokenAddress);
        uint256 round = _checkActiveRound();

        MemberStake storage member = _memberStake[tokenAddress][memberId];
        _checkNoUnstakeRequest(member, tokenAddress, memberId);
        _checkStakedLiquidity(member, tokenAddress, memberId);
        _checkPromisedWaitingPhasesNotRewritten(member, memberOwner, promisedWaitingPhases);

        TotalStake storage totals = _totalStake[tokenAddress];
        _checkBoostCap(tokenAddress, memberId, round, boostAmount);

        StakeWrite memory write = StakeWrite({
            round: round,
            memberId: memberId,
            memberOwner: memberOwner,
            promisedWaitingPhases: promisedWaitingPhases,
            prevPromisedWaitingPhases: member.promisedWaitingPhases
        });

        _pull(tokenAddress, msg.sender, boostAmount);

        member.boostShares += boostAmount;
        totals.totalBoostShares += boostAmount;

        if (promisedWaitingPhases > write.prevPromisedWaitingPhases) {
            govVotesAdded = member.liquidityShares * (promisedWaitingPhases - write.prevPromisedWaitingPhases);
            member.promisedWaitingPhases = promisedWaitingPhases;
            _totalValidGovVotesAdded[tokenAddress].increase(round, govVotesAdded);
            _validGovVotesByMember[tokenAddress][memberId].increase(round, govVotesAdded);
        }

        _validBoostSharesByMember[tokenAddress][memberId].increase(round, boostAmount);
        _totalValidBoostSharesAdded[tokenAddress].increase(round, boostAmount);

        _emitBoostStaked(_boostStakedPayload(tokenAddress, write, boostAmount, govVotesAdded));
    }

    function unstake(address tokenAddress, uint256 memberId) external onlyMemberOwner(memberId) {
        _checkToken(tokenAddress);

        MemberStake storage member = _memberStake[tokenAddress][memberId];
        _checkNoUnstakeRequest(member, tokenAddress, memberId);
        _checkStakedLiquidity(member, tokenAddress, memberId);

        uint256 round = _currentRound();
        if (_hasUsedStakeRights(tokenAddress, round, memberId)) {
            revert StakeRightsUsed(tokenAddress, round, memberId);
        }

        uint256 govVotes = _govVotesOf(member);
        uint256 boostShares = member.boostShares;

        member.unlockRequestPhase = round;
        _totalValidGovVotesRemoved[tokenAddress].increase(round, govVotes);
        _validGovVotesByMember[tokenAddress][memberId].decrease(round, govVotes);

        if (boostShares > 0) {
            _validBoostSharesByMember[tokenAddress][memberId].decrease(round, boostShares);
            _totalValidBoostSharesRemoved[tokenAddress].increase(round, boostShares);
        }

        uint256 validBoostSharesTotal = _totalValidBoostSharesAt(tokenAddress, round);
        uint256 govVotesTotal = _totalValidGovVotesAt(tokenAddress, round);

        emit Unstaked({
            tokenAddress: tokenAddress,
            round: round,
            memberId: memberId,
            promisedWaitingPhases: member.promisedWaitingPhases,
            govVotes: govVotes,
            liquidityShares: member.liquidityShares,
            boostShares: member.boostShares,
            totalValidBoostShares: validBoostSharesTotal,
            totalValidGovVotes: govVotesTotal
        });
    }

    function withdraw(address tokenAddress, uint256 memberId) external onlyMemberOwner(memberId) {
        _checkToken(tokenAddress);
        address pair = _pairFor(tokenAddress);

        MemberStake storage member = _memberStake[tokenAddress][memberId];
        if (member.unlockRequestPhase == 0) revert UnstakeNotRequested(tokenAddress, memberId);
        _checkStakedLiquidity(member, tokenAddress, memberId);

        uint256 round = _currentRound();
        uint256 promisedWaitingPhases = member.promisedWaitingPhases;
        uint256 liquidityShares = member.liquidityShares;
        uint256 boostShares = member.boostShares;
        if (round <= member.unlockRequestPhase + promisedWaitingPhases) {
            revert UnlockRoundNotReached(round, member.unlockRequestPhase + promisedWaitingPhases);
        }

        delete _memberStake[tokenAddress][memberId];

        (
            uint256 tokenAmountForLiquidity,
            uint256 parentTokenAmountForLiquidity,
            uint256 withdrawableLpBurned,
            uint256 withdrawableLpToMember
        ) = _withdrawLiquidity(tokenAddress, pair, round, liquidityShares);

        // Only the asset and the community share total move here: the boost history was already reduced
        // when the unlock was requested.
        if (boostShares > 0) {
            _push(tokenAddress, msg.sender, boostShares);
            _totalStake[tokenAddress].totalBoostShares -= boostShares;
        }

        TotalStake storage totals = _totalStake[tokenAddress];
        // forge-lint: disable-next-item(reentrancy-events)
        emit StakeWithdrawn({
            tokenAddress: tokenAddress,
            round: round,
            memberId: memberId,
            promisedWaitingPhases: promisedWaitingPhases,
            liquidityShares: liquidityShares,
            tokenAmountForLiquidity: tokenAmountForLiquidity,
            parentTokenAmountForLiquidity: parentTokenAmountForLiquidity,
            boostShares: boostShares,
            withdrawableLpBurned: withdrawableLpBurned,
            withdrawableLpToMember: withdrawableLpToMember,
            totalLiquidityShares: totals.totalLiquidityShares,
            totalBoostShares: totals.totalBoostShares,
            totalWithdrawableLp: totals.lastWithdrawableLp
        });
    }

    function mergeStake(address tokenAddress, uint256 sourceMemberId, uint256 targetMemberId)
        external
        onlyMemberOwner(sourceMemberId)
    {
        if (sourceMemberId == targetMemberId) {
            revert SourceEqualsTarget(sourceMemberId);
        }
        _checkToken(tokenAddress);
        // forge-lint: disable-next-item(unused-return)
        IMemberNFT(MEMBER_NFT_ADDRESS).ownerOf(targetMemberId);

        MemberStake storage source = _memberStake[tokenAddress][sourceMemberId];
        MemberStake storage target = _memberStake[tokenAddress][targetMemberId];
        _checkNoUnstakeRequest(source, tokenAddress, sourceMemberId);
        _checkNoUnstakeRequest(target, tokenAddress, targetMemberId);
        _checkStakedLiquidity(source, tokenAddress, sourceMemberId);

        uint256 round = _currentRound();
        if (_hasUsedStakeRights(tokenAddress, round, sourceMemberId)) {
            revert StakeRightsUsed(tokenAddress, round, sourceMemberId);
        }

        bool targetHadPosition = target.liquidityShares != 0 || target.boostShares != 0;

        MergedStake memory merged = _mergeIntoTarget(tokenAddress, round, sourceMemberId, targetMemberId);

        if (merged.boostShares > 0) {
            _moveBoostHistory(tokenAddress, sourceMemberId, targetMemberId, merged.boostShares, round);
        }

        if (merged.boostShares > 0 && targetHadPosition) {
            uint256 targetBoostShares = _memberStake[tokenAddress][targetMemberId].boostShares;
            (, uint256 targetCap) = _boostStakeBaseAndMemberCap(tokenAddress, targetMemberId, round);
            if (targetBoostShares > targetCap) {
                revert BoostCapExceeded(tokenAddress, targetMemberId, targetBoostShares, targetCap);
            }
        }

        emit StakesMerged({
            tokenAddress: tokenAddress,
            round: round,
            sourceMemberId: sourceMemberId,
            targetMemberId: targetMemberId,
            liquiditySharesMerged: merged.liquidityShares,
            boostSharesMerged: merged.boostShares,
            targetGovVotes: merged.targetGovVotes,
            targetLiquidityShares: merged.targetLiquidityShares,
            targetBoostShares: merged.targetBoostShares,
            targetPromisedWaitingPhases: merged.targetPromisedWaitingPhases,
            prevSourceGovVotes: merged.prevSourceGovVotes,
            prevSourcePromisedWaitingPhases: merged.prevSourcePromisedWaitingPhases,
            totalValidGovVotes: merged.totalValidGovVotes
        });
    }

    function pairAddress(address tokenAddress) external view returns (address) {
        return _pairAddressByTokenAddress[tokenAddress];
    }

    function totalBurnedToken(address tokenAddress) external view returns (uint256) {
        return _totalBurnedToken[tokenAddress];
    }

    function totalParentTokenBurned(address tokenAddress) external view returns (uint256) {
        return _totalParentTokenBurned[tokenAddress];
    }

    function validGovVotes(address tokenAddress, uint256 round, uint256 memberId)
        external
        view
        returns (uint256)
    {
        _checkRoundStarted(round);
        return _validGovVotesByMember[tokenAddress][memberId].value(round);
    }

    function totalValidGovVotes(address tokenAddress, uint256 round) external view returns (uint256) {
        _checkRoundStarted(round);
        return _totalValidGovVotesAt(tokenAddress, round);
    }

    function totalValidGovVotesAdded(address tokenAddress, uint256 round) external view returns (uint256) {
        _checkRoundStarted(round);
        return _totalValidGovVotesAdded[tokenAddress].value(round);
    }

    function totalValidGovVotesRemoved(address tokenAddress, uint256 round) external view returns (uint256) {
        _checkRoundStarted(round);
        return _totalValidGovVotesRemoved[tokenAddress].value(round);
    }

    function memberStake(address tokenAddress, uint256 memberId)
        external
        view
        returns (
            uint256 liquidityShares,
            uint256 boostShares,
            uint256 promisedWaitingPhases,
            uint256 unlockRequestPhase,
            uint256 tokenAmountForLiquidity,
            uint256 parentTokenAmountForLiquidity,
            uint256 firstGovVoteRound
        )
    {
        MemberStake storage member = _memberStake[tokenAddress][memberId];
        liquidityShares = member.liquidityShares;
        boostShares = member.boostShares;
        promisedWaitingPhases = member.promisedWaitingPhases;
        unlockRequestPhase = member.unlockRequestPhase;
        firstGovVoteRound = member.firstGovVoteRound;

        TotalStake storage totals = _totalStake[tokenAddress];
        address pair = _pairAddressByTokenAddress[tokenAddress];
        if (pair != address(0) && totals.totalLiquidityShares != 0) {
            PairSnapshot memory snapshot = _pairSnapshot(pair, tokenAddress);
            (, uint256 withdrawableLp, ) = _previewReclassification(totals, snapshot);
            uint256 lpAmount = (liquidityShares * withdrawableLp) / totals.totalLiquidityShares;
            if (snapshot.pairTotalSupply != 0) {
                // The share is converted in two steps on purpose: `lpAmount` is the value the spec defines
                // and folding both divisions into one expression would round a different quantity.
                // forge-lint: disable-next-line(divide-before-multiply)
                tokenAmountForLiquidity = (lpAmount * snapshot.reserveToken) / snapshot.pairTotalSupply;
                // forge-lint: disable-next-line(divide-before-multiply)
                parentTokenAmountForLiquidity = (lpAmount * snapshot.reserveParent) / snapshot.pairTotalSupply;
            }
        }
    }

    function totalStake(address tokenAddress)
        external
        view
        returns (
            uint256 totalLiquidityShares,
            uint256 totalLp,
            uint256 withdrawableLp,
            uint256 feeLp,
            uint256 totalBoostShares,
            uint256 tokenAmountForLiquidity,
            uint256 parentTokenAmountForLiquidity,
            uint256 firstGovVoteRound
        )
    {
        TotalStake storage totals = _totalStake[tokenAddress];
        totalLiquidityShares = totals.totalLiquidityShares;
        totalLp = totals.lastFeeLp + totals.lastWithdrawableLp;
        totalBoostShares = totals.totalBoostShares;
        firstGovVoteRound = totals.firstGovVoteRound;

        address pair = _pairAddressByTokenAddress[tokenAddress];
        if (pair == address(0)) {
            return (totalLiquidityShares, totalLp, 0, 0, totalBoostShares, 0, 0, firstGovVoteRound);
        }

        PairSnapshot memory snapshot = _pairSnapshot(pair, tokenAddress);
        (feeLp, withdrawableLp, ) = _previewReclassification(totals, snapshot);
        if (snapshot.pairTotalSupply != 0) {
            tokenAmountForLiquidity = (withdrawableLp * snapshot.reserveToken) / snapshot.pairTotalSupply;
            parentTokenAmountForLiquidity = (withdrawableLp * snapshot.reserveParent) / snapshot.pairTotalSupply;
        }
    }

    function liquidityTokenAmount(address tokenAddress) external view returns (uint256) {
        return _totalLiquidityTokenAmount[tokenAddress];
    }

    function boostStakeCap(address tokenAddress, uint256 memberId)
        external
        view
        returns (uint256 memberCap, uint256 memberUsed)
    {
        (, memberCap) = _boostStakeBaseAndMemberCap(tokenAddress, memberId, _currentRound());
        memberUsed = _memberStake[tokenAddress][memberId].boostShares;
    }

    function canWithdraw(address tokenAddress, uint256 memberId) external view returns (bool) {
        MemberStake storage member = _memberStake[tokenAddress][memberId];
        if (member.unlockRequestPhase == 0) return false;
        return _currentRound() > member.unlockRequestPhase + member.promisedWaitingPhases;
    }

    function validBoostShares(address tokenAddress, uint256 round, uint256 memberId)
        external
        view
        returns (uint256)
    {
        _checkRoundStarted(round);
        return _validBoostSharesByMember[tokenAddress][memberId].value(round);
    }

    function totalValidBoostShares(address tokenAddress, uint256 round) external view returns (uint256) {
        _checkRoundStarted(round);
        return _totalValidBoostSharesAt(tokenAddress, round);
    }

    function totalValidBoostSharesAdded(address tokenAddress, uint256 round) external view returns (uint256) {
        _checkRoundStarted(round);
        return _totalValidBoostSharesAdded[tokenAddress].value(round);
    }

    function totalValidBoostSharesRemoved(address tokenAddress, uint256 round) external view returns (uint256) {
        _checkRoundStarted(round);
        return _totalValidBoostSharesRemoved[tokenAddress].value(round);
    }

    function _currentRound() private view returns (uint256) {
        return IPhase(PHASE_ADDRESS).currentPhase();
    }

    function _checkRoundStarted(uint256 round) private view {
        uint256 currentRound = _currentRound();
        if (round > currentRound) revert RoundNotStarted(round, currentRound);
    }

    function _totalValidGovVotesAt(address tokenAddress, uint256 round) private view returns (uint256) {
        return _totalValidGovVotesAdded[tokenAddress].value(round)
            - _totalValidGovVotesRemoved[tokenAddress].value(round);
    }

    function _totalValidBoostSharesAt(address tokenAddress, uint256 round) private view returns (uint256) {
        return _totalValidBoostSharesAdded[tokenAddress].value(round)
            - _totalValidBoostSharesRemoved[tokenAddress].value(round);
    }

    function _boostStakeBaseAndMemberCap(address tokenAddress, uint256 memberId, uint256 round)
        private
        view
        returns (uint256 baseCap, uint256 memberCap)
    {
        uint256 liquidityPrincipal = _totalLiquidityTokenAmount[tokenAddress];
        if (liquidityPrincipal == 0) return (0, 0);

        {
            ILOVE20Token token = ILOVE20Token(tokenAddress);
            uint256 maxSupply = token.MAX_SUPPLY();
            if (maxSupply == 0) return (0, 0);
            uint256 mintedShare = Math.mulDiv(liquidityPrincipal, token.totalSupply(), maxSupply);
            baseCap = mintedShare * LIQUIDITY_TOKEN_EQUIVALENCE_FACTOR * BOOST_STAKE_SUPPLY_FACTOR;
        }

        uint256 totalVotes = _totalValidGovVotesAt(tokenAddress, round);
        if (totalVotes == 0) return (baseCap, 0);

        uint256 memberVotes = _validGovVotesByMember[tokenAddress][memberId].value(round);
        memberCap = Math.mulDiv(baseCap, memberVotes, totalVotes) * BOOST_STAKE_MULTIPLIER;
    }

    function _checkBoostCap(
        address tokenAddress,
        uint256 memberId,
        uint256 round,
        uint256 boostAmount
    ) private view {
        MemberStake storage member = _memberStake[tokenAddress][memberId];
        (, uint256 memberCap) = _boostStakeBaseAndMemberCap(tokenAddress, memberId, round);
        if (member.boostShares + boostAmount > memberCap) {
            uint256 memberRemaining = member.boostShares < memberCap ? memberCap - member.boostShares : 0;
            revert BoostCapExceeded(tokenAddress, memberId, boostAmount, memberRemaining);
        }
    }

    function _checkActiveRound() private view returns (uint256 round) {
        round = _currentRound();
        if (round == 0) revert StakeNotStarted();
    }

    function _checkPromisedWaitingPhases(uint256 promisedWaitingPhases) private view {
        if (promisedWaitingPhases < PROMISED_WAITING_PHASES_MIN || promisedWaitingPhases > PROMISED_WAITING_PHASES_MAX) {
            revert InvalidPromisedWaitingPhases(
                promisedWaitingPhases, PROMISED_WAITING_PHASES_MIN, PROMISED_WAITING_PHASES_MAX
            );
        }
    }

    function _checkToken(address tokenAddress) private view {
        if (!ILaunch(LAUNCH_ADDRESS).isLOVE20Token(tokenAddress)) revert TokenNotRegistered(tokenAddress);
    }

    function _checkNoUnstakeRequest(
        MemberStake storage member,
        address tokenAddress,
        uint256 memberId
    ) private view {
        if (member.unlockRequestPhase != 0) revert UnstakeAlreadyRequested(tokenAddress, memberId);
    }

    function _checkStakedLiquidity(
        MemberStake storage member,
        address tokenAddress,
        uint256 memberId
    ) private view {
        if (member.liquidityShares == 0) revert NoStakedLiquidity(tokenAddress, memberId);
    }

    /// @dev The promised waiting period is decided at the write point because the rule depends on both the
    /// caller and the position. Everybody is barred from lowering it; a caller that is not the NFT holder is
    /// additionally barred from raising it on a non-empty position, i.e. it must reuse the current value.
    /// Both directions share `PromisedWaitingPhasesDecreased` on purpose: no new error type is introduced.
    function _checkPromisedWaitingPhasesNotRewritten(
        MemberStake storage member,
        address memberOwner,
        uint256 promisedWaitingPhases
    ) private view {
        uint256 current = member.promisedWaitingPhases;
        if (promisedWaitingPhases < current) {
            revert PromisedWaitingPhasesDecreased(promisedWaitingPhases, current);
        }
        if (memberOwner == msg.sender) return;
        // Same criterion as `targetHadPosition` in `_mergeIntoTarget`, not `promisedWaitingPhases == 0`.
        bool hasPosition = member.liquidityShares != 0 || member.boostShares != 0;
        if (hasPosition && promisedWaitingPhases != current) {
            revert PromisedWaitingPhasesDecreased(promisedWaitingPhases, current);
        }
    }

    function _hasUsedStakeRights(
        address tokenAddress,
        uint256 round,
        uint256 memberId
    ) private view returns (bool) {
        if (IVote(VOTE_ADDRESS).voteAmountByMemberId(tokenAddress, round, memberId) != 0) return true;
        return ISubmit(IVote(VOTE_ADDRESS).SUBMIT_ADDRESS()).proposalIdBySubmitterId(tokenAddress, round, memberId) != 0;
    }

    function _pull(address tokenAddress, address from, uint256 amount) private {
        IERC20(tokenAddress).safeTransferFrom(from, address(this), amount);
    }

    function _push(address tokenAddress, address to, uint256 amount) private {
        // forge-lint: disable-next-line(reentrancy-no-eth)
        IERC20(tokenAddress).safeTransfer(to, amount);
    }

    function _pairFor(address tokenAddress) private returns (address pair) {
        pair = _pairAddressByTokenAddress[tokenAddress];
        if (pair == address(0)) {
            pair = IUniswapV2Factory(PAIR_FACTORY_ADDRESS).getPair(
                tokenAddress, ILOVE20Token(tokenAddress).PARENT_TOKEN_ADDRESS()
            );
            if (pair == address(0)) revert PairMissing(tokenAddress);
            _pairAddressByTokenAddress[tokenAddress] = pair;
        }
    }

    function _mergeIntoTarget(
        address tokenAddress,
        uint256 round,
        uint256 sourceMemberId,
        uint256 targetMemberId
    ) private returns (MergedStake memory merged) {
        MemberStake storage source = _memberStake[tokenAddress][sourceMemberId];
        MemberStake storage target = _memberStake[tokenAddress][targetMemberId];
        bool targetIsEmpty = target.liquidityShares == 0 && target.boostShares == 0;

        if (!targetIsEmpty && target.promisedWaitingPhases < source.promisedWaitingPhases) {
            revert TargetPromisedWaitingPhasesTooShort(
                target.promisedWaitingPhases, source.promisedWaitingPhases
            );
        }

        merged.liquidityShares = source.liquidityShares;
        merged.boostShares = source.boostShares;
        merged.prevSourcePromisedWaitingPhases = source.promisedWaitingPhases;
        merged.prevSourceGovVotes = _govVotesOf(source);
        uint256 govVotesBefore = _govVotesOf(target);

        target.liquidityShares += merged.liquidityShares;
        target.boostShares += merged.boostShares;
        if (targetIsEmpty) {
            target.promisedWaitingPhases = merged.prevSourcePromisedWaitingPhases;
        }
        if (target.firstGovVoteRound == 0) target.firstGovVoteRound = round;

        uint256 govVotesAdded = _govVotesOf(target) - govVotesBefore;
        if (merged.prevSourceGovVotes > 0) {
            _totalValidGovVotesRemoved[tokenAddress].increase(round, merged.prevSourceGovVotes);
            _validGovVotesByMember[tokenAddress][sourceMemberId].decrease(round, merged.prevSourceGovVotes);
        }
        if (govVotesAdded > 0) {
            _totalValidGovVotesAdded[tokenAddress].increase(round, govVotesAdded);
            _validGovVotesByMember[tokenAddress][targetMemberId].increase(round, govVotesAdded);
        }

        merged.targetGovVotes = _govVotesOf(target);
        merged.targetLiquidityShares = target.liquidityShares;
        merged.targetBoostShares = target.boostShares;
        merged.targetPromisedWaitingPhases = target.promisedWaitingPhases;
        merged.totalValidGovVotes = _totalValidGovVotesAt(tokenAddress, round);

        delete _memberStake[tokenAddress][sourceMemberId];
    }

    function _moveBoostHistory(address tokenAddress, uint256 sourceMemberId, uint256 targetMemberId, uint256 shares, uint256 round)
        private
    {
        _validBoostSharesByMember[tokenAddress][sourceMemberId].decrease(round, shares);
        _validBoostSharesByMember[tokenAddress][targetMemberId].increase(round, shares);
    }

    function _creditLiquidity(
        address tokenAddress,
        address pair,
        StakeWrite memory write,
        AddedLiquidity memory added
    ) private returns (uint256 govVotesAdded, uint256 liquiditySharesAdded) {
        MemberStake storage member = _memberStake[tokenAddress][write.memberId];
        TotalStake storage totals = _totalStake[tokenAddress];

        liquiditySharesAdded = totals.totalLiquidityShares == 0 || added.withdrawableLpBefore == 0
            ? added.lpMinted
            : (totals.totalLiquidityShares * added.lpMinted) / added.withdrawableLpBefore;

        govVotesAdded = (member.liquidityShares + liquiditySharesAdded) * write.promisedWaitingPhases
            - _govVotesOf(member);

        if (member.firstGovVoteRound == 0 && liquiditySharesAdded != 0) member.firstGovVoteRound = write.round;
        if (totals.firstGovVoteRound == 0 && liquiditySharesAdded != 0) totals.firstGovVoteRound = write.round;

        member.liquidityShares += liquiditySharesAdded;
        member.promisedWaitingPhases = write.promisedWaitingPhases;
        totals.totalLiquidityShares += liquiditySharesAdded;
        totals.lastWithdrawableLp += added.lpMinted;
        _totalLiquidityTokenAmount[tokenAddress] += added.tokenAmount;
        _totalValidGovVotesAdded[tokenAddress].increase(write.round, govVotesAdded);
        _validGovVotesByMember[tokenAddress][write.memberId].increase(write.round, govVotesAdded);

        _updateSqrtKBaseline(totals, pair, tokenAddress);

        _emitLiquidityStaked(_liquidityStakedPayload(tokenAddress, write, added, govVotesAdded, liquiditySharesAdded));
    }

    /// @dev The payload is built in its own frame and handed to the emitter as a single pointer: a
    ///      sixteen-field event with thirteen non-indexed fields cannot be emitted while any other local
    ///      is live, and `_creditLiquidity` still holds its own state by then.
    function _liquidityStakedPayload(
        address tokenAddress,
        StakeWrite memory write,
        AddedLiquidity memory added,
        uint256 govVotesAdded,
        uint256 liquiditySharesAdded
    ) private view returns (LiquidityStakedPayload memory payload) {
        MemberStake storage member = _memberStake[tokenAddress][write.memberId];
        TotalStake storage totals = _totalStake[tokenAddress];

        payload.tokenAddress = tokenAddress;
        payload.round = write.round;
        payload.memberId = write.memberId;
        payload.caller = msg.sender;
        payload.memberOwner = write.memberOwner;
        payload.tokenAmount = added.tokenAmount;
        payload.parentTokenAmount = added.parentTokenAmount;
        payload.promisedWaitingPhases = write.promisedWaitingPhases;
        payload.prevPromisedWaitingPhases = write.prevPromisedWaitingPhases;
        payload.govVotesAdded = govVotesAdded;
        payload.liquiditySharesAdded = liquiditySharesAdded;
        payload.liquidityShares = member.liquidityShares;
        payload.totalLiquidityShares = totals.totalLiquidityShares;
        payload.totalValidGovVotes = _totalValidGovVotesAt(tokenAddress, write.round);
        payload.totalWithdrawableLp = totals.lastWithdrawableLp;
    }

    function _emitLiquidityStaked(LiquidityStakedPayload memory payload) private {
        // forge-lint: disable-next-item(reentrancy-events)
        emit LiquidityStaked({
            tokenAddress: payload.tokenAddress,
            round: payload.round,
            memberId: payload.memberId,
            caller: payload.caller,
            memberOwner: payload.memberOwner,
            tokenAmount: payload.tokenAmount,
            parentTokenAmount: payload.parentTokenAmount,
            promisedWaitingPhases: payload.promisedWaitingPhases,
            prevPromisedWaitingPhases: payload.prevPromisedWaitingPhases,
            govVotesAdded: payload.govVotesAdded,
            liquiditySharesAdded: payload.liquiditySharesAdded,
            liquidityShares: payload.liquidityShares,
            totalLiquidityShares: payload.totalLiquidityShares,
            totalValidGovVotes: payload.totalValidGovVotes,
            totalWithdrawableLp: payload.totalWithdrawableLp
        });
    }

    function _boostStakedPayload(
        address tokenAddress,
        StakeWrite memory write,
        uint256 boostAmount,
        uint256 govVotesAdded
    ) private view returns (BoostStakedPayload memory payload) {
        MemberStake storage member = _memberStake[tokenAddress][write.memberId];
        TotalStake storage totals = _totalStake[tokenAddress];

        payload.tokenAddress = tokenAddress;
        payload.round = write.round;
        payload.memberId = write.memberId;
        payload.caller = msg.sender;
        payload.memberOwner = write.memberOwner;
        payload.boostAmount = boostAmount;
        payload.promisedWaitingPhases = write.promisedWaitingPhases;
        payload.prevPromisedWaitingPhases = write.prevPromisedWaitingPhases;
        payload.govVotesAdded = govVotesAdded;
        payload.govVotes = _govVotesOf(member);
        payload.boostShares = member.boostShares;
        payload.totalBoostShares = totals.totalBoostShares;
        payload.totalValidBoostShares = _totalValidBoostSharesAt(tokenAddress, write.round);
        payload.totalValidGovVotes = _totalValidGovVotesAt(tokenAddress, write.round);
    }

    function _emitBoostStaked(BoostStakedPayload memory payload) private {
        // forge-lint: disable-next-item(reentrancy-events)
        emit BoostStaked({
            tokenAddress: payload.tokenAddress,
            round: payload.round,
            memberId: payload.memberId,
            caller: payload.caller,
            memberOwner: payload.memberOwner,
            boostAmount: payload.boostAmount,
            promisedWaitingPhases: payload.promisedWaitingPhases,
            prevPromisedWaitingPhases: payload.prevPromisedWaitingPhases,
            govVotesAdded: payload.govVotesAdded,
            govVotes: payload.govVotes,
            boostShares: payload.boostShares,
            totalBoostShares: payload.totalBoostShares,
            totalValidBoostShares: payload.totalValidBoostShares,
            totalValidGovVotes: payload.totalValidGovVotes
        });
    }

    function _addLiquidity(
        address tokenAddress,
        address pair,
        uint256 round,
        uint256 tokenAmount,
        uint256 parentTokenAmount
    ) private returns (AddedLiquidity memory added) {
        TotalStake storage totals = _totalStake[tokenAddress];

        PairSnapshot memory snapshot = _pairSnapshot(pair, tokenAddress);
        _applyReclassification(tokenAddress, round, totals, snapshot);
        added.withdrawableLpBefore = totals.lastWithdrawableLp;

        (added.tokenAmount, added.parentTokenAmount) =
            _optimalAmounts(tokenAmount, parentTokenAmount, snapshot.reserveToken, snapshot.reserveParent);

        address parentTokenAddress = ILOVE20Token(tokenAddress).PARENT_TOKEN_ADDRESS();
        _pull(tokenAddress, msg.sender, added.tokenAmount);
        _pull(parentTokenAddress, msg.sender, added.parentTokenAmount);
        _push(tokenAddress, pair, added.tokenAmount);
        _push(parentTokenAddress, pair, added.parentTokenAmount);

        added.lpMinted = IUniswapV2Pair(pair).mint(address(this));
        if (added.lpMinted == 0) revert ZeroLiquidityMinted();
    }

    function _pairSnapshot(address pair, address tokenAddress) private view returns (PairSnapshot memory snapshot) {
        IUniswapV2Pair pairContract = IUniswapV2Pair(pair);
        // forge-lint: disable-next-item(unused-return)
        (uint112 reserve0, uint112 reserve1, ) = pairContract.getReserves();
        snapshot.pairTotalSupply = pairContract.totalSupply();
        if (tokenAddress == pairContract.token0()) {
            snapshot.reserveToken = uint256(reserve0);
            snapshot.reserveParent = uint256(reserve1);
        } else {
            snapshot.reserveToken = uint256(reserve1);
            snapshot.reserveParent = uint256(reserve0);
        }
    }

    function _previewReclassification(TotalStake storage totals, PairSnapshot memory snapshot)
        private
        view
        returns (uint256 feeLp, uint256 withdrawableLp, uint256 sqrtKOfLp)
    {
        uint256 lastFeeLp = totals.lastFeeLp;
        uint256 lastWithdrawableLp = totals.lastWithdrawableLp;
        uint256 lastSqrtKOfLp = totals.lastSqrtKOfLp;

        if (lastFeeLp + lastWithdrawableLp == 0 || lastSqrtKOfLp == 0 || snapshot.pairTotalSupply == 0) {
            return (lastFeeLp, lastWithdrawableLp, lastSqrtKOfLp);
        }

        uint256 currentSqrtKOfLp =
            (Math.sqrt(snapshot.reserveToken * snapshot.reserveParent) * (lastFeeLp + lastWithdrawableLp))
                / snapshot.pairTotalSupply;
        if (currentSqrtKOfLp == 0 || currentSqrtKOfLp <= lastSqrtKOfLp) {
            return (lastFeeLp, lastWithdrawableLp, lastSqrtKOfLp);
        }

        withdrawableLp = (lastWithdrawableLp * lastSqrtKOfLp) / currentSqrtKOfLp;
        feeLp = lastFeeLp + lastWithdrawableLp - withdrawableLp;
        sqrtKOfLp = currentSqrtKOfLp;
    }

    function _applyReclassification(
        address tokenAddress,
        uint256 round,
        TotalStake storage totals,
        PairSnapshot memory snapshot
    ) private {
        uint256 previousFeeLp = totals.lastFeeLp;
        uint256 previousWithdrawableLp = totals.lastWithdrawableLp;
        uint256 previousSqrtKOfLp = totals.lastSqrtKOfLp;

        (uint256 feeLp, uint256 withdrawableLp, uint256 sqrtKOfLp) = _previewReclassification(totals, snapshot);

        totals.lastFeeLp = feeLp;
        totals.lastWithdrawableLp = withdrawableLp;
        totals.lastSqrtKOfLp = sqrtKOfLp;

        if (sqrtKOfLp > previousSqrtKOfLp) {
            emit FeeReclassified({
                tokenAddress: tokenAddress,
                round: round,
                feeLpAdded: feeLp - previousFeeLp,
                withdrawableLpRemoved: previousWithdrawableLp - withdrawableLp,
                totalFeeLp: feeLp,
                totalWithdrawableLp: withdrawableLp,
                sqrtKOfLp: sqrtKOfLp,
                pairTotalSupply: snapshot.pairTotalSupply
            });
        }
    }

    // Pure proportional conversion: the side kept at its desired amount is never trimmed, the other is
    // scaled down to the reserve ratio. Whatever does not fit is simply not transferred, so it stays in
    // the caller's wallet. There is no tolerance and no revert (price protection lives in the caller).
    function _optimalAmounts(
        uint256 tokenAmount,
        uint256 parentTokenAmount,
        uint256 reserveToken,
        uint256 reserveParent
    ) private pure returns (uint256 optimalTokenAmount, uint256 optimalParentTokenAmount) {
        if (reserveToken == 0 || reserveParent == 0) {
            return (tokenAmount, parentTokenAmount);
        }

        optimalParentTokenAmount = (tokenAmount * reserveParent) / reserveToken;
        if (optimalParentTokenAmount <= parentTokenAmount) {
            return (tokenAmount, optimalParentTokenAmount);
        }

        optimalTokenAmount = (parentTokenAmount * reserveToken) / reserveParent;
        return (optimalTokenAmount, parentTokenAmount);
    }

    // The accounted LP total is always `lastFeeLp + lastWithdrawableLp`: LP transferred to this
    // contract from outside is claimable by nobody, so it must not shift the fee baseline.
    function _updateSqrtKBaseline(TotalStake storage totals, address pair, address tokenAddress) private {
        PairSnapshot memory snapshot = _pairSnapshot(pair, tokenAddress);
        if (snapshot.pairTotalSupply == 0) {
            totals.lastSqrtKOfLp = 0;
            return;
        }
        uint256 totalLp = totals.lastFeeLp + totals.lastWithdrawableLp;
        totals.lastSqrtKOfLp = (Math.sqrt(snapshot.reserveToken * snapshot.reserveParent) * totalLp) / snapshot.pairTotalSupply;
    }

    function _withdrawLiquidity(address tokenAddress, address pair, uint256 round, uint256 liquidityShares)
        private
        returns (
            uint256 tokenAmount,
            uint256 parentTokenAmount,
            uint256 withdrawableLpBurned,
            uint256 withdrawableLpToMember
        )
    {
        TotalStake storage totals = _totalStake[tokenAddress];
        _settleFees(tokenAddress, pair, round);

        uint256 lpAmount = (liquidityShares * totals.lastWithdrawableLp) / totals.totalLiquidityShares;
        totals.lastWithdrawableLp -= lpAmount;
        if (totals.totalLiquidityShares != 0) {
            uint256 liquidityPrincipal = _totalLiquidityTokenAmount[tokenAddress];
            // forge-lint: disable-next-line(divide-before-multiply)
            _totalLiquidityTokenAmount[tokenAddress] =
                liquidityPrincipal - (liquidityShares * liquidityPrincipal) / totals.totalLiquidityShares;
        }
        totals.totalLiquidityShares -= liquidityShares;

        if (lpAmount > 0) {
            PairSnapshot memory snapshot = _pairSnapshot(pair, tokenAddress);
            if (_canBurn(lpAmount, snapshot)) {
                withdrawableLpBurned = lpAmount;
                _push(pair, pair, lpAmount);
                (tokenAmount, parentTokenAmount) = _burnLp(IUniswapV2Pair(pair), tokenAddress, msg.sender);
            } else {
                withdrawableLpToMember = lpAmount;
                _push(pair, msg.sender, lpAmount);
            }
        }

        _updateSqrtKBaseline(totals, pair, tokenAddress);
    }

    function _burnLp(IUniswapV2Pair pairContract, address tokenAddress, address to)
        private
        returns (uint256 tokenAmount, uint256 parentTokenAmount)
    {
        // forge-lint: disable-next-line(reentrancy-no-eth)
        (uint256 amount0, uint256 amount1) = pairContract.burn(to);
        if (tokenAddress == pairContract.token0()) {
            return (amount0, amount1);
        }
        return (amount1, amount0);
    }

    function _settleFees(address tokenAddress, address pair, uint256 round) private {
        TotalStake storage totals = _totalStake[tokenAddress];

        PairSnapshot memory snapshot = _pairSnapshot(pair, tokenAddress);
        _applyReclassification(tokenAddress, round, totals, snapshot);
        uint256 feeLp = totals.lastFeeLp;

        uint256 settlementUnit = Math.mulDiv(snapshot.pairTotalSupply, FEE_SETTLEMENT_RATIO, PRECISION);
        if (feeLp < settlementUnit) {
            return;
        }
        if (_lastSettlePhase[tokenAddress] == round) {
            return;
        }
        if (!_canBurn(settlementUnit, snapshot)) {
            return;
        }

        _realizeFees(tokenAddress, pair, settlementUnit, round);
    }

    // `pair.burn` reverts when either side of the proportional payout floors to zero, so a unit too
    // small to move both reserves is skipped instead of failing the settlement. `lp * reserve >=
    // totalSupply` is the exact integer form of `lp * reserve / totalSupply > 0`.
    function _canBurn(uint256 lpAmount, PairSnapshot memory snapshot) private pure returns (bool) {
        return lpAmount * snapshot.reserveToken >= snapshot.pairTotalSupply
            && lpAmount * snapshot.reserveParent >= snapshot.pairTotalSupply;
    }

    function _realizeFees(address tokenAddress, address pair, uint256 processedFeeLp, uint256 round) private {
        if (processedFeeLp == 0) {
            return;
        }
        TotalStake storage totals = _totalStake[tokenAddress];
        IUniswapV2Pair pairContract = IUniswapV2Pair(pair);
        _lastSettlePhase[tokenAddress] = round;

        _push(pair, pair, processedFeeLp);
        (uint256 tokenBurned, uint256 parentTokenBurned) = _burnLp(pairContract, tokenAddress, address(this));

        _totalParentTokenBurned[tokenAddress] += parentTokenBurned;

        uint256 totalTokenBurned = tokenBurned;
        if (parentTokenBurned > 0) {
            totalTokenBurned += _swapParentTokenForToken(tokenAddress, parentTokenBurned);
        }
        if (totalTokenBurned > 0) {
            // forge-lint: disable-next-line(reentrancy-no-eth)
            ILOVE20Token(tokenAddress).burn(totalTokenBurned);
        }
        _totalBurnedToken[tokenAddress] += totalTokenBurned;

        totals.lastFeeLp -= processedFeeLp;
        _updateSqrtKBaseline(totals, pair, tokenAddress);

        uint256 burnedTokenTotal = _totalBurnedToken[tokenAddress];
        uint256 parentTokenBurnedTotal = _totalParentTokenBurned[tokenAddress];

        // forge-lint: disable-next-item(reentrancy-events)
        emit FeesSettled({
            tokenAddress: tokenAddress,
            round: round,
            feeLpBurned: processedFeeLp,
            tokenBurned: totalTokenBurned,
            parentTokenBurned: parentTokenBurned,
            totalBurnedToken: burnedTokenTotal,
            totalParentTokenBurned: parentTokenBurnedTotal,
            totalFeeLp: totals.lastFeeLp
        });
    }

    function _swapParentTokenForToken(address tokenAddress, uint256 parentTokenAmount)
        private
        returns (uint256 tokenAmountOut)
    {
        address parentTokenAddress = ILOVE20Token(tokenAddress).PARENT_TOKEN_ADDRESS();
        address[] memory path = new address[](2);
        path[0] = parentTokenAddress;
        path[1] = tokenAddress;

        uint256[] memory amounts = IUniswapV2Router02(ROUTER_ADDRESS).getAmountsOut(parentTokenAmount, path);
        uint256 amountOutMin = amounts[amounts.length - 1];

        // forge-lint: disable-next-line(reentrancy-no-eth)
        IERC20(parentTokenAddress).forceApprove(ROUTER_ADDRESS, parentTokenAmount);
        // forge-lint: disable-next-item(reentrancy-no-eth)
        amounts = IUniswapV2Router02(ROUTER_ADDRESS).swapExactTokensForTokens(
            parentTokenAmount, amountOutMin, path, address(this), block.timestamp
        );
        tokenAmountOut = amounts[amounts.length - 1];
    }

    function _govVotesOf(MemberStake storage member) private view returns (uint256) {
        return member.liquidityShares * member.promisedWaitingPhases;
    }
}
