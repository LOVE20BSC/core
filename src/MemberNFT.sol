// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {ILOVE20Token} from "./interfaces/ILOVE20Token.sol";
import {IMemberNFT} from "./interfaces/IMemberNFT.sol";
import {ERC721} from "../lib/openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {
    ERC721Enumerable
} from "../lib/openzeppelin-contracts/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Pagination} from "../lib/libs/src/Pagination.sol";

/**
 * @title MemberNFT
 * @notice ERC721-based Member identity system for LOVE20 ecosystem
 */
contract MemberNFT is ERC721Enumerable, IMemberNFT {
    using Pagination for address[];
    // ============ Fixed Parameters ============

    address public LOVE20_TOKEN_ADDRESS;
    uint256 public immutable BASE_DIVISOR;
    uint256 public immutable BYTES_THRESHOLD;
    uint256 public immutable MULTIPLIER;
    uint256 public immutable MAX_NAME_LENGTH;

    // ============ State Variables ============

    bool public initialized;

    uint256 internal _nextTokenId = 1;

    uint256 public totalBurnedForMint;

    // id => name
    mapping(uint256 => string) internal _names;

    // normalizedName => id
    mapping(string => uint256) internal _normalizedNameToTokenId;

    // all holder addresses
    address[] internal _allHolders;

    // holderAddress => index in _allHolders array (0-based, only valid when balanceOf(holder) > 0)
    mapping(address => uint256) internal _holderIndex;

    // ============ Constructor ============

    /**
     * @param baseDivisor_ Base divisor for cost calculation (e.g., 1e8)
     * @param bytesThreshold_ Byte length threshold for cost multiplier (e.g., 7)
     * @param multiplier_ Multiplier for short names (e.g., 10)
     * @param maxNameLength_ Maximum name length in bytes (e.g., 32)
     */
    constructor(
        uint256 baseDivisor_,
        uint256 bytesThreshold_,
        uint256 multiplier_,
        uint256 maxNameLength_
    ) ERC721("LOVE20 Member NFT", "Member") {
        require(baseDivisor_ > 0 && bytesThreshold_ > 0 && multiplier_ > 0 && maxNameLength_ > 0);
        BASE_DIVISOR = baseDivisor_;
        BYTES_THRESHOLD = bytesThreshold_;
        MULTIPLIER = multiplier_;
        MAX_NAME_LENGTH = maxNameLength_;
    }

    function init(address firstTokenAddress) external {
        if (initialized) revert AlreadyInitialized();
        require(firstTokenAddress != address(0));
        LOVE20_TOKEN_ADDRESS = firstTokenAddress;
        initialized = true;
    }

    // ============ Member Functions ============

    /**
     * @notice Mint a new member identity with the given name
     * @dev Requires payment in LOVE20 tokens based on name length.
     *      Uses safeMint to ensure recipient can receive ERC721.
     * @param name The unique name for the member
     * @return id The newly minted token ID
     */
    function mint(
        string calldata name
    ) external returns (uint256 id, uint256 mintCost) {
        string memory name_ = _addTestPrefixIfNeeded(name);

        string memory normalizedName = _validateName(name_);

        mintCost = calculateMintCost(name_);
        id = _mintMember(msg.sender, name_, normalizedName, mintCost);
        return (id, mintCost);
    }

    function _mintMember(
        address memberOwner,
        string memory name,
        string memory normalizedName,
        uint256 mintCost
    ) internal returns (uint256 id) {
        id = _nextTokenId++;
        _names[id] = name;
        _normalizedNameToTokenId[normalizedName] = id;

        if (mintCost > 0) {
            totalBurnedForMint += mintCost;

            if (!IERC20(LOVE20_TOKEN_ADDRESS).transferFrom(memberOwner, address(this), mintCost)) {
                revert FeeTransferFailed();
            }
            ILOVE20Token(LOVE20_TOKEN_ADDRESS).burn(mintCost);
        }

        _safeMint(memberOwner, id);

        // Keep this event after _safeMint to preserve the established event order; failures revert atomically.
        // forge-lint: disable-next-item(reentrancy-events)
        emit Mint({
            id: id,
            owner: memberOwner,
            name: name,
            normalizedName: normalizedName,
            cost: mintCost
        });

        return id;
    }

    /**
     * @notice Calculate the cost to mint a member with the given name
     * @dev Uses the supplied name's byte length without adding a Test prefix.
     * @param name The member name to calculate cost for
     * @return The cost in LOVE20 tokens
     */
    function calculateMintCost(
        string memory name
    ) public view returns (uint256) {
        ILOVE20Token token = ILOVE20Token(LOVE20_TOKEN_ADDRESS);

        uint256 unmintedSupply = token.maxSupply() - token.totalSupply();

        uint256 baseCost = unmintedSupply / BASE_DIVISOR;

        uint256 byteLength = bytes(name).length;

        if (byteLength >= BYTES_THRESHOLD) {
            return baseCost;
        }

        uint256 difference = BYTES_THRESHOLD - byteLength;

        // forge-lint: disable-next-line(divide-before-multiply)
        return baseCost * (MULTIPLIER ** difference);
    }

    /**
     * @notice Get the member name for a token ID
     * @param id The token ID to query
     * @return The member name associated with the token ID (empty string if token doesn't exist)
     */
    function nameOf(
        uint256 id
    ) external view returns (string memory) {
        return _names[id];
    }

    /**
     * @notice Check if a member name is already used (case-insensitive)
     * @param name The member name to check
     * @return True if the member name is already used
     */
    function isNameUsed(
        string calldata name
    ) external view returns (bool) {
        return _normalizedNameToTokenId[_toLowerCase(name)] != 0;
    }

    /**
     * @notice Get token ID by member name (case-insensitive)
     * @param name The member name to query
     * @return The token ID associated with the member name (0 if not exists)
     */
    function idOf(
        string calldata name
    ) external view returns (uint256) {
        return _normalizedNameToTokenId[_toLowerCase(name)];
    }

    /**
     * @notice Get the normalized (lowercase) version of a member name
     * @param name The member name to normalize
     * @return The normalized member name with ASCII uppercase converted to lowercase
     */
    function normalizedNameOf(
        string calldata name
    ) external pure returns (string memory) {
        return _toLowerCase(name);
    }

    /**
     * @notice Get paginated list of holder addresses
     * @param offset Starting index in the holders array (0-based)
     * @param limit Maximum number of holders to return
     * @param reverse If true, iterate from the end (newest holders first)
     * @return holderList Array of holder addresses in the requested page
     * @return totalCount Total number of unique holders
     */
    function holders(uint256 offset, uint256 limit, bool reverse)
        external view returns (address[] memory holderList, uint256 totalCount)
    {
        return _allHolders.paginate(offset, limit, reverse);
    }

    // ============ Internal Functions ============

    /**
     * @dev Add "Test" prefix to member name if token symbol starts with "Test"
     *      and member name doesn't already start with "Test"
     * @param name The original member name
     * @return The member name with "Test" prefix added if needed
     */
    function _addTestPrefixIfNeeded(
        string memory name
    ) internal view returns (string memory) {
        bytes memory symbolBytes = bytes(ILOVE20Token(LOVE20_TOKEN_ADDRESS).symbol());
        if (
            symbolBytes.length >= 4 &&
            symbolBytes[0] == "T" &&
            symbolBytes[1] == "e" &&
            symbolBytes[2] == "s" &&
            symbolBytes[3] == "t"
        ) {
            bytes memory nameBytes = bytes(name);
            if (
                nameBytes.length < 4 ||
                nameBytes[0] != "T" ||
                nameBytes[1] != "e" ||
                nameBytes[2] != "s" ||
                nameBytes[3] != "t"
            ) {
                return string(abi.encodePacked("Test", name));
            }
        }
        return name;
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

    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal virtual override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (from == to) return from;

        if (from != address(0) && balanceOf(from) == 0) {
            _removeHolder(from);
        }
        if (to != address(0) && balanceOf(to) == 1) {
            _addHolder(to);
        }
        return from;
    }

    /**
     * @dev Validate member name and revert with specific error
     * @param name The member name to validate
     * @return normalizedName The ASCII-lowercased name, reused as the uniqueness mapping key
     */
    function _validateName(string memory name) internal view returns (string memory normalizedName) {
        bytes memory nameBytes = bytes(name);
        uint256 len = nameBytes.length;

        if (len == 0) revert NameEmpty();
        if (len > MAX_NAME_LENGTH)
            revert NameTooLong(len, MAX_NAME_LENGTH);
        if (!_isValidNameChars(nameBytes))
            revert NameInvalidCharacters();

        // Check uniqueness (case-insensitive)
        normalizedName = _toLowerCase(name);
        uint256 existingTokenId = _normalizedNameToTokenId[normalizedName];
        if (existingTokenId != 0) {
            revert NameAlreadyExists(existingTokenId);
        }
    }

    /**
     * @dev Validate member name characters and format
     * @param nameBytes The member name bytes to validate
     * @return bool True if the member name characters are valid
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
    function _isValidNameChars(
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
            // Gas-optimized: checks grouped by first byte
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

                // Gas-optimized: checks grouped by first byte

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
