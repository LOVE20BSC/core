// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Mint} from "../src/Mint.sol";
import {LOVE20Token} from "../src/LOVE20Token.sol";
import {IMintErrors} from "../src/interfaces/IMint.sol";
import {ISubmitErrors, TargetMode} from "../src/interfaces/ISubmit.sol";
import {IERC721Errors} from "../lib/openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";

interface MintVm {
    function assume(bool) external;
    function prank(address) external;
    function expectRevert(bytes calldata) external;
}

contract MintFuzzTest {
    MintVm constant vm = MintVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    Mint mint;
    LOVE20Token token;

    address constant TARGET = address(0x1234);

    uint256 public mockTotalVotes;
    uint256 public mockMemberVotes;
    uint256 public mockProposalVotes;
    uint256 public mockTotalBoost;
    uint256 public mockMemberBoost;
    uint256 public proposalCount = 1;

    uint256 public constant LAUNCH_RATIO = 1e16;
    uint256 public constant MAX_LAUNCH_COUNT = 1000;
    mapping(address => uint256) public issuedLaunchCount;

    function setupFuzz(uint256 supply, uint256 maxSup, uint256 govRatio, uint256 propRatio) internal {
        mint = new Mint();
        mint.init(
            address(this),
            address(this),
            address(this),
            address(this),
            50,
            govRatio,
            propRatio,
            2
        );
        token = new LOVE20Token("Fuzz", "FUZ", supply, maxSup, address(this), address(mint), address(1));
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
        return mockTotalVotes;
    }

    function votesNumByMemberId(address, uint256, uint256 id) external view returns (uint256) {
        return id == 1 ? mockMemberVotes : 0;
    }

    function votesNumByProposalId(address, uint256, uint256 id) external view returns (uint256) {
        return id == 1 ? mockProposalVotes : 0;
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
        return mockTotalBoost;
    }

    function stakedAmountOfVotersByMemberId(address, uint256, uint256) external view returns (uint256) {
        return mockMemberBoost;
    }

    function proposalTarget(address, uint256 id) external pure returns (address, TargetMode) {
        if (id == 0 || id > 1) revert ISubmitErrors.ProposalNotFound(id);
        return (TARGET, TargetMode.NoCallback);
    }

    function addLaunchCount(address community, uint256, uint256 count) external {
        require(msg.sender == address(mint));
        issuedLaunchCount[community] += count;
    }

    // ============ Fuzz Tests: Random Supply & Ratios ============

    /// @notice Fuzz test: prepare reward with random supply constraints
    function testFuzz_PrepareWithRandomSupply(
        uint256 currentSupply,
        uint256 maxSupply,
        uint256 govRatio,
        uint256 proposalRatio
    ) public {
        // Bound parameters to valid ranges
        maxSupply = bound(maxSupply, 1000, type(uint96).max); // Avoid overflow in token
        currentSupply = bound(currentSupply, 100, maxSupply - 100);
        vm.assume(maxSupply > currentSupply);
        vm.assume(maxSupply - currentSupply >= 100);
        govRatio = bound(govRatio, 0, 1000);
        proposalRatio = bound(proposalRatio, 0, 1000 - govRatio);

        mockTotalVotes = 100;
        mockProposalVotes = 10;

        setupFuzz(currentSupply, maxSupply, govRatio, proposalRatio);

        // Trigger auto-prepare by minting
        if (govRatio > 0) {
            try mint.mintGovReward(address(token), 1, 1) {} catch {
                // Zero reward is valid for small ratios, skip test
                return;
            }
        } else if (proposalRatio > 0) {
            vm.prank(TARGET);
            try mint.mintProposalReward(address(token), 1, 1) {} catch {
                // Zero reward is valid for small ratios, skip test
                return;
            }
        } else {
            // No rewards, skip test
            return;
        }

        uint256 available = maxSupply - currentSupply;
        uint256 expectedGov = (available * govRatio) / 1000;
        uint256 expectedProposal = (available * proposalRatio) / 1000;

        assertEq(mint.govReward(address(token), 1), expectedGov);
        assertEq(mint.proposalReward(address(token), 1), expectedProposal);
        assertEq(
            mint.rewardReserved(address(token)),
            expectedGov + expectedProposal
        );
    }

    /// @notice Fuzz test: governance reward calculation with random votes
    function testFuzz_GovRewardWithRandomVotes(
        uint256 totalVotes_,
        uint256 memberVotes_,
        uint256 totalBoost_,
        uint256 memberBoost_
    ) public {
        totalVotes_ = bound(totalVotes_, 1, 1e9);
        memberVotes_ = bound(memberVotes_, 1, totalVotes_);
        totalBoost_ = bound(totalBoost_, 0, 1e18);
        memberBoost_ = bound(memberBoost_, 0, totalBoost_);

        mockTotalVotes = totalVotes_;
        mockMemberVotes = memberVotes_;
        mockTotalBoost = totalBoost_;
        mockMemberBoost = memberBoost_;
        mockProposalVotes = 10;
        proposalCount = 1;

        setupFuzz(1000, 100000, 500, 0);

        uint256 govTotal = mint.govReward(address(token), 1);

        // Skip if no reward available
        if (govTotal == 0) return;

        // Query reward before minting to verify calculation
        (uint256 expectedVote, uint256 expectedBoost, uint256 expectedBurn,) =
            mint.govRewardByMemberId(address(token), 1, 1);

        // Skip if vote reward is zero (would cause NoRewardAvailable)
        if (expectedVote == 0 && expectedBoost == 0) return;

        mint.mintGovReward(address(token), 1, 1);

        uint256 votePool = govTotal / 2;
        uint256 calculatedVote = (votePool * memberVotes_) / totalVotes_;

        assertEq(expectedVote, calculatedVote);
        assertEq(mint.rewardMinted(address(token)), expectedVote + expectedBoost);

        // Boost must not exceed multiplier cap
        if (totalBoost_ > 0) {
            uint256 theoreticalBoost = ((govTotal - votePool) * memberBoost_) / totalBoost_;
            uint256 cappedBoost = expectedVote * 2; // multiplier is 2
            if (theoreticalBoost <= cappedBoost) {
                assertEq(expectedBoost, theoreticalBoost);
                assertEq(expectedBurn, 0);
            } else {
                assertEq(expectedBoost, cappedBoost);
                assertEq(expectedBurn, theoreticalBoost - cappedBoost);
            }
        }
    }

    /// @notice Fuzz test: proposal reward distribution
    function testFuzz_ProposalRewardDistribution(
        uint256 totalVotes_,
        uint256 proposalVotes_,
        uint256 supply
    ) public {
        totalVotes_ = bound(totalVotes_, 20, 1e9);
        proposalVotes_ = bound(proposalVotes_, 1, totalVotes_);
        supply = bound(supply, 100, 1e6);

        mockTotalVotes = totalVotes_;
        mockProposalVotes = proposalVotes_;

        setupFuzz(supply, supply * 10, 0, 500);

        // Trigger auto-prepare by minting
        vm.prank(TARGET);
        try mint.mintProposalReward(address(token), 1, 1) {} catch {}

        uint256 minVotes = (totalVotes_ * 50 + 999) / 1000; // Ceiling of 5%
        bool shouldQualify = proposalVotes_ >= minVotes;

        assertEq(mint.isProposalIdWithReward(address(token), 1, 1), shouldQualify);

        if (shouldQualify) {
            (uint256 amount,) = mint.proposalRewardByProposalId(address(token), 1, 1);
            uint256 proposalPool = mint.proposalReward(address(token), 1);
            uint256 eligibleVotes = mint.eligibleProposalVotes(address(token), 1);

            // Skip if no eligible votes (division by zero)
            if (eligibleVotes == 0) return;

            uint256 expectedAmount = (proposalPool * proposalVotes_) / eligibleVotes;
            assertEq(amount, expectedAmount);
        }
    }

    /// @notice Fuzz test: batch governance minting atomicity
    function testFuzz_BatchAtomicity(uint8 roundCount) public {
        vm.assume(roundCount > 0 && roundCount <= 20);

        mockTotalVotes = 100;
        mockMemberVotes = 50;

        setupFuzz(1000, 100000, 100, 0);

        uint256[] memory rounds = new uint256[](roundCount);
        for (uint256 i; i < roundCount; i++) {
            rounds[i] = i + 1;
        }

        uint256 supplyBefore = token.totalSupply();
        (uint256[] memory votes,,) = mint.mintGovRewards(address(token), 1, rounds);

        assertEq(votes.length, roundCount);

        uint256 totalMinted;
        for (uint256 i; i < votes.length; i++) {
            totalMinted += votes[i];
        }

        assertEq(token.totalSupply(), supplyBefore + totalMinted);
    }

    /// @notice Fuzz test: supply exhaustion edge cases
    function testFuzz_SupplyExhaustion(uint256 nearMax) public {
        vm.assume(nearMax >= 1 && nearMax <= 1000);

        uint256 maxSup = 10000;
        uint256 supply = maxSup - nearMax;

        mockTotalVotes = 100;
        mockMemberVotes = 50;
        mockProposalVotes = 10;
        mockTotalBoost = 1000;
        mockMemberBoost = 100;
        proposalCount = 1;

        setupFuzz(supply, maxSup, 500, 500);

        uint256 govPool = mint.govReward(address(token), 1);
        uint256 propPool = mint.proposalReward(address(token), 1);

        assertLe(govPool + propPool, nearMax);

        uint256 reserved = mint.rewardReserved(address(token));
        uint256 available = mint.rewardAvailable(address(token));

        assertEq(reserved, govPool + propPool);
        assertEq(available + reserved, maxSup - supply);
    }

    // ============ Helper Functions ============

    function bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (max == min) return min;
        return min + (x % (max - min + 1));
    }

    function assertEq(uint256 a, uint256 b) internal pure {
        require(a == b, "assertEq failed");
    }

    function assertEq(bool a, bool b) internal pure {
        require(a == b, "assertEq bool failed");
    }

    function assertLe(uint256 a, uint256 b) internal pure {
        require(a <= b, "assertLe failed");
    }
}
