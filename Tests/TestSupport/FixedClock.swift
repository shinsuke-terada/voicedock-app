// 手で進める時計（CR-08 の差し替え。T-10）。
import Foundation
import Synchronization
import VDCore

/// 手で進める時計。now と uptime を同じだけ進める。
public final class FixedClock: AppClock {
    private struct State {
        var now: Instant
        var uptime: Duration
    }

    private let state: Mutex<State>

    public init(now: Instant, uptime: Duration = .zero) {
        state = Mutex(State(now: now, uptime: uptime))
    }

    /// `init(now: Instant(epochMillis:))` の短縮（T-11・T-14 などが使う）。
    public convenience init(epochMillis: Int64) {
        self.init(now: Instant(epochMillis: epochMillis))
    }

    public func now() -> Instant { state.withLock { $0.now } }
    public func uptime() -> Duration { state.withLock { $0.uptime } }

    public func set(_ now: Instant) {
        state.withLock { $0.now = now }
    }

    public func advance(seconds: Int) {
        advance(milliseconds: Int64(seconds) * 1000)
    }

    public func advance(milliseconds: Int64) {
        state.withLock { state in
            state.now = state.now.adding(milliseconds: milliseconds)
            state.uptime += .milliseconds(milliseconds)
        }
    }
}
