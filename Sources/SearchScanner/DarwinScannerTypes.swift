import DarwinScanner
import Foundation

/// Identity of a filesystem as reported by `statfs(2)`.
///
/// Two paths share an index scope only when this matches, which is how
/// "never cross a physical mount" is enforced. `f_fsid` is used rather than
/// `st_dev` because APFS firmlinks such as `/Users` and `/Applications` report
/// a different `st_dev` than `/` while belonging to the same volume.
struct FileSystemIdentity: Equatable, Sendable {
    var fsIDHi: Int64
    var fsIDLo: Int64
    /// Raw `f_fstypename` (`apfs`, `hfs`, `msdos`, `exfat`, `nfs`, ...).
    ///
    /// Reported verbatim. Nothing here infers whether a volume is solid state
    /// or rotational: `apfs` is used for both SSD and spinning media, and a
    /// guess would let a caller size its concurrency off a lie.
    var fileSystemName: String

    static func == (lhs: FileSystemIdentity, rhs: FileSystemIdentity) -> Bool {
        lhs.fsIDHi == rhs.fsIDHi && lhs.fsIDLo == rhs.fsIDLo
    }
}

/// The vnode type `ATTR_CMN_OBJTYPE` reports.
///
/// These are the kernel's `VREG`/`VDIR`/`VLNK` codes, not the `DT_*` codes
/// `readdir(3)` uses. The two numbering schemes collide in meaning, and reading
/// bulk data with the `DT_*` assumption makes every directory look like a
/// regular file, so the walk silently never descends.
enum DirectoryObjectType: Sendable {
    case unknown
    case regular
    case directory
    case symbolicLink
    case other

    init(raw: UInt32) {
        switch raw {
        case DARWIN_VREG: self = .regular
        case DARWIN_VDIR: self = .directory
        case DARWIN_VLNK: self = .symbolicLink
        default: self = .other
        }
    }

    /// True for the codes the kernel legitimately uses for a directory entry.
    static func isKnownVnodeType(_ raw: UInt32) -> Bool {
        switch raw {
        case DARWIN_VREG, DARWIN_VDIR, DARWIN_VCHR, DARWIN_VBLK,
             DARWIN_VLNK, DARWIN_VSOCK, DARWIN_VFIFO, DARWIN_VWHT:
            return true
        default:
            return false
        }
    }
}

/// One decoded directory child, independent of which reader produced it.
struct DirectoryEntry: Sendable {
    var name: String
    var type: DirectoryObjectType
    var size: Int64
    var modifiedAt: Date
    var fileID: UInt64?
    /// The filesystem this child belongs to, inherited from the directory it
    /// was listed in.
    var fileSystem: FileSystemIdentity
    var isMountPoint: Bool
    /// Non-zero when this specific child could not be described (a failed
    /// `fstatat`, or a bulk record whose error attribute was set).
    var errorCode: Int32
    /// False when at least one requested attribute was unavailable, or the
    /// name was not valid UTF-8. The entry is dropped rather than invented,
    /// and the listing is reported incomplete so nothing is pruned on it.
    var isFullyDescribed: Bool

    var isDirectory: Bool { type == .directory }
    var isSymbolicLink: Bool { type == .symbolicLink }
    /// True when this child is unusable as an index entry.
    var hasUnresolvedMetadata: Bool { errorCode != 0 || !isFullyDescribed }

    /// The errno to report when this entry forces the listing to be reported
    /// as incomplete. Nil when the entry described itself cleanly.
    var failureCode: Int32? {
        guard hasUnresolvedMetadata else { return nil }
        return errorCode != 0 ? errorCode : EILSEQ
    }

    /// A directory we are willing to descend into: never a symbolic link,
    /// always fully described, and always on the scan root's filesystem.
    func isTraversable(from root: FileSystemIdentity) -> Bool {
        isDirectory && !isSymbolicLink && fileSystem == root && !hasUnresolvedMetadata
    }
}

struct DirectoryReadResult: Sendable {
    var entries: [DirectoryEntry]
    /// Non-zero when the listing is partial; nothing may be deleted on its
    /// strength.
    var failureCode: Int32
    /// Which reader produced this, so a caller can tell a bulk result from a
    /// fallback one. Bulk and fallback must agree; the tests check that.
    var usedBulkReader: Bool
}

enum DirectoryReadError: Error, Sendable {
    case openFailed(path: String, code: Int32)
}

/// Reads one directory through the Darwin bridge, preferring `getattrlistbulk`
/// and falling back to a `readdir` + `fstatat` cursor.
///
/// Fallback is unconditional on bulk failure rather than selective on errno.
/// `ENOTSUP`, `EINVAL`, `EOPNOTSUPP` and friends say the bulk path cannot serve
/// this directory, not that the directory is unreadable — and a bulk failure is
/// never reported as an empty directory. Only the cursor is authoritative about
/// what really happened, so every failure path defers to it.
enum DirectoryReader {
    /// Chunk size for the fallback cursor. Small enough to stay cache friendly
    /// on a mechanical disk, large enough to keep syscall overhead low.
    static let fallbackChunkSize = 512

    /// Diagnostic: whether the bulk decoder reads this machine's real
    /// directories coherently. Reported, never used to quietly disable bulk —
    /// a parser that cannot read a directory is a defect worth surfacing.
    static var bulkDecoderIsCoherent: Bool { darwin_bulk_probe() == 1 }

    /// Reads `path` and returns its direct children in filesystem order.
    ///
    /// - Parameter identity: the `statfs` identity of `path` itself. Children
    ///   inherit it, which is both cheaper and more reliable than asking the
    ///   bulk reader for a per-child filesystem identity.
    /// - Throws: ``DirectoryReadError/openFailed(code:)`` when the directory
    ///   itself cannot be opened, which is the signal to emit an incomplete
    ///   batch rather than an empty complete one.
    static func read(
        path: String,
        identity: FileSystemIdentity,
        preferBulk: Bool = true
    ) throws -> DirectoryReadResult {
        if preferBulk, let bulk = readWithBulkReader(path: path, identity: identity) {
            return bulk
        }
        return try readWithCursor(path: path, identity: identity)
    }

    // MARK: - getattrlistbulk

    /// Returns nil when the bulk path cannot serve this directory for any
    /// reason: refusal by the kernel, a record that did not decode coherently,
    /// or a directory larger than the in-C byte cap. Never returns an empty
    /// result for a failure — an empty result is only ever produced by a
    /// successful read of a genuinely empty directory.
    private static func readWithBulkReader(
        path: String, identity: FileSystemIdentity
    ) -> DirectoryReadResult? {
        var items: UnsafeMutablePointer<darwin_bulk_item>?
        var count: UInt32 = 0
        let status = path.withCString { cPath in
            darwin_directory_read_all(cPath, &items, &count)
        }
        defer { if let items { darwin_directory_free(items) } }
        if status < 0 {
            return nil
        }
        if status == 0 {
            // A successful read of a directory that has no children.
            return DirectoryReadResult(
                entries: [], failureCode: 0, usedBulkReader: true)
        }
        guard let items, count > 0 else {
            return nil
        }

        let buffer = UnsafeBufferPointer(start: items, count: Int(count))
        var entries: [DirectoryEntry] = []
        var failures: [Int32] = []
        entries.reserveCapacity(buffer.count)
        for item in buffer {
            let entry = convert(item, identity: identity)
            if entry.hasUnresolvedMetadata, let code = entry.failureCode {
                failures.append(code)
            }
            entries.append(entry)
        }
        return DirectoryReadResult(
            entries: entries,
            failureCode: failures.first ?? 0,
            usedBulkReader: true)
    }

    private static func convert(
        _ item: darwin_bulk_item, identity: FileSystemIdentity
    ) -> DirectoryEntry {
        let nameLength = Int(item.name_length)
        // The C decoder already rejected anything that is not valid UTF-8, so
        // this conversion is lossless. There is deliberately no
        // replacement-character fallback: a name that cannot be represented
        // faithfully has no String form worth indexing.
        let name = withUnsafeBytes(of: item.name) { raw -> String in
            guard nameLength > 0 else { return "" }
            return String(
                decoding: raw.bindMemory(to: UInt8.self)[0..<nameLength],
                as: UTF8.self)
        }
        let failed =
            (item.flags & (DARWIN_ITEM_STAT_FAILED | DARWIN_ITEM_UTF8_REJECTED)) != 0
        return DirectoryEntry(
            name: name,
            type: DirectoryObjectType(raw: item.object_type),
            size: item.size,
            modifiedAt: Date(timeIntervalSince1970: Double(item.modified_at)),
            fileID: item.file_id != 0 ? item.file_id : nil,
            fileSystem: identity,
            isMountPoint: (item.flags & DARWIN_ITEM_IS_MOUNT_POINT) != 0,
            errorCode: item.error != 0 ? Int32(bitPattern: item.error) : 0,
            isFullyDescribed: !failed)
    }

    // MARK: - readdir + fstatat

    private static func readWithCursor(
        path: String, identity: FileSystemIdentity
    ) throws -> DirectoryReadResult {
        guard let handle = path.withCString({ darwin_directory_open($0) }) else {
            throw DirectoryReadError.openFailed(
                path: path, code: Int32(errno == 0 ? EIO : errno))
        }
        defer { darwin_directory_close(handle) }

        let capacity = UInt32(fallbackChunkSize)
        let buffer = UnsafeMutablePointer<darwin_bulk_item>.allocate(capacity: Int(capacity))
        defer {
            buffer.deinitialize(count: Int(capacity))
            buffer.deallocate()
        }

        var entries: [DirectoryEntry] = []
        var failures: [Int32] = []
        var failure: Int32 = 0
        while true {
            var produced: UInt32 = 0
            var readErrno: Int32 = 0
            let status = darwin_directory_next(
                handle, buffer, capacity, &produced, &readErrno)
            if produced > 0 {
                let slice = UnsafeBufferPointer(start: buffer, count: Int(produced))
                entries.reserveCapacity(entries.count + slice.count)
                for item in slice {
                    let entry = convert(item, identity: identity)
                    if entry.hasUnresolvedMetadata, let code = entry.failureCode {
                        failures.append(code)
                    }
                    entries.append(entry)
                }
            }
            if status != 0 {
                // 1 means the directory is exhausted; a negative status is a
                // genuine failure that must not be mistaken for "done".
                failure = status < 0 ? -status : readErrno
                break
            }
        }

        if failure == 0, let first = failures.first { failure = first }
        return DirectoryReadResult(
            entries: entries, failureCode: failure, usedBulkReader: false)
    }

    // MARK: - Mount identity

    /// `statfs(2)` identity of `path`, or nil when it cannot be resolved.
    static func fileSystemIdentity(ofPath path: String) -> FileSystemIdentity? {
        var errorCode: Int32 = 0
        return fileSystemIdentity(ofPath: path, errorCode: &errorCode)
    }

    /// `statfs(2)` identity of `path`, reporting why it could not be resolved.
    ///
    /// The distinction matters to the scanner: "this path is on another
    /// filesystem" justifies skipping it silently, while "I could not tell
    /// which filesystem this is" does not — that is an unreadable scope, and
    /// reporting it is what keeps its index records alive.
    static func fileSystemIdentity(
        ofPath path: String, errorCode: inout Int32
    ) -> FileSystemIdentity? {
        var fsIDHi: Int64 = 0
        var fsIDLo: Int64 = 0
        var nameBuffer = [CChar](repeating: 0, count: 32)
        errorCode = 0
        let status = nameBuffer.withUnsafeMutableBufferPointer { buffer -> Int32 in
            path.withCString { cPath in
                darwin_statfs_identity(
                    cPath, &fsIDHi, &fsIDLo, buffer.baseAddress, UInt32(buffer.count))
            }
        }
        guard status == 0 else {
            errorCode = -status > 0 ? -status : EIO
            return nil
        }
        let name = String(cString: nameBuffer)
        return FileSystemIdentity(
            fsIDHi: fsIDHi, fsIDLo: fsIDLo,
            fileSystemName: name.isEmpty ? "unknown" : name)
    }

    /// `dev_t` of the filesystem `path` lives on, or 0 when unresolvable.
    static func deviceID(ofPath path: String) -> dev_t {
        path.withCString { cPath in
            dev_t(darwin_device_id(cPath))
        }
    }
}