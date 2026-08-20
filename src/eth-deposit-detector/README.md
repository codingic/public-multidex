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

**A. ETH 原生转账（无日志，必须靠 receipt）**
- 一次 `eth_getBlockReceipts` 拿到整块所有 receipt，提取每条的 `transactionHash` 与 `to`（`to == null` 的合约创建交易直接跳过）。
- 只对本块中 `to` 命中 `watchedAddresses` 的交易，补一次 `eth_getTransactionByHash` 取 `value`，再 `recordDeposit`。
- **为什么这样设计**：原生 ETH 转账不发日志，`eth_getLogs` 查不到；若改成逐笔 `eth_getTransactionByHash`，主网单块 100~300+ 笔交易就要几百次 RPC（单块 1~3T cycles、串行极慢）。改成整块 receipt 一次 RPC，RPC 次数从「每块几百次」降到「每块几次命中」，百万地址下才成立。

**B. ERC-20 转账（有 Transfer 日志）**
- 把 `watchedTokens`（约 200 个）按 `LOG_ADDR_BATCH(100)` 切片，每批一次 `eth_getLogs`，链上用 `addresses = [batch]` 按合约过滤——返回日志量小、可控、不会被 provider 截断。
- 每条日志本地走 `extractLogEntry`：先校验 `topics`（Transfer 事件、topic 数量 ≥ 3、topic[2] 为目标地址），再用 `Map.get(watchedAddresses, recipient)` 匹配收款地址，命中才入库。

### 2.4 确认数与存档 `confirmDeposits(tip)`
每次扫描推进后调用：
- 遍历 `deposits`，刷新 `confirmations = tip - blockHeight`（不足则记 0）。
- `confirmations >= CONFIRMED_BLOCKS(35)`：移出 `deposits`，追加进永久存档 `depositsConfirmed`，并登记 `confirmedKeys`（防重复入库）；迭代结束后再统一删除，避免在 map 迭代中删当前键。
- 未达阈值：仅刷新 `confirmations` 字段。

## 3. 关键设计要点

| 关注点 | 做法 |
| --- | --- |
| 百万充值地址 | 过滤尽量推到链上（ERC-20 按合约 `addresses` 过滤）；本地只用 `Map.get(watchedAddresses, …)` 做 O(log n)≈20 次比较，百万级毫无压力 |
| ETH 检测成本 | `eth_getBlockReceipts` 整块一次 RPC + 命中才补 value，而非逐笔查询 |
| 地址规范化 | `registerDepositAddress` 强制归一成 `0x` + 小写，与日志 topic 派生的 key 一致，否则会**静默漏检全部 ERC-20 充值** |
| 重复入库防护 | 去重双查 `deposits` + `confirmedKeys`；`postupgrade` 从已有 `depositsConfirmed` 回填 `confirmedKeys` |
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
4. **`eth_getBlockReceipts` 响应上限**：`responseSizeEstimate` 与 cycles 为经验值；若某区块 receipt 体积超过 provider 上限，该接口返回 `[]`，**该块 ETH 会被漏扫**（不影响 ERC-20 分支）。极端活跃区块建议加 per-block retry 或回退方案。
5. **provider 截断风险**：ERC-20 路径按合约过滤后日志量已很小，但理论超大区块仍可能被截断；`eth_getLogs` 返回 `Err` 时本模块返回 `[]`（不崩溃，但漏扫该块）。

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
