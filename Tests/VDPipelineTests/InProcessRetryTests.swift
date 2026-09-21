// 工程内リトライのテスト（T-18 §6.5。PLAN §5.4。voicedock test_worker_loop.py の failing_pipeline）。
import Foundation
import Synchronization
import TestSupport
import Testing
import VDContract
import VDCore
import VDProcess
import VDStore

@testable import VDPipeline

@Suite("InProcessRetry")
struct InProcessRetryTests {
    /// 待ちの中で停止を立てる Sleeper。
    struct StoppingSleeper: Sleeper {
        let flag: StopFlag
        func sleep(seconds: Int) async throws { flag.set() }
    }

    /// 待ちが取り消された Sleeper。
    struct CancelledSleeper: Sleeper {
        func sleep(seconds: Int) async throws { throw CancellationError() }
    }

    /// sleeper と stop を差し替えた TickContext。
    static func context(_ w: PipelineWorld, sleeper: any Sleeper, stop: StopFlag = StopFlag()) async throws
        -> TickContext
    {
        guard let config = await w.configStore.current() else { throw PipelineFixtureError.noConfig }
        let deps = WorkerDependencies(
            layout: w.layout, paths: w.paths, store: w.store, config: w.configStore, ingest: w.ingest,
            runner: ProcessRunner(), catalog: TestCatalogs.minimal, license: AlwaysAllowLicenseGate(), clock: w.clock,
            sleeper: sleeper, log: w.log)
        return TickContext(
            deps: deps, config: config, zone: PipelineFixtures.zone, snapshot: nil, pauses: PauseBook(log: w.log),
            activity: ActivityBoard(assertion: RecordingSleepAssertion()), stop: stop)
    }

    /// 偽の Part の工程: NORMALIZING でなければ NORMALIZING にしてから NORMALIZING→FAILED(code)。
    static func failPart(_ w: PipelineWorld, _ pk: String, _ code: ErrorCode) {
        if (try? w.part(pk).status) != .normalizing { try? w.movePart(pk, [.normalizing]) }
        try? w.movePart(pk, [.failed], code: code)
    }

    /// 偽の Session の工程: ANALYZING でなければ ANALYZING にしてから ANALYZING→FAILED(code)。
    static func failSession(_ w: PipelineWorld, _ key: String, _ code: ErrorCode) {
        if (try? w.store.session(key)?.status) != .analyzing { try? w.moveSession(key, [.analyzing]) }
        try? w.moveSession(key, [.failed], code: code)
    }

    static func retryEvents(_ w: PipelineWorld, _ pk: String) throws -> [EventRow] {
        try w.partEvents(pk).filter { $0.detail == "retry" }
    }

    @Test("失敗 → 3 秒 → 失敗 → 10 秒 → 失敗 → 終了")
    func waitsTheBackoffBetweenAttempts() async throws {
        let w = try await PipelineWorld.make()
        let pk = try w.insertPart()
        let calls = Mutex<Int>(0)
        // 戻すたびに retry_count が 0 に戻る壊れ方では終わらないので、10 回で止める（止まらずに落ちるようにする）
        let stop = StopFlag()
        await InProcessRetry(ctx: try await w.context(stop: stop)).run(entity: .recording, key: pk) {
            let n = calls.withLock {
                $0 += 1
                return $0
            }
            Self.failPart(w, pk, .whisperFailed)
            if n >= 10 { stop.set() }
        }
        #expect(calls.withLock { $0 } == 3)
        #expect(w.sleeper.recorded == [3, 10])
        let retries = try Self.retryEvents(w, pk)
        #expect(retries.count == 2)
        #expect(retries.allSatisfy { $0.fromStatus == "FAILED" && $0.toStatus == "NORMALIZING" })
    }

    @Test("attempts 以外は 1 回で終わる")
    func exemptCodeRunsOnce() async throws {
        let w = try await PipelineWorld.make()
        let pk = try w.insertPart()
        let calls = Mutex<Int>(0)
        await InProcessRetry(ctx: try await w.context()).run(entity: .recording, key: pk) {
            calls.withLock { $0 += 1 }
            Self.failPart(w, pk, .whisperExecMissing)
        }
        #expect(calls.withLock { $0 } == 1)
        #expect(w.sleeper.recorded == [])
    }

    @Test("停止要求の後は待たない")
    func stopBeforeSleepDoesNotSleep() async throws {
        let w = try await PipelineWorld.make()
        let pk = try w.insertPart()
        let stop = StopFlag()
        let calls = Mutex<Int>(0)
        await InProcessRetry(ctx: try await w.context(stop: stop)).run(entity: .recording, key: pk) {
            calls.withLock { $0 += 1 }
            Self.failPart(w, pk, .whisperFailed)
            stop.set()
        }
        #expect(calls.withLock { $0 } == 1)
        #expect(w.sleeper.recorded == [])
    }

    @Test("待ちの後に停止を見る")
    func stopDuringSleepDoesNotResume() async throws {
        let w = try await PipelineWorld.make()
        let pk = try w.insertPart()
        let stop = StopFlag()
        let calls = Mutex<Int>(0)
        let ctx = try await Self.context(w, sleeper: StoppingSleeper(flag: stop), stop: stop)
        await InProcessRetry(ctx: ctx).run(entity: .recording, key: pk) {
            calls.withLock { $0 += 1 }
            Self.failPart(w, pk, .whisperFailed)
        }
        #expect(calls.withLock { $0 } == 1)
        #expect(try w.part(pk).status == .failed)
    }

    @Test("待ちが取り消されたら終わる")
    func cancelledSleepEnds() async throws {
        let w = try await PipelineWorld.make()
        let pk = try w.insertPart()
        let calls = Mutex<Int>(0)
        let ctx = try await Self.context(w, sleeper: CancelledSleeper())
        await InProcessRetry(ctx: ctx).run(entity: .recording, key: pk) {
            calls.withLock { $0 += 1 }
            Self.failPart(w, pk, .whisperFailed)
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test("Session も同じ")
    func sessionRetriesToo() async throws {
        let w = try await PipelineWorld.make()
        let key = "DJIMIC3:20260829"
        try w.moveSession(key, [.ready, .merging, .merged])
        let calls = Mutex<Int>(0)
        await InProcessRetry(ctx: try await w.context()).run(entity: .session, key: key) {
            calls.withLock { $0 += 1 }
            Self.failSession(w, key, .llmUnavailable)
        }
        #expect(calls.withLock { $0 } == 3)
        #expect(w.sleeper.recorded == [3, 10])
    }

    @Test("CE retry.maxAttempts 2 にすると 2 回で終わる")
    func ceRetryMaxAttempts() async throws {
        let w = try await PipelineWorld.make { $0.retry.maxAttempts = 2 }
        let pk = try w.insertPart()
        let calls = Mutex<Int>(0)
        await InProcessRetry(ctx: try await w.context()).run(entity: .recording, key: pk) {
            calls.withLock { $0 += 1 }
            Self.failPart(w, pk, .whisperFailed)
        }
        #expect(calls.withLock { $0 } == 2)
        #expect(w.sleeper.recorded == [3])
    }

    @Test("CE retry.backoffSeconds [5,7,9] の待ちが使われる")
    func ceRetryBackoffSeconds() async throws {
        let w = try await PipelineWorld.make { $0.retry.backoffSeconds = [5, 7, 9] }
        let pk = try w.insertPart()
        await InProcessRetry(ctx: try await w.context()).run(entity: .recording, key: pk) {
            Self.failPart(w, pk, .whisperFailed)
        }
        #expect(w.sleeper.recorded == [5, 7])
    }
}
