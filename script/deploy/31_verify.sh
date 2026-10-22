#!/usr/bin/env bash
set -euo pipefail

# 步骤三：合约开源验证。自包含——自行载入 network.params、dex 的两个模块地址文件、core.params
# 与上次部署写入的 addresses.core.params，不依赖入口脚本在部署后刷新地址。
# 用法：script/deploy/31_verify.sh <network>

network="${1:?usage: script/deploy/31_verify.sh <network>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NETWORK_DIR="$PROJECT_ROOT/script/network/$network"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

# 载入 dex UniswapV2 模块地址文件（FACTORY_ADDRESS / ROUTER_ADDRESS）与 core.params；
# 根父币不配置，LOVE20Token 构造参数里的父币地址从 Router.WETH() 现场读取。
for config in network.params addresses.uniswapv2.params core.params addresses.core.params; do
    if [ ! -f "$NETWORK_DIR/$config" ]; then
        echo "Error: Missing required configuration: $NETWORK_DIR/$config"
        exit 1
    fi
done

set -a
source "$NETWORK_DIR/network.params"
source "$NETWORK_DIR/addresses.uniswapv2.params"
source "$NETWORK_DIR/core.params"
source "$NETWORK_DIR/addresses.core.params"
set +a

cd "$PROJECT_ROOT"

# 链不支持开源验证时跳过，不视为失败，使一键部署在本地/未接入浏览器的链上仍可跑通。
case "$CHAIN_ID" in
    56|97) ;;
    *) echo "Skip: source verification is not configured for chain $CHAIN_ID"; exit 0 ;;
esac
: "${ETHERSCAN_API_KEY:?Set an Etherscan API key; source verification has not run.}"

require_core_addresses() {
    local field
    for field in LOVE20_TOKEN_ADDRESS MEMBER_NFT_ADDRESS PHASE_ADDRESS LAUNCH_ADDRESS \
        MINT_ADDRESS STAKE_ADDRESS SUBMIT_ADDRESS VOTE_ADDRESS; do
        if [[ ! ${!field:-} =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ ${!field:-} = 0x0000000000000000000000000000000000000000 ]]; then
            echo "Error: Missing or invalid $field in $NETWORK_DIR/addresses.core.params"
            exit 1
        fi
    done
}
require_core_addresses

# Encode all constructor arguments before submitting any verification request.
# 命令替换失败在 set -e 下会静默中止，故逐个显式判别，保证失败有明确输出。
if ! ROOT_PARENT=$(cast call "$ROUTER_ADDRESS" "WETH()(address)" --rpc-url "$RPC_URL"); then
    echo "Error: Failed to read WETH() from Router $ROUTER_ADDRESS"
    exit 1
fi
if ! MEMBER_ARGS=$(cast abi-encode "constructor(uint256,uint256,uint256,uint256)" \
    "$MEMBER_BASE_DIVISOR" "$MEMBER_BYTES_THRESHOLD" "$MEMBER_MULTIPLIER" "$MEMBER_MAX_NAME_LENGTH"); then
    echo "Error: Failed to encode MemberNFT constructor arguments"
    exit 1
fi
if ! PHASE_ARGS=$(cast abi-encode "constructor(uint256,uint256,uint256,uint256,uint256)" \
    "$PHASE_ORIGIN_BLOCKS" "$PHASE_ORIGIN_PHASE_BLOCKS" "$PHASE_TARGET_SECONDS" \
    "$PHASE_ADJUST_THRESHOLD" "$PHASE_SYNC_OBSERVATION_LIMIT"); then
    echo "Error: Failed to encode Phase constructor arguments"
    exit 1
fi
if ! TOKEN_ARGS=$(cast abi-encode "constructor(string,string,uint256,uint256,address,address,address)" \
    "$TOKEN_NAME" "$TOKEN_SYMBOL" "$INITIAL_SUPPLY" "$MAX_SUPPLY" \
    "$DISTRIBUTOR" "$MINT_ADDRESS" "$ROOT_PARENT"); then
    echo "Error: Failed to encode LOVE20Token constructor arguments"
    exit 1
fi

COMMON_ARGS=(--chain "$CHAIN_ID" --verifier etherscan --verifier-url "https://api.etherscan.io/v2/api" --watch)
verify_contract() {
    local address=$1 name=$2
    shift 2
    echo "Verifying $name..."
    forge verify-contract "$address" "src/$name.sol:$name" "${COMMON_ARGS[@]}" "$@"
}

verify_contract "$MEMBER_NFT_ADDRESS" MemberNFT --constructor-args "$MEMBER_ARGS"
verify_contract "$PHASE_ADDRESS" Phase --constructor-args "$PHASE_ARGS"
verify_contract "$LAUNCH_ADDRESS" Launch
verify_contract "$LOVE20_TOKEN_ADDRESS" LOVE20Token --constructor-args "$TOKEN_ARGS"
verify_contract "$MINT_ADDRESS" Mint
verify_contract "$STAKE_ADDRESS" Stake
verify_contract "$SUBMIT_ADDRESS" Submit
verify_contract "$VOTE_ADDRESS" Vote
echo "✓ Source verification succeeded for all 8 contracts"
