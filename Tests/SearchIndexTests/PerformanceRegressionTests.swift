import Foundation
import SearchCore
import Testing
@testable import SearchIndex

@Suite("性能优化保持搜索语义")
struct PerformanceRegressionTests {
    private func entry(_ name: String, id: Int64, volume: String = "v", size: Int64 = 0) -> IndexedEntry {
        IndexedEntry(key: EntryKey(volumeID: volume, nodeID: id), relativePath: name,
                     name: name, size: size, modifiedAt: Date(timeIntervalSince1970: 0))
    }

    @Test("独立卷数据库可以复用节点编号")
    func repeatedNodeIDAcrossVolumesRemainsDistinct() {
        let values = [entry("same.txt", id: 1, volume: "a"), entry("same.txt", id: 1, volume: "b")]
        let engine = SearchEngine(snapshot: .init(generation: 1, entries: values, volumes: []))
        #expect(engine.search(.init()).keys == values.map(\.key))
    }

    @Test("长短名称在宽查询中仍按名称排序")
    func broadSortKeepsLexicographicOrder() {
        let names = ["a", "aa", "ab", "b", "c"] + (0..<70).map { "z\($0)" }
        let values = names.enumerated().map { entry($0.element, id: Int64($0.offset + 1)) }
        let engine = SearchEngine(snapshot: .init(generation: 1, entries: values, volumes: []))
        let expected = values.sorted { $0.name < $1.name }.map(\.key)
        #expect(engine.search(.init(sort: .name)).keys == expected)
    }

    @Test("相同八字节前缀不改变完整名称比较")
    func narrowSortUsesCompleteKeyBeforeLength() {
        let values = [entry("abcdefghz", id: 1), entry("abcdefghay", id: 2)]
        let engine = SearchEngine(snapshot: .init(generation: 1, entries: values, volumes: []))
        #expect(engine.search(.init(text: "abcdefgh", sort: .name)).keys == [values[1].key, values[0].key])
    }

    @Test("文件大小排序保持 Int64 精度")
    func sizeSortDoesNotRoundLargeIntegers() {
        let values = [entry("large", id: 1, size: 9_007_199_254_740_993),
                      entry("small", id: 2, size: 9_007_199_254_740_992)]
        let engine = SearchEngine(snapshot: .init(generation: 1, entries: values, volumes: []))
        #expect(engine.search(.init(sort: .size)).keys == [values[1].key, values[0].key])
    }
}

@Suite("静态索引读取安全回归")
struct ImmutableReaderRegressionTests {
    private func createCheckpointedFixture(at url: URL) throws {
        let writer = try SQLiteConnection(url: url)
        try writer.run("CREATE TABLE fixture(value INTEGER);")
        try writer.run("INSERT INTO fixture VALUES (42);")
        try writer.run("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    @Test("非空真实 WAL 必须拒绝 immutable 模式")
    func pendingWALIsRejected() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("catalog.sqlite")
        let writer = try SQLiteConnection(url: url)
        try writer.run("CREATE TABLE fixture(value INTEGER);")
        try writer.run("INSERT INTO fixture VALUES (42);")
        let wal = URL(fileURLWithPath: url.path + "-wal")
        let size = try FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? NSNumber
        #expect((size?.intValue ?? 0) > 0)
        #expect(!SQLiteConnection.isStaticImmutableSafe(databaseURL: url))
        #expect(throws: (any Error).self) {
            _ = try CatalogReader(databaseURL: url, staticImmutable: true)
        }
        withExtendedLifetime(writer) {}
    }

    @Test("immutable 读取特殊字符路径且不生成 WAL 或 SHM")
    func immutableReadDoesNotCreateSidecars() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("索引 #?.sqlite")
        try createCheckpointedFixture(at: url)
        // 只清理本测试已 checkpoint 的临时库旁件，让断言直接检验读取器是否新建旁件。
        let wal = URL(fileURLWithPath: url.path + "-wal")
        if FileManager.default.fileExists(atPath: wal.path) {
            let size = try FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? NSNumber
            try #require(size?.intValue == 0)
            try FileManager.default.removeItem(at: wal)
        }
        let shm = URL(fileURLWithPath: url.path + "-shm")
        if FileManager.default.fileExists(atPath: shm.path) {
            try FileManager.default.removeItem(at: shm)
        }
        for suffix in ["-wal", "-shm"] {
            #expect(!FileManager.default.fileExists(atPath: url.path + suffix))
        }
        let reader = try SQLiteConnection(url: url, access: .staticImmutable)
        #expect(try reader.query("SELECT value FROM fixture;").first?.int64(at: 0) == 42)
        for suffix in ["-wal", "-shm"] {
            #expect(!FileManager.default.fileExists(atPath: url.path + suffix))
        }
        withExtendedLifetime(reader) {}
    }
}
