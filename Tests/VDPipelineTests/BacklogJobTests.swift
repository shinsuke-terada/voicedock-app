// 後追いを Worker の仕事として回す（PLAN §8.9.9「実行は Worker の直列ループに 1 件の仕事として入れる」。T-41 §6.2）。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDPipeline

@Suite("後追いの仕事", .serialized)
struct BacklogJobTests {
    @Test("Worker の直列ループで 1 件の仕事として実行する")
    func workerRunsBacklogPreviewAsAJob() async throws {
        let w = try await PipelineWorld.make()
        let worker = w.worker()
        let replies = BacklogReplies<BacklogPlan>()
        await worker.enqueue(.backlog(.preview(reply: replies.reply)))
        await worker.tick()
        // COMPLETED の Session が無い
        #expect(replies.results == [.success(BacklogPlan(eligible: [], skipped: []))])
    }

    @Test("手動で消した分も同じ")
    func workerRunsResolveAbsentAsAJob() async throws {
        let w = try await PipelineWorld.make()
        let worker = w.worker()
        let replies = BacklogReplies<BacklogPlan>()
        await worker.enqueue(.resolveAbsent(.preview(reply: replies.reply)))
        await worker.tick()
        #expect(replies.results.count == 1)
        let first = try #require(replies.results.first)
        #expect((try? first.get()) != nil)
    }

    @Test("仕事は 1 回だけ実行される")
    func jobRunsOnceAcrossTicks() async throws {
        let w = try await PipelineWorld.make()
        let worker = w.worker()
        let replies = BacklogReplies<BacklogPlan>()
        await worker.enqueue(.backlog(.preview(reply: replies.reply)))
        await worker.tick()
        await worker.tick()
        #expect(replies.results.count == 1)
    }

    static let stopped = BacklogFailure(message: "終了中のため実行しませんでした")
    static let unavailable = BacklogFailure(message: "設定が読めていません")

    @Test(
        "停止要求が立っていれば後追いを実行せず、失敗で 1 回返事をする（パラメータ化: 過去分・手動で消した分）",
        arguments: [BacklogKind.backlog, .resolveAbsent])
    func stopRequestedRepliesWithFailure(_ kind: BacklogKind) async throws {
        let w = try await PipelineWorld.make()
        let worker = w.worker()
        let replies = BacklogReplies<BacklogPlan>()
        let action = BacklogAction.preview(reply: replies.reply)
        await worker.enqueue(kind == .backlog ? .backlog(action) : .resolveAbsent(action))
        let stop = StopFlag()
        stop.set()
        await worker.stagePendingJobs(try await w.context(stop: stop))
        #expect(replies.results == [.failure(Self.stopped)])
    }

    @Test("設定エラー中の tick は後追いに失敗で 1 回返事をする")
    func configErrorRepliesWithFailure() async throws {
        let w = try await PipelineWorld.make()
        let worker = w.worker()
        try Data("{".utf8).write(to: w.layout.configFile)
        _ = await w.configStore.load()
        #expect(await w.configStore.current() == nil)
        let preview = BacklogReplies<BacklogPlan>()
        let execute = BacklogReplies<BacklogExecution>()
        await worker.enqueue(.backlog(.preview(reply: preview.reply)))
        await worker.enqueue(
            .resolveAbsent(.execute(preview: BacklogPlan(eligible: [], skipped: []), reply: execute.reply)))
        await worker.tick()
        await worker.tick()
        #expect(preview.results == [.failure(Self.unavailable)])
        #expect(execute.results == [.failure(Self.unavailable)])
        #expect(await worker.pendingJobs.isEmpty)
    }

    @Test("停止要求の前後に入れた後追いにも失敗で 1 回返事をする")
    func requestStopRepliesWithFailure() async throws {
        let w = try await PipelineWorld.make()
        let worker = w.worker()
        let queued = BacklogReplies<BacklogExecution>()
        await worker.enqueue(.backlog(.execute(preview: BacklogPlan(eligible: [], skipped: []), reply: queued.reply)))
        await worker.requestStop()
        let after = BacklogReplies<BacklogPlan>()
        await worker.enqueue(.resolveAbsent(.preview(reply: after.reply)))
        await worker.tick()
        #expect(queued.results == [.failure(Self.stopped)])
        #expect(after.results == [.failure(Self.stopped)])
    }
}
