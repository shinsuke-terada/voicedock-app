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

    public init(termination: Termination, stdoutTail: Data, stderrTail: Data) {
        self.termination = termination
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
    }

    /// UTF-8 として読む（途中で切れた多バイト文字は U+FFFD になる）
    public var stdoutText: String { String(decoding: stdoutTail, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderrTail, as: UTF8.self) }
}
