// state/reaper.lock の排他ロック（PLAN §2.1）。アプリの IngestService と reaper が共有する。
import Darwin
import Foundation

public final class FileLock: Sendable {
    private let fd: Int32

    private init(fd: Int32) {
        self.fd = fd
    }

    /// 取れなかった理由（F-84。起動の単一起動のロックが「ほかが持っている」と「開けない」を分けるため）
    public enum Failure: Error, Equatable, Sendable {
        /// ほかが持っている（flock が EWOULDBLOCK）
        case held
        /// open が失敗した（errno。symlink は O_NOFOLLOW で ELOOP、親が無ければ ENOENT。ほかに EACCES・EISDIR・ENOSPC・EROFS など）
        case openFailed(errno: Int32)
        /// flock が EWOULDBLOCK 以外で失敗した（errno。ENOTSUP など）
        case lockFailed(errno: Int32)
    }

    /// open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644) → flock(fd, LOCK_EX | LOCK_NB)。
    /// 開けない（symlink は O_NOFOLLOW で ELOOP。辿った先に作らない。F-73）・ロックが取れない（EWOULDBLOCK を含む）なら
    /// fd を閉じて nil。待たない（待つのは呼び手）。
    /// 親ディレクトリ（state/）は在ること。ロックファイルの中身は書かない。消さない。
    public static func tryAcquire(url: URL) -> FileLock? {
        guard case .success(let lock) = tryAcquireResult(url: url) else { return nil }
        return lock
    }

    /// tryAcquire と同じ手順で、取れなかった理由を返す（F-84）。ほかが持っている（EWOULDBLOCK）なら `.held`、
    /// open の失敗は `.openFailed`、flock のほかの失敗は `.lockFailed`（errno は close の前に控える）。
    public static func tryAcquireResult(url: URL) -> Result<FileLock, Failure> {
        let fd = open(url.path(percentEncoded: false), O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return .failure(.openFailed(errno: errno)) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let e = errno
            close(fd)
            return .failure(e == EWOULDBLOCK ? .held : .lockFailed(errno: e))
        }
        return .success(FileLock(fd: fd))
    }

    /// flock(fd, LOCK_UN)。何度呼んでもよい（fd は閉じない。閉じるのは deinit）。
    public func release() {
        _ = flock(fd, LOCK_UN)
    }

    /// close(fd)（閉じればロックも外れる）
    deinit {
        close(fd)
    }
}
