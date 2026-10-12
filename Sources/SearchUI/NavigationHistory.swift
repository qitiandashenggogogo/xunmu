import Foundation
import SearchCore

/// 导航历史中的一帧：位置状态 + 该位置对应的快照与结果。
///
/// 前进/后退必须同时恢复查询、选区、滚动锚点，以及当时使用的快照与结果，
/// 否则回到旧位置时会出现「查询是旧的、结果是新的」这类错配。
public struct NavigationFrame: Sendable {
    public var state: NavigationState
    public var snapshot: CatalogSnapshot
    public var result: SearchResult

    public init(state: NavigationState, snapshot: CatalogSnapshot, result: SearchResult) {
        self.state = state
        self.snapshot = snapshot
        self.result = result
    }

    /// 位置标识：同样的查询文本 + 同样的搜索范围视为同一位置。
    public var locationKey: String {
        NavigationHistory.locationKey(for: state.query)
    }

    public static func locationKey(for query: SearchQuery) -> String {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(scopeKey(query.scope))|@\(text)"
    }

    private static func scopeKey(_ scope: SearchScope) -> String {
        switch scope {
        case .all:
            return "all"
        case .volume(let id):
            return "volume:\(id)"
        case .directory(let volumeID, let path, let recursive):
            return "dir:\(volumeID):\(path):\(recursive ? "r" : "n")"
        }
    }
}

/// 应用内目录范围导航的纯逻辑历史栈（不依赖 AppKit，可直接单测）。
///
/// 位置标识只包含查询文本与搜索范围：仅排序、扩展名等条件变化算同一位置的更新，
/// 会替换当前帧而不是堆出历史；进出目录、换查询文本才算新位置。
public struct NavigationHistory: Sendable {
    /// 历史深度上限，防止长时间使用后无界增长。
    public static let defaultCapacity = 64

    /// 位置标识（查询文本 + 范围）。历史内部与 UI 侧共用同一套判定。
    public static func locationKey(for query: SearchQuery) -> String {
        NavigationFrame.locationKey(for: query)
    }

    public private(set) var frames: [NavigationFrame]
    public private(set) var cursor: Int
    public let capacity: Int

    public init(capacity: Int = NavigationHistory.defaultCapacity) {
        self.frames = []
        self.cursor = -1
        self.capacity = max(1, capacity)
    }

    public var current: NavigationFrame? {
        guard frames.indices.contains(cursor) else { return nil }
        return frames[cursor]
    }

    public var canGoBack: Bool { cursor > 0 }
    public var canGoForward: Bool { frames.indices.contains(cursor + 1) }
    public var depth: Int { frames.count }

    /// 提交一个新状态。
    ///
    /// - 位置与当前相同（只换了结果或选区）：替换当前帧，不产生历史垃圾。
    /// - 位置不同：丢弃前进分支并压入新帧。
    public mutating func commit(_ frame: NavigationFrame) {
        if let current, current.locationKey == frame.locationKey {
            frames[cursor] = frame
            trimFrontIfNeeded()
            return
        }
        if frames.indices.contains(cursor) {
            frames.removeSubrange((cursor + 1)..<frames.count)
        }
        frames.append(frame)
        cursor = frames.count - 1
        trimFrontIfNeeded()
    }

    /// 重置历史（例如新建搜索、或外部要求清空导航）。
    public mutating func reset(to frame: NavigationFrame?) {
        frames.removeAll(keepingCapacity: true)
        cursor = -1
        if let frame {
            commit(frame)
        }
    }

    @discardableResult
    public mutating func goBack() -> NavigationFrame? {
        guard canGoBack else { return nil }
        cursor -= 1
        return current
    }

    @discardableResult
    public mutating func goForward() -> NavigationFrame? {
        guard canGoForward else { return nil }
        cursor += 1
        return current
    }

    private mutating func trimFrontIfNeeded() {
        guard frames.count > capacity else { return }
        let overflow = frames.count - capacity
        frames.removeFirst(overflow)
        cursor -= overflow
    }
}