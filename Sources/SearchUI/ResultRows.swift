import Foundation
import SearchCore

/// 表格显示用的尺寸/日期文本（中文本地化、确定性输出）。
public enum DisplayText {
    public static let emptyMarker = "—"

    /// 界面默认语言环境；日期只对可见行格式化，因此固定在 zh_CN。
    public static let defaultLocale = Locale(identifier: "zh_CN")

    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// 字节数 → "1.0 KB"。用整数运算避免本地化千分位/小数点带来的不确定性。
    public static func size(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        guard unitIndex > 0 else { return "\(bytes) B" }
        let tenths = Int((value * 10).rounded())
        return "\(tenths / 10).\(tenths % 10) \(units[unitIndex])"
    }

    public static func size(_ bytes: Int64, isDirectory: Bool) -> String {
        isDirectory ? emptyMarker : size(bytes)
    }

    public static func date(_ date: Date, timeZone: TimeZone, locale: Locale = defaultLocale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

/// 一行结果的显示数据。值类型，按需构建并缓存（只为可见行构建）。
public struct ResultRow: Sendable, Equatable {
    public let key: EntryKey
    public let name: String
    public let relativePath: String
    public let parentRelativePath: String
    public let size: Int64
    public let modifiedAt: Date
    public let sizeText: String
    public let modifiedText: String
    public let isDirectory: Bool
    public let volumeID: String
    public let volumeName: String
    public let volumeRootPath: String
    public let volumeUUID: String?
    public let volumeIsOnline: Bool
    public let state: EntryState
    /// 索引记录的文件身份（inode）。打开前用它确认路径上还是同一个文件。
    public let fileID: UInt64?

    public init(
        key: EntryKey,
        name: String,
        relativePath: String,
        parentRelativePath: String,
        size: Int64,
        modifiedAt: Date,
        sizeText: String,
        modifiedText: String,
        isDirectory: Bool,
        volumeID: String,
        volumeName: String,
        volumeRootPath: String,
        volumeUUID: String?,
        volumeIsOnline: Bool,
        state: EntryState,
        fileID: UInt64? = nil
    ) {
        self.key = key
        self.name = name
        self.relativePath = relativePath
        self.parentRelativePath = parentRelativePath
        self.size = size
        self.modifiedAt = modifiedAt
        self.sizeText = sizeText
        self.modifiedText = modifiedText
        self.isDirectory = isDirectory
        self.volumeID = volumeID
        self.volumeName = volumeName
        self.volumeRootPath = volumeRootPath
        self.volumeUUID = volumeUUID
        self.volumeIsOnline = volumeIsOnline
        self.state = state
        self.fileID = fileID
    }

    public var fileExtension: String {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "" : ext.lowercased()
    }

    /// 卷状态列：优先显示离线，其次显示条目校验状态。
    public var statusText: String {
        guard volumeIsOnline else { return "未连接" }
        switch state {
        case .current: return "正常"
        case .stale: return "待检查"
        case .unknown: return "未知"
        }
    }

    /// 只是静态标记（在线 + 有根路径）。真正打开前还要做运行时校验。
    public var canOpen: Bool { volumeIsOnline && !volumeRootPath.isEmpty }

    /// 路径字符串：即使卷离线也能给出（复制路径不需要唤醒卷）。
    public var displayPath: String {
        guard !volumeRootPath.isEmpty else { return relativePath }
        var base = volumeRootPath
        while base.hasSuffix("/") { base.removeLast() }
        var tail = relativePath
        while tail.hasPrefix("/") { tail.removeFirst() }
        return tail.isEmpty ? base : base + "/" + tail
    }

    /// 绝对路径；卷离线或缺少根路径时不构造（无法解析挂载点）。
    public func absoluteURL() -> URL? {
        guard canOpen else { return nil }
        var url = URL(fileURLWithPath: volumeRootPath, isDirectory: true)
        for component in relativePath.split(separator: "/") {
            url.appendPathComponent(String(component), isDirectory: false)
        }
        return url
    }
}

/// 行缓存：只为可见行构建 ResultRow，容量有上限，避免百万命中时堆满内存。
/// 只在主线程访问（结果表渲染），故用 `@unchecked Sendable` 桥接。
private final class VisibleRowCache: @unchecked Sendable {
    private struct Entry {
        let timeZoneID: String
        let localeID: String
        let row: ResultRow
    }

    private let limit: Int
    private var entries: [Int: Entry] = [:]
    private var order: [Int] = []

    init(limit: Int = 2048) {
        self.limit = max(1, limit)
        entries.reserveCapacity(min(limit, 512))
    }

    func value(at index: Int, timeZone: TimeZone, locale: Locale) -> ResultRow? {
        guard let entry = entries[index],
              entry.timeZoneID == timeZone.identifier,
              entry.localeID == locale.identifier else { return nil }
        return entry.row
    }

    func insert(_ row: ResultRow, at index: Int, timeZone: TimeZone, locale: Locale) {
        if entries[index] == nil {
            order.append(index)
            while order.count > limit {
                let evicted = order.removeFirst()
                entries.removeValue(forKey: evicted)
            }
        }
        entries[index] = Entry(timeZoneID: timeZone.identifier, localeID: locale.identifier, row: row)
    }
}

/// 键 → 行号查询。命中数很大时不建字典（省内存），退化为对键数组做一次线性查找。
///
/// 线性查找每帧只发生几次（恢复选区 / 恢复滚动锚点 / 进入目录），代价远低于
/// 为百万命中常驻一张百万级字典；而且不会因此丢掉选区。
private final class LazyKeyIndex: @unchecked Sendable {
    private var built: [EntryKey: Int]?
    private var overLimit = false
    private let buildLimit: Int

    init(buildLimit: Int) {
        self.buildLimit = max(0, buildLimit)
    }

    func value(for key: EntryKey, keys: [EntryKey]) -> Int? {
        if overLimit { return keys.firstIndex(of: key) }
        if built == nil {
            guard keys.count <= buildLimit else {
                overLimit = true
                return keys.firstIndex(of: key)
            }
            var map: [EntryKey: Int] = [:]
            map.reserveCapacity(keys.count)
            for (offset, entryKey) in keys.enumerated() {
                if map[entryKey] == nil { map[entryKey] = offset }
            }
            built = map
        }
        return built?[key]
    }
}

/// 快照的不可变查表：键 → 条目、卷 ID → 卷记录。
///
/// 契约上每次索引变动都会递增代际，因此同代快照内容相同；同一代内反复渲染时
/// 可以直接复用这张表，不必重建百万级字典。
struct EntryLookup: Sendable {
    let generation: UInt64
    let volumes: [VolumeRecord]
    let entryByKey: [EntryKey: IndexedEntry]
    let volumeByID: [String: VolumeRecord]

    init(snapshot: CatalogSnapshot) {
        var volumeMap: [String: VolumeRecord] = [:]
        volumeMap.reserveCapacity(snapshot.volumes.count)
        for volume in snapshot.volumes { volumeMap[volume.id] = volume }

        var entryMap: [EntryKey: IndexedEntry] = [:]
        entryMap.reserveCapacity(snapshot.entries.count)
        for entry in snapshot.entries { entryMap[entry.key] = entry }

        self.generation = snapshot.generation
        self.volumes = snapshot.volumes
        self.entryByKey = entryMap
        self.volumeByID = volumeMap
    }

    var entryCount: Int { entryByKey.count }
}

/// 一次渲染所需的全部行数据。
///
/// 只保存：结果键数组（直接复用引擎给出的数组，不复制）+ 快照的不可变查表
/// + 小容量可见行缓存。不会为全部命中构建 `ResultRow` 数组：
/// 日期等文本只在可见行真正需要时才格式化。
public struct ResultRowStore: Sendable {
    public let generation: UInt64
    public let volumes: [VolumeRecord]

    private var keys: [EntryKey]
    private let lookup: EntryLookup
    private var rowCache: VisibleRowCache
    private var keyIndex: LazyKeyIndex
    private let rowCacheLimit: Int
    private let keyIndexBuildLimit: Int

    public init(
        snapshot: CatalogSnapshot,
        keys: [EntryKey],
        rowCacheLimit: Int = 2048,
        keyIndexBuildLimit: Int = 200_000
    ) {
        let lookup = EntryLookup(snapshot: snapshot)
        self.generation = lookup.generation
        self.volumes = lookup.volumes
        self.keys = keys
        self.lookup = lookup
        self.rowCache = VisibleRowCache(limit: rowCacheLimit)
        self.keyIndex = LazyKeyIndex(buildLimit: keyIndexBuildLimit)
        self.rowCacheLimit = rowCacheLimit
        self.keyIndexBuildLimit = keyIndexBuildLimit
    }

    /// 结果键数组（直接持有引擎给出的数组，不做拷贝）。
    public var resultKeys: [EntryKey] { keys }

    /// 快照条目数（查表规模，不随结果变化）。
    public var entryCount: Int { lookup.entryCount }

    /// 同一代内换一批结果时复用查表，只重建行缓存与键索引。
    /// 键完全相同时原样返回（表格重建时零成本）。
    public func reusing(keys newKeys: [EntryKey]) -> ResultRowStore {
        guard newKeys != keys else { return self }
        var copy = self
        copy.keys = newKeys
        copy.rowCache = VisibleRowCache(limit: rowCacheLimit)
        copy.keyIndex = LazyKeyIndex(buildLimit: keyIndexBuildLimit)
        return copy
    }

    /// 结果键数量（不是已构建的行数）。
    public var count: Int { keys.count }

    /// 按需构建一行显示数据；只为可见行付出格式化成本。
    public func row(
        at index: Int,
        timeZone: TimeZone = .current,
        locale: Locale = DisplayText.defaultLocale
    ) -> ResultRow? {
        guard keys.indices.contains(index) else { return nil }
        if let cached = rowCache.value(at: index, timeZone: timeZone, locale: locale) { return cached }

        let key = keys[index]
        guard let entry = lookup.entryByKey[key] else { return nil }
        let volume = lookup.volumeByID[key.volumeID]

        let row = ResultRow(
            key: key,
            name: entry.name,
            relativePath: entry.relativePath,
            parentRelativePath: (entry.relativePath as NSString).deletingLastPathComponent,
            size: entry.size,
            modifiedAt: entry.modifiedAt,
            sizeText: DisplayText.size(entry.size, isDirectory: entry.isDirectory),
            modifiedText: DisplayText.date(entry.modifiedAt, timeZone: timeZone, locale: locale),
            isDirectory: entry.isDirectory,
            volumeID: key.volumeID,
            volumeName: volume?.name ?? key.volumeID,
            volumeRootPath: volume?.rootPath ?? "",
            volumeUUID: volume?.volumeUUID,
            volumeIsOnline: volume?.isOnline ?? false,
            state: entry.state,
            fileID: entry.fileID
        )
        rowCache.insert(row, at: index, timeZone: timeZone, locale: locale)
        return row
    }

    /// 键 → 行号。命中数很大时走线性查找，保证任何规模下都能恢复选区/滚动锚点。
    public func index(of key: EntryKey) -> Int? {
        keyIndex.value(for: key, keys: keys)
    }

    public func volume(id: String) -> VolumeRecord? {
        lookup.volumeByID[id]
    }

    public var offlineVolumeNames: [String] {
        volumes.filter { !$0.isOnline }.map(\.name)
    }

    /// 诊断用：结果里有多少键在快照中找不到。全量扫描，仅在排查时调用。
    public func missingKeyCount() -> Int {
        var missing = 0
        for key in keys where lookup.entryByKey[key] == nil { missing += 1 }
        return missing
    }
}