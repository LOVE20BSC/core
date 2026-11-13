// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Script} from "@forge-std/Script.sol";
import {console2} from "@forge-std/console2.sol";
import {AirdropDistributor} from "../../src/distributor/AirdropDistributor.sol";
import {IAirdropDistributor} from "../../src/interfaces/distributor/IAirdropDistributor.sol";
import {MemberNFT} from "../../src/MemberNFT.sol";
import {Phase} from "../../src/Phase.sol";
import {Launch} from "../../src/Launch.sol";
import {Mint} from "../../src/Mint.sol";
import {Vote} from "../../src/Vote.sol";
import {Submit} from "../../src/Submit.sol";
import {Stake, DexConfig} from "../../src/Stake.sol";
import {IMemberNFT} from "../../src/interfaces/IMemberNFT.sol";
import {IPhase} from "../../src/interfaces/IPhase.sol";
import {ILaunch, LaunchInitParams} from "../../src/interfaces/ILaunch.sol";
import {IMint} from "../../src/interfaces/IMint.sol";
import {IStake} from "../../src/interfaces/IStake.sol";
import {ISubmit} from "../../src/interfaces/ISubmit.sol";
import {IVote} from "../../src/interfaces/IVote.sol";
import {ILOVE20Token} from "../../src/interfaces/ILOVE20Token.sol";
import {IUniswapV2Factory} from "../../src/interfaces/UniswapV2/IUniswapV2Factory.sol";

// The deploy script reads only the root parent token and the Factory from the Router; the Router
// interface Stake actually calls lives in src/interfaces/UniswapV2/.
interface IUniswapV2RouterWeth {
    function WETH() external view returns (address);
    function factory() external view returns (address);
}

contract DeployCore is Script {
    // The settlement ratio must not exceed the pool fee, so a single settlement's execution price is
    // at most one fee worse (the spot price moves about twice that) and a round trip cannot beat two.
    // Bound at 0.25%, below the pool fee. Precision is 1e18.
    uint256 internal constant MAX_FEE_SETTLEMENT_RATIO = 2.5e15;
    // Pre-broadcast copies of the same constants in Launch: a child symbol plus the "Test" prefix
    // must still fit the symbol limit. _validateDeployment asserts both copies are equal afterwards,
    // so a drift between the two contracts cannot pass unnoticed.
    uint256 internal constant MAX_TOKEN_SYMBOL_LENGTH = 32;
    uint256 internal constant TEST_PREFIX_BYTES = 4;
    // Copies of the AirdropDistributor compile-time constants: the genesis share denominator must
    // stay comparable to LAUNCH_AMOUNT (see _validateConfig) and the claim delay must stay inside
    // the contract's own bound. _validateDeployment asserts both copies are equal afterwards.
    uint256 internal constant TOTAL_SHARE = 1e18;
    uint256 internal constant MAX_CLAIM_DELAY_ROUNDS = 1000;
    struct DeploymentAddresses {
        address token;
        address airdropDistributor;
        address memberNFT;
        address phase;
        address launch;
        address mint;
        address vote;
        address submit;
        address stake;
    }

    struct CoreConfig {
        uint256 chainId;
        bytes32 genesisMerkleRoot;
        uint256 genesisClaimDelayRounds;
        string tokenName;
        string tokenSymbol;
        uint256 memberBaseDivisor;
        uint256 memberBytesThreshold;
        uint256 memberMultiplier;
        uint256 memberMaxNameLength;
        uint256 phaseOriginBlocks;
        uint256 phaseOriginPhaseBlocks;
        uint256 phaseTargetSeconds;
        uint256 phaseAdjustThreshold;
        uint256 phaseSyncObservationLimit;
        uint256 launchCountThresholdRatio;
        uint256 maxLaunchCount;
        uint256 tokenSymbolLength;
        uint256 launchAmount;
        uint256 maxSupply;
        uint256 proposalRewardMinVoteRatio;
        uint256 roundRewardGovRatio;
        uint256 roundRewardProposalRatio;
        uint256 boostStakeSupplyFactor;
        uint256 boostStakeMultiplier;
        DexConfig dexConfig;
        uint256 submitMinRatio;
        uint256 promisedWaitingPhasesMin;
        uint256 promisedWaitingPhasesMax;
        uint256 feeSettlementRatio;
    }

    function run() external returns (DeploymentAddresses memory addrs) {
        CoreConfig memory config = _loadConfig();
        _validateConfig(config);
        address rootParent = IUniswapV2RouterWeth(config.dexConfig.router).WETH();

        vm.startBroadcast();
        addrs = _deployContracts(config, rootParent);
        vm.stopBroadcast();

        _validateDeployment(config, rootParent, addrs);
        _logDeploymentSummary(addrs);
    }

    function _loadConfig() internal view returns (CoreConfig memory config) {
        config.chainId = vm.envUint("CHAIN_ID");
        config.genesisMerkleRoot = vm.envBytes32("GENESIS_AIRDROP_MERKLE_ROOT");
        config.genesisClaimDelayRounds = vm.envUint("GENESIS_AIRDROP_CLAIM_DELAY_ROUNDS");
        config.tokenName = vm.envString("TOKEN_NAME");
        config.tokenSymbol = vm.envString("TOKEN_SYMBOL");
        config.memberBaseDivisor = vm.envUint("MEMBER_BASE_DIVISOR");
        config.memberBytesThreshold = vm.envUint("MEMBER_BYTES_THRESHOLD");
        config.memberMultiplier = vm.envUint("MEMBER_MULTIPLIER");
        config.memberMaxNameLength = vm.envUint("MEMBER_MAX_NAME_LENGTH");
        config.phaseOriginBlocks = vm.envUint("PHASE_ORIGIN_BLOCKS");
        config.phaseOriginPhaseBlocks = vm.envUint("PHASE_ORIGIN_PHASE_BLOCKS");
        config.phaseTargetSeconds = vm.envUint("PHASE_TARGET_SECONDS");
        config.phaseAdjustThreshold = vm.envUint("PHASE_ADJUST_THRESHOLD");
        config.phaseSyncObservationLimit = vm.envUint("PHASE_SYNC_OBSERVATION_LIMIT");
        config.launchCountThresholdRatio = vm.envUint("LAUNCH_COUNT_THRESHOLD_RATIO");
        config.maxLaunchCount = vm.envUint("MAX_LAUNCH_COUNT");
        config.tokenSymbolLength = vm.envUint("TOKEN_SYMBOL_LENGTH");
        config.launchAmount = vm.envUint("LAUNCH_AMOUNT");
        config.maxSupply = vm.envUint("MAX_SUPPLY");
        config.proposalRewardMinVoteRatio = vm.envUint("PROPOSAL_REWARD_MIN_VOTE_RATIO");
        config.roundRewardGovRatio = vm.envUint("ROUND_REWARD_GOV_RATIO");
        config.roundRewardProposalRatio = vm.envUint("ROUND_REWARD_PROPOSAL_RATIO");
        config.boostStakeSupplyFactor = vm.envUint("BOOST_STAKE_SUPPLY_FACTOR");
        config.boostStakeMultiplier = vm.envUint("BOOST_STAKE_MULTIPLIER");
        config.dexConfig = DexConfig({
            router: vm.envAddress("ROUTER_ADDRESS"),
            pairFactory: vm.envAddress("FACTORY_ADDRESS"),
            swapFeeForLpRatio: vm.envUint("SWAP_FEE_FOR_LP_RATIO"),
            swapFeeForProtocolRatio: vm.envUint("SWAP_FEE_FOR_PROTOCOL_RATIO")
        });
        config.submitMinRatio = vm.envUint("SUBMIT_MIN_RATIO");
        config.promisedWaitingPhasesMin = vm.envUint("PROMISED_WAITING_PHASES_MIN");
        config.promisedWaitingPhasesMax = vm.envUint("PROMISED_WAITING_PHASES_MAX");
        config.feeSettlementRatio = vm.envUint("FEE_SETTLEMENT_RATIO");
    }

    function _validateConfig(CoreConfig memory config) internal view {
        require(block.chainid == config.chainId, "Chain ID mismatch");

        require(config.memberBaseDivisor != 0, "Member NFT base divisor must be nonzero");
        require(config.memberBytesThreshold != 0, "Member NFT bytes threshold must be nonzero");
        require(config.memberMultiplier != 0, "Member NFT multiplier must be nonzero");
        require(config.memberMaxNameLength != 0, "Member NFT max name length must be nonzero");

        require(config.phaseOriginBlocks != 0, "Phase origin blocks must be nonzero");
        require(config.phaseOriginPhaseBlocks != 0, "Phase origin phase blocks must be nonzero");
        require(config.phaseTargetSeconds != 0, "Phase target seconds must be nonzero");
        require(
            config.phaseAdjustThreshold != 0 && config.phaseAdjustThreshold <= 1e18,
            "Phase adjust threshold out of range"
        );
        require(config.phaseSyncObservationLimit != 0, "Phase observation limit must be nonzero");

        require(config.genesisMerkleRoot != bytes32(0), "Genesis merkle root must be nonzero");
        require(
            config.genesisClaimDelayRounds <= MAX_CLAIM_DELAY_ROUNDS,
            "Genesis claim delay rounds exceed MAX_CLAIM_DELAY_ROUNDS"
        );
        require(bytes(config.tokenName).length != 0, "Token name must be nonempty");
        require(bytes(config.tokenSymbol).length != 0, "Token symbol must be nonempty");
        require(
            config.launchCountThresholdRatio != 0 && config.launchCountThresholdRatio <= 1e18,
            "Launch count threshold ratio out of range"
        );
        require(config.maxLaunchCount != 0, "Max launch count must be nonzero");
        require(config.tokenSymbolLength != 0, "Token symbol length must be nonzero");
        require(
            config.tokenSymbolLength + TEST_PREFIX_BYTES <= MAX_TOKEN_SYMBOL_LENGTH,
            "Token symbol length leaves no room for the Test prefix"
        );
        // LAUNCH_AMOUNT >= TOTAL_SHARE is load-bearing for AirdropDistributor: it has no amount == 0
        // check on claim because amount = floor(balance * share / remainingShare) >= 1 whenever
        // share >= 1, remainingShare <= 1e18 and the balance is at least LAUNCH_AMOUNT.
        require(
            config.launchAmount >= TOTAL_SHARE && config.launchAmount <= config.maxSupply,
            "Launch amount out of range"
        );

        require(config.proposalRewardMinVoteRatio <= 1e18, "Proposal threshold exceeds 1e18");
        require(config.roundRewardGovRatio <= 1e18, "Round reward gov ratio exceeds 1e18");
        require(
            config.roundRewardProposalRatio <= 1e18 - config.roundRewardGovRatio,
            "Round reward ratios exceed 1e18"
        );
        require(config.boostStakeSupplyFactor != 0, "Boost stake supply factor must be nonzero");
        require(config.boostStakeMultiplier != 0, "Boost stake multiplier must be nonzero");
        // The DEX fee profile: the pair keeps `lp`, the DEX protocol takes `protocol`, and their sum
        // is the swap fee. Stake derives the `_mintFee` split from the same two numbers, so a wrong
        // profile silently shifts the protocol-fee prediction and eats staker principal.
        require(config.dexConfig.swapFeeForLpRatio != 0, "SWAP_FEE_FOR_LP_RATIO must be nonzero");
        require(
            config.dexConfig.swapFeeForProtocolRatio < config.dexConfig.swapFeeForLpRatio,
            "SWAP_FEE_FOR_PROTOCOL_RATIO must be below SWAP_FEE_FOR_LP_RATIO"
        );

        require(config.submitMinRatio != 0 && config.submitMinRatio <= 1e18, "Submit min ratio out of range");

        require(config.promisedWaitingPhasesMin != 0, "Promised waiting phases min must be nonzero");
        require(
            config.promisedWaitingPhasesMin <= config.promisedWaitingPhasesMax,
            "Promised waiting phases range is invalid"
        );
        require(config.feeSettlementRatio != 0, "Fee settlement ratio must be nonzero");
        require(
            config.feeSettlementRatio <= MAX_FEE_SETTLEMENT_RATIO,
            "Fee settlement ratio exceeds MAX_FEE_SETTLEMENT_RATIO (0.25%)"
        );

        // DEX dependencies must be deployed contracts from the same deployment. The root parent
        // token is read from Router.WETH() and not registered again in core.params. The Factory is
        // used by Launch/Stake to create pools and the Router by the withdrawal swap; a mismatch
        // between them does not revert during simulation and would broadcast 9 contracts for
        // nothing (21_check.sh would only catch it afterwards).
        require(config.dexConfig.pairFactory.code.length != 0, "Factory must be a deployed contract");
        require(config.dexConfig.router.code.length != 0, "Router must be a deployed contract");
        require(
            IUniswapV2RouterWeth(config.dexConfig.router).factory() == config.dexConfig.pairFactory,
            "Router.factory must match FACTORY_ADDRESS"
        );
        require(
            IUniswapV2RouterWeth(config.dexConfig.router).WETH().code.length != 0, "WETH must be a deployed contract"
        );
        // Stake accounts for the DEX's protocol fee when one is configured (it replicates the pair's
        // `_mintFee` so the denominators match what `pair.burn` actually pays). Reading it here makes
        // the deployment surface explicit instead of silently depending on `feeTo == address(0)`.
        // Low-level on purpose: `try`/`catch` does not catch an ABI-decoding failure, so a factory
        // without the getter would revert here instead of being treated as "no protocol fee".
        (bool feeToOk, bytes memory feeToData) =
            config.dexConfig.pairFactory.staticcall(abi.encodeWithSelector(IUniswapV2Factory.feeTo.selector));
        if (feeToOk && feeToData.length >= 32) {
            // `feeTo` is an address returned in a 32-byte word; the low 160 bits are the value.
            // forge-lint: disable-next-line(unsafe-typecast)
            address feeTo = address(uint160(abi.decode(feeToData, (uint256))));
            require(feeTo == address(0) || feeTo.code.length != 0, "feeTo must be zero or a contract");
        }
    }

    struct PredictedAddresses {
        address airdropDistributor;
        address launch;
        address memberNFT;
        address vote;
        address mint;
        address genesisToken;
    }

    function _deployContracts(CoreConfig memory config, address rootParent)
        internal
        returns (DeploymentAddresses memory addrs)
    {
        PredictedAddresses memory predicted = _predictAddresses();

        addrs.phase = address(_deployPhase(config));
        console2.log("Phase deployed at:", addrs.phase);

        addrs.airdropDistributor = _deployAirdropDistributor(config, addrs.phase, predicted);
        console2.log("AirdropDistributor deployed at:", addrs.airdropDistributor);

        LaunchInitParams memory launchParams = LaunchInitParams({
            mintAddress: predicted.mint,
            memberNFTAddress: predicted.memberNFT,
            rootParentTokenAddress: rootParent,
            pairFactoryAddress: config.dexConfig.pairFactory,
            launchCountThresholdRatio: config.launchCountThresholdRatio,
            maxLaunchCount: config.maxLaunchCount,
            tokenSymbolLength: config.tokenSymbolLength,
            launchAmount: config.launchAmount,
            maxSupply: config.maxSupply,
            distributor: addrs.airdropDistributor,
            name: config.tokenName,
            symbol: config.tokenSymbol
        });
        addrs.launch = address(new Launch(launchParams));
        require(addrs.launch == predicted.launch, "Launch address differs from the prediction");
        console2.log("Launch deployed at:", addrs.launch);
        addrs.token = Launch(addrs.launch).FIRST_TOKEN_ADDRESS();
        require(addrs.token == predicted.genesisToken, "First token address differs from the prediction");
        console2.log("First LOVE20Token created at:", addrs.token);

        addrs.memberNFT = address(_deployMemberNFT(config, addrs.token));
        require(addrs.memberNFT == predicted.memberNFT, "MemberNFT address differs from the prediction");
        console2.log("MemberNFT deployed at:", addrs.memberNFT);

        addrs.stake = address(
            new Stake(
                addrs.phase,
                addrs.memberNFT,
                predicted.vote,
                addrs.launch,
                config.dexConfig,
                config.promisedWaitingPhasesMin,
                config.promisedWaitingPhasesMax,
                config.feeSettlementRatio,
                config.boostStakeSupplyFactor,
                config.boostStakeMultiplier
            )
        );
        console2.log("Stake deployed at:", addrs.stake);

        addrs.submit = address(new Submit(addrs.phase, addrs.stake, addrs.memberNFT, config.submitMinRatio));
        console2.log("Submit deployed at:", addrs.submit);

        addrs.vote = address(new Vote(addrs.phase, addrs.stake, addrs.submit, addrs.memberNFT));
        require(addrs.vote == predicted.vote, "Vote address differs from the prediction");
        require(IStake(addrs.stake).VOTE_ADDRESS() == addrs.vote, "Stake vote address differs from the prediction");
        console2.log("Vote deployed at:", addrs.vote);

        addrs.mint = address(
            new Mint(
                addrs.phase,
                addrs.vote,
                addrs.submit,
                addrs.launch,
                addrs.memberNFT,
                config.proposalRewardMinVoteRatio,
                config.roundRewardGovRatio,
                config.roundRewardProposalRatio
            )
        );
        require(addrs.mint == predicted.mint, "Mint address differs from the prediction");
        require(ILOVE20Token(addrs.token).MINTER() == addrs.mint, "First token minter differs from Mint");
        require(ILaunch(addrs.launch).MINT_ADDRESS() == addrs.mint, "Launch mint address differs from Mint");
        console2.log("Mint deployed at:", addrs.mint);
    }

    // Deployment order is fixed: Phase (nonce+0), AirdropDistributor (+1), Launch (+2), MemberNFT
    // (+3), Stake (+4), Submit (+5), Vote (+6), Mint (+7). Each contract below requires the address
    // it was predicted at, so any drift in the broadcast order fails the whole run instead of
    // leaving a half-bound deployment on chain.
    /// @dev The AirdropDistributor is configured with the genesis token and merkle root at
    ///      construction time, so it is deployed before the Launch that creates that token: both
    ///      addresses come from the prediction and are reconciled here.
    ///
    ///      The constructor records `clamp(currentPhase()) + delay`, and it may observe a
    ///      different phase than the reads around this call: every deployment is its own
    ///      transaction, so a phase boundary can fall inside the broadcast window. Bracket the
    ///      phase instead of sampling it once — rounds only increase, so the constructor's round
    ///      lies in `[phaseBefore, phaseAfter]`, and that interval is a single round for any
    ///      deployment that does not straddle a boundary.
    function _deployAirdropDistributor(
        CoreConfig memory config,
        address phaseAddress,
        PredictedAddresses memory predicted
    ) private returns (address airdropDistributor) {
        uint256 phaseBefore = IPhase(phaseAddress).currentPhase();
        airdropDistributor = address(
            new AirdropDistributor(
                predicted.launch,
                phaseAddress,
                predicted.genesisToken,
                config.genesisMerkleRoot,
                config.genesisClaimDelayRounds
            )
        );
        require(
            airdropDistributor == predicted.airdropDistributor,
            "AirdropDistributor address differs from the prediction"
        );
        uint256 phaseAfter = IPhase(phaseAddress).currentPhase();
        uint256 claimableFromRound =
            IAirdropDistributor(airdropDistributor).airdropInfo(predicted.genesisToken).claimableFromRound;
        require(
            claimableFromRound >= (phaseBefore == 0 ? 1 : phaseBefore) + config.genesisClaimDelayRounds
                && claimableFromRound
                    <= (phaseAfter == 0 ? 1 : phaseAfter) + config.genesisClaimDelayRounds,
            "AirdropDistributor genesis claim round mismatch"
        );
    }

    function _predictAddresses() private view returns (PredictedAddresses memory predicted) {
        address creator = _predictor();
        uint256 nonce = vm.getNonce(creator);
        predicted.airdropDistributor = vm.computeCreateAddress(creator, nonce + 1);
        predicted.launch = vm.computeCreateAddress(creator, nonce + 2);
        predicted.memberNFT = vm.computeCreateAddress(creator, nonce + 3);
        predicted.vote = vm.computeCreateAddress(creator, nonce + 6);
        predicted.mint = vm.computeCreateAddress(creator, nonce + 7);
        // Launch's constructor performs exactly one CREATE (the genesis LOVE20Token); factory.createPair
        // is an external call and does not consume Launch's nonce, so the token is nonce 1.
        predicted.genesisToken = vm.computeCreateAddress(predicted.launch, 1);
        require(
            predicted.airdropDistributor != address(0) && predicted.launch != address(0)
                && predicted.memberNFT != address(0) && predicted.vote != address(0)
                && predicted.mint != address(0) && predicted.genesisToken != address(0),
            "Predicted address is zero"
        );
    }

    function _predictor() internal view virtual returns (address) {
        return msg.sender;
    }

    function _deployMemberNFT(CoreConfig memory config, address firstToken) private returns (MemberNFT) {
        return new MemberNFT(
            config.memberBaseDivisor,
            config.memberBytesThreshold,
            config.memberMultiplier,
            config.memberMaxNameLength,
            firstToken
        );
    }

    function _deployPhase(CoreConfig memory config) private returns (Phase) {
        return new Phase(
            config.phaseOriginBlocks,
            config.phaseOriginPhaseBlocks,
            config.phaseTargetSeconds,
            config.phaseAdjustThreshold,
            config.phaseSyncObservationLimit
        );
    }

    function _validateDeployment(CoreConfig memory config, address rootParent, DeploymentAddresses memory addrs)
        internal
        view
    {
        require(addrs.token.code.length != 0, "LOVE20Token is not a contract");
        require(addrs.airdropDistributor.code.length != 0, "AirdropDistributor is not a contract");
        require(addrs.memberNFT.code.length != 0, "MemberNFT is not a contract");
        require(addrs.phase.code.length != 0, "Phase is not a contract");
        require(addrs.launch.code.length != 0, "Launch is not a contract");
        require(addrs.mint.code.length != 0, "Mint is not a contract");
        require(addrs.vote.code.length != 0, "Vote is not a contract");
        require(addrs.submit.code.length != 0, "Submit is not a contract");
        require(addrs.stake.code.length != 0, "Stake is not a contract");

        ILOVE20Token token = ILOVE20Token(addrs.token);
        require(keccak256(bytes(token.name())) == keccak256(bytes(config.tokenName)), "Token name mismatch");
        require(keccak256(bytes(token.symbol())) == keccak256(bytes(config.tokenSymbol)), "Token symbol mismatch");
        require(token.MAX_SUPPLY() == config.maxSupply, "Token max supply mismatch");
        require(token.MINTER() == addrs.mint, "Token minter mismatch");
        require(token.PARENT_TOKEN_ADDRESS() == rootParent, "Token parent mismatch");
        require(token.totalSupply() == config.launchAmount, "Token launch amount mismatch");
        // forge-lint: disable-next-item(incorrect-strict-equality)
        require(
            token.balanceOf(addrs.airdropDistributor) == config.launchAmount,
            "Token distributor balance mismatch"
        );

        _validateAirdropDistributor(config, addrs);

        IMemberNFT memberNFT = IMemberNFT(addrs.memberNFT);
        require(memberNFT.LOVE20_TOKEN_ADDRESS() == addrs.token, "MemberNFT token mismatch");
        require(memberNFT.BASE_DIVISOR() == config.memberBaseDivisor, "MemberNFT base divisor mismatch");
        require(memberNFT.BYTES_THRESHOLD() == config.memberBytesThreshold, "MemberNFT bytes threshold mismatch");
        require(memberNFT.MULTIPLIER() == config.memberMultiplier, "MemberNFT multiplier mismatch");
        require(memberNFT.MAX_NAME_LENGTH() == config.memberMaxNameLength, "MemberNFT max name length mismatch");

        IPhase phase = IPhase(addrs.phase);
        require(phase.ORIGIN_BLOCKS() == config.phaseOriginBlocks, "Phase origin blocks mismatch");
        require(
            phase.ORIGIN_PHASE_BLOCKS() == config.phaseOriginPhaseBlocks,
            "Phase origin phase blocks mismatch"
        );
        require(phase.TARGET_SECONDS() == config.phaseTargetSeconds, "Phase target seconds mismatch");
        require(phase.ADJUST_THRESHOLD() == config.phaseAdjustThreshold, "Phase adjust threshold mismatch");
        require(
            phase.SYNC_OBSERVATION_LIMIT() == config.phaseSyncObservationLimit,
            "Phase observation limit mismatch"
        );

        ILaunch launch = ILaunch(addrs.launch);
        require(launch.MINT_ADDRESS() == addrs.mint, "Launch mint mismatch");
        require(launch.MEMBER_NFT_ADDRESS() == addrs.memberNFT, "Launch member NFT mismatch");
        require(launch.ROOT_PARENT_TOKEN_ADDRESS() == rootParent, "Launch root parent mismatch");
        require(launch.FIRST_TOKEN_ADDRESS() == addrs.token, "Launch first token mismatch");
        require(launch.PAIR_FACTORY_ADDRESS() == config.dexConfig.pairFactory, "Launch pair factory mismatch");
        require(
            launch.LAUNCH_COUNT_THRESHOLD_RATIO() == config.launchCountThresholdRatio,
            "Launch count threshold ratio mismatch"
        );
        require(launch.MAX_LAUNCH_COUNT() == config.maxLaunchCount, "Launch max count mismatch");
        require(launch.TOKEN_SYMBOL_LENGTH() == config.tokenSymbolLength, "Launch symbol length mismatch");
        require(
            launch.MAX_TOKEN_SYMBOL_LENGTH() == MAX_TOKEN_SYMBOL_LENGTH,
            "Launch max token symbol length mismatch"
        );
        require(launch.TEST_PREFIX_BYTES() == TEST_PREFIX_BYTES, "Launch test prefix length mismatch");
        require(launch.LAUNCH_AMOUNT() == config.launchAmount, "Launch amount mismatch");
        require(launch.MAX_SUPPLY() == config.maxSupply, "Launch max supply mismatch");

        require(launch.isLOVE20Token(addrs.token), "Launch first token not registered");
        require(launch.parentToken(addrs.token) == rootParent, "Launch first token parent mismatch");
        require(
            launch.tokenAddressBySymbol(config.tokenSymbol) == addrs.token, "Launch first token symbol mismatch"
        );
        (address[] memory tokenList, uint256 tokenCount) = launch.tokens(0, 1, false);
        require(tokenCount == 1 && tokenList.length == 1 && tokenList[0] == addrs.token, "Launch token list mismatch");
        (address[] memory childList, uint256 childCount) = launch.childTokens(rootParent, 0, 1, false);
        require(childCount == 1 && childList.length == 1 && childList[0] == addrs.token, "Launch child list mismatch");
        require(
            IUniswapV2Factory(config.dexConfig.pairFactory).getPair(addrs.token, rootParent) != address(0),
            "First token pair missing"
        );

        IMint mint = IMint(addrs.mint);
        require(mint.VOTE_ADDRESS() == addrs.vote, "Mint vote mismatch");
        require(mint.SUBMIT_ADDRESS() == addrs.submit, "Mint submit mismatch");
        require(mint.LAUNCH_ADDRESS() == addrs.launch, "Mint launch mismatch");
        require(mint.MEMBER_NFT_ADDRESS() == addrs.memberNFT, "Mint member NFT mismatch");
        require(mint.PHASE_ADDRESS() == addrs.phase, "Mint phase mismatch");
        require(
            mint.PROPOSAL_REWARD_MIN_VOTE_RATIO() == config.proposalRewardMinVoteRatio,
            "Mint proposal threshold mismatch"
        );
        require(mint.ROUND_REWARD_GOV_RATIO() == config.roundRewardGovRatio, "Mint gov ratio mismatch");
        require(
            mint.ROUND_REWARD_PROPOSAL_RATIO() == config.roundRewardProposalRatio,
            "Mint proposal ratio mismatch"
        );

        IStake stake = IStake(addrs.stake);
        require(stake.PHASE_ADDRESS() == addrs.phase, "Stake phase mismatch");
        require(stake.MEMBER_NFT_ADDRESS() == addrs.memberNFT, "Stake member NFT mismatch");
        require(stake.VOTE_ADDRESS() == addrs.vote, "Stake vote mismatch");
        require(stake.LAUNCH_ADDRESS() == addrs.launch, "Stake launch mismatch");
        require(stake.ROUTER_ADDRESS() == config.dexConfig.router, "Stake router mismatch");
        require(stake.PAIR_FACTORY_ADDRESS() == config.dexConfig.pairFactory, "Stake pair factory mismatch");
        require(
            stake.PROMISED_WAITING_PHASES_MIN() == config.promisedWaitingPhasesMin,
            "Stake waiting phases min mismatch"
        );
        require(
            stake.PROMISED_WAITING_PHASES_MAX() == config.promisedWaitingPhasesMax,
            "Stake waiting phases max mismatch"
        );
        require(
            stake.FEE_SETTLEMENT_RATIO() == config.feeSettlementRatio, "Stake fee settlement ratio mismatch"
        );
        require(
            stake.BOOST_STAKE_SUPPLY_FACTOR() == config.boostStakeSupplyFactor,
            "Stake boost supply factor mismatch"
        );
        require(
            stake.BOOST_STAKE_MULTIPLIER() == config.boostStakeMultiplier,
            "Stake boost multiplier mismatch"
        );
        require(
            stake.SWAP_FEE_FOR_LP_RATIO() == config.dexConfig.swapFeeForLpRatio,
            "Stake swap fee for LP ratio mismatch"
        );
        require(
            stake.SWAP_FEE_FOR_PROTOCOL_RATIO() == config.dexConfig.swapFeeForProtocolRatio,
            "Stake boost multiplier mismatch"
        );
        require(
            stake.LIQUIDITY_TOKEN_EQUIVALENCE_FACTOR() == 2, "Stake liquidity equivalence factor mismatch"
        );

        ISubmit submit = ISubmit(addrs.submit);
        require(submit.PHASE_ADDRESS() == addrs.phase, "Submit phase mismatch");
        require(submit.STAKE_ADDRESS() == addrs.stake, "Submit stake mismatch");
        require(submit.MEMBER_NFT_ADDRESS() == addrs.memberNFT, "Submit member NFT mismatch");
        require(submit.SUBMIT_MIN_RATIO() == config.submitMinRatio, "Submit min ratio mismatch");

        IVote vote = IVote(addrs.vote);
        require(vote.PHASE_ADDRESS() == addrs.phase, "Vote phase mismatch");
        require(vote.STAKE_ADDRESS() == addrs.stake, "Vote stake mismatch");
        require(vote.SUBMIT_ADDRESS() == addrs.submit, "Vote submit mismatch");
        require(vote.MEMBER_NFT_ADDRESS() == addrs.memberNFT, "Vote member NFT mismatch");
    }

    /// @dev Separate from `_validateDeployment` because that function already carries the whole
    ///      deployment graph and adding these locals to it does not compile.
    function _validateAirdropDistributor(CoreConfig memory config, DeploymentAddresses memory addrs)
        private
        view
    {
        IAirdropDistributor airdropDistributor = IAirdropDistributor(addrs.airdropDistributor);
        require(airdropDistributor.LAUNCH_ADDRESS() == addrs.launch, "AirdropDistributor launch mismatch");
        require(airdropDistributor.PHASE_ADDRESS() == addrs.phase, "AirdropDistributor phase mismatch");
        require(airdropDistributor.TOTAL_SHARE() == TOTAL_SHARE, "AirdropDistributor total share mismatch");
        require(
            airdropDistributor.MAX_CLAIM_DELAY_ROUNDS() == MAX_CLAIM_DELAY_ROUNDS,
            "AirdropDistributor max claim delay mismatch"
        );
        require(
            airdropDistributor.airdropInfo(addrs.token).merkleRoot == config.genesisMerkleRoot,
            "AirdropDistributor genesis merkle root mismatch"
        );

        // The genesis claim round was frozen at deployment and the current round may have moved
        // since; the exact bracket is asserted in `_deployAirdropDistributor`, where both ends are
        // read around the deployment. Here only the time-invariant bounds are checked: the recorded
        // base round is at least the clamp floor and no later than the round reached by now.
        uint256 currentRound = IPhase(addrs.phase).currentPhase();
        uint256 claimableFromRound = airdropDistributor.airdropInfo(addrs.token).claimableFromRound;
        require(
            claimableFromRound >= 1 + config.genesisClaimDelayRounds
                && claimableFromRound
                    <= (currentRound == 0 ? 1 : currentRound) + config.genesisClaimDelayRounds,
            "AirdropDistributor genesis claim round mismatch"
        );
    }

    function _logDeploymentSummary(DeploymentAddresses memory addrs) private pure {
        console2.log("\n=== Deployment Summary ===");
        console2.log("LOVE20_TOKEN_ADDRESS=", addrs.token);
        console2.log("AIRDROP_DISTRIBUTOR_ADDRESS=", addrs.airdropDistributor);
        console2.log("MEMBER_NFT_ADDRESS=", addrs.memberNFT);
        console2.log("PHASE_ADDRESS=", addrs.phase);
        console2.log("LAUNCH_ADDRESS=", addrs.launch);
        console2.log("MINT_ADDRESS=", addrs.mint);
        console2.log("STAKE_ADDRESS=", addrs.stake);
        console2.log("SUBMIT_ADDRESS=", addrs.submit);
        console2.log("VOTE_ADDRESS=", addrs.vote);
    }
}
