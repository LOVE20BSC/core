// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IAirdropDistributor, AirdropInfo} from "../interfaces/distributor/IAirdropDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IPhase} from "../interfaces/IPhase.sol";
import {Pagination} from "@libs/Pagination.sol";

contract AirdropDistributor is IAirdropDistributor {
    using SafeERC20 for IERC20;
    using Pagination for address[];

    uint256 public constant TOTAL_SHARE = 1e18;
    uint256 public constant MAX_CLAIM_DELAY_ROUNDS = 1000;

    address public immutable LAUNCH_ADDRESS;
    address public immutable PHASE_ADDRESS;

    address[] internal _tokenAddresses;

    // tokenAddress => merkleRoot of the claimer/share tree
    mapping(address => bytes32) internal _merkleRootByTokenAddress;
    // tokenAddress => first round in which a claim is accepted
    mapping(address => uint256) internal _claimableFromRoundByTokenAddress;
    // tokenAddress => cumulative share consumed by successful claims
    mapping(address => uint256) internal _claimedShareByTokenAddress;
    // tokenAddress => claimer => whether the claimer already claimed this token
    mapping(address => mapping(address => bool)) internal _isClaimedByTokenAddressByClaimer;
    // tokenAddress => claimer => amount actually paid out by the successful claim
    mapping(address => mapping(address => uint256)) internal _claimedAmountByTokenAddressByClaimer;

    modifier onlyLaunch() {
        if (msg.sender != LAUNCH_ADDRESS) revert NotLaunchContract(msg.sender);
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

        _configure(genesisTokenAddress, genesisMerkleRoot, genesisClaimDelayRounds);
    }

    function onTokenLaunched(
        address tokenAddress,
        address,
        uint256,
        bytes[] calldata distributorData
    ) external onlyLaunch {
        if (distributorData.length != 1) revert InvalidDistributorDataCount(distributorData.length, 1);
        if (distributorData[0].length != 64) revert InvalidDistributorDataLength(distributorData[0].length, 64);

        (bytes32 merkleRoot, uint256 claimDelayRounds) = abi.decode(distributorData[0], (bytes32, uint256));
        _configure(tokenAddress, merkleRoot, claimDelayRounds);
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

        uint256 remaining = remainingShareByTokenAddress(tokenAddress);
        if (share == 0) revert InvalidProof();
        if (share > remaining) revert ShareExceedsRemaining(share, remaining);

        if (!MerkleProof.verifyCalldata(proof, merkleRoot, leafHash(claimer, share))) revert InvalidProof();

        amount = Math.mulDiv(IERC20(tokenAddress).balanceOf(address(this)), share, remaining);

        // forge-lint: disable-next-line(missing-events-access-control)
        _isClaimedByTokenAddressByClaimer[tokenAddress][claimer] = true;
        _claimedAmountByTokenAddressByClaimer[tokenAddress][claimer] = amount;
        _claimedShareByTokenAddress[tokenAddress] += share;

        IERC20(tokenAddress).safeTransfer(claimer, amount);

        emit AirdropClaimed({
            tokenAddress: tokenAddress,
            claimer: claimer,
            share: share,
            amount: amount,
            remainingShare: remaining - share
        });
    }

    function merkleRootByTokenAddress(address tokenAddress) external view returns (bytes32) {
        return _merkleRootByTokenAddress[tokenAddress];
    }

    function claimableFromRoundByTokenAddress(address tokenAddress) external view returns (uint256) {
        return _claimableFromRoundByTokenAddress[tokenAddress];
    }

    function claimedShareByTokenAddress(address tokenAddress) external view returns (uint256) {
        return _claimedShareByTokenAddress[tokenAddress];
    }

    function isClaimedByTokenAddressByClaimer(
        address tokenAddress,
        address claimer
    ) external view returns (bool) {
        return _isClaimedByTokenAddressByClaimer[tokenAddress][claimer];
    }

    function claimedAmountByTokenAddressByClaimer(
        address tokenAddress,
        address claimer
    ) external view returns (uint256) {
        return _claimedAmountByTokenAddressByClaimer[tokenAddress][claimer];
    }

    function remainingShareByTokenAddress(address tokenAddress) public view returns (uint256) {
        return TOTAL_SHARE - _claimedShareByTokenAddress[tokenAddress];
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

        uint256 remaining = remainingShareByTokenAddress(tokenAddress);
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
            address tokenAddress = tokenAddressList[i];
            uint256 claimedShare = _claimedShareByTokenAddress[tokenAddress];
            // forge-lint: disable-next-item(calls-loop)
            uint256 contractBalance = IERC20(tokenAddress).balanceOf(address(this));

            infos[i] = AirdropInfo({
                tokenAddress: tokenAddress,
                merkleRoot: _merkleRootByTokenAddress[tokenAddress],
                claimableFromRound: _claimableFromRoundByTokenAddress[tokenAddress],
                claimedShare: claimedShare,
                remainingShare: TOTAL_SHARE - claimedShare,
                contractBalance: contractBalance
            });
        }
    }

    function _configure(address tokenAddress, bytes32 merkleRoot, uint256 claimDelayRounds) internal {
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
        _tokenAddresses.push(tokenAddress);

        emit AirdropConfigured({
            tokenAddress: tokenAddress,
            merkleRoot: merkleRoot,
            claimableFromRound: claimableFromRound
        });
    }
}
