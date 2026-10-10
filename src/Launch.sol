// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {ILaunch, DistributorMode, LaunchInitParams} from "./interfaces/ILaunch.sol";
import {ILaunchDistributor} from "./interfaces/ILaunchDistributor.sol";
import {ILOVE20Token} from "./interfaces/ILOVE20Token.sol";
import {IMemberNFT} from "./interfaces/IMemberNFT.sol";
import {IUniswapV2Factory} from "./interfaces/UniswapV2/IUniswapV2Factory.sol";
import {LOVE20Token} from "./LOVE20Token.sol";
import {Pagination} from "../lib/libs/src/Pagination.sol";

/**
 * @title Launch
 * @notice First token bootstrap, launch count ledger, count merging, sub-token launching and pair creation
 */
contract Launch is ILaunch {
    using Pagination for address[];
    // ============ Fixed Parameters ============

    // used for the launch count permission
    address public mintAddress;
    // used for member ownership checks
    address public memberNFTAddress;
    // the root parent token, WBNB on BSC
    address public rootParentTokenAddress;
    // the first token; its launch counts mirror 1:1 into root-level counts
    address public firstTokenAddress;
    // the Uniswap V2 compatible factory every launched token gets its pair from
    address public pairFactoryAddress;

    // sub-token symbol length
    uint256 public TOKEN_SYMBOL_LENGTH;
    // launch threshold ratio used by Mint, 1e18 precision
    uint256 public LAUNCH_RATIO;
    // per-community upper bound of issued launch counts
    uint256 public MAX_LAUNCH_COUNT;
    // first token supply
    uint256 public LAUNCH_AMOUNT;
    // maximum supply of every launched token
    uint256 public MAX_SUPPLY;
    bool public initialized;

    // ============ State Variables ============

    // creation-ordered list of every launched token, the first token included
    address[] internal _tokens;
    // tokenAddress => parent token address; the zero address means Launch did not create the token
    mapping(address => address) internal _parentTokenOf;
    // symbol => token address; symbols are unique and the first token is registered too
    mapping(string => address) internal _tokenAddressBySymbol;
    // parentTokenAddress => creation-ordered children
    mapping(address => address[]) internal _childTokens;

    // tokenAddress => memberId => available integer launch count
    mapping(address => mapping(uint256 => uint256)) internal _launchCount;
    // tokenAddress => issued launch count; consumption and merging do not decrease it
    mapping(address => uint256) internal _issuedLaunchCount;

    // ============ Initialization ============

    /**
     * @notice Bind dependencies, create and register the first token, and initialize MemberNFT
     * @dev The initialization state check runs before parameter checks. The first token does not consume a
     *      launch count, carries no distributor data and always uses NoCallback. It is recorded as
     *      `firstTokenAddress`, the only token whose launch counts mirror into root-level counts.
     * @param params Dependencies, launch settings, token supply settings and first-token metadata
     */
    function init(LaunchInitParams calldata params) external {
        if (initialized) revert AlreadyInitialized();
        if (
            params.mintAddress == address(0) || params.memberNFTAddress == address(0)
                || params.rootParentTokenAddress == address(0) || params.pairFactoryAddress == address(0)
                || params.distributor == address(0)
        ) {
            revert InvalidAddress();
        }
        if (params.launchRatio == 0) revert ZeroAmount("launchRatio");
        if (params.launchRatio > 1e18) revert InvalidAmount();
        if (params.maxLaunchCount == 0) revert ZeroAmount("maxLaunchCount");
        if (params.tokenSymbolLength == 0) revert ZeroAmount("tokenSymbolLength");
        if (params.launchAmount == 0) revert ZeroAmount("launchAmount");
        if (params.launchAmount > params.maxSupply) revert InvalidAmount();

        initialized = true;
        mintAddress = params.mintAddress;
        memberNFTAddress = params.memberNFTAddress;
        rootParentTokenAddress = params.rootParentTokenAddress;
        pairFactoryAddress = params.pairFactoryAddress;
        LAUNCH_RATIO = params.launchRatio;
        MAX_LAUNCH_COUNT = params.maxLaunchCount;
        TOKEN_SYMBOL_LENGTH = params.tokenSymbolLength;
        LAUNCH_AMOUNT = params.launchAmount;
        MAX_SUPPLY = params.maxSupply;

        address firstToken = _createToken(params.rootParentTokenAddress, params.name, params.symbol, params.distributor);
        firstTokenAddress = firstToken;
        _tokens.push(firstToken);
        _parentTokenOf[firstToken] = params.rootParentTokenAddress;
        _tokenAddressBySymbol[params.symbol] = firstToken;
        _childTokens[params.rootParentTokenAddress].push(firstToken);

        // MemberNFT is initialized with the first token in the same transaction; it does not store Launch.
        IMemberNFT(params.memberNFTAddress).init(firstToken);

        // The first token address is known only after deployment, so this event follows the external call.
        // forge-lint: disable-next-item(reentrancy-events)
        emit TokenLaunched({
            tokenAddress: firstToken,
            parentTokenAddress: params.rootParentTokenAddress,
            launcherMemberId: 0,
            distributor: params.distributor,
            name: params.name,
            symbol: params.symbol
        });
    }

    // ============ Token Registration ============

    /**
     * @notice Whether the address is a LOVE20 token created and registered by Launch
     * @dev The first token is registered in `init`, sub-tokens in `launchToken`. The check reads the
     *      parent ledger Launch maintains itself, so any address Launch did not create — WBNB, EOAs,
     *      unrelated contracts — returns false without an external call.
     */
    function isLOVE20Token(address tokenAddress) public view returns (bool) {
        return _parentTokenOf[tokenAddress] != address(0);
    }

    // ============ Launch ============

    /**
     * @notice Launch a sub-token of the given community and consume one launch count
     * @dev Check order: parameters, existence, ownership, ledger. The launch count is consumed before any
     *      external call, so a failing call reverts the consumption, the registration and the token. The
     *      root parent token is accepted as a parent for root-level launches and consumes the root-level
     *      count; every other parent must be a registered LOVE20 token.
     * @param tokenSymbol Sub-token symbol, validated against the configured length and character set
     * @param parentTokenAddress The community token, must be a registered LOVE20 token or the root parent token
     * @param memberId The member that consumes the launch count, must be held by the caller
     * @param distributor Receiver of the initial supply
     * @param distributorMode NoCallback or Callback
     * @param distributorData Opaque data array passed to the distributor callback, format defined by distributor
     * @return tokenAddress The newly created sub-token
     */
    function launchToken(
        string calldata tokenSymbol,
        address parentTokenAddress,
        uint256 memberId,
        address distributor,
        DistributorMode distributorMode,
        bytes[] calldata distributorData
    ) external returns (address tokenAddress) {
        _checkValidTokenSymbol(tokenSymbol);
        if (distributor == address(0)) revert InvalidAddress();
        _checkDistributorMode(distributorMode, distributor);

        if (parentTokenAddress != rootParentTokenAddress && !isLOVE20Token(parentTokenAddress)) {
            revert InvalidParentToken();
        }

        if (_ownerOf(memberId) != msg.sender) revert NotMemberOwner(memberId);

        uint256 availableCount = _launchCount[parentTokenAddress][memberId];
        if (availableCount == 0) revert NotEnoughLaunchCount();

        _launchCount[parentTokenAddress][memberId] = availableCount - 1;

        // Mainnet test support: a parent symbol starting with "Test" prefixes the sub-token symbol; a
        // root-level launch reads the first token instead, since the root parent symbol is shared across
        // networks. The prefix is applied after the symbol check, so the actual symbol may exceed the length.
        string memory parentTokenSymbol = ILOVE20Token(parentTokenAddress).symbol();
        string memory prefixSourceSymbol = parentTokenAddress == rootParentTokenAddress
            ? ILOVE20Token(firstTokenAddress).symbol()
            : parentTokenSymbol;
        string memory subTokenSymbol = _addTestPrefixIfNeeded(tokenSymbol, prefixSourceSymbol);
        if (_tokenAddressBySymbol[subTokenSymbol] != address(0)) revert TokenSymbolExists();
        string memory tokenName = string.concat(subTokenSymbol, "@", parentTokenSymbol);

        // Registration must follow creation because the token address is only known afterwards; a
        // reentrant call cannot observe an inconsistent registry, and the registry is complete before
        // the distributor callback runs.
        // forge-lint: disable-next-item(reentrancy-no-eth)
        tokenAddress = _createToken(parentTokenAddress, tokenName, subTokenSymbol, distributor);
        _tokens.push(tokenAddress);
        _parentTokenOf[tokenAddress] = parentTokenAddress;
        _tokenAddressBySymbol[subTokenSymbol] = tokenAddress;
        _childTokens[parentTokenAddress].push(tokenAddress);

        // The new token address is known only after deployment, so this event follows the external call.
        // forge-lint: disable-next-item(reentrancy-events)
        emit TokenLaunched({
            tokenAddress: tokenAddress,
            parentTokenAddress: parentTokenAddress,
            launcherMemberId: memberId,
            distributor: distributor,
            name: tokenName,
            symbol: subTokenSymbol
        });

        if (distributorMode == DistributorMode.Callback) {
            ILaunchDistributor(distributor).onTokenLaunched(tokenAddress, parentTokenAddress, memberId, distributorData);
        }
    }

    /**
     * @notice Move part of the available launch count to another member of the same community
     * @dev Only the source MemberNFT is required to be held, the target is not. The launch credit held by
     *      Mint is not transferred and no other state of the target is touched.
     * @param tokenAddress The community token or the root parent token for root-level counts
     * @param sourceMemberId The member that gives the count, must be held by the caller
     * @param targetMemberId The member that receives the count, only required to exist
     * @param count The transferred count, greater than zero
     */
    function mergeLaunchCount(address tokenAddress, uint256 sourceMemberId, uint256 targetMemberId, uint256 count)
        external
    {
        if (sourceMemberId == targetMemberId) {
            revert SourceAndTargetMustBeDifferent();
        }
        if (count == 0) revert CountMustBeGreaterThanZero();

        if (tokenAddress != rootParentTokenAddress && !isLOVE20Token(tokenAddress)) revert InvalidTokenAddress();

        address sourceOwner = _ownerOf(sourceMemberId);
        // Existence check only: a missing target reverts with the MemberNFT error, Launch adds no own error.
        _ownerOf(targetMemberId);

        if (sourceOwner != msg.sender) revert NotMemberOwner(sourceMemberId);

        uint256 sourceCount = _launchCount[tokenAddress][sourceMemberId];
        if (sourceCount < count) revert NotEnoughLaunchCount();

        _launchCount[tokenAddress][sourceMemberId] = sourceCount - count;
        _launchCount[tokenAddress][targetMemberId] += count;

        emit LaunchCountMerged({
            tokenAddress: tokenAddress, sourceMemberId: sourceMemberId, targetMemberId: targetMemberId, count: count
        });
    }

    /**
     * @notice Add launch counts of a community to a member
     * @dev Only Mint can call it, in the same transaction as the governance reward mint. The per-community
     *      issued bound is enforced here as a fallback. When the token is the first token, the same count is
     *      mirrored 1:1 into the root-level ledger under rootParentTokenAddress, so root-level issuance stays
     *      equal to the first token's issuance; the root parent token itself is not accepted as a parameter.
     * @param tokenAddress The community token, must be a registered LOVE20 token
     * @param memberId The member that receives the counts
     * @param count The added count, greater than zero
     */
    function addLaunchCount(address tokenAddress, uint256 memberId, uint256 count) external {
        if (msg.sender != mintAddress) revert UnauthorizedCaller();
        if (count == 0) revert CountMustBeGreaterThanZero();
        if (!isLOVE20Token(tokenAddress)) revert InvalidTokenAddress();

        uint256 issuedCount = _issuedLaunchCount[tokenAddress];
        // Subtraction form: the cap check must also hold for extremely large counts, and issuedCount
        // never exceeds MAX_LAUNCH_COUNT, so the subtraction cannot underflow.
        if (count > MAX_LAUNCH_COUNT - issuedCount) {
            revert LaunchCountLimitReached();
        }

        _launchCount[tokenAddress][memberId] += count;
        _issuedLaunchCount[tokenAddress] = issuedCount + count;

        emit LaunchCountAdded({tokenAddress: tokenAddress, memberId: memberId, count: count});

        // The first token's counts are mirrored 1:1 into the root-level ledger of the same member.
        if (tokenAddress == firstTokenAddress) {
            _launchCount[rootParentTokenAddress][memberId] += count;
            _issuedLaunchCount[rootParentTokenAddress] += count;
            emit LaunchCountAdded({tokenAddress: rootParentTokenAddress, memberId: memberId, count: count});
        }
    }

    // ============ Queries ============

    /**
     * @notice Available integer launch count of a member in a community
     * @dev An unregistered token returns 0 without reverting, except the root parent token, which carries
     *      the root-level counts.
     */
    function launchCount(address tokenAddress, uint256 memberId) external view returns (uint256) {
        return _launchCount[tokenAddress][memberId];
    }

    /**
     * @notice Issued launch count of a community; consumption and merging never decrease it
     * @dev An unregistered token returns 0 without reverting, except the root parent token, whose issued
     *      count mirrors the first token's.
     */
    function issuedLaunchCount(address tokenAddress) external view returns (uint256) {
        return _issuedLaunchCount[tokenAddress];
    }

    /**
     * @notice Page through every launched token in creation order, the first token included
     * @dev An offset beyond the list returns an empty array and the true total count, without reverting.
     * @param offset Starting index, 0-based
     * @param limit Maximum number of entries to return
     * @param reverse If true, return the newest tokens first
     * @return tokenList The requested page
     * @return totalCount Total number of launched tokens
     */
    function tokens(uint256 offset, uint256 limit, bool reverse)
        external
        view
        returns (address[] memory tokenList, uint256 totalCount)
    {
        return _tokens.paginate(offset, limit, reverse);
    }

    /**
     * @notice Page through the sub-tokens of a community in creation order
     * @dev `childTokens(rootParentTokenAddress)` returns the first token and every root-level token, the
     *      first token at index 0; an unknown parent returns an empty array and a zero count.
     * @param parentTokenAddress The community token, or the root parent token for root-level tokens
     * @param offset Starting index, 0-based
     * @param limit Maximum number of entries to return
     * @param reverse If true, return the newest sub-tokens first
     * @return tokenList The requested page
     * @return totalCount Total number of sub-tokens of the community
     */
    function childTokens(address parentTokenAddress, uint256 offset, uint256 limit, bool reverse)
        external
        view
        returns (address[] memory tokenList, uint256 totalCount)
    {
        return _childTokens[parentTokenAddress].paginate(offset, limit, reverse);
    }

    /**
     * @notice Token address registered for a symbol
     * @dev Symbols are unique, so the lookup is single valued; an unused symbol returns the zero
     *      address.
     */
    function tokenAddressBySymbol(string calldata symbol) external view returns (address) {
        return _tokenAddressBySymbol[symbol];
    }

    /**
     * @notice Parent token address Launch recorded for a token address
     * @dev The zero address means Launch did not create the token; the first token returns
     *      `rootParentTokenAddress`.
     */
    function parentTokenOf(address tokenAddress) external view returns (address) {
        return _parentTokenOf[tokenAddress];
    }

    // ============ Internal Functions ============

    function _createToken(address parentTokenAddress, string memory name, string memory symbol, address distributor)
        internal
        returns (address tokenAddress)
    {
        if (bytes(name).length == 0) revert EmptyString("name");
        if (bytes(symbol).length == 0) revert EmptyString("symbol");
        tokenAddress = address(
            new LOVE20Token(name, symbol, LAUNCH_AMOUNT, MAX_SUPPLY, distributor, mintAddress, parentTokenAddress)
        );

        // Reuse a correct Pair that was created before this predictable CREATE address was deployed.
        IUniswapV2Factory factory = IUniswapV2Factory(pairFactoryAddress);
        // forge-lint: disable-next-line(reentrancy-no-eth)
        if (factory.getPair(tokenAddress, parentTokenAddress) == address(0)) {
            // forge-lint: disable-next-line(reentrancy-no-eth)
            if (factory.createPair(tokenAddress, parentTokenAddress) == address(0)) revert InvalidAddress();
        }
    }

    /**
     * @dev Read the current owner of a member NFT; a missing member reverts with the MemberNFT error.
     */
    function _ownerOf(uint256 memberId) internal view returns (address) {
        return IMemberNFT(memberNFTAddress).ownerOf(memberId);
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

        // The configured length is greater than zero after init; the empty check keeps the first-byte
        // access below total.
        if (length == 0 || length != TOKEN_SYMBOL_LENGTH) revert InvalidTokenSymbol();
        if (!_isValidTokenSymbolBytes(symbolBytes)) revert InvalidTokenSymbol();
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
        if (distributor.code.length == 0) revert InvalidDistributorMode();
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
}
