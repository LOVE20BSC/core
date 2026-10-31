// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {ILOVE20Token} from "./interfaces/ILOVE20Token.sol";
import {IMemberNFT} from "./interfaces/IMemberNFT.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {
    ERC721Enumerable
} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pagination} from "@libs/Pagination.sol";

contract MemberNFT is ERC721Enumerable, IMemberNFT {
    using Pagination for address[];
    using SafeERC20 for IERC20;

    address public LOVE20_TOKEN_ADDRESS;
    uint256 public immutable BASE_DIVISOR;
    uint256 public immutable BYTES_THRESHOLD;
    uint256 public immutable MULTIPLIER;
    uint256 public immutable MAX_NAME_LENGTH;

    bool public initialized;

    uint256 internal _nextTokenId = 1;

    uint256 public totalBurnedForMint;

    // id => name
    mapping(uint256 => string) internal _memberNameByTokenId;

    // normalizedName => id
    mapping(string => uint256) internal _tokenIdByNormalizedName;

    // all holder addresses
    address[] internal _allHolders;

    // holderAddress => index in _allHolders array (0-based, only valid when balanceOf(holder) > 0)
    mapping(address => uint256) internal _holderIndex;

    constructor(
        uint256 baseDivisor,
        uint256 bytesThreshold,
        uint256 multiplier,
        uint256 maxNameLength
    ) ERC721("LOVE20 Member NFT", "Member") {
        BASE_DIVISOR = baseDivisor;
        BYTES_THRESHOLD = bytesThreshold;
        MULTIPLIER = multiplier;
        MAX_NAME_LENGTH = maxNameLength;
    }

    // forge-lint: disable-next-item(missing-zero-check)
    function init(address firstTokenAddress) external {
        if (initialized) revert AlreadyInitialized();
        LOVE20_TOKEN_ADDRESS = firstTokenAddress;
        initialized = true;
    }

    function mint(
        string calldata name
    ) external returns (uint256 tokenId, uint256 mintCost) {
        string memory prefixedName = _addTestPrefixIfNeeded(name);

        string memory normalizedName = _validateName(prefixedName);

        mintCost = calculateMintCost(prefixedName);
        tokenId = _mintMember(msg.sender, prefixedName, normalizedName, mintCost);
        return (tokenId, mintCost);
    }

    function _mintMember(
        address memberOwner,
        string memory name,
        string memory normalizedName,
        uint256 mintCost
    ) internal returns (uint256 tokenId) {
        tokenId = _nextTokenId++;
        _memberNameByTokenId[tokenId] = name;
        _tokenIdByNormalizedName[normalizedName] = tokenId;

        if (mintCost > 0) {
            totalBurnedForMint += mintCost;

            IERC20(LOVE20_TOKEN_ADDRESS).safeTransferFrom(memberOwner, address(this), mintCost);
            ILOVE20Token(LOVE20_TOKEN_ADDRESS).burn(mintCost);
        }

        _safeMint(memberOwner, tokenId);

        // forge-lint: disable-next-item(reentrancy-events)
        emit MemberMinted({
            memberId: tokenId,
            owner: memberOwner,
            cost: mintCost,
            name: name,
            normalizedName: normalizedName
        });

        return tokenId;
    }

    function calculateMintCost(
        string memory name
    ) public view returns (uint256) {
        ILOVE20Token token = ILOVE20Token(LOVE20_TOKEN_ADDRESS);

        uint256 unmintedSupply = token.MAX_SUPPLY() - token.totalSupply();

        uint256 baseCost = unmintedSupply / BASE_DIVISOR;

        uint256 byteLength = bytes(name).length;

        if (byteLength >= BYTES_THRESHOLD) {
            return baseCost;
        }

        uint256 difference = BYTES_THRESHOLD - byteLength;

        // forge-lint: disable-next-line(divide-before-multiply)
        return baseCost * (MULTIPLIER ** difference);
    }

    function memberName(
        uint256 tokenId
    ) external view returns (string memory) {
        return _memberNameByTokenId[tokenId];
    }

    function isNameUsed(
        string calldata name
    ) external view returns (bool) {
        return _tokenIdByNormalizedName[_toLowerCase(name)] != 0;
    }

    function memberId(
        string calldata name
    ) external view returns (uint256) {
        return _tokenIdByNormalizedName[_toLowerCase(name)];
    }

    function normalizeName(
        string calldata name
    ) external pure returns (string memory) {
        return _toLowerCase(name);
    }

    function holders(uint256 offset, uint256 limit, bool reverse)
        external view returns (address[] memory holderList, uint256 totalCount)
    {
        return _allHolders.paginate(offset, limit, reverse);
    }

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
        if (len > MAX_NAME_LENGTH) revert NameTooLong(len, MAX_NAME_LENGTH);
        if (!_isValidNameChars(nameBytes)) revert NameInvalidCharacters();

        normalizedName = _toLowerCase(name);
        uint256 existingTokenId = _tokenIdByNormalizedName[normalizedName];
        if (existingTokenId != 0) {
            revert NameAlreadyExists(existingTokenId);
        }
    }

    function _isValidNameChars(
        bytes memory nameBytes
    ) internal pure returns (bool) {
        uint256 len = nameBytes.length;

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

            uint8 numBytes = 0;

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

            if (i + numBytes > len) {
                return false;
            }

            for (uint256 j = 1; j < numBytes; j++) {
                uint8 contByte = uint8(nameBytes[i + j]);

                // All continuation bytes must be in range 0x80-0xBF
                if (contByte < 0x80 || contByte > 0xBF) {
                    return false;
                }
            }

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

                if (byte1 == 0xF0 && byte2 < 0x90) {
                    // Overlong encoding
                    return false;
                }
                if (byte1 == 0xF4 && byte2 >= 0x90) {
                    // Code point > U+10FFFF
                    return false;
                }
            }

            i += numBytes;
        }

        return true;
    }

    function _toLowerCase(
        string memory str
    ) internal pure returns (string memory) {
        bytes memory bStr = bytes(str);
        bytes memory result = new bytes(bStr.length);
        for (uint256 i = 0; i < bStr.length; i++) {
            if (bStr[i] >= 0x41 && bStr[i] <= 0x5A) {
                result[i] = bytes1(uint8(bStr[i]) + 32);
            } else {
                result[i] = bStr[i];
            }
        }
        return string(result);
    }
}
