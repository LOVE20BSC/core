// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {LOVE20Token} from "../src/LOVE20Token.sol";
import {ILOVE20TokenErrors} from "../src/interfaces/ILOVE20Token.sol";

contract TokenCaller {
    function mint(LOVE20Token token, address to, uint256 amount) external {
        token.mint(to, amount);
    }

    function burn(LOVE20Token token, uint256 amount) external {
        token.burn(amount);
    }

    function callMint(LOVE20Token token, address to, uint256 amount)
        external
        returns (bool, bytes memory)
    {
        return address(token).call(abi.encodeWithSelector(token.mint.selector, to, amount));
    }
}

contract LOVE20TokenTest {
    /// 父币地址只作为构造参数保存，代币本体不再与父币发生任何转账
    address private constant PARENT = address(0xBEEF);
    LOVE20Token private token;
    TokenCaller private minter;
    TokenCaller private holder;

    function setUp() public {
        minter = new TokenCaller();
        holder = new TokenCaller();
        token = new LOVE20Token(
            "LOVE20",
            "LOVE",
            100 ether,
            150 ether,
            address(this),
            address(minter),
            PARENT
        );
    }

    function testConstructorAndInitialDistribution() public view {
        require(keccak256(bytes(token.name())) == keccak256("LOVE20"), "name");
        require(keccak256(bytes(token.symbol())) == keccak256("LOVE"), "symbol");
        require(token.totalSupply() == 100 ether, "supply");
        require(token.balanceOf(address(this)) == 100 ether, "distributor");
        require(token.maxSupply() == 150 ether, "max supply");
        require(token.minter() == address(minter), "minter");
        require(token.parentTokenAddress() == PARENT, "parent");
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

    function testConstructorRejectsInvalidSupply() public {
        // initialSupply 大于 maxSupply
        require(
            _selector(_deployRevert(_tokenCode(101 ether, 100 ether, address(this), address(this), PARENT)))
                == ILOVE20TokenErrors.InvalidSupply.selector,
            "above max supply"
        );

        // initialSupply 为零：零供应代币不可创建
        require(
            _selector(_deployRevert(_tokenCode(0, 100 ether, address(this), address(this), PARENT)))
                == ILOVE20TokenErrors.InvalidSupply.selector,
            "zero initial supply"
        );

        // 两者相等合法
        require(_deploys(_tokenCode(100 ether, 100 ether, address(this), address(this), PARENT)), "equal supply");
    }

    function testConstructorRejectsZeroAddresses() public {
        require(
            _selector(_deployRevert(_tokenCode(1 ether, 1 ether, address(0), address(this), PARENT)))
                == ILOVE20TokenErrors.InvalidAddress.selector,
            "zero distributor"
        );
        require(
            _selector(_deployRevert(_tokenCode(1 ether, 1 ether, address(this), address(0), PARENT)))
                == ILOVE20TokenErrors.InvalidAddress.selector,
            "zero minter"
        );
        require(
            _selector(_deployRevert(_tokenCode(1 ether, 1 ether, address(this), address(this), address(0))))
                == ILOVE20TokenErrors.InvalidAddress.selector,
            "zero parent"
        );
    }

    function _tokenCode(
        uint256 initialSupply,
        uint256 maxSupply,
        address distributor,
        address minterAddress,
        address parentAddress
    ) private pure returns (bytes memory) {
        return abi.encodePacked(
            type(LOVE20Token).creationCode,
            abi.encode("LOVE20", "LOVE", initialSupply, maxSupply, distributor, minterAddress, parentAddress)
        );
    }

    function _deploys(bytes memory bytecode) private returns (bool) {
        address deployed;
        assembly {
            deployed := create(0, add(bytecode, 32), mload(bytecode))
        }
        return deployed != address(0);
    }

    /// 构造回滚必须用 assembly `create`：`vm.expectRevert` 与 `new` 混用时，真回滚会终止整个
    /// 用例并判 PASS，使其后的断言全部变成死代码。create 还会保留 revert data 供 selector 断言。
    function _deployRevert(bytes memory bytecode) private returns (bytes memory data) {
        address deployed;
        uint256 size;
        assembly {
            deployed := create(0, add(bytecode, 32), mload(bytecode))
            size := returndatasize()
        }
        require(deployed == address(0), "deploy should revert");
        data = new bytes(size);
        assembly {
            returndatacopy(add(data, 32), 0, size)
        }
    }

    function _selector(bytes memory data) private pure returns (bytes4 selector) {
        if (data.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(data, 32))
        }
    }
}
