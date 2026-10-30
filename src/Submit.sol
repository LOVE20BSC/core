// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IPhase} from "./interfaces/IPhase.sol";
import {IStake} from "./interfaces/IStake.sol";
import {IMemberNFT} from "./interfaces/IMemberNFT.sol";
import {ISubmit, ProposalHead, ProposalBody, ProposalInfo, SubmitInfo, TargetMode} from "./interfaces/ISubmit.sol";
import {IProposalTarget} from "./interfaces/IProposalTarget.sol";

import {Pagination} from "@libs/Pagination.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract Submit is ISubmit {
    using Pagination for uint256[];

    uint256 private constant SUBMIT_ROUND_LIMIT = 1000;

    uint256 public constant MAX_TITLE_LENGTH = 1024;
    uint256 public constant MAX_DETAILS_LENGTH = 1024;
    uint256 public constant MAX_TARGET_DATA_BYTES = 16 * 1024;
    uint256 public constant MAX_TARGET_DATA_COUNT = 16;

    bool public initialized;
    address public PHASE_ADDRESS;
    address public STAKE_ADDRESS;
    address public MEMBER_NFT_ADDRESS;
    uint256 public SUBMIT_MIN_RATIO;

    // tokenAddress => ProposalInfo[]
    mapping(address => ProposalInfo[]) internal _proposals;

    // tokenAddress => author => proposalId[]
    mapping(address => mapping(uint256 => uint256[])) internal _authorProposalIds;
    // tokenAddress => round => SubmitInfo[]
    mapping(address => mapping(uint256 => SubmitInfo[]))
        internal _submits;
    // tokenAddress => round => proposalId => SubmitInfo
    mapping(address => mapping(uint256 => mapping(uint256 => SubmitInfo)))
        internal _submitInfoByProposalId;
    // tokenAddress => round => submitterId => SubmitInfo
    mapping(address => mapping(uint256 => mapping(uint256 => SubmitInfo)))
        internal _submitInfoBySubmitterId;

    function currentRound() public view returns (uint256) {
        return IPhase(PHASE_ADDRESS).currentPhase();
    }

    // forge-lint: disable-next-item(missing-zero-check)
    function init(
        address phaseAddress,
        address stakeAddress,
        address memberNFTAddress,
        uint256 submitMinRatio
    ) external {
        if (initialized) {
            revert AlreadyInitialized();
        }
        initialized = true;
        PHASE_ADDRESS = phaseAddress;
        STAKE_ADDRESS = stakeAddress;
        MEMBER_NFT_ADDRESS = memberNFTAddress;
        SUBMIT_MIN_RATIO = submitMinRatio;
    }

    function canSubmit(
        address tokenAddress,
        uint256 memberId
    ) public view returns (bool) {
        (uint256 validVotes, uint256 requiredVotes, ) = _submitPower(tokenAddress, memberId);
        return _meetsSubmitPower(validVotes, requiredVotes);
    }

    function _submitPower(
        address tokenAddress,
        uint256 memberId
    ) private view returns (uint256 validVotes, uint256 requiredVotes, uint256 totalVotes) {
        IStake stake = IStake(STAKE_ADDRESS);
        uint256 round = currentRound();
        validVotes = stake.validGovVotes(tokenAddress, round, memberId);
        totalVotes = stake.totalValidGovVotes(tokenAddress, round);
        requiredVotes = Math.mulDiv(totalVotes, SUBMIT_MIN_RATIO, 1e18, Math.Rounding.Ceil);
    }

    function _meetsSubmitPower(uint256 validVotes, uint256 requiredVotes) private pure returns (bool) {
        return requiredVotes != 0 && validVotes >= requiredVotes;
    }

    function _requireSubmitPower(address tokenAddress, uint256 memberId) private view {
        (uint256 validVotes, uint256 requiredVotes, uint256 totalVotes) = _submitPower(tokenAddress, memberId);
        if (totalVotes == 0) {
            revert NoGovVotes(tokenAddress);
        }
        if (!_meetsSubmitPower(validVotes, requiredVotes)) {
            revert InsufficientSubmitPower(tokenAddress, memberId, validVotes, requiredVotes);
        }
    }

    modifier onlyMemberOwner(uint256 memberId) {
        if (IMemberNFT(MEMBER_NFT_ADDRESS).ownerOf(memberId) != msg.sender) {
            revert NotMemberOwner(memberId);
        }
        _;
    }

    function submitNewProposal(
        address tokenAddress,
        uint256 memberId,
        ProposalBody calldata proposalBody
    ) external onlyMemberOwner(memberId) returns (uint256 proposalId) {
        _validateProposalBody(proposalBody);
        _requireSubmitPower(tokenAddress, memberId);

        proposalId = _createProposal(tokenAddress, memberId, proposalBody);

        _submitByProposalId(tokenAddress, memberId, proposalId);
        _callProposalCreated(tokenAddress, proposalId);
        _callProposalSubmitted(tokenAddress, proposalId, memberId);
        return proposalId;
    }

    function submit(address tokenAddress, uint256 memberId, uint256 proposalId)
        external
        onlyMemberOwner(memberId)
    {
        _requireProposalExists(tokenAddress, proposalId);
        _requireSubmitPower(tokenAddress, memberId);

        _submitByProposalId(tokenAddress, memberId, proposalId);
        _callProposalSubmitted(tokenAddress, proposalId, memberId);
    }

    function isSubmitted(
        address tokenAddress,
        uint256 round,
        uint256 proposalId
    ) public view returns (bool) {
        return
            _submitInfoByProposalId[tokenAddress][round][proposalId]
                .submitterId != 0;
    }

    function proposalIds(address tokenAddress, uint256 offset, uint256 limit, bool reverse)
        external view returns (uint256[] memory proposalIdList, uint256 totalCount) {
        totalCount = _proposals[tokenAddress].length;
        // Proposal records carry bodies, so only their ids belong on a page; bodies come from
        // proposalInfosByProposalIds.
        uint256[] memory indices = Pagination.paginateIndices(totalCount, offset, limit, reverse);
        proposalIdList = new uint256[](indices.length);
        for (uint256 i = 0; i < indices.length; i++) {
            proposalIdList[i] = _proposals[tokenAddress][indices[i]].head.id;
        }
    }

    function proposalIdsByAuthor(
        address tokenAddress,
        uint256 author,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory proposalIdList, uint256 totalCount) {
        return _authorProposalIds[tokenAddress][author].paginate(offset, limit, reverse);
    }

    function proposalTarget(address tokenAddress, uint256 proposalId)
        external
        view
        returns (address target, TargetMode targetMode)
    {
        if (proposalId == 0 || proposalId > _proposals[tokenAddress].length) {
            revert ProposalNotFound(proposalId);
        }
        ProposalBody storage body = _proposals[tokenAddress][proposalId - 1].body;
        return (body.target, body.targetMode);
    }

    function proposalInfosByProposalIds(
        address tokenAddress,
        uint256[] calldata requestedProposalIds
    ) external view returns (ProposalInfo[] memory) {
        ProposalInfo[] memory infos = new ProposalInfo[](requestedProposalIds.length);
        for (uint256 i = 0; i < requestedProposalIds.length; i++) {
            if (requestedProposalIds[i] == 0 || requestedProposalIds[i] > _proposals[tokenAddress].length) {
                // forge-lint: disable-next-line(require-revert-in-loop)
                revert ProposalNotFound(requestedProposalIds[i]);
            }
            infos[i] = _proposals[tokenAddress][requestedProposalIds[i] - 1];
        }
        return infos;
    }

    function submitInfos(
        address tokenAddress,
        uint256 round,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (SubmitInfo[] memory submitInfoList, uint256 totalCount) {
        totalCount = _submits[tokenAddress][round].length;
        uint256[] memory indices = Pagination.paginateIndices(totalCount, offset, limit, reverse);
        submitInfoList = new SubmitInfo[](indices.length);
        for (uint256 i = 0; i < indices.length; i++) {
            submitInfoList[i] = _submits[tokenAddress][round][indices[i]];
        }
    }

    function proposalIdBySubmitterId(
        address tokenAddress,
        uint256 round,
        uint256 submitterId
    ) external view returns (uint256 proposalId) {
        return _submitInfoBySubmitterId[tokenAddress][round][submitterId].proposalId;
    }

    function submitterIdByProposalId(
        address tokenAddress,
        uint256 round,
        uint256 proposalId
    ) external view returns (uint256 submitterId) {
        return _submitInfoByProposalId[tokenAddress][round][proposalId].submitterId;
    }

    function _validateProposalBody(ProposalBody calldata proposalBody) internal view {
        uint256 titleLength = bytes(proposalBody.title).length;
        if (titleLength == 0) revert TitleEmpty();
        if (titleLength > MAX_TITLE_LENGTH) revert TitleTooLong(titleLength, MAX_TITLE_LENGTH);

        uint256 detailsLength = bytes(proposalBody.details).length;
        if (detailsLength > MAX_DETAILS_LENGTH) revert DetailsTooLong(detailsLength, MAX_DETAILS_LENGTH);

        uint256 targetDataCount = proposalBody.targetData.length;
        if (targetDataCount > MAX_TARGET_DATA_COUNT) {
            revert TargetDataTooMany(targetDataCount, MAX_TARGET_DATA_COUNT);
        }
        uint256 targetDataBytes = 0;
        for (uint256 i = 0; i < targetDataCount; ++i) {
            targetDataBytes += proposalBody.targetData[i].length;
        }
        if (targetDataBytes > MAX_TARGET_DATA_BYTES) {
            revert TargetDataTooLarge(targetDataBytes, MAX_TARGET_DATA_BYTES);
        }

        if (proposalBody.target == address(0)) revert ZeroTargetAddress();
        if (proposalBody.targetMode == TargetMode.Callback && proposalBody.target.code.length == 0) {
            revert CallbackTargetNotContract(proposalBody.target);
        }
    }

    function _createProposal(
        address tokenAddress,
        uint256 memberId,
        ProposalBody memory proposalBody
    ) internal returns (uint256 proposalId) {
        proposalId = _proposals[tokenAddress].length + 1;
        ProposalHead memory head = ProposalHead({
            id: proposalId,
            author: memberId,
            createAtBlock: block.number
        });

        _proposals[tokenAddress].push(ProposalInfo({head: head, body: proposalBody}));
        _authorProposalIds[tokenAddress][memberId].push(proposalId);

        emit ProposalCreated({
            tokenAddress: tokenAddress,
            proposalId: proposalId,
            authorId: memberId,
            target: proposalBody.target,
            targetMode: proposalBody.targetMode,
            targetData: proposalBody.targetData,
            title: proposalBody.title,
            details: proposalBody.details
        });

        return proposalId;
    }

    function _requireProposalExists(address tokenAddress, uint256 proposalId) internal view {
        if (proposalId == 0 || proposalId > _proposals[tokenAddress].length) {
            revert ProposalNotFound(proposalId);
        }
    }

    function _submitByProposalId(
        address tokenAddress,
        uint256 memberId,
        uint256 proposalId
    ) internal {
        // Checks
        _requireProposalExists(tokenAddress, proposalId);

        uint256 round = currentRound();
        if (isSubmitted(tokenAddress, round, proposalId)) {
            revert ProposalAlreadySubmitted(tokenAddress, round, proposalId);
        }
        if (
            _submitInfoBySubmitterId[tokenAddress][round][memberId]
                .submitterId != 0
        ) revert MemberAlreadySubmitted(tokenAddress, round, memberId);
        if (_submits[tokenAddress][round].length >= SUBMIT_ROUND_LIMIT) {
            revert SubmitRoundFull(tokenAddress, round, SUBMIT_ROUND_LIMIT);
        }

        // Effects
        SubmitInfo memory submitInfo = SubmitInfo(
            memberId,
            proposalId
        );

        _submits[tokenAddress][round].push(submitInfo);
        _submitInfoByProposalId[tokenAddress][round][
            proposalId
        ] = submitInfo;
        _submitInfoBySubmitterId[tokenAddress][round][
            memberId
        ] = submitInfo;

        bool isFirstSubmit = _submits[tokenAddress][round].length == 1;

        // forge-lint: disable-next-item(reentrancy-events)
        emit ProposalSubmitted({
            tokenAddress: tokenAddress,
            round: round,
            submitterId: memberId,
            proposalId: proposalId
        });

        // Interactions
        if (isFirstSubmit) {
            // forge-lint: disable-next-line(unused-return)
            IPhase(PHASE_ADDRESS).sync();
        }

    }

    function _callProposalCreated(address tokenAddress, uint256 proposalId) private {
        ProposalBody memory body = _proposals[tokenAddress][proposalId - 1].body;
        if (body.targetMode == TargetMode.Callback) {
            IProposalTarget(body.target).onProposalCreated(tokenAddress, proposalId, body.targetData);
        }
    }

    function _callProposalSubmitted(address tokenAddress, uint256 proposalId, uint256 memberId) private {
        ProposalBody memory body = _proposals[tokenAddress][proposalId - 1].body;
        if (body.targetMode == TargetMode.Callback) {
            IProposalTarget(body.target).onProposalSubmitted(tokenAddress, proposalId, memberId, body.targetData);
        }
    }
}
