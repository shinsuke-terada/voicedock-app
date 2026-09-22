// AppServices の偽物（T-30。VoiceDockAppTests の中だけ）。read が返す値を差し替え、呼ばれた操作を記録する。
import Foundation
import Synchronization
import VDCore

@testable import VoiceDockApp

/// AppServices の偽物。Mutex<State> で持つ（@unchecked Sendable を使わない。PT-14）。
final class FakeServices: AppServices {
    private struct State {
        var snapshot: AppSnapshot
        var reload: ConfigLoadResult = .invalid([])
        var requeueCount = 0
        var reloadCount = 0
        var scanCount = 0
        var lastConnectedSeen: [Instant?] = []
        var continuations: [AsyncStream<Void>.Continuation] = []
    }

    private let state: Mutex<State>

    init(_ snapshot: AppSnapshot) {
        state = Mutex(State(snapshot: snapshot))
    }

    func set(_ snapshot: AppSnapshot) { state.withLock { $0.snapshot = snapshot } }
    func setReload(_ result: ConfigLoadResult) { state.withLock { $0.reload = result } }

    var requeueCount: Int { state.withLock { $0.requeueCount } }
    var reloadCount: Int { state.withLock { $0.reloadCount } }
    var scanCount: Int { state.withLock { $0.scanCount } }
    /// read に渡された値
    var lastConnectedSeen: [Instant?] { state.withLock { $0.lastConnectedSeen } }
    /// read が呼ばれた回数
    var readCount: Int { state.withLock { $0.lastConnectedSeen.count } }

    /// updates() が呼ばれた回数（購読が始まったか）
    var subscriberCount: Int { state.withLock { $0.continuations.count } }

    /// updates() のストリームに 1 件流す
    func push() {
        let continuations = state.withLock { $0.continuations }
        for c in continuations { c.yield(()) }
    }

    func read(lastConnectedAt: Instant?) async -> AppSnapshot {
        state.withLock {
            $0.lastConnectedSeen.append(lastConnectedAt)
            return $0.snapshot
        }
    }

    func requeueManual() async { state.withLock { $0.requeueCount += 1 } }

    func reloadConfig() async -> ConfigLoadResult {
        state.withLock {
            $0.reloadCount += 1
            return $0.reload
        }
    }

    func scanNow() async { state.withLock { $0.scanCount += 1 } }

    func updates() async -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        state.withLock { $0.continuations.append(continuation) }
        return stream
    }
}

/// FinderOpening の偽物。渡された URL を順に覚える。
final class FakeFinder: FinderOpening {
    private let urls = Mutex<[URL]>([])

    var revealed: [URL] { urls.withLock { $0 } }

    func reveal(_ url: URL) { urls.withLock { $0.append(url) } }
}
