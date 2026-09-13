// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

uint256 constant CLAIM_DELAY_BLOCKS = 1;

struct LaunchInfo {
    address parentTokenAddress;
    uint256 parentTokenFundraisingGoal;
    uint256 secondHalfMinBlocks;
    uint256 launchAmount;
    uint256 startBlock;
    uint256 secondHalfStartBlock;
    uint256 endBlock;
    bool hasEnded;
    uint256 participantCount;
    uint256 totalContributed;
    uint256 totalExtraRefunded;
}
interface ILOVE20LaunchErrors {
    error AlreadyInitialized();
    error InvalidTokenSymbol();
    error TokenSymbolExists();
    error NotEligibleToLaunchToken();
    error LaunchAlreadyEnded();
    error LaunchNotEnded();
    error ClaimDelayNotPassed();
    error NoContribution();
    error NotEnoughWaitingBlocks();
    error TokensAlreadyClaimed();
    error LaunchAlreadyExists();
    error ParentTokenNotSet();
    error ZeroContribution();
    error InvalidTokenAddress();
    error InvalidToAddress();
    error InvalidParentToken();
}

interface ILOVE20LaunchEvents {
    event LaunchToken(
        address indexed tokenAddress,
        string tokenSymbol,
        address indexed parentTokenAddress,
        address indexed account
    );

    event Contribute(
        address indexed tokenAddress,
        address indexed account,
        uint256 amount,
        uint256 totalContributed,
        uint256 participantCount
    );

    event Withdraw(
        address indexed tokenAddress,
        address indexed account,
        uint256 amount
    );

    event Claim(
        address indexed tokenAddress,
        address indexed account,
        uint256 receivedTokenAmount,
        uint256 extraRefund
    );

    event SecondHalfStart(
        address indexed tokenAddress,
        uint256 secondHalfStartBlock,
        uint256 totalContributed
    );

    event LaunchEnd(
        address indexed tokenAddress,
        uint256 totalContributed,
        uint256 participantCount,
        uint256 endBlock
    );
}

interface ILOVE20Launch is ILOVE20LaunchErrors, ILOVE20LaunchEvents {
    function tokenFactoryAddress()
        external
        view
        returns (address factoryAddress);

    function submitAddress() external view returns (address address_);
    function mintAddress() external view returns (address address_);

    function TOKEN_SYMBOL_LENGTH() external view returns (uint256 length);

    function FIRST_PARENT_TOKEN_FUNDRAISING_GOAL()
        external
        view
        returns (uint256 goal);

    function PARENT_TOKEN_FUNDRAISING_GOAL()
        external
        view
        returns (uint256 goal);

    function SECOND_HALF_MIN_BLOCKS() external view returns (uint256 blocks);

    function WITHDRAW_WAITING_BLOCKS() external view returns (uint256 blocks);

    function MIN_GOV_REWARD_MINTS_TO_LAUNCH()
        external
        view
        returns (uint256 mints);

    function isLOVE20Token(address tokenAddress) external view returns (bool);

    function launchToken(
        string memory tokenSymbol,
        address parentTokenAddress
    ) external returns (address tokenAddress);

    function contribute(
        address tokenAddress,
        uint256 parentTokenAmount,
        address to
    ) external;

    function withdraw(address tokenAddress) external;

    function claim(
        address tokenAddress
    ) external returns (uint256 receivedTokenAmount, uint256 extraRefund);

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
        );

    function remainingLaunchCount(
        address parentTokenAddress,
        address account
    ) external view returns (uint256 count);

    function tokensCount() external view returns (uint256 count);
    function tokensAtIndex(
        uint256 index
    ) external view returns (address tokenAddress);

    function childTokensByLauncherCount(
        address parentTokenAddress,
        address account
    ) external view returns (uint256 count);
    function childTokensByLauncherAtIndex(
        address parentTokenAddress,
        address account,
        uint256 index
    ) external view returns (address tokenAddress);

    function childTokensCount(
        address parentTokenAddress
    ) external view returns (uint256 count);

    function childTokensAtIndex(
        address parentTokenAddress,
        uint256 index
    ) external view returns (address tokenAddress);

    function launchingTokensCount() external view returns (uint256 count);

    function launchingTokensAtIndex(
        uint256 index
    ) external view returns (address tokenAddress);

    function launchedTokensCount() external view returns (uint256 count);

    function launchedTokensAtIndex(
        uint256 index
    ) external view returns (address tokenAddress);

    function launchingChildTokensCount(
        address parentTokenAddress
    ) external view returns (uint256 count);

    function launchingChildTokensAtIndex(
        address parentTokenAddress,
        uint256 index
    ) external view returns (address tokenAddress);

    function launchedChildTokensCount(
        address parentTokenAddress
    ) external view returns (uint256 count);

    function launchedChildTokensAtIndex(
        address parentTokenAddress,
        uint256 index
    ) external view returns (address tokenAddress);

    function participatedTokensCount(
        address account
    ) external view returns (uint256 count);

    function participatedTokensAtIndex(
        address account,
        uint256 index
    ) external view returns (address tokenAddress);

    function tokenAddressBySymbol(
        string memory symbol
    ) external view returns (address tokenAddress);

    function launchInfo(
        address tokenAddress
    ) external view returns (LaunchInfo memory info);

    function contributed(
        address tokenAddress,
        address account
    ) external view returns (uint256 amount);

    function lastContributedBlock(
        address tokenAddress,
        address account
    ) external view returns (uint256 blockNumber);
}
