# 公共接口（主控维护）

Sources/SearchCore/Models.swift 是模型契约。索引目录 rootPath 是用户选定的扫描根（可以是整卷或目录），relativePath 相对该根；id 是本地注册的索引范围稳定 UUID，不与卷名/挂载点混用。volumeUUID 优先保存底层文件系统 UUID；第三方驱动未提供时保存 `partition:<GPT 分区 UUID>`（DiskArbitration），不采用卷名/容量等弱指纹；重挂载使用卷 UUID 与原选定根在卷内的相对位置解析。没有可靠卷 UUID 时保留离线范围，不能凭卷名自动合并。

## SearchIndex

公开 `public actor CatalogStore`：

- `init(databaseURL: URL) throws`
- `registerVolume(_ volume: VolumeRecord) throws`
- `volumes() throws -> [VolumeRecord]`
- `entries(volumeID: String? = nil) throws -> [IndexedEntry]`
- `apply(_ batch: DirectoryBatch) throws -> UInt64`：完整批只表示该目录的直属子项已完整枚举；删缺失直属子项时应删其子树。不完整批不得删除。节点显式 ID 不复用，原始路径保留，父目录不能用字符串前缀误匹配。每次变动递增持久代际。
- `checkpoint(volumeID: String) throws -> SyncCheckpoint?`
- `commitCheckpoint(_ checkpoint: SyncCheckpoint, pendingPaths: [String]) throws`：checkpoint 与补扫责任原子提交。
- `pendingPaths(volumeID: String) throws -> [String]`
- `setPendingPaths(volumeID: String, paths: [String]) throws`
- `generation() throws -> UInt64`
- `snapshot() throws -> CatalogSnapshot`、`entryCount(volumeID: String? = nil)`、`clearPendingPaths(volumeID:paths:)`、`bumpGeneration()`；公开 `CatalogError`。

`entriesUnordered(volumeID:)`、`appendEntriesUnordered(volumeID:into:)` 与 `snapshotUnordered()` 是省略数据库排序的读取入口，仅用于交给会自行建立全序的搜索引擎；既有 `entries(volumeID:)` 的有序语义保留。`snapshot()` 和 `snapshotUnordered()` 在一个 `BEGIN DEFERRED` 读事务内取得代际、条目与卷信息。

公开 `CatalogReader` 提供同样的读取、计数与快照入口及 `checkIntegrity(full:)`，默认以 `SQLITE_OPEN_READONLY` 打开既有库，不创建缺失的主库。只读连接不写主库，但可能维护 WAL/SHM 旁件。`init(databaseURL:staticImmutable:)` 的 immutable 模式在构造时拒绝非空 WAL，保留原始路径身份；调用方还必须保证无并发写入者，WAL 为空不能证明这一前提。

`registerVolume` 的在线/离线等元数据真实变化也递增代际；重复注册不递增。APFS/HFS+ 同父目录唯一 inode 可证明的改名保留节点与子树 ID；跨目录移动、硬链接歧义或 exFAT 不可靠身份按新条目处理，旧 ID 不复用。

公开 `public struct SearchEngine: Sendable`：

- `init(snapshot: CatalogSnapshot)`
- `search(_ query: SearchQuery, isCancelled: @Sendable () -> Bool = { false }) -> SearchResult`

查询所有命中，不固定 Top-K 截断。任意位置子串、按空白分开的 AND 词，裸词匹配文件名或相对路径，`name:词` 仅文件名；支持 `-词`、`-name:词`、`-path:词` 排除与 `path:词`、`ext:pdf`、`size:>10mb`、`date:2026-01-01..2026-12-31`。大小写/规范化仅作匹配键；结果稳定总排序，最后以(volumeID,nodeID)决胜。取消前/扫描中/排序前后检查。允许排序后台执行。UI 只需要 keys，不生成每行 ViewModel。

## SearchScanner

公开 `public struct DirectoryScanner: Sendable`：

- `init(excludedPaths: [String] = [])`：按绝对路径组件边界排除本应用索引目录，避免索引自身写入触发循环；默认空，不擅自忽略用户文件。
- `scan(volume: VolumeRecord, startingAt: [String] = [""], recursive: Bool = true, onBatch: @escaping @Sendable (DirectoryBatch) async throws -> Void) async throws`：抛 CancellationError；不跟随符号链接，不跨挂载；每目录流式发送批，errors 用不完整批保留旧记录；真实用户盘只读；Darwin 批量 API 有 fallback。回调按目录顺序 await，形成背压。首轮默认单扫描任务，不按 CPU 开满线程。
- `public enum VolumeDiscovery`：`static func mountedVolumes() -> [VolumeRecord]`，`static func describe(rootURL: URL, id: String = UUID().uuidString) -> VolumeRecord`。返回真实文件系统信息/卷 UUID，无法判断时不要伪造。
- `public final class FileEventMonitor: @unchecked Sendable`：`init(rootURL: URL, sinceEventID: UInt64 = 0, checkpointJournal: String? = nil, onChanges: @escaping @Sendable ([FileChange]) -> Void) throws`，`start() throws`，`stop()`，`var journalUUID: String? { get }`，`var currentEventID: UInt64 { get }`、`var resumedFromCheckpoint: Bool { get }`。优先 per-device 流，使用与其对应的 id；start 先于 scan，不能把“最新收到”当“已应用”。回调路径相对索引根，事件 drop -> entire scope，rootchange/wrapped -> full。释放 stream 与生命周期线程安全。

## SearchUI

公开 `@MainActor public protocol SearchWindowDelegate: AnyObject`：

- `func searchWindow(_ window: SearchWindowController, didChange query: SearchQuery)`
- `func searchWindowDidRequestAddRoot(_ window: SearchWindowController)`
- `func searchWindowDidRequestRescan(_ window: SearchWindowController)`
- `func searchWindowDidRequestPause(_ window: SearchWindowController)`
- `func searchWindowDidRestoreNavigation(_ window: SearchWindowController)`：协议提供默认空实现；主控取消在途查询，只在索引换代后重新验证恢复帧。

公开 `@MainActor public final class SearchWindowController: NSWindowController`：

- `init()`；`weak var searchDelegate: (any SearchWindowDelegate)?`
- `var currentQuery: SearchQuery { get }`
- `func update(snapshot: CatalogSnapshot, result: SearchResult)`：同代 snapshot 才渲染，忽略旧代结果；按稳定键恢复选区。
- `func setStatus(_ text: String)`；`func setScanning(_ scanning: Bool)`；`func setPausedState(_ paused: Bool)`，扫描与暂停状态独立。
- `func restoreState(_ state: NavigationState)`；`func captureState() -> NavigationState`

AppKit NSTableView，中文界面。允许NSOpenPanel选择根在主控delegate实现。双击文件或Finder打开不清状态；应用内目录范围进入/后退保存完整state和结果快照。仅用类型图标，不逐条读HDD；QuickLook按需。卷筛选由snapshot.volumes填充。界面应能使用模型中的所有筛选，主控可以二轮追加简化控件。不得调用索引/扫描模块。

## 主控集成

应用入口和AppController只由主控编辑。每个索引范围单独库。本机Application Support存数据库；显式用户选根后扫描，不在程序第一次运行自动全盘递归。测试/演示使用临时夹具，不扫描敏感文档内容。checkpoint可落后于apply（重放幂等），不能跳过未apply且未持久化补扫责任的事件。暂停保存待扫目录，并在恢复时reconcile。
