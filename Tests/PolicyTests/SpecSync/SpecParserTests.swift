// MarkdownDocument・SpecDocument・TestNameIndex の読み方の固定テスト（PLAN §10.3。T-05）。
import TestSupport
import Testing

@Suite("SpecParser")
struct SpecParserTests {
    @Test("コードフェンスの中の # 行で節が切れない")
    func fenceDoesNotEndSection() throws {
        let doc = MarkdownDocument(text: "## S1. 状態\n\n```bash\n# 2026-09-18 に実行\n```\nafter\n## S2. 次\nnext\n")
        let lines = try doc.section("S1.")
        #expect(lines.contains("after"))
        #expect(!lines.contains("next"))
    }

    @Test("見出しが無ければ誤りを投げる（skip しない）")
    func missingSectionThrows() {
        #expect(throws: MarkdownError.sectionNotFound("S9.")) {
            try MarkdownDocument(text: "## S1. a\n").section("S9.")
        }
    }

    @Test("太字の ID を読み、打ち消しの行を生きた ID に数えない")
    func boldAndStruckIDs() throws {
        let spec = SpecDocument(
            text:
                "## S7. ND\n\n| # | 故障 | 期待 | 層 |\n|---|---|---|---|\n| **ND-24** | a | b | R2 |\n| ~~ND-30~~ | ~~c~~ | — | — |\n| ND-31 | d | e | A・R3 |\n"
        )
        #expect(try spec.ids(.nd) == ["ND-24", "ND-31"])
        #expect(try spec.retiredIDs(.nd) == ["ND-30"])
        #expect(try spec.ndLayers()["ND-31"] == ["A", "R3"])
    }

    @Test("見出しの名前でコードブロックを取り、次の見出しの先のフェンスは取らない")
    func codeBlockByHeading() throws {
        let text = "## S9. E2E\n\n## whisper-cli の argv\n\n```text\n-m a -f b\n```\n## 次\n```text\nother\n```\n"
        let spec = SpecDocument(text: text)
        #expect(try spec.codeBlock(heading: "whisper-cli の argv", language: "text") == "-m a -f b")
        #expect(try spec.codeBlock(heading: "S9. E2E", language: "text") == nil)
        #expect(throws: MarkdownError.sectionNotFound("無い")) {
            try spec.codeBlock(heading: "無い", language: nil)
        }
    }

    @Test("表のセルはバッククォートの中の | で分けない")
    func cellsKeepPipeInCode() {
        #expect(MarkdownDocument.cells("| `a|b` | c |") == ["`a|b`", "c"])
    }

    @Test("遷移は直前の段落 Part: / Session: で分け、★ と括弧の注記を無視する")
    func transitionFences() throws {
        let text = "## S2. 遷移\n\nPart:\n```text\nA→B | B→C(注記)\n```\nSession:\n```text\n★ X→Y\n```\n"
        let spec = SpecDocument(text: text)
        #expect(try spec.transitionEdges(.part) == [SpecEdge(from: "A", to: "B"), SpecEdge(from: "B", to: "C")])
        #expect(try spec.transitionEdges(.session) == [SpecEdge(from: "X", to: "Y")])
    }

    @Test("テストの表示名から ID と層を集め、@Test でない文字列と文中の ID は拾わない")
    func testNameIndex() {
        let source = """
            @Test("ND-18 [R2] サイズが変わる") func a() {}
            @Test("CV-08 境界") func b() {}
            let note = "ND-99 これはテスト名ではない"
            @Test("説明の中の ND-77 は先頭ではない") func c() {}
            // @Test("ND-66 コメント")
            """
        let entries = TestNameIndex.entries(in: source, path: "X.swift")
        #expect(entries.map(\.id) == ["ND-18", "CV-08"])
        #expect(entries.first?.layer == "R2")
    }
}
