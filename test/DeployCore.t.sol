// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Test} from "@forge-std/Test.sol";
import {DeployCore} from "../script/deploy/DeployCore.s.sol";

contract DeployCoreHarness is DeployCore {
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

    function testRejectsZeroDistributor() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.distributor = address(0);
        vm.expectRevert("Distributor must be nonzero");
        deployer.validateConfigForTest(config);
    }

    function testRejectsEmptyTokenName() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.tokenName = "";
        vm.expectRevert("Token name must be nonempty");
        deployer.validateConfigForTest(config);
    }

    function testRejectsLaunchRatioAbovePrecision() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.launchRatio = 1e18 + 1;
        vm.expectRevert("Launch ratio out of range");
        deployer.validateConfigForTest(config);
    }

    function testRejectsZeroLaunchRatio() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.launchRatio = 0;
        vm.expectRevert("Launch ratio out of range");
        deployer.validateConfigForTest(config);
    }

    function testRejectsLaunchAmountAboveMaxSupply() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.initialSupply = config.maxSupply + 1;
        vm.expectRevert("Initial supply out of range");
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

    function testRejectsZeroMaxBoostMultiplier() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.maxBoostMultiplier = 0;
        vm.expectRevert("Max boost multiplier out of range");
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

    function testRejectsFeeRatioAbovePoolFee() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.feeSettlementRatio = 3e15 + 1;
        vm.expectRevert("Fee settlement ratio exceeds the 0.30% pool fee");
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

    function testRejectsZeroInitialSupply() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.initialSupply = 0;
        vm.expectRevert("Initial supply out of range");
        deployer.validateConfigForTest(config);
    }

    function testRejectsProposalThresholdAbovePrecision() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.proposalRewardMinVoteRatio = 1e18 + 1;
        vm.expectRevert("Proposal threshold exceeds 1e18");
        deployer.validateConfigForTest(config);
    }

    function testRejectsBoostMultiplierAboveMax() public {
        DeployCore.CoreConfig memory config = _validConfig();
        config.maxBoostMultiplier = 1001;
        vm.expectRevert("Max boost multiplier out of range");
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
        vm.expectRevert("Fee settlement ratio out of range");
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
            distributor: address(0xD15),
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
            launchRatio: 1e18,
            maxLaunchCount: 1000,
            tokenSymbolLength: 4,
            initialSupply: 1e27,
            maxSupply: 1e28,
            proposalRewardMinVoteRatio: 5e16,
            roundRewardGovRatio: 1e17,
            roundRewardProposalRatio: 1e17,
            maxBoostMultiplier: 2,
            submitMinRatio: 1e16,
            promisedWaitingPhasesMin: 1,
            promisedWaitingPhasesMax: 100,
            feeSettlementRatio: 3e15
        });
    }
}

contract MockPair {}

contract MockFactory {
    function getPair(address, address) external pure returns (address) {
        return address(0);
    }

    function createPair(address, address) external returns (address) {
        return address(new MockPair());
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
