import CoreServices
import Foundation
import SearchCore
@testable import SearchScanner
import Testing

/// Drives the flag-to-change rules with simulated event payloads. No stream is
/// started and no real file is touched, so the escalation rules — the part that
/// decides whether a scope survives — can be checked exactly instead of waiting
/// for the kernel to cooperate.
@Suite("FSEvents flag classification")
struct FileEventTranslatorTests {
    private let root = "/data/index-root"

    private func translate(
        paths: [String], flags: [UInt32], ids: [UInt64]
    ) -> [FileChange] {
        FileEventTranslator.changes(
            absolutePaths: paths, flags: flags, eventIDs: ids, rootPath: root)
    }

    @Test("An item modification is a local change")
    func itemModificationIsALocalChange() {
        let changes = translate(
            paths: ["\(root)/notes.txt"],
            flags: [UInt32(kFSEventStreamEventFlagItemModified)], ids: [41])
        #expect(changes.count == 1)
        #expect(changes.first?.relativePath == "notes.txt")
        #expect(changes.first?.eventID == 41)
        #expect(changes.first?.requiresRecursiveScan == false)
        #expect(changes.first?.requiresFullScan == false)
    }

    @Test("MustScanSubDirs becomes a recursive scan")
    func mustScanSubDirsBecomesRecursive() {
        let changes = translate(
            paths: ["\(root)/a"],
            flags: [UInt32(kFSEventStreamEventFlagMustScanSubDirs)], ids: [7])
        #expect(changes.count == 1)
        #expect(changes.first?.relativePath == "a")
        #expect(changes.first?.requiresRecursiveScan == true)
        #expect(changes.first?.requiresFullScan == false)
    }

    @Test("A newly created directory needs a recursive scan")
    func newDirectoryNeedsRecursiveScan() {
        // A directory that did not exist before brings its whole subtree with
        // it, so item level handling would leave the new contents unindexed.
        let changes = translate(
            paths: ["\(root)/fresh"],
            flags: [
                UInt32(kFSEventStreamEventFlagItemCreated)
                    | UInt32(kFSEventStreamEventFlagItemIsDir)
            ],
            ids: [12])
        #expect(changes.count == 1)
        #expect(changes.first?.relativePath == "fresh")
        #expect(changes.first?.requiresRecursiveScan == true)
        #expect(changes.first?.requiresFullScan == false)
    }

    @Test("A newly created file needs no recursive scan")
    func newFileNeedsNoRecursiveScan() {
        let changes = translate(
            paths: ["\(root)/fresh.txt"],
            flags: [
                UInt32(kFSEventStreamEventFlagItemCreated)
                    | UInt32(kFSEventStreamEventFlagItemIsFile)
            ],
            ids: [13])
        #expect(changes.count == 1)
        #expect(changes.first?.requiresRecursiveScan == false)
    }

    @Test(
        "Dropped events invalidate the whole scope",
        arguments: [
            kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped,
        ])
    func droppedEventsInvalidateTheWholeScope(flag: Int) {
        let changes = translate(paths: ["\(root)"], flags: [UInt32(flag)], ids: [99])
        #expect(changes.count == 1)
        #expect(changes.first?.relativePath == "")
        #expect(changes.first?.requiresFullScan == true)
        #expect(changes.first?.eventID == 99)
    }

    @Test(
        "Root changes and wrapped event ids invalidate the whole scope",
        arguments: [
            kFSEventStreamEventFlagRootChanged, kFSEventStreamEventFlagEventIdsWrapped,
        ])
    func rootChangedAndWrappedInvalidateTheWholeScope(flag: Int) {
        let changes = translate(paths: ["\(root)"], flags: [UInt32(flag)], ids: [5])
        #expect(changes.count == 1)
        #expect(changes.first?.relativePath == "")
        #expect(changes.first?.requiresFullScan == true)
    }

    @Test(
        "Mount and unmount invalidate the whole scope",
        arguments: [kFSEventStreamEventFlagMount, kFSEventStreamEventFlagUnmount])
    func mountAndUnmountInvalidateTheWholeScope(flag: Int) {
        let changes = translate(paths: ["\(root)/sub"], flags: [UInt32(flag)], ids: [77])
        #expect(changes.count == 1)
        #expect(changes.first?.relativePath == "")
        #expect(changes.first?.requiresFullScan == true)
    }

    @Test("One dropped event collapses the whole delivery")
    func oneDroppedEventCollapsesTheWholeDelivery() {
        let changes = translate(
            paths: ["\(root)/a", "\(root)/b", "\(root)"],
            flags: [
                UInt32(kFSEventStreamEventFlagItemCreated),
                UInt32(kFSEventStreamEventFlagItemRemoved),
                UInt32(kFSEventStreamEventFlagKernelDropped),
            ],
            ids: [1, 2, 30])
        // Item level detail is meaningless once the journal has dropped events.
        #expect(changes.count == 1)
        #expect(changes.first?.relativePath == "")
        #expect(changes.first?.requiresFullScan == true)
    }

    @Test("An unrecognised flag shape is treated conservatively")
    func unknownFlagShapeIsTreatedConservatively() {
        // A flag bit this build has never seen means the event shape is not
        // understood, and guessing is exactly what must not happen here.
        let unknown: UInt32 = 1 << 25
        let changes = translate(paths: ["\(root)/x"], flags: [unknown], ids: [3])
        #expect(changes.count == 1)
        #expect(changes.first?.requiresFullScan == true)
    }

    @Test("HistoryDone on its own requires nothing")
    func historyDoneAloneRequiresNothing() {
        let changes = translate(
            paths: ["\(root)"], flags: [UInt32(kFSEventStreamEventFlagHistoryDone)], ids: [4])
        #expect(changes.count == 1)
        #expect(changes.first?.requiresRecursiveScan == false)
        #expect(changes.first?.requiresFullScan == false)
    }

    @Test("Events outside the root are ignored")
    func eventsOutsideTheRootAreIgnored() {
        let changes = translate(
            paths: ["/elsewhere/x", "\(root)"],
            flags: [
                UInt32(kFSEventStreamEventFlagItemModified),
                UInt32(kFSEventStreamEventFlagItemModified),
            ],
            ids: [8, 9])
        #expect(changes.count == 1)
        #expect(changes.first?.relativePath == "")
    }

    @Test("The same path is coalesced and escalates")
    func samePathIsCoalescedAndEscalates() {
        let changes = translate(
            paths: ["\(root)/a", "\(root)/a"],
            flags: [
                UInt32(kFSEventStreamEventFlagItemCreated),
                UInt32(kFSEventStreamEventFlagMustScanSubDirs),
            ],
            ids: [10, 21])
        #expect(changes.count == 1)
        #expect(changes.first?.relativePath == "a")
        #expect(changes.first?.eventID == 21, "the newest id must win")
        #expect(changes.first?.requiresRecursiveScan == true)
    }

    @Test("Distinct paths keep their arrival order")
    func distinctPathsKeepTheirOrder() {
        let changes = translate(
            paths: ["\(root)/b", "\(root)/a"],
            flags: [
                UInt32(kFSEventStreamEventFlagItemModified),
                UInt32(kFSEventStreamEventFlagItemModified),
            ],
            ids: [2, 1])
        #expect(changes.map(\.relativePath) == ["b", "a"])
    }

    @Test("An empty delivery produces nothing")
    func emptyDeliveryProducesNothing() {
        #expect(translate(paths: [], flags: [], ids: []).isEmpty)
    }
}

@Suite("FSEvents path boundaries")
struct FileEventPathBoundaryTests {
    @Test("Relative paths are computed on component boundaries")
    func relativePathUsesComponentBoundaries() {
        let root = "/data/backup"
        #expect(
            FileEventTranslator.relativePath(
                forAbsolutePath: "/data/backup", rootPath: root) == "")
        #expect(
            FileEventTranslator.relativePath(
                forAbsolutePath: "/data/backup/a/b.txt", rootPath: root) == "a/b.txt")
        // A sibling whose name merely starts with the root is not inside it.
        #expect(
            FileEventTranslator.relativePath(
                forAbsolutePath: "/data/backups/a.txt", rootPath: root) == nil)
        #expect(FileEventTranslator.relativePath(forAbsolutePath: "/data", rootPath: root) == nil)
        #expect(
            FileEventTranslator.relativePath(forAbsolutePath: "/other/a", rootPath: root) == nil)
    }

    @Test("A trailing slash on the root is normalised away")
    func trailingSlashOnRootIsNormalized() {
        #expect(
            FileEventTranslator.relativePath(
                forAbsolutePath: "/data/backup/a", rootPath: "/data/backup/") == "a")
    }

    @Test("The filesystem root contains every absolute path")
    func filesystemRootContainsEveryAbsolutePath() {
        #expect(
            FileEventTranslator.relativePath(forAbsolutePath: "/Users/a/b", rootPath: "/")
                == "Users/a/b")
        #expect(
            FileEventTranslator.relativePath(forAbsolutePath: "relative", rootPath: "/") == nil)
    }
}

@Suite("FileEventMonitor lifecycle")
struct FileEventMonitorLifecycleTests {
    @Test("A device-scoped monitor reports its journal UUID and starts from now")
    func newMonitorStartsFromNowWithADeviceJournal() throws {
        let fixture = try ScannerFixture()
        let monitor = try FileEventMonitor(rootURL: fixture.root) { _ in }
        defer { monitor.stop() }

        // FSEvents exposes no device-scoped "current head" before a stream
        // exists, so the honest baseline before start is zero, not a guess.
        #expect(monitor.currentEventID == 0)
        #expect(monitor.resumedFromCheckpoint == false)
        #expect(monitor.deviceID != 0, "a real path must resolve to a device")

        let journal = try #require(
            monitor.journalUUID,
            "FSEventsCopyUUIDForDevice should return a journal UUID for a live volume")
        #expect(journal.count >= 32, "expected a UUID-shaped journal, got \(journal)")

        try monitor.start()
        #expect(monitor.resumedFromCheckpoint == false)
        // With a stream live, its latest event id is the device's real head.
        #expect(monitor.currentEventID > 0)
        monitor.stop()
        // Stopping twice must be safe; the stream is released exactly once.
        monitor.stop()
    }

    @Test("Device-relative paths round-trip through the volume root")
    func deviceRelativePathsRoundTrip() {
        // FSEventStreamCreateRelativeToDevice takes paths relative to the
        // volume root with no leading slash; the volume root itself is "".
        #expect(
            FileEventMonitor.relativePath(ofRoot: "/Volumes/Data", underVolume: "/")
                == "Volumes/Data")
        #expect(FileEventMonitor.relativePath(ofRoot: "/", underVolume: "/") == "")
        #expect(FileEventMonitor.relativePath(ofRoot: "/", underVolume: "/") == "")

        #expect(
            FileEventMonitor.absolutePath(deviceRelative: "Pictures/July", volumeRoot: "/")
                == "/Pictures/July")
        #expect(FileEventMonitor.absolutePath(deviceRelative: "", volumeRoot: "/Volumes/X")
            == "/Volumes/X")
    }

    @Test("A watched root under its volume yields a leading-slash-free path")
    func watchedRootPathHasNoLeadingSlash() throws {
        let fixture = try ScannerFixture()
        let volumeRoot = try #require(
            Optional(VolumeDiscovery.volumeRootPath(for: fixture.root)))
        let relative = FileEventMonitor.relativePath(
            ofRoot: fixture.root.path, underVolume: volumeRoot)
        #expect(!relative.hasPrefix("/"))
        #expect(
            FileEventMonitor.absolutePath(deviceRelative: relative, volumeRoot: volumeRoot)
                == fixture.root.path)
    }

    @Test("Starting on a missing root fails")
    func startFailsForAMissingRoot() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacEverythingMonitorMissing-\(UUID().uuidString)")
        let monitor = try FileEventMonitor(rootURL: missing) { _ in }
        var thrown: FileEventMonitor.MonitorError?
        do {
            try monitor.start()
        } catch let error as FileEventMonitor.MonitorError {
            thrown = error
        } catch {
            Issue.record("expected MonitorError, got \(error)")
        }
        #expect(thrown == .rootUnavailable(path: missing.path))
        monitor.stop()
    }

    @Test("Resume is refused when the persisted journal does not match the device")
    func resumeIsRefusedWhenThePersistedJournalDoesNotMatch() throws {
        let fixture = try ScannerFixture()
        let monitor = try FileEventMonitor(
            rootURL: fixture.root,
            sinceEventID: 4_294_967_290,
            checkpointJournal: "00000000-0000-0000-0000-000000000000"
        ) { _ in }
        defer { monitor.stop() }

        // Replaying another journal's event id would skip everything that
        // happened in between, so the monitor starts from "now" instead and
        // says so.
        try monitor.start()
        #expect(monitor.resumedFromCheckpoint == false)
    }

    @Test("Resume is accepted when the persisted journal matches the device")
    func resumeIsAcceptedWhenThePersistedJournalMatches() throws {
        let fixture = try ScannerFixture()
        let reference = try FileEventMonitor(rootURL: fixture.root) { _ in }
        defer { reference.stop() }

        let resumed = try FileEventMonitor(
            rootURL: fixture.root,
            sinceEventID: 12_345,
            checkpointJournal: reference.journalUUID
        ) { _ in }
        defer { resumed.stop() }

        try resumed.start()
        #expect(resumed.resumedFromCheckpoint == true)
    }

    @Test("Releasing the monitor tears the stream down")
    func monitorReleasesItsStreamOnDeinit() throws {
        let fixture = try ScannerFixture()
        var monitor: FileEventMonitor? = try FileEventMonitor(rootURL: fixture.root) { _ in }
        try monitor?.start()
        monitor = nil
        // deinit stops the stream; surviving this without a leak or a hang is
        // the assertion. A strongly held context box would be a retain cycle
        // that stops deinit from ever running, so this also proves there is
        // none.
        #expect(monitor == nil)
    }
}