import Foundation
import SearchCore
import Testing
@testable import SearchIndex

/// `CatalogReader` exists so that reading an index never needs write access. That
/// guarantee is worth pinning: if it ever regressed into a read-write open, every
/// read would take the writer lock away from the scanner and would mutate an index
/// living on a mounted external volume.
@Suite("只读目录读取")
struct CatalogReaderTests {
    private func makeFixture() throws -> TempCatalogFixture {
        try TempCatalogFixture()
    }

    @Test("只读读取与写入读取结果一致")
    func readOnlyMatchesReadWrite() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let volume = makeVolume()
        do {
            let store = try fixture.makeStore()
            try await store.registerVolume(volume)
            try await store.apply(
                DirectoryBatch(
                    volumeID: volume.id, directoryRelativePath: "",
                    entries: [
                        makeEntry("docs", isDirectory: true),
                        makeEntry("docs/a.txt", size: 1),
                        makeEntry("报告/b.pdf", size: 2),
                    ],
                    isComplete: true
                )
            )
        }

        let writer = try fixture.makeStore()
        let expected = try await writer.entries(volumeID: volume.id)

        let reader = try CatalogReader(databaseURL: fixture.databaseURL)
        let actual = try reader.entries(volumeID: volume.id)
        #expect(actual == expected, "两条读路径必须产出逐字节相同的快照")
        let writerGeneration = try await writer.generation()
        #expect(try reader.generation() == writerGeneration)
        #expect(try reader.volumes() == [volume])
        #expect(try reader.entryCount() == 3)
        #expect(reader.isReadOnly)
    }

    @Test("快照可用，且能自检完整性")
    func snapshotAndIntegrity() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let volume = makeVolume()
        let store = try fixture.makeStore()
        try await store.registerVolume(volume)
        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "",
                entries: [makeEntry("x.txt", size: 9)], isComplete: true
            )
        )

        let reader = try CatalogReader(databaseURL: fixture.databaseURL)
        let snapshot = try reader.snapshot()
        // Registering a volume and applying a batch both advance the generation, so
        // capture what the writer actually reached instead of hard-coding a number.
        let expectedGeneration = try await store.generation()
        #expect(snapshot.generation == expectedGeneration)
        #expect(snapshot.entries.map(\.relativePath) == ["x.txt"])
        #expect(snapshot.volumes.count == 1)
        #expect(try reader.checkIntegrity() == "ok")
    }

    @Test("写入完成后重复快照读保持自洽")
    func repeatedSnapshotsAreSelfConsistent() async throws {
        let fixture = try TempCatalogFixture()
        defer { fixture.remove() }

        let volume = makeVolume()
        let store = try fixture.makeStore()
        try await store.registerVolume(volume)
        for round in 0..<6 {
            let name = "round\(round).txt"
            try await store.apply(
                DirectoryBatch(
                    volumeID: volume.id, directoryRelativePath: "",
                    entries: [makeEntry(name, size: Int64(round))], isComplete: false
                )
            )
        }

        // This fixture is quiescent before it is read: every write happens above, so
        // these repeats show a snapshot is *stable*, NOT that it is atomic against a
        // concurrent writer. The interleaving proof — an independent connection
        // committing while a snapshot transaction is open — lives in
        // `SnapshotTransactionTests`; do not read this case as that coverage.
        let reader = try CatalogReader(databaseURL: fixture.databaseURL)
        let expectedGeneration = try await store.generation()
        for _ in 0..<5 {
            let snapshot = try reader.snapshot()
            // Every entry in the snapshot must share the snapshot's generation: a
            // snapshot that straddled an apply would carry rows from a newer
            // generation under an older generation number, or vice versa.
            let sizes = Set(snapshot.entries.map(\.size))
            #expect(sizes == Set(0..<6), "快照内不应出现跨代的行: \(sizes.sorted())")
            #expect(snapshot.entries.count == 6)
            #expect(snapshot.generation == expectedGeneration)
            #expect(snapshot.volumes.map(\.id) == [volume.id])
        }
    }

    @Test("同连接的并发读取不交错")
    func concurrentReadsOnOneReaderAreSerialized() async throws {
        let fixture = try TempCatalogFixture()
        defer { fixture.remove() }

        let volume = makeVolume()
        let store = try fixture.makeStore()
        try await store.registerVolume(volume)
        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "",
                entries: (0..<400).map { makeEntry("f\($0).txt", size: Int64($0)) },
                isComplete: true
            )
        )

        let reader = try CatalogReader(databaseURL: fixture.databaseURL)
        // A copy shares the connection (and therefore the lock) with the original.
        let copy = reader
        let results = await withTaskGroup(of: Int?.self) { group in
            for _ in 0..<8 {
                group.addTask { try? reader.entries(volumeID: volume.id).count }
                group.addTask { try? copy.entries().count }
                group.addTask { try? reader.snapshot().entries.count }
                group.addTask { try? copy.snapshotUnordered().entries.count }
            }
            var counts: [Int?] = []
            for await value in group { counts.append(value) }
            return counts
        }
        #expect(results.allSatisfy { $0 == 400 }, "并发读取必须各自得到完整的 400 行")
        #expect(results.count == 32)
    }

    @Test("只读打开不存在的文件必须失败，而不是创建它")
    func readOnlyNeverCreatesTheFile() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let missing = fixture.directory.appendingPathComponent("does-not-exist.sqlite")
        #expect(throws: CatalogError.self) {
            _ = try CatalogReader(databaseURL: missing)
        }
        #expect(
            !FileManager.default.fileExists(atPath: missing.path),
            "只读打开绝不能把缺失的索引库创建出来"
        )
    }

    @Test("只读读取不会修改文件字节")
    func readOnlyDoesNotMutateTheFile() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let volume = makeVolume()
        let store = try fixture.makeStore()
        try await store.registerVolume(volume)
        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "",
                entries: [makeEntry("k.txt", size: 3)], isComplete: true
            )
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.databaseURL.path)
        let before = attributes[.size] as? Int
        let beforeModification = attributes[.modificationDate] as? Date

        let reader = try CatalogReader(databaseURL: fixture.databaseURL)
        for _ in 0..<5 { _ = try reader.entries() }
        _ = try reader.generation()
        _ = try reader.snapshot()

        let after = try FileManager.default.attributesOfItem(atPath: fixture.databaseURL.path)
        #expect((after[.size] as? Int) == before, "读取不应改变数据库大小")
        #expect((after[.modificationDate] as? Date) == beforeModification, "读取不应修改数据库")
    }
}
