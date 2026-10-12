import DarwinScanner
import Foundation
import SearchCore

/// Discovers volumes and describes index roots using real filesystem facts.
///
/// Everything reported here comes from `statfs(2)` and `NSURL`'s volume
/// resource values. Nothing is inferred: in particular a volume's rotational
/// character is never guessed from its filesystem type, because `apfs` is used
/// for both SSD and spinning media and a wrong guess would mislead the
/// scheduler. When a fact is unavailable the record is marked conservatively
/// instead of being filled with a plausible-looking default.
public enum VolumeDiscovery {
    /// Filesystems this application is prepared to trust for a replayed
    /// FSEvents log.
    ///
    /// Both are journalled formats macOS implements itself, so an event id
    /// from the device's FSEvents database means what it says and a macOS-side
    /// walk describes the whole tree. Nothing else qualifies — in particular a
    /// filesystem type says nothing about the backing hardware, and `apfs` in
    /// particular is used for both SSD and spinning media.
    static let trustedFileSystemNames: Set<String> = ["apfs", "hfs"]

    /// Whether a scope on this filesystem may be trusted without a full
    /// verification pass first.
    ///
    /// Conservative by construction: anything not explicitly trusted needs
    /// verification, including filesystems this build has never heard of. An
    /// unrecognised type is a third-party driver whose journal and event
    /// semantics are unknown, and assuming they behave like APFS is exactly the
    /// assumption that silently loses changes on a removable disk.
    ///
    /// Pure and total, so it can be exercised without mounting anything.
    static func requiresFullVerification(fileSystem: String) -> Bool {
        let normalized = fileSystem.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return !trustedFileSystemNames.contains(normalized)
    }

    /// Every currently mounted volume the system reports, excluding the
    /// synthetic `/Volumes` container itself.
    ///
    /// The `id` of each returned record is freshly generated: an index scope is
    /// registered and persisted by the caller, and volume identity must never
    /// be conflated with the generated scope id.
    public static func mountedVolumes() -> [VolumeRecord] {
        let keys: [URLResourceKey] = [
            .volumeIdentifierKey, .volumeNameKey, .volumeUUIDStringKey, .volumeURLKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []

        var records: [VolumeRecord] = []
        records.reserveCapacity(urls.count)
        for url in urls {
            let path = DirectoryScanner.normalizeAbsolutePath(url.path)
            if path == "/Volumes" || path.isEmpty { continue }
            records.append(describe(rootURL: url, id: UUID().uuidString))
        }
        return records.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Builds a record for a user-selected index root.
    ///
    /// When the root cannot be resolved (unmounted external volume, deleted
    /// directory) the record is kept with `isOnline == false` and
    /// `requiresFullVerification == true` so its offline entries stay
    /// searchable instead of being pruned. A record is never merged with
    /// another volume on the strength of a matching name.
    public static func describe(rootURL: URL, id: String = UUID().uuidString) -> VolumeRecord {
        let path = DirectoryScanner.normalizeAbsolutePath(rootURL.path)
        var record = VolumeRecord(id: id, name: defaultName(for: path), rootPath: path)

        if let name = volumeName(of: rootURL), !name.isEmpty {
            record.name = name
        }
        record.volumeUUID = volumeUUIDString(of: rootURL)

        if let identity = DirectoryReader.fileSystemIdentity(ofPath: path) {
            record.isOnline = true
            record.fileSystem = identity.fileSystemName
        } else {
            record.isOnline = false
            record.fileSystem = "unknown"
            // The volume could not be verified at all, so anything previously
            // indexed under this scope must be treated as unverified rather
            // than as evidence that entries were deleted.
            record.requiresFullVerification = true
        }

        // A volume whose contents can change outside macOS, or whose driver is
        // unknown, cannot be trusted for deletion-by-absence until it has been
        // walked in full.
        if VolumeDiscovery.requiresFullVerification(fileSystem: record.fileSystem) {
            record.requiresFullVerification = true
        }
        // Without a stable volume UUID a remount cannot be tied back to this
        // scope, so deletion-by-absence stays forbidden until it is resolved.
        if record.volumeUUID?.isEmpty != false {
            record.requiresFullVerification = true
        }

        return record
    }

    /// True when the path is the root of a mounted volume rather than a
    /// directory somewhere inside one.
    public static func isVolumeRoot(_ path: String) -> Bool {
        let normalized = DirectoryScanner.normalizeAbsolutePath(path)
        guard normalized != "/",
              let identity = DirectoryReader.fileSystemIdentity(ofPath: normalized)
        else { return false }
        let parent = (normalized as NSString).deletingLastPathComponent
        guard parent != normalized, !parent.isEmpty else { return false }
        return DirectoryReader.fileSystemIdentity(ofPath: parent) != identity
    }

    /// Root of the volume a path lives on, as an absolute path with no trailing
    /// slash. Empty when the volume could not be resolved.
    ///
    /// FSEvents device-relative streams need this: their paths are expressed
    /// relative to the volume root, without a leading slash.
    public static func volumeRootPath(for url: URL) -> String {
        if let values = try? url.resourceValues(forKeys: [.volumeURLKey]),
           let volumeURL = values.volume {
            return DirectoryScanner.normalizeAbsolutePath(volumeURL.path)
        }
        // A volume root is the one whose parent is on a different filesystem.
        let path = DirectoryScanner.normalizeAbsolutePath(url.path)
        guard isVolumeRoot(path) else { return "" }
        return path
    }

    /// Native filesystem UUID, or tagged GPT partition UUID for drivers without one.
    public static func volumeUUIDString(of url: URL) -> String? {
        StableVolumeIdentity.identifier(for: url)
    }

    private static func volumeName(of url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.volumeNameKey]) else {
            return nil
        }
        return values.volumeName
    }

    private static func defaultName(for path: String) -> String {
        if path == "/" { return "Macintosh HD" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}