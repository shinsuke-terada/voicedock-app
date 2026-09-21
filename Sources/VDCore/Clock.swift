// 時計と待ち（CR-08）。`Date()` と単調時計を読んでよい唯一のファイル（PT-09）。
import Foundation

/// 時計（CR-08）。標準ライブラリの `Clock` と名前を分ける。
public protocol AppClock: Sendable {
    /// 壁時計の現在（毎回読む。tick の先頭で固定しない。TIME-04）
    func now() -> Instant
    /// 単調時計（TTL やタイムアウトの計測用。スリープ中も進む）
    func uptime() -> Duration
}

public struct SystemClock: AppClock {
    private let origin: ContinuousClock.Instant
    public init() { origin = ContinuousClock.now }
    public func now() -> Instant { Instant(date: Date()) }
    public func uptime() -> Duration { origin.duration(to: ContinuousClock.now) }
}

/// 待ち（工程内リトライ・安定性判定・ポーリング）。テストは RecordingSleeper で待たない。
public protocol Sleeper: Sendable {
    func sleep(seconds: Int) async throws
}

public struct TaskSleeper: Sleeper {
    public init() {}
    /// `Task.sleep(for: .seconds(seconds))`。0 以下なら何もしない。キャンセルで CancellationError。
    public func sleep(seconds: Int) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(for: .seconds(seconds))
    }
}
