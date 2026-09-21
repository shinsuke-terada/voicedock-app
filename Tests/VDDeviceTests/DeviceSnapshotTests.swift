// DeviceSnapshot・IngestActivity の値の約束（T-15 §5.3）。
import Foundation
import Testing
import VDCore
import VDDevice

@Suite("DeviceSnapshot")
struct DeviceSnapshotTests {
    static let t = Instant(epochMillis: 1_790_000_000_000)

    static func snapshot(devices: [String: DeviceObservation]) -> DeviceSnapshot {
        DeviceSnapshot(
            generation: 1, completedAt: t, connectEpoch: 0, devices: devices, unavailable: [:], notListableErrno: [:])
    }

    @Test("ちょうど maxAge は新鮮、1 ms 超は古い")
    func freshnessIncludesTheBoundary() {
        let s = Self.snapshot(devices: [:])
        #expect(s.isFresh(now: Instant(epochMillis: 1_790_000_900_000), maxAgeSeconds: 900))
        #expect(!s.isFresh(now: Instant(epochMillis: 1_790_000_900_001), maxAgeSeconds: 900))
    }

    @Test("IngestActivity.idle は走査していない・0 件")
    func idleActivityIsZero() {
        let idle = IngestActivity.idle
        #expect(idle.scanning == false)
        #expect(idle.deviceID == nil)
        #expect(idle.copied == 0)
        #expect(idle.total == 0)
        #expect(idle.lastActivityAt == nil)
    }

    @Test("0 台は devices が空で、readOnly の不明（nil）とは別の値で表す（DEL-32）")
    func zeroDevicesIsNotUnknown() {
        let zero = Self.snapshot(devices: [:])
        #expect(zero.devices.isEmpty)
        let unknown = DeviceObservation(
            deviceID: "DJIMIC3", mountPath: "/tmp/Volumes/DJIMIC3", deviceNode: nil, readOnly: nil, freeBytes: nil,
            relpaths: [])
        let writable = DeviceObservation(
            deviceID: "DJIMIC3", mountPath: "/tmp/Volumes/DJIMIC3", deviceNode: nil, readOnly: false, freeBytes: nil,
            relpaths: [])
        let observed = Self.snapshot(devices: ["DJIMIC3": unknown])
        #expect(observed.devices.count == 1)
        #expect(observed.devices["DJIMIC3"]?.readOnly == nil)
        #expect(unknown != writable)
        #expect(zero != observed)
    }
}
