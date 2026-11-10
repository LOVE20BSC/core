# LOVE20BSC Core

Core 负责 MemberNFT、Phase、Stake、Proposal、Vote、Mint、LOVE20Token 和 Launch。

迁移方式：每个合约先以固定旧提交建立原始快照，再按小步提交改造成 BSC 版本。旧代码来源：`LOVE20TKM/core@0e3efcc13a7b9e202033f62e4858795bf43b557e`。

## 依赖

| 子模块 | 用途 |
| --- | --- |
| `lib/libs` | 跨仓共享 Solidity 原语；本仓是 `action`、`group-chat` 的版本权威 |
| `lib/openzeppelin-contracts` | 标准 ERC 与数学库；同上 |
| `lib/forge-std` | 测试与脚本 |

下游经嵌套依赖使用本仓的 `libs` 与 OpenZeppelin；版本见 `.gitmodules` + `foundry.lock`。生产源码通过 `@libs/`、`@openzeppelin/contracts/` 别名导入直接依赖，`remappings.txt` 是实际解析表。规则见 [合约开发规范](https://github.com/LOVE20BSC/matt-gov/blob/main/docs/dev-standards.md) §3.2。

## 当前状态

- `src/LOVE20Token.sol`：已完成 BSC 版，构造函数接收名称、符号、首批供应量、最大供应量、`distributor`、`minter` 和父币。
- `src/Launch.sol`：已完成 BSC 版，负责首币部署、代币创建与登记、发射次数账本、次数融合和子币发射。
- `src/MemberNFT.sol`：已完成 BSC 版成员身份 NFT，首币地址在构造函数传入（部署脚本从 `Launch.FIRST_TOKEN_ADDRESS()` 读取）。
- `src/Phase.sol`：已完成 BSC 版无业务语义时间片，含同步观测分页查询与动态校准。
- `src/Stake.sol`：已完成 BSC 版流动性质押、加速质押、份额与手续费重分类、按轮次的治理票与加速份额账本。
- `src/Submit.sol`：已完成 BSC 版 Proposal 创建与推举，含创建与推举两个 Target 回调。
- `src/Vote.sol`：已完成 BSC 版本轮投票、票数上限与加速快照，含投票回调。
- `src/Mint.sol`：已完成 BSC 版轮次池准备（含无许可入口）、治理与 Proposal 结算、发射额度生成。
- `src/interfaces/`：与冻结自有声明保持一致，标准能力通过 OpenZeppelin 继承补齐。
- `test/compat/`：真实 V2 子集 `RealV2.sol` 与前序审计修复的回归证据 `CoreSecurityPoC.t.sol`，随 `forge test` 在 CI 执行。

每个提交只做一个行为变化，并附带编译、测试和 ABI 差异说明。

`SECURITY_AUDIT_2026-09-28.md` 与 `SECURITY_AUDIT_REPORT_2026-10-01.md` 是 `init` 时代的历史记录，结论与行号均已随构造函数化失效，只作追溯保留。
