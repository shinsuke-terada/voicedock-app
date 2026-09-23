// アプリの終了で止めた LLM を解析の失敗として記録しないこと（PLAN §8.5・§8.15。F-82・issue #119）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDLLM
import VDStore

@testable import VDPipeline

@Suite("SessionAnalysis（F-82 終了で止めた LLM）", .timeLimit(.minutes(1)))
struct SessionAnalysisStoppedTests {
    static let key = PipelineFixtures.sessionKey

    /// 失敗の作り方（起動の中止か、止められたサーバとの通信の失敗）。
    enum Failure: String, CaseIterable, Sendable {
        case startCancelled
        case connectionLost

        var message: String {
            switch self {
            case .startCancelled: "server_start_failed: cancelled"
            case .connectionLost: "URLError -1004"
            }
        }
    }

    /// READY の Session と 09 時の Part。失敗は llama の起動か chat の応答に仕込む。
    static func world(_ failure: Failure) async throws -> PipelineWorld {
        let stage = StageFailure(.llmUnavailable, failure.message)
        let w: PipelineWorld
        switch failure {
        case .startCancelled:
            w = try await SessionAnalysisTests.world(llm: FakeLLMServer(failure: stage))
        case .connectionLost:
            w = try await SessionAnalysisTests.world(chat: FakeChatTransport(responses: [.failure(stage)]))
        }
        try w.addSession(status: .ready)
        try w.addSessionPart(hour: 9)
        return w
    }

    /// 停止要求を立てた（か立てない）文脈で Session の工程を 1 回。
    static func process(_ w: PipelineWorld, stopRequested: Bool) async throws -> TickContext {
        let stop = StopFlag()
        if stopRequested { stop.set() }
        let ctx = try await w.context(stop: stop)
        _ = await SessionSteps(ctx: ctx).process(sessionKey: Self.key)
        return ctx
    }

    @Test(
        "F-82 停止要求の下での起動の中止（server_start_failed: cancelled）と通信の失敗は Session を FAILED にせず ANALYZING のまま（retry_count・llm_failed を書かない）",
        arguments: Failure.allCases)
    func stoppedFailureLeavesAnalyzing(_ failure: Failure) async throws {
        let w = try await Self.world(failure)

        let ctx = try await Self.process(w, stopRequested: true)

        let s = try w.session()
        #expect(s.status == .analyzing)
        #expect(s.retryCount == 0)
        #expect(s.errorCode == nil)
        #expect(s.errorMessage == nil)
        #expect(w.lines("llm_failed").isEmpty)
        #expect(try w.sessionEvents().last?.toStatus == "ANALYZING")
        // 次回起動時の復旧が戻す（PLAN §5.3）
        _ = try Recovery(store: w.store, layout: w.layout, log: w.log, config: ctx.config, zone: ctx.zone).run()
        #expect(try w.session().status == .merged)
    }

    @Test(
        "F-82 停止要求が無ければ、起動の失敗も通信の失敗も従来どおり ANALYZING→FAILED（LLM_UNAVAILABLE・retry_count 1）",
        arguments: Failure.allCases)
    func unstoppedFailureIsFailed(_ failure: Failure) async throws {
        let w = try await Self.world(failure)

        _ = try await Self.process(w, stopRequested: false)

        let s = try w.session()
        #expect(s.status == .failed)
        #expect(s.retryCount == 1)
        #expect(s.errorCode == .llmUnavailable)
        #expect(s.errorMessage == failure.message)
        #expect(
            w.lines("llm_failed").contains {
                $0.hasSuffix(
                    "llm_failed session_key=DJIMIC3:20260912 error_code=LLM_UNAVAILABLE detail=\"\(failure.message)\"")
            })
    }
}
