#!/usr/bin/env bash
set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "Error: network name is required (e.g. bsc97_dev)"
    exit 1
fi
network="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
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

# 必需配置。载入顺序不可调整：core.params 以 ${WBNB_ADDRESS} 引用 addresses.dex.params。
set -a
source "$NETWORK_DIR/network.params"
source "$NETWORK_DIR/addresses.dex.params"
source "$NETWORK_DIR/core.params"
set +a

# 可选配置：已部署地址，以及账户信息（KEYSTORE_ACCOUNT / ACCOUNT_ADDRESS 之外的 KEYSTORE_PASSWORD 亦在此处）。
if [ -f "$NETWORK_DIR/addresses.core.params" ]; then
    set -a
    source "$NETWORK_DIR/addresses.core.params"
    set +a
fi

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

# 8 个核心合约地址，供 01_deploy.sh 与 verify.sh 共用校验。
# 字段必须写在函数体内：函数经 export -f 传给子进程后，未导出的数组会静默展开为空，校验会变成空转。
# 99_check.sh 支持独立运行（不 source 本文件），故保留自身检查。
require_core_addresses() {
    local field
    for field in LOVE20TOKEN_ADDRESS MEMBERNFT_ADDRESS PHASE_ADDRESS LAUNCH_ADDRESS \
        MINT_ADDRESS STAKE_ADDRESS SUBMIT_ADDRESS VOTE_ADDRESS; do
        if [[ ! ${!field:-} =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ ${!field:-} = 0x0000000000000000000000000000000000000000 ]]; then
            echo "Error: Missing or invalid $field"
            exit 1
        fi
    done
}
# 步骤文件可能作为子进程启动（如 bash -c 'source 00_init.sh <net> && bash 01_deploy.sh'），函数不随环境继承。
export -f require_core_addresses
