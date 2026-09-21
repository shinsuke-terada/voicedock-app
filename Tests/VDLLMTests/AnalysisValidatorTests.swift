// AnalysisValidator の切り詰めと検証が voicedock（pydantic v2）と同じ判定・順・文言になること（PLAN §8.5、LLM-02・LLM-09、T-19）。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDLLM

@Suite("AnalysisValidator")
struct AnalysisValidatorTests {
    static let long501 = String(repeating: "あ", count: 501)

    /// T-19 §4.7 の表（すべて既定の最終形スキーマ）。
    static let errorTable: [(input: String, expected: String)] = [
        (#"{"title":"t"}"#, "- summary: Field required"),
        ("{}", "- title: Field required\n- summary: Field required"),
        (#"{"title":"t","summary":"s","mood":"x"}"#, "- mood: Extra inputs are not permitted"),
        (#"{"title":"t","summary":""}"#, "- summary: String should have at least 1 character"),
        (#"{"title":"","summary":"s"}"#, "- title: String should have at least 1 character"),
        (#"{"title":"t","summary":"s","key_points":"文字列"}"#, "- key_points: Input should be a valid list"),
        (#"{"title":"t","summary":"s","key_points":{"a":1}}"#, "- key_points: Input should be a valid list"),
        (#"{"title":"t","summary":"s","key_points":["a",1]}"#, "- key_points.1: Input should be a valid string"),
        (
            #"{"title":"t","summary":"s","key_points":[null,true,1.5,"ok"]}"#,
            "- key_points.0: Input should be a valid string\n- key_points.1: Input should be a valid string\n"
                + "- key_points.2: Input should be a valid string"
        ),
        (#"{"title":"t","summary":"s","tasks":[{"due":null}]}"#, "- tasks.0.text: Field required"),
        (
            #"{"title":"t","summary":"s","tasks":["x"]}"#,
            "- tasks.0: Input should be a valid dictionary or instance of Task"
        ),
        (#"{"title":"t","summary":"s","tasks":[{"text":"a","x":1}]}"#, "- tasks.0.x: Extra inputs are not permitted"),
        (
            #"{"title":"t","summary":"s","tasks":[{"text":"a","due":3}]}"#,
            "- tasks.0.due: Input should be a valid string"
        ),
        (
            #"{"title":"t","summary":"s","tasks":[{"text":""}]}"#,
            "- tasks.0.text: String should have at least 1 character"
        ),
        (
            #"{"title":"t","summary":"s","tasks":[{"text":""# + long501 + #""}]}"#,
            "- tasks.0.text: String should have at most 500 characters"
        ),
        (
            #"{"title":"t","summary":"s","tasks":[{"x":1,"due":3}]}"#,
            "- tasks.0.text: Field required\n- tasks.0.due: Input should be a valid string\n"
                + "- tasks.0.x: Extra inputs are not permitted"
        ),
        (
            #"{"title":"t","summary":"s","tasks":[{"text":5,"due":true},"y"]}"#,
            "- tasks.0.text: Input should be a valid string\n- tasks.0.due: Input should be a valid string\n"
                + "- tasks.1: Input should be a valid dictionary or instance of Task"
        ),
        (#"{"title":"t","summary":"s","tasks":null}"#, "- tasks: Input should be a valid list"),
        (#"{"title":5,"summary":"s"}"#, "- title: Input should be a valid string"),
        (#"{"title":true,"summary":"s"}"#, "- title: Input should be a valid string"),
        (#"{"title":"t","summary":null}"#, "- summary: Input should be a valid string"),
        (
            #"{"title":["t"],"summary":{"a":1}}"#,
            "- title: Input should be a valid string\n- summary: Input should be a valid string"
        ),
        (#"{"title":"t","summary":"s","tags":null}"#, "- tags: Input should be a valid list"),
        (
            #"{"zzz":1,"title":"t","summary":"s","aaa":2}"#,
            "- zzz: Extra inputs are not permitted\n- aaa: Extra inputs are not permitted"
        ),
        (
            #"{"mood":1,"summary":3,"tags":[1],"zzz":2}"#,
            "- title: Field required\n- summary: Input should be a valid string\n- tags.0: Input should be a valid string\n"
                + "- mood: Extra inputs are not permitted\n- zzz: Extra inputs are not permitted"
        ),
    ]

    static func failure(
        _ obj: [(String, PyJSONValue)], _ schema: AnalysisSchema = LLMFixtures.schema(.final)
    ) -> String? {
        if case .failure(let errors) = AnalysisValidator.validate(obj, schema: schema) {
            return errors.rendered
        }
        return nil
    }

    static func success(
        _ obj: [(String, PyJSONValue)], _ schema: AnalysisSchema = LLMFixtures.schema(.final)
    ) -> AnalysisResult? {
        try? AnalysisValidator.validate(obj, schema: schema).get()
    }

    static func strings(_ prefix: String, _ count: Int) -> PyJSONValue {
        .array((0..<count).map { .string("\(prefix)\($0)") })
    }

    @Test("検証エラーの行が pydantic と同じ", arguments: errorTable)
    func errorLines(input: String, expected: String) throws {
        #expect(Self.failure(try LLMFixtures.object(input)) == expected)
    }

    @Test("中間形に title と tags を出したら未知キー（入力の順）")
    func partialRejectsTitleAndTags() throws {
        let obj = try LLMFixtures.object(#"{"title":"t","summary":"s","tags":["a"]}"#)
        #expect(
            Self.failure(obj, LLMFixtures.schema(.partial))
                == "- title: Extra inputs are not permitted\n- tags: Extra inputs are not permitted")
    }

    @Test("golden llm_validate", arguments: try Golden.cases("llm_validate"))
    func goldenValidate(item: GoldenCase) throws {
        let schema = try LLMFixtures.schema(item)
        let actual: PyJSONValue
        switch AnalysisValidator.validate(try item.orderedObject("payload"), schema: schema) {
        case .success(let result):
            actual = .object([("ok", .bool(true)), ("errors", .null), ("result", result.pyJSON(schema: schema))])
        case .failure(let errors):
            actual = .object([("ok", .bool(false)), ("errors", .string(errors.rendered)), ("result", .null)])
        }
        guard let json = GoldenJSON(any: actual.foundationObject) else {
            Issue.record("GoldenJSON にできない")
            return
        }
        GoldenAssert.matchesJSON(json, group: "llm_validate", name: item.name)
    }

    @Test("golden llm_trim", arguments: try Golden.cases("llm_trim"))
    func goldenTrim(item: GoldenCase) throws {
        let (obj, trimmed) = AnalysisValidator.trim(
            try item.orderedObject("payload"), schema: try LLMFixtures.schema(item))
        let actual: PyJSONValue = .object([("trimmed", .array(trimmed.map { .string($0) })), ("result", .object(obj))])
        guard let json = GoldenJSON(any: actual.foundationObject) else {
            Issue.record("GoldenJSON にできない")
            return
        }
        GoldenAssert.matchesJSON(json, group: "llm_trim", name: item.name)
    }

    @Test("golden llm_validate・llm_trim のケースが在る")
    func goldenValidatorGroupsHaveCases() throws {
        #expect(!(try Golden.cases("llm_validate")).isEmpty)
        #expect(!(try Golden.cases("llm_trim")).isEmpty)
    }

    @Test("正しい入力は通る")
    func validPayloadPasses() throws {
        let obj = try LLMFixtures.object(
            #"{"title":"開発と打ち合わせの一日","summary":"削除条件を整理した。","key_points":["整理した"],"#
                + #""tasks":[{"text":"確認する","due":null}],"decisions":["GUI は作らない"],"ideas":["話者識別"],"#
                + #""tags":["VoiceDock"]}"#)
        #expect(
            Self.success(obj)
                == AnalysisResult(
                    title: "開発と打ち合わせの一日", summary: "削除条件を整理した。", keyPoints: ["整理した"],
                    tasks: [AnalysisTask(text: "確認する", due: nil)], decisions: ["GUI は作らない"], ideas: ["話者識別"],
                    tags: ["VoiceDock"]))
    }

    @Test("欠けた配列は空配列")
    func missingListsDefaultToEmpty() throws {
        let result = Self.success(try LLMFixtures.object(#"{"title":"t","summary":"s"}"#))
        #expect(
            result
                == AnalysisResult(
                    title: "t", summary: "s", keyPoints: [], tasks: [], decisions: [], ideas: [], tags: []))
    }

    @Test("due の欠落は nil")
    func missingDueIsNil() throws {
        let result = Self.success(try LLMFixtures.object(#"{"title":"t","summary":"s","tasks":[{"text":"a"}]}"#))
        #expect(result?.tasks == [AnalysisTask(text: "a", due: nil)])
    }

    @Test("無効な節を出したら未知キー")
    func disabledSectionIsRejected() throws {
        let schema = LLMFixtures.schema(.final) { $0.ideas.enabled = false }
        let obj = try LLMFixtures.object(#"{"title":"t","summary":"s","ideas":["x"]}"#)
        #expect(Self.failure(obj, schema) == "- ideas: Extra inputs are not permitted")
    }

    @Test("bool を文字列として受けない")
    func boolIsNotAString() throws {
        let obj = try LLMFixtures.object(#"{"title":true,"summary":"s"}"#)
        #expect(Self.failure(obj) == "- title: Input should be a valid string")
    }

    @Test("エラーに入力値を入れない（LLM-09）")
    func valuesAreNotLeaked() throws {
        let obj = try LLMFixtures.object(
            #"{"title":"t","summary":"秘密の本文","tasks":[{"text":"秘密のタスク","x":"秘密の値"}],"mood":"秘密"}"#)
        let rendered = try #require(Self.failure(obj))
        #expect(!rendered.contains("秘密"))
        #expect(rendered == "- tasks.0.x: Extra inputs are not permitted\n- mood: Extra inputs are not permitted")
    }

    @Test("切り詰めの実測")
    func trimMeasured() throws {
        let tags = (0..<20).map { PyJSONValue.int(Int64($0)) }
        let obj: [(String, PyJSONValue)] = [
            ("title", .string(String(repeating: "あ", count: 121))), ("summary", .int(5)),
            ("key_points", .string(String(repeating: "x", count: 30))), ("tags", .array(tags)),
            ("tasks", .array(Array(repeating: .object([("text", .string("a"))]), count: 60))),
        ]
        let (trimmedObj, trimmed) = AnalysisValidator.trim(obj, schema: LLMFixtures.schema(.final))
        #expect(trimmed == ["title: 121 -> 120", "key_points: 30 -> 20", "tasks: 60 -> 50", "tags: 20 -> 15"])
        #expect(trimmedObj.map(\.0) == ["title", "summary", "key_points", "tags", "tasks"])
        #expect(trimmedObj[0].1 == .string(String(repeating: "あ", count: 120)))
        #expect(trimmedObj[1].1 == .int(5))
        #expect(trimmedObj[2].1 == .string(String(repeating: "x", count: 20)))
        #expect(trimmedObj[3].1 == .array(Array(tags.prefix(15))))
        #expect(trimmedObj[4].1 == .array(Array(repeating: .object([("text", .string("a"))]), count: 50)))

        let second: [(String, PyJSONValue)] = [
            ("title", .string("t")), ("summary", .string(String(repeating: "s", count: 4001))),
        ]
        let (secondObj, secondTrimmed) = AnalysisValidator.trim(second, schema: LLMFixtures.schema(.final))
        #expect(secondTrimmed == ["summary: 4001 -> 4000"])
        #expect(secondObj[1].1 == .string(String(repeating: "s", count: 4000)))
    }

    @Test("切り詰めてから検証する")
    func trimmingThenValidating() {
        let obj: [(String, PyJSONValue)] = [
            ("title", .string(String(repeating: "あ", count: 121))), ("summary", .string("s")),
            ("tags", Self.strings("t", 20)),
        ]
        let schema = LLMFixtures.schema(.final)
        #expect(
            Self.failure(obj, schema)
                == "- title: String should have at most 120 characters\n"
                + "- tags: List should have at most 15 items after validation, not 20")
        let (trimmedObj, _) = AnalysisValidator.trim(obj, schema: schema)
        let result = Self.success(trimmedObj, schema)
        #expect(result?.tags?.count == 15)
        #expect(result?.title == String(repeating: "あ", count: 120))
    }

    @Test("上限ちょうどは切らない")
    func exactlyAtLimitIsNotTrimmed() {
        let obj: [(String, PyJSONValue)] = [
            ("title", .string(String(repeating: "あ", count: 120))), ("summary", .string("s")),
            ("tags", Self.strings("t", 15)),
        ]
        let (trimmedObj, trimmed) = AnalysisValidator.trim(obj, schema: LLMFixtures.schema(.final))
        #expect(trimmed == [])
        #expect(PyJSONValue.object(trimmedObj) == .object(obj))
    }

    @Test("tasks の text は切らない")
    func taskTextIsNotTrimmed() {
        let obj: [(String, PyJSONValue)] = [
            ("title", .string("t")), ("summary", .string("s")),
            ("tasks", .array([.object([("text", .string(Self.long501))])])),
        ]
        let (trimmedObj, trimmed) = AnalysisValidator.trim(obj, schema: LLMFixtures.schema(.final))
        #expect(trimmed == [])
        #expect(Self.failure(trimmedObj)?.contains("at most 500") == true)
    }

    @Test("最小長は切り詰めで直さない")
    func emptySummaryIsNotFixed() {
        let obj: [(String, PyJSONValue)] = [("title", .string("t")), ("summary", .string(""))]
        let (trimmedObj, trimmed) = AnalysisValidator.trim(obj, schema: LLMFixtures.schema(.final))
        #expect(trimmed == [])
        #expect(Self.failure(trimmedObj)?.contains("at least 1") == true)
    }

    @Test("上限の無い節は切らない")
    func noLimitMeansNoTrim() {
        let schema = LLMFixtures.schema(.final) { $0.ideas.maxItems = nil }
        let obj: [(String, PyJSONValue)] = [
            ("title", .string("t")), ("summary", .string("s")), ("ideas", Self.strings("i", 200)),
        ]
        let (trimmedObj, trimmed) = AnalysisValidator.trim(obj, schema: schema)
        #expect(trimmed == [])
        #expect(Self.success(trimmedObj, schema)?.ideas?.count == 200)
    }

    @Test("文字数はスカラーで数える")
    func countsScalarsNotCharacters() {
        let ga = "\u{304B}\u{3099}"
        let obj: [(String, PyJSONValue)] = [
            ("title", .string(String(repeating: ga, count: 61))), ("summary", .string("s")),
        ]
        let (trimmedObj, trimmed) = AnalysisValidator.trim(obj, schema: LLMFixtures.schema(.final))
        #expect(trimmed == ["title: 122 -> 120"])
        guard case .string(let title) = trimmedObj[0].1 else {
            Issue.record("title が文字列でない")
            return
        }
        #expect(title.unicodeScalars.count == 120)
    }

    @Test("空のオブジェクトは切るものが無く、必須の 2 つが欠ける")
    func emptyObject() {
        let (trimmedObj, trimmed) = AnalysisValidator.trim([], schema: LLMFixtures.schema(.final))
        #expect(trimmed == [])
        #expect(trimmedObj.isEmpty)
        #expect(Self.failure([]) == "- title: Field required\n- summary: Field required")
    }

    @Test("pydantic の単数・複数の文言")
    func pluralForms() {
        #expect(LLMValidationMessages.tooShort(1) == "String should have at least 1 character")
        #expect(LLMValidationMessages.tooShort(2) == "String should have at least 2 characters")
        #expect(LLMValidationMessages.tooLong(1) == "String should have at most 1 character")
        #expect(LLMValidationMessages.tooLong(500) == "String should have at most 500 characters")
        #expect(LLMValidationMessages.tooManyItems(1, 3) == "List should have at most 1 item after validation, not 3")
        #expect(
            LLMValidationMessages.tooManyItems(15, 20) == "List should have at most 15 items after validation, not 20")
    }
}
