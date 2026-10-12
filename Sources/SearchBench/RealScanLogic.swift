import Foundation
import Darwin
import SearchCore

// 真实盘只读验收路线的**纯逻辑**部分。
//
// 单独成文件是为了让每一条判定都能被单独审阅与单独验证：
// 这些函数没有 IO、没有可变状态，只吃值、返回值。
// AcceptanceTests directly imports SearchBench to exercise these production rules.

// MARK: - 卷 / 设备身份

enum VolumeIdentity {
    /// `stat(2)` 的 st_dev：这是设备/文件系统身份，不是路径层级。
    ///
    /// 目录层级说明不了任何事 —— `/Volumes/盘/索引.sqlite` 与 `/Volumes/盘/照片`
    /// 前缀上分不出区别，但两者在同一个设备上。所以必须比设备。
    static func deviceID(ofPath path: String) -> UInt64? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return UInt64(bitPattern: Int64(info.st_dev))
    }

    static func volumeUUID(ofPath path: String) -> String? {
        StableVolumeIdentity.identifier(for: URL(fileURLWithPath: path, isDirectory: true))
    }

}

// MARK: - 索引落盘位置的安全判定

enum ReportLocationSafety {
    enum Decision: Equatable {
        /// 索引可以放在这里。
        case allowed
        /// 索引位置与扫描根在同一设备：会把索引写进被扫描的盘。
        case sameDeviceAsScanRoot
        /// 有一方拿不到可靠身份：无法证明安全，按不安全处理。
        case identityUnavailable

        var isAllowed: Bool { self == .allowed }

        var message: String {
            switch self {
            case .allowed:
                return "索引位置与扫描根不在同一设备"
            case .sameDeviceAsScanRoot:
                return """
                拒绝执行：--report-dir 与 --real-root 位于同一个设备（同一 st_dev、同一卷 UUID）。
                把索引写在被扫描的盘上既污染用户数据，也会让该盘的扫描结果把索引自己再扫进去。
                请把 --report-dir 指到本机磁盘上的目录。
                """
            case .identityUnavailable:
                return """
                拒绝执行：无法确定 --report-dir 或 --real-root 的设备/卷身份。
                无法证明索引不会落到扫描卷上时，一律按不安全处理（不猜、不放行）。
                """
            }
        }
    }

    /// 判定规则（两条都过才放行）：
    /// 1. 两边都要拿得到 `st_dev`，且不相等；
    /// 2. 两边都要拿得到卷 UUID，且不相等。
    /// 任何一条缺失都按 `identityUnavailable` 拒绕，不做“看起来没问题”的放行。
    static func decide(
        scanRootDeviceID: UInt64?,
        reportDirDeviceID: UInt64?,
        scanRootVolumeUUID: String?,
        reportDirVolumeUUID: String?
    ) -> Decision {
        guard let scanRootDeviceID, let reportDirDeviceID,
              let scanRootVolumeUUID, let reportDirVolumeUUID
        else { return .identityUnavailable }
        guard !scanRootVolumeUUID.isEmpty, !reportDirVolumeUUID.isEmpty else { return .identityUnavailable }

        if scanRootDeviceID == reportDirDeviceID || scanRootVolumeUUID == reportDirVolumeUUID {
            return .sameDeviceAsScanRoot
        }
        return .allowed
    }
}

// MARK: - 校验遍（第二遍纯元数据扫描）的差异

struct EntryFingerprint: Equatable {
    var isDirectory: Bool
    var size: Int64
    var modifiedAtSeconds: Int

    static func make(_ entry: ScannedEntry) -> EntryFingerprint {
        EntryFingerprint(
            isDirectory: entry.isDirectory,
            size: entry.size,
            modifiedAtSeconds: Int(entry.modifiedAt.timeIntervalSince1970.rounded())
        )
    }
}

struct VerifyPassDiff: Equatable {
    /// 第一遍没有、第二遍出现。
    var added: Int
    /// 第一遍有、第二遍没有。
    var removed: Int
    /// 两边都有，但大小/修改时间/类型不同。
    var changed: Int
    /// 完全一致。
    var unchanged: Int

    var totalChanges: Int { added + removed + changed }
}

enum VerifyPass {
    /// 逐项比较两遍扫描的目录集合。
    ///
    /// 结果**不是**算法成败的判据：如果扫描期间这个盘本身在被人动（拷照片、删旧文件），
    /// 差异数就是真实发生的变化。所以调用方只把它当“实际变更数”报告，
    /// 不因为非零就判定算法失败。
    static func diff(
        first: [String: EntryFingerprint],
        second: [String: EntryFingerprint]
    ) -> VerifyPassDiff {
        var added = 0
        var removed = 0
        var changed = 0
        var unchanged = 0

        for (path, fingerprint) in second {
            guard let before = first[path] else {
                added += 1
                continue
            }
            if before == fingerprint {
                unchanged += 1
            } else {
                changed += 1
            }
        }
        removed = first.count - (unchanged + changed)

        return VerifyPassDiff(added: added, removed: removed, changed: changed, unchanged: unchanged)
    }
}

// MARK: - 查询集合

struct RealQueryCase: Equatable {
    var id: String
    var label: String
    var text: String
}

enum RealQueryCases {
    /// 真实盘验收固定用这几条：单字中文、双字中文、单字母、扩展名、空查询（全量）。
    static let fixed: [RealQueryCase] = [
        RealQueryCase(id: "hanzi-1", label: "单字中文", text: "文"),
        RealQueryCase(id: "hanzi-2", label: "双字中文", text: "报告"),
        RealQueryCase(id: "letter-1", label: "单个拉丁字母", text: "a"),
        RealQueryCase(id: "ext-jpg", label: "扩展名 jpg", text: "jpg"),
        RealQueryCase(id: "all", label: "空查询（全量）", text: ""),
    ]
}

// MARK: - 结果自检

enum ResultSelfCheck {
    static func hasDuplicates(_ keys: [EntryKey]) -> Bool {
        Set(keys).count != keys.count
    }

    /// 重开数据库后同一查询必须给出**完全相同顺序**的键序列。
    /// 顺序变了就意味着排序不稳定或索引读回有问题。
    static func sameKeySequence(_ lhs: [EntryKey], _ rhs: [EntryKey]) -> Bool {
        lhs == rhs
    }
}

// MARK: - 统计

enum Statistics {
    /// 最近秩百分位（nearest-rank）。空样本返回 0。
    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    struct Summary: Equatable {
        var samples: Int
        var minMs: Double
        var p50Ms: Double
        var p95Ms: Double
        var maxMs: Double

        init(_ values: [Double]) {
            let sorted = values.sorted()
            samples = sorted.count
            minMs = sorted.first ?? 0
            maxMs = sorted.last ?? 0
            p50Ms = Statistics.percentile(sorted, 0.50)
            p95Ms = Statistics.percentile(sorted, 0.95)
        }
    }
}

// MARK: - 进度与措辞

enum ScanProgress {
    /// 累计进度行：**只有计数**，没有任何用户文件名。
    /// 进度输出会被主控直接看到，所以这里刻意不拼任何路径。
    static func line(
        elapsedMs: Double,
        directoriesScanned: Int,
        entriesSeen: Int,
        completeBatches: Int,
        failedBatches: Int,
        rowsWritten: Int
    ) -> String {
        String(
            format: "[扫描 %7.1fs] 已扫目录 %d，已见条目 %d，完整批次 %d，失败批次 %d，已写索引行 %d",
            elapsedMs / 1_000,
            directoriesScanned,
            entriesSeen,
            completeBatches,
            failedBatches,
            rowsWritten
        )
    }
}

enum Wording {
    /// 首扫是**首次观察**，不是冷缓存基准：目录树此前可能已被系统或用户访问过。
    static let firstPassNote = """
    first-observed（首次观察）：这是本次运行对目录树的第一次遍历，不是冷缓存基准。
    一次目录遍历就是真实的目录元数据读取（stat/目录枚举），因此包含真实硬盘读，
    不声称“零硬盘读”。重跑同一目录会受系统缓存影响而更快。
    """

    static let verifyPassNote = """
    第二遍是纯元数据扫描（只读目录项元数据，不读文件内容、不写盘）。
    两遍之间的差异数是该盘在这段时间里的真实变化；卷上有并发改动时，
    差异数非零属于正常现象，不据此判定算法失败。
    """

    static let safetyNote = """
    索引数据库只写到 --report-dir 指定的本机目录，并通过 st_dev + 卷 UUID 双重校验，
    确认与 --real-root 不在同一设备后才开始。扫描全程只读：不创建、不修改、不删除
    扫描根下的任何文件，也不改系统设置。
    """
}
