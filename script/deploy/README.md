# Core 合约部署指南

## 目录结构

```
script/
├── deploy/
│   ├── one_click_deploy.sh    # 一键部署脚本
│   ├── 00_init.sh             # 环境初始化
│   ├── 01_deploy.sh           # 合约部署
│   ├── 99_check.sh            # 部署验证
│   ├── verify.sh              # 合约开源验证
│   └── DeployCore.s.sol       # Foundry 部署脚本
└── network/
    ├── bsc97_dev/             # BSC 测试网配置
    │   ├── .account           # 账户信息（敏感，已 gitignore）
    │   ├── network.params     # 网络参数
    │   ├── addresses.dex.params   # DEX 已部署地址（WBNB / Factory / Router），必需
    │   ├── core.params        # 合约部署参数
    │   └── addresses.core.params  # 本协议已部署地址，部署成功后自动写入
    └── anvil31337_dev/        # 本地测试网配置
        └── ...
```

## 部署前准备

### 1. 配置网络参数

编辑 `script/network/<network>/network.params`：
```bash
CHAIN_ID=97
RPC_URL=https://data-seed-prebsc-1-s1.binance.org:8545
```

### 2. 配置账户信息

创建 `script/network/<network>/.account`（此文件已被 .gitignore）：
```bash
KEYSTORE_ACCOUNT=keystore-file-name
ACCOUNT_ADDRESS=0xYourAccountAddress
KEYSTORE_PASSWORD=                        # 可选，留空即不启用
```

公共网络通过 Keystore 签名；仅 `CHAIN_ID=31337` 的本地网络可使用 `ACCOUNT_ADDRESS` 配合节点解锁账户。不要把明文私钥放进配置或命令参数。

`KEYSTORE_PASSWORD` 是可选项：填写非空值时直接用它解锁 keystore，整条部署链路无交互；留空或整行不写则保持原流程，由 forge 在终端询问密码。该值以明文保存在 `.account`，仅建议在受控机器或测试网使用；由助手操作且未配置该项时，在对话的密码输入框中提供，勿直接贴到消息中。

### 3. 配置 DEX 地址

编辑 `script/network/<network>/addresses.dex.params`，写入 `dex/` 仓库**同网络**部署并验收过的三个地址：

```bash
WBNB_ADDRESS=0x...      # 该网络的 WBNB（BSC 主网/测试网用官方地址，本地用 dex 部署的 TestWBNB）
FACTORY_ADDRESS=0x...   # dex 部署的 Uniswap V2 Factory
ROUTER_ADDRESS=0x...    # dex 部署的 Uniswap V2 Router02
```

该文件是 `00_init.sh` 的必需配置：缺失直接报错，三个地址为空或不是已部署合约会在广播前失败。

### 4. 配置合约参数

编辑 `script/network/<network>/core.params`：

```bash
# LOVE20Token 部署参数
TOKEN_NAME=LOVE20
TOKEN_SYMBOL=LOVE
INITIAL_SUPPLY=1000000000000000000000000000  # 10亿（18位小数）
MAX_SUPPLY=10000000000000000000000000000     # 100亿（18位小数）
DISTRIBUTOR=0xYourDeployerAddressHere        # 初始代币接收地址
PARENT_TOKEN=${WBNB_ADDRESS}                  # WBNB地址，取自 addresses.dex.params

# MemberNFT 部署参数
MEMBER_BASE_DIVISOR=100000000
MEMBER_BYTES_THRESHOLD=7
MEMBER_MULTIPLIER=10
MEMBER_MAX_NAME_LENGTH=32

# Phase 部署参数
PHASE_ORIGIN_BLOCKS=1
PHASE_ORIGIN_PHASE_BLOCKS=28800              # 示例值；按目标链实测出块间隔设置
PHASE_TARGET_SECONDS=86400                   # 1天
PHASE_ADJUST_THRESHOLD=600000000000000000    # 0.6（18位小数）
PHASE_SYNC_OBSERVATION_LIMIT=100

# Launch 部署参数
LAUNCH_RATIO=1000000000000000000             # 1e18，上限即 1e18
MAX_LAUNCH_COUNT=1000
TOKEN_SYMBOL_LENGTH=4                        # 子币符号 UTF-8 字节长度（首币不受此限；汉字占 3 字节）

# Mint 部署参数
MIN_PROPOSAL_VOTES=50                        # 提案奖励门槛（千分比，须 <= 1000）
GOV_REWARD_RATIO=100                         # 治理奖池占比（千分比）
PROPOSAL_REWARD_RATIO=100                    # 提案奖池占比（千分比）
MAX_BOOST_MULTIPLIER=2

# Submit 部署参数
SUBMIT_MIN_PER_THOUSAND=10                   # 推举门槛（千分比）

# Stake 部署参数
PROMISED_WAITING_PHASES_MIN=1
PROMISED_WAITING_PHASES_MAX=100

# Stake 手续费销毁阈值及单次处理量的分母
MAX_WITHDRAWABLE_TO_FEE_RATIO=1000           # 每次处理 floor(withdrawableLp / 1000) 个手续费 LP 最小单位
```

`core.params` 缺任一键，部署会在模拟阶段因读不到环境变量而失败；取值上下界由对应合约的 `init` 校验（例：`LAUNCH_RATIO` 上限 `1e18`、`MIN_PROPOSAL_VOTES <= 1000`、`GOV_REWARD_RATIO + PROPOSAL_REWARD_RATIO <= 1000`、`PROMISED_WAITING_PHASES_MIN <= MAX`），部署脚本另在广播前重复校验 `LAUNCH_RATIO` 与 `MIN_PROPOSAL_VOTES`。

**重要参数说明：**
- `DISTRIBUTOR`: 设置为部署钱包地址，接收初始代币
- 首币 `minter` 自动绑定本次部署的 Mint 地址，无需配置 `MINTER`。
- `PARENT_TOKEN`: 
  - BSC 主网: 使用官方 WBNB `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c`
  - BSC 测试网: 使用测试 WBNB `0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd`
  - Anvil 本地: 使用 `${WBNB_ADDRESS}` 引用 dex 部署的 TestWBNB
- `PHASE_ORIGIN_PHASE_BLOCKS`: 以目标链实测出块间隔估算；不要将固定的“3 秒一块”当作发布依据。

## 部署流程

### 一键部署

```bash
cd core
./script/deploy/one_click_deploy.sh bsc97_dev
```

该脚本会自动执行：
1. 加载环境配置
2. 部署所有合约
3. 验证部署结果
4. 保存合约地址

链 ID、全部初始化绑定及常量、DEX 地址关系任一不一致，部署入口返回失败，不覆盖已保存的地址。网络名必填，缺参直接报错。`PARENT_TOKEN`（WBNB）、`FACTORY_ADDRESS`、`ROUTER_ADDRESS` 在广播前即校验为已部署合约，配错不会产生任何交易。

DEX 使用相邻 `dex/` 仓库自部署的官方 Uniswap V2：交易手续费固定为 0.30%，Factory 的 `feeTo` 与 `feeToSetter` 均为零。地址应来自该仓库同网络的部署及验收结果，不使用旧 PancakeSwap 配置。

`MAX_WITHDRAWABLE_TO_FEE_RATIO` 决定手续费销毁的触发阈值和单次处理量，不是交易费率。`99_check.sh` 中的 `ACTUAL_FEE_RATIO` 只是链上读取结果，用于与这个配置值比对。现有配置保持 `1000`；每社区每 Phase 至多实际结算一次，且单次处理量须足够让 Pair 两侧产出非零数量。

### 分步部署

`00_init.sh` 与 `01_deploy.sh` 之间靠同一 shell 的变量传递，必须在同一个 bash 子进程里顺序执行。不要把 `00_init.sh` `source` 进交互 shell —— 它的 `set -euo pipefail` 会留在当前终端（部分编辑器的终端集成会因此在每条命令前报 `RPROMPT: parameter not set`）。

```bash
# 初始化 + 部署
bash -c 'source script/deploy/00_init.sh bsc97_dev && bash script/deploy/01_deploy.sh'
```

`01_deploy.sh` 已执行链上验收。重新独立验收时，在载入最新地址后运行 `99_check.sh`：

```bash
bash -c 'source script/deploy/00_init.sh bsc97_dev && bash script/deploy/99_check.sh'
```

`99_check.sh` 只读配置与链上状态，可重复运行。

## 合约开源验证

部署完成后，在 BSCScan 上验证合约：

```bash
# 设置 Etherscan API Key
export ETHERSCAN_API_KEY=your-api-key

# 执行验证
./script/deploy/verify.sh bsc97_dev
```

使用 Etherscan V2 API Key。缺少 Key、链不支持、构造参数错误或任何一份合约验证失败均返回非零；只有 8 份全部成功才显示完成。API 入口依据 [Etherscan 官方文档](https://docs.etherscan.io/make-your-first-call)。

API Key 只通过环境变量传入，不要写进 `network.params`：`00_init.sh` 会载入该文件，文件里的空值会覆盖已导出的环境变量。

## 部署输出

部署成功后，合约地址会自动写入 `script/network/<network>/addresses.core.params`：

```bash
LOVE20TOKEN_ADDRESS=0x...
MEMBERNFT_ADDRESS=0x...
PHASE_ADDRESS=0x...
LAUNCH_ADDRESS=0x...
MINT_ADDRESS=0x...
STAKE_ADDRESS=0x...
SUBMIT_ADDRESS=0x...
VOTE_ADDRESS=0x...
```

## 常见问题

### 1. 首币 minter 绑定问题

`DeployCore` 先部署 Mint，再由 Launch 创建首币并绑定 Mint。Token 没有 `setMinter`，错误绑定必须重新部署。开源验证使用本次部署地址文件里的 `MINT_ADDRESS`。

### 2. PARENT_TOKEN 配置

- 首个代币必须使用 WBNB 作为父币（协议树外根父币）
- 发射的父币可以使用任意已部署的 LOVE20Token 地址，或根父币（WBNB）：父币为根父币的根级发射创建与首币平级的同级币，消耗首币次数 1:1 伴生出的根级次数
- 部署后 `firstTokenAddress()` 必须等于 `tokens(0)` 的首币地址（`99_check.sh` 已校验）

### 3. 区块数量配置

根据目标网络近期区块时间计算初始块数，部署后核对 `Phase` 同步与校准行为。

## 安全注意事项

1. **敏感文件**: `.account` 已被 `.gitignore`，仅配置 Keystore 名称及账户地址，绝不提交到仓库
2. **私钥管理**: 生产环境建议使用硬件钱包或 Keystore
3. **参数检查**: 部署前仔细检查所有参数，特别是供应量和地址
4. **测试先行**: 生产部署前先在测试网完整测试流程

## 本地回归

```bash
forge build
forge test
python3 test/deploy_scripts_test.py
forge test --match-contract ProposalDoSTest -vv
```

压力测试使用真实 Core 合约及模拟 DEX，实际创建、推举、投票、申请解锁并调用 Mint。输出用于本地回归，不代表目标 BSC 链的交易或区块 gas 上限。
