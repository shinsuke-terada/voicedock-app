// アプリの終了で止めた文字起こしを失敗として記録しないこと（PLAN §8.4 手順 6・§8.15。F-82・issue #119 の E6・E7）。
import Darwin
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDProcess
import VDStore

@testable import VDPipeline

@Suite("PartStepsTranscribe（F-82 終了で止めた whisper）", .serialized)
struct PartStepsTranscribeStoppedTests {
    /// runner だけを差し替えた TickContext（ほかは世界のもの）。
    static func context(_ w: PipelineWorld, runner: any ProcessRunning) async throws -> TickContext {
        let base = try await w.context()
        let d = w.deps
        let deps = WorkerDependencies(
            layout: d.layout, paths: d.paths, store: d.store, config: d.config, ingest: d.ingest, runner: runner,
            llama: d.llama, chatTransportFactory: d.chatTransportFactory, clock: d.clock, sleeper: d.sleeper,
            log: d.log, license: d.license, catalog: d.catalog, physicalMemoryBytes: d.physicalMemoryBytes,
            locks: d.locks, volumeOpener: d.volumeOpener)
        return TickContext(
            deps: deps, config: base.config, zone: base.zone, snapshot: nil, pauses: base.pauses,
            activity: base.activity, stop: base.stop, undeletableStreaks: UndeletableStreaks())
    }

    static func result(_ termination: ProcessResult.Termination, stopped: Bool = false) -> ProcessResult {
        ProcessResult(termination: termination, stdoutTail: Data(), stderrTail: Data(), stoppedByTerminateAll: stopped)
    }

    @Test(
        "F-82 終了で止めた whisper（SIGTERM）と閉じた後の起動の拒否（ECANCELED）は FAILED にせず TRANSCRIBING のまま（retry_count・error_code・ログを書かない）",
        arguments: [
            PartStepsTranscribeStoppedTests.result(.signaled(SIGTERM), stopped: true),
            PartStepsTranscribeStoppedTests.result(.spawnFailed(errno: ECANCELED)),
        ])
    func stoppedWhisperLeavesRowForRecovery(_ scripted: ProcessResult) async throws {
        let (w, pk) = try await PartStepsTranscribeTests.prepared()
        let ctx = try await Self.context(w, runner: ScriptedProcessRunner(results: [scripted]))

        #expect(await PartSteps(ctx: ctx).ensureTranscribed(try w.part(pk)) == false)

        let row = try w.part(pk)
        #expect(row.status == .transcribing)
        #expect(row.retryCount == 0)
        #expect(row.errorCode == nil)
        #expect(row.errorMessage == nil)
        #expect(w.lines("transcription_failed").isEmpty)
        // 次回起動時の復旧が戻す（PLAN §5.3）
        _ = try Recovery(store: w.store, layout: w.layout, log: w.log, config: ctx.config, zone: ctx.zone).run()
        #expect(try w.part(pk).status == .normalized)
    }

    @Test("F-82 一時的な起動の失敗（EAGAIN）は WHISPER_FAILED（attempts）で FAILED にし、工程内リトライの対象になる")
    func transientSpawnFailureIsRetried() async throws {
        let (w, pk) = try await PartStepsTranscribeTests.prepared()
        let ctx = try await Self.context(
            w, runner: ScriptedProcessRunner(results: [Self.result(.spawnFailed(errno: EAGAIN))]))

        #expect(await PartSteps(ctx: ctx).ensureTranscribed(try w.part(pk)) == false)

        let row = try w.part(pk)
        #expect(row.status == .failed)
        #expect(row.errorCode == .whisperFailed)
        #expect(row.errorMessage == "spawn: errno 35")
        #expect(InProcessRetry(ctx: ctx).delay(entity: .recording, key: pk) == 3)
    }
}
