// AppModel が外の世界に触れる唯一の口（テストは FakeServices で差し替える）。
import AppKit
import Foundation
import VDContract
import VDCore
import VDModels
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
    /// 設定の 1 つのキーを変えて保存する（GUI で変えてよい 4 つだけ。PLAN §6.3）。
    func updateConfig(_ mutate: @Sendable (inout AppConfig) -> Void) async -> ConfigUpdateResult
    /// モデルを 1 件ダウンロードする（進捗は progress に。取り消しは cancelDownload）。
    func download(
        kind: ModelKind, entry: ModelEntry, progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async -> Result<URL, ModelError>
    func cancelDownload(id: String) async
    /// 利用者が選んだ .gguf を読み込む（PLAN §8.10「ファイルから読み込む」）。
    func importGGUF(from source: URL) async -> Result<(id: String, url: URL), ModelError>
    /// ログイン項目の操作（PLAN §8.12 の 6）。
    func registerLoginItem() -> LoginItemResult
    func unregisterLoginItem() -> LoginItemResult
    func openSystemSettingsLoginItems()
    /// 「今はしない」などの記録。
    func saveUIState(_ state: UIState) -> Bool
    // T-32
    /// 「診断を実行」（PLAN §8.11。DR-09 を除く 15 件。何も書かない）
    func runDiagnostics() async -> [DiagnosticResult]
    /// Worker の直列ループに仕事を入れる（DR-09 など）
    func enqueue(_ job: WorkerJob) async
    /// 「状態の詳細」（PLAN §8.12。DB が無ければ全 0。DB を作らない）
    func statusReport() async -> StatusReport
    /// 要対応の「システム設定を開く」（ファイルとフォルダの許可）
    func openSystemSettingsPrivacyFilesAndFolders()
    // T-40
    /// 「元音声の削除を有効にする」（PLAN §8.9.8。DeletionEnabler.enable）
    func enableDeletion(confirmation: String) async -> Result<Void, EnableError>
    /// 「無音・重複も消す」（DeletionEnabler.enableSkippedDeletion）
    func enableSkippedDeletion(confirmation: String) async -> Result<Void, EnableError>
    /// 「削除を無効にする」（確認なし。DeletionEnabler.disable。失敗した段の名前）
    func disableDeletion() async -> [String]
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
            s.vaultPath = c.vault.path
            // stat と opendir だけで、何も作らない（NOTE-16）
            s.vault = VaultCheck.evaluate(path: c.vault.path, marker: c.vault.marker)
        }
        // T-31: モデル・ログイン項目・パネルの記憶
        s.physicalMemoryBytes = context.physicalMemoryBytes
        s.loginItem = context.loginItem.status()
        s.uiState = context.uiState.load()
        if let c = config {
            let catalog = context.catalog
            let layout = context.layout
            s.vaultMarker = c.vault.marker
            s.whisperEntry = catalog.entry(kind: .whisper, id: c.transcription.whisperModelID)
            s.whisperPresent = s.whisperEntry.map { ModelFiles.isPresent($0, kind: .whisper, layout: layout) } ?? false
            s.vadEnabled = c.transcription.vad.enabled
            s.vadEntry = catalog.entry(kind: .vad, id: c.transcription.vad.modelID)
            s.vadPresent = s.vadEntry.map { ModelFiles.isPresent($0, kind: .vad, layout: layout) } ?? false
            s.llmModelID = c.llm.modelID
            s.llmPresent = ModelChoices.llmIsPresent(id: c.llm.modelID, catalog: catalog, layout: layout)
            s.llmChoices = ModelChoices.llm(
                catalog: catalog, physicalMemoryBytes: s.physicalMemoryBytes, currentID: c.llm.modelID,
                layout: layout)
        }
        s.ingestState = await context.ingest.state()
        s.ingestActivity = await context.ingest.activity()
        s.device = await context.ingest.latestSnapshot()
        // 起動直後（メモリに前回の値が無い）は ui-state.json の値を使う（F-70。再起動で「まだありません」に戻さない）
        s.lastConnectedAt = LastConnected.resolve(
            device: s.device, carried: lastConnectedAt, persisted: s.uiState.lastConnectedAt)
        s.renameCandidates = OnboardingEvaluator.renameCandidates(s.device)
        // T-40: 3 行の個別表示（式は LockObserving.display の 1 か所。書き直さない）
        if let c = config {
            s.deletion = DeletionPanelState(
                display: await context.locks.display(config: c, snapshot: s.device),
                deleteSkippedSource: c.cleanup.deleteSkippedSource)
        } else {
            // 設定エラー中でも、消す能力が残っていれば trash と「無効にする」を出す（PLAN §8.9.8。設定エラーは条件に入らない）
            s.deletionResidual = await context.enabler.hasRemainingCapability()
        }
        s.worker = await context.worker.status()
        // T-32: 要対応（ガードの判定は Worker の PauseReason をそのまま読む。CR-06）
        var attention = AttentionInput(now: s.now)
        attention.configPresent = s.configPresent
        attention.violations = s.configViolations
        attention.ingestActivity = s.ingestActivity
        attention.snapshot = s.device
        attention.paused = s.worker.paused
        attention.vault = s.vault
        attention.reaper = await context.locks.reaperStatus()
        attention.snapshotMaxAgeSeconds = config?.device.snapshotMaxAgeSeconds ?? 900
        s.attention = AttentionEvaluator.items(attention)
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

    func updateConfig(_ mutate: @Sendable (inout AppConfig) -> Void) async -> ConfigUpdateResult {
        await context.config.update(mutate)
    }

    /// UI は ModelManager だけを使う（00-api-map §10・T-23 §10）。ModelManager が状態を動かす。
    func download(
        kind: ModelKind, entry: ModelEntry, progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async -> Result<URL, ModelError> {
        await context.models.download(entry.id, kind: kind, progress: progress)
    }

    func cancelDownload(id: String) async { await context.models.cancel(id: id) }

    func importGGUF(from source: URL) async -> Result<(id: String, url: URL), ModelError> {
        await context.models.importCustomLLM(from: source)
    }

    func registerLoginItem() -> LoginItemResult { context.loginItem.register() }

    func unregisterLoginItem() -> LoginItemResult { context.loginItem.unregister() }

    func openSystemSettingsLoginItems() { context.loginItem.openSystemSettings() }

    func saveUIState(_ state: UIState) -> Bool { context.uiState.save(state) }

    // T-32

    func runDiagnostics() async -> [DiagnosticResult] {
        await Diagnostics(deps: context.diagnostics).run(loginItemStatus: context.loginItem.status())
    }

    func enqueue(_ job: WorkerJob) async { await context.worker.enqueue(job) }

    /// 読むだけ（DB は ReadOnlyStore。inbox と staging を走査するので「詳細」を開いたときだけ呼ぶ）
    func statusReport() async -> StatusReport {
        let config = await context.config.current()
        let zone = ZonedTime(timeZone: config.flatMap { TimeZone(identifier: $0.timeZone) } ?? .current)
        return StatusReporter.build(
            layout: context.layout, config: config, snapshot: await context.ingest.latestSnapshot(),
            now: context.clock.now(), zone: zone)
    }

    /// `x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders`（`!` を使わず URLComponents で作る）
    func openSystemSettingsPrivacyFilesAndFolders() {
        guard let url = Self.privacyFilesAndFoldersURL() else { return }
        NSWorkspace.shared.open(url)
    }

    /// システム設定の「ファイルとフォルダ」の URL（テストが文字列を固定する）
    static func privacyFilesAndFoldersURL() -> URL? {
        var components = URLComponents()
        components.scheme = systemSettingsScheme
        components.path = securityPane
        components.query = filesAndFoldersAnchor
        return components.url
    }

    // T-40

    func enableDeletion(confirmation: String) async -> Result<Void, EnableError> {
        await context.enabler.enable(confirmation: confirmation)
    }

    func enableSkippedDeletion(confirmation: String) async -> Result<Void, EnableError> {
        await context.enabler.enableSkippedDeletion(confirmation: confirmation)
    }

    func disableDeletion() async -> [String] { await context.enabler.disable() }

    static let systemSettingsScheme = "x-apple.systempreferences"
    static let securityPane = "com.apple.preference.security"
    static let filesAndFoldersAnchor = "Privacy_FilesAndFolders"
}
