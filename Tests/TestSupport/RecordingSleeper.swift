// 待たずに待ち秒を記録する Sleeper（CR-08 の差し替え。T-10）。
import Foundation
import Synchronization
import VDCore

/// 待たずに待ち秒を記録する。clock を渡すとその秒数だけ進める。
public final class RecordingSleeper: Sleeper {
    private let clock: FixedClock?
    private let seconds = Mutex<[Int]>([])

    public init(clock: FixedClock? = nil) {
        self.clock = clock
    }

    public func sleep(seconds value: Int) async throws {
        seconds.withLock { $0.append(value) }
        clock?.advance(seconds: value)
    }

    public var recorded: [Int] { seconds.withLock { $0 } }
}
