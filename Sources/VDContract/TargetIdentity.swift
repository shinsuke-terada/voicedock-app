// 削除対象の同定（PLAN §4.6。RV-06〜RV-12）。アプリの事前確認と reaper が同じ関数を使う。
import Darwin
import Foundation

public enum TargetIdentity {
    /// RV-06 / RV-07。<volumesRoot の realpath>/<deviceID> を開き、開いた fd に fstatfs する。
    public static func openVolume(volumesRoot: String, deviceID: String) -> VolumeOpenResult {
        guard DeviceID.isValid(deviceID) else {
            return .rejected(IdentityMismatch(IdentityReason.notAMountPoint))
        }
        guard let root = PosixIO.realpath(volumesRoot) else { return .absent }
        let path = root + "/" + deviceID
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            let error = errno
            switch error {
            case ENOENT:
                return .absent
            case ENOTDIR, ELOOP:
                return .rejected(IdentityMismatch(IdentityReason.notAMountPoint))
            default:
                // 開けないボリュームで要求を拒否すると processed.log に載って消費されてしまう。残して期限切れに任せる（F-48）
                return .absent
            }
        }
        var sfs = statfs()
        if fstatfs(fd, &sfs) != 0 {
            close(fd)
            return .rejected(IdentityMismatch(IdentityReason.notAMountPoint))
        }
        // バイト列の完全一致。Unicode の正規化はしない
        let mnton = PosixIO.string(fromCTuple: sfs.f_mntonname)
        if mnton != path {
            close(fd)
            return .rejected(IdentityMismatch(IdentityReason.notAMountPoint))
        }
        let fstype = PosixIO.string(fromCTuple: sfs.f_fstypename)
        if fstype != Contract.expectedFilesystem {
            close(fd)
            return .rejected(IdentityMismatch(IdentityReason.unexpectedFS))
        }
        let readOnly = (sfs.f_flags & UInt32(MNT_RDONLY)) != 0
        return .opened(VolumeHandle(fd: fd, readOnly: readOnly, mountPath: path))
    }

    /// RV-08〜RV-12。検証が通れば、検証済みの親 fd を持つ VerifiedTarget を body に貸す。
    /// body を抜けたら（このメソッドが開いた）親 fd を閉じる。失敗なら body を呼ばない。
    public static func withVerifiedTarget<R>(
        volume: VolumeHandle, relpath: String,
        expectedSize: Int64, expectedMtime: Double,
        _ body: (VerifiedTarget) -> R
    ) -> Result<R, IdentityMismatch> {
        // RV-08
        guard RelPath.isSafe(relpath) else { return .failure(IdentityMismatch(IdentityReason.relpathUnsafe)) }
        let comps = RelPath.components(relpath)
        guard let name = comps.last else { return .failure(IdentityMismatch(IdentityReason.relpathUnsafe)) }
        let dirs = comps.dropLast()
        // ボリュームの fd は借りる。閉じない
        var current = volume.fd
        var owned: Int32? = nil
        defer {
            if let owned { close(owned) }
        }
        // RV-09。macOS では symlink も通常ファイルも FIFO も ENOTDIR になる
        for comp in dirs {
            let next = openat(current, comp, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                let error = errno
                if error == ENOTDIR || error == ELOOP {
                    return .failure(IdentityMismatch(IdentityReason.pathContainsSymlink))
                }
                return .failure(IdentityMismatch(IdentityReason.targetMissing))
            }
            if let previous = owned { close(previous) }
            owned = next
            current = next
        }
        let parentFD = current
        // RV-09（errno によらない）
        var st = stat()
        if fstatat(parentFD, name, &st, AT_SYMLINK_NOFOLLOW) != 0 {
            return .failure(IdentityMismatch(IdentityReason.targetMissing))
        }
        // RV-10
        if (st.st_mode & S_IFMT) == S_IFLNK {
            return .failure(IdentityMismatch(IdentityReason.targetIsSymlink))
        }
        if (st.st_mode & S_IFMT) != S_IFREG {
            return .failure(IdentityMismatch(IdentityReason.notRegularFile))
        }
        // RV-11
        guard RecordingName.parseFile(name)?.isOrig == true else {
            return .failure(IdentityMismatch(IdentityReason.filenameRule))
        }
        // relpath が 1 要素（ボリューム直下のファイル）は常に folder_rule
        guard dirs.last.map(RecordingName.isFolder) ?? false else {
            return .failure(IdentityMismatch(IdentityReason.folderRule))
        }
        // RV-12
        if Int64(st.st_size) != expectedSize {
            return .failure(IdentityMismatch(IdentityReason.sizeMismatch))
        }
        // expectedMtime が NaN なら比較が偽になり不一致（fail-closed）
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        guard abs(mtime - expectedMtime) < Contract.mtimeToleranceSeconds else {
            return .failure(IdentityMismatch(IdentityReason.mtimeMismatch))
        }
        // body の中では parentFD が開いている（owned は defer で body の後に閉じる）
        let result = body(VerifiedTarget(parentFD: parentFD, name: name))
        return .success(result)
    }
}

public enum VolumeOpenResult: Sendable {
    case opened(VolumeHandle)
    /// device_absent（要求を残す）
    case absent
    /// not_a_mount_point / unexpected_fs
    case rejected(IdentityMismatch)
}

/// 開いたボリュームのディレクトリ fd。deinit で閉じる。
/// 本番のコードで初期化子を呼んでよいのはこのファイルだけ（PT-22）。テストは @testable import で FakeVolumeOpener が使う。
public final class VolumeHandle: Sendable {
    public let fd: Int32
    /// 同じ fstatfs の f_flags & MNT_RDONLY（観測値）。reaper の RV-07 とアプリの事前確認が使う
    public let readOnly: Bool
    /// realpath 済みの <volumesRoot>/<deviceID>
    public let mountPath: String

    init(fd: Int32, readOnly: Bool, mountPath: String) {
        self.fd = fd
        self.readOnly = readOnly
        self.mountPath = mountPath
    }

    deinit {
        close(fd)
    }
}

/// body の外へ持ち出さない（parentFD は body の後で閉じられる）。
public struct VerifiedTarget {
    public let parentFD: Int32
    public let name: String
}

public struct IdentityMismatch: Error, Equatable, Sendable {
    /// IdentityReason の定数のどれか
    public let reason: String

    public init(_ reason: String) {
        self.reason = reason
    }
}

/// 理由語（PLAN 付録 B.2 の全語。逐語）。reaper とアプリが共有する。
public enum IdentityReason {
    public static let lock1 = "lock1"
    public static let confInvalid = "conf_invalid"
    public static let malformedRequestID = "malformed_request_id"
    public static let malformedRequest = "malformed_request"
    public static let replayed = "replayed"
    public static let partkeyMismatch = "partkey_mismatch"
    public static let deviceAbsent = "device_absent"
    public static let notAMountPoint = "not_a_mount_point"
    public static let unexpectedFS = "unexpected_fs"
    public static let mountReadonly = "mount_readonly"
    public static let relpathUnsafe = "relpath_unsafe"
    public static let pathContainsSymlink = "path_contains_symlink"
    public static let targetMissing = "target_missing"
    public static let targetIsSymlink = "target_is_symlink"
    public static let notRegularFile = "not_regular_file"
    public static let filenameRule = "filename_rule"
    public static let folderRule = "folder_rule"
    public static let sizeMismatch = "size_mismatch"
    public static let mtimeMismatch = "mtime_mismatch"
    public static let unlinkFailed = "unlink_failed"
    public static let stillPresent = "still_present"
    /// 上の 21 語をこの順に（SPEC 同期のテストが付録 B.2 と照合する）
    public static let all: [String] = [
        lock1, confInvalid, malformedRequestID, malformedRequest, replayed, partkeyMismatch,
        deviceAbsent, notAMountPoint, unexpectedFS, mountReadonly, relpathUnsafe, pathContainsSymlink,
        targetMissing, targetIsSymlink, notRegularFile, filenameRule, folderRule, sizeMismatch,
        mtimeMismatch, unlinkFailed, stillPresent,
    ]
}

/// アプリはボリュームをこのプロトコル経由で開く（テストで差し替えるため。CR-25）。reaper は openVolume を直接呼ぶ。
public protocol VolumeOpener: Sendable {
    func open(volumesRoot: String, deviceID: String) -> VolumeOpenResult
}

/// 本番の実装。openVolume を呼ぶだけ。
public struct SystemVolumeOpener: VolumeOpener {
    public init() {}

    public func open(volumesRoot: String, deviceID: String) -> VolumeOpenResult {
        TargetIdentity.openVolume(volumesRoot: volumesRoot, deviceID: deviceID)
    }
}
