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
    # .account 可选配置 KEYSTORE_PASSWORD：非空则直接用于解锁 keystore，部署全程无交互；
    # 未配置或留空则不传该参数，由 forge 在终端询问密码。
    if [[ -n "${KEYSTORE_PASSWORD:-}" ]]; then
        FORGE_CMD+=(--password "$KEYSTORE_PASSWORD")
    fi
elif [[ "$CHAIN_ID" = "31337" && -n "${ACCOUNT_ADDRESS:-}" ]]; then
    FORGE_CMD+=(--sender "$ACCOUNT_ADDRESS" --unlocked)
else
    echo "Error: Set KEYSTORE_ACCOUNT in .account (public RPCs cannot sign with --unlocked)."
    exit 1
fi

# 执行部署
cd "$PROJECT_ROOT"
if ! { "${FORGE_CMD[@]}" 2>&1 | tee "$DEPLOY_LOG"; }; then
    echo "Error: Deployment failed; saved addresses were not changed."
    exit 1
fi

# 从部署输出中提取地址（DeployCore.s.sol 的 _logDeploymentSummary 输出）。
# grep 无匹配会让管道在 set -e 下静默中止，故逐个容错取值，缺项交由 require_core_addresses 报错。
LOVE20TOKEN_ADDRESS=$(grep "LOVE20TOKEN_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs || true)
MEMBERNFT_ADDRESS=$(grep "MEMBERNFT_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs || true)
PHASE_ADDRESS=$(grep "PHASE_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs || true)
LAUNCH_ADDRESS=$(grep "LAUNCH_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs || true)
MINT_ADDRESS=$(grep "MINT_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs || true)
STAKE_ADDRESS=$(grep "STAKE_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs || true)
SUBMIT_ADDRESS=$(grep "SUBMIT_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs || true)
VOTE_ADDRESS=$(grep "VOTE_ADDRESS=" "$DEPLOY_LOG" | tail -1 | cut -d'=' -f2 | xargs || true)

require_core_addresses
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
