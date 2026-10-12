import AppKit
import SearchUI

@main
@MainActor
enum MacEverythingApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var controller: AppController?
    private var diagnosticsItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于\(AppBrand.displayName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出\(AppBrand.displayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)

        applicationMainMenu(menu)

        do {
            let appController = try AppController()
            controller = appController
            attachUpdateAndDiagnosticsMenu(to: appMenu, controller: appController)
            appController.start()
            appController.startUpdates()
            NSApplication.shared.activate(ignoringOtherApps: true)
        } catch {
            let alert = NSAlert()
            // 先给白话短提示，再原样附上系统给出的详细信息（只在本机显示）。
            alert.messageText = "打不开记录"
            alert.informativeText = "请检查存储目录权限与空间。\n\n详细信息：\(error.localizedDescription)"
            alert.runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    /// 更新菜单由 AppUpdateController 提供状态；未配置更新源时菜单项保持禁用，
    /// 点击时给出中文原因，而不是静默失败。
    private func attachUpdateAndDiagnosticsMenu(to appMenu: NSMenu, controller: AppController) {
        appMenu.addItem(.separator())
        for item in controller.makeUpdateMenuItems(target: controller) {
            appMenu.addItem(item)
        }

        appMenu.addItem(.separator())
        // 本地诊断：默认关闭，只在用户明确同意后才记录。
        let toggle = NSMenuItem(title: "记录诊断", action: #selector(AppController.toggleDiagnosticsRecording(_:)), keyEquivalent: "")
        toggle.toolTip = "只在本机内存暂存排错记录。"
        toggle.target = controller
        toggle.state = controller.diagnostics.isEnabled ? .on : .off
        appMenu.addItem(toggle)

        let export = NSMenuItem(title: "导出诊断…", action: #selector(AppController.exportDiagnostics(_:)), keyEquivalent: "")
        export.toolTip = "把临时记录保存成文件。"
        export.target = controller
        appMenu.addItem(export)

        let clear = NSMenuItem(title: "清空诊断", action: #selector(AppController.clearDiagnostics(_:)), keyEquivalent: "")
        clear.toolTip = "只清内存里的临时记录。"
        clear.target = controller
        appMenu.addItem(clear)

        // 诊断报告模块接入点：真实 API 到位后由主控调用 setDiagnosticsHandler 启用。
        let item = NSMenuItem(title: "生成报告…", action: #selector(runDiagnostics(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = false
        item.toolTip = "此功能尚未启用。"
        appMenu.addItem(item)
        diagnosticsItem = item
    }

    @objc private func runDiagnostics(_ sender: Any?) {
        controller?.runDiagnostics()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(runDiagnostics(_:)) {
            return controller?.canGenerateDiagnosticsReport == true
        }
        return true
    }

    private func applicationMainMenu(_ menu: NSMenu) { NSApplication.shared.mainMenu = menu }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { controller?.stop() }
}
