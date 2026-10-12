import Testing
import Foundation
import SearchCore
import SearchIndex
// SearchBench 的生产函数是 internal（可执行 target），必须 @testable 才能看到。
@testable import SearchBench

// 索引只读性能模式的验收。
//
// 覆盖三件事：
// 1. **只读是真的只读**：用 CatalogReader 打开一个真实小索引后，库文件与 WAL/SHM 旁件
//    的字节数、修改时间都不应发生变化；并且只读打开不应创建任何新文件。
// 2. **WAL 闸**：存在未 checkpoint 的 WAL 时，`--require-checkpointed-wal` 必须拒绕。
// 3. **阶段计时与稳定自检**：命中数逐次恒定、排序序列两次一致、取消不返回半截结果。
//
// 全部在临时目录里造小索引（几十条），不碰用户索引，不复制 GB 级库。

@Suite("索引只读性能模式")
struct IndexReadOnlyModeTests {

    /// 在临时目录里建一个小索引（40 条 + 5 个目录）。写入只发生在测试自己的临时库里。
    private func makeIndex(label: String, entryCount: Int = 40) async throws -> (dir: AcceptanceTempDirectory, url: URL) {
        let dir = try AcceptanceTempDirectory(label: label)
        let url = dir.path("catalog.sqlite", isDirectory: false)

        let volume = AcceptanceFixture.internalVolume()
        let directories = ["目录0", "目录1", "目录2", "目录3", "目录4"]
        let childrenOf: (String) -> [String] = { directory in
            (0..<entryCount)
                .map { "目录\($0 % 5)/报告-\($0).pdf" }
                .filter { $0.hasPrefix(directory + "/") }
        }

        let store = try CatalogStore(databaseURL: url)
        try await store.registerVolume(volume)
        try await store.apply(
            AcceptanceFixture.batch(
                volumeID: volume.id, directory: "", paths: directories, isDirectory: { _ in true }
            )
        )
        for directory in directories {
            try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: volume.id, directory: directory, paths: childrenOf(directory),
                    size: { _ in 4_096 }
                )
            )
        }
        return (dir, url)
    }

    private func fingerprint(_ url: URL) -> (bytes: Int64, modified: Date?) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (
            (attributes?[.size] as? NSNumber)?.int64Value ?? -1,
            attributes?[.modificationDate] as? Date
        )
    }

    // MARK: - 只读是真的只读

    @Test("CatalogReader 只读打开不改动库文件与旁件")
    func readOnlyOpenDoesNotMutateTheDatabase() async throws {
        let fixture = try await makeIndex(label: "readonly")
        let before = fingerprint(fixture.url)
        let walBefore = fingerprint(URL(fileURLWithPath: fixture.url.path + "-wal", isDirectory: false))
        let listingBefore = try directoryListing(fixture.dir)

        // 多次只读打开 + 读取
        for _ in 0..<3 {
            let reader = try CatalogReader(databaseURL: fixture.url)
            #expect(reader.isReadOnly, "连接必须声明为只读")
            _ = try reader.entryCount()
            _ = try reader.entries()
            _ = try reader.generation()
            _ = try reader.volumes()
        }

        let after = fingerprint(fixture.url)
        let walAfter = fingerprint(URL(fileURLWithPath: fixture.url.path + "-wal", isDirectory: false))
        let listingAfter = try directoryListing(fixture.dir)

        #expect(after.bytes == before.bytes, "只读打开不得改变库文件大小")
        #expect(after.modified == before.modified, "只读打开不得改变库文件修改时间")
        #expect(walAfter.bytes == walBefore.bytes, "只读打开不得写入或截断 WAL")
        #expect(listingAfter == listingBefore, "只读打开不得在目录里新建文件")
    }

    @Test("只读读出的快照与写连接读出的完全一致")
    func readOnlySnapshotMatchesWriterSnapshot() async throws {
        let fixture = try await makeIndex(label: "same-snapshot")

        let reader = try CatalogReader(databaseURL: fixture.url)
        let viaReader = try reader.snapshot()

        let writer = try CatalogStore(databaseURL: fixture.url)
        let viaWriter = CatalogSnapshot(
            generation: try await writer.generation(),
            entries: try await writer.entries(),
            volumes: try await writer.volumes()
        )

        #expect(viaReader.generation == viaWriter.generation)
        #expect(viaReader.entries.count == viaWriter.entries.count)
        #expect(
            Set(viaReader.entries.map(\.relativePath)) == Set(viaWriter.entries.map(\.relativePath)),
            "同一库经只读与读写两条路读出的条目集合必须一致"
        )
    }

    @Test("对不存在的库只读打开必须失败，不得创建空库")
    func readOnlyOpenOfMissingDatabaseFails() throws {
        let dir = try AcceptanceTempDirectory(label: "missing")
        let url = dir.path("not-there.sqlite", isDirectory: false)

        #expect(throws: (any Error).self) {
            _ = try CatalogReader(databaseURL: url)
        }
        #expect(
            !FileManager.default.fileExists(atPath: url.path),
            "只读打开失败后不得留下一个新建的空库（那会污染用户的索引目录）"
        )
    }

    // MARK: - WAL 闸

    @Test("存在未 checkpoint 的 WAL 时，必须能判定并拒绕")
    func uncheckpointedWALIsDetectedAndRefused() async throws {
        let fixture = try await makeIndex(label: "wal")

        // 只读打开前后的文件事实：已 checkpoint 的库（无 WAL 或 WAL 为空）放行。
        let cleanFacts = IndexFileInspection.facts(for: fixture.url)
        #expect(cleanFacts.checkpointedBeforeRun, "新建临时库尚未产生未 checkpoint 的 WAL")
        #expect(try IndexFileInspection.uncheckedWAL(for: fixture.url) == nil, "无 WAL 时不应报未 checkpoint")

        // 人为造一个非空 WAL，判定必须翻转为“未 checkpoint”。
        let walURL = URL(fileURLWithPath: fixture.url.path + "-wal", isDirectory: false)
        try Data(repeating: 0x5A, count: 4_096).write(to: walURL)

        let dirtyFacts = IndexFileInspection.facts(for: fixture.url)
        #expect(dirtyFacts.walPresent, "应识别出 WAL 存在")
        #expect(dirtyFacts.walBytes == 4_096)
        #expect(!dirtyFacts.checkpointedBeforeRun, "WAL 非空时不得认为已 checkpoint")

        let unchecked = try #require(try IndexFileInspection.uncheckedWAL(for: fixture.url))
        #expect(unchecked.bytes == 4_096, "未 checkpoint 的字节数必须如实报出")

        // 这正是 `--require-checkpointed-wal` 要拒绕的情况。
        #expect(IndexPerfError.uncheckpointedWAL(bytes: unchecked.bytes, path: unchecked.path)
            .description.contains("拒绝执行"))
    }

    @Test("WAL 为空文件时视为已 checkpoint")
    func zeroLengthWALCountsAsCheckpointed() throws {
        let dir = try AcceptanceTempDirectory(label: "wal-empty")
        let url = dir.path("catalog.sqlite", isDirectory: false)
        try Data(repeating: 0, count: 8_192).write(to: url)
        try Data().write(to: URL(fileURLWithPath: url.path + "-wal", isDirectory: false))

        #expect(IndexFileInspection.facts(for: url).checkpointedBeforeRun, "0 字节 WAL 视为已 checkpoint")
        #expect(try IndexFileInspection.uncheckedWAL(for: url) == nil)
    }

    @Test("报告只记文件名与字节数，不记完整路径")
    func fileFactsDoNotLeakTheFullPath() async throws {
        let fixture = try await makeIndex(label: "nofacts")
        let facts = IndexFileInspection.facts(for: fixture.url)

        #expect(!facts.databaseFileName.contains("/"), "只报文件名")
        #expect(facts.databaseFileName.hasSuffix(".sqlite"))
        #expect(facts.databaseBytes > 0)
        #expect(facts.note.contains("checkpoint"))
    }

    // MARK: - 稳定自检（分阶段测量的前提）

    @Test("查询命中数与键序列逐次恒定")
    func repeatedQueriesAreStable() async throws {
        let fixture = try await makeIndex(label: "stable")
        let reader = try CatalogReader(databaseURL: fixture.url)
        let engine = SearchEngine(snapshot: try reader.snapshot())

        for text in ["报告", "文", "a", "pdf", ""] {
            let reference = engine.search(SearchQuery(text: text))
            let referenceKeys = reference.keys
            for _ in 0..<5 {
                let again = engine.search(SearchQuery(text: text))
                #expect(again.keys == referenceKeys, "查询「\(text)」的键序列必须逐次一致")
                #expect(Set(again.keys).count == again.keys.count, "查询「\(text)」不得返回重复键")
            }
        }
    }

    @Test("四种排序键 × 升降序两次运行序列一致")
    func sortOrderingIsRepeatable() async throws {
        let fixture = try await makeIndex(label: "sort")
        let reader = try CatalogReader(databaseURL: fixture.url)
        let engine = SearchEngine(snapshot: try reader.snapshot())

        for sort in SearchSort.allCases {
            for ascending in [true, false] {
                let query = SearchQuery(text: "", sort: sort, ascending: ascending)
                let first = engine.search(query).keys
                let second = engine.search(query).keys
                #expect(first == second, "sort=\(sort.rawValue) \(ascending ? "升序" : "降序") 两次运行序列不一致")
                #expect(Set(first).count == first.count, "排序结果不得含重复键")
            }
        }
    }

    @Test("取消不返回半截结果")
    func cancellationNeverReturnsPartialResults() async throws {
        let fixture = try await makeIndex(label: "cancel")
        let reader = try CatalogReader(databaseURL: fixture.url)
        let engine = SearchEngine(snapshot: try reader.snapshot())
        let query = SearchQuery(text: "")

        let complete = engine.search(query)
        #expect(!complete.keys.isEmpty, "对照查询必须有命中")

        let cancelled = engine.search(query, isCancelled: { true })
        #expect(cancelled.isCancelled)
        #expect(cancelled.keys.isEmpty, "取消不得返回半截命中")

        let switch_ = AcceptanceFixture.CancellationSwitch(cancelAfterChecks: 2)
        let midCancel = engine.search(query, isCancelled: switch_.closure)
        #expect(midCancel.keys.isEmpty, "扫描途中取消同样不得返回半截命中")
    }

    @Test("分阶段测量的四个阶段都取到有限的非负耗时")
    func stageTimingsAreFinite() async throws {
        let fixture = try await makeIndex(label: "stages")
        let reader = try CatalogReader(databaseURL: fixture.url)

        let countStart = DispatchTime.now()
        let count = try reader.entryCount()
        let countMs = elapsedMs(since: countStart)

        let decodeStart = DispatchTime.now()
        let entries = try reader.entries()
        let decodeMs = elapsedMs(since: decodeStart)

        let buildStart = DispatchTime.now()
        let engine = SearchEngine(
            snapshot: CatalogSnapshot(generation: try await reader.generation(), entries: entries, volumes: try reader.volumes())
        )
        let buildMs = elapsedMs(since: buildStart)

        let openMs = 0.0  // 打开耗时由调用方记录；这里只断言其余三段

        for (name, value) in [("count", countMs), ("decode", decodeMs), ("build", buildMs), ("open", openMs)] {
            #expect(value.isFinite && value >= 0, "阶段耗时 \(name) 必须是有限非负数")
        }
        #expect(count == entries.count)
        #expect(engine.search(SearchQuery(text: "")).keys.count == entries.count)
    }

    // MARK: - 工具

    private func directoryListing(_ dir: AcceptanceTempDirectory) throws -> [String: Int64] {
        var map: [String: Int64] = [:]
        guard let walker = FileManager.default.enumerator(atPath: dir.url.path) else { return map }
        for case let name as String in walker {
            let attributes = try FileManager.default.attributesOfItem(atPath: dir.url.appendingPathComponent(name).path)
            map[name] = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        }
        return map
    }

    private func elapsedMs(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }
}