import Foundation
import SearchCore
import SearchScanner
import Testing

/// Creates and tears down an isolated directory tree under the system temp
/// directory. Nothing here ever touches a real volume.
final class ScannerFixture {
    let root: URL

    init(name: String = "MacEverythingScannerTests") throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        // The system temp directory sits behind a symlink (/var -> /private/var).
        // Resolving it here keeps fixture paths and scanner paths identical.
        root = URL(
            fileURLWithPath: (raw.path as NSString).standardizingPath, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func directory(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func file(_ relative: String, contents: String = "x") throws -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: false)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Creates a symbolic link inside the fixture. `destination` is resolved
    /// against the fixture root so a fixture link can never point at an
    /// arbitrary absolute path.
    @discardableResult
    func symbolicLink(relative: String, destination: String) throws -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: false)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = URL(fileURLWithPath: destination, relativeTo: root)
            .absoluteURL.resolvingSymlinksInPath()
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        return url
    }

    /// Builds a tree with `directoryCount` directories, each holding
    /// `filesPerDirectory` files, so a walk has enough work to be interruptible.
    func makeWideTree(directoryCount: Int, filesPerDirectory: Int = 4) throws {
        for index in 0..<directoryCount {
            let name = String(format: "d%04d", index)
            try directory(name)
            for fileIndex in 0..<filesPerDirectory {
                try file("\(name)/f\(fileIndex).txt")
            }
        }
    }

    var volume: VolumeRecord {
        VolumeDiscovery.describe(rootURL: root)
    }
}

/// Thread safe sink for batches produced by the scanner's `onBatch` callback.
final class BatchCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DirectoryBatch] = []

    func append(_ batch: DirectoryBatch) {
        lock.lock()
        storage.append(batch)
        lock.unlock()
    }

    var batches: [DirectoryBatch] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var allRelativePaths: Set<String> {
        Set(batches.flatMap { $0.entries.map(\.relativePath) })
    }

    var directoriesScanned: Set<String> {
        Set(batches.map(\.directoryRelativePath))
    }

    func batch(forDirectory relative: String) -> DirectoryBatch? {
        batches.first { $0.directoryRelativePath == relative }
    }
}

/// Arms cancellation of the scan task after a fixed number of batches, so the
/// cancellation test does not depend on how fast the disk is.
final class CancelAfterBatches: @unchecked Sendable {
    private let lock = NSLock()
    private var task: AnyTaskBox?
    private var seen = 0
    private let threshold: Int

    init(threshold: Int) {
        self.threshold = threshold
    }

    func attach<Failure: Error>(_ task: Task<Void, Failure>) {
        lock.lock()
        self.task = AnyTaskBox(task)
        lock.unlock()
    }

    func recordBatch() {
        lock.lock()
        seen += 1
        let shouldCancel = seen >= threshold
        let pending = task
        lock.unlock()
        if shouldCancel { pending?.cancelAll() }
    }
}

/// Type erases a task's failure type so the canceller can hold any `Task`.
final class AnyTaskBox: @unchecked Sendable {
    private let cancel: @Sendable () -> Void

    init<Failure: Error>(_ task: Task<Void, Failure>) {
        cancel = { task.cancel() }
    }

    func cancelAll() { cancel() }
}