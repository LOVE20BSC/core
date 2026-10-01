#!/usr/bin/env bash
set -euo pipefail

network="${1:-}"
if [ -z "$network" ]; then
    echo "Usage: $0 <network>"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00_init.sh" "$network"
cd "$PROJECT_ROOT"
: "${ETHERSCAN_API_KEY:?Set an Etherscan API key; source verification has not run.}"
case "$CHAIN_ID" in
    56|97) ;;
    *) echo "Error: Source verification is not configured for chain $CHAIN_ID"; exit 1 ;;
esac

require_core_addresses

# Encode all constructor arguments before submitting any verification request.
# 命令替换失败在 set -e 下会静默中止，故逐个显式判别，保证失败有明确输出。
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
    "$DISTRIBUTOR" "$MINT_ADDRESS" "$PARENT_TOKEN"); then
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

verify_contract "$MEMBERNFT_ADDRESS" MemberNFT --constructor-args "$MEMBER_ARGS"
verify_contract "$PHASE_ADDRESS" Phase --constructor-args "$PHASE_ARGS"
verify_contract "$LAUNCH_ADDRESS" Launch
verify_contract "$LOVE20TOKEN_ADDRESS" LOVE20Token --constructor-args "$TOKEN_ARGS"
verify_contract "$MINT_ADDRESS" Mint
verify_contract "$STAKE_ADDRESS" Stake
verify_contract "$SUBMIT_ADDRESS" Submit
verify_contract "$VOTE_ADDRESS" Vote
echo "✓ Source verification succeeded for all 8 contracts"
