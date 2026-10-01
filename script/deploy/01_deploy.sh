#!/usr/bin/env bash
set -euo pipefail

echo "=== Deploying Core Contracts to $network ==="

# 准备部署日志
DEPLOY_LOG=$(mktemp)
trap "rm -f $DEPLOY_LOG" EXIT

# 构建 forge script 命令
FORGE_CMD=(forge script script/deploy/DeployCore.s.sol:DeployCore --rpc-url "$RPC_URL" --chain-id "$CHAIN_ID" --broadcast --slow -vvv)

# 公共网络使用 Keystore；仅本地链允许节点托管账户签名。
if [[ -n "${KEYSTORE_ACCOUNT:-}" ]]; then
    FORGE_CMD+=(--account "$KEYSTORE_ACCOUNT")
    if [[ -n "${ACCOUNT_ADDRESS:-}" ]]; then
        FORGE_CMD+=(--sender "$ACCOUNT_ADDRESS")
    fi
elif [[ "$CHAIN_ID" = "31337" && -n "${ACCOUNT_ADDRESS:-}" ]]; then
    FORGE_CMD+=(--sender "$ACCOUNT_ADDRESS" --unlocked)
else
    echo "Error: Set KEYSTORE_ACCOUNT in .account (public RPCs cannot sign with --unlocked)."
    exit 1
fi

# 执行部署
cd "$PROJECT_ROOT"
if ! WRITE_ADDRESS_FILE=false "${FORGE_CMD[@]}" 2>&1 | tee "$DEPLOY_LOG"; then
    echo "Error: Deployment failed; saved addresses were not changed."
    exit 1
fi

# 从部署输出中提取地址（DeployCore.s.sol 的 _logDeploymentSummary 输出）
LOVE20TOKEN_ADDRESS=$(grep "LOVE20TOKEN_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs)
MEMBERNFT_ADDRESS=$(grep "MEMBERNFT_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs)
PHASE_ADDRESS=$(grep "PHASE_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs)
LAUNCH_ADDRESS=$(grep "LAUNCH_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs)
MINT_ADDRESS=$(grep "MINT_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs)
STAKE_ADDRESS=$(grep "STAKE_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs)
SUBMIT_ADDRESS=$(grep "SUBMIT_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs)
VOTE_ADDRESS=$(grep "VOTE_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs)

for field in LOVE20TOKEN_ADDRESS MEMBERNFT_ADDRESS PHASE_ADDRESS LAUNCH_ADDRESS MINT_ADDRESS STAKE_ADDRESS SUBMIT_ADDRESS VOTE_ADDRESS; do
    if [[ ! ${!field} =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ ${!field} = 0x0000000000000000000000000000000000000000 ]]; then
        echo "Error: Missing or invalid $field in deployment output."
        exit 1
    fi
done
export LOVE20TOKEN_ADDRESS MEMBERNFT_ADDRESS PHASE_ADDRESS LAUNCH_ADDRESS MINT_ADDRESS STAKE_ADDRESS SUBMIT_ADDRESS VOTE_ADDRESS
bash "$PROJECT_ROOT/script/deploy/99_check.sh"

# 写入地址文件
cat > "$NETWORK_DIR/addresses.core.params" <<EOFADDR
LOVE20TOKEN_ADDRESS=$LOVE20TOKEN_ADDRESS
MEMBERNFT_ADDRESS=$MEMBERNFT_ADDRESS
PHASE_ADDRESS=$PHASE_ADDRESS
LAUNCH_ADDRESS=$LAUNCH_ADDRESS
MINT_ADDRESS=$MINT_ADDRESS
STAKE_ADDRESS=$STAKE_ADDRESS
SUBMIT_ADDRESS=$SUBMIT_ADDRESS
VOTE_ADDRESS=$VOTE_ADDRESS
EOFADDR

echo "✓ Deployment completed and addresses saved"
