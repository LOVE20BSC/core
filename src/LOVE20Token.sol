// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ILOVE20Token} from "./interfaces/ILOVE20Token.sol";

contract LOVE20Token is ERC20, ILOVE20Token {
    uint256 public immutable MAX_SUPPLY;
    address public MINTER;
    address public PARENT_TOKEN_ADDRESS;

    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        uint256 maxSupply,
        address distributor,
        address minter,
        address parentTokenAddress
    ) ERC20(name, symbol) {
        if (initialSupply == 0) revert ZeroInitialSupply();
        if (maxSupply < initialSupply) revert InvalidInitialSupply(initialSupply, maxSupply);
        if (distributor == address(0)) revert ZeroDistributorAddress();
        if (minter.code.length == 0) revert DependencyNotContract(minter);
        if (parentTokenAddress.code.length == 0) revert DependencyNotContract(parentTokenAddress);

        _mint(distributor, initialSupply);
        emit TokenMinted({
            to: distributor,
            amount: initialSupply
        });
        MAX_SUPPLY = maxSupply;
        MINTER = minter;
        PARENT_TOKEN_ADDRESS = parentTokenAddress;
    }

    modifier onlyMinter() {
        if (msg.sender != MINTER) revert NotMinter(msg.sender);
        _;
    }

    function mint(address to, uint256 amount) external override onlyMinter {
        uint256 remaining = MAX_SUPPLY - totalSupply();
        if (amount > remaining) revert MaxSupplyExceeded(amount, remaining);
        _mint(to, amount);
        emit TokenMinted({
            to: to,
            amount: amount
        });
    }

    function burn(uint256 amount) external override {
        _burn(msg.sender, amount);
        emit TokenBurned({
            from: msg.sender,
            amount: amount
        });
    }
}
