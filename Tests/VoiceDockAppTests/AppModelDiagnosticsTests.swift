// AppModel の診断・DR-09・状態の詳細・要対応の操作のテスト（T-32 §5.9）。ビューは作らない。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDPipeline

@testable import VoiceDockApp

@MainActor
@Suite("AppModel+Diagnostics")
struct AppModelDiagnosticsTests {
    static let fixed = Instant(epochMillis: 1_756_000_000_000)
    static let layout = HomeLayout(root: URL(fileURLWithPath: "/tmp/voicedock-t32-layout", isDirectory: true))

    static func present() -> AppSnapshot {
        var s = AppSnapshot(now: fixed)
        s.configPresent = true
        return s
    }

    static func makeModel(
        _ fake: FakeServices, finder: FakeFinder = FakeFinder(), chooser: FakeFolderChooser = FakeFolderChooser(nil)
    ) -> AppModel {
        AppModel(
            services: fake, openFinder: finder, layout: layout, catalog: TestCatalogs.minimal, chooser: chooser,
            fileChooser: FakeFileChooser(nil), presentModal: { $0() }, sleeper: RecordingSleeper(), now: fixed,
            quit: {})
    }

    static func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<5_000 {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    static let r1 = DiagnosticResult(id: "DR-01", status: .ok, label: "設定", details: ["違反はありません"])
    static let r2 = DiagnosticResult(id: "DR-12", status: .notice, label: "ログイン項目", details: ["登録されていません"])
    static let probe = DiagnosticResult(id: "DR-09", status: .ok, label: "LLM の疎通", details: ["test-llm（1.5s）"])

    @Test("診断の結果を出す")
    func runDiagnosticsShowsResults() async {
        let fake = FakeServices(Self.present())
        fake.setDiagnostics([Self.r1, Self.r2])
        let model = Self.makeModel(fake)
        #expect(model.diagnostics == .idle)
        await model.runDiagnostics()
        #expect(model.diagnostics == .done([Self.r1, Self.r2]))
    }

    @Test("実行中は二重に押せない")
    func runDiagnosticsIsNotStartedTwice() async {
        let fake = FakeServices(Self.present())
        fake.setDiagnostics([Self.r1], hold: true)
        let model = Self.makeModel(fake)
        let first = Task { await model.runDiagnostics() }
        #expect(await Self.waitUntil { model.diagnostics == .running })
        await model.runDiagnostics()
        fake.releaseDiagnostics()
        await first.value
        #expect(fake.diagnosticsCount == 1)
        #expect(model.diagnostics == .done([Self.r1]))
    }

    @Test("DR-09 は Worker の仕事として入れ、返事で結果を出す")
    func probeGoesThroughTheWorker() async throws {
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake)
        await model.runLLMProbe()
        #expect(model.probe == .running)
        #expect(fake.jobs.count == 1)
        let job = try #require(fake.jobs.first)
        switch job {
        case .llmProbe(let reply): reply(Self.probe)
        case .backlog, .resolveAbsent: Issue.record("DR-09 の仕事ではない")
        }
        #expect(await Self.waitUntil { model.probe == .done([Self.probe]) })
    }

    @Test("前の世代の返事は捨てる（閉じて押し直した後に届いた古い返事）")
    func staleProbeReplyIsDropped() async throws {
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake)
        await model.runLLMProbe()
        model.panelDidClose()
        await model.runLLMProbe()
        #expect(fake.jobs.count == 2)
        let old = try #require(fake.jobs.first)
        switch old {
        case .llmProbe(let reply): reply(Self.probe)
        case .backlog, .resolveAbsent: Issue.record("DR-09 の仕事ではない")
        }
        for _ in 0..<50 { await Task.yield() }
        #expect(model.probe == .running)
        let fresh = try #require(fake.jobs.last)
        let newer = DiagnosticResult(id: "DR-09", status: .fail, label: "LLM の疎通", details: ["HTTP 500"])
        switch fresh {
        case .llmProbe(let reply): reply(newer)
        case .backlog, .resolveAbsent: Issue.record("DR-09 の仕事ではない")
        }
        #expect(await Self.waitUntil { model.probe == .done([newer]) })
    }

    @Test("システム設定の「ファイルとフォルダ」の URL")
    func privacyURLIsFixed() {
        #expect(
            LiveServices.privacyFilesAndFoldersURL()?.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
    }

    @Test("閉じた後の返事は捨てる")
    func lateProbeReplyIsDropped() async throws {
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake)
        await model.runLLMProbe()
        model.panelDidClose()
        #expect(model.probe == .idle)
        let job = try #require(fake.jobs.first)
        switch job {
        case .llmProbe(let reply): reply(Self.probe)
        case .backlog, .resolveAbsent: Issue.record("DR-09 の仕事ではない")
        }
        for _ in 0..<50 { await Task.yield() }
        #expect(model.probe == .idle)
    }

    @Test("状態の詳細は開いたときだけ読む")
    func detailsLoadsTheReportOnlyWhenOpen() async {
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake)
        await model.toggleDetails()
        #expect(model.detailsExpanded)
        #expect(model.snapshot.statusReport != nil)
        await model.toggleDetails()
        #expect(!model.detailsExpanded)
        #expect(model.snapshot.statusReport == nil)
        #expect(fake.statusReportCount == 1)
    }

    @Test("要対応があればアイコンが要対応になる")
    func attentionSetsTheIcon() async {
        var s = Self.present()
        s.attention = [.diskSpaceLow]
        let fake = FakeServices(s)
        let model = Self.makeModel(fake)
        #expect(!model.hasAttention)
        await model.refresh()
        #expect(model.hasAttention)
        #expect(model.iconState == .attention)
    }

    @Test("7 つの操作をそれぞれの処理へ渡す")
    func performActionsAreRouted() async {
        let fake = FakeServices(Self.present())
        let finder = FakeFinder()
        let chooser = FakeFolderChooser(nil)
        let model = Self.makeModel(fake, finder: finder, chooser: chooser)
        model.perform(.revealConfig)
        #expect(finder.revealed == [Self.layout.configFile])
        model.perform(.reloadConfig)
        #expect(await Self.waitUntil { fake.reloadCount == 1 })
        model.perform(.chooseVault)
        #expect(await Self.waitUntil { chooser.calls == 1 })
        model.perform(.openSystemSettings)
        #expect(fake.openPrivacyCount == 1)
        model.perform(.openModels)
        #expect(model.modelsHighlighted)
        model.perform(.openDeletionFlow)
        #expect(model.deletionHighlighted)
        model.perform(.runDiagnostics)
        #expect(await Self.waitUntil { fake.diagnosticsCount == 1 })
        #expect(model.detailsExpanded)
        #expect(fake.statusReportCount == 1)
        #expect(fake.reloadCount == 1)
        #expect(chooser.calls == 1)
        #expect(finder.revealed.count == 1)
    }
}
