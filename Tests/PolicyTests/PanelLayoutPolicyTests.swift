// パネルの形の静的な約束（T-30 §4.13・F-65）。主画面はスクロールしない。スクロールは別の画面の枠（SubScreen）だけ。
import Foundation
import TestSupport
import Testing

@Suite("PanelLayoutPolicy")
struct PanelLayoutPolicyTests {
    /// スクロールする入れ物（どれか 1 つでも主画面に在れば「スクロールしないと見られない」になる）
    static let scrollingContainers: Set<String> = ["ScrollView", "List", "Form"]
    static let panelView = "VoiceDockApp/Panel/PanelView.swift"
    static let subScreen = "VoiceDockApp/Panel/SubScreen.swift"

    static func identifiers(_ file: SourceFile) -> Set<String> {
        Set(file.tokens.filter { $0.kind == .identifier }.map(\.text))
    }

    @Test("主画面（PanelView.swift）に ScrollView・List・Form が無い")
    func mainScreenDoesNotScroll() throws {
        let file = try #require(try SourceTree.load().first { $0.relativePath == Self.panelView })
        let ids = Self.identifiers(file)
        // 空振りしない: 主画面の中身を実際に並べていること
        #expect(ids.contains("VStack"))
        #expect(ids.contains("StatusSection"))
        #expect(ids.intersection(Self.scrollingContainers).sorted() == [])
    }

    @Test("パネルの中で ScrollView を使ってよいのは SubScreen.swift だけ")
    func onlySubScreenScrolls() throws {
        let files = try SourceTree.load().filter { $0.relativePath.hasPrefix("VoiceDockApp/Panel/") }
        #expect(files.count >= 2)
        // 陽性対照: SubScreen は ScrollView を持つ（語の取り出しが効いている）
        let sub = try #require(files.first { $0.relativePath == Self.subScreen })
        #expect(Self.identifiers(sub).contains("ScrollView"))
        let offenders = files.filter { $0.relativePath != Self.subScreen }
            .filter { !Self.identifiers($0).intersection(Self.scrollingContainers).isEmpty }
            .map(\.relativePath)
        #expect(offenders == [])
    }
}
