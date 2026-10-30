// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

interface ILOVE20TokenEvents {
    event TokenMinted(
        address indexed to,
        uint256 amount
    );
    event TokenBurned(
        address indexed from,
        uint256 amount
    );
}

interface ILOVE20TokenErrors {
    error ZeroInitialSupply();
    error InvalidInitialSupply(
        uint256 value,
        uint256 maxSupply
    );
    error ZeroDistributorAddress();
    error DependencyNotContract(address dependency);
    error NotMinter(address caller);
    error MaxSupplyExceeded(
        uint256 requested,
        uint256 remaining
    );
}

interface ILOVE20Token is
    IERC20,
    IERC20Metadata,
    IERC20Errors,
    ILOVE20TokenEvents,
    ILOVE20TokenErrors
{
    function MAX_SUPPLY() external view returns (uint256);

    function MINTER() external view returns (address);

    function PARENT_TOKEN_ADDRESS() external view returns (address);

    function mint(address to, uint256 amount) external;

    function burn(uint256 amount) external;
}
