// SIGTERM を受けたら『今の 1 件の後に止まる』（PLAN §8.9.4）。
import Darwin
import Synchronization

/// ファイルスコープの let（シグナルハンドラは捕捉を持てないのでグローバルに置く。`nonisolated(unsafe)` は使わない。PT-14）
private let stopFlag = Atomic<Bool>(false)

enum Signals {
    /// SIGTERM のハンドラを入れる。ハンドラはアトミックなフラグを立てるだけ（async-signal-safe）
    static func installTerminationHandler() {
        signal(SIGTERM, { _ in stopFlag.store(true, ordering: .relaxed) })
    }

    static var stopRequested: Bool { stopFlag.load(ordering: .relaxed) }
}
