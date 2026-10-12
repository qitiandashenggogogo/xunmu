import Foundation
import Testing

@testable import SearchDiagnostics

@Suite("Diagnostics recorder privacy and behaviour")
struct DiagnosticsRecorderTests {
    private func makeTempURL(_ name: String = "diagnostics.json") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchDiagnosticsTests-\(UUID().uuidString)-\(name)")
    }

    /// Decode an exported file back into events — the real end-to-end check,
    /// rather than searching the raw JSON text (which the encoder may have
    /// escaped, giving a false pass).
    private func exportedEvents(from url: URL) throws -> [DiagnosticEvent] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([DiagnosticEvent].self, from: data)
    }

    // MARK: - Opt-in and consent withdrawal

    @Test("Recording is off by default and stores nothing")
    func recordingIsOffByDefault() async throws {
        let recorder = DiagnosticsRecorder()
        let isEnabled = await recorder.isEnabled
        #expect(isEnabled == false)
        await #expect(throws: DiagnosticsError.recordingDisabled) {
            try await recorder.record(module: .index, code: .applicationError(.database))
        }
        let count = await recorder.count
        #expect(count == 0)
    }

    @Test("Disabling clears the buffer atomically (no separate clear needed)")
    func disablingClearsBufferAtomically() async throws {
        let recorder = DiagnosticsRecorder()
        await recorder.setEnabled(true)
        try await recorder.record(module: .index, code: .applicationError(.database))
        try await recorder.record(module: .scanner, code: .scanPartialFailure)
        let before = await recorder.count
        #expect(before == 2)

        // Withdrawal is a single call: the buffer is emptied in the same actor
        // turn, so nothing is left behind for a later export to pick up.
        await recorder.setEnabled(false)
        let after = await recorder.count
        #expect(after == 0, "setEnabled(false) must clear the buffer")

        // And recording is refused afterwards.
        await #expect(throws: DiagnosticsError.recordingDisabled) {
            try await recorder.record(module: .index, code: .applicationError(.database))
        }
    }

    // MARK: - Capacity

    @Test("The buffer evicts the oldest at capacity")
    func bufferEvictsOldestAtCapacity() async throws {
        let recorder = DiagnosticsRecorder(
            configuration: DiagnosticsConfiguration(capacity: 3, enabled: true))
        for _ in 0..<5 {
            try await recorder.record(
                module: .scanner, code: .scanPartialFailure, counter: .scanDirectory)
        }
        let count = await recorder.count
        let dropped = await recorder.droppedCount
        #expect(count == 3, "buffer must stay at capacity")
        #expect(dropped == 2, "two oldest were evicted")

        let events = await recorder.events()
        #expect(events.map(\.sequence) == [3, 4, 5], "the newest survive")
    }

    @Test("strict rejection surfaces bufferFull instead of evicting")
    func strictRejectionSurfacesBufferFull() async throws {
        let recorder = DiagnosticsRecorder(
            configuration: DiagnosticsConfiguration(capacity: 1, enabled: true))
        try await recorder.record(module: .app, code: .cancelled)
        await #expect(throws: DiagnosticsError.bufferFull(capacity: 1)) {
            try await recorder.record(module: .app, code: .cancelled, rejectWhenFull: true)
        }
        let dropped = await recorder.droppedCount
        #expect(dropped == 0, "strict rejection does not count as a drop")
    }

    @Test("Lowering capacity trims to the new limit")
    func loweringCapacityTrims() async throws {
        let recorder = DiagnosticsRecorder(
            configuration: DiagnosticsConfiguration(capacity: 10, enabled: true))
        for _ in 0..<8 { try await recorder.record(module: .search, code: .cancelled) }
        await recorder.setCapacity(3)
        let count = await recorder.count
        let events = await recorder.events()
        #expect(count == 3)
        #expect(events.map(\.sequence).last == 8, "the newest survive trimming")
    }

    @Test("An out-of-range capacity is clamped, never left invalid")
    func outOfRangeCapacityIsClamped() async throws {
        // init clamps
        #expect(DiagnosticsConfiguration(capacity: 0).capacity == 1)
        #expect(DiagnosticsConfiguration(capacity: -1).capacity == 1)
        #expect(DiagnosticsConfiguration(capacity: 1_000_000).capacity == 10_000)

        // setCapacity clamps too
        let recorder = DiagnosticsRecorder(
            configuration: DiagnosticsConfiguration(capacity: 5, enabled: true))
        await recorder.setCapacity(-3)
        let negativeCapacity = await recorder.capacity
        #expect(negativeCapacity == 1)
        await recorder.setCapacity(1_000_000)
        let hugeCapacity = await recorder.capacity
        #expect(hugeCapacity == 10_000)

        // Mutating the stored property directly (legal, it is a public var) and
        // then recording must not trap on an empty-buffer removeFirst.
        var mutated = DiagnosticsConfiguration(capacity: 5, enabled: true)
        mutated.capacity = 0
        let mutatedRecorder = DiagnosticsRecorder(configuration: mutated)
        let normalizedCapacity = await mutatedRecorder.capacity
        #expect(normalizedCapacity == 1, "the public capacity reflects the effective limit")
        try await mutatedRecorder.record(module: .app, code: .cancelled)
        let count = await mutatedRecorder.count
        #expect(count == 1, "recording with a mutated capacity=0 must not crash")
    }

    // MARK: - Clear and sequence

    @Test("Clear empties the buffer and resets the drop counter")
    func clearEmptiesBuffer() async throws {
        let recorder = DiagnosticsRecorder(
            configuration: DiagnosticsConfiguration(capacity: 2, enabled: true))
        for _ in 0..<5 { try await recorder.record(module: .app, code: .cancelled) }
        let droppedBefore = await recorder.droppedCount
        #expect(droppedBefore > 0)
        await recorder.clear()
        let count = await recorder.count
        let droppedAfter = await recorder.droppedCount
        #expect(count == 0)
        #expect(droppedAfter == 0)
    }

    @Test("The recorder assigns sequence numbers; clear does not rewind them")
    func recorderAssignsSequence() async throws {
        let recorder = DiagnosticsRecorder(
            configuration: DiagnosticsConfiguration(capacity: 10, enabled: true))
        try await recorder.record(module: .app, code: .cancelled)
        try await recorder.record(module: .app, code: .cancelled)
        var events = await recorder.events()
        #expect(events.map(\.sequence) == [1, 2])

        await recorder.clear()
        try await recorder.record(module: .app, code: .cancelled)
        events = await recorder.events()
        #expect(events.map(\.sequence) == [3], "sequence keeps increasing across clear")
    }

    // MARK: - Export

    @Test("Export writes only the recorder-owned metadata")
    func exportWritesRedactedJSON() async throws {
        let recorder = DiagnosticsRecorder(
            configuration: DiagnosticsConfiguration(capacity: 10, enabled: true),
            build: Build(marketingVersion: "1.2.3", buildNumber: "7", isDebug: false),
            environment: Environment(osMajor: 15, osMinor: 1, arch: "arm64"),
            now: { Date(timeIntervalSince1970: 0) })
        try await recorder.record(
            module: .index, code: .indexDatabaseFailure(sqliteCode: 14))

        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let written = try await recorder.export(to: url)
        #expect(written == 1)

        let decoded = try exportedEvents(from: url)
        #expect(decoded.count == 1)
        let event = try #require(decoded.first)
        #expect(event.module == .index)
        #expect(event.code == .indexDatabaseFailure(sqliteCode: 14))
        #expect(event.build.marketingVersion == "1.2.3")
        #expect(event.environment.arch == "arm64")
        #expect(event.sequence == 1)
    }

    @Test("Export failure is reported, not swallowed")
    func exportFailureIsReported() async throws {
        let recorder = DiagnosticsRecorder(
            configuration: DiagnosticsConfiguration(capacity: 4, enabled: true))
        try await recorder.record(module: .app, code: .cancelled)

        let blocker = makeTempURL("parent")
        try Data("x".utf8).write(to: blocker)
        let badURL = blocker.appendingPathComponent("child/diagnostics.json")

        var caught: DiagnosticsError?
        do {
            try await recorder.export(to: badURL)
        } catch let error as DiagnosticsError {
            caught = error
        } catch {
            Issue.record("expected DiagnosticsError, got \(error)")
        }
        guard case .exportFailed = caught else {
            Issue.record("expected exportFailed, got \(String(describing: caught))")
            return
        }
        try? FileManager.default.removeItem(at: blocker)
    }

    @Test("An empty buffer exports an empty array")
    func emptyBufferExportsEmptyArray() async throws {
        let recorder = DiagnosticsRecorder(
            configuration: DiagnosticsConfiguration(capacity: 4, enabled: true))
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let written = try await recorder.export(to: url)
        #expect(written == 0)
        let decoded = try exportedEvents(from: url)
        #expect(decoded.isEmpty)
    }
}

@Suite("Injection resistance")
struct DiagnosticsInjectionTests {
    // A stand-in for `CatalogError`: real CatalogError carries a database path,
    // the SQL statement, and the SQLite message. None of that may reach a
    // payload.
    private struct FakeCatalogError: Error {
        let statement = "SELECT * FROM entries WHERE path LIKE '%private%'"
        let message = "UNIQUE constraint failed: entries.path"
        let path = "/Users/someone/Library/Application Support/index.sqlite"
    }

    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchDiagnosticsInject-\(UUID().uuidString).json")
    }

    private func exportedEvents(from url: URL) throws -> [DiagnosticEvent] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([DiagnosticEvent].self, from: data)
    }

    @Test("Hostile Build/Environment values cannot reach the payload")
    func hostileMetadataCannotLeak() async throws {
        let hostile = "/Users/someone/Documents/private-search-term"
        // The recorder owns its metadata, but even if a hostile value is forced
        // into a Build/Environment, the exported, decoded payload must not
        // contain it.
        let recorder = DiagnosticsRecorder(
            configuration: DiagnosticsConfiguration(capacity: 4, enabled: true),
            build: Build(marketingVersion: hostile, buildNumber: hostile, isDebug: false),
            environment: Environment(osMajor: 15, osMinor: 1, arch: hostile),
            now: { Date(timeIntervalSince1970: 0) })
        try await recorder.record(module: .app, code: .cancelled)

        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try await recorder.export(to: url)

        // Decode the real payload, not the raw text: the encoder may escape
        // characters, and a text search would give a false pass.
        let decoded = try exportedEvents(from: url)
        let event = try #require(decoded.first)
        #expect(event.build.marketingVersion != hostile)
        #expect(event.build.buildNumber != hostile)
        #expect(event.environment.arch != hostile)
        #expect(event.build.marketingVersion == "unknown")
        #expect(event.environment.arch == "unknown")

        // No string field anywhere in the decoded event equals the secret.
        let strings = [
            event.build.marketingVersion, event.build.buildNumber,
            event.environment.arch, event.module.rawValue,
            event.code.numericDetail.map(String.init) ?? "",
        ]
        for value in strings {
            #expect(!value.contains("private-search-term"))
            #expect(!value.contains("/Users/"))
        }
    }

    @Test("A hostile Environment arch is replaced by 'unknown'")
    func hostileArchIsSanitized() {
        #expect(Environment(osMajor: 15, osMinor: 1, arch: "/etc/passwd").arch == "unknown")
        #expect(Environment(osMajor: 15, osMinor: 1, arch: "arm64").arch == "arm64")
        #expect(Build(marketingVersion: "/a/b", buildNumber: "1", isDebug: false)
            .marketingVersion == "unknown")
        #expect(Build(marketingVersion: "1.2.3", buildNumber: "1", isDebug: false)
            .marketingVersion == "1.2.3")
    }

    @Test("A CatalogError's SQL, path and message never reach the payload")
    func catalogErrorContentsNeverLeak() async throws {
        let error = FakeCatalogError()
        let kind = DiagnosticsClassifier.classify(error)
        #expect(kind == .database)

        let recorder = DiagnosticsRecorder(
            configuration: DiagnosticsConfiguration(capacity: 4, enabled: true),
            build: Build(marketingVersion: "1.0", buildNumber: "1", isDebug: false),
            environment: Environment(osMajor: 15, osMinor: 1, arch: "arm64"),
            now: { Date(timeIntervalSince1970: 0) })
        // Only the coarse classification crosses into the recorder; the error
        // object itself is never serialized.
        try await recorder.record(module: .index, code: .applicationError(kind))

        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try await recorder.export(to: url)

        let decoded = try exportedEvents(from: url)
        let event = try #require(decoded.first)
        #expect(event.code == .applicationError(.database))

        // Recursively walk the decoded event's string-bearing fields to prove
        // none of the error's contents are present.
        let allStrings = collectStrings(from: event)
        let forbidden = [
            error.statement, error.message, error.path,
            "SELECT", "constraint", "entries.path", "/Users/", "Application Support",
        ]
        for secret in forbidden {
            for value in allStrings {
                #expect(
                    !value.contains(secret),
                    "decoded payload leaked \(secret) via \(value)")
            }
        }
    }

    /// Flatten every string reachable in the decoded event, so a leak assertion
    /// is not limited to the fields we happened to think of.
    private func collectStrings(from event: DiagnosticEvent) -> [String] {
        var result = [
            event.build.marketingVersion, event.build.buildNumber,
            event.environment.arch, event.module.rawValue,
        ]
        if let counter = event.counter { result.append(counter.rawValue) }
        switch event.code {
        case .applicationError(let kind): result.append(kind.rawValue)
        case .indexDatabaseFailure(let code): result.append(String(code))
        case .scanSyscallFailure(let errno): result.append(String(errno))
        case .scanPartialFailure, .cancelled, .volumeUnavailable,
             .eventsInvalidatedScope, .diagnosticsInternalFailure:
            break
        }
        return result
    }
}

@Suite("Closed type surface")
struct DiagnosticsTypeSurfaceTests {
    @Test("The code carries only fixed cases and small integers")
    func codeCarriesNoFreeText() {
        let codes: [Code] = [
            .applicationError(.database),
            .applicationError(.enumeration),
            .applicationError(.cancelled),
            .applicationError(.volumeUnavailable),
            .applicationError(.systemCall),
            .applicationError(.invalidInput),
            .applicationError(.other),
            .indexDatabaseFailure(sqliteCode: 1),
            .scanSyscallFailure(errno: 13),
            .scanPartialFailure,
            .cancelled,
            .volumeUnavailable,
            .eventsInvalidatedScope,
            .diagnosticsInternalFailure,
        ]
        for code in codes {
            if let detail = code.numericDetail {
                #expect(type(of: detail) == Int32.self)
            }
        }
    }

    @Test("Enum cases are closed")
    func enumsAreClosed() {
        #expect(Module.allCases.count == 7)
        #expect(ErrorKind.allCases.count == 7)
        #expect(Counter.allCases.count == 9)
    }
}

@Suite("Error classification")
struct DiagnosticsClassifierTests {
    @Test("Cancellation is classified as cancelled")
    func cancellationIsCancelled() {
        #expect(DiagnosticsClassifier.classify(CancellationError()) == .cancelled)
    }

    @Test("Unknown errors fall back to the coarse .other case")
    func unknownErrorsFallBackToOther() {
        struct Weird: Error {}
        #expect(DiagnosticsClassifier.classify(Weird()) == .other)
    }
}
