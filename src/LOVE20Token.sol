// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ILOVE20Token} from "./interfaces/ILOVE20Token.sol";

/**
 * @title LOVE20Token
 * @notice Implementation of the LOVE20 token with burning and minting capabilities
 * @dev Implements ILOVE20Token on top of OpenZeppelin ERC20
 */
contract LOVE20Token is ERC20, ILOVE20Token {
    // State variables
    uint256 public immutable MAX_SUPPLY;
    address public MINTER;
    address public PARENT_TOKEN_ADDRESS;
    /**
     * @notice Contract constructor
     * @dev `initialSupply` must be greater than zero and at most `maxSupply`, so a deployed token
     *      never starts with a zero total supply.
     * @param name Token name
     * @param symbol Token symbol
     * @param initialSupply Initial token supply
     * @param maxSupply Maximum token supply
     * @param distributor Initial token recipient
     * @param minter Address allowed to mint
     * @param parentTokenAddress Parent token address
     */
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

    /**
     * @inheritdoc ILOVE20Token
     */
    function mint(address to, uint256 amount) external override onlyMinter {
        uint256 remaining = MAX_SUPPLY - totalSupply();
        if (amount > remaining) revert MaxSupplyExceeded(amount, remaining);
        _mint(to, amount);
        emit TokenMinted({
            to: to,
            amount: amount
        });
    }

    /**
     * @inheritdoc ILOVE20Token
     */
    function burn(uint256 amount) external override {
        _burn(msg.sender, amount);
        emit TokenBurned({
            from: msg.sender,
            amount: amount
        });
    }
}
