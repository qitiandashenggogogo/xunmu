import Foundation
import SearchCore
import Testing
@testable import SearchIndex

@Suite("主控回归：状态与筛选")
struct LeadRegressionTests {
    @Test func nameScopeDoesNotMatchOnlyParent() {
        let e = SearchEngine(snapshot: CatalogSnapshot(generation: 1, entries: [IndexedEntry(key: EntryKey(volumeID: "v", nodeID: 1), relativePath: "报告/notes.txt", name: "notes.txt")], volumes: []))
        #expect(e.search(SearchQuery(text: "报告")).keys.count == 1)
        #expect(e.search(SearchQuery(text: "name:报告")).keys.isEmpty)
        #expect(e.search(SearchQuery(text: "notes -path:报告")).keys.isEmpty)
    }
    @Test func strictSizeBoundsAndOverflow() {
        #expect(QueryParser.parseSize(">100")?.min == 101)
        #expect(QueryParser.parseSize("<100")?.max == 99)
        #expect(QueryParser.parseSize("999999999999999999999999gb") == nil)
        #expect(QueryParser.parseSize("1unknown") == nil)
        let p = QueryParser.parse("size:>100 size:<200")
        #expect(p.sizePredicate?.minValue == 101)
        #expect(p.sizePredicate?.maxValue == 199)
    }
    @Test func partialWithoutIssueRemainsStale() async throws {
        let f = try TempCatalogFixture(); defer { f.remove() }
        let s = try f.makeStore(); let v = makeVolume()
        try await s.registerVolume(v)
        try await s.apply(DirectoryBatch(volumeID: v.id, directoryRelativePath: "", entries: [makeEntry("docs", isDirectory: true)], isComplete: true))
        try await s.apply(DirectoryBatch(volumeID: v.id, directoryRelativePath: "docs", entries: [], isComplete: false))
        #expect(try await s.entries().first?.state == .stale)
    }
    @Test func offlineChangeInvalidatesGeneration() async throws {
        let f = try TempCatalogFixture(); defer { f.remove() }
        let s = try f.makeStore(); var v = makeVolume()
        try await s.registerVolume(v); let g = try await s.generation()
        try await s.registerVolume(v); #expect(try await s.generation() == g)
        v.isOnline = false; try await s.registerVolume(v)
        #expect(try await s.generation() == g + 1)
    }
    @Test func provenFolderRenameKeepsDescendantIDs() async throws {
        let f = try TempCatalogFixture(); defer { f.remove() }
        let s = try f.makeStore(); let v = makeVolume()
        try await s.registerVolume(v)
        let old = ScannedEntry(relativePath: "old", name: "old", isDirectory: true, fileID: 50)
        try await s.apply(DirectoryBatch(volumeID: v.id, directoryRelativePath: "", entries: [old], isComplete: true))
        try await s.apply(DirectoryBatch(volumeID: v.id, directoryRelativePath: "old", entries: [makeEntry("old/a.txt")], isComplete: true))
        let before = try await s.entries()
        let new = ScannedEntry(relativePath: "new", name: "new", isDirectory: true, fileID: 50)
        try await s.apply(DirectoryBatch(volumeID: v.id, directoryRelativePath: "", entries: [new], isComplete: true))
        let after = try await s.entries()
        let afterIDs = after.map(\.key).sorted { $0.nodeID < $1.nodeID }
        let beforeIDs = before.map(\.key).sorted { $0.nodeID < $1.nodeID }
        #expect(afterIDs == beforeIDs)
        #expect(after.map(\.relativePath).sorted() == ["new", "new/a.txt"])
    }
}
