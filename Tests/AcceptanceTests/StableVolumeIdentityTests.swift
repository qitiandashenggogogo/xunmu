import Foundation
import Testing
import SearchCore
import SearchScanner
import SearchUI

@Suite("卷身份一致性")
struct StableVolumeIdentityTests {
    @Test("原生卷使用系统 UUID，三条调用路径一致") @MainActor
    func nativeUUID() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
        let native = try #require(url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        #expect(StableVolumeIdentity.identifier(for: url) == native)
        #expect(VolumeDiscovery.volumeUUIDString(of: url) == native)
        #expect(FileActions.mountedVolumeUUID(atPath: url.path) == native)
    }

    @Test("不存在的路径不能用祖先卷身份冒充在线")
    func missingPath() {
        #expect(StableVolumeIdentity.identifier(for: URL(fileURLWithPath: "/missing-\(UUID().uuidString)")) == nil)
    }

    @Test("实际第三方 NTFS 的分区 UUID 可跨扫描和打开校验使用",
          .enabled(if: ProcessInfo.processInfo.environment["MACEVERYTHING_HARDWARE_IDENTITY"] == "1")) @MainActor
    func realNTFSPartition() throws {
        let volume = try #require(VolumeDiscovery.mountedVolumes().first { $0.fileSystem.lowercased().contains("ntfs") })
        let identity = try #require(volume.volumeUUID)
        #expect(identity.hasPrefix("partition:"))
        #expect(UUID(uuidString: String(identity.dropFirst("partition:".count))) != nil)
        #expect(FileActions.mountedVolumeUUID(atPath: volume.rootPath) == identity)
        #expect(VolumeDiscovery.describe(rootURL: URL(fileURLWithPath: volume.rootPath), id: volume.id).volumeUUID == identity)
        #expect(volume.requiresFullVerification)
    }
    @Test("实际外置盘的枚举身份能通过打开前门禁，子目录身份一致",
          .enabled(if: ProcessInfo.processInfo.environment["MACEVERYTHING_HARDWARE_IDENTITY"] == "1"),
          arguments: ["exfat", "tuxera_ntfs"]) @MainActor
    func realOpenGate(fileSystem: String) async throws {
        let volume = try #require(VolumeDiscovery.mountedVolumes().first { $0.fileSystem == fileSystem })
        let batches = HardwareRootBatches()
        try await DirectoryScanner().scan(volume: volume, recursive: false) { await batches.append($0) }
        let values = await batches.values
        #expect(values.count == 1)
        #expect(values.allSatisfy { $0.isComplete })
        let entry = try #require(values.flatMap(\.entries).first { $0.isDirectory && !$0.isSymbolicLink && !$0.name.hasPrefix(".") })
        let key = EntryKey(volumeID: volume.id, nodeID: 1)
        let indexed = IndexedEntry(key: key, relativePath: entry.relativePath, name: entry.name,
            isDirectory: entry.isDirectory, size: entry.size, modifiedAt: entry.modifiedAt, fileID: entry.fileID)
        let store = ResultRowStore(snapshot: CatalogSnapshot(generation: 1, entries: [indexed], volumes: [volume]), keys: [key])
        let row = try #require(store.row(at: 0))
        #expect(FileActions.verifyOpen(row) == nil)
        #expect(StableVolumeIdentity.identifier(for: URL(fileURLWithPath: volume.rootPath).appendingPathComponent(entry.relativePath)) == volume.volumeUUID)
        // Validate stream construction only. No writes or fake changes on user disks.
        let monitor = try FileEventMonitor(rootURL: URL(fileURLWithPath: volume.rootPath), onChanges: { _ in })
        try monitor.start()
        monitor.stop()
    }

}


private actor HardwareRootBatches {
    var values: [DirectoryBatch] = []
    func append(_ batch: DirectoryBatch) { values.append(batch) }
}
