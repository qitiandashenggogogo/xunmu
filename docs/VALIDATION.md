# 验收与实测记录

2026-10-09 至 2026-10-10，主控实际执行。交付为本地试用 MVP；两块外置卷已完成只读全盘验收，详见下方记录。实际拔插、跨 Windows 与 Finder/Quick Look 鼠标点击仍未完成。

四个独立 Cindy 会话均为 **Orca Worker**，模型 MiniMax M3.1 Flash Preview：索引与持久化、扫描与卷同步、搜索与导航界面、测试与性能验证。它们交付源码与测试；各会话 shell 被宿主自动审批拒绝/超时，因此下列执行证据均来自主控，未将 worker 自报作为通过依据。

## 构建、窗口与正确性

环境：Apple M4、24 GB 内存、10 逻辑核，macOS 26.6.2 (25G83)，CLT Swift 6.3.3，无完整 Xcode。使用 CLT 提供的 Swift Testing.framework，测试脚本补齐框架与运行库路径；未安装全局依赖。

实际命令：

```sh
MACEVERYTHING_UI_SMOKE=1 MACEVERYTHING_ACCEPTANCE_UI=1 bash Scripts/test.sh
bash Scripts/build-app.sh
dist/速寻.app/Contents/MacOS/MacEverything --smoke --data-dir "$PWD/.build/delivery-smoke"
codesign --verify --strict dist/速寻.app
```

第一阶段测试输出：**253 tests in 19 suites passed after 1.584 seconds**。后续硬件验收增加了直接测试验收工具和卷身份的用例，结果见下方。两个 AppKit 测试开关均开启，并非仅运行纯逻辑测试。应用构建、Info.plist 校验、临时签名、严格签名复验均成功。应用实体位于本机 Library/Caches，dist 为链接，避免 iCloud Documents 重新附加包元数据。

应用实际启动后的自动检索：63 个索引条目、查询「报告」命中 20 条、查询与选区恢复 true，窗口 960 × 628。应用自身的完整框架位图已检查，见 [界面截图](app-preview-2026-10-12.png)。这证明原生窗口与程序驱动流程，不等于桌面真实点击或 Quick Look 内容已验证。

| 行为 | 证据与结果 |
|---|---|
| 单/双汉字、任意位置子串、多词/排除、名称/路径、大小/日期/扩展名 | 引擎与独立验收用例通过；Unicode 原始名往返、NFC 检索、区分大小写覆盖 |
| 全部命中、稳定全序、取消 | 大结果集不截断；升降序与稳定 ID 决胜；扫描/排序取消返回空结果，旧代际 UI 不渲染 |
| SQLite 持久化 | 重开读回、幂等重放、代际、checkpoint 与补扫责任、ID 不复用通过 |
| 删除安全 | 权限不足的真实临时目录、部分扫描、离线保留、子树边界、大小写、通配字符、2000 条删除通过 |
| Darwin 扫描 | 真实文件/目录/链接、bulk 与 fallback 一致、bulk 实际使用、inode/大小、不跟随链接、非法根与路径逃逸检查通过 |
| 真实 FSEvents | 临时 APFS 目录实际创建、改名；停监控期间写入，再以同日志 UUID/断点启动，离线变化回放通过 |
| 导航与界面 | 缓存帧即时后退、选区/滚动锚、首次结果恢复、同代换结果、懒构建、超过映射阈值的线性查找通过 |
| 打开门禁 | 卷 UUID、挂载存在、目标 inode/替换、离线拒绝、离线路径复制用例通过；真实打开/Reveal/Quick Look 仍待点击验收 |

## 可复现性能

使用 release 引擎；合成数据固定 seed=1592614637。10 万条重复 7 次、预热 2 次；百万条重复 5 次、预热 1 次。p95 仅描述这些有限采样，不是任何硬件下的承诺。完整 JSON 保存于 [10 万条](benchmarks/2026-10-09-100k.json)、[百万条](benchmarks/2026-10-09-1m.json)。

```sh
swift build -c release --product SearchBench --scratch-path .build/package
.build/package/arm64-apple-macosx/release/SearchBench --count 100000 --repeats 7 --warmup 2 --persist --scan-files 2000 --output .build/bench-100k.json
.build/package/arm64-apple-macosx/release/SearchBench --count 1000000 --repeats 5 --warmup 1 --output .build/bench-1m.json
```

按平台改用 `swift build -c release --show-bin-path --scratch-path .build/package` 返回的二进制目录，不固定 ARM 路径。

名称升序的完整结果查询（匹配 + 排序/有序过滤 + 返回全部键），单位毫秒：

| 查询 | 10 万条首查 / p50 / p95 | 百万条首查 / p50 / p95 | 百万条命中 |
|---|---|---|---|
| 文 | 11.608 / 7.402 / 7.894 | 124.322 / 79.295 / 80.734 | 31,078 |
| 报告 | 11.191 / 7.317 / 7.637 | 114.073 / 80.881 / 81.568 | 31,331 |
| a | 10.823 / 6.959 / 6.980 | 107.812 / 74.022 / 78.481 | 222,511 |
| presentation | 11.013 / 7.486 / 7.587 | 117.221 / 81.167 / 81.365 | 28,033 |

### 2026-10-12 百万条重测（只读库优化后）

主控在只读加载路径优化后重跑了 release `SearchBench` 百万条合成基准，
**exit 0、`selfCheckFailures` 为空**。原始报告：
[2026-10-12-1m.json](benchmarks/2026-10-12-1m.json)（入库前已逐字段核查，无私有路径与标识，数值未做任何修改）。

| 查询 | 首查 | p50 | p95 | 命中 |
|---|---:|---:|---:|---:|
| 文 | 59.345 ms | 15.894625 ms | 17.648125 ms | 31,078 |
| 报告 | 53.925 ms | 16.24825 ms | 16.36375 ms | 31,331 |
| a | 52.428 ms | 15.124041 ms | 15.285417 ms | 222,511 |
| presentation | 54.552 ms | 18.181959 ms | 18.354625 ms | 28,033 |

- 匹配/排序缓存构建（engineInit）：百万条 **3239.345 ms**，对比上一轮 8.47 s。
- 基准进程峰值 RSS：**1175.734 MiB**，对比上一轮 1102.7 MiB。**内存没有下降，反而略升**；
  加速主要来自加载路径，不能表述为“整体更快且更省”。
- 名称升/降序 15.267 / 126.688 ms，路径升/降序 15.965 / 150.506 ms，大小 42.864 / 43.718 ms，
  日期 33.109 / 33.245 ms。降序仍明显慢于升序。
- 仍是 **first-observed**，且仍是**内存合成**数据，不含磁盘 IO，不能外推到机械盘或外置盘。

> ⚠️ **真实盘数字本轮未重测。** 只读库优化后**没有**在 8TB NTFS 或 1TB exFAT 上重跑，
> 因此上方“8TB NTFS 续验”那一节里的 p50 89–128 ms、索引重开读取 17.505 s、峰值 RSS 1674.406 MiB
> **全部是优化前的旧数字**，本轮**不宣称**其中任何一项已经在真实盘上达到了新水平。
> 要给出真实盘的优化后数字，必须在真盘上重新跑一遍。

- 匹配/排序缓存构建：10 万条 **604 ms**，百万条 **8.47 s**。这是从内存条目构建缓存，不是应用冷启动总耗时。
- 基准进程峰值 RSS：10 万条 **154.6 MiB**，百万条 **1102.7 MiB**。包括合成数据、引擎与临时结构；不是 GUI 常驻值，GUI 百万行查表额外成本尚未实测。
- 对命中最多的 a 查询测四列升降序：百万条名称升序 **74.3 ms**、路径升序 **73.5 ms**；名称/路径降序 **347.8/367.9 ms**，大小约 **313–319 ms**，日期约 **208–214 ms**。不能用最快升序值代表所有排序。
- 10 万条 SQLite：4000 个目录事务写入 **2.87 s**，重开并读回 **56.2 ms**，读回数量一致。未测试百万条 SQLite 恢复总耗时。
- 取消探针在不同检查次数触发；所有已触发取消均返回空键。百万条第 1000 次检查触发时总查询耗时 **70.8 ms**；这不是「外部取消请求到响应」延迟，不可据此承诺取消响应指标。
- 真实扫描夹具：2000 个文件、200 个目录与符号链接，共 2201 条；首遍 **5.9 ms**，第二遍 **4.7 ms**，完整且未跟随链接。创建夹具会预热缓存，这些数字只说明本机缓存中的小目录遍历，**完全不能代表机械盘首扫**。

匹配以连续 UTF-8 缓冲避免每条 Foundation 子串开销；广泛命中的名称/路径升序过滤快照预排序序列，全部命中仍可访问。SQLite 缺失目录查询移除无用排序，避免错误索引计划反复扫整卷。两项修改均重跑正确性与性能验证。

## 外置盘只读实测（2026-10-09）

实际命令使用 release SearchBench 的 `--real-root PATH --report-dir LOCAL_PATH --verify-pass`。索引仅写本机 `.build/hardware/`；扫描盘下不创建文件、不改名、不删除，不读内容。两块盘依次扫描。USB 桥未暴露可靠旋转介质标记，因此按保守单扫描任务运行，不用文件系统格式猜介质。

- **1TB USB / exFAT：通过本轮只读验收。** 134,885 条、12,850 个完整目录批次、0 个失败批次；首遍扫描及 SQLite 写入 **36.159 s**，第二遍元数据校验 **5.835 s**，新增/消失/变化均 0。引擎构建约 1.15 s，重开读回约 166 ms；重开前后五组查询键序列完全一致且无重复。SQLite integrity_check=ok，Python 从原始名称/路径独立计算的五组命中数与引擎一致。[脱敏统计报告](benchmarks/2026-10-09-real-exfat.json)。
- 五次稳态采样，完整名称升序查询 p50/p95：文 **19.489/20.996 ms**（20,261 条），报告 **19.270/20.415 ms**（15 条），a **22.989/29.440 ms**（131,890 条），jpg 子串 **20.582/21.130 ms**（2,854 条），空查询 **17.600/19.798 ms**（134,885 条）。峰值 RSS **353.797 MiB**，包含元数据指纹与重开验证缓存，不等于 GUI 常驻内存。
- **8TB USB / Tuxera NTFS：未通过全盘验收，空间受阻。** 约 671.2 s 时已报告 1,019,100 条、12,456 个完整批次；扫描提前结束时本机可用空间约 117 MiB。旧探针未保留具体错误码，不能将某个 SQLite 错误写成已证实原因。查询、重开与第二遍校验未完成，以上计数是部分扫描进度，不代表盘上总条目数或完整覆盖。主控停止进程，删除本次生成的失败临时库；未清理用户文档或外置盘。后续需先补足本机空间再从头验收。
- 实际 exFAT/NTFS 根目录元数据与打开前门禁、子目录身份一致性、FSEvents 流创建/启动/停止测试通过；未产生测试文件或模拟外置盘变更，不等于真实拔插/实时变更回放已通过。
- 第三方 NTFS 实际没有 Foundation 卷 UUID：已复现并修复。优先原生卷 UUID，缺失时使用 DiskArbitration 的真实 GPT 分区 UUID；扫描、挂载恢复和打开门禁统一使用同一规则。仅 APFS/HFS 信任日志续播；第三方和未知驱动保守要求全树校验。
- 新进程加载 exFAT 索引副本并模拟离线：134,885 条真实索引加 63 条演示记录共 **134,948 条**，报告搜索 **35 条**，查询/选区恢复均 true。模拟根不可用，未实际推出盘；临时副本验收后已移除。
- 桌面辅助功能实际输入报告后显示 20 条演示结果，高级筛选输入 100mb 并应用后状态落盘、清除和文件夹筛选均可用。鼠标、Finder、Quick Look 尚无可靠成功证据，演示窗口处于台前调度缩略图；不把辅助功能动作当作鼠标验收。已为大小上下限添加不同的辅助功能标签。

本轮主控最终回归：**285 tests in 26 suites passed after 2.275 seconds**，两个 UI 开关和实际外置卷身份开关均开启。真实模式的安全闸、差异、统计直接测试 SearchBench 生产函数，不再测试复制实现。已补空间保护：大规模真实模式启动要求至少 2 GiB，应用/扫描写库期间保留 512 MiB；空间不足暂停并保留旧索引，部分扫描不继续查询验收、不标为通过。错误输出保留类型/错误码，避免打印用户文件路径。

这次是 first-observed（首次观察），目录可能已被访问；不是冷缓存 HDD 保证。检索统计为引擎全结果耗时，不是键盘到 UI 首屏的端到端延迟。

## 8TB NTFS 续验与界面修复（2026-10-10）

用户腾出本机空间后，以同一 release SearchBench 重新只读扫描 8TB USB / Tuxera NTFS。命令仍为 `--real-root PATH --report-dir LOCAL_PATH --verify-pass`，不读取文件内容、不写外置卷、不改变系统权限。全盘 **1,026,273 条、13,416 个完整目录批次、零失败**；首遍扫描及 SQLite 入库 **466.027 s**，第二遍纯元数据校验 **248.605 s**，新增/消失/变化均零。退出码 0，自检通过。[脱敏统计报告](benchmarks/2026-10-10-real-ntfs.json)。

| 完整名称升序查询 | 命中数 | p50 / p95（ms，5 次采样） |
|---|---:|---:|
| 文 | 969,414 | 110.602 / 121.050 |
| 报告 | 211 | 128.128 / 134.622 |
| a | 975,807 | 95.623 / 103.247 |
| jpg 子串 | 78,874 | 89.228 / 89.732 |
| 空查询 | 1,026,273 | 109.266 / 169.946 |

裸词同时匹配名称和相对路径，表内 `jpg` 是子串查询，不能理解为只统计 jpg 扩展名。主控用 Python 从 SQLite 原始名称/路径独立执行 NFC + Unicode casefold 子串计算，五组计数完全一致；`PRAGMA integrity_check` 返回 `ok`。

首次构建查询缓存 **7.077 s**；重开 SQLite 读取 **17.505 s**、重新构建缓存 **6.741 s**，条目数与五组有序键序列完全一致，没有重复键。这里是同进程新数据库连接的重开检查，不是整个应用新进程的启动计时。基准进程峰值 RSS **1674.406 MiB**，包含百万条指纹、重开和全量结果缓存，不代表 GUI 常驻内存。准备时间及内存仍需优化。此前中断的扫描保留为历史失败记录，不用本次成功覆盖它；本次依然是 first-observed，不能声称冷缓存机械盘速度。

界面实测：本机演示窗口通过真实鼠标与前台键盘输入完成「报告」20 条搜索、名称列顺序切换和结果选择。正常退出时选中节点落盘，新进程恢复查询。右键实测没有菜单，源码确认将右键处理放在了不存在的 NSTableViewDelegate 回调中；改为 ResultsTableView 实际 `rightMouseDown(with:)` 转交控制器，增加真实 NSEvent 分发回归。修复后 **286 tests in 26 suites passed after 2.337 seconds**，两个 UI 开关和实际外置卷身份开关均开启；重新打包与严格签名复验通过。Finder/Quick Look 的真实菜单操作仍待展开的前台窗口验证，不以回归测试替代。

本轮还复现了 iCloud 编译环境故障：编译模块缓存带 `dataless` 标志，恢复源码触发 `input file ... was modified during the build`。构建/测试脚本现在先读取本项目输入、将编译缓存默认放到 Library/Caches；完整构建及回归已证明恢复有效。可分别用 `MACEVERYTHING_SCRATCH_DIR`、`MACEVERYTHING_TEST_SCRATCH_DIR` 覆盖缓存位置。

## 尚未完成的硬件和交互验收

- 外置机械盘的冷缓存首扫、低优先级扫描对其他应用读盘的影响、USB 桥和共盘分区、APFS/HFS+/exFAT 实际推出/拔插。
- exFAT 经 Windows 深层增删改后插回。实现挂载后全树元数据校验，不能用根 mtime/采样证明没有变化；尚未在对应盘验证。
- 全盘 FDA/TCC 权限提示与撤销、其他 macOS 版本、Intel 机器、真实跨挂载点。
- Finder 打开与 Reveal、Quick Look 实际内容、像素级滚动恢复的真实鼠标操作。2026-10-10 已确认真实鼠标的表头排序/选区与前台键盘搜索，右键事件接入已修复；其余仍需展开的前台窗口验证。未改动系统权限/台前调度设置。
- 跨目录移动/硬链接歧义/exFAT 不可靠 inode 不能保证 ID 跨改名稳定；同父目录 APFS/HFS+ 可证明的唯一 inode 改名保留 ID。打开前仍核对卷及文件身份。
- 第三方 NTFS 驱动不提供文件系统 UUID 时，使用 DiskArbitration 返回的 GPT 分区 UUID（`partition:<UUID>`）；真实硬盘及子目录身份和打开前门禁已验证。两种 UUID 都拿不到时仍拒绝打开；不会用卷名、容量或主机 UUID 合并硬盘。
- 非 UTF-8 文件名当前不纳入索引：两种枚举路径均严格检查字节，遇到无效名称将目录标为不完整并保留旧记录，避免替换字符造成错误路径或误删。原始字节路径支持尚未实现。
- 百万条内存与构建时间仍偏高；降序与数字列大量命中排序可继续优化。尚无拼音、正文、网络盘、独立守护进程、保存搜索集合或正式签名公证版本；已有最近查询/选区恢复。
- **自动更新仍未接通、也未验证**：Sparkle 2 已接入界面与后台检查，但缺更新源地址、缺 Ed25519 密钥对、
  缺公开仓库与 Releases，从未跑过一次真实的旧版→新版升级。缺配置时“检查更新…”是禁用状态并说明原因，
  不会静默失败。本轮测试**没有**覆盖这一条（需要真实发布包与网络环境）。
- **远程崩溃/诊断上报未接通、也未验证**：`SearchDiagnostics` 是**本地零依赖**模块，不联网、不上传。
  本轮通过的 `本地诊断接线` 套件只验证本地接线与导出顺序，**不等于**存在任何远程上报能力。
  将来若新增外发上报，必须先取得用户明确同意，且默认不含文件名、路径、搜索词与文件内容。

## 基准安全边界

百万条只在内存合成，没有创建百万个真实文件。`--scan-files` 上限 20000，仅在临时夹具写入并清理。`--database` 指定目标或 SQLite 旁件已存在时拒绝执行，测完仅删除本次创建的库；`--output` 可覆盖报告，不删除目录。夹具只在本机临时目录写入；真实外置盘验收仅枚举名称与元数据，不读内容、不写盘、不改权限、不推出硬盘。原始路径索引和 GUI 私有截图留在被 Git 忽略的 `.build/hardware/`，不提交用户文件名明细。

## 索引只读分阶段测量（2026-10-10 新增）

`SearchBench --index-db PATH [--require-checkpointed-wal]` 对**已存在的本机索引**做分阶段只读测量，
与合成基准、真实盘扫描互斥：

| 阶段 | 含义 |
| --- | --- |
| 打开 | 以 `SQLITE_OPEN_READONLY` 打开（`SearchIndex.CatalogReader`），不建表、不写主库文件 |
| 计数 | `COUNT(*)`，利用覆盖索引 |
| 读取解码 | 读出行并解码成 `IndexedEntry`（启动准备时间的主要来源） |
| 引擎构建 | 构建归一化匹配键缓存 |

随后对固定查询集（文 / 报告 / a / jpg / 空查询）各跑至少 5 次，记录首观测耗时与 p50/p95、
命中数与**逐次稳定性**；再做四种排序键 × 升降序的两次运行序列一致性比对，以及多点取消探测。

安全边界：

- **不用 `CatalogStore` 打开原库**。`CatalogStore.init` 是读写连接、会跑 schema 初始化并可能写 meta；
  只读测量一律走 `CatalogReader`。
- **不复制**数据库文件。**禁止复制 GB 级真实索引**（本项目已授权的边界）：
  避免额外占用一份同体积的空间，也避免产生第二份副本。要看数据库请直接读原件。
- **不写主库文件**：不建表、不写 meta、不 checkpoint、不 vacuum、不改 journal 模式。
  这**不等于**「物理上不具备写入能力」——WAL 库的 `-wal` / `-shm` 旁件仍会被 SQLite 维护，
  只读连接可能创建或更新它们。只读保证的是「主库文件零写入」。
- **immutable 打开本模式不用**：它确实完全不碰旁件，但要求调用方**静态**保证没有并发写入者
  （暂停扫描器不算，那只降低概率；真正的保证应来自持有写入方也遵守的排他锁）。本测量只做瞬时观测，
  不具备该前提，因此走普通只读打开。
- **WAL 闸**：`--require-checkpointed-wal` 在存在未 checkpoint 的 WAL 时拒绕执行（退出码 2）。
  带 WAL 的库只读打开时会一并读入这些帧，读到的状态与已 checkpoint 的库不同，跨次对比不可靠。
  反向也要说清：**WAL 为 0 只能证明「本次测量前没看到未合并的 WAL」，
  不能证明「当时没有别的进程在写」**，报告里的 `checkpointedBeforeRun` 只是一种观察，不是并发安全证明。

验收命令（由主控实跑并回填数字）：

```sh
swift build -c release --product SearchBench --scratch-path .build/package
.build/package/arm64-apple-macosx/release/SearchBench \
  --index-db "$HOME/Library/Application Support/MacEverything/catalog.sqlite" \
  --require-checkpointed-wal --output .build/index-perf.json
```

**实测结果：本轮尚未运行（主控尚未实跑该命令），下表留空待回填。**

| 阶段 / 指标 | 数值 |
| --- | --- |
| 打开 / 计数 / 读取解码 / 引擎构建（ms） | 待实测 |
| 文 / 报告 / a / jpg / 空查询 的 p50 / p95（ms） | 待实测 |
| 命中数逐次稳定性、四排序键序列稳定性 | 待实测 |
| 取消探测（全部真取消均返回空） | 待实测 |
| 峰值 RSS | 待实测 |

作为参照：真实 8TB NTFS 轮次里同口径的数字为引擎构建 7.077 s、重开读取 17.505 s、
重建缓存 6.741 s、峰值 RSS 1674.406 MiB（见上方“8TB NTFS 续验”）。两者不是同一次运行，不可混用。

## 独立验收矩阵（2026-10-10 新增）

`Tests/AcceptanceTests/ReleaseCapabilityAcceptanceTests.swift` 与
`IndexReadOnlyModeTests.swift` 新增黑盒用例，不复刻实现里的单元测试。

### 命名纠正（重要）

早期版本把下面两项写成「两版升级」和「坏包」，**这两个名字当时超出了实际做到的事**，现按真实范围改名，
断言本身一条未放宽：

| 早期叫法 | 现用准确名称 | 实际覆盖的事 | 实际**没有**覆盖的事 |
| --- | --- | --- | --- |
| 两版升级 | **同一份代码重开索引的等价性**（reopen equivalence） | 同一个 `.app` 代码、同一个索引文件，在**新进程/新连接**下重开后条目、代际、查询键序列一致；只读重开不写主库；重开后写入侧仍可用 | 真正的**跨版本**升级（旧版本写的库由新版本代码打开）。仓库里没有「旧版本」这份二进制，用例里的“旧索引”是当前代码写的夹具 |
| 坏包 | **损坏索引库被拒绝**（corrupt-index rejection） | 把索引文件尾部改坏后，要么打开失败，要么 `integrity_check` 明确不返回 `ok`；绝不静默当成「0 条记录」的空库 | 安装包层面的**坏包**：ZIP 篡改、签名被破坏、App 签名不符、Sparkle 校验失败。这些需要真实发布包与网络环境，代码里测不了 |

同理，「升级」在别处出现时，如果指的是当前代码重开数据库，一律按上表的真实范围理解。
**Sparkle 网络升级与安装包防篡改在本轮仍未验收**，见下方「矩阵不覆盖」小节。

### 矩阵

最后两列是**实际跑出来的状态**，不是占位符。“已跑通”表示已在 2026-10-12 主控的整包基线中
实际执行并通过（日志 `~/Library/Caches/MacEverything/lead-final-tests-20261012.log`，
对应套件：`发布能力 · 索引升级与保留`、`发布能力 · 隐私边界`、`发布能力 · 视图状态保留`、`索引只读性能模式`）。
这**只说明在临时夹具里能真跑**，不改变上文“命名纠正”一节的范围限制。

| 矩阵项 | 覆盖用例 | 状态 |
| --- | --- | --- |
| 重开等价：索引被重新只读打开，条目/代际/键序列不变 | `reopenPreservesIndexAndResults` | **已跑通** |
| 重开不写主库（文件与旁件字节数、修改时间不变） | `reopenIsReadOnly`、`readOnlyOpenDoesNotMutateTheDatabase` | **已跑通** |
| 损坏库不得被当作健康索引 | `corruptedIndexIsRejected` | **已跑通** |
| 缺失索引不得被静默新建为空库 | `missingFileIsRejectedNotCreated` | **已跑通** |
| 原库保留且可继续增量更新 | `indexRemainsWritableAfterReopen` | **已跑通** |
| 视图状态保留：查询/范围/选区/锚点/滚动可捕获、可 Codable 往返 | `capturedStateCarriesEverything`、`stateSurvivesCodableRoundTrip` | **已跑通** |
| 导航前进后退保留完整状态 | `navigationRoundTripKeepsState` | **已跑通** |
| 索引换代后旧视图状态仍可恢复 | `stateFromOlderGenerationStillRestores` | **已跑通** |
| 无文件信息外泄：公开报告不含用户名/外置盘名/凭据/会话标识/绝对路径 | `publishedReportsCarryNoUserOrVolumeNames` 等 4 条 | **已跑通** |
| 对外事实只到卷级，不下沉到文件级 | `externalFactsStopAtVolumeLevel` | **已跑通** |
| 离线复制路径是本地操作，不带内容、不可打开 | `copyPathIsLocalOnly` | **已跑通** |
| 索引只读：打开/计数/读取解码/引擎构建四阶段耗时可用 | `stageTimingsAreFinite` | **已跑通** |
| 索引只读：查询命中数与键序列逐次恒定 | `repeatedQueriesAreStable` | **已跑通** |
| 索引只读：四排序键 × 升降序两次运行序列一致 | `sortOrderingIsRepeatable` | **已跑通** |
| 索引只读：取消不返回半截结果 | `cancellationNeverReturnsPartialResults` | **已跑通** |

**矩阵中不覆盖、代码里也测不了的部分**（需真实环境实测，不得标为通过）：

- **真实跨版本升级**（旧版本写出的索引被新版本代码打开）：仓库内没有旧版本二进制，矩阵里只有「同一份代码重开」
- **安装包层面的坏包**：ZIP 篡改、签名破坏、签名与更新源不符
- 真实签名包在同事 Mac 上的首次安装（Gatekeeper 放行）与跨版本升级
- **Sparkle 真实网络升级**：缺更新源地址、缺 Ed25519 密钥对、从未跑过一次旧版→新版
- 公证与 Developer ID 信任（无付费开发者账号）
- 升级过程中断电/崩溃后的索引一致性

## 本轮 worker 交付说明

- 2026-10-10 早先执行通道失效，上一轮派发均 `AGENT_NOT_READY`，**未执行任何改动**。
- 现已恢复受管执行通道（执行方为 MiniMax M3.1 Flash Preview）。
  （本文不记录内部 provider / session / worker 标识：它们是调度内部信息，不属于公开文档，
  也不应进入公开仓库。）
- 本轮新增用例与 `--index-db` 模式**已于 2026-10-12 实际编译并运行**，矩阵状态见上表，
  整包结果见下方“整包基线回归”。
- 泄露审计与待处理问题见 [OPEN-SOURCE.md](OPEN-SOURCE.md)。

## 整包基线回归（2026-10-12）

### 主控最终证据（以此为准）

```sh
MACEVERYTHING_TEST_SCRATCH_DIR="$PWD/.build/main" \
MACEVERYTHING_UI_SMOKE=1 MACEVERYTHING_ACCEPTANCE_UI=1 \
bash Scripts/test.sh --build-system native --skip-update
# 日志：~/Library/Caches/MacEverything/lead-delivery-tests-20261012.log
```

**结果：exit 0，422 tests / 48 suites 全部通过，14.900 s；2 项跳过。**

- 跳过的 2 项仍是**真实外置盘身份**用例（`实际外置盘的枚举身份能通过打开前门禁，子目录身份一致`、
  `实际第三方 NTFS 的分区 UUID 可跨扫描和打开校验使用`），需真实盘在线，**不是代码失败**。
- 本次运行的是**最新完整源码**，包含共享隐私检测改造与结果表布局修复。对应套件全部通过：
  `结果表布局`（7 项）、`发布调度`（10 项）、`发布能力 · 隐私边界`、`搜索窗口冒烟`（原生窗口）、
  `界面验收`、`本地诊断接线`、`排序决胜：相同键必须回落到 EntryKey`、
  `排序全序、去重与查询不变量`、`索引只读性能模式`、`发布能力 · 索引升级与保留`、
  `发布能力 · 视图状态保留`。
- 共享隐私检测运行**在本机注入了私有标识**，用于验证「真实值也能被检出」；
  **这些值不写入仓库**，仓库内也没有任何真实标识常量。

### 打包、签名与启动（主控实际执行）

- 构建产物：`~/Library/Caches/MacEverything/FinalBuild-20261012/速寻.app`。
  主控逐个执行 `codesign --verify --deep --strict`，app、`Sparkle.framework`、`Updater.app`、
  `Downloader.xpc`、`Installer.xpc` **全部返回 0**。日志：
  `~/Library/Caches/MacEverything/lead-delivery-package-20261012.log`
- 包内已带 Sparkle 的 MIT 许可声明；**无更新源时“检查更新…”保持禁用**，不会静默失败。
- 整包 `--smoke`：**exit 0**，`indexed=63`、`reportMatches=20`、`queryRestored=true`、
  `selectionRestored=true`。日志：
  `~/Library/Caches/MacEverything/lead-delivery-smoke-20261012.log`
- 界面：新增 [app-preview-2026-10-12.png](app-preview-2026-10-12.png)，已查看确认
  **表头与首行不再重叠**；原图 `app-preview.png` 保留作过程记录。
- 本地 zip：`~/Library/Caches/MacEverything/FinalBuild-20261012/速寻-0.1.0-1-arm64.zip`
  （1,554,819 bytes）。**仅在本地准备，未发布、未推送、未创建任何仓库或服务。**
- 仍为自签名，**无 Developer ID、无公证**；同事 Mac 首次安装与真实跨版本升级**未验证**。

### 历史：两轮更早的记录（保留，不涂改）

**413 tests / 47 suites（视觉修复前）**：exit 0，但表头与首行重叠的截图问题尚未修复，
故只能算视觉修复前的验收。日志：`~/Library/Caches/MacEverything/lead-reviewed-tests-20261012.log`。

**408 tests / 46 suites（有排序 bug）**：1 个 suite 失败（4 个 issue），全部落在
`SearchEngineAcceptanceTests.swift:267` 的「全序决胜为 (volumeID, nodeID) 升序」。
主控当时定位为引擎名称/路径**等长**分支的真实 bug，已修复并补上专门的排序回归套件。
日志：`~/Library/Caches/MacEverything/lead-final-tests-20261012.log`。
保留这段失败记录，是为了说明这个 bug 真实存在过，也说明断言当时没有被放宽去凑绿。

### 工作会话的前序证据（更早，仅作过程记录）

工作会话是本轮唯一可构建/测试的执行会话。首次构建先报
`input file '…/PublishSchedulerTests.swift' was modified during the build`（另一会话正在编辑该文件），
重跑后暴露出下面两个真实编译错误（均在 Tests/AcceptanceTests 所有权内）。

环境：macOS 26.6.2 (25G83)，Xcode.app 位于 `/Applications/Xcode.app`，
`--build-system native`（SwiftPM 会警告 deprecated，但本环境仍可用）。
复用现有 `.build/main`（含 Sparkle 2.10.0 checkout），**没有拉依赖、没有清签名缓存、没有删任何缓存或数据库**。

工作会话运行：**408 tests / 46 suites，3 失败（6 个 issue），2 跳过，exit 1。**
日志：`~/Library/Caches/MacEverything/validate-baseline-2026-10-12-run5.log` 与 `-final.log`。

### 本会话修掉的 6 个真实问题（均在 Tests/AcceptanceTests 与 Sources/SearchBench 所有权内）

| 位置 | 问题 | 处理 |
| --- | --- | --- |
| `RealScanProbeLogicTests.swift` 编译错误 | `temporary.path` 解析到 `AcceptanceTempDirectory.path(_:isDirectory:)` 方法而非 `url.path`，3 处类型不匹配 | 改为 `temporary.url.path` |
| `ReleaseCapabilityAcceptanceTests.swift` 编译错误 | 嵌套函数 `walk(_:path:)` 的两处递归调用漏了 `path:` 标签 | 补上标签 |
| `RealScanProbeLogicTests.swift` 拒绝文案断言 | 断言 `message.contains("同一设备")`，实际生产文案是“同一个设备”——绑死了措辞 | 改为断言真正要验的东西：`拒绝执行` + 点名 `--report-dir` / `--real-root` |
| `RealScanProbeLogicTests.swift` 措辞断言 | 断言“不含 `零硬盘读`”，但生产文案写的是**否定引述** `不声称“零硬盘读”`——生产文案是对的，断言被引号绕过 | 先剔除引号与否定引述再查，并补一条正向断言（必须说明目录遍历就是真实磁盘读）。断言变严，不是变松 |
| `ReleaseCapabilityAcceptanceTests.swift` 报告字段名断言 | `queryText` 被列进禁止键名，但它是基准内部的**固定合成查询集**字段 | 改为**值级白名单**：键名仍受限，且值必须是那几条固定字面量。将来真写进用户搜索词会直接变红 |
| `ReleaseCapabilityAcceptanceTests.swift` 复制路径断言 | 断言 `displayPath == "文档/报告.pdf"`（相对路径），但 `ResultRows.swift` 的文档化契约是 `displayPath = 卷根 + 相对路径`（纯字符串拼接，离线也能给） | 按已文档化的真实契约重写断言，并**新增**一条：无卷根时退化为相对路径。离线不可打开的两条安全断言原样保留 |

**没有任何一条 Acceptance 断言是为了“凑绿”而放宽的**：三处改动都是把绑死措辞的断言换成真契约，
或把被绕过的检查写得更严。

### 工作会话当时遗留的 2 个失败：均已解决

| 位置 | 现象 | 终态 |
| --- | --- | --- |
| `SearchEngineAcceptanceTests.swift:267`（4 issue） | 全序决胜断言不符，降序实测 `["vol-internal#7","vol-external#3","vol-internal#5","vol-external#9"]`。`Sources/SearchIndex/SearchEngine.swift` 写明“最终决胜键恒为升序、不随方向反转” | **已修复**（引擎等长 `memcmp` 分支）并补了排序回归套件；断言从未被放宽 |
| `PublishSchedulerTests.swift:261,279`（2 issue） | `持续 pending trigger 被有界延后`：`probe.calls` 与预期不符。当时 `PublishScheduler.swift` 仍在被另一会话编辑 | 随代码推进通过，`发布调度` 套件现为绿 |


## 寻目品牌与文案版验收（2026-10-12）

执行渠道：图标和界面实现由 Orca Worker（Opus 5.5）完成，名称、文案提案及致谢整理由 Orca Worker（Gemini 3.8 Flash）完成；主控独立审查并实际构建、测试和验签。

主控启用两个真实 AppKit 开关，复用 `.build/main` 运行：

```sh
MACEVERYTHING_TEST_SCRATCH_DIR="$PWD/.build/main" MACEVERYTHING_UI_SMOKE=1 MACEVERYTHING_ACCEPTANCE_UI=1 bash Scripts/test.sh --build-system native --skip-update
```

品牌、文案、错误详情及工具栏宽度修复后的完整测试：**429 tests / 49 suites 通过，exit 0**。
2 项真实外置盘身份用例跳过，未新增真实外盘验收。日志：`~/Library/Caches/MacEverything/lead-xunmu-publish-tests-20261012.log`。

签名构建与实际启动：

- 展示名及窗口标题为「寻目」，可执行文件仍是 `MacEverything`，Bundle ID 与数据目录保持兼容。
- A 图标已入包，`CFBundleIconFile=AppIcon`，包内资源与已选定图标逐字节相同。
- app、Sparkle.framework、Updater.app、Downloader.xpc、Installer.xpc 与 Autoupdate 独立严格验签返回 0；Sparkle 完整许可文件（含 External Licenses）已随包保留。
- `--smoke` exit 0：63 条记录，报告查询 20 条；查询、选区恢复均 true。AppKit 自动验证后，未接通的报告菜单仍禁用，缺更新配置时检查更新菜单仍禁用。
- 新截图 [寻目品牌界面](app-preview-xunmu-2026-10-12.png) 已查看：首行与表头不重叠，「只看文件夹」完整显示。截图为隔离演示夹具，不含用户文件。
- 错误详情原文保留、正常状态清除旧详情、重复点击只开一个 sheet、原文不进入诊断导出均有实际通过的用例。

本轮没有公证、同事 Mac 首次安装、真实两版本网络升级或远程崩溃上传验收；这些仍未接通或未验证。性能数字仍采用前述合成与历史真实盘记录，不把文案改版当作性能重测。
