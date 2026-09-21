// 子プロセスの起動の指定。引数は配列だけ、環境変数は明示したものだけ（PLAN §8.2、PR-05 / PR-06）。
import Foundation

public struct ProcessSpec: Sendable, Equatable {
    public let executable: URL  // 絶対パスの file URL
    public let arguments: [String]  // argv[1...]（argv[0] は executable のパス）
    public let environment: [String: String]

    public init(executable: URL, arguments: [String], environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

public enum ProcessEnvironment {
    public static let path = "/usr/bin:/bin:/usr/sbin:/sbin"
    /// whisper-cli・llama-server・reaper 用
    public static let standard: [String: String] = ["PATH": path, "LANG": "en_US.UTF-8"]
    /// diskutil・launchctl 用（出力の文言をロケールに依存させない）
    public static let cLocale: [String: String] = ["PATH": path, "LC_ALL": "C"]
}

public enum SpawnError: Error, Equatable, Sendable {
    /// posix_spawn の戻り値（ENOENT: 無い、EACCES: 実行権が無い）。指定が不正なとき（相対パス・NUL を含む引数・= を含むか空の環境変数名）は EINVAL
    case spawnFailed(errno: Int32)
    /// pipe(2) の失敗
    case pipeFailed(errno: Int32)
}
