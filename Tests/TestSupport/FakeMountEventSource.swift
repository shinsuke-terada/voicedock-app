// MountEventSource の差し替え（T-15。00-api-map §15）。send() で再走査の契機を起こす。
import Foundation
import VDDevice

/// MountEventSource の差し替え。Continuation の一覧は内部の actor が持つ（Mutex を使わない）
public final class FakeMountEventSource: MountEventSource, Sendable {
    private actor Box {
        var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

        func add(_ id: UUID, _ continuation: AsyncStream<Void>.Continuation) { continuations[id] = continuation }
        func remove(_ id: UUID) { continuations[id] = nil }
        func yield() { for continuation in continuations.values { continuation.yield(()) } }
        var count: Int { continuations.count }
    }

    private let box = Box()

    public init() {}

    public func events() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        let id = UUID()
        let box = self.box
        continuation.onTermination = { _ in Task { await box.remove(id) } }
        Task { await box.add(id, continuation) }
        return stream
    }

    /// 登録済みの購読の数（events() の登録は Task で後から行われるので、send() の前にテストが待つため。@testable で使う）
    var subscriberCount: Int {
        get async { await box.count }
    }

    /// 購読中の全ストリームへ () を流す
    public func send() {
        let box = self.box
        Task { await box.yield() }
    }
}
