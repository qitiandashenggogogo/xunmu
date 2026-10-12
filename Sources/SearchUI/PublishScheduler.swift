import Foundation

/// 发布调度器：把「什么时候再跑一轮」从 AppController 里抽出来，使其**可被真实执行地测试**。
///
/// 并发规则（single-flight）：
/// - 每一轮都必须先拿到 `gateHeld` 闸门才能执行；入口、外部触发、延迟唤醒**共用同一个闸门**，
///   因此任何时刻最多只有一轮 `pass` 在跑（不会出现两个并发的读库）。
/// - 闸门被占用时到来的触发合并成一次「待处理」，不丢，也不并发执行。
///
/// 时序规则：
/// - 单轮内 `retryNeeded` 做**有上限的立即重试**，避免忙循环。
/// - 用满后安排**一个合并的延迟重试**（可取消、带退避）；新一轮开始前重置重试预算。
/// - 一轮干净结束（发布/跳过）时最多立即补跑一次；其余待处理触发合并进延迟轮，
///   因此持续扫描也不会把调度变成忙循环，但索引稳定后结果仍会落地。
///
/// 可观测性：`waitForQuiescence()` 由调度器在真正静默时显式唤醒，
/// 因此验收「最终发布了 / 没有残留工作」不依赖让出次数或任务调度顺序。
///
/// 停止规则：
/// - 每次 `await pass()` 之后、每次调度之前都检查 `stopped`；`stop()` 之后不再调度，
///   也不再显示「稍后自动同步」这类实际上不会发生的承诺。
@MainActor
public final class PublishScheduler {
    /// 一轮发布。返回 `.retryNeeded` 表示这一轮作废、需要再来。
    ///
    /// 标为 `@MainActor`：发布全程在主线程发生（采样 → 读库 → 重建引擎 → 重跑搜索），
    /// 闭包内因此可以直接访问 App 的主线程状态。
    public typealias Pass = @MainActor @Sendable () async -> PublishPassOutcome

    /// 达到立即重试上限后的延迟重试间隔（退避）。
    public var retryDelay: Duration = .milliseconds(1200)
    /// 单轮内允许的**失败轮数**上限（**含首轮**）：首轮返回 `.retryNeeded` 时计数即为 1，
    /// 因此整轮最多跑 `maxImmediateRetries` 次失败的 pass，第 N 次之后转延迟轮。
    public var maxImmediateRetries: Int = PublishCoordinator.maxConsecutiveRetries
    /// 可注入的等待实现，测试里换成可控 continuation，避免真实睡眠。
    var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    private var coordinator = PublishCoordinator()
    /// single-flight 闸门。任何一轮执行期间为 true。
    private var gateHeld = false
    private var pendingTrigger = false
    private var delayedTask: Task<Void, Never>?
    private var stopped = false

    // MARK: - 静默信号（确定等待，不是碰运气）
    //
    // 调度器每到达「确实没有后续动作」的状态就主动唤醒等待者；
    // 等待者因此不需要靠 `Task.yield()` 撞轮次来猜「大概跑完了」。
    private struct IdleWaiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, Never>
        let timeoutTask: Task<Void, Never>
    }
    private var idleWaiters: [IdleWaiter] = []
    private var nextWaiterID: UInt64 = 0

    // MARK: - 观测

    /// 执行过的轮数。
    public private(set) var passCount = 0
    /// 真正重建并发布了快照的轮数。
    public private(set) var publishCount = 0
    /// 安排过的延迟重试次数。
    public private(set) var delayedRetryCount = 0
    /// 曾经同时执行的轮数峰值（single-flight 的证据，应恒为 1）。
    public private(set) var maxConcurrentPasses = 0
    private var activePasses = 0

    /// 状态提示（只在确实还有后续动作时给出）。
    public var statusHandler: (@MainActor (String) -> Void)?

    public init() {}

    public var hasPendingWork: Bool { gateHeld || delayedTask != nil || pendingTrigger }
    public var isStopped: Bool { stopped }

    // MARK: - 对 App 的公开封装（App 不直接碰内部协调器）

    /// 幂等判定：版本向量与上次成功发布一致则无需重建。
    public func isUnchanged(sampled vector: PublishVersionVector) -> Bool {
        coordinator.isUnchanged(sampled: vector)
    }

    /// 记录一次成功发布。
    public func recordPublished(_ vector: PublishVersionVector) {
        coordinator.didPublish(vector)
    }

    /// 读取前采样失败：保留旧快照，不进入读取。
    public func handleSamplingFailure() -> PublishPassOutcome {
        coordinator.handleSamplingFailure()
    }

    /// 读取后决策（含读前/读后两次采样的一致性判定）。
    public func decide(
        readFailedBefore: Bool,
        before: PublishVersionVector,
        readFailedAfter: Bool,
        after: PublishVersionVector
    ) -> PublishPassOutcome {
        coordinator.decide(
            readFailedBefore: readFailedBefore,
            before: before,
            readFailedAfter: readFailedAfter,
            after: after
        )
    }

    // MARK: - 入口

    /// 外部触发一次发布。`pass` 会跨多轮复用，所以传闭包而不是单次结果。
    public func trigger(_ pass: @escaping Pass) async {
        guard !stopped else { return }
        // 新触发取消待醒的延迟轮，改为立即处理（闸门占用时则合并为待处理）。
        cancelDelayedRetry()
        await runRounds(pass: pass, allowsImmediateFollowUp: true)
    }

    /// 停止：取消延迟重试、丢弃待处理触发，之后不再复活。
    public func stop() {
        stopped = true
        pendingTrigger = false
        delayedTask?.cancel()
        delayedTask = nil
        signalIdleIfNeeded()
    }

    /// 测试用：等待调度器**真正静默**（没有在跑的轮，也没有待唤醒的延迟轮）。
    ///
    /// 依赖 `signalIdleIfNeeded()` 的显式唤醒，不依赖让出次数或调用顺序。
    /// 返回 false 表示在 `timeout` 内没有静默（回归时给出可读的失败，而不是挂死）。
    @discardableResult
    public func waitForQuiescence(timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while hasPendingWork {
            if ContinuousClock.now >= deadline { return false }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                nextWaiterID &+= 1
                let id = nextWaiterID
                // 检查与登记之间没有让出点，MainActor 上不会丢唤醒。
                let timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.resumeIdleWaiter(id: id)
                }
                idleWaiters.append(IdleWaiter(id: id, continuation: continuation, timeoutTask: timeoutTask))
            }
        }
        return true
    }

    private func signalIdleIfNeeded() {
        guard !hasPendingWork, !idleWaiters.isEmpty else { return }
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume()
        }
    }

    private func resumeIdleWaiter(id: UInt64) {
        guard let index = idleWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = idleWaiters.remove(at: index)
        waiter.timeoutTask.cancel()
        waiter.continuation.resume()
    }

    // MARK: - 内部

    /// 所有入口共用的执行路径。闸门保证同一时刻只有一轮。
    private func runRounds(pass: @escaping Pass, allowsImmediateFollowUp: Bool) async {
        if gateHeld {
            // 已经有一轮在跑：合并，不并发。
            pendingTrigger = true
            return
        }
        guard !stopped else { return }
        gateHeld = true
        var endedCleanly = false
        var immediateRetries = 0

        while !stopped {
            activePasses += 1
            maxConcurrentPasses = max(maxConcurrentPasses, activePasses)
            let outcome = await pass()
            activePasses -= 1

            // await 之后立刻检查停止：退出后不再安装引擎、不再重试。
            if stopped { break }
            passCount += 1
            if outcome == .published { publishCount += 1 }
            if outcome != .retryNeeded {
                endedCleanly = true
                break
            }
            immediateRetries += 1
            if immediateRetries >= maxImmediateRetries {
                // 调度之前再检查一次停止。
                if !stopped { scheduleDelayedRetry(pass: pass) }
                endedCleanly = false
                break
            }
        }

        gateHeld = false

        guard !stopped else { pendingTrigger = false; signalIdleIfNeeded(); return }
        guard pendingTrigger else { signalIdleIfNeeded(); return }
        pendingTrigger = false
        if endedCleanly && allowsImmediateFollowUp {
            // 干净结束：最多立即补跑一次（保证最终一致且不忙循环）。
            await runRounds(pass: pass, allowsImmediateFollowUp: false)
        } else if delayedTask == nil {
            // 重试用尽时循环里已经安排过延迟轮，这里不再重复安排
            // （否则同一次延后会被计成两次，且会顶掉刚排好的那一轮）。
            scheduleDelayedRetry(pass: pass)
        }
        signalIdleIfNeeded()
    }

    private func scheduleDelayedRetry(pass: @escaping Pass) {
        guard !stopped else { return }
        cancelDelayedRetry()
        // 新一轮开始前重置重试预算，否则永远拿不到重试机会。
        coordinator.resetRetryBudget()
        delayedRetryCount += 1
        statusHandler?("记录正在持续变化，稍后会自动刷新。")
        delayedTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sleep(self.retryDelay)
            guard !Task.isCancelled, !self.stopped else { return }
            self.delayedTask = nil
            // 走同一个闸门：若此刻已有轮在跑，这里只会合并，不会并发。
            await self.runRounds(pass: pass, allowsImmediateFollowUp: true)
        }
    }

    private func cancelDelayedRetry() {
        delayedTask?.cancel()
        delayedTask = nil
    }
}