# LOVE20BSC Core

Core 负责 MemberNFT、Phase、Stake、Proposal、Vote、Mint、LOVE20Token 和 Launch。

迁移方式：每个合约先以固定旧提交建立原始快照，再按小步提交改造成 BSC 版本。旧代码来源：`LOVE20TKM/core@0e3efcc13a7b9e202033f62e4858795bf43b557e`。

## 当前状态

- `src/LOVE20Token.sol`：已完成 BSC 版，构造函数接收名称、符号、首批供应量、最大供应量、`distributor`、`minter` 和父币。
- `src/Launch.sol`：已完成 BSC 版，负责首币部署、代币创建与登记、发射次数账本、次数融合和子币发射。
- `src/MemberNFT.sol`：已完成 BSC 版成员身份 NFT，`init(firstToken)` 由 `Launch.init` 创建首币时同步调用。
- `src/Phase.sol`：已完成 BSC 版无业务语义时间片，含同步观测分页查询与动态校准。
- `src/interfaces/`：与冻结自有声明保持一致，标准能力通过 OpenZeppelin 继承补齐。

每个提交只做一个行为变化，并附带编译、测试和 ABI 差异说明。
