import Foundation
import SearchCore
@testable import SearchScanner
import Testing

@Suite("Volume discovery")
struct VolumeDiscoveryTests {
    @Test("A live directory reports real filesystem facts")
    func describeReportsRealFactsForALiveDirectory() throws {
        let fixture = try ScannerFixture()
        let record = VolumeDiscovery.describe(rootURL: fixture.root)

        #expect(record.rootPath == (fixture.root.path as NSString).standardizingPath)
        #expect(FileManager.default.fileExists(atPath: record.rootPath))
        #expect(record.isOnline)
        #expect(
            record.fileSystem != "unknown",
            "statfs should name the filesystem, got \(record.fileSystem)")
        #expect(!record.name.isEmpty)
        #expect(!record.id.isEmpty)
    }

    @Test("The filesystem name is verbatim and never inferred as solid state")
    func fileSystemIsReportedVerbatim() throws {
        let fixture = try ScannerFixture()
        let record = VolumeDiscovery.describe(rootURL: fixture.root)
        // The contract this test enforces: the filesystem string is whatever
        // statfs says, and nothing in this type claims the backing hardware is
        // solid state. `apfs` in particular is used for both SSD and spinning
        // media, so a caller must not read anything into it.
        let identity = try #require(
            DirectoryReader.fileSystemIdentity(ofPath: fixture.root.path))
        #expect(record.fileSystem == identity.fileSystemName)
        #expect(!record.fileSystem.lowercased().contains("ssd"))
        #expect(!record.fileSystem.lowercased().contains("rotational"))
    }

    @Test("The scope id is a different identity from the volume UUID")
    func scopeIdIsDistinctFromTheVolumeUUID() throws {
        let fixture = try ScannerFixture()
        let record = VolumeDiscovery.describe(rootURL: fixture.root, id: "scope-1")
        // The index scope id and the volume UUID answer different questions:
        // the scope is what the user selected, the UUID is what the volume is.
        #expect(record.id == "scope-1")
        #expect(record.id != record.volumeUUID)
    }

    @Test("A volume UUID, when present, is a real UUID string")
    func volumeUUIDIsAUuidString() throws {
        let fixture = try ScannerFixture()
        let identifier = try #require(
            VolumeDiscovery.volumeUUIDString(of: fixture.root),
            "the system temp directory should be on a volume that reports a UUID")
        #expect(identifier == identifier.uppercased() || identifier == identifier.lowercased())
        #expect(identifier.count >= 32, "expected a UUID-shaped string, got \(identifier)")
        #expect(identifier.filter { $0 == "-" }.count == 4 || identifier.count == 32)
    }

    @Test("An unresolved root stays an offline scope instead of being fabricated")
    func unavailableRootStaysAnOfflineScope() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacEverythingAbsent-\(UUID().uuidString)")
        let record = VolumeDiscovery.describe(rootURL: missing)

        #expect(record.isOnline == false)
        #expect(
            record.requiresFullVerification,
            "an unresolved volume must not be treated as verified")
        #expect(record.fileSystem == "unknown")
        #expect(record.volumeUUID == nil, "an unresolved path has no volume UUID")
    }

    @Test("Filesystems that change outside macOS require full verification",
        arguments: [
            "ntfs", "NTFS", "tuxera_ntfs", "paragon_ntfs", "ntfs-3g", "fuse.ntfs",
            "ntfs3", "exfat", "msdos", "msdosfs", "fat32", "vfat",
        ])
    func foreignWriteFileSystemsRequireVerification(fileSystem: String) {
        #expect(
            VolumeDiscovery.requiresFullVerification(fileSystem: fileSystem),
            "\(fileSystem) must not be trusted without a full verification")
    }

    @Test("An unknown third-party driver is not trusted either",
        arguments: ["", "   ", "unknown", "zfs", "btrfs", "tuxera_ext4", "acfs"])
    func unknownFileSystemsRequireVerification(fileSystem: String) {
        // Absence of a known-bad marker is not evidence of trustworthiness. An
        // unrecognised type is a driver whose journal and event semantics are
        // unknown, and assuming they behave like APFS is what silently loses
        // changes on a removable disk.
        #expect(
            VolumeDiscovery.requiresFullVerification(fileSystem: fileSystem),
            "\(fileSystem) must not be trusted without a full verification")
    }

    @Test("Journalled macOS file systems keep a trustworthy event log",
        arguments: ["apfs", "APFS", " apfs ", "hfs", "HFS"])
    func journalledFileSystemsAreTrusted(fileSystem: String) {
        #expect(
            !VolumeDiscovery.requiresFullVerification(fileSystem: fileSystem),
            "\(fileSystem) is journalled by macOS and its log may be replayed")
    }

    @Test("The real filesystem name is preserved verbatim")
    func realFileSystemNameIsPreserved() throws {
        let fixture = try ScannerFixture()
        let record = VolumeDiscovery.describe(rootURL: fixture.root)
        let identity = try #require(
            DirectoryReader.fileSystemIdentity(ofPath: fixture.root.path))
        // Classification never rewrites what the volume calls itself: the name
        // is what gets shown to the user and stored.
        #expect(record.fileSystem == identity.fileSystemName)
    }

    @Test("Two scopes on one root share the volume UUID but not the scope id")
    func twoDescriptionsShareTheVolumeUUID() throws {
        let fixture = try ScannerFixture()
        let first = VolumeDiscovery.describe(rootURL: fixture.root, id: "a")
        let second = VolumeDiscovery.describe(rootURL: fixture.root, id: "b")
        #expect(first.volumeUUID == second.volumeUUID)
        #expect(first.id != second.id)
    }

    @Test("Mounted volumes are real and exclude the /Volumes container")
    func mountedVolumesAreRealAndExcludeTheVolumesContainer() {
        let volumes = VolumeDiscovery.mountedVolumes()
        #expect(!volumes.isEmpty, "there is always at least the boot volume")
        #expect(
            !volumes.contains { $0.rootPath == "/Volumes" },
            "/Volumes is a container on the root volume, not a volume")

        if let boot = volumes.first(where: { $0.rootPath == "/" }) {
            #expect(boot.isOnline)
        } else {
            Issue.record("the boot volume should appear in mountedVolumes()")
        }

        for volume in volumes {
            #expect(!volume.fileSystem.isEmpty)
            #expect(!volume.rootPath.isEmpty)
        }
    }

    @Test("A temp directory is not a volume root, and its volume root resolves")
    func volumeRootResolution() throws {
        let fixture = try ScannerFixture()
        #expect(!VolumeDiscovery.isVolumeRoot(fixture.root.path))
        // The filesystem root has no parent filesystem to differ from.
        #expect(!VolumeDiscovery.isVolumeRoot("/"))

        let volumeRoot = VolumeDiscovery.volumeRootPath(for: fixture.root)
        #expect(!volumeRoot.isEmpty, "the temp directory's volume root must resolve")
        #expect(volumeRoot.hasPrefix("/"))
        // The temp directory lives inside that volume, never is it.
        #expect(!FileEventMonitor.relativePath(ofRoot: fixture.root.path, underVolume: volumeRoot)
            .hasPrefix("/"))
    }
}

@Suite("Darwin directory reader")
struct DarwinBridgeTests {
    @Test("The bulk decoder reads real directories coherently")
    func bulkDecoderIsCoherent() {
        // This is a diagnostic, not a silent kill switch. A parser that cannot
        // read a real directory is a defect, and quietly degrading to the
        // fallback would hide exactly the failure worth seeing.
        #expect(
            DirectoryReader.bulkDecoderIsCoherent,
            "the bulk reader rejected its own decoded records on this machine")
    }

    @Test("Bulk and fallback readers agree, and the bulk path really ran")
    func bulkAndFallbackReadersAgree() throws {
        let fixture = try ScannerFixture()
        try fixture.directory("sub")
        try fixture.file("alpha.txt", contents: "alpha")
        try fixture.file("sub/beta.txt", contents: "beta")
        try fixture.symbolicLink(relative: "link", destination: "alpha.txt")
        let identity = try #require(
            DirectoryReader.fileSystemIdentity(ofPath: fixture.root.path))

        let bulk = try DirectoryReader.read(
            path: fixture.root.path, identity: identity, preferBulk: true)
        let fallback = try DirectoryReader.read(
            path: fixture.root.path, identity: identity, preferBulk: false)

        // Asserting only the name sets would pass even if bulk silently fell
        // back, so the reader used is asserted explicitly.
        #expect(bulk.usedBulkReader, "the bulk reader must actually have been used")
        #expect(!fallback.usedBulkReader)
        #expect(bulk.failureCode == 0)
        #expect(fallback.failureCode == 0)
        #expect(Set(bulk.entries.map(\.name)) == Set(fallback.entries.map(\.name)))

        let bulkTypes = Dictionary(
            uniqueKeysWithValues: bulk.entries.map { ($0.name, $0.type) })
        for entry in fallback.entries {
            #expect(bulkTypes[entry.name] == entry.type, "type mismatch for \(entry.name)")
        }
    }

    @Test("Vnode types are decoded as VREG/VDIR/VLNK, not DT_*")
    func vnodeTypesAreDecodedCorrectly() throws {
        let fixture = try ScannerFixture()
        try fixture.file("plain.txt")
        try fixture.directory("folder")
        try fixture.symbolicLink(relative: "link", destination: "plain.txt")
        let identity = try #require(
            DirectoryReader.fileSystemIdentity(ofPath: fixture.root.path))

        for preferBulk in [true, false] {
            let result = try DirectoryReader.read(
                path: fixture.root.path, identity: identity, preferBulk: preferBulk)
            let byName = Dictionary(
                uniqueKeysWithValues: result.entries.map { ($0.name, $0) })
            let mode = preferBulk ? "bulk" : "fallback"
            #expect(byName["plain.txt"]?.type == .regular, "\(mode)")
            #expect(byName["folder"]?.type == .directory, "\(mode)")
            #expect(byName["link"]?.type == .symbolicLink, "\(mode)")
            #expect(byName["folder"]?.isDirectory == true, "\(mode)")
            #expect(byName["link"]?.isSymbolicLink == true, "\(mode)")
            // A directory must carry a zero size in both decoders.
            #expect(byName["folder"]?.size == 0, "\(mode)")
            #expect(byName["link"]?.size == 0, "\(mode)")
        }
    }

    @Test("Sizes, ids and modification times come from the real filesystem")
    func readerReportsSizesAndTimesCorrectly() throws {
        let fixture = try ScannerFixture()
        let url = try fixture.file("payload.bin", contents: String(repeating: "x", count: 4096))
        let identity = try #require(
            DirectoryReader.fileSystemIdentity(ofPath: fixture.root.path))

        for preferBulk in [true, false] {
            let result = try DirectoryReader.read(
                path: fixture.root.path, identity: identity, preferBulk: preferBulk)
            let payload = try #require(
                result.entries.first { $0.name == "payload.bin" })
            #expect(payload.size == 4096, "preferBulk=\(preferBulk)")
            #expect(payload.fileID != nil, "preferBulk=\(preferBulk)")
            #expect(payload.fileSystem == identity, "preferBulk=\(preferBulk)")

            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let expected = try #require(attributes[.modificationDate] as? Date)
            // Whole-second resolution.
            #expect(
                Int64(payload.modifiedAt.timeIntervalSince1970.rounded())
                    == Int64(expected.timeIntervalSince1970.rounded(.down)),
                "preferBulk=\(preferBulk)")
        }
    }

    @Test("A missing directory is an open failure, never an empty success")
    func readerReportsAMissingDirectoryAsAnOpenFailure() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacEverythingNoDir-\(UUID().uuidString)")
        var code: Int32 = 0
        do {
            _ = try DirectoryReader.read(
                path: missing.path,
                identity: FileSystemIdentity(fsIDHi: 0, fsIDLo: 0, fileSystemName: "unknown"))
        } catch let error as DirectoryReadError {
            if case .openFailed(_, let reported) = error { code = reported }
        } catch {
            Issue.record("expected DirectoryReadError.openFailed, got \(error)")
        }
        #expect(code == ENOENT, "got errno \(code)")
    }

    @Test("Every child inherits the directory's filesystem identity")
    func readerAssignsTheOpenedFilesystemIdentity() throws {
        let fixture = try ScannerFixture()
        try fixture.file("identity.txt")
        let identity = try #require(
            DirectoryReader.fileSystemIdentity(ofPath: fixture.root.path))
        let result = try DirectoryReader.read(path: fixture.root.path, identity: identity)
        #expect(!result.entries.isEmpty)
        for entry in result.entries {
            #expect(
                entry.fileSystem == identity,
                "\(entry.name) was attributed to the wrong filesystem")
        }
    }

    @Test("An empty directory is a complete, empty listing")
    func emptyDirectoryReadsAsAnEmptyCompleteListing() throws {
        let fixture = try ScannerFixture()
        let empty = try fixture.directory("empty")
        let identity = try #require(
            DirectoryReader.fileSystemIdentity(ofPath: empty.path))
        let result = try DirectoryReader.read(path: empty.path, identity: identity)
        #expect(result.entries.isEmpty)
        #expect(result.failureCode == 0, "an empty directory is still fully enumerated")
    }

    @Test("An unreadable filesystem identity reports why, not just that it failed")
    func filesystemIdentityReportsItsError() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacEverythingNoFs-\(UUID().uuidString)")
        var errorCode: Int32 = 0
        let identity = DirectoryReader.fileSystemIdentity(
            ofPath: missing.path, errorCode: &errorCode)
        #expect(identity == nil)
        #expect(errorCode == ENOENT, "got errno \(errorCode)")
    }

    @Test("The device id of a real path is non-zero")
    func deviceIDResolves() throws {
        let fixture = try ScannerFixture()
        #expect(DirectoryReader.deviceID(ofPath: fixture.root.path) != 0)
        #expect(DirectoryReader.deviceID(ofPath: "/definitely/not/here") == 0)
    }
}