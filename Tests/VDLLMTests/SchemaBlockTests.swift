// SchemaBlock が voicedock render_schema_block とバイト一致すること（PLAN §8.5、LLM-01、T-19）。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDLLM

@Suite("SchemaBlock")
struct SchemaBlockTests {
    /// T-19 §4.3 の既定の最終形の全文（voicedock 実測）。
    static let finalDefaultText = """
        {
          "title": "内容を表す簡潔な日本語（120 文字以内）",
          "summary": "全体の要約（4000 文字以内）",
          "key_points": ["..."],
          "tasks": [{"text": "やること", "due": "2026-08-30 または null"}],
          "decisions": ["..."],
          "ideas": ["..."],
          "tags": ["..."]
        }
        """

    @Test("golden llm_schema_block", arguments: try Golden.cases("llm_schema_block"))
    func goldenSchemaBlock(item: GoldenCase) throws {
        let rendered = SchemaBlock.render(try LLMFixtures.schema(item))
        GoldenAssert.matches(rendered, group: "llm_schema_block", name: item.name)
        if item.name == "final_default" {
            #expect(rendered == Self.finalDefaultText)
        }
    }

    @Test("golden llm_schema_block のケースが在る")
    func goldenSchemaBlockHasCases() throws {
        #expect(!(try Golden.cases("llm_schema_block")).isEmpty)
    }

    @Test("既定の最終形が §4.3 の全文と一致")
    func finalMatchesPlanText() {
        let rendered = SchemaBlock.render(LLMFixtures.schema(.final))
        #expect(rendered.unicodeScalars.elementsEqual(Self.finalDefaultText.unicodeScalars))
    }

    @Test("件数の上限を見せない（LLM-01）")
    func itemLimitIsNotShown() {
        let rendered = SchemaBlock.render(LLMFixtures.schema(.final) { $0.ideas.maxItems = 7 })
        let ideasLine = rendered.split(separator: "\n").first { $0.contains("\"ideas\"") }
        #expect(ideasLine == "  \"ideas\": [\"...\"],")
        #expect(ideasLine?.contains("7") == false)
        #expect(!rendered.contains("最大 7 件"))
    }

    @Test("文字数の上限は見せる")
    func characterLimitIsShown() {
        #expect(SchemaBlock.render(LLMFixtures.schema(.final)).contains("文字以内"))
    }

    @Test("末尾に改行が無い")
    func noTrailingNewline() {
        #expect(SchemaBlock.render(LLMFixtures.schema(.final)).unicodeScalars.last == "}")
        #expect(SchemaBlock.render(LLMFixtures.schema(.partial)).unicodeScalars.last == "}")
    }
}
