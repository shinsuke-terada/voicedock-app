// IngestPort の偽物（削除の流れのテスト用）。scanNow の台本を持つ（FakeIngest は scanNow で generation を進められないため）。作り手 T-38。
import VDDevice
import VDPipeline

/// IngestPort の偽物（削除の流れのテスト用）。走査もコピーもしない。
public actor ScriptedIngest: IngestPort {
    public enum Scan: Sendable {
        case publish(DeviceSnapshot)
        case skip
    }

    private var snapshot: DeviceSnapshot?
    private var scans: [Scan] = []
    private var scanner: (@Sendable (UInt64) -> DeviceSnapshot?)?
    private var calls = 0

    public init(snapshot: DeviceSnapshot?) {
        self.snapshot = snapshot
    }

    public func setSnapshot(_ s: DeviceSnapshot?) { snapshot = s }

    /// scanNow の台本（先頭から使う）
    public func script(_ scans: [Scan]) { self.scans = scans }

    /// 台本が尽きたときに使う走査（次の generation を渡す。nil を返すと見送り）
    public func setScanner(_ f: @escaping @Sendable (UInt64) -> DeviceSnapshot?) { scanner = f }

    public var scanNowCalls: Int { calls }

    public func latestSnapshot() -> DeviceSnapshot? { snapshot }

    /// .idle
    public func state() -> IngestState { .idle }

    /// 何も流さない
    public func updates() -> AsyncStream<Void> {
        AsyncStream { _ in }
    }

    public func scanNow() async -> UInt64? {
        calls += 1
        if !scans.isEmpty {
            switch scans.removeFirst() {
            case .publish(let s):
                snapshot = s
                return s.generation
            case .skip:
                return nil
            }
        }
        guard let scanner else { return nil }
        guard let s = scanner((snapshot?.generation ?? 0) + 1) else { return nil }
        snapshot = s
        return s.generation
    }
}
