import AppKit
import Foundation
import Testing
@testable import SearchUI
import SearchCore

private let layoutSmokeEnabled = ProcessInfo.processInfo.environment["MACEVERYTHING_UI_SMOKE"] == "1"

/// 结果表真实 AppKit 布局回归（需要真实窗口与窗口服务）。
///
/// 默认整组标记为 skipped（不是静默通过）；用
/// `MACEVERYTHING_UI_SMOKE=1 swift test --filter SearchUI` 启用。
///
/// 覆盖的缺陷（主控截图证据：`lead-app-smoke-20261012/smoke.png` 里首行
/// 「2026项目报告-12.txt」整行透过表头）：
/// AppKit 把表头盖在滚动视图顶部（clip view 并没有被缩），靠
/// `NSClipView.bounds.origin.y == -表头高度` 给表头让位；任何 `scroll(to: .zero)`
/// 都会取消这份额定，把文档整体上移一个表头高度，首行因此被表头整行盖住。
///
/// 证据来源说明（不要误读）：下面注释里引用的具体数值（表头高 28、行高 20、
/// 静止态 bounds.origin.y = -28、滚到 .zero 后重叠 20pt）来自一个**独立的 /tmp AppKit 探针**，
/// 它在 macOS 26.6.2 上复刻了同样的装配（expanded 工具栏 + .inset + 自定义 NSTableHeaderView +
/// 6 列 + syncTableWidth）并打印真实坐标；**不是**跑本控制器得到的。本套件里的断言
/// 全部基于真实控制器 `showWindow` → `layoutSubtreeIfNeeded` → `displayIfNeeded` 之后的坐标。
///
/// 两种「被裁掉」要分清，测试也分开断言：
/// - 滚到顶部时首行被表头**整行**盖住 → 要防的原缺陷（见前 4 个用例）；
/// - 滚动中首行被内容区上沿**裁掉一部分** → 正常行为，不当缺陷（偏移量用例只要求
///   「表头下方第一个完整可见的行」存在且不被表头压住，并用它上面那行做反证）。
@Suite("结果表布局", .enabled(if: layoutSmokeEnabled, "需要环境变量 MACEVERYTHING_UI_SMOKE=1"), .serialized, .timeLimit(.minutes(2)))
@MainActor
struct SearchWindowLayoutTests {

    @Test("工具栏完整显示只看文件夹，不截成省略号")
    func folderFilterTitleFits() throws {
        let controller = try makeLaidOutController()
        defer { controller.close() }
        let item = try #require(controller.window?.toolbar?.items.first { $0.itemIdentifier == .meFoldersOnly })
        let checkbox = try #require(item.view as? NSButton)
        let cell = try #require(checkbox.cell)
        #expect(checkbox.title == "只看文件夹")
        #expect(checkbox.frame.width + 0.5 >= cell.cellSize.width,
                "实际控件宽度必须容纳完整文字和复选框")
    }

    // MARK: - 夹具

    private func entries(_ count: Int) -> [IndexedEntry] {
        (0..<count).map { index in
            IndexedEntry(
                key: EntryKey(volumeID: "v1", nodeID: Int64(index + 1)),
                relativePath: "文档/报告-\(index).txt",
                name: "报告-\(index).txt",
                size: 2048,
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }
    }

    private func snapshot(count: Int, generation: UInt64 = 1) -> CatalogSnapshot {
        CatalogSnapshot(
            generation: generation,
            entries: entries(count),
            volumes: [VolumeRecord(id: "v1", name: "本地盘", rootPath: "/tmp/fixture", volumeUUID: "UUID-V1", isOnline: true)]
        )
    }

    private func result(count: Int, generation: UInt64 = 1) -> SearchResult {
        SearchResult(generation: generation, keys: entries(count).map(\.key))
    }

    /// 建好窗口并完成一次真实布局（`showWindow` → `layoutSubtreeIfNeeded` → `displayIfNeeded`）。
    private func makeLaidOutController() throws -> SearchWindowController {
        _ = NSApplication.shared
        let controller = SearchWindowController()
        controller.showWindow(nil)
        let window = try #require(controller.window, "搜索窗口应已创建")
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return controller
    }

    private func layout(_ controller: SearchWindowController) {
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.displayIfNeeded()
    }

    private func windowRect(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }

    /// 断言前置条件：窗口真的布局出了非空的结果表与表头。
    /// 环境没布局成功时要给出可读信息，而不是让后面的几何断言报一堆无关差异。
    private func requireLayoutReady(
        _ controller: SearchWindowController,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> (table: NSTableView, header: NSTableHeaderView, scroll: NSScrollView) {
        let table = controller.tableView
        let header = try #require(table.headerView as? NSTableHeaderView, sourceLocation: sourceLocation)
        let scroll = try #require(table.enclosingScrollView, sourceLocation: sourceLocation)
        layout(controller)
        #expect(header.frame.height > 0, "表头必须有高度，否则测不出重叠", sourceLocation: sourceLocation)
        #expect(scroll.frame.height > 0 && scroll.frame.width > 0,
                "滚动视图必须已完成布局（当前 \(scroll.frame)）", sourceLocation: sourceLocation)
        return (table, header, scroll)
    }

    /// 一行在窗口坐标里的矩形；行高为 0 说明表格尚未完成行布局。
    private func rowRect(_ table: NSTableView, _ row: Int, sourceLocation: SourceLocation = #_sourceLocation) throws -> NSRect {
        let rect = table.rect(ofRow: row)
        #expect(rect.height > 0, "第 \(row) 行尚未布局（rect=\(rect)）", sourceLocation: sourceLocation)
        return table.convert(rect, to: nil)
    }

    /// 核心不变量：这一行必须完整落在滚动区内，且与表头矩形零相交。
    private func expectRowVisibleBelowHeader(
        _ table: NSTableView,
        _ header: NSTableHeaderView,
        _ scroll: NSScrollView,
        row: Int,
        label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let rowRect = try rowRect(table, row, sourceLocation: sourceLocation)
        let headerRect = windowRect(header)
        let scrollRect = windowRect(scroll)
        let overlap = NSIntersectionRect(rowRect, headerRect)
        #expect(overlap.height == 0,
                "\(label)：第 \(row) 行与表头重叠 \(overlap)pt（表头=\(headerRect)，该行=\(rowRect)）",
                sourceLocation: sourceLocation)
        #expect(scrollRect.contains(rowRect),
                "\(label)：第 \(row) 行必须完整可见（该行=\(rowRect)，可视区=\(scrollRect)）",
                sourceLocation: sourceLocation)
    }

    // MARK: - 回归：首行不能被表头盖住

    @Test("首帧渲染后首行完整可见且不与表头重叠")
    func firstRowIsFullyVisibleBelowHeader() throws {
        let controller = try makeLaidOutController()
        defer { controller.close() }
        let (table, header, scroll) = try requireLayoutReady(controller)

        controller.update(snapshot: snapshot(count: 60), result: result(count: 60))
        layout(controller)

        try expectRowVisibleBelowHeader(table, header, scroll, row: 0, label: "首帧渲染")
        #expect(controller.resultRows.count == 60)
    }

    @Test("内容不足一屏时首行同样不被表头盖住")
    func firstRowVisibleWhenContentShorterThanViewport() throws {
        let controller = try makeLaidOutController()
        defer { controller.close() }
        let (table, header, scroll) = try requireLayoutReady(controller)

        controller.update(snapshot: snapshot(count: 3), result: result(count: 3))
        layout(controller)

        try expectRowVisibleBelowHeader(table, header, scroll, row: 0, label: "内容不足一屏")
    }

    @Test("空结果清空后再渲染，首行仍不被表头盖住")
    func emptyRenderThenResultsKeepsFirstRowVisible() throws {
        let controller = try makeLaidOutController()
        defer { controller.close() }
        let (table, header, scroll) = try requireLayoutReady(controller)

        // 先走一次「0 结果」分支（它会主动滚动），再渲染真实结果。
        controller.update(snapshot: snapshot(count: 0, generation: 1), result: result(count: 0, generation: 1))
        layout(controller)
        controller.update(snapshot: snapshot(count: 60, generation: 2), result: result(count: 60, generation: 2))
        layout(controller)

        try expectRowVisibleBelowHeader(table, header, scroll, row: 0, label: "空结果后重渲染")
    }

    @Test("恢复状态（历史遗留的 offset 0）后首行仍可见")
    func restoreStateWithZeroOffsetKeepsFirstRowVisible() throws {
        let controller = try makeLaidOutController()
        defer { controller.close() }
        let (table, header, scroll) = try requireLayoutReady(controller)

        controller.update(snapshot: snapshot(count: 60), result: result(count: 60))
        layout(controller)
        // 旧版本写盘的 scrollOffset 就是 0（那时把首行藏在表头下的那个值）。
        controller.restoreState(
            NavigationState(
                query: SearchQuery(text: "报告"),
                selectedKey: nil,
                scrollAnchorKey: nil,
                scrollOffset: 0
            )
        )
        layout(controller)

        try expectRowVisibleBelowHeader(table, header, scroll, row: 0, label: "恢复 offset 0")
    }

    // MARK: - 既有滚动恢复行为保留

    @Test("按锚点恢复：目标行进入视口且不被表头盖住")
    func anchorRestoreBringsRowIntoViewBelowHeader() throws {
        let controller = try makeLaidOutController()
        defer { controller.close() }
        let (table, header, scroll) = try requireLayoutReady(controller)

        controller.update(snapshot: snapshot(count: 60), result: result(count: 60))
        layout(controller)
        let anchorKey = controller.resultRows.resultKeys[40]
        controller.restoreState(
            NavigationState(
                query: SearchQuery(text: "报告"),
                selectedKey: anchorKey,
                scrollAnchorKey: anchorKey,
                scrollOffset: 0
            )
        )
        layout(controller)

        try expectRowVisibleBelowHeader(table, header, scroll, row: 40, label: "锚点恢复到第 40 行")
        // 锚点恢复必须真的滚动了（否则等于没恢复）。
        #expect(scroll.contentView.bounds.origin.y > 0, "按锚点恢复后应滚到文档中部")
    }

    /// 内容区（表头下方的真正可读区域）在窗口坐标里的矩形。
    ///
    /// AppKit 把表头**盖在滚动视图顶部**（clip view 并没有被缩），所以
    /// 「可视区」必须自己扣掉表头那条带子，否则会把表头覆盖的部分当成可视。
    private func contentRectBelowHeader(_ header: NSTableHeaderView, _ scroll: NSScrollView) -> NSRect {
        let scrollRect = windowRect(scroll)
        let headerRect = windowRect(header)
        return NSRect(
            x: scrollRect.minX,
            y: scrollRect.minY,
            width: scrollRect.width,
            height: max(0, headerRect.minY - scrollRect.minY)
        )
    }

    private func windowRowRect(_ table: NSTableView, _ row: Int) -> NSRect {
        table.convert(table.rect(ofRow: row), to: nil)
    }

    /// 从窗口坐标里找出「表头下方第一个完整可见的行」。
    ///
    /// 不依赖生产实现（不调 `currentScrollAnchorKey` 等内部逻辑），只用行矩形与内容区比较。
    /// 窗口坐标系 **y 向上、不 flipped**：`minY` 是下沿、`maxY` 是上沿。
    ///
    /// 算法：按行索引从小到大有序扫描，返回**第一个**垂直方向完整落入内容区的行。
    /// 不做提前 return —— 滚动到文档中部时，第 0 行位于内容区**上方**（`rect.minY >= contentRect.maxY`），
    /// 它和它后面若干行都不可见，若在这里提前判 nil 就永远走不到真正可见的行。
    /// 「取到的确实是最上面那个 full 行」由调用方的上一行反证负责。
    ///
    /// 两种「被裁掉」要分开看：
    /// - 滚到顶部时首行被表头**整行**盖住 —— 要防的原缺陷；
    /// - 滚动中位于视口上方的行从上方滑过表头 —— 正常行为，不当缺陷。
    private func topmostFullyVisibleRow(_ table: NSTableView, contentRect: NSRect) -> Int? {
        for index in 0..<table.numberOfRows {
            let rect = windowRowRect(table, index)
            let fullyVisible = rect.minY >= contentRect.minY - 0.5 && rect.maxY <= contentRect.maxY + 0.5
            if fullyVisible { return index }
        }
        return nil
    }

    @Test("按偏移量恢复：表头下最上面完整可见行不被表头盖住")
    func offsetRestoreKeepsTopRowBelowHeader() throws {
        let controller = try makeLaidOutController()
        defer { controller.close() }
        let (table, header, scroll) = try requireLayoutReady(controller)

        controller.update(snapshot: snapshot(count: 60), result: result(count: 60))
        layout(controller)
        controller.restoreState(
            NavigationState(query: SearchQuery(text: "报告"), scrollOffset: 300)
        )
        layout(controller)

        // 既有行为：偏移量原样生效（不因为表头让位而被改写）。
        #expect(abs(scroll.contentView.bounds.origin.y - 300) < 0.5,
                "按偏移量恢复应落在记录的偏移上（当前 \(scroll.contentView.bounds.origin.y)）")

        let headerRect = windowRect(header)
        let scrollRect = windowRect(scroll)
        // 前提：表头确实压在滚动视图顶部；否则下面的内容区算法没有意义。
        #expect(abs(headerRect.maxY - scrollRect.maxY) < 0.5,
                "表头应贴在滚动视图顶部（表头=\(headerRect)，滚动区=\(scrollRect)）")
        let contentRect = contentRectBelowHeader(header, scroll)
        #expect(contentRect.height > 0, "表头下方应有内容区（当前 \(contentRect)）")

        let topRow = try #require(topmostFullyVisibleRow(table, contentRect: contentRect), "偏移量恢复后应有完整可见的行")

        // 邻行证据：这个行必须真的是「最上面完整可见」的那行——
        // 上一行不得也完整可见（否则说明取错了行，绿灯是假的）。
        if topRow > 0 {
            let above = windowRowRect(table, topRow - 1)
            #expect(!(above.minY >= contentRect.minY - 0.5 && above.maxY <= contentRect.maxY + 0.5),
                    "第 \(topRow - 1) 行不应也完整可见（该行=\(above)，内容区=\(contentRect)）")
        }

        let topRect = windowRowRect(table, topRow)
        let overlap = NSIntersectionRect(topRect, headerRect)
        #expect(overlap.height == 0,
                "第 \(topRow) 行不应压在表头上（重叠 \(overlap.height)pt，该行=\(topRect)，表头=\(headerRect)）")
        #expect(contentRect.contains(topRect),
                "第 \(topRow) 行应完整落在表头下方的内容区里（该行=\(topRect)，内容区=\(contentRect)）")
    }

    // MARK: - 既有表头排序行为保留

    @Test("布局修复不影响表头排序与查询")
    func sortStillDrivesQueryAfterScrollRestore() throws {
        let controller = try makeLaidOutController()
        defer { controller.close() }
        _ = try requireLayoutReady(controller)

        controller.update(snapshot: snapshot(count: 60), result: result(count: 60))
        layout(controller)
        #expect(controller.currentQuery.sort == .name)
        #expect(controller.currentQuery.ascending == true)

        // 生产实现的既有语义：切到新字段时，name/path 默认升序，其余字段默认降序；
        // 同一列再点一次才反向。这里写准，不反向迁就实现。
        controller.requestSort(column: 2) // 大小列
        #expect(controller.currentQuery.sort == .size, "点击可排序列应切换排序字段")
        #expect(controller.currentQuery.ascending == false, "首次切到大小列按实现默认降序")
        controller.requestSort(column: 2) // 同一列再点：反向
        #expect(controller.currentQuery.sort == .size)
        #expect(controller.currentQuery.ascending == true, "再次点击同一列应反向")

        // 滚动恢复不应改动查询
        let before = controller.currentQuery
        controller.restoreState(NavigationState(query: before, scrollOffset: 120))
        layout(controller)
        #expect(controller.currentQuery.sort == before.sort)
        #expect(controller.currentQuery.ascending == before.ascending)
    }
}
