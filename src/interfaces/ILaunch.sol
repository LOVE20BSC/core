// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

enum DistributorMode {
    NoCallback,
    Callback
}

struct LaunchInitParams {
    address mintAddress;
    address memberNFTAddress;
    address rootParentTokenAddress;
    address pairFactoryAddress;
    address distributor;
    uint256 launchRatio;
    uint256 maxLaunchCount;
    uint256 tokenSymbolLength;
    uint256 launchAmount;
    uint256 maxSupply;
    string name;
    string symbol;
}

interface ILaunchErrors {
    error AlreadyInitialized();
    error ZeroDistributorAddress();
    error TokenNameEmpty();
    error TokenSymbolEmpty();
    error TokenNameTooLong(
        uint256 length,
        uint256 maxLength
    );
    error TokenSymbolTooLong(
        uint256 length,
        uint256 maxLength
    );
    error InvalidTokenSymbolLength(
        uint256 length,
        uint256 expected
    );
    error InvalidTokenSymbolCharacters();
    error TokenSymbolAlreadyExists(bytes32 symbolHash);
    error PairCreationFailed(address parentTokenAddress);
    error ParentTokenNotRegistered(address parentTokenAddress);
    error TokenNotRegistered(address tokenAddress);
    error DistributorNotContract(address distributor);
    error InsufficientLaunchCount(
        uint256 memberId,
        uint256 available,
        uint256 required
    );
    error ZeroCount();
    error SourceAndTargetMemberIdsMustBeDifferent(
        uint256 sourceMemberId,
        uint256 targetMemberId
    );
    error NotMemberOwner(uint256 memberId);
    error NotMintContract(address caller);
    error LaunchCountLimitExceeded(
        address tokenAddress,
        uint256 requested,
        uint256 remaining
    );
}

interface ILaunchEvents {
    event GenesisTokenCreated(
        address indexed tokenAddress,
        address indexed parentTokenAddress,
        address distributor,
        string name,
        string symbol
    );
    event TokenLaunched(
        address indexed tokenAddress,
        address indexed parentTokenAddress,
        uint256 indexed launcherMemberId,
        address distributor,
        DistributorMode distributorMode,
        string name,
        string symbol
    );
    event LaunchCountAdded(
        address indexed tokenAddress,
        uint256 indexed memberId,
        uint256 count,
        uint256 issuedCount,
        uint256 memberRemaining
    );
    event LaunchCountMerged(
        address indexed tokenAddress,
        uint256 indexed sourceMemberId,
        uint256 indexed targetMemberId,
        uint256 count,
        uint256 sourceRemaining,
        uint256 targetRemaining
    );
    event LaunchCountConsumed(
        address indexed tokenAddress,
        uint256 indexed memberId,
        uint256 remaining
    );
}

interface ILaunch is ILaunchErrors, ILaunchEvents {
    function mintAddress() external view returns (address);
    function memberNFTAddress() external view returns (address);
    function rootParentTokenAddress() external view returns (address);
    function firstTokenAddress() external view returns (address);
    function pairFactoryAddress() external view returns (address);
    function TOKEN_SYMBOL_LENGTH() external view returns (uint256);
    function MAX_TOKEN_SYMBOL_LENGTH() external view returns (uint256);
    function MAX_TOKEN_NAME_LENGTH() external view returns (uint256);
    function LAUNCH_RATIO() external view returns (uint256);
    function MAX_LAUNCH_COUNT() external view returns (uint256);
    function LAUNCH_AMOUNT() external view returns (uint256);
    function MAX_SUPPLY() external view returns (uint256);
    function initialized() external view returns (bool);
    function init(LaunchInitParams calldata params) external;
    function isLOVE20Token(address tokenAddress) external view returns (bool);
    function launchToken(
        string calldata tokenSymbol,
        address parentTokenAddress,
        uint256 memberId,
        address distributor,
        DistributorMode distributorMode,
        bytes[] calldata distributorData
    ) external returns (address tokenAddress);
    function mergeLaunchCount(address tokenAddress, uint256 sourceMemberId, uint256 targetMemberId, uint256 count)
        external;
    function addLaunchCount(address tokenAddress, uint256 memberId, uint256 count) external;
    function launchCount(address tokenAddress, uint256 memberId) external view returns (uint256);
    function issuedLaunchCount(address tokenAddress) external view returns (uint256);
    function tokens(uint256 offset, uint256 limit, bool reverse)
        external
        view
        returns (address[] memory tokenList, uint256 totalCount);
    function childTokens(address parentTokenAddress, uint256 offset, uint256 limit, bool reverse)
        external
        view
        returns (address[] memory tokenList, uint256 totalCount);
    function tokenAddressBySymbol(string calldata symbol) external view returns (address);
    function parentTokenOf(address tokenAddress) external view returns (address);
}
