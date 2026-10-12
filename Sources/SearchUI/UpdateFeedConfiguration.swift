import Foundation
import SearchCore

/// 从 Info.plist 读取更新配置（纯逻辑，不依赖 Sparkle，可直接单测）。
///
/// 读取键沿用 Sparkle 2.10 的约定，三者含义**不同**，不要混用：
/// - `SUFeedURL`：HTTPS appcast 地址（必需）。
/// - `SUPublicEDKey`：Ed25519 更新公钥（必需，且必须是 32 字节 Base64）。
/// - `SUAllowsAutomaticUpdates`：是否允许**自动下载**更新（可选）。
/// - `SUEnableAutomaticChecks`：是否**跳过首次许可询问**直接允许自动检查（可选，默认不写，
///   以保留 Sparkle 在第二次启动时询问用户的许可机制）。
///
/// 任何一项缺失或不合法都视为「未配置更新」，界面必须明确禁用更新，
/// 而不是退回本地自制下载执行器。
public struct UpdateFeedConfiguration: Sendable, Equatable {
    public let feedURL: URL
    public let publicEDKey: String
    /// 允许后台自动下载更新（Info.plist: SUAllowsAutomaticUpdates）。
    public let allowsAutomaticDownload: Bool
    /// 跳过首次许可询问（Info.plist: SUEnableAutomaticChecks）。
    public let enablesAutomaticChecksWithoutPrompt: Bool

    /// 只说明本机配置完整，不代表已经连上更新服务器。
    public var statusText: String { "更新已配置：\(feedURL.host ?? feedURL.absoluteString)" }

    public init(
        feedURL: URL,
        publicEDKey: String,
        allowsAutomaticDownload: Bool = false,
        enablesAutomaticChecksWithoutPrompt: Bool = false
    ) {
        self.feedURL = feedURL
        self.publicEDKey = publicEDKey
        self.allowsAutomaticDownload = allowsAutomaticDownload
        self.enablesAutomaticChecksWithoutPrompt = enablesAutomaticChecksWithoutPrompt
    }
}

/// 未配置更新时的原因与中文说明。
public enum UpdateConfigurationIssue: String, Sendable, Equatable, CaseIterable {
    case missingFeedURL
    case malformedFeedURL
    case insecureFeedURL
    case missingPublicKey
    case malformedPublicKey

    /// 白话短标题（2–5 字）。
    public var title: String {
        switch self {
        case .missingFeedURL: return "缺少更新源"
        case .malformedFeedURL: return "更新源无效"
        case .insecureFeedURL: return "需安全连接"
        case .missingPublicKey: return "缺少验证"
        case .malformedPublicKey: return "验证无效"
        }
    }

    /// 白话说明。缺配置时根本没有联网检查，所以只说「已停用」，不说「暂无更新」。
    public var message: String {
        let reason: String
        switch self {
        case .missingFeedURL: reason = "未配置更新服务器地址。"
        case .malformedFeedURL: reason = "更新服务器地址格式有误。"
        case .insecureFeedURL: reason = "更新网址必须使用 HTTPS。"
        case .missingPublicKey: reason = "更新验证信息缺失。"
        case .malformedPublicKey: reason = "更新验证信息格式有误。"
        }
        return "\(title)：\(reason)自动更新已停用。"
    }

    /// 给开发者排查用的配置键说明（只在本机「详情」里展示）。
    public var technicalDetail: String {
        switch self {
        case .missingFeedURL:
            return "Info.plist 缺少 SUFeedURL。"
        case .malformedFeedURL:
            return "SUFeedURL 无法解析为 URL。"
        case .insecureFeedURL:
            return "SUFeedURL 不是 https:// 地址。"
        case .missingPublicKey:
            return "Info.plist 缺少 SUPublicEDKey。"
        case .malformedPublicKey:
            return "SUPublicEDKey 必须是 32 字节 Ed25519 公钥的 Base64。"
        }
    }

    public var isMissing: Bool {
        self == .missingFeedURL || self == .missingPublicKey
    }
}

public enum UpdateFeedReader {
    public static let feedKey = "SUFeedURL"
    public static let publicKey = "SUPublicEDKey"
    public static let automaticDownloadKey = "SUAllowsAutomaticUpdates"
    public static let enableAutomaticChecksKey = "SUEnableAutomaticChecks"

    /// Ed25519 公钥必须是 32 字节；Base64 编码后为 44 个字符（含结尾 '='）。
    public static func isValidPublicEDKey(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count == 44 else { return false }
        guard let data = Data(base64Encoded: trimmed, options: [.ignoreUnknownCharacters]) else { return false }
        return data.count == 32
    }

    /// 解析更新配置。`nil` 表示未配置；第二个返回值说明原因。
    public static func read(
        infoDictionary: [String: Any],
        allowsInsecureTransport: Bool = false
    ) -> (configuration: UpdateFeedConfiguration?, issue: UpdateConfigurationIssue?) {
        let rawFeed = (infoDictionary[feedKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if rawFeed.isEmpty { return (nil, .missingFeedURL) }
        guard let url = URL(string: rawFeed), url.scheme != nil, url.host?.isEmpty == false else {
            return (nil, .malformedFeedURL)
        }
        let scheme = url.scheme?.lowercased()
        if scheme != "https", !(allowsInsecureTransport && scheme == "http") {
            return (nil, .insecureFeedURL)
        }

        let rawKey = (infoDictionary[publicKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if rawKey.isEmpty { return (nil, .missingPublicKey) }
        // 公钥不合法时绝不放行：否则等于用一个没法校验的 key 去接受更新。
        guard isValidPublicEDKey(rawKey) else { return (nil, .malformedPublicKey) }

        return (UpdateFeedConfiguration(
            feedURL: url,
            publicEDKey: rawKey,
            allowsAutomaticDownload: boolValue(infoDictionary[automaticDownloadKey]) ?? false,
            enablesAutomaticChecksWithoutPrompt: boolValue(infoDictionary[enableAutomaticChecksKey]) ?? false
        ), nil)
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let flag = value as? Bool { return flag }
        if let flag = value as? NSNumber { return flag.boolValue }
        return nil
    }
}

/// 发布快照的版本向量：每个索引库的持久代际 + 卷状态。
///
/// 用来判断「这次是否真的需要重建快照」。**不能**用条目数之类的粗略信号：
/// 同数量的改名/移动/大小变化必须被识别成变化。
public struct PublishVersionVector: Sendable, Equatable {
    public var generations: [String: UInt64]
    public var volumes: [VolumeRecord]

    public init(generations: [String: UInt64], volumes: [VolumeRecord]) {
        self.generations = generations
        self.volumes = volumes
    }

    public static let empty = PublishVersionVector(generations: [:], volumes: [])

    public var isEmpty: Bool { generations.isEmpty && volumes.isEmpty }
}

/// 发布决策。抽成纯类型便于单测，并且 App 侧真的用它决定行为。
public enum PublishDecision: Sendable, Equatable {
    /// 版本向量与上次成功发布相同：不重建、不重跑搜索（幂等）。
    case skipUnchanged
    /// 需要用新读取的条目重建快照。
    case publish
    /// 读取过程中索引又变了：这一轮结果已经可能错代，重跑一次。
    case retryAfterChange
    /// 读取失败：保留上一次快照，不发布半截数据。
    case keepPreviousSnapshot
}

public enum PublishPlanner {
    /// - Parameters:
    ///   - previous: 上一次成功发布时使用的版本向量（没有则 nil）。
    ///   - readFailed: 任一索引库读取失败。
    ///   - before: 读取条目之前采样到的版本向量。
    ///   - after: 读取条目之后采样到的版本向量。
    public static func decide(
        previous: PublishVersionVector?,
        readFailed: Bool,
        before: PublishVersionVector,
        after: PublishVersionVector
    ) -> PublishDecision {
        // 任何一卷读失败都不能发布部分快照，哪怕已经读到了别的卷。
        if readFailed { return .keepPreviousSnapshot }
        // 读条目的过程中扫描又推进了代际：这次读到的可能是混合状态。
        if before != after { return .retryAfterChange }
        // 完全没变：跳过重建。这是幂等路径，不是「同数量就跳过」。
        if let previous, previous == after { return .skipUnchanged }
        return .publish
    }
}
