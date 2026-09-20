// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Vote} from "../src/Vote.sol";
import {Phase} from "../src/Phase.sol";
import {Submit} from "../src/Submit.sol";
import {MemberNFT} from "../src/MemberNFT.sol";
import {LOVE20Token} from "../src/LOVE20Token.sol";
import {IPhase} from "../src/interfaces/IPhase.sol";
import {IVote, IVoteErrors, IVoteEvents} from "../src/interfaces/IVote.sol";
import {IStakeErrors} from "../src/interfaces/IStake.sol";
import {ISubmitErrors, ProposalBody, TargetMode} from "../src/interfaces/ISubmit.sol";
import {IProposalTarget} from "../src/interfaces/IProposalTarget.sol";

interface VoteVm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function roll(uint256 blockNumber) external;
    function warp(uint256 timestamp) external;
    function prank(address sender) external;
    function expectRevert(bytes calldata revertData) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory entries);
}

/// @notice Stake stand-in for the two reads Vote performs.
/// @dev Both entry points stay `view` to match `IStake`, so the compiler emits STATICCALL and this
///      mock cannot count invocations. Tests observe read behaviour by mutating the returned values
///      from inside a Target callback instead (see `MockTarget`). `cumulatedBoostShares` keeps the
///      real Stake round gate, so a Vote that asked for the wrong round would revert here.
contract MockStake {
    error MockStakeReadDisabled();

    address public phaseAddress;

    mapping(address => mapping(uint256 => uint256)) private _validVotes;
    mapping(address => uint256) private _globalVotes;
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) private _boost;

    bool public boostReadDisabled;

    function setPhase(address phaseAddress_) external {
        phaseAddress = phaseAddress_;
    }

    /// @dev A view function may still revert on stored state, which is how tests prove that a read
    ///      never happened without having to count invocations.
    function disableBoostRead(bool disabled) external {
        boostReadDisabled = disabled;
    }

    function setValidGovVotes(address tokenAddress, uint256 memberId, uint256 votes) external {
        _validVotes[tokenAddress][memberId] = votes;
    }

    function setGlobalGovVotes(address tokenAddress, uint256 votes) external {
        _globalVotes[tokenAddress] = votes;
    }

    function setBoost(address tokenAddress, uint256 round, uint256 memberId, uint256 boostShares) external {
        _boost[tokenAddress][round][memberId] = boostShares;
    }

    function validGovVotes(address tokenAddress, uint256 memberId) external view returns (uint256) {
        return _validVotes[tokenAddress][memberId];
    }

    function globalGovVotes(address tokenAddress) external view returns (uint256) {
        return _globalVotes[tokenAddress];
    }

    function cumulatedBoostShares(address tokenAddress, uint256 round, uint256 memberId)
        external
        view
        returns (uint256)
    {
        // A round that has not started has no record yet: reverting is the old behaviour, and it
        // turns "Vote asked Stake for the current round" into an enforced invariant.
        if (boostReadDisabled) {
            revert MockStakeReadDisabled();
        }
        if (round > IPhase(phaseAddress).currentPhase()) {
            revert IStakeErrors.InvalidPhase(round);
        }
        return _boost[tokenAddress][round][memberId];
    }
}

/// @notice Proposal Target stand-in: records every callback, can revert on demand, and can mutate
///         the Stake values mid-batch so that "read once" claims become observable.
contract MockTarget is IProposalTarget {
    error MockTargetCallbackFailure(uint256 callIndex);

    address public voteAddress;

    uint256 public createdCalls;
    uint256 public submittedCalls;
    uint256 public votedCalls;
    /// 1-based index of the `onProposalVoted` call that must revert; 0 = never revert.
    uint256 public revertOnVotedCall;

    address public lastCreatedTokenAddress;
    uint256 public lastCreatedProposalId;
    uint256 public lastSubmittedProposalId;
    uint256 public lastSubmittedSubmitterId;

    address public lastVotedTokenAddress;
    uint256 public lastVotedRound;
    uint256 public lastVotedProposalId;
    uint256 public lastVotedVoterId;
    uint256 public lastVotedVotes;
    uint256 public lastVotedOuterDataLength;
    uint256 public lastVotedInnerDataLength;
    bytes public lastVotedFirstData;
    /// Value of `Vote.votesNumByMemberId` observed *inside* the callback, i.e. after Vote wrote state.
    uint256 public votesNumObservedInCallback;

    uint256[] private _votedVotes;
    uint256[] private _votedProposalIds;
    uint256[] private _votedOuterDataLengths;
    uint256[] private _votedInnerDataLengths;
    bytes[] private _votedFirstDataList;
    uint256[] private _observedVotesNumList;

    MockStake private _mutatedStake;
    address private _mutationTokenAddress;
    uint256 private _mutationMemberId;
    uint256 private _mutationValue;
    bool private _mutateCapOnce;
    bool private _mutateBoostOnce;

    constructor(address voteAddress_) {
        voteAddress = voteAddress_;
    }

    function setRevertOnVotedCall(uint256 callIndex) external {
        revertOnVotedCall = callIndex;
    }

    /// @dev The first callback lowers the member's vote cap to `newCap`.
    function mutateCapOnFirstCallback(address stakeAddress, address tokenAddress, uint256 memberId, uint256 newCap)
        external
    {
        _mutatedStake = MockStake(stakeAddress);
        _mutationTokenAddress = tokenAddress;
        _mutationMemberId = memberId;
        _mutationValue = newCap;
        _mutateCapOnce = true;
    }

    /// @dev The first callback raises the member's Stake boost to `newBoost` for the round it sees.
    function mutateBoostOnFirstCallback(address stakeAddress, address tokenAddress, uint256 memberId, uint256 newBoost)
        external
    {
        _mutatedStake = MockStake(stakeAddress);
        _mutationTokenAddress = tokenAddress;
        _mutationMemberId = memberId;
        _mutationValue = newBoost;
        _mutateBoostOnce = true;
    }

    function votedVotesLength() external view returns (uint256) {
        return _votedVotes.length;
    }

    function votedVotesAt(uint256 index) external view returns (uint256) {
        return _votedVotes[index];
    }

    function votedProposalIdAt(uint256 index) external view returns (uint256) {
        return _votedProposalIds[index];
    }

    function votedOuterDataLengthAt(uint256 index) external view returns (uint256) {
        return _votedOuterDataLengths[index];
    }

    function votedInnerDataLengthAt(uint256 index) external view returns (uint256) {
        return _votedInnerDataLengths[index];
    }

    /// @dev The bytes of `targetData[0]` as seen by the callback at `index`; empty when the outer
    ///      array was empty.
    function votedFirstDataAt(uint256 index) external view returns (bytes memory) {
        return _votedFirstDataList[index];
    }

    /// @dev `Vote.votesNumByMemberId` as read from inside the callback at `index`.
    function observedVotesNumAt(uint256 index) external view returns (uint256) {
        return _observedVotesNumList[index];
    }

    function onProposalCreated(address tokenAddress, uint256 proposalId, bytes[] calldata) external {
        createdCalls += 1;
        lastCreatedTokenAddress = tokenAddress;
        lastCreatedProposalId = proposalId;
    }

    function onProposalSubmitted(address tokenAddress, uint256 proposalId, uint256 submitterId, bytes[] calldata)
        external
    {
        submittedCalls += 1;
        lastSubmittedProposalId = proposalId;
        lastSubmittedSubmitterId = submitterId;
        tokenAddress;
    }

    function onProposalVoted(
        address tokenAddress,
        uint256 round,
        uint256 proposalId,
        uint256 voterId,
        uint256 votes,
        bytes[] calldata targetData
    ) external {
        votedCalls += 1;
        if (revertOnVotedCall != 0 && votedCalls == revertOnVotedCall) {
            revert MockTargetCallbackFailure(votedCalls);
        }

        lastVotedTokenAddress = tokenAddress;
        lastVotedRound = round;
        lastVotedProposalId = proposalId;
        lastVotedVoterId = voterId;
        lastVotedVotes = votes;
        lastVotedOuterDataLength = targetData.length;
        lastVotedInnerDataLength = targetData.length == 0 ? 0 : targetData[0].length;
        lastVotedFirstData = targetData.length == 0 ? bytes("") : targetData[0];
        votesNumObservedInCallback = IVote(voteAddress).votesNumByMemberId(tokenAddress, round, voterId);

        _votedVotes.push(votes);
        _votedProposalIds.push(proposalId);
        _votedOuterDataLengths.push(targetData.length);
        _votedInnerDataLengths.push(targetData.length == 0 ? 0 : targetData[0].length);
        _votedFirstDataList.push();
        _votedFirstDataList[_votedFirstDataList.length - 1] = lastVotedFirstData;
        _observedVotesNumList.push(votesNumObservedInCallback);

        if (_mutateCapOnce) {
            _mutateCapOnce = false;
            _mutatedStake.setValidGovVotes(_mutationTokenAddress, _mutationMemberId, _mutationValue);
        }
        if (_mutateBoostOnce) {
            _mutateBoostOnce = false;
            _mutatedStake.setBoost(_mutationTokenAddress, round, _mutationMemberId, _mutationValue);
        }
    }
}
/// @notice Submit stand-in used only to reach branches the real Submit makes unreachable.
contract MockSubmit {
    mapping(address => mapping(uint256 => mapping(uint256 => bool))) private _submitted;
    mapping(address => mapping(uint256 => address)) private _targets;
    mapping(address => mapping(uint256 => TargetMode)) private _modes;

    function setSubmitted(address tokenAddress, uint256 round, uint256 proposalId, bool value) external {
        _submitted[tokenAddress][round][proposalId] = value;
    }

    function setTarget(address tokenAddress, uint256 proposalId, address target, TargetMode mode) external {
        _targets[tokenAddress][proposalId] = target;
        _modes[tokenAddress][proposalId] = mode;
    }

    function isSubmitted(address tokenAddress, uint256 round, uint256 proposalId) external view returns (bool) {
        return _submitted[tokenAddress][round][proposalId];
    }

    function proposalTarget(address tokenAddress, uint256 proposalId)
        external
        view
        returns (address target, TargetMode targetMode)
    {
        return (_targets[tokenAddress][proposalId], _modes[tokenAddress][proposalId]);
    }
}

/// @notice Vote against the real Phase, MemberNFT and Submit, with Stake and the Target stubbed.
contract VoteTest {
    VoteVm private constant vm = VoteVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant ORIGIN_BLOCKS = 100;
    uint256 private constant PHASE_BLOCKS = 100;
    uint256 private constant TARGET_SECONDS = 1000;
    uint256 private constant ADJUST_THRESHOLD = 1e17;
    uint256 private constant SYNC_OBSERVATION_LIMIT = 10;
    uint256 private constant MEMBER_COUNT = 10;
    uint256 private constant DEFAULT_CAP = 100;

    address private constant TOKEN = address(0xBEEF);
    address private constant TOKEN2 = address(0xCAFE);
    address private constant EOA_TARGET = address(0xE1E1);
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant MINT_ADDRESS = address(0x1234);

    Phase private phase;
    MockStake private stake;
    MockTarget private target;
    Submit private submit;
    Vote private vote;
    MemberNFT private memberNFT;
    LOVE20Token private feeToken;

    uint256[] private _memberIds;
    address[] private _memberOwners;
    uint256 private _outsiderMemberId;
    uint256 private _cursorRound;
    uint256 private _cursor;

    function setUp() public {
        vm.roll(ORIGIN_BLOCKS);
        vm.warp(1000);

        phase = new Phase(ORIGIN_BLOCKS, PHASE_BLOCKS, TARGET_SECONDS, ADJUST_THRESHOLD, SYNC_OBSERVATION_LIMIT);
        stake = new MockStake();
        stake.setPhase(address(phase));

        // initialSupply == maxSupply keeps the mint fee at zero, so members cost nothing to create.
        feeToken = new LOVE20Token("LOVE20", "LOVE20", 1000e18, 1000e18, address(this), address(this), address(0xdead));
        memberNFT = new MemberNFT(1e8, 7, 10, 32);
        memberNFT.init(address(feeToken));

        submit = new Submit();
        submit.init(address(phase), address(stake), address(memberNFT), 1);

        vote = new Vote();
        vote.init(address(phase), address(stake), address(submit), address(memberNFT), MINT_ADDRESS);

        target = new MockTarget(address(vote));

        // Every member has its own owner: both entry points are msg.sender sensitive, so tests
        // exercise them the way the protocol is used.
        for (uint256 i = 0; i < MEMBER_COUNT; i++) {
            address owner = address(uint160(0x1000 + i));
            _memberOwners.push(owner);
            vm.prank(owner);
            (uint256 id,) = memberNFT.mint(_memberName(i));
            _memberIds.push(id);
        }
        vm.prank(ALICE);
        (_outsiderMemberId,) = memberNFT.mint("outsider");

        stake.setGlobalGovVotes(TOKEN, 1000);
        stake.setGlobalGovVotes(TOKEN2, 1000);
        for (uint256 i = 0; i < _memberIds.length; i++) {
            stake.setValidGovVotes(TOKEN, _memberIds[i], DEFAULT_CAP);
            stake.setValidGovVotes(TOKEN2, _memberIds[i], DEFAULT_CAP);
        }
        stake.setValidGovVotes(TOKEN, _outsiderMemberId, DEFAULT_CAP);
    }

    // ============ Helpers ============

    function _memberName(uint256 index) private pure returns (string memory) {
        string[10] memory names = ["m1", "m2", "m3", "m4", "m5", "m6", "m7", "m8", "m9", "m10"];
        return names[index];
    }

    /// @dev Submit allows one submission per member per round per token, so submissions rotate through
    ///      the member pool and the cursor restarts whenever the round advances.
    function _nextSubmitter() private returns (uint256 memberId) {
        uint256 round = phase.currentPhase();
        if (round != _cursorRound) {
            _cursorRound = round;
            _cursor = 0;
        }
        require(_cursor < _memberIds.length, "ran out of members for this round");
        memberId = _memberIds[_cursor];
        _cursor += 1;
    }

    function _body(address targetAddress, TargetMode mode) private pure returns (ProposalBody memory) {
        return ProposalBody({
            title: "proposal",
            details: "details",
            target: targetAddress,
            targetMode: mode,
            targetData: new bytes[](0)
        });
    }

    function _proposeNoCallback(address tokenAddress) private returns (uint256 proposalId) {
        uint256 memberId = _nextSubmitter();
        vm.prank(_ownerOfMember(memberId));
        proposalId = submit.submitNewProposal(tokenAddress, memberId, _body(EOA_TARGET, TargetMode.NoCallback));
    }

    function _proposeCallback(address tokenAddress, address targetAddress) private returns (uint256 proposalId) {
        uint256 memberId = _nextSubmitter();
        vm.prank(_ownerOfMember(memberId));
        proposalId = submit.submitNewProposal(tokenAddress, memberId, _body(targetAddress, TargetMode.Callback));
    }

    function _proposeBatch(address tokenAddress, uint256 count) private returns (uint256[] memory ids) {
        ids = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            ids[i] = _proposeNoCallback(tokenAddress);
        }
    }

    function _proposeWithMode(address tokenAddress, address targetAddress, TargetMode mode)
        private
        returns (uint256 proposalId)
    {
        uint256 memberId = _nextSubmitter();
        vm.prank(_ownerOfMember(memberId));
        proposalId = submit.submitNewProposal(tokenAddress, memberId, _body(targetAddress, mode));
    }

    function _emptyRows(uint256 count) private pure returns (bytes[][] memory rows) {
        rows = new bytes[][](count);
        for (uint256 i = 0; i < count; i++) {
            rows[i] = new bytes[](0);
        }
    }

    /// @dev The `Voted` events emitted by this Vote during the current log recording.
    function _votedLogs() private returns (VoteVm.Log[] memory filtered) {
        VoteVm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i = 0; i < logs.length; i++) {
            if (_isVotedLog(logs[i])) {
                count += 1;
            }
        }
        filtered = new VoteVm.Log[](count);
        uint256 next;
        for (uint256 i = 0; i < logs.length; i++) {
            if (_isVotedLog(logs[i])) {
                filtered[next] = logs[i];
                next += 1;
            }
        }
    }

    function _isVotedLog(VoteVm.Log memory entry) private view returns (bool) {
        return entry.emitter == address(vote) && entry.topics.length > 0
            && entry.topics[0] == IVoteEvents.Voted.selector;
    }

    function _singleton(uint256 value) private pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = value;
    }

    function _filled(uint256 count, uint256 value) private pure returns (uint256[] memory out) {
        out = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            out[i] = value;
        }
    }

    function _ownerOfMember(uint256 memberId) private view returns (address owner) {
        for (uint256 i = 0; i < _memberIds.length; i++) {
            if (_memberIds[i] == memberId) {
                return _memberOwners[i];
            }
        }
        return ALICE;
    }

    /// @dev Votes with an empty outer Target Data array, i.e. every callback gets empty data.
    function _voteWithoutData(
        address tokenAddress,
        uint256 memberId,
        uint256[] memory proposalIds,
        uint256[] memory votes
    ) private {
        vm.prank(_ownerOfMember(memberId));
        vote.vote(tokenAddress, memberId, proposalIds, votes, new bytes[][](0));
    }

    /// @dev Votes with an explicit Target Data array; returns the raw call result so that callers can
    ///      assert on reverts without mixing cheatcodes and low-level calls in one expression.
    function _voteWithData(
        address tokenAddress,
        uint256 memberId,
        uint256[] memory proposalIds,
        uint256[] memory votes,
        bytes[][] memory targetData
    ) private returns (bool ok, bytes memory data) {
        vm.prank(_ownerOfMember(memberId));
        (ok, data) =
            address(vote).call(abi.encodeCall(vote.vote, (tokenAddress, memberId, proposalIds, votes, targetData)));
    }

    function _advanceRounds(uint256 count) private {
        vm.roll(block.number + PHASE_BLOCKS * count);
    }

    function _callVote(bytes memory callData) private returns (bool ok, bytes memory data) {
        (ok, data) = address(vote).call(callData);
    }

    function _expectRevert(bytes memory callData, bytes memory expected, string memory label) private {
        _expectRevertOn(address(vote), callData, expected, label);
    }

    /// @dev Same as `_expectRevert`, but sent as the owner of `memberId`.
    function _expectRevertAs(uint256 memberId, bytes memory callData, bytes memory expected, string memory label)
        private
    {
        vm.prank(_ownerOfMember(memberId));
        _expectRevertOn(address(vote), callData, expected, label);
    }

    function _expectRevertOn(address targetAddress, bytes memory callData, bytes memory expected, string memory label)
        private
    {
        (bool ok, bytes memory data) = targetAddress.call(callData);
        require(!ok, string.concat(label, ": expected a revert"));
        require(keccak256(data) == keccak256(expected), string.concat(label, ": unexpected revert data"));
    }

    function _assertAllVoteStateEmpty(address tokenAddress, uint256 round, uint256 memberId) private view {
        require(vote.votesNum(tokenAddress, round) == 0, "round total must stay zero");
        require(vote.votesNumByMemberId(tokenAddress, round, memberId) == 0, "member total must stay zero");
        require(vote.stakedAmountOfVoters(tokenAddress, round) == 0, "round boost total must stay zero");
        require(
            vote.stakedAmountOfVotersByMemberId(tokenAddress, round, memberId) == 0, "member boost must stay zero"
        );
        (uint256[] memory ids, uint256 total) = vote.votedProposalIds(tokenAddress, round, 0, 100, false);
        require(ids.length == 0 && total == 0, "voted proposal list must stay empty");
    }

    // ============ init ============

    function testInitWiresEveryDependencyAndStartsEmpty() external view {
        require(vote.initialized(), "must be initialized");
        require(vote.phaseAddress() == address(phase), "phase address");
        require(vote.stakeAddress() == address(stake), "stake address");
        require(vote.submitAddress() == address(submit), "submit address");
        require(vote.memberNFTAddress() == address(memberNFT), "memberNFT address");
        require(vote.mintAddress() == MINT_ADDRESS, "mint address");

        require(vote.currentRound() == phase.currentPhase(), "round must follow phase");
        require(vote.votesNum(TOKEN, vote.currentRound()) == 0, "no votes yet");
        require(vote.stakedAmountOfVoters(TOKEN, vote.currentRound()) == 0, "no boost yet");
    }

    function testInitRejectsSecondCall() external {
        Vote fresh = new Vote();
        fresh.init(address(phase), address(stake), address(submit), address(memberNFT), MINT_ADDRESS);
        require(fresh.initialized(), "first init must succeed");

        bytes memory expected = abi.encodeWithSelector(IVoteErrors.AlreadyInitialized.selector);
        _expectRevertOn(
            address(fresh),
            abi.encodeCall(fresh.init, (address(phase), address(stake), address(submit), address(memberNFT), MINT_ADDRESS)),
            expected,
            "second init"
        );
        require(fresh.mintAddress() == MINT_ADDRESS, "second init must not overwrite state");
    }

    /// @dev Every dependency is checked, and a rejected init leaves nothing behind.
    function testInitRejectsEveryZeroDependency() external {
        bytes memory expected = abi.encodeWithSelector(IVoteErrors.InvalidAddress.selector);
        Vote fresh = new Vote();

        _expectRevertOn(
            address(fresh),
            abi.encodeCall(fresh.init, (address(0), address(stake), address(submit), address(memberNFT), MINT_ADDRESS)),
            expected,
            "zero phase"
        );
        require(!fresh.initialized(), "zero phase must not initialize");

        fresh = new Vote();
        _expectRevertOn(
            address(fresh),
            abi.encodeCall(fresh.init, (address(phase), address(0), address(submit), address(memberNFT), MINT_ADDRESS)),
            expected,
            "zero stake"
        );
        require(!fresh.initialized(), "zero stake must not initialize");

        fresh = new Vote();
        _expectRevertOn(
            address(fresh),
            abi.encodeCall(fresh.init, (address(phase), address(stake), address(0), address(memberNFT), MINT_ADDRESS)),
            expected,
            "zero submit"
        );
        require(!fresh.initialized(), "zero submit must not initialize");

        fresh = new Vote();
        _expectRevertOn(
            address(fresh),
            abi.encodeCall(fresh.init, (address(phase), address(stake), address(submit), address(0), MINT_ADDRESS)),
            expected,
            "zero memberNFT"
        );
        require(!fresh.initialized(), "zero memberNFT must not initialize");

        fresh = new Vote();
        _expectRevertOn(
            address(fresh),
            abi.encodeCall(fresh.init, (address(phase), address(stake), address(submit), address(memberNFT), address(0))),
            expected,
            "zero mint"
        );
        require(!fresh.initialized(), "zero mint must not initialize");

        fresh = new Vote();
        _expectRevertOn(
            address(fresh),
            abi.encodeCall(fresh.init, (address(0), address(0), address(0), address(0), address(0))),
            expected,
            "all zero"
        );
        require(!fresh.initialized(), "all zero must not initialize");
    }

    /// @dev Initialization state is read before the arguments, so a second call on an initialized
    ///      contract reports `AlreadyInitialized` even when the arguments are also invalid.
    function testInitStateIsCheckedBeforeArguments() external {
        Vote fresh = new Vote();
        fresh.init(address(phase), address(stake), address(submit), address(memberNFT), MINT_ADDRESS);

        bytes memory expected = abi.encodeWithSelector(IVoteErrors.AlreadyInitialized.selector);
        _expectRevertOn(
            address(fresh),
            abi.encodeCall(fresh.init, (address(0), address(0), address(0), address(0), address(0))),
            expected,
            "state before arguments"
        );
    }

    function testInitIsPermissionlessAndThereIsNoDeployer() external {
        Vote fresh = new Vote();
        vm.prank(ALICE);
        fresh.init(address(phase), address(stake), address(submit), address(memberNFT), MINT_ADDRESS);
        require(fresh.initialized(), "any caller may initialize");

        // No deployer is remembered: nothing distinguishes this contract from one initialized by
        // another account, and there is no owner/administrator to leak.
        require(fresh.phaseAddress() == address(phase) && fresh.mintAddress() == MINT_ADDRESS, "state as given");
    }

    /// @dev Only the zero address is rejected; nothing requires the dependencies to be contracts.
    function testInitAcceptsNonContractAddresses() external {
        Vote fresh = new Vote();
        fresh.init(address(1), address(2), address(3), address(4), address(5));
        require(fresh.initialized(), "non-contract addresses are accepted");
        require(fresh.phaseAddress() == address(1) && fresh.mintAddress() == address(5), "stored verbatim");
    }

    // ============ Round views ============

    function testCurrentRoundMirrorsPhase() external {
        require(vote.currentRound() == 1, "round 1 at origin");
        _advanceRounds(1);
        require(vote.currentRound() == phase.currentPhase() && vote.currentRound() == 2, "round 2");
        _advanceRounds(3);
        require(vote.currentRound() == phase.currentPhase() && vote.currentRound() == 5, "round 5");
    }

    function testIsRoundEndedIsFalseForRoundZero() external {
        require(!vote.isRoundEnded(0), "round 0 is never ended");
        _advanceRounds(4);
        require(!vote.isRoundEnded(0), "round 0 stays not-ended in later rounds");
    }

    function testIsRoundEndedBoundaries() external {
        uint256 round = vote.currentRound();
        require(!vote.isRoundEnded(round), "current round has not ended");
        require(!vote.isRoundEnded(round + 1), "future round has not ended");
        require(!vote.isRoundEnded(type(uint256).max), "distant future has not ended");

        _advanceRounds(1);
        require(vote.isRoundEnded(round), "previous round has ended");
        require(!vote.isRoundEnded(round + 1), "round after the previous one is current");
    }

    function testCanVoteFollowsTheStakeCapBoundaries() external {
        uint256 memberId = _memberIds[0];
        require(vote.maxVotesNum(TOKEN, memberId) == DEFAULT_CAP, "cap passthrough");
        require(vote.canVote(TOKEN, memberId), "cap of one or more can vote");

        stake.setValidGovVotes(TOKEN, memberId, 0);
        require(!vote.canVote(TOKEN, memberId), "zero cap cannot vote");
        require(vote.maxVotesNum(TOKEN, memberId) == 0, "zero cap passthrough");

        stake.setValidGovVotes(TOKEN, memberId, 1);
        require(vote.canVote(TOKEN, memberId), "cap of exactly one can vote");
    }

    function testMaxVotesNumPassesThroughExtremes() external {
        uint256 memberId = _memberIds[0];
        stake.setValidGovVotes(TOKEN, memberId, type(uint256).max);
        require(vote.maxVotesNum(TOKEN, memberId) == type(uint256).max, "max cap passthrough");
        require(vote.canVote(TOKEN, memberId), "max cap can vote");
    }

    /// @dev Vote is a pure reader for unknown members, tokens and rounds: nothing reverts and
    ///      everything reads as zero, which is what Mint relies on after a round has closed.
    function testUnknownTokenAndMemberReadZeroWithoutReverting() external view {
        require(vote.votesNum(TOKEN, 1) == 0, "unknown round");
        require(vote.votesNumByProposalId(TOKEN, 1, 77) == 0, "unknown proposal");
        require(vote.votesNumByMemberId(TOKEN, 1, 999) == 0, "unknown member");
        require(!vote.isProposalIdVoted(TOKEN, 1, 77), "unknown proposal is not voted");
        require(!vote.canVote(TOKEN, 999), "unknown member cannot vote");
        require(vote.maxVotesNum(TOKEN, 999) == 0, "unknown member has no cap");
        require(vote.stakedAmountOfVoters(TOKEN, 1) == 0, "unknown round boost");
        require(vote.stakedAmountOfVotersByMemberId(TOKEN, 1, 999) == 0, "unknown member boost");
    }

    /// @dev Round-keyed record sets answer with an empty result for a round that has not started,
    ///      the same way they answer for a round with no records; only point-in-time reads revert,
    ///      and those live in Stake.
    function testFutureRoundRecordReadsReturnEmptyWithoutReverting() external view {
        uint256 future = vote.currentRound() + 5;

        (uint256[] memory ids, uint256 total) = vote.votedProposalIds(TOKEN, future, 0, 10, false);
        require(ids.length == 0 && total == 0, "voted proposals");

        (ids, total) = vote.votedProposalIdsByMemberId(TOKEN, future, _memberIds[0], 0, 10, false);
        require(ids.length == 0 && total == 0, "member voted proposals");

        (ids, total) = vote.voterIdsByProposalId(TOKEN, future, 1, 0, 10, false);
        require(ids.length == 0 && total == 0, "voters of a proposal");

        (uint256[] memory proposals, uint256[] memory votes, uint256 count) =
            vote.votesNumsByMemberId(TOKEN, future, _memberIds[0], 0, 10, false);
        require(proposals.length == 0 && votes.length == 0 && count == 0, "member votes page");

        uint256[] memory requested = _singleton(1);
        require(vote.votesNumsByMemberIdByProposalIds(TOKEN, future, _memberIds[0], requested)[0] == 0, "by ids");

        require(!vote.isRoundEnded(future), "future round has not ended");
        require(vote.votesNum(TOKEN, future) == 0, "future round total");
        require(vote.stakedAmountOfVoters(TOKEN, future) == 0, "future round boost total");
    }
    // ============ vote: authorization ============

    function testVoteRejectsNonOwner() external {
        uint256 memberId = _memberIds[0];
        uint256 proposalId = _proposeNoCallback(TOKEN);
        bytes memory expected = abi.encodeWithSelector(IVoteErrors.NotMemberOwner.selector, memberId);

        vm.prank(ALICE);
        _expectRevertOn(
            address(vote),
            abi.encodeCall(vote.vote, (TOKEN, memberId, _singleton(proposalId), _singleton(10), new bytes[][](0))),
            expected,
            "non-owner"
        );
        _assertAllVoteStateEmpty(TOKEN, vote.currentRound(), memberId);
    }

    /// @dev Vote keeps no `InvalidMemberId` of its own: the member NFT is the one that rejects an
    ///      unknown id, and that error is what surfaces.
    function testVoteRejectsMemberThatDoesNotExist() external {
        uint256 proposalId = _proposeNoCallback(TOKEN);
        bytes memory expected = abi.encodeWithSignature("ERC721NonexistentToken(uint256)", 9999);
        _expectRevert(
            abi.encodeCall(vote.vote, (TOKEN, 9999, _singleton(proposalId), _singleton(10), new bytes[][](0))),
            expected,
            "unknown member"
        );
    }

    function testVoteRejectsZeroMemberId() external {
        uint256 proposalId = _proposeNoCallback(TOKEN);
        bytes memory expected = abi.encodeWithSignature("ERC721NonexistentToken(uint256)", 0);
        _expectRevert(
            abi.encodeCall(vote.vote, (TOKEN, 0, _singleton(proposalId), _singleton(10), new bytes[][](0))),
            expected,
            "zero member"
        );
    }

    // ============ vote: check order ============

    function testOwnershipIsCheckedBeforeEligibility() external {
        uint256 memberId = _memberIds[0];
        uint256 proposalId = _proposeNoCallback(TOKEN);
        // Both the owner check and the cap check would fail; ownership is reported.
        stake.setValidGovVotes(TOKEN, memberId, 0);
        bytes memory expected = abi.encodeWithSelector(IVoteErrors.NotMemberOwner.selector, memberId);

        vm.prank(ALICE);
        _expectRevertOn(
            address(vote),
            abi.encodeCall(vote.vote, (TOKEN, memberId, _singleton(proposalId), _singleton(1), new bytes[][](0))),
            expected,
            "ownership before eligibility"
        );
    }

    function testEligibilityIsCheckedBeforeLengths() external {
        uint256 memberId = _memberIds[0];
        stake.setValidGovVotes(TOKEN, memberId, 0);
        bytes memory expected = abi.encodeWithSelector(IVoteErrors.CannotVote.selector);

        // No proposal exists and the batch is empty, yet the missing voting power is what surfaces.
        _expectRevertAs(
            memberId,
            abi.encodeCall(vote.vote, (TOKEN, memberId, new uint256[](0), new uint256[](0), new bytes[][](0))),
            expected,
            "eligibility before lengths"
        );
    }

    /// @dev Both per-proposal failures happen before Stake is asked for the snapshot: with the
    ///      snapshot read disabled, the reported errors stay the protocol's own.
    function testVoteChecksPrecedeTheStakeSnapshotRead() external {
        uint256 memberId = _memberIds[0];
        uint256 proposalId = _proposeNoCallback(TOKEN);

        stake.disableBoostRead(true);

        // Control: a well formed call does reach the read, so the switch is meaningful.
        _expectRevertAs(
            memberId,
            abi.encodeCall(vote.vote, (TOKEN, memberId, _singleton(proposalId), _singleton(1), new bytes[][](0))),
            abi.encodeWithSelector(MockStake.MockStakeReadDisabled.selector),
            "control"
        );

        _expectRevertAs(
            memberId,
            abi.encodeCall(vote.vote, (TOKEN, memberId, _singleton(999), _singleton(1), new bytes[][](0))),
            abi.encodeWithSelector(IVoteErrors.ProposalNotSubmitted.selector),
            "submission before snapshot"
        );

        _expectRevertAs(
            memberId,
            abi.encodeCall(vote.vote, (TOKEN, memberId, _singleton(proposalId), _singleton(0), new bytes[][](0))),
            abi.encodeWithSelector(IVoteErrors.VotesMustBeGreaterThanZero.selector),
            "amount before snapshot"
        );
    }

    // ============ vote: batch shape ============

    function testVoteRejectsEmptyProposalIds() external {
        uint256 memberId = _memberIds[0];
        bytes memory expected = abi.encodeWithSelector(IVoteErrors.InvalidTargetDataLength.selector);
        _expectRevertAs(
            memberId,
            abi.encodeCall(vote.vote, (TOKEN, memberId, new uint256[](0), new uint256[](0), new bytes[][](0))),
            expected,
            "empty batch"
        );
        _assertAllVoteStateEmpty(TOKEN, vote.currentRound(), memberId);
    }

    function testVoteRejectsVotesLengthMismatch() external {
        uint256 memberId = _memberIds[0];
        uint256[] memory ids = _proposeBatch(TOKEN, 2);
        bytes memory expected = abi.encodeWithSelector(IVoteErrors.InvalidTargetDataLength.selector);

        _expectRevertAs(
            memberId,
            abi.encodeCall(vote.vote, (TOKEN, memberId, ids, _singleton(1), new bytes[][](0))),
            expected,
            "votes shorter than proposals"
        );

        _expectRevertAs(
            memberId,
            abi.encodeCall(vote.vote, (TOKEN, memberId, ids, _filled(3, 1), new bytes[][](0))),
            expected,
            "votes longer than proposals"
        );

        _assertAllVoteStateEmpty(TOKEN, vote.currentRound(), memberId);
    }

    function testVoteRejectsTargetDataLengthMismatch() external {
        uint256 memberId = _memberIds[0];
        uint256[] memory ids = _proposeBatch(TOKEN, 2);
        bytes memory expected = abi.encodeWithSelector(IVoteErrors.InvalidTargetDataLength.selector);

        bytes[][] memory tooShort = new bytes[][](1);
        tooShort[0] = new bytes[](0);
        (bool ok, bytes memory data) = _voteWithData(TOKEN, memberId, ids, _filled(2, 1), tooShort);
        require(!ok && keccak256(data) == keccak256(expected), "outer array shorter than proposals");

        bytes[][] memory tooLong = new bytes[][](3);
        for (uint256 i = 0; i < tooLong.length; i++) {
            tooLong[i] = new bytes[](0);
        }
        (ok, data) = _voteWithData(TOKEN, memberId, ids, _filled(2, 1), tooLong);
        require(!ok && keccak256(data) == keccak256(expected), "outer array longer than proposals");

        _assertAllVoteStateEmpty(TOKEN, vote.currentRound(), memberId);
    }

    // ============ vote: happy path and round scoping ============

    function testVoteRecordsCountsListsAndSnapshot() external {
        uint256 memberId = _memberIds[0];
        uint256[] memory ids = _proposeBatch(TOKEN, 2);
        stake.setBoost(TOKEN, 1, memberId, 50);

        _voteWithoutData(TOKEN, memberId, ids, _filled(2, 30));

        require(vote.votesNum(TOKEN, 1) == 60, "round total");
        require(vote.votesNumByProposalId(TOKEN, 1, ids[0]) == 30, "first proposal total");
        require(vote.votesNumByProposalId(TOKEN, 1, ids[1]) == 30, "second proposal total");
        require(vote.votesNumByMemberId(TOKEN, 1, memberId) == 60, "member total");
        require(vote.votesNumByMemberIdByProposalId(TOKEN, 1, memberId, ids[0]) == 30, "member per proposal");
        require(vote.isProposalIdVoted(TOKEN, 1, ids[0]), "proposal marked voted");
        require(!vote.isProposalIdVoted(TOKEN, 1, 999), "unrelated proposal untouched");
        require(vote.stakedAmountOfVotersByMemberId(TOKEN, 1, memberId) == 50, "member snapshot");
        require(vote.stakedAmountOfVoters(TOKEN, 1) == 50, "round snapshot total");

        (uint256[] memory voted, uint256 total) = vote.votedProposalIds(TOKEN, 1, 0, 10, false);
        require(total == 2 && voted.length == 2 && voted[0] == ids[0] && voted[1] == ids[1], "proposal list");

        (voted, total) = vote.votedProposalIdsByMemberId(TOKEN, 1, memberId, 0, 10, false);
        require(total == 2 && voted.length == 2 && voted[0] == ids[0] && voted[1] == ids[1], "member list");

        (uint256[] memory voters, uint256 voterTotal) = vote.voterIdsByProposalId(TOKEN, 1, ids[0], 0, 10, false);
        require(voterTotal == 1 && voters.length == 1 && voters[0] == memberId, "voter list");
    }

    function testProposalMustBeSubmittedAgainInEveryRound() external {
        uint256 author = _nextSubmitter();
        vm.prank(_ownerOfMember(author));
        uint256 proposalId = submit.submitNewProposal(TOKEN, author, _body(EOA_TARGET, TargetMode.NoCallback));

        uint256 memberId = _memberIds[1];
        _advanceRounds(1);

        bytes memory expected = abi.encodeWithSelector(IVoteErrors.ProposalNotSubmitted.selector);
        _expectRevertAs(
            memberId,
            abi.encodeCall(vote.vote, (TOKEN, memberId, _singleton(proposalId), _singleton(5), new bytes[][](0))),
            expected,
            "previous round submission does not carry over"
        );

        uint256 resubmitter = _nextSubmitter();
        vm.prank(_ownerOfMember(resubmitter));
        submit.submit(TOKEN, resubmitter, proposalId);

        _voteWithoutData(TOKEN, memberId, _singleton(proposalId), _singleton(5));
        require(vote.votesNumByProposalId(TOKEN, 2, proposalId) == 5, "counted in the new round");
        require(vote.votesNumByProposalId(TOKEN, 1, proposalId) == 0, "the old round is untouched");
    }

    function testVoteRejectsProposalIdsThatWereNeverSubmitted() external {
        uint256 memberId = _memberIds[0];
        bytes memory expected = abi.encodeWithSelector(IVoteErrors.ProposalNotSubmitted.selector);

        _expectRevertAs(
            memberId,
            abi.encodeCall(vote.vote, (TOKEN, memberId, _singleton(999), _singleton(1), new bytes[][](0))),
            expected,
            "never created"
        );
        _expectRevertAs(
            memberId,
            abi.encodeCall(vote.vote, (TOKEN, memberId, _singleton(0), _singleton(1), new bytes[][](0))),
            expected,
            "zero proposal id"
        );
        _assertAllVoteStateEmpty(TOKEN, vote.currentRound(), memberId);
    }

    function testVoteRejectsZeroAmounts() external {
        uint256 memberId = _memberIds[0];
        uint256[] memory ids = _proposeBatch(TOKEN, 2);
        bytes memory expected = abi.encodeWithSelector(IVoteErrors.VotesMustBeGreaterThanZero.selector);

        _expectRevertAs(
            memberId,
            abi.encodeCall(vote.vote, (TOKEN, memberId, _singleton(ids[0]), _singleton(0), new bytes[][](0))),
            expected,
            "zero on a single proposal"
        );

        uint256[] memory votes = _filled(2, 10);
        votes[1] = 0;
        _expectRevertAs(
            memberId, abi.encodeCall(vote.vote, (TOKEN, memberId, ids, votes, new bytes[][](0))), expected, "zero later in the batch"
        );
        _assertAllVoteStateEmpty(TOKEN, vote.currentRound(), memberId);
    }
    // ============ vote: vote allowance ============

    function testVoteAccumulatesAcrossCallsUntilTheCap() external {
        uint256 memberId = _memberIds[0];
        uint256[] memory ids = _proposeBatch(TOKEN, 3);

        _voteWithoutData(TOKEN, memberId, _singleton(ids[0]), _singleton(30));
        _voteWithoutData(TOKEN, memberId, _singleton(ids[1]), _singleton(70));
        require(vote.votesNumByMemberId(TOKEN, 1, memberId) == 100, "first two calls fit the cap");

        bytes memory expected = abi.encodeWithSelector(IVoteErrors.NotEnoughVotesLeft.selector);
        _expectRevertAs(
            memberId,
            abi.encodeCall(vote.vote, (TOKEN, memberId, _singleton(ids[2]), _singleton(1), new bytes[][](0))),
            expected,
            "one over the cap"
        );
        require(vote.votesNumByMemberId(TOKEN, 1, memberId) == 100, "the failed call changes nothing");
        require(vote.votesNum(TOKEN, 1) == 100, "round total untouched");
    }

    function testVoteAllowsExactlyTheCap() external {
        uint256 memberId = _memberIds[0];
        uint256[] memory ids = _proposeBatch(TOKEN, 1);
        _voteWithoutData(TOKEN, memberId, ids, _singleton(DEFAULT_CAP));
        require(vote.votesNumByMemberId(TOKEN, 1, memberId) == DEFAULT_CAP, "exactly the cap is allowed");
    }

    /// @dev The allowance is evaluated on the running batch total: what an earlier entry in the same
    ///      call consumed counts against a later entry.
    function testBatchAllowanceIsCumulativeInsideTheBatch() external {
        uint256 memberId = _memberIds[0];
        uint256[] memory ids = _proposeBatch(TOKEN, 2);

        _voteWithoutData(TOKEN, memberId, ids, _filled(2, 50));
        require(vote.votesNumByMemberId(TOKEN, 1, memberId) == 100, "50 + 50 fits exactly");

        uint256[] memory overflow = _filled(2, 50);
        overflow[1] = 51;
        bytes memory expected = abi.encodeWithSelector(IVoteErrors.NotEnoughVotesLeft.selector);
        _expectRevertAs(
            memberId, abi.encodeCall(vote.vote, (TOKEN, memberId, ids, overflow, new bytes[][](0))), expected, "50 + 51"
        );
    }

    function testOverCapInsideABatchRollsBackTheWholeCall() external {
        uint256 memberId = _memberIds[0];
        uint256[] memory ids = _proposeBatch(TOKEN, 2);
        stake.setBoost(TOKEN, 1, memberId, 50);

        uint256[] memory votes = _filled(2, 60);
        votes[1] = 41;
        bytes memory expected = abi.encodeWithSelector(IVoteErrors.NotEnoughVotesLeft.selector);
        _expectRevertAs(
            memberId, abi.encodeCall(vote.vote, (TOKEN, memberId, ids, votes, new bytes[][](0))), expected, "60 + 41"
        );

        // Not even the entries that were already accepted survive.
        _assertAllVoteStateEmpty(TOKEN, 1, memberId);
        (uint256[] memory voted, uint256 total) = vote.votedProposalIds(TOKEN, 1, 0, 10, false);
        require(voted.length == 0 && total == 0, "proposal list rolled back");
    }

    /// @dev The allowance is read once, before the batch is processed. The Target lowers the cap to
    ///      zero during the first callback, so a Vote that re-read it per proposal would revert here.
    function testAllowanceIsCapturedOnceForTheWholeBatch() external {
        uint256 memberId = _memberIds[0];
        uint256 first = _proposeCallback(TOKEN, address(target));
        uint256 second = _proposeNoCallback(TOKEN);
        uint256 third = _proposeNoCallback(TOKEN);

        uint256[] memory ids = new uint256[](3);
        ids[0] = first;
        ids[1] = second;
        ids[2] = third;

        target.mutateCapOnFirstCallback(address(stake), TOKEN, memberId, 0);

        uint256[] memory votes = _filled(3, 40);
        votes[2] = 20;
        _voteWithoutData(TOKEN, memberId, ids, votes);

        require(target.votedCalls() == 1, "the callback proposal fired once");
        // The mutation must really have landed, otherwise the batch would pass for the wrong reason.
        require(stake.validGovVotes(TOKEN, memberId) == 0, "the cap was lowered during the batch");
        require(vote.votesNumByMemberId(TOKEN, 1, memberId) == 100, "the cap captured up front governs the batch");
    }

    function testAllowanceAndTotalsAreScopedToTheRound() external {
        uint256 memberId = _memberIds[0];
        uint256[] memory ids = _proposeBatch(TOKEN, 1);
        _voteWithoutData(TOKEN, memberId, ids, _singleton(DEFAULT_CAP));
        require(vote.votesNumByMemberId(TOKEN, 1, memberId) == DEFAULT_CAP, "cap spent in round 1");

        _advanceRounds(1);
        uint256[] memory nextRoundIds = _proposeBatch(TOKEN, 1);
        _voteWithoutData(TOKEN, memberId, nextRoundIds, _singleton(DEFAULT_CAP));

        require(vote.votesNumByMemberId(TOKEN, 2, memberId) == DEFAULT_CAP, "round 2 has a fresh allowance");
        require(vote.votesNumByMemberId(TOKEN, 1, memberId) == DEFAULT_CAP, "round 1 stays as it was");
        require(vote.votesNum(TOKEN, 1) == DEFAULT_CAP && vote.votesNum(TOKEN, 2) == DEFAULT_CAP, "round totals");
    }

    function testAllowanceIsScopedToTokenAndMember() external {
        uint256 memberId = _memberIds[0];
        uint256 other = _memberIds[1];
        uint256[] memory ids = _proposeBatch(TOKEN, 1);

        _voteWithoutData(TOKEN, memberId, ids, _singleton(DEFAULT_CAP));

        // Another member keeps their own allowance against the same proposal.
        _voteWithoutData(TOKEN, other, ids, _singleton(7));
        require(vote.votesNumByMemberId(TOKEN, 1, other) == 7, "other member total");
        require(vote.votesNumByProposalId(TOKEN, 1, ids[0]) == DEFAULT_CAP + 7, "proposal total sums members");

        // And the same member keeps a separate allowance on another token.
        uint256[] memory otherTokenIds = _proposeBatch(TOKEN2, 1);
        _voteWithoutData(TOKEN2, memberId, otherTokenIds, _singleton(11));
        require(vote.votesNumByMemberId(TOKEN2, 1, memberId) == 11, "token scoped total");
        require(vote.votesNumByMemberId(TOKEN, 1, memberId) == DEFAULT_CAP, "token scoped independently");
    }

    // ============ vote: snapshot arithmetic ============

    function testFirstVoteRecordsTheFullSnapshot() external {
        uint256 memberId = _memberIds[0];
        uint256[] memory ids = _proposeBatch(TOKEN, 1);
        stake.setBoost(TOKEN, 1, memberId, 50);

        _voteWithoutData(TOKEN, memberId, ids, _singleton(10));

        require(vote.stakedAmountOfVotersByMemberId(TOKEN, 1, memberId) == 50, "full snapshot on the first vote");
        require(vote.stakedAmountOfVoters(TOKEN, 1) == 50, "round total follows");
    }

    function testSecondVoteRecordsOnlyTheDelta() external {
        uint256 memberId = _memberIds[0];
        uint256[] memory ids = _proposeBatch(TOKEN, 2);

        stake.setBoost(TOKEN, 1, memberId, 50);
        _voteWithoutData(TOKEN, memberId, _singleton(ids[0]), _singleton(10));
        stake.setBoost(TOKEN, 1, memberId, 80);
        _voteWithoutData(TOKEN, memberId, _singleton(ids[1]), _singleton(10));

        require(vote.stakedAmountOfVotersByMemberId(TOKEN, 1, memberId) == 80, "snapshot tracks the latest boost");
        require(vote.stakedAmountOfVoters(TOKEN, 1) == 80, "only the 30 point delta was added");
    }

    function testSnapshotFollowsEveryIncreaseButNeverDoubleCounts() external {
        uint256 memberId = _memberIds[0];
        uint256[] memory ids = _proposeBatch(TOKEN, 3);

        stake.setBoost(TOKEN, 1, memberId, 50);
        _voteWithoutData(TOKEN, memberId, _singleton(ids[0]), _singleton(10));
        stake.setBoost(TOKEN, 1, memberId, 80);
        _voteWithoutData(TOKEN, memberId, _singleton(ids[1]), _singleton(10));
        stake.setBoost(TOKEN, 1, memberId, 120);
        _voteWithoutData(TOKEN, memberId, _singleton(ids[2]), _singleton(10));

        require(vote.stakedAmountOfVotersByMemberId(TOKEN, 1, memberId) == 120, "50 then 80 then 120");
        require(vote.stakedAmountOfVoters(TOKEN, 1) == 120, "the round total tracks the member snapshot");
    }

    function testStakingWithoutVotingDoesNotMoveTheSnapshot() external {
        uint256 memberId = _memberIds[0];
        uint256[] memory ids = _proposeBatch(TOKEN, 1);

        stake.setBoost(TOKEN, 1, memberId, 50);
        _voteWithoutData(TOKEN, memberId, ids, _singleton(10));
        stake.setBoost(TOKEN, 1, memberId, 80);

        require(vote.stakedAmountOfVotersByMemberId(TOKEN, 1, memberId) == 50, "no vote, no update");
        require(vote.stakedAmountOfVoters(TOKEN, 1) == 50, "round total unchanged");
    }

    function testUnchangedBoostLeavesTheSnapshotAlone() external {
        uint256 memberId = _memberIds[0];
        uint256[] memory ids = _proposeBatch(TOKEN, 2);

        stake.setBoost(TOKEN, 1, memberId, 50);
        _voteWithoutData(TOKEN, memberId, ids, _filled(2, 10));

        require(vote.stakedAmountOfVotersByMemberId(TOKEN, 1, memberId) == 50, "no growth, no re-add");
        require(vote.stakedAmountOfVoters(TOKEN, 1) == 50, "50 is not counted twice");
    }

    /// @dev Only growth is credited: a member whose Stake boost fell cannot lower a snapshot that was
    ///      already recorded, and the round total does not go negative.
    function testBoostDecreaseIsNotCredited() external {
        uint256 memberId = _memberIds[0];
        uint256[] memory ids = _proposeBatch(TOKEN, 2);

        stake.setBoost(TOKEN, 1, memberId, 50);
        _voteWithoutData(TOKEN, memberId, _singleton(ids[0]), _singleton(10));
        stake.setBoost(TOKEN, 1, memberId, 30);
        _voteWithoutData(TOKEN, memberId, _singleton(ids[1]), _singleton(10));

        require(vote.stakedAmountOfVotersByMemberId(TOKEN, 1, memberId) == 50, "a decrease is ignored");
        require(vote.stakedAmountOfVoters(TOKEN, 1) == 50, "round total stays positive");
    }

    /// @dev The snapshot is read per proposal, not once for the batch. The Target raises the member's
    ///      Stake boost during the first callback, so a Vote that read it once would report 50.
    function testSnapshotIsReadPerProposalNotOncePerBatch() external {
        uint256 memberId = _memberIds[0];
        uint256 first = _proposeCallback(TOKEN, address(target));
        uint256 second = _proposeNoCallback(TOKEN);

        uint256[] memory ids = new uint256[](2);
        ids[0] = first;
        ids[1] = second;

        stake.setBoost(TOKEN, 1, memberId, 50);
        target.mutateBoostOnFirstCallback(address(stake), TOKEN, memberId, 80);

        _voteWithoutData(TOKEN, memberId, ids, _filled(2, 10));

        require(target.votedCalls() == 1, "the callback proposal fired once");
        require(stake.cumulatedBoostShares(TOKEN, 1, memberId) == 80, "the boost was raised during the batch");
        require(vote.stakedAmountOfVotersByMemberId(TOKEN, 1, memberId) == 80, "the second read saw 80");
        require(vote.stakedAmountOfVoters(TOKEN, 1) == 80, "total follows the member snapshot");
    }

    /// @dev Stake answers per round, so the snapshot is taken from the round being voted in. Seeding
    ///      an older round with a different value must not leak into the current one.
    function testSnapshotIsReadForTheCurrentRound() external {
        uint256 memberId = _memberIds[0];
        stake.setBoost(TOKEN, 1, memberId, 50);

        _advanceRounds(1);
        stake.setBoost(TOKEN, 2, memberId, 80);
        uint256[] memory ids = _proposeBatch(TOKEN, 1);
        _voteWithoutData(TOKEN, memberId, ids, _singleton(10));

        require(vote.stakedAmountOfVotersByMemberId(TOKEN, 2, memberId) == 80, "round 2 uses the round 2 value");
        require(vote.stakedAmountOfVotersByMemberId(TOKEN, 1, memberId) == 0, "round 1 was never voted in");
    }

    function testSnapshotIsScopedToTheRound() external {
        uint256 memberId = _memberIds[0];
        uint256[] memory ids = _proposeBatch(TOKEN, 1);
        stake.setBoost(TOKEN, 1, memberId, 120);
        _voteWithoutData(TOKEN, memberId, ids, _singleton(10));
        require(vote.stakedAmountOfVotersByMemberId(TOKEN, 1, memberId) == 120, "round 1 snapshot");

        _advanceRounds(1);
        stake.setBoost(TOKEN, 2, memberId, 30);
        uint256[] memory nextRoundIds = _proposeBatch(TOKEN, 1);
        _voteWithoutData(TOKEN, memberId, nextRoundIds, _singleton(10));

        require(vote.stakedAmountOfVotersByMemberId(TOKEN, 2, memberId) == 30, "round 2 snapshots from scratch");
        require(vote.stakedAmountOfVoters(TOKEN, 2) == 30, "round 2 total");
        require(vote.stakedAmountOfVotersByMemberId(TOKEN, 1, memberId) == 120, "round 1 is frozen");
    }

    /// @dev A member who never voted keeps a zero snapshot, and a later increase is credited in full
    ///      because zero and "no record yet" are indistinguishable by design.
    function testBoostGrowthAfterAZeroSnapshotIsCreditedInFull() external {
        uint256 memberId = _memberIds[0];
        uint256[] memory ids = _proposeBatch(TOKEN, 2);

        stake.setBoost(TOKEN, 1, memberId, 0);
        _voteWithoutData(TOKEN, memberId, _singleton(ids[0]), _singleton(10));
        require(vote.stakedAmountOfVotersByMemberId(TOKEN, 1, memberId) == 0, "zero snapshot");

        stake.setBoost(TOKEN, 1, memberId, 30);
        _voteWithoutData(TOKEN, memberId, _singleton(ids[1]), _singleton(10));

        require(vote.stakedAmountOfVotersByMemberId(TOKEN, 1, memberId) == 30, "the full value is credited");
        require(vote.stakedAmountOfVoters(TOKEN, 1) == 30, "round total");
    }

    function testSnapshotTotalsSumAcrossMembers() external {
        uint256 first = _memberIds[0];
        uint256 second = _memberIds[1];
        uint256[] memory ids = _proposeBatch(TOKEN, 2);

        stake.setBoost(TOKEN, 1, first, 50);
        stake.setBoost(TOKEN, 1, second, 30);
        _voteWithoutData(TOKEN, first, _singleton(ids[0]), _singleton(10));
        _voteWithoutData(TOKEN, second, _singleton(ids[1]), _singleton(10));

        require(vote.stakedAmountOfVotersByMemberId(TOKEN, 1, first) == 50, "first member");
        require(vote.stakedAmountOfVotersByMemberId(TOKEN, 1, second) == 30, "second member");
        require(vote.stakedAmountOfVoters(TOKEN, 1) == 80, "round total is the sum");

        // Another increase from one member adds only that member's delta.
        stake.setBoost(TOKEN, 1, first, 90);
        _voteWithoutData(TOKEN, first, _singleton(ids[1]), _singleton(10));
        require(vote.stakedAmountOfVoters(TOKEN, 1) == 120, "first member 50 to 90 plus the other member's 30");
    }

    function testSnapshotsDoNotBleedAcrossTokens() external {
        uint256 memberId = _memberIds[0];
        uint256[] memory ids = _proposeBatch(TOKEN, 1);
        uint256[] memory otherTokenIds = _proposeBatch(TOKEN2, 1);

        stake.setBoost(TOKEN, 1, memberId, 50);
        stake.setBoost(TOKEN2, 1, memberId, 900);
        _voteWithoutData(TOKEN, memberId, ids, _singleton(10));
        _voteWithoutData(TOKEN2, memberId, otherTokenIds, _singleton(10));

        require(vote.stakedAmountOfVoters(TOKEN, 1) == 50, "token 1 snapshot");
        require(vote.stakedAmountOfVoters(TOKEN2, 1) == 900, "token 2 snapshot");
        require(vote.stakedAmountOfVotersByMemberId(TOKEN, 1, memberId) == 50, "member snapshot per token");
        require(vote.stakedAmountOfVotersByMemberId(TOKEN2, 1, memberId) == 900, "member snapshot per token 2");
    }
    // ============ vote: record sets ============

    function testRepeatedVotesOnOneProposalAreRecordedOnce() external {
        uint256 memberId = _memberIds[0];
        uint256[] memory ids = _proposeBatch(TOKEN, 1);

        _voteWithoutData(TOKEN, memberId, ids, _singleton(20));
        _voteWithoutData(TOKEN, memberId, ids, _singleton(30));

        require(vote.votesNumByProposalId(TOKEN, 1, ids[0]) == 50, "votes accumulate");
        require(vote.votesNumByMemberId(TOKEN, 1, memberId) == 50, "member total");

        (uint256[] memory voted, uint256 total) = vote.votedProposalIds(TOKEN, 1, 0, 10, false);
        require(total == 1 && voted.length == 1, "the round list holds it once");
        (voted, total) = vote.votedProposalIdsByMemberId(TOKEN, 1, memberId, 0, 10, false);
        require(total == 1 && voted.length == 1, "the member list holds it once");
        (uint256[] memory voters, uint256 voterTotal) = vote.voterIdsByProposalId(TOKEN, 1, ids[0], 0, 10, false);
        require(voterTotal == 1 && voters.length == 1, "the voter list holds the member once");
    }

    function testProposalListGrowsOncePerProposalAcrossVoters() external {
        uint256 first = _memberIds[0];
        uint256 second = _memberIds[1];
        uint256[] memory ids = _proposeBatch(TOKEN, 1);

        _voteWithoutData(TOKEN, first, ids, _singleton(20));
        _voteWithoutData(TOKEN, second, ids, _singleton(7));

        (uint256[] memory voted, uint256 total) = vote.votedProposalIds(TOKEN, 1, 0, 10, false);
        require(total == 1 && voted[0] == ids[0], "the second voter does not append a duplicate");

        (uint256[] memory voters, uint256 voterTotal) = vote.voterIdsByProposalId(TOKEN, 1, ids[0], 0, 10, false);
        require(voterTotal == 2 && voters[0] == first && voters[1] == second, "both voters in insertion order");
    }

    function testMemberListGrowsOncePerProposal() external {
        uint256 memberId = _memberIds[0];
        uint256[] memory ids = _proposeBatch(TOKEN, 2);

        _voteWithoutData(TOKEN, memberId, _singleton(ids[0]), _singleton(5));
        _voteWithoutData(TOKEN, memberId, _singleton(ids[1]), _singleton(5));
        _voteWithoutData(TOKEN, memberId, _singleton(ids[0]), _singleton(5));

        (uint256[] memory voted, uint256 total) = vote.votedProposalIdsByMemberId(TOKEN, 1, memberId, 0, 10, false);
        require(total == 2 && voted[0] == ids[0] && voted[1] == ids[1], "insertion order without duplicates");

        (voted, total) = vote.votedProposalIds(TOKEN, 1, 0, 10, false);
        require(total == 2 && voted[0] == ids[0] && voted[1] == ids[1], "the round list matches");
    }

    function testRecordListsAreScopedToRoundAndToken() external {
        uint256 memberId = _memberIds[0];
        uint256[] memory ids = _proposeBatch(TOKEN, 1);
        _voteWithoutData(TOKEN, memberId, ids, _singleton(5));

        (uint256[] memory voted, uint256 total) = vote.votedProposalIds(TOKEN, 2, 0, 10, false);
        require(total == 0 && voted.length == 0, "another round");
        (voted, total) = vote.votedProposalIdsByMemberId(TOKEN, 2, memberId, 0, 10, false);
        require(total == 0 && voted.length == 0, "another round, member list");
        (voted, total) = vote.votedProposalIds(TOKEN2, 1, 0, 10, false);
        require(total == 0 && voted.length == 0, "another token");

        (uint256[] memory voters, uint256 voterTotal) = vote.voterIdsByProposalId(TOKEN2, 1, ids[0], 0, 10, false);
        require(voterTotal == 0 && voters.length == 0, "another token, voter list");
    }

    function testRoundTotalsAreArithmeticallyClosed() external {
        uint256 first = _memberIds[0];
        uint256 second = _memberIds[1];
        uint256[] memory ids = _proposeBatch(TOKEN, 3);

        _voteWithoutData(TOKEN, first, _singleton(ids[0]), _singleton(11));
        _voteWithoutData(TOKEN, first, _singleton(ids[1]), _singleton(13));
        _voteWithoutData(TOKEN, second, _singleton(ids[1]), _singleton(17));
        _voteWithoutData(TOKEN, second, _singleton(ids[2]), _singleton(19));

        uint256 byProposal = vote.votesNumByProposalId(TOKEN, 1, ids[0]) + vote.votesNumByProposalId(TOKEN, 1, ids[1])
            + vote.votesNumByProposalId(TOKEN, 1, ids[2]);
        uint256 byMember = vote.votesNumByMemberId(TOKEN, 1, first) + vote.votesNumByMemberId(TOKEN, 1, second);

        require(byProposal == 60, "proposal totals close");
        require(byMember == 60, "member totals close");
        require(vote.votesNum(TOKEN, 1) == 60, "and equal the round total");
    }

    // ============ vote: events ============

    function testVotedEventCarriesTheExactPayload() external {
        uint256 memberId = _memberIds[0];
        uint256[] memory ids = _proposeBatch(TOKEN, 2);

        vm.recordLogs();
        _voteWithoutData(TOKEN, memberId, ids, _filled(2, 30));
        VoteVm.Log[] memory events = _votedLogs();

        require(events.length == 2, "one event per proposal");
        for (uint256 i = 0; i < events.length; i++) {
            require(events[i].topics.length == 4, "three indexed arguments plus the signature");
            require(events[i].topics[1] == bytes32(uint256(uint160(TOKEN))), "tokenAddress");
            require(events[i].topics[2] == bytes32(memberId), "voterId");
            require(events[i].topics[3] == bytes32(ids[i]), "proposalId follows the batch order");
            (uint256 round, uint256 votes) = abi.decode(events[i].data, (uint256, uint256));
            require(round == 1, "round is part of the payload");
            require(votes == 30, "votes is the amount for this proposal");
        }
    }

    function testNoEventSurvivesARevertedCall() external {
        uint256 memberId = _memberIds[0];
        uint256[] memory ids = _proposeBatch(TOKEN, 1);

        vm.recordLogs();
        _expectRevertAs(
            memberId,
            abi.encodeCall(vote.vote, (TOKEN, memberId, ids, _singleton(0), new bytes[][](0))),
            abi.encodeWithSelector(IVoteErrors.VotesMustBeGreaterThanZero.selector),
            "zero amount"
        );
        require(_votedLogs().length == 0, "a reverted call leaves no event behind");
    }

    function testEventOrderFollowsTheBatchOrder() external {
        uint256 memberId = _memberIds[0];
        uint256 first = _proposeWithMode(TOKEN, address(target), TargetMode.Callback);
        uint256 second = _proposeNoCallback(TOKEN);
        uint256 third = _proposeNoCallback(TOKEN);

        uint256[] memory ids = new uint256[](3);
        ids[0] = first;
        ids[1] = second;
        ids[2] = third;

        vm.recordLogs();
        _voteWithoutData(TOKEN, memberId, ids, _filled(3, 10));
        VoteVm.Log[] memory events = _votedLogs();

        require(events.length == 3, "one event per proposal");
        for (uint256 i = 0; i < events.length; i++) {
            require(events[i].topics[3] == bytes32(ids[i]), "events keep the caller's order");
        }
    }

    // ============ vote: target callbacks ============

    function testNoCallbackModeNeverCallsTheTarget() external {
        uint256 memberId = _memberIds[0];
        // The proposal points at the mock, but its mode forbids callbacks in both places.
        uint256 proposalId = _proposeWithMode(TOKEN, address(target), TargetMode.NoCallback);
        stake.setBoost(TOKEN, 1, memberId, 50);

        _voteWithoutData(TOKEN, memberId, _singleton(proposalId), _singleton(10));

        require(target.createdCalls() == 0, "NoCallback skips the create hook too");
        require(target.votedCalls() == 0, "NoCallback never reaches the vote hook");
        require(vote.votesNumByProposalId(TOKEN, 1, proposalId) == 10, "the vote is still recorded");
    }

    function testCallbackReceivesEveryArgument() external {
        uint256 memberId = _memberIds[0];
        uint256 proposalId = _proposeWithMode(TOKEN, address(target), TargetMode.Callback);
        stake.setBoost(TOKEN, 1, memberId, 50);

        bytes[][] memory rows = new bytes[][](1);
        rows[0] = new bytes[](2);
        rows[0][0] = abi.encode(7);
        rows[0][1] = hex"deadbeef";

        (bool ok,) = _voteWithData(TOKEN, memberId, _singleton(proposalId), _singleton(10), rows);
        require(ok, "vote must succeed");

        require(target.lastVotedTokenAddress() == TOKEN, "tokenAddress");
        require(target.lastVotedRound() == 1, "round");
        require(target.lastVotedProposalId() == proposalId, "proposalId");
        require(target.lastVotedVoterId() == memberId, "voterId");
        require(target.lastVotedVotes() == 10, "votes is this proposal's amount");
        require(target.lastVotedOuterDataLength() == 2, "the row is passed through untouched");
        require(keccak256(target.votedFirstDataAt(0)) == keccak256(abi.encode(7)), "first element verbatim");
    }

    /// @dev Each callback receives the row that belongs to its own proposal, in order.
    function testCallbackGetsTheRowOfItsOwnProposal() external {
        uint256 memberId = _memberIds[0];
        uint256 first = _proposeWithMode(TOKEN, address(target), TargetMode.Callback);
        uint256 second = _proposeWithMode(TOKEN, address(target), TargetMode.Callback);

        uint256[] memory ids = new uint256[](2);
        ids[0] = first;
        ids[1] = second;

        bytes[][] memory rows = new bytes[][](2);
        rows[0] = new bytes[](1);
        rows[0][0] = abi.encode(11);
        rows[1] = new bytes[](1);
        rows[1][0] = abi.encode(22);

        (bool ok,) = _voteWithData(TOKEN, memberId, ids, _filled(2, 10), rows);
        require(ok, "vote must succeed");
        require(target.votedCalls() == 2, "both proposals are Callback mode");
        require(keccak256(target.votedFirstDataAt(0)) == keccak256(abi.encode(11)), "row 0 reaches proposal 0");
        require(keccak256(target.votedFirstDataAt(1)) == keccak256(abi.encode(22)), "row 1 reaches proposal 1");
    }

    /// @dev Vote accepts both "no rows at all" and "one row per proposal". The callback receives the
    ///      inner row, so the two forms are the same input: an empty row either way.
    function testEmptyOuterArrayEqualsOneEmptyRowPerProposal() external {
        uint256 memberId = _memberIds[0];
        uint256 first = _proposeWithMode(TOKEN, address(target), TargetMode.Callback);
        uint256 second = _proposeWithMode(TOKEN, address(target), TargetMode.Callback);

        uint256[] memory ids = new uint256[](2);
        ids[0] = first;
        ids[1] = second;

        (bool ok,) = _voteWithData(TOKEN, memberId, ids, _filled(2, 10), new bytes[][](0));
        require(ok, "an empty outer array is accepted");
        require(target.votedCalls() == 2, "and still calls back for every proposal");
        require(target.votedOuterDataLengthAt(0) == 0 && target.votedOuterDataLengthAt(1) == 0, "empty rows");

        (ok,) = _voteWithData(TOKEN, memberId, ids, _filled(2, 10), _emptyRows(2));
        require(ok, "one empty row per proposal is accepted");
        require(target.votedCalls() == 4, "one more call per proposal");
        require(
            target.votedOuterDataLengthAt(2) == 0 && target.votedOuterDataLengthAt(3) == 0,
            "the callback sees an empty row either way"
        );
    }

    function testCallbackSeesTheDeltaNotTheRunningTotal() external {
        uint256 memberId = _memberIds[0];
        uint256 first = _proposeWithMode(TOKEN, address(target), TargetMode.Callback);
        uint256 second = _proposeWithMode(TOKEN, address(target), TargetMode.Callback);

        uint256[] memory ids = new uint256[](2);
        ids[0] = first;
        ids[1] = second;

        uint256[] memory votes = _filled(2, 30);
        votes[1] = 20;
        _voteWithoutData(TOKEN, memberId, ids, votes);

        require(target.votedVotesAt(0) == 30 && target.votedVotesAt(1) == 20, "each call carries its own delta");
        require(vote.votesNumByMemberId(TOKEN, 1, memberId) == 50, "state holds the running total");
    }

    /// @dev Checks-effects-interactions: the callback runs after the vote counters are written, so a
    ///      Target can rely on reading the updated record from inside the hook.
    function testCallbackObservesStateAlreadyWritten() external {
        uint256 memberId = _memberIds[0];
        uint256 proposalId = _proposeWithMode(TOKEN, address(target), TargetMode.Callback);
        stake.setBoost(TOKEN, 1, memberId, 50);

        _voteWithoutData(TOKEN, memberId, _singleton(proposalId), _singleton(30));

        require(target.observedVotesNumAt(0) == 30, "the member total was already written");
        require(vote.votesNumByMemberId(TOKEN, 1, memberId) == 30, "and it matches the final state");
    }

    function testCallbackFailureRollsBackTheWholeBatch() external {
        uint256 memberId = _memberIds[0];
        uint256 first = _proposeWithMode(TOKEN, address(target), TargetMode.Callback);
        uint256 second = _proposeWithMode(TOKEN, address(target), TargetMode.Callback);

        uint256[] memory ids = new uint256[](2);
        ids[0] = first;
        ids[1] = second;

        stake.setBoost(TOKEN, 1, memberId, 50);
        target.setRevertOnVotedCall(2);

        (bool ok, bytes memory data) = _voteWithData(TOKEN, memberId, ids, _filled(2, 10), new bytes[][](0));
        bytes memory expected = abi.encodeWithSelector(MockTarget.MockTargetCallbackFailure.selector, 2);
        require(!ok && keccak256(data) == keccak256(expected), "the callback failure surfaces unchanged");

        _assertAllVoteStateEmpty(TOKEN, 1, memberId);
        (uint256[] memory voted, uint256 total) = vote.votedProposalIds(TOKEN, 1, 0, 10, false);
        require(voted.length == 0 && total == 0, "the accepted first entry was rolled back");
    }

    function testCallbackFailureOnTheFirstProposalLeavesNothing() external {
        uint256 memberId = _memberIds[0];
        uint256 proposalId = _proposeWithMode(TOKEN, address(target), TargetMode.Callback);
        stake.setBoost(TOKEN, 1, memberId, 50);

        target.setRevertOnVotedCall(1);

        (bool ok, bytes memory data) = _voteWithData(TOKEN, memberId, _singleton(proposalId), _singleton(10), new bytes[][](0));
        bytes memory expected = abi.encodeWithSelector(MockTarget.MockTargetCallbackFailure.selector, 1);
        require(!ok && keccak256(data) == keccak256(expected), "the callback failure surfaces unchanged");

        _assertAllVoteStateEmpty(TOKEN, 1, memberId);
        require(vote.stakedAmountOfVotersByMemberId(TOKEN, 1, memberId) == 0, "snapshot rolled back");
    }
    // ============ paginated queries ============

    function testVotedProposalIdsPaginationWindows() external {
        uint256 memberId = _memberIds[5];
        uint256[] memory ids = _proposeBatch(TOKEN, 5);
        _voteWithoutData(TOKEN, memberId, ids, _filled(5, 10));

        (uint256[] memory page, uint256 total) = vote.votedProposalIds(TOKEN, 1, 0, 2, false);
        require(total == 5 && page.length == 2 && page[0] == ids[0] && page[1] == ids[1], "first page");

        (page, total) = vote.votedProposalIds(TOKEN, 1, 2, 2, false);
        require(total == 5 && page.length == 2 && page[0] == ids[2] && page[1] == ids[3], "second page");

        (page, total) = vote.votedProposalIds(TOKEN, 1, 4, 2, false);
        require(total == 5 && page.length == 1 && page[0] == ids[4], "limit clipped to what is left");

        (page, total) = vote.votedProposalIds(TOKEN, 1, 5, 2, false);
        require(total == 5 && page.length == 0, "offset at the end returns nothing");

        (page, total) = vote.votedProposalIds(TOKEN, 1, type(uint256).max, 2, false);
        require(total == 5 && page.length == 0, "a huge offset does not revert");

        (page, total) = vote.votedProposalIds(TOKEN, 1, 0, 0, false);
        require(total == 5 && page.length == 0, "a zero limit returns the total only");

        (page, total) = vote.votedProposalIds(TOKEN, 1, 0, 100, false);
        require(page.length == 5 && total == 5, "a limit above the total returns everything");

        (page,) = vote.votedProposalIds(TOKEN, 1, 0, 2, true);
        require(page.length == 2 && page[0] == ids[4] && page[1] == ids[3], "reverse starts at the newest");

        (page,) = vote.votedProposalIds(TOKEN, 1, 3, 2, true);
        require(page.length == 2 && page[0] == ids[1] && page[1] == ids[0], "reverse offset skips from the newest");
    }

    function testVotedProposalIdsByMemberIdPaginationWindows() external {
        uint256 memberId = _memberIds[5];
        uint256[] memory ids = _proposeBatch(TOKEN, 4);
        _voteWithoutData(TOKEN, memberId, ids, _filled(4, 10));

        (uint256[] memory page, uint256 total) = vote.votedProposalIdsByMemberId(TOKEN, 1, memberId, 1, 2, false);
        require(total == 4 && page.length == 2 && page[0] == ids[1] && page[1] == ids[2], "first page");

        (page, total) = vote.votedProposalIdsByMemberId(TOKEN, 1, memberId, 3, 5, false);
        require(total == 4 && page.length == 1 && page[0] == ids[3], "second page");

        (page, total) = vote.votedProposalIdsByMemberId(TOKEN, 1, memberId, 4, 5, false);
        require(total == 4 && page.length == 0, "offset at the end");

        (page,) = vote.votedProposalIdsByMemberId(TOKEN, 1, memberId, 1, 2, true);
        require(page.length == 2 && page[0] == ids[2] && page[1] == ids[1], "reverse page");

        (page, total) = vote.votedProposalIdsByMemberId(TOKEN, 1, _memberIds[6], 0, 5, false);
        require(total == 0 && page.length == 0, "a member who never voted");
    }

    function testVoterIdsByProposalIdPaginationWindows() external {
        uint256[] memory ids = _proposeBatch(TOKEN, 1);
        uint256 first = _memberIds[5];
        uint256 second = _memberIds[6];
        uint256 third = _memberIds[7];

        _voteWithoutData(TOKEN, first, ids, _singleton(10));
        _voteWithoutData(TOKEN, second, ids, _singleton(10));
        _voteWithoutData(TOKEN, third, ids, _singleton(10));

        (uint256[] memory page, uint256 total) = vote.voterIdsByProposalId(TOKEN, 1, ids[0], 0, 2, false);
        require(total == 3 && page.length == 2 && page[0] == first && page[1] == second, "first page");

        (page, total) = vote.voterIdsByProposalId(TOKEN, 1, ids[0], 2, 2, false);
        require(total == 3 && page.length == 1 && page[0] == third, "second page");

        (page,) = vote.voterIdsByProposalId(TOKEN, 1, ids[0], 0, 2, true);
        require(page.length == 2 && page[0] == third && page[1] == second, "reverse page");

        (page, total) = vote.voterIdsByProposalId(TOKEN, 1, 999, 0, 2, false);
        require(total == 0 && page.length == 0, "a proposal nobody voted for");
    }

    function testVotesNumsByMemberIdPairsIdsWithTheirAmounts() external {
        uint256 memberId = _memberIds[5];
        uint256[] memory ids = _proposeBatch(TOKEN, 3);

        uint256[] memory votes = _filled(3, 10);
        votes[1] = 20;
        votes[2] = 30;
        _voteWithoutData(TOKEN, memberId, ids, votes);

        (uint256[] memory list, uint256[] memory amounts, uint256 total) =
            vote.votesNumsByMemberId(TOKEN, 1, memberId, 0, 2, false);
        require(total == 3 && list.length == 2 && amounts.length == 2, "page sizes");
        require(list[0] == ids[0] && amounts[0] == 10 && list[1] == ids[1] && amounts[1] == 20, "pairs align");

        (list, amounts,) = vote.votesNumsByMemberId(TOKEN, 1, memberId, 0, 3, true);
        require(list[0] == ids[2] && amounts[0] == 30, "reverse keeps the pairing");
        require(list[1] == ids[1] && amounts[1] == 20, "reverse second pair");
        require(list[2] == ids[0] && amounts[2] == 10, "reverse third pair");

        (list, amounts, total) = vote.votesNumsByMemberId(TOKEN, 1, memberId, 3, 3, false);
        require(total == 3 && list.length == 0 && amounts.length == 0, "offset at the end");
    }

    function testVotesNumsByMemberIdByProposalIdsMirrorsTheRequest() external {
        uint256 memberId = _memberIds[5];
        uint256[] memory ids = _proposeBatch(TOKEN, 3);

        uint256[] memory votes = _filled(3, 10);
        votes[1] = 20;
        votes[2] = 30;
        _voteWithoutData(TOKEN, memberId, ids, votes);

        uint256[] memory requested = new uint256[](4);
        requested[0] = ids[2];
        requested[1] = 999;
        requested[2] = ids[0];
        requested[3] = ids[2];

        uint256[] memory answer = vote.votesNumsByMemberIdByProposalIds(TOKEN, 1, memberId, requested);
        require(answer.length == 4, "one slot per requested id");
        require(answer[0] == 30 && answer[1] == 0 && answer[2] == 10 && answer[3] == 30, "order kept, unknown is zero");

        answer = vote.votesNumsByMemberIdByProposalIds(TOKEN, 1, memberId, new uint256[](0));
        require(answer.length == 0, "an empty request returns an empty answer");
    }

    // ============ cross-token and cross-module ============

    function testTokensShareNoState() external {
        uint256 memberId = _memberIds[5];
        uint256[] memory first = _proposeBatch(TOKEN, 1);
        uint256[] memory second = _proposeBatch(TOKEN2, 1);
        require(first[0] == 1 && second[0] == 1, "both tokens number proposals from one");

        _voteWithoutData(TOKEN, memberId, first, _singleton(10));
        _voteWithoutData(TOKEN2, memberId, second, _singleton(20));

        require(vote.votesNum(TOKEN, 1) == 10 && vote.votesNum(TOKEN2, 1) == 20, "round totals are separate");
        require(
            vote.votesNumByProposalId(TOKEN, 1, 1) == 10 && vote.votesNumByProposalId(TOKEN2, 1, 1) == 20,
            "proposal totals are separate"
        );
        require(
            vote.votesNumByMemberId(TOKEN, 1, memberId) == 10
                && vote.votesNumByMemberId(TOKEN2, 1, memberId) == 20,
            "member totals are separate"
        );

        (uint256[] memory list, uint256 total) = vote.votedProposalIds(TOKEN, 1, 0, 10, false);
        require(total == 1 && list[0] == 1, "token one list");
        (list, total) = vote.votedProposalIds(TOKEN2, 1, 0, 10, false);
        require(total == 1 && list[0] == 1, "token two list");

        (uint256[] memory voters,) = vote.voterIdsByProposalId(TOKEN2, 1, 1, 0, 10, false);
        require(voters.length == 1 && voters[0] == memberId, "token two voter list");
    }

    /// @dev The first submission of a round calibrates Phase; Vote must follow the calibrated round
    ///      rather than run on its own notion of time.
    function testPhaseCalibrationFromSubmitIsSharedWithVote() external {
        _proposeBatch(TOKEN, 1);

        vm.roll(201);
        vm.warp(1505);
        uint256 memberId = _memberIds[5];
        uint256 second = _proposeWithMode(TOKEN, EOA_TARGET, TargetMode.NoCallback);

        require(vote.currentRound() == 2, "still round 2 while calibrating");
        (uint256 startBlock, uint256 phaseBlocks) = phase.phaseInfo(3);
        require(startBlock == 300 && phaseBlocks == 200, "phase 3 was calibrated");

        _voteWithoutData(TOKEN, memberId, _singleton(second), _singleton(10));
        require(vote.votesNumByProposalId(TOKEN, 2, second) == 10, "counted in round 2");

        vm.roll(400);
        require(vote.currentRound() == 3, "round 3 starts at the calibrated block");
        uint256 resubmitter = _nextSubmitter();
        vm.prank(_ownerOfMember(resubmitter));
        submit.submit(TOKEN, resubmitter, second);

        _voteWithoutData(TOKEN, memberId, _singleton(second), _singleton(10));
        require(vote.votesNumByProposalId(TOKEN, 3, second) == 10, "counted in the calibrated round 3");
        require(vote.votesNumByProposalId(TOKEN, 2, second) == 10, "round 2 keeps its own total");
    }

    /// @dev What a later module reads: the snapshot of a finished round must not move when staking
    ///      continues afterwards.
    function testSnapshotOfAFinishedRoundStaysFrozen() external {
        uint256 memberId = _memberIds[0];
        uint256[] memory ids = _proposeBatch(TOKEN, 1);
        stake.setBoost(TOKEN, 1, memberId, 50);
        _voteWithoutData(TOKEN, memberId, ids, _singleton(10));

        _advanceRounds(2);
        stake.setBoost(TOKEN, 3, memberId, 999);

        require(vote.votesNumByMemberId(TOKEN, 1, memberId) == 10, "votes of round 1 stay frozen");
        require(vote.stakedAmountOfVotersByMemberId(TOKEN, 1, memberId) == 50, "member snapshot stays frozen");
        require(vote.stakedAmountOfVoters(TOKEN, 1) == 50, "round total stays frozen");
        require(vote.stakedAmountOfVotersByMemberId(TOKEN, 3, memberId) == 0, "round 3 has no snapshot yet");

        (uint256[] memory list, uint256 total) = vote.votedProposalIds(TOKEN, 1, 0, 10, false);
        require(total == 1 && list.length == 1, "the round 1 list stays readable");
    }
    // ============ fuzzed invariants ============

    function testFuzzASingleVoteUpToTheAllowanceIsAccepted(uint96 capSeed, uint96 amountSeed) external {
        uint256 cap = 1 + (uint256(capSeed) % 1e24);
        uint256 amount = 1 + (uint256(amountSeed) % cap);

        uint256 memberId = _memberIds[0];
        stake.setValidGovVotes(TOKEN, memberId, cap);
        uint256[] memory ids = _proposeBatch(TOKEN, 1);

        _voteWithoutData(TOKEN, memberId, ids, _singleton(amount));

        require(vote.votesNumByMemberId(TOKEN, 1, memberId) == amount, "the whole amount is stored");
        require(vote.votesNum(TOKEN, 1) == amount, "and it is the round total");
        require(vote.votesNumByProposalId(TOKEN, 1, ids[0]) == amount, "and the proposal total");
    }

    function testFuzzASingleVoteOverTheAllowanceReverts(uint96 capSeed, uint96 extraSeed) external {
        uint256 cap = 1 + (uint256(capSeed) % 1e24);
        uint256 amount = cap + 1 + (uint256(extraSeed) % 1e24);

        uint256 memberId = _memberIds[0];
        stake.setValidGovVotes(TOKEN, memberId, cap);
        uint256[] memory ids = _proposeBatch(TOKEN, 1);

        bytes memory expected = abi.encodeWithSelector(IVoteErrors.NotEnoughVotesLeft.selector);
        _expectRevertAs(
            memberId,
            abi.encodeCall(vote.vote, (TOKEN, memberId, ids, _singleton(amount), new bytes[][](0))),
            expected,
            "over the allowance"
        );
        _assertAllVoteStateEmpty(TOKEN, 1, memberId);
    }

    function testFuzzBatchTotalsAreTheSumOfTheirParts(uint96 firstSeed, uint96 secondSeed) external {
        uint256 firstAmount = 1 + (uint256(firstSeed) % 1e20);
        uint256 secondAmount = 1 + (uint256(secondSeed) % 1e20);

        uint256 memberId = _memberIds[0];
        stake.setValidGovVotes(TOKEN, memberId, 1e24);
        uint256[] memory ids = _proposeBatch(TOKEN, 2);

        uint256[] memory votes = _filled(2, firstAmount);
        votes[1] = secondAmount;
        _voteWithoutData(TOKEN, memberId, ids, votes);

        uint256 sum = firstAmount + secondAmount;
        require(vote.votesNum(TOKEN, 1) == sum, "round total");
        require(vote.votesNumByMemberId(TOKEN, 1, memberId) == sum, "member total");
        require(vote.votesNumByProposalId(TOKEN, 1, ids[0]) == firstAmount, "first proposal");
        require(vote.votesNumByProposalId(TOKEN, 1, ids[1]) == secondAmount, "second proposal");
        require(vote.votesNumByMemberIdByProposalId(TOKEN, 1, memberId, ids[0]) == firstAmount, "member first");
        require(vote.votesNumByMemberIdByProposalId(TOKEN, 1, memberId, ids[1]) == secondAmount, "member second");
    }

    /// @dev The snapshot only ever credits growth, so after two votes around two boost readings the
    ///      recorded value must be exactly the larger of the two.
    function testFuzzSnapshotIsTheLargerOfTheObservedBoosts(uint96 firstSeed, uint96 secondSeed) external {
        uint256 firstBoost = uint256(firstSeed) % 1e24;
        uint256 secondBoost = uint256(secondSeed) % 1e24;

        uint256 memberId = _memberIds[0];
        uint256[] memory ids = _proposeBatch(TOKEN, 2);

        stake.setBoost(TOKEN, 1, memberId, firstBoost);
        _voteWithoutData(TOKEN, memberId, _singleton(ids[0]), _singleton(1));
        stake.setBoost(TOKEN, 1, memberId, secondBoost);
        _voteWithoutData(TOKEN, memberId, _singleton(ids[1]), _singleton(1));

        uint256 expected = firstBoost > secondBoost ? firstBoost : secondBoost;
        require(vote.stakedAmountOfVotersByMemberId(TOKEN, 1, memberId) == expected, "member snapshot");
        require(vote.stakedAmountOfVoters(TOKEN, 1) == expected, "round snapshot");
    }

    /// @dev An independent implementation of the page window, checked against all three lists.
    function testFuzzPageWindowMatchesTheUnderlyingSlice(
        uint8 countSeed,
        uint8 offsetSeed,
        uint8 limitSeed,
        bool reverse
    ) external {
        uint256 count = uint256(countSeed) % 9;
        uint256[] memory ids = _proposeBatch(TOKEN, count);
        uint256 memberId = _memberIds[8];
        if (count > 0) {
            _voteWithoutData(TOKEN, memberId, ids, _filled(count, 1));
        }
        _assertPageWindows(ids, memberId, uint256(offsetSeed) % 12, uint256(limitSeed) % 12, reverse);
    }

    function _assertPageWindows(
        uint256[] memory ids,
        uint256 memberId,
        uint256 offset,
        uint256 limit,
        bool reverse
    ) private view {
        uint256[] memory expected = _expectedPage(ids, offset, limit, reverse);

        (uint256[] memory page, uint256 total) = vote.votedProposalIds(TOKEN, 1, offset, limit, reverse);
        require(total == ids.length, "the round list reports the true total");
        require(keccak256(abi.encode(page)) == keccak256(abi.encode(expected)), "round list page");

        (page, total) = vote.votedProposalIdsByMemberId(TOKEN, 1, memberId, offset, limit, reverse);
        require(total == ids.length, "the member list reports the true total");
        require(keccak256(abi.encode(page)) == keccak256(abi.encode(expected)), "member list page");

        uint256[] memory voterIds = ids.length > 0 ? _singleton(memberId) : new uint256[](0);
        (page, total) = vote.voterIdsByProposalId(TOKEN, 1, 1, offset, limit, reverse);
        require(total == voterIds.length, "the voter list reports the true total");
        require(
            keccak256(abi.encode(page)) == keccak256(abi.encode(_expectedPage(voterIds, offset, limit, reverse))),
            "voter list page"
        );
    }

    function _expectedPage(uint256[] memory ids, uint256 offset, uint256 limit, bool reverse)
        private
        pure
        returns (uint256[] memory expected)
    {
        uint256 total = ids.length;
        if (offset >= total || limit == 0) {
            return new uint256[](0);
        }
        uint256 remaining = total - offset;
        uint256 size = remaining < limit ? remaining : limit;
        expected = new uint256[](size);
        for (uint256 i = 0; i < size; i++) {
            uint256 index = reverse ? total - 1 - offset - i : offset + i;
            expected[i] = ids[index];
        }
    }
}

/// @notice Vote wired to a Submit stub: it reaches the guard that a real Submit makes unreachable
///         (it refuses a zero target outright) and batch sizes a real Submit cannot assemble, since
///         it allows only one submission per member per round.
contract VoteStubTest {
    VoteVm private constant vm = VoteVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant ORIGIN_BLOCKS = 100;
    uint256 private constant MAX_PROPOSAL_ID = 64;
    address private constant TOKEN = address(0xBEEF);
    address private constant OWNER = address(0x9001);
    address private constant MINT_ADDRESS = address(0x1234);

    Phase private phase;
    MockStake private stake;
    MockSubmit private submitStub;
    MockTarget private target;
    Vote private vote;
    MemberNFT private memberNFT;
    LOVE20Token private feeToken;

    uint256 private _memberId;

    function setUp() public {
        vm.roll(ORIGIN_BLOCKS);
        vm.warp(1000);

        phase = new Phase(ORIGIN_BLOCKS, 100, 1000, 1e17, 10);
        stake = new MockStake();
        stake.setPhase(address(phase));

        feeToken = new LOVE20Token("LOVE20", "LOVE20", 1000e18, 1000e18, address(this), address(this), address(0xdead));
        memberNFT = new MemberNFT(1e8, 7, 10, 32);
        memberNFT.init(address(feeToken));

        submitStub = new MockSubmit();
        vote = new Vote();
        vote.init(address(phase), address(stake), address(submitStub), address(memberNFT), MINT_ADDRESS);
        target = new MockTarget(address(vote));

        vm.prank(OWNER);
        (_memberId,) = memberNFT.mint("voter");
        stake.setValidGovVotes(TOKEN, _memberId, type(uint256).max);

        for (uint256 proposalId = 1; proposalId <= MAX_PROPOSAL_ID; proposalId++) {
            submitStub.setSubmitted(TOKEN, 1, proposalId, true);
        }
    }

    function _ids(uint256 firstProposalId, uint256 count) private pure returns (uint256[] memory ids) {
        ids = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            ids[i] = firstProposalId + i;
        }
    }

    function _ones(uint256 count) private pure returns (uint256[] memory votes) {
        votes = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            votes[i] = 1;
        }
    }

    /// @dev `Callback` with a zero target is skipped rather than called; the vote still lands.
    function testCallbackModeWithZeroTargetSkipsTheHook() external {
        submitStub.setTarget(TOKEN, 1, address(0), TargetMode.Callback);

        vm.prank(OWNER);
        vote.vote(TOKEN, _memberId, _ids(1, 1), _ones(1), new bytes[][](0));

        require(vote.votesNumByProposalId(TOKEN, 1, 1) == 1, "the vote is still recorded");
        require(target.votedCalls() == 0, "the zero address is never called");
    }

    /// @dev There is no protocol level cap on the batch size; the caller splits by block gas.
    function testBatchSizeHasNoProtocolCap() external {
        uint256 size = MAX_PROPOSAL_ID;

        vm.prank(OWNER);
        vote.vote(TOKEN, _memberId, _ids(1, size), _ones(size), new bytes[][](0));

        require(vote.votesNum(TOKEN, 1) == size, "every entry is recorded");
        require(vote.votesNumByMemberId(TOKEN, 1, _memberId) == size, "member total");

        (uint256[] memory list, uint256 total) = vote.votedProposalIds(TOKEN, 1, 0, size, false);
        require(total == size && list.length == size, "the round list holds every proposal");
    }

    /// @dev Guards the shape of the cost curve rather than its absolute value: with a stubbed Stake the
    ///      numbers are a lower bound, but a per-entry re-read of the allowance, the submission state
    ///      or the record set would make the per entry cost grow with the batch, and that must not
    ///      happen.
    function testBatchCostIsLinearInTheBatchSize() external {
        uint256 small = _measureBatch(1, 8);
        uint256 large = _measureBatch(9, 32);

        uint256 perEntrySmall = small / 8;
        uint256 perEntryLarge = large / 32;

        require(
            perEntryLarge <= perEntrySmall,
            string.concat("per entry cost must not grow with the batch: ", _decimal(perEntrySmall), " then ", _decimal(perEntryLarge))
        );
        require(perEntryLarge <= 250_000, string.concat("per entry ceiling: ", _decimal(perEntryLarge)));

        // Recorded batch scale. Under the stubbed Stake one entry costs about 157k gas, so a 30M gas
        // block fits well over a hundred entries; the real Stake adds two external reads per entry,
        // so this is a lower bound on the batch size rather than an upper bound.
        uint256 entriesPerBlock = 30_000_000 / perEntryLarge;
        require(entriesPerBlock >= 100, string.concat("entries per 30M gas block: ", _decimal(entriesPerBlock)));
    }

    function _measureBatch(uint256 firstProposalId, uint256 size) private returns (uint256 gasUsed) {
        uint256[] memory ids = _ids(firstProposalId, size);
        uint256[] memory votes = _ones(size);

        uint256 before = gasleft();
        vm.prank(OWNER);
        vote.vote(TOKEN, _memberId, ids, votes, new bytes[][](0));
        gasUsed = before - gasleft();
    }

    function _decimal(uint256 value) private pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits += 1;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
