import Testing
import Foundation
import SearchCore
import SearchIndex

/// 搜索引擎黑盒验收。
///
/// 只使用 `SearchEngine` + `SearchCore` 的公开接口，合成条目全部在内存中，
/// 不写任何用户文件。每条断言都针对「正确实现通过、错误实现失败」的可分辨行为。
@Suite("搜索引擎验收")
struct SearchEngineAcceptanceTests {

    private var volumes: [VolumeRecord] {
        [AcceptanceFixture.internalVolume(), AcceptanceFixture.externalVolume()]
    }

    // MARK: - 任意位置中文子串

    @Test("单字中文命中名称的开头、中间与结尾")
    func singleChineseCharacterMatchesAtAnyPosition() {
        let snapshot = AcceptanceFixture.snapshot(
            volumes: volumes,
            entries: [
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 1, "报告.pdf"),
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 2, "季度报告-终版.docx"),
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 3, "报表.xlsx"),
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 4, "预算.txt"),
            ]
        )
        let engine = SearchEngine(snapshot: snapshot)
        let hits = AcceptanceFixture.paths(of: snapshot, keys: engine.search(SearchQuery(text: "报")).keys)

        #expect(Set(hits) == Set(["报告.pdf", "报表.xlsx", "季度报告-终版.docx"]), "单字「报」应命中开头/中间/结尾三种位置")
        #expect(!hits.contains("预算.txt"), "不含「报」的文件不得命中")
    }

    @Test("双字中文可命中文件名，也可只命中路径")
    func twoChineseCharactersMatchAcrossDirectoryAndFileName() {
        let snapshot = AcceptanceFixture.snapshot(
            volumes: volumes,
            entries: [
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 1, "项目/文档/年度报告.pdf"),
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 2, "文档说明.txt"),
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 3, "工作报告.xlsx"),
            ]
        )
        let engine = SearchEngine(snapshot: snapshot)

        let byName = AcceptanceFixture.paths(of: snapshot, keys: engine.search(SearchQuery(text: "报告")).keys)
        #expect(byName == ["工作报告.xlsx", "项目/文档/年度报告.pdf"])

        // 路径上的词必须能命中：`文档` 只出现在相对路径里。
        let byPath = AcceptanceFixture.paths(of: snapshot, keys: engine.search(SearchQuery(text: "path:文档")).keys)
        #expect(byPath == ["项目/文档/年度报告.pdf", "文档说明.txt"])
    }

    @Test("裸词匹配名称或路径其一即可，不要求同时命中")
    func bareTermMatchesNameOrPath() {
        let snapshot = AcceptanceFixture.snapshot(
            volumes: volumes,
            entries: [
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 1, "预算/2026/report.pdf"),
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 2, "预算/2026/summary.pdf"),
            ]
        )
        let engine = SearchEngine(snapshot: snapshot)

        let hits = AcceptanceFixture.paths(of: snapshot, keys: engine.search(SearchQuery(text: "report")).keys)
        #expect(hits == ["预算/2026/report.pdf"], "裸词应同时匹配名称或路径")
    }

    // MARK: - Unicode 等价与原始文件名

    @Test("规范等价查询命中两种写法，但结果保留原始名字节")
    func canonicallyEquivalentQueryMatchesBothForms() {
        let precomposed = "Café 报告.pdf"          // é = U+00E9
        let decomposed = "Cafe\u{301} 报告.pdf"    // e + U+0301
        #expect(Array(precomposed.utf8) != Array(decomposed.utf8), "两个夹具名必须在字节层面不同")

        let snapshot = AcceptanceFixture.snapshot(
            volumes: volumes,
            entries: [
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 1, precomposed),
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 2, decomposed),
            ]
        )
        let engine = SearchEngine(snapshot: snapshot)
        let rows = AcceptanceFixture.entriesByKey(
            snapshot,
            keys: engine.search(SearchQuery(text: "café")).keys
        )

        #expect(Set(rows.keys) == Set([precomposed, decomposed]), "规范等价查询应同时命中两种写法")
        #expect(rows[precomposed]?.name == precomposed, "结果必须保留预组合原始名")
        #expect(rows[decomposed]?.name == decomposed, "结果必须保留分解形式原始名")
        #expect(!rows.values.contains { $0.name != $0.relativePath }, "name 必须是 relativePath 的原始末段")
    }

    @Test("原始文件名不被裁剪或改写")
    func originalFileNameBytesAreNeverRewritten() {
        let oddName = "  报表  最终版 (1).xlsx  "
        let snapshot = AcceptanceFixture.snapshot(
            volumes: volumes,
            entries: [
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 1, oddName),
            ]
        )
        let engine = SearchEngine(snapshot: snapshot)
        let rows = AcceptanceFixture.entriesByKey(snapshot, keys: engine.search(SearchQuery(text: "报表")).keys)

        #expect(rows[oddName]?.name == "  报表  最终版 (1).xlsx  ", "首尾空格属于原始文件名，不得被裁剪")
    }

    @Test("区分大小写时只匹配同样大小写")
    func caseSensitiveQueryOnlyMatchesExactCase() {
        let snapshot = AcceptanceFixture.snapshot(
            volumes: volumes,
            entries: [
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 1, "Report.PDF"),
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 2, "report.pdf"),
            ]
        )
        let engine = SearchEngine(snapshot: snapshot)

        let insensitive = AcceptanceFixture.paths(
            of: snapshot,
            keys: engine.search(SearchQuery(text: "report", caseSensitive: false)).keys
        )
        #expect(Set(insensitive) == Set(["Report.PDF", "report.pdf"]), "默认大小写不敏感")

        let sensitive = AcceptanceFixture.paths(
            of: snapshot,
            keys: engine.search(SearchQuery(text: "report", caseSensitive: true)).keys
        )
        #expect(sensitive == ["report.pdf"], "区分大小写时不得匹配 Report.PDF")
    }

    @Test("区分大小写时查询输入的大小写原样保留")
    func caseSensitiveQueryKeepsInputCase() {
        let snapshot = AcceptanceFixture.snapshot(
            volumes: volumes,
            entries: [
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 1, "Report.PDF"),
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 2, "report.pdf"),
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 3, "REPORT-notes.txt"),
            ]
        )
        let engine = SearchEngine(snapshot: snapshot)

        // 输入 "REPORT" 且区分大小写：只能命中名字里真的是 REPORT 的那条。
        let exactUpper = AcceptanceFixture.paths(
            of: snapshot,
            keys: engine.search(SearchQuery(text: "REPORT", caseSensitive: true)).keys
        )
        #expect(exactUpper == ["REPORT-notes.txt"], "区分大小写时必须按输入的原始大小写匹配")

        // 输入 "Report" 时同样只能命中那条，不能被降级成小写去匹配 report.pdf。
        let exactMixed = AcceptanceFixture.paths(
            of: snapshot,
            keys: engine.search(SearchQuery(text: "Report", caseSensitive: true)).keys
        )
        #expect(exactMixed == ["Report.PDF"], "不得把查询降级为小写后再比较")

        // 查询对象本身也要原样保留，便于 UI 回显。
        let query = SearchQuery(text: "RePoRt", caseSensitive: true)
        #expect(query.text == "RePoRt", "查询文本不得被规范化")
        #expect(engine.search(query).keys.count == 0, "混合大小写输入在区分模式下应无命中")
    }

    // MARK: - 多卷全命中与稳定总序

    @Test("跨卷查询返回全部命中")
    func multiVolumeQueryReturnsEveryHitAcrossVolumes() {
        let snapshot = AcceptanceFixture.snapshot(
            volumes: volumes,
            entries: [
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 1, "共享/报告.pdf"),
                AcceptanceFixture.indexedEntry(volumeID: "vol-external", nodeID: 2, "共享/报告.pdf"),
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 3, "共享/报告-副本.pdf"),
                AcceptanceFixture.indexedEntry(volumeID: "vol-external", nodeID: 4, "其他/报告.pdf"),
                AcceptanceFixture.indexedEntry(volumeID: "vol-external", nodeID: 5, "其他/发票.pdf"),
            ]
        )
        let engine = SearchEngine(snapshot: snapshot)
        let result = engine.search(SearchQuery(text: "报告"))

        #expect(!result.isCancelled)
        #expect(result.keys.count == 4, "两个卷上的 4 条命中必须全部返回")
        #expect(Set(result.keys.map(\.volumeID)) == Set(["vol-internal", "vol-external"]))
        #expect(result.generation == snapshot.generation, "结果必须回显快照代际")
    }

    @Test("5000 条全部命中不得被 Top-K 截断，且引擎自身保证结果键唯一")
    func noTopKTruncationForLargeHitSet() {
        let total = 5_000
        let entries = (0..<total).map { index in
            AcceptanceFixture.indexedEntry(
                volumeID: index.isMultiple(of: 2) ? "vol-internal" : "vol-external",
                nodeID: Int64(index + 1),
                "报告/文档-\(String(format: "%05d", index)).pdf"
            )
        }
        let snapshot = AcceptanceFixture.snapshot(volumes: volumes, entries: entries)
        let engine = SearchEngine(snapshot: snapshot)
        let result = engine.search(SearchQuery(text: "文档"))

        #expect(result.keys.count == total, "\(total) 条全部命中不得被 Top-K 截断")
        #expect(Set(result.keys).count == total, "结果键不得重复")
    }

    @Test("快照含重复键时引擎不产生重复结果行")
    func engineProducesUniqueKeysEvenIfSnapshotRepeatsAKey() {
        // 快照里同一个键出现两次（理论上不该发生，但引擎必须自己兜住）：
        // 结果键必须唯一，否则 UI 的行号与结果位置会错位。
        let duplicated = AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 7, "重复/同名.pdf")
        let entries = [
            AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 1, "目录/甲.pdf"),
            duplicated,
            duplicated,
            AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 9, "目录/乙.pdf"),
        ]
        let snapshot = AcceptanceFixture.snapshot(volumes: volumes, entries: entries)
        let engine = SearchEngine(snapshot: snapshot)
        let result = engine.search(SearchQuery(text: ".pdf"))

        #expect(Set(result.keys).count == result.keys.count, "引擎必须自己保证结果键唯一，不能指望 UI 去重")
        #expect(result.keys.count >= 3, "三条不同条目都应命中")
    }

    @Test("不同查询各自返回无重复的键")
    func everyQueryReturnsUniqueKeys() {
        let snapshot = AcceptanceFixture.snapshot(
            volumes: volumes,
            paths: AcceptanceFixture.syntheticPaths(count: 5_000),
            volumeID: "vol-internal"
        )
        let engine = SearchEngine(snapshot: snapshot)

        for text in ["文", "报告", "a", "presentation", ""] {
            let result = engine.search(SearchQuery(text: text))
            #expect(
                Set(result.keys).count == result.keys.count,
                "查询「\(text)」返回了重复键，键数 \(result.keys.count)、唯一数 \(Set(result.keys).count)"
            )
        }
    }

    @Test("全序决胜为 (volumeID, nodeID) 升序")
    func orderingIsStrictTotalOrderWithKeyTiebreaker() {
        // 名称、大小、日期全部相同：唯一排序依据必须是 (volumeID, nodeID) 升序。
        let entries = [
            AcceptanceFixture.indexedEntry(volumeID: "vol-external", nodeID: 9, "a/同名.txt", size: 100, modifiedOffsetSeconds: 10),
            AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 5, "a/同名.txt", size: 100, modifiedOffsetSeconds: 10),
            AcceptanceFixture.indexedEntry(volumeID: "vol-external", nodeID: 3, "a/同名.txt", size: 100, modifiedOffsetSeconds: 10),
            AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 7, "a/同名.txt", size: 100, modifiedOffsetSeconds: 10),
        ]
        let snapshot = AcceptanceFixture.snapshot(volumes: volumes, entries: entries)
        let engine = SearchEngine(snapshot: snapshot)
        let expected = ["vol-external#3", "vol-external#9", "vol-internal#5", "vol-internal#7"]

        for sort in SearchSort.allCases {
            for ascending in [true, false] {
                let ordered = engine
                    .search(SearchQuery(text: "同名", sort: sort, ascending: ascending))
                    .keys
                    .map { "\($0.volumeID)#\($0.nodeID)" }
                #expect(
                    ordered == expected,
                    "sort=\(sort.rawValue) ascending=\(ascending) 时全序决胜必须是 (volumeID, nodeID) 升序"
                )
            }
        }
    }

    @Test("四种排序键与升降序方向一致且可重复")
    func sortDirectionsAreConsistentAndStable() {
        let snapshot = AcceptanceFixture.snapshot(
            volumes: volumes,
            entries: [
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 1, "b.pdf", size: 300, modifiedOffsetSeconds: 300),
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 2, "a.pdf", size: 100, modifiedOffsetSeconds: 100),
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 3, "c.pdf", size: 200, modifiedOffsetSeconds: 200),
            ]
        )
        let engine = SearchEngine(snapshot: snapshot)

        func paths(_ result: SearchResult) -> [String] {
            AcceptanceFixture.paths(of: snapshot, keys: result.keys)
        }

        #expect(paths(engine.search(SearchQuery(text: ".pdf", sort: .name, ascending: true))) == ["a.pdf", "b.pdf", "c.pdf"])
        #expect(paths(engine.search(SearchQuery(text: ".pdf", sort: .name, ascending: false))) == ["c.pdf", "b.pdf", "a.pdf"])
        #expect(paths(engine.search(SearchQuery(text: ".pdf", sort: .size, ascending: true))) == ["a.pdf", "c.pdf", "b.pdf"])
        #expect(paths(engine.search(SearchQuery(text: ".pdf", sort: .modified, ascending: true))) == ["a.pdf", "c.pdf", "b.pdf"])

        let first = engine.search(SearchQuery(text: ".pdf", sort: .size, ascending: false)).keys
        for _ in 0..<5 {
            #expect(
                engine.search(SearchQuery(text: ".pdf", sort: .size, ascending: false)).keys == first,
                "重复查询必须给出完全一致的顺序"
            )
        }
    }

    // MARK: - 取消

    @Test("扫描前取消返回空结果并标记取消")
    func cancelledBeforeScanReturnsNoKeys() {
        let snapshot = AcceptanceFixture.snapshot(
            volumes: volumes,
            paths: AcceptanceFixture.syntheticPaths(count: 2_000),
            volumeID: "vol-internal"
        )
        let engine = SearchEngine(snapshot: snapshot)
        let result = engine.search(SearchQuery(text: "文档"), isCancelled: { true })

        #expect(result.isCancelled, "扫描前取消必须标记 isCancelled")
        #expect(result.keys.isEmpty, "取消的结果不得返回任何半截命中")
    }

    @Test("扫描途中取消仍返回空结果而不是半截结果")
    func cancellationDuringScanReturnsNoKeysNotPartial() {
        let snapshot = AcceptanceFixture.snapshot(
            volumes: volumes,
            paths: AcceptanceFixture.syntheticPaths(count: 20_000),
            volumeID: "vol-internal"
        )
        let engine = SearchEngine(snapshot: snapshot)
        let cancelSwitch = AcceptanceFixture.CancellationSwitch(cancelAfterChecks: 3)
        let result = engine.search(SearchQuery(text: "文档"), isCancelled: cancelSwitch.closure)

        #expect(result.isCancelled, "扫描途中取消必须标记 isCancelled")
        #expect(result.keys.isEmpty, "取消必须返回空结果，调用方不得把半截结果当成完整结果")
    }

    @Test("取消后重跑得到完整结果")
    func nonCancelledRunAfterCancelledRunIsComplete() {
        let snapshot = AcceptanceFixture.snapshot(
            volumes: volumes,
            paths: AcceptanceFixture.syntheticPaths(count: 20_000),
            volumeID: "vol-internal"
        )
        let engine = SearchEngine(snapshot: snapshot)

        let cancelled = engine.search(SearchQuery(text: "文档"), isCancelled: { true })
        #expect(cancelled.isCancelled)

        let complete = engine.search(SearchQuery(text: "文档"))
        #expect(!complete.isCancelled)
        #expect(!complete.keys.isEmpty, "取消后重跑必须得到完整结果，不得被旧取消状态污染")
    }

    // MARK: - 范围与筛选

    @Test("卷范围与目录范围（递归/非递归）各自生效")
    func volumeAndDirectoryScopes() {
        let entries = [
            AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 1, "文档", isDirectory: true),
            AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 2, "文档/报告.pdf"),
            AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 3, "文档/子目录/明细.pdf"),
            AcceptanceFixture.indexedEntry(volumeID: "vol-external", nodeID: 4, "文档/外置.pdf"),
        ]
        let snapshot = AcceptanceFixture.snapshot(volumes: volumes, entries: entries)
        let engine = SearchEngine(snapshot: snapshot)

        let inVolume = AcceptanceFixture.paths(
            of: snapshot,
            keys: engine.search(SearchQuery(text: ".pdf", scope: .volume("vol-internal"))).keys
        )
        #expect(Set(inVolume) == Set(["文档/报告.pdf", "文档/子目录/明细.pdf"]), "卷范围不得串到外置盘")

        let recursive = AcceptanceFixture.paths(
            of: snapshot,
            keys: engine.search(
                SearchQuery(text: ".pdf", scope: .directory(volumeID: "vol-internal", relativePath: "文档", recursive: true))
            ).keys
        )
        #expect(Set(recursive) == Set(["文档/报告.pdf", "文档/子目录/明细.pdf"]))

        let flat = AcceptanceFixture.paths(
            of: snapshot,
            keys: engine.search(
                SearchQuery(text: ".pdf", scope: .directory(volumeID: "vol-internal", relativePath: "文档", recursive: false))
            ).keys
        )
        #expect(flat == ["文档/报告.pdf"], "非递归目录范围只看直属子项")
    }

    @Test("目录范围不匹配共享前缀的兄弟目录")
    func directoryScopeDoesNotMatchSiblingWithSharedStringPrefix() {
        let snapshot = AcceptanceFixture.snapshot(
            volumes: volumes,
            entries: [
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 1, "文档/甲.pdf"),
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 2, "文档备份/乙.pdf"),
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 3, "文档资料/丙.pdf"),
            ]
        )
        let engine = SearchEngine(snapshot: snapshot)
        let hits = AcceptanceFixture.paths(
            of: snapshot,
            keys: engine.search(
                SearchQuery(text: ".pdf", scope: .directory(volumeID: "vol-internal", relativePath: "文档", recursive: true))
            ).keys
        )
        #expect(hits == ["文档/甲.pdf"], "目录范围不得把「文档备份」「文档资料」当作子路径")
    }

    @Test("目录范围不把仅大小写不同的路径当作子路径")
    func directoryScopeIsCaseSensitiveOnPathPrefix() {
        let snapshot = AcceptanceFixture.snapshot(
            volumes: volumes,
            entries: [
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 1, "Docs/甲.pdf"),
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 2, "docs/乙.pdf"),
            ]
        )
        let engine = SearchEngine(snapshot: snapshot)
        let hits = AcceptanceFixture.paths(
            of: snapshot,
            keys: engine.search(
                SearchQuery(text: ".pdf", scope: .directory(volumeID: "vol-internal", relativePath: "Docs", recursive: true))
            ).keys
        )
        #expect(hits == ["Docs/甲.pdf"], "范围比较必须按真实路径字节，不能大小写折叠后把 docs 也算进来")
    }

    @Test("扩展名、大小、日期与仅文件夹筛选")
    func extensionSizeAndDateFilters() {
        let snapshot = AcceptanceFixture.snapshot(
            volumes: volumes,
            entries: [
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 1, "小报告.pdf", size: 1_000, modifiedOffsetSeconds: 0),
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 2, "大报告.pdf", size: 50_000_000, modifiedOffsetSeconds: 100_000),
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 3, "大报告.txt", size: 50_000_000, modifiedOffsetSeconds: 100_000),
            ]
        )
        let engine = SearchEngine(snapshot: snapshot)

        let pdf = AcceptanceFixture.paths(of: snapshot, keys: engine.search(SearchQuery(text: "报告", extensions: ["PDF"])).keys)
        #expect(Set(pdf) == Set(["小报告.pdf", "大报告.pdf"]), "扩展名筛选应忽略大小写与前导点")

        let large = AcceptanceFixture.paths(of: snapshot, keys: engine.search(SearchQuery(text: "报告", minSize: 1_000_000)).keys)
        #expect(Set(large) == Set(["大报告.pdf", "大报告.txt"]))

        let early = AcceptanceFixture.paths(
            of: snapshot,
            keys: engine.search(
                SearchQuery(text: "报告", modifiedBefore: AcceptanceFixture.baseDate.addingTimeInterval(50_000))
            ).keys
        )
        #expect(early == ["小报告.pdf"], "日期筛选必须真正生效")

        let folders = AcceptanceFixture.paths(of: snapshot, keys: engine.search(SearchQuery(text: "报告", foldersOnly: true)).keys)
        #expect(folders.isEmpty, "仅文件夹时不得返回文件")
    }

    @Test("空格分词为 AND，-词为排除")
    func exclusionAndMultipleTermsAreAndSemantics() {
        let snapshot = AcceptanceFixture.snapshot(
            volumes: volumes,
            entries: [
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 1, "预算/2026/预算表.xlsx"),
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 2, "预算/2025/预算表.xlsx"),
                AcceptanceFixture.indexedEntry(volumeID: "vol-internal", nodeID: 3, "实际/2026/预算表.xlsx"),
            ]
        )
        let engine = SearchEngine(snapshot: snapshot)

        #expect(
            AcceptanceFixture.paths(of: snapshot, keys: engine.search(SearchQuery(text: "预算 2026")).keys)
                == ["预算/2026/预算表.xlsx", "实际/2026/预算表.xlsx"],
            "空格分词应为 AND"
        )
        #expect(
            AcceptanceFixture.paths(of: snapshot, keys: engine.search(SearchQuery(text: "预算 -2025")).keys)
                == ["预算/2026/预算表.xlsx", "实际/2026/预算表.xlsx"],
            "-词 应排除包含该词的条目"
        )
        #expect(
            AcceptanceFixture.paths(of: snapshot, keys: engine.search(SearchQuery(text: "预算 -实际")).keys)
                == ["预算/2026/预算表.xlsx", "预算/2025/预算表.xlsx"]
        )
    }

    @Test("空查询返回全库且给出稳定全序")
    func emptyQueryReturnsWholeCatalogInTotalOrder() {
        let snapshot = AcceptanceFixture.snapshot(
            volumes: volumes,
            paths: AcceptanceFixture.syntheticPaths(count: 1_000),
            volumeID: "vol-internal"
        )
        let engine = SearchEngine(snapshot: snapshot)
        let result = engine.search(SearchQuery(text: ""))

        #expect(result.keys.count == snapshot.entries.count, "空查询应返回全部条目，不截断")
        let lookup = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.key, $0) })
        let orderedNames = result.keys.compactMap { lookup[$0]?.name }
        let expectedNames = snapshot.entries.map(\.name).sorted { $0.folding(options: .caseInsensitive, locale: nil).compare($1.folding(options: .caseInsensitive, locale: nil)) == .orderedAscending }
        #expect(orderedNames == expectedNames, "空查询按名称排序；同名时按稳定身份决胜")
        #expect(engine.search(SearchQuery()).keys == result.keys)
    }
}
