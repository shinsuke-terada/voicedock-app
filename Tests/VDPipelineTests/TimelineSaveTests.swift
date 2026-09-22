// Timeline の保存のテスト（T-29 §6.3。PLAN §8.5「成功時の書き込み」2・§8.6 Timeline）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDLLM
import VDStore

@testable import VDPipeline

@Suite("TimelineSave", .serialized, .timeLimit(.minutes(1)))
struct TimelineSaveTests {
    static let key = PipelineFixtures.vaultSessionKey
    static let slug = KeySlug.of(PipelineFixtures.vaultSessionKey)
    /// 2026-08-29T07:12:04+09:00
    static let partAStart: Int64 = 1_787_955_124_000

    /// Part A だけの統合結果の指紋（統合結果は仕様から手で組む: segment 0.0〜3.2・5.5〜9.0、Block は started_at〜ended_at）。
    static func partAFingerprint() throws -> String {
        let s = partAStart
        let t = SessionTranscript(
            dayDate: try #require(LocalDate(year: 2026, month: 8, day: 29)),
            segments: [
                AbsoluteSegment(
                    at: Instant(epochMillis: s), endAt: Instant(epochMillis: s + 3200), text: "おはようございます。"),
                AbsoluteSegment(
                    at: Instant(epochMillis: s + 5500), endAt: Instant(epochMillis: s + 9000), text: "今日の予定を確認します。"),
            ],
            blocks: [TimeBlock(start: Instant(epochMillis: s), end: Instant(epochMillis: s + 2000))],
            excludedPartkeys: [])
        return TranscriptFingerprint.of(t, zone: PipelineFixtures.zone)
    }

    /// installLLM・MERGED の Session・RAW_SAVED の Part（parts の順）。
    static func world(chat: [ChatResult], parts: [PipelineFixtures.PartSpec] = [PipelineFixtures.partA])
        async throws -> PipelineWorld
    {
        let w = try await PipelineWorld.make(chat: FakeChatTransport(responses: chat))
        try await w.installLLM()
        try w.addSession(key: key, day: "2026-08-29", status: .merged)
        for p in parts { try w.addPart(p, status: .rawSaved) }
        return w
    }

    static func analyze(_ w: PipelineWorld) async throws -> Bool {
        let steps = SessionSteps(ctx: try await w.context())
        let t = try #require(try steps.buildSessionTranscript(key))
        return await steps.ensureAnalysis(key, t)
    }

    static func timeline(_ w: PipelineWorld) throws -> String {
        let data = try Data(contentsOf: w.layout.timelineJSON(sessionSlug: slug))
        return String(decoding: data, as: UTF8.self)
    }

    @Test("単一パスは summary の文を Block ごとに")
    func singlePassTimelineIsSaved() async throws {
        let w = try await Self.world(chat: [.content(PipelineFixtures.analysis)])
        #expect(try await Self.analyze(w))
        let fp = try Self.partAFingerprint()
        let expected =
            "{\n  \"schema\": 2,\n  \"transcript_sha256\": \"" + fp + "\",\n  \"blocks\": [\n    {\n"
            + "      \"start_at\": \"2026-08-29T07:12:04+09:00\",\n      \"end_at\": \"2026-08-29T07:12:06+09:00\",\n"
            + "      \"lines\": [\n        \"削除条件を整理した。\"\n      ]\n    }\n  ]\n}\n"
        #expect(try Self.timeline(w) == expected)
    }

    @Test("Map-Reduce は Map の結果とチャンクの時刻")
    func mapReduceTimelineUsesPartials() async throws {
        let w = try await Self.world(
            chat: [
                .content(#"{"summary":"朝","key_points":["朝の要点"]}"#), .content(#"{"summary":"昼","key_points":[]}"#),
                .content(PipelineFixtures.analysis),
            ],
            parts: [PipelineFixtures.partA, PipelineFixtures.partC])
        #expect(try await Self.analyze(w))
        #expect(await w.chat.calls.count == 3)
        let blocks =
            "  \"blocks\": [\n    {\n"
            + "      \"start_at\": \"2026-08-29T07:12:04+09:00\",\n      \"end_at\": \"2026-08-29T07:12:13+09:00\",\n"
            + "      \"lines\": [\n        \"朝の要点\"\n      ]\n    },\n    {\n"
            + "      \"start_at\": \"2026-08-29T09:30:00+09:00\",\n      \"end_at\": \"2026-08-29T09:30:09+09:00\",\n"
            + "      \"lines\": [\n        \"昼\"\n      ]\n    }\n  ]\n}\n"
        let text = try Self.timeline(w)
        #expect(text.hasPrefix("{\n  \"schema\": 2,\n  \"transcript_sha256\": \""))
        #expect(text.hasSuffix(blocks))
    }

    @Test("Timeline を書けなくても解析は成功")
    func timelineWriteFailureIsNotFatal() async throws {
        let w = try await Self.world(chat: [.content(PipelineFixtures.analysis)])
        try FileManager.default.createDirectory(
            at: w.layout.timelineJSON(sessionSlug: Self.slug), withIntermediateDirectories: true)
        #expect(try await Self.analyze(w))
        #expect(try w.session(Self.key).status == .analyzed)
        #expect(w.lines("config_warning").contains { $0.contains("config_warning rule=timeline message=") })
    }
}
