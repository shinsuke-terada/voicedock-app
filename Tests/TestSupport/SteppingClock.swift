// 呼ばれるたびに進む時計（経過時間・時間上限を測る処理のテスト用。00-api-map §15。T-10）。
import Foundation
import Synchronization
import VDCore

/// now() と uptime() のどちらも、呼ばれるたびに step ずつ進む時計（経過時間・時間上限を測る処理のテスト用。00-api-map §15）。
/// now() は start、start + step、start + 2·step … を、uptime() は .zero、step、2·step … を返す（返してから進める）。now と uptime は別々に数える。
public final class SteppingClock: AppClock {
    private struct State {
        var nextNow: Instant
        var nextUptime: Duration
    }

    private let stepMilliseconds: Int64
    private let state: Mutex<State>

    public init(start: Instant, stepMilliseconds: Int64) {
        self.stepMilliseconds = stepMilliseconds
        state = Mutex(State(nextNow: start, nextUptime: .zero))
    }

    public func now() -> Instant {
        state.withLock { state in
            let current = state.nextNow
            state.nextNow = current.adding(milliseconds: stepMilliseconds)
            return current
        }
    }

    public func uptime() -> Duration {
        state.withLock { state in
            let current = state.nextUptime
            state.nextUptime = current + .milliseconds(stepMilliseconds)
            return current
        }
    }
}
