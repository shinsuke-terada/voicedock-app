// Worker と工程の依存（本番の実装は VoiceDockApp/Bootstrap だけが組み立てる）。後続チケットはフィールドを足すだけ。
import VDContract
import VDCore
import VDLLM
import VDProcess
import VDStore

/// Worker と工程の依存（00-api-map §11。並びは地図の相対順）。タイムゾーンは持たない（tick ごとに設定から作る）。
public struct WorkerDependencies: Sendable {
    public let layout: HomeLayout
    public let paths: AppPaths
    public let store: Store
    public let config: ConfigStore
    public let ingest: any IngestPort
    public let runner: any ProcessRunning
    public let llama: any LLMServerControl
    public let chatTransportFactory: ChatTransportFactory
    public let clock: any AppClock
    public let sleeper: any Sleeper
    public let log: AppLog
    public let license: any LicenseGate
    public let catalog: ModelCatalog
    /// ProcessInfo.processInfo.physicalMemory（Bootstrap が注入。ガードのテストで差し替える）
    public let physicalMemoryBytes: UInt64
    /// 乗り換えの走査（PLAN §8.13）。起動時に 1 回呼ぶ。
    public let importedKeys: ImportedKeysService

    public init(
        layout: HomeLayout, paths: AppPaths, store: Store, config: ConfigStore, ingest: any IngestPort,
        runner: any ProcessRunning, llama: any LLMServerControl, chatTransportFactory: @escaping ChatTransportFactory,
        clock: any AppClock, sleeper: any Sleeper, log: AppLog, license: any LicenseGate, catalog: ModelCatalog,
        physicalMemoryBytes: UInt64, importedKeys: ImportedKeysService
    ) {
        self.layout = layout
        self.paths = paths
        self.store = store
        self.config = config
        self.ingest = ingest
        self.runner = runner
        self.llama = llama
        self.chatTransportFactory = chatTransportFactory
        self.clock = clock
        self.sleeper = sleeper
        self.log = log
        self.license = license
        self.catalog = catalog
        self.physicalMemoryBytes = physicalMemoryBytes
        self.importedKeys = importedKeys
    }
}
