// `state/processed.log`（PLAN §8.9.4）。1 行 1 件: `<request_id>`、成功は `<request_id> DELETED`（F-80）。
// 照合は request_id の部分の完全一致。PT-12 の許可場所。
import Darwin
import Foundation
import VDContract

struct ProcessedLog: Sendable {
    let url: URL
    /// 処理した request_id のバイト列（空行は入れない）
    private var ids: Set<[UInt8]> = []
    /// そのうち結果を DELETED と記録した request_id（F-80。unlink の後に結果を書けなかった要求を RV-04 で DELETED として書き直す）
    private var deleted: Set<[UInt8]> = []
    /// 読めなかった（ENOENT 以外の失敗）。真なら contains は常に真（fail-closed）、recordedDeleted は常に偽
    private var unreadable = false

    static let maxBytes = 64 * 1024 * 1024
    /// 行の中の request_id と結果の区切り（request_id の文字種に空白は無い。RequestID.pattern）
    static let separator: UInt8 = 0x20
    /// 成功の行の結果の語（DELETED。DeleteResultStatus の値をそのまま使う）
    static let deletedWord = Array(DeleteResultStatus.deleted.rawValue.utf8)

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
            insert(Array(line))
        }
    }

    /// 1 行を読む。区切りの無い行（従来の形）は request_id だけ。`<request_id> <結果>` は結果が DELETED のときだけ deleted にも入れる
    /// （ほかの語・区切りが 2 つ以上は、処理済みとだけ見る）
    private mutating func insert(_ line: [UInt8]) {
        guard let space = line.firstIndex(of: Self.separator) else {
            ids.insert(line)
            return
        }
        let id = Array(line[..<space])
        ids.insert(id)
        if Array(line[(space + 1)...]) == Self.deletedWord { deleted.insert(id) }
    }

    func contains(_ requestID: String) -> Bool {
        if unreadable { return true }
        return ids.contains(Array(requestID.utf8))
    }

    /// その request_id を DELETED（unlink して不在を確かめた）と記録したか（F-80）。読めなければ偽（リプレイは従来どおり拒否）
    func recordedDeleted(_ requestID: String) -> Bool {
        if unreadable { return false }
        return deleted.contains(Array(requestID.utf8))
    }

    /// `O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK` で 1 行追記し `fsync`。成功で true（失敗は呼び手が無視する）。
    /// deleted が真なら `<request_id> DELETED`（成功。F-80）、偽なら `<request_id>`（拒否）。
    /// symlink は辿らない（ELOOP で失敗）。FIFO は読み手が無ければ ENXIO で失敗し、開くところで止まらない（F-73）
    @discardableResult mutating func append(_ requestID: String, deleted: Bool = false) -> Bool {
        var line = Array(requestID.utf8)
        if deleted { line += [Self.separator] + Self.deletedWord }
        let fd = open(
            url.path(percentEncoded: false), O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return false }
        guard ReaperIO.writeAll(fd: fd, Data(line + [0x0A])) else {
            close(fd)
            return false
        }
        guard fsync(fd) == 0 else {
            close(fd)
            return false
        }
        close(fd)
        // 同じ実行の中の 2 件目を捕まえる
        insert(line)
        return true
    }
}
