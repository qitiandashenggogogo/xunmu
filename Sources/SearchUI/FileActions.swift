import AppKit
import Darwin
import Foundation
@preconcurrency import QuickLook
@preconcurrency import QuickLookUI
import SearchCore

/// 打开类操作被拒绝的原因。
public enum FileActionError: Error, Equatable, Sendable {
    /// 索引里该卷已标记为离线。
    case volumeOffline
    /// 卷根路径不存在（盘被拔出或路径失效）。
    case volumeNotMounted
    /// 索引记录没有卷 UUID，无法确认身份。
    case volumeIdentityUnknown
    /// 当前挂载点的卷 UUID 与索引记录不一致（卷被换过）。
    case volumeChanged
    /// 目标路径上已经没有这个条目。
    case pathUnavailable
    /// 路径存在，但已经不是索引记录里的那个文件（inode 不符）。
    case fileReplaced
    /// 系统没有真正打开这个文件。
    case openFailed

    public var message: String {
        switch self {
        case .volumeOffline:
            return "无法打开：磁盘未连接。请连接后再试。"
        case .volumeNotMounted:
            return "无法打开：找不到磁盘位置。磁盘可能已拔出或卸载。"
        case .volumeIdentityUnknown:
            return "已阻止打开：无法确认是哪块磁盘。缺少可靠的磁盘唯一标识。以免误开别的盘上同名文件。"
        case .volumeChanged:
            return "已阻止打开：磁盘与记录不一致。可能换过盘，请重新检查。"
        case .pathUnavailable:
            return "找不到该文件，可能已被移动或删除。"
        case .fileReplaced:
            return "已阻止打开：文件与记录不符。请重新检查后再试。"
        case .openFailed:
            return "系统未能打开该文件。"
        }
    }
}

/// 打开、Finder 显示、复制路径、快速查看。
///
/// 只做打开/只读类操作：不删除、不改名、不移动、不改写用户文件。
/// 打开前必须依次满足：索引标记在线 → 卷根仍在挂载 → 真实卷 UUID 与索引记录一致
/// → 目标路径仍存在 → 目标 inode 与索引记录的 fileID 一致。
/// 复制路径不需要唤醒卷，因此不做这些校验。
@MainActor
public enum FileActions {
    /// 读取挂载点当前真实的卷 UUID。
    public static func mountedVolumeUUID(atPath path: String) -> String? {
        StableVolumeIdentity.identifier(for: URL(fileURLWithPath: path, isDirectory: true))
    }

    /// 返回 nil 表示卷身份可确认；否则返回拒绝原因。
    public static func verifyVolume(for row: ResultRow) -> FileActionError? {
        guard row.volumeIsOnline else { return .volumeOffline }
        guard !row.volumeRootPath.isEmpty else { return .volumeNotMounted }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: row.volumeRootPath, isDirectory: &isDirectory) else {
            return .volumeNotMounted
        }
        guard let expected = row.volumeUUID, !expected.isEmpty else { return .volumeIdentityUnknown }
        guard let actual = mountedVolumeUUID(atPath: row.volumeRootPath) else { return .volumeNotMounted }
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else { return .volumeChanged }
        return nil
    }

    /// 目标文件身份核对：用 lstat 取 inode 与索引记录的 fileID 比较。
    /// 索引里没有 fileID 时不阻断（保守：只做存在性检查）。
    public static func verifyFileIdentity(_ row: ResultRow, at url: URL) -> FileActionError? {
        guard let known = row.fileID else { return nil }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .pathUnavailable }
        guard UInt64(info.st_ino) == known else { return .fileReplaced }
        return nil
    }

    /// 打开前的完整检查。
    public static func verifyOpen(_ row: ResultRow) -> FileActionError? {
        if let error = verifyVolume(for: row) { return error }
        guard let url = row.absoluteURL() else { return .pathUnavailable }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .pathUnavailable
        }
        return verifyFileIdentity(row, at: url)
    }

    /// 打开（双击）：文件用默认程序，目录交给 Finder。
    /// 不改变查询、选区与导航历史。只有系统真的打开才返回 true。
    @discardableResult
    public static func open(_ row: ResultRow, status: (String) -> Void) -> Bool {
        if let error = verifyOpen(row) {
            status(error.message)
            return false
        }
        guard let url = row.absoluteURL() else {
            status(FileActionError.pathUnavailable.message)
            return false
        }
        let opened = NSWorkspace.shared.open(url)
        if !opened { status(FileActionError.openFailed.message) }
        return opened
    }

    /// 在 Finder 中显示并选中。
    @discardableResult
    public static func revealInFinder(_ row: ResultRow, status: (String) -> Void) -> Bool {
        if let error = verifyOpen(row) {
            status(error.message)
            return false
        }
        guard let url = row.absoluteURL() else {
            status(FileActionError.pathUnavailable.message)
            return false
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true // AppKit confirms dispatch only; this API has no success result.
    }

    /// 复制路径：不需要唤醒卷，也不做卷/文件身份校验（离线路径同样可复制）。
    @discardableResult
    public static func copyPath(_ row: ResultRow, status: (String) -> Void) -> Bool {
        let path = row.displayPath
        guard !path.isEmpty else {
            status(FileActionError.pathUnavailable.message)
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
        status("已复制路径：\(path)")
        return true
    }
}

/// 按需快速查看。面板按需打开，不预加载缩略图。
/// `QLPreviewPanel` 的数据源/代理仍是旧的非隔离回调，用 `@preconcurrency` 桥接。
@MainActor
final class QuickLookPresenter: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    private var items: [ResultRow] = []

    func present(rows: [ResultRow]) -> FileActionError? {
        guard let first = rows.first else { return .pathUnavailable }
        if let error = FileActions.verifyOpen(first) { return error }
        let usable = rows.filter { FileActions.verifyOpen($0) == nil }
        guard !usable.isEmpty, let panel = QLPreviewPanel.shared() else { return nil }
        items = usable
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
        return nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
        guard items.indices.contains(index), let url = items[index].absoluteURL() else {
            return URL(fileURLWithPath: "/") as NSURL
        }
        return url as NSURL
    }

    func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        items = []
    }
}
