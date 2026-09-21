// ProcessRunner.spawn と RunningProcess のテスト（T-12 §5.2）。本物の子プロセスを起動する（無害なコマンドとテスト用のスクリプトだけ）。
import Darwin
import Foundation
import TestSupport
import Testing
import VDProcess

@Suite("ProcessRunner.spawn", .serialized, .timeLimit(.minutes(1)))
struct RunningProcessTests {
    private func spec(_ path: String, _ arguments: [String] = [], environment: [String: String] = [:]) -> ProcessSpec {
        ProcessSpec(executable: URL(filePath: path), arguments: arguments, environment: environment)
    }

    private func script(_ body: String, name: String, in dir: TempDirectory) throws -> ProcessSpec {
        let url = try ScriptWriter.write(body, name: name, in: dir.url)
        return spec(url.path(percentEncoded: false), environment: ProcessEnvironment.standard)
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

    @Test("spawn した子を terminate で止める")
    func spawnAndTerminate() async throws {
        let process = try await ProcessRunner().spawn(spec("/bin/sleep", ["30"]))
        #expect(await process.isRunning == true)
        #expect(await process.terminate(grace: .seconds(1)) == .signaled(SIGTERM))
        #expect(await process.isRunning == false)
    }

    @Test("2 回目の terminate は最初の終わり方を返す")
    func terminateTwiceReturnsSameResult() async throws {
        let process = try await ProcessRunner().spawn(spec("/bin/sleep", ["30"]))
        #expect(await process.terminate(grace: .seconds(1)) == .signaled(SIGTERM))
        let clock = ContinuousClock()
        var second: ProcessResult.Termination?
        let elapsed = await clock.measure {
            second = await process.terminate(grace: .seconds(1))
        }
        #expect(second == .signaled(SIGTERM))
        #expect(elapsed < .milliseconds(500))
    }

    @Test("SIGTERM を無視する子は grace の後 SIGKILL")
    func terminateEscalatesToSIGKILL() async throws {
        let dir = try TempDirectory()
        let process = try await ProcessRunner().spawn(
            try script("trap '' TERM; echo ready >&2; sleep 30\n", name: "ignoreterm.sh", in: dir))
        // trap を設定し終えたことを stderr で知る（書いたばかりのスクリプトの最初の exec は 0.1〜0.3 秒かかる）
        let ready = try await waitForStderr(process, containing: "ready\n")
        try #require(ready.contains("ready\n"))
        #expect(await process.terminate(grace: .milliseconds(500)) == .signaled(SIGKILL))
    }

    @Test("無い実行ファイルの spawn は SpawnError")
    func spawnMissingExecutableThrows() async throws {
        let dir = try TempDirectory()
        let missing = spec(dir.url.appending(path: "nope").path(percentEncoded: false))
        await #expect(throws: SpawnError.spawnFailed(errno: ENOENT)) {
            _ = try await ProcessRunner().spawn(missing)
        }
    }

    @Test("動いている間も stderr の末尾を読める")
    func stderrTailWhileRunning() async throws {
        let dir = try TempDirectory()
        let process = try await ProcessRunner().spawn(
            try script("echo ready >&2; sleep 30\n", name: "ready.sh", in: dir))
        let text = try await waitForStderr(process, containing: "ready\n")
        #expect(text.contains("ready\n"))
        _ = await process.terminate(grace: .seconds(1))
    }

    @Test("勝手に終わったことを waitForExit で知れる")
    func waitForExitReportsCrash() async throws {
        let dir = try TempDirectory()
        let process = try await ProcessRunner().spawn(try script("sleep 0.2; exit 3\n", name: "crash.sh", in: dir))
        #expect(await process.waitForExit() == .exited(3))
        #expect(await process.isRunning == false)
    }

    /// 64 KiB 近くを stderr に書いてすぐ終わる子。最後の行は読み取りが追いつかないと欠ける
    private func burstThenExit(_ dir: TempDirectory) throws -> ProcessSpec {
        try script(
            "i=0; while [ $i -lt 1500 ]; do echo 'padding-padding-padding-padding-padding' >&2; i=$((i+1)); done; "
                + "echo LAST-LINE >&2; exit 1\n", name: "burst.sh", in: dir)
    }

    @Test("既に終わった子の terminate は stderr を最後まで読んでから返す")
    func terminateAfterExitDrainsStderr() async throws {
        let dir = try TempDirectory()
        let process = try await ProcessRunner().spawn(try burstThenExit(dir))
        let deadline = ContinuousClock.now + .seconds(5)
        while await process.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await process.terminate(grace: .zero) == .exited(1))
        let tail = String(decoding: await process.stderrTail(), as: UTF8.self)
        #expect(tail.hasSuffix("LAST-LINE\n"))
    }

    @Test("waitForExit は stderr を最後まで読んでから返す")
    func waitForExitDrainsStderr() async throws {
        let dir = try TempDirectory()
        let process = try await ProcessRunner().spawn(try burstThenExit(dir))
        #expect(await process.waitForExit() == .exited(1))
        let tail = String(decoding: await process.stderrTail(), as: UTF8.self)
        #expect(tail.hasSuffix("LAST-LINE\n"))
    }

    @Test("terminateAll は spawn した子と run 中の子を止める")
    func terminateAllStopsSpawnedAndRunning() async throws {
        let runner = ProcessRunner()
        let first = try await runner.spawn(spec("/bin/sleep", ["30"]))
        let second = try await runner.spawn(spec("/bin/sleep", ["30"]))
        let running = Task { await runner.run(spec("/bin/sleep", ["30"]), timeout: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(200))
        await runner.terminateAll(grace: .seconds(1))
        #expect(await first.isRunning == false)
        #expect(await second.isRunning == false)
        #expect(await running.value.termination == .signaled(SIGTERM))
    }
}
