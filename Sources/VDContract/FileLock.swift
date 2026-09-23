// state/reaper.lock の排他ロック（PLAN §2.1）。アプリの IngestService と reaper が共有する。
import Darwin
import Foundation

public final class FileLock: Sendable {
    private let fd: Int32

    private init(fd: Int32) {
        self.fd = fd
    }

    /// open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644) → flock(fd, LOCK_EX | LOCK_NB)。
    /// 開けない（symlink は O_NOFOLLOW で ELOOP。辿った先に作らない。F-73）・ロックが取れない（EWOULDBLOCK を含む）なら
    /// fd を閉じて nil。待たない（待つのは呼び手）。
    /// 親ディレクトリ（state/）は在ること。ロックファイルの中身は書かない。消さない。
    public static func tryAcquire(url: URL) -> FileLock? {
        let fd = open(url.path(percentEncoded: false), O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return FileLock(fd: fd)
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
