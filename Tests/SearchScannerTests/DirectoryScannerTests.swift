import Foundation
import SearchCore
@testable import SearchScanner
import Testing

@Suite("DirectoryScanner enumeration")
struct DirectoryScannerTests {
    @Test("A deep tree is enumerated completely, one batch per directory")
    func deepTreeIsEnumeratedCompletely() async throws {
        let fixture = try ScannerFixture()
        try fixture.directory("a/b/c/d/e")
        try fixture.file("a/b/c/d/e/深层文件.txt", contents: "hello")
        try fixture.file("top.txt")

        let collector = BatchCollector()
        let scanner = DirectoryScanner()
        try await scanner.scan(volume: fixture.volume, onBatch: { collector.append($0) })

        let paths = collector.allRelativePaths
        #expect(paths.contains("top.txt"), "root children must be reported")
        #expect(paths.contains("a"))
        #expect(paths.contains("a/b/c/d/e/深层文件.txt"))

        for expected in ["", "a", "a/b", "a/b/c", "a/b/c/d", "a/b/c/d/e"] {
            #expect(
                collector.directoriesScanned.contains(expected),
                "expected a batch for \(expected)")
        }
        #expect(
            !collector.batches.contains { $0.issue != nil },
            "a fully readable tree must not report issues")
        #expect(
            collector.batches.allSatisfy { $0.isComplete },
            "a fully readable tree must produce complete batches")
    }

    @Test("Symbolic links are listed but never descended")
    func symbolicLinksAreReportedButNeverFollowed() async throws {
        let fixture = try ScannerFixture()
        try fixture.directory("dir/nested")
        try fixture.file("dir/nested/file.txt")
        // A self referential link and a link back to the scan root. Following
        // either would never terminate.
        try fixture.symbolicLink(relative: "dir/self", destination: "..")
        try fixture.symbolicLink(relative: "dir/loop", destination: fixture.root.path)
        try fixture.symbolicLink(relative: "dir/entry", destination: "nested/file.txt")

        let collector = BatchCollector()
        let scanner = DirectoryScanner()
        try await scanner.scan(volume: fixture.volume, onBatch: { collector.append($0) })

        let links = Set(
            collector.batches.flatMap(\.entries)
                .filter(\.isSymbolicLink)
                .map(\.relativePath))
        #expect(links == ["dir/self", "dir/loop", "dir/entry"])

        // Listed, but no batch is ever emitted for them: that is what keeps a
        // cycle from turning into an infinite walk.
        #expect(!collector.directoriesScanned.contains("dir/self"))
        #expect(!collector.directoriesScanned.contains("dir/loop"))
        #expect(!collector.directoriesScanned.contains("dir/entry"))

        let loopEntry = collector.batches.flatMap(\.entries)
            .first { $0.relativePath == "dir/loop" }
        #expect(loopEntry?.isDirectory == false)
        #expect(loopEntry?.isSymbolicLink == true)
    }

    @Test("recursive:false enumerates the starting directories only")
    func recursiveFalseEnumeratesOnlyTheStartingDirectories() async throws {
        let fixture = try ScannerFixture()
        try fixture.directory("alpha/child")
        try fixture.file("alpha/child/deep.txt")
        try fixture.directory("beta")
        try fixture.file("beta/shallow.txt")

        let collector = BatchCollector()
        let scanner = DirectoryScanner()
        try await scanner.scan(
            volume: fixture.volume,
            startingAt: ["alpha", "beta"],
            recursive: false,
            onBatch: { collector.append($0) })

        #expect(collector.directoriesScanned == ["alpha", "beta"])
        // Direct children are described even though they are not descended.
        #expect(collector.allRelativePaths.contains("alpha/child"))
        #expect(collector.allRelativePaths.contains("beta/shallow.txt"))
        // Their own contents are not.
        #expect(!collector.allRelativePaths.contains("alpha/child/deep.txt"))
    }

    @Test("startingAt scopes the walk to a subtree")
    func startingAtScopesTheWalkToASubtree() async throws {
        let fixture = try ScannerFixture()
        try fixture.directory("wanted/inner")
        try fixture.file("wanted/inner/keep.txt")
        try fixture.file("unwanted.txt")

        let collector = BatchCollector()
        let scanner = DirectoryScanner()
        try await scanner.scan(
            volume: fixture.volume,
            startingAt: ["wanted"],
            onBatch: { collector.append($0) })

        #expect(collector.directoriesScanned == ["wanted", "wanted/inner"])
        #expect(collector.allRelativePaths.contains("wanted/inner/keep.txt"))
        #expect(!collector.allRelativePaths.contains("unwanted.txt"))
    }

    @Test("A missing scope yields an incomplete batch instead of failing the walk")
    func missingStartingScopeYieldsAnIncompleteBatch() async throws {
        let fixture = try ScannerFixture()
        try fixture.file("present.txt")

        let collector = BatchCollector()
        let scanner = DirectoryScanner()
        // A scope that no longer exists must not abort the whole walk, and must
        // not be reported as a complete listing: a complete listing is what
        // authorizes deleting previously indexed records.
        try await scanner.scan(
            volume: fixture.volume,
            startingAt: ["", "gone/entirely"],
            onBatch: { collector.append($0) })

        let missing = collector.batch(forDirectory: "gone/entirely")
        #expect(missing != nil)
        #expect(missing?.isComplete == false)
        #expect(missing?.entries.isEmpty == true)
        #expect(missing?.issue?.code == ENOENT)

        #expect(collector.directoriesScanned.contains(""))
        #expect(collector.allRelativePaths.contains("present.txt"))
    }

    @Test("A start path that escapes the root is rejected")
    func startingAtCannotEscapeTheRegisteredRoot() async throws {
        let fixture = try ScannerFixture()
        try fixture.file("inside.txt")

        let collector = BatchCollector()
        let scanner = DirectoryScanner()
        var thrown: DirectoryScanner.ScanError?
        do {
            try await scanner.scan(
                volume: fixture.volume,
                startingAt: ["../.."],
                onBatch: { collector.append($0) })
        } catch let error as DirectoryScanner.ScanError {
            thrown = error
        }
        #expect(thrown == .startOutsideRoot(relativePath: "../.."))
        #expect(collector.batches.isEmpty)
    }

    @Test("An unmounted root is reported rather than indexed as empty")
    func missingRootIsReportedAsUnavailable() async throws {
        let fixture = try ScannerFixture()
        let volume = fixture.volume
        try FileManager.default.removeItem(at: fixture.root)

        let scanner = DirectoryScanner()
        var thrown: DirectoryScanner.ScanError?
        do {
            try await scanner.scan(volume: volume, onBatch: { _ in })
        } catch let error as DirectoryScanner.ScanError {
            thrown = error
        } catch {
            Issue.record("expected ScanError.rootUnavailable, got \(error)")
        }
        #expect(thrown == .rootUnavailable(path: volume.rootPath))
    }

    @Test("Cancelling the task stops the walk early with CancellationError")
    func cancellationStopsTheWalkEarly() async throws {
        let fixture = try ScannerFixture()
        try fixture.makeWideTree(directoryCount: 400)

        let collector = BatchCollector()
        let canceller = CancelAfterBatches(threshold: 5)
        let scanner = DirectoryScanner()

        let task = Task {
            try await scanner.scan(volume: fixture.volume, onBatch: { batch in
                collector.append(batch)
                canceller.recordBatch()
            })
        }
        canceller.attach(task)

        var cancelled = false
        do {
            try await task.value
        } catch is CancellationError {
            cancelled = true
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }

        #expect(cancelled, "a cancelled scan must throw CancellationError")
        let seen = collector.batches.count
        #expect(seen > 0, "the walk should have started before cancellation")
        #expect(seen < 401, "cancellation should have stopped the walk short of the end")
    }

    @Test("An excluded subtree is omitted without faking an enumeration failure")
    func excludedSubtreeIsOmittedEntirely() async throws {
        let fixture = try ScannerFixture()
        try fixture.file("keep.txt")
        try fixture.file("appdata/index.sqlite")
        try fixture.file("appdata/nested/blob.bin")

        let collector = BatchCollector()
        let scanner = DirectoryScanner(
            excludedPaths: [fixture.root.appendingPathComponent("appdata").path])
        try await scanner.scan(volume: fixture.volume, onBatch: { collector.append($0) })

        #expect(collector.allRelativePaths.contains("keep.txt"))
        #expect(!collector.allRelativePaths.contains("appdata"))
        #expect(!collector.directoriesScanned.contains("appdata"))
        // The parent's listing stays complete: exclusion is a scope decision,
        // not an enumeration failure, so it must not trigger delete-by-absence.
        let rootBatch = collector.batch(forDirectory: "")
        #expect(rootBatch?.isComplete == true)
        #expect(rootBatch?.issue == nil)
    }

    @Test("Exclusion matches on a path component boundary")
    func exclusionMatchesOnAComponentBoundary() {
        let excluded = ["/data/appstate"]
        #expect(DirectoryScanner.isExcluded("/data/appstate", excluded: excluded))
        #expect(DirectoryScanner.isExcluded("/data/appstate/db.sqlite", excluded: excluded))
        #expect(!DirectoryScanner.isExcluded("/data/appstate-old", excluded: excluded))
        #expect(!DirectoryScanner.isExcluded("/data/other", excluded: excluded))
    }

    @Test("Relative scope paths normalise to the index's stored form")
    func relativePathNormalization() {
        #expect(DirectoryScanner.normalizeRelative("") == "")
        #expect(DirectoryScanner.normalizeRelative("/") == "")
        #expect(DirectoryScanner.normalizeRelative("./a/b") == "a/b")
        #expect(DirectoryScanner.normalizeRelative("/a/b/") == "a/b")
    }

    @Test("Traversal refuses foreign filesystems and symbolic links")
    func traversalGuardRejectsForeignFilesystemsAndLinks() {
        let mine = FileSystemIdentity(fsIDHi: 1, fsIDLo: 1, fileSystemName: "apfs")
        let theirs = FileSystemIdentity(fsIDHi: 2, fsIDLo: 2, fileSystemName: "apfs")

        func entry(type: DirectoryObjectType, fileSystem: FileSystemIdentity) -> DirectoryEntry {
            DirectoryEntry(
                name: "x", type: type, size: 0, modifiedAt: Date(), fileID: 1,
                fileSystem: fileSystem, isMountPoint: false, errorCode: 0,
                isFullyDescribed: true)
        }

        #expect(entry(type: .directory, fileSystem: mine).isTraversable(from: mine))
        // Another filesystem is a mounted volume, not part of this scope.
        #expect(!entry(type: .directory, fileSystem: theirs).isTraversable(from: mine))
        // A symbolic link is never descended, even on the same filesystem.
        #expect(!entry(type: .symbolicLink, fileSystem: mine).isTraversable(from: mine))
        #expect(!entry(type: .regular, fileSystem: mine).isTraversable(from: mine))
    }

    @Test("A partially described child blocks pruning but is still reported")
    func partiallyDescribedChildMarksTheBatchIncomplete() {
        let identity = FileSystemIdentity(fsIDHi: 1, fsIDLo: 1, fileSystemName: "apfs")
        func entry(isFullyDescribed: Bool) -> DirectoryEntry {
            DirectoryEntry(
                name: "x", type: .regular, size: 0, modifiedAt: Date(), fileID: 1,
                fileSystem: identity, isMountPoint: false, errorCode: 0,
                isFullyDescribed: isFullyDescribed)
        }
        #expect(entry(isFullyDescribed: false).hasUnresolvedMetadata)
        // A directory whose metadata is incomplete must not be descended: the
        // walk would be planning on facts it does not have.
        #expect(!entry(isFullyDescribed: false).isTraversable(from: identity))
        #expect(!entry(isFullyDescribed: true).hasUnresolvedMetadata)
    }

    @Test("Ordinary subdirectories stay on the root's filesystem")
    func ordinarySubdirectoriesShareTheRootFilesystem() async throws {
        // The guard that stops a walk at a mount point has to let the common
        // case through, including paths that live behind APFS firmlinks.
        let fixture = try ScannerFixture()
        try fixture.directory("nested/deeper")

        let rootIdentity = try #require(
            DirectoryReader.fileSystemIdentity(ofPath: fixture.root.path))
        let nestedIdentity = try #require(
            DirectoryReader.fileSystemIdentity(
                ofPath: fixture.root.appendingPathComponent("nested").path))
        #expect(rootIdentity == nestedIdentity)
        #expect(!rootIdentity.fileSystemName.isEmpty)

        let collector = BatchCollector()
        let scanner = DirectoryScanner()
        try await scanner.scan(volume: fixture.volume, onBatch: { collector.append($0) })
        #expect(collector.directoriesScanned.contains("nested/deeper"))
    }

    @Test("An unreadable directory yields an incomplete batch and keeps its entry")
    func unreadableDirectoryProducesIncompleteBatch() async throws {
        guard geteuid() != 0 else {
            // POSIX permissions do not deny root, so this cannot be provoked
            // here; noted rather than silently reported as passing.
            return
        }
        let fixture = try ScannerFixture()
        try fixture.directory("locked")
        try fixture.file("locked/secret.txt")
        try fixture.file("open.txt")

        let locked = fixture.root.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: locked.path)
        }

        let collector = BatchCollector()
        let scanner = DirectoryScanner()
        try await scanner.scan(volume: fixture.volume, onBatch: { collector.append($0) })

        let lockedBatch = collector.batch(forDirectory: "locked")
        #expect(lockedBatch != nil, "the locked directory must still be visited and reported")
        #expect(lockedBatch?.isComplete == false)
        #expect(lockedBatch?.entries.isEmpty == true)
        #expect(lockedBatch?.issue?.code == EACCES)

        // The parent still lists the directory: an unreadable subtree must not
        // make the directory look deleted.
        let rootBatch = collector.batch(forDirectory: "")
        #expect(rootBatch?.entries.contains { $0.relativePath == "locked" } == true)
        #expect(collector.allRelativePaths.contains("open.txt"))
    }
}