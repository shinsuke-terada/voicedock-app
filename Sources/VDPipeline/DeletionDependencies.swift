// 削除の段の 1 tick 分の依存（PLAN §8.9.5〜§8.9.7）。本番は TickContext から、テストは DeletionScene から作る。
import VDContract
import VDCore
import VDDevice
import VDStore

/// 削除の段の 1 tick 分の依存。
struct DeletionDependencies: Sendable {
    let layout: HomeLayout
    let store: Store
    /// tick の設定（tick の中で変えない）
    let config: AppConfig
    let zone: ZonedTime
    let ingest: any IngestPort
    let locks: LockEvaluator
    let volumeOpener: any VolumeOpener
    let clock: any AppClock
    let log: AppLog
    let pended: PendedPartkeys
    let warn: @Sendable (any Error) -> Void

    init(
        layout: HomeLayout, store: Store, config: AppConfig, zone: ZonedTime, ingest: any IngestPort,
        locks: LockEvaluator, volumeOpener: any VolumeOpener, clock: any AppClock, log: AppLog,
        pended: PendedPartkeys, warn: @escaping @Sendable (any Error) -> Void
    ) {
        self.layout = layout
        self.store = store
        self.config = config
        self.zone = zone
        self.ingest = ingest
        self.locks = locks
        self.volumeOpener = volumeOpener
        self.clock = clock
        self.log = log
        self.pended = pended
        self.warn = warn
    }

    /// ctx.deps.layout / store / ingest / locks / volumeOpener / clock / log、ctx.config、ctx.zone、ctx.pendedPartkeys、warn = { ctx.warnStore($0) }
    init(ctx: TickContext) {
        self.init(
            layout: ctx.deps.layout, store: ctx.deps.store, config: ctx.config, zone: ctx.zone,
            ingest: ctx.deps.ingest, locks: ctx.deps.locks, volumeOpener: ctx.deps.volumeOpener,
            clock: ctx.deps.clock, log: ctx.deps.log, pended: ctx.pendedPartkeys, warn: { ctx.warnStore($0) })
    }

    var reaper: ReaperRunner { locks.reaper }

    /// その時点の最新の snapshot。無いか新鮮でなければ nil（DEL-20。tick の先頭の snapshot ではない。Part の処理は数時間かかる）
    func freshSnapshot() async -> DeviceSnapshot? {
        guard let s = await ingest.latestSnapshot(),
            s.isFresh(now: clock.now(), maxAgeSeconds: config.device.snapshotMaxAgeSeconds)
        else { return nil }
        return s
    }

    /// 削除条件の評価の環境（LockEvaluator.observe。useCache は既定で真）
    func context(snapshot: DeviceSnapshot?, useCache: Bool = true) async -> DeletionContext {
        DeletionContext(
            config: config, locks: await locks.observe(config: config, snapshot: snapshot, useCache: useCache),
            layout: layout, volumeOpener: volumeOpener)
    }

    /// warn に渡さず TransitionConflict を「状態が変わった」として記録する（WARNING）
    func logStatusChanged(recordingKey: String) {
        log.warning(
            .sourceDeleteSkipped,
            [(.recordingKey, .string(recordingKey)), (.reason, .string(DeletionReason.statusChanged))])
    }

    func logStatusChanged(sessionKey: String) {
        log.warning(
            .sourceDeleteSkipped,
            [(.sessionKey, .string(sessionKey)), (.reason, .string(DeletionReason.statusChanged))])
    }
}
