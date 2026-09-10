# LOVE20BSC Core

Core 负责 MemberNFT、Phase、Stake、Proposal、Vote、Mint、LOVE20Token、TokenFactory 和 Launch。

当前迁移顺序：先以固定旧提交建立 `LOVE20Token` 原始快照，再按小步提交改造成 BSC 版本。旧代码来源：`LOVE20TKM/core@0e3efcc13a7b9e202033f62e4858795bf43b557e`。

## 当前状态

- `src/LOVE20Token.sol`：旧版原始迁移快照，暂未开始 BSC 语义改造。
- `src/interfaces/ILOVE20Token.sol`：对应旧版快照接口。

每个提交只做一个行为变化，并附带编译、测试和 ABI 差异说明。
