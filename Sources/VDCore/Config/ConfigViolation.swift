// 設定の違反（CV）と読み込みの結果（PLAN §6.1・§6.4）。違反は例外にせず配列で返す。
import Foundation

/// 設定の違反 1 件。`Error` は `ConfigMigrator.migrate` の `Result` の失敗側に置くため（例外としては投げない）。
public struct ConfigViolation: Error, Equatable, Sendable {
    /// "CV-nn"
    public let rule: String
    public let code: ErrorCode
    /// "device.stabilityChecks"、配列の要素は "device.includeVolumes.0"、ファイル全体は "<file>"
    public let keyPath: String
    public let message: String

    public init(rule: String, code: ErrorCode, keyPath: String, message: String) {
        self.rule = rule
        self.code = code
        self.keyPath = keyPath
        self.message = message
    }

    /// voicedock config.py:67-69 と同じ 1 行表記（区切りは空白 2 つ）。
    public var rendered: String { "\(rule)  \(code.rawValue)  \(keyPath): \(message)" }
}

/// config.json の読み込みの結果。
public enum ConfigLoadResult: Equatable, Sendable {
    case valid(AppConfig)
    case invalid([ConfigViolation])
}
