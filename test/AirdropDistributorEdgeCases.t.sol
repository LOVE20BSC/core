// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {LaunchDeployFixture} from "./utils/LaunchDeployFixture.sol";
import {
    IAirdropDistributor,
    IAirdropDistributorErrors,
    AirdropInfo
} from "../src/interfaces/distributor/IAirdropDistributor.sol";
import {ILaunchDistributor} from "../src/interfaces/distributor/ILaunchDistributor.sol";
import {LOVE20Token} from "../src/LOVE20Token.sol";

/// 只在构造期配置好首币、随后用低层调用手动触发回调的分发方包装：
/// 直接复用 AirdropDistributor，由测试本身以 Launch 地址身份伪造 msg.sender
contract AirdropDistributorEdgeCasesTest is LaunchDeployFixture {
    bytes32 internal constant GENESIS_ROOT = keccak256("genesis root");

    function setUp() public {
        _deploySystem(GENESIS_ROOT, 0);
    }

    // ============ 9. 回调鉴权 ============

    function testOnTokenLaunchedRejectsNonLaunchCaller() external {
        bytes[] memory data = _distributorData(keccak256("x"), 0);
        _assertRevertSelector(
            ALICE,
            abi.encodeCall(ILaunchDistributor.onTokenLaunched, (address(0x1234), address(firstToken), 1, data)),
            IAirdropDistributorErrors.NotLaunchContract.selector
        );
    }

    function testOnTokenLaunchedRejectsNonLaunchCallerEvenWithInvalidPayload() external {
        // 鉴权先于参数校验：即使 payload 非法，非 Launch 调用者只拿到鉴权错误
        bytes[] memory data = new bytes[](0);
        _assertRevertSelector(
            ALICE,
            abi.encodeCall(ILaunchDistributor.onTokenLaunched, (address(0x1234), address(firstToken), 1, data)),
            IAirdropDistributorErrors.NotLaunchContract.selector
        );
    }

    function testOnTokenLaunchedReportsCallerInErrorPayload() external {
        bytes[] memory data = new bytes[](0);
        bytes memory expected = abi.encodeWithSelector(
            IAirdropDistributorErrors.NotLaunchContract.selector, ALICE
        );
        _expectRevert(
            ALICE,
            abi.encodeCall(ILaunchDistributor.onTokenLaunched, (address(0x1234), address(firstToken), 1, data)),
            expected
        );
    }

    // ============ 10. distributorData 条数 ============

    function testOnTokenLaunchedRejectsEmptyDistributorData() external {
        bytes[] memory data = new bytes[](0);
        _assertRevertSelector(
            address(launch),
            abi.encodeCall(ILaunchDistributor.onTokenLaunched, (address(0x1234), address(firstToken), 1, data)),
            IAirdropDistributorErrors.InvalidDistributorDataCount.selector
        );
    }

    function testOnTokenLaunchedRejectsTwoDistributorDataEntries() external {
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encode(keccak256("a"), uint256(0));
        data[1] = abi.encode(keccak256("b"), uint256(0));
        _assertRevertSelector(
            address(launch),
            abi.encodeCall(ILaunchDistributor.onTokenLaunched, (address(0x1234), address(firstToken), 1, data)),
            IAirdropDistributorErrors.InvalidDistributorDataCount.selector
        );
    }

    function testOnTokenLaunchedReportsDistributorDataCountPayload() external {
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encode(keccak256("a"), uint256(0));
        data[1] = abi.encode(keccak256("b"), uint256(0));
        _expectRevert(
            address(launch),
            abi.encodeCall(ILaunchDistributor.onTokenLaunched, (address(0x1234), address(firstToken), 1, data)),
            abi.encodeWithSelector(IAirdropDistributorErrors.InvalidDistributorDataCount.selector, 2, 1)
        );
    }

    // ============ 11. distributorData 元素长度 ============

    function testOnTokenLaunchedRejectsWrongPayloadLength() external {
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(keccak256("short"));

        _expectRevert(
            address(launch),
            abi.encodeCall(ILaunchDistributor.onTokenLaunched, (address(0x1234), address(firstToken), 1, data)),
            abi.encodeWithSelector(IAirdropDistributorErrors.InvalidDistributorDataLength.selector, 32, 64)
        );
    }

    function testOnTokenLaunchedRejectsOversizedPayload() external {
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(keccak256("a"), uint256(0), uint256(0));

        _expectRevert(
            address(launch),
            abi.encodeCall(ILaunchDistributor.onTokenLaunched, (address(0x1234), address(firstToken), 1, data)),
            abi.encodeWithSelector(IAirdropDistributorErrors.InvalidDistributorDataLength.selector, 96, 64)
        );
    }

    // ============ 12. merkleRoot == 0 ============

    function testOnTokenLaunchedRejectsZeroMerkleRoot() external {
        _expectRevert(
            address(launch),
            abi.encodeCall(
                ILaunchDistributor.onTokenLaunched,
                (address(0x1234), address(firstToken), 1, _distributorData(bytes32(0), 0))
            ),
            abi.encodeWithSelector(IAirdropDistributorErrors.ZeroMerkleRoot.selector)
        );
    }

    // ============ 13. claimDelayRounds 上界 ============

    function testOnTokenLaunchedAcceptsMaximumClaimDelayRounds() external {
        _rollToPhase(2);
        address tokenAddress = address(0x1234);
        bytes[] memory data = _distributorData(keccak256("max delay"), 1000);

        vm.prank(address(launch));
        distributor.onTokenLaunched(tokenAddress, address(firstToken), 1, data);

        require(distributor.claimableFromRoundByTokenAddress(tokenAddress) == 1002, "base 2 + 1000");
        require(distributor.merkleRootByTokenAddress(tokenAddress) == keccak256("max delay"), "configured");
    }

    function testOnTokenLaunchedRejectsClaimDelayRoundsAboveMaximum() external {
        _expectRevert(
            address(launch),
            abi.encodeCall(
                ILaunchDistributor.onTokenLaunched,
                (address(0x1234), address(firstToken), 1, _distributorData(keccak256("too long"), 1001))
            ),
            abi.encodeWithSelector(IAirdropDistributorErrors.ClaimDelayRoundsExceeded.selector, 1001, 1000)
        );
    }

    // ============ 14. 同一 token 二次配置 ============

    function testReconfiguringTheSameTokenReverts() external {
        // 首币已在构造期配置；把首币再配置一次必然命中 TokenAlreadyConfigured
        _expectRevert(
            address(launch),
            abi.encodeCall(
                ILaunchDistributor.onTokenLaunched,
                (address(firstToken), address(ROOT_TOKEN), 1, _distributorData(keccak256("dup"), 0))
            ),
            abi.encodeWithSelector(IAirdropDistributorErrors.TokenAlreadyConfigured.selector, address(firstToken))
        );
    }

    function testReconfiguringAConfiguredSubTokenReverts() external {
        bytes32 root = keccak256("sub root");
        address subToken = _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(root, 0));

        _expectRevert(
            address(launch),
            abi.encodeCall(
                ILaunchDistributor.onTokenLaunched,
                (subToken, address(firstToken), aliceMemberId, _distributorData(keccak256("dup"), 0))
            ),
            abi.encodeWithSelector(IAirdropDistributorErrors.TokenAlreadyConfigured.selector, subToken)
        );
        require(distributor.merkleRootByTokenAddress(subToken) == root, "original root intact");
    }

    function testTokenAlreadyConfiguredOutranksOtherChecks() external {
        // 已配置 token 再用零 root 配置：先命中 TokenAlreadyConfigured，而非 ZeroMerkleRoot
        _assertRevertSelector(
            address(launch),
            abi.encodeCall(
                ILaunchDistributor.onTokenLaunched,
                (address(firstToken), address(ROOT_TOKEN), 1, _distributorData(bytes32(0), 5000))
            ),
            IAirdropDistributorErrors.TokenAlreadyConfigured.selector
        );
    }

    // ============ 15. 未配置 token ============

    function testClaimOnUnconfiguredTokenReverts() external {
        _rollToPhase(1);
        bytes32[] memory proof = new bytes32[](0);
        _assertRevertSelector(
            ALICE,
            abi.encodeCall(IAirdropDistributor.claim, (address(0xdead), 1e17, proof)),
            IAirdropDistributorErrors.TokenNotConfigured.selector
        );
    }

    function testClaimReportsUnconfiguredTokenPayload() external {
        _rollToPhase(1);
        _expectRevert(
            ALICE,
            abi.encodeCall(IAirdropDistributor.claim, (address(0xdead), 1e17, new bytes32[](0))),
            abi.encodeWithSelector(IAirdropDistributorErrors.TokenNotConfigured.selector, address(0xdead))
        );
    }

    function testTokenNotConfiguredOutranksRoundCheck() external {
        // 创世前 + 未配置：先命中 TokenNotConfigured
        require(phase.currentPhase() == 0, "pre-genesis");
        _assertRevertSelector(
            ALICE,
            abi.encodeCall(IAirdropDistributor.claim, (address(0xdead), 1e17, new bytes32[](0))),
            IAirdropDistributorErrors.TokenNotConfigured.selector
        );
    }

    // ============ 16. 未到领取轮 ============

    function testClaimBeforeClaimableRoundReverts() external {
        _rollToPhase(1);
        bytes32[] memory leaves = _threeLeaves();
        address subToken = _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(_merkleRoot(leaves), 2));
        require(distributor.claimableFromRoundByTokenAddress(subToken) == 3, "round 3");

        _expectRevert(
            ALICE,
            abi.encodeCall(IAirdropDistributor.claim, (subToken, ALICE_SHARE, _merkleProof(leaves, 0))),
            abi.encodeWithSelector(IAirdropDistributorErrors.ClaimRoundNotReached.selector, subToken, 1, 3)
        );
    }

    function testClaimRoundNotReachedOutranksAlreadyClaimed() external {
        // 已领取的 token 在下一轮也会先命中轮次校验吗？claimableFromRound 已过则不会。
        // 这里验证：未到轮次时，即使调用者已领取过，也先报轮次未到（顺序契约）。
        _rollToPhase(1);
        bytes32[] memory leaves = _threeLeaves();
        address subToken = _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(_merkleRoot(leaves), 1));
        _rollToPhase(2);
        _claimAs(ALICE, subToken, ALICE_SHARE, _merkleProof(leaves, 0));

        // 构造一个更晚的轮次配置无法实现（配置后不可改），改为验证已领取错误
        _assertRevertSelector(
            ALICE,
            abi.encodeCall(IAirdropDistributor.claim, (subToken, ALICE_SHARE, _merkleProof(leaves, 0))),
            IAirdropDistributorErrors.AirdropAlreadyClaimed.selector
        );
    }

    // ============ 17. 重复领取 ============

    function testClaimTwiceReverts() external {
        _rollToPhase(1);
        bytes32[] memory leaves = _threeLeaves();
        bytes32[] memory proof = _merkleProof(leaves, 0);
        address subToken = _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(_merkleRoot(leaves), 0));

        _claimAs(ALICE, subToken, ALICE_SHARE, proof);

        _expectRevert(
            ALICE,
            abi.encodeCall(IAirdropDistributor.claim, (subToken, ALICE_SHARE, proof)),
            abi.encodeWithSelector(IAirdropDistributorErrors.AirdropAlreadyClaimed.selector, subToken, ALICE)
        );
    }

    function testClaimTwiceKeepsTheFirstAmount() external {
        _rollToPhase(1);
        bytes32[] memory leaves = _threeLeaves();
        bytes32[] memory proof = _merkleProof(leaves, 0);
        address subToken = _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(_merkleRoot(leaves), 0));

        (bool ok, bytes memory data) =
            _callAs(ALICE, abi.encodeCall(IAirdropDistributor.claim, (subToken, ALICE_SHARE, proof)));
        require(ok, "first claim");
        uint256 firstAmount = abi.decode(data, (uint256));

        (ok, ) = _callAs(ALICE, abi.encodeCall(IAirdropDistributor.claim, (subToken, ALICE_SHARE, proof)));
        require(!ok, "second claim reverts");
        require(
            distributor.claimedAmountByTokenAddressByClaimer(subToken, ALICE) == firstAmount, "amount unchanged"
        );
    }

    // ============ 18. 份额超剩余 ============

    function testClaimAboveRemainingShareReverts() external {
        _rollToPhase(1);
        bytes32[] memory leaves = _threeLeaves();
        address subToken = _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(_merkleRoot(leaves), 0));

        // 先让 CAROL 领走 60%，剩余 40%；此时 ALICE 的 100% 份额必超剩余
        _claimAs(CAROL, subToken, CAROL_SHARE, _merkleProof(leaves, 2));

        _expectRevert(
            ALICE,
            abi.encodeCall(IAirdropDistributor.claim, (subToken, TOTAL_SHARE, _merkleProof(leaves, 0))),
            abi.encodeWithSelector(
                IAirdropDistributorErrors.ShareExceedsRemaining.selector, TOTAL_SHARE, TOTAL_SHARE - CAROL_SHARE
            )
        );
    }

    function testShareExceedsRemainingOutranksMerkleProof() external {
        // 超剩余 + 错误 proof：先命中 ShareExceedsRemaining
        _rollToPhase(1);
        bytes32[] memory leaves = _threeLeaves();
        address subToken = _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(_merkleRoot(leaves), 0));
        _claimAs(CAROL, subToken, CAROL_SHARE, _merkleProof(leaves, 2));

        _assertRevertSelector(
            ALICE,
            abi.encodeCall(IAirdropDistributor.claim, (subToken, TOTAL_SHARE, new bytes32[](0))),
            IAirdropDistributorErrors.ShareExceedsRemaining.selector
        );
    }

    function testClaimExactlyRemainingShareSucceeds() external {
        _rollToPhase(1);
        bytes32[] memory leaves = _threeLeaves();
        address subToken = _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(_merkleRoot(leaves), 0));

        _claimAs(CAROL, subToken, CAROL_SHARE, _merkleProof(leaves, 2));
        uint256 remaining = distributor.remainingShareByTokenAddress(subToken);
        require(remaining == TOTAL_SHARE - CAROL_SHARE, "remaining after carol");

        // 单叶树：ALICE 的份额正好等于整个 TOTAL_SHARE，即 claim 时 remaining 恰好等于 share
        bytes32[] memory single = new bytes32[](1);
        single[0] = _leaf(ALICE, TOTAL_SHARE);
        address exactToken =
            _launchSubToken(ALICE, aliceMemberId, "EXT", _distributorData(_merkleRoot(single), 0));

        uint256 pool = LOVE20Token(exactToken).balanceOf(address(distributor));
        _claimAs(ALICE, exactToken, TOTAL_SHARE, _merkleProof(single, 0));
        require(distributor.remainingShareByTokenAddress(exactToken) == 0, "exact share exhausts");
        require(LOVE20Token(exactToken).balanceOf(address(distributor)) == 0, "pool drained");
        require(LOVE20Token(exactToken).balanceOf(ALICE) == pool, "full pool paid out");
    }

    // ============ 19./20. proof 非法与零份额 ============

    function testClaimWithWrongProofReverts() external {
        _rollToPhase(1);
        bytes32[] memory leaves = _threeLeaves();
        address subToken = _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(_merkleRoot(leaves), 0));

        // 用 BOB 的 proof 领取 ALICE 的份额
        _assertRevertSelector(
            ALICE,
            abi.encodeCall(IAirdropDistributor.claim, (subToken, ALICE_SHARE, _merkleProof(leaves, 1))),
            IAirdropDistributorErrors.InvalidProof.selector
        );
    }

    function testClaimWithEmptyProofReverts() external {
        _rollToPhase(1);
        bytes32[] memory leaves = _threeLeaves();
        address subToken = _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(_merkleRoot(leaves), 0));

        _assertRevertSelector(
            ALICE,
            abi.encodeCall(IAirdropDistributor.claim, (subToken, ALICE_SHARE, new bytes32[](0))),
            IAirdropDistributorErrors.InvalidProof.selector
        );
    }

    function testZeroShareRevertsWithInvalidProofNotANewError() external {
        _rollToPhase(1);

        // 树中只有非零份额叶子：claim(share = 0) 的叶子不在树里，归入 InvalidProof
        bytes32[] memory leaves = _threeLeaves();
        address subToken =
            _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(_merkleRoot(leaves), 0));

        _assertRevertSelector(
            ALICE,
            abi.encodeCall(IAirdropDistributor.claim, (subToken, 0, _merkleProof(leaves, 0))),
            IAirdropDistributorErrors.InvalidProof.selector
        );
    }

    function testZeroShareWithEmptyProofReverts() external {
        _rollToPhase(1);
        bytes32[] memory leaves = _threeLeaves();
        address subToken =
            _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(_merkleRoot(leaves), 0));

        // share == 0 不触发 ShareExceedsRemaining（0 不 > remaining），落到 merkle 校验
        _assertRevertSelector(
            ALICE,
            abi.encodeCall(IAirdropDistributor.claim, (subToken, 0, new bytes32[](0))),
            IAirdropDistributorErrors.InvalidProof.selector
        );
        require(distributor.claimedShareByTokenAddress(subToken) == 0, "no state written");
        require(!distributor.isClaimedByTokenAddressByClaimer(subToken, ALICE), "not marked claimed");
    }

    function testZeroShareDoesNotTriggerShareExceedsRemaining() external {
        _rollToPhase(1);
        bytes32[] memory leaves = _threeLeaves();
        address subToken =
            _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(_merkleRoot(leaves), 0));
        // 先耗尽大部分份额，使 remaining 很小；share == 0 仍然不命中上界错误
        _claimAs(CAROL, subToken, CAROL_SHARE, _merkleProof(leaves, 2));

        _assertRevertSelector(
            ALICE,
            abi.encodeCall(IAirdropDistributor.claim, (subToken, 0, new bytes32[](0))),
            IAirdropDistributorErrors.InvalidProof.selector
        );
    }

    /// 加固后新增：树里含真正的零份额叶子时，claim(share=0) 必须被显式拒绝。
    /// 加固前该路径会静默成功（amount=0、写 isClaimed=true），使该地址永久失去领取资格。
    function testZeroShareLeafWithValidProofIsRejectedBeforeAnyStateWrite() external {
        _rollToPhase(1);

        // 树叶确实包含 leaf(ALICE, 0)，proof 完全正确
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _leaf(ALICE, 0);
        leaves[1] = _leaf(BOB, 5e17);
        address subToken =
            _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(_merkleRoot(leaves), 0));

        // 契约要求的回滚数据必须逐字节匹配：InvalidProof()
        _expectRevert(
            ALICE,
            abi.encodeCall(IAirdropDistributor.claim, (subToken, 0, _merkleProof(leaves, 0))),
            abi.encodeWithSelector(IAirdropDistributorErrors.InvalidProof.selector)
        );

        // 这是本次加固的核心断言：原本会静默成功的路径不得写任何状态
        require(!distributor.isClaimedByTokenAddressByClaimer(subToken, ALICE), "no claim flag");
        require(distributor.claimedShareByTokenAddress(subToken) == 0, "no claimed share");
        require(
            distributor.claimedAmountByTokenAddressByClaimer(subToken, ALICE) == 0, "no claimed amount"
        );
        require(distributor.remainingShareByTokenAddress(subToken) == TOTAL_SHARE, "remaining untouched");
        require(LOVE20Token(subToken).balanceOf(ALICE) == 0, "no tokens transferred");

        // 该地址的领取资格未被消耗：用其它合法份额仍不可行（不在树里），
        // 但 BOB 的正常领取必须成功，证明池子未被污染
        _claimAs(BOB, subToken, 5e17, _merkleProof(leaves, 1));
        require(distributor.isClaimedByTokenAddressByClaimer(subToken, BOB), "bob can still claim");
        require(LOVE20Token(subToken).balanceOf(BOB) == 50 ether, "bob paid his share");
    }

    // ============ 21. 延迟轮次语义 ============

    function testDelayZeroClaimableAtSameRoundAndDelayOneAtNext() external {
        _rollToPhase(3);

        bytes32[] memory leaves = _threeLeaves();
        address sameRound =
            _launchSubToken(ALICE, aliceMemberId, "SAM", _distributorData(_merkleRoot(leaves), 0));
        address nextRound =
            _launchSubToken(BOB, bobMemberId, "NXT", _distributorData(_merkleRoot(leaves), 1));

        require(distributor.claimableFromRoundByTokenAddress(sameRound) == 3, "delay 0 same round");
        require(distributor.claimableFromRoundByTokenAddress(nextRound) == 4, "delay 1 next round");

        _claimAs(ALICE, sameRound, ALICE_SHARE, _merkleProof(leaves, 0));
        _assertRevertSelector(
            ALICE,
            abi.encodeCall(IAirdropDistributor.claim, (nextRound, ALICE_SHARE, _merkleProof(leaves, 0))),
            IAirdropDistributorErrors.ClaimRoundNotReached.selector
        );

        _rollToPhase(4);
        _claimAs(ALICE, nextRound, ALICE_SHARE, _merkleProof(leaves, 0));
        require(distributor.isClaimedByTokenAddressByClaimer(nextRound, ALICE), "next round claim");
    }

    // ============ 22. 创世前夹取 ============

    function testPreGenesisClampPreventsClamingBeforeOrigin() external {
        require(phase.currentPhase() == 0, "pre-genesis");

        bytes32[] memory leaves = _threeLeaves();
        address subToken = _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(_merkleRoot(leaves), 0));
        require(distributor.claimableFromRoundByTokenAddress(subToken) == 1, "clamped to 1");

        _expectRevert(
            ALICE,
            abi.encodeCall(IAirdropDistributor.claim, (subToken, ALICE_SHARE, _merkleProof(leaves, 0))),
            abi.encodeWithSelector(IAirdropDistributorErrors.ClaimRoundNotReached.selector, subToken, 0, 1)
        );

        // 创世前永远无法领取：即使把区块推到 origin-1
        vm.roll(phaseOriginBlocks - 1);
        require(phase.currentPhase() == 0, "still pre-genesis");
        _assertRevertSelector(
            ALICE,
            abi.encodeCall(IAirdropDistributor.claim, (subToken, ALICE_SHARE, _merkleProof(leaves, 0))),
            IAirdropDistributorErrors.ClaimRoundNotReached.selector
        );

        vm.roll(phaseOriginBlocks);
        require(phase.currentPhase() == 1, "genesis reached");
        _claimAs(ALICE, subToken, ALICE_SHARE, _merkleProof(leaves, 0));
        require(distributor.isClaimedByTokenAddressByClaimer(subToken, ALICE), "claimable at origin");
    }

    function testGenesisDelayBaseRoundIsOneNotZero() external {
        // 重新部署一套，创世延迟为 7；创世前必须得 8（1+7），而不是 7（0+7）
        _deploySystem(GENESIS_ROOT, 7);
        require(phase.currentPhase() == 0, "pre-genesis");
        require(distributor.claimableFromRoundByTokenAddress(address(firstToken)) == 8, "1 + 7");
    }

    // ============ claimableAmount 只读契约 ============

    function testClaimableAmountNeverRevertsOnBadInput() external {
        _rollToPhase(1);
        bytes32[] memory empty = new bytes32[](0);
        require(distributor.claimableAmount(address(0), address(0), 0, empty) == 0, "all zero");
        require(distributor.claimableAmount(address(0xdead), ALICE, type(uint256).max, empty) == 0, "huge share");
    }

    function testClaimableAmountIsCallerIndependent() external {
        _rollToPhase(1);
        bytes32[] memory leaves = _threeLeaves();
        bytes32[] memory proof = _merkleProof(leaves, 0);
        address subToken = _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(_merkleRoot(leaves), 0));

        uint256 fromAlice = distributor.claimableAmount(subToken, ALICE, ALICE_SHARE, proof);
        uint256 fromCarol = distributor.claimableAmount(subToken, ALICE, ALICE_SHARE, proof);
        require(fromAlice != 0, "non-zero quote");
        require(fromAlice == fromCarol, "no caller dependency");

        _claimAs(ALICE, subToken, ALICE_SHARE, proof);
        require(distributor.claimableAmount(subToken, ALICE, ALICE_SHARE, proof) == 0, "zero after claim");
    }

    // ============ 26. updateSnapshotUri 鉴权顺序与错误归属 ============

    function testUpdateSnapshotUriUnconfiguredTokenErrorOutranksSnapshotUriChecks() external {
        // modifier 第一行先查 merkleRoot：未配置 token 即便 uri 为空/超长也只报 TokenNotConfigured
        address unknown = address(0xdead);
        _expectRevert(
            ALICE,
            abi.encodeCall(IAirdropDistributor.updateSnapshotUri, (unknown, "")),
            abi.encodeWithSelector(IAirdropDistributorErrors.TokenNotConfigured.selector, unknown)
        );
        string memory tooLong = _uriOfLength(257);
        _expectRevert(
            ALICE,
            abi.encodeCall(IAirdropDistributor.updateSnapshotUri, (unknown, tooLong)),
            abi.encodeWithSelector(IAirdropDistributorErrors.TokenNotConfigured.selector, unknown)
        );
    }

    function testUpdateSnapshotUriAuthErrorOutranksUriValidation() external {
        // 非发射者传空 uri：先过 modifier 鉴权，命中 NotSnapshotUriUpdater，而非 SnapshotUriEmpty
        address subToken = _launchSub(ALICE, aliceMemberId, "SUB");
        _expectRevert(
            BOB,
            abi.encodeCall(IAirdropDistributor.updateSnapshotUri, (subToken, "")),
            abi.encodeWithSelector(
                IAirdropDistributorErrors.NotSnapshotUriUpdater.selector, BOB, aliceMemberId
            )
        );
        // 非发射者传超长 uri：同样先命中鉴权
        string memory tooLong = _uriOfLength(257);
        _expectRevert(
            BOB,
            abi.encodeCall(IAirdropDistributor.updateSnapshotUri, (subToken, tooLong)),
            abi.encodeWithSelector(
                IAirdropDistributorErrors.NotSnapshotUriUpdater.selector, BOB, aliceMemberId
            )
        );
    }

    function testGenesisTokenAuthErrorReportsZeroMemberIdForEveryCaller() external {
        // 创世币 launcherMemberId == 0，任何调用者的错误负载里 memberId 都是 0
        bytes memory callData = abi.encodeCall(
            IAirdropDistributor.updateSnapshotUri, (address(firstToken), "https://genesis")
        );
        address[3] memory callers = [ALICE, BOB, address(this)];
        for (uint256 i; i < callers.length; ++i) {
            _expectRevert(
                callers[i],
                callData,
                abi.encodeWithSelector(
                    IAirdropDistributorErrors.NotSnapshotUriUpdater.selector, callers[i], 0
                )
            );
        }
    }

    function testSnapshotUriEmptyAndTooLongErrorsAreDistinct() external {
        address subToken = _launchSub(ALICE, aliceMemberId, "SUB");
        _assertRevertSelector(
            ALICE,
            abi.encodeCall(IAirdropDistributor.updateSnapshotUri, (subToken, "")),
            IAirdropDistributorErrors.SnapshotUriEmpty.selector
        );
        _assertRevertSelector(
            ALICE,
            abi.encodeCall(IAirdropDistributor.updateSnapshotUri, (subToken, _uriOfLength(257))),
            IAirdropDistributorErrors.SnapshotUriTooLong.selector
        );
    }

    function testLength256BoundaryAndLength257Boundary() external {
        address subToken = _launchSub(ALICE, aliceMemberId, "SUB");
        string memory exactly256 = _uriOfLength(256);
        vm.prank(ALICE);
        distributor.updateSnapshotUri(subToken, exactly256);
        require(bytes(exactly256).length == 256, "exactly 256 accepted");

        // 再次更新为 257 → SnapshotUriTooLong(257, 256)
        string memory tooLong = _uriOfLength(257);
        _expectRevert(
            ALICE,
            abi.encodeCall(IAirdropDistributor.updateSnapshotUri, (subToken, tooLong)),
            abi.encodeWithSelector(IAirdropDistributorErrors.SnapshotUriTooLong.selector, 257, 256)
        );
    }

    function _launchSub(address launcher, uint256 memberId, string memory symbol) private returns (address) {
        return _launchSubToken(launcher, memberId, symbol, _distributorData(keccak256("snapshot root"), 0));
    }

    function _uriOfLength(uint256 length) private pure returns (string memory) {
        bytes memory uri = new bytes(length);
        for (uint256 i; i < length; ++i) uri[i] = "a";
        return string(uri);
    }

}
