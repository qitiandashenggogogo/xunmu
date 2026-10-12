import Foundation
import SearchCore
import Testing
@testable import SearchIndex

private func indexedEntry(
    _ volumeID: String,
    _ nodeID: Int64,
    _ relativePath: String,
    isDirectory: Bool = false,
    size: Int64 = 0,
    modifiedAt: Date = Date(timeIntervalSinceReferenceDate: 0)
) -> IndexedEntry {
    IndexedEntry(
        key: EntryKey(volumeID: volumeID, nodeID: nodeID),
        relativePath: relativePath,
        name: (relativePath as NSString).lastPathComponent,
        isDirectory: isDirectory,
        isSymbolicLink: false,
        size: size,
        modifiedAt: modifiedAt
    )
}

private func snapshot(
    _ generation: UInt64 = 1,
    _ entries: [IndexedEntry],
    volumes: [VolumeRecord] = [makeVolume()]
) -> CatalogSnapshot {
    CatalogSnapshot(generation: generation, entries: entries, volumes: volumes)
}

private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = .current
    components.year = year
    components.month = month
    components.day = dayOfMonth
    components.hour = 0
    components.minute = 0
    components.second = 0
    return components.date ?? Date(timeIntervalSinceReferenceDate: 0)
}

/// Maps result keys back to the relative paths the test declared.
private func paths(_ result: SearchResult, _ engine: SearchEngine) -> [String] {
    let lookup = Dictionary(
        uniqueKeysWithValues: engine.snapshotEntries.map { ($0.key, $0.relativePath) }
    )
    return result.keys.compactMap { lookup[$0] }
}

/// Cancellation token stub: flips to `true` after the requested number of polls.
private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var polls = 0
    private let tripAfter: Int

    init(tripAfter: Int) { self.tripAfter = tripAfter }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return polls
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        polls += 1
        return polls > tripAfter
    }
}

@Suite("SearchEngine 匹配、筛选、排序与取消")
struct SearchEngineTests {
    // MARK: - Matching

    @Test("任意位置子串，含一到两个汉字")
    func matchesSubstringAnywhereIncludingOneOrTwoChineseCharacters() {
        let entries = [
            indexedEntry("v", 1, "2026/季度报告汇总.pdf"),
            indexedEntry("v", 2, "docs/读书笔记.md"),
            indexedEntry("v", 3, "report.txt"),
        ]
        let engine = SearchEngine(snapshot: snapshot(1, entries))

        #expect(paths(engine.search(SearchQuery(text: "报告")), engine) == ["2026/季度报告汇总.pdf"])
        #expect(paths(engine.search(SearchQuery(text: "季度")), engine) == ["2026/季度报告汇总.pdf"])
        #expect(paths(engine.search(SearchQuery(text: "度报")), engine) == ["2026/季度报告汇总.pdf"])
        #expect(paths(engine.search(SearchQuery(text: "读书")), engine) == ["docs/读书笔记.md"])
        // Single Latin character, substring anywhere.
        #expect(paths(engine.search(SearchQuery(text: "r")), engine) == ["report.txt"])
    }

    @Test("默认大小写不敏感，可要求大小写敏感")
    func caseInsensitiveByDefaultAndCaseSensitiveOnDemand() {
        let entries = [
            indexedEntry("v", 1, "Readme.TXT"),
            indexedEntry("v", 2, "readme.txt"),
        ]
        let engine = SearchEngine(snapshot: snapshot(1, entries))

        #expect(paths(engine.search(SearchQuery(text: "readme")), engine).count == 2)
        // Case-sensitive must NOT fold the query term either: "readme" only hits
        // the lowercase file.
        #expect(paths(engine.search(SearchQuery(text: "readme", caseSensitive: true)), engine) == ["readme.txt"])
        // "README" differs from "Readme" in case, so a case-sensitive query must
        // find nothing at all — it is not silently normalized into a match.
        #expect(paths(engine.search(SearchQuery(text: "README", caseSensitive: true)), engine).isEmpty)
        // Exact spelling matches.
        #expect(paths(engine.search(SearchQuery(text: "Readme", caseSensitive: true)), engine) == ["Readme.TXT"])
        // Case-sensitive still reaches into the path.
        let nested = SearchEngine(snapshot: snapshot(1, [indexedEntry("v", 1, "Core/Index.swift")]))
        #expect(paths(nested.search(SearchQuery(text: "Core", caseSensitive: true)), nested) == ["Core/Index.swift"])
        #expect(paths(nested.search(SearchQuery(text: "core", caseSensitive: true)), nested).isEmpty)
        // Case-sensitive exclusion must not fold either.
        let excluded = nested.search(SearchQuery(text: "Index -CORE", caseSensitive: true))
        #expect(paths(excluded, nested) == ["Core/Index.swift"])
        #expect(paths(nested.search(SearchQuery(text: "Index -Core", caseSensitive: true)), nested).isEmpty)
    }

    @Test("组合字符与预组合字符都能匹配，且不改动原始路径")
    func unicodeNormalizationMatchesComposedAndDecomposedForms() {
        let engine = SearchEngine(snapshot: snapshot(1, [indexedEntry("v", 1, "café.txt")]))

        #expect(paths(engine.search(SearchQuery(text: "café")), engine) == ["café.txt"])
        #expect(paths(engine.search(SearchQuery(text: "café")), engine) == ["café.txt"])
        #expect(engine.snapshotEntries[0].relativePath == "café.txt", "stored path must stay verbatim")
    }

    @Test("多词 AND，-词 排除，path: 限定路径")
    func multipleWordsAreAndedAndExclusionsSubtract() {
        let entries = [
            indexedEntry("v", 1, "src/core/index.swift"),
            indexedEntry("v", 2, "src/core/index_test.swift"),
            indexedEntry("v", 3, "docs/index.md"),
            indexedEntry("v", 4, "src/core/index.tmp"),
        ]
        let engine = SearchEngine(snapshot: snapshot(1, entries))

        // Bare words match name OR path: "core" is only in the path, "index" is
        // in the name. Both are required (AND).
        let anded = engine.search(SearchQuery(text: "core index"))
        #expect(
            paths(anded, engine).sorted() == [
                "src/core/index.swift", "src/core/index.tmp", "src/core/index_test.swift",
            ]
        )
        // docs/index.md has no "core" anywhere, so it is correctly excluded.
        #expect(!paths(anded, engine).contains("docs/index.md"))

        let excluding = engine.search(SearchQuery(text: "core index -test -tmp"))
        #expect(paths(excluding, engine) == ["src/core/index.swift"])

        // Exclusion also inspects the path, so docs/index.md can be filtered out.
        #expect(paths(engine.search(SearchQuery(text: "index -docs")), engine).count == 3)

        #expect(paths(engine.search(SearchQuery(text: "path:src/core")), engine).count == 3)
        #expect(paths(engine.search(SearchQuery(text: "path:docs/index")), engine) == ["docs/index.md"])
    }

    @Test("行内过滤词 ext: / size: / date: / path:")
    func inlineFilterTokens() {
        let entries = [
            indexedEntry("v", 1, "docs/手册.pdf", size: 2_000_000, modifiedAt: day(2026, 3, 15)),
            indexedEntry("v", 2, "docs/notes.md", size: 300, modifiedAt: day(2025, 1, 2)),
            indexedEntry("v", 3, "docs/手册.txt", size: 2_000_000, modifiedAt: day(2026, 8, 1)),
        ]
        let engine = SearchEngine(snapshot: snapshot(1, entries))

        #expect(paths(engine.search(SearchQuery(text: "ext:pdf")), engine) == ["docs/手册.pdf"])
        #expect(paths(engine.search(SearchQuery(text: "ext:pdf,md")), engine).count == 2)
        #expect(paths(engine.search(SearchQuery(text: "path:docs/手册")), engine).count == 2)
        #expect(paths(engine.search(SearchQuery(text: "size:>1mb")), engine).count == 2)
        #expect(paths(engine.search(SearchQuery(text: "size:<1kb")), engine) == ["docs/notes.md"])
        #expect(paths(engine.search(SearchQuery(text: "size:1000..3000000")), engine).count == 2)
        #expect(paths(engine.search(SearchQuery(text: "size:>1mb size:<1500000")), engine).count == 0)
        #expect(
            paths(engine.search(SearchQuery(text: "date:2026-01-01..2026-06-30")), engine) == ["docs/手册.pdf"]
        )
        #expect(paths(engine.search(SearchQuery(text: "date:>2026-07-01")), engine) == ["docs/手册.txt"])
        #expect(paths(engine.search(SearchQuery(text: "date:2026-03-15")), engine).count == 1)
        #expect(paths(engine.search(SearchQuery(text: "手册 ext:pdf")), engine) == ["docs/手册.pdf"])
        #expect(paths(engine.search(SearchQuery(text: "手册 ext:pdf -path:docs/notes")), engine).count == 1)

        // Hidden files have no extension.
        let hidden = SearchEngine(snapshot: snapshot(1, [indexedEntry("v", 1, ".gitignore")]))
        #expect(paths(hidden.search(SearchQuery(text: "ext:gitignore")), hidden).isEmpty)
        #expect(paths(hidden.search(SearchQuery(text: "ext:")), hidden).count == 1, "bare ext: is not a filter")
    }

    @Test("文件名里的冒号不会被当成过滤字段")
    func colonInFilenameIsNotTreatedAsAField() {
        let entries = [
            indexedEntry("v", 1, "report:2026.txt"),
            indexedEntry("v", 2, "report-2026.txt"),
        ]
        let engine = SearchEngine(snapshot: snapshot(1, entries))

        // "report:2026" is not a known field, so the whole token must stay literal.
        #expect(paths(engine.search(SearchQuery(text: "report:2026")), engine) == ["report:2026.txt"])
    }

    // MARK: - Model filters

    @Test("模型字段筛选：扩展名/仅目录/大小/日期")
    func modelFiltersExtensionFoldersSizeAndDate() {
        let entries = [
            indexedEntry("v", 1, "a.pdf", size: 100, modifiedAt: day(2026, 5, 1)),
            indexedEntry("v", 2, "a.txt", size: 5_000, modifiedAt: day(2025, 5, 1)),
            indexedEntry("v", 3, "folder", isDirectory: true, size: 0, modifiedAt: day(2026, 5, 2)),
        ]
        let engine = SearchEngine(snapshot: snapshot(1, entries))

        var query = SearchQuery()
        query.extensions = [".PDF"]
        #expect(paths(engine.search(query), engine) == ["a.pdf"])

        query = SearchQuery()
        query.foldersOnly = true
        #expect(paths(engine.search(query), engine) == ["folder"])

        query = SearchQuery()
        query.minSize = 1_000
        #expect(paths(engine.search(query), engine) == ["a.txt"])

        query = SearchQuery()
        query.maxSize = 100
        #expect(paths(engine.search(query), engine) == ["a.pdf", "folder"])

        query = SearchQuery()
        query.modifiedAfter = day(2026, 1, 1)
        #expect(paths(engine.search(query), engine) == ["a.pdf", "folder"])

        query = SearchQuery()
        query.modifiedBefore = day(2026, 1, 1)
        #expect(paths(engine.search(query), engine) == ["a.txt"])

        query = SearchQuery()
        query.minSize = 4_000
        query.maxSize = 6_000
        query.extensions = ["txt"]
        #expect(paths(engine.search(query), engine) == ["a.txt"])
    }

    @Test("范围筛选：卷、目录（递归与非递归）、前缀不误伤")
    func scopeFiltering() {
        let entries = [
            indexedEntry("v", 1, "root.txt"),
            indexedEntry("v", 2, "docs/readme.md"),
            indexedEntry("v", 3, "docs/deep/nested.txt"),
            indexedEntry("v", 4, "docsx/other.txt"),
            indexedEntry("w", 5, "docs/other-volume.txt"),
        ]
        let engine = SearchEngine(snapshot: snapshot(1, entries, volumes: []))

        #expect(engine.search(SearchQuery()).keys.count == 5)
        #expect(engine.search(SearchQuery(scope: .volume("v"))).keys.count == 4)

        let recursive = SearchQuery(scope: .directory(volumeID: "v", relativePath: "docs", recursive: true))
        #expect(paths(engine.search(recursive), engine) == ["docs/deep/nested.txt", "docs/readme.md"])

        let shallow = SearchQuery(scope: .directory(volumeID: "v", relativePath: "docs", recursive: false))
        #expect(paths(engine.search(shallow), engine) == ["docs/readme.md"])

        // "docsx" must not be treated as being inside "docs"; "/" means the root.
        let root = SearchQuery(scope: .directory(volumeID: "v", relativePath: "/", recursive: true))
        #expect(paths(engine.search(root), engine).count == 4)

        let rootShallow = SearchQuery(scope: .directory(volumeID: "v", relativePath: "", recursive: false))
        #expect(paths(engine.search(rootShallow), engine) == ["root.txt"])
    }

    // MARK: - Ordering

    @Test("排序是稳定全序，以 (volumeID, nodeID) 决胜")
    func sortIsAStableTotalOrderWithTiebreak() {
        // Three entries tie on both name and size.
        let entries = [
            indexedEntry("b-vol", 9, "same.txt", size: 100),
            indexedEntry("a-vol", 5, "same.txt", size: 100),
            indexedEntry("a-vol", 2, "same.txt", size: 100),
        ]
        let engine = SearchEngine(snapshot: snapshot(1, entries, volumes: []))

        var query = SearchQuery(text: "same")
        query.sort = .size
        query.ascending = true
        let ascending = engine.search(query)
        #expect(ascending.keys.map(\.volumeID) == ["a-vol", "a-vol", "b-vol"])
        #expect(ascending.keys.map(\.nodeID) == [2, 5, 9], "ties resolve by (volumeID, nodeID) ascending")

        query.ascending = false
        let descending = engine.search(query)
        #expect(descending.keys.map(\.nodeID) == [2, 5, 9], "direction reverses the sort key, never the tiebreak")

        // Repeated runs are identical (total order, not just stability).
        #expect(engine.search(query).keys == descending.keys)
        #expect(engine.search(query).keys == engine.search(query).keys)
    }

    @Test("四种排序模式")
    func sortModes() {
        let entries = [
            indexedEntry("v", 1, "b/20.txt", size: 20, modifiedAt: day(2026, 1, 1)),
            indexedEntry("v", 2, "a/30.txt", size: 30, modifiedAt: day(2024, 1, 1)),
            indexedEntry("v", 3, "c/10.txt", size: 10, modifiedAt: day(2025, 1, 1)),
        ]
        let engine = SearchEngine(snapshot: snapshot(1, entries))

        var query = SearchQuery()
        query.sort = .name
        #expect(paths(engine.search(query), engine) == ["c/10.txt", "b/20.txt", "a/30.txt"])

        query.sort = .path
        #expect(paths(engine.search(query), engine) == ["a/30.txt", "b/20.txt", "c/10.txt"])

        query.sort = .size
        #expect(paths(engine.search(query), engine) == ["c/10.txt", "b/20.txt", "a/30.txt"])

        query.sort = .modified
        #expect(paths(engine.search(query), engine) == ["a/30.txt", "c/10.txt", "b/20.txt"])
    }

    @Test("同排序键下不同卷的混合结果仍全序")
    func mixedVolumeOrderingIsTotal() {
        let entries = [
            indexedEntry("vol-b", 1, "x.txt", size: 5),
            indexedEntry("vol-a", 1, "x.txt", size: 5),
            indexedEntry("vol-a", 0, "x.txt", size: 5),
        ]
        let engine = SearchEngine(snapshot: snapshot(1, entries, volumes: []))
        let result = engine.search(SearchQuery(text: "x", sort: .size, ascending: true))
        #expect(result.keys == [
            EntryKey(volumeID: "vol-a", nodeID: 0),
            EntryKey(volumeID: "vol-a", nodeID: 1),
            EntryKey(volumeID: "vol-b", nodeID: 1),
        ])
    }

    // MARK: - Cancellation & completeness

    @Test("取消的查询不返回部分结果")
    func cancelledSearchReturnsNoKeysAndFlag() {
        let entries = (1...5_000).map { indexedEntry("v", Int64($0), "file\($0).txt") }
        let engine = SearchEngine(snapshot: snapshot(3, entries))

        let immediate = engine.search(SearchQuery(), isCancelled: { true })
        #expect(immediate.isCancelled)
        #expect(immediate.keys.isEmpty)
        #expect(immediate.generation == 3, "a cancelled result still reports the snapshot it belongs to")

        let probe = CancellationProbe(tripAfter: 1)
        let midFlight = engine.search(SearchQuery(), isCancelled: probe.isCancelled)
        #expect(midFlight.isCancelled)
        #expect(midFlight.keys.isEmpty)
        #expect(probe.callCount > 1, "cancellation is polled during the scan")
    }

    @Test("未取消时取消令牌会被反复轮询但结果完整")
    func neverCancelledSearchStillReturnsEverything() {
        let entries = (1...10_000).map { indexedEntry("v", Int64($0), "f\($0).txt") }
        let engine = SearchEngine(snapshot: snapshot(1, entries))
        let probe = CancellationProbe(tripAfter: .max)
        let result = engine.search(SearchQuery(), isCancelled: probe.isCancelled)
        #expect(!result.isCancelled)
        #expect(result.keys.count == 10_000)
    }

    @Test("排序途中取消也能被捕获")
    func cancellationDuringSortIsCaught() {
        // Enough elements that the sort performs far more than a few thousand
        // comparisons, so the comparator's cancellation check must fire.
        let entries = (1...20_000).map { indexedEntry("v", Int64($0), "f\($0).txt") }
        let engine = SearchEngine(snapshot: snapshot(1, entries))

        // Passes the scan phase (which polls ~11 times), then trips inside the sort.
        let probe = CancellationProbe(tripAfter: 20)
        let result = engine.search(
            SearchQuery(text: "f", sort: .name, ascending: true),
            isCancelled: probe.isCancelled
        )
        #expect(result.isCancelled)
        #expect(result.keys.isEmpty, "a cancelled sort must not leak a partial ordering")
    }

    @Test("不做 Top-K 截断")
    func searchNeverTruncatesResults() {
        let total = 20_000
        let entries = (1...total).map { indexedEntry("v", Int64($0), "match\($0).txt") }
        let engine = SearchEngine(snapshot: snapshot(1, entries))
        let result = engine.search(SearchQuery(text: "match"))
        #expect(!result.isCancelled)
        #expect(result.keys.count == total)
    }

    @Test("全角与半角数字不被折叠")
    func fullWidthCharactersAreNotFolded() {
        let entries = [
            indexedEntry("v", 1, "２０２６年.txt"),
            indexedEntry("v", 2, "2026年.txt"),
        ]
        let engine = SearchEngine(snapshot: snapshot(1, entries))

        // Case folding yes, width folding no: full-width digits stay distinct.
        #expect(paths(engine.search(SearchQuery(text: "2026")), engine) == ["2026年.txt"])
        #expect(paths(engine.search(SearchQuery(text: "２０２６")), engine) == ["２０２６年.txt"])
    }

    @Test("裸词也能命中只在目录里的词")
    func bareTermsMatchPathAsWellAsName() {
        let entries = [
            indexedEntry("v", 1, "2026/季度报告汇总.pdf"),
            indexedEntry("v", 2, "docs/读书笔记.md"),
            indexedEntry("v", 3, "misc/random.bin"),
        ]
        let engine = SearchEngine(snapshot: snapshot(1, entries))

        // "季度" appears only in the file name here, but "2026" only in the path.
        #expect(paths(engine.search(SearchQuery(text: "季度")), engine) == ["2026/季度报告汇总.pdf"])
        #expect(paths(engine.search(SearchQuery(text: "2026")), engine) == ["2026/季度报告汇总.pdf"])
        #expect(paths(engine.search(SearchQuery(text: "读书")), engine) == ["docs/读书笔记.md"])
        // path: restricts matching to the path. Since name is always the last path
        // component it never excludes a bare-word hit, but it must still match.
        #expect(paths(engine.search(SearchQuery(text: "path:2026/季度")), engine) == ["2026/季度报告汇总.pdf"])
        #expect(paths(engine.search(SearchQuery(text: "path:不存在")), engine).isEmpty)
    }
    @Test("结果携带快照代际")
    func resultEchoesSnapshotGeneration() {
        let engine = SearchEngine(snapshot: snapshot(7, [indexedEntry("v", 1, "a.txt")]))
        #expect(engine.search(SearchQuery()).generation == 7)
        #expect(engine.count == 1)
    }

    @Test("空查询返回范围内全部条目")
    func emptyQueryReturnsEverythingInScope() {
        let entries = [indexedEntry("v", 1, "a.txt"), indexedEntry("w", 2, "b.txt")]
        let engine = SearchEngine(snapshot: snapshot(1, entries, volumes: []))

        #expect(engine.search(SearchQuery(text: "   ")).keys.count == 2)
        #expect(engine.search(SearchQuery(text: "nothing-matches-this")).keys.isEmpty)
    }
}