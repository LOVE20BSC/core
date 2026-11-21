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
    uint256 private constant PRECISION = 1e18;
    uint256 private constant PROPOSAL_ID_TO_INDEX_OFFSET = 1;

    uint256 public constant MAX_TITLE_LENGTH = 1024;
    uint256 public constant MAX_DETAILS_LENGTH = 1024;
    uint256 public constant MAX_CREATION_DATA_BYTES = 16 * 1024;

    address public PHASE_ADDRESS;
    address public STAKE_ADDRESS;
    address public MEMBER_NFT_ADDRESS;
    uint256 public SUBMIT_MIN_RATIO;

    // tokenAddress => ProposalInfo[]
    mapping(address => ProposalInfo[]) internal _proposals;

    // tokenAddress => target => proposalId[]
    mapping(address => mapping(address => uint256[])) internal _proposalIdsByTarget;
    // tokenAddress => author => proposalId[]
    mapping(address => mapping(uint256 => uint256[])) internal _proposalIdsByAuthor;
    // tokenAddress => author => target => proposalId[]
    mapping(address => mapping(uint256 => mapping(address => uint256[]))) internal _proposalIdsByAuthorByTarget;
    // tokenAddress => round => SubmitInfo[]
    mapping(address => mapping(uint256 => SubmitInfo[]))
        internal _submits;
    // tokenAddress => round => target => SubmitInfo[]
    mapping(address => mapping(uint256 => mapping(address => SubmitInfo[]))) internal _submitInfosByTarget;
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
    constructor(
        address phaseAddress,
        address stakeAddress,
        address memberNFTAddress,
        uint256 submitMinRatio
    ) {
        PHASE_ADDRESS = phaseAddress;
        STAKE_ADDRESS = stakeAddress;
        MEMBER_NFT_ADDRESS = memberNFTAddress;
        SUBMIT_MIN_RATIO = submitMinRatio;
    }

    function canSubmit(
        address tokenAddress,
        uint256 memberId
    ) public view returns (bool) {
        (uint256 validVotes, uint256 requiredVotes, ) = _submitPower(tokenAddress, currentRound(), memberId);
        return _meetsSubmitPower(validVotes, requiredVotes);
    }

    function _submitPower(
        address tokenAddress,
        uint256 round,
        uint256 memberId
    ) private view returns (uint256 validVotes, uint256 requiredVotes, uint256 totalVotes) {
        IStake stake = IStake(STAKE_ADDRESS);
        validVotes = stake.govVotes(tokenAddress, round, memberId);
        totalVotes = stake.totalGovVotes(tokenAddress, round);
        requiredVotes = Math.mulDiv(totalVotes, SUBMIT_MIN_RATIO, PRECISION, Math.Rounding.Ceil);
    }

    function _meetsSubmitPower(uint256 validVotes, uint256 requiredVotes) private pure returns (bool) {
        return requiredVotes != 0 && validVotes >= requiredVotes;
    }

    function _checkSubmitPower(
        address tokenAddress,
        uint256 round,
        uint256 memberId
    ) private view {
        (uint256 validVotes, uint256 requiredVotes, uint256 totalVotes) = _submitPower(tokenAddress, round, memberId);
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
        ProposalBody calldata proposalBody,
        bytes calldata submitData
    ) external onlyMemberOwner(memberId) returns (uint256 proposalId) {
        _checkProposalBody(proposalBody);
        uint256 round = currentRound();
        _checkSubmitPower(tokenAddress, round, memberId);
        _checkSubmitterQuota(tokenAddress, round, memberId);

        proposalId = _createProposal(tokenAddress, memberId, proposalBody);

        _recordSubmission(tokenAddress, round, proposalId, memberId);
        if (proposalBody.targetMode == TargetMode.Callback) {
            IProposalTarget(proposalBody.target).onProposalCreated(tokenAddress, proposalId, proposalBody.creationData);
            IProposalTarget(proposalBody.target).onProposalSubmitted(tokenAddress, round, proposalId, memberId, submitData);
        }
        return proposalId;
    }

    function submit(
        address tokenAddress,
        uint256 memberId,
        uint256 proposalId,
        bytes calldata submitData
    ) external onlyMemberOwner(memberId) {
        _checkExistingProposal(tokenAddress, proposalId);
        uint256 round = currentRound();
        _checkSubmitPower(tokenAddress, round, memberId);
        if (isSubmitted(tokenAddress, round, proposalId)) {
            revert ProposalAlreadySubmitted(tokenAddress, round, proposalId);
        }
        _checkSubmitterQuota(tokenAddress, round, memberId);

        _recordSubmission(tokenAddress, round, proposalId, memberId);
        ProposalBody storage body = _proposals[tokenAddress][proposalId - PROPOSAL_ID_TO_INDEX_OFFSET].body;
        if (body.targetMode == TargetMode.Callback) {
            IProposalTarget(body.target).onProposalSubmitted(tokenAddress, round, proposalId, memberId, submitData);
        }
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
        uint256[] memory indices = Pagination.paginateIndices(totalCount, offset, limit, reverse);
        proposalIdList = new uint256[](indices.length);
        for (uint256 i = 0; i < indices.length; i++) {
            proposalIdList[i] = _proposals[tokenAddress][indices[i]].head.id;
        }
    }

    function proposalIdsByTarget(
        address tokenAddress,
        address target,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory proposalIdList, uint256 totalCount) {
        return _proposalIdsByTarget[tokenAddress][target].paginate(offset, limit, reverse);
    }

    function proposalIdsByAuthor(
        address tokenAddress,
        uint256 author,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory proposalIdList, uint256 totalCount) {
        return _proposalIdsByAuthor[tokenAddress][author].paginate(offset, limit, reverse);
    }

    function proposalIdsByAuthorByTarget(
        address tokenAddress,
        uint256 author,
        address target,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (uint256[] memory proposalIdList, uint256 totalCount) {
        return _proposalIdsByAuthorByTarget[tokenAddress][author][target].paginate(offset, limit, reverse);
    }

    function proposalTarget(address tokenAddress, uint256 proposalId)
        external
        view
        returns (address target, TargetMode targetMode)
    {
        _checkExistingProposal(tokenAddress, proposalId);
        ProposalBody storage body = _proposals[tokenAddress][proposalId - PROPOSAL_ID_TO_INDEX_OFFSET].body;
        return (body.target, body.targetMode);
    }

    function proposalInfosByProposalIds(
        address tokenAddress,
        uint256[] calldata requestedProposalIds
    ) external view returns (ProposalInfo[] memory) {
        ProposalInfo[] memory infos = new ProposalInfo[](requestedProposalIds.length);
        for (uint256 i = 0; i < requestedProposalIds.length; i++) {
            _checkExistingProposal(tokenAddress, requestedProposalIds[i]);
            infos[i] = _proposals[tokenAddress][requestedProposalIds[i] - PROPOSAL_ID_TO_INDEX_OFFSET];
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

    function submitInfosByTarget(
        address tokenAddress,
        uint256 round,
        address target,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (SubmitInfo[] memory submitInfoList, uint256 totalCount) {
        SubmitInfo[] storage infos = _submitInfosByTarget[tokenAddress][round][target];
        totalCount = infos.length;
        uint256[] memory indices = Pagination.paginateIndices(totalCount, offset, limit, reverse);
        submitInfoList = new SubmitInfo[](indices.length);
        for (uint256 i = 0; i < indices.length; i++) {
            submitInfoList[i] = infos[indices[i]];
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

    function _checkProposalBody(ProposalBody calldata proposalBody) internal view {
        uint256 titleLength = bytes(proposalBody.title).length;
        if (titleLength == 0) revert TitleEmpty();
        if (titleLength > MAX_TITLE_LENGTH) revert TitleTooLong(titleLength, MAX_TITLE_LENGTH);

        uint256 detailsLength = bytes(proposalBody.details).length;
        if (detailsLength > MAX_DETAILS_LENGTH) revert DetailsTooLong(detailsLength, MAX_DETAILS_LENGTH);

        if (proposalBody.creationData.length > MAX_CREATION_DATA_BYTES) {
            revert CreationDataTooLarge(proposalBody.creationData.length, MAX_CREATION_DATA_BYTES);
        }

        if (proposalBody.target == address(0)) revert ZeroTargetAddress();
        if (proposalBody.targetMode == TargetMode.Callback && proposalBody.target.code.length == 0) {
            revert CallbackTargetNotContract(proposalBody.target);
        }
    }

    function _createProposal(
        address tokenAddress,
        uint256 memberId,
        ProposalBody calldata proposalBody
    ) internal returns (uint256 proposalId) {
        proposalId = _proposals[tokenAddress].length + 1;
        ProposalHead memory head = ProposalHead({
            id: proposalId,
            author: memberId,
            createAtBlock: block.number
        });

        _proposals[tokenAddress].push(ProposalInfo({head: head, body: proposalBody}));
        _proposalIdsByTarget[tokenAddress][proposalBody.target].push(proposalId);
        _proposalIdsByAuthor[tokenAddress][memberId].push(proposalId);
        _proposalIdsByAuthorByTarget[tokenAddress][memberId][proposalBody.target].push(proposalId);

        emit ProposalCreated({
            tokenAddress: tokenAddress,
            proposalId: proposalId,
            authorId: memberId,
            target: proposalBody.target,
            targetMode: proposalBody.targetMode,
            creationData: proposalBody.creationData,
            title: proposalBody.title,
            details: proposalBody.details
        });

        return proposalId;
    }

    function _checkExistingProposal(address tokenAddress, uint256 proposalId) internal view {
        if (proposalId == 0 || proposalId > _proposals[tokenAddress].length) {
            // forge-lint: disable-next-line(require-revert-in-loop)
            revert ProposalNotFound(tokenAddress, proposalId);
        }
    }

    function _checkSubmitterQuota(
        address tokenAddress,
        uint256 round,
        uint256 memberId
    ) internal view {
        if (
            _submitInfoBySubmitterId[tokenAddress][round][memberId]
                .submitterId != 0
        ) revert MemberAlreadySubmitted(tokenAddress, round, memberId);
        if (_submits[tokenAddress][round].length >= SUBMIT_ROUND_LIMIT) {
            revert SubmitRoundFull(tokenAddress, round, SUBMIT_ROUND_LIMIT);
        }
    }

    function _recordSubmission(
        address tokenAddress,
        uint256 round,
        uint256 proposalId,
        uint256 memberId
    ) internal {
        SubmitInfo memory submitInfo = SubmitInfo(
            memberId,
            proposalId
        );

        _submits[tokenAddress][round].push(submitInfo);
        address target = _proposals[tokenAddress][proposalId - PROPOSAL_ID_TO_INDEX_OFFSET].body.target;
        _submitInfosByTarget[tokenAddress][round][target].push(submitInfo);
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

        if (isFirstSubmit) {
            // forge-lint: disable-next-item(unused-return)
            IPhase(PHASE_ADDRESS).sync();
        }
    }
}
