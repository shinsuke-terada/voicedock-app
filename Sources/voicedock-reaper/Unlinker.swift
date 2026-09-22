// 削除は `unlinkat` だけ（PLAN §8.9.4）。デバイス上の対象と `queue/delete` の要求ファイルの両方をここが消す。PT-01 の許可場所。
import Darwin
import VDContract

enum Unlinker {
    enum UnlinkOutcome: Equatable, Sendable {
        case ok
        case unlinkFailed
        case stillPresent
    }

    /// RV-13。検証済みの親 fd に `unlinkat` → 同じ fd に `fstatat(AT_SYMLINK_NOFOLLOW)` が ENOENT
    static func unlinkTarget(_ target: VerifiedTarget) -> UnlinkOutcome {
        if unlinkat(target.parentFD, target.name, 0) != 0 { return .unlinkFailed }
        var st = stat()
        // まだ在る
        if fstatat(target.parentFD, target.name, &st, AT_SYMLINK_NOFOLLOW) == 0 { return .stillPresent }
        // 確かめられなければ消えたことにしない（fail-closed）
        return errno == ENOENT ? .ok : .stillPresent
    }

    /// `queue/delete` 直下の `.json` だけを消す。成功で true（失敗は呼び手が無視する）。
    /// `AT_REMOVEDIR` を渡さない（ディレクトリは消さない。PR-16）
    static func removeRequest(named name: String, inQueueDelete fd: Int32) -> Bool {
        guard name.hasSuffix(".json"), !name.contains("/"), name != ".", name != ".." else { return false }
        return unlinkat(fd, name, 0) == 0
    }
}
