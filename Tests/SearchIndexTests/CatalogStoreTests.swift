import Foundation
import SearchCore
import Testing
@testable import SearchIndex

/// Temporary on-disk fixture. Never touches the user's real Application Support
/// directory or any real volume — every test database lives in the system temp dir.
struct TempCatalogFixture {
    let directory: URL
    let databaseURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacEverythingIndexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("catalog.sqlite")
    }

    func makeStore() throws -> CatalogStore {
        try CatalogStore(databaseURL: databaseURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

func makeVolume(_ id: String = "vol-1", name: String = "Test Volume") -> VolumeRecord {
    VolumeRecord(
        id: id,
        name: name,
        rootPath: "/tmp/mac-everything-test-root",
        fileSystem: "apfs",
        volumeUUID: "UUID-\(id)"
    )
}

func makeEntry(
    _ relativePath: String,
    name: String? = nil,
    isDirectory: Bool = false,
    size: Int64 = 0,
    modifiedAt: Date = Date(timeIntervalSinceReferenceDate: 0)
) -> ScannedEntry {
    ScannedEntry(
        relativePath: relativePath,
        name: name ?? ((relativePath as NSString).lastPathComponent),
        isDirectory: isDirectory,
        isSymbolicLink: false,
        size: size,
        modifiedAt: modifiedAt
    )
}

@Suite("CatalogStore 持久化与目录批次语义")
struct CatalogStoreTests {
    @Test("条目与卷信息在重开数据库后保留")
    func entriesAndVolumesSurviveRestart() async throws {
        let fixture = try TempCatalogFixture()
        defer { fixture.remove() }

        let volume = makeVolume()
        let generation: UInt64
        let nodeID: Int64
        do {
            let store = try fixture.makeStore()
            try await store.registerVolume(volume)
            try await store.apply(
                DirectoryBatch(
                    volumeID: volume.id,
                    directoryRelativePath: "",
                    entries: [makeEntry("报告/季度汇总.pdf", size: 42)],
                    isComplete: true
                )
            )
            generation = try await store.generation()
            nodeID = try #require(try await store.entries(volumeID: volume.id).first?.key.nodeID)
        }

        // A brand new connection == the app restarting.
        let reopened = try fixture.makeStore()
        let entries = try await reopened.entries(volumeID: volume.id)
        #expect(entries.count == 1)
        #expect(entries[0].relativePath == "报告/季度汇总.pdf")
        #expect(entries[0].key.nodeID == nodeID)
        #expect(try await reopened.generation() == generation)
        #expect(try await reopened.volumes() == [volume])
    }

    @Test("不完整批次不删除任何旧记录，并把目录标记为待校验")
    func partialBatchNeverDeletesAndMarksDirectoryStale() async throws {
        let fixture = try TempCatalogFixture()
        defer { fixture.remove() }

        let volume = makeVolume()
        let store = try fixture.makeStore()
        try await store.registerVolume(volume)

        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id,
                directoryRelativePath: "",
                entries: [
                    makeEntry("docs", isDirectory: true),
                    makeEntry("docs/a.txt", size: 1),
                    makeEntry("docs/b.txt", size: 2),
                ],
                isComplete: true
            )
        )

        // Permission failure deep in the tree: keep everything, flag for verification.
        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id,
                directoryRelativePath: "docs",
                entries: [makeEntry("docs/a.txt", size: 1)],
                isComplete: false,
                issue: ScanIssue(relativePath: "docs", code: 1, message: "EPERM")
            )
        )

        let all = try await store.entries(volumeID: volume.id)
        #expect(all.map(\.relativePath).sorted() == ["docs", "docs/a.txt", "docs/b.txt"])
        let docs = try #require(all.first { $0.relativePath == "docs" })
        #expect(docs.state == .stale, "errored scan must leave the directory marked for re-verification")
    }

    @Test("完整批次删除缺失子项的整棵子树，且不动根级兄弟")
    func completeBatchDeletesMissingSubtreeButKeepsSiblingPrefix() async throws {
        let fixture = try TempCatalogFixture()
        defer { fixture.remove() }

        let volume = makeVolume()
        let store = try fixture.makeStore()
        try await store.registerVolume(volume)

        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "",
                entries: [makeEntry("a", isDirectory: true), makeEntry("bc.txt")],
                isComplete: true
            )
        )
        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "a",
                entries: [makeEntry("a/b", isDirectory: true)],
                isComplete: true
            )
        )
        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "a/b",
                entries: [makeEntry("a/b/deep.txt")],
                isComplete: true
            )
        )
        #expect(try await store.entryCount(volumeID: volume.id) == 4)

        // "a" is now empty: the whole "a/b" subtree must go with it.
        try await store.apply(
            DirectoryBatch(volumeID: volume.id, directoryRelativePath: "a", entries: [], isComplete: true)
        )
        #expect(try await store.entries(volumeID: volume.id).map(\.relativePath).sorted() == ["a", "bc.txt"])
    }

    @Test("删除 a/b 不会误删 a/bc.txt（禁止裸前缀匹配）")
    func deletingDirectoryDoesNotDeleteShorterPrefixedSibling() async throws {
        let fixture = try TempCatalogFixture()
        defer { fixture.remove() }

        let volume = makeVolume()
        let store = try fixture.makeStore()
        try await store.registerVolume(volume)

        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "",
                entries: [makeEntry("a", isDirectory: true)], isComplete: true
            )
        )
        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "a",
                entries: [makeEntry("a/b", isDirectory: true), makeEntry("a/bc.txt")],
                isComplete: true
            )
        )
        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "a/b",
                entries: [makeEntry("a/b/inner.txt")], isComplete: true
            )
        )

        // "a" still holds "a/bc.txt" — a naive string prefix would have eaten it.
        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "a",
                entries: [makeEntry("a/bc.txt")], isComplete: true
            )
        )
        #expect(try await store.entries(volumeID: volume.id).map(\.relativePath).sorted() == ["a", "a/bc.txt"])
    }

    @Test("节点 ID 永不复用")
    func nodeIDIsNeverReused() async throws {
        let fixture = try TempCatalogFixture()
        defer { fixture.remove() }

        let volume = makeVolume()
        let store = try fixture.makeStore()
        try await store.registerVolume(volume)

        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "",
                entries: [makeEntry("gone.txt")], isComplete: true
            )
        )
        let firstID = try #require(try await store.entries(volumeID: volume.id).first?.key.nodeID)

        try await store.apply(
            DirectoryBatch(volumeID: volume.id, directoryRelativePath: "", entries: [], isComplete: true)
        )
        #expect(try await store.entryCount(volumeID: volume.id) == 0)

        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "",
                entries: [makeEntry("different.txt")], isComplete: true
            )
        )
        let secondID = try #require(try await store.entries(volumeID: volume.id).first?.key.nodeID)

        #expect(firstID != secondID,
                "AUTOINCREMENT must not hand out a recycled id — stale UI state could open the wrong file")
    }

    @Test("relativePath 与 name 原样保留（不做大小写/规范化改写）")
    func relativePathAndNameArePreservedVerbatim() async throws {
        let fixture = try TempCatalogFixture()
        defer { fixture.remove() }

        let volume = makeVolume()
        let store = try fixture.makeStore()
        try await store.registerVolume(volume)

        let odd = makeEntry("Mixed Case/Ünïcödé File (副本).TXT", name: "Ünïcödé File (副本).TXT")
        try await store.apply(
            DirectoryBatch(volumeID: volume.id, directoryRelativePath: "", entries: [odd], isComplete: true)
        )
        let stored = try #require(try await store.entries(volumeID: volume.id).first)
        #expect(stored.relativePath == "Mixed Case/Ünïcödé File (副本).TXT")
        #expect(stored.name == "Ünïcödé File (副本).TXT")
    }

    @Test("代际只在真实变动时递增")
    func generationOnlyAdvancesOnRealChange() async throws {
        let fixture = try TempCatalogFixture()
        defer { fixture.remove() }

        let volume = makeVolume()
        let store = try fixture.makeStore()
        try await store.registerVolume(volume)
        let initialGeneration = try await store.generation()

        let batch = DirectoryBatch(
            volumeID: volume.id, directoryRelativePath: "",
            entries: [makeEntry("a.txt", size: 1)], isComplete: true
        )
        #expect(try await store.apply(batch) == initialGeneration + 1)

        // Identical re-apply changes nothing.
        #expect(try await store.apply(batch) == initialGeneration + 1)

        #expect(
            try await store.apply(
                DirectoryBatch(
                    volumeID: volume.id, directoryRelativePath: "",
                    entries: [makeEntry("a.txt", size: 2)], isComplete: true
                )
            ) == initialGeneration + 2
        )
    }

    @Test("未注册范围的应用会明确报错")
    func applyOnUnknownVolumeThrows() async throws {
        let fixture = try TempCatalogFixture()
        defer { fixture.remove() }

        let store = try fixture.makeStore()
        await #expect(throws: CatalogError.self) {
            try await store.apply(
                DirectoryBatch(volumeID: "nope", directoryRelativePath: "", entries: [], isComplete: true)
            )
        }
        do {
            _ = try await store.apply(
                DirectoryBatch(volumeID: "nope", directoryRelativePath: "", entries: [], isComplete: true)
            )
            Issue.record("expected an unknownVolume error")
        } catch let error as CatalogError {
            guard case .unknownVolume(let id) = error.kind else {
                Issue.record("wrong error kind: \(error)")
                return
            }
            #expect(id == "nope")
        }
    }

    @Test("checkpoint 与补扫责任原子提交并跨重启保留")
    func checkpointAndPendingPathsCommitAtomicallyAndSurviveRestart() async throws {
        let fixture = try TempCatalogFixture()
        defer { fixture.remove() }

        let volume = makeVolume()
        do {
            let store = try fixture.makeStore()
            try await store.registerVolume(volume)
            #expect(try await store.checkpoint(volumeID: volume.id) == nil)

            try await store.commitCheckpoint(
                SyncCheckpoint(volumeID: volume.id, eventID: 42, journalUUID: "journal-1"),
                pendingPaths: ["b", "a", "c"]
            )
            let checkpoint = try #require(try await store.checkpoint(volumeID: volume.id))
            #expect(checkpoint.eventID == 42)
            #expect(checkpoint.journalUUID == "journal-1")
            #expect(try await store.pendingPaths(volumeID: volume.id) == ["b", "a", "c"])
        }

        let reopened = try fixture.makeStore()
        let checkpoint = try #require(try await reopened.checkpoint(volumeID: volume.id))
        #expect(checkpoint.eventID == 42)
        #expect(try await reopened.pendingPaths(volumeID: volume.id) == ["b", "a", "c"])

        try await reopened.setPendingPaths(volumeID: volume.id, paths: ["only"])
        #expect(try await reopened.pendingPaths(volumeID: volume.id) == ["only"])

        // Advancing the checkpoint must not silently drop unswept responsibility.
        try await reopened.commitCheckpoint(
            SyncCheckpoint(volumeID: volume.id, eventID: 99, journalUUID: "journal-1"),
            pendingPaths: ["only", "extra"]
        )
        #expect(try await reopened.pendingPaths(volumeID: volume.id) == ["only", "extra"])
        #expect(try await reopened.checkpoint(volumeID: volume.id)?.eventID == 99)
    }

    @Test("clearPendingPaths 只清掉已处理路径")
    func clearPendingPathsRemovesOnlyGivenPaths() async throws {
        let fixture = try TempCatalogFixture()
        defer { fixture.remove() }

        let store = try fixture.makeStore()
        try await store.registerVolume(makeVolume())
        try await store.setPendingPaths(volumeID: "vol-1", paths: ["a", "b", "c"])
        try await store.clearPendingPaths(volumeID: "vol-1", paths: ["b"])
        #expect(try await store.pendingPaths(volumeID: "vol-1") == ["a", "c"])
    }

    @Test("snapshot 汇总代际、条目与卷")
    func snapshotCarriesGenerationEntriesAndVolumes() async throws {
        let fixture = try TempCatalogFixture()
        defer { fixture.remove() }

        let volume = makeVolume()
        let store = try fixture.makeStore()
        try await store.registerVolume(volume)
        let initialGeneration = try await store.generation()
        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "",
                entries: [makeEntry("x.txt", size: 7)], isComplete: true
            )
        )
        let snapshot = try await store.snapshot()
        #expect(snapshot.generation == initialGeneration + 1)
        #expect(snapshot.volumes == [volume])
        #expect(snapshot.entries.map(\.relativePath) == ["x.txt"])
        #expect(snapshot.entries[0].size == 7)
    }

    @Test("同一路径的元数据更新复用同一 node id")
    func upsertUpdatesMetadataInPlace() async throws {
        let fixture = try TempCatalogFixture()
        defer { fixture.remove() }

        let volume = makeVolume()
        let store = try fixture.makeStore()
        try await store.registerVolume(volume)
        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "",
                entries: [makeEntry("f.txt", size: 1, modifiedAt: Date(timeIntervalSinceReferenceDate: 10))],
                isComplete: true
            )
        )
        let before = try #require(try await store.entries(volumeID: volume.id).first)

        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "",
                entries: [makeEntry("f.txt", size: 99, modifiedAt: Date(timeIntervalSinceReferenceDate: 20))],
                isComplete: true
            )
        )
        let after = try #require(try await store.entries(volumeID: volume.id).first)
        #expect(after.key.nodeID == before.key.nodeID, "stable node id across metadata updates")
        #expect(after.size == 99)
        #expect(after.modifiedAt == Date(timeIntervalSinceReferenceDate: 20))
    }

    @Test("重扫根目录不会删掉根节点自身或根级兄弟")
    func rootRescanKeepsRootNodeAndSiblings() async throws {
        let fixture = try TempCatalogFixture()
        defer { fixture.remove() }

        let volume = makeVolume()
        let store = try fixture.makeStore()
        try await store.registerVolume(volume)

        // The scanner reports the root itself as an entry alongside its children.
        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "",
                entries: [
                    makeEntry("", name: "/", isDirectory: true),
                    makeEntry("alpha.txt"),
                    makeEntry("beta.txt"),
                ],
                isComplete: true
            )
        )
        #expect(try await store.entryCount(volumeID: volume.id) == 3)

        // Rescan where "alpha.txt" is gone. Root node and sibling must survive.
        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "",
                entries: [makeEntry("", name: "/", isDirectory: true), makeEntry("beta.txt")],
                isComplete: true
            )
        )
        #expect(
            try await store.entries(volumeID: volume.id).map(\.relativePath).sorted() == ["", "beta.txt"]
        )

        // Same via a "/"-spelled root, which canonicalizes to "".
        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "/",
                entries: [makeEntry("beta.txt")], isComplete: true
            )
        )
        #expect(try await store.entries(volumeID: volume.id).map(\.relativePath).sorted() == ["", "beta.txt"])
    }

    @Test("重扫子目录不会删掉该目录自身")
    func directoryRescanKeepsTheDirectoryNodeItself() async throws {
        let fixture = try TempCatalogFixture()
        defer { fixture.remove() }

        let volume = makeVolume()
        let store = try fixture.makeStore()
        try await store.registerVolume(volume)

        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "",
                entries: [makeEntry("docs", isDirectory: true)],
                isComplete: true
            )
        )
        // Rescan "docs" with no children at all.
        try await store.apply(
            DirectoryBatch(volumeID: volume.id, directoryRelativePath: "docs", entries: [], isComplete: true)
        )
        #expect(try await store.entries(volumeID: volume.id).map(\.relativePath) == ["docs"])
    }

    @Test("删除子树的前缀边界：a/b 不影响 a/bc、a/b-旧、a/bb")
    func subtreeDeletionRespectsPrefixBoundaries() async throws {
        let fixture = try TempCatalogFixture()
        defer { fixture.remove() }

        let volume = makeVolume()
        let store = try fixture.makeStore()
        try await store.registerVolume(volume)

        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "",
                entries: [makeEntry("a", isDirectory: true)], isComplete: true
            )
        )
        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "a",
                entries: [
                    makeEntry("a/b", isDirectory: true),
                    makeEntry("a/bc.txt"),
                    makeEntry("a/b-旧.txt"),
                    makeEntry("a/bb/deep.txt", isDirectory: true),
                ],
                isComplete: true
            )
        )
        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "a/b",
                entries: [makeEntry("a/b/inner.txt")], isComplete: true
            )
        )
        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "a/bb",
                entries: [makeEntry("a/bb/keep.txt")], isComplete: true
            )
        )

        // "a" now only holds "a/bb" and the two prefix-adjacent files.
        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "a",
                entries: [
                    makeEntry("a/bc.txt"),
                    makeEntry("a/b-旧.txt"),
                    makeEntry("a/bb", isDirectory: true),
                ],
                isComplete: true
            )
        )
        #expect(
            try await store.entries(volumeID: volume.id).map(\.relativePath).sorted() == [
                "a", "a/b-旧.txt", "a/bb", "a/bb/keep.txt", "a/bc.txt",
            ]
        )
    }

    @Test("连续两个批次各自变更都会推进代际，幂等重放不变")
    func consecutiveBatchesEachBumpGeneration() async throws {
        let fixture = try TempCatalogFixture()
        defer { fixture.remove() }

        let volume = makeVolume()
        let store = try fixture.makeStore()
        try await store.registerVolume(volume)
        let initialGeneration = try await store.generation()

        // Batch 1: insert.
        let g1 = try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "",
                entries: [
                    makeEntry("a.txt", size: 1, modifiedAt: Date(timeIntervalSinceReferenceDate: 100)),
                    makeEntry("b.txt", size: 1, modifiedAt: Date(timeIntervalSinceReferenceDate: 100)),
                    makeEntry("c.txt", size: 1, modifiedAt: Date(timeIntervalSinceReferenceDate: 100)),
                ],
                isComplete: true
            )
        )
        #expect(g1 == initialGeneration + 1)

        // Batch 2: update only ONE row. This is the case a naive
        // `sqlite3_changes()` before/after comparison misses, because the previous
        // statement changed 3 rows and this one changes 1 (1 > 3 == false).
        let g2 = try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "",
                entries: [
                    makeEntry("a.txt", size: 2, modifiedAt: Date(timeIntervalSinceReferenceDate: 200)),
                    makeEntry("b.txt", size: 1, modifiedAt: Date(timeIntervalSinceReferenceDate: 100)),
                    makeEntry("c.txt", size: 1, modifiedAt: Date(timeIntervalSinceReferenceDate: 100)),
                ],
                isComplete: true
            )
        )
        #expect(g2 == initialGeneration + 2, "a single-row update must still advance the generation")

        // Batch 3: idempotent replay of batch 2 changes nothing.
        let g3 = try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "",
                entries: [
                    makeEntry("a.txt", size: 2, modifiedAt: Date(timeIntervalSinceReferenceDate: 200)),
                    makeEntry("b.txt", size: 1, modifiedAt: Date(timeIntervalSinceReferenceDate: 100)),
                    makeEntry("c.txt", size: 1, modifiedAt: Date(timeIntervalSinceReferenceDate: 100)),
                ],
                isComplete: true
            )
        )
        #expect(g3 == initialGeneration + 2, "replaying an identical batch must not bump the generation")
        #expect(try await store.generation() == initialGeneration + 2)
    }

    @Test("删除操作同样使用 total_changes 判定")
    func deleteOnlyAlsoDetectsChange() async throws {
        let fixture = try TempCatalogFixture()
        defer { fixture.remove() }

        let volume = makeVolume()
        let store = try fixture.makeStore()
        try await store.registerVolume(volume)

        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "",
                entries: [
                    makeEntry("keep.txt"),
                    makeEntry("drop1.txt"),
                    makeEntry("drop2.txt"),
                ],
                isComplete: true
            )
        )
        let afterInsert = try await store.generation()

        // Delete 2 rows right after a 3-row insert: `sqlite3_changes()` would read
        // 2 > 3 == false and wrongly report "nothing changed".
        let afterDelete = try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "",
                entries: [makeEntry("keep.txt")], isComplete: true
            )
        )
        #expect(afterDelete == afterInsert + 1)
        #expect(try await store.entries(volumeID: volume.id).map(\.relativePath) == ["keep.txt"])
    }

    @Test("大批量缺失项（2000 条）分块删除且不误伤兄弟")
    func largeMissingSetIsDeletedInChunks() async throws {
        let fixture = try TempCatalogFixture()
        defer { fixture.remove() }

        let volume = makeVolume()
        let store = try fixture.makeStore()
        try await store.registerVolume(volume)

        let many = 2_000
        var entries: [ScannedEntry] = [makeEntry("big", isDirectory: true)]
        for index in 0..<many {
            entries.append(makeEntry("big/child\(index).txt"))
        }
        // Sibling whose name shares the "big" prefix must never be touched.
        entries.append(makeEntry("big-sibling", isDirectory: true))
        entries.append(makeEntry("big-sibling/keep.txt"))
        try await store.apply(
            DirectoryBatch(volumeID: volume.id, directoryRelativePath: "", entries: entries, isComplete: true)
        )
        #expect(try await store.entryCount(volumeID: volume.id) == many + 3)

        // "big" now has no children at all: 2000 missing paths in one apply.
        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "big",
                entries: [], isComplete: true
            )
        )
        #expect(
            try await store.entries(volumeID: volume.id).map(\.relativePath).sorted() == [
                "big", "big-sibling", "big-sibling/keep.txt",
            ]
        )
    }

    @Test("LIKE 必须大小写敏感：删 A 不能连带删 a")
    func subtreeDeletionIsCaseSensitive() async throws {
        let fixture = try TempCatalogFixture()
        defer { fixture.remove() }

        let volume = makeVolume()
        let store = try fixture.makeStore()
        try await store.registerVolume(volume)

        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "",
                entries: [
                    makeEntry("A", isDirectory: true),
                    makeEntry("a", isDirectory: true),
                ],
                isComplete: true
            )
        )
        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "A",
                entries: [makeEntry("A/deep/inner.txt")], isComplete: true
            )
        )
        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "a",
                entries: [makeEntry("a/other.txt")], isComplete: true
            )
        )
        #expect(try await store.entryCount(volumeID: volume.id) == 4)

        // Drop "A" from the root. Only A's subtree goes; "a" is a different path.
        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "",
                entries: [makeEntry("a", isDirectory: true)], isComplete: true
            )
        )
        #expect(
            try await store.entries(volumeID: volume.id).map(\.relativePath).sorted() == [
                "a", "a/other.txt",
            ],
            "SQLite LIKE folds ASCII case by default; a case-insensitive prefix match would have wiped a/other.txt"
        )
    }

    @Test("含引号与转义字符的路径不会被 LIKE 通配符误伤")
    func wildcardCharactersInPathsAreEscaped() async throws {
        let fixture = try TempCatalogFixture()
        defer { fixture.remove() }

        let volume = makeVolume()
        let store = try fixture.makeStore()
        try await store.registerVolume(volume)

        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "",
                entries: [
                    makeEntry("100%done", isDirectory: true),
                    makeEntry("100%done/keep.txt"),
                    makeEntry("under_score", isDirectory: true),
                    makeEntry("under_score/keep.txt"),
                ],
                isComplete: true
            )
        )
        // Re-scan the root without "100%done": only that subtree may go.
        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "",
                entries: [makeEntry("under_score", isDirectory: true), makeEntry("under_score/keep.txt")],
                isComplete: true
            )
        )
        #expect(try await store.entries(volumeID: volume.id).map(\.relativePath).sorted() == ["under_score", "under_score/keep.txt"])
    }
}