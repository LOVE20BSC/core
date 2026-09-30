#!/usr/bin/env bash
# BSC Testnet 部署脚本
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

echo "==================================="
echo "BSC Testnet (Chapel) 部署指南"
echo "==================================="
echo ""

# 检查必要工具
check_tool() {
    if ! command -v "$1" &> /dev/null; then
        echo "❌ 错误: 未找到 $1"
        echo "   请先安装: $2"
        exit 1
    fi
}

echo "📋 检查必要工具..."
check_tool "forge" "curl -L https://foundry.paradigm.xyz | bash && foundryup"
check_tool "cast" "foundry (same as forge)"
echo "✅ 工具检查通过"
echo ""

# 加载网络配置
echo "📋 加载网络配置..."
source "$SCRIPT_DIR/network.params"
source "$SCRIPT_DIR/dex.params"

echo "  Chain ID: $CHAIN_ID"
echo "  RPC URL:  $RPC_URL"
echo "  Router:   $ROUTER_ADDRESS"
echo "  Factory:  $FACTORY_ADDRESS"
echo "  WBNB:     $WBNB_ADDRESS"
echo ""

# 检查 RPC 连接
echo "📋 测试 RPC 连接..."
BLOCK_NUMBER=$(cast block-number --rpc-url "$RPC_URL" 2>/dev/null || echo "")
if [ -z "$BLOCK_NUMBER" ]; then
    echo "❌ 错误: 无法连接到 RPC"
    echo "   请检查网络连接或更换 RPC 端点"
    exit 1
fi
echo "✅ RPC 连接正常 (当前区块: $BLOCK_NUMBER)"
echo ""

# 检查部署账户
echo "📋 检查部署账户..."
if [ -n "$ACCOUNT_ADDRESS" ]; then
    echo "  使用指定账户: $ACCOUNT_ADDRESS"
    DEPLOYER="$ACCOUNT_ADDRESS"
elif [ -n "$PRIVATE_KEY" ]; then
    DEPLOYER=$(cast wallet address "$PRIVATE_KEY" 2>/dev/null || echo "")
    if [ -z "$DEPLOYER" ]; then
        echo "❌ 错误: PRIVATE_KEY 格式无效"
        exit 1
    fi
    echo "  从私钥推导地址: $DEPLOYER"
else
    # 使用 Foundry 默认账户
    DEPLOYER=$(cast wallet address --keystore ~/.foundry/keystores/default 2>/dev/null || echo "")
    if [ -z "$DEPLOYER" ]; then
        echo "⚠️  未配置部署账户"
        echo ""
        echo "请选择以下方式之一："
        echo ""
        echo "1. 在 network.params 中设置 ACCOUNT_ADDRESS 和 PRIVATE_KEY"
        echo "   ACCOUNT_ADDRESS=0x..."
        echo "   PRIVATE_KEY=0x..."
        echo ""
        echo "2. 使用 Foundry keystore："
        echo "   cast wallet import default --interactive"
        echo ""
        echo "3. 使用 Ledger 硬件钱包（需要额外配置）"
        exit 1
    fi
    echo "  使用 Foundry 默认账户: $DEPLOYER"
fi

# 检查账户余额
BALANCE=$(cast balance "$DEPLOYER" --rpc-url "$RPC_URL" 2>/dev/null || echo "0")
BALANCE_ETH=$(cast --to-unit "$BALANCE" ether 2>/dev/null || echo "0")
echo "  余额: $BALANCE_ETH BNB"
echo ""

# 检查是否需要领取测试币
REQUIRED_BALANCE="100000000000000000" # 0.1 BNB
if [ "$BALANCE" -lt "$REQUIRED_BALANCE" ]; then
    echo "⚠️  余额不足，需要领取测试币"
    echo ""
    echo "📌 获取 BSC Testnet BNB："
    echo "   1. 访问: https://testnet.bnbchain.org/faucet-smart"
    echo "   2. 输入地址: $DEPLOYER"
    echo "   3. 完成验证并领取"
    echo ""
    echo "   或使用备用水龙头："
    echo "   - https://testnet.binance.org/faucet-smart"
    echo ""
    read -p "领取完成后按回车继续... " -r
    echo ""

    # 重新检查余额
    BALANCE=$(cast balance "$DEPLOYER" --rpc-url "$RPC_URL")
    BALANCE_ETH=$(cast --to-unit "$BALANCE" ether)
    echo "  新余额: $BALANCE_ETH BNB"

    if [ "$BALANCE" -lt "$REQUIRED_BALANCE" ]; then
        echo "❌ 余额仍不足，无法继续部署"
        exit 1
    fi
fi

echo "✅ 账户检查通过"
echo ""

# 验证 DEX 合约
echo "📋 验证 DEX 合约..."

# 检查 Router
ROUTER_CODE=$(cast code "$ROUTER_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
if [ "$ROUTER_CODE" = "0x" ] || [ -z "$ROUTER_CODE" ]; then
    echo "❌ 错误: Router 合约不存在"
    echo "   地址: $ROUTER_ADDRESS"
    exit 1
fi
echo "  ✓ Router 存在"

# 检查 Factory
FACTORY_CODE=$(cast code "$FACTORY_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
if [ "$FACTORY_CODE" = "0x" ] || [ -z "$FACTORY_CODE" ]; then
    echo "❌ 错误: Factory 合约不存在"
    echo "   地址: $FACTORY_ADDRESS"
    exit 1
fi
echo "  ✓ Factory 存在"

# 检查 WBNB
WBNB_CODE=$(cast code "$WBNB_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
if [ "$WBNB_CODE" = "0x" ] || [ -z "$WBNB_CODE" ]; then
    echo "❌ 错误: WBNB 合约不存在"
    echo "   地址: $WBNB_ADDRESS"
    exit 1
fi
echo "  ✓ WBNB 存在"

# 验证 Router 和 Factory 的关系
ROUTER_FACTORY=$(cast call "$ROUTER_ADDRESS" "factory()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
if [ "$(echo "$ROUTER_FACTORY" | tr '[:upper:]' '[:lower:]')" != "$(echo "$FACTORY_ADDRESS" | tr '[:upper:]' '[:lower:]')" ]; then
    echo "❌ 错误: Router.factory() 与配置的 Factory 地址不匹配"
    echo "   Router.factory(): $ROUTER_FACTORY"
    echo "   配置的 Factory:   $FACTORY_ADDRESS"
    exit 1
fi
echo "  ✓ Router-Factory 一致性验证通过"

echo "✅ DEX 合约验证通过"
echo ""

# 准备部署
echo "==================================="
echo "准备部署 LOVE20 Core 合约"
echo "==================================="
echo ""
echo "📋 部署参数汇总："
echo "  网络:     BSC Testnet (Chapel)"
echo "  Chain ID: $CHAIN_ID"
echo "  部署账户: $DEPLOYER"
echo "  余额:     $BALANCE_ETH BNB"
echo "  Router:   $ROUTER_ADDRESS"
echo "  Factory:  $FACTORY_ADDRESS"
echo "  WBNB:     $WBNB_ADDRESS"
echo ""
echo "⚠️  注意事项："
echo "  1. 合约部署后无法升级或修改"
echo "  2. 请仔细检查所有参数"
echo "  3. 建议先在本地 Anvil 测试"
echo "  4. 部署预计消耗 0.05-0.1 BNB"
echo ""

read -p "确认开始部署？(yes/no): " -r
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "已取消部署"
    exit 0
fi
echo ""

# 执行部署
echo "🚀 开始部署..."
cd "$CORE_DIR"

DEPLOY_CMD="forge script script/deploy/DeployCore.s.sol:DeployCore \
    --rpc-url $RPC_URL \
    --broadcast \
    --verify"

if [ -n "$PRIVATE_KEY" ]; then
    DEPLOY_CMD="$DEPLOY_CMD --private-key $PRIVATE_KEY"
elif [ -n "$ACCOUNT_ADDRESS" ]; then
    DEPLOY_CMD="$DEPLOY_CMD --sender $ACCOUNT_ADDRESS"
else
    DEPLOY_CMD="$DEPLOY_CMD --keystore ~/.foundry/keystores/default"
fi

if [ -n "$ETHERSCAN_API_KEY" ]; then
    DEPLOY_CMD="$DEPLOY_CMD --etherscan-api-key $ETHERSCAN_API_KEY"
fi

echo "执行命令:"
echo "$DEPLOY_CMD"
echo ""

eval "$DEPLOY_CMD"

DEPLOY_RESULT=$?
echo ""

if [ $DEPLOY_RESULT -eq 0 ]; then
    echo "✅ 部署成功！"
    echo ""
    echo "📋 后续步骤："
    echo "  1. 查看部署日志获取合约地址"
    echo "  2. 运行验证脚本: bash script/deploy/99_check.sh"
    echo "  3. 在 BscScan 上验证合约源码"
    echo "  4. 进行完整的集成测试"
    echo ""
    echo "🔗 BSC Testnet 浏览器:"
    echo "   https://testnet.bscscan.com/address/$DEPLOYER"
else
    echo "❌ 部署失败"
    echo ""
    echo "📋 故障排查："
    echo "  1. 检查 gas 是否充足"
    echo "  2. 检查 RPC 连接是否稳定"
    echo "  3. 查看详细错误信息"
    echo "  4. 尝试重新部署"
    exit 1
fi
