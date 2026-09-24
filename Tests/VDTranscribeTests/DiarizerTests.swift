// Diarizer のテスト（T-48 §5。PLAN §8.4.1）。偽 argmax-cli を本物の ProcessRunner で起動する。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDProcess

@testable import VDTranscribe

@Suite("Diarizer", .serialized, .timeLimit(.minutes(1)))
struct DiarizerTests {
    static let slug = "TX01_MIC002_20260829_071204_orig-0123456789"

    static let twoLines = [
        "SPEAKER audio16k 1 0.000 3.200 <NA> <NA> A <NA> <NA>",
        "SPEAKER audio16k 1 5.500 3.500 <NA> <NA> B <NA> <NA>",
    ]

    /// テストごとの環境（一時ディレクトリ・HomeLayout・AppPaths・staging・入力）。
    struct Fixture {
        let tmp: TempDirectory
        let layout: HomeLayout
        let paths: AppPaths

        init(models: Bool = true) throws {
            tmp = try TempDirectory()
            layout = HomeLayout(root: tmp.url.appending(path: "home", directoryHint: .isDirectory))
            try layout.createDirectories()
            paths = AppPaths(
                resources: tmp.url.appending(path: "resources", directoryHint: .isDirectory),
                helpers: tmp.url.appending(path: "helpers", directoryHint: .isDirectory))
            try FileManager.default.createDirectory(at: paths.helpers, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: paths.resources, withIntermediateDirectories: true)
            if models {
                try FileManager.default.createDirectory(at: paths.speakerModels, withIntermediateDirectories: true)
            }
            try FileManager.default.createDirectory(
                at: layout.stagingDirectory(slug: DiarizerTests.slug), withIntermediateDirectories: true)
            try Data("RIFF....WAVEfmt ".utf8).write(to: input)
        }

        var script: URL { paths.argmaxCLI }
        var input: URL { layout.normalizedAudio(slug: DiarizerTests.slug) }
        var rttm: URL { layout.stagingDirectory(slug: DiarizerTests.slug).appending(path: "diarization.rttm") }

        func diarizer(maxTimeoutSeconds: Int = 21_600) -> Diarizer {
            Diarizer(runner: ProcessRunner(), paths: paths, layout: layout, maxTimeoutSeconds: maxTimeoutSeconds)
        }

        func run(maxTimeoutSeconds: Int = 21_600) async -> DiarizeOutcome {
            await diarizer(maxTimeoutSeconds: maxTimeoutSeconds).diarize(
                input: input, slug: DiarizerTests.slug, durationSeconds: 9.0)
        }
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    @Test("成功で RTTM の区間を返し、RTTM を消す")
    func diarizes() async throws {
        let f = try Fixture()
        try FakeArgmax.write(to: f.script, output: .rttm(Self.twoLines))
        let outcome = await f.run()
        #expect(
            outcome
                == .diarized([
                    SpeakerTurn(start: 0.0, end: 3.2, speaker: "A"), SpeakerTurn(start: 5.5, end: 9.0, speaker: "B"),
                ]))
        #expect(!Self.exists(f.rttm))
        #expect(!FakeArgmax.recordedArgv(f.script).isEmpty)
    }

    @Test("argmax-cli が無ければ起動せず helper_missing")
    func missingHelper() async throws {
        let f = try Fixture()
        #expect(f.diarizer().missingParts() == ["argmax-cli"])
        #expect(await f.run() == .failed(reason: "helper_missing"))
    }

    @Test("SpeakerModels が無ければ helper_missing")
    func missingModels() async throws {
        let f = try Fixture(models: false)
        try FakeArgmax.write(to: f.script)
        #expect(f.diarizer().missingParts() == ["SpeakerModels"])
        #expect(await f.run() == .failed(reason: "helper_missing"))
        #expect(FakeArgmax.recordedArgv(f.script).isEmpty)
    }

    @Test("終了 3 は exit_3")
    func exitNonZero() async throws {
        let f = try Fixture()
        try FakeArgmax.write(to: f.script, exitCode: 3)
        #expect(await f.run() == .failed(reason: "exit_3"))
        #expect(!Self.exists(f.rttm))
    }

    @Test("自分を SIGKILL すると signal_9")
    func signaled() async throws {
        let f = try Fixture()
        try FakeArgmax.write(to: f.script, selfSignal: 9)
        #expect(await f.run() == .failed(reason: "signal_9"))
    }

    @Test("タイムアウトは timeout")
    func timeout() async throws {
        let f = try Fixture()
        try FakeArgmax.write(to: f.script, sleepSeconds: 30)
        let outcome = await f.diarizer(maxTimeoutSeconds: 1).diarize(
            input: f.input, slug: Self.slug, durationSeconds: nil)
        #expect(outcome == .failed(reason: "timeout"))
    }

    @Test("終了 0 で RTTM が無ければ rttm_unreadable")
    func noRTTM() async throws {
        let f = try Fixture()
        try FakeArgmax.write(to: f.script, output: .none)
        #expect(await f.run() == .failed(reason: "rttm_unreadable"))
    }

    @Test("読めない RTTM は rttm_unreadable")
    func brokenRTTM() async throws {
        let f = try Fixture()
        try FakeArgmax.write(to: f.script, output: .custom("garbage"))
        #expect(await f.run() == .failed(reason: "rttm_unreadable"))
        #expect(!Self.exists(f.rttm))
    }

    @Test("空の RTTM は 0 件の成功（TEST-28）")
    func emptyRTTM() async throws {
        let f = try Fixture()
        try FakeArgmax.write(to: f.script, output: .rttm([]))
        #expect(await f.run() == .diarized([]))
    }

    @Test("前回の RTTM を起動の前に消す")
    func staleRTTMIsRemovedFirst() async throws {
        let f = try Fixture()
        try Data((Self.twoLines.joined(separator: "\n") + "\n").utf8).write(to: f.rttm)
        try FakeArgmax.write(to: f.script, output: .none)
        #expect(await f.run() == .failed(reason: "rttm_unreadable"))
        #expect(!Self.exists(f.rttm))
    }

    @Test("起動の argv が PLAN どおり")
    func argvIsRecorded() async throws {
        let f = try Fixture()
        try FakeArgmax.write(to: f.script)
        _ = await f.run()
        let home = f.layout.root.path(percentEncoded: false)
        let resources = f.paths.resources.path(percentEncoded: false)
        #expect(
            FakeArgmax.recordedArgv(f.script) == [
                "diarize", "--audio-path", "\(home)staging/\(Self.slug)/audio16k.wav", "--model-path",
                "\(resources)SpeakerModels/", "--rttm-path", "\(home)staging/\(Self.slug)/diarization.rttm",
                "--use-exclusive-reconciliation",
            ])
        #expect(
            FakeArgmax.recordedArgv(f.script)
                == DiarizeArgs.build(input: f.input, models: f.paths.speakerModels, rttm: f.rttm))
    }

    @Test(
        "タイムアウトの式",
        arguments: [(nil, 21_600), (10.0, 120), (1000.0, 500), (100_000.0, 21_600)] as [(Double?, Int)])
    func timeoutFormula(duration: Double?, expected: Int) {
        #expect(Diarizer.timeoutFactor == 0.5)
        #expect(Diarizer.minTimeoutSeconds == 120)
        #expect(Diarizer.timeoutSeconds(duration: duration, maxTimeoutSeconds: 21_600) == expected)
    }
}
