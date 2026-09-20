// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {ILOVE20Vote} from "./interfaces/ILOVE20Vote.sol";
import {ILOVE20Verify} from "./interfaces/ILOVE20Verify.sol";
import {ILOVE20Stake} from "./interfaces/ILOVE20Stake.sol";
import {ILOVE20Token} from "./interfaces/ILOVE20Token.sol";
import {ILOVE20Mint} from "./interfaces/ILOVE20Mint.sol";

contract LOVE20Mint is ILOVE20Mint {
    // ------ manage reward ------
    // tokenAddress => reward(managed by prepareReward)
    mapping(address => uint256) public rewardReserved;

    // tokenAddress => rewardMinted (managed by _mintReward)
    mapping(address => uint256) public rewardMinted;

    // tokenAddress => rewardBurned (managed by _burnReward)
    mapping(address => uint256) public rewardBurned;

    // ------ variable for gov reward ------
    // tokenAddress => account => num (managed by mintGovReward)
    mapping(address => mapping(address => uint256))
        public numOfMintGovRewardByAccount;

    // tokenAddress => round => reward
    mapping(address => mapping(uint256 => uint256)) public govReward;

    // tokenAddress => round => bool
    mapping(address => mapping(uint256 => bool))
        public boostRewardBurnCheckeded;

    // tokenAddress => round => account => mintedReward
    mapping(address => mapping(uint256 => mapping(address => uint256)))
        public govRewardMintedByAccount;

    // ------ variable for action reward ------
    // tokenAddress => round => reward
    mapping(address => mapping(uint256 => uint256)) public actionReward;

    // tokenAddress => round => bool
    mapping(address => mapping(uint256 => bool)) public actionRewardBurnChecked;

    // tokenAddress => round => actionId => account => mintedReward
    mapping(address => mapping(uint256 => mapping(uint256 => mapping(address => uint256))))
        public actionRewardMintedByAccount;

    // ------ variable for init ------
    bool public initialized;
    address public voteAddress;
    address public verifyAddress;
    address public stakeAddress;
    uint256 public ACTION_REWARD_MIN_VOTE_PER_THOUSAND;
    uint256 public ROUND_REWARD_GOV_PER_THOUSAND;
    uint256 public ROUND_REWARD_ACTION_PER_THOUSAND;
    uint256 public MAX_GOV_BOOST_REWARD_MULTIPLIER;

    function initialize(
        address voteAddress_,
        address verifyAddress_,
        address stakeAddress_,
        uint256 actionRewardMinVotePerThousand,
        uint256 roundRewardGovPerThousand,
        uint256 roundRewardActionPerThousand,
        uint256 maxGovBoostRewardMultiplier
    ) external {
        if (initialized) {
            revert AlreadyInitialized();
        }
        initialized = true;
        voteAddress = voteAddress_;
        verifyAddress = verifyAddress_;
        stakeAddress = stakeAddress_;
        ACTION_REWARD_MIN_VOTE_PER_THOUSAND = actionRewardMinVotePerThousand;
        ROUND_REWARD_GOV_PER_THOUSAND = roundRewardGovPerThousand;
        ROUND_REWARD_ACTION_PER_THOUSAND = roundRewardActionPerThousand;
        MAX_GOV_BOOST_REWARD_MULTIPLIER = maxGovBoostRewardMultiplier;
    }

    function isActionIdWithReward(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) public view returns (bool) {
        ILOVE20Vote vote = ILOVE20Vote(voteAddress);
        uint256 minVotesWithReward = (ACTION_REWARD_MIN_VOTE_PER_THOUSAND *
            vote.votesNum(tokenAddress, round)) / 1000;
        return
            vote.votesNumByActionId(tokenAddress, round, actionId) >=
            minVotesWithReward;
    }

    function prepareRewardIfNeeded(address tokenAddress) external {
        uint256 round = ILOVE20Verify(verifyAddress).currentRound();

        if (isRewardPrepared(tokenAddress, round)) {
            // already prepared
            return;
        }

        uint256 govRewardAmount = calculateRoundGovReward(tokenAddress);
        govReward[tokenAddress][round] = govRewardAmount;

        uint256 actionRewardAmount = calculateRoundActionReward(tokenAddress);
        actionReward[tokenAddress][round] = actionRewardAmount;

        rewardReserved[tokenAddress] += govRewardAmount + actionRewardAmount;

        emit PrepareReward({
            tokenAddress: tokenAddress,
            round: round,
            govRewardAmount: govRewardAmount,
            actionRewardAmount: actionRewardAmount
        });
    }

    function mintGovReward(
        address tokenAddress,
        uint256 round
    )
        external
        returns (uint256 verifyReward, uint256 boostReward, uint256 burnReward)
    {
        if (ILOVE20Verify(verifyAddress).currentRound() <= round) {
            revert RoundNotReadyToMint();
        }

        _burnBoostRewardIfNeeded(tokenAddress, round);
        _burnActionRewardIfNeeded(tokenAddress, round);

        bool isMinted;
        (verifyReward, boostReward, burnReward, isMinted) = govRewardByAccount(
            tokenAddress,
            round,
            msg.sender
        );
        if (isMinted) {
            revert AlreadyMinted();
        }

        if (verifyReward + boostReward + burnReward == 0) {
            revert NoRewardAvailable();
        }

        uint256 mintAmount = verifyReward + boostReward;

        govRewardMintedByAccount[tokenAddress][round][msg.sender] = mintAmount;
        numOfMintGovRewardByAccount[tokenAddress][msg.sender]++;

        _mintReward(tokenAddress, mintAmount);
        _burnReward(tokenAddress, burnReward);

        emit MintGovReward({
            tokenAddress: tokenAddress,
            round: round,
            account: msg.sender,
            verifyReward: verifyReward,
            boostReward: boostReward,
            burnReward: burnReward
        });

        return (verifyReward, boostReward, burnReward);
    }

    function _burnBoostRewardIfNeeded(
        address tokenAddress,
        uint256 round
    ) internal {
        if (boostRewardBurnCheckeded[tokenAddress][round]) {
            return;
        }
        boostRewardBurnCheckeded[tokenAddress][round] = true;

        if (
            ILOVE20Verify(verifyAddress).stakedAmountOfVerifiers(
                tokenAddress,
                round
            ) > 0
        ) {
            return;
        }

        uint256 burnReward = govBoostReward(tokenAddress, round);

        _burnReward(tokenAddress, burnReward);

        emit BurnBoostReward({
            tokenAddress: tokenAddress,
            round: round,
            burnReward: burnReward
        });
    }

    function _burnActionRewardIfNeeded(
        address tokenAddress,
        uint256 round
    ) internal {
        if (actionRewardBurnChecked[tokenAddress][round]) {
            return;
        }
        actionRewardBurnChecked[tokenAddress][round] = true;

        uint256 totalActionReward = actionReward[tokenAddress][round];
        if (totalActionReward == 0) {
            return;
        }

        uint256 abstentionScore = ILOVE20Verify(verifyAddress)
            .abstentionScoreWithReward(tokenAddress, round);
        uint256 totalScore = ILOVE20Verify(verifyAddress).scoreWithReward(
            tokenAddress,
            round
        );

        if (totalScore != abstentionScore) {
            return;
        }

        _burnReward(tokenAddress, totalActionReward);

        emit BurnActionReward({
            tokenAddress: tokenAddress,
            round: round,
            burnReward: totalActionReward
        });
    }

    function mintActionReward(
        address tokenAddress,
        uint256 round,
        uint256 actionId
    ) external returns (uint256) {
        if (ILOVE20Verify(verifyAddress).currentRound() <= round) {
            revert RoundNotReadyToMint();
        }

        (uint256 reward, bool isMinted) = actionRewardByActionIdByAccount(
            tokenAddress,
            round,
            actionId,
            msg.sender
        );

        if (reward == 0) {
            revert NoRewardAvailable();
        }
        if (isMinted) {
            revert AlreadyMinted();
        }

        actionRewardMintedByAccount[tokenAddress][round][actionId][
            msg.sender
        ] = reward;

        _mintReward(tokenAddress, reward);

        emit MintActionReward({
            tokenAddress: tokenAddress,
            round: round,
            actionId: actionId,
            account: msg.sender,
            reward: reward
        });

        return reward;
    }

    // ------ reward management ------
    function isRewardPrepared(
        address tokenAddress,
        uint256 round
    ) public view returns (bool) {
        return govReward[tokenAddress][round] > 0;
    }

    function rewardAvailable(
        address tokenAddress
    ) public view returns (uint256) {
        ILOVE20Token token = ILOVE20Token(tokenAddress);

        return
            (token.maxSupply() - token.totalSupply()) -
            reservedAvailable(tokenAddress);
    }

    function reservedAvailable(
        address tokenAddress
    ) public view returns (uint256) {
        return
            rewardReserved[tokenAddress] -
            rewardMinted[tokenAddress] -
            rewardBurned[tokenAddress];
    }

    // ------ gov reward ------
    function calculateRoundGovReward(
        address tokenAddress
    ) public view returns (uint256) {
        return
            (rewardAvailable(tokenAddress) * ROUND_REWARD_GOV_PER_THOUSAND) /
            1000;
    }
    function govVerifyReward(
        address tokenAddress,
        uint256 round
    ) public view returns (uint256) {
        return (govReward[tokenAddress][round] / 2);
    }

    function govBoostReward(
        address tokenAddress,
        uint256 round
    ) public view returns (uint256) {
        return (govReward[tokenAddress][round] / 2);
    }

    function _govRewardByAccount(
        address tokenAddress,
        uint256 round,
        address account
    )
        internal
        view
        returns (uint256 verifyReward, uint256 boostReward, uint256 burnReward)
    {
        uint256 totalGovVerifyReward = govVerifyReward(tokenAddress, round);
        if (totalGovVerifyReward == 0) {
            return (0, 0, 0);
        }

        uint256 scores = ILOVE20Verify(verifyAddress).scoreByVerifier(
            tokenAddress,
            round,
            account
        );

        if (scores == 0) {
            return (0, 0, 0);
        }

        uint256 totalScores = ILOVE20Verify(verifyAddress).score(
            tokenAddress,
            round
        );

        // first half reward based on verification scores
        verifyReward = (totalGovVerifyReward * scores) / totalScores;

        // second half reward based on staked amount
        uint256 totalGovBoostReward = govBoostReward(tokenAddress, round);
        uint256 totalStakedAmount = ILOVE20Verify(verifyAddress)
            .stakedAmountOfVerifiers(tokenAddress, round);
        if (totalStakedAmount != 0) {
            uint256 stakedAmount = ILOVE20Stake(stakeAddress)
                .cumulatedTokenAmountByAccount(tokenAddress, round, account);
            uint256 maxBoostReward = (totalGovBoostReward * stakedAmount) /
                totalStakedAmount;
            boostReward = maxBoostReward >
                verifyReward * MAX_GOV_BOOST_REWARD_MULTIPLIER
                ? verifyReward * MAX_GOV_BOOST_REWARD_MULTIPLIER
                : maxBoostReward;

            burnReward = maxBoostReward - boostReward;
        }

        return (verifyReward, boostReward, burnReward);
    }

    // gov reward
    function govRewardByAccount(
        address tokenAddress,
        uint256 round,
        address account
    )
        public
        view
        returns (
            uint256 verifyReward,
            uint256 boostReward,
            uint256 burnReward,
            bool isMinted
        )
    {
        (verifyReward, boostReward, burnReward) = _govRewardByAccount(
            tokenAddress,
            round,
            account
        );

        isMinted = govRewardMintedByAccount[tokenAddress][round][account] > 0;

        return (verifyReward, boostReward, burnReward, isMinted);
    }

    // ------ action reward ------
    function calculateRoundActionReward(
        address tokenAddress
    ) public view returns (uint256) {
        return
            (rewardAvailable(tokenAddress) * ROUND_REWARD_ACTION_PER_THOUSAND) /
            1000;
    }

    function _actionRewardByActionIdByAccount(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        address account
    ) internal view returns (uint256 reward) {
        uint256 totalActionReward = actionReward[tokenAddress][round];
        if (totalActionReward == 0) {
            return 0;
        }

        if (!isActionIdWithReward(tokenAddress, round, actionId)) {
            return 0;
        }

        uint256 score = ILOVE20Verify(verifyAddress).scoreByActionIdByAccount(
            tokenAddress,
            round,
            actionId,
            account
        );
        if (score == 0) {
            return 0;
        }

        uint256 totalScore = ILOVE20Verify(verifyAddress).scoreWithReward(
            tokenAddress,
            round
        );

        uint256 totalAbstentionScore = ILOVE20Verify(verifyAddress)
            .abstentionScoreWithReward(tokenAddress, round);

        return
            (totalActionReward * score) / (totalScore - totalAbstentionScore);
    }

    function actionRewardByActionIdByAccount(
        address tokenAddress,
        uint256 round,
        uint256 actionId,
        address account
    ) public view returns (uint256 reward, bool isMinted) {
        reward = _actionRewardByActionIdByAccount(
            tokenAddress,
            round,
            actionId,
            account
        );
        isMinted =
            actionRewardMintedByAccount[tokenAddress][round][actionId][
                account
            ] >
            0;

        return (reward, isMinted);
    }

    function _mintReward(address tokenAddress, uint256 amount) internal {
        if (reservedAvailable(tokenAddress) < amount) {
            revert NotEnoughReward();
        }

        rewardMinted[tokenAddress] += amount;

        ILOVE20Token token = ILOVE20Token(tokenAddress);
        token.mint(msg.sender, amount);
    }

    function _burnReward(address tokenAddress, uint256 amount) internal {
        if (reservedAvailable(tokenAddress) < amount) {
            revert NotEnoughRewardToBurn();
        }

        rewardBurned[tokenAddress] += amount;
    }
}
