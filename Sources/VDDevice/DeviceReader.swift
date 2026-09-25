// デバイス上のファイルを読む唯一の型（PLAN §8.1・CR-11・PT-10）。書き込み用のフラグを一切使わない。
import Darwin
import Foundation
import VDContract

public struct DeviceReader: Sendable {
    /// lstat の呼び出し。成功なら 0、失敗なら errno を返す（ENOENT も含む）。
    /// 本番は `Darwin.lstat` そのもの。テストは `init(lstat:)` で失敗を注入する（#97・F-67。分岐ではなく差し替え。CR-25）
    typealias LstatCall = @Sendable (_ path: String, _ st: inout Darwin.stat) -> Int32

    let lstatCall: LstatCall

    public init() {
        lstatCall = { path, st in Darwin.lstat(path, &st) == 0 ? 0 : errno }
    }

    /// テストが lstat の失敗を注入する口（モジュールの中だけ。00-api-map の公開 API ではない）
    init(lstat: @escaping LstatCall) {
        lstatCall = lstat
    }

    /// dir の直下の名前（`.` と `..` を除く。`.` で始まる名前も含めて返す。捨てるのは呼び手）。
    /// 名前は UTF-8 のバイト順に並べる。opendir が失敗したら errno を返す（errno によらず失敗は失敗）
    public func listEntries(of dir: String) -> Result<[String], ErrnoError> {
        errno = 0
        guard let dirp = opendir(dir) else { return .failure(ErrnoError(errno)) }
        defer { closedir(dirp) }
        var names: [String] = []
        while true {
            errno = 0
            guard let ent = readdir(dirp) else {
                if errno != 0 { return .failure(ErrnoError(errno)) }
                break
            }
            let name = withUnsafeBytes(of: ent.pointee.d_name) { raw -> String in
                let bytes = raw.bindMemory(to: CChar.self)
                guard let base = bytes.baseAddress else { return "" }
                return String(cString: base)
            }
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        return .success(names.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) })
    }

    /// lstat で symlink か（lstat が失敗したら false）。モジュールの中だけで使う（00-api-map の公開 API ではない）
    func isSymlink(_ path: String) -> Bool {
        entryKind(path) == .symlink
    }

    /// lstat の種類。symlink を辿らない（lstat の失敗は errno によらず missing）
    public func entryKind(_ path: String) -> EntryKind {
        (try? lstatKind(path).get()) ?? .missing
    }

    /// lstat の種類と、失敗なら errno（ENOENT も含む）。走査が ENOENT とそれ以外を分けるために使う（#97・F-67）
    func lstatKind(_ path: String) -> Result<EntryKind, ErrnoError> {
        var st = Darwin.stat()
        let code = lstatCall(path, &st)
        guard code == 0 else { return .failure(ErrnoError(code)) }
        switch st.st_mode & S_IFMT {
        case S_IFLNK: return .success(.symlink)
        case S_IFDIR: return .success(.directory)
        case S_IFREG: return .success(.regularFile)
        default: return .success(.other)
        }
    }
}

public enum EntryKind: Equatable, Sendable { case directory, regularFile, symlink, other, missing }

/// デバイス上の原本の size と mtime（DEL-12: 必ず原本の値。inbox のコピーの値を入れない）
public struct FileStat: Equatable, Hashable, Sendable {
    public let size: Int64
    /// st_mtimespec.tv_sec + tv_nsec / 1e9
    public let mtime: Double

    public init(size: Int64, mtime: Double) {
        self.size = size
        self.mtime = mtime
    }

    init(_ st: Darwin.stat) {
        size = Int64(st.st_size)
        mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000
    }
}

/// 1 台分の走査の結果（PLAN §8.1 ファイルの走査）。
public struct ScanListing: Equatable, Sendable {
    /// ファイル規則に一致し日時も正しい通常ファイル（_orig も denoised も）
    public let relpaths: Set<String>
    /// そのうち _orig（UTF-8 のバイト順）
    public let origCandidates: [String]
    /// 規則の形には一致するが日時が不正・relpath が不健全（バイト順）
    public let unparsable: [String]
    /// 走査中に 1 つでも列挙に失敗したら false（その一覧を「消えた」の根拠にしない）。
    /// 失敗に数えるのは、深さの上限の内側での opendir / readdir の失敗と、ENOENT 以外の lstat の失敗（#97・F-67）。
    /// ENOENT（列挙から lstat までの間に消えた）は数えない。深さの上限の外は見ないので数えない（取り込みの範囲の外）
    public let complete: Bool

    /// 走査そのものが行えなかったとき（モジュールの中だけで使う）
    static let incomplete = ScanListing(relpaths: [], origCandidates: [], unparsable: [], complete: false)

    public init(relpaths: Set<String>, origCandidates: [String], unparsable: [String], complete: Bool) {
        self.relpaths = relpaths
        self.origCandidates = origCandidates
        self.unparsable = unparsable
        self.complete = complete
    }
}

/// コピーの失敗（PLAN §8.1 コピー・付録 A.4 の copy_failed）。
public enum CopyError: Error, Equatable, Sendable {
    /// 開いた原本の size / mtime が安定性判定の値と違う・通常ファイルでない
    case changed
    /// 原本を開けない・読めない（抜かれた等）
    case readError(Int32)
    /// 書いたバイト数が size と違う
    case sizeMismatch
    /// inbox 側の作成・書き込み・fsync・rename・DB 登録の失敗
    case writeError(Int32)

    /// copy_failed の reason 語（付録 A.4）
    public var reason: String {
        switch self {
        case .changed: "changed"
        case .readError: "read_error"
        case .sizeMismatch: "copy_size_mismatch"
        case .writeError: "write_error"
        }
    }
}

/// 塊で読む元（DeviceFileHandle と、テストの FakeChunkReader）
public protocol ChunkReading {
    /// 最大 maxBytes を読む。空の Data は終わり
    func read(maxBytes: Int) throws(ErrnoError) -> Data
}

/// デバイス上の原本の読み取り専用の fd。BlockingIO の閉包の中で作って使い、外へ出さない（Sendable にしない）
public final class DeviceFileHandle: ChunkReading {
    private var fd: Int32

    init(fd: Int32) {
        self.fd = fd
    }

    /// 閉じた後に呼ばれたら EBADF
    public func read(maxBytes: Int) throws(ErrnoError) -> Data {
        guard fd >= 0 else { throw ErrnoError(EBADF) }
        let descriptor = fd
        var buffer = Data(count: maxBytes)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, maxBytes) }
            if n >= 0 {
                buffer.count = n
                return buffer
            }
            if errno == EINTR { continue }
            throw ErrnoError(errno)
        }
    }

    /// 2 回呼んでもよい
    func close() {
        guard fd >= 0 else { return }
        _ = Darwin.close(fd)
        fd = -1
    }

    /// 閉じていなければ閉じる
    deinit {
        close()
    }
}

extension DeviceReader {
    /// volumeRoot と relpath から原本のパスを作る（文字列の連結で `/` を挟まない。PT-06）。モジュールの中だけで使う
    func fullPath(volumeRoot: String, relpath: String) -> String {
        URL(fileURLWithPath: volumeRoot, isDirectory: true)
            .appendingPathComponent(relpath, isDirectory: false)
            .path(percentEncoded: false)
    }

    /// ボリュームを maxDepth 階層まで走査する（voicedock-ingest:321-352 と同じ深さ。symlink は辿らない。DEV-09）
    public func scan(volumeRoot: String, maxDepth: Int) -> ScanListing {
        var state = ScanState()
        walk(dir: volumeRoot, prefix: [], remaining: maxDepth, into: &state)
        return ScanListing(
            relpaths: state.relpaths, origCandidates: Self.byteOrdered(state.orig),
            unparsable: Self.byteOrdered(state.unparsable), complete: state.complete)
    }

    /// lstat の size と mtime。失敗・通常ファイルでない（symlink を含む）なら nil
    public func stat(volumeRoot: String, relpath: String) -> FileStat? {
        var st = Darwin.stat()
        guard lstatCall(fullPath(volumeRoot: volumeRoot, relpath: relpath), &st) == 0 else { return nil }
        guard st.st_mode & S_IFMT == S_IFREG else { return nil }
        return FileStat(st)
    }

    /// 原本を O_RDONLY | O_NOFOLLOW で開き、fstat の値が expected と一致するときだけ返す（PR-11・PT-10）
    public func openForCopy(
        volumeRoot: String, relpath: String, expected: FileStat
    ) -> Result<DeviceFileHandle, CopyError> {
        let fd = open(fullPath(volumeRoot: volumeRoot, relpath: relpath), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return .failure(.readError(errno)) }
        var st = Darwin.stat()
        guard fstat(fd, &st) == 0 else {
            let code = errno
            _ = Darwin.close(fd)
            return .failure(.readError(code))
        }
        guard st.st_mode & S_IFMT == S_IFREG else {
            _ = Darwin.close(fd)
            return .failure(.changed)
        }
        guard FileStat(st) == expected else {
            _ = Darwin.close(fd)
            return .failure(.changed)
        }
        return .success(DeviceFileHandle(fd: fd))
    }

    private struct ScanState {
        var relpaths: Set<String> = []
        var orig: [String] = []
        var unparsable: [String] = []
        var complete = true
    }

    /// 深さの上限（remaining < 1）の外は列挙も lstat もしない。そこにあるものは観測に含まれず、complete も偽にしない
    /// （上限の外の録音は Part にならず、削除の対象にも F-64 の自動完了の対象にもならない。F-67）
    private func walk(dir: String, prefix: [String], remaining: Int, into state: inout ScanState) {
        if remaining < 1 { return }
        guard case .success(let names) = listEntries(of: dir) else {
            state.complete = false
            return
        }
        for name in names {
            // .Trashes・._*・.Spotlight-V100（DEV-09）。ログも出さない
            if name.hasPrefix(".") { continue }
            let child = URL(fileURLWithPath: dir, isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
                .path(percentEncoded: false)
            let components = prefix + [name]
            switch lstatKind(child) {
            case .failure(let error):
                // ENOENT は列挙から lstat までの間に消えた（無いのと同じ）。
                // それ以外は在るかもしれないのに観測できていない（一覧を「消えた」の根拠にさせない。#97・F-67）
                if error.code != ENOENT { state.complete = false }
                continue
            case .success(.directory):
                // フォルダ規則を見ずに全部降りる
                walk(dir: child, prefix: components, remaining: remaining - 1, into: &state)
            case .success(.regularFile):
                // NOTES.txt など。黙って無視
                if !RecordingName.matchesFilePattern(name) { continue }
                let rel = RelPath.join(components)
                guard RelPath.isSafe(rel), let parsed = RecordingName.parseFile(name) else {
                    state.unparsable.append(rel)
                    continue
                }
                state.relpaths.insert(rel)
                if parsed.isOrig { state.orig.append(rel) }
            case .success(.symlink), .success(.other), .success(.missing):
                continue
            }
        }
    }

    /// UTF-8 のバイト順
    private static func byteOrdered(_ values: [String]) -> [String] {
        values.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }
}
