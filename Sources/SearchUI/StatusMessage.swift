import Foundation

/// 状态栏消息：先给白话短提示，系统给出的详细信息单独保留。
///
/// - `text` 是固定的白话说明，可以带计数、磁盘名、路径这类变量；
/// - `detail` 原样保存系统详细信息（例如 `error.localizedDescription`），
///   只在本机界面里通过「详情」查看，**不写进诊断记录、不写日志、不上传**。
public struct StatusMessage: Equatable, Sendable {
    public let text: String
    public let detail: String?

    public init(_ text: String, detail: String? = nil) {
        self.text = text
        // 只有全是空白时才当作没有详情；否则原样保存，不裁剪。
        let isBlank = detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        self.detail = isBlank ? nil : detail
    }

    /// 白话短提示 + 系统原文。
    public static func failure(_ text: String, error: Error) -> StatusMessage {
        StatusMessage(text, detail: error.localizedDescription)
    }
}
