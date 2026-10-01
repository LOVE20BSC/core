#!/usr/bin/env bash
set -euo pipefail

network="${1:-anvil31337_dev}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NETWORK_DIR="$PROJECT_ROOT/script/network/$network"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

for config in network.params addresses.dex.params core.params; do
    if [ ! -f "$NETWORK_DIR/$config" ]; then
        echo "Error: Missing required configuration: $NETWORK_DIR/$config"
        exit 1
    fi
done

# 加载网络配置
if [ -f "$NETWORK_DIR/network.params" ]; then
    set -a
    source "$NETWORK_DIR/network.params"
    set +a
fi

# 加载 dex 部署地址（WBNB, Factory, Router）
if [ -f "$NETWORK_DIR/addresses.dex.params" ]; then
    set -a
    source "$NETWORK_DIR/addresses.dex.params"
    set +a
fi

# 加载合约参数
if [ -f "$NETWORK_DIR/core.params" ]; then
    set -a
    source "$NETWORK_DIR/core.params"
    set +a
fi

# 加载已部署地址
if [ -f "$NETWORK_DIR/addresses.core.params" ]; then
    set -a
    source "$NETWORK_DIR/addresses.core.params"
    set +a
fi

# 加载账户信息
if [ -f "$NETWORK_DIR/.account" ]; then
    set -a
    source "$NETWORK_DIR/.account"
    set +a
fi

export network
export NETWORK_DIR
export PROJECT_ROOT

# 确认实际链，不能只检查 RPC 是否可连接。
ACTUAL_CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL") || exit 1
if [ "$ACTUAL_CHAIN_ID" != "$CHAIN_ID" ]; then
    echo "Error: RPC chain ID $ACTUAL_CHAIN_ID does not match configured CHAIN_ID $CHAIN_ID"
    exit 1
fi

echo "✓ Initialized environment for network: $network"
echo "  RPC_URL: $RPC_URL"
echo "  CHAIN_ID: $CHAIN_ID"
