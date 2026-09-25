// reaper を本物として起動するための舞台（PLAN §10.5 の層 R1・R3）。三重ロックは全部外した状態で作る（TEST-04）。
// volumesRoot は必ず一時ディレクトリかディスクイメージの一時マウント点（/Volumes の下には決して置かない。T-07 §4.5）。
import Darwin
import Foundation
import TestSupport
import VDContract

struct ReaperBench {
    /// 層 R1 のディレクトリ名と層 R3 のディスクイメージの名前（PLAN §10.2: 実機と同じ DJIMIC3 を使わない。一意の VDTxxxx）。
    /// 層 R1 でも DJIMIC3 にしない: 壊した reaper が VOLUMES_ROOT を既定の /Volumes に倒しても、実機ではなく device_absent になる
    static let deviceID = "VDT0037"
    static let folder = "TX_MIC001_20260912_090000"
    static let fileName = "TX00_MIC001_20260912_090000_orig.wav"
    static let relpath = "TX_MIC001_20260912_090000/TX00_MIC001_20260912_090000_orig.wav"
    static let partkey = "VDT0037/TX_MIC001_20260912_090000/TX00_MIC001_20260912_090000_orig.wav"
    static let sessionKey = "VDT0037:20260912"
    static let createdAt = "2026-09-12T18:00:00+09:00"
    /// 2026-09-12T09:01:00+09:00。偶数秒（FAT の 2 秒分解能でも変わらない）
    static let mtime: Double = 1_789_171_260
    /// FakeVolume.standardContent と同じ
    static let content = Data(repeating: 0x78, count: 4096)
    static let requestID = "20260912T090000Z-a5d046dce76cfedc-a1b2c3"

    let tmp: TempDirectory
    let layout: HomeLayout
    let volumesRoot: URL
    let deviceRoot: URL
    let image: DiskImageVolume?

    /// diskImage が nil なら普通のディレクトリ（層 R1）、在れば FAT32 / HFS+ のマウント点（層 R3）
    init(in tmp: TempDirectory? = nil, diskImage: DiskImageVolume? = nil, deleteSourceAudio: Bool = true) throws {
        let tmp = try tmp ?? TempDirectory()
        self.tmp = tmp
        layout = HomeLayout(root: tmp.url.appendingPathComponent("home", isDirectory: true))
        try layout.createDirectories()
        try FileManager.default.createDirectory(at: layout.binDirectory, withIntermediateDirectories: true)
        // RV-00 は <HOME>/bin/voicedock-reaper からの起動だけを許す
        let binary = try Data(contentsOf: ReaperBinary.url())
        try binary.write(to: layout.reaperExecutable)
        guard chmod(layout.reaperExecutable.path(percentEncoded: false), 0o755) == 0 else {
            throw BenchError(description: "chmod に失敗: " + layout.reaperExecutable.path(percentEncoded: false))
        }
        if let diskImage, diskImage.deviceID != Self.deviceID {
            throw BenchError(description: "ディスクイメージの名前は ReaperBench.deviceID にする: " + diskImage.deviceID)
        }
        let root = diskImage?.volumesRoot ?? tmp.url.appendingPathComponent("Volumes", isDirectory: true)
        // 何かを置く前に、実機に触れ得る舞台を拒む（構造で守る。PLAN §10.2）
        try Self.refuseUnsafe(volumesRoot: root, deviceID: diskImage?.deviceID ?? Self.deviceID)
        image = diskImage
        volumesRoot = root
        deviceRoot = volumesRoot.appendingPathComponent(Self.deviceID, isDirectory: true)
        if diskImage == nil {
            try FileManager.default.createDirectory(at: deviceRoot, withIntermediateDirectories: true)
        }
        try placeSource()
        try writeReaperConf(deleteSourceAudio: deleteSourceAudio)
    }

    /// 実機に触れ得る舞台を拒む: volumesRoot の realpath（無ければ標準化したパス）が `/Volumes` かその下、
    /// または deviceID が実機と同じ `VOICEDOCK`・`DJIMIC3`（F-94）。hdiutil を使わずに確かめられるよう static に分ける
    static func refuseUnsafe(volumesRoot: URL, deviceID: String) throws {
        // macOS のボリューム名は大文字小文字を区別しないので、区別せずに比べる（レビューの #8）
        guard !["VOICEDOCK", "DJIMIC3"].contains(where: { $0.caseInsensitiveCompare(deviceID) == .orderedSame }) else {
            throw BenchError(description: "ReaperBench: 実機と同じ名前 \(deviceID) は使わない")
        }
        let raw = volumesRoot.standardizedFileURL.path(percentEncoded: false)
        var resolved = raw
        if let real = Darwin.realpath(raw, nil) {
            resolved = String(decoding: Data(bytes: real, count: strlen(real)), as: UTF8.self)
            free(real)
        }
        for path in [raw, resolved] {
            let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
            if trimmed == "/Volumes" || trimmed.hasPrefix("/Volumes/") {
                throw BenchError(description: "ReaperBench: volumesRoot が /Volumes の下にある: " + path)
            }
        }
    }

    // MARK: - 準備

    func placeSource(_ relpath: String = ReaperBench.relpath, content: Data = ReaperBench.content) throws {
        let url = deviceRoot.appendingPathComponent(relpath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url)
        let seconds = Int(Self.mtime)
        var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
        guard utimes(url.path(percentEncoded: false), &times) == 0 else {
            throw BenchError(description: "utimes に失敗: " + url.path(percentEncoded: false))
        }
    }

    /// 実際に置いたファイルの (size, mtime)（FAT は 2 秒刻みなので lstat した値を使う）
    func actualStat(_ relpath: String = ReaperBench.relpath) throws -> (size: Int64, mtime: Double) {
        var st = stat()
        let path = deviceRoot.appendingPathComponent(relpath).path(percentEncoded: false)
        guard lstat(path, &st) == 0 else { throw BenchError(description: "lstat に失敗: " + path) }
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        return (Int64(st.st_size), mtime)
    }

    /// volumesRoot が nil ならこの舞台の volumesRoot（/Volumes を既定にしない）
    func writeReaperConf(deleteSourceAudio: Bool = true, volumesRoot: String? = nil) throws {
        let root = volumesRoot ?? self.volumesRoot.path(percentEncoded: false)
        try ReaperConf(deleteSourceAudio: deleteSourceAudio, volumesRoot: root).render().write(to: layout.reaperConf)
    }

    func writeReaperConfRaw(_ text: String) throws {
        try Data(text.utf8).write(to: layout.reaperConf)
    }

    func removeReaperConf() throws {
        try FileManager.default.removeItem(at: layout.reaperConf)
    }

    /// 既定は「今のデバイス上の実物と一致する、通る要求」。引数で 1 か所だけ壊す
    @discardableResult
    func writeRequest(
        requestID: String = ReaperBench.requestID, deviceID: String = ReaperBench.deviceID,
        relpath: String = ReaperBench.relpath, partkey: String? = nil,
        size: Int64? = nil, mtime: Double? = nil, fileName: String? = nil
    ) throws -> String {
        let actual = (size == nil || mtime == nil) ? try actualStat(relpath) : (0, 0)
        let request = DeleteRequest(
            requestID: requestID, createdAt: Self.createdAt, deviceID: deviceID,
            partkey: partkey ?? (deviceID + "/" + relpath), sessionKey: Self.sessionKey,
            target: DeleteTarget(relpath: relpath, size: size ?? actual.0, mtime: mtime ?? actual.1))
        let name = fileName ?? (requestID + ".json")
        try ContractJSON.encode(request).write(to: layout.queueDelete.appendingPathComponent(name))
        return name
    }

    /// 生のバイト列をそのまま置く（RV-03 の形を壊すテスト用）
    func writeRawRequest(fileName: String, _ text: String) throws {
        try Data(text.utf8).write(to: layout.queueDelete.appendingPathComponent(fileName))
    }

    // MARK: - 実行

    func run() throws -> ReaperRun {
        try ReaperBinary.run(
            executable: layout.reaperExecutable, arguments: ["--home", layout.root.path(percentEncoded: false)])
    }

    func start() throws -> ReaperProcess {
        try ReaperBinary.start(
            executable: layout.reaperExecutable, arguments: ["--home", layout.root.path(percentEncoded: false)])
    }

    // MARK: - 観測

    /// queue/delete の名前（バイト順）
    func requests() -> [String] { Self.names(in: layout.queueDelete) }

    /// queue/result の名前
    func results() -> [String] { Self.names(in: layout.queueResult) }

    /// queue/rejected の名前
    func rejected() -> [String] { Self.names(in: layout.queueRejected) }

    func result(_ requestID: String) throws -> DeleteResult {
        let data = try Data(contentsOf: layout.queueResult.appendingPathComponent(requestID + ".json"))
        switch ContractJSON.decodeResult(data) {
        case .success(let result): return result
        case .failure(let error): throw error
        }
    }

    func processedLines() -> [String] { Self.lines(of: layout.processedLog) }

    func logLines() -> [String] { Self.lines(of: layout.reaperLog) }

    func sourceExists(_ relpath: String = ReaperBench.relpath) -> Bool {
        var st = stat()
        return lstat(deviceRoot.appendingPathComponent(relpath).path(percentEncoded: false), &st) == 0
    }

    /// queue/ の下のファイル（ディレクトリを除く）の queue/ からの相対パス（ND-38: queue/result の外に作られていないこと）
    func filesUnderQueue() -> [String] {
        let queue = layout.root.appendingPathComponent("queue", isDirectory: true)
        let base = queue.path(percentEncoded: false)
        guard let enumerator = FileManager.default.enumerator(atPath: base) else { return [] }
        var files: [String] = []
        for case let path as String in enumerator {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: base + path, isDirectory: &isDirectory), !isDirectory.boolValue {
                files.append(path)
            }
        }
        return files.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    private static func names(in directory: URL) -> [String] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return all.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    private static func lines(of url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

/// 舞台の準備の失敗（テストを失敗させる）
struct BenchError: Error, CustomStringConvertible {
    let description: String
}
