// テストの表示名の ID が SPEC の表に在ること、有効にした種類では集合が一致することの検査（PLAN §10.3。T-05）。
import TestSupport
import Testing

@Suite("SpecCoverage")
struct SpecCoverageTests {
    @Test("テストの表示名の ID はすべて SPEC の表の生きた ID")
    func testIDsExistInSpec() throws {
        let spec = try SpecDocument.load()
        var live: Set<String> = []
        for kind in SpecIDKind.allCases { live.formUnion(try spec.ids(kind)) }
        for entry in try TestNameIndex.load() {
            #expect(live.contains(entry.id), "\(entry.path) の \(entry.id) は SPEC の表に無い")
        }
    }

    @Test("有効にした種類では SPEC の ID の集合とテストの ID の集合が一致する")
    func activatedKindsMatchSpec() throws {
        let spec = try SpecDocument.load()
        let entries = try TestNameIndex.load()
        for kind in SpecCoverage.activated {
            let specIDs = Set(try spec.ids(kind))
            let testIDs = Set(entries.map(\.id).filter { $0.hasPrefix(kind.rawValue + "-") })
            #expect(
                specIDs == testIDs,
                "\(kind.rawValue): SPEC だけ \(specIDs.subtracting(testIDs).sorted())、テストだけ \(testIDs.subtracting(specIDs).sorted())"
            )
        }
    }

    @Test("ND を有効にしたら、各 ND の層ごとに 1 本以上のテストがある")
    func ndLayersAreCovered() throws {
        guard SpecCoverage.activated.contains(.nd) else { return }
        let spec = try SpecDocument.load()
        let entries = try TestNameIndex.load().filter { $0.id.hasPrefix("ND-") }
        for (id, layers) in try spec.ndLayers() {
            for layer in layers {
                #expect(entries.contains { $0.id == id && $0.layer == layer }, "\(id) [\(layer)] のテストが無い")
            }
        }
    }

    @Test("有効にした種類は .cv・.dr・.nd を含む（外すと集合の一致の検査が黙って止まる。T-39）")
    func activatedKeepsTheCheckedKinds() {
        #expect(SpecCoverage.activated.isSuperset(of: [.cv, .dr, .nd]))
    }
}
