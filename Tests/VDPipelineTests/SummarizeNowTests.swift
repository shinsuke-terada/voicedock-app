// 今すぐ要約（WorkerJob.summarizeNow）のテスト（PLAN §5.4・F-66）。Vault は TempDirectory の中だけ。
import Foundation
import Synchronization
import TestSupport
import Testing
import VDContract
import VDCore
import VDLLM
import VDStore

@testable import VDPipeline

/// 今すぐ要約の返事を順に覚える。
final class SummarizeNowReplies: Sendable {
    private let replies = Mutex<[Result<Int, SummarizeNowFailure>]>([])

    var job: WorkerJob {
        .summarizeNow(reply: { r in self.replies.withLock { $0.append(r) } })
    }

    var results: [Result<Int, SummarizeNowFailure>] { replies.withLock { $0 } }
}

/// 札つきで返事を順に覚える（入れた順を確かめる）。
final class TaggedSummarizeNowReplies: Sendable {
    private let replies = Mutex<[(tag: Int, result: Result<Int, SummarizeNowFailure>)]>([])

    func job(_ tag: Int) -> WorkerJob {
        .summarizeNow(reply: { r in self.replies.withLock { $0.append((tag, r)) } })
    }

    var tags: [Int] { replies.withLock { $0.map(\.tag) } }
    var results: [Result<Int, SummarizeNowFailure>] { replies.withLock { $0.map(\.result) } }
}

/// complete の中で release まで止まる ChatTransport（LLMProbeCheck の await の間に割り込むため）。
final class GateChatTransport: ChatTransport {
    private struct State {
        var entered = false
        var released = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    var entered: Bool { state.withLock { $0.entered } }

    func complete(system: String, user: String) async -> ChatResult {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { s in
                s.entered = true
                if s.released { return true }
                s.waiter = c
                return false
            }
            if resumeNow { c.resume() }
        }
        return .content("ok")
    }

    func release() {
        let waiter = state.withLock { s in
            s.released = true
            let w = s.waiter
            s.waiter = nil
            return w
        }
        waiter?.resume()
    }
}

@Suite("SummarizeNow", .serialized, .timeLimit(.minutes(1)))
struct SummarizeNowTests {
    static let key = PipelineFixtures.vaultSessionKey
    /// 2026-08-29T07:30:00+09:00（Part A の 07:12:04 と同じ日。idle の 1800 秒は経っていない）
    static let sameDayMorning: Int64 = 1_787_956_200_000
    /// 2026-08-29T07:50:00+09:00（Part B の 07:42:10 の後）
    static let sameDayLater: Int64 = 1_787_957_400_000
    static let stopped = SummarizeNowFailure(message: "終了中のため実行しませんでした")

    /// 時計は 2026-08-29T07:30:00+09:00。whisper・LLM・Vault を置き、Part A を登録して 1 tick 回す（Session は OPEN のまま）。
    static func openWorld(llm: Bool = true, configure: (inout AppConfig) -> Void = { _ in }) async throws
        -> (PipelineWorld, Worker)
    {
        let w = try await PipelineWorld.make(
            configure: configure,
            chat: FakeChatTransport(
                responses: [.content(PipelineFixtures.analysis), .content(PipelineFixtures.analysis)]))
        w.clock.set(Instant(epochMillis: Self.sameDayMorning))
        try w.installWhisper()
        if llm { try await w.installLLM() }
        try await w.installVault(marker: true)
        let a = PipelineFixtures.partA
        try w.registerPart(relpath: a.relpath, startedAt: a.startedAt, seconds: a.seconds)
        let worker = w.worker()
        await worker.start()
        await worker.tick()
        return (w, worker)
    }

    @Test("今日の OPEN を閉じ、同じ tick で要約まで進めて、閉じた数を 1 回だけ返す")
    func closesTodayAndSummarizesInTheSameTick() async throws {
        let (w, worker) = try await Self.openWorld()
        // 手動の要約が無ければ当日・idle 前の Session は OPEN のまま（Part は終端まで進む）
        #expect(try w.session(Self.key).status == .open)
        #expect(await w.chat.calls.isEmpty)

        let replies = SummarizeNowReplies()
        await worker.enqueue(replies.job)
        await worker.tick()

        #expect(replies.results == [.success(1)])
        let s = try w.session(Self.key)
        #expect(s.status == .completed)
        #expect(s.outputPath == "Daily/Voice/Wiki/20260829/2026-08-29 Voice.md")
        let events = try w.sessionEvents(Self.key)
        let ready = try #require(events.first { $0.toStatus == "READY" })
        #expect(ready.fromStatus == "OPEN")
        #expect(ready.detail == "summarize_now")
        #expect(await w.chat.calls.count == 1)
        #expect(await worker.pendingJobs.isEmpty)

        // 次の tick で返事が重ならない
        await worker.tick()
        #expect(replies.results == [.success(1)])
    }

    @Test("閉じた後の同じ日の録音で再オープンし、要約し直す")
    func laterPartSameDayReopensAndResummarizes() async throws {
        let (w, worker) = try await Self.openWorld()
        let replies = SummarizeNowReplies()
        await worker.enqueue(replies.job)
        await worker.tick()
        #expect(try w.session(Self.key).status == .completed)
        let before = try w.sessionEvents(Self.key).count

        w.clock.set(Instant(epochMillis: Self.sameDayLater))
        let b = PipelineFixtures.partB
        let pkB = try w.registerPart(relpath: b.relpath, startedAt: b.startedAt, seconds: b.seconds)
        await worker.tick()

        #expect(try w.part(pkB).status == .completed)
        let s = try w.session(Self.key)
        #expect(s.status == .completed)
        #expect(s.regeneratedCount == 1)
        let added = Array(try w.sessionEvents(Self.key).dropFirst(before))
        #expect(
            added.map(\.toStatus) == [
                "MERGING", "MERGED", "ANALYZING", "ANALYZED", "WRITING", "SAVED", "CLEANUP", "COMPLETED",
            ])
        #expect(added.first?.detail == "reopen")
        #expect(await w.chat.calls.count == 2)
        let daily = try w.noteText("Daily/Voice/Wiki/20260829/2026-08-29 Voice.md")
        #expect(daily.contains("\nparts: 2\n"))
        #expect(replies.results == [.success(1)])
    }

    @Test("TEST-28 OPEN の Session が 0 件なら 0 を返す")
    func noOpenSessionRepliesZero() async throws {
        let w = try await PipelineWorld.make()
        try await w.installLLM()
        let worker = w.worker()
        let replies = SummarizeNowReplies()
        await worker.enqueue(replies.job)
        await worker.tick()
        #expect(replies.results == [.success(0)])
        #expect(try w.store.sessions(status: .ready).isEmpty)
    }

    @Test("押した時点の OPEN を日付を問わず全部閉じる（過去の日の取り残しも）")
    func closesEveryOpenSessionRegardlessOfDay() async throws {
        let w = try await PipelineWorld.make()
        try await w.installLLM()
        // 2026-08-29T08:30:00+09:00。どちらも作った直後（idle 前）
        w.clock.set(Instant(epochMillis: 1_787_959_800_000))
        try w.store.insertSession(
            NewSession(sessionKey: "DJIMIC3:20260829", dayDate: "2026-08-29", deviceID: "DJIMIC3"))
        try w.store.insertSession(
            NewSession(sessionKey: "DJIMIC3:20260828", dayDate: "2026-08-28", deviceID: "DJIMIC3"))
        let worker = w.worker()
        let replies = SummarizeNowReplies()
        await worker.enqueue(replies.job)
        await worker.tick()
        #expect(replies.results == [.success(2)])
        for key in ["DJIMIC3:20260828", "DJIMIC3:20260829"] {
            #expect(try w.session(key).status == .ready)
            #expect(try w.sessionEvents(key).last?.detail == "summarize_now")
        }
    }

    @Test("LLM のモデルが無ければ閉じずに失敗で返す")
    func missingLLMRepliesFailureWithoutClosing() async throws {
        let (w, worker) = try await Self.openWorld(llm: false)
        #expect(try w.session(Self.key).status == .open)
        let replies = SummarizeNowReplies()
        await worker.enqueue(replies.job)
        await worker.tick()
        #expect(replies.results == [.failure(SummarizeNowFailure(message: "LLM が未選択"))])
        #expect(try w.session(Self.key).status == .open)
        #expect(!(try w.sessionEvents(Self.key).contains { $0.detail == "summarize_now" }))
    }

    @Test("選んだ LLM のファイルと llama-server が無ければ理由を並べて返す")
    func missingModelFileListsReasons() async throws {
        let w = try await PipelineWorld.make { $0.llm.modelID = "test-llm" }
        let worker = w.worker()
        let replies = SummarizeNowReplies()
        await worker.enqueue(replies.job)
        await worker.tick()
        #expect(
            replies.results == [.failure(SummarizeNowFailure(message: "LLM モデルがありません、llama-server がありません"))])
    }

    @Test("設定エラー中は失敗で返す")
    func configErrorRepliesFailure() async throws {
        let w = try await PipelineWorld.make()
        try await w.installLLM()
        let worker = w.worker()
        try Data("{".utf8).write(to: w.layout.configFile)
        _ = await w.configStore.load()
        #expect(await w.configStore.current() == nil)
        let replies = SummarizeNowReplies()
        await worker.enqueue(replies.job)
        await worker.tick()
        #expect(replies.results == [.failure(SummarizeNowFailure(message: "設定が読めていません"))])
        #expect(await worker.pendingJobs.isEmpty)
    }

    @Test("停止要求のときは失敗で返す（段の中・列で待つ間・停止の後の enqueue）")
    func stopRepliesFailure() async throws {
        let (w, worker) = try await Self.openWorld()
        // 段の途中で停止要求が立ったとき（stageSummarizeNow が ctx.stop を見る）
        let inStage = SummarizeNowReplies()
        await worker.enqueue(inStage.job)
        let stop = StopFlag()
        stop.set()
        await worker.stageSummarizeNow(try await w.context(stop: stop))
        #expect(inStage.results == [.failure(Self.stopped)])
        #expect(try w.session(Self.key).status == .open)
        // 列で待っている間に requestStop
        let queued = SummarizeNowReplies()
        await worker.enqueue(queued.job)
        await worker.requestStop()
        #expect(queued.results == [.failure(Self.stopped)])
        #expect(await worker.pendingJobs.isEmpty)
        // requestStop の後の enqueue → tick
        let after = SummarizeNowReplies()
        await worker.enqueue(after.job)
        await worker.tick()
        #expect(after.results == [.failure(Self.stopped)])
        #expect(try w.session(Self.key).status == .open)
    }

    @Test("closeIdleSessions の段より後に入った分は pendingJobs の段で実行せず、次の tick で行う")
    func lateJobWaitsForTheNextTick() async throws {
        let (w, worker) = try await Self.openWorld()
        let replies = SummarizeNowReplies()
        await worker.enqueue(replies.job)
        await worker.stagePendingJobs(try await w.context())
        #expect(replies.results.isEmpty)
        #expect(await worker.pendingJobs.count == 1)
        #expect(try w.session(Self.key).status == .open)
        await worker.tick()
        #expect(replies.results == [.success(1)])
        #expect(try w.session(Self.key).status == .completed)
    }

    /// probe を gate で止めた Worker と、その Worker の停止フラグを共有する ctx。
    static func gatedWorker(_ w: PipelineWorld, _ gate: GateChatTransport) async throws -> (Worker, TickContext) {
        let worker = Worker(deps: w.deps(chat: gate), assertion: w.assertion, onStage: nil)
        guard let config = await w.configStore.current() else { throw PipelineFixtureError.noConfig }
        let ctx = await worker.makeContext(config, Worker.zone(for: config), snapshot: nil)
        return (worker, ctx)
    }

    /// 札の順に列を作り、probe の待ちの間に requestStop を呼ぶ。今すぐ要約の返事を返す。
    static func stopDuringProbe(summarizeFirst: Bool) async throws -> (SummarizeNowReplies, ReplyRecorder) {
        let (w, _) = try await Self.openWorld()
        let gate = GateChatTransport()
        let (worker, ctx) = try await Self.gatedWorker(w, gate)
        let replies = SummarizeNowReplies()
        let probe = ReplyRecorder()
        if summarizeFirst {
            await worker.enqueue(replies.job)
            await worker.enqueue(probe.job())
        } else {
            await worker.enqueue(probe.job())
            await worker.enqueue(replies.job)
        }
        let stage = Task { await worker.stagePendingJobs(ctx) }
        for _ in 0..<2000 where !gate.entered { await Task.yield() }
        #expect(gate.entered)
        await worker.requestStop()
        gate.release()
        await stage.value
        #expect(await worker.pendingJobs.isEmpty)
        #expect(try w.session(Self.key).status == .open)
        return (replies, probe)
    }

    @Test("列が [probe, 今すぐ要約] で probe の待ちの間に停止要求が来ても、停止の返事が 1 回だけ返る")
    func stopDuringProbeBeforeSummarize() async throws {
        let (replies, probe) = try await Self.stopDuringProbe(summarizeFirst: false)
        #expect(replies.results == [.failure(Self.stopped)])
        #expect(probe.results.count == 1)
    }

    @Test("列が [今すぐ要約, probe] で probe の待ちの間に停止要求が来ても、停止の返事が 1 回だけ返る")
    func stopDuringProbeAfterSummarize() async throws {
        let (replies, probe) = try await Self.stopDuringProbe(summarizeFirst: true)
        #expect(replies.results == [.failure(Self.stopped)])
        #expect(probe.results.count == 1)
    }

    @Test("pendingJobs の段で戻した分は、その間に入った分より前に行う（入れた順）")
    func deferredJobsKeepEnqueueOrder() async throws {
        let (w, _) = try await Self.openWorld()
        let gate = GateChatTransport()
        let (worker, ctx) = try await Self.gatedWorker(w, gate)
        let replies = TaggedSummarizeNowReplies()
        await worker.enqueue(replies.job(1))
        await worker.enqueue(ReplyRecorder().job())
        let stage = Task { await worker.stagePendingJobs(ctx) }
        for _ in 0..<2000 where !gate.entered { await Task.yield() }
        #expect(gate.entered)
        await worker.enqueue(replies.job(2))
        gate.release()
        await stage.value
        #expect(replies.tags.isEmpty)
        await worker.tick()
        #expect(replies.tags == [1, 2])
        #expect(replies.results == [.success(1), .success(0)])
    }

    @Test("allowReopen が false なら、閉じた後の同じ日の録音で要約し直さない")
    func noReopenWhenDisallowed() async throws {
        let (w, worker) = try await Self.openWorld { $0.session.allowReopen = false }
        let replies = SummarizeNowReplies()
        await worker.enqueue(replies.job)
        await worker.tick()
        #expect(try w.session(Self.key).status == .completed)
        let before = try w.sessionEvents(Self.key).count

        w.clock.set(Instant(epochMillis: Self.sameDayLater))
        let b = PipelineFixtures.partB
        let pkB = try w.registerPart(relpath: b.relpath, startedAt: b.startedAt, seconds: b.seconds)
        await worker.tick()

        // Raw には載る（RAW_SAVED）が、Session は再オープンしないので Daily は書き直さない
        #expect(try w.part(pkB).status == .rawSaved)
        let s = try w.session(Self.key)
        #expect(s.status == .completed)
        #expect(s.regeneratedCount == 0)
        #expect(try w.sessionEvents(Self.key).count == before)
        #expect(await w.chat.calls.count == 1)
    }
}
