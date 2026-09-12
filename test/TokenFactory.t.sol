// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {LOVE20Token} from "../src/LOVE20Token.sol";
import {TokenFactory} from "../src/TokenFactory.sol";
import {ITokenFactory, ITokenFactoryErrors} from "../src/interfaces/ITokenFactory.sol";

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
}

contract FactoryCaller {
    function init(
        TokenFactory factory,
        address launch,
        address mint,
        uint256 launchAmount,
        uint256 maxSupply
    ) external {
        factory.init(launch, mint, launchAmount, maxSupply);
    }

    function createToken(
        TokenFactory factory,
        address parent,
        string calldata name,
        string calldata symbol,
        address distributor
    ) external returns (address) {
        return factory.createToken(parent, name, symbol, distributor);
    }

    function callCreateToken(
        TokenFactory factory,
        address parent,
        string calldata name,
        string calldata symbol,
        address distributor
    ) external returns (bool, bytes memory) {
        return address(factory).call(
            abi.encodeWithSelector(
                ITokenFactory.createToken.selector,
                parent,
                name,
                symbol,
                distributor
            )
        );
    }
}

contract TokenFactoryTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    TokenFactory private factory;
    FactoryCaller private launch;
    FactoryCaller private other;
    address private constant MINT = address(0x1234);
    address private constant PARENT = address(0x5678);
    address private constant DISTRIBUTOR = address(0x9ABC);

    function setUp() public {
        factory = new TokenFactory();
        launch = new FactoryCaller();
        other = new FactoryCaller();
    }

    function initFactory() private {
        factory.init(address(launch), MINT, 100 ether, 200 ether);
    }

    function testPermissionlessInitAndInitializedGetter() public {
        other.init(factory, address(launch), MINT, 100 ether, 200 ether);

        require(factory.initialized(), "initialized");
        require(factory.launchAddress() == address(launch), "launch");
        require(factory.mintAddress() == MINT, "mint");
        require(factory.LAUNCH_AMOUNT() == 100 ether, "launch amount");
        require(factory.MAX_SUPPLY() == 200 ether, "max supply");

        (bool ok, bytes memory data) = address(factory).call(
            abi.encodeWithSelector(
                ITokenFactory.init.selector,
                address(launch),
                MINT,
                100 ether,
                200 ether
            )
        );
        require(!ok && _selector(data) == ITokenFactoryErrors.AlreadyInitialized.selector, "reinit");
    }

    function testInitRejectsInvalidAmountAndZeroAddresses() public {
        (bool ok, bytes memory data) = address(factory).call(
            abi.encodeWithSelector(ITokenFactory.init.selector, address(launch), MINT, 201, 200)
        );
        require(!ok && _selector(data) == ITokenFactoryErrors.InvalidAmount.selector, "amount");

        (ok, data) = address(factory).call(
            abi.encodeWithSelector(ITokenFactory.init.selector, address(0), MINT, 100, 200)
        );
        require(!ok && _selector(data) == ITokenFactoryErrors.ZeroAddress.selector, "launch zero");

        (ok, data) = address(factory).call(
            abi.encodeWithSelector(ITokenFactory.init.selector, address(launch), address(0), 100, 200)
        );
        require(!ok && _selector(data) == ITokenFactoryErrors.ZeroAddress.selector, "mint zero");
    }

    function testOnlyLaunchAndUninitializedChecks() public {
        (bool ok, bytes memory data) = other.callCreateToken(factory, PARENT, "LOVE", "L", DISTRIBUTOR);
        require(!ok && _selector(data) == ITokenFactoryErrors.UnauthorizedCaller.selector, "uninitialized");

        initFactory();
        (ok, data) = other.callCreateToken(factory, PARENT, "LOVE", "L", DISTRIBUTOR);
        require(!ok && _selector(data) == ITokenFactoryErrors.UnauthorizedCaller.selector, "only launch");
    }

    function testCreateTokenValidatesArguments() public {
        initFactory();

        (bool ok, bytes memory data) = launch.callCreateToken(factory, address(0), "LOVE", "L", DISTRIBUTOR);
        require(!ok && _selector(data) == ITokenFactoryErrors.ZeroAddress.selector, "parent zero");
        (ok, data) = launch.callCreateToken(factory, PARENT, "LOVE", "L", address(0));
        require(!ok && _selector(data) == ITokenFactoryErrors.ZeroAddress.selector, "distributor zero");
        (ok, data) = launch.callCreateToken(factory, PARENT, "", "L", DISTRIBUTOR);
        require(!ok && _selector(data) == ITokenFactoryErrors.EmptyString.selector, "name empty");
        (ok, data) = launch.callCreateToken(factory, PARENT, "LOVE", "", DISTRIBUTOR);
        require(!ok && _selector(data) == ITokenFactoryErrors.EmptyString.selector, "symbol empty");
    }

    function testCreateTokenCreatesAndDistributesToken() public {
        initFactory();
        address tokenAddress = launch.createToken(factory, PARENT, "LOVE", "L", DISTRIBUTOR);
        LOVE20Token token = LOVE20Token(tokenAddress);

        require(keccak256(bytes(token.name())) == keccak256(bytes("LOVE")), "name");
        require(keccak256(bytes(token.symbol())) == keccak256(bytes("L")), "symbol");
        require(token.totalSupply() == 100 ether, "supply");
        require(token.balanceOf(DISTRIBUTOR) == 100 ether, "distributor");
        require(token.maxSupply() == 200 ether, "max supply");
        require(token.minter() == MINT, "minter");
        require(token.parentTokenAddress() == PARENT, "parent");
    }

    function testCreateTokenEmitsTokenCreated() public {
        initFactory();
        vm.recordLogs();
        address tokenAddress = launch.createToken(factory, PARENT, "LOVE", "L", DISTRIBUTOR);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSelector = keccak256("TokenCreated(address,address,string,string,address)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(factory) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != eventSelector) continue;
            require(logs[i].topics[1] == bytes32(uint256(uint160(tokenAddress))), "token event");
            require(logs[i].topics[2] == bytes32(uint256(uint160(PARENT))), "parent event");
            (string memory name, string memory symbol, address distributor) = abi.decode(
                logs[i].data,
                (string, string, address)
            );
            require(keccak256(bytes(name)) == keccak256(bytes("LOVE")), "event name");
            require(keccak256(bytes(symbol)) == keccak256(bytes("L")), "event symbol");
            require(distributor == DISTRIBUTOR, "event distributor");
            found = true;
        }
        require(found, "missing TokenCreated");
    }

    function _selector(bytes memory data) private pure returns (bytes4 selector) {
        if (data.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(data, 32))
        }
    }
}
