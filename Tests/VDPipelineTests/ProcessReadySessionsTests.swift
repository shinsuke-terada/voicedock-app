// processReadySessions のテスト（T-22 §6.7。PLAN §5.4。voicedock worker.py:326-340, 391-412 / test_session_resume）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDLLM
import VDStore

@testable import VDPipeline

@Suite("ProcessReadySessions", .serialized, .timeLimit(.minutes(1)))
struct ProcessReadySessionsTests {
    static let key = PipelineFixtures.sessionKey

    /// 常に ANALYSIS を返す chat
    static func alwaysAnalysis() -> FakeChatTransport {
        FakeChatTransport { _ in .content(PipelineFixtures.analysis) }
    }

    static func world(chat: FakeChatTransport = alwaysAnalysis()) async throws -> PipelineWorld {
        let w = try await PipelineWorld.make(chat: chat)
        try await w.installLLM()
        return w
    }

    static func run(_ w: PipelineWorld, ctx: TickContext? = nil) async throws {
        let c: TickContext
        if let ctx { c = ctx } else { c = try await w.context() }
        await w.worker().stageProcessReadySessions(c)
    }

    /// sleeper を差し替えた TickContext（工程内リトライが止まらない壊れ方でも終わるよう上限つき）。
    static func context(_ w: PipelineWorld, sleeper: any Sleeper) async throws -> TickContext {
        guard let config = await w.configStore.current() else { throw PipelineFixtureError.noConfig }
        return TickContext(
            deps: w.deps(sleeper: sleeper), config: config, zone: PipelineFixtures.zone, snapshot: nil,
            pauses: PauseBook(log: w.log), activity: ActivityBoard(assertion: RecordingSleepAssertion()),
            stop: StopFlag(), undeletableStreaks: UndeletableStreaks())
    }

    @Test("Part が全部終端でなければ処理しない")
    func needsEveryPartTerminal() async throws {
        let w = try await Self.world()
        try w.addSession(status: .ready)
        try w.addSessionPart(hour: 9, status: .rawSaved)
        try w.addSessionPart(hour: 10, status: .transcribed)
        try await Self.run(w)
        #expect(try w.session().status == .ready)
    }

    @Test("FAILED を含んでも全部終端なら処理する")
    func terminalMixIsReady() async throws {
        let w = try await Self.world()
        try w.addSession(status: .ready)
        try w.addSessionPart(hour: 9, status: .rawSaved)
        try w.addSessionPart(hour: 10, status: .failed)
        try await Self.run(w)
        #expect(try w.session().status == .analyzed)
    }

    @Test("Part 0 件は対象外")
    func sessionWithoutPartsIsNotReady() async throws {
        let w = try await Self.world()
        try w.addSession(status: .ready)
        try await Self.run(w)
        #expect(try w.session().status == .ready)
    }

    @Test("processable の 6 状態を全部拾う")
    func scansEveryProcessableState() async throws {
        let w = try await Self.world()
        let states: [SessionStatus] = [.ready, .merging, .merged, .analyzing, .analyzed, .writing]
        var keys: [String] = []
        for (i, status) in states.enumerated() {
            let day = String(format: "202609%02d", i + 1)
            let key = "DJIMIC3:" + day
            try w.addSession(key: key, day: String(format: "2026-09-%02d", i + 1), status: status)
            try w.addSessionPart(hour: 9, sessionKey: key, day: day)
            keys.append(key)
        }
        try await Self.run(w)
        for key in keys {
            #expect(try w.session(key).status == .analyzed, "\(key)")
        }
    }

    @Test("processable 以外は触らない")
    func ignoresOtherStates() async throws {
        let w = try await Self.world()
        let states: [SessionStatus] = [.open, .saved, .completed, .failed]
        for (i, status) in states.enumerated() {
            let day = String(format: "202609%02d", i + 1)
            try w.addSession(key: "DJIMIC3:" + day, day: String(format: "2026-09-%02d", i + 1), status: status)
            try w.addSessionPart(hour: 9, sessionKey: "DJIMIC3:" + day, day: day)
        }
        try await Self.run(w)
        for (i, status) in states.enumerated() {
            #expect(try w.session(String(format: "DJIMIC3:202609%02d", i + 1)).status == status)
        }
    }

    @Test("処理順は session_key 昇順")
    func orderIsBySessionKey() async throws {
        let w = try await Self.world()
        try w.addSession(key: "DJIMIC3:20260913", day: "2026-09-13", status: .ready)
        try w.addSessionPart(hour: 9, sessionKey: "DJIMIC3:20260913", day: "20260913")
        try w.addSession(key: "DJIMIC3:20260912", day: "2026-09-12", status: .merged)
        try w.addSessionPart(hour: 9, sessionKey: "DJIMIC3:20260912", day: "20260912")
        let baseline = (try w.sessionEvents("DJIMIC3:20260912") + w.sessionEvents("DJIMIC3:20260913")).map(\.id).max()
        let mark = try #require(baseline)
        try await Self.run(w)
        let first12 = try #require(try w.sessionEvents("DJIMIC3:20260912").first { $0.id > mark })
        let first13 = try #require(try w.sessionEvents("DJIMIC3:20260913").first { $0.id > mark })
        #expect(first12.id < first13.id)
    }

    enum StopCase: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case oneTarget, noTarget, stopDuringFirst
        var testDescription: String { rawValue }
    }

    @Test("終わりで必ず llama-server を止める", arguments: StopCase.allCases)
    func serverIsAlwaysStopped(_ c: StopCase) async throws {
        let flag = StopFlag()
        let chat = FakeChatTransport { _ in
            if c == .stopDuringFirst { flag.set() }
            return .content(PipelineFixtures.analysis)
        }
        let w = try await Self.world(chat: chat)
        switch c {
        case .oneTarget:
            try w.addSession(status: .ready)
            try w.addSessionPart(hour: 9)
        case .noTarget:
            break
        case .stopDuringFirst:
            try w.addSession(key: "DJIMIC3:20260912", day: "2026-09-12", status: .ready)
            try w.addSessionPart(hour: 9, sessionKey: "DJIMIC3:20260912", day: "20260912")
            try w.addSession(key: "DJIMIC3:20260913", day: "2026-09-13", status: .ready)
            try w.addSessionPart(hour: 9, sessionKey: "DJIMIC3:20260913", day: "20260913")
        }
        try await Self.run(w, ctx: try await w.context(stop: flag))
        #expect(await w.llm.stopCount == 1)
        if c == .stopDuringFirst {
            #expect(try w.session("DJIMIC3:20260912").status == .analyzed)  // 1 件目は最後まで処理した
            #expect(try w.session("DJIMIC3:20260913").status == .ready)
        }
    }

    @Test("解析の失敗は工程内で 3 回（毎回やり直す）")
    func sessionIsRetriedInProcess() async throws {
        let chat = FakeChatTransport { _ in .failure(StageFailure(.llmUnavailable, "URLError -1004")) }
        let w = try await Self.world(chat: chat)
        try w.addSession(status: .ready)
        try w.addSessionPart(hour: 9)
        let sleeper = LimitedSleeper(limit: 10)
        try await Self.run(w, ctx: try await Self.context(w, sleeper: sleeper))
        let s = try w.session()
        #expect(s.status == .failed)
        #expect(s.retryCount == 3)
        #expect(sleeper.recorded == [3, 10])
        #expect(await chat.calls.count == 3)
    }

    @Test("LLM_INVALID_JSON は工程内で回さない")
    func invalidJSONIsNotRetriedInProcess() async throws {
        let chat = FakeChatTransport { _ in .content(#"{"title":"t"}"#) }
        let w = try await Self.world(chat: chat)
        try w.addSession(status: .ready)
        try w.addSessionPart(hour: 9)
        let sleeper = LimitedSleeper(limit: 10)
        try await Self.run(w, ctx: try await Self.context(w, sleeper: sleeper))
        #expect(await chat.calls.count == 2)
        #expect(sleeper.recorded.isEmpty)
    }
}
