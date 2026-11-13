// SPDX-License-Identifier: MIT
pragma solidity =0.8.37;

interface IUniswapV2Factory {
    /// @dev Non-zero when the DEX keeps a protocol fee; the pair then mints 1/6 of its sqrt(k)
    ///      growth to this address on every mint/burn. Stake must account for that dilution.
    function feeTo() external view returns (address);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}
