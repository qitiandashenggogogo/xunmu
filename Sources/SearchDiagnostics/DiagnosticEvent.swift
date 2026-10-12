import Foundation

/// A single redacted diagnostic record.
///
/// The whole point of this type is that there is no field to put a path, a
/// search term, a filename, SQL, or an exception message into. Every payload
/// field is a fixed scalar or a member of a closed enum. Nothing derived from
/// `localizedDescription`, `String(describing:)`, or an arbitrary caller string
/// is accepted anywhere on this type — see ``DiagnosticRecorder/record(_:)``.
///
/// A native crash is *not* representable here, and deliberately so: a crash is
/// not a Swift `Error`, and no `do/catch` around an app operation can observe
/// one. Feeding a caught `Error` into this recorder records an application
/// error, never a crash. Crash capture is a separate, not-yet-connected
/// mechanism; see `docs/DIAGNOSTICS.md`.
public struct DiagnosticEvent: Sendable, Equatable, Codable {
    /// Payload schema version. Bumped only when the wire shape changes, so a
    /// stored export can be interpreted later.
    public let schemaVersion: Int
    /// Monotonically increasing per recorder, starting at 1. Assigned by the
    /// recorder so two events can never share one, and never read from a
    /// caller-supplied value.
    public let sequence: UInt64
    /// Wall-clock time the event was recorded (seconds since 1970). Carries no
    /// location; the date alone reveals nothing about the user's files.
    public let recordedAt: Date
    /// Which build produced it.
    public let build: Build
    /// Coarse platform facts. No username, no locale, no hostname.
    public let environment: Environment
    /// Which subsystem produced it.
    public let module: Module
    /// What happened, as a closed enum. Carries a small numeric detail (an
    /// errno, a SQLite result code) but never text.
    public let code: Code
    /// A closed set of named counters to increment alongside the code.
    public let counter: Counter?

    /// Only the recorder constructs events, and it assigns `sequence` itself.
    /// `internal` on purpose: handing a public initializer that takes a `Build`,
    /// `Environment`, or `sequence` would let a caller smuggle a free-form
    /// string into those fields and straight into the exported JSON. To add an
    /// event, call ``DiagnosticsRecorder/record(module:code:counter:)``.
    init(
        sequence: UInt64,
        recordedAt: Date,
        build: Build,
        environment: Environment,
        module: Module,
        code: Code,
        counter: Counter? = nil
    ) {
        self.schemaVersion = DiagnosticEvent.currentSchemaVersion
        self.sequence = sequence
        self.recordedAt = recordedAt
        self.build = build
        self.environment = environment
        self.module = module
        self.code = code
        self.counter = counter
    }

    public static let currentSchemaVersion = 1
}

/// Which build this is. Free-form strings (a git SHA, a marketing version) are
/// accepted, but they are authored by the build, never derived from user data.
public struct Build: Sendable, Equatable, Codable {
    /// Short semantic version the developer set, e.g. "0.1.0".
    public var marketingVersion: String
    /// Build number the developer set, e.g. "1".
    public var buildNumber: String
    /// True for debug builds; a redacted report is less useful from a debug run.
    public var isDebug: Bool

    public init(marketingVersion: String, buildNumber: String, isDebug: Bool) {
        // Constrained at construction as a second line of defence. The recorder
        // owns this metadata in practice, so nothing here should ever be
        // user-derived; if a caller does pass something path-shaped anyway, it
        // is reduced to "unknown" rather than reaching the exported JSON.
        self.marketingVersion = Build.sanitized(marketingVersion)
        self.buildNumber = Build.sanitized(buildNumber)
        self.isDebug = isDebug
    }

    /// Allows only short, punctuation-light tokens. Anything else — notably
    /// anything containing "/" — is not a version string and is refused.
    static func sanitized(_ value: String) -> String {
        guard !value.isEmpty, value.count <= 32 else { return "unknown" }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-+")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "unknown"
        }
        return value
    }

    /// The current process's build, read from the bundle. Falls back to fixed
    /// placeholder values when running under the test harness, which has no
    /// bundle metadata.
    public static func current(isDebug: Bool) -> Build {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        let number = (info?["CFBundleVersion"] as? String) ?? "0"
        return Build(
            marketingVersion: version, buildNumber: number, isDebug: isDebug)
    }
}

/// Coarse, non-identifying platform facts.
public struct Environment: Sendable, Equatable, Codable {
    /// macOS major version, e.g. 15. Patch level is deliberately coarse.
    public var osMajor: Int
    public var osMinor: Int
    /// Raw hardware machine string ("arm64", "x86_64").
    public var arch: String

    public init(osMajor: Int, osMinor: Int, arch: String) {
        // Closed set: an architecture is one of a handful of known values, so
        // anything else is reported as "unknown" instead of passed through.
        self.osMajor = max(0, osMajor)
        self.osMinor = max(0, osMinor)
        self.arch = Environment.sanitizedArch(arch)
    }

    static func sanitizedArch(_ value: String) -> String {
        switch value.lowercased() {
        case "arm64": return "arm64"
        case "x86_64", "x86-64": return "x86_64"
        default: return "unknown"
        }
    }

    /// The current process's OS and architecture.
    public static func current() -> Environment {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif
        return Environment(
            osMajor: version.majorVersion, osMinor: version.minorVersion, arch: arch)
    }
}

/// Which subsystem emitted an event. A closed set so no module name is ever
/// attacker- or user-controlled text.
public enum Module: String, Sendable, Codable, CaseIterable {
    case app = "app"
    case index = "index"
    case scanner = "scanner"
    case search = "search"
    case ui = "ui"
    case volume = "volume"
    case diagnostics = "diagnostics"
}

/// A closed set of things that can go wrong, expressed without any payload that
/// could carry user content.
///
/// Every case is a fixed, code-level fact. Where a numeric detail is genuinely
/// needed (an errno, a SQLite result code) it is a small integer parameter, not
/// a string, and never the operation's description text.
public enum Code: Sendable, Codable, Equatable {
    /// A catchable application error was observed in `module`.
    ///
    /// This records that *an error happened*, never what it said. The caller
    /// chooses the specific case below so the meaning stays inside this enum;
    /// the recorder never inspects the error's message.
    case applicationError(ErrorKind)

    /// The index database failed to open or run a statement.
    ///
    /// `sqliteCode` is the raw SQLite result code (an Int32), not the SQL or the
    /// error message, neither of which may leave the process.
    case indexDatabaseFailure(sqliteCode: Int32)

    /// A filesystem syscall failed while scanning, identified only by errno.
    case scanSyscallFailure(errno: Int32)

    /// A scan did not finish; retained so scope size is never pruned.
    case scanPartialFailure

    /// The user cancelled a scan or query.
    case cancelled

    /// A volume could not be resolved or went offline.
    case volumeUnavailable

    /// A remote/root-change/journal-drop event forced a full rescan.
    case eventsInvalidatedScope

    /// Something in this diagnostics module itself failed (e.g. export write).
    case diagnosticsInternalFailure

    /// The single integer detail attached to a code, if any. Used for grouping
    /// and de-duplication; never shown raw to a user.
    public var numericDetail: Int32? {
        switch self {
        case .indexDatabaseFailure(let code): return code
        case .scanSyscallFailure(let errno): return errno
        default: return nil
        }
    }
}

/// Coarse classification of a caught `Error`, chosen by the caller.
///
/// A caller maps a specific error to a case *before* handing it to the
/// recorder. The recorder does not read the error, so nothing it carries can be
/// serialized. `CatalogError` in particular holds SQL, file paths, and SQLite
/// messages; those must be reduced to one of these fixed cases and never passed
/// through.
public enum ErrorKind: String, Sendable, Codable, CaseIterable {
    /// The index database could not be opened or a statement failed.
    case database
    /// The selected root or a volume was missing or offline.
    case volumeUnavailable
    /// A scan or query could not enumerate something.
    case enumeration
    /// An operation was cancelled.
    case cancelled
    /// A low-level filesystem or OS call failed.
    case systemCall
    /// A filter or query was not understood.
    case invalidInput
    /// Anything not otherwise classified. Deliberately coarse.
    case other
}

/// A named counter to increment. Closed so no dynamic key (which might be a
/// path or a search term) can ever become a payload field.
public enum Counter: String, Sendable, Codable, CaseIterable {
    case scanBatch = "scan_batch"
    case scanDirectory = "scan_directory"
    case scanError = "scan_error"
    case indexApply = "index_apply"
    case indexCommit = "index_commit"
    case searchQuery = "search_query"
    case searchCancelled = "search_cancelled"
    case volumeOffline = "volume_offline"
    case exportFailed = "export_failed"
}