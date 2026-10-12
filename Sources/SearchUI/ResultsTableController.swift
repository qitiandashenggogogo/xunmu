import AppKit
import SearchCore

/// 负责空格触发快速查看的结果表。
final class ResultsTableView: NSTableView {
    var onQuickLook: (() -> Void)?
    var onContextClick: ((NSEvent) -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        if let onContextClick {
            onContextClick(event)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        // 空格 = 快速查看（仅在有选中行且未按修饰键时接管）
        let isSpace = event.charactersIgnoringModifiers == " " || event.keyCode == 49
        if isSpace, selectedRow >= 0, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            onQuickLook?()
            return
        }
        super.keyDown(with: event)
    }
}

/// 自定义表头：自己处理鼠标点击来触发排序，不依赖 AppKit 的表头点击委托方法。
final class ResultsHeaderView: NSTableHeaderView {
    /// 参数是列序号。
    var onColumnClicked: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard let table = tableView else { return }
        let point = convert(event.locationInWindow, from: nil)
        for column in 0..<table.tableColumns.count where headerRect(ofColumn: column).contains(point) {
            onColumnClicked?(column)
            return
        }
        super.mouseDown(with: event)
    }
}

/// NSTableView 数据源/代理。
///
/// 行数据来自 `ResultRowStore` 的按需构建（只有可见行会真正生成 ResultRow），
/// 不为每行创建 ViewModel，也不在滚动/绘制时读磁盘。
@MainActor
final class ResultsTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var tableView: ResultsTableView
    weak var owner: SearchWindowController?

    private(set) var store = ResultRowStore(snapshot: CatalogSnapshot(generation: 0, entries: [], volumes: []), keys: [])

    private static let nameCellID = NSUserInterfaceItemIdentifier("nameCell")
    private static let textCellID = NSUserInterfaceItemIdentifier("textCell")

    init(tableView: ResultsTableView) {
        self.tableView = tableView
        super.init()
        tableView.onContextClick = { [weak self] event in
            self?.showContextMenu(with: event)
        }
    }

    func apply(store: ResultRowStore) {
        self.store = store
    }

    var count: Int { store.count }

    func row(at index: Int) -> ResultRow? { store.row(at: index) }

    func index(of key: EntryKey) -> Int? { store.index(of: key) }

    var selectedKeys: [EntryKey] {
        tableView.selectedRowIndexes.compactMap { store.row(at: $0)?.key }
    }

    var selectedKey: EntryKey? { selectedKeys.first }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        store.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let columnID = ResultColumn(rawValue: tableColumn?.identifier.rawValue ?? ""),
              let resultRow = store.row(at: row) else { return nil }

        let text: String
        switch columnID {
        case .name: text = resultRow.name
        case .path: text = resultRow.parentRelativePath
        case .size: text = resultRow.sizeText
        case .modified: text = resultRow.modifiedText
        case .volume: text = resultRow.volumeName
        case .status: text = resultRow.statusText
        }

        if columnID == .name {
            let cell = (tableView.makeView(withIdentifier: Self.nameCellID, owner: self) as? NSTableCellView)
                ?? makeNameCell()
            cell.textField?.stringValue = text
            cell.textField?.toolTip = resultRow.relativePath
            cell.imageView?.image = TypeIconCache.shared.icon(for: resultRow)
            return cell
        }

        let cell = (tableView.makeView(withIdentifier: Self.textCellID, owner: self) as? NSTableCellView)
            ?? makeTextCell()
        cell.textField?.stringValue = text
        cell.textField?.alignment = columnID.alignment
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let resultRow = store.row(at: row), let url = resultRow.absoluteURL() else { return nil }
        return url as NSURL
    }

    // MARK: - NSTableViewDelegate

    func tableViewDidChangeSelection(_ notification: Notification) {
        owner?.tableSelectionDidChange()
    }

    func tableView(_ tableView: NSTableView, doubleClickedOnRow row: Int) {
        owner?.openRow(at: row)
    }

    private func showContextMenu(with event: NSEvent) {
        let location = tableView.convert(event.locationInWindow, from: nil)
        let clickedRow = tableView.row(at: location)
        if clickedRow >= 0, !tableView.selectedRowIndexes.contains(clickedRow) {
            tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        let menu = owner?.makeContextMenu() ?? NSMenu()
        menu.popUp(positioning: nil, at: location, in: tableView)
    }

    // MARK: - 便捷

    func column(at index: Int) -> ResultColumn? {
        ResultColumn.allCases.indices.contains(index) ? ResultColumn.allCases[index] : nil
    }

    func select(key: EntryKey?) {
        guard let key, let index = store.index(of: key) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    // MARK: - 单元构造

    private func makeTextCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Self.textCellID
        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingMiddle
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(textField)
        cell.textField = textField
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func makeNameCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Self.nameCellID
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(imageView)
        cell.addSubview(textField)
        cell.imageView = imageView
        cell.textField = textField
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
