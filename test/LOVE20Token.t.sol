// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {LOVE20Token} from "../src/LOVE20Token.sol";
import {ILOVE20TokenErrors} from "../src/interfaces/ILOVE20Token.sol";

contract MockParentToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract TokenCaller {
    function mint(LOVE20Token token, address to, uint256 amount) external {
        token.mint(to, amount);
    }

    function burn(LOVE20Token token, uint256 amount) external {
        token.burn(amount);
    }

    function burnForParentToken(LOVE20Token token, uint256 amount) external returns (uint256) {
        return token.burnForParentToken(amount);
    }

    function callMint(LOVE20Token token, address to, uint256 amount)
        external
        returns (bool, bytes memory)
    {
        return address(token).call(abi.encodeWithSelector(token.mint.selector, to, amount));
    }
}

interface Vm {
    function expectRevert(bytes4 revertData) external;
}

contract LOVE20TokenTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    MockParentToken private parent;
    LOVE20Token private token;
    TokenCaller private minter;
    TokenCaller private holder;

    function setUp() public {
        parent = new MockParentToken();
        minter = new TokenCaller();
        holder = new TokenCaller();
        token = new LOVE20Token(
            "LOVE20",
            "LOVE",
            100 ether,
            150 ether,
            address(this),
            address(minter),
            address(parent)
        );
    }

    function testConstructorAndInitialDistribution() public view {
        require(keccak256(bytes(token.name())) == keccak256("LOVE20"), "name");
        require(keccak256(bytes(token.symbol())) == keccak256("LOVE"), "symbol");
        require(token.totalSupply() == 100 ether, "supply");
        require(token.balanceOf(address(this)) == 100 ether, "distributor");
        require(token.maxSupply() == 150 ether, "max supply");
        require(token.minter() == address(minter), "minter");
        require(token.parentTokenAddress() == address(parent), "parent");
    }

    function testMinterCanMintUpToMaxSupply() public {
        minter.mint(token, address(this), 50 ether);
        require(token.totalSupply() == 150 ether, "mint");

        (bool ok, bytes memory data) = minter.callMint(token, address(this), 1);
        require(!ok && _selector(data) == ILOVE20TokenErrors.ExceedsMaxSupply.selector, "exceeded max supply");
    }

    function testNonMinterCannotMint() public {
        (bool ok, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.mint.selector, address(this), 1)
        );
        require(!ok && _selector(data) == ILOVE20TokenErrors.NotMinter.selector, "unauthorized mint");
    }

    function testBurnReducesCallerBalanceAndSupply() public {
        require(token.transfer(address(holder), 20 ether), "transfer");
        holder.burn(token, 7 ether);
        require(token.balanceOf(address(holder)) == 13 ether, "balance");
        require(token.totalSupply() == 93 ether, "supply");
    }

    function testBurnForParentTokenUsesPoolRatio() public {
        require(token.transfer(address(holder), 20 ether), "transfer");
        parent.mint(address(token), 200 ether);

        uint256 received = holder.burnForParentToken(token, 10 ether);
        require(received == 20 ether, "parent amount");
        require(token.balanceOf(address(holder)) == 10 ether, "token balance");
        require(parent.balanceOf(address(holder)) == 20 ether, "parent balance");
        require(token.parentPool() == 180 ether, "pool");
    }

    function testConstructorRejectsInvalidSupply() public {
        parent = new MockParentToken();
        vm.expectRevert(ILOVE20TokenErrors.InvalidSupply.selector);
        new LOVE20Token(
            "LOVE20",
            "LOVE",
            101 ether,
            100 ether,
            address(this),
            address(this),
            address(parent)
        );
    }

    function testConstructorRejectsZeroAddresses() public {
        parent = new MockParentToken();
        vm.expectRevert(ILOVE20TokenErrors.InvalidAddress.selector);
        new LOVE20Token(
            "LOVE20",
            "LOVE",
            1 ether,
            1 ether,
            address(0),
            address(this),
            address(parent)
        );

        vm.expectRevert(ILOVE20TokenErrors.InvalidAddress.selector);
        new LOVE20Token(
            "LOVE20",
            "LOVE",
            1 ether,
            1 ether,
            address(this),
            address(0),
            address(parent)
        );

        vm.expectRevert(ILOVE20TokenErrors.InvalidAddress.selector);
        new LOVE20Token(
            "LOVE20",
            "LOVE",
            1 ether,
            1 ether,
            address(this),
            address(this),
            address(0)
        );
    }

    function _selector(bytes memory data) private pure returns (bytes4 selector) {
        if (data.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(data, 32))
        }
    }
}
