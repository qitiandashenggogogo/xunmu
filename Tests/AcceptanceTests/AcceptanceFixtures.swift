import Foundation
import SearchCore
import SearchIndex

// 验收测试共用夹具。全部数据都是内存合成或 `NSTemporaryDirectory()` 下的临时目录，
// 不扫描用户主目录、外置盘，不创建海量真实文件。

/// 验收测试临时目录：创建时带唯一后缀，释放时删除自身。
final class AcceptanceTempDirectory {
    let url: URL

    init(label: String) throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MacEverything-Acceptance-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base
    }

    func path(_ component: String, isDirectory: Bool = false) -> URL {
        url.appendingPathComponent(component, isDirectory: isDirectory)
    }

    /// 在夹具内创建子目录。
    @discardableResult
    func makeDirectory(_ component: String) throws -> URL {
        let target = path(component, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    /// 在夹具内创建文件（只写入验收自己创建的临时夹具）。
    @discardableResult
    func makeFile(_ component: String, contents: String = "acceptance") throws -> URL {
        let target = path(component, isDirectory: false)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: target, options: .atomic)
        return target
    }

    func remove(_ component: String) throws {
        try FileManager.default.removeItem(at: path(component))
    }

    func chmod(_ component: String, permissions: Int) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: path(component).path
        )
    }

    func restoreDefaultPermissions(_ component: String) {
        chmod(component, permissions: 0o755)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

enum AcceptanceFixture {
    /// 固定基准时间：2026-01-01T00:00:00Z（= 1_767_225_600），保证断言可复现。
    static let baseDate = Date(timeIntervalSince1970: 1_767_225_600)

    // MARK: 卷

    static func volume(
        id: String,
        name: String? = nil,
        rootPath: String = "/Volumes/acceptance-fixture",
        fileSystem: String = "apfs",
        volumeUUID: String? = nil,
        isOnline: Bool = true,
        requiresFullVerification: Bool = false,
        lastVerifiedAt: Date? = nil
    ) -> VolumeRecord {
        VolumeRecord(
            id: id,
            name: name ?? id,
            rootPath: rootPath,
            fileSystem: fileSystem,
            volumeUUID: volumeUUID,
            isOnline: isOnline,
            requiresFullVerification: requiresFullVerification,
            lastVerifiedAt: lastVerifiedAt
        )
    }

    static func internalVolume(
        id: String = "vol-internal",
        isOnline: Bool = true,
        requiresFullVerification: Bool = false
    ) -> VolumeRecord {
        volume(
            id: id,
            name: "内置盘",
            rootPath: "/Volumes/acceptance-internal",
            fileSystem: "apfs",
            volumeUUID: "ACCEPTANCE-INTERNAL-UUID",
            isOnline: isOnline,
            requiresFullVerification: requiresFullVerification
        )
    }

    static func externalVolume(
        id: String = "vol-external",
        isOnline: Bool = true,
        requiresFullVerification: Bool = false
    ) -> VolumeRecord {
        volume(
            id: id,
            name: "外置盘",
            rootPath: "/Volumes/acceptance-external",
            fileSystem: "exfat",
            volumeUUID: "ACCEPTANCE-EXTERNAL-UUID",
            isOnline: isOnline,
            requiresFullVerification: requiresFullVerification
        )
    }

    // MARK: 条目

    static func scannedEntry(
        _ relativePath: String,
        isDirectory: Bool = false,
        isSymbolicLink: Bool = false,
        size: Int64 = 0,
        modifiedOffsetSeconds: TimeInterval = 0,
        fileID: UInt64? = nil
    ) -> ScannedEntry {
        ScannedEntry(
            relativePath: relativePath,
            name: (relativePath as NSString).lastPathComponent,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            size: size,
            modifiedAt: baseDate.addingTimeInterval(modifiedOffsetSeconds),
            fileID: fileID
        )
    }

    /// 一个目录的直属子项批次（每层各自一批，符合扫描器的真实行为）。
    static func batch(
        volumeID: String,
        directory: String,
        paths: [String],
        isComplete: Bool = true,
        isDirectory: (String) -> Bool = { _ in false },
        size: (String) -> Int64 = { _ in 1024 },
        modifiedOffsetSeconds: TimeInterval = 0,
        issue: ScanIssue? = nil
    ) -> DirectoryBatch {
        DirectoryBatch(
            volumeID: volumeID,
            directoryRelativePath: directory,
            entries: paths.map { path in
                let directoryFlag = isDirectory(path)
                let fullPath = directory.isEmpty || path.hasPrefix(directory + "/") ? path : directory + "/" + path
                return scannedEntry(
                    fullPath,
                    isDirectory: directoryFlag,
                    size: directoryFlag ? 0 : size(path),
                    modifiedOffsetSeconds: modifiedOffsetSeconds
                )
            },
            isComplete: isComplete,
            issue: issue
        )
    }

    /// 模拟扫描失败（权限/IO 错误）：批次必须是 incomplete。
    static func failedBatch(
        volumeID: String,
        directory: String,
        partialPaths: [String],
        code: Int32 = 13,
        message: String = "acceptance simulated EACCES"
    ) -> DirectoryBatch {
        batch(
            volumeID: volumeID,
            directory: directory,
            paths: partialPaths,
            isComplete: false,
            issue: ScanIssue(relativePath: directory, code: code, message: message)
        )
    }

    static func indexedEntry(
        volumeID: String,
        nodeID: Int64,
        _ relativePath: String,
        isDirectory: Bool = false,
        isSymbolicLink: Bool = false,
        size: Int64 = 0,
        modifiedOffsetSeconds: TimeInterval = 0,
        state: EntryState = .current
    ) -> IndexedEntry {
        IndexedEntry(
            key: EntryKey(volumeID: volumeID, nodeID: nodeID),
            relativePath: relativePath,
            name: (relativePath as NSString).lastPathComponent,
            isDirectory: isDirectory,
            isSymbolicLink: isSymbolicLink,
            size: size,
            modifiedAt: baseDate.addingTimeInterval(modifiedOffsetSeconds),
            state: state
        )
    }

    // MARK: 快照

    static func snapshot(
        generation: UInt64 = 1,
        volumes: [VolumeRecord],
        entries: [IndexedEntry]
    ) -> CatalogSnapshot {
        CatalogSnapshot(generation: generation, entries: entries, volumes: volumes)
    }

    static func snapshot(
        generation: UInt64 = 1,
        volumes: [VolumeRecord],
        paths: [String],
        volumeID: String
    ) -> CatalogSnapshot {
        snapshot(
            generation: generation,
            volumes: volumes,
            entries: paths.enumerated().map { index, path in
                indexedEntry(
                    volumeID: volumeID,
                    nodeID: Int64(index + 1),
                    path,
                    isDirectory: !path.contains(".")
                )
            }
        )
    }

    // MARK: 断言辅助

    static func entriesByPath(_ snapshot: CatalogSnapshot) -> [String: IndexedEntry] {
        var map: [String: IndexedEntry] = [:]
        for entry in snapshot.entries { map[entry.relativePath] = entry }
        return map
    }

    static func entriesByKey(_ snapshot: CatalogSnapshot, keys: [EntryKey]) -> [String: IndexedEntry] {
        let byKey = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.key, $0) })
        var map: [String: IndexedEntry] = [:]
        for key in keys {
            if let entry = byKey[key] { map[entry.relativePath] = entry }
        }
        return map
    }

    static func paths(of snapshot: CatalogSnapshot, keys: [EntryKey]) -> [String] {
        let byKey = Dictionary(snapshot.entries.map { ($0.key, $0.relativePath) }, uniquingKeysWith: { first, _ in first })
        return keys.compactMap { byKey[$0] }
    }

    // MARK: 合成数据集（纯内存，不落盘）

    /// 确定性 PRNG，保证基准与验收可复现。
    struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let chineseWords = [
        "文档", "报告", "图片", "视频", "合同", "发票", "预算", "笔记",
        "截图", "素材", "录音", "表格", "备份", "草稿", "索引", "缓存",
    ]

    static let latinWords = [
        "report", "invoice", "budget", "notes", "meeting", "project", "archive",
        "presentation", "dataset", "backup", "summary", "contract", "receipt",
        "proposal", "statement", "timeline", "worksheet", "checklist",
    ]

    static let extensions = ["pdf", "txt", "docx", "xlsx", "png", "jpg", "mov", "swift", "zip"]

    /// 合成条目：按 `目录0000/词-序号.ext` 结构生成，纯内存，磁盘上没有对应文件。
    static func syntheticPaths(count: Int, seed: UInt64 = 0x5EED) -> [String] {
        var generator = SplitMix64(seed: seed)
        var result: [String] = []
        result.reserveCapacity(count)
        let directoryCount = max(1, min(4_000, Int((Double(count) / 250).rounded(.up))))
        for index in 0..<count {
            let directory = "目录" + String(format: "%04d", Int.random(in: 0..<directoryCount, using: &generator))
            let usesChinese = Bool.random(using: &generator)
            let stem = usesChinese
                ? chineseWords[Int.random(in: 0..<chineseWords.count, using: &generator)]
                : latinWords[Int.random(in: 0..<latinWords.count, using: &generator)]
            let ext = extensions[Int.random(in: 0..<extensions.count, using: &generator)]
            result.append("\(directory)/\(stem)-\(String(format: "%05d", index)).\(ext)")
        }
        return result
    }

    static func syntheticEntries(
        count: Int,
        volumeID: String,
        nodeIDStart: Int64 = 1,
        seed: UInt64 = 0x5EED
    ) -> [IndexedEntry] {
        syntheticPaths(count: count, seed: seed).enumerated().map { index, path in
            indexedEntry(
                volumeID: volumeID,
                nodeID: nodeIDStart + Int64(index),
                path,
                size: Int64(1_024 * (1 + index % 4_096)),
                modifiedOffsetSeconds: Double(index % 100_000)
            )
        }
    }

    // MARK: 取消探针

    /// 线程安全的取消开关：第 N 次被询问后返回 true，用于模拟扫描/排序过程中被取消。
    final class CancellationSwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var checks = 0
        private let cancelAfterChecks: Int

        init(cancelAfterChecks: Int) {
            self.cancelAfterChecks = max(0, cancelAfterChecks)
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            checks += 1
            return checks > cancelAfterChecks
        }

        /// 可直接传给 `SearchEngine.search(_:isCancelled:)`。
        var closure: @Sendable () -> Bool {
            let probe = self
            return { probe.isCancelled }
        }
    }

    // MARK: 环境开关

    /// 需要真实 AppKit 窗口的用例默认禁用，用
    /// `@Test(.disabled(if: !AcceptanceFixture.uiAcceptanceEnabled, "…"))` 表达。
    static var uiAcceptanceEnabled: Bool {
        ProcessInfo.processInfo.environment["MACEVERYTHING_ACCEPTANCE_UI"] == "1"
    }
}
