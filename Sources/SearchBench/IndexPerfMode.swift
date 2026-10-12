import Foundation
import SearchCore
import SearchIndex

// 既有本机索引的**只读**性能模式（第三条管线，与合成基准、真实盘扫描都分开）。
//
// 用法：
//   SearchBench --index-db "/path/to/catalog.sqlite" [--require-checkpointed-wal] [--repeats N]
//
// 硬约束（代码层面保证）：
// * 不写主库文件。走 SearchIndex.CatalogReader —— 它以 SQLITE_OPEN_READONLY 打开、
//   不建表、不跑任何会改库的 pragma，**主库文件不会被写**。
//   注意这不等于「什么都没写」：SQLite 对 WAL 库仍会维护 `-wal` / `-shm` 旁件，
//   只读连接可能创建或更新它们。只读保证的是「主库文件零写入」，仅此而已。
//   **不用 CatalogStore 打开原库**：CatalogStore.init 是读写连接、会跑 schema 初始化并可能写 meta。
// * 不复制。只在原地读，不拷贝数据库文件。
//   **禁止复制 GB 级真实索引**（本项目已授权的边界）：避免额外占用一份同体积的空间，
//   也避免产生第二份副本。需要看数据库请直接读原件。
// * 不改原库。不 checkpoint、不 vacuum、不改 journal 模式。
// * 报告只含计数、统计与阶段耗时；不含任何用户文件路径。数据库只报**文件名**与字节数，
//   完整路径仅打到 stderr（终端是本机的），避免报告里出现含用户名的本机路径。
// * 不读被索引的文件内容。索引里只有名字、大小、时间这类元数据，本模式只读索引库本身，
//   不 stat、不打开、不读取任何被索引的用户文件，也不触碰外置盘。
//
// ⚠️ 不要写「不写磁盘」。WAL 库的 `-wal` / `-shm` 旁件可能被 SQLite 创建或更新，
//    本模式不保证「磁盘零写入」，只保证「主库文件零写入 + 不读被索引内容」。

// MARK: - 选项

// 三个新字段声明在 BenchOptions（Swift 不允许 extension 里加存储属性）：
//   indexDatabasePath: String?   --index-db
//   requireCheckpointedWAL: Bool --require-checkpointed-wal

enum IndexPerfError: Error, CustomStringConvertible {
    case needsIndexDB
    case indexDBMissing(String)
    case uncheckpointedWAL(bytes: Int64, path: String)
    case mutuallyExclusive(String)

    var description: String {
        switch self {
        case .needsIndexDB:
            return "索引只读模式缺少 --index-db（要测的本机索引数据库路径）"
        case .indexDBMissing(let path):
            return "索引数据库不存在：\(path)"
        case .uncheckpointedWAL(let bytes, let path):
            return """
            拒绝执行：索引存在未 checkpoint 的 WAL（\(bytes) 字节）
              \(path)
            带 WAL 的库在只读打开时会把这些帧一并读进来，读到的内容与「已 checkpoint」的库不是同一状态，
            跨次运行对比就不可靠。请先正常退出一次应用让它完成 checkpoint 后重跑；
            若确实需要测带 WAL 的状态，不加 --require-checkpointed-wal 即可，
            报告会如实标注 walPresent / walBytes / checkpointedBeforeRun
            （注意 checkpointedBeforeRun 为 true 只代表本次测量前没看到 WAL，不代表当时没有别的进程在写）。
            """
        case .mutuallyExclusive(let detail):
            return "索引只读模式不与其他模式混跑：\(detail)"
        }
    }
}

// MARK: - WAL / 文件事实

struct IndexFileFacts: Codable {
    var databaseFileName: String
    var databaseBytes: Int64
    var walPresent: Bool
    var walBytes: Int64
    var shmPresent: Bool
    /// 是否在测量开始前已确认没有未 checkpoint 的 WAL。
    var checkpointedBeforeRun: Bool
    var note: String
}

enum IndexFileInspection {
    static func facts(for url: URL) -> IndexFileFacts {
        let walURL = URL(fileURLWithPath: url.path + "-wal", isDirectory: false)
        let shmURL = URL(fileURLWithPath: url.path + "-shm", isDirectory: false)
        let walBytes = byteSize(walURL)
        let shmBytes = byteSize(shmURL)
        return IndexFileFacts(
            databaseFileName: url.lastPathComponent,
            databaseBytes: byteSize(url),
            walPresent: FileManager.default.fileExists(atPath: walURL.path),
            walBytes: walBytes,
            shmPresent: FileManager.default.fileExists(atPath: shmURL.path),
            checkpointedBeforeRun: walBytes == 0,
            note: """
            只读连接不会改写主库文件，但在 WAL 存在时会把这些帧读进来，
            因此 walBytes > 0 时本次读到的状态包含未 checkpoint 的改动；跨次对比前请先 checkpoint。
            反过来，walBytes == 0 也**不能证明**当前没有别的进程在写：这个数字只是瞬时观察，
            不能替代「无并发写入者」这一前提。要真的只读且不碰旁件，只能用 immutable 打开，
            而 immutable 要求调用方静态保证无并发写入者。
            """
        )
    }

    static func byteSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func uncheckedWAL(for url: URL) throws -> (bytes: Int64, path: String)? {
        let walURL = URL(fileURLWithPath: url.path + "-wal", isDirectory: false)
        let bytes = byteSize(walURL)
        guard bytes > 0 else { return nil }
        return (bytes, walURL.path)
    }
}

// MARK: - 报告

struct IndexPerfStages: Codable {
    var openMs: Double
    var countMs: Double
    var decodeMs: Double
    var engineBuildMs: Double
}

struct IndexPerfQueryStat: Codable {
    var id: String
    var label: String
    var text: String
    var hitCount: Int
    /// 多次运行的命中数必须恒定；这里记 min/max，用于暴露不稳定。
    var minHitCount: Int
    var maxHitCount: Int
    var samples: Int
    var minMs: Double
    var p50Ms: Double
    var p95Ms: Double
    var maxMs: Double
    var firstObservedMs: Double
    var keysStableAcrossRuns: Bool
}

struct IndexPerfSortStat: Codable {
    var sort: String
    var ascending: Bool
    var hitCount: Int
    var elapsedMs: Double
    /// 同一条件下两次运行的键序列是否完全一致（用序列指纹比较）。
    var sequenceStableAcrossRuns: Bool
}

struct IndexPerfCancelStat: Codable {
    var immediateMs: Double
    var immediateIsCancelled: Bool
    var immediateKeyCount: Int
    var uncancelledHitCount: Int
    var uncancelledMs: Double
    var sweep: [CancelProbeStat]
}

struct IndexPerfReport: Codable {
    var schemaVersion: Int
    var generatedAtUTC: String
    var mode: String
    var file: IndexFileFacts
    var entryCountReported: Int
    var generation: UInt64
    var volumeCount: Int
    var integrityCheck: String
    var stages: IndexPerfStages
    var queries: [IndexPerfQueryStat]
    var sorts: [IndexPerfSortStat]
    var cancel: IndexPerfCancelStat
    var memory: MemoryStat
    var selfCheckFailures: [String]
    var notes: [String]
}

// MARK: - 运行器

enum IndexPerfRunner {

    static func isIndexMode(_ options: BenchOptions) -> Bool {
        options.indexDatabasePath != nil
    }

    static func run(options: BenchOptions) async throws -> Int32 {
        let databaseURL = try resolveDatabaseURL(options)
        try checkNoOtherPhases(options)

        // —— WAL 闸：只要调用方要求"确认过的干净状态"，未 checkpoint 就拒绕 ——
        let facts = IndexFileInspection.facts(for: databaseURL)
        if options.requireCheckpointedWAL, let unchecked = try IndexFileInspection.uncheckedWAL(for: databaseURL) {
            throw IndexPerfError.uncheckpointedWAL(bytes: unchecked.bytes, path: unchecked.path)
        }

        var failures: [String] = []
        FileHandle.standardError.write(Data("""
        索引只读性能测量
        数据库文件：\(databaseURL.lastPathComponent)（完整路径：\(databaseURL.path)）
        大小：\(facts.databaseBytes) 字节；WAL：\(facts.walPresent ? "\(facts.walBytes) 字节" : "无")
        严格只读打开：不写主库文件、不 checkpoint、不复制文件（WAL 旁件可能被 SQLite 维护）。

        """.utf8))

        // —— 阶段 1：只读打开 ——
        let openStart = BenchClock.now()
        let reader = try CatalogReader(databaseURL: databaseURL)
        let openMs = BenchClock.milliseconds(since: openStart)
        if !reader.isReadOnly {
            failures.append("连接未处于只读状态，拒绝采信本次测量")
        }

        // —— 阶段 2：计数（不加 volume 过滤，利用覆盖索引）——
        let countStart = BenchClock.now()
        let reportedCount = try reader.entryCount()
        let countMs = BenchClock.milliseconds(since: countStart)

        // —— 阶段 3：读取 + 解码成条目 ——
        let decodeStart = BenchClock.now()
        let entries = try reader.entries()
        let decodeMs = BenchClock.milliseconds(since: decodeStart)

        if entries.count != reportedCount {
            failures.append("COUNT(*) 与实际读出行数不一致：\(reportedCount) vs \(entries.count)")
        }

        let generation = try reader.generation()
        let volumes = try reader.volumes()
        let integrity = try reader.checkIntegrity(full: false)
        if integrity != "ok" {
            failures.append("PRAGMA quick_check 返回 \(integrity)")
        }

        let snapshot = CatalogSnapshot(generation: generation, entries: entries, volumes: volumes)

        // —— 阶段 4：引擎构建（归一化匹配键缓存）——
        let engineStart = BenchClock.now()
        let engine = SearchEngine(snapshot: snapshot)
        let engineBuildMs = BenchClock.milliseconds(since: engineStart)

        let repeats = max(5, options.repeats)

        // —— 查询：命中数必须逐次恒定 ——
        let queryStats = runQueries(engine: engine, repeats: repeats)
        for stat in queryStats {
            if stat.minHitCount != stat.maxHitCount {
                failures.append("查询「\(stat.text)」的命中数在多次运行间不稳定：\(stat.minHitCount)…\(stat.maxHitCount)")
            }
            if !stat.keysStableAcrossRuns {
                failures.append("查询「\(stat.text)」的键序列在多次运行间不一致")
            }
        }

        // —— 排序：每个排序键 × 方向跑两次，序列指纹必须一致 ——
        let sortStats = runSortStability(engine: engine)
        for stat in sortStats where !stat.sequenceStableAcrossRuns {
            failures.append("sort=\(stat.sort) \(stat.ascending ? "升序" : "降序") 的键序列在两次运行间不一致")
        }

        // —— 取消 ——
        let cancelStat = runCancelChecks(engine: engine)
        if !cancelStat.immediateIsCancelled {
            failures.append("立即取消时结果未标记 isCancelled")
        }
        if cancelStat.immediateKeyCount != 0 {
            failures.append("立即取消时仍返回了 \(cancelStat.immediateKeyCount) 条半截结果")
        }
        if cancelStat.uncancelledHitCount == 0 {
            failures.append("取消自检的对照查询命中 0 条，自检无意义")
        }
        for probe in cancelStat.sweep where probe.isCancelled && probe.keyCount != 0 {
            failures.append("取消探测（\(probe.checksBeforeCancel) 次检查后取消）返回了 \(probe.keyCount) 条半截结果")
        }

        let peak = BenchClock.peakResidentBytes()
        let report = IndexPerfReport(
            schemaVersion: 1,
            generatedAtUTC: ISO8601DateFormatter().string(from: Date()),
            mode: "index-readonly",
            file: facts,
            entryCountReported: reportedCount,
            generation: generation,
            volumeCount: volumes.count,
            integrityCheck: integrity,
            stages: IndexPerfStages(
                openMs: RealScanRunner.round3(openMs),
                countMs: RealScanRunner.round3(countMs),
                decodeMs: RealScanRunner.round3(decodeMs),
                engineBuildMs: RealScanRunner.round3(engineBuildMs)
            ),
            queries: queryStats,
            sorts: sortStats,
            cancel: cancelStat,
            memory: MemoryStat(
                peakResidentBytes: peak,
                peakResidentMB: RealScanRunner.round3(Double(peak) / 1_048_576)
            ),
            selfCheckFailures: failures,
            notes: [
                """
                分阶段计时：打开 / 计数 / 读取解码 / 引擎构建各自独立。
                读取解码把百万行变成内存里的 IndexedEntry，是启动准备时间的主要来源。
                """,
                """
                本模式不写主库文件：经 CatalogReader 以 SQLITE_OPEN_READONLY 打开，
                不建表、不写 meta、不 checkpoint、不 vacuum、不改 journal 模式，
                也**不复制**数据库文件。
                这不等于「物理上不具备写入能力」——SQLite 对 WAL 库仍会维护 -wal / -shm 旁件，
                只读连接可能创建或更新它们；immutable 打开才完全不碰旁件，
                但那需要调用方静态保证没有并发写入者，本模式不满足该前提，因此不使用。
                """,
                """
                首观测（first-observed）语义：这些数字是本机当前缓存与 CPU 状态下的观测，
                不是冷缓存保证，也不代表机械盘或外置盘读取速度。
                """,
                "报告只含计数、统计与阶段耗时；数据库只报文件名与字节数，不含完整路径，也不含任何用户文件路径或文件名。"
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(report), as: UTF8.self)

        // 默认只打到 stdout；写文件需要显式 --output（writeReport 不会删任何目录）。
        if let outputPath = options.outputPath {
            try BenchOptions.writeReport(json: json, to: outputPath)
            FileHandle.standardError.write(Data("JSON 已写入 \(outputPath)\n".utf8))
        }
        print(json)

        FileHandle.standardError.write(Data("""
        阶段耗时：打开 \(RealScanRunner.round3(openMs)) ms / 计数 \(RealScanRunner.round3(countMs)) ms /
        读取解码 \(RealScanRunner.round3(decodeMs)) ms / 引擎构建 \(RealScanRunner.round3(engineBuildMs)) ms
        峰值常驻内存：\(RealScanRunner.round3(Double(peak) / 1_048_576)) MB
        自检：\(failures.isEmpty ? "通过" : "失败（\(failures.count) 项）")
        \(failures.joined(separator: "\n"))

        """.utf8))

        return failures.isEmpty ? 0 : 1
    }

    // MARK: 查询

    static func runQueries(engine: SearchEngine, repeats: Int) -> [IndexPerfQueryStat] {
        var stats: [IndexPerfQueryStat] = []
        for queryCase in RealQueryCases.fixed {
            let query = SearchQuery(text: queryCase.text)

            let firstStart = BenchClock.now()
            let firstResult = engine.search(query)
            let firstMs = BenchClock.milliseconds(since: firstStart)
            let referenceFingerprint = sequenceFingerprint(firstResult.keys)
            var referenceCount = firstResult.keys.count

            var samples: [Double] = []
            var minCount = referenceCount
            var maxCount = referenceCount
            var stable = true

            for _ in 0..<repeats {
                let start = BenchClock.now()
                let result = engine.search(query)
                samples.append(BenchClock.milliseconds(since: start))
                minCount = min(minCount, result.keys.count)
                maxCount = max(maxCount, result.keys.count)
                if sequenceFingerprint(result.keys) != referenceFingerprint {
                    stable = false
                }
                referenceCount = result.keys.count
            }

            let summary = Statistics.Summary(samples)
            stats.append(
                IndexPerfQueryStat(
                    id: queryCase.id,
                    label: queryCase.label,
                    text: queryCase.text,
                    hitCount: referenceCount,
                    minHitCount: minCount,
                    maxHitCount: maxCount,
                    samples: summary.samples,
                    minMs: RealScanRunner.round3(summary.minMs),
                    p50Ms: RealScanRunner.round3(summary.p50Ms),
                    p95Ms: RealScanRunner.round3(summary.p95Ms),
                    maxMs: RealScanRunner.round3(summary.maxMs),
                    firstObservedMs: RealScanRunner.round3(firstMs),
                    keysStableAcrossRuns: stable
                )
            )
        }
        return stats
    }

    // MARK: 排序稳定性

    static func runSortStability(engine: SearchEngine) -> [IndexPerfSortStat] {
        var stats: [IndexPerfSortStat] = []
        // 用命中面最宽的一条（空查询）测排序：全量排序才是最容易被不稳定性暴露的形状。
        let query = SearchQuery(text: "")

        for sort in SearchSort.allCases {
            for ascending in [true, false] {
                let shaped = SearchQuery(text: query.text, sort: sort, ascending: ascending)
                let firstStart = BenchClock.now()
                let first = engine.search(shaped)
                let elapsed = BenchClock.milliseconds(since: firstStart)
                let second = engine.search(shaped)

                stats.append(
                    IndexPerfSortStat(
                        sort: sort.rawValue,
                        ascending: ascending,
                        hitCount: first.keys.count,
                        elapsedMs: RealScanRunner.round3(elapsed),
                        sequenceStableAcrossRuns: sequenceFingerprint(first.keys) == sequenceFingerprint(second.keys)
                    )
                )
            }
        }
        return stats
    }

    // MARK: 取消

    static func runCancelChecks(engine: SearchEngine) -> IndexPerfCancelStat {
        let query = SearchQuery(text: "")

        let start = BenchClock.now()
        let immediate = engine.search(query, isCancelled: { true })
        let immediateMs = BenchClock.milliseconds(since: start)

        let referenceStart = BenchClock.now()
        let reference = engine.search(query)
        let referenceMs = BenchClock.milliseconds(since: referenceStart)

        var sweep: [CancelProbeStat] = []
        for threshold in [1, 3, 10, 30, 100, 1_000] {
            let probe = CancelProbe(cancelAfterChecks: threshold)
            let sweepStart = BenchClock.now()
            let result = engine.search(query, isCancelled: probe.closure)
            sweep.append(
                CancelProbeStat(
                    checksBeforeCancel: threshold,
                    isCancelled: result.isCancelled,
                    keyCount: result.keys.count,
                    elapsedMs: RealScanRunner.round3(BenchClock.milliseconds(since: sweepStart))
                )
            )
        }

        return IndexPerfCancelStat(
            immediateMs: RealScanRunner.round3(immediateMs),
            immediateIsCancelled: immediate.isCancelled,
            immediateKeyCount: immediate.keys.count,
            uncancelledHitCount: reference.keys.count,
            uncancelledMs: RealScanRunner.round3(referenceMs),
            sweep: sweep
        )
    }

    // MARK: 键序列指纹

    /// 顺序敏感的 64 位指纹（FNV-1a）。只用于比较是否同一序列，不用于安全用途。
    static func sequenceFingerprint(_ keys: [EntryKey]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ value: UInt64) {
            var v = value
            for _ in 0..<8 {
                hash ^= (v & 0xff)
                hash = hash &* 0x0000_0100_0000_01b3
                v >>= 8
            }
        }
        for key in keys {
            for byte in key.volumeID.utf8 { mix(UInt64(byte)) }
            mix(0)
            mix(UInt64(bitPattern: key.nodeID))
        }
        return hash
    }

    // MARK: 选项校验

    static func resolveDatabaseURL(_ options: BenchOptions) throws -> URL {
        guard let path = options.indexDatabasePath, !path.isEmpty else {
            throw IndexPerfError.needsIndexDB
        }
        let url = URL(fileURLWithPath: path, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw IndexPerfError.indexDBMissing(path)
        }
        return url
    }

    static func checkNoOtherPhases(_ options: BenchOptions) throws {
        if options.persist {
            throw IndexPerfError.mutuallyExclusive("--persist 会新建并写入合成库，不适用于索引只读测量")
        }
        if options.scanFiles > 0 {
            throw IndexPerfError.mutuallyExclusive("--scan-files 会创建真实文件，不适用于索引只读测量")
        }
        if options.count != BenchOptions().count {
            throw IndexPerfError.mutuallyExclusive("--count 是合成数据集规模，索引只读模式不用它")
        }
    }
}
