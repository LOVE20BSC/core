// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface ILOVE20TokenEvents {
    event TokenMint(address indexed to, uint256 amount);
    event TokenBurn(address indexed from, uint256 amount);
}

interface ILOVE20TokenErrors {
    error InvalidAddress();
    error NotMinter();
    error ExceedsMaxSupply();
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

    function mint(address to, uint256 amount) external;

    function burn(uint256 amount) external;
}
