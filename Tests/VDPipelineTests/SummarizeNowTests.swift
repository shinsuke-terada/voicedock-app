// 今すぐ要約（WorkerJob.summarizeNow）のテスト（PLAN §5.4・F-66）。Vault は TempDirectory の中だけ。
import Foundation
import Synchronization
import TestSupport
import Testing
import VDContract
import VDCore
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

@Suite("SummarizeNow", .serialized, .timeLimit(.minutes(1)))
struct SummarizeNowTests {
    static let key = PipelineFixtures.vaultSessionKey
    /// 2026-08-29T07:30:00+09:00（Part A の 07:12:04 と同じ日。idle の 1800 秒は経っていない）
    static let sameDayMorning: Int64 = 1_787_956_200_000
    /// 2026-08-29T07:50:00+09:00（Part B の 07:42:10 の後）
    static let sameDayLater: Int64 = 1_787_957_400_000
    static let stopped = SummarizeNowFailure(message: "終了中のため実行しませんでした")

    /// 時計は 2026-08-29T07:30:00+09:00。whisper・LLM・Vault を置き、Part A を登録して 1 tick 回す（Session は OPEN のまま）。
    static func openWorld(llm: Bool = true) async throws -> (PipelineWorld, Worker) {
        let w = try await PipelineWorld.make(
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

    @Test("今日の日付の OPEN だけを閉じる（設定のタイムゾーンの今日）")
    func closesOnlyTodaysOpenSessions() async throws {
        let w = try await PipelineWorld.make()
        try await w.installLLM()
        // 2026-08-28T23:30:00Z = 2026-08-29T08:30:00+09:00（UTC ではまだ 28 日）
        w.clock.set(Instant(epochMillis: 1_787_959_800_000))
        try w.store.insertSession(
            NewSession(sessionKey: "DJIMIC3:20260829", dayDate: "2026-08-29", deviceID: "DJIMIC3"))
        try w.store.insertSession(
            NewSession(sessionKey: "DJIMIC3:20260828", dayDate: "2026-08-28", deviceID: "DJIMIC3"))
        let closed = try SummarizeNow(ctx: try await w.context()).closeTodaySessions()
        #expect(closed == 1)
        #expect(try w.session("DJIMIC3:20260829").status == .ready)
        #expect(try w.session("DJIMIC3:20260828").status == .open)
        #expect(try w.sessionEvents("DJIMIC3:20260829").last?.detail == "summarize_now")
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
}
