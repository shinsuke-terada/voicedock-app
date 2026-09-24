// argmax-cli の argv（PLAN §8.4.1。F-89）。
import Foundation

public enum DiarizeArgs {
    /// `argmax-cli diarize --help` に在るべきフラグ（DR-18）。
    public static let requiredFlags = ["--audio-path", "--model-path", "--rttm-path", "--use-exclusive-reconciliation"]

    /// argv[0] を含まない引数の配列。先頭は "diarize"。
    public static func build(input: URL, models: URL, rttm: URL) -> [String] {
        [
            "diarize", "--audio-path", WhisperArgs.p(input), "--model-path", WhisperArgs.p(models),
            "--rttm-path", WhisperArgs.p(rttm), "--use-exclusive-reconciliation",
        ]
    }

    /// requiredFlags のうち help に語として無いもの（宣言順）。判定は `WhisperHelpCheck.containsFlag`（DR-18）。
    public static func missingFlags(helpOutput: String) -> [String] {
        requiredFlags.filter { !WhisperHelpCheck.containsFlag($0, in: helpOutput) }
    }
}
