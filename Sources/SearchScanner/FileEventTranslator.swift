import CoreServices
import Foundation
import SearchCore

/// Pure translation from raw FSEvents records to ``FileChange`` values.
///
/// Kept separate from the stream plumbing so the escalation rules — the part
/// that decides whether a scope survives — can be exercised without a live
/// event stream or any real filesystem activity.
enum FileEventTranslator {
    /// Flags that invalidate the whole watched scope: the kernel can no longer
    /// tell us what changed, so the only safe answer is to rescan everything.
    ///
    /// Mount and unmount are included: they replace the tree underneath the
    /// root, which no amount of item-level reconciliation can repair.
    static let wholeScopeFlags: UInt32 =
        UInt32(kFSEventStreamEventFlagUserDropped)
        | UInt32(kFSEventStreamEventFlagKernelDropped)
        | UInt32(kFSEventStreamEventFlagRootChanged)
        | UInt32(kFSEventStreamEventFlagEventIdsWrapped)
        | UInt32(kFSEventStreamEventFlagMount)
        | UInt32(kFSEventStreamEventFlagUnmount)

    /// Flags the translator understands. Anything outside this set means an
    /// event shape this code has never seen, which is treated as a full scan
    /// rather than quietly ignored.
    static let knownFlags: UInt32 =
        wholeScopeFlags
        | UInt32(kFSEventStreamEventFlagMustScanSubDirs)
        | UInt32(kFSEventStreamEventFlagHistoryDone)
        | UInt32(kFSEventStreamEventFlagItemCreated)
        | UInt32(kFSEventStreamEventFlagItemRemoved)
        | UInt32(kFSEventStreamEventFlagItemInodeMetaMod)
        | UInt32(kFSEventStreamEventFlagItemRenamed)
        | UInt32(kFSEventStreamEventFlagItemModified)
        | UInt32(kFSEventStreamEventFlagItemFinderInfoMod)
        | UInt32(kFSEventStreamEventFlagItemChangeOwner)
        | UInt32(kFSEventStreamEventFlagItemXattrMod)
        | UInt32(kFSEventStreamEventFlagItemIsFile)
        | UInt32(kFSEventStreamEventFlagItemIsDir)
        | UInt32(kFSEventStreamEventFlagItemIsSymlink)
        | UInt32(kFSEventStreamEventFlagItemIsHardlink)
        | UInt32(kFSEventStreamEventFlagItemIsLastHardlink)
        | UInt32(kFSEventStreamEventFlagItemCloned)

    /// Converts one absolute path to a path relative to the index root.
    ///
    /// Returns nil when the path is outside the root. Matching is done on a
    /// path-component boundary, so a root of `/data/backup` never claims
    /// `/data/backups/notes.txt`.
    static func relativePath(forAbsolutePath path: String, rootPath: String) -> String? {
        let root = normalize(rootPath)
        let candidate = normalize(path)
        if root == "/" {
            guard candidate.hasPrefix("/") else { return nil }
            return String(candidate.dropFirst())
        }
        if candidate == root { return "" }
        let prefix = root + "/"
        guard candidate.hasPrefix(prefix) else { return nil }
        return String(candidate.dropFirst(prefix.count))
    }

    /// Folds one FSEvents delivery into the changes it implies.
    ///
    /// `absolutePaths`, `flags` and `eventIDs` are parallel arrays as handed to
    /// the stream callback. Events are coalesced per path, keeping the highest
    /// event id and escalating the required work; a whole-scope event discards
    /// the item level detail and yields exactly one full-scan change.
    static func changes(
        absolutePaths: [String],
        flags: [UInt32],
        eventIDs: [UInt64],
        rootPath: String
    ) -> [FileChange] {
        let count = min(absolutePaths.count, min(flags.count, eventIDs.count))
        guard count > 0 else { return [] }

        var wholeScopeID: UInt64 = 0
        var sawWholeScope = false
        var order: [String] = []
        var merged: [String: FileChange] = [:]

        for index in 0..<count {
            let id = eventIDs[index]
            let flag = flags[index]

            if (flag & wholeScopeFlags) != 0 {
                sawWholeScope = true
                wholeScopeID = max(wholeScopeID, id)
                continue
            }

            guard let relative = relativePath(
                forAbsolutePath: absolutePaths[index], rootPath: rootPath)
            else {
                // Outside the index root. The callback still advances the
                // device's event id, which is why `currentEventID` is maintained
                // independently of what is delivered here.
                continue
            }

            var requiresRecursiveScan = (flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs)) != 0
            if (flag & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed)) != 0,
               (flag & UInt32(kFSEventStreamEventFlagItemIsDir)) != 0 {
                // A directory that did not exist before: its entire subtree is
                // new, so it needs a recursive scan just like a dropped subtree.
                requiresRecursiveScan = true
            }
            let isUnknownShape = (flag & ~knownFlags) != 0
            let requiresFullScan = isUnknownShape && flag != 0

            if var existing = merged[relative] {
                existing.eventID = max(existing.eventID, id)
                existing.requiresRecursiveScan =
                    existing.requiresRecursiveScan || requiresRecursiveScan
                existing.requiresFullScan = existing.requiresFullScan || requiresFullScan
                merged[relative] = existing
            } else {
                merged[relative] = FileChange(
                    relativePath: relative,
                    eventID: id,
                    requiresRecursiveScan: requiresRecursiveScan,
                    requiresFullScan: requiresFullScan)
                order.append(relative)
            }
        }

        if sawWholeScope {
            return [
                FileChange(
                    relativePath: "",
                    eventID: wholeScopeID,
                    requiresRecursiveScan: false,
                    requiresFullScan: true)
            ]
        }

        return order.compactMap { merged[$0] }
    }

    /// Strips redundant separators and a trailing slash, keeping "/" intact.
    static func normalize(_ path: String) -> String {
        var value = path
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        if value.count > 1 {
            while value.hasSuffix("//") { value.removeLast() }
        }
        return value
    }
}