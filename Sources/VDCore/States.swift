// Part / Session の状態・遷移表・復旧写像・集合（PLAN §5.1・付録 A.1〜A.2）。状態名の文字列はこのファイルにしか書かない（PT-06）。
import Foundation

/// Part の状態。宣言順 = PLAN 付録 A.1 の表の順（voicedock states.py:25-40）。rawValue は DB の `recordings.status` に書く値。
public enum PartStatus: String, CaseIterable, Sendable, Hashable {
    case discovered = "DISCOVERED"
    case normalizing = "NORMALIZING"
    case normalized = "NORMALIZED"
    case transcribing = "TRANSCRIBING"
    case transcribed = "TRANSCRIBED"
    case rawWriting = "RAW_WRITING"
    case rawSaved = "RAW_SAVED"
    case sourceDeleting = "SOURCE_DELETING"
    case sourceDeletePending = "SOURCE_DELETE_PENDING"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case skipped = "SKIPPED"

    /// 行を作るときの状態（PLAN §5.2 `insertRecording`）。
    public static let initial: PartStatus = .discovered
}

/// Session の状態。宣言順 = PLAN 付録 A.1 の表の順（voicedock states.py:42-57）。
public enum SessionStatus: String, CaseIterable, Sendable, Hashable {
    case open = "OPEN"
    case ready = "READY"
    case merging = "MERGING"
    case merged = "MERGED"
    case analyzing = "ANALYZING"
    case analyzed = "ANALYZED"
    case writing = "WRITING"
    case saved = "SAVED"
    case sourceDeleting = "SOURCE_DELETING"
    case sourceDeletePending = "SOURCE_DELETE_PENDING"
    case cleanup = "CLEANUP"
    case completed = "COMPLETED"
    case failed = "FAILED"

    public static let initial: SessionStatus = .open
}

/// 遷移の種類。`.normal` は遷移表、`.recovery` は復旧写像でだけ許す（PLAN §5.2）。PT-21: `.recovery` を書いてよいのは
/// このファイル・`VDStore/Transitions.swift`・`VDPipeline/Recovery.swift` だけ。
public enum TransitionKind: Sendable, Hashable {
    case normal
    case recovery
}

/// 遷移の辺。エンティティごとに型が分かれる（Part と Session の同名状態を 1 つの集合に混ぜない。SM-21）。
public struct Edge<S: Hashable & Sendable>: Hashable, Sendable {
    public let from: S
    public let to: S
    public init(_ from: S, _ to: S) {
        self.from = from
        self.to = to
    }
}

/// Part の状態の集合（PLAN §5.1）。書き手と検証側が同じ定数を使う（DEL-21）。
public enum PartStates {
    /// Session を進めてよいか。
    public static let terminal: Set<PartStatus> = [
        .rawSaved, .sourceDeleting, .sourceDeletePending, .completed, .failed, .skipped,
    ]
    /// 根拠 A で消してよいか。
    /// DEL-02: terminal と混同しない。FAILED / SKIPPED は本文が保存されていない。
    public static let deletable: Set<PartStatus> = terminal.subtracting([.failed, .skipped])
    /// staging を消してよいか（FAILED の 16 kHz は再試行の入力）。
    public static let stagingDisposable: Set<PartStatus> = terminal.subtracting([.failed])
    /// 空なら Session の削除段を畳む。
    public static let awaitingDeletion: Set<PartStatus> = deletable.subtracting([.completed])
    /// Raw ノートに載る Part。
    public static let rawNoteMembers: Set<PartStatus> = [
        .transcribed, .rawWriting, .rawSaved, .sourceDeleting, .sourceDeletePending, .completed,
    ]
    /// inbox の取り残し判定（DR-15・状態の詳細）。
    public static let inboxLeftover: Set<PartStatus> = terminal.subtracting([.failed])
    /// 復旧。
    public static let inProgress: Set<PartStatus> = [.normalizing, .transcribing, .rawWriting, .sourceDeleting]
    /// FAILED からの戻り先。
    public static let retryableFromFailed: Set<PartStatus> = [.normalizing, .transcribing, .rawWriting]
    /// retry_count を 0 に戻す遷移先。
    public static let retryReset: Set<PartStatus> = [.normalized, .transcribed, .rawSaved]
    /// 各工程の入口。
    public static let normalizable: Set<PartStatus> = [.discovered, .normalizing]
    /// 各工程の入口。
    public static let transcribable: Set<PartStatus> = [.normalized, .transcribing]
    /// 各工程の入口。
    public static let rawWritable: Set<PartStatus> = [.transcribed, .rawWriting]
    /// ensureNormalized の冪等。
    public static let normalizedOrBeyond: Set<PartStatus> = [
        .normalized, .transcribing, .transcribed, .rawWriting, .rawSaved, .sourceDeleting, .sourceDeletePending,
        .completed,
    ]
    /// ensureTranscribed の冪等。
    public static let transcribedOrBeyond: Set<PartStatus> = [
        .transcribed, .rawWriting, .rawSaved, .sourceDeleting, .sourceDeletePending, .completed,
    ]
    /// ensureRawNote の冪等。
    public static let rawSavedOrBeyond: Set<PartStatus> = [
        .rawSaved, .sourceDeleting, .sourceDeletePending, .completed,
    ]
}

/// Session の状態の集合（PLAN §5.1）。
public enum SessionStates {
    /// 復旧。
    public static let inProgress: Set<SessionStatus> = [.merging, .analyzing, .writing, .sourceDeleting, .cleanup]
    /// FAILED からの戻り先。
    public static let retryableFromFailed: Set<SessionStatus> = [.merging, .analyzing, .writing]
    /// retry_count を 0 に戻す遷移先。
    public static let retryReset: Set<SessionStatus> = [.merged, .analyzed, .saved]
    /// 各工程の入口。
    public static let mergeable: Set<SessionStatus> = [.ready, .merging]
    /// 各工程の入口。
    public static let analyzable: Set<SessionStatus> = [.merged, .analyzing]
    /// 各工程の入口。
    public static let writable: Set<SessionStatus> = [.analyzed, .writing]
    /// processReadySessions の対象。
    public static let processable: Set<SessionStatus> = mergeable.union(analyzable).union(writable)
    /// 再オープン元。v1.1 で広げた。voicedock は SAVED / COMPLETED だけ（X-31）。
    public static let reopenable: Set<SessionStatus> = [
        .saved, .sourceDeleting, .sourceDeletePending, .cleanup, .completed,
    ]
    /// 削除評価の対象。
    public static let deleteEvaluated: Set<SessionStatus> = [.saved, .sourceDeleting, .sourceDeletePending, .cleanup]
    /// CLEANUP へ進める遷移元。
    public static let cleanupFrom: Set<SessionStatus> = [.saved, .sourceDeleting, .sourceDeletePending]
    /// ensureDailyNote の冪等。
    public static let savedOrBeyond: Set<SessionStatus> = [
        .saved, .sourceDeleting, .sourceDeletePending, .cleanup, .completed,
    ]
    /// ensureMerged の冪等。
    public static let mergedOrBeyond: Set<SessionStatus> = Set<SessionStatus>([
        .merged, .analyzing, .analyzed, .writing,
    ]).union(savedOrBeyond)
}

/// SKIPPED の理由の集合（PLAN §5.1）。
public enum SkipReasons {
    /// 根拠 B で元音声を消してよい SKIPPED の理由（PLAN §8.9.1。許可リスト）。
    public static let deletable: Set<ErrorCode> = [.duplicateContent, .noSpeechDetected]
    /// Daily の警告行に ⚠ を付けない理由（PLAN §8.6。NOTE-05）。**deletable と同値でも別定数**。片方の変更に追随させない。
    public static let benign: Set<ErrorCode> = [.noSpeechDetected, .duplicateContent]
}

/// 遷移表と復旧写像（PLAN 付録 A.1〜A.2）。
public enum TransitionTable {
    /// PLAN 付録 A.2 の Part の遷移表（23 本。★無し）。この並びで書く。
    public static let part: Set<Edge<PartStatus>> = [
        Edge(.discovered, .normalizing), Edge(.discovered, .skipped),
        Edge(.normalizing, .normalized), Edge(.normalizing, .skipped), Edge(.normalizing, .failed),
        Edge(.normalized, .transcribing), Edge(.normalized, .normalizing),
        Edge(.transcribing, .normalizing), Edge(.transcribing, .transcribed), Edge(.transcribing, .skipped),
        Edge(.transcribing, .failed),
        Edge(.transcribed, .rawWriting),
        Edge(.rawWriting, .rawSaved), Edge(.rawWriting, .failed),
        Edge(.rawSaved, .sourceDeleting), Edge(.rawSaved, .completed),
        Edge(.sourceDeleting, .completed), Edge(.sourceDeleting, .sourceDeletePending),
        Edge(.sourceDeletePending, .sourceDeleting),
        Edge(.completed, .sourceDeleting),
        Edge(.failed, .normalizing), Edge(.failed, .transcribing), Edge(.failed, .rawWriting),
    ]

    /// PLAN 付録 A.2 の Session の遷移表（voicedock の 24 本 ＋ ★ 6 本 = 30 本）。
    public static let session: Set<Edge<SessionStatus>> = [
        Edge(.open, .open), Edge(.open, .ready), Edge(.ready, .merging),
        Edge(.merging, .merged), Edge(.merging, .completed), Edge(.merging, .failed),
        Edge(.merged, .analyzing), Edge(.analyzing, .analyzed), Edge(.analyzing, .failed),
        Edge(.analyzed, .writing), Edge(.writing, .saved), Edge(.writing, .failed),
        Edge(.saved, .sourceDeleting), Edge(.saved, .cleanup), Edge(.saved, .merging), Edge(.completed, .merging),
        Edge(.sourceDeleting, .cleanup), Edge(.sourceDeleting, .sourceDeletePending),
        Edge(.sourceDeletePending, .sourceDeleting), Edge(.sourceDeletePending, .cleanup),
        Edge(.cleanup, .completed),
        Edge(.failed, .merging), Edge(.failed, .analyzing), Edge(.failed, .writing),
        // ★ 本計画の追加（PLAN §5.6。X-13 / X-31）
        Edge(.merged, .analyzed),  // analysis_reused
        Edge(.analyzed, .analyzing), Edge(.writing, .analyzing),  // stale_analysis
        Edge(.sourceDeleting, .merging), Edge(.sourceDeletePending, .merging), Edge(.cleanup, .merging),  // 削除段からの再オープン
    ]

    /// PLAN 付録 A.1 の復旧写像（この順に処理する）。
    public static let partRecovery: [Edge<PartStatus>] = [
        Edge(.normalizing, .discovered), Edge(.transcribing, .normalized),
        Edge(.rawWriting, .transcribed), Edge(.sourceDeleting, .sourceDeletePending),
    ]
    public static let sessionRecovery: [Edge<SessionStatus>] = [
        Edge(.merging, .ready), Edge(.analyzing, .merged), Edge(.writing, .analyzed),
        Edge(.sourceDeleting, .sourceDeletePending), Edge(.cleanup, .saved),
    ]

    public static func allows(_ e: Edge<PartStatus>, kind: TransitionKind) -> Bool {
        switch kind {
        case .normal: return part.contains(e)
        case .recovery: return partRecovery.contains(e)
        }
    }
    public static func allows(_ e: Edge<SessionStatus>, kind: TransitionKind) -> Bool {
        switch kind {
        case .normal: return session.contains(e)
        case .recovery: return sessionRecovery.contains(e)
        }
    }
}
