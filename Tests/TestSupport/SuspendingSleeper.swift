// 止められるまで戻らない Sleeper（T-15。00-api-map §15）。周期の走査を止めておくテスト用。
import Foundation
import VDCore

/// sleep はタスクが止められるまで戻らない（止められたら CancellationError）
public struct SuspendingSleeper: Sleeper {
    public init() {}

    public func sleep(seconds: Int) async throws {
        while true {
            try await Task.sleep(for: .seconds(3600))
        }
    }
}
