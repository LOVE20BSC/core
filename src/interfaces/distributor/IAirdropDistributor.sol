// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {ILaunchDistributor} from "./ILaunchDistributor.sol";

struct AirdropInfo {
    address tokenAddress;
    bytes32 merkleRoot;
    uint256 claimableFromRound;
    uint256 totalClaimedShare;
    uint256 totalRemainingShare;
    uint256 totalClaimedAmount;
    uint256 remainingAmount;
    string snapshotUri;
}

interface IAirdropDistributorEvents {
    event AirdropConfigured(
        address indexed tokenAddress,
        bytes32 merkleRoot,
        uint256 claimableFromRound
    );
    event AirdropClaimed(
        address indexed tokenAddress,
        address indexed claimer,
        uint256 share,
        uint256 amount,
        uint256 remainingShare
    );
    event AirdropSnapshotUriUpdated(
        address indexed tokenAddress,
        string snapshotUri,
        string prevSnapshotUri
    );
}

interface IAirdropDistributorErrors {
    error NotLaunchContract(address caller);
    error InvalidDistributorDataCount(
        uint256 count,
        uint256 expectedCount
    );
    error InvalidDistributorDataLength(
        uint256 length,
        uint256 expectedLength
    );
    error TokenAlreadyConfigured(address tokenAddress);
    error ZeroMerkleRoot();
    error ClaimDelayRoundsExceeded(
        uint256 claimDelayRounds,
        uint256 maxClaimDelayRounds
    );
    error ClaimRoundNotReached(
        address tokenAddress,
        uint256 currentRound,
        uint256 claimableFromRound
    );
    error TokenNotConfigured(address tokenAddress);
    error AirdropAlreadyClaimed(
        address tokenAddress,
        address claimer
    );
    error ShareExceedsRemaining(
        uint256 share,
        uint256 remainingShare
    );
    error InvalidProof();
    error SnapshotUriEmpty();
    error SnapshotUriTooLong(
        uint256 length,
        uint256 maxLength
    );
    error NotSnapshotUriUpdater(
        address caller,
        uint256 launcherMemberId
    );
}

interface IAirdropDistributor is
    ILaunchDistributor,
    IAirdropDistributorEvents,
    IAirdropDistributorErrors
{
    function LAUNCH_ADDRESS() external view returns (address);
    function PHASE_ADDRESS() external view returns (address);
    function TOTAL_SHARE() external view returns (uint256);
    function MAX_CLAIM_DELAY_ROUNDS() external view returns (uint256);
    function MAX_SNAPSHOT_URI_BYTES() external view returns (uint256);

    function claim(
        address tokenAddress,
        uint256 share,
        bytes32[] calldata proof
    ) external returns (uint256 amount);

    function isClaimed(address tokenAddress, address claimer) external view returns (bool);
    function claimedAmount(address tokenAddress, address claimer) external view returns (uint256);
    function claimableAmount(
        address tokenAddress,
        address claimer,
        uint256 share,
        bytes32[] calldata proof
    ) external view returns (uint256 amount);
    function leafHash(address claimer, uint256 share) external pure returns (bytes32);
    function updateSnapshotUri(address tokenAddress, string calldata snapshotUri) external;
    function airdropInfo(address tokenAddress) external view returns (AirdropInfo memory info);
    function airdropInfos(
        uint256 offset,
        uint256 limit,
        bool reverse
    ) external view returns (AirdropInfo[] memory infos, uint256 totalCount);
}
