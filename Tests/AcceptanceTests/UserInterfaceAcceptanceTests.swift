import Testing
import AppKit
import SearchCore
import SearchUI

/// 界面层黑盒验收：结果的懒构建、离线/待校验状态显示、导航状态恢复。
///
/// 分两部分：
/// 1. 默认运行：`ResultRowStore` / `NavigationHistory`，纯值类型，不依赖窗口显示。
/// 2. 需要真实 AppKit 窗口：默认禁用，设 `MACEVERYTHING_ACCEPTANCE_UI=1` 后运行。
@Suite("界面验收")
@MainActor
struct UserInterfaceAcceptanceTests {

    private var volumes: [VolumeRecord] {
        [AcceptanceFixture.internalVolume(), AcceptanceFixture.externalVolume(isOnline: false)]
    }

    private var snapshot: CatalogSnapshot {
        AcceptanceFixture.snapshot(
            generation: 7,
            volumes: volumes,
            entries: [
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 1, "文档", isDirectory: true),
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 2, "文档/报告.pdf", size: 2_048, modifiedOffsetSeconds: 10),
                AcceptanceFixture.indexedEntry(volumeID: "vol-external", nodeID: 3, "外置/说明.txt", state: .stale),
            ]
        )
    }

    // MARK: - 懒构建

    @Test("只按命中键计数，不预建全库行")
    func rowStoreCountsKeysWithoutMaterializingRows() {
        // 10 万条合成条目（纯内存），结果只含 3 个键。
        let largeSnapshot = AcceptanceFixture.snapshot(
            generation: 3,
            volumes: [AcceptanceFixture.internalVolume()],
            entries: AcceptanceFixture.syntheticEntries(count: 100_000, volumeID: "vol-internal")
        )
        let keys = [
            EntryKey(volumeID: "vol-internal", nodeID: 1),
            EntryKey(volumeID: "vol-internal", nodeID: 500),
            EntryKey(volumeID: "vol-internal", nodeID: 100_000),
        ]

        let store = ResultRowStore(snapshot: largeSnapshot, keys: keys)

        #expect(store.entryCount == 100_000, "查表规模是快照条目数，不随结果变化")
        #expect(store.count == 3, "count 是结果键数量，不是已构建的行数")
        #expect(store.resultKeys == keys, "结果键数组原样保留引擎给出的顺序")
        #expect(store.missingKeyCount() == 0)

        // 只在真正取某一行时才付出构建成本。
        #expect(store.row(at: 0)?.name == largeSnapshot.entries[0].name)
        #expect(store.row(at: 2) != nil)
        #expect(store.row(at: 3) == nil, "越界取行必须安全返回 nil")
        #expect(store.count == 3, "取行不得改变结果键数量")
    }

    @Test("快照里找不到的键保留在结果数组中，取行时为 nil")
    func missingKeysStayInResultArrayAndRowIsNil() {
        let store = ResultRowStore(
            snapshot: snapshot,
            keys: [
                EntryKey(volumeID: "vol-internal", nodeID: 2),   // 存在
                EntryKey(volumeID: "vol-internal", nodeID: 999),  // 快照里没有
                EntryKey(volumeID: "已删除的卷", nodeID: 1),      // 卷都不在
            ]
        )

        #expect(store.count == 3, "缺失键不得从结果数组里剔除，否则行号与结果位置会错位")
        #expect(store.missingKeyCount() == 2, "诊断计数应指出 2 个键找不到")
        #expect(store.row(at: 0)?.name == "报告.pdf")
        #expect(store.row(at: 1) == nil, "找不到的键取行时必须为 nil，而不是崩溃或串行")
        #expect(store.row(at: 2) == nil)
    }

    @Test("重复键不去重、不改变引擎给出的数组")
    func duplicateKeysAreNotCollapsedByTheStore() {
        let key = EntryKey(volumeID: "vol-internal", nodeID: 2)
        let store = ResultRowStore(snapshot: snapshot, keys: [key, key])

        #expect(store.count == 2, "UI 不得重建/去重引擎的结果数组")
        #expect(store.resultKeys == [key, key])
        #expect(store.index(of: key) == 0, "键 → 行号返回首个出现位置")
        #expect(store.row(at: 0)?.name == "报告.pdf")
        #expect(store.row(at: 1)?.name == "报告.pdf")
    }

    @Test("同一代内换结果时复用查表")
    func reusingKeysKeepsEntryLookup() {
        let store = ResultRowStore(
            snapshot: snapshot,
            keys: [EntryKey(volumeID: "vol-internal", nodeID: 2)]
        )
        #expect(store.entryCount == 3)

        let same = store.reusing(keys: [EntryKey(volumeID: "vol-internal", nodeID: 2)])
        #expect(same.count == 1)
        #expect(same.entryCount == 3, "同代复用不改变查表规模")

        let changed = store.reusing(keys: [EntryKey(volumeID: "vol-internal", nodeID: 1)])
        #expect(changed.count == 1)
        #expect(changed.row(at: 0)?.name == "文档")
        #expect(changed.missingKeyCount() == 0)
    }

    // MARK: - 状态显示

    @Test("离线卷的条目不可打开")
    func offlineVolumeRowsCannotBeOpened() throws {
        let store = ResultRowStore(snapshot: snapshot, keys: [EntryKey(volumeID: "vol-external", nodeID: 3)])
        let row = try #require(store.row(at: 0))

        #expect(row.statusText == "未连接", "离线卷的条目必须显示未连接状态")
        #expect(!row.canOpen, "离线卷的条目不得可打开")
        #expect(row.absoluteURL() == nil, "离线卷不得解析出可打开的绝对路径")
        #expect(row.displayPath == "/Volumes/acceptance-external/外置/说明.txt", "复制路径不需要唤醒卷，离线时也要给出路径")
        #expect(store.offlineVolumeNames == ["外置盘"])
    }

    @Test("待校验条目显示为待校验而不是正常")
    func staleEntriesAreVisibleAsPendingVerification() {
        let store = ResultRowStore(snapshot: snapshot, keys: [EntryKey(volumeID: "vol-external", nodeID: 3)])
        #expect(store.row(at: 0)?.statusText == "未连接")
        var onlineSnapshot = snapshot
        onlineSnapshot.volumes[1].isOnline = true
        let online = ResultRowStore(snapshot: onlineSnapshot, keys: store.resultKeys)
        #expect(online.row(at: 0)?.statusText == "待检查")

        let current = ResultRowStore(snapshot: snapshot, keys: [EntryKey(volumeID: "vol-internal", nodeID: 2)])
        #expect(current.row(at: 0)?.statusText == "正常")
    }

    @Test("尺寸与时间文本是确定性的中文格式")
    func sizeAndDateTextAreDeterministicChinese() throws {
        let entries = [
            AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 1, "a.bin", size: 1_536, modifiedOffsetSeconds: 0),
            AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 2, "b.bin", size: 0, modifiedOffsetSeconds: 0),
        ]
        let store = ResultRowStore(snapshot: AcceptanceFixture.snapshot(volumes: volumes, entries: entries), keys: entries.map(\.key))
        let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))

        #expect(store.row(at: 0, timeZone: shanghai)?.sizeText == "1.5 KB")
        #expect(store.row(at: 1, timeZone: shanghai)?.sizeText == "0 B")
        #expect(
            store.row(at: 0, timeZone: shanghai)?.modifiedText == "2026-01-01 08:00",
            "时间显示必须是固定的中文格式"
        )
    }

    @Test("在线条目能拼出可打开的绝对路径")
    func onlineRowBuildsOpenableAbsolutePath() throws {
        let store = ResultRowStore(snapshot: snapshot, keys: [EntryKey(volumeID: "vol-internal", nodeID: 2)])
        let row = try #require(store.row(at: 0))

        #expect(row.canOpen)
        #expect(
            row.absoluteURL()?.path == "/Volumes/acceptance-internal/文档/报告.pdf",
            "绝对路径应由卷根 + 相对路径拼出"
        )
        #expect(row.parentRelativePath == "文档")
        #expect(row.fileExtension == "pdf")
        #expect(row.volumeName == "内置盘")
    }

    @Test("含中文与 emoji 的行显示保留原始名字")
    func rowKeepsUnicodeNames() {
        let entries = [
            AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 1, "国际/Café 报告.pdf"),
            AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 2, "国际/🚀-文件.txt"),
        ]
        let store = ResultRowStore(snapshot: AcceptanceFixture.snapshot(volumes: volumes, entries: entries), keys: entries.map(\.key))

        #expect(store.row(at: 0)?.name == "Café 报告.pdf")
        #expect(store.row(at: 1)?.name == "🚀-文件.txt")
        #expect(store.row(at: 0)?.relativePath == "国际/Café 报告.pdf")
    }

    @Test("目录行的尺寸显示为占位符")
    func directoryRowShowsSizePlaceholder() {
        let store = ResultRowStore(snapshot: snapshot, keys: [EntryKey(volumeID: "vol-internal", nodeID: 1)])
        let row = store.row(at: 0)

        #expect(row?.isDirectory == true)
        #expect(row?.sizeText == "—", "目录不应显示伪造的体积")
    }

    // MARK: - 导航历史（纯逻辑）

    private func frame(
        text: String,
        scope: SearchScope = .all,
        selected: EntryKey? = nil,
        anchor: EntryKey? = nil,
        offset: Double = 0,
        snapshot: CatalogSnapshot
    ) -> NavigationFrame {
        NavigationFrame(
            state: NavigationState(
                query: SearchQuery(text: text, scope: scope),
                selectedKey: selected,
                scrollAnchorKey: anchor,
                scrollOffset: offset
            ),
            snapshot: snapshot,
            result: SearchResult(generation: snapshot.generation, keys: snapshot.entries.map(\.key))
        )
    }

    @Test("进入目录产生历史，后退恢复完整状态")
    func enteringDirectoryPushesHistoryAndBackRestoresFullState() {
        let snapshot = snapshot
        let root = frame(text: "", scope: .all, selected: EntryKey(volumeID: "vol-internal", nodeID: 2), snapshot: snapshot)
        let inside = frame(
            text: "",
            scope: .directory(volumeID: "vol-internal", relativePath: "文档", recursive: false),
            selected: EntryKey(volumeID: "vol-internal", nodeID: 1),
            snapshot: snapshot
        )

        var history = NavigationHistory()
        history.commit(root)
        #expect(!history.canGoBack, "第一帧没有可返回的历史")

        history.commit(inside)
        #expect(history.canGoBack)
        #expect(
            history.current?.state.query.scope == .directory(volumeID: "vol-internal", relativePath: "文档", recursive: false)
        )

        let restored = history.goBack()
        #expect(restored?.state.query.scope == .all, "后退必须回到进入目录之前的范围")
        #expect(restored?.state.selectedKey == EntryKey(volumeID: "vol-internal", nodeID: 2), "选区必须一起恢复")
        #expect(history.canGoForward)
    }

    @Test("同一查询位置的更新替换当前帧而不是堆历史")
    func sameLocationUpdateReplacesFrame() {
        let snapshot = snapshot
        var history = NavigationHistory()
        history.commit(frame(text: "报告", snapshot: snapshot))
        history.commit(frame(text: "报告", selected: EntryKey(volumeID: "vol-internal", nodeID: 2), snapshot: snapshot))

        #expect(history.depth == 1, "同一查询位置的更新只替换当前帧")
        #expect(history.current?.state.selectedKey == EntryKey(volumeID: "vol-internal", nodeID: 2))
    }

    @Test("回退后新查询丢弃前进分支")
    func newBranchAfterBackDropsForwardFrames() {
        let snapshot = snapshot
        var history = NavigationHistory()
        history.commit(frame(text: "a", snapshot: snapshot))
        history.commit(frame(text: "b", snapshot: snapshot))
        history.commit(frame(text: "c", snapshot: snapshot))

        _ = history.goBack()
        #expect(history.canGoForward)

        history.commit(frame(text: "d", snapshot: snapshot))

        #expect(!history.canGoForward, "回退后新查询必须丢弃前进分支")
        #expect(history.current?.state.query.text == "d")
    }

    @Test("导航历史深度有上限")
    func historyDepthIsBounded() {
        let snapshot = snapshot
        var history = NavigationHistory(capacity: 8)
        for index in 0..<50 {
            history.commit(frame(text: "q\(index)", snapshot: snapshot))
        }

        #expect(history.depth <= 8, "历史深度必须有上限，防止长时间使用后无界增长")
        #expect(history.current?.state.query.text == "q49", "最新一帧必须保留")
    }

    @Test("导航帧保存了当时的结果与快照，可原样重放")
    func navigationFrameCarriesSnapshotAndResult() {
        let snapshot = snapshot
        let result = SearchResult(generation: 7, keys: [EntryKey(volumeID: "vol-internal", nodeID: 2)])
        let frame = NavigationFrame(
            state: NavigationState(query: SearchQuery(text: "报告")),
            snapshot: snapshot,
            result: result
        )

        #expect(frame.result.keys == result.keys)
        #expect(frame.snapshot.generation == frame.result.generation, "帧内快照与结果必须同代，否则回放会错配")
        #expect(frame.locationKey != NavigationFrame.locationKey(for: SearchQuery(text: "发票")))
    }

    // MARK: - 窗口级（需 MACEVERYTHING_ACCEPTANCE_UI=1）

    /// 记录回调的 delegate。`searchWindowDidRestoreNavigation` 有默认空实现，
    /// 这里显式实现以计数，用来验证后退/前进确实通知了主控。
    private final class RecordingDelegate: SearchWindowDelegate {
        var queries: [SearchQuery] = []
        var addRootCount = 0
        var rescanCount = 0
        var pauseCount = 0
        var restoreNavigationCount = 0

        func searchWindow(_ window: SearchWindowController, didChange query: SearchQuery) {
            queries.append(query)
        }
        func searchWindowDidRequestAddRoot(_ window: SearchWindowController) { addRootCount += 1 }
        func searchWindowDidRequestRescan(_ window: SearchWindowController) { rescanCount += 1 }
        func searchWindowDidRequestPause(_ window: SearchWindowController) { pauseCount += 1 }
        func searchWindowDidRestoreNavigation(_ window: SearchWindowController) { restoreNavigationCount += 1 }
    }

    private func makeWindow() -> SearchWindowController {
        let controller = SearchWindowController()
        _ = controller.window   // 触发窗口构建
        return controller
    }

    @Test(
        "窗口只渲染与快照同代的结果",
        .disabled(if: !AcceptanceFixture.uiAcceptanceEnabled, "未设置 MACEVERYTHING_ACCEPTANCE_UI=1")
    )
    func windowRendersOnlySameGenerationResults() {
        let controller = makeWindow()

        controller.update(
            snapshot: snapshot,
            result: SearchResult(generation: 7, keys: [EntryKey(volumeID: "vol-internal", nodeID: 2)])
        )
        #expect(controller.resultRows.count == 1)

        controller.update(
            snapshot: snapshot,
            result: SearchResult(generation: 6, keys: [EntryKey(volumeID: "vol-external", nodeID: 3)])
        )
        #expect(controller.resultRows.count == 1, "旧代结果不得覆盖已渲染内容")
        #expect(controller.resultRows.row(at: 0)?.name == "报告.pdf")
    }

    @Test(
        "同一代内换一批结果仍然生效",
        .disabled(if: !AcceptanceFixture.uiAcceptanceEnabled, "未设置 MACEVERYTHING_ACCEPTANCE_UI=1")
    )
    func windowAcceptsNewKeysInSameGeneration() {
        let controller = makeWindow()

        controller.update(
            snapshot: snapshot,
            result: SearchResult(generation: 7, keys: [EntryKey(volumeID: "vol-internal", nodeID: 2)])
        )
        #expect(controller.resultRows.count == 1)

        controller.update(
            snapshot: snapshot,
            result: SearchResult(
                generation: 7,
                keys: [EntryKey(volumeID: "vol-internal", nodeID: 1), EntryKey(volumeID: "vol-external", nodeID: 3)]
            )
        )
        #expect(controller.resultRows.count == 2, "同代换结果必须生效")
        #expect(controller.resultRows.row(at: 0)?.name == "文档")
        #expect(controller.resultRows.row(at: 1)?.name == "说明.txt")
    }

    @Test(
        "窗口忽略已取消的结果",
        .disabled(if: !AcceptanceFixture.uiAcceptanceEnabled, "未设置 MACEVERYTHING_ACCEPTANCE_UI=1")
    )
    func windowIgnoresCancelledResult() {
        let controller = makeWindow()

        controller.update(
            snapshot: snapshot,
            result: SearchResult(generation: 7, keys: [EntryKey(volumeID: "vol-internal", nodeID: 2)])
        )
        controller.update(snapshot: snapshot, result: SearchResult(generation: 7, keys: [], isCancelled: true))

        #expect(controller.resultRows.count == 1, "取消的结果不得清空或覆盖已渲染内容")
    }

    @Test(
        "窗口状态捕获与恢复保持查询、范围与排序",
        .disabled(if: !AcceptanceFixture.uiAcceptanceEnabled, "未设置 MACEVERYTHING_ACCEPTANCE_UI=1")
    )
    func windowCaptureRestoreRoundTripKeepsQuerySelectionAndScope() {
        let controller = makeWindow()

        controller.update(
            snapshot: snapshot,
            result: SearchResult(generation: 7, keys: [EntryKey(volumeID: "vol-internal", nodeID: 1)])
        )
        controller.setQuery(SearchQuery(text: "报告", sort: .size, ascending: false))
        let state = controller.captureState()
        #expect(state.query.text == "报告")

        controller.setQuery(SearchQuery(text: "别的", scope: .volume("vol-external")))
        controller.restoreState(state)

        #expect(controller.currentQuery.text == "报告")
        #expect(controller.currentQuery.scope == .all, "恢复后范围必须回到原状态")
        #expect(controller.currentQuery.sort == .size)
        #expect(!controller.currentQuery.ascending)
    }

    @Test(
        "窗口进入目录后可后退回原范围，并通知主控",
        .disabled(if: !AcceptanceFixture.uiAcceptanceEnabled, "未设置 MACEVERYTHING_ACCEPTANCE_UI=1")
    )
    func windowNavigationIntoDirectoryAndBack() throws {
        let controller = makeWindow()
        let delegate = RecordingDelegate()
        controller.searchDelegate = delegate

        controller.update(
            snapshot: snapshot,
            result: SearchResult(generation: 7, keys: [EntryKey(volumeID: "vol-internal", nodeID: 1)])
        )
        controller.enterDirectory(EntryKey(volumeID: "vol-internal", nodeID: 1), recursive: false)

        let scope = try #require(controller.currentQuery.scope.directory)
        #expect(scope.volumeID == "vol-internal")
        #expect(scope.relativePath == "文档")
        #expect(!scope.recursive)

        controller.update(
            snapshot: snapshot,
            result: SearchResult(generation: 7, keys: [EntryKey(volumeID: "vol-internal", nodeID: 2)])
        )
        #expect(controller.canGoBack)

        controller.goBack()
        #expect(controller.currentQuery.scope == .all, "后退必须恢复进入目录之前的范围")
        #expect(controller.resultRows.count == 1)
        #expect(delegate.restoreNavigationCount == 1, "后退必须通知主控，以便取消在途查询并后台重算")
    }
}

extension SearchScope {
    /// 测试便捷：取出目录范围的三元组。
    var directory: (volumeID: String, relativePath: String, recursive: Bool)? {
        if case .directory(let volumeID, let relativePath, let recursive) = self {
            return (volumeID, relativePath, recursive)
        }
        return nil
    }
}
