# Core 合约部署指南

## 目录结构

```
script/
├── deploy/
│   ├── one_click_deploy.sh    # 一键部署入口（纯编排，不载入任何环境文件）
│   ├── 11_deploy.sh           # 合约部署（构造函数一次注入，自载入部署输入）
│   ├── 21_check.sh            # 部署正确性校验（自载入校验文件）
│   ├── 31_verify.sh           # 合约开源验证（自载入网络与地址文件）
│   └── DeployCore.s.sol       # Foundry 部署脚本
└── network/
    ├── verifier.params        # 开源验证端点与跳过链（所有网络共用一份）
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
ETHERSCAN_API_KEY=                        # 开源验证凭据；空=验证步骤直接失败（跳过与否只看 VERIFY_SKIP_CHAIN_IDS）
```

编辑 `script/network/verifier.params`（所有网络共用一份，不随网络目录新建）：
```bash
ETHERSCAN_VERIFIER_URL=https://api.etherscan.io/v2/api   # 验证器端点；自建/第三方验证器改这里
VERIFY_SKIP_CHAIN_IDS=31337               # 逗号分隔；默认验证，只有列出的链跳过
```

验证默认开启：没有列进 `VERIFY_SKIP_CHAIN_IDS` 的链会真去验证，缺 Key 或端点不可用都会失败，不会静默放过。`56`、`97` 不允许出现跳过名单里（部署回归测试会拒绝），否则一条没验证的主网部署看起来会像成功。

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
# LOVE20Token（首币；LAUNCH_AMOUNT / MAX_SUPPLY 同时决定此后每个子币的铸造量与上限）
TOKEN_NAME=LOVE@WBNB                          # 首币名称，惯例为 <首币符号>@<根父币符号>
TOKEN_SYMBOL=LOVE                             # 首币符号；以 "Test" 开头时，子币符号自动加 "Test" 前缀
LAUNCH_AMOUNT=1e27                           # 每个代币的首批供应，10亿枚（18位小数）；不得小于 1e18
MAX_SUPPLY=1e28                              # 每个代币的供应上限，100亿枚（18位小数）

# 首币空投（distributor 为首币首批供应的接收方，由部署顺序决定，不再配置地址）
GENESIS_AIRDROP_MERKLE_ROOT=0x...            # 首币份额 Merkle Root；零值在广播前失败
GENESIS_AIRDROP_CLAIM_DELAY_ROUNDS=1         # 首币可领取轮 = max(currentPhase,1) + 该值；须 <= 1000

# MemberNFT
MEMBER_BASE_DIVISOR=1e8
MEMBER_BYTES_THRESHOLD=7
MEMBER_MULTIPLIER=10
MEMBER_MAX_NAME_LENGTH=32

# Phase
PHASE_ORIGIN_BLOCKS=1
PHASE_ORIGIN_PHASE_BLOCKS=28800              # 示例值；按目标链实测出块间隔设置
PHASE_TARGET_SECONDS=86400                   # 1天
PHASE_ADJUST_THRESHOLD=6e17                  # 60%
PHASE_SYNC_OBSERVATION_LIMIT=100

# Launch
LAUNCH_COUNT_THRESHOLD_RATIO=1e17              # 10%，每累计未铸供应的这一比例折算 1 个发射次数
MAX_LAUNCH_COUNT=1000
TOKEN_SYMBOL_LENGTH=6                        # 子币符号 UTF-8 字节长度（首币不受此限；两个汉字或六个字母数字）

# Mint 部署参数（比例以 1e18 表示 100%）
PROPOSAL_REWARD_MIN_VOTE_RATIO=3e16              # 提案奖励门槛（3%，须 <= 1e18）
ROUND_REWARD_GOV_RATIO=5e14                      # 治理奖池占可用供应的比例（0.05%）
ROUND_REWARD_PROPOSAL_RATIO=5e14                 # 提案奖池占可用供应的比例（0.05%）

# Submit 部署参数（比例以 1e18 表示 100%）
SUBMIT_MIN_RATIO=3e15                            # 推举门槛（0.3%）

# Stake 部署参数
PROMISED_WAITING_PHASES_MIN=1
PROMISED_WAITING_PHASES_MAX=100
# 加速激励质押单人上限：上限基数 = 流动性质押社区代币本金 × 2 × (已铸造量 / 最大供应量) × 该因子
BOOST_STAKE_SUPPLY_FACTOR=2                      # 建议 1–10（仅建议，部署只校验大于 0）
# 单人上限 = 上限基数 × (该治理者有效治理票 / 总有效治理票) × 该倍数（社区层面无聚合上限）
BOOST_STAKE_MULTIPLIER=5                         # 建议 1–20（仅建议，部署只校验大于 0）

# 单笔手续费结算占 Pair LP 总供应的比例（1e18 = 100%），同时是结算阈值
FEE_SETTLEMENT_RATIO=25e14   # 0.25%，即上界 MAX_FEE_SETTLEMENT_RATIO（源码常量写作 2.5e15）；每次处理 floor(pairTotalSupply * 该值 / 1e18) 个手续费 LP 最小单位；手续费 LP 不足一个单位时不销毁
```

上例取正式网络的部署值（同白皮书附录 A）。`script/network/anvil31337_dev/core.params` 是本地测试 profile，为了让 Phase 与发行节奏在几分钟内跑完，取值刻意不同（如 Phase 目标 300 秒、每社区次数上限 10000），不要拿它当正式配置。

值可写成 `<整数>e<指数>`（`1e17` 即 10%）或带下划线的分组写法（`1_000_000`），由 `script/deploy/params.sh` 在载入时展开为十进制再导出。展开是纯词法的：没有键表，新增或删除参数都不需要改载入器；只对整体形如 `<整数>e<整数>` 的值生效，其余原样保留，写错的写法会留给 `vm.envUint` 在广播前报错。尾数必须是不带小数点的整数，`2.5e15` 不会被展开（写成 `25e14`）。行尾 `#` 注释在展开前丢弃。该机制只作用于 `*.params`，`.account` 仍直接 `source`（密码可能含 `#`）。

本仓没有必填键断言：core 的部署参数没有「缺键即静默改变行为」的成员，缺键一律由 `vm.envUint` 在广播前失败；因此三个步骤只做 `params_unset_all`，不调用 `params_require_keys` / `params_require_values`。

`core.params` 缺任一键，部署会在模拟阶段因读不到环境变量而失败；全部部署期静态参数由 `DeployCore` 在广播前校验，部署后再由 `_validateDeployment` 逐项核对完整绑定图（含 `Launch.MAX_TOKEN_SYMBOL_LENGTH` 与广播前副本相等），`21_check.sh` 独立复核（含首币 `totalSupply`、首币在 `AIRDROP_DISTRIBUTOR_ADDRESS` 的余额、首币的 Merkle Root 与可领取轮，以及 `TOKEN_SYMBOL_LENGTH + TEST_PREFIX_BYTES <= MAX_TOKEN_SYMBOL_LENGTH` 的 Test 前缀余量，金额与轮次从链上读取）：MemberNFT 四项非零、Phase 五项非零且 `ADJUST_THRESHOLD <= 1e18`、`0 < LAUNCH_COUNT_THRESHOLD_RATIO <= 1e18`、`MAX_LAUNCH_COUNT/TOKEN_SYMBOL_LENGTH` 非零、`1e18 <= LAUNCH_AMOUNT <= MAX_SUPPLY`、`PROPOSAL_REWARD_MIN_VOTE_RATIO <= 1e18`、两项激励比例之和 `<= 1e18`、`BOOST_STAKE_SUPPLY_FACTOR > 0`（建议 1–10，非校验条件）、`BOOST_STAKE_MULTIPLIER > 0`（建议 1–20，非校验条件）、`0 < SUBMIT_MIN_RATIO <= 1e18`、`PROMISED_WAITING_PHASES_MIN > 0` 且 `<= MAX`、`0 < FEE_SETTLEMENT_RATIO <= 0.25%`（`MAX_FEE_SETTLEMENT_RATIO`）、`GENESIS_AIRDROP_MERKLE_ROOT != 0` 且 `GENESIS_AIRDROP_CLAIM_DELAY_ROUNDS <= 1000`（`AirdropDistributor.MAX_CLAIM_DELAY_ROUNDS`）。合约构造函数只保存配置，不做静态零值校验；依赖代码与派生值由部署脚本核对。

`LAUNCH_AMOUNT >= 1e18`（= `AirdropDistributor.TOTAL_SHARE`）是**承重**约束：它是「`claim` 不检查 `amount == 0`」的前提——份额 `share >= 1`、剩余份额 `remainingShare <= 1e18` 时，`amount = floor(balance × share ÷ remainingShare) >= 1`。链下生成器必须把份额精确归一到 `1e18`。

**重要参数说明：**
- `GENESIS_AIRDROP_MERKLE_ROOT` / `GENESIS_AIRDROP_CLAIM_DELAY_ROUNDS`: 首币空投配置，构造 `AirdropDistributor` 时一次写入；`merkleRoot` 填错等于该批首币永久锁死（链上无法验证叶子之和），部署前必须在链下复核
- `DISTRIBUTOR_ADDRESS` 已删除：首币首批供应的接收方是 `AirdropDistributor`，其地址由部署顺序固定（预测 `nonce+1`）并在部署后 `require` 核对，不再由配置注入。历史 `core.params` 里残留该键不会报错（`params.sh` 无键表），但已无任何读取方
- 首币的 minter 自动绑定本次部署的 Mint 地址，部署参数中没有 minter 项。
- 根父币（WETH）无需配置：`DeployCore` 从 `Router.WETH()` 读取，BSC 主网/测试网即官方 WBNB，Anvil 本地即 dex 部署的 WETH9。
- `PHASE_ORIGIN_PHASE_BLOCKS`: 以目标链实测出块间隔估算；不要将固定的“3 秒一块”当作发布依据。

## 部署流程

### 一键部署

```bash
cd core
./script/deploy/one_click_deploy.sh anvil31337_dev
```

该脚本依次调用下列单步骤脚本（各步骤只做自己那一步、互不调用、自行载入输入；单独执行见「分步部署」）：

1. `11_deploy.sh` —— 自载入部署输入并按固定顺序部署全部合约（构造函数一次注入依赖），写入合约地址
2. `21_check.sh` —— 自载入校验文件，校验部署结果
3. `31_verify.sh` —— 自载入地址文件做合约开源验证；默认执行（需 `network.params` 的 `ETHERSCAN_API_KEY`），只有 `verifier.params` 的 `VERIFY_SKIP_CHAIN_IDS` 列出的链才跳过

链 ID、全部部署期静态参数、构造绑定及常量、DEX 地址关系任一不一致，部署入口返回失败，并回滚到上一次已保存的地址（校验失败不覆盖旧地址）。广播阶段或其后的校验失败时，`11_deploy.sh` 保留部署日志并打印日志与 broadcast 产物路径；广播前失败只清理本次临时文件。网络名必填，缺参直接报错。`FACTORY_ADDRESS`、`ROUTER_ADDRESS` 有代码、`Router.factory()` 与配置一致、`Router.WETH()` 读出的根父币有代码，均在广播前校验，配错不会产生任何交易。

DEX 使用相邻 `dex/` 仓库自部署的官方 Uniswap V2，Factory 的 `feeTo` 与 `feeToSetter` 均为零。地址应来自该仓库同网络的部署及验收结果，不使用旧 PancakeSwap 配置。

`FEE_SETTLEMENT_RATIO` 是单笔手续费结算占 Pair 的 LP 总供应的比例，同时决定触发阈值和单次处理量，不是交易费率。它以 `1e18` 表示 100%；`21_check.sh` 中的 `ACTUAL_FEE_RATIO` 只是链上读取结果，用于与这个配置值比对。上界是编译期常量 `MAX_FEE_SETTLEMENT_RATIO = 2.5e15`（0.25%，低于池费率），配置值取 `25e14`（0.25%，与白皮书附录 A 一致）。单笔销毁占 Pair LP 总供应的比例恰为该值；卖出量占父币储备的比例相同，成交价相对结算前偏离恰为该值，现货价移动约为其两倍；夹子往返成本为两倍池费，因此只要该值不大于目标池费率，成交价偏离低于一个池费、现货价移动不超过两倍池费，往返无利可图。该值必须不大于目标池费率，否则单笔结算的现货价移动会盖过往返成本、放大夹子敞口。每社区每 Phase 至多实际结算一次，且单次处理量须足够让 Pair 两侧产出非零数量。手续费 LP 恒不超过社区记账 LP，因此社区质押 LP 占全池比例低于该值时，手续费 LP 通常达不到一个单位，`settleFees` 不实际销毁；这部分手续费仍作为池中 LP 留在合约里，直到社区质押增长。取整边界是例外：`feeLp == floor(pairTotalSupply × 该值 / 1e18)` 时，即使份额低于该比例仍会结算。

### 分步部署

每个步骤脚本统一 `<step>.sh <network>` 一种调用形态，**自行加载自己需要的文件**，没有任何文件互相 source，任一一步都可脱离入口单独执行：

| 步骤 | 自行载入的输入 |
| --- | --- |
| `11_deploy.sh` | `network.params`、`addresses.uniswapv2.params`、`core.params`、`.account`；写入 `addresses.core.params` |
| `21_check.sh` | `network.params`、`addresses.uniswapv2.params`、`core.params`、`addresses.core.params` |
| `31_verify.sh` | `network.params`、`verifier.params`、`addresses.uniswapv2.params`、`core.params`、`addresses.core.params` |

各步骤自行载入自己的输入（见上表），dex 的地址文件与 `core.params` 之间无引用关系，载入顺序不再敏感。`21_check.sh` 另断言 `addresses.core.params` 的键集合等于 9 个期望合约键。

```bash
# 部署
./script/deploy/11_deploy.sh anvil31337_dev

# 校验部署结果（只读配置与链上状态）
./script/deploy/21_check.sh anvil31337_dev

# 合约开源验证
./script/deploy/31_verify.sh anvil31337_dev
```

`11_deploy.sh` 只负责自包含加载、链/账户/密码、调用 forge 与地址文件原子写入，不重复 Solidity 脚本的参数/依赖/绑定校验；验收由 `one_click_deploy.sh` 编排，或按上例单独运行。

## 合约开源验证

部署完成后，在 BSCScan 上验证合约：

```bash
# 把 Etherscan API Key 填进 script/network/<network>/network.params 的 ETHERSCAN_API_KEY

# 执行验证（端点与跳过名单见 verifier.params）
./script/deploy/31_verify.sh anvil31337_dev
```

使用 Etherscan V2 API Key。缺少 Key、构造参数错误或任何一份合约验证失败均返回非零；链列在 `verifier.params` 的 `VERIFY_SKIP_CHAIN_IDS` 时跳过并返回 0；只有 9 份全部成功才显示完成（`AirdropDistributor` 源码路径为 `src/distributor/AirdropDistributor.sol`）。API 入口依据 [Etherscan 官方文档](https://docs.etherscan.io/make-your-first-call)。

`ETHERSCAN_API_KEY` 是 `network.params` 的一个键，和 `CHAIN_ID`、`RPC_URL` 一样只从文件取值：步骤脚本载入该文件时文件值（包括空值）覆盖调用方的同名环境变量，因此 `ETHERSCAN_API_KEY=xxx ./31_verify.sh` 不生效。该键是凭据，仓库里只放空值，本地或 CI 运行前再填。

## 部署输出

部署成功后，合约地址会自动写入 `script/network/<network>/addresses.core.params`：

```bash
LOVE20_TOKEN_ADDRESS=0x...
AIRDROP_DISTRIBUTOR_ADDRESS=0x...
MEMBER_NFT_ADDRESS=0x...
PHASE_ADDRESS=0x...
LAUNCH_ADDRESS=0x...
MINT_ADDRESS=0x...
STAKE_ADDRESS=0x...
SUBMIT_ADDRESS=0x...
VOTE_ADDRESS=0x...
```

## 常见问题

### 1. 首币 minter 与 distributor 绑定问题

`DeployCore` 先部署 `Launch`，由其构造函数创建首币并写入预测的 Mint 地址；Mint 最后部署，部署后回读 `Token.MINTER` 与 `Launch.MINT_ADDRESS` 核对。Token 没有 `setMinter`，错误绑定必须重新部署。开源验证使用本次部署地址文件里的 `MINT_ADDRESS`。

首币的 distributor 同样是预测地址：部署顺序固定为 `Phase`(+0) → `AirdropDistributor`(+1) → `Launch`(+2) → `MemberNFT`(+3) → `Stake`(+4) → `Submit`(+5) → `Vote`(+6) → `Mint`(+7)，首币地址预测为 `computeCreateAddress(launch, 1)`（`Launch` 构造函数只有一处 `new`；`factory.createPair` 是外部调用不消耗 nonce）。每个预测地址在部署后都 `require` 核对，任一不符即整笔失败。

### 2. 根父币（WETH）配置

- 根父币无需配置：`DeployCore` 从 `Router.WETH()` 读取。首个代币必须使用 WETH 作为父币（协议树外根父币，BSC 上即官方 WBNB）
- 发射的父币必须是已登记的 LOVE20Token 地址；父币未登记时回滚 `ParentTokenNotRegistered`
- 部署后 `FIRST_TOKEN_ADDRESS()` 必须等于 `tokens(0)` 的首币地址（`21_check.sh` 已校验）

### 3. 区块数量配置

根据目标网络近期区块时间计算初始块数，部署后核对 `Phase` 同步与校准行为。

## 安全注意事项

1. **敏感文件**: `.account` 已被 `.gitignore`，仅配置 Keystore 名称及账户地址，绝不提交到仓库
2. **私钥管理**: 生产环境建议使用硬件钱包或 Keystore
3. **参数检查**: 部署前仔细检查所有参数，特别是供应量和地址
4. **测试先行**: 生产部署前先在测试网完整测试流程
5. **鉴权根优先**: 发布前检查项里 `MEMBER_NFT_ADDRESS` 是**首要**核对项。`Launch`、`Stake`、`Submit`、`Vote`、`Mint` 的成员入口都以它的 `ownerOf` 为鉴权判据，绑错不是参数错而是鉴权失效；其余项（比例、供应量、依赖地址）错了至少不会让权限判断失真。`DeployCore` 部署后逐项 require，`21_check.sh` 独立复核，任一不一致即重新部署。

## 本地回归

```bash
forge build
forge test
python3 test/deploy_scripts_test.py
forge test --match-contract ProposalDoSTest -vv
```

压力测试使用真实 Core 合约及模拟 DEX，实际创建、推举、投票、申请解锁并调用 Mint。输出用于本地回归，不代表目标 BSC 链的交易或区块 gas 上限。
