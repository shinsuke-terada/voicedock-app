// IngestService が使う部品の束（PLAN §8.1）。T-15 が remounter と mountEvents を inspector の後に足す。
import Foundation
import VDContract
import VDCore
import VDStore

public struct IngestDependencies: Sendable {
    public let layout: HomeLayout
    /// 設定エラー中は nil
    public let configProvider: @Sendable () async -> AppConfig?
    public let store: Store
    public let inspector: any MountInspector
    public let reader: DeviceReader
    public let coexistence: CoexistenceGuard
    public let clock: any AppClock
    public let sleeper: any Sleeper
    public let zone: ZonedTime
    public let log: AppLog
    /// 本番は Contract.volumesRoot。テストは必ず一時ディレクトリ
    public let volumesRoot: String

    public init(
        layout: HomeLayout, configProvider: @escaping @Sendable () async -> AppConfig?, store: Store,
        inspector: any MountInspector, reader: DeviceReader, coexistence: CoexistenceGuard, clock: any AppClock,
        sleeper: any Sleeper, zone: ZonedTime, log: AppLog, volumesRoot: String
    ) {
        self.layout = layout
        self.configProvider = configProvider
        self.store = store
        self.inspector = inspector
        self.reader = reader
        self.coexistence = coexistence
        self.clock = clock
        self.sleeper = sleeper
        self.zone = zone
        self.log = log
        self.volumesRoot = volumesRoot
    }
}
