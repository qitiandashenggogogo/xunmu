import Foundation
import Testing
@testable import SearchUI
import SearchCore

/// 调度器测试：真实驱动 `PublishScheduler`（不是只测枚举）。
///
/// 时序确定性约定（回归时不靠碰运气，也不靠挂死）：
/// - 延迟唤醒由 `Gate` / `ControlledSleep` 手动放行，不用 `Task.yield()` 撞轮次；
/// - 「真的停在等待上」「等待确实返回了」「调度器真的静默了」都有**确定信号**可等；
/// - 所有等待都带超时（`BoundedWaiter` + suite 级 `.timeLimit`），
///   条件不成立时返回 false 让断言失败，而不是永远悬挂；
/// - 每个闸门在用例收尾都会 `release()`/`drain()`，保证 `CheckedContinuation` 不泄漏。
/// - `Probe` 独立于调度器自报值统计 pass 的并发峰值（`maxConcurrentPasses` 只是旁证）。
///
/// 重试预算的准确语义（容易数错，写在这里固定下来）：
/// `maxImmediateRetries = 3` 指**一轮内连续失败的 pass 总数上限，含首轮**。
/// 首轮返回 `.retryNeeded` 时计数就是 1，因此整轮最多跑 3 次失败的 pass，
/// 第 3 次失败之后才转延迟轮 —— 不是「首轮 + 3 次重试」。
///
/// 重点覆盖：
/// - 达到立即重试上限后，**即使没有任何新的外部触发**，库稳定下来也必须最终发布。
/// - 延迟等待期间到来的新触发不能丢，且最终是真正的 `.published`（之后同代跳过）。
/// - 延迟唤醒与新触发共用 single-flight，`maxConcurrentPasses` 恒为 1。
/// - `await pass()` 期间 `stop()`：不重试、不晚发布。
/// - 持续 pending trigger 被有界延后，不变成忙循环。
@Suite("发布调度", .timeLimit(.minutes(5)))
@MainActor
struct PublishSchedulerTests {

    /// 延迟重试等待的默认闸门：默认关闭，测试显式 `release()`。
    private func makeScheduler(wakeGate: Gate = Gate()) -> PublishScheduler {
        let scheduler = PublishScheduler()
        scheduler.sleep = { _ in await wakeGate.enter() }
        return scheduler
    }

    // MARK: - 立即重试与延迟重试

    @Test("达到立即重试上限后，没有新触发也会延迟重试并最终发布")
    func delayedRetryEventuallyPublishesWithoutNewTrigger() async {
        let wakeGate = Gate()
        defer { wakeGate.release() }
        let scheduler = makeScheduler(wakeGate: wakeGate)
        let probe = Probe()

        let pass: PublishScheduler.Pass = {
            probe.enter()
            defer { probe.leave() }
            // 首轮连续 3 次失败用满预算 → 转延迟轮；延迟轮第 1 次仍失败，第 2 次发布。
            return probe.calls <= 4 ? .retryNeeded : .published
        }

        await scheduler.trigger(pass)
        // 立即重试用满后调度了一次延迟重试；此时还没发布。
        #expect(scheduler.delayedRetryCount == 1, "达到上限必须安排延迟重试，否则最后一次触发会永久丢失")
        #expect(probe.calls == scheduler.maxImmediateRetries, "失败轮数必须恰好等于立即重试预算（含首轮）")
        #expect(scheduler.publishCount == 0)
        #expect(await wakeGate.waitUntilWaiting(), "延迟轮必须真的停在等待上，否则本测试什么都没证明")

        wakeGate.release()
        #expect(await scheduler.waitForQuiescence(), "调度器没有在限定时间内静默")
        #expect(scheduler.publishCount == 1, "没有任何外部触发时也必须最终发布")
        #expect(probe.calls == scheduler.maxImmediateRetries + 2, "延迟轮：第 1 次仍失败，第 2 次发布")
        #expect(scheduler.hasPendingWork == false)
    }

    @Test("延迟等待期间的新触发被消费：真正发布一次后同代跳过")
    func triggerDuringDelayedWaitIsConsumed() async {
        let wakeGate = Gate()
        defer { wakeGate.release() }
        let scheduler = makeScheduler(wakeGate: wakeGate)
        let probe = Probe()
        let stable = PublishVersionVector(generations: ["vol-a": 6], volumes: [])

        // 索引持续推进 → 前 5 轮作废；稳定之后真的发布一次，再之后同代跳过。
        let pass: PublishScheduler.Pass = {
            probe.enter()
            defer { probe.leave() }
            guard probe.calls >= 6 else { return .retryNeeded }
            if scheduler.isUnchanged(sampled: stable) { return .skippedUnchanged }
            scheduler.recordPublished(stable)
            return .published
        }

        await scheduler.trigger(pass)
        #expect(scheduler.delayedRetryCount == 1)
        #expect(probe.calls == scheduler.maxImmediateRetries, "首轮用满预算后转延迟轮")
        #expect(scheduler.publishCount == 0, "不稳定期间不得发布")
        let callsBeforeSecondTrigger = probe.calls

        // 延迟等待期间又来一次触发：必须被消费，而不是被吞掉或另开一轮并发。
        // （第二次触发会取消待醒的延迟轮并立即跑轮，因此第 6 轮才是真正的发布。）
        await scheduler.trigger(pass)
        #expect(probe.calls > callsBeforeSecondTrigger, "等待期间的新触发必须被消费")
        #expect(probe.peakActive == 1, "新触发不得与其它轮并发")
        #expect(scheduler.maxConcurrentPasses == 1, "single-flight 被破坏")

        wakeGate.release() // 放行被取消的延迟轮所占的等待
        #expect(await scheduler.waitForQuiescence(), "调度器没有在限定时间内静默")
        #expect(scheduler.publishCount == 1, "最终必须真正发布一次")
        #expect(probe.calls == 6, "不应该为了发布同一代而多跑轮次")
        #expect(scheduler.hasPendingWork == false)

        // 同代再触发：只跳过，不重建、不再发布。
        let callsBeforeThirdTrigger = probe.calls
        await scheduler.trigger(pass)
        #expect(probe.calls == callsBeforeThirdTrigger + 1, "同代触发也必须被消费（跳过这一轮）")
        #expect(scheduler.publishCount == 1, "同代不得重复构建")
        #expect(scheduler.isUnchanged(sampled: stable), "发布记录必须落在真实版本向量上")
        #expect(scheduler.hasPendingWork == false)
    }

    @Test("延迟轮之前重置重试预算，否则索引稳定后也发不出结果")
    func retryBudgetIsResetBeforeDelayedRound() async {
        let wakeGate = Gate()
        defer { wakeGate.release() }
        let scheduler = makeScheduler(wakeGate: wakeGate)
        let probe = Probe()
        let pass: PublishScheduler.Pass = {
            probe.enter()
            defer { probe.leave() }
            return probe.calls <= 3 ? .retryNeeded : .published
        }
        await scheduler.trigger(pass)
        #expect(scheduler.delayedRetryCount == 1)
        wakeGate.release()
        #expect(await scheduler.waitForQuiescence(), "调度器没有在限定时间内静默")
        #expect(scheduler.publishCount == 1,
                "若未在延迟轮前重置预算，延迟轮的第一遍就会用尽预算而永远发不出结果")
    }

    // MARK: - single-flight

    @Test("延迟唤醒与新触发共用 single-flight：任意时刻只有一轮")
    func delayedWakeSharesSingleFlightWithNewTrigger() async {
        let wakeGate = Gate()
        let insidePass = Gate()
        defer { wakeGate.release(); insidePass.release() }
        let scheduler = makeScheduler(wakeGate: wakeGate)
        let probe = Probe()

        // 第 4 轮是延迟轮的首轮，卡在 pass 内部，等新触发到来。
        let pass: PublishScheduler.Pass = {
            probe.enter()
            if probe.calls == 4 { await insidePass.enter() }
            defer { probe.leave() }
            return probe.calls <= 3 ? .retryNeeded : (probe.calls == 4 ? .published : .skippedUnchanged)
        }

        await scheduler.trigger(pass)
        #expect(scheduler.delayedRetryCount == 1)

        wakeGate.release()
        #expect(await probe.waitForCalls(4), "延迟轮没有进入 pass") // 闸门正被占用

        // 新触发到来：必须被合并，不能开第二轮。
        await scheduler.trigger(pass)
        #expect(probe.calls == 4, "闸门被占用时新触发只能合并，不得并发开新轮")
        #expect(probe.peakActive == 1)
        #expect(scheduler.maxConcurrentPasses == 1)

        insidePass.release()
        #expect(await scheduler.waitForQuiescence(), "调度器没有在限定时间内静默")

        #expect(probe.calls == 5, "被合并的触发必须在干净结束后立刻补跑一次")
        #expect(scheduler.publishCount == 1)
        #expect(probe.peakActive == 1, "整个过程任何时刻只有一轮在跑")
        #expect(scheduler.maxConcurrentPasses == 1)
        #expect(scheduler.hasPendingWork == false)
    }

    // MARK: - 停止

    @Test("stop() 阻止延迟重试：被取消的延迟轮确实返回且不复活")
    func stopPreventsDelayedRetry() async {
        // 用可观察的 sleep：能证明「延迟轮真的停在了等待上」，也能证明
        // 「放行之后它真的返回了」——不再靠断言跑在复活之前蒙对。
        let sleeper = ControlledSleep()
        defer { sleeper.release() }
        let scheduler = PublishScheduler()
        scheduler.sleep = { _ in await sleeper.sleep() }
        var statuses: [String] = []
        scheduler.statusHandler = { statuses.append($0) }

        let probe = Probe()
        let pass: PublishScheduler.Pass = {
            probe.enter()
            defer { probe.leave() }
            return .retryNeeded // 永远不稳定
        }

        await scheduler.trigger(pass)
        #expect(scheduler.delayedRetryCount == 1)
        #expect(await sleeper.waitUntilWaiting(), "延迟轮必须真的停在等待上，否则本测试什么都没证明")
        #expect(sleeper.startCount == 1, "只应有一个延迟轮在等")

        let callsAtStop = probe.calls
        #expect(callsAtStop == scheduler.maxImmediateRetries, "停止前应恰好用满立即重试预算")

        scheduler.stop()
        #expect(scheduler.hasPendingWork == false, "停止后不应残留待处理工作")

        // 放行被取消的延迟轮，并**等它真的从等待中返回**；返回后再断言没有复活。
        sleeper.release()
        #expect(await sleeper.waitUntilFinished(1), "被取消的延迟轮必须真的从等待中返回，不能悬挂")
        #expect(probe.calls == callsAtStop, "停止后不得重跑 pass")
        #expect(scheduler.delayedRetryCount == 1, "停止后不得再安排新的延迟重试")
        #expect(await scheduler.waitForQuiescence(), "停止后调度器必须静默")

        await scheduler.trigger(pass) // 停止后 trigger 直接返回
        #expect(probe.calls == callsAtStop, "停止后新的触发也不得复活调度")
        #expect(scheduler.hasPendingWork == false)
    }

    @Test("await pass 期间 stop：这一轮即使报成功也不得发布")
    func stopDuringPassDoesNotPublishLate() async {
        let insidePass = Gate()
        defer { insidePass.release() }
        let scheduler = makeScheduler()
        let probe = Probe()
        let pass: PublishScheduler.Pass = {
            probe.enter()
            defer { probe.leave() }
            await insidePass.enter()
            return .published // 就绪的一轮：退出后也不得落到界面上
        }

        let trigger = Task { await scheduler.trigger(pass) }
        #expect(await probe.waitForCalls(1), "首轮没有开始")
        scheduler.stop()
        insidePass.release()
        await trigger.value
        #expect(await scheduler.waitForQuiescence(), "调度器没有在限定时间内静默")

        #expect(scheduler.publishCount == 0, "stop 之后不得再发布")
        #expect(scheduler.passCount == 0, "stop 之后这一轮不算完成")
        #expect(scheduler.hasPendingWork == false)
    }

    @Test("await pass 期间 stop：不再重试，也不再安排延迟轮")
    func stopDuringPassDoesNotRetry() async {
        let insidePass = Gate()
        defer { insidePass.release() }
        let scheduler = makeScheduler()
        let probe = Probe()
        let pass: PublishScheduler.Pass = {
            probe.enter()
            defer { probe.leave() }
            await insidePass.enter()
            return .retryNeeded // 退出后也不得因此重试或延后
        }

        let trigger = Task { await scheduler.trigger(pass) }
        #expect(await probe.waitForCalls(1), "首轮没有开始")
        scheduler.stop()
        insidePass.release()
        await trigger.value
        #expect(await scheduler.waitForQuiescence(), "调度器没有在限定时间内静默")

        #expect(probe.calls == 1, "stop 之后不得重试")
        #expect(scheduler.delayedRetryCount == 0, "stop 之后不得安排延迟重试")
        #expect(scheduler.hasPendingWork == false)
    }

    // MARK: - 有界延后（防忙循环）

    @Test("持续 pending trigger 被有界延后：不忙循环，且最终仍会发布")
    func pendingTriggersAreDeferredWithBound() async {
        let wakeGate = Gate()
        let insidePass = Gate()
        defer { wakeGate.release(); insidePass.release() }
        let scheduler = makeScheduler(wakeGate: wakeGate)
        let probe = Probe()

        let pass: PublishScheduler.Pass = {
            probe.enter()
            if probe.calls == 1 { await insidePass.enter() }
            defer { probe.leave() }
            return .retryNeeded // 索引一直不稳定
        }

        let trigger = Task { await scheduler.trigger(pass) }
        #expect(await probe.waitForCalls(1), "首轮没有开始") // 第一轮卡在 pass 内，闸门被占

        for _ in 0..<20 { await scheduler.trigger(pass) }
        #expect(probe.calls == 1, "闸门占用期间的持续触发必须合并成一次待处理")
        #expect(probe.peakActive == 1)

        insidePass.release()
        await trigger.value

        // 有界的准确口径：被卡住的首轮也在预算之内，所以整轮失败的 pass 次数
        // 恰好等于 maxImmediateRetries（3），而不是「首轮 + 3 次重试」。
        // 断言是精确等值而不是上界 —— 预算一旦被调大或跑飞，这里立刻失败。
        #expect(probe.calls == scheduler.maxImmediateRetries,
                "失败轮数必须恰好等于立即重试预算（含首轮），不多跑也不少跑")
        #expect(scheduler.delayedRetryCount == 1, "同一次延后只能排一个延迟轮")
        #expect(await wakeGate.waitUntilWaiting(), "有界延后必须真的停在等待上")
        #expect(wakeGate.isWaiting, "有界延后必须真的停在等待上，不能空转成忙循环")
        #expect(scheduler.hasPendingWork == true)

        // 索引稳定下来后：新的触发取消已排的延迟轮并真正发布（延后不等于丢弃）。
        let stable = PublishVersionVector(generations: ["vol-a": 9], volumes: [])
        let finishingPass: PublishScheduler.Pass = {
            probe.enter()
            defer { probe.leave() }
            if scheduler.isUnchanged(sampled: stable) { return .skippedUnchanged }
            scheduler.recordPublished(stable)
            return .published
        }
        await scheduler.trigger(finishingPass)
        #expect(await scheduler.waitForQuiescence(), "调度器没有在限定时间内静默")

        #expect(probe.calls == scheduler.maxImmediateRetries + 1, "有界延后之后的新触发只应跑一轮")
        #expect(scheduler.publishCount == 1, "延后之后的新触发必须真正发布")
        #expect(probe.peakActive == 1)
        #expect(scheduler.maxConcurrentPasses == 1)
        #expect(scheduler.hasPendingWork == false)
    }

    // MARK: - 幂等与失败

    @Test("幂等：同代不再重复构建")
    func idempotentGenerationDoesNotRebuild() async {
        let scheduler = makeScheduler()
        let vector = PublishVersionVector(generations: ["vol-a": 5], volumes: [])
        let builds = Counter()
        let pass: PublishScheduler.Pass = {
            if scheduler.isUnchanged(sampled: vector) { return .skippedUnchanged }
            scheduler.recordPublished(vector)
            _ = builds.next()
            return .published
        }

        await scheduler.trigger(pass)
        #expect(builds.value == 1)
        await scheduler.trigger(pass)
        #expect(builds.value == 1, "同代重复触发不得重复构建")
        await scheduler.trigger(pass)
        #expect(scheduler.passCount == 3)
        #expect(scheduler.publishCount == 1)
    }

    @Test("保留旧快照：读取失败不算发布，也不消耗重试预算")
    func failureKeepsPreviousSnapshot() async {
        let scheduler = makeScheduler()
        var statuses: [String] = []
        scheduler.statusHandler = { statuses.append($0) }
        let pass: PublishScheduler.Pass = { .keptPreviousSnapshot }

        await scheduler.trigger(pass)
        #expect(scheduler.publishCount == 0)
        #expect(scheduler.delayedRetryCount == 0, "读取失败不该安排无意义的延迟重试")
        #expect(scheduler.hasPendingWork == false)
    }
}

// MARK: - 测试替身

/// 有界等待点：条件成立则返回 true；超时返回 false，并把仍挂着的 continuation 全部释放
/// （回归时得到一条明确的失败，而不是永远悬挂或泄漏 continuation）。
@MainActor
private final class BoundedWaiter {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Bool, Never>
        let timeoutTask: Task<Void, Never>
    }
    private var waiters: [Waiter] = []
    private var nextID: UInt64 = 0

    /// `condition` 每次醒来都会重新求值；超时返回 false。
    func wait(timeout: Duration = .seconds(5), until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            if ContinuousClock.now >= deadline {
                releaseAll(satisfied: false)
                return false
            }
            let satisfied: Bool = await withCheckedContinuation { continuation in
                nextID &+= 1
                let id = nextID
                let timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.resume(id: id, satisfied: false)
                }
                waiters.append(Waiter(id: id, continuation: continuation, timeoutTask: timeoutTask))
            }
            if !satisfied {
                releaseAll(satisfied: false)
                return false
            }
        }
        return true
    }

    /// 状态变化时调用：所有等待者重新检查条件。
    func notify() { releaseAll(satisfied: true) }

    private func resume(id: UInt64, satisfied: Bool) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: satisfied)
    }

    private func releaseAll(satisfied: Bool) {
        let resumed = waiters
        waiters = []
        for waiter in resumed {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(returning: satisfied)
        }
    }
}

/// 手动闸门：需要显式 `release()` 才会放行，用来把「等在哪」变成可断言的事实。
@MainActor
private final class Gate {
    private var isReleased = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let arrivals = BoundedWaiter()
    private(set) var waitCount = 0

    /// 已有人停在闸门上（还没被放行）。
    var isWaiting: Bool { !waiting.isEmpty }

    func enter() async {
        if isReleased { return }
        waitCount += 1
        await withCheckedContinuation { continuation in
            // 先挂上自己，再通知观察者：观察者醒来时 isWaiting 一定为真。
            waiting.append(continuation)
            arrivals.notify()
        }
    }

    /// 等到确实有人停在闸门上；超时没人到达则返回 false。
    @discardableResult
    func waitUntilWaiting(timeout: Duration = .seconds(5)) async -> Bool {
        await arrivals.wait(timeout: timeout) { self.isWaiting }
    }

    /// 永久放行（用例收尾也用它，保证被取消的等待者能返回）。
    func release() {
        isReleased = true
        resumeAll()
    }

    private func resumeAll() {
        let resumed = waiting
        waiting = []
        for continuation in resumed { continuation.resume() }
    }
}

/// 可观察的 sleep 替身：记录开始/返回次数，可手动放行，并可等待「它确实返回了」。
/// 用来在不靠顺序的前提下证明被取消的延迟轮真的从等待里退了出来（没有悬挂）。
@MainActor
private final class ControlledSleep {
    private let gate = Gate()
    private let finishes = BoundedWaiter()
    private(set) var startCount = 0
    private(set) var finishCount = 0

    var isWaiting: Bool { gate.isWaiting }

    func sleep() async {
        startCount += 1
        await gate.enter()
        finishCount += 1
        finishes.notify()
    }

    @discardableResult
    func waitUntilWaiting(timeout: Duration = .seconds(5)) async -> Bool {
        await gate.waitUntilWaiting(timeout: timeout)
    }

    /// 等到 sleep 至少返回过 `target` 次（被取消的路径也会返回，因此可用来证明没悬挂）。
    @discardableResult
    func waitUntilFinished(_ target: Int, timeout: Duration = .seconds(5)) async -> Bool {
        await finishes.wait(timeout: timeout) { self.finishCount >= target }
    }

    func release() { gate.release() }
}

/// 记录 pass 被调用的次数、并发峰值，并可等待「第 n 次调用已发生」。
@MainActor
private final class Probe {
    private(set) var calls = 0
    private(set) var active = 0
    private(set) var peakActive = 0
    private let arrivals = BoundedWaiter()

    @discardableResult
    func enter() -> Int {
        calls += 1
        active += 1
        peakActive = max(peakActive, active)
        arrivals.notify()
        return calls
    }

    func leave() { active -= 1 }

    @discardableResult
    func waitForCalls(_ n: Int, timeout: Duration = .seconds(5)) async -> Bool {
        await arrivals.wait(timeout: timeout) { self.calls >= n }
    }
}

/// 跨并发闭包使用的计数器（测试只跑在主线程，但闭包是 @Sendable）。
private final class Counter: @unchecked Sendable {
    private(set) var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}