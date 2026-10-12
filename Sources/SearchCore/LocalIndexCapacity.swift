import Foundation
import Darwin

/// Keep a reserve on the local index disk; never try to reclaim user data.
public enum LocalIndexCapacity {
    public static let reserveBytes: UInt64 = 512 * 1_024 * 1_024
    public enum CapacityError: Error, LocalizedError, Sendable {
        case unavailable
        case insufficient(available: UInt64, required: UInt64)
        public var errorDescription: String? {
            switch self {
            case .unavailable: return "无法确认本机索引盘剩余空间，已停止扫描；已有索引保留。"
            case .insufficient(let available, let required):
                return "本机索引盘空间不足（剩余 \(available / 1_024 / 1_024) MiB，需要保留至少 \(required / 1_024 / 1_024) MiB）。扫描已停止，已有索引保留；释放本机空间后再继续。"
            }
        }
    }
    public static func freeBytes(at url: URL) -> UInt64? {
        var path = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: path.path), path.path != "/" { path.deleteLastPathComponent() }
        var info = statfs()
        guard statfs(path.path, &info) == 0 else { return nil }
        return UInt64(info.f_bavail) * UInt64(info.f_bsize)
    }
    public static func require(_ available: UInt64?, minimum: UInt64 = reserveBytes) throws {
        guard let available else { throw CapacityError.unavailable }
        guard available >= minimum else { throw CapacityError.insufficient(available: available, required: minimum) }
    }
    public static func ensureAvailable(at url: URL, minimum: UInt64 = reserveBytes) throws {
        try require(freeBytes(at: url), minimum: minimum)
    }
}
