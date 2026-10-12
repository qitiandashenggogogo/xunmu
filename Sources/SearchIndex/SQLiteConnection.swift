import CSQLite
import Foundation

/// Error surfaced by the index layer. Carries the SQLite result code so callers can
/// distinguish "unknown volume" style programming errors from real database faults.
public struct CatalogError: Error, CustomStringConvertible, Sendable {
    public enum Kind: Sendable {
        case open(path: String, message: String)
        case sqlite(code: Int32, message: String, statement: String)
        case unknownVolume(String)
    }

    public let kind: Kind

    public var description: String {
        switch kind {
        case .open(let path, let message):
            return "无法打开索引数据库 (\(path)): \(message)"
        case .sqlite(let code, let message, let statement):
            return "SQLite 错误 \(code): \(message) [\(statement)]"
        case .unknownVolume(let id):
            return "未注册的索引范围: \(id)"
        }
    }
}

/// A single SQLite bindable value.
enum SQLiteValue: Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
}

/// Typed, allocation-free view over the current row of a stepping statement.
/// Valid only for the duration of the `forEachRow` body call.
struct SQLiteRowReader {
    fileprivate let statement: OpaquePointer

    func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    func double(_ column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    func bool(_ column: Int32) -> Bool {
        sqlite3_column_int64(statement, column) != 0
    }

    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    func optionalUInt64(_ column: Int32) -> UInt64? {
        guard !isNull(column) else { return nil }
        return UInt64(bitPattern: sqlite3_column_int64(statement, column))
    }

    func string(_ column: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: cString)
    }

    func optionalString(_ column: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: cString)
    }
}

/// Legacy row wrapper, kept for the small administrative queries (`volumes`,
/// `checkpoint`, `pendingPaths`) where row counts are tiny.
struct SQLiteRow {
    let values: [SQLiteValue]

    subscript(index: Int) -> SQLiteValue? {
        get { values[index] }
    }

    func string(at index: Int) -> String? {
        if case .text(let value) = values[index] { return value }
        return nil
    }

    func int64(at index: Int) -> Int64? {
        switch values[index] {
        case .integer(let value): return value
        case .real(let value): return Int64(value)
        case .text(let value): return Int64(value)
        case .null: return nil
        }
    }

    func double(at index: Int) -> Double? {
        switch values[index] {
        case .integer(let value): return Double(value)
        case .real(let value): return value
        case .text(let value): return Double(value)
        case .null: return nil
        }
    }
}

/// Minimal, dependency-free SQLite wrapper.
///
/// **All access to the handle is serialized by `lock`.** `SQLITE_OPEN_FULLMUTEX`
/// only serializes calls *into* SQLite; it does nothing for Swift-side state, and it
/// does nothing about the same cached statement being stepped from two call sites at
/// once. That matters because `CatalogReader` is a `Sendable` struct holding a class
/// reference: copies share one connection, so the lock has to live here, on the
/// connection, rather than on the handle value. The lock is recursive so a
/// transaction body can call back into the same connection.
final class SQLiteConnection: @unchecked Sendable {
    enum Access {
        /// Read-write, creating the file if needed. Runs schema setup.
        case readWriteCreate
        /// Read-only: never creates the database file and never writes to it.
        ///
        /// This does **not** mean "touches nothing on disk": SQLite still maintains
        /// the `-wal` / `-shm` sidecars for a WAL database, and a read-only connection
        /// may create or update them. Use `.staticImmutable` only when the caller can
        /// guarantee no concurrent writer and no pending WAL content.
        case readOnly
        /// Immutable read: read-only, no locking, and no `-wal` / `-shm` sidecars.
        ///
        /// Refuses to open a database whose `-wal` still holds unmerged content —
        /// the guarantee belongs here, not in the caller. It still cannot detect a
        /// concurrent writer; that responsibility stays with the caller.
        case staticImmutable
    }

    private let lock = NSRecursiveLock()
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    init(url: URL, access: Access = .readWriteCreate) throws {
        let flags: Int32
        var openTarget = url.path
        switch access {
        case .readWriteCreate:
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        case .readOnly:
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        case .staticImmutable:
            // The constructor itself refuses a database with committed WAL content:
            // relying on the caller to have run the check first is exactly the kind of
            // thing that silently rots. Callers may still want to check *earlier* to
            // report a friendly state, but the hard gate lives here.
            try Self.requireNoCommittedWAL(url)
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
            openTarget = Self.immutableURI(for: url)
        }
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(openTarget, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            if let db { sqlite3_close_v2(db) }
            throw CatalogError(kind: .open(path: url.path, message: message))
        }
        handle = db
        if access == .staticImmutable {
            try run("PRAGMA query_only = 1;")
            return
        }
        // busy_timeout is a connection setting, safe in both writable modes.
        try run("PRAGMA busy_timeout = 5000;")
        guard access == .readWriteCreate else { return }
        // WAL keeps readers (the UI snapshot loader) from blocking the single writer.
        try run("PRAGMA journal_mode = WAL;")
        try run("PRAGMA synchronous = NORMAL;")
        try run("PRAGMA foreign_keys = ON;")
    }

    // MARK: - Sidecar paths

    /// SQLite keeps WAL/journal bookkeeping next to the database, by appending a
    /// suffix to the **full path**: `catalog.sqlite-wal`, not
    /// `catalog.sqlite.sqlite-wal`. Building this with `appendingPathExtension`
    /// silently produces the wrong filename and makes every safety check vacuously
    /// return "safe".
    nonisolated static func sidecarURL(_ url: URL, suffix: String) -> URL {
        URL(fileURLWithPath: url.path + suffix)
    }

    /// Size of the `-wal` sidecar, or 0 when it does not exist.
    nonisolated static func walSize(_ url: URL) throws -> Int {
        let wal = sidecarURL(url, suffix: "-wal")
        guard FileManager.default.fileExists(atPath: wal.path) else { return 0 }
        let attributes = try FileManager.default.attributesOfItem(atPath: wal.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw CatalogError(kind: .open(path: url.path, message: "无法读取 WAL 旁件大小"))
        }
        return size.intValue
    }

    /// Whether the database file itself exists and is readable.
    ///
    /// A missing or unreadable main file can never be opened, let alone opened
    /// immutably, so it must not report "available" just because no `-wal` was found.
    nonisolated static func isDatabaseReadable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        guard !isDirectory.boolValue else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    /// True when the database has no *committed* WAL content and the main file is
    /// readable.
    ///
    /// This is a **necessary but not sufficient** condition for an immutable open: an
    /// empty `-wal` proves nothing is pending, and a readable file proves it exists —
    /// neither proves that no other process is about to write. Nothing local can
    /// prove that. In particular, an unmounted volume or a paused scanner is **not**
    /// such a guarantee: another process (a second app instance, a backup tool, a
    /// mount-time migration) may still be writing. Establishing quiescence is the
    /// caller's responsibility, typically by holding an exclusive lock the writer
    /// also respects.
    static func isStaticImmutableSafe(databaseURL: URL) -> Bool {
        isDatabaseReadable(databaseURL) && (try? walSize(databaseURL)) == 0
    }

    /// Hard gate used by the `.staticImmutable` constructor.
    private static func requireNoCommittedWAL(_ url: URL) throws {
        let size = try walSize(url)
        guard size == 0 else {
            throw CatalogError(
                kind: .open(
                    path: url.path,
                    message: "索引存在 \(size) 字节未合并的 WAL 内容，拒绝以不可变模式只读打开；请先完成 checkpoint 或改用普通只读打开"
                )
            )
        }
    }

    // MARK: - Immutable URI

    /// Builds the real `file:…?immutable=1` URI.
    ///
    /// `SQLITE_OPEN_URI` alone does nothing: SQLite only URI-decodes names that start
    /// with `file:`. A bare path is treated as a literal filename, which is why the
    /// previous version silently degraded to an ordinary read-only open.
    ///
    /// The path must be percent-encoded, otherwise `#` starts a fragment, `?` starts
    /// the query, and a literal `%` starts an escape — any of which corrupts a real
    /// index file name. Non-ASCII (Chinese) names are encoded byte by byte in UTF-8.
    nonisolated static func immutableURI(for url: URL) -> String {
        "file:" + percentEncodePath(url.path) + "?immutable=1"
    }

    /// Percent-encodes everything except the RFC 3986 unreserved set plus `/`,
    /// which must stay literal so the path structure survives.
    nonisolated static func percentEncodePath(_ path: String) -> String {
        let unreserved: Set<UInt8> = Set(
            Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/".utf8)
        )
        let hexDigits = Array("0123456789ABCDEF".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(path.utf8.count)
        for byte in path.utf8 {
            if unreserved.contains(byte) {
                out.append(byte)
            } else {
                out.append(UInt8(ascii: "%"))
                out.append(hexDigits[Int(byte >> 4)])
                out.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    deinit {
        lock.lock()
        defer { lock.unlock() }
        for statement in statements.values { sqlite3_finalize(statement) }
        if let handle { sqlite3_close_v2(handle) }
    }

    var lastInsertRowID: Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return 0 }
        return sqlite3_last_insert_rowid(handle)
    }

    /// Rows changed by the **most recently completed** DML statement.
    ///
    /// Do NOT use this to detect "did my statement change anything": a statement
    /// resets the value on each DML statement, so comparing two statements'
    /// counts silently misses updates (a 2-row UPDATE after a
    /// 5-row UPDATE reads as 2 > 5 == false). Use `totalChanges` for that.
    var changes: Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return 0 }
        return sqlite3_changes(handle)
    }

    /// Monotonic count of every row changed since the connection was opened.
    /// Differences across a single statement are the reliable change signal.
    ///
    /// Int64 on purpose: this counter is never reset, so a long-lived catalog
    /// connection would eventually wrap an Int32 and make every change look like
    /// "no change".
    var totalChanges: Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return 0 }
        return sqlite3_total_changes64(handle)
    }

    /// Executes a statement that returns no rows.
    func run(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, bindings)
        defer { finish(statement) }
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw makeError(code: rc, sql: sql)
        }
    }

    /// Executes a statement that returns rows.
    func query(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, bindings)
        defer { finish(statement) }
        var rows: [SQLiteRow] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_ROW {
                rows.append(SQLiteRow(values: readRow(statement)))
                continue
            }
            if rc == SQLITE_DONE { break }
            throw makeError(code: rc, sql: sql)
        }
        return rows
    }

    /// Streams rows straight into `body` without materializing intermediate
    /// `[SQLiteRow]` / `[SQLiteValue]` values.
    ///
    /// This is the hot path for loading a million-row catalog: the old
    /// `query(_:_:)` allocated one enum payload per non-nil column (≈10 per row)
    /// before a `compactMap` threw them all away again. Decoding straight from the
    /// statement keeps exactly one `String` allocation per text column and none
    /// for integers, reals and NULLs.
    func forEachRow(
        _ sql: String,
        _ bindings: [SQLiteValue] = [],
        _ body: (SQLiteRowReader) throws -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql, bindings)
        defer { finish(statement) }
        let reader = SQLiteRowReader(statement: statement)
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_ROW {
                try body(reader)
                continue
            }
            if rc == SQLITE_DONE { break }
            throw makeError(code: rc, sql: sql)
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        // The lock is taken *before* BEGIN. Taking it afterwards leaves a window in
        // which two threads each issue a successful BEGIN, and the loser's ROLLBACK
        // then unwinds the winner's transaction. The lock is recursive, so the body's
        // own statements re-enter it on this thread while other threads stay out for
        // the whole transaction.
        lock.lock()
        defer { lock.unlock() }
        try run("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let value = try body()
            try run("COMMIT;")
            return value
        } catch {
            // Best effort rollback: a failure here must not mask the original error.
            try? run("ROLLBACK;")
            throw error
        }
    }

    /// Read-only transaction.
    ///
    /// `BEGIN DEFERRED` is deliberate and must not be upgraded to `IMMEDIATE`: a
    /// deferred transaction takes no lock until the first read, then holds a
    /// consistent snapshot for its duration. That is exactly what a snapshot load
    /// needs, and it never blocks (or is blocked by) the single writer. In WAL mode
    /// the snapshot is pinned to the state at the first read, so generation, volumes
    /// and entries can never straddle two generations.
    func readTransaction<T>(_ body: () throws -> T) throws -> T {
        // Same ordering requirement as `transaction`: lock first, then BEGIN.
        lock.lock()
        defer { lock.unlock() }
        try run("BEGIN DEFERRED;")
        do {
            let value = try body()
            try run("COMMIT;")
            return value
        } catch {
            try? run("ROLLBACK;")
            throw error
        }
    }

    private func prepare(_ sql: String, _ bindings: [SQLiteValue]) throws -> OpaquePointer {
        guard let handle else {
            throw CatalogError(kind: .sqlite(code: SQLITE_MISUSE, message: "连接已关闭", statement: sql))
        }
        let statement: OpaquePointer
        if let cached = statements[sql] { statement = cached }
        else {
            if statements.count >= 128 {
                for cached in statements.values { sqlite3_finalize(cached) }
                statements.removeAll(keepingCapacity: true)
            }
            var prepared: OpaquePointer?
            let rc = sqlite3_prepare_v2(handle, sql, -1, &prepared, nil)
            guard rc == SQLITE_OK, let prepared else {
                if let prepared { sqlite3_finalize(prepared) }
                throw makeError(code: rc, sql: sql)
            }
            statements[sql] = prepared
            statement = prepared
        }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let bindRC: Int32
            switch binding {
            case .null:
                bindRC = sqlite3_bind_null(statement, index)
            case .integer(let value):
                bindRC = sqlite3_bind_int64(statement, index, value)
            case .real(let value):
                bindRC = sqlite3_bind_double(statement, index, value)
            case .text(let value):
                // SQLITE_TRANSIENT = -1: SQLite copies the bytes, so the temporary
                // Swift String buffer may die as soon as this call returns.
                bindRC = sqlite3_bind_text(
                    statement, index, value, -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }
            if bindRC != SQLITE_OK {
                finish(statement)
                throw makeError(code: bindRC, sql: sql)
            }
        }
        return statement
    }

    private func finish(_ statement: OpaquePointer) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    private func readRow(_ statement: OpaquePointer) -> [SQLiteValue] {
        let count = Int(sqlite3_column_count(statement))
        var values: [SQLiteValue] = []
        values.reserveCapacity(count)
        for column in 0..<count {
            switch sqlite3_column_type(statement, Int32(column)) {
            case SQLITE_INTEGER:
                values.append(.integer(sqlite3_column_int64(statement, Int32(column))))
            case SQLITE_FLOAT:
                values.append(.real(sqlite3_column_double(statement, Int32(column))))
            case SQLITE_TEXT:
                if let cString = sqlite3_column_text(statement, Int32(column)) {
                    values.append(.text(String(cString: cString)))
                } else {
                    values.append(.null)
                }
            default:
                values.append(.null)
            }
        }
        return values
    }

    private func makeError(code: Int32, sql: String) -> CatalogError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
        return CatalogError(kind: .sqlite(code: code, message: message, statement: sql))
    }
}
