import Foundation
import SearchCore

/// Read-only view over a catalog database.
///
/// Two reasons this exists rather than reusing `CatalogStore`:
///
/// 1. **Safety.** `CatalogStore.init` opens read-write and runs schema setup. On an
///    index that lives on a mounted external volume that is the wrong thing to do
///    for a pure read (and it takes the single-writer lock away from the scanner).
///    `CatalogReader` opens `SQLITE_OPEN_READONLY`: it never creates the database
///    file and never writes to it.
/// 2. **Cost.** Loading a million rows through a read-only connection does not have
///    to compete with an active writer, so reopen latency drops.
///
/// What read-only does **not** mean: SQLite still maintains the `-wal` / `-shm`
/// sidecars of a WAL database, and a read-only connection may create or update
/// those. It guarantees no write to the main database file, nothing more.
///
/// If the caller can additionally guarantee "no concurrent writer", opening with
/// `staticImmutable: true` additionally tells SQLite the file can never change, so
/// it skips the sidecars entirely. Use `isStaticImmutableAvailable(databaseURL:)` to
/// check the WAL precondition first when you want to surface a friendly state
/// instead of an error — but note it is **necessary, not sufficient**: an empty WAL
/// proves nothing is pending, it cannot prove no other process is about to write.
/// Never open a live index this way.
///
/// Thread safety: all access funnels through one connection's lock, so copies of a
/// reader (and concurrent calls on one) cannot interleave. `snapshot()` runs inside
/// a single deferred read transaction, so it can never straddle two generations.
public struct CatalogReader: Sendable {
    private let db: SQLiteConnection

    /// Opens `databaseURL` read-only. Throws if the file does not exist.
    public init(databaseURL: URL) throws {
        db = try SQLiteConnection(url: databaseURL, access: .readOnly)
    }

    /// Opens as immutable: read-only, no locking, no `-wal` / `-shm` sidecars.
    ///
    /// **The caller must guarantee nothing else is writing the file.** SQLite will
    /// not lock it and will not replay or create a WAL, so a concurrent writer would
    /// be silently ignored and its data lost from this reader's view.
    ///
    /// Throws when the `-wal` sidecar holds unmerged content — the check is enforced
    /// by the constructor, so it cannot be bypassed by forgetting to call
    /// `isStaticImmutableAvailable(databaseURL:)` first.
    public init(databaseURL: URL, staticImmutable: Bool) throws {
        db = try SQLiteConnection(
            url: databaseURL,
            access: staticImmutable ? .staticImmutable : .readOnly
        )
    }

    /// Whether the database has no unmerged WAL content — the *necessary* condition
    /// for `init(databaseURL:staticImmutable:)`.
    ///
    /// Insufficient on its own: an empty `-wal` says nothing about a writer that has
    /// not flushed yet. Only pass `staticImmutable: true` when you know the index is
    /// quiescent (e.g. the scanner is paused or the volume is unmounted).
    public static func isStaticImmutableAvailable(databaseURL: URL) -> Bool {
        SQLiteConnection.isStaticImmutableSafe(databaseURL: databaseURL)
    }

    /// True when this reader was opened without write access to the database file.
    /// Does not imply the `-wal` / `-shm` sidecars were left alone.
    public var isReadOnly: Bool { true }

    public func generation() throws -> UInt64 {
        let value = try db.query("SELECT value FROM meta WHERE key = 'generation';").first?.string(at: 0)
        guard let value, let parsed = UInt64(value) else { return 0 }
        return parsed
    }

    public func volumes() throws -> [VolumeRecord] {
        try db.query(
            """
            SELECT id, name, root_path, file_system, volume_uuid,
                   is_online, requires_full_verification, last_verified_at
            FROM volumes ORDER BY id;
            """
        ).compactMap(CatalogStore.volume(from:))
    }

    /// All entries, or one volume's. See `CatalogStore.readEntries` for why the
    /// ordering differs between the two shapes.
    public func entries(volumeID: String? = nil) throws -> [IndexedEntry] {
        try CatalogStore.readEntries(db, volumeID: volumeID)
    }

    /// Same rows, no `ORDER BY`, streamed straight into the caller's array.
    ///
    /// For callers that only feed `SearchEngine` — which always establishes its own
    /// total order — the ordering is dead weight, and in the single-volume shape it
    /// can cost a full index walk plus a random row lookup per row. Adopt this in
    /// the App's load path and keep `entries()` for anything that needs the order.
    public func appendEntriesUnordered(
        volumeID: String? = nil,
        into result: inout [IndexedEntry]
    ) throws {
        try CatalogStore.streamEntries(db, volumeID: volumeID, into: &result)
    }

    public func entriesUnordered(volumeID: String? = nil) throws -> [IndexedEntry] {
        var result: [IndexedEntry] = []
        try appendEntriesUnordered(volumeID: volumeID, into: &result)
        return result
    }

    public func entryCount(volumeID: String? = nil) throws -> Int {
        let sql: String
        var bindings: [SQLiteValue] = []
        if let volumeID {
            sql = "SELECT COUNT(*) FROM nodes WHERE volume_id = ?;"
            bindings = [.text(volumeID)]
        } else {
            sql = "SELECT COUNT(*) FROM nodes;"
        }
        return try db.query(sql, bindings).first?.int64(at: 0).map(Int.init) ?? 0
    }

    /// Reads generation, volumes and entries under **one** deferred read transaction.
    ///
    /// A naive read of generation → volumes → entries → generation can straddle a
    /// concurrent `apply`: re-reading only `entries` on a detected change still leaves
    /// the old volumes and the old `after` generation attached to new rows. A single
    /// deferred transaction pins one WAL snapshot for the whole read, so all three
    /// always come from the same generation — with no retry loop and no extra pass.
    /// `DEFERRED` is used rather than `IMMEDIATE` so the reader never takes a write
    /// lock and never blocks the scanner.
    public func snapshot() throws -> CatalogSnapshot {
        try db.readTransaction {
            let generation = try self.generation()
            let volumes = try self.volumes()
            let entries = try self.entries()
            return CatalogSnapshot(generation: generation, entries: entries, volumes: volumes)
        }
    }

    /// Unordered variant of `snapshot()`, for callers that feed `SearchEngine`.
    public func snapshotUnordered() throws -> CatalogSnapshot {
        try db.readTransaction {
            let generation = try self.generation()
            let volumes = try self.volumes()
            var entries: [IndexedEntry] = []
            try self.appendEntriesUnordered(into: &entries)
            return CatalogSnapshot(generation: generation, entries: entries, volumes: volumes)
        }
    }

    /// Cheap integrity signal for the UI: `PRAGMA quick_check` vs `integrity_check`.
    public func checkIntegrity(full: Bool = false) throws -> String {
        try db.query("PRAGMA \(full ? "integrity_check" : "quick_check");").first?.string(at: 0) ?? "unknown"
    }
}