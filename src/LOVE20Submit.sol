// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Phase} from "./Phase.sol";
import {IStake} from "./interfaces/IStake.sol";
import {ILOVE20Submit, ActionHead, ActionBody, ActionInfo, ActionSubmitInfo} from "./interfaces/ILOVE20Submit.sol";

contract LOVE20Submit is Phase, ILOVE20Submit {
    bool public initialized;
    address public stakeAddress;
    uint256 public SUBMIT_MIN_PER_THOUSAND;
    uint256 public MAX_VERIFICATION_KEY_LENGTH;

    // tokenAddress => ActionInfo[]
    mapping(address => ActionInfo[]) internal _actions;

    // tokenAddress => author => actionId[]
    mapping(address => mapping(address => uint256[])) internal _authorActionIds;
    // tokenAddress => round => ActionSubmitInfo[]
    mapping(address => mapping(uint256 => ActionSubmitInfo[]))
        internal _actionSubmits;
    // tokenAddress => round => actionId => ActionSubmitInfo
    mapping(address => mapping(uint256 => mapping(uint256 => ActionSubmitInfo)))
        internal _actionSubmitInfoByActionId;
    // tokenAddress => round => submitter => ActionSubmitInfo
    mapping(address => mapping(uint256 => mapping(address => ActionSubmitInfo)))
        internal _actionSubmitInfoBySubmitter;

    constructor(
        uint256 originBlocks,
        uint256 phaseBlocks,
        uint256 targetSeconds,
        uint256 adjustThreshold,
        uint256 syncObservationLimit
    ) Phase(originBlocks, phaseBlocks, targetSeconds, adjustThreshold, syncObservationLimit) {}

    function currentRound() internal view returns (uint256) {
        return currentPhase();
    }

    function initialize(
        address stakeAddress_,
        uint256 submitMinPerThousand,
        uint256 maxVerificationKeyLength
    ) external {
        if (initialized) {
            revert AlreadyInitialized();
        }
        initialized = true;
        stakeAddress = stakeAddress_;
        SUBMIT_MIN_PER_THOUSAND = submitMinPerThousand;
        MAX_VERIFICATION_KEY_LENGTH = maxVerificationKeyLength;
    }

    function canSubmit(
        address tokenAddress,
        address account
    ) public view returns (bool) {
        IStake stake = IStake(stakeAddress);
        // Note: IStake.validGovVotes takes memberId (uint256), but old code used address
        // Casting address to uint256 as temporary measure for baseline compilation
        uint256 validVotes = stake.validGovVotes(tokenAddress, uint256(uint160(account)));
        uint256 total = stake.globalGovVotes(tokenAddress);

        if (validVotes == 0) {
            return false;
        }

        return ((validVotes * 1000) / total) >= SUBMIT_MIN_PER_THOUSAND;
    }

    function submitNewAction(
        address tokenAddress,
        ActionBody calldata actionBody
    ) external returns (uint256 actionId) {
        if (!canSubmit(tokenAddress, msg.sender)) revert CannotSubmitAction();

        actionId = _createAction(tokenAddress, actionBody);

        _submitByActionId(tokenAddress, actionId);
        return actionId;
    }

    function submit(address tokenAddress, uint256 actionId) external {
        if (!canSubmit(tokenAddress, msg.sender)) revert CannotSubmitAction();

        _submitByActionId(tokenAddress, actionId);
    }

    function isSubmitted(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) public view returns (bool) {
        return
            _actionSubmitInfoByActionId[tokenAddress][round][actionId]
                .submitter != address(0);
    }

    function canJoin(
        address tokenAddress,
        uint256 actionId,
        address account
    ) external view returns (bool) {
        address whiteListAddress = actionInfo(tokenAddress, actionId)
            .body
            .whiteListAddress;
        return whiteListAddress == address(0) || whiteListAddress == account;
    }

    function actionsCount(address tokenAddress) public view returns (uint256) {
        return _actions[tokenAddress].length;
    }
    function actionsAtIndex(
        address tokenAddress,
        uint256 index
    ) public view returns (ActionInfo memory) {
        return _actions[tokenAddress][index];
    }

    function actionInfo(
        address tokenAddress,
        uint256 actionId
    ) public view returns (ActionInfo memory) {
        if (actionId >= _actions[tokenAddress].length)
            revert ActionIdNotExist();
        return _actions[tokenAddress][actionId];
    }

    function actionSubmitsCount(
        address tokenAddress,
        uint256 round
    ) external view returns (uint256) {
        return _actionSubmits[tokenAddress][round].length;
    }

    function actionSubmitsAtIndex(
        address tokenAddress,
        uint256 round,
        uint256 index
    ) external view returns (ActionSubmitInfo memory) {
        return _actionSubmits[tokenAddress][round][index];
    }

    function submitInfo(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external view returns (ActionSubmitInfo memory) {
        return _actionSubmitInfoByActionId[tokenAddress][round][actionId];
    }

    function submitInfoBySubmitter(
        address tokenAddress,
        uint256 round,
        address submitter
    ) external view returns (ActionSubmitInfo memory) {
        return _actionSubmitInfoBySubmitter[tokenAddress][round][submitter];
    }

    function authorActionIdsCount(
        address tokenAddress,
        address author
    ) external view returns (uint256) {
        return _authorActionIds[tokenAddress][author].length;
    }

    function authorActionIdsAtIndex(
        address tokenAddress,
        address author,
        uint256 index
    ) external view returns (uint256) {
        return _authorActionIds[tokenAddress][author][index];
    }

    function _createAction(
        address tokenAddress,
        ActionBody memory actionBody
    ) internal returns (uint256 actionId) {
        if (actionBody.minStake == 0) revert MinStakeZero();
        if (actionBody.maxRandomAccounts == 0) revert MaxRandomAccountsZero();
        if (bytes(actionBody.title).length == 0) revert TitleEmpty();
        if (bytes(actionBody.verificationRule).length == 0)
            revert VerificationRuleEmpty();
        for (uint256 i = 0; i < actionBody.verificationKeys.length; i++) {
            if (
                bytes(actionBody.verificationKeys[i]).length >
                MAX_VERIFICATION_KEY_LENGTH
            ) revert VerificationKeyLengthExceeded();
        }

        actionId = _actions[tokenAddress].length;
        ActionHead memory head = ActionHead({
            id: actionId,
            author: msg.sender,
            createAtBlock: block.number
        });

        _actions[tokenAddress].push(ActionInfo({head: head, body: actionBody}));
        _authorActionIds[tokenAddress][msg.sender].push(actionId);

        emit ActionCreate({
            tokenAddress: tokenAddress,
            round: currentRound(),
            author: msg.sender,
            actionId: actionId,
            actionBody: actionBody
        });

        return actionId;
    }

    function _submitByActionId(
        address tokenAddress,
        uint256 actionId
    ) internal {
        if (actionId >= _actions[tokenAddress].length)
            revert ActionIdNotExist();

        uint256 round = currentRound();
        // check if actionId is already submitted in current round
        if (isSubmitted(tokenAddress, round, actionId))
            revert AlreadySubmitted();
        if (
            _actionSubmitInfoBySubmitter[tokenAddress][round][msg.sender]
                .submitter != address(0)
        ) revert OnlyOneSubmitPerRound();

        ActionSubmitInfo memory actionSubmitInfo = ActionSubmitInfo(
            msg.sender,
            actionId
        );

        _actionSubmits[tokenAddress][round].push(actionSubmitInfo);
        _actionSubmitInfoByActionId[tokenAddress][round][
            actionId
        ] = actionSubmitInfo;
        _actionSubmitInfoBySubmitter[tokenAddress][round][
            msg.sender
        ] = actionSubmitInfo;

        emit ActionSubmit({
            tokenAddress: tokenAddress,
            round: round,
            submitter: msg.sender,
            actionId: actionId
        });
    }
}
