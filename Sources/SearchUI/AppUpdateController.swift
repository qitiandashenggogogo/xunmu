import AppKit
import Foundation
import Sparkle

/// Sparkle 错误域与「用户取消」代码。
///
/// 取自 Sparkle 2.10.0 的 `SUErrors.h`：
/// - `SUSparkleErrorDomain`：Sparkle 使用的错误域常量。
/// - `SUInstallationCanceledError = 4007`（`NS_ENUM(OSStatus, SUError)` 的成员）。
/// 这里用裸值而不是 `SUError.something`，避免依赖 Swift 导入时的大小写前缀裁剪规则。
enum SparkleErrorCodes {
    static let domain = SUSparkleErrorDomain
    static let installationCanceled = 4007
}

/// 基于 Sparkle 2.10 的应用内更新入口。
///
/// 关键行为（都对应真实 SDK 语义，不是猜的）：
/// - **不覆盖用户偏好**：`SPUUpdater.automaticallyChecksForUpdates` 会持久化到宿主 bundle 的
///   user defaults，头文件明确写着「不要每次启动都赋值，否则会忽略用户的选择」。
///   所以构造时用 `startingUpdater: false`，之后只调用 `startUpdater()`，
///   仅在用户自己切换菜单时写这个属性。
/// - **保留首次许可机制**：默认不写 `SUEnableAutomaticChecks`，让 Sparkle 在第二次启动时
///   询问用户是否允许自动检查。`SUAllowsAutomaticUpdates` 是另一件事（是否允许自动下载），
///   两者在 `UpdateFeedConfiguration` 里分开。
/// - **缺配置不联网**：没有 SUFeedURL / SUPublicEDKey（或公钥不是 32 字节 Base64）时，
///   连 Sparkle 控制器都不构造，菜单禁用并给出中文原因。
/// - 公钥只从 Info.plist 的 `SUPublicEDKey` 读：`SPUUpdater` 上**没有** `setEdDSAPublicKey`，
///   `setFeedURL(_:)` 在 2.10 已废弃。
/// - 下载、校验、安装全部交给 Sparkle；本文件不实现任何下载或执行逻辑。
@MainActor
public final class AppUpdateController: NSObject {

    public struct MenuActions {
        public var checkForUpdates: Selector
        public var toggleAutomaticChecks: Selector
        public init(checkForUpdates: Selector, toggleAutomaticChecks: Selector) {
            self.checkForUpdates = checkForUpdates
            self.toggleAutomaticChecks = toggleAutomaticChecks
        }
    }

    public let configuration: UpdateFeedConfiguration?
    public let issue: UpdateConfigurationIssue?
    public private(set) var disabledReason: String?
    /// 未配置时给开发者看的配置键说明，只在本机「详情」里展示。
    public private(set) var disabledDetail: String?
    public private(set) var isStarted = false
    public private(set) var startError: String?

    /// 安装前回调：保存会话（查询、选区、滚动）。索引与缓存不删除。
    public var onBeforeInstall: (@MainActor () -> Void)?
    /// 白话短提示 + 可选的系统详细信息（只在本机展示，不进诊断记录）。
    public var statusHandler: (@MainActor (StatusMessage) -> Void)?

    private var controller: SPUStandardUpdaterController?
    /// 容器只是壳，真正的更新器在 `.updater` 上。
    private var updater: SPUUpdater? { controller?.updater }

    public init(bundle: Bundle = .main) {
        let info = bundle.infoDictionary ?? [:]
        let (configuration, issue) = UpdateFeedReader.read(infoDictionary: info)
        self.configuration = configuration
        self.issue = issue
        super.init()

        guard let configuration else {
            let reason = issue ?? .missingFeedURL
            self.disabledReason = reason.message
            self.disabledDetail = reason.technicalDetail
            return
        }
        // startingUpdater: false —— 我们在 start() 里显式启动，避免在构造期就触发任何检查。
        self.controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        // 刻意不设置 automaticallyChecksForUpdates：那会覆盖用户已保存的偏好。
        // 这里只保留配置值用于展示。
        self.configurationDefaultAutomaticChecks = configuration.enablesAutomaticChecksWithoutPrompt
    }

    /// 仅用于展示/说明，不代表当前用户偏好。
    public private(set) var configurationDefaultAutomaticChecks: Bool = false

    /// 用户当前偏好（由 Sparkle 自己持久化）。
    public var automaticallyChecksForUpdates: Bool {
        updater?.automaticallyChecksForUpdates ?? false
    }

    /// 菜单是否可用：Sparkle 说现在能不能检查，就照它说的。
    public var canCheckForUpdates: Bool {
        guard configuration != nil, let updater else { return false }
        return updater.canCheckForUpdates
    }

    /// 应用启动后调用。未配置时不联网、不构造任何东西。
    public func start() {
        guard configuration != nil else {
            // 没配置就没有联网检查：只说「更新未启用」，不能说成「暂无更新」。
            statusHandler?(StatusMessage("更新未启用", detail: disabledExplanation))
            return
        }
        guard let updater else {
            startError = "更新组件不可用。"
            statusHandler?(StatusMessage(startError ?? ""))
            return
        }
        do {
            // Swift 侧 `startUpdater:` 已导入为 `start()`。
            try updater.start()
            isStarted = true
        } catch {
            isStarted = false
            startError = "无法启动更新检查。"
            statusHandler?(.failure(startError ?? "", error: error))
            return
        }
        if configurationDefaultAutomaticChecks {
            // Info.plist 显式要求跳过许可询问时，才在启动后做一次后台检查。
            updater.checkForUpdatesInBackground()
        }
        statusHandler?(StatusMessage(configuration?.statusText ?? ""))
    }

    /// 菜单「检查更新…」。`canCheckForUpdates` 为假时给出明确提示。
    public func checkForUpdates() {
        guard configuration != nil, let updater else {
            presentDisabledAlert()
            return
        }
        guard updater.canCheckForUpdates else {
            statusHandler?(StatusMessage("现在不能检查更新，请稍后再试。"))
            return
        }
        updater.checkForUpdates()
    }

    /// 仅在用户主动切换时调用；Sparkle 会把这个值持久化到宿主 bundle 的 user defaults。
    public func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updater?.automaticallyChecksForUpdates = enabled
    }

    public func makeMenuItems(target: AnyObject, actions: MenuActions) -> [NSMenuItem] {
        let check = NSMenuItem(title: "检查更新…", action: actions.checkForUpdates, keyEquivalent: "")
        check.target = target
        check.isEnabled = canCheckForUpdates
        check.toolTip = "查找是否有可用的新版本。"

        let toggle = NSMenuItem(title: "自动查更新", action: actions.toggleAutomaticChecks, keyEquivalent: "")
        toggle.target = target
        toggle.isEnabled = configuration != nil
        toggle.state = automaticallyChecksForUpdates ? .on : .off
        toggle.toolTip = "定期查找新版本并提醒。"
        return [check, toggle]
    }

    /// 白话原因 + 配置键说明，两段分开。
    private var disabledExplanation: String {
        let reason = disabledReason ?? UpdateConfigurationIssue.missingFeedURL.message
        guard let disabledDetail else { return reason }
        return "\(reason)\n\n\(disabledDetail)"
    }

    private func presentDisabledAlert() {
        let alert = NSAlert()
        alert.messageText = "更新未启用"
        alert.informativeText = disabledExplanation
        alert.addButton(withTitle: "好")
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - SPUUpdaterDelegate

// Sparkle 的委托回调不是 main-actor 隔离的，而本类是 @MainActor。
// 用 @preconcurrency 桥接，并把每个回调体标成 nonisolated，再显式回到主线程。
extension AppUpdateController: @preconcurrency SPUUpdaterDelegate {

    /// 真正的安装回调是 `updater(_:willInstallUpdate:)`。
    /// （之前写的 `updaterWillInstallUpdate(_:metadata:)` 不是协议回调，永远不会触发，
    ///   等于安装前根本没保存会话。）
    nonisolated public func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        // Sparkle 在主线程回调安装流程。
        MainActor.assumeIsolated {
            self.onBeforeInstall?()
        }
    }

    nonisolated public func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        Task { @MainActor [weak self] in
            // Sparkle 在「没有可装的新版本」时也走这里（含已是最新等原因），不一律说成失败；
            // 具体原因由系统原文给出，放在「详情」里。
            self?.statusHandler?(.failure("未找到可用的新版本。", error: error))
        }
    }

    nonisolated public func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let nsError = error as NSError
        let isSparkleCancel = nsError.domain == SparkleErrorCodes.domain
            && nsError.code == SparkleErrorCodes.installationCanceled
        let isSystemCancel = nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
        guard !isSparkleCancel, !isSystemCancel else { return }
        Task { @MainActor [weak self] in
            self?.statusHandler?(.failure("更新未完成。", error: nsError))
        }
    }

    nonisolated public func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor [weak self] in
            self?.statusHandler?(StatusMessage("发现新版本 \(item.displayVersionString)，准备下载。"))
        }
    }
}
