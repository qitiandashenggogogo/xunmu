import Testing
import Foundation
import SearchCore
import SearchIndex
import SearchScanner
@testable import SearchBench

// 真实盘验收流水线的**小规模实跑**。
//
// 这一组用例把 `RealScanRunner` 的那条路线（DirectoryScanner → 逐目录 CatalogStore.apply
// → SearchEngine → 固定查询 → 取消 → 重开 → 同键序列比较）在一个小临时目录上完整跑一遍，
// 用来证明这条路本身是通的；真实外置盘由主控用 --real-root 跑。
//
// 只在 `NSTemporaryDirectory()` 下建几十个文件，不碰用户目录，不读文件内容。

@Suite("真实盘验收流水线 · 小临时目录")
struct RealPipelineSmokeTests {

    /// 固定查询集，与真实盘模式一致（真实盘上的命中数由那边实测，这里只看流水线通不通）。
    private static let queries = ["文", "报告", "a", "jpg", ""]

    private struct Fixture {
        let root: AcceptanceTempDirectory
        let databaseDirectory: AcceptanceTempDirectory
        let database: URL
        let volume: VolumeRecord
    }

    private func buildFixture(label: String) throws -> Fixture {
        let root = try AcceptanceTempDirectory(label: label)
        // 几十个文件 + 几个子目录，足够触发多目录批次与排序。
        for index in 0..<24 {
            try root.makeFile("目录\(index % 6)/报告-\(index).pdf", contents: String(repeating: "x", count: 32))
            try root.makeFile("目录\(index % 6)/照片-\(index).jpg", contents: String(repeating: "y", count: 16))
        }
        try root.makeFile("说明.txt", contents: "说明")

        // 索引库放在夹具外面一点，但仍在同一设备上（真实盘模式会拒绕，这里是刻意的小规模冒烟）。
        let databaseDirectory = try AcceptanceTempDirectory(label: "probe-db")
        let database = databaseDirectory.path("index.sqlite", isDirectory: false)
        let volume = VolumeDiscovery.describe(rootURL: root.url, id: "smoke-\(label)")
        return Fixture(root: root, databaseDirectory: databaseDirectory, database: database, volume: volume)
    }

    @Test("扫描 → 入库 → 引擎 → 查询 → 重开同序列，端到端跑通")
    func endToEndPipeline() async throws {
        let fixture = try buildFixture(label: "pipeline")
        let scanner = DirectoryScanner()

        // 1) 首扫 + 逐目录入库
        let store = try CatalogStore(databaseURL: fixture.database)
        try await store.registerVolume(fixture.volume)

        let pass = try await RealScanRunner.runPass(volume: fixture.volume, applyTo: store, fingerprints: nil)
        #expect(pass.completed)
        #expect(pass.directoriesScanned == 7)
        #expect(pass.failedBatches == 0)
        #expect(pass.entriesSeen == 55)
        let entries = pass.entriesSeen

        // 2) 引擎
        let entriesBefore = try await store.entries()
        let snapshot = CatalogSnapshot(
            generation: try await store.generation(),
            entries: entriesBefore,
            volumes: try await store.volumes()
        )
        let engine = SearchEngine(snapshot: snapshot)
        #expect(entriesBefore.count >= entries, "入库后条目数不少于扫描见到的条目数")

        // 3) 固定查询 + 取消自检（键序列只在内存里，不落盘）
        var referenceKeys: [String: [EntryKey]] = [:]
        for text in Self.queries {
            let result = engine.search(SearchQuery(text: text))
            #expect(!result.isCancelled, "查询「\(text)」不应返回取消状态")
            #expect(Set(result.keys).count == result.keys.count, "查询「\(text)」返回了重复键")
            referenceKeys[text] = result.keys
        }
        #expect(referenceKeys["报告"]?.isEmpty == false, "夹具里有报告-*.pdf，中文查询应命中")
        #expect(referenceKeys["jpg"]?.isEmpty == false, "夹具里有 .jpg 文件")
        #expect(referenceKeys[""]?.count == snapshot.entries.count, "空查询应返回全量")

        let cancelled = engine.search(SearchQuery(text: ""), isCancelled: { true })
        #expect(cancelled.isCancelled)
        #expect(cancelled.keys.isEmpty, "取消不得返回半截结果")
        #expect(referenceKeys[""]?.isEmpty == false, "对照查询必须有命中，否则取消自检无意义")

        // 4) 重开：条目数与键序列都必须一致
        let reopened = try CatalogStore(databaseURL: fixture.database)
        let entriesAfter = try await reopened.entries()
        #expect(entriesAfter.count == entriesBefore.count, "重开后条目数必须一致")

        let reopenedEngine = SearchEngine(
            snapshot: CatalogSnapshot(
                generation: try await reopened.generation(),
                entries: entriesAfter,
                volumes: try await reopened.volumes()
            )
        )
        for text in Self.queries {
            let after = reopenedEngine.search(SearchQuery(text: text))
            #expect(
                after.keys == referenceKeys[text],
                "重开后查询「\(text)」的键序列必须与关闭前完全一致（顺序也算）"
            )
            #expect(Set(after.keys).count == after.keys.count)
        }
    }

    @Test("第二遍纯元数据扫描与第一遍逐项比较：无改动时差异为零")
    func verifyPassOnUnchangedTree() async throws {
        let fixture = try buildFixture(label: "verify")
        let scanner = DirectoryScanner()

        func fingerprints() async throws -> [String: EntryFingerprint] {
            let map = ScanFingerprintMap()
            let pass = try await RealScanRunner.runPass(volume: fixture.volume, applyTo: nil, fingerprints: map)
            #expect(pass.completed)
            #expect(pass.failedBatches == 0)
            return map.snapshot()
        }

        let first = try await fingerprints()
        let second = try await fingerprints()
        let diff = VerifyPass.diff(first: first, second: second)

        #expect(!first.isEmpty, "夹具不应为空")
        #expect(diff.totalChanges == 0, "未改动的目录两遍扫描应完全一致，实际差异 \(diff.totalChanges)")
        #expect(diff.unchanged == first.count)
    }

    @Test("真实改动会被计入差异数，而不是被当成算法失败")
    func verifyPassReportsActualChanges() async throws {
        let fixture = try buildFixture(label: "verify-change")
        let scanner = DirectoryScanner()

        func fingerprints() async throws -> [String: EntryFingerprint] {
            let map = ScanFingerprintMap()
            let pass = try await RealScanRunner.runPass(volume: fixture.volume, applyTo: nil, fingerprints: map)
            #expect(pass.completed)
            #expect(pass.failedBatches == 0)
            return map.snapshot()
        }

        let first = try await fingerprints()

        // 模拟“盘在这期间被改动”：新增、删除各一项。
        try fixture.root.makeFile("目录0/新增文件.txt", contents: "新")
        try fixture.root.remove("说明.txt")

        let second = try await fingerprints()
        let diff = VerifyPass.diff(first: first, second: second)

        #expect(diff.added == 1, "应统计出 1 个新增")
        #expect(diff.removed == 1, "应统计出 1 个消失")
        #expect(diff.totalChanges >= 2)
        #expect(diff.unchanged + diff.changed == first.count - 1)
    }

    @Test("扫描往返一次不写盘：只读扫描不改动被扫描目录")
    func readOnlyScanDoesNotModifyScanRoot() async throws {
        let fixture = try buildFixture(label: "readonly")
        let scanner = DirectoryScanner()

        func listing() throws -> [String: Int] {
            var map: [String: Int] = [:]
            guard let walker = FileManager.default.enumerator(atPath: fixture.root.url.path) else { return map }
            for case let path as String in walker {
                let attributes = try FileManager.default.attributesOfItem(atPath: fixture.root.url.appendingPathComponent(path).path)
                map[path] = (attributes[.size] as? NSNumber)?.intValue ?? -1
            }
            return map
        }

        let before = try listing()
        let pass = try await RealScanRunner.runPass(volume: fixture.volume, applyTo: nil, fingerprints: nil)
        #expect(pass.completed)
        let after = try listing()

        #expect(pass.entriesSeen > 0)
        #expect(after == before, "只读扫描不得增删改扫描根下的任何东西")
    }
}
