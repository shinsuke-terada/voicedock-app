// データの初期化（PLAN §8.12 の 8・§8.15・F-95）。予約は「詳細・診断」の長押し、実行は次の起動で DB を開く前（Bootstrap）。
// DB は開いたまま消せず（Store に閉じる口が無い）、Worker の停止は戻せないので、予約して終了し、次の起動で消す。
// 消すのは DB と取り込み・処理の途中の物だけ。設定・モデル・ログ・reaper・Vault のノートは消さない。
// 消す能力（元音声の削除）が残っている間は消さない（予約だけ取り下げる）。削除は SafeUnlink だけで行う（PT-01）。
import Darwin
import Foundation
import VDContract
import VDCore

public enum DataReset {
    /// 実行の結果
    public enum Outcome: Equatable, Sendable {
        /// 予約が無い
        case notRequested
        /// 予約はあったが消さなかった（reason はログの `reason=` と同じ語）
        case refused(reason: String)
        /// 消した。removed は消したファイルの数、failed は消せなかったものの数
        case completed(removed: Int, failed: Int)
    }

    /// 消す能力が残っていて断ったときの理由語
    static let reasonDeletionEnabled = "deletion_enabled"
    /// 予約を取り下げられず断ったときの理由語（取り下げられないまま消すと、起動のたびに消し直す）
    static let reasonRequestNotRemoved = "request_not_removed"

    /// 予約の中身（在ることだけが意味を持つ）
    static let requestBody = Data("data-reset\n".utf8)

    /// 予約を書く。書けたら真
    public static func request(layout: HomeLayout) -> Bool {
        do {
            try AtomicFile.write(requestBody, to: layout.dataResetRequest)
            return true
        } catch {
            return false
        }
    }

    /// 予約が在るか（symlink も「在る」と数える。消すときに SafeUnlink が拒むので、実行はされない）
    static func isRequested(layout: HomeLayout) -> Bool {
        var info = stat()
        return lstat(layout.dataResetRequest.path(percentEncoded: false), &info) == 0
    }

    /// 予約が在れば実行する。先に予約を取り下げ（取り下げられなければ何も消さない）、消す能力が残っていれば消さない。
    /// DB は -wal・-shm を先に消し、どちらかが残れば本体を消さない（古い WAL を新しい DB に当てない）。
    /// DB を開く前（Bootstrap の手順 9 より前）に呼ぶ
    public static func performIfRequested(layout: HomeLayout, deletionCapable: Bool, log: AppLog) -> Outcome {
        guard isRequested(layout: layout) else { return .notRequested }
        do {
            try SafeUnlink.remove(layout.dataResetRequest, under: .run, layout: layout)
        } catch {
            log.warning(.dataReset, [(.reason, .string(reasonRequestNotRemoved))])
            return .refused(reason: reasonRequestNotRemoved)
        }
        guard !deletionCapable else {
            log.warning(.dataReset, [(.reason, .string(reasonDeletionEnabled))])
            return .refused(reason: reasonDeletionEnabled)
        }
        var tally = Tally()
        removeDatabase(layout: layout, tally: &tally)
        for (directory, root) in contentRoots(layout) {
            removeContents(of: directory, under: root, layout: layout, tally: &tally)
        }
        let fields: [(LogKey, LogValue)] = [(.count, .int(Int64(tally.removed))), (.failed, .int(Int64(tally.failed)))]
        if tally.failed > 0 { log.warning(.dataReset, fields) } else { log.info(.dataReset, fields) }
        return .completed(removed: tally.removed, failed: tally.failed)
    }

    /// 中身を消すディレクトリ（ディレクトリそのものは残す）。queue の 2 つは直下の *.json だけ（SafeUnlink の規則）
    static func contentRoots(_ layout: HomeLayout) -> [(URL, SafeUnlinkRoot)] {
        [
            (layout.inbox, .inbox), (layout.staging, .staging), (layout.transcriptsParts, .transcripts),
            (layout.analysis, .analysis), (layout.queueDelete, .queueDelete), (layout.queueResult, .queueResult),
        ]
    }

    struct Tally {
        var removed = 0
        var failed = 0
    }

    /// -wal・-shm → 本体の順。-wal か -shm を消せなければ本体を残す
    static func removeDatabase(layout: HomeLayout, tally: inout Tally) {
        var sidecarsGone = true
        for name in SafeUnlinkRoot.databaseFileNames.dropFirst() {
            let gone = removeFile(layout.url(relative: name), under: .database, layout: layout, tally: &tally)
            sidecarsGone = sidecarsGone && gone
        }
        guard sidecarsGone else {
            tally.failed += 1  // 本体を残した分
            return
        }
        _ = removeFile(layout.database, under: .database, layout: layout, tally: &tally)
    }

    /// 1 つ消す。無ければ何もせず真（数えない）。消せなければ偽（failed に数える）
    static func removeFile(_ url: URL, under root: SafeUnlinkRoot, layout: HomeLayout, tally: inout Tally) -> Bool {
        var info = stat()
        guard lstat(url.path(percentEncoded: false), &info) == 0 else { return errno == ENOENT }
        do {
            try SafeUnlink.remove(url, under: root, layout: layout, missingOK: true)
            tally.removed += 1
            return true
        } catch {
            tally.failed += 1
            return false
        }
    }

    /// directory の中身を深さ優先で消す（symlink は辿らず、SafeUnlink が拒むので failed に数える）。
    /// 下位のディレクトリは中身を消した後に空なら消す。directory そのものは残す
    static func removeContents(of directory: URL, under root: SafeUnlinkRoot, layout: HomeLayout, tally: inout Tally) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        else { return }
        for name in names {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            var info = stat()
            guard lstat(url.path(percentEncoded: false), &info) == 0 else { continue }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                removeContents(of: url, under: root, layout: layout, tally: &tally)
                do {
                    try SafeUnlink.removeEmptyDirectory(url, under: root, layout: layout)
                } catch {
                    tally.failed += 1
                }
            } else {
                _ = removeFile(url, under: root, layout: layout, tally: &tally)
            }
        }
    }
}
