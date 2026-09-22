// パネルの中の画面（PanelScreen）と docs/SPEC.md S20（PLAN §8.12 の節と画面の表）の照合（T-30 §8。SPEC 同期は issue #18 で足した。PLAN F-68）。
import TestSupport
import Testing

@testable import VoiceDockApp

@Suite("PanelScreen")
struct PanelScreenTests {
    @Test("PanelScreen は main と SPEC S20 の画面の列の case だけ")
    func screensMatchSpec() throws {
        let sections = try SpecDocument.load().panelSections()
        #expect(sections.map(\.number) == Array(1...9))
        let screens = sections.compactMap(\.screen)
        #expect(!screens.isEmpty)
        #expect(Set(screens).count == screens.count)
        #expect(Set(PanelScreen.allCases.map(\.rawValue)) == Set(["main"] + screens))
        #expect(PanelScreen.allCases.count == screens.count + 1)
    }
}
