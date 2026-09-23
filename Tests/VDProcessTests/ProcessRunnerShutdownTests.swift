// ProcessRunner.terminateAll が閉じること（F-76・issue #116）。本物の子プロセスを起動する（無害なコマンドとテスト用のスクリプトだけ）。
import Darwin
import Foundation
import TestSupport
import Testing
import VDProcess

@Suite("ProcessRunner.terminateAll（閉じる）", .serialized, .timeLimit(.minutes(1)))
struct ProcessRunnerShutdownTests {
    private func spec(_ path: String, _ arguments: [String] = [], environment: [String: String] = [:]) -> ProcessSpec {
        ProcessSpec(executable: URL(filePath: path), arguments: arguments, environment: environment)
    }

    /// 起動されたら marker を作るだけの子（起動されなかったことを marker が無いことで確かめる）
    private func touch(_ marker: URL) -> ProcessSpec {
        spec("/usr/bin/touch", [marker.path(percentEncoded: false)])
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// stderrTail() が needle を含むまで 50 ms ごとに最大 2 秒待ち、最後に読んだ文字列を返す
    private func waitForStderr(_ process: RunningProcess, containing needle: String) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        var text = ""
        while clock.now < deadline {
            text = String(decoding: await process.stderrTail(), as: UTF8.self)
            if text.contains(needle) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return text
    }

    @Test("F-76 子が 0 件でも閉じ、以後の run は起動せずに spawnFailed(ECANCELED)")
    func closesEvenWithoutChildren() async throws {
        let dir = try TempDirectory()
        let marker = dir.url.appending(path: "ran")
        let runner = ProcessRunner()
        await runner.terminateAll(grace: .seconds(1))
        let result = await runner.run(touch(marker), timeout: .seconds(10))
        #expect(
            result == ProcessResult(termination: .spawnFailed(errno: ECANCELED), stdoutTail: Data(), stderrTail: Data())
        )
        #expect(!exists(marker))
    }

    @Test("F-76 terminateAll の後の spawn は起動せずに SpawnError.spawnFailed(ECANCELED) を投げる")
    func spawnAfterTerminateAllThrows() async throws {
        let dir = try TempDirectory()
        let marker = dir.url.appending(path: "ran")
        let runner = ProcessRunner()
        await runner.terminateAll(grace: .seconds(1))
        await #expect(throws: SpawnError.spawnFailed(errno: ECANCELED)) {
            _ = try await runner.spawn(touch(marker))
        }
        #expect(!exists(marker))
    }

    @Test("F-76 子を止めた後に来た run も起動しない（終了の後に子を残さない）")
    func runAfterTerminatingChildrenIsRefused() async throws {
        let dir = try TempDirectory()
        let marker = dir.url.appending(path: "ran")
        let runner = ProcessRunner()
        let spawned = try await runner.spawn(spec("/bin/sleep", ["30"]))
        await runner.terminateAll(grace: .seconds(1))
        #expect(await spawned.isRunning == false)
        let result = await runner.run(touch(marker), timeout: .seconds(10))
        #expect(result.termination == .spawnFailed(errno: ECANCELED))
        #expect(!exists(marker))
    }

    @Test("F-76 子が全部終われば grace を待たずに戻る")
    func returnsOnceAllChildrenExit() async throws {
        let runner = ProcessRunner()
        let spawned = try await runner.spawn(spec("/bin/sleep", ["30"]))
        let running = Task { await runner.run(spec("/bin/sleep", ["30"]), timeout: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(200))
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await runner.terminateAll(grace: .seconds(20))
        }
        #expect(elapsed < .seconds(5))
        #expect(await spawned.isRunning == false)
        #expect(await running.value.termination == .signaled(SIGTERM))
    }

    @Test("F-76 SIGTERM を無視する子は grace を待ってから SIGKILL")
    func ignoringChildIsKilledAfterGrace() async throws {
        let dir = try TempDirectory()
        let script = try ScriptWriter.write(
            "trap '' TERM; echo ready >&2; sleep 30\n", name: "ignoreterm.sh", in: dir.url)
        let runner = ProcessRunner()
        let process = try await runner.spawn(
            spec(script.path(percentEncoded: false), environment: ProcessEnvironment.standard))
        // trap を設定し終えたことを stderr で知る（書いたばかりのスクリプトの最初の exec は 0.1〜0.3 秒かかる）
        let ready = try await waitForStderr(process, containing: "ready\n")
        try #require(ready.contains("ready\n"))
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await runner.terminateAll(grace: .seconds(1))
        }
        #expect(elapsed >= .seconds(1))
        #expect(await process.waitForExit() == .signaled(SIGKILL))
    }
}
