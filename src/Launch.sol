// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {ILaunch, DistributorMode, LaunchInitParams} from "./interfaces/ILaunch.sol";
import {ILaunchDistributor} from "./interfaces/ILaunchDistributor.sol";
import {ILOVE20Token} from "./interfaces/ILOVE20Token.sol";
import {IMemberNFT} from "./interfaces/IMemberNFT.sol";
import {IUniswapV2Factory} from "./interfaces/UniswapV2/IUniswapV2Factory.sol";
import {LOVE20Token} from "./LOVE20Token.sol";

/**
 * @title Launch
 * @notice First token bootstrap, launch count ledger, count merging, sub-token launching and pair creation
 */
contract Launch is ILaunch {
    // ============ Fixed Parameters ============

    // used for the launch count permission
    address public mintAddress;
    // used for member ownership checks
    address public memberNFTAddress;
    // the root parent token, WBNB on BSC
    address public rootParentTokenAddress;
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
     *      launch count, carries no distributor data and always uses NoCallback.
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

        address firstTokenAddress =
            _createToken(params.rootParentTokenAddress, params.name, params.symbol, params.distributor);
        _tokens.push(firstTokenAddress);
        _parentTokenOf[firstTokenAddress] = params.rootParentTokenAddress;
        _tokenAddressBySymbol[params.symbol] = firstTokenAddress;
        _childTokens[params.rootParentTokenAddress].push(firstTokenAddress);

        // MemberNFT is initialized with the first token in the same transaction; it does not store Launch.
        IMemberNFT(params.memberNFTAddress).init(firstTokenAddress);

        // The first token address is known only after deployment, so this event follows the external call.
        // forge-lint: disable-next-item(reentrancy-events)
        emit TokenLaunched({
            tokenAddress: firstTokenAddress,
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
     *      external call, so a failing call reverts the consumption, the registration and the token.
     * @param tokenSymbol Sub-token symbol, validated against the configured length and character set
     * @param parentTokenAddress The community token, must be a registered LOVE20 token
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

        if (!isLOVE20Token(parentTokenAddress)) revert InvalidParentToken();

        if (_ownerOf(memberId) != msg.sender) revert NotMemberOwner(memberId);

        uint256 availableCount = _launchCount[parentTokenAddress][memberId];
        if (availableCount == 0) revert NotEnoughLaunchCount();

        _launchCount[parentTokenAddress][memberId] = availableCount - 1;

        // Mainnet test support: a parent symbol starting with "Test" prefixes the sub-token symbol.
        // The prefix is applied after the symbol check, so the actual symbol may exceed the configured length.
        string memory parentTokenSymbol = ILOVE20Token(parentTokenAddress).symbol();
        string memory subTokenSymbol = _addTestPrefixIfNeeded(tokenSymbol, parentTokenSymbol);
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
     * @param tokenAddress The community token
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

        if (!isLOVE20Token(tokenAddress)) revert InvalidTokenAddress();

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
     *      issued bound is enforced here as a fallback.
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
    }

    // ============ Queries ============

    /**
     * @notice Available integer launch count of a member in a community
     * @dev An unregistered token returns 0 without reverting.
     */
    function launchCount(address tokenAddress, uint256 memberId) external view returns (uint256) {
        return _launchCount[tokenAddress][memberId];
    }

    /**
     * @notice Issued launch count of a community; consumption and merging never decrease it
     * @dev An unregistered token returns 0 without reverting.
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
        return _page(_tokens, offset, limit, reverse);
    }

    /**
     * @notice Page through the sub-tokens of a community in creation order
     * @dev `childTokens(rootParentTokenAddress)` returns the first token; an unknown parent returns an
     *      empty array and a zero count.
     * @param parentTokenAddress The community token
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
        return _page(_childTokens[parentTokenAddress], offset, limit, reverse);
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

        // Every launched token gets its pair in the same transaction, so staking a community never depends
        // on a step outside the protocol. The address is not stored here: Stake reads it from the factory
        // on its first stake. A factory returning the zero address is rejected instead of leaving the
        // community un-stakable without a trace.
        // No reentrancy guard: the factory only deploys the pair and calls back into nothing that can reach
        // Launch, and the caller registers the token right after this returns.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        if (IUniswapV2Factory(pairFactoryAddress).createPair(tokenAddress, parentTokenAddress) == address(0)) {
            revert InvalidAddress();
        }
    }

    /**
     * @dev Shared pagination for the launch lists: an out-of-range offset yields an empty page with
     *      the true total count, and a limit above the remaining entries is clamped.
     */
    function _page(address[] storage list, uint256 offset, uint256 limit, bool reverse)
        private
        view
        returns (address[] memory tokenList, uint256 totalCount)
    {
        totalCount = list.length;
        if (offset >= totalCount) {
            return (new address[](0), totalCount);
        }

        uint256 remaining = totalCount - offset;
        uint256 pageSize = remaining < limit ? remaining : limit;
        tokenList = new address[](pageSize);

        for (uint256 i = 0; i < pageSize; i++) {
            uint256 index = reverse ? (totalCount - 1 - offset - i) : (offset + i);
            tokenList[i] = list[index];
        }

        return (tokenList, totalCount);
    }

    /**
     * @dev Read the current owner of a member NFT; a missing member reverts with the MemberNFT error.
     */
    function _ownerOf(uint256 memberId) internal view returns (address) {
        return IMemberNFT(memberNFTAddress).ownerOf(memberId);
    }

    /**
     * @dev Sub-token symbol rules kept from the old launch: exact configured length, first character A-Z,
     *      remaining characters A-Z or 0-9. ASCII codes: "A"-"Z" is 0x41-0x5A, "0"-"9" is 0x30-0x39.
     */
    function _checkValidTokenSymbol(string calldata tokenSymbol) internal view {
        bytes calldata symbolBytes = bytes(tokenSymbol);
        uint256 length = symbolBytes.length;

        // The configured length is greater than zero after init; the empty check keeps the first-byte
        // access below total.
        if (length == 0 || length != TOKEN_SYMBOL_LENGTH) revert InvalidTokenSymbol();

        uint8 firstByte = uint8(symbolBytes[0]);
        if (firstByte < 0x41 || firstByte > 0x5A) revert InvalidTokenSymbol();

        bool allLettersOrDigits = true;
        for (uint256 i = 1; i < length; i++) {
            uint8 byteValue = uint8(symbolBytes[i]);
            if (!((byteValue >= 0x41 && byteValue <= 0x5A) || (byteValue >= 0x30 && byteValue <= 0x39))) {
                allLettersOrDigits = false;
                break;
            }
        }
        if (!allLettersOrDigits) revert InvalidTokenSymbol();
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
     * @dev Add the "Test" prefix when the parent token symbol starts with "Test"; the comparison uses the
     *      first four bytes of the parent symbol, so a shorter symbol never matches.
     */
    function _addTestPrefixIfNeeded(string calldata tokenSymbol, string memory parentTokenSymbol)
        internal
        pure
        returns (string memory)
    {
        bytes memory parentSymbolBytes = bytes(parentTokenSymbol);
        if (
            parentSymbolBytes.length >= 4 && parentSymbolBytes[0] == "T" && parentSymbolBytes[1] == "e"
                && parentSymbolBytes[2] == "s" && parentSymbolBytes[3] == "t"
        ) {
            return string(abi.encodePacked("Test", tokenSymbol));
        }
        return tokenSymbol;
    }
}
