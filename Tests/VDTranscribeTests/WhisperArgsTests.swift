// WhisperArgs のテスト（T-17 §6.1。PLAN §8.4）。
import Foundation
import Testing
import VDCore

@testable import VDTranscribe

@Suite("WhisperArgs")
struct WhisperArgsTests {
    static let home = "/tmp/vd-home"
    static let slug = "0123456789abcdef"

    static let model = URL(fileURLWithPath: "\(home)/models/whisper/ggml-large-v3-turbo-q8_0.bin")
    static let input = URL(fileURLWithPath: "\(home)/staging/\(slug)/audio16k.wav")
    static let outputBase = URL(fileURLWithPath: "\(home)/staging/\(slug)/whisper")
    static let vadModel = URL(fileURLWithPath: "\(home)/models/vad/ggml-silero-v5.1.2.bin")

    static func defaults() -> TranscriptionConfig { AppConfig.defaults(timeZone: "Asia/Tokyo").transcription }

    static func build(_ config: TranscriptionConfig, threads: Int = 6) -> [String] {
        WhisperArgs.build(
            model: model, input: input, outputBase: outputBase, config: config, vadModel: vadModel, threads: threads)
    }

    /// `flag` の次の要素。
    static func value(after flag: String, in argv: [String]) -> String? {
        guard let index = argv.firstIndex(of: flag), index + 1 < argv.count else { return nil }
        return argv[index + 1]
    }

    @Test("argv が PLAN §8.4 と逐語一致")
    func argvMatchesPlan() {
        let h = Self.home
        let s = Self.slug
        #expect(
            Self.build(Self.defaults()) == [
                "-m", "\(h)/models/whisper/ggml-large-v3-turbo-q8_0.bin", "-f", "\(h)/staging/\(s)/audio16k.wav",
                "-l", "ja", "-t", "6", "--vad", "--vad-model", "\(h)/models/vad/ggml-silero-v5.1.2.bin",
                "--vad-threshold", "0.5", "--vad-min-speech-duration-ms", "250", "--vad-min-silence-duration-ms",
                "1000", "--vad-speech-pad-ms", "200", "-oj", "-of", "\(h)/staging/\(s)/whisper", "-np",
            ])
    }

    @Test("CE transcription.vad.threshold の値が --vad-threshold に渡る")
    func ceVADThreshold() {
        var config = Self.defaults()
        #expect(Self.value(after: "--vad-threshold", in: Self.build(config)) == "0.5")
        config.vad.threshold = 0.25
        #expect(Self.value(after: "--vad-threshold", in: Self.build(config)) == "0.25")
    }

    @Test("CE transcription.vad.minSpeechDurationMs の値が渡る")
    func ceVADMinSpeechDurationMs() {
        var config = Self.defaults()
        #expect(Self.value(after: "--vad-min-speech-duration-ms", in: Self.build(config)) == "250")
        config.vad.minSpeechDurationMs = 100
        #expect(Self.value(after: "--vad-min-speech-duration-ms", in: Self.build(config)) == "100")
    }

    @Test("CE transcription.vad.minSilenceDurationMs の値が渡る")
    func ceVADMinSilenceDurationMs() {
        var config = Self.defaults()
        #expect(Self.value(after: "--vad-min-silence-duration-ms", in: Self.build(config)) == "1000")
        config.vad.minSilenceDurationMs = 500
        #expect(Self.value(after: "--vad-min-silence-duration-ms", in: Self.build(config)) == "500")
    }

    @Test("CE transcription.vad.speechPadMs の値が渡る")
    func ceVADSpeechPadMs() {
        var config = Self.defaults()
        #expect(Self.value(after: "--vad-speech-pad-ms", in: Self.build(config)) == "200")
        config.vad.speechPadMs = 50
        #expect(Self.value(after: "--vad-speech-pad-ms", in: Self.build(config)) == "50")
    }

    @Test("CE transcription.language が -l に渡る")
    func ceTranscriptionLanguage() {
        var config = Self.defaults()
        #expect(Self.value(after: "-l", in: Self.build(config)) == "ja")
        config.language = "en"
        #expect(Self.value(after: "-l", in: Self.build(config)) == "en")
    }

    @Test("CE transcription.vad.enabled false なら VAD のフラグを 1 つも渡さない")
    func vadDisabledPassesNoVadFlag() {
        var config = Self.defaults()
        #expect(Self.build(config).filter { $0.hasPrefix("--vad") }.count == 6)
        config.vad.enabled = false
        let argv = Self.build(config)
        #expect(!argv.contains { $0.hasPrefix("--vad") })
        #expect(argv.last == "-np")
    }

    @Test("数値の書式", arguments: zip([0.5, 1.0, 0.25, 2.0, 0.1], ["0.5", "1", "0.25", "2", "0.1"]))
    func numFormat(value: Double, expected: String) {
        #expect(WhisperArgs.num(value) == expected)
    }

    @Test("CE transcription.threads > 0 はそのまま -t に渡る", arguments: [4, 16])
    func threadsFromConfig(threads: Int) {
        var config = Self.defaults()
        config.threads = threads
        let argv = Self.build(config, threads: WhisperArgs.resolvedThreads(config.threads))
        #expect(Self.value(after: "-t", in: argv) == String(threads))
    }

    @Test("threads = 0 は論理 CPU 数と 8 の小さい方")
    func zeroThreadsIsCapped() {
        let resolved = WhisperArgs.resolvedThreads(0)
        #expect(resolved == min(ProcessInfo.processInfo.activeProcessorCount, 8))
        #expect(resolved <= 8)
        #expect(resolved >= 1)
    }
}
