import AppKit
import SearchCore

/// 结果表列定义。
enum ResultColumn: String, CaseIterable {
    case name
    case path
    case size
    case modified
    case volume
    case status

    var title: String {
        switch self {
        case .name: return "名称"
        case .path: return "所在位置"
        case .size: return "大小"
        case .modified: return "修改时间"
        case .volume: return "所在磁盘"
        case .status: return "状态"
        }
    }

    /// 点击表头时对应的查询排序；卷/状态列不参与排序。
    var sort: SearchSort? {
        switch self {
        case .name: return .name
        case .path: return .path
        case .size: return .size
        case .modified: return .modified
        case .volume, .status: return nil
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .name: return 180
        case .path: return 220
        case .size: return 90
        case .modified: return 140
        case .volume: return 90
        case .status: return 80
        }
    }

    var alignment: NSTextAlignment {
        switch self {
        case .size: return .right
        case .status, .volume: return .center
        case .name, .path, .modified: return .left
        }
    }
}

/// 类型图标缓存：按「目录 / 扩展名」取图标，同类型只查一次 NSWorkspace。
/// 不按文件路径取图标，避免逐行文件 IO。
@MainActor
final class TypeIconCache {
    static let shared = TypeIconCache()

    // `extension` 是 Swift 关键字，枚举 case 改名为 ext。
    private enum CacheKey: Hashable {
        case directory
        case ext(String)
    }

    private var cache: [CacheKey: NSImage] = [:]

    private init() {}

    func icon(for row: ResultRow) -> NSImage {
        let key: CacheKey = row.isDirectory ? .directory : .ext(row.fileExtension)
        if let cached = cache[key] { return cached }
        let image = makeImage(for: key)
        cache[key] = image
        return image
    }

    private func makeImage(for key: CacheKey) -> NSImage {
        let image: NSImage
        switch key {
        case .directory:
            image = NSWorkspace.shared.icon(for: .folder)
        case .ext(let ext):
            image = ext.isEmpty ? NSWorkspace.shared.icon(for: .data) : NSWorkspace.shared.icon(forFileType: ext)
        }
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    func clear() { cache.removeAll() }
}