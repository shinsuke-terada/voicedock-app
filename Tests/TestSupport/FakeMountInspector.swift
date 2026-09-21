// MountInspector の差し替え（T-13）。@unchecked Sendable を使わないため、不変の値で持つ。
import Foundation
import VDDevice

public struct FakeMountInspector: MountInspector {
    /// key = パス（volumesRoot 配下のエントリのパス、realpath しない）
    public var infos: [String: MountInfo]
    /// isMountPoint が真になるパス
    public var mountPoints: Set<String>
    /// key = パス
    public var volumeNames: [String: String]
    /// allMounts の戻り
    public var mounts: [MountInfo]

    public init(
        infos: [String: MountInfo] = [:], mountPoints: Set<String> = [], volumeNames: [String: String] = [:],
        mounts: [MountInfo] = []
    ) {
        self.infos = infos
        self.mountPoints = mountPoints
        self.volumeNames = volumeNames
        self.mounts = mounts
    }

    /// よく使う形: path をマウント点・ボリューム名 = 最後の要素・rw・msdos・/dev/disk4 で登録した値を返す
    public static func mounted(
        _ paths: [String], readOnly: Bool = false, node: String = "/dev/disk4", freeBytes: Int64 = 4_500_000_000
    ) -> FakeMountInspector {
        var inspector = FakeMountInspector()
        for path in paths {
            let info = MountInfo(
                mountOnName: path, mountFromName: node, fsTypeName: "msdos", readOnly: readOnly, freeBytes: freeBytes)
            inspector.infos[path] = info
            inspector.mountPoints.insert(path)
            inspector.volumeNames[path] = URL(fileURLWithPath: path).lastPathComponent
            inspector.mounts.append(info)
        }
        return inspector
    }

    public func mountInfo(path: String) -> MountInfo? { infos[path] }
    public func allMounts() -> [MountInfo] { mounts }
    public func volumeName(path: String) -> String? { volumeNames[path] }
    public func isMountPoint(path: String) -> Bool { mountPoints.contains(path) }
}
