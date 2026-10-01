// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Submit} from "../src/Submit.sol";
import {Phase} from "../src/Phase.sol";
import {ISubmitErrors, ProposalBody, ProposalInfo, SubmitInfo, TargetMode} from "../src/interfaces/ISubmit.sol";

interface SubmitVm {
    function roll(uint256 blockNumber) external;
    function warp(uint256 timestamp) external;
    function prank(address) external;
    function expectRevert(bytes calldata) external;
    function pauseGasMetering() external;
    function resumeGasMetering() external;
}

contract MockStake {
    mapping(address => mapping(uint256 => uint256)) private _validVotes;
    mapping(address => uint256) private _globalVotes;

    function setValidGovVotes(address token, uint256 memberId, uint256 votes) external {
        _validVotes[token][memberId] = votes;
    }

    function setGlobalGovVotes(address token, uint256 votes) external {
        _globalVotes[token] = votes;
    }

    function validGovVotes(address token, uint256 memberId) external view returns (uint256) {
        return _validVotes[token][memberId];
    }

    function globalGovVotes(address token) external view returns (uint256) {
        return _globalVotes[token];
    }
}

contract MockMemberNFT {
    mapping(uint256 => address) private _owners;

    function setOwner(uint256 tokenId, address owner) external {
        _owners[tokenId] = owner;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _owners[tokenId];
    }
}

contract MockTarget {
    uint256 public lastCreatedProposalId;
    uint256 public lastSubmittedProposalId;
    uint256 public lastSubmitterId;
    address public lastTokenAddress;

    function onProposalCreated(address tokenAddress, uint256 proposalId, bytes[] calldata) external {
        lastTokenAddress = tokenAddress;
        lastCreatedProposalId = proposalId;
    }

    function onProposalSubmitted(address tokenAddress, uint256 proposalId, uint256 submitterId, bytes[] calldata) external {
        lastTokenAddress = tokenAddress;
        lastSubmittedProposalId = proposalId;
        lastSubmitterId = submitterId;
    }
}

contract SubmitTest {
    SubmitVm private constant vm = SubmitVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant TOKEN = address(0xBEEF);
    address private constant TOKEN2 = address(0xCAFE);
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    Phase private phase;
    Submit private submit;
    MockStake private stake;
    MockMemberNFT private memberNFT;

    function setUp() public {
        vm.roll(100);
        vm.warp(1000);
        phase = new Phase(100, 100, 1000, 1e17, 10);
        stake = new MockStake();
        memberNFT = new MockMemberNFT();
        submit = new Submit();
        submit.init(address(phase), address(stake), address(memberNFT), 10);

        // Setup default member ownership and voting power
        memberNFT.setOwner(1, address(this));
        memberNFT.setOwner(2, ALICE);
        memberNFT.setOwner(3, BOB);
        stake.setValidGovVotes(TOKEN, 1, 100);
        stake.setGlobalGovVotes(TOKEN, 1000);
    }

    // ============ Initialization Tests ============

    function testInitSuccess() external view {
        require(submit.initialized(), "not initialized");
        require(submit.phaseAddress() == address(phase), "wrong phase");
        require(submit.stakeAddress() == address(stake), "wrong stake");
        require(submit.memberNFTAddress() == address(memberNFT), "wrong memberNFT");
        require(submit.SUBMIT_MIN_PER_THOUSAND() == 10, "wrong threshold");
    }

    function testInitCannotReinitialize() external {
        Submit newSubmit = new Submit();
        newSubmit.init(address(phase), address(stake), address(memberNFT), 10);
        bytes memory expected = abi.encodeWithSelector(ISubmitErrors.AlreadyInitialized.selector);
        (bool ok, bytes memory data) = address(newSubmit).call(
            abi.encodeCall(newSubmit.init, (address(phase), address(stake), address(memberNFT), 10))
        );
        require(!ok && keccak256(data) == keccak256(expected), "should revert AlreadyInitialized");
    }

    function testInitRejectsZeroAddresses() external {
        Submit newSubmit = new Submit();
        bytes memory expected = abi.encodeWithSelector(ISubmitErrors.InvalidAddress.selector);

        (bool ok, bytes memory data) = address(newSubmit).call(
            abi.encodeCall(newSubmit.init, (address(0), address(stake), address(memberNFT), 10))
        );
        require(!ok && keccak256(data) == keccak256(expected), "should reject zero phase");

        newSubmit = new Submit();
        (ok, data) = address(newSubmit).call(
            abi.encodeCall(newSubmit.init, (address(phase), address(0), address(memberNFT), 10))
        );
        require(!ok && keccak256(data) == keccak256(expected), "should reject zero stake");

        newSubmit = new Submit();
        (ok, data) = address(newSubmit).call(
            abi.encodeCall(newSubmit.init, (address(phase), address(stake), address(0), 10))
        );
        require(!ok && keccak256(data) == keccak256(expected), "should reject zero memberNFT");
    }

    function testInitRejectsInvalidThreshold() external {
        Submit newSubmit = new Submit();
        bytes memory expectedZero = abi.encodeWithSelector(ISubmitErrors.ZeroAmount.selector, "submitMinPerThousand");
        (bool ok, bytes memory data) = address(newSubmit).call(
            abi.encodeCall(newSubmit.init, (address(phase), address(stake), address(memberNFT), 0))
        );
        require(!ok && keccak256(data) == keccak256(expectedZero), "should reject zero threshold");

        newSubmit = new Submit();
        bytes memory expectedInvalid = abi.encodeWithSelector(ISubmitErrors.InvalidAmount.selector);
        (ok, data) = address(newSubmit).call(
            abi.encodeCall(newSubmit.init, (address(phase), address(stake), address(memberNFT), 1001))
        );
        require(!ok && keccak256(data) == keccak256(expectedInvalid), "should reject threshold > 1000");
    }

    // ============ Permission Tests ============

    function testCanSubmitWithSufficientVotes() external view {
        require(submit.canSubmit(TOKEN, 1), "should be able to submit");
    }

    function testCannotSubmitWithInsufficientVotes() external {
        stake.setValidGovVotes(TOKEN, 1, 9);
        require(!submit.canSubmit(TOKEN, 1), "should not be able to submit");
    }

    function testCannotSubmitWithZeroGlobalVotes() external {
        stake.setGlobalGovVotes(TOKEN, 0);
        require(!submit.canSubmit(TOKEN, 1), "should not submit with zero global");
    }

    function testCannotSubmitWithZeroValidVotes() external {
        stake.setValidGovVotes(TOKEN, 1, 0);
        require(!submit.canSubmit(TOKEN, 1), "should not submit with zero valid");
    }

    function testCanSubmitExactThreshold() external {
        stake.setValidGovVotes(TOKEN, 1, 10);
        require(submit.canSubmit(TOKEN, 1), "should submit at exact threshold");
    }

    // ============ Proposal Creation Tests ============

    function testSubmitNewProposalSuccess() external {
        ProposalBody memory body = ProposalBody({
            title: "Test Proposal",
            details: "Detailed description",
            target: address(0x1),
            targetMode: TargetMode.NoCallback,
            targetData: new bytes[](0)
        });
        uint256 proposalId = submit.submitNewProposal(TOKEN, 1, body);
        require(proposalId == 1, "wrong proposal id");
        require(submit.isSubmitted(TOKEN, 1, proposalId), "not submitted");
    }

    function testSubmitNewProposalWithCallback() external {
        MockTarget target = new MockTarget();
        ProposalBody memory body = ProposalBody({
            title: "Callback Proposal",
            details: "With callback",
            target: address(target),
            targetMode: TargetMode.Callback,
            targetData: new bytes[](0)
        });
        uint256 proposalId = submit.submitNewProposal(TOKEN, 1, body);
        require(target.lastCreatedProposalId() == proposalId, "callback not called on create");
        require(target.lastSubmittedProposalId() == proposalId, "callback not called on submit");
        require(target.lastSubmitterId() == 1, "wrong submitter in callback");
    }

    function testSubmitNewProposalRejectsEmptyTitle() external {
        ProposalBody memory body = ProposalBody({
            title: "",
            details: "Details",
            target: address(0x1),
            targetMode: TargetMode.NoCallback,
            targetData: new bytes[](0)
        });
        bytes memory expected = abi.encodeWithSelector(ISubmitErrors.EmptyString.selector, "title");
        (bool ok, bytes memory data) = address(submit).call(
            abi.encodeCall(submit.submitNewProposal, (TOKEN, 1, body))
        );
        require(!ok && keccak256(data) == keccak256(expected), "should reject empty title");
    }

    function testSubmitNewProposalRejectsZeroTarget() external {
        ProposalBody memory body = ProposalBody({
            title: "Test",
            details: "Details",
            target: address(0),
            targetMode: TargetMode.NoCallback,
            targetData: new bytes[](0)
        });
        bytes memory expected = abi.encodeWithSelector(ISubmitErrors.InvalidAddress.selector);
        (bool ok, bytes memory data) = address(submit).call(
            abi.encodeCall(submit.submitNewProposal, (TOKEN, 1, body))
        );
        require(!ok && keccak256(data) == keccak256(expected), "should reject zero target");
    }

    function testSubmitNewProposalRejectsCallbackToEOA() external {
        ProposalBody memory body = ProposalBody({
            title: "Bad Callback",
            details: "EOA target",
            target: address(0x1),
            targetMode: TargetMode.Callback,
            targetData: new bytes[](0)
        });
        bytes memory expected = abi.encodeWithSelector(ISubmitErrors.InvalidTargetMode.selector);
        (bool ok, bytes memory data) = address(submit).call(
            abi.encodeCall(submit.submitNewProposal, (TOKEN, 1, body))
        );
        require(!ok && keccak256(data) == keccak256(expected), "should reject callback to EOA");
    }

    function testSubmitNewProposalRejectsNonOwner() external {
        ProposalBody memory body = ProposalBody({
            title: "Test",
            details: "Details",
            target: address(0x1),
            targetMode: TargetMode.NoCallback,
            targetData: new bytes[](0)
        });
        bytes memory expected = abi.encodeWithSelector(ISubmitErrors.NotMemberOwner.selector, 2);
        (bool ok, bytes memory data) = address(submit).call(
            abi.encodeCall(submit.submitNewProposal, (TOKEN, 2, body))
        );
        require(!ok && keccak256(data) == keccak256(expected), "should reject non-owner");
    }

    function testSubmitNewProposalRejectsInsufficientVotes() external {
        stake.setValidGovVotes(TOKEN, 1, 9);
        ProposalBody memory body = ProposalBody({
            title: "Test",
            details: "Details",
            target: address(0x1),
            targetMode: TargetMode.NoCallback,
            targetData: new bytes[](0)
        });
        bytes memory expected = abi.encodeWithSelector(ISubmitErrors.CannotSubmitAction.selector);
        (bool ok, bytes memory data) = address(submit).call(
            abi.encodeCall(submit.submitNewProposal, (TOKEN, 1, body))
        );
        require(!ok && keccak256(data) == keccak256(expected), "should reject insufficient votes");
    }

    // ============ Proposal Submission Tests ============

    function testOneBasedProposalIdsAcrossCreateReadAndResubmit() external {
        MockTarget target = new MockTarget();
        ProposalBody memory body = ProposalBody("first", "", address(target), TargetMode.Callback, new bytes[](0));
        require(submit.submitNewProposal(TOKEN, 1, body) == 1, "first id");
        require(target.lastCreatedProposalId() == 1 && target.lastSubmittedProposalId() == 1, "first callbacks");
        require(submit.proposalIdBySubmitter(TOKEN, 1, 1) == 1, "submitted member");
        require(submit.proposalIdBySubmitter(TOKEN, 1, 2) == 0, "absent member");
        require(!submit.isSubmitted(TOKEN, 1, 0) && submit.submitterIdByProposalId(TOKEN, 1, 0) == 0, "zero sentinel");

        vm.roll(200);
        stake.setValidGovVotes(TOKEN, 2, 100);
        memberNFT.setOwner(2, address(this));
        body.title = "second";
        require(submit.submitNewProposal(TOKEN, 2, body) == 2, "next id");
        require(target.lastCreatedProposalId() == 2 && target.lastSubmittedProposalId() == 2, "last callbacks");

        vm.roll(300);
        submit.submit(TOKEN, 1, 1);
        require(target.lastCreatedProposalId() == 2 && target.lastSubmittedProposalId() == 1, "resubmit callback");
        require(submit.proposalIdBySubmitter(TOKEN, 3, 1) == 1, "resubmit lookup");
        require(submit.submitterIdByProposalId(TOKEN, 3, 1) == 1, "reverse lookup");

        (uint256[] memory ids, uint256 count) = submit.proposalIds(TOKEN, 0, 10, false);
        require(count == 2 && ids.length == 2 && ids[0] == 1 && ids[1] == 2, "ids and count");
        (ids, count) = submit.proposalIdsByAuthor(TOKEN, 1, 0, 10, true);
        require(count == 1 && ids.length == 1 && ids[0] == 1, "author ids");
        (ids, count) = submit.proposalIdsByAuthor(TOKEN, 2, 0, 10, false);
        require(count == 1 && ids.length == 1 && ids[0] == 2, "author 2 ids");
        ProposalInfo[] memory infos = submit.proposalInfosByIds(TOKEN, ids);
        require(infos[0].head.id == 2 && keccak256(bytes(infos[0].body.title)) == keccak256("second"), "last detail");
        (SubmitInfo[] memory records, uint256 total) = submit.submitInfos(TOKEN, 3, 0, 10, false);
        require(total == 1 && records[0].proposalId == 1, "submission ids");

        ids = new uint256[](1);
        for (uint256 i = 0; i < 3; i++) {
            ids[0] = i == 0 ? 0 : (i == 1 ? 3 : type(uint256).max);
            bytes32 expected = keccak256(abi.encodeWithSelector(ISubmitErrors.ProposalNotFound.selector, ids[0]));
            (bool ok, bytes memory data) = address(submit).call(abi.encodeCall(submit.proposalInfosByIds, (TOKEN, ids)));
            require(!ok && keccak256(data) == expected, "missing detail");
            (ok, data) = address(submit).call(abi.encodeCall(submit.submit, (TOKEN, 1, ids[0])));
            require(!ok && keccak256(data) == expected, "missing submission");
        }
    }

    function testProposalTargetMatchesTheRecordAndRejectsUnassignedIds() external {
        MockTarget target = new MockTarget();
        ProposalBody memory body = ProposalBody("first", "", address(target), TargetMode.Callback, new bytes[](0));
        require(submit.submitNewProposal(TOKEN, 1, body) == 1, "first id");

        (address stored, TargetMode mode) = submit.proposalTarget(TOKEN, 1);
        require(stored == address(target) && mode == TargetMode.Callback, "callback target");

        vm.roll(200);
        stake.setValidGovVotes(TOKEN, 2, 100);
        memberNFT.setOwner(2, address(this));
        ProposalBody memory noCallback =
            ProposalBody("second", "", address(0xE1E1), TargetMode.NoCallback, new bytes[](0));
        require(submit.submitNewProposal(TOKEN, 2, noCallback) == 2, "next id");
        (stored, mode) = submit.proposalTarget(TOKEN, 2);
        require(stored == address(0xE1E1) && mode == TargetMode.NoCallback, "no callback target");

        uint256[] memory ids = new uint256[](2);
        ids[0] = 2;
        ids[1] = 1;
        ProposalInfo[] memory infos = submit.proposalInfosByIds(TOKEN, ids);
        for (uint256 i = 0; i < ids.length; i++) {
            (address fromRecord, TargetMode modeFromRecord) = submit.proposalTarget(TOKEN, ids[i]);
            require(fromRecord == infos[i].body.target, "target agrees with the record");
            require(modeFromRecord == infos[i].body.targetMode, "mode agrees with the record");
        }

        uint256[3] memory missing;
        missing[0] = 0;
        missing[1] = 3;
        missing[2] = type(uint256).max;
        for (uint256 i = 0; i < missing.length; i++) {
            bytes32 expected = keccak256(abi.encodeWithSelector(ISubmitErrors.ProposalNotFound.selector, missing[i]));
            (bool ok, bytes memory data) = address(submit).call(abi.encodeCall(submit.proposalTarget, (TOKEN, missing[i])));
            require(!ok && keccak256(data) == expected, "missing target");
        }
    }

    function testSubmitExistingProposal() external {
        ProposalBody memory body = ProposalBody({
            title: "Test",
            details: "Details",
            target: address(0x1),
            targetMode: TargetMode.NoCallback,
            targetData: new bytes[](0)
        });
        uint256 proposalId = submit.submitNewProposal(TOKEN, 1, body);

        vm.roll(200);
        stake.setValidGovVotes(TOKEN, 2, 100);
        memberNFT.setOwner(2, address(this));
        submit.submit(TOKEN, 2, proposalId);
        require(submit.isSubmitted(TOKEN, 2, proposalId), "not submitted in round 2");
        require(submit.proposalIdBySubmitter(TOKEN, 2, 2) == proposalId, "wrong lookup");
    }

    function testSubmitRejectsNonExistentProposal() external {
        bytes memory expected = abi.encodeWithSelector(ISubmitErrors.ProposalNotFound.selector, 999);
        (bool ok, bytes memory data) = address(submit).call(
            abi.encodeCall(submit.submit, (TOKEN, 1, 999))
        );
        require(!ok && keccak256(data) == keccak256(expected), "should reject non-existent proposal");
    }

    function testSubmitRejectsAlreadySubmittedProposal() external {
        ProposalBody memory body = ProposalBody({
            title: "Test",
            details: "Details",
            target: address(0x1),
            targetMode: TargetMode.NoCallback,
            targetData: new bytes[](0)
        });
        uint256 proposalId = submit.submitNewProposal(TOKEN, 1, body);

        stake.setValidGovVotes(TOKEN, 2, 100);
        memberNFT.setOwner(2, address(this));
        bytes memory expected = abi.encodeWithSelector(ISubmitErrors.AlreadySubmitted.selector);
        (bool ok, bytes memory data) = address(submit).call(
            abi.encodeCall(submit.submit, (TOKEN, 2, proposalId))
        );
        require(!ok && keccak256(data) == keccak256(expected), "should reject already submitted");
    }

    function testSubmitRejectsMultipleSubmissionsPerRound() external {
        // Create proposal 1 with member 1 (creates and submits in round 1)
        ProposalBody memory body = ProposalBody({
            title: "First",
            details: "Details",
            target: address(0x1),
            targetMode: TargetMode.NoCallback,
            targetData: new bytes[](0)
        });
        submit.submitNewProposal(TOKEN, 1, body);

        // Create proposal 2 with member 2 (creates but doesn't submit yet)
        body.title = "Second";
        stake.setValidGovVotes(TOKEN, 2, 100);
        memberNFT.setOwner(2, address(this));

        // We can't use submitNewProposal here because it auto-submits
        // Instead, we need to move to next round, create the proposal there,
        // then come back to round 1 to test the duplicate submission
        vm.roll(200); // Move to round 2
        uint256 proposalId2 = submit.submitNewProposal(TOKEN, 2, body);

        // Roll back to round 1
        vm.roll(100);

        // Member 1 already submitted proposal 1 in round 1, try to submit proposal 2 in the same round
        bytes memory expected = abi.encodeWithSelector(ISubmitErrors.OnlyOneSubmitPerRound.selector);
        (bool ok, bytes memory data) = address(submit).call(
            abi.encodeCall(submit.submit, (TOKEN, 1, proposalId2))
        );
        require(!ok && keccak256(data) == keccak256(expected), "should reject second submission in same round");
    }

    function testSubmitRejectsNonOwner() external {
        ProposalBody memory body = ProposalBody({
            title: "Test",
            details: "Details",
            target: address(0x1),
            targetMode: TargetMode.NoCallback,
            targetData: new bytes[](0)
        });
        uint256 proposalId = submit.submitNewProposal(TOKEN, 1, body);

        vm.roll(200);
        bytes memory expected = abi.encodeWithSelector(ISubmitErrors.NotMemberOwner.selector, 2);
        (bool ok, bytes memory data) = address(submit).call(
            abi.encodeCall(submit.submit, (TOKEN, 2, proposalId))
        );
        require(!ok && keccak256(data) == keccak256(expected), "should reject non-owner");
    }

    function testSubmitRejectsInsufficientVotes() external {
        ProposalBody memory body = ProposalBody({
            title: "Test",
            details: "Details",
            target: address(0x1),
            targetMode: TargetMode.NoCallback,
            targetData: new bytes[](0)
        });
        uint256 proposalId = submit.submitNewProposal(TOKEN, 1, body);

        vm.roll(200);
        stake.setValidGovVotes(TOKEN, 1, 9);
        bytes memory expected = abi.encodeWithSelector(ISubmitErrors.CannotSubmitAction.selector);
        (bool ok, bytes memory data) = address(submit).call(
            abi.encodeCall(submit.submit, (TOKEN, 1, proposalId))
        );
        require(!ok && keccak256(data) == keccak256(expected), "should reject insufficient votes");
    }

    // ============ Query Function Tests ============

    function testProposalIdsWithPagination() external {
        ProposalBody memory body = ProposalBody({
            title: "Proposal",
            details: "Details",
            target: address(0x1),
            targetMode: TargetMode.NoCallback,
            targetData: new bytes[](0)
        });

        uint256 currentBlock = block.number;
        for (uint256 i = 0; i < 5; i++) {
            submit.submitNewProposal(TOKEN, 1, body);
            currentBlock += 100;
            vm.roll(currentBlock);
        }

        (uint256[] memory ids, uint256 count) = submit.proposalIds(TOKEN, 0, 3, false);
        require(count == 5 && ids.length == 3, "wrong page 1 size");
        require(ids[0] == 1 && ids[1] == 2 && ids[2] == 3, "wrong page 1 ids");

        (ids, count) = submit.proposalIds(TOKEN, 3, 3, false);
        require(count == 5 && ids.length == 2, "wrong page 2 size");
        require(ids[0] == 4 && ids[1] == 5, "wrong page 2 ids");

        (ids, count) = submit.proposalIds(TOKEN, 0, 10, true);
        require(ids.length == 5 && ids[0] == 5 && ids[4] == 1, "wrong reverse order");
    }

    function testProposalIdsEmptyResults() external view {
        (uint256[] memory ids, uint256 count) = submit.proposalIds(TOKEN, 0, 10, false);
        require(count == 0 && ids.length == 0, "should be empty");

        (ids, count) = submit.proposalIds(TOKEN, 100, 10, false);
        require(count == 0 && ids.length == 0, "offset beyond range");

        (ids, count) = submit.proposalIds(TOKEN, 0, 0, false);
        require(count == 0 && ids.length == 0, "zero limit");
    }

    function testProposalIdsByAuthor() external {
        ProposalBody memory body = ProposalBody({
            title: "Proposal",
            details: "Details",
            target: address(0x1),
            targetMode: TargetMode.NoCallback,
            targetData: new bytes[](0)
        });

        submit.submitNewProposal(TOKEN, 1, body);
        vm.roll(200);
        submit.submitNewProposal(TOKEN, 1, body);

        stake.setValidGovVotes(TOKEN, 2, 100);
        memberNFT.setOwner(2, address(this));
        vm.roll(300);
        submit.submitNewProposal(TOKEN, 2, body);

        (uint256[] memory ids, uint256 count) = submit.proposalIdsByAuthor(TOKEN, 1, 0, 10, false);
        require(count == 2 && ids.length == 2 && ids[0] == 1 && ids[1] == 2, "author 1 proposals");

        (ids, count) = submit.proposalIdsByAuthor(TOKEN, 2, 0, 10, false);
        require(count == 1 && ids.length == 1 && ids[0] == 3, "author 2 proposals");

        (ids, count) = submit.proposalIdsByAuthor(TOKEN, 999, 0, 10, false);
        require(count == 0 && ids.length == 0, "non-existent author");
    }

    function testSubmitInfosQuery() external {
        ProposalBody memory body = ProposalBody({
            title: "Proposal",
            details: "Details",
            target: address(0x1),
            targetMode: TargetMode.NoCallback,
            targetData: new bytes[](0)
        });

        uint256 p1 = submit.submitNewProposal(TOKEN, 1, body);

        stake.setValidGovVotes(TOKEN, 2, 100);
        memberNFT.setOwner(2, address(this));
        uint256 p2 = submit.submitNewProposal(TOKEN, 2, body);

        (SubmitInfo[] memory infos, uint256 count) = submit.submitInfos(TOKEN, 1, 0, 10, false);
        require(count == 2 && infos.length == 2, "wrong count");
        require(infos[0].submitterId == 1 && infos[0].proposalId == p1, "wrong first submit");
        require(infos[1].submitterId == 2 && infos[1].proposalId == p2, "wrong second submit");

        (infos, count) = submit.submitInfos(TOKEN, 1, 0, 10, true);
        require(infos[0].submitterId == 2 && infos[1].submitterId == 1, "wrong reverse order");
    }

    function testLookupMappings() external {
        ProposalBody memory body = ProposalBody({
            title: "Test",
            details: "Details",
            target: address(0x1),
            targetMode: TargetMode.NoCallback,
            targetData: new bytes[](0)
        });
        uint256 proposalId = submit.submitNewProposal(TOKEN, 1, body);

        require(submit.proposalIdBySubmitter(TOKEN, 1, 1) == proposalId, "wrong proposalId by submitter");
        require(submit.submitterIdByProposalId(TOKEN, 1, proposalId) == 1, "wrong submitterId by proposal");
        require(submit.proposalIdBySubmitter(TOKEN, 1, 999) == 0, "non-existent submitter");
        require(submit.submitterIdByProposalId(TOKEN, 1, 999) == 0, "non-existent proposal");
    }

    // ============ Multi-Token Tests ============

    function testMultipleTokensIndependent() external {
        ProposalBody memory body = ProposalBody({
            title: "Token1 Proposal",
            details: "Details",
            target: address(0x1),
            targetMode: TargetMode.NoCallback,
            targetData: new bytes[](0)
        });

        stake.setGlobalGovVotes(TOKEN, 1000);
        stake.setValidGovVotes(TOKEN, 1, 100);
        uint256 p1 = submit.submitNewProposal(TOKEN, 1, body);

        vm.roll(200);
        stake.setGlobalGovVotes(TOKEN2, 1000);
        stake.setValidGovVotes(TOKEN2, 1, 100);
        body.title = "Token2 Proposal";
        uint256 p2 = submit.submitNewProposal(TOKEN2, 1, body);

        require(p1 == 1 && p2 == 1, "both should be id 1");
        require(submit.isSubmitted(TOKEN, 1, p1), "token1 submitted");
        require(submit.isSubmitted(TOKEN2, 2, p2), "token2 submitted");
        require(!submit.isSubmitted(TOKEN, 2, p2), "token1 not submitted for p2");

        (uint256[] memory ids1,) = submit.proposalIds(TOKEN, 0, 10, false);
        (uint256[] memory ids2,) = submit.proposalIds(TOKEN2, 0, 10, false);
        require(ids1.length == 1 && ids2.length == 1, "independent proposal lists");
    }

    // ============ Phase Integration Tests ============

    function testSubmitUsesSharedPhaseAfterCalibration() external {
        ProposalBody memory body = ProposalBody("first", "", address(0x1), TargetMode.NoCallback, new bytes[](0));
        uint256 id = submit.submitNewProposal(TOKEN, 1, body);
        vm.roll(201);
        vm.warp(1505);
        require(submit.currentRound() == 2, "round before sync");

        stake.setValidGovVotes(TOKEN, 2, 100);
        memberNFT.setOwner(2, address(this));
        submit.submit(TOKEN, 2, id);
        require(submit.currentRound() == 2 && phase.currentPhase() == 2, "current round unchanged");
        (uint256 start, uint256 length) = phase.phaseInfo(3);
        require(start == 300 && length == 200, "future phase calibrated");

        vm.roll(400);
        vm.warp(2500);
        require(phase.currentPhase() == 3 && submit.currentRound() == 3, "shared calibrated round");
        submit.submit(TOKEN, 1, id);
        require(submit.isSubmitted(TOKEN, 3, id), "submission in calibrated round");
        require(!submit.isSubmitted(TOKEN, 4, id), "no future submission");
    }

    function testCurrentRoundMatchesPhase() external view {
        require(submit.currentRound() == phase.currentPhase(), "round should match phase");
    }

    function testFirstSubmitTriggersPhaseSync() external {
        ProposalBody memory body = ProposalBody({
            title: "First",
            details: "Details",
            target: address(0x1),
            targetMode: TargetMode.NoCallback,
            targetData: new bytes[](0)
        });

        vm.roll(201);
        vm.warp(1505);
        uint256 phaseBefore = phase.currentPhase();
        submit.submitNewProposal(TOKEN, 1, body);
        uint256 phaseAfter = phase.currentPhase();
        require(phaseAfter >= phaseBefore, "phase should sync");
    }

    // ============ Edge Case Tests ============

    function testProposalIdIncrementsCorrectly() external {
        ProposalBody memory body = ProposalBody({
            title: "Proposal",
            details: "Details",
            target: address(0x1),
            targetMode: TargetMode.NoCallback,
            targetData: new bytes[](0)
        });

        uint256 currentBlock = block.number;
        for (uint256 i = 1; i <= 10; i++) {
            uint256 proposalId = submit.submitNewProposal(TOKEN, 1, body);
            require(proposalId == i, "wrong proposal id");
            currentBlock += 100;
            vm.roll(currentBlock);
        }
    }

    function testCanResubmitAcrossMultipleRounds() external {
        ProposalBody memory body = ProposalBody({
            title: "Test",
            details: "Details",
            target: address(0x1),
            targetMode: TargetMode.NoCallback,
            targetData: new bytes[](0)
        });
        uint256 proposalId = submit.submitNewProposal(TOKEN, 1, body);

        uint256 currentBlock = block.number;
        for (uint256 round = 2; round <= 5; round++) {
            currentBlock += 100;
            vm.roll(currentBlock);
            submit.submit(TOKEN, 1, proposalId);
            require(submit.isSubmitted(TOKEN, round, proposalId), "not submitted in round");
            require(submit.proposalIdBySubmitter(TOKEN, round, 1) == proposalId, "wrong lookup");
        }
    }

    function testDifferentMembersCanSubmitSameProposal() external {
        ProposalBody memory body = ProposalBody({
            title: "Test",
            details: "Details",
            target: address(0x1),
            targetMode: TargetMode.NoCallback,
            targetData: new bytes[](0)
        });
        uint256 proposalId = submit.submitNewProposal(TOKEN, 1, body);

        vm.roll(200);
        stake.setValidGovVotes(TOKEN, 2, 100);
        memberNFT.setOwner(2, address(this));
        submit.submit(TOKEN, 2, proposalId);

        require(submit.proposalIdBySubmitter(TOKEN, 1, 1) == proposalId, "member 1 submission");
        require(submit.proposalIdBySubmitter(TOKEN, 2, 2) == proposalId, "member 2 submission");
    }

    function testProposalWithLargeData() external {
        bytes[] memory largeData = new bytes[](10);
        for (uint256 i = 0; i < 10; i++) {
            largeData[i] = abi.encodePacked(i, i, i);
        }
        ProposalBody memory body = ProposalBody({
            title: "Large Data Proposal",
            details: "With large target data",
            target: address(0x1),
            targetMode: TargetMode.NoCallback,
            targetData: largeData
        });
        uint256 proposalId = submit.submitNewProposal(TOKEN, 1, body);
        require(proposalId == 1, "should create proposal with large data");

        ProposalInfo[] memory infos = submit.proposalInfosByIds(TOKEN, _asSingletonArray(proposalId));
        require(infos[0].body.targetData.length == 10, "data not preserved");
    }

    function testProposalWithLongStrings() external {
        string memory longTitle = "This is a very long title that contains a lot of text to test the string handling capabilities";
        string memory longDetails = "This is an extremely long details section that would typically contain a comprehensive description of the proposal including all the necessary information that voters would need to make an informed decision about whether to support or reject this particular proposal";

        ProposalBody memory body = ProposalBody({
            title: longTitle,
            details: longDetails,
            target: address(0x1),
            targetMode: TargetMode.NoCallback,
            targetData: new bytes[](0)
        });
        uint256 proposalId = submit.submitNewProposal(TOKEN, 1, body);

        ProposalInfo[] memory infos = submit.proposalInfosByIds(TOKEN, _asSingletonArray(proposalId));
        require(
            keccak256(bytes(infos[0].body.title)) == keccak256(bytes(longTitle)),
            "title not preserved"
        );
        require(
            keccak256(bytes(infos[0].body.details)) == keccak256(bytes(longDetails)),
            "details not preserved"
        );
    }

    function testBlockNumberRecordedCorrectly() external {
        ProposalBody memory body = ProposalBody({
            title: "Test",
            details: "Details",
            target: address(0x1),
            targetMode: TargetMode.NoCallback,
            targetData: new bytes[](0)
        });

        uint256 currentBlock = block.number;
        uint256 proposalId = submit.submitNewProposal(TOKEN, 1, body);

        ProposalInfo[] memory infos = submit.proposalInfosByIds(TOKEN, _asSingletonArray(proposalId));
        require(infos[0].head.createAtBlock == currentBlock, "wrong block number");
    }

    function testAuthorRecordedCorrectly() external {
        ProposalBody memory body = ProposalBody({
            title: "Test",
            details: "Details",
            target: address(0x1),
            targetMode: TargetMode.NoCallback,
            targetData: new bytes[](0)
        });

        uint256 proposalId = submit.submitNewProposal(TOKEN, 1, body);

        ProposalInfo[] memory infos = submit.proposalInfosByIds(TOKEN, _asSingletonArray(proposalId));
        require(infos[0].head.author == 1, "wrong author");
    }

    // ============ Boundary Value Tests ============

    function testSubmissionLimitPerTokenAndRound() external {
        ProposalBody memory body = ProposalBody("Proposal", "", address(0x1), TargetMode.NoCallback, new bytes[](0));
        uint256 oldProposalId = submit.submitNewProposal(TOKEN, 1, body);
        vm.roll(200);

        // These submissions represent separate transactions in the same round.
        vm.pauseGasMetering();
        for (uint256 memberId = 1; memberId <= 1000; memberId++) {
            memberNFT.setOwner(memberId, address(this));
            stake.setValidGovVotes(TOKEN, memberId, 100);
            submit.submitNewProposal(TOKEN, memberId, body);
        }
        vm.resumeGasMetering();

        memberNFT.setOwner(1001, address(this));
        stake.setValidGovVotes(TOKEN, 1001, 100);
        require(submit.canSubmit(TOKEN, 1001), "vote threshold still met");
        vm.expectRevert(abi.encodeWithSelector(ISubmitErrors.CannotSubmitAction.selector));
        submit.submitNewProposal(TOKEN, 1001, body);
        vm.expectRevert(abi.encodeWithSelector(ISubmitErrors.CannotSubmitAction.selector));
        submit.submit(TOKEN, 1001, oldProposalId);

        (, uint256 count) = submit.submitInfos(TOKEN, 2, 0, 0, false);
        require(count == 1000, "round limit");
        (, count) = submit.proposalIds(TOKEN, 0, 0, false);
        require(count == 1001, "failed creation rolled back");
        (, count) = submit.proposalIdsByAuthor(TOKEN, 1001, 0, 0, false);
        require(count == 0, "failed author index rolled back");
        require(submit.proposalIdBySubmitter(TOKEN, 2, 1001) == 0, "failed submission consumed no member slot");
        require(!submit.isSubmitted(TOKEN, 2, oldProposalId), "old proposal not submitted");

        stake.setGlobalGovVotes(TOKEN2, 1000);
        stake.setValidGovVotes(TOKEN2, 1001, 100);
        require(submit.submitNewProposal(TOKEN2, 1001, body) == 1, "other token independent");

        vm.roll(300);
        submit.submit(TOKEN, 1001, oldProposalId);
        require(submit.isSubmitted(TOKEN, 3, oldProposalId), "old proposal accepted next round");
        require(submit.submitNewProposal(TOKEN, 1, body) == 1002, "new proposal accepted beyond history of 1000");
    }

    function testThresholdBoundaries() external {
        // Test exact threshold
        stake.setValidGovVotes(TOKEN, 1, 10);
        stake.setGlobalGovVotes(TOKEN, 1000);
        require(submit.canSubmit(TOKEN, 1), "should submit at exact threshold");

        // Test just below threshold
        stake.setValidGovVotes(TOKEN, 1, 9);
        require(!submit.canSubmit(TOKEN, 1), "should not submit below threshold");

        // Test just above threshold
        stake.setValidGovVotes(TOKEN, 1, 11);
        require(submit.canSubmit(TOKEN, 1), "should submit above threshold");
    }

    function testMaximumThreshold() external {
        Submit newSubmit = new Submit();
        newSubmit.init(address(phase), address(stake), address(memberNFT), 1000);
        stake.setValidGovVotes(TOKEN, 1, 1000);
        stake.setGlobalGovVotes(TOKEN, 1000);
        require(newSubmit.canSubmit(TOKEN, 1), "should submit at max threshold");
    }

    function testMinimumThreshold() external {
        Submit newSubmit = new Submit();
        newSubmit.init(address(phase), address(stake), address(memberNFT), 1);
        stake.setValidGovVotes(TOKEN, 1, 1);
        stake.setGlobalGovVotes(TOKEN, 1000);
        require(newSubmit.canSubmit(TOKEN, 1), "should submit at min threshold");
    }

    function testLargeVoteNumbers() external {
        stake.setValidGovVotes(TOKEN, 1, type(uint256).max / 1000);
        stake.setGlobalGovVotes(TOKEN, type(uint256).max / 1000);
        require(submit.canSubmit(TOKEN, 1), "should handle large numbers");
    }

    // ============ Gas Optimization Tests ============

    function testMultipleProposalsBatchQuery() external {
        ProposalBody memory body = ProposalBody({
            title: "Test",
            details: "Details",
            target: address(0x1),
            targetMode: TargetMode.NoCallback,
            targetData: new bytes[](0)
        });

        uint256[] memory ids = new uint256[](5);
        uint256 currentBlock = block.number;
        for (uint256 i = 0; i < 5; i++) {
            ids[i] = submit.submitNewProposal(TOKEN, 1, body);
            currentBlock += 100;
            vm.roll(currentBlock);
        }

        ProposalInfo[] memory infos = submit.proposalInfosByIds(TOKEN, ids);
        require(infos.length == 5, "wrong batch size");
        for (uint256 i = 0; i < 5; i++) {
            require(infos[i].head.id == ids[i], "wrong id in batch");
        }
    }

    // ============ Helper Functions ============

    function _asSingletonArray(uint256 element) private pure returns (uint256[] memory) {
        uint256[] memory array = new uint256[](1);
        array[0] = element;
        return array;
    }
}
