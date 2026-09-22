// 本番の依存を組み立てる唯一の場所（PLAN §8.15 の起動手順）。ここ以外で本番の実装を new しない。
import AppKit
import Foundation
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
    /// ロックの観測（Phase 7 は DisabledLockObserver。T-36 が LockEvaluator に替える）
    let locks: any LockObserving
    /// 診断の依存（書ける Store を持たない。PT-17）
    let diagnostics: DiagnosticsDependencies
    let llama: LlamaServerSupervisor
    let ingest: IngestService
    let worker: Worker
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

    init(
        layout: HomeLayout, paths: AppPaths, clock: any AppClock, log: AppLog, catalog: ModelCatalog,
        config: ConfigStore, store: Store, runner: ProcessRunner, locks: any LockObserving,
        diagnostics: DiagnosticsDependencies, llama: LlamaServerSupervisor, ingest: IngestService,
        worker: Worker, models: ModelManager, downloader: ModelDownloader, loginItem: any LoginItemControlling,
        uiState: UIStateStore, physicalMemoryBytes: UInt64
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
        self.models = models
        self.downloader = downloader
        self.loginItem = loginItem
        self.uiState = uiState
        self.physicalMemoryBytes = physicalMemoryBytes
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

    var message: String {
        switch self {
        case .directories(let e): Strings.bootFailureDirectories(e)
        case .catalog(let e): Strings.bootFailureCatalog(e)
        case .database(let e): Strings.bootFailureDatabase(e)
        }
    }
}

/// 本番の組み立て（PLAN §8.15）。
enum Bootstrap {
    /// P0-02 で確定。実機では `-mountPoint` が使えない（docs/POC.md 章 3）。
    static let useMountPoint = false
    /// os.Logger の subsystem（= BUNDLE_ID。identity.env と同じ値）。T-36 が AppIdentity.bundleID に替える。
    static let logSubsystem = "io.github.shinsuke-terada.VoiceDock"

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
        // 4. 時計とログ（設定を読む前のログは既定のレベルで出す）
        let clock: any AppClock = SystemClock()
        let bootZone = ZonedTime(timeZone: TimeZone.current)
        let sink = TeeSink([OSLogSink(subsystem: logSubsystem), LogFile(url: layout.appLog)])
        var log = AppLog(sink: sink, level: .info, unsafeContent: false, zone: bootZone, clock: clock, category: "app")
        // 5. 子プロセス
        let runner = ProcessRunner()
        // 6. ロックの観測（何も読まない・何も起動しない。Phase 8 の T-36 が LockEvaluator に替える）
        let locks: any LockObserving = DisabledLockObserver()
        // 7. 設定（無ければ既定を書く）。T-36 が observeReaperConf を locks.observeReaperConf() に替える
        let config = ConfigStore(
            layout: layout, catalog: catalog, log: log.withCategory("pipeline"), observeReaperConf: { .missing })
        let loaded = await config.load()
        // 8. ログを設定で作り直す（ここから後のログだけが設定のレベルに従う）
        var zone = bootZone
        var loadedConfig: AppConfig?
        if case .valid(let c) = loaded {
            zone = ZonedTime(timeZone: TimeZone(identifier: c.timeZone) ?? .current)
            log = AppLog(
                sink: sink, level: LogLevel(configValue: c.logging.level) ?? .info,
                unsafeContent: c.logging.unsafeLogContent, zone: zone, clock: clock, category: "app")
            loadedConfig = c
        }
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
                physicalMemoryBytes: physicalMemoryBytes))
        // 12 の後. 診断の依存（Worker とは別。書ける Store を渡さない。PT-17）
        let diagnostics = DiagnosticsDependencies(
            layout: layout, paths: paths, catalog: catalog, config: config, ingest: ingest, locks: locks,
            runner: runner, verificationCache: verificationCache, signature: SecAppSignatureReader(),
            bundleURL: Bundle.main.bundleURL, physicalMemoryBytes: physicalMemoryBytes, clock: clock,
            log: log.withCategory("pipeline"))
        // 13. ロック 1 の修復をつなぐ（T-40 が `await config.setLock1Reconciler { await enabler.reconcileLock1() }` を書く）
        // 14. モデル
        let hashChunkBytes =
            (loadedConfig?.audio.hashChunkBytes) ?? AppConfig.defaults(timeZone: "UTC").audio.hashChunkBytes
        let downloader = ModelDownloader(
            layout: layout, factory: EphemeralDownloadSessionFactory(),
            log: log.withCategory("models"), hashChunkBytes: hashChunkBytes)
        let models = ModelManager(
            layout: layout, catalog: catalog, downloader: downloader,
            cache: verificationCache, log: log.withCategory("models"), hashChunkBytes: hashChunkBytes)
        // 15. Worker.start()（復旧）を終えてから Worker のループと IngestService.start()（走査）を始める（PLAN §8.15）
        let ctx = AppContext(
            layout: layout, paths: paths, clock: clock, log: log, catalog: catalog, config: config, store: store,
            runner: runner, locks: locks, diagnostics: diagnostics, llama: llama, ingest: ingest, worker: worker,
            models: models, downloader: downloader,
            loginItem: SystemLoginItem(), uiState: UIStateStore(url: layout.uiState),
            physicalMemoryBytes: physicalMemoryBytes)
        ctx.workerTask = await startServices(
            workerStart: { await worker.start() }, workerRun: { await worker.run() },
            ingestStart: { await ingest.start() })
        // 16.
        return .success(ctx)
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
