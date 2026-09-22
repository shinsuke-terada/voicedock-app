// 削除の段の配線: Worker の tick を回して、Raw の直後・SAVED の直後の口と tick の段が中身を呼ぶこと（PLAN §5.4・§8.9。T-38 §6.9・T-39 §6.4。TEST-06）。
// デバイスは <tmp>/Volumes/DJIMIC3（TempDirectory の中だけ）。reaper はスタブで、起動は ScriptedProcessRunner に記録する。
import Darwin
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDStore

@testable import VDPipeline

@Suite("削除の段の配線", .serialized)
struct DeletionStagesWiringTests {
    struct Wired {
        let world: PipelineWorld
        /// reaper の検証と起動を記録する（world.locks の runner）
        let runner: ScriptedProcessRunner
        let pk: String
    }

    /// 削除を有効にし、Vault・whisper・Part・デバイス上の原本・スタブの reaper・reaper.conf・新鮮な snapshot を置く。
    /// deleteSkippedSource が真ならロック B も開ける（T-39 §6.4）。
    static func makeWorld(snapshotAge: Int = 0, deleteSkippedSource: Bool = false) async throws -> Wired {
        let base = try await PipelineWorld.make {
            $0.cleanup.deleteSourceAudio = true
            $0.cleanup.deleteSkippedSource = deleteSkippedSource
            $0.device.mountMode = "rw"
        }
        let runner = ScriptedProcessRunner(results: [ScriptedProcessRunner.version()])
        let locks = LockEvaluator(layout: base.layout, verifier: base.verifier, runner: runner, log: base.log)
        let w = PipelineWorld(
            tmp: base.tmp, layout: base.layout, paths: base.paths, store: base.store, configStore: base.configStore,
            ingest: base.ingest, clock: base.clock, sleeper: base.sleeper, sink: base.sink, log: base.log,
            assertion: base.assertion, chat: base.chat, llm: base.llm, physicalMemoryBytes: base.physicalMemoryBytes,
            locks: locks, verifier: base.verifier)
        try await w.installVault()
        try w.installWhisper()
        let pk = try w.registerPart()
        // デバイス上の原本: inbox と同じバイト列、mtime は登録の source_mtime
        let volumes = w.tmp.url.appendingPathComponent("Volumes", isDirectory: true)
        let original = volumes.appendingPathComponent("DJIMIC3", isDirectory: true)
            .appendingPathComponent(PipelineFixtures.relpath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: w.layout.inboxFile(deviceID: "DJIMIC3", relpath: PipelineFixtures.relpath))
            .write(to: original)
        var times = [timeval(tv_sec: 1_787_000_000, tv_usec: 0), timeval(tv_sec: 1_787_000_000, tv_usec: 0)]
        #expect(utimes(original.path(percentEncoded: false), &times) == 0)
        // スタブの reaper と reaper.conf
        try FileManager.default.createDirectory(at: w.layout.binDirectory, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: w.layout.reaperExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: w.layout.reaperExecutable.path(percentEncoded: false))
        try ReaperConf(deleteSourceAudio: true, volumesRoot: volumes.path(percentEncoded: false)).render()
            .write(to: w.layout.reaperConf)
        await w.ingest.setSnapshot(
            FakeIngest.snapshot(
                generation: 1, completedAt: w.clock.now().adding(seconds: -snapshotAge),
                devices: ["DJIMIC3": [PipelineFixtures.relpath]]))
        return Wired(world: w, runner: runner, pk: pk)
    }

    /// queue/delete の . 始まりでない .json（実装の DeleteQueue.names を使わずに数える）
    static func requests(_ w: PipelineWorld) -> [String] {
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: w.layout.queueDelete.path(percentEncoded: false)))
            ?? []
        return names.filter { !$0.hasPrefix(".") && $0.hasSuffix(".json") }
    }

    /// DB の delete_request_id の DELETED 結果を queue/result に置く
    static func writeDeleted(_ w: PipelineWorld, pk: String, id: String) throws {
        let data = try ContractJSON.encode(
            DeleteResult(
                requestID: id, completedAt: PipelineFixtures.zone.iso(w.clock.now()), reaperVersion: AppVersion.string,
                deviceID: "DJIMIC3", partkey: pk, status: .deleted, detail: PipelineFixtures.relpath))
        try data.write(to: DeleteQueue.resultURL(id, layout: w.layout))
    }

    static func homeLaunches(_ runner: ScriptedProcessRunner) async -> Int {
        await runner.recorded.filter { $0.arguments.first == "--home" }.count
    }

    @Test("1 tick で Raw の直後に要求を書き、reaper を起動する")
    func tickRequestsDeletionAfterTheRawNote() async throws {
        let wired = try await Self.makeWorld()
        let w = wired.world
        await w.worker().tick()
        #expect(try w.part(wired.pk).status == .sourceDeleting)
        #expect(Self.requests(w).count == 1)
        #expect(!w.lines("delete_requested").isEmpty)
        #expect(w.sink.lines.contains { $0.hasSuffix(" reaper_run exit=0") })
        #expect(await w.ingest.scanNowCalls == 1)
    }

    @Test("次の tick で結果を回収して完了する")
    func nextTickCollectsTheResult() async throws {
        let wired = try await Self.makeWorld()
        let w = wired.world
        let worker = w.worker()
        await worker.tick()
        let id = try #require(try w.part(wired.pk).deleteRequestID)
        // reaper の姿: 要求を消して結果を書く（次の tick で reaper を起動しないので、回収は段 collectDeleteResults だけ）
        for name in Self.requests(w) {
            try FileManager.default.removeItem(at: w.layout.queueDelete.appendingPathComponent(name))
        }
        try Self.writeDeleted(w, pk: wired.pk, id: id)
        await w.ingest.setSnapshot(
            FakeIngest.snapshot(generation: 2, completedAt: w.clock.now(), devices: ["DJIMIC3": []]))
        await worker.tick()
        #expect(await Self.homeLaunches(wired.runner) == 1)
        let part = try w.part(wired.pk)
        #expect(part.status == .completed)
        #expect(part.sourceDeletedAt != nil)
    }

    @Test("snapshot が古い tick では reaper を起動しない")
    func staleSnapshotDoesNotLaunch() async throws {
        let wired = try await Self.makeWorld(snapshotAge: 901)
        let w = wired.world
        await w.worker().tick()
        #expect(await Self.homeLaunches(wired.runner) == 0)
        // Raw の直後の要求も書かない（DEL-20）
        #expect(Self.requests(w) == [])
        #expect(try w.part(wired.pk).status == .rawSaved)
    }

    @Test("SAVED の直後の口（SessionSteps.deleteSourcesIfSafe）が削除段を呼ぶ")
    func savedHookRunsTheStage() async throws {
        let w = try await PipelineWorld.make()
        try w.addSession(key: "DJIMIC3:20260829", day: "2026-08-29", status: .saved)
        let pk = try w.addPart(PipelineFixtures.partA, status: .rawSaved)
        await SessionSteps(ctx: try await w.context()).deleteSourcesIfSafe("DJIMIC3:20260829")
        #expect(try w.session("DJIMIC3:20260829").status == .completed)
        #expect(try w.part(pk).status == .completed)
        #expect(
            w.sink.lines.contains {
                $0.hasSuffix(" source_delete_skipped session_key=DJIMIC3:20260829 reason=delete_source_audio_disabled")
            })
    }

    @Test("起動直後の reaperScanGeneration は 0（どの generation の走査でも判定できる）")
    func scanGenerationStartsAtZero() async throws {
        let wired = try await Self.makeWorld()
        let w = wired.world
        let key = PipelineFixtures.vaultSessionKey
        try w.addSession(key: key, day: "2026-08-29", status: .sourceDeleting)
        try w.forcePart(wired.pk, status: .sourceDeleting, sessionKey: key)
        let id = RequestID.make(partkey: wired.pk, utcEpochSeconds: 1_788_040_812, randomHex6: "abcdef")
        try w.store.updateRecording(wired.pk, [.deleteRequestID(id)])
        try Self.writeDeleted(w, pk: wired.pk, id: id)
        await w.ingest.setSnapshot(
            FakeIngest.snapshot(generation: 1, completedAt: w.clock.now(), devices: ["DJIMIC3": []]))
        await w.worker().tick()
        #expect(try w.part(wired.pk).status == .completed)
    }

    /// 無音で SKIPPED にした Part（transcript を置き、OPEN の Session に入れる）で、間引きを越えてから 1 tick 回す（T-39 §6.4）
    static func tickWithSkippedPart(snapshotAge: Int) async throws -> Wired {
        let wired = try await Self.makeWorld(snapshotAge: snapshotAge, deleteSkippedSource: true)
        let w = wired.world
        try StorePaths.advancePart(w.store, partkey: wired.pk, to: .skipped, errorCode: .noSpeechDetected)
        try PartTranscriptCodec.encode(
            PartTranscript(
                partkey: wired.pk, language: "ja", durationSeconds: 2.0, startedAt: PipelineFixtures.startedAt,
                text: "", segments: [])
        ).write(to: w.layout.transcript(slug: KeySlug.of(wired.pk)))
        try w.addSession(key: "DJIMIC3:20260829", day: "2026-08-29", status: .open)
        try w.store.updateRecording(wired.pk, [.sessionKey("DJIMIC3:20260829")])
        w.clock.advance(seconds: 60)
        await w.worker().tick()
        return wired
    }

    @Test("tick の中で根拠 B の要求を書く（settleSkippedDeletions の段の配線）")
    func tickSettlesSkippedParts() async throws {
        let wired = try await Self.tickWithSkippedPart(snapshotAge: 0)
        let w = wired.world
        #expect(Self.requests(w).count == 1)
        let part = try w.part(wired.pk)
        #expect(part.status == .skipped)
        #expect(part.deleteRequestID != nil)
        #expect(!w.lines("delete_requested").isEmpty)
    }

    @Test("snapshot が古い tick では根拠 B の段を行わない")
    func staleTickDoesNotSettle() async throws {
        let wired = try await Self.tickWithSkippedPart(snapshotAge: 901)
        let w = wired.world
        #expect(Self.requests(w) == [])
        #expect(try w.part(wired.pk).deleteRequestID == nil)
    }
}
