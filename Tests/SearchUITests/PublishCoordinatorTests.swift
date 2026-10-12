import Foundation
import Testing
@testable import SearchUI
import SearchCore

/// 发布协调器测试：走的是 App 真正使用的状态机（PublishCoordinator），
/// 而不只是枚举决策。
@Suite("发布协调器")
struct PublishCoordinatorTests {

    private func vector(_ a: UInt64, _ b: UInt64? = nil, online: Bool = true) -> PublishVersionVector {
        var generations: [String: UInt64] = ["vol-a": a]
        if let b { generations["vol-b"] = b }
        return PublishVersionVector(
            generations: generations,
            volumes: [
                VolumeRecord(id: "vol-a", name: "内置盘", rootPath: "/", isOnline: online),
                VolumeRecord(id: "vol-b", name: "外置盘", rootPath: "/Volumes/Ext", isOnline: online),
            ]
        )
    }

    @Test("首次进入：未发布过任何内容时不算未变")
    func notUnchangedBeforeFirstPublish() {
        let coordinator = PublishCoordinator()
        #expect(coordinator.isUnchanged(sampled: vector(1)) == false)
    }

    @Test("发布后同一版本向量：读全库之前就跳过")
    func unchangedIsSkippedBeforeReading() {
        var coordinator = PublishCoordinator()
        let v = vector(7)
        #expect(coordinator.decide(readFailedBefore: false, before: v, readFailedAfter: false, after: v) == .published)
        coordinator.didPublish(v)
        #expect(coordinator.isUnchanged(sampled: v) == true)
    }

    @Test("同数量改名/移动：代际推进必须重新发布")
    func sameCountChangeMustPublish() {
        var coordinator = PublishCoordinator()
        let previous = vector(7)
        let now = vector(8)
        #expect(coordinator.decide(readFailedBefore: false, before: previous, readFailedAfter: false, after: previous) == .published)
        coordinator.didPublish(previous)

        #expect(coordinator.decide(readFailedBefore: false, before: now, readFailedAfter: false, after: now) == .published,
                "条目总数没变也必须重新发布")
    }

    @Test("读取期间推进：返回需要重跑，并安排有上限的重试")
    func retryIsScheduledAndBounded() {
        var coordinator = PublishCoordinator()
        let previous = vector(7)
        let before = vector(8)
        let after = vector(9)

        #expect(coordinator.decide(readFailedBefore: false, before: before, readFailedAfter: false, after: after) == .retryNeeded)
        #expect(coordinator.allowsAnotherRetry == true)
        #expect(coordinator.consecutiveRetries == 1)

        // 连续推进时不能变成忙循环
        for _ in 0..<8 {
            _ = coordinator.decide(readFailedBefore: false, before: before, readFailedAfter: false, after: after)
        }
        #expect(coordinator.allowsAnotherRetry == false, "必须存在重试上限，避免忙循环")
        #expect(coordinator.consecutiveRetries == PublishCoordinator.maxConsecutiveRetries)
    }

    @Test("重试后成功发布会重置计数")
    func successfulPublishResetsRetryBudget() {
        var coordinator = PublishCoordinator()
        let before = vector(8)
        _ = coordinator.decide(readFailedBefore: false, before: before, readFailedAfter: false, after: vector(9))
        #expect(coordinator.consecutiveRetries == 1)
        let stable = vector(10)
        #expect(coordinator.decide(readFailedBefore: false, before: stable, readFailedAfter: false, after: stable) == .published)
        coordinator.didPublish(stable)
        #expect(coordinator.consecutiveRetries == 0)
        #expect(coordinator.allowsAnotherRetry == true)
        #expect(coordinator.isUnchanged(sampled: stable) == true)
    }

    @Test("读取前采样失败：保留旧快照，不进入读取")
    func samplingFailureKeepsPrevious() {
        var coordinator = PublishCoordinator()
        let v = vector(7)
        coordinator.didPublish(v)
        #expect(coordinator.handleSamplingFailure() == .keptPreviousSnapshot)
        #expect(coordinator.isUnchanged(sampled: v) == true, "失败不应作废上次成功的发布记录")
    }

    @Test("读取失败（读前或读后）都保留旧快照")
    func readFailureEitherSideKeepsPrevious() {
        var coordinator = PublishCoordinator()
        let v = vector(7)
        coordinator.didPublish(v)
        #expect(coordinator.decide(readFailedBefore: true, before: v, readFailedAfter: false, after: v) == .keptPreviousSnapshot)
        #expect(coordinator.decide(readFailedBefore: false, before: v, readFailedAfter: true, after: v) == .keptPreviousSnapshot)
        #expect(coordinator.isUnchanged(sampled: v) == true)
    }

    @Test("读取失败优先于版本推进")
    func readFailureWinsOverChange() {
        var coordinator = PublishCoordinator()
        let before = vector(7)
        let after = vector(9)
        #expect(coordinator.decide(readFailedBefore: false, before: before, readFailedAfter: true, after: after) == .keptPreviousSnapshot)
        #expect(coordinator.consecutiveRetries == 0)
    }

    @Test("卷状态变化也要重新发布")
    func volumeStateChangePublishes() {
        var coordinator = PublishCoordinator()
        let online = vector(7, online: true)
        let offline = vector(7, online: false)
        coordinator.didPublish(online)
        #expect(coordinator.isUnchanged(sampled: offline) == false)
        #expect(coordinator.decide(readFailedBefore: false, before: offline, readFailedAfter: false, after: offline) == .published)
    }
}