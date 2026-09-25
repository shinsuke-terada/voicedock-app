// Prompts の資源と差し込みが voicedock と同じで、修復プロンプトにスキーマが付くこと（PLAN §8.5、X-12、T-19）。
import CryptoKit
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDLLM

@Suite("Prompts")
struct PromptsTests {
    static let promptsDirectory = PackageRoot.url.appendingPathComponent("Resources/prompts")

    /// T-19 §4.5 の表の sha256。
    static let expectedSHA256: [String: String] = [
        "analyze_ja.txt": "6309c0c7b5dd51913f5f270162b278a094e7c678532b14851f82ac5a038c0a29",
        "map_ja.txt": "ff99c78e2c88e5bb401b4461469c45ac51ee2af35d0382327afbb84d7e4d42e2",
        "reduce_ja.txt": "857e5b8b41608c731398c6bbb3c95f29dfa9522f643164773edae197e809e8a2",
        "repair_json_ja.txt": "c2c01a1c4a064cef3e9cb4a8237cd639355a95d9b34c9055b75d8db74d12c52d",
    ]

    static func schemaBlockGolden(_ name: String) throws -> String {
        String(decoding: try Golden.expectedBytes("llm_schema_block", name), as: UTF8.self)
    }

    /// スカラー列としての部分一致（Swift の `contains` は Character 単位で正準等価に比べるため）。
    static func scalarContains(_ text: String, _ part: String) -> Bool {
        let hay = Array(text.unicodeScalars)
        let needle = Array(part.unicodeScalars)
        guard needle.count <= hay.count else { return false }
        return (0...(hay.count - needle.count)).contains { hay[$0..<($0 + needle.count)].elementsEqual(needle) }
    }

    @Test("プロンプトの資源が固定の sha256 と一致")
    func resourceFilesAreExactCopies() throws {
        #expect(Self.expectedSHA256.count == 4)
        for (name, expected) in Self.expectedSHA256 {
            let data = try Data(contentsOf: Self.promptsDirectory.appendingPathComponent(name))
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(actual == expected, "\(name)")
        }
    }

    @Test("golden llm_prompt", arguments: try Golden.cases("llm_prompt"))
    func goldenSystemPrompt(item: GoldenCase) throws {
        let config = try GoldenConfig.make(item)
        let kind: PromptKind
        switch try item.string("kind") {
        case "analyze": kind = .analyze
        case "map": kind = .map
        case "reduce": kind = .reduce
        case let other:
            Issue.record("未知の kind: \(other)")
            return
        }
        let schema = AnalysisSchema(
            config: AnalysisConfigView(sections: config.llm.analysis.sections), kind: kind == .map ? .partial : .final)
        let actual = try LLMFixtures.prompts().system(
            kind, schema: schema, custom: config.llm.analysis.customInstructions)
        GoldenAssert.matches(actual, group: "llm_prompt", name: item.name)
    }

    @Test("golden llm_repair_prompt", arguments: try Golden.cases("llm_repair_prompt"))
    func goldenRepairPrompt(item: GoldenCase) throws {
        let actual = try LLMFixtures.prompts().repair(
            schema: try LLMFixtures.schema(item), errors: try item.string("errors"),
            previousOutput: try item.string("previousOutput"))
        GoldenAssert.matches(actual, group: "llm_repair_prompt", name: item.name)
    }

    @Test("golden prompt_files", arguments: try Golden.cases("prompt_files"))
    func goldenPromptFiles(item: GoldenCase) throws {
        if item.name == "repair_json" {
            // X-12: voicedock の repair_json.txt の後ろに "\n{schema_block}\n" を足したもの。
            let actual = try Data(contentsOf: Self.promptsDirectory.appendingPathComponent("repair_json_ja.txt"))
            let expected = try Golden.expectedBytes("prompt_files", "repair_json") + Data("\n{schema_block}\n".utf8)
            #expect(actual == expected)
            return
        }
        let actual = try Data(contentsOf: Self.promptsDirectory.appendingPathComponent("\(item.name).txt"))
        GoldenAssert.matches(bytes: actual, group: "prompt_files", name: item.name)
    }

    @Test("golden llm_prompt・llm_repair_prompt・prompt_files のケースが在る")
    func goldenPromptGroupsHaveCases() throws {
        #expect(!(try Golden.cases("llm_prompt")).isEmpty)
        #expect(!(try Golden.cases("llm_repair_prompt")).isEmpty)
        #expect(!(try Golden.cases("prompt_files")).isEmpty)
    }

    @Test("map の system は中間形（title と tags が無い）")
    func mapHasNoTitleOrTags() throws {
        let system = try LLMFixtures.prompts().map(schema: LLMFixtures.schema(.partial), custom: "")
        #expect(!system.contains("\"title\""))
        #expect(!system.contains("\"tags\""))
        #expect(system.contains("\"summary\""))
    }

    @Test("差し込み後にプレースホルダが残らない", arguments: [PromptKind.analyze, .map, .reduce])
    func placeholdersAreFilled(kind: PromptKind) throws {
        let schema = LLMFixtures.schema(kind == .map ? .partial : .final)
        let system = try LLMFixtures.prompts().system(kind, schema: schema, custom: "")
        #expect(!system.contains("{schema_block}"))
        #expect(!system.contains("{custom_instructions}"))
        #expect(system.contains("summary"))
    }

    @Test("修復プロンプトの末尾にスキーマ（X-12）")
    func repairIncludesTheSchema() throws {
        let actual = try LLMFixtures.prompts().repair(
            schema: LLMFixtures.schema(.final), errors: "- summary: Field required",
            previousOutput: "{\"title\": \"t\"}")
        let expected =
            "前回の出力は JSON として不正でした。\n\nエラー内容:\n- summary: Field required\n\n前回の出力:\n{\"title\": \"t\"}\n\n"
            + "同じ内容を、指定されたスキーマに厳密に従う有効な JSON のみで出力し直してください。\n説明文やコードフェンスを付けないでください。\n\n"
            + (try Self.schemaBlockGolden("final_default")) + "\n"
        #expect(actual.unicodeScalars.elementsEqual(expected.unicodeScalars))
    }

    @Test("Map の修復は中間形のスキーマ")
    func repairUsesThePartialSchemaForMap() throws {
        let actual = try LLMFixtures.prompts().repair(
            schema: LLMFixtures.schema(.partial), errors: "- title: Extra inputs are not permitted",
            previousOutput: "{}")
        #expect(actual.hasSuffix((try Self.schemaBlockGolden("partial_default")) + "\n"))
    }

    @Test("差し込みの順が固定")
    func substitutionOrderIsFixed() throws {
        let prompts = try LLMFixtures.prompts()
        let system = prompts.analyze(schema: LLMFixtures.schema(.final), custom: "独自 {schema_block} 指示")
        #expect(system.contains("独自 {schema_block} 指示"))
        let repair = prompts.repair(
            schema: LLMFixtures.schema(.final), errors: "- summary: Field required", previousOutput: "出力 {errors} 末尾")
        #expect(repair.contains("出力 {errors} 末尾"))
    }

    @Test("置換はスカラーの完全一致（Python の str.replace と同じ）")
    func replaceIsLiteralOnScalars() throws {
        let actual = try LLMFixtures.prompts().repair(
            schema: LLMFixtures.schema(.final), errors: "{previous_output}\u{301}", previousOutput: "P")
        #expect(Self.scalarContains(actual, "エラー内容:\nP\u{301}\n"))
        #expect(PromptText.replaceAll("a}\u{301}b", "}", "X") == "aX\u{301}b")
    }

    @Test("ファイルが無ければ unreadable")
    func loadFailsForMissingFile() throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        for name in ["analyze_ja.txt", "map_ja.txt", "reduce_ja.txt"] {
            let data = try Data(contentsOf: Self.promptsDirectory.appendingPathComponent(name))
            try data.write(to: temp.url.appendingPathComponent(name))
        }
        #expect(throws: PromptsError.unreadable("repair_json_ja.txt")) {
            try Prompts.load(directory: temp.url)
        }
    }

    @Test("空のディレクトリなら最初のファイルで unreadable")
    func loadFailsForEmptyDirectory() throws {
        let temp = try TempDirectory()
        defer { temp.remove() }
        #expect(throws: PromptsError.unreadable("analyze_ja.txt")) {
            try Prompts.load(directory: temp.url)
        }
    }

    @Test("疎通確認の文言")
    func probeConstants() {
        #expect(LLMProbe.system == "{\"ok\": true} と返してください。")
        #expect(LLMProbe.user == "ping")
        #expect(LLMProbe.user.unicodeScalars.count < 100)
    }

    @Test("リンクを作らせない（PR-15）")
    func noPromptAsksForWikilinks() throws {
        for name in ["analyze_ja.txt", "map_ja.txt", "reduce_ja.txt"] {
            let text = String(
                decoding: try Data(contentsOf: Self.promptsDirectory.appendingPathComponent(name)), as: UTF8.self)
            #expect(text.contains("本文に [[ ]] 形式のリンクを書かないでください。"), "\(name)")
        }
        let repair = String(
            decoding: try Data(contentsOf: Self.promptsDirectory.appendingPathComponent("repair_json_ja.txt")),
            as: UTF8.self)
        #expect(!repair.contains("[["))
    }

    // MARK: - F-92 の上書き

    @Test("template は同梱のファイルの本文そのもの（3 つ）")
    func templateIsTheBundledText() throws {
        let prompts = try Prompts.load(directory: Self.promptsDirectory)
        let files: [(PromptKind, String)] = [
            (.analyze, "analyze_ja.txt"), (.map, "map_ja.txt"), (.reduce, "reduce_ja.txt"),
        ]
        for (kind, name) in files {
            let data = try Data(contentsOf: Self.promptsDirectory.appendingPathComponent(name))
            #expect(Data(prompts.template(kind).utf8) == data, "\(name)")
        }
    }

    @Test("overriding の nil は同梱のまま（3 つとも nil なら元と等しい。TEST-28）")
    func overridingWithNilsIsIdentity() throws {
        let prompts = try Prompts.load(directory: Self.promptsDirectory)
        #expect(prompts.overriding(PromptOverrides(analyze: nil, map: nil, reduce: nil)) == prompts)
    }

    @Test("overriding は指定した種類だけを替え、修復のプロンプトは替えない")
    func overridingReplacesOnlyGivenKinds() throws {
        let prompts = Prompts(analyze: "A", map: "M", reduce: "R", repair: "P {schema_block}")
        let o = prompts.overriding(PromptOverrides(analyze: nil, map: "M2", reduce: nil))
        #expect(o == Prompts(analyze: "A", map: "M2", reduce: "R", repair: "P {schema_block}"))
        #expect(o.template(.analyze) == "A")
        #expect(o.template(.map) == "M2")
        #expect(o.template(.reduce) == "R")
    }
}
