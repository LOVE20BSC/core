// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";

interface IMemberNFTEvents {
    event MemberMinted(
        uint256 indexed memberId,
        address indexed owner,
        uint256 cost,
        string name,
        string normalizedName
    );
}

interface IMemberNFTErrors {
    error NameAlreadyExists(uint256 existingId);
    error AlreadyInitialized();
    error NameEmpty();
    error NameTooLong(uint256 length, uint256 maxLength);
    error NameInvalidCharacters();
}

interface IMemberNFT is
    IERC721Metadata,
    IERC721Enumerable,
    IMemberNFTEvents,
    IMemberNFTErrors
{
    function LOVE20_TOKEN_ADDRESS() external view returns (address);

    function BASE_DIVISOR() external view returns (uint256);

    function BYTES_THRESHOLD() external view returns (uint256);

    function MULTIPLIER() external view returns (uint256);

    function MAX_NAME_LENGTH() external view returns (uint256);

    function initialized() external view returns (bool);

    function init(address firstTokenAddress) external;

    function mint(
        string calldata name
    ) external returns (uint256 id, uint256 mintCost);

    function calculateMintCost(
        string calldata name
    ) external view returns (uint256);

    function nameOf(uint256 id) external view returns (string memory);

    function isNameUsed(
        string calldata name
    ) external view returns (bool);

    function idOf(
        string calldata name
    ) external view returns (uint256);

    function normalizedNameOf(
        string calldata name
    ) external pure returns (string memory);

    function totalBurnedForMint() external view returns (uint256);

    function holders(uint256 offset, uint256 limit, bool reverse)
        external view returns (address[] memory holderList, uint256 totalCount);
}
