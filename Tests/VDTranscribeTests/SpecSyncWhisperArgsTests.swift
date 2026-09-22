// whisper-cli の argv と docs/SPEC.md S11（PLAN §8.4 の text フェンス）の照合（issue #18。PLAN F-68。T-17 §9）。
// SPEC の語から先頭の実行ファイルを除き、`<HOME>`・`<slug>`・`<threads>` を置き換えて WhisperArgs.build の既定値と比べる。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDTranscribe

@Suite("SpecSyncWhisperArgs")
struct SpecSyncWhisperArgsTests {
    static let home = "/tmp/vd-home"
    static let slug = "0123456789abcdef"
    static let threads = 6

    /// SPEC の語の置き換え（先頭の実行ファイルは argv に含めない）。
    static func expected(_ words: [String]) -> [String] {
        words.dropFirst().map {
            $0.replacingOccurrences(of: "<HOME>", with: home)
                .replacingOccurrences(of: "<slug>", with: slug)
                .replacingOccurrences(of: "<threads>", with: String(threads))
        }
    }

    @Test("argv が SPEC S11 と逐語で同じ（先頭の実行ファイルを除く）")
    func whisperArgvMatchesSpec() throws {
        let words = try SpecDocument.load().whisperArgv()
        #expect(words.first == "<bundle>/Contents/Helpers/whisper-cli")
        let argv = WhisperArgs.build(
            model: URL(fileURLWithPath: "\(Self.home)/models/whisper/ggml-large-v3-turbo-q5_0.bin"),
            input: URL(fileURLWithPath: "\(Self.home)/staging/\(Self.slug)/audio16k.wav"),
            outputBase: URL(fileURLWithPath: "\(Self.home)/staging/\(Self.slug)/whisper"),
            config: AppConfig.defaults(timeZone: "Asia/Tokyo").transcription,
            vadModel: URL(fileURLWithPath: "\(Self.home)/models/vad/ggml-silero-v5.1.2.bin"),
            threads: Self.threads)
        #expect(argv == Self.expected(words))
    }
}
