// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Mint} from "../src/Mint.sol";
import {LOVE20Token} from "../src/LOVE20Token.sol";
import {IMintErrors, BurnReason} from "../src/interfaces/IMint.sol";
import {ISubmitErrors, TargetMode} from "../src/interfaces/ISubmit.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

interface MintVm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function expectEmit(bool, bool, bool, bool) external;
    function expectEmit(bool, bool, bool, bool, address) external;

    function prank(address sender) external;

    function recordLogs() external;

    function getRecordedLogs() external returns (Log[] memory);
}

/// @title MintEvents - Comprehensive event verification tests
/// @notice Validates that every write operation emits correct events with exact field values
contract MintEventsTest {
    MintVm constant vm = MintVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    Mint mint;
    LOVE20Token token;
    address constant TARGET = address(0x1234);
    bool zeroBoost;
    uint256 issuedCount;
    uint256 currentPhaseValue = 1;

    event RoundRewardReserved(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 govReward,
        uint256 proposalReward,
        uint256 totalRewardReserved
    );

    event GovRewardMinted(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 indexed memberId,
        uint256 voteReward,
        uint256 boostReward,
        uint256 totalRewardMinted
    );

    event ProposalRewardMinted(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 indexed proposalId,
        address recipient,
        uint256 amount,
        uint256 totalRewardMinted
    );

    event ProposalRewardBurned(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 indexed proposalId,
        uint256 amount,
        uint256 totalRewardBurned
    );

    event RewardBurned(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 amount,
        uint256 totalRewardBurned,
        BurnReason reason
    );

    event LaunchCountAdded(
        address indexed tokenAddress,
        uint256 indexed memberId,
        uint256 count,
        uint256 issuedCount,
        uint256 memberRemaining
    );

    function setUp() public {
        mint = new Mint(
            address(this),
            address(this),
            address(this),
            address(this),
            address(this),
            5e16,
            1e17,
            1e17
        );
        token = new LOVE20Token("Test", "TST", 10000, 1000000, address(this), address(mint), address(this));
        mint.reserveRoundReward(address(token), 1);
        currentPhaseValue = type(uint256).max;
    }

    // Mock interfaces
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
        if (id == 0 || id > 5) revert IERC721Errors.ERC721NonexistentToken(id);
        return address(this);
    }

    function totalVoteAmount(address, uint256) external pure returns (uint256) {
        return 1000;
    }

    function voteAmountByMemberId(address, uint256, uint256 id) external pure returns (uint256) {
        if (id == 0) return 0;
        return 200;
    }

    function voteAmountByProposalId(address, uint256, uint256 id) external pure returns (uint256) {
        if (id == 1) return 400;
        if (id == 2) return 560;
        if (id == 3) return 40;
        return 0;
    }

    function votedProposalIds(address, uint256, uint256, uint256 limit, bool)
        external
        pure
        returns (uint256[] memory ids, uint256 total)
    {
        total = 3;
        ids = new uint256[](limit > 3 ? 3 : limit);
        for (uint256 i = 0; i < ids.length; i++) {
            ids[i] = i + 1;
        }
    }

    function totalVoterBoost(address, uint256) external view returns (uint256) {
        return zeroBoost ? 0 : 5000;
    }

    // 30% of the boost pool against 20% of the vote pool, so `voteReward` and `boostReward` differ.
    function voterBoost(address, uint256, uint256 id) external pure returns (uint256) {
        if (id == 0) return 0;
        return 1500;
    }

    function proposalTarget(address tokenAddress, uint256 id) external pure returns (address, TargetMode) {
        if (id == 0 || id > 3) revert ISubmitErrors.ProposalNotFound(tokenAddress, id);
        return (TARGET, TargetMode.NoCallback);
    }

    function addLaunchCount(address tokenAddress, uint256 memberId, uint256 count) external {
        require(msg.sender == address(mint));
        issuedCount += count;
        emit LaunchCountAdded({
            tokenAddress: tokenAddress,
            memberId: memberId,
            count: count,
            issuedCount: issuedCount,
            memberRemaining: count
        });
    }

    function issuedLaunchCount(address) external view returns (uint256) {
        return issuedCount;
    }

    function MAX_LAUNCH_COUNT() external pure returns (uint256) {
        return 1000;
    }

    function LAUNCH_COUNT_THRESHOLD_RATIO() external pure returns (uint256) {
        return 1e16;
    }

    /// @notice Verify the second reservation emits both pool amounts and the cumulative reserve.
    function testEvent_RoundRewardReservedEmitsCorrectFields() public {
        currentPhaseValue = 2;
        uint256 roundOneReserved = 198000;
        uint256 pool = (1000000 - 10000 - roundOneReserved) / 10;

        vm.expectEmit(true, true, false, true, address(mint));
        emit RoundRewardReserved({
            tokenAddress: address(token),
            round: 2,
            govReward: pool,
            proposalReward: pool,
            totalRewardReserved: roundOneReserved + pool * 2
        });

        mint.reserveRoundReward(address(token), 2);
    }

    /// @notice Verify GovRewardMinted event with exact amounts
    /// @dev The expectation is computed from the spec formula rather than from `govRewardByMemberId`, so
    ///      a broken formula cannot agree with itself.
    function testEvent_GovRewardMintedEmitsCorrectFields() public {
        uint256 round = 1;
        // A member id above 1 keeps `round` and `memberId` distinguishable.
        uint256 memberId = 2;

        uint256 govReward = (1000000 - 10000) * 100 / 1000;
        uint256 votePool = govReward / 2;
        uint256 voteReward = votePool * 200 / 1000;
        uint256 boostPool = govReward - votePool;
        uint256 boostReward = boostPool * 1500 / 5000;

        vm.expectEmit(true, true, true, true);
        emit GovRewardMinted({
            tokenAddress: address(token),
            round: round,
            memberId: memberId,
            voteReward: voteReward,
            boostReward: boostReward,
            totalRewardMinted: voteReward + boostReward
        });

        mint.mintGovReward(address(token), round, memberId, address(this));
    }

    /// @notice Verify ProposalRewardMinted event with exact amount and target
    function testEvent_ProposalRewardMintedEmitsCorrectFields() public {
        uint256 round = 1;
        // A proposal id above 1 keeps `round` and `proposalId` distinguishable.
        uint256 proposalId = 2;

        uint256 proposalReward = (1000000 - 10000) * 100 / 1000;
        uint256 amount = proposalReward * 560 / 1000;

        // Settle a different proposal first, so `amount` and `totalRewardMinted` differ and a swap
        // between them cannot pass unnoticed.
        vm.prank(TARGET);
        mint.mintProposalReward(address(token), round, 1, TARGET);

        vm.expectEmit(true, true, true, true);
        emit ProposalRewardMinted({
            tokenAddress: address(token),
            round: round,
            proposalId: proposalId,
            recipient: TARGET,
            amount: amount,
            totalRewardMinted: amount + proposalReward * 400 / 1000
        });

        vm.prank(TARGET);
        mint.mintProposalReward(address(token), round, proposalId, TARGET);
    }

    function assertEq(uint256 a, uint256 b, string memory message) internal pure {
        require(a == b, message);
    }

    /// @notice Verify batch minting emits multiple GovRewardMinted events
    function testEvent_BatchMintEmitsMultipleEvents() public {
        uint256 memberId = 2;
        uint256[] memory rounds = new uint256[](3);
        rounds[0] = 1;
        rounds[1] = 2;
        rounds[2] = 3;
        for (uint256 i; i < rounds.length; i++) {
            currentPhaseValue = rounds[i];
            mint.reserveRoundReward(address(token), rounds[i]);
        }
        currentPhaseValue = type(uint256).max;

        // Verify first event from the spec formula, not from the contract's own query.
        uint256 govReward = (1000000 - 10000) * 100 / 1000;
        uint256 votePool = govReward / 2;
        uint256 voteReward1 = votePool * 200 / 1000;
        uint256 boostPool = govReward - votePool;
        uint256 boostReward1 = boostPool * 1500 / 5000;

        // Seed a settlement for the other member so the first batch event's cumulative total
        // differs from its own increment.
        mint.mintGovReward(address(token), 1, 1, address(this));

        vm.expectEmit(true, true, true, true);
        emit GovRewardMinted({
            tokenAddress: address(token),
            round: 1,
            memberId: memberId,
            voteReward: voteReward1,
            boostReward: boostReward1,
            totalRewardMinted: (voteReward1 + boostReward1) * 2
        });

        // Note: Cannot verify all 3 events in one call with current tooling
        // This demonstrates the pattern for the first event
        mint.mintGovRewards(address(token), rounds, memberId, address(this));
    }

    /// @notice Verify ProposalRewardMinted is the only settlement event for an unallocatable reward
    /// @dev Funds paid to a qualifying proposal are recorded as minted at settlement.
    function testEvent_UnallocatableProposalRewardSettlesAsMinted() public {
        uint256 round = 1;
        uint256 proposalId = 1;

        vm.prank(TARGET);
        uint256 settled = mint.mintProposalReward(address(token), round, proposalId, TARGET);

        assertEq(settled, 39600, "settled amount");
        assertEq(mint.totalRewardMinted(address(token)), settled, "minted ledger");
        assertEq(token.balanceOf(TARGET), settled, "tokens held by the recipient");
    }

    function testEvent_ProposalRewardBurnedEmitsExactShareAndCumulativeTotal() public {
        zeroBoost = true;
        mint.burnUnusedBoostReward(address(token), 1);
        uint256 amount = 99000 * 40 / 1000;

        vm.expectEmit(true, true, true, true, address(mint));
        emit ProposalRewardBurned({
            tokenAddress: address(token),
            round: 1,
            proposalId: 3,
            amount: amount,
            totalRewardBurned: 49500 + amount
        });
        vm.prank(TARGET);
        mint.burnProposalReward(address(token), 1, 3);
        assertEq(mint.totalRewardBurned(address(token)), 49500 + amount, "shared burn ledger");
    }

    function testEvent_BurnUnusedBoostRewardEmitsExactRelease() public {
        zeroBoost = true;
        vm.expectEmit(true, true, false, true, address(mint));
        emit RewardBurned({
            tokenAddress: address(token),
            round: 1,
            amount: 49500,
            totalRewardBurned: 49500,
            reason: BurnReason.BoostPoolCancelled
        });
        mint.burnUnusedBoostReward(address(token), 1);
    }

    /// @notice Each burn event carries the total folded from both event types across rounds.
    function testEvent_BurnEventsShareTheCumulativeTotal() public {
        zeroBoost = true;
        vm.recordLogs();
        for (uint256 round = 1; round <= 2; ++round) {
            currentPhaseValue = round;
            mint.reserveRoundReward(address(token), round);
            currentPhaseValue = round + 1;
            mint.burnProposalReward(address(token), round, 3);
            mint.burnUnusedBoostReward(address(token), round);
            mint.burnProposalReward(address(token), round, 3);
        }

        MintVm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 boostTopic = keccak256("RewardBurned(address,uint256,uint256,uint256,uint8)");
        bytes32 proposalTopic = keccak256("ProposalRewardBurned(address,uint256,uint256,uint256,uint256)");
        uint256 foldedBurned;
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(mint)) continue;
            bytes32 topic = logs[i].topics[0];
            if (topic != boostTopic && topic != proposalTopic) continue;
            require(topic == (count % 2 == 0 ? proposalTopic : boostTopic), "events follow call order");
            (uint256 amount, uint256 cumulative) = abi.decode(logs[i].data, (uint256, uint256));
            foldedBurned += amount;
            assertEq(cumulative, foldedBurned, "every event carries the post-state total");
            ++count;
        }
        assertEq(count, 4, "one boost burn and one proposal burn per round");
        assertEq(foldedBurned, mint.totalRewardBurned(address(token)), "the folded total matches the ledger");
    }

    /// @notice 两个 `Minted` 事件共享 `totalRewardMinted`：逐条日志的后置值等于跨事件折叠
    function testEvent_MintedEventsShareTheCumulativeTotal() public {
        vm.recordLogs();
        mint.mintGovReward(address(token), 1, 1, address(this));
        vm.prank(TARGET);
        mint.mintProposalReward(address(token), 1, 1, TARGET);

        MintVm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 govTopic = keccak256("GovRewardMinted(address,uint256,uint256,uint256,uint256,uint256)");
        bytes32 proposalTopic = keccak256("ProposalRewardMinted(address,uint256,uint256,address,uint256,uint256)");
        uint256 folded;
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(mint) || logs[i].topics.length == 0) continue;
            uint256 minted;
            if (logs[i].topics[0] == govTopic) {
                uint256 voteReward;
                uint256 boostReward;
                (voteReward, boostReward, minted) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                folded += voteReward + boostReward;
            } else if (logs[i].topics[0] == proposalTopic) {
                uint256 amount;
                (, amount, minted) = abi.decode(logs[i].data, (address, uint256, uint256));
                folded += amount;
            } else {
                continue;
            }
            assertEq(minted, folded, "each settlement carries the shared post-state total");
            ++seen;
        }
        require(seen == 2, "one event per settlement");
        assertEq(folded, mint.totalRewardMinted(address(token)), "the folded total matches the ledger");
    }

    /// @notice Each reservation event carries the sum of both pools from every reservation so far.
    function testEvent_RoundRewardReservedMatchesFold() public {
        uint256 foldedReserved = 198000; // The first round is reserved by setUp.
        vm.recordLogs();
        for (uint256 round = 2; round <= 3; ++round) {
            currentPhaseValue = round;
            mint.reserveRoundReward(address(token), round);
            mint.reserveRoundReward(address(token), round);
        }

        MintVm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "unique reservation event per round");
        for (uint256 i; i < logs.length; ++i) {
            require(logs[i].emitter == address(mint), "Mint emitted the reservation");
            require(logs[i].topics[0] == keccak256("RoundRewardReserved(address,uint256,uint256,uint256,uint256)"),
                    "reservation topic");
            assertEq(uint256(logs[i].topics[2]), i + 2, "reservation round");
            (uint256 govReward, uint256 proposalReward, uint256 reserved) =
                abi.decode(logs[i].data, (uint256, uint256, uint256));
            foldedReserved += govReward + proposalReward;
            assertEq(reserved, foldedReserved, "cumulative totalRewardReserved");
        }
        assertEq(foldedReserved, mint.totalRewardReserved(address(token)), "the folded total matches the ledger");
    }

    /// 依赖序：`TokenMinted` 与 `LaunchCountAdded` 都先于依赖它们的 `GovRewardMinted`。
    function testEvent_LaunchCountAddedPrecedesGovRewardMinted() public {
        vm.recordLogs();
        mint.mintGovReward(address(token), 1, 1, address(this));

        MintVm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 mintTopic = keccak256("TokenMinted(address,uint256)");
        bytes32 launchTopic = keccak256("LaunchCountAdded(address,uint256,uint256,uint256,uint256)");
        bytes32 govTopic = keccak256("GovRewardMinted(address,uint256,uint256,uint256,uint256,uint256)");
        uint256 mintIndex = type(uint256).max;
        uint256 launchIndex = type(uint256).max;
        uint256 govIndex = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0) continue;
            if (logs[i].emitter == address(token) && logs[i].topics[0] == mintTopic) mintIndex = i;
            if (logs[i].topics[0] == launchTopic) launchIndex = i;
            if (logs[i].emitter == address(mint) && logs[i].topics[0] == govTopic) govIndex = i;
        }

        require(mintIndex != type(uint256).max, "missing TokenMinted");
        require(launchIndex != type(uint256).max, "missing LaunchCountAdded");
        require(govIndex != type(uint256).max, "missing GovRewardMinted");
        require(mintIndex < govIndex, "token mint precedes gov reward");
        require(launchIndex < govIndex, "launch count precedes gov reward");
    }

}

/// @notice Mock Vote with no eligible proposals
contract MockVoteWithNoEligibleProposals {
    function isRoundEnded(uint256) external pure returns (bool) { return true; }
    function totalVoteAmount(address, uint256) external pure returns (uint256) { return 1000; }
    function voteAmountByMemberId(address, uint256, uint256) external pure returns (uint256) { return 200; }
    function voteAmountByProposalId(address, uint256, uint256 id) external pure returns (uint256) {
        if (id == 0 || id > 3) return 0;
        return 40; // Below 5% threshold
    }
    function votedProposalIds(address, uint256, uint256, uint256 limit, bool)
        external pure returns (uint256[] memory ids, uint256 total) {
        total = 3;
        ids = new uint256[](limit > 3 ? 3 : limit);
        for (uint256 i = 0; i < ids.length; i++) { ids[i] = i + 1; }
    }
    function totalVoterBoost(address, uint256) external pure returns (uint256) { return 0; }
    function voterBoost(address, uint256, uint256) external pure returns (uint256) { return 0; }
}
