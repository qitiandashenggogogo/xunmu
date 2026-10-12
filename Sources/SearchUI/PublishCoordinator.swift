import Foundation
import SearchCore

/// 单次发布的执行结果。
public enum PublishPassOutcome: Sendable, Equatable {
    /// 用新条目重建了快照，并重跑了搜索。
    case published
    /// 版本向量与上次成功发布一致：什么都没做（幂等）。
    case skippedUnchanged
    /// 任一索引库读取失败：保留上一次快照。
    case keptPreviousSnapshot
    /// 读取期间代际推进，这一轮结果作废，需要再来一轮。
    case retryNeeded
}

/// 发布协调器：App 真正使用的状态机，不是只测枚举的摆设。
///
/// 它负责三件容易出错的事：
/// 1. 幂等：版本向量与上次成功发布一致时不重建、不重跑搜索。
/// 2. 不发布半截数据：任意一卷读取失败（**包括缺少 store**）都保留旧快照。
/// 3. 读取期间代际推进时不发布错代结果，并且安排**有上限**的重跑，
///    既不会丢掉最后一次触发，也不会在繁忙索引下变成忙循环。
public struct PublishCoordinator: Sendable {
    /// 连续重试上限。超过后放弃重跑，等待下一次真实触发（例如扫描结束或挂载事件）。
    public static let maxConsecutiveRetries = 3

    public private(set) var lastPublished: PublishVersionVector?
    public private(set) var consecutiveRetries: Int = 0

    public init() {}

    /// 记录一次成功的发布。
    public mutating func didPublish(_ vector: PublishVersionVector) {
        lastPublished = vector
        consecutiveRetries = 0
    }

    /// 版本向量是否与上次成功发布完全一致（读全库之前就可以判断）。
    public func isUnchanged(sampled vector: PublishVersionVector) -> Bool {
        guard let lastPublished else { return false }
        return lastPublished == vector
    }

    /// 读取前采样失败时不进入读取。
    public mutating func handleSamplingFailure() -> PublishPassOutcome {
        consecutiveRetries = 0
        return .keptPreviousSnapshot
    }

    /// 读取之后做决策。`readFailedBefore` 与 `readFailedAfter` 任一为真都视为失败。
    public mutating func decide(
        readFailedBefore: Bool,
        before: PublishVersionVector,
        readFailedAfter: Bool,
        after: PublishVersionVector
    ) -> PublishPassOutcome {
        let decision = PublishPlanner.decide(
            previous: lastPublished,
            readFailed: readFailedBefore || readFailedAfter,
            before: before,
            after: after
        )
        switch decision {
        case .keepPreviousSnapshot:
            consecutiveRetries = 0
            return .keptPreviousSnapshot
        case .skipUnchanged:
            consecutiveRetries = 0
            return .skippedUnchanged
        case .retryAfterChange:
            // 封顶：即使上游继续调用，计数也不会无限增长。
            consecutiveRetries = min(consecutiveRetries + 1, PublishCoordinator.maxConsecutiveRetries)
            return .retryNeeded
        case .publish:
            consecutiveRetries = 0
            return .published
        }
    }

    /// 是否还允许立刻再跑一轮。上限用尽后返回 false，等待下一次真实触发。
    public var allowsAnotherRetry: Bool {
        consecutiveRetries < PublishCoordinator.maxConsecutiveRetries
    }

    /// 重置重试预算（保留上次成功发布的版本向量）。
    ///
    /// 延迟重试开始前必须调用：否则 `consecutiveRetries` 一直卡在上限，
    /// 索引稳定后也拿不到新的重试机会。
    public mutating func resetRetryBudget() {
        consecutiveRetries = 0
    }
}