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
    error InvalidTokenSymbol();
    error TokenSymbolExists();
    error InvalidTokenAddress();
    error InvalidParentToken();
    error InvalidAddress();
    error InvalidDistributorMode();
    error ZeroAmount(string parameter);
    error UnauthorizedCaller();
    error NotMemberOwner(uint256 memberId);
    error CountMustBeGreaterThanZero();
    error SourceAndTargetMustBeDifferent();
    error NotEnoughLaunchCount();
    error LaunchCountLimitReached();
    error InvalidAmount();
    error EmptyString(string parameter);
}

interface ILaunchEvents {
    event TokenLaunched(
        address indexed tokenAddress,
        address indexed parentTokenAddress,
        uint256 indexed launcherMemberId,
        address distributor,
        string name,
        string symbol
    );
    event LaunchCountAdded(address indexed tokenAddress, uint256 indexed memberId, uint256 count);
    event LaunchCountMerged(
        address indexed tokenAddress, uint256 indexed sourceMemberId, uint256 indexed targetMemberId, uint256 count
    );
}

interface ILaunch is ILaunchErrors, ILaunchEvents {
    function mintAddress() external view returns (address);
    function memberNFTAddress() external view returns (address);
    function rootParentTokenAddress() external view returns (address);
    function TOKEN_SYMBOL_LENGTH() external view returns (uint256);
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
