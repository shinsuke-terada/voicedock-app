// ProcessRunner.run のテスト（T-12 §5.1）。本物の子プロセスを起動する（無害なコマンドとテスト用のスクリプトだけ）。
import Darwin
import Foundation
import TestSupport
import Testing
import VDProcess

@Suite("ProcessRunner.run", .serialized, .timeLimit(.minutes(1)))
struct ProcessRunnerTests {
    private func spec(_ path: String, _ arguments: [String] = [], environment: [String: String] = [:]) -> ProcessSpec {
        ProcessSpec(executable: URL(filePath: path), arguments: arguments, environment: environment)
    }

    /// 書いたばかりのスクリプトの最初の exec は macOS の検査で 0.1〜0.3 秒かかる（その間に届いた SIGTERM は trap より先に効く）。
    /// 先頭に `[ "$1" = warm ] && exit 0` を置いたスクリプトを 1 回空で起動しておく
    private func warmUp(_ script: URL) async {
        _ = await ProcessRunner().run(
            spec(script.path(percentEncoded: false), ["warm"], environment: ProcessEnvironment.standard),
            timeout: .seconds(10))
    }

    @Test("引数は配列のまま渡りシェルを通らない")
    func argumentsArePassedVerbatim() async {
        let result = await ProcessRunner().run(
            spec("/usr/bin/printf", ["%s|", "a b", "$HOME", "; echo x", "*", ""]), timeout: .seconds(10))
        #expect(result.termination == .exited(0))
        #expect(result.stdoutText == "a b|$HOME|; echo x|*||")
    }

    @Test("環境変数は渡したものだけ（キーの昇順）")
    func environmentIsOnlyWhatIsGiven() async {
        let result = await ProcessRunner().run(
            spec("/usr/bin/env", environment: ["B": "2", "A": "1"]), timeout: .seconds(10))
        #expect(result.termination == .exited(0))
        #expect(result.stdoutText == "A=1\nB=2\n")
    }

    @Test("空の環境でも起動できる")
    func emptyEnvironment() async {
        let result = await ProcessRunner().run(spec("/usr/bin/env", environment: [:]), timeout: .seconds(10))
        #expect(result.stdoutTail.isEmpty)
        #expect(result.termination == .exited(0))
    }

    @Test("終了コードを返す")
    func exitCodeIsReported() async throws {
        let dir = try TempDirectory()
        let script = try ScriptWriter.write("exit 7\n", name: "exit7.sh", in: dir.url)
        let result = await ProcessRunner().run(
            spec(script.path(percentEncoded: false)), timeout: .seconds(10))
        #expect(result.termination == .exited(7))
    }

    @Test("シグナルで終わったことを返す")
    func signalIsReported() async throws {
        let dir = try TempDirectory()
        let script = try ScriptWriter.write("kill -USR1 $$\n", name: "usr1.sh", in: dir.url)
        let result = await ProcessRunner().run(
            spec(script.path(percentEncoded: false)), timeout: .seconds(10))
        #expect(result.termination == .signaled(SIGUSR1))
    }

    @Test("stdin は /dev/null（待たずに終わる）")
    func stdinIsDevNull() async {
        let clock = ContinuousClock()
        var result: ProcessResult?
        let elapsed = await clock.measure {
            result = await ProcessRunner().run(spec("/bin/cat"), timeout: .seconds(10))
        }
        #expect(result?.termination == .exited(0))
        #expect(result?.stdoutTail.isEmpty == true)
        #expect(elapsed < .seconds(1))
    }

    @Test("無い実行ファイルは spawnFailed(ENOENT)")
    func missingExecutableIsSpawnFailed() async throws {
        let dir = try TempDirectory()
        let result = await ProcessRunner().run(
            spec(dir.url.appending(path: "nope").path(percentEncoded: false)), timeout: .seconds(10))
        #expect(result.termination == .spawnFailed(errno: ENOENT))
        #expect(result.stdoutTail.isEmpty)
        #expect(result.stderrTail.isEmpty)
    }

    @Test("実行権の無いファイルは spawnFailed(EACCES)")
    func nonExecutableIsSpawnFailed() async throws {
        let dir = try TempDirectory()
        let script = try ScriptWriter.write("exit 0\n", name: "noexec.sh", in: dir.url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: script.path(percentEncoded: false))
        let result = await ProcessRunner().run(
            spec(script.path(percentEncoded: false)), timeout: .seconds(10))
        #expect(result.termination == .spawnFailed(errno: EACCES))
    }

    @Test("相対パスは EINVAL")
    func relativePathIsRejected() async throws {
        let executable = try #require(URL(string: "file:ls"))
        let result = await ProcessRunner().run(
            ProcessSpec(executable: executable, arguments: [], environment: [:]), timeout: .seconds(10))
        #expect(result.termination == .spawnFailed(errno: EINVAL))
    }

    @Test("NUL を含む引数は EINVAL")
    func nulInArgumentIsRejected() async {
        let result = await ProcessRunner().run(spec("/bin/echo", ["a\u{0}b"]), timeout: .seconds(10))
        #expect(result.termination == .spawnFailed(errno: EINVAL))
    }

    @Test("stderr は末尾 4 KiB")
    func stderrTailKeepsLast4KiB() async throws {
        let dir = try TempDirectory()
        let body = """
            i=0
            while [ $i -lt 1000 ]; do printf 0123456789 >&2; i=$((i+1)); done
            printf END >&2

            """
        let script = try ScriptWriter.write(body, name: "stderr.sh", in: dir.url)
        let result = await ProcessRunner().run(
            spec(script.path(percentEncoded: false), environment: ProcessEnvironment.standard), timeout: .seconds(10))
        #expect(result.termination == .exited(0))
        #expect(result.stderrTail.count == 4096)
        #expect(result.stderrText.hasSuffix("END"))
    }

    @Test("stdout は末尾 64 KiB")
    func stdoutTailKeepsLast64KiB() async throws {
        let dir = try TempDirectory()
        let script = try ScriptWriter.write(
            "head -c 100000 /dev/zero | tr '\\0' x; printf END\n", name: "stdout.sh", in: dir.url)
        let result = await ProcessRunner().run(
            spec(script.path(percentEncoded: false), environment: ProcessEnvironment.standard), timeout: .seconds(10))
        #expect(result.termination == .exited(0))
        #expect(result.stdoutTail.count == 65536)
        #expect(result.stdoutText.hasSuffix("END"))
    }

    @Test("大量の出力でも子が止まらない")
    func largeOutputDoesNotBlockChild() async throws {
        let dir = try TempDirectory()
        let script = try ScriptWriter.write(
            "head -c 1000000 /dev/zero\nhead -c 1000000 /dev/zero >&2\n", name: "large.sh", in: dir.url)
        let clock = ContinuousClock()
        var result: ProcessResult?
        let elapsed = await clock.measure {
            result = await ProcessRunner().run(
                spec(script.path(percentEncoded: false), environment: ProcessEnvironment.standard),
                timeout: .seconds(5))
        }
        #expect(result?.termination == .exited(0))
        #expect(elapsed < .seconds(5))
    }

    @Test("子は新しいプロセスグループの先頭")
    func newProcessGroup() async throws {
        let dir = try TempDirectory()
        let script = try ScriptWriter.write("echo $$; ps -o pgid= -p $$\n", name: "pgid.sh", in: dir.url)
        let result = await ProcessRunner().run(
            spec(script.path(percentEncoded: false), environment: ProcessEnvironment.standard), timeout: .seconds(10))
        #expect(result.termination == .exited(0))
        let lines = result.stdoutText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        try #require(lines.count == 2)
        #expect(lines[0] == lines[1])
        #expect(lines[1] != String(getpgrp()))
    }

    @Test("子は 0・1・2 以外の fd を受け継がない")
    func childDoesNotInheritParentFDs() async throws {
        let fd = open("/dev/null", O_RDONLY)
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(dup2(fd, 200) == 200)
        defer { close(200) }
        let result = await ProcessRunner().run(spec("/bin/ls", ["/dev/fd"]), timeout: .seconds(10))
        #expect(result.termination == .exited(0))
        let lines = result.stdoutText.split(separator: "\n").map(String.init)
        #expect(!lines.isEmpty)
        #expect(!lines.contains("200"))
    }

    @Test("タイムアウトで子と孫をグループごと止める（ASR-07）")
    func timeoutKillsChildAndGrandchild() async throws {
        let dir = try TempDirectory()
        let pidFile = dir.url.appending(path: "grandchild.pid")
        let script = try ScriptWriter.write(
            "[ \"$1\" = warm ] && exit 0\nsleep 30 & echo $! > \"$1\"; sleep 30\n", name: "grandchild.sh", in: dir.url)
        await warmUp(script)
        let clock = ContinuousClock()
        var result: ProcessResult?
        let elapsed = await clock.measure {
            result = await ProcessRunner().run(
                spec(
                    script.path(percentEncoded: false), [pidFile.path(percentEncoded: false)],
                    environment: ProcessEnvironment.standard), timeout: .milliseconds(500))
        }
        #expect(result?.termination == .timedOut)
        #expect(elapsed < .seconds(5))  // SIGTERM で止まる（子の sleep 30 が自然に終わるのを待っていない）
        let grandchild = try #require(try readPID(pidFile))
        #expect(await waitUntilGone(pid: grandchild, within: .seconds(2)))
    }

    @Test("SIGTERM を無視する子は 5 秒後に SIGKILL")
    func timeoutEscalatesToSIGKILL() async throws {
        let dir = try TempDirectory()
        let script = try ScriptWriter.write(
            "[ \"$1\" = warm ] && exit 0\ntrap '' TERM; sleep 30\n", name: "ignoreterm.sh", in: dir.url)
        await warmUp(script)
        let clock = ContinuousClock()
        var result: ProcessResult?
        let elapsed = await clock.measure {
            result = await ProcessRunner().run(
                spec(script.path(percentEncoded: false), environment: ProcessEnvironment.standard),
                timeout: .milliseconds(200))
        }
        #expect(result?.termination == .timedOut)
        #expect(elapsed >= .seconds(5))
        #expect(elapsed < .seconds(8))
    }

    @Test("正常終了でもグループに残った孫を消す")
    func lingeringGrandchildIsKilledAfterExit() async throws {
        let dir = try TempDirectory()
        let pidFile = dir.url.appending(path: "lingering.pid")
        let script = try ScriptWriter.write("sleep 30 & echo $! > \"$1\"; exit 0\n", name: "lingering.sh", in: dir.url)
        let clock = ContinuousClock()
        var result: ProcessResult?
        let elapsed = await clock.measure {
            result = await ProcessRunner().run(
                spec(
                    script.path(percentEncoded: false), [pidFile.path(percentEncoded: false)],
                    environment: ProcessEnvironment.standard), timeout: .seconds(10))
        }
        #expect(result?.termination == .exited(0))
        #expect(elapsed < .seconds(2))
        let grandchild = try #require(try readPID(pidFile))
        #expect(await waitUntilGone(pid: grandchild, within: .seconds(2)))
    }

    @Test("2 つの run は並行に進む（actor を止めない）")
    func runsDoNotBlockEachOther() async {
        let runner = ProcessRunner()
        let sleep = spec("/bin/sleep", ["1"])
        let clock = ContinuousClock()
        var results: [ProcessResult] = []
        let elapsed = await clock.measure {
            async let first = runner.run(sleep, timeout: .seconds(10))
            async let second = runner.run(sleep, timeout: .seconds(10))
            results = await [first, second]
        }
        #expect(results.map(\.termination) == [.exited(0), .exited(0)])
        #expect(elapsed < .milliseconds(1900))
    }

    @Test("呼び手のタスクを取り消すと子を止める")
    func cancellingTheCallerStopsTheChild() async throws {
        let runner = ProcessRunner()
        let task = Task { await runner.run(spec("/bin/sleep", ["30"]), timeout: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(200))
        let clock = ContinuousClock()
        var result: ProcessResult?
        let elapsed = await clock.measure {
            task.cancel()
            result = await task.value
        }
        #expect(result?.termination == .timedOut)
        #expect(elapsed < .seconds(1))
    }

    @Test("すぐ終わる子の終了を取りこぼさない")
    func exitWaiterDoesNotMissEarlyExit() async {
        let runner = ProcessRunner()
        let clock = ContinuousClock()
        var terminations: [ProcessResult.Termination] = []
        let elapsed = await clock.measure {
            for _ in 0..<50 {
                terminations.append(await runner.run(spec("/usr/bin/true"), timeout: .seconds(5)).termination)
            }
        }
        #expect(terminations == Array(repeating: .exited(0), count: 50))
        #expect(elapsed < .seconds(10))
    }
}
