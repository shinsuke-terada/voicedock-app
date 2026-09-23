// 照合したモデルの書き出し（F-83。PLAN §8.10）。rename の前に中身を、後に親ディレクトリを F_FULLFSYNC で書き出す。
import Foundation
import VDContract

enum ModelFileSync {
    /// 書き出しに失敗したときの `ModelError.io` の語。
    static let fsyncFailure = "fsync"

    /// url の中身をドライブまで書き出す（`AtomicFile.fullFsync`。symlink は辿らない）。成功なら nil、開けない・失敗なら errno。
    static func syncFile(_ url: URL) -> Int32? {
        let fd = open(url.path(percentEncoded: false), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        return AtomicFile.fullFsync(fd)
    }

    /// url の親ディレクトリを書き出す（rename を残す）。開けない・失敗は無視する（AtomicFile と同じ）。
    static func syncParent(of url: URL) {
        let fd = open(url.deletingLastPathComponent().path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return }
        _ = AtomicFile.fullFsync(fd)
        close(fd)
    }
}
