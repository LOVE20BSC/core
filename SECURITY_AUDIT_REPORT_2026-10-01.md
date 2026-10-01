# LOVE20BSC Core 审计报告与修复记录

审计日期：2026-10-01（Asia/Shanghai）

基线提交：`274f89714177d137f1826e7ee16d47c06a2fc3f5`

复核对象：上述提交及本次尚未提交的合约、部署、测试修复。

## 结论

已修复构建、压力测试和部署交付问题，并按用户确认实施零 LP 提取的最小修复、Mint/Launch 初始化上界和每个代币每轮最多推举 1,000 个提案的限制。Mint 单轮准备扫描因此最多 1,000 项，无需增加分批机制；0.3% 推举门槛自身仍不能提供每轮 333 个提案的硬上限。LP 非零但双币产出舍入为零的路径也未扩大处理范围。

生产合约仅改动 `Stake.sol`、`Mint.sol`、`Launch.sol` 的上述分支和 `Submit.sol` 的一条共同入口上限检查；自有接口、事件、存储布局均未新增或修改，BSC 对应规格和验收同步更新。没有执行公共网络广播、实际开源验证、修改线上部署或读取真实账户凭据。

测试通过说明对应断言成立，不代表所有风险消失。零 LP 回归测试已从复现失败改为验证 Boost 归还、头寸清理和剩余资产账本保持正确；目标链部署及真实 Pair 场景仍须单独验收。

## 范围与方法

覆盖八个核心合约：LOVE20Token、MemberNFT、Phase、Stake、Submit、Vote、Mint、Launch；以及自有接口、部署与验收脚本、网络配置、现有单元/集成/fuzz/invariant 测试、依赖和编译配置。

设计依据仅为 BSC 仓库的协议规格、迁移规范及当前实现，不采用 TKM 版技能资料推断 BSC 行为。规格与实现差异经过协议语义核对后分类，不自动认定为漏洞。

方法包括调用链审查、权限与资金路径核对、整数舍入分析、真实 Core 合约压力测试、隔离的部署脚本失败注入、编译与全量测试。DEX 压力场景使用仓库已有模拟 Pair/Router，没有将模拟结果当作 BSC 实盘数据。既有 [DEX 兼容性报告](/Users/BigPolarBear/Documents/github/LOVE20BSC/compatibility/results/compatibility-report.md) 只作为历史证据，本次没有重跑它的链上探针。

当前 DEX 以 [dex/README.md](/Users/BigPolarBear/Documents/github/LOVE20BSC/dex/README.md:1) 和固定的官方 Uniswap V2 源码为准：自行部署、交易手续费 0.30%、`feeTo` 与 `feeToSetter` 均为零，永久关闭协议抽成。兼容性目录的旧 PancakeSwap 费率不代表当前目标 DEX。本次曾据旧资料加入 `DEX_FEE_BPS` 配置及关联门禁，现已全部撤回；原 `MAX_WITHDRAWABLE_TO_FEE_RATIO=1000` 未改。

严重性按潜在影响与触发条件评定；发布流程的“高风险”不等于已经存在可盗取资产的高危漏洞。

## 发现总表

| 编号 | 级别 / 类型 | 问题 | 当前状态 |
| --- | --- | --- | --- |
| F-01 | 高 / 资产可用性 | 极小 LP 份额提取回滚，连带阻塞 Boost | 零 LP 最小修复完成；非零 LP 的双币舍入限制保留 |
| F-02 | 中 / 经济与可用性 | 逐个推举、投票后解锁可累积有票提案，Mint 无界扫描 | 已按确认限制每个代币每轮 1,000 个；保留名额占满与批量调用风险 |
| F-03 | 高 / 发布门禁 | 压力测试接口失配，阻断完整构建与测试，且未实际调用 Mint | 已修复 |
| F-04 | 高 / 部署验收 | permissionless init 的最终验收遗漏绑定和常量 | 已修复 |
| F-05 | 中 / 部署执行 | 不核对实际 chain ID，公共 RPC 错用解锁账户签名 | 已修复 |
| F-06 | 中 / 开源验证 | 验证失败仍可能报告成功，构造参数引用不存在的 MINTER | 已修复 |
| F-07 | 高 / 凭据与部署 | 旧测试网入口可能打印明文私钥，且配置不完整 | 已通过统一入口修复 |
| F-08 | 中 / 外部依赖 | 未校验 Router.WETH 与配置 WBNB 相等 | 已修复 |
| F-09 | 低 / 配置防护 | Mint/Launch 初始化接受范围比部署验收更宽 | 已按确认补齐合约上界和广播前门禁 |

这里“已修复”指本地工作区修复及对应回归通过，不代表已合并或已部署。

## F-01：极小 LP 份额导致正常提取回滚

位置：[Stake.sol](/Users/BigPolarBear/Documents/github/LOVE20BSC/core/src/Stake.sol:657)、[withdraw](/Users/BigPolarBear/Documents/github/LOVE20BSC/core/src/Stake.sol:207)。回归：[Stake 测试](/Users/BigPolarBear/Documents/github/LOVE20BSC/core/test/Stake.t.sol:863)。

本金提取先按下式折算 LP：

```text
lpAmount = floor(member.liquidityShares * global.lastWithdrawableLp / global.totalLiquidityShares)
```

手续费重分类会降低可提取 LP 基数。当某成员只持有很少份额时，结果可能为零。基线代码仍把零 LP 转入 Pair 并调用 `burn`，导致整笔回滚。Boost 转回发生在这一步之后，因此同样无法取回。

最小复现使用现有 MockPair：先形成较大质押，再创建 1 个 LP 份额的小头寸，附加 `1e18` Boost，向池子双边各增加 1001 个最小单位并同步模拟储备。修复前到达等待期后的 `withdraw` 因零 LP 销毁失败；修复后相同场景成功，回归确认 Boost 全额归还、头寸清理、只移除退出份额及 Boost 负债，可提取 LP 和实际 LP 余额不减。

限制：MockPair 在零 LP 时使用 `INSUFFICIENT_LIQUIDITY`，官方 V2 Pair 在双币产出为零时回滚 `INSUFFICIENT_LIQUIDITY_BURNED`。本次尚未在目标链真实 Pair 上重放这个完整场景。

按用户确认只实施最小修复：零 LP 时跳过本金的 Pair 转账与 burn，权限、等待期及先结算手续费的顺序不变。退出者放弃不足一个 LP 最小单位的尾差，余量留在可提取 LP 总账，由剩余份额承接；复用现有 `Withdraw`，双币数量为零。

未新增直接领取 LP 的入口。因此 LP 非零但某侧双币产出舍入为零、或手续费结算失败，仍可能让整笔提取回滚；不能把零 LP 修复表述为所有退出可用性问题均已关闭。

## F-02：有票提案数量无界增长，已增加每轮推举上限

位置：[Submit.canSubmit](/Users/BigPolarBear/Documents/github/LOVE20BSC/core/src/Submit.sol:64)、[Stake.unstake](/Users/BigPolarBear/Documents/github/LOVE20BSC/core/src/Stake.sol:174)、[Mint 扫描](/Users/BigPolarBear/Documents/github/LOVE20BSC/core/src/Mint.sol:334)。

推举门槛以当前活跃票权占比计算。成员推举、投票后申请解锁，会立即从全局活跃票权中扣除自身权重，但该轮的推举和投票记录保留。攻击者可用不同 NFT 和新增质押反复执行，不能据此假设每新增一份提案都需要几何增长的活跃资本。

这里扫描的是 Vote 记录的**有票提案**，不是所有曾创建的提案。构造增长必须包含实际投票。资金仍要满足等待期，每个身份仍有铸造和交易成本，不是同一笔资金在一轮内免费反复使用。

新 [压力测试](/Users/BigPolarBear/Documents/github/LOVE20BSC/core/test/stress/ProposalDoS.t.sol:80) 使用真实八个 Core 合约，逐个执行“铸造身份 → 质押 → 推举 → 投票 → 申请解锁”，确认全局活跃票权归零，同时 Vote 的记录持续累积。轮次用区块高度推进，随后真正调用治理及 Proposal 奖励领取。以下是加入推举上限前的边界探测记录，超过 1,000 个的场景不再能通过当前推举入口构造。

| 有票提案数 | 首次 mint 调用消耗 gas |
| --- | ---: |
| 10 | 399,276 |
| 300 | 2,238,979 |
| 1000 | 6,698,974 |
| 2000 | 13,113,560 |
| 2550 | 16,663,228 |
| 2600 | 16,986,686 |

历史构建阶段暂停测试 gas 计量，避免把许多现实交易挤进一笔测试调用的预算；测量 Mint 前恢复计量并将相关账户/存储标为冷访问。表中包含首次奖励准备与领取的执行成本，不含现实交易固有 gas，不代表 BSC 的交易或区块上限。

表中消耗使用相同编译配置及 `--isolate` 测得，给首次 Mint 显式传入执行预算。2,550 个在 16,750,000 gas 执行预算内通过；2,600 个在该预算的常规测试中回滚，放宽本地预算至 30,000,000 后完成并测得表中消耗。根据 [BSC 官方 Mendel 升级说明](https://docs.bnbchain.org/announce/mendel-bsc/) 和 [BEP-652](https://github.com/bnb-chain/BEPs/blob/master/BEPs/BEP-652.md)，主网于 2026-04-28、测试网于 2026-03-24 启用 16,777,216 gas 单笔交易硬上限，独立于区块 gas 上限。16,750,000 是为交易固有开销预留空间的本地执行预算，不是链上常量；测量也不是 BSC 实际交易回执。

上限加入前，该样本的结算边界约在 2,550～2,600 个之间，并未逐个搜索精确最大值。样本奖励门槛为 5%，1,000 个以上时仅首个提案达标，首次治理奖励领取未涉及 Boost 奖励或新增发射次数；参数、领取入口、调用包装及存储状态会改变消耗，不能把这一边界作为所有状态的安全上限。

用户补充：推举门槛预计不低于 0.3%，一年实验中的实际提案量比 333 还低一个数量级；该运行数据为用户提供，本次未独立核验。最终按用户确认采用 1,000 个硬上限，不增加分批改造。

这里的门槛是 `SUBMIT_MIN_PER_THOUSAND >= 3`，不是 Mint 的奖励门槛。`floor(1 / 0.003) = 333` 只约束固定同一组票权下同时达标的成员，不能约束动态分母下一整轮的累计推举数。以 1% 为例：背景活跃票权 9900，新 NFT 投入 100 票后占 1%，推举、投票后申请解锁使总量退回 9900，下一 NFT 可投入另一份 100 票重复；退出中的资产依然锁定，提案和投票记录不会删除。现有压力测试在更严格的 1% 推举门槛下实际构造了 1000 个有票提案。后续判断应看每轮有票提案数、首次铸造 gas 及新增锁定资本成本；若要增加分批机制，需另行确认设计。

已按确认实施**每个代币每轮最多推举 1,000 个提案**：在 [Submit._submitByProposalId](/Users/BigPolarBear/Documents/github/LOVE20BSC/core/src/Submit.sol:252) 的共同入口检查 `_submits[tokenAddress][round].length >= 1000`，复用 `CannotSubmitAction()` 回滚，同时覆盖新提案推举和旧提案再次推举。有票提案必先经过本轮推举，因此 Mint 单轮扫描最多 1,000 项，不截断任何合法票数。`canSubmit` 保持票权门槛查询语义；实际写入口额外检查去重、成员名额和总数。不增加可调参数、存储字段或 ABI。

回归验证第 1,000 个允许，第 1,001 个新旧推举均被拒绝，失败创建及作者索引回滚、成员名额不消耗；下一轮新旧推举和其他代币均成功，历史总数可以超过 1,000。当前 1,000 个有票提案的首次准备与治理领取测得 6,699,064 gas（`--isolate`），通过固定 8,000,000 gas 执行预算，随后 Proposal 领取与预留账本检查通过。

该方案的代价是名额先到先得，恶意占满可阻止同代币本轮后续推举；已推举提案可继续投票和领取，下一轮及其他代币独立计数。它针对单轮扫描导致的 gas 风险，不能保证任意多轮批量领取或任意扩展回调均不超 gas。

当前回归复现（在 `core` 执行）：

```bash
forge test --match-test testSubmissionLimitPerTokenAndRound -vv
forge test --match-contract ProposalDoSTest --isolate -vv
```

## F-03：压力测试无法编译且原 gas 测量无效

基线的 `ProposalDoS.t.sol` 对 `MemberNFT.mint` 传入地址、错误解构返回值，调用不存在的 `proposalIdsByPhase`；后续 Submit、Vote 参数也未对齐当前 ABI。所谓 Mint gas 测量没有调用 Mint，使用时间推进代替区块推进，且质押准备有直接跳过路径。

已用自包含测试替换：不依赖环境注入部署地址；使用当前 ABI；断言真实提案数量、投票总量、达标票数、预留账本及实际铸造；对 10/300/1000 样本执行。加入推举上限后移除临时压力参数，将原本地 15,000,000 gas 回归预算收紧为固定 8,000,000；该预算不是目标链区块上限。

同时删除 Stake 中两个以 `require(true)` 代替有效断言的占位测试，并保留 F-01 的有效复现。没有用跳过文件的方式让完整测试通过。

## F-04：部署验收遗漏不可修改的初始化配置

位置：[99_check.sh](/Users/BigPolarBear/Documents/github/LOVE20BSC/core/script/deploy/99_check.sh:115)。

基线遗漏 Launch 的根父币、Factory、symbol 长度、发射量、供应上限；MemberNFT 名称长度；Phase 起点、初始块数及观测上限。这些配置一旦初始化不可替换，permissionless init 的安全发布边界必须依靠完整验收。

已补齐上述读取与比较，同时核对首币登记。代码读取失败按失败处理；地址比较只对地址做大小写归一化，Token 名称等字符串仍精确比较。错误计数修复为在 `set -e` 下不会因第一次自增意外退出的形式。

隔离回归逐项注入错误值，确认均非零退出。地址文件在广播成功且链上验收全部通过后才写入；广播失败、地址解析缺失或验收失败均保留旧文件。Solidity 部署脚本不具备写地址能力，地址只由 shell 层在验收通过后落盘。

公开 `init` 是现有明确设计，本次不将它单独认定为漏洞，也没有加入管理员或部署者权限。

## F-05：错链与签名配置缺少可靠处理

位置：[00_init.sh](/Users/BigPolarBear/Documents/github/LOVE20BSC/core/script/deploy/00_init.sh:51)、[01_deploy.sh](/Users/BigPolarBear/Documents/github/LOVE20BSC/core/script/deploy/01_deploy.sh:11)、[DeployCore](/Users/BigPolarBear/Documents/github/LOVE20BSC/core/script/deploy/DeployCore.s.sol:28)。

已在 RPC 层对比实际 chain ID，在执行参数中显式传链 ID，并在部署脚本模拟阶段核对 `block.chainid`。公共网络使用配置的 Keystore；仅 31337 本地网络允许节点解锁账户签名。移除命令字符串拼接与 `eval`，改用参数数组。

本次没有连接钱包、要求密码或广播真实交易。Keystore 密码交互尚未进行实机部署验收。

## F-06：开源验证假成功与错误构造参数

位置：[verify.sh](/Users/BigPolarBear/Documents/github/LOVE20BSC/core/script/deploy/verify.sh:13)。

已取消 `|| echo` 吞错：缺少 API Key、未知网络、构造参数编码失败或任一合约开源失败均非零退出；只有八份全部成功才显示完成。构造参数编码失败会指明是 MemberNFT、Phase 还是 LOVE20Token，且不会发出任何验证请求。Token 构造参数使用本次的 `MINT_ADDRESS`，不依赖不存在的 `MINTER`。

使用 Etherscan V2 入口，chain ID 由 Foundry 传入，API Key 通过环境提供。依据：[Etherscan 官方 API 文档](https://docs.etherscan.io/make-your-first-call)。

回归覆盖首份失败、最后一份失败、全部成功和缺少 Key。没有向浏览器平台提交真实开源申请。

## F-07：旧入口配置缺失和明文私钥日志

位置：统一部署入口 `script/deploy/one_click_deploy.sh`。

基线独立入口缺少 Core 参数加载，把明文私钥拼进部署命令并输出。现已将它缩为统一 `bsc97_dev` 入口的委托；实际配置、签名、验收、地址保存使用同一条路径。

仍需部署者填写 `bsc97_dev` 中真实 DEX 地址及分发地址；模板占位值没有被审计过程替换为猜测地址。新路径只将 Keystore 名称传给签名工具，不把私钥放入命令行或打印。

## F-08：Router.WETH 未与 WBNB 配置对账

位置：[DEX 验收](/Users/BigPolarBear/Documents/github/LOVE20BSC/core/script/deploy/99_check.sh:328)。

已核对 `Router.factory() == FACTORY_ADDRESS`、`Router.WETH() == WBNB_ADDRESS`、首币父币为该 WBNB，并确认 Router、Factory、WBNB 均有代码。对实际返回有效但错误地址的情形，回归确认会拒绝。部署脚本另在广播前校验 WBNB、Factory、Router 均为已部署合约：`PARENT_TOKEN` 只被记录、`ROUTER_ADDRESS` 只在提现时使用，两者配错时模拟阶段不会回滚，此前要到本项验收才发现、8 个合约已白广播。

这些检查验证配置与接口关系，不证明任意提供的 Router/Factory 都可信。正式发布仍需对具体地址与实现来源验收。

## F-09：经济参数的部署防护与链上防护边界

基线的 [Mint.init](/Users/BigPolarBear/Documents/github/LOVE20BSC/core/src/Mint.sol:75) 允许 Proposal 奖励门槛超过 1000，使所有 Proposal 无法达标；[Launch.init](/Users/BigPolarBear/Documents/github/LOVE20BSC/core/src/Launch.sol:65) 允许 launchRatio 超过 `1e18`，把当次发射阈值设为未发行供应量的 100% 以上。由于额度可累计、阈值随供应量变化，不能由此断言永远不能发射。

用户确认后，合约 `init` 和部署脚本均校验：

- `MIN_PROPOSAL_VOTES <= 1000`；
- `LAUNCH_RATIO <= 1e18`。

两份合约超出上界均复用 `InvalidAmount()`，不新增错误或接口。Proposal 门槛 0、1000 保持合法；`launchRatio` 继续要求大于 0，恰好 `1e18` 合法。回归验证越界失败不消耗初始化机会，修正参数后可正常初始化。这是经确认的配置策略收紧，不是已证实可盗取资产的漏洞修复，也不会改变已部署实例。

手续费参数须与上述初始化上界分开理解：`MAX_WITHDRAWABLE_TO_FEE_RATIO` 是 Stake 的销毁阈值和单次处理量的分母；`ACTUAL_FEE_RATIO` 只是验收脚本从链上读取该值的临时变量。若可提取 LP 为 1,000,000 个最小单位、配置为 1000，则手续费 LP 至少达到 1000 个最小单位才可能触发，单次也只处理 1000 个；另受每 Phase 一次及双币产出非零的约束。它不是 Uniswap 交易费率，验收继续核对链上值与配置一致。

BSC 的 [Stake 规格](/Users/BigPolarBear/Documents/github/LOVE20BSC/matt-gov/docs/specs/core/04-stake.md:82) 另写有结合池费率选择该分母的经济约束；这是两项独立参数之间的策略关系，不是把销毁阈值当成交易费率。本次撤回新增的通用费率配置及关联门禁，保留现有 1000；该经济关系不能单独作为无 MEV 风险的证明。Stake 的 `init` 未修改。

## 设计、实现与安全复核

| 模块 | 本次关注点 | 结论与边界 |
| --- | --- | --- |
| LOVE20Token | minter 权限、maxSupply、burn | 限定 minter 铸造且受供应上限；没有可随意替换 minter 的管理入口 |
| MemberNFT | 身份唯一性、所有权迁移、枚举、铸造费用 | 当前持有人控制身份资产；ID 不复用；名称与 holder 枚举已有测试覆盖 |
| Phase | 按区块计轮、历史段、动态校准 | 压力测试已按区块推进；时间与区块不可互相替代 |
| Stake | Token 登记、LP/手续费份额、Boost、解锁、融合 | F-01 的零 LP 分支已修，其他失败边界保留；来源当前轮已用权益后仍禁止融合 |
| Submit | 推举资格、双向去重、每轮数量、回调顺序 | 先写完整状态再回调；共同入口将每个代币每轮推举数限制在 1,000 个 |
| Vote | 累计票权、冻结快照、回调与轮次 | 票数累加及额度检查已有单元/fuzz 覆盖；有票提案数受 Submit 上限约束 |
| Mint | 预留/铸造/取消守恒、重复领取、向下舍入 | 账本 invariant 通过；单轮最多扫描 1,000 项，任意多轮批量仍须控制大小 |
| Launch | 父子登记、额度权限、预建 Pair | 已有 Pair 复用逻辑保留；配置范围见 F-09 |
| 外部依赖 | ERC20、V2 Pair/Router、Proposal/Distributor 回调 | 依赖约束和状态顺序必须一起评估，不能因未设重入锁就断言必然有漏洞，也不能笼统保证“无重入风险” |

对旧报告中的三项历史问题复核：Token 注册门禁、预建 Pair 复用、当前轮已使用权益的来源融合限制在当前代码中可见；本次没有回退这些保护。它们不能替代 F-02 的数量边界分析。

手续费兑换的 `amountOutMin` 来自同笔交易当前储备，不是跨交易价格锚。每 Phase 一次和单笔量约束可降低暴露，但不能证明不存在 MEV。旧报告建议把报价再下调 2% 并不能建立可信价格基准，本次未采用。

自有合约精确锁定 Solidity 0.8.37，Foundry 1.8.1，EVM 目标 Osaka，optimizer 200，未开启 via-IR。依赖由 Git submodule 与 lockfile 固定，本次没有升级依赖。Osaka 在目标网络的实际支持仍属于发布验收项目。

## 验证结果与限制

| 检查 | 结果 |
| --- | --- |
| 完整 `forge build` | 通过 |
| 完整 `forge test --summary` | 19 个 suite，400 项通过，0 失败，0 跳过 |
| Mint invariant | 9 项断言通过；Foundry 汇总计为 1 项，32 runs / 480 calls |
| fuzz | 现有用例各 256 次，通过 |
| 推举上限 | 第 1,001 个新旧推举回滚且不留状态，下一轮、其他代币及超过 1,000 的历史总数通过 |
| 压力测试 | 10/300/1000 提案，固定 8,000,000 gas 首次 Mint 预算，两类奖励及缓存断言通过 |
| 部署脚本隔离回归 | 25 项通过，无真实网络调用或广播；已移除 2 项针对撤回的 DEX 费率配置的检查 |
| shell 语法与 diff 检查 | 通过 |
| Slither | 未完成；crytic-compile 读取 Foundry build-info 时 `KeyError: 'output'`，不据此作安全判断 |
| 目标 BSC 分叉、钱包实签、实际部署与开源 | 本次未执行 |

计数以最终命令的 suite 汇总为准；不能把 `--list` 展开的 invariant 名称简单相加，也不能沿用前一阶段的历史计数。测试数量不等于有效安全场景数量；既有其余测试质量未据此宣称完整覆盖。

复现命令（在 `core` 执行）：

```bash
forge build
forge test --summary
forge test --match-contract ProposalDoSTest -vv
forge test --match-test testDustWithdrawalReturnsBoostAndClearsShares -vv
python3 test/deploy_scripts_test.py
```

## 本轮处理结果与边界

| 决策 | 实施状态 | 对现有设计的影响 |
| --- | --- | --- |
| 小额 LP 出口 | 已按确认实施零 LP 最小修复；没有新增 LP 直接提取入口 | 不新增 ABI，零额退出可归还 Boost 并放弃尾差；非零 LP 双币舍入及结算失败边界保留 |
| 大轮次奖励准备 | 已按确认在共同推举入口限制每个代币每轮 1,000 个提案 | 超限复用 `CannotSubmitAction`；ABI、投票、解锁与奖励公式不变，单轮扫描有界；保留名额占满及任意批量风险 |
| 参数上界 | 已按确认将两个上界加入 Mint/Launch 的 init | 收紧输入，与部署验收对齐；规格及边界测试已同步 |

没有提交、部署或迁移线上状态。新增 LP 出口或分批奖励准备仍需另行确认。发布前仍需真实目标 Pair 回归、目标链部署演练与逐项验收，本报告不替代这些检查。
