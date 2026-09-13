// SPDX-License-Identifier: MIT

pragma solidity =0.8.17;

import {ArrayUtils} from "./lib/ArrayUtils.sol";
import {ILOVE20TokenFactory} from "./interfaces/ILOVE20TokenFactory.sol";
import {ILOVE20Token} from "./interfaces/ILOVE20Token.sol";
import {ILOVE20Submit} from "./interfaces/ILOVE20Submit.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ILOVE20Launch, CLAIM_DELAY_BLOCKS, LaunchInfo} from "./interfaces/ILOVE20Launch.sol";
import {EnumerableSet} from "../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {ILOVE20Mint} from "./interfaces/ILOVE20Mint.sol";

contract LOVE20Launch is ILOVE20Launch {
    using EnumerableSet for EnumerableSet.AddressSet;

    // ------ init variables ------
    bool public initialized;
    // used for launchToken
    address public tokenFactoryAddress;
    // used for checking remainingLaunchCount
    address public submitAddress;
    // used for checking remainingLaunchCount
    address public mintAddress;

    uint256 public TOKEN_SYMBOL_LENGTH;
    uint256 public FIRST_PARENT_TOKEN_FUNDRAISING_GOAL;
    uint256 public PARENT_TOKEN_FUNDRAISING_GOAL;
    uint256 public SECOND_HALF_MIN_BLOCKS;
    uint256 public WITHDRAW_WAITING_BLOCKS;
    uint256 public MIN_GOV_REWARD_MINTS_TO_LAUNCH;

    // ------ token variables ------
    address[] internal _tokens;
    mapping(string => address) public tokenAddressBySymbol;
    mapping(address => address[]) internal _childTokens;

    // ----- launch variables -----

    mapping(address => LaunchInfo) internal _launches;
    // tokenAddress => account => contributed
    mapping(address => mapping(address => uint256)) public contributed;
    // tokenAddress => account => lastContributedBlock
    mapping(address => mapping(address => uint256)) public lastContributedBlock;

    // tokenAddress => account => claimed
    mapping(address => mapping(address => bool)) internal _claimed;

    // account => token[]
    mapping(address => EnumerableSet.AddressSet) internal _participatedTokens;

    // parentTokenAddress => launcher => token[] (tokens launched by this account)
    mapping(address => mapping(address => address[]))
        internal _childTokensByLauncher;

    EnumerableSet.AddressSet internal _launchingTokens;
    // parentTokenAddress => tokens
    mapping(address => EnumerableSet.AddressSet) internal _launchingChildTokens;

    EnumerableSet.AddressSet internal _launchedTokens;
    // parentTokenAddress => tokens
    mapping(address => EnumerableSet.AddressSet) internal _launchedChildTokens;

    function launchInfo(
        address tokenAddress
    ) external view returns (LaunchInfo memory info) {
        return _launches[tokenAddress];
    }

    function initialize(
        address tokenFactoryAddress_,
        address submitAddress_,
        address mintAddress_,
        uint256 tokenSymbolLength,
        uint256 firstParentTokenFundraisingGoal,
        uint256 parentTokenFundraisingGoal,
        uint256 secondHalfMinBlocks,
        uint256 withdrawWaitingBlocks,
        uint256 numOfMintGovRewardPerLaunchToken
    ) external {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        tokenFactoryAddress = tokenFactoryAddress_;
        submitAddress = submitAddress_;
        mintAddress = mintAddress_;
        TOKEN_SYMBOL_LENGTH = tokenSymbolLength;
        FIRST_PARENT_TOKEN_FUNDRAISING_GOAL = firstParentTokenFundraisingGoal;
        PARENT_TOKEN_FUNDRAISING_GOAL = parentTokenFundraisingGoal;
        SECOND_HALF_MIN_BLOCKS = secondHalfMinBlocks;
        WITHDRAW_WAITING_BLOCKS = withdrawWaitingBlocks;
        MIN_GOV_REWARD_MINTS_TO_LAUNCH = numOfMintGovRewardPerLaunchToken;
    }

    function launchToken(
        string memory tokenSymbol,
        address parentTokenAddress
    ) external returns (address) {
        // Check parent token and msg.sender, except for the first token
        if (tokensCount() > 0) {
            _checkValidTokenSymbol(tokenSymbol);

            if (!isLOVE20Token(parentTokenAddress)) {
                revert InvalidParentToken();
            }

            if (remainingLaunchCount(parentTokenAddress, msg.sender) == 0) {
                revert NotEligibleToLaunchToken();
            }

            // used for mainnet test: if parent token symbol starts with "Test", then add "Test" to token symbol
            string memory parentSymbol = IERC20Metadata(parentTokenAddress)
                .symbol();
            bytes4 prefix = bytes4(bytes(parentSymbol));
            if (prefix == bytes4("Test")) {
                tokenSymbol = string(abi.encodePacked("Test", tokenSymbol));
            }
        }

        return _launchToken(tokenSymbol, parentTokenAddress);
    }

    function isLOVE20Token(address tokenAddress) public view returns (bool) {
        return _launches[tokenAddress].parentTokenAddress != address(0);
    }

    function _checkValidTokenSymbol(string memory tokenSymbol) internal view {
        bytes1 firstChar = bytes1("A");
        bytes1 lastChar = bytes1("Z");
        bytes1 firstNum = bytes1("0");
        bytes1 lastNum = bytes1("9");

        if (bytes(tokenSymbol).length != TOKEN_SYMBOL_LENGTH) {
            revert InvalidTokenSymbol();
        }
        if (
            !(bytes(tokenSymbol)[0] >= firstChar &&
                bytes(tokenSymbol)[0] <= lastChar)
        ) {
            revert InvalidTokenSymbol();
        }
        for (uint256 i = 1; i < bytes(tokenSymbol).length; i++) {
            if (
                !(bytes(tokenSymbol)[i] >= firstChar &&
                    bytes(tokenSymbol)[i] <= lastChar) &&
                !(bytes(tokenSymbol)[i] >= firstNum &&
                    bytes(tokenSymbol)[i] <= lastNum)
            ) {
                revert InvalidTokenSymbol();
            }
        }
    }

    function contribute(
        address tokenAddress,
        uint256 parentTokenAmount,
        address to
    ) external {
        if (!isLOVE20Token(tokenAddress)) revert InvalidTokenAddress();
        if (parentTokenAmount == 0) revert ZeroContribution();
        if (to == address(0)) revert InvalidToAddress();

        LaunchInfo storage launch = _launches[tokenAddress];

        if (launch.hasEnded) revert LaunchAlreadyEnded();

        IERC20(launch.parentTokenAddress).transferFrom(
            msg.sender,
            address(this),
            parentTokenAmount
        );

        if (contributed[tokenAddress][to] == 0) {
            launch.participantCount += 1;
            _participatedTokens[to].add(tokenAddress);
        }
        launch.totalContributed += parentTokenAmount;
        contributed[tokenAddress][to] += parentTokenAmount;
        lastContributedBlock[tokenAddress][to] = block.number;

        emit Contribute({
            tokenAddress: tokenAddress,
            account: to,
            amount: parentTokenAmount,
            totalContributed: launch.totalContributed,
            participantCount: launch.participantCount
        });

        if (
            launch.secondHalfStartBlock == 0 &&
            launch.totalContributed >= launch.parentTokenFundraisingGoal / 2
        ) {
            launch.secondHalfStartBlock = block.number;
            emit SecondHalfStart({
                tokenAddress: tokenAddress,
                secondHalfStartBlock: block.number,
                totalContributed: launch.totalContributed
            });
        } else if (
            launch.secondHalfStartBlock != 0 &&
            block.number - launch.secondHalfStartBlock >=
            launch.secondHalfMinBlocks &&
            launch.totalContributed >= launch.parentTokenFundraisingGoal
        ) {
            _endLaunch(tokenAddress);
        }
    }

    function withdraw(address tokenAddress) external {
        LaunchInfo storage launch = _launches[tokenAddress];
        if (launch.hasEnded) revert LaunchAlreadyEnded();
        uint256 myContribution = contributed[tokenAddress][msg.sender];
        if (myContribution == 0) revert NoContribution();
        // check if waiting blocks is passed
        if (
            block.number - lastContributedBlock[tokenAddress][msg.sender] <
            WITHDRAW_WAITING_BLOCKS
        ) {
            revert NotEnoughWaitingBlocks();
        }

        // update info
        launch.participantCount -= 1;
        _participatedTokens[msg.sender].remove(tokenAddress);
        launch.totalContributed -= myContribution;
        contributed[tokenAddress][msg.sender] = 0;
        lastContributedBlock[tokenAddress][msg.sender] = 0;

        // transfer parent token to user
        IERC20(launch.parentTokenAddress).transfer(msg.sender, myContribution);

        emit Withdraw({
            tokenAddress: tokenAddress,
            account: msg.sender,
            amount: myContribution
        });
    }

    function _caculateClaimAmounts(
        address tokenAddress,
        address account
    ) internal view returns (uint256 receiveTokenAmount, uint256 extraRefund) {
        LaunchInfo memory launch = _launches[tokenAddress];
        uint256 myContribution = contributed[tokenAddress][account];

        receiveTokenAmount =
            (launch.launchAmount * myContribution) /
            launch.totalContributed;

        extraRefund =
            ((launch.totalContributed - launch.parentTokenFundraisingGoal) *
                myContribution) /
            launch.totalContributed;

        return (receiveTokenAmount, extraRefund);
    }
    function claim(
        address tokenAddress
    ) external returns (uint256 receiveTokenAmount, uint256 extraRefund) {
        LaunchInfo storage launch = _launches[tokenAddress];
        if (!launch.hasEnded) revert LaunchNotEnded();

        if (block.number < launch.endBlock + CLAIM_DELAY_BLOCKS) {
            revert ClaimDelayNotPassed();
        }
        if (_claimed[tokenAddress][msg.sender]) revert TokensAlreadyClaimed();

        (receiveTokenAmount, extraRefund) = _caculateClaimAmounts(
            tokenAddress,
            msg.sender
        );

        if (receiveTokenAmount == 0) revert NoContribution();

        _claimed[tokenAddress][msg.sender] = true;
        launch.totalExtraRefunded += extraRefund;

        IERC20(launch.parentTokenAddress).transfer(msg.sender, extraRefund);

        IERC20(tokenAddress).transfer(msg.sender, receiveTokenAmount);

        emit Claim({
            tokenAddress: tokenAddress,
            account: msg.sender,
            receivedTokenAmount: receiveTokenAmount,
            extraRefund: extraRefund
        });

        return (receiveTokenAmount, extraRefund);
    }

    function claimInfo(
        address tokenAddress,
        address account
    )
        external
        view
        returns (
            uint256 receivedTokenAmount,
            uint256 extraRefund,
            bool isClaimed
        )
    {
        LaunchInfo memory launch = _launches[tokenAddress];
        if (!launch.hasEnded) revert LaunchNotEnded();

        isClaimed = _claimed[tokenAddress][account];

        (receivedTokenAmount, extraRefund) = _caculateClaimAmounts(
            tokenAddress,
            account
        );

        return (receivedTokenAmount, extraRefund, isClaimed);
    }

    function remainingLaunchCount(
        address parentTokenAddress,
        address account
    ) public view returns (uint256 count) {
        if (!isLOVE20Token(parentTokenAddress)) revert InvalidParentToken();

        if (
            !ILOVE20Submit(submitAddress).canSubmit(parentTokenAddress, account)
        ) {
            return 0;
        }

        uint256 countHaveLaunched = childTokensByLauncherCount(
            parentTokenAddress,
            account
        );
        uint256 mintGovRewardCount = ILOVE20Mint(mintAddress)
            .numOfMintGovRewardByAccount(parentTokenAddress, account);

        return
            (mintGovRewardCount / MIN_GOV_REWARD_MINTS_TO_LAUNCH) -
            countHaveLaunched;
    }

    function tokensCount() public view returns (uint256) {
        return _tokens.length;
    }

    function tokensAtIndex(uint256 index) external view returns (address) {
        return _tokens[index];
    }
    function childTokensCount(
        address parentTokenAddress
    ) external view returns (uint256) {
        return _childTokens[parentTokenAddress].length;
    }
    function childTokensAtIndex(
        address parentTokenAddress,
        uint256 index
    ) external view returns (address) {
        return _childTokens[parentTokenAddress][index];
    }

    function launchingTokensCount() external view returns (uint256) {
        return _launchingTokens.length();
    }
    function launchingTokensAtIndex(
        uint256 index
    ) external view returns (address) {
        return _launchingTokens.at(index);
    }
    function launchedTokensCount() external view returns (uint256) {
        return _launchedTokens.length();
    }

    function launchedTokensAtIndex(
        uint256 index
    ) external view returns (address) {
        return _launchedTokens.at(index);
    }

    function launchingChildTokensCount(
        address parentTokenAddress
    ) external view returns (uint256) {
        return _launchingChildTokens[parentTokenAddress].length();
    }
    function launchingChildTokensAtIndex(
        address parentTokenAddress,
        uint256 index
    ) external view returns (address) {
        return _launchingChildTokens[parentTokenAddress].at(index);
    }
    function launchedChildTokensCount(
        address parentTokenAddress
    ) external view returns (uint256) {
        return _launchedChildTokens[parentTokenAddress].length();
    }
    function launchedChildTokensAtIndex(
        address parentTokenAddress,
        uint256 index
    ) external view returns (address) {
        return _launchedChildTokens[parentTokenAddress].at(index);
    }

    function participatedTokensCount(
        address account
    ) external view returns (uint256) {
        return _participatedTokens[account].length();
    }
    function participatedTokensAtIndex(
        address account,
        uint256 index
    ) external view returns (address) {
        return _participatedTokens[account].at(index);
    }

    function childTokensByLauncherCount(
        address parentTokenAddress,
        address launcher
    ) public view returns (uint256) {
        return _childTokensByLauncher[parentTokenAddress][launcher].length;
    }

    function childTokensByLauncherAtIndex(
        address parentTokenAddress,
        address launcher,
        uint256 index
    ) external view returns (address) {
        return _childTokensByLauncher[parentTokenAddress][launcher][index];
    }

    function _launchToken(
        string memory tokenSymbol,
        address parentTokenAddress
    ) private returns (address) {
        if (tokenAddressBySymbol[tokenSymbol] != address(0))
            revert TokenSymbolExists();

        string memory parentTokenSymbol = IERC20Metadata(parentTokenAddress)
            .symbol();
        string memory tokenName = string(
            abi.encodePacked(tokenSymbol, "@", parentTokenSymbol)
        );
        address newTokenAddress = ILOVE20TokenFactory(tokenFactoryAddress)
            .createToken(parentTokenAddress, tokenName, tokenSymbol);

        _tokens.push(newTokenAddress);
        _childTokensByLauncher[parentTokenAddress][msg.sender].push(
            newTokenAddress
        );
        tokenAddressBySymbol[tokenSymbol] = newTokenAddress;
        _childTokens[parentTokenAddress].push(newTokenAddress);

        _startLaunch(newTokenAddress);

        emit LaunchToken({
            tokenAddress: newTokenAddress,
            tokenSymbol: tokenSymbol,
            parentTokenAddress: parentTokenAddress,
            account: msg.sender
        });

        return newTokenAddress;
    }

    function _startLaunch(address token) private {
        if (_launches[token].parentTokenAddress != address(0))
            revert LaunchAlreadyExists();
        address parentTokenAddress = ILOVE20Token(token).parentTokenAddress();
        if (parentTokenAddress == address(0)) revert ParentTokenNotSet();

        LaunchInfo storage launch = _launches[token];
        launch.parentTokenAddress = parentTokenAddress;
        if (token == _tokens[0]) {
            launch
                .parentTokenFundraisingGoal = FIRST_PARENT_TOKEN_FUNDRAISING_GOAL;
        } else {
            launch.parentTokenFundraisingGoal = PARENT_TOKEN_FUNDRAISING_GOAL;
        }
        launch.secondHalfMinBlocks = SECOND_HALF_MIN_BLOCKS;
        launch.launchAmount = ILOVE20TokenFactory(tokenFactoryAddress)
            .LAUNCH_AMOUNT();
        launch.startBlock = block.number;
        launch.hasEnded = false;

        _launchingTokens.add(token);
        _launchingChildTokens[parentTokenAddress].add(token);
    }

    function _endLaunch(address tokenAddress) private {
        LaunchInfo storage launch = _launches[tokenAddress];
        launch.hasEnded = true;
        launch.endBlock = block.number;

        _launchingTokens.remove(tokenAddress);
        _launchingChildTokens[launch.parentTokenAddress].remove(tokenAddress);
        _launchedTokens.add(tokenAddress);
        _launchedChildTokens[launch.parentTokenAddress].add(tokenAddress);

        // transfer parent token to token
        IERC20(launch.parentTokenAddress).transfer(
            tokenAddress,
            launch.parentTokenFundraisingGoal
        );

        emit LaunchEnd({
            tokenAddress: tokenAddress,
            totalContributed: launch.totalContributed,
            participantCount: launch.participantCount,
            endBlock: block.number
        });
    }
}
