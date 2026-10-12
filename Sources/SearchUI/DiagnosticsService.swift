import AppKit
import Foundation
import SearchDiagnostics

/// 应用侧的本地诊断接线。
///
/// 隐私边界（与 SearchDiagnostics 模块一致）：
/// - 记录只由固定枚举构成：`Module` / `Code` / `ErrorKind` / `Counter`，外加 errno、SQLite 返回码这类小整数。
/// - **不**记录 `localizedDescription`、文件路径、搜索词、查询文本、SQL 或任何自由字符串。
/// - 数据只留在本进程内存；唯一出口是用户手动选路径导出 JSON。**没有任何上传地址**。
/// - 默认关闭；开关状态存在 UserDefaults，撤回时 `setEnabled(false)` 会连缓冲区一起清空。
///
/// 并发约定：所有对 recorder 的操作都经过 ``enqueue(_:)`` **按调用顺序串行**执行。
/// 否则「快速开启 → 关闭 → 导出」这种连击会出现提交顺序错乱，
/// 可能导出到撤回之前的事件，或在撤回之后又写进一条。
@MainActor
public final class DiagnosticsService {
    public static let defaultsKey = "diagnosticsRecordingEnabled"
    /// 隐私说明：逐条对应 `DiagnosticEvent` 的真实字段与本服务的真实行为。
    public static let privacyNotice = """
    记录只暂存在本机内存。
    导出时才会写成文件。
    记下错误类型与发生次数。
    另含时间、应用版本、系统版本和芯片架构。
    不记录文件名、路径或搜索词。
    这些记录不会自动上传。
    清空只清内存里的临时记录。
    已导出的文件不会被清除。
    """
    /// 导出面板上的简短提醒。
    public static let exportNotice = "不含文件名、路径或搜索词。\n文件不会自动上传，是否分享由你决定。"

    private let recorder: DiagnosticsRecorder
    private let defaults: UserDefaults
    private var statusHandler: (@MainActor (StatusMessage) -> Void)?

    /// 串行队列的尾部任务。所有 recorder 操作都排在它后面，按调用顺序执行。
    private var tail: Task<Void, Never>?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 默认关闭：没有显式同意就不记录。
        let enabled = defaults.bool(forKey: Self.defaultsKey)
        self.recorder = DiagnosticsRecorder(configuration: DiagnosticsConfiguration(enabled: enabled))
    }

    /// 等待此前排队的所有操作完成（测试与退出前使用）。
    public func drain() async {
        await tail?.value
    }

    public func setStatusHandler(_ handler: @escaping @MainActor (StatusMessage) -> Void) {
        statusHandler = handler
    }

    /// 排入一个操作，按调用顺序串行执行。
    private func enqueue(_ body: @escaping @Sendable (DiagnosticsRecorder) async -> Void) {
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            await body(recorder)
        }
    }

    public var isEnabled: Bool {
        defaults.bool(forKey: Self.defaultsKey)
    }

    /// 用户已经同意（点了「继续开启」）之后才调用。
    /// 记录开关本身也不在「请求同意」这一步被打开。
    public func grantConsentAndEnable() async {
        defaults.set(true, forKey: Self.defaultsKey)
        enqueue { await $0.setEnabled(true) }
        await drain()
        statusHandler?(StatusMessage("已开启诊断。记录只在本机，不会自动上传。"))
    }

    /// 撤回同意：关闭记录并清空缓冲，同样串行执行。
    public func revokeConsent() async {
        defaults.set(false, forKey: Self.defaultsKey)
        enqueue { await $0.setEnabled(false) }
        await drain()
        // 只有真正清空之后才对外宣布。
        statusHandler?(StatusMessage("已停止诊断，临时记录已清空。已导出的文件不受影响。"))
    }

    public func setEnabled(_ enabled: Bool) async {
        if enabled {
            await grantConsentAndEnable()
        } else {
            await revokeConsent()
        }
    }

    public var eventCount: Int {
        get async {
            await tail?.value
            return await recorder.count
        }
    }

    /// 仅供测试：读取已缓冲事件的模块/代码投影（不暴露完整事件对象）。
    public func diagnosticsEventsForTesting() async -> [(module: Module, code: Code)] {
        await tail?.value
        return await recorder.events().map { ($0.module, $0.code) }
    }

    // MARK: - 记录

    /// 记一条固定代码事件。调用点不传任何用户内容。
    public func record(module: Module, code: Code, counter: Counter? = nil) {
        enqueue { recorder in
            try? await recorder.record(module: module, code: code, counter: counter)
        }
    }

    /// 把一个 catch 到的错误压成一个粗分类后再记录（绝不把错误本身传进去）。
    public func recordFailure(module: Module, kind: ErrorKind, counter: Counter? = nil) {
        record(module: module, code: .applicationError(kind), counter: counter)
    }

    /// 文件系统/系统调用类失败：只取 errno 这个小整数。
    public func recordErrno(_ error: Error, module: Module = .scanner, counter: Counter? = nil) {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            record(module: module, code: .scanSyscallFailure(errno: Int32(truncatingIfNeeded: nsError.code)), counter: counter)
        } else {
            recordFailure(module: module, kind: .systemCall, counter: counter)
        }
    }

    // MARK: - 导出 / 清除

    /// 用 NSSavePanel 让用户自己选保存位置。不做任何上传。
    public func presentExportPanel(from window: NSWindow?) {
        let panel = NSSavePanel()
        panel.title = "导出诊断"
        panel.message = Self.exportNotice
        panel.nameFieldStringValue = Self.defaultExportName()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            Task { await self.finishExport(to: url) }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    /// 直接导出到给定 URL（供测试与非面板路径）。
    public func export(to url: URL) async throws -> Int {
        let box = ExportBox()
        enqueue { recorder in
            do { box.result = .success(try await recorder.export(to: url)) }
            catch {
                box.result = .failure(error)
                // 导出失败本身也是一条本地诊断（面板与非面板路径都记）。
                try? await recorder.record(
                    module: .diagnostics,
                    code: .diagnosticsInternalFailure,
                    counter: .exportFailed
                )
            }
        }
        await drain()
        guard let result = box.result else {
            throw DiagnosticsError.exportFailed(reason: .unknown)
        }
        return try result.get()
    }

    /// 串行队列执行体回传结果的容器（同一 actor 轮次内读写）。
    private final class ExportBox: @unchecked Sendable {
        var result: Result<Int, Error>?
    }

    /// 面板选定路径后的导出与状态反馈。
    /// 失败时系统原文只进状态栏「详情」，诊断里只记封闭的事件代号（见 `export(to:)`）。
    func finishExport(to url: URL) async {
        do {
            let count = try await export(to: url)
            statusHandler?(StatusMessage(count == 0
                ? "没有可导出的诊断记录。"
                : "已导出 \(count) 条诊断记录到 \(url.lastPathComponent)。文件不会自动上传。"))
        } catch {
            statusHandler?(.failure("诊断导出失败。", error: error))
        }
    }

    public func clear() async {
        enqueue { await $0.clear() }
        await drain()
        statusHandler?(StatusMessage("已清空临时诊断记录。已导出的文件不受影响。"))
    }

    private static func defaultExportName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(AppBrand.displayName)诊断-\(formatter.string(from: Date())).json"
    }
}