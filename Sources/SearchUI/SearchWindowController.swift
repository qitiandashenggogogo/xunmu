import AppKit
import SearchCore

/// 搜索窗口回调。由主控实现（索引、扫描与应用生命周期都在主控侧）。
@MainActor
public protocol SearchWindowDelegate: AnyObject {
    func searchWindow(_ window: SearchWindowController, didChange query: SearchQuery)
    func searchWindowDidRequestAddRoot(_ window: SearchWindowController)
    func searchWindowDidRequestRescan(_ window: SearchWindowController)
    func searchWindowDidRequestPause(_ window: SearchWindowController)
    func searchWindowDidRestoreNavigation(_ window: SearchWindowController)
}

@MainActor
public extension SearchWindowDelegate {
    /// 后退/前进已即时恢复到缓存帧（查询、结果、选区、滚动）之后调用。
    /// 主控应在这里取消在途查询，并对该帧的快照/结果做后台重算；不实现也不影响 UI。
    func searchWindowDidRestoreNavigation(_ window: SearchWindowController) {}
}

/// 原生 macOS 搜索结果窗口。
///
/// 职责边界：
/// - 只消费 `CatalogSnapshot` + `SearchResult`（键列表），自己不排序、不扫描、不读磁盘；
///   逐行数据按需构建（只为可见行格式化），不预先为全部命中创建行对象。
/// - 同代才渲染：快照与结果代际不一致、或结果已取消时一律忽略，避免旧结果覆盖新结果。
/// - 应用内目录范围导航保存完整 `NavigationState` + 当时的快照/结果；打开文件、双击目录不产生历史。
@MainActor
public final class SearchWindowController: NSWindowController {

    // MARK: - 对外状态

    public weak var searchDelegate: (any SearchWindowDelegate)?

    /// 当前渲染所用的行数据源（键 + 不可变查表 + 可见行缓存）。
    public private(set) var resultRows: ResultRowStore

    /// 结果表（公开为 AppKit 标准类型，避免把内部类型泄露到公开 API）。
    public var tableView: NSTableView { resultsTable }

    public var canGoBack: Bool { history.canGoBack }
    public var canGoForward: Bool { history.canGoForward }

    // MARK: - 内部状态

    private let resultsTable: ResultsTableView
    private let tableController: ResultsTableController
    private var history = NavigationHistory()
    private var snapshot = CatalogSnapshot(generation: 0, entries: [], volumes: [])
    private var result = SearchResult(generation: 0, keys: [], isCancelled: true)
    private var hasRendered = false
    private var renderedGeneration: UInt64 = 0

    private var scope: SearchScope = .all
    private var advancedValues = AdvancedFilterValues.none
    private var advancedFilters = ResolvedFilters.none
    private var sort: SearchSort = .name
    private var ascending = true

    private var isApplyingProgrammaticChange = false
    /// 结果尚未到达时的待恢复状态（例如重启后从磁盘读回的状态）。
    private var pendingRestoreState: NavigationState?
    private var advancedPanel: AdvancedFilterPanelController?
    private let quickLookPresenter = QuickLookPresenter()

    // MARK: - 控件

    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let volumePopUp = NSPopUpButton()
    private let extensionField = NSTextField(string: "")
    private let foldersOnlyCheckbox = NSButton(checkboxWithTitle: "只看文件夹", target: nil, action: nil)
    private let advancedButton = NSButton(title: "高级筛选…", target: nil, action: nil)
    private let addRootButton = NSButton(title: "添加位置", target: nil, action: nil)
    private let rescanButton = NSButton(title: "重新检查", target: nil, action: nil)
    private let pauseButton = NSButton(title: "暂停", target: nil, action: nil)
    private let enterDirectoryButton = NSButton(title: "浏览此处", target: nil, action: nil)
    private let backButton = NSButton(title: "后退", target: nil, action: nil)
    private let forwardButton = NSButton(title: "前进", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    /// 只有状态带系统详细信息时才出现；点开用原生说明窗原样展示。
    private let statusDetailButton = NSButton(title: "详情", target: nil, action: nil)
    private var statusMessage = StatusMessage("")
    private var isShowingStatusDetail = false
    private let scopeLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()

    // MARK: - 初始化

    public init() {
        let table = ResultsTableView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        resultsTable = table
        tableController = ResultsTableController(tableView: table)
        resultRows = ResultRowStore(snapshot: CatalogSnapshot(generation: 0, entries: [], volumes: []), keys: [])
        super.init(window: SearchWindowController.makeWindow())
        configure()
    }

    public required init?(coder: NSCoder) {
        let table = ResultsTableView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        resultsTable = table
        tableController = ResultsTableController(tableView: table)
        resultRows = ResultRowStore(snapshot: CatalogSnapshot(generation: 0, entries: [], volumes: []), keys: [])
        super.init(window: SearchWindowController.makeWindow())
        configure()
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 720, height: 360)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func configure() {
        guard let window else { return }
        shouldCascadeWindows = true
        window.toolbarStyle = .expanded
        window.contentView = makeContentView()
        configureControls()
        configureTableView()
        let toolbar = makeToolbar()
        toolbar.delegate = self
        window.toolbar = toolbar
        updateVolumePopUp()
        updateSortIndicators()
        updateNavigationButtons()
        updateScopeLabel()
        countLabel.stringValue = "共 0 项"
        statusLabel.stringValue = ""
        setScanning(false)
        setPausedState(false)
    }

    // MARK: - 视图构建

    private func makeContentView() -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 560))

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let statusBar = NSView()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        // 窄窗口时先裁短提示，不挤掉「详情」、范围与计数。
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusDetailButton.bezelStyle = .inline
        statusDetailButton.controlSize = .small
        statusDetailButton.font = .systemFont(ofSize: 11)
        statusDetailButton.isHidden = true
        statusDetailButton.translatesAutoresizingMaskIntoConstraints = false
        statusDetailButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusDetailButton.setContentHuggingPriority(.required, for: .horizontal)

        scopeLabel.font = .systemFont(ofSize: 11)
        scopeLabel.textColor = .secondaryLabelColor
        scopeLabel.lineBreakMode = .byTruncatingTail
        scopeLabel.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false

        root.addSubview(scrollView)
        root.addSubview(statusBar)
        statusBar.addSubview(separator)
        statusBar.addSubview(statusLabel)
        statusBar.addSubview(statusDetailButton)
        statusBar.addSubview(scopeLabel)
        statusBar.addSubview(countLabel)
        statusBar.addSubview(progressIndicator)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            statusBar.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),

            separator.topAnchor.constraint(equalTo: statusBar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),

            progressIndicator.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 8),
            progressIndicator.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: progressIndicator.trailingAnchor, constant: 6),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),

            statusDetailButton.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 6),
            statusDetailButton.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),

            scopeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: statusDetailButton.trailingAnchor, constant: 12),
            scopeLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),

            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scopeLabel.trailingAnchor, constant: 12),
            countLabel.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -10),
            countLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])

        return root
    }

    private func configureTableView() {
        let table = resultsTable
        for column in ResultColumn.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.minWidth = column.minWidth
            tableColumn.width = column.minWidth
            table.addTableColumn(tableColumn)
        }
        table.rowHeight = 20
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .inset
        table.dataSource = tableController
        table.delegate = tableController
        table.target = self
        table.doubleAction = #selector(openSelection)
        table.onQuickLook = { [weak self] in self?.presentQuickLook() }

        let header = ResultsHeaderView()
        header.onColumnClicked = { [weak self] column in self?.requestSort(column: column) }
        table.headerView = header

        scrollView.documentView = table
        table.frame = NSRect(origin: .zero, size: NSSize(width: 960, height: 400))
        table.autoresizingMask = [.width]

        tableController.owner = self
    }

    private func configureControls() {
        searchField.placeholderString = "搜索文件名"
        searchField.toolTip = "输一两个字也能找到。\n名称或路径里的任意片段都能匹配。"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(controlEntered)

        volumePopUp.pullsDown = false
        volumePopUp.target = self
        volumePopUp.action = #selector(volumePopUpChanged)
        volumePopUp.toolTip = "只在选定的磁盘里查找。"

        extensionField.placeholderString = "文件后缀"
        extensionField.toolTip = "可填多个，用逗号隔开。\n例如 pdf,docx"
        extensionField.target = self
        extensionField.action = #selector(controlEntered)
        extensionField.widthAnchor.constraint(equalToConstant: 110).isActive = true

        foldersOnlyCheckbox.target = self
        foldersOnlyCheckbox.action = #selector(controlEntered)
        foldersOnlyCheckbox.toolTip = "结果里只列出文件夹。"

        advancedButton.target = self
        advancedButton.action = #selector(showAdvancedPanel)
        advancedButton.toolTip = "按大小、修改时间细化。"
        addRootButton.target = self
        addRootButton.action = #selector(addRootTapped)
        addRootButton.toolTip = "选择文件夹或外接硬盘。"
        rescanButton.target = self
        rescanButton.action = #selector(rescanTapped)
        rescanButton.toolTip = "检查已添加位置的变动。"
        pauseButton.target = self
        pauseButton.action = #selector(pauseTapped)
        enterDirectoryButton.target = self
        enterDirectoryButton.action = #selector(enterDirectoryTapped)
        enterDirectoryButton.toolTip = "只看所选文件夹的直接内容。"
        backButton.target = self
        backButton.action = #selector(backTapped)
        backButton.toolTip = "回到上一个搜索。"
        forwardButton.target = self
        forwardButton.action = #selector(forwardTapped)
        forwardButton.toolTip = "前往下一个搜索。"

        statusDetailButton.target = self
        statusDetailButton.action = #selector(showStatusDetail)
        statusDetailButton.toolTip = "查看系统给出的详细信息。"
        statusDetailButton.setAccessibilityLabel("查看状态详情")

        let panel = AdvancedFilterPanelController()
        panel.onApply = { [weak self] values in self?.applyAdvancedFilters(values, notify: true) }
        panel.onClear = { [weak self] values in self?.applyAdvancedFilters(values, notify: true) }
        advancedPanel = panel
    }

    // MARK: - 公共接口

    /// 渲染一批结果。快照与结果代际不一致、结果已取消、或代际落后于已渲染内容时忽略。
    public func update(snapshot: CatalogSnapshot, result: SearchResult) {
        guard snapshot.generation == result.generation else { return }
        guard !result.isCancelled else { return }
        guard !hasRendered || snapshot.generation >= renderedGeneration else { return }

        render(snapshot: snapshot, result: result)
        history.commit(NavigationFrame(state: currentState(), snapshot: snapshot, result: result))
        updateNavigationButtons()
    }

    /// 普通状态：没有详细信息，会顺带收起上一条错误的「详情」。
    public func setStatus(_ text: String) {
        setStatus(StatusMessage(text))
    }

    /// 白话短提示显示在状态栏；系统详细信息只挂在「详情」后面，原样保留。
    /// 新消息总是整体替换旧消息：恢复正常后不会残留旧错误的详情。
    public func setStatus(_ message: StatusMessage) {
        statusMessage = message
        statusLabel.stringValue = message.text
        // 状态栏一行放不下时，悬停仍能看到完整的短提示。
        statusLabel.toolTip = message.text.isEmpty ? nil : message.text
        statusDetailButton.isHidden = message.detail == nil
    }

    /// 当前状态栏消息（供 UI 自测断言）。
    public var currentStatus: StatusMessage { statusMessage }

    /// 「详情」按钮当前是否可见（供 UI 自测断言）。
    public var isStatusDetailAvailable: Bool { !statusDetailButton.isHidden }

    /// 原生说明窗：标题是白话短提示，正文是系统原文。同一时间只开一个，重复错误不叠窗口。
    @objc func showStatusDetail() {
        guard let detail = statusMessage.detail, !isShowingStatusDetail else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = statusMessage.text
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        isShowingStatusDetail = true
        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { [weak self] _ in self?.isShowingStatusDetail = false }
        } else {
            alert.runModal()
            isShowingStatusDetail = false
        }
    }

    public func setScanning(_ scanning: Bool) {
        // 扫描中 ≠ 已暂停：按钮文案由 setPausedState 决定。
        if scanning {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
    }

    /// 暂停/继续状态：暂停时按钮显示「继续」，正常时显示「暂停」。
    public func setPausedState(_ paused: Bool) {
        pauseButton.title = paused ? "继续" : "暂停"
        pauseButton.toolTip = paused ? "继续检查" : "暂停检查"
    }

    /// 暂停按钮当前文案（供 UI 自测断言）。
    public var pauseButtonTitle: String { pauseButton.title }

    public func captureState() -> NavigationState {
        currentState()
    }

    public func restoreState(_ state: NavigationState) {
        isApplyingProgrammaticChange = true
        applyQueryToControls(state.query)
        isApplyingProgrammaticChange = false

        if hasRendered {
            pendingRestoreState = nil
            render(snapshot: snapshot, result: result)
            restoreSelection(state.selectedKey)
            restoreScroll(anchorKey: state.scrollAnchorKey, offset: state.scrollOffset)
        } else {
            // 首批结果还没回来：先存住，等下一次 update 渲染时再应用，避免重启丢选区。
            pendingRestoreState = state
        }
        updateNavigationButtons()
    }

    /// 以编程方式写入查询控件（本身不触发回调；主控可据此自行发起搜索）。
    public func setQuery(_ query: SearchQuery) {
        isApplyingProgrammaticChange = true
        applyQueryToControls(query)
        isApplyingProgrammaticChange = false
        notifyQueryChanged()
    }

    /// 当前查询（由控件与范围状态组装）。
    public var currentQuery: SearchQuery {
        var query = SearchQuery()
        query.text = searchField.stringValue
        query.scope = scope
        query.extensions = ExtensionFilterParser.parse(extensionField.stringValue)
        query.foldersOnly = foldersOnlyCheckbox.state == .on
        query.minSize = advancedFilters.minSize
        query.maxSize = advancedFilters.maxSize
        query.modifiedAfter = advancedFilters.modifiedAfter
        query.modifiedBefore = advancedFilters.modifiedBefore
        query.caseSensitive = advancedFilters.caseSensitive
        query.sort = sort
        query.ascending = ascending
        return query
    }

    /// 把某个目录设为搜索范围（recursive = false 表示只看该目录直属子项）。
    /// 进入前先把当前完整帧（查询 + 结果 + 选区 + 滚动）存入历史，否则后退无处可回。
    public func enterDirectory(_ key: EntryKey, recursive: Bool) {
        guard let index = resultRows.index(of: key), let row = resultRows.row(at: index), row.isDirectory else { return }
        preserveCurrentFrame()
        scope = .directory(volumeID: row.volumeID, relativePath: row.relativePath, recursive: recursive)
        updateVolumePopUp()
        updateScopeLabel()
        notifyQueryChanged()
    }

    /// 把当前状态（含选区与滚动锚点）作为一帧存入导航历史。
    private func preserveCurrentFrame() {
        guard hasRendered else { return }
        history.commit(NavigationFrame(state: currentState(), snapshot: snapshot, result: result))
    }

    public func goBack() {
        guard let frame = history.goBack() else { return }
        pendingRestoreState = nil
        apply(frame: frame)
        searchDelegate?.searchWindowDidRestoreNavigation(self)
    }

    public func goForward() {
        guard let frame = history.goForward() else { return }
        pendingRestoreState = nil
        apply(frame: frame)
        searchDelegate?.searchWindowDidRestoreNavigation(self)
    }

    /// 清空导航历史（例如索引被整体重建）。
    public func resetNavigation() {
        history.reset(to: nil)
        updateNavigationButtons()
    }

    /// 外部（主控）接入新能力后刷新工具栏/菜单可用性。
    public func refreshActionsAvailability() {
        updateNavigationButtons()
    }

    // MARK: - 渲染

    private func apply(frame: NavigationFrame) {
        pendingRestoreState = nil
        isApplyingProgrammaticChange = true
        applyQueryToControls(frame.state.query)
        isApplyingProgrammaticChange = false

        render(snapshot: frame.snapshot, result: frame.result)
        restoreSelection(frame.state.selectedKey)
        restoreScroll(anchorKey: frame.state.scrollAnchorKey, offset: frame.state.scrollOffset)
        updateNavigationButtons()
    }

    private func render(snapshot: CatalogSnapshot, result: SearchResult) {
        let previousSelection = tableController.selectedKey
        let previousAnchor = currentScrollAnchorKey()
        let previousOffset = currentScrollOffset()

        self.snapshot = snapshot
        self.result = result
        if snapshot.generation == resultRows.generation && resultRows.entryCount == snapshot.entries.count {
            // 同代：复用已有查表，只换结果键与行缓存。
            resultRows = resultRows.reusing(keys: result.keys)
        } else {
            resultRows = ResultRowStore(snapshot: snapshot, keys: result.keys)
        }
        tableController.apply(store: resultRows)
        resultsTable.reloadData()

        renderedGeneration = snapshot.generation
        hasRendered = true

        updateVolumePopUp(volumes: snapshot.volumes)
        countLabel.stringValue = "共 \(resultRows.count) 项"
        updateSortIndicators()
        updateScopeLabel()
        updateNavigationButtons()

        if resultRows.count == 0 {
            resultsTable.deselectAll(nil)
            // 不能用 scroll(to: .zero)：那会取消表头让位，首行会被表头盖住。
            scrollToContentTop()
        } else {
            restoreSelection(previousSelection)
            restoreScroll(anchorKey: previousAnchor, offset: previousOffset)
            if let pending = pendingRestoreState {
                pendingRestoreState = nil
                restoreSelection(pending.selectedKey)
                restoreScroll(anchorKey: pending.scrollAnchorKey, offset: pending.scrollOffset)
            }
        }
    }

    private func currentState() -> NavigationState {
        NavigationState(
            query: currentQuery,
            selectedKey: tableController.selectedKey,
            scrollAnchorKey: currentScrollAnchorKey(),
            scrollOffset: currentScrollOffset()
        )
    }

    private func restoreSelection(_ key: EntryKey?) {
        tableController.select(key: key)
    }

    private func currentScrollAnchorKey() -> EntryKey? {
        let visible = scrollView.contentView.documentVisibleRect
        let point = NSPoint(x: visible.minX + 1, y: visible.minY + 1)
        let row = resultsTable.row(at: point)
        guard row >= 0 else { return nil }
        return tableController.row(at: row)?.key
    }

    private func currentScrollOffset() -> Double {
        Double(scrollView.contentView.bounds.origin.y)
    }

    private func restoreScroll(anchorKey: EntryKey?, offset: Double) {
        let clip = scrollView.contentView
        let top = contentTopOffset
        let documentHeight = max(resultsTable.bounds.height, CGFloat(resultRows.count) * resultsTable.rowHeight)
        // 下界同样是 top：内容不足一屏时若夹到 0，首行会退回表头底下。
        let maxOffset = max(top, documentHeight - clip.bounds.height)
        let target: CGFloat
        if offset > 0, offset <= maxOffset + 1 {
            target = CGFloat(offset)
        } else if let anchorKey, let index = resultRows.index(of: anchorKey), index >= 0 {
            target = resultsTable.rect(ofRow: index).minY + top
        } else {
            target = top
        }
        clip.scroll(to: NSPoint(x: 0, y: min(max(top, target), maxOffset)))
    }

    /// 「滚到最上」的合法 `NSClipView.bounds.origin.y`：**不是 `.zero`，而是 `-表头高度`**。
    ///
    /// AppKit 把表头画在滚动视图顶部（而不是把 clip view 往下缩），并靠
    /// `bounds.origin.y == -表头高度` 给表头让位。实测：静止时 bounds.origin.y == -28；
    /// 一旦 `scroll(to: .zero)`，文档整体上移 28pt，首行（行高 20）被表头整行盖住。
    private var contentTopOffset: CGFloat {
        -(resultsTable.headerView?.frame.height ?? 0)
    }

    private func scrollToContentTop() {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: contentTopOffset))
    }

    // MARK: - 查询同步

    private func notifyQueryChanged() {
        guard !isApplyingProgrammaticChange else { return }
        searchDelegate?.searchWindow(self, didChange: currentQuery)
        updateNavigationButtons()
    }

    private func applyQueryToControls(_ query: SearchQuery) {
        searchField.stringValue = query.text
        extensionField.stringValue = query.extensions.joined(separator: ",")
        foldersOnlyCheckbox.state = query.foldersOnly ? .on : .off
        scope = query.scope
        sort = query.sort
        ascending = query.ascending

        advancedValues = AdvancedFilterValues(
            minSizeText: AdvancedFilterResolver.sizeText(for: query.minSize),
            maxSizeText: AdvancedFilterResolver.sizeText(for: query.maxSize),
            useModifiedAfter: query.modifiedAfter != nil,
            modifiedAfter: query.modifiedAfter ?? Date(timeIntervalSince1970: 0),
            useModifiedBefore: query.modifiedBefore != nil,
            modifiedBefore: query.modifiedBefore ?? Date(),
            caseSensitive: query.caseSensitive
        )
        advancedFilters = ResolvedFilters(
            minSize: query.minSize,
            maxSize: query.maxSize,
            modifiedAfter: query.modifiedAfter,
            modifiedBefore: query.modifiedBefore,
            caseSensitive: query.caseSensitive
        )
        updateVolumePopUp()
        updateScopeLabel()
    }

    private func applyAdvancedFilters(_ values: AdvancedFilterValues, notify: Bool) {
        guard let (_, resolved) = advancedPanel?.currentValues() else {
            setStatus("筛选条件有误，请检查大小或日期。")
            return
        }
        advancedValues = values
        advancedFilters = resolved
        if notify { notifyQueryChanged() }
    }

    // MARK: - 范围与卷

    private func updateVolumePopUp(volumes: [VolumeRecord]? = nil) {
        let records = volumes ?? snapshot.volumes
        let previousVolumeID = volumePopUp.selectedItem?.representedObject as? String

        volumePopUp.removeAllItems()
        if case .directory(let volumeID, let path, _) = scope {
            let volumeName = records.first { $0.id == volumeID }?.name ?? volumeID
            let item = NSMenuItem(title: "文件夹：\(volumeName)", action: nil, keyEquivalent: "")
            item.representedObject = "dir:\(volumeID):\(path)"
            volumePopUp.menu?.addItem(item)
        }
        volumePopUp.addItem(withTitle: "全部磁盘")
        for volume in records {
            volumePopUp.addItem(withTitle: volume.isOnline ? volume.name : "\(volume.name)（未连接）")
            if let last = volumePopUp.menu?.items.last {
                last.representedObject = "volume:\(volume.id)"
                if !volume.isOnline { last.isEnabled = false }
            }
        }

        let desired: String?
        switch scope {
        case .all:
            desired = nil
        case .volume(let id):
            desired = "volume:\(id)"
        case .directory(let volumeID, let path, _):
            desired = "dir:\(volumeID):\(path)"
        }
        let target = desired ?? previousVolumeID
        if let target, let index = volumePopUp.menu?.items.firstIndex(where: { $0.representedObject as? String == target }) {
            volumePopUp.selectItem(at: index)
        } else {
            volumePopUp.selectItem(at: 0)
        }
    }

    @objc private func volumePopUpChanged() {
        guard let represented = volumePopUp.selectedItem?.representedObject as? String else {
            scope = .all
            updateScopeLabel()
            notifyQueryChanged()
            return
        }
        if represented.hasPrefix("dir:") {
            updateScopeLabel()
            return
        }
        let id = String(represented.dropFirst("volume:".count))
        scope = .volume(id)
        updateScopeLabel()
        notifyQueryChanged()
    }

    private func updateScopeLabel() {
        switch scope {
        case .all:
            scopeLabel.stringValue = "范围：已添加位置"
        case .volume(let id):
            let name = snapshot.volumes.first { $0.id == id }?.name ?? id
            scopeLabel.stringValue = "范围：磁盘 \(name)"
        case .directory(let volumeID, let path, let recursive):
            let name = snapshot.volumes.first { $0.id == volumeID }?.name ?? volumeID
            scopeLabel.stringValue = "范围：\(name)/\(path) \(recursive ? "含子文件夹" : "只看本层")"
        }
    }

    private func updateNavigationButtons() {
        backButton.isEnabled = history.canGoBack
        forwardButton.isEnabled = history.canGoForward
        let selectedRow = tableController.selectedKey
            .flatMap { resultRows.index(of: $0) }
            .flatMap { resultRows.row(at: $0) }
        enterDirectoryButton.isEnabled = selectedRow?.isDirectory ?? false
    }

    private func updateSortIndicators() {
        for column in resultsTable.tableColumns {
            guard let resultColumn = ResultColumn(rawValue: column.identifier.rawValue),
                  let columnSort = resultColumn.sort else {
                column.sortDescriptorPrototype = nil
                continue
            }
            column.sortDescriptorPrototype = (columnSort == sort)
                ? NSSortDescriptor(key: nil, ascending: ascending)
                : nil
        }
    }

    // MARK: - 内部回调（结果表 / 表头）

    func tableSelectionDidChange() {
        updateNavigationButtons()
    }

    func requestSort(column: Int) {
        guard let resultColumn = tableController.column(at: column), let newSort = resultColumn.sort else { return }
        if sort == newSort {
            ascending.toggle()
        } else {
            sort = newSort
            ascending = (newSort == .name || newSort == .path)
        }
        updateSortIndicators()
        notifyQueryChanged()
    }

    func openRow(at rowIndex: Int) {
        guard let row = resultRows.row(at: rowIndex) else { return }
        // 打开不清除查询/选区/滚动，也不写入导航历史。
        FileActions.open(row) { [weak self] text in self?.setStatus(text) }
    }

    private func selectedRows() -> [ResultRow] {
        tableController.selectedKeys.compactMap { resultRows.index(of: $0) }.compactMap { resultRows.row(at: $0) }
    }

    func makeContextMenu() -> NSMenu {
        let rows = selectedRows()
        let isDirectory = rows.first?.isDirectory ?? false

        let menu = NSMenu()
        let open = NSMenuItem(title: "打开", action: #selector(openSelection), keyEquivalent: "")
        open.target = self
        open.isEnabled = !rows.isEmpty
        menu.addItem(open)

        let reveal = NSMenuItem(title: "在访达显示", action: #selector(revealSelection), keyEquivalent: "")
        reveal.target = self
        reveal.isEnabled = !rows.isEmpty
        menu.addItem(reveal)

        let copy = NSMenuItem(title: "复制路径", action: #selector(copyPathSelection), keyEquivalent: "c")
        copy.target = self
        copy.isEnabled = !rows.isEmpty
        menu.addItem(copy)

        let quickLook = NSMenuItem(title: "快速查看", action: #selector(quickLookSelection), keyEquivalent: "")
        quickLook.target = self
        quickLook.isEnabled = !rows.isEmpty
        menu.addItem(quickLook)

        menu.addItem(.separator())

        let enter = NSMenuItem(title: "浏览此处", action: #selector(enterDirectoryTapped), keyEquivalent: "")
        enter.toolTip = "只看所选文件夹的直接内容。"
        enter.target = self
        enter.isEnabled = isDirectory
        menu.addItem(enter)

        let enterRecursive = NSMenuItem(
            title: "搜索此处",
            action: #selector(enterDirectoryRecursivelyTapped),
            keyEquivalent: ""
        )
        enterRecursive.toolTip = "含所选文件夹及其子文件夹。"
        enterRecursive.target = self
        enterRecursive.isEnabled = isDirectory
        menu.addItem(enterRecursive)

        menu.addItem(.separator())

        let back = NSMenuItem(title: "后退", action: #selector(backTapped), keyEquivalent: "[")
        back.target = self
        back.isEnabled = history.canGoBack
        menu.addItem(back)

        let forward = NSMenuItem(title: "前进", action: #selector(forwardTapped), keyEquivalent: "]")
        forward.target = self
        forward.isEnabled = history.canGoForward
        menu.addItem(forward)

        return menu
    }

    private func presentQuickLook() {
        let rows = selectedRows()
        guard !rows.isEmpty else { return }
        if let error = quickLookPresenter.present(rows: rows) {
            setStatus(error.message)
        }
    }

    // MARK: - 动作

    @objc private func controlEntered() {
        notifyQueryChanged()
    }

    @objc private func showAdvancedPanel() {
        advancedPanel?.present(values: advancedValues, relativeTo: advancedButton)
    }

    // 内部（而非 private）：供 UI 冒烟测试直接触发，验证回调分发。
    @objc func addRootTapped() {
        searchDelegate?.searchWindowDidRequestAddRoot(self)
    }

    @objc func rescanTapped() {
        searchDelegate?.searchWindowDidRequestRescan(self)
    }

    @objc func pauseTapped() {
        searchDelegate?.searchWindowDidRequestPause(self)
    }

    @objc private func backTapped() {
        goBack()
    }

    @objc private func forwardTapped() {
        goForward()
    }

    @objc private func enterDirectoryTapped() {
        guard let key = tableController.selectedKey else { return }
        enterDirectory(key, recursive: false)
    }

    @objc private func enterDirectoryRecursivelyTapped() {
        guard let key = tableController.selectedKey else { return }
        enterDirectory(key, recursive: true)
    }

    @objc private func openSelection() {
        guard let row = selectedRows().first else { return }
        FileActions.open(row) { [weak self] text in self?.setStatus(text) }
    }

    @objc private func revealSelection() {
        guard let row = selectedRows().first else { return }
        FileActions.revealInFinder(row) { [weak self] text in self?.setStatus(text) }
    }

    @objc private func copyPathSelection() {
        guard let row = selectedRows().first else { return }
        FileActions.copyPath(row) { [weak self] text in self?.setStatus(text) }
    }

    @objc private func quickLookSelection() {
        presentQuickLook()
    }

    // MARK: - 窗口

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        syncTableWidth()
        window?.makeFirstResponder(searchField)
    }

    /// 窗口首次布局后把表格宽度对齐到滚动视图，避免首帧列宽异常。
    private func syncTableWidth() {
        let width = scrollView.contentSize.width
        guard width > 0 else { return }
        var frame = resultsTable.frame
        frame.size.width = width
        resultsTable.frame = frame
    }
}

// MARK: - NSSearchFieldDelegate

extension SearchWindowController: NSSearchFieldDelegate {
    public func controlTextDidChange(_ obj: Notification) {
        notifyQueryChanged()
    }
}

// MARK: - 工具栏

extension NSToolbarItem.Identifier {
    static let meBack = NSToolbarItem.Identifier("me.back")
    static let meForward = NSToolbarItem.Identifier("me.forward")
    static let meEnterDirectory = NSToolbarItem.Identifier("me.enterDirectory")
    static let meSearchField = NSToolbarItem.Identifier("me.searchField")
    static let meVolume = NSToolbarItem.Identifier("me.volume")
    static let meExtension = NSToolbarItem.Identifier("me.extension")
    static let meFoldersOnly = NSToolbarItem.Identifier("me.foldersOnly")
    static let meAdvanced = NSToolbarItem.Identifier("me.advanced")
    static let meAddRoot = NSToolbarItem.Identifier("me.addRoot")
    static let meRescan = NSToolbarItem.Identifier("me.rescan")
    static let mePause = NSToolbarItem.Identifier("me.pause")
}

extension SearchWindowController: NSToolbarDelegate {
    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "me.mainToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = true
        return toolbar
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .meAddRoot, .meBack, .meForward, .meEnterDirectory, .meSearchField, .meVolume, .meExtension,
            .meFoldersOnly, .meAdvanced, .meRescan, .mePause,
        ]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .flexibleSpace, .separator]
    }

    public func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.meBack, .meForward, .meEnterDirectory, .meAdvanced, .meAddRoot, .meRescan, .mePause]
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case .meSearchField:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "搜索"
            item.paletteLabel = "搜索"
            item.view = searchField
            item.minSize = NSSize(width: 220, height: 24)
            item.maxSize = NSSize(width: 520, height: 24)
            return item
        case .meVolume:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "磁盘"
            item.paletteLabel = "选择磁盘"
            item.view = volumePopUp
            return item
        case .meExtension:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "后缀"
            item.paletteLabel = "后缀筛选"
            item.view = extensionField
            return item
        case .meFoldersOnly:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "只看文件夹"
            item.paletteLabel = "只看文件夹"
            item.view = foldersOnlyCheckbox
            // 新文案比「仅文件夹」更长，最小宽度必须容纳完整复选框。
            item.minSize = NSSize(width: ceil(foldersOnlyCheckbox.intrinsicContentSize.width), height: 20)
            return item
        default:
            return makeButtonItem(identifier)
        }
    }

    private func makeButtonItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        let button: NSButton
        let label: String
        let action: Selector
        switch identifier {
        case .meBack:
            (button, label, action) = (backButton, "后退", #selector(backTapped))
        case .meForward:
            (button, label, action) = (forwardButton, "前进", #selector(forwardTapped))
        case .meEnterDirectory:
            (button, label, action) = (enterDirectoryButton, "浏览此处", #selector(enterDirectoryTapped))
        case .meAdvanced:
            (button, label, action) = (advancedButton, "高级筛选", #selector(showAdvancedPanel))
        case .meAddRoot:
            (button, label, action) = (addRootButton, "添加位置", #selector(addRootTapped))
        case .meRescan:
            (button, label, action) = (rescanButton, "重新检查", #selector(rescanTapped))
        case .mePause:
            (button, label, action) = (pauseButton, "暂停", #selector(pauseTapped))
        default:
            return nil
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.view = button
        item.target = self
        item.action = action
        return item
    }
}
