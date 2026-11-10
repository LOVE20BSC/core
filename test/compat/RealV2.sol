// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Faithful subset of UniswapV2Pair: MINIMUM_LIQUIDITY, 0.3% fee, k-check, sync, skim, lock.
/// @dev    Only what Stake touches is implemented. `burn` pays out from balances, like the real pair.
contract RealV2Pair {
    uint256 private constant MINIMUM_LIQUIDITY = 1000;
    uint256 private constant FEE_NUMERATOR = 997;
    uint256 private constant FEE_DENOMINATOR = 1000;

    bool private _unlocked = true;

    modifier lock() {
        require(_unlocked, "V2: LOCKED");
        _unlocked = false;
        _;
        _unlocked = true;
    }

    address public immutable token0;
    address public immutable token1;

    uint112 private _reserve0;
    uint112 private _reserve1;
    uint32 private _blockTimestampLast;

    uint256 private _totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(address tokenA, address tokenB) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) {
        return (_reserve0, _reserve1, _blockTimestampLast);
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        return true;
    }

    function mint(address to) external lock returns (uint256 liquidity) {
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        if (_totalSupply == 0) {
            liquidity = _sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            liquidity = _min((amount0 * _totalSupply) / _reserve0, (amount1 * _totalSupply) / _reserve1);
        }
        require(liquidity > 0, "V2: INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);
        _update(balance0, balance1);
    }

    function burn(address to) external lock returns (uint256 amount0, uint256 amount1) {
        uint256 liquidity = balanceOf[address(this)];
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        amount0 = (liquidity * balance0) / _totalSupply;
        amount1 = (liquidity * balance1) / _totalSupply;
        require(amount0 > 0 && amount1 > 0, "V2: INSUFFICIENT_LIQUIDITY_BURNED");

        _burn(address(this), liquidity);
        IERC20(token0).transfer(to, amount0);
        IERC20(token1).transfer(to, amount1);

        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)));
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to) external lock {
        require(amount0Out > 0 || amount1Out > 0, "V2: INSUFFICIENT_OUTPUT_AMOUNT");
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "V2: INSUFFICIENT_LIQUIDITY");

        if (amount0Out > 0) IERC20(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).transfer(to, amount1Out);

        uint256 newBalance0 = IERC20(token0).balanceOf(address(this));
        uint256 newBalance1 = IERC20(token1).balanceOf(address(this));

        uint256 amount0In = newBalance0 > uint256(_reserve0) - amount0Out ? newBalance0 - (uint256(_reserve0) - amount0Out) : 0;
        uint256 amount1In = newBalance1 > uint256(_reserve1) - amount1Out ? newBalance1 - (uint256(_reserve1) - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "V2: INSUFFICIENT_INPUT_AMOUNT");

        uint256 adjusted0 = newBalance0 * FEE_DENOMINATOR - amount0In * (FEE_DENOMINATOR - FEE_NUMERATOR);
        uint256 adjusted1 = newBalance1 * FEE_DENOMINATOR - amount1In * (FEE_DENOMINATOR - FEE_NUMERATOR);
        require(
            adjusted0 * adjusted1 >= uint256(_reserve0) * uint256(_reserve1) * FEE_DENOMINATOR * FEE_DENOMINATOR,
            "V2: K"
        );
        _update(newBalance0, newBalance1);
    }

    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)));
    }

    function skim(address to) external lock {
        IERC20(token0).transfer(to, IERC20(token0).balanceOf(address(this)) - uint256(_reserve0));
        IERC20(token1).transfer(to, IERC20(token1).balanceOf(address(this)) - uint256(_reserve1));
    }

    function _update(uint256 balance0, uint256 balance1) private {
        require(balance0 <= type(uint112).max && balance1 <= type(uint112).max, "V2: OVERFLOW");
        _reserve0 = uint112(balance0);
        _reserve1 = uint112(balance1);
        _blockTimestampLast = uint32(block.timestamp);
    }

    function _mint(address to, uint256 value) private {
        _totalSupply += value;
        balanceOf[to] += value;
    }

    function _burn(address from, uint256 value) private {
        balanceOf[from] -= value;
        _totalSupply -= value;
    }

    function _sqrt(uint256 y) private pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract RealV2Factory {
    mapping(address => mapping(address => address)) public getPair;
    uint256 public createdPairCount;

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(getPair[tokenA][tokenB] == address(0), "V2: PAIR_EXISTS");
        pair = address(new RealV2Pair(tokenA, tokenB));
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
        createdPairCount += 1;
    }

    /// @notice Deploys a pair without counting it as a Launch creation (attacker pre-creation).
    function preCreatePair(address tokenA, address tokenB) external returns (address pair) {
        require(getPair[tokenA][tokenB] == address(0), "V2: PAIR_EXISTS");
        pair = address(new RealV2Pair(tokenA, tokenB));
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }
}

contract RealV2Router {
    address public immutable factory;

    constructor(address factoryAddress) {
        factory = factoryAddress;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        public
        view
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        (uint112 reserveIn, uint112 reserveOut) = _reserves(path[0], path[1]);
        amounts[1] = (amountIn * 997 * uint256(reserveOut)) / (uint256(reserveIn) * 1000 + amountIn * 997);
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external returns (uint256[] memory amounts) {
        amounts = getAmountsOut(amountIn, path);
        require(amounts[1] >= amountOutMin, "V2: INSUFFICIENT_OUTPUT_AMOUNT");

        address pair = RealV2Factory(factory).getPair(path[0], path[1]);
        IERC20(path[0]).transferFrom(msg.sender, pair, amountIn);
        if (path[0] == RealV2Pair(pair).token0()) {
            RealV2Pair(pair).swap(0, amounts[1], to);
        } else {
            RealV2Pair(pair).swap(amounts[1], 0, to);
        }
    }

    function _reserves(address tokenIn, address tokenOut) private view returns (uint112 reserveIn, uint112 reserveOut) {
        address pair = RealV2Factory(factory).getPair(tokenIn, tokenOut);
        (uint112 reserve0, uint112 reserve1,) = RealV2Pair(pair).getReserves();
        if (tokenIn == RealV2Pair(pair).token0()) {
            (reserveIn, reserveOut) = (reserve0, reserve1);
        } else {
            (reserveIn, reserveOut) = (reserve1, reserve0);
        }
    }
}
