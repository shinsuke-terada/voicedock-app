# T-08 VDCore: 状態・遷移表・復旧写像・集合・ErrorCode・RetryPolicy

| 項目 | 値 |
|---|---|
| Phase | 2（記録の土台） |
| 前提 | T-05（docs/SPEC.md と SPEC 同期の基盤）、T-06（VDContract。このチケットは import しないが、モジュールの並びのため） |
| 見積もり | ソース約 330 行、テスト約 450 行 |
| ブランチ | `feat/T-08-states-errors` |

## 目的

Part / Session の状態、遷移表（normal）、復旧写像（recovery）、工程の入口・冪等の集合、エラーコードと再試行の区分を、**VDCore の 1 か所**に定義する。
状態名とエラーコード名の文字列は、このチケットが作る 2 ファイルの rawValue にしか現れない（PT-06）。後続のすべての工程と削除条件がこの定数を使う（DEL-02 / DEL-21 / SM-21）。

## 参照

- PLAN §5.1（集合）、§5.2（辺の検査）、§5.3（復旧写像の順）、§5.4（RetryPolicy の意味・工程内リトライの式）、§8.9.5（削除評価の backoff の式）、付録 A.1〜A.3
- voicedock@d3d595e: `src/voicedock/states.py:25-384`（列挙・遷移表・復旧・集合）、`src/voicedock/errors.py:80-215`（宣言順・RetryPolicy）、
  `src/voicedock/pipeline.py:1750-1760`（retry_delay）、`1855-1868`（delete_evaluation_delay）、`tests/unit/test_states.py`、`tests/unit/test_errors.py`、`tests/unit/test_retry.py:517`
- 移植メモ V2 §1〜§3

## 作るもの

| パス | 内容 |
|---|---|
| `Sources/VDCore/States.swift` | `PartStatus`・`SessionStatus`・`TransitionKind`・`Edge`・`PartStates`・`SessionStates`・`SkipReasons`・`TransitionTable` |
| `Sources/VDCore/ErrorCode.swift` | `ErrorCode`・`RetryPolicy` と `ErrorCode` の拡張 |
| `Sources/VDCore/StageFailure.swift` | `StageFailure` |
| `Sources/VDCore/RetryDelay.swift` | `RetryDelay` |
| `Sources/VDCore/RawNoteMembership.swift` | `RawNoteMembership`（00-api-map §2.1 の置き場所。書き手と検証側が同じ関数で Raw の Part 集合を作る） |
| `Tests/VDCoreTests/StatesTests.swift` | 列挙・遷移表・復旧写像の固定 |
| `Tests/VDCoreTests/StatesInvariantTests.swift` | 不変条件（PLAN §5.1） |
| `Tests/VDCoreTests/ErrorCodeTests.swift` | 宣言順・RetryPolicy・reason 語 |
| `Tests/VDCoreTests/RetryDelayTests.swift` | 2 つの式 |
| `Tests/VDCoreTests/RawNoteMembershipTests.swift` | 集合の関数 |
| `Tests/VDCoreTests/SpecSyncStatesTests.swift` | docs/SPEC.md の S1〜S3（付録 A.1〜A.3 の写し）と実装の突き合わせ。**T-05 §5 の全文をそのまま**（PolicyTests は VDCore を `@testable import` しないので VDCoreTests に置く） |

## 仕様

### PLAN §5.1 の名前との対応

PLAN §5.1 の表は `partTerminal` のような平らな名前で書いているが、00-api-map に従い**エンティティごとの名前空間**に置く。対応は次のとおり（PLAN の名前はコード中に出さない）:

| PLAN §5.1 | Swift |
|---|---|
| `partTerminal` / `partDeletable` / `stagingDisposable` / `awaitingDeletion` / `rawNoteMembers` / `inboxLeftoverStates` | `PartStates.terminal` / `.deletable` / `.stagingDisposable` / `.awaitingDeletion` / `.rawNoteMembers` / `.inboxLeftover` |
| `partInProgress` / `partRetryableFromFailed` / `partRetryReset` | `PartStates.inProgress` / `.retryableFromFailed` / `.retryReset` |
| `normalizable` / `transcribable` / `rawWritable` / `normalizedOrBeyond` / `transcribedOrBeyond` / `rawSavedOrBeyond` | `PartStates.normalizable` / `.transcribable` / `.rawWritable` / `.normalizedOrBeyond` / `.transcribedOrBeyond` / `.rawSavedOrBeyond` |
| `sessionInProgress` / `sessionRetryableFromFailed` / `sessionRetryReset` | `SessionStates.inProgress` / `.retryableFromFailed` / `.retryReset` |
| `mergeable` / `analyzable` / `writable` / `processable` / `reopenable` / `deleteEvaluated` / `cleanupFrom` / `savedOrBeyond` / `mergedOrBeyond` | `SessionStates.` 同名 |
| `deletableSkipReasons` / `benignSkipReasons` | `SkipReasons.deletable` / `SkipReasons.benign` |

### `Sources/VDCore/States.swift`

ファイル先頭の 1 行コメント: `// Part / Session の状態・遷移表・復旧写像・集合（PLAN §5.1・付録 A.1〜A.2）。状態名の文字列はこのファイルにしか書かない（PT-06）。`

```swift
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
```

**`PartStates`**（`public enum PartStates`。すべて `public static let …: Set<PartStatus>`。宣言はこの順）:

| 名前 | 定義（Swift の式をこのとおりに書く） |
|---|---|
| `terminal` | `[.rawSaved, .sourceDeleting, .sourceDeletePending, .completed, .failed, .skipped]` |
| `deletable` | `terminal.subtracting([.failed, .skipped])` |
| `stagingDisposable` | `terminal.subtracting([.failed])` |
| `awaitingDeletion` | `deletable.subtracting([.completed])` |
| `rawNoteMembers` | `[.transcribed, .rawWriting, .rawSaved, .sourceDeleting, .sourceDeletePending, .completed]` |
| `inboxLeftover` | `terminal.subtracting([.failed])`（`stagingDisposable` と同値だが別の問い。**別定数として式を書く**。`stagingDisposable` を参照しない） |
| `inProgress` | `[.normalizing, .transcribing, .rawWriting, .sourceDeleting]` |
| `retryableFromFailed` | `[.normalizing, .transcribing, .rawWriting]` |
| `retryReset` | `[.normalized, .transcribed, .rawSaved]` |
| `normalizable` | `[.discovered, .normalizing]` |
| `transcribable` | `[.normalized, .transcribing]` |
| `rawWritable` | `[.transcribed, .rawWriting]` |
| `normalizedOrBeyond` | `[.normalized, .transcribing, .transcribed, .rawWriting, .rawSaved, .sourceDeleting, .sourceDeletePending, .completed]` |
| `transcribedOrBeyond` | `[.transcribed, .rawWriting, .rawSaved, .sourceDeleting, .sourceDeletePending, .completed]` |
| `rawSavedOrBeyond` | `[.rawSaved, .sourceDeleting, .sourceDeletePending, .completed]` |

各定数の `///` には PLAN §5.1 の「使い道」列をそのまま書く（例 `/// Session を進めてよいか（READY→MERGING のガード）。` ）。`deletable` には `/// DEL-02: terminal と混同しない。FAILED / SKIPPED は本文が保存されていない。` を書く。

**`SessionStates`**（`public enum SessionStates`。すべて `public static let …: Set<SessionStatus>`。この順）:

| 名前 | 定義 |
|---|---|
| `inProgress` | `[.merging, .analyzing, .writing, .sourceDeleting, .cleanup]` |
| `retryableFromFailed` | `[.merging, .analyzing, .writing]` |
| `retryReset` | `[.merged, .analyzed, .saved]` |
| `mergeable` | `[.ready, .merging]` |
| `analyzable` | `[.merged, .analyzing]` |
| `writable` | `[.analyzed, .writing]` |
| `processable` | `mergeable.union(analyzable).union(writable)` |
| `reopenable` | `[.saved, .sourceDeleting, .sourceDeletePending, .cleanup, .completed]`（`///` に「v1.1 で広げた。voicedock は SAVED / COMPLETED だけ（X-31）」） |
| `deleteEvaluated` | `[.saved, .sourceDeleting, .sourceDeletePending, .cleanup]` |
| `cleanupFrom` | `[.saved, .sourceDeleting, .sourceDeletePending]` |
| `savedOrBeyond` | `[.saved, .sourceDeleting, .sourceDeletePending, .cleanup, .completed]` |
| `mergedOrBeyond` | `Set<SessionStatus>([.merged, .analyzing, .analyzed, .writing]).union(savedOrBeyond)` |

**`SkipReasons`**（`public enum SkipReasons`）:

```swift
/// 根拠 B で元音声を消してよい SKIPPED の理由（PLAN §8.9.1。許可リスト）。
public static let deletable: Set<ErrorCode> = [.duplicateContent, .noSpeechDetected]
/// Daily の警告行に ⚠ を付けない理由（PLAN §8.6。NOTE-05）。**deletable と同値でも別定数**。片方の変更に追随させない。
public static let benign: Set<ErrorCode> = [.noSpeechDetected, .duplicateContent]
```

**`TransitionTable`**（`public enum TransitionTable`）:

```swift
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
```

- `SOURCE_DELETING→SOURCE_DELETE_PENDING` は normal にも recovery にも在る（Part・Session とも）。`allows` はどちらの kind でも真になる
- `static func` で「表に無い辺」を例外にしない（投げるのは VDStore の `IllegalTransition`。T-11）

### `Sources/VDCore/ErrorCode.swift`

先頭コメント: `// エラーコード（PLAN 付録 A.3）。宣言順は voicedock errors.py と同じ（Daily の警告行の並びがこれに依存する）。コード名の文字列はこのファイルにしか書かない（PT-06）。`

```swift
public enum ErrorCode: String, CaseIterable, Sendable, Hashable {
    case configUnknownKey = "CONFIG_UNKNOWN_KEY"
    case configInvalidValue = "CONFIG_INVALID_VALUE"
    case configLockMismatch = "CONFIG_LOCK_MISMATCH"
    case deviceNotReadable = "DEVICE_NOT_READABLE"
    case deviceUnsupported = "DEVICE_UNSUPPORTED"
    case fileNotStable = "FILE_NOT_STABLE"
    case duplicateContent = "DUPLICATE_CONTENT"
    case sourceMissing = "SOURCE_MISSING"
    case sourceHashMismatch = "SOURCE_HASH_MISMATCH"
    // HELPER_UNAVAILABLE は廃止（番号を詰めない。PLAN 付録 A.3）
    case deleteQueueFailed = "DELETE_QUEUE_FAILED"
    case deleteTimeout = "DELETE_TIMEOUT"
    case diskSpaceLow = "DISK_SPACE_LOW"
    case audioProbeFailed = "AUDIO_PROBE_FAILED"
    case importFailed = "IMPORT_FAILED"
    case normalizeVerifyFailed = "NORMALIZE_VERIFY_FAILED"
    case normalizedMissing = "NORMALIZED_MISSING"
    case whisperExecMissing = "WHISPER_EXEC_MISSING"
    case whisperModelMissing = "WHISPER_MODEL_MISSING"
    case whisperFailed = "WHISPER_FAILED"
    case whisperTimeout = "WHISPER_TIMEOUT"
    case noSpeechDetected = "NO_SPEECH_DETECTED"
    case obsidianRawWriteFailed = "OBSIDIAN_RAW_WRITE_FAILED"
    case obsidianRawVerifyFailed = "OBSIDIAN_RAW_VERIFY_FAILED"
    case sessionMergeFailed = "SESSION_MERGE_FAILED"
    case llmUnavailable = "LLM_UNAVAILABLE"
    case llmFailed = "LLM_FAILED"
    case llmInvalidJSON = "LLM_INVALID_JSON"
    case obsidianNotFound = "OBSIDIAN_NOT_FOUND"
    case obsidianWriteFailed = "OBSIDIAN_WRITE_FAILED"
    case obsidianVerifyFailed = "OBSIDIAN_VERIFY_FAILED"
    case sourceIdentityMismatch = "SOURCE_IDENTITY_MISMATCH"
    case sourceDeleteFailed = "SOURCE_DELETE_FAILED"
    // LOCAL_DELETE_FAILED / DB_ERROR は廃止
}

/// 再試行の区分（PLAN 付録 A.3・§5.4）。振る舞いを変えるのは `attempts`（工程内リトライの対象）だけ。
/// requeue（4 つの契機）は RetryPolicy を見ずに FAILED をすべて戻す。`none` / `nextPoll` / `nextConnect` は表示と voicedock との対応のために残す。
public enum RetryPolicy: Sendable, Hashable {
    case none
    case nextPoll
    case nextConnect
    case attempts
}

extension ErrorCode {
    /// PLAN 付録 A.3 の「再試行」列。
    public var retryPolicy: RetryPolicy { … }   // 下の表を switch で全ケース網羅（default を書かない）
    /// 宣言順の 0 始まりの位置（`ErrorCode.allCases.firstIndex(of: self)`）。Daily の警告行の並びに使う。
    public var declarationIndex: Int { … }
    /// `part_skipped` の reason 語。対象外は nil。
    public var skipReasonWord: String? { … }
    /// 工程内リトライの対象か（`retryPolicy == .attempts`。voicedock counts_against_max_attempts）。
    public var countsAgainstMaxAttempts: Bool { retryPolicy == .attempts }
}
```

`retryPolicy` の表（switch に**全 32 ケースを並べ、`default` を書かない**。新しいコードを足したときにコンパイルで気付くため）:

| RetryPolicy | コード |
|---|---|
| `.none` | configUnknownKey, configInvalidValue, configLockMismatch, deviceUnsupported, duplicateContent, sourceMissing, whisperExecMissing, whisperModelMissing, noSpeechDetected, llmInvalidJSON |
| `.nextPoll` | deviceNotReadable, fileNotStable, diskSpaceLow |
| `.nextConnect` | deleteQueueFailed, deleteTimeout, normalizedMissing, sourceIdentityMismatch, sourceDeleteFailed |
| `.attempts` | sourceHashMismatch, audioProbeFailed, importFailed, normalizeVerifyFailed, whisperFailed, whisperTimeout, obsidianRawWriteFailed, obsidianRawVerifyFailed, sessionMergeFailed, llmUnavailable, llmFailed, obsidianNotFound, obsidianWriteFailed, obsidianVerifyFailed |

`skipReasonWord`: `.sourceMissing` → `"source_missing"`、`.duplicateContent` → `"duplicate_content"`、`.noSpeechDetected` → `"no_speech"`、それ以外 → `nil`（switch で書く）。

`declarationIndex` は `ErrorCode.allCases.firstIndex(of: self) ?? ErrorCode.allCases.count`（`??` の右は到達しない。force unwrap を使わないため）。

### `Sources/VDCore/StageFailure.swift`

```swift
// 工程の運用上の失敗（ErrorCode と文言の組。00-api-map §0）。
/// 工程の運用上の失敗（ErrorCode を持つ）。error_message に入る文言は `message`（200 文字への切り詰めは VDStore が行う）。
public struct StageFailure: Error, Equatable, Sendable {
    public let code: ErrorCode
    public let message: String
    public init(_ code: ErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}
```

### `Sources/VDCore/RetryDelay.swift`

```swift
// 工程内リトライと削除評価の待ち秒の式（PLAN §5.4・§8.9.5）。
public enum RetryDelay {
    /// 工程内リトライの待ち秒（PLAN §5.4。voicedock pipeline.py:1750-1760）。
    /// retryCount < 1 か retryCount >= maxAttempts なら nil（終わり）。backoff[retryCount - 1] が無ければ nil。
    public static func inProcess(retryCount: Int, maxAttempts: Int, backoff: [Int]) -> Int? {
        guard retryCount >= 1, retryCount < maxAttempts else { return nil }
        let index = retryCount - 1
        guard index < backoff.count else { return nil }
        return backoff[index]
    }

    /// 削除評価の待ち秒（PLAN §8.9.5。voicedock pipeline.py:1855-1868）。attempts 0 と 1 はどちらも先頭の値。
    /// backoff が空なら 0（CV-52 で空は設定エラーだが、ここでは落ちない）。
    public static func deleteEvaluation(attempts: Int, backoff: [Int]) -> Int {
        guard !backoff.isEmpty else { return 0 }
        let index = min(max(attempts, 1), backoff.count) - 1
        return backoff[index]
    }
}
```

### `Sources/VDCore/RawNoteMembership.swift`

```swift
// Raw ノートに載る Part の判定（PLAN §8.6・§8.7・§8.9.1。00-api-map §2.1）。
/// Raw ノートに載る Part かどうか（PLAN §8.6・§8.7・§8.9.1）。**書き手（Raw の描画）と検証側（保存検証・削除条件の再検証）がこの関数だけを使う**（§9.1 原則 2）。
public enum RawNoteMembership {
    public static func isMember(status: PartStatus, transcriptReadable: Bool) -> Bool {
        PartStates.rawNoteMembers.contains(status) && transcriptReadable
    }
}
```

## テスト

すべて `import Testing` と `@testable import VDCore`。期待値は PLAN の表から手で書く（実装の定数を期待値に使わない。TEST-01）。

### `Tests/VDCoreTests/StatesTests.swift`（`@Suite("States") struct StatesTests`）

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `partStatusDeclarationOrder` | `Part の状態は付録 A.1 の順` | `PartStatus.allCases.map(\.rawValue) == ["DISCOVERED","NORMALIZING","NORMALIZED","TRANSCRIBING","TRANSCRIBED","RAW_WRITING","RAW_SAVED","SOURCE_DELETING","SOURCE_DELETE_PENDING","COMPLETED","FAILED","SKIPPED"]` |
| `sessionStatusDeclarationOrder` | `Session の状態は付録 A.1 の順` | 13 個を同様に逐語で |
| `initialStates` | `初期状態は DISCOVERED と OPEN` | `PartStatus.initial == .discovered`、`SessionStatus.initial == .open` |
| `partTableHas23Edges` | `Part の遷移表は 23 本` | `TransitionTable.part.count == 23`、下記の辺の列を逐語で並べた配列を `Set` にしたものと一致 |
| `sessionTableHas30Edges` | `Session の遷移表は 30 本（voicedock 24 ＋ ★6）` | 同上 |
| `starEdgesArePresent` | `★ の 6 辺が在る` | `merged→analyzed`・`analyzed→analyzing`・`writing→analyzing`・`sourceDeleting→merging`・`sourceDeletePending→merging`・`cleanup→merging` の各 `allows(…, kind: .normal)` が真 |
| `voicedockOutOfTableEdgesAreAbsent` | `voicedock が表の外で使っていた辺は表に無い` | `analyzed→failed`・`cleanup→sourceDeleting`（Session）と、復旧専用 7 辺（Part 3・Session 4）の `allows(…, kind: .normal)` が偽 |
| `recoveryMapsInOrder` | `復旧写像は付録 A.1 の順` | `partRecovery` と `sessionRecovery` の配列を逐語で比較（順序込み） |
| `recoveryOnlyEdgesNeedRecoveryKind` | `復旧専用の辺は recovery でだけ許す` | 例: `Edge(PartStatus.normalizing, .discovered)`: normal 偽・recovery 真。`Edge(SessionStatus.cleanup, .saved)`: 同じ |
| `sourceDeletingToPendingInBothKinds` | `SOURCE_DELETING→PENDING は両方の kind で許す` | Part・Session とも normal 真・recovery 真 |
| `normalEdgeIsNotRecovery` | `通常の辺は recovery では許さない` | `Edge(PartStatus.discovered, .normalizing)` の recovery が偽 |
| `openSelfTransitionOnly` | `自己遷移は OPEN→OPEN だけ` | 両表で `from == to` の辺の集合が `{open→open}` |
| `skippedHasNoOutgoingEdges` | `SKIPPED から出る辺は無い（SM-20）` | `part.filter { $0.from == .skipped }` が空 |
| `failedOutgoingEqualsRetryable` | `FAILED から出る辺の行き先 = retryableFromFailed` | Part・Session とも |

### `Tests/VDCoreTests/StatesInvariantTests.swift`（`@Suite("States invariants") struct StatesInvariantTests`）

PLAN §5.1 の不変条件（TEST-08）。**集合の中身を直書きせず、関係だけを検査する**:

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `deletableIsStrictSubsetOfTerminal` | `deletable ⊂ terminal で差は FAILED と SKIPPED（DEL-02）` | `PartStates.deletable.isStrictSubset(of: .terminal)` かつ `terminal.subtracting(deletable) == [.failed, .skipped]` |
| `stagingDisposableExcludesFailed` | `stagingDisposable は terminal から FAILED だけを除く（SM-23）` | `terminal.subtracting(stagingDisposable) == [.failed]` |
| `inboxLeftoverIsSeparateButEqual` | `inboxLeftover は terminal から FAILED だけを除く` | 同上（値の一致だけを確かめ、定義が別であることはソースの `inboxLeftover` 行に `stagingDisposable` が出ないことで PolicyTests が見る必要は無い。ここでは値だけ） |
| `awaitingDeletionIsDeletableMinusCompleted` | `awaitingDeletion = deletable − COMPLETED` | |
| `inProgressEqualsRecoveryDomain` | `進行中の全状態に復旧先がある（SM-07）` | `Set(partRecovery.map(\.from)) == PartStates.inProgress`、Session も |
| `recoveryDomainHasNoDuplicates` | `復旧写像の遷移元は重複しない` | `partRecovery.map(\.from)` の要素数 = Set の要素数、Session も |
| `retryableFromFailedIsSymmetric` | `FAILED に入る辺の遷移元 = FAILED から出る辺の行き先 = retryableFromFailed` | 表から `into = {e.from \| e.to == .failed, e.from != .failed}`、`out = {e.to \| e.from == .failed}` を作り、`into == out == retryableFromFailed`。Part・Session とも |
| `ingStatesAreInProgressOrPending` | `名前が ING で終わる状態は進行中か SOURCE_DELETE_PENDING（SM-10）` | 全ケースを回し、`rawValue.hasSuffix("ING")` なら `inProgress` に在るか `== .sourceDeletePending` |
| `inProgressIsNotTerminalExceptSourceDeleting` | `進行中は終端ではない（SOURCE_DELETING だけは終端にも含む）` | `PartStates.inProgress.intersection(PartStates.terminal.subtracting([.sourceDeleting])).isEmpty` かつ `PartStates.terminal.contains(.sourceDeleting)` |
| `recoveryTargetsCanResume` | `復旧の行き先から通常の辺で再開できる` | 各復旧辺 `a→b` について `b` を `from` とする normal 辺が 1 本以上あり、かつ `b` は `inProgress` に無い |
| `allStatesReachable` | `初期状態から全状態へ到達できる` | normal 表で幅優先探索し、到達集合 == `allCases` の集合（Part・Session） |
| `retryResetAreStagePasses` | `retry_count を戻す状態は工程通過の状態` | `retryReset` のどの rawValue も `ING` で終わらない。Part 3 件・Session 3 件 |
| `processableIsUnion` | `processable = mergeable ∪ analyzable ∪ writable` | |
| `cleanupFromIsInDeleteEvaluated` | `cleanupFrom ⊂ deleteEvaluated` | |
| `savedOrBeyondInMergedOrBeyond` | `savedOrBeyond ⊂ mergedOrBeyond` | |
| `beyondSetsAreNested` | `rawSavedOrBeyond ⊂ transcribedOrBeyond ⊂ normalizedOrBeyond` | 真部分集合 |
| `rawSavedOrBeyondEqualsDeletable` | `rawSavedOrBeyond = deletable` | 値の一致（別の問いだが現状同値であることの固定） |
| `stageEntrancesContainTheirInProgress` | `各工程の入口は進行中の状態を含む（SM-08）` | `normalizable ∋ .normalizing`、`transcribable ∋ .transcribing`、`rawWritable ∋ .rawWriting`、`mergeable ∋ .merging`、`analyzable ∋ .analyzing`、`writable ∋ .writing` |
| `reopenableHasDeletionStages` | `再オープン元は削除段を含む（X-31）` | `SessionStates.reopenable == [.saved, .sourceDeleting, .sourceDeletePending, .cleanup, .completed]`、各要素 `x` について `Edge(x, .merging)` が normal 表に在る |
| `skipReasonsAreSeparateConstants` | `deletable と benign は同値だが別定数` | `SkipReasons.deletable == SkipReasons.benign`、どちらも `{.duplicateContent, .noSpeechDetected}` |
| `deletableSkipReasonsAreSkipCodes` | `根拠 B の理由は skipReasonWord を持つ` | `SkipReasons.deletable` の各コードの `skipReasonWord != nil` |

### `Tests/VDCoreTests/ErrorCodeTests.swift`（`@Suite("ErrorCode") struct ErrorCodeTests`）

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `declarationOrderMatchesAppendixA3` | `宣言順は付録 A.3 の順（voicedock errors.py から 3 つを除いた順）` | `allCases.map(\.rawValue)` を 32 個の逐語の配列と比較 |
| `abolishedCodesAreAbsent` | `廃止した 3 コードは無い` | `ErrorCode(rawValue:)` が `HELPER_UNAVAILABLE`・`LOCAL_DELETE_FAILED`・`DB_ERROR` で nil |
| `retryPolicyTable` | `再試行の区分は付録 A.3 の表どおり` | 32 行の `(rawValue, "none"\|"nextPoll"\|"nextConnect"\|"attempts")` の表と `String(describing: retryPolicy)` を全件比較（パラメータ化テスト `arguments:` に表を渡す。SPEC 同期の `errorCodesMatchSpec` と同じ表記） |
| `everyCodeHasRetryPolicy` | `全コードに RetryPolicy がある（TEST-08）` | `allCases` の各要素で `retryPolicy` を評価して落ちない（switch の網羅はコンパイラが保証するので、件数 32 の確認） |
| `countsAgainstMaxAttemptsOnlyAttempts` | `工程内リトライの対象は attempts だけ` | `allCases.filter(\.countsAgainstMaxAttempts)` が `.attempts` の 14 個と一致 |
| `skipReasonWords` | `part_skipped の reason 語` | 3 コードの語が逐語で一致し、他の 29 コードは nil |
| `declarationIndexIsPosition` | `declarationIndex は宣言順の位置` | `.configUnknownKey` 0、`.duplicateContent` 6、`.noSpeechDetected` 20、`.sourceDeleteFailed` 31 |
| `stageFailureEquality` | `StageFailure は code と message で等しい` | |

### `Tests/VDCoreTests/RetryDelayTests.swift`（`@Suite("RetryDelay") struct RetryDelayTests`）

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `inProcessDefault` | `既定 3 回・[3,10,30] は 3 秒・10 秒で終わる` | `(1,3,[3,10,30]) → 3`、`(2,…) → 10`、`(3,…) → nil`、`(0,…) → nil` |
| `inProcessShortBackoff` | `backoff が足りなければ nil` | `(2, 5, [3]) → nil` |
| `deleteEvaluationZeroAndOneAreFirst` | `削除評価の attempts 0 と 1 は先頭の値（voicedock test_retry.py:517）` | `(0,[60,300,900,3600]) → 60`、`(1,…) → 60`、`(2,…) → 300`、`(4,…) → 3600`、`(9,…) → 3600` |
| `deleteEvaluationEmpty` | `削除評価の backoff が空なら 0` | `(3, []) → 0` |

### `Tests/VDCoreTests/RawNoteMembershipTests.swift`

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `membersNeedReadableTranscript` | `rawNoteMembers でも transcript が読めなければ載らない` | 全 PartStatus × {true,false} の 24 通り: 真になるのは `rawNoteMembers` の 6 状態 × true の 6 通りだけ |

### `Tests/VDCoreTests/SpecSyncStatesTests.swift`（`@Suite("SpecSyncStates") struct SpecSyncStatesTests`。T-05 §5 の全文）

T-05 の `SpecDocument`（TestSupport）で `docs/SPEC.md` を読む。関数名・表示名・中身は T-05 §5 の全文のとおり（ここで変えない）:

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `partStatesMatchSpec` | `Part の状態の宣言順が SPEC と同じ` | S1 の「Part の状態」の表の `` `X` `` の出現順 == `PartStatus.allCases.map(\.rawValue)` |
| `sessionStatesMatchSpec` | `Session の状態の宣言順が SPEC と同じ` | 同上（Session） |
| `partTransitionsMatchSpec` | `Part の遷移表が SPEC と同じ（辺の集合）` | S2 の `Part:` のフェンスの `A→B` の集合（★と括弧の注記は無視）== `TransitionTable.part` を rawValue の組にした集合 |
| `sessionTransitionsMatchSpec` | `Session の遷移表が SPEC と同じ（辺の集合）` | 同上（30 本） |
| `partRecoveryMatchesSpec` | `Part の復旧写像が SPEC と同じ（順も）` | S1 のフェンスの行頭 `Part:` の辺の列 == `partRecovery` |
| `sessionRecoveryMatchesSpec` | `Session の復旧写像が SPEC と同じ（順も）` | 同上（`sessionRecovery`） |
| `errorCodesMatchSpec` | `エラーコードの宣言順と再試行が SPEC と同じ` | S3 の表の `` `X` ``（`\| — \|` の廃止の行を除く）の出現順 == `ErrorCode.allCases.map(\.rawValue)`、各行の 3 列目 == `String(describing: retryPolicy)`（`none`/`nextPoll`/`nextConnect`/`attempts`） |

## 一回限りの照合（PR 本文に結果を貼る。スクリプトはコミットしない）

PLAN 付録 A.2 の注記どおり、voicedock の表と本チケットの表の差が ★ の 6 本だけであることを確かめる。scratch のディレクトリで:

```bash
mkdir -p /tmp/t08 && cd /tmp/t08
git -C /Users/terada/Projects/voicedock show d3d595e:src/voicedock/states.py > states_d3d595e.py
cat > compare.py <<'PY'
import re, sys
sys.path.insert(0, ".")
import states_d3d595e as s
vd_part = {(a.value, b.value) for a, b in s.PART_TRANSITIONS}
vd_sess = {(a.value, b.value) for a, b in s.SESSION_TRANSITIONS}
src = open(sys.argv[1], encoding="utf-8").read()
def swift_edges(name):
    block = src.split(f"public static let {name}:")[1].split("]\n")[0]
    pairs = re.findall(r"Edge\(\.(\w+), \.(\w+)\)", block)
    snake = lambda c: re.sub(r"(?<!^)([A-Z])", r"_\1", c).upper()
    return {(snake(a), snake(b)) for a, b in pairs}
sw_part, sw_sess = swift_edges("part"), swift_edges("session")
print("Part    vd=%d swift=%d swift-only=%s vd-only=%s" % (len(vd_part), len(sw_part), sorted(sw_part - vd_part), sorted(vd_part - sw_part)))
print("Session vd=%d swift=%d swift-only=%s vd-only=%s" % (len(vd_sess), len(sw_sess), sorted(sw_sess - vd_sess), sorted(vd_sess - sw_sess)))
PY
python3 compare.py <repo>/Sources/VDCore/States.swift
```

期待する出力（逐語）:

```text
Part    vd=23 swift=23 swift-only=[] vd-only=[]
Session vd=24 swift=30 swift-only=[('ANALYZED', 'ANALYZING'), ('CLEANUP', 'MERGING'), ('MERGED', 'ANALYZED'), ('SOURCE_DELETE_PENDING', 'MERGING'), ('SOURCE_DELETING', 'MERGING'), ('WRITING', 'ANALYZING')] vd-only=[]
```

（`rawWriting` → `RAW_WRITING` のように camelCase を大文字の snake に直して比べる。`sourceDeletePending` → `SOURCE_DELETE_PENDING`。）

## 破壊による証明

| 壊し方（1 回に 1 か所） | 落ちるべきテスト |
|---|---|
| `PartStates.deletable` の定義から `.failed` を引くのをやめる（`terminal.subtracting([.skipped])`） | `deletableIsStrictSubsetOfTerminal` |
| `TransitionTable.session` から `Edge(.cleanup, .merging)` を消す | `sessionTableHas30Edges`、`starEdgesArePresent`、`reopenableHasDeletionStages`、`sessionTransitionsMatchSpec` |
| `partRecovery` の 1 番目と 2 番目を入れ替える | `recoveryMapsInOrder`、`partRecoveryMatchesSpec` |
| `SessionStates.inProgress` から `.cleanup` を消す | `inProgressEqualsRecoveryDomain` |
| `ErrorCode` の `.sourceMissing` と `.duplicateContent` の宣言を入れ替える | `declarationOrderMatchesAppendixA3`、`errorCodesMatchSpec` |
| `.whisperTimeout` の retryPolicy を `.none` にする | `retryPolicyTable`、`countsAgainstMaxAttemptsOnlyAttempts`、`errorCodesMatchSpec` |
| `RetryDelay.deleteEvaluation` の `max(attempts, 1)` を `attempts` にする | `deleteEvaluationZeroAndOneAreFirst` |
| `RetryDelay.inProcess` の `retryCount < maxAttempts` を `<=` にする | `inProcessDefault` |
| `RawNoteMembership.isMember` の `&& transcriptReadable` を消す | `membersNeedReadableTranscript` |
| `PartStates.retryableFromFailed` に `.discovered` を足す | `retryableFromFailedIsSymmetric` |

## 受け入れ条件

- [ ] 上の 11 ファイルがあり、`make lint` と `make test` が通る
- [ ] 状態名・エラーコード名の文字列リテラルが `States.swift` / `ErrorCode.swift` 以外の `Sources/` に無い（PT-06 が緑）
- [ ] `.recovery` を書いているのが `States.swift` だけ（PT-21 が緑）
- [ ] `retryPolicy` と `skipReasonWord` の switch に `default` が無い
- [ ] 一回限りの照合の出力を PR 本文に貼った
- [ ] 破壊による証明の 10 項目を行い、落ちたテスト名を PR 本文に貼った

## SPEC の変更

- `docs/SPEC.md` の付録 A.1〜A.3 は T-05 が PLAN から写したものをそのまま使う（変更なし）。本チケットで食い違いが見つかったら PLAN と SPEC を同じ PR で直す

## マージ後にやること

なし

## API 地図への変更提案

- なし（00-api-map §2.1 のとおり）。ただし `PartStates` / `SessionStates` の名前は PLAN §5.1 の「集合（Swift 名）」列（`partTerminal` など）と表記が違う。PLAN §5.1 の列を「Swift 名（`PartStates.terminal` など）」に直すことを提案する（本チケットの対応表を正とする） → PLAN §5.1 に反映済み（2026-09-18。列名を「v1.1 の説明用の名前。Swift では `PartStates.terminal` のように型の中に置く。対応は T-08」とした）
- `ErrorCode.countsAgainstMaxAttempts` を公開 API に足した（工程内リトライの判定。T-18 が使う） → 00-api-map に反映済み（2026-09-18）
- （整合修正で追記）SPEC 同期のテストは T-05 §5 の置き場所と名前（`Tests/VDCoreTests/SpecSyncStatesTests.swift`・7 本）に合わせた
- （実装で追記・決定）`RetryPolicy` の rawValue（`next_poll` など）はどこからも使われず、SPEC 同期の `String(describing:)`（`nextPoll`）と表記が 2 通りになるので、利用者の判断で `: String` を外した（2026-09-21）。00-api-map §2.1 の `RetryPolicy: Sendable` と一致する。地図の変更は不要
