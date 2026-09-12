// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {MemberNFT} from "../src/MemberNFT.sol";
import {LOVE20Token} from "../src/LOVE20Token.sol";
import {IMemberNFT, IMemberNFTErrors} from "../src/interfaces/IMemberNFT.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory logs);
}

contract MemberCaller {
    function approveToken(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }

    function mint(
        MemberNFT nft,
        string calldata name
    ) external returns (uint256 id, uint256 cost) {
        return nft.mint(name);
    }

    function callMint(
        MemberNFT nft,
        string calldata name
    ) external returns (bool, bytes memory) {
        return address(nft).call(abi.encodeWithSelector(nft.mint.selector, name));
    }

    function approveNft(MemberNFT nft, address spender, uint256 id) external {
        nft.approve(spender, id);
    }

    function transferNft(MemberNFT nft, address to, uint256 id) external {
        nft.transferFrom(address(this), to, id);
    }

    function transferNftFrom(
        MemberNFT nft,
        address from,
        address to,
        uint256 id
    ) external {
        nft.transferFrom(from, to, id);
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
    }
}

contract MemberNFTTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant BASE_DIVISOR = 1e8;
    uint256 private constant BYTES_THRESHOLD = 7;
    uint256 private constant MULTIPLIER = 10;
    uint256 private constant MAX_NAME_LENGTH = 32;
    uint256 private constant INITIAL_SUPPLY = 100 ether;
    uint256 private constant UNMINTED = 1 ether;
    address private constant PARENT = address(0x5678);

    LOVE20Token private token;
    MemberNFT private nft;
    MemberCaller private alice;
    MemberCaller private bob;
    MemberCaller private carol;
    MemberCaller private dave;

    function setUp() public {
        token = _newToken("LOVE");
        nft = new MemberNFT(BASE_DIVISOR, BYTES_THRESHOLD, MULTIPLIER, MAX_NAME_LENGTH);
        alice = new MemberCaller();
        bob = new MemberCaller();
        carol = new MemberCaller();
        dave = new MemberCaller();

        nft.init(address(token));
        token.approve(address(nft), type(uint256).max);
        _fund(alice);
        _fund(bob);
        _fund(carol);
    }

    function testConstructorAndInitialState() public view {
        require(keccak256(bytes(nft.name())) == keccak256("LOVE20 Member NFT"), "nft name");
        require(keccak256(bytes(nft.symbol())) == keccak256("Member"), "nft symbol");
        require(nft.BASE_DIVISOR() == BASE_DIVISOR, "base divisor");
        require(nft.BYTES_THRESHOLD() == BYTES_THRESHOLD, "bytes threshold");
        require(nft.MULTIPLIER() == MULTIPLIER, "multiplier");
        require(nft.MAX_NAME_LENGTH() == MAX_NAME_LENGTH, "max name length");
        require(nft.initialized(), "initialized");
        require(nft.LOVE20_TOKEN_ADDRESS() == address(token), "first token");
        require(nft.totalSupply() == 0, "total supply");
        (address[] memory holderList, uint256 totalCount) = nft.holders(0, 100, false);
        require(totalCount == 0, "holders count");
        require(holderList.length == 0, "empty holder list");
        require(nft.totalBurnedForMint() == 0, "burned");
    }

    function testConstructorRejectsZeroParameters() public {
        require(_deploys(BASE_DIVISOR, BYTES_THRESHOLD, MULTIPLIER, MAX_NAME_LENGTH), "valid parameters");
        require(!_deploys(0, BYTES_THRESHOLD, MULTIPLIER, MAX_NAME_LENGTH), "zero divisor");
        require(!_deploys(BASE_DIVISOR, 0, MULTIPLIER, MAX_NAME_LENGTH), "zero threshold");
        require(!_deploys(BASE_DIVISOR, BYTES_THRESHOLD, 0, MAX_NAME_LENGTH), "zero multiplier");
        require(!_deploys(BASE_DIVISOR, BYTES_THRESHOLD, MULTIPLIER, 0), "zero max name length");
    }

    function testInitStoresFirstTokenAndRejectsRepeat() public {
        MemberNFT fresh = new MemberNFT(BASE_DIVISOR, BYTES_THRESHOLD, MULTIPLIER, MAX_NAME_LENGTH);
        require(!fresh.initialized(), "not initialized");
        require(fresh.LOVE20_TOKEN_ADDRESS() == address(0), "no first token");

        (bool ok, ) = address(fresh).call(abi.encodeWithSelector(IMemberNFT.init.selector, address(0)));
        require(!ok, "zero first token");

        fresh.init(address(token));
        require(fresh.initialized(), "initialized");
        require(fresh.LOVE20_TOKEN_ADDRESS() == address(token), "first token");

        bytes memory data = _revertData(
            address(fresh),
            abi.encodeWithSelector(IMemberNFT.init.selector, address(token)),
            "reinit expected"
        );
        require(_selector(data) == IMemberNFTErrors.AlreadyInitialized.selector, "reinit");
    }

    function testMintAndQuoteRevertBeforeInit() public {
        MemberNFT fresh = new MemberNFT(BASE_DIVISOR, BYTES_THRESHOLD, MULTIPLIER, MAX_NAME_LENGTH);

        (bool ok, ) = address(fresh).call(_mintCall("abc"));
        require(!ok, "mint before init");

        (ok, ) = address(fresh).call(_costCall("abc"));
        require(!ok, "quote before init");
    }

    function testMintBurnsCostAndStoresIdentity() public {
        uint256 expected = nft.calculateMintCost("abc");
        uint256 supplyBefore = token.totalSupply();
        uint256 balanceBefore = token.balanceOf(address(alice));

        (uint256 id, uint256 cost) = alice.mint(nft, "abc");

        require(id == 1, "first id");
        require(cost == expected, "charged cost");
        require(cost > 0, "fixture cost");
        require(token.balanceOf(address(alice)) == balanceBefore - cost, "payer balance");
        require(token.totalSupply() == supplyBefore - cost, "burned supply");
        require(token.balanceOf(address(nft)) == 0, "no residual balance");
        require(nft.totalBurnedForMint() == cost, "accumulator");
        require(nft.ownerOf(id) == address(alice), "owner");
        require(nft.balanceOf(address(alice)) == 1, "balance");
        require(keccak256(bytes(nft.nameOf(id))) == keccak256("abc"), "stored name");
        (address[] memory holderList, uint256 totalCount) = nft.holders(0, 100, false);
        require(totalCount == 1, "holders count");
        require(holderList.length == 1, "holder list length");
        require(holderList[0] == address(alice), "holder 0");
    }

    function testCalculateMintCostFollowsLengthFormula() public view {
        uint256 base = _baseCost();
        require(base > 0, "fixture base cost");
        require(nft.calculateMintCost("1234567") == base, "at threshold");
        require(nft.calculateMintCost("12345678") == base, "above threshold");
        require(nft.calculateMintCost("123456") == base * 10, "one below threshold");
        require(nft.calculateMintCost("12345") == base * 100, "two below threshold");
        require(nft.calculateMintCost("1") == base * (MULTIPLIER ** 6), "shortest name");
        require(nft.calculateMintCost("123456") == nft.calculateMintCost("654321"), "length only");
    }

    function testZeroCostMintSkipsTokenTransfer() public {
        LOVE20Token fullyMinted = new LOVE20Token(
            "LOVE20",
            "LOVE",
            INITIAL_SUPPLY,
            INITIAL_SUPPLY,
            address(this),
            address(this),
            PARENT
        );
        MemberNFT freeNft = new MemberNFT(BASE_DIVISOR, BYTES_THRESHOLD, MULTIPLIER, MAX_NAME_LENGTH);
        freeNft.init(address(fullyMinted));
        require(freeNft.calculateMintCost("a") == 0, "zero quote");

        (uint256 id, uint256 cost) = dave.mint(freeNft, "dave");

        require(id == 1, "first id");
        require(cost == 0, "zero cost");
        require(freeNft.ownerOf(id) == address(dave), "owner");
        require(freeNft.totalBurnedForMint() == 0, "no burn recorded");
        require(fullyMinted.balanceOf(address(dave)) == 0, "untouched balance");
    }

    function testMintRevertsWithoutAllowance() public {
        (bool ok, ) = dave.callMint(nft, "dave");
        require(!ok, "mint without allowance");
        require(nft.totalSupply() == 0, "nothing minted");
    }

    function testMintRejectsEmptyAndTooLongNames() public {
        bytes memory atLimit = bytes("abcdefghijklmnopqrstuvwxyz012345");
        bytes memory overLimit = bytes.concat(atLimit, "z");
        require(atLimit.length == MAX_NAME_LENGTH, "fixture at limit");

        (uint256 id, ) = alice.mint(nft, string(atLimit));
        require(keccak256(bytes(nft.nameOf(id))) == keccak256(atLimit), "name at limit");

        bytes memory data = _revertData(address(nft), _mintCall(string(overLimit)), "too long expected");
        require(_selector(data) == IMemberNFTErrors.NameTooLong.selector, "too long");
        require(_revertArg(data) == overLimit.length, "too long length");

        data = _revertData(address(nft), _mintCall(""), "empty expected");
        require(_selector(data) == IMemberNFTErrors.NameEmpty.selector, "empty");
    }

    function testMintRejectsForbiddenCharactersAndInvalidUtf8() public {
        bytes[] memory invalid = new bytes[](31);
        invalid[0] = hex"20"; // space
        invalid[1] = hex"01"; // C0 control
        invalid[2] = hex"7f"; // DEL
        invalid[3] = hex"c2a0"; // U+00A0 no-break space
        invalid[4] = hex"c2ad"; // U+00AD soft hyphen
        invalid[5] = hex"c285"; // U+0085 C1 control
        invalid[6] = hex"cd8f"; // U+034F combining grapheme joiner
        invalid[7] = hex"d89c"; // U+061C arabic letter mark
        invalid[8] = hex"e19a80"; // U+1680 ogham space mark
        invalid[9] = hex"e28080"; // U+2000 en quad
        invalid[10] = hex"e2808b"; // U+200B zero width space
        invalid[11] = hex"e2808f"; // U+200F right-to-left mark
        invalid[12] = hex"e280a8"; // U+2028 line separator
        invalid[13] = hex"e280ae"; // U+202E right-to-left override
        invalid[14] = hex"e2819f"; // U+205F medium math space
        invalid[15] = hex"e281a1"; // U+2061 invisible times
        invalid[16] = hex"e281aa"; // U+206A deprecated format
        invalid[17] = hex"e281af"; // U+206F deprecated format
        invalid[18] = hex"e38080"; // U+3000 ideographic space
        invalid[19] = hex"efbbbf"; // U+FEFF byte order mark
        invalid[20] = hex"80"; // invalid start byte
        invalid[21] = hex"c1bf"; // invalid start byte 0xC1
        invalid[22] = hex"f5808080"; // invalid start byte 0xF5
        invalid[23] = hex"c2"; // truncated 2-byte sequence
        invalid[24] = hex"c241"; // bad continuation byte
        invalid[25] = hex"e280"; // truncated 3-byte sequence
        invalid[26] = hex"e08080"; // overlong 3-byte encoding
        invalid[27] = hex"eda080"; // UTF-16 surrogate U+D800
        invalid[28] = hex"f0808080"; // overlong 4-byte encoding
        invalid[29] = hex"f4908080"; // code point above U+10FFFF
        invalid[30] = bytes.concat("ab", hex"e2808b", "cd"); // forbidden char inside a name

        for (uint256 i; i < invalid.length; ++i) {
            bytes memory data = _revertData(address(nft), _mintCall(string(invalid[i])), "invalid name expected");
            require(_selector(data) == IMemberNFTErrors.NameInvalidCharacters.selector, "invalid characters");
        }
        require(nft.totalSupply() == 0, "nothing minted");
    }

    function testMintAcceptsValidNamesWithinByteLimit() public {
        bytes[] memory valid = new bytes[](6);
        valid[0] = bytes("a");
        valid[1] = bytes("abcdefghijklmnopqrstuvwxyz012345"); // 32 bytes
        valid[2] = hex"e4b8ade69687"; // 中文
        valid[3] = hex"f09f9880"; // single code point emoji
        valid[4] = bytes("A_b-9");
        valid[5] = bytes.concat("ab", hex"e4b8ad", "CD");

        for (uint256 i; i < valid.length; ++i) {
            (uint256 id, ) = alice.mint(nft, string(valid[i]));
            require(id == i + 1, "sequential id");
            require(keccak256(bytes(nft.nameOf(id))) == keccak256(valid[i]), "stored name");
            require(nft.idOf(string(valid[i])) == id, "idOf");
            require(nft.isNameUsed(string(valid[i])), "isNameUsed");
        }
        require(nft.totalSupply() == valid.length, "total supply");
        (address[] memory holderList, uint256 totalCount) = nft.holders(0, 100, false);
        require(totalCount == 1, "single holder");
        require(holderList.length == 1, "single holder list");
    }

    function testNameQueriesAreCaseInsensitiveAndPreserveOriginal() public {
        (uint256 id, ) = alice.mint(nft, "MiXeD");

        require(keccak256(bytes(nft.nameOf(id))) == keccak256("MiXeD"), "original case stored");
        require(nft.idOf("MiXeD") == id, "exact case");
        require(nft.idOf("mixed") == id, "lowercase");
        require(nft.idOf("MIXED") == id, "uppercase");
        require(nft.idOf("other") == 0, "unknown name");
        require(nft.isNameUsed("mixed"), "used");
        require(!nft.isNameUsed("other"), "unused");
        require(bytes(nft.nameOf(id + 1)).length == 0, "unknown id has no name");
        require(keccak256(bytes(nft.normalizedNameOf("MiXeD"))) == keccak256("mixed"), "normalize ascii");
        require(
            keccak256(bytes(nft.normalizedNameOf(unicode"中A文"))) == keccak256(bytes(unicode"中a文")),
            "normalize unicode"
        );

        bytes memory data = _revertData(address(nft), _mintCall("mixed"), "duplicate expected");
        require(_selector(data) == IMemberNFTErrors.NameAlreadyExists.selector, "duplicate");
        require(_revertArg(data) == id, "duplicate id");
    }

    function testTestPrefixAppliedWhenFirstTokenSymbolStartsWithTest() public {
        LOVE20Token testToken = _newToken("TestLOVE");
        MemberNFT testNft = new MemberNFT(BASE_DIVISOR, BYTES_THRESHOLD, MULTIPLIER, MAX_NAME_LENGTH);
        testNft.init(address(testToken));
        require(testToken.transfer(address(alice), 10 ether), "fund alice");
        alice.approveToken(address(testToken), address(testNft), type(uint256).max);

        uint256 shortQuote = testNft.calculateMintCost("abc");
        uint256 prefixedQuote = testNft.calculateMintCost("Testabc");
        require(shortQuote == _quoteFor(testToken, "abc"), "quote without prefix");
        require(prefixedQuote == _quoteFor(testToken, "Testabc"), "quote with prefix");
        require(shortQuote > prefixedQuote, "shorter name costs more");

        (uint256 id, uint256 cost) = alice.mint(testNft, "abc");
        require(keccak256(bytes(testNft.nameOf(id))) == keccak256("Testabc"), "prefixed name");
        require(cost == prefixedQuote, "cost uses prefixed length");
        require(testNft.idOf("testabc") == id, "normalized lookup");
        require(testNft.isNameUsed("TESTABC"), "case-insensitive lookup");

        (uint256 alreadyPrefixed, ) = alice.mint(testNft, "Testxyz");
        require(keccak256(bytes(testNft.nameOf(alreadyPrefixed))) == keccak256("Testxyz"), "no double prefix");

        (uint256 shortName, ) = alice.mint(testNft, "Tes");
        require(keccak256(bytes(testNft.nameOf(shortName))) == keccak256("TestTes"), "short name prefixed");

        (uint256 plain, ) = alice.mint(nft, "abc");
        require(keccak256(bytes(nft.nameOf(plain))) == keccak256("abc"), "no prefix for other symbols");
    }

    function testEnumerableViewsTrackTokensAndOwners() public {
        (uint256 a1, ) = alice.mint(nft, "aaa");
        (uint256 a2, ) = alice.mint(nft, "bbb");
        (uint256 b1, ) = bob.mint(nft, "ccc");

        require(nft.totalSupply() == 3, "total supply");
        require(nft.tokenByIndex(0) == a1, "token 0");
        require(nft.tokenByIndex(1) == a2, "token 1");
        require(nft.tokenByIndex(2) == b1, "token 2");
        require(nft.tokenOfOwnerByIndex(address(alice), 0) == a1, "alice token 0");
        require(nft.tokenOfOwnerByIndex(address(alice), 1) == a2, "alice token 1");
        require(nft.tokenOfOwnerByIndex(address(bob), 0) == b1, "bob token 0");
        require(nft.balanceOf(address(alice)) == 2, "alice balance");
        require(nft.ownerOf(a2) == address(alice), "owner");
    }

    function testHolderEnumerationAcrossMintTransferAndSelfTransfer() public {
        (uint256 a1, ) = alice.mint(nft, "aaa");
        (uint256 a2, ) = alice.mint(nft, "bbb");
        bob.mint(nft, "ccc");
        uint256 c1 = _mintAs(carol, "ddd");

        (address[] memory holderList, uint256 totalCount) = nft.holders(0, 100, false);
        require(totalCount == 3, "three holders");
        require(holderList.length == 3, "three holder list");
        require(holderList[0] == address(alice), "holder 0");
        require(holderList[1] == address(bob), "holder 1");
        require(holderList[2] == address(carol), "holder 2");

        // 自转账不加入也不移除，索引保持不变
        alice.transferNft(nft, address(alice), a1);
        (holderList, totalCount) = nft.holders(0, 100, false);
        require(totalCount == 3, "self transfer count");
        require(holderList[0] == address(alice), "self transfer index");
        require(nft.ownerOf(a1) == address(alice), "self transfer owner");
        require(nft.balanceOf(address(alice)) == 2, "self transfer balance");

        // 转出其中一枚仍在集合内，转出最后一枚才移除
        alice.transferNft(nft, address(bob), a1);
        (holderList, totalCount) = nft.holders(0, 100, false);
        require(totalCount == 3, "partial transfer count");
        require(holderList[0] == address(alice), "partial transfer keeps alice");
        require(nft.balanceOf(address(bob)) == 2, "bob balance");

        // swap-and-pop：末位 carol 顶替 alice 的索引
        alice.transferNft(nft, address(bob), a2);
        (holderList, totalCount) = nft.holders(0, 100, false);
        require(totalCount == 2, "removal count");
        require(holderList[0] == address(carol), "carol moved to index 0");
        require(holderList[1] == address(bob), "bob keeps index 1");

        // 授权操作员发起的转账同样维护集合
        carol.approveNft(nft, address(alice), c1);
        alice.transferNftFrom(nft, address(carol), address(alice), c1);
        (holderList, totalCount) = nft.holders(0, 100, false);
        require(totalCount == 2, "operator transfer count");
        require(holderList[1] == address(alice), "alice appended");
        require(nft.balanceOf(address(carol)) == 0, "carol emptied");
        require(nft.ownerOf(c1) == address(alice), "operator transfer owner");

        // Test out of bounds access
        (holderList, totalCount) = nft.holders(10, 100, false);
        require(totalCount == 2, "out of bounds total count");
        require(holderList.length == 0, "out of bounds empty list");
    }

    function testMintAndHolderEvents() public {
        bob.mint(nft, "ccc");

        vm.recordLogs();
        (uint256 id, uint256 cost) = alice.mint(nft, "alice");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 mintTopic = keccak256("Mint(uint256,address,string,string,uint256)");
        bytes32 addTopic = keccak256("AddHolder(address,uint256)");
        bool minted;
        bool added;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(nft) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == mintTopic) {
                require(logs[i].topics[1] == bytes32(id), "mint id");
                require(logs[i].topics[2] == bytes32(uint256(uint160(address(alice)))), "mint owner");
                (string memory name, string memory normalized, uint256 eventCost) = abi.decode(
                    logs[i].data,
                    (string, string, uint256)
                );
                require(keccak256(bytes(name)) == keccak256("alice"), "mint name");
                require(keccak256(bytes(normalized)) == keccak256("alice"), "mint normalized name");
                require(eventCost == cost, "mint cost");
                minted = true;
            } else if (logs[i].topics[0] == addTopic) {
                require(logs[i].topics[1] == bytes32(uint256(uint160(address(alice)))), "add holder");
                require(abi.decode(logs[i].data, (uint256)) == 2, "add holder total");
                added = true;
            }
        }
        require(minted && added, "missing mint or add holder event");

        vm.recordLogs();
        alice.transferNft(nft, address(bob), id);
        logs = vm.getRecordedLogs();
        bytes32 removeTopic = keccak256("RemoveHolder(address,uint256)");
        bool removed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(nft) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] != removeTopic) continue;
            require(logs[i].topics[1] == bytes32(uint256(uint160(address(alice)))), "remove holder");
            require(abi.decode(logs[i].data, (uint256)) == 1, "remove holder total");
            removed = true;
        }
        require(removed, "missing remove holder event");
    }

    // ============ Helpers ============

    // 用裸 CREATE 的返回值判定构造是否成功：成功返回非零地址，回滚返回 address(0)。
    // 不使用 vm.expectRevert：`new` 构造一旦回滚，测试函数会在此终止并被判 PASS，
    // 其后语句全部成为死代码；且与裸 create 混用还会污染返回值观测。
    function _deploys(
        uint256 divisor,
        uint256 threshold,
        uint256 multiplier,
        uint256 maxLength
    ) private returns (bool) {
        bytes memory bytecode = abi.encodePacked(
            type(MemberNFT).creationCode,
            abi.encode(divisor, threshold, multiplier, maxLength)
        );
        address deployed;
        assembly {
            deployed := create(0, add(bytecode, 32), mload(bytecode))
        }
        return deployed != address(0);
    }

    function _newToken(string memory symbol) private returns (LOVE20Token) {
        return
            new LOVE20Token(
                "LOVE20",
                symbol,
                INITIAL_SUPPLY,
                INITIAL_SUPPLY + UNMINTED,
                address(this),
                address(this),
                PARENT
            );
    }

    function _fund(MemberCaller caller) private {
        require(token.transfer(address(caller), 10 ether), "fund caller");
        caller.approveToken(address(token), address(nft), type(uint256).max);
    }

    function _mintAs(MemberCaller caller, string memory name) private returns (uint256 id) {
        (id, ) = caller.mint(nft, name);
        return id;
    }

    function _baseCost() private view returns (uint256) {
        return (token.maxSupply() - token.totalSupply()) / BASE_DIVISOR;
    }

    function _quoteFor(LOVE20Token token_, string memory name) private view returns (uint256) {
        uint256 base = (token_.maxSupply() - token_.totalSupply()) / BASE_DIVISOR;
        uint256 length = bytes(name).length;
        if (length >= BYTES_THRESHOLD) return base;
        return base * (MULTIPLIER ** (BYTES_THRESHOLD - length));
    }

    function _mintCall(string memory name) private pure returns (bytes memory) {
        return abi.encodeWithSelector(IMemberNFT.mint.selector, name);
    }

    function _costCall(string memory name) private pure returns (bytes memory) {
        return abi.encodeWithSelector(IMemberNFT.calculateMintCost.selector, name);
    }

    function _revertData(
        address target,
        bytes memory callData,
        string memory note
    ) private returns (bytes memory) {
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

    function _revertArg(bytes memory data) private pure returns (uint256 value) {
        require(data.length >= 36, "short revert data");
        assembly {
            value := mload(add(data, 36))
        }
    }
}
