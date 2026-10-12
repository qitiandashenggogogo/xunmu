import CoreServices
import Foundation
import Darwin
import SearchCore

/// Watches an index root for changes through FSEvents and reports them as
/// ``FileChange`` values relative to that root.
///
/// The stream is genuinely per-device: it is created with
/// `FSEventStreamCreateRelativeToDevice`, so its paths are expressed relative
/// to the volume root without a leading slash and its event id belongs to that
/// device's FSEvents database. That is why `journalUUID` carries
/// `FSEventsCopyUUIDForDevice` rather than the volume's own UUID — an event id
/// is only meaningful alongside the journal it came from, and the journal is
/// replaced whenever FSEvents discards its database.
///
/// The callback reports *what changed*. Advancing the application's persisted
/// checkpoint is the application's job: the newest event received is not the
/// newest event applied, and this type never treats one as the other.
public final class FileEventMonitor: @unchecked Sendable {
    public enum MonitorError: Error, Equatable, Sendable {
        case rootUnavailable(path: String)
        case volumeRootUnavailable(path: String)
        case streamCreationFailed(path: String)
    }

    /// The UUID of this device's FSEvents database, or nil when the service
    /// cannot supply one (for example on a read-only device).
    ///
    /// Persist it next to the event id: an event id is only replayable while
    /// the journal UUID matches.
    public var journalUUID: String? {
        lock.withLock { storedJournalUUID }
    }

    /// The newest event id observed on this device.
    ///
    /// Before start this is zero. Start captures a conservative device cursor
    /// using FSEventsGetLastEventIdForDeviceBeforeTime; callbacks then advance it.
    /// Only the index owner may decide which observed boundary is durable.
    public var currentEventID: UInt64 {
        lock.withLock { storedEventID }
    }

    /// True when the stream was created with a persisted event id rather than
    /// from "now". False means events happened before this monitor existed
    /// that it will never report, and a full verification is required.
    public var resumedFromCheckpoint: Bool {
        lock.withLock { resumed }
    }

    /// The `dev_t` being watched.
    public var deviceID: dev_t {
        lock.withLock { device }
    }

    public init(
        rootURL: URL,
        sinceEventID: UInt64 = 0,
        onChanges: @escaping @Sendable ([FileChange]) -> Void
    ) throws {
        let resolved = rootURL.path.withCString { realpath($0, nil) }
        if let resolved {
            self.rootPath = FileEventTranslator.normalize(String(cString: resolved))
            free(resolved)
        } else { self.rootPath = FileEventTranslator.normalize(rootURL.path) }
        self.onChanges = onChanges
        self.requestedEventID = sinceEventID

        let device = DirectoryReader.deviceID(ofPath: self.rootPath)
        self.device = device
        self.volumeRootPath = VolumeDiscovery.volumeRootPath(for: rootURL)
        self.deviceRelativePath =
            FileEventMonitor.relativePath(
                ofRoot: self.rootPath, underVolume: self.volumeRootPath)
        self.storedJournalUUID = FileEventMonitor.fseventsUUID(for: device)
    }

    /// Same as the contract initializer, plus the journal the caller persisted.
    ///
    /// An event id is only meaningful together with the journal it came from.
    /// When the persisted journal does not match this device's, replaying it
    /// would silently skip everything that happened in between, so the monitor
    /// refuses and starts from "now"; `resumedFromCheckpoint` reports that and
    /// the caller is expected to schedule a full verification.
    public convenience init(
        rootURL: URL,
        sinceEventID: UInt64,
        checkpointJournal: String?,
        onChanges: @escaping @Sendable ([FileChange]) -> Void
    ) throws {
        try self.init(rootURL: rootURL, sinceEventID: sinceEventID, onChanges: onChanges)
        if let checkpointJournal, checkpointJournal != storedJournalUUID {
            self.requestedEventID = 0
        }
    }

    // MARK: - Lifecycle

    public func start() throws {
        if lock.withLock({ stream != nil }) { return }
        guard FileManager.default.fileExists(atPath: rootPath) else {
            throw MonitorError.rootUnavailable(path: rootPath)
        }
        guard !volumeRootPath.isEmpty else {
            throw MonitorError.volumeRootUnavailable(path: rootPath)
        }
        let device = self.device
        guard device != 0 else {
            throw MonitorError.rootUnavailable(path: rootPath)
        }
        let watchedPath = deviceRelativePath

        let since = lock.withLock { () -> FSEventStreamEventId in
            if requestedEventID != 0 {
                resumed = true
                return FSEventStreamEventId(requestedEventID)
            }
            resumed = false
            // SDK specifies Unix seconds here (despite the CFAbsoluteTime type).
            // Capture a conservative device cursor before registering the stream;
            // persisting SinceNow (UInt64.max) would lose offline changes and overflow.
            return FSEventsGetLastEventIdForDeviceBeforeTime(device, Date().timeIntervalSince1970)
        }

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)

        // The box is handed to FSEvents through the context's retain/release
        // callbacks so the context memory itself cannot be released while a
        // callback is in flight. It holds the monitor weakly: a strong
        // reference would be a retain cycle that stops deinit from ever
        // running, and deinit is what tears the stream down.
        let box = ContextBox(monitor: self)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                return UnsafeRawPointer(Unmanaged<ContextBox>.fromOpaque(pointer).retain().toOpaque())
            },
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<ContextBox>.fromOpaque(pointer).release()
            },
            copyDescription: nil)

        if ProcessInfo.processInfo.environment["MACEVERYTHING_TRACE_EVENTS"] == "1" {
            FileHandle.standardError.write(Data("EVENT_START root=\(rootPath) volume=\(volumeRootPath) watch=\(watchedPath) device=\(device) since=\(since)\n".utf8))
        }
        let created = FSEventStreamCreateRelativeToDevice(
            kCFAllocatorDefault,
            FileEventMonitor.streamCallback,
            &context,
            device,
            [watchedPath as CFString] as CFArray,
            since,
            0.15,
            flags)

        guard let created else {
            throw MonitorError.streamCreationFailed(path: rootPath)
        }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            throw MonitorError.streamCreationFailed(path: rootPath)
        }

        lock.withLock {
            stream = created
            // Now that a device-scoped stream exists, its latest id is the only
            // honest answer for "where is this device up to".
            storedEventID = FSEventStreamGetLatestEventId(created)
        }
    }

    public func stop() {
        let current: FSEventStreamRef? = lock.withLock {
            let value = stream
            stream = nil
            return value
        }
        guard let current else { return }
        // Invalidate blocks until any in-flight callback has returned, which is
        // what keeps the context box from being released underneath one.
        FSEventStreamStop(current)
        FSEventStreamInvalidate(current)
        FSEventStreamRelease(current)
    }

    deinit {
        stop()
    }

    // MARK: - Stream callback

    private static let streamCallback: FSEventStreamCallback = {
        _, info, count, eventPaths, eventFlags, eventIDs in
        guard let info, count > 0 else { return }
        let box = Unmanaged<ContextBox>.fromOpaque(info).takeUnretainedValue()
        guard let monitor = box.monitor else { return }
        monitor.handle(
            paths: eventPaths, flags: eventFlags, ids: eventIDs, count: count)
    }

    private func handle(
        paths: UnsafeMutableRawPointer,
        flags: UnsafePointer<FSEventStreamEventFlags>,
        ids: UnsafePointer<FSEventStreamEventId>,
        count: Int
    ) {
        // With UseCFTypes the framework hands over a CFArrayRef of CFStringRef,
        // not a C array of string pointers.
        let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue()
        let flagArray = UnsafeBufferPointer(start: flags, count: count)
        let idArray = UnsafeBufferPointer(start: ids, count: count)

        let volumeRoot = volumeRootPath

        var absolutePaths: [String] = []
        absolutePaths.reserveCapacity(count)
        for index in 0..<count {
            let value = CFArrayGetValueAtIndex(array, index)
            guard let value else {
                absolutePaths.append("")
                continue
            }
            let string = unsafeBitCast(value, to: CFString.self)
            // Device-relative paths carry no leading slash; the whole volume is
            // the empty string.
            absolutePaths.append(
                FileEventMonitor.absolutePath(
                    deviceRelative: string as String, volumeRoot: volumeRoot))
        }

        // The device's event id advances whether or not an event maps to a
        // change inside this root; outside-root events still consume ids.
        var highestEventID: UInt64 = 0
        for index in 0..<count {
            highestEventID = max(highestEventID, ids[index])
        }
        lock.withLock {
            if let stream { storedEventID = FSEventStreamGetLatestEventId(stream) }
            if highestEventID > storedEventID { storedEventID = highestEventID }
        }

        if ProcessInfo.processInfo.environment["MACEVERYTHING_TRACE_EVENTS"] == "1" {
            FileHandle.standardError.write(Data("EVENT_RAW root=\(rootPath) paths=\(absolutePaths) flags=\(Array(flagArray))\n".utf8))
        }
        let changes = FileEventTranslator.changes(
            absolutePaths: absolutePaths,
            flags: flagArray.map { UInt32($0) },
            eventIDs: idArray.map { UInt64($0) },
            rootPath: rootPath)

        guard !changes.isEmpty else { return }
        onChanges(changes)
    }

    // MARK: - Path and identity helpers

    /// Rebuilds an absolute path from a device-relative FSEvents path.
    static func absolutePath(deviceRelative: String, volumeRoot: String) -> String {
        if deviceRelative.isEmpty { return volumeRoot }
        return volumeRoot.hasSuffix("/") ? volumeRoot + deviceRelative : volumeRoot + "/" + deviceRelative
    }

    /// Path of `root` relative to its volume root, without a leading slash.
    static func relativePath(ofRoot root: String, underVolume volumeRoot: String) -> String {
        let root = FileEventTranslator.normalize(root)
        let volumeRoot = FileEventTranslator.normalize(volumeRoot)
        guard !volumeRoot.isEmpty else { return "" }
        if root == volumeRoot { return "" }
        let prefix = volumeRoot.hasSuffix("/") ? volumeRoot : volumeRoot + "/"
        guard root.hasPrefix(prefix) else { return "" }
        return String(root.dropFirst(prefix.count))
    }

    /// `FSEventsCopyUUIDForDevice` as a string, or nil when unavailable.
    static func fseventsUUID(for device: dev_t) -> String? {
        guard device != 0 else { return nil }
        guard let uuid = FSEventsCopyUUIDForDevice(device) else { return nil }
        guard let string = CFUUIDCreateString(kCFAllocatorDefault, uuid) else { return nil }
        return string as String
    }

    // MARK: - State

    /// Held by FSEvents for the stream's lifetime so the context memory
    /// outlives every in-flight callback. The monitor is weak on purpose: a
    /// strong link back would stop deinit from running, and deinit is what
    /// stops the stream.
    private final class ContextBox: @unchecked Sendable {
        weak var monitor: FileEventMonitor?
        init(monitor: FileEventMonitor) { self.monitor = monitor }
    }

    private let rootPath: String
    private let onChanges: @Sendable ([FileChange]) -> Void
    private let queue = DispatchQueue(label: "com.maceverything.fsevents")
    private let lock = NSLock()

    private let device: dev_t
    private let volumeRootPath: String
    private let deviceRelativePath: String

    private var stream: FSEventStreamRef?
    private let storedJournalUUID: String?
    private var storedEventID: UInt64 = 0
    private var requestedEventID: UInt64
    private var resumed = false
}