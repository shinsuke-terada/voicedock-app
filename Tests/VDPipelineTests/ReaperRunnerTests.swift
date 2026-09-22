// ReaperRunner の検証の部分（PLAN §8.9.3。T-36 §6.7。T-38 が run() の行を足す）。
import Darwin
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDProcess

@testable import VDPipeline

@Suite("ReaperRunner")
struct ReaperRunnerTests {
    static func layout(_ tmp: TempDirectory, bin: Bool = true) throws -> HomeLayout {
        let layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
        try layout.createDirectories()
        if bin {
            try FileManager.default.createDirectory(at: layout.binDirectory, withIntermediateDirectories: true)
        }
        return layout
    }

    static func runner(
        _ layout: HomeLayout, results: [ProcessResult] = [], verifier: FakeSignatureVerifier = FakeSignatureVerifier()
    ) -> ReaperRunner {
        ReaperRunner(layout: layout, runner: ScriptedProcessRunner(results: results), verifier: verifier)
    }

    @Test("無ければ absent")
    func installationIsAbsentWithoutFile() throws {
        let tmp = try TempDirectory()
        let layout = try Self.layout(tmp, bin: false)
        #expect(Self.runner(layout).installation() == .absent)
    }

    @Test("通常ファイルでなければ absent（パラメータ化: symlink・ディレクトリ）", arguments: ["symlink", "ディレクトリ"])
    func installationRejectsNonRegular(_ kind: String) throws {
        let tmp = try TempDirectory()
        let layout = try Self.layout(tmp)
        if kind == "symlink" {
            let other = tmp.url.appendingPathComponent("other", isDirectory: false)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: other)
            try FileManager.default.createSymbolicLink(
                atPath: layout.reaperExecutable.path(percentEncoded: false),
                withDestinationPath: other.path(percentEncoded: false))
        } else {
            try FileManager.default.createDirectory(at: layout.reaperExecutable, withIntermediateDirectories: false)
        }
        #expect(Self.runner(layout).installation() == .absent)
    }

    @Test("鍵は lstat の inode・size・mtime")
    func installationKeyFollowsStat() throws {
        let tmp = try TempDirectory()
        let layout = try Self.layout(tmp)
        let path = layout.reaperExecutable.path(percentEncoded: false)
        try Data(repeating: 0x78, count: 4096).write(to: layout.reaperExecutable)
        var times = [timeval(tv_sec: 1_789_171_260, tv_usec: 0), timeval(tv_sec: 1_789_171_260, tv_usec: 0)]
        #expect(utimes(path, &times) == 0)
        var st = stat()
        #expect(lstat(path, &st) == 0)
        guard case .present(let key) = Self.runner(layout).installation() else {
            Issue.record("present でない")
            return
        }
        #expect(key.size == 4096)
        #expect(key.mtimeSeconds == 1_789_171_260)
        #expect(key.inode == UInt64(st.st_ino))
    }

    @Test("署名検証は bin/voicedock-reaper だけを見る")
    func signatureChecksTheInstalledPath() throws {
        let tmp = try TempDirectory()
        let layout = try Self.layout(tmp)
        let verifier = FakeSignatureVerifier()
        _ = Self.runner(layout, verifier: verifier).signatureIsValid()
        #expect(verifier.verifiedURLs == [layout.reaperExecutable])
    }

    @Test(
        "版は stdout の完全一致（パラメータ化）",
        arguments: [
            (AppVersion.string + "\n", true), (AppVersion.string, false), (AppVersion.string + "\n\n", false),
            (" " + AppVersion.string + "\n", false),
        ])
    func versionMatchesExactly(_ output: String, _ want: Bool) async throws {
        let tmp = try TempDirectory()
        let layout = try Self.layout(tmp)
        let runner = Self.runner(layout, results: [ScriptedProcessRunner.version(output)])
        #expect(await runner.versionMatches() == want)
    }

    @Test("終了コード ≠ 0・タイムアウトは nil", arguments: ["exited(1)", "timedOut"])
    func versionNilOnFailure(_ kind: String) async throws {
        let tmp = try TempDirectory()
        let layout = try Self.layout(tmp)
        let result =
            kind == "exited(1)"
            ? ProcessResult(termination: .exited(1), stdoutTail: Data("0.1.0\n".utf8), stderrTail: Data())
            : ProcessResult(termination: .timedOut, stdoutTail: Data("0.1.0\n".utf8), stderrTail: Data())
        #expect(await Self.runner(layout, results: [result]).runVersion() == nil)
    }

    // MARK: - run()（T-38 §6.8）

    @Test("起動は bin/voicedock-reaper --home <HOME> だけ")
    func runArgvIsExact() async throws {
        let tmp = try TempDirectory()
        let layout = try Self.layout(tmp)
        let scripted = ScriptedProcessRunner(results: [ScriptedProcessRunner.exited(0)])
        let outcome = await ReaperRunner(layout: layout, runner: scripted, verifier: FakeSignatureVerifier()).run()
        #expect(outcome == .finished(ScriptedProcessRunner.exited(0)))
        #expect(
            await scripted.recorded == [
                ProcessSpec(
                    executable: layout.reaperExecutable,
                    arguments: ["--home", layout.root.path(percentEncoded: false)],
                    environment: ProcessEnvironment.standard)
            ])
        #expect(await scripted.recordedTimeouts == [.seconds(120)])
    }

    @Test("署名が不正なら起動しない")
    func runRefusesInvalidSignature() async throws {
        let tmp = try TempDirectory()
        let layout = try Self.layout(tmp)
        let scripted = ScriptedProcessRunner(results: [ScriptedProcessRunner.exited(0)])
        let outcome = await ReaperRunner(
            layout: layout, runner: scripted, verifier: FakeSignatureVerifier(valid: false)
        )
        .run()
        #expect(outcome == .notLaunched(reason: "signature"))
        #expect(await scripted.recorded == [])
    }
}
