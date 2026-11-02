// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Script} from "@forge-std/Script.sol";
import {console2} from "@forge-std/console2.sol";
import {MemberNFT} from "../../src/MemberNFT.sol";
import {Phase} from "../../src/Phase.sol";
import {Launch} from "../../src/Launch.sol";
import {Mint} from "../../src/Mint.sol";
import {Vote} from "../../src/Vote.sol";
import {Submit} from "../../src/Submit.sol";
import {Stake} from "../../src/Stake.sol";
import {IMemberNFT} from "../../src/interfaces/IMemberNFT.sol";
import {IPhase} from "../../src/interfaces/IPhase.sol";
import {ILaunch, LaunchInitParams} from "../../src/interfaces/ILaunch.sol";
import {IMint} from "../../src/interfaces/IMint.sol";
import {IStake} from "../../src/interfaces/IStake.sol";
import {ISubmit} from "../../src/interfaces/ISubmit.sol";
import {IVote} from "../../src/interfaces/IVote.sol";
import {ILOVE20Token} from "../../src/interfaces/ILOVE20Token.sol";

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

    struct DeploymentAddresses {
        address token;
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
        address factory;
        address router;
        address distributor;
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
        uint256 maxBoostMultiplier;
        uint256 submitMinRatio;
        uint256 promisedWaitingPhasesMin;
        uint256 promisedWaitingPhasesMax;
        uint256 feeSettlementRatio;
    }

    function run() external returns (DeploymentAddresses memory addrs) {
        CoreConfig memory config = _loadConfig();
        _validateConfig(config);
        address rootParent = IUniswapV2RouterWeth(config.router).WETH();

        vm.startBroadcast();
        addrs = _deployContracts(config, rootParent);
        vm.stopBroadcast();

        _validateDeployment(config, rootParent, addrs);
        _logDeploymentSummary(addrs);
    }

    function _loadConfig() internal view returns (CoreConfig memory config) {
        config.chainId = vm.envUint("CHAIN_ID");
        config.factory = vm.envAddress("FACTORY_ADDRESS");
        config.router = vm.envAddress("ROUTER_ADDRESS");
        config.distributor = vm.envAddress("DISTRIBUTOR_ADDRESS");
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
        config.maxBoostMultiplier = vm.envUint("MAX_BOOST_MULTIPLIER");
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

        require(config.distributor != address(0), "Distributor must be nonzero");
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
        require(config.launchAmount != 0 && config.launchAmount <= config.maxSupply, "Launch amount out of range");

        require(config.proposalRewardMinVoteRatio <= 1e18, "Proposal threshold exceeds 1e18");
        require(config.roundRewardGovRatio <= 1e18, "Round reward gov ratio exceeds 1e18");
        require(
            config.roundRewardProposalRatio <= 1e18 - config.roundRewardGovRatio,
            "Round reward ratios exceed 1e18"
        );
        require(
            config.maxBoostMultiplier != 0 && config.maxBoostMultiplier <= 1000,
            "Max boost multiplier out of range"
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
        // between them does not revert during simulation and would broadcast 8 contracts for
        // nothing (21_check.sh would only catch it afterwards).
        require(config.factory.code.length != 0, "Factory must be a deployed contract");
        require(config.router.code.length != 0, "Router must be a deployed contract");
        require(
            IUniswapV2RouterWeth(config.router).factory() == config.factory,
            "Router.factory must match FACTORY_ADDRESS"
        );
        require(
            IUniswapV2RouterWeth(config.router).WETH().code.length != 0, "WETH must be a deployed contract"
        );
    }

    function _deployContracts(CoreConfig memory config, address rootParent)
        internal
        returns (DeploymentAddresses memory addrs)
    {
        // Deploy MemberNFT.
        addrs.memberNFT = address(_deployMemberNFT(config));
        console2.log("MemberNFT deployed at:", addrs.memberNFT);

        // Deploy Phase.
        addrs.phase = address(_deployPhase(config));
        console2.log("Phase deployed at:", addrs.phase);

        // Deploy Mint (not initialized yet).
        addrs.mint = address(new Mint());
        console2.log("Mint deployed at:", addrs.mint);

        // Deploy Launch.
        addrs.launch = address(new Launch());
        console2.log("Launch deployed at:", addrs.launch);

        // Call Launch.init() to create the first token.
        LaunchInitParams memory launchParams = LaunchInitParams({
            mintAddress: addrs.mint,
            memberNFTAddress: addrs.memberNFT,
            rootParentTokenAddress: rootParent,
            pairFactoryAddress: config.factory,
            launchCountThresholdRatio: config.launchCountThresholdRatio,
            maxLaunchCount: config.maxLaunchCount,
            tokenSymbolLength: config.tokenSymbolLength,
            launchAmount: config.launchAmount,
            maxSupply: config.maxSupply,
            distributor: config.distributor,
            name: config.tokenName,
            symbol: config.tokenSymbol
        });
        Launch(addrs.launch).init(launchParams);

        // Read the first token address from Launch.
        (address[] memory tokens,) = Launch(addrs.launch).tokens(0, 1, false);
        addrs.token = tokens[0];
        console2.log("First LOVE20Token created at:", addrs.token);

        // Deploy Stake (not initialized yet).
        addrs.stake = address(new Stake());
        console2.log("Stake deployed at:", addrs.stake);

        // Deploy Submit (not initialized yet).
        addrs.submit = address(new Submit());
        console2.log("Submit deployed at:", addrs.submit);

        // Deploy Vote (not initialized yet).
        addrs.vote = address(new Vote());
        console2.log("Vote deployed at:", addrs.vote);

        // Initialize Stake.
        Stake(addrs.stake).init(
            addrs.phase,
            addrs.memberNFT,
            addrs.vote,
            addrs.launch,
            config.router,
            config.factory,
            config.promisedWaitingPhasesMin,
            config.promisedWaitingPhasesMax,
            config.feeSettlementRatio
        );
        console2.log("Stake initialized");

        // Initialize Submit.
        Submit(addrs.submit).init(addrs.phase, addrs.stake, addrs.memberNFT, config.submitMinRatio);
        console2.log("Submit initialized");

        // Initialize Vote.
        Vote(addrs.vote).init(addrs.phase, addrs.stake, addrs.submit, addrs.memberNFT);
        console2.log("Vote initialized");

        // Initialize Mint (needs every contract address).
        Mint(addrs.mint).init(
            addrs.vote,
            addrs.submit,
            addrs.launch,
            addrs.memberNFT,
            config.proposalRewardMinVoteRatio,
            config.roundRewardGovRatio,
            config.roundRewardProposalRatio,
            config.maxBoostMultiplier
        );
        console2.log("Mint initialized");
    }

    function _deployMemberNFT(CoreConfig memory config) private returns (MemberNFT) {
        return new MemberNFT(
            config.memberBaseDivisor, config.memberBytesThreshold, config.memberMultiplier, config.memberMaxNameLength
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
        ILOVE20Token token = ILOVE20Token(addrs.token);
        require(keccak256(bytes(token.name())) == keccak256(bytes(config.tokenName)), "Token name mismatch");
        require(keccak256(bytes(token.symbol())) == keccak256(bytes(config.tokenSymbol)), "Token symbol mismatch");
        require(token.MAX_SUPPLY() == config.maxSupply, "Token max supply mismatch");
        require(token.MINTER() == addrs.mint, "Token minter mismatch");
        require(token.PARENT_TOKEN_ADDRESS() == rootParent, "Token parent mismatch");
        require(token.totalSupply() == config.launchAmount, "Token launch amount mismatch");
        // forge-lint: disable-next-item(incorrect-strict-equality)
        require(token.balanceOf(config.distributor) == config.launchAmount, "Token distributor balance mismatch");

        IMemberNFT memberNFT = IMemberNFT(addrs.memberNFT);
        require(memberNFT.initialized(), "MemberNFT not initialized");
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
        require(launch.initialized(), "Launch not initialized");
        require(launch.MINT_ADDRESS() == addrs.mint, "Launch mint mismatch");
        require(launch.MEMBER_NFT_ADDRESS() == addrs.memberNFT, "Launch member NFT mismatch");
        require(launch.ROOT_PARENT_TOKEN_ADDRESS() == rootParent, "Launch root parent mismatch");
        require(launch.FIRST_TOKEN_ADDRESS() == addrs.token, "Launch first token mismatch");
        require(launch.PAIR_FACTORY_ADDRESS() == config.factory, "Launch pair factory mismatch");
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

        IMint mint = IMint(addrs.mint);
        require(mint.initialized(), "Mint not initialized");
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
        require(
            mint.MAX_GOV_BOOST_REWARD_MULTIPLIER() == config.maxBoostMultiplier,
            "Mint max boost mismatch"
        );

        IStake stake = IStake(addrs.stake);
        require(stake.initialized(), "Stake not initialized");
        require(stake.PHASE_ADDRESS() == addrs.phase, "Stake phase mismatch");
        require(stake.MEMBER_NFT_ADDRESS() == addrs.memberNFT, "Stake member NFT mismatch");
        require(stake.VOTE_ADDRESS() == addrs.vote, "Stake vote mismatch");
        require(stake.LAUNCH_ADDRESS() == addrs.launch, "Stake launch mismatch");
        require(stake.ROUTER_ADDRESS() == config.router, "Stake router mismatch");
        require(stake.PAIR_FACTORY_ADDRESS() == config.factory, "Stake pair factory mismatch");
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

        ISubmit submit = ISubmit(addrs.submit);
        require(submit.initialized(), "Submit not initialized");
        require(submit.PHASE_ADDRESS() == addrs.phase, "Submit phase mismatch");
        require(submit.STAKE_ADDRESS() == addrs.stake, "Submit stake mismatch");
        require(submit.MEMBER_NFT_ADDRESS() == addrs.memberNFT, "Submit member NFT mismatch");
        require(submit.SUBMIT_MIN_RATIO() == config.submitMinRatio, "Submit min ratio mismatch");

        IVote vote = IVote(addrs.vote);
        require(vote.initialized(), "Vote not initialized");
        require(vote.PHASE_ADDRESS() == addrs.phase, "Vote phase mismatch");
        require(vote.STAKE_ADDRESS() == addrs.stake, "Vote stake mismatch");
        require(vote.SUBMIT_ADDRESS() == addrs.submit, "Vote submit mismatch");
        require(vote.MEMBER_NFT_ADDRESS() == addrs.memberNFT, "Vote member NFT mismatch");
    }

    function _logDeploymentSummary(DeploymentAddresses memory addrs) private pure {
        console2.log("\n=== Deployment Summary ===");
        console2.log("LOVE20_TOKEN_ADDRESS=", addrs.token);
        console2.log("MEMBER_NFT_ADDRESS=", addrs.memberNFT);
        console2.log("PHASE_ADDRESS=", addrs.phase);
        console2.log("LAUNCH_ADDRESS=", addrs.launch);
        console2.log("MINT_ADDRESS=", addrs.mint);
        console2.log("STAKE_ADDRESS=", addrs.stake);
        console2.log("SUBMIT_ADDRESS=", addrs.submit);
        console2.log("VOTE_ADDRESS=", addrs.vote);
    }
}
