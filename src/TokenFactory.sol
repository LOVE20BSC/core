// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {LOVE20Token} from "./LOVE20Token.sol";
import {ITokenFactory} from "./interfaces/ITokenFactory.sol";

contract TokenFactory is ITokenFactory {
    address public launchAddress;
    address public mintAddress;
    uint256 public LAUNCH_AMOUNT;
    uint256 public MAX_SUPPLY;
    bool public initialized;

    modifier onlyLaunch() {
        if (msg.sender != launchAddress) {
            revert UnauthorizedCaller();
        }
        _;
    }

    function init(
        address launchAddress_,
        address mintAddress_,
        uint256 launchAmount_,
        uint256 maxSupply_
    ) external {
        if (launchAmount_ > maxSupply_) {
            revert InvalidAmount();
        }
        if (initialized) {
            revert AlreadyInitialized();
        }
        if (launchAddress_ == address(0)) {
            revert ZeroAddress("launchAddress");
        }
        if (mintAddress_ == address(0)) {
            revert ZeroAddress("mintAddress");
        }
        initialized = true;
        launchAddress = launchAddress_;
        mintAddress = mintAddress_;
        LAUNCH_AMOUNT = launchAmount_;
        MAX_SUPPLY = maxSupply_;
    }

    function createToken(
        address parentTokenAddress,
        string calldata name,
        string calldata symbol,
        address distributor
    ) external onlyLaunch returns (address tokenAddress) {
        if (!initialized) {
            revert UnauthorizedCaller();
        }
        if (parentTokenAddress == address(0)) {
            revert ZeroAddress("parentTokenAddress");
        }
        if (distributor == address(0)) {
            revert ZeroAddress("distributor");
        }
        if (bytes(name).length == 0) {
            revert EmptyString("name");
        }
        if (bytes(symbol).length == 0) {
            revert EmptyString("symbol");
        }

        LOVE20Token token = new LOVE20Token(
            name,
            symbol,
            LAUNCH_AMOUNT,
            MAX_SUPPLY,
            distributor,
            mintAddress,
            parentTokenAddress
        );
        tokenAddress = address(token);

        emit TokenCreated({
            tokenAddress: tokenAddress,
            parentTokenAddress: parentTokenAddress,
            name: name,
            symbol: symbol,
            distributor: distributor
        });
    }
}
