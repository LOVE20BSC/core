#!/usr/bin/env bash
set -euo pipefail

# 部署与初始化正确性校验：只读配置与链上状态，可重复运行。自行独立载入校验所需文件，
# 不依赖调用方预载环境：network.params 提供 RPC 与链 ID，dex 的两个模块地址文件提供期望的
# 绑定，core.params 提供期望的部署参数，addresses.core.params 提供待校验的已部署地址。
# 根父币期望值取自链上 Router.WETH()（部署脚本的同源读取），不在配置中重复登记。
# 用法：script/deploy/21_check.sh <network>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

network="${1:?usage: script/deploy/21_check.sh <network>}"
NETWORK_DIR="$PROJECT_ROOT/script/network/$network"

# 参数文件载入器：1e17 / 1_000_000 这类写法在载入时展开为十进制（见 params.sh）。
source "$SCRIPT_DIR/params.sh"

if [ ! -d "$NETWORK_DIR" ]; then
    echo "Error: Network directory not found: $NETWORK_DIR"
    exit 1
fi

# 载入 dex UniswapV2 模块地址文件（FACTORY_ADDRESS / ROUTER_ADDRESS）与 core.params；
# 根父币不配置，期望值取自链上 Router.WETH()，与 DeployCore.s.sol 同源。
for config in network.params addresses.uniswapv2.params core.params addresses.core.params; do
    if [ ! -f "$NETWORK_DIR/$config" ]; then
        echo "Error: Missing required configuration: $NETWORK_DIR/$config"
        exit 1
    fi
done

params_load "$NETWORK_DIR/network.params"
params_load "$NETWORK_DIR/addresses.uniswapv2.params"
params_load "$NETWORK_DIR/core.params"
params_load "$NETWORK_DIR/addresses.core.params"

# 地址文件的键集合必须与期望合约集合一致：键名漏改会让后续变量静默为空，
# 逐项 cast 调用要到很后面才以难以定位的形式失败，故在此显式断言。
address_file="$NETWORK_DIR/addresses.core.params"
expected_keys="LAUNCH_ADDRESS LOVE20_TOKEN_ADDRESS MEMBER_NFT_ADDRESS MINT_ADDRESS PHASE_ADDRESS STAKE_ADDRESS SUBMIT_ADDRESS VOTE_ADDRESS"
actual_keys=$(grep -oE '^[A-Z0-9_]+=' "$address_file" | sed 's/=$//' | sort | tr '\n' ' ' || true)
if [ "$actual_keys" != "$(printf '%s\n' $expected_keys | sort | tr '\n' ' ')" ]; then
    echo "Error: $address_file key set mismatch"
    echo "  expected: $(printf '%s\n' $expected_keys | sort | tr '\n' ' ')"
    echo "  actual:   $actual_keys"
    exit 1
fi

# 根父币期望值：链上 Router.WETH()，与 DeployCore.s.sol 同源。
ROUTER_WETH=$(cast call "$ROUTER_ADDRESS" "WETH()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
if [ "$ROUTER_WETH" = "ERROR" ]; then
    echo "Error: Failed to read WETH() from Router $ROUTER_ADDRESS"
    exit 1
fi

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
if [ -z "${LOVE20_TOKEN_ADDRESS:-}" ] || [ -z "${MEMBER_NFT_ADDRESS:-}" ] || \
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
verify_value "totalSupply" "$INITIAL_SUPPLY" "$ACTUAL_TOTAL_SUPPLY" || ((FAILED+=1))

ACTUAL_DISTRIBUTOR_BALANCE=$(cast call "$LOVE20_TOKEN_ADDRESS" "balanceOf(address)(uint256)" "$DISTRIBUTOR_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "distributor balance" "$INITIAL_SUPPLY" "$ACTUAL_DISTRIBUTOR_BALANCE" || ((FAILED+=1))

ACTUAL_PARENT=$(cast call "$LOVE20_TOKEN_ADDRESS" "PARENT_TOKEN_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "PARENT_TOKEN_ADDRESS" "$ROUTER_WETH" "$ACTUAL_PARENT" || ((FAILED+=1))

# 2. 验证 MemberNFT
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

ACTUAL_INIT=$(cast call "$MEMBER_NFT_ADDRESS" "initialized()(bool)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
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
ACTUAL_LAUNCH_AMOUNT=$(cast call "$LAUNCH_ADDRESS" "LAUNCH_AMOUNT()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "LAUNCH_AMOUNT" "$INITIAL_SUPPLY" "$ACTUAL_LAUNCH_AMOUNT" || ((FAILED+=1))
ACTUAL_LAUNCH_MAX_SUPPLY=$(cast call "$LAUNCH_ADDRESS" "MAX_SUPPLY()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "MAX_SUPPLY" "$MAX_SUPPLY" "$ACTUAL_LAUNCH_MAX_SUPPLY" || ((FAILED+=1))
ACTUAL_REGISTERED=$(cast call "$LAUNCH_ADDRESS" "isLOVE20Token(address)(bool)" "$LOVE20_TOKEN_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "first token registered" "true" "$ACTUAL_REGISTERED" || ((FAILED+=1))
ACTUAL_FIRST_TOKEN=$(cast call "$LAUNCH_ADDRESS" "FIRST_TOKEN_ADDRESS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "FIRST_TOKEN_ADDRESS" "$LOVE20_TOKEN_ADDRESS" "$ACTUAL_FIRST_TOKEN" || ((FAILED+=1))

ACTUAL_LAUNCH_INIT=$(cast call "$LAUNCH_ADDRESS" "initialized()(bool)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "initialized" "true" "$ACTUAL_LAUNCH_INIT" || ((FAILED+=1))

# 5. 验证 Mint
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
verify_value "ROUND_REWARD_GOV_RATIO" "$GOV_REWARD_RATIO" "$ACTUAL_GOV_REWARD" || ((FAILED+=1))

ACTUAL_PROPOSAL_REWARD=$(cast call "$MINT_ADDRESS" "ROUND_REWARD_PROPOSAL_RATIO()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "ROUND_REWARD_PROPOSAL_RATIO" "$PROPOSAL_REWARD_RATIO" "$ACTUAL_PROPOSAL_REWARD" || ((FAILED+=1))

ACTUAL_MAX_BOOST=$(cast call "$MINT_ADDRESS" "MAX_GOV_BOOST_REWARD_MULTIPLIER()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "MAX_GOV_BOOST_REWARD_MULTIPLIER" "$MAX_BOOST_MULTIPLIER" "$ACTUAL_MAX_BOOST" || ((FAILED+=1))

ACTUAL_MINT_INIT=$(cast call "$MINT_ADDRESS" "initialized()(bool)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "initialized" "true" "$ACTUAL_MINT_INIT" || ((FAILED+=1))

# 6. 验证 Stake
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

ACTUAL_STAKE_INIT=$(cast call "$STAKE_ADDRESS" "initialized()(bool)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "initialized" "true" "$ACTUAL_STAKE_INIT" || ((FAILED+=1))

# 7. 验证 Submit
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

ACTUAL_SUBMIT_INIT=$(cast call "$SUBMIT_ADDRESS" "initialized()(bool)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "initialized" "true" "$ACTUAL_SUBMIT_INIT" || ((FAILED+=1))

# 8. 验证 Vote
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

ACTUAL_VOTE_INIT=$(cast call "$VOTE_ADDRESS" "initialized()(bool)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
verify_value "initialized" "true" "$ACTUAL_VOTE_INIT" || ((FAILED+=1))

# ========================================
# 边界值验证（安全检查）
# ========================================
echo ""
echo -e "${CYAN}─────────────────────────────────────────${NC}"
echo -e "${BLUE}Boundary Value Checks${NC}"
echo -e "${CYAN}─────────────────────────────────────────${NC}"

# 比较两个非负十进制整数字符串：输出 -1 / 0 / 1。bash 内建算术只有 64 位，
# 供应量到 1e28，不能先转整数再比；同长度数字串的字典序与数值序一致。
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

# 1. 验证 PROPOSAL_REWARD_MIN_VOTE_RATIO <= 1e18
echo -e "${GRAY}Checking PROPOSAL_REWARD_MIN_VOTE_RATIO...${NC}"
verify_boundary "PROPOSAL_REWARD_MIN_VOTE_RATIO" "$ACTUAL_MIN_PROPOSAL" "1000000000000000000" || ((FAILED+=1))

# 2. 验证 LAUNCH_RATIO <= 1e18 且非零
echo -e "${GRAY}Checking LAUNCH_RATIO...${NC}"
verify_boundary "LAUNCH_RATIO" "$ACTUAL_LAUNCH_RATIO" "1000000000000000000" || ((FAILED+=1))
verify_positive "LAUNCH_RATIO" "$ACTUAL_LAUNCH_RATIO" || ((FAILED+=1))

# 3. 验证全部部署期静态参数非零/范围
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
    "MAX_GOV_BOOST_REWARD_MULTIPLIER:$ACTUAL_MAX_BOOST" \
    "FEE_SETTLEMENT_RATIO:$ACTUAL_FEE_RATIO"; do
    verify_positive "${pair%%:*}" "${pair#*:}" || ((FAILED+=1))
done

verify_boundary "PHASE_ADJUST_THRESHOLD" "$ACTUAL_ADJUST_THRESHOLD" "1000000000000000000" || ((FAILED+=1))
verify_boundary "MAX_GOV_BOOST_REWARD_MULTIPLIER" "$ACTUAL_MAX_BOOST" "1000" || ((FAILED+=1))
verify_boundary "SUBMIT_MIN_RATIO" "$ACTUAL_MIN_RATIO" "1000000000000000000" || ((FAILED+=1))
verify_boundary "FEE_SETTLEMENT_RATIO" "$ACTUAL_FEE_RATIO" "3000000000000000" || ((FAILED+=1))

# 两个非负十进制整数字符串相加；逐位处理避免 64 位溢出。
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
if [ -z "${TOKEN_NAME:-}" ] || [ -z "${TOKEN_SYMBOL:-}" ] || [ "$DISTRIBUTOR_ADDRESS" = "0x0000000000000000000000000000000000000000" ]; then
    echo -e "  ${RED}✗${NC} TOKEN_NAME / TOKEN_SYMBOL / DISTRIBUTOR_ADDRESS is empty"
    ((FAILED+=1))
else
    echo -e "  ${GREEN}✓${NC} token name, symbol and distributor are set"
fi

# 4. 验证 Router 和 Factory 的地址一致性
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

# 5. 验证根父币（Router.WETH() 读出的 WETH）本身是已部署合约
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
