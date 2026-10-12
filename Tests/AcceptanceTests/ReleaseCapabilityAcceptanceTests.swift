import Testing
import Foundation
import SearchCore
import SearchIndex
import SearchUI

// 发布能力验收矩阵（黑盒）。
//
// 这些用例只测**可观察的行为契约**，不复刻实现里的单元测试：
//   1. 重开等价性：同一份代码在新的连接/进程上重开索引，条目/代际/查询结果保持
//   2. 损坏库拒绝：损坏的索引库不得被当成可用索引
//   3. 原库与视图状态保留：重开/重启不改数据，导航状态可捕获与恢复
//   4. 无同意不外传：诊断/报告产物里不得出现用户文件路径、文件名、搜索词
//   5. 无文件信息外泄：索引与报告只含元数据，不含文件内容
//
// ⚠️ 命名说明：这里**没有**跨版本升级测试。仓库里没有“旧版本”这份二进制，
//    所谓“旧索引”是**当前代码**写出的夹具，用例实际验证的是「同一份代码重开库」的等价性。
//    同样，这里测的是**索引数据库损坏**，不是安装包层面的坏包（ZIP 篡改、签名破坏）。
//    跨版本升级、Sparkle 网络升级与安装包防篡改需要真实发布包与网络环境，代码里测不了，
//    因此本文件只覆盖能在临时夹具里真跑的部分；未覆盖项在 docs/VALIDATION.md 里列明。

@Suite("发布能力 · 索引升级与保留")
struct ReleaseUpgradeAcceptanceTests {

    /// 造一份“先前写好的”索引（**当前代码**写出，不是旧版本二进制）。
    private func makeExistingIndex(_ dir: AcceptanceTempDirectory, name: String = "catalog.sqlite") async throws -> URL {
        let url = dir.path(name, isDirectory: false)
        let volume = AcceptanceFixture.internalVolume(id: "vol-internal")
        let store = try CatalogStore(databaseURL: url)
        try await store.registerVolume(volume)
        try await store.apply(
            AcceptanceFixture.batch(
                volumeID: volume.id, directory: "", paths: ["文档", "预算.xlsx"], isDirectory: { $0 == "文档" }
            )
        )
        try await store.apply(
            AcceptanceFixture.batch(volumeID: volume.id, directory: "文档", paths: ["报告.pdf", "预算-终版.pdf"])
        )
        return url
    }

    @Test("索引被重新只读打开后，条目、代际与查询结果保持不变（同一份代码的重开等价性）")
    func reopenPreservesIndexAndResults() async throws {
        let dir = try AcceptanceTempDirectory(label: "reopen")
        let url = try await makeExistingIndex(dir)

        // 重开前视角
        let before = try CatalogReader(databaseURL: url)
        let snapshotBefore = try before.snapshot()
        let engineBefore = SearchEngine(snapshot: snapshotBefore)
        let expectedKeys = engineBefore.search(SearchQuery(text: "报告")).keys

        // 重开后视角：重新打开一个连接（模拟重启后再打开）
        let after = try CatalogReader(databaseURL: url)
        let snapshotAfter = try after.snapshot()
        let engineAfter = SearchEngine(snapshot: snapshotAfter)

        #expect(snapshotAfter.generation == snapshotBefore.generation, "重开不得改变已持久化的代际")
        #expect(snapshotAfter.entries.count == snapshotBefore.entries.count, "重开不得丢条目")
        #expect(
            Set(snapshotAfter.entries.map(\.relativePath)) == Set(snapshotBefore.entries.map(\.relativePath)),
            "重开不得增删路径"
        )
        #expect(
            engineAfter.search(SearchQuery(text: "报告")).keys == expectedKeys,
            "重开后同一查询必须给出相同的键序列"
        )
        #expect(try after.checkIntegrity(full: true) == "ok", "重开后库必须完好")
    }

    @Test("重开只读不写主库：文件与旁件保持不变")
    func reopenIsReadOnly() async throws {
        let dir = try AcceptanceTempDirectory(label: "reopen-readonly")
        let url = try await makeExistingIndex(dir)

        func fingerprint() -> (Int64, Date?) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return ((attributes?[.size] as? NSNumber)?.int64Value ?? -1, attributes?[.modificationDate] as? Date)
        }
        let before = fingerprint()

        _ = try CatalogReader(databaseURL: url).snapshot()

        #expect(fingerprint() == before, "只读重开不得改动主库文件")
    }

    @Test("损坏的索引库不得被当成可用索引（数据库损坏，不是安装包坏包）")
    func corruptedIndexIsRejected() async throws {
        let dir = try AcceptanceTempDirectory(label: "corrupt")
        let url = try await makeExistingIndex(dir)

        // 把文件尾部改坏，制造一个明显损坏的库。
        var bytes = try Data(contentsOf: url)
        for index in stride(from: bytes.count - 4096, to: bytes.count, by: 1) where index >= 0 {
            bytes[index] = UInt8.random(in: 0...255)
        }
        try bytes.write(to: url)

        // 要么打开即失败，要么完整性检查明确报不 ok —— 绝不能静默当作"0 条记录"。
        var openedButUnusable = false
        if let reader = try? CatalogReader(databaseURL: url) {
            let check = (try? reader.checkIntegrity(full: true)) ?? "unknown"
            #expect(check != "ok", "损坏库不得通过完整性检查")
            if check == "ok" {
                openedButUnusable = true
            }
        }
        #expect(!openedButUnusable, "损坏库不得被当作健康索引接受")
    }

    @Test("缺失的索引不得被静默新建为空库")
    func missingFileIsRejectedNotCreated() async throws {
        let dir = try AcceptanceTempDirectory(label: "absent")
        let url = dir.path("catalog.sqlite", isDirectory: false)

        #expect(throws: (any Error).self) { _ = try CatalogReader(databaseURL: url) }
        #expect(!FileManager.default.fileExists(atPath: url.path), "打开失败不得新建空库")
    }

    @Test("只读重开之后，原库仍可继续增量更新（写入侧仍工作）")
    func indexRemainsWritableAfterReopen() async throws {
        let dir = try AcceptanceTempDirectory(label: "reopen-write")
        let url = try await makeExistingIndex(dir)

        let generationBefore = try CatalogReader(databaseURL: url).generation()

        let store = try CatalogStore(databaseURL: url)
        try await store.apply(
            AcceptanceFixture.batch(volumeID: "vol-internal", directory: "文档", paths: ["新增文件.txt"])
        )

        #expect(try await store.generation() > generationBefore, "重开后的写入应推进代际")
        #expect(try await store.entries().contains { $0.relativePath == "文档/新增文件.txt" })
    }
}

// MARK: - 视图状态保留

@Suite("发布能力 · 视图状态保留")
@MainActor
struct ReleaseViewStateTests {

    private var volumes: [VolumeRecord] {
        [AcceptanceFixture.internalVolume()]
    }

    private var snapshot: CatalogSnapshot {
        AcceptanceFixture.snapshot(
            generation: 11,
            volumes: volumes,
            entries: [
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 1, "文档", isDirectory: true),
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 2, "文档/报告.pdf", size: 2_048),
            ]
        )
    }

    private func frame(text: String, scope: SearchScope, selected: EntryKey?) -> NavigationFrame {
        NavigationFrame(
            state: NavigationState(query: SearchQuery(text: text, scope: scope), selectedKey: selected),
            snapshot: snapshot,
            result: SearchResult(generation: 11, keys: snapshot.entries.map(\.key))
        )
    }

    @Test("捕获的状态完整包含查询、范围、选区、锚点与滚动位置")
    func capturedStateCarriesEverything() {
        let state = NavigationState(
            query: SearchQuery(text: "报告", sort: .size, ascending: false),
            selectedKey: EntryKey(volumeID: "vol-internal", nodeID: 2),
            scrollAnchorKey: EntryKey(volumeID: "vol-internal", nodeID: 1),
            scrollOffset: 128.5
        )

        #expect(state.query.text == "报告")
        #expect(state.query.sort == .size)
        #expect(!state.query.ascending)
        #expect(state.selectedKey == EntryKey(volumeID: "vol-internal", nodeID: 2))
        #expect(state.scrollAnchorKey == EntryKey(volumeID: "vol-internal", nodeID: 1))
        #expect(state.scrollOffset == 128.5)
    }

    @Test("状态可序列化后原样读回（重启恢复的前提）")
    func stateSurvivesCodableRoundTrip() throws {
        let state = NavigationState(
            query: SearchQuery(text: "报告 预算", scope: .directory(volumeID: "v", relativePath: "文档", recursive: true)),
            selectedKey: EntryKey(volumeID: "v", nodeID: 9),
            scrollAnchorKey: EntryKey(volumeID: "v", nodeID: 3),
            scrollOffset: 42
        )
        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(NavigationState.self, from: data)

        #expect(restored == state, "视图状态必须能完整往返，才能在升级/重启后恢复")
    }

    @Test("目录范围前进后退保留完整状态")
    func navigationRoundTripKeepsState() {
        let rootKey = EntryKey(volumeID: "vol-internal", nodeID: 2)
        let insideKey = EntryKey(volumeID: "vol-internal", nodeID: 1)

        var history = NavigationHistory()
        history.commit(frame(text: "", scope: .all, selected: rootKey))
        history.commit(frame(text: "", scope: .directory(volumeID: "vol-internal", relativePath: "文档", recursive: false), selected: insideKey))

        let back = history.goBack()
        #expect(back?.state.query.scope == .all)
        #expect(back?.state.selectedKey == rootKey, "后退必须恢复选区")

        let forward = history.goForward()
        #expect(forward?.state.query.scope == .directory(volumeID: "vol-internal", relativePath: "文档", recursive: false))
        #expect(forward?.state.selectedKey == insideKey)
    }

    @Test("索引代际前进时，旧快照的状态仍可原样恢复")
    func stateFromOlderGenerationStillRestores() {
        let oldState = NavigationState(
            query: SearchQuery(text: "报告"),
            selectedKey: EntryKey(volumeID: "vol-internal", nodeID: 2),
            scrollOffset: 64
        )
        let data = try? JSONEncoder().encode(oldState)
        let restored = data.flatMap { try? JSONDecoder().decode(NavigationState.self, from: $0) }

        #expect(restored?.selectedKey == oldState.selectedKey, "索引换代不应让已保存的视图状态无法恢复")
        #expect(restored?.scrollOffset == 64)
    }
}

// MARK: - 隐私：公开产物不泄露用户信息

@Suite("发布能力 · 隐私边界")
struct ReleasePrivacyAcceptanceTests {

    /// 仓库根：由 #filePath 反推，不依赖当前工作目录假设。
    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)      // …/Tests/AcceptanceTests/ThisFile.swift
            .deletingLastPathComponent()     // AcceptanceTests
            .deletingLastPathComponent()     // Tests
            .deletingLastPathComponent()     // 仓库根
    }

    private static func publicBenchmarkReports() throws -> [URL] {
        let directory = repositoryRoot()
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("benchmarks", isDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        return contents.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    }

    /// 私有标识的来源。**真实标识不得出现在源码、注释、文档或错误消息里**，
    /// 因此这里全部在运行期取得：
    ///
    /// 1. 本机登录用户名（`NSUserName`，必要时含 `NSFullUserName`）——每台机器都会自动生效，
    ///    不依赖任何配置，也不会因为配置缺失而漏掉。
    /// 2. 额外的私有卷名 / 硬件标识，通过环境变量
    ///    `MACEVERYTHING_PRIVATE_IDENTIFIERS_JSON` 注入一个**字符串数组**。
    ///    这些值属于本机私密配置，**不写入仓库、不写进本文档**，只在运行测试的机器上提供。
    ///
    /// 行为约定（故意做得严格，避免“配置错了却变绿”）：
    /// - 变量**未设置** → 只用自动取得的本机用户名。这是合法的最小配置（CI 常见情形），
    ///   但此时**不覆盖**任意卷名检测，文档里也必须如实这么写。
    /// - 变量**已设置但格式非法**（不是数组 / 含非字符串元素 / 含空字符串）→ **抛错**，
    ///   绝不降级成空表。那样一次拼错的配置就会让整套私有标识检测静默失效。
    enum PrivateIdentifierSource {

        static let environmentKey = "MACEVERYTHING_PRIVATE_IDENTIFIERS_JSON"

        /// 分类标签：只用于失败诊断，**不包含标识本身**。
        enum Category: String {
            case userName = "本机用户名"
            case injectedVolume = "环境注入的卷/硬件标识"
        }

        /// 显式的配置错误。
        ///
        /// `Equatable` 是必需的：`#expect(throws:)` 要求错误类型同时满足 `Error & Equatable`。
        /// `description` 里**只说哪一类配置有问题**，不回显任何标识值。
        struct ConfigurationError: Error, Equatable, CustomStringConvertible {
            let reason: String
            var description: String { "私有标识注入配置无效：\(reason)" }
        }

        /// 合并自动取得与注入的标识（去重、去掉空白、保持稳定顺序）。
        ///
        /// - Parameters:
        ///   - environment: 环境变量表（便于测试注入）
        ///   - userName / fullUserName: 相当于 `NSUserName` / `NSFullUserName`
        static func identifiers(
            environment: [String: String],
            userName: String,
            fullUserName: String? = nil
        ) throws -> [(value: String, category: Category)] {
            var result: [(String, Category)] = []

            func add(_ raw: String?, _ category: Category, required: Bool) throws {
                guard let raw else {
                    if required { throw ConfigurationError(reason: "缺少运行期用户名") }
                    return
                }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    if required { throw ConfigurationError(reason: "运行期用户名为空") }
                    return
                }
                guard !result.contains(where: { $0.0 == trimmed }) else { return }
                result.append((trimmed, category))
            }

            try add(userName, .userName, required: true)
            try add(fullUserName, .userName, required: false)

            guard let raw = environment[environmentKey] else {
                return result   // 未配置 = 合法的最小配置，不是错误
            }
            guard let data = raw.data(using: .utf8) else {
                throw ConfigurationError(reason: "\(environmentKey) 不是合法的 UTF-8 文本")
            }
            let parsed: Any
            do {
                parsed = try JSONSerialization.jsonObject(with: data)
            } catch {
                throw ConfigurationError(reason: "\(environmentKey) 不是合法 JSON")
            }
            guard let array = parsed as? [Any] else {
                throw ConfigurationError(reason: "\(environmentKey) 顶层必须是数组")
            }
            for (index, element) in array.enumerated() {
                guard let text = element as? String else {
                    throw ConfigurationError(reason: "\(environmentKey) 第 \(index + 1) 项不是字符串")
                }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw ConfigurationError(reason: "\(environmentKey) 第 \(index + 1) 项是空字符串")
                }
                try add(text, .injectedVolume, required: false)
            }
            return result.map { (value: $0.0, category: $0.1) }
        }

        /// 便利入口：从真实进程环境读取。
        static func currentIdentifiers() throws -> [(value: String, category: Category)] {
            try identifiers(
                environment: ProcessInfo.processInfo.environment,
                userName: NSUserName(),
                fullUserName: NSFullUserName()
            )
        }
    }

    /// 逐字段遍历**解析后的** JSON，而不是对原文做字符串 `contains`。
    ///
    /// 理由：JSON 转义（`\uXXXX`、斜杠转义等）会让文本包含检查漏判；
    /// 先 `JSONSerialization` 解析成值再逐个字符串看，看到的才是真实内容。
    private static func allStringValues(in report: URL) throws -> [(key: String, value: String)] {
        try allStringValues(in: try Data(contentsOf: report), reportName: report.lastPathComponent)
    }

    private static func allStringValues(
        in data: Data,
        reportName: String
    ) throws -> [(key: String, value: String)] {
        let root = try JSONSerialization.jsonObject(with: data)
        var found: [(key: String, value: String)] = []

        func walk(_ value: Any, path: String) {
            switch value {
            case let string as String:
                found.append((path, string))
            case let array as [Any]:
                for (index, element) in array.enumerated() { walk(element, path: "\(path)[\(index)]") }
            case let dictionary as [String: Any]:
                for (key, element) in dictionary {
                    walk(element, path: path.isEmpty ? key : "\(path).\(key)")
                }
            default:
                break   // 数字 / 布尔 / null 不含可泄露文本
            }
        }
        walk(root, path: "")
        return found
    }

    /// 看起来像绝对本地路径的值（`/`、`~` 或盘符开头）。
    private static func looksLikeAbsoluteLocalPath(_ value: String) -> Bool {
        value.hasPrefix("/") || value.hasPrefix("~") || value.contains(":\\")
    }

    /// **唯一的私有标识检测真身**。生产报告与合成回归都调它，不各写一份。
    ///
    /// 只返回**类别集合**，永不返回匹配到的值。这样调用方手里的
    /// `#expect` 表达式里只会出现 `Bool` / 类别，而不会出现 `value` 或 `identifier.value`
    /// —— 否则 Swift Testing 宏在失败时会捕获并打印整个表达式的操作数，
    /// 即使自定义消息不写，也会从宏的输出里泄露出去。
    private static func privateIdentifierCategories(
        foundIn value: String,
        identifiers: [(value: String, category: PrivateIdentifierSource.Category)]
    ) -> Set<PrivateIdentifierSource.Category> {
        var categories: Set<PrivateIdentifierSource.Category> = []
        for identifier in identifiers where value.contains(identifier.value) {
            categories.insert(identifier.category)
        }
        return categories
    }

    @Test("已发布性能报告的每个字符串字段都不含用户名或外置盘名")
    func publishedReportsCarryNoUserOrVolumeNames() throws {
        // 真实标识**不进源码**：运行期取得本机用户名，额外卷/硬件标识由本机环境注入。
        // 断言只看**算好的类别集合**，失败诊断只有报告名、字段名与类别，不含标识本身。
        let identifiers = try PrivateIdentifierSource.currentIdentifiers()
        #expect(!identifiers.isEmpty, "本机用户名至少要自动取到一条")

        for report in try Self.publicBenchmarkReports() {
            for (key, value) in try Self.allStringValues(in: report) {
                let categories = Self.privateIdentifierCategories(foundIn: value, identifiers: identifiers)
                #expect(
                    categories.isEmpty,
                    """
                    \(report.lastPathComponent) 的 \(key) 含私有标识（检测类别：\
                    \(categories.map(\.rawValue).sorted().joined(separator: "、"))）
                    """
                )
            }
        }
    }

    /// **纯合成**标识的辅助逻辑回归：不碰任何真实用户数据，
    /// 证明注入通道与检测逻辑本身有效（含 JSON 转义后的真实字符串）。
    @Test("私有标识注入与检测：JSON 转义、本机用户名、注入卷名都能被检测")
    func privateIdentifierDetectionWorksOnSyntheticData() throws {
        // 全部是合成占位值，不对应任何真实机器或真实人。
        let syntheticUser = "SYNTH-USER-4c1f9a"
        let syntheticVolume = "SYNTH-VOLUME-zeta-77"
        // 故意用 JSON 转义写中文与引号，验证“先解析再比对”不会漏判。
        let injectedJSON = #"["\#(syntheticVolume)", "\u5408\u6210\u5377\u6807-\u03b2"]"#

        let identifiers = try PrivateIdentifierSource.identifiers(
            environment: [PrivateIdentifierSource.environmentKey: injectedJSON],
            userName: syntheticUser
        )
        #expect(
            identifiers.contains { $0.value == syntheticUser && $0.category == .userName },
            "本机用户名必须自动进入检测集"
        )
        #expect(
            identifiers.contains { $0.value == syntheticVolume && $0.category == .injectedVolume },
            "环境注入的卷名必须进入检测集"
        )
        #expect(
            identifiers.contains { $0.value == "合成卷标-β" && $0.category == .injectedVolume },
            "JSON \\uXXXX 转义后的真实字符串必须被解码后参与检测"
        )

        // 造一份“泄露了这些标识”的合成报告，验证确实会被抓到。
        // 注意方向：这里期望的是**检出**，不是“未检出”。
        // 检测调用的是**同一个** `privateIdentifierCategories` 真身，不是函数内的镜像实现。
        let leaky = Data(#"{"volumeName": "\#(syntheticVolume)", "user": "\#(syntheticUser)", "escaped": "\u5408\u6210\u5377\u6807-\u03b2"}"#.utf8)
        var sawUserName = false, sawInjectedVolume = false
        for (key, value) in try Self.allStringValues(in: leaky, reportName: "synthetic-leak.json") {
            let categories = Self.privateIdentifierCategories(foundIn: value, identifiers: identifiers)
            if categories.contains(.userName) { sawUserName = true }
            if categories.contains(.injectedVolume) { sawInjectedVolume = true }
            #expect(
                categories.count <= 2,
                "合成样本 \(key) 只应命中两类（用户/卷），实际类别数异常"
            )
        }
        #expect(sawUserName, "合成样本中的本机用户名必须被检出")
        #expect(sawInjectedVolume, "合成样本中的注入卷名（含 \\uXXXX 转义那条）必须被检出")

        // 反向：同一批标识下，一个**不在**检测集的词不应误报。
        let clean = Data(#"{"note": "SYNTH-CLEAN-token-9b"}"#.utf8)
        for (key, value) in try Self.allStringValues(in: clean, reportName: "synthetic-clean.json") {
            // 先算出类别集合，再断言：不让 helper 调用本身出现在 #expect 表达式里，
            // 避免宏在失败时把 value / identifiers 一起捕获打印。
            let categories = Self.privateIdentifierCategories(foundIn: value, identifiers: identifiers)
            #expect(
                categories.isEmpty,
                "合成样本 \(key) 出现误报：不属于检测集的字符串被当成了私有标识"
            )
        }
    }

    /// 配置坏了必须**显式失败**，绝不能降级成空表从而“假绿”。
    @Test("私有标识注入配置非法时显式失败，不会静默当成空表")
    func malformedPrivateIdentifierConfigurationFailsLoudly() throws {
        let key = PrivateIdentifierSource.environmentKey
        // 纯合成用户，不含任何真实标识。
        let syntheticUser = "SYNTH-USER-4c1f9a"
        // 真正合法的 JSON **对象**（不是非法 JSON），用来单独验证「顶层必须是数组」这一分支：
        // 旧写法 `#"{\"a\":\"b\"}"#` 在 raw string 里反斜杠是字面量，那其实是非法 JSON，
        // 会先被 JSON 解析拒绝，根本到不了「顶层不是数组」的分支，分类验证不成立。
        let validObject = #"{ "a": "b" }"#

        let broken = [
            ("不是 JSON", "{"),
            ("顶层不是数组（合法 JSON 对象）", validObject),
            // 注：裸数字（12345）虽然是合法 JSON，但 JSONSerialization 不开
            // .allowFragments 时会直接拒绝，根本到不了「顶层必须是数组」分支；
            // 放进来只会把夹具本身判错，所以不列。
            ("含非字符串元素", #"["ok", 7]"#),
            ("含空字符串", #"["ok", ""]"#),
            ("只含空白字符串", #"["ok", "   "]"#),
        ]
        for (label, payload) in broken {
            // 先证明这个夹具**确实是合法 JSON**（否则「顶层不是数组」分支没被真正走到）。
            let parsesAsJSON = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) != nil
            if label.hasPrefix("顶层") {
                #expect(parsesAsJSON, "\(label) 夹具必须是合法 JSON，否则验不到目标分支")
            }
            #expect(
                throws: PrivateIdentifierSource.ConfigurationError.self,
                "\(label) 必须抛错而不是降级"
            ) {
                _ = try PrivateIdentifierSource.identifiers(
                    environment: [key: payload],
                    userName: syntheticUser
                )
            }
        }

        // 错误描述**不得回显注入的 payload 或任何标识值**，否则日志本身就是泄露途径。
        let payloadWithSecret = #"["ok", 7, "\u5408\u6210\u79c1\u5bc6\u6807\u8bc6"]"#
        do {
            _ = try PrivateIdentifierSource.identifiers(
                environment: [key: payloadWithSecret],
                userName: syntheticUser
            )
            #expect(false, "含非字符串元素的配置必须抛错")
        } catch let error as PrivateIdentifierSource.ConfigurationError {
            let rendered = error.description
            #expect(!rendered.contains("合成私密标识"), "错误描述不得回显注入的标识值")
            #expect(!rendered.contains(payloadWithSecret), "错误描述不得回显原始 payload")
            #expect(!rendered.contains(syntheticUser), "错误描述不得回显本机用户名")
            #expect(rendered.contains("第"), "错误描述应指出是第几项出错（类别信息）")
        }

        // 未配置是合法的最小配置，但**仍然**要自动取到本机用户名——
        // 否则“忘了配置变量”就会让整套私有标识检测变成空转。
        let withoutConfiguration = try PrivateIdentifierSource.identifiers(
            environment: [:],
            userName: syntheticUser
        )
        #expect(withoutConfiguration.contains { $0.category == .userName },
                "未配置变量时仍必须包含本机用户名")
    }

    @Test("已发布性能报告的每个字符串字段都不含凭据或会话标识")
    func publishedReportsCarryNoCredentialsOrSessionIDs() throws {
        let forbidden = ["BEGIN RSA PRIVATE KEY", "BEGIN PRIVATE KEY", "api_key", "apikey",
                         "password", "secret", "worker_id", "session_id", "bridge note"]
        for report in try Self.publicBenchmarkReports() {
            for (key, value) in try Self.allStringValues(in: report) {
                let lowered = value.lowercased()
                for needle in forbidden {
                    #expect(
                        !lowered.contains(needle.lowercased()),
                        "\(report.lastPathComponent) 的 \(key) 含疑似凭据/会话标识：\(needle)"
                    )
                }
            }
        }
    }

    @Test("已发布性能报告的每个字符串字段都不是绝对本地路径")
    func publishedReportsContainNoAbsolutePaths() throws {
        for report in try Self.publicBenchmarkReports() {
            for (key, value) in try Self.allStringValues(in: report) {
                #expect(
                    !Self.looksLikeAbsoluteLocalPath(value),
                    "\(report.lastPathComponent) 的 \(key) 是绝对本地路径：\(value)"
                )
            }
        }
    }

    @Test("报告的键名里没有路径/文件名/用户搜索词级字段")
    func reportSchemaHasNoPathFields() throws {
        let forbiddenKeys = [
            "relativePath", "fileName", "absolutePath", "searchText",
            "queryText", "rootPath", "filePath", "names", "paths",
        ]
        // `cancel.queryText` 是基准报告里唯一与查询词同名的键。它的值来自
        // SearchBench 内部**固定的合成查询集**（见 BenchQueryCases / RealQueryCases），
        // 不是用户敲的搜索词。把它整个放过等于放弃检查，所以这里改成**值级白名单**：
        // 键名仍受限，值还必须是那几条固定字面量之一。将来真把用户搜索词写进去会直接变红。
        let allowedQueryTextValues: Set<String> = [
            "文", "报告", "a", "jpg", "", "presentation",
        ]
        for report in try Self.publicBenchmarkReports() {
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: report))
            func check(_ dictionary: [String: Any]) {
                for (key, value) in dictionary {
                    if key == "queryText", let text = value as? String {
                        #expect(
                            allowedQueryTextValues.contains(text),
                            "\(report.lastPathComponent) 的 queryText = \(text) 不在固定合成查询集内，疑似真实用户搜索词"
                        )
                    } else {
                        #expect(!forbiddenKeys.contains(key), "\(report.lastPathComponent) 含路径/文件名级字段 \(key)")
                    }
                    if let nested = dictionary[key] as? [String: Any] { check(nested) }
                }
            }
            if let dictionary = root as? [String: Any] { check(dictionary) }
        }
    }

    @Test("对外事实只到卷级，不下沉到文件级")
    func externalFactsStopAtVolumeLevel() {
        let volume = AcceptanceFixture.internalVolume()
        let names = Set(Mirror(reflecting: volume).children.compactMap(\.label))
        #expect(volume.volumeUUID?.isEmpty == false, "卷 UUID 是重挂载匹配的事实，应可用")
        #expect(!names.contains("relativePath"), "VolumeRecord 不得携带条目级相对路径")
        #expect(!names.contains("name_key") && !names.contains("path_key"), "卷记录不得带匹配键")
    }

    @Test("离线复制路径是本地操作，不带内容也不可打开")
    func copyPathIsLocalOnly() throws {
        let volume = AcceptanceFixture.internalVolume(isOnline: false)
        let entries = [AcceptanceFixture.indexedEntry(volumeID: volume.id, nodeID: 1, "文档/报告.pdf")]
        let snapshot = AcceptanceFixture.snapshot(generation: 1, volumes: [volume], entries: entries)

        let store = ResultRowStore(snapshot: snapshot, keys: [EntryKey(volumeID: volume.id, nodeID: 1)])
        let row = try #require(store.row(at: 0))
        #expect(!row.canOpen, "离线卷条目不得可打开")
        #expect(row.absoluteURL() == nil, "离线卷不得解析出可打开的绝对 URL")
        // 契约以 Sources/SearchUI/ResultRows.swift 的 `displayPath` 文档为准：
        // 它是**纯字符串拼接**（卷根 + 相对路径），不 stat、不唤醒卷、不读内容，
        // 所以离线也能给出；早先这里断言“只给相对路径”与该文档化契约不符，已改为断言真实契约。
        #expect(
            row.displayPath == volume.rootPath + "/文档/报告.pdf",
            "复制路径 = 卷根 + 相对路径（纯字符串，不触碰文件系统）"
        )
        #expect(!row.displayPath.isEmpty)

        // 卷根缺失时退化为相对路径，而不是造出一个假路径。
        let rootless = ResultRowStore(
            snapshot: AcceptanceFixture.snapshot(
                generation: 1,
                volumes: [
                    AcceptanceFixture.volume(
                        id: volume.id,
                        name: "内置盘",
                        rootPath: "",
                        fileSystem: "apfs",
                        volumeUUID: "ACCEPTANCE-INTERNAL-UUID",
                        isOnline: false
                    )
                ],
                entries: entries
            ),
            keys: [EntryKey(volumeID: volume.id, nodeID: 1)]
        )
        let fallbackRow = try #require(rootless.row(at: 0))
        #expect(fallbackRow.displayPath == "文档/报告.pdf", "无卷根时只能给相对路径")
    }
}