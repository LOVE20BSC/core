# Core 合约部署指南

## 目录结构

```
script/
├── deploy/
│   ├── one_click_deploy.sh    # 一键部署入口（纯编排，不载入任何环境文件）
│   ├── 11_deploy.sh           # 合约部署与初始化（自载入部署输入）
│   ├── 21_check.sh            # 部署与初始化正确性校验（自载入校验文件）
│   ├── 31_verify.sh           # 合约开源验证（自载入网络与地址文件）
│   └── DeployCore.s.sol       # Foundry 部署脚本
└── network/
    └── anvil31337_dev/        # 本地测试网配置（后续网络按 <链名><链id>_<类型> 新建）
        ├── .account           # 账户信息（敏感，已 gitignore）
        ├── network.params     # 网络参数
        ├── addresses.uniswapv2.params # dex UniswapV2 模块地址（Factory / Router），必需
        ├── core.params        # 合约部署参数
        └── addresses.core.params  # 本协议已部署地址，部署成功后自动写入
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
KEYSTORE_PASSWORD=                        # 可选，留空走弹窗（仅 macOS）
```

`.account` 是必需文件：本地链与公共网络统一走 keystore 签名，不提供 `--unlocked` 回退。不要把明文私钥放进配置或命令参数。

`KEYSTORE_PASSWORD` 填写非空值时直接用它解锁 keystore，整条部署链路无交互；留空或整行不写时由 macOS `osascript` 弹窗读取。`one_click_deploy.sh` 入口把密码**只解析一次**（先重置、再读 `.account`、最后才交互）并导出给全部部署步骤；单独运行某个部署步骤时，该步骤按 环境变量 → `.account` → 交互 自行解析。**入口不接受通过环境变量传密码**：`KEYSTORE_PASSWORD=xxx ./script/deploy/one_click_deploy.sh <net>` 里的值会被入口重置掉（有意为之，避免上次运行的残留密码被静默复用），非交互场景请把密码写进 `.account` 的 `KEYSTORE_PASSWORD`。非 macOS 环境没有 `osascript`，必须填写该项，脚本会在缺失时明确报错。该值以明文保存在 `.account`，仅建议在受控机器或测试网使用；由助手操作且未配置该项时，在对话的密码输入框中提供，勿直接贴到消息中。

密码不会出现在进程参数里：`11_deploy.sh` 将其写入权限 600 的临时文件，以 `--password-file` 传给 forge，广播结束或脚本退出时删除。

### 3. 配置 DEX 地址

把 `dex/` 仓库**同网络** UniswapV2 模块部署并验收过的 `addresses.uniswapv2.params` 复制到本仓：

```bash
FACTORY_ADDRESS=0x...    # dex 部署的 Uniswap V2 Factory
ROUTER_ADDRESS=0x...     # dex 部署的 Uniswap V2 Router02
```

该文件是部署的必需配置：缺失直接报错。`FACTORY_ADDRESS`、`ROUTER_ADDRESS` 有代码、`Router.factory() == FACTORY_ADDRESS` 与 `Router.WETH()` 有代码由 `DeployCore` 在广播前校验，`11_deploy.sh` 不重复 cast 检查。根父币（WETH）不需要配置：`DeployCore` 从 `Router.WETH()` 现场读取，`21_check.sh` 与 `31_verify.sh` 按同一来源取用——WETH 模块的地址文件与 core 无关，不必复制。

### 4. 配置合约参数

编辑 `script/network/<network>/core.params`：

```bash
# LOVE20Token 部署参数
TOKEN_NAME=LOVE20
TOKEN_SYMBOL=LOVE
INITIAL_SUPPLY=1000000000000000000000000000  # 10亿（18位小数）
MAX_SUPPLY=10000000000000000000000000000     # 100亿（18位小数）
DISTRIBUTOR_ADDRESS=0xYourDeployerAddressHere  # 初始代币接收地址

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

# Mint 部署参数（比例以 1e18 表示 100%）
PROPOSAL_REWARD_MIN_VOTE_RATIO=50000000000000000  # 提案奖励门槛（5%，须 <= 1e18）
GOV_REWARD_RATIO=100000000000000000              # 治理奖池占比（10%）
PROPOSAL_REWARD_RATIO=100000000000000000         # 提案奖池占比（10%）
MAX_BOOST_MULTIPLIER=2

# Submit 部署参数（比例以 1e18 表示 100%）
SUBMIT_MIN_RATIO=10000000000000000               # 推举门槛（1%）

# Stake 部署参数
PROMISED_WAITING_PHASES_MIN=1
PROMISED_WAITING_PHASES_MAX=100

# 单笔手续费结算占可提取 LP 的比例（1e18 = 100%），同时是结算阈值
FEE_SETTLEMENT_RATIO=3000000000000000  # 0.3%；每次处理 floor(withdrawableLp * 该值 / 1e18) 个手续费 LP 最小单位
```

`core.params` 缺任一键，部署会在模拟阶段因读不到环境变量而失败；全部部署期静态参数由 `DeployCore` 在广播前校验，部署后再由 `_validateDeployment` 逐项核对完整绑定图，`21_check.sh` 独立复核（含首币 `totalSupply` 与 `DISTRIBUTOR_ADDRESS` 余额）：MemberNFT 四项非零、Phase 五项非零且 `ADJUST_THRESHOLD <= 1e18`、`0 < LAUNCH_RATIO <= 1e18`、`MAX_LAUNCH_COUNT/TOKEN_SYMBOL_LENGTH/LAUNCH_AMOUNT` 非零且 `LAUNCH_AMOUNT <= MAX_SUPPLY`、`PROPOSAL_REWARD_MIN_VOTE_RATIO <= 1e18`、两项激励比例之和 `<= 1e18`、`0 < MAX_BOOST_MULTIPLIER <= 1000`、`0 < SUBMIT_MIN_RATIO <= 1e18`、`PROMISED_WAITING_PHASES_MIN > 0` 且 `<= MAX`、`0 < FEE_SETTLEMENT_RATIO <= 0.30%` 池费率。合约 `init` 只防重复初始化并保存配置。

**重要参数说明：**
- `DISTRIBUTOR_ADDRESS`: 设置为部署钱包地址，接收初始代币
- 首币 `minter` 自动绑定本次部署的 Mint 地址，无需配置 `MINTER`。
- 根父币（WETH）无需配置：`DeployCore` 从 `Router.WETH()` 读取，BSC 主网/测试网即官方 WBNB，Anvil 本地即 dex 部署的 WETH9。
- `PHASE_ORIGIN_PHASE_BLOCKS`: 以目标链实测出块间隔估算；不要将固定的“3 秒一块”当作发布依据。

## 部署流程

### 一键部署

```bash
cd core
./script/deploy/one_click_deploy.sh anvil31337_dev
```

该脚本依次调用下列单步骤脚本（各步骤只做自己那一步、互不调用、自行载入输入；单独执行见「分步部署」）：

1. `11_deploy.sh` —— 自载入部署输入并部署初始化全部合约，写入合约地址
2. `21_check.sh` —— 自载入校验文件，校验部署与初始化结果
3. `31_verify.sh` —— 自载入地址文件做合约开源验证；链支持时执行（需 `ETHERSCAN_API_KEY`），链不支持时跳过

链 ID、全部部署期静态参数、初始化绑定及常量、DEX 地址关系任一不一致，部署入口返回失败，并回滚到上一次已保存的地址（校验失败不覆盖旧地址）。广播阶段或其后的校验失败时，`11_deploy.sh` 保留部署日志并打印日志与 broadcast 产物路径；广播前失败只清理本次临时文件。网络名必填，缺参直接报错。`FACTORY_ADDRESS`、`ROUTER_ADDRESS` 有代码、`Router.factory()` 与配置一致、`Router.WETH()` 读出的根父币有代码，均在广播前校验，配错不会产生任何交易。

DEX 使用相邻 `dex/` 仓库自部署的官方 Uniswap V2：交易手续费固定为 0.30%，Factory 的 `feeTo` 与 `feeToSetter` 均为零。地址应来自该仓库同网络的部署及验收结果，不使用旧 PancakeSwap 配置。

`FEE_SETTLEMENT_RATIO` 是单笔手续费结算占可提取 LP 的比例，同时决定触发阈值和单次处理量，不是交易费率。它以 `1e18` 表示 100%；`21_check.sh` 中的 `ACTUAL_FEE_RATIO` 只是链上读取结果，用于与这个配置值比对。现有配置 `3e15` 表示 0.3%，等于目标池费率，是该约束的上界；单次价格移动严格小于一个池费，一次往返的夹子成本仍为两个池费。该值必须不大于目标池费率，否则单笔结算的价格移动会盖过池费、放大夹子敞口。每社区每 Phase 至多实际结算一次，且单次处理量须足够让 Pair 两侧产出非零数量。

### 分步部署

每个步骤脚本统一 `<step>.sh <network>` 一种调用形态，**自行加载自己需要的文件**，没有任何文件互相 source，任一一步都可脱离入口单独执行：

| 步骤 | 自行载入的输入 |
| --- | --- |
| `11_deploy.sh` | `network.params`、`addresses.uniswapv2.params`、`core.params`、`.account`；写入 `addresses.core.params` |
| `21_check.sh` | `network.params`、`addresses.uniswapv2.params`、`core.params`、`addresses.core.params` |
| `31_verify.sh` | `network.params`、`addresses.uniswapv2.params`、`core.params`、`addresses.core.params` |

各步骤自行载入自己的输入（见上表），dex 的地址文件与 `core.params` 之间无引用关系，载入顺序不再敏感。`21_check.sh` 另断言 `addresses.core.params` 的键集合等于 8 个期望合约键。

```bash
# 部署与初始化
./script/deploy/11_deploy.sh anvil31337_dev

# 校验部署与初始化结果（只读配置与链上状态，可重复运行）
./script/deploy/21_check.sh anvil31337_dev

# 合约开源验证
./script/deploy/31_verify.sh anvil31337_dev
```

`11_deploy.sh` 只负责自包含加载、链/账户/密码、调用 forge 与地址文件原子写入，不重复 Solidity 脚本的参数/依赖/绑定校验；验收由 `one_click_deploy.sh` 编排，或按上例单独运行。

## 合约开源验证

部署完成后，在 BSCScan 上验证合约：

```bash
# 设置 Etherscan API Key
export ETHERSCAN_API_KEY=your-api-key

# 执行验证
./script/deploy/31_verify.sh anvil31337_dev
```

使用 Etherscan V2 API Key。缺少 Key、构造参数错误或任何一份合约验证失败均返回非零；链不支持开源验证时跳过并返回 0；只有 8 份全部成功才显示完成。API 入口依据 [Etherscan 官方文档](https://docs.etherscan.io/make-your-first-call)。

API Key 只通过环境变量传入，不要写进 `network.params`：步骤脚本会载入该文件，文件里的空值会覆盖已导出的环境变量。

## 部署输出

部署成功后，合约地址会自动写入 `script/network/<network>/addresses.core.params`：

```bash
LOVE20_TOKEN_ADDRESS=0x...
MEMBER_NFT_ADDRESS=0x...
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

### 2. 根父币（WETH）配置

- 根父币无需配置：`DeployCore` 从 `Router.WETH()` 读取。首个代币必须使用 WETH 作为父币（协议树外根父币，BSC 上即官方 WBNB）
- 发射的父币可以使用任意已部署的 LOVE20Token 地址，或根父币（WETH）：父币为根父币的根级发射创建与首币平级的同级币，消耗首币次数 1:1 伴生出的根级次数
- 部署后 `firstTokenAddress()` 必须等于 `tokens(0)` 的首币地址（`21_check.sh` 已校验）

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
