// DeletionPanelState（3 行・trash・注意書き。PLAN §8.9.8。T-40 §6.3）。LockEvaluator を通さず値の写像だけを見る。
import Foundation
import TestSupport
import Testing
import VDCore

@testable import VDPipeline

@Suite("DeletionPanelState")
struct DeletionPanelStateTests {
    static func display(
        appEnabled: Bool = true, confState: LockDisplay.ConfState = .enabled,
        reaper: ReaperStatus = .valid(version: "1.0.0"), mountMode: String = "rw",
        devices: [(String, DeviceWritability)]? = [("DJIMIC3", .writable)],
        readiness: DeletionReadiness = .configured
    ) -> LockDisplay {
        LockDisplay(
            appEnabled: appEnabled, confState: confState, reaper: reaper, mountMode: mountMode,
            devices: devices?.map { LockDisplay.Device(deviceID: $0.0, writability: $0.1) }, readiness: readiness)
    }

    static func state(_ display: LockDisplay, skipped: Bool = false) -> DeletionPanelState {
        DeletionPanelState(display: display, deleteSkippedSource: skipped)
    }

    @Test("3 行が PLAN §8.9.8 の逐語")
    func linesAreVerbatim() {
        let s = Self.state(Self.display())
        #expect(
            s.lines == [
                "ロック 1  : アプリ=有効, reaper.conf=有効",
                "ロック 2-A: 削除モジュール=導入済み（署名 OK, 版 1.0.0）",
                "ロック 2-B: 設定=rw, DJIMIC3=読み書き可能（観測）",
            ])
    }

    @Test(
        "片方だけ有効でも trash を出す",
        arguments: [
            (true, LockDisplay.ConfState.disabled, true),
            (false, LockDisplay.ConfState.enabled, true),
            (true, LockDisplay.ConfState.enabled, true),
            (false, LockDisplay.ConfState.missing, false),
        ])
    func trashIsShownWhileEitherSideIsEnabled(_ app: Bool, _ conf: LockDisplay.ConfState, _ expected: Bool) {
        let s = Self.state(Self.display(appEnabled: app, confState: conf))
        #expect(s.showsTrash == expected)
    }

    @Test("デバイスが未接続でも trash は消えない")
    func trashIsShownEvenWhenTheDeviceIsAbsent() {
        let s = Self.state(Self.display(devices: [], readiness: .disabled("mount_mode_ro")))
        #expect(s.showsTrash == true)
    }

    @Test("観測が読み取り専用の間は挿し直しの案内を出す")
    func reinsertNoticeWhileTheDeviceIsReadOnly() {
        let s = Self.state(Self.display(devices: [("DJIMIC3", .readOnly)]))
        #expect(s.notices == ["読み書きできるようになるのはデバイスを挿し直した後です"])
    }

    @Test("観測できないときも案内を出す")
    func reinsertNoticeWhenTheObservationIsUnknown() {
        let s = Self.state(Self.display(devices: [("DJIMIC3", .unknown)]))
        #expect(s.notices == ["読み書きできるようになるのはデバイスを挿し直した後です"])
    }

    @Test("削除が無効なら案内は出さない")
    func noReinsertNoticeWhenDeletionIsOff() {
        let s = Self.state(Self.display(appEnabled: false, confState: .missing, devices: [("DJIMIC3", .readOnly)]))
        #expect(s.notices == [])
    }

    @Test("版が違えば更新の案内を出す")
    func updateNoticeOnVersionMismatch() throws {
        let s = Self.state(Self.display(reaper: .versionMismatch(found: "0.9.0"), devices: [("DJIMIC3", .writable)]))
        #expect(s.notices == ["削除モジュールの更新が必要です"])
        let line2 = try #require(s.lines.dropFirst().first)
        #expect(line2.hasSuffix(DeletionStrings.reaperUpdateNotice))
        #expect(line2 == "ロック 2-A: 削除モジュール=導入済み（署名 OK, 版 0.9.0）。削除モジュールの更新が必要です")
    }

    @Test("2 つとも当てはまれば更新が先")
    func bothNoticesAppearInOrder() {
        let s = Self.state(Self.display(reaper: .versionMismatch(found: nil), devices: [("DJIMIC3", .readOnly)]))
        #expect(s.notices == ["削除モジュールの更新が必要です", "読み書きできるようになるのはデバイスを挿し直した後です"])
    }

    @Test("全部外れていれば案内は無い")
    func noNoticesWhenEverythingIsReleased() {
        let s = Self.state(Self.display())
        #expect(s.notices == [])
    }

    @Test("「無音・重複も消す」は削除が有効なときだけ出す", arguments: [(true, true), (false, false)])
    func skippedToggleFollowsTheAppSetting(_ app: Bool, _ expected: Bool) {
        let s = Self.state(Self.display(appEnabled: app))
        #expect(s.showsSkippedToggle == expected)
    }

    @Test("確認語は ENABLE")
    func confirmationWordIsVerbatim() {
        #expect(DeletionStrings.confirmationWord == "ENABLE")
        #expect(DeletionEnabler.confirmationWord == "ENABLE")
    }
}
