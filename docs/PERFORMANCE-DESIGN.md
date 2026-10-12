# 索引层性能设计（SearchIndex）

本文件记录 SearchIndex 层的性能测量方法、本轮改动、以及**尚未解决**的部分。
所有数字都来自本机实际执行，不是估算。测量环境、命令与原始输出见文末。

## 重要更正：两个口径不能混用

上一版把「全库无 filter」读路径的 10.26 s → 0.43 s 当作主要成果，那**不能外推到 App 的真实路径**。
App 走的是 `entries(volumeID:)`，即单卷形状。合成单卷库（20 万行）实测：

| 读形状 | 耗时 | 说明 |
|---|---|---|
| `entries(volumeID:)`（含 ORDER BY，**App 现状**） | 129.60 ms | 索引自带顺序，无临时排序，但仍逐行随机回表 |
| `entriesUnordered(volumeID:)`（新增） | **70.12 ms** | 顺序表扫描 |
| `entries()` 全库无序 | 60.16 ms | 表扫描 |
| `snapshot()`（单事务内） | 60.26 ms | |

即：`ORDER BY` 在单卷下虽然**不产生额外排序**（EXPLAIN：`SEARCH … USING INDEX idx_nodes_path (volume_id=?)`，
无 `USE TEMP B-TREE FOR ORDER BY`），但**仍是索引遍历 + 每行一次随机 rowid 回表**，比表扫描贵约 1.85×。
所以「ORDER BY 免费」只代表没有额外排序，不代表没有代价。

结论：给 App 一个可选的 unordered 流式快照 API（见下），由 UI 决定是否采用。

## 语义回归修复（优先级高于速度）

### 第一批：窄查询与排序结构（由主控 `PerformanceRegressionTests` 捕获）

性能改动一度引入四个真实语义回归，均由主控的 `PerformanceRegressionTests` 捕获，已修复：

1. **去重从 `Set<EntryKey>` 降成 `Set<Int64>`** —— App 每卷一个独立 SQLite 文件，每个库的
   AUTOINCREMENT 都从 1 开始，节点号跨卷必然重复，降级后会直接丢掉另一个卷的文件。
   已恢复完整 `EntryKey` 去重。
2. **`packPrefix` 没有右补零** —— 原实现把字节左移累积，`"b"` 得 0x62、`"aa"` 得 0x6161，
   整数比较会认为 `"b" < "aa"`，与字节字典序相反。已改为高位对齐、右侧补零，空串得 0。
3. **窄查询在前缀相同时先比长度** —— `"abcdefghay"` 与 `"abcdefghz"` 前 8 字节相同，
   长度优先会把 `…z` 排在 `…ay` 之前，与完整键顺序矛盾。已改为**先比第 9 字节起的剩余字节，
   相等后才比长度**；`ordered()` 与窄查询排序两处都改了。
4. **`Double` 承载 2^53 以上整数** —— 文件大小用 `Double` 会让 2^53+1 与 2^53 同值后按 nodeID 错排。
   已改为大小用 `Int64`、时间用 `Double`、前缀用完整 `UInt64` 三槽并存，各自精确。

另外修正了自己两个测试真错误（不是放宽）：「预算」夹具不存在（改为独立的预算夹具）、
snapshot 代际断言忘了注册卷也会推进代际（改为采集真实写入代际对比）。

### 第二批：全序决胜（由主控整包验收捕获）

主控整包 408 tests / 46 suites 验收抓到 `SearchEngineAcceptanceTests.orderingIsStrictTotalOrderWithKeyTiebreaker`
四个用例全红（sort=name/path × 升/降，同名同路径的四个条目）。两个根因，都是**相同键没有被判为相同**：

5. **窄查询：完整字节相同且长度相同被判成 Desc** —— `memcmp == 0` 之后直接
   `ordering = ar.count < br.count ? .orderedAscending : .orderedDescending`，长度相等落到 `Desc`。
   于是一组同键条目两两都判「大于」，`(volumeID, nodeID)` 决胜**永远不执行**，
   升序结果退化成排序算法的残留顺序（实测：external#9, internal#5, external#3, internal#7）。
   已改为：`memcmp == 0` 后先比长度，**长度也相等就返回 `.orderedSame`**，交给 EntryKey 决胜。
6. **预排序：同 nodeID 跨卷跳过 volumeID 比较** —— `ordered()` 原先写成
   `if left.nodeID != right.nodeID { 比 volumeID … }`，而每卷一个 SQLite 文件、AUTOINCREMENT 都从 1 开始，
   跨卷出现相同 nodeID 是常态而非例外，这一对只能落到 `left.index < right.index`（输入顺序）。
   已改为**无条件先比 volumeID、再比 nodeID**，`index` 只作为 EntryKey 完全相同时的最后兜底。

新增 `Tests/SearchIndexTests/SortTiebreakerRegressionTests.swift` 同时钉住两条路径：
窄查询（9 命中 ≤ `max(64, n/20)`，走实时比较器）与宽查询（73 命中 > 64，走 `init` 里预建的顺序），
name/path × 升/降四种组合都断言**精确全序**；夹具用 >8 字节的完全相同键（含长中文名）、
跨卷复用 nodeID、并把输入顺序打乱到与期望顺序相反，因此任何「退化成输入顺序」的实现都过不了。
降序期望单独写出（主键反转、决胜仍升序），不写成升序的镜像。

## 结论摘要

真实 NTFS 索引（1,026,273 条）上的最大问题**不是解码，而是查询计划**。

| 阶段 | 改动前 | 说明 |
|---|---|---|
| 加载全量（无 filter，旧解码 + ORDER BY） | 10,258.60 ms | App 不走这个形状，仅作对照 |
| 加载单卷（App 真实形状，合成 20 万行） | 129.60 ms | unordered 后 70.12 ms |
| `SearchEngine.init` | 7,510.81 ms | 真实库旧值；合成 30 万条 1800.95 → 775.06 ms |
| 全命中排序 bySize | 2,768.50 ms | 真实库旧值；合成 30 万条 318.61 → 39.57 ms |
| 全命中排序 byName/byPath | 90.47 / 93.32 ms | 走预排序快路径，本轮未变 |

**重要限制**：真实索引 `.build/hardware/ntfs-20261010/real-index-…sqlite` 在上一轮实测过程中
被**非本会话的进程删除**（本会话对该文件只做过 `mode=ro` 读取与 `CatalogReader` 只读打开；
主控已核原路径缺失，UI 会话确认是清理时删了 `.build/hardware`）。**绝不重新扫描外置盘**，
因此真实库的「改动后」数字目前拿不到，合成数据结论不能替代。

## 测量方法

### 为什么需要独立的只读路径

真实索引位于外置盘索引目录。`CatalogStore.init` 以 `SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE`
打开并执行建表与 PRAGMA，用它打开真实索引既不安全（会写）、也会与扫描器抢单写锁。
因此本轮新增 `CatalogReader`：只读打开、只读 PRAGMA、跳过全部 schema 设置。
它同时是交付给 App 的附加 API（见下）。

### 读路径 A/B 的构造

同一个只读连接、同一份 1,026,273 行数据、相同投影列，对比两种解码：

- **旧**：`db.query(sql)` 先把每行物化成 `[SQLiteValue]`（10 列/行，约 1000 万个枚举值），
  再 `compactMap` 成 `IndexedEntry`，中间的数组全部丢弃。
- **新**：`db.forEachRow(sql)` 流式步进，直接从 statement 读列。非文本列零分配，
  文本列每列一次 `String`。

### 合成 A/B 的构造

`SearchIndex` + `SearchCore` 用 `swiftc -O` 编译成单模块可执行文件（绕过整包构建，
因为整包当时被 `SearchUI`/`SearchBench` 的在改代码挡住），生成 30 万条合成条目：
1/3 为 ASCII 词、2/3 为中文词，路径带两层目录，nodeID 按模 3 分到两个卷。
「改动前」版本由当前源码机械回退三处改动（去重回退到 `Set<EntryKey>`、
去掉 8 字节前缀、排序回到 `[Int]` 索引排列）单独编译，两者跑同一份数据。

## 本轮改动与依据

### 1. `entries()` 的排序只在该付钱时才付

实测查询计划：

| SQL | 计划 |
|---|---|
| `… FROM nodes ORDER BY volume_id, relative_path` | `SCAN nodes USING INDEX idx_nodes_path` |
| `… FROM nodes` | `SCAN nodes` |
| `… WHERE volume_id = ? ORDER BY volume_id, relative_path` | `SEARCH nodes USING INDEX idx_nodes_path (volume_id=?)` |

前两种的差别见上表（10.26 s vs 0.61 s）。第三种没有临时排序，但仍逐行随机回表，
所以**保留原 `entries(volumeID:)` 的有序行为**（接口契约不变），另加 unordered 变体供 UI 选择。

### 2. 流式强类型解码（0.61 s → 0.43 s）

新增 `SQLiteConnection.forEachRow` 与 `SQLiteRowReader`，行在步进过程中直接解码成
`IndexedEntry`，不再构造 `[SQLiteValue]`。旧的 `query()` 保留给 `volumes()` /
`checkpoint()` / `pendingPaths()` 这些行数极小的管理查询。

### 3. 排序用密集候选数组，而不是索引排列（bySize 318.61 → 39.57 ms，8.1×）

原实现排序 `[Int]` 下标，比较时每次都要按下标随机访问 ~130 字节的 `Record`
（30 万条 ≈ 39 MB），缓存未命中主导成本。改为先把比较键拷进密集的
`SortCandidate`（`key`/`nodeID`/`index`，24 字节）再排序，原下标随行携带。
这对 `.size` / `.modified` 收益最大，因为它们没有预排序快路径。

### 4. init 的两个预排序同样改密集数组（init 1800.95 → 775.06 ms，2.3×）

`nameOrder` / `pathOrder` 在 init 时对全量索引各排一次，是 init 的主要成本。
改为 `OrderCandidate` 密集排序，与上一条同源。

### 5. 8 字节排序前缀

`Record` 增加 `namePrefix`/`pathPrefix`：折叠后键的前 8 个 UTF-8 字节，大端、右侧补零。
补零保证「短串是长串前缀」时整数序与字节字典序一致，相等则回退到完整比较
（因此仍是严格全序）。绝大多数比较一次整数比较即可判定，不必触碰字节池。

### 6. `foldedKey` 的 ASCII 快路径（424.57 → 389.14 ms）

`folding(options: .caseInsensitive)` 走完整 Unicode 大小写折叠表且总是分配；
ASCII 文本用 `lowercased()`（已小写时直接返回自身）即可，等价且快得多。
`canonicalRelativePath` 同样加了「已经规范则返回原实例」的快路径。
真实库以中文为主，收益约 9%；纯英文卷上会明显更大。

### 7. 去重回完整 `EntryKey`

上一版改成 `Set<Int64>` 是错的（见语义回归 1），已恢复 `Set<EntryKey>`。

### 8. `CatalogReader` 的并发与事务一致性

- `SQLiteConnection` 增加 `NSRecursiveLock`，**所有**对句柄的访问都经过它。
  `SQLITE_OPEN_FULLMUTEX` 只串行化进入 SQLite 的调用，保护不了 Swift 侧的 `statements`
  字典，也保护不了同一个缓存 statement 被两个调用点同时 step。由于 `CatalogReader`
  是持有类引用的 `Sendable` 结构体，副本共享同一个连接，锁必须放在连接上。
- **锁在 `BEGIN` 之前获取**。否则两个线程可以各自 `BEGIN` 成功，随后失败方的
  `ROLLBACK` 会把胜方的事务也回滚掉——这正是并发测试最初 flaky 的原因（修复后连跑 15 次全绿）。
- `snapshot()` 改为在单个 `BEGIN DEFERRED` 只读事务里完成。`DEFERRED` 不会取写锁、
  不会阻塞扫描器，且第一个读之后整个事务固定在同一 WAL 快照上，
  因此 generation / volumes / entries 不可能跨代。**不得改成 `IMMEDIATE`。**
  本轮补修：四个快照入口现在**全部**在单个 `db.readTransaction` 内完成——
  `CatalogReader.snapshot()`、`CatalogReader.snapshotUnordered()`、
  `CatalogStore.snapshotUnordered()`，以及本轮修好的 `CatalogStore.snapshot()`
  （此前它依次读 generation / entries / volumes，三次各自取锁、不在同一事务，
  外部连接并发 `apply` 时会拼出跨代快照；签名、返回类型与 `entries()` 的有序语义均未变）。
  覆盖与**未覆盖**的部分见下方「快照单事务的验证边界」。

### 9. 快照单事务的验证边界

不能把「写了再重复读」当成并发覆盖。现有证据分三层，逐层标明强度：

| 层次 | 用例 | 强度 |
|---|---|---|
| 原语层交错 | `SnapshotTransactionTests.readTransactionPinsSnapshotAcrossExternalCommit` | **真交错**。外部独立连接在读者事务**仍然打开时**提交（提交由事务体内发出，顺序由构造保证，无 sleep / 无轮询），断言事务内第二次读仍是提交前的代际与行数；事务结束后同一连接立刻读到新版本。若 `readTransaction` 退化为多次独立读，这两处断言会直接失败。 |
| 公共快照不变量 | `SnapshotTransactionTests.snapshotIsSingleVersionWhileExternalWriteIsInFlight` | 外部连接持有**未提交**写事务（多一行 + 推进一代）时，`CatalogStore.snapshot()` 与 `snapshotUnordered()`、`CatalogReader.snapshot()` 的 generation / 行集合 / 卷集合必须同属一个版本；提交后三元组整体翻转且仍同版本。 |
| 静止期稳定性 | `CatalogReaderTests.repeatedSnapshotsAreSelfConsistent`（原名 `snapshotIsTakenInOneReadTransaction`，已改名） | **只证明稳定，不证明原子**。夹具在读之前就没有并发写入，原用例名与注释夸大了它。已加断言 `generation` 与卷 ID，并在注释里指向真正的交错用例。 |

**未覆盖（仅静态确认）**：`snapshot()` 自身两次读之间恰好落进一次外部提交。
`snapshot()` 没有中途插桩点，用计时手段模拟只会得到运气而不是证据；
`CatalogStore.snapshot()` 是 `db.readTransaction` 的一层薄封装，原语层用例覆盖的正是它所依赖的语义。

### 10. 只读不等于"不动磁盘"

`SQLITE_OPEN_READONLY` 保证**不写主数据库文件**，但 SQLite 仍会维护 WAL 模式的
`-wal` / `-shm` 旁件，可能创建或更新它们。上一版注释里"物理上无法写"的说法已删除。
确实需要连旁件都不碰时，必须同时满足「无并发写入」且「WAL 不存在或为空」，
此时可显式使用 `CatalogReader(databaseURL:staticImmutable:)`，
并先用 `SQLiteConnection.isStaticImmutableSafe(databaseURL:)` 检查。**不得对活跃库假装安全。**

不可变打开的三个细节（本轮复核后固定）：

- **WAL 非空由构造函数硬拦。** `SQLiteConnection.Access.staticImmutable` 的构造分支先跑
  `requireNoCommittedWAL`，`-wal` 仍有内容就直接抛错，不依赖调用方记得先检查。
  `isStaticImmutableSafe` 只是给 UI 一个更早、更友好的状态，**它是必要条件不是充分条件**：
  WAL 为空证明不了「没有别的进程正要写」，卷未挂载或扫描器暂停也不是这种保证。
- **打开串必须是百分号编码的 `file:…?immutable=1`。** 只加 `SQLITE_OPEN_URI` 不起作用——
  SQLite 只对以 `file:` 开头的串做 URI 解码，裸路径被当成字面文件名，于是静默退化成
  普通只读打开。不编码时 `#` 起片段、`?` 起查询、字面 `%` 起转义，中文名按 UTF-8 逐字节编码。
  `percentEncodePath` 只保留 RFC 3986 unreserved 集与 `/`，路径分隔符必须保持字面量。
- **归一化 fallback 已删除。** 原先有一个「NFC/NFD 拼写再试一次」的备用 URI 函数，
  其调用点已不存在，函数成为死代码；且它会破坏路径身份——NFD 拼写打不开时改用 NFC 拼写，
  在文件系统上可能命中**另一个**文件。索引路径一律按调用方给出的原样使用。

## 新增公开 API（原接口全部保留）

- **唯一的行为变化**：`CatalogStore.snapshot()` 的三次读现在在同一个只读事务里完成
  （原为三次独立读），返回值与排序语义不变，只是跨代风险被消除。
  其余原接口签名与行为均未变。

- `public struct CatalogReader`：`init(databaseURL:)`（只读）、
  `init(databaseURL:staticImmutable:)`（需先确认无并发写且 WAL 为空）、
  `generation()`、`volumes()`、`entries(volumeID:)`、`entryCount(volumeID:)`、
  `snapshot()`、`snapshotUnordered()`、`entriesUnordered(volumeID:)`、
  `appendEntriesUnordered(volumeID:into:)`、`checkIntegrity(full:)`、`isReadOnly`。
  建议 App 用它做首屏加载与离线校验。
- unordered 变体（**需要 UI 接入才算生效**）：`CatalogStore` 与 `CatalogReader` 都提供
  `entriesUnordered(volumeID:)` / `appendEntriesUnordered(volumeID:into:)` /
  `snapshotUnordered()`。它们只省略 `ORDER BY`，行内容与解码路径完全相同；
  任何只需要喂给 `SearchEngine` 的地方都可以换用（引擎自己会建立全序）。
  `entries(volumeID:)` 的有序契约保持不变。
- `SQLiteConnection.isStaticImmutableSafe(databaseURL:)`（internal，供上层做静态只读前置检查）。

## 未完成 / 仍需后续

1. **真实库改动后数字缺失**。真实索引已被其他进程删除，按边界**不再重建、不再扫描外置盘**。
   后续只能靠合成库给出趋势，真实库基线需主控在合适时机重建索引后重测。
2. **`init` 仍有约 2.4 µs/条目**（合成 20 万条约 705 ms，中文文件名）。剩余大头是字节池追加与
   两次全量排序。延迟构建 `nameOrder`/`pathOrder` 需要把不可变结构换成带同步的惰性存储，
   属于接口层改动，**本轮按指示未做**。
3. **未引入派生持久缓存**：按指示只在首轮实测不足时设计；本轮瓶颈在查询计划与排序数据结构，
   不是缓存缺失，因此没有写任何二进制缓存格式，也没有动旧库 schema。
4. **删除路径的分块删除仍未测**。`deleteSubtrees` 按 150 条分块以避开 SQLite 的
   表达式深度/变量数上限，且带 `ESCAPE` 时 LIKE 前缀优化不生效，仍是带 OR 的全表扫描。
5. **unordered API 尚未接入**：UI 仍在用 `entries(volumeID:)`（129.60 ms）。换到
   `snapshotUnordered()` 可降到 70.12 ms，但需主控决定接入点并重测首屏。
6. **降序决胜契约未动**：降序只反转主键方向，`(volumeID, nodeID)` 决胜恒为升序，有测试固定。
7. **整包 `swift test` 当时被 `Sources/SearchUI/AppUpdateController.swift`（Sparkle 2.5.2 API
   不匹配）与 `Sources/SearchBench/IndexPerfMode.swift`（`writeReport` 缺失）挡住，
   两者都不在本会话所有权内。本会话改动的测试目标本身可编译通过。

## 本轮修掉的项（不再算未完成）

- **`CatalogStore.snapshot()` 的跨代风险**：三次独立读已改为单个 `BEGIN DEFERRED`
  只读事务（锁在 `BEGIN` 之前取，`DEFERRED` 不取写锁），公开有序快照契约、
  签名与返回类型均未变。验证边界见第 9 节；其中「提交恰好落在 snapshot 两次读之间」
  一项在本封装下无法无 sleep 构造，已明确标为仅静态确认，未冒充并发覆盖。

## 复现命令

```bash
# 测试（IndexReview：仅复制 SearchCore/SearchIndex/Tests，绕开被 SearchUI/SearchBench 挡住的整包构建）
cd ~/Library/Caches/MacEverything/IndexReview
rm -rf Sources/SearchCore Sources/SearchIndex Tests/SearchIndexTests
cp -R <repo>/Sources/SearchCore Sources/ && cp -R <repo>/Sources/SearchIndex Sources/
cp -R <repo>/Tests/SearchIndexTests Tests/
rm -f Sources/SearchIndex/Placeholder.swift Tests/SearchIndexTests/Placeholder.swift
DYLD_FRAMEWORK_PATH=/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
DYLD_LIBRARY_PATH=/Library/Developer/CommandLineTools/Library/Developer/usr/lib \
swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks

# 单卷读形状基准
.build/index-perf/sv-bench 200000
```

## 原始测量输出

真实 NTFS 索引，1,026,273 条，热缓存，release 构建，只读连接（改动前代码）：

```
open(read-only)                              0.84 ms
count(*)                                  3455.27 ms  1026273 rows
A 旧解码 + ORDER BY (原实现)               10258.60 ms  1026273 rows
B 旧解码, 无 ORDER BY                         609.82 ms  1026273 rows
C 新流式解码, 无 ORDER BY                      430.69 ms  1026273 rows
D 新流式解码 + 单卷 ORDER BY                   566.97 ms  1026273 rows
snapshot()                                 2717.91 ms
SearchEngine.init                         7510.81 ms
search 窄词 '报告' byName                    133.77 ms    211 hits
search 宽词 'e' byName                      101.49 ms  994171 hits
search 空词 byName (全命中)                   90.47 ms 1026273 hits
search 空词 byPath (全命中)                   93.32 ms 1026273 hits
search 空词 bySize (全命中)                 2768.50 ms 1026273 hits
search 空词 byModified (全命中)             1590.38 ms 1026273 hits
```

同一份 30 万条合成数据，改动前 / 改动后：

```
                                  改动前        改动后
SearchEngine.init              1800.95 ms    775.06 ms   (2.3x)
空词 bySize (全命中)             318.61 ms     39.57 ms   (8.1x)
空词 byModified (全命中)          41.65 ms     34.84 ms
空词 byName (全命中)              26.07 ms     26.13 ms   (走预排序快路径)
空词 byPath (全命中)              25.07 ms     25.62 ms   (走预排序快路径)
旧 folding 名+路径               424.57 ms    389.14 ms   (1.09x)
```

SQLite 查询计划与 CLI 计时（真实库、同一投影，热缓存）：

```
ORDER BY volume_id, relative_path   real 2.24s
无 ORDER BY                          real 1.06s
单卷 + ORDER BY                      real 1.24s
```

单卷读形状（合成 20 万行，release，热缓存，各 3 次取最小）：

```
entries(volumeID:) 有序 [App 现状]     129.60 ms
entriesUnordered(volumeID:)            70.12 ms
entries() 全库无序                      60.16 ms
snapshot()                             60.26 ms
SearchEngine.init                      704.77 ms
search 空词 byName                      16.99 ms
search 空词 bySize                      25.06 ms
search 空词 byModified                  24.30 ms
search 单字 '报'                        18.42 ms
```