# solchain-deposit（SOL 充值检测后端）

## 1. 模块定位

`solchain-deposit` 是多链 DEX 中**专门负责 Solana（SOL / SPL Token）充值检测**的独立 canister。职责边界与 `eth-deposit-detector` 对称：

> **只做一件事：取交易 → 解析入金 → 存进充值表（deposits / depositsConfirmed）。不负责入账。**

- 检测到一笔确认的 SOL / SPL 入金后，存入 `deposits`，并在达到确认深度后移入 `depositsConfirmed` 永久存档。
- **入账（给用户加余额）不在本模块内**：由 backend 读取 `depositsConfirmed` 后完成。

## 2. 检测模型：按地址取交易记录（与 ETH 读块不同）

ETH 检测器是「整块扫 `eth_getBlockByNumber` + 本地过滤」。Solana 没有可整块拉取的全局 Transfer 日志，因此本模块改为**按地址增量取交易记录**——这也是 Solana 索引器的标准做法。

**触发方式：仅外部触发，无定时器。** backend 周期性（或按需）对每个被监控地址调用 `refreshAddressTx(addr)`，canister 随即：

1. `getSignaturesForAddress(addr, { commitment: finalized, until: cursor, before: …, limit })` 增量取该地址的新交易签名（每地址维护 `lastSignature` 游标，`before` 翻页，页数封顶 `MAX_SIG_PAGES`）。
2. 对每个新签名 `getTransaction(sig, { encoding: jsonParsed, commitment: finalized })` 取完整交易。
3. 复用解析逻辑提取入金，写入充值表。

### 2.1 地址模型（SOL vs SPL）

| 资产 | 监控的地址 | 说明 |
| --- | --- | --- |
| SOL | **owner 钱包**（`registerDepositAddress` 注册，存 `watchedAddresses`） | 原生 SOL 入账是 system transfer，`destination == owner 钱包`，该钱包在交易账户列表里 → `getSignaturesForAddress(owner)` 能取到 |
| SPL | **ATA**（`watchedAddresses` 只存 owner 钱包；ATA 由 `(owner, mint, tokenProgram)` 在 canister 内通过 `Ata.ataAddress` 派生，从不存储/注册） | 纯入金 SPL 时 **owner 钱包不在交易账户列表里**（列表里只有 ATA / mint / program），查 owner 会漏；必须查 ATA |

**ATA 在 canister 内派生（含 ed25519 off-curve / PDA 拒绝校验）**：
```
ATA = Ata.ataAddress(owner, mint, tokenProgramId)   // 等价于 Solana SDK find_program_address
    = SHA-256(owner ‖ mint ‖ tokenProgramId ‖ [bump] ‖ ATA_PROGRAM_ID ‖ "ProgramDerivedAddress")
      取第一个「不在 ed25519 曲线上」的 32 字节哈希（bump 从 255 递减；实践中恒为 255）
```
- `ATA_PROGRAM_ID = ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL`
- `tokenProgramId`：legacy SPL = `TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA`；Token-2022 = `TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb`。**必须按 mint 归属选对 program**（backend 用 `watchToken` 注册 legacy、`watchToken2022` 注册 Token-2022），否则派生出错误的 ATA。
- `Ata.mo` 的 off-curve 校验与 Solana SDK `find_program_address` 逐字节一致：已用 5000 组随机 `(owner, mint, program)` 派生 + 30000 组逐哈希 `bytes_are_curve_point` 校验，与 SDK **100% 匹配**（含已知向量 `Fcuc4KJvU6yamqSvbhajvCQWfJJwSyMD6Vq6FPgV4vCT`）。校验逻辑即 RFC 8032 `CompressedEdwardsY::decompress()`：32 字节按**小端**解释、掩掉符号位（byte31 0x80）、拒绝 `>= P` 的非规范编码，再用欧拉判别法判 `x²=(y²−1)/(d·y²+1)` 是否有平方根。

### 2.2 增量游标（避免重放历史）

- 每地址 `lastSignature` 游标记录**已处理到的最新签名**。
- **首次刷新**（游标为空）：只把游标设为当前最新签名，**不处理历史**（避免把远古历史误当充值）。backend 应在注册后尽快触发首次刷新。
- **后续刷新**：`until: cursor` 取比游标新的签名（`before` 逐页往回翻，直到碰到游标或页数封顶），处理完毕后游标前移到本轮最新签名。
- `getSignaturesForAddress` 只返回 finalized 交易，故取到的都是不可逆交易。

### 2.3 单笔交易解析（`processTxJson` → `extractTransfers`）

**A. SOL 原生转账（System Program）**
- 遍历 `transaction.message.instructions` + `meta.innerInstructions`，找 `program == "system"` 且 `parsed.type == "transfer"` 的指令，取 `parsed.info.destination`（收款地址）与 `parsed.info.lamports`。
- `destination ∈ watchedAddresses` 且 `lamports > 0` 才 `recordDeposit`。
- 说明：原生 SOL 转账由 System Program 处理，**不存在 `transferChecked` 变体**（checked 概念仅属于 SPL Token Program），故此处只匹配 `transfer` 即可，不构成遗漏。

**B. SPL Token 转账（仅 `transfer` / `transferChecked` 入账，逐指令取额）**
- 逐条遍历 `transaction.message.instructions` + `meta.innerInstructions`（`allInstructions`），每条指令用 `splTransferOf` 解析出 `(source, destination, amount)`：
  - **parsed 路径**：jsonParsed 已给出 `parsed.type ∈ {transfer, transferChecked}` 且 `parsed.info` 含 `source`/`destination`/`amount`（top-level 与已解析的 inner 都走这条）。
  - **raw 路径（关键）**：`getTransaction`(jsonParsed) 的 **inner instructions 通常不被解析**（只剩 `data`/`accounts`/`programIdIndex`）。此时对 `data` 做 base58 解码，读判别字 `byte[0]`（3=transfer, 12=transferChecked）与金额 `byte[1:9]`（小端 u64，等同 Go 的 `binary.LittleEndian.Uint64(byteInsParam[1:9])`）；`source` 恒为 `accounts[0]`，**`destination` 在 `transfer` 为 `accounts[1]`、`transferChecked` 为 `accounts[2]`（`accounts[1]` 是 mint，绝不能当目标）**，经 `accountPubkey` 解析账户索引；长度守卫 `transfer` 需 ≥3、`transferChecked` 需 ≥4 个账户。程序 id 必须是 `Tokenkeg…` 或 `Tokenz…` 才解读字节。这条路径覆盖 **CPI 内的转账**（DEX 兑换下发、质押奖励等），避免被漏检。（注：Go 参考后端仅注册 legacy `Tokenkeg…`，canister 另经 `watchToken2022` 覆盖 `Tokenz…`，两者判别字相同。）
- 金额取自指令自身（parsed 取 `parsed.info.amount`，raw 取解码出的小端 u64），**不再使用 `postTokenBalances` 差额**。每一条指令独立记一笔入金，dedup key = `signature#spl#指令索引`（同 tx 多笔转入同一 ATA 互不合并）。
- 目的地 token 账户经 `postTokenBalances`（按 `accountIndex` → `accountPubkey` 映射）解析出 `(owner, mint)`，仅当 `owner ∈ watchedAddresses && mint ∈ watchedTokens` 才入账（既用于确权，也用于把 source 解析成发送方钱包）。
- `from` 填为**发送方钱包**：源 token 账户（`source`）的 owner；源账户不在 `postTokenBalances` 时回退为源账户公钥。
- **排除法天然成立**：`mintTo`、ATA 创建、Burn 等指令 `parsed.type` 不符，raw 路径下判别字也不是 3/12，都不会进入本分支，不可能被误判为入金。
- SOL 侧：`findSolTransfers` 只处理 `program == "system" && itype == "transfer"`，无 checked 变体、无 mint 概念。
- 失败交易（`meta.err` 非 null 对象）整体跳过，不计入。

### 2.4 确认与存档 `confirmDeposits(tip)`

每次成功刷新后调用：遍历 `deposits`，刷新 `confirmations = tip − slot`；达到 `CONFIRMED_SLOTS(32)` 的移入 `depositsConfirmed` 并登记 `confirmedKeys`。因所有交易均以 `finalized` 取出，确认深度基本即时满足。

## 3. 关键设计要点

| 关注点 | 做法 |
| --- | --- |
| 检测模型 | 按地址 `getSignaturesForAddress` 增量取签名 + 逐个 `getTransaction` 解析（标准 Solana 索引器模式），与 ETH 读块模型不同 |
| 触发 | **仅外部触发** `refreshAddressTx(addr)`，无定时器；节奏由 backend 调度 |
| SPL 覆盖 | SPL ATA 在 canister 内由 `(owner, mint, tokenProgram)` 经 `Ata.ataAddress` 派生，从不存储；`refreshAddressTx` 对每个 watched mint 派生 ATA 后轮询，才能取到纯入金 SPL |
| 地址规范 | base58 大小写敏感；`registerDepositAddress` 用 `Base58.isValidSolanaAddress`（解码后正好 32 字节）强校验；`watchToken` / `watchToken2022` 注册 mint 时同样做 32 字节校验 |
| 重复防护 | dedup key = `signature#sol#指令索引` / `signature#spl#账户索引`；`deposits` + `confirmedKeys` 双查；`postupgrade` 回填 `confirmedKeys` |
| 幂等 | 取数失败则中止本轮、不前移游标（下轮重试）；单签 `getTransaction` 失败则停在该签、游标停在最后一个成功签 |
| RPC 接入 | 经 dfinity `sol-rpc` canister `tghme-zyaaa-aaaar-qarca-cai` 的 `jsonRequest`（通用 JSON-RPC 转发），统一发 `getSlot` / `getSignaturesForAddress` / `getTransaction`，结果用 `mo:json` 解析 |

## 4. 公共接口

| 接口 | 类型 | 权限 | 说明 |
| --- | --- | --- | --- |
| `refreshAddressTx(addr)` | shared | controller | **核心入口**：刷新某 watched 地址（owner 或 ATA）的充值记录，从链上取新交易并存入充值表 |
| `registerDepositAddress(owner, addr)` | shared | controller | 注册 SOL 充值地址（owner 钱包，严格 32 字节校验） |
| `unregisterDepositAddress(addr)` | shared | controller | 注销 SOL 充值地址（并清游标） |
| `getDepositAddresses()` | query | 公开 | 返回所有被监控 SOL 充值地址 |
| `watchToken(mint)` | shared | controller | 注册被监控的 legacy SPL mint（canister 内据此为每个 owner 派生 ATA） |
| `watchToken2022(mint)` | shared | controller | 注册被监控的 Token-2022 mint（使用 Token-2022 program 派生 ATA） |
| `unwatchToken(mint)` | shared | controller | 注销被监控 mint |
| `getWatchedTokens()` | query | 公开 | 返回所有被监控 mint |
| `getWatchedTokenPrograms()` | query | 公开 | 返回 `(mint, tokenProgramId)` 列表 |
| `getConfirmedDeposits()` | query | 公开 | 返回已达确认阈值的永久存档（**当前为全量返回**，见 §6） |
| `getDeployMode()` / `cyclesBalance()` | query | 公开 | 运维查询 |

> `refreshAddressTx` / `register*` 目前限 controller。backend 须被设为 controller（或改授权）后才能驱动检测。

## 5. 部署与 backend 接线

- **构建配置**：`mops.toml` 已含 `[canisters.solchain-deposit]` 指向 `src/solchain-deposit/main.mo`；依赖 `core / json / sha2`，其中 `sha2` 供 `Ata.mo` 做 ATA 派生所需的 SHA-256。
- **backend 接线**：
  1. 用户开通 SOL 充值：`registerDepositAddress(owner, solAddr)`；对每个要监控的 SPL mint 调 `watchToken(mint)`（legacy）或 `watchToken2022(mint)`（Token-2022）。**ATA 不再由 backend 派生/注册**——`refreshAddressTx` 会对每个 watched mint 自动派生 ATA 并轮询。
  2. 周期/按需：对每个注册的 SOL 地址（`getDepositAddresses()`）调用 `refreshAddressTx(addr)`，canister 内部会顺带轮询该 owner 的全部派生 ATA。
  3. 读 `getConfirmedDeposits()` 取存档完成入账。
- **sol-rpc**：`Constants.solRpcMainnet()`（主网，`#Default(#Mainnet)`）→ canister `tghme-zyaaa-aaaar-qarca-cai`。

## 6. 已知限制 / TODO

1. **`depositsConfirmed` 无限增长**：永久存档数组随用户量长期膨胀，需分桶 / backend 消费后清理。
2. **全量返回接口**：`getDepositAddresses()` / `getConfirmedDeposits()` 当前返回整个数组，百万级需分页。
3. **逐个注册/逐个刷新**：注册与 `refreshAddressTx` 都是单地址粒度，百万地址需批量接口 + 分片/队列化。
4. **签名截断**：单地址单轮最多取 `SIG_LIMIT × MAX_SIG_PAGES`(25×4=100) 条新签名，突发高频入账会延后到下轮（dedup 保证不重复；游标本轮不越过未取到的旧签名，故不丢，只会慢）。
5. **历史深度依赖 provider**：`getSignaturesForAddress` 的可查历史受 provider 保留窗口限制；深历史（超出窗口）充值查不到，需归档节点/索引服务。
6. **cycles 预算**：`SOL_RPC_CYCLES = 10B` 按调用计；`refreshAddressTx` 一轮含 1×getSignaturesForAddress + N×getTransaction + 1×getSlot，建议在测试网实测单次成本。

## 7. 代码结构

```
src/solchain-deposit/
├── main.mo          // detector actor：refreshAddressTx 入口、取数、解析、存储、公开接口
├── Types.mo         // Transfer / Deposit 类型定义
├── Constants.mo     // 链配置、按地址扫描参数、cycles 预算、sol-rpc 构造
├── SolRpcTypes.mo   // sol-rpc canister 的 Candid 类型子集（jsonRequest 等）
├── Ata.mo           // SPL Associated Token Account (ATA) 派生 + ed25519 off-curve 校验
├── Base58.mo        // base58 字母表校验 + isValidSolanaAddress（32 字节严格校验）
└── README.md        // 本文件
```
