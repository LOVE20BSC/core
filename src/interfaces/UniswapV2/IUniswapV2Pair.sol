// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

interface IUniswapV2Pair {
    // The factory sorts token addresses, so the community token is not always `token0()`; callers that know
    // it compare against `token0()` to order the reserves. LP transfers go through the ERC20 interface, so
    // `transfer` is not declared here.
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function totalSupply() external view returns (uint256);
    function mint(address to) external returns (uint256 liquidity);
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
}
