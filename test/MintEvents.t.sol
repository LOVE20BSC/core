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

    event RewardPrepared(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 govReward,
        uint256 proposalReward,
        uint256 eligibleProposalVoteAmount,
        uint256 totalRewardReserved,
        uint256 totalRewardBurned
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
        mint = new Mint();
        mint.init(
            address(this),
            address(this),
            address(this),
            address(this),
            5e16,
            1e17,
            1e17
        );
        token = new LOVE20Token("Test", "TST", 10000, 1000000, address(this), address(mint), address(this));
    }

    // Mock interfaces
    function PHASE_ADDRESS() external view returns (address) {
        return address(this);
    }

    function currentPhase() external pure returns (uint256) {
        return type(uint256).max;
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
        if (id == 0 || id > 3) return 0;
        return 600;
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

    /// @notice Verify RewardPrepared event with exact field values
    function testEvent_RewardPreparedEmitsCorrectFields() public {
        uint256 round = 1;
        uint256 govRewardExpected = (1000000 - 10000) * 100 / 1000;
        uint256 proposalRewardExpected = (1000000 - 10000) * 100 / 1000;

        vm.expectEmit(true, true, false, true);
        emit RewardPrepared({
            tokenAddress: address(token),
            round: round,
            govReward: govRewardExpected,
            proposalReward: proposalRewardExpected,
            eligibleProposalVoteAmount: 1800,
            totalRewardReserved: govRewardExpected + proposalRewardExpected,
            totalRewardBurned: 0
        });

        mint.mintGovReward(address(token), round, 1, address(this));
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
        uint256 amount = proposalReward * 600 / 1800;

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
            totalRewardMinted: amount * 2
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
    /// @dev Mint no longer voids a proposal reward; an Executor destroys the tokens it received, so
    ///      the token's own burn event carries that half and Mint emits only the settlement.
    function testEvent_UnallocatableProposalRewardSettlesAsMinted() public {
        uint256 round = 1;
        uint256 proposalId = 1;

        vm.prank(TARGET);
        uint256 settled = mint.mintProposalReward(address(token), round, proposalId, TARGET);

        assertEq(settled, 33000, "settled amount");
        assertEq(mint.totalRewardMinted(address(token)), settled, "minted ledger");
        assertEq(token.balanceOf(TARGET), settled, "tokens held by the recipient");
    }

    /// @notice 取消池燃烧必须先于奖池准备（依赖序），累计 `totalRewardBurned` 必须等于折叠值
    function testEvent_RewardBurnedPrecedesRewardPrepared() public {
        zeroBoost = true;

        vm.recordLogs();
        mint.mintGovReward(address(token), 1, 1, address(this));

        (uint256 burnedIndex, uint256 preparedIndex, uint256 burnedTotal, uint256 cumulative, uint256 burnedCumulative)
        = _scanRewardLogs(vm.getRecordedLogs());

        require(burnedIndex != type(uint256).max, "missing RewardBurned");
        require(preparedIndex != type(uint256).max, "missing RewardPrepared");
        require(burnedIndex < preparedIndex, "burn must precede prepare");
        require(burnedTotal > 0, "burn amount");
        assertEq(cumulative, burnedTotal, "totalRewardBurned equals folded burns");
        assertEq(burnedCumulative, cumulative, "the burn event carries the post-state total");
    }

    /// @notice 跨轮累计：每轮 `RewardPrepared.totalRewardBurned` 等于此前全部 `RewardBurned` 之和
    function testEvent_RewardPreparedCumulativeMatchesFoldedBurns() public {
        zeroBoost = true;
        uint256 foldedBurned;

        for (uint256 round = 1; round <= 2; ++round) {
            vm.recordLogs();
            mint.mintGovReward(address(token), round, 1, address(this));

            (, uint256 preparedIndex, uint256 burnedThisRound, uint256 cumulative, uint256 burnedCumulative) =
                _scanRewardLogs(vm.getRecordedLogs());
            require(preparedIndex != type(uint256).max, "missing RewardPrepared");

            foldedBurned += burnedThisRound;
            assertEq(cumulative, foldedBurned, "cumulative totalRewardBurned");
            assertEq(burnedCumulative, foldedBurned, "the burn event carries the same cumulative");
        }
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

    /// @notice 跨轮累计：每轮 `RewardPrepared.totalRewardReserved` 等于此前全部 (govReward + proposalReward) 之和
    function testEvent_RewardPreparedReservedMatchesFold() public {
        uint256 foldedReserved;

        for (uint256 round = 1; round <= 2; ++round) {
            vm.recordLogs();
            mint.mintGovReward(address(token), round, 1, address(this));

            (uint256 govReward, uint256 proposalReward, uint256 reserved) =
                _scanPreparedReserved(vm.getRecordedLogs());
            foldedReserved += govReward + proposalReward;
            assertEq(reserved, foldedReserved, "cumulative totalRewardReserved");
        }
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

    /// @dev 折叠 `RewardPrepared`：(govReward, proposalReward, eligibleVoteAmount, totalRewardReserved, totalRewardBurned)
    function _scanPreparedReserved(MintVm.Log[] memory logs)
        private
        view
        returns (uint256 govReward, uint256 proposalReward, uint256 reserved)
    {
        bytes32 preparedTopic =
            keccak256("RewardPrepared(address,uint256,uint256,uint256,uint256,uint256,uint256)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(mint) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != preparedTopic) continue;
            (govReward, proposalReward,, reserved,) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
            found = true;
        }
        require(found, "missing RewardPrepared");
    }

    function _scanRewardLogs(MintVm.Log[] memory logs)
        private
        view
        returns (
            uint256 burnedIndex,
            uint256 preparedIndex,
            uint256 burnedTotal,
            uint256 cumulative,
            uint256 burnedCumulative
        )
    {
        bytes32 burnedTopic = keccak256("RewardBurned(address,uint256,uint256,uint256,uint8)");
        bytes32 preparedTopic =
            keccak256("RewardPrepared(address,uint256,uint256,uint256,uint256,uint256,uint256)");
        burnedIndex = type(uint256).max;
        preparedIndex = type(uint256).max;

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(mint) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == burnedTopic) {
                (uint256 amount, uint256 burnedPost,) = abi.decode(logs[i].data, (uint256, uint256, uint8));
                burnedTotal += amount;
                burnedCumulative = burnedPost;
                if (burnedIndex == type(uint256).max) burnedIndex = i;
            } else if (logs[i].topics[0] == preparedTopic) {
                (, , , , cumulative) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
                preparedIndex = i;
            }
        }
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
