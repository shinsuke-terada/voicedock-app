// Vendor の --help の fixture に、アプリが渡すフラグがすべて在ることの検査（PLAN §8.4・§8.5・§11.2。T-03）。
import Foundation
import TestSupport
import Testing

@Suite("VendorFixture")
struct VendorFixtureTests {
    /// whisper-cli に渡すフラグ（PLAN §8.4 の argv）。T-17 で `WhisperHelpCheck.vadFlags` と argv の組み立てに置き換える。
    static let whisperFlags = [
        "-m", "-f", "-l", "-t", "--vad", "--vad-model", "--vad-threshold", "--vad-min-speech-duration-ms",
        "--vad-min-silence-duration-ms", "--vad-speech-pad-ms", "-oj", "-of", "-np",
    ]

    /// llama-server に渡すフラグ（PLAN §8.5）。T-21 で `LlamaArgs.usedFlags` に置き換える。
    static let llamaFlags = [
        "--model", "--host", "--port", "--api-key-file", "--ctx-size", "--n-gpu-layers", "--jinja",
        "--parallel", "--no-webui", "--offline",
    ]

    /// `flag` が help の中に「前後が空白・カンマ・行頭行末・=」で区切られた語として在るか。
    static func contains(_ help: String, flag: String) throws -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: flag)
        let regex = try NSRegularExpression(pattern: "(^|[\\s,])\(escaped)([\\s,=]|$)", options: [.anchorsMatchLines])
        return regex.firstMatch(in: help, range: NSRange(location: 0, length: help.utf16.count)) != nil
    }

    @Test("whisper-cli の --help に argv のフラグがすべて在る", arguments: whisperFlags)
    func whisperHelpHasFlag(_ flag: String) throws {
        let help = try String(contentsOf: PackageRoot.file("Tests/Fixtures/whisper-cli-help.txt"), encoding: .utf8)
        #expect(try Self.contains(help, flag: flag))
    }

    @Test("llama-server の --help に使うフラグがすべて在る", arguments: llamaFlags)
    func llamaHelpHasFlag(_ flag: String) throws {
        let help = try String(contentsOf: PackageRoot.file("Tests/Fixtures/llama-server-help.txt"), encoding: .utf8)
        #expect(try Self.contains(help, flag: flag))
    }

    @Test("フラグの判定は語の一部に一致しない")
    func flagMatchIsWholeWord() throws {
        #expect(try Self.contains("  --vad-model FNAME  path", flag: "--vad-model"))
        #expect(try !Self.contains("  --vad-model-x FNAME", flag: "--vad-model"))
        #expect(try Self.contains("  -m FNAME, --model FNAME", flag: "--model"))
        #expect(try !Self.contains("  --no-models", flag: "--model"))
    }

    @Test("versions.env に 11 のキーがすべて在る")
    func versionsEnvHasAllKeys() throws {
        let text = try String(contentsOf: PackageRoot.file("Vendor/versions.env"), encoding: .utf8)
        let keys = text.split(separator: "\n")
            .filter { !$0.hasPrefix("#") && $0.contains("=") }
            .map { String($0.prefix { $0 != "=" }) }
        #expect(
            Set(keys)
                == [
                    "WHISPER_CPP_REPO", "WHISPER_CPP_REF", "WHISPER_CPP_SHA",
                    "LLAMA_CPP_REPO", "LLAMA_CPP_REF", "LLAMA_CPP_SHA",
                    "ARGMAX_OSS_REPO", "ARGMAX_OSS_REF", "ARGMAX_OSS_SHA",
                    "SPEAKER_MODELS_REPO", "SPEAKER_MODELS_SHA",
                ])
    }
}
