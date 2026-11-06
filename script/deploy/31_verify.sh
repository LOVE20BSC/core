#!/usr/bin/env bash
set -euo pipefail

# Step 3: source verification. Self-contained: loads network.params, verifier.params, the dex
# UniswapV2 address file, core.params and the addresses.core.params written by the last deployment,
# without relying on the entrypoint to refresh addresses afterwards.
# Usage: script/deploy/31_verify.sh <network>

network="${1:?usage: script/deploy/31_verify.sh <network>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NETWORK_DIR="$PROJECT_ROOT/script/network/$network"
VERIFIER_PARAMS="$PROJECT_ROOT/script/network/verifier.params"

# Parameter file loader: 1e17 / 1_000_000 style literals are expanded to decimal on load (params.sh).
source "$SCRIPT_DIR/params.sh"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

# Load the dex UniswapV2 address file (FACTORY_ADDRESS / ROUTER_ADDRESS) and core.params; the root
# parent token is not configured - the parent address in the LOVE20Token constructor arguments is
# read from Router.WETH().
for config in network.params addresses.uniswapv2.params core.params addresses.core.params; do
    if [ ! -f "$NETWORK_DIR/$config" ]; then
        echo "Error: Missing required configuration: $NETWORK_DIR/$config"
        exit 1
    fi
done
if [ ! -f "$VERIFIER_PARAMS" ]; then
    echo "Error: Missing required configuration: $VERIFIER_PARAMS"
    exit 1
fi

# Parameters come from files only: clear every key the files define, so a value exported by the
# caller cannot override a file value.
params_unset_all "$NETWORK_DIR/network.params" "$VERIFIER_PARAMS" \
    "$NETWORK_DIR/addresses.uniswapv2.params" "$NETWORK_DIR/core.params" \
    "$NETWORK_DIR/addresses.core.params"

params_load "$NETWORK_DIR/network.params"
params_load "$VERIFIER_PARAMS"
params_load "$NETWORK_DIR/addresses.uniswapv2.params"
params_load "$NETWORK_DIR/core.params"
params_load "$NETWORK_DIR/addresses.core.params"

cd "$PROJECT_ROOT"

# The opt-out list is mandatory as a key but may be empty: "verify every chain" is a legal answer.
params_require_keys "$VERIFIER_PARAMS" VERIFY_SKIP_CHAIN_IDS || exit 1

# Verification is attempted by default: only the chains listed here skip it, so a new production
# chain fails loudly instead of passing unverified.
skip_chains=",${VERIFY_SKIP_CHAIN_IDS:-},"
if [ -n "${CHAIN_ID:-}" ] && [[ "$skip_chains" == *",$CHAIN_ID,"* ]]; then
    echo "Skip: source verification is disabled for chain $CHAIN_ID in $VERIFIER_PARAMS"
    exit 0
fi

# The endpoint is a mandatory key: an empty URL would be passed straight to forge.
params_require_values "$VERIFIER_PARAMS" ETHERSCAN_VERIFIER_URL || exit 1
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

# Encode all constructor arguments before submitting any verification request. A failing command
# substitution would silently abort under set -e, so each call is checked explicitly and every
# failure produces a clear message.
if ! ROOT_PARENT=$(cast call "$ROUTER_ADDRESS" "WETH()(address)" --rpc-url "$RPC_URL"); then
    echo "Error: Failed to read WETH() from Router $ROUTER_ADDRESS"
    exit 1
fi
if ! MEMBER_ARGS=$(cast abi-encode "constructor(uint256,uint256,uint256,uint256,address)" \
    "$MEMBER_BASE_DIVISOR" "$MEMBER_BYTES_THRESHOLD" "$MEMBER_MULTIPLIER" "$MEMBER_MAX_NAME_LENGTH" \
    "$LOVE20_TOKEN_ADDRESS"); then
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
    "$TOKEN_NAME" "$TOKEN_SYMBOL" "$LAUNCH_AMOUNT" "$MAX_SUPPLY" \
    "$DISTRIBUTOR_ADDRESS" "$MINT_ADDRESS" "$ROOT_PARENT"); then
    echo "Error: Failed to encode LOVE20Token constructor arguments"
    exit 1
fi
if ! LAUNCH_ARGS=$(cast abi-encode \
    "constructor((address,address,address,address,address,uint256,uint256,uint256,uint256,uint256,string,string))" \
    "($MINT_ADDRESS,$MEMBER_NFT_ADDRESS,$ROOT_PARENT,$FACTORY_ADDRESS,$DISTRIBUTOR_ADDRESS,$LAUNCH_COUNT_THRESHOLD_RATIO,\
$MAX_LAUNCH_COUNT,$TOKEN_SYMBOL_LENGTH,$LAUNCH_AMOUNT,$MAX_SUPPLY,$TOKEN_NAME,$TOKEN_SYMBOL)"); then
    echo "Error: Failed to encode Launch constructor arguments"
    exit 1
fi
if ! SUBMIT_ARGS=$(cast abi-encode "constructor(address,address,address,uint256)" \
    "$PHASE_ADDRESS" "$STAKE_ADDRESS" "$MEMBER_NFT_ADDRESS" "$SUBMIT_MIN_RATIO"); then
    echo "Error: Failed to encode Submit constructor arguments"
    exit 1
fi
if ! VOTE_ARGS=$(cast abi-encode "constructor(address,address,address,address)" \
    "$PHASE_ADDRESS" "$STAKE_ADDRESS" "$SUBMIT_ADDRESS" "$MEMBER_NFT_ADDRESS"); then
    echo "Error: Failed to encode Vote constructor arguments"
    exit 1
fi
if ! STAKE_ARGS=$(cast abi-encode \
    "constructor(address,address,address,address,address,address,uint256,uint256,uint256,uint256,uint256)" \
    "$PHASE_ADDRESS" "$MEMBER_NFT_ADDRESS" "$VOTE_ADDRESS" "$LAUNCH_ADDRESS" "$ROUTER_ADDRESS" \
    "$FACTORY_ADDRESS" "$PROMISED_WAITING_PHASES_MIN" "$PROMISED_WAITING_PHASES_MAX" \
    "$FEE_SETTLEMENT_RATIO" "$BOOST_STAKE_SUPPLY_FACTOR" "$BOOST_STAKE_MULTIPLIER"); then
    echo "Error: Failed to encode Stake constructor arguments"
    exit 1
fi
if ! MINT_ARGS=$(cast abi-encode "constructor(address,address,address,address,address,uint256,uint256,uint256)" \
    "$PHASE_ADDRESS" "$VOTE_ADDRESS" "$SUBMIT_ADDRESS" "$LAUNCH_ADDRESS" "$MEMBER_NFT_ADDRESS" \
    "$PROPOSAL_REWARD_MIN_VOTE_RATIO" "$ROUND_REWARD_GOV_RATIO" "$ROUND_REWARD_PROPOSAL_RATIO"); then
    echo "Error: Failed to encode Mint constructor arguments"
    exit 1
fi

COMMON_ARGS=(--chain "$CHAIN_ID" --verifier etherscan --verifier-url "$ETHERSCAN_VERIFIER_URL" --watch)
verify_contract() {
    local address=$1 name=$2
    shift 2
    echo "Verifying $name..."
    forge verify-contract "$address" "src/$name.sol:$name" "${COMMON_ARGS[@]}" "$@"
}

verify_contract "$MEMBER_NFT_ADDRESS" MemberNFT --constructor-args "$MEMBER_ARGS"
verify_contract "$PHASE_ADDRESS" Phase --constructor-args "$PHASE_ARGS"
verify_contract "$LAUNCH_ADDRESS" Launch --constructor-args "$LAUNCH_ARGS"
verify_contract "$LOVE20_TOKEN_ADDRESS" LOVE20Token --constructor-args "$TOKEN_ARGS"
verify_contract "$MINT_ADDRESS" Mint --constructor-args "$MINT_ARGS"
verify_contract "$STAKE_ADDRESS" Stake --constructor-args "$STAKE_ARGS"
verify_contract "$SUBMIT_ADDRESS" Submit --constructor-args "$SUBMIT_ARGS"
verify_contract "$VOTE_ADDRESS" Vote --constructor-args "$VOTE_ARGS"
echo "✓ Source verification succeeded for all 8 contracts"
