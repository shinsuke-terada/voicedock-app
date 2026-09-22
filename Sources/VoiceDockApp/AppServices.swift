// AppModel が外の世界に触れる唯一の口（テストは FakeServices で差し替える）。
import Foundation
import VDCore
import VDNotes
import VDPipeline
import VDStore

/// AppModel が外の世界に触れる唯一の口。
protocol AppServices: Sendable {
    /// 現在の観測をまとめて 1 つ読む（アクターへの await はここに閉じる）。
    func read(lastConnectedAt: Instant?) async -> AppSnapshot
    /// パネルの「再試行」（PLAN §5.4 の契機 3）。
    func requeueManual() async
    /// パネルの「設定を読み直す」（PLAN §6.3）。
    func reloadConfig() async -> ConfigLoadResult
    /// 走査を促す（Vault やモデルを変えた後に使う。T-31 / T-40）。
    func scanNow() async
    /// IngestService からの更新の通知（走査の終わり）。
    func updates() async -> AsyncStream<Void>
    // T-32 が enqueue(_ job: WorkerJob) を足す
}

/// 本番の AppServices（Bootstrap が作った AppContext を読むだけ）。
struct LiveServices: AppServices {
    let context: AppContext

    /// どれも読むだけ。DB は ReadOnlyStore で開き、無ければ作らない（PLAN §8.12）。
    func read(lastConnectedAt: Instant?) async -> AppSnapshot {
        var s = AppSnapshot(now: context.clock.now())
        let config = await context.config.current()
        s.configPresent = (config != nil)
        s.configViolations = await context.config.violations()
        if let c = config {
            s.timeZone = c.timeZone
            s.deletionEnabled = c.cleanup.deleteSourceAudio
            s.vaultPath = c.vault.path
            // stat と opendir だけで、何も作らない（NOTE-16）
            s.vault = VaultCheck.evaluate(path: c.vault.path, marker: c.vault.marker)
        }
        s.ingestState = await context.ingest.state()
        s.ingestActivity = await context.ingest.activity()
        s.device = await context.ingest.latestSnapshot()
        s.lastConnectedAt = (s.device?.devices.isEmpty == false) ? s.device?.completedAt : lastConnectedAt
        s.worker = await context.worker.status()
        // 開けない・投げたら .empty のまま（DB が無ければ全 0。PLAN §8.12）
        if let ro = ReadOnlyStore.open(url: context.layout.database), let b = try? ro.backlog() {
            s.backlog = BacklogCounts(count: b.count, seconds: b.seconds, unknownDuration: b.unknownDuration)
        }
        return s
    }

    func requeueManual() async { await context.worker.requeue(.manual) }

    func reloadConfig() async -> ConfigLoadResult { await context.config.load() }

    func scanNow() async { _ = await context.ingest.scanNow() }

    func updates() async -> AsyncStream<Void> { await context.ingest.updates() }
}
