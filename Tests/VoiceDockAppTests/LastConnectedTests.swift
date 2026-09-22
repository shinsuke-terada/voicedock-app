// LastConnected（最終接続の決め方と、ui-state.json に書く頻度の抑え方。F-70）のテスト。
import Foundation
import Testing
import VDCore
import VDDevice

@testable import VoiceDockApp

@Suite("LastConnected")
struct LastConnectedTests {
    static let t = Instant(epochMillis: 1_787_955_153_000)

    static func snapshot(at: Instant, ids: [String]) -> DeviceSnapshot {
        var devices: [String: DeviceObservation] = [:]
        for id in ids {
            devices[id] = DeviceObservation(
                deviceID: id, mountPath: "/tmp/" + id, deviceNode: nil, readOnly: nil, freeBytes: nil, relpaths: [])
        }
        return DeviceSnapshot(
            generation: 1, completedAt: at, connectEpoch: 1, devices: devices, unavailable: [:], notListableErrno: [:])
    }

    @Test("接続中は snapshot の時刻（メモリとファイルの値より優先）")
    func connectedUsesSnapshotTime() {
        let now = Self.t.adding(seconds: 600)
        let got = LastConnected.resolve(
            device: Self.snapshot(at: now, ids: ["DJIMIC3"]), carried: Self.t, persisted: Self.t)
        #expect(got == now)
    }

    @Test("切れていればメモリの前回の値")
    func disconnectedUsesCarried() {
        let carried = Self.t.adding(seconds: 30)
        let got = LastConnected.resolve(device: Self.snapshot(at: Self.t, ids: []), carried: carried, persisted: Self.t)
        #expect(got == carried)
    }

    @Test("再起動の直後（メモリに無い）は ui-state.json の値")
    func restartUsesPersisted() {
        #expect(LastConnected.resolve(device: nil, carried: nil, persisted: Self.t) == Self.t)
        #expect(
            LastConnected.resolve(device: Self.snapshot(at: Self.t, ids: []), carried: nil, persisted: Self.t) == Self.t
        )
    }

    @Test("一度も観測していなければ nil")
    func neverConnectedIsNil() {
        #expect(LastConnected.resolve(device: nil, carried: nil, persisted: nil) == nil)
        #expect(LastConnected.resolve(device: Self.snapshot(at: Self.t, ids: []), carried: nil, persisted: nil) == nil)
    }

    struct SaveCase: Sendable, CustomTestStringConvertible {
        let name: String
        let current: Instant?
        let connected: Bool
        let written: Instant?
        let expected: Instant?
        var testDescription: String { name }
    }

    static let saveCases: [SaveCase] = [
        SaveCase(name: "最終接続が無ければ書かない", current: nil, connected: false, written: nil, expected: nil),
        SaveCase(name: "まだ書いていなければすぐ書く", current: t, connected: true, written: nil, expected: t),
        SaveCase(name: "書いた値と同じなら書かない", current: t, connected: false, written: t, expected: nil),
        SaveCase(
            name: "時計が戻って書いた値より古くなっても、切れた後なら書く", current: t, connected: false,
            written: t.adding(seconds: 1), expected: t),
        SaveCase(
            name: "接続中に時計が 59.999 秒戻っただけなら書かない", current: t.adding(milliseconds: -59_999),
            connected: true, written: t, expected: nil),
        SaveCase(
            name: "接続中に時計が 60 秒戻ったら書く", current: t.adding(seconds: -60), connected: true, written: t,
            expected: t.adding(seconds: -60)),
        SaveCase(
            name: "差が桁あふれしてもトラップせずに書く", current: Instant(epochMillis: Int64.max), connected: true,
            written: Instant(epochMillis: Int64.min), expected: Instant(epochMillis: Int64.max)),
        SaveCase(
            name: "接続中で 59.999 秒しか進んでいなければ書かない", current: t.adding(milliseconds: 59_999),
            connected: true, written: t, expected: nil),
        SaveCase(
            name: "接続中で 60 秒進んだら書く", current: t.adding(seconds: 60), connected: true, written: t,
            expected: t.adding(seconds: 60)),
        SaveCase(
            name: "切れた後の最後の値は 1 秒でも進んでいれば書く", current: t.adding(seconds: 1), connected: false,
            written: t, expected: t.adding(seconds: 1)),
    ]

    @Test("書くかどうか", arguments: saveCases)
    func valueToSave(_ c: SaveCase) {
        #expect(LastConnected.valueToSave(current: c.current, connected: c.connected, written: c.written) == c.expected)
    }
}
