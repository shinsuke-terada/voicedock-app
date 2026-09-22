// IngestService が使う部品の束（PLAN §8.1）。並びは 00-api-map §5。
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
    public let remounter: any Remounter
    public let mountEvents: any MountEventSource
    public let reader: DeviceReader
    public let clock: any AppClock
    public let sleeper: any Sleeper
    public let zone: ZonedTime
    public let log: AppLog
    /// 本番は Contract.volumesRoot。テストは必ず一時ディレクトリ
    public let volumesRoot: String

    public init(
        layout: HomeLayout, configProvider: @escaping @Sendable () async -> AppConfig?, store: Store,
        inspector: any MountInspector, remounter: any Remounter, mountEvents: any MountEventSource,
        reader: DeviceReader, clock: any AppClock,
        sleeper: any Sleeper, zone: ZonedTime, log: AppLog, volumesRoot: String
    ) {
        self.layout = layout
        self.configProvider = configProvider
        self.store = store
        self.inspector = inspector
        self.remounter = remounter
        self.mountEvents = mountEvents
        self.reader = reader
        self.clock = clock
        self.sleeper = sleeper
        self.zone = zone
        self.log = log
        self.volumesRoot = volumesRoot
    }
}
