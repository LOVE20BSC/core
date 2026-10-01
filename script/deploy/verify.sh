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

for field in LOVE20TOKEN_ADDRESS MEMBERNFT_ADDRESS PHASE_ADDRESS LAUNCH_ADDRESS MINT_ADDRESS STAKE_ADDRESS SUBMIT_ADDRESS VOTE_ADDRESS; do
    if [[ ! ${!field:-} =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ ${!field} = 0x0000000000000000000000000000000000000000 ]]; then
        echo "Error: Missing or invalid $field"
        exit 1
    fi
done

# Encode all constructor arguments before submitting any verification request.
MEMBER_ARGS=$(cast abi-encode "constructor(uint256,uint256,uint256,uint256)" \
    "$MEMBER_BASE_DIVISOR" "$MEMBER_BYTES_THRESHOLD" "$MEMBER_MULTIPLIER" "$MEMBER_MAX_NAME_LENGTH")
PHASE_ARGS=$(cast abi-encode "constructor(uint256,uint256,uint256,uint256,uint256)" \
    "$PHASE_ORIGIN_BLOCKS" "$PHASE_ORIGIN_PHASE_BLOCKS" "$PHASE_TARGET_SECONDS" \
    "$PHASE_ADJUST_THRESHOLD" "$PHASE_SYNC_OBSERVATION_LIMIT")
TOKEN_ARGS=$(cast abi-encode "constructor(string,string,uint256,uint256,address,address,address)" \
    "$TOKEN_NAME" "$TOKEN_SYMBOL" "$INITIAL_SUPPLY" "$MAX_SUPPLY" \
    "$DISTRIBUTOR" "$MINT_ADDRESS" "$PARENT_TOKEN")

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
