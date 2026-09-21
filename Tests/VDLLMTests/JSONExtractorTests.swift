// JSONExtractor が voicedock extract_json / strip_think と同じ結果を出すこと（PLAN §8.5、T-19）。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDLLM

@Suite("JSONExtractor")
struct JSONExtractorTests {
    static let valid = #"{"title": "一日", "summary": "まとめ", "tasks": []}"#
    /// VALID を `json.dumps` 既定（ASCII エスケープ）で書いたもの。
    static let validEscaped = #"{"title": "\u4e00\u65e5", "summary": "\u307e\u3068\u3081", "tasks": []}"#
    static let validValue: PyJSONValue = .object([
        ("title", .string("一日")), ("summary", .string("まとめ")), ("tasks", .array([])),
    ])

    static func extracted(_ text: String) -> PyJSONValue? {
        JSONExtractor.extractObject(text).map { PyJSONValue.object($0) }
    }

    static func decoded(_ json: String) -> PyJSONValue? {
        PyJSON.decode(json)
    }

    @Test("そのままの JSON")
    func bareJSON() {
        #expect(Self.extracted(Self.valid) == Self.validValue)
        #expect(Self.extracted(Self.validEscaped) == Self.validValue)
    }

    @Test("json のフェンス")
    func fencedJSON() {
        #expect(Self.extracted("```json\n" + Self.valid + "\n```") == Self.validValue)
        #expect(Self.extracted("```json\n" + Self.validEscaped + "\n```") == Self.validValue)
    }

    @Test("言語名の無いフェンス")
    func fenceWithoutLanguage() {
        #expect(Self.extracted("```\n" + Self.valid + "\n```") == Self.validValue)
    }

    @Test("前後に文章がある")
    func proseAroundTheJSON() {
        #expect(Self.extracted("はい、整理しました。\n\n" + Self.valid + "\n\n以上です。") == Self.validValue)
    }

    @Test("think タグを除く")
    func thinkingTagsAreRemoved() {
        #expect(Self.extracted("<think>まず何を出すか考える</think>\n" + Self.valid) == Self.validValue)
    }

    @Test(
        "使えない出力は nil",
        arguments: ["", "ただの文章です", "{", "{'single': 'quotes'}", "[1, 2, 3]", "\"文字列\"", "null"])
    func unusableOutputReturnsNil(text: String) {
        #expect(JSONExtractor.extractObject(text) == nil)
    }

    @Test("最上位の配列なら最初のオブジェクト")
    func topLevelArrayYieldsFirstObject() {
        #expect(
            Self.extracted(#"[{"title": "t", "summary": "s"}]"#)
                == .object([("title", .string("t")), ("summary", .string("s"))]))
    }

    @Test("think の中の JSON は取らない")
    func jsonInsideThinkIsNotTaken() {
        #expect(
            Self.extracted(#"<think>{"title": "下書き", "summary": "捨てる"}</think>"# + Self.valid) == Self.validValue)
    }

    @Test("閉じない think は残りを飲み込む")
    func unclosedThinkSwallowsTheRest() {
        #expect(JSONExtractor.extractObject(#"<think>{"title": "途中""#) == nil)
    }

    @Test("think が複数でも全部除く")
    func multipleThinkBlocksAreRemoved() {
        #expect(Self.extracted("<think>A</think>前置き<think>B</think>" + Self.valid) == Self.validValue)
    }

    @Test("stripThink は think の外を残す")
    func stripThinkLeavesOtherText() {
        #expect(JSONExtractor.stripThink("前<think>中</think>後") == "前後")
        #expect(JSONExtractor.stripThink("<think>A</think>前置き<think>B</think>X") == "前置きX")
        #expect(JSONExtractor.stripThink("<think>{\"a\":1}") == "")
        #expect(JSONExtractor.stripThink("<think>A<think>B</think>C") == "C")
    }

    @Test("文字列の中の } は終わりではない")
    func braceInsideAStringIsNotTheEnd() {
        let object = #"{"summary": "閉じ括弧 } を含む文", "tasks": []}"#
        #expect(Self.extracted("説明\n" + object + "\n以上") == Self.decoded(object))
        #expect(Self.decoded(object) != nil)
    }

    @Test("文字列の中のエスケープされた引用符")
    func escapedQuoteInsideAString() {
        let object = #"{"summary": "引用 \" を含む"}"#
        #expect(Self.extracted("前" + object + "後") == .object([("summary", .string("引用 \" を含む"))]))
    }

    @Test("閉じ引用符の前のバックスラッシュ")
    func backslashBeforeClosingQuote() {
        let object = #"{"summary": "末尾が \\ で終わる"}"#
        #expect(Self.extracted("x" + object + "y") == .object([("summary", .string("末尾が \\ で終わる"))]))
    }

    @Test("入れ子のオブジェクト")
    func nestedObjects() {
        let object = #"{"tasks": [{"text": "a", "due": null}], "summary": "s"}"#
        #expect(
            Self.extracted("説明\n" + object)
                == .object([
                    ("tasks", .array([.object([("text", .string("a")), ("due", .null)])])), ("summary", .string("s")),
                ]))
    }

    @Test("オブジェクトの後ろの文章")
    func trailingTextAfterTheObject() {
        #expect(Self.extracted(Self.valid + "\n\nこれで完了です。") == Self.validValue)
    }

    @Test("最初のオブジェクトを取る")
    func firstObjectWins() {
        #expect(
            Self.extracted("{\"summary\": \"1 本目\"}\n{\"summary\": \"2 本目\"}")
                == .object([("summary", .string("1 本目"))]))
    }

    @Test("フェンスを balanced より先に試す")
    func fenceIsPreferredOverBalanced() {
        #expect(Self.extracted("前置きに { があります\n```json\n" + Self.valid + "\n```") == Self.validValue)
    }

    /// T-19 §4.6 の voicedock 実測の 8 例。期待が nil なら取り出せない。
    static let measured: [(text: String, expected: String?)] = [
        (#"<think>x</think> {"a":1}"#, #"{"a":1}"#),
        (#"pre {"a":"}"} post"#, #"{"a":"}"}"#),
        (#"[{"a":1}]"#, #"{"a":1}"#),
        (#"<think>{"a":1}"#, nil),
        ("```\nnot json\n```\n{\"b\":2}", #"{"b":2}"#),
        ("```json\n[1]\n```\n```json\n{\"c\":3}\n```", #"{"c":3}"#),
        (#"{"a": NaN}"#, "NaN"),
        (#"{"a":1,"a":2}"#, #"{"a":2}"#),
    ]

    @Test("voicedock の実測の 8 例", arguments: 0..<8)
    func voicedockMeasuredCases(input: Int) {
        let (text, expected) = Self.measured[input]
        let actual = JSONExtractor.extractObject(text)
        switch expected {
        case nil:
            #expect(actual == nil)
        case "NaN":
            guard let actual, actual.count == 1, actual[0].0 == "a", case .double(let value) = actual[0].1 else {
                Issue.record("NaN の例: \(String(describing: actual))")
                return
            }
            #expect(value.isNaN)
        case let json?:
            #expect(actual.map { PyJSONValue.object($0) } == Self.decoded(json))
        }
    }

    @Test("golden llm_extract", arguments: try Golden.cases("llm_extract"))
    func goldenExtract(item: GoldenCase) throws {
        let actual: GoldenJSON
        if let entries = JSONExtractor.extractObject(try item.string("text")) {
            guard let converted = GoldenJSON(any: PyJSONValue.object(entries).foundationObject) else {
                Issue.record("GoldenJSON にできない: \(entries)")
                return
            }
            actual = converted
        } else {
            actual = .null
        }
        GoldenAssert.matchesJSON(actual, group: "llm_extract", name: item.name)
    }

    @Test("golden llm_strip_think", arguments: try Golden.cases("llm_strip_think"))
    func goldenStripThink(item: GoldenCase) throws {
        GoldenAssert.matches(
            JSONExtractor.stripThink(try item.string("text")), group: "llm_strip_think", name: item.name)
    }

    @Test("golden llm_extract・llm_strip_think のケースが在る")
    func goldenExtractGroupsHaveCases() throws {
        #expect(!(try Golden.cases("llm_extract")).isEmpty)
        #expect(!(try Golden.cases("llm_strip_think")).isEmpty)
    }

    @Test("キーの順を保つ（重複は後勝ちで最初の位置）")
    func keyOrderIsPreserved() {
        #expect(Self.extracted(#"{"b":1,"a":2,"b":3}"#) == .object([("b", .int(3)), ("a", .int(2))]))
    }

    @Test("フェンスには改行が要る")
    func fenceNeedsANewline() {
        #expect(JSONExtractor.fenced(Array("```json {\"a\":1}```".unicodeScalars)).isEmpty)
        #expect(Self.extracted("```json {\"a\":1}```") == .object([("a", .int(1))]))
    }

    @Test("空の入力は nil")
    func emptyInput() {
        #expect(JSONExtractor.extractObject("") == nil)
        #expect(JSONExtractor.stripThink("") == "")
    }
}
