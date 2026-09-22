// Worker の状態（パネルの 1 行と要対応に使う。PLAN §8.12）。

/// requeue の契機（PLAN §5.4 の 1〜3）。
public enum RequeueReason: String, Sendable, Equatable { case startup, connect, manual }

/// パネルの 1 行の状態に使う（PLAN §8.12「文字起こし中 07:12 の録音」「要約中 2026-08-29」）。
public enum WorkerActivity: Equatable, Sendable {
    case idle
    case normalizing(partkey: String, startedAt: String)
    case transcribing(partkey: String, startedAt: String)
    case writingRawNote(sessionKey: String)
    case merging(sessionKey: String)
    case analyzing(sessionKey: String, dayDate: String)
    case writingDailyNote(sessionKey: String, dayDate: String)
}

/// Worker の今の工程と停止中の理由。
public struct WorkerStatus: Equatable, Sendable {
    public let activity: WorkerActivity
    /// PauseReason.allCases の順
    public let paused: [PauseReason]

    public init(activity: WorkerActivity, paused: [PauseReason]) {
        self.activity = activity
        self.paused = paused
    }
}
