import Foundation
import Testing
@testable import SearchUI
import SearchCore

/// 纯逻辑导航栈测试：不需要 GUI，可在无窗口的测试环境中直接运行。
@Suite("导航历史")
struct NavigationHistoryTests {

    // MARK: - 夹具

    private func frame(text: String, scope: SearchScope = .all, generation: UInt64 = 1, keyName: String = "a") -> NavigationFrame {
        let key = EntryKey(volumeID: "v1", nodeID: Int64(abs(keyName.hashValue % 1000)))
        let entry = IndexedEntry(
            key: key,
            relativePath: "\(keyName).txt",
            name: "\(keyName).txt",
            size: 1,
            modifiedAt: Date(timeIntervalSince1970: 0)
        )
        let snapshot = CatalogSnapshot(generation: generation, entries: [entry], volumes: [volume()])
        let result = SearchResult(generation: generation, keys: [key])
        let state = NavigationState(query: SearchQuery(text: text, scope: scope))
        return NavigationFrame(state: state, snapshot: snapshot, result: result)
    }

    private func volume(online: Bool = true) -> VolumeRecord {
        VolumeRecord(id: "v1", name: "测试卷", rootPath: "/tmp/fixture", isOnline: online)
    }

    // MARK: - 测试

    @Test("第一帧不可后退")
    func commitFirstFrameIsNotBackable() {
        var history = NavigationHistory()
        #expect(history.canGoBack == false)
        #expect(history.canGoForward == false)
        history.commit(frame(text: "报告"))
        #expect(history.depth == 1)
        #expect(history.canGoBack == false)
        #expect(history.current?.state.query.text == "报告")
    }

    @Test("同一位置只替换不堆历史")
    func sameLocationReplacesInsteadOfGrowing() {
        var history = NavigationHistory()
        history.commit(frame(text: "报告"))
        history.commit(frame(text: "报告", generation: 7))
        #expect(history.depth == 1)
        #expect(history.current?.snapshot.generation == 7)
    }

    @Test("范围变化算新位置")
    func scopeChangeCreatesNewLocation() {
        var history = NavigationHistory()
        history.commit(frame(text: "报告"))
        history.commit(frame(text: "报告", scope: .volume("v1")))
        #expect(history.depth == 2)
        #expect(history.canGoBack == true)
    }

    @Test("仅首尾空白视为同一位置")
    func whitespaceOnlyDifferenceIsSameLocation() {
        var history = NavigationHistory()
        history.commit(frame(text: "报告"))
        history.commit(frame(text: " 报告 "))
        #expect(history.depth == 1)
    }

    @Test("后退同时恢复状态、快照与结果")
    func goBackRestoresStateSnapshotAndResult() {
        var history = NavigationHistory()
        history.commit(frame(text: "旧位置", generation: 3))
        history.commit(frame(text: "新位置", generation: 9))

        let restored = history.goBack()
        #expect(restored?.state.query.text == "旧位置")
        #expect(restored?.snapshot.generation == 3)
        #expect(restored?.result.generation == 3)
        #expect(restored?.result.keys.count == 1)
        #expect(history.canGoBack == false)
        #expect(history.canGoForward == true)
    }

    @Test("前进")
    func goForward() {
        var history = NavigationHistory()
        history.commit(frame(text: "a"))
        history.commit(frame(text: "b"))
        history.goBack()
        let restored = history.goForward()
        #expect(restored?.state.query.text == "b")
        #expect(history.canGoForward == false)
    }

    @Test("后退后再提交会截断前进分支")
    func commitAfterGoBackTruncatesForwardBranch() {
        var history = NavigationHistory()
        history.commit(frame(text: "a"))
        history.commit(frame(text: "b"))
        history.goBack()
        history.commit(frame(text: "c"))
        #expect(history.depth == 2)
        #expect(history.canGoForward == false)
        #expect(history.current?.state.query.text == "c")
    }

    @Test("目录与是否递归都算不同位置")
    func directoryScopeIsPartOfLocation() {
        var history = NavigationHistory()
        history.commit(frame(text: "x", scope: .directory(volumeID: "v1", relativePath: "a", recursive: false)))
        history.commit(frame(text: "x", scope: .directory(volumeID: "v1", relativePath: "b", recursive: false)))
        #expect(history.depth == 2, "不同目录是不同位置")

        history.reset(to: nil)
        history.commit(frame(text: "x", scope: .directory(volumeID: "v1", relativePath: "a", recursive: false)))
        history.commit(frame(text: "x", scope: .directory(volumeID: "v1", relativePath: "a", recursive: true)))
        #expect(history.depth == 2, "是否含子目录属于不同位置")
    }

    @Test("容量上限丢最旧且保留当前位置")
    func capacityDropsOldestAndKeepsCurrent() {
        var history = NavigationHistory(capacity: 3)
        for index in 0..<5 {
            history.commit(frame(text: "q\(index)"))
        }
        #expect(history.depth == 3)
        #expect(history.current?.state.query.text == "q4")
        #expect(history.canGoBack == true)
        #expect(history.goBack()?.state.query.text == "q3")
    }

    @Test("reset 清空历史")
    func resetClearsHistory() {
        var history = NavigationHistory()
        history.commit(frame(text: "a"))
        history.commit(frame(text: "b"))
        history.reset(to: nil)
        #expect(history.depth == 0)
        #expect(history.current == nil)
        #expect(history.canGoBack == false)
    }

    @Test("位置标识同时被历史与帧使用")
    func locationKeyIsShared() {
        let query = SearchQuery(text: " 报告 ", scope: .volume("v1"))
        #expect(NavigationHistory.locationKey(for: query) == frame(text: "报告", scope: .volume("v1")).locationKey)
    }
}