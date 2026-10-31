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
    uint256 tokenAmountDesired;
    uint256 parentTokenAmountDesired;
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

contract Stake is IStake {
    using RoundHistoryUint256 for RoundHistoryUint256.History;
    using SafeERC20 for IERC20;

    uint256 private constant SLIPPAGE_PRECISION = 1e18;

    bool public initialized;
    address public PHASE_ADDRESS;
    address public MEMBER_NFT_ADDRESS;
    address public VOTE_ADDRESS;
    address public LAUNCH_ADDRESS;
    address public ROUTER_ADDRESS;
    address public PAIR_FACTORY_ADDRESS;
    uint256 public PROMISED_WAITING_PHASES_MIN;
    uint256 public PROMISED_WAITING_PHASES_MAX;
    uint256 public FEE_SETTLEMENT_RATIO;

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

    // forge-lint: disable-next-item(missing-zero-check)
    function init(
        address phaseAddress,
        address memberNFTAddress,
        address voteAddress,
        address launchAddress,
        address routerAddress,
        address pairFactoryAddress,
        uint256 promisedWaitingPhasesMin,
        uint256 promisedWaitingPhasesMax,
        uint256 feeSettlementRatio
    ) external {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        PHASE_ADDRESS = phaseAddress;
        MEMBER_NFT_ADDRESS = memberNFTAddress;
        VOTE_ADDRESS = voteAddress;
        LAUNCH_ADDRESS = launchAddress;
        ROUTER_ADDRESS = routerAddress;
        PAIR_FACTORY_ADDRESS = pairFactoryAddress;
        PROMISED_WAITING_PHASES_MIN = promisedWaitingPhasesMin;
        PROMISED_WAITING_PHASES_MAX = promisedWaitingPhasesMax;
        FEE_SETTLEMENT_RATIO = feeSettlementRatio;
    }

    function settleFees(address tokenAddress) external {
        _requireToken(tokenAddress);
        _settleFees(tokenAddress, _pairFor(tokenAddress));
    }

    modifier onlyMemberOwner(uint256 memberId) {
        if (IMemberNFT(MEMBER_NFT_ADDRESS).ownerOf(memberId) != msg.sender) revert NotMemberOwner(memberId);
        _;
    }

    function stakeLiquidity(
        address tokenAddress,
        uint256 tokenAmount,
        uint256 parentTokenAmount,
        uint256 slippage,
        uint256 promisedWaitingPhases,
        uint256 memberId
    ) external onlyMemberOwner(memberId) returns (uint256 govVotesAdded, uint256 liquiditySharesAdded) {
        if (tokenAmount == 0) revert ZeroTokenAmount();
        if (parentTokenAmount == 0) revert ZeroParentTokenAmount();
        _checkPromisedWaitingPhases(promisedWaitingPhases);
        _requireToken(tokenAddress);
        address pair = _pairFor(tokenAddress);
        uint256 round = _requireActiveRound();

        MemberStake storage member = _memberStake[tokenAddress][memberId];
        _requireNoUnstakeRequest(member, tokenAddress, memberId);
        if (promisedWaitingPhases < member.promisedWaitingPhases) {
            revert PromisedWaitingPhasesDecreased(promisedWaitingPhases, member.promisedWaitingPhases);
        }

        AddedLiquidity memory added = _addLiquidity(tokenAddress, pair, tokenAmount, parentTokenAmount, slippage);
        return _creditLiquidity(tokenAddress, pair, round, memberId, promisedWaitingPhases, added);
    }

    function stakeBoost(address tokenAddress, uint256 boostAmount, uint256 promisedWaitingPhases, uint256 memberId)
        external
        onlyMemberOwner(memberId)
        returns (uint256 govVotesAdded)
    {
        if (boostAmount == 0) revert ZeroBoostAmount();
        _checkPromisedWaitingPhases(promisedWaitingPhases);
        _requireToken(tokenAddress);

        MemberStake storage member = _memberStake[tokenAddress][memberId];
        _requireNoUnstakeRequest(member, tokenAddress, memberId);
        _requireStakedLiquidity(member, tokenAddress, memberId);
        if (promisedWaitingPhases < member.promisedWaitingPhases) {
            revert PromisedWaitingPhasesDecreased(promisedWaitingPhases, member.promisedWaitingPhases);
        }

        uint256 round = _currentRound();
        _pull(tokenAddress, msg.sender, boostAmount);

        TotalStake storage totals = _totalStake[tokenAddress];
        member.boostShares += boostAmount;
        totals.totalBoostShares += boostAmount;

        if (promisedWaitingPhases > member.promisedWaitingPhases) {
            govVotesAdded = member.liquidityShares * (promisedWaitingPhases - member.promisedWaitingPhases);
            member.promisedWaitingPhases = promisedWaitingPhases;
            _totalValidGovVotesAdded[tokenAddress].increase(round, govVotesAdded);
            _validGovVotesByMember[tokenAddress][memberId].increase(round, govVotesAdded);
        }

        _validBoostSharesByMember[tokenAddress][memberId].increase(round, boostAmount);
        _totalValidBoostSharesAdded[tokenAddress].increase(round, boostAmount);

        uint256 validBoostSharesTotal = _totalValidBoostSharesAt(tokenAddress, round);
        uint256 govVotesTotal = _totalValidGovVotesAt(tokenAddress, round);

        // forge-lint: disable-next-item(reentrancy-events)
        emit BoostStaked({
            tokenAddress: tokenAddress,
            round: round,
            memberId: memberId,
            boostAmount: boostAmount,
            promisedWaitingPhases: promisedWaitingPhases,
            govVotesAdded: govVotesAdded,
            govVotes: _govVotesOf(member),
            boostShares: member.boostShares,
            totalBoostShares: totals.totalBoostShares,
            totalValidBoostShares: validBoostSharesTotal,
            totalValidGovVotes: govVotesTotal
        });
    }

    function unstake(address tokenAddress, uint256 memberId) external onlyMemberOwner(memberId) {
        _requireToken(tokenAddress);

        MemberStake storage member = _memberStake[tokenAddress][memberId];
        _requireNoUnstakeRequest(member, tokenAddress, memberId);
        _requireStakedLiquidity(member, tokenAddress, memberId);

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
        _requireToken(tokenAddress);
        address pair = _pairFor(tokenAddress);

        MemberStake storage member = _memberStake[tokenAddress][memberId];
        if (member.unlockRequestPhase == 0) revert UnstakeNotRequested(tokenAddress, memberId);
        _requireStakedLiquidity(member, tokenAddress, memberId);

        uint256 round = _currentRound();
        uint256 promisedWaitingPhases = member.promisedWaitingPhases;
        uint256 liquidityShares = member.liquidityShares;
        uint256 boostShares = member.boostShares;
        if (round <= member.unlockRequestPhase + promisedWaitingPhases) {
            revert InsufficientWaitingPhases(round, member.unlockRequestPhase + promisedWaitingPhases);
        }

        (uint256 tokenAmountForLiquidity, uint256 parentTokenAmountForLiquidity, uint256 lpBurned, uint256 lpToMember) =
            _withdrawLiquidity(tokenAddress, pair, liquidityShares);

        // Only the asset and the community share total move here: the boost history was already reduced
        // when the unlock was requested.
        if (boostShares > 0) {
            _push(tokenAddress, msg.sender, boostShares);
            _totalStake[tokenAddress].totalBoostShares -= boostShares;
        }

        delete _memberStake[tokenAddress][memberId];

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
            lpBurned: lpBurned,
            lpToMember: lpToMember,
            totalLiquidityShares: totals.totalLiquidityShares,
            totalBoostShares: totals.totalBoostShares
        });
    }

    function mergeStake(address tokenAddress, uint256 sourceMemberId, uint256 targetMemberId)
        external
        onlyMemberOwner(sourceMemberId)
    {
        if (sourceMemberId == targetMemberId) {
            revert SourceAndTargetMemberIdsMustBeDifferent(sourceMemberId, targetMemberId);
        }
        _requireToken(tokenAddress);
        IMemberNFT(MEMBER_NFT_ADDRESS).ownerOf(targetMemberId);

        MemberStake storage source = _memberStake[tokenAddress][sourceMemberId];
        MemberStake storage target = _memberStake[tokenAddress][targetMemberId];
        _requireNoUnstakeRequest(source, tokenAddress, sourceMemberId);
        _requireNoUnstakeRequest(target, tokenAddress, targetMemberId);
        _requireStakedLiquidity(source, tokenAddress, sourceMemberId);

        uint256 round = _currentRound();
        if (_hasUsedStakeRights(tokenAddress, round, sourceMemberId)) {
            revert StakeRightsUsed(tokenAddress, round, sourceMemberId);
        }

        MergedStake memory merged = _mergeIntoTarget(tokenAddress, round, sourceMemberId, targetMemberId);

        if (merged.boostShares > 0) {
            _moveBoostHistory(tokenAddress, sourceMemberId, targetMemberId, merged.boostShares, round);
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
        _requireRoundStarted(round);
        return _validGovVotesByMember[tokenAddress][memberId].value(round);
    }

    function totalValidGovVotes(address tokenAddress, uint256 round) external view returns (uint256) {
        _requireRoundStarted(round);
        return _totalValidGovVotesAt(tokenAddress, round);
    }

    function totalValidGovVotesAdded(address tokenAddress, uint256 round) external view returns (uint256) {
        _requireRoundStarted(round);
        return _totalValidGovVotesAdded[tokenAddress].value(round);
    }

    function totalValidGovVotesRemoved(address tokenAddress, uint256 round) external view returns (uint256) {
        _requireRoundStarted(round);
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
            uint256 parentTokenAmountForLiquidity
        )
    {
        MemberStake storage member = _memberStake[tokenAddress][memberId];
        liquidityShares = member.liquidityShares;
        boostShares = member.boostShares;
        promisedWaitingPhases = member.promisedWaitingPhases;
        unlockRequestPhase = member.unlockRequestPhase;

        TotalStake storage totals = _totalStake[tokenAddress];
        address pair = _pairAddressByTokenAddress[tokenAddress];
        if (pair != address(0) && totals.totalLiquidityShares != 0) {
            (uint256 reserveToken, uint256 reserveParent, uint256 pairTotalSupply) = _reserves(pair, tokenAddress);
            (, uint256 withdrawableLp, ) = _reclassify(totals, reserveToken, reserveParent, pairTotalSupply);
            uint256 lpAmount = (liquidityShares * withdrawableLp) / totals.totalLiquidityShares;
            if (pairTotalSupply != 0) {
                // The share is converted in two steps on purpose: `lpAmount` is the value the spec defines
                // and folding both divisions into one expression would round a different quantity.
                // forge-lint: disable-next-line(divide-before-multiply)
                tokenAmountForLiquidity = (lpAmount * reserveToken) / pairTotalSupply;
                // forge-lint: disable-next-line(divide-before-multiply)
                parentTokenAmountForLiquidity = (lpAmount * reserveParent) / pairTotalSupply;
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
            uint256 parentTokenAmountForLiquidity
        )
    {
        TotalStake storage totals = _totalStake[tokenAddress];
        totalLiquidityShares = totals.totalLiquidityShares;
        totalLp = totals.lastFeeLp + totals.lastWithdrawableLp;
        totalBoostShares = totals.totalBoostShares;

        address pair = _pairAddressByTokenAddress[tokenAddress];
        if (pair == address(0)) return (totalLiquidityShares, totalLp, 0, 0, totalBoostShares, 0, 0);

        (uint256 reserveToken, uint256 reserveParent, uint256 pairTotalSupply) = _reserves(pair, tokenAddress);
        (feeLp, withdrawableLp, ) = _reclassify(totals, reserveToken, reserveParent, pairTotalSupply);
        if (pairTotalSupply != 0) {
            tokenAmountForLiquidity = (withdrawableLp * reserveToken) / pairTotalSupply;
            parentTokenAmountForLiquidity = (withdrawableLp * reserveParent) / pairTotalSupply;
        }
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
        _requireRoundStarted(round);
        return _validBoostSharesByMember[tokenAddress][memberId].value(round);
    }

    function totalValidBoostShares(address tokenAddress, uint256 round) external view returns (uint256) {
        _requireRoundStarted(round);
        return _totalValidBoostSharesAt(tokenAddress, round);
    }

    function totalValidBoostSharesAdded(address tokenAddress, uint256 round) external view returns (uint256) {
        _requireRoundStarted(round);
        return _totalValidBoostSharesAdded[tokenAddress].value(round);
    }

    function totalValidBoostSharesRemoved(address tokenAddress, uint256 round) external view returns (uint256) {
        _requireRoundStarted(round);
        return _totalValidBoostSharesRemoved[tokenAddress].value(round);
    }

    function _currentRound() private view returns (uint256) {
        return IPhase(PHASE_ADDRESS).currentPhase();
    }

    function _requireRoundStarted(uint256 round) private view {
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

    function _requireActiveRound() private view returns (uint256 round) {
        round = _currentRound();
        if (round == 0) revert NotAllowedToStakeAtRoundZero();
    }

    function _checkPromisedWaitingPhases(uint256 promisedWaitingPhases) private view {
        if (promisedWaitingPhases < PROMISED_WAITING_PHASES_MIN || promisedWaitingPhases > PROMISED_WAITING_PHASES_MAX) {
            revert InvalidPromisedWaitingPhases(
                promisedWaitingPhases, PROMISED_WAITING_PHASES_MIN, PROMISED_WAITING_PHASES_MAX
            );
        }
    }

    function _requireToken(address tokenAddress) private view {
        if (!ILaunch(LAUNCH_ADDRESS).isLOVE20Token(tokenAddress)) revert TokenNotRegistered(tokenAddress);
    }

    function _requireNoUnstakeRequest(
        MemberStake storage member,
        address tokenAddress,
        uint256 memberId
    ) private view {
        if (member.unlockRequestPhase != 0) revert UnstakeAlreadyRequested(tokenAddress, memberId);
    }

    function _requireStakedLiquidity(
        MemberStake storage member,
        address tokenAddress,
        uint256 memberId
    ) private view {
        if (member.liquidityShares == 0) revert NoStakedLiquidity(tokenAddress, memberId);
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
        uint256 round,
        uint256 memberId,
        uint256 promisedWaitingPhases,
        AddedLiquidity memory added
    ) private returns (uint256 govVotesAdded, uint256 liquiditySharesAdded) {
        MemberStake storage member = _memberStake[tokenAddress][memberId];
        TotalStake storage totals = _totalStake[tokenAddress];

        liquiditySharesAdded = totals.totalLiquidityShares == 0 || added.withdrawableLpBefore == 0
            ? added.lpMinted
            : (totals.totalLiquidityShares * added.lpMinted) / added.withdrawableLpBefore;

        govVotesAdded = (member.liquidityShares + liquiditySharesAdded) * promisedWaitingPhases
            - _govVotesOf(member);

        member.liquidityShares += liquiditySharesAdded;
        member.promisedWaitingPhases = promisedWaitingPhases;
        totals.totalLiquidityShares += liquiditySharesAdded;
        totals.lastWithdrawableLp += added.lpMinted;
        _totalValidGovVotesAdded[tokenAddress].increase(round, govVotesAdded);
        _validGovVotesByMember[tokenAddress][memberId].increase(round, govVotesAdded);

        _updateSqrtKBaseline(totals, pair, tokenAddress);

        uint256 govVotesTotal = _totalValidGovVotesAt(tokenAddress, round);

        // forge-lint: disable-next-item(reentrancy-events)
        emit LiquidityStaked({
            tokenAddress: tokenAddress,
            round: round,
            memberId: memberId,
            tokenAmountDesired: added.tokenAmountDesired,
            parentTokenAmountDesired: added.parentTokenAmountDesired,
            tokenAmount: added.tokenAmount,
            parentTokenAmount: added.parentTokenAmount,
            promisedWaitingPhases: promisedWaitingPhases,
            govVotesAdded: govVotesAdded,
            govVotes: _govVotesOf(member),
            liquiditySharesAdded: liquiditySharesAdded,
            liquidityShares: member.liquidityShares,
            totalLiquidityShares: totals.totalLiquidityShares,
            totalValidGovVotes: govVotesTotal
        });
    }

    function _addLiquidity(
        address tokenAddress,
        address pair,
        uint256 tokenAmount,
        uint256 parentTokenAmount,
        uint256 slippage
    ) private returns (AddedLiquidity memory added) {
        TotalStake storage totals = _totalStake[tokenAddress];
        added.tokenAmountDesired = tokenAmount;
        added.parentTokenAmountDesired = parentTokenAmount;

        (uint256 reserveToken, uint256 reserveParent, uint256 pairTotalSupply) = _reserves(pair, tokenAddress);
        (totals.lastFeeLp, totals.lastWithdrawableLp, totals.lastSqrtKOfLp) =
            _reclassify(totals, reserveToken, reserveParent, pairTotalSupply);
        added.withdrawableLpBefore = totals.lastWithdrawableLp;

        (added.tokenAmount, added.parentTokenAmount) =
            _optimalAmounts(tokenAmount, parentTokenAmount, reserveToken, reserveParent, slippage);

        address parentTokenAddress = ILOVE20Token(tokenAddress).PARENT_TOKEN_ADDRESS();
        _pull(tokenAddress, msg.sender, added.tokenAmount);
        _pull(parentTokenAddress, msg.sender, added.parentTokenAmount);
        _push(tokenAddress, pair, added.tokenAmount);
        _push(parentTokenAddress, pair, added.parentTokenAmount);

        added.lpMinted = IUniswapV2Pair(pair).mint(address(this));
        if (added.lpMinted == 0) revert ZeroLiquidityMinted();
    }

    function _reserves(address pair, address tokenAddress)
        private
        view
        returns (uint256 reserveToken, uint256 reserveParent, uint256 pairTotalSupply)
    {
        IUniswapV2Pair pairContract = IUniswapV2Pair(pair);
        // forge-lint: disable-next-line(unused-return)
        (uint112 reserve0, uint112 reserve1, ) = pairContract.getReserves();
        pairTotalSupply = pairContract.totalSupply();
        if (tokenAddress == pairContract.token0()) {
            (reserveToken, reserveParent) = (uint256(reserve0), uint256(reserve1));
        } else {
            (reserveToken, reserveParent) = (uint256(reserve1), uint256(reserve0));
        }
    }

    function _reclassify(TotalStake storage totals, uint256 reserveToken, uint256 reserveParent, uint256 pairTotalSupply)
        private
        view
        returns (uint256 feeLp, uint256 withdrawableLp, uint256 sqrtKOfLp)
    {
        uint256 lastFeeLp = totals.lastFeeLp;
        uint256 lastWithdrawableLp = totals.lastWithdrawableLp;
        uint256 lastSqrtKOfLp = totals.lastSqrtKOfLp;

        if (lastFeeLp + lastWithdrawableLp == 0 || lastSqrtKOfLp == 0 || pairTotalSupply == 0) {
            return (lastFeeLp, lastWithdrawableLp, lastSqrtKOfLp);
        }

        uint256 currentSqrtKOfLp = (Math.sqrt(reserveToken * reserveParent) * (lastFeeLp + lastWithdrawableLp)) / pairTotalSupply;
        if (currentSqrtKOfLp == 0 || currentSqrtKOfLp <= lastSqrtKOfLp) {
            return (lastFeeLp, lastWithdrawableLp, lastSqrtKOfLp);
        }

        withdrawableLp = (lastWithdrawableLp * lastSqrtKOfLp) / currentSqrtKOfLp;
        feeLp = lastFeeLp + lastWithdrawableLp - withdrawableLp;
        sqrtKOfLp = currentSqrtKOfLp;
    }

    function _optimalAmounts(
        uint256 tokenAmount,
        uint256 parentTokenAmount,
        uint256 reserveToken,
        uint256 reserveParent,
        uint256 slippage
    ) private pure returns (uint256 optimalTokenAmount, uint256 optimalParentTokenAmount) {
        if (reserveToken == 0 || reserveParent == 0) {
            return (tokenAmount, parentTokenAmount);
        }

        optimalParentTokenAmount = (tokenAmount * reserveParent) / reserveToken;
        if (optimalParentTokenAmount <= parentTokenAmount) {
            _checkSlippage(parentTokenAmount - optimalParentTokenAmount, parentTokenAmount, slippage);
            return (tokenAmount, optimalParentTokenAmount);
        }

        optimalTokenAmount = (parentTokenAmount * reserveToken) / reserveParent;
        _checkSlippage(tokenAmount - optimalTokenAmount, tokenAmount, slippage);
        return (optimalTokenAmount, parentTokenAmount);
    }

    function _checkSlippage(uint256 deviation, uint256 desiredAmount, uint256 slippage) private pure {
        (uint256 productHigh, uint256 productLow) = Math.mul512(desiredAmount, slippage);
        (uint256 deviationHigh, uint256 deviationLow) = Math.mul512(deviation, SLIPPAGE_PRECISION);
        if (deviationHigh > productHigh || (deviationHigh == productHigh && deviationLow > productLow)) {
            uint256 maxDeviation = Math.mulDiv(desiredAmount, slippage, SLIPPAGE_PRECISION);
            revert SlippageExceeded(deviation, maxDeviation);
        }
    }

    /// @dev The accounted LP total is always `lastFeeLp + lastWithdrawableLp`: LP transferred to this
    ///      contract from outside is claimable by nobody, so it must not shift the fee baseline.
    function _updateSqrtKBaseline(TotalStake storage totals, address pair, address tokenAddress) private {
        (uint256 reserveToken, uint256 reserveParent, uint256 pairTotalSupply) = _reserves(pair, tokenAddress);
        if (pairTotalSupply == 0) {
            totals.lastSqrtKOfLp = 0;
            return;
        }
        uint256 totalLp = totals.lastFeeLp + totals.lastWithdrawableLp;
        totals.lastSqrtKOfLp = (Math.sqrt(reserveToken * reserveParent) * totalLp) / pairTotalSupply;
    }

    function _withdrawLiquidity(address tokenAddress, address pair, uint256 liquidityShares)
        private
        returns (uint256 tokenAmount, uint256 parentTokenAmount, uint256 lpBurned, uint256 lpToMember)
    {
        TotalStake storage totals = _totalStake[tokenAddress];
        _settleFees(tokenAddress, pair);

        uint256 lpAmount = (liquidityShares * totals.lastWithdrawableLp) / totals.totalLiquidityShares;
        totals.lastWithdrawableLp -= lpAmount;
        totals.totalLiquidityShares -= liquidityShares;

        if (lpAmount > 0) {
            (uint256 reserveToken, uint256 reserveParent, uint256 pairTotalSupply) = _reserves(pair, tokenAddress);
            if (_canBurn(lpAmount, reserveToken, reserveParent, pairTotalSupply)) {
                lpBurned = lpAmount;
                _push(pair, pair, lpAmount);
                (tokenAmount, parentTokenAmount) = _burnLp(IUniswapV2Pair(pair), tokenAddress, msg.sender);
            } else {
                lpToMember = lpAmount;
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

    function _settleFees(address tokenAddress, address pair) private {
        TotalStake storage totals = _totalStake[tokenAddress];

        (uint256 reserveToken, uint256 reserveParent, uint256 pairTotalSupply) = _reserves(pair, tokenAddress);
        (uint256 feeLp, uint256 withdrawableLp, uint256 sqrtKOfLp) =
            _reclassify(totals, reserveToken, reserveParent, pairTotalSupply);

        totals.lastFeeLp = feeLp;
        totals.lastWithdrawableLp = withdrawableLp;
        totals.lastSqrtKOfLp = sqrtKOfLp;

        uint256 settlementUnit = Math.mulDiv(withdrawableLp, FEE_SETTLEMENT_RATIO, 1e18);
        if (feeLp < settlementUnit) {
            return;
        }
        uint256 round = _currentRound();
        if (_lastSettlePhase[tokenAddress] == round) {
            return;
        }
        if (!_canBurn(settlementUnit, reserveToken, reserveParent, pairTotalSupply)) {
            return;
        }

        _realizeFees(tokenAddress, pair, settlementUnit, round);
    }

    /// @dev `pair.burn` reverts when either side of the proportional payout floors to zero, so a unit too
    ///      small to move both reserves is skipped instead of failing the settlement. `lp * reserve >=
    ///      totalSupply` is the exact integer form of `lp * reserve / totalSupply > 0`.
    function _canBurn(uint256 lpAmount, uint256 reserveToken, uint256 reserveParent, uint256 pairTotalSupply)
        private
        pure
        returns (bool)
    {
        return lpAmount * reserveToken >= pairTotalSupply && lpAmount * reserveParent >= pairTotalSupply;
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
            feeLp: processedFeeLp,
            tokenBurned: totalTokenBurned,
            parentTokenBurned: parentTokenBurned,
            totalBurnedToken: burnedTokenTotal,
            totalParentTokenBurned: parentTokenBurnedTotal
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
