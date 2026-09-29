#!/usr/bin/env bash
set -euo pipefail

network="${1:-}"
if [ -z "$network" ]; then
    echo "Usage: $0 <network>"
    echo "Example: $0 bsc97_dev"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00_init.sh" "$network" || exit 1

if [ -z "${LOVE20TOKEN_ADDRESS:-}" ] || [ -z "${MEMBERNFT_ADDRESS:-}" ] || \
   [ -z "${PHASE_ADDRESS:-}" ] || [ -z "${LAUNCH_ADDRESS:-}" ] || \
   [ -z "${MINT_ADDRESS:-}" ] || [ -z "${STAKE_ADDRESS:-}" ] || \
   [ -z "${SUBMIT_ADDRESS:-}" ] || [ -z "${VOTE_ADDRESS:-}" ]; then
    echo "Error: Contract addresses not found. Please deploy first."
    exit 1
fi

# 检查是否设置了 ETHERSCAN_API_KEY
if [ -z "${ETHERSCAN_API_KEY:-}" ]; then
    echo "Warning: ETHERSCAN_API_KEY not set. Skipping verification."
    exit 0
fi

echo "=== Verifying Contracts on Etherscan ==="

# 确定验证器URL
if [ "$CHAIN_ID" = "56" ]; then
    VERIFIER_URL="https://api.bscscan.com/api"
elif [ "$CHAIN_ID" = "97" ]; then
    VERIFIER_URL="https://api-testnet.bscscan.com/api"
else
    echo "Warning: Unknown chain ID $CHAIN_ID. Skipping verification."
    exit 0
fi

echo "Verifying MemberNFT..."
forge verify-contract "$MEMBERNFT_ADDRESS" \
    src/MemberNFT.sol:MemberNFT \
    --chain-id "$CHAIN_ID" \
    --verifier-url "$VERIFIER_URL" \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args $(cast abi-encode "constructor(uint256,uint256,uint256,uint256)" \
        "$MEMBER_BASE_DIVISOR" "$MEMBER_BYTES_THRESHOLD" "$MEMBER_MULTIPLIER" "$MEMBER_MAX_NAME_LENGTH") \
    --watch || echo "MemberNFT verification failed or already verified"

echo "Verifying Phase..."
forge verify-contract "$PHASE_ADDRESS" \
    src/Phase.sol:Phase \
    --chain-id "$CHAIN_ID" \
    --verifier-url "$VERIFIER_URL" \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args $(cast abi-encode "constructor(uint256,uint256,uint256,uint256,uint256)" \
        "$PHASE_ORIGIN_BLOCKS" "$PHASE_ORIGIN_PHASE_BLOCKS" "$PHASE_TARGET_SECONDS" \
        "$PHASE_ADJUST_THRESHOLD" "$PHASE_SYNC_OBSERVATION_LIMIT") \
    --watch || echo "Phase verification failed or already verified"

echo "Verifying Launch..."
forge verify-contract "$LAUNCH_ADDRESS" \
    src/Launch.sol:Launch \
    --chain-id "$CHAIN_ID" \
    --verifier-url "$VERIFIER_URL" \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --watch || echo "Launch verification failed or already verified"

echo "Verifying LOVE20Token..."
forge verify-contract "$LOVE20TOKEN_ADDRESS" \
    src/LOVE20Token.sol:LOVE20Token \
    --chain-id "$CHAIN_ID" \
    --verifier-url "$VERIFIER_URL" \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args $(cast abi-encode "constructor(string,string,uint256,uint256,address,address,address)" \
        "$TOKEN_NAME" "$TOKEN_SYMBOL" "$INITIAL_SUPPLY" "$MAX_SUPPLY" \
        "$DISTRIBUTOR" "$MINTER" "$PARENT_TOKEN") \
    --watch || echo "LOVE20Token verification failed or already verified"

echo "Verifying Mint..."
forge verify-contract "$MINT_ADDRESS" \
    src/Mint.sol:Mint \
    --chain-id "$CHAIN_ID" \
    --verifier-url "$VERIFIER_URL" \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --watch || echo "Mint verification failed or already verified"

echo "Verifying Stake..."
forge verify-contract "$STAKE_ADDRESS" \
    src/Stake.sol:Stake \
    --chain-id "$CHAIN_ID" \
    --verifier-url "$VERIFIER_URL" \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --watch || echo "Stake verification failed or already verified"

echo "Verifying Submit..."
forge verify-contract "$SUBMIT_ADDRESS" \
    src/Submit.sol:Submit \
    --chain-id "$CHAIN_ID" \
    --verifier-url "$VERIFIER_URL" \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --watch || echo "Submit verification failed or already verified"

echo "Verifying Vote..."
forge verify-contract "$VOTE_ADDRESS" \
    src/Vote.sol:Vote \
    --chain-id "$CHAIN_ID" \
    --verifier-url "$VERIFIER_URL" \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --watch || echo "Vote verification failed or already verified"

echo "✓ Contract verification completed"
