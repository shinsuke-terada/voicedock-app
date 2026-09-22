// LockDisplay.lines の全組み合わせ（型と文言は T-32 §4.11。PLAN §8.9.8。T-36 §6.5）。期待は T-32 §4.11 の表から手で書く。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice

@testable import VDPipeline

@Suite("LockDisplay")
struct LockDisplayTests {
    static func display(
        appEnabled: Bool = true, confState: LockDisplay.ConfState = .enabled,
        reaper: ReaperStatus = .valid(version: "1.0.0"), mountMode: String = "rw",
        devices: [LockDisplay.Device]? = [LockDisplay.Device(deviceID: "DJIMIC3", writability: .writable)]
    ) -> LockDisplay {
        LockDisplay(
            appEnabled: appEnabled, confState: confState, reaper: reaper, mountMode: mountMode, devices: devices,
            readiness: .configured)
    }

    @Test("全部外れたときの 3 行（PLAN §8.9.8 の例）")
    func allReleasedLines() {
        #expect(
            Self.display().lines == [
                "ロック 1  : アプリ=有効, reaper.conf=有効",
                "ロック 2-A: 削除モジュール=導入済み（署名 OK, 版 1.0.0）",
                "ロック 2-B: 設定=rw, DJIMIC3=読み書き可能（観測）",
            ])
    }

    @Test("既定（削除無効）の 3 行")
    func defaultLines() {
        let d = Self.display(
            appEnabled: false, confState: .missing, reaper: .notInstalled, mountMode: "ro", devices: [])
        #expect(
            d.lines == [
                "ロック 1  : アプリ=無効, reaper.conf=無し",
                "ロック 2-A: 削除モジュール=未導入",
                "ロック 2-B: 設定=ro, デバイス未接続",
            ])
    }

    @Test("観測できないを読み書き可能に丸めない（#107 / #148）", arguments: ["unknown", "nil"])
    func unknownIsNotWritable(_ kind: String) {
        let devices: [LockDisplay.Device]? =
            kind == "unknown" ? [LockDisplay.Device(deviceID: "DJIMIC3", writability: .unknown)] : nil
        let want = kind == "unknown" ? "ロック 2-B: 設定=rw, DJIMIC3=不明（観測）" : "ロック 2-B: 設定=rw, 観測=不明"
        #expect(Self.display(devices: devices).lines[2] == want)
    }

    @Test("読み取り専用と複数台")
    func readOnlyAndSeveralDevices() {
        let d = Self.display(devices: [
            LockDisplay.Device(deviceID: "A", writability: .writable),
            LockDisplay.Device(deviceID: "B", writability: .readOnly),
        ])
        #expect(d.lines[2] == "ロック 2-B: 設定=rw, A=読み書き可能（観測）, B=読み取り専用（観測）")
    }

    @Test(
        "削除モジュールの各状態（パラメータ化）",
        arguments: [
            (ReaperStatus.signatureInvalid, "導入済み（署名 NG）"),
            (.versionMismatch(found: "0.9.0"), "導入済み（署名 OK, 版 0.9.0）。削除モジュールの更新が必要です"),
            (.versionMismatch(found: nil), "導入済み（署名 OK, 版 不明）。削除モジュールの更新が必要です"),
        ])
    func reaperStates(_ reaper: ReaperStatus, _ want: String) {
        #expect(Self.display(reaper: reaper).lines[1] == "ロック 2-A: 削除モジュール=" + want)
    }

    @Test(
        "設定ファイルの各状態（パラメータ化）",
        arguments: [(LockDisplay.ConfState.disabled, "reaper.conf=無効"), (.invalid, "reaper.conf=不正")])
    func confStates(_ state: LockDisplay.ConfState, _ want: String) {
        #expect(Self.display(confState: state).lines[0] == "ロック 1  : アプリ=有効, " + want)
    }

    @Test("LockEvaluator.display は観測を並べ替えて渡す")
    func evaluatorBuildsTheDisplay() async throws {
        let f = try LockEvaluatorTests.makeEvaluator()
        let observed: [String: Bool?] = ["B": false, "A": nil]
        let snapshot = LockEvaluatorTests.snapshot(observed)
        let d = await f.evaluator.display(config: f.config, snapshot: snapshot)
        #expect(
            d.devices == [
                LockDisplay.Device(deviceID: "A", writability: .unknown),
                LockDisplay.Device(deviceID: "B", writability: .writable),
            ])
        #expect(d.reaper == .valid(version: AppVersion.string))
        #expect(d.readiness == .configured)
    }
}
