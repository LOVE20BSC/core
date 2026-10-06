#!/usr/bin/env bash
set -euo pipefail

# 颜色定义
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

# 检查所有合约地址是否已设置
if [ -z "${LOVE20TOKEN_ADDRESS:-}" ] || [ -z "${MEMBERNFT_ADDRESS:-}" ] || \
   [ -z "${PHASE_ADDRESS:-}" ] || [ -z "${LAUNCH_ADDRESS:-}" ] || \
   [ -z "${MINT_ADDRESS:-}" ] || [ -z "${STAKE_ADDRESS:-}" ] || \
   [ -z "${SUBMIT_ADDRESS:-}" ] || [ -z "${VOTE_ADDRESS:-}" ]; then
    echo -e "${RED}✗ Error: Not all contract addresses are set${NC}"
    exit 1
fi

# 辅助函数：标准化输出（去掉引号和科学计数法标记）
normalize_output() {
    local value="$1"
    # 去掉首尾引号
    value="${value%\"}"
    value="${value#\"}"
    # 去掉科学计数法标记 [1e18]
    value="${value% \[*\]}"
    echo "$value"
}

# 辅助函数：验证单个值
verify_value() {
    local field_name=$1
    local expected=$2
    local actual=$3

    # 标准化两个值
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

# 辅助函数：验证合约是否部署
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

# 辅助函数：打印合约头部
print_contract_header() {
    local num=$1
    local name=$2
    local address=$3
    echo ""
    echo -e "${BLUE}[$num/8]${NC} ${CYAN}${name}${NC}"
    echo -e "${GRAY}      ${address}${NC}"
}

FAILED=0
ACTUAL_CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
verify_value "CHAIN_ID" "$CHAIN_ID" "$ACTUAL_CHAIN_ID" || exit 1

# 1. 验证 LOVE20Token
print_contract_header "1" "LOVE20Token" "$LOVE20TOKEN_ADDRESS"
verify_deployed "LOVE20Token" "$LOVE20TOKEN_ADDRESS" || ((FAILED+=1))

ACTUAL_NAME=$(cast call "$LOVE20TOKEN_ADDRESS" "name()(string)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "name" "$TOKEN_NAME" "$ACTUAL_NAME" || ((FAILED+=1))

ACTUAL_SYMBOL=$(cast call "$LOVE20TOKEN_ADDRESS" "symbol()(string)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "symbol" "$TOKEN_SYMBOL" "$ACTUAL_SYMBOL" || ((FAILED+=1))

ACTUAL_MAX_SUPPLY=$(cast call "$LOVE20TOKEN_ADDRESS" "maxSupply()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "maxSupply" "$MAX_SUPPLY" "$ACTUAL_MAX_SUPPLY" || ((FAILED+=1))

ACTUAL_MINTER=$(cast call "$LOVE20TOKEN_ADDRESS" "minter()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "minter" "$MINT_ADDRESS" "$ACTUAL_MINTER" || ((FAILED+=1))

ACTUAL_PARENT=$(cast call "$LOVE20TOKEN_ADDRESS" "parentTokenAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "parentTokenAddress" "$PARENT_TOKEN" "$ACTUAL_PARENT" || ((FAILED+=1))

# 2. 验证 MemberNFT
print_contract_header "2" "MemberNFT" "$MEMBERNFT_ADDRESS"
verify_deployed "MemberNFT" "$MEMBERNFT_ADDRESS" || ((FAILED+=1))

ACTUAL_BASE_DIVISOR=$(cast call "$MEMBERNFT_ADDRESS" "BASE_DIVISOR()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "BASE_DIVISOR" "$MEMBER_BASE_DIVISOR" "$ACTUAL_BASE_DIVISOR" || ((FAILED+=1))

ACTUAL_BYTES_THRESHOLD=$(cast call "$MEMBERNFT_ADDRESS" "BYTES_THRESHOLD()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "BYTES_THRESHOLD" "$MEMBER_BYTES_THRESHOLD" "$ACTUAL_BYTES_THRESHOLD" || ((FAILED+=1))

ACTUAL_MULTIPLIER=$(cast call "$MEMBERNFT_ADDRESS" "MULTIPLIER()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "MULTIPLIER" "$MEMBER_MULTIPLIER" "$ACTUAL_MULTIPLIER" || ((FAILED+=1))

ACTUAL_MAX_NAME_LENGTH=$(cast call "$MEMBERNFT_ADDRESS" "MAX_NAME_LENGTH()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "MAX_NAME_LENGTH" "$MEMBER_MAX_NAME_LENGTH" "$ACTUAL_MAX_NAME_LENGTH" || ((FAILED+=1))

ACTUAL_TOKEN=$(cast call "$MEMBERNFT_ADDRESS" "LOVE20_TOKEN_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "LOVE20_TOKEN_ADDRESS" "$LOVE20TOKEN_ADDRESS" "$ACTUAL_TOKEN" || ((FAILED+=1))

ACTUAL_INIT=$(cast call "$MEMBERNFT_ADDRESS" "initialized()(bool)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "initialized" "true" "$ACTUAL_INIT" || ((FAILED+=1))

# 3. 验证 Phase
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

# 4. 验证 Launch
print_contract_header "4" "Launch" "$LAUNCH_ADDRESS"
verify_deployed "Launch" "$LAUNCH_ADDRESS" || ((FAILED+=1))

ACTUAL_LAUNCH_RATIO=$(cast call "$LAUNCH_ADDRESS" "LAUNCH_RATIO()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "LAUNCH_RATIO" "$LAUNCH_RATIO" "$ACTUAL_LAUNCH_RATIO" || ((FAILED+=1))

ACTUAL_MAX_LAUNCH_COUNT=$(cast call "$LAUNCH_ADDRESS" "MAX_LAUNCH_COUNT()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "MAX_LAUNCH_COUNT" "$MAX_LAUNCH_COUNT" "$ACTUAL_MAX_LAUNCH_COUNT" || ((FAILED+=1))

ACTUAL_LAUNCH_MINT=$(cast call "$LAUNCH_ADDRESS" "mintAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "mintAddress" "$MINT_ADDRESS" "$ACTUAL_LAUNCH_MINT" || ((FAILED+=1))

ACTUAL_LAUNCH_MEMBER=$(cast call "$LAUNCH_ADDRESS" "memberNFTAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "memberNFTAddress" "$MEMBERNFT_ADDRESS" "$ACTUAL_LAUNCH_MEMBER" || ((FAILED+=1))

ACTUAL_ROOT_PARENT=$(cast call "$LAUNCH_ADDRESS" "rootParentTokenAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "rootParentTokenAddress" "$PARENT_TOKEN" "$ACTUAL_ROOT_PARENT" || ((FAILED+=1))
ACTUAL_LAUNCH_FACTORY=$(cast call "$LAUNCH_ADDRESS" "pairFactoryAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "pairFactoryAddress" "$FACTORY_ADDRESS" "$ACTUAL_LAUNCH_FACTORY" || ((FAILED+=1))
ACTUAL_SYMBOL_LENGTH=$(cast call "$LAUNCH_ADDRESS" "TOKEN_SYMBOL_LENGTH()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "TOKEN_SYMBOL_LENGTH" "$TOKEN_SYMBOL_LENGTH" "$ACTUAL_SYMBOL_LENGTH" || ((FAILED+=1))
ACTUAL_LAUNCH_AMOUNT=$(cast call "$LAUNCH_ADDRESS" "LAUNCH_AMOUNT()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "LAUNCH_AMOUNT" "$INITIAL_SUPPLY" "$ACTUAL_LAUNCH_AMOUNT" || ((FAILED+=1))
ACTUAL_LAUNCH_MAX_SUPPLY=$(cast call "$LAUNCH_ADDRESS" "MAX_SUPPLY()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "MAX_SUPPLY" "$MAX_SUPPLY" "$ACTUAL_LAUNCH_MAX_SUPPLY" || ((FAILED+=1))
ACTUAL_REGISTERED=$(cast call "$LAUNCH_ADDRESS" "isLOVE20Token(address)(bool)" "$LOVE20TOKEN_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "first token registered" "true" "$ACTUAL_REGISTERED" || ((FAILED+=1))
ACTUAL_FIRST_TOKEN=$(cast call "$LAUNCH_ADDRESS" "firstTokenAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "firstTokenAddress" "$LOVE20TOKEN_ADDRESS" "$ACTUAL_FIRST_TOKEN" || ((FAILED+=1))

ACTUAL_LAUNCH_INIT=$(cast call "$LAUNCH_ADDRESS" "initialized()(bool)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "initialized" "true" "$ACTUAL_LAUNCH_INIT" || ((FAILED+=1))

# 5. 验证 Mint
print_contract_header "5" "Mint" "$MINT_ADDRESS"
verify_deployed "Mint" "$MINT_ADDRESS" || ((FAILED+=1))

ACTUAL_MINT_VOTE=$(cast call "$MINT_ADDRESS" "voteAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "voteAddress" "$VOTE_ADDRESS" "$ACTUAL_MINT_VOTE" || ((FAILED+=1))

ACTUAL_MINT_SUBMIT=$(cast call "$MINT_ADDRESS" "submitAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "submitAddress" "$SUBMIT_ADDRESS" "$ACTUAL_MINT_SUBMIT" || ((FAILED+=1))

ACTUAL_MINT_LAUNCH=$(cast call "$MINT_ADDRESS" "launchAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "launchAddress" "$LAUNCH_ADDRESS" "$ACTUAL_MINT_LAUNCH" || ((FAILED+=1))

ACTUAL_MINT_MEMBER=$(cast call "$MINT_ADDRESS" "memberNFTAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "memberNFTAddress" "$MEMBERNFT_ADDRESS" "$ACTUAL_MINT_MEMBER" || ((FAILED+=1))

ACTUAL_MINT_PHASE=$(cast call "$MINT_ADDRESS" "phaseAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "phaseAddress" "$PHASE_ADDRESS" "$ACTUAL_MINT_PHASE" || ((FAILED+=1))

ACTUAL_MIN_PROPOSAL=$(cast call "$MINT_ADDRESS" "PROPOSAL_REWARD_MIN_VOTE_PER_THOUSAND()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "PROPOSAL_REWARD_MIN_VOTE_PER_THOUSAND" "$MIN_PROPOSAL_VOTES" "$ACTUAL_MIN_PROPOSAL" || ((FAILED+=1))

ACTUAL_GOV_REWARD=$(cast call "$MINT_ADDRESS" "ROUND_REWARD_GOV_PER_THOUSAND()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "ROUND_REWARD_GOV_PER_THOUSAND" "$GOV_REWARD_RATIO" "$ACTUAL_GOV_REWARD" || ((FAILED+=1))

ACTUAL_PROPOSAL_REWARD=$(cast call "$MINT_ADDRESS" "ROUND_REWARD_PROPOSAL_PER_THOUSAND()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "ROUND_REWARD_PROPOSAL_PER_THOUSAND" "$PROPOSAL_REWARD_RATIO" "$ACTUAL_PROPOSAL_REWARD" || ((FAILED+=1))

ACTUAL_MAX_BOOST=$(cast call "$MINT_ADDRESS" "MAX_GOV_BOOST_REWARD_MULTIPLIER()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "MAX_GOV_BOOST_REWARD_MULTIPLIER" "$MAX_BOOST_MULTIPLIER" "$ACTUAL_MAX_BOOST" || ((FAILED+=1))

ACTUAL_MINT_INIT=$(cast call "$MINT_ADDRESS" "initialized()(bool)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "initialized" "true" "$ACTUAL_MINT_INIT" || ((FAILED+=1))

# 6. 验证 Stake
print_contract_header "6" "Stake" "$STAKE_ADDRESS"
verify_deployed "Stake" "$STAKE_ADDRESS" || ((FAILED+=1))

ACTUAL_STAKE_PHASE=$(cast call "$STAKE_ADDRESS" "phaseAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "phaseAddress" "$PHASE_ADDRESS" "$ACTUAL_STAKE_PHASE" || ((FAILED+=1))

ACTUAL_STAKE_MEMBER=$(cast call "$STAKE_ADDRESS" "memberNFTAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "memberNFTAddress" "$MEMBERNFT_ADDRESS" "$ACTUAL_STAKE_MEMBER" || ((FAILED+=1))

ACTUAL_STAKE_VOTE=$(cast call "$STAKE_ADDRESS" "voteAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "voteAddress" "$VOTE_ADDRESS" "$ACTUAL_STAKE_VOTE" || ((FAILED+=1))

ACTUAL_STAKE_LAUNCH=$(cast call "$STAKE_ADDRESS" "launchAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "launchAddress" "$LAUNCH_ADDRESS" "$ACTUAL_STAKE_LAUNCH" || ((FAILED+=1))

ACTUAL_ROUTER=$(cast call "$STAKE_ADDRESS" "routerAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "routerAddress" "$ROUTER_ADDRESS" "$ACTUAL_ROUTER" || ((FAILED+=1))

ACTUAL_FACTORY=$(cast call "$STAKE_ADDRESS" "pairFactoryAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "pairFactoryAddress" "$FACTORY_ADDRESS" "$ACTUAL_FACTORY" || ((FAILED+=1))

ACTUAL_WAITING_MIN=$(cast call "$STAKE_ADDRESS" "PROMISED_WAITING_PHASES_MIN()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "PROMISED_WAITING_PHASES_MIN" "$PROMISED_WAITING_PHASES_MIN" "$ACTUAL_WAITING_MIN" || ((FAILED+=1))

ACTUAL_WAITING_MAX=$(cast call "$STAKE_ADDRESS" "PROMISED_WAITING_PHASES_MAX()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "PROMISED_WAITING_PHASES_MAX" "$PROMISED_WAITING_PHASES_MAX" "$ACTUAL_WAITING_MAX" || ((FAILED+=1))

ACTUAL_FEE_RATIO=$(cast call "$STAKE_ADDRESS" "MAX_WITHDRAWABLE_TO_FEE_RATIO()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "MAX_WITHDRAWABLE_TO_FEE_RATIO" "$MAX_WITHDRAWABLE_TO_FEE_RATIO" "$ACTUAL_FEE_RATIO" || ((FAILED+=1))

ACTUAL_STAKE_INIT=$(cast call "$STAKE_ADDRESS" "initialized()(bool)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "initialized" "true" "$ACTUAL_STAKE_INIT" || ((FAILED+=1))

# 7. 验证 Submit
print_contract_header "7" "Submit" "$SUBMIT_ADDRESS"
verify_deployed "Submit" "$SUBMIT_ADDRESS" || ((FAILED+=1))

ACTUAL_SUBMIT_PHASE=$(cast call "$SUBMIT_ADDRESS" "phaseAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "phaseAddress" "$PHASE_ADDRESS" "$ACTUAL_SUBMIT_PHASE" || ((FAILED+=1))

ACTUAL_SUBMIT_STAKE=$(cast call "$SUBMIT_ADDRESS" "stakeAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "stakeAddress" "$STAKE_ADDRESS" "$ACTUAL_SUBMIT_STAKE" || ((FAILED+=1))

ACTUAL_SUBMIT_MEMBER=$(cast call "$SUBMIT_ADDRESS" "memberNFTAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "memberNFTAddress" "$MEMBERNFT_ADDRESS" "$ACTUAL_SUBMIT_MEMBER" || ((FAILED+=1))

ACTUAL_MIN_PER_THOUSAND=$(cast call "$SUBMIT_ADDRESS" "SUBMIT_MIN_PER_THOUSAND()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "SUBMIT_MIN_PER_THOUSAND" "$SUBMIT_MIN_PER_THOUSAND" "$ACTUAL_MIN_PER_THOUSAND" || ((FAILED+=1))

ACTUAL_SUBMIT_INIT=$(cast call "$SUBMIT_ADDRESS" "initialized()(bool)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "initialized" "true" "$ACTUAL_SUBMIT_INIT" || ((FAILED+=1))

# 8. 验证 Vote
print_contract_header "8" "Vote" "$VOTE_ADDRESS"
verify_deployed "Vote" "$VOTE_ADDRESS" || ((FAILED+=1))

ACTUAL_VOTE_STAKE=$(cast call "$VOTE_ADDRESS" "stakeAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "stakeAddress" "$STAKE_ADDRESS" "$ACTUAL_VOTE_STAKE" || ((FAILED+=1))

ACTUAL_VOTE_SUBMIT=$(cast call "$VOTE_ADDRESS" "submitAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "submitAddress" "$SUBMIT_ADDRESS" "$ACTUAL_VOTE_SUBMIT" || ((FAILED+=1))

ACTUAL_VOTE_PHASE=$(cast call "$VOTE_ADDRESS" "phaseAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "phaseAddress" "$PHASE_ADDRESS" "$ACTUAL_VOTE_PHASE" || ((FAILED+=1))

ACTUAL_VOTE_MEMBER=$(cast call "$VOTE_ADDRESS" "memberNFTAddress()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "memberNFTAddress" "$MEMBERNFT_ADDRESS" "$ACTUAL_VOTE_MEMBER" || ((FAILED+=1))

ACTUAL_VOTE_INIT=$(cast call "$VOTE_ADDRESS" "initialized()(bool)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "initialized" "true" "$ACTUAL_VOTE_INIT" || ((FAILED+=1))

# ========================================
# 边界值验证（安全检查）
# ========================================
echo ""
echo -e "${CYAN}─────────────────────────────────────────${NC}"
echo -e "${BLUE}Boundary Value Checks${NC}"
echo -e "${CYAN}─────────────────────────────────────────${NC}"

# 验证边界值的辅助函数
verify_boundary() {
    local field_name=$1
    local actual=$2
    local max_value=$3

    actual=$(normalize_output "$actual")

    if [[ ! "$actual" =~ ^[0-9]+$ || ! "$max_value" =~ ^[0-9]+$ ]]; then
        echo -e "  ${RED}✗${NC} ${field_name}: Failed to read value"
        return 1
    fi

    # 上限最大为 1e18，在 bash 内建整数范围内；超出 64 位的配置值视为超限，用 2>/dev/null 压掉
    # "integer expression expected" 噪音，判定仍走 else 分支。
    if [ "$actual" -le "$max_value" ] 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} ${field_name} <= $max_value (actual: $actual)"
        return 0
    else
        echo -e "  ${RED}✗${NC} ${field_name} > $max_value (actual: $actual)"
        return 1
    fi
}

# 1. 验证 PROPOSAL_REWARD_MIN_VOTE_PER_THOUSAND <= 1000
echo -e "${GRAY}Checking PROPOSAL_REWARD_MIN_VOTE_PER_THOUSAND...${NC}"
verify_boundary "PROPOSAL_REWARD_MIN_VOTE_PER_THOUSAND" "$ACTUAL_MIN_PROPOSAL" "1000" || ((FAILED+=1))

# 2. 验证 LAUNCH_RATIO <= 1e18
echo -e "${GRAY}Checking LAUNCH_RATIO...${NC}"
verify_boundary "LAUNCH_RATIO" "$ACTUAL_LAUNCH_RATIO" "1000000000000000000" || ((FAILED+=1))

# 3. 验证 Router 和 Factory 的地址一致性
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

# 4. 验证 Router 使用配置中的 WBNB
echo -e "${GRAY}Checking Router WETH...${NC}"
ROUTER_WETH=$(cast call "$ACTUAL_ROUTER" "WETH()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
if [ "$ROUTER_WETH" = "ERROR" ]; then
    echo -e "  ${RED}✗${NC} Router.WETH() call failed"
    ((FAILED+=1))
else
    ROUTER_WETH=$(normalize_output "$ROUTER_WETH")
    verify_value "Router.WETH" "$WBNB_ADDRESS" "$ROUTER_WETH" || ((FAILED+=1))
fi
verify_deployed "WBNB" "$WBNB_ADDRESS" || ((FAILED+=1))
verify_deployed "Factory" "$FACTORY_ADDRESS" || ((FAILED+=1))
verify_deployed "Router" "$ROUTER_ADDRESS" || ((FAILED+=1))
verify_value "root parent is WBNB" "$WBNB_ADDRESS" "$ACTUAL_ROOT_PARENT" || ((FAILED+=1))

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
