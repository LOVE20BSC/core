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
    │   ├── core.params        # 合约部署参数
    │   └── addresses.core.params  # 已部署地址
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
PRIVATE_KEY=your-private-key
```

### 3. 配置合约参数

编辑 `script/network/<network>/core.params`：

```bash
# LOVE20Token 部署参数
TOKEN_NAME=LOVE20
TOKEN_SYMBOL=LOVE
INITIAL_SUPPLY=1000000000000000000000000000  # 10亿（18位小数）
MAX_SUPPLY=10000000000000000000000000000     # 100亿（18位小数）
DISTRIBUTOR=0xYourDeployerAddressHere        # 初始代币接收地址
MINTER=${MINT_ADDRESS}                       # Mint合约地址
PARENT_TOKEN=0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd  # WBNB地址

# MemberNFT 部署参数
MEMBER_BASE_DIVISOR=100000000
MEMBER_BYTES_THRESHOLD=7
MEMBER_MULTIPLIER=10
MEMBER_MAX_NAME_LENGTH=32

# Phase 部署参数
PHASE_ORIGIN_BLOCKS=1
PHASE_ORIGIN_PHASE_BLOCKS=28800              # ~1天（BSC ~3秒/块）
PHASE_TARGET_SECONDS=86400                   # 1天
PHASE_ADJUST_THRESHOLD=600000000000000000    # 0.6（18位小数）
PHASE_SYNC_OBSERVATION_LIMIT=100
```

**重要参数说明：**
- `DISTRIBUTOR`: 设置为部署钱包地址，接收初始代币
- `MINTER`: 必须是 Mint 合约地址，需要先部署 Mint 或使用占位符
- `PARENT_TOKEN`: 
  - BSC 主网: 使用官方 WBNB `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c`
  - BSC 测试网: 使用测试 WBNB `0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd`
  - Anvil 本地: 使用 `${WBNB_ADDRESS}` 引用 dex 部署的 TestWBNB
- `PHASE_ORIGIN_PHASE_BLOCKS`: 
  - 测试环境: 100 块（约5分钟）
  - 生产环境: 28800 块（约1天，BSC ~3秒/块）

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

### 分步部署

```bash
# 1. 初始化环境
source script/deploy/00_init.sh bsc97_dev

# 2. 部署合约
./script/deploy/01_deploy.sh

# 3. 验证部署
./script/deploy/99_check.sh
```

## 合约开源验证

部署完成后，在 BSCScan 上验证合约：

```bash
# 设置 Etherscan API Key
export ETHERSCAN_API_KEY=your-api-key

# 执行验证
./script/deploy/verify.sh bsc97_dev
```

## 部署输出

部署成功后，合约地址会自动写入 `script/network/<network>/addresses.core.params`：

```bash
LOVE20TOKEN_ADDRESS=0x...
MEMBERNFT_ADDRESS=0x...
PHASE_ADDRESS=0x...
LAUNCH_ADDRESS=0x...
STAKE_ADDRESS=
SUBMIT_ADDRESS=
VOTE_ADDRESS=
MINT_ADDRESS=
```

## 常见问题

### 1. MINTER 地址问题

如果 Mint 合约尚未部署，可以：
- 方案1: 先部署 Mint，将地址填入 `core.params` 的 `MINTER`
- 方案2: 临时使用 `0x0000...0000`，后续通过 `setMinter` 更新

### 2. PARENT_TOKEN 配置

- 首个代币必须使用 WBNB 作为父币（协议树外根父币）
- 后续代币可以使用任意已部署的 LOVE20Token 地址

### 3. 区块数量配置

BSC 平均出块时间约 3 秒：
- 5 分钟 ≈ 100 块
- 1 小时 ≈ 1200 块
- 1 天 ≈ 28800 块

## 安全注意事项

1. **敏感文件**: `.account` 文件包含私钥，已被 `.gitignore`，绝不提交到仓库
2. **私钥管理**: 生产环境建议使用硬件钱包或 Keystore
3. **参数检查**: 部署前仔细检查所有参数，特别是供应量和地址
4. **测试先行**: 生产部署前先在测试网完整测试流程
