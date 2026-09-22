// DR-09（LLM に実リクエストを 1 回）のテスト（T-32 §5.4）。llama-server は起動しない（FakeLLMServer）。
import Foundation
import TestSupport
import Testing
import VDCore
import VDLLM
import VDProcess

@testable import VDPipeline

@Suite("DR-09")
struct LLMProbeCheckTests {
    /// clock を差し替えた TickContext（それ以外は世界のもの）
    static func context(_ w: PipelineWorld, clock: any AppClock) async throws -> TickContext {
        let chat = w.chat
        let deps = WorkerDependencies(
            layout: w.layout, paths: w.paths, store: w.store, config: w.configStore, ingest: w.ingest,
            runner: ProcessRunner(), llama: w.llm, chatTransportFactory: { _, _ in chat }, clock: clock,
            sleeper: w.sleeper, log: w.log, license: AlwaysAllowLicenseGate(), catalog: TestCatalogs.minimal,
            physicalMemoryBytes: w.physicalMemoryBytes)
        guard let config = await w.configStore.current() else { throw PipelineFixtureError.noConfig }
        return TickContext(
            deps: deps, config: config, zone: Worker.zone(for: config), snapshot: nil, pauses: PauseBook(log: w.log),
            activity: ActivityBoard(assertion: w.assertion), stop: StopFlag())
    }

    @Test("DR-09 応答が返れば ok、経過秒を小数 1 桁で出す")
    func probeOK() async throws {
        let w = try await PipelineWorld.make(chat: FakeChatTransport(responses: [.content(#"{"ok": true}"#)]))
        try await w.installLLM()
        let clock = SteppingClock(start: Instant(epochMillis: 1_788_040_812_000), stepMilliseconds: 1500)
        let r = await LLMProbeCheck(ctx: try await Self.context(w, clock: clock)).run()
        #expect(r == DiagnosticResult(id: "DR-09", status: .ok, label: "LLM の疎通", details: ["test-llm（1.5s）"]))
    }

    @Test("DR-09 LLM が選ばれていなければ fail")
    func probeFailWhenNotSelected() async throws {
        let w = try await PipelineWorld.make { $0.llm.modelID = nil }
        let r = await LLMProbeCheck(ctx: try await w.context()).run()
        #expect(r.status == .fail)
        #expect(r.details == ["LLM モデルが選ばれていません"])
        #expect(await w.llm.ensureCalls.isEmpty)
    }

    @Test("DR-09 モデルのファイルが無ければガードと同じ語で fail")
    func probeFailWhenModelMissing() async throws {
        let w = try await PipelineWorld.make()
        try await w.installLLM()
        let model = w.layout.modelFile(kind: "llm", file: "test-llm.gguf")
        try FileManager.default.removeItem(at: model)
        let ctx = try await w.context()
        let r = await LLMProbeCheck(ctx: ctx).run()
        #expect(r.status == .fail)
        #expect(r.details == ["LLM モデルがありません"])
        #expect(await w.llm.ensureCalls.isEmpty)
        // 前回の tick の PauseBook には積まない（判定だけを借りる）
        #expect(ctx.pauses.paused.isEmpty)
        #expect(w.lines("pipeline_paused").isEmpty)
    }

    @Test("DR-09 ensureRunning が失敗すれば、その文言で fail")
    func probeFailWhenServerFails() async throws {
        let w = try await PipelineWorld.make(llm: FakeLLMServer(failure: StageFailure(.llmUnavailable, "起動できない")))
        try await w.installLLM()
        let r = await LLMProbeCheck(ctx: try await w.context()).run()
        #expect(r.status == .fail)
        #expect(r.details == ["起動できない"])
    }

    @Test("DR-09 complete が失敗すれば、その文言で fail")
    func probeFailWhenTransportFails() async throws {
        let w = try await PipelineWorld.make(
            chat: FakeChatTransport(responses: [.failure(StageFailure(.llmUnavailable, "HTTP 500"))]))
        try await w.installLLM()
        let r = await LLMProbeCheck(ctx: try await w.context()).run()
        #expect(r.status == .fail)
        #expect(r.details == ["HTTP 500"])
    }

    @Test("DR-09 成功しても llama-server を止めない（Worker が止める）")
    func probeDoesNotStopTheServer() async throws {
        let w = try await PipelineWorld.make(chat: FakeChatTransport(responses: [.content(#"{"ok": true}"#)]))
        try await w.installLLM()
        let r = await LLMProbeCheck(ctx: try await w.context()).run()
        #expect(r.status == .ok)
        #expect(await w.llm.stopCount == 0)
        #expect(await w.llm.ensureCalls.map(\.modelID) == ["test-llm"])
    }

    @Test("DR-09 疎通確認のプロンプトを送る")
    func probeUsesTheProbePrompts() async throws {
        let w = try await PipelineWorld.make(chat: FakeChatTransport(responses: [.content(#"{"ok": true}"#)]))
        try await w.installLLM()
        _ = await LLMProbeCheck(ctx: try await w.context()).run()
        let calls = await w.chat.calls
        #expect(calls.count == 1)
        #expect(calls.first?.system == "{\"ok\": true} と返してください。")
        #expect(calls.first?.user == "ping")
    }

    @Test("DR-09 応答の中身は見ない（JSON でなくても ok）")
    func probeIgnoresTheBody() async throws {
        let w = try await PipelineWorld.make(chat: FakeChatTransport(responses: [.content("にゃー")]))
        try await w.installLLM()
        let r = await LLMProbeCheck(ctx: try await w.context()).run()
        #expect(r.status == .ok)
    }
}
