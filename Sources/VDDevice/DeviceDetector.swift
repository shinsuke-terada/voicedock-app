// デバイス判定（PLAN §8.1 規則 1〜9）。判定の順序と理由語を変えない。
import Darwin
import Foundation
import VDContract
import VDCore

public enum DetectionReason: String, Sendable, CaseIterable {
    case notIncluded = "not_included"
    case excluded = "excluded"
    case symlink = "symlink"
    case notAMountPoint = "not_a_mount_point"
    case notListable = "not_listable"
    case noRecordings = "no_recordings"
    case mountNameMismatch = "mount_name_mismatch"
    case invalidDeviceID = "invalid_device_id"

    /// 利用者の操作が要る理由（snapshot の unavailable に載せ、変化したときだけ WARNING）
    public var needsUserAction: Bool { self == .notListable || self == .mountNameMismatch || self == .invalidDeviceID }
}

public struct DetectedDevice: Equatable, Sendable {
    /// = エントリ名
    public let deviceID: String
    /// <volumesRoot>/<エントリ名>（realpath しない。表示とログ用）
    public let mountPath: String
    /// mountInfo(path).mountFromName。取れなければ nil
    public let node: String?
}

public struct SkippedVolume: Equatable, Sendable {
    public let name: String
    public let reason: DetectionReason
    /// notListable のときだけ（errno は listingError.code）
    public let listingError: ErrnoError?
}

public struct DetectionResult: Equatable, Sendable {
    /// 名前の UTF-8 バイト順
    public let devices: [DetectedDevice]
    /// 名前の UTF-8 バイト順
    public let skipped: [SkippedVolume]
    /// volumesRoot 自体を列挙できなかった（「0 台」と「観測できない」を分けるため）
    public let listingError: ErrnoError?
    /// 規則 1（not_included）で外した名前のうち、名前のほかはデバイスに見えるもの（規則 2 の除外に当たらず、ローカルの FS の
    /// symlink でないマウント点で、列挙でき、直下に録音のフォルダかファイルがある）。名前の UTF-8 バイト順（F-81）。
    /// 取り込まず削除の対象にもしない。走査が snapshot の unavailable に not_included で載せ、「はじめに」の⑤が改名を案内する
    public let notIncludedDevices: [String]

    init(
        devices: [DetectedDevice], skipped: [SkippedVolume], listingError: ErrnoError?,
        notIncludedDevices: [String] = []
    ) {
        self.devices = devices
        self.skipped = skipped
        self.listingError = listingError
        self.notIncludedDevices = notIncludedDevices
    }
}

public struct DeviceDetector: Sendable {
    let config: DeviceConfig
    let volumesRoot: String
    let inspector: any MountInspector
    let reader: DeviceReader

    public init(config: DeviceConfig, volumesRoot: String, inspector: any MountInspector, reader: DeviceReader) {
        self.config = config
        self.volumesRoot = volumesRoot
        self.inspector = inspector
        self.reader = reader
    }

    /// 1 つ目に当たった理由で対象外にする。判定はファイルを開かない（列挙・lstat・statfs だけ）。access(2) を使わない（DEV-03）
    public func detect() -> DetectionResult {
        // 判定の最初に、待たずに取れるマウントの一覧（getmntinfo(MNT_NOWAIT)）からネットワークの FS のマウント点を集める
        // （F-81）。応答しない共有では lstat・statfs・realpath・ボリューム名の取得が止まり、走査が reaper.lock を持ったまま
        // 止まるので、そのパスにはどれも呼ばない。一覧が取れなければ（空）従来どおり判定する
        let remote = Set(inspector.allMounts().filter { !$0.isLocal }.map(\.mountOnName))
        let names: [String]
        switch reader.listEntries(of: volumesRoot) {
        case .failure(let err):
            return DetectionResult(devices: [], skipped: [], listingError: err)
        case .success(let listed):
            names = listed
        }
        var devices: [DetectedDevice] = []
        var skipped: [SkippedVolume] = []
        var notIncludedDevices: [String] = []
        for name in names {
            if name.hasPrefix(".") { continue }
            let path = URL(fileURLWithPath: volumesRoot, isDirectory: true)
                .appendingPathComponent(name, isDirectory: false).path(percentEncoded: false)
            switch evaluate(name: name, path: path, remote: remote) {
            case .some(let skip):
                skipped.append(skip)
                if skip.reason == .notIncluded && looksLikeDevice(name: name, path: path, remote: remote) {
                    notIncludedDevices.append(name)
                }
            case .none:
                devices.append(
                    DetectedDevice(
                        deviceID: name, mountPath: path, node: inspector.mountInfo(path: path)?.mountFromName))
            }
        }
        return DetectionResult(
            devices: devices, skipped: skipped, listingError: nil, notIncludedDevices: notIncludedDevices)
    }

    /// 規則 1 で外した名前が、名前のほかはデバイスに見えるか（F-81）。規則 2（exclude・ネットワークの FS）・3・4・5・6 を
    /// 同じ順に当てる（規則 8・9 は見ない。古いマウント点が残って `VOICEDOCK 1` にマウントされた実機も案内するため）。
    /// stat が増えるのは not_included の名前だけ（include が空なら呼ばれない）。取り込みにも削除にも使わない
    private func looksLikeDevice(name: String, path: String, remote: Set<String>) -> Bool {
        if config.excludeVolumes.contains(where: { fnmatch($0, name, 0) == 0 }) { return false }
        if remote.contains(path) { return false }
        if reader.isSymlink(path) { return false }
        if !inspector.isMountPoint(path: path) { return false }
        guard case .success(let children) = reader.listEntries(of: path) else { return false }
        return children.contains(where: { hasRecording(child: $0, volumePath: path) })
    }

    /// 規則 8 を単独で評価する（再マウント後に T-15 が呼ぶ）。純粋関数: name と観測したボリューム名が一致するか（nil は不一致）
    public static func nameMatchesVolume(_ name: String, volumeName: String?) -> Bool {
        volumeName.map { PyText.scalarsEqual($0, name) } ?? false
    }

    /// 規則 1〜9 をこの順に。通れば nil。remote はネットワークの FS のマウント点（detect が getmntinfo から集める）
    private func evaluate(name: String, path: String, remote: Set<String>) -> SkippedVolume? {
        // 規則 1: include が空でなければ、どれかの glob に一致すること（DEV-05: 名前だけで判定）。
        // fnmatch は C 文字列（UTF-8 のバイト列）で比べるので、正準等価でも綴りの違う名前は一致しない（F-81）
        if !config.includeVolumes.isEmpty, !config.includeVolumes.contains(where: { fnmatch($0, name, 0) == 0 }) {
            return SkippedVolume(name: name, reason: .notIncluded, listingError: nil)
        }
        // 規則 2: exclude の glob（正規表現ではない。DEV-07）
        if config.excludeVolumes.contains(where: { fnmatch($0, name, 0) == 0 }) {
            return SkippedVolume(name: name, reason: .excluded, listingError: nil)
        }
        // 規則 2 の続き（F-81）: ネットワークの FS（MNT_LOCAL でない）のマウント点も excluded（新しい理由語を足さない）。
        // 規則 3 以降の lstat・statfs・realpath・ボリューム名は、応答しない共有で止まるので呼ばない。
        // 除外の側なので Set<String> の照合（Swift の == と同じ正準等価）で広めに当てる（綴りの違いで取りこぼして、
        // 止まる呼び出しに進まない）
        if remote.contains(path) {
            return SkippedVolume(name: name, reason: .excluded, listingError: nil)
        }
        // 規則 3: エントリ自体が symlink（DEV-08）
        if reader.isSymlink(path) {
            return SkippedVolume(name: name, reason: .symlink, listingError: nil)
        }
        // 規則 4: マウント点であること
        if !inspector.isMountPoint(path: path) {
            return SkippedVolume(name: name, reason: .notAMountPoint, listingError: nil)
        }
        // 規則 5: 列挙できること（errno によらず失敗は not_listable。DEV-03）
        let children: [String]
        switch reader.listEntries(of: path) {
        case .failure(let err):
            return SkippedVolume(name: name, reason: .notListable, listingError: err)
        case .success(let listed):
            children = listed
        }
        // 規則 6: 直下に録音のフォルダかファイルがあること（symlink は数えない。DEV-19）
        if !children.contains(where: { hasRecording(child: $0, volumePath: path) }) {
            return SkippedVolume(name: name, reason: .noRecordings, listingError: nil)
        }
        // 規則 7: 欠番
        // 規則 8: エントリ名とボリューム名が一致すること
        if !Self.nameMatchesVolume(name, volumeName: inspector.volumeName(path: path)) {
            return SkippedVolume(name: name, reason: .mountNameMismatch, listingError: nil)
        }
        // 規則 9: device_id として健全であること（PLAN §4.2）
        if !DeviceID.isValid(name) {
            return SkippedVolume(name: name, reason: .invalidDeviceID, listingError: nil)
        }
        return nil
    }

    /// 規則 6 の 1 件: `.` 始まりでなく、フォルダ規則のディレクトリかファイル規則の通常ファイル
    private func hasRecording(child: String, volumePath: String) -> Bool {
        if child.hasPrefix(".") { return false }
        let childPath = URL(fileURLWithPath: volumePath, isDirectory: true)
            .appendingPathComponent(child, isDirectory: false).path(percentEncoded: false)
        switch reader.entryKind(childPath) {
        case .directory: return RecordingName.isFolder(child)
        case .regularFile: return RecordingName.parseFile(child) != nil
        case .symlink, .other, .missing: return false
        }
    }
}
