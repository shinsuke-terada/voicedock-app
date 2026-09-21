// Worker と工程の依存（本番の実装は VoiceDockApp/Bootstrap だけが組み立てる）。後続チケットはフィールドを足すだけ。
import VDContract
import VDCore
import VDProcess
import VDStore

/// Worker と工程の依存（00-api-map §11）。タイムゾーンは持たない（tick ごとに設定から作る）。
public struct WorkerDependencies: Sendable {
    public let layout: HomeLayout
    public let paths: AppPaths
    public let store: Store
    public let config: ConfigStore
    public let ingest: any IngestPort
    public let runner: any ProcessRunning
    public let catalog: ModelCatalog
    public let license: any LicenseGate
    public let clock: any AppClock
    public let sleeper: any Sleeper
    public let log: AppLog

    public init(
        layout: HomeLayout, paths: AppPaths, store: Store, config: ConfigStore, ingest: any IngestPort,
        runner: any ProcessRunning, catalog: ModelCatalog, license: any LicenseGate,
        clock: any AppClock, sleeper: any Sleeper, log: AppLog
    ) {
        self.layout = layout
        self.paths = paths
        self.store = store
        self.config = config
        self.ingest = ingest
        self.runner = runner
        self.catalog = catalog
        self.license = license
        self.clock = clock
        self.sleeper = sleeper
        self.log = log
    }
}
