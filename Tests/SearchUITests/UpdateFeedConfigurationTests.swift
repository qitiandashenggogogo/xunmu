import Foundation
import Testing
@testable import SearchUI
import SearchCore

/// 更新配置解析测试（纯逻辑，不加载 Sparkle、不联网）。
@Suite("更新配置")
struct UpdateFeedConfigurationTests {

    /// 32 字节 Ed25519 公钥的合法 Base64（测试用假值，不是真公钥）。
    private let validKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    private let invalidKey = "not-a-32-byte-ed25519-public-key-base64"

    @Test("配置齐全时启用")
    func validConfigurationIsEnabled() throws {
        let result = UpdateFeedReader.read(infoDictionary: [
            UpdateFeedReader.feedKey: "https://example.github.io/macanything/appcast.xml",
            UpdateFeedReader.publicKey: validKey,
        ])
        let configuration = try #require(result.configuration, "应当启用更新：\(String(describing: result.issue))")
        #expect(result.issue == nil)
        #expect(configuration.feedURL.scheme == "https")
        #expect(configuration.publicEDKey == validKey)
        #expect(configuration.statusText.contains("更新已配置"))
        // 只代表本机配置完整，不能说成已连上服务器。
        #expect(!configuration.statusText.contains("已连接"))
    }

    @Test("公钥必须是 32 字节 Base64")
    func publicKeyMustBe32Bytes() {
        #expect(UpdateFeedReader.isValidPublicEDKey(validKey) == true)
        #expect(UpdateFeedReader.isValidPublicEDKey(invalidKey) == false)
        #expect(UpdateFeedReader.isValidPublicEDKey("") == false)
        // 长度对但不是合法 Base64 载荷
        #expect(UpdateFeedReader.isValidPublicEDKey(String(repeating: "A", count: 44)) == false)

        let result = UpdateFeedReader.read(infoDictionary: [
            UpdateFeedReader.feedKey: "https://example.com/appcast.xml",
            UpdateFeedReader.publicKey: invalidKey,
        ])
        #expect(result.configuration == nil, "公钥不合法时绝不能启用更新")
        #expect(result.issue == .malformedPublicKey)
    }

    @Test("缺更新源时禁用并给出中文原因")
    func missingFeedURLDisables() {
        let result = UpdateFeedReader.read(infoDictionary: [UpdateFeedReader.publicKey: validKey])
        #expect(result.configuration == nil)
        #expect(result.issue == .missingFeedURL)
        #expect(result.issue?.message.contains("未配置更新服务器地址") == true)
        // 配置键名保留在给开发者排查的技术说明里。
        #expect(result.issue?.technicalDetail.contains("SUFeedURL") == true)
    }

    @Test("空字符串等同于缺键")
    func blankValuesCountAsMissing() {
        let result = UpdateFeedReader.read(infoDictionary: [
            UpdateFeedReader.feedKey: "   ",
            UpdateFeedReader.publicKey: "",
        ])
        #expect(result.configuration == nil)
        #expect(result.issue == .missingFeedURL)
    }

    @Test("缺公钥时禁用")
    func missingPublicKeyDisables() {
        let result = UpdateFeedReader.read(infoDictionary: [
            UpdateFeedReader.feedKey: "https://example.github.io/appcast.xml",
        ])
        #expect(result.configuration == nil)
        #expect(result.issue == .missingPublicKey)
    }

    @Test("非 HTTPS 更新源被拒绝", arguments: ["http://example.com/appcast.xml", "ftp://example.com/appcast.xml"])
    func insecureFeedURLIsRejected(feed: String) {
        let result = UpdateFeedReader.read(infoDictionary: [
            UpdateFeedReader.feedKey: feed,
            UpdateFeedReader.publicKey: validKey,
        ])
        #expect(result.configuration == nil)
        #expect(result.issue == .insecureFeedURL)
    }

    @Test("本地开发可显式放开 http")
    func insecureTransportCanBeAllowedExplicitly() throws {
        let result = UpdateFeedReader.read(
            infoDictionary: [
                UpdateFeedReader.feedKey: "http://127.0.0.1:8080/appcast.xml",
                UpdateFeedReader.publicKey: validKey,
            ],
            allowsInsecureTransport: true
        )
        #expect(result.configuration?.feedURL.host == "127.0.0.1")
    }

    @Test("无法解析的地址被拒绝")
    func malformedFeedURLIsRejected() {
        let result = UpdateFeedReader.read(infoDictionary: [
            UpdateFeedReader.feedKey: "not a url",
            UpdateFeedReader.publicKey: validKey,
        ])
        #expect(result.configuration == nil)
        #expect(result.issue == .malformedFeedURL)
    }

    @Test("SUAllowsAutomaticUpdates 与 SUEnableAutomaticChecks 含义分离")
    func automaticKeysAreDistinct() {
        let onlyDownload = UpdateFeedReader.read(infoDictionary: [
            UpdateFeedReader.feedKey: "https://example.com/appcast.xml",
            UpdateFeedReader.publicKey: validKey,
            UpdateFeedReader.automaticDownloadKey: true,
        ])
        #expect(onlyDownload.configuration?.allowsAutomaticDownload == true)
        #expect(onlyDownload.configuration?.enablesAutomaticChecksWithoutPrompt == false,
                "允许自动下载不等于跳过首次许可询问")

        let onlyPrompt = UpdateFeedReader.read(infoDictionary: [
            UpdateFeedReader.feedKey: "https://example.com/appcast.xml",
            UpdateFeedReader.publicKey: validKey,
            UpdateFeedReader.enableAutomaticChecksKey: NSNumber(value: true),
        ])
        #expect(onlyPrompt.configuration?.allowsAutomaticDownload == false)
        #expect(onlyPrompt.configuration?.enablesAutomaticChecksWithoutPrompt == true)
    }

    @Test("默认两个开关都不开，保留 Sparkle 的首次许可机制")
    func automaticChecksDefaultOff() {
        let result = UpdateFeedReader.read(infoDictionary: [
            UpdateFeedReader.feedKey: "https://example.com/appcast.xml",
            UpdateFeedReader.publicKey: validKey,
        ])
        #expect(result.configuration?.allowsAutomaticDownload == false)
        #expect(result.configuration?.enablesAutomaticChecksWithoutPrompt == false)
    }

    @Test("空 Info.plist 明确禁用")
    func emptyInfoDictionaryDisables() {
        let result = UpdateFeedReader.read(infoDictionary: [:])
        #expect(result.configuration == nil)
        #expect(result.issue == .missingFeedURL)
        #expect(result.issue?.isMissing == true)
    }

    @Test("每种缺失都有可展示的中文说明")
    func everyIssueHasMessage() {
        for issue in UpdateConfigurationIssue.allCases {
            #expect(!issue.message.isEmpty)
            #expect(issue.message.contains("自动更新已停用"))
            #expect((2...5).contains(issue.title.count), "标题应为 2–5 字：\(issue.title)")
            #expect(!issue.technicalDetail.isEmpty)
            // 缺配置时根本没联网检查，绝不能说成「暂无更新 / 已是最新」。
            #expect(!issue.message.contains("暂无更新"))
            #expect(!issue.message.contains("最新"))
        }
    }
}

/// 发布决策测试：这些用例专门用来区分「看起来能用」的错误实现。
@Suite("发布决策")
struct PublishPlannerTests {

    private func vector(v1: UInt64, v2: UInt64 = 0, online: Bool = true) -> PublishVersionVector {
        PublishVersionVector(
            generations: v1 == 0 ? [:] : ["vol-a": v1].merging(v2 == 0 ? [:] : ["vol-b": v2]) { a, _ in a },
            volumes: [
                VolumeRecord(id: "vol-a", name: "内置盘", rootPath: "/", isOnline: online),
                VolumeRecord(id: "vol-b", name: "外置盘", rootPath: "/Volumes/Ext", isOnline: online),
            ]
        )
    }

    @Test("首次发布")
    func firstPublish() {
        let v = vector(v1: 1)
        #expect(PublishPlanner.decide(previous: nil, readFailed: false, before: v, after: v) == .publish)
    }

    @Test("幂等：版本向量未变则不重建")
    func idempotentWhenNothingChanged() {
        let v = vector(v1: 7)
        let previous = v
        #expect(PublishPlanner.decide(previous: previous, readFailed: false, before: v, after: v) == .skipUnchanged)
    }

    @Test("同数量改名/移动：代际推进必须重新发布（条目数判定会漏）")
    func sameCountButGenerationMovedMustPublish() {
        // 上次发布在 v7；扫描把 v7 改成 v8（例如改名/移动，条目总数不变）；
        // 本轮读条目前后都稳定在 v8。
        let previous = vector(v1: 7)
        let before = vector(v1: 8)
        let after = vector(v1: 8)
        #expect(PublishPlanner.decide(previous: previous, readFailed: false, before: before, after: after) == .publish,
                "同数量的改名/移动必须重新发布，按条目数判定会漏")
    }

    @Test("卷状态变化也要重新发布")
    func volumeStateChangeMustPublish() {
        let previous = vector(v1: 7, online: true)
        let before = vector(v1: 7, online: false)
        let after = vector(v1: 7, online: false)
        #expect(before == after, "本轮读取期间卷状态是稳定的")
        #expect(previous != after, "相对上次发布，卷状态变了")
        #expect(PublishPlanner.decide(previous: previous, readFailed: false, before: before, after: after) == .publish)
    }

    @Test("任意一卷读取失败都保留旧快照")
    func anyVolumeReadFailureKeepsPreviousSnapshot() {
        let v = vector(v1: 7, v2: 3)
        #expect(PublishPlanner.decide(previous: v, readFailed: true, before: v, after: v) == .keepPreviousSnapshot)
        // 即使版本向量没变，读取失败也不能「跳过」当作没事发生
        #expect(PublishPlanner.decide(previous: nil, readFailed: true, before: v, after: v) == .keepPreviousSnapshot)
    }

    @Test("读取期间扫描推进：不发布错代数据")
    func generationMovedDuringReadDoesNotPublish() {
        let before = vector(v1: 7)
        let after = vector(v1: 9)
        let decision = PublishPlanner.decide(previous: before, readFailed: false, before: before, after: after)
        #expect(decision == .retryAfterChange)
        #expect(decision != .publish, "横跨两代的 entries 绝不能拿去构建快照")
    }

    @Test("读取失败优先于版本变化")
    func readFailureWinsOverVersionChange() {
        let before = vector(v1: 7)
        let after = vector(v1: 9)
        #expect(PublishPlanner.decide(previous: before, readFailed: true, before: before, after: after) == .keepPreviousSnapshot)
    }
}