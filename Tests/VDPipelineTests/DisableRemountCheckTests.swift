// 無効化の再マウントを観測で確かめる（PLAN §8.9.8。F-72・issue #112 の B7）。舞台は EnablerBench（/Volumes には触れない）。
import Foundation
import TestSupport
import Testing
import VDContract
import VDCore
import VDDevice

@testable import VDPipeline

@Suite("DeletionEnabler（F-72 再マウントの観測）")
struct DisableRemountCheckTests {
    static let remountFailedLine = " WARNING deletion_disabled reason=remount"

    /// 無効化の走査が返す snapshot を差し替えた、三重ロックが外れた舞台
    static func bench(_ scan: @escaping @Sendable (DeletionScene, UInt64) -> DeviceSnapshot) async throws
        -> EnablerBench
    {
        let bench = try await EnablerBench(enabled: true)
        let scene = bench.scene
        await bench.ingest.setScanner { generation in scan(scene, generation) }
        return bench
    }

    @Test("F-72 無効化の走査の後もデバイスが読み書きできるなら段 remount の失敗")
    func writableAfterTheScanIsARemountFailure() async throws {
        let bench = try await Self.bench { scene, g in scene.snapshot(generation: g, readOnly: false) }
        let failed = await bench.enabler.disable()
        #expect(failed == ["remount"])
        #expect(await bench.ingest.scanNowCalls == 1)
        #expect(bench.logLines().contains { $0.hasSuffix(Self.remountFailedLine) })
    }

    @Test("F-72 走査の後に読み取り専用か観測できない（readOnly が nil）なら段 remount の失敗（読み取り専用に丸めない）")
    func unobservedAfterTheScanIsARemountFailure() async throws {
        let bench = try await Self.bench { scene, g in scene.snapshot(generation: g, readOnly: nil) }
        #expect(await bench.enabler.disable() == ["remount"])
    }

    @Test("F-72 走査の後、接続中の全デバイスが読み取り専用なら成功")
    func readOnlyAfterTheScanSucceeds() async throws {
        let bench = try await Self.bench { scene, g in scene.snapshot(generation: g, readOnly: true) }
        #expect(await bench.enabler.disable() == [])
        #expect(bench.logLines().filter { $0.contains(" INFO  deletion_disabled") }.count == 1)
    }

    @Test("F-72 1 台でも読み書きできるデバイスが残れば段 remount の失敗（全デバイスを見る）")
    func oneWritableDeviceAmongManyIsARemountFailure() async throws {
        let bench = try await Self.bench { scene, g in
            let base = scene.snapshot(generation: g, readOnly: true)
            var devices = base.devices
            devices["OTHERMIC"] = DeviceObservation(
                deviceID: "OTHERMIC", mountPath: scene.volumesRoot.path(percentEncoded: false) + "/OTHERMIC",
                deviceNode: "/dev/disk8", readOnly: false, freeBytes: 1_000, relpaths: [])
            return DeviceSnapshot(
                generation: g, completedAt: base.completedAt, connectEpoch: base.connectEpoch, devices: devices,
                unavailable: [:], notListableErrno: [:])
        }
        #expect(await bench.enabler.disable() == ["remount"])
    }

    @Test("F-72 デバイスが 0 台なら戻すものが無いので成功（TEST-28）")
    func noDeviceSucceeds() async throws {
        let bench = try await Self.bench { scene, g in scene.snapshot(generation: g, includeDevice: false) }
        #expect(await bench.enabler.disable() == [])
    }
}
