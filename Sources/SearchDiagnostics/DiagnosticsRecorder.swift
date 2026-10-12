import Foundation

/// Why a write or record operation did not succeed.
///
/// Failures are reported as values, not silently swallowed, so the caller and
/// the tests can observe capacity and save problems.
public enum DiagnosticsError: Error, Equatable, Sendable {
    /// The ring buffer is at its configured capacity and cannot accept more
    /// until it is exported or cleared.
    case bufferFull(capacity: Int)
    /// Writing the export file failed (bad path, no permission, no space).
    case exportFailed(reason: ExportFailure)
    /// Recording is disabled because the user has not (yet) opted in, or has
    /// withdrawn consent.
    case recordingDisabled
}

/// Non-sensitive reasons an export write can fail. No filesystem path appears
/// here; the caller's own URL is theirs and is not echoed into diagnostics.
public enum ExportFailure: String, Equatable, Sendable {
    case pathUnavailable
    case encodingFailed
    case writeFailed
    case permissionDenied
    case unknown
}

/// Configuration for a ``DiagnosticsRecorder``. Only affects local retention.
///
/// `capacity` is clamped on every write, so mutating the stored property after
/// `init` (it is a `var`, so this is legal) cannot put the recorder into a state
/// where eviction crashes or the buffer grows without bound.
public struct DiagnosticsConfiguration: Sendable, Equatable {
    /// Inclusive bounds the capacity is clamped into.
    public static let capacityRange = 1...10_000
    public static let defaultCapacity = 200

    /// Maximum number of events kept in memory before the oldest are evicted.
    public var capacity: Int
    /// When false, recording is refused and the buffer stays empty.
    public var enabled: Bool

    public init(capacity: Int = DiagnosticsConfiguration.defaultCapacity, enabled: Bool = false) {
        self.capacity = DiagnosticsConfiguration.clamp(capacity)
        self.enabled = enabled
    }

    static func clamp(_ value: Int) -> Int {
        min(max(value, capacityRange.lowerBound), capacityRange.upperBound)
    }
}

/// Collects redacted ``DiagnosticEvent`` records in a bounded in-memory ring
/// buffer and exports them as JSON when — and only when — the caller asks.
///
/// Privacy posture, which the rest of this file exists to enforce:
/// - No networking of any kind. There is no URLSession, no socket, no upload.
///   A later, separate crash reporter may send a *previously exported* file at
///   the user's request; this type never initiates anything.
/// - **Build and environment metadata are owned by the recorder**, captured once
///   at init from the running process. They are read-only fields on every event,
///   so no public entry point accepts them and there is nowhere for a caller to
///   place a string that would be copied into the exported JSON.
/// - Recording is opt-in (`enabled` defaults to false). Turning it off with
///   ``setEnabled(false)`` clears the buffer atomically in the same actor turn,
///   so a caller cannot forget to follow it with ``clear()`` and cannot race a
///   half-revoked state.
public actor DiagnosticsRecorder {
    private var configuration: DiagnosticsConfiguration
    private var buffer: [DiagnosticEvent] = []
    private var nextSequence: UInt64 = 1
    private var droppedBecauseFull: Int = 0

    /// Recorder-owned metadata. Never supplied by a caller.
    private let build: Build
    private let environment: Environment
    /// Injectable clock so exports are deterministic under test.
    private let now: @Sendable () -> Date

    public init(configuration: DiagnosticsConfiguration = DiagnosticsConfiguration()) {
        self.configuration = configuration
        self.configuration.capacity = DiagnosticsConfiguration.clamp(configuration.capacity)
        self.build = .current(isDebug: false)
        self.environment = .current()
        self.now = { Date() }
    }

    /// Test seam: fixes build metadata and the clock so exported payloads can be
    /// compared exactly. Not part of the shipping API surface.
    internal init(
        configuration: DiagnosticsConfiguration,
        build: Build,
        environment: Environment,
        now: @escaping @Sendable () -> Date
    ) {
        self.configuration = configuration
        self.configuration.capacity = DiagnosticsConfiguration.clamp(configuration.capacity)
        self.build = build
        self.environment = environment
        self.now = now
    }

    /// Current consent state.
    public var isEnabled: Bool { configuration.enabled }
    /// Number of events currently buffered.
    public var count: Int { buffer.count }
    /// Configured maximum, always within ``DiagnosticsConfiguration/capacityRange``.
    public var capacity: Int { configuration.capacity }
    /// How many events were discarded because the buffer was full.
    public var droppedCount: Int { droppedBecauseFull }

    /// Turn recording on, or withdraw consent.
    ///
    /// Setting this to `false` clears the buffer in the same actor turn, so
    /// withdrawing consent is a single call and cannot leave buffered events
    /// behind for a later export to pick up.
    public func setEnabled(_ enabled: Bool) {
        configuration.enabled = enabled
        if !enabled {
            buffer.removeAll(keepingCapacity: false)
            droppedBecauseFull = 0
        }
    }

    /// Replace capacity, clamping to the supported range and trimming the
    /// oldest events if the new limit is smaller.
    public func setCapacity(_ capacity: Int) {
        configuration.capacity = DiagnosticsConfiguration.clamp(capacity)
        trimToCapacity()
    }

    /// Record one event described entirely by closed enums.
    ///
    /// This is the only public way to add an event, and it has no parameter
    /// that can carry a message, description, path, or query. Build and
    /// environment are attached by the recorder from its own trusted metadata.
    @discardableResult
    public func record(
        module: Module,
        code: Code,
        counter: Counter? = nil,
        rejectWhenFull: Bool = false
    ) throws -> RecordOutcome {
        let event = DiagnosticEvent(
            sequence: nextSequence,
            recordedAt: now(),
            build: build,
            environment: environment,
            module: module,
            code: code,
            counter: counter)
        return try append(event, rejectWhenFull: rejectWhenFull)
    }

    /// A snapshot copy of the buffered events, oldest first.
    public func events() -> [DiagnosticEvent] { buffer }

    /// Discard all buffered events and reset the local drop counter. The
    /// sequence keeps increasing so a later export cannot be mistaken for a
    /// replay of an earlier one.
    public func clear() {
        buffer.removeAll(keepingCapacity: false)
        droppedBecauseFull = 0
    }

    /// Write the buffered events to `url` as a JSON array, pretty-printed so a
    /// human can read it before choosing to share it.
    ///
    /// This is the *only* egress path in the module, and it writes to a file the
    /// caller names. Nothing is transmitted.
    @discardableResult
    public func export(to url: URL) throws -> Int {
        let payload = buffer
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(payload)
            try data.write(to: url, options: [.atomic])
            return payload.count
        } catch is EncodingError {
            throw DiagnosticsError.exportFailed(reason: .encodingFailed)
        } catch let error as CocoaError {
            switch error.code {
            case .fileWriteNoPermission, .fileWriteInvalidFileName:
                throw DiagnosticsError.exportFailed(reason: .permissionDenied)
            case .fileNoSuchFile, .fileReadUnsupportedScheme:
                throw DiagnosticsError.exportFailed(reason: .pathUnavailable)
            default:
                throw DiagnosticsError.exportFailed(reason: .writeFailed)
            }
        } catch {
            throw DiagnosticsError.exportFailed(reason: .unknown)
        }
    }

    // MARK: - Internals

    private func append(_ event: DiagnosticEvent, rejectWhenFull: Bool) throws -> RecordOutcome {
        guard configuration.enabled else { throw DiagnosticsError.recordingDisabled }

        // Re-read the clamp on every append: `configuration` is a struct whose
        // stored `capacity` is a public var, so it can be mutated into an
        // invalid range between calls. Evicting from an empty buffer would trap.
        let limit = DiagnosticsConfiguration.clamp(configuration.capacity)

        var evicted = false
        if buffer.count >= limit {
            if rejectWhenFull {
                throw DiagnosticsError.bufferFull(capacity: limit)
            }
            buffer.removeFirst(buffer.count - limit + 1)
            droppedBecauseFull += 1
            evicted = true
        }
        buffer.append(event)
        // The recorder, not the caller, assigns sequence numbers, so a
        // hand-built event cannot duplicate or run backwards.
        nextSequence &+= 1
        return .recorded(evictedOldest: evicted)
    }

    private func trimToCapacity() {
        let limit = DiagnosticsConfiguration.clamp(configuration.capacity)
        if buffer.count > limit {
            buffer.removeFirst(buffer.count - limit)
        }
    }

    /// Result of a successful ``record(module:code:counter:)``.
    public enum RecordOutcome: Sendable, Equatable {
        case recorded(evictedOldest: Bool)

        public var evictedOldest: Bool {
            if case .recorded(let evicted) = self { return evicted }
            return false
        }
    }
}
