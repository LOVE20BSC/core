// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {ArrayUtils} from "./lib/ArrayUtils.sol";
import {Phase} from "./Phase.sol";
import {ILOVE20Token} from "./interfaces/ILOVE20Token.sol";
import {ILOVE20STToken} from "./interfaces/ILOVE20STToken.sol";
import {ILOVE20SLToken} from "./interfaces/ILOVE20SLToken.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ILOVE20Stake, AccountStakeStatus} from "./interfaces/ILOVE20Stake.sol";

contract LOVE20Stake is Phase, ILOVE20Stake {
    using ArrayUtils for uint256[];

    bool public initialized;
    uint256 public PROMISED_WAITING_PHASES_MIN;
    uint256 public PROMISED_WAITING_PHASES_MAX;

    // tokenAddress => govVotes
    mapping(address => uint256) public govVotesNum;
    // tokenAddress => initialStakeRound
    mapping(address => uint256) public initialStakeRound;

    // tokenAddress => account => StakeInfo
    mapping(address => mapping(address => AccountStakeStatus))
        internal _accountStakeStatus;

    // tokenAddress => round => cumulatedTokenAmount
    mapping(address => mapping(uint256 => uint256))
        internal _cumulatedTokenAmount;
    // tokenAddress => round => account => cumulatedTokenAmount
    mapping(address => mapping(uint256 => mapping(address => uint256)))
        internal _cumulatedTokenAmountByAccount;

    // tokenAddress => round[]
    mapping(address => uint256[]) internal _stakeTokenUpdatedRounds;
    // tokenAddress => account => round[]
    mapping(address => mapping(address => uint256[]))
        internal _stakeTokenUpdatedRoundsByAccount;

    constructor(
        uint256 originBlocks,
        uint256 phaseBlocks
    ) Phase(originBlocks, phaseBlocks) {}

    function initialize(
        uint256 promisedWaitingPhasesMin,
        uint256 promisedWaitingPhasesMax
    ) external {
        if (initialized) {
            revert AlreadyInitialized();
        }
        initialized = true;
        PROMISED_WAITING_PHASES_MIN = promisedWaitingPhasesMin;
        PROMISED_WAITING_PHASES_MAX = promisedWaitingPhasesMax;
    }

    function accountStakeStatus(
        address tokenAddress,
        address account
    ) external view returns (AccountStakeStatus memory) {
        return _accountStakeStatus[tokenAddress][account];
    }

    function validGovVotes(
        address tokenAddress,
        address account
    ) external view returns (uint256) {
        AccountStakeStatus memory status = _accountStakeStatus[tokenAddress][
            account
        ];

        ILOVE20SLToken sl = ILOVE20SLToken(
            ILOVE20Token(tokenAddress).slAddress()
        );
        uint256 slAmount = sl.balanceOf(account);

        ILOVE20STToken st = ILOVE20STToken(
            ILOVE20Token(tokenAddress).stAddress()
        );
        uint256 stAmount = st.balanceOf(account);

        if (slAmount >= status.slAmount && stAmount >= status.stAmount) {
            return status.govVotes;
        } else {
            return 0;
        }
    }

    function stakeLiquidity(
        address tokenAddress,
        uint256 tokenAmountForLP,
        uint256 parentTokenAmountForLP,
        uint256 promisedWaitingPhases,
        address to
    ) external returns (uint256 govVotesAdded, uint256 slAmountAdded) {
        // round 0 is not allowed, because will use 0 to check if the round is started
        if (currentRound() == 0) revert NotAllowedToStakeAtRoundZero();
        if (initialStakeRound[tokenAddress] == 0) {
            initialStakeRound[tokenAddress] = currentRound();
        }

        if (to == address(0)) revert InvalidToAddress();
        if (tokenAmountForLP == 0 || parentTokenAmountForLP == 0)
            revert StakeAmountMustBeSet();

        if (_accountStakeStatus[tokenAddress][to].requestedUnstakeRound != 0)
            revert UnstakeAlreadyRequested();
        if (
            promisedWaitingPhases < PROMISED_WAITING_PHASES_MIN ||
            promisedWaitingPhases > PROMISED_WAITING_PHASES_MAX
        ) revert PromisedWaitingPhasesOutOfRange();
        if (
            promisedWaitingPhases <
            _accountStakeStatus[tokenAddress][to].promisedWaitingPhases
        ) revert PromisedWaitingPhasesMustBeGreaterOrEqualThanBefore();

        address slAddress = ILOVE20Token(tokenAddress).slAddress();

        IERC20(tokenAddress).transferFrom(
            msg.sender,
            slAddress,
            tokenAmountForLP
        );

        address parentTokenAddress = ILOVE20Token(tokenAddress)
            .parentTokenAddress();
        IERC20(parentTokenAddress).transferFrom(
            msg.sender,
            slAddress,
            parentTokenAmountForLP
        );

        slAmountAdded = ILOVE20SLToken(slAddress).mint(to);

        AccountStakeStatus storage status = _accountStakeStatus[tokenAddress][
            to
        ];

        govVotesAdded =
            caculateGovVotes(
                status.slAmount + slAmountAdded,
                promisedWaitingPhases
            ) -
            caculateGovVotes(status.slAmount, status.promisedWaitingPhases);
        status.govVotes += govVotesAdded;
        govVotesNum[tokenAddress] += govVotesAdded;
        status.promisedWaitingPhases = promisedWaitingPhases;
        status.slAmount += slAmountAdded;

        emit StakeLiquidity({
            tokenAddress: tokenAddress,
            round: currentRound(),
            account: to,
            tokenAmountForLP: tokenAmountForLP,
            parentTokenAmountForLP: parentTokenAmountForLP,
            promisedWaitingPhases: promisedWaitingPhases,
            govVotesAdded: govVotesAdded,
            govVotes: status.govVotes,
            slAmountAdded: slAmountAdded,
            slAmount: status.slAmount
        });

        return (govVotesAdded, slAmountAdded);
    }

    function stakeToken(
        address tokenAddress,
        uint256 tokenAmount,
        uint256 promisedWaitingPhases,
        address to
    ) external returns (uint256 govVotesAdded) {
        if (to == address(0)) revert InvalidToAddress();

        AccountStakeStatus storage status = _accountStakeStatus[tokenAddress][
            to
        ];

        if (status.slAmount == 0) revert NoStakedLiquidity();
        if (tokenAmount == 0) revert StakeAmountMustBeSet();

        if (status.requestedUnstakeRound != 0) revert UnstakeAlreadyRequested();

        if (
            promisedWaitingPhases < PROMISED_WAITING_PHASES_MIN ||
            promisedWaitingPhases > PROMISED_WAITING_PHASES_MAX
        ) revert PromisedWaitingPhasesOutOfRange();
        if (promisedWaitingPhases < status.promisedWaitingPhases)
            revert PromisedWaitingPhasesMustBeGreaterOrEqualThanBefore();

        // transfer token to contract
        ILOVE20STToken st = ILOVE20STToken(
            ILOVE20Token(tokenAddress).stAddress()
        );
        IERC20(tokenAddress).transferFrom(msg.sender, address(st), tokenAmount);

        // mint st token
        st.mint(to);

        status.stAmount = status.stAmount + tokenAmount;
        if (status.promisedWaitingPhases < promisedWaitingPhases) {
            govVotesAdded =
                caculateGovVotes(status.slAmount, promisedWaitingPhases) -
                status.govVotes;
            status.govVotes += govVotesAdded;
            govVotesNum[tokenAddress] += govVotesAdded;
            status.promisedWaitingPhases = promisedWaitingPhases;
        }

        _updateAmountStaked(tokenAddress, tokenAmount, true);
        _updateAmountStakedByAccount(tokenAddress, to, tokenAmount, true);

        emit StakeToken({
            tokenAddress: tokenAddress,
            round: currentRound(),
            account: to,
            tokenAmount: tokenAmount,
            promisedWaitingPhases: promisedWaitingPhases,
            govVotesAdded: govVotesAdded,
            govVotes: status.govVotes,
            stAmount: status.stAmount
        });

        return govVotesAdded;
    }

    function unstake(address tokenAddress) external {
        AccountStakeStatus storage status = _accountStakeStatus[tokenAddress][
            msg.sender
        ];
        uint256 slAmount = status.slAmount;
        uint256 stAmount = status.stAmount;
        uint256 govVotes = status.govVotes;

        if (status.requestedUnstakeRound != 0) revert UnstakeAlreadyRequested();

        if (slAmount == 0) revert NoStakedLiquidity();

        if (slAmount > 0) {
            ILOVE20SLToken sl = ILOVE20SLToken(
                ILOVE20Token(tokenAddress).slAddress()
            );
            sl.transferFrom(msg.sender, address(this), slAmount);
        }

        if (stAmount > 0) {
            ILOVE20STToken st = ILOVE20STToken(
                ILOVE20Token(tokenAddress).stAddress()
            );
            st.transferFrom(msg.sender, address(this), stAmount);
        }

        uint256 round = currentRound();

        status.requestedUnstakeRound = round;
        govVotesNum[tokenAddress] -= status.govVotes;
        status.govVotes = 0;

        _updateAmountStaked(tokenAddress, stAmount, false);
        _updateAmountStakedByAccount(tokenAddress, msg.sender, stAmount, false);

        emit Unstake({
            tokenAddress: tokenAddress,
            round: currentRound(),
            account: msg.sender,
            promisedWaitingPhases: status.promisedWaitingPhases,
            govVotes: govVotes,
            slAmount: slAmount,
            stAmount: stAmount
        });
    }

    function withdraw(address tokenAddress) external {
        AccountStakeStatus storage status = _accountStakeStatus[tokenAddress][
            msg.sender
        ];
        uint256 stAmount = status.stAmount;
        uint256 slAmount = status.slAmount;
        uint256 requestedUnstakeRound = status.requestedUnstakeRound;
        uint256 promisedWaitingPhases = status.promisedWaitingPhases;

        if (slAmount == 0) revert NoStakedLiquidity();
        if (requestedUnstakeRound == 0) revert UnstakeNotRequested();

        if (currentRound() - requestedUnstakeRound <= promisedWaitingPhases)
            revert NotEnoughWaitingBlocks();

        // reset staked amount
        delete _accountStakeStatus[tokenAddress][msg.sender];

        (
            uint256 tokenAmountForLp,
            uint256 parentTokenAmountForLp
        ) = _withdrawAssets(tokenAddress, slAmount, stAmount);

        emit Withdraw({
            tokenAddress: tokenAddress,
            round: currentRound(),
            account: msg.sender,
            slAmount: slAmount,
            promisedWaitingPhases: promisedWaitingPhases,
            tokenAmountForLp: tokenAmountForLp,
            parentTokenAmountForLp: parentTokenAmountForLp,
            stAmount: stAmount
        });
    }

    function caculateGovVotes(
        uint256 slAmount,
        uint256 promisedWaitingPhases
    ) public pure returns (uint256) {
        return slAmount * promisedWaitingPhases;
    }

    function cumulatedTokenAmount(
        address tokenAddress,
        uint256 round
    ) external view returns (uint256 tokenAmount) {
        if (currentRound() < round) revert RoundHasNotStartedYet();

        tokenAmount = _cumulatedTokenAmount[tokenAddress][round];
        if (tokenAmount > 0) {
            return tokenAmount;
        }

        (bool found, uint256 nearestRound) = _stakeTokenUpdatedRounds[
            tokenAddress
        ].findLeftNearestOrEqualValue(round);
        if (found) {
            return _cumulatedTokenAmount[tokenAddress][nearestRound];
        }
        return 0;
    }

    function cumulatedTokenAmountByAccount(
        address tokenAddress,
        uint256 round,
        address account
    ) external view returns (uint256 tokenAmount) {
        if (currentRound() < round) revert RoundHasNotStartedYet();

        tokenAmount = _cumulatedTokenAmountByAccount[tokenAddress][round][
            account
        ];
        if (tokenAmount > 0) {
            return tokenAmount;
        }

        (bool found, uint256 nearestRound) = _stakeTokenUpdatedRoundsByAccount[
            tokenAddress
        ][account].findLeftNearestOrEqualValue(round);
        if (found) {
            return
                _cumulatedTokenAmountByAccount[tokenAddress][nearestRound][
                    account
                ];
        }
        return 0;
    }

    function stakeTokenUpdatedRoundsCount(
        address tokenAddress
    ) external view returns (uint256) {
        return _stakeTokenUpdatedRounds[tokenAddress].length;
    }

    function stakeTokenUpdatedRoundsAtIndex(
        address tokenAddress,
        uint256 index
    ) external view returns (uint256) {
        return _stakeTokenUpdatedRounds[tokenAddress][index];
    }

    function stakeTokenUpdatedRoundsByAccountCount(
        address tokenAddress,
        address account
    ) external view returns (uint256) {
        return _stakeTokenUpdatedRoundsByAccount[tokenAddress][account].length;
    }

    function stakeTokenUpdatedRoundsByAccountAtIndex(
        address tokenAddress,
        address account,
        uint256 index
    ) external view returns (uint256) {
        return _stakeTokenUpdatedRoundsByAccount[tokenAddress][account][index];
    }

    function _handleLiquidityFee(address tokenAddress) internal {
        ILOVE20SLToken sl = ILOVE20SLToken(
            ILOVE20Token(tokenAddress).slAddress()
        );

        // withdraw fee
        sl.withdrawFee(address(this));

        // add to parent token pool
        IERC20 parentToken = IERC20(
            ILOVE20Token(tokenAddress).parentTokenAddress()
        );

        uint256 parentTokenAmount = parentToken.balanceOf(address(this));
        if (parentTokenAmount > 0) {
            parentToken.transfer(tokenAddress, parentTokenAmount);
        }

        // burn token
        uint256 burnAmount = IERC20(tokenAddress).balanceOf(address(this));
        if (burnAmount > 0) {
            ILOVE20Token token = ILOVE20Token(tokenAddress);
            token.burn(burnAmount);
        }
    }

    function _withdrawAssets(
        address tokenAddress,
        uint256 slAmount,
        uint256 stAmount
    )
        internal
        returns (uint256 tokenAmountForLp, uint256 parentTokenAmountForLp)
    {
        if (slAmount > 0) {
            _handleLiquidityFee(tokenAddress);
            ILOVE20SLToken sl = ILOVE20SLToken(
                ILOVE20Token(tokenAddress).slAddress()
            );
            sl.transfer(address(sl), slAmount);
            (tokenAmountForLp, parentTokenAmountForLp) = sl.burn(msg.sender);
        }

        if (stAmount > 0) {
            ILOVE20STToken st = ILOVE20STToken(
                ILOVE20Token(tokenAddress).stAddress()
            );
            st.transfer(address(st), stAmount);
            st.burn(msg.sender);
        }

        return (tokenAmountForLp, parentTokenAmountForLp);
    }

    function _updateAmountStaked(
        address tokenAddress,
        uint256 tokenAmount,
        bool increase
    ) internal {
        uint256 length = _stakeTokenUpdatedRounds[tokenAddress].length;
        uint256 round = currentRound();
        uint256 latestRound = length > 0
            ? _stakeTokenUpdatedRounds[tokenAddress][length - 1]
            : 0;

        if (length == 0 || round > latestRound) {
            _cumulatedTokenAmount[tokenAddress][round] = _cumulatedTokenAmount[
                tokenAddress
            ][latestRound];
            _stakeTokenUpdatedRounds[tokenAddress].push(round);
        }

        if (increase) {
            _cumulatedTokenAmount[tokenAddress][round] += tokenAmount;
        } else {
            _cumulatedTokenAmount[tokenAddress][round] -= tokenAmount;
        }
    }

    function _updateAmountStakedByAccount(
        address tokenAddress,
        address account,
        uint256 tokenAmount,
        bool increase
    ) internal {
        uint256 round = currentRound();
        uint256[] storage updateRounds = _stakeTokenUpdatedRoundsByAccount[
            tokenAddress
        ][account];
        uint256 length = updateRounds.length;
        uint256 latestRound = length > 0 ? updateRounds[length - 1] : 0;

        if (length == 0 || round > latestRound) {
            // copy latest round data
            _cumulatedTokenAmountByAccount[tokenAddress][round][
                account
            ] = _cumulatedTokenAmountByAccount[tokenAddress][latestRound][
                account
            ];
            updateRounds.push(round);
        }

        if (increase) {
            _cumulatedTokenAmountByAccount[tokenAddress][round][
                account
            ] += tokenAmount;
        } else {
            _cumulatedTokenAmountByAccount[tokenAddress][round][
                account
            ] -= tokenAmount;
        }
    }
}
