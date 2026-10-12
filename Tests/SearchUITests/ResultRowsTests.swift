import Foundation
import Testing
@testable import SearchUI
import SearchCore

/// 行数据构建与显示文本测试（纯逻辑，无 GUI，不依赖 AppKit 窗口）。
@Suite("结果行数据")
struct ResultRowsTests {

    private let utc = TimeZone(identifier: "UTC")!

    private func volume(id: String = "v1", online: Bool = true, uuid: String? = "UUID-V1") -> VolumeRecord {
        VolumeRecord(
            id: id,
            name: id == "v1" ? "本地盘" : "移动盘",
            rootPath: "/fixtures/\(id)",
            volumeUUID: uuid,
            isOnline: online
        )
    }

    private func entry(
        id: Int64,
        volumeID: String = "v1",
        name: String,
        isDirectory: Bool = false,
        size: Int64 = 0,
        relativePath: String? = nil,
        state: EntryState = .current,
        fileID: UInt64? = nil
    ) -> IndexedEntry {
        IndexedEntry(
            key: EntryKey(volumeID: volumeID, nodeID: id),
            relativePath: relativePath ?? "目录/\(name)",
            name: name,
            isDirectory: isDirectory,
            size: size,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fileID: fileID,
            state: state
        )
    }

    private func store(
        entries: [IndexedEntry],
        keys: [EntryKey],
        volumes: [VolumeRecord]? = nil,
        generation: UInt64 = 3,
        keyIndexBuildLimit: Int = 200_000
    ) -> ResultRowStore {
        ResultRowStore(
            snapshot: CatalogSnapshot(generation: generation, entries: entries, volumes: volumes ?? [volume()]),
            keys: keys,
            keyIndexBuildLimit: keyIndexBuildLimit
        )
    }

    private func row(_ store: ResultRowStore, _ index: Int) -> ResultRow? {
        store.row(at: index, timeZone: utc)
    }

    // MARK: - 显示文本

    @Test("尺寸文本", arguments: [(Int64, String)]([
        (0, "0 B"), (512, "512 B"), (1024, "1.0 KB"), (1536, "1.5 KB"),
        (1 << 20, "1.0 MB"), (3 * (1 << 30), "3.0 GB"),
    ]))
    func sizeFormatting(input: Int64, expected: String) {
        #expect(DisplayText.size(input) == expected)
    }

    @Test("目录尺寸显示为破折号")
    func directorySizeIsDash() {
        #expect(DisplayText.size(1024, isDirectory: true) == DisplayText.emptyMarker)
        #expect(DisplayText.size(1024, isDirectory: false) == "1.0 KB")
    }

    @Test("日期格式固定时区可复现")
    func dateFormattingIsDeterministic() {
        #expect(DisplayText.date(Date(timeIntervalSince1970: 0), timeZone: utc) == "1970-01-01 00:00")
        #expect(DisplayText.defaultLocale.identifier == "zh_CN")
    }

    // MARK: - 按需行构建

    @Test("计数等于结果键数")
    func countIsResultKeyCount() {
        let entries = [entry(id: 1, name: "一.txt"), entry(id: 2, name: "二.txt")]
        let keys = [EntryKey(volumeID: "v1", nodeID: 2), EntryKey(volumeID: "v1", nodeID: 1)]
        let store = store(entries: entries, keys: keys)
        #expect(store.count == 2)
        #expect(store.generation == 3)
    }

    @Test("行顺序跟随结果键顺序")
    func rowsFollowResultKeyOrder() {
        let entries = [entry(id: 1, name: "一.txt"), entry(id: 2, name: "二.txt"), entry(id: 3, name: "三.txt")]
        let keys = [EntryKey(volumeID: "v1", nodeID: 2), EntryKey(volumeID: "v1", nodeID: 1)]
        let store = store(entries: entries, keys: keys)
        #expect(row(store, 0)?.name == "二.txt")
        #expect(row(store, 1)?.name == "一.txt")
    }

    @Test("越界行号为 nil")
    func outOfRangeRowIsNil() {
        let store = store(entries: [entry(id: 1, name: "一.txt")], keys: [EntryKey(volumeID: "v1", nodeID: 1)])
        #expect(row(store, -1) == nil)
        #expect(row(store, 1) == nil)
    }

    @Test("重复取行结果稳定")
    func rowIsCachedButStable() {
        let store = store(entries: [entry(id: 1, name: "一.txt")], keys: [EntryKey(volumeID: "v1", nodeID: 1)])
        #expect(row(store, 0) == row(store, 0))
    }

    @Test("日期只在按需取行时按传入时区格式化")
    func rowIsBuiltOnDemandWithRequestedTimeZone() {
        let store = store(entries: [entry(id: 1, name: "一.txt")], keys: [EntryKey(volumeID: "v1", nodeID: 1)])
        #expect(store.row(at: 0, timeZone: utc)?.modifiedText == "2023-11-14 22:13")
        #expect(store.row(at: 0, timeZone: utc)?.modifiedText == "2023-11-14 22:13")
    }

    @Test("快照里没有的键没有行且可统计")
    func missingKeyProducesNilRowAndIsCounted() {
        let entries = [entry(id: 1, name: "一.txt")]
        let keys = [EntryKey(volumeID: "v1", nodeID: 1), EntryKey(volumeID: "v1", nodeID: 99)]
        let store = store(entries: entries, keys: keys)
        #expect(store.count == 2)
        #expect(row(store, 0) != nil)
        #expect(row(store, 1) == nil)
        #expect(store.missingKeyCount() == 1)
    }

    @Test("重复键按行号各渲染一行")
    func duplicateKeysAreRenderedPerKeyIndex() {
        let key = EntryKey(volumeID: "v1", nodeID: 1)
        let store = store(entries: [entry(id: 1, name: "一.txt")], keys: [key, key])
        #expect(store.count == 2)
        #expect(row(store, 0) == row(store, 1))
        #expect(store.missingKeyCount() == 0)
    }

    @Test("按键查行号")
    func indexLookupByKey() {
        let entries = [entry(id: 7, name: "报告.pdf", size: 2048)]
        let key = EntryKey(volumeID: "v1", nodeID: 7)
        let store = store(entries: entries, keys: [key])
        #expect(store.index(of: key) == 0)
        #expect(store.index(of: EntryKey(volumeID: "v1", nodeID: 8)) == nil)
    }

    @Test("超过建表阈值时仍能按键找回行号（不丢选区）")
    func indexLookupFallsBackToLinearScanWithoutLosingSelection() {
        let entries = (0..<50).map { entry(id: Int64($0), name: "\($0).txt") }
        let keys = entries.map(\.key)
        let store = store(entries: entries, keys: keys, keyIndexBuildLimit: 4)
        #expect(store.index(of: keys[49]) == 49, "阈值内不建表也必须能找回选中项")
        #expect(store.index(of: keys[0]) == 0)
        #expect(store.index(of: EntryKey(volumeID: "v1", nodeID: 999)) == nil)
        #expect(row(store, 49)?.name == "49.txt")
    }

    @Test("父路径来自相对路径")
    func parentPathIsDerivedFromRelativePath() {
        let entries = [entry(id: 1, name: "报告.pdf", relativePath: "工作/2026/报告.pdf")]
        let store = store(entries: entries, keys: [EntryKey(volumeID: "v1", nodeID: 1)])
        #expect(row(store, 0)?.parentRelativePath == "工作/2026")
        #expect(row(store, 0)?.relativePath == "工作/2026/报告.pdf")
    }

    // MARK: - 卷状态与身份

    @Test("在线行带卷 UUID 与绝对路径")
    func onlineRowCarriesVolumeUUIDAndURL() {
        let entries = [entry(id: 1, name: "报告.pdf", relativePath: "工作/报告.pdf", fileID: 42)]
        let store = store(entries: entries, keys: [EntryKey(volumeID: "v1", nodeID: 1)])
        let value = row(store, 0)
        #expect(value?.absoluteURL()?.path == "/fixtures/v1/工作/报告.pdf")
        #expect(value?.volumeUUID == "UUID-V1")
        #expect(value?.fileID == 42)
        #expect(value?.statusText == "正常")
        #expect(value?.canOpen == true)
    }

    @Test("离线行不可打开且状态为离线")
    func offlineRowIsNotOpenableAndSaysSo() {
        let entries = [entry(id: 1, name: "报告.pdf", relativePath: "报告.pdf")]
        let store = store(
            entries: entries,
            keys: [EntryKey(volumeID: "v1", nodeID: 1)],
            volumes: [volume(online: false)]
        )
        let value = row(store, 0)
        #expect(value?.canOpen == false)
        #expect(value?.absoluteURL() == nil)
        #expect(value?.statusText == "未连接")
        #expect(store.offlineVolumeNames == ["本地盘"])
    }

    @Test("离线路径字符串仍可复制")
    func offlineRowStillHasDisplayPath() {
        let entries = [entry(id: 1, name: "报告.pdf", relativePath: "报告.pdf")]
        let store = store(
            entries: entries,
            keys: [EntryKey(volumeID: "v1", nodeID: 1)],
            volumes: [volume(online: false)]
        )
        #expect(row(store, 0)?.displayPath == "/fixtures/v1/报告.pdf")
        #expect(row(store, 0)?.absoluteURL() == nil)
    }

    @Test("待校验条目在状态列显示")
    func staleEntryIsMarkedPendingVerification() {
        let entries = [entry(id: 1, name: "报告.pdf", state: .stale)]
        let store = store(entries: entries, keys: [EntryKey(volumeID: "v1", nodeID: 1)])
        #expect(row(store, 0)?.statusText == "待检查")
    }

    @Test("离线优先于条目状态")
    func offlineVolumeBeatsEntryState() {
        let entries = [entry(id: 1, name: "报告.pdf", state: .stale)]
        let store = store(
            entries: entries,
            keys: [EntryKey(volumeID: "v1", nodeID: 1)],
            volumes: [volume(online: false)]
        )
        #expect(row(store, 0)?.statusText == "未连接")
    }

    @Test("快照里没有卷记录时按离线处理")
    func unknownVolumeRecordIsTreatedAsOffline() {
        let entries = [entry(id: 1, volumeID: "v9", name: "报告.pdf")]
        let store = store(entries: entries, keys: [EntryKey(volumeID: "v9", nodeID: 1)])
        let value = row(store, 0)
        #expect(value?.canOpen == false)
        #expect(value?.volumeUUID == nil)
        #expect(value?.volumeName == "v9")
    }

    @Test("扩展名小写化")
    func fileExtensionIsLowercased() {
        let entries = [entry(id: 1, name: "报告.PDF")]
        let store = store(entries: entries, keys: [EntryKey(volumeID: "v1", nodeID: 1)])
        #expect(row(store, 0)?.fileExtension == "pdf")
    }

    @Test("无扩展名文件")
    func extensionlessFileHasNoExtension() {
        let entries = [entry(id: 1, name: "README")]
        let store = store(entries: entries, keys: [EntryKey(volumeID: "v1", nodeID: 1)])
        #expect(row(store, 0)?.fileExtension == "")
    }

    // MARK: - 同代重用

    @Test("键不变时重用不产生新状态")
    func reusingWithSameKeysReturnsUnchangedStore() {
        let entries = [entry(id: 1, name: "一.txt")]
        let keys = [EntryKey(volumeID: "v1", nodeID: 1)]
        let store = store(entries: entries, keys: keys)
        let reused = store.reusing(keys: keys)
        #expect(reused.resultKeys == store.resultKeys)
        #expect(reused.entryCount == store.entryCount)
        #expect(row(reused, 0) == row(store, 0))
    }

    @Test("换键时复用查表但丢弃行缓存")
    func reusingWithNewKeysKeepsLookupAndDropsRowCache() {
        let entries = [entry(id: 1, name: "一.txt"), entry(id: 2, name: "二.txt")]
        let store = store(entries: entries, keys: [EntryKey(volumeID: "v1", nodeID: 1)])
        #expect(row(store, 0)?.name == "一.txt")

        let reused = store.reusing(keys: [EntryKey(volumeID: "v1", nodeID: 2)])
        #expect(reused.entryCount == 2, "同代重用不应重建查表")
        #expect(reused.count == 1)
        #expect(row(reused, 0)?.name == "二.txt", "行缓存必须随结果键失效")
    }
}
