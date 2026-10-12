import DarwinScanner
import Foundation
import SearchCore

/// Walks a registered index root and streams one ``DirectoryBatch`` per
/// directory to the caller.
///
/// Design constraints baked in here:
/// - Single task, single directory at a time. Mechanical disks are the default
///   target and saturating them with parallel readers makes the scan slower,
///   not faster, so the pipeline is deliberately serial. Backpressure comes
///   from awaiting `onBatch` per directory.
/// - Symbolic links are reported but never followed, so a link cycle cannot
///   trap the walk.
/// - The walk stops at a filesystem boundary: only children whose `statfs`
///   identity matches the scan root are descended.
/// - A directory that could not be enumerated produces a batch with
///   `isComplete == false`, which is the contract's signal that existing index
///   records underneath it must be preserved rather than pruned.
public struct DirectoryScanner: Sendable {
    /// Absolute paths whose subtrees are omitted entirely, used to keep the
    /// application's own database and cache out of the index it maintains.
    ///
    /// Entries are dropped from their parent's listing rather than marked
    /// incomplete, so the exclusion stays invisible to the index and never
    /// causes a delete-by-absence.
    public let excludedPaths: [String]

    public init(excludedPaths: [String] = []) {
        self.excludedPaths = excludedPaths.map(DirectoryScanner.normalizeAbsolutePath)
    }

    public enum ScanError: Error, Equatable, Sendable {
        /// The registered root itself is gone or is no longer a directory.
        case rootUnavailable(path: String)
        /// `startingAt` named a path outside the registered root.
        case startOutsideRoot(relativePath: String)
    }

    /// Scans `volume` and streams each directory's direct children to
    /// `onBatch`, awaiting it before moving on.
    ///
    /// - Parameters:
    ///   - startingAt: Relative paths to enumerate instead of the whole root.
    ///     `[""]` means the root. An empty array is treated the same way. This
    ///     is what makes a resumed or a partial (补扫) scan possible.
    ///   - recursive: When false only the directories named in `startingAt`
    ///     are enumerated; their children are reported but not descended.
    /// - Throws: `CancellationError` when the surrounding task is cancelled,
    ///   `ScanError` when the root is unusable or a start path escapes the
    ///   root. Per-directory failures are reported through the batch instead.
    public func scan(
        volume: VolumeRecord,
        startingAt: [String] = [""],
        recursive: Bool = true,
        onBatch: @escaping @Sendable (DirectoryBatch) async throws -> Void
    ) async throws {
        let rootPath = DirectoryScanner.normalizeAbsolutePath(volume.rootPath)
        guard let rootIdentity = DirectoryReader.fileSystemIdentity(ofPath: rootPath) else {
            throw ScanError.rootUnavailable(path: rootPath)
        }

        let roots = startingAt.isEmpty ? [""] : startingAt
        // Depth first, children in the order the filesystem reported them.
        var pending: [String] = []
        for start in roots.reversed() {
            pending.append(DirectoryScanner.normalizeRelative(start))
        }

        let excluded = excludedPaths

        while !pending.isEmpty {
            try Task.checkCancellation()

            let relative = pending.removeLast()
            let absolute = relative.isEmpty ? rootPath : rootPath + "/" + relative
            guard !relative.split(separator: "/").contains("..") else {
                throw ScanError.startOutsideRoot(relativePath: relative)
            }
            if DirectoryScanner.isExcluded(absolute, excluded: excluded) { continue }

            // Re-checked at pop time so a volume mounted between reading the
            // parent and descending here is still not crossed, and so a
            // directory that became unreadable is reported instead of quietly
            // vanishing from the walk.
            var identityError: Int32 = 0
            guard
                let identity = DirectoryReader.fileSystemIdentity(
                    ofPath: absolute, errorCode: &identityError)
            else {
                // "I could not tell which filesystem this is" is not the same
                // answer as "this is another filesystem". Silently continuing
                // here would leave a pending directory unvisited and
                // unreported, which is precisely how a scan under-covers
                // without anyone noticing. Report it as incomplete so the index
                // keeps its records and the caller can retry.
                let code = identityError == 0 ? EIO : identityError
                if relative.isEmpty, DirectoryScanner.isRootLoss(code) {
                    throw ScanError.rootUnavailable(path: rootPath)
                }
                try await onBatch(
                    DirectoryBatch(
                        volumeID: volume.id,
                        directoryRelativePath: relative,
                        entries: [],
                        isComplete: false,
                        issue: DirectoryScanner.issue(for: relative, code: code)))
                continue
            }
            guard identity == rootIdentity else {
                // Definitely another filesystem: a mounted volume sitting
                // inside the root. Nothing under it belongs to this scope, and
                // omitting it is safe because no batch was ever emitted for it.
                continue
            }

            let result: DirectoryReadResult
            do {
                result = try DirectoryReader.read(path: absolute, identity: identity)
            } catch let error as DirectoryReadError {
                guard case .openFailed(_, let code) = error else {
                    try await onBatch(
                        DirectoryBatch(
                            volumeID: volume.id,
                            directoryRelativePath: relative,
                            entries: [],
                            isComplete: false,
                            issue: DirectoryScanner.issue(for: relative, code: EIO)))
                    continue
                }
                if relative.isEmpty, DirectoryScanner.isRootLoss(code) {
                    throw ScanError.rootUnavailable(path: rootPath)
                }
                try await onBatch(
                    DirectoryBatch(
                        volumeID: volume.id,
                        directoryRelativePath: relative,
                        entries: [],
                        isComplete: false,
                        issue: DirectoryScanner.issue(for: relative, code: code)))
                continue
            }

            let conversion = DirectoryScanner.convert(
                result.entries,
                directory: relative,
                root: rootPath,
                identity: identity,
                excluded: excluded)

            try Task.checkCancellation()

            let isComplete = result.failureCode == 0 && conversion.failedChildren.isEmpty
            try await onBatch(
                DirectoryBatch(
                    volumeID: volume.id,
                    directoryRelativePath: relative,
                    entries: conversion.entries,
                    isComplete: isComplete,
                    issue: isComplete ? nil : DirectoryScanner.issue(
                        for: relative,
                        code: result.failureCode != 0
                            ? result.failureCode
                            : (conversion.failedChildren.first ?? EIO))))

            guard recursive else { continue }
            for child in conversion.childDirectories.reversed() {
                pending.append(child)
            }
        }
    }

    // MARK: - Conversion

    private struct Conversion {
        var entries: [ScannedEntry]
        var childDirectories: [String]
        /// First errno of a child that could not be described, if any.
        var failedChildren: [Int32]
    }

    private static func convert(
        _ raw: [DirectoryEntry],
        directory relative: String,
        root rootPath: String,
        identity: FileSystemIdentity,
        excluded: [String]
    ) -> Conversion {
        var entries: [ScannedEntry] = []
        var children: [String] = []
        var failures: [Int32] = []
        entries.reserveCapacity(raw.count)

        for child in raw {
            let childPath = relative.isEmpty ? child.name : relative + "/" + child.name
            if isExcluded(rootPath + "/" + childPath, excluded: excluded) {
                continue
            }
            if let failure = child.failureCode {
                // The child is still worth reporting if we know what it is, but
                // the listing is no longer complete, so nothing may be pruned
                // on its strength.
                failures.append(failure)
                if child.name.isEmpty { continue }
            }
            entries.append(
                ScannedEntry(
                    relativePath: childPath,
                    name: child.name,
                    isDirectory: child.isDirectory,
                    isSymbolicLink: child.isSymbolicLink,
                    size: child.size,
                    modifiedAt: child.modifiedAt,
                    fileID: child.fileID))
        }

        // Only same-filesystem directories, and never a symbolic link, so the
        // walk cannot escape the registered root or enter a link cycle. Excluded
        // subtrees are skipped here as well as in the listing above, otherwise
        // an excluded directory would still have its contents scanned.
        for child in raw where !child.hasUnresolvedMetadata {
            guard child.isTraversable(from: identity) else { continue }
            let childPath = relative.isEmpty ? child.name : relative + "/" + child.name
            if isExcluded(rootPath + "/" + childPath, excluded: excluded) { continue }
            children.append(childPath)
        }

        return Conversion(
            entries: entries, childDirectories: children, failedChildren: failures)
    }

    // MARK: - Paths

    /// Removes redundant separators and any trailing slash except for "/".
    static func normalizeAbsolutePath(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        if standardized.count > 1, standardized.hasSuffix("/") {
            return String(standardized.dropLast())
        }
        return standardized
    }

    /// Relative scope paths arrive as "", "a/b", "/a/b", "a/b/" or "./a".
    /// They all collapse to the "" or "a/b" forms the index stores.
    static func normalizeRelative(_ path: String) -> String {
        var value = path
        while value.hasPrefix("./") { value.removeFirst(2) }
        while value.hasPrefix("/") { value.removeFirst(1) }
        while value.hasSuffix("/") && !value.isEmpty { value.removeLast() }
        return value
    }

    /// Path boundary match: `/data/backup` must not exclude `/data/backups`.
    static func isExcluded(_ path: String, excluded: [String]) -> Bool {
        for prefix in excluded {
            if prefix == "/" { return path.hasPrefix("/") }
            if path == prefix { return true }
            if path.hasPrefix(prefix + "/") { return true }
        }
        return false
    }

    /// Codes that mean "the volume or the selected root is not there",
    /// as opposed to "this one directory is unreadable".
    private static func isRootLoss(_ code: Int32) -> Bool {
        code == ENOENT || code == ENOTDIR || code == ENODEV || code == ENXIO
    }

    private static func issue(for relative: String, code: Int32) -> ScanIssue {
        ScanIssue(
            relativePath: relative,
            code: code,
            message: String(cString: strerror(code)))
    }
}