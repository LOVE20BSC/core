// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

interface IUniswapV2Pair {
    // `token1()` is not declared: every caller identifies the community token by `token0()` and treats the
    // other reserve as the parent side. LP transfers go through the ERC20 interface, so `transfer` is not
    // declared here either.
    function token0() external view returns (address);
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function totalSupply() external view returns (uint256);
    function mint(address to) external returns (uint256 liquidity);
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
}
