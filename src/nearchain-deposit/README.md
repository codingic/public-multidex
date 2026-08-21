# nearchain-deposit（NEAR NEP-141 充值检测器）

监控 NEAR 链上区块，解析每笔交易的 receipt outcomes 中 **NEP-141 `ft_transfer` 事件**，
把收款方（`new_owner_id`）命中「已登记充值账户」的代币转账记为充值记录。

**只处理代币充值**——刻意不检测原生 NEAR 的 `Transfer`（按「只是 token 的充值」要求）。

## 流程（与 ethchain-deposit 一致）

`latestHeight`（取 `final` 块高）→ `scanBlocks`（按块扫描，每轮上限 `MAX_BLOCKS_PER_SCAN`）
→ `scanBlockProd`（每块：`block` 取 `(交易哈希, signer_id)` 二元组 → 每笔
`EXPERIMENTAL_tx_status` 取 `receipts_outcome` → `extractReceipt` 匹配「被监控代币 +
被监控收款方」）→ `confirmDeposits`（达到 `CONFIRMED_BLOCKS` 确认数后归档进
`depositsConfirmed`）。

采用 **拉取模型**：检测器只归档，DEX 后端通过 `getConfirmedDeposits` 读取后自行入账
（与 ETH/SOL/BTC 检测器一致）。

## RPC 传输

NEAR 在 ICP 上没有官方的「NEAR-RPC canister」（ETH 用的是 EVM-RPC canister），因此通过
**管理 canister `aaaaa-aa` 的 `http_request`（HTTPS 出站调用）** 直接访问 NEAR RPC
（默认 `https://rpc.mainnet.near.org`，可用环境变量 `NEAR_RPC_URL` 覆盖）。

关键点：

- 交易明细用 **`EXPERIMENTAL_tx_status`**（非已废弃的 `EXPERIMENTAL_tx`），且必须同时
  传 `tx_hash` + `sender_account_id`（即 `block` 返回的 `signer_id`）——只传哈希会被 RPC
  以 `UNKNOWN_TRANSACTION` 拒绝。`data` 字段兼容「单对象」与「数组」（NEP-297 批量事件）。
- **成本提示**：NEAR 没有 `eth_getLogs` 这类「整块日志」接口，只能逐笔 RPC 取 receipt
  结果。每轮出站调用量 ≈ `MAX_BLOCKS_PER_SCAN` × 每块交易数，主网单块常达数百笔。
  上线前务必按实际交易量调小 `MAX_BLOCKS_PER_SCAN`（`Constants.mo`），并确认 RPC 节点
  支持 `EXPERIMENTAL_tx_status`（部分公开节点不开放实验接口）。

## 对外接口（controller 调用）

- `registerDepositAddress(owner, nearAccount)` / `unregisterDepositAddress(nearAccount)`
- `watchToken(contract)` / `unwatchToken(contract)` / `getWatchedTokens`（空集合 = 监控所有 NEP-141 代币）
- `getDepositAddresses()` / `getConfirmedDeposits()`
- `scanAll()`（手动触发一轮扫描）

## 关键文件

- `main.mo`：扫描主循环与事件解析
- `NearRpcTypes.mo`：IC `http_request` 管理接口类型
- `Constants.mo`：RPC 地址与扫描参数（确认数、轮询间隔等）
- `Hex.mo`：`lowerText` / `decimalToNat`（NEAR 账户小写归一、十进制金额解析）
- `Types.mo`：`Transfer` / `Deposit`（字段形状与 ETH 检测器一致，便于后端统一拉取）
