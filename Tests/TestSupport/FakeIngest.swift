// IngestPort の偽物（Worker のテスト用。00-api-map §15。作り手 T-18）。走査もコピーもしない。
import Foundation
import VDCore
import VDDevice
import VDPipeline

/// IngestPort の偽物（Worker のテスト用）。走査もコピーもしない。
public actor FakeIngest: IngestPort {
    private var snapshot: DeviceSnapshot?
    private var ingestState: IngestState
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var calls = 0

    public init(snapshot: DeviceSnapshot? = nil, state: IngestState = .idle) {
        self.snapshot = snapshot
        self.ingestState = state
    }

    public func setSnapshot(_ s: DeviceSnapshot?) { snapshot = s }

    public func setState(_ s: IngestState) { ingestState = s }

    /// 購読中の updates() に 1 つ流す
    public func sendUpdate() {
        for continuation in continuations.values { continuation.yield(()) }
    }

    public var scanNowCalls: Int { calls }

    public func latestSnapshot() -> DeviceSnapshot? { snapshot }

    public func state() -> IngestState { ingestState }

    /// bufferingNewest(1)
    public func updates() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeContinuation(id) } }
        return stream
    }

    /// scanNowCalls += 1、snapshot?.generation を返す
    public func scanNow() async -> UInt64? {
        calls += 1
        return snapshot?.generation
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }

    /// テスト用の snapshot（devices は deviceID → relpaths。readOnly false、freeBytes nil、mountPath "/tmp/vd-fake/<id>"）
    public static func snapshot(
        generation: UInt64 = 1, completedAt: Instant, connectEpoch: UInt64 = 0,
        devices: [String: Set<String>] = [:]
    ) -> DeviceSnapshot {
        var observed: [String: DeviceObservation] = [:]
        for (id, relpaths) in devices {
            observed[id] = DeviceObservation(
                deviceID: id, mountPath: "/tmp/vd-fake/" + id, deviceNode: nil, readOnly: false, freeBytes: nil,
                relpaths: relpaths)
        }
        return DeviceSnapshot(
            generation: generation, completedAt: completedAt, connectEpoch: connectEpoch, devices: observed,
            unavailable: [:], notListableErrno: [:])
    }
}
