// whisper-cli --help に VAD の 6 フラグが逐語で在るか（DR-04。本アプリで強化）。
import Foundation

public enum WhisperHelpCheck {
    public static let vadFlags = [
        "--vad", "--vad-model", "--vad-threshold",
        "--vad-min-speech-duration-ms", "--vad-min-silence-duration-ms", "--vad-speech-pad-ms",
    ]

    /// フラグの直前に在ってよいもの（行頭・空白・`,`・`[`）。
    static let flagPrefixPattern = #"(?:^|[\s,\[])"#
    /// フラグの直後に在ってよいもの（行末・空白・`,`・`=`・`]`・`<`）。
    static let flagSuffixPattern = #"(?:$|[\s,=\]<])"#

    /// 欠けたフラグを vadFlags の順で返す（空なら全部在る）。
    /// DR-04: 語としての完全一致。`--vad` は `--vad-model` の接頭辞なので部分一致では判定しない。
    public static func missingVADFlags(helpOutput: String) -> [String] {
        vadFlags.filter { !containsFlag($0, in: helpOutput) }
    }

    /// help に flag が語として在るか（DR-04・DR-18。`DiarizeArgs.missingFlags` と共有する）。
    /// 直前が行頭・空白・`,`・`[`、直後が行末・空白・`,`・`=`・`]`・`<`。
    /// pattern は毎回コンパイルする（NSRegularExpression は Sendable が保証されないので static に持たない）。
    static func containsFlag(_ flag: String, in help: String) -> Bool {
        let pattern = flagPrefixPattern + NSRegularExpression.escapedPattern(for: flag) + flagSuffixPattern
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return false
        }
        return regex.firstMatch(in: help, range: NSRange(location: 0, length: help.utf16.count)) != nil
    }
}
