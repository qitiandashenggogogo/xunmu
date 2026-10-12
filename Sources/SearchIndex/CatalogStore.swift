import Foundation
import SearchCore

/// Single-writer persistent catalog backed by SQLite (WAL mode).
///
/// Contract highlights implemented here:
/// * `node_id` comes from `AUTOINCREMENT`, so a deleted node's id is never handed
///   out again — stale UI state can never be resurrected onto a different file.
/// * `relative_path` is stored verbatim; normalization only ever happens in
///   generated matching keys (`name_key`, `path_key`).
/// * A `DirectoryBatch` marked `isComplete` replaces the directory's direct
///   children: upserts inside one transaction, then delete-on-missing (including
///   the whole subtree of each missing child).
/// * An incomplete batch only upserts. Nothing is ever deleted on a partial or
///   errored scan, and the affected directory is flagged `.stale`.
/// * `generation` is a persisted counter bumped on every mutating apply, so the
///   UI can discard results computed against an older snapshot.
public actor CatalogStore {
    private let db: SQLiteConnection

    // MARK: - Lifecycle

    public init(databaseURL: URL) throws {
        let directory = databaseURL.deletingLastPathComponent()
        if !directory.path.isEmpty && !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let connection = try SQLiteConnection(url: databaseURL)
        try CatalogStore.migrate(connection)
        db = connection
    }

    private static func migrate(_ db: SQLiteConnection) throws {
        try db.run(
            """
            CREATE TABLE IF NOT EXISTS meta (
                key   TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            );
            """
        )
        try db.run(
            """
            CREATE TABLE IF NOT EXISTS volumes (
                id                         TEXT PRIMARY KEY NOT NULL,
                name                       TEXT NOT NULL,
                root_path                  TEXT NOT NULL,
                file_system                TEXT NOT NULL,
                volume_uuid                TEXT,
                is_online                  INTEGER NOT NULL DEFAULT 1,
                requires_full_verification INTEGER NOT NULL DEFAULT 0,
                last_verified_at           REAL
            );
            """
        )
        try db.run(
            """
            CREATE TABLE IF NOT EXISTS nodes (
                node_id          INTEGER PRIMARY KEY AUTOINCREMENT,
                volume_id        TEXT NOT NULL REFERENCES volumes(id) ON DELETE CASCADE,
                relative_path    TEXT NOT NULL,
                parent_path      TEXT NOT NULL,
                name             TEXT NOT NULL,
                name_key         TEXT NOT NULL,
                path_key         TEXT NOT NULL,
                is_directory     INTEGER NOT NULL,
                is_symbolic_link INTEGER NOT NULL,
                size             INTEGER NOT NULL,
                modified_at      REAL NOT NULL,
                file_id          INTEGER,
                state            INTEGER NOT NULL,
                UNIQUE (volume_id, relative_path)
            );
            """
        )
        try db.run("CREATE INDEX IF NOT EXISTS idx_nodes_volume ON nodes(volume_id);")
        try db.run("CREATE INDEX IF NOT EXISTS idx_nodes_parent ON nodes(volume_id, parent_path);")
        try db.run("CREATE INDEX IF NOT EXISTS idx_nodes_path ON nodes(volume_id, relative_path);")
        try db.run(
            """
            CREATE TABLE IF NOT EXISTS checkpoints (
                volume_id    TEXT PRIMARY KEY NOT NULL,
                event_id     INTEGER NOT NULL,
                journal_uuid TEXT
            );
            """
        )
        try db.run(
            """
            CREATE TABLE IF NOT EXISTS pending_paths (
                volume_id TEXT NOT NULL,
                path      TEXT NOT NULL,
                PRIMARY KEY (volume_id, path)
            );
            """
        )
        // Scratch table used inside apply() to diff a directory's direct children
        // without materializing an unbounded IN (...) list.
        try db.run(
            """
            CREATE TEMP TABLE IF NOT EXISTS batch_paths (
                relative_path TEXT PRIMARY KEY NOT NULL
            );
            """
        )
        try db.run("INSERT OR IGNORE INTO meta(key, value) VALUES ('generation', '0');")
    }

    // MARK: - Volumes

    public func registerVolume(_ volume: VolumeRecord) throws {
        if try volumes().first(where: { $0.id == volume.id }) == volume { return }
        try db.transaction {
        try db.run(
            """
            INSERT INTO volumes(id, name, root_path, file_system, volume_uuid,
                                is_online, requires_full_verification, last_verified_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                root_path = excluded.root_path,
                file_system = excluded.file_system,
                volume_uuid = excluded.volume_uuid,
                is_online = excluded.is_online,
                requires_full_verification = excluded.requires_full_verification,
                last_verified_at = excluded.last_verified_at;
            """,
            [
                .text(volume.id),
                .text(volume.name),
                .text(volume.rootPath),
                .text(volume.fileSystem),
                volume.volumeUUID.map { SQLiteValue.text($0) } ?? .null,
                .integer(volume.isOnline ? 1 : 0),
                .integer(volume.requiresFullVerification ? 1 : 0),
                volume.lastVerifiedAt.map { SQLiteValue.real($0.timeIntervalSinceReferenceDate) } ?? .null,
            ]
        )
        try bumpGeneration()
        }
    }

    public func volumes() throws -> [VolumeRecord] {
        try db.query(
            """
            SELECT id, name, root_path, file_system, volume_uuid,
                   is_online, requires_full_verification, last_verified_at
            FROM volumes ORDER BY id;
            """
        ).compactMap(Self.volume(from:))
    }

    /// Convenience used by the app layer to build a `CatalogSnapshot` without
    /// having to stitch `volumes()` and `entries()` together itself.
    ///
    /// All three reads run inside **one** deferred read transaction, exactly like
    /// `CatalogReader.snapshot()`. Read separately they could straddle a concurrent
    /// `apply` — an entry list from a newer generation attached to an older `after`
    /// generation, or a volume list that no longer matches the rows. `readTransaction`
    /// takes the connection lock *before* `BEGIN`, so the whole triple is serialized
    /// against this connection's other work and pinned to a single WAL snapshot.
    /// `DEFERRED` deliberately: the reader never takes a write lock and never blocks
    /// the single writer. **Must not be changed to `IMMEDIATE`.**
    public func snapshot() throws -> CatalogSnapshot {
        try db.readTransaction {
            CatalogSnapshot(
                generation: try self.generation(),
                entries: try self.entries(),
                volumes: try self.volumes()
            )
        }
    }

    // MARK: - Reads

    public func entries(volumeID: String? = nil) throws -> [IndexedEntry] {
        try Self.readEntries(db, volumeID: volumeID)
    }

    /// Unordered streaming load. New API; `entries(volumeID:)` keeps its contract.
    ///
    /// The App's own read shape is per volume, and for a single volume the
    /// `ORDER BY volume_id, relative_path` is served by `idx_nodes_path` rather than
    /// by a sort — but it is still an index walk with one random row lookup per row.
    /// `SearchEngine` establishes its own total order anyway, so anything that only
    /// feeds the engine can drop the ordering. Measured shapes are recorded in
    /// docs/PERFORMANCE-DESIGN.md; do not assume the no-filter numbers apply to the
    /// per-volume path.
    public func entriesUnordered(volumeID: String? = nil) throws -> [IndexedEntry] {
        var result: [IndexedEntry] = []
        try Self.streamEntries(db, volumeID: volumeID, into: &result)
        return result
    }

    /// Appends rows straight into `result`, reusing its capacity across loads.
    public func appendEntriesUnordered(
        volumeID: String? = nil,
        into result: inout [IndexedEntry]
    ) throws {
        try Self.streamEntries(db, volumeID: volumeID, into: &result)
    }

    /// Unordered snapshot for the App's load path. New API.
    public func snapshotUnordered() throws -> CatalogSnapshot {
        var entries: [IndexedEntry] = []
        return try db.readTransaction {
            let generation = try self.generation()
            let volumes = try self.volumes()
            try Self.streamEntries(db, volumeID: nil, into: &entries)
            return CatalogSnapshot(generation: generation, entries: entries, volumes: volumes)
        }
    }

    /// Shared row loader for `CatalogStore` (read-write) and `CatalogReader` (read-only).
    ///
    /// The `ORDER BY` is deliberately asymmetric, and this is measured, not guessed:
    ///
    /// * `WHERE volume_id = ? ORDER BY volume_id, relative_path` is served by
    ///   `idx_nodes_path`, which *is* the sort order, so the ordering is free.
    /// * `ORDER BY volume_id, relative_path` with no filter forces
    ///   `SCAN nodes USING INDEX idx_nodes_path`: a full index walk plus one random
    ///   rowid lookup per row to fetch the other columns.
    /// * Dropping it gives a sequential `SCAN nodes` table walk, which is exactly the
    ///   order `node_id` already gives us (AUTOINCREMENT insertion order).
    ///
    /// Measured on the 1,026,273-row NTFS index (warm cache, sqlite3 CLI, identical
    /// projection): with ORDER BY 2.24 s, without 1.06 s, single-volume + ORDER BY
    /// 1.24 s. Ordering is therefore only paid for when it is already indexed.
    static func readEntries(_ db: SQLiteConnection, volumeID: String?) throws -> [IndexedEntry] {
        var entries: [IndexedEntry] = []
        let sql: String
        var bindings: [SQLiteValue] = []
        if let volumeID {
            sql = Self.entryColumns + " WHERE volume_id = ? ORDER BY volume_id, relative_path;"
            bindings = [.text(volumeID)]
        } else {
            sql = Self.entryColumns + ";"
        }
        try db.forEachRow(sql, bindings) { row in
            entries.append(Self.decode(row))
        }
        return entries
    }

    /// Same decode path, no `ORDER BY`, writing into a caller-owned buffer.
    static func streamEntries(
        _ db: SQLiteConnection,
        volumeID: String?,
        into result: inout [IndexedEntry]
    ) throws {
        let sql: String
        var bindings: [SQLiteValue] = []
        if let volumeID {
            sql = Self.entryColumns + " WHERE volume_id = ?;"
            bindings = [.text(volumeID)]
        } else {
            sql = Self.entryColumns + ";"
        }
        try db.forEachRow(sql, bindings) { row in
            result.append(Self.decode(row))
        }
    }

    private static func decode(_ row: SQLiteRowReader) -> IndexedEntry {
        IndexedEntry(
            key: EntryKey(volumeID: row.string(1), nodeID: row.int64(0)),
            relativePath: row.string(2),
            name: row.string(3),
            isDirectory: row.bool(4),
            isSymbolicLink: row.bool(5),
            size: row.int64(6),
            modifiedAt: Date(timeIntervalSinceReferenceDate: row.double(7)),
            fileID: row.optionalUInt64(8),
            state: stateValue(for: row.int64(9))
        )
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

    public func generation() throws -> UInt64 {
        let value = try db.query("SELECT value FROM meta WHERE key = 'generation';").first?.string(at: 0)
        guard let value, let parsed = UInt64(value) else { return 0 }
        return parsed
    }

    // MARK: - Applying scans

    /// Applies one directory batch inside a single transaction.
    /// Returns the catalog generation *after* the batch was applied.
    @discardableResult
    public func apply(_ batch: DirectoryBatch) throws -> UInt64 {
        try requireVolume(batch.volumeID)
        // A batch's entries are the DIRECT children of `directoryRelativePath`, so the
        // diff must select nodes whose parent_path equals that directory — not the
        // directory's own parent. Getting this wrong would delete the directory
        // itself and every sibling hanging off its parent.
        let directoryPath = IndexText.canonicalRelativePath(batch.directoryRelativePath)

        try db.transaction {
            try db.run("DELETE FROM batch_paths;")
            for entry in batch.entries {
                try db.run(
                    "INSERT OR REPLACE INTO batch_paths(relative_path) VALUES (?);",
                    [.text(entry.relativePath)]
                )
            }
            // The directory being scanned is never a candidate for delete-on-missing.
            // For the root ("") this is the only protection: its parent_path is also
            // "", so without this it would delete itself on the first rescan.
            for candidate in [batch.directoryRelativePath, directoryPath] {
                try db.run(
                    "INSERT OR IGNORE INTO batch_paths(relative_path) VALUES (?);",
                    [.text(candidate)]
                )
            }

            var changed = false
            // A complete parent listing can prove a same-directory rename when
            // exactly one disappeared entry and one incoming entry share an inode.
            // Restrict this to native filesystems; imported exFAT ids are not trusted.
            let native = try volumes().first(where: { $0.id == batch.volumeID })?.fileSystem.lowercased()
            if batch.isComplete && (native == "apfs" || native == "hfs") {
                let inodeCounts = Dictionary(batch.entries.compactMap { $0.fileID }.map { ($0, 1) }, uniquingKeysWith: +)
                for entry in batch.entries where entry.fileID.map({ inodeCounts[$0] == 1 }) == true {
                    if try preserveRenamedIdentity(entry, volumeID: batch.volumeID, directoryPath: directoryPath) { changed = true }
                }
            }

            // 1. Upsert everything the scan saw.
            for entry in batch.entries {
                if try upsert(entry, volumeID: batch.volumeID, state: .current) { changed = true }
            }

            if batch.isComplete {
                // 2. Delete-on-missing over this directory's direct children only.
                //    The directory's own node has a *different* parent_path, so it is
                //    structurally protected from this diff.
                let missing = try db.query(
                    """
                    SELECT relative_path FROM nodes
                    WHERE volume_id = ? AND parent_path = ?
                      AND relative_path NOT IN (SELECT relative_path FROM batch_paths);
                    """,
                    [.text(batch.volumeID), .text(directoryPath)]
                ).compactMap { $0.string(at: 0) }

                if !missing.isEmpty, try deleteSubtrees(missing, volumeID: batch.volumeID) {
                    changed = true
                }
            } else {
                // 3. Partial / errored scan: the directory itself needs re-verification.
                //    Only an upsert of already-seen entries is allowed to clear the flag,
                //    never the absence of an entry in a partial listing.
                if try markStale(
                    relativePath: batch.directoryRelativePath,
                    canonicalPath: directoryPath,
                    volumeID: batch.volumeID
                ) {
                    changed = true
                }
            }

            if changed {
                try bumpGeneration()
            }
        }

        return try generation()
    }

    /// Bumps the persisted generation. Exposed so callers that mutate the catalog
    /// outside `apply` (e.g. volume metadata changes) can invalidate stale UI state.
    @discardableResult
    public func bumpGeneration() throws -> UInt64 {
        let current = try generation()
        let next = current + 1
        try db.run(
            "INSERT INTO meta(key, value) VALUES ('generation', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
            [.text(String(next))]
        )
        return next
    }

    // MARK: - Checkpoints & pending rescan responsibility

    public func checkpoint(volumeID: String) throws -> SyncCheckpoint? {
        guard let row = try db.query(
            "SELECT event_id, journal_uuid FROM checkpoints WHERE volume_id = ?;",
            [.text(volumeID)]
        ).first, let eventID = row.int64(at: 0) else { return nil }
        return SyncCheckpoint(volumeID: volumeID, eventID: UInt64(eventID), journalUUID: row.string(at: 1))
    }

    /// Commits the FSEvents checkpoint *and* the rescan responsibility atomically, so
    /// a crash can never leave a checkpoint that skipped an unapplied event.
    public func commitCheckpoint(_ checkpoint: SyncCheckpoint, pendingPaths: [String]) throws {
        try db.transaction {
            try db.run(
                """
                INSERT INTO checkpoints(volume_id, event_id, journal_uuid) VALUES (?, ?, ?)
                ON CONFLICT(volume_id) DO UPDATE SET
                    event_id = excluded.event_id,
                    journal_uuid = excluded.journal_uuid;
                """,
                [
                    .text(checkpoint.volumeID),
                    .integer(Int64(checkpoint.eventID)),
                    checkpoint.journalUUID.map { SQLiteValue.text($0) } ?? .null,
                ]
            )
            try replacePendingPaths(checkpoint.volumeID, with: pendingPaths)
        }
    }

    public func pendingPaths(volumeID: String) throws -> [String] {
        try db.query(
            "SELECT path FROM pending_paths WHERE volume_id = ? ORDER BY rowid;",
            [.text(volumeID)]
        ).compactMap { $0.string(at: 0) }
    }

    public func setPendingPaths(volumeID: String, paths: [String]) throws {
        try db.transaction {
            try replacePendingPaths(volumeID, with: paths)
        }
    }

    /// Convenience: drops paths that have since been applied, keeping the rest.
    public func clearPendingPaths(volumeID: String, paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try db.transaction {
            for path in paths {
                try db.run(
                    "DELETE FROM pending_paths WHERE volume_id = ? AND path = ?;",
                    [.text(volumeID), .text(path)]
                )
            }
        }
    }

    // MARK: - Internals

    private func requireVolume(_ volumeID: String) throws {
        let exists = try db.query("SELECT 1 FROM volumes WHERE id = ?;", [.text(volumeID)]).first != nil
        guard exists else { throw CatalogError(kind: .unknownVolume(volumeID)) }
    }

    private func upsert(_ entry: ScannedEntry, volumeID: String, state: EntryState) throws -> Bool {
        let before = db.totalChanges
        try db.run(
            """
            INSERT INTO nodes(volume_id, relative_path, parent_path, name, name_key, path_key,
                              is_directory, is_symbolic_link, size, modified_at, file_id, state)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(volume_id, relative_path) DO UPDATE SET
                parent_path = excluded.parent_path,
                name = excluded.name,
                name_key = excluded.name_key,
                path_key = excluded.path_key,
                is_directory = excluded.is_directory,
                is_symbolic_link = excluded.is_symbolic_link,
                size = excluded.size,
                modified_at = excluded.modified_at,
                file_id = excluded.file_id,
                state = excluded.state
            WHERE nodes.name <> excluded.name
               OR nodes.name_key <> excluded.name_key
               OR nodes.path_key <> excluded.path_key
               OR nodes.is_directory <> excluded.is_directory
               OR nodes.is_symbolic_link <> excluded.is_symbolic_link
               OR nodes.size <> excluded.size
               OR nodes.modified_at <> excluded.modified_at
               OR nodes.file_id IS NOT excluded.file_id
               OR nodes.state <> excluded.state;
            """,
            [
                .text(volumeID),
                .text(entry.relativePath),
                .text(IndexText.parentPath(of: entry.relativePath)),
                .text(entry.name),
                .text(IndexText.foldedKey(entry.name)),
                .text(IndexText.foldedKey(entry.relativePath)),
                .integer(entry.isDirectory ? 1 : 0),
                .integer(entry.isSymbolicLink ? 1 : 0),
                .integer(entry.size),
                .real(entry.modifiedAt.timeIntervalSinceReferenceDate),
                entry.fileID.map { SQLiteValue.integer(Int64(bitPattern: $0)) } ?? .null,
                .integer(Int64(Self.stateValue(state))),
            ]
        )
        return db.totalChanges > before
    }

    /// Reassociates a proven direct-child rename while retaining descendant IDs.
    /// Hard links, cross-directory moves and uncertain identities remain new entries.
    private func preserveRenamedIdentity(_ entry: ScannedEntry, volumeID: String, directoryPath: String) throws -> Bool {
        guard let fileID = entry.fileID,
              try db.query("SELECT node_id FROM nodes WHERE volume_id = ? AND relative_path = ?;", [.text(volumeID), .text(entry.relativePath)]).isEmpty else { return false }
        let candidates = try db.query("""
            SELECT node_id, relative_path FROM nodes
            WHERE volume_id = ? AND parent_path = ? AND file_id = ? AND is_directory = ?
              AND relative_path NOT IN (SELECT relative_path FROM batch_paths);
            """, [.text(volumeID), .text(directoryPath), .integer(Int64(bitPattern: fileID)), .integer(entry.isDirectory ? 1 : 0)])
        guard candidates.count == 1, let oldPath = candidates[0].string(at: 1) else { return false }
        // Multiple incoming hard links sharing an inode cannot be disambiguated.
        // Existing siblings with the same inode also make identity ambiguous.
        let linked = try db.query("SELECT COUNT(*) FROM nodes WHERE volume_id = ? AND file_id = ?;", [.text(volumeID), .integer(Int64(bitPattern: fileID))]).first?.int64(at: 0)
        guard linked == 1 else { return false }
        let prefix = oldPath + "/"
        let descendants = try db.query("""
            SELECT node_id, relative_path, name FROM nodes
            WHERE volume_id = ? AND (relative_path = ? COLLATE BINARY OR substr(relative_path, 1, length(?)) = ? COLLATE BINARY);
            """, [.text(volumeID), .text(oldPath), .text(prefix), .text(prefix)])
        let updates = descendants.compactMap { row -> (Int64, String, String)? in
            guard let id = row.int64(at: 0), let path = row.string(at: 1), let name = row.string(at: 2) else { return nil }
            return (id, entry.relativePath + String(path.dropFirst(oldPath.count)), path == oldPath ? entry.name : name)
        }
        for (_, path, _) in updates {
            guard try db.query("SELECT node_id FROM nodes WHERE volume_id = ? AND relative_path = ?;", [.text(volumeID), .text(path)]).isEmpty else { return false }
        }
        for (id, path, name) in updates {
            try db.run("UPDATE nodes SET relative_path = ?, parent_path = ?, name = ?, name_key = ?, path_key = ? WHERE node_id = ?;", [.text(path), .text(IndexText.parentPath(of: path)), .text(name), .text(IndexText.foldedKey(name)), .text(IndexText.foldedKey(path)), .integer(id)])
        }
        return !updates.isEmpty
    }

    /// Marks the directory node itself as needing re-verification.
    ///
    /// `relative_path` is stored verbatim, so a scanner that spells the directory
    /// differently from its children's canonical form would otherwise be missed;
    /// the raw spelling is tried first, then the canonical one.
    private func markStale(relativePath: String, canonicalPath: String, volumeID: String) throws -> Bool {
        for candidate in [relativePath, canonicalPath] where !candidate.isEmpty {
            let before = db.totalChanges
            try db.run(
                "UPDATE nodes SET state = ? WHERE volume_id = ? AND relative_path = ?;",
                [.integer(Int64(Self.stateValue(.stale))), .text(volumeID), .text(candidate)]
            )
            if db.totalChanges > before { return true }
        }
        return false
    }

    /// Missing paths per DELETE statement.
    ///
    /// Each path costs 2 bind variables and one more level of OR-expression
    /// nesting. SQLite caps expression depth (`SQLITE_MAX_EXPR_DEPTH`, default
    /// 1000) and variable count, so a single statement cannot take a directory
    /// with thousands of vanished children.
    private static let deleteChunkSize = 150

    /// Deletes each missing child **and everything below it**.
    ///
    /// The root directory (`""`) is the special case: its subtree is the whole
    /// volume, and a `"/%"` prefix pattern would match nothing because relative
    /// paths never start with a separator.
    private func deleteSubtrees(_ paths: [String], volumeID: String) throws -> Bool {
        let before = db.totalChanges

        // A missing *root* means the whole volume subtree is gone.
        if paths.contains(where: { IndexText.canonicalRelativePath($0).isEmpty }) {
            try db.run("DELETE FROM nodes WHERE volume_id = ?;", [.text(volumeID)])
            return db.totalChanges > before
        }

        var offset = 0
        while offset < paths.count {
            let end = min(offset + Self.deleteChunkSize, paths.count)
            let chunk = paths[offset..<end]

            // One statement, OR-ed subtrees.
            //   * equality uses the verbatim stored path;
            //   * literal prefixes end in a separator, so `a/b` never includes `a/bc`;
            //   * LIKE ignores collations and folds ASCII case. BINARY equality
            //     on substr preserves case and treats wildcard characters literally.
            let predicate = Array(
                repeating: "(relative_path = ? COLLATE BINARY OR substr(relative_path, 1, length(?)) = ? COLLATE BINARY)",
                count: chunk.count
            ).joined(separator: " OR ")
            var bindings: [SQLiteValue] = [.text(volumeID)]
            for path in chunk {
                let anchor = IndexText.canonicalRelativePath(path)
                bindings.append(.text(path))
                bindings.append(.text(anchor + "/"))
                bindings.append(.text(anchor + "/"))
            }
            try db.run("DELETE FROM nodes WHERE volume_id = ? AND (\(predicate));", bindings)

            offset = end
        }
        return db.totalChanges > before
    }

    private func replacePendingPaths(_ volumeID: String, with paths: [String]) throws {
        try db.run("DELETE FROM pending_paths WHERE volume_id = ?;", [.text(volumeID)])
        for path in paths {
            try db.run(
                "INSERT OR REPLACE INTO pending_paths(volume_id, path) VALUES (?, ?);",
                [.text(volumeID), .text(path)]
            )
        }
    }

    // MARK: - Row mapping

    static let entryColumns = """
        SELECT node_id, volume_id, relative_path, name, is_directory, is_symbolic_link,
               size, modified_at, file_id, state
        FROM nodes
        """

    /// Row mapping shared by the streaming reader and the legacy buffered reader
    /// (the latter only survives as a benchmark baseline; see `readEntries`).
    static func entry(from row: SQLiteRow) -> IndexedEntry? {
        guard let nodeID = row.int64(at: 0),
              let volumeID = row.string(at: 1),
              let relativePath = row.string(at: 2),
              let name = row.string(at: 3),
              let modifiedAt = row.double(at: 7) else { return nil }
        return IndexedEntry(
            key: EntryKey(volumeID: volumeID, nodeID: nodeID),
            relativePath: relativePath,
            name: name,
            isDirectory: row.int64(at: 4) == 1,
            isSymbolicLink: row.int64(at: 5) == 1,
            size: row.int64(at: 6) ?? 0,
            modifiedAt: Date(timeIntervalSinceReferenceDate: modifiedAt),
            fileID: row.int64(at: 8).map { UInt64(bitPattern: $0) },
            state: stateValue(for: row.int64(at: 9) ?? 0)
        )
    }

    static func volume(from row: SQLiteRow) -> VolumeRecord? {
        guard let id = row.string(at: 0),
              let name = row.string(at: 1),
              let rootPath = row.string(at: 2),
              let fileSystem = row.string(at: 3) else { return nil }
        return VolumeRecord(
            id: id,
            name: name,
            rootPath: rootPath,
            fileSystem: fileSystem,
            volumeUUID: row.string(at: 4),
            isOnline: row.int64(at: 5) == 1,
            requiresFullVerification: row.int64(at: 6) == 1,
            lastVerifiedAt: row.double(at: 7).map(Date.init(timeIntervalSinceReferenceDate:))
        )
    }

    private static func stateValue(_ state: EntryState) -> Int {
        switch state {
        case .current: return 0
        case .stale: return 1
        case .unknown: return 2
        }
    }

    static func stateValue(for raw: Int64) -> EntryState {
        switch raw {
        case 1: return .stale
        case 2: return .unknown
        default: return .current
        }
    }
}
