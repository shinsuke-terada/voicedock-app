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
}
