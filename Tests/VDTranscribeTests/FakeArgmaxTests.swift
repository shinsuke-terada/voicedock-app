// 偽 argmax-cli 自体のテスト（T-48 §5。TEST-05）。
import Foundation
import TestSupport
import Testing
import VDProcess

@Suite("FakeArgmax", .serialized)
struct FakeArgmaxTests {
    static func run(_ script: URL, _ arguments: [String]) async -> ProcessResult {
        await ProcessRunner().run(
            ProcessSpec(executable: script, arguments: arguments, environment: ProcessEnvironment.standard),
            timeout: .seconds(10))
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    @Test("--help で help を出して 0")
    func helpPrintsHelpText() async throws {
        let tmp = try TempDirectory()
        let script = try FakeArgmax.write(to: tmp.url.appending(path: "argmax-cli"))
        let rttm = tmp.url.appending(path: "out.rttm").path(percentEncoded: false)
        let result = await Self.run(script, ["diarize", "--rttm-path", rttm, "--help"])
        #expect(result.termination == .exited(0))
        #expect(result.stdoutText == FakeArgmax.help + "\n")
        #expect(!Self.exists(URL(fileURLWithPath: rttm)))
    }

    @Test("argv を 1 行ずつ記録する")
    func recordsArgv() async throws {
        let tmp = try TempDirectory()
        let script = try FakeArgmax.write(to: tmp.url.appending(path: "argmax-cli"), output: .none)
        #expect(FakeArgmax.recordedArgv(script) == [])
        let result = await Self.run(script, ["diarize", "--audio-path", "a b.wav", "--use-exclusive-reconciliation"])
        #expect(result.termination == .exited(0))
        #expect(
            FakeArgmax.recordedArgv(script) == [
                "diarize", "--audio-path", "a b.wav", "--use-exclusive-reconciliation",
            ])
    }

    @Test("--rttm-path の次の値へ RTTM を書く")
    func writesToRTTMPath() async throws {
        let tmp = try TempDirectory()
        let script = try FakeArgmax.write(
            to: tmp.url.appending(path: "argmax-cli"),
            output: .rttm([
                "SPEAKER audio16k 1 0.000 2.000 <NA> <NA> A <NA> <NA>",
                "SPEAKER audio16k 1 2.500 1.000 <NA> <NA> B <NA> <NA>",
            ]))
        let rttm = tmp.url.appending(path: "out.rttm")
        let result = await Self.run(script, ["diarize", "--rttm-path", rttm.path(percentEncoded: false)])
        #expect(result.termination == .exited(0))
        let written = try String(contentsOf: rttm, encoding: .utf8)
        #expect(
            written
                == "SPEAKER audio16k 1 0.000 2.000 <NA> <NA> A <NA> <NA>\n"
                + "SPEAKER audio16k 1 2.500 1.000 <NA> <NA> B <NA> <NA>\n")
    }

    @Test("output .none は RTTM を書かない")
    func outputNoneWritesNothing() async throws {
        let tmp = try TempDirectory()
        let script = try FakeArgmax.write(to: tmp.url.appending(path: "argmax-cli"), output: .none)
        let rttm = tmp.url.appending(path: "out.rttm")
        let result = await Self.run(script, ["diarize", "--rttm-path", rttm.path(percentEncoded: false)])
        #expect(result.termination == .exited(0))
        #expect(!Self.exists(rttm))
    }

    @Test("終了コードを返す")
    func exitCode() async throws {
        let tmp = try TempDirectory()
        let script = try FakeArgmax.write(to: tmp.url.appending(path: "argmax-cli"), exitCode: 4)
        let result = await Self.run(script, ["diarize"])
        #expect(result.termination == .exited(4))
    }
}
