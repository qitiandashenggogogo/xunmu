import Foundation
import SearchCore
import Testing
@testable import SearchIndex

/// Opt-in benchmark harness. **Disabled unless an environment variable is set**, so
/// it never slows down or perturbs the normal test run.
///
/// ```
/// ME_INDEX_BENCH=1 swift test --filter IndexBench
/// ME_INDEX_BENCH=1 ME_INDEX_BENCH_DB=/abs/path/catalog.sqlite swift test --filter IndexBench
/// ```
///
/// When `ME_INDEX_BENCH_DB` is given it is opened **strictly read-only** via
/// `CatalogReader`; the legacy buffered decode is measured on the same connection so
/// the two numbers are directly comparable on identical data.
///
/// Memory ceiling: it measures an existing catalog, it never copies or duplicates
/// it on disk.
@Suite("索引性能基准（需 ME_INDEX_BENCH=1）")
struct IndexBench {
    @Test("重开加载与查询基准")
    func reopenAndQueryBench() throws {
        guard ProcessInfo.processInfo.environment["ME_INDEX_BENCH"] == "1" else { return }

        let environment = ProcessInfo.processInfo.environment
        var report: [String: String] = [:]

        if let path = environment["ME_INDEX_BENCH_DB"], !path.isEmpty {
            try benchDatabase(URL(fileURLWithPath: path), into: &report)
        } else {
            let count = Int(environment["ME_INDEX_BENCH_ENTRIES"] ?? "") ?? 200_000
            try benchSynthetic(count: count, into: &report)
        }

        let json = report.keys.sorted().map { "\"\($0)\": \"\(report[$0]!)\"" }
            .joined(separator: ",\n  ")
        print("\n=== INDEX BENCH ===\n{\n  \(json)\n}\n=== END ===")
    }

    // MARK: - Real database (read-only)

    private func benchDatabase(_ url: URL, into report: inout [String: String]) throws {
        // Warm the OS page cache so the numbers are CPU/decode bound, not a
        // one-off cold read from the external volume.
        let reader = try CatalogReader(databaseURL: url)
        report["db_rowCount"] = String(try reader.entryCount())
        _ = try reader.generation()

        // --- Legacy buffered decode: the implementation this replaces. ---
        // Materializes one [SQLiteValue] per column (~10 per row) before compactMap.
        let legacyStart = DispatchTime.now().uptimeNanoseconds
        var legacyCount = 0
        do {
            let legacyDB = try SQLiteConnection(url: url, access: .readOnly)
            try legacyDB.forEachRow(
                CatalogStore.entryColumns + " ORDER BY volume_id, relative_path;"
            ) { row in
                // Same shape the old path paid for: one boxed value per column.
                _ = [
                    SQLiteValue.integer(row.int64(0)),
                    .text(row.string(1)),
                    .text(row.string(2)),
                    .text(row.string(3)),
                    .integer(row.int64(4)),
                    .integer(row.int64(5)),
                    .integer(row.int64(6)),
                    .real(row.double(7)),
                    row.isNull(8) ? SQLiteValue.null : .integer(row.int64(8)),
                    .integer(row.int64(9)),
                ]
                legacyCount += 1
            }
        }
        report["db_legacy_bufferedDecodeMs"] = ms(since: legacyStart)
        report["db_legacy_rows"] = String(legacyCount)

        // --- New streaming decode + no redundant ORDER BY. ---
        let streamStart = DispatchTime.now().uptimeNanoseconds
        let entries = try reader.entries()
        report["db_streamingDecodeMs"] = ms(since: streamStart)
        report["db_rows"] = String(entries.count)

        // --- Same load, but keeping the old ORDER BY (isolates the plan change). ---
        let orderedStart = DispatchTime.now().uptimeNanoseconds
        var orderedCount = 0
        do {
            let orderedDB = try SQLiteConnection(url: url, access: .readOnly)
            try orderedDB.forEachRow(
                CatalogStore.entryColumns + " ORDER BY volume_id, relative_path;"
            ) { _ in orderedCount += 1 }
        }
        report["db_streaming_withOrderByMs"] = ms(since: orderedStart)
        report["db_streaming_withOrderBy_rows"] = String(orderedCount)

        let snapshot = CatalogSnapshot(
            generation: try reader.generation(),
            entries: entries,
            volumes: try reader.volumes()
        )
        try benchEngine(snapshot: snapshot, into: &report, prefix: "db_")
    }

    // MARK: - Synthetic (no disk cost)

    private func benchSynthetic(count: Int, into report: inout [String: String]) throws {
        var entries: [IndexedEntry] = []
        entries.reserveCapacity(count)
        let words = ["报告", "photo", "IMG", "预算", "doc", "视频", "x"]
        for index in 0..<count {
            let folder = index % 97
            let leaf = words[index % words.count]
            let relativePath = "dir\(folder)/\(leaf)-\(index).\(index % 3 == 0 ? "pdf" : "txt")"
            entries.append(
                IndexedEntry(
                    key: EntryKey(volumeID: "synthetic", nodeID: Int64(index + 1)),
                    relativePath: relativePath,
                    name: (relativePath as NSString).lastPathComponent,
                    isDirectory: index % 11 == 0,
                    size: Int64(index % 1_000_000),
                    modifiedAt: Date(timeIntervalSinceReferenceDate: Double(index % 5_000_000))
                )
            )
        }
        let snapshot = CatalogSnapshot(generation: 1, entries: entries, volumes: [makeVolume()])
        try benchEngine(snapshot: snapshot, into: &report, prefix: "syn_")
    }

    // MARK: - Engine

    private func benchEngine(
        snapshot: CatalogSnapshot,
        into report: inout [String: String],
        prefix: String
    ) throws {
        report["\(prefix)entries"] = String(snapshot.entries.count)

        let initStart = DispatchTime.now().uptimeNanoseconds
        let engine = SearchEngine(snapshot: snapshot)
        report["\(prefix)engineInitMs"] = ms(since: initStart)

        // Distinct query shapes: narrow substring, wide substring, no text at all,
        // plus each sort mode, because sorting is where the second O(N log N) lives.
        let narrow = SearchQuery(text: "报告", sort: .name, ascending: true)
        let wide = SearchQuery(text: "e", sort: .name, ascending: true)
        let everything = SearchQuery(text: "", sort: .name, ascending: true)

        report["\(prefix)search_narrowMs"] = repeated(5) { engine.search(narrow).keys.count }
        report["\(prefix)search_wideMs"] = repeated(3) { engine.search(wide).keys.count }
        report["\(prefix)search_allMs"] = repeated(3) { engine.search(everything).keys.count }

        var byPath = everything
        byPath.sort = .path
        report["\(prefix)search_allByPathMs"] = repeated(3) { engine.search(byPath).keys.count }

        var bySize = everything
        bySize.sort = .size
        report["\(prefix)search_allBySizeMs"] = repeated(3) { engine.search(bySize).keys.count }
    }

    // MARK: - Helpers

    private func repeated(_ times: Int, _ body: () -> Int) -> String {
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<times {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = body()
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return String(format: "%.2f", best)
    }

    private func ms(since start: UInt64) -> String {
        String(format: "%.2f", Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
}