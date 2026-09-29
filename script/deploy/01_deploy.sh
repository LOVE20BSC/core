#!/usr/bin/env bash
set -euo pipefail

echo "=== Deploying Core Contracts to $network ==="

DEPLOY_OUTPUT=$(forge script script/deploy/DeployCore.s.sol:DeployCore \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --slow \
    -vvv 2>&1)

echo "$DEPLOY_OUTPUT"

# 提取部署地址
LOVE20TOKEN_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep "LOVE20TOKEN_ADDRESS=" | tail -1 | cut -d'=' -f2 | xargs)
MEMBERNFT_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep "MEMBERNFT_ADDRESS=" | tail -1 | cut -d'=' -f2 | xargs)
PHASE_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep "PHASE_ADDRESS=" | tail -1 | cut -d'=' -f2 | xargs)
LAUNCH_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep "LAUNCH_ADDRESS=" | tail -1 | cut -d'=' -f2 | xargs)
MINT_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep "MINT_ADDRESS=" | tail -1 | cut -d'=' -f2 | xargs)
STAKE_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep "STAKE_ADDRESS=" | tail -1 | cut -d'=' -f2 | xargs)
SUBMIT_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep "SUBMIT_ADDRESS=" | tail -1 | cut -d'=' -f2 | xargs)
VOTE_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep "VOTE_ADDRESS=" | tail -1 | cut -d'=' -f2 | xargs)

# 写入地址文件
cat > "$NETWORK_DIR/addresses.core.params" <<EOF
LOVE20TOKEN_ADDRESS=$LOVE20TOKEN_ADDRESS
MEMBERNFT_ADDRESS=$MEMBERNFT_ADDRESS
PHASE_ADDRESS=$PHASE_ADDRESS
LAUNCH_ADDRESS=$LAUNCH_ADDRESS
MINT_ADDRESS=$MINT_ADDRESS
STAKE_ADDRESS=$STAKE_ADDRESS
SUBMIT_ADDRESS=$SUBMIT_ADDRESS
VOTE_ADDRESS=$VOTE_ADDRESS
EOF

echo "✓ Deployment completed and addresses saved"
export LOVE20TOKEN_ADDRESS MEMBERNFT_ADDRESS PHASE_ADDRESS LAUNCH_ADDRESS MINT_ADDRESS STAKE_ADDRESS SUBMIT_ADDRESS VOTE_ADDRESS
