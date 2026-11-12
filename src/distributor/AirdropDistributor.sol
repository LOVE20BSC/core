// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IAirdropDistributor, AirdropInfo} from "../interfaces/distributor/IAirdropDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IPhase} from "../interfaces/IPhase.sol";
import {ILaunch} from "../interfaces/ILaunch.sol";
import {IMemberNFT} from "../interfaces/IMemberNFT.sol";
import {Pagination} from "@libs/Pagination.sol";

contract AirdropDistributor is IAirdropDistributor {
    using SafeERC20 for IERC20;
    using Pagination for address[];

    uint256 public constant TOTAL_SHARE = 1e18;
    uint256 public constant MAX_CLAIM_DELAY_ROUNDS = 1000;
    uint256 public constant MAX_SNAPSHOT_URI_BYTES = 256;

    address public immutable LAUNCH_ADDRESS;
    address public immutable PHASE_ADDRESS;

    address[] internal _tokenAddresses;

    // tokenAddress => merkleRoot of the claimer/share tree
    mapping(address => bytes32) internal _merkleRootByTokenAddress;
    // tokenAddress => first round in which a claim is accepted
    mapping(address => uint256) internal _claimableFromRoundByTokenAddress;
    // tokenAddress => cumulative share consumed by successful claims
    mapping(address => uint256) internal _claimedShareByTokenAddress;
    // tokenAddress => cumulative token amount actually paid out by successful claims
    mapping(address => uint256) internal _totalClaimedAmountByTokenAddress;
    // tokenAddress => claimer => whether the claimer already claimed this token
    mapping(address => mapping(address => bool)) internal _isClaimedByTokenAddressByClaimer;
    // tokenAddress => claimer => amount actually paid out by the successful claim
    mapping(address => mapping(address => uint256)) internal _claimedAmountByTokenAddressByClaimer;
    // tokenAddress => discovery hint URL of the Merkle snapshot JSON (empty by default)
    mapping(address => string) internal _snapshotUriByTokenAddress;
    // tokenAddress => launcher memberId (0 = genesis, permanently non-updatable)
    mapping(address => uint256) internal _launcherMemberIdByTokenAddress;

    modifier onlyLaunch() {
        if (msg.sender != LAUNCH_ADDRESS) revert NotLaunchContract(msg.sender);
        _;
    }

    modifier onlySnapshotUriUpdater(address tokenAddress) {
        if (_merkleRootByTokenAddress[tokenAddress] == bytes32(0)) revert TokenNotConfigured(tokenAddress);
        uint256 launcherMemberId = _launcherMemberIdByTokenAddress[tokenAddress];
        if (launcherMemberId == 0) revert NotSnapshotUriUpdater(msg.sender, 0);
        address memberNFT = ILaunch(LAUNCH_ADDRESS).MEMBER_NFT_ADDRESS();
        if (IMemberNFT(memberNFT).ownerOf(launcherMemberId) != msg.sender) {
            revert NotSnapshotUriUpdater(msg.sender, launcherMemberId);
        }
        _;
    }

    // forge-lint: disable-next-item(missing-zero-check)
    constructor(
        address launchAddress,
        address phaseAddress,
        address genesisTokenAddress,
        bytes32 genesisMerkleRoot,
        uint256 genesisClaimDelayRounds
    ) {
        LAUNCH_ADDRESS = launchAddress;
        PHASE_ADDRESS = phaseAddress;

        _configure(genesisTokenAddress, genesisMerkleRoot, genesisClaimDelayRounds, 0);
    }

    function onTokenLaunched(
        address tokenAddress,
        address,
        uint256 launcherMemberId,
        bytes[] calldata distributorData
    ) external onlyLaunch {
        if (distributorData.length != 1) revert InvalidDistributorDataCount(distributorData.length, 1);
        if (distributorData[0].length != 64) revert InvalidDistributorDataLength(distributorData[0].length, 64);

        (bytes32 merkleRoot, uint256 claimDelayRounds) = abi.decode(distributorData[0], (bytes32, uint256));
        _configure(tokenAddress, merkleRoot, claimDelayRounds, launcherMemberId);
    }

    function claim(
        address tokenAddress,
        uint256 share,
        bytes32[] calldata proof
    ) external returns (uint256 amount) {
        address claimer = msg.sender;
        bytes32 merkleRoot = _merkleRootByTokenAddress[tokenAddress];
        if (merkleRoot == bytes32(0)) revert TokenNotConfigured(tokenAddress);

        uint256 currentRound = IPhase(PHASE_ADDRESS).currentPhase();
        uint256 claimableFromRound = _claimableFromRoundByTokenAddress[tokenAddress];
        if (currentRound < claimableFromRound) {
            revert ClaimRoundNotReached(tokenAddress, currentRound, claimableFromRound);
        }

        if (_isClaimedByTokenAddressByClaimer[tokenAddress][claimer]) {
            revert AirdropAlreadyClaimed(tokenAddress, claimer);
        }

        uint256 remaining = _remainingShare(tokenAddress);
        if (share == 0) revert InvalidProof();
        if (share > remaining) revert ShareExceedsRemaining(share, remaining);

        if (!MerkleProof.verifyCalldata(proof, merkleRoot, leafHash(claimer, share))) revert InvalidProof();

        amount = Math.mulDiv(IERC20(tokenAddress).balanceOf(address(this)), share, remaining);

        // forge-lint: disable-next-line(missing-events-access-control)
        _isClaimedByTokenAddressByClaimer[tokenAddress][claimer] = true;
        _claimedAmountByTokenAddressByClaimer[tokenAddress][claimer] = amount;
        _claimedShareByTokenAddress[tokenAddress] += share;
        _totalClaimedAmountByTokenAddress[tokenAddress] += amount;

        IERC20(tokenAddress).safeTransfer(claimer, amount);

        emit AirdropClaimed({
            tokenAddress: tokenAddress,
            claimer: claimer,
            share: share,
            amount: amount,
            remainingShare: remaining - share
        });
    }

    function updateSnapshotUri(address tokenAddress, string calldata snapshotUri)
        external
        onlySnapshotUriUpdater(tokenAddress)
    {
        uint256 length = bytes(snapshotUri).length;
        if (length == 0) revert SnapshotUriEmpty();
        if (length > MAX_SNAPSHOT_URI_BYTES) revert SnapshotUriTooLong(length, MAX_SNAPSHOT_URI_BYTES);
        string memory prevSnapshotUri = _snapshotUriByTokenAddress[tokenAddress];
        _snapshotUriByTokenAddress[tokenAddress] = snapshotUri;
        emit AirdropSnapshotUriUpdated({
            tokenAddress: tokenAddress,
            snapshotUri: snapshotUri,
            prevSnapshotUri: prevSnapshotUri
        });
    }

    function isClaimed(address tokenAddress, address claimer) external view returns (bool) {
        return _isClaimedByTokenAddressByClaimer[tokenAddress][claimer];
    }

    function claimedAmount(address tokenAddress, address claimer) external view returns (uint256) {
        return _claimedAmountByTokenAddressByClaimer[tokenAddress][claimer];
    }

    function _remainingShare(address tokenAddress) private view returns (uint256) {
        return TOTAL_SHARE - _claimedShareByTokenAddress[tokenAddress];
    }

    function airdropInfo(address tokenAddress) external view returns (AirdropInfo memory info) {
        info = _buildAirdropInfo(tokenAddress);
    }

    function _buildAirdropInfo(address tokenAddress) private view returns (AirdropInfo memory info) {
        if (_merkleRootByTokenAddress[tokenAddress] == bytes32(0)) return info;

        uint256 claimedShare = _claimedShareByTokenAddress[tokenAddress];
        // A configured token may not have been created yet (the genesis token is created by Launch,
        // which is deployed after this contract). Solidity reverts before try/catch when the target
        // has no code, so guard with extcodesize: balanceOf is a discovery read and a missing token
        // leaves remainingAmount at 0 instead of reverting the whole view.
        uint256 contractBalance = 0;
        if (tokenAddress.code.length != 0) {
            // forge-lint: disable-next-item(calls-loop)
            contractBalance = IERC20(tokenAddress).balanceOf(address(this));
        }

        info = AirdropInfo({
            tokenAddress: tokenAddress,
            merkleRoot: _merkleRootByTokenAddress[tokenAddress],
            claimableFromRound: _claimableFromRoundByTokenAddress[tokenAddress],
            totalClaimedShare: claimedShare,
            totalRemainingShare: TOTAL_SHARE - claimedShare,
            totalClaimedAmount: _totalClaimedAmountByTokenAddress[tokenAddress],
            remainingAmount: contractBalance,
            snapshotUri: _snapshotUriByTokenAddress[tokenAddress]
        });
    }

    function claimableAmount(
        address tokenAddress,
        address claimer,
        uint256 share,
        bytes32[] calldata proof
    ) external view returns (uint256 amount) {
        bytes32 merkleRoot = _merkleRootByTokenAddress[tokenAddress];
        if (merkleRoot == bytes32(0)) return 0;

        uint256 claimableFromRound = _claimableFromRoundByTokenAddress[tokenAddress];
        if (IPhase(PHASE_ADDRESS).currentPhase() < claimableFromRound) return 0;

        if (_isClaimedByTokenAddressByClaimer[tokenAddress][claimer]) return 0;

        uint256 remaining = _remainingShare(tokenAddress);
        if (share == 0 || share > remaining) return 0;

        if (!MerkleProof.verifyCalldata(proof, merkleRoot, leafHash(claimer, share))) return 0;

        return Math.mulDiv(IERC20(tokenAddress).balanceOf(address(this)), share, remaining);
    }

    function leafHash(address claimer, uint256 share) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(claimer, share))));
    }

    function airdropInfos(
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (AirdropInfo[] memory infos, uint256 totalCount) {
        address[] memory tokenAddressList;

        (tokenAddressList, totalCount) = _tokenAddresses.paginate(offset, limit, reverse);

        uint256 count = tokenAddressList.length;
        infos = new AirdropInfo[](count);
        for (uint256 i = 0; i < count; i++) {
            infos[i] = _buildAirdropInfo(tokenAddressList[i]);
        }
    }

    function _configure(
        address tokenAddress,
        bytes32 merkleRoot,
        uint256 claimDelayRounds,
        uint256 launcherMemberId
    ) internal {
        if (_merkleRootByTokenAddress[tokenAddress] != bytes32(0)) revert TokenAlreadyConfigured(tokenAddress);
        if (merkleRoot == bytes32(0)) revert ZeroMerkleRoot();
        if (claimDelayRounds > MAX_CLAIM_DELAY_ROUNDS) {
            revert ClaimDelayRoundsExceeded(claimDelayRounds, MAX_CLAIM_DELAY_ROUNDS);
        }

        uint256 currentRound = IPhase(PHASE_ADDRESS).currentPhase();
        uint256 baseRound = currentRound == 0 ? 1 : currentRound;
        uint256 claimableFromRound = baseRound + claimDelayRounds;

        _merkleRootByTokenAddress[tokenAddress] = merkleRoot;
        _claimableFromRoundByTokenAddress[tokenAddress] = claimableFromRound;
        _launcherMemberIdByTokenAddress[tokenAddress] = launcherMemberId;
        _tokenAddresses.push(tokenAddress);

        emit AirdropConfigured({
            tokenAddress: tokenAddress,
            merkleRoot: merkleRoot,
            claimableFromRound: claimableFromRound
        });
    }
}
