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

    function isRoundEnded(uint256 round) external pure returns (bool) {
        return round > 0;
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

    function testRepeatedInitReverts() public {
        setupMint(1000, 10000);
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.AlreadyInitialized.selector));
        mint.init(address(this), address(this), address(this), address(this), 50, 100, 100, 2);
    }

    function testProposalDoubleClaimReverts() public {
        setupMint(1000, 10000);
        mint.prepareRewardIfNeeded(address(token), 1);
        vm.prank(TARGET);
        mint.mintProposalReward(address(token), 1, 1);
        vm.prank(TARGET);
        vm.expectRevert(abi.encodeWithSelector(IMintErrors.AlreadyMinted.selector));
        mint.mintProposalReward(address(token), 1, 1);
    }

    function testRewardReservedGetter() public {
        setupMint(1000, 10000);
        require(mint.rewardReserved(address(token)) == 0, "initial reserved");
        mint.prepareRewardIfNeeded(address(token), 1);
        require(mint.rewardReserved(address(token)) > 0, "reserved after prepare");
    }

    function testGovRewardGetter() public {
        setupMint(1000, 10000);
        require(mint.govReward(address(token), 1) == 0, "initial gov reward");
        mint.prepareRewardIfNeeded(address(token), 1);
        require(mint.govReward(address(token), 1) > 0, "gov reward after prepare");
    }

    function testProposalRewardGetter() public {
        setupMint(1000, 10000);
        require(mint.proposalReward(address(token), 1) == 0, "initial proposal reward");
        mint.prepareRewardIfNeeded(address(token), 1);
        require(mint.proposalReward(address(token), 1) > 0, "proposal reward after prepare");
    }

    function testRewardAvailableGetter() public {
        setupMint(1000, 10000);
        uint256 available = mint.rewardAvailable(address(token));
        require(available == 9000, "available matches maxSupply - totalSupply");
    }
}
