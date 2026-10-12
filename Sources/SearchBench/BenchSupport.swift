import Foundation
import Darwin
import SearchCore
import SearchIndex
import SearchScanner

// SearchBench 的全部实现。入口（顶层代码）在同目录的 main.swift。
//
// ⚠️ 数据集说明：本基准**全部使用内存合成的条目**，不创建任何真实文件、
// 不扫描用户主目录或外置盘。`--count 1000000` 表示 100 万条合成记录，
// 不是磁盘上真实存在的文件数。唯一会落盘的是可选的 `--persist` 阶段，
// 它把合成记录写入 `NSTemporaryDirectory()` 下的临时 SQLite 库，结束后删除。

// MARK: - 命令行选项

enum BenchError: Error, CustomStringConvertible {
    case badArgument(String)
    case unsafeDatabaseTarget(String)

    var description: String {
        switch self {
        case .badArgument(let message): return message
        case .unsafeDatabaseTarget(let message): return message
        }
    }
}

/// 线程安全的取消探针：第 N 次被询问后返回 true，用于在扫描/排序过程中触发取消。
final class CancelProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var checks = 0
    private let cancelAfterChecks: Int

    init(cancelAfterChecks: Int) {
        self.cancelAfterChecks = max(0, cancelAfterChecks)
    }

    var closure: @Sendable () -> Bool {
        let probe = self
        return {
            probe.lock.lock()
            defer { probe.lock.unlock() }
            probe.checks += 1
            return probe.checks > probe.cancelAfterChecks
        }
    }
}

struct BenchOptions: Sendable {
    var count: Int = 100_000
    var repeats: Int = 5
    var warmup: Int = 1
    var persist: Bool = false
    var databasePath: String?
    var outputPath: String?
    var seed: UInt64 = 0x5EED_5EED
    /// 真实扫描吞吐阶段的文件数；0 = 不创建任何真实文件（默认）。
    var scanFiles: Int = 0
    // 真实盘只读验收（与合成基准分离的第二条管线，实现在 RealScanMode.swift）
    /// 用户指定的只读扫描根（外置盘或目录）。
    var realRootPath: String?
    /// 索引库与 JSON 报告的本机落盘目录；必须与扫描根不在同一设备。
    var reportDirPath: String?
    /// 是否跑第二遍纯元数据扫描并与第一遍逐项比较。
    var verifyPass: Bool = false
    // 既有本机索引的只读性能测量（第三条管线，实现在 IndexPerfMode.swift）
    /// 要测量的本机索引数据库路径；严格只读打开，不写、不复制。
    var indexDatabasePath: String?
    /// 要求测量开始前不存在未 checkpoint 的 WAL，否则拒绕执行。
    var requireCheckpointedWAL: Bool = false

    static let usage = """
    SearchBench —— 寻目本地搜索基准

    用法：SearchBench [选项]

      --count N        合成条目数量（默认 100000，可用 1000000；均为内存合成，不创建真实文件）
      --repeats N      每个查询类的重复次数，用于算 p50/p95（默认 5）
      --warmup N       预热次数（默认 1，不计入统计）
      --persist        追加 SQLite 持久化阶段（写入临时目录中的临时库，结束后删除）
      --database PATH  指定 --persist 的数据库路径（默认临时目录）
      --scan-files N   追加真实扫描吞吐阶段：在临时目录创建 N 个小文件后测速（默认 0 = 不创建；
                       建议 1000～5000，不接受 1000000 这种规模，合成数据请用 --count）
      --output PATH    把 JSON 报告额外写入该文件
      --seed N         合成数据随机种子（默认 1592594621，固定以保证可复现）
      --help           显示本帮助

    真实盘只读验收（与上面的合成模式互斥，分开跑）：
      --real-root PATH   对真实目录做只读完整扫描（外置盘或目录）。不读文件内容，
                         不创建/修改/删除该盘上任何文件，不改系统设置
      --report-dir PATH  索引库与 JSON 报告的本机落盘目录。安全闸：必须与 --real-root
                         不在同一设备（st_dev + 卷 UUID 双重校验），否则拒绕执行（退出码 2）；
                         索引库名带时间戳+UUID，已存在就拒绕，绝不覆盖已有库
      --verify-pass      跑第二遍纯元数据扫描，与第一遍逐项比较，报告实际变更数。
                         盘上有并发改动时该数字非零属正常，不据此判定算法失败

      例：SearchBench --real-root "/Volumes/某盘" --report-dir ~/.local/share/maceverything/bench --verify-pass

    既有本机索引只读性能测量（与上面两条互斥，分开跑）：
      --index-db PATH            对已存在的本机索引做分阶段只读测量：打开 / 计数 / 读取解码 /
                                 引擎构建 / 查询 p50p95 / 排序稳定性 / 取消
      --require-checkpointed-wal  若索引存在未 checkpoint 的 WAL 则拒绕执行（退出码 2）。
                                 带 WAL 的库读到的状态与已 checkpoint 的库不同，跨次对比不可靠

      例：SearchBench --index-db "$HOME/Library/Application Support/MacEverything/catalog.sqlite"

      该模式经 SearchIndex.CatalogReader 以 SQLITE_OPEN_READONLY 打开：
      不写主库文件、不建表、不 checkpoint、不复制数据库文件。
      注意「不写主库文件」不等于「物理上写不了」：WAL 库的 -wal / -shm 旁件仍可能被维护。
      只用 immutable 打开才能完全不碰旁件，但那要求调用方静态保证无并发写入者，此处不满足。

    输出：合成模式 stdout 为 JSON；真实模式 JSON 保存在 --report-dir，stderr 为摘要。
    退出码 0=通过，1=自检失败，2=参数错误或未满足安全条件。

    说明：默认不碰磁盘上的任何真实文件；只有 --scan-files N 会在临时目录创建 N 个小文件，
    测完立即删除。它反映的是本机临时卷上的吞吐，不能代表机械盘或外置盘。
    """

    static func parse(_ arguments: [String]) throws -> BenchOptions {
        var options = BenchOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func value(_ name: String) throws -> String {
                guard index + 1 < arguments.count else {
                    throw BenchError.badArgument("参数 \(name) 缺少取值")
                }
                index += 1
                return arguments[index]
            }
            func integer(_ name: String, minimum: Int) throws -> Int {
                let raw = try value(name)
                guard let parsed = Int(raw), parsed >= minimum else {
                    throw BenchError.badArgument("参数 \(name) 需要一个 ≥ \(minimum) 的整数，实际为 \(raw)")
                }
                return parsed
            }

            switch argument {
            case "--count":
                options.count = try integer("--count", minimum: 1)
            case "--repeats":
                options.repeats = try integer("--repeats", minimum: 1)
            case "--warmup":
                options.warmup = try integer("--warmup", minimum: 0)
            case "--persist":
                options.persist = true
            case "--database":
                options.databasePath = try value("--database")
            case "--scan-files":
                options.scanFiles = try integer("--scan-files", minimum: 0)
            case "--real-root":
                options.realRootPath = try value("--real-root")
            case "--report-dir":
                options.reportDirPath = try value("--report-dir")
            case "--verify-pass":
                options.verifyPass = true
            case "--index-db":
                options.indexDatabasePath = try value("--index-db")
            case "--require-checkpointed-wal":
                options.requireCheckpointedWAL = true
            case "--output":
                options.outputPath = try value("--output")
            case "--seed":
                let raw = try value("--seed")
                guard let seed = UInt64(raw) else {
                    throw BenchError.badArgument("参数 --seed 需要一个无符号整数，实际为 \(raw)")
                }
                options.seed = seed
            case "--help", "-h":
                throw BenchError.badArgument(BenchOptions.usage)
            default:
                throw BenchError.badArgument("未知参数 \(argument)\n\n" + BenchOptions.usage)
            }
            index += 1
        }
        if options.scanFiles > 20_000 {
            throw BenchError.badArgument(
                "--scan-files 上限 20000：真实扫描阶段只用于小规模测速，大规模数据请用 --count 的合成条目")
        }
        return options
    }

    // MARK: 安全的临时数据库目标

    /// 解析一个**只会新建、只删自己**的数据库路径。
    ///
    /// 规则：
    /// - 默认在临时目录里用 UUID 命名新建，测完删除。
    /// - `--database` 指定时，目标路径（或其 `-wal` / `-shm` 旁件）**已存在就拒绕**，
    ///   绝不打开、更绝不删除用户的库。
    /// - 返回的 `cleanup` 只包含本次新建的文件，结束时只删这些。
    static func resolveDatabaseTarget(
        _ requested: String?
    ) throws -> (url: URL, cleanupDirectory: URL?) {
        guard let requested else {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("MacEverything-SearchBench-\(UUID().uuidString)", isDirectory: true)
            return (directory.appendingPathComponent("bench.sqlite", isDirectory: false), directory)
        }

        let url = URL(fileURLWithPath: requested, isDirectory: false)
        let siblings = [url.path, url.path + "-wal", url.path + "-shm", url.path + "-journal"]
        for path in siblings where FileManager.default.fileExists(atPath: path) {
            throw BenchError.unsafeDatabaseTarget(
                """
                拒绝使用已存在的数据库：\(path)
                --database 只接受一个不存在的新路径（测试夹具）。为避免弄坏你自己的数据，
                基准既不会打开、也不会删除已存在的库或它的 -wal/-shm 旁件。
                换一个路径，或直接不加 --database 使用临时目录。
                """
            )
        }
        let parent = url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else {
            throw BenchError.badArgument("--database 的父目录不存在：\(parent.path)")
        }
        // 指定路径时不新建目录，结束时只删本次新建的数据库文件。
        return (url, nil)
    }

    /// 删除本次新建的数据库及其旁件（不存在就跳过）。
    static func removeDatabase(at url: URL) -> Bool {
        var removed = true
        for path in [url.path, url.path + "-wal", url.path + "-shm", url.path + "-journal"] {
            if FileManager.default.fileExists(atPath: path) {
                do {
                    try FileManager.default.removeItem(atPath: path)
                } catch {
                    removed = false
                }
            }
        }
        return removed
    }

    /// 写入 JSON 报告：只创建父目录，不删任何东西；目标是目录就拒绕。
    static func writeReport(json: String, to path: String) throws {
        let url = URL(fileURLWithPath: path, isDirectory: false)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else {
                throw BenchError.badArgument("--output 指向一个目录，请给出文件路径：\(url.path)")
            }
        }
        let parent = url.deletingLastPathComponent()
        if !parent.path.isEmpty {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try Data(json.utf8).write(to: url, options: .atomic)
    }
}

// MARK: - 计时工具

enum BenchClock {
    static func now() -> DispatchTime { DispatchTime.now() }

    static func milliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    /// 进程峰值常驻内存（Darwin 上 ru_maxrss 单位是字节）。
    static func peakResidentBytes() -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
        return Int64(usage.ru_maxrss)
    }
}

struct Percentiles: Codable {
    var samples: Int
    var minMs: Double
    var p50Ms: Double
    var p95Ms: Double
    var maxMs: Double

    init(_ values: [Double]) {
        let sorted = values.sorted()
        samples = sorted.count
        minMs = sorted.first ?? 0
        maxMs = sorted.last ?? 0
        p50Ms = Percentiles.percentile(sorted, 0.50)
        p95Ms = Percentiles.percentile(sorted, 0.95)
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}

// MARK: - 合成数据集（纯内存）

struct BenchSplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum SyntheticDataset {
    static let chineseWords = [
        "文档", "报告", "图片", "视频", "合同", "发票", "预算", "笔记",
        "截图", "素材", "录音", "表格", "备份", "草稿", "索引", "缓存",
    ]
    static let latinWords = [
        "report", "invoice", "budget", "notes", "meeting", "project", "archive",
        "presentation", "dataset", "backup", "summary", "contract", "receipt",
        "proposal", "statement", "timeline", "worksheet", "checklist",
    ]
    static let extensions = ["pdf", "txt", "docx", "xlsx", "png", "jpg", "mov", "swift", "zip"]

    /// 生成一条合成的相对路径。中文两字词占约一半，模拟真实中文目录命名习惯。
    static func path(index: Int, generator: inout BenchSplitMix64) -> String {
        let directoryCount = 4_000
        let directory = "目录" + String(format: "%04d", Int.random(in: 0..<directoryCount, using: &generator))
        let stem = Bool.random(using: &generator)
            ? chineseWords[Int.random(in: 0..<chineseWords.count, using: &generator)]
            : latinWords[Int.random(in: 0..<latinWords.count, using: &generator)]
        let ext = extensions[Int.random(in: 0..<extensions.count, using: &generator)]
        return "\(directory)/\(stem)-\(String(format: "%06d", index)).\(ext)"
    }

    static func entries(count: Int, volumeID: String, seed: UInt64) -> [IndexedEntry] {
        var generator = BenchSplitMix64(seed: seed)
        var result: [IndexedEntry] = []
        result.reserveCapacity(count)
        let baseDate = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z
        for index in 0..<count {
            let relativePath = path(index: index, generator: &generator)
            result.append(
                IndexedEntry(
                    key: EntryKey(volumeID: volumeID, nodeID: Int64(index + 1)),
                    relativePath: relativePath,
                    name: (relativePath as NSString).lastPathComponent,
                    isDirectory: false,
                    size: Int64(1_024 * (1 + index % 4_096)),
                    modifiedAt: baseDate.addingTimeInterval(Double(index % 100_000))
                )
            )
        }
        return result
    }

    /// 把合成条目按父目录分组，用于持久化阶段构造合法的 `DirectoryBatch`。
    static func directoryBatches(_ entries: [IndexedEntry], volumeID: String) -> [DirectoryBatch] {
        var grouped: [String: [ScannedEntry]] = [:]
        grouped.reserveCapacity(4_096)
        for entry in entries {
            let parent = (entry.relativePath as NSString).deletingLastPathComponent
            grouped[parent, default: []].append(
                ScannedEntry(
                    relativePath: entry.relativePath,
                    name: entry.name,
                    isDirectory: entry.isDirectory,
                    isSymbolicLink: entry.isSymbolicLink,
                    size: entry.size,
                    modifiedAt: entry.modifiedAt
                )
            )
        }
        return grouped.keys.sorted().map { parent in
            DirectoryBatch(
                volumeID: volumeID,
                directoryRelativePath: parent,
                entries: grouped[parent] ?? [],
                isComplete: true,
                issue: nil
            )
        }
    }
}

// MARK: - 查询与报告模型

struct BenchQueryCase: Sendable {
    let id: String
    let label: String
    let text: String
}

enum BenchQueryCases {
    /// 一汉字 / 两汉字 / 单个拉丁字母 / 长词 —— 覆盖 MVP 要求的全部短词形态。
    static let all: [BenchQueryCase] = [
        BenchQueryCase(id: "hanzi-1", label: "单字中文", text: "文"),
        BenchQueryCase(id: "hanzi-2", label: "双字中文", text: "报告"),
        BenchQueryCase(id: "letter-1", label: "单个拉丁字母", text: "a"),
        BenchQueryCase(id: "long-word", label: "长单词", text: "presentation"),
    ]
}

struct QueryStat: Codable {
    var id: String
    var label: String
    var text: String
    var firstQueryMs: Double
    var engineBuildMs: Double
    var hitCount: Int
    var warmup: Percentiles
    var measured: Percentiles
}

struct SortStat: Codable {
    var sort: String
    var ascending: Bool
    var hitCount: Int
    var elapsedMs: Double
}

struct CancelProbeStat: Codable {
    /// 允许引擎询问多少次之后才返回「已取消」。
    var checksBeforeCancel: Int
    var isCancelled: Bool
    var keyCount: Int
    var elapsedMs: Double
}

struct CancelStat: Codable {
    var queryText: String
    var cancelledMs: Double
    var isCancelled: Bool
    var cancelledKeyCount: Int
    var uncancelledHitCount: Int
    var uncancelledMs: Double
    /// 在不同时间点触发取消的探测：任何一次真取消都必须返回空结果。
    var sweep: [CancelProbeStat]
}

struct DatasetStat: Codable {
    var kind: String
    var entryCount: Int
    var directoryCount: Int
    var seed: UInt64
    var realFilesCreated: Int
    var generateMs: Double
    var note: String
}

struct BuildStat: Codable {
    var engineInitMs: Double
    var engineCount: Int
    var snapshotEntryCount: Int
    var peakResidentBytesAfterBuild: Int64
}

struct PersistenceStat: Codable {
    var ran: Bool
    var entryCount: Int
    var directoryBatchCount: Int
    var writeMs: Double
    var reopenAndLoadMs: Double
    var reopenedEntryCount: Int
    var reopenMatched: Bool
    var databasePath: String
    var removedAfterRun: Bool
    var note: String
}

struct EnvironmentStat: Codable {
    var osVersion: String
    var activeProcessorCount: Int
    var processName: String
}

struct BenchReport: Codable {
    var schemaVersion: Int
    var generatedAtUTC: String
    var dataset: DatasetStat
    var environment: EnvironmentStat
    var build: BuildStat
    var queries: [QueryStat]
    var sorts: [SortStat]
    var cancel: CancelStat
    var persistence: PersistenceStat
    var scan: ScanStat
    var memory: MemoryStat
    var selfCheckFailures: [String]
    var notes: [String]
}

struct MemoryStat: Codable {
    var peakResidentBytes: Int64
    var peakResidentMB: Double
}

struct ScanStat: Codable {
    var ran: Bool
    var realFilesCreated: Int
    var directoryCount: Int
    var entriesIndexed: Int
    var directoryBatchCount: Int
    var firstScanMs: Double
    var secondScanMs: Double
    var entriesPerSecondFirstPass: Double
    var allBatchesComplete: Bool
    var symlinksFollowed: Int
    var fixturePath: String
    var fixtureRemovedAfterRun: Bool
    var note: String
}

/// 扫描阶段的批次收集器（`onBatch` 是 `@Sendable` 闭包）。
final class ScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var entries = 0
    private var batches = 0
    private var incomplete = 0
    private var symlinkDescents = 0

    func consume(_ batch: DirectoryBatch) {
        lock.lock()
        batches += 1
        entries += batch.entries.count
        if !batch.isComplete { incomplete += 1 }
        // 只统计「真的跟进链接了」的情况：出现了链接目录自身的批次，
        // 或条目路径已经落到链接之下。仅把链接当条目报告出来不算跟进。
        let descendedDirectory = batch.directoryRelativePath == "链接"
            || batch.directoryRelativePath.hasPrefix("链接/")
        let descendedEntry = batch.entries.contains { $0.relativePath.hasPrefix("链接/") }
        if descendedDirectory || descendedEntry { symlinkDescents += 1 }
        lock.unlock()
    }

    var snapshot: (entries: Int, batches: Int, incomplete: Int, symlinks: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (entries, batches, incomplete, symlinkDescents)
    }
}

// MARK: - 运行器

enum SearchBenchRunner {

    static func run(arguments: [String]) async -> Int32 {
        let options: BenchOptions
        do {
            options = try BenchOptions.parse(arguments)
        } catch {
            FileHandle.standardError.write(Data(("\(error)\n").utf8))
            return 2
        }

        // 真实盘只读验收：完全独立的第二条管线，不与合成基准混跑。
        if RealScanRunner.isRealMode(options) {
            do {
                return try await RealScanRunner.run(options: options)
            } catch {
                FileHandle.standardError.write(Data(("拒绝执行：\(error)\n").utf8))
                return 2
            }
        }

        // 既有本机索引的只读性能测量：第三条管线。
        if IndexPerfRunner.isIndexMode(options) {
            do {
                return try await IndexPerfRunner.run(options: options)
            } catch {
                FileHandle.standardError.write(Data(("拒绝执行：\(error)\n").utf8))
                return 2
            }
        }

        // 持久化阶段的目标路径先行校验：已存在的库一律拒绕（退出码 2），
        // 不打开也不删除用户的数据库。
        var databaseTarget: (url: URL, cleanupDirectory: URL?)? = nil
        if options.persist {
            do {
                databaseTarget = try BenchOptions.resolveDatabaseTarget(options.databasePath)
            } catch {
                FileHandle.standardError.write(Data(("拒绝执行：\(error)\n").utf8))
                return 2
            }
        }

        let report = await execute(options: options, databaseTarget: databaseTarget)

        let json: String
        do {
            json = try encode(report)
        } catch {
            FileHandle.standardError.write(Data(("JSON 编码失败：\(error)\n").utf8))
            return 1
        }

        FileHandle.standardOutput.write(Data(json.utf8))
        FileHandle.standardOutput.write(Data("\n".utf8))
        FileHandle.standardError.write(Data(summary(report).utf8))

        if let outputPath = options.outputPath {
            // 只写文件：可能覆盖一份「上一次基准报告」，但不会删除目录或任何其他东西。
            do {
                try BenchOptions.writeReport(json: json, to: outputPath)
                FileHandle.standardError.write(Data("JSON 已写入 \(outputPath)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data(("JSON 写入失败：\(error)\n").utf8))
                return 1
            }
        }

        return report.selfCheckFailures.isEmpty ? 0 : 1
    }

    // MARK: 阶段

    private static func execute(
        options: BenchOptions,
        databaseTarget: (url: URL, cleanupDirectory: URL?)?
    ) async -> BenchReport {
        let volume = VolumeRecord(
            id: "bench-volume",
            name: "基准合成卷",
            rootPath: "/synthetic/bench",
            fileSystem: "synthetic"
        )
        var failures: [String] = []

        // 1. 生成合成数据集（纯内存，不创建任何文件）
        let generateStart = BenchClock.now()
        let entries = SyntheticDataset.entries(count: options.count, volumeID: volume.id, seed: options.seed)
        let generateMs = BenchClock.milliseconds(since: generateStart)
        let directoryCount = Set(entries.map { ($0.relativePath as NSString).deletingLastPathComponent }).count

        let snapshot = CatalogSnapshot(generation: 1, entries: entries, volumes: [volume])

        // 2. 构建搜索引擎（归一化匹配键缓存）
        let buildStart = BenchClock.now()
        let engine = SearchEngine(snapshot: snapshot)
        let buildMs = BenchClock.milliseconds(since: buildStart)

        // 3. 查询延迟：每个查询类先测一次冷启动（新建引擎后的首个查询），再测 p50/p95
        var queryStats: [QueryStat] = []
        for queryCase in BenchQueryCases.all {
            let coldEngineStart = BenchClock.now()
            let coldEngine = SearchEngine(snapshot: snapshot)
            let coldEngineMs = BenchClock.milliseconds(since: coldEngineStart)

            let query = SearchQuery(text: queryCase.text)
            let firstStart = BenchClock.now()
            let firstResult = coldEngine.search(query)
            let firstMs = BenchClock.milliseconds(since: firstStart)

            for _ in 0..<options.warmup {
                _ = engine.search(query)
            }

            var samples: [Double] = []
            var hitCount = firstResult.keys.count
            for _ in 0..<options.repeats {
                let start = BenchClock.now()
                let result = engine.search(query)
                samples.append(BenchClock.milliseconds(since: start))
                if result.isCancelled {
                    failures.append("查询「\(queryCase.text)」返回了被取消的结果")
                }
                hitCount = result.keys.count
            }
            if hitCount == 0 {
                failures.append("查询「\(queryCase.text)」命中 0 条，合成数据集可能与查询不匹配")
            }

            queryStats.append(
                QueryStat(
                    id: queryCase.id,
                    label: queryCase.label,
                    text: queryCase.text,
                    firstQueryMs: round3(firstMs),
                    engineBuildMs: round3(coldEngineMs),
                    hitCount: hitCount,
                    warmup: Percentiles([]),
                    measured: Percentiles(samples)
                )
            )
        }

        // 4. 全排序：命中量最大的查询在四种排序键与两个方向上各跑一次
        var sortStats: [SortStat] = []
        let widestText = queryStats.max { $0.hitCount < $1.hitCount }?.text
        let widestQuery = BenchQueryCases.all.first { $0.text == widestText } ?? BenchQueryCases.all[0]
        for sort in SearchSort.allCases {
            for ascending in [true, false] {
                let query = SearchQuery(text: widestQuery.text, sort: sort, ascending: ascending)
                let start = BenchClock.now()
                let result = engine.search(query)
                let elapsed = BenchClock.milliseconds(since: start)
                if result.keys.count == 0 {
                    failures.append("排序统计「\(sort.rawValue)」没有任何命中")
                }
                sortStats.append(
                    SortStat(
                        sort: sort.rawValue,
                        ascending: ascending,
                        hitCount: result.keys.count,
                        elapsedMs: round3(elapsed)
                    )
                )
            }
        }

        // 5. 取消：必须快速返回、标记取消，且不返回半截命中
        let cancelQuery = SearchQuery(text: widestQuery.text)
        let cancelStart = BenchClock.now()
        let cancelledResult = engine.search(cancelQuery, isCancelled: { true })
        let cancelMs = BenchClock.milliseconds(since: cancelStart)

        let referenceStart = BenchClock.now()
        let referenceResult = engine.search(cancelQuery)
        let referenceMs = BenchClock.milliseconds(since: referenceStart)
        let referenceCount = referenceResult.keys.count

        if !cancelledResult.isCancelled {
            failures.append("立即取消时结果未标记 isCancelled")
        }
        if !cancelledResult.keys.isEmpty {
            failures.append("立即取消时仍返回了 \(cancelledResult.keys.count) 条半截结果")
        }
        if referenceCount == 0 {
            failures.append("同一查询在正常情况下命中 0 条，取消自检无意义")
        }

        // 在多个时间点触发取消（包括扫描过程中与排序过程中），任何一次真取消
        // 都必须返回空结果，而不是半截命中。
        var sweep: [CancelProbeStat] = []
        for threshold in [1, 3, 10, 30, 100, 1_000] {
            let probe = CancelProbe(cancelAfterChecks: threshold)
            let start = BenchClock.now()
            let result = engine.search(cancelQuery, isCancelled: probe.closure)
            let elapsed = BenchClock.milliseconds(since: start)

            if result.isCancelled, !result.keys.isEmpty {
                failures.append(
                    "取消探测（\(threshold) 次检查后取消）返回了 \(result.keys.count) 条半截结果")
            }
            if !result.isCancelled, result.keys.count != referenceCount {
                failures.append(
                    "取消探测（\(threshold) 次检查）未触发取消时，命中数 \(result.keys.count) 与正常 \(referenceCount) 不一致")
            }
            sweep.append(
                CancelProbeStat(
                    checksBeforeCancel: threshold,
                    isCancelled: result.isCancelled,
                    keyCount: result.keys.count,
                    elapsedMs: round3(elapsed)
                )
            )
        }

        let cancelStat = CancelStat(
            queryText: widestQuery.text,
            cancelledMs: round3(cancelMs),
            isCancelled: cancelledResult.isCancelled,
            cancelledKeyCount: cancelledResult.keys.count,
            uncancelledHitCount: referenceCount,
            uncancelledMs: round3(referenceMs),
            sweep: sweep
        )

        // 6. 可选：SQLite 持久化阶段（临时目录）
        let persistenceOutcome = await runPersistencePhase(
            enabled: options.persist,
            target: databaseTarget,
            entries: entries,
            volume: volume
        )
        failures.append(contentsOf: persistenceOutcome.failures)
        let persistence = persistenceOutcome.stat

        // 7. 可选：小型临时目录真实扫描吞吐
        let scanOutcome = await runScanPhase(fileCount: options.scanFiles)
        failures.append(contentsOf: scanOutcome.failures)
        let scan = scanOutcome.stat

        let peakBytes = BenchClock.peakResidentBytes()

        return BenchReport(
            schemaVersion: 1,
            generatedAtUTC: ISO8601DateFormatter().string(from: Date()),
            dataset: DatasetStat(
                kind: "synthetic",
                entryCount: entries.count,
                directoryCount: directoryCount,
                seed: options.seed,
                realFilesCreated: 0,
                generateMs: round3(generateMs),
                note: "全部条目为内存合成；磁盘上没有创建对应文件，realFilesCreated 恒为 0"
            ),
            environment: EnvironmentStat(
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
                processName: ProcessInfo.processInfo.processName
            ),
            build: BuildStat(
                engineInitMs: round3(buildMs),
                engineCount: snapshot.entries.count,
                snapshotEntryCount: snapshot.entries.count,
                peakResidentBytesAfterBuild: BenchClock.peakResidentBytes()
            ),
            queries: queryStats,
            sorts: sortStats,
            cancel: cancelStat,
            persistence: persistence,
            scan: scan,
            memory: MemoryStat(
                peakResidentBytes: peakBytes,
                peakResidentMB: round3(Double(peakBytes) / 1_048_576)
            ),
            selfCheckFailures: failures,
            notes: [
                "数据集为合成条目，不代表任何真实磁盘文件数量或真实目录结构。",
                "查询延迟为单次内存搜索耗时，不含磁盘 IO；真实端到端延迟受机械盘影响，需另测。",
                "扫描吞吐（若启用）是在临时目录上创建的真实小文件，只反映本机当前卷，不外推到机械盘或外置盘。",
                "未覆盖：外置盘离线、跨 Windows/跨系统元数据、FSEvents 故障补扫的端到端时延。"
            ]
        )
    }

    /// 可选的 SQLite 持久化阶段：写入 → 重开 → 全量读回，比对条目数。
    private static func runPersistencePhase(
        enabled: Bool,
        target: (url: URL, cleanupDirectory: URL?)?,
        entries: [IndexedEntry],
        volume: VolumeRecord
    ) async -> (stat: PersistenceStat, failures: [String]) {
        let note = "数据库位于临时目录，测量结束后删除；不写入用户数据目录"
        guard enabled, let target else {
            return (
                PersistenceStat(
                    ran: false,
                    entryCount: 0,
                    directoryBatchCount: 0,
                    writeMs: 0,
                    reopenAndLoadMs: 0,
                    reopenedEntryCount: 0,
                    reopenMatched: true,
                    databasePath: "",
                    removedAfterRun: true,
                    note: "未启用（加 --persist 运行）"
                ),
                []
            )
        }

        // 目标路径已在 run() 里校验为“不存在的新路径”，这里直接用。
        let databaseURL = target.url
        let batches = SyntheticDataset.directoryBatches(entries, volumeID: volume.id)
        var failures: [String] = []
        let writeStart = BenchClock.now()
        var writeMs = 0.0
        do {
            let store = try CatalogStore(databaseURL: databaseURL)
            try await store.registerVolume(volume)
            for batch in batches {
                try await store.apply(batch)
            }
            writeMs = BenchClock.milliseconds(since: writeStart)

            let reopenStart = BenchClock.now()
            let reopened = try CatalogStore(databaseURL: databaseURL)
            let loaded = try await reopened.entries()
            let reopenedMs = BenchClock.milliseconds(since: reopenStart)
            let matched = loaded.count == entries.count
            if !matched {
                failures.append("持久化阶段重开后条目数不一致：写入 \(entries.count)，读回 \(loaded.count)")
            }
            // 只删本次新建的库及其旁件；若目录也是本次新建的才删目录。
            let removed = BenchOptions.removeDatabase(at: databaseURL)
            if let cleanupDirectory = target.cleanupDirectory {
                try? FileManager.default.removeItem(at: cleanupDirectory)
            }

            return (
                PersistenceStat(
                    ran: true,
                    entryCount: entries.count,
                    directoryBatchCount: batches.count,
                    writeMs: round3(writeMs),
                    reopenAndLoadMs: round3(reopenedMs),
                    reopenedEntryCount: loaded.count,
                    reopenMatched: matched,
                    databasePath: databaseURL.path,
                    removedAfterRun: removed,
                    note: note
                ),
                failures
            )
        } catch {
            BenchOptions.removeDatabase(at: databaseURL)
            if let cleanupDirectory = target.cleanupDirectory {
                try? FileManager.default.removeItem(at: cleanupDirectory)
            }
            failures.append("持久化阶段失败：\(error)")
            return (
                PersistenceStat(
                    ran: true,
                    entryCount: entries.count,
                    directoryBatchCount: batches.count,
                    writeMs: round3(writeMs),
                    reopenAndLoadMs: 0,
                    reopenedEntryCount: 0,
                    reopenMatched: false,
                    databasePath: databaseURL.path,
                    removedAfterRun: true,
                    note: "失败：" + String(describing: error)
                ),
                failures
            )
        }
    }

    /// 小型临时目录的真实扫描吞吐阶段。
    ///
    /// 与合成数据阶段不同：这里真的在 `NSTemporaryDirectory()` 下建一个小的目录树，
    /// 跑一次 `DirectoryScanner`，再跑一次（缓存已热）作对照，结束后删掉整个夹具。
    /// 文件数被上限抦在 20000 以内，避免变成「百万真实文件」。
    private static func runScanPhase(
        fileCount: Int
    ) async -> (stat: ScanStat, failures: [String]) {
        let note = "临时目录内的小规模真实文件，测完即删；不代表机械盘或外置盘速度"
        guard fileCount > 0 else {
            return (
                ScanStat(
                    ran: false, realFilesCreated: 0, directoryCount: 0, entriesIndexed: 0,
                    directoryBatchCount: 0, firstScanMs: 0, secondScanMs: 0,
                    entriesPerSecondFirstPass: 0, allBatchesComplete: true, symlinksFollowed: 0,
                    fixturePath: "", fixtureRemovedAfterRun: true,
                    note: "未启用（加 --scan-files N 运行；默认不创建任何真实文件）"
                ),
                []
            )
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MacEverything-SearchBench-Scan-\(UUID().uuidString)", isDirectory: true)
        // 链接目标建在 root 旁边（不在 root 内），单独跟踪，失败路径也要清掉。
        var linkTarget: URL?
        let directoryCount = max(1, fileCount / 10)
        var failures: [String] = []

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // 真实写入 N 个小文件（仅临时目录）。
            let payload = Data(repeating: 0x41, count: 64)
            for index in 0..<fileCount {
                let directory = root
                    .appendingPathComponent("目录\(String(format: "%03d", index / 10))", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let stem = index.isMultiple(of: 2)
                    ? SyntheticDataset.chineseWords[index % SyntheticDataset.chineseWords.count]
                    : SyntheticDataset.latinWords[index % SyntheticDataset.latinWords.count]
                let ext = SyntheticDataset.extensions[index % SyntheticDataset.extensions.count]
                let file = directory.appendingPathComponent("\(stem)-\(String(format: "%05d", index)).\(ext)")
                try payload.write(to: file)
            }
            // 一个指向夹具外的符号链接，用来验证扫描不跟随链接。
            let outside = root.deletingLastPathComponent()
                .appendingPathComponent("MacEverything-SearchBench-Outside-\(UUID().uuidString)", isDirectory: true)
            linkTarget = outside
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try payload.write(to: outside.appendingPathComponent("越界.txt"))
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("链接"),
                withDestinationURL: outside
            )

            let volume = VolumeDiscovery.describe(rootURL: root, id: "bench-scan-volume")
            let scanner = DirectoryScanner()

            let firstCounter = ScanCounter()
            let firstStart = BenchClock.now()
            try await scanner.scan(volume: volume, startingAt: [""], recursive: true) { batch in
                firstCounter.consume(batch)
            }
            let firstMs = BenchClock.milliseconds(since: firstStart)

            let secondCounter = ScanCounter()
            let secondStart = BenchClock.now()
            try await scanner.scan(volume: volume, startingAt: [""], recursive: true) { batch in
                secondCounter.consume(batch)
            }
            let secondMs = BenchClock.milliseconds(since: secondStart)

            let first = firstCounter.snapshot
            let second = secondCounter.snapshot

            if first.entries < fileCount {
                failures.append(
                    "真实扫描阶段枚举到的条目少于创建的文件数：创建 \(fileCount)，枚举 \(first.entries)")
            }
            if first.incomplete > 0 {
                failures.append("真实扫描阶段有 \(first.incomplete) 个目录批次不是完整批次")
            }
            if first.entries != second.entries {
                failures.append(
                    "两次扫描枚举数量不一致：第一次 \(first.entries)，第二次 \(second.entries)")
            }
            if first.symlinks > 0 {
                failures.append("扫描跟随了符号链接：\(first.symlinks) 个目录批次出现符号链接目录")
            }

            if let linkTarget { try? FileManager.default.removeItem(at: linkTarget) }
            try? FileManager.default.removeItem(at: root)
            let removed = !FileManager.default.fileExists(atPath: root.path)

            let entriesPerSecond = firstMs > 0 ? Double(first.entries) / (firstMs / 1_000) : 0
            return (
                ScanStat(
                    ran: true,
                    realFilesCreated: fileCount,
                    directoryCount: directoryCount,
                    entriesIndexed: first.entries,
                    directoryBatchCount: first.batches,
                    firstScanMs: round3(firstMs),
                    secondScanMs: round3(secondMs),
                    entriesPerSecondFirstPass: round3(entriesPerSecond),
                    allBatchesComplete: first.incomplete == 0,
                    symlinksFollowed: first.symlinks,
                    fixturePath: root.path,
                    fixtureRemovedAfterRun: removed,
                    note: note
                ),
                failures
            )
        } catch {
            if let linkTarget { try? FileManager.default.removeItem(at: linkTarget) }
            try? FileManager.default.removeItem(at: root)
            failures.append("真实扫描阶段失败：\(error)")
            return (
                ScanStat(
                    ran: true, realFilesCreated: fileCount, directoryCount: directoryCount,
                    entriesIndexed: 0, directoryBatchCount: 0, firstScanMs: 0, secondScanMs: 0,
                    entriesPerSecondFirstPass: 0, allBatchesComplete: false, symlinksFollowed: 0,
                    fixturePath: root.path, fixtureRemovedAfterRun: true,
                    note: "失败：" + String(describing: error)
                ),
                failures
            )
        }
    }

    // MARK: 输出

    private static func encode(_ report: BenchReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        return String(decoding: data, as: UTF8.self)
    }

    private static func round3(_ value: Double) -> Double {
        (value * 1_000).rounded() / 1_000
    }

    private static func summary(_ report: BenchReport) -> String {
        var lines: [String] = []
        lines.append("")
        lines.append("=== SearchBench 合成数据基准（未创建任何真实文件）===")
        lines.append("数据集：\(report.dataset.entryCount) 条合成条目 / \(report.dataset.directoryCount) 个合成目录，真实文件数 \(report.dataset.realFilesCreated)")
        lines.append("环境：\(report.environment.osVersion)，\(report.environment.activeProcessorCount) 逻辑核")
        lines.append(String(format: "引擎构建（匹配键缓存）：%.3f ms", report.build.engineInitMs))
        lines.append("")
        lines.append("查询延迟：")
        for stat in report.queries {
            lines.append(String(
                format: "  %@（%@）首查 %.3f ms，p50 %.3f ms，p95 %.3f ms，命中 %d 条",
                stat.label, stat.text, stat.firstQueryMs, stat.measured.p50Ms, stat.measured.p95Ms, stat.hitCount
            ))
        }
        lines.append("")
        lines.append("全排序：")
        for stat in report.sorts {
            lines.append(String(
                format: "  sort=%@ %@：命中 %d 条，%.3f ms",
                stat.sort, stat.ascending ? "升序" : "降序", stat.hitCount, stat.elapsedMs
            ))
        }
        lines.append("")
        lines.append(String(
            format: "取消：%.3f ms，isCancelled=%@，取消后返回 %d 条，同查询正常命中 %d 条",
            report.cancel.cancelledMs,
            report.cancel.isCancelled ? "true" : "false",
            report.cancel.cancelledKeyCount,
            report.cancel.uncancelledHitCount
        ))
        if report.persistence.ran {
            lines.append(String(
                format: "持久化：写入 %.1f ms（%d 个目录批次），重开读回 %.1f ms，条目数 %d（一致：%@）",
                report.persistence.writeMs,
                report.persistence.directoryBatchCount,
                report.persistence.reopenAndLoadMs,
                report.persistence.reopenedEntryCount,
                report.persistence.reopenMatched ? "是" : "否"
            ))
        }
        if report.scan.ran {
            lines.append(String(
                format: "真实扫描吞吐：创建 %d 个真实文件（%d 个目录），枚举 %d 条，首扫 %.1f ms，二扫 %.1f ms，约 %.0f 条/秒，全部批次完整：%@",
                report.scan.realFilesCreated,
                report.scan.directoryCount,
                report.scan.entriesIndexed,
                report.scan.firstScanMs,
                report.scan.secondScanMs,
                report.scan.entriesPerSecondFirstPass,
                report.scan.allBatchesComplete ? "是" : "否"
            ))
        }
        lines.append(String(format: "峰值常驻内存：%.1f MB", report.memory.peakResidentMB))
        if report.selfCheckFailures.isEmpty {
            lines.append("自检：通过")
        } else {
            lines.append("自检：失败")
            for failure in report.selfCheckFailures { lines.append("  - \(failure)") }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
