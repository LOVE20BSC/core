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
import {Launch} from "../src/Launch.sol";
import {DistributorMode} from "../src/interfaces/ILaunch.sol";

contract AirdropDistributorTest is LaunchDeployFixture {
    bytes32 internal constant GENESIS_ROOT = keccak256("genesis root");

    function setUp() public {
        _deploySystem(GENESIS_ROOT, 0);
    }

    // ============ 1. 构造函数与编译期常量 ============

    function testConstructorWiresDependenciesAndConstants() external view {
        require(distributor.LAUNCH_ADDRESS() == address(launch), "launch address");
        require(distributor.PHASE_ADDRESS() == address(phase), "phase address");
        require(distributor.TOTAL_SHARE() == 1e18, "total share");
        require(distributor.MAX_CLAIM_DELAY_ROUNDS() == 1000, "max claim delay rounds");
    }

    function testConstructorShipsWithoutReentrancyGuardSemantics() external view {
        // 合约不继承 ReentrancyGuard：claim 走 CEI，重复领取由账本拦截
        require(distributor.isClaimedByTokenAddressByClaimer(address(firstToken), ALICE) == false, "fresh");
        require(distributor.remainingShareByTokenAddress(address(firstToken)) == TOTAL_SHARE, "full share");
        require(address(distributor).code.length != 0, "deployed");
    }

    // ============ 2. 首币在构造期完成配置 ============

    function testGenesisTokenIsConfiguredInConstructor() external view {
        require(distributor.merkleRootByTokenAddress(address(firstToken)) == GENESIS_ROOT, "genesis root");
        require(distributor.claimableFromRoundByTokenAddress(address(firstToken)) == 1, "genesis claimable round");
        require(distributor.claimedShareByTokenAddress(address(firstToken)) == 0, "no claimed share");
    }

    function testGenesisTokenConfiguresWithDelay() external {
        _deploySystemSpecifyingGenesisDelay(5);
        // Phase 尚未开始，baseRound 夹取为 1
        require(distributor.claimableFromRoundByTokenAddress(address(firstToken)) == 6, "gated by delay");
    }

    // ============ 3. 创世前夹取：currentPhase()==0 ============

    function testGenesisPendingPhaseClampsBaseRoundToOne() external view {
        require(phase.currentPhase() == 0, "phase not started");
        require(distributor.claimableFromRoundByTokenAddress(address(firstToken)) == 1, "base round clamped to 1");
    }

    function testClaimBeforeGenesisRevertsWithClaimRoundNotReached() external {
        bytes32[] memory proof = new bytes32[](0);
        _assertRevertSelector(
            ALICE,
            abi.encodeCall(IAirdropDistributor.claim, (address(firstToken), ALICE_SHARE, proof)),
            IAirdropDistributorErrors.ClaimRoundNotReached.selector
        );
    }

    // ============ 4. 普通发射走 Launch 回调 ============

    function testSubTokenLaunchViaCallbackConfiguresDistributor() external {
        bytes32 subRoot = keccak256("sub root");
        address subToken = _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(subRoot, 2));

        require(distributor.merkleRootByTokenAddress(subToken) == subRoot, "sub root");
        require(distributor.claimableFromRoundByTokenAddress(subToken) == 3, "base 1 + delay 2");
        require(distributor.claimedShareByTokenAddress(subToken) == 0, "no claimed share");
        require(distributor.merkleRootByTokenAddress(subToken) != GENESIS_ROOT, "distinct from genesis");
    }

    function testSubTokenLaunchDeliversSupplyToDistributor() external {
        address subToken = _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(keccak256("r"), 0));
        require(LOVE20Token(subToken).balanceOf(address(distributor)) == LAUNCH_AMOUNT, "sub supply held");
    }

    // ============ 5. 首币与子币互相隔离 ============

    function testGenesisAndSubTokenConfigurationsAreIsolated() external {
        bytes32 subRoot = keccak256("sub root");
        address subToken = _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(subRoot, 3));

        require(distributor.merkleRootByTokenAddress(address(firstToken)) == GENESIS_ROOT, "genesis root kept");
        require(distributor.merkleRootByTokenAddress(subToken) == subRoot, "sub root kept");
        require(distributor.claimableFromRoundByTokenAddress(address(firstToken)) == 1, "genesis round kept");
        require(distributor.claimableFromRoundByTokenAddress(subToken) == 4, "sub round kept");

        _rollToPhase(1);
        bytes32[] memory empty = new bytes32[](0);
        (bool ok, ) = _callAs(ALICE, abi.encodeCall(IAirdropDistributor.claim, (address(firstToken), 1e17, empty)));
        require(!ok, "genesis claim needs a proof");

        require(distributor.claimedShareByTokenAddress(address(firstToken)) == 0, "genesis untouched");
        require(distributor.claimedShareByTokenAddress(subToken) == 0, "sub untouched");
        require(distributor.remainingShareByTokenAddress(address(firstToken)) == TOTAL_SHARE, "genesis remaining");
        require(distributor.remainingShareByTokenAddress(subToken) == TOTAL_SHARE, "sub remaining");
    }

    // ============ 6. 领取成功 ============

    function testClaimPaysShareOfPoolAndRecordsLedger() external {
        _rollToPhase(1);

        bytes32[] memory leaves = _threeLeaves();
        bytes32 root = _merkleRoot(leaves);
        address subToken = _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(root, 0));

        uint256 share = ALICE_SHARE;
        bytes32[] memory proof = _merkleProof(leaves, 0);
        uint256 balanceBefore = LOVE20Token(subToken).balanceOf(address(distributor));

        _claimAs(ALICE, subToken, share, proof);

        uint256 expectedAmount = balanceBefore * share / TOTAL_SHARE;
        require(LOVE20Token(subToken).balanceOf(ALICE) == expectedAmount, "claimer paid");
        require(
            LOVE20Token(subToken).balanceOf(address(distributor)) == balanceBefore - expectedAmount,
            "distributor debited"
        );
        require(
            distributor.claimedAmountByTokenAddressByClaimer(subToken, ALICE) == expectedAmount, "amount ledger"
        );
        require(distributor.claimedShareByTokenAddress(subToken) == share, "share ledger");
        require(distributor.remainingShareByTokenAddress(subToken) == TOTAL_SHARE - share, "remaining ledger");
        require(distributor.isClaimedByTokenAddressByClaimer(subToken, ALICE), "claimed flag");
    }

    function testClaimReturnsAmountThroughLowLevelCall() external {
        _rollToPhase(1);

        bytes32[] memory leaves = _threeLeaves();
        bytes32 root = _merkleRoot(leaves);
        address subToken = _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(root, 0));

        uint256 share = ALICE_SHARE;
        (bool ok, bytes memory data) = _callAs(
            ALICE, abi.encodeCall(IAirdropDistributor.claim, (subToken, share, _merkleProof(leaves, 0)))
        );
        require(ok, "claim succeeded");
        uint256 amount = abi.decode(data, (uint256));
        require(amount == LAUNCH_AMOUNT * share / TOTAL_SHARE, "returned amount");
        require(amount == distributor.claimedAmountByTokenAddressByClaimer(subToken, ALICE), "matches ledger");
    }

    // ============ 7. 动态池：比例分配、末位清零 ============

    function testDynamicPoolPaysProportionallyAndLastClaimerDrainsBalance() external {
        _rollToPhase(1);

        // 份额 10% / 30% / 60%，按从小到大顺序领取
        bytes32[] memory leaves = _threeLeaves();
        bytes32 root = _merkleRoot(leaves);
        address subToken = _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(root, 0));
        LOVE20Token token = LOVE20Token(subToken);

        uint256 pool = token.balanceOf(address(distributor));
        require(pool == LAUNCH_AMOUNT, "pool funded");

        _claimAs(ALICE, subToken, ALICE_SHARE, _merkleProof(leaves, 0));
        uint256 aliceAmount = token.balanceOf(ALICE);

        _claimAs(BOB, subToken, BOB_SHARE, _merkleProof(leaves, 1));
        uint256 bobAmount = token.balanceOf(BOB);

        _claimAs(CAROL, subToken, CAROL_SHARE, _merkleProof(leaves, 2));
        uint256 carolAmount = token.balanceOf(CAROL);

        require(aliceAmount == 10 ether, "first claimer takes 10%");
        require(bobAmount == 30 ether, "second claimer takes 30%");
        require(carolAmount == 60 ether, "third claimer takes 60%");
        require(aliceAmount < bobAmount && bobAmount < carolAmount, "ascending payouts");
        require(aliceAmount + bobAmount + carolAmount == pool, "pool fully distributed");
        require(token.balanceOf(address(distributor)) == 0, "balance drained by the last claimer");
        require(distributor.remainingShareByTokenAddress(subToken) == 0, "share exhausted");
    }

    function testLaterClaimerBenefitFromPoolGrowth() external {
        _rollToPhase(1);

        bytes32[] memory leaves = _threeLeaves();
        address subToken =
            _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(_merkleRoot(leaves), 0));
        LOVE20Token token = LOVE20Token(subToken);

        _claimAs(ALICE, subToken, ALICE_SHARE, _merkleProof(leaves, 0));
        require(token.balanceOf(ALICE) == 10 ether, "first claimer takes 10% of the pool");
        require(token.balanceOf(address(distributor)) == 90 ether, "pool after first claim");

        // 外部注资后，后续领取者按实时余额结算，而非首次快照
        mintAccount.mintToken(subToken, address(distributor), 10 ether);
        uint256 poolBeforeBob = token.balanceOf(address(distributor));
        require(poolBeforeBob == 100 ether, "pool topped up");

        uint256 expectedBob = poolBeforeBob * BOB_SHARE / (TOTAL_SHARE - ALICE_SHARE);
        _claimAs(BOB, subToken, BOB_SHARE, _merkleProof(leaves, 1));
        require(token.balanceOf(BOB) == expectedBob, "second claimer follows live balance");
        require(expectedBob > token.balanceOf(ALICE), "late claimer earns more than the first");

        // 末位领取者拿走按份额算出的全部剩余，且分子分母相等时正好清零
        uint256 remainingShare = TOTAL_SHARE - ALICE_SHARE - BOB_SHARE;
        uint256 poolBeforeCarol = token.balanceOf(address(distributor));
        _claimAs(CAROL, subToken, CAROL_SHARE, _merkleProof(leaves, 2));
        require(remainingShare == CAROL_SHARE, "last leaf consumes the rest of the share");
        require(token.balanceOf(CAROL) == poolBeforeCarol, "last claimer drains the residual pool");
        require(token.balanceOf(address(distributor)) == 0, "pool drained");
        require(distributor.remainingShareByTokenAddress(subToken) == 0, "share exhausted");
    }

    // ============ 8. claimableAmount 与 claim 一致 ============

    function testClaimableAmountMatchesClaimReturnValue() external {
        _rollToPhase(1);

        bytes32[] memory leaves = _threeLeaves();
        bytes32 root = _merkleRoot(leaves);
        address subToken = _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(root, 0));

        uint256 share = BOB_SHARE;
        bytes32[] memory proof = _merkleProof(leaves, 1);
        uint256 quoted = distributor.claimableAmount(subToken, BOB, share, proof);

        (bool ok, bytes memory data) =
            _callAs(BOB, abi.encodeCall(IAirdropDistributor.claim, (subToken, share, proof)));
        require(ok, "claim succeeded");
        uint256 claimed = abi.decode(data, (uint256));

        require(quoted != 0, "quote non-zero");
        require(quoted == claimed, "quote matches claim");
    }

    function testClaimableAmountReturnsZeroForEveryFailingCondition() external {
        _rollToPhase(1);

        bytes32[] memory leaves = _threeLeaves();
        bytes32 root = _merkleRoot(leaves);
        address subToken = _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(root, 0));
        bytes32[] memory proof = _merkleProof(leaves, 0);

        require(distributor.claimableAmount(address(0xdead), ALICE, 1e17, proof) == 0, "unconfigured token");
        require(distributor.claimableAmount(subToken, ALICE, TOTAL_SHARE + 1, proof) == 0, "share above remaining");
        require(distributor.claimableAmount(subToken, ALICE, 0, proof) == 0, "zero share");
        require(distributor.claimableAmount(subToken, ALICE, ALICE_SHARE, new bytes32[](0)) == 0, "bad proof");
        require(distributor.claimableAmount(subToken, DAVE, ALICE_SHARE, proof) == 0, "wrong claimer leaf");

        _claimAs(ALICE, subToken, ALICE_SHARE, proof);
        require(distributor.claimableAmount(subToken, ALICE, ALICE_SHARE, proof) == 0, "already claimed");
    }

    // ============ 21./22. 延迟轮次语义 ============

    function testZeroDelayIsClaimableInTheSameRound() external {
        _rollToPhase(4);
        require(phase.currentPhase() == 4, "at round 4");

        bytes32[] memory leaves = _threeLeaves();
        address subToken =
            _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(_merkleRoot(leaves), 0));
        require(distributor.claimableFromRoundByTokenAddress(subToken) == 4, "same round");

        _claimAs(ALICE, subToken, ALICE_SHARE, _merkleProof(leaves, 0));
        require(distributor.isClaimedByTokenAddressByClaimer(subToken, ALICE), "claimed immediately");
    }

    function testOneRoundDelayBecomesClaimableOnlyInTheNextRound() external {
        _rollToPhase(4);

        bytes32[] memory leaves = _threeLeaves();
        address subToken =
            _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(_merkleRoot(leaves), 1));
        require(distributor.claimableFromRoundByTokenAddress(subToken) == 5, "next round");

        _assertRevertSelector(
            ALICE,
            abi.encodeCall(IAirdropDistributor.claim, (subToken, ALICE_SHARE, _merkleProof(leaves, 0))),
            IAirdropDistributorErrors.ClaimRoundNotReached.selector
        );

        _rollToPhase(5);
        _claimAs(ALICE, subToken, ALICE_SHARE, _merkleProof(leaves, 0));
        require(distributor.isClaimedByTokenAddressByClaimer(subToken, ALICE), "claimed next round");
    }

    function testGenesisPendingPhaseCannotClaimBeforeOriginAndPaysAfter() external {
        bytes32[] memory leaves = _threeLeaves();
        // 首币已用 GENESIS_ROOT 配置；此处构造一个延迟为 0 的子币以覆盖创世前夹取路径
        address subToken =
            _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(_merkleRoot(leaves), 0));
        require(phase.currentPhase() == 0, "still pre-genesis");
        require(distributor.claimableFromRoundByTokenAddress(subToken) == 1, "clamped to round 1");

        _assertRevertSelector(
            ALICE,
            abi.encodeCall(IAirdropDistributor.claim, (subToken, ALICE_SHARE, _merkleProof(leaves, 0))),
            IAirdropDistributorErrors.ClaimRoundNotReached.selector
        );

        _rollToPhase(1);
        _claimAs(ALICE, subToken, ALICE_SHARE, _merkleProof(leaves, 0));
        require(distributor.isClaimedByTokenAddressByClaimer(subToken, ALICE), "claimable at round 1");
    }

    // ============ 分页 airdropInfos ============

    function testAirdropInfosPaginationSemantics() external {
        _rollToPhase(1);
        address subTokenA = _launchSubToken(ALICE, aliceMemberId, "SUA", _distributorData(keccak256("a"), 0));
        address subTokenB = _launchSubToken(BOB, bobMemberId, "SUB", _distributorData(keccak256("b"), 1));

        // 首币 + 两个子币 = 3 条
        (AirdropInfo[] memory infos, uint256 totalCount) = distributor.airdropInfos(0, 10, false);
        require(totalCount == 3, "total count");
        require(infos.length == 3, "all rows");
        require(infos[0].tokenAddress == address(firstToken), "insertion order 0");
        require(infos[1].tokenAddress == subTokenA, "insertion order 1");
        require(infos[2].tokenAddress == subTokenB, "insertion order 2");

        (infos, totalCount) = distributor.airdropInfos(0, 10, true);
        require(totalCount == 3, "reverse total");
        require(infos[0].tokenAddress == subTokenB, "reverse 0");
        require(infos[2].tokenAddress == address(firstToken), "reverse 2");

        (infos, totalCount) = distributor.airdropInfos(5, 10, false);
        require(totalCount == 3, "out of range keeps total");
        require(infos.length == 0, "out of range is empty");

        (infos, totalCount) = distributor.airdropInfos(1, 1, false);
        require(totalCount == 3, "window total");
        require(infos.length == 1, "window size");
        require(infos[0].tokenAddress == subTokenA, "window row");

        (infos, totalCount) = distributor.airdropInfos(0, 0, false);
        require(totalCount == 3, "limit zero returns count only");
        require(infos.length == 0, "limit zero returns no rows");
    }

    function testAirdropInfosFillsEveryField() external {
        _rollToPhase(1);

        bytes32[] memory leaves = _threeLeaves();
        bytes32 root = _merkleRoot(leaves);
        address subToken = _launchSubToken(ALICE, aliceMemberId, "SUB", _distributorData(root, 2));
        _rollToPhase(3);
        _claimAs(ALICE, subToken, ALICE_SHARE, _merkleProof(leaves, 0));

        (AirdropInfo[] memory infos, ) = distributor.airdropInfos(0, 10, false);
        require(infos.length == 2, "genesis plus sub");

        AirdropInfo memory genesisInfo = infos[0];
        require(genesisInfo.tokenAddress == address(firstToken), "genesis address");
        require(genesisInfo.merkleRoot == GENESIS_ROOT, "genesis root");
        require(genesisInfo.claimableFromRound == 1, "genesis round");
        require(genesisInfo.claimedShare == 0, "genesis claimed share");
        require(genesisInfo.remainingShare == TOTAL_SHARE, "genesis remaining");
        require(genesisInfo.contractBalance == LAUNCH_AMOUNT, "genesis balance");

        AirdropInfo memory subInfo = infos[1];
        require(subInfo.tokenAddress == subToken, "sub address");
        require(subInfo.merkleRoot == root, "sub root");
        require(subInfo.claimableFromRound == 3, "sub round");
        require(subInfo.claimedShare == ALICE_SHARE, "sub claimed share");
        require(subInfo.remainingShare == TOTAL_SHARE - ALICE_SHARE, "sub remaining");
        require(subInfo.contractBalance == LAUNCH_AMOUNT - 10 ether, "sub balance");
    }

    // ============ Helpers ============

    /// 在既有系统之外重新部署一套，用于需要指定创世延迟的场景
    function _deploySystemSpecifyingGenesisDelay(uint256 genesisClaimDelayRounds) private {
        _deploySystem(GENESIS_ROOT, genesisClaimDelayRounds);
    }
}
