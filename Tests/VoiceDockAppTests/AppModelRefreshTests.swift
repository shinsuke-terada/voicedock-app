// AppModel の読み直しの順と鮮度（F-84・issue #119 の G7・G8・G12）。ビューは作らない。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDPipeline

@testable import VoiceDockApp

@MainActor
@Suite("AppModel の読み直し（F-84）")
struct AppModelRefreshTests {
    static let t = Instant(epochMillis: 1_787_955_153_000)

    /// 削除が有効な観測（trash が出る）
    static func enabled() -> AppSnapshot {
        var s = AppModelTests.present()
        s.deletion = AppModelTests.deletionOn
        return s
    }

    /// 削除が無効な観測（trash が出ない）
    static func disabled() -> AppSnapshot {
        var s = AppModelTests.present()
        s.deletion = AppModelDeletionTests.panel(appEnabled: false, conf: .disabled)
        return s
    }

    /// 状態の詳細（件数だけを変えて見分ける）
    static func report(undeletable: Int) -> StatusReport {
        var r = FakeServices.emptyReport
        r.undeletableTotal = undeletable
        return r
    }

    // MARK: G7 refresh の世代

    @Test("F-84 後から始まった refresh の結果を先に入れたら、前に始まった refresh の古い結果で戻さない")
    func staleRefreshDoesNotOverwriteNewerOne() async {
        let fake = FakeServices(Self.enabled())
        let model = AppModelTests.makeModel(fake)
        fake.holdNextReads(1)
        let stale = Task { await model.refresh() }
        #expect(await AppModelTests.waitUntil { fake.heldReadCount == 1 })
        fake.set(Self.disabled())
        await model.refresh()
        #expect(model.showsTrash == false)
        fake.releaseReads()
        await stale.value
        #expect(model.showsTrash == false)
        #expect(model.deletion == AppModelDeletionTests.panel(appEnabled: false, conf: .disabled))
    }

    @Test("F-84 無効化の直後に、その前に始まった周期の読み込みが後から終わっても「有効」に戻して見せない")
    func disableIsNotUndoneByAnEarlierRead() async {
        let fake = FakeServices(Self.enabled())
        let model = AppModelTests.makeModel(fake)
        await model.refresh()
        #expect(model.showsTrash == true)
        // 周期の読み込みが「有効」を読んで止まっている間に無効化が終わる
        fake.holdNextReads(1)
        let periodic = Task { await model.refresh() }
        #expect(await AppModelTests.waitUntil { fake.heldReadCount == 1 })
        fake.set(Self.disabled())
        _ = await model.disableDeletion()
        #expect(model.showsTrash == false)
        fake.releaseReads()
        await periodic.value
        #expect(model.showsTrash == false)
        #expect(model.showsDisableButton == false)
    }

    @Test("F-84 捨てる古い結果が観測した最終接続は引き継ぐ（新しい結果がデバイスを観測していないとき）")
    func staleReadStillCarriesLastConnected() async {
        var connected = AppModelTests.present()
        connected.device = LastConnectedTests.snapshot(at: Self.t, ids: ["MIC-A"])
        connected.lastConnectedAt = Self.t
        var gone = AppModelTests.present()
        gone.device = LastConnectedTests.snapshot(at: Self.t.adding(seconds: 60), ids: [])
        let fake = FakeServices(connected)
        let model = AppModelTests.makeModel(fake)
        fake.holdNextReads(1)
        let stale = Task { await model.refresh() }
        #expect(await AppModelTests.waitUntil { fake.heldReadCount == 1 })
        fake.set(gone)
        await model.refresh()
        #expect(model.snapshot.lastConnectedAt == nil)
        fake.releaseReads()
        await stale.value
        // 接続中の表示には戻さず、最終接続の時刻だけを残して ui-state.json に書く
        #expect(model.snapshot.device?.devices.isEmpty == true)
        #expect(model.snapshot.lastConnectedAt == Self.t)
        #expect(fake.savedStates.map(\.lastConnectedAt) == [Self.t])
    }

    @Test("F-84 先に始まった read が最終接続を書いた後に、その前のファイルを読んだ read が入っても、「今はしない」の後もファイルに残る（F-70）")
    func laterReadWithOldFileKeepsWrittenLastConnected() async throws {
        let tmp = try TempDirectory()
        defer { tmp.remove() }
        let store = AppModelLastConnectedTests.store(tmp)
        var connected = AppModelTests.present()
        connected.device = LastConnectedTests.snapshot(at: Self.t, ids: ["MIC-A"])
        var gone = AppModelTests.present()
        gone.device = LastConnectedTests.snapshot(at: Self.t.adding(seconds: 60), ids: [])
        let fake = FakeServices(connected, uiStore: store)
        let model = AppModelTests.makeModel(fake)
        // read k がデバイスを観測して止まる → read j がまだ最終接続の無いファイルを読んで止まる
        fake.holdNextReads(2)
        let k = Task { await model.refresh() }
        #expect(await AppModelTests.waitUntil { fake.heldReadCount == 1 })
        fake.set(gone)
        let j = Task { await model.refresh() }
        #expect(await AppModelTests.waitUntil { fake.heldReadCount == 2 })
        // k が先に終わって t を書く
        fake.releaseOldestRead()
        await k.value
        #expect(store.load().lastConnectedAt == Self.t)
        // 後から始まった j は、古い uiState のまま入る（j のほうが新しい観測なので捨てない）
        fake.releaseReads()
        await j.value
        #expect(model.snapshot.uiState.lastConnectedAt == nil)
        // その後の「今はしない」は、この起動で書いた t をファイルに残す
        await model.dismissLoginItem()
        let file = store.load()
        #expect(file.loginItemDecided == true)
        #expect(file.lastConnectedAt == Self.t)
    }

    @Test("F-84 新しい結果がデバイスを観測していれば、古い結果の最終接続で書き換えない")
    func staleReadDoesNotReplaceConnectedTime() async {
        var old = AppModelTests.present()
        old.device = LastConnectedTests.snapshot(at: Self.t, ids: ["MIC-A"])
        old.lastConnectedAt = Self.t
        let later = Self.t.adding(seconds: 600)
        var now = AppModelTests.present()
        now.device = LastConnectedTests.snapshot(at: later, ids: ["MIC-A"])
        now.lastConnectedAt = later
        let fake = FakeServices(old)
        let model = AppModelTests.makeModel(fake)
        fake.holdNextReads(1)
        let stale = Task { await model.refresh() }
        #expect(await AppModelTests.waitUntil { fake.heldReadCount == 1 })
        fake.set(now)
        await model.refresh()
        fake.releaseReads()
        await stale.value
        #expect(model.snapshot.lastConnectedAt == later)
        #expect(fake.savedStates.map(\.lastConnectedAt) == [later])
    }

    // MARK: G8 状態の詳細の読み直し

    /// Worker の今の工程を差し替えた観測（再試行の後に Worker が遅れて DB を書き換える様子を作る）
    static func working(_ activity: WorkerActivity) -> AppSnapshot {
        var s = AppModelTests.present()
        s.worker = WorkerStatus(activity: activity, paused: [])
        return s
    }

    @Test("F-84 再試行の後は、Worker が要求を片付けて idle に戻った後の refresh で状態の詳細を読み直す（すぐには読まない）")
    func retryReloadsAfterWorkerReturnsToIdle() async {
        let fake = FakeServices(Self.working(.idle))
        let model = AppModelTests.makeModel(fake)
        await model.show(.details)
        #expect(fake.statusReportCount == 1)
        // requeue は要求を積むだけ。直後の refresh はまだ前の DB（Worker は tick を始めていない）
        await model.requeueManual()
        #expect(fake.requeueCount == 1)
        #expect(fake.statusReportCount == 1)
        // Worker が tick を始め、再試行した Part を処理している間は読まない
        fake.set(Self.working(.transcribing(partkey: "20260829/DJI_01_20260829_071200_orig.wav", startedAt: "x")))
        await model.refresh()
        #expect(fake.statusReportCount == 1)
        // 処理を終えて DB を書き換え、idle に戻った後の最初の refresh で読み直す
        fake.setStatusReport(Self.report(undeletable: 3))
        fake.set(Self.working(.idle))
        await model.refresh()
        #expect(fake.statusReportCount == 2)
        #expect(model.snapshot.statusReport?.undeletableTotal == 3)
        // 読み直したら印を下ろす（その後の周期の refresh では読まない）
        await model.refresh()
        #expect(fake.statusReportCount == 2)
    }

    @Test("F-84 再試行の後に Worker がすぐ片付けても（処理中を観測しなくても）、次の refresh で読み直す")
    func retryReloadsOnTheNextRefreshWhenWorkerWasQuick() async {
        let fake = FakeServices(Self.working(.idle))
        let model = AppModelTests.makeModel(fake)
        await model.show(.details)
        await model.requeueManual()
        #expect(fake.statusReportCount == 1)
        fake.setStatusReport(Self.report(undeletable: 4))
        await model.refresh()
        #expect(fake.statusReportCount == 2)
        #expect(model.snapshot.statusReport?.undeletableTotal == 4)
    }

    @Test("F-84 再試行の後、読み直す前に「詳細・診断」を出たら読み直さない")
    func leavingDetailsCancelsTheRetryReload() async {
        let fake = FakeServices(Self.working(.idle))
        let model = AppModelTests.makeModel(fake)
        await model.show(.details)
        await model.requeueManual()
        await model.show(.main)
        await model.refresh()
        #expect(fake.statusReportCount == 1)
        #expect(model.snapshot.statusReport == nil)
        // 入り直したら入ったときに 1 回読むだけ（前の再試行の待ちは残っていない）
        await model.show(.details)
        await model.refresh()
        #expect(fake.statusReportCount == 2)
    }

    @Test("F-84 「詳細・診断」の画面で設定を読み直したら状態の詳細を読み直す")
    func reloadConfigReloadsStatusReport() async {
        let fake = FakeServices(AppModelTests.present())
        fake.setReload(.valid(AppConfig.defaults(timeZone: "UTC")))
        let model = AppModelTests.makeModel(fake)
        await model.show(.details)
        fake.setStatusReport(Self.report(undeletable: 2))
        await model.reloadConfig()
        #expect(model.reloadResult == .ok)
        #expect(fake.statusReportCount == 2)
        #expect(model.snapshot.statusReport?.undeletableTotal == 2)
    }

    @Test("F-84 後追いの実行の返事が来たら状態の詳細を読み直す")
    func backlogExecutionReloadsStatusReport() async throws {
        let fake = FakeServices(AppModelTests.present())
        let model = AppModelTests.makeModel(fake)
        await model.show(.details)
        #expect(fake.statusReportCount == 1)
        model.previewBacklog(.backlog)
        #expect(await AppModelTests.waitUntil { fake.jobs.count == 1 })
        guard case .backlog(.preview(let previewReply)) = try #require(fake.jobs.first) else {
            Issue.record("過去分の preview の仕事ではない")
            return
        }
        previewReply(.success(AppModelBacklogTests.plan))
        #expect(await AppModelTests.waitUntil { model.backlogState == .preview(.backlog, AppModelBacklogTests.plan) })
        // プレビューだけでは DB は変わらないので読み直さない
        #expect(fake.statusReportCount == 1)
        model.executeBacklog(.backlog)
        #expect(await AppModelTests.waitUntil { fake.jobs.count == 2 })
        guard case .backlog(.execute(_, let executeReply)) = try #require(fake.jobs.last) else {
            Issue.record("過去分の execute の仕事ではない")
            return
        }
        fake.setStatusReport(Self.report(undeletable: 1))
        executeReply(.success(BacklogExecution(previewed: 1, added: 0, done: 1)))
        #expect(await AppModelTests.waitUntil { model.snapshot.statusReport?.undeletableTotal == 1 })
        #expect(fake.statusReportCount == 2)
    }

    @Test("F-84 「詳細・診断」にいなければ、操作の後も状態の詳細を読まない（0 回。TEST-28）")
    func noReloadOutsideDetails() async {
        let fake = FakeServices(AppModelTests.present())
        let model = AppModelTests.makeModel(fake)
        await model.requeueManual()
        await model.reloadConfig()
        #expect(fake.statusReportCount == 0)
        #expect(model.snapshot.statusReport == nil)
    }

    @Test("F-84 状態の詳細の読み込みが重なったら、後から始まった読み込みの結果を残す")
    func staleStatusReportIsDropped() async {
        let fake = FakeServices(AppModelTests.present())
        let model = AppModelTests.makeModel(fake)
        fake.setStatusReport(Self.report(undeletable: 5))
        fake.holdNextStatusReports(1)
        let entering = Task { await model.show(.details) }
        #expect(await AppModelTests.waitUntil { fake.heldStatusReportCount == 1 })
        fake.setStatusReport(Self.report(undeletable: 7))
        await model.reloadConfig()
        #expect(model.snapshot.statusReport?.undeletableTotal == 7)
        fake.releaseStatusReports()
        await entering.value
        #expect(model.snapshot.statusReport?.undeletableTotal == 7)
    }

    // MARK: G12 ツールチップ

    @Test("F-84 アイコンが同じでも状態の 1 行が変われば、ツールチップの書き直しを知らせる（同じなら知らせない）")
    func statusLineChangesAreNotified() async {
        var copying = AppModelTests.present()
        copying.ingestActivity = IngestActivity(
            scanning: true, deviceID: "MIC-A", copied: 1, total: 3, lastActivityAt: nil)
        let fake = FakeServices(copying)
        let model = AppModelTests.makeModel(fake)
        let lines = model.statusLineChanges
        let icons = model.iconChanges
        await model.refresh()
        #expect(model.statusLine == "MIC-A から取り込み中 1/3 — コピーが終われば抜いて大丈夫です")
        await model.refresh()
        copying.ingestActivity = IngestActivity(
            scanning: true, deviceID: "MIC-A", copied: 2, total: 3, lastActivityAt: nil)
        fake.set(copying)
        await model.refresh()
        #expect(model.statusLine == "MIC-A から取り込み中 2/3 — コピーが終われば抜いて大丈夫です")
        model.stop()
        var lineCount = 0
        for await _ in lines { lineCount += 1 }
        var iconCount = 0
        for await _ in icons { iconCount += 1 }
        // 1 回目（設定エラーの行 → 1/3）と 3 回目（1/3 → 2/3）。アイコンは 1 回目に待機中 → 取り込み中の 1 回だけ
        #expect(lineCount == 2)
        #expect(iconCount == 1)
    }
}
