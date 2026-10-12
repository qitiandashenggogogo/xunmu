import Testing
import Foundation
import SearchCore
import SearchIndex

/// 持久化目录（SQLite）黑盒验收。
///
/// 只用 `CatalogStore` 的公开接口 + 临时夹具目录内的数据库文件；
/// 不写用户主目录、不写外置盘、不创建海量真实文件。
@Suite("持久化目录验收")
struct CatalogPersistenceAcceptanceTests {

    // 每个用例一套独立夹具与数据库（Swift Testing 默认并行执行同 suite 内的用例）。
    private func withStore<T>(
        _ body: (CatalogStore, AcceptanceTempDirectory) async throws -> T
    ) async throws -> T {
        let temporary = try AcceptanceTempDirectory(label: "catalog")
        let store = try CatalogStore(databaseURL: temporary.path("catalog.sqlite", isDirectory: false))
        try await store.registerVolume(AcceptanceFixture.internalVolume())
        try await store.registerVolume(AcceptanceFixture.externalVolume())
        return try await body(store, temporary)
    }

    private func paths(_ store: CatalogStore) async throws -> Set<String> {
        Set(try await store.entries().map(\.relativePath))
    }

    private func snapshot(of store: CatalogStore) async throws -> CatalogSnapshot {
        AcceptanceFixture.snapshot(
            generation: try await store.generation(),
            volumes: try await store.volumes(),
            entries: try await store.entries()
        )
    }

    // MARK: - 目录直属 diff

    @Test("完整批次的直属 diff 删除缺失子项及其子树，保留同级项")
    func completeBatchDiffDeletesOnlyMissingDirectChildrenSubtrees() async throws {
        try await withStore { store, _ in
            try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-internal", directory: "",
                    paths: ["项目", "其他.txt"], isDirectory: { $0 == "项目" }
                )
            )
            try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-internal", directory: "项目",
                    paths: ["子目录", "报告.pdf"], isDirectory: { $0 == "子目录" }
                )
            )
            try await store.apply(
                AcceptanceFixture.batch(volumeID: "vol-internal", directory: "项目/子目录", paths: ["明细.pdf"])
            )
            #expect(
                try await paths(store) == ["项目", "其他.txt", "项目/子目录", "项目/报告.pdf", "项目/子目录/明细.pdf"]
            )

            // 目录「项目」的一次完整枚举不再包含「子目录」→ 其整棵子树必须删除。
            try await store.apply(
                AcceptanceFixture.batch(volumeID: "vol-internal", directory: "项目", paths: ["报告.pdf"])
            )
            #expect(
                try await paths(store) == ["项目", "其他.txt", "项目/报告.pdf"],
                "缺失直属子项应连同其子树一起删除，同级保留项不受影响"
            )
        }
    }

    @Test("删除直属子项不删父目录本体与兄弟目录")
    func directoryDiffDoesNotDeleteParentOrSiblings() async throws {
        try await withStore { store, _ in
            try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-internal", directory: "", paths: ["父目录"], isDirectory: { _ in true }
                )
            )
            try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-internal", directory: "父目录", paths: ["甲", "乙"], isDirectory: { _ in true }
                )
            )
            try await store.apply(
                AcceptanceFixture.batch(volumeID: "vol-internal", directory: "父目录/甲", paths: ["文件.txt"])
            )
            try await store.apply(
                AcceptanceFixture.batch(volumeID: "vol-internal", directory: "父目录/乙", paths: ["文件.txt"])
            )

            try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-internal", directory: "父目录", paths: ["乙"], isDirectory: { _ in true }
                )
            )
            #expect(
                try await paths(store) == ["父目录", "父目录/乙", "父目录/乙/文件.txt"],
                "删除直属子项不得误删父目录本体或兄弟目录"
            )
        }
    }

    @Test("共享前缀的兄弟目录不会被前缀匹配误删")
    func prefixBoundaryDoesNotDeleteSiblingsSharingPrefix() async throws {
        try await withStore { store, _ in
            try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-internal", directory: "", paths: ["a", "ab"], isDirectory: { _ in true }
                )
            )
            try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-internal", directory: "a", paths: ["b", "bc"], isDirectory: { _ in true }
                )
            )
            try await store.apply(AcceptanceFixture.batch(volumeID: "vol-internal", directory: "ab", paths: ["keep.txt"]))
            try await store.apply(AcceptanceFixture.batch(volumeID: "vol-internal", directory: "a/bc", paths: ["keep.txt"]))
            try await store.apply(AcceptanceFixture.batch(volumeID: "vol-internal", directory: "a/b", paths: ["inside.txt"]))

            // 「a」的直属子项 diff：「b」消失，「bc」必须幸存。
            try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-internal", directory: "a", paths: ["bc"], isDirectory: { _ in true }
                )
            )

            let remaining = try await paths(store)
            #expect(!remaining.contains("a/b"), "缺失的直属子项应被删除")
            #expect(!remaining.contains("a/b/inside.txt"), "缺失子项的子树应一并删除")
            #expect(remaining.contains("a"), "父目录不得被删除")
            #expect(remaining.contains("a/bc"), "「a/bc」不是「a/b」的子路径，不得被前缀匹配误删")
            #expect(remaining.contains("a/bc/keep.txt"))
            #expect(remaining.contains("ab"), "同层兄弟目录「ab」不得受影响")
            #expect(remaining.contains("ab/keep.txt"))
        }
    }

    @Test("删除 A 的子树不删除仅大小写不同的兄弟 a")
    func deletingSubtreeOfUppercaseDoesNotDeleteLowercaseSibling() async throws {
        try await withStore { store, _ in
            try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-internal", directory: "", paths: ["A", "a"], isDirectory: { _ in true }
                )
            )
            try await store.apply(
                AcceptanceFixture.batch(volumeID: "vol-internal", directory: "A", paths: ["甲.txt", "乙.txt"])
            )
            try await store.apply(
                AcceptanceFixture.batch(volumeID: "vol-internal", directory: "a", paths: ["丙.txt"])
            )

            // 重新枚举根目录时「A」消失，差异删除必须精确命中 A 的子树。
            try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-internal", directory: "", paths: ["a"], isDirectory: { _ in true }
                )
            )

            let remaining = try await paths(store)
            #expect(!remaining.contains("A"), "缺失的目录本身应被删除")
            #expect(!remaining.contains("A/甲.txt"), "A 的子树应全部删除")
            #expect(!remaining.contains("A/乙.txt"), "A 的子树应全部删除")
            #expect(remaining.contains("a"), "仅大小写不同的兄弟「a」不得被大小写折叠后误删")
            #expect(remaining.contains("a/丙.txt"), "「a」的子树必须原样保留")
        }
    }

    @Test("名字里的 % 与 _ 按字面处理")
    func likeWildcardCharactersInNamesAreTreatedLiterally() async throws {
        try await withStore { store, _ in
            try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-internal", directory: "",
                    paths: ["a%b", "a_b", "aXb"], isDirectory: { _ in true }
                )
            )
            for directory in ["a%b", "a_b", "aXb"] {
                try await store.apply(
                    AcceptanceFixture.batch(volumeID: "vol-internal", directory: directory, paths: ["inside.txt"])
                )
            }
            try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-internal", directory: "", paths: ["a_b", "aXb"], isDirectory: { _ in true }
                )
            )

            #expect(
                try await paths(store) == ["a_b", "a_b/inside.txt", "aXb", "aXb/inside.txt"],
                "% / _ 出现在名字里时按字面处理，不得当通配符扩大删除范围"
            )
        }
    }

    // MARK: - 批量删除的规模上限

    @Test("单目录一次删除 2000 个缺失项不会触发 SQLite 变量或表达式深度上限")
    func bulkDeletionOfTwoThousandMissingEntriesSucceeds() async throws {
        try await withStore { store, _ in
            let total = 2_000
            try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-internal", directory: "",
                    paths: ["大批量"], isDirectory: { _ in true }
                )
            )
            try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-internal", directory: "大批量",
                    paths: (0..<total).map { String(format: "大批量/文件-%05d.txt", $0) }
                )
            )
            #expect(try await paths(store).count == total + 1)

            // 一次完整枚举返回空 → 2000 个直属子项全部缺失。
            let generationBefore = try await store.generation()
            try await store.apply(
                AcceptanceFixture.batch(volumeID: "vol-internal", directory: "大批量", paths: [])
            )

            #expect(
                try await paths(store) == ["大批量"],
                "2000 项一次性删除必须成功完成，不能因 SQL 变量或表达式深度超限而失败"
            )
            #expect(try await store.generation() > generationBefore)
        }
    }

    @Test("单目录 2500 项中保留 500、删除 2000 也能正确 diff")
    func bulkDeletionAlongsideRetainedEntriesSucceeds() async throws {
        try await withStore { store, _ in
            let retained = (0..<500).map { String(format: "保留/留下-%05d.txt", $0) }
            let removed = (0..<2_000).map { String(format: "保留/删掉-%05d.txt", $0) }
            try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-internal", directory: "", paths: ["保留"], isDirectory: { _ in true }
                )
            )
            try await store.apply(
                AcceptanceFixture.batch(volumeID: "vol-internal", directory: "保留", paths: retained + removed)
            )
            #expect(try await paths(store).count == 2_501)

            try await store.apply(
                AcceptanceFixture.batch(volumeID: "vol-internal", directory: "保留", paths: retained)
            )

            let remaining = try await paths(store)
            #expect(remaining.count == 501, "保留 500 条 + 目录本身")
            #expect(remaining.contains("保留"))
            #expect(remaining.contains("保留/留下-00000.txt"))
            #expect(!remaining.contains("保留/删掉-00000.txt"), "2000 条缺失项应被删干净")
            #expect(!remaining.contains("保留/删掉-01999.txt"))
        }
    }

    // MARK: - 不完整 / 失败批次

    @Test("不完整批次只做增量，绝不删除旧记录")
    func incompleteBatchNeverDeletesExistingEntries() async throws {
        try await withStore { store, _ in
            try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-internal", directory: "", paths: ["目录"], isDirectory: { _ in true }
                )
            )
            try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-internal", directory: "目录", paths: ["甲.txt", "乙.txt", "丙.txt"]
                )
            )
            #expect(try await paths(store).count == 4)

            try await store.apply(
                AcceptanceFixture.failedBatch(
                    volumeID: "vol-internal", directory: "目录", partialPaths: ["目录/丁.txt"]
                )
            )
            #expect(
                try await paths(store) == ["目录", "目录/甲.txt", "目录/乙.txt", "目录/丙.txt", "目录/丁.txt"],
                "不完整批次必须保留全部旧记录，只做增量写入"
            )
        }
    }

    @Test("枚举失败的目录被标记为待校验")
    func failedDirectoryIsFlaggedForRevalidation() async throws {
        try await withStore { store, _ in
            try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-internal", directory: "",
                    paths: ["受限"], isDirectory: { _ in true }
                )
            )
            try await store.apply(
                AcceptanceFixture.batch(volumeID: "vol-internal", directory: "受限", paths: ["可读.txt"])
            )
            try await store.apply(
                AcceptanceFixture.failedBatch(
                    volumeID: "vol-internal", directory: "受限", partialPaths: ["受限/可读.txt"]
                )
            )

            let entries = AcceptanceFixture.entriesByPath(try await snapshot(of: store))
            let restricted = try #require(entries["受限"])
            #expect(restricted.state == .stale, "枚举失败的目录必须标记为待校验，而不是静默视为正常")
        }
    }

    @Test("卷拔出（离线）不删除该卷的索引记录")
    func volumeEjectDoesNotDeleteEntriesOfThatVolume() async throws {
        try await withStore { store, _ in
            try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-external", directory: "", paths: ["离线目录"], isDirectory: { _ in true }
                )
            )
            try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-external", directory: "离线目录", paths: ["内含.txt", "数据.txt"]
                )
            )

            try await store.registerVolume(
                AcceptanceFixture.externalVolume(isOnline: false, requiresFullVerification: true)
            )

            #expect(
                try await paths(store) == ["离线目录", "离线目录/内含.txt", "离线目录/数据.txt"],
                "卷离线不得删除该卷的索引记录"
            )
            let volumes = try await store.volumes()
            let external = try #require(volumes.first { $0.id == "vol-external" })
            #expect(!external.isOnline)
            #expect(external.requiresFullVerification, "离线卷必须标记需要完整校验")
        }
    }

    // MARK: - 重开 / checkpoint / 补扫责任

    @Test("重启后索引条目保留")
    func entriesSurviveDatabaseReopen() async throws {
        let temporary = try AcceptanceTempDirectory(label: "reopen")
        let databaseURL = temporary.path("catalog.sqlite", isDirectory: false)

        do {
            let store = try CatalogStore(databaseURL: databaseURL)
            try await store.registerVolume(AcceptanceFixture.internalVolume())
            try await store.registerVolume(AcceptanceFixture.externalVolume())
            try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-internal", directory: "",
                    paths: ["文档", "预算.xlsx"], isDirectory: { $0 == "文档" }
                )
            )
            try await store.apply(
                AcceptanceFixture.batch(volumeID: "vol-internal", directory: "文档", paths: ["报告.pdf"])
            )
            try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-external", directory: "", paths: ["外置"], isDirectory: { _ in true }
                )
            )
            try await store.apply(
                AcceptanceFixture.batch(volumeID: "vol-external", directory: "外置", paths: ["说明.txt"])
            )
        }

        let reopened = try CatalogStore(databaseURL: databaseURL)
        #expect(
            try await paths(reopened) == ["文档", "文档/报告.pdf", "预算.xlsx", "外置", "外置/说明.txt"],
            "重启后索引必须保留"
        )
        #expect(try await reopened.volumes().count == 2)
    }

    @Test("checkpoint 与补扫责任一起跨重启保留")
    func checkpointAndPendingPathsSurviveReopen() async throws {
        let temporary = try AcceptanceTempDirectory(label: "checkpoint")
        let databaseURL = temporary.path("catalog.sqlite", isDirectory: false)

        do {
            let store = try CatalogStore(databaseURL: databaseURL)
            try await store.registerVolume(AcceptanceFixture.internalVolume())
            #expect(try await store.checkpoint(volumeID: "vol-internal") == nil, "首次使用应无 checkpoint")
            try await store.commitCheckpoint(
                SyncCheckpoint(volumeID: "vol-internal", eventID: 4_096, journalUUID: "journal-acceptance"),
                pendingPaths: ["文档/待补扫", "图片/待补扫"]
            )
        }

        let reopened = try CatalogStore(databaseURL: databaseURL)
        let checkpoint = try #require(try await reopened.checkpoint(volumeID: "vol-internal"))
        #expect(checkpoint.eventID == 4_096)
        #expect(checkpoint.journalUUID == "journal-acceptance")
        #expect(
            try await reopened.pendingPaths(volumeID: "vol-internal") == ["文档/待补扫", "图片/待补扫"],
            "补扫责任必须与 checkpoint 一起持久化，重启后不得丢失"
        )
    }

    @Test("checkpoint 前进时补扫责任整体替换，不出现新旧混搭")
    func commitCheckpointIsAtomicWithPendingPaths() async throws {
        try await withStore { store, _ in
            try await store.commitCheckpoint(
                SyncCheckpoint(volumeID: "vol-internal", eventID: 10, journalUUID: "j1"), pendingPaths: ["a"]
            )
            try await store.commitCheckpoint(
                SyncCheckpoint(volumeID: "vol-internal", eventID: 20, journalUUID: "j1"), pendingPaths: ["b", "c"]
            )

            #expect(try await store.checkpoint(volumeID: "vol-internal")?.eventID == 20)
            #expect(
                try await store.pendingPaths(volumeID: "vol-internal") == ["b", "c"],
                "不允许出现「新 checkpoint + 旧 pending」"
            )
        }
    }

    @Test("清理补扫责任不移动 checkpoint")
    func pendingPathsCanBeClearedWithoutMovingCheckpoint() async throws {
        try await withStore { store, _ in
            try await store.commitCheckpoint(
                SyncCheckpoint(volumeID: "vol-internal", eventID: 7, journalUUID: "j"), pendingPaths: ["a", "b"]
            )
            try await store.setPendingPaths(volumeID: "vol-internal", paths: ["b"])

            #expect(try await store.pendingPaths(volumeID: "vol-internal") == ["b"])
            #expect(try await store.checkpoint(volumeID: "vol-internal")?.eventID == 7)
        }
    }

    @Test("不同卷的 checkpoint 与补扫责任互相隔离")
    func perVolumeCheckpointAndPendingPathsAreIsolated() async throws {
        try await withStore { store, _ in
            try await store.commitCheckpoint(
                SyncCheckpoint(volumeID: "vol-internal", eventID: 100, journalUUID: "ji"),
                pendingPaths: ["internal-only"]
            )
            #expect(try await store.checkpoint(volumeID: "vol-external") == nil)
            #expect(try await store.pendingPaths(volumeID: "vol-external").isEmpty)
        }
    }

    // MARK: - 代际与节点身份

    @Test("连续两次真实改动各自推进一代；幂等重放不推进")
    func generationAdvancesOnEachChangeButNotOnIdempotentReplay() async throws {
        try await withStore { store, temporary in
            let start = try await store.generation()

            let afterFirst = try await store.apply(
                AcceptanceFixture.batch(volumeID: "vol-internal", directory: "", paths: ["第一版.txt"], size: { _ in 1_024 })
            )
            #expect(afterFirst == start + 1, "第一次真实改动应推进且只推进一代")

            let afterSecond = try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-internal", directory: "", paths: ["第一版.txt", "第二版.txt"], size: { $0.contains("第一") ? 1_024 : 2_048 }
                )
            )
            #expect(afterSecond == afterFirst + 1, "第二次真实改动必须继续推进，不能停在同一代")

            // 幂等重放：内容完全一致的重复批次。
            let afterReplay = try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-internal", directory: "", paths: ["第一版.txt", "第二版.txt"], size: { $0.contains("第一") ? 1_024 : 2_048 }
                )
            )
            #expect(afterReplay == afterSecond, "内容未变的重复批次不应推进代际")

            // 语义等价的重放（批次顺序不同、内容相同）也不得推进。
            let afterShuffledReplay = try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-internal", directory: "",
                    paths: ["第二版.txt", "第一版.txt"],
                    size: { path in path.contains("第一") ? 1_024 : 2_048 }
                )
            )
            #expect(afterShuffledReplay == afterSecond, "同一目录内容的等价重放不应推进代际")

            // 真正修改内容时推进。
            let afterEdit = try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-internal", directory: "", paths: ["第二版.txt"], size: { _ in 4_096 }
                )
            )
            #expect(afterEdit == afterSecond + 1, "内容变化必须推进代际")

            // 代际持久化。
            let reopened = try CatalogStore(databaseURL: temporary.path("catalog.sqlite", isDirectory: false))
            #expect(
                try await reopened.generation() == afterEdit,
                "代际必须持久化，重启后不能退回 0，否则旧结果会被误认为最新"
            )
        }
    }

    @Test("删除后重建的同路径条目不复用节点 ID")
    func nodeIdentityIsNotReusedAfterDeletion() async throws {
        try await withStore { store, _ in
            try await store.apply(
                AcceptanceFixture.batch(volumeID: "vol-internal", directory: "", paths: ["临时.txt"], size: { _ in 1_024 })
            )
            let original = try #require(try await store.entries().first { $0.relativePath == "临时.txt" })

            try await store.apply(AcceptanceFixture.batch(volumeID: "vol-internal", directory: "", paths: []))
            try await store.apply(
                AcceptanceFixture.batch(volumeID: "vol-internal", directory: "", paths: ["临时.txt"], size: { _ in 2_048 })
            )
            let recreated = try #require(try await store.entries().first { $0.relativePath == "临时.txt" })

            #expect(
                original.key.nodeID != recreated.key.nodeID,
                "同路径重建后节点 ID 不得复用，否则旧选区/滚动锚点会指向新文件"
            )
            #expect(recreated.size == 2_048, "重建后应写入新内容")
        }
    }

    @Test("Unicode 文件名逐字节往返，重启后不变")
    func unicodeNamesRoundTripThroughSQLiteUnchanged() async throws {
        let temporary = try AcceptanceTempDirectory(label: "unicode")
        let databaseURL = temporary.path("catalog.sqlite", isDirectory: false)
        let names = [
            "Café 报告.pdf",                 // 预组合 é
            "Cafe\u{301} 报告.pdf",           // 分解形式
            "emoji-🚀-文件.txt",
            "空格 与\t制表符.txt",
            "引号\"测试\".txt",
            "半角ｆｕｌｌｗｉｄｔｈ.txt",
        ]

        do {
            let store = try CatalogStore(databaseURL: databaseURL)
            try await store.registerVolume(AcceptanceFixture.internalVolume())
            try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-internal", directory: "",
                    paths: ["国际"], isDirectory: { _ in true }
                )
            )
            try await store.apply(
                AcceptanceFixture.batch(
                    volumeID: "vol-internal", directory: "国际",
                    paths: names.map { "国际/\($0)" }
                )
            )
            #expect(try await store.entries().filter { !$0.isDirectory }.map { Array($0.name.utf8) }.sorted { $0.lexicographicallyPrecedes($1) } == names.map { Array($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) })
        }

        let reopened = try CatalogStore(databaseURL: databaseURL)
        #expect(
            try await reopened.entries().filter { !$0.isDirectory }.map { Array($0.name.utf8) }.sorted { $0.lexicographicallyPrecedes($1) } == names.map { Array($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) },
            "文件名必须逐字节往返，不得被规范化或转义破坏"
        )
    }

    @Test("向未登记卷写入会失败且不落数据")
    func applyToUnknownVolumeFails() async throws {
        try await withStore { store, _ in
            await #expect(throws: (any Error).self) {
                try await store.apply(
                    AcceptanceFixture.batch(volumeID: "vol-not-registered", directory: "", paths: ["x.txt"])
                )
            }
            let entries = try await store.entries()
            #expect(entries.isEmpty, "未登记卷的批次不得部分落库")
        }
    }
}
