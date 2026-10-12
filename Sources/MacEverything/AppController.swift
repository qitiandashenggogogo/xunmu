import AppKit
import Darwin
import SearchCore
import SearchDiagnostics
import SearchIndex
import SearchScanner
import SearchUI

private struct RegisteredRoot: Codable {
    var volume: VolumeRecord
    var relativeToVolume: String?
}

private struct ScanJob {
    var volumeID: String
    var paths: Set<String>
    var recursive: Bool
    var eventID: UInt64?
}

@MainActor
final class AppController: NSObject, SearchWindowDelegate, NSMenuItemValidation {
    private let window = SearchWindowController()
    private let dataURL: URL
    private let smoke: Bool
    private var roots: [RegisteredRoot] = []
    private var stores: [String: CatalogStore] = [:]
    private var monitors: [String: FileEventMonitor] = [:]
    private var scans: [String: Task<Void, Never>] = [:]
    private var pendingEvents: [String: [FileChange]] = [:]
    private var devices: [String: dev_t] = [:]
    private var pendingDirectories: [String: Set<String>] = [:]
    private var scanIssues: [String: [ScanIssue]] = [:]
    private var snapshot = CatalogSnapshot(generation: 0, entries: [], volumes: [])
    private var searchTask: Task<SearchResult, Never>?
    private var searchTicket: UInt64 = 0
    private var publishedCount = 0
    private var publishDate = Date.distantPast
    private var workspaceTokens: [NSObjectProtocol] = []
    private var isPaused = false
    private var shuttingDown = false
    private var lastResult: SearchResult?
    private var engine: SearchEngine?
    private var engineGeneration: UInt64 = 0
    // Conservative MVP budget: serialize metadata walks across roots. USB bridges
    // may hide that multiple mounted volumes share one physical mechanical disk.
    private var queuedScans: [ScanJob] = []
    private var preparingScanID: String?
    private var smokeStarted = false
    // Publish coalescing: scanning can trigger many overlapping requests.
    // Only one read+rebuild runs at a time; extra requests collapse into one.
    // 发布去重与重试全部由 PublishScheduler 负责（合并重入、有上限立即重试、
    // 可取消的延迟重试），这里不再重复维护 inFlight 标志。
    /// 发布调度器：拥有幂等/重试状态机（幂等判定与重试预算都在它身上，
    /// 延迟轮开始前会重置预算）。
    private lazy var scheduler: PublishScheduler = {
        let scheduler = PublishScheduler()
        scheduler.statusHandler = { [weak self] text in self?.window.setStatus(text) }
        return scheduler
    }()
    private var diagnosticsHandler: (@MainActor () -> Void)?
    let updater = AppUpdateController()
    let diagnostics = DiagnosticsService()

    init(arguments: [String] = CommandLine.arguments) throws {
        let args = arguments
        smoke = args.contains("--smoke")
        if let i = args.firstIndex(of: "--data-dir"), i + 1 < args.count {
            dataURL = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        } else if args.contains("--demo") || smoke {
            dataURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/demo-session", isDirectory: true)
        } else {
            dataURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacEverything", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
        super.init()
        window.searchDelegate = self
        window.window?.title = AppBrand.displayName
        updater.onBeforeInstall = { [weak self] in self?.saveSessionForUpdate() }
        updater.statusHandler = { [weak self] message in
            guard !message.text.isEmpty else { return }
            self?.window.setStatus(message)
        }
        diagnostics.setStatusHandler { [weak self] message in
            guard !message.text.isEmpty else { return }
            self?.window.setStatus(message)
        }
    }

    /// 安装更新前保存会话：只写查询/选区/滚动与索引范围，不删除索引与缓存。
    func saveSessionForUpdate() {
        saveNavigation()
        persistRoots()
        window.setStatus("已保存搜索状态。记录与缓存不会删除。")
    }

    /// 诊断模块接入点：真实 API 到位后由主控实现（目前不假设接口）。
    func setDiagnosticsHandler(_ handler: (@MainActor () -> Void)?) {
        diagnosticsHandler = handler
        window.refreshActionsAvailability()
    }

    func runDiagnostics() {
        diagnosticsHandler?()
    }

    var canGenerateDiagnosticsReport: Bool { diagnosticsHandler != nil }

    // MARK: - 本地诊断菜单

    @objc func toggleDiagnosticsRecording(_ sender: Any?) {
        if diagnostics.isEnabled {
            Task { await setDiagnosticsEnabled(false) }
            return
        }
        // 先征求同意；用户点了「继续开启」才真正打开记录。
        presentDiagnosticsPrivacyNotice()
    }

    @objc func exportDiagnostics(_ sender: Any?) {
        diagnostics.presentExportPanel(from: window.window)
    }

    @objc func clearDiagnostics(_ sender: Any?) {
        Task { await diagnostics.clear() }
    }

    /// 开启记录前把边界说清楚：本地、非崩溃、不上传。
    /// 用户点「继续开启」之前不会打开任何记录。
    private func presentDiagnosticsPrivacyNotice() {
        let alert = NSAlert()
        alert.messageText = "开启诊断"
        alert.informativeText = """
        只用于排查使用中的问题。

        \(DiagnosticsService.privacyNotice)

        这不是崩溃报告，崩溃时不会生成记录。
        """
        alert.addButton(withTitle: "确认开启")
        alert.addButton(withTitle: "暂不开启")
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return } // 取消：保持关闭
            Task { @MainActor in await self?.setDiagnosticsEnabled(true) }
        }
        if let window = window.window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    private func setDiagnosticsEnabled(_ enabled: Bool) async {
        await diagnostics.setEnabled(enabled)
        window.refreshActionsAvailability()
    }

    func start() {
        window.showWindow(nil)
        window.setStatus("请先添加要搜索的文件夹或磁盘。建立记录后，断开也能搜。")
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refreshMountedRoots() }
            })
        }
        Task { await load() }
    }

    func stop() {
        shuttingDown = true
        scheduler.stop()
        saveNavigation()
        searchTask?.cancel()
        for scan in scans.values { scan.cancel() }
        for monitor in monitors.values { monitor.stop() }
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }

    func startUpdates() {
        updater.start()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updater.checkForUpdates()
    }

    @objc func toggleAutomaticUpdates(_ sender: Any?) {
        // 只有用户主动切换时才写这个属性（Sparkle 会持久化到宿主 bundle 的 user defaults）。
        let next = !updater.automaticallyChecksForUpdates
        updater.setAutomaticallyChecksForUpdates(next)
        if let item = sender as? NSMenuItem { item.state = next ? .on : .off }
    }

    /// 菜单校验：禁用态的「检查更新…」不能被 AppKit 自动验证重新启用，
    /// 否则会在用户不该联网的时候触发一次检查。
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates(_:)) {
            return updater.canCheckForUpdates
        }
        if menuItem.action == #selector(toggleAutomaticUpdates(_:)) {
            return updater.configuration != nil
        }
        return true
    }

    func makeUpdateMenuItems(target: AnyObject) -> [NSMenuItem] {
        updater.makeMenuItems(target: target, actions: .init(checkForUpdates: #selector(checkForUpdates(_:)), toggleAutomaticChecks: #selector(toggleAutomaticUpdates(_:))))
    }

    private func load() async {
        do {
            let url = dataURL.appendingPathComponent("roots.json")
            if let data = try? Data(contentsOf: url) { roots = try JSONDecoder().decode([RegisteredRoot].self, from: data) }
            for root in roots {
                let store = try CatalogStore(databaseURL: databaseURL(root.volume.id))
                stores[root.volume.id] = store
                try await store.registerVolume(root.volume)
            }
            await refreshMountedRoots(startScans: false)
            await publish()
            if let data = try? Data(contentsOf: dataURL.appendingPathComponent("navigation.json")),
               let state = try? JSONDecoder().decode(NavigationState.self, from: data) { window.restoreState(state) }
            runSearch(window.currentQuery)
            let args = CommandLine.arguments
            if args.contains("--demo") || smoke {
                let demoURL = try createDemoFiles()
                await addRoot(demoURL)
            } else if let i = args.firstIndex(of: "--index-root"), i + 1 < args.count {
                await addRoot(URL(fileURLWithPath: args[i + 1], isDirectory: true))
            } else {
                for root in roots where root.volume.isOnline { await resume(root.volume) }
            }
        } catch {
            window.setStatus(.failure("恢复记录失败。已有文件不受影响。", error: error))
            diagnostics.recordFailure(module: .app, kind: .other, counter: .scanError)
        }
    }

    private func databaseURL(_ id: String) -> URL { dataURL.appendingPathComponent("catalog-\(id).sqlite") }
    private func persistRoots() {
        do { try JSONEncoder().encode(roots).write(to: dataURL.appendingPathComponent("roots.json"), options: .atomic) }
        catch {
            window.setStatus(.failure("无法保存搜索位置。", error: error))
            diagnostics.recordErrno(error, module: .app)
        }
    }
    private func saveNavigation() {
        do { try JSONEncoder().encode(window.captureState()).write(to: dataURL.appendingPathComponent("navigation.json"), options: .atomic) }
        catch {
            window.setStatus(.failure("无法保存搜索状态。", error: error))
            diagnostics.recordErrno(error, module: .app)
        }
    }

    func searchWindow(_ window: SearchWindowController, didChange query: SearchQuery) { runSearch(query); saveNavigation() }
    func searchWindowDidRestoreNavigation(_ window: SearchWindowController) {
        searchTask?.cancel()
        searchTicket &+= 1
        lastResult = SearchResult(generation: window.resultRows.generation, keys: window.resultRows.resultKeys)
        saveNavigation()
        if window.resultRows.generation != snapshot.generation { runSearch(window.currentQuery) }
    }
    func searchWindowDidRequestAddRoot(_ window: SearchWindowController) {
        let panel = NSOpenPanel()
        panel.title = "选择位置"
        panel.message = "可选文件夹或外接硬盘。建立记录后，断开也能搜。"
        panel.prompt = "加入搜索"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window.window!) { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor [weak self] in for url in urls { await self?.addRoot(url) } }
        }
    }
    func searchWindowDidRequestRescan(_ window: SearchWindowController) {
        isPaused = false
        window.setPausedState(false)
        Task { for root in roots where root.volume.isOnline { await beginScan(root.volume, paths: [""], recursive: true) } }
    }
    func searchWindowDidRequestPause(_ window: SearchWindowController) {
        isPaused.toggle()
        window.setPausedState(isPaused)
        if isPaused {
            for task in scans.values { task.cancel() }
            window.setStatus("检查已暂停。已有记录仍可搜索，点「继续」恢复。")
        } else {
            Task { for root in roots where root.volume.isOnline { await resume(root.volume) } }
        }
    }

    private func addRoot(_ url: URL) async {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        if let i = roots.firstIndex(where: { $0.volume.rootPath == canonical.path }) {
            let refreshed = VolumeDiscovery.describe(rootURL: canonical, id: roots[i].volume.id)
            roots[i].volume = refreshed
            devices[refreshed.id] = device(at: refreshed.rootPath)
            try? await stores[refreshed.id]?.registerVolume(refreshed)
            persistRoots()
            await resume(refreshed)
            return
        }
        let volume = VolumeDiscovery.describe(rootURL: canonical)
        do {
            let store = try CatalogStore(databaseURL: databaseURL(volume.id))
            stores[volume.id] = store
            try await store.registerVolume(volume)
            let base = try? canonical.resourceValues(forKeys: [.volumeURLKey]).volume
            let relative = base.flatMap { root -> String? in
                let prefix = root.path == "/" ? "/" : root.path + "/"
                if canonical.path == root.path { return "" }
                guard canonical.path.hasPrefix(prefix) else { return nil }
                return String(canonical.path.dropFirst(prefix.count))
            }
            roots.append(RegisteredRoot(volume: volume, relativeToVolume: relative))
            devices[volume.id] = device(at: volume.rootPath)
            persistRoots()
            await publish()
            await beginScan(volume, paths: [""], recursive: true)
        } catch {
            window.setStatus(.failure("无法添加该位置。", error: error))
            diagnostics.recordFailure(module: .index, kind: .database, counter: .indexApply)
        }
    }

    private func device(at path: String) -> dev_t? {
        var info = stat()
        return path.withCString { lstat($0, &info) } == 0 ? info.st_dev : nil
    }
    private func identityIsValid(_ volume: VolumeRecord) -> Bool {
        guard let current = device(at: volume.rootPath), current == devices[volume.id] else { return false }
        if let uuid = volume.volumeUUID {
            return StableVolumeIdentity.identifier(for: URL(fileURLWithPath: volume.rootPath)) == uuid
        }
        return volume.isOnline
    }

    private func refreshMountedRoots(startScans: Bool = true) async {
        let mounted = VolumeDiscovery.mountedVolumes()
        for i in roots.indices {
            let old = roots[i].volume
            var updated = old
            if let uuid = old.volumeUUID, let mount = mounted.first(where: { $0.volumeUUID == uuid }), let relative = roots[i].relativeToVolume {
                updated.rootPath = URL(fileURLWithPath: mount.rootPath, isDirectory: true).appendingPathComponent(relative).path
                updated.isOnline = FileManager.default.fileExists(atPath: updated.rootPath)
            } else if let uuid = old.volumeUUID {
                updated.isOnline = StableVolumeIdentity.identifier(for: URL(fileURLWithPath: old.rootPath)) == uuid
            } else {
                // UUID unavailable: only trust the already-attached device during this process.
                updated.isOnline = devices[old.id] != nil && devices[old.id] == device(at: old.rootPath)
            }
            roots[i].volume = updated
            if updated.isOnline { devices[updated.id] = device(at: updated.rootPath) }
            else { scans[updated.id]?.cancel(); monitors.removeValue(forKey: updated.id)?.stop(); devices.removeValue(forKey: updated.id) }
            if let store = stores[updated.id] { try? await store.registerVolume(updated) }
            if startScans && !old.isOnline && updated.isOnline && !isPaused { await resume(updated) }
        }
        persistRoots()
        await publish()
    }

    private func startMonitor(_ volume: VolumeRecord) async throws {
        if monitors[volume.id] != nil { return }
        let checkpoint = try await stores[volume.id]?.checkpoint(volumeID: volume.id)
        let monitor = try FileEventMonitor(rootURL: URL(fileURLWithPath: volume.rootPath), sinceEventID: checkpoint?.eventID ?? 0, checkpointJournal: checkpoint?.journalUUID) { [weak self] changes in
            Task { @MainActor [weak self] in self?.received(changes, volumeID: volume.id) }
        }
        // A changed journal cannot safely replay the saved cursor.
        if let checkpoint, checkpoint.journalUUID != monitor.journalUUID {
            try await stores[volume.id]?.setPendingPaths(volumeID: volume.id, paths: [""])
        }
        try monitor.start()
        monitors[volume.id] = monitor
    }

    private func resume(_ volume: VolumeRecord) async {
        guard volume.isOnline, !isPaused, scans[volume.id] == nil else { return }
        do {
            try await startMonitor(volume)
            let pending = try await stores[volume.id]?.pendingPaths(volumeID: volume.id) ?? []
            let count = try await stores[volume.id]?.entryCount(volumeID: volume.id) ?? 0
            if volume.requiresFullVerification || monitors[volume.id]?.journalUUID == nil || count == 0 {
                await beginScan(volume, paths: [""], recursive: true)
            } else if !pending.isEmpty { await beginScan(volume, paths: pending, recursive: true) }
            else { window.setStatus("记录已就绪，正在同步最新变动。") }
        } catch {
            window.setStatus(.failure("文件变动监控不可用，已保留现有记录。", error: error))
            diagnostics.recordFailure(module: .scanner, kind: .systemCall, counter: .scanError)
        }
    }

    private func received(_ changes: [FileChange], volumeID: String) {
        guard !shuttingDown else { return }
        guard let root = roots.first(where: { $0.volume.id == volumeID }) else { return }
        let filtered = changes.filter { change in
            let path = URL(fileURLWithPath: root.volume.rootPath).appendingPathComponent(change.relativePath).standardizedFileURL.path
            return path != dataURL.path && !path.hasPrefix(dataURL.path + "/")
        }
        guard !filtered.isEmpty else { return }
        pendingEvents[volumeID, default: []].append(contentsOf: filtered)
        guard scans[volumeID] == nil, !isPaused, let volume = roots.first(where: { $0.volume.id == volumeID })?.volume, volume.isOnline else { return }
        Task { await drainEvents(volume) }
    }
    private func drainEvents(_ volume: VolumeRecord) async {
        guard scans[volume.id] == nil, !isPaused else { return }
        let changes = pendingEvents.removeValue(forKey: volume.id) ?? []
        guard !changes.isEmpty else { return }
        let eventID = changes.map(\.eventID).max() ?? 0
        if changes.contains(where: \.requiresFullScan) {
            await beginScan(volume, paths: [""], recursive: true, eventID: eventID)
            return
        }
        var directories = Set<String>()
        var recursive = false
        for change in changes {
            let url = URL(fileURLWithPath: volume.rootPath).appendingPathComponent(change.relativePath)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                directories.insert(change.relativePath)
            } else {
                let parent = (change.relativePath as NSString).deletingLastPathComponent
                directories.insert(parent == "." ? "" : parent)
            }
            recursive = recursive || change.requiresRecursiveScan
        }
        await beginScan(volume, paths: directories.sorted(), recursive: recursive, eventID: eventID)
    }

    private func beginScan(_ volume: VolumeRecord, paths: [String], recursive: Bool, eventID: UInt64? = nil) async {
        guard !isPaused, !shuttingDown, volume.isOnline, scans[volume.id] == nil, let store = stores[volume.id] else { return }
        if preparingScanID != nil || !scans.isEmpty {
            if let i = queuedScans.firstIndex(where: { $0.volumeID == volume.id }) {
                queuedScans[i].paths.formUnion(paths)
                queuedScans[i].recursive = queuedScans[i].recursive || recursive
                if let eventID { queuedScans[i].eventID = max(queuedScans[i].eventID ?? 0, eventID) }
            } else {
                queuedScans.append(ScanJob(volumeID: volume.id, paths: Set(paths), recursive: recursive, eventID: eventID))
            }
            do {
                let old = try await store.pendingPaths(volumeID: volume.id)
                try await store.setPendingPaths(volumeID: volume.id, paths: Array(Set(old).union(paths)))
            } catch { window.setStatus(.failure("无法保存检查进度。", error: error)) }
            return
        }
        preparingScanID = volume.id
        defer { preparingScanID = nil }
        do {
            try LocalIndexCapacity.ensureAvailable(at: dataURL)
            if devices[volume.id] == nil { devices[volume.id] = device(at: volume.rootPath) }
            try await startMonitor(volume) // monitor before first directory enumeration
            pendingDirectories[volume.id] = Set(paths)
            scanIssues[volume.id] = []
            try await store.setPendingPaths(volumeID: volume.id, paths: paths)
        } catch let error as LocalIndexCapacity.CapacityError {
            isPaused = true
            window.setPausedState(true)
            window.setStatus(.failure("本机存储空间检查未通过，已暂停检查。", error: error))
            diagnostics.recordFailure(module: .index, kind: .other, counter: .indexCommit)
            return
        } catch {
            window.setStatus(.failure("无法开始检查。", error: error))
            diagnostics.recordFailure(module: .scanner, kind: .enumeration, counter: .scanError)
            return
        }
        window.setScanning(true)
        window.setStatus("正在检查 \(volume.name)。已有记录仍可搜索。")
        let appliedBoundary = eventID ?? monitors[volume.id]?.currentEventID ?? 0
        scans[volume.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let cachePrefix = self.dataURL.path + "/"
                let exclusions = volume.rootPath == self.dataURL.path || volume.rootPath.hasPrefix(cachePrefix)
                    ? self.stores.keys.flatMap { id in [self.databaseURL(id).path, self.databaseURL(id).path + "-wal", self.databaseURL(id).path + "-shm"] } + [self.dataURL.appendingPathComponent("roots.json").path, self.dataURL.appendingPathComponent("navigation.json").path, self.dataURL.appendingPathComponent("smoke.png").path]
                    : [self.dataURL.path]
                try await DirectoryScanner(excludedPaths: exclusions).scan(volume: volume, startingAt: paths, recursive: recursive) { [weak self] batch in
                    guard let self else { throw CancellationError() }
                    try await self.checkIndexCapacity()
                    try await self.apply(batch, volume: volume, recursive: recursive)
                }
                let remaining = Array(self.pendingDirectories[volume.id] ?? [])
                try await store.commitCheckpoint(SyncCheckpoint(volumeID: volume.id, eventID: appliedBoundary, journalUUID: self.monitors[volume.id]?.journalUUID), pendingPaths: remaining)
                if recursive && paths.contains("") && remaining.isEmpty, let i = self.roots.firstIndex(where: { $0.volume.id == volume.id }) {
                    self.roots[i].volume.lastVerifiedAt = Date()
                    try await store.registerVolume(self.roots[i].volume)
                    self.persistRoots()
                }
                let issueCount = self.scanIssues[volume.id]?.count ?? 0
                self.window.setStatus(issueCount == 0 ? "检查完成。搜索使用本机记录。" : "部分位置未读取（\(issueCount) 处）。已保留旧记录，排查后可重新检查。")
            } catch let error as LocalIndexCapacity.CapacityError {
                self.isPaused = true
                self.window.setPausedState(true)
                self.window.setStatus(.failure("本机存储空间检查未通过，已暂停检查。", error: error))
            } catch is CancellationError {
                self.window.setStatus("检查已暂停，进度已保存。已有记录仍可搜索。")
                self.diagnostics.record(module: .scanner, code: .cancelled, counter: .searchCancelled)
            } catch {
                self.window.setStatus(.failure("检查已中断，已保留之前的记录。", error: error))
                self.diagnostics.record(module: .scanner, code: .scanPartialFailure, counter: .scanError)
                self.diagnostics.recordErrno(error, module: .scanner, counter: .scanError)
            }
            self.scans.removeValue(forKey: volume.id)
            self.window.setScanning(!self.scans.isEmpty || !self.queuedScans.isEmpty)
            await self.publish()
            if !recursive && (self.scanIssues[volume.id]?.isEmpty ?? true) && !(self.pendingDirectories[volume.id]?.isEmpty ?? true) { await self.resume(volume) }
            if !self.isPaused { await self.drainEvents(volume) }
            await self.startNextScan()
            if self.smoke && self.scans.isEmpty && self.queuedScans.isEmpty && !self.smokeStarted { await self.runSmoke() }
        }
    }

    private func checkIndexCapacity() throws {
        try LocalIndexCapacity.ensureAvailable(at: dataURL)
    }

    private func startNextScan() async {
        guard scans.isEmpty, preparingScanID == nil, !isPaused, !shuttingDown else { return }
        while !queuedScans.isEmpty {
            let job = queuedScans.removeFirst()
            guard let volume = roots.first(where: { $0.volume.id == job.volumeID })?.volume, volume.isOnline else { continue }
            let paths = job.paths.contains("") ? [""] : job.paths.sorted()
            await beginScan(volume, paths: paths, recursive: job.recursive, eventID: job.eventID)
            return
        }
        window.setScanning(false)
    }

    private func apply(_ batch: DirectoryBatch, volume: VolumeRecord, recursive: Bool) async throws {
        try Task.checkCancellation()
        guard identityIsValid(volume), let store = stores[volume.id] else { throw CancellationError() }
        let known: Set<String> = recursive ? [] : Set(snapshot.entries.lazy.filter { $0.key.volumeID == volume.id && $0.isDirectory }.map(\.relativePath))
        _ = try await store.apply(batch)
        var pending = pendingDirectories[volume.id] ?? []
        if batch.isComplete { pending.remove(batch.directoryRelativePath) }
        for entry in batch.entries where entry.isDirectory && !entry.isSymbolicLink && (recursive || !known.contains(entry.relativePath)) { pending.insert(entry.relativePath) }
        pendingDirectories[volume.id] = pending
        try await store.setPendingPaths(volumeID: volume.id, paths: Array(pending))
        if let issue = batch.issue { scanIssues[volume.id, default: []].append(issue) }
        publishedCount += batch.entries.count
        if Date().timeIntervalSince(publishDate) > 0.8 {
            publishDate = Date()
            window.setStatus("正在检查 \(volume.name) · 本次已整理 \(publishedCount) 项。已有部分可先搜索。")
            await publish()
        }
    }

    private func publish() async {
        await scheduler.trigger { [weak self] in
            guard let self else { return .keptPreviousSnapshot }
            return await self.publishOnce()
        }
    }

    /// 采样当前版本向量：每个索引库的持久代际 + 卷状态。
    /// 缺少 store 记为失败 —— 不能当作「这个卷没有变化」。
    private func sampleVersions() async -> (vector: PublishVersionVector, readFailed: Bool) {
        var generations: [String: UInt64] = [:]
        var failed = false
        for root in roots {
            guard let store = stores[root.volume.id] else {
                failed = true
                continue
            }
            do { generations[root.volume.id] = try await store.generation() }
            catch {
                failed = true
                diagnostics.recordFailure(module: .index, kind: .database, counter: .indexApply)
            }
        }
        return (PublishVersionVector(generations: generations, volumes: roots.map(\.volume)), failed)
    }

    private func publishOnce() async -> PublishPassOutcome {
        // 退出后不再做任何发布工作。
        guard !shuttingDown else { return .keptPreviousSnapshot }
        // 1) 读全库之前先采样；没变就不必读（真正的幂等）。
        let before = await sampleVersions()
        if before.readFailed {
            window.setStatus("读取记录失败，已保留上次结果。")
            return scheduler.handleSamplingFailure()
        }
        if scheduler.isUnchanged(sampled: before.vector) {
            return .skippedUnchanged
        }

        // 2) 读全库。任意一卷失败（包括缺少 store）都不发布部分快照。
        // 用无序读取：SearchEngine 自己会给出稳定全序，这里不需要 ORDER BY。
        var entries: [IndexedEntry] = []
        var readFailed = false
        for root in roots {
            if let store = stores[root.volume.id] {
                do { entries.append(contentsOf: try await store.entriesUnordered(volumeID: root.volume.id)) }
                catch {
                    readFailed = true
                    diagnostics.recordFailure(module: .index, kind: .database, counter: .indexApply)
                }
            } else {
                readFailed = true
            }
        }

        // 3) 读完之后再采一次：扫描可能正在推进代际。
        let after = await sampleVersions()
        if shuttingDown { return .keptPreviousSnapshot }

        switch scheduler.decide(
            readFailedBefore: before.readFailed,
            before: before.vector,
            readFailedAfter: after.readFailed || readFailed,
            after: after.vector
        ) {
        case .keptPreviousSnapshot:
            window.setStatus("读取记录失败，已保留上次完整结果。")
            return .keptPreviousSnapshot
        case .retryNeeded:
            // 读的过程中代际变了：这批 entries 可能横跨两代，丢弃重跑。
            return .retryNeeded
        case .skippedUnchanged:
            return .skippedUnchanged
        case .published:
            break
        }

        snapshot = CatalogSnapshot(generation: snapshot.generation &+ 1, entries: entries, volumes: after.vector.volumes)
        let frozen = snapshot
        let prepared = await Task.detached(priority: .userInitiated) { SearchEngine(snapshot: frozen) }.value
        // 读库/建引擎期间可能已经退出：此时不要把引擎装回去。
        guard !shuttingDown else { return .keptPreviousSnapshot }
        guard snapshot.generation == frozen.generation else { return .retryNeeded }
        engine = prepared
        engineGeneration = frozen.generation
        scheduler.recordPublished(after.vector)
        runSearch(window.currentQuery)
        return .published
    }

    private func runSearch(_ query: SearchQuery) {
        searchTask?.cancel()
        searchTicket &+= 1
        let ticket = searchTicket
        let frozen = snapshot
        let cached = engineGeneration == frozen.generation ? engine : nil
        let task = Task.detached(priority: .userInitiated) {
            (cached ?? SearchEngine(snapshot: frozen)).search(query, isCancelled: { Task.isCancelled })
        }
        searchTask = task
        Task { [weak self] in
            let result = await task.value
            guard let self, ticket == self.searchTicket, result.generation == self.snapshot.generation, !result.isCancelled else { return }
            self.lastResult = result
            self.window.update(snapshot: frozen, result: result)
        }
    }

    private func createDemoFiles() throws -> URL {
        let root = dataURL.appendingPathComponent("示例文件", isDirectory: true)
        for folder in ["项目", "照片", "资料"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for i in 1...60 {
            let folder = i % 3 == 0 ? "项目" : i % 3 == 1 ? "照片" : "资料"
            let name = i % 3 == 0 ? "2026项目报告-\(i).txt" : i % 3 == 1 ? "旅行照片-\(i).jpg" : "学习资料-café-\(i).txt"
            let url = root.appendingPathComponent(folder).appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) { try Data("\(AppBrand.displayName)测试夹具 \(i)\n".utf8).write(to: url) }
        }
        return root
    }

    private func runSmoke() async {
        smokeStarted = true
        window.restoreState(NavigationState(query: SearchQuery(text: "报告")))
        runSearch(window.currentQuery)
        if let task = searchTask { _ = await task.value }
        try? await Task.sleep(for: .milliseconds(300))
        guard let result = lastResult, !result.keys.isEmpty else {
            print("SMOKE_FAILED: 报告搜索无结果")
            exit(1)
        }
        let state = NavigationState(query: SearchQuery(text: "报告"), selectedKey: result.keys.first, scrollAnchorKey: result.keys.first)
        window.restoreState(state)
        let restored = window.captureState()
        window.window?.contentView?.layoutSubtreeIfNeeded()
        guard let appWindow = window.window, appWindow.frame.width >= 720, appWindow.frame.height >= 360, restored.query.text == "报告", restored.selectedKey == state.selectedKey else {
            print("SMOKE_FAILED: 窗口尺寸或导航状态不正确")
            exit(1)
        }
        guard let appMenu = NSApplication.shared.mainMenu?.items.first?.submenu else {
            print("SMOKE_FAILED: 应用菜单缺失")
            exit(1)
        }
        // 真正让 AppKit 自动校验菜单，防止只设 isEnabled=false 却被重新启用。
        appMenu.update()
        let reportItem = appMenu.items.first { $0.action == NSSelectorFromString("runDiagnostics:") }
        let updateItem = appMenu.items.first { $0.action == #selector(checkForUpdates(_:)) }
        let reportDisabled = reportItem != nil && reportItem?.isEnabled == false
        let updateStateCorrect = updater.configuration != nil || (updateItem != nil && updateItem?.isEnabled == false)
        guard appWindow.title == AppBrand.displayName, reportDisabled, updateStateCorrect else {
            print("SMOKE_FAILED: 品牌名称或未启用菜单状态不正确")
            exit(1)
        }
        let output: [String: Any] = ["windowWidth": appWindow.frame.width, "windowHeight": appWindow.frame.height, "indexed": snapshot.entries.count, "reportMatches": result.keys.count, "queryRestored": restored.query.text == "报告", "selectionRestored": restored.selectedKey == state.selectedKey, "brand": appWindow.title, "reportMenuDisabled": reportDisabled, "updateMenuStateCorrect": updateStateCorrect]
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print("SMOKE_RESULT: \(text)") }
        if let view = window.window?.contentView?.superview, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: dataURL.appendingPathComponent("smoke.png")) }
        }
        saveNavigation()
        NSApplication.shared.terminate(nil)
    }
}
