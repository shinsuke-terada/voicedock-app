// LockObserving（DisabledLockObserver と LockDisplay.lines）のテスト（T-32 §5.10）。
import Foundation
import TestSupport
import Testing
import VDCore
import VDDevice

@testable import VDPipeline

@Suite("LockObserving")
struct LockObservingTests {
    static func config(delete: Bool, mountMode: String) -> AppConfig {
        var c = AppConfig.defaults(timeZone: "Asia/Tokyo")
        c.cleanup.deleteSourceAudio = delete
        c.device.mountMode = mountMode
        return c
    }

    static func snapshot(_ devices: [String: Bool?]) -> DeviceSnapshot {
        var observed: [String: DeviceObservation] = [:]
        for (id, readOnly) in devices {
            observed[id] = DeviceObservation(
                deviceID: id, mountPath: "/tmp/vd-fake/" + id, deviceNode: nil, readOnly: readOnly, freeBytes: nil,
                relpaths: [])
        }
        return DeviceSnapshot(
            generation: 1, completedAt: Instant(epochMillis: 1_788_040_812_000), connectEpoch: 0, devices: observed,
            unavailable: [:], notListableErrno: [:])
    }

    @Test("DisabledLockObserver は常に削除無効")
    func disabledObserverIsAlwaysDisabled() async {
        let observer = DisabledLockObserver()
        let o = await observer.observe(
            config: Self.config(delete: true, mountMode: "rw"), snapshot: Self.snapshot(["DJIMIC3": false]))
        #expect(o.readiness == .disabled("delete_source_audio_disabled"))
        #expect(o.allReleased(for: "DJIMIC3") == false)
        #expect(await observer.reaperStatus() == .notInstalled)
        #expect(o.volumesRoot == nil)
        #expect(o.confState == .missing)
    }

    @Test("DisabledLockObserver でも 3 行が組める（DR-14）")
    func disabledObserverDisplaysThreeLines() async {
        let d = await DisabledLockObserver().display(
            config: Self.config(delete: true, mountMode: "rw"), snapshot: Self.snapshot(["DJIMIC3": false]))
        #expect(
            d.lines == [
                "ロック 1  : アプリ=有効, reaper.conf=無し", "ロック 2-A: 削除モジュール=未導入",
                "ロック 2-B: 設定=rw, DJIMIC3=読み書き可能（観測）",
            ])
    }

    @Test("snapshot が無ければ観測=不明")
    func displayWithoutSnapshotSaysUnknown() async {
        let d = await DisabledLockObserver().display(config: Self.config(delete: false, mountMode: "ro"), snapshot: nil)
        #expect(d.lines.last == "ロック 2-B: 設定=ro, 観測=不明")
        #expect(d.devices == nil)
    }

    @Test("0 台なら デバイス未接続（TEST-28）")
    func displayWithZeroDevices() async {
        let d = await DisabledLockObserver().display(
            config: Self.config(delete: false, mountMode: "ro"), snapshot: Self.snapshot([:]))
        #expect(d.lines.last == "ロック 2-B: 設定=ro, デバイス未接続")
        #expect(d.devices == [])
    }

    @Test("writability は観測だけを見る")
    func writabilityObservesOnly() {
        let s = Self.snapshot(["RO": true, "RW": false, "NIL": nil])
        #expect(DeviceWritability.observe(deviceID: "RO", snapshot: s) == .readOnly)
        #expect(DeviceWritability.observe(deviceID: "RW", snapshot: s) == .writable)
        #expect(DeviceWritability.observe(deviceID: "NIL", snapshot: s) == .unknown)
        #expect(DeviceWritability.observe(deviceID: "GONE", snapshot: s) == .absent)
        #expect(DeviceWritability.observe(deviceID: "RW", snapshot: nil) == .absent)
    }

    @Test("devices は鍵のバイト順")
    func devicesAreInByteOrder() {
        let o = LockObservation(
            readiness: .configured, snapshot: Self.snapshot(["b": false, "a": true, "A": nil]), volumesRoot: nil,
            confState: .enabled)
        #expect(o.devices?.map(\.deviceID) == ["A", "a", "b"])
        #expect(o.devices?.map(\.writability) == [.unknown, .readOnly, .writable])
        let d = LockDisplay(
            appEnabled: true, confState: .enabled, reaper: .valid(version: "1.0.0"), mountMode: "rw",
            devices: o.devices, readiness: .configured)
        #expect(
            d.lines == [
                "ロック 1  : アプリ=有効, reaper.conf=有効", "ロック 2-A: 削除モジュール=導入済み（署名 OK, 版 1.0.0）",
                "ロック 2-B: 設定=rw, A=不明（観測）, a=読み取り専用（観測）, b=読み書き可能（観測）",
            ])
    }
}
