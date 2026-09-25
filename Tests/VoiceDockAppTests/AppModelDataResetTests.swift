// AppModel のデータの初期化の口（PLAN §8.12 の 8・F-95）。ビューは作らない。予約できたら終了し、削除が有効な間は何もしない。
import Foundation
import Synchronization
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDPipeline

@testable import VoiceDockApp

@MainActor
@Suite("AppModel+DataReset（F-95）")
struct AppModelDataResetTests {
    static let fixed = Instant(epochMillis: 1_756_000_000_000)
    static let layout = HomeLayout(root: URL(fileURLWithPath: "/tmp/voicedock-f95-layout", isDirectory: true))

    /// 終了が呼ばれた回数
    final class QuitCounter: Sendable {
        private let count = Mutex(0)
        func hit() { count.withLock { $0 += 1 } }
        var value: Int { count.withLock { $0 } }
    }

    static func snapshot(appEnabled: Bool) -> AppSnapshot {
        var s = AppSnapshot(now: fixed)
        s.configPresent = true
        s.deletion = AppModelDeletionTests.panel(appEnabled: appEnabled, conf: appEnabled ? .enabled : .missing)
        return s
    }

    static func makeModel(_ fake: FakeServices, quit: QuitCounter) -> AppModel {
        AppModel(
            services: fake, openFinder: FakeFinder(), layout: layout, catalog: TestCatalogs.minimal,
            chooser: FakeFolderChooser(nil), fileChooser: FakeFileChooser(nil), presentModal: { $0() },
            sleeper: RecordingSleeper(), now: fixed, quit: { quit.hit() })
    }

    @Test("削除が無効なら、予約を services に 1 回頼み、予約できたら終了する")
    func requestsOnceAndQuitsWhenReserved() async {
        let fake = FakeServices(Self.snapshot(appEnabled: false))
        let quit = QuitCounter()
        let model = Self.makeModel(fake, quit: quit)
        await model.refresh()
        #expect(model.canRequestDataReset == true)
        await model.requestDataReset()
        #expect(fake.dataResetCount == 1)
        #expect(quit.value == 1)
        #expect(model.dataResetFailed == false)
        // 終了の後始末（最大 10 秒）の間にもう一度押させない（レビューの #1）
        #expect(model.dataResetBusy == true)
        #expect(model.canRequestDataReset == false)
        await model.requestDataReset()
        #expect(fake.dataResetCount == 1)
        #expect(quit.value == 1)
    }

    @Test("予約できなければ終了せず、失敗を画面に出す")
    func failureKeepsRunningAndShowsTheError() async {
        let fake = FakeServices(Self.snapshot(appEnabled: false))
        fake.setDataResetResult(false)
        let quit = QuitCounter()
        let model = Self.makeModel(fake, quit: quit)
        await model.refresh()
        await model.requestDataReset()
        #expect(fake.dataResetCount == 1)
        #expect(quit.value == 0)
        #expect(model.dataResetFailed == true)
        // 失敗したら押し直せる
        #expect(model.dataResetBusy == false)
        #expect(model.canRequestDataReset == true)
    }

    @Test("元音声の削除が有効な間（trash が出ている）は押せず、services も終了も呼ばない")
    func deletionEnabledBlocksTheReset() async {
        let fake = FakeServices(Self.snapshot(appEnabled: true))
        let quit = QuitCounter()
        let model = Self.makeModel(fake, quit: quit)
        await model.refresh()
        #expect(model.showsTrash == true)
        #expect(model.canRequestDataReset == false)
        await model.requestDataReset()
        #expect(fake.dataResetCount == 0)
        #expect(quit.value == 0)
    }

    @Test("設定エラー中でも消す能力が残っていれば（residual）押せない")
    func residualCapabilityBlocksTheReset() async {
        var s = AppSnapshot(now: Self.fixed)
        s.configPresent = false
        s.deletionResidual = true
        let fake = FakeServices(s)
        let quit = QuitCounter()
        let model = Self.makeModel(fake, quit: quit)
        await model.refresh()
        #expect(model.canRequestDataReset == false)
        await model.requestDataReset()
        #expect(fake.dataResetCount == 0)
        #expect(quit.value == 0)
    }

    @Test("設定が読めていて削除が無効でも、消す能力が残っていれば（無効化の段の失敗で reaper が残った）押せない")
    func residualWithConfigBlocksTheReset() async {
        var s = Self.snapshot(appEnabled: false)
        s.deletionResidual = true
        let fake = FakeServices(s)
        let quit = QuitCounter()
        let model = Self.makeModel(fake, quit: quit)
        await model.refresh()
        #expect(model.showsTrash == false)
        #expect(model.dataResetBlockedByDeletion == true)
        await model.requestDataReset()
        #expect(fake.dataResetCount == 0)
        #expect(quit.value == 0)
    }

    @Test("予約の失敗の表示はパネルを閉じたら消す（F-84 と同じ）")
    func failureIsClearedWhenThePanelCloses() async {
        let fake = FakeServices(Self.snapshot(appEnabled: false))
        fake.setDataResetResult(false)
        let model = Self.makeModel(fake, quit: QuitCounter())
        await model.refresh()
        await model.requestDataReset()
        #expect(model.dataResetFailed == true)
        model.panelDidClose()
        #expect(model.dataResetFailed == false)
    }

    @Test(
        "起動時の初期化の結果を状態の見出しの下に出す（F-95・レビューの #4）",
        arguments: [
            (DataReset.Outcome.completed(removed: 79, failed: 0), "データを初期化しました（79 件のファイルを消しました）", false),
            (
                DataReset.Outcome.completed(removed: 3, failed: 2),
                "データを初期化しましたが、消せなかったものが 2 件あります。ログを確かめてください", true
            ),
            (
                DataReset.Outcome.refused(.deletionEnabled),
                "データを初期化しませんでした。元音声の削除が有効でした。無効にしてから、もう一度初期化してください", true
            ),
            (
                DataReset.Outcome.refused(.databaseNotRemoved),
                "データを初期化しませんでした。データベースを消せませんでした。ログを確かめてください", true
            ),
            (
                DataReset.Outcome.refused(.requestNotRemoved),
                "データを初期化しませんでした。初期化の予約を取り下げられませんでした。ログを確かめてください", true
            ),
            (DataReset.Outcome.refused(.staleRequest), "前回の初期化の残りの予約を取り下げました（データは消していません）", true),
        ])
    func outcomeNoticeIsShown(_ outcome: DataReset.Outcome, _ text: String, _ warning: Bool) async {
        var s = Self.snapshot(appEnabled: false)
        s.dataReset = outcome
        let model = Self.makeModel(FakeServices(s), quit: QuitCounter())
        await model.refresh()
        #expect(model.dataResetNotice == text)
        #expect(model.dataResetNoticeIsWarning == warning)
    }

    @Test("予約が無ければ結果は出さない（TEST-28）")
    func noNoticeWithoutARequest() async {
        let model = Self.makeModel(FakeServices(Self.snapshot(appEnabled: false)), quit: QuitCounter())
        await model.refresh()
        #expect(model.dataResetNotice == nil)
    }

    @Test("結果は、出したままパネルを閉じたら二度と出さない")
    func noticeIsDismissedWhenThePanelCloses() async {
        var s = Self.snapshot(appEnabled: false)
        s.dataReset = .completed(removed: 1, failed: 0)
        let model = Self.makeModel(FakeServices(s), quit: QuitCounter())
        await model.refresh()
        #expect(model.dataResetNotice != nil)
        model.panelDidClose()
        await model.refresh()
        #expect(model.dataResetNotice == nil)
    }
}
