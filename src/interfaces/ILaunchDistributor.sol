// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

interface ILaunchDistributor {
    function onTokenLaunched(
        address tokenAddress,
        address parentTokenAddress,
        uint256 launcherMemberId,
        bytes32[] calldata keys,
        bytes[] calldata values
    ) external;
}
