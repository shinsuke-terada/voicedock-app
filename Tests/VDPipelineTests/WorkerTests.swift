// Worker のテスト（T-18 §6.9。PLAN §5.3・§5.4。voicedock test_worker_loop.py）。
import Foundation
import Synchronization
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDProcess
import VDStore

@testable import VDPipeline

@Suite("Worker", .serialized)
struct WorkerTests {
    /// 常に偽の課金の口。
    struct DenyingLicenseGate: LicenseGate {
        func allowsProcessing() -> Bool { false }
    }

    /// Worker を後から入れる箱（onStage から requestStop を呼ぶため）。
    final class WorkerBox: Sendable {
        let worker = Mutex<Worker?>(nil)
    }

    /// sleeper と license を差し替えた Worker。
    static func worker(
        _ w: PipelineWorld, sleeper: any Sleeper, license: any LicenseGate = AlwaysAllowLicenseGate(),
        onStage: (@Sendable (TickStage) -> Void)? = nil
    ) -> Worker {
        let deps = WorkerDependencies(
            layout: w.layout, paths: w.paths, store: w.store, config: w.configStore, ingest: w.ingest,
            runner: ProcessRunner(), catalog: TestCatalogs.minimal, license: license, clock: w.clock,
            sleeper: sleeper, log: w.log)
        return Worker(deps: deps, assertion: w.assertion, onStage: onStage)
    }

    static func relpath(_ hhmmss: String) -> String {
        "TX_MIC001_20260829_071201/TX01_MIC002_20260829_" + hhmmss + "_orig.wav"
    }

    static func ago(_ w: PipelineWorld, seconds: Int64) -> Instant {
        Instant(epochMillis: w.clock.now().epochMillis - seconds * 1000)
    }

    static func invalidate(_ w: PipelineWorld) async throws {
        try Data("{".utf8).write(to: w.layout.configFile)
        _ = await w.configStore.load()
    }

    static func putOrphan(_ w: PipelineWorld) throws -> URL {
        let url = w.layout.inboxFile(deviceID: "DJIMIC3", relpath: relpath("091204"))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 10).write(to: url)
        return url
    }

    /// RAW_WRITING から FAILED にした Part（戻ると RAW_WRITING。Raw の工程は T-18 では偽を返すので動かない）。
    static func failedAtRawWriting(_ w: PipelineWorld) throws -> String {
        let pk = try w.insertPart()
        try w.movePart(
            pk, [.normalizing, .normalized, .transcribing, .transcribed, .rawWriting, .failed],
            code: .obsidianRawWriteFailed)
        return pk
    }

    @Test("tick の段の順（PLAN §5.4）")
    func tickFollowsThePlanOrder() async throws {
        let w = try await PipelineWorld.make()
        await w.ingest.setSnapshot(FakeIngest.snapshot(completedAt: w.clock.now()))
        let recorder = StageRecorder()
        let worker = w.worker { recorder.record($0) }
        await worker.requeue(.manual)
        await worker.tick()
        #expect(recorder.recorded == TickStage.allCases)
    }

    @Test("snapshot が古ければ削除の 3 段を飛ばす")
    func staleSnapshotSkipsDeletionStages() async throws {
        let w = try await PipelineWorld.make()
        await w.ingest.setSnapshot(FakeIngest.snapshot(completedAt: Self.ago(w, seconds: 901)))
        let recorder = StageRecorder()
        await w.worker { recorder.record($0) }.tick()
        let expected = TickStage.allCases.filter {
            $0 != .manualRequeue && !TickStage.requiresFreshSnapshot.contains($0)
        }
        #expect(recorder.recorded == expected)
        #expect(!recorder.recorded.contains(.evaluateDeletions))
        #expect(!recorder.recorded.contains(.settleSkippedDeletions))
        #expect(!recorder.recorded.contains(.runReaperIfNeeded))
    }

    @Test("snapshot が無ければ（起動直後）削除の 3 段を飛ばす")
    func nilSnapshotSkipsDeletionStages() async throws {
        let w = try await PipelineWorld.make()
        let recorder = StageRecorder()
        await w.worker { recorder.record($0) }.tick()
        #expect(!recorder.recorded.contains(.evaluateDeletions))
        #expect(!recorder.recorded.contains(.settleSkippedDeletions))
        #expect(!recorder.recorded.contains(.runReaperIfNeeded))
        #expect(recorder.recorded.contains(.groupNewParts) && recorder.recorded.contains(.requeueOnConnect))
    }

    @Test("ちょうど 900 秒は新鮮")
    func freshnessBoundaryIsInclusive() async throws {
        let w = try await PipelineWorld.make()
        await w.ingest.setSnapshot(FakeIngest.snapshot(completedAt: Self.ago(w, seconds: 900)))
        let recorder = StageRecorder()
        await w.worker { recorder.record($0) }.tick()
        #expect(recorder.recorded.contains(.evaluateDeletions))
        #expect(recorder.recorded.contains(.settleSkippedDeletions))
        #expect(recorder.recorded.contains(.runReaperIfNeeded))
    }

    @Test("設定エラー中は何もしない")
    func configErrorDoesNothing() async throws {
        let w = try await PipelineWorld.make()
        let pk = try w.registerPart()
        try await Self.invalidate(w)
        let before = try w.partEvents(pk).count
        let recorder = StageRecorder()
        await w.worker { recorder.record($0) }.tick()
        #expect(recorder.recorded == [])
        #expect(try w.partEvents(pk).count == before)
        #expect(try w.part(pk).status == .discovered)
    }

    @Test("共存ガード中は何もしない")
    func coexistenceBlockedDoesNothing() async throws {
        let w = try await PipelineWorld.make()
        await w.ingest.setState(.coexistenceBlocked)
        let recorder = StageRecorder()
        await w.worker { recorder.record($0) }.tick()
        #expect(recorder.recorded == [])
    }

    @Test("start は復旧 → 閉じる → 孤児 → requeue")
    func startRecoversAndRequeues() async throws {
        let w = try await PipelineWorld.make()
        let normalizing = try w.insertPart(relpath: Self.relpath("071201"))
        try w.movePart(normalizing, [.normalizing])
        let failed = try w.insertPart(relpath: Self.relpath("071202"))
        try w.movePart(failed, [.normalizing, .failed], code: .importFailed)
        let orphan = try Self.putOrphan(w)

        await w.worker().start()

        let lines = w.sink.lines
        let wanted = [
            "INFO  service_started version=\(AppVersion.string) schema=v1_initial",
            "INFO  recovery_completed rolled_back=1",
            "INFO  inbox_orphans_removed count=1",
            "INFO  recovery_completed requeued=1",
        ]
        let indices = wanted.map { text in lines.firstIndex { $0.hasSuffix(text) } }
        #expect(indices.allSatisfy { $0 != nil })
        let found = indices.compactMap { $0 }
        #expect(found == found.sorted())
        #expect(!PipelineFixtures.exists(orphan))
        #expect(try w.part(normalizing).status == .discovered)
        #expect(try w.part(failed).status == .normalizing)
    }

    @Test("設定エラー中の start は保留し、解除後の最初の tick で行う")
    func startWhileBlockedIsDeferred() async throws {
        let w = try await PipelineWorld.make()
        try await Self.invalidate(w)
        let orphan = try Self.putOrphan(w)
        let worker = w.worker()
        await worker.start()
        #expect(w.lines("service_started").isEmpty)
        try AtomicFile.write(ConfigLoader.encode(PipelineFixtures.baseConfig()), to: w.layout.configFile)
        _ = await w.configStore.load()
        await worker.tick()
        #expect(w.lines("service_started").count == 1)
        #expect(PipelineFixtures.exists(orphan))
    }

    @Test("start は 1 回だけ")
    func startIsOnce() async throws {
        let w = try await PipelineWorld.make()
        let worker = w.worker()
        await worker.start()
        await worker.start()
        #expect(w.lines("service_started").count == 1)
    }

    @Test("connectEpoch が増えたら requeue(.connect)")
    func connectRisingEdgeRequeues() async throws {
        let w = try await PipelineWorld.make()
        let pk = try Self.failedAtRawWriting(w)
        let worker = w.worker()
        await w.ingest.setSnapshot(FakeIngest.snapshot(completedAt: w.clock.now(), connectEpoch: 0))
        await worker.tick()
        #expect(try w.part(pk).status == .failed)
        await w.ingest.setSnapshot(FakeIngest.snapshot(generation: 2, completedAt: w.clock.now(), connectEpoch: 1))
        await worker.tick()
        #expect(try w.part(pk).status == .rawWriting)
        try w.movePart(pk, [.failed], code: .obsidianRawWriteFailed)
        await worker.tick()
        #expect(try w.part(pk).status == .failed)
        await w.ingest.setSnapshot(FakeIngest.snapshot(generation: 3, completedAt: w.clock.now(), connectEpoch: 2))
        await worker.tick()
        #expect(try w.part(pk).status == .rawWriting)
    }

    @Test("起動後の最初の接続も契機")
    func firstConnectAfterStartupCounts() async throws {
        let w = try await PipelineWorld.make()
        let pk = try Self.failedAtRawWriting(w)
        await w.ingest.setSnapshot(FakeIngest.snapshot(completedAt: w.clock.now(), connectEpoch: 1))
        await w.worker().tick()
        #expect(try w.part(pk).status == .rawWriting)
    }

    @Test("再試行ボタンは次の tick の先頭")
    func manualRequeueRunsAtTickStart() async throws {
        let w = try await PipelineWorld.make()
        let pk = try Self.failedAtRawWriting(w)
        let worker = w.worker()
        await worker.requeue(.manual)
        #expect(try w.part(pk).status == .failed)
        await worker.tick()
        #expect(try w.part(pk).status == .rawWriting)
    }

    @Test("Part は started_at 順に処理する")
    func pendingPartsAreOrderedByStartedAt() async throws {
        let w = try await PipelineWorld.make()
        let nine = try w.registerPart(
            relpath: Self.relpath("090000"), startedAt: "2026-08-29T09:00:00+09:00", seconds: 2.0)
        let eight = try w.registerPart(
            relpath: Self.relpath("080000"), startedAt: "2026-08-29T08:00:00+09:00", seconds: 3.0)
        await w.worker().tick()
        let done = { (pk: String) throws -> Int64? in
            try w.partEvents(pk).first { $0.fromStatus == "NORMALIZING" && $0.toStatus == "NORMALIZED" }?.id
        }
        let eightID = try #require(try done(eight))
        let nineID = try #require(try done(nine))
        #expect(eightID < nineID)
    }

    @Test("終端の Part は扱わない")
    func terminalPartsAreNotPending() async throws {
        let w = try await PipelineWorld.make()
        let full: [PartStatus] = [.normalizing, .normalized, .transcribing, .transcribed, .rawWriting, .rawSaved]
        let paths: [(String, [PartStatus])] = [
            (Self.relpath("071201"), [.normalizing, .failed]),
            (Self.relpath("071202"), [.skipped]),
            (Self.relpath("071203"), full),
            (Self.relpath("071204"), full + [.completed]),
        ]
        var keys: [String] = []
        for (relpath, path) in paths {
            let pk = try w.insertPart(relpath: relpath)
            try w.movePart(pk, path)
            keys.append(pk)
        }
        let before = try w.eventCount(parts: keys)
        await w.worker().tick()
        #expect(try w.eventCount(parts: keys) == before)
    }

    @Test("停止要求は Part の区切りで効く")
    func stopBetweenPartsStops() async throws {
        let w = try await PipelineWorld.make()
        let first = try w.registerPart()
        let second = try w.registerPart(
            relpath: Self.relpath("081204"), startedAt: "2026-08-29T08:12:04+09:00", seconds: 3.0)
        let flag = StopFlag()
        let ctx = try await w.context(stop: flag, assertion: RecordingSleepAssertion(onBegin: { flag.set() }))
        await w.worker().stageProcessPendingParts(ctx)
        #expect(PartStates.normalizedOrBeyond.contains(try w.part(first).status))
        #expect(try w.part(second).status == .discovered)
    }

    @Test("課金の口が偽なら何もしない")
    func licenseGateStopsTheTick() async throws {
        let w = try await PipelineWorld.make()
        let recorder = StageRecorder()
        let worker = Self.worker(w, sleeper: w.sleeper, license: DenyingLicenseGate()) { recorder.record($0) }
        await worker.tick()
        #expect(recorder.recorded == [])
        #expect(w.lines("pipeline_paused").contains { $0.hasSuffix("WARNING pipeline_paused reason=license") })
    }

    @Test("service_stopping は 1 回")
    func requestStopLogsOnce() async throws {
        let w = try await PipelineWorld.make()
        let worker = w.worker()
        await worker.requestStop()
        await worker.requestStop()
        #expect(w.lines("service_stopping").count == 1)
    }

    @Test("run は通知で起きる")
    func runWakesOnUpdates() async throws {
        let w = try await PipelineWorld.make()
        let recorder = StageRecorder()
        let worker = Self.worker(w, sleeper: SuspendingSleeper()) { recorder.record($0) }
        let finished = Mutex<Bool>(false)
        let task = Task {
            await worker.run()
            finished.withLock { $0 = true }
        }
        defer { task.cancel() }
        try await waitUntil("1 回目の tick") { recorder.count(.groupNewParts) == 1 }
        await w.ingest.sendUpdate()
        try await waitUntil("2 回目の tick") { recorder.count(.groupNewParts) == 2 }
        await worker.requestStop()
        try await waitUntil("run の終わり") { finished.withLock { $0 } }
        #expect(recorder.count(.groupNewParts) == 2)
    }

    @Test("run はパネルの要求で起きる")
    func runWakesOnRequeue() async throws {
        let w = try await PipelineWorld.make()
        let recorder = StageRecorder()
        let worker = Self.worker(w, sleeper: SuspendingSleeper()) { recorder.record($0) }
        let finished = Mutex<Bool>(false)
        let task = Task {
            await worker.run()
            finished.withLock { $0 = true }
        }
        defer { task.cancel() }
        try await waitUntil("1 回目の tick") { recorder.count(.groupNewParts) == 1 }
        await worker.requeue(.manual)
        try await waitUntil("2 回目の tick") { recorder.count(.groupNewParts) == 2 }
        #expect(recorder.count(.manualRequeue) == 1)
        await worker.requestStop()
        try await waitUntil("run の終わり") { finished.withLock { $0 } }
    }

    @Test("停止の後は tick しない")
    func runDoesNotTickAfterStop() async throws {
        let w = try await PipelineWorld.make()
        let recorder = StageRecorder()
        let box = WorkerBox()
        let worker = Self.worker(w, sleeper: SuspendingSleeper()) { stage in
            recorder.record(stage)
            if stage == .groupNewParts, let target = box.worker.withLock({ $0 }) {
                Task { await target.requestStop() }
            }
        }
        box.worker.withLock { $0 = worker }
        let finished = Mutex<Bool>(false)
        let task = Task {
            await worker.run()
            finished.withLock { $0 = true }
        }
        defer { task.cancel() }
        try await waitUntil("run の終わり") { finished.withLock { $0 } }
        #expect(recorder.count(.groupNewParts) == 1)
    }

    @Test("工程の間だけスリープを抑止する")
    func sleepAssertionFollowsActivity() async throws {
        let w = try await PipelineWorld.make()
        try w.installWhisper()
        try w.registerPart()
        let worker = w.worker()
        await worker.tick()
        #expect(w.assertion.begins >= 1)
        #expect(w.assertion.active == false)
        #expect(await worker.status().activity == .idle)
    }
}
