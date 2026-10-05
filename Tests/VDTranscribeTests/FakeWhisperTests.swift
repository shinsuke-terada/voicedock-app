// 偽 whisper-cli 自体のテスト（T-17 §6.5。TEST-05）。
import Foundation
import TestSupport
import Testing
import VDProcess

@Suite("FakeWhisper", .serialized)
struct FakeWhisperTests {
    static func run(_ script: URL, _ arguments: [String], timeout: Duration = .seconds(10)) async -> ProcessResult {
        await ProcessRunner().run(
            ProcessSpec(executable: script, arguments: arguments, environment: ProcessEnvironment.standard),
            timeout: timeout)
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    @Test("生 JSON が voicedock の偽物と同じ 1 行")
    func rawDocumentMatchesVoicedock() {
        let expected =
            #"{"systeminfo": "AVX = 0 | NEON = 1 |", "model": {"type": "large", "multilingual": true}, "#
            + #""params": {"model": "ggml-large-v3-turbo-q8_0.bin", "language": "ja"}, "result": {"language": "ja"}, "#
            + #""transcription": [{"timestamps": {"from": "00:00:00,000", "to": "00:00:03,200"}, "#
            + #""offsets": {"from": 0, "to": 3200}, "text": " おはようございます。"}, "#
            + #"{"timestamps": {"from": "00:00:05,500", "to": "00:00:09,000"}, "#
            + #""offsets": {"from": 5500, "to": 9000}, "text": " 今日の予定を確認します。"}]}"#
        #expect(Array(FakeWhisper.rawDocument().utf8) == Array(expected.utf8))
    }

    @Test("発話 (12.5, 20.25) の JSON")
    func rawDocumentForNoonUtterance() {
        let document = FakeWhisper.rawDocument([FakeWhisperUtterance(12.5, 20.25, " 正午すぎ")])
        let suffix =
            #""transcription": [{"timestamps": {"from": "00:00:12,500", "to": "00:00:20,250"}, "#
            + #""offsets": {"from": 12500, "to": 20250}, "text": " 正午すぎ"}]}"#
        #expect(document.hasSuffix(suffix))
    }

    @Test("argv を 1 行ずつ記録する")
    func recordsArgv() async throws {
        let tmp = try TempDirectory()
        let script = try FakeWhisper.write(to: tmp.url.appending(path: "whisper-cli"))
        let base = tmp.url.appending(path: "x").path(percentEncoded: false)
        let result = await Self.run(script, ["-of", base, "-np"])
        #expect(result.termination == .exited(0))
        #expect(FakeWhisper.recordedArgv(script) == ["-of", base, "-np"])
        let written = try String(contentsOf: URL(fileURLWithPath: base + ".json"), encoding: .utf8)
        #expect(written == FakeWhisper.rawDocument() + "\n")
    }

    @Test("--help で help を出して 0")
    func helpPrintsHelpText() async throws {
        let tmp = try TempDirectory()
        let script = try FakeWhisper.write(to: tmp.url.appending(path: "whisper-cli"))
        let base = tmp.url.appending(path: "x").path(percentEncoded: false)
        let result = await Self.run(script, ["-of", base, "--help"])
        #expect(result.termination == .exited(0))
        #expect(result.stdoutText == FakeWhisper.helpWithVAD + "\n")
        #expect(!Self.exists(URL(fileURLWithPath: base + ".json")))
    }

    @Test("output .none は JSON を書かない")
    func outputNoneWritesNothing() async throws {
        let tmp = try TempDirectory()
        let script = try FakeWhisper.write(to: tmp.url.appending(path: "whisper-cli"), output: .none)
        let base = tmp.url.appending(path: "x").path(percentEncoded: false)
        let result = await Self.run(script, ["-of", base])
        #expect(result.termination == .exited(0))
        #expect(!Self.exists(URL(fileURLWithPath: base + ".json")))
    }

    @Test("終了コードと stderr")
    func exitCodeAndStderr() async throws {
        let tmp = try TempDirectory()
        let script = try FakeWhisper.write(to: tmp.url.appending(path: "whisper-cli"), exitCode: 5, stderr: "it's bad")
        let result = await Self.run(script, [])
        #expect(result.termination == .exited(5))
        #expect(result.stderrText == "it's bad")
    }

    @Test("孫プロセスが marker を作る")
    func grandchildTouchesMarker() async throws {
        let tmp = try TempDirectory()
        let marker = tmp.url.appending(path: "marker")
        let script = try FakeWhisper.write(
            to: tmp.url.appending(path: "whisper-cli"), sleepSeconds: 1, grandchildMarker: marker)
        let result = await Self.run(script, [], timeout: .seconds(10))
        #expect(result.termination == .exited(0))
        #expect(Self.exists(marker))
    }
}
