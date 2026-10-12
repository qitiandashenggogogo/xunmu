import Foundation

/// Reduces a caught `Error` to one of the coarse ``ErrorKind`` cases *without
/// reading anything the error carries.
///
/// This exists so call sites do not have to hand-write the mapping and then be
/// tempted to attach `error.localizedDescription` "just for context". The switch
/// matches on type only; no associated value of any caught error is ever read,
/// copied, or stored. A `CatalogError` (which carries SQL text, a file path, and
/// the SQLite message) collapses to `.database` and nothing else survives.
public enum DiagnosticsClassifier {
    /// Best-effort classification for callers that do not want to hand-roll it.
    ///
    /// Unknown types fall back to `.other`, which is coarse on purpose. The
    /// function is total and side-effect free.
    public static func classify(_ error: Error) -> ErrorKind {
        // Cancellation is checked first: it is common and unambiguous.
        if error is CancellationError { return .cancelled }
        // Match by type name so this module does not have to depend on
        // SearchIndex/SearchUI/Scanner. Depending on them just to name a type
        // would create an unnecessary coupling; matching on the fully qualified
        // name keeps SearchDiagnostics standalone and dependency-light.
        let name = String(describing: type(of: error))
        switch name {
        case let value where value.contains("CatalogError"):
            return .database
        case let value where value.contains("ScanError"):
            return .enumeration
        case let value where value.contains("MonitorError"):
            return .enumeration
        case let value where value.contains("FilterParseError"):
            return .invalidInput
        case let value where value.contains("CapacityError"):
            return .systemCall
        default:
            return .other
        }
    }
}