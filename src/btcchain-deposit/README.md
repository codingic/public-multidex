# btcchain-deposit（BTC 充值检测后端）

## 1. 模块定位

`btcchain-deposit` 是多链 DEX 中**专门负责 Bitcoin（BTC）充值检测**的独立 canister。职责边界与 `eth-deposit-detector` / `solchain-deposit` 完全对称：

> **只做一件事：扫链 → 解析入金 → 存进地图（deposits）。不负责入账。**

- 检测到一笔确认的 BTC 入金（UTXO）后，存入 `deposits`，并在达到确认数（区块深度）后移入 `depositsConfirmed` 永久存档。
- **入账（给用户加余额）不在本模块内**：由 backend 读取 `depositsConfirmed` 后完成（BTC→本 detector，ETH→eth-deposit-detector，SOL→solchain-deposit，每资产单点入账）。

## 2. 整体工作流程

### 2.1 定时扫描
- 启动时通过 `Timer.recurringTimer(#seconds(SCAN_INTERVAL_SEC), scanBlocks)` 注册每 `SCAN_INTERVAL_SEC(15)` 秒一次的周期性扫描。
- Bitcoin 没有「全局 Transfer 日志」，也没有账户抽象，检测模型是**按被监控地址轮询 UTXO**（这也与 SOL 版的「按地址轮询」对称）：每轮对 `watchedAddresses` 中的每个地址各做一次 `get_utxos`。

### 2.2 按地址轮询 `get_utxos`
- 每个被监控地址发一次 `get_utxos`（`network=#mainnet`，`filter=#max_number_of_utxos(UTXO_LIMIT=100)`）。
- 响应里每一项 `Utxo` 携带：`outpoint { txid, vout }`、`value`（satoshi，即 `amountRaw`）、`height`（区块高度，0=未确认/mempool），以及全局 `tip_height`（当前链尖）。
- 以 `txid#vout` 作为**稳定的去重键**（dedupKey）：每轮重新列出该地址的全部 UTXO，靠 dedup 双查（`deposits` + `confirmedKeys`）防止重复入库，**无需 Solana 版那样的增量游标**。

### 2.3 入金判定
- BTC 原生模型：UTXO 出现在被监控地址即视为入金。`from` 在 `get_utxos` 中不可见（UTXO 无显式 sender），统一留空。
- `amountRaw` = `value`（satoshi，已为最小单位，无需再换算）。

### 2.4 确认数与存档 `confirmDeposits(tip)`
- `tip` 来自本轮 `get_utxos` 的 `tip_height`。
- 确认数计算：`height == 0`（未确认）→ 0；否则 `tip − height + 1`。
- `confirmations >= CONFIRMED_CONFIRMATIONS(6)`：移出 `deposits`，追加进永久存档 `depositsConfirmed`，并登记 `confirmedKeys`（防重复入库）；迭代结束后再统一删除。
- 未达阈值：仅刷新 `confirmations`。

## 3. 关键设计要点

| 关注点 | 做法 |
| --- | --- |
| 检测模型 | BTC 无全局 Transfer 日志 → **按 `watchedAddresses` 逐地址 `get_utxos` 轮询**（与 SOL 版「按地址轮询」对称），与 ETH 版「整块扫」对称但以 UTXO 为中心 |
| 去重 | 去重键 = `txid#vout`；靠 `deposits` + `confirmedKeys` 双查防重复入库；`postupgrade` 从 `depositsConfirmed` 回填 `confirmedKeys` |
| 地址规范 | `isValidBtcAddress`：bech32（`bc1`/`tb1`/`bcrt1` 前缀）直接放行；其余按 Bitcoin base58 字母表校验；校验和交由链上 `get_utxos` 兜底 |
| 幂等 / 防重组 | `CONFIRMED_CONFIRMATIONS=6` 阈值、`height` 深度判定、dedup 键 |
| 金额 | `value` 已是 satoshi（最小单位），直接作为 `amountRaw`，无 decimal 换算 |
| RPC 接入 | 经 dfinity bitcoin canister `mgi-tqaaaa-aaaar-qaqoa-cai` 的 **typed** 接口 `get_utxos`（Candid 直接解码，无需 JSON-RPC 文本解析），主网 `#mainnet` |

## 4. 公共接口

| 接口 | 类型 | 权限 |  uchar 说明 |
| --- | --- | --- | --- |
| `registerDepositAddress(owner, addr)` | shared | controller | 注册某用户的 BTC 充值地址（`addr` 经 `isValidBtcAddress` 校验） |
| `unregisterDepositAddress(addr)` | shared | controller | 注销某充值地址 |
| `getDepositAddresses()` | query | 公开 | 返回当前所有被监控充值地址 |
| `getConfirmedDeposits()` | query | 公开 | 返回已达确认阈值的永久存档（**当前为全量返回**，见 §6） |
| `scanAll()` | shared | 公开 | 手动触发一次 `scanBlocks`（调试 / 补扫用） |
| `getDeployMode()` | query | 公开 | 固定返回 `"production"` |
| `cyclesBalance()` | query | 公开 | 返回当前 cycles 余额（运维监控用） |

> 所有 `controller` 接口现阶段只能由 controller 或受权的 backend 调用。实际部署时需要由 backend（被授权为 controller 或经中间方法）在用户开通充值地址时调用 `registerDepositAddress`。

## 5. 部署与接线

- **构建配置**：`icp.yaml`（新增 `btcchain-deposit` canister + 加入 `engine`/`subnet` 环境）与 `mops.toml`（新增 `[canisters.btcchain-deposit]` 指向 `src/btcchain-deposit/main.mo`）已接入。
- **backend 接线**：backend 新增 `setBtcDetector(principal)` / `getBtcDetector()`，并把 `creditAndRegister` 等记账入口的调用方白名单扩展为「bridge **或** eth-deposit-detector **或** solchain-deposit **或** btcchain-deposit **或** controller」。
- **bitcoin canister**：通过 `Constants.btcCanisterMainnet()`（主网）访问 `mgi-tqaaaa-aaaar-qaqoa-cai`，`#mainnet`。

## 6. 已知限制 / TODO（百万规模配套项）

1. **`depositsConfirmed` 无限增长**：永久存档数组会随用户量长期膨胀，撑高 canister 内存。已在该变量处标 `TODO`——需分桶存储 / backend 消费后清理。
2. **全量返回接口**：`getDepositAddresses()` / `getConfirmedDeposits()` 当前返回整个数组，百万级会撑爆 query 响应，**需加分页**。
3. **逐个注册不可行**：`registerDepositAddress` 一次只注册一个地址，100 万地址需调用 100 万次，**需提供批量注册接口**。
4. **按地址轮询的 RPC 成本**：每轮对所有 `watchedAddresses` 各发一次 `get_utxos`。地址数大时 RPC 次数线性增长（百万地址不可接受），需引入分片 / 队列化 / 限制并发；单地址单轮最多 `UTXO_LIMIT(100)` 个 UTXO，超出的需分页（当前未实现，已在 `filter` 处可扩展 `min_confirmations` 替代）。

## 7. 代码结构

```
src/btcchain-deposit/
├── main.mo          // detector actor：扫描调度、链上读取、解析、存储、公开接口
├── Types.mo         // Transfer / Deposit 类型定义（竖排）
├── Constants.mo     // 链配置、扫描参数、bitcoin canister 构造
├── BtcRpcTypes.mo   // bitcoin canister 的 Candid 类型子集（get_utxos 等）
└── README.md        // 本文件
```
