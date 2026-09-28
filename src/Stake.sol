// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Math} from "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {RoundHistoryUint256} from "../lib/libs/src/RoundHistoryUint256.sol";
import {Pagination} from "../lib/libs/src/Pagination.sol";
import {IPhase} from "./interfaces/IPhase.sol";
import {ILaunch} from "./interfaces/ILaunch.sol";
import {ISubmit} from "./interfaces/ISubmit.sol";
import {ILOVE20Token} from "./interfaces/ILOVE20Token.sol";
import {IMemberNFT} from "./interfaces/IMemberNFT.sol";
import {IUniswapV2Pair} from "./interfaces/UniswapV2/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "./interfaces/UniswapV2/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "./interfaces/UniswapV2/IUniswapV2Router02.sol";
import {IVote} from "./interfaces/IVote.sol";
import {IStake, MemberStake, GlobalStake} from "./interfaces/IStake.sol";

// The swap amounts actually deposited and the share price basis of this add have to travel together from
// `_addLiquidity` to `_creditLiquidity`; packing them into one memory struct keeps the two functions
// below the 16-slot limit instead of returning four separate values.
struct AddedLiquidity {
    uint256 tokenAmountDesired;
    uint256 parentTokenAmountDesired;
    uint256 tokenAmount;
    uint256 parentTokenAmount;
    uint256 lpMinted;
    uint256 withdrawableLpBefore;
}

contract Stake is IStake {
    using RoundHistoryUint256 for RoundHistoryUint256.History;
    using Pagination for uint256[];

    uint256 private constant SLIPPAGE_PRECISION = 1e18;

    bool public initialized;
    address public phaseAddress;
    address public memberNFTAddress;
    address public voteAddress;
    address public submitAddress;
    address public launchAddress;
    address public routerAddress;
    address public pairFactoryAddress;
    uint256 public PROMISED_WAITING_PHASES_MIN;
    uint256 public PROMISED_WAITING_PHASES_MAX;
    uint256 public MAX_WITHDRAWABLE_TO_FEE_RATIO;

    mapping(address => address) internal _pairAddress;
    mapping(address => GlobalStake) internal _globalStake;
    mapping(address => mapping(uint256 => MemberStake)) internal _memberStake;
    mapping(address => uint256) internal _globalGovVotes;
    mapping(address => uint256) internal _totalBurnedToken;
    mapping(address => uint256) internal _totalParentTokenBurned;
    mapping(address => RoundHistoryUint256.History) internal _globalBoostHistory;
    mapping(address => mapping(uint256 => RoundHistoryUint256.History)) internal _boostHistoryByMember;
    // tokenAddress => phase of the last realised settlement; one settlement per community per phase
    mapping(address => uint256) internal _lastSettlePhase;

    function init(
        address phaseAddress_,
        address memberNFTAddress_,
        address voteAddress_,
        address submitAddress_,
        address launchAddress_,
        address routerAddress_,
        address pairFactoryAddress_,
        uint256 promisedWaitingPhasesMin,
        uint256 promisedWaitingPhasesMax,
        uint256 maxWithdrawableToFeeRatio
    ) external {
        if (initialized) revert AlreadyInitialized();
        if (
            phaseAddress_ == address(0) ||
            memberNFTAddress_ == address(0) ||
            voteAddress_ == address(0) ||
            submitAddress_ == address(0) ||
            launchAddress_ == address(0) ||
            routerAddress_ == address(0) ||
            pairFactoryAddress_ == address(0)
        ) revert InvalidAddress();
        if (promisedWaitingPhasesMin == 0) revert ZeroAmount("promisedWaitingPhasesMin");
        if (maxWithdrawableToFeeRatio == 0) revert ZeroAmount("maxWithdrawableToFeeRatio");
        if (promisedWaitingPhasesMin > promisedWaitingPhasesMax) revert InvalidAmount();

        initialized = true;
        phaseAddress = phaseAddress_;
        memberNFTAddress = memberNFTAddress_;
        voteAddress = voteAddress_;
        submitAddress = submitAddress_;
        launchAddress = launchAddress_;
        routerAddress = routerAddress_;
        pairFactoryAddress = pairFactoryAddress_;
        PROMISED_WAITING_PHASES_MIN = promisedWaitingPhasesMin;
        PROMISED_WAITING_PHASES_MAX = promisedWaitingPhasesMax;
        MAX_WITHDRAWABLE_TO_FEE_RATIO = maxWithdrawableToFeeRatio;
    }

    function settleFees(address tokenAddress) external {
        _requireToken(tokenAddress);
        _settleFees(tokenAddress, _pairFor(tokenAddress));
    }

    function stakeLiquidity(
        address tokenAddress,
        uint256 tokenAmount,
        uint256 parentTokenAmount,
        uint256 slippage,
        uint256 promisedWaitingPhases,
        uint256 memberId
    ) external returns (uint256 govVotesAdded, uint256 liquiditySharesAdded) {
        if (tokenAmount == 0 || parentTokenAmount == 0) revert StakeAmountMustBeSet();
        _checkPromisedWaitingPhases(promisedWaitingPhases);
        _requireToken(tokenAddress);
        address pair = _pairFor(tokenAddress);
        uint256 round = _requireActiveRound();
        _requireMemberOwner(memberId);

        MemberStake storage member = _memberStake[tokenAddress][memberId];
        if (member.unlockRequestPhase != 0) revert UnstakeAlreadyRequested();
        if (promisedWaitingPhases < member.promisedWaitingPhases) {
            revert PromisedWaitingPhasesMustBeGreaterOrEqualThanBefore();
        }

        AddedLiquidity memory added = _addLiquidity(tokenAddress, pair, tokenAmount, parentTokenAmount, slippage);
        return _creditLiquidity(tokenAddress, pair, round, memberId, promisedWaitingPhases, added);
    }

    function stakeBoost(address tokenAddress, uint256 boostAmount, uint256 promisedWaitingPhases, uint256 memberId)
        external
        returns (uint256 govVotesAdded)
    {
        if (boostAmount == 0) revert StakeAmountMustBeSet();
        _checkPromisedWaitingPhases(promisedWaitingPhases);
        _requireToken(tokenAddress);
        _requireMemberOwner(memberId);

        MemberStake storage member = _memberStake[tokenAddress][memberId];
        if (member.unlockRequestPhase != 0) revert UnstakeAlreadyRequested();
        if (member.liquidityShares == 0) revert NoStakedLiquidity();
        if (promisedWaitingPhases < member.promisedWaitingPhases) {
            revert PromisedWaitingPhasesMustBeGreaterOrEqualThanBefore();
        }

        uint256 round = _currentRound();
        // No reentrancy guard: the entry validates first and the boost tokens are pulled before any
        // accounting changes, so a reentrant call can only observe the state this call already settled.
        _pull(tokenAddress, msg.sender, boostAmount);

        GlobalStake storage global = _globalStake[tokenAddress];
        member.boostShares += boostAmount;
        global.totalBoostShares += boostAmount;

        if (promisedWaitingPhases > member.promisedWaitingPhases) {
            govVotesAdded = member.liquidityShares * (promisedWaitingPhases - member.promisedWaitingPhases);
            member.promisedWaitingPhases = promisedWaitingPhases;
            _globalGovVotes[tokenAddress] += govVotesAdded;
        }

        _boostHistoryByMember[tokenAddress][memberId].increase(round, boostAmount);
        _globalBoostHistory[tokenAddress].increase(round, boostAmount);

        // The event reports the boost balance after the tokens arrived, and any failure reverts atomically.
        // forge-lint: disable-next-item(reentrancy-events)
        emit StakeBoost({
            tokenAddress: tokenAddress,
            round: round,
            memberId: memberId,
            boostAmount: boostAmount,
            promisedWaitingPhases: promisedWaitingPhases,
            govVotesAdded: govVotesAdded,
            govVotes: member.liquidityShares * member.promisedWaitingPhases,
            boostSharesAdded: boostAmount,
            boostShares: member.boostShares
        });
    }

    function unstake(address tokenAddress, uint256 memberId) external {
        _requireToken(tokenAddress);
        _requireMemberOwner(memberId);

        MemberStake storage member = _memberStake[tokenAddress][memberId];
        if (member.unlockRequestPhase != 0) revert UnstakeAlreadyRequested();
        if (member.liquidityShares == 0) revert NoStakedLiquidity();

        uint256 round = _currentRound();
        uint256 govVotes = member.liquidityShares * member.promisedWaitingPhases;
        uint256 boostShares = member.boostShares;

        member.unlockRequestPhase = round;
        _globalGovVotes[tokenAddress] -= govVotes;

        // The boost leaves the community history as soon as the unlock is requested, keeping the old
        // `LOVE20Stake` behaviour; the withdrawal must not subtract it a second time.
        if (boostShares > 0) {
            _boostHistoryByMember[tokenAddress][memberId].decrease(round, boostShares);
            _globalBoostHistory[tokenAddress].decrease(round, boostShares);
        }

        emit Unstake({
            tokenAddress: tokenAddress,
            round: round,
            memberId: memberId,
            promisedWaitingPhases: member.promisedWaitingPhases,
            govVotes: govVotes,
            liquidityShares: member.liquidityShares,
            boostShares: member.boostShares
        });
    }

    function withdraw(address tokenAddress, uint256 memberId) external {
        _requireToken(tokenAddress);
        address pair = _pairFor(tokenAddress);
        _requireMemberOwner(memberId);

        MemberStake storage member = _memberStake[tokenAddress][memberId];
        if (member.unlockRequestPhase == 0) revert UnstakeNotRequested();
        if (member.liquidityShares == 0) revert NoStakedLiquidity();

        uint256 round = _currentRound();
        uint256 promisedWaitingPhases = member.promisedWaitingPhases;
        uint256 liquidityShares = member.liquidityShares;
        uint256 boostShares = member.boostShares;
        // The promised waiting period is counted in whole phases beyond the request phase, matching the
        // old `LOVE20Stake.withdraw`: phase P after the request is still too early.
        if (round <= member.unlockRequestPhase + promisedWaitingPhases) revert NotEnoughWaitingPhases();

        (uint256 tokenAmountForLiquidity, uint256 parentTokenAmountForLiquidity) =
            _withdrawLiquidity(tokenAddress, pair, liquidityShares);

        // Only the asset and the community share total move here: the boost history was already reduced
        // when the unlock was requested.
        if (boostShares > 0) {
            _push(tokenAddress, msg.sender, boostShares);
            _globalStake[tokenAddress].totalBoostShares -= boostShares;
        }

        delete _memberStake[tokenAddress][memberId];

        // The event carries the amounts the pair returned, so it follows the burn; failures revert atomically.
        // forge-lint: disable-next-item(reentrancy-events)
        emit Withdraw({
            tokenAddress: tokenAddress,
            round: round,
            memberId: memberId,
            promisedWaitingPhases: promisedWaitingPhases,
            liquidityShares: liquidityShares,
            tokenAmountForLiquidity: tokenAmountForLiquidity,
            parentTokenAmountForLiquidity: parentTokenAmountForLiquidity,
            boostShares: boostShares
        });
    }

    function mergeStake(address tokenAddress, uint256 sourceMemberId, uint256 targetMemberId) external {
        if (sourceMemberId == targetMemberId) revert SourceAndTargetMustBeDifferent();
        _requireToken(tokenAddress);
        if (sourceMemberId == 0 || targetMemberId == 0) revert InvalidMemberId();
        IMemberNFT(memberNFTAddress).ownerOf(targetMemberId);
        if (IMemberNFT(memberNFTAddress).ownerOf(sourceMemberId) != msg.sender) revert NotMemberOwner(sourceMemberId);

        MemberStake storage source = _memberStake[tokenAddress][sourceMemberId];
        MemberStake storage target = _memberStake[tokenAddress][targetMemberId];
        if (source.unlockRequestPhase != 0 || target.unlockRequestPhase != 0) revert UnstakeAlreadyRequested();
        if (source.liquidityShares == 0) revert NoStakedLiquidity();

        uint256 round = _currentRound();
        if (
            IVote(voteAddress).votesNumByMemberId(tokenAddress, round, sourceMemberId) != 0
                || ISubmit(submitAddress).proposalIdBySubmitter(tokenAddress, round, sourceMemberId) != 0
        ) {
            revert SourceHasUsedStakeRightsInCurrentRound();
        }

        (uint256 liquiditySharesMerged, uint256 boostSharesMerged) =
            _mergeIntoTarget(tokenAddress, sourceMemberId, targetMemberId);

        if (boostSharesMerged > 0) {
            _moveBoostHistory(tokenAddress, sourceMemberId, targetMemberId, boostSharesMerged, round);
        }

        emit StakeMerged({
            tokenAddress: tokenAddress,
            round: round,
            sourceMemberId: sourceMemberId,
            targetMemberId: targetMemberId,
            liquiditySharesMerged: liquiditySharesMerged,
            boostSharesMerged: boostSharesMerged
        });
    }

    function pairAddress(address tokenAddress) external view returns (address) {
        return _pairAddress[tokenAddress];
    }

    function totalBurnedToken(address tokenAddress) external view returns (uint256) {
        return _totalBurnedToken[tokenAddress];
    }

    function totalParentTokenBurned(address tokenAddress) external view returns (uint256) {
        return _totalParentTokenBurned[tokenAddress];
    }

    function globalGovVotes(address tokenAddress) external view returns (uint256) {
        return _globalGovVotes[tokenAddress];
    }

    function stakeData(address tokenAddress, uint256 memberId)
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

        GlobalStake storage global = _globalStake[tokenAddress];
        address pair = _pairAddress[tokenAddress];
        if (pair != address(0) && global.totalLiquidityShares != 0) {
            (uint256 reserveToken, uint256 reserveParent, uint256 pairTotalSupply) = _reserves(pair, tokenAddress);
            (, uint256 withdrawableLp, ) = _reclassify(global, reserveToken, reserveParent, pairTotalSupply);
            uint256 lpAmount = (liquidityShares * withdrawableLp) / global.totalLiquidityShares;
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

    function validGovVotes(address tokenAddress, uint256 memberId) external view returns (uint256) {
        MemberStake storage member = _memberStake[tokenAddress][memberId];
        if (member.unlockRequestPhase != 0) return 0;
        return member.liquidityShares * member.promisedWaitingPhases;
    }

    function globalStakeData(address tokenAddress)
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
        GlobalStake storage global = _globalStake[tokenAddress];
        totalLiquidityShares = global.totalLiquidityShares;
        totalLp = global.totalLp;
        totalBoostShares = global.totalBoostShares;

        address pair = _pairAddress[tokenAddress];
        if (pair == address(0)) return (totalLiquidityShares, totalLp, 0, 0, totalBoostShares, 0, 0);

        (uint256 reserveToken, uint256 reserveParent, uint256 pairTotalSupply) = _reserves(pair, tokenAddress);
        (feeLp, withdrawableLp, ) = _reclassify(global, reserveToken, reserveParent, pairTotalSupply);
        if (pairTotalSupply != 0) {
            tokenAmountForLiquidity = (withdrawableLp * reserveToken) / pairTotalSupply;
            parentTokenAmountForLiquidity = (withdrawableLp * reserveParent) / pairTotalSupply;
        }
    }

    /// @dev Returns a boolean for any token address, like `stakeData`: an unregistered community simply has
    ///      no withdrawal to report, so callers get `false` instead of a revert.
    function canWithdraw(address tokenAddress, uint256 memberId) external view returns (bool) {
        MemberStake storage member = _memberStake[tokenAddress][memberId];
        if (member.unlockRequestPhase == 0) return false;
        return _currentRound() > member.unlockRequestPhase + member.promisedWaitingPhases;
    }

    function cumulatedBoostShares(address tokenAddress, uint256 round, uint256 memberId)
        external
        view
        returns (uint256)
    {
        // A round that has not started has no record yet: reverting keeps the old behaviour instead of
        // reporting the latest record as if it belonged to a future round.
        if (round > _currentRound()) revert InvalidPhase(round);
        return _boostHistoryByMember[tokenAddress][memberId].value(round);
    }

    function globalBoostUpdatedRounds(address tokenAddress, uint256 offset, uint256 limit, bool reverse)
        external
        view
        returns (uint256[] memory rounds, uint256 totalCount)
    {
        return _globalBoostHistory[tokenAddress].index.keys.paginate(offset, limit, reverse);
    }

    function boostUpdatedRounds(address tokenAddress, uint256 memberId, uint256 offset, uint256 limit, bool reverse)
        external
        view
        returns (uint256[] memory rounds, uint256 totalCount)
    {
        return _boostHistoryByMember[tokenAddress][memberId].index.keys.paginate(offset, limit, reverse);
    }

    function _currentRound() private view returns (uint256) {
        return IPhase(phaseAddress).currentPhase();
    }

    function _requireActiveRound() private view returns (uint256 round) {
        round = _currentRound();
        if (round == 0) revert NotAllowedToStakeAtRoundZero();
    }

    function _checkPromisedWaitingPhases(uint256 promisedWaitingPhases) private view {
        if (promisedWaitingPhases < PROMISED_WAITING_PHASES_MIN || promisedWaitingPhases > PROMISED_WAITING_PHASES_MAX) {
            revert PromisedWaitingPhasesOutOfRange();
        }
    }

    function _requireMemberOwner(uint256 memberId) private view {
        if (memberId == 0) revert InvalidMemberId();
        if (IMemberNFT(memberNFTAddress).ownerOf(memberId) != msg.sender) revert NotMemberOwner(memberId);
    }

    function _requireToken(address tokenAddress) private view {
        if (!ILaunch(launchAddress).isLOVE20Token(tokenAddress)) revert InvalidTokenAddress();
    }

    /// @dev Every token Stake moves — LOVE20 tokens, WBNB and the pair's LP token — reverts instead of
    ///      returning false, so the boolean only has to be asserted, not converted into an own error.
    function _pull(address token, address from, uint256 amount) private {
        require(IERC20(token).transferFrom(from, address(this), amount));
    }

    function _push(address token, address to, uint256 amount) private {
        // No reentrancy guard: the caller validated and priced the position before this payout, and the
        // LP accounting is written from the amounts the pair returns, never from a state a reentered
        // call could observe half applied.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        require(IERC20(token).transfer(to, amount));
    }

    /// @dev Launch creates the pair of every token when it is launched, so the first stake only has to read
    ///      it from the factory and remember it. A community without a pair is not stakeable and is rejected
    ///      here instead of being created on the side.
    function _pairFor(address tokenAddress) private returns (address pair) {
        pair = _pairAddress[tokenAddress];
        if (pair == address(0)) {
            pair = IUniswapV2Factory(pairFactoryAddress).getPair(tokenAddress, ILOVE20Token(tokenAddress).parentTokenAddress());
            if (pair == address(0)) revert InvalidTokenAddress();
            _pairAddress[tokenAddress] = pair;
        }
    }

    /// @dev Moves the source stake into the target and re-prices the merged governance votes. The target
    ///      keeps its own waiting phases when it is not empty, so the merged liquidity can only raise the
    ///      vote count and the subtraction below cannot underflow.
    function _mergeIntoTarget(address tokenAddress, uint256 sourceMemberId, uint256 targetMemberId)
        private
        returns (uint256 liquiditySharesMerged, uint256 boostSharesMerged)
    {
        MemberStake storage source = _memberStake[tokenAddress][sourceMemberId];
        MemberStake storage target = _memberStake[tokenAddress][targetMemberId];
        bool targetIsEmpty = target.liquidityShares == 0 && target.boostShares == 0;

        if (!targetIsEmpty && target.promisedWaitingPhases < source.promisedWaitingPhases) {
            revert TargetPromisedWaitingPhasesTooShort();
        }

        liquiditySharesMerged = source.liquidityShares;
        boostSharesMerged = source.boostShares;
        uint256 promisedWaitingPhases = targetIsEmpty ? source.promisedWaitingPhases : target.promisedWaitingPhases;
        uint256 govVotesBefore = target.liquidityShares * target.promisedWaitingPhases;

        target.liquidityShares += liquiditySharesMerged;
        target.boostShares += boostSharesMerged;
        target.promisedWaitingPhases = promisedWaitingPhases;

        uint256 govVotesAdded = target.liquidityShares * promisedWaitingPhases - govVotesBefore;
        _globalGovVotes[tokenAddress] =
            _globalGovVotes[tokenAddress] - liquiditySharesMerged * source.promisedWaitingPhases + govVotesAdded;

        delete _memberStake[tokenAddress][sourceMemberId];
    }

    function _moveBoostHistory(address tokenAddress, uint256 sourceMemberId, uint256 targetMemberId, uint256 shares, uint256 round)
        private
    {
        _boostHistoryByMember[tokenAddress][sourceMemberId].decrease(round, shares);
        _boostHistoryByMember[tokenAddress][targetMemberId].increase(round, shares);
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
        GlobalStake storage global = _globalStake[tokenAddress];

        // Zero-priced basis keeps the old `LOVE20SLToken` branch: the whole basis was reclassified into
        // fees, so the deposit is worth its own LP amount instead of dividing by zero.
        liquiditySharesAdded = global.totalLiquidityShares == 0 || added.withdrawableLpBefore == 0
            ? added.lpMinted
            : (global.totalLiquidityShares * added.lpMinted) / added.withdrawableLpBefore;

        govVotesAdded = (member.liquidityShares + liquiditySharesAdded) * promisedWaitingPhases
            - member.liquidityShares * member.promisedWaitingPhases;

        member.liquidityShares += liquiditySharesAdded;
        member.promisedWaitingPhases = promisedWaitingPhases;
        global.totalLiquidityShares += liquiditySharesAdded;
        global.lastWithdrawableLp += added.lpMinted;
        _globalGovVotes[tokenAddress] += govVotesAdded;

        _updateSqrtKBaseline(global, pair, tokenAddress);

        // The event carries the amounts the pair minted against, so it follows the mint; failures revert atomically.
        // forge-lint: disable-next-item(reentrancy-events)
        emit StakeLiquidity({
            tokenAddress: tokenAddress,
            round: round,
            memberId: memberId,
            tokenAmountDesired: added.tokenAmountDesired,
            parentTokenAmountDesired: added.parentTokenAmountDesired,
            tokenAmount: added.tokenAmount,
            parentTokenAmount: added.parentTokenAmount,
            promisedWaitingPhases: promisedWaitingPhases,
            govVotesAdded: govVotesAdded,
            govVotes: member.liquidityShares * promisedWaitingPhases,
            liquiditySharesAdded: liquiditySharesAdded,
            liquidityShares: member.liquidityShares
        });
    }

    function _addLiquidity(
        address tokenAddress,
        address pair,
        uint256 tokenAmount,
        uint256 parentTokenAmount,
        uint256 slippage
    ) private returns (AddedLiquidity memory added) {
        GlobalStake storage global = _globalStake[tokenAddress];
        added.tokenAmountDesired = tokenAmount;
        added.parentTokenAmountDesired = parentTokenAmount;

        // Fee reclassification runs before the shares are priced, so the new deposit is priced against
        // the withdrawable basis that already excludes this round's fees.
        (uint256 reserveToken, uint256 reserveParent, uint256 pairTotalSupply) = _reserves(pair, tokenAddress);
        (global.lastFeeLp, global.lastWithdrawableLp, global.lastSqrtKOfLp) =
            _reclassify(global, reserveToken, reserveParent, pairTotalSupply);
        added.withdrawableLpBefore = global.lastWithdrawableLp;

        (added.tokenAmount, added.parentTokenAmount) =
            _optimalAmounts(tokenAmount, parentTokenAmount, reserveToken, reserveParent, slippage);

        address parentTokenAddress = ILOVE20Token(tokenAddress).parentTokenAddress();
        _pull(tokenAddress, msg.sender, added.tokenAmount);
        _pull(parentTokenAddress, msg.sender, added.parentTokenAmount);
        _push(tokenAddress, pair, added.tokenAmount);
        _push(parentTokenAddress, pair, added.parentTokenAmount);

        added.lpMinted = IUniswapV2Pair(pair).mint(address(this));
        if (added.lpMinted == 0) revert ZeroAmount("lpMinted");
    }

    function _reserves(address pair, address tokenAddress)
        private
        view
        returns (uint256 reserveToken, uint256 reserveParent, uint256 pairTotalSupply)
    {
        IUniswapV2Pair pairContract = IUniswapV2Pair(pair);
        // The pair's cached timestamp is not part of the LP accounting, only the two reserves are.
        // forge-lint: disable-next-line(unused-return)
        (uint112 reserve0, uint112 reserve1, ) = pairContract.getReserves();
        pairTotalSupply = pairContract.totalSupply();
        if (tokenAddress == pairContract.token0()) {
            (reserveToken, reserveParent) = (uint256(reserve0), uint256(reserve1));
        } else {
            (reserveToken, reserveParent) = (uint256(reserve1), uint256(reserve0));
        }
    }

    function _reclassify(GlobalStake storage global, uint256 reserveToken, uint256 reserveParent, uint256 pairTotalSupply)
        private
        view
        returns (uint256 feeLp, uint256 withdrawableLp, uint256 sqrtKOfLp)
    {
        uint256 lastFeeLp = global.lastFeeLp;
        uint256 lastWithdrawableLp = global.lastWithdrawableLp;
        uint256 lastSqrtKOfLp = global.lastSqrtKOfLp;

        // Without a baseline the ratio below would price the whole basis down to zero, so an unset baseline
        // skips reclassification instead of reclassifying everything into fees.
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
        if (deviation * SLIPPAGE_PRECISION > desiredAmount * slippage) revert SlippageExceeded(slippage, deviation);
    }

    /// @dev `totalLp` is owned here and always means the accounted amount: LP transferred to this contract
    ///      from outside is claimable by nobody, so it must not shift the fee baseline.
    function _updateSqrtKBaseline(GlobalStake storage global, address pair, address tokenAddress) private {
        (uint256 reserveToken, uint256 reserveParent, uint256 pairTotalSupply) = _reserves(pair, tokenAddress);
        global.totalLp = global.lastFeeLp + global.lastWithdrawableLp;
        if (pairTotalSupply == 0) {
            global.lastSqrtKOfLp = 0;
            return;
        }
        global.lastSqrtKOfLp = (Math.sqrt(reserveToken * reserveParent) * global.totalLp) / pairTotalSupply;
    }

    /// @dev Fees are settled first so the shares are redeemed against the withdrawable basis that already
    ///      excludes this round's fees; a failing settlement fails the whole withdrawal.
    function _withdrawLiquidity(address tokenAddress, address pair, uint256 liquidityShares)
        private
        returns (uint256 tokenAmount, uint256 parentTokenAmount)
    {
        GlobalStake storage global = _globalStake[tokenAddress];
        _settleFees(tokenAddress, pair);

        uint256 lpAmount = (liquidityShares * global.lastWithdrawableLp) / global.totalLiquidityShares;
        global.lastWithdrawableLp -= lpAmount;
        global.totalLiquidityShares -= liquidityShares;

        IUniswapV2Pair pairContract = IUniswapV2Pair(pair);
        _push(pair, pair, lpAmount);
        (tokenAmount, parentTokenAmount) = _burnLp(pairContract, tokenAddress, msg.sender);

        _updateSqrtKBaseline(global, pair, tokenAddress);
    }

    function _burnLp(IUniswapV2Pair pairContract, address tokenAddress, address to)
        private
        returns (uint256 tokenAmount, uint256 parentTokenAmount)
    {
        // No reentrancy guard: the shares were already priced and removed from the ledger, and the
        // withdrawn amounts come from this burn.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        (uint256 amount0, uint256 amount1) = pairContract.burn(to);
        if (tokenAddress == pairContract.token0()) {
            return (amount0, amount1);
        }
        return (amount1, amount0);
    }

    /// @dev Reclassification always runs, because every later pricing reads the withdrawable basis. The
    ///      swap-and-burn that realises the fee is limited to one settlement per community per phase.
    function _settleFees(address tokenAddress, address pair) private {
        GlobalStake storage global = _globalStake[tokenAddress];

        (uint256 reserveToken, uint256 reserveParent, uint256 pairTotalSupply) = _reserves(pair, tokenAddress);
        (uint256 feeLp, uint256 withdrawableLp, uint256 sqrtKOfLp) =
            _reclassify(global, reserveToken, reserveParent, pairTotalSupply);

        global.lastFeeLp = feeLp;
        global.lastWithdrawableLp = withdrawableLp;
        global.lastSqrtKOfLp = sqrtKOfLp;
        global.totalLp = feeLp + withdrawableLp;

        // The threshold doubles as the size of one settlement: a unit is the smallest fee worth burning,
        // so one settlement burns one unit and the rest stays pending for the next phase. That keeps a
        // single settlement's price move at `withdrawableLp / (MAX_WITHDRAWABLE_TO_FEE_RATIO * pairTotalSupply)`.
        uint256 settlementUnit = withdrawableLp / MAX_WITHDRAWABLE_TO_FEE_RATIO;
        if (feeLp < settlementUnit) {
            return;
        }
        if (_lastSettlePhase[tokenAddress] == _currentRound()) {
            return;
        }
        if (!_canBurn(settlementUnit, reserveToken, reserveParent, pairTotalSupply)) {
            return;
        }

        _realizeFees(tokenAddress, pair, settlementUnit);
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

    /// @dev Keeps the unprocessed fee as the pending basis, so the next phase settles the remainder.
    /// @dev The withdrawable basis is left as the caller reclassified it; only the fee side changes here.
    function _realizeFees(address tokenAddress, address pair, uint256 processedFeeLp) private {
        // A zero amount is reachable, not defensive padding: a pair that exists but has no liquidity has
        // `totalSupply == 0`, which makes `_canBurn` judge `0 >= 0` true and lets the settlement through
        // with a zero unit — a token launched but never staked is exactly that state. Burning zero would
        // divide by zero in the pair and turn a no-op settlement into a revert, which would also block
        // `withdraw`, because it settles before pricing the shares.
        if (processedFeeLp == 0) {
            return;
        }
        GlobalStake storage global = _globalStake[tokenAddress];
        IUniswapV2Pair pairContract = IUniswapV2Pair(pair);
        _lastSettlePhase[tokenAddress] = _currentRound();

        _push(pair, pair, processedFeeLp);
        (uint256 tokenBurned, uint256 parentTokenBurned) = _burnLp(pairContract, tokenAddress, address(this));

        _totalParentTokenBurned[tokenAddress] += parentTokenBurned;

        uint256 totalTokenBurned = tokenBurned;
        if (parentTokenBurned > 0) {
            totalTokenBurned += _swapParentTokenForToken(tokenAddress, parentTokenBurned);
        }
        if (totalTokenBurned > 0) {
            // No reentrancy guard: the fee LP left the ledger before this burn and the withdrawable basis
            // was already rewritten by the caller.
            // forge-lint: disable-next-line(reentrancy-no-eth)
            ILOVE20Token(tokenAddress).burn(totalTokenBurned);
        }
        _totalBurnedToken[tokenAddress] += totalTokenBurned;

        global.lastFeeLp -= processedFeeLp;
        _updateSqrtKBaseline(global, pair, tokenAddress);

        // The event carries the burned amounts, so it follows the burn and the swap; failures revert atomically.
        // forge-lint: disable-next-item(reentrancy-events)
        emit FeesSettled({
            tokenAddress: tokenAddress,
            round: _currentRound(),
            feeLp: processedFeeLp,
            tokenBurned: totalTokenBurned,
            parentTokenBurned: parentTokenBurned
        });
    }

    function _swapParentTokenForToken(address tokenAddress, uint256 parentTokenAmount)
        private
        returns (uint256 tokenAmountOut)
    {
        address parentTokenAddress = ILOVE20Token(tokenAddress).parentTokenAddress();
        address[] memory path = new address[](2);
        path[0] = parentTokenAddress;
        path[1] = tokenAddress;

        // the accepted minimum is derived from the reserves in this same transaction, never from the caller
        uint256[] memory amounts = IUniswapV2Router02(routerAddress).getAmountsOut(parentTokenAmount, path);
        uint256 amountOutMin = amounts[amounts.length - 1];

        // No reentrancy guard: the fee was already taken out of the ledger and the swap only converts the
        // parent token that is burned afterwards in the same transaction.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        require(IERC20(parentTokenAddress).approve(routerAddress, parentTokenAmount));
        // forge-lint: disable-next-item(reentrancy-no-eth)
        amounts = IUniswapV2Router02(routerAddress).swapExactTokensForTokens(
            parentTokenAmount, amountOutMin, path, address(this), block.timestamp
        );
        tokenAmountOut = amounts[amounts.length - 1];
    }
}
