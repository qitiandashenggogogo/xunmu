import Foundation
import SearchCore
import Testing
@testable import SearchIndex

/// Covers the invariants the performance work had to preserve.
///
/// The engine now sorts dense key arrays instead of index permutations into the
/// ~130-byte `Record`, precomputes an 8-byte ordering prefix, and dedups on
/// `nodeID`. Every one of those is an opportunity to silently change result order,
/// so the ordering contract is pinned here rather than inferred.
@Suite("排序全序、去重与查询不变量")
struct SearchOrderingTests {
    private func entry(
        _ volumeID: String,
        _ nodeID: Int64,
        _ relativePath: String,
        size: Int64 = 0,
        modifiedAt: Double = 0
    ) -> IndexedEntry {
        IndexedEntry(
            key: EntryKey(volumeID: volumeID, nodeID: nodeID),
            relativePath: relativePath,
            name: (relativePath as NSString).lastPathComponent,
            size: size,
            modifiedAt: Date(timeIntervalSinceReferenceDate: modifiedAt)
        )
    }

    private func engine(_ entries: [IndexedEntry]) -> SearchEngine {
        SearchEngine(snapshot: CatalogSnapshot(generation: 7, entries: entries, volumes: []))
    }

    @Test("四种排序各自都是全序：无重复键且可重复复现")
    func everySortIsATotalOrder() {
        // Deliberately includes equal primary keys so the tiebreaker is exercised,
        // and names long enough to share an 8-byte prefix so the prefix-key
        // prefilter's fallback path is exercised too.
        var entries: [IndexedEntry] = []
        for index in 0..<600 {
            entries.append(
                entry(
                    index % 3 == 0 ? "vol-b" : "vol-a",
                    Int64(index),
                    "directory-with-a-long-prefix/shared-\(index % 97).txt",
                    size: Int64(index % 5),
                    modifiedAt: Double(index % 7)
                )
            )
        }
        let subject = engine(entries)
        for sort in SearchSort.allCases {
            for ascending in [true, false] {
                var query = SearchQuery()
                query.sort = sort
                query.ascending = ascending
                let first = subject.search(query).keys
                let second = subject.search(query).keys
                #expect(first == second, "\(sort.rawValue) 重复运行结果不一致")
                #expect(Set(first).count == first.count, "\(sort.rawValue) 出现重复键")
                #expect(first.count == entries.count)
            }
        }
    }

    @Test("同名跨卷：决胜键恒为 (volumeID, nodeID) 升序，降序也不反转")
    func sameNameAcrossVolumesUsesAscendingTiebreak() {
        let entries = [
            entry("vol-b", 9, "same.txt", size: 100, modifiedAt: 500),
            entry("vol-a", 5, "same.txt", size: 100, modifiedAt: 500),
            entry("vol-a", 2, "same.txt", size: 100, modifiedAt: 500),
            entry("vol-a", 1, "same.txt", size: 100, modifiedAt: 500),
        ]
        let subject = engine(entries)
        let expected = [
            EntryKey(volumeID: "vol-a", nodeID: 1),
            EntryKey(volumeID: "vol-a", nodeID: 2),
            EntryKey(volumeID: "vol-a", nodeID: 5),
            EntryKey(volumeID: "vol-b", nodeID: 9),
        ]
        for sort in SearchSort.allCases {
            for ascending in [true, false] {
                var query = SearchQuery(sort: sort, ascending: ascending)
                query.text = "same"
                #expect(
                    subject.search(query).keys == expected,
                    "\(sort.rawValue)/\(ascending) 的决胜键应恒为升序"
                )
            }
        }
    }

    @Test("主键相同时降序不改变组内决胜顺序")
    func descendingKeepsAscendingTiebreakWithinGroups() {
        // Two groups of equal size; descending must reverse the groups while each
        // group keeps ascending (volumeID, nodeID).
        let entries = [
            entry("vol-a", 1, "small-a.txt", size: 1),
            entry("vol-a", 2, "small-b.txt", size: 1),
            entry("vol-a", 3, "large-a.txt", size: 99),
            entry("vol-a", 4, "large-b.txt", size: 99),
        ]
        let subject = engine(entries)
        var descending = SearchQuery(text: ".txt", sort: .size, ascending: false)
        descending.sort = .size
        let result = subject.search(descending).keys
        #expect(result == [
            EntryKey(volumeID: "vol-a", nodeID: 3),
            EntryKey(volumeID: "vol-a", nodeID: 4),
            EntryKey(volumeID: "vol-a", nodeID: 1),
            EntryKey(volumeID: "vol-a", nodeID: 2),
        ])
    }

    @Test("短中文与任意位置子串")
    func shortChineseSubstringMatching() {
        let entries = [
            entry("v", 1, "2026/季度报告汇总.pdf"),
            entry("v", 2, "docs/读书笔记.md"),
            entry("v", 3, "财务/年度预算表.xlsx"),
            entry("v", 4, "misc/random.bin"),
        ]
        let subject = engine(entries)
        #expect(subject.search(SearchQuery(text: "报")).keys == [EntryKey(volumeID: "v", nodeID: 1)])
        #expect(subject.search(SearchQuery(text: "预算")).keys == [EntryKey(volumeID: "v", nodeID: 3)])
        #expect(subject.search(SearchQuery(text: "读书")).keys == [EntryKey(volumeID: "v", nodeID: 2)])
        // A term that only lives in a parent directory still matches.
        #expect(subject.search(SearchQuery(text: "2026")).keys == [EntryKey(volumeID: "v", nodeID: 1)])
        #expect(subject.search(SearchQuery(text: "财务")).keys == [EntryKey(volumeID: "v", nodeID: 3)])
        #expect(subject.search(SearchQuery(text: "不存在")).keys.isEmpty)
    }

    @Test("取消：任何阶段取消都返回空结果并置位，不返回部分结果")
    func cancellationNeverLeaksPartialResults() {
        let entries = (1...20_000).map {
            entry("v", Int64($0), "dir\($0 % 50)/file\($0).txt", size: Int64($0 % 97))
        }
        let subject = engine(entries)

        let immediate = subject.search(SearchQuery(text: "file"), isCancelled: { true })
        #expect(immediate.isCancelled)
        #expect(immediate.keys.isEmpty)
        #expect(immediate.generation == 7, "取消结果仍要带上快照代际")

        // Cancel part-way through the scan.
        final class Probe: @unchecked Sendable {
            private let lock = NSLock()
            private var polls = 0
            let tripAfter: Int
            init(tripAfter: Int) { self.tripAfter = tripAfter }
            func isCancelled() -> Bool {
                lock.lock(); defer { lock.unlock() }
                polls += 1
                return polls > tripAfter
            }
        }
        for trip in [1, 3, 10] {
            let probe = Probe(tripAfter: trip)
            let result = subject.search(SearchQuery(text: "file"), isCancelled: probe.isCancelled)
            #expect(result.isCancelled, "tripAfter=\(trip) 应判定为取消")
            #expect(result.keys.isEmpty)
        }

        // Never cancelling still returns everything.
        let probe = Probe(tripAfter: .max)
        let complete = subject.search(SearchQuery(text: "file"), isCancelled: probe.isCancelled)
        #expect(!complete.isCancelled)
        #expect(complete.keys.count == 20_000)
    }

    @Test("重复条目按 nodeID 去重，不影响其它节点")
    func duplicateEntriesAreDeduped() {
        let entries = [
            entry("vol-a", 1, "a.txt", size: 10),
            entry("vol-a", 2, "b.txt", size: 20),
            entry("vol-b", 1, "c.txt", size: 30),
        ]
        // Same nodes repeated, interleaved.
        var withDuplicates: [IndexedEntry] = []
        for _ in 0..<4 { withDuplicates += entries }
        let subject = engine(withDuplicates)

        #expect(subject.count == 3, "同一 nodeID 只应保留一条")
        let result = subject.search(SearchQuery(text: ".txt", sort: .name, ascending: true))
        #expect(result.keys.count == 3)
        #expect(Set(result.keys).count == 3)
        // Different volumes may legitimately reuse the same node number.
        let subject2 = engine(entries)
        #expect(subject2.search(SearchQuery(text: ".txt")).keys.count == 3)
    }

    @Test("同一快照重复构建的引擎结果完全一致")
    func rebuildIsDeterministic() {
        let entries = (1..<2_000).map {
            entry(
                "vol-\($0 % 2)",
                Int64($0),
                "prefix/shared-name-\($0 % 311).ext\($0 % 5)",
                size: Int64($0 % 13),
                modifiedAt: Double($0 % 29)
            )
        }
        let snapshot = CatalogSnapshot(generation: 3, entries: entries, volumes: [])
        for sort in SearchSort.allCases {
            var query = SearchQuery(sort: sort, ascending: true)
            let a = SearchEngine(snapshot: snapshot).search(query).keys
            let b = SearchEngine(snapshot: snapshot).search(query).keys
            #expect(a == b, "\(sort.rawValue) 两次独立构建结果应一致")
            #expect(a.count == entries.count)
            query.ascending = false
            let c = SearchEngine(snapshot: snapshot).search(query).keys
            #expect(SearchEngine(snapshot: snapshot).search(query).keys == c)
        }
    }

    @Test("长度不等但前缀相同的字符串按完整键定序")
    func prefixTieFallsBackToFullKeyBeforeLength() {
        // All three share the same first 8 bytes, so the prefilter ties and the
        // *next byte* must decide. Ranking by length would give 1, 2, 3; byte
        // order gives 3, 1, 2 because ' ' (0x20) < '1' (0x31) < '2' (0x32).
        let entries = [
            entry("v", 3, "abcdefgh longer.txt"),
            entry("v", 1, "abcdefgh1.txt"),
            entry("v", 2, "abcdefgh2.txt"),
        ]
        let subject = engine(entries)
        var query = SearchQuery(text: "abcdefgh", sort: .name, ascending: true)
        #expect(subject.search(query).keys == [
            EntryKey(volumeID: "v", nodeID: 3),  // "abcdefgh longer.txt"
            EntryKey(volumeID: "v", nodeID: 1),  // "abcdefgh1.txt"
            EntryKey(volumeID: "v", nodeID: 2),  // "abcdefgh2.txt"
        ])

        // Broad and narrow queries must agree on the same ordering.
        query.text = ""
        #expect(subject.search(query).keys == [
            EntryKey(volumeID: "v", nodeID: 3),
            EntryKey(volumeID: "v", nodeID: 1),
            EntryKey(volumeID: "v", nodeID: 2),
        ], "宽查询与窄查询必须给出同一顺序")
    }

    @Test("大小写不同的同前缀名称按折叠键定序")
    func foldedKeyDrivesCaseInsensitiveOrdering() {
        // Ordering uses the folded (case-folded) key, so 'X' is compared as 'x'.
        // 'i' (0x69) < 'x' (0x78), so the longer "…ghi" name comes first.
        let entries = [
            entry("v", 1, "abcdefgh.txt"),
            entry("v", 2, "abcdefghX.txt"),
            entry("v", 3, "abcdefghi.txt"),
        ]
        let subject = engine(entries)
        var query = SearchQuery(text: "abcdefgh", sort: .name, ascending: true)
        #expect(subject.search(query).keys == [
            EntryKey(volumeID: "v", nodeID: 1),
            EntryKey(volumeID: "v", nodeID: 3),
            EntryKey(volumeID: "v", nodeID: 2),
        ])
        query.text = ""
        let broad = subject.search(query).keys
        let narrow = subject.search(SearchQuery(text: "abcdefgh", sort: .name, ascending: true)).keys
        #expect(broad == narrow, "宽查询与窄查询必须给出同一顺序")
    }

    @Test("长短混合名称按字节字典序，不受前缀键长度影响")
    func shortAndLongNamesKeepByteOrder() {
        // "b" (1 byte) must sort after "aa" (2 bytes): a prefix packer that forgets
        // to right-pad zero bytes compares 0x62 against 0x6161 and gets this wrong.
        let names = ["a", "aa", "ab", "b", "c", "za", "zz"]
        let entries = names.enumerated().map { entry("v", Int64($0.offset + 1), $0.element) }
        let subject = engine(entries)
        var ascending = SearchQuery(sort: .name, ascending: true)
        #expect(subject.search(ascending).keys == entries.map(\.key))

        ascending = SearchQuery(sort: .name, ascending: false)
        #expect(subject.search(ascending).keys == entries.reversed().map(\.key))
    }

    @Test("文件大小排序保留 Int64 精度")
    func sizeSortKeepsInt64Precision() {
        // 2^53 + 1 and 2^53 are distinct Int64 values but collapse to the same Double.
        let big: Int64 = 9_007_199_254_740_993      // 2^53 + 1
        let small: Int64 = 9_007_199_254_740_992    // 2^53
        let entries = [
            entry("v", 1, "large.txt", size: big),
            entry("v", 2, "small.txt", size: small),
            entry("v", 3, "negative.txt", size: -5),
            entry("v", 4, "zero.txt", size: 0),
        ]
        let subject = engine(entries)
        let keys = subject.search(SearchQuery(sort: .size, ascending: true)).keys
        #expect(keys == [
            EntryKey(volumeID: "v", nodeID: 3),  // -5
            EntryKey(volumeID: "v", nodeID: 4),  // 0
            EntryKey(volumeID: "v", nodeID: 2),  // 2^53
            EntryKey(volumeID: "v", nodeID: 1),  // 2^53 + 1
        ])
    }
}