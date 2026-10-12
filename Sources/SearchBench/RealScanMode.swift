import Foundation
import Darwin
import SearchCore
import SearchIndex
import SearchScanner

// 真实盘只读验收路线（与合成基准完全分离的第二条管线）。
//
// 用法：SearchBench --real-root "/Volumes/某盘" --report-dir ~/.local/share/maceverything/bench [--verify-pass]
//
// 边界（代码层面保证，不靠自觉）：
// * 全程只读：不创建/修改/删除扫描根下的任何文件，不读文件内容，不改系统设置。
// * 索引只写 --report-dir，并用 st_dev + 卷 UUID 双重校验确认不在扫描卷上，否则拒绕执行。
// * 索引库名带时间戳 + UUID，且已存在就拒绕，绝不覆盖任何已有库。
// * 报告 JSON 只有计数、统计与卷事实，不含用户文件路径明细；键（卷 ID + 节点 ID）只留在内存里做自检。
// * 单线程扫描：DirectoryScanner 本身即单任务串行，这里不再并发开第二条扫描。

// 真实盘模式的三个新字段（realRootPath / reportDirPath / verifyPass）
// 直接声明在 BenchOptions 里——Swift 不允许在 extension 中加存储属性。

enum RealScanError: Error, CustomStringConvertible {
    case needsRealRoot
    case needsReportDir
    case mutuallyExclusive(String)
    case safetyRefused(String)
    case rootUnavailable(String)

    var description: String {
        switch self {
        case .needsRealRoot:
            return "真实盘模式缺少 --real-root（要只读扫描的根目录）"
        case .needsReportDir:
            return "真实盘模式缺少 --report-dir（索引与报告的本机落盘目录）"
        case .mutuallyExclusive(let detail):
            return "真实盘模式不与合成阶段混跑：\(detail)。请分开跑。"
        case .safetyRefused(let detail):
            return detail
        case .rootUnavailable(let detail):
            return detail
        }
    }
}

// MARK: - 报告结构（只含计数 / 统计 / 卷事实）

struct RealVolumeFact: Codable {
    var volumeUUID: String?
    var fileSystem: String
    var isOnline: Bool
    var requiresFullVerification: Bool
    var scanRootDeviceIDHex: String
    var reportDirDeviceIDHex: String
    /// allowed / sameDeviceAsScanRoot / identityUnavailable
    var reportLocationDecision: String
}

struct RealScanPhase: Codable {
    var firstPassMs: Double
    var directoriesScanned: Int
    var entriesSeen: Int
    var completeBatches: Int
    var failedBatches: Int
    var rowsApplied: Int
    var progressIntervalSeconds: Double
    var progressLinesEmitted: Int
    var scanReturnedNormally: Bool
}

struct RealQueryStat: Codable {
    var id: String
    var label: String
    var text: String
    var hitCount: Int
    var samples: Int
    var minMs: Double
    var p50Ms: Double
    var p95Ms: Double
    var maxMs: Double
    var firstObservedMs: Double
}

struct RealCancelStat: Codable {
    var immediateMs: Double
    var immediateIsCancelled: Bool
    var immediateKeyCount: Int
    var uncancelledHitCount: Int
    var uncancelledMs: Double
    var sweep: [CancelProbeStat]
}

struct RealReopenStat: Codable {
    var entryCountBeforeReopen: Int
    var entryCountAfterReopen: Int
    var reopenLoadMs: Double
    var engineBuildMsAfterReopen: Double
    var queriesMatchAfterReopen: Bool
    var duplicatedKeysFound: Bool
}

struct RealVerifyStat: Codable {
    var ran: Bool
    var secondPassMs: Double
    var added: Int
    var removed: Int
    var changed: Int
    var unchanged: Int
    var totalChanges: Int
    var note: String
}

struct RealScanReport: Codable {
    var schemaVersion: Int
    var generatedAtUTC: String
    var mode: String
    var volume: RealVolumeFact
    var scan: RealScanPhase
    var indexDatabasePath: String
    var reportFilePath: String
    var engineBuildMs: Double
    var engineEntryCount: Int
    var generation: UInt64
    var queries: [RealQueryStat]
    var cancel: RealCancelStat
    var reopen: RealReopenStat
    var verify: RealVerifyStat
    var memory: MemoryStat
    var selfCheckFailures: [String]
    var notes: [String]
}

// MARK: - 运行器

enum RealScanRunner {

    /// 进度打印间隔：5 秒，只打累计计数，不打任何用户文件名。
    static let progressInterval: Double = 5

    static func isRealMode(_ options: BenchOptions) -> Bool {
        options.realRootPath != nil || options.reportDirPath != nil || options.verifyPass
    }

    static func run(options: BenchOptions) async throws -> Int32 {
        let realRootPath = try requireRealRoot(options)
        let reportDirectory = try requireReportDir(options)
        try checkNoSyntheticPhases(options)

        // —— 安全闸：索引必须落在与扫描根不同的设备上 ——
        let scanDevice = VolumeIdentity.deviceID(ofPath: realRootPath)
        let reportAncestor = existingAncestor(of: reportDirectory)
        let reportDevice = VolumeIdentity.deviceID(ofPath: reportAncestor.path)
        let decision = ReportLocationSafety.decide(
            scanRootDeviceID: scanDevice,
            reportDirDeviceID: reportDevice,
            scanRootVolumeUUID: VolumeIdentity.volumeUUID(ofPath: realRootPath),
            reportDirVolumeUUID: VolumeIdentity.volumeUUID(ofPath: reportAncestor.path)
        )
        guard decision.isAllowed else {
            throw RealScanError.safetyRefused(decision.message)
        }

        try LocalIndexCapacity.ensureAvailable(at: reportAncestor, minimum: 2 * 1_024 * 1_024 * 1_024)
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)

        // —— 索引库：新建，绝不覆盖已有库 ——
        let stamp = timestamp()
        let suffix = String(UUID().uuidString.prefix(8))
        let databaseURL = reportDirectory
            .appendingPathComponent("real-index-\(stamp)-\(suffix).sqlite", isDirectory: false)
        for path in [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"] {
            guard !FileManager.default.fileExists(atPath: path) else {
                throw RealScanError.safetyRefused("索引库已存在，拒绝覆盖：\(path)")
            }
        }

        let volume = VolumeDiscovery.describe(
            rootURL: URL(fileURLWithPath: realRootPath, isDirectory: true),
            id: "real-\(stamp)-\(suffix)"
        )
        guard volume.isOnline else {
            throw RealScanError.rootUnavailable("""
            扫描根当前不可读（可能未挂载或无权限）：\(realRootPath)
            按只读要求，本工具不会尝试挂载、改权限或改系统设置。请确认盘已挂载后重跑。
            """)
        }

        var failures: [String] = []
        FileHandle.standardError.write(Data((Wording.safetyNote + "\n\n").utf8))
        FileHandle.standardError.write(Data("""
        卷：\(volume.name)（\(volume.fileSystem)）
        卷 UUID：\(volume.volumeUUID ?? "无法确定")
        扫描根设备：\(hex(scanDevice))　报告目录设备：\(hex(reportDevice))　判定：\(decision)
        索引库：\(databaseURL.path)
        开始只读首扫（单线程，只读目录元数据）…

        """.utf8))

        // —— 第一遍：完整扫描 + 逐目录入库 ——
        let store = try CatalogStore(databaseURL: databaseURL)
        try await store.registerVolume(volume)

        let firstFingerprints = options.verifyPass ? ScanFingerprintMap() : nil
        let firstPass = try await runPass(
            volume: volume,
            applyTo: store,
            fingerprints: firstFingerprints,
            indexDirectory: reportDirectory
        )

        let firstPassLabel = firstPass.completed && firstPass.failedBatches == 0 ? "首扫完成" : "首扫未完整完成"
        FileHandle.standardError.write(Data("""
        \(firstPassLabel)：耗时 \(seconds(firstPass.elapsedMs)) s，目录 \(firstPass.directoriesScanned)，条目 \(firstPass.entriesSeen)，完整批次 \(firstPass.completeBatches)，失败批次 \(firstPass.failedBatches)，已写索引行 \(firstPass.rowsApplied)

        """.utf8))

        let entriesBeforeReopen = try await store.entries()
        let entryCount = entriesBeforeReopen.count
        let generation = try await store.generation()

        // Stop immediately on incomplete scans. Do not construct large caches or
        // continue testing an index that has not been fully built.
        if !firstPass.completed || firstPass.failedBatches > 0 {
            throw RealScanError.safetyRefused("首扫未完整完成，保留部分本机索引；不运行查询或校验遍，也不标为通过。")
        }

        // —— 引擎构建 ——
        let snapshot = CatalogSnapshot(
            generation: generation,
            entries: entriesBeforeReopen,
            volumes: try await store.volumes()
        )
        let engineStart = BenchClock.now()
        let engine = SearchEngine(snapshot: snapshot)
        let engineBuildMs = BenchClock.milliseconds(since: engineStart)

        // —— 固定查询：每条至少 5 次 ——
        let repeats = max(5, options.repeats)
        let runs = runQueries(engine: engine, repeats: repeats)
        if !firstPass.completed { failures.append("首扫提前结束，结果不完整") }
        if firstPass.failedBatches > 0 { failures.append("首扫存在不完整批次，部分范围尚未校验") }
        if firstPass.rowsApplied != entryCount { failures.append("枚举条目数与入库条目数不一致") }

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

        // —— 重开数据库：条目数 + 同查询同键序列自检 ——
        let reopen = try await runReopenChecks(
            databaseURL: databaseURL,
            expectedCount: entryCount,
            runs: runs
        )
        failures.append(contentsOf: reopen.failures)

        // —— 可选：第二遍纯元数据扫描 ——
        let verify: RealVerifyStat
        if options.verifyPass {
            FileHandle.standardError.write(Data("\n开始第二遍纯元数据扫描并与第一遍逐项比较…\n".utf8))
            let secondFingerprints = ScanFingerprintMap()
            let secondPass = try await runPass(volume: volume, applyTo: nil, fingerprints: secondFingerprints)
            if !secondPass.completed || secondPass.failedBatches > 0 {
                failures.append("校验遍未完整完成，不能声称全树已验证")
            }
            let diff = VerifyPass.diff(
                first: firstFingerprints?.snapshot() ?? [:],
                second: secondFingerprints.snapshot()
            )
            verify = RealVerifyStat(
                ran: true,
                secondPassMs: round3(secondPass.elapsedMs),
                added: diff.added,
                removed: diff.removed,
                changed: diff.changed,
                unchanged: diff.unchanged,
                totalChanges: diff.totalChanges,
                note: Wording.verifyPassNote
            )
            FileHandle.standardError.write(Data("""
            校验遍完成：耗时 \(seconds(secondPass.elapsedMs)) s，实际变更 \(diff.totalChanges) 项（新增 \(diff.added) / 消失 \(diff.removed) / 变化 \(diff.changed) / 未变 \(diff.unchanged)）
            盘上有并发改动时该数字非零是正常现象，不代表算法失败。

            """.utf8))
            // 变更数是事实，不进 selfCheckFailures。
        } else {
            verify = RealVerifyStat(
                ran: false, secondPassMs: 0, added: 0, removed: 0, changed: 0, unchanged: 0,
                totalChanges: 0, note: "未启用（加 --verify-pass 跑第二遍纯元数据扫描）"
            )
        }

        // —— 写报告 ——
        let reportURL = reportDirectory
            .appendingPathComponent("real-scan-\(stamp)-\(suffix).json", isDirectory: false)
        let peak = BenchClock.peakResidentBytes()
        let report = RealScanReport(
            schemaVersion: 1,
            generatedAtUTC: ISO8601DateFormatter().string(from: Date()),
            mode: "real-readonly",
            volume: RealVolumeFact(
                volumeUUID: volume.volumeUUID,
                fileSystem: volume.fileSystem,
                isOnline: volume.isOnline,
                requiresFullVerification: volume.requiresFullVerification,
                scanRootDeviceIDHex: hex(scanDevice),
                reportDirDeviceIDHex: hex(reportDevice),
                reportLocationDecision: "\(decision)"
            ),
            scan: RealScanPhase(
                firstPassMs: round3(firstPass.elapsedMs),
                directoriesScanned: firstPass.directoriesScanned,
                entriesSeen: firstPass.entriesSeen,
                completeBatches: firstPass.completeBatches,
                failedBatches: firstPass.failedBatches,
                rowsApplied: firstPass.rowsApplied,
                progressIntervalSeconds: progressInterval,
                progressLinesEmitted: firstPass.progressLines,
                scanReturnedNormally: firstPass.completed
            ),
            indexDatabasePath: databaseURL.path,
            reportFilePath: reportURL.path,
            engineBuildMs: round3(engineBuildMs),
            engineEntryCount: snapshot.entries.count,
            generation: generation,
            queries: runs.map(\.stat),
            cancel: cancelStat,
            reopen: reopen.stat,
            verify: verify,
            memory: MemoryStat(peakResidentBytes: peak, peakResidentMB: round3(Double(peak) / 1_048_576)),
            selfCheckFailures: failures,
            notes: [
                Wording.firstPassNote,
                Wording.verifyPassNote,
                Wording.safetyNote,
                "报告只含计数、统计与卷事实；扫描根下的文件路径明细既没进 JSON，也没进终端输出。",
                "首扫耗时包含真实目录元数据读取，不代表冷缓存速度，也不代表机械盘随机寻道性能。"
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(report), as: UTF8.self)
        try Data(json.utf8).write(to: reportURL, options: .atomic)

        FileHandle.standardError.write(Data("""
        索引库（保留，供 GUI 后续使用）：\(databaseURL.path)
        JSON 报告：\(reportURL.path)
        峰值常驻内存：\(report.memory.peakResidentMB) MB
        自检：\(failures.isEmpty ? "通过" : "失败（\(failures.count) 项）")
        \(failures.joined(separator: "\n"))

        """.utf8))

        return failures.isEmpty ? 0 : 1
    }

    // MARK: - 单遍扫描

    struct PassResult {
        var elapsedMs: Double = 0
        var directoriesScanned: Int = 0
        var entriesSeen: Int = 0
        var completeBatches: Int = 0
        var failedBatches: Int = 0
        var rowsApplied: Int = 0
        var progressLines: Int = 0
        var completed: Bool = true
    }

    /// 跑一遍扫描：可选把每目录批次写进 `store`，可选收集指纹用于第二遍比较。
    static func runPass(
        volume: VolumeRecord,
        applyTo store: CatalogStore?,
        fingerprints: ScanFingerprintMap?,
        indexDirectory: URL? = nil
    ) async throws -> PassResult {
        let progress = PassProgress()
        do {
            try await DirectoryScanner().scan(volume: volume, startingAt: [""], recursive: true) { batch in
                if let indexDirectory { try LocalIndexCapacity.ensureAvailable(at: indexDirectory) }
                if let store { _ = try await store.apply(batch) }
                fingerprints?.absorb(batch.entries)
                await progress.record(batch, applied: store != nil)
            }
            return await progress.finish(completed: true)
        } catch {
            // Do not include errors that may contain private user filenames.
            let reason: String
            if let capacity = error as? LocalIndexCapacity.CapacityError {
                reason = capacity.localizedDescription
            } else if let catalog = error as? CatalogError, case .sqlite(let code, let message, _) = catalog.kind {
                reason = "SQLite \(code): \(message)"
            } else {
                let failure = error as NSError
                reason = "\(failure.domain) / \(failure.code)"
            }
            FileHandle.standardError.write(Data("扫描提前结束，范围尚未完整校验：\(reason)\n".utf8))
            return await progress.finish(completed: false)
        }
    }

    private actor PassProgress {
        private var result = PassResult()
        private let start = BenchClock.now()
        private var lastProgress = BenchClock.now()

        func record(_ batch: DirectoryBatch, applied: Bool) {
            result.directoriesScanned += 1
            result.entriesSeen += batch.entries.count
            if batch.isComplete { result.completeBatches += 1 } else { result.failedBatches += 1 }
            if applied { result.rowsApplied += batch.entries.count }
            let now = BenchClock.now()
            if now.uptimeNanoseconds &- lastProgress.uptimeNanoseconds >= UInt64(progressInterval * 1_000_000_000) {
                result.progressLines += 1
                let line = ScanProgress.line(elapsedMs: BenchClock.milliseconds(since: start),
                    directoriesScanned: result.directoriesScanned, entriesSeen: result.entriesSeen,
                    completeBatches: result.completeBatches, failedBatches: result.failedBatches,
                    rowsWritten: result.rowsApplied)
                FileHandle.standardError.write(Data((line + "\n").utf8))
                lastProgress = now
            }
        }

        func finish(completed: Bool) -> PassResult {
            result.elapsedMs = BenchClock.milliseconds(since: start)
            result.completed = completed
            return result
        }
    }

    // MARK: - 查询 / 取消 / 重开

    struct QueryRun {
        var stat: RealQueryStat
        /// 只留在内存里做重开自检，不写进 JSON。
        var keys: [EntryKey]
    }

    static func runQueries(engine: SearchEngine, repeats: Int) -> [QueryRun] {
        var runs: [QueryRun] = []
        for queryCase in RealQueryCases.fixed {
            let query = SearchQuery(text: queryCase.text)

            let firstStart = BenchClock.now()
            let firstResult = engine.search(query)
            let firstMs = BenchClock.milliseconds(since: firstStart)

            var samples: [Double] = []
            var keys = firstResult.keys
            for _ in 0..<repeats {
                let start = BenchClock.now()
                let result = engine.search(query)
                samples.append(BenchClock.milliseconds(since: start))
                keys = result.keys
            }

            let summary = Statistics.Summary(samples)
            runs.append(
                QueryRun(
                    stat: RealQueryStat(
                        id: queryCase.id,
                        label: queryCase.label,
                        text: queryCase.text,
                        hitCount: keys.count,
                        samples: summary.samples,
                        minMs: round3(summary.minMs),
                        p50Ms: round3(summary.p50Ms),
                        p95Ms: round3(summary.p95Ms),
                        maxMs: round3(summary.maxMs),
                        firstObservedMs: round3(firstMs)
                    ),
                    keys: keys
                )
            )
        }
        return runs
    }

    static func runCancelChecks(engine: SearchEngine) -> RealCancelStat {
        // 用命中面最宽的一条（空查询 → 全量）来测取消。
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
                    elapsedMs: round3(BenchClock.milliseconds(since: sweepStart))
                )
            )
        }

        return RealCancelStat(
            immediateMs: round3(immediateMs),
            immediateIsCancelled: immediate.isCancelled,
            immediateKeyCount: immediate.keys.count,
            uncancelledHitCount: reference.keys.count,
            uncancelledMs: round3(referenceMs),
            sweep: sweep
        )
    }

    static func runReopenChecks(
        databaseURL: URL,
        expectedCount: Int,
        runs: [QueryRun]
    ) async throws -> (stat: RealReopenStat, failures: [String]) {
        var failures: [String] = []

        let reopenStart = BenchClock.now()
        let reopened = try CatalogStore(databaseURL: databaseURL)
        let entries = try await reopened.entries()
        let loadMs = BenchClock.milliseconds(since: reopenStart)

        let buildStart = BenchClock.now()
        let engine = SearchEngine(
            snapshot: CatalogSnapshot(
                generation: try await reopened.generation(),
                entries: entries,
                volumes: try await reopened.volumes()
            )
        )
        let buildMs = BenchClock.milliseconds(since: buildStart)

        if entries.count != expectedCount {
            failures.append("重开数据库后条目数不一致：关闭前 \(expectedCount)，重开后 \(entries.count)")
        }

        var allMatch = true
        var duplicated = false
        for run in runs {
            let after = engine.search(SearchQuery(text: run.stat.text))
            if !ResultSelfCheck.sameKeySequence(run.keys, after.keys) {
                allMatch = false
                failures.append(
                    "重开后查询「\(run.stat.text)」的键序列与关闭前不一致："
                    + "关闭前 \(run.keys.count) 条，重开后 \(after.keys.count) 条")
            }
            if ResultSelfCheck.hasDuplicates(after.keys) {
                duplicated = true
                failures.append("重开后查询「\(run.stat.text)」返回了重复键")
            }
        }

        let stat = RealReopenStat(
            entryCountBeforeReopen: expectedCount,
            entryCountAfterReopen: entries.count,
            reopenLoadMs: round3(loadMs),
            engineBuildMsAfterReopen: round3(buildMs),
            queriesMatchAfterReopen: allMatch,
            duplicatedKeysFound: duplicated
        )
        return (stat, failures)
    }

    // MARK: - 选项校验

    static func requireRealRoot(_ options: BenchOptions) throws -> String {
        guard let path = options.realRootPath, !path.isEmpty else {
            throw RealScanError.needsRealRoot
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw RealScanError.rootUnavailable("扫描根不存在或不是目录：\(path)")
        }
        return path
    }

    static func requireReportDir(_ options: BenchOptions) throws -> URL {
        guard let path = options.reportDirPath, !path.isEmpty else {
            throw RealScanError.needsReportDir
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        return url
    }

    static func existingAncestor(of url: URL) -> URL {
        var ancestor = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            ancestor.deleteLastPathComponent()
        }
        return ancestor
    }

    static func checkNoSyntheticPhases(_ options: BenchOptions) throws {
        if options.persist {
            throw RealScanError.mutuallyExclusive("--persist 是合成库阶段，不适用于真实盘只读验收")
        }
        if options.scanFiles > 0 {
            throw RealScanError.mutuallyExclusive("--scan-files 会创建真实文件，不适用于真实盘只读验收")
        }
        if options.count != BenchOptions().count {
            throw RealScanError.mutuallyExclusive("--count 是合成数据集规模，真实盘模式不用它")
        }
    }

    // MARK: - 小工具

    static func hex(_ deviceID: UInt64?) -> String {
        guard let deviceID else { return "无法确定" }
        return "dev:0x" + String(deviceID, radix: 16)
    }

    static func seconds(_ milliseconds: Double) -> String {
        String(format: "%.1f", milliseconds / 1_000)
    }

    static func round3(_ value: Double) -> Double {
        (value * 1_000).rounded() / 1_000
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

/// 指纹收集器：只在 `--verify-pass` 时启用，内存开销与条目数成正比。
final class ScanFingerprintMap: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: EntryFingerprint] = [:]

    func insert(_ path: String, _ fingerprint: EntryFingerprint) {
        lock.lock()
        storage[path] = fingerprint
        lock.unlock()
    }

    func absorb(_ entries: [ScannedEntry]) {
        lock.lock()
        for entry in entries { storage[entry.relativePath] = EntryFingerprint.make(entry) }
        lock.unlock()
    }

    func snapshot() -> [String: EntryFingerprint] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
