// terminateAll が止めた子の結果に印を付けること（PLAN §8.2。F-82・issue #119 の E6）。本物の子プロセス（テスト用のスクリプト）。
import Darwin
import Foundation
import TestSupport
import Testing
import VDProcess

@Suite("ProcessRunner（F-82 terminateAll が止めた印）", .serialized, .timeLimit(.minutes(1)))
struct ProcessRunnerStoppedTests {
    private func spec(_ path: String, _ arguments: [String] = [], environment: [String: String] = [:]) -> ProcessSpec {
        ProcessSpec(executable: URL(filePath: path), arguments: arguments, environment: environment)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// path が在るようになるまで 20 ms ごとに最大 10 秒待つ（時間ではなく印を待つ）
    private func waitUntilExists(_ url: URL) async throws -> Bool {
        var waited = 0
        while !exists(url), waited < 500 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        return exists(url)
    }

    @Test("F-82 実行中に terminateAll が止めた子の結果は stoppedByTerminateAll が真（終わり方は SIGTERM のまま）")
    func stoppedChildIsMarked() async throws {
        let dir = try TempDirectory()
        let ready = dir.url.appending(path: "ready")
        let script = try ScriptWriter.write(": > \"$1\"\nexec /bin/sleep 30\n", name: "ready.sh", in: dir.url)
        let runner = ProcessRunner()
        let running = Task {
            await runner.run(
                spec(
                    script.path(percentEncoded: false), [ready.path(percentEncoded: false)],
                    environment: ProcessEnvironment.standard), timeout: .seconds(60))
        }
        try #require(try await waitUntilExists(ready))

        await runner.terminateAll(grace: .seconds(5))

        let result = await running.value
        #expect(result.termination == .signaled(SIGTERM))
        #expect(result.stoppedByTerminateAll)
    }

    @Test("F-82 自分で終わった子・タイムアウトで止めた子・閉じた後に拒んだ実行は印が偽")
    func unstoppedResultsAreNotMarked() async throws {
        let runner = ProcessRunner()
        let exited = await runner.run(spec("/usr/bin/true"), timeout: .seconds(10))
        #expect(exited.termination == .exited(0))
        #expect(!exited.stoppedByTerminateAll)
        let timedOut = await runner.run(spec("/bin/sleep", ["30"]), timeout: .milliseconds(200))
        #expect(timedOut.termination == .timedOut)
        #expect(!timedOut.stoppedByTerminateAll)

        await runner.terminateAll(grace: .seconds(1))

        let refused = await runner.run(spec("/usr/bin/true"), timeout: .seconds(10))
        #expect(refused.termination == .spawnFailed(errno: ProcessRunner.closedErrno))
        #expect(!refused.stoppedByTerminateAll)
    }

    @Test("F-82 TEST-28 既定の初期化子は印を偽にする（出力も空）")
    func defaultInitializerIsUnmarked() {
        let result = ProcessResult(termination: .exited(0), stdoutTail: Data(), stderrTail: Data())
        #expect(!result.stoppedByTerminateAll)
        #expect(result.stdoutText.isEmpty)
        #expect(result.stderrText.isEmpty)
    }
}
