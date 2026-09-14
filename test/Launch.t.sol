// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {Launch} from "../src/Launch.sol";
import {ILaunch, ILaunchErrors, LaunchInitParams, DistributorMode} from "../src/interfaces/ILaunch.sol";
import {LOVE20Token} from "../src/LOVE20Token.sol";
import {MemberNFT} from "../src/MemberNFT.sol";
import {IMemberNFTErrors} from "../src/interfaces/IMemberNFT.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721Errors} from "../lib/openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";

error DistributorCallbackFailed();

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
}

/// 模拟终端用户：持有 MemberNFT，并以自身身份发起被测调用
contract Caller {
    function forward(address target, bytes calldata data) external returns (bool, bytes memory) {
        return target.call(data);
    }

    function approveToken(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }

    function mintMember(MemberNFT memberNFT, string calldata name) external returns (uint256 id, uint256 cost) {
        return memberNFT.mint(name);
    }

    function transferMember(MemberNFT memberNFT, address to, uint256 id) external {
        memberNFT.transferFrom(address(this), to, id);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
    }
}

/// 模拟 Mint：唯一被授权调用 addLaunchCount 的地址
contract MintAccount {
    function addLaunchCount(Launch launch, address tokenAddress, uint256 memberId, uint256 count) external {
        launch.addLaunchCount(tokenAddress, memberId, count);
    }

    function forward(address target, bytes calldata data) external returns (bool, bytes memory) {
        return target.call(data);
    }
}

/// 模拟需要回调的社区分发方
contract CallbackDistributor {
    address public lastTokenAddress;
    address public lastParentTokenAddress;
    uint256 public lastLauncherMemberId;
    bytes[] public lastData;
    uint256 public callCount;
    bool public rejectNextCall;

    // 回调发生时刻的 Launch / 代币观测值，用于验证外部调用的时机
    Launch public probe;
    bool public observedRegistered;
    uint256 public observedLaunchCount;
    uint256 public observedBalance;

    function setRejectNextCall(bool value) external {
        rejectNextCall = value;
    }

    function setProbe(Launch value) external {
        probe = value;
    }

    function onTokenLaunched(
        address tokenAddress,
        address parentTokenAddress,
        uint256 launcherMemberId,
        bytes[] calldata data
    ) external {
        if (rejectNextCall) revert DistributorCallbackFailed();
        lastTokenAddress = tokenAddress;
        lastParentTokenAddress = parentTokenAddress;
        lastLauncherMemberId = launcherMemberId;
        // 逐元素复制：calldata 的嵌套动态数组不能整体写入 storage
        delete lastData;
        for (uint256 i; i < data.length; ++i) {
            lastData.push(data[i]);
        }
        if (address(probe) != address(0)) {
            observedRegistered = probe.isLOVE20Token(tokenAddress);
            observedLaunchCount = probe.launchCount(parentTokenAddress, launcherMemberId);
            observedBalance = IERC20(tokenAddress).balanceOf(address(this));
        }
        callCount += 1;
    }
}

/// 带同名 getter 的无关合约：登记判定不得读取代币合约
contract FakeToken {
    address public parentTokenAddress;
    string public symbol;

    constructor(address parentTokenAddress_, string memory symbol_) {
        parentTokenAddress = parentTokenAddress_;
        symbol = symbol_;
    }
}

contract LaunchTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant BASE_DIVISOR = 1e8;
    uint256 private constant BYTES_THRESHOLD = 7;
    uint256 private constant MULTIPLIER = 10;
    uint256 private constant MAX_NAME_LENGTH = 32;

    uint256 private constant LAUNCH_RATIO = 1e16;
    uint256 private constant MAX_LAUNCH_COUNT = 100;
    uint256 private constant SYMBOL_LENGTH = 3;
    uint256 private constant LAUNCH_AMOUNT = 100 ether;
    uint256 private constant MAX_SUPPLY = 200 ether;
    uint256 private constant CALLER_FUNDING = 10 ether;

    address private constant ROOT = address(0x5678);
    address private constant SUB_DISTRIBUTOR = address(0x9ABC);
    address private constant EOA = address(0xBEEF);

    Launch private launch;
    MemberNFT private member;
    LOVE20Token private firstToken;
    MintAccount private mintAccount;
    Caller private alice;
    Caller private bob;
    Caller private carol;
    CallbackDistributor private distributor;

    uint256 private aliceMemberId;
    uint256 private bobMemberId;
    uint256 private carolMemberId;

    function setUp() public {
        member = new MemberNFT(BASE_DIVISOR, BYTES_THRESHOLD, MULTIPLIER, MAX_NAME_LENGTH);
        launch = new Launch();
        mintAccount = new MintAccount();
        alice = new Caller();
        bob = new Caller();
        carol = new Caller();
        distributor = new CallbackDistributor();

        launch.init(_validParams());
        firstToken = LOVE20Token(member.LOVE20_TOKEN_ADDRESS());

        _fundAndApprove(alice, firstToken, member);
        _fundAndApprove(bob, firstToken, member);
        _fundAndApprove(carol, firstToken, member);

        (aliceMemberId, ) = alice.mintMember(member, "alice");
        (bobMemberId, ) = bob.mintMember(member, "bob");
        (carolMemberId, ) = carol.mintMember(member, "carol");
    }

    // ============ init ============

    function testInitCreatesFirstTokenAndWiresDependencies() public view {
        require(launch.initialized(), "initialized");
        require(launch.mintAddress() == address(mintAccount), "mint");
        require(launch.memberNFTAddress() == address(member), "member");
        require(launch.rootParentTokenAddress() == ROOT, "root parent");
        require(launch.TOKEN_SYMBOL_LENGTH() == SYMBOL_LENGTH, "symbol length");
        require(launch.LAUNCH_RATIO() == LAUNCH_RATIO, "launch ratio");
        require(launch.MAX_LAUNCH_COUNT() == MAX_LAUNCH_COUNT, "max launch count");
        require(launch.LAUNCH_AMOUNT() == LAUNCH_AMOUNT, "launch amount");
        require(launch.MAX_SUPPLY() == MAX_SUPPLY, "max supply");

        // MemberNFT 由 init 同步初始化，并且只保存首币地址
        require(member.initialized(), "member initialized");
        require(member.LOVE20_TOKEN_ADDRESS() == address(firstToken), "member fee token");

        // 登记账本：首币已登记且父币为根父币
        require(launch.isLOVE20Token(address(firstToken)), "first token registered");
        require(launch.parentTokenOf(address(firstToken)) == ROOT, "first token parent");
        require(launch.tokenAddressBySymbol("LOVE") == address(firstToken), "first token symbol ledger");
        (address[] memory list, uint256 total) = launch.tokens(0, 10, false);
        require(total == 1 && list.length == 1 && list[0] == address(firstToken), "tokens list");
        (list, total) = launch.childTokens(ROOT, 0, 10, false);
        require(total == 1 && list.length == 1 && list[0] == address(firstToken), "child tokens");
        require(launch.launchCount(address(firstToken), aliceMemberId) == 0, "no launch count");

        // 首币本体
        require(keccak256(bytes(firstToken.name())) == keccak256("LOVE20"), "token name");
        require(keccak256(bytes(firstToken.symbol())) == keccak256("LOVE"), "token symbol");
        require(firstToken.balanceOf(address(this)) == LAUNCH_AMOUNT - 3 * CALLER_FUNDING, "distributor balance");
        require(firstToken.totalSupply() == LAUNCH_AMOUNT - member.totalBurnedForMint(), "supply conservation");
        require(firstToken.maxSupply() == MAX_SUPPLY, "token max supply");
        require(firstToken.minter() == address(mintAccount), "token minter");
        require(firstToken.parentTokenAddress() == ROOT, "token parent");
    }

    function testInitIsPermissionless() public {
        MemberNFT freshMember = _newMember();
        Launch freshLaunch = new Launch();

        (bool ok, ) = carol.forward(
            address(freshLaunch),
            abi.encodeWithSelector(
                ILaunch.init.selector, _params(address(freshMember), LAUNCH_AMOUNT, MAX_SUPPLY, "LOVE")
            )
        );
        require(ok, "permissionless init");
        require(freshLaunch.initialized(), "initialized");
        require(freshLaunch.mintAddress() == address(mintAccount), "mint");
        require(freshMember.initialized(), "member wired");
        require(freshLaunch.isLOVE20Token(freshMember.LOVE20_TOKEN_ADDRESS()), "first token registered");
    }

    function testInitEmitsTokenLaunchedForFirstToken() public {
        MemberNFT freshMember = _newMember();
        Launch freshLaunch = new Launch();

        vm.recordLogs();
        freshLaunch.init(_params(address(freshMember), LAUNCH_AMOUNT, MAX_SUPPLY, "LOVE"));

        address firstTokenAddress = freshMember.LOVE20_TOKEN_ADDRESS();
        bool found;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSelector = keccak256("TokenLaunched(address,address,uint256,address,string,string)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(freshLaunch) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != eventSelector) continue;
            require(logs[i].topics[1] == bytes32(uint256(uint160(firstTokenAddress))), "event token");
            require(logs[i].topics[2] == bytes32(uint256(uint160(ROOT))), "event parent");
            require(logs[i].topics[3] == bytes32(0), "event launcher member");
            (address distributorAddress, string memory name, string memory symbol) =
                abi.decode(logs[i].data, (address, string, string));
            require(distributorAddress == address(this), "event distributor");
            require(keccak256(bytes(name)) == keccak256("LOVE20"), "event name");
            require(keccak256(bytes(symbol)) == keccak256("LOVE"), "event symbol");
            found = true;
        }
        require(found, "missing TokenLaunched");
    }

    function testInitRejectsRepeatInitialization() public {
        bytes memory data = _revertOf(
            address(launch), abi.encodeWithSelector(ILaunch.init.selector, _freshParams()), "repeat init expected"
        );
        require(_selector(data) == ILaunchErrors.AlreadyInitialized.selector, "already initialized");

        // 参数非法与重复初始化同时命中时按初始化状态回滚（通用规则「初始化与安全」）
        LaunchInitParams memory invalid = _freshParams();
        invalid.mintAddress = address(0);
        data = _revertOf(
            address(launch), abi.encodeWithSelector(ILaunch.init.selector, invalid), "status before parameters expected"
        );
        require(_selector(data) == ILaunchErrors.AlreadyInitialized.selector, "initialized checked first");

        // 首币名称/符号为空同样不能越过初始化状态校验
        invalid = _freshParams();
        invalid.name = "";
        data = _revertOf(
            address(launch), abi.encodeWithSelector(ILaunch.init.selector, invalid), "status before empty name expected"
        );
        require(_selector(data) == ILaunchErrors.AlreadyInitialized.selector, "initialized before EmptyString");
    }

    function testInitRejectsZeroAddressParameters() public {
        LaunchInitParams memory params = _freshParams();
        params.mintAddress = address(0);
        _requireInitRevert(params, ILaunchErrors.InvalidAddress.selector, "mint zero");

        params = _freshParams();
        params.memberNFTAddress = address(0);
        _requireInitRevert(params, ILaunchErrors.InvalidAddress.selector, "member zero");

        params = _freshParams();
        params.rootParentTokenAddress = address(0);
        _requireInitRevert(params, ILaunchErrors.InvalidAddress.selector, "root zero");

        params = _freshParams();
        params.distributor = address(0);
        _requireInitRevert(params, ILaunchErrors.InvalidAddress.selector, "distributor zero");
    }

    function testInitRejectsZeroAmountParameters() public {
        LaunchInitParams memory params = _freshParams();
        params.launchRatio = 0;
        bytes memory data = _initRevertData(params, "zero ratio expected");
        require(_selector(data) == ILaunchErrors.ZeroAmount.selector, "ratio selector");
        require(keccak256(bytes(_argString(data))) == keccak256("launchRatio"), "ratio parameter name");

        params = _freshParams();
        params.maxLaunchCount = 0;
        data = _initRevertData(params, "zero max count expected");
        require(_selector(data) == ILaunchErrors.ZeroAmount.selector, "max count selector");
        require(keccak256(bytes(_argString(data))) == keccak256("maxLaunchCount"), "max count parameter name");

        params = _freshParams();
        params.tokenSymbolLength = 0;
        data = _initRevertData(params, "zero symbol length expected");
        require(_selector(data) == ILaunchErrors.ZeroAmount.selector, "symbol length selector");
        require(keccak256(bytes(_argString(data))) == keccak256("tokenSymbolLength"), "symbol length parameter name");
    }

    function testInitRejectsLaunchAmountAboveMaxSupply() public {
        LaunchInitParams memory params = _freshParams();
        params.launchAmount = MAX_SUPPLY + 1;
        _requireInitRevert(params, ILaunchErrors.InvalidAmount.selector, "amount above supply");
    }

    function testInitAcceptsZeroAndEqualSupplySettings() public {
        // launchAmount 与 maxSupply 可以相等
        MemberNFT equalMember = _newMember();
        Launch equalLaunch = new Launch();
        equalLaunch.init(_params(address(equalMember), MAX_SUPPLY, MAX_SUPPLY, "LOVE"));
        require(LOVE20Token(equalMember.LOVE20_TOKEN_ADDRESS()).totalSupply() == MAX_SUPPLY, "equal supply");

        // 两者可以同时为零
        MemberNFT zeroMember = _newMember();
        Launch zeroLaunch = new Launch();
        zeroLaunch.init(_params(address(zeroMember), 0, 0, "LOVE"));
        LOVE20Token zeroToken = LOVE20Token(zeroMember.LOVE20_TOKEN_ADDRESS());
        require(zeroToken.totalSupply() == 0, "zero supply");
        require(zeroToken.maxSupply() == 0, "zero max supply");
    }

    function testInitRejectsEmptyFirstTokenNameOrSymbol() public {
        LaunchInitParams memory params = _freshParams();
        params.name = "";
        bytes memory data = _initRevertData(params, "empty name expected");
        require(_selector(data) == ILaunchErrors.EmptyString.selector, "name selector");
        require(keccak256(bytes(_argString(data))) == keccak256("name"), "name parameter");

        params = _freshParams();
        params.symbol = "";
        data = _initRevertData(params, "empty symbol expected");
        require(_selector(data) == ILaunchErrors.EmptyString.selector, "symbol selector");
        require(keccak256(bytes(_argString(data))) == keccak256("symbol"), "symbol parameter");
    }

    function testInitNeverCallsDistributor() public {
        // 首币固定 NoCallback：即使 distributor 是会在回调里回滚的合约，init 也必须成功
        MemberNFT freshMember = _newMember();
        Launch freshLaunch = new Launch();
        distributor.setRejectNextCall(true);

        LaunchInitParams memory params = _params(address(freshMember), LAUNCH_AMOUNT, MAX_SUPPLY, "LOVE");
        params.distributor = address(distributor);
        freshLaunch.init(params);

        require(distributor.callCount() == 0, "no callback for the first token");
        LOVE20Token first = LOVE20Token(freshMember.LOVE20_TOKEN_ADDRESS());
        require(first.balanceOf(address(distributor)) == LAUNCH_AMOUNT, "supply delivered");
        require(freshLaunch.isLOVE20Token(address(first)), "first token registered");
    }

    function testInitRollsBackWhenMemberNftRejects() public {
        // 预置一个已初始化的 MemberNFT：init 在创建首币后调用它并因此整体回滚
        MemberNFT rejecting = _newMember();
        rejecting.init(EOA);
        Launch freshLaunch = new Launch();

        bytes memory data = _revertOf(
            address(freshLaunch),
            abi.encodeWithSelector(
                ILaunch.init.selector, _params(address(rejecting), LAUNCH_AMOUNT, MAX_SUPPLY, "LOVE")
            ),
            "member reject expected"
        );
        require(_selector(data) == IMemberNFTErrors.AlreadyInitialized.selector, "member error bubbles up");
        require(!freshLaunch.initialized(), "initialized rolled back");
        require(freshLaunch.mintAddress() == address(0), "mint rolled back");
        require(freshLaunch.rootParentTokenAddress() == address(0), "root rolled back");
        require(rejecting.LOVE20_TOKEN_ADDRESS() == EOA, "member untouched");
    }

    // ============ 代币登记与查询 ============

    function testRegistrationIsClosedToUnrelatedAddresses() public {
        Launch freshLaunch = new Launch();
        require(!freshLaunch.isLOVE20Token(address(0)), "zero before init");
        require(!freshLaunch.isLOVE20Token(EOA), "eoa before init");
        require(!freshLaunch.isLOVE20Token(address(firstToken)), "first token before init");

        // 有同名 getter 的无关合约同样返回 false，且不发起外部调用
        FakeToken fake = new FakeToken(ROOT, "LOVE");
        require(!launch.isLOVE20Token(address(fake)), "fake token");
        require(launch.parentTokenOf(address(fake)) == address(0), "fake parent ledger");
        require(!launch.isLOVE20Token(EOA), "eoa");
        require(!launch.isLOVE20Token(address(0)), "zero address");
        require(!launch.isLOVE20Token(address(member)), "unrelated contract");
        require(!launch.isLOVE20Token(address(launch)), "launch itself");
    }

    function testUnregisteredQueriesReturnZeroWithoutReverting() public {
        FakeToken fake = new FakeToken(ROOT, "LOVE");
        require(launch.launchCount(address(fake), 1) == 0, "launch count");
        require(launch.issuedLaunchCount(address(fake)) == 0, "issued count");
        require(launch.launchCount(address(firstToken), 999) == 0, "unknown member");
        require(launch.tokenAddressBySymbol("ZZZ") == address(0), "unknown symbol");
        require(launch.parentTokenOf(address(0)) == address(0), "zero parent");
        (address[] memory list, uint256 total) = launch.childTokens(EOA, 0, 10, false);
        require(total == 0 && list.length == 0, "unknown parent children");
    }

    function testFirstTokenSymbolIsNotAValidSubTokenSymbol() public {
        // 首币符号长度为 4、子币长度配置为 3：首币本身不受该配置约束（见 init 用例的 symbol 断言），
        // 但首币的符号不能反过来当作合法的子币符号发射
        require(bytes(firstToken.symbol()).length == 4, "fixture length");
        require(SYMBOL_LENGTH == 3, "fixture configuration");

        _grantCount(address(firstToken), aliceMemberId, 1);
        (bool ok, bytes memory data) = _launch(alice, "LOVE", address(firstToken), aliceMemberId);
        require(!ok, "first token symbol is not a valid sub-token symbol");
        require(_selector(data) == ILaunchErrors.InvalidTokenSymbol.selector, "symbol length rule");
    }

    // ============ launchToken ============

    function testLaunchTokenCreatesRegistersAndConsumesCount() public {
        _grantCount(address(firstToken), aliceMemberId, 2);
        uint256 issuedBefore = launch.issuedLaunchCount(address(firstToken));

        address tokenAddress = _launchOk(alice, "AAA", address(firstToken), aliceMemberId);
        LOVE20Token subToken = LOVE20Token(tokenAddress);

        require(keccak256(bytes(subToken.name())) == keccak256("AAA@LOVE"), "name");
        require(keccak256(bytes(subToken.symbol())) == keccak256("AAA"), "symbol");
        require(subToken.totalSupply() == LAUNCH_AMOUNT, "supply");
        require(subToken.balanceOf(SUB_DISTRIBUTOR) == LAUNCH_AMOUNT, "distributed to distributor");
        require(subToken.maxSupply() == MAX_SUPPLY, "max supply");
        require(subToken.minter() == address(mintAccount), "minter");
        require(subToken.parentTokenAddress() == address(firstToken), "token parent");

        require(launch.isLOVE20Token(tokenAddress), "registered");
        require(launch.parentTokenOf(tokenAddress) == address(firstToken), "parent ledger");
        require(launch.tokenAddressBySymbol("AAA") == tokenAddress, "symbol ledger");
        require(launch.launchCount(address(firstToken), aliceMemberId) == 1, "count consumed");
        require(launch.launchCount(address(firstToken), bobMemberId) == 0, "other member untouched");
        require(launch.issuedLaunchCount(address(firstToken)) == issuedBefore, "issued unchanged");

        (address[] memory list, uint256 total) = launch.tokens(0, 10, false);
        require(total == 2 && list[1] == tokenAddress, "appended to token list");
        (list, total) = launch.childTokens(address(firstToken), 0, 10, false);
        require(total == 1 && list[0] == tokenAddress, "child list");
    }

    function testLaunchTokenEmitsTokenLaunched() public {
        _grantCount(address(firstToken), aliceMemberId, 1);

        vm.recordLogs();
        address tokenAddress = _launchOk(alice, "AAA", address(firstToken), aliceMemberId);

        bool found;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSelector = keccak256("TokenLaunched(address,address,uint256,address,string,string)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(launch) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != eventSelector) continue;
            require(logs[i].topics[1] == bytes32(uint256(uint160(tokenAddress))), "event token");
            require(logs[i].topics[2] == bytes32(uint256(uint160(address(firstToken)))), "event parent");
            require(logs[i].topics[3] == bytes32(aliceMemberId), "event launcher member");
            (address distributorAddress, string memory name, string memory symbol) =
                abi.decode(logs[i].data, (address, string, string));
            require(distributorAddress == SUB_DISTRIBUTOR, "event distributor");
            require(keccak256(bytes(name)) == keccak256("AAA@LOVE"), "event name");
            require(keccak256(bytes(symbol)) == keccak256("AAA"), "event symbol");
            found = true;
        }
        require(found, "missing TokenLaunched");
        // 反向断言：只发一条 TokenLaunched，且不产生其它 Launch 事件
        require(_countLogs(logs, address(launch), eventSelector) == 1, "exactly one TokenLaunched");
        require(_countLogs(logs, address(launch), keccak256("LaunchCountAdded(address,uint256,uint256)")) == 0, "no added");
        require(_countLogs(logs, address(launch), keccak256("LaunchCountMerged(address,uint256,uint256,uint256)")) == 0, "no merged");
        require(_countLogs(logs, address(launch), keccak256("TokenCreated(address,address,string,string,address)")) == 0, "no TokenCreated");
    }

    function testLaunchTokenRejectsInvalidSymbols() public {
        string[] memory invalid = new string[](14);
        invalid[0] = "";
        invalid[1] = "AA";
        invalid[2] = "AAAA";
        invalid[3] = "1AA";
        invalid[4] = "aAA";
        invalid[5] = "A1a";
        invalid[6] = "A-A";
        invalid[7] = "A A";
        // 紧邻允许区间的字符：首字符下界 0x40('@')、上界 0x5B('[')；其余字符 0x2F('/')、
        // 0x3A(':')、0x40('@')、0x5B('[')，用来钉住四个边界的放宽变异
        invalid[8] = "@AA";
        invalid[9] = "[AA";
        invalid[10] = "A/A";
        invalid[11] = "A:A";
        invalid[12] = "A@A";
        invalid[13] = "A[A";

        _grantCount(address(firstToken), aliceMemberId, 2);
        for (uint256 i; i < invalid.length; ++i) {
            (bool ok, bytes memory data) = _launch(alice, invalid[i], address(firstToken), aliceMemberId);
            require(!ok, "invalid symbol must revert");
            require(_selector(data) == ILaunchErrors.InvalidTokenSymbol.selector, "symbol selector");
        }
        require(launch.launchCount(address(firstToken), aliceMemberId) == 2, "no count consumed");

        // 合法符号：首字符 A-Z，其余 A-Z0-9
        address firstAddress = _launchOk(alice, "A0Z", address(firstToken), aliceMemberId);
        address secondAddress = _launchOk(alice, "ZZ9", address(firstToken), aliceMemberId);
        require(firstAddress != secondAddress, "distinct tokens");
        require(launch.launchCount(address(firstToken), aliceMemberId) == 0, "both counts consumed");
    }

    function testLaunchTokenRejectsZeroDistributor() public {
        _grantCount(address(firstToken), aliceMemberId, 1);
        (bool ok, bytes memory data) = alice.forward(
            address(launch),
            _launchCalldata(
                "AAA",
                address(firstToken),
                aliceMemberId,
                address(0),
                DistributorMode.NoCallback,
                _emptyData()
            )
        );
        require(!ok, "zero distributor must revert");
        require(_selector(data) == ILaunchErrors.InvalidAddress.selector, "address selector");
    }

    function testLaunchTokenEnforcesDataAndModeRules() public {
        _grantCount(address(firstToken), aliceMemberId, 1);

        bytes[] memory oneValue = new bytes[](1);
        oneValue[0] = hex"aabb";

        // NoCallback 忽略 data 数组，且不调用回调
        (bool ok, bytes memory data) = alice.forward(
            address(launch),
            _launchCalldata(
                "AAA",
                address(firstToken),
                aliceMemberId,
                address(distributor),
                DistributorMode.NoCallback,
                oneValue
            )
        );
        require(ok, "no callback ignores data");
        address tokenAddress = abi.decode(data, (address));
        require(tokenAddress != address(0), "token created");
        require(distributor.callCount() == 0, "no callback invoked");

        // Callback 要求 distributor 是合约
        (ok, data) = alice.forward(
            address(launch),
            _launchCalldata(
                "AAA",
                address(firstToken),
                aliceMemberId,
                EOA,
                DistributorMode.Callback,
                _emptyData()
            )
        );
        require(!ok, "eoa callback must revert");
        require(_selector(data) == ILaunchErrors.InvalidDistributorMode.selector, "mode selector");

        require(launch.launchCount(address(firstToken), aliceMemberId) == 0, "count consumed");
    }

    function testLaunchTokenInvokesCallbackDistributor() public {
        _grantCount(address(firstToken), aliceMemberId, 1);

        bytes[] memory data = new bytes[](2);
        data[0] = hex"aabb";
        data[1] = hex"cc";

        (bool ok, bytes memory returnData) = alice.forward(
            address(launch),
            _launchCalldata(
                "AAA", address(firstToken), aliceMemberId, address(distributor), DistributorMode.Callback, data
            )
        );
        require(ok, "callback launch");
        address tokenAddress = abi.decode(returnData, (address));

        require(distributor.callCount() == 1, "called once");
        require(distributor.lastTokenAddress() == tokenAddress, "callback token");
        require(distributor.lastParentTokenAddress() == address(firstToken), "callback parent");
        require(distributor.lastLauncherMemberId() == aliceMemberId, "callback member");
        require(keccak256(distributor.lastData(0)) == keccak256(hex"aabb"), "data 0");
        require(distributor.lastData(1).length == 1, "data 1");
        require(LOVE20Token(tokenAddress).balanceOf(address(distributor)) == LAUNCH_AMOUNT, "supply to distributor");
        require(launch.isLOVE20Token(tokenAddress), "registered before callback");
    }

    function testLaunchTokenNoCallbackSkipsContractCallback() public {
        _grantCount(address(firstToken), aliceMemberId, 1);

        (bool ok, bytes memory data) = alice.forward(
            address(launch),
            _launchCalldata(
                "AAA",
                address(firstToken),
                aliceMemberId,
                address(distributor),
                DistributorMode.NoCallback,
                _emptyData()
            )
        );
        require(ok, "no callback launch");
        address tokenAddress = abi.decode(data, (address));
        require(distributor.callCount() == 0, "callback skipped");
        require(LOVE20Token(tokenAddress).balanceOf(address(distributor)) == LAUNCH_AMOUNT, "supply delivered");
    }

    function testLaunchTokenCallbackObservesCompletedRegistration() public {
        _grantCount(address(firstToken), aliceMemberId, 2);
        distributor.setProbe(launch);

        (bool ok, bytes memory data) = alice.forward(
            address(launch),
            _launchCalldata(
                "AAA",
                address(firstToken),
                aliceMemberId,
                address(distributor),
                DistributorMode.Callback,
                _emptyData()
            )
        );
        require(ok, "callback launch");
        address tokenAddress = abi.decode(data, (address));

        // 回调时：代币已创建并收到首批供应、已登记、次数已扣减
        require(distributor.observedBalance() == LAUNCH_AMOUNT, "supply delivered before callback");
        require(distributor.observedRegistered(), "registration before callback");
        require(distributor.observedLaunchCount() == 1, "count consumed before callback");
        require(launch.launchCount(address(firstToken), aliceMemberId) == 1, "count after launch");
        require(launch.isLOVE20Token(tokenAddress), "token stays registered");
    }

    function testLaunchTokenCallbackFailureRollsBack() public {
        _grantCount(address(firstToken), aliceMemberId, 1);
        distributor.setRejectNextCall(true);

        (bool ok, bytes memory data) = alice.forward(
            address(launch),
            _launchCalldata(
                "AAA",
                address(firstToken),
                aliceMemberId,
                address(distributor),
                DistributorMode.Callback,
                _emptyData()
            )
        );
        require(!ok, "callback failure must revert");
        require(_selector(data) == DistributorCallbackFailed.selector, "callback error bubbles up");

        require(launch.launchCount(address(firstToken), aliceMemberId) == 1, "count restored");
        require(launch.tokenAddressBySymbol("AAA") == address(0), "symbol not registered");
        (address[] memory list, uint256 total) = launch.tokens(0, 10, false);
        require(total == 1 && list.length == 1, "no token appended");
        require(launch.issuedLaunchCount(address(firstToken)) == 1, "issued unchanged");
    }

    function testLaunchTokenRejectsUnregisteredParent() public {
        _grantCount(address(firstToken), aliceMemberId, 1);
        FakeToken fake = new FakeToken(ROOT, "FAKE");

        address[4] memory parents = [address(0), EOA, address(fake), address(member)];
        for (uint256 i; i < parents.length; ++i) {
            (bool ok, bytes memory data) = _launch(alice, "AAA", parents[i], aliceMemberId);
            require(!ok, "unregistered parent must revert");
            require(_selector(data) == ILaunchErrors.InvalidParentToken.selector, "parent selector");
        }
        require(launch.launchCount(address(firstToken), aliceMemberId) == 1, "count untouched");
    }

    function testLaunchTokenRejectsMissingMember() public {
        // 即使次数账本有余量，不存在的 memberId 也必须先由 MemberNFT 的标准错误回滚
        _grantCount(address(firstToken), 999, 1);
        _grantCount(address(firstToken), 0, 1);

        (bool ok, bytes memory data) = _launch(alice, "AAA", address(firstToken), 999);
        require(!ok, "missing member must revert");
        require(_selector(data) == IERC721Errors.ERC721NonexistentToken.selector, "member nft error");
        require(_argUint(data) == 999, "error member id");

        (ok, data) = _launch(alice, "AAA", address(firstToken), 0);
        require(!ok, "zero member must revert");
        require(_selector(data) == IERC721Errors.ERC721NonexistentToken.selector, "zero member nft error");

        require(launch.launchCount(address(firstToken), 999) == 1, "count untouched");
    }

    function testLaunchTokenRejectsNonOwner() public {
        _grantCount(address(firstToken), aliceMemberId, 1);

        (bool ok, bytes memory data) = _launch(bob, "AAA", address(firstToken), aliceMemberId);
        require(!ok, "non owner must revert");
        require(_selector(data) == ILaunchErrors.NotMemberOwner.selector, "owner selector");
        require(_argUint(data) == aliceMemberId, "error member id");
        require(launch.launchCount(address(firstToken), aliceMemberId) == 1, "count untouched");
    }

    function testLaunchTokenRequiresAvailableCount() public {
        (bool ok, bytes memory data) = _launch(alice, "AAA", address(firstToken), aliceMemberId);
        require(!ok, "empty ledger must revert");
        require(_selector(data) == ILaunchErrors.NotEnoughLaunchCount.selector, "count selector");

        _grantCount(address(firstToken), aliceMemberId, 1);
        _launchOk(alice, "AAA", address(firstToken), aliceMemberId);

        (ok, data) = _launch(alice, "BBB", address(firstToken), aliceMemberId);
        require(!ok, "consumed count must revert");
        require(_selector(data) == ILaunchErrors.NotEnoughLaunchCount.selector, "consumed selector");
        require(launch.launchCount(address(firstToken), aliceMemberId) == 0, "ledger drained");
        require(launch.tokenAddressBySymbol("BBB") == address(0), "nothing created");
    }

    function testLaunchTokenChecksParametersThenExistenceThenOwnershipThenLedger() public {
        // 参数优先：符号非法 + distributor 为零
        (bool ok, bytes memory data) = alice.forward(
            address(launch),
            _launchCalldata(
                "aa", address(firstToken), aliceMemberId, address(0), DistributorMode.NoCallback, _emptyData()
            )
        );
        require(!ok && _selector(data) == ILaunchErrors.InvalidTokenSymbol.selector, "symbol before distributor");

        // 参数优先：distributor 为零 + 父币未登记
        (ok, data) = alice.forward(
            address(launch),
            _launchCalldata(
                "AAA", address(0), aliceMemberId, address(0), DistributorMode.NoCallback, _emptyData()
            )
        );
        require(!ok && _selector(data) == ILaunchErrors.InvalidAddress.selector, "distributor before parent");

        // 存在性优先于持有：父币未登记 + 调用者不持有该成员
        (ok, data) = _launch(bob, "AAA", address(0), aliceMemberId);
        require(!ok && _selector(data) == ILaunchErrors.InvalidParentToken.selector, "parent before ownership");

        // 持有优先于账本：不持有成员 + 账本为零
        (ok, data) = _launch(bob, "AAA", address(firstToken), aliceMemberId);
        require(!ok && _selector(data) == ILaunchErrors.NotMemberOwner.selector, "ownership before ledger");

        require(launch.launchCount(address(firstToken), aliceMemberId) == 0, "no state change");
        require(launch.tokenAddressBySymbol("AAA") == address(0), "no token created");
    }

    function testLaunchCountFollowsMemberTransfer() public {
        _grantCount(address(firstToken), aliceMemberId, 1);
        alice.transferMember(member, address(bob), aliceMemberId);
        require(member.ownerOf(aliceMemberId) == address(bob), "transferred");

        (bool ok, bytes memory data) = _launch(alice, "AAA", address(firstToken), aliceMemberId);
        require(!ok, "former owner must revert");
        require(_selector(data) == ILaunchErrors.NotMemberOwner.selector, "owner selector");

        _launchOk(bob, "AAA", address(firstToken), aliceMemberId);
        require(launch.launchCount(address(firstToken), aliceMemberId) == 0, "count follows the member id");
    }

    function testLaunchTokenRejectsDuplicateSymbol() public {
        _grantCount(address(firstToken), aliceMemberId, 2);
        _launchOk(alice, "AAA", address(firstToken), aliceMemberId);
        address secondParent = _launchOk(alice, "BBB", address(firstToken), aliceMemberId);

        // 符号全局唯一：换父币也撞
        _grantCount(secondParent, aliceMemberId, 1);
        (bool ok, bytes memory data) = _launch(alice, "AAA", secondParent, aliceMemberId);
        require(!ok, "duplicate symbol must revert");
        require(_selector(data) == ILaunchErrors.TokenSymbolExists.selector, "duplicate selector");
        require(launch.launchCount(secondParent, aliceMemberId) == 1, "count untouched");

        // 首币符号占位同一账本：首币符号长度为 3 的部署下无法再发射同名子币
        (Launch booted, LOVE20Token bootedToken, , uint256 memberId) = _bootSystem("LOV", carol, "dave");
        _grantCountAt(booted, address(bootedToken), memberId, 1);
        (ok, data) = _launchAt(booted, carol, "LOV", address(bootedToken), memberId);
        require(!ok, "first token symbol occupies the ledger");
        require(_selector(data) == ILaunchErrors.TokenSymbolExists.selector, "first token symbol selector");
    }

    function testLaunchTokenAppliesTestPrefixAndChecksFinalSymbol() public {
        (Launch booted, LOVE20Token bootedToken, , uint256 memberId) = _bootSystem("TestLOVE", carol, "dave");
        require(keccak256(bytes(bootedToken.symbol())) == keccak256("TestLOVE"), "first token symbol untouched");
        require(booted.tokenAddressBySymbol("TestLOVE") == address(bootedToken), "first token ledger");

        _grantCountAt(booted, address(bootedToken), memberId, 2);
        address prefixed = _launchOkAt(booted, carol, "AAA", address(bootedToken), memberId);
        LOVE20Token prefixedToken = LOVE20Token(prefixed);

        // 前缀施加在校验之后，最终符号与名称都带前缀
        require(keccak256(bytes(prefixedToken.symbol())) == keccak256("TestAAA"), "prefixed symbol");
        require(keccak256(bytes(prefixedToken.name())) == keccak256("TestAAA@TestLOVE"), "prefixed name");
        require(booted.tokenAddressBySymbol("TestAAA") == prefixed, "final symbol ledger");
        require(booted.tokenAddressBySymbol("AAA") == address(0), "unprefixed symbol not registered");

        // 唯一性按最终符号判定
        (bool ok, bytes memory data) = _launchAt(booted, carol, "AAA", address(bootedToken), memberId);
        require(!ok, "duplicate final symbol must revert");
        require(_selector(data) == ILaunchErrors.TokenSymbolExists.selector, "final symbol selector");
    }

    // ============ mergeLaunchCount ============

    function testMergeLaunchCountMovesCountAndEmits() public {
        _grantCount(address(firstToken), aliceMemberId, 5);
        _grantCount(address(firstToken), bobMemberId, 1);

        vm.recordLogs();
        (bool ok, ) = _merge(alice, address(firstToken), aliceMemberId, bobMemberId, 3);
        require(ok, "merge");

        require(launch.launchCount(address(firstToken), aliceMemberId) == 2, "source decreased");
        require(launch.launchCount(address(firstToken), bobMemberId) == 4, "target increased");
        require(launch.issuedLaunchCount(address(firstToken)) == 6, "issued unchanged");

        bool found;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSelector = keccak256("LaunchCountMerged(address,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(launch) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != eventSelector) continue;
            require(logs[i].topics[1] == bytes32(uint256(uint160(address(firstToken)))), "event token");
            require(logs[i].topics[2] == bytes32(aliceMemberId), "event source");
            require(logs[i].topics[3] == bytes32(bobMemberId), "event target");
            require(abi.decode(logs[i].data, (uint256)) == 3, "event count");
            found = true;
        }
        require(found, "missing LaunchCountMerged");
        // 反向断言：只发一条 LaunchCountMerged，且不产生其它 Launch 事件
        require(_countLogs(logs, address(launch), eventSelector) == 1, "exactly one LaunchCountMerged");
        require(
            _countLogs(logs, address(launch), keccak256("TokenLaunched(address,address,uint256,address,string,string)")) == 0,
            "no launch event"
        );
        require(_countLogs(logs, address(launch), keccak256("LaunchCountAdded(address,uint256,uint256)")) == 0, "no added");

        // 目标不需要由调用者持有：向 carol 的成员融合同样成立
        (ok, ) = _merge(alice, address(firstToken), aliceMemberId, carolMemberId, 2);
        require(ok, "merge to third party");
        require(launch.launchCount(address(firstToken), aliceMemberId) == 0, "source drained");
        require(launch.launchCount(address(firstToken), carolMemberId) == 2, "third party increased");
    }

    function testMergeLaunchCountRejectsSameMemberOrZeroCount() public {
        _grantCount(address(firstToken), aliceMemberId, 5);

        (bool ok, bytes memory data) = _merge(alice, address(firstToken), aliceMemberId, aliceMemberId, 1);
        require(!ok, "same member must revert");
        require(_selector(data) == ILaunchErrors.SourceAndTargetMustBeDifferent.selector, "same member selector");

        (ok, data) = _merge(alice, address(firstToken), aliceMemberId, bobMemberId, 0);
        require(!ok, "zero count must revert");
        require(_selector(data) == ILaunchErrors.CountMustBeGreaterThanZero.selector, "zero count selector");

        require(launch.launchCount(address(firstToken), aliceMemberId) == 5, "ledger untouched");
    }

    function testMergeLaunchCountRejectsUnregisteredToken() public {
        _grantCount(address(firstToken), aliceMemberId, 5);
        FakeToken fake = new FakeToken(ROOT, "FAKE");

        (bool ok, bytes memory data) = _merge(alice, address(fake), aliceMemberId, bobMemberId, 1);
        require(!ok, "unregistered token must revert");
        require(_selector(data) == ILaunchErrors.InvalidTokenAddress.selector, "token selector");

        (ok, data) = _merge(alice, EOA, aliceMemberId, bobMemberId, 1);
        require(!ok, "eoa token must revert");
        require(_selector(data) == ILaunchErrors.InvalidTokenAddress.selector, "eoa token selector");

        require(launch.launchCount(address(firstToken), aliceMemberId) == 5, "ledger untouched");
    }

    function testMergeLaunchCountRejectsMissingMembers() public {
        _grantCount(address(firstToken), 999, 5);
        _grantCount(address(firstToken), 0, 5);

        (bool ok, bytes memory data) = _merge(alice, address(firstToken), 999, bobMemberId, 1);
        require(!ok, "missing source must revert");
        require(_selector(data) == IERC721Errors.ERC721NonexistentToken.selector, "source member error");
        require(_argUint(data) == 999, "source member id");

        (ok, data) = _merge(alice, address(firstToken), aliceMemberId, 999, 1);
        require(!ok, "missing target must revert");
        require(_selector(data) == IERC721Errors.ERC721NonexistentToken.selector, "target member error");
        require(_argUint(data) == 999, "target member id");

        // memberId 不从 0 开始，0 永远无效：源与目标两个方向都覆盖
        (ok, data) = _merge(alice, address(firstToken), 0, bobMemberId, 1);
        require(!ok, "zero source must revert");
        require(_selector(data) == IERC721Errors.ERC721NonexistentToken.selector, "zero source error");
        require(_argUint(data) == 0, "zero source member id");

        (ok, data) = _merge(alice, address(firstToken), aliceMemberId, 0, 1);
        require(!ok, "zero target must revert");
        require(_selector(data) == IERC721Errors.ERC721NonexistentToken.selector, "zero target error");
        require(_argUint(data) == 0, "zero target member id");
    }

    function testMergeLaunchCountRejectsNonOwner() public {
        _grantCount(address(firstToken), aliceMemberId, 5);

        (bool ok, bytes memory data) = _merge(bob, address(firstToken), aliceMemberId, bobMemberId, 1);
        require(!ok, "non owner must revert");
        require(_selector(data) == ILaunchErrors.NotMemberOwner.selector, "owner selector");
        require(_argUint(data) == aliceMemberId, "error member id");
        require(launch.launchCount(address(firstToken), aliceMemberId) == 5, "ledger untouched");
    }

    function testMergeLaunchCountRejectsInsufficientCount() public {
        _grantCount(address(firstToken), aliceMemberId, 2);

        (bool ok, bytes memory data) = _merge(alice, address(firstToken), aliceMemberId, bobMemberId, 3);
        require(!ok, "insufficient count must revert");
        require(_selector(data) == ILaunchErrors.NotEnoughLaunchCount.selector, "count selector");
        require(launch.launchCount(address(firstToken), aliceMemberId) == 2, "source untouched");
        require(launch.launchCount(address(firstToken), bobMemberId) == 0, "target untouched");
    }

    function testMergeLaunchCountChecksParametersThenExistenceThenOwnershipThenLedger() public {
        // 参数优先：同成员 + count 为零
        (bool ok, bytes memory data) = _merge(alice, address(firstToken), aliceMemberId, aliceMemberId, 0);
        require(!ok && _selector(data) == ILaunchErrors.SourceAndTargetMustBeDifferent.selector, "same before count");

        // 参数优先于存在性：count 为零 + 未登记 token
        (ok, data) = _merge(alice, EOA, aliceMemberId, bobMemberId, 0);
        require(!ok && _selector(data) == ILaunchErrors.CountMustBeGreaterThanZero.selector, "count before token");

        // 存在性优先于持有：未登记 token + 不存在的成员
        (ok, data) = _merge(bob, EOA, 999, bobMemberId, 1);
        require(!ok && _selector(data) == ILaunchErrors.InvalidTokenAddress.selector, "token before member");

        // 存在性优先于持有：源成员不存在 + 调用者不持有
        (ok, data) = _merge(bob, address(firstToken), 999, bobMemberId, 1);
        require(!ok && _selector(data) == IERC721Errors.ERC721NonexistentToken.selector, "member before ownership");

        // 持有优先于账本：不持有源 + 源次数不足
        (ok, data) = _merge(bob, address(firstToken), aliceMemberId, bobMemberId, 1);
        require(!ok && _selector(data) == ILaunchErrors.NotMemberOwner.selector, "ownership before ledger");
    }

    // ============ addLaunchCount ============

    function testAddLaunchCountUpdatesBothLedgersAndEmits() public {
        vm.recordLogs();
        mintAccount.addLaunchCount(launch, address(firstToken), aliceMemberId, 4);

        require(launch.launchCount(address(firstToken), aliceMemberId) == 4, "launch count");
        require(launch.issuedLaunchCount(address(firstToken)) == 4, "issued count");

        bool found;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSelector = keccak256("LaunchCountAdded(address,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(launch) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != eventSelector) continue;
            require(logs[i].topics[1] == bytes32(uint256(uint160(address(firstToken)))), "event token");
            require(logs[i].topics[2] == bytes32(aliceMemberId), "event member");
            require(abi.decode(logs[i].data, (uint256)) == 4, "event count");
            found = true;
        }
        require(found, "missing LaunchCountAdded");
        // 反向断言：只发一条 LaunchCountAdded，且不产生其它 Launch 事件
        require(_countLogs(logs, address(launch), eventSelector) == 1, "exactly one LaunchCountAdded");
        require(_countLogs(logs, address(launch), keccak256("LaunchCountMerged(address,uint256,uint256,uint256)")) == 0, "no merged");
        require(
            _countLogs(logs, address(launch), keccak256("TokenLaunched(address,address,uint256,address,string,string)")) == 0,
            "no launch event"
        );

        // 累加而不是覆盖
        mintAccount.addLaunchCount(launch, address(firstToken), aliceMemberId, 1);
        require(launch.launchCount(address(firstToken), aliceMemberId) == 5, "accumulated");
        require(launch.issuedLaunchCount(address(firstToken)) == 5, "issued accumulated");
    }

    function testAddLaunchCountRejectsUnauthorizedCaller() public {
        (bool ok, bytes memory data) = alice.forward(
            address(launch), abi.encodeWithSelector(ILaunch.addLaunchCount.selector, address(firstToken), aliceMemberId, 1)
        );
        require(!ok, "non mint caller must revert");
        require(_selector(data) == ILaunchErrors.UnauthorizedCaller.selector, "caller selector");

        (ok, data) = carol.forward(
            address(launch), abi.encodeWithSelector(ILaunch.addLaunchCount.selector, address(firstToken), aliceMemberId, 1)
        );
        require(!ok, "another caller must revert");
        require(_selector(data) == ILaunchErrors.UnauthorizedCaller.selector, "caller selector");

        require(launch.launchCount(address(firstToken), aliceMemberId) == 0, "ledger untouched");
        require(launch.issuedLaunchCount(address(firstToken)) == 0, "issued untouched");
    }

    function testAddLaunchCountRejectsZeroCountAndUnregisteredToken() public {
        (bool ok, bytes memory data) = mintAccount.forward(
            address(launch), abi.encodeWithSelector(ILaunch.addLaunchCount.selector, address(firstToken), aliceMemberId, 0)
        );
        require(!ok, "zero count must revert");
        require(_selector(data) == ILaunchErrors.CountMustBeGreaterThanZero.selector, "zero count selector");

        FakeToken fake = new FakeToken(ROOT, "FAKE");
        (ok, data) = mintAccount.forward(
            address(launch), abi.encodeWithSelector(ILaunch.addLaunchCount.selector, address(fake), aliceMemberId, 1)
        );
        require(!ok, "unregistered token must revert");
        require(_selector(data) == ILaunchErrors.InvalidTokenAddress.selector, "token selector");

        (ok, data) = mintAccount.forward(
            address(launch), abi.encodeWithSelector(ILaunch.addLaunchCount.selector, EOA, aliceMemberId, 1)
        );
        require(!ok, "eoa token must revert");
        require(_selector(data) == ILaunchErrors.InvalidTokenAddress.selector, "eoa token selector");
    }

    function testAddLaunchCountEnforcesCommunityCap() public {
        mintAccount.addLaunchCount(launch, address(firstToken), aliceMemberId, MAX_LAUNCH_COUNT);
        require(launch.issuedLaunchCount(address(firstToken)) == MAX_LAUNCH_COUNT, "issued at cap");
        require(launch.launchCount(address(firstToken), aliceMemberId) == MAX_LAUNCH_COUNT, "count at cap");

        // 到达上限后任何增量都回滚，极端大值也不能以算术溢出收场
        (bool ok, bytes memory data) = mintAccount.forward(
            address(launch), abi.encodeWithSelector(ILaunch.addLaunchCount.selector, address(firstToken), aliceMemberId, 1)
        );
        require(!ok, "cap reached must revert");
        require(_selector(data) == ILaunchErrors.LaunchCountLimitReached.selector, "cap selector");

        (ok, data) = mintAccount.forward(
            address(launch),
            abi.encodeWithSelector(ILaunch.addLaunchCount.selector, address(firstToken), aliceMemberId, type(uint256).max)
        );
        require(!ok, "extreme count must revert");
        require(_selector(data) == ILaunchErrors.LaunchCountLimitReached.selector, "extreme count selector");

        require(launch.issuedLaunchCount(address(firstToken)) == MAX_LAUNCH_COUNT, "issued unchanged");

        // 消耗与融合都不释放累计上限
        _launchOk(alice, "AAA", address(firstToken), aliceMemberId);
        (ok, ) = _merge(alice, address(firstToken), aliceMemberId, bobMemberId, 1);
        require(ok, "merge after cap");
        require(launch.issuedLaunchCount(address(firstToken)) == MAX_LAUNCH_COUNT, "issued never decreases");

        (ok, data) = mintAccount.forward(
            address(launch), abi.encodeWithSelector(ILaunch.addLaunchCount.selector, address(firstToken), carolMemberId, 1)
        );
        require(!ok, "consumption does not free the cap");
        require(_selector(data) == ILaunchErrors.LaunchCountLimitReached.selector, "cap selector after use");
    }

    function testAddLaunchCountChecksPermissionThenParametersThenExistence() public {
        // 权限优先：非 Mint + count 为零
        (bool ok, bytes memory data) = alice.forward(
            address(launch), abi.encodeWithSelector(ILaunch.addLaunchCount.selector, address(firstToken), aliceMemberId, 0)
        );
        require(!ok && _selector(data) == ILaunchErrors.UnauthorizedCaller.selector, "permission before count");

        // 参数优先于存在性：count 为零 + 未登记 token
        (ok, data) = mintAccount.forward(
            address(launch), abi.encodeWithSelector(ILaunch.addLaunchCount.selector, EOA, aliceMemberId, 0)
        );
        require(!ok && _selector(data) == ILaunchErrors.CountMustBeGreaterThanZero.selector, "count before token");

        // 存在性优先于上限：未登记 token + 超过上限的次数
        (ok, data) = mintAccount.forward(
            address(launch),
            abi.encodeWithSelector(ILaunch.addLaunchCount.selector, EOA, aliceMemberId, type(uint256).max)
        );
        require(!ok && _selector(data) == ILaunchErrors.InvalidTokenAddress.selector, "token before cap");
    }

    function testWriteEntriesDoNotValidateInitialized() public {
        Launch freshLaunch = new Launch();
        require(!freshLaunch.initialized(), "fixture");

        // launchToken：先命中符号长度校验（未初始化时长度配置为 0），不是 AlreadyInitialized
        (bool ok, bytes memory data) = _launchAt(freshLaunch, alice, "AAA", address(firstToken), aliceMemberId);
        require(!ok, "uninitialized launch must revert");
        require(_selector(data) == ILaunchErrors.InvalidTokenSymbol.selector, "symbol check first");

        // mergeLaunchCount：先命中代币登记校验（未初始化时无任何登记）
        (ok, data) = alice.forward(
            address(freshLaunch),
            abi.encodeWithSelector(ILaunch.mergeLaunchCount.selector, address(firstToken), aliceMemberId, bobMemberId, 1)
        );
        require(!ok, "uninitialized merge must revert");
        require(_selector(data) == ILaunchErrors.InvalidTokenAddress.selector, "token check first");

        // addLaunchCount：先命中调用者校验（未初始化时 mintAddress 为零地址）
        (ok, data) = mintAccount.forward(
            address(freshLaunch),
            abi.encodeWithSelector(ILaunch.addLaunchCount.selector, address(firstToken), aliceMemberId, 1)
        );
        require(!ok, "uninitialized add must revert");
        require(_selector(data) == ILaunchErrors.UnauthorizedCaller.selector, "caller check first");
    }

    // ============ 分页查询 ============

    function testTokensPaginationBoundaries() public {
        _grantCount(address(firstToken), aliceMemberId, 2);
        address second = _launchOk(alice, "AAA", address(firstToken), aliceMemberId);
        address third = _launchOk(alice, "BBB", address(firstToken), aliceMemberId);

        (address[] memory list, uint256 total) = launch.tokens(0, 100, false);
        require(total == 3, "total count");
        require(list.length == 3, "full page");
        require(list[0] == address(firstToken), "index 0 is first token");
        require(list[1] == second && list[2] == third, "creation order");

        // limit 截断
        (list, total) = launch.tokens(0, 2, false);
        require(total == 3 && list.length == 2, "clamped page");
        require(list[0] == address(firstToken) && list[1] == second, "clamped content");

        // limit 为零返回空数组与真实总数
        (list, total) = launch.tokens(0, 0, false);
        require(total == 3 && list.length == 0, "zero limit");

        // offset 等于总数与超过总数都返回空数组与真实总数
        (list, total) = launch.tokens(3, 10, false);
        require(total == 3 && list.length == 0, "offset at total");
        (list, total) = launch.tokens(99, 10, false);
        require(total == 3 && list.length == 0, "offset beyond total");

        // 中间页
        (list, total) = launch.tokens(1, 10, false);
        require(total == 3 && list.length == 2 && list[0] == second, "tail page");

        // reverse 从新到旧
        (list, total) = launch.tokens(0, 100, true);
        require(total == 3 && list.length == 3, "reverse full page");
        require(list[0] == third && list[1] == second && list[2] == address(firstToken), "reverse order");
        (list, total) = launch.tokens(1, 2, true);
        require(total == 3 && list.length == 2 && list[0] == second && list[1] == address(firstToken), "reverse tail");
    }

    function testChildTokensPaginationAndUnknownParent() public {
        _grantCount(address(firstToken), aliceMemberId, 2);
        address childA = _launchOk(alice, "AAA", address(firstToken), aliceMemberId);
        address childB = _launchOk(alice, "BBB", address(firstToken), aliceMemberId);

        // 首币是其根父币的子币
        (address[] memory list, uint256 total) = launch.childTokens(ROOT, 0, 10, false);
        require(total == 1 && list.length == 1 && list[0] == address(firstToken), "first token is a child of root");

        (list, total) = launch.childTokens(address(firstToken), 0, 10, false);
        require(total == 2 && list.length == 2, "two children");
        require(list[0] == childA && list[1] == childB, "creation order");

        (list, total) = launch.childTokens(address(firstToken), 0, 1, true);
        require(total == 2 && list.length == 1 && list[0] == childB, "reverse clamped");

        (list, total) = launch.childTokens(address(firstToken), 2, 10, false);
        require(total == 2 && list.length == 0, "offset at total");

        // 未登记的父币地址返回空数组与零
        (list, total) = launch.childTokens(EOA, 0, 10, false);
        require(total == 0 && list.length == 0, "unknown parent");
        (list, total) = launch.childTokens(childA, 0, 10, false);
        require(total == 0 && list.length == 0, "leaf has no child");
    }

    function testChildTokensSpanMultipleLevels() public {
        _grantCount(address(firstToken), aliceMemberId, 1);
        address child = _launchOk(alice, "AAA", address(firstToken), aliceMemberId);

        _grantCount(child, aliceMemberId, 1);
        address grandChild = _launchOk(alice, "BBB", child, aliceMemberId);

        require(launch.parentTokenOf(grandChild) == child, "grand child parent ledger");
        require(launch.isLOVE20Token(grandChild), "grand child registered");

        (address[] memory list, uint256 total) = launch.childTokens(child, 0, 10, false);
        require(total == 1 && list[0] == grandChild, "nested child list");

        (list, total) = launch.tokens(0, 10, false);
        require(total == 3 && list[2] == grandChild, "nested token order");
    }

    // ============ Helpers ============

    function _newMember() private returns (MemberNFT) {
        return new MemberNFT(BASE_DIVISOR, BYTES_THRESHOLD, MULTIPLIER, MAX_NAME_LENGTH);
    }

    function _validParams() private view returns (LaunchInitParams memory) {
        return _params(address(member), LAUNCH_AMOUNT, MAX_SUPPLY, "LOVE");
    }

    /// init 参数校验用例专用：每次换一个未初始化的 MemberNFT。
    /// `ILaunchErrors.AlreadyInitialized` 与 `IMemberNFTErrors.AlreadyInitialized` 的 selector
    /// 相同，只有让 MemberNFT 这条路径不可能回滚，断言才能归因到 Launch。
    function _freshParams() private returns (LaunchInitParams memory) {
        return _params(address(_newMember()), LAUNCH_AMOUNT, MAX_SUPPLY, "LOVE");
    }

    /// 统计某个 emitter 发出的指定 topic0 的日志条数，用于事件的反向断言
    function _countLogs(Vm.Log[] memory logs, address emitter, bytes32 topic0) private pure returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics.length != 0 && logs[i].topics[0] == topic0) {
                count += 1;
            }
        }
        return count;
    }

    function _params(
        address memberNFTAddress,
        uint256 launchAmount,
        uint256 maxSupply,
        string memory firstTokenSymbol
    ) private view returns (LaunchInitParams memory) {
        return LaunchInitParams({
            mintAddress: address(mintAccount),
            memberNFTAddress: memberNFTAddress,
            rootParentTokenAddress: ROOT,
            distributor: address(this),
            launchRatio: LAUNCH_RATIO,
            maxLaunchCount: MAX_LAUNCH_COUNT,
            tokenSymbolLength: SYMBOL_LENGTH,
            launchAmount: launchAmount,
            maxSupply: maxSupply,
            name: "LOVE20",
            symbol: firstTokenSymbol
        });
    }

    /// 独立部署一套 Launch + MemberNFT + 首币，并给调用者铸一个成员
    function _bootSystem(
        string memory firstTokenSymbol,
        Caller caller,
        string memory memberName
    ) private returns (Launch bootedLaunch, LOVE20Token bootedToken, MemberNFT bootedMember, uint256 memberId) {
        bootedMember = _newMember();
        bootedLaunch = new Launch();
        bootedLaunch.init(_params(address(bootedMember), LAUNCH_AMOUNT, MAX_SUPPLY, firstTokenSymbol));
        bootedToken = LOVE20Token(bootedMember.LOVE20_TOKEN_ADDRESS());
        _fundAndApprove(caller, bootedToken, bootedMember);
        (memberId, ) = caller.mintMember(bootedMember, memberName);
    }

    function _fundAndApprove(Caller caller, LOVE20Token token, MemberNFT memberNFT) private {
        require(token.transfer(address(caller), CALLER_FUNDING), "fund caller");
        caller.approveToken(address(token), address(memberNFT), type(uint256).max);
    }

    function _launchCalldata(
        string memory tokenSymbol,
        address parentTokenAddress,
        uint256 memberId,
        address distributorAddress,
        DistributorMode distributorMode,
        bytes[] memory data
    ) private pure returns (bytes memory) {
        return abi.encodeWithSelector(
            ILaunch.launchToken.selector,
            tokenSymbol,
            parentTokenAddress,
            memberId,
            distributorAddress,
            distributorMode,
            data
        );
    }

    function _emptyData() private pure returns (bytes[] memory) {
        return new bytes[](0);
    }

    function _launch(
        Caller caller,
        string memory tokenSymbol,
        address parentTokenAddress,
        uint256 memberId
    ) private returns (bool, bytes memory) {
        return _launchAt(launch, caller, tokenSymbol, parentTokenAddress, memberId);
    }

    function _launchAt(
        Launch target,
        Caller caller,
        string memory tokenSymbol,
        address parentTokenAddress,
        uint256 memberId
    ) private returns (bool, bytes memory) {
        return caller.forward(
            address(target),
            _launchCalldata(
                tokenSymbol,
                parentTokenAddress,
                memberId,
                SUB_DISTRIBUTOR,
                DistributorMode.NoCallback,
                _emptyData()
            )
        );
    }

    function _launchOk(
        Caller caller,
        string memory tokenSymbol,
        address parentTokenAddress,
        uint256 memberId
    ) private returns (address) {
        return _launchOkAt(launch, caller, tokenSymbol, parentTokenAddress, memberId);
    }

    function _launchOkAt(
        Launch target,
        Caller caller,
        string memory tokenSymbol,
        address parentTokenAddress,
        uint256 memberId
    ) private returns (address tokenAddress) {
        (bool ok, bytes memory data) = _launchAt(target, caller, tokenSymbol, parentTokenAddress, memberId);
        require(ok, "launch failed");
        return abi.decode(data, (address));
    }

    function _merge(
        Caller caller,
        address tokenAddress,
        uint256 sourceMemberId,
        uint256 targetMemberId,
        uint256 count
    ) private returns (bool, bytes memory) {
        return caller.forward(
            address(launch),
            abi.encodeWithSelector(
                ILaunch.mergeLaunchCount.selector, tokenAddress, sourceMemberId, targetMemberId, count
            )
        );
    }

    function _grantCount(address tokenAddress, uint256 memberId, uint256 count) private {
        _grantCountAt(launch, tokenAddress, memberId, count);
    }

    function _grantCountAt(Launch target, address tokenAddress, uint256 memberId, uint256 count) private {
        mintAccount.addLaunchCount(target, tokenAddress, memberId, count);
    }

    function _initRevertData(LaunchInitParams memory params, string memory note) private returns (bytes memory) {
        return _revertOf(address(new Launch()), abi.encodeWithSelector(ILaunch.init.selector, params), note);
    }

    function _requireInitRevert(LaunchInitParams memory params, bytes4 expected, string memory note) private {
        bytes memory data = _initRevertData(params, note);
        require(_selector(data) == expected, note);
    }

    function _revertOf(address target, bytes memory callData, string memory note) private returns (bytes memory) {
        (bool ok, bytes memory data) = target.call(callData);
        require(!ok, note);
        return data;
    }

    function _selector(bytes memory data) private pure returns (bytes4 selector) {
        if (data.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(data, 32))
        }
    }

    function _argUint(bytes memory data) private pure returns (uint256 value) {
        require(data.length >= 36, "short revert data");
        assembly {
            value := mload(add(data, 36))
        }
    }

    function _argString(bytes memory data) private pure returns (string memory) {
        require(data.length > 4, "short revert data");
        bytes memory tail = new bytes(data.length - 4);
        for (uint256 i; i < tail.length; ++i) {
            tail[i] = data[i + 4];
        }
        return abi.decode(tail, (string));
    }
}
