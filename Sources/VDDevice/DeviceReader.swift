// デバイス上のファイルを読む唯一の型（PLAN §8.1・CR-11・PT-10）。書き込み用のフラグを一切使わない。
import Darwin
import Foundation

public struct DeviceReader: Sendable {
    public init() {}

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

    /// lstat の種類。symlink を辿らない
    public func entryKind(_ path: String) -> EntryKind {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .missing }
        switch st.st_mode & S_IFMT {
        case S_IFLNK: return .symlink
        case S_IFDIR: return .directory
        case S_IFREG: return .regularFile
        default: return .other
        }
    }
}

public enum EntryKind: Equatable, Sendable { case directory, regularFile, symlink, other, missing }
