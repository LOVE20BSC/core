# Real Contract Integration Tests

这个目录包含使用真实合约的集成测试，验证 Mint 合约与其他核心合约的实际交互。

## 测试策略

### 为什么使用真实合约？

根据用户明确要求："集成测试不就是应该完全用真实合约来一个真实流程吗？"

集成测试应该：
- ✅ 使用真实合约进行内部依赖测试
- ✅ 仅在系统边界使用 mock（外部系统如 Uniswap）
- ✅ 验证真实的跨合约交互和状态转换
- ✅ 发现实际集成中的问题

### Mock vs Real 的界限

**真实合约** (内部依赖):
- Phase - 轮次管理
- Vote - 投票记录
- Submit - 提案管理
- Stake - 质押和 boost
- Launch - Token 创建
- Mint - 奖励系统 (被测合约)
- MemberNFT - 成员身份

**Mock 合约** (系统边界):
- MockUniswapV2Factory - 外部 DEX
- MockUniswapV2Router - 外部 DEX
- MockUniswapV2Pair - 外部 DEX
- LOVE20Token (rootToken) - 测试用根 token

## 测试文件

### MintRealIntegration.t.sol

完整的治理流程集成测试：

**testRealIntegration_FullGovernanceFlow** (3.18M gas)
- 使用 nonce 预测 + 构造函数注入部署所有真实合约
- 解决 Vote ↔ Stake 前向引用
- 测试完整流程：质押 → 提案 → 投票 → 推进轮次 → 准备奖励 → 领取奖励
- 验证所有跨合约集成点

**关键集成点**:
```
Mint ↔ Vote: 获取投票数据
Mint ↔ Submit: 获取提案目标
Mint ↔ Phase: 检查轮次状态
Mint ↔ MemberNFT: 验证成员所有权
Mint ↔ Launch: 更新 launch count
Vote ↔ Stake: 获取 boost 数据
Submit ↔ Stake: 验证提案资格
```

## 依赖关系

详见 [DEPENDENCIES.md](./DEPENDENCIES.md)

## 部署顺序

固定顺序为 `Phase → Launch → MemberNFT → Stake → Submit → Vote → Mint`。

```solidity
// 阶段 1: 先部署 mock 外部依赖（避免 CREATE 打乱 nonce）
factory = new MockUniswapV2Factory();
router = new MockUniswapV2Router();
rootToken = new LOVE20Token(...);

// 预测三处前向引用（相对起始 nonce 的 +2 / +5 / +6）
uint256 nonce = vm.getNonce(address(this));
address predictedMember = vm.computeCreateAddress(address(this), nonce + 2);
address predictedVote = vm.computeCreateAddress(address(this), nonce + 5);
address predictedMint = vm.computeCreateAddress(address(this), nonce + 6);

// 阶段 2: 按顺序构造
phase = new Phase(100, 1000, 3600, 10, 50);
launch = new Launch(...);                                          // 1. 创建首币
memberNFT = new MemberNFT(..., launch.FIRST_TOKEN_ADDRESS());       // 2. 真实首币地址
stake = new Stake(..., predictedVote, ...);                        // 3. Vote 尚未部署
submit = new Submit(address(phase), address(stake), address(memberNFT), 5e16);
vote = new Vote(address(phase), address(stake), address(submit), address(memberNFT));
mint = new Mint(address(phase), address(vote), address(submit), address(launch), address(memberNFT), 5e16, 1e17, 1e17);

require(address(memberNFT) == predictedMember);
require(address(vote) == predictedVote);
require(address(mint) == predictedMint);
```

## 运行测试

```bash
# 运行所有真实集成测试
forge test --match-path test/integration/MintRealIntegration.t.sol

# 运行特定测试
forge test --match-test testRealIntegration_FullGovernanceFlow -vvv

# 查看 gas 报告
forge test --match-path test/integration/MintRealIntegration.t.sol --gas-report
```

## 测试结果

```
Ran 1 test for test/integration/MintRealIntegration.t.sol:MintRealIntegrationTest
[PASS] testRealIntegration_FullGovernanceFlow() (gas: 3176815)
Suite result: ok. 1 passed; 0 failed; 0 skipped
```

## 关键发现

1. **Round 0 限制**: Round 0 不允许质押，测试需要先推进区块
2. **RootToken 需求**: Stake.stakeLiquidity 需要 rootToken (parentToken) 余额
3. **Uniswap Mock**: MockUniswapV2Pair 必须实现 totalSupply(), mint(), burn() 方法
4. **前向引用解决**: Vote ↔ Stake 通过 nonce 预测 + 构造函数注入解决

## 补充测试

Mock 集成测试 (`test/MintIntegration.t.sol`) 补充真实合约测试：
- 10 个边界条件和极端场景测试
- 使用增强型 mock 进行精确状态控制
- 测试恰好阈值、零投票、跨轮领取等场景
- 两种策略互为补充，提供全面覆盖
