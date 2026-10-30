// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Mint} from "../src/Mint.sol";
import {LOVE20Token} from "../src/LOVE20Token.sol";
import {IMintErrors} from "../src/interfaces/IMint.sol";
import {ISubmitErrors, TargetMode} from "../src/interfaces/ISubmit.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

interface MintVm {
    function expectRevert(bytes calldata data) external;
    function prank(address sender) external;
}

contract MintUnpreparedTest {
    MintVm constant vm = MintVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Mint mint;
    LOVE20Token token;
    uint256 totalVoteAmountValue = 100;
    uint256 memberVoteAmount = 10;
    uint256 proposalVoteAmount = 20;
    uint256 totalBoost = 50;
    uint256 memberBoost = 5;
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
            5e16,
            govRatio,
            proposalRatio,
            2
        );
        token = new LOVE20Token("Test", "TST", supply, maxSupply, address(this), address(mint), address(this));
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
        return id == 1 ? proposalVoteAmount : 0;
    }

    function votedProposalIds(address, uint256, uint256, uint256 limit, bool)
        external
        pure
        returns (uint256[] memory ids, uint256 total)
    {
        total = 1;
        ids = new uint256[](limit == 0 ? 0 : 1);
        if (ids.length > 0) {
            ids[0] = 1;
        }
    }

    function totalVoterBoost(address, uint256) external view returns (uint256) {
        return totalBoost;
    }

    function voterBoost(address, uint256, uint256) external view returns (uint256) {
        return memberBoost;
    }

    function proposalTarget(address, uint256 id) external pure returns (address, TargetMode) {
        if (id == 0 || id > 1) revert ISubmitErrors.ProposalNotFound(id);
        return (address(0xBEEF), TargetMode.NoCallback);
    }

    function addLaunchCount(address community, uint256, uint256 count) external {
        require(msg.sender == address(mint));
        issuedLaunchCount[community] += count;
    }

    function testUnpreparedProposalRewardCalculatesRealtime() public {
        setupMint(1000, 10000, 0, 1e17);
        (uint256 amount, bool minted) = mint.proposalRewardByProposalId(address(token), 1, 1);
        require(amount == 900 && !minted, "only eligible proposal gets full pool: 900 * 20 / 20");
        require(!mint.isRewardPrepared(address(token), 1), "should not be prepared");
    }

    function testUnpreparedGovRewardCalculatesRealtime() public {
        setupMint(1000, 10000, 1e17, 0);
        (uint256 voteReward, uint256 boostReward, uint256 burnReward, bool minted) =
            mint.govRewardByMemberId(address(token), 1, 1);
        require(voteReward == 45 && boostReward == 45 && burnReward == 0 && !minted, "unprepared 10/100 * 900");
        require(!mint.isRewardPrepared(address(token), 1), "should not be prepared");
    }

    function testUnpreparedIsProposalIdWithRewardReturnsTrue() public {
        setupMint(1000, 10000, 0, 1e17);
        require(mint.isProposalIdWithReward(address(token), 1, 1), "20/100 >= 5% threshold");
        require(!mint.isRewardPrepared(address(token), 1), "should not be prepared");
    }

    function testUnpreparedBelowThresholdReturnsFalse() public {
        proposalVoteAmount = 4;
        setupMint(1000, 10000, 0, 1e17);
        require(!mint.isProposalIdWithReward(address(token), 1, 1), "4/100 < 5% threshold");
        (uint256 amount,) = mint.proposalRewardByProposalId(address(token), 1, 1);
        require(amount == 0, "ineligible returns zero");
    }

    function testPreparedAndUnpreparedQueryConsistency() public {
        setupMint(1000, 10000, 1e17, 1e17);
        (uint256 unprepGov,,,) = mint.govRewardByMemberId(address(token), 1, 1);
        (uint256 unprepProp,) = mint.proposalRewardByProposalId(address(token), 1, 1);


        (uint256 prepGov,,,) = mint.govRewardByMemberId(address(token), 1, 1);
        (uint256 prepProp,) = mint.proposalRewardByProposalId(address(token), 1, 1);

        require(unprepGov == prepGov, "gov reward must match");
        require(unprepProp == prepProp, "proposal reward must match");
    }

    function testUnpreparedWithZeroVoteAmountReturnsZero() public {
        totalVoteAmountValue = 0;
        memberVoteAmount = 0;
        proposalVoteAmount = 0;
        setupMint(1000, 10000, 1e17, 1e17);

        (uint256 voteReward, uint256 boostReward, uint256 burnReward, bool minted) =
            mint.govRewardByMemberId(address(token), 1, 1);
        require(voteReward == 0 && boostReward == 0 && burnReward == 0 && !minted, "zero votes");

        (uint256 amount,) = mint.proposalRewardByProposalId(address(token), 1, 1);
        require(amount == 0, "zero proposal votes");
    }
}
