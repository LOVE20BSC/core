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

contract MintCoverageTest {
    MintVm constant vm = MintVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Mint mint;
    LOVE20Token token;
    uint256 totalVotes = 1;
    uint256 memberVotes = 1;
    uint256 firstVotes = 1;
    uint256 proposalCount = 1;
    uint256 minVoteRatio = 50;
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
        token = new LOVE20Token("Coverage", "COV", supply, maxSupply, address(this), address(mint), address(1));
    }

    function isRoundEnded(uint256 round) external pure returns (bool) {
        return round > 0;
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

    function stakedAmountOfVoters(address, uint256) external view returns (uint256) {
        return totalBoost;
    }

    function stakedAmountOfVotersByMemberId(address, uint256, uint256) external view returns (uint256) {
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

    function testInitRejectsZeroAddress() public {
        Mint a = new Mint();
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.InvalidAddress.selector));
        a.init(address(0), address(this), address(this), address(this), 50, 100, 100, 2);
    }

    function testInitRejectsBadRatioSum() public {
        Mint c = new Mint();
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.InvalidAmount.selector));
        c.init(address(this), address(this), address(this), address(this), 50, 600, 401, 2);
    }

    function testInitRejectsZeroMultiplier() public {
        Mint d = new Mint();
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.InvalidAmount.selector));
        d.init(address(this), address(this), address(this), address(this), 50, 100, 100, 0);
    }

    function testInitRejectsMultiplierAbove1000() public {
        Mint e = new Mint();
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.InvalidAmount.selector));
        e.init(address(this), address(this), address(this), address(this), 50, 100, 100, 1001);
    }

    function testProposalMintUnauthorized() public {
        setupMint(1000, 10000, 0, 100);
        mint.prepareRewardIfNeeded(address(token), 1);
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.UnauthorizedCaller.selector));
        mint.mintProposalReward(address(token), 1, 1);
    }

    function testProposalMintRoundNotReady() public {
        setupMint(1000, 10000, 0, 100);
        vm.prank(TARGET);
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.RoundNotReadyToMint.selector));
        mint.mintProposalReward(address(token), 0, 1);
    }

    function testProposalMintRoundNotPrepared() public {
        setupMint(1000, 10000, 0, 100);
        vm.prank(TARGET);
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.RoundNotReadyToMint.selector));
        mint.mintProposalReward(address(token), 1, 1);
    }

    function testPrepareBurnsBothPoolsWhenEligibleVotesZero() public {
        totalVotes = 100;
        firstVotes = 1;
        proposalCount = 1;
        minVoteRatio = 50;
        setupMint(1000, 10000, 100, 100);
        uint256 burnedBefore = mint.rewardBurned(address(token));
        vm.recordLogs();
        mint.prepareRewardIfNeeded(address(token), 1);
        MintVm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 burnedSig = keccak256("RewardBurned(address,uint256,uint256,bytes32)");
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
        totalVotes = 100;
        firstVotes = 100;
        proposalCount = 1;
        setupMint(999, 1000, 1, 1);
        uint256 burnedBefore = mint.rewardBurned(address(token));
        vm.recordLogs();
        mint.prepareRewardIfNeeded(address(token), 1);
        MintVm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 burnedSig = keccak256("RewardBurned(address,uint256,uint256,bytes32)");
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
        totalVotes = 999;
        firstVotes = 1;
        proposalCount = 1;
        minVoteRatio = 999;
        setupMint(999, 1000, 1, 1);
        uint256 burnedBefore = mint.rewardBurned(address(token));
        vm.recordLogs();
        mint.prepareRewardIfNeeded(address(token), 1);
        MintVm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 burnedSig = keccak256("RewardBurned(address,uint256,uint256,bytes32)");
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
        setupMint(1000, 10000, 100, 100);
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.RoundNotReadyToMint.selector));
        mint.prepareRewardIfNeeded(address(token), 0);
    }

    function testMultiProposalDustStaysInPool() public {
        totalVotes = 3;
        firstVotes = 1;
        proposalCount = 3;
        minVoteRatio = 0;
        setupMint(1000, 11000, 0, 100);
        mint.prepareRewardIfNeeded(address(token), 1);
        uint256 sum;
        for (uint256 id = 1; id <= 3; id++) {
            vm.prank(TARGET);
            sum += mint.mintProposalReward(address(token), 1, id);
        }
        require(sum == 999, "dust stays in pool");
        require(mint.reservedAvailable(address(token)) == 1, "dust retained");
    }

    function testBurnOnlyGovernanceSettlement() public {
        totalVotes = 1_000_000;
        memberVotes = 1;
        totalBoost = 1000;
        memberBoost = 1000;
        setupMint(1000, 10000, 100, 0);
        mint.prepareRewardIfNeeded(address(token), 1);
        (uint256 v, uint256 b, uint256 burn) = mint.mintGovReward(address(token), 1, 1);
        require(v == 0 && b == 0 && burn == 450, "only burn recorded");
        require(token.totalSupply() == 1000, "nothing minted");
        require(mint.launchCredit(address(token), 1) == 0, "no credit without mint");
    }

    function testGovRewardRoundNotReady() public {
        setupMint(1000, 10000, 100, 0);
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.RoundNotReadyToMint.selector));
        mint.mintGovReward(address(token), 1, 0);
    }

    function testGovRewardRoundNotPrepared() public {
        setupMint(1000, 10000, 100, 0);
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.RoundNotReadyToMint.selector));
        mint.mintGovReward(address(token), 1, 2);
    }
}
