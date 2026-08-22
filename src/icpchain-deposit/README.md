# icpchain-deposit — ICP 充值检测器（懒扫描模型，仅 ICP）

本模块检测 ICP 转入 DEX backend 托管账户的充值。**与 ETH/BTC/SOL/NEAR 检测器不同：
它不运行后台定时器轮询区块链，且当前只支持 ICP（不做多 ICRC token 框架）。**

## 模型

- 每个用户 = DEX backend 的 principal + 专属 subaccount → `account_identifier`。
- 充值 = ICP ledger 的一笔 `transfer`，其 `to` 账户为 `(backendPrincipal, userSubaccount)`。
- 用户打开充值界面点「刷新」时，调用 `scanUserDeposits(userSub)`：
  1. 通过 `icrc3_get_blocks` 分页回扫最近 24h 的区块（按块时间戳判断）；
  2. 过滤 `to == (backendPrincipal, userSub)` 的 `transfer`（`btype = "1xfer"/"2xfer"`）；
  3. 去重后存入 `depositsConfirmed`（key = `blockIndex`，block index 在 ledger 内唯一）；
  4. 返回该用户全部充值记录。
- 前端显示的「用户余额」由调用方用台账（累计充值 − 已归集）计算，
  **不是链上原始余额**，所以能正确反映「充值 150、归集走 100、再充值 50 → 显示 150」，
  而链上余额此时只有 50。

## 为什么不做成 ETH 那样的持续扫块

- ICP ledger **没有按地址查历史**的接口，只能 `icrc3_get_blocks`（按高度区间）。
- 持续扫块成本高且无必要：充值发生在用户主动操作时，按需懒扫描近 24h 即可覆盖。
- 归集是 backend 内部流程，余额显示依赖台账而非链上快照。

## 接口

| 方法 | 说明 |
|------|------|
| `setOwner(principal)` | controller 设置 backend 主账户 principal |
| `scanUserDeposits(subaccount)` | **用户刷新时调用**：回扫近 24h、归档并返该用户充值 |
| `getConfirmedDeposits(subaccount)` | 返回**该用户**的已归档充值（query） |
| `getOwner()` | 返回已设置的 backend 主账户 principal |

## 部署后接线

```
dfx canister call icpchain-deposit setOwner <backend-principal>
```

## 解析格式

依赖 ICP ledger `icrc3_get_blocks` 返回的 **ICRC-3 `Value`** 结构：

- block 顶层：`btype`（块类型，`"1xfer"/"2xfer"` 为转账）、`ts`（时间戳）、`tx`（交易 payload）、`fee`（顶层手续费）
- `tx` 内：`op`（操作类型，旧版用 `"xfer"`）、`amt`（金额）、`from` / `to`（账户）、`fee`（可选）
- 账户 = `Array [Blob(owner), Blob(subaccount)?]`，无 subaccount 时只有一个元素
- `#Map` = `[(Text, Value)]` 键值对元组数组

## 限制

- 仅能检测到**部署后 / 上次刷新之后**的充值；早于首次扫描窗口的历史无法回溯
  （与「链上无按地址历史查询」一致）。扫描窗口为近 24h。
- **`archived_blocks` 未处理**：`GetBlocksResult` 里的归档块回调被忽略。正常 24h 窗口
  都在主 ledger 内不会触发；仅当 `MAX_SCAN_BLOCKS` 用满或块增长超出主 ledger 时才会漏块。
- **字段名/编码基于 ICRC-3 标准，尚未在真实 ICP ledger 上实测**。上线前建议先在测试网
  调一次 `icrc3_get_blocks`，核对 `btype` 取值、时间戳字段名（`ts`）、以及账户 owner 的
  blob 是否能用 `Principal.fromBlob` round-trip。
- 每次刷新会重扫近 24h（靠 `recordDeposit` 去重保证不重复记账，但 RPC 成本重复）。
