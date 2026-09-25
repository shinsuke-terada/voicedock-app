// Worker が取り込み側に求めるもの（テストで FakeIngest に差し替える）。本番は IngestService（T-15）。
import VDDevice

/// Worker が取り込み側に求めるもの（00-api-map §11）。
public protocol IngestPort: Sendable {
    func latestSnapshot() async -> DeviceSnapshot?
    func state() async -> IngestState
    func updates() async -> AsyncStream<Void>
    func scanNow() async -> UInt64?
}

extension IngestService: IngestPort {}
