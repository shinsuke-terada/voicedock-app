// AnalysisSchema が設定の sections から voicedock build_schema と同じフィールドを作ること（PLAN §8.5、T-19）。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDLLM

/// VDLLMTests で共有する準備（T-19 §5.0）。
enum LLMFixtures {
    /// 既定の設定（`AppConfig.defaults(timeZone: "Asia/Tokyo")`）の sections。
    static var defaultSections: AnalysisSections {
        AppConfig.defaults(timeZone: "Asia/Tokyo").llm.analysis.sections
    }

    /// 既定の sections を edit で変えてスキーマを作る。
    static func schema(
        _ kind: AnalysisSchema.Kind, _ edit: (inout AnalysisSections) -> Void = { _ in }
    ) -> AnalysisSchema {
        var sections = defaultSections
        edit(&sections)
        return AnalysisSchema(config: AnalysisConfigView(sections: sections), kind: kind)
    }

    /// golden のケースの `timeZone`・`overrides`・`partial` からスキーマを作る。
    static func schema(_ item: GoldenCase) throws -> AnalysisSchema {
        let config = try GoldenConfig.make(item)
        return AnalysisSchema(
            config: AnalysisConfigView(sections: config.llm.analysis.sections),
            kind: try item.bool("partial") ? .partial : .final)
    }

    static func prompts() throws -> Prompts {
        try Prompts.load(directory: PackageRoot.url.appendingPathComponent("Resources/prompts"))
    }

    /// JSON の本文をキーの順を保ったオブジェクトにする（`PyJSON.decode`）。
    static func object(_ json: String) throws -> [(String, PyJSONValue)] {
        guard case .object(let entries) = PyJSON.decode(json) else {
            throw FixtureError.notAnObject(json)
        }
        return entries
    }

    enum FixtureError: Error {
        case notAnObject(String)
    }
}

@Suite("AnalysisSchema")
struct AnalysisSchemaTests {
    static let defaultFinalNames = ["title", "summary", "key_points", "tasks", "decisions", "ideas", "tags"]

    @Test("既定の最終形のフィールドと並び")
    func defaultFinalFields() {
        let schema = LLMFixtures.schema(.final)
        #expect(schema.fieldNames == Self.defaultFinalNames)
        #expect(
            schema.fields.map(\.shape) == [
                .text(maxScalars: 120), .text(maxScalars: 4000), .stringList(maxItems: 20), .taskList(maxItems: 50),
                .stringList(maxItems: 30), .stringList(maxItems: 30), .stringList(maxItems: 15),
            ])
        #expect(schema.fields.filter(\.required).map(\.name) == ["title", "summary"])
        #expect(schema.kind == .final)
    }

    @Test("中間形は title と tags を持たない")
    func defaultPartialFields() {
        let schema = LLMFixtures.schema(.partial)
        #expect(schema.fieldNames == ["summary", "key_points", "tasks", "decisions", "ideas"])
        #expect(schema.kind == .partial)
    }

    @Test("timeline はスキーマに入らない")
    func timelineIsNeverAField() {
        #expect(LLMFixtures.defaultSections.timeline.enabled)
        #expect(LLMFixtures.schema(.final).field(named: "timeline") == nil)
        #expect(LLMFixtures.schema(.partial).field(named: "timeline") == nil)
        #expect(!LLMFixtures.schema(.final).fieldNames.contains("timeline"))
        #expect(!LLMFixtures.schema(.partial).fieldNames.contains("timeline"))
    }

    @Test("CE llm.analysis.sections.key_points.enabled false でスキーマから消える")
    func ceKeyPointsEnabled() {
        #expect(LLMFixtures.schema(.final).fieldNames.contains("key_points"))
        let schema = LLMFixtures.schema(.final) { $0.keyPoints.enabled = false }
        #expect(schema.fieldNames == ["title", "summary", "tasks", "decisions", "ideas", "tags"])
    }

    @Test("CE llm.analysis.sections.tasks.enabled false でスキーマから消える")
    func ceTasksEnabled() {
        #expect(LLMFixtures.schema(.final).fieldNames.contains("tasks"))
        let schema = LLMFixtures.schema(.final) { $0.tasks.enabled = false }
        #expect(schema.fieldNames == ["title", "summary", "key_points", "decisions", "ideas", "tags"])
    }

    @Test("CE llm.analysis.sections.decisions.enabled false でスキーマから消える")
    func ceDecisionsEnabled() {
        #expect(LLMFixtures.schema(.final).fieldNames.contains("decisions"))
        let schema = LLMFixtures.schema(.final) { $0.decisions.enabled = false }
        #expect(schema.fieldNames == ["title", "summary", "key_points", "tasks", "ideas", "tags"])
    }

    @Test("CE llm.analysis.sections.ideas.enabled false でスキーマから消える")
    func ceIdeasEnabled() {
        #expect(LLMFixtures.schema(.final).fieldNames.contains("ideas"))
        let schema = LLMFixtures.schema(.final) { $0.ideas.enabled = false }
        #expect(schema.fieldNames == ["title", "summary", "key_points", "tasks", "decisions", "tags"])
    }

    @Test("CE llm.analysis.sections.tags.enabled false でスキーマから消える")
    func ceTagsEnabled() {
        #expect(LLMFixtures.schema(.final).fieldNames.contains("tags"))
        let schema = LLMFixtures.schema(.final) { $0.tags.enabled = false }
        #expect(schema.fieldNames == ["title", "summary", "key_points", "tasks", "decisions", "ideas"])
    }

    @Test("CE llm.analysis.sections.ideas.maxItems が null の節には上限が無い")
    func maxItemsNilHasNoLimit() {
        #expect(LLMFixtures.schema(.final).field(named: "ideas")?.shape == .stringList(maxItems: 30))
        let unlimited = LLMFixtures.schema(.final) { $0.ideas.maxItems = nil }
        #expect(unlimited.field(named: "ideas")?.shape == .stringList(maxItems: nil))
        #expect(unlimited.field(named: "ideas")?.trimLimit == nil)
        let three = LLMFixtures.schema(.final) { $0.ideas.maxItems = 3 }
        #expect(three.field(named: "ideas")?.shape == .stringList(maxItems: 3))
    }

    @Test("CE llm.analysis.sections.key_points.maxItems が形に入る")
    func ceKeyPointsMaxItems() {
        #expect(LLMFixtures.schema(.final).field(named: "key_points")?.shape == .stringList(maxItems: 20))
        let schema = LLMFixtures.schema(.final) { $0.keyPoints.maxItems = 3 }
        #expect(schema.field(named: "key_points")?.shape == .stringList(maxItems: 3))
        #expect(schema.field(named: "key_points")?.trimLimit == 3)
    }

    @Test("CE llm.analysis.sections.tasks.maxItems が形に入る")
    func ceTasksMaxItems() {
        #expect(LLMFixtures.schema(.final).field(named: "tasks")?.shape == .taskList(maxItems: 50))
        let schema = LLMFixtures.schema(.final) { $0.tasks.maxItems = 3 }
        #expect(schema.field(named: "tasks")?.shape == .taskList(maxItems: 3))
        #expect(schema.field(named: "tasks")?.trimLimit == 3)
    }

    @Test("CE llm.analysis.sections.decisions.maxItems が形に入る")
    func ceDecisionsMaxItems() {
        #expect(LLMFixtures.schema(.final).field(named: "decisions")?.shape == .stringList(maxItems: 30))
        let schema = LLMFixtures.schema(.final) { $0.decisions.maxItems = 3 }
        #expect(schema.field(named: "decisions")?.shape == .stringList(maxItems: 3))
    }

    @Test("CE llm.analysis.sections.tags.maxItems が形に入る")
    func ceTagsMaxItems() {
        #expect(LLMFixtures.schema(.final).field(named: "tags")?.shape == .stringList(maxItems: 15))
        let schema = LLMFixtures.schema(.final) { $0.tags.maxItems = 3 }
        #expect(schema.field(named: "tags")?.shape == .stringList(maxItems: 3))
    }

    @Test("配列の節の並びは order に従わない")
    func listOrderIgnoresConfigOrder() {
        var config = AppConfig.defaults(timeZone: "Asia/Tokyo")
        config.llm.analysis.order = ["ideas", "summary", "tasks"]
        let schema = AnalysisSchema(config: AnalysisConfigView(sections: config.llm.analysis.sections), kind: .final)
        #expect(schema.fieldNames == Self.defaultFinalNames)
    }

    @Test("CE llm.analysis.sections.summary.enabled false なら title も summary も無い")
    func summaryDisabledRemovesTitleAndSummary() {
        #expect(LLMFixtures.schema(.final).fieldNames.first == "title")
        let final = LLMFixtures.schema(.final) { $0.summary.enabled = false }
        #expect(final.fieldNames == ["key_points", "tasks", "decisions", "ideas", "tags"])
        let partial = LLMFixtures.schema(.partial) { $0.summary.enabled = false }
        #expect(partial.fieldNames == ["key_points", "tasks", "decisions", "ideas"])
    }

    @Test("節がすべて無効ならフィールドは 0 個")
    func allSectionsDisabledHasNoFields() {
        let schema = LLMFixtures.schema(.final) {
            $0.summary.enabled = false
            $0.keyPoints.enabled = false
            $0.tasks.enabled = false
            $0.decisions.enabled = false
            $0.ideas.enabled = false
            $0.tags.enabled = false
        }
        #expect(schema.fields.isEmpty)
        #expect(SchemaBlock.render(schema) == "{\n\n}")
    }
}
