import Foundation

public enum EntryState: String, Codable, Sendable { case current, stale, unknown }
public struct EntryKey: Hashable, Codable, Sendable {
    public var volumeID: String
    public var nodeID: Int64
    public init(volumeID: String, nodeID: Int64) { self.volumeID = volumeID; self.nodeID = nodeID }
}
public struct VolumeRecord: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var rootPath: String
    public var fileSystem: String
    /// Native volume UUID or "partition:<GPT UUID>" from StableVolumeIdentity.
    public var volumeUUID: String?
    public var isOnline: Bool
    public var requiresFullVerification: Bool
    public var lastVerifiedAt: Date?
    public init(id: String, name: String, rootPath: String, fileSystem: String = "unknown", volumeUUID: String? = nil, isOnline: Bool = true, requiresFullVerification: Bool = false, lastVerifiedAt: Date? = nil) {
        self.id = id; self.name = name; self.rootPath = rootPath; self.fileSystem = fileSystem
        self.volumeUUID = volumeUUID; self.isOnline = isOnline; self.requiresFullVerification = requiresFullVerification; self.lastVerifiedAt = lastVerifiedAt
    }
}
public struct ScannedEntry: Codable, Equatable, Sendable {
    public var relativePath: String
    public var name: String
    public var isDirectory: Bool
    public var isSymbolicLink: Bool
    public var size: Int64
    public var modifiedAt: Date
    public var fileID: UInt64?
    public init(relativePath: String, name: String, isDirectory: Bool, isSymbolicLink: Bool = false, size: Int64 = 0, modifiedAt: Date = .distantPast, fileID: UInt64? = nil) {
        self.relativePath = relativePath; self.name = name; self.isDirectory = isDirectory; self.isSymbolicLink = isSymbolicLink
        self.size = size; self.modifiedAt = modifiedAt; self.fileID = fileID
    }
}
public struct ScanIssue: Codable, Equatable, Sendable {
    public var relativePath: String
    public var code: Int32
    public var message: String
    public init(relativePath: String, code: Int32, message: String) { self.relativePath = relativePath; self.code = code; self.message = message }
}
public struct DirectoryBatch: Sendable {
    public var volumeID: String
    public var directoryRelativePath: String
    public var entries: [ScannedEntry]
    public var isComplete: Bool
    public var issue: ScanIssue?
    public init(volumeID: String, directoryRelativePath: String, entries: [ScannedEntry], isComplete: Bool, issue: ScanIssue? = nil) {
        self.volumeID = volumeID; self.directoryRelativePath = directoryRelativePath; self.entries = entries; self.isComplete = isComplete; self.issue = issue
    }
}
public struct IndexedEntry: Codable, Equatable, Sendable {
    public var key: EntryKey
    public var relativePath: String
    public var name: String
    public var isDirectory: Bool
    public var isSymbolicLink: Bool
    public var size: Int64
    public var modifiedAt: Date
    public var fileID: UInt64?
    public var state: EntryState
    public init(key: EntryKey, relativePath: String, name: String, isDirectory: Bool = false, isSymbolicLink: Bool = false, size: Int64 = 0, modifiedAt: Date = .distantPast, fileID: UInt64? = nil, state: EntryState = .current) {
        self.key = key; self.relativePath = relativePath; self.name = name; self.isDirectory = isDirectory; self.isSymbolicLink = isSymbolicLink
        self.size = size; self.modifiedAt = modifiedAt; self.fileID = fileID; self.state = state
    }
}
public struct SyncCheckpoint: Codable, Equatable, Sendable {
    public var volumeID: String
    public var eventID: UInt64
    public var journalUUID: String?
    public init(volumeID: String, eventID: UInt64, journalUUID: String? = nil) { self.volumeID = volumeID; self.eventID = eventID; self.journalUUID = journalUUID }
}
public struct CatalogSnapshot: Sendable {
    public var generation: UInt64
    public var entries: [IndexedEntry]
    public var volumes: [VolumeRecord]
    public init(generation: UInt64, entries: [IndexedEntry], volumes: [VolumeRecord]) { self.generation = generation; self.entries = entries; self.volumes = volumes }
}
public enum SearchSort: String, Codable, CaseIterable, Sendable { case name, path, size, modified }
public enum SearchScope: Equatable, Codable, Sendable {
    case all
    case volume(String)
    case directory(volumeID: String, relativePath: String, recursive: Bool)
}
public struct SearchQuery: Equatable, Codable, Sendable {
    public var text: String
    public var scope: SearchScope
    public var extensions: [String]
    public var foldersOnly: Bool
    public var minSize: Int64?
    public var maxSize: Int64?
    public var modifiedAfter: Date?
    public var modifiedBefore: Date?
    public var caseSensitive: Bool
    public var sort: SearchSort
    public var ascending: Bool
    public init(text: String = "", scope: SearchScope = .all, extensions: [String] = [], foldersOnly: Bool = false, minSize: Int64? = nil, maxSize: Int64? = nil, modifiedAfter: Date? = nil, modifiedBefore: Date? = nil, caseSensitive: Bool = false, sort: SearchSort = .name, ascending: Bool = true) {
        self.text = text; self.scope = scope; self.extensions = extensions; self.foldersOnly = foldersOnly
        self.minSize = minSize; self.maxSize = maxSize; self.modifiedAfter = modifiedAfter; self.modifiedBefore = modifiedBefore
        self.caseSensitive = caseSensitive; self.sort = sort; self.ascending = ascending
    }
}
public struct SearchResult: Sendable {
    public var generation: UInt64
    public var keys: [EntryKey]
    public var isCancelled: Bool
    public init(generation: UInt64, keys: [EntryKey], isCancelled: Bool = false) { self.generation = generation; self.keys = keys; self.isCancelled = isCancelled }
}
public struct NavigationState: Codable, Equatable, Sendable {
    public var query: SearchQuery
    public var selectedKey: EntryKey?
    public var scrollAnchorKey: EntryKey?
    public var scrollOffset: Double
    public init(query: SearchQuery = SearchQuery(), selectedKey: EntryKey? = nil, scrollAnchorKey: EntryKey? = nil, scrollOffset: Double = 0) {
        self.query = query; self.selectedKey = selectedKey; self.scrollAnchorKey = scrollAnchorKey; self.scrollOffset = scrollOffset
    }
}
public struct FileChange: Sendable {
    public var relativePath: String
    public var eventID: UInt64
    public var requiresRecursiveScan: Bool
    public var requiresFullScan: Bool
    public init(relativePath: String, eventID: UInt64, requiresRecursiveScan: Bool = false, requiresFullScan: Bool = false) {
        self.relativePath = relativePath; self.eventID = eventID; self.requiresRecursiveScan = requiresRecursiveScan; self.requiresFullScan = requiresFullScan
    }
}
