# solchain-deposit（SOL 充值检测后端）

## 1. 模块定位

`solchain-deposit` 是多链 DEX 中**专门负责 Solana（SOL / SPL Token）充值检测**的独立 canister。职责边界与 `eth-deposit-detector` 完全对称：

> **只做一件事：扫链 → 解析入金交易 → 存进地图（deposits）。不负责入账。**

- 检测到一笔确认的 SOL / SPL 入金后，存入 `deposits`，并在达到确认数（slot 深度）后移入 `depositsConfirmed` 永久存档。
- **入账（给用户加余额）不在本模块内**：由 backend 读取 `depositsConfirmed` 后完成（SOL→detector，ETH→eth-deposit-detector，BTC→bridge，每资产单点入账）。

## 2. 整体工作流程

### 2.1 定时扫描
- 启动时通过 `Timer.recurringTimer(#seconds(SCAN_INTERVAL_SEC), scanBlocks)` 注册每 `SCAN_INTERVAL_SEC(8)` 秒一次的周期性扫描。
- Solana 没有「全局 Transfer 日志」可整块拉取，检测模型是**按被监控地址轮询**（这也是 Solana 索引器的标准做法）：每轮对 `watchedAddresses` 中的每个地址各做一次 `getSignaturesForAddress` 增量扫描。

### 2.2 按地址增量游标（避免重放历史）
- 每个被监控地址维护一个 `lastSignature` 游标：记录该地址**已处理到的最新签名**。
- 每轮 `getSignaturesForAddress` 按时间倒序（最新在前）返回至多 `SIG_LIMIT(50)` 条签名：
  - **首次**为该地址扫描（`lastSignature` 为空）：只把游标设为当前最新签名，**不把历史入账计入**（与 ETH 版「首次跳到 tip 不重放」语义一致），避免把远古历史误当充值。
  - **后续**扫描：从最新签名往下处理，**一旦遇到等于游标的签名即停止**（其下方都是已处理的旧签名），然后把游标前移到本轮最新签名。
  - 若某地址一次涌入超过 `SIG_LIMIT` 笔，中间部分可能延后一轮补齐；已处理的由 dedup 保证不重复入库。

### 2.3 单笔交易解析 `getTx(sig)` + `extractTransfers(tx)`
对游标之上的每个新签名调 `getTransaction`（`encoding: jsonParsed`），解析出所有入金：

**A. SOL 原生转账（System Program）**
- 遍历 `instructions` + `innerInstructions`，找 `program == "system"` 且 `parsed.type == "transfer"` 的指令。
- 取 `parsed.info.destination`（收款地址）与 `parsed.info.lamports`（金额，base10 文本）。
- `destination ∈ watchedAddresses` 且 `lamports > 0` 才 `recordDeposit`。amount 为 lamports。

**B. SPL Token 转账（Token / Token-2022 Program）**
- Solana 的 SPL 入账不靠解析指令里的 token account → owner 映射（易漏 inner instruction / ATA 创建），而是**直接扫 `meta.postTokenBalances`**：找 `(owner ∈ watchedAddresses) && (mint ∈ watchedTokens) && (post > pre)` 的 token 账户，金额 = `post − pre`。
- 这种方式独立于指令布局，天然覆盖 inner instructions 与关联代币账户（ATA）创建带来的余额变化。

### 2.4 确认数与存档 `confirmDeposits(tip)`
每次扫描后调用（与 ETH 版一致）：
- 遍历 `deposits`，刷新 `confirmations = tip − slot`（不足则记 0）。
- `confirmations >= CONFIRMED_SLOTS(32)`：移出 `deposits`，追加进永久存档 `depositsConfirmed`，并登记 `confirmedKeys`（防重复入库）；迭代结束后再统一删除。
- 未达阈值：仅刷新 `confirmations`。

## 3. 关键设计要点

| 关注点 | 做法 |
| --- | --- |
| 检测模型 | Solana 无全局 Transfer 日志 → **按 `watchedAddresses` 逐地址 `getSignaturesForAddress` 增量扫描**（标准 Solana 索引器模式），与 ETH 版「整块扫」对称 |
| 增量游标 | 每地址 `lastSignature` 游标；首次仅播种不入账，后续遇游标即停，避免重放历史 |
| SOL 原生入金 | 解析 `system` transfer 指令的 `destination` / `lamports`，`destination` 直接是 owner 地址 |
| SPL 入金 | 扫 `postTokenBalances` 的 `(owner, mint)` 余额增量，独立于指令布局，覆盖 inner/ATA |
| 地址规范 | base58 大小写敏感，不做小写化；`registerDepositAddress` 用 `Base58.isValidBase58` 校验字母表，非法直接 trap |
| 重复入库防护 | 去重双查 `deposits` + `confirmedKeys`；dedup key = `signature#sol#指令索引`（原生）/ `signature#spl#账户索引`（代币）；`postupgrade` 从 `depositsConfirmed` 回填 `confirmedKeys` |
| 幂等 / 防重组 | `DELAY_SLOTS` 延迟、`CONFIRMED_SLOTS` 阈值、dedup key |
| RPC 接入 | 经 dfinity `sol-rpc` canister `tghme-zyaaa-aaaar-qarca-cai` 的 `jsonRequest`（通用 JSON-RPC 转发，与 evm-rpc 的 `multi_request` 同形），统一发 `getSlot` / `getSignaturesForAddress` / `getTransaction`，结果以原始 JSON 文本用 `mo:json` 解析 |

## 4. 公共接口

| 接口 | 类型 | 权限 | 说明 |
| --- | --- | --- | --- |
| `watchToken(mint)` | shared | controller | 增加一个被监控的 SPL mint（仅存地址） |
| `unwatchToken(mint)` | shared | controller | 取消监控某 mint |
| `getWatchedTokens()` | query | 公开 | 返回当前被监控 mint 列表 |
| `registerDepositAddress(owner, addr)` | shared | controller | 注册某用户的 SOL 充值地址（`addr` 经 base58 校验）；SPL 与原生路径共同前提 |
| `unregisterDepositAddress(addr)` | shared | controller | 注销某充值地址（同时清游标） |
| `getDepositAddresses()` | query | 公开 | 返回当前所有被监控充值地址 |
| `getConfirmedDeposits()` | query | 公开 | 返回已达确认阈值的永久存档（**当前为全量返回**，见 §6） |
| `scanAll()` | shared | 公开 | 手动触发一次 `scanBlocks`（调试 / 补扫用） |
| `getDeployMode()` | query | 公开 | 固定返回 `"production"` |
| `cyclesBalance()` | query | 公开 | 返回当前 cycles 余额（运维监控用） |

> 所有 `controller` 接口当前只能由 controller 或受权的 backend 调用。实际部署时需要由 backend（被授权为 controller 或经中间方法）在用户开通充值地址时调用 `registerDepositAddress`。

## 5. 部署与接线

- **构建配置**：`icp.yaml`（新增 `solchain-deposit` canister + 加入 `engine`/`subnet` 环境）与 `mops.toml`（新增 `[canisters.solchain-deposit]` 指向 `src/solchain-deposit/main.mo`）已接入。
- **backend 接线**：backend 新增 `setSolDetector(principal)` / `getSolDetector()`，并把 `creditAndRegister` 等记账入口的调用方白名单扩展为「bridge **或** eth-deposit-detector **或** solchain-deposit **或** controller」。
- **sol-rpc**：通过 `Constants.solRpcMainnet()`（主网，`#Default(#Mainnet)`）访问 sol-rpc canister `tghme-zyaaa-aaaar-qarca-cai`。

## 6. 已知限制 / TODO（百万规模配套项）

1. **`depositsConfirmed` 无限增长**：永久存档数组会随用户量长期膨胀，撑高 canister 内存。已在该变量处标 `TODO`——需分桶存储 / backend 消费后清理。
2. **全量返回接口**：`getDepositAddresses()` / `getConfirmedDeposits()` 当前返回整个数组，百万级会撑爆 query 响应，**需加分页**。
3. **逐个注册不可行**：`registerDepositAddress` 一次只注册一个地址，100 万地址需调用 100 万次，**需提供批量注册接口**。
4. **按地址轮询的 RPC 成本**：每轮对所有 `watchedAddresses` 各发一次 `getSignaturesForAddress`，再对新签名逐个 `getTransaction`。地址数大时 RPC 次数线性增长（百万地址不可接受），需引入分片 / 队列化 / 限制并发；也可改走 `getBlock` 整块 + 本地按地址过滤（但 Solana 的 `getBlock` 默认 `transactionDetails` 受限、payload 大，provider 限制更严）。
5. **`SIG_LIMIT` 截断**：单地址一轮最多拉 `SIG_LIMIT(50)` 条签名，突发高频入账可能延后一轮补齐（dedup 保证不重复）。

## 7. 代码结构

```
src/solchain-deposit/
├── main.mo          // detector actor：扫描调度、链上读取、解析、存储、公开接口
├── Types.mo         // Transfer / Deposit 类型定义（竖排）
├── Constants.mo     // 链配置、扫描参数、cycles 预算、sol-rpc 构造
├── SolRpcTypes.mo   // sol-rpc canister 的 Candid 类型子集（jsonRequest 等）
├── Base58.mo        // base58 字母表校验 / 解码（地址大小写敏感，不做小写化）
└── README.md        // 本文件
```
