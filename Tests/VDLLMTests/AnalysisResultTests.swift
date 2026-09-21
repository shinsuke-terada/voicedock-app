// AnalysisResult.pyJSON が voicedock の model_dump（analysis.json）と同じ形になること（PLAN §8.5、T-19）。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDLLM

@Suite("AnalysisResult")
struct AnalysisResultTests {
    static func validated(_ json: String, _ schema: AnalysisSchema) throws -> AnalysisResult {
        try AnalysisValidator.validate(try LLMFixtures.object(json), schema: schema).get()
    }

    @Test("analysis.json の形が voicedock と一致")
    func analysisJSONMatchesVoicedock() throws {
        let schema = LLMFixtures.schema(.final)
        let result = try Self.validated(
            #"{"title":"t","summary":"s","tasks":[{"text":"x","due":"2026-09-20"}]}"#, schema)
        let expected =
            "{\n  \"title\": \"t\",\n  \"summary\": \"s\",\n  \"key_points\": [],\n  \"tasks\": [\n    {\n"
            + "      \"text\": \"x\",\n      \"due\": \"2026-09-20\"\n    }\n  ],\n  \"decisions\": [],\n"
            + "  \"ideas\": [],\n  \"tags\": []\n}\n"
        #expect(PyJSON.fileData(result.pyJSON(schema: schema)) == Data(expected.utf8))
    }

    @Test("due が nil でも null として出す")
    func nullDueIsWritten() throws {
        let schema = LLMFixtures.schema(.final)
        let result = try Self.validated(#"{"title":"t","summary":"s","tasks":[{"text":"x"}]}"#, schema)
        let text = String(decoding: PyJSON.fileData(result.pyJSON(schema: schema)), as: UTF8.self)
        #expect(text.contains("\"due\": null"))
    }

    @Test("中間形の pyJSON に title と tags が無い")
    func partialHasNoTitleOrTags() throws {
        let schema = LLMFixtures.schema(.partial)
        let result = try Self.validated(#"{"summary":"s"}"#, schema)
        guard case .object(let entries) = result.pyJSON(schema: schema) else {
            Issue.record("オブジェクトでない")
            return
        }
        #expect(entries.map(\.0) == ["summary", "key_points", "tasks", "decisions", "ideas"])
    }

    @Test("golden analysis_json", arguments: try Golden.cases("analysis_json"))
    func goldenAnalysisJSON(item: GoldenCase) throws {
        let config = try GoldenConfig.make(item)
        let schema = AnalysisSchema(config: AnalysisConfigView(sections: config.llm.analysis.sections), kind: .final)
        let result = try AnalysisValidator.validate(try item.orderedObject("payload"), schema: schema).get()
        GoldenAssert.matches(
            bytes: PyJSON.fileData(result.pyJSON(schema: schema)), group: "analysis_json", name: item.name)
    }

    @Test("golden analysis_json のケースが在る")
    func goldenAnalysisJSONHasCases() throws {
        #expect(!(try Golden.cases("analysis_json")).isEmpty)
    }

    @Test("フィールドが 0 個のスキーマなら空のオブジェクト")
    func emptySchemaGivesEmptyObject() {
        let schema = LLMFixtures.schema(.final) {
            $0.summary.enabled = false
            $0.keyPoints.enabled = false
            $0.tasks.enabled = false
            $0.decisions.enabled = false
            $0.ideas.enabled = false
            $0.tags.enabled = false
        }
        let result = AnalysisResult(
            title: nil, summary: nil, keyPoints: nil, tasks: nil, decisions: nil, ideas: nil, tags: nil)
        #expect(result.pyJSON(schema: schema) == .object([]))
    }
}
