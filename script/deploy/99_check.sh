#!/usr/bin/env bash
set -euo pipefail

echo "=== Verifying Deployment ==="

# 检查所有合约地址是否已设置
if [ -z "${LOVE20TOKEN_ADDRESS:-}" ] || [ -z "${MEMBERNFT_ADDRESS:-}" ] || \
   [ -z "${PHASE_ADDRESS:-}" ] || [ -z "${LAUNCH_ADDRESS:-}" ] || \
   [ -z "${MINT_ADDRESS:-}" ] || [ -z "${STAKE_ADDRESS:-}" ] || \
   [ -z "${SUBMIT_ADDRESS:-}" ] || [ -z "${VOTE_ADDRESS:-}" ]; then
    echo "Error: Not all contract addresses are set"
    exit 1
fi

# 验证合约是否部署成功（检查bytecode）
echo "Checking LOVE20Token at $LOVE20TOKEN_ADDRESS..."
TOKEN_CODE=$(cast code "$LOVE20TOKEN_ADDRESS" --rpc-url "$RPC_URL")
if [ "$TOKEN_CODE" = "0x" ]; then
    echo "Error: LOVE20Token not deployed"
    exit 1
fi

echo "Checking MemberNFT at $MEMBERNFT_ADDRESS..."
MEMBER_CODE=$(cast code "$MEMBERNFT_ADDRESS" --rpc-url "$RPC_URL")
if [ "$MEMBER_CODE" = "0x" ]; then
    echo "Error: MemberNFT not deployed"
    exit 1
fi

echo "Checking Phase at $PHASE_ADDRESS..."
PHASE_CODE=$(cast code "$PHASE_ADDRESS" --rpc-url "$RPC_URL")
if [ "$PHASE_CODE" = "0x" ]; then
    echo "Error: Phase not deployed"
    exit 1
fi

echo "Checking Launch at $LAUNCH_ADDRESS..."
LAUNCH_CODE=$(cast code "$LAUNCH_ADDRESS" --rpc-url "$RPC_URL")
if [ "$LAUNCH_CODE" = "0x" ]; then
    echo "Error: Launch not deployed"
    exit 1
fi

echo "Checking Mint at $MINT_ADDRESS..."
MINT_CODE=$(cast code "$MINT_ADDRESS" --rpc-url "$RPC_URL")
if [ "$MINT_CODE" = "0x" ]; then
    echo "Error: Mint not deployed"
    exit 1
fi

echo "Checking Stake at $STAKE_ADDRESS..."
STAKE_CODE=$(cast code "$STAKE_ADDRESS" --rpc-url "$RPC_URL")
if [ "$STAKE_CODE" = "0x" ]; then
    echo "Error: Stake not deployed"
    exit 1
fi

echo "Checking Submit at $SUBMIT_ADDRESS..."
SUBMIT_CODE=$(cast code "$SUBMIT_ADDRESS" --rpc-url "$RPC_URL")
if [ "$SUBMIT_CODE" = "0x" ]; then
    echo "Error: Submit not deployed"
    exit 1
fi

echo "Checking Vote at $VOTE_ADDRESS..."
VOTE_CODE=$(cast code "$VOTE_ADDRESS" --rpc-url "$RPC_URL")
if [ "$VOTE_CODE" = "0x" ]; then
    echo "Error: Vote not deployed"
    exit 1
fi

# 验证合约配置
echo "Verifying token configuration..."
TOKEN_NAME=$(cast call "$LOVE20TOKEN_ADDRESS" "name()(string)" --rpc-url "$RPC_URL")
TOKEN_SYMBOL=$(cast call "$LOVE20TOKEN_ADDRESS" "symbol()(string)" --rpc-url "$RPC_URL")
echo "  Token: $TOKEN_NAME ($TOKEN_SYMBOL)"

echo "Verifying MemberNFT configuration..."
BASE_DIVISOR=$(cast call "$MEMBERNFT_ADDRESS" "BASE_DIVISOR()(uint256)" --rpc-url "$RPC_URL")
echo "  BASE_DIVISOR: $BASE_DIVISOR"

echo "Verifying Phase configuration..."
TARGET_SECONDS=$(cast call "$PHASE_ADDRESS" "TARGET_SECONDS()(uint256)" --rpc-url "$RPC_URL")
echo "  TARGET_SECONDS: $TARGET_SECONDS"

echo "✓ All contracts deployed and verified successfully"
