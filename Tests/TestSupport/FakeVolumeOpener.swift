// 普通のディレクトリを VolumeHandle に包む（マウント点・FS 種別の検査をしない）。
// アプリ層の ND と正の対照で使う（PLAN §4.6、§10.5）。@testable import VDContract。
import Darwin
import Foundation

@testable import VDContract

public struct FakeVolumeOpener: VolumeOpener {
    public let readOnly: Bool

    public init(readOnly: Bool = false) {
        self.readOnly = readOnly
    }

    /// <volumesRoot>/<deviceID> を open(O_RDONLY | O_DIRECTORY | O_NOFOLLOW)。ENOENT → .absent、その他の失敗 → .rejected(not_a_mount_point)、
    /// 成功 → .opened(VolumeHandle(fd:readOnly: self.readOnly, mountPath: <realpath したパス>))
    public func open(volumesRoot: String, deviceID: String) -> VolumeOpenResult {
        let path = volumesRoot + "/" + deviceID
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if fd < 0 {
            if errno == ENOENT { return .absent }
            return .rejected(IdentityMismatch(IdentityReason.notAMountPoint))
        }
        let mountPath = PosixIO.realpath(path) ?? path
        return .opened(VolumeHandle(fd: fd, readOnly: readOnly, mountPath: mountPath))
    }
}
