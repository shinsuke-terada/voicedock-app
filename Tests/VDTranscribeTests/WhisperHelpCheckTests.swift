// WhisperHelpCheck のテスト（T-17 §6.4。DR-04）。
import Foundation
import TestSupport
import Testing

@testable import VDTranscribe

@Suite("WhisperHelpCheck")
struct WhisperHelpCheckTests {
    static let allFlags = [
        "--vad", "--vad-model", "--vad-threshold", "--vad-min-speech-duration-ms", "--vad-min-silence-duration-ms",
        "--vad-speech-pad-ms",
    ]

    @Test("VAD ありの help は欠けなし")
    func helpWithVADHasAllFlags() {
        #expect(WhisperHelpCheck.missingVADFlags(helpOutput: FakeWhisper.helpWithVAD).isEmpty)
    }

    @Test("VAD なしの help は 6 つ全部欠ける")
    func helpWithoutVADMissesAll() {
        #expect(WhisperHelpCheck.vadFlags == Self.allFlags)
        #expect(WhisperHelpCheck.missingVADFlags(helpOutput: FakeWhisper.helpWithoutVAD) == Self.allFlags)
    }

    @Test("--vad-model だけでは --vad を満たさない")
    func prefixIsNotEnough() {
        let missing = WhisperHelpCheck.missingVADFlags(helpOutput: "  --vad-model FNAME\n")
        #expect(missing.contains("--vad"))
        #expect(!missing.contains("--vad-model"))
    }

    @Test("末尾の , を除いて照合する")
    func trailingCommaIsIgnored() {
        let missing = WhisperHelpCheck.missingVADFlags(helpOutput: "-vm FNAME, --vad-model FNAME\n  --vad,")
        #expect(!missing.contains("--vad"))
        #expect(!missing.contains("--vad-model"))
    }

    @Test("DR-04 固定した whisper-cli の help に 6 フラグが在る")
    func realHelpFixtureHasAllFlags() throws {
        let data = try Data(contentsOf: PackageRoot.file("Tests/Fixtures/whisper-cli-help.txt"))
        let text = String(decoding: data, as: UTF8.self)
        #expect(WhisperHelpCheck.missingVADFlags(helpOutput: text).isEmpty)
    }
}
