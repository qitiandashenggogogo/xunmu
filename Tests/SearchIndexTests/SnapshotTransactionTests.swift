import Foundation
import SearchCore
import Testing
@testable import SearchIndex

/// Pins the single-transaction guarantee that `snapshot()` relies on, against a
/// **second, independent connection** acting as an external writer (the scanner, a
/// second app instance, a migration tool).
///
/// What is covered here, precisely:
///
/// * `readTransactionPinsSnapshotAcrossExternalCommit` is a real interleaving test:
///   the external connection *commits while the reader's transaction is still open*
///   (issued from inside the transaction body, so the ordering is by construction —
///   no sleeps, no polling, no luck). It proves the reader's second read still sees
///   the pre-commit generation and the pre-commit row count. Without the pinned
///   transaction these two reads would return the post-commit values.
/// * `snapshotIsSingleVersionWhileExternalWriteIsInFlight` drives the public
///   `snapshot()` / `snapshotUnordered()` while an external write transaction is held
///   open, and asserts the generation / rows / volumes invariant on both sides of
///   the commit.
///
/// What is **not** covered here: forcing a commit to land *between two specific reads
/// inside* `snapshot()` itself. `snapshot()` offers no seam to stop it mid-body, and
/// a timing-based stand-in would be luck, not evidence. The gap is closed by the
/// primitive-level test above, since `snapshot()` is a thin wrapper over exactly that
/// `readTransaction`; this is stated here so nobody reads these two tests as a
/// direct mid-body interleaving proof.
@Suite("快照单事务与外部写入交叠")
struct SnapshotTransactionTests {
    /// Raw node insert for the external writer. Kept as literal SQL on purpose: the
    /// point of these tests is the transaction boundary, not the insert API.
    private func insertNodeSQL(volumeID: String, path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return """
        INSERT INTO nodes(volume_id, relative_path, parent_path, name, name_key, path_key,
                          is_directory, is_symbolic_link, size, modified_at, state)
        VALUES ('\(volumeID)', '\(path)', '', '\(name)', '\(name)', '\(path)', 0, 0, 0, 0, 0);
        """
    }

    private func bumpGenerationSQL() -> String {
        "UPDATE meta SET value = CAST(value AS INTEGER) + 1 WHERE key = 'generation';"
    }

    @Test("只读事务在外部连接中途提交后仍固定在同一快照")
    func readTransactionPinsSnapshotAcrossExternalCommit() async throws {
        let fixture = try TempCatalogFixture()
        defer { fixture.remove() }

        let volume = makeVolume()
        let store = try fixture.makeStore()
        try await store.registerVolume(volume)
        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "",
                entries: [makeEntry("a.txt")],
                isComplete: true
            )
        )
        let generationBefore = try await store.generation()
        #expect(generationBefore > 0)

        // Two independent connections to the same file: one reads, one writes. Neither
        // shares state with `store`, so this really is an external writer.
        let reader = try SQLiteConnection(url: fixture.databaseURL, access: .readOnly)
        let writer = try SQLiteConnection(url: fixture.databaseURL)

        let observed: (String?, Int64?, String?, Int64?) = try reader.readTransaction {
            // First read pins this transaction's snapshot.
            let startGeneration = try reader.query("SELECT value FROM meta WHERE key = 'generation';")
                .first?.string(at: 0)
            let startCount = try reader.query("SELECT COUNT(*) FROM nodes;").first?.int64(at: 0)

            // The external writer commits *while the reader transaction is open*.
            // WAL lets one writer commit next to an open reader; a pinned reader
            // must not notice. Ordering here is by construction, not by timing.
            try writer.transaction {
                try writer.run(insertNodeSQL(volumeID: volume.id, path: "mid.txt"))
                try writer.run(bumpGenerationSQL())
            }

            let afterCommitGeneration = try reader.query("SELECT value FROM meta WHERE key = 'generation';")
                .first?.string(at: 0)
            let afterCommitCount = try reader.query("SELECT COUNT(*) FROM nodes;").first?.int64(at: 0)
            return (startGeneration, startCount, afterCommitGeneration, afterCommitCount)
        }
        withExtendedLifetime((store, reader, writer)) {}

        #expect(observed.0 == String(generationBefore))
        #expect(observed.1 == 1)
        #expect(observed.2 == observed.0, "事务内第二次读必须仍是同一代际，不能看到事务期间提交的新代际")
        #expect(observed.3 == observed.1, "事务内第二次读必须仍是同一批行，不能看到事务期间提交的新行")

        // The commit is real: the very next transaction sees the new version.
        #expect(try reader.query("SELECT value FROM meta WHERE key = 'generation';").first?.string(at: 0)
                == String(generationBefore + 1))
        #expect(try reader.query("SELECT COUNT(*) FROM nodes;").first?.int64(at: 0) == 2)
    }

    @Test("外部写事务进行中，快照的代际/行/卷仍属同一版本")
    func snapshotIsSingleVersionWhileExternalWriteIsInFlight() async throws {
        let fixture = try TempCatalogFixture()
        defer { fixture.remove() }

        let volume = makeVolume()
        let store = try fixture.makeStore()
        try await store.registerVolume(volume)
        try await store.apply(
            DirectoryBatch(
                volumeID: volume.id, directoryRelativePath: "",
                entries: [makeEntry("a.txt"), makeEntry("b.txt")],
                isComplete: true
            )
        )
        let generationBefore = try await store.generation()

        let writer = try SQLiteConnection(url: fixture.databaseURL)
        // An uncommitted external write: one more node plus one more generation.
        try writer.run("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try writer.run(insertNodeSQL(volumeID: volume.id, path: "c.txt"))
            try writer.run(bumpGenerationSQL())

            let ordered = try await store.snapshot()
            let unordered = try await store.snapshotUnordered()
            for snapshot in [ordered, unordered] {
                // The invariant, checked as a triple: a generation, a row set and a
                // volume set from one version. Half-visible is the only failure mode.
                #expect(snapshot.generation == generationBefore, "未提交写入不得泄漏进代际")
                #expect(snapshot.entries.map(\.name).sorted() == ["a.txt", "b.txt"], "行集合必须仍是提交前的版本")
                #expect(snapshot.entries.allSatisfy { $0.key.volumeID == volume.id })
                #expect(snapshot.volumes.map(\.id) == [volume.id])
            }

            let reader = try CatalogReader(databaseURL: fixture.databaseURL)
            let readSnapshot = try reader.snapshot()
            #expect(readSnapshot.generation == generationBefore)
            #expect(readSnapshot.entries.count == 2)
            #expect(readSnapshot.volumes.map(\.id) == [volume.id])
            withExtendedLifetime(reader) {}

            try writer.run("COMMIT;")
        } catch {
            try? writer.run("ROLLBACK;")
            throw error
        }
        withExtendedLifetime((store, writer)) {}

        // After the commit the whole triple flips together, still one version.
        let after = try await store.snapshot()
        #expect(after.generation == generationBefore + 1)
        #expect(after.entries.map(\.name).sorted() == ["a.txt", "b.txt", "c.txt"])
        #expect(after.volumes.map(\.id) == [volume.id])
    }
}