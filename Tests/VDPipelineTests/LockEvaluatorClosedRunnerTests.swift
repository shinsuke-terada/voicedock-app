// 閉じた ProcessRunner（アプリの終了の途中）での reaper の版の確かめ（F-76・issue #116。PLAN §8.2・§8.9.2）。
import Darwin
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDProcess
import VDStore

@testable import VDPipeline

@Suite("LockEvaluator（閉じた ProcessRunner）", .serialized)
struct LockEvaluatorClosedRunnerTests {
    /// terminateAll で閉じた本物の ProcessRunner（子は 0 件）
    static func closedRunner() async -> ProcessRunner {
        let runner = ProcessRunner()
        await runner.terminateAll(grace: .zero)
        return runner
    }

    static func refused() -> ProcessResult {
        ProcessResult(termination: .spawnFailed(errno: ECANCELED), stdoutTail: Data(), stderrTail: Data())
    }

    static func hasLog(_ scene: DeletionScene, _ event: String) -> Bool {
        scene.logLines.contains { $0.contains(" " + event) }
    }

    @Test("F-76 閉じた ProcessRunner では readiness は unconfirmed（reaper_invalid にしない）で、reaper_failed を出さない")
    func closedRunnerLeavesReadinessUnconfirmed() async throws {
        let scene = try DeletionScene()
        let locks = LockEvaluator(
            layout: scene.layout, verifier: scene.verifier, runner: await Self.closedRunner(), log: scene.log)
        #expect(await locks.readiness(config: scene.config) == .unconfirmed)
        #expect(await locks.readiness(config: scene.config) == .unconfirmed)
        #expect(await locks.readiness(config: scene.config, useCache: false) == .unconfirmed)
        #expect(!Self.hasLog(scene, "reaper_failed"))
    }

    @Test("F-76 版を観測できなかった結果はキャッシュしない（次に起動できれば configured）")
    func unobservedVersionIsNotCached() async throws {
        let scene = try DeletionScene()
        let runner = ScriptedProcessRunner(results: [Self.refused(), ScriptedProcessRunner.version()])
        let locks = LockEvaluator(layout: scene.layout, verifier: scene.verifier, runner: runner, log: scene.log)
        #expect(await locks.readiness(config: scene.config) == .unconfirmed)
        #expect(await locks.readiness(config: scene.config) == .configured)
        #expect(await runner.recorded.count == 2)
        #expect(!Self.hasLog(scene, "reaper_failed"))
    }

    @Test("F-76 ECANCELED 以外の起動の失敗（実行権が無い）は従来どおり reaper_invalid")
    func otherSpawnFailuresStayInvalid() async throws {
        let scene = try DeletionScene()
        let runner = ScriptedProcessRunner(results: [
            ProcessResult(termination: .spawnFailed(errno: EACCES), stdoutTail: Data(), stderrTail: Data())
        ])
        let locks = LockEvaluator(layout: scene.layout, verifier: scene.verifier, runner: runner, log: scene.log)
        #expect(await locks.readiness(config: scene.config) == .disabled("reaper_invalid"))
        #expect(Self.hasLog(scene, "reaper_failed reason=version_mismatch"))
    }

    @Test("F-76 閉じた ProcessRunner では削除の要求も、削除せずの完了もしない（Session は SAVED のまま待つ）")
    func closedRunnerNeitherRequestsNorCompletes() async throws {
        let scene = try DeletionScene()
        let locks = LockEvaluator(
            layout: scene.layout, verifier: scene.verifier, runner: await Self.closedRunner(), log: scene.log)
        let stage = SessionDeletionStage(
            deps: scene.deletionDependencies(ingest: ScriptedIngest(snapshot: scene.snapshot()), locks: locks))
        await stage.deleteSourcesIfSafe(sessionKey: DeletionScene.sessionKey)
        let session = try #require(try scene.store.session(DeletionScene.sessionKey))
        #expect(session.status == .saved)
        #expect(session.deleteAttempts == 1)
        #expect(try #require(try scene.store.recording(DeletionScene.partkey)).status == .rawSaved)
        #expect(scene.requests() == [])
        #expect(!Self.hasLog(scene, "source_delete_skipped"))
        #expect(!Self.hasLog(scene, "reaper_failed"))
    }
}
