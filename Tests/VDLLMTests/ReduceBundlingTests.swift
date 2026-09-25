// Reduce の入力の JSON と束ね方が voicedock _as_json / _bundles と同じであること（PLAN §8.5「Map-Reduce」、T-20）。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDLLM

@Suite("ReduceBundling")
struct ReduceBundlingTests {
    static func partial(_ summary: String) -> AnalysisResult {
        AnalysisResult(
            title: nil, summary: summary, keyPoints: [], tasks: [], decisions: [], ideas: [], tags: nil)
    }

    static let five = ["s0", "s1", "s2", "s3", "s4"].map(partial)

    @Test("Reduce の入力の JSON が voicedock と一致")
    func asJSONMatchesVoicedock() {
        let item = AnalysisResult(
            title: nil, summary: "朝/昼\n\"引用\"\t\\\u{1}", keyPoints: ["a"], tasks: [AnalysisTask(text: "x", due: nil)],
            decisions: [], ideas: [], tags: nil)
        let json = ReduceBundling.asJSON([item], schema: LLMFixtures.schema(.partial))
        #expect(
            json
                == #"[{"summary":"朝/昼\n\"引用\"\t\\\u0001","key_points":["a"],"tasks":[{"text":"x","due":null}],"decisions":[],"ideas":[]}]"#
        )
    }

    @Test("無効な節は出さない")
    func asJSONWithDisabledSection() {
        let schema = LLMFixtures.schema(.partial) { $0.ideas.enabled = false }
        let item = AnalysisResult(
            title: nil, summary: "s", keyPoints: [], tasks: [AnalysisTask(text: "a", due: nil)], decisions: [],
            ideas: nil, tags: nil)
        #expect(
            ReduceBundling.asJSON([item], schema: schema)
                == #"[{"summary":"s","key_points":[],"tasks":[{"text":"a","due":null}],"decisions":[]}]"#)
    }

    @Test(
        "束ね方が voicedock と一致",
        arguments: [
            (70, [["s0"], ["s1"], ["s2"], ["s3"], ["s4"]]),
            (141, [["s0", "s1"], ["s2", "s3"], ["s4"]]),
            (142, [["s0", "s1"], ["s2", "s3"], ["s4"]]),
            (212, [["s0", "s1", "s2"], ["s3", "s4"]]),
        ])
    func bundlesMeasured(limit: Int, expected: [[String]]) {
        let schema = LLMFixtures.schema(.partial)
        #expect(TextLimit.scalarCount(ReduceBundling.asJSON(Array(Self.five.prefix(1)), schema: schema)) == 71)
        #expect(TextLimit.scalarCount(ReduceBundling.asJSON(Array(Self.five.prefix(2)), schema: schema)) == 141)
        #expect(TextLimit.scalarCount(ReduceBundling.asJSON(Array(Self.five.prefix(3)), schema: schema)) == 211)
        let bundles = ReduceBundling.bundles(Self.five, schema: schema, limit: limit, itemLimit: nil)
        #expect(bundles.map { $0.map { $0.summary ?? "" } } == expected)
    }

    @Test("並べ替えない")
    func bundlesKeepOrder() {
        let bundles = ReduceBundling.bundles(
            Self.five, schema: LLMFixtures.schema(.partial), limit: 141, itemLimit: nil)
        #expect(bundles.count > 1)
        #expect(bundles.flatMap { $0 }.map { $0.summary ?? "" } == ["s0", "s1", "s2", "s3", "s4"])
    }

    @Test("1 個で超える要素は単独")
    func oversizedItemIsItsOwnBundle() {
        let three = Array(Self.five.prefix(3))
        let bundles = ReduceBundling.bundles(three, schema: LLMFixtures.schema(.partial), limit: 10, itemLimit: nil)
        #expect(bundles.map { $0.map { $0.summary ?? "" } } == [["s0"], ["s1"], ["s2"]])
    }

    @Test("itemLimit を渡すと文字数の余裕があっても件数で区切る（X-43）")
    func bundlesRespectItemLimit() {
        let bundles = ReduceBundling.bundles(
            Self.five, schema: LLMFixtures.schema(.partial), limit: 1_000_000, itemLimit: 2)
        #expect(bundles.map { $0.map { $0.summary ?? "" } } == [["s0", "s1"], ["s2", "s3"], ["s4"]])
    }

    /// golden の partials を中間形で検証する（すべて成功すること）。
    static func goldenPartials(_ item: GoldenCase) throws -> (partials: [AnalysisResult], schema: AnalysisSchema) {
        let config = try GoldenConfig.make(item)
        let partialSchema = AnalysisSchema(
            config: AnalysisConfigView(sections: config.llm.analysis.sections), kind: .partial)
        var partials: [AnalysisResult] = []
        for object in try item.orderedList("partials") {
            switch AnalysisValidator.validate(object, schema: partialSchema) {
            case .success(let result): partials.append(result)
            case .failure(let errors): throw GoldenPartialError.invalid(errors.rendered)
            }
        }
        return (partials, partialSchema)
    }

    enum GoldenPartialError: Error {
        case invalid(String)
    }

    @Test("golden llm_as_json", arguments: try Golden.cases("llm_as_json"))
    func goldenAsJSON(item: GoldenCase) throws {
        let (partials, schema) = try Self.goldenPartials(item)
        GoldenAssert.matches(ReduceBundling.asJSON(partials, schema: schema), group: "llm_as_json", name: item.name)
    }

    @Test("golden llm_bundles", arguments: try Golden.cases("llm_bundles"))
    func goldenBundles(item: GoldenCase) throws {
        let (partials, schema) = try Self.goldenPartials(item)
        let bundles = ReduceBundling.bundles(partials, schema: schema, limit: try item.int("limit"), itemLimit: nil)
        var next: Int64 = 0
        var indices: [GoldenJSON] = []
        for bundle in bundles {
            var group: [GoldenJSON] = []
            for _ in bundle {
                group.append(.integer(next))
                next += 1
            }
            indices.append(.array(group))
        }
        GoldenAssert.matchesJSON(.array(indices), group: "llm_bundles", name: item.name)
    }

    @Test("golden llm_as_json・llm_bundles のケースが在る")
    func goldenBundlingGroupsHaveCases() throws {
        #expect(!(try Golden.cases("llm_as_json")).isEmpty)
        #expect(!(try Golden.cases("llm_bundles")).isEmpty)
    }
}
