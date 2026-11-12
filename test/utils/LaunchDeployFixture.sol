// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Launch} from "../../src/Launch.sol";
import {LaunchInitParams, DistributorMode} from "../../src/interfaces/ILaunch.sol";
import {MemberNFT} from "../../src/MemberNFT.sol";
import {LOVE20Token} from "../../src/LOVE20Token.sol";
import {Phase} from "../../src/Phase.sol";
import {AirdropDistributor} from "../../src/distributor/AirdropDistributor.sol";
import {IAirdropDistributor, AirdropInfo} from "../../src/interfaces/distributor/IAirdropDistributor.sol";
import {ILOVE20Token} from "../../src/interfaces/ILOVE20Token.sol";

interface AirdropVm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function roll(uint256 blockNumber) external;
    function warp(uint256 timestamp) external;
    function prank(address sender) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
    function getNonce(address account) external view returns (uint256);
    function computeCreateAddress(address deployer, uint256 nonce) external view returns (address);
}

/// 根父币最小模拟：只提供 Launch 读取的 symbol()
contract AirdropRootTokenMock {
    function symbol() external pure returns (string memory) {
        return "ROOT";
    }
}

/// 最小 Pair Factory：提供 Launch 建池所需的两个入口
contract AirdropPairFactoryMock {
    mapping(address => mapping(address => address)) private _pairByTokens;

    function getPair(address tokenA, address tokenB) external view returns (address pair) {
        return _pairByTokens[tokenA][tokenB];
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        pair = address(uint160(uint256(keccak256(abi.encodePacked(tokenA, tokenB)))));
        _pairByTokens[tokenA][tokenB] = pair;
        _pairByTokens[tokenB][tokenA] = pair;
    }
}

/// 模拟 Mint：唯一被授权调用 addLaunchCount 的地址，同时可在 MAX_SUPPLY 内补铸
contract AirdropMintAccount {
    function addLaunchCount(Launch launch, address tokenAddress, uint256 memberId, uint256 count) external {
        launch.addLaunchCount(tokenAddress, memberId, count);
    }

    function mintToken(address tokenAddress, address to, uint256 amount) external {
        ILOVE20Token(tokenAddress).mint(to, amount);
    }
}

/// AirdropDistributor 测试的部署夹具。
/// 地址预测与部署脚本一致：首币地址 = computeCreateAddress(launchAddress, 1)。
abstract contract LaunchDeployFixture {
    AirdropVm internal constant vm = AirdropVm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant TOTAL_SHARE = 1e18;
    uint256 internal constant LAUNCH_AMOUNT = 100 ether;
    uint256 internal constant MAX_SUPPLY = 200 ether;
    uint256 internal constant TOKEN_SYMBOL_LENGTH = 3;
    uint256 internal constant LAUNCH_COUNT_THRESHOLD_RATIO = 1e16;
    uint256 internal constant MAX_LAUNCH_COUNT = 100;

    uint256 internal constant MEMBER_BASE_DIVISOR = 1e30;
    uint256 internal constant MEMBER_BYTES_THRESHOLD = 7;
    uint256 internal constant MEMBER_MULTIPLIER = 10;
    uint256 internal constant MEMBER_MAX_NAME_LENGTH = 32;

    uint256 internal constant PHASE_BLOCK_COUNT = 100;
    uint256 internal constant PHASE_TARGET_SECONDS = 86400;
    uint256 internal constant PHASE_ADJUST_THRESHOLD = 2e17;
    uint256 internal constant PHASE_OBSERVATION_LIMIT = 10;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    address internal constant DAVE = address(0xDA7E);
    address internal constant ROOT_TOKEN = address(0x6007);

    uint256 internal constant ALICE_SHARE = 1e17;
    uint256 internal constant BOB_SHARE = 3e17;
    uint256 internal constant CAROL_SHARE = 6e17;

    AirdropPairFactoryMock internal pairFactory;
    AirdropMintAccount internal mintAccount;
    Phase internal phase;
    AirdropDistributor internal distributor;
    Launch internal launch;
    MemberNFT internal memberNFT;
    LOVE20Token internal firstToken;

    uint256 internal phaseOriginBlocks;
    uint256 internal aliceMemberId;
    uint256 internal bobMemberId;
    uint256 internal carolMemberId;
    uint256 internal daveMemberId;

    /// 部署 Phase / AirdropDistributor / Launch / MemberNFT，并给四个成员铸身份与发射次数。
    /// Phase 的 ORIGIN_BLOCKS 固定在未来，因此部署后 currentPhase() == 0。
    function _deploySystem(bytes32 genesisMerkleRoot, uint256 genesisClaimDelayRounds) internal {
        phaseOriginBlocks = block.number + 1000;

        pairFactory = new AirdropPairFactoryMock();
        mintAccount = new AirdropMintAccount();
        phase = new Phase(
            phaseOriginBlocks,
            PHASE_BLOCK_COUNT,
            PHASE_TARGET_SECONDS,
            PHASE_ADJUST_THRESHOLD,
            PHASE_OBSERVATION_LIMIT
        );

        // 后续创建顺序：distributor (nonce+0) → Launch (nonce+1) → MemberNFT (nonce+2)
        uint256 nonce = vm.getNonce(address(this));
        address predictedLaunch = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedMemberNFT = vm.computeCreateAddress(address(this), nonce + 2);
        address predictedFirstToken = vm.computeCreateAddress(predictedLaunch, 1);

        distributor = new AirdropDistributor(
            predictedLaunch,
            address(phase),
            predictedFirstToken,
            genesisMerkleRoot,
            genesisClaimDelayRounds
        );

        launch = new Launch(
            LaunchInitParams({
                mintAddress: address(mintAccount),
                memberNFTAddress: predictedMemberNFT,
                rootParentTokenAddress: ROOT_TOKEN,
                pairFactoryAddress: address(pairFactory),
                distributor: address(distributor),
                launchCountThresholdRatio: LAUNCH_COUNT_THRESHOLD_RATIO,
                maxLaunchCount: MAX_LAUNCH_COUNT,
                tokenSymbolLength: TOKEN_SYMBOL_LENGTH,
                launchAmount: LAUNCH_AMOUNT,
                maxSupply: MAX_SUPPLY,
                name: "LOVE20",
                symbol: "LOVE"
            })
        );

        memberNFT = new MemberNFT(
            MEMBER_BASE_DIVISOR,
            MEMBER_BYTES_THRESHOLD,
            MEMBER_MULTIPLIER,
            MEMBER_MAX_NAME_LENGTH,
            launch.FIRST_TOKEN_ADDRESS()
        );

        require(address(launch) == predictedLaunch, "launch address prediction");
        require(address(memberNFT) == predictedMemberNFT, "member nft address prediction");
        require(launch.FIRST_TOKEN_ADDRESS() == predictedFirstToken, "first token address prediction");
        firstToken = LOVE20Token(predictedFirstToken);

        aliceMemberId = _mintMember(ALICE, "alice");
        bobMemberId = _mintMember(BOB, "bob");
        carolMemberId = _mintMember(CAROL, "carol");
        daveMemberId = _mintMember(DAVE, "dave");

        uint256 count = 10;
        mintAccount.addLaunchCount(launch, address(firstToken), aliceMemberId, count);
        mintAccount.addLaunchCount(launch, address(firstToken), bobMemberId, count);
        mintAccount.addLaunchCount(launch, address(firstToken), carolMemberId, count);
        mintAccount.addLaunchCount(launch, address(firstToken), daveMemberId, count);
    }

    function _mintMember(address memberOwner, string memory memberName) internal returns (uint256 memberId) {
        vm.prank(memberOwner);
        (memberId, ) = memberNFT.mint(memberName);
    }

    /// 以当前 NFT 持有人身份把 memberId 转给新持有人，用于验证权限实时读取 owner
    function _transferMember(address currentOwner, address newOwner, uint256 memberId) internal {
        vm.prank(currentOwner);
        memberNFT.transferFrom(currentOwner, newOwner, memberId);
    }

    /// 以成员身份发起一次回调模式的普通发射，返回新建子币地址
    function _launchSubToken(
        address launcher,
        uint256 memberId,
        string memory symbol,
        bytes[] memory distributorData
    ) internal returns (address tokenAddress) {
        vm.prank(launcher);
        return launch.launchToken(
            symbol, address(firstToken), memberId, address(distributor), DistributorMode.Callback, distributorData
        );
    }

    /// 把 (merkleRoot, claimDelayRounds) 打包成 Launch 回调要求的单条目数据
    function _distributorData(bytes32 merkleRoot, uint256 claimDelayRounds) internal pure returns (bytes[] memory) {
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encode(merkleRoot, claimDelayRounds);
        return data;
    }

    function _leaf(address claimer, uint256 share) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(claimer, share))));
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// 逐层两两配对；奇数个节点时末位与自身配对，保证每一层都被填满
    function _merkleRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            level = _nextLevel(level);
        }
        return level[0];
    }

    function _merkleProof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory proof) {
        bytes32[] memory level = leaves;
        uint256 idx = index;
        uint256 depth;
        uint256 length = level.length;
        while (length > 1) {
            depth += 1;
            length = (length + 1) / 2;
        }

        proof = new bytes32[](depth);
        uint256 cursor;
        while (level.length > 1) {
            uint256 sibling = idx ^ 1;
            proof[cursor] = sibling < level.length ? level[sibling] : level[idx];
            cursor += 1;
            level = _nextLevel(level);
            idx /= 2;
        }
    }

    /// ALICE / BOB / CAROL 三人、份额 10% / 30% / 60% 的标准三叶树
    function _threeLeaves() internal pure returns (bytes32[] memory leaves) {
        leaves = new bytes32[](3);
        leaves[0] = _leaf(ALICE, ALICE_SHARE);
        leaves[1] = _leaf(BOB, BOB_SHARE);
        leaves[2] = _leaf(CAROL, CAROL_SHARE);
    }

    function _nextLevel(bytes32[] memory level) private pure returns (bytes32[] memory next) {
        uint256 nextLength = (level.length + 1) / 2;
        next = new bytes32[](nextLength);
        for (uint256 i = 0; i < nextLength; i += 1) {
            uint256 left = 2 * i;
            uint256 right = 2 * i + 1;
            next[i] = _hashPair(level[left], right < level.length ? level[right] : level[left]);
        }
    }

    /// 当前 Phase 轮次推进到指定轮；轮次 0 表示保持创世前
    function _rollToPhase(uint256 phaseNumber) internal {
        if (phaseNumber == 0) return;
        vm.roll(phaseOriginBlocks + (phaseNumber - 1) * PHASE_BLOCK_COUNT);
    }

    function _claimAs(address claimer, address tokenAddress, uint256 share, bytes32[] memory proof) internal {
        vm.prank(claimer);
        distributor.claim(tokenAddress, share, proof);
    }

    /// 以指定调用者身份向 distributor 发低层调用，断言回滚数据逐字节等于期望
    function _expectRevert(address caller, bytes memory callData, bytes memory expectedRevertData) internal {
        vm.prank(caller);
        (bool ok, bytes memory data) = address(distributor).call(callData);
        require(!ok, "expected revert");
        require(keccak256(data) == keccak256(expectedRevertData), "revert data mismatch");
    }

    /// 以指定调用者身份向 distributor 发低层调用并返回原始数据
    function _callAs(address caller, bytes memory callData) internal returns (bool ok, bytes memory data) {
        vm.prank(caller);
        return address(distributor).call(callData);
    }

    function _assertRevertSelector(
        address caller,
        bytes memory callData,
        bytes4 expectedSelector
    ) internal {
        (bool ok, bytes memory data) = _callAs(caller, callData);
        require(!ok, "expected revert");
        require(_selector(data) == expectedSelector, "revert selector mismatch");
    }

    function _selector(bytes memory data) internal pure returns (bytes4 selector) {
        if (data.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(data, 32))
        }
    }
}
