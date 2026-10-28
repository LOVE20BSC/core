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

// 部署脚本只从 Router 读取根父币与 Factory 地址；Stake 实际调用的 Router 接口见 src/interfaces/UniswapV2/。
interface IUniswapV2RouterWeth {
    function WETH() external view returns (address);
    function factory() external view returns (address);
}

contract DeployCore is Script {
    // Uniswap V2 池费率 0.30%，按 1e18 精度换算；手续费结算比例不得超过可提取的费率本身。
    uint256 internal constant MAX_FEE_SETTLEMENT_RATIO = 3e15;
    // 与 Launch.MAX_TOKEN_SYMBOL_LENGTH 同源：子币符号加 "Test" 前缀（4 字节）后仍不得超上限。
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
        uint256 launchRatio;
        uint256 maxLaunchCount;
        uint256 tokenSymbolLength;
        uint256 initialSupply;
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
        config.launchRatio = vm.envUint("LAUNCH_RATIO");
        config.maxLaunchCount = vm.envUint("MAX_LAUNCH_COUNT");
        config.tokenSymbolLength = vm.envUint("TOKEN_SYMBOL_LENGTH");
        config.initialSupply = vm.envUint("INITIAL_SUPPLY");
        config.maxSupply = vm.envUint("MAX_SUPPLY");
        config.proposalRewardMinVoteRatio = vm.envUint("PROPOSAL_REWARD_MIN_VOTE_RATIO");
        config.roundRewardGovRatio = vm.envUint("GOV_REWARD_RATIO");
        config.roundRewardProposalRatio = vm.envUint("PROPOSAL_REWARD_RATIO");
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
        require(config.launchRatio != 0 && config.launchRatio <= 1e18, "Launch ratio out of range");
        require(config.maxLaunchCount != 0, "Max launch count must be nonzero");
        require(config.tokenSymbolLength != 0, "Token symbol length must be nonzero");
        require(
            config.tokenSymbolLength + TEST_PREFIX_BYTES <= MAX_TOKEN_SYMBOL_LENGTH,
            "Token symbol length leaves no room for the Test prefix"
        );
        require(
            config.initialSupply != 0 && config.initialSupply <= config.maxSupply, "Initial supply out of range"
        );

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
        require(
            config.feeSettlementRatio != 0 && config.feeSettlementRatio <= 1e18,
            "Fee settlement ratio out of range"
        );
        require(
            config.feeSettlementRatio <= MAX_FEE_SETTLEMENT_RATIO,
            "Fee settlement ratio exceeds the 0.30% pool fee"
        );

        // DEX 依赖必须是已部署合约且属于同一套部署。根父币从 Router.WETH() 读取，不在 core.params
        // 重复登记；Factory 供 Launch/Stake 建池、Router 供提现兑换，三者配错时模拟阶段不会回滚，
        // 会白广播 8 个合约（要到 21_check.sh 才拦下）。
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
        // 部署 MemberNFT
        addrs.memberNFT = address(_deployMemberNFT(config));
        console2.log("MemberNFT deployed at:", addrs.memberNFT);

        // 部署 Phase
        addrs.phase = address(_deployPhase(config));
        console2.log("Phase deployed at:", addrs.phase);

        // 部署 Mint（未初始化）
        addrs.mint = address(new Mint());
        console2.log("Mint deployed at:", addrs.mint);

        // 部署 Launch
        addrs.launch = address(new Launch());
        console2.log("Launch deployed at:", addrs.launch);

        // 调用 Launch.init() 创建首个代币
        LaunchInitParams memory launchParams = LaunchInitParams({
            mintAddress: addrs.mint,
            memberNFTAddress: addrs.memberNFT,
            rootParentTokenAddress: rootParent,
            pairFactoryAddress: config.factory,
            launchRatio: config.launchRatio,
            maxLaunchCount: config.maxLaunchCount,
            tokenSymbolLength: config.tokenSymbolLength,
            launchAmount: config.initialSupply,
            maxSupply: config.maxSupply,
            distributor: config.distributor,
            name: config.tokenName,
            symbol: config.tokenSymbol
        });
        Launch(addrs.launch).init(launchParams);

        // 从 Launch 获取首个代币地址
        (address[] memory tokens,) = Launch(addrs.launch).tokens(0, 1, false);
        addrs.token = tokens[0];
        console2.log("First LOVE20Token created at:", addrs.token);

        // 部署 Stake（未初始化）
        addrs.stake = address(new Stake());
        console2.log("Stake deployed at:", addrs.stake);

        // 部署 Submit（未初始化）
        addrs.submit = address(new Submit());
        console2.log("Submit deployed at:", addrs.submit);

        // 部署 Vote（未初始化）
        addrs.vote = address(new Vote());
        console2.log("Vote deployed at:", addrs.vote);

        // 初始化 Stake
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

        // 初始化 Submit
        Submit(addrs.submit).init(addrs.phase, addrs.stake, addrs.memberNFT, config.submitMinRatio);
        console2.log("Submit initialized");

        // 初始化 Vote
        Vote(addrs.vote).init(addrs.phase, addrs.stake, addrs.submit, addrs.memberNFT);
        console2.log("Vote initialized");

        // 初始化 Mint（需要所有合约地址）
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
        require(token.maxSupply() == config.maxSupply, "Token max supply mismatch");
        require(token.minter() == addrs.mint, "Token minter mismatch");
        require(token.parentTokenAddress() == rootParent, "Token parent mismatch");
        require(token.totalSupply() == config.initialSupply, "Token initial supply mismatch");
        // forge-lint: disable-next-item(incorrect-strict-equality)
        require(token.balanceOf(config.distributor) == config.initialSupply, "Token distributor balance mismatch");

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
        require(launch.mintAddress() == addrs.mint, "Launch mint mismatch");
        require(launch.memberNFTAddress() == addrs.memberNFT, "Launch member NFT mismatch");
        require(launch.rootParentTokenAddress() == rootParent, "Launch root parent mismatch");
        require(launch.firstTokenAddress() == addrs.token, "Launch first token mismatch");
        require(launch.pairFactoryAddress() == config.factory, "Launch pair factory mismatch");
        require(launch.LAUNCH_RATIO() == config.launchRatio, "Launch ratio mismatch");
        require(launch.MAX_LAUNCH_COUNT() == config.maxLaunchCount, "Launch max count mismatch");
        require(launch.TOKEN_SYMBOL_LENGTH() == config.tokenSymbolLength, "Launch symbol length mismatch");
        require(launch.LAUNCH_AMOUNT() == config.initialSupply, "Launch amount mismatch");
        require(launch.MAX_SUPPLY() == config.maxSupply, "Launch max supply mismatch");

        IMint mint = IMint(addrs.mint);
        require(mint.initialized(), "Mint not initialized");
        require(mint.voteAddress() == addrs.vote, "Mint vote mismatch");
        require(mint.submitAddress() == addrs.submit, "Mint submit mismatch");
        require(mint.launchAddress() == addrs.launch, "Mint launch mismatch");
        require(mint.memberNFTAddress() == addrs.memberNFT, "Mint member NFT mismatch");
        require(mint.phaseAddress() == addrs.phase, "Mint phase mismatch");
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
        require(stake.phaseAddress() == addrs.phase, "Stake phase mismatch");
        require(stake.memberNFTAddress() == addrs.memberNFT, "Stake member NFT mismatch");
        require(stake.voteAddress() == addrs.vote, "Stake vote mismatch");
        require(stake.launchAddress() == addrs.launch, "Stake launch mismatch");
        require(stake.routerAddress() == config.router, "Stake router mismatch");
        require(stake.pairFactoryAddress() == config.factory, "Stake pair factory mismatch");
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
        require(submit.phaseAddress() == addrs.phase, "Submit phase mismatch");
        require(submit.stakeAddress() == addrs.stake, "Submit stake mismatch");
        require(submit.memberNFTAddress() == addrs.memberNFT, "Submit member NFT mismatch");
        require(submit.SUBMIT_MIN_RATIO() == config.submitMinRatio, "Submit min ratio mismatch");

        IVote vote = IVote(addrs.vote);
        require(vote.initialized(), "Vote not initialized");
        require(vote.phaseAddress() == addrs.phase, "Vote phase mismatch");
        require(vote.stakeAddress() == addrs.stake, "Vote stake mismatch");
        require(vote.submitAddress() == addrs.submit, "Vote submit mismatch");
        require(vote.memberNFTAddress() == addrs.memberNFT, "Vote member NFT mismatch");
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
