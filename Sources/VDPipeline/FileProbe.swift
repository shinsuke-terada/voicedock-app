// 「通常ファイルで size > 0」（PLAN §8.3 手順 1・§8.4 手順 2。voicedock _usable_source）。symlink は辿る。
import Darwin
import Foundation

/// ファイルの種類と大きさの確かめ（symlink は辿る）。
enum FileProbe {
    /// `stat(p(url))` が成功し、`S_ISREG` で `st_size > 0`。
    static func isNonEmptyRegularFile(_ url: URL) -> Bool {
        var info = stat()
        guard stat(url.path(percentEncoded: false), &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG && info.st_size > 0
    }

    /// `stat` が成功し `S_ISREG`、かつ `access(p(url), X_OK) == 0`（T-22 の llama-server のガードが使う）。
    static func isExecutableFile(_ url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }
}
