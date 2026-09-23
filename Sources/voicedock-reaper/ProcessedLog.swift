// `state/processed.log`（PLAN §8.9.4）。1 行 1 request_id。照合は行の完全一致。PT-12 の許可場所。
import Darwin
import Foundation

struct ProcessedLog: Sendable {
    let url: URL
    /// 行のバイト列（空行は入れない）
    private var lines: Set<[UInt8]> = []
    /// 読めなかった（ENOENT 以外の失敗）。真なら contains は常に真（fail-closed）
    private var unreadable = false

    static let maxBytes = 64 * 1024 * 1024

    /// 読めるうちに 1 度だけ全部読んで持つ（1 回の実行の間は reaper だけが書く）。
    /// 読めない（ENOENT 以外の失敗・通常ファイルでない）→ true を返し続ける（fail-closed。RV-04 で `replayed` になり、何も消えない）。
    /// `O_NONBLOCK` は FIFO を置かれても開くところで止まらないため（通常ファイルの読み取りには影響しない。F-73）
    init(url: URL) {
        self.url = url
        let fd = open(url.path(percentEncoded: false), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            unreadable = errno != ENOENT
            return
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            unreadable = true
            return
        }
        guard let data = ReaperIO.readAll(fd: fd, limit: Self.maxBytes) else {
            unreadable = true
            return
        }
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: false) where !line.isEmpty {
            lines.insert(Array(line))
        }
    }

    func contains(_ requestID: String) -> Bool {
        if unreadable { return true }
        return lines.contains(Array(requestID.utf8))
    }

    /// `O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK` で 1 行追記し `fsync`。成功で true（失敗は呼び手が無視する）。
    /// symlink は辿らない（ELOOP で失敗）。FIFO は読み手が無ければ ENXIO で失敗し、開くところで止まらない（F-73）
    @discardableResult mutating func append(_ requestID: String) -> Bool {
        let fd = open(
            url.path(percentEncoded: false), O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return false }
        guard ReaperIO.writeAll(fd: fd, Data((requestID + "\n").utf8)) else {
            close(fd)
            return false
        }
        guard fsync(fd) == 0 else {
            close(fd)
            return false
        }
        close(fd)
        // 同じ実行の中の 2 件目を捕まえる
        lines.insert(Array(requestID.utf8))
        return true
    }
}
