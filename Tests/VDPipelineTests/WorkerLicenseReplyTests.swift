// ライセンスで止めた tick が、待っているパネルの仕事に返事をすること（PLAN §5.4・§8.14。F-82・issue #119 の D8）。
import Foundation
import Synchronization
import TestSupport
import Testing
import VDContract
import VDCore
import VDStore

@testable import VDPipeline

@Suite("Worker（F-82 ライセンスで止めた tick の返事）", .serialized, .timeLimit(.minutes(1)))
struct WorkerLicenseReplyTests {
    /// 返事を貯める箱（返事は Worker の文脈で呼ばれる）。
    final class Replies: Sendable {
        let probe = Mutex<[DiagnosticResult]>([])
        let summarize = Mutex<[Result<Int, SummarizeNowFailure>]>([])
        let backlog = Mutex<[Result<BacklogPlan, BacklogFailure>]>([])
    }

    static func worker(_ w: PipelineWorld, recorder: StageRecorder) -> Worker {
        Worker(
            deps: w.deps(license: WorkerTests.DenyingLicenseGate()), assertion: w.assertion,
            onStage: { recorder.record($0) })
    }

    @Test("F-82 ライセンスで止めた tick は、待っている DR-09・今すぐ要約・後追いに「ライセンス」の失敗で 1 回ずつ返事をする")
    func licenseStoppedTickRepliesToPendingJobs() async throws {
        let w = try await PipelineWorld.make()
        let recorder = StageRecorder()
        let worker = Self.worker(w, recorder: recorder)
        let replies = Replies()
        await worker.enqueue(.llmProbe(reply: { r in replies.probe.withLock { $0.append(r) } }))
        await worker.enqueue(.summarizeNow(reply: { r in replies.summarize.withLock { $0.append(r) } }))
        await worker.enqueue(.backlog(.preview(reply: { r in replies.backlog.withLock { $0.append(r) } })))

        await worker.tick()
        await worker.tick()

        let probe = replies.probe.withLock { $0 }
        #expect(probe.count == 1)
        #expect(probe.first?.id == "DR-09")
        #expect(probe.first?.status == .fail)
        #expect(probe.first?.details == ["ライセンス"])
        #expect(replies.summarize.withLock { $0 } == [.failure(SummarizeNowFailure(message: "ライセンス"))])
        #expect(replies.backlog.withLock { $0 } == [.failure(BacklogFailure(message: "ライセンス"))])
        #expect(recorder.recorded.isEmpty)
        #expect(await worker.pendingJobs.isEmpty)
    }

    @Test("F-82 TEST-28 待っている仕事が 0 件でも、ライセンスで止めた tick は段を回さず理由だけを積む")
    func licenseStoppedTickWithoutJobs() async throws {
        let w = try await PipelineWorld.make()
        let recorder = StageRecorder()
        let worker = Self.worker(w, recorder: recorder)

        await worker.tick()

        #expect(recorder.recorded.isEmpty)
        #expect(await worker.status().paused == [.license])
        #expect(await worker.pendingJobs.isEmpty)
    }
}
