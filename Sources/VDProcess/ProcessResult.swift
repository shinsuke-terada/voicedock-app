// 子プロセスの結果（PLAN §8.2）。
import Foundation

public struct ProcessResult: Sendable, Equatable {
    public enum Termination: Sendable, Equatable {
        case exited(Int32)  // 終了コード
        case signaled(Int32)  // シグナル番号
        case timedOut  // タイムアウト（または呼び手のタスクの取り消し）でこちらから止めた
        case spawnFailed(errno: Int32)
    }
    public static let stdoutTailLimit = 65_536  // --help の検査用
    public static let stderrTailLimit = 4_096

    public let termination: Termination
    public let stdoutTail: Data  // 末尾 stdoutTailLimit バイト
    public let stderrTail: Data  // 末尾 stderrTailLimit バイト
    /// 実行中に `ProcessRunner.terminateAll`（アプリの終了）がこの子のグループに SIGTERM を送った（F-82）。
    /// `termination` は実際の終わり方のまま（多くは `.signaled(SIGTERM)`。止める前に終わっていれば `.exited` のこともある）。
    /// 閉じた後で起動しなかった実行は偽のまま（`.spawnFailed(errno: ProcessRunner.closedErrno)` で見分ける。F-76）
    public let stoppedByTerminateAll: Bool

    public init(termination: Termination, stdoutTail: Data, stderrTail: Data, stoppedByTerminateAll: Bool = false) {
        self.termination = termination
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
        self.stoppedByTerminateAll = stoppedByTerminateAll
    }

    /// UTF-8 として読む（途中で切れた多バイト文字は U+FFFD になる）
    public var stdoutText: String { String(decoding: stdoutTail, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderrTail, as: UTF8.self) }
}
