# LOVE20BSC Core 安全审计报告

- 日期：2026-09-28
- 审计版本：`core@93998fa6127699b11256e7fee183c57826f2b41d`
- 范围：`core/src` 的 8 个合约、13 个接口及其直接使用的 `libs`；涉及兑换和建池时使用同一工作区的原版 Uniswap V2
- 结论（修复前）：发现 **1 项严重、1 项高危、1 项中危**。三项均已在当前工作树修复，并通过回归测试。

## 修复状态

| 编号 | 修复内容 | 状态 |
| --- | --- | --- |
| C-01 | `Stake` 只接受 `Launch.isLOVE20Token` 登记的代币，并由固定 `launchAddress` 提供登记来源 | 已修复 |
| H-01 | `Launch` 创建 Pair 前先读取 Factory；预先存在的正确 Pair 直接复用 | 已修复 |
| M-01 | `Submit` 先完成推举状态写入再执行回调，`Stake.mergeStake` 直接检查当前 Round 的 Vote 票数和 Submit 推举记录 | 已修复 |

融合规则按产品确认采用“仅当前 Round”：上一 Round 使用过的来源 NFT 在下一 Round 可以再次融合；`submitNewProposal` 的创建回调在推举状态写入后执行。

## 前提和方法

本报告接受项目的无管理员设计：`init` 不限制调用者；发布方核对全部初始化地址和参数，只向社区发布校验正确的实例。因此，单纯的公开 `init` **不是本报告的漏洞**。发布脚本本身不在本次 `core` 审计范围内，其核对是否已落地也未得到独立验证。以下三项发现均不依赖抢先初始化。

审查覆盖八个合约的资产、权限、轮次及奖励调用路径，并检查直接使用的接口和历史索引库。复现使用 [本地测试](../compatibility/test/CoreAuditFindings.t.sol) 连接当前 `core` 源码，部署与 `dex` 固定在相同上游提交的 Uniswap V2 Factory、Pair、Router；Factory 构造参数为零地址，关闭协议抽成。测试用 Factory 的创建字节码与 `dex/build/core/UniswapV2Factory.sol` **逐字节相同**。静态扫描使用 Slither 0.11.3，审查了其与资金、权限和回调有关的提示；未将扫描提示直接计为漏洞。

## 修复前发现概览

| 编号 | 等级 | 结果 | 所在流程 |
| --- | --- | --- | --- |
| C-01 | 严重 | 已复现真实社区代币被转走，原持有人无法提取全部 Boost | Stake 手续费结算 |
| H-01 | 高危 | 已复现已初始化实例的子币发射被预建 Pair 阻断 | Launch 子币发射 |
| M-01 | 中危 | 已复现推举数量超过门槛推导上界；奖励准备成本随数量增长 | Stake 融合、Submit、Vote、Mint |

## C-01 伪造代币可消耗其他社区存放在 Stake 的资产

**位置**：[Stake._requireToken](src/Stake.sol#L419)、[Stake._pairFor](src/Stake.sol#L440)、[Stake._realizeFees](src/Stake.sol#L722)、[Stake._swapParentTokenForToken](src/Stake.sol#L766)。

**根因。** `Stake` 只要求传入合约的 `parentTokenAddress()` 非零，没有要求它是 [Launch 登记的代币](src/Launch.sol#L121)。第一次质押后，`_pairFor` 缓存 Pair；手续费结算仍使用这个 Pair 烧 LP，却重新读取可由伪造代币改变的 `parentTokenAddress()` 决定 Router 要花哪一种资产。所有社区的 Boost 代币实物余额都放在同一个 `Stake` 地址，按社区分开的只是账本。

**复现。** 测试正常初始化六个 `init` 合约以及 `Phase`，由 `Launch` 创建真实社区代币 VIC。独立受害者存入 100 VIC 作为 Boost。攻击者用自己可任意铸造的代币 FA、FC，在真实 Factory 中创建 FC/FA 和 FC/VIC Pair；用 FA、FC 给自己的 FC 质押建池并积累待结手续费，然后把 FC 声称的父币从 FA 改成 VIC。任何人可调用的 `settleFees(FC)` 随后从旧 FC/FA Pair 取出 FA，却通过新申报的 FC/VIC 路径，从 `Stake` 现有 VIC 余额支付兑换。攻击者持有 FC/VIC 的 LP，可取回 Pair 收到的 VIC。

在 `MAX_WITHDRAWABLE_TO_FEE_RATIO = 1000`、原版 V2 交易费率 0.30% 的修复前复现中，受害者的 100 VIC Boost 负债不变，但 `Stake` 的 VIC 余额减少 **9.999999999999999998 VIC**。攻击者取回了资产；受害者等待期满后调用 `withdraw` 回滚。修复后的 [testFakeTokenCannotSpendAnotherCommunityBoost](../compatibility/test/CoreAuditFindings.t.sol#L131) 断言未登记代币被拒绝、受害者余额不减少并可正常提取。

**建议。** `Stake` 应只接受 `Launch.isLOVE20Token(tokenAddress)` 为真的代币，并在使用已缓存 Pair、结算及兑换前核对 Pair 与登记父币的对应关系。修复后以“其他社区的实际代币余额不得被本社区操作减少”为回归断言。仅调整 `amountOutMin` 或结算比例不能修复资产识别错误。

## H-01 预建下一枚代币的 Pair 可阻断子币发射

**位置**：[Launch.launchToken](src/Launch.sol#L139)、[Launch._createToken](src/Launch.sol#L329)、[UniswapV2Factory.createPair](../dex/lib/v2-core/contracts/UniswapV2Factory.sol#L21)。

**根因。** `Launch` 使用普通 `CREATE` 部署代币，下一个代币地址可从 `Launch` 地址和部署 nonce 算出。原版 Factory 的 `createPair(tokenA, tokenB)` 不要求两个地址已经有代码。攻击者可在子币发射交易前，为“下一个代币地址 / 所选父币”先创建 Pair。`Launch` 部署出该代币后，无条件再次调用 `createPair`，因 `PAIR_EXISTS` 回滚；新币部署和发射次数扣减都随交易回滚，所以重试仍面对同一个可预测地址和已存在的 Pair。

**修复前复现。** 测试在首币和所有依赖正常初始化之后，另一账户预建下一地址与首币的 Pair；旧实现发射以 `UniswapV2: PAIR_EXISTS` 回滚。修复后的 [testPrecreatedPairDoesNotBlockChildLaunch](../compatibility/test/CoreAuditFindings.t.sol#L172) 断言 Launch 复用该 Pair、正常部署子币并消耗发射次数。

**建议。** 创建代币后读取 Factory 的现有 Pair；不存在时创建，已存在时验证确属该代币和父币并复用。配套测试须覆盖预建 Pair、正常新建 Pair 和错误 Pair 状态。改用另一个可预测的代币地址算法本身不能解决抢先建池。

## M-01 质押融合使每轮提案数不受票权门槛的静态上界约束

**位置**：[Submit.canSubmit](src/Submit.sol#L64)、[Stake.mergeStake](src/Stake.sol#L244)、[Vote._vote](src/Vote.sol#L250)、[Mint._calculateEligibleProposalVotes](src/Mint.sol#L330)。

**根因。** `canSubmit` 检查的是调用当刻该 `memberId` 的票权占比。每个成员每轮仅推举一次，但 `mergeStake` 只禁止合并本轮**已投票**的来源成员，没有禁止合并**已推举**的来源成员。持有多个 NFT 的同一人可在每次推举后把整份质押合并到下一个空 NFT，再以同样票权推举。旧报告把同时达标的成员数量 `floor(1000 / SUBMIT_MIN_PER_THOUSAND)` 当作整轮累计提案上限，该推导忽略了票权的顺次转移。

**修复前根因。** 质押来源在推举后仍可融合到下一 NFT，因此同一份票权可以顺次重复满足推举门槛。修复后的回归覆盖 [当前 Round 推举](../compatibility/test/CoreAuditFindings.t.sol#L192)、[当前 Round 投票](../compatibility/test/CoreAuditFindings.t.sol#L247) 和 [创建回调](../compatibility/test/CoreAuditFindings.t.sol#L221)：当前 Round 已推举或已投票的来源均被拒绝，上一 Round 使用过的来源在下一 Round 可以融合。

**建议。** 明确每轮可承受的提案量并在 `Submit` 写入口设置可验证上限，或阻止本轮已推举成员继续转出对应质押；若产品需要不设上限，则让 `Mint` 分批完成奖励准备。修改前应测量目标链 gas 限额及提案量增长曲线。

## 其他核对结果

| 模块 | 核对结果 |
| --- | --- |
| LOVE20Token | 铸造限于 `minter`，当前总供应受 `maxSupply` 限制；持有人只能销毁自己的余额。未发现独立的无限铸造入口。 |
| MemberNFT | 名称按 UTF-8 **字节**计费，铸造费用转入后销毁；`_safeMint` 的接收者回调在名称和费用状态写入后发生。Unicode 只作 ASCII 大小写归一，符合现有设计。 |
| Launch | 首币及子币由同一 Factory 建池；发射次数先扣后调用外部合约，失败时原子回滚。H-01 是建池地址被抢先占用的问题。 |
| Phase | `sync` 每 Phase 至多记录一次，并只为下一 Phase 写入新长度；未找到已证实的资产或权限攻击路径。 |
| Stake | 份额、解锁、Boost 历史按代币和成员记账；C-01 证明其资产实物并非按社区隔离。正常登记代币使用的 ERC20 和 Pair 均无任意回调。 |
| Submit / Vote | 成员持有权和投票累计额度已检查；Target 回调在对应状态更新后触发，回调失败回滚交易。M-01 发生在两者与 Stake 的跨模块约束上。 |
| Mint | 通过当前 NFT 持有人、已结束轮次和目标地址限制领取；奖励状态在铸币前写入。未找到登记代币绕过 `maxSupply` 的路径；准备阶段有 M-01 的线性成本。 |

部署参数仍需逐项核对。尤其 [Stake.init](src/Stake.sol#L56) 对 `MAX_WITHDRAWABLE_TO_FEE_RATIO` 只校验非零；非零并不等于在原版 V2 的 0.30% 费率下具有经济防护。报告的真实 DEX 复现使用 `1000`，C-01 在该值下依然成立。`getAmountsOut` 取自交易当刻的储备，给结果再乘 `98%` 不能防止事先操纵报价。

## 验证范围

- `core` 常规与模糊测试：排除耗时较长的 Mint 不变量组后，**393 项通过、0 项失败**。
- Mint 不变量组：按缩短配置 **32 轮、每轮 40 次调用**，9 项不变量均通过；未把它等同于项目默认的 256 轮、每轮 500 次调用。
- [修复回归测试](../compatibility/test/CoreAuditFindings.t.sol)：**5 项通过**，覆盖登记代币、预建 Pair、当前 Round 推举/投票、提案创建回调和跨 Round 融合。使用当前 `core` 源码及与 `dex` 同版本的原版 V2；已核对两处 Factory 创建字节码相同。
- Slither 0.11.3：扫描 62 个合约、产生 157 条诊断，未报告 Critical/High；多数属于已知取整、循环、命名或泛化重入提示。C-01 和 H-01 由可运行复现确定，不能因扫描器未报警而排除。
- 未做目标 BSC 链分叉测试、部署脚本验收或实际 MEV 盈利测算；M-01 在目标链达到拒绝服务所需的提案数仍待测量。
