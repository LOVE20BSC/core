// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

interface ITokenFactoryErrors {
    error AlreadyInitialized();
    error ZeroAddress(string parameter);
    error EmptyString(string parameter);
    error InvalidAmount();
    error UnauthorizedCaller();
}

interface ITokenFactoryEvents {
    event TokenCreated(
        address indexed tokenAddress,
        address indexed parentTokenAddress,
        string name,
        string symbol,
        address distributor
    );
}

interface ITokenFactory is ITokenFactoryErrors, ITokenFactoryEvents {
    function launchAddress() external view returns (address);
    function mintAddress() external view returns (address);
    function initialized() external view returns (bool);
    function LAUNCH_AMOUNT() external view returns (uint256);
    function MAX_SUPPLY() external view returns (uint256);
    function init(
        address launchAddress,
        address mintAddress,
        uint256 launchAmount,
        uint256 maxSupply
    ) external;
    function createToken(
        address parentTokenAddress,
        string calldata name,
        string calldata symbol,
        address distributor
    ) external returns (address tokenAddress);
}
