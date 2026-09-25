// 要約プロンプトの上書き（llm.analysis.prompts）が Analyzer の system に効くこと（F-92）。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDLLM

@Suite("Analyzer の要約プロンプトの上書き（F-92）")
struct AnalyzerPromptOverrideTests {
    static func schemaBlock(_ name: String) throws -> String {
        String(decoding: try Golden.expectedBytes("llm_schema_block", name), as: UTF8.self)
    }

    /// Map は朝・夜、それ以外（analyze・reduce）は FINAL を返す（system を見ずに user で振り分ける）
    static func transport() -> FakeChatTransport {
        FakeChatTransport { call in
            switch call.user {
            case "朝の話": return AnalyzerHarness.partial("朝")
            case "夜の話": return AnalyzerHarness.partial("夜")
            default: return AnalyzerHarness.final()
            }
        }
    }

    static func run(
        _ segments: [AbsoluteSegment], prompts overrides: PromptOverrides, custom: String = ""
    ) async throws -> (outcome: AnalyzeOutcome, calls: [FakeChatTransport.Call]) {
        let transport = Self.transport()
        let config = AnalyzerHarness.config {
            $0.analysis.prompts = overrides
            $0.analysis.customInstructions = custom
        }
        let analyzer = Analyzer(transport: transport, prompts: try LLMFixtures.prompts(), config: config)
        let outcome = await analyzer.analyze(AnalyzerHarness.transcript(segments))
        return (outcome, await transport.calls)
    }

    static let oneChunk = [ChunkFixtures.seg("短い話", 0)]
    static let none = PromptOverrides(analyze: nil, map: nil, reduce: nil)

    @Test("CE llm.analysis.prompts.analyze が単一パスの system になる（差し込みは同梱と同じ順）")
    func ceAnalyzeOverride() async throws {
        let harness = try AnalyzerHarness()
        let overrides = PromptOverrides(analyze: "解析する。{custom_instructions}\n{schema_block}", map: nil, reduce: nil)
        let (outcome, calls) = try await Self.run(Self.oneChunk, prompts: overrides, custom: "短く。")
        #expect(calls.map(\.system) == ["解析する。短く。\n" + (try Self.schemaBlock("final_default"))])
        #expect(AnalyzerHarness.success(outcome) != nil)
        // null は同梱の本文のまま
        let (_, defaultCalls) = try await Self.run(Self.oneChunk, prompts: Self.none)
        #expect(defaultCalls.map(\.system) == [harness.analyzeSystem])
    }

    @Test("CE llm.analysis.prompts.map が Map の system になる（Reduce は同梱のまま）")
    func ceMapOverride() async throws {
        let harness = try AnalyzerHarness()
        let overrides = PromptOverrides(analyze: nil, map: "部分。{custom_instructions}\n{schema_block}", reduce: nil)
        let (outcome, calls) = try await Self.run(AnalyzerTests.twoChunks, prompts: overrides)
        let map = "部分。\n" + (try Self.schemaBlock("partial_default"))
        #expect(calls.map(\.system) == [map, map, harness.reduceSystem])
        #expect(AnalyzerHarness.success(outcome)?.partials.map(\.summary) == ["朝", "夜"])
    }

    @Test("CE llm.analysis.prompts.reduce が Reduce の system になる（Map は同梱のまま）")
    func ceReduceOverride() async throws {
        let harness = try AnalyzerHarness()
        let overrides = PromptOverrides(analyze: nil, map: nil, reduce: "まとめ。{custom_instructions}\n{schema_block}")
        let (outcome, calls) = try await Self.run(AnalyzerTests.twoChunks, prompts: overrides)
        let reduce = "まとめ。\n" + (try Self.schemaBlock("final_default"))
        #expect(calls.map(\.system) == [harness.mapSystem, harness.mapSystem, reduce])
        #expect(AnalyzerHarness.success(outcome) != nil)
    }

    @Test("map の上書きは多段 Reduce の束ね（中間の Map）にも効き、最後の Reduce は同梱のまま（PLAN §8.5。F-92）")
    func mapOverrideAppliesToFolding() async throws {
        let harness = try AnalyzerHarness()
        let config = AnalyzerHarness.config {
            $0.maxCharsPerRequest = 150
            $0.chunkOverlapChars = 0
            $0.analysis.prompts = PromptOverrides(
                analyze: nil, map: "部分。{custom_instructions}\n{schema_block}", reduce: nil)
        }
        // 3 チャンク（100 文字ずつ）→ 中間結果 3 個は 150 文字に収まらないので 2 束に畳む（AnalyzerTests と同じ形）
        let segs = [
            ChunkFixtures.seg(String(repeating: "a", count: 100), 0),
            ChunkFixtures.seg(String(repeating: "b", count: 100), 10),
            ChunkFixtures.seg(String(repeating: "c", count: 100), 20),
        ]
        let transport = FakeChatTransport { call in
            if call.user.contains("\"f1\"") { return AnalyzerHarness.final() }
            if call.user.hasPrefix("[") {
                return call.user.contains("\"s1\"") ? AnalyzerHarness.partial("f1") : AnalyzerHarness.partial("f2")
            }
            switch call.user.first {
            case "a": return AnalyzerHarness.partial("s1")
            case "b": return AnalyzerHarness.partial("s2")
            case "c": return AnalyzerHarness.partial("s3")
            default: return AnalyzerHarness.unexpected
            }
        }
        let analyzer = Analyzer(transport: transport, prompts: try LLMFixtures.prompts(), config: config)
        let outcome = await analyzer.analyze(AnalyzerHarness.transcript(segs))
        let calls = await transport.calls
        let map = "部分。\n" + (try Self.schemaBlock("partial_default"))
        try #require(calls.count == 6)
        // 0〜2 はチャンクの Map、3〜4 は中間結果の束の Map（どちらも上書き）、5 は最後の Reduce（同梱）
        #expect(calls.map(\.system) == [map, map, map, map, map, harness.reduceSystem])
        #expect(calls[3].user.hasPrefix("["))
        #expect(calls[4].user.hasPrefix("["))
        #expect(AnalyzerHarness.success(outcome) != nil)
    }

    @Test("上書きが全部 null なら 3 つとも同梱の本文（TEST-28）")
    func noOverridesKeepBundled() async throws {
        let harness = try AnalyzerHarness()
        let (_, calls) = try await Self.run(AnalyzerTests.twoChunks, prompts: Self.none)
        #expect(calls.map(\.system) == [harness.mapSystem, harness.mapSystem, harness.reduceSystem])
    }
}
