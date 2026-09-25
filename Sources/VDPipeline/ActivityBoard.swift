// 今の工程の表示とスリープの抑止（PLAN §8.15）。
import Foundation
import Synchronization

/// スリープの抑止（PLAN §8.15）。begin / end は何度呼んでもよい（既に同じ状態なら何もしない）。
protocol SleepAssertion: Sendable {
    func begin()
    func end()
}

/// ProcessInfo の activity でアイドルスリープを抑止する。
final class ProcessInfoSleepAssertion: SleepAssertion {
    static let reason = "VoiceDock が録音を処理しています"

    private let token = Mutex<(any NSObjectProtocol)?>(nil)

    init() {}

    /// トークンが無ければ ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled,
    /// .suddenTerminationDisabled], reason: Self.reason) を保持する。
    func begin() {
        token.withLock { current in
            if current == nil {
                current = ProcessInfo.processInfo.beginActivity(
                    options: [.idleSystemSleepDisabled, .suddenTerminationDisabled], reason: Self.reason)
            }
        }
    }

    /// トークンが在れば ProcessInfo.processInfo.endActivity(token) して nil に。
    func end() {
        token.withLock { current in
            if let held = current {
                ProcessInfo.processInfo.endActivity(held)
                current = nil
            }
        }
    }
}

/// 今の工程（status() に出す）。.idle 以外になったら begin、.idle になったら end。
final class ActivityBoard: Sendable {
    private let assertion: any SleepAssertion
    private let activity = Mutex<WorkerActivity>(.idle)

    init(assertion: any SleepAssertion) {
        self.assertion = assertion
    }

    func set(_ activity: WorkerActivity) {
        self.activity.withLock { $0 = activity }
        if activity == .idle {
            assertion.end()
        } else {
            assertion.begin()
        }
    }

    var current: WorkerActivity { activity.withLock { $0 } }
}
