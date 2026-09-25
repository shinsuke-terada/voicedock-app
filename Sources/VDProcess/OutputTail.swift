// パイプの出力の末尾だけを持つ。読み取りのスレッドと呼び手が共有する（Mutex。@unchecked を使わない）。
import Foundation
import Synchronization

final class OutputTail: Sendable {
    let limit: Int
    private let state: Mutex<State>
    struct State {
        var data = Data()
        var finished = false
        var stopRequested = false
    }

    init(limit: Int) {
        self.limit = limit
        self.state = Mutex(State())
    }

    /// 末尾 limit バイトだけを残す
    func append(_ bytes: UnsafeRawBufferPointer) {
        state.withLock { s in
            s.data.append(contentsOf: bytes)
            if s.data.count > limit { s.data = Data(s.data.suffix(limit)) }
        }
    }
    func finish() { state.withLock { $0.finished = true } }
    func requestStop() { state.withLock { $0.stopRequested = true } }
    var isFinished: Bool { state.withLock { $0.finished } }
    var shouldStop: Bool { state.withLock { $0.stopRequested } }
    var snapshot: Data { state.withLock { $0.data } }
}
