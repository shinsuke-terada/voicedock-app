// 状態機械を 1 本の直列ループで回す（PLAN §5.4）。whisper と LLM を同時に走らせない（LLM-15）。
import Foundation
import VDContract
import VDCore
import VDDevice
import VDNotes
import VDStore

/// 状態機械を 1 本の直列ループで回す（PLAN §5.4）。
public actor Worker {
    public static let pollSeconds = 30

    let deps: WorkerDependencies
    let pauses: PauseBook
    let board: ActivityBoard
    let stop = StopFlag()
    let onStage: (@Sendable (TickStage) -> Void)?
    /// 起動の処理（start の 1 回目が作り、後から来た start・run・tick はこれを待つ。actor の再入で二重に走らせない）
    var startTask: Task<Void, Never>?
    var pendingStart = false
    var lastSeenConnectEpoch: UInt64 = 0
    var pendingRequeues: [RequeueReason] = []
    var wakeContinuation: AsyncStream<Void>.Continuation?
    var stoppingLogged = false
    /// Vault 索引と、それを作った Vault のパス（tick をまたいで持つ。voicedock 変更 BK-3）
    var vaultIndex: VaultIndex? = nil
    var vaultIndexPath: String? = nil
    // T-32 がジョブの列を足す

    public init(deps: WorkerDependencies) {
        self.init(deps: deps, assertion: ProcessInfoSleepAssertion(), onStage: nil)
    }

    /// テスト用（@testable）。sleep の抑止と、段の実行の記録を差し替える。
    init(deps: WorkerDependencies, assertion: any SleepAssertion, onStage: (@Sendable (TickStage) -> Void)?) {
        self.deps = deps
        self.pauses = PauseBook(log: deps.log)
        self.board = ActivityBoard(assertion: assertion)
        self.onStage = onStage
    }

    /// 設定のタイムゾーンから作る（CV-32 があるので TimeZone.current には来ない）。
    static func zone(for config: AppConfig) -> ZonedTime {
        ZonedTime(timeZone: TimeZone(identifier: config.timeZone) ?? TimeZone.current)
    }

    /// 起動時に 1 回（PLAN §5.3・§5.4）。設定エラー中・共存ガード中は保留し、解除された最初の tick の先頭で行う。
    /// 2 回目以降の呼び手は 1 回目の処理が終わるのを待ってから戻る（start の途中で tick が走らない）。
    public func start() async {
        if let running = startTask {
            await running.value
            return
        }
        let task = Task { await self.startOnce() }
        startTask = task
        await task.value
    }

    /// start の本体（1 回だけ）。
    func startOnce() async {
        let noConfig = await deps.config.current() == nil
        let blocked = await deps.ingest.state() == .coexistenceBlocked
        if noConfig || blocked {
            pendingStart = true
            return
        }
        await performStart(delayed: false)
    }

    /// 復旧 → 閉じる → inbox の孤児（遅れた start では行わない）→ requeue(.startup)。
    func performStart(delayed: Bool) async {
        guard let config = await deps.config.current() else {
            pendingStart = true
            return
        }
        deps.log.info(
            .serviceStarted,
            [(.version, .string(AppVersion.string)), (.schema, .of((try? deps.store.appliedMigrations)?.last))])
        let zone = Worker.zone(for: config)
        let ctx = makeContext(config, zone, snapshot: nil)
        do {
            _ = try Recovery(store: deps.store, layout: deps.layout, log: deps.log, config: config, zone: zone).run()
        } catch {
            warnStore(error, rule: "recovery")
        }
        do {
            try SessionSteps(ctx: ctx).closeIdleSessions()
        } catch {
            warnStore(error)
        }
        if !delayed {
            let s = deps.store
            let l = deps.layout
            let g = deps.log
            do {
                let n = try await BlockingIO.run { try InboxMaintenance(store: s, layout: l, log: g).removeOrphans() }
                if n > 0 { deps.log.info(.inboxOrphansRemoved, [(.count, .of(n))]) }
            } catch {
                warnStore(error)
            }
        }
        requeueFailed(.startup, ctx)
    }

    /// DB の例外で常駐を止めない（1 件の失敗で残りを止めない。DEL-14）。TickContext.warnStore と同じ 1 行。
    func warnStore(_ e: any Error, rule: String = "store") {
        deps.log.warning(.configWarning, [(.rule, .string(rule)), (.message, .string(ErrorText.describe(e)))])
    }

    /// 1 周（PLAN §5.4 の順）。停止要求で中断したら finishTick も board.set(.idle) も呼ばない。
    public func tick() async {
        if let running = startTask { await running.value }
        guard let config = await deps.config.current() else {
            board.set(.idle)
            return
        }
        if await deps.ingest.state() == .coexistenceBlocked {
            board.set(.idle)
            return
        }
        if pendingStart {
            pendingStart = false
            await performStart(delayed: true)
        }
        guard deps.license.allowsProcessing() else {
            pauses.trip(.license)
            pauses.finishTick()
            return
        }
        let zone = Worker.zone(for: config)
        let snapshot = await deps.ingest.latestSnapshot()
        let ctx = makeContext(config, zone, snapshot: snapshot)
        if !pendingRequeues.isEmpty {
            guard await run(.manualRequeue, ctx) else { return }
        }
        for stage in [TickStage.groupNewParts, .requeueRecopied, .closeIdleSessions, .processPendingParts] {
            guard await run(stage, ctx) else { return }
        }
        for stage in [TickStage.refreshVaultIndex, .processReadySessions, .collectDeleteResults, .expireDeleteRequests]
        {
            guard await run(stage, ctx) else { return }
        }
        if let s = snapshot,
            s.isFresh(now: deps.clock.now(), maxAgeSeconds: config.device.snapshotMaxAgeSeconds)
        {
            for stage in [TickStage.evaluateDeletions, .settleSkippedDeletions, .runReaperIfNeeded] {
                guard await run(stage, ctx) else { return }
            }
        }
        for stage in [TickStage.pendingJobs, .requeueOnConnect] {
            guard await run(stage, ctx) else { return }
        }
        pauses.finishTick()
        board.set(.idle)
    }

    /// 段を 1 つ行う。停止要求が立っていれば行わずに偽（tick を中断する）。
    private func run(_ stage: TickStage, _ ctx: TickContext) async -> Bool {
        if stop.isSet { return false }
        onStage?(stage)
        switch stage {
        case .manualRequeue: stageManualRequeue(ctx)
        case .groupNewParts: stageGroupNewParts(ctx)
        case .requeueRecopied: stageRequeueRecopied(ctx)
        case .closeIdleSessions: stageCloseIdleSessions(ctx)
        case .processPendingParts: await stageProcessPendingParts(ctx)
        case .refreshVaultIndex: await stageRefreshVaultIndex(ctx)
        case .processReadySessions: await stageProcessReadySessions(ctx)
        case .collectDeleteResults: await stageCollectDeleteResults(ctx)
        case .expireDeleteRequests: await stageExpireDeleteRequests(ctx)
        case .evaluateDeletions: await stageEvaluateDeletions(ctx)
        case .settleSkippedDeletions: await stageSettleSkippedDeletions(ctx)
        case .runReaperIfNeeded: await stageRunReaperIfNeeded(ctx)
        case .pendingJobs: await stagePendingJobs(ctx)
        case .requeueOnConnect: stageRequeueOnConnect(ctx)
        }
        return true
    }

    /// 待ちは「IngestService の通知」「パネルの要求」「30 秒」の早い方（PLAN §5.4 / §8.15）。
    public func run() async {
        await start()
        let (wake, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        wakeContinuation = continuation
        let updates = await deps.ingest.updates()
        let pump = Task { for await _ in updates { continuation.yield(()) } }
        let sleeper = deps.sleeper
        let timer = Task {
            while !Task.isCancelled {
                do { try await sleeper.sleep(seconds: Worker.pollSeconds) } catch { return }
                continuation.yield(())
            }
        }
        var waiting = wake.makeAsyncIterator()
        while !stop.isSet {
            await tick()
            if stop.isSet { break }
            if await waiting.next() == nil { break }
        }
        pump.cancel()
        timer.cancel()
        continuation.finish()
        wakeContinuation = nil
    }

    /// 停止要求。実行中の子プロセスは止めない（アプリの終了処理が ProcessRunner.terminateAll で止める。PLAN §8.15）。
    public func requestStop() {
        stop.set()
        wakeContinuation?.yield(())
        if !stoppingLogged {
            deps.log.info(.serviceStopping, [(.version, .string(AppVersion.string))])
            stoppingLogged = true
        }
    }

    /// 実行は次の tick の先頭の manualRequeue（tick の途中で行を動かさない）。
    public func requeue(_ reason: RequeueReason) async {
        pendingRequeues.append(reason)
        wakeContinuation?.yield(())
    }

    public func status() -> WorkerStatus {
        WorkerStatus(activity: board.current, paused: pauses.paused)
    }

    func makeContext(_ config: AppConfig, _ zone: ZonedTime, snapshot: DeviceSnapshot?) -> TickContext {
        TickContext(
            deps: deps, config: config, zone: zone, snapshot: snapshot, pauses: pauses, activity: board, stop: stop)
    }

    /// 契機 1〜3（PLAN §5.4）。
    func requeueFailed(_ reason: RequeueReason, _ ctx: TickContext) {
        do {
            _ = try Requeue(ctx: ctx).requeueFailed(reason)
        } catch {
            warnStore(error)
        }
    }
}
