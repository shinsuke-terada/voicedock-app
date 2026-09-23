// ファイルの書き換えの唯一の実装（CR-01）。tmp の後始末もここだけが行う。
import CryptoKit
import Darwin
import Foundation

public enum AtomicFile {
    /// url の親ディレクトリは在ること（作らない）。
    /// 途中のどこで失敗しても、tmp を作った後なら tmp を消して元の誤りを投げる。最終ファイルは差し替えない（CR-21）。
    /// url が symlink なら rename が symlink そのものを置き換える（リンク先には書かない）。
    /// F-83: fullSync が真なら、tmp と親ディレクトリを `fsync` の代わりに `fullFsync`（F_FULLFSYNC。ドライブのキャッシュまで流す）で書き出す。
    /// 既定は偽（今までどおり fsync）。原本の削除の根拠になるファイルの書き手が真にする（Vault のノートは NoteWriter、
    /// transcript は Transcriber）。
    public static func write(
        _ data: Data, to url: URL, permissions: mode_t = 0o644, verifyReadBack: Bool = false, fullSync: Bool = false
    ) throws(AtomicFileError) {
        let tmp = tmpURL(for: url)
        let fd = open(
            tmp.path(percentEncoded: false), O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, permissions)
        if fd < 0 {
            throw .open(errno: errno)
        }
        _ = fchmod(fd, permissions)
        if let code = PosixIO.writeAll(fd: fd, data) {
            close(fd)
            discard(tmp)
            throw .write(errno: code)
        }
        if let code = fullSync ? fullFsync(fd) : plainFsync(fd) {
            close(fd)
            discard(tmp)
            throw .fsync(errno: code)
        }
        close(fd)
        if verifyReadBack && !readBackMatches(tmp, data) {
            discard(tmp)
            throw .readBackMismatch
        }
        if rename(tmp.path(percentEncoded: false), url.path(percentEncoded: false)) != 0 {
            let code = errno
            discard(tmp)
            throw .rename(errno: code)
        }
        let dirFD = open(
            url.deletingLastPathComponent().path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if dirFD >= 0 {
            _ = fullSync ? fullFsync(dirFD) : plainFsync(dirFD)
            close(dirFD)
        }
    }

    /// F-83: `fcntl(F_FULLFSYNC)`。macOS の `fsync` はドライブのキャッシュまでは流さない。F_FULLFSYNC が**どの errno で失敗しても**
    /// `fsync` に戻す（対応しないファイルシステム・デバイスでも書き出しを諦めない。SQLite と同じ）。成功なら nil、失敗なら fsync の errno。
    /// VDModels も使う（照合したモデルの rename の前。§8.10）。
    public static func fullFsync(_ fd: Int32) -> Int32? {
        if fcntl(fd, F_FULLFSYNC) == 0 { return nil }
        return plainFsync(fd)
    }

    /// `fsync`。成功なら nil、失敗なら errno。
    private static func plainFsync(_ fd: Int32) -> Int32? {
        fsync(fd) == 0 ? nil : errno
    }

    /// 同じディレクトリの ".<ファイル名>.tmp"
    public static func tmpURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".tmp")
    }

    /// 自分の tmp だけを消す（失敗は無視する）。
    private static func discard(_ tmp: URL) {
        _ = unlink(tmp.path(percentEncoded: false))
    }

    /// tmp を読み直し、SHA256 が data と一致するか。開けない・読めないときも偽。
    private static func readBackMatches(_ tmp: URL, _ data: Data) -> Bool {
        let fd = open(tmp.path(percentEncoded: false), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard case .success(let read) = PosixIO.readAll(fd: fd, limit: data.count + 1) else { return false }
        return SHA256.hash(data: read) == SHA256.hash(data: data)
    }
}

public enum AtomicFileError: Error, Equatable, Sendable {
    case open(errno: Int32)
    case write(errno: Int32)
    case fsync(errno: Int32)
    case readBackMismatch
    case rename(errno: Int32)
}
