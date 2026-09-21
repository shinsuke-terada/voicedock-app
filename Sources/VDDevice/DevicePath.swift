// デバイス上のファイルの位置（PLAN §4・CR-11）。I/O を持たない値。開くのは DeviceReader だけ。
import Foundation

public struct DevicePath: Hashable, Sendable {
    public let deviceID: String
    public let relpath: String
    public init(deviceID: String, relpath: String) {
        self.deviceID = deviceID
        self.relpath = relpath
    }
}
