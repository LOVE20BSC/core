// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Test} from "@forge-std/Test.sol";
import {DeployCore} from "../script/deploy/DeployCore.s.sol";
import {IPhase} from "../src/interfaces/IPhase.sol";

contract DeployCoreHarness is DeployCore {
    function _predictor() internal view override returns (address) {
        return address(this);
    }

    function validateConfigForTest(CoreConfig memory config) external view {
        _validateConfig(config);
    }

    function deployForTest(CoreConfig memory config, address rootParent)
        external
        returns (DeploymentAddresses memory addrs)
    {
        addrs = _deployContracts(config, rootParent);
        _validateDeployment(config, rootParent, addrs);
    }

    function validateDeploymentForTest(CoreConfig memory config, address rootParent, DeploymentAddresses memory addrs)
        external
        view
    {
        _validateDeployment(config, rootParent, addrs);
    }
}

contract DeployCoreTest is Test {
    DeployCoreHarness internal deployer;
    address internal factory;
    address internal router;
    address internal rootParent = address(0xBEEF);

    function setUp() public {
        deployer = new DeployCoreHarness();
        factory = makeAddr("factory");
        vm.etch(factory, hex"00");
        router = address(new MockRouter(rootParent, factory));
        vm.etch(rootParent, hex"00");
    }

    function testPreflightAcceptsValidConfig() public view {
        deployer.validateConfigForTest(_validConfig());
    }

    function testDeploymentBindingGraph() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.factory = address(new MockFactory());
        config.router = address(new MockRouter(rootParent, config.factory));
        DeployCore.DeploymentAddresses memory addrs = deployer.deployForTest(config, rootParent);
        require(addrs.token != address(0), "token deployed");
        require(addrs.airdropDistributor != address(0), "airdrop distributor deployed");
        require(addrs.memberNFT != address(0), "member NFT deployed");
        require(addrs.phase != address(0), "phase deployed");
        require(addrs.launch != address(0), "launch deployed");
        require(addrs.mint != address(0), "mint deployed");
        require(addrs.stake != address(0), "stake deployed");
        require(addrs.submit != address(0), "submit deployed");
        require(addrs.vote != address(0), "vote deployed");
    }

    function testRejectsInvalidChainId() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.chainId = block.chainid + 1;
        vm.expectRevert("Chain ID mismatch");
        deployer.validateConfigForTest(config);
    }

    function testRejectsMemberNFTZeroParameter() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.memberBaseDivisor = 0;
        vm.expectRevert("Member NFT base divisor must be nonzero");
        deployer.validateConfigForTest(config);
    }

    function testRejectsPhaseZeroOrigin() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.phaseOriginBlocks = 0;
        vm.expectRevert("Phase origin blocks must be nonzero");
        deployer.validateConfigForTest(config);
    }

    function testRejectsPhaseAdjustThresholdAbovePrecision() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.phaseAdjustThreshold = 1e18 + 1;
        vm.expectRevert("Phase adjust threshold out of range");
        deployer.validateConfigForTest(config);
    }

    // Pins the deployment order (Phase +0, AirdropDistributor +1, Launch +2, MemberNFT +3, Stake +4,
    // Submit +5, Vote +6, Mint +7) against the predictions the script actually used, and pins the
    // genesis token to Launch's first CREATE. `_deployContracts` already requires each equality, so
    // this test is the independent statement of the same table: it recomputes every address from the
    // pre-deployment nonce instead of trusting the script's own arithmetic.
    function testPredictedAddressesFollowDeploymentOrder() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.factory = address(new MockFactory());
        config.router = address(new MockRouter(rootParent, config.factory));

        address creator = address(deployer);
        uint256 nonce = vm.getNonce(creator);
        address expectedAirdropDistributor = vm.computeCreateAddress(creator, nonce + 1);
        address expectedLaunch = vm.computeCreateAddress(creator, nonce + 2);
        address expectedMemberNFT = vm.computeCreateAddress(creator, nonce + 3);
        address expectedVote = vm.computeCreateAddress(creator, nonce + 6);
        address expectedMint = vm.computeCreateAddress(creator, nonce + 7);
        // Launch's constructor performs exactly one CREATE; factory.createPair is an external call.
        address expectedToken = vm.computeCreateAddress(expectedLaunch, 1);

        DeployCore.DeploymentAddresses memory addrs = deployer.deployForTest(config, rootParent);

        require(addrs.airdropDistributor == expectedAirdropDistributor, "airdrop distributor nonce+1");
        require(addrs.launch == expectedLaunch, "launch nonce+2");
        require(addrs.memberNFT == expectedMemberNFT, "member NFT nonce+3");
        require(addrs.vote == expectedVote, "vote nonce+6");
        require(addrs.mint == expectedMint, "mint nonce+7");
        require(addrs.token == expectedToken, "genesis token is launch nonce 1");
    }

    // The genesis claim round is frozen at deployment, so re-running the deployment validation
    // after Phase has advanced must still pass. Comparing against the live round instead would
    // report a false mismatch on every late re-check and on any deployment whose broadcast window
    // straddles a phase boundary.
    function testGenesisClaimRoundValidationSurvivesPhaseAdvance() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.factory = address(new MockFactory());
        config.router = address(new MockRouter(rootParent, config.factory));

        DeployCore.DeploymentAddresses memory addrs = deployer.deployForTest(config, rootParent);
        uint256 deployedRound = IPhase(addrs.phase).currentPhase();

        vm.roll(block.number + config.phaseOriginPhaseBlocks * 5);
        assertGt(IPhase(addrs.phase).currentPhase(), deployedRound, "phase advanced");

        deployer.validateDeploymentForTest(config, rootParent, addrs);
    }

    function testRejectsZeroGenesisMerkleRoot() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.genesisMerkleRoot = bytes32(0);
        vm.expectRevert("Genesis merkle root must be nonzero");
        deployer.validateConfigForTest(config);
    }

    function testRejectsGenesisClaimDelayAboveMax() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.genesisClaimDelayRounds = 1001;
        vm.expectRevert("Genesis claim delay rounds exceed MAX_CLAIM_DELAY_ROUNDS");
        deployer.validateConfigForTest(config);
    }

    function testRejectsEmptyTokenName() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.tokenName = "";
        vm.expectRevert("Token name must be nonempty");
        deployer.validateConfigForTest(config);
    }

    function testRejectsLaunchCountThresholdRatioAbovePrecision() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.launchCountThresholdRatio = 1e18 + 1;
        vm.expectRevert("Launch count threshold ratio out of range");
        deployer.validateConfigForTest(config);
    }

    function testRejectsZeroLaunchCountThresholdRatio() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.launchCountThresholdRatio = 0;
        vm.expectRevert("Launch count threshold ratio out of range");
        deployer.validateConfigForTest(config);
    }

    function testRejectsLaunchAmountAboveMaxSupply() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.launchAmount = config.maxSupply + 1;
        vm.expectRevert("Launch amount out of range");
        deployer.validateConfigForTest(config);
    }

    function testRejectsLaunchAmountBelowTotalShare() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.launchAmount = 1e18 - 1;
        vm.expectRevert("Launch amount out of range");
        deployer.validateConfigForTest(config);
    }

    function testAcceptsLaunchAmountAtTotalShare() public view {
        DeployCore.CoreConfig memory config = _validConfig();
        config.launchAmount = 1e18;
        deployer.validateConfigForTest(config);
    }

    function testRejectsRoundRewardRatioSumAbovePrecision() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.roundRewardGovRatio = 6e17;
        config.roundRewardProposalRatio = 5e17;
        vm.expectRevert("Round reward ratios exceed 1e18");
        deployer.validateConfigForTest(config);
    }

    function testRejectsGovRatioAbovePrecision() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.roundRewardGovRatio = 1e18 + 1;
        vm.expectRevert("Round reward gov ratio exceeds 1e18");
        deployer.validateConfigForTest(config);
    }

    function testRejectsZeroBoostStakeSupplyFactor() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.boostStakeSupplyFactor = 0;
        vm.expectRevert("Boost stake supply factor must be nonzero");
        deployer.validateConfigForTest(config);
    }

    function testRejectsZeroBoostStakeMultiplier() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.boostStakeMultiplier = 0;
        vm.expectRevert("Boost stake multiplier must be nonzero");
        deployer.validateConfigForTest(config);
    }

    function testRejectsZeroSubmitMinRatio() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.submitMinRatio = 0;
        vm.expectRevert("Submit min ratio out of range");
        deployer.validateConfigForTest(config);
    }

    function testRejectsInvalidWaitingPhaseRange() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.promisedWaitingPhasesMin = config.promisedWaitingPhasesMax + 1;
        vm.expectRevert("Promised waiting phases range is invalid");
        deployer.validateConfigForTest(config);
    }

    function testRejectsFeeRatioAboveMaxFeeSettlementRatio() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.feeSettlementRatio = 2.5e15 + 1;
        vm.expectRevert("Fee settlement ratio exceeds MAX_FEE_SETTLEMENT_RATIO (0.25%)");
        deployer.validateConfigForTest(config);
    }

    function testRejectsNonContractFactory() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.factory = makeAddr("eoaFactory");
        vm.expectRevert("Factory must be a deployed contract");
        deployer.validateConfigForTest(config);
    }

    function testRejectsNonContractRouter() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.router = makeAddr("eoaRouter");
        vm.expectRevert("Router must be a deployed contract");
        deployer.validateConfigForTest(config);
    }

    function testRejectsRouterFactoryMismatch() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.router = address(new MockRouter(rootParent, makeAddr("otherFactory")));
        vm.expectRevert("Router.factory must match FACTORY_ADDRESS");
        deployer.validateConfigForTest(config);
    }

    function testRejectsZeroRootParent() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.router = address(new MockRouter(address(0), factory));
        vm.expectRevert("WETH must be a deployed contract");
        deployer.validateConfigForTest(config);
    }

    function testRejectsMemberNFTBytesThresholdZero() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.memberBytesThreshold = 0;
        vm.expectRevert("Member NFT bytes threshold must be nonzero");
        deployer.validateConfigForTest(config);
    }

    function testRejectsMemberNFTMultiplierZero() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.memberMultiplier = 0;
        vm.expectRevert("Member NFT multiplier must be nonzero");
        deployer.validateConfigForTest(config);
    }

    function testRejectsMemberNFTMaxNameLengthZero() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.memberMaxNameLength = 0;
        vm.expectRevert("Member NFT max name length must be nonzero");
        deployer.validateConfigForTest(config);
    }

    function testRejectsPhaseOriginPhaseBlocksZero() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.phaseOriginPhaseBlocks = 0;
        vm.expectRevert("Phase origin phase blocks must be nonzero");
        deployer.validateConfigForTest(config);
    }

    function testRejectsPhaseTargetSecondsZero() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.phaseTargetSeconds = 0;
        vm.expectRevert("Phase target seconds must be nonzero");
        deployer.validateConfigForTest(config);
    }

    function testRejectsPhaseSyncObservationLimitZero() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.phaseSyncObservationLimit = 0;
        vm.expectRevert("Phase observation limit must be nonzero");
        deployer.validateConfigForTest(config);
    }

    function testRejectsPhaseAdjustThresholdZero() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.phaseAdjustThreshold = 0;
        vm.expectRevert("Phase adjust threshold out of range");
        deployer.validateConfigForTest(config);
    }

    function testRejectsEmptyTokenSymbol() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.tokenSymbol = "";
        vm.expectRevert("Token symbol must be nonempty");
        deployer.validateConfigForTest(config);
    }

    function testRejectsZeroMaxLaunchCount() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.maxLaunchCount = 0;
        vm.expectRevert("Max launch count must be nonzero");
        deployer.validateConfigForTest(config);
    }

    function testRejectsZeroTokenSymbolLength() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.tokenSymbolLength = 0;
        vm.expectRevert("Token symbol length must be nonzero");
        deployer.validateConfigForTest(config);
    }

    function testRejectsSymbolLengthWithoutTestPrefixRoom() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.tokenSymbolLength = 29;
        vm.expectRevert("Token symbol length leaves no room for the Test prefix");
        deployer.validateConfigForTest(config);
    }

    function testAcceptsSymbolLengthAtTestPrefixLimit() public view {
        DeployCore.CoreConfig memory config = _validConfig();
        config.tokenSymbolLength = 28;
        deployer.validateConfigForTest(config);
    }

    function testRejectsZeroLaunchAmount() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.launchAmount = 0;
        vm.expectRevert("Launch amount out of range");
        deployer.validateConfigForTest(config);
    }

    function testRejectsProposalThresholdAbovePrecision() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.proposalRewardMinVoteRatio = 1e18 + 1;
        vm.expectRevert("Proposal threshold exceeds 1e18");
        deployer.validateConfigForTest(config);
    }

    function testAcceptsBoostStakeSupplyFactorAboveRecommendation() public view {
        DeployCore.CoreConfig memory config = _validConfig();
        config.boostStakeSupplyFactor = 11;
        deployer.validateConfigForTest(config);
    }

    function testAcceptsBoostStakeMultiplierAboveRecommendation() public view {
        DeployCore.CoreConfig memory config = _validConfig();
        config.boostStakeMultiplier = 21;
        deployer.validateConfigForTest(config);
    }

    function testRejectsSubmitMinRatioAbovePrecision() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.submitMinRatio = 1e18 + 1;
        vm.expectRevert("Submit min ratio out of range");
        deployer.validateConfigForTest(config);
    }

    function testRejectsZeroFeeSettlementRatio() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.feeSettlementRatio = 0;
        vm.expectRevert("Fee settlement ratio must be nonzero");
        deployer.validateConfigForTest(config);
    }

    function testRejectsZeroPromisedWaitingPhasesMin() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.promisedWaitingPhasesMin = 0;
        vm.expectRevert("Promised waiting phases min must be nonzero");
        deployer.validateConfigForTest(config);
    }

    function _validConfig() internal view returns (DeployCore.CoreConfig memory) {
        return DeployCore.CoreConfig({
            chainId: block.chainid,
            factory: factory,
            router: router,
            genesisMerkleRoot: keccak256("genesis airdrop"),
            genesisClaimDelayRounds: 1,
            tokenName: "Test LOVE20",
            tokenSymbol: "TestLOVE20",
            memberBaseDivisor: 100000000,
            memberBytesThreshold: 7,
            memberMultiplier: 10,
            memberMaxNameLength: 32,
            phaseOriginBlocks: 1,
            phaseOriginPhaseBlocks: 100,
            phaseTargetSeconds: 300,
            phaseAdjustThreshold: 6e17,
            phaseSyncObservationLimit: 100,
            launchCountThresholdRatio: 1e18,
            maxLaunchCount: 1000,
            tokenSymbolLength: 4,
            launchAmount: 1e27,
            maxSupply: 1e28,
            proposalRewardMinVoteRatio: 5e16,
            roundRewardGovRatio: 1e17,
            roundRewardProposalRatio: 1e17,
            boostStakeSupplyFactor: 2,
            boostStakeMultiplier: 5,
            submitMinRatio: 1e16,
            promisedWaitingPhasesMin: 1,
            promisedWaitingPhasesMax: 100,
            feeSettlementRatio: 2.5e15
        });
    }
}

contract MockPair {}

contract MockFactory {
    mapping(address => mapping(address => address)) internal _pairs;

    function getPair(address tokenA, address tokenB) external view returns (address) {
        return _pairs[tokenA][tokenB];
    }

    function createPair(address tokenA, address tokenB) external returns (address) {
        address pair = address(new MockPair());
        _pairs[tokenA][tokenB] = pair;
        _pairs[tokenB][tokenA] = pair;
        return pair;
    }
}

contract MockRouter {
    address public weth;
    address private _factory;

    constructor(address weth_, address factory_) {
        weth = weth_;
        _factory = factory_;
    }

    function WETH() external view returns (address) {
        return weth;
    }

    function factory() external view returns (address) {
        return _factory;
    }
}
