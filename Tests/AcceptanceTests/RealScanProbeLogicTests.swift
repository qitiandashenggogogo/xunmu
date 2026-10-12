import Testing
import Foundation
import Darwin
import SearchCore
import SearchIndex
// SearchBench 的生产函数是 internal（可执行 target），必须 @testable 才能看到。
@testable import SearchBench

// 真实盘验收路线的契约测试，**直接测 SearchBench 的生产函数**（Package.swift 已把
// SearchBench 加入 AcceptanceTests 依赖），因此不存在“镜像实现与真身漂移”的问题。
//
// 覆盖：
//   * 索引落盘位置的安全闸（st_dev + 卷 UUID 双重校验）
//   * 第二遍纯元数据扫描的差异计算
//   * 取消/重开自检判定
//   * 固定查询集与百分位
//   * 进度行只含计数、不含路径
//   * 措辞不夸大声称
//
// 真实外置盘由主控用 `SearchBench --real-root …` 跑；这里只用临时目录与合成输入。

@Suite("真实盘验收 · 落盘位置安全闸")
struct RealScanSafetyRuleTests {

    // ↓↓↓ 以下三个用例是 HEAD 中已存在的有效安全覆盖，本轮曾被误删，现按原断言恢复。
    // 不要因为它们看起来与新用例重复就再删：它们守的是**真实入口的行为**，
    // 而 `sameDeviceIsRefused` 等只测纯函数 `ReportLocationSafety.decide`。

    @Test("只给校验遍开关时拒绝，不能误跑合成基准")
    func realFlagsRequireSourceRoot() async {
        var options = BenchOptions()
        options.verifyPass = true
        #expect(RealScanRunner.isRealMode(options))
        await #expect(throws: RealScanError.self) { _ = try await RealScanRunner.run(options: options) }
    }

    @Test("同一设备（同 st_dev）拒绕")
    func sameDeviceIsRefused() {
        #expect(
            ReportLocationSafety.decide(
                scanRootDeviceID: 16, reportDirDeviceID: 16,
                scanRootVolumeUUID: "uuid-a", reportDirVolumeUUID: "uuid-b"
            ) == .sameDeviceAsScanRoot,
            "同一 st_dev 上落索引就是写在被扫描的盘上，必须拒绕"
        )
    }

    @Test("同一卷 UUID 拒绕，即使 st_dev 读数不同")
    func sameVolumeUUIDIsRefused() {
        #expect(
            ReportLocationSafety.decide(
                scanRootDeviceID: 16, reportDirDeviceID: 99,
                scanRootVolumeUUID: "uuid-a", reportDirVolumeUUID: "uuid-a"
            ) == .sameDeviceAsScanRoot,
            "卷 UUID 相同就是同一个卷，st_dev 读数不同也不能放行"
        )
    }

    @Test("设备与卷 UUID 都不同才放行")
    func differentDeviceAndVolumeIsAllowed() {
        #expect(
            ReportLocationSafety.decide(
                scanRootDeviceID: 16, reportDirDeviceID: 16777220,
                scanRootVolumeUUID: "uuid-a", reportDirVolumeUUID: "uuid-b"
            ) == .allowed
        )
    }

    @Test("任一身份拿不到就拒绕，不做“看起来没问题”的放行")
    func unknownIdentityIsRefused() {
        #expect(
            ReportLocationSafety.decide(
                scanRootDeviceID: nil, reportDirDeviceID: 1,
                scanRootVolumeUUID: "a", reportDirVolumeUUID: "b"
            ) == .identityUnavailable
        )
        #expect(
            ReportLocationSafety.decide(
                scanRootDeviceID: 1, reportDirDeviceID: 1,
                scanRootVolumeUUID: nil, reportDirVolumeUUID: "b"
            ) == .identityUnavailable
        )
        #expect(
            ReportLocationSafety.decide(
                scanRootDeviceID: 1, reportDirDeviceID: 2,
                scanRootVolumeUUID: "a", reportDirVolumeUUID: ""
            ) == .identityUnavailable,
            "空字符串卷 UUID 视为拿不到身份"
        )
    }

    @Test("被拒时给出的理由可执行")
    func refusalMessagesAreActionable() {
        let sameDevice = ReportLocationSafety.decide(
            scanRootDeviceID: 1, reportDirDeviceID: 1,
            scanRootVolumeUUID: "a", reportDirVolumeUUID: "b"
        )
        #expect(!sameDevice.isAllowed)
        // 只断言「可执行」这件事本身：拒绝文案必须点明是哪个参数冲突、且给出下一步。
        // 不绑定具体措辞（“同一个设备” vs “同一设备” 换字不应使测试变红）。
        #expect(sameDevice.message.contains("拒绝执行"))
        #expect(sameDevice.message.contains("--report-dir"))
        #expect(sameDevice.message.contains("--real-root"))

        let unknown = ReportLocationSafety.decide(
            scanRootDeviceID: nil, reportDirDeviceID: nil,
            scanRootVolumeUUID: nil, reportDirVolumeUUID: nil
        )
        #expect(!unknown.isAllowed)
        #expect(unknown.message.contains("设备/卷身份"))
    }

    @Test("目录层级相同不代表同一设备判定失效：真机上用 st_dev 与卷 UUID 判定")
    func hierarchyAloneCannotDecideSafety() throws {
        let temporary = try AcceptanceTempDirectory(label: "identity")

        let nested = try temporary.makeDirectory("报告/预算")
        let scanDevice = try #require(VolumeIdentity.deviceID(ofPath: nested.path))
        let reportDevice = try #require(VolumeIdentity.deviceID(ofPath: temporary.url.path))

        // 同一临时目录下的两条路径：前缀上分不开，只能靠设备身份。
        #expect(scanDevice == reportDevice, "同一临时目录下的路径必然在同一设备上")
        let decision = ReportLocationSafety.decide(
            scanRootDeviceID: scanDevice,
            reportDirDeviceID: reportDevice,
            scanRootVolumeUUID: VolumeIdentity.volumeUUID(ofPath: nested.path),
            reportDirVolumeUUID: VolumeIdentity.volumeUUID(ofPath: temporary.url.path)
        )
        #expect(decision == .sameDeviceAsScanRoot, "同设备的子目录不能拿来放索引")

        // 真实路径的卷 UUID 一定要能取到，否则这条安全闸形同虚设。
        #expect(
            VolumeIdentity.volumeUUID(ofPath: temporary.url.path) != nil,
            "本机临时目录应能取到卷 UUID；若这里失败，说明安全闸会一律拒绕，需要重新设计"
        )
    }

    @Test("同卷位置拒绝时不得先创建报告目录")
    func refusalDoesNotCreateDirectories() async throws {
        let temporary = try AcceptanceTempDirectory(label: "report-safety")
        let target = temporary.url.appendingPathComponent("must-not-create/nested")
        var options = BenchOptions()
        options.realRootPath = temporary.url.path
        options.reportDirPath = target.path
        do {
            _ = try await RealScanRunner.run(options: options)
            Issue.record("同卷位置不应放行")
        } catch let error as RealScanError {
            if case .safetyRefused = error {} else { Issue.record("拒绝原因不符") }
        }
        #expect(!FileManager.default.fileExists(atPath: temporary.url.appendingPathComponent("must-not-create").path))
    }

    @Test("不存在的路径拿不到设备身份")
    func missingPathHasNoIdentity() {
        #expect(VolumeIdentity.deviceID(ofPath: "/definitely/not/here-\(UUID().uuidString)") == nil)
        #expect(VolumeIdentity.volumeUUID(ofPath: "/definitely/not/here-\(UUID().uuidString)") == nil)
    }
}

// MARK: - 第二遍差异计算

@Suite("真实盘验收 · 校验遍差异")
struct VerifyPassDiffRuleTests {

    private func fingerprint(
        isDirectory: Bool = false,
        size: Int64 = 100,
        seconds: Int = 1_700_000_000
    ) -> EntryFingerprint {
        EntryFingerprint(isDirectory: isDirectory, size: size, modifiedAtSeconds: seconds)
    }

    @Test("完全一致时无变更")
    func identicalPassesShowNoChanges() {
        let map = ["a.txt": fingerprint(), "b/c.txt": fingerprint(size: 20)]
        let diff = VerifyPass.diff(first: map, second: map)

        #expect(diff.totalChanges == 0)
        #expect(diff.unchanged == 2)
        #expect(diff.added == 0)
        #expect(diff.removed == 0)
    }

    @Test("新增、消失、变化分别统计")
    func countsEachKindOfChange() {
        let first = [
            "保留.txt": fingerprint(),
            "删掉.txt": fingerprint(),
            "变了.txt": fingerprint(size: 100),
        ]
        let second = [
            "保留.txt": fingerprint(),
            "变了.txt": fingerprint(size: 200),
            "新增.txt": fingerprint(),
        ]
        let diff = VerifyPass.diff(first: first, second: second)

        #expect(diff.added == 1)
        #expect(diff.removed == 1)
        #expect(diff.changed == 1)
        #expect(diff.unchanged == 1)
        #expect(diff.totalChanges == 3)
    }

    @Test("只有新增时删除数仍为零")
    func additionsNeverBecomeNegativeRemovals() {
        let diff = VerifyPass.diff(first: ["a": fingerprint()], second: ["a": fingerprint(), "b": fingerprint()])
        #expect(diff.added == 1)
        #expect(diff.removed == 0)
        #expect(diff.totalChanges == 1)
    }

    @Test("文件变目录算变化")
    func typeChangeCountsAsChange() {
        let first = ["x": fingerprint(isDirectory: false, size: 10)]
        let second = ["x": fingerprint(isDirectory: true, size: 0)]
        #expect(VerifyPass.diff(first: first, second: second).changed == 1)
    }

    @Test("修改时间变化算变化")
    func modificationTimeChangeCountsAsChange() {
        let first = ["x": fingerprint(seconds: 1_700_000_000)]
        let second = ["x": fingerprint(seconds: 1_700_000_060)]
        #expect(VerifyPass.diff(first: first, second: second).changed == 1)
    }

    @Test("第二遍为空时删除数等于第一遍条目数")
    func emptySecondPassHasNoRemovals() {
        let first = ["a": fingerprint(), "b": fingerprint()]
        let diff = VerifyPass.diff(first: first, second: [:])

        #expect(diff.added == 0)
        #expect(diff.removed == 2)
        #expect(diff.totalChanges == 2)
    }

    @Test("指纹由真实条目构造")
    func fingerprintFromScannedEntry() {
        let entry = ScannedEntry(
            relativePath: "a/b.txt", name: "b.txt", isDirectory: false,
            size: 42, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000.4)
        )
        let fingerprint = EntryFingerprint.make(entry)
        #expect(!fingerprint.isDirectory)
        #expect(fingerprint.size == 42)
        #expect(fingerprint.modifiedAtSeconds == 1_700_000_000, "时间戳按整秒比较")
    }
}

// MARK: - 自检与统计规则

@Suite("真实盘验收 · 自检与统计规则")
struct RealScanSelfCheckRuleTests {

    @Test("重复键判定")
    func duplicateDetection() {
        let a = EntryKey(volumeID: "v", nodeID: 1)
        let b = EntryKey(volumeID: "v", nodeID: 2)
        #expect(!ResultSelfCheck.hasDuplicates([a, b]))
        #expect(ResultSelfCheck.hasDuplicates([a, a]))
        #expect(!ResultSelfCheck.hasDuplicates([]))
    }

    @Test("键序列比较要求顺序完全一致")
    func keySequenceComparison() {
        let a = EntryKey(volumeID: "v", nodeID: 1)
        let b = EntryKey(volumeID: "v", nodeID: 2)
        #expect(ResultSelfCheck.sameKeySequence([a, b], [a, b]))
        #expect(!ResultSelfCheck.sameKeySequence([a, b], [b, a]), "顺序不同即为不一致，不能只比集合")
        #expect(!ResultSelfCheck.sameKeySequence([a, b], [a]))
    }

    @Test("固定查询集就是验收承诺的那五条")
    func fixedQuerySetIsTheAgreedOne() {
        #expect(RealQueryCases.fixed.map(\.text) == ["文", "报告", "a", "jpg", ""])
    }

    @Test("百分位用最近秩")
    func percentileNearestRank() {
        let sorted: [Double] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        #expect(Statistics.percentile(sorted, 0.50) == 5)
        #expect(Statistics.percentile(sorted, 0.95) == 10)
        #expect(Statistics.percentile([], 0.5) == 0)
        #expect(Statistics.percentile([42], 0.95) == 42)

        let summary = Statistics.Summary([3, 1, 2])
        #expect(summary.samples == 3)
        #expect(summary.minMs == 1)
        #expect(summary.maxMs == 3)
    }

    @Test("键序列指纹顺序敏感")
    func keySequenceFingerprintIsOrderSensitive() {
        let a = EntryKey(volumeID: "v", nodeID: 1)
        let b = EntryKey(volumeID: "v", nodeID: 2)
        #expect(IndexPerfRunner.sequenceFingerprint([a, b]) == IndexPerfRunner.sequenceFingerprint([a, b]))
        #expect(IndexPerfRunner.sequenceFingerprint([a, b]) != IndexPerfRunner.sequenceFingerprint([b, a]))
    }
}

// MARK: - 进度输出与措辞

@Suite("真实盘验收 · 进度输出与措辞")
struct ScanProgressOutputTests {

    @Test("进度行只含计数，不含任何路径片段")
    func progressLineContainsCountsOnly() {
        let line = ScanProgress.line(
            elapsedMs: 12_345,
            directoriesScanned: 412,
            entriesSeen: 88_120,
            completeBatches: 410,
            failedBatches: 2,
            rowsWritten: 88_120
        )

        #expect(line.contains("412"))
        #expect(line.contains("88120"))
        #expect(!line.contains("/"), "进度行不得出现路径分隔符")
        #expect(!line.contains("Volumes"), "进度行不得出现卷名或挂载点")
    }

    @Test("即使计数很小，行里也没有用户文件名")
    func progressLineHasNoFileNames() {
        let line = ScanProgress.line(
            elapsedMs: 1_000, directoriesScanned: 1, entriesSeen: 1,
            completeBatches: 1, failedBatches: 0, rowsWritten: 1
        )
        for fragment in ["照片", "DSC", "合同", ".jpg", "@"] {
            #expect(!line.contains(fragment), "进度行不得包含 \(fragment) 之类的文件名片段")
        }
    }

    @Test("措辞不夸大声称：首扫是首次观察，目录遍历是真实元数据读")
    func wordingDoesNotOverclaim() {
        #expect(Wording.firstPassNote.contains("first-observed"))
        #expect(Wording.firstPassNote.contains("目录元数据"))
        // 先把**否定引述**去掉再查：本文件里的 `不声称“零硬盘读”` 是在否定它，
        // 直接做子串判断会把它当成“在这里声称零硬盘读”。
        // 要判的是“有没有把零硬盘读当结论说出口”，不是“这句话里有没有这几个字”。
        var unquoted = Wording.firstPassNote
        for quote in ["“", "”", "\""] { unquoted = unquoted.replacingOccurrences(of: quote, with: "") }
        for denial in ["不声称零硬盘读", "不宣称零硬盘读", "不是零硬盘读"] {
            unquoted = unquoted.replacingOccurrences(of: denial, with: "")
        }
        #expect(!unquoted.contains("零硬盘读"), "不得把首扫说成零硬盘读（否定引述也不允许残留该说法）")
        #expect(unquoted.contains("真实的目录元数据读取"), "应明确说明目录遍历就是真实磁盘读")
        #expect(Wording.verifyPassNote.contains("并发改动"))
        #expect(Wording.safetyNote.contains("只读"))
    }
}