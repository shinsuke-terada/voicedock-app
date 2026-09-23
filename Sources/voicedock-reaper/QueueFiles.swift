// `queue/delete` の列挙と読み取り、`queue/rejected` への退避、`queue/result` への書き込み（PLAN §8.9.4）。PT-12 の許可場所。
import Darwin
import Foundation
import VDContract

final class QueueFiles {
    let layout: HomeLayout
    /// queue/delete のディレクトリ fd（openat / unlinkat / renameat がこれを起点に働く。TOCTOU の窓を消す）
    let deleteFD: Int32
    /// queue/rejected のディレクトリ fd。開けなければ -1（退避は失敗として扱う）
    let rejectedFD: Int32

    /// queue/delete を `O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC` で開く。開けなければ nil
    /// （`rejected/` は `O_RDONLY | O_DIRECTORY | O_CLOEXEC`。開けなければ -1 のまま）
    /// 名前を `open` にしない（Darwin の `open(2)` と紛れるため）
    static func make(layout: HomeLayout) -> QueueFiles? {
        let deleteFD = open(
            layout.queueDelete.path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard deleteFD >= 0 else { return nil }
        let rejectedFD = open(layout.queueRejected.path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        return QueueFiles(layout: layout, deleteFD: deleteFD, rejectedFD: rejectedFD)
    }

    private init(layout: HomeLayout, deleteFD: Int32, rejectedFD: Int32) {
        self.layout = layout
        self.deleteFD = deleteFD
        self.rejectedFD = rejectedFD
    }

    /// 開いた fd を閉じる
    deinit {
        close(deleteFD)
        if rejectedFD >= 0 { close(rejectedFD) }
    }

    /// `.` で始まらない名前を UTF-8 のバイト順の昇順に。読めなければ []。
    /// 「`.` で始まる」は先頭の Unicode スカラーで見る（Character で見ると "." の直後の結合文字で一致しない。F-81）
    func names() -> [String] {
        guard
            let all = try? FileManager.default.contentsOfDirectory(
                atPath: layout.queueDelete.path(percentEncoded: false))
        else { return [] }
        return all.filter { $0.unicodeScalars.first != "." }
            .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    /// RV-02a。`<request_id>.json` の形か（正規表現を別に持たない。`RequestID.pattern` が唯一の出どころ。CR-06）
    static func isRequestFileName(_ name: String) -> Bool {
        name.hasSuffix(".json") && RequestID.isValid(String(name.dropLast(5)))
    }

    /// 名前から `.json` を落とした stem（`isRequestFileName` を通ったものだけに使う）
    static func stem(of name: String) -> String {
        String(name.dropLast(5))
    }

    /// 要求の読み取りの結果（F-73）
    enum RequestRead: Equatable, Sendable {
        case read(Data)
        /// openat が ENOENT（列挙の後に取り下げられた）。呼び手は何も書かずに次へ進む
        case gone
        /// それ以外の読めない要求（開けない・symlink・通常ファイルでない・64 KiB 超・読み取りの失敗）
        case unreadable
    }

    /// `openat(deleteFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)` → 通常ファイル → `Contract.maxRequestBytes` 以下 → 全部読む。
    /// `O_NONBLOCK` は FIFO を置かれても開くところで止まらないため（通常ファイルの読み取りには影響しない。F-73）
    func readRequest(named name: String) -> RequestRead {
        let fd = openat(deleteFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT ? .gone : .unreadable }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return .unreadable }
        guard st.st_size <= Contract.maxRequestBytes else { return .unreadable }
        guard let data = ReaperIO.readAll(fd: fd, limit: Contract.maxRequestBytes + 1) else { return .unreadable }
        return .read(data)
    }

    /// `renameat(deleteFD, name, rejectedFD, name)`。同名は上書きされる。成功で true
    func moveToRejected(named name: String) -> Bool {
        guard rejectedFD >= 0 else { return false }
        return renameat(deleteFD, name, rejectedFD, name) == 0
    }

    /// `queue/result/<request_id>.json` が（`.` を除く通常のファイルとして）在るか
    func resultExists(requestID: String) -> Bool {
        var st = stat()
        let path = layout.queueResult.path(percentEncoded: false) + "/" + requestID + ".json"
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFREG
    }

    /// `ContractJSON.encode` → `AtomicFile.write(_, to:, permissions: 0o644)`。成功で true
    func writeResult(_ result: DeleteResult) -> Bool {
        let url = layout.queueResult.appendingPathComponent(result.requestID + ".json", isDirectory: false)
        do {
            let data = try ContractJSON.encode(result)
            try AtomicFile.write(data, to: url, permissions: 0o644)
            return true
        } catch {
            return false
        }
    }
}
