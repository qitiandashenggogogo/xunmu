import Foundation
import SearchCore
import Testing
@testable import SearchIndex

/// Regression cover for the two places where the total order used to leak input
/// order, both found by `SearchEngineAcceptanceTests.orderingIsStrictTotalOrderWithKeyTiebreaker`:
///
/// 1. **Narrow queries** (hits ≤ `max(64, records.count / 20)`) sort on the fly. When
///    two keys were byte-identical *and* the same length, the comparator returned
///    `.orderedDescending` instead of `.orderedSame`, so every pair of same-key entries
///    compared as "greater", the `(volumeID, nodeID)` tiebreaker never ran, and the
///    ascending result was whatever the sort algorithm left behind.
/// 2. **Broad queries** (hits above that threshold) filter the precomputed order built
///    in `init`. That comparator only consulted `volumeID` when the two node IDs
///    differed — and node IDs restart at 1 in every volume's own SQLite file, so a
///    cross-volume tie fell through to input order.
///
/// The fixture is built to hit both paths and to fail loudly on either bug:
/// * group A / group B are byte-identical **and longer than 8 bytes** (so the
///   `memcmp` remainder branch is taken and returns 0), including a long Chinese name;
/// * group B reuses nodeID 4 in two different volumes, so only `volumeID` can order it;
/// * the input order is deliberately shuffled against the expected order, so a
///   comparator that silently falls back to "input order" cannot pass;
/// * the ascending / descending expectations are written out separately, because the
///   descending contract is "reverse the sort key only, `(volumeID, nodeID)` stays
///   ascending" — the two directions must NOT be plain mirrors of each other.
///
/// Byte order of the fixture keys (UTF-8, which is what the engine compares):
/// `adir…`/`aaa-…` < `mdir…`/`mmm-…` < `zdir…`/`zzz-…`.
@Suite("排序决胜：相同键必须回落到 EntryKey")
struct SortTiebreakerRegressionTests {
    private static let groupAName = "aaa-同名文件甲-超过八个字节.txt"
    private static let groupAPath = "adir/aaa-同名文件甲-超过八个字节.txt"
    private static let groupBName = "mmm-same-name-超过八个字节.txt"
    private static let groupBPath = "mdir/same-name-超过八个字节.txt"

    private static let expectedGroupA: [EntryKey] = [
        EntryKey(volumeID: "vol-external", nodeID: 3),
        EntryKey(volumeID: "vol-external", nodeID: 9),
        EntryKey(volumeID: "vol-internal", nodeID: 5),
        EntryKey(volumeID: "vol-internal", nodeID: 7),
    ]
    private static let expectedGroupB: [EntryKey] = [
        // Same nodeID, different volume: only `volumeID` can order this pair.
        EntryKey(volumeID: "vol-external", nodeID: 4),
        EntryKey(volumeID: "vol-internal", nodeID: 4),
    ]

    private func entry(_ volumeID: String, _ nodeID: Int64, _ name: String, _ path: String) -> IndexedEntry {
        IndexedEntry(
            key: EntryKey(volumeID: volumeID, nodeID: nodeID),
            relativePath: path,
            name: name,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
    }

    /// Shuffled on purpose: the expected orders below are *not* this order.
    private func makeEntries(fillerCount: Int) -> [IndexedEntry] {
        var values = [
            entry("vol-external", 9, Self.groupAName, Self.groupAPath),
            entry("vol-internal", 5, Self.groupAName, Self.groupAPath),
            entry("vol-external", 3, Self.groupAName, Self.groupAPath),
            entry("vol-internal", 4, Self.groupBName, Self.groupBPath),
            entry("vol-external", 4, Self.groupBName, Self.groupBPath),
            entry("vol-internal", 7, Self.groupAName, Self.groupAPath),
        ]
        for offset in 0..<fillerCount {
            let stem = String(format: "zzz-fill-%03d", offset)
            values.append(entry("vol-fill", Int64(offset + 1), stem + ".txt", "zdir/" + stem + ".txt"))
        }
        return values
    }

    private func expectations(fillerCount: Int) -> (ascending: [EntryKey], descending: [EntryKey]) {
        // Filler keys are already ascending by construction.
        let fillers = (0..<fillerCount).map { EntryKey(volumeID: "vol-fill", nodeID: Int64($0 + 1)) }
        return (
            ascending: Self.expectedGroupA + Self.expectedGroupB + fillers,
            // Primary key reversed; every tie group keeps ascending (volumeID, nodeID).
            descending: Array(fillers.reversed()) + Self.expectedGroupB + Self.expectedGroupA
        )
    }

    private func assertTieOrder(fillerCount: Int) throws {
        let engine = SearchEngine(
            snapshot: .init(generation: 1, entries: makeEntries(fillerCount: fillerCount), volumes: [])
        )
        #expect(engine.count == 6 + fillerCount)
        let expected = expectations(fillerCount: fillerCount)

        for sort in [SearchSort.name, SearchSort.path] {
            for ascending in [true, false] {
                let result = engine.search(.init(text: "", sort: sort, ascending: ascending))
                #expect(!result.isCancelled)
                let want = ascending ? expected.ascending : expected.descending
                #expect(
                    result.keys == want,
                    "相同键必须先回落到 (volumeID, nodeID) 升序决胜；降序只反转主键"
                )
                #expect(
                    Set(result.keys) == Set(want),
                    "排序不得丢条或重复"
                )
            }
        }
    }

    @Test("窄查询在相同键上回落到 EntryKey 决胜")
    func narrowQueryTiesFallBackToEntryKey() throws {
        // 9 hits ≤ max(64, 9 / 20) = 64 → the on-the-fly comparator, not the precomputed order.
        try assertTieOrder(fillerCount: 3)
    }

    @Test("宽查询走预排序时同样按 EntryKey 决胜")
    func broadQueryTiesFallBackToEntryKey() throws {
        // 73 hits > max(64, 73 / 20) = 64 → the precomputed order built in init.
        try assertTieOrder(fillerCount: 67)
    }
}