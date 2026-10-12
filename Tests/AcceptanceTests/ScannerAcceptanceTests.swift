import Testing
import Foundation
import Darwin
import SearchCore
import SearchIndex
import SearchScanner

// ⚠️ 依赖说明：本文件按 `docs/INTERFACES.md` 的公开契约编写，
// 需要 `Sources/SearchScanner` 落地后才能编译。
// 若要在扫描模块完成前先跑通其余验收用例，把本文件临时移出 Tests/AcceptanceTests 即可。
//
// 全部用例只扫描 `NSTemporaryDirectory()` 下由测试自己创建的夹具目录，
// 绝不扫描用户主目录、外置盘或任何真实用户文档；符号链接目标也在临时目录内。

/// 线程安全的批次收集器（`onBatch` 是 @Sendable 闭包）。
final class BatchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DirectoryBatch] = []

    func append(_ batch: DirectoryBatch) {
        lock.lock()
        storage.append(batch)
        lock.unlock()
    }

    var batches: [DirectoryBatch] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// 某个目录的最新批次。
    func latest(for directory: String) -> DirectoryBatch? {
        batches.last { $0.directoryRelativePath == directory }
    }

    var allPaths: Set<String> {
        Set(batches.flatMap { batch in batch.entries.map(\.relativePath) })
    }
}

/// 可在 `onBatch` 回调里取消宿主 Task 的句柄。
final class TaskCanceller: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelTask: (@Sendable () -> Void)?
    private var cancelled = false

    func adopt<T: Sendable>(_ task: Task<T, Never>) {
        lock.lock()
        self.cancelTask = { task.cancel() }
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let target = cancelTask
        lock.unlock()
        target?()
    }
}

@Suite("扫描器验收")
struct ScannerAcceptanceTests {

    private func buildFixture(_ temporary: AcceptanceTempDirectory) throws {
        try temporary.makeFile("说明.txt")
        try temporary.makeFile("文档/报告.pdf")
        try temporary.makeFile("文档/子目录/明细.txt")
    }

    private func volumeRecord(_ temporary: AcceptanceTempDirectory) -> VolumeRecord {
        AcceptanceFixture.volume(
            id: "vol-fixture",
            name: "验收夹具",
            rootPath: temporary.url.path,
            fileSystem: "fixture"
        )
    }

    private func runScan(
        _ temporary: AcceptanceTempDirectory,
        startingAt: [String] = [""],
        recursive: Bool = true
    ) async throws -> BatchRecorder {
        let recorder = BatchRecorder()
        let scanner = DirectoryScanner()
        try await scanner.scan(
            volume: volumeRecord(temporary),
            startingAt: startingAt,
            recursive: recursive
        ) { batch in
            recorder.append(batch)
        }
        return recorder
    }

    // MARK: - 基本枚举

    @Test("递归扫描枚举整个夹具树，每目录一个完整批次")
    func scanEnumeratesFixtureTreeWithCompleteBatches() async throws {
        let temporary = try AcceptanceTempDirectory(label: "scan")
        try buildFixture(temporary)

        let recorder = try await runScan(temporary)

        #expect(
            recorder.allPaths.isSuperset(of: ["说明.txt", "文档", "文档/报告.pdf", "文档/子目录", "文档/子目录/明细.txt"]),
            "递归扫描必须枚举到夹具里的每个目录与文件，实际: \(recorder.allPaths.sorted())"
        )
        for directory in ["", "文档", "文档/子目录"] {
            let batch = try #require(recorder.latest(for: directory), "目录「\(directory)」必须有一次枚举批次")
            #expect(batch.isComplete, "目录「\(directory)」枚举成功必须是完整批次")
            #expect(batch.issue == nil, "成功枚举不应带 issue")
            #expect(batch.volumeID == "vol-fixture")
        }
        let rootBatch = try #require(recorder.latest(for: ""))
        #expect(
            !rootBatch.entries.contains { $0.relativePath.contains("/") },
            "一个批次只描述一个目录的直属子项，实际: \(rootBatch.entries.map(\.relativePath))"
        )
    }

    @Test("非递归扫描只停在直属子项")
    func nonRecursiveScanStopsAtDirectChildren() async throws {
        let temporary = try AcceptanceTempDirectory(label: "scan-flat")
        try buildFixture(temporary)

        let recorder = try await runScan(temporary, recursive: false)

        #expect(recorder.allPaths.contains("文档"))
        #expect(
            !recorder.batches.contains { $0.directoryRelativePath == "文档" },
            "非递归不得下降到子目录"
        )
    }

    // MARK: - 符号链接

    @Test("符号链接本身入索引，但不跟随其目标")
    func scanDoesNotFollowSymbolicLinks() async throws {
        let temporary = try AcceptanceTempDirectory(label: "scan-link")
        let target = try AcceptanceTempDirectory(label: "scan-link-target")
        try buildFixture(temporary)
        try target.makeFile("越界.txt")
        try FileManager.default.createSymbolicLink(
            at: temporary.path("链接"),
            withDestinationURL: target.url
        )

        let recorder = try await runScan(temporary)

        let rootBatch = try #require(recorder.latest(for: ""))
        let linkEntry = try #require(
            rootBatch.entries.first { $0.relativePath == "链接" },
            "符号链接本身应作为条目出现"
        )
        #expect(linkEntry.isSymbolicLink, "符号链接必须被标记")
        #expect(!linkEntry.isDirectory, "指向目录的符号链接不得当作普通目录")
        #expect(
            !recorder.allPaths.contains { $0.hasPrefix("链接/") },
            "扫描器不得跟随符号链接进入其目标目录，实际: \(recorder.allPaths.filter { $0.hasPrefix("链接") }.sorted())"
        )
    }

    // MARK: - 失败目录

    @Test(
        "权限失败的目录返回 incomplete 批次并带 issue",
        .disabled(if: getuid() == 0, "以 root 运行时无法模拟权限拒绝")
    )
    func unreadableDirectoryProducesIncompleteBatchWithIssue() async throws {
        let temporary = try AcceptanceTempDirectory(label: "scan-denied")
        try temporary.makeDirectory("受限")
        try temporary.makeFile("受限/看不见.txt")
        try temporary.makeFile("可读/看得见.txt")
        temporary.chmod("受限", permissions: 0o000)
        defer { temporary.restoreDefaultPermissions("受限") }

        let recorder = try await runScan(temporary)

        let failed = try #require(
            recorder.batches.first { $0.directoryRelativePath == "受限" },
            "受限目录必须返回一个批次"
        )
        #expect(!failed.isComplete, "权限失败的目录不得标记为完整")
        #expect(failed.issue != nil, "权限失败必须带 issue，供上层显示待校验状态")
        #expect((failed.issue?.code ?? 0) > 0)

        let readable = try #require(recorder.latest(for: "可读"))
        #expect(readable.isComplete, "同一根下的可读目录仍应完整枚举")
    }

    @Test(
        "失败批次写回目录后保留旧记录并标记待校验",
        .disabled(if: getuid() == 0, "以 root 运行时无法模拟权限拒绝")
    )
    func failedDirectoryBatchAppliedToCatalogKeepsPreviousRecords() async throws {
        let temporary = try AcceptanceTempDirectory(label: "scan-denied-catalog")
        try temporary.makeDirectory("受限")
        try temporary.makeFile("受限/旧文件.txt")
        defer { temporary.restoreDefaultPermissions("受限") }

        let store = try CatalogStore(databaseURL: temporary.path("catalog.sqlite", isDirectory: false))
        try await store.registerVolume(volumeRecord(temporary))

        for batch in try await runScan(temporary).batches {
            try await store.apply(batch)
        }
        #expect(try await store.entries().contains { $0.relativePath == "受限/旧文件.txt" })

        temporary.chmod("受限", permissions: 0o000)
        let secondPass = try await runScan(temporary)
        let failedBatch = try #require(secondPass.batches.first { $0.directoryRelativePath == "受限" })
        #expect(!failedBatch.isComplete)
        try await store.apply(failedBatch)

        #expect(
            try await store.entries().contains { $0.relativePath == "受限/旧文件.txt" },
            "失败批次不得删除已有索引记录"
        )
        let restricted = try #require(try await store.entries().first { $0.relativePath == "受限" })
        #expect(restricted.state == .stale, "失败目录必须标记为待校验")
    }

    // MARK: - 删除 diff

    @Test("文件删除后重扫，该条目从索引中消失且兄弟项保留")
    func rescanAfterDeletionProducesCompleteBatchWithoutDeletedFile() async throws {
        let temporary = try AcceptanceTempDirectory(label: "scan-delete")
        try buildFixture(temporary)

        let store = try CatalogStore(databaseURL: temporary.path("catalog.sqlite", isDirectory: false))
        try await store.registerVolume(volumeRecord(temporary))
        for batch in try await runScan(temporary).batches {
            try await store.apply(batch)
        }
        #expect(try await store.entries().filter { !$0.isDirectory }.map(\.relativePath).contains("文档/报告.pdf"))

        // 只删除夹具内的一个文件，然后只重扫它所在的目录。
        try temporary.remove("文档/报告.pdf")
        for batch in try await runScan(temporary, startingAt: ["文档"], recursive: false).batches {
            try await store.apply(batch)
        }

        let after = try await store.entries().map(\.relativePath)
        #expect(!after.contains("文档/报告.pdf"), "已删除文件必须从索引中移除")
        #expect(after.contains("文档/子目录"), "同目录未删除的兄弟项必须保留")
    }

    @Test("删除目录后重扫，其子树整体移除且父目录保留")
    func rescanAfterDirectoryDeletionRemovesWholeSubtree() async throws {
        let temporary = try AcceptanceTempDirectory(label: "scan-delete-dir")
        try buildFixture(temporary)

        let store = try CatalogStore(databaseURL: temporary.path("catalog.sqlite", isDirectory: false))
        try await store.registerVolume(volumeRecord(temporary))
        for batch in try await runScan(temporary).batches {
            try await store.apply(batch)
        }

        try temporary.remove("文档/子目录")
        for batch in try await runScan(temporary, startingAt: ["文档"], recursive: true).batches {
            try await store.apply(batch)
        }

        let after = try await store.entries().map(\.relativePath)
        #expect(!after.contains("文档/子目录"), "已删除目录本身应消失")
        #expect(!after.contains("文档/子目录/明细.txt"), "已删除目录的子树应整体消失")
        #expect(after.contains("文档/报告.pdf"), "同目录仍在的文件必须保留")
    }

    // MARK: - 自排除路径

    @Test("排除路径（如索引自己的数据库）不入索引，也不触发按缺失删除")
    func excludedPathsAreSkippedWithoutCausingDeletion() async throws {
        let temporary = try AcceptanceTempDirectory(label: "scan-exclude")
        try buildFixture(temporary)
        let databaseURL = try temporary.makeFile("index.sqlite", contents: "fake-db")
        try temporary.makeFile("缓存/临时.bin", contents: "cache")

        let catalogFixture = try AcceptanceTempDirectory(label: "scan-exclude-catalog")
        let store = try CatalogStore(databaseURL: catalogFixture.path("catalog.sqlite"))
        try await store.registerVolume(volumeRecord(temporary))

        // 第一遍：不排除，先把两条记录写进索引。
        for batch in try await runScan(temporary).batches {
            try await store.apply(batch)
        }
        let initialPaths = Set(try await store.entries().map(\.relativePath))
        #expect(
            initialPaths.contains("index.sqlite") && initialPaths.contains("缓存/临时.bin"),
            "预置：未排除时两条路径都应入库"
        )

        // 第二遍：排除数据库目录后重扫，被排除项只应「不再出现」，不得变成 incomplete。
        let recorder = BatchRecorder()
        let scanner = DirectoryScanner(excludedPaths: [databaseURL.path])
        try await scanner.scan(volume: volumeRecord(temporary), startingAt: [""], recursive: true) { batch in
            recorder.append(batch)
        }

        #expect(
            !recorder.allPaths.contains("index.sqlite"),
            "排除的路径不得出现在扫描结果里"
        )
        let rootBatch = try #require(recorder.latest(for: ""))
        #expect(
            rootBatch.isComplete,
            "排除项是「正常不扫描」，不得把父目录标成不完整"
        )
        #expect(recorder.batches.allSatisfy { $0.isComplete }, "排除不得制造任何失败批次")

        for batch in recorder.batches {
            try await store.apply(batch)
        }
        #expect(
            try await store.entries().contains { $0.relativePath == "缓存/临时.bin" },
            "未排除的兄弟项必须保留"
        )
    }

    @Test("排除前缀不得误伤共享前缀的兄弟目录")
    func exclusionRespectsPathBoundary() async throws {
        let temporary = try AcceptanceTempDirectory(label: "scan-exclude-boundary")
        try temporary.makeFile("data/keep.txt")
        try temporary.makeFile("data-backup/keep.txt")
        let excluded = temporary.path("data").path

        let recorder = BatchRecorder()
        let scanner = DirectoryScanner(excludedPaths: [excluded])
        try await scanner.scan(volume: volumeRecord(temporary), startingAt: [""], recursive: true) { batch in
            recorder.append(batch)
        }

        #expect(!recorder.allPaths.contains("data/keep.txt"), "被排除的子树不得进入结果")
        #expect(
            !recorder.batches.contains { $0.directoryRelativePath == "data" },
            "被排除的子树不得被下降进入"
        )
        #expect(recorder.allPaths.contains("data-backup/keep.txt"), "「data-backup」只共享前缀，不得被排除")
    }

    // MARK: - 取消

    @Test("扫描中取消抛出 CancellationError 或在取消前已正常完成")
    func cancelDuringScanStopsTheScan() async throws {
        let temporary = try AcceptanceTempDirectory(label: "scan-cancel")
        for index in 0..<300 {
            try temporary.makeFile("目录\(String(format: "%03d", index))/文件.txt")
        }

        let recorder = BatchRecorder()
        let canceller = TaskCanceller()
        let scanner = DirectoryScanner()
        let volume = volumeRecord(temporary)

        let task = Task { () -> Result<Void, Error> in
            do {
                try await scanner.scan(volume: volume, startingAt: [""], recursive: true) { batch in
                    recorder.append(batch)
                    canceller.cancel()
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        canceller.adopt(task)

        switch await task.value {
        case .success:
            #expect(!recorder.batches.isEmpty, "取消前至少应交付一批数据")
        case .failure(let error):
            #expect(error is CancellationError, "取消扫描必须抛出 CancellationError，实际: \(error)")
        }
    }

    // MARK: - 卷发现

    @Test("describe 返回真实文件系统信息，且保留显式 ID")
    func describeRootReturnsRealFileSystemInformation() throws {
        let temporary = try AcceptanceTempDirectory(label: "describe")
        let record = VolumeDiscovery.describe(rootURL: temporary.url, id: "vol-fixture")

        #expect(record.id == "vol-fixture", "显式传入的 ID 必须保留，不得被自动 UUID 覆盖")
        #expect(
            URL(fileURLWithPath: record.rootPath).standardizedFileURL.path
                == temporary.url.standardizedFileURL.path,
            "rootPath 必须指向真实夹具目录"
        )
        #expect(!record.rootPath.isEmpty)
        #expect(!record.name.isEmpty, "无法判断名称时应回落到目录名，不得返回空")
        #expect(record.isOnline)
    }

    @Test("挂载卷列表只含真实存在的挂载点")
    func mountedVolumesReturnsRealRootsOnly() throws {
        let mounted = VolumeDiscovery.mountedVolumes()
        #expect(!mounted.isEmpty, "系统至少应有一个挂载卷")

        for record in mounted {
            #expect(!record.id.isEmpty)
            #expect(!record.rootPath.isEmpty, "挂载卷必须有真实挂载点")
            #expect(
                FileManager.default.fileExists(atPath: record.rootPath),
                "返回的挂载点必须真实存在: \(record.rootPath)"
            )
        }
        #expect(
            Set(mounted.map(\.rootPath)).count == mounted.count,
            "挂载卷列表不应出现重复挂载点"
        )
    }

    // MARK: - 事件监视器（契约级）

    @Test("journal 与持久化值不一致时拒绝重放，转为完整校验")
    func eventMonitorRefusesToResumeOnMismatchedJournal() throws {
        let temporary = try AcceptanceTempDirectory(label: "fsevents-resume")
        let root = temporary.path("监控目录", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [FileChange] = []
            func append(_ changes: [FileChange]) { lock.lock(); storage.append(contentsOf: changes); lock.unlock() }
            var changes: [FileChange] { lock.lock(); defer { lock.unlock() }; return storage }
        }

        let recorder = Recorder()
        // 传入一个不属于本卷的 journal：跨设备的事件 ID 空间不可比。
        let monitor = try FileEventMonitor(
            rootURL: root,
            sinceEventID: 999_999,
            checkpointJournal: "acceptance-not-this-device",
            onChanges: { recorder.append($0) }
        )
        try monitor.start()
        defer { monitor.stop() }

        #expect(
            !monitor.resumedFromCheckpoint,
            "journal 不一致时不得声称从检查点恢复，否则会静默跳过期间的全部变更"
        )
        #expect(monitor.journalUUID != "acceptance-not-this-device", "监视器必须暴露真实设备 journal")
    }

    @Test("扫描根不存在时抛出 rootUnavailable，而不是返回空结果")
    func scanOfMissingRootThrowsRootUnavailable() async throws {
        let temporary = try AcceptanceTempDirectory(label: "scan-missing-root")
        let missing = AcceptanceFixture.volume(
            id: "vol-missing",
            name: "不存在的根",
            rootPath: temporary.path("根本没有这个目录").path
        )
        let scanner = DirectoryScanner()

        await #expect(throws: (any Error).self) {
            try await scanner.scan(volume: missing, startingAt: [""], recursive: true) { _ in }
        }
    }

    @Test("卷拔出后 describe 标记离线并要求完整校验，不伪造可用状态")
    func describeOnMissingRootMarksOffline() throws {
        let temporary = try AcceptanceTempDirectory(label: "describe-offline")
        let missingURL = temporary.path("已拔出的卷", isDirectory: true)

        let record = VolumeDiscovery.describe(rootURL: missingURL, id: "vol-ejected")

        #expect(!record.isOnline, "不存在的根不得报告为在线")
        #expect(record.fileSystem == "unknown", "无法判断文件系统时必须标 unknown，不得猜")
        #expect(record.requiresFullVerification, "未验证的卷必须要求完整校验，禁止据缺失删除索引")
    }

    @Test("真实存在的目录被描述为在线，且带文件系统信息")
    func describeOnRealDirectoryReportsOnline() throws {
        let temporary = try AcceptanceTempDirectory(label: "describe-online")
        let record = VolumeDiscovery.describe(rootURL: temporary.url, id: "vol-present")

        #expect(record.isOnline)
        #expect(record.fileSystem != "unknown", "真实目录应能拿到文件系统类型")
        #expect(record.volumeUUID?.isEmpty == false, "本地卷应能拿到 volumeUUID 供重挂载匹配")
    }

    @Test("事件监视器先于扫描启动，返回 journal 与事件 ID")
    func eventMonitorStartsAndReportsPosition() async throws {
        let temporary = try AcceptanceTempDirectory(label: "fsevents")
        let root = temporary.path("监控目录", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [FileChange] = []
            func append(_ changes: [FileChange]) {
                lock.lock(); storage.append(contentsOf: changes); lock.unlock()
            }
            var changes: [FileChange] { lock.lock(); defer { lock.unlock() }; return storage }
        }

        let recorder = Recorder()
        let monitor = try FileEventMonitor(rootURL: root) { changes in recorder.append(changes) }
        try monitor.start()
        defer { monitor.stop() }

        #expect(monitor.journalUUID != nil, "启动后必须有 journal UUID，供 checkpoint 跨重启校验")
        #expect(monitor.currentEventID >= 0)

        // 夹具内写入一个文件，等一小段时间让事件回流。
        try temporary.makeFile("监控目录/触发.txt")
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, recorder.changes.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let changes = recorder.changes
        #expect(!changes.isEmpty, "监视启动后写入文件应收到事件")
        for change in changes {
            #expect(
                !change.relativePath.hasPrefix("/"),
                "回调路径必须是相对索引根的路径，实际: \(change.relativePath)"
            )
        }
        #expect(
            monitor.currentEventID == (changes.map(\.eventID).max() ?? monitor.currentEventID),
            "currentEventID 必须对应已收到的最大事件 ID，不能拿「最新收到」冒充「已应用」"
        )
    }
}
