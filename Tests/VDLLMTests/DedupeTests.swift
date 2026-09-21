// Reduce の結果の重複除去が voicedock dedupe と同じであること（PLAN §8.5「Map-Reduce」、T-20）。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDLLM

@Suite("Dedupe")
struct DedupeTests {
    /// §4.2 の実測（voicedock normalize_for_dedupe）。
    static let measured: [(String, String)] = [
        (" VoiceDock ", "voicedock"),
        ("ＶｏｉｃｅＤｏｃｋ", "voicedock"),
        ("VOICEDOCK", "voicedock"),
        ("ﾃｽﾄ", "テスト"),
        ("Straße", "strasse"),
        ("\u{FB01}le", "file"),
        ("\u{FB00}", "ff"),
        ("ΣΑΣ", "σασ"),
        ("\u{01C5}", "d\u{017E}"),
        ("\u{0130}stanbul", "i\u{0307}stanbul"),
        ("\u{3000}全角空白\u{3000}", "全角空白"),
        ("\u{1c}X\u{1f}", "x"),
        ("\u{200b}X", "\u{200b}x"),
    ]

    static let confirm = AnalysisTask(text: "確認する", due: nil)
    static let confirmSpaced = AnalysisTask(text: " 確認する ", due: "2026-09-01")
    static let other = AnalysisTask(text: "別", due: nil)

    static let applyInput = #"""
        {"title":"t","summary":"s","key_points":["A","a"," A ","Ａ"],"tasks":[{"text":"確認する","due":null},\#
        {"text":" 確認する ","due":"2026-09-01"},{"text":"別","due":null}],"decisions":["x"],"ideas":[],\#
        "tags":["VoiceDock","voicedock","Straße","STRASSE","ΣΑΣ","σας"]}
        """#

    /// applyInput に apply をかけた期待値（§5.2 applyMatchesVoicedock）。
    static func expectApplied(_ r: AnalysisResult) {
        #expect(r.title == "t")
        #expect(r.summary == "s")
        #expect(r.keyPoints == ["A"])
        #expect(r.tasks?.count == 2)
        #expect(r.tasks?.map(\.text) == ["確認する", "別"])
        #expect(r.decisions == ["x"])
        #expect(r.ideas == [])
        #expect(r.tags == ["VoiceDock", "Straße", "ΣΑΣ"])
    }

    @Test("正規形が voicedock と一致", arguments: measured)
    func keyMeasured(input: String, expected: String) {
        let actual = Dedupe.key(input)
        #expect(PyText.scalarsEqual(actual, expected), "\(actual.unicodeScalars.map { $0.value })")
    }

    @Test("最初に現れたものを残す")
    func keepsTheFirstOccurrence() {
        #expect(Dedupe.strings(["a", "b", "a", "c", "b"]) == ["a", "b", "c"])
    }

    @Test("NFKC・strip・casefold で比べる")
    func normalizesBeforeComparing() {
        let pairs = [
            (" VoiceDock ", "VoiceDock"), ("ＶｏｉｃｅＤｏｃｋ", "VoiceDock"), ("VOICEDOCK", "voicedock"), ("ﾃｽﾄ", "テスト"),
        ]
        for (left, right) in pairs {
            #expect(Dedupe.strings([left, right]) == [left])
        }
    }

    @Test("曖昧一致しない")
    func doesNotMatchLoosely() {
        #expect(Dedupe.strings(["削除条件を整理した", "削除条件を整理する"]) == ["削除条件を整理した", "削除条件を整理する"])
        #expect(Dedupe.strings(["VoiceDock", "VoiceDock の設計"]) == ["VoiceDock", "VoiceDock の設計"])
    }

    @Test("tasks は text で比べる")
    func tasksAreDedupedByText() {
        #expect(Dedupe.tasks([Self.confirm, Self.confirmSpaced, Self.other]) == [Self.confirm, Self.other])
    }

    @Test("結果全体への適用が voicedock と一致")
    func applyMatchesVoicedock() throws {
        let input = AnalysisResult(
            title: "t", summary: "s", keyPoints: ["A", "a", " A ", "Ａ"],
            tasks: [Self.confirm, Self.confirmSpaced, Self.other], decisions: ["x"], ideas: [],
            tags: ["VoiceDock", "voicedock", "Straße", "STRASSE", "ΣΑΣ", "σας"])
        let applied = Dedupe.apply(input)
        Self.expectApplied(applied)
        #expect(applied.tasks == [Self.confirm, Self.other])
    }

    @Test("無効な節は nil のまま")
    func nilSectionsStayNil() {
        let input = AnalysisResult(
            title: "t", summary: "s", keyPoints: ["a"], tasks: nil, decisions: nil, ideas: nil, tags: nil)
        let applied = Dedupe.apply(input)
        #expect(applied.ideas == nil)
        #expect(applied.tasks == nil)
        #expect(applied.decisions == nil)
        #expect(applied.tags == nil)
    }

    @Test("golden llm_dedupe", arguments: try Golden.cases("llm_dedupe"))
    func goldenDedupe(item: GoldenCase) throws {
        let actual: PyJSONValue
        switch try item.string("kind") {
        case "key":
            actual = .array(try item.strings("inputs").map { .string(Dedupe.key($0)) })
        case "values":
            actual = .array(Dedupe.strings(try item.strings("inputs")).map { .string($0) })
        case "result":
            let config = try GoldenConfig.make(item)
            let finalSchema = AnalysisSchema(
                config: AnalysisConfigView(sections: config.llm.analysis.sections), kind: .final)
            switch AnalysisValidator.validate(try item.orderedObject("payload"), schema: finalSchema) {
            case .success(let result): actual = Dedupe.apply(result).pyJSON(schema: finalSchema)
            case .failure(let errors):
                Issue.record("検証に落ちた: \(errors.rendered)")
                return
            }
        default:
            Issue.record("未知の kind: \(try item.string("kind"))")
            return
        }
        guard let json = GoldenJSON(any: actual.foundationObject) else {
            Issue.record("GoldenJSON にできない")
            return
        }
        GoldenAssert.matchesJSON(json, group: "llm_dedupe", name: item.name)
    }

    @Test("golden llm_dedupe のケースが在る")
    func goldenDedupeHasCases() throws {
        #expect(!(try Golden.cases("llm_dedupe")).isEmpty)
    }
}
