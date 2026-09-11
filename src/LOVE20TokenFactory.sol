// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {LOVE20Token} from "./LOVE20Token.sol";
import {LOVE20SLToken} from "./LOVE20SLToken.sol";
import {LOVE20STToken} from "./LOVE20STToken.sol";
import {IUniswapV2Factory} from "./uniswap-v2-core/interfaces/IUniswapV2Factory.sol";
import {ILOVE20TokenFactory} from "./interfaces/ILOVE20TokenFactory.sol";

/**
 * @title LOVE20TokenFactory
 * @notice Factory contract for creating LOVE20 tokens and their associated tokens
 */
contract LOVE20TokenFactory is ILOVE20TokenFactory {
    address public uniswapV2Factory;
    address public launchAddress;
    address public stakeAddress;
    address public mintAddress;

    uint256 public LAUNCH_AMOUNT;
    uint256 public MAX_SUPPLY;
    uint256 public MAX_WITHDRAWABLE_TO_FEE_RATIO;

    bool public initialized;

    /**
     * @notice Modifier to ensure only the launch address can call a function
     */
    modifier onlyLaunch() {
        if (msg.sender != launchAddress) {
            revert UnauthorizedCaller();
        }
        _;
    }

    /**
     * @notice Initializes the factory contract
     * @dev Can only be called once
     */
    function initialize(
        address uniswapV2Factory_,
        address launchAddress_,
        address stakeAddress_,
        address mintAddress_,
        uint256 launchAmount_,
        uint256 maxSupply_,
        uint256 maxWithdrawableToFeeRatio_
    ) external {
        if (maxSupply_ < launchAmount_) {
            revert InvalidAmount();
        }

        if (initialized) {
            revert AlreadyInitialized();
        }

        initialized = true;
        uniswapV2Factory = uniswapV2Factory_;
        launchAddress = launchAddress_;
        stakeAddress = stakeAddress_;
        mintAddress = mintAddress_;
        LAUNCH_AMOUNT = launchAmount_;
        MAX_SUPPLY = maxSupply_;
        MAX_WITHDRAWABLE_TO_FEE_RATIO = maxWithdrawableToFeeRatio_;
    }

    /**
     * @notice Creates a new LOVE20 token with its associated SL and ST tokens
     * @dev Only the launch address can create new tokens
     */
    function createToken(
        address parentTokenAddress,
        string calldata name,
        string calldata symbol
    ) external override onlyLaunch returns (address tokenAddress) {
        if (parentTokenAddress == address(0)) {
            revert ZeroAddress("parentTokenAddress");
        }
        if (bytes(name).length == 0) {
            revert EmptyString("name");
        }
        if (bytes(symbol).length == 0) {
            revert EmptyString("symbol");
        }

        // Create LOVE20Token
        LOVE20Token token = new LOVE20Token(
            name,
            symbol,
            LAUNCH_AMOUNT,
            MAX_SUPPLY,
            msg.sender
        );
        tokenAddress = address(token);

        // Create LOVE20SLToken
        address pairAddress = IUniswapV2Factory(uniswapV2Factory).createPair(
            tokenAddress,
            parentTokenAddress
        );
        LOVE20SLToken slToken = new LOVE20SLToken(
            stakeAddress,
            tokenAddress,
            parentTokenAddress,
            pairAddress,
            MAX_WITHDRAWABLE_TO_FEE_RATIO
        );
        address slAddress = address(slToken);

        // Create LOVE20STToken
        LOVE20STToken stToken = new LOVE20STToken(stakeAddress, tokenAddress);
        address stAddress = address(stToken);

        token.initialize(mintAddress, parentTokenAddress, slAddress, stAddress);

        emit TokenCreate({
            tokenAddress: tokenAddress,
            parentTokenAddress: parentTokenAddress,
            name: name,
            symbol: symbol
        });

        return tokenAddress;
    }
}
