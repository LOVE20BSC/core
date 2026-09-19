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
    error InvalidAddress();
    error InvalidTargetMode();
    error NotMemberOwner(uint256 memberId);
    error EmptyString(string parameter);
    error ZeroAmount(string parameter);
    error InvalidAmount();
    error ProposalNotFound(uint256 proposalId);
    error CannotSubmitAction();
    error AlreadySubmitted();
    error OnlyOneSubmitPerRound();
}
interface ISubmitEvents {
    // Events
    event ProposalCreated(
        address indexed tokenAddress,
        uint256 indexed proposalId,
        uint256 indexed author,
        string title,
        string details,
        address target,
        TargetMode targetMode
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

    function SUBMIT_MIN_PER_THOUSAND() external view returns (uint256);

    function initialized() external view returns (bool);

    function init(
        address phaseAddress,
        address stakeAddress,
        address memberNFTAddress,
        uint256 submitMinPerThousand
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
