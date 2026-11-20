// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Mint} from "../src/Mint.sol";
import {LOVE20Token} from "../src/LOVE20Token.sol";
import {IMintErrors, ProposalRewardStatus} from "../src/interfaces/IMint.sol";
import {ISubmitErrors, TargetMode} from "../src/interfaces/ISubmit.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

interface MintVm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
    function expectRevert(bytes calldata data) external;
    function prank(address sender) external;
}

contract MintTest {
    MintVm constant vm = MintVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Mint mint;
    LOVE20Token token;
    uint256 totalVoteAmountValue = 1;
    uint256 memberVoteAmount = 1;
    uint256 firstVotes = 1;
    uint256 secondVotes;
    uint256 proposalCount = 1;
    uint256 minVoteRatio = 5e16;
    uint256 totalBoost;
    uint256 memberBoost;
    bool rejectProposalScan;
    uint256 currentPhaseValue = type(uint256).max;
    uint256 public LAUNCH_COUNT_THRESHOLD_RATIO = 1e16;
    uint256 public constant MAX_LAUNCH_COUNT = 1000;
    mapping(address => uint256) public issuedLaunchCount;

    function setupMint(uint256 supply, uint256 maxSupply, uint256 govRatio, uint256 proposalRatio) internal {
        mint = new Mint(
            address(this),
            address(this),
            address(this),
            address(this),
            address(this),
            minVoteRatio,
            govRatio,
            proposalRatio
        );
        token = new LOVE20Token("Review", "REV", supply, maxSupply, address(this), address(mint), address(this));
        if (totalVoteAmountValue != 0) reserveRound(1);
    }

    function reserveRound(uint256 round) internal {
        uint256 phaseBefore = currentPhaseValue;
        currentPhaseValue = round;
        mint.reserveRoundReward(address(token), round);
        currentPhaseValue = phaseBefore;
    }

    function testFirstVoteReservationFixesBudgetsBeforeReverseSettlement() external {
        setupMint(1000e18, 10000e18, 1e17, 1e17);
        currentPhaseValue = 1;
        mint.reserveRoundReward(address(token), 1);
        uint256 first = mint.govReward(address(token), 1);
        mint.reserveRoundReward(address(token), 1);
        require(mint.totalRewardReserved(address(token)) == first * 2, "reserved once");
        currentPhaseValue = 2;
        mint.reserveRoundReward(address(token), 2);
        uint256 second = mint.govReward(address(token), 2);
        require(second < first, "next round sees prior reservation");
        currentPhaseValue = 3;
        require(mint.mintProposalReward(address(token), 2, 1, address(this)) == second, "later proposal settles first");
        (uint256 voteReward,) = mint.mintGovReward(address(token), 1, 1, address(this));
        require(voteReward == first / 2, "earlier governance share is stable");
        require(mint.govReward(address(token), 1) == first, "first budget fixed");
        require(mint.govReward(address(token), 2) == second, "second budget fixed");
    }

    function testZeroPoolsStayReservedAfterSupplyFalls() external {
        setupMint(999, 1000, 1e17, 1e17);
        require(mint.totalRewardReserved(address(token)) == 0, "first reservation rounds both pools to zero");

        token.burn(100);
        currentPhaseValue = 1;
        vm.recordLogs();
        mint.reserveRoundReward(address(token), 1);
        require(vm.getRecordedLogs().length == 0, "no second reservation event");
        require(mint.totalRewardReserved(address(token)) == 0, "round one stays at zero");

        reserveRound(2);
        require(mint.totalRewardReserved(address(token)) == 20, "round two uses the released supply");
    }

    function testReservationCannotBeCalledByAnyoneOrMintBeforeRoundEnd() external {
        setupMint(1000e18, 10000e18, 1e17, 1e17);
        currentPhaseValue = 1;
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.NotVoteContract.selector, address(0xBAD)));
        mint.reserveRoundReward(address(token), 1);
        mint.reserveRoundReward(address(token), 1);
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.RoundNotEnded.selector, 1));
        mint.mintGovReward(address(token), 1, 1, address(this));
    }

    function PHASE_ADDRESS() external view returns (address) {
        return address(this);
    }

    function isLOVE20Token(address tokenAddress) external view returns (bool) {
        return tokenAddress == address(token);
    }

    function currentPhase() external view returns (uint256) {
        return currentPhaseValue;
    }

    function ownerOf(uint256 id) external view returns (address) {
        if (id != 1) revert IERC721Errors.ERC721NonexistentToken(id);
        return address(this);
    }

    function totalVoteAmount(address, uint256) external view returns (uint256) {
        return totalVoteAmountValue;
    }

    function voteAmountByMemberId(address, uint256, uint256 id) external view returns (uint256) {
        return id == 1 ? memberVoteAmount : 0;
    }

    function voteAmountByProposalId(address, uint256, uint256 id) external view returns (uint256) {
        return id == 1 ? firstVotes : id > 1 && id <= proposalCount ? secondVotes : 0;
    }

    function votedProposalIds(address, uint256, uint256, uint256 limit, bool)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        require(!rejectProposalScan, "unexpected proposal scan");
        total = proposalCount;
        ids = new uint256[](limit == 0 ? 0 : total);
        for (uint256 i; i < ids.length; i++) {
            ids[i] = i + 1;
        }
    }

    function totalVoterBoost(address, uint256) external view returns (uint256) {
        return totalBoost;
    }

    function voterBoost(address, uint256, uint256) external view returns (uint256) {
        return memberBoost;
    }

    function proposalTarget(address tokenAddress, uint256 id) external view returns (address, TargetMode) {
        if (id == 0 || id > proposalCount) revert ISubmitErrors.ProposalNotFound(tokenAddress, id);
        return (address(this), TargetMode.NoCallback);
    }

    function addLaunchCount(address community, uint256, uint256 count) external {
        require(msg.sender == address(mint));
        issuedLaunchCount[community] += count;
    }

    function testBatchMustPreserveMemberOwner() public {
        setupMint(1000, 10000, 1e17, 0);
        reserveRound(2);
        uint256[] memory rounds = new uint256[](2);
        rounds[0] = 1;
        rounds[1] = 2;
        (uint256[] memory votes, uint256[] memory boosts) =
            mint.mintGovRewards(address(token), rounds, 1, address(this));
        require(votes.length == 2 && boosts.length == 2, "array lengths");
        require(votes[0] == 450 && votes[1] == 405, "round order");
        require(boosts[0] + boosts[1] == 0, "no voter boost");
        require(token.balanceOf(address(this)) == 1855 && mint.totalRewardMinted(address(token)) == 855, "batch reward");
        require(mint.totalRewardBurned(address(token)) == 0, "batch leaves boost reserves intact");
    }

    function testBatchFailureRollsBackRewardsAndLaunchCounts() public {
        setupMint(1000, 10000, 1e17, 0);
        uint256[] memory rounds = new uint256[](2);
        rounds[0] = rounds[1] = 1;
        vm.expectRevert(
            abi.encodeWithSelector(IMintErrors.MemberRewardAlreadyMinted.selector, address(token), 1, 1)
        );
        mint.mintGovRewards(address(token), rounds, 1, address(this));
        (,, bool minted) = mint.govRewardByMemberId(address(token), 1, 1);
        require(!minted && mint.totalRewardMinted(address(token)) == 0, "reward rollback");
        require(token.totalSupply() == 1000, "token rollback");
        require(issuedLaunchCount[address(token)] == 0 && mint.launchCredit(address(token), 1) == 0, "launch rollback");
        (uint256 voteReward,) = mint.mintGovReward(address(token), 1, 1, address(this));
        require(voteReward == 450 && mint.totalRewardMinted(address(token)) == 450, "retry settles once");
    }

    function testEmptyBatchHasNoSideEffects() public {
        setupMint(1000, 10000, 1e17, 0);
        (uint256[] memory votes, uint256[] memory boosts) =
            mint.mintGovRewards(address(token), new uint256[](0), 1, address(this));
        require(votes.length + boosts.length == 0, "empty arrays");
        require(token.totalSupply() == 1000 && mint.totalRewardMinted(address(token)) == 0, "empty batch mutated");
    }

    function testEmptyBatchChecksOwner() public {
        setupMint(1000, 10000, 1e17, 0);
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.NotMemberOwner.selector, 1));
        mint.mintGovRewards(address(token), new uint256[](0), 1, address(this));
    }

    function testGovMintRejectsZeroRecipient() public {
        setupMint(1000, 10000, 1e17, 0);
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.ZeroRecipientAddress.selector));
        mint.mintGovReward(address(token), 1, 1, address(0));
    }

    function testRewardLargerThanCurrentSupplyMustStillMint() public {
        setupMint(1, 1000, 1e17, 0);
        mint.mintGovReward(address(token), 1, 1, address(this));
        require(token.totalSupply() == 50, "valid reward missing");
    }

    function testLaunchCreditMustUseActualPreMintSupply() public {
        LAUNCH_COUNT_THRESHOLD_RATIO = 1e17;
        setupMint(900, 1000, 1e18, 0);
        mint.mintGovReward(address(token), 1, 1, address(this));
        require(issuedLaunchCount[address(token)] == 5, "launch counts");
        require(mint.launchCredit(address(token), 1) == 0, "exact threshold credit");
    }

    function testLaunchThresholdMustRoundUp() public {
        LAUNCH_COUNT_THRESHOLD_RATIO = 15e16;
        setupMint(90, 100, 2e17, 0);
        mint.mintGovReward(address(token), 1, 1, address(this));
        require(issuedLaunchCount[address(token)] == 0, "must retain 1 credit below ceil threshold 2");
        require(mint.launchCredit(address(token), 1) == 1, "fractional credit lost");
    }

    function testLaunchCapRetainsUnconvertedCredit() public {
        LAUNCH_COUNT_THRESHOLD_RATIO = 1e17;
        setupMint(900, 1000, 1e18, 0);
        issuedLaunchCount[address(token)] = MAX_LAUNCH_COUNT - 1;
        mint.mintGovReward(address(token), 1, 1, address(this));
        require(issuedLaunchCount[address(token)] == MAX_LAUNCH_COUNT, "cap exceeded");
        require(mint.launchCredit(address(token), 1) == 40, "capped credit lost");
        mint.burnUnusedBoostReward(address(token), 1);
        reserveRound(2);
        mint.mintGovReward(address(token), 2, 1, address(this));
        require(mint.launchCredit(address(token), 1) == 40, "credit grew after cap");
    }

    function testProposalBelowFivePercentMustNotQualify() public {
        totalVoteAmountValue = 21;
        firstVotes = 1;
        secondVotes = 20;
        proposalCount = 2;
        setupMint(1000, 10000, 0, 1e17);
        require(mint.mintProposalReward(address(token), 1, 2, address(this)) == 857, "reward uses 20/21");
        require(!mint.isProposalIdWithReward(address(token), 1, 1), "1/21 is less than 5 percent");
        (uint256 amount,) = mint.proposalRewardSettlement(address(token), 1, 1);
        require(amount == 0, "ineligible query");
        vm.expectRevert(
            abi.encodeWithSelector(IMintErrors.ProposalBelowThreshold.selector, address(token), 1, 1, 1, 2)
        );
        mint.mintProposalReward(address(token), 1, 1, address(this));
        ProposalRewardStatus status;
        (amount, status) = mint.proposalRewardSettlement(address(token), 1, 2);
        require(amount == 857 && status == ProposalRewardStatus.Minted, "minted query");
    }

    function testProposalExactlyAtThresholdQualifies() public {
        totalVoteAmountValue = 20;
        secondVotes = 19;
        proposalCount = 2;
        setupMint(1000, 10000, 0, 1e17);
        require(mint.isProposalIdWithReward(address(token), 1, 1), "exact 5 percent");
        require(mint.mintProposalReward(address(token), 1, 1, address(this)) == 45, "exact threshold reward");
        require(mint.launchCredit(address(token), 1) == 0, "proposal added launch credit");
    }

    function testZeroProposalRewardMustRevert() public {
        setupMint(999, 1000, 0, 1e15);
        vm.expectRevert(
            abi.encodeWithSelector(IMintErrors.ProposalPoolEmpty.selector, address(token), 1)
        );
        mint.mintProposalReward(address(token), 1, 1, address(this));
        (, ProposalRewardStatus status) = mint.proposalRewardSettlement(address(token), 1, 1);
        require(
            status == ProposalRewardStatus.Unsettled && mint.totalRewardMinted(address(token)) == 0,
            "zero reward consumed state"
        );
    }

    function testBelowThresholdOutranksAnEmptyPool() public {
        totalVoteAmountValue = 100;
        firstVotes = 1;
        secondVotes = 1;
        proposalCount = 2;
        setupMint(1000, 10000, 0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IMintErrors.ProposalBelowThreshold.selector, address(token), 1, 1, 1, 5)
        );
        mint.mintProposalReward(address(token), 1, 1, address(this));
    }

    function testProposalRewardRoundedToZeroMustRevert() public {
        totalVoteAmountValue = 1000;
        firstVotes = 50;
        secondVotes = 950;
        proposalCount = 2;
        setupMint(999, 1000, 0, 1e18);
        vm.expectRevert(
            abi.encodeWithSelector(IMintErrors.ProposalRewardRoundedToZero.selector, address(token), 1, 1)
        );
        mint.mintProposalReward(address(token), 1, 1, address(this));
    }

    function testMemberRewardRoundedToZeroMustRevert() public {
        setupMint(999, 1000, 1e18, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IMintErrors.MemberRewardRoundedToZero.selector, address(token), 1, 1)
        );
        mint.mintGovReward(address(token), 1, 1, address(this));
    }

    function testZeroGovRewardMustRevert() public {
        setupMint(999, 1000, 1e15, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IMintErrors.MemberRewardPoolEmpty.selector, address(token), 1)
        );
        mint.mintGovReward(address(token), 1, 1, address(this));
        (,, bool minted) = mint.govRewardByMemberId(address(token), 1, 1);
        require(!minted && mint.totalRewardMinted(address(token)) == 0, "zero gov reward consumed state");
    }

    function testZeroVoteRoundCannotMintOrBurnReward() public {
        totalVoteAmountValue = 0;
        memberVoteAmount = 0;
        firstVotes = 0;
        setupMint(1000, 10000, 1e17, 1e17);
        vm.expectRevert(
            abi.encodeWithSelector(IMintErrors.MemberHasNoVote.selector, address(token), 2, 1)
        );
        mint.mintGovReward(address(token), 2, 1, address(this));
        vm.expectRevert(
            abi.encodeWithSelector(IMintErrors.ProposalPoolEmpty.selector, address(token), 2)
        );
        mint.mintProposalReward(address(token), 2, 1, address(this));
        vm.recordLogs();
        mint.burnUnusedBoostReward(address(token), 2);
        mint.burnProposalReward(address(token), 2, 1);
        require(vm.getRecordedLogs().length == 0, "zero-vote burns emit no events");
        require(mint.totalRewardMinted(address(token)) == 0, "zero-vote settlement mutated state");
        require(mint.totalRewardReserved(address(token)) == 0, "zero-vote round used reserve");
        require(mint.totalRewardBurned(address(token)) == 0, "zero-vote round burned reserve");
    }

    function testNonexistentRewardQueriesMustRevert() public {
        setupMint(1000, 10000, 1e17, 0);
        for (uint256 round = 1; round <= 2; round++) {
            vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
            mint.govRewardByMemberId(address(token), round, 999);
            vm.expectRevert(abi.encodeWithSelector(ISubmitErrors.ProposalNotFound.selector, address(token), 999));
            mint.proposalRewardSettlement(address(token), round, 999);
        }
        (uint256 amount, ProposalRewardStatus status) = mint.proposalRewardSettlement(address(token), 2, 1);
        require(amount == 0 && status == ProposalRewardStatus.Unsettled, "valid proposal with no reserved pool");
    }

    function testGovernanceQueryMatchesMintAndBoost() public {
        totalVoteAmountValue = firstVotes = 10;
        totalBoost = 2;
        memberBoost = 1;
        setupMint(1000, 11000, 1e17, 0);
        (uint256 voteReward, uint256 boostReward, bool minted) =
            mint.govRewardByMemberId(address(token), 1, 1);
        require(voteReward == 50 && boostReward == 250 && !minted, "boost query");
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.NotMemberOwner.selector, 1));
        vm.prank(address(2));
        mint.mintGovReward(address(token), 1, 1, address(this));
        (voteReward, boostReward) = mint.mintGovReward(address(token), 1, 1, address(this));
        require(voteReward == 50 && boostReward == 250, "mint differs from query");
        require(token.totalSupply() == 1300 && mint.totalRewardBurned(address(token)) == 0, "mint/burn ledger");
        require(mint.reservedAvailable(address(token)) == 700, "remaining reserve");
        (voteReward, boostReward, minted) = mint.govRewardByMemberId(address(token), 1, 1);
        require(voteReward == 50 && boostReward == 250 && minted, "settled query");
    }

    function testPreviewAndMintNeverReadTheProposalList() public {
        totalVoteAmountValue = memberVoteAmount = proposalCount = 300;
        secondVotes = 1;
        minVoteRatio = 0;
        setupMint(1000, 10000, 0, 1e17);
        rejectProposalScan = true;
        (uint256 amount,) = mint.proposalRewardSettlement(address(token), 1, 1);
        require(amount == 3, "preview uses full round votes");
        require(mint.mintProposalReward(address(token), 1, 1, address(this)) == 3, "first mint uses the reserved pool");
        require(mint.mintProposalReward(address(token), 1, 300, address(this)) == 3, "subsequent mint");
    }

    function testBurnRewardReleasesOnlyTheBelowThresholdShare() public {
        totalVoteAmountValue = 21;
        firstVotes = 1;
        secondVotes = 20;
        proposalCount = 2;
        setupMint(1000, 10000, 0, 1e17);
        rejectProposalScan = true;
        uint256 availableBefore = mint.rewardAvailable(address(token));

        currentPhaseValue = 1;
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.RoundNotEnded.selector, 1));
        mint.burnProposalReward(address(token), 1, 1);
        currentPhaseValue = 2;
        (uint256 amount, ProposalRewardStatus status) = mint.proposalRewardSettlement(address(token), 1, 1);
        require(amount == 0 && status == ProposalRewardStatus.Unsettled, "ineligible reward awaits settlement");

        vm.prank(address(0xCAFE));
        mint.burnProposalReward(address(token), 1, 1);
        (amount, status) = mint.proposalRewardSettlement(address(token), 1, 1);
        require(amount == 42 && status == ProposalRewardStatus.Burned, "burned amount remains queryable");
        require(token.totalSupply() == 1000, "burn only releases the reserve");
        require(mint.totalRewardBurned(address(token)) == 42, "floor(900 / 21)");
        require(mint.rewardAvailable(address(token)) == availableBefore + 42, "share becomes available");
        require(mint.proposalReward(address(token), 1) == 900, "frozen pool");

        vm.recordLogs();
        mint.burnProposalReward(address(token), 1, 1);
        mint.burnProposalReward(address(token), 1, 2);
        mint.burnProposalReward(address(token), 1, 3);
        require(vm.getRecordedLogs().length == 0, "skipped proposals emit no events");
        require(mint.totalRewardBurned(address(token)) == 42, "duplicate, qualifying and zero-vote calls are no-ops");
        vm.expectRevert(
            abi.encodeWithSelector(IMintErrors.ProposalRewardAlreadyBurned.selector, address(token), 1, 1)
        );
        mint.mintProposalReward(address(token), 1, 1, address(this));
        require(mint.mintProposalReward(address(token), 1, 2, address(this)) == 857, "qualifying share is stable");
        require(mint.reservedAvailable(address(token)) == 1, "mixed-round dust remains reserved");
    }

    function testLastBelowThresholdProposalReleasesTheAllIneligiblePool() public {
        totalVoteAmountValue = 3;
        secondVotes = 1;
        proposalCount = 3;
        minVoteRatio = 5e17;
        setupMint(1000, 1002, 0, 1e18);

        require(mint.reservedAvailable(address(token)) == 2, "first vote reserves the pool");
        mint.burnProposalReward(address(token), 1, 3);
        mint.burnProposalReward(address(token), 1, 3);
        mint.burnProposalReward(address(token), 1, 1);
        require(mint.totalRewardBurned(address(token)) == 0, "individual shares round to zero");
        vm.expectRevert(
            abi.encodeWithSelector(IMintErrors.ProposalRewardAlreadyBurned.selector, address(token), 1, 3)
        );
        mint.mintProposalReward(address(token), 1, 3, address(this));
        mint.burnProposalReward(address(token), 1, 2);
        require(mint.totalRewardBurned(address(token)) == 2, "final distinct proposal releases the dust");
        (uint256 amount, ProposalRewardStatus status) = mint.proposalRewardSettlement(address(token), 1, 2);
        require(amount == 0 && status == ProposalRewardStatus.Burned, "round dust is not part of the proposal share");
        require(mint.reservedAvailable(address(token)) == 0, "no locked share");
        require(mint.proposalReward(address(token), 1) == 2, "frozen pool is preserved");
    }

    function testSettlementReleasesReservationAndBurnReturnsAvailability() public {
        totalVoteAmountValue = 20;
        secondVotes = 19;
        proposalCount = 2;
        setupMint(1000, 10000, 0, 1e17);
        require(mint.mintProposalReward(address(token), 1, 2, address(this)) == 855, "settle the other proposal first");
        uint256 reservedBefore = mint.reservedAvailable(address(token));
        uint256 availableBefore = mint.rewardAvailable(address(token));
        uint256 proposalPoolBefore = mint.proposalReward(address(token), 1);
        uint256 amount = mint.mintProposalReward(address(token), 1, 1, address(this));
        require(amount == 45, "settled amount");
        require(mint.totalRewardMinted(address(token)) == 855 + amount, "minted ledger");
        require(mint.reservedAvailable(address(token)) == reservedBefore - amount, "reserved share consumed");
        require(mint.rewardAvailable(address(token)) == availableBefore, "settling is budget neutral");
        require(mint.proposalReward(address(token), 1) == proposalPoolBefore, "round pool unchanged");
        require(token.totalSupply() == 1855 + amount, "reward minted to the recipient");

        // No protocol path burns an unallocatable reward (ADR-004): the Executor never receives
        // those tokens. Burning a settled reward here only probes the Mint ledger — supply returns
        // to where it started and the share goes back to `rewardAvailable`, the same budget effect
        // a settle-by-burn used to have.
        token.burn(amount);
        require(token.totalSupply() == 1855, "destroying restores supply");
        require(mint.rewardAvailable(address(token)) == availableBefore + amount, "share back in circulation");
        require(mint.reservedAvailable(address(token)) == reservedBefore - amount, "destroying re-reserves nothing");

        (uint256 queryAmount, ProposalRewardStatus status) = mint.proposalRewardSettlement(address(token), 1, 1);
        require(queryAmount == amount && status == ProposalRewardStatus.Minted, "settled query");
    }

    function testProposalRewardRejectsRepeatSettlement() public {
        totalVoteAmountValue = 20;
        secondVotes = 19;
        proposalCount = 2;
        setupMint(1000, 10000, 0, 1e17);
        (uint256 amount, ProposalRewardStatus status) = mint.proposalRewardSettlement(address(token), 1, 1);
        require(amount == 45 && status == ProposalRewardStatus.Unsettled, "unsettled quote");
        require(mint.mintProposalReward(address(token), 1, 1, address(this)) == 45, "first settlement");
        (amount, status) = mint.proposalRewardSettlement(address(token), 1, 1);
        require(amount == 45 && status == ProposalRewardStatus.Minted, "minted amount and status");
        vm.expectRevert(
            abi.encodeWithSelector(IMintErrors.ProposalRewardAlreadyMinted.selector, address(token), 1, 1)
        );
        mint.mintProposalReward(address(token), 1, 1, address(this));
        vm.expectRevert(
            abi.encodeWithSelector(IMintErrors.ProposalRewardAlreadyMinted.selector, address(token), 1, 1)
        );
        mint.burnProposalReward(address(token), 1, 1);
        require(mint.totalRewardMinted(address(token)) == 45, "minted share settled once");
        require(mint.totalRewardBurned(address(token)) == 0, "minted share cannot burn");
        mint.mintProposalReward(address(token), 1, 2, address(this));
        vm.expectRevert(
            abi.encodeWithSelector(IMintErrors.ProposalRewardAlreadyMinted.selector, address(token), 1, 2)
        );
        mint.mintProposalReward(address(token), 1, 2, address(this));
    }

    function testProposalRewardRejectsIneligibleProposal() public {
        totalVoteAmountValue = 21;
        firstVotes = 1;
        secondVotes = 20;
        proposalCount = 2;
        setupMint(1000, 10000, 0, 1e17);
        (uint256 amount,) = mint.proposalRewardSettlement(address(token), 1, 1);
        require(amount == 0, "ineligible projection");
        vm.expectRevert(
            abi.encodeWithSelector(IMintErrors.ProposalBelowThreshold.selector, address(token), 1, 1, 1, 2)
        );
        mint.mintProposalReward(address(token), 1, 1, address(this));
    }

    function testBurnUnusedBoostRewardRejectsUnfinishedRound() public {
        setupMint(1000, 10000, 1e17, 1e17);
        currentPhaseValue = 1;
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.RoundNotEnded.selector, 1));
        mint.burnUnusedBoostReward(address(token), 1);
        require(mint.totalRewardBurned(address(token)) == 0, "unfinished round burned reserve");
    }

    function testBurnUnusedBoostRewardRejectsRoundZero() public {
        setupMint(1000, 10000, 1e17, 1e17);
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.RoundNotEnded.selector, 0));
        mint.burnUnusedBoostReward(address(token), 0);
    }

    function testUnusedBoostPoolRequiresExplicitBurn() public {
        totalVoteAmountValue = memberVoteAmount = 100;
        firstVotes = 96;
        secondVotes = 4;
        proposalCount = 2;
        setupMint(1000, 10000, 1e17, 1e17);
        uint256 availableBefore = mint.rewardAvailable(address(token));
        uint256 reservedBefore = mint.totalRewardReserved(address(token));

        (uint256 voteReward, uint256 boostReward) = mint.mintGovReward(address(token), 1, 1, address(this));
        require(voteReward == 450 && boostReward == 0, "governance settlement pays the vote share");
        require(mint.mintProposalReward(address(token), 1, 1, address(this)) == 864, "qualifying proposal can mint");
        require(mint.totalRewardBurned(address(token)) == 0, "minting leaves the boost pool reserved");

        mint.burnProposalReward(address(token), 1, 2);
        require(mint.totalRewardBurned(address(token)) == 36, "only the proposal share is burned");
        require(mint.reservedAvailable(address(token)) == 450, "boost pool remains reserved");
        require(mint.rewardAvailable(address(token)) == availableBefore + 36, "only the proposal share is available");

        vm.prank(address(0xCAFE));
        mint.burnUnusedBoostReward(address(token), 1);
        require(token.totalSupply() == 2314, "burn releases a reservation");

        vm.recordLogs();
        mint.burnUnusedBoostReward(address(token), 1);
        require(vm.getRecordedLogs().length == 0, "retry emits no events");
        require(mint.totalRewardBurned(address(token)) == 486, "boost pool released once");
        require(mint.rewardAvailable(address(token)) == availableBefore + 486, "both burns restore capacity");
        require(mint.totalRewardReserved(address(token)) == reservedBefore, "original reserves unchanged");
    }
}
