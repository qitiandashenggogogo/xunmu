import AppKit
import Foundation
import Testing
@testable import SearchUI
import SearchCore

private let uiSmokeEnabled = ProcessInfo.processInfo.environment["MACEVERYTHING_UI_SMOKE"] == "1"

/// 窗口级冒烟测试（需要真实 AppKit 窗口）。
///
/// 默认整组标记为 skipped（不是静默通过）；用
/// `MACEVERYTHING_UI_SMOKE=1 swift test --filter SearchUI` 启用。
@Suite("搜索窗口冒烟", .enabled(if: uiSmokeEnabled, "需要环境变量 MACEVERYTHING_UI_SMOKE=1"), .serialized)
@MainActor
struct SearchWindowSmokeTests {

    // MARK: - 夹具

    @MainActor
    final class RecordingDelegate: SearchWindowDelegate {
        var queries: [SearchQuery] = []
        var addRootCount = 0
        var rescanCount = 0
        var pauseCount = 0
        var restoreNotifications = 0

        func searchWindow(_ window: SearchWindowController, didChange query: SearchQuery) {
            queries.append(query)
        }
        func searchWindowDidRequestAddRoot(_ window: SearchWindowController) { addRootCount += 1 }
        func searchWindowDidRequestRescan(_ window: SearchWindowController) { rescanCount += 1 }
        func searchWindowDidRequestPause(_ window: SearchWindowController) { pauseCount += 1 }
        func searchWindowDidRestoreNavigation(_ window: SearchWindowController) { restoreNotifications += 1 }
    }

    private var directoryKey: EntryKey { EntryKey(volumeID: "v1", nodeID: 1) }
    private var fileKey: EntryKey { EntryKey(volumeID: "v1", nodeID: 2) }

    private func fixtureEntries() -> [IndexedEntry] {
        [
            IndexedEntry(
                key: directoryKey,
                relativePath: "文档",
                name: "文档",
                isDirectory: true
            ),
            IndexedEntry(
                key: fileKey,
                relativePath: "文档/报告.pdf",
                name: "报告.pdf",
                size: 2048,
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
        ]
    }

    private func snapshot(generation: UInt64, online: Bool = true) -> CatalogSnapshot {
        CatalogSnapshot(
            generation: generation,
            entries: fixtureEntries(),
            volumes: [VolumeRecord(id: "v1", name: "本地盘", rootPath: "/tmp/fixture", volumeUUID: "UUID-V1", isOnline: online)]
        )
    }

    private func makeController() -> SearchWindowController {
        _ = NSApplication.shared
        let controller = SearchWindowController()
        _ = controller.window
        return controller
    }

    private func selectRow(_ controller: SearchWindowController, _ row: Int) {
        guard controller.tableView.numberOfRows > row else { return }
        controller.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    // MARK: - 渲染门控

    @Test("真实右键事件由结果表接管，而不是无效的委托方法")
    func resultTableReceivesContextClick() throws {
        _ = NSApplication.shared
        let table = ResultsTableView()
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1
        ))
        var received: NSEvent?
        table.onContextClick = { received = $0 }
        table.rightMouseDown(with: event)
        #expect(received === event)
    }

    @Test("结果按给定顺序渲染")
    func updateRendersRowsInResultOrder() async {
        let controller = makeController()
        controller.update(snapshot: snapshot(generation: 1), result: SearchResult(generation: 1, keys: [fileKey, directoryKey]))
        #expect(controller.resultRows.count == 2)
        #expect(controller.resultRows.row(at: 0)?.name == "报告.pdf")
        #expect(controller.resultRows.row(at: 1)?.name == "文档")
    }

    @Test("结果与快照不同代时不渲染")
    func mismatchedGenerationIsIgnored() async {
        let controller = makeController()
        controller.update(snapshot: snapshot(generation: 5), result: SearchResult(generation: 4, keys: [fileKey]))
        #expect(controller.resultRows.count == 0)
    }

    @Test("取消的结果不覆盖已渲染内容")
    func cancelledResultDoesNotOverwriteRenderedRows() async {
        let controller = makeController()
        controller.update(snapshot: snapshot(generation: 1), result: SearchResult(generation: 1, keys: [fileKey]))
        #expect(controller.resultRows.count == 1)
        controller.update(snapshot: snapshot(generation: 2), result: SearchResult(generation: 2, keys: [], isCancelled: true))
        #expect(controller.resultRows.count == 1)
    }

    // MARK: - 查询与暂停

    @Test("查询变化通知主控")
    func queryChangeNotifiesDelegate() async {
        let controller = makeController()
        let delegate = RecordingDelegate()
        controller.searchDelegate = delegate
        controller.setQuery(SearchQuery(text: "报告", extensions: ["pdf"], foldersOnly: true, sort: .size, ascending: false))
        #expect(delegate.queries.count == 1)
        #expect(controller.currentQuery.text == "报告")
        #expect(controller.currentQuery.extensions == ["pdf"])
        #expect(controller.currentQuery.foldersOnly == true)
        #expect(controller.currentQuery.sort == .size)
        #expect(controller.currentQuery.ascending == false)
    }

    @Test("扫描中不改变暂停按钮文案，暂停状态单独控制")
    func scanningDoesNotFlipPauseButton() async {
        let controller = makeController()
        #expect(controller.pauseButtonTitle == "暂停")
        controller.setScanning(true)
        #expect(controller.pauseButtonTitle == "暂停", "扫描中不等于已暂停")
        controller.setScanning(false)
        controller.setPausedState(true)
        #expect(controller.pauseButtonTitle == "继续")
        controller.setPausedState(false)
        #expect(controller.pauseButtonTitle == "暂停")
    }

    @Test("三个工具栏动作分别回调主控")
    func toolbarActionsReachDelegate() async {
        let controller = makeController()
        let delegate = RecordingDelegate()
        controller.searchDelegate = delegate
        controller.addRootTapped()
        controller.rescanTapped()
        controller.pauseTapped()
        #expect(delegate.addRootCount == 1)
        #expect(delegate.rescanCount == 1)
        #expect(delegate.pauseCount == 1)
    }

    // MARK: - 导航与状态恢复

    @Test("进入目录把范围改成目录，并留下可后退的位置")
    func enterDirectoryChangesScopeAndKeepsHistory() async {
        let controller = makeController()
        let snap = snapshot(generation: 1)
        controller.update(snapshot: snap, result: SearchResult(generation: 1, keys: [directoryKey, fileKey]))
        selectRow(controller, 0)
        #expect(controller.captureState().selectedKey == directoryKey)

        controller.enterDirectory(directoryKey, recursive: false)
        guard case .directory(let volumeID, let path, let recursive) = controller.currentQuery.scope else {
            Issue.record("进入目录后范围应变为目录")
            return
        }
        #expect(volumeID == "v1")
        #expect(path == "文档")
        #expect(recursive == false)

        controller.update(snapshot: snap, result: SearchResult(generation: 1, keys: [fileKey]))
        #expect(controller.canGoBack == true)
    }

    @Test("后退立刻恢复缓存帧并通知主控")
    func goBackRestoresCachedFrameImmediately() async {
        let controller = makeController()
        let delegate = RecordingDelegate()
        controller.searchDelegate = delegate
        let snap = snapshot(generation: 1)

        controller.update(snapshot: snap, result: SearchResult(generation: 1, keys: [directoryKey, fileKey]))
        selectRow(controller, 0)
        controller.enterDirectory(directoryKey, recursive: false)
        controller.update(snapshot: snap, result: SearchResult(generation: 1, keys: [fileKey]))
        #expect(controller.resultRows.count == 1)

        controller.goBack()
        #expect(delegate.restoreNotifications == 1, "恢复后应通知主控取消在途查询/重算")
        #expect(controller.currentQuery.scope == .all)
        #expect(controller.resultRows.count == 2, "应恢复缓存帧里的旧结果，而不是等新查询")
        #expect(controller.captureState().selectedKey == directoryKey, "选区应按稳定键恢复")

        controller.goForward()
        #expect(controller.currentQuery.scope == .directory(volumeID: "v1", relativePath: "文档", recursive: false))
        #expect(controller.resultRows.count == 1)
    }

    @Test("结果未到达时的恢复状态会在首帧应用")
    func pendingRestoreStateAppliedOnFirstResults() async {
        let controller = makeController()
        // 重启场景：先从磁盘读回状态，此时还没有任何结果。
        controller.restoreState(
            NavigationState(
                query: SearchQuery(text: "报告"),
                selectedKey: fileKey,
                scrollAnchorKey: fileKey,
                scrollOffset: 0
            )
        )
        #expect(controller.currentQuery.text == "报告")

        controller.update(snapshot: snapshot(generation: 1), result: SearchResult(generation: 1, keys: [directoryKey, fileKey]))
        #expect(controller.captureState().selectedKey == fileKey, "待恢复状态必须在首帧结果生效")
    }

    @Test("捕获与恢复状态可往返")
    func captureAndRestoreStateRoundTrip() async {
        let controller = makeController()
        controller.update(snapshot: snapshot(generation: 1), result: SearchResult(generation: 1, keys: [fileKey, directoryKey]))
        controller.setQuery(SearchQuery(text: "报告", extensions: ["pdf"], sort: .size, ascending: false))
        let state = controller.captureState()
        #expect(state.query.text == "报告")

        controller.setQuery(SearchQuery(text: "别的东西"))
        controller.restoreState(state)
        #expect(controller.currentQuery.text == "报告")
        #expect(controller.currentQuery.extensions == ["pdf"])
        #expect(controller.currentQuery.sort == .size)
    }

    // MARK: - 卷状态

    @Test("离线卷的行不可打开")
    func offlineVolumeRowsCannotBeOpened() async {
        let controller = makeController()
        controller.update(
            snapshot: snapshot(generation: 1, online: false),
            result: SearchResult(generation: 1, keys: [fileKey])
        )
        let row = controller.resultRows.row(at: 0)
        #expect(row?.canOpen == false)
        #expect(row?.statusText == "未连接")
    }

    // MARK: - 状态栏：短提示 + 详情

    private struct SampleError: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    @Test("错误状态：先显示白话短提示，系统原文原样保留在「详情」")
    func failureStatusKeepsSystemDetail() {
        let controller = makeController()
        let system = "The file “catalog.sqlite” couldn’t be opened because you don’t have permission to view it."
        controller.setStatus(.failure("无法开始检查。", error: SampleError(text: system)))
        #expect(controller.currentStatus.text == "无法开始检查。")
        #expect(controller.currentStatus.detail == system, "系统原文不得被裁剪或改写")
        #expect(controller.isStatusDetailAvailable, "有详细信息时必须能打开「详情」")
    }

    @Test("恢复正常状态后不残留旧错误的详情")
    func normalStatusClearsPreviousDetail() {
        let controller = makeController()
        controller.setStatus(.failure("无法开始检查。", error: SampleError(text: "旧错误")))
        controller.setStatus("检查完成。搜索使用本机记录。")
        #expect(controller.currentStatus.detail == nil)
        #expect(controller.isStatusDetailAvailable == false, "新的正常状态不应还挂着旧错误的「详情」")

        // 连续出错：只保留最新一条，不累积。
        controller.setStatus(.failure("无法保存检查进度。", error: SampleError(text: "错误一")))
        controller.setStatus(.failure("检查已中断，已保留之前的记录。", error: SampleError(text: "错误二")))
        #expect(controller.currentStatus.detail == "错误二")
    }

    @Test("重复点「详情」只开一个说明窗")
    func repeatedDetailOpensSingleSheet() throws {
        let controller = makeController()
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        // 窗口不可见时会走模态说明窗，测试里会卡住；前提不成立就直接失败。
        try #require(window.isVisible, "需要可见窗口才能验证说明窗以 sheet 方式出现")
        controller.setStatus(.failure("无法开始检查。", error: SampleError(text: "系统详细信息")))
        controller.showStatusDetail()
        controller.showStatusDetail()
        #expect(window.sheets.count == 1, "重复点击不得叠出多个说明窗")
        for sheet in window.sheets { window.endSheet(sheet) }
    }
}
