// 本番の依存を組み立てる唯一の場所（PLAN §8.15 の起動手順）。ここ以外で本番の実装を new しない。
import AppKit
import Foundation
import Synchronization
import VDContract
import VDCore
import VDDevice
import VDLLM
import VDModels
import VDPipeline
import VDProcess
import VDStore

/// 起動でできた長生きの部品。AppDelegate と LiveServices が持つ。
@MainActor
final class AppContext {
    let layout: HomeLayout
    let paths: AppPaths
    let clock: any AppClock
    let log: AppLog
    let catalog: ModelCatalog
    let config: ConfigStore
    let store: Store
    let runner: ProcessRunner
    /// ロックの観測（本番は LockEvaluator。診断とパネルは LockObserving として読む）
    let locks: any LockObserving
    /// 診断の依存（書ける Store を持たない。PT-17）
    let diagnostics: DiagnosticsDependencies
    let llama: LlamaServerSupervisor
    let ingest: IngestService
    let worker: Worker
    /// 削除の有効化・無効化・ロック 1 の修復（T-40）
    let enabler: DeletionEnabler
    let models: ModelManager
    /// ModelManager に渡したもの（T-31）
    let downloader: ModelDownloader
    let loginItem: any LoginItemControlling
    /// <HOME>/ui-state.json（T-31）
    let uiState: UIStateStore
    /// ProcessInfo.processInfo.physicalMemory（Worker と同じ値。T-31）
    let physicalMemoryBytes: UInt64
    /// Worker.run() を回しているタスク（終了で待つ）
    var workerTask: Task<Void, Never>?
    /// 単一起動のロック（`<HOME>/state/app.lock`。F-76）。アプリが生きている間ずっと持つ（手放すと 2 つ目の起動を拒めない）。
    /// 本番は Bootstrap が渡す。テストの組み立ては持たない（nil）
    let instanceLock: FileLock?
    /// 起動の手順 8 で時刻帯とログに実際に使った値（F-84）。Store・IngestService・AppLog はこの値のまま動き、
    /// 「設定を読み直す」では変わらない（LiveServices.read が今の設定と比べ、違えばパネルに「再起動すると反映されます」を出す）
    let runningSettings: EffectiveSettings

    init(
        layout: HomeLayout, paths: AppPaths, clock: any AppClock, log: AppLog, catalog: ModelCatalog,
        config: ConfigStore, store: Store, runner: ProcessRunner, locks: any LockObserving,
        diagnostics: DiagnosticsDependencies, llama: LlamaServerSupervisor, ingest: IngestService,
        worker: Worker, enabler: DeletionEnabler, models: ModelManager, downloader: ModelDownloader,
        loginItem: any LoginItemControlling,
        uiState: UIStateStore, physicalMemoryBytes: UInt64, instanceLock: FileLock? = nil,
        runningSettings: EffectiveSettings = EffectiveSettings.resolve(nil)
    ) {
        self.layout = layout
        self.paths = paths
        self.clock = clock
        self.log = log
        self.catalog = catalog
        self.config = config
        self.store = store
        self.runner = runner
        self.locks = locks
        self.diagnostics = diagnostics
        self.llama = llama
        self.ingest = ingest
        self.worker = worker
        self.enabler = enabler
        self.models = models
        self.downloader = downloader
        self.loginItem = loginItem
        self.uiState = uiState
        self.physicalMemoryBytes = physicalMemoryBytes
        self.instanceLock = instanceLock
        self.runningSettings = runningSettings
    }
}

/// 起動できなかった理由（パネルを出さずに知らせて終わる。設定エラーはここに来ない）。
enum BootFailure: Error, Equatable {
    /// HomeLayout.createDirectories() が投げた
    case directories(String)
    /// バンドルの ModelCatalog.json が読めない
    case catalog(String)
    /// Store(url:clock:zone:) が投げた
    case database(String)
    /// 単一起動のロック（`state/app.lock`）をほかが持っている = 別のインスタンスが動いている（F-76）。知らせずに終わる
    case alreadyRunning
    /// 単一起動のロックを開けない・flock が EWOULDBLOCK 以外で失敗した（F-84。別のインスタンスが動いているとは限らない）。
    /// 値は `<relpath>` と `<段>: errno <n> (<strerror>)`
    case instanceLock(path: String, reason: String)

    /// 警告の本文。nil なら何も出さずに終わる（alreadyRunning。パネルは先に起動したほうにある。D-7）
    var message: String? {
        switch self {
        case .directories(let e): Strings.bootFailureDirectories(e)
        case .catalog(let e): Strings.bootFailureCatalog(e)
        case .database(let e): Strings.bootFailureDatabase(e)
        case .alreadyRunning: nil
        case .instanceLock(let path, let reason): Strings.bootFailureInstanceLock(path: path, reason: reason)
        }
    }
}

/// 本番の組み立て（PLAN §8.15）。
enum Bootstrap {
    /// P0-02 で確定。実機では `-mountPoint` が使えない（docs/POC.md 章 3）。
    static let useMountPoint = false
    /// os.Logger の subsystem（= BUNDLE_ID。AppIdentity から。T-36 §4.1）
    static let logSubsystem = AppIdentity.bundleID

    /// 本番の組み立て。PLAN §8.15 の順に行う。
    @MainActor static func build() async -> Result<AppContext, BootFailure> {
        // 1. 配置
        let layout = HomeLayout.production()
        let paths = AppPaths.fromMainBundle()
        // 2. <HOME> と下位ディレクトリ（bin/ は作らない）
        do { try layout.createDirectories() } catch { return .failure(.directories(ErrorText.describe(error))) }
        // 3. カタログ
        let catalogData: Data
        do { catalogData = try Data(contentsOf: paths.modelCatalog) } catch {
            return .failure(.catalog(ErrorText.describe(error)))
        }
        let catalog: ModelCatalog
        switch ModelCatalog.load(catalogData) {
        case .success(let c): catalog = c
        case .failure(let e): return .failure(.catalog(ErrorText.describe(e)))
        }
        // 4. 時計とログ（設定を読む前のログは既定のレベルで出す。既定は設定が無いときの EffectiveSettings。F-84）
        let clock: any AppClock = SystemClock()
        let bootTimeZone = TimeZone.current
        let bootSettings = EffectiveSettings.resolve(nil, current: bootTimeZone)
        let sink = TeeSink([OSLogSink(subsystem: logSubsystem), LogFile(url: layout.appLog)])
        var log = AppLog(
            sink: sink, level: bootSettings.logLevel, unsafeContent: bootSettings.unsafeLogContent,
            zone: ZonedTime(timeZone: bootSettings.timeZone), clock: clock, category: "app")
        // 4 の後. 単一起動（F-76）。設定・DB・復旧・Worker より前に <HOME>/state/app.lock を取る。ほかが持っていれば別の
        // インスタンスが動いている（2 つ目の復旧が 1 つ目の処理中の行を戻さないように）。ログの 1 行のほかは何もせずに終わる。
        // 開けない（EACCES・EISDIR・ENOSPC・ELOOP など）ときは黙って終わらず、起動の失敗として NSAlert を出す（F-84）
        let instanceLock: FileLock
        switch acquireInstanceLock(layout: layout) {
        case .success(let lock): instanceLock = lock
        case .failure(let failure):
            if failure == .alreadyRunning {
                log.info(
                    .serviceStopping,
                    [(.version, .string(AppVersion.string)), (.reason, .string(alreadyRunningReason))])
            }
            return .failure(failure)
        }
        // 5. 子プロセス
        let runner = ProcessRunner()
        // 6. 三重ロックの評価（init は検証しない。署名の要件は AppIdentity から。T-36）
        let locks = LockEvaluator(
            layout: layout, verifier: CodeSignatureVerifier(requirement: ReaperSignature.production), runner: runner,
            log: log.withCategory("pipeline"))
        // 7. 設定（無ければ既定を書く）
        let config = ConfigStore(
            layout: layout, catalog: catalog, log: log.withCategory("pipeline"),
            observeReaperConf: { await locks.observeReaperConf() })
        // 7 の中. ロック 1 の修復口を挿してから読む（起動時の CV-30 を 1 回目の読み込みで直す。PLAN §6.1・T-40）。
        // IngestService は読み込んだ設定の時刻帯とログで 11 に作るので、DeletionEnabler には中継を渡して 11 でつなぐ
        let enablerIngest = LateBoundIngest()
        let enabler = DeletionEnabler(
            layout: layout, paths: paths, config: config,
            verifier: CodeSignatureVerifier(requirement: ReaperSignature.production),
            ingest: enablerIngest, log: log.withCategory("pipeline"))
        await config.setLock1Reconciler { [enabler] in await enabler.reconcileLock1() }
        let loaded = await config.load()  // 修復口を挿した後に読む
        // 8. ログを設定で作り直す（ここから後のログだけが設定のレベルに従う）。時刻帯とログに使う値は EffectiveSettings の
        // 1 か所で解き、AppContext に残す（Store・IngestService・AppLog は読み直しで変わらないので、違えばパネルに出す。F-84）。
        // 設定が読めなければ手順 4 と同じ値（TimeZone.current・INFO・本文を出さない）
        var loadedConfig: AppConfig?
        if case .valid(let c) = loaded { loadedConfig = c }
        let running = EffectiveSettings.resolve(loadedConfig, current: bootTimeZone)
        let zone = ZonedTime(timeZone: running.timeZone)
        log = AppLog(
            sink: sink, level: running.logLevel, unsafeContent: running.unsafeLogContent, zone: zone, clock: clock,
            category: "app")
        // 9. DB
        let store: Store
        do { store = try Store(url: layout.database, clock: clock, zone: zone) } catch {
            return .failure(.database(ErrorText.describe(error)))
        }
        // 10. LLM
        let llama = LlamaServerSupervisor(
            runner: runner, paths: paths, layout: layout, clock: clock, sleeper: TaskSleeper(),
            log: log.withCategory("llm"), factory: EphemeralSessionFactory())
        // 11. 取り込み
        let ingest = IngestService(
            deps: IngestDependencies(
                layout: layout,
                configProvider: { await config.current() },
                store: store,
                inspector: SystemMountInspector(),
                remounter: DiskutilRemounter(
                    runner: runner, inspector: SystemMountInspector(), useMountPoint: Bootstrap.useMountPoint),
                mountEvents: WorkspaceMountEventSource(),
                reader: DeviceReader(),
                clock: clock, sleeper: TaskSleeper(), zone: zone,
                log: log.withCategory("device"), volumesRoot: Contract.volumesRoot))
        enablerIngest.bind(ingest)
        // 12. Worker（verificationCache は 14 のモデルと共有する。WorkerDependencies へ足すチケットは未決）
        let verificationCache = ModelVerificationCache()
        let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
        let worker = Worker(
            deps: WorkerDependencies(
                layout: layout, paths: paths, store: store, config: config, ingest: ingest,
                runner: runner, llama: llama,
                chatTransportFactory: { handle, cfg in
                    LoopbackChatTransport(
                        endpoint: handle.endpoint, apiKey: handle.apiKey, modelID: handle.modelID, config: cfg,
                        factory: EphemeralSessionFactory())
                },
                clock: clock, sleeper: TaskSleeper(), log: log.withCategory("pipeline"),
                license: AlwaysAllowLicenseGate(), catalog: catalog,
                physicalMemoryBytes: physicalMemoryBytes, locks: locks, volumeOpener: SystemVolumeOpener()))
        // 12 の後. 診断の依存（Worker とは別。書ける Store を渡さない。PT-17）
        let diagnostics = DiagnosticsDependencies(
            layout: layout, paths: paths, catalog: catalog, config: config, ingest: ingest, locks: locks,
            runner: runner, verificationCache: verificationCache, signature: SecAppSignatureReader(),
            bundleURL: Bundle.main.bundleURL, physicalMemoryBytes: physicalMemoryBytes, clock: clock,
            log: log.withCategory("pipeline"))
        // 13. ロック 1 の修復は 7 でつないだ（load() より前に挿す。T-40）
        // 14. モデル
        let hashChunkBytes =
            (loadedConfig?.audio.hashChunkBytes) ?? AppConfig.defaults(timeZone: "UTC").audio.hashChunkBytes
        let downloader = ModelDownloader(
            layout: layout, factory: EphemeralDownloadSessionFactory(),
            log: log.withCategory("models"), hashChunkBytes: hashChunkBytes)
        let models = ModelManager(
            layout: layout, catalog: catalog, downloader: downloader,
            cache: verificationCache, log: log.withCategory("models"), hashChunkBytes: hashChunkBytes)
        // 14 の後. 前回の取り込みが途中で終わって残った models/llm/.custom-import-*.gguf.part を消す（F-83。PLAN §8.10）。
        // 単一起動のロック（4 の後）を取った後なので、ほかのインスタンスの取り込みの途中のファイルは消さない。
        // Worker と取り込みを始める（15）より前。消した数を出す既存のログのイベントは無いので出さない
        await models.discardStaleImports()
        // 15. Worker.start()（復旧）を終えてから Worker のループと IngestService.start()（走査）を始める（PLAN §8.15）
        let ctx = AppContext(
            layout: layout, paths: paths, clock: clock, log: log, catalog: catalog, config: config, store: store,
            runner: runner, locks: locks, diagnostics: diagnostics, llama: llama, ingest: ingest, worker: worker,
            enabler: enabler, models: models, downloader: downloader,
            loginItem: SystemLoginItem(), uiState: UIStateStore(url: layout.uiState),
            physicalMemoryBytes: physicalMemoryBytes, instanceLock: instanceLock, runningSettings: running)
        ctx.workerTask = await startServices(
            workerStart: { await worker.start() }, workerRun: { await worker.run() },
            ingestStart: { await ingest.start() })
        // 16.
        return .success(ctx)
    }

    /// 2 つ目の起動が出す `service_stopping` の reason（付録 A.4。F-76）
    static let alreadyRunningReason = "already_running"

    /// 単一起動のロック（F-76）。`<HOME>/state/app.lock`（reaper.lock とは別）を `FileLock.tryAcquireResult` で取る（待たない）。
    /// ほかが持っていれば（EWOULDBLOCK）`.alreadyRunning`。開けない・flock がほかの理由で失敗したら `.instanceLock`
    /// （F-84。別のインスタンスが動いているとは限らないので、黙って終わらずに知らせる）。state/ は先に作っておくこと（手順 2）。
    /// fd は O_CLOEXEC なので子プロセス（whisper-cli・llama-server・reaper）はロックを受け継がない（アプリが落ちれば外れる）
    static func acquireInstanceLock(layout: HomeLayout) -> Result<FileLock, BootFailure> {
        let path = layout.relativePath(of: layout.appLock) ?? layout.appLock.path(percentEncoded: false)
        switch FileLock.tryAcquireResult(url: layout.appLock) {
        case .success(let lock): return .success(lock)
        case .failure(.held): return .failure(.alreadyRunning)
        case .failure(.openFailed(let e)): return .failure(.instanceLock(path: path, reason: errnoText("open", e)))
        case .failure(.lockFailed(let e)): return .failure(.instanceLock(path: path, reason: errnoText("flock", e)))
        }
    }

    /// `<段>: errno <n> (<strerror>)`（F-84。起動の失敗の警告に出す）
    static func errnoText(_ stage: String, _ e: Int32) -> String {
        stage + ": errno " + String(e) + " (" + String(cString: strerror(e)) + ")"
    }

    /// 起動の順（PLAN §8.15）: 復旧（`Worker.start()`）を**待ってから** Worker のループを作り、最後に走査を始める。
    /// Task の開始順は保証されないので、`run()` の先頭の `start()` には頼らない（2 回目の `start()` は 1 回目の完了を待って即座に戻る）。
    /// 戻り値は `run()` を回しているタスク（終了で待つ）。
    static func startServices(
        workerStart: @escaping @Sendable () async -> Void,
        workerRun: @escaping @Sendable () async -> Void,
        ingestStart: @escaping @Sendable () async -> Void
    ) async -> Task<Void, Never> {
        await workerStart()
        let task = Task { await workerRun() }
        await ingestStart()
        return task
    }
}

/// DeletionEnabler を IngestService より先に作るための中継（T-40）。
/// 修復口は最初の `config.load()` より前に挿す（PLAN §6.1）が、IngestService は読み込んだ設定の時刻帯とログで作るため。
/// `bind` の前の呼び出しは「観測なし・見送り」を返す（起動が終わる前に無効化は呼ばれない）。
final class LateBoundIngest: IngestPort {
    private let target = Mutex<IngestService?>(nil)

    func bind(_ ingest: IngestService) { target.withLock { $0 = ingest } }

    func latestSnapshot() async -> DeviceSnapshot? { await target.withLock { $0 }?.latestSnapshot() }

    func state() async -> IngestState { await target.withLock { $0 }?.state() ?? .idle }

    func updates() async -> AsyncStream<Void> {
        guard let ingest = target.withLock({ $0 }) else { return AsyncStream { $0.finish() } }
        return await ingest.updates()
    }

    func scanNow() async -> UInt64? { await target.withLock { $0 }?.scanNow() }
}
