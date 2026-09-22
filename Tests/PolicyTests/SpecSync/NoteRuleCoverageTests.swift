// 保存検証 RN / DN の SPEC S12 の ID と、テストの表示名の先頭の ID の集合の一致（issue #18。PLAN §10.3・F-68。T-28 §8）。
// 表示名は `RN-5 / DN-6 session_key が違う` のように、先頭に ID を ` / ` で並べてよい（Raw と Daily の同じ規則を 1 本で見るため）。
import Foundation
import TestSupport
import Testing

/// 表示名の先頭の RN / DN の ID を集める。
enum NoteRuleNameIndex {
    /// 先頭の ID の並び（` / ` 区切り）の後は空白か終わり。
    static let pattern = "^((?:RN|DN)-[0-9]+(?: / (?:RN|DN)-[0-9]+)*)(?: |$)"

    /// 1 つのソースの `@Test("…")` の表示名から集める。
    static func ids(in text: String) -> [String] {
        let scanned = SourceScanner.scan(text)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return scanned.literals.flatMap { literal -> [String] in
            guard TestNameIndex.isTestDisplayName(literal, in: scanned.code) else { return [] }
            let raw = literal.raw
            let range = NSRange(location: 0, length: raw.utf16.count)
            guard let match = regex.firstMatch(in: raw, range: range), let head = Range(match.range(at: 1), in: raw)
            else { return [] }
            return raw[head].components(separatedBy: " / ")
        }
    }

    /// `Tests/` 配下の全 `.swift` から集める。
    static func load() throws -> Set<String> {
        let root = PackageRoot.file("Tests")
        guard let enumerator = FileManager.default.enumerator(atPath: root.path(percentEncoded: false)) else {
            return []
        }
        var result: Set<String> = []
        for case let path as String in enumerator where path.hasSuffix(".swift") {
            result.formUnion(ids(in: try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)))
        }
        return result
    }
}

@Suite("NoteRuleCoverage")
struct NoteRuleCoverageTests {
    @Test("SPEC S12 の RN / DN の ID の集合とテストの表示名の ID の集合が一致する")
    func noteRulesAreCovered() throws {
        let spec = try SpecDocument.load()
        let specIDs = Set(try SpecNoteKind.allCases.flatMap { try spec.noteRules($0) })
        #expect(!specIDs.isEmpty)
        let testIDs = try NoteRuleNameIndex.load()
        #expect(
            specIDs == testIDs,
            "SPEC だけ \(specIDs.subtracting(testIDs).sorted())、テストだけ \(testIDs.subtracting(specIDs).sorted())")
    }

    @Test("表示名の先頭の ID の並びを読み、文中の ID と @Test でない文字列は拾わない")
    func nameIndexReadsLeadingIDs() {
        let source = """
            @Test("RN-5 / DN-6 session_key が違う") func a() {}
            @Test("DN-9 リンクが要る") func b() {}
            @Test("Raw に DN-5 は無い") func c() {}
            let note = "RN-1 これはテスト名ではない"
            @Test("RN-2/DN-2 区切りが違う") func d() {}
            """
        #expect(NoteRuleNameIndex.ids(in: source) == ["RN-5", "DN-6", "DN-9"])
        #expect(NoteRuleNameIndex.ids(in: "") == [])
    }
}
