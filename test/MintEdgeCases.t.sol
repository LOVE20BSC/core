// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Mint} from "../src/Mint.sol";
import {LOVE20Token} from "../src/LOVE20Token.sol";
import {IMintErrors} from "../src/interfaces/IMint.sol";
import {ISubmitErrors, TargetMode} from "../src/interfaces/ISubmit.sol";
import {IERC721Errors} from "../lib/openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";

interface MintVm {
    function expectRevert(bytes calldata data) external;
    function prank(address sender) external;
}

contract MintEdgeCasesTest {
    MintVm constant vm = MintVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    Mint mint;
    LOVE20Token token;
    address constant TARGET = address(0x1234);

    function setupMint(uint256 supply, uint256 maxSupply) internal {
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
        token = new LOVE20Token("Test", "TST", supply, maxSupply, address(this), address(mint), address(1));
    }

    uint256 public currentPhaseValue = type(uint256).max;

    function phaseAddress() external view returns (address) {
        return address(this);
    }

    function currentPhase() external view returns (uint256) {
        return currentPhaseValue;
    }

    function ownerOf(uint256 id) external view returns (address) {
        if (id != 1) revert IERC721Errors.ERC721NonexistentToken(id);
        return address(this);
    }

    function votesNum(address, uint256) external pure returns (uint256) {
        return 100;
    }

    function votesNumByMemberId(address, uint256, uint256 id) external pure returns (uint256) {
        return id == 1 ? 50 : 0;
    }

    function votesNumByProposalId(address, uint256, uint256 id) external pure returns (uint256) {
        return id == 1 ? 100 : 0;
    }

    function votedProposalIds(address, uint256, uint256, uint256 limit, bool)
        external
        pure
        returns (uint256[] memory ids, uint256 total)
    {
        total = 1;
        ids = new uint256[](limit == 0 ? 0 : 1);
        if (ids.length > 0) ids[0] = 1;
    }

    function stakedAmountOfVoters(address, uint256) external pure returns (uint256) {
        return 1000;
    }

    function stakedAmountOfVotersByMemberId(address, uint256, uint256) external pure returns (uint256) {
        return 1000;
    }

    function proposalTarget(address, uint256 id) external pure returns (address, TargetMode) {
        if (id == 0 || id > 1) revert ISubmitErrors.ProposalNotFound(id);
        return (TARGET, TargetMode.NoCallback);
    }

    function addLaunchCount(address, uint256, uint256) external view {
        require(msg.sender == address(mint));
    }

    function issuedLaunchCount(address) external pure returns (uint256) {
        return 0;
    }

    function MAX_LAUNCH_COUNT() external pure returns (uint256) {
        return 1000;
    }

    function LAUNCH_RATIO() external pure returns (uint256) {
        return 1e16;
    }

    function testRepeatedInitReverts() public {
        setupMint(1000, 10000);
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.AlreadyInitialized.selector));
        mint.init(address(this), address(this), address(this), address(this), 50, 100, 100, 2);
    }

    function testInitDerivesPhaseFromVote() public {
        setupMint(1000, 10000);
        require(mint.phaseAddress() == address(this), "phase derived and exposed");
    }

    function testInitRejectsVoteWithoutPhase() public {
        ZeroPhaseVote zeroPhaseVote = new ZeroPhaseVote();
        Mint fresh = new Mint();
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.InvalidAddress.selector));
        fresh.init(address(zeroPhaseVote), address(this), address(this), address(this), 50, 100, 100, 2);
        require(!fresh.initialized(), "must not latch on failed derivation");
    }

    function testRoundEndedReadsDerivedPhaseDirectly() public {
        setupMint(1000, 10000);
        currentPhaseValue = 5;
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.RoundNotReadyToMint.selector));
        mint.mintGovReward(address(token), 1, 5);

        currentPhaseValue = 6;
        (uint256 voteReward,,) = mint.mintGovReward(address(token), 1, 5);
        require(voteReward > 0, "round settles once the derived phase advances");
    }

    function testProposalDoubleClaimReverts() public {
        setupMint(1000, 10000);
        vm.prank(TARGET);
        mint.mintProposalReward(address(token), 1, 1);
        vm.prank(TARGET);
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.AlreadyMinted.selector));
        mint.mintProposalReward(address(token), 1, 1);
    }

    function testRewardReservedGetter() public {
        setupMint(1000, 10000);
        require(mint.rewardReserved(address(token)) == 0, "initial reserved");
        vm.prank(TARGET);
        mint.mintProposalReward(address(token), 1, 1);
        require(mint.rewardReserved(address(token)) > 0, "reserved after prepare");
    }

    function testGovRewardGetter() public {
        setupMint(1000, 10000);
        require(mint.govReward(address(token), 1) == 0, "initial gov reward");
        mint.mintGovReward(address(token), 1, 1);
        require(mint.govReward(address(token), 1) > 0, "gov reward after prepare");
    }

    function testProposalRewardGetter() public {
        setupMint(1000, 10000);
        require(mint.proposalReward(address(token), 1) == 0, "initial proposal reward");
        vm.prank(TARGET);
        mint.mintProposalReward(address(token), 1, 1);
        require(mint.proposalReward(address(token), 1) > 0, "proposal reward after prepare");
    }

    function testRewardAvailableGetter() public {
        setupMint(1000, 10000);
        uint256 available = mint.rewardAvailable(address(token));
        require(available == 9000, "available matches maxSupply - totalSupply");
    }

    function testBurnUnmintedUnauthorizedReverts() public {
        setupMint(1000, 10000);
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.UnauthorizedCaller.selector));
        mint.burnUnmintedProposalReward(address(token), 1, 1);
    }

    function testBurnUnmintedRoundNotReadyReverts() public {
        setupMint(1000, 10000);
        vm.prank(TARGET);
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.RoundNotReadyToMint.selector));
        mint.burnUnmintedProposalReward(address(token), 0, 1);
    }

    function testBurnUnmintedUnknownProposalReverts() public {
        setupMint(1000, 10000);
        vm.prank(TARGET);
        vm.expectRevert(abi.encodeWithSelector(ISubmitErrors.ProposalNotFound.selector, 2));
        mint.burnUnmintedProposalReward(address(token), 1, 2);
    }
}

contract ZeroPhaseVote {
    function phaseAddress() external pure returns (address) {
        return address(0);
    }
}
