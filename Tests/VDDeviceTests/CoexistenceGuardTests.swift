// 共存ガードの検査（T-13 §5.4）。ScriptedProcessRunner で試し、本物の launchctl を動かさない。
import Darwin
import Foundation
import TestSupport
import Testing
import VDProcess

@testable import VDDevice

@Suite("CoexistenceGuard")
struct CoexistenceGuardTests {
    static func result(_ termination: ProcessResult.Termination) -> ProcessResult {
        ProcessResult(termination: termination, stdoutTail: Data(), stderrTail: Data())
    }

    @Test("launchctl の argv と環境が逐語どおり")
    func argvIsExact() async throws {
        let runner = ScriptedProcessRunner(results: [ScriptedProcessRunner.exited(1)])
        _ = await CoexistenceGuard(runner: runner, uid: 501).isVoicedockHelperLoaded()
        let recorded = await runner.recorded
        #expect(recorded.count == 1)
        let spec = try #require(recorded.first)
        #expect(spec.executable.path(percentEncoded: false) == "/bin/launchctl")
        #expect(spec.arguments == ["print", "gui/501/com.voicedock.ingest"])
        #expect(CoexistenceGuard.arguments(uid: 501) == ["print", "gui/501/com.voicedock.ingest"])
        #expect(spec.environment == ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"])
        #expect(spec.environment == ProcessEnvironment.cLocale)
        #expect(await runner.recordedTimeouts == [.seconds(10)])
    }

    @Test("終了コード 0 なら登録されている")
    func exitZeroMeansLoaded() async {
        let runner = ScriptedProcessRunner(results: [ScriptedProcessRunner.exited(0)])
        #expect(await CoexistenceGuard(runner: runner, uid: 501).isVoicedockHelperLoaded())
    }

    @Test("0 以外（113）なら登録されていない")
    func nonZeroMeansNotLoaded() async {
        let runner = ScriptedProcessRunner(results: [ScriptedProcessRunner.exited(113)])
        #expect(await !CoexistenceGuard(runner: runner, uid: 501).isVoicedockHelperLoaded())
    }

    @Test(
        "タイムアウト・起動失敗・シグナルは偽",
        arguments: [
            ProcessResult.Termination.timedOut, .spawnFailed(errno: ENOENT), .signaled(9),
        ])
    func timeoutAndSpawnFailureAreNotLoaded(termination: ProcessResult.Termination) async {
        let runner = ScriptedProcessRunner(results: [Self.result(termination)])
        #expect(await !CoexistenceGuard(runner: runner, uid: 501).isVoicedockHelperLoaded())
    }
}
