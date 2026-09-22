// AppModel の「元音声の削除」の口（T-40 §4.5）。ビューは作らない。押したら services に渡り、結果が画面の値になる。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice
import VDPipeline

@testable import VoiceDockApp

@MainActor
@Suite("AppModel+Deletion")
struct AppModelDeletionTests {
    static let fixed = Instant(epochMillis: 1_756_000_000_000)
    static let layout = HomeLayout(root: URL(fileURLWithPath: "/tmp/voicedock-t40-layout", isDirectory: true))

    static func present(deletion: DeletionPanelState? = nil) -> AppSnapshot {
        var s = AppSnapshot(now: fixed)
        s.configPresent = true
        s.deletion = deletion
        return s
    }

    static func panel(appEnabled: Bool, conf: LockDisplay.ConfState) -> DeletionPanelState {
        DeletionPanelState(
            display: LockDisplay(
                appEnabled: appEnabled, confState: conf, reaper: .notInstalled, mountMode: appEnabled ? "rw" : "ro",
                devices: [], readiness: .disabled(DeletionReason.deleteSourceAudioDisabled)),
            deleteSkippedSource: false)
    }

    static func makeModel(_ fake: FakeServices) -> AppModel {
        AppModel(
            services: fake, openFinder: FakeFinder(), layout: layout, catalog: TestCatalogs.minimal,
            chooser: FakeFolderChooser(nil), fileChooser: FakeFileChooser(nil), presentModal: { $0() },
            sleeper: RecordingSleeper(), now: fixed, quit: {})
    }

    @Test("有効化は入力をそのまま services に渡し、成功したら挿し直しの案内を出す")
    func enablePassesTheInputAndShowsTheReinsertNotice() async {
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake)
        let r = await model.enableDeletion(confirmation: " enable ")
        #expect(fake.enableConfirmations == [" enable "])
        guard case .success = r else {
            Issue.record("成功しなかった")
            return
        }
        #expect(model.deletionNotice == "読み書きできるようになるのはデバイスを挿し直した後です")
        #expect(model.enableError == nil)
        // 操作の後に読み直す
        #expect(fake.readCount == 1)
    }

    @Test("有効化の失敗は enableError に残り、案内は出さない")
    func enableFailureIsKept() async {
        let fake = FakeServices(Self.present())
        fake.setEnableResult(.failure(.notConfirmed))
        let model = Self.makeModel(fake)
        _ = await model.enableDeletion(confirmation: "y")
        #expect(model.enableError == .notConfirmed)
        #expect(model.deletionNotice == nil)
    }

    @Test("根拠 B は入力をそのまま services に渡す")
    func enableSkippedPassesTheInput() async {
        let fake = FakeServices(Self.present())
        fake.setEnableResult(.failure(.config([])))
        let model = Self.makeModel(fake)
        _ = await model.enableSkippedDeletion(confirmation: "ENABLE")
        #expect(fake.skippedConfirmations == ["ENABLE"])
        #expect(fake.enableConfirmations == [])
        #expect(model.enableError == .config([]))
    }

    @Test("無効化は確認なしで services を 1 回呼び、失敗した段をそのまま持つ")
    func disableCallsServicesOnceAndKeepsTheStages() async {
        let fake = FakeServices(Self.present())
        fake.setDisableResult(["reaper_conf", "remount"])
        let model = Self.makeModel(fake)
        _ = await model.enableDeletion(confirmation: "ENABLE")
        let failed = await model.disableDeletion()
        #expect(fake.disableCount == 1)
        #expect(failed == ["reaper_conf", "remount"])
        #expect(model.disableFailedStages == ["reaper_conf", "remount"])
        #expect(model.deletionNotice == nil)
    }

    @Test("TEST-28 無効化がすべて成功すれば段の表示は空")
    func disableWithNoFailures() async {
        let fake = FakeServices(Self.present())
        let model = Self.makeModel(fake)
        let failed = await model.disableDeletion()
        #expect(failed == [])
        #expect(model.disableFailedStages == [])
    }

    @Test("deletion は観測の写しのまま、trash は DeletionPanelState.showsTrash に従う")
    func deletionAndTrashFollowTheSnapshot() async {
        let fake = FakeServices(Self.present(deletion: Self.panel(appEnabled: false, conf: .enabled)))
        let model = Self.makeModel(fake)
        await model.refresh()
        #expect(model.deletion == Self.panel(appEnabled: false, conf: .enabled))
        #expect(model.showsTrash == true)
        fake.set(Self.present(deletion: Self.panel(appEnabled: false, conf: .missing)))
        await model.refresh()
        #expect(model.showsTrash == false)
    }

    @Test("TEST-28 設定エラー中で消す能力も残っていなければ trash も「無効にする」も出さない")
    func noTrashWithoutDeletionState() async {
        let fake = FakeServices(Self.present(deletion: nil))
        let model = Self.makeModel(fake)
        await model.refresh()
        #expect(model.deletion == nil)
        #expect(model.showsTrash == false)
        #expect(model.showsDisableButton == false)
    }

    @Test("設定エラー中でも消す能力が残っていれば trash と「無効にする」を出す（PLAN §8.9.8）")
    func residualCapabilityShowsTrashAndDisable() async {
        var s = Self.present(deletion: nil)
        s.configPresent = false
        s.deletionResidual = true
        let fake = FakeServices(s)
        let model = Self.makeModel(fake)
        await model.refresh()
        #expect(model.showsTrash == true)
        #expect(model.showsDisableButton == true)
    }

    @Test("無効化に失敗した段がある間は「無効にする」を出し続ける")
    func failedDisableKeepsTheButton() async {
        let fake = FakeServices(Self.present(deletion: Self.panel(appEnabled: false, conf: .disabled)))
        fake.setDisableResult(["remove_reaper"])
        let model = Self.makeModel(fake)
        _ = await model.disableDeletion()
        #expect(model.showsTrash == false)
        #expect(model.showsDisableButton == true)
    }

    @Test("操作の実行中は deletionBusy が立ち、終われば下りる")
    func busyWhileOperating() async {
        let fake = FakeServices(Self.present(deletion: Self.panel(appEnabled: true, conf: .enabled)))
        fake.setHoldDisable(true)
        let model = Self.makeModel(fake)
        #expect(model.deletionBusy == false)
        let running = Task { await model.disableDeletion() }
        for _ in 0..<5_000 where fake.disableCount == 0 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(model.deletionBusy == true)
        fake.releaseDisable()
        _ = await running.value
        #expect(model.deletionBusy == false)
    }

    static func device(readOnly: Bool?) -> DeviceSnapshot {
        DeviceSnapshot(
            generation: 2, completedAt: fixed, connectEpoch: 1,
            devices: [
                "DJIMIC3": DeviceObservation(
                    deviceID: "DJIMIC3", mountPath: "/tmp/voicedock-t40-mnt/DJIMIC3", deviceNode: "/dev/disk9",
                    readOnly: readOnly, freeBytes: 1_000, relpaths: [])
            ], unavailable: [:], notListableErrno: [:])
    }

    @Test("挿し直しの案内は、読み書きできるデバイスを観測したら消える")
    func reinsertNoticeClearsOnWritableDevice() async {
        var s = Self.present(deletion: Self.panel(appEnabled: true, conf: .enabled))
        s.device = Self.device(readOnly: true)
        let fake = FakeServices(s)
        let model = Self.makeModel(fake)
        _ = await model.enableDeletion(confirmation: "ENABLE")
        #expect(model.deletionNotice == "読み書きできるようになるのはデバイスを挿し直した後です")
        s.device = Self.device(readOnly: false)
        fake.set(s)
        await model.refresh()
        #expect(model.deletionNotice == nil)
    }
}
