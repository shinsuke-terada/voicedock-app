// パネルの中の画面の切り替え（T-30 §4.11b・F-65）。ビューは作らない。AppModel.screen と状態の詳細の読み書きを見る。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDPipeline

@testable import VoiceDockApp

@MainActor
@Suite("AppModel+Navigation")
struct AppModelNavigationTests {
    static let fixed = Instant(epochMillis: 1_756_000_000_000)
    static let layout = HomeLayout(root: URL(fileURLWithPath: "/tmp/voicedock-f65-layout", isDirectory: true))

    static func present() -> AppSnapshot {
        var s = AppSnapshot(now: fixed)
        s.configPresent = true
        return s
    }

    static func makeModel(_ fake: FakeServices) -> AppModel {
        AppModel(
            services: fake, openFinder: FakeFinder(), layout: layout, catalog: TestCatalogs.minimal,
            chooser: FakeFolderChooser(nil), fileChooser: FakeFileChooser(nil), presentModal: { $0() },
            sleeper: RecordingSleeper(), now: fixed, quit: {})
    }

    static func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<5_000 {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    @Test("TEST-28 何もしなければ主画面で、状態の詳細は読まない")
    func startsOnTheMainScreen() {
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake)
        #expect(model.screen == .main)
        #expect(model.detailsExpanded == false)
        #expect(fake.statusReportCount == 0)
    }

    @Test("「詳細・診断」に入ると状態の詳細を 1 回読み、戻ると捨てる")
    func detailsScreenLoadsAndDropsTheReport() async {
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake)
        await model.show(.details)
        #expect(model.screen == .details)
        #expect(model.detailsExpanded)
        #expect(model.snapshot.statusReport != nil)
        #expect(fake.statusReportCount == 1)
        await model.show(.main)
        #expect(model.screen == .main)
        #expect(model.detailsExpanded == false)
        #expect(model.snapshot.statusReport == nil)
        #expect(fake.statusReportCount == 1)
    }

    @Test("「詳細・診断」以外の画面では状態の詳細を読まない")
    func otherScreensDoNotLoadTheReport() async {
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake)
        for screen in [PanelScreen.attention, .deletion, .settings, .main] {
            await model.show(screen)
            #expect(model.screen == screen)
        }
        #expect(model.detailsExpanded == false)
        #expect(fake.statusReportCount == 0)
    }

    @Test("「詳細・診断」から別の画面へ直接移っても状態の詳細を捨てる")
    func leavingDetailsForAnotherScreenDropsTheReport() async {
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake)
        await model.show(.details)
        await model.show(.deletion)
        #expect(model.screen == .deletion)
        #expect(model.detailsExpanded == false)
        #expect(model.snapshot.statusReport == nil)
    }

    @Test("パネルを閉じたら次は主画面から（状態の詳細も捨てる）")
    func closingThePanelReturnsToMain() async {
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake)
        await model.show(.details)
        model.panelDidClose()
        #expect(model.screen == .main)
        #expect(model.detailsExpanded == false)
        #expect(model.snapshot.statusReport == nil)
    }

    @Test("要対応の「有効化フローを開く」は「元音声の削除」の画面へ、「モデルの節を開く」は主画面へ")
    func attentionActionsNavigate() async {
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake)
        model.perform(.openDeletionFlow)
        #expect(await Self.waitUntil { model.screen == .deletion })
        #expect(model.deletionHighlighted)
        model.perform(.openModels)
        #expect(await Self.waitUntil { model.screen == .main })
        #expect(model.modelsHighlighted)
    }

    @Test("要対応の「診断を実行」は「詳細・診断」の画面へ移ってから診断する")
    func runDiagnosticsOpensTheDetailsScreen() async {
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake)
        model.perform(.runDiagnostics)
        #expect(await Self.waitUntil { fake.diagnosticsCount == 1 })
        #expect(model.screen == .details)
        #expect(model.detailsExpanded)
        #expect(fake.statusReportCount == 1)
    }

    @Test("画面は 5 つ（主画面・要対応・元音声の削除・詳細・診断・設定）")
    func fiveScreens() {
        #expect(PanelScreen.allCases.map(\.rawValue) == ["main", "attention", "deletion", "details", "settings"])
    }
}
