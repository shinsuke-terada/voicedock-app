// データの初期化（PLAN §8.12 の 8・§8.15・F-95）。予約は「詳細・診断」の長押し、実行は次の起動で DB を開く前（Bootstrap）。
// DB は開いたまま消せず（Store に閉じる口が無い）、Worker の停止は戻せないので、予約して終了し、次の起動で消す。
// 消すのは DB と、取り込み・文字起こし・要約の結果と作業中のファイルだけ。設定・モデル・ログ・reaper・Vault のノートは消さない。
// 消す能力（元音声の削除）が残っている間は予約も実行もしない。削除は SafeUnlink だけで行う（PT-01）。
import Darwin
import Foundation
import VDContract
import VDCore

public enum DataReset {
    /// 実行の結果（次の起動のパネルに出す。F-95・レビューの #4）
    public enum Outcome: Equatable, Sendable {
        /// 予約が無い
        case notRequested
        /// 予約はあったが初期化しなかった
        case refused(RefusalReason)
        /// 初期化した。removed は消したファイルの数、failed は消せなかったもの・確かめられなかったルートの数
        case completed(removed: Int, failed: Int)
    }

    /// 初期化しなかった理由（ログの `reason=` の語。PLAN 付録 A.4）
    public enum RefusalReason: String, Equatable, Sendable {
        /// 消す能力が残っていた（予約の時と実行の時）
        case deletionEnabled = "deletion_enabled"
        /// 予約を取り下げられなかった（取り下げられないまま消すと、起動のたびに消し直す）
        case requestNotRemoved = "request_not_removed"
        /// DB を消しきれず、ほかを消さずに止めた（DB の行と、行が指すファイルを食い違わせない）
        case databaseNotRemoved = "database_not_removed"
        /// DB を消した後の続きの予約が残っていたが、新しい DB がすでに在った（前回の初期化の後に使い始めている）。
        /// 消さずに予約だけ取り下げる
        case staleRequest = "stale_request"
    }

    // 予約の時のログの `reason=` の語（PLAN 付録 A.4）
    /// 予約した
    static let reasonRequested = "requested"
    /// 予約を書けなかった
    static let reasonRequestNotWritten = "request_not_written"

    /// 予約の中身。初めは requested、DB を消した後は dbRemoved に書き換える（途中で落ちても次の起動で続きを行う。レビューの #3）
    enum Phase: Equatable {
        case requested, dbRemoved

        var body: Data {
            switch self {
            case .requested: Data("data-reset\n".utf8)
            case .dbRemoved: Data("data-reset db-removed\n".utf8)
            }
        }
    }

    /// 予約を書く。消す能力が残っていれば書かない。結果はどれもログに 1 行出す。書けたら真
    public static func request(layout: HomeLayout, deletionCapable: Bool, log: AppLog) -> Bool {
        guard !deletionCapable else {
            log.warning(.dataReset, [(.reason, .string(RefusalReason.deletionEnabled.rawValue))])
            return false
        }
        do {
            try AtomicFile.write(Phase.requested.body, to: layout.dataResetRequest)
        } catch {
            log.warning(.dataReset, [(.reason, .string(reasonRequestNotWritten))])
            return false
        }
        log.info(.dataReset, [(.reason, .string(reasonRequested))])
        return true
    }

    /// 予約が在るか（symlink も「在る」と数える。取り下げで SafeUnlink が拒むので、実行はされない）
    static func isRequested(layout: HomeLayout) -> Bool {
        var info = stat()
        return lstat(layout.dataResetRequest.path(percentEncoded: false), &info) == 0
    }

    /// 予約の段階。通常ファイルでなければ nil（symlink は辿らない）。中身が dbRemoved の本文でなければ requested
    static func phase(layout: HomeLayout) -> Phase? {
        let path = layout.dataResetRequest.path(percentEncoded: false)
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let data = FileManager.default.contents(atPath: path)
        return data == Phase.dbRemoved.body ? .dbRemoved : .requested
    }

    /// DB の 3 つのファイル（本体・-wal・-shm）。名前は HomeLayout.database から作る（CR-06）
    static func databaseFiles(_ layout: HomeLayout) -> (main: URL, sidecars: [URL]) {
        let name = layout.database.lastPathComponent
        return (layout.database, [layout.url(relative: name + "-wal"), layout.url(relative: name + "-shm")])
    }

    /// 予約が在れば実行する。DB を開く前（Bootstrap の手順 9 より前）に呼ぶ。この順で、断ったら何も消さない:
    /// 1. 予約が通常ファイルでなければ取り下げを試み、断る（取り下げられなければ request_not_removed）。
    /// 2. 消す能力が残っていれば予約を取り下げて断る。
    /// 3. 予約が requested なら、DB の 3 つが通常ファイルか無いことを確かめ、-wal・-shm → 本体の順に消す。消しきれなければ
    ///    予約を取り下げ、ほかを消さずに止める（古い WAL を新しい DB に当てない。DB の行が指すファイルだけを消さない）。
    ///    消せたら予約を dbRemoved に書き換える。予約が dbRemoved で DB の本体が在れば（前回の初期化の後に使い始めている）
    ///    消さずに予約を取り下げる（stale_request）。
    /// 4. inbox・staging・transcripts/parts・analysis・queue/delete・queue/result の中身を消す。ルートそのものが
    ///    <HOME> の中の本物のディレクトリでなければ（symlink を含む）触らない。
    /// 5. 最後に予約を取り下げる。途中で落ちたら次の起動が 3 か 4 から続きを行う。取り下げに失敗しても、次の起動は
    ///    dbRemoved の予約と新しい DB を見て消し直さない
    public static func performIfRequested(layout: HomeLayout, deletionCapable: Bool, log: AppLog) -> Outcome {
        guard isRequested(layout: layout) else { return .notRequested }
        guard let phase = phase(layout: layout) else {
            _ = withdraw(layout)
            return refuse(.requestNotRemoved, log: log)
        }
        guard !deletionCapable else {
            return refuse(withdraw(layout) ? .deletionEnabled : .requestNotRemoved, log: log)
        }
        var tally = Tally()
        switch phase {
        case .requested:
            guard removeDatabase(layout: layout, tally: &tally) else {
                _ = withdraw(layout)
                log.warning(
                    .dataReset,
                    [
                        (.reason, .string(RefusalReason.databaseNotRemoved.rawValue)),
                        (.count, .int(Int64(tally.removed))), (.failed, .int(Int64(tally.failed))),
                    ])
                return .refused(.databaseNotRemoved)
            }
            // 書けなくても続ける（最後の取り下げまで落ちなければ同じ。落ちたら次の起動が DB の無いまま 3 からやり直す）
            try? AtomicFile.write(Phase.dbRemoved.body, to: layout.dataResetRequest)
        case .dbRemoved:
            var info = stat()
            if lstat(layout.database.path(percentEncoded: false), &info) == 0 {
                return refuse(withdraw(layout) ? .staleRequest : .requestNotRemoved, log: log)
            }
        }
        for (directory, root) in contentRoots(layout) {
            guard isContainedDirectory(directory, layout: layout) else {
                tally.failed += 1
                continue
            }
            removeContents(of: directory, under: root, layout: layout, tally: &tally)
        }
        if !withdraw(layout) { tally.failed += 1 }
        let fields: [(LogKey, LogValue)] = [(.count, .int(Int64(tally.removed))), (.failed, .int(Int64(tally.failed)))]
        if tally.failed > 0 { log.warning(.dataReset, fields) } else { log.info(.dataReset, fields) }
        return .completed(removed: tally.removed, failed: tally.failed)
    }

    /// 予約を取り下げる（SafeUnlink の .run）。取り下げられた（か初めから無い）なら真
    static func withdraw(_ layout: HomeLayout) -> Bool {
        do {
            try SafeUnlink.remove(layout.dataResetRequest, under: .run, layout: layout)
            return true
        } catch {
            return false
        }
    }

    static func refuse(_ reason: RefusalReason, log: AppLog) -> Outcome {
        log.warning(.dataReset, [(.reason, .string(reason.rawValue))])
        return .refused(reason)
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

    /// directory が symlink でないディレクトリで、その realpath が「<HOME> の realpath + / + 相対パス」と一致するか
    /// （途中の要素が symlink でも一致しない）。一致しなければ中を列挙しない（<HOME> の外を消さない）
    static func isContainedDirectory(_ directory: URL, layout: HomeLayout) -> Bool {
        // ディレクトリの URL の path は末尾に / が付き、lstat が symlink を辿るので落とす
        var path = directory.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
            let relative = layout.relativePath(of: directory),
            let rootReal = realPath(layout.root), let directoryReal = realPath(directory)
        else { return false }
        return directoryReal == rootReal + "/" + relative
    }

    /// realpath(3)。解けなければ nil
    static func realPath(_ url: URL) -> String? {
        guard let resolved = Darwin.realpath(url.path(percentEncoded: false), nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// DB の 3 つを消す。消しきれば（初めから無いものを含む）真。どれかが通常ファイルでなければ何も消さずに偽
    static func removeDatabase(layout: HomeLayout, tally: inout Tally) -> Bool {
        let files = databaseFiles(layout)
        for url in [files.main] + files.sidecars {
            var info = stat()
            if lstat(url.path(percentEncoded: false), &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFREG else {
                    tally.failed += 1
                    return false
                }
            } else if errno != ENOENT {
                tally.failed += 1
                return false
            }
        }
        for url in files.sidecars + [files.main] {
            guard removeFile(url, under: .database, layout: layout, tally: &tally) else { return false }
        }
        return true
    }

    /// 1 つ消す。無ければ何もせず真（数えない）。消せなければ偽（failed に数える）
    static func removeFile(_ url: URL, under root: SafeUnlinkRoot, layout: HomeLayout, tally: inout Tally) -> Bool {
        var info = stat()
        guard lstat(url.path(percentEncoded: false), &info) == 0 else {
            if errno == ENOENT { return true }
            tally.failed += 1
            return false
        }
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
    /// 読めないディレクトリも failed に数える。下位のディレクトリは中身を消した後に空なら消す。directory そのものは残す
    static func removeContents(of directory: URL, under root: SafeUnlinkRoot, layout: HomeLayout, tally: inout Tally) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        else {
            tally.failed += 1
            return
        }
        for name in names {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            var info = stat()
            guard lstat(url.path(percentEncoded: false), &info) == 0 else {
                if errno != ENOENT { tally.failed += 1 }
                continue
            }
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
