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

# 加载网络配置
if [ -f "$NETWORK_DIR/network.params" ]; then
    set -a
    source "$NETWORK_DIR/network.params"
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

echo "✓ Initialized environment for network: $network"
echo "  RPC_URL: $RPC_URL"
echo "  CHAIN_ID: $CHAIN_ID"
