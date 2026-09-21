# Mint 合约测试用例数学模型

本文档独立于代码实现，纯粹基于业务逻辑描述奖励计算的数学模型。测试用例将基于此模型计算期望值，并与合约实际运行结果对比验证。

## 1. 核心参数定义

### 1.1 配置参数
```
ROUND_REWARD_GOV_PER_THOUSAND = 100           // 治理奖励池比例: 10%
ROUND_REWARD_PROPOSAL_PER_THOUSAND = 100      // 提案奖励池比例: 10%
PROPOSAL_REWARD_MIN_VOTE_PER_THOUSAND = 50   // 提案资格阈值: 5%
MAX_GOV_BOOST_REWARD_MULTIPLIER = 2           // Boost 倍数上限: 2x
```

### 1.2 Token 供应参数
```
maxSupply = token.maxSupply()
currentSupply = token.totalSupply()
rewardReserved = 已预留的奖励总额
rewardMinted = 已铸造的奖励总额
rewardBurned = 已销毁的奖励总额
```

## 2. 可用奖励计算

### 2.1 预留可用额
```
reservedAvailable = rewardReserved - rewardMinted - rewardBurned
```

### 2.2 总可用奖励
```
rewardAvailable = (maxSupply - currentSupply) - reservedAvailable
```

## 3. 轮次奖励池准备

每轮准备时从可用奖励中分配：

### 3.1 治理奖励池
```
govRewardAmount = rewardAvailable × (ROUND_REWARD_GOV_PER_THOUSAND / 1000)
                = rewardAvailable × 0.1
```

### 3.2 提案奖励池
```
proposalRewardAmount = rewardAvailable × (ROUND_REWARD_PROPOSAL_PER_THOUSAND / 1000)
                     = rewardAvailable × 0.1
```

### 3.3 更新预留总额
```
rewardReserved += govRewardAmount + proposalRewardAmount
```

## 4. 治理奖励计算（成员奖励）

治理奖励池分为两个子池：

### 4.1 投票奖励池（Vote Pool）
```
votePoolAmount = govRewardAmount / 2
```

**注意**: 使用整数除法，奇数时向下取整，余数归入 boost 池

### 4.2 Boost 奖励池（Boost Pool）
```
boostPoolAmount = govRewardAmount - votePoolAmount
```

### 4.3 成员投票奖励
```
memberVotes = 成员在该轮的总投票数
totalVotes = 该轮所有成员的总投票数

voteReward = (votePoolAmount × memberVotes) / totalVotes
```

**注意**: 整数除法向下取整

### 4.4 成员 Boost 奖励

#### 4.4.1 理论 Boost 奖励
```
memberBoost = 成员在该轮的质押 boost 值
totalBoost = 该轮所有成员的总质押 boost 值

theoreticalBoost = (boostPoolAmount × memberBoost) / totalBoost
```

#### 4.4.2 Boost 上限计算
```
maxBoostReward = voteReward × MAX_GOV_BOOST_REWARD_MULTIPLIER
               = voteReward × 2
```

#### 4.4.3 实际 Boost 奖励
```
boostReward = min(theoreticalBoost, maxBoostReward)
```

#### 4.4.4 超额销毁
```
burnReward = theoreticalBoost - boostReward
```

**池取消规则**:
- 如果 `totalBoost == 0`，则 `boostPoolAmount` 全部销毁：
  ```
  rewardBurned += boostPoolAmount
  ```

### 4.5 成员总奖励
```
totalReward = voteReward + boostReward
```

## 5. 提案奖励计算

### 5.1 提案资格判定

#### 5.1.1 最低票数阈值（向上取整）
```
minVotes = ceil(totalVotes × (PROPOSAL_REWARD_MIN_VOTE_PER_THOUSAND / 1000))
         = ceil(totalVotes × 0.05)
```

#### 5.1.2 提案是否合格
```
isEligible = (proposalVotes >= minVotes) AND (proposalVotes > 0)
```

### 5.2 合格提案总票数
```
eligibleProposalVotes = sum(proposalVotes for all eligible proposals)
```

### 5.3 单个提案奖励（比例分配）
```
proposalReward = (proposalRewardAmount × proposalVotes) / eligibleProposalVotes
```

**注意**: 整数除法向下取整，精度损失归入池中（dust）

**池取消规则**:
- 如果 `eligibleProposalVotes == 0`，则 `proposalRewardAmount` 全部销毁：
  ```
  rewardBurned += proposalRewardAmount
  ```

## 6. 投票权重计算（来自 Stake 合约）

### 6.1 质押投票权
```
govVotes = liquidityShares × promisedWaitingPhases
```

其中：
- `liquidityShares`: 成员质押的流动性份额
- `promisedWaitingPhases`: 承诺的等待轮次数（1-100）

### 6.2 Boost 值
```
memberBoost = stakedBoostOfVotersByMemberId[tokenAddress][round][memberId]
```

由 Vote 合约在投票时记录，来自 Stake 合约的 `govVotes`

## 7. 测试场景数学模型

### 场景 1: 简单两成员投票

**初始状态**:
```
maxSupply = 1,000,000
currentSupply = 50,000
rewardReserved = 0
rewardMinted = 0
rewardBurned = 0
```

**计算**:
```
rewardAvailable = (1,000,000 - 50,000) - 0 = 950,000
govRewardAmount = 950,000 × 0.1 = 95,000
proposalRewardAmount = 950,000 × 0.1 = 95,000

votePoolAmount = 95,000 / 2 = 47,500
boostPoolAmount = 95,000 - 47,500 = 47,500
```

**成员投票**:
```
member1: 100 votes, 5000 boost
member2: 60 votes, 3000 boost
totalVotes = 160
totalBoost = 8000
```

**成员 1 奖励**:
```
voteReward1 = (47,500 × 100) / 160 = 29,687 (整数除法)
theoreticalBoost1 = (47,500 × 5000) / 8000 = 29,687
maxBoostReward1 = 29,687 × 2 = 59,374
boostReward1 = min(29,687, 59,374) = 29,687
burnReward1 = 0
totalReward1 = 29,687 + 29,687 = 59,374
```

**成员 2 奖励**:
```
voteReward2 = (47,500 × 60) / 160 = 17,812 (整数除法)
theoreticalBoost2 = (47,500 × 3000) / 8000 = 17,812
maxBoostReward2 = 17,812 × 2 = 35,624
boostReward2 = min(17,812, 35,624) = 17,812
burnReward2 = 0
totalReward2 = 17,812 + 17,812 = 35,624
```

**验证比例**:
```
投票比例 = 100:60 = 5:3
奖励比例 = 59,374:35,624 ≈ 5:3 ✓
```

### 场景 2: 5% 阈值边界

**投票分布**:
```
totalVotes = 480
proposal1: 24 votes (24/480 = 5.00%)
proposal2: 10 votes (10/480 = 2.08%)
proposal3: 470 votes (470/480 = 97.92%)
```

**阈值计算**:
```
minVotes = ceil(480 × 0.05) = ceil(24.0) = 24
```

**资格判定**:
```
proposal1: 24 >= 24 → 合格 ✓
proposal2: 10 < 24 → 不合格 ✗
proposal3: 470 >= 24 → 合格 ✓
```

**合格票数**:
```
eligibleProposalVotes = 24 + 470 = 494
```

**奖励分配** (假设 proposalRewardAmount = 95,000):
```
proposal1Reward = (95,000 × 24) / 494 = 4,615 (整数除法)
proposal2Reward = 0 (不合格)
proposal3Reward = (95,000 × 470) / 494 = 90,425 (整数除法)
```

### 场景 3: Boost 上限触发

**极端投票分布**:
```
member1: 10 votes, 9000 boost (高 boost 低投票)
member2: 90 votes, 1000 boost (低 boost 高投票)
totalVotes = 100
totalBoost = 10,000
```

**假设** govRewardAmount = 100,000:
```
votePoolAmount = 50,000
boostPoolAmount = 50,000
```

**成员 1**:
```
voteReward1 = (50,000 × 10) / 100 = 5,000
theoreticalBoost1 = (50,000 × 9000) / 10,000 = 45,000
maxBoostReward1 = 5,000 × 2 = 10,000
boostReward1 = min(45,000, 10,000) = 10,000 (触发上限)
burnReward1 = 45,000 - 10,000 = 35,000 (超额销毁)
totalReward1 = 5,000 + 10,000 = 15,000
```

**成员 2**:
```
voteReward2 = (50,000 × 90) / 100 = 45,000
theoreticalBoost2 = (50,000 × 1000) / 10,000 = 5,000
maxBoostReward2 = 45,000 × 2 = 90,000
boostReward2 = min(5,000, 90,000) = 5,000 (未触发上限)
burnReward2 = 0
totalReward2 = 45,000 + 5,000 = 50,000
```

**总销毁**:
```
totalBurned = 35,000
```

### 场景 4: 池取消

#### 4.1 Boost 池取消
当 `totalBoost == 0` 时：
```
boostPoolCancelled = boostPoolAmount
rewardBurned += boostPoolAmount
所有成员: boostReward = 0, burnReward = 0
```

#### 4.2 提案池取消
当 `eligibleProposalVotes == 0` 时（无合格提案）：
```
proposalPoolCancelled = proposalRewardAmount
rewardBurned += proposalRewardAmount
所有提案: proposalReward = 0
```

### 场景 5: 质押流转（Unstake 和 Re-stake）

**Round 1 质押**:
```
stakeLiquidity(5000 tokens, promisedWaitingPhases=1)
liquidityShares1 = f(5000) // 由 Uniswap Pair 计算
govVotes1 = liquidityShares1 × 1
```

**投票**:
```
member1 votes: 100
```

**Unstake**:
```
unstakeLiquidity(全部)
liquidityShares = 0
```

**Round 2 重新质押**:
```
stakeLiquidity(3000 tokens, promisedWaitingPhases=1)
liquidityShares2 = f(3000) // 通常 < liquidityShares1
govVotes2 = liquidityShares2 × 1
```

**投票**:
```
member1 votes: 60 (更少，因为质押少了)
```

**奖励对比**:
```
由于 liquidityShares2 < liquidityShares1
且 govVotes2 < govVotes1
因此 round2Reward < round1Reward
```

### 场景 6: 重复领取保护

**第一次领取**:
```
_govMinted[tokenAddress][round][memberId] = false
mintGovReward(...) → 成功，获得奖励
_govMinted[tokenAddress][round][memberId] = true
```

**第二次领取**:
```
_govMinted[tokenAddress][round][memberId] = true
mintGovReward(...) → revert AlreadyMinted()
```

同理适用于提案奖励：
```
_proposalMinted[tokenAddress][round][proposalId] = true
```

## 8. 精度和舍入规则

### 8.1 向上取整（Ceil）
- 提案最低票数阈值: `minVotes = ceil(totalVotes × 0.05)`

### 8.2 向下取整（Floor，整数除法）
- 所有奖励分配计算使用整数除法
- 投票奖励池: `votePoolAmount = govRewardAmount / 2`
- 成员投票奖励: `voteReward = (votePoolAmount × memberVotes) / totalVotes`
- 提案奖励: `proposalReward = (proposalRewardAmount × proposalVotes) / eligibleProposalVotes`
- Boost 理论值: `theoreticalBoost = (boostPoolAmount × memberBoost) / totalBoost`

### 8.3 精度损失（Dust）
由于整数除法向下取整，部分奖励无法完全分配，形成 "dust" 留在池中：
```
实际分配总和 < 池总额
差额 = dust（留在池中，不会销毁也不会铸造）
```

## 9. 测试验证原则

### 9.1 精确值验证
对于可精确计算的值，测试必须使用 `assertEq` 进行精确匹配：
```solidity
assertEq(actualValue, expectedValue, "描述");
```

### 9.2 比例验证
对于有精度损失的比例分配，验证相对比例关系：
```solidity
// 投票比例 100:60 = 5:3
assertEq(voteReward1 * 3, voteReward2 * 5, "Vote rewards should match 5:3 ratio");
```

### 9.3 不等式验证
对于上限和下限约束：
```solidity
assertTrue(boostReward <= maxBoostReward, "Boost should not exceed cap");
assertTrue(boostReward <= theoreticalBoost, "Boost should not exceed theoretical");
```

### 9.4 独立计算
测试中的期望值必须独立于合约代码计算，直接使用本文档中的数学公式。

## 10. 常见测试陷阱

### 10.1 ❌ 错误：只验证大小关系
```solidity
assertTrue(voteReward1 > voteReward2, "Member1 should get more");
```

### 10.2 ✅ 正确：验证精确比例
```solidity
uint256 expectedRatio = (memberVotes1 * 1e18) / memberVotes2;
uint256 actualRatio = (voteReward1 * 1e18) / voteReward2;
assertEq(actualRatio, expectedRatio, "Rewards should match vote ratio");
```

### 10.3 ❌ 错误：从合约读取期望值
```solidity
uint256 expected = mint.govRewardByMemberId(...); // 错误！
assertEq(actual, expected, "Should match");
```

### 10.4 ✅ 正确：独立计算期望值
```solidity
uint256 votePoolAmount = govRewardAmount / 2;
uint256 expected = (votePoolAmount * memberVotes) / totalVotes;
assertEq(actual, expected, "Should match calculated value");
```
