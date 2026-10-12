import AppKit

/// 高级筛选面板（大小 / 修改时间 / 区分大小写），由工具栏「高级…」按钮以 popover 展示。
///
/// 面板只读写 `AdvancedFilterValues` 这一纯值类型，真正的解析与校验在
/// `AdvancedFilterResolver` 中完成（可单测）。
@MainActor
final class AdvancedFilterPanelController: NSViewController {
    var onApply: ((AdvancedFilterValues) -> Void)?
    var onClear: ((AdvancedFilterValues) -> Void)?

    private let minSizeField = NSTextField(string: "")
    private let maxSizeField = NSTextField(string: "")
    private let afterCheckbox = NSButton(checkboxWithTitle: "修改时间从", target: nil, action: nil)
    private let afterPicker = NSDatePicker()
    private let beforeCheckbox = NSButton(checkboxWithTitle: "截至", target: nil, action: nil)
    private let beforePicker = NSDatePicker()
    private let caseSensitiveCheckbox = NSButton(checkboxWithTitle: "区分大小写", target: nil, action: nil)
    private let messageLabel = NSTextField(labelWithString: "")
    private let endOfDayCheckbox = NSButton(checkboxWithTitle: "包含当天", target: nil, action: nil)

    private var current: AdvancedFilterValues = .none
    private var popover: NSPopover?

    // MARK: - 生命周期

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
        root.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        minSizeField.setAccessibilityLabel("最小文件大小")
        maxSizeField.setAccessibilityLabel("最大文件大小")
        stack.addArrangedSubview(makeRow(label: "文件大小", field: minSizeField))
        stack.addArrangedSubview(makeRow(label: "", field: maxSizeField))

        stack.addArrangedSubview(makeSeparator())

        let afterRow = NSStackView(views: [afterCheckbox, afterPicker, NSView()])
        afterRow.orientation = .horizontal
        afterRow.spacing = 6
        afterRow.alignment = .centerY
        stack.addArrangedSubview(afterRow)

        let beforeRow = NSStackView(views: [beforeCheckbox, beforePicker, endOfDayCheckbox, NSView()])
        beforeRow.orientation = .horizontal
        beforeRow.spacing = 6
        beforeRow.alignment = .centerY
        stack.addArrangedSubview(beforeRow)

        stack.addArrangedSubview(caseSensitiveCheckbox)
        stack.addArrangedSubview(makeSeparator())

        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .systemRed
        messageLabel.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(messageLabel)

        let applyButton = NSButton(title: "应用筛选", target: self, action: #selector(applyTapped))
        applyButton.keyEquivalent = "\r"
        applyButton.bezelStyle = .rounded
        let clearButton = NSButton(title: "清空条件", target: self, action: #selector(clearTapped))
        clearButton.bezelStyle = .rounded
        let buttonRow = NSStackView(views: [NSView(), clearButton, applyButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        stack.addArrangedSubview(buttonRow)

        for field in [minSizeField, maxSizeField] {
            field.placeholderString = "如 10mb、>10mb、1mb-5mb"
            field.widthAnchor.constraint(equalToConstant: 200).isActive = true
        }
        for picker in [afterPicker, beforePicker] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = [.yearMonthDay, .hourMinute]
            picker.widthAnchor.constraint(equalToConstant: 170).isActive = true
        }
        afterCheckbox.toolTip = "从所选那天起修改的才算。"
        beforeCheckbox.toolTip = "只算这个时间之前修改的。"
        endOfDayCheckbox.toolTip = "截至日当天修改的也算入。"
        caseSensitiveCheckbox.toolTip = "英文字母严格区分大小写。"
        afterCheckbox.target = self
        afterCheckbox.action = #selector(togglePickers)
        beforeCheckbox.target = self
        beforeCheckbox.action = #selector(togglePickers)

        view = root
    }

    private func makeSeparator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 1),
        ])
        return box
    }

    private func makeRow(label: String, field: NSTextField) -> NSView {
        let text = NSTextField(labelWithString: label)
        text.alignment = .right
        text.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let row = NSStackView(views: [text, field])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        return row
    }

    // MARK: - 对外接口

    func present(values: AdvancedFilterValues, relativeTo view: NSView) {
        loadViewIfNeeded()
        current = values
        minSizeField.stringValue = values.minSizeText
        maxSizeField.stringValue = values.maxSizeText
        afterCheckbox.state = values.useModifiedAfter ? .on : .off
        afterPicker.dateValue = values.modifiedAfter
        beforeCheckbox.state = values.useModifiedBefore ? .on : .off
        beforePicker.dateValue = values.modifiedBefore
        endOfDayCheckbox.state = values.useModifiedBefore ? .on : .off
        caseSensitiveCheckbox.state = values.caseSensitive ? .on : .off
        messageLabel.stringValue = ""
        togglePickers()

        let newPopover = NSPopover()
        newPopover.behavior = .transient
        newPopover.contentViewController = self
        newPopover.show(relativeTo: .zero, of: view, preferredEdge: .minY)
        popover = newPopover
    }

    /// 读取当前输入；解析失败时返回 nil 并在面板内提示，不静默忽略非法输入。
    func currentValues() -> (values: AdvancedFilterValues, resolved: ResolvedFilters)? {
        let values = readValues()
        do {
            let resolved = try AdvancedFilterResolver.resolve(values)
            messageLabel.stringValue = ""
            messageLabel.toolTip = nil
            return (values, resolved)
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? "筛选条件有误，请检查大小或日期。"
            messageLabel.stringValue = text
            messageLabel.toolTip = text
            return nil
        }
    }

    private func readValues() -> AdvancedFilterValues {
        var values = current
        values.minSizeText = minSizeField.stringValue
        values.maxSizeText = maxSizeField.stringValue
        values.useModifiedAfter = afterCheckbox.state == .on
        values.modifiedAfter = startOfDay(afterPicker.dateValue)
        values.useModifiedBefore = beforeCheckbox.state == .on
        values.modifiedBefore = endOfDayCheckbox.state == .on
            ? self.endOfDay(beforePicker.dateValue)
            : beforePicker.dateValue
        values.caseSensitive = caseSensitiveCheckbox.state == .on
        return values
    }

    private func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    private func endOfDay(_ date: Date) -> Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
    }

    // MARK: - 动作

    @objc private func applyTapped() {
        guard let (values, _) = currentValues() else { return }
        current = values
        onApply?(values)
        dismissPopover()
    }

    @objc private func clearTapped() {
        let cleared = AdvancedFilterValues(
            minSizeText: "",
            maxSizeText: "",
            useModifiedAfter: false,
            modifiedAfter: current.modifiedAfter,
            useModifiedBefore: false,
            modifiedBefore: current.modifiedBefore,
            caseSensitive: false
        )
        current = cleared
        minSizeField.stringValue = ""
        maxSizeField.stringValue = ""
        afterCheckbox.state = .off
        beforeCheckbox.state = .off
        endOfDayCheckbox.state = .off
        caseSensitiveCheckbox.state = .off
        messageLabel.stringValue = ""
        togglePickers()
        onClear?(cleared)
    }

    @objc private func togglePickers() {
        afterPicker.isEnabled = afterCheckbox.state == .on
        beforePicker.isEnabled = beforeCheckbox.state == .on
        endOfDayCheckbox.isEnabled = beforeCheckbox.state == .on
    }

    private func dismissPopover() {
        popover?.performClose(nil)
        popover = nil
    }
}