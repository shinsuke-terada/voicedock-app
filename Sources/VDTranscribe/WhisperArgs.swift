// whisper-cli の argv（PLAN §8.4。voicedock transcribe.py の build_argv と同じ並び）。
import Foundation
import VDCore

public enum WhisperArgs {
    /// `transcription.threads == 0` のときの上限。
    public static let maxAutoThreads = 8

    /// argv[0] を含まない引数の配列（ProcessSpec.arguments にそのまま渡す）。
    public static func build(
        model: URL, input: URL, outputBase: URL, config: TranscriptionConfig,
        vadModel: URL?, threads: Int
    ) -> [String] {
        var argv = ["-m", p(model), "-f", p(input), "-l", config.language, "-t", String(threads)]
        if config.vad.enabled {
            argv += [
                "--vad",
                "--vad-model", vadModel.map { p($0) } ?? "",
                "--vad-threshold", num(config.vad.threshold),
                "--vad-min-speech-duration-ms", String(config.vad.minSpeechDurationMs),
                "--vad-min-silence-duration-ms", String(config.vad.minSilenceDurationMs),
                "--vad-speech-pad-ms", String(config.vad.speechPadMs),
            ]
        }
        return argv + ["-oj", "-of", p(outputBase), "-np"]
    }

    /// 値が整数に等しく |x| < 1e15 なら整数の 10 進、そうでなければ Double.description（0.5→"0.5"、1.0→"1"）。
    public static func num(_ x: Double) -> String {
        if x.isFinite, x == x.rounded(.towardZero), abs(x) < 1e15 { return String(Int64(x)) }
        return x.description
    }

    /// configured > 0 ならその値、0 なら min(ProcessInfo.processInfo.activeProcessorCount, 8)。
    public static func resolvedThreads(_ configured: Int) -> Int {
        configured > 0 ? configured : min(ProcessInfo.processInfo.activeProcessorCount, maxAutoThreads)
    }

    /// パスの文字列化（00-api-map §0）。
    static func p(_ url: URL) -> String { url.path(percentEncoded: false) }
}
