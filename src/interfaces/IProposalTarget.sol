// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

/// @notice Callbacks core invokes after a proposal state change. Implemented outside core.
/// @dev Core does not authenticate implementations. As the first check of every callback, the
///      implementation MUST require `msg.sender` to be `Submit` (create/submit callbacks) or
///      `Vote` (vote callback). Without it anyone can forge a notification and rewrite the
///      implementation's state (spec: `specs/core/01-common-rules.md`, 回调接口).
interface IProposalTarget {
    /// @notice Called by `Submit` once the proposal is created.
    /// @dev MUST first require `msg.sender == Submit`.
    function onProposalCreated(
        address tokenAddress,
        uint256 proposalId,
        bytes[] calldata targetData
    ) external;

    /// @notice Called by `Submit` once the proposal is submitted in the current round.
    /// @dev MUST first require `msg.sender == Submit`.
    function onProposalSubmitted(
        address tokenAddress,
        uint256 proposalId,
        uint256 submitterId,
        bytes[] calldata targetData
    ) external;

    /// @notice Called by `Vote` once this call's votes are recorded; `voteAmount` is the delta.
    /// @dev MUST first require `msg.sender == Vote`.
    function onProposalVoted(
        address tokenAddress,
        uint256 round,
        uint256 proposalId,
        uint256 voterId,
        uint256 voteAmount,
        bytes[] calldata targetData
    ) external;
}
