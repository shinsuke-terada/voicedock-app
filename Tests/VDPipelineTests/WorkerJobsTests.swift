// Worker の仕事（enqueue と stagePendingJobs）のテスト（T-32 §5.5）。
import Foundation
import Synchronization
import TestSupport
import Testing
import VDCore

@testable import VDPipeline

/// 返事を順に覚える。
final class ReplyRecorder: Sendable {
    private let replies = Mutex<[(tag: Int, result: DiagnosticResult)]>([])

    func job(_ tag: Int = 0) -> WorkerJob {
        .llmProbe(reply: { r in self.replies.withLock { $0.append((tag, r)) } })
    }

    var results: [DiagnosticResult] { replies.withLock { $0.map(\.result) } }
    var tags: [Int] { replies.withLock { $0.map(\.tag) } }
}

@Suite("Worker の仕事")
struct WorkerJobsTests {
    @Test("DR-09 enqueue した疎通確認は tick で 1 回返事をする")
    func probeRunsAsAJob() async throws {
        let w = try await PipelineWorld.make(chat: FakeChatTransport(responses: [.content("ok")]))
        try await w.installLLM()
        let worker = w.worker()
        let recorder = ReplyRecorder()
        await worker.enqueue(recorder.job())
        await worker.tick()
        #expect(recorder.results.map(\.id) == ["DR-09"])
        #expect(recorder.results.first?.status == .ok)
    }

    @Test("仕事は tick をまたいで 1 回だけ")
    func jobRunsOnceAcrossTicks() async throws {
        let w = try await PipelineWorld.make(chat: FakeChatTransport(responses: [.content("ok"), .content("ok")]))
        try await w.installLLM()
        let worker = w.worker()
        let recorder = ReplyRecorder()
        await worker.enqueue(recorder.job())
        await worker.tick()
        await worker.tick()
        #expect(recorder.results.count == 1)
        #expect(await w.llm.ensureCalls.count == 1)
    }

    @Test("入れた順に実行する")
    func jobsRunInOrder() async throws {
        let w = try await PipelineWorld.make(
            chat: FakeChatTransport(responses: [.content("ok"), .content("ok"), .content("ok")]))
        try await w.installLLM()
        let worker = w.worker()
        let recorder = ReplyRecorder()
        await worker.enqueue(recorder.job(1))
        await worker.enqueue(recorder.job(2))
        await worker.enqueue(recorder.job(3))
        await worker.tick()
        #expect(recorder.tags == [1, 2, 3])
    }

    @Test("停止要求の後も返事は必ず返る（.skip）")
    func stopRepliesWithSkip() async throws {
        let w = try await PipelineWorld.make(chat: FakeChatTransport(responses: [.content("ok")]))
        try await w.installLLM()
        let expected = DiagnosticResult(
            id: "DR-09", status: .skip, label: "LLM の疎通", details: ["終了中のため実行しませんでした"])
        // 段の途中で停止要求が立ったとき（stagePendingJobs が ctx.stop を見る）
        let worker = w.worker()
        let inStage = ReplyRecorder()
        await worker.enqueue(inStage.job())
        let stopped = StopFlag()
        stopped.set()
        await worker.stagePendingJobs(try await w.context(stop: stopped))
        #expect(inStage.results == [expected])
        // enqueue → requestStop（tick を回さない）: 列に残っていた仕事にも返事が返る
        let other = w.worker()
        let queued = ReplyRecorder()
        await other.enqueue(queued.job())
        await other.requestStop()
        #expect(queued.results == [expected])
        #expect(await other.pendingJobs.isEmpty)
        // requestStop() の後に enqueue → tick
        let after = ReplyRecorder()
        await worker.requestStop()
        await worker.enqueue(after.job())
        await worker.tick()
        #expect(after.results == [expected])
        #expect(await w.llm.ensureCalls.isEmpty)
    }

    @Test("DR-09 設定エラー中の enqueue → tick は fail で返事をする")
    func configErrorRepliesWithFail() async throws {
        let w = try await PipelineWorld.make(chat: FakeChatTransport(responses: [.content("ok")]))
        try await w.installLLM()
        let worker = w.worker()
        // 設定ファイルを壊して読み直す（設定エラー状態。PLAN §6.1）
        try Data("{".utf8).write(to: w.layout.configFile)
        _ = await w.configStore.load()
        #expect(await w.configStore.current() == nil)
        let recorder = ReplyRecorder()
        await worker.enqueue(recorder.job())
        await worker.tick()
        #expect(
            recorder.results == [
                DiagnosticResult(id: "DR-09", status: .fail, label: "LLM の疎通", details: ["設定が読めていません"])
            ])
        #expect(await worker.pendingJobs.isEmpty)
        #expect(await w.llm.ensureCalls.isEmpty)
    }

    @Test("run() 中の enqueue は 30 秒を待たずに tick を回す")
    func enqueueWakesTheLoop() async throws {
        let w = try await PipelineWorld.make(chat: FakeChatTransport(responses: [.content("ok")]))
        try await w.installLLM()
        let recorder = StageRecorder()
        let worker = Worker(
            deps: w.deps(sleeper: SuspendingSleeper()), assertion: w.assertion, onStage: { recorder.record($0) })
        let finished = Mutex<Bool>(false)
        let task = Task {
            await worker.run()
            finished.withLock { $0 = true }
        }
        defer { task.cancel() }
        try await waitUntil("1 回目の tick") { recorder.count(.pendingJobs) == 1 }
        let replies = ReplyRecorder()
        await worker.enqueue(replies.job())
        try await waitUntil("返事") { replies.results.count == 1 }
        #expect(recorder.count(.pendingJobs) == 2)
        await worker.requestStop()
        try await waitUntil("run の終わり") { finished.withLock { $0 } }
    }

    @Test("TEST-28 仕事が 0 件なら返事も LLM の呼び出しも無い")
    func noJobsIsCheap() async throws {
        let w = try await PipelineWorld.make()
        try await w.installLLM()
        let worker = w.worker()
        await worker.tick()
        #expect(await w.llm.ensureCalls.isEmpty)
        #expect(await w.chat.calls.isEmpty)
        #expect(await worker.pendingJobs.isEmpty)
    }
}
