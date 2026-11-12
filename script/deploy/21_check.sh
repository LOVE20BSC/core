#!/usr/bin/env bash
set -euo pipefail

# Deployment check: read-only over config and chain state.
# Loads its own inputs instead of relying on a preloaded environment: network.params provides
# RPC and chain ID, the dex UniswapV2 address file the expected bindings, core.params the
# expected deployment parameters and addresses.core.params the addresses to verify.
# The expected root parent token comes from the on-chain Router.WETH() (the same source the
# deploy script reads) and is not registered again in the configuration.
# Usage: script/deploy/21_check.sh <network>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

network="${1:?usage: script/deploy/21_check.sh <network>}"
NETWORK_DIR="$PROJECT_ROOT/script/network/$network"

# Parameter file loader: 1e17 / 1_000_000 style literals are expanded to decimal on load (params.sh).
source "$SCRIPT_DIR/params.sh"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

# Load the dex UniswapV2 address file (FACTORY_ADDRESS / ROUTER_ADDRESS) and core.params; the root
# parent token is not configured: its expected value is read from Router.WETH(), as in
# DeployCore.s.sol.
for config in network.params addresses.uniswapv2.params core.params addresses.core.params; do
    if [ ! -f "$NETWORK_DIR/$config" ]; then
        echo "Error: Missing required configuration: $NETWORK_DIR/$config"
        exit 1
    fi
done

# Parameters come from files only: clear every key the files define, so a value exported by the
# caller cannot override a file value.
params_unset_all "$NETWORK_DIR/network.params" "$NETWORK_DIR/addresses.uniswapv2.params" \
    "$NETWORK_DIR/core.params" "$NETWORK_DIR/addresses.core.params"

params_load "$NETWORK_DIR/network.params"
params_load "$NETWORK_DIR/addresses.uniswapv2.params"
params_load "$NETWORK_DIR/core.params"
params_load "$NETWORK_DIR/addresses.core.params"

# The address file's key set must equal the expected contract set: a renamed key would leave later
# variables silently empty and fail much later with an unhelpful message, so assert it here.
address_file="$NETWORK_DIR/addresses.core.params"
expected_keys="AIRDROP_DISTRIBUTOR_ADDRESS LAUNCH_ADDRESS LOVE20_TOKEN_ADDRESS MEMBER_NFT_ADDRESS MINT_ADDRESS PHASE_ADDRESS STAKE_ADDRESS SUBMIT_ADDRESS VOTE_ADDRESS"
actual_keys=$(grep -oE '^[A-Z0-9_]+=' "$address_file" | sed 's/=$//' | sort | tr '\n' ' ' || true)
if [ "$actual_keys" != "$(printf '%s\n' $expected_keys | sort | tr '\n' ' ')" ]; then
    echo "Error: $address_file key set mismatch"
    echo "  expected: $(printf '%s\n' $expected_keys | sort | tr '\n' ' ')"
    echo "  actual:   $actual_keys"
    exit 1
fi

# Expected root parent token: on-chain Router.WETH(), the same source DeployCore.s.sol uses.
ROUTER_WETH=$(cast call "$ROUTER_ADDRESS" "WETH()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
if [ "$ROUTER_WETH" = "ERROR" ]; then
    echo "Error: Failed to read WETH() from Router $ROUTER_ADDRESS"
    exit 1
fi

# Colors.
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

echo ""
echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     Verifying Contract Deployment     ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
echo ""

# Every contract address must be set.
if [ -z "${LOVE20_TOKEN_ADDRESS:-}" ] || [ -z "${AIRDROP_DISTRIBUTOR_ADDRESS:-}" ] || \
   [ -z "${MEMBER_NFT_ADDRESS:-}" ] || \
   [ -z "${PHASE_ADDRESS:-}" ] || [ -z "${LAUNCH_ADDRESS:-}" ] || \
   [ -z "${MINT_ADDRESS:-}" ] || [ -z "${STAKE_ADDRESS:-}" ] || \
   [ -z "${SUBMIT_ADDRESS:-}" ] || [ -z "${VOTE_ADDRESS:-}" ]; then
    echo -e "${RED}✗ Error: Not all contract addresses are set${NC}"
    exit 1
fi

# Helper: normalize output (strip quotes and the scientific-notation marker).
normalize_output() {
    local value="$1"
    # strip surrounding quotes
    value="${value%\"}"
    value="${value#\"}"
    # strip the scientific-notation marker [1e18]
    value="${value% \[*\]}"
    echo "$value"
}

# Helper: verify a single value.
verify_value() {
    local field_name=$1
    local expected=$2
    local actual=$3

    # normalize both values
    expected=$(normalize_output "$expected")
    actual=$(normalize_output "$actual")

    if [[ "$expected" =~ ^0x[0-9a-fA-F]{40}$ && "$actual" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        expected=$(echo "$expected" | tr '[:upper:]' '[:lower:]')
        actual=$(echo "$actual" | tr '[:upper:]' '[:lower:]')
    fi

    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}✓${NC} ${field_name}"
        echo -e "    ${GRAY}Expected: ${expected}${NC}"
        echo -e "    ${GRAY}Actual:   ${actual}${NC}"
        return 0
    else
        echo -e "  ${RED}✗${NC} ${field_name}"
        echo -e "    ${GRAY}Expected: ${expected}${NC}"
        echo -e "    ${YELLOW}Actual:   ${actual}${NC}"
        return 1
    fi
}

# Helper: verify that a contract is deployed.
verify_deployed() {
    local name=$1
    local address=$2

    local code
    code=$(cast code "$address" --rpc-url "$RPC_URL" 2>/dev/null) || return 1
    if [[ ! "$code" =~ ^0x[0-9a-fA-F]+$ ]]; then
        echo -e "${RED}✗ $name not deployed at $address${NC}"
        return 1
    fi
    return 0
}

# Helper: print a contract header.
print_contract_header() {
    local num=$1
    local name=$2
    local address=$3
    echo ""
    echo -e "${BLUE}[$num/9]${NC} ${CYAN}${name}${NC}"
    echo -e "${GRAY}      ${address}${NC}"
}

FAILED=0
ACTUAL_CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
verify_value "CHAIN_ID" "$CHAIN_ID" "$ACTUAL_CHAIN_ID" || exit 1

# 1. LOVE20Token.
print_contract_header "1" "LOVE20Token" "$LOVE20_TOKEN_ADDRESS"
verify_deployed "LOVE20Token" "$LOVE20_TOKEN_ADDRESS" || ((FAILED+=1))

ACTUAL_NAME=$(cast call "$LOVE20_TOKEN_ADDRESS" "name()(string)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "name" "$TOKEN_NAME" "$ACTUAL_NAME" || ((FAILED+=1))

ACTUAL_SYMBOL=$(cast call "$LOVE20_TOKEN_ADDRESS" "symbol()(string)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "symbol" "$TOKEN_SYMBOL" "$ACTUAL_SYMBOL" || ((FAILED+=1))

ACTUAL_MAX_SUPPLY=$(cast call "$LOVE20_TOKEN_ADDRESS" "MAX_SUPPLY()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "MAX_SUPPLY" "$MAX_SUPPLY" "$ACTUAL_MAX_SUPPLY" || ((FAILED+=1))

ACTUAL_MINTER=$(cast call "$LOVE20_TOKEN_ADDRESS" "MINTER()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "MINTER" "$MINT_ADDRESS" "$ACTUAL_MINTER" || ((FAILED+=1))

ACTUAL_TOTAL_SUPPLY=$(cast call "$LOVE20_TOKEN_ADDRESS" "totalSupply()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
# totalSupply / distributor balance equal the deployment values only while the first token has no
# mint, burn or transfer: this step is idempotent read-only, not a timeless invariant.
verify_value "totalSupply" "$LAUNCH_AMOUNT" "$ACTUAL_TOTAL_SUPPLY" || ((FAILED+=1))

ACTUAL_DISTRIBUTOR_BALANCE=$(cast call "$LOVE20_TOKEN_ADDRESS" "balanceOf(address)(uint256)" "$AIRDROP_DISTRIBUTOR_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "distributor balance" "$LAUNCH_AMOUNT" "$ACTUAL_DISTRIBUTOR_BALANCE" || ((FAILED+=1))

ACTUAL_PARENT=$(cast call "$LOVE20_TOKEN_ADDRESS" "PARENT_TOKEN_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "PARENT_TOKEN_ADDRESS" "$ROUTER_WETH" "$ACTUAL_PARENT" || ((FAILED+=1))

# 2. MemberNFT.
print_contract_header "2" "MemberNFT" "$MEMBER_NFT_ADDRESS"
verify_deployed "MemberNFT" "$MEMBER_NFT_ADDRESS" || ((FAILED+=1))

ACTUAL_BASE_DIVISOR=$(cast call "$MEMBER_NFT_ADDRESS" "BASE_DIVISOR()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "BASE_DIVISOR" "$MEMBER_BASE_DIVISOR" "$ACTUAL_BASE_DIVISOR" || ((FAILED+=1))

ACTUAL_BYTES_THRESHOLD=$(cast call "$MEMBER_NFT_ADDRESS" "BYTES_THRESHOLD()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "BYTES_THRESHOLD" "$MEMBER_BYTES_THRESHOLD" "$ACTUAL_BYTES_THRESHOLD" || ((FAILED+=1))

ACTUAL_MULTIPLIER=$(cast call "$MEMBER_NFT_ADDRESS" "MULTIPLIER()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "MULTIPLIER" "$MEMBER_MULTIPLIER" "$ACTUAL_MULTIPLIER" || ((FAILED+=1))

ACTUAL_MAX_NAME_LENGTH=$(cast call "$MEMBER_NFT_ADDRESS" "MAX_NAME_LENGTH()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "MAX_NAME_LENGTH" "$MEMBER_MAX_NAME_LENGTH" "$ACTUAL_MAX_NAME_LENGTH" || ((FAILED+=1))

ACTUAL_TOKEN=$(cast call "$MEMBER_NFT_ADDRESS" "LOVE20_TOKEN_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "LOVE20_TOKEN_ADDRESS" "$LOVE20_TOKEN_ADDRESS" "$ACTUAL_TOKEN" || ((FAILED+=1))

# 3. Phase.
print_contract_header "3" "Phase" "$PHASE_ADDRESS"
verify_deployed "Phase" "$PHASE_ADDRESS" || ((FAILED+=1))

ACTUAL_TARGET_SECONDS=$(cast call "$PHASE_ADDRESS" "TARGET_SECONDS()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "TARGET_SECONDS" "$PHASE_TARGET_SECONDS" "$ACTUAL_TARGET_SECONDS" || ((FAILED+=1))

ACTUAL_ADJUST_THRESHOLD=$(cast call "$PHASE_ADDRESS" "ADJUST_THRESHOLD()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "ADJUST_THRESHOLD" "$PHASE_ADJUST_THRESHOLD" "$ACTUAL_ADJUST_THRESHOLD" || ((FAILED+=1))

ACTUAL_ORIGIN_BLOCKS=$(cast call "$PHASE_ADDRESS" "ORIGIN_BLOCKS()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "ORIGIN_BLOCKS" "$PHASE_ORIGIN_BLOCKS" "$ACTUAL_ORIGIN_BLOCKS" || ((FAILED+=1))
ACTUAL_ORIGIN_PHASE_BLOCKS=$(cast call "$PHASE_ADDRESS" "ORIGIN_PHASE_BLOCKS()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "ORIGIN_PHASE_BLOCKS" "$PHASE_ORIGIN_PHASE_BLOCKS" "$ACTUAL_ORIGIN_PHASE_BLOCKS" || ((FAILED+=1))
ACTUAL_OBSERVATION_LIMIT=$(cast call "$PHASE_ADDRESS" "SYNC_OBSERVATION_LIMIT()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "SYNC_OBSERVATION_LIMIT" "$PHASE_SYNC_OBSERVATION_LIMIT" "$ACTUAL_OBSERVATION_LIMIT" || ((FAILED+=1))

# 4. Launch.
print_contract_header "4" "Launch" "$LAUNCH_ADDRESS"
verify_deployed "Launch" "$LAUNCH_ADDRESS" || ((FAILED+=1))

ACTUAL_LAUNCH_COUNT_THRESHOLD_RATIO=$(cast call "$LAUNCH_ADDRESS" "LAUNCH_COUNT_THRESHOLD_RATIO()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "LAUNCH_COUNT_THRESHOLD_RATIO" "$LAUNCH_COUNT_THRESHOLD_RATIO" "$ACTUAL_LAUNCH_COUNT_THRESHOLD_RATIO" || ((FAILED+=1))

ACTUAL_MAX_LAUNCH_COUNT=$(cast call "$LAUNCH_ADDRESS" "MAX_LAUNCH_COUNT()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "MAX_LAUNCH_COUNT" "$MAX_LAUNCH_COUNT" "$ACTUAL_MAX_LAUNCH_COUNT" || ((FAILED+=1))

ACTUAL_LAUNCH_MINT=$(cast call "$LAUNCH_ADDRESS" "MINT_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "MINT_ADDRESS" "$MINT_ADDRESS" "$ACTUAL_LAUNCH_MINT" || ((FAILED+=1))

ACTUAL_LAUNCH_MEMBER=$(cast call "$LAUNCH_ADDRESS" "MEMBER_NFT_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "MEMBER_NFT_ADDRESS" "$MEMBER_NFT_ADDRESS" "$ACTUAL_LAUNCH_MEMBER" || ((FAILED+=1))

ACTUAL_ROOT_PARENT=$(cast call "$LAUNCH_ADDRESS" "ROOT_PARENT_TOKEN_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "ROOT_PARENT_TOKEN_ADDRESS" "$ROUTER_WETH" "$ACTUAL_ROOT_PARENT" || ((FAILED+=1))
ACTUAL_LAUNCH_FACTORY=$(cast call "$LAUNCH_ADDRESS" "PAIR_FACTORY_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "PAIR_FACTORY_ADDRESS" "$FACTORY_ADDRESS" "$ACTUAL_LAUNCH_FACTORY" || ((FAILED+=1))
ACTUAL_SYMBOL_LENGTH=$(cast call "$LAUNCH_ADDRESS" "TOKEN_SYMBOL_LENGTH()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "TOKEN_SYMBOL_LENGTH" "$TOKEN_SYMBOL_LENGTH" "$ACTUAL_SYMBOL_LENGTH" || ((FAILED+=1))

# The testnet "Test" prefix is applied after the length check, so the final symbol is still bounded
# by Launch.MAX_TOKEN_SYMBOL_LENGTH. Both limits are read from chain instead of being duplicated
# here; every reading goes through normalize_output, or a cast scientific-notation suffix would read
# as non-numeric and turn a passing deployment into a failure.
ACTUAL_SYMBOL_LENGTH=$(normalize_output "${ACTUAL_SYMBOL_LENGTH:-}")
ACTUAL_MAX_SYMBOL_LENGTH=$(cast call "$LAUNCH_ADDRESS" "MAX_TOKEN_SYMBOL_LENGTH()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
ACTUAL_MAX_SYMBOL_LENGTH=$(normalize_output "$ACTUAL_MAX_SYMBOL_LENGTH")
ACTUAL_TEST_PREFIX_BYTES=$(cast call "$LAUNCH_ADDRESS" "TEST_PREFIX_BYTES()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
ACTUAL_TEST_PREFIX_BYTES=$(normalize_output "$ACTUAL_TEST_PREFIX_BYTES")
if [[ ! "$ACTUAL_MAX_SYMBOL_LENGTH" =~ ^[0-9]+$ ]] || [[ ! "$ACTUAL_TEST_PREFIX_BYTES" =~ ^[0-9]+$ ]]; then
    echo -e "  ${RED}✗${NC} Failed to read MAX_TOKEN_SYMBOL_LENGTH / TEST_PREFIX_BYTES from $LAUNCH_ADDRESS"
    ((FAILED+=1))
elif [[ ! "$ACTUAL_SYMBOL_LENGTH" =~ ^[0-9]+$ ]]; then
    # A failed TOKEN_SYMBOL_LENGTH read is already counted by verify_value above; counting it here
    # too would report one failure twice.
    :
elif [ "$((ACTUAL_SYMBOL_LENGTH + ACTUAL_TEST_PREFIX_BYTES))" -gt "$ACTUAL_MAX_SYMBOL_LENGTH" ]; then
    echo -e "  ${RED}✗${NC} TOKEN_SYMBOL_LENGTH + TEST_PREFIX_BYTES exceeds MAX_TOKEN_SYMBOL_LENGTH (${ACTUAL_SYMBOL_LENGTH} + ${ACTUAL_TEST_PREFIX_BYTES} > ${ACTUAL_MAX_SYMBOL_LENGTH})"
    ((FAILED+=1))
else
    echo -e "  ${GREEN}✓${NC} TOKEN_SYMBOL_LENGTH + TEST_PREFIX_BYTES <= MAX_TOKEN_SYMBOL_LENGTH ($((ACTUAL_SYMBOL_LENGTH + ACTUAL_TEST_PREFIX_BYTES)) <= ${ACTUAL_MAX_SYMBOL_LENGTH})"
fi
ACTUAL_LAUNCH_AMOUNT=$(cast call "$LAUNCH_ADDRESS" "LAUNCH_AMOUNT()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "LAUNCH_AMOUNT" "$LAUNCH_AMOUNT" "$ACTUAL_LAUNCH_AMOUNT" || ((FAILED+=1))
ACTUAL_LAUNCH_MAX_SUPPLY=$(cast call "$LAUNCH_ADDRESS" "MAX_SUPPLY()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "MAX_SUPPLY" "$MAX_SUPPLY" "$ACTUAL_LAUNCH_MAX_SUPPLY" || ((FAILED+=1))
ACTUAL_REGISTERED=$(cast call "$LAUNCH_ADDRESS" "isLOVE20Token(address)(bool)" "$LOVE20_TOKEN_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "first token registered" "true" "$ACTUAL_REGISTERED" || ((FAILED+=1))
ACTUAL_FIRST_TOKEN=$(cast call "$LAUNCH_ADDRESS" "FIRST_TOKEN_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "FIRST_TOKEN_ADDRESS" "$LOVE20_TOKEN_ADDRESS" "$ACTUAL_FIRST_TOKEN" || ((FAILED+=1))

ACTUAL_SYMBOL_TOKEN=$(cast call "$LAUNCH_ADDRESS" "tokenAddressBySymbol(string)(address)" "$TOKEN_SYMBOL" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "tokenAddressBySymbol" "$LOVE20_TOKEN_ADDRESS" "$ACTUAL_SYMBOL_TOKEN" || ((FAILED+=1))

ACTUAL_FIRST_PARENT=$(cast call "$LAUNCH_ADDRESS" "parentToken(address)(address)" "$LOVE20_TOKEN_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "first token parent" "$ROUTER_WETH" "$ACTUAL_FIRST_PARENT" || ((FAILED+=1))

ACTUAL_FIRST_PAIR=$(cast call "$FACTORY_ADDRESS" "getPair(address,address)(address)" "$LOVE20_TOKEN_ADDRESS" "$ROUTER_WETH" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
if [[ "$ACTUAL_FIRST_PAIR" == "ERROR" || "$ACTUAL_FIRST_PAIR" == "0x0000000000000000000000000000000000000000" ]]; then
    echo -e "  ${RED}✗${NC} first token pair missing (${ACTUAL_FIRST_PAIR})"
    ((FAILED+=1))
else
    echo -e "  ${GREEN}✓${NC} first token pair ${ACTUAL_FIRST_PAIR}"
fi

# 5. Mint.
print_contract_header "5" "Mint" "$MINT_ADDRESS"
verify_deployed "Mint" "$MINT_ADDRESS" || ((FAILED+=1))

ACTUAL_MINT_VOTE=$(cast call "$MINT_ADDRESS" "VOTE_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "VOTE_ADDRESS" "$VOTE_ADDRESS" "$ACTUAL_MINT_VOTE" || ((FAILED+=1))

ACTUAL_MINT_SUBMIT=$(cast call "$MINT_ADDRESS" "SUBMIT_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "SUBMIT_ADDRESS" "$SUBMIT_ADDRESS" "$ACTUAL_MINT_SUBMIT" || ((FAILED+=1))

ACTUAL_MINT_LAUNCH=$(cast call "$MINT_ADDRESS" "LAUNCH_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "LAUNCH_ADDRESS" "$LAUNCH_ADDRESS" "$ACTUAL_MINT_LAUNCH" || ((FAILED+=1))

ACTUAL_MINT_MEMBER=$(cast call "$MINT_ADDRESS" "MEMBER_NFT_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "MEMBER_NFT_ADDRESS" "$MEMBER_NFT_ADDRESS" "$ACTUAL_MINT_MEMBER" || ((FAILED+=1))

ACTUAL_MINT_PHASE=$(cast call "$MINT_ADDRESS" "PHASE_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "PHASE_ADDRESS" "$PHASE_ADDRESS" "$ACTUAL_MINT_PHASE" || ((FAILED+=1))

ACTUAL_MIN_PROPOSAL=$(cast call "$MINT_ADDRESS" "PROPOSAL_REWARD_MIN_VOTE_RATIO()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "PROPOSAL_REWARD_MIN_VOTE_RATIO" "$PROPOSAL_REWARD_MIN_VOTE_RATIO" "$ACTUAL_MIN_PROPOSAL" || ((FAILED+=1))

ACTUAL_GOV_REWARD=$(cast call "$MINT_ADDRESS" "ROUND_REWARD_GOV_RATIO()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "ROUND_REWARD_GOV_RATIO" "$ROUND_REWARD_GOV_RATIO" "$ACTUAL_GOV_REWARD" || ((FAILED+=1))

ACTUAL_PROPOSAL_REWARD=$(cast call "$MINT_ADDRESS" "ROUND_REWARD_PROPOSAL_RATIO()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "ROUND_REWARD_PROPOSAL_RATIO" "$ROUND_REWARD_PROPOSAL_RATIO" "$ACTUAL_PROPOSAL_REWARD" || ((FAILED+=1))

# 6. Stake.
print_contract_header "6" "Stake" "$STAKE_ADDRESS"
verify_deployed "Stake" "$STAKE_ADDRESS" || ((FAILED+=1))

ACTUAL_STAKE_PHASE=$(cast call "$STAKE_ADDRESS" "PHASE_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "PHASE_ADDRESS" "$PHASE_ADDRESS" "$ACTUAL_STAKE_PHASE" || ((FAILED+=1))

ACTUAL_STAKE_MEMBER=$(cast call "$STAKE_ADDRESS" "MEMBER_NFT_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "MEMBER_NFT_ADDRESS" "$MEMBER_NFT_ADDRESS" "$ACTUAL_STAKE_MEMBER" || ((FAILED+=1))

ACTUAL_STAKE_VOTE=$(cast call "$STAKE_ADDRESS" "VOTE_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "VOTE_ADDRESS" "$VOTE_ADDRESS" "$ACTUAL_STAKE_VOTE" || ((FAILED+=1))

ACTUAL_STAKE_LAUNCH=$(cast call "$STAKE_ADDRESS" "LAUNCH_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "LAUNCH_ADDRESS" "$LAUNCH_ADDRESS" "$ACTUAL_STAKE_LAUNCH" || ((FAILED+=1))

ACTUAL_ROUTER=$(cast call "$STAKE_ADDRESS" "ROUTER_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "ROUTER_ADDRESS" "$ROUTER_ADDRESS" "$ACTUAL_ROUTER" || ((FAILED+=1))

ACTUAL_FACTORY=$(cast call "$STAKE_ADDRESS" "PAIR_FACTORY_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "PAIR_FACTORY_ADDRESS" "$FACTORY_ADDRESS" "$ACTUAL_FACTORY" || ((FAILED+=1))

ACTUAL_WAITING_MIN=$(cast call "$STAKE_ADDRESS" "PROMISED_WAITING_PHASES_MIN()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "PROMISED_WAITING_PHASES_MIN" "$PROMISED_WAITING_PHASES_MIN" "$ACTUAL_WAITING_MIN" || ((FAILED+=1))

ACTUAL_WAITING_MAX=$(cast call "$STAKE_ADDRESS" "PROMISED_WAITING_PHASES_MAX()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "PROMISED_WAITING_PHASES_MAX" "$PROMISED_WAITING_PHASES_MAX" "$ACTUAL_WAITING_MAX" || ((FAILED+=1))

ACTUAL_FEE_RATIO=$(cast call "$STAKE_ADDRESS" "FEE_SETTLEMENT_RATIO()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "FEE_SETTLEMENT_RATIO" "$FEE_SETTLEMENT_RATIO" "$ACTUAL_FEE_RATIO" || ((FAILED+=1))

ACTUAL_BOOST_SUPPLY_FACTOR=$(cast call "$STAKE_ADDRESS" "BOOST_STAKE_SUPPLY_FACTOR()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "BOOST_STAKE_SUPPLY_FACTOR" "$BOOST_STAKE_SUPPLY_FACTOR" "$ACTUAL_BOOST_SUPPLY_FACTOR" || ((FAILED+=1))

ACTUAL_BOOST_MULTIPLIER=$(cast call "$STAKE_ADDRESS" "BOOST_STAKE_MULTIPLIER()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "BOOST_STAKE_MULTIPLIER" "$BOOST_STAKE_MULTIPLIER" "$ACTUAL_BOOST_MULTIPLIER" || ((FAILED+=1))

ACTUAL_LIQUIDITY_EQUIVALENCE=$(cast call "$STAKE_ADDRESS" "LIQUIDITY_TOKEN_EQUIVALENCE_FACTOR()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "LIQUIDITY_TOKEN_EQUIVALENCE_FACTOR" "2" "$ACTUAL_LIQUIDITY_EQUIVALENCE" || ((FAILED+=1))

# 7. Submit.
print_contract_header "7" "Submit" "$SUBMIT_ADDRESS"
verify_deployed "Submit" "$SUBMIT_ADDRESS" || ((FAILED+=1))

ACTUAL_SUBMIT_PHASE=$(cast call "$SUBMIT_ADDRESS" "PHASE_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "PHASE_ADDRESS" "$PHASE_ADDRESS" "$ACTUAL_SUBMIT_PHASE" || ((FAILED+=1))

ACTUAL_SUBMIT_STAKE=$(cast call "$SUBMIT_ADDRESS" "STAKE_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "STAKE_ADDRESS" "$STAKE_ADDRESS" "$ACTUAL_SUBMIT_STAKE" || ((FAILED+=1))

ACTUAL_SUBMIT_MEMBER=$(cast call "$SUBMIT_ADDRESS" "MEMBER_NFT_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "MEMBER_NFT_ADDRESS" "$MEMBER_NFT_ADDRESS" "$ACTUAL_SUBMIT_MEMBER" || ((FAILED+=1))

ACTUAL_MIN_RATIO=$(cast call "$SUBMIT_ADDRESS" "SUBMIT_MIN_RATIO()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "SUBMIT_MIN_RATIO" "$SUBMIT_MIN_RATIO" "$ACTUAL_MIN_RATIO" || ((FAILED+=1))

# 8. Vote.
print_contract_header "8" "Vote" "$VOTE_ADDRESS"
verify_deployed "Vote" "$VOTE_ADDRESS" || ((FAILED+=1))

ACTUAL_VOTE_STAKE=$(cast call "$VOTE_ADDRESS" "STAKE_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "STAKE_ADDRESS" "$STAKE_ADDRESS" "$ACTUAL_VOTE_STAKE" || ((FAILED+=1))

ACTUAL_VOTE_SUBMIT=$(cast call "$VOTE_ADDRESS" "SUBMIT_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "SUBMIT_ADDRESS" "$SUBMIT_ADDRESS" "$ACTUAL_VOTE_SUBMIT" || ((FAILED+=1))

ACTUAL_VOTE_PHASE=$(cast call "$VOTE_ADDRESS" "PHASE_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "PHASE_ADDRESS" "$PHASE_ADDRESS" "$ACTUAL_VOTE_PHASE" || ((FAILED+=1))

ACTUAL_VOTE_MEMBER=$(cast call "$VOTE_ADDRESS" "MEMBER_NFT_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "MEMBER_NFT_ADDRESS" "$MEMBER_NFT_ADDRESS" "$ACTUAL_VOTE_MEMBER" || ((FAILED+=1))

# 9. AirdropDistributor.
print_contract_header "9" "AirdropDistributor" "$AIRDROP_DISTRIBUTOR_ADDRESS"
verify_deployed "AirdropDistributor" "$AIRDROP_DISTRIBUTOR_ADDRESS" || ((FAILED+=1))

ACTUAL_AIRDROP_LAUNCH=$(cast call "$AIRDROP_DISTRIBUTOR_ADDRESS" "LAUNCH_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "LAUNCH_ADDRESS" "$LAUNCH_ADDRESS" "$ACTUAL_AIRDROP_LAUNCH" || ((FAILED+=1))

ACTUAL_AIRDROP_PHASE=$(cast call "$AIRDROP_DISTRIBUTOR_ADDRESS" "PHASE_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "PHASE_ADDRESS" "$PHASE_ADDRESS" "$ACTUAL_AIRDROP_PHASE" || ((FAILED+=1))

# The genesis token's initial supply is minted to this distributor and stays there until claimants
# withdraw it, so the token balance check in section 1 already binds token and distributor together.
ACTUAL_TOTAL_SHARE=$(cast call "$AIRDROP_DISTRIBUTOR_ADDRESS" "TOTAL_SHARE()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "TOTAL_SHARE" "1000000000000000000" "$ACTUAL_TOTAL_SHARE" || ((FAILED+=1))

ACTUAL_MAX_CLAIM_DELAY=$(cast call "$AIRDROP_DISTRIBUTOR_ADDRESS" "MAX_CLAIM_DELAY_ROUNDS()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "MAX_CLAIM_DELAY_ROUNDS" "1000" "$ACTUAL_MAX_CLAIM_DELAY" || ((FAILED+=1))

# One tuple read covers every per-token field. `cast call --json` is required here: without it cast
# prints the already-decoded human string `(0x…, 0x…, 2, …)`, which `cast abi-decode` then rejects
# with "invalid character '('" and every field silently becomes null. With `--json` the result is a
# nested array (`[[field0, field1, …]]`) whose elements are plain strings, so `jq` can read them
# safely — and stays correct when snapshotUri contains commas or quotes, which a plain comma split
# would get wrong. Field order matches AirdropInfo: tokenAddress, merkleRoot, claimableFromRound,
# totalClaimedShare, totalRemainingShare, totalClaimedAmount, remainingAmount, snapshotUri.
AIRDROP_INFO_SIG="airdropInfo(address)((address,bytes32,uint256,uint256,uint256,uint256,uint256,string))"
AIRDROP_INFO_JSON=$(cast call "$AIRDROP_DISTRIBUTOR_ADDRESS" "$AIRDROP_INFO_SIG" "$LOVE20_TOKEN_ADDRESS" \
    --rpc-url "$RPC_URL" --json 2>/dev/null || echo "ERROR")
airdrop_field() {
    # A failed or reverted call leaves AIRDROP_INFO_JSON as the bare word ERROR; jq would then fail
    # with a parse error, so report ERROR explicitly instead of letting the field become empty.
    if [ "$AIRDROP_INFO_JSON" = "ERROR" ]; then
        echo "ERROR"
        return 0
    fi
    printf '%s' "$AIRDROP_INFO_JSON" | jq -r ".[0][$1] // \"ERROR\"" 2>/dev/null || echo "ERROR"
}
ACTUAL_GENESIS_ROOT=$(airdrop_field 1)
ACTUAL_CLAIMED_SHARE=$(airdrop_field 3)
ACTUAL_REMAINING_SHARE=$(airdrop_field 4)
ACTUAL_CLAIMED_AMOUNT=$(airdrop_field 5)
ACTUAL_REMAINING_AMOUNT=$(airdrop_field 6)

verify_value "genesis merkle root" "$GENESIS_AIRDROP_MERKLE_ROOT" "$ACTUAL_GENESIS_ROOT" || ((FAILED+=1))

# claimedShare is 0 only while nobody has claimed the genesis token: this step is an idempotent
# read-only check of the deployment, not a timeless invariant.
verify_value "genesis claimed share" "0" "$ACTUAL_CLAIMED_SHARE" || ((FAILED+=1))

verify_value "genesis remaining share" "1000000000000000000" "$ACTUAL_REMAINING_SHARE" || ((FAILED+=1))

# AirdropDistributor records `max(round at its deployment block, 1) + delay` at construction time and
# never updates it, so the expected value must NOT be recomputed from the current round: once Phase
# advances past the deployment round this script would compare a stored past value against a moving
# expectation and report a false failure on every re-run. The exact equality is asserted at deploy
# time by `DeployCore._validateDeployment`, which reads the round in the same block. Here the check is
# time-invariant: the base round was a real past-or-current round and never below the clamp floor.
ACTUAL_CLAIMABLE_FROM=$(airdrop_field 2)
ACTUAL_CLAIMABLE_FROM=$(normalize_output "$ACTUAL_CLAIMABLE_FROM")
ACTUAL_CURRENT_PHASE=$(cast call "$PHASE_ADDRESS" "currentPhase()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
ACTUAL_CURRENT_PHASE=$(normalize_output "$ACTUAL_CURRENT_PHASE")
# 18 digits is below the signed 64-bit limit, so the arithmetic below cannot wrap; a longer value or
# a failed read is reported instead of producing a bogus expected round.
if [[ ! "$ACTUAL_CLAIMABLE_FROM" =~ ^[0-9]{1,18}$ ]] || [[ ! "$ACTUAL_CURRENT_PHASE" =~ ^[0-9]{1,18}$ ]]; then
    echo -e "  ${RED}✗${NC} Failed to read genesis claimable round / currentPhase (${ACTUAL_CLAIMABLE_FROM} / ${ACTUAL_CURRENT_PHASE})"
    ((FAILED+=1))
else
    # While Phase has not started, the clamp makes the stored value exactly `1 + delay`.
    current_base_round=$ACTUAL_CURRENT_PHASE
    if [ "$current_base_round" -eq 0 ]; then
        current_base_round=1
    fi
    min_claimable_from=$((1 + GENESIS_AIRDROP_CLAIM_DELAY_ROUNDS))
    max_claimable_from=$((current_base_round + GENESIS_AIRDROP_CLAIM_DELAY_ROUNDS))
    if [ "$ACTUAL_CLAIMABLE_FROM" -lt "$min_claimable_from" ] || [ "$ACTUAL_CLAIMABLE_FROM" -gt "$max_claimable_from" ]; then
        echo -e "  ${RED}✗${NC} genesis claimable round out of range: expected ${min_claimable_from}..${max_claimable_from}, got ${ACTUAL_CLAIMABLE_FROM}"
        ((FAILED+=1))
    else
        echo -e "  ${GREEN}✓${NC} genesis claimable round: ${ACTUAL_CLAIMABLE_FROM} (within ${min_claimable_from}..${max_claimable_from})"
    fi
fi

# ========================================
# Boundary value checks (safety).
# ========================================
echo ""
echo -e "${CYAN}─────────────────────────────────────────${NC}"
echo -e "${BLUE}Boundary Value Checks${NC}"
echo -e "${CYAN}─────────────────────────────────────────${NC}"

# Compare two non-negative decimal integer strings: -1 / 0 / 1. Bash arithmetic is 64-bit only and
# supply reaches 1e28, so compare digit strings; equal-length decimal strings sort like numbers,
# which makes the digit-by-digit comparison exact.
decimal_cmp() {
    local a b
    a=$(normalize_output "$1" | sed -E 's/^0+//')
    b=$(normalize_output "$2" | sed -E 's/^0+//')
    a=${a:-0}
    b=${b:-0}
    if [[ ! "$a" =~ ^[0-9]+$ || ! "$b" =~ ^[0-9]+$ ]]; then
        echo 2
        return 0
    fi
    if [ "${#a}" -ne "${#b}" ]; then
        [ "${#a}" -lt "${#b}" ] && echo -1 || echo 1
    elif [[ "$a" < "$b" ]]; then
        echo -1
    elif [[ "$a" > "$b" ]]; then
        echo 1
    else
        echo 0
    fi
}

# Helper: verify an upper bound.
verify_boundary() {
    local field_name=$1
    local actual=$2
    local max_value=$3

    actual=$(normalize_output "$actual")

    if [[ ! "$actual" =~ ^[0-9]+$ || ! "$max_value" =~ ^[0-9]+$ ]]; then
        echo -e "  ${RED}✗${NC} ${field_name}: Failed to read value"
        return 1
    fi

    if [ "$(decimal_cmp "$actual" "$max_value")" -le 0 ]; then
        echo -e "  ${GREEN}✓${NC} ${field_name} <= $max_value (actual: $actual)"
        return 0
    else
        echo -e "  ${RED}✗${NC} ${field_name} > $max_value (actual: $actual)"
        return 1
    fi
}

verify_positive() {
    local field_name=$1
    local actual
    actual=$(normalize_output "$2")

    if [[ ! "$actual" =~ ^[0-9]+$ ]] || [ "$(decimal_cmp "$actual" 0)" -eq 0 ]; then
        echo -e "  ${RED}✗${NC} ${field_name} must be positive (actual: $actual)"
        return 1
    fi
    echo -e "  ${GREEN}✓${NC} ${field_name} is positive (actual: $actual)"
    return 0
}

# 1. PROPOSAL_REWARD_MIN_VOTE_RATIO <= 1e18.
echo -e "${GRAY}Checking PROPOSAL_REWARD_MIN_VOTE_RATIO...${NC}"
verify_boundary "PROPOSAL_REWARD_MIN_VOTE_RATIO" "$ACTUAL_MIN_PROPOSAL" "1000000000000000000" || ((FAILED+=1))

# 2. LAUNCH_COUNT_THRESHOLD_RATIO <= 1e18 and nonzero.
echo -e "${GRAY}Checking LAUNCH_COUNT_THRESHOLD_RATIO...${NC}"
verify_boundary "LAUNCH_COUNT_THRESHOLD_RATIO" "$ACTUAL_LAUNCH_COUNT_THRESHOLD_RATIO" "1000000000000000000" || ((FAILED+=1))
verify_positive "LAUNCH_COUNT_THRESHOLD_RATIO" "$ACTUAL_LAUNCH_COUNT_THRESHOLD_RATIO" || ((FAILED+=1))

# 3. Every deployment-static parameter is nonzero and within range.
echo -e "${GRAY}Checking deployment-static bounds...${NC}"
for pair in \
    "MEMBER_BASE_DIVISOR:$ACTUAL_BASE_DIVISOR" \
    "MEMBER_BYTES_THRESHOLD:$ACTUAL_BYTES_THRESHOLD" \
    "MEMBER_MULTIPLIER:$ACTUAL_MULTIPLIER" \
    "MEMBER_MAX_NAME_LENGTH:$ACTUAL_MAX_NAME_LENGTH" \
    "PHASE_ORIGIN_BLOCKS:$ACTUAL_ORIGIN_BLOCKS" \
    "PHASE_ORIGIN_PHASE_BLOCKS:$ACTUAL_ORIGIN_PHASE_BLOCKS" \
    "PHASE_TARGET_SECONDS:$ACTUAL_TARGET_SECONDS" \
    "PHASE_ADJUST_THRESHOLD:$ACTUAL_ADJUST_THRESHOLD" \
    "PHASE_SYNC_OBSERVATION_LIMIT:$ACTUAL_OBSERVATION_LIMIT" \
    "MAX_LAUNCH_COUNT:$ACTUAL_MAX_LAUNCH_COUNT" \
    "TOKEN_SYMBOL_LENGTH:$ACTUAL_SYMBOL_LENGTH" \
    "LAUNCH_AMOUNT:$ACTUAL_LAUNCH_AMOUNT" \
    "SUBMIT_MIN_RATIO:$ACTUAL_MIN_RATIO" \
    "PROMISED_WAITING_PHASES_MIN:$ACTUAL_WAITING_MIN" \
    "BOOST_STAKE_SUPPLY_FACTOR:$ACTUAL_BOOST_SUPPLY_FACTOR" \
    "BOOST_STAKE_MULTIPLIER:$ACTUAL_BOOST_MULTIPLIER" \
    "FEE_SETTLEMENT_RATIO:$ACTUAL_FEE_RATIO" \
    "GENESIS_AIRDROP_CLAIM_DELAY_ROUNDS:$GENESIS_AIRDROP_CLAIM_DELAY_ROUNDS"; do
    verify_positive "${pair%%:*}" "${pair#*:}" || ((FAILED+=1))
done

verify_boundary "PHASE_ADJUST_THRESHOLD" "$ACTUAL_ADJUST_THRESHOLD" "1000000000000000000" || ((FAILED+=1))
verify_boundary "SUBMIT_MIN_RATIO" "$ACTUAL_MIN_RATIO" "1000000000000000000" || ((FAILED+=1))
# LAUNCH_AMOUNT >= TOTAL_SHARE is what lets AirdropDistributor skip an amount == 0 check on claim:
# with share >= 1 and remainingShare <= 1e18, floor(balance * share / remainingShare) >= 1.
if [ "$(decimal_cmp "$ACTUAL_LAUNCH_AMOUNT" "$ACTUAL_TOTAL_SHARE")" -lt 0 ]; then
    echo -e "  ${RED}✗${NC} LAUNCH_AMOUNT < TOTAL_SHARE ($ACTUAL_LAUNCH_AMOUNT < $ACTUAL_TOTAL_SHARE)"
    ((FAILED+=1))
else
    echo -e "  ${GREEN}✓${NC} LAUNCH_AMOUNT >= TOTAL_SHARE ($ACTUAL_LAUNCH_AMOUNT >= $ACTUAL_TOTAL_SHARE)"
fi
# Upper bound mirrors MAX_FEE_SETTLEMENT_RATIO in DeployCore.s.sol: 0.25%, below the pool fee.
verify_boundary "FEE_SETTLEMENT_RATIO" "$ACTUAL_FEE_RATIO" "2500000000000000" || ((FAILED+=1))

# Add two non-negative decimal integer strings; digit by digit to avoid 64-bit overflow.
decimal_add() {
    local a b i digit carry=0 out=""
    a=$(normalize_output "$1" | sed -E 's/^0+//')
    b=$(normalize_output "$2" | sed -E 's/^0+//')
    a=${a:-0}
    b=${b:-0}
    if [[ ! "$a" =~ ^[0-9]+$ || ! "$b" =~ ^[0-9]+$ ]]; then
        echo "ERROR"
        return 0
    fi
    while [ "${#a}" -lt "${#b}" ]; do a="0$a"; done
    while [ "${#b}" -lt "${#a}" ]; do b="0$b"; done
    for ((i = ${#a} - 1; i >= 0; i--)); do
        digit=$(( ${a:i:1} + ${b:i:1} + carry ))
        carry=$(( digit / 10 ))
        out="$(( digit % 10 ))${out}"
    done
    [ "$carry" -ne 0 ] && out="${carry}${out}"
    echo "$out"
}

# totalClaimedAmount + remainingAmount == the genesis supply. Both sides are read from chain, so the
# identity holds after the first claim lands too; the supply itself is LAUNCH_AMOUNT because the
# genesis token's whole first supply is minted to this distributor. Sum with decimal_add: LAUNCH_AMOUNT
# is 1e27, well beyond bash's signed 64-bit range.
genesis_supply_sum=$(decimal_add "$ACTUAL_CLAIMED_AMOUNT" "$ACTUAL_REMAINING_AMOUNT")
if [ "$(decimal_cmp "$genesis_supply_sum" "$LAUNCH_AMOUNT")" -eq 0 ]; then
    echo -e "  ${GREEN}✓${NC} genesis supply conservation ($ACTUAL_CLAIMED_AMOUNT + $ACTUAL_REMAINING_AMOUNT == $LAUNCH_AMOUNT)"
else
    echo -e "  ${RED}✗${NC} genesis supply conservation failed: $ACTUAL_CLAIMED_AMOUNT + $ACTUAL_REMAINING_AMOUNT != $LAUNCH_AMOUNT"
    ((FAILED+=1))
fi

if [ "$(decimal_cmp "$ACTUAL_LAUNCH_AMOUNT" "$ACTUAL_LAUNCH_MAX_SUPPLY")" -gt 0 ]; then
    echo -e "  ${RED}✗${NC} LAUNCH_AMOUNT > MAX_SUPPLY"
    ((FAILED+=1))
else
    echo -e "  ${GREEN}✓${NC} LAUNCH_AMOUNT <= MAX_SUPPLY"
fi
round_reward_sum=$(decimal_add "$ACTUAL_GOV_REWARD" "$ACTUAL_PROPOSAL_REWARD")
if [ "$(decimal_cmp "$round_reward_sum" 1000000000000000000)" -gt 0 ]; then
    echo -e "  ${RED}✗${NC} ROUND_REWARD_GOV_RATIO + ROUND_REWARD_PROPOSAL_RATIO > 1e18"
    ((FAILED+=1))
else
    echo -e "  ${GREEN}✓${NC} round reward ratios <= 1e18"
fi
if [ "$(decimal_cmp "$ACTUAL_WAITING_MIN" "$ACTUAL_WAITING_MAX")" -gt 0 ]; then
    echo -e "  ${RED}✗${NC} PROMISED_WAITING_PHASES_MIN > MAX"
    ((FAILED+=1))
else
    echo -e "  ${GREEN}✓${NC} PROMISED_WAITING_PHASES range is valid"
fi
if [ -z "${TOKEN_NAME:-}" ] || [ -z "${TOKEN_SYMBOL:-}" ] || [ "$AIRDROP_DISTRIBUTOR_ADDRESS" = "0x0000000000000000000000000000000000000000" ]; then
    echo -e "  ${RED}✗${NC} TOKEN_NAME / TOKEN_SYMBOL / AIRDROP_DISTRIBUTOR_ADDRESS is empty"
    ((FAILED+=1))
else
    echo -e "  ${GREEN}✓${NC} token name, symbol and distributor are set"
fi

# 4. Router / Factory address consistency.
echo -e "${GRAY}Checking Router-Factory consistency...${NC}"
ROUTER_FACTORY=$(cast call "$ACTUAL_ROUTER" "factory()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
if [ "$ROUTER_FACTORY" = "ERROR" ]; then
    echo -e "  ${RED}✗${NC} Router.factory() call failed"
    ((FAILED+=1))
elif verify_value "Router.factory" "$ACTUAL_FACTORY" "$ROUTER_FACTORY"; then
    echo -e "  ${GREEN}✓${NC} Router.factory() == pairFactoryAddress"
else
    echo -e "  ${RED}✗${NC} Router.factory() mismatch"
    echo -e "    Expected: $ACTUAL_FACTORY"
    echo -e "    Got:      $ROUTER_FACTORY"
    ((FAILED+=1))
fi

# 5. The root parent token (Router.WETH()) must itself be a deployed contract.
echo -e "${GRAY}Checking Router WETH...${NC}"
verify_deployed "WETH" "$ROUTER_WETH" || ((FAILED+=1))
verify_deployed "Factory" "$FACTORY_ADDRESS" || ((FAILED+=1))
verify_deployed "Router" "$ROUTER_ADDRESS" || ((FAILED+=1))
verify_value "root parent is router WETH" "$ROUTER_WETH" "$ACTUAL_ROOT_PARENT" || ((FAILED+=1))

echo ""
echo -e "${CYAN}════════════════════════════════════════${NC}"
if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All verifications passed${NC}"
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo ""
else
    echo -e "${RED}✗ $FAILED verification(s) failed${NC}"
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo ""
    exit 1
fi
