// 1 回の走査の観測と取り込みの進捗（PLAN §8.1）。走査ごとに 1 つだけ公開する。時刻で新旧を比べない（generation を使う）。
import Foundation
import VDCore

public struct DeviceSnapshot: Equatable, Sendable {
    public let generation: UInt64
    public let completedAt: Instant
    public let connectEpoch: UInt64
    /// key = device_id。0 台なら空（「不明」ではない。DEL-32）
    public let devices: [String: DeviceObservation]
    /// 名前 → not_listable / mount_name_mismatch / invalid_device_id / mount_failed（再マウントでアンマウントされたまま）/
    /// not_included（名前が include に無いがデバイスに見える。改名の案内だけで、取り込まず削除もしない）。F-81
    public let unavailable: [String: String]
    /// not_listable の errno（EPERM のときだけ TCC の案内。DR-11）
    public let notListableErrno: [String: Int32]

    public init(
        generation: UInt64, completedAt: Instant, connectEpoch: UInt64, devices: [String: DeviceObservation],
        unavailable: [String: String], notListableErrno: [String: Int32]
    ) {
        self.generation = generation
        self.completedAt = completedAt
        self.connectEpoch = connectEpoch
        self.devices = devices
        self.unavailable = unavailable
        self.notListableErrno = notListableErrno
    }

    /// now − completedAt <= maxAgeSeconds（等号を含む）
    public func isFresh(now: Instant, maxAgeSeconds: Int) -> Bool {
        now.epochMillis - completedAt.epochMillis <= Int64(maxAgeSeconds) * 1000
    }
}

public struct DeviceObservation: Equatable, Sendable {
    public let deviceID: String
    public let mountPath: String
    public let deviceNode: String?
    /// statfs の観測値。観測できなければ nil（偽と区別する。DEL-31 / DEL-32）
    public let readOnly: Bool?
    public let freeBytes: Int64?
    /// _orig も denoised も全部。録音 0 件なら空（DEV-19）
    public let relpaths: Set<String>

    public init(
        deviceID: String, mountPath: String, deviceNode: String?, readOnly: Bool?, freeBytes: Int64?,
        relpaths: Set<String>
    ) {
        self.deviceID = deviceID
        self.mountPath = mountPath
        self.deviceNode = deviceNode
        self.readOnly = readOnly
        self.freeBytes = freeBytes
        self.relpaths = relpaths
    }
}

/// 走査の途中経過（snapshot にしない進捗。UI と沈黙の判定が使う。PLAN §8.1・§8.11）
public struct IngestActivity: Equatable, Sendable {
    public let scanning: Bool
    public let deviceID: String?
    public let copied: Int
    public let total: Int
    public let lastActivityAt: Instant?

    public init(scanning: Bool, deviceID: String?, copied: Int, total: Int, lastActivityAt: Instant?) {
        self.scanning = scanning
        self.deviceID = deviceID
        self.copied = copied
        self.total = total
        self.lastActivityAt = lastActivityAt
    }

    public static let idle = IngestActivity(scanning: false, deviceID: nil, copied: 0, total: 0, lastActivityAt: nil)
}
