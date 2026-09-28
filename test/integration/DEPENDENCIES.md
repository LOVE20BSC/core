# 合约依赖关系分析

## 实际集成测试完成 ✅

**状态**: `test/integration/MintRealIntegration.t.sol` 已完成并通过测试
- **测试**: `testRealIntegration_FullGovernanceFlow()` 
- **Gas 消耗**: 3,176,815
- **结果**: PASS ✅

## Init 函数签名

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
**依赖**: 无（构造函数，不需要其他合约地址）

### MemberNFT
```solidity
function init(address firstTokenAddress) external
```
**依赖**: LOVE20Token 地址（由 Launch.init() 内部创建并传入）

### Mint
```solidity
function init(
    address voteAddress_,
    address submitAddress_,
    address launchAddress_,
    address memberNFTAddress_,
    uint256 proposalRewardMinVotePerThousand_,
    uint256 roundRewardGovPerThousand_,
    uint256 roundRewardProposalPerThousand_,
    uint256 maxGovBoostRewardMultiplier_
) external
```
**依赖**: Vote, Submit, Launch, MemberNFT

### Vote
```solidity
function init(
    address phaseAddress_,
    address stakeAddress_,
    address submitAddress_,
    address memberNFTAddress_,
    address mintAddress_
) external
```
**依赖**: Phase, Stake, Submit, MemberNFT, Mint

### Submit
```solidity
function init(
    address phaseAddress_,
    address stakeAddress_,
    address memberNFTAddress_,
    uint256 submitMinPerThousand
) external
```
**依赖**: Phase, Stake, MemberNFT

### Stake
```solidity
function init(
    address phaseAddress_,
    address memberNFTAddress_,
    address voteAddress_,
    address launchAddress_,
    address routerAddress_,
    address pairFactoryAddress_,
    uint256 promisedWaitingPhasesMin,
    uint256 promisedWaitingPhasesMax,
    uint256 maxWithdrawableToFeeRatio
) external
```
**依赖**: Phase, MemberNFT, Vote, Launch, UniswapV2Router, UniswapV2Factory

### Launch
```solidity
function init(LaunchInitParams calldata params) external
// params 包含:
// - mintAddress
// - memberNFTAddress
// - rootParentTokenAddress
// - pairFactoryAddress
// - distributor
// - 其他配置参数
```
**依赖**: Mint, MemberNFT, rootParentToken, UniswapV2Factory
**特殊**: Launch.init() 会创建第一个 LOVE20Token 并调用 MemberNFT.init()

## 依赖图

```
Phase (constructor, 无依赖)
  ↓
  需要 Phase 的合约:
  - Vote
  - Submit  
  - Stake

UniswapV2Factory (外部合约)
UniswapV2Router (外部合约)
  ↓
  需要 Uniswap 的合约:
  - Stake
  - Launch

循环依赖:
  Vote ←→ Stake
  (Vote 需要 Stake, Stake 需要 Vote)

特殊依赖:
  Launch.init() → 创建 firstToken → MemberNFT.init(firstToken)
```

## 初始化顺序

### 阶段 1: 部署所有合约（new）
```solidity
Phase phase = new Phase(100, 1000, 3600, 10, 50);
MemberNFT memberNFT = new MemberNFT(...);
Mint mint = new Mint();
Vote vote = new Vote();
Submit submit = new Submit();
Stake stake = new Stake();
Launch launch = new Launch();

// 外部依赖（测试中用 mock）
UniswapV2Factory factory = new MockUniswapV2Factory();
UniswapV2Router router = new MockUniswapV2Router();
LOVE20Token rootToken = new LOVE20Token(...);  // 作为 rootParentToken
```

### 阶段 2: 初始化（init）

**关键**: Launch.init() 会创建第一个 token 并初始化 MemberNFT，所以要先调用它

```solidity
// 1. 先初始化 Launch（它会创建 firstToken 并初始化 MemberNFT）
launch.init(LaunchInitParams({
    mintAddress: address(mint),
    memberNFTAddress: address(memberNFT),
    rootParentTokenAddress: address(rootToken),
    pairFactoryAddress: address(factory),
    distributor: distributor,
    launchRatio: 1e16,
    maxLaunchCount: 1000,
    tokenSymbolLength: 4,
    launchAmount: 10000,
    maxSupply: 1000000,
    name: "TestCommunity",
    symbol: "TEST"
}));
// 此时 MemberNFT 已被 Launch 初始化

// 2. 初始化 Submit（只依赖 Phase, Stake, MemberNFT）
submit.init(
    address(phase),
    address(stake),
    address(memberNFT),
    50  // submitMinPerThousand: 5%
);

// 3. 初始化 Stake（依赖 Phase, MemberNFT, Vote, Launch, Router, Factory）
stake.init(
    address(phase),
    address(memberNFT),
    address(vote),
    address(launch),
    address(router),
    address(factory),
    1,    // promisedWaitingPhasesMin
    100,  // promisedWaitingPhasesMax
    10    // maxWithdrawableToFeeRatio
);

// 4. 初始化 Vote（依赖 Phase, Stake, Submit, MemberNFT, Mint）
vote.init(
    address(phase),
    address(stake),
    address(submit),
    address(memberNFT),
    address(mint)
);

// 5. 最后初始化 Mint（依赖 Vote, Submit, Launch, MemberNFT）
mint.init(
    address(vote),
    address(submit),
    address(launch),
    address(memberNFT),
    50,   // proposalRewardMinVotePerThousand: 5%
    100,  // roundRewardGovPerThousand: 10%
    100,  // roundRewardProposalPerThousand: 10%
    2     // maxGovBoostRewardMultiplier: 2x
);
```

## 循环依赖的解决

Vote ←→ Stake 的循环依赖通过**先 new 再 init** 的方式解决：

1. `Vote vote = new Vote()` 和 `Stake stake = new Stake()` 都先创建出来
2. Stake.init() 时传入 `address(vote)` - 此时 Vote 还未初始化，但地址已存在
3. Vote.init() 时传入 `address(stake)` - 此时 Stake 已经初始化完成
4. 两个合约都可以正常调用对方的接口

## 测试策略

### Mock 外部依赖
- MockUniswapV2Factory
- MockUniswapV2Router  
- 创建一个 rootParentToken (LOVE20Token)

### 真实合约集成
- Phase, MemberNFT, Mint, Vote, Submit, Stake, Launch
- 全部用真实合约
- 按照上述顺序初始化

### 测试场景
1. 完整治理流程: 投票 → 准备奖励 → 领取奖励
2. 多轮次批量领取
3. Launch count 触发
4. 跨合约权限验证
5. 状态同步验证
