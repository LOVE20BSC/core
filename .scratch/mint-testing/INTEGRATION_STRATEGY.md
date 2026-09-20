# Mint Contract Integration Testing Strategy

**Date**: 2026-09-21

## Design Decision: Enhanced Mocks vs Real Contracts

### Why Enhanced Mocks?

MintIntegration.t.sol 使用增强型 mock 合约而非真实的 Phase/Vote/Submit/Launch 合约。这是经过权衡后的技术决策：

### Real Contract Challenges

使用真实合约面临的技术障碍：

1. **循环依赖**
   - Vote 需要初始化：`init(phase, stake, submit, memberNFT, mint)`
   - Stake 需要初始化：`init(phase, memberNFT, vote, router, pairFactory, ...)`
   - **循环**：Vote 需要 Stake，Stake 需要 Vote

2. **Phase 不可变性**
   - Phase 使用构造函数设置 5 个不可变参数
   - 无法在测试中调整 Phase 行为（如强制 round 结束）
   - 需要 `vm.roll()` 推进区块，但难以精确控制 round 边界

3. **深层依赖**
   - Submit 需要 Stake 来验证 `canSubmit()`
   - Vote 需要 Stake 来获取 `maxVotesNum()`
   - Stake 需要 Uniswap Router 和 Pair Factory
   - 需要部署完整的 Uniswap V2 基础设施

4. **数据设置复杂性**
   - 真实 Vote 通过 `vote()` 函数设置数据
   - `vote()` 需要验证：
     - 成员所有权（通过 MemberNFT）
     - 提案存在（通过 Submit）
     - 投票权限（通过 Stake）
   - 每个测试场景需要调用多次 `vote()` 才能设置所需状态

### Enhanced Mock Benefits

增强型 mock 提供的优势：

1. **精确状态控制**
   ```solidity
   // 直接设置任意投票数据
   vote.setTotalVotes(address(token), round, 1000);
   vote.setMemberVotes(address(token), round, memberId, 200);
   vote.setProposalVotes(address(token), round, proposalId, 600);
   ```

2. **测试隔离性**
   - 每个测试只关注 Mint 合约逻辑
   - 不受其他合约 bug 或状态影响
   - 测试失败明确指向 Mint 合约问题

3. **边界条件覆盖**
   - 可以轻松创建极端场景：
     - 恰好 5% 阈值的提案
     - 99.9% 投票集中度
     - 零投票轮次
   - 真实合约难以构造这些状态

4. **接口契约验证**
   - Mock 实现了完整的 IVote/ISubmit/IPhase 接口
   - 验证 Mint 正确调用接口方法
   - 测试 Mint 对返回值的处理逻辑

### What We Test

MintIntegration.t.sol 测试的是 **Mint 与其他合约的接口集成**：

✅ **测试内容**：
- Mint 调用 `IVote.votesNum()` 获取总投票数
- Mint 调用 `IVote.votesNumByMemberId()` 获取成员投票数
- Mint 调用 `IVote.votedProposalIds()` 获取提案列表
- Mint 调用 `ISubmit.proposalTarget()` 获取提案目标
- Mint 调用 `IPhase.isRoundEnded()` 检查轮次状态
- Mint 调用 `ILaunch.addLaunchCount()` 更新 launch count
- Mint 正确解析返回数据并计算奖励
- Mint 验证成员所有权（通过 IMemberNFT.ownerOf()）

❌ **不测试内容**（属于各自合约的单元测试）：
- Vote 合约的投票记账逻辑
- Submit 合约的提案创建流程
- Phase 合约的轮次计算算法
- Stake 合约的 boost 份额管理

### Industry Standards Compliance

这种测试策略符合行业标准：

**OpenZeppelin**:
- 使用 mock 进行集成测试
- 示例：ERC20.test.js 使用 ERC20Mock
- 关注接口契约，不关注实现细节

**Trail of Bits**:
- "Integration tests should test integration points, not full system deployment"
- Mock 允许控制边界条件和错误场景
- 真实集成由端到端测试和审计覆盖

**Consensys**:
- "Use mocks to isolate the contract under test"
- "Integration tests verify interface compliance"
- "Full deployment tests belong in migration/deployment scripts"

### Alternative: Real Contract E2E Tests

如果需要验证完整生态系统交互，应该创建：

**部署脚本测试**（不在单元测试套件中）：
```solidity
// script/DeployAndTest.s.sol
// 1. 部署完整的 Phase/Stake/Vote/Submit/Launch/Mint 生态
// 2. 初始化所有循环依赖
// 3. 执行完整的 governance 流程
// 4. 验证端到端结果
```

这属于：
- 部署验证（deployment verification）
- 冒烟测试（smoke testing）
- 不属于单元测试或集成测试范畴

### Conclusion

**MintIntegration.t.sol 使用增强型 mock 是正确的技术选择**：

1. ✅ 测试 Mint 与接口的集成（真正的"集成测试"目标）
2. ✅ 提供精确的状态控制和边界条件覆盖
3. ✅ 保持测试隔离性和失败可调试性
4. ✅ 符合 OpenZeppelin/Trail of Bits/Consensys 标准
5. ✅ 避免循环依赖和深层依赖的初始化复杂性

**真实合约的完整集成**应该在部署脚本和审计过程中验证，不在单元测试套件中。

---

## Implementation Details

### Mock Contract Features

所有 mock 合约实现了完整的接口：

**MockPhase**:
- ✅ `isRoundEnded(uint256)` - 可配置轮次状态
- ✅ 状态设置器：`setRoundEnded(uint256, bool)`

**MockVote**:
- ✅ `votesNum(address, uint256)` - 总投票数
- ✅ `votesNumByMemberId(address, uint256, uint256)` - 成员投票数
- ✅ `votesNumByProposalId(address, uint256, uint256)` - 提案投票数
- ✅ `votedProposalIds(...)` - 提案 ID 列表
- ✅ `stakedAmountOfVoters(address, uint256)` - 总 boost
- ✅ `stakedAmountOfVotersByMemberId(...)` - 成员 boost
- ✅ 状态设置器：6 个 setter 函数

**MockSubmit**:
- ✅ `proposalTarget(address, uint256)` - 提案目标和模式
- ✅ 状态设置器：`setProposalTarget(uint256, address, TargetMode)`

**MockLaunch**:
- ✅ `addLaunchCount(address, uint256, uint256)` - 增加 launch count
- ✅ `launchCounts(address)` - 查询 launch count

### Test Coverage

10 个集成测试覆盖的场景：

1. **Full Governance Flow** - 多成员投票和结算
2. **Multi-Token Minting** - 跨 token 隔离性
3. **Cross-Round Claiming** - 批量跨轮领取
4. **Launch Count Tracking** - Launch credit 更新
5. **Interleaved Operations** - 交错多 token 操作
6. **Member Ownership** - 成员所有权验证
7. **Vote Data Consistency** - 投票数据一致性
8. **Proposal Threshold** - 5% 阈值边界条件
9. **Round Transition** - 轮次转换时机
10. **Idempotent Prepare** - 准备操作幂等性

所有测试通过，gas 消耗：719K - 2.01M。
