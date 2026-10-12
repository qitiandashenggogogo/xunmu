import Foundation
import Darwin
import SearchCore

/// Read-only, `Sendable` search over an immutable `CatalogSnapshot`.
///
/// The snapshot's normalized matching keys are precomputed once in `init`, so a
/// query only does substring comparisons — no per-query normalization.
///
/// The engine never truncates: a finished search returns **every** match. A
/// cancelled search returns no keys at all plus `isCancelled == true`, so a
/// caller can never mistake a partial answer for a complete one.
///
/// Ordering is a strict total order: the requested sort key (direction applied),
/// then `(volumeID, nodeID)` ascending as the final tiebreaker. That makes results
/// stable regardless of `Array.sort` stability, so selection/anchors survive.
/// Packs the first 8 UTF-8 bytes of `range` into a big-endian, **zero-padded** integer.
///
/// The bytes must land in the *high* end of the word. Packing them left-aligned
/// instead would compare `"b"` (0x62) against `"aa"` (0x6161) and wrongly call `"b"`
/// smaller, because a one-byte key would have no zero tail. With right padding,
/// `"b"` becomes 0x62_00000000000000 and `"aa"` becomes 0x6161_00000000000000, so
/// the integer order matches byte-lexicographic order for every length, and an empty
/// key packs to 0.
///
/// This is only ever a *prefilter*: an exact tie falls through to a full comparison.
@inline(__always)
private func packPrefix(_ base: UnsafePointer<UInt8>, _ range: Range<Int>) -> UInt64 {
    var packed: UInt64 = 0
    let count = min(8, range.count)
    var shift = 56
    for offset in 0..<count {
        packed |= UInt64(base[range.lowerBound + offset]) << UInt64(shift)
        shift -= 8
    }
    return packed
}

/// Compact sort candidate. See `sort(_:by:ascending:isCancelled:)`.
///
/// The three key slots exist because they have three different exactness
/// requirements: a name/path prefix is a full `UInt64` (rounding it to `Double`
/// would make distinct prefixes compare equal), a size is a full `Int64` (file
/// sizes above 2^53 are not representable as `Double`), and a timestamp is a
/// `Double`. Only the slot the active ordering uses is populated.
private struct SortCandidate {
    var prefixKey: UInt64 = 0
    var integerKey: Int64 = 0
    var timeKey: Double = 0
    var nodeID: Int64
    var index: Int32
}

/// Dense candidate for the two precomputed orderings built in `init`.
private struct OrderCandidate {
    var prefixKey: UInt64 = 0
    var length: Int32
    var lowerBound: Int32
    var nodeID: Int64
    var index: Int32
}

/// Maps a big-endian, zero-padded prefix onto a `Double` that preserves the integer
/// ordering. Only safe as a *candidate* filter: above 2^53 distinct prefixes collapse.
@inline(__always)
private func prefixOrderKey(_ prefix: UInt64) -> Double {
    Double(prefix) / 1_844_674_407_370_955_161_088.0  // 2^64
}

/// Read-only, `Sendable` search over an immutable `CatalogSnapshot`.
public struct SearchEngine: Sendable {
    struct Record: Sendable {
        var key: EntryKey
        var name: String
        var relativePath: String
        var nameKey: String
        var pathKey: String
        var canonicalPath: String
        var foldedNameBytes: Range<Int>
        var foldedPathBytes: Range<Int>
        var exactNameBytes: Range<Int>
        var exactPathBytes: Range<Int>
        var isDirectory: Bool
        var size: Int64
        var modifiedAt: Date
        /// First 8 UTF-8 bytes of the folded name, big-endian, zero-padded.
        ///
        /// Lets the two orderings resolve almost every comparison with a single
        /// integer compare instead of a `memcmp` call. Zero-padding makes the
        /// integer order agree with byte-lexicographic order: a shorter string
        /// that is a prefix of the longer one pads to a smaller value.
        var namePrefix: UInt64
        /// First 8 UTF-8 bytes of the folded path, same encoding as `namePrefix`.
        var pathPrefix: UInt64
    }

    private let generation: UInt64
    private let records: [Record]
    private let matchingBytes: [UInt8]
    private let nameOrder: [Int]
    private let pathOrder: [Int]

    public init(snapshot: CatalogSnapshot) {
        generation = snapshot.generation
        var built: [Record] = []
        var pool: [UInt8] = []
        pool.reserveCapacity(snapshot.entries.reduce(0) { $0 + $1.name.utf8.count + $1.relativePath.utf8.count })
        func append(_ text: String) -> Range<Int> {
            let start = pool.count
            pool.append(contentsOf: text.utf8)
            return start..<pool.count
        }
        built.reserveCapacity(snapshot.entries.count)
        // Dedup on the *whole* key. Each volume gets its own SQLite file with its own
        // AUTOINCREMENT counter starting at 1, so node numbers repeat across volumes
        // and a `Set<Int64>` would silently drop a different volume's file.
        var seen = Set<EntryKey>()
        for entry in snapshot.entries {
            guard seen.insert(entry.key).inserted else { continue }
            let nameKey = IndexText.foldedKey(entry.name)
            let pathKey = IndexText.foldedKey(entry.relativePath)
            let foldedNameBytes = append(nameKey)
            let foldedPathBytes = append(pathKey)
            let exactName = IndexText.canonicalKey(entry.name)
            let exactPath = IndexText.canonicalKey(entry.relativePath)
            let exactNameBytes = exactName == nameKey ? foldedNameBytes : append(exactName)
            let exactPathBytes = exactPath == pathKey ? foldedPathBytes : append(exactPath)
            built.append(
                Record(
                    key: entry.key,
                    name: entry.name,
                    relativePath: entry.relativePath,
                    nameKey: nameKey,
                    pathKey: pathKey,
                    canonicalPath: IndexText.canonicalRelativePath(entry.relativePath),
                    foldedNameBytes: foldedNameBytes, foldedPathBytes: foldedPathBytes,
                    exactNameBytes: exactNameBytes, exactPathBytes: exactPathBytes,
                    isDirectory: entry.isDirectory,
                    size: entry.size,
                    modifiedAt: entry.modifiedAt,
                    namePrefix: 0, pathPrefix: 0
                )
            )
        }
        // Prefix keys are read from the finished pool, so they must be packed after
        // `pool` stops growing and before the array is published as immutable.
        pool.withUnsafeBufferPointer { bytes in
            let base = bytes.baseAddress!
            for offset in built.indices {
                let record = built[offset]
                built[offset].namePrefix = packPrefix(base, record.foldedNameBytes)
                built[offset].pathPrefix = packPrefix(base, record.foldedPathBytes)
            }
        }
        records = built
        matchingBytes = pool
        // Publish ordered sequences with the immutable snapshot. Broad queries
        // filter these sequences instead of sorting hundreds of thousands of hits.
        //
        // Both orderings are built once, at init, over the *whole* index — so they
        // are worth sorting densely. Sorting an `[Int]` permutation would make each
        // of the ~n log n comparisons dereference a ~130-byte `Record` at a random
        // offset, which is what made this the single most expensive phase of
        // `SearchEngine.init`. The dense candidate keeps the comparison keys
        // contiguous; the original index rides along so nothing else changes.
        func ordered(_ byName: Bool) -> [Int] {
            var candidates: [OrderCandidate] = []
            candidates.reserveCapacity(built.count)
            for offset in built.indices {
                let record = built[offset]
                let range = byName ? record.foldedNameBytes : record.foldedPathBytes
                candidates.append(
                    OrderCandidate(
                        prefixKey: byName ? record.namePrefix : record.pathPrefix,
                        length: Int32(range.count),
                        lowerBound: Int32(range.lowerBound),
                        nodeID: record.key.nodeID,
                        index: Int32(offset)
                    )
                )
            }
            return pool.withUnsafeBufferPointer { bytes in
                let base = bytes.baseAddress!
                candidates.sort { left, right in
                    if left.prefixKey != right.prefixKey { return left.prefixKey < right.prefixKey }
                    // Equal first 8 bytes: the 9th byte decides before length does.
                    // Comparing length first would rank "abcdefghay" after
                    // "abcdefghz", which contradicts the full key order.
                    let length = min(Int(left.length), Int(right.length))
                    if length > 8 {
                        let comparison = memcmp(
                            base + Int(left.lowerBound) + 8,
                            base + Int(right.lowerBound) + 8,
                            length - 8
                        )
                        if comparison != 0 { return comparison < 0 }
                    }
                    if left.length != right.length { return left.length < right.length }
                    // Byte-identical keys: ALWAYS volumeID then nodeID. Gating the
                    // volume compare on `nodeID != nodeID` was wrong — every volume
                    // has its own SQLite file whose AUTOINCREMENT restarts at 1, so
                    // two volumes routinely hand out the *same* nodeID. That pair
                    // must still be ordered by volume; skipping it made the group
                    // fall through to input order, which is exactly what makes the
                    // result depend on the array's prior arrangement.
                    let a = built[Int(left.index)].key.volumeID
                    let b = built[Int(right.index)].key.volumeID
                    if a != b { return a < b }
                    if left.nodeID != right.nodeID { return left.nodeID < right.nodeID }
                    return left.index < right.index
                }
                return candidates.map { Int($0.index) }
            }
        }
        nameOrder = ordered(true)
        pathOrder = ordered(false)
    }

    /// Number of indexed entries this engine can match against.
    public var count: Int { records.count }

    /// Generation of the snapshot this engine was built from; echoed on every result.
    public var snapshotGeneration: UInt64 { generation }

    /// Reconstructs the entries this engine was built from (paths/names are the
    /// original bytes, never the normalized keys).
    var snapshotEntries: [IndexedEntry] {
        records.map { record in
            IndexedEntry(
                key: record.key,
                relativePath: record.relativePath,
                name: record.name,
                isDirectory: record.isDirectory,
                isSymbolicLink: false,
                size: record.size,
                modifiedAt: record.modifiedAt
            )
        }
    }

    public func search(
        _ query: SearchQuery,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> SearchResult {
        if isCancelled() {
            return SearchResult(generation: generation, keys: [], isCancelled: true)
        }

        let parsed = QueryParser.parse(query.text, caseSensitive: query.caseSensitive)
        let scope = ScopeFilter(query.scope)
        let terms = ByteTerms(parsed)
        let extensions = Set(
            query.extensions.compactMap(IndexText.normalizeExtensionFilter)
        ).union(parsed.extensions)

        let size = SizePredicate.range(
            minInclusive: tighterLowerBound(query.minSize, parsed.sizePredicate?.minValue),
            maxInclusive: tighterUpperBound(query.maxSize, parsed.sizePredicate?.maxValue)
        )
        let date = DatePredicate.range(
            after: tighterLowerBound(query.modifiedAfter, parsed.datePredicate?.afterValue),
            before: tighterUpperBound(query.modifiedBefore, parsed.datePredicate?.beforeValue)
        )

        var matches: [Int] = []
        matches.reserveCapacity(min(records.count, 1024))

        let completed = matchingBytes.withUnsafeBufferPointer { pool in
            var index = 0
            while index < records.count {
                if index % 2048 == 0, isCancelled() { return false }
                let record = records[index]
                if self.matches(record, parsed: parsed, scope: scope, extensions: extensions,
                                size: size, date: date, foldersOnly: query.foldersOnly,
                                caseSensitive: query.caseSensitive, terms: terms, pool: pool) {
                    matches.append(index)
                }
                index += 1
            }
            return true
        }
        if !completed { return SearchResult(generation: generation, keys: [], isCancelled: true) }

        if isCancelled() {
            return SearchResult(generation: generation, keys: [], isCancelled: true)
        }

        do {
            try sort(&matches, by: query.sort, ascending: query.ascending, isCancelled: isCancelled)
        } catch {
            // Only SearchCancelledError escapes the comparator today, but a bare
            // `catch` keeps this total: a cancelled query must never surface as a
            // thrown error, and a future comparator must not turn one into a crash.
            return SearchResult(generation: generation, keys: [], isCancelled: true)
        }

        if isCancelled() {
            return SearchResult(generation: generation, keys: [], isCancelled: true)
        }

        return SearchResult(
            generation: generation,
            keys: matches.map { records[$0].key },
            isCancelled: false
        )
    }

    // MARK: - Filtering

    private func matches(
        _ record: Record,
        parsed: ParsedQuery,
        scope: ScopeFilter,
        extensions: Set<String>,
        size: SizePredicate,
        date: DatePredicate,
        foldersOnly: Bool,
        caseSensitive: Bool,
        terms: ByteTerms,
        pool: UnsafeBufferPointer<UInt8>
    ) -> Bool {
        guard scope.contains(record) else { return false }
        if foldersOnly, !record.isDirectory { return false }

        if !extensions.isEmpty {
            guard let ext = IndexText.lowercaseExtension(of: record.name), extensions.contains(ext) else {
                return false
            }
        }
        guard size.matches(record.size) else { return false }
        guard date.matches(record.modifiedAt) else { return false }

        let nameRange = caseSensitive ? record.exactNameBytes : record.foldedNameBytes
        let pathRange = caseSensitive ? record.exactPathBytes : record.foldedPathBytes
        for term in terms.include where !byteContains(pool, range: pathRange, term: term) && !byteContains(pool, range: nameRange, term: term) { return false }
        for term in terms.name where !byteContains(pool, range: nameRange, term: term) { return false }
        for term in terms.path where !byteContains(pool, range: pathRange, term: term) { return false }
        for term in terms.exclude where byteContains(pool, range: pathRange, term: term) || byteContains(pool, range: nameRange, term: term) { return false }
        for term in terms.excludedName where byteContains(pool, range: nameRange, term: term) { return false }
        for term in terms.excludedPath where byteContains(pool, range: pathRange, term: term) { return false }
        return true
    }

    // MARK: - Ordering

    private func sort(
        _ indices: inout [Int],
        by sort: SearchSort,
        ascending: Bool,
        isCancelled: @Sendable () -> Bool
    ) throws {
        let records = self.records
        if (sort == .name || sort == .path), indices.count > max(64, records.count / 20) {
            let order = sort == .name ? nameOrder : pathOrder
            var included = [Bool](repeating: false, count: records.count)
            for (offset, index) in indices.enumerated() {
                if offset % 2048 == 0, isCancelled() { throw SearchCancelledError() }
                included[index] = true
            }
            var ordered: [Int] = []
            ordered.reserveCapacity(indices.count)
            if ascending {
                for (offset, index) in order.enumerated() {
                    if offset % 2048 == 0, isCancelled() { throw SearchCancelledError() }
                    if included[index] { ordered.append(index) }
                }
            } else {
                // Reverse primary groups, retaining the ascending stable-ID
                // tiebreaker within each group, including descending queries.
                var end = order.count
                while end > 0 {
                    if isCancelled() { throw SearchCancelledError() }
                    let last = records[order[end - 1]]
                    let value = sort == .name ? last.nameKey : last.pathKey
                    var start = end - 1
                    while start > 0 {
                        if start % 2048 == 0, isCancelled() { throw SearchCancelledError() }
                        let candidate = records[order[start - 1]]
                        if (sort == .name ? candidate.nameKey : candidate.pathKey) != value { break }
                        start -= 1
                    }
                    for offset in start..<end {
                        if offset % 2048 == 0, isCancelled() { throw SearchCancelledError() }
                        if included[order[offset]] { ordered.append(order[offset]) }
                    }
                    end = start
                }
            }
            indices = ordered
            return
        }
        var comparisonsSinceCheck = 0
        // Size and date have no precomputed order (their values are metadata, not part
        // of the name/path bytes), so they always land here — and those two were the
        // expensive orderings on a million-row catalog. Copying the comparison keys
        // into a dense array avoids chasing indices into the ~130-byte `records`
        // array on every one of the ~20M comparisons.
        var candidates: [SortCandidate] = []
        candidates.reserveCapacity(indices.count)
        let byName = sort == .name
        for index in indices {
            let record = records[index]
            switch sort {
            case .size:
                // Int64, never Double: file sizes above 2^53 are exactly representable
                // as Int64 and would collide as Doubles.
                candidates.append(SortCandidate(integerKey: record.size, nodeID: record.key.nodeID, index: Int32(index)))
            case .modified:
                candidates.append(SortCandidate(timeKey: record.modifiedAt.timeIntervalSinceReferenceDate, nodeID: record.key.nodeID, index: Int32(index)))
            case .name:
                candidates.append(SortCandidate(prefixKey: record.namePrefix, nodeID: record.key.nodeID, index: Int32(index)))
            case .path:
                candidates.append(SortCandidate(prefixKey: record.pathPrefix, nodeID: record.key.nodeID, index: Int32(index)))
            }
        }
        // The name/path fallback needs the byte pool to compare keys past 8 bytes.
        _ = try matchingBytes.withUnsafeBufferPointer { bytes -> Void in
            let base = bytes.baseAddress!
            try candidates.sort { left, right in
            // Cancellation must also fire *during* the sort: a million-entry sort
            // is the longest phase, so a query cannot be abandoned mid-sort.
            comparisonsSinceCheck += 1
            if comparisonsSinceCheck % 4096 == 0, isCancelled() {
                throw SearchCancelledError()
            }
            let ordering: ComparisonResult
            let usesPrefix = sort == .name || sort == .path
            if usesPrefix {
                if left.prefixKey != right.prefixKey {
                    ordering = left.prefixKey < right.prefixKey ? .orderedAscending : .orderedDescending
                } else {
                    // Equal 8-byte prefix: compare the remainder of the bytes *before*
                    // falling back to length. Ranking "abcdefghay" after "abcdefghz"
                    // because it is longer contradicts the full-key order.
                    let a = records[Int(left.index)], b = records[Int(right.index)]
                    let ar = byName ? a.foldedNameBytes : a.foldedPathBytes
                    let br = byName ? b.foldedNameBytes : b.foldedPathBytes
                    let common = min(ar.count, br.count)
                    if common > 8 {
                        let comparison = memcmp(
                            base + ar.lowerBound + 8,
                            base + br.lowerBound + 8,
                            common - 8
                        )
                        if comparison != 0 {
                            ordering = comparison < 0 ? .orderedAscending : .orderedDescending
                        } else if ar.count != br.count {
                            // Identical bytes up to the shorter length: shorter first.
                            ordering = ar.count < br.count ? .orderedAscending : .orderedDescending
                        } else {
                            // Identical key bytes AND identical length is a *tie*, not
                            // a descent. Returning Desc here (which is what
                            // `count < count ? Asc : Desc` degenerated into) made every
                            // pair of same-key entries compare as "greater", so an
                            // ascending query handed the whole group to whatever order
                            // the sort algorithm happened to produce, and the
                            // `(volumeID, nodeID)` tiebreaker below never ran.
                            ordering = .orderedSame
                        }
                    } else if ar.count != br.count {
                        ordering = ar.count < br.count ? .orderedAscending : .orderedDescending
                    } else {
                        // Identical key bytes: let the tiebreaker decide.
                        ordering = .orderedSame
                    }
                }
            } else if sort == .size {
                if left.integerKey != right.integerKey {
                    ordering = left.integerKey < right.integerKey ? .orderedAscending : .orderedDescending
                } else {
                    ordering = .orderedSame
                }
            } else {
                if left.timeKey != right.timeKey {
                    ordering = left.timeKey < right.timeKey ? .orderedAscending : .orderedDescending
                } else {
                    ordering = .orderedSame
                }
            }
            if ordering != .orderedSame {
                // Direction applies to the sort key only.
                return ascending ? ordering == .orderedAscending : ordering == .orderedDescending
            }
            // Total-order tiebreaker: always ascending, never reversed, so paging
            // stays consistent in both directions.
            let a = records[Int(left.index)]
            let b = records[Int(right.index)]
            if a.key.volumeID != b.key.volumeID { return a.key.volumeID < b.key.volumeID }
            return left.nodeID < right.nodeID
            }
        }
        indices = candidates.map { Int($0.index) }
    }
}

// MARK: - Predicate helpers

/// Merges two optional bounds into the more restrictive one. Written by hand
/// rather than with `max`/`min`: those read poorly on optionals (`max(nil, x)`
/// silently means "x") and the intent here is worth spelling out.
private func tighterLowerBound<T: Comparable>(_ a: T?, _ b: T?) -> T? {
    switch (a, b) {
    case (nil, nil): return nil
    case (let value?, nil): return value
    case (nil, let value?): return value
    case (let x?, let y?): return x > y ? x : y
    }
}

private func tighterUpperBound<T: Comparable>(_ a: T?, _ b: T?) -> T? {
    switch (a, b) {
    case (nil, nil): return nil
    case (let value?, nil): return value
    case (nil, let value?): return value
    case (let x?, let y?): return x < y ? x : y
    }
}

/// Thrown out of the sort comparator; never escapes `search`.
struct SearchCancelledError: Error {}

extension SizePredicate {
    var minValue: Int64? {
        if case .range(let low, _) = self { return low }
        return nil
    }
    var maxValue: Int64? {
        if case .range(_, let high) = self { return high }
        return nil
    }
}

extension DatePredicate {
    var afterValue: Date? {
        if case .range(let after, _) = self { return after }
        return nil
    }
    var beforeValue: Date? {
        if case .range(_, let before) = self { return before }
        return nil
    }
}

/// Resolves `SearchScope` against a record without any string-prefix ambiguity.
private struct ScopeFilter: Sendable {
    private enum Kind: Sendable {
        case all
        case volume(String)
        case directory(volumeID: String, prefix: String, recursive: Bool)
    }

    private let kind: Kind

    init(_ scope: SearchScope) {
        switch scope {
        case .all:
            kind = .all
        case .volume(let id):
            kind = .volume(id)
        case .directory(let volumeID, let relativePath, let recursive):
            let canonical = IndexText.canonicalRelativePath(relativePath)
            kind = .directory(
                volumeID: volumeID,
                prefix: canonical.isEmpty ? "" : canonical + "/",
                recursive: recursive
            )
        }
    }

    func contains(_ record: SearchEngine.Record) -> Bool {
        switch kind {
        case .all:
            return true
        case .volume(let id):
            return record.key.volumeID == id
        case .directory(let volumeID, let prefix, let recursive):
            guard record.key.volumeID == volumeID else { return false }
            if prefix.isEmpty {
                // Root: recursive covers the whole volume, non-recursive is direct children only.
                if recursive { return true }
                return !record.canonicalPath.contains("/")
            }
            guard record.canonicalPath.hasPrefix(prefix) else { return false }
            if recursive { return true }
            let remainder = record.canonicalPath.dropFirst(prefix.count)
            return !remainder.contains("/")
        }
    }
}

private struct ByteTerms {
    let include, name, path, exclude, excludedName, excludedPath: [[UInt8]]
    init(_ parsed: ParsedQuery) {
        include = parsed.includeTerms.map { Array($0.utf8) }
        name = parsed.nameTerms.map { Array($0.utf8) }
        path = parsed.pathTerms.map { Array($0.utf8) }
        exclude = parsed.excludeTerms.map { Array($0.utf8) }
        excludedName = parsed.excludedNameTerms.map { Array($0.utf8) }
        excludedPath = parsed.excludedPathTerms.map { Array($0.utf8) }
    }
}

/// Both sides were NFC normalized before encoding. Byte matching preserves
/// Unicode scalar substrings while avoiding repeated Foundation string bridging.
@inline(__always)
private func byteContains(_ pool: UnsafeBufferPointer<UInt8>, range: Range<Int>, term: [UInt8]) -> Bool {
    if term.isEmpty { return true }
    guard term.count <= range.count, let base = pool.baseAddress else { return false }
    return term.withUnsafeBufferPointer { needle in
        let lastStart = range.upperBound - needle.count
        var cursor = range.lowerBound
        while cursor <= lastStart {
            guard let found = memchr(base + cursor, Int32(needle[0]), lastStart - cursor + 1) else { return false }
            let position = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
            if needle.count == 1 || memcmp(base + position, needle.baseAddress!, needle.count) == 0 { return true }
            cursor = position + 1
        }
        return false
    }
}
