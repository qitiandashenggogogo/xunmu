import Foundation
import SearchCore
import SearchScanner
import Testing

private final class EventInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [FileChange] = []
    func add(_ changes: [FileChange]) { lock.withLock { values.append(contentsOf: changes) } }
    func contains(_ path: String) -> Bool { lock.withLock { values.contains { $0.relativePath == path } } }
    func clear() { lock.withLock { values.removeAll() } }
}

@Suite("真实 FSEvents 接入与离线回放", .serialized)
struct LiveEventAcceptanceTests {
    private func waitFor(_ path: String, in inbox: EventInbox) async throws {
        for _ in 0..<80 {
            if inbox.contains(path) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("真实事件流未报告 \(path)")
    }

    @Test func liveCreateRenameAndOfflineReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacEverything-LiveEvents-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = EventInbox()
        let monitor = try FileEventMonitor(rootURL: root) { inbox.add($0) }
        try monitor.start()
        defer { monitor.stop() }
        #expect(monitor.currentEventID > 0 && monitor.currentEventID < UInt64(Int64.max))
        try "fixture".write(to: root.appendingPathComponent("created.txt"), atomically: false, encoding: .utf8)
        try await waitFor("created.txt", in: inbox)
        try FileManager.default.moveItem(at: root.appendingPathComponent("created.txt"), to: root.appendingPathComponent("renamed.txt"))
        try await waitFor("renamed.txt", in: inbox)
        let boundary = monitor.currentEventID
        let journal = try #require(monitor.journalUUID)
        monitor.stop()
        inbox.clear()
        try "offline".write(to: root.appendingPathComponent("offline.txt"), atomically: false, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(500))
        let resumed = try FileEventMonitor(rootURL: root, sinceEventID: boundary, checkpointJournal: journal) { inbox.add($0) }
        try resumed.start()
        defer { resumed.stop() }
        #expect(resumed.resumedFromCheckpoint)
        try await waitFor("offline.txt", in: inbox)
    }
}
