# 合约依赖关系分析

## 实际集成测试完成 ✅

**状态**: `test/integration/MintRealIntegration.t.sol` 已完成并通过测试
- **测试**: `testRealIntegration_FullGovernanceFlow()`
- **Gas 消耗**: 3,176,815
- **结果**: PASS ✅

## 构造函数签名

所有依赖都通过构造函数一次注入，不存在 `init` 入口。

### Phase
```solidity
constructor(
    uint256 originBlocks,
    uint256 originPhaseBlocks,
    uint256 targetSeconds,
    uint256 adjustThreshold,
    uint256 syncObservationLimit
)
```
**依赖**: 无

### MemberNFT
```solidity
constructor(
    uint256 baseDivisor,
    uint256 bytesThreshold,
    uint256 multiplier,
    uint256 maxNameLength,
    address firstTokenAddress
)
```
**依赖**: LOVE20Token 地址（部署脚本从已部署的 `Launch.FIRST_TOKEN_ADDRESS()` 读取）

### Mint
```solidity
constructor(
    address phaseAddress,
    address voteAddress,
    address submitAddress,
    address launchAddress,
    address memberNFTAddress,
    uint256 proposalRewardMinVoteRatio,
    uint256 roundRewardGovRatio,
    uint256 roundRewardProposalRatio
)
```
**依赖**: Phase, Vote, Submit, Launch, MemberNFT（`phaseAddress` 为直接入参，不再从 Vote 派生）

### Vote
```solidity
constructor(
    address phaseAddress,
    address stakeAddress,
    address submitAddress,
    address memberNFTAddress
)
```
**依赖**: Phase, Stake, Submit, MemberNFT

### Submit
```solidity
constructor(
    address phaseAddress,
    address stakeAddress,
    address memberNFTAddress,
    uint256 submitMinRatio
)
```
**依赖**: Phase, Stake, MemberNFT

### Stake
```solidity
constructor(
    address phaseAddress,
    address memberNFTAddress,
    address voteAddress,
    address launchAddress,
    address routerAddress,
    address pairFactoryAddress,
    uint256 promisedWaitingPhasesMin,
    uint256 promisedWaitingPhasesMax,
    uint256 feeSettlementRatio,
    uint256 boostStakeSupplyFactor,
    uint256 boostStakeMultiplier
)
```
**依赖**: Phase, MemberNFT, Vote, Launch, UniswapV2Router, UniswapV2Factory

### Launch
```solidity
constructor(LaunchInitParams params)
// params 包含:
// - mintAddress
// - memberNFTAddress
// - rootParentTokenAddress
// - pairFactoryAddress
// - distributor
// - 其他配置参数
```
**依赖**: Mint, MemberNFT, rootParentToken, UniswapV2Factory
**特殊**: `Launch` 构造函数创建首个 LOVE20Token 并登记，构造函数内只允许这一次 CREATE；`MemberNFT` 的首币绑定移到其自身构造函数

## 依赖图

```
Phase（构造函数，无依赖）
  ↓
  需要 Phase 的合约:
  - Stake
  - Submit
  - Vote
  - Mint

UniswapV2Factory（外部合约）
UniswapV2Router（外部合约）
  ↓
  需要 Uniswap 的合约:
  - Stake
  - Launch

前向引用（部署前按 nonce 预测地址）:
  - MemberNFT
  - Vote（Stake 构造时尚未部署）
  - Mint

特殊依赖:
  Launch 构造函数 → 创建 firstToken → MemberNFT 构造函数读取 Launch.FIRST_TOKEN_ADDRESS()
```

## 部署顺序

部署顺序固定为 `Phase → Launch → MemberNFT → Stake → Submit → Vote → Mint`；构造函数不得调用同批部署合约的 getter，因此脚本对 `MemberNFT`、`Vote`、`Mint` 使用 `vm.computeCreateAddress` 预测地址，并在对应合约部署后立即核对。

### 阶段 1: 预测地址

```solidity
// 外部依赖先部署（测试中用 mock），避免其 CREATE 打乱 nonce
UniswapV2Factory factory = new MockUniswapV2Factory();
UniswapV2Router router = new MockUniswapV2Router();
LOVE20Token rootToken = new LOVE20Token(...);  // 作为 rootParentToken

uint256 nonce = vm.getNonce(address(this));
address predictedMember = vm.computeCreateAddress(address(this), nonce + 2);
address predictedVote = vm.computeCreateAddress(address(this), nonce + 5);
address predictedMint = vm.computeCreateAddress(address(this), nonce + 6);
```

### 阶段 2: 按顺序构造

```solidity
// 1. Phase
Phase phase = new Phase(100, 1000, 3600, 10, 50);

// 2. Launch：构造函数创建首币，构造函数内只有这一次 CREATE
Launch launch = new Launch(LaunchInitParams({
    mintAddress: predictedMint,
    memberNFTAddress: predictedMember,
    rootParentTokenAddress: address(rootToken),
    pairFactoryAddress: address(factory),
    distributor: distributor,
    launchCountThresholdRatio: 1e16,
    maxLaunchCount: 1000,
    tokenSymbolLength: 4,
    launchAmount: 10000,
    maxSupply: 1000000,
    name: "TestCommunity",
    symbol: "TEST"
}));

// 3. MemberNFT：首币地址来自 Launch 的真实返回值
MemberNFT memberNFT = new MemberNFT(..., launch.FIRST_TOKEN_ADDRESS());
require(address(memberNFT) == predictedMember);

// 4. Stake：Vote 尚未部署，使用预测地址
Stake stake = new Stake(
    address(phase), address(memberNFT), predictedVote, address(launch),
    address(router), address(factory), 1, 100, 2.5e15, 2, 5
);

// 5. Submit
Submit submit = new Submit(address(phase), address(stake), address(memberNFT), 5e16);

// 6. Vote
Vote vote = new Vote(address(phase), address(stake), address(submit), address(memberNFT));
require(address(vote) == predictedVote);

// 7. Mint
Mint mint = new Mint(
    address(phase), address(vote), address(submit), address(launch), address(memberNFT),
    5e16, 1e17, 1e17
);
require(address(mint) == predictedMint);
```

## 前向引用的解决

`Stake` 构造时需要 `Vote` 地址，而 `Vote` 在其后部署。解决方式是部署前预测：

1. 起始 nonce 的 `+2` 是 `MemberNFT`，`+5` 是 `Vote`，`+6` 是 `Mint`（`Launch` 构造函数内创建首币使用的是 `Launch` 自身 nonce，不消耗部署者 nonce）
2. 预测值与真实部署地址必须一致，不一致说明中间插入了其他 CREATE，部署脚本立即失败
3. 构造函数只保存地址、不调用同批合约 getter，因此预测地址在部署前是安全的

## 测试策略

### Mock 外部依赖
- MockUniswapV2Factory
- MockUniswapV2Router
- 创建一个 rootParentToken (LOVE20Token)

### 真实合约集成
- Phase, MemberNFT, Mint, Vote, Submit, Stake, Launch
- 全部用真实合约
- 按照上述固定顺序部署

### 测试场景
1. 完整治理流程: 投票 → 准备奖励 → 领取奖励
2. 多轮次批量领取
3. Launch count 触发
4. 跨合约权限验证
5. 状态同步验证
