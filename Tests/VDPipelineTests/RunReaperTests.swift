// reaper の起動と、起動の後に始まった走査を待ってからの回収（PLAN §8.9.6・§8.9.3。T-38 §6.6）。
// reaper は ScriptedProcessRunner の偽物だけ（本物のプロセスを起動しない。/Volumes には触れない）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDProcess
import VDStore

@testable import VDPipeline

@Suite("runReaperIfNeeded")
struct RunReaperTests {
    static let pk = DeletionScene.partkey

    struct Fixture {
        let scene: DeletionScene
        let ingest: ScriptedIngest
        let runner: ScriptedProcessRunner
        let locks: LockEvaluator
        let deps: DeletionDependencies
        let id: String
    }

    /// 要求を 1 件書いた状態（要求は scene.locks の deps で書く）。起動は runner に記録する
    static func fixture(
        _ reaperResults: [ProcessResult] = [ScriptedProcessRunner.exited(0)], scene: DeletionScene? = nil
    ) async throws -> Fixture {
        let scene = try scene ?? DeletionScene()
        let ingest = ScriptedIngest(snapshot: scene.snapshot())
        let requestDeps = scene.deletionDependencies(ingest: ingest)
        #expect(await DeletionRequester(deps: requestDeps).requestDeletions(sessionKey: DeletionScene.sessionKey) == 1)
        let id = try #require(try scene.store.recording(pk)?.deleteRequestID)
        let runner = ScriptedProcessRunner(results: [ScriptedProcessRunner.version()] + reaperResults)
        let locks = LockEvaluator(layout: scene.layout, verifier: scene.verifier, runner: runner, log: scene.log)
        return Fixture(
            scene: scene, ingest: ingest, runner: runner, locks: locks,
            deps: scene.deletionDependencies(ingest: ingest, locks: locks), id: id)
    }

    static func run(_ f: Fixture, _ generation: UInt64 = 0) async -> UInt64 {
        await ResultCollector(deps: f.deps).runReaperIfNeeded(reaperScanGeneration: generation)
    }

    static func homeLaunches(_ runner: ScriptedProcessRunner) async -> Int {
        await runner.recorded.filter { $0.arguments.first == "--home" }.count
    }

    static func logged(_ scene: DeletionScene, _ body: String) -> Bool {
        scene.logLines.contains { $0.hasSuffix(" " + body) }
    }

    static func deleted(_ f: Fixture) throws {
        try f.scene.writeResult(partkey: pk, requestID: f.id, status: .deleted, detail: DeletionScene.relpath)
    }

    static func part(_ scene: DeletionScene) throws -> RecordingRow {
        try #require(try scene.store.recording(pk))
    }

    @Test("要求と書き込み可能なデバイスがあれば起動し、走査の後に回収する")
    func launchesAndCollectsAfterTheScan() async throws {
        let f = try await Self.fixture()
        await f.ingest.script([.publish(f.scene.snapshot(generation: 2, relpaths: []))])
        try Self.deleted(f)
        #expect(await Self.run(f) == 2)
        let recorded = await f.runner.recorded
        #expect(recorded.count == 2)
        let launch = try #require(recorded.last)
        #expect(launch.executable == f.scene.layout.reaperExecutable)
        #expect(launch.arguments == ["--home", f.scene.layout.root.path(percentEncoded: false)])
        #expect(launch.environment == ProcessEnvironment.standard)
        let timeouts = await f.runner.recordedTimeouts
        #expect(timeouts.count == 2 && timeouts[1] == .seconds(120))
        #expect(Self.logged(f.scene, "reaper_run exit=0"))
        #expect(await f.ingest.scanNowCalls == 1)
        #expect(try Self.part(f.scene).status == .completed)
    }

    @Test("要求が無ければ起動しない")
    func noRequestsNoLaunch() async throws {
        let f = try await Self.fixture()
        for url in f.scene.requests() { try FileManager.default.removeItem(at: url) }
        #expect(await Self.run(f, 3) == 3)
        #expect(await f.runner.recorded == [])
        #expect(await f.ingest.scanNowCalls == 0)
    }

    @Test(
        "書き込み可能なデバイスが無ければ起動しない（パラメータ化: readOnly true・nil・0 台・snapshot nil）",
        arguments: ["readOnly true", "readOnly nil", "0 台", "snapshot nil"])
    func noWritableDeviceNoLaunch(_ kind: String) async throws {
        let f = try await Self.fixture()
        switch kind {
        case "readOnly true": await f.ingest.setSnapshot(f.scene.snapshot(readOnly: true))
        case "readOnly nil": await f.ingest.setSnapshot(f.scene.snapshot(readOnly: nil))
        case "0 台": await f.ingest.setSnapshot(f.scene.snapshot(includeDevice: false))
        default: await f.ingest.setSnapshot(nil)
        }
        #expect(await Self.run(f) == 0)
        #expect(await f.runner.recorded == [])
    }

    @Test("起動の直前は署名と版を検証し直す")
    func readinessIsVerifiedWithoutCache() async throws {
        // --version を 2 回（キャッシュを作る 1 回と、起動の直前の 1 回）、その後に reaper
        let f = try await Self.fixture([ScriptedProcessRunner.version(), ScriptedProcessRunner.exited(0)])
        #expect(await f.locks.readiness(config: f.scene.config) == .configured)
        let verifiedBefore = f.scene.verifier.verifiedURLs.count
        _ = await Self.run(f)
        // 起動の直前の readiness（キャッシュを使わない）と ReaperRunner.run の 2 回
        #expect(f.scene.verifier.verifiedURLs.count == verifiedBefore + 2)
        let arguments = await f.runner.recorded.map(\.arguments)
        #expect(
            arguments == [["--version"], ["--version"], ["--home", f.scene.layout.root.path(percentEncoded: false)]])
    }

    @Test("準備が崩れていれば起動しない")
    func disabledReadinessNoLaunch() async throws {
        let f = try await Self.fixture()
        try f.scene.removeReaperConf()
        _ = await Self.run(f)
        #expect(await Self.homeLaunches(f.runner) == 0)
    }

    @Test("0 以外は reaper_failed exit_<n>（4 は busy。パラメータ化: 4・2・3）", arguments: [Int32(4), 2, 3])
    func nonZeroExitIsLogged(_ code: Int32) async throws {
        let f = try await Self.fixture([ScriptedProcessRunner.exited(code)])
        _ = await Self.run(f)
        #expect(Self.logged(f.scene, "reaper_run exit=" + String(code)))
        let reason = code == 4 ? "busy" : "exit_" + String(code)
        #expect(Self.logged(f.scene, "reaper_failed reason=" + reason))
        if code == 4 {
            #expect(!Self.logged(f.scene, "reaper_failed reason=exit_4"))
        }
        #expect(await f.ingest.scanNowCalls == 1)
    }

    @Test("タイムアウトは reason=timeout")
    func timeoutIsLogged() async throws {
        let f = try await Self.fixture([ProcessResult(termination: .timedOut, stdoutTail: Data(), stderrTail: Data())])
        _ = await Self.run(f)
        #expect(Self.logged(f.scene, "reaper_run exit=null"))
        #expect(Self.logged(f.scene, "reaper_failed reason=timeout"))
    }

    @Test("シグナルは 128+s、起動失敗は 127（パラメータ化）", arguments: ["signaled(9)", "spawnFailed(errno: 2)"])
    func signalAndSpawnFailureAreLogged(_ kind: String) async throws {
        let termination: ProcessResult.Termination = kind == "signaled(9)" ? .signaled(9) : .spawnFailed(errno: 2)
        let f = try await Self.fixture([ProcessResult(termination: termination, stdoutTail: Data(), stderrTail: Data())]
        )
        _ = await Self.run(f)
        let exit = kind == "signaled(9)" ? "137" : "127"
        #expect(Self.logged(f.scene, "reaper_run exit=" + exit))
        #expect(Self.logged(f.scene, "reaper_failed reason=exit_" + exit))
    }

    @Test("走査が見送られたら「今の generation + 1」を待つ")
    func skippedScanWaitsForTheNextScan() async throws {
        let f = try await Self.fixture()
        await f.ingest.setSnapshot(f.scene.snapshot(generation: 5, relpaths: []))
        await f.ingest.script([.skip])
        try Self.deleted(f)
        #expect(await Self.run(f) == 6)
        #expect(f.scene.results().count == 1)
        #expect(try Self.part(f.scene).status == .sourceDeleting)
    }

    @Test("ReaperRunner.run は起動の直前に署名を見る（ND-41 の 2 層目）")
    func signatureCheckedRightBeforeLaunch() async throws {
        let tmp = try TempDirectory()
        let layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
        let runner = ScriptedProcessRunner(results: [])
        let outcome = await ReaperRunner(layout: layout, runner: runner, verifier: FakeSignatureVerifier(valid: false))
            .run()
        #expect(outcome == .notLaunched(reason: "signature"))
        #expect(await runner.recorded == [])
    }
}
