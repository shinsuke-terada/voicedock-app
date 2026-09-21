// 停止要求のフラグ（ハンドラはフラグを立てるだけ。CONC-11）。
import Synchronization

/// 停止要求（ハンドラはフラグを立てるだけ。CONC-11）。
final class StopFlag: Sendable {
    private let flag = Mutex<Bool>(false)

    init() {}

    func set() { flag.withLock { $0 = true } }

    var isSet: Bool { flag.withLock { $0 } }
}
