// マウント情報の取得（PLAN §8.1 規則 4・8、読み取り専用の観測）。単体テストでは差し替える。
import Darwin
import Foundation

public struct MountInfo: Equatable, Sendable {
    /// statfs の f_mntonname（例 "/Volumes/VOICEDOCK"）
    public let mountOnName: String
    /// f_mntfromname（例 "/dev/disk4"）
    public let mountFromName: String
    /// f_fstypename（例 "msdos"）
    public let fsTypeName: String
    /// f_flags & MNT_RDONLY != 0
    public let readOnly: Bool
    /// f_bavail × f_bsize。f_bavail が Int64 に収まらない・掛け算があふれたら nil（F-71）
    public let freeBytes: Int64?
    /// f_flags & MNT_LOCAL != 0（偽はネットワークの FS。判定はそのマウント点で止まりうる呼び出しに進まない。F-81）
    public let isLocal: Bool

    /// isLocal の既定は真（F-81 より前の呼び手とテストの値はローカルの FS のもの）
    public init(
        mountOnName: String, mountFromName: String, fsTypeName: String, readOnly: Bool, freeBytes: Int64?,
        isLocal: Bool = true
    ) {
        self.mountOnName = mountOnName
        self.mountFromName = mountFromName
        self.fsTypeName = fsTypeName
        self.readOnly = readOnly
        self.freeBytes = freeBytes
        self.isLocal = isLocal
    }

    init(statfs s: statfs) {
        mountOnName = withUnsafeBytes(of: s.f_mntonname) { raw -> String in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
        mountFromName = withUnsafeBytes(of: s.f_mntfromname) { raw -> String in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
        fsTypeName = withUnsafeBytes(of: s.f_fstypename) { raw -> String in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
        readOnly = (s.f_flags & UInt32(MNT_RDONLY)) != 0
        isLocal = (s.f_flags & UInt32(MNT_LOCAL)) != 0
        // F-71: f_bavail（UInt64）が Int64 に収まらなければ観測できない扱い（トラップしない。CR-16）
        if let available = Int64(exactly: s.f_bavail) {
            let (v, o) = available.multipliedReportingOverflow(by: Int64(s.f_bsize))
            freeBytes = o ? nil : v
        } else {
            freeBytes = nil
        }
    }
}

public protocol MountInspector: Sendable {
    /// path を含むファイルシステムの statfs。失敗なら nil（「観測できない」）
    func mountInfo(path: String) -> MountInfo?
    /// getmntinfo(MNT_NOWAIT) の全項目。失敗なら空配列。
    /// MNT_NOWAIT はカーネルが持つ値を返すだけで、応答しないネットワークの FS でも待たない（判定の最初に使う。F-81）
    func allMounts() -> [MountInfo]
    /// URLResourceValues.volumeName。取れなければ nil
    func volumeName(path: String) -> String?
    /// path が「それ自身がマウント点」か（規則 4）。statfs の f_mntonname == realpath(path)
    func isMountPoint(path: String) -> Bool
}

public struct SystemMountInspector: MountInspector {
    public init() {}

    public func mountInfo(path: String) -> MountInfo? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        return MountInfo(statfs: s)
    }

    /// getmntinfo の領域は解放しない（libc が持つ静的な領域のため）
    public func allMounts() -> [MountInfo] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        return (0..<Int(count)).map { MountInfo(statfs: buffer[$0]) }
    }

    public func volumeName(path: String) -> String? {
        try? URL(fileURLWithPath: path, isDirectory: true).resourceValues(forKeys: [.volumeNameKey]).volumeName
    }

    /// realpath で比べる（一時ディレクトリは /var/folders → /private/var。hdiutil の f_mntonname は realpath 側。PLAN §4.6）
    public func isMountPoint(path: String) -> Bool {
        guard let real = Self.realPath(path) else { return false }
        guard let info = mountInfo(path: path) else { return false }
        return info.mountOnName == real
    }

    /// realpath(path, nil) の結果。失敗なら nil
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
