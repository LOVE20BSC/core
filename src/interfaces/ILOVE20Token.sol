// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface ILOVE20TokenEvents {
    event TokenMint(address indexed to, uint256 amount);
    event TokenBurn(address indexed from, uint256 amount);
    event BurnForParentToken(
        address indexed burner,
        uint256 burnAmount,
        uint256 parentTokenAmount
    );
}

interface ILOVE20TokenErrors {
    error AlreadyInitialized();
    error InvalidAddress();
    error NotMinter();
    error ExceedsMaxSupply();
    error InsufficientBalance();
    error InvalidSupply();
}

interface ILOVE20Token is
    IERC20,
    IERC20Metadata,
    ILOVE20TokenEvents,
    ILOVE20TokenErrors
{
    function maxSupply() external view returns (uint256);

    function minter() external view returns (address);

    function parentTokenAddress() external view returns (address);

    function slAddress() external view returns (address);

    function stAddress() external view returns (address);

    function parentPool() external view returns (uint256);

    function mint(address to, uint256 amount) external;

    function burn(uint256 amount) external;

    function burnForParentToken(
        uint256 amount
    ) external returns (uint256 parentTokenAmount);
}
