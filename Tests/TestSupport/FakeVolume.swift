// 一時ディレクトリに DJI Mic 3 と同じ木を作る（PLAN §10.2。voicedock tests/fixtures/fake_tree.py）。
import Darwin
import Foundation

/// `<tmp>/Volumes/<deviceID>` に偽のボリュームを作る。マウント点ではないので、開くのは `FakeVolumeOpener`。
public final class FakeVolume: Sendable {
    /// <tmp>/Volumes
    public let volumesRoot: URL
    /// <tmp>/Volumes/<deviceID>
    public let root: URL
    public let deviceID: String
    /// 原本の mtime はコピー時刻の 4 時間 34 分前（voicedock の DEVICE_MTIME_OFFSET。DEL-12 を再現する）
    public static let deviceMtimeOffsetSeconds: Double = 16_440
    /// voicedock の reaper ベンチと同じ中身（b"x" * 4096）
    public static let standardContent = Data(repeating: 0x78, count: 4096)

    /// root まで作る
    public init(in tmp: TempDirectory, deviceID: String = "DJIMIC3") throws {
        volumesRoot = tmp.url.appendingPathComponent("Volumes", isDirectory: true)
        root = volumesRoot.appendingPathComponent(deviceID, isDirectory: true)
        self.deviceID = deviceID
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func url(_ relpath: String) -> URL {
        root.appendingPathComponent(relpath)
    }

    /// 親を作り、書き、utimes で mtime を設定
    @discardableResult
    public func addFile(_ relpath: String, data: Data = FakeVolume.standardContent, mtime: Double) throws -> URL {
        let target = url(relpath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
        try setMtime(relpath, mtime)
        return target
    }

    @discardableResult
    public func addDirectory(_ relpath: String) throws -> URL {
        let target = url(relpath)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    /// destination は与えた文字列のまま（相対・絶対）
    public func addSymlink(_ relpath: String, destination: String) throws {
        let target = url(relpath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: target.path(percentEncoded: false), withDestinationPath: destination)
    }

    /// mkfifo
    public func addFIFO(_ relpath: String) throws {
        let target = url(relpath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if mkfifo(target.path(percentEncoded: false), 0o644) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// utimes（秒と μ秒）
    public func setMtime(_ relpath: String, _ mtime: Double) throws {
        let seconds = mtime.rounded(.down)
        let micros = Int32(((mtime - seconds) * 1_000_000).rounded())
        var times = [
            timeval(tv_sec: Int(seconds), tv_usec: micros),
            timeval(tv_sec: Int(seconds), tv_usec: micros),
        ]
        if utimes(url(relpath).path(percentEncoded: false), &times) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// lstat
    public func fileStat(_ relpath: String) -> (size: Int64, mtime: Double)? {
        var st = stat()
        guard lstat(url(relpath).path(percentEncoded: false), &st) == 0 else { return nil }
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        return (Int64(st.st_size), mtime)
    }

    /// 下の StandardTree を作る。原本の mtime = copyTime − deviceMtimeOffsetSeconds
    public func populateStandardTree(copyTime: Double) throws {
        let mtime = copyTime - Self.deviceMtimeOffsetSeconds
        for relpath in StandardTree.origInScope + StandardTree.denoised + StandardTree.beyondDepth {
            try addFile(relpath, data: Self.standardContent, mtime: mtime)
        }
        for relpath in StandardTree.hidden {
            try addFile(relpath, data: Data(repeating: 0x00, count: 82), mtime: mtime)
        }
        try addSymlink(StandardTree.symlinkFolder, destination: "TX_MIC001_20260829_071201")
    }

    public enum StandardTree {
        /// 取り込みの候補（_orig、symlink でない、走査の深さ 3 以内、. 始まりでない）
        public static let origInScope: [String] = [
            "TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav",
            "TX_MIC001_20260829_074201/TX01_MIC002_20260829_074210_orig.wav",
            "a/b/TX01_MIC002_20260829_083000_orig.wav",
        ]
        public static let denoised: [String] = ["TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204.wav"]
        /// 深さ 4（maxScanDepth 3 の外）
        public static let beyondDepth: [String] = ["a/b/c/TX01_MIC002_20260829_090000_orig.wav"]
        /// . 始まり（黙って無視されるもの）
        public static let hidden: [String] = [
            "TX_MIC001_20260829_071201/._TX01_MIC002_20260829_071204_orig.wav",
            ".Spotlight-V100/Store-V2/x",
            ".Trashes/501/TX01_MIC002_20260829_071204_orig.wav",
            ".fseventsd/fseventsd-uuid",
        ]
        /// フォルダ規則に一致する名前の symlink（→ "TX_MIC001_20260829_071201"。走査が辿ってはいけない）
        public static let symlinkFolder = "TX_MIC001_20260829_080001"
    }
}
