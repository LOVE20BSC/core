// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

interface ILOVE20MintEvents {
    // ------ Events ------
    event PrepareReward(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 govRewardAmount,
        uint256 actionRewardAmount
    );

    event MintGovReward(
        address indexed tokenAddress,
        uint256 indexed round,
        address indexed account,
        uint256 verifyReward,
        uint256 boostReward,
        uint256 burnReward
    );

    event MintActionReward(
        address indexed tokenAddress,
        uint256 round,
        uint256 indexed actionId,
        address indexed account,
        uint256 reward
    );

    event BurnActionReward(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 burnReward
    );

    event BurnBoostReward(
        address indexed tokenAddress,
        uint256 indexed round,
        uint256 burnReward
    );
}

interface ILOVE20MintErrors {
    error AlreadyInitialized();
    error NoRewardAvailable();
    error AlreadyMinted();
    error RoundNotReadyToMint();
    error NotEnoughReward();
    error NotEnoughRewardToBurn();
}

interface ILOVE20Mint is ILOVE20MintEvents, ILOVE20MintErrors {
    function voteAddress() external view returns (address);
    function verifyAddress() external view returns (address);
    function stakeAddress() external view returns (address);
    function ACTION_REWARD_MIN_VOTE_PER_THOUSAND()
        external
        view
        returns (uint256);
    function ROUND_REWARD_GOV_PER_THOUSAND() external view returns (uint256);
    function ROUND_REWARD_ACTION_PER_THOUSAND() external view returns (uint256);
    function MAX_GOV_BOOST_REWARD_MULTIPLIER() external view returns (uint256);

    function isActionIdWithReward(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external view returns (bool);

    function rewardReserved(
        address tokenAddress
    ) external view returns (uint256);
    function rewardMinted(address tokenAddress) external view returns (uint256);
    function rewardBurned(address tokenAddress) external view returns (uint256);

    function prepareRewardIfNeeded(address tokenAddress) external;

    function mintGovReward(
        address tokenAddress,
        uint256 round
    )
        external
        returns (uint256 verifyReward, uint256 boostReward, uint256 burnReward);

    function mintActionReward(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external returns (uint256);

    function isRewardPrepared(
        address tokenAddress,
        uint256 round
    ) external view returns (bool);

    function rewardAvailable(
        address tokenAddress
    ) external view returns (uint256);

    function reservedAvailable(
        address tokenAddress
    ) external view returns (uint256);

    function calculateRoundGovReward(
        address tokenAddress
    ) external view returns (uint256);

    function govReward(
        address tokenAddress,
        uint256 round
    ) external view returns (uint256);

    function boostRewardBurnCheckeded(
        address tokenAddress,
        uint256 round
    ) external view returns (bool);

    function govRewardMintedByAccount(
        address tokenAddress,
        uint256 round,
        address account
    ) external view returns (uint256);

    function govVerifyReward(
        address tokenAddress,
        uint256 round
    ) external view returns (uint256);

    function govBoostReward(
        address tokenAddress,
        uint256 round
    ) external view returns (uint256);

    function govRewardByAccount(
        address tokenAddress,
        uint256 round,
        address account
    )
        external
        view
        returns (
            uint256 verifyReward,
            uint256 boostReward,
            uint256 burnReward,
            bool isMinted
        );

    function calculateRoundActionReward(
        address tokenAddress
    ) external view returns (uint256);

    function actionReward(
        address tokenAddress,
        uint256 round
    ) external view returns (uint256);

    function actionRewardBurnChecked(
        address tokenAddress,
        uint256 round
    ) external view returns (bool);

    function actionRewardMintedByAccount(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        address account
    ) external view returns (uint256);

    function actionRewardByActionIdByAccount(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        address account
    ) external view returns (uint256 reward, bool isMinted);

    function numOfMintGovRewardByAccount(
        address tokenAddress,
        address account
    ) external view returns (uint256);
}
