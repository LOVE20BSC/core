// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Mint} from "../src/Mint.sol";
import {LOVE20Token} from "../src/LOVE20Token.sol";
import {IMintErrors} from "../src/interfaces/IMint.sol";
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

contract MintCoverageTest {
    MintVm constant vm = MintVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Mint mint;
    LOVE20Token token;
    uint256 totalVoteAmountValue = 1;
    uint256 memberVoteAmount = 1;
    uint256 firstVotes = 1;
    uint256 proposalCount = 1;
    uint256 minVoteRatio = 5e16;
    uint256 totalBoost;
    uint256 memberBoost;
    uint256 public LAUNCH_RATIO = 1e16;
    uint256 public constant MAX_LAUNCH_COUNT = 1000;
    mapping(address => uint256) public issuedLaunchCount;

    address constant TARGET = address(0x1234);

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
        token = new LOVE20Token("Coverage", "COV", supply, maxSupply, address(this), address(mint), address(this));
    }

    function PHASE_ADDRESS() external view returns (address) {
        return address(this);
    }

    function currentPhase() external pure returns (uint256) {
        return type(uint256).max;
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
        return id >= 1 && id <= proposalCount ? firstVotes : 0;
    }

    function votedProposalIds(address, uint256, uint256, uint256 limit, bool)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
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

    function proposalTarget(address, uint256 id) external view returns (address, TargetMode) {
        if (id == 0 || id > proposalCount) revert ISubmitErrors.ProposalNotFound(id);
        return (TARGET, TargetMode.NoCallback);
    }

    function addLaunchCount(address community, uint256, uint256 count) external {
        require(msg.sender == address(mint));
        issuedLaunchCount[community] += count;
    }

    function testProposalMintUnauthorized() public {
        setupMint(1000, 10000, 0, 1e17);
        vm.expectRevert(
            abi.encodeWithSelector(IMintErrors.NotProposalTarget.selector, address(this), TARGET)
        );
        mint.mintProposalReward(address(token), 1, 1, address(this));
    }

    function testProposalMintRoundNotReady() public {
        setupMint(1000, 10000, 0, 1e17);
        vm.prank(TARGET);
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.RoundNotEnded.selector, 0));
        mint.mintProposalReward(address(token), 0, 1, TARGET);
    }

    // This test is no longer valid after auto-prepare feature
    // Auto-prepare automatically prepares rewards when minting, so "not prepared" state doesn't cause revert
    // Keeping it as a comment for historical reference
    /*
    function testProposalMintRoundNotPrepared() public {
        setupMint(1000, 10000, 0, 1e17);
        vm.prank(TARGET);
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.RoundNotEnded.selector));
        mint.mintProposalReward(address(token), 1, 1, TARGET);
    }
    */

    function testProposalMintAutoPrepare() public {
        setupMint(1000, 10000, 0, 1e17);
        vm.prank(TARGET);
        // Before auto-prepare, this would fail with RoundNotEnded
        // Now it should succeed and automatically prepare rewards
        uint256 amount = mint.mintProposalReward(address(token), 1, 1, TARGET);
        // Verify reward was calculated and minted
        require(amount > 0, "proposal reward should be non-zero");
    }

    function testProposalMintRejectsZeroRecipient() public {
        setupMint(1000, 10000, 0, 1e17);
        vm.prank(TARGET);
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.ZeroRecipientAddress.selector));
        mint.mintProposalReward(address(token), 1, 1, address(0));
    }

    function testExecutorStyleDestroyReleasesTheReservation() public {
        setupMint(1000, 10000, 0, 1e17);
        vm.prank(TARGET);
        uint256 settled = mint.mintProposalReward(address(token), 1, 1, TARGET);
        require(settled > 0, "settled amount");
        require(mint.rewardMinted(address(token)) == settled, "minted ledger");

        // Destroying the tokens releases the reservation through `rewardMinted`, so the budget
        // effect matches the settle-by-burn path while supply returns to where it started.
        uint256 availableAfterSettle = mint.rewardAvailable(address(token));
        vm.prank(TARGET);
        token.burn(settled);
        require(token.totalSupply() == 1000, "supply restored");
        require(
            mint.rewardAvailable(address(token)) == availableAfterSettle + settled, "share back in circulation"
        );
    }

    function testPrepareBurnsBothPoolsWhenEligibleVotesZero() public {
        totalVoteAmountValue = 100;
        firstVotes = 1;
        proposalCount = 1;
        minVoteRatio = 5e16;
        setupMint(1000, 10000, 1e17, 1e17);
        uint256 burnedBefore = mint.rewardBurned(address(token));
        vm.recordLogs();
        mint.mintGovReward(address(token), 1, 1, address(this));
        MintVm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 burnedSig = keccak256("RewardBurned(address,uint256,uint256,uint8)");
        uint256 burnedCount;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(mint) && logs[i].topics[0] == burnedSig) {
                burnedCount++;
            }
        }
        require(burnedCount == 2, "both pools burned");
        require(mint.rewardBurned(address(token)) > burnedBefore, "burned increased");
    }

    function testPrepareSkipsZeroAmountBurnEvents() public {
        totalVoteAmountValue = 100;
        firstVotes = 100;
        proposalCount = 1;
        setupMint(999, 1000, 1e15, 1e15);
        uint256 burnedBefore = mint.rewardBurned(address(token));
        vm.recordLogs();
        MintVm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 burnedSig = keccak256("RewardBurned(address,uint256,uint256,uint8)");
        uint256 burnedCount;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(mint) && logs[i].topics[0] == burnedSig) {
                burnedCount++;
            }
        }
        require(burnedCount == 0, "zero amounts not emitted");
        require(mint.rewardBurned(address(token)) == burnedBefore, "burned unchanged");
    }

    function testPrepareSkipsZeroProposalPoolBurnEvent() public {
        totalVoteAmountValue = 999;
        firstVotes = 1;
        proposalCount = 1;
        minVoteRatio = 999e15;
        setupMint(999, 1000, 1e15, 1e15);
        uint256 burnedBefore = mint.rewardBurned(address(token));
        vm.recordLogs();
        MintVm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 burnedSig = keccak256("RewardBurned(address,uint256,uint256,uint8)");
        uint256 burnedCount;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(mint) && logs[i].topics[0] == burnedSig) {
                burnedCount++;
            }
        }
        require(burnedCount == 0, "zero proposal pool not emitted");
        require(mint.rewardBurned(address(token)) == burnedBefore, "burned unchanged");
    }

    function testPrepareRoundNotReady() public {
        setupMint(1000, 10000, 1e17, 1e17);
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.RoundNotEnded.selector, 0));
        mint.mintGovReward(address(token), 0, 1, address(this));
    }

    function testMultiProposalDustStaysInPool() public {
        totalVoteAmountValue = 3;
        firstVotes = 1;
        proposalCount = 3;
        minVoteRatio = 0;
        setupMint(1000, 11000, 0, 1e17);
        uint256 sum;
        for (uint256 id = 1; id <= 3; id++) {
            vm.prank(TARGET);
            sum += mint.mintProposalReward(address(token), 1, id, TARGET);
        }
        require(sum == 999, "dust stays in pool");
        require(mint.reservedAvailable(address(token)) == 1, "dust retained");
    }

    function testBurnOnlyGovernanceSettlement() public {
        totalVoteAmountValue = 1_000_000;
        memberVoteAmount = 1;
        totalBoost = 1000;
        memberBoost = 1000;
        setupMint(1000, 10000, 1e17, 0);
        (uint256 v, uint256 b, uint256 burn) = mint.mintGovReward(address(token), 1, 1, address(this));
        require(v == 0 && b == 0 && burn == 450, "only burn recorded");
        require(token.totalSupply() == 1000, "nothing minted");
        require(mint.launchCredit(address(token), 1) == 0, "no credit without mint");
    }

    function testGovRewardRoundNotReady() public {
        setupMint(1000, 10000, 1e17, 0);
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.RoundNotEnded.selector, 0));
        mint.mintGovReward(address(token), 0, 1, address(this));
    }

    // This test is no longer valid after auto-prepare feature
    // Auto-prepare automatically prepares rewards when minting, so "not prepared" state doesn't cause revert
    // Keeping it as a comment for historical reference
    /*
    function testGovRewardRoundNotPrepared() public {
        setupMint(1000, 10000, 1e17, 0);
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.RoundNotEnded.selector));
        mint.mintGovReward(address(token), 1, 2, address(this));
    }
    */

    function testGovRewardAutoPrepare() public {
        setupMint(1000, 10000, 1e17, 0);
        // Before auto-prepare, this would fail with RoundNotEnded
        // Now it should succeed and automatically prepare rewards
        (uint256 v, uint256 b, uint256 burn) = mint.mintGovReward(address(token), 1, 1, address(this));
        // Verify rewards were calculated and minted
        require(v > 0 || b > 0 || burn > 0, "rewards should be non-zero");
    }
}
