// 全設定キーに「振る舞いのテスト」（表示名が `CE <keyPath> `）があるか、書く予定のチケットが決まっているか（PLAN §6.2・CR-14。T-09）。
import Foundation
import TestSupport
import Testing
import VDCore

@Suite("ConfigEffect coverage")
struct ConfigEffectCoverageTests {
    /// 振る舞いテストの印（文字列リテラルの先頭）。
    static let pattern = "^CE ([A-Za-z0-9_.]+) "

    /// 文字列リテラルの一覧から `CE <keyPath> ` のキーパスを集める（コメントの中は拾わない）。
    static func coveredKeys(in literals: [StringLiteral]) throws -> Set<String> {
        let regex = try NSRegularExpression(pattern: pattern)
        var keys: Set<String> = []
        for literal in literals {
            let raw = literal.raw
            guard let match = regex.firstMatch(in: raw, range: NSRange(location: 0, length: raw.utf16.count)),
                let range = Range(match.range(at: 1), in: raw)
            else { continue }
            keys.insert(String(raw[range]))
        }
        return keys
    }

    @Test("全キーに CE テストがあるか、予定のチケットが決まっている（CR-14）")
    func everyKeyIsCoveredOrPending() throws {
        var covered: Set<String> = []
        for file in try SourceTree.load(root: PackageRoot.file("Tests")) {
            covered.formUnion(try Self.coveredKeys(in: file.scanned.literals))
        }
        let all = Set(ConfigKeys.allKeyPaths)
        let pending = Set(ConfigEffectPending.owners.keys)
        #expect(covered.isSubset(of: all), "知らないキーの CE テスト: \(covered.subtracting(all).sorted())")
        #expect(pending.isSubset(of: all), "知らないキーが pending にある: \(pending.subtracting(all).sorted())")
        #expect(
            covered.intersection(pending).isEmpty,
            "テストがあるのに pending に残っている: \(covered.intersection(pending).sorted())")
        #expect(
            covered.union(pending) == all, "誰も持っていないキー: \(all.subtracting(covered.union(pending)).sorted())")
    }

    @Test("CE の印を拾える（検査自体の陽性対照）")
    func extractorFindsCELiterals() throws {
        let source = #"@Test("CE device.mountMode x") func a() {}"# + "\n" + #"// @Test("CE vault.path x")"# + "\n"
        #expect(try Self.coveredKeys(in: SourceScanner.scan(source).literals) == ["device.mountMode"])
        #expect(try Self.coveredKeys(in: SourceScanner.scan("").literals).isEmpty)
    }
}
