// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Mint} from "../src/Mint.sol";
import {LOVE20Token} from "../src/LOVE20Token.sol";
import {IMintErrors} from "../src/interfaces/IMint.sol";
import {ISubmitErrors, TargetMode} from "../src/interfaces/ISubmit.sol";
import {IERC721Errors} from "../lib/openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";

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
    uint256 totalVotes = 1;
    uint256 memberVotes = 1;
    uint256 firstVotes = 1;
    uint256 secondVotes;
    uint256 proposalCount = 1;
    uint256 minVoteRatio = 50;
    uint256 totalBoost;
    uint256 memberBoost;
    bool rejectProposalScan;
    uint256 public LAUNCH_RATIO = 1e16;
    uint256 public constant MAX_LAUNCH_COUNT = 1000;
    mapping(address => uint256) public issuedLaunchCount;

    function setupMint(uint256 supply, uint256 maxSupply, uint256 govRatio, uint256 proposalRatio) internal {
        mint = new Mint();
        mint.init(
            address(this),
            address(this),
            address(this),
            address(this),
            minVoteRatio,
            govRatio,
            proposalRatio,
            2
        );
        token = new LOVE20Token("Review", "REV", supply, maxSupply, address(this), address(mint), address(1));
    }

    function phaseAddress() external view returns (address) {
        return address(this);
    }

    function currentPhase() external pure returns (uint256) {
        return type(uint256).max;
    }

    function ownerOf(uint256 id) external view returns (address) {
        if (id != 1) revert IERC721Errors.ERC721NonexistentToken(id);
        return address(this);
    }

    function votesNum(address, uint256) external view returns (uint256) {
        return totalVotes;
    }

    function votesNumByMemberId(address, uint256, uint256 id) external view returns (uint256) {
        return id == 1 ? memberVotes : 0;
    }

    function votesNumByProposalId(address, uint256, uint256 id) external view returns (uint256) {
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

    function stakedAmountOfVoters(address, uint256) external view returns (uint256) {
        return totalBoost;
    }

    function stakedAmountOfVotersByMemberId(address, uint256, uint256) external view returns (uint256) {
        return memberBoost;
    }

    function proposalTarget(address, uint256 id) external view returns (address, TargetMode) {
        if (id == 0 || id > proposalCount) revert ISubmitErrors.ProposalNotFound(id);
        return (address(this), TargetMode.NoCallback);
    }

    function addLaunchCount(address community, uint256, uint256 count) external {
        require(msg.sender == address(mint));
        issuedLaunchCount[community] += count;
    }

    function testBatchMustPreserveMemberOwner() public {
        setupMint(1000, 10000, 100, 0);
        uint256[] memory rounds = new uint256[](2);
        rounds[0] = 1;
        rounds[1] = 2;
        (uint256[] memory votes, uint256[] memory boosts, uint256[] memory burns) =
            mint.mintGovRewards(address(token), 1, rounds);
        require(votes.length == 2 && boosts.length == 2 && burns.length == 2, "array lengths");
        require(votes[0] == 450 && votes[1] == 427, "round order");
        require(boosts[0] + boosts[1] + burns[0] + burns[1] == 0, "cancelled boost");
        require(token.balanceOf(address(this)) == 1877 && mint.rewardMinted(address(token)) == 877, "batch reward");
    }

    function testBatchFailureRollsBackRewardsAndLaunchCounts() public {
        setupMint(1000, 10000, 100, 0);
        uint256[] memory rounds = new uint256[](2);
        rounds[0] = rounds[1] = 1;
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.AlreadyMinted.selector));
        mint.mintGovRewards(address(token), 1, rounds);
        (,,, bool minted) = mint.govRewardByMemberId(address(token), 1, 1);
        require(!minted && mint.rewardMinted(address(token)) == 0, "reward rollback");
        require(token.totalSupply() == 1000, "token rollback");
        require(issuedLaunchCount[address(token)] == 0 && mint.launchCredit(address(token), 1) == 0, "launch rollback");
    }

    function testEmptyBatchHasNoSideEffects() public {
        setupMint(1000, 10000, 100, 0);
        (uint256[] memory votes, uint256[] memory boosts, uint256[] memory burns) =
            mint.mintGovRewards(address(token), 999, new uint256[](0));
        require(votes.length + boosts.length + burns.length == 0, "empty arrays");
        require(token.totalSupply() == 1000 && mint.rewardMinted(address(token)) == 0, "empty batch mutated");
    }

    function testRewardLargerThanCurrentSupplyMustStillMint() public {
        setupMint(1, 1000, 100, 0);
        mint.mintGovReward(address(token), 1, 1);
        require(token.totalSupply() == 50, "valid reward missing");
    }

    function testLaunchCreditMustUseActualPreMintSupply() public {
        LAUNCH_RATIO = 1e17;
        setupMint(900, 1000, 1000, 0);
        mint.mintGovReward(address(token), 1, 1);
        require(issuedLaunchCount[address(token)] == 5, "launch counts");
        require(mint.launchCredit(address(token), 1) == 0, "exact threshold credit");
    }

    function testLaunchThresholdMustRoundUp() public {
        LAUNCH_RATIO = 15e16;
        setupMint(90, 100, 200, 0);
        mint.mintGovReward(address(token), 1, 1);
        require(issuedLaunchCount[address(token)] == 0, "must retain 1 credit below ceil threshold 2");
        require(mint.launchCredit(address(token), 1) == 1, "fractional credit lost");
    }

    function testLaunchCapRetainsUnconvertedCredit() public {
        LAUNCH_RATIO = 1e17;
        setupMint(900, 1000, 1000, 0);
        issuedLaunchCount[address(token)] = MAX_LAUNCH_COUNT - 1;
        mint.mintGovReward(address(token), 1, 1);
        require(issuedLaunchCount[address(token)] == MAX_LAUNCH_COUNT, "cap exceeded");
        require(mint.launchCredit(address(token), 1) == 40, "capped credit lost");
        mint.mintGovReward(address(token), 1, 2);
        require(mint.launchCredit(address(token), 1) == 40, "credit grew after cap");
    }

    function testProposalBelowFivePercentMustNotQualify() public {
        totalVotes = 21;
        firstVotes = 1;
        secondVotes = 20;
        proposalCount = 2;
        setupMint(1000, 10000, 0, 100);
        // Trigger auto-prepare by minting
        mint.mintProposalReward(address(token), 1, 2);
        require(!mint.isProposalIdWithReward(address(token), 1, 1), "1/21 is less than 5 percent");
        require(mint.eligibleProposalVotes(address(token), 1) == 20, "ineligible votes entered denominator");
        (uint256 amount,) = mint.proposalRewardByProposalId(address(token), 1, 1);
        require(amount == 0, "ineligible query");
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.NoRewardAvailable.selector));
        mint.mintProposalReward(address(token), 1, 1);
        bool minted;
        (amount, minted) = mint.proposalRewardByProposalId(address(token), 1, 2);
        require(amount == 900 && minted, "minted query");
    }

    function testProposalExactlyAtThresholdQualifies() public {
        totalVotes = 20;
        secondVotes = 19;
        proposalCount = 2;
        setupMint(1000, 10000, 0, 100);
        require(mint.isProposalIdWithReward(address(token), 1, 1), "exact 5 percent");
        require(mint.mintProposalReward(address(token), 1, 1) == 45, "exact threshold reward");
        require(mint.launchCredit(address(token), 1) == 0, "proposal added launch credit");
    }

    function testZeroProposalRewardMustRevert() public {
        setupMint(999, 1000, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.NoRewardAvailable.selector));
        mint.mintProposalReward(address(token), 1, 1);
        (, bool minted) = mint.proposalRewardByProposalId(address(token), 1, 1);
        require(!minted && mint.rewardMinted(address(token)) == 0, "zero reward consumed state");
    }

    function testZeroGovRewardMustRevert() public {
        setupMint(999, 1000, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.NoRewardAvailable.selector));
        mint.mintGovReward(address(token), 1, 1);
        (,,, bool minted) = mint.govRewardByMemberId(address(token), 1, 1);
        require(!minted && mint.rewardMinted(address(token)) == 0, "zero gov reward consumed state");
    }

    function testZeroVotePreparationMustEmitEvent() public {
        setupMint(1000, 10000, 100, 0);
        totalVotes = 0;
        firstVotes = 0;
        memberVotes = 0;
        vm.recordLogs();
        // Trigger auto-prepare by attempting to mint
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.NoRewardAvailable.selector));
        mint.mintGovReward(address(token), 1, 2);
        MintVm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("RewardPrepared(address,uint256,uint256,uint256,uint256,uint256,uint256)");
        uint256 count;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(mint) && logs[i].topics[0] == sig) {
                count++;
                require(uint256(logs[i].topics[2]) == 2, "event round");
                require(keccak256(logs[i].data) == keccak256(abi.encode(0, 0, 0, 0, 0)), "event ledger");
            }
        }
        require(count == 1, "RewardPrepared missing for zero-vote round");
        // Note: Since the transaction reverted, the _isRewardPrepared flag was rolled back
        // A second call will emit the event again because the flag is still false
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.NoRewardAvailable.selector));
        mint.mintGovReward(address(token), 1, 2);
        logs = vm.getRecordedLogs();
        uint256 count2;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(mint) && logs[i].topics[0] == sig) {
                count2++;
            }
        }
        require(count2 == 1, "duplicate preparation event");
    }

    function testZeroVoteRoundSettlementMustReject() public {
        setupMint(1000, 10000, 100, 100);
        totalVotes = 0;
        memberVotes = 0;
        firstVotes = 0;
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.NoRewardAvailable.selector));
        mint.mintGovReward(address(token), 1, 2);
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.NoRewardAvailable.selector));
        mint.mintProposalReward(address(token), 2, 1);
        require(mint.rewardMinted(address(token)) == 0, "zero-vote settlement mutated state");
    }

    function testNonexistentRewardQueriesMustRevert() public {
        setupMint(1000, 10000, 100, 0);
        for (uint256 round = 1; round <= 2; round++) {
            vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
            mint.govRewardByMemberId(address(token), round, 999);
            vm.expectRevert(abi.encodeWithSelector(ISubmitErrors.ProposalNotFound.selector, 999));
            mint.proposalRewardByProposalId(address(token), round, 999);
        }
        (uint256 amount, bool minted) = mint.proposalRewardByProposalId(address(token), 2, 1);
        require(amount == 0 && !minted, "valid unprepared proposal");
    }

    function testQueryUnpreparedRoundCalculatesRealtime() public {
        setupMint(1000, 10000, 100, 0);
        // Query before any mint - should calculate real-time
        (uint256 voteReward, uint256 boostReward, uint256 burnReward, bool minted) =
            mint.govRewardByMemberId(address(token), 2, 1);
        require(voteReward == 450 && boostReward == 0 && burnReward == 0 && !minted, "unprepared calculates real-time");
        // Trigger prepare for round 1 by minting (memberVotes = 1 for this round)
        mint.mintGovReward(address(token), 1, 1);
        // Now set memberVotes to 0 and query round 1 - should return cached zero for nonvoter
        memberVotes = 0;
        (voteReward, boostReward, burnReward, minted) = mint.govRewardByMemberId(address(token), 1, 1);
        require(voteReward + boostReward + burnReward == 0 && minted, "nonvoter member reward");
    }

    function testGovernanceQueryMatchesMintAndBoostBurn() public {
        totalVotes = firstVotes = 10;
        totalBoost = 2;
        memberBoost = 1;
        setupMint(1000, 11000, 100, 0);
        (uint256 voteReward, uint256 boostReward, uint256 burnReward, bool minted) =
            mint.govRewardByMemberId(address(token), 1, 1);
        require(voteReward == 50 && boostReward == 100 && burnReward == 150 && !minted, "boost query");
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.NotMemberOwner.selector, 1));
        vm.prank(address(2));
        mint.mintGovReward(address(token), 1, 1);
        (voteReward, boostReward, burnReward) = mint.mintGovReward(address(token), 1, 1);
        require(voteReward == 50 && boostReward == 100 && burnReward == 150, "mint differs from query");
        require(token.totalSupply() == 1150 && mint.rewardBurned(address(token)) == 150, "mint/burn ledger");
        require(mint.reservedAvailable(address(token)) == 700, "remaining reserve");
        (voteReward, boostReward, burnReward, minted) = mint.govRewardByMemberId(address(token), 1, 1);
        require(voteReward == 50 && boostReward == 100 && burnReward == 150 && minted, "settled query");
    }

    function testPrepareScansProposalsOnceAndCachesResult() public {
        totalVotes = memberVotes = proposalCount = 300;
        secondVotes = 1;
        minVoteRatio = 0;
        setupMint(1000, 10000, 0, 100);
        // First mint triggers prepare and scans proposals
        mint.mintProposalReward(address(token), 1, 1);
        require(mint.eligibleProposalVotes(address(token), 1) == 300, "cached votes");
        rejectProposalScan = true;
        // Second mint uses cached data - no scan
        require(mint.mintProposalReward(address(token), 1, 300) == 3, "cached settlement");
    }

    function testBurnUnmintedProposalRewardReturnsAvailability() public {
        totalVotes = 20;
        secondVotes = 19;
        proposalCount = 2;
        setupMint(1000, 10000, 0, 100);
        require(mint.mintProposalReward(address(token), 1, 2) == 855, "prepare via sibling mint");
        uint256 burnedBefore = mint.rewardBurned(address(token));
        uint256 reservedBefore = mint.reservedAvailable(address(token));
        uint256 availableBefore = mint.rewardAvailable(address(token));
        uint256 proposalPoolBefore = mint.proposalReward(address(token), 1);
        uint256 amount = mint.burnUnmintedProposalReward(address(token), 1, 1);
        require(amount == 45, "burn amount");
        require(mint.rewardBurned(address(token)) == burnedBefore + amount, "burned ledger");
        require(mint.reservedAvailable(address(token)) == reservedBefore - amount, "reserved share consumed");
        require(mint.rewardAvailable(address(token)) == availableBefore + amount, "availability restored");
        require(mint.proposalReward(address(token), 1) == proposalPoolBefore, "round pool unchanged");
        require(mint.eligibleProposalVotes(address(token), 1) == 20, "eligible votes unchanged");
        require(token.totalSupply() == 1855, "burn minted nothing");
        (uint256 queryAmount, bool minted) = mint.proposalRewardByProposalId(address(token), 1, 1);
        require(queryAmount == amount && minted, "settled query");
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.AlreadyMinted.selector));
        mint.mintProposalReward(address(token), 1, 1);
    }

    function testBurnUnmintedProposalRewardAutoPrepares() public {
        totalVotes = 20;
        secondVotes = 19;
        proposalCount = 2;
        setupMint(1000, 10000, 0, 100);
        require(!mint.isRewardPrepared(address(token), 1), "precondition");
        uint256 amount = mint.burnUnmintedProposalReward(address(token), 1, 1);
        require(amount == 45 && mint.isRewardPrepared(address(token), 1), "auto-prepared");
        require(mint.proposalReward(address(token), 1) == 900, "frozen pool");
        require(mint.eligibleProposalVotes(address(token), 1) == 20, "frozen eligible votes");
        require(mint.rewardBurned(address(token)) == amount, "burned ledger");
        require(token.totalSupply() == 1000, "nothing minted");
        require(mint.mintProposalReward(address(token), 1, 2) == 855, "sibling share intact");
    }

    function testBurnUnmintedProposalRewardRejectsSettledProposal() public {
        totalVotes = 20;
        secondVotes = 19;
        proposalCount = 2;
        setupMint(1000, 10000, 0, 100);
        require(mint.burnUnmintedProposalReward(address(token), 1, 1) == 45, "first burn");
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.AlreadyMinted.selector));
        mint.burnUnmintedProposalReward(address(token), 1, 1);
        mint.mintProposalReward(address(token), 1, 2);
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.AlreadyMinted.selector));
        mint.burnUnmintedProposalReward(address(token), 1, 2);
    }

    function testBurnUnmintedProposalRewardRejectsIneligibleProposal() public {
        totalVotes = 21;
        firstVotes = 1;
        secondVotes = 20;
        proposalCount = 2;
        setupMint(1000, 10000, 0, 100);
        (uint256 amount,) = mint.proposalRewardByProposalId(address(token), 1, 1);
        require(amount == 0, "ineligible projection");
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.NoRewardAvailable.selector));
        mint.burnUnmintedProposalReward(address(token), 1, 1);
    }
}
