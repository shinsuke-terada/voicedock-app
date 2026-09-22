// 「戻りうる Session の状態すべてに受け手がいる」の不変条件（T-22 §6.8。SM-07。voicedock test_session_resume :125-165）。
import Foundation
import TestSupport
import Testing
import VDCore
import VDStore

@testable import VDPipeline

@Suite("SessionStateHandler", .timeLimit(.minutes(1)))
struct SessionStateHandlerTests {
    static let handled = SessionStates.mergeable.union(SessionStates.analyzable).union(SessionStates.writable)

    @Test("SM-07 Session の FAILED の戻り先に受け手がいる")
    func everyResumeTargetHasAHandler() {
        #expect(!SessionStates.retryableFromFailed.isEmpty)
        #expect(SessionStates.retryableFromFailed.isSubset(of: Self.handled))
    }

    @Test("SM-07 復旧の戻り先に受け手がいる")
    func recoveryTargetsHaveHandlers() {
        for s in [SessionStatus.ready, .merged, .analyzed] {
            #expect(SessionStates.processable.contains(s), "\(s)")
        }
        for s in [SessionStatus.saved, .sourceDeletePending] {
            #expect(SessionStates.deleteEvaluated.contains(s), "\(s)")
        }
    }

    @Test("再オープンの行き先は MERGING")
    func reopenTargetIsMergeable() {
        #expect(SessionStates.mergeable.contains(.merging))
        #expect(!SessionStates.reopenable.isEmpty)
        for s in SessionStates.reopenable {
            #expect(TransitionTable.session.contains(Edge(s, .merging)), "\(s)")
        }
    }

    @Test("ANALYZING から再開し MERGED→ANALYZING を書かない")
    func analyzingResumesWithoutPhantom() async throws {
        let w = try await PipelineWorld.make(
            chat: FakeChatTransport(responses: [.content(PipelineFixtures.analysis)]))
        try await w.installLLM()
        try w.addSession(status: .analyzing)
        try w.addSessionPart(hour: 9)
        _ = await SessionSteps(ctx: try await w.context()).process(sessionKey: PipelineFixtures.sessionKey)
        #expect(try w.session().status == .analyzed)
        #expect(!(try w.sessionEvents().contains { $0.fromStatus == "MERGED" && $0.toStatus == "ANALYZING" }))
    }
}
