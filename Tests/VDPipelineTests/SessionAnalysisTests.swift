// 解析のテスト（T-22 §6.5。PLAN §5.6「解析の再利用」「古い解析」・§8.5。voicedock test_session_analysis）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDLLM
import VDStore

@testable import VDPipeline

@Suite("SessionAnalysis", .timeLimit(.minutes(1)))
struct SessionAnalysisTests {
    static let key = PipelineFixtures.sessionKey
    static let slug = KeySlug.of(PipelineFixtures.sessionKey)
    /// 2026-09-12T09:00:00+09:00
    static let nine: Int64 = 1_789_171_200_000

    /// 09 時の 60 秒の Part（「おはようございます。」0〜3 秒）だけの統合結果の指紋（統合結果は仕様から手で組む）。
    static func nineFingerprint() throws -> String {
        let t = SessionTranscript(
            dayDate: try #require(LocalDate(year: 2026, month: 9, day: 12)),
            segments: [
                AbsoluteSegment(
                    at: Instant(epochMillis: nine), endAt: Instant(epochMillis: nine + 3000),
                    text: "おはようございます。")
            ],
            blocks: [TimeBlock(start: Instant(epochMillis: nine), end: Instant(epochMillis: nine + 60_000))],
            excludedPartkeys: [])
        return TranscriptFingerprint.of(t, zone: PipelineFixtures.zone)
    }

    /// installLLM 済みの世界（chat の既定は ANALYSIS を 1 回）。
    static func world(
        chat: FakeChatTransport = FakeChatTransport(responses: [.content(PipelineFixtures.analysis)]),
        llm: FakeLLMServer = FakeLLMServer(), install: Bool = true
    ) async throws -> PipelineWorld {
        let w = try await PipelineWorld.make(chat: chat, llm: llm)
        if install { try await w.installLLM() }
        return w
    }

    /// status の Session と 09 時の Part。
    static func world(status: SessionStatus, chat: [ChatResult] = [.content(PipelineFixtures.analysis)])
        async throws -> PipelineWorld
    {
        let w = try await Self.world(chat: FakeChatTransport(responses: chat))
        try w.addSession(status: status)
        try w.addSessionPart(hour: 9)
        return w
    }

    static func process(_ w: PipelineWorld) async throws -> SessionStepResult {
        await SessionSteps(ctx: try await w.context()).process(sessionKey: Self.key)
    }

    /// 今の DB から統合し ensureAnalysis。
    static func ensure(_ w: PipelineWorld, ctx: TickContext? = nil) async throws -> Bool {
        let c: TickContext
        if let ctx { c = ctx } else { c = try await w.context() }
        let steps = SessionSteps(ctx: c)
        let t = try #require(try steps.buildSessionTranscript(Self.key))
        return await steps.ensureAnalysis(Self.key, t)
    }

    static func analysisURL(_ w: PipelineWorld) -> URL { w.layout.analysisJSON(sessionSlug: slug) }
    static func sourceURL(_ w: PipelineWorld) -> URL { w.layout.sourceJSON(sessionSlug: slug) }

    static func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    /// 09:30 開始の RAW_SAVED の Part（「こんにちは。」）。10 時だと 09:00:00〜10:00:03 が
    /// maxSecondsPerRequest（3600）を超えて 2 チャンクになり、chat が Map 2 回 ＋ Reduce 1 回になる。
    static func addHalfPastNine(_ w: PipelineWorld) throws {
        try w.addTimedPart(
            time: "09:30:00", stamp: "093000", segments: [TranscriptSegment(start: 0.0, end: 3.0, text: "こんにちは。")])
    }

    // MARK: - 成功

    @Test("READY → ANALYZED（Daily は T-29）")
    func readySessionReachesAnalyzed() async throws {
        let w = try await Self.world(status: .ready)
        #expect(try await Self.process(w) == .analyzed)
        #expect(try w.sessionEvents().suffix(4).map(\.toStatus) == ["MERGING", "MERGED", "ANALYZING", "ANALYZED"])
        #expect(try Self.read(Self.analysisURL(w)) == Data(PipelineFixtures.analysisFile.utf8))
        let s = try w.session()
        #expect(s.analysisPath == "analysis/" + Self.slug + ".json")
        #expect(s.title == "開発の一日")
        #expect(s.errorCode == nil)
        #expect(
            w.lines("llm_completed").contains {
                $0.hasSuffix("llm_completed session_key=DJIMIC3:20260912 chunks=1 elapsed_s=0.0")
            })
    }

    @Test(".source.json の形")
    func sourceJSONIsExact() async throws {
        let w = try await Self.world(status: .ready)
        _ = try await Self.process(w)
        let fp = try Self.nineFingerprint()
        let expected =
            "{\n  \"schema\": 1,\n  \"transcript_sha256\": \"" + fp + "\",\n  \"segments\": 1,\n  \"blocks\": 1\n}\n"
        #expect(try Self.read(Self.sourceURL(w)) == Data(expected.utf8))
    }

    @Test("analyze のプロンプトと本文")
    func llmGetsTheTranscript() async throws {
        let w = try await Self.world(status: .ready)
        _ = try await Self.process(w)
        let calls = await w.chat.calls
        #expect(calls.count == 1)
        let config = try #require(await w.configStore.current())
        let schema = AnalysisSchema(config: AnalysisConfigView(sections: config.llm.analysis.sections), kind: .final)
        let prompts = try Prompts.load(directory: w.paths.promptsDirectory)
        #expect(calls.first?.system == prompts.analyze(schema: schema, custom: ""))
        #expect(calls.first?.user == "おはようございます。")
    }

    @Test("選んだモデルで llama-server を起動する")
    func serverIsStartedWithTheModel() async throws {
        let w = try await Self.world(status: .ready)
        _ = try await Self.process(w)
        let calls = await w.llm.ensureCalls
        let entry = try #require(TestCatalogs.minimal.entry(kind: .llm, id: "test-llm"))
        #expect(calls.count == 1)
        #expect(calls.first?.model == ModelFiles.url(kind: .llm, entry: entry, layout: w.layout))
        #expect(calls.first?.modelID == "test-llm")
    }

    // MARK: - 再利用

    @Test("★ 指紋が一致すれば LLM を呼ばず MERGED→ANALYZED")
    func validAnalysisIsReused() async throws {
        let w = try await Self.world(status: .merged)
        try w.writeAnalysis(fingerprint: try Self.nineFingerprint())
        #expect(try w.session().analysisPath == nil)
        _ = try await Self.process(w)
        #expect(await w.chat.calls.isEmpty)
        #expect(await w.llm.ensureCalls.isEmpty)
        let last = try w.sessionEvents().last
        #expect(last?.fromStatus == "MERGED")
        #expect(last?.toStatus == "ANALYZED")
        #expect(last?.detail == "analysis_reused")
        let s = try w.session()
        #expect(s.analysisPath == "analysis/" + Self.slug + ".json")
        #expect(s.title == "開発の一日")
    }

    @Test("ANALYZING からの再利用")
    func reuseFromAnalyzing() async throws {
        let w = try await Self.world(status: .analyzing)
        try w.writeAnalysis(fingerprint: try Self.nineFingerprint())
        _ = try await Self.process(w)
        let last = try w.sessionEvents().last
        #expect(last?.fromStatus == "ANALYZING")
        #expect(last?.toStatus == "ANALYZED")
        #expect(last?.detail == "analysis_reused")
    }

    @Test("指紋が無ければ作り直す")
    func missingFingerprintReanalyzes() async throws {
        let w = try await Self.world(status: .merged)
        try w.writeAnalysis(fingerprint: nil)
        _ = try await Self.process(w)
        #expect(await w.chat.calls.count == 1)
    }

    @Test("別の transcript の解析は作り直す")
    func differentTranscriptReanalyzes() async throws {
        let w = try await Self.world(status: .merged)
        try w.writeAnalysis(fingerprint: String(repeating: "b", count: 64))
        _ = try await Self.process(w)
        #expect(await w.chat.calls.count == 1)
    }

    @Test("壊れた解析は作り直す")
    func brokenAnalysisReanalyzes() async throws {
        let w = try await Self.world(status: .merged)
        try w.writeAnalysis(fingerprint: try Self.nineFingerprint())
        try AtomicFile.write(Data("{".utf8), to: Self.analysisURL(w))
        _ = try await Self.process(w)
        #expect(await w.chat.calls.count == 1)
    }

    // MARK: - 古い解析

    /// 09 時の Part で解析済み（status、正しいファイル）→ 09:30 の RAW_SAVED の Part を足す → ensureAnalysis。
    static func stale(from status: SessionStatus) async throws -> PipelineWorld {
        let w = try await Self.world(status: status)
        try w.writeAnalysis(fingerprint: try Self.nineFingerprint())
        try Self.addHalfPastNine(w)
        #expect(try await Self.ensure(w))
        return w
    }

    @Test("★ ANALYZED で指紋が違えば ANALYZED→ANALYZING（stale_analysis）")
    func staleAnalysisFromAnalyzed() async throws {
        let w = try await Self.stale(from: .analyzed)
        let events = try w.sessionEvents().suffix(2)
        #expect(events.map(\.fromStatus) == ["ANALYZED", "ANALYZING"])
        #expect(events.map(\.toStatus) == ["ANALYZING", "ANALYZED"])
        #expect(events.first?.detail == "stale_analysis")
        #expect(await w.chat.calls.count == 1)
        let source = try #require(PyJSON.decode(try Self.read(Self.sourceURL(w))))
        guard case .object(let fields) = source else {
            Issue.record("object でない")
            return
        }
        #expect(fields.first { $0.0 == "segments" }?.1 == .int(2))
    }

    @Test("★ WRITING でも同じ（WRITING→ANALYZING）")
    func staleAnalysisFromWriting() async throws {
        let w = try await Self.stale(from: .writing)
        let first = try w.sessionEvents().suffix(2).first
        #expect(first?.fromStatus == "WRITING")
        #expect(first?.toStatus == "ANALYZING")
        #expect(first?.detail == "stale_analysis")
    }

    @Test("ANALYZED で解析 JSON が読めなければ作り直す（FAILED にしない）")
    func brokenAnalysisInAnalyzedIsRedone() async throws {
        let w = try await Self.world(status: .analyzed)
        try w.writeAnalysis(fingerprint: try Self.nineFingerprint())
        try AtomicFile.write(Data("{".utf8), to: Self.analysisURL(w))
        _ = try await Self.ensure(w)
        #expect(try w.session().status == .analyzed)
        #expect(!(try w.sessionEvents().contains { $0.toStatus == "FAILED" }))
    }

    @Test("ANALYZED で一致すれば何もしない")
    func matchingAnalyzedIsKept() async throws {
        let w = try await Self.world(status: .analyzed)
        try w.writeAnalysis(fingerprint: try Self.nineFingerprint())
        let before = try w.sessionEvents().count
        #expect(try await Self.ensure(w))
        #expect(try w.sessionEvents().count == before)
        #expect(await w.chat.calls.isEmpty)
    }

    // MARK: - 失敗

    @Test("LLM の失敗は ANALYZING→FAILED")
    func llmFailureIsFailed() async throws {
        let w = try await Self.world(status: .ready, chat: [.failure(StageFailure(.llmUnavailable, "URLError -1004"))])
        _ = try await Self.process(w)
        let s = try w.session()
        #expect(s.status == .failed)
        #expect(s.errorCode == .llmUnavailable)
        #expect(s.errorMessage == "URLError -1004")
        #expect(
            w.lines("llm_failed").contains {
                $0.hasSuffix(
                    "llm_failed session_key=DJIMIC3:20260912 error_code=LLM_UNAVAILABLE detail=\"URLError -1004\"")
            })
        #expect(!PipelineFixtures.exists(Self.analysisURL(w)))
        #expect(!PipelineFixtures.exists(Self.sourceURL(w)))
    }

    @Test("直らない JSON は LLM_INVALID_JSON")
    func invalidJSONIsFailed() async throws {
        let bad = ChatResult.content(#"{"title":"t"}"#)
        let w = try await Self.world(status: .ready, chat: [bad, bad])
        _ = try await Self.process(w)
        let s = try w.session()
        #expect(s.status == .failed)
        #expect(s.errorCode == .llmInvalidJSON)
        #expect(s.errorMessage == "- summary: Field required")
    }

    @Test("起動の失敗は LLM_UNAVAILABLE")
    func serverStartFailureIsFailed() async throws {
        let w = try await Self.world(
            llm: FakeLLMServer(failure: StageFailure(.llmUnavailable, "server_start_failed: no_port")))
        try w.addSession(status: .ready)
        try w.addSessionPart(hour: 9)
        _ = try await Self.process(w)
        let s = try w.session()
        #expect(s.status == .failed)
        #expect(s.errorCode == .llmUnavailable)
        #expect(s.errorMessage == "server_start_failed: no_port")
        #expect(await w.chat.calls.isEmpty)
    }

    @Test("解析を書けなければ LLM_FAILED で指紋は書かない")
    func analysisWriteFailureLeavesNoFingerprint() async throws {
        let w = try await Self.world(status: .ready)
        // analysis.json の位置にディレクトリを置く（layout.analysis を 0o555 にすると同じディレクトリの .source.json も
        // 書けなくなり、.source.json を先に書く壊れ方が見えない）
        try FileManager.default.createDirectory(at: Self.analysisURL(w), withIntermediateDirectories: false)
        _ = try await Self.process(w)
        let s = try w.session()
        #expect(s.status == .failed)
        #expect(s.errorCode == .llmFailed)
        #expect(s.errorMessage?.hasPrefix("AtomicFileError: ") == true)
        #expect(!PipelineFixtures.exists(Self.sourceURL(w)))
    }

    @Test("指紋を書けなければ LLM_FAILED")
    func sourceWriteFailureIsLLMFailed() async throws {
        let analysis = ChatResult.content(PipelineFixtures.analysis)
        let w = try await Self.world(status: .ready, chat: [analysis, analysis])
        try FileManager.default.createDirectory(at: Self.sourceURL(w), withIntermediateDirectories: false)
        _ = try await Self.process(w)
        let s = try w.session()
        #expect(s.status == .failed)
        #expect(s.errorCode == .llmFailed)
        try w.store.recordSessionTransition(sessionKey: Self.key, from: .failed, to: .analyzing)
        _ = try await Self.ensure(w)
        #expect(await w.chat.calls.count == 2)
    }

    @Test("切り詰めを記録する")
    func trimmedIsLogged() async throws {
        let tags = (1...20).map { "\"t\($0)\"" }.joined(separator: ", ")
        let json = PipelineFixtures.analysis.replacingOccurrences(of: #"["VoiceDock"]"#, with: "[" + tags + "]")
        let w = try await Self.world(status: .ready, chat: [.content(json)])
        _ = try await Self.process(w)
        #expect(
            w.lines("analysis_trimmed").contains {
                $0.hasSuffix("analysis_trimmed session_key=DJIMIC3:20260912 fields=\"tags: 20 -> 15\"")
            })
    }

    // MARK: - 再オープン

    @Test("再オープン後は再解析")
    func reopenedSessionIsReanalyzed() async throws {
        let analysis = ChatResult.content(PipelineFixtures.analysis)
        let w = try await Self.world(status: .ready, chat: [analysis, analysis])
        #expect(try await Self.process(w) == .analyzed)
        try w.forceSession(Self.key, status: .saved)
        try Self.addHalfPastNine(w)
        #expect(SessionSteps(ctx: try await w.context()).reopenSession(Self.key))
        _ = try await Self.process(w)
        #expect(await w.chat.calls.count == 2)
    }

    @Test("新しい segment が無ければ再解析しない")
    func unchangedReopenIsReused() async throws {
        let w = try await Self.world(status: .ready)
        #expect(try await Self.process(w) == .analyzed)
        try w.forceSession(Self.key, status: .saved)
        try w.addSessionPart(hour: 10, status: .skipped)
        #expect(SessionSteps(ctx: try await w.context()).reopenSession(Self.key))
        _ = try await Self.process(w)
        #expect(await w.chat.calls.count == 1)
        #expect(try w.sessionEvents().last?.detail == "analysis_reused")
    }

    // MARK: - ガード

    @Test("ガードで止まれば遷移しない")
    func guardFailureDoesNotTransition() async throws {
        let w = try await Self.world(install: false)
        try w.addSession(status: .merged)
        try w.addSessionPart(hour: 9)
        #expect(try await Self.ensure(w) == false)
        #expect(try w.session().status == .merged)
        #expect(w.lines("pipeline_paused").contains { $0.hasSuffix("pipeline_paused reason=llm_not_selected") })
        #expect(await w.chat.calls.isEmpty)
    }

    @Test("古い解析もガードで待つ（遷移しない）")
    func staleWaitsOnGuard() async throws {
        let w = try await Self.world(status: .analyzed)
        try w.writeAnalysis(fingerprint: String(repeating: "b", count: 64))
        try FileManager.default.removeItem(at: w.paths.llamaServer)
        let ctx = try await w.context()
        #expect(try await Self.ensure(w, ctx: ctx) == false)
        #expect(try w.session().status == .analyzed)
        #expect(ctx.pauses.paused.contains(.llamaServerMissing))
        #expect(await w.chat.calls.isEmpty)  // ガードで止まれば LLM に触れない
        #expect(await w.llm.ensureCalls.isEmpty)
    }
}
