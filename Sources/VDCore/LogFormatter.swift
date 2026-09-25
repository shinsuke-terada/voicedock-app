// ログの 1 行の書式と値の引用・本文の遮断（PLAN §8.15。voicedock log.py と同じ書式）。
import Foundation

public enum LogFormatter {
    public static let redacted = "<redacted>"
    public static let maxValueScalars = 200

    /// `"<ts> <level.token> <event>"` の後に、fields を渡された順に `" key=value"` をつなぐ。
    /// redact が真なら、本文のキーと 200 スカラーを超える文字列を `<redacted>` に置き換える（PR-08）。
    public static func line(
        ts: String, level: LogLevel, event: LogEvent, fields: [(LogKey, LogValue)], redact: Bool
    ) -> String {
        var text = "\(ts) \(level.token) \(event.rawValue)"
        for (key, value) in fields {
            var shown = value
            if redact {
                if key.isContent {
                    shown = .string(redacted)
                } else if case .string(let s) = value, TextLimit.scalarCount(s) > maxValueScalars {
                    shown = .string(redacted)
                }
            }
            text += " \(key.rawValue)=\(formatValue(shown))"
        }
        return text
    }

    /// 空でなく全スカラーが U+0021〜U+007E で `"` でも `=` でもない文字列はそのまま、ほかは JSON で引用する。
    /// voicedock は Python の `$` のため末尾の改行 1 つを素通しした。本アプリは全体一致で判定し、改行を含む値は必ず引用する。
    public static func formatValue(_ v: LogValue) -> String {
        switch v {
        case .null:
            return "null"
        case .bool(let flag):
            return flag ? "true" : "false"
        case .int(let number):
            return String(number)
        case .double(let number):
            return number.description
        case .string(let s):
            let plain =
                !s.isEmpty
                && s.unicodeScalars.allSatisfy { scalar in
                    (0x21...0x7E).contains(scalar.value) && scalar != "\"" && scalar != "="
                }
            return plain ? s : PyJSON.dumpsCompact(.string(s))
        }
    }
}
