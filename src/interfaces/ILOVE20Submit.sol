// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IPhase} from "./IPhase.sol";

struct ActionHead {
    // managed by contract
    uint256 id;
    address author;
    uint256 createAtBlock;
}

struct ActionBody {
    // action parameters
    uint256 minStake;
    uint256 maxRandomAccounts;
    address whiteListAddress;
    // action content
    string title;
    string verificationRule;
    // extra verification info
    string[] verificationKeys;
    string[] verificationInfoGuides;
}

struct ActionInfo {
    ActionHead head;
    ActionBody body;
}

struct ActionSubmitInfo {
    address submitter;
    uint256 actionId;
}
interface ILOVE20SubmitErrors {
    error AlreadyInitialized();
    error CannotSubmitAction();
    error ActionIdNotExist();
    error MinStakeZero();
    error MaxRandomAccountsZero();
    error TitleEmpty();
    error VerificationRuleEmpty();
    error VerificationKeyLengthExceeded();
    error AlreadySubmitted();
    error OnlyOneSubmitPerRound();
}
interface ILOVE20SubmitEvents {
    // Events
    event ActionCreate(
        address indexed tokenAddress,
        uint256 round,
        address indexed author,
        uint256 indexed actionId,
        ActionBody actionBody
    );

    event ActionSubmit(
        address indexed tokenAddress,
        uint256 round,
        address indexed submitter,
        uint256 indexed actionId
    );
}

interface ILOVE20Submit is ILOVE20SubmitErrors, ILOVE20SubmitEvents, IPhase {
    function stakeAddress() external view returns (address);

    function SUBMIT_MIN_PER_THOUSAND() external view returns (uint256);
    function MAX_VERIFICATION_KEY_LENGTH() external view returns (uint256);

    function canSubmit(
        address tokenAddress,
        address account
    ) external view returns (bool);

    function submitNewAction(
        address tokenAddress,
        ActionBody calldata actionBody
    ) external returns (uint256 actionId);

    function submit(address tokenAddress, uint256 actionId) external;

    function isSubmitted(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external view returns (bool);

    function canJoin(
        address tokenAddress,
        uint256 actionId,
        address account
    ) external view returns (bool);

    function actionsCount(address tokenAddress) external view returns (uint256);
    function actionsAtIndex(
        address tokenAddress,
        uint256 index
    ) external view returns (ActionInfo memory);

    function actionInfo(
        address tokenAddress,
        uint256 actionId
    ) external view returns (ActionInfo memory);

    function actionSubmitsCount(
        address tokenAddress,
        uint256 round
    ) external view returns (uint256);

    function actionSubmitsAtIndex(
        address tokenAddress,
        uint256 round,
        uint256 index
    ) external view returns (ActionSubmitInfo memory);

    function submitInfo(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external view returns (ActionSubmitInfo memory);

    function submitInfoBySubmitter(
        address tokenAddress,
        uint256 round,
        address submitter
    ) external view returns (ActionSubmitInfo memory);

    function authorActionIdsCount(
        address tokenAddress,
        address author
    ) external view returns (uint256);

    function authorActionIdsAtIndex(
        address tokenAddress,
        address author,
        uint256 index
    ) external view returns (uint256);
}
