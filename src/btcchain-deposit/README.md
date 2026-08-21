# btcchain-deposit（BTC 充值检测后端）

## 1. 模块定位

`btcchain-deposit` 是多链 DEX 中**专门负责 Bitcoin（BTC）充值检测**的独立 canister。职责边界与 `eth-deposit-detector` / `solchain-deposit` 完全对称：

> **只做一件事：扫链 → 解析入金 → 存进地图（deposits）。不负责入账。**

- 检测到一笔确认的 BTC 入金（交易的某个 output 支付给被监控地址）后，存入 `deposits`，并在达到确认数（区块深度）后移入 `depositsConfirmed` 永久存档。
- **入账（给用户加余额）不在本模块内**：由 backend 读取 `depositsConfirmed` 后完成（BTC→本 detector，ETH→eth-deposit-detector，SOL→solchain-deposit，每资产单点入账）。

## 2. 整体工作流程

### 2.1 检测模型：逐区块扫描（block-by-block）

> 与 SOL 版的 `getBlock` 逐区块模型完全对齐。**不再按地址轮询 `get_utxos`**——BTC 主网 `get_utxos` 只能按地址查、且看不到「谁付给我」，无法做无状态的全链扫描；因此改为像 SOL 那样**逐区块读原始区块、解码、比对 scriptPubKey**。

每轮扫描流程：

1. **取链尖高度** `get_current_block_height` → `tip`。
2. **确定扫描窗口**：`safeTip = tip − DELAY_BLOCKS(1)`（保守地只扫已稳定的区块），本轮回填到 `min(safeTip, blockHeight + MAX_BLOCKS_PER_SCAN(10))`。
3. **取每个区块的 hash**：`get_block_headers(start=h, end=h)` 返回该高度的 `BlockHeader.block_hash`。
4. **取原始区块**：`get_block(block_hash)` 返回整块序列化字节 `Blob`。
5. **解码**：`Block.decodeBlock(raw)` 遍历块内每笔交易的每个 output，抽出 `{ script : Blob, value : Nat64, txIndex, vout }`（无需解析 txid / 输入脚本 / witness）。
6. **地址匹配**：把每个 output 的 `script` 经 `BtcAddr.scriptToAddress` **反向转换成规范地址**，去 `watchedAddresses` 里查（不匹配的脚本形状——OP_RETURN / P2PK / 多签等——直接返回 null 跳过）。
7. 命中 → `recordDeposit`（dedupKey = `blockHex # txIndex # vout`，upsert 幂等）。

### 2.2 游标推进与失败重试（对齐 SOL）

- `blockHeight` 是扫描游标。首次运行跳到 `tip − DELAY_BLOCKS − MAX_BLOCKS_PER_SCAN`，之后每轮向前推进。
- 某高度 `get_block` / `decodeBlock` 失败 → 停在当前高度，下轮重扫（dedup 幂等，重扫不会重复入库）。
- 定时触发：`Timer.recurringTimer(#seconds(SCAN_INTERVAL_SEC=15), scanBlocks)`。

### 2.3 地址注册与匹配

- `registerDepositAddress(owner, addr)` 调用 `BtcAddr.addressToScript(addr)` 做**注册时校验**（base58 双重 SHA256 / bech32(bech32m) polymod 校验和 + 支持类型），拼错即拒；通过后把 `addr` 登记进 `watchedAddresses`（addr↔owner）。**不再维护 `watchedScripts` 脚本表**。
- 扫描热路径反向走：每个 output 的 scriptPubKey 经 `BtcAddr.scriptToAddress(script, hrp)` 转回规范地址，与 `watchedAddresses` 直接比对。
- 支持类型（标准形状白名单）：P2PKH（base58 v0）、P2SH（base58 v5）、P2WPKH（bech32 v0-20）、P2WSH（bech32 v0-32）、P2TR / Taproot（bech32m v1-32）；其余一律 null。要求地址为小写规范形式（大写 bech32 会在注册校验时被拒）。base58 版本字节固定为主网（0x00 / 0x05）。
- **匹配是完全匹配**：注册串与扫描侧重编码串**逐字符相等**才命中（`Map.get` 精确键查找，无前缀/包含/模糊）。注册时校验 bech32 HRP 与所扫网络一致——主网部署注册 `tb1…`/`bcrt1…` 直接 trap（否则扫描侧用 `bc` 重编码成不同字符串，静默永不匹配）；base58 测试网版本字节（0x6f/0xc4）由 `BtcAddr` 拒绝。
- **锁定 / 不可花费的 output 永远不会入充值表**：匹配是与注册地址的脚本**逐字节相等**，所以任何「内嵌用户地址但带锁」的脚本（CLTV/CSV 时间锁、哈希锁 HTLC、多签包裹、OP_RETURN 携带地址数据）都不可能命中；非标准 witness 程序在注册与扫描**两侧同时被拒**——v0 非 20/32 字节是共识不可花费（永久锁定），v1 非 32 字节 / v2–v16 是 anyone-can-spend（语义未定义，任何人都可花走）。
- bech32 HRP（`bc` / `tb` / `bcrt`）由 `Constants.BTC_NETWORK` 推导，与所扫网络一致，保证 script→address 与注册地址逐字符一致；校验和变体按 BIP350 严格配对（v0↔bech32、v1↔bech32m），错配地址直接拒绝。
- 扫描活性保障：`scanBlocks` 用 try/catch 兜底释放 `scanning` 标志——即使 `Block.decodeBlock` 在畸形区块上 trap（已加截断保护，正常返回 null），也不会把扫描锁死到下次升级。

### 2.4 入金判定与确认数 `confirmDeposits(tip)`

- BTC 原生模型：output 出现在被监控 scriptPubKey 即视为入金。`from` 不可见（UTXO 无显式 sender），统一留空。
- `amountRaw` = `value`（satoshi，已是最小单位，无需换算）。
- 确认数（已 mined 的 output）：`confirmations = if (tip >= height) { tip − height + 1 } else { 0 }`（移除了旧的 `height == 0` 特判，统一用链尖深度）。
- `confirmations >= CONFIRMED_CONFIRMATIONS(6)`：移出 `deposits`，追加进永久存档 `depositsConfirmed`，并登记 `confirmedKeys`（防重复入库）；迭代结束后再统一删除。
- 未达阈值：仅刷新 `confirmations`。

## 3. 关键设计要点

| 关注点 | 做法 |
| --- | --- |
| 检测模型 | **逐区块扫描**：`get_current_block_height` → `get_block_headers`(取 hash) → `get_block`(原始块) → `Block.decodeBlock` → scriptPubKey 反向转地址比对 `watchedAddresses`。与 SOL 版逐块模型对称，替代旧的按地址 `get_utxos` 轮询 |
| 游标 / 重扫 | `blockHeight` 游标；首跑跳到 `tip − DELAY_BLOCKS − MAX_BLOCKS_PER_SCAN`；失败停当前高度下轮重扫；dedup 幂等 |
| 地址规范 | `BtcAddr`：`addressToScript`（注册时校验）+ `scriptToAddress`（扫描时反向转换）：base58（P2PKH/P2SH）+ bech32/bech32m（P2WPKH/P2WSH/P2TR），拼错即拒 |
| 热路径 | 每个 output 的 scriptPubKey 反向解码为规范地址后查 `watchedAddresses`；不支持的脚本形状直接 null 跳过。反向转换对块内全部 output 执行（含校验和计算），成本高于旧版 hex 比对，见 §6 |
| 去重 | 去重键 = `blockHex # txIndex # vout`；`deposits` + `confirmedKeys` 双查防重复入库；`postupgrade` 从 `depositsConfirmed` 回填 `confirmedKeys` |
| 幂等 / 防重组 | `CONFIRMED_CONFIRMATIONS=6` 阈值、`tip − height + 1` 深度判定、`recordDeposit` upsert |
| 金额 | `value` 已是 satoshi（最小单位），直接作为 `amountRaw`，无 decimal 换算 |
| RPC 接入 | 经 dfinity bitcoin canister `mgi-tqaaaa-aaaar-qaqoa-cai` 的 typed 接口：`get_current_block_height` / `get_block_headers` / `get_block`（原始 Blob，Candid 直接解码，无需 JSON-RPC 文本解析）；主网 `#mainnet`。`get_utxos` / `get_balance` 仍保留在类型中但扫描不再使用 |

## 4. 公共接口

| 接口 | 类型 | 权限 | 说明 |
| --- | --- | --- | --- |
| `registerDepositAddress(owner, addr)` | shared | controller | 注册某用户的 BTC 充值地址；`addr` 经 `BtcAddr.addressToScript` 解码 + 校验和校验（拼错即拒），登记 `watchedAddresses`（addr↔owner） |
| `unregisterDepositAddress(addr)` | shared | controller | 注销某充值地址（从 `watchedAddresses` 删除） |
| `getDepositAddresses()` | query | 公开 | 返回当前所有被监控充值地址 |
| `getConfirmedDeposits()` | query | 公开 | 返回已达确认阈值的永久存档（**当前为全量返回**，见 §6） |
| `scanAll()` | shared | 公开 | 手动触发一次 `scanBlocks`（调试 / 补扫用） |
| `getDeployMode()` | query | 公开 | 固定返回 `"production"` |
| `cyclesBalance()` | query | 公开 | 返回当前 cycles 余额（运维监控用） |

> 所有 `controller` 接口现阶段只能由 controller 或受权的 backend 调用。实际部署时需要由 backend（被授权为 controller 或经中间方法）在用户开通充值地址时调用 `registerDepositAddress`。

## 5. 部署与接线

- **构建配置**：`icp.yaml` 与 `mops.toml`（新增 `[canisters.btcchain-deposit]` 指向 `src/btcchain-deposit/main.mo`）已接入。
- **backend 接线**：backend 新增 `setBtcDetector(principal)` / `getBtcDetector()`，并把 `creditAndRegister` 等记账入口的调用方白名单扩展为「bridge **或** eth-deposit-detector **或** solchain-deposit **或** btcchain-deposit **或** controller」。
- **bitcoin canister**：通过 `Constants.btcCanisterMainnet()`（主网）访问 `mgi-tqaaaa-aaaar-qaqoa-cai`，`#mainnet`。

## 6. 已知限制 / TODO（百万规模配套项）

1. **`depositsConfirmed` 无限增长**：永久存档数组会随用户量长期膨胀，撑高 canister 内存。已在该变量处标 `TODO`——需分桶存储 / backend 消费后清理。
2. **全量返回接口**：`getDepositAddresses()` / `getConfirmedDeposits()` 当前返回整个数组，百万级会撑爆 query 响应，**需加分页**。
3. **逐个注册不可行**：`registerDepositAddress` 一次只注册一个地址，100 万地址需调用 100 万次，**需提供批量注册接口**。
4. **`get_block` 带宽 / cycles 成本**：逐区块模型每轮最多读 `MAX_BLOCKS_PER_SCAN(10)` 个原始区块（单块可达 1–4 MB），cycles 与解码成本远高于旧版「按地址 `get_utxos`」。需关注：(a) 落后太多时游标会渐进追赶，首跑可能多轮才能追上链尖；(b) 超大区块（含大量非相关交易）解码有固定开销，必要时应引入只扫相关高度的窗口化 / 限制并发。相较旧模型，RPC 次数不再随「地址数」线性增长，而随「区块数」增长，更适合大规模用户。
5. **扫描热路径反向转换成本**：`scriptToAddress` 对块内**每个** output 执行（含 base58 除法循环 / bech32 polymod 校验和计算），单块数千 output 时指令开销显著高于旧版「script hex 查表」。若实测逼近消息指令上限或 cycles 偏高，可加预筛优化：先比对 witness program / hash160 的 hex 是否命中（等价于恢复轻量脚本键），命中才做完整地址编码。

## 7. 代码结构

```
src/btcchain-deposit/
├── main.mo          // detector actor：扫描调度、链上读取、解析、存储、公开接口
├── Types.mo         // Transfer / Deposit 类型定义
├── Constants.mo     // 链配置、扫描参数（DELAY_BLOCKS / MAX_BLOCKS_PER_SCAN / SCAN_INTERVAL_SEC / CONFIRMED_CONFIRMATIONS / BTC_RPC_CYCLES）、bitcoin canister 构造
├── BtcRpcTypes.mo   // bitcoin canister 的 Candid 类型子集（get_current_block_height / get_block_headers / get_block / get_utxos / get_balance）
├── BtcAddr.mo       // 地址 ⇄ scriptPubKey 双向转换器：addressToScript（注册校验）+ scriptToAddress（扫描反向转换），base58 + bech32/bech32m；无 Word32/位运算环境下用 + * / % 模拟 polymod 与 5↔8 转换
├── Block.mo         // 【新增】原始比特币区块解码器（legacy + segwit/BIP141，含 witness 段处理防游标错位）
└── README.md        // 本文件
```
