// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {ILaunch, DistributorMode, LaunchInitParams} from "./interfaces/ILaunch.sol";
import {ILaunchDistributor} from "./interfaces/ILaunchDistributor.sol";
import {ILOVE20Token} from "./interfaces/ILOVE20Token.sol";
import {IMemberNFT} from "./interfaces/IMemberNFT.sol";
import {IUniswapV2Factory} from "./interfaces/UniswapV2/IUniswapV2Factory.sol";
import {LOVE20Token} from "./LOVE20Token.sol";
import {Pagination} from "@libs/Pagination.sol";

contract Launch is ILaunch {
    using Pagination for address[];

    address public MINT_ADDRESS;
    address public MEMBER_NFT_ADDRESS;
    address public ROOT_PARENT_TOKEN_ADDRESS;
    address public FIRST_TOKEN_ADDRESS;
    address public PAIR_FACTORY_ADDRESS;

    uint256 public TOKEN_SYMBOL_LENGTH;
    uint256 public LAUNCH_RATIO;
    uint256 public MAX_LAUNCH_COUNT;
    uint256 public LAUNCH_AMOUNT;
    uint256 public MAX_SUPPLY;
    uint256 public constant MAX_TOKEN_SYMBOL_LENGTH = 32;
    uint256 public constant MAX_TOKEN_NAME_LENGTH = 96;
    bool public initialized;

    modifier onlyMint() {
        if (msg.sender != MINT_ADDRESS) revert NotMintContract(msg.sender);
        _;
    }

    modifier onlyMemberOwner(uint256 memberId) {
        if (_ownerOf(memberId) != msg.sender) revert NotMemberOwner(memberId);
        _;
    }

    // creation-ordered list of every launched token, the first token included
    address[] internal _tokens;
    // tokenAddress => parent token address; the zero address means Launch did not create the token
    mapping(address => address) internal _parentTokenByTokenAddress;
    // symbol => token address; symbols are unique and the first token is registered too
    mapping(string => address) internal _tokenAddressBySymbol;
    // parentTokenAddress => creation-ordered children
    mapping(address => address[]) internal _childTokens;

    // tokenAddress => memberId => available integer launch count
    mapping(address => mapping(uint256 => uint256)) internal _remainingLaunchCount;
    // tokenAddress => issued launch count; consumption and merging do not decrease it
    mapping(address => uint256) internal _issuedLaunchCount;

    function init(LaunchInitParams calldata params) external {
        if (initialized) revert AlreadyInitialized();

        initialized = true;
        MINT_ADDRESS = params.mintAddress;
        MEMBER_NFT_ADDRESS = params.memberNFTAddress;
        ROOT_PARENT_TOKEN_ADDRESS = params.rootParentTokenAddress;
        PAIR_FACTORY_ADDRESS = params.pairFactoryAddress;
        LAUNCH_RATIO = params.launchRatio;
        MAX_LAUNCH_COUNT = params.maxLaunchCount;
        TOKEN_SYMBOL_LENGTH = params.tokenSymbolLength;
        LAUNCH_AMOUNT = params.launchAmount;
        MAX_SUPPLY = params.maxSupply;

        address firstToken = _createToken(params.rootParentTokenAddress, params.name, params.symbol, params.distributor);
        FIRST_TOKEN_ADDRESS = firstToken;
        _tokens.push(firstToken);
        _parentTokenByTokenAddress[firstToken] = params.rootParentTokenAddress;
        _tokenAddressBySymbol[params.symbol] = firstToken;
        _childTokens[params.rootParentTokenAddress].push(firstToken);

        IMemberNFT(params.memberNFTAddress).init(firstToken);

        // forge-lint: disable-next-item(reentrancy-events)
        emit GenesisTokenCreated({
            tokenAddress: firstToken,
            parentTokenAddress: params.rootParentTokenAddress,
            distributor: params.distributor,
            name: params.name,
            symbol: params.symbol
        });
    }

    function isLOVE20Token(address tokenAddress) public view returns (bool) {
        return _parentTokenByTokenAddress[tokenAddress] != address(0);
    }

    function launchToken(
        string calldata tokenSymbol,
        address parentTokenAddress,
        uint256 memberId,
        address distributor,
        DistributorMode distributorMode,
        bytes[] calldata distributorData
    ) external onlyMemberOwner(memberId) returns (address tokenAddress) {
        _checkValidTokenSymbol(tokenSymbol);
        if (distributor == address(0)) revert ZeroDistributorAddress();
        _checkDistributorMode(distributorMode, distributor);

        if (parentTokenAddress != ROOT_PARENT_TOKEN_ADDRESS && !isLOVE20Token(parentTokenAddress)) {
            revert ParentTokenNotRegistered(parentTokenAddress);
        }

        uint256 availableCount = _remainingLaunchCount[parentTokenAddress][memberId];
        if (availableCount == 0) revert InsufficientLaunchCount(memberId, availableCount, 1);

        {
            uint256 remainingCount = availableCount - 1;
            _remainingLaunchCount[parentTokenAddress][memberId] = remainingCount;

            emit LaunchCountConsumed({
                tokenAddress: parentTokenAddress,
                memberId: memberId,
                remaining: remainingCount
            });
        }

        // Mainnet test support: a parent symbol starting with "Test" prefixes the sub-token symbol; a
        // root-level launch reads the first token instead, since the root parent symbol is shared across
        // networks. The prefix is applied after the symbol check, so the actual symbol may exceed the length.
        string memory parentTokenSymbol = ILOVE20Token(parentTokenAddress).symbol();
        string memory prefixSourceSymbol = parentTokenAddress == ROOT_PARENT_TOKEN_ADDRESS
            ? ILOVE20Token(FIRST_TOKEN_ADDRESS).symbol()
            : parentTokenSymbol;
        string memory subTokenSymbol = _addTestPrefixIfNeeded(tokenSymbol, prefixSourceSymbol);
        if (_tokenAddressBySymbol[subTokenSymbol] != address(0)) {
            revert TokenSymbolAlreadyExists(keccak256(bytes(subTokenSymbol)));
        }
        string memory tokenName = string.concat(subTokenSymbol, "@", parentTokenSymbol);

        // Registration must follow creation because the token address is only known afterwards; a
        // reentrant call cannot observe an inconsistent registry, and the registry is complete before
        // the distributor callback runs.
        // forge-lint: disable-next-item(reentrancy-no-eth)
        tokenAddress = _createToken(parentTokenAddress, tokenName, subTokenSymbol, distributor);
        _tokens.push(tokenAddress);
        _parentTokenByTokenAddress[tokenAddress] = parentTokenAddress;
        _tokenAddressBySymbol[subTokenSymbol] = tokenAddress;
        _childTokens[parentTokenAddress].push(tokenAddress);

        // forge-lint: disable-next-item(reentrancy-events)
        emit TokenLaunched({
            tokenAddress: tokenAddress,
            parentTokenAddress: parentTokenAddress,
            launcherMemberId: memberId,
            distributor: distributor,
            distributorMode: distributorMode,
            name: tokenName,
            symbol: subTokenSymbol
        });

        if (distributorMode == DistributorMode.Callback) {
            ILaunchDistributor(distributor).onTokenLaunched(tokenAddress, parentTokenAddress, memberId, distributorData);
        }
    }

    function mergeLaunchCount(address tokenAddress, uint256 sourceMemberId, uint256 targetMemberId, uint256 count)
        external
        onlyMemberOwner(sourceMemberId)
    {
        if (sourceMemberId == targetMemberId) {
            revert SourceAndTargetMemberIdsMustBeDifferent(sourceMemberId, targetMemberId);
        }
        if (count == 0) revert ZeroCount();

        if (tokenAddress != ROOT_PARENT_TOKEN_ADDRESS && !isLOVE20Token(tokenAddress)) {
            revert TokenNotRegistered(tokenAddress);
        }

        _ownerOf(targetMemberId);

        uint256 sourceCount = _remainingLaunchCount[tokenAddress][sourceMemberId];
        if (sourceCount < count) revert InsufficientLaunchCount(sourceMemberId, sourceCount, count);

        uint256 sourceRemaining = sourceCount - count;
        uint256 targetRemaining = _remainingLaunchCount[tokenAddress][targetMemberId] + count;
        _remainingLaunchCount[tokenAddress][sourceMemberId] = sourceRemaining;
        _remainingLaunchCount[tokenAddress][targetMemberId] = targetRemaining;

        emit LaunchCountMerged({
            tokenAddress: tokenAddress,
            sourceMemberId: sourceMemberId,
            targetMemberId: targetMemberId,
            count: count,
            sourceRemaining: sourceRemaining,
            targetRemaining: targetRemaining
        });
    }

    function addLaunchCount(address tokenAddress, uint256 memberId, uint256 count)
        external
        onlyMint
    {
        if (count == 0) revert ZeroCount();
        if (!isLOVE20Token(tokenAddress)) revert TokenNotRegistered(tokenAddress);

        uint256 issuedCount = _issuedLaunchCount[tokenAddress];
        if (count > MAX_LAUNCH_COUNT - issuedCount) {
            revert LaunchCountLimitExceeded(tokenAddress, count, MAX_LAUNCH_COUNT - issuedCount);
        }

        _addLaunchCount(tokenAddress, memberId, count);

        if (tokenAddress == FIRST_TOKEN_ADDRESS) {
            _addLaunchCount(ROOT_PARENT_TOKEN_ADDRESS, memberId, count);
        }
    }

    function remainingLaunchCount(address tokenAddress, uint256 memberId) external view returns (uint256) {
        return _remainingLaunchCount[tokenAddress][memberId];
    }

    function issuedLaunchCount(address tokenAddress) external view returns (uint256) {
        return _issuedLaunchCount[tokenAddress];
    }

    function tokens(uint256 offset, uint256 limit, bool reverse)
        external
        view
        returns (address[] memory tokenList, uint256 totalCount)
    {
        return _tokens.paginate(offset, limit, reverse);
    }

    function childTokens(address parentTokenAddress, uint256 offset, uint256 limit, bool reverse)
        external
        view
        returns (address[] memory tokenList, uint256 totalCount)
    {
        return _childTokens[parentTokenAddress].paginate(offset, limit, reverse);
    }

    function tokenAddressBySymbol(string calldata symbol) external view returns (address) {
        return _tokenAddressBySymbol[symbol];
    }

    function parentToken(address tokenAddress) external view returns (address) {
        return _parentTokenByTokenAddress[tokenAddress];
    }

    function _createToken(address parentTokenAddress, string memory name, string memory symbol, address distributor)
        internal
        returns (address tokenAddress)
    {
        uint256 nameLength = bytes(name).length;
        if (nameLength == 0) revert TokenNameEmpty();
        if (nameLength > MAX_TOKEN_NAME_LENGTH) revert TokenNameTooLong(nameLength, MAX_TOKEN_NAME_LENGTH);

        uint256 symbolLength = bytes(symbol).length;
        if (symbolLength == 0) revert TokenSymbolEmpty();
        if (symbolLength > MAX_TOKEN_SYMBOL_LENGTH) revert TokenSymbolTooLong(symbolLength, MAX_TOKEN_SYMBOL_LENGTH);

        tokenAddress = address(
            new LOVE20Token(name, symbol, LAUNCH_AMOUNT, MAX_SUPPLY, distributor, MINT_ADDRESS, parentTokenAddress)
        );

        IUniswapV2Factory factory = IUniswapV2Factory(PAIR_FACTORY_ADDRESS);
        // forge-lint: disable-next-line(reentrancy-no-eth)
        if (factory.getPair(tokenAddress, parentTokenAddress) == address(0)) {
            // forge-lint: disable-next-line(reentrancy-no-eth)
            address pair = factory.createPair(tokenAddress, parentTokenAddress);
            if (pair == address(0)) revert PairCreationFailed(parentTokenAddress);
        }
    }

    /**
     * @dev Read the current owner of a member NFT; a missing member reverts with the MemberNFT error.
     */
    function _ownerOf(uint256 memberId) internal view returns (address) {
        return IMemberNFT(MEMBER_NFT_ADDRESS).ownerOf(memberId);
    }

    /**
     * @dev Sub-token symbol rules: the UTF-8 byte length must equal the configured TOKEN_SYMBOL_LENGTH;
     *      the first character must be ASCII "A"-"Z" or a Chinese character, every following character
     *      must be ASCII "A"-"Z", "0"-"9" or a Chinese character. ASCII codes: "A"-"Z" is 0x41-0x5A,
     *      "0"-"9" is 0x30-0x39; a Chinese character is the three-byte UTF-8 encoding of a code point
     *      in the CJK Unified Ideographs block U+4E00-U+9FFF, so a pure-Chinese symbol needs a
     *      configured length that is a multiple of three. Any other byte sequence reverts, including
     *      incomplete UTF-8 sequences and multi-byte characters outside the block.
     */
    function _checkValidTokenSymbol(string calldata tokenSymbol) internal view {
        bytes calldata symbolBytes = bytes(tokenSymbol);
        uint256 length = symbolBytes.length;

        if (length != TOKEN_SYMBOL_LENGTH) revert InvalidTokenSymbolLength(length, TOKEN_SYMBOL_LENGTH);
        if (!_isValidTokenSymbolBytes(symbolBytes)) revert InvalidTokenSymbolCharacters();
    }

    /**
     * @dev Whether every character of the symbol bytes is allowed: the first position must be ASCII
     *      "A"-"Z" or a Chinese character, the remaining positions must be ASCII "A"-"Z", "0"-"9" or
     *      a Chinese character.
     */
    function _isValidTokenSymbolBytes(bytes calldata symbolBytes) internal pure returns (bool) {
        uint256 length = symbolBytes.length;
        uint256 i = 0;
        while (i < length) {
            uint8 byteValue = uint8(symbolBytes[i]);
            if (byteValue >= 0x41 && byteValue <= 0x5A) {
                i += 1;
            } else if (i > 0 && byteValue >= 0x30 && byteValue <= 0x39) {
                i += 1;
            } else if (_isChineseChar(symbolBytes, i, length)) {
                i += 3;
            } else {
                return false;
            }
        }
        return true;
    }

    /**
     * @dev Whether the three bytes starting at the index encode a Chinese character in the CJK
     *      Unified Ideographs block U+4E00-U+9FFF: two continuation bytes 0x80-0xBF after a lead byte
     *      0xE5-0xE9, or after 0xE4 with a second byte of at least 0xB8 (0xE4 with a lower second byte
     *      lies below U+4E00). An incomplete trailing sequence cannot match.
     */
    function _isChineseChar(bytes calldata symbolBytes, uint256 start, uint256 length)
        internal
        pure
        returns (bool)
    {
        if (start + 3 > length) return false;

        uint8 byte2 = uint8(symbolBytes[start + 1]);
        uint8 byte3 = uint8(symbolBytes[start + 2]);
        if (byte2 < 0x80 || byte2 > 0xBF || byte3 < 0x80 || byte3 > 0xBF) return false;

        uint8 byte1 = uint8(symbolBytes[start]);
        if (byte1 == 0xE4) return byte2 >= 0xB8;
        return byte1 >= 0xE5 && byte1 <= 0xE9;
    }

    /**
     * @dev NoCallback ignores distributor data; Callback requires a contract distributor.
     */
    function _checkDistributorMode(
        DistributorMode distributorMode,
        address distributor
    ) internal view {
        if (distributorMode == DistributorMode.NoCallback) {
            return;
        }
        if (distributor.code.length == 0) revert DistributorNotContract(distributor);
    }

    /**
     * @dev Add the "Test" prefix when the prefix source symbol starts with "Test"; the comparison uses the
     *      first four bytes, so a shorter symbol never matches. The caller passes the parent token symbol,
     *      or the first token symbol for root-level launches whose root parent symbol is shared across networks.
     */
    function _addTestPrefixIfNeeded(string calldata tokenSymbol, string memory prefixSourceSymbol)
        internal
        pure
        returns (string memory)
    {
        bytes memory symbolBytes = bytes(prefixSourceSymbol);
        if (
            symbolBytes.length >= 4 && symbolBytes[0] == "T" && symbolBytes[1] == "e" && symbolBytes[2] == "s"
                && symbolBytes[3] == "t"
        ) {
            return string(abi.encodePacked("Test", tokenSymbol));
        }
        return tokenSymbol;
    }

    function _addLaunchCount(
        address tokenAddress,
        uint256 memberId,
        uint256 count
    ) private {
        uint256 issuedCount = _issuedLaunchCount[tokenAddress] + count;
        _issuedLaunchCount[tokenAddress] = issuedCount;
        _remainingLaunchCount[tokenAddress][memberId] += count;
        emit LaunchCountAdded({
            tokenAddress: tokenAddress,
            memberId: memberId,
            count: count,
            issuedCount: issuedCount,
            memberRemaining: _remainingLaunchCount[tokenAddress][memberId]
        });
    }
}
