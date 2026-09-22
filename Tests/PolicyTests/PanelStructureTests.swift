// 主画面の節の並びと docs/SPEC.md S20（PLAN §8.12 の節と画面の表）の照合（T-30 §8。SPEC 同期は issue #18 で足した。PLAN F-68）。
// PanelView.swift の `var main` の中で、各節を表す語が最初に出る位置の順を見る（コードを動かさずに並びを固定する）。
import Foundation
import TestSupport
import Testing

@Suite("PanelStructure")
struct PanelStructureTests {
    static let panelView = "VoiceDockApp/Panel/PanelView.swift"

    /// S20 の「節」の列 → 主画面でその節を表す語（型名か Strings の項目名）。S20 に主画面の行を足したらここにも足す。
    static let markers: [String: String] = [
        "状態": "StatusSection", "要対応": "AttentionSection", "はじめに": "OnboardingSection",
        "保存先（Vault）": "VaultSection", "モデル": "ModelsSection", "元音声の削除": "rowDeletion",
        "詳細・診断": "rowDetails", "終了": "buttonQuit",
    ]

    /// `var main` より後の識別子（主画面の中身）。
    static func mainIdentifiers() throws -> [String] {
        let file = try #require(try SourceTree.load().first { $0.relativePath == panelView })
        let ids = file.tokens.filter { $0.kind == .identifier }.map(\.text)
        let start = try #require(
            ids.indices.first { ids[$0] == "var" && $0 + 1 < ids.count && ids[$0 + 1] == "main" }, "var main が無い")
        return Array(ids[(start + 2)...])
    }

    @Test("主画面の節の並びが SPEC S20 の主画面の行の順と同じ")
    func mainOrderMatchesSpec() throws {
        let onMain = try SpecDocument.load().panelSections().filter(\.onMain).map(\.title)
        #expect(!onMain.isEmpty)
        #expect(Set(onMain) == Set(Self.markers.keys), "S20 の主画面の行と語の対応表が食い違う")
        let ids = try Self.mainIdentifiers()
        var positions: [(title: String, index: Int)] = []
        for title in onMain {
            let marker = try #require(Self.markers[title])
            let index = try #require(ids.firstIndex(of: marker), "主画面に \(marker)（S20 の \(title)）が無い")
            positions.append((title, index))
        }
        #expect(positions.sorted { $0.index < $1.index }.map(\.title) == onMain)
    }
}
