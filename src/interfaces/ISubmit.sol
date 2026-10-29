// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

enum TargetMode { NoCallback, Callback }

struct ProposalHead {
    // managed by contract
    uint256 id;
    uint256 author;
    uint256 createAtBlock;
}

struct ProposalBody {
    string title;
    string details;
    address target;
    TargetMode targetMode;
    bytes[] targetData;
}

struct ProposalInfo {
    ProposalHead head;
    ProposalBody body;
}

struct SubmitInfo {
    uint256 submitterId;
    uint256 proposalId;
}
interface ISubmitErrors {
    error AlreadyInitialized();
    error TitleEmpty();
    error TitleTooLong(
        uint256 length,
        uint256 maxLength
    );
    error DetailsTooLong(
        uint256 length,
        uint256 maxLength
    );
    error TargetDataTooMany(
        uint256 count,
        uint256 maxCount
    );
    error TargetDataTooLarge(
        uint256 totalLength,
        uint256 maxLength
    );
    error ZeroTargetAddress();
    error CallbackTargetNotContract(address target);
    error NotMemberOwner(uint256 memberId);
    error NoGovVotes(address tokenAddress);
    error ProposalNotFound(uint256 proposalId);
    error InsufficientSubmitPower(
        address tokenAddress,
        uint256 memberId,
        uint256 validVotes,
        uint256 requiredVotes
    );
    error SubmitRoundFull(
        address tokenAddress,
        uint256 round,
        uint256 limit
    );
    error ProposalAlreadySubmitted(
        address tokenAddress,
        uint256 round,
        uint256 proposalId
    );
    error MemberAlreadySubmitted(
        address tokenAddress,
        uint256 round,
        uint256 memberId
    );
}
interface ISubmitEvents {
    event ProposalCreated(
        address indexed tokenAddress,
        uint256 indexed proposalId,
        uint256 indexed authorId,
        address target,
        TargetMode targetMode,
        bytes[] targetData,
        string title,
        string details
    );

    event ProposalSubmitted(
        address indexed tokenAddress,
        uint256 round,
        uint256 indexed submitterId,
        uint256 indexed proposalId
    );
}

interface ISubmit is ISubmitErrors, ISubmitEvents {
    function stakeAddress() external view returns (address);
    function phaseAddress() external view returns (address);
    function memberNFTAddress() external view returns (address);

    function SUBMIT_MIN_RATIO() external view returns (uint256);
    function MAX_TITLE_LENGTH() external view returns (uint256);
    function MAX_DETAILS_LENGTH() external view returns (uint256);
    function MAX_TARGET_DATA_BYTES() external view returns (uint256);
    function MAX_TARGET_DATA_COUNT() external view returns (uint256);

    function initialized() external view returns (bool);

    function init(
        address phaseAddress,
        address stakeAddress,
        address memberNFTAddress,
        uint256 submitMinRatio
    ) external;

    function currentRound() external view returns (uint256);

    function canSubmit(
        address tokenAddress,
        uint256 memberId
    ) external view returns (bool);

    function submitNewProposal(
        address tokenAddress,
        uint256 memberId,
        ProposalBody calldata body
    ) external returns (uint256 proposalId);

    function submit(address tokenAddress, uint256 memberId, uint256 proposalId) external;

    function isSubmitted(
        address tokenAddress,
        uint256 round,
        uint256 proposalId
    ) external view returns (bool);

    function proposalIds(address tokenAddress, uint256 offset, uint256 limit, bool reverse)
        external view returns (uint256[] memory proposalIdList, uint256 totalCount);

    function proposalIdsByAuthor(
        address tokenAddress,
        uint256 author,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory proposalIdList, uint256 totalCount);

    function proposalInfosByIds(
        address tokenAddress,
        uint256[] calldata proposalIds
    ) external view returns (ProposalInfo[] memory);

    function proposalTarget(address tokenAddress, uint256 proposalId)
        external
        view
        returns (address target, TargetMode targetMode);

    function submitInfos(
        address tokenAddress,
        uint256 round,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (SubmitInfo[] memory submitInfoList, uint256 totalCount);

    function proposalIdBySubmitter(
        address tokenAddress,
        uint256 round,
        uint256 submitterId
    ) external view returns (uint256 proposalId);

    function submitterIdByProposalId(
        address tokenAddress,
        uint256 round,
        uint256 proposalId
    ) external view returns (uint256 submitterId);
}
