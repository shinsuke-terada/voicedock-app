// アプリの終了で止めた whisper と、起動の失敗の写し方（PLAN §8.4 手順 6・§8.2。F-82・issue #119 の E6・E7）。
import Darwin
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDProcess

@testable import VDTranscribe

@Suite("Transcriber（F-82 終了で止めた whisper と起動の失敗）", .serialized, .timeLimit(.minutes(1)))
struct TranscriberStoppedTests {
    typealias Fixture = TranscriberTests.Fixture

    /// run が呼ばれたら whisper.json に document を書き、台本の結果を返す（止める前に 0 で終わっていた whisper の代わり）。
    actor WritingRunner: ProcessRunning {
        let json: URL
        let document: String
        let result: ProcessResult

        init(json: URL, document: String, result: ProcessResult) {
            self.json = json
            self.document = document
            self.result = result
        }

        func run(_ spec: ProcessSpec, timeout: Duration) async -> ProcessResult {
            try? Data(document.utf8).write(to: json)
            return result
        }

        func spawn(_ spec: ProcessSpec) async throws(SpawnError) -> RunningProcess {
            throw SpawnError.spawnFailed(errno: ENOSYS)
        }
    }

    static func result(_ termination: ProcessResult.Termination, stopped: Bool = false) -> ProcessResult {
        ProcessResult(termination: termination, stdoutTail: Data(), stderrTail: Data(), stoppedByTerminateAll: stopped)
    }

    static func transcriber(_ f: Fixture, runner: any ProcessRunning) -> Transcriber {
        Transcriber(
            runner: runner, paths: f.paths, layout: f.layout, config: Fixture.defaults(), catalog: f.catalog,
            clock: FixedClock(epochMillis: 1_788_000_000_000))
    }

    static func run(_ f: Fixture, _ scripted: ProcessResult) async throws -> TranscribeOutcome {
        try FakeWhisper.write(to: f.script)
        return await transcriber(f, runner: ScriptedProcessRunner(results: [scripted])).transcribe(f.request())
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    @Test("F-82 terminateAll が止めた whisper（SIGTERM）は失敗にせず .stopped（生 JSON も transcript も残さない）")
    func stoppedBySigtermIsStopped() async throws {
        let f = try Fixture()
        let outcome = try await Self.run(f, Self.result(.signaled(SIGTERM), stopped: true))
        #expect(outcome == .stopped)
        #expect(!Self.exists(f.whisperJSON))
        #expect(!Self.exists(f.transcript))
    }

    @Test("F-82 閉じた後の起動の拒否（ECANCELED）は WHISPER_EXEC_MISSING にせず .stopped")
    func closedRunnerRefusalIsStopped() async throws {
        let f = try Fixture()
        #expect(try await Self.run(f, Self.result(.spawnFailed(errno: ProcessRunner.closedErrno))) == .stopped)
    }

    @Test("F-82 止めた印があっても 0 で終わって JSON があれば、結果として読む（止める前に終わっていた）")
    func exitZeroBeforeStopIsRead() async throws {
        let f = try Fixture()
        try FakeWhisper.write(to: f.script)
        let runner = WritingRunner(
            json: f.whisperJSON, document: FakeWhisper.rawDocument(), result: Self.result(.exited(0), stopped: true))
        let outcome = await Self.transcriber(f, runner: runner).transcribe(f.request())
        #expect(TranscriberTests.isTranscribed(outcome))
    }

    @Test("F-82 TEST-28 止めた印があっても 0 で終わり、生 JSON が空（0 バイト）なら .stopped にせず WHISPER_FAILED「生 JSON を読めません」")
    func emptyJSONAfterStopIsUnreadable() async throws {
        let f = try Fixture()
        try FakeWhisper.write(to: f.script)
        let runner = WritingRunner(json: f.whisperJSON, document: "", result: Self.result(.exited(0), stopped: true))
        let outcome = await Self.transcriber(f, runner: runner).transcribe(f.request())
        #expect(
            outcome
                == .failure(
                    StageFailure(.whisperFailed, "生 JSON を読めません: staging/\(TranscriberTests.slug)/whisper.json")))
    }

    @Test("F-82 止めた印の無いシグナル 15（利用者が whisper を止めたなど）は従来どおり WHISPER_FAILED")
    func signalWithoutStopIsFailure() async throws {
        let f = try Fixture()
        let outcome = try await Self.run(f, Self.result(.signaled(SIGTERM)))
        #expect(outcome == .failure(StageFailure(.whisperFailed, "シグナル 15: ")))
    }

    @Test(
        "F-82 実行ファイルの問題で起動できないときだけ WHISPER_EXEC_MISSING（再試行しない）",
        arguments: [
            (ENOENT, "spawn: errno 2"), (EACCES, "spawn: errno 13"), (EPERM, "spawn: errno 1"),
            (ENOEXEC, "spawn: errno 8"), (EBADARCH, "spawn: errno 86"), (EINVAL, "spawn: errno 22"),
            (ENOTDIR, "spawn: errno 20"), (ELOOP, "spawn: errno 62"), (ENAMETOOLONG, "spawn: errno 63"),
            (EBADEXEC, "spawn: errno 85"), (EBADMACHO, "spawn: errno 88"),
        ])
    func executableProblemsAreExecMissing(errno code: Int32, message: String) async throws {
        let f = try Fixture()
        let outcome = try await Self.run(f, Self.result(.spawnFailed(errno: code)))
        #expect(outcome == .failure(StageFailure(.whisperExecMissing, message)))
    }

    @Test(
        "F-82 一時的な起動の失敗（EAGAIN・EMFILE・ENFILE・ENOMEM・ETXTBSY）は WHISPER_FAILED（工程内リトライの対象）",
        arguments: [
            (EAGAIN, "spawn: errno 35"), (EMFILE, "spawn: errno 24"), (ENFILE, "spawn: errno 23"),
            (ENOMEM, "spawn: errno 12"), (ETXTBSY, "spawn: errno 26"),
        ])
    func transientSpawnFailuresAreWhisperFailed(errno code: Int32, message: String) async throws {
        let f = try Fixture()
        let outcome = try await Self.run(f, Self.result(.spawnFailed(errno: code)))
        #expect(outcome == .failure(StageFailure(.whisperFailed, message)))
        #expect(ErrorCode.whisperFailed.retryPolicy == .attempts)
    }

    @Test("F-82 本物の ProcessRunner: 実行中の whisper を terminateAll で止めると .stopped（起動の印を待ってから止める）")
    func realRunnerTerminateAllIsStopped() async throws {
        let f = try Fixture()
        try FakeWhisper.write(to: f.script, sleepSeconds: 30)
        let runner = ProcessRunner()
        let transcriber = Self.transcriber(f, runner: runner)
        let request = f.request()
        let task = Task { await transcriber.transcribe(request) }
        // 印: 偽 whisper は最初に argv を書く
        let argv = URL(fileURLWithPath: f.script.path(percentEncoded: false) + ".argv")
        var waited = 0
        while !Self.exists(argv), waited < 1_000 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(Self.exists(argv))

        await runner.terminateAll(grace: .seconds(5))

        #expect(await task.value == .stopped)
        #expect(!Self.exists(f.whisperJSON))
        #expect(!Self.exists(f.transcript))
    }
}
