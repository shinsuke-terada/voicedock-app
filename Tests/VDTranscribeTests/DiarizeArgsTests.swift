// DiarizeArgs のテスト（T-48 §5。PLAN §8.4.1。DR-18）。
import Foundation
import TestSupport
import Testing

@testable import VDTranscribe

@Suite("DiarizeArgs")
struct DiarizeArgsTests {
    static let allFlags = ["--audio-path", "--model-path", "--rttm-path", "--use-exclusive-reconciliation"]

    @Test("argv は PLAN §8.4.1 の並び")
    func argvOrder() {
        let argv = DiarizeArgs.build(
            input: URL(fileURLWithPath: "/h/staging/s/audio16k.wav"),
            models: URL(fileURLWithPath: "/b/Contents/Resources/SpeakerModels", isDirectory: true),
            rttm: URL(fileURLWithPath: "/h/staging/s/diarization.rttm"))
        #expect(
            argv == [
                "diarize", "--audio-path", "/h/staging/s/audio16k.wav", "--model-path",
                "/b/Contents/Resources/SpeakerModels/", "--rttm-path", "/h/staging/s/diarization.rttm",
                "--use-exclusive-reconciliation",
            ])
    }

    @Test("固定した版の --help に 4 つのフラグが在る")
    func fixtureHasAllFlags() throws {
        #expect(DiarizeArgs.requiredFlags == Self.allFlags)
        let data = try Data(contentsOf: PackageRoot.file("Tests/Fixtures/argmax-cli-diarize-help.txt"))
        let text = String(decoding: data, as: UTF8.self)
        #expect(DiarizeArgs.missingFlags(helpOutput: text) == [])
    }

    @Test("無いフラグを宣言順に返す")
    func missingFlagReported() throws {
        let data = try Data(contentsOf: PackageRoot.file("Tests/Fixtures/argmax-cli-diarize-help.txt"))
        let help = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "--rttm-path", with: "")
        #expect(!help.contains("--rttm-path"))
        #expect(DiarizeArgs.missingFlags(helpOutput: help) == ["--rttm-path"])
    }

    @Test("長いフラグの一部は在ると見なさない")
    func prefixIsNotAFlag() {
        let help = """
              --audio-path <audio-path>
              --model-path-x <x>
              --rttm-path <rttm-path>
              --use-exclusive-reconciliation
            """
        #expect(DiarizeArgs.missingFlags(helpOutput: help) == ["--model-path"])
    }

    @Test("前後の区切りは §4.1 のとおり")
    func delimitersAroundFlag() {
        let help =
            "USAGE: x [--rttm-path <p>]\n  --audio-path=<a>\n  --use-exclusive-reconciliation]\n  x--model-path <p>"
        #expect(DiarizeArgs.missingFlags(helpOutput: help) == ["--model-path"])
    }

    @Test("空の help（TEST-28）")
    func emptyHelp() {
        #expect(DiarizeArgs.missingFlags(helpOutput: "") == Self.allFlags)
    }
}
