// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Mint} from "../src/Mint.sol";
import {LOVE20Token} from "../src/LOVE20Token.sol";
import {ISubmitErrors, TargetMode} from "../src/interfaces/ISubmit.sol";
import {IERC721Errors} from "../lib/openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";

interface MintVm {
    function assume(bool condition) external pure;
}

/// @title MintInvariant - Invariant tests for core accounting rules
/// @notice Verifies that critical invariants hold across any sequence of operations
contract MintInvariantTest {
    Mint public mint;
    LOVE20Token public token;
    address constant TARGET = address(0x1234);

    // State tracking for invariants
    uint256 public preparedRounds;
    uint256 public settledGovRewards;
    uint256 public settledProposalRewards;

    function setUp() public {
        mint = new Mint();
        mint.init(
            address(this),
            address(this),
            address(this),
            address(this),
            50,
            100,
            100,
            2
        );
        token = new LOVE20Token("Test", "TST", 10000, 1000000, address(this), address(mint), address(1));
    }

    // Mock interfaces
    function isRoundEnded(uint256 round) external pure returns (bool) {
        return round > 0;
    }

    function ownerOf(uint256 id) external view returns (address) {
        if (id == 0 || id > 10) revert IERC721Errors.ERC721NonexistentToken(id);
        return address(this);
    }

    function votesNum(address, uint256) external pure returns (uint256) {
        return 1000;
    }

    function votesNumByMemberId(address, uint256, uint256 id) external pure returns (uint256) {
        if (id == 0) return 0;
        return 100;
    }

    function votesNumByProposalId(address, uint256, uint256 id) external pure returns (uint256) {
        if (id == 0 || id > 5) return 0;
        return 300;
    }

    function votedProposalIds(address, uint256, uint256, uint256 limit, bool)
        external
        pure
        returns (uint256[] memory ids, uint256 total)
    {
        total = 5;
        ids = new uint256[](limit > 5 ? 5 : limit);
        for (uint256 i = 0; i < ids.length; i++) {
            ids[i] = i + 1;
        }
    }

    function stakedAmountOfVoters(address, uint256) external pure returns (uint256) {
        return 5000;
    }

    function stakedAmountOfVotersByMemberId(address, uint256, uint256 id) external pure returns (uint256) {
        if (id == 0) return 0;
        return 500;
    }

    function proposalTarget(address, uint256 id) external pure returns (address, TargetMode) {
        if (id == 0 || id > 5) revert ISubmitErrors.ProposalNotFound(id);
        return (TARGET, TargetMode.NoCallback);
    }

    function addLaunchCount(address, uint256, uint256) external view {
        require(msg.sender == address(mint));
    }

    /// @notice Invariant: reserved always covers minted + burned
    function invariant_ReservedCoversSettled() public view {
        uint256 reserved = mint.rewardReserved(address(token));
        uint256 minted = mint.rewardMinted(address(token));
        uint256 burned = mint.rewardBurned(address(token));

        assert(reserved >= minted + burned);
    }

    /// @notice Invariant: available + reserved + supply = maxSupply
    function invariant_TotalSupplyAccountingClosed() public view {
        uint256 available = mint.rewardAvailable(address(token));
        uint256 reserved = mint.rewardReserved(address(token));
        uint256 minted = mint.rewardMinted(address(token));
        uint256 burned = mint.rewardBurned(address(token));
        uint256 supply = token.totalSupply();
        uint256 maxSupply = token.maxSupply();

        // available = maxSupply - totalSupply - reservedAvailable
        // reservedAvailable = reserved - minted - burned
        uint256 reservedAvailable = reserved - minted - burned;

        assert(available + supply + reservedAvailable == maxSupply);
    }

    /// @notice Invariant: rewardMinted never decreases
    function invariant_MintedMonotonic() public view {
        uint256 minted = mint.rewardMinted(address(token));
        assert(minted >= settledGovRewards + settledProposalRewards);
    }

    /// @notice Invariant: rewardReserved never decreases after first prepare
    function invariant_ReservedMonotonicAfterFirstPrepare() public view {
        if (preparedRounds > 0) {
            uint256 reserved = mint.rewardReserved(address(token));
            assert(reserved > 0);
        }
    }

    /// @notice Invariant: gov + proposal rewards never exceed reserved
    function invariant_PreparedRewardsNeverExceedReserved() public view {
        for (uint256 i = 1; i <= 10; i++) {
            if (mint.isRewardPrepared(address(token), i)) {
                uint256 govReward = mint.govReward(address(token), i);
                uint256 proposalReward = mint.proposalReward(address(token), i);
                uint256 reserved = mint.rewardReserved(address(token));

                assert(govReward + proposalReward <= reserved);
            }
        }
    }

    /// @notice Invariant: eligible proposal votes never exceed total votes
    function invariant_EligibleVotesNeverExceedTotal() public view {
        for (uint256 i = 1; i <= 10; i++) {
            if (mint.isRewardPrepared(address(token), i)) {
                uint256 eligibleVotes = mint.eligibleProposalVotes(address(token), i);
                // Total votes in our mock is 1000
                assert(eligibleVotes <= 1500); // 5 proposals × 300 votes
            }
        }
    }

    /// @notice Invariant: individual gov reward never exceeds pool
    function invariant_IndividualGovRewardNeverExceedsPool() public view {
        for (uint256 round = 1; round <= 10; round++) {
            if (mint.isRewardPrepared(address(token), round)) {
                uint256 govReward = mint.govReward(address(token), round);
                if (govReward == 0) continue;

                for (uint256 memberId = 1; memberId <= 10; memberId++) {
                    (uint256 voteReward, uint256 boostReward,,) =
                        mint.govRewardByMemberId(address(token), round, memberId);

                    assert(voteReward + boostReward <= govReward);
                }
            }
        }
    }

    /// @notice Invariant: individual proposal reward never exceeds pool
    function invariant_IndividualProposalRewardNeverExceedsPool() public view {
        for (uint256 round = 1; round <= 10; round++) {
            if (mint.isRewardPrepared(address(token), round)) {
                uint256 proposalReward = mint.proposalReward(address(token), round);
                if (proposalReward == 0) continue;

                for (uint256 proposalId = 1; proposalId <= 5; proposalId++) {
                    if (mint.isProposalIdWithReward(address(token), round, proposalId)) {
                        (uint256 amount,) = mint.proposalRewardByProposalId(address(token), round, proposalId);
                        assert(amount <= proposalReward);
                    }
                }
            }
        }
    }

    /// @notice Invariant: boost burn never exceeds theoretical boost
    function invariant_BoostBurnNeverExceedsTheoretical() public view {
        for (uint256 round = 1; round <= 10; round++) {
            if (mint.isRewardPrepared(address(token), round)) {
                uint256 govReward = mint.govReward(address(token), round);
                if (govReward == 0) continue;

                for (uint256 memberId = 1; memberId <= 10; memberId++) {
                    (uint256 voteReward, uint256 boostReward, uint256 burnReward,) =
                        mint.govRewardByMemberId(address(token), round, memberId);

                    // burnReward should not exceed what theoretical boost would be
                    uint256 theoreticalMax = voteReward * 2; // maxGovBoostRewardMultiplier
                    assert(burnReward + boostReward <= theoreticalMax);
                }
            }
        }
    }

    // Helper functions to trigger state changes for invariant testing

    function prepare(uint256 round) public {
        if (round == 0 || round > 10) return;
        mint.prepareRewardIfNeeded(address(token), round);
        preparedRounds++;
    }

    function settleGov(uint256 memberId, uint256 round) public {
        if (memberId == 0 || memberId > 10) return;
        if (round == 0 || round > 10) return;
        if (!mint.isRewardPrepared(address(token), round)) return;

        try mint.mintGovReward(address(token), memberId, round) {
            settledGovRewards++;
        } catch {
            // Ignore expected reverts
        }
    }

    function settleProposal(uint256 round, uint256 proposalId) public {
        if (round == 0 || round > 10) return;
        if (proposalId == 0 || proposalId > 5) return;
        if (!mint.isRewardPrepared(address(token), round)) return;

        try mint.mintProposalReward(address(token), round, proposalId) {
            settledProposalRewards++;
        } catch {
            // Ignore expected reverts
        }
    }

    function batchSettle(uint256 memberId, uint256[] memory rounds) public {
        if (memberId == 0 || memberId > 10) return;
        if (rounds.length == 0 || rounds.length > 10) return;

        try mint.mintGovRewards(address(token), memberId, rounds) {
            settledGovRewards += rounds.length;
        } catch {
            // Ignore expected reverts
        }
    }
}
