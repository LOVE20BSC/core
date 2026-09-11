// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

interface ILOVE20TokenFactoryErrors {
    error AlreadyInitialized();

    error ZeroAddress(string parameter);

    error EmptyString(string parameter);

    error InvalidAmount();

    error UnauthorizedCaller();
}

interface ILOVE20TokenFactoryEvents {
    event TokenCreate(
        address indexed tokenAddress,
        address indexed parentTokenAddress,
        string name,
        string symbol
    );
}

interface ILOVE20TokenFactory is
    ILOVE20TokenFactoryErrors,
    ILOVE20TokenFactoryEvents
{
    function uniswapV2Factory() external view returns (address);

    function launchAddress() external view returns (address);

    function stakeAddress() external view returns (address);

    function mintAddress() external view returns (address);

    function LAUNCH_AMOUNT() external view returns (uint256);

    function MAX_SUPPLY() external view returns (uint256);

    function MAX_WITHDRAWABLE_TO_FEE_RATIO() external view returns (uint256);

    function createToken(
        address parentTokenAddress,
        string memory name,
        string memory symbol
    ) external returns (address tokenAddress);
}
