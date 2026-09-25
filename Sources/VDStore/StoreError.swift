// Store の開設・移行・バックアップ・行の読み取りの失敗（PLAN §7）。運用上の ErrorCode は持たない。
import Foundation

public enum StoreError: Error, Equatable, Sendable {
    /// journal_mode を WAL にできなかった（CONC-03）
    case notWAL
    /// 開けなかった・PRAGMA を設定できなかった（説明は GRDB の説明文）
    case open(String)
    /// マイグレーションに失敗した。より新しいアプリが当てた版があるときは "superseded"
    case migration(String)
    /// 移行前のバックアップに失敗した
    case backup(String)
    /// 行を型に写せなかった（NULL であってはならない列が NULL、未知の status など）。"<table>.<column> key=<key>"
    case corruptRow(String)
    /// 列更新に同じ列が 2 回現れた。列名
    case invalidUpdate(String)
}
