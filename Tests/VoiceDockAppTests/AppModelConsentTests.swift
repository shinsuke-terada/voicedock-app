// 削除の同意の範囲（PLAN §8.9.8・§8.9.9。F-72・issue #112 の G1 と G2）。後追いの実行はプレビューの計画を運び、
// 閉じたらプレビュー・診断の結果を捨てる。ビューは作らない。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDPipeline

@testable import VoiceDockApp

@MainActor
@Suite("AppModel（F-72 削除の同意）")
struct AppModelConsentTests {
    static let fixed = Instant(epochMillis: 1_756_000_000_000)
    static let layout = HomeLayout(root: URL(fileURLWithPath: "/tmp/voicedock-f72-layout", isDirectory: true))
    static let shown = BacklogPlan(eligible: ["a", "c"], skipped: [BacklogSkip(partkey: "b", reason: "not_deletable")])
    static let later = BacklogPlan(eligible: ["a", "c", "d"], skipped: [])
    static let r1 = DiagnosticResult(id: "DR-01", status: .ok, label: "設定", details: ["違反はありません"])

    static func makeModel(_ fake: FakeServices) -> AppModel {
        AppModel(
            services: fake, openFinder: FakeFinder(), layout: layout, catalog: TestCatalogs.minimal,
            chooser: FakeFolderChooser(nil), fileChooser: FakeFileChooser(nil), presentModal: { $0() },
            sleeper: RecordingSleeper(), now: fixed, quit: {})
    }

    static func fake() -> FakeServices {
        var s = AppSnapshot(now: fixed)
        s.configPresent = true
        return FakeServices(s)
    }

    static func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<5_000 {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    /// 返事を届ける Task が走り終わるまで待つ（捨てられたことを確かめる前に）
    static func settle() async {
        for _ in 0..<50 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// n 件目の仕事（無ければ投げる。添字の範囲外でテストの過程を落とさない）
    static func job(_ fake: FakeServices, _ index: Int) throws -> WorkerJob {
        let jobs = fake.jobs
        guard index < jobs.count else { throw ConsentTestError("仕事が " + String(index + 1) + " 件目まで無い") }
        return jobs[index]
    }

    /// n 件目の仕事の preview の返事の口
    static func previewReply(_ fake: FakeServices, _ index: Int) throws
        -> @Sendable (Result<BacklogPlan, BacklogFailure>) -> Void
    {
        guard case .backlog(.preview(let reply)) = try Self.job(fake, index) else {
            throw ConsentTestError("過去分の preview の仕事ではない")
        }
        return reply
    }

    /// プレビューを出したところまで進める（仕事は 1 件）
    static func previewed(_ fake: FakeServices, _ model: AppModel) async throws {
        model.previewBacklog(.backlog)
        #expect(await Self.waitUntil { fake.jobs.count == 1 })
        try Self.previewReply(fake, 0)(.success(Self.shown))
        #expect(await Self.waitUntil { model.backlogState == .preview(.backlog, Self.shown) })
    }

    // MARK: - G1 後追い

    @Test("F-72 実行の仕事はプレビューで見せた計画を運ぶ")
    func executeCarriesThePreviewedPlan() async throws {
        let fake = Self.fake()
        let model = Self.makeModel(fake)
        try await Self.previewed(fake, model)
        model.executeBacklog(.backlog)
        #expect(await Self.waitUntil { fake.jobs.count == 2 })
        guard case .backlog(.execute(let preview, _)) = try Self.job(fake, 1) else {
            Issue.record("過去分の execute の仕事ではない")
            return
        }
        #expect(
            preview == BacklogPlan(eligible: ["a", "c"], skipped: [BacklogSkip(partkey: "b", reason: "not_deletable")]))
    }

    @Test("F-72 パネルを閉じるとプレビューを捨て、実行ボタンを残さない（閉じた後の実行は仕事を入れない）")
    func closingThePanelDropsThePreview() async throws {
        let fake = Self.fake()
        let model = Self.makeModel(fake)
        try await Self.previewed(fake, model)
        model.panelDidClose()
        #expect(model.backlogState == .idle)
        #expect(model.backlogExecuting == false)
        model.executeBacklog(.backlog)
        await Self.settle()
        #expect(model.backlogState == .idle)
        #expect(fake.jobs.count == 1)
    }

    @Test("F-72 閉じる前に頼んだプレビューの返事は、開き直して押し直した後に届いても捨てる")
    func staleReplyAfterReopenIsDropped() async throws {
        let fake = Self.fake()
        let model = Self.makeModel(fake)
        model.previewBacklog(.backlog)
        #expect(await Self.waitUntil { fake.jobs.count == 1 })
        model.panelDidClose()
        model.panelDidOpen()
        model.previewBacklog(.backlog)
        #expect(await Self.waitUntil { fake.jobs.count == 2 })
        try Self.previewReply(fake, 0)(.success(Self.later))
        await Self.settle()
        #expect(model.backlogState == .working(.backlog))
        try Self.previewReply(fake, 1)(.success(Self.shown))
        #expect(await Self.waitUntil { model.backlogState == .preview(.backlog, Self.shown) })
    }

    @Test("F-72 閉じた後に届いた実行の返事は捨てる")
    func executeReplyAfterCloseIsDropped() async throws {
        let fake = Self.fake()
        let model = Self.makeModel(fake)
        try await Self.previewed(fake, model)
        model.executeBacklog(.backlog)
        #expect(await Self.waitUntil { fake.jobs.count == 2 })
        guard case .backlog(.execute(_, let reply)) = try Self.job(fake, 1) else {
            Issue.record("過去分の execute の仕事ではない")
            return
        }
        model.panelDidClose()
        reply(.success(BacklogExecution(previewed: 2, added: 1, done: 2)))
        await Self.settle()
        #expect(model.backlogState == .idle)
    }

    // MARK: - G2 診断

    @Test("F-72 パネルを閉じると診断の結果を捨てる（削除の画面に古い結果を「最新」として出さない）")
    func closingThePanelDropsDiagnostics() async {
        let fake = Self.fake()
        fake.setDiagnostics([Self.r1])
        let model = Self.makeModel(fake)
        await model.runDiagnostics()
        #expect(model.diagnostics == .done([Self.r1]))
        model.panelDidClose()
        #expect(model.diagnostics == .idle)
    }

    @Test("F-72 閉じた後に届いた診断の結果は捨て、開き直して実行し直せば出す")
    func diagnosticsFinishingAfterCloseAreDropped() async {
        let fake = Self.fake()
        fake.setDiagnostics([Self.r1], hold: true)
        let model = Self.makeModel(fake)
        let first = Task { await model.runDiagnostics() }
        #expect(await Self.waitUntil { model.diagnostics == .running })
        model.panelDidClose()
        #expect(model.diagnostics == .idle)
        fake.releaseDiagnostics()
        await first.value
        #expect(model.diagnostics == .idle)
        fake.setDiagnostics([Self.r1])
        await model.runDiagnostics()
        #expect(model.diagnostics == .done([Self.r1]))
    }

    @Test("F-72 結果が 0 件の診断も閉じたら捨てる（TEST-28）")
    func emptyDiagnosticsAreDroppedToo() async {
        let fake = Self.fake()
        fake.setDiagnostics([])
        let model = Self.makeModel(fake)
        await model.runDiagnostics()
        #expect(model.diagnostics == .done([]))
        model.panelDidClose()
        #expect(model.diagnostics == .idle)
    }
}

/// 仕事の形が想定と違う
struct ConsentTestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
