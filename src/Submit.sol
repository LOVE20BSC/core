// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IPhase} from "./interfaces/IPhase.sol";
import {IStake} from "./interfaces/IStake.sol";
import {IMemberNFT} from "./interfaces/IMemberNFT.sol";
import {ISubmit, ProposalHead, ProposalBody, ProposalInfo, SubmitInfo, TargetMode} from "./interfaces/ISubmit.sol";
import {IProposalTarget} from "./interfaces/IProposalTarget.sol";

import {Pagination} from "../lib/libs/src/Pagination.sol";

contract Submit is ISubmit {
    using Pagination for uint256[];
    bool public initialized;
    address public phaseAddress;
    address public stakeAddress;
    address public memberNFTAddress;
    uint256 public SUBMIT_MIN_PER_THOUSAND;

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
        return IPhase(phaseAddress).currentPhase();
    }

    function init(
        address phaseAddress_,
        address stakeAddress_,
        address memberNFTAddress_,
        uint256 submitMinPerThousand
    ) external {
        if (initialized) {
            revert AlreadyInitialized();
        }
        if (phaseAddress_ == address(0) || stakeAddress_ == address(0) || memberNFTAddress_ == address(0)) {
            revert InvalidAddress();
        }
        if (submitMinPerThousand == 0) {
            revert ZeroAmount("submitMinPerThousand");
        }
        if (submitMinPerThousand > 1000) {
            revert InvalidAmount();
        }
        initialized = true;
        phaseAddress = phaseAddress_;
        stakeAddress = stakeAddress_;
        memberNFTAddress = memberNFTAddress_;
        SUBMIT_MIN_PER_THOUSAND = submitMinPerThousand;
    }

    function canSubmit(
        address tokenAddress,
        uint256 memberId
    ) public view returns (bool) {
        IStake stake = IStake(stakeAddress);
        uint256 validVotes = stake.validGovVotes(tokenAddress, memberId);
        uint256 total = stake.globalGovVotes(tokenAddress);

        if (total == 0) {
            return false;
        }
        if (validVotes == 0) {
            return false;
        }

        return ((validVotes * 1000) / total) >= SUBMIT_MIN_PER_THOUSAND;
    }

    function submitNewProposal(
        address tokenAddress,
        uint256 memberId,
        ProposalBody calldata proposalBody
    ) external returns (uint256 proposalId) {
        IMemberNFT memberNFT = IMemberNFT(memberNFTAddress);
        if (memberNFT.ownerOf(memberId) != msg.sender) {
            revert NotMemberOwner(memberId);
        }
        if (!canSubmit(tokenAddress, memberId)) revert CannotSubmitAction();

        proposalId = _createProposal(tokenAddress, memberId, proposalBody);

        _submitByProposalId(tokenAddress, memberId, proposalId);
        return proposalId;
    }

    function submit(address tokenAddress, uint256 memberId, uint256 proposalId) external {
        IMemberNFT memberNFT = IMemberNFT(memberNFTAddress);
        if (memberNFT.ownerOf(memberId) != msg.sender) {
            revert NotMemberOwner(memberId);
        }
        if (!canSubmit(tokenAddress, memberId)) revert CannotSubmitAction();

        _submitByProposalId(tokenAddress, memberId, proposalId);
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
        // proposalInfosByIds.
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

    function proposalInfosByIds(
        address tokenAddress,
        uint256[] calldata ids
    ) external view returns (ProposalInfo[] memory) {
        ProposalInfo[] memory infos = new ProposalInfo[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == 0 || ids[i] > _proposals[tokenAddress].length) {
                // forge-lint: disable-next-line(require-revert-in-loop)
                revert ProposalNotFound(ids[i]);
            }
            infos[i] = _proposals[tokenAddress][ids[i] - 1];
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

    function proposalIdBySubmitter(
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

    function _createProposal(
        address tokenAddress,
        uint256 memberId,
        ProposalBody memory proposalBody
    ) internal returns (uint256 proposalId) {
        if (bytes(proposalBody.title).length == 0) revert EmptyString("title");
        if (proposalBody.target == address(0)) revert InvalidAddress();
        if (proposalBody.targetMode == TargetMode.Callback && proposalBody.target.code.length == 0) {
            revert InvalidTargetMode();
        }

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
            author: memberId,
            title: proposalBody.title,
            details: proposalBody.details,
            target: proposalBody.target,
            targetMode: proposalBody.targetMode
        });

        if (proposalBody.targetMode == TargetMode.Callback) {
            IProposalTarget(proposalBody.target).onProposalCreated(
                tokenAddress,
                proposalId,
                proposalBody.targetData
            );
        }

        return proposalId;
    }

    function _submitByProposalId(
        address tokenAddress,
        uint256 memberId,
        uint256 proposalId
    ) internal {
        // Checks
        if (proposalId == 0 || proposalId > _proposals[tokenAddress].length)
            revert ProposalNotFound(proposalId);

        uint256 round = currentRound();
        if (isSubmitted(tokenAddress, round, proposalId))
            revert AlreadySubmitted();
        if (
            _submitInfoBySubmitterId[tokenAddress][round][memberId]
                .submitterId != 0
        ) revert OnlyOneSubmitPerRound();

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
            IPhase(phaseAddress).sync();
        }

        ProposalBody memory body = _proposals[tokenAddress][proposalId - 1].body;
        if (body.targetMode == TargetMode.Callback) {
            IProposalTarget(body.target).onProposalSubmitted(
                tokenAddress,
                proposalId,
                memberId,
                body.targetData
            );
        }
    }
}
