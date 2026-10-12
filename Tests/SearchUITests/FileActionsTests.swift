import AppKit
import Darwin
import Foundation
import Testing
@testable import SearchUI
import SearchCore

/// 打开类操作的安全门测试：只创建系统临时夹具，不触碰任何用户文件。
@Suite("文件操作安全门")
@MainActor
struct FileActionsTests {

    // MARK: - 夹具

    private func row(
        online: Bool = true,
        rootPath: String,
        volumeUUID: String?,
        relativePath: String = "报告.pdf",
        fileID: UInt64? = nil
    ) -> ResultRow {
        ResultRow(
            key: EntryKey(volumeID: "v1", nodeID: 1),
            name: "报告.pdf",
            relativePath: relativePath,
            parentRelativePath: "",
            size: 1,
            modifiedAt: Date(timeIntervalSince1970: 0),
            sizeText: "1 B",
            modifiedText: "1970-01-01 00:00",
            isDirectory: false,
            volumeID: "v1",
            volumeName: "测试卷",
            volumeRootPath: rootPath,
            volumeUUID: volumeUUID,
            volumeIsOnline: online,
            state: .current,
            fileID: fileID
        )
    }

    /// 在系统临时目录里建一个夹具文件，返回 (url, inode)。
    private func makeTemporaryFixture() throws -> (url: URL, inode: UInt64) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macEverything-uitest-\(UUID().uuidString)")
        try Data("夹具".utf8).write(to: url)
        var info = stat()
        #expect(lstat(url.path, &info) == 0)
        return (url, UInt64(info.st_ino))
    }

    private func removeFixture(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 卷身份

    @Test("离线卷被拒绝")
    func offlineVolumeIsRefused() {
        #expect(FileActions.verifyVolume(for: row(online: false, rootPath: "/", volumeUUID: "X")) == .volumeOffline)
    }

    @Test("空根路径被拒绝")
    func emptyRootPathIsRefused() {
        #expect(FileActions.verifyVolume(for: row(rootPath: "", volumeUUID: "X")) == .volumeNotMounted)
    }

    @Test("挂载点不存在被拒绝")
    func missingMountPointIsRefused() {
        #expect(
            FileActions.verifyVolume(for: row(rootPath: "/不存在的挂载点/寻目测试", volumeUUID: "X")) == .volumeNotMounted
        )
    }

    @Test("缺卷 UUID 无法确认身份")
    func missingVolumeUUIDIsRefused() {
        #expect(FileActions.verifyVolume(for: row(rootPath: "/", volumeUUID: nil)) == .volumeIdentityUnknown)
        #expect(FileActions.verifyVolume(for: row(rootPath: "/", volumeUUID: "")) == .volumeIdentityUnknown)
    }

    @Test("换过盘被拒绝")
    func replacedVolumeIsRefused() {
        #expect(
            FileActions.verifyVolume(for: row(rootPath: "/", volumeUUID: "00000000-0000-0000-0000-000000000000")) == .volumeChanged
        )
    }

    @Test("卷 UUID 一致时通过")
    func matchingVolumeUUIDPasses() throws {
        let actual = try #require(FileActions.mountedVolumeUUID(atPath: "/"), "根卷应有可读 UUID")
        #expect(FileActions.verifyVolume(for: row(rootPath: "/", volumeUUID: actual)) == nil)
        #expect(FileActions.verifyVolume(for: row(rootPath: "/", volumeUUID: actual.uppercased())) == nil)
    }

    // MARK: - 目标存在性与文件身份

    @Test("目标不存在时拒绝打开")
    func missingTargetIsRefused() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macEverything-uidir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { removeFixture(directory) }
        let uuid = try #require(FileActions.mountedVolumeUUID(atPath: "/"))
        let subject = row(rootPath: directory.path, volumeUUID: uuid, relativePath: "不存在.pdf")
        #expect(FileActions.verifyOpen(subject) == .pathUnavailable)
        var status = ""
        #expect(FileActions.open(subject) { status = $0 } == false)
        #expect(status.contains("找不到"))
    }

    @Test("路径上的文件被替换时拒绝打开")
    func replacedFileIsRefused() throws {
        let fixture = try makeTemporaryFixture()
        defer { removeFixture(fixture.url) }
        let uuid = try #require(FileActions.mountedVolumeUUID(atPath: "/"))
        let subject = row(
            rootPath: FileManager.default.temporaryDirectory.path,
            volumeUUID: uuid,
            relativePath: fixture.url.lastPathComponent,
            fileID: fixture.inode &+ 1
        )
        #expect(FileActions.verifyOpen(subject) == .fileReplaced)
        var status = ""
        #expect(FileActions.open(subject) { status = $0 } == false)
        #expect(status.contains("文件与记录不符"))
    }

    @Test("文件身份一致时通过全部检查")
    func matchingFileIDPassesAllChecks() throws {
        let fixture = try makeTemporaryFixture()
        defer { removeFixture(fixture.url) }
        let uuid = try #require(FileActions.mountedVolumeUUID(atPath: "/"))
        let subject = row(
            rootPath: FileManager.default.temporaryDirectory.path,
            volumeUUID: uuid,
            relativePath: fixture.url.lastPathComponent,
            fileID: fixture.inode
        )
        #expect(FileActions.verifyOpen(subject) == nil)
    }

    @Test("没有 fileID 时只做存在性检查")
    func missingFileIDOnlyChecksExistence() throws {
        let fixture = try makeTemporaryFixture()
        defer { removeFixture(fixture.url) }
        let uuid = try #require(FileActions.mountedVolumeUUID(atPath: "/"))
        let subject = row(
            rootPath: FileManager.default.temporaryDirectory.path,
            volumeUUID: uuid,
            relativePath: fixture.url.lastPathComponent,
            fileID: nil
        )
        #expect(FileActions.verifyFileIdentity(subject, at: fixture.url) == nil)
        #expect(FileActions.verifyOpen(subject) == nil)
    }

    @Test("离线路径可以复制，不需要唤醒卷")
    func copyPathWorksForOfflineRows() {
        let subject = row(online: false, rootPath: "/Volumes/移动盘", volumeUUID: nil, relativePath: "报告.pdf")
        var status = ""
        #expect(FileActions.copyPath(subject) { status = $0 } == true)
        #expect(NSPasteboard.general.string(forType: .string) == "/Volumes/移动盘/报告.pdf")
        #expect(status.contains("已复制路径"))
    }

    @Test("离线行不提供可打开的 URL")
    func absoluteURLOnlyForOnlineRowWithRoot() {
        #expect(row(online: false, rootPath: "/", volumeUUID: nil).absoluteURL() == nil)
        #expect(row(rootPath: "", volumeUUID: "X").absoluteURL() == nil)
        #expect(row(rootPath: "/tmp", volumeUUID: "X").absoluteURL()?.path == "/tmp/报告.pdf")
        #expect(row(rootPath: "/tmp", volumeUUID: "X").displayPath == "/tmp/报告.pdf")
    }
}