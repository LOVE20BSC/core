# Uniswap V2 接口

本目录包含与 Uniswap V2 协议交互所需的标准接口。这些接口定义了 LOVE20 协议与 Uniswap V2 兼容的 DEX（去中心化交易所）之间的交互规范。

## 接口文件

- **IUniswapV2Factory.sol** - 工厂合约接口，用于创建和查询交易对
- **IUniswapV2Pair.sol** - 流动性池接口，用于铸造/销毁 LP 代币和执行交换
- **IUniswapV2Router02.sol** - 路由器接口，用于添加/移除流动性和执行代币交换

## 兼容性

这些接口与以太坊主网上部署的 Uniswap V2 合约接口完全一致，也兼容 BSC 上的 PancakeSwap V2 等其他 Uniswap V2 分叉。

## 使用场景

- **Launch.sol** - 使用工厂接口为新启动的代币创建交易对
- **Stake.sol** - 使用所有三个接口管理流动性质押、费用结算和代币交换

## 注意事项

LOVE20 协议依赖这些标准接口与 DEX 交互，不应修改这些接口的签名或行为定义。
