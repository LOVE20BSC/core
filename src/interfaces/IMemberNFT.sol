// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

interface ILOVE20GroupEvents {
    event Mint(
        uint256 indexed tokenId,
        address indexed owner,
        string groupName,
        string normalizedName,
        uint256 cost
    );

    event AddHolder(address indexed holder, uint256 totalHolders);

    event RemoveHolder(address indexed holder, uint256 totalHolders);
}

interface ILOVE20GroupErrors {
    error GroupNameAlreadyExists(uint256 existingTokenId);
    error GroupNameEmpty();
    error GroupNameTooLong(uint256 length, uint256 maxLength);
    error GroupNameInvalidCharacters();
    error HolderIndexOutOfBounds(uint256 length);
}

interface ILOVE20Group is ILOVE20GroupEvents, ILOVE20GroupErrors {
    function LOVE20_TOKEN_ADDRESS() external view returns (address);

    function BASE_DIVISOR() external view returns (uint256);

    function BYTES_THRESHOLD() external view returns (uint256);

    function MULTIPLIER() external view returns (uint256);

    function MAX_GROUP_NAME_LENGTH() external view returns (uint256);

    function mint(
        string calldata groupName
    ) external returns (uint256 tokenId, uint256 mintCost);

    function calculateMintCost(
        string memory groupName
    ) external view returns (uint256);

    function groupNameOf(uint256 tokenId) external view returns (string memory);

    function isGroupNameUsed(
        string calldata groupName
    ) external view returns (bool);

    function tokenIdOf(
        string calldata groupName
    ) external view returns (uint256);

    function normalizedNameOf(
        string calldata groupName
    ) external pure returns (string memory);

    function totalBurnedForMint() external view returns (uint256);

    /// @dev Deprecated: non-authoritative helper on deployed LOVE20Group.
    /// It may become stale after ERC721 self-transfers. Use Transfer events
    /// or totalSupply/tokenByIndex/ownerOf to rebuild reliable holder sets.
    function holdersCount() external view returns (uint256);

    /// @dev Deprecated: non-authoritative helper on deployed LOVE20Group.
    /// It may become stale after ERC721 self-transfers. Use Transfer events
    /// or totalSupply/tokenByIndex/ownerOf to rebuild reliable holder sets.
    function holdersAtIndex(uint256 index) external view returns (address);
}
