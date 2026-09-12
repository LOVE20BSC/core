// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {ILOVE20Group} from "./interfaces/ILOVE20Group.sol";
import {ILOVE20Token} from "./interfaces/ILOVE20Token.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {
    ERC721Enumerable
} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {
    SafeERC20,
    IERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title LOVE20Group
 * @notice ERC721-based Group system for LOVE20 ecosystem
 * @dev Each Group represents ownership of a group in the LOVE20 ecosystem
 */
contract LOVE20Group is ERC721Enumerable, ILOVE20Group {
    using SafeERC20 for IERC20;
    // ============ Immutable Parameters ============

    address public immutable LOVE20_TOKEN_ADDRESS;
    uint256 public immutable BASE_DIVISOR;
    uint256 public immutable BYTES_THRESHOLD;
    uint256 public immutable MULTIPLIER;
    uint256 public immutable MAX_GROUP_NAME_LENGTH;

    // ============ State Variables ============

    uint256 internal _nextTokenId = 1;

    uint256 public totalBurnedForMint;

    // tokenId => groupName
    mapping(uint256 => string) internal _groupNames;

    // normalizedName => tokenId
    mapping(string => uint256) internal _normalizedNameToTokenId;

    // all holder addresses
    address[] internal _allHolders;

    // holderAddress => index in _allHolders array (0-based, only valid when balanceOf(holder) > 0)
    mapping(address => uint256) internal _holderIndex;

    // ============ Constructor ============

    /**
     * @param love20Token_ Address of the LOVE20 token
     * @param baseDivisor_ Base divisor for cost calculation (e.g., 1e8)
     * @param bytesThreshold_ Byte length threshold for cost multiplier (e.g., 7)
     * @param multiplier_ Multiplier for short names (e.g., 10)
     * @param maxGroupNameLength_ Maximum group name length in bytes (e.g., 64)
     */
    constructor(
        address love20Token_,
        uint256 baseDivisor_,
        uint256 bytesThreshold_,
        uint256 multiplier_,
        uint256 maxGroupNameLength_
    ) ERC721("LOVE20 Group", "Group") {
        LOVE20_TOKEN_ADDRESS = love20Token_;
        BASE_DIVISOR = baseDivisor_;
        BYTES_THRESHOLD = bytesThreshold_;
        MULTIPLIER = multiplier_;
        MAX_GROUP_NAME_LENGTH = maxGroupNameLength_;
    }

    // ============ Group Functions ============

    /**
     * @notice Mint a new group with the given group name
     * @dev Requires payment in LOVE20 tokens based on name length.
     *      Uses safeMint to ensure recipient can receive ERC721.
     * @param groupName The unique name for the group
     * @return tokenId The newly minted token ID
     */
    function mint(
        string memory groupName
    ) external returns (uint256 tokenId, uint256 mintCost) {
        groupName = _addTestPrefixIfNeeded(groupName);

        _validateGroupName(groupName);

        mintCost = calculateMintCost(groupName);
        tokenId = _mintGroup(msg.sender, groupName, mintCost);
        return (tokenId, mintCost);
    }

    function _mintGroup(
        address groupOwner,
        string memory groupName,
        uint256 mintCost
    ) internal returns (uint256 tokenId) {
        // Use normalized (lowercase) name for storage
        string memory normalizedName = _toLowerCase(groupName);

        tokenId = _nextTokenId++;
        _groupNames[tokenId] = groupName;
        _normalizedNameToTokenId[normalizedName] = tokenId;

        if (mintCost > 0) {
            totalBurnedForMint += mintCost;

            IERC20 token = IERC20(LOVE20_TOKEN_ADDRESS);
            token.safeTransferFrom(groupOwner, address(this), mintCost);
            ILOVE20Token(LOVE20_TOKEN_ADDRESS).burn(mintCost);
        }

        _safeMint(groupOwner, tokenId);

        emit Mint({
            tokenId: tokenId,
            owner: groupOwner,
            groupName: groupName,
            normalizedName: normalizedName,
            cost: mintCost
        });

        return tokenId;
    }

    /**
     * @notice Calculate the cost to mint a group with the given group name
     * @dev Cost formula:
     *      Base cost = remaining unminted LOVE20 / 10^7
     *      For names with >= 7 bytes: cost = base cost
     *      For names with < 7 bytes: cost = base cost * (10 ^ (7 - byte_length))
     * @param groupName The group name to calculate cost for
     * @return The cost in LOVE20 tokens
     */
    function calculateMintCost(
        string memory groupName
    ) public view returns (uint256) {
        ILOVE20Token token = ILOVE20Token(LOVE20_TOKEN_ADDRESS);

        uint256 unmintedSupply = token.maxSupply() - token.totalSupply();

        uint256 baseCost = unmintedSupply / BASE_DIVISOR;

        uint256 byteLength = bytes(groupName).length;

        if (byteLength >= BYTES_THRESHOLD) {
            return baseCost;
        }

        uint256 difference = BYTES_THRESHOLD - byteLength;

        return baseCost * (MULTIPLIER ** difference);
    }

    /**
     * @notice Get the group name for a token ID
     * @param tokenId The token ID to query
     * @return The group name associated with the token ID (empty string if token doesn't exist)
     */
    function groupNameOf(
        uint256 tokenId
    ) external view returns (string memory) {
        return _groupNames[tokenId];
    }

    /**
     * @notice Check if a group name is already used (case-insensitive)
     * @param groupName The group name to check
     * @return True if the group name is already used
     */
    function isGroupNameUsed(
        string calldata groupName
    ) external view returns (bool) {
        return _normalizedNameToTokenId[_toLowerCase(groupName)] != 0;
    }

    /**
     * @notice Get token ID by group name (case-insensitive)
     * @param groupName The group name to query
     * @return The token ID associated with the group name (0 if not exists)
     */
    function tokenIdOf(
        string calldata groupName
    ) external view returns (uint256) {
        return _normalizedNameToTokenId[_toLowerCase(groupName)];
    }

    /**
     * @notice Get the normalized (lowercase) version of a group name
     * @param groupName The group name to normalize
     * @return The normalized group name with ASCII uppercase converted to lowercase
     */
    function normalizedNameOf(
        string calldata groupName
    ) external pure returns (string memory) {
        return _toLowerCase(groupName);
    }

    /**
     * @notice Get the total number of unique holders
     * @return The number of unique addresses that currently hold NFTs
     */
    function holdersCount() external view returns (uint256) {
        return _allHolders.length;
    }

    /**
     * @notice Get the holder address at the given index
     * @param index The index in the holders array (0-based)
     * @return The holder address at the given index
     */
    function holdersAtIndex(uint256 index) external view returns (address) {
        if (index >= _allHolders.length) {
            revert HolderIndexOutOfBounds(_allHolders.length);
        }
        return _allHolders[index];
    }

    // ============ Internal Functions ============

    /**
     * @dev Add "Test" prefix to group name if token symbol starts with "Test"
     *      and group name doesn't already start with "Test"
     * @param groupName The original group name
     * @return The group name with "Test" prefix added if needed
     */
    function _addTestPrefixIfNeeded(
        string memory groupName
    ) internal view returns (string memory) {
        bytes4 prefix = bytes4(
            bytes(ILOVE20Token(LOVE20_TOKEN_ADDRESS).symbol())
        );
        if (prefix == bytes4("Test")) {
            bytes memory nameBytes = bytes(groupName);
            if (
                nameBytes.length < 4 ||
                nameBytes[0] != "T" ||
                nameBytes[1] != "e" ||
                nameBytes[2] != "s" ||
                nameBytes[3] != "t"
            ) {
                return string(abi.encodePacked("Test", groupName));
            }
        }
        return groupName;
    }

    /**
     * @dev Add a holder to the holders array if not already present
     * @param holder The address to add
     */
    function _addHolder(address holder) internal {
        uint256 index = _allHolders.length;
        _allHolders.push(holder);
        _holderIndex[holder] = index; // 0-based index

        emit AddHolder({holder: holder, totalHolders: _allHolders.length});
    }

    /**
     * @dev Remove a holder from the holders array using swap-and-pop
     * @param holder The address to remove
     */
    function _removeHolder(address holder) internal {
        uint256 index = _holderIndex[holder];
        uint256 lastIndex = _allHolders.length - 1;

        if (index != lastIndex) {
            address lastHolder = _allHolders[lastIndex];
            _allHolders[index] = lastHolder;
            _holderIndex[lastHolder] = index;
        }
        _allHolders.pop();
        delete _holderIndex[holder];

        emit RemoveHolder({holder: holder, totalHolders: _allHolders.length});
    }

    /**
     * @dev Hook that is called before any token transfer
     * @param from Address transferring the token (address(0) for mint)
     * @param to Address receiving the token (address(0) for burn)
     * @param firstTokenId The token ID being transferred
     * @param batchSize The number of tokens being transferred (always 1 for this contract)
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 firstTokenId,
        uint256 batchSize
    ) internal virtual override {
        uint256 fromBalanceBefore = from != address(0) ? balanceOf(from) : 0;
        uint256 toBalanceBefore = to != address(0) ? balanceOf(to) : 0;

        super._beforeTokenTransfer(from, to, firstTokenId, batchSize);

        if (from == address(0)) {
            // Mint
            if (toBalanceBefore == 0 && to != address(0)) {
                _addHolder(to);
            }
        } else if (to == address(0)) {
            // Burn
            if (fromBalanceBefore == 1) {
                _removeHolder(from);
            }
        } else {
            // Transfer
            if (fromBalanceBefore == 1) {
                _removeHolder(from);
            }
            if (toBalanceBefore == 0) {
                _addHolder(to);
            }
        }
    }

    /**
     * @dev Validate group name and revert with specific error
     * @param groupName The group name to validate
     */
    function _validateGroupName(string memory groupName) internal view {
        bytes memory nameBytes = bytes(groupName);
        uint256 len = nameBytes.length;

        if (len == 0) revert GroupNameEmpty();
        if (len > MAX_GROUP_NAME_LENGTH)
            revert GroupNameTooLong(len, MAX_GROUP_NAME_LENGTH);
        if (!_isValidGroupNameChars(nameBytes))
            revert GroupNameInvalidCharacters();

        // Check uniqueness (case-insensitive)
        string memory normalizedName = _toLowerCase(groupName);
        uint256 existingTokenId = _normalizedNameToTokenId[normalizedName];
        if (existingTokenId != 0) {
            revert GroupNameAlreadyExists(existingTokenId);
        }
    }

    /**
     * @dev Validate group name characters and format
     * @param nameBytes The group name bytes to validate
     * @return bool True if the group name characters are valid
     *
     * Validation rules:
     * - Must be valid UTF-8 encoding
     * - No ASCII whitespace (0x20) or control characters (0x00-0x1F, 0x7F)
     * - No Unicode whitespace characters (U+00A0, U+1680, U+2000-U+200A, U+202F, U+205F, U+3000)
     * - No zero-width characters (U+200B-U+200F, U+034F, U+FEFF, U+2060, U+00AD)
     * - No line/paragraph separators (U+2028, U+2029)
     * - No directional formatting (U+061C, U+202A-U+202E, U+2066-U+2069)
     * - No invisible mathematical operators (U+2061-U+2064)
     * - No deprecated format characters (U+206A-U+206F)
     * - Supports UTF-8 encoded characters including Unicode
     *
     * Note: We check byte length, not character count. A single Unicode
     * character may use multiple bytes in UTF-8 encoding.
     */
    function _isValidGroupNameChars(
        bytes memory nameBytes
    ) internal pure returns (bool) {
        uint256 len = nameBytes.length;

        // Validate UTF-8 encoding and check for invalid characters
        uint256 i = 0;
        while (i < len) {
            uint8 byteValue = uint8(nameBytes[i]);

            // Reject C0 control characters (0x00-0x1F) and space (0x20)
            if (byteValue <= 0x20) {
                return false;
            }

            // Reject DEL character (0x7F)
            if (byteValue == 0x7F) {
                return false;
            }

            // ASCII range (0x21-0x7E): valid single-byte character
            if (byteValue < 0x80) {
                i++;
                continue;
            }

            // Multi-byte UTF-8 sequence validation
            uint8 numBytes = 0;

            // Determine expected sequence length based on first byte
            if (byteValue >= 0xC2 && byteValue <= 0xDF) {
                // 2-byte sequence: 110xxxxx 10xxxxxx
                numBytes = 2;
            } else if (byteValue >= 0xE0 && byteValue <= 0xEF) {
                // 3-byte sequence: 1110xxxx 10xxxxxx 10xxxxxx
                numBytes = 3;
            } else if (byteValue >= 0xF0 && byteValue <= 0xF4) {
                // 4-byte sequence: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
                numBytes = 4;
            } else {
                // Invalid UTF-8 start byte (0x80-0xC1, 0xF5-0xFF)
                return false;
            }

            // Check if there are enough remaining bytes
            if (i + numBytes > len) {
                return false;
            }

            // Validate continuation bytes and check for forbidden sequences
            for (uint256 j = 1; j < numBytes; j++) {
                uint8 contByte = uint8(nameBytes[i + j]);

                // All continuation bytes must be in range 0x80-0xBF
                if (contByte < 0x80 || contByte > 0xBF) {
                    return false;
                }
            }

            // Now check for forbidden Unicode characters
            // Gas-optimized: Group checks by first byte to reduce redundant comparisons
            if (numBytes == 2) {
                uint8 byte1 = uint8(nameBytes[i]);
                uint8 byte2 = uint8(nameBytes[i + 1]);

                if (byte1 == 0xC2) {
                    // C1 control characters (U+0080-U+009F): 0x80-0x9F
                    // U+00A0 (No-Break Space): 0xA0
                    // U+00AD (Soft Hyphen): 0xAD
                    if (
                        (byte2 >= 0x80 && byte2 <= 0x9F) ||
                        byte2 == 0xA0 ||
                        byte2 == 0xAD
                    ) {
                        return false;
                    }
                } else if (byte1 == 0xCD) {
                    // U+034F (Combining Grapheme Joiner): 0xCD 0x8F
                    if (byte2 == 0x8F) {
                        return false;
                    }
                } else if (byte1 == 0xD8) {
                    // U+061C (Arabic Letter Mark): 0xD8 0x9C
                    if (byte2 == 0x9C) {
                        return false;
                    }
                }
            }

            if (numBytes == 3) {
                uint8 byte1 = uint8(nameBytes[i]);
                uint8 byte2 = uint8(nameBytes[i + 1]);
                uint8 byte3 = uint8(nameBytes[i + 2]);

                // Gas-optimized: Group checks by first byte to reduce redundant comparisons

                if (byte1 == 0xE1) {
                    // Check for U+1680 (Ogham Space Mark): 0xE1 0x9A 0x80
                    if (byte2 == 0x9A && byte3 == 0x80) {
                        return false;
                    }
                } else if (byte1 == 0xE2) {
                    // All U+2xxx forbidden characters start with 0xE2
                    if (byte2 == 0x80) {
                        // U+2000-U+200F (spaces, zero-width chars): 0x80-0x8F
                        // U+2028-U+202F (separators, bidi, NNBSP): 0xA8-0xAF
                        if (
                            (byte3 >= 0x80 && byte3 <= 0x8F) ||
                            (byte3 >= 0xA8 && byte3 <= 0xAF)
                        ) {
                            return false;
                        }
                    } else if (byte2 == 0x81) {
                        // U+205F (Medium Math Space): 0x9F
                        // U+2060-U+2064 (Word Joiner, Invisible Math Ops): 0xA0-0xA4
                        // U+2066-U+2069 (Bidi Isolates): 0xA6-0xA9
                        // U+206A-U+206F (Deprecated Format Chars): 0xAA-0xAF
                        if (
                            byte3 == 0x9F ||
                            (byte3 >= 0xA0 && byte3 <= 0xA4) ||
                            (byte3 >= 0xA6 && byte3 <= 0xAF)
                        ) {
                            return false;
                        }
                    }
                } else if (byte1 == 0xE3) {
                    // Check for U+3000 (Ideographic Space): 0xE3 0x80 0x80
                    if (byte2 == 0x80 && byte3 == 0x80) {
                        return false;
                    }
                } else if (byte1 == 0xEF) {
                    // Check for U+FEFF (BOM): 0xEF 0xBB 0xBF
                    if (byte2 == 0xBB && byte3 == 0xBF) {
                        return false;
                    }
                } else if (byte1 == 0xE0) {
                    // Reject overlong encodings
                    if (byte2 < 0xA0) {
                        return false;
                    }
                } else if (byte1 == 0xED) {
                    // Reject UTF-16 surrogates (U+D800-U+DFFF)
                    if (byte2 >= 0xA0) {
                        return false;
                    }
                }
            }

            if (numBytes == 4) {
                uint8 byte1 = uint8(nameBytes[i]);
                uint8 byte2 = uint8(nameBytes[i + 1]);

                // Additional validation for 4-byte sequences
                // Reject overlong encodings and code points > U+10FFFF
                if (byte1 == 0xF0 && byte2 < 0x90) {
                    // Overlong encoding
                    return false;
                }
                if (byte1 == 0xF4 && byte2 >= 0x90) {
                    // Code point > U+10FFFF
                    return false;
                }
            }

            // Move to next character
            i += numBytes;
        }

        return true;
    }

    /**
     * @dev Convert ASCII uppercase letters (A-Z) to lowercase (a-z)
     * @param str The string to convert
     * @return A new string with uppercase letters converted to lowercase
     * @notice Only converts ASCII letters (0x41-0x5A). Unicode characters
     *         (e.g., German ß, Turkish İ, etc.) are NOT converted due to
     *         complexity of Unicode case mapping rules.
     */
    function _toLowerCase(
        string memory str
    ) internal pure returns (string memory) {
        bytes memory bStr = bytes(str);
        bytes memory result = new bytes(bStr.length);
        for (uint256 i = 0; i < bStr.length; i++) {
            // ASCII A-Z: 0x41-0x5A -> a-z: 0x61-0x7A
            if (bStr[i] >= 0x41 && bStr[i] <= 0x5A) {
                result[i] = bytes1(uint8(bStr[i]) + 32);
            } else {
                result[i] = bStr[i];
            }
        }
        return string(result);
    }
}
