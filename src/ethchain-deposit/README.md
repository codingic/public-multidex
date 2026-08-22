# eth-deposit-detector（ETH 充值检测后端）

## 1. 模块定位

`eth-deposit-detector` 是多链 DEX 中**专门负责以太坊（ETH / ERC-20）充值检测**的独立 canister。它的职责边界非常窄：

> **只做一件事：扫链 → 解析入金交易 → 存进地图（deposits）。不负责入账。**

- 检测到一笔确认的 ETH/ERC-20 入金后，存入 `deposits`，并在达到确认数后移入 `depositsConfirmed` 永久存档。
- **入账（给用户加余额）不在本模块内**：由 backend 读取 `depositsConfirmed` 后调用自身的 `creditAndRegister` 完成。本模块通过 backend 的 `setEthDetector` 被授权为第二个记账 canister（ETH→detector，BTC/SOL→bridge），每个资产由且仅由一个 canister 入账，避免 `creditedSeq` 高水位冲突。

## 2. 整体工作流程

### 2.1 定时扫描
- 启动时通过 `Timer.recurringTimer(#seconds(SCAN_INTERVAL_SEC), scanBlocks)` 注册每 5 秒一次的周期性扫描。
- `safeTip = tip - DELAY_BLOCKS(2)`：只扫已经稳定的区块，避免扫到可能被重组的最新区块。
- 每轮最多向前推进 `MAX_BLOCKS_PER_SCAN(5)` 个区块。

### 2.2 部署后自动追链（避免从 0 重放）
- `blockHeight` 初始为 0。首次扫描时若 `blockHeight == 0 && tip > 0`，直接跳到 `tip - DELAY_BLOCKS - MAX_BLOCKS_PER_SCAN`，部署后立即从当前高度往后扫，不会去重放整条主网（约 2000 万区块）。
- 升级后 `blockHeight` 已持久化（非零），不受影响。

### 2.3 单区块处理 `scanBlockProd(h)`
针对每个待扫区块并行跑两条独立的检测路径：

**A. ETH 原生转账（无日志，逐笔解析交易）**
- 一次 `eth_getBlockByNumber`（`getBlock`）拿到整块的交易哈希列表 `transactions`。
- 对每笔交易哈希调 `eth_getTransactionByHash`（`evmGetTx`）拿到 `to`/`value`，命中 `watchedAddresses` 且 `value > 0` 的才 `recordDeposit`。
- 原生 ETH 转账不发日志，`eth_getLogs` 查不到，所以必须逐笔解析交易。

**B. ERC-20 转账（有 Transfer 日志）**
- 一次 `eth_getLogs` 拉回该区块的全部 Transfer 日志（`addresses = []` 不过滤合约地址，`topics` 只留 `TRANSFER_SIG` 预过滤事件签名）。
- 每条日志本地走 `extractLogEntry`：先校验 `topics`（Transfer 事件、topic 数量 ≥ 3），再判断**是否调用了被 watch 的合约**（`Map.get(watchedTokens, log.address)`），再判断 **to 地址是否正确**（`Map.get(watchedAddresses, 从 topic[2] 提取的收款地址)`），命中才入库。

> **明确不支持内部 ETH 充值（internal transactions）。** 本模块只识别两类入金：① 原生 ETH 转账（交易 `to` 直接为 watch 地址，路径 A）；② ERC-20 `Transfer` 日志（路径 B）。合约在执行过程中通过 `CALL` 间接转出的 ETH（即 `trace_block` 才能看到的 internal transaction）**不会被检测**，也不会据此入账。这是有意为之的功能边界，不是 bug——相关 `trace_block` 解析代码已删除。若业务需要支持合约代付 / 内部转账充值，需另行评估并接入 trace 类 RPC（届时需注意 `trace_block` 并非所有 provider 都支持，且会显著增加每区块的 RPC 成本与重组复杂度）。

### 2.4 确认数与存档 `confirmDeposits(tip)`
每次扫描推进后调用：
- 遍历 `deposits`，刷新 `confirmations = tip - blockHeight`（不足则记 0）。
- `confirmations >= CONFIRMED_BLOCKS(35)`：移出 `deposits`，追加进永久存档 `depositsConfirmed`（以去重键为 key 的 Map，键的存在本身就防重复入库）；迭代结束后再统一删除，避免在 map 迭代中删当前键。
- 未达阈值：仅刷新 `confirmations` 字段。

## 3. 关键设计要点

| 关注点 | 做法 |
| --- | --- |
| 百万充值地址 | ERC-20 先整块拉 Transfer 日志，本地用 `Map.get` 做「合约 + 收款地址」两级 O(log n) 匹配（百万地址 ≈20 次比较无压力）；ETH 走标准 `eth_getBlockByNumber` + 逐笔 `eth_getTransactionByHash` |
| ETH 检测成本 | `eth_getBlockByNumber`（`getBlock`）拿区块哈希列表，再逐笔 `eth_getTransactionByHash`（`evmGetTx`）解析 to/value |
| 地址规范化 | `registerDepositAddress` 强制归一成 `0x` + 小写，与日志 topic 派生的 key 一致，否则会**静默漏检全部 ERC-20 充值** |
| 重复入库防护 | 去重双查 `deposits` + `depositsConfirmed`（以去重键为 key，存档本身即"已结算"成员判断）；`postupgrade` 无需回填 |
| 幂等 / 防重组 | `DELAY_BLOCKS` 延迟、`CONFIRMED_BLOCKS` 阈值、dedup key（`txHash#native` / `txHash#logIndex`） |

## 4. 公共接口

| 接口 | 类型 | 权限 | 说明 |
| --- | --- | --- | --- |
| `watchToken(contract)` | shared | controller | 增加一个被监控的 ERC-20 合约（仅存地址，不入参 symbol/decimals） |
| `unwatchToken(contract)` | shared | controller | 取消监控某合约 |
| `getWatchedTokens()` | query | 公开 | 返回当前被监控合约列表 |
| `registerDepositAddress(owner, addr)` | shared | controller | 注册某用户的充值地址（`addr` 强制 `0x`+小写）；ERC-20 路径能跑通的前提 |
| `unregisterDepositAddress(addr)` | shared | controller | 注销某充值地址 |
| `getDepositAddresses()` | query | 公开 | 返回当前所有被监控充值地址 |
| `getConfirmedDeposits()` | query | 公开 | 返回已达确认阈值的永久存档（**当前为全量返回**，见 §6） |
| `scanAll()` | shared | 公开 | 手动触发一次 `scanBlocks`（调试 / 补扫用） |
| `getDeployMode()` | query | 公开 | 固定返回 `"production"` |
| `cyclesBalance()` | query | 公开 | 返回当前 cycles 余额（运维监控用） |

> 所有 `controller` 接口当前只能由 controller 或受权的 backend 调用。实际部署时需要由 backend（被授权为 controller 或经中间方法）在用户开通充值地址时调用 `registerDepositAddress`。

## 5. 部署与接线

- **构建配置**：`icp.yaml`（新增 `eth-deposit-detector` canister + 加入 `engine`/`subnet` 环境）与 `mops.toml`（新增 `[canisters.eth-deposit-detector]` 指向 `src/eth-deposit-detector/main.mo`）已接入。
- **backend 接线**：`src/backend/main.mo` 新增 `setEthDetector(principal)` / `getEthDetector()`，并把 `creditAndRegister`、`checkDepositAdmission`、`admitDeposit` 三个记账入口的调用方白名单扩展为「bridge **或** eth-deposit-detector **或** controller」。
- **EVM-RPC**：通过 `Constants.evmRpcMainnet()`（主网，`#EthMainnet(?[#PublicNode])`）访问 EVM-RPC canister `7hfb6-caaaa-aaaar-qadga-cai`。

## 6. 已知限制 / TODO（百万规模配套项）

1. **`depositsConfirmed` 无限增长**：永久存档数组会随用户量长期膨胀，撑高 canister 内存。已在该变量处标 `TODO`——需分桶存储 / backend 消费后清理。（已实现 `confirmedKeys` 防重复，但存档本身未限容）
2. **全量返回接口**：`getDepositAddresses()` / `getConfirmedDeposits()` 当前返回整个数组，百万级会撑爆 query 响应，**需加分页**。
3. **逐个注册不可行**：`registerDepositAddress` 一次只注册一个地址，100 万地址需调用 100 万次，**需提供批量注册接口**（如 `registerDepositAddresses([(owner, addr)])`）。
4. **ETH 逐笔解析成本**：`getBlock` 拿到区块哈希列表后，需对每笔交易调一次 `eth_getTransactionByHash`（`evmGetTx`）。主网单块 100~300+ 笔交易 → 每块几百次串行 RPC（单块约 1~3T cycles、较慢），百万地址下成本偏高；若需优化可改回 `eth_getBlockReceipts`（一次拿整块 receipt，但该方法是 Erigon 起家、部分 provider 可能不支持）。
5. **全量 Transfer 日志量级**：ERC-20 路径整块拉取全部 Transfer 日志，活跃区块的 Transfer 事件可能数千条，若超过 provider 单次 `eth_getLogs` 返回上限，`ethGetLogs` 返回 `null` → 该块标记失败、下一轮重试。必要时加 `GetLogsRpcConfig.responseSizeEstimate` 或回退按合约分批。

## 7. 代码结构

```
src/eth-deposit-detector/
├── main.mo          // detector actor：扫描调度、链上读取、解析、存储、公开接口
├── Types.mo         // Transfer / Deposit 类型定义（竖排）
├── Constants.mo     // 链配置、扫描参数、cycles 预算、EVM-RPC 构造
├── EvmRpcTypes.mo   // EVM-RPC canister 的 Candid 类型子集
├── Hex.mo           // 十六进制解析：lowerHex / topicToAddress / hexToNat 等
└── README.md        // 本文件
```
