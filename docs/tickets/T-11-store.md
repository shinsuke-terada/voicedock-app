# T-11 VDStore: スキーマ・マイグレーション・遷移・列更新・問い合わせ・読み取り専用

> （F-82・issue #119。2026-09-23。マージ後の追記）`Transitions.swift` に `groupPart(_ partkey: String, into session: NewSession) throws -> SessionStatus` を足した（分組の 1 件: Session の作成（無ければ。events に NULL→OPEN）・`session_key`・集計・OPEN なら `OPEN→OPEN`（detail = partkey）を 1 トランザクションで行い、分組した時点の状態を返す。PLAN §5.2・§5.6）。
> 同じトランザクションで使うため、遷移の SQL（`applyTransition`）・Session の行の作成（`insertSessionRow`）・集計（`Queries.swift` の `refreshSessionAggregates(_ db:key:now:)`）を `Database` を受ける static 関数に分けた（SQL は 1 か所のまま。CR-06）。テストは `Tests/VDStoreTests/GroupPartTests.swift`（表示名は `F-82` で始まる）。

- Phase: 2（記録の土台）
- 前提: T-08（`PartStatus` / `SessionStatus` / `TransitionTable` / `PartStates` / `SessionStates` / `ErrorCode`）、T-10（`Instant` / `AppClock` / `ZonedTime` / `TextLimit`、TestSupport の `FixedClock` / `SteppingClock`）。TestSupport の `TempDirectory`（T-01）は T-08 の前提として入っている
- 見積もり: 実装 約 650 行、テスト 約 700 行

## 1. 目的

SQLite（GRDB `DatabasePool`、WAL）を「全状態の単一の真実」として用意する。状態を変える API は `recordPartTransition` / `recordSessionTransition` と行の作成（`insertRecording` / `insertSession`）だけにし、
遷移表の検査・楽観的同時実行制御・`events` への記録・`retry_count` の規則・200 文字の切り詰め・`updated_at` の更新を 1 か所に閉じ込める。
問い合わせはすべて `Store` のメソッドにし（CONC-02）、診断と状態表示のための「DB を作らない」読み取り経路（`ReadOnlyStore`）を用意する。

## 2. 参照

- PLAN §5.1（集合）、§5.2（状態を変える API）、§5.3（復旧で使う問い合わせ）、§5.6（集計の SQL）、§7 全体、§8.12（状態の詳細）、付録 A.1〜A.3、PT-05 / PT-06 / PT-21
- voicedock@d3d595e: `src/voicedock/db.py`（`record_transition` 304-367、`_insert` 388-424、問い合わせ 436-545、`_update` 562-607、`connect` 659-688）、
  `src/voicedock/migrations/0001_initial.sql` / `0002_delete_request_id.sql` / `0003_duplicate_of.sql`、`src/voicedock/status.py`（`_counts` / `_backlog` / `_failed` 269-371）、
  `tests/unit/test_db.py`、`tests/unit/test_migration_rules.py`
- GRDB 7.11.1: `DatabasePool(path:configuration:)`、`Configuration.prepareDatabase(_:)`、`DatabaseMigrator`、`DatabaseReader.backup(to:pagesPerStep:progress:)`、`Row.decode(_:forColumn:)`、`Database.changesCount`

### 2.1 GRDB の注意点（確認済み。実装者が必ず守る）

- `DatabasePool` は writer を開いた**後で** `setUpWALMode()` を呼び、その中で **`PRAGMA synchronous = NORMAL` を実行する**（GRDB `Database.swift:531-539`）。
  `prepareDatabase` で `synchronous = FULL` を設定しても writer では上書きされる。**プールを作った後に writer で `PRAGMA synchronous = FULL` を実行し直し、`PRAGMA synchronous` が `2` であることを確かめる**
- `Row` の非 Optional の添字（`row["x"] as String`）は NULL や型違いで**プロセスを落とす**。行の読み取りは必ず `try row.decode(T.self, forColumn:)`（Optional は `T?.self`）を使う（CR-04 / CR-16）
- GRDB は既定で二重引用符の文字列リテラルを無効にしている（`setupDoubleQuotedStringLiterals`）。SQL の中で文字列を書かない（値はすべて `?` で束縛する）
- `DatabaseMigrator` は `Sendable`。`DatabasePool` は `Sendable`（GRDB 側で宣言済み）なので `Store` は `@unchecked` なしで `Sendable` になる

## 3. 作るもの

```
Sources/VDStore/Store.swift
Sources/VDStore/StoreError.swift
Sources/VDStore/Schema.swift
Sources/VDStore/EntityType.swift
Sources/VDStore/Rows.swift
Sources/VDStore/Transitions.swift
Sources/VDStore/Updates.swift
Sources/VDStore/Queries.swift
Sources/VDStore/ReadOnlyStore.swift
Tests/TestSupport/Builders.swift
Tests/VDStoreTests/StoreOpenTests.swift
Tests/VDStoreTests/SchemaTests.swift
Tests/VDStoreTests/TransitionsTests.swift
Tests/VDStoreTests/UpdatesTests.swift
Tests/VDStoreTests/QueriesTests.swift
Tests/VDStoreTests/BackupTests.swift
Tests/VDStoreTests/ReadOnlyStoreTests.swift
```

`Package.swift`: `VDStore` ターゲット（依存 `VDContract`・`VDCore`・`GRDB`）と `VDStoreTests`（依存 `VDStore`・`TestSupport`）は T-01 で宣言済みであること。無ければこの PR で足す。

## 4. 仕様

### 4.1 `StoreError.swift`

```swift
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
```

### 4.2 `EntityType.swift`

```swift
// events.entity_type の値と、表・主キー列の対応（PLAN §5.2）。
public enum EntityType: String, Sendable, CaseIterable {
    case recording
    case session

    /// SQL へ埋め込んでよい唯一の可変部分（2 値の enum から来る固定文字列）
    var table: String { self == .recording ? "recordings" : "sessions" }
    var keyColumn: String { self == .recording ? "partkey" : "session_key" }
}
```

### 4.3 `Schema.swift`

```swift
// v1_initial の DDL（PLAN §7.2 の逐語）と DatabaseMigrator。
import GRDB

enum Schema {
    static let v1InitialIdentifier = "v1_initial"
    static let v1Initial: String = """
        CREATE TABLE sessions (
            session_key         TEXT    PRIMARY KEY NOT NULL,
            day_date            TEXT    NOT NULL,
            device_id           TEXT    NOT NULL,
            started_at          TEXT,
            ended_at            TEXT,
            recorded_seconds    REAL,
            part_count          INTEGER NOT NULL DEFAULT 0,
            failed_part_count   INTEGER NOT NULL DEFAULT 0,
            title               TEXT,
            analysis_path       TEXT,
            raw_output_path     TEXT,
            raw_output_sha256   TEXT,
            output_path         TEXT,
            output_sha256       TEXT,
            status              TEXT    NOT NULL,
            retry_count         INTEGER NOT NULL DEFAULT 0,
            regenerated_count   INTEGER NOT NULL DEFAULT 0,
            delete_attempts     INTEGER NOT NULL DEFAULT 0,
            error_code          TEXT,
            error_message       TEXT,
            source_deleted_at   TEXT,
            updated_at          TEXT    NOT NULL
        );
        CREATE INDEX idx_sessions_status ON sessions (status);
        CREATE INDEX idx_sessions_day    ON sessions (day_date);

        CREATE TABLE recordings (
            partkey               TEXT    PRIMARY KEY NOT NULL,
            device_id             TEXT    NOT NULL,
            source_folder         TEXT    NOT NULL,
            transmitter_id        TEXT    NOT NULL,
            mic_index             INTEGER NOT NULL,
            started_at            TEXT    NOT NULL,
            duration_seconds      REAL,
            ended_at              TEXT,
            source_path           TEXT,
            source_size           INTEGER,
            source_mtime          REAL,
            sha256                TEXT,
            sha256_helper         TEXT,
            inbox_path            TEXT,
            staging_dir           TEXT,
            normalized_path       TEXT,
            transcript_path       TEXT,
            session_key           TEXT REFERENCES sessions(session_key) ON DELETE SET NULL,
            status                TEXT    NOT NULL,
            retry_count           INTEGER NOT NULL DEFAULT 0,
            error_code            TEXT,
            error_message         TEXT,
            source_deleted_at     TEXT,
            updated_at            TEXT    NOT NULL,
            delete_request_id     TEXT,
            duplicate_of          TEXT,
            needs_recopy          INTEGER NOT NULL DEFAULT 0
        );
        CREATE UNIQUE INDEX idx_recordings_sha ON recordings (sha256) WHERE sha256 IS NOT NULL;
        CREATE INDEX idx_recordings_status   ON recordings (status);
        CREATE INDEX idx_recordings_session  ON recordings (session_key);
        CREATE INDEX idx_recordings_started  ON recordings (started_at);

        CREATE TABLE events (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            entity_type   TEXT NOT NULL,
            entity_key    TEXT NOT NULL,
            from_status   TEXT,
            to_status     TEXT NOT NULL,
            error_code    TEXT,
            detail        TEXT,
            created_at    TEXT NOT NULL
        );
        CREATE INDEX idx_events_entity ON events (entity_type, entity_key, id);

        CREATE TABLE imported_keys (
            partkey      TEXT PRIMARY KEY NOT NULL,
            source_note  TEXT NOT NULL,
            imported_at  TEXT NOT NULL
        );
        """
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(v1InitialIdentifier) { db in
            try db.execute(sql: v1Initial)
        }
        return migrator
    }
}
```

- `v1Initial` は PLAN §7.2 の DDL から `--` のコメントだけを取り除いたもの（上の逐語。列の並び・型・制約・既定値・索引名は 1 文字も変えない）。Swift の複数行文字列の字下げ（8 空白）は取り除かれる
- `eraseDatabaseOnSchemaChange` は既定（false）のまま。`registerMigration` の `foreignKeyChecks` も既定（`.deferred`）
- **テーブルを作り直す移行を書かない。列の追加は末尾へ**（v2 以降の規則。今回は v1 だけ）

### 4.4 `Store.swift`

```swift
// SQLite（GRDB DatabasePool・WAL）の開設とマイグレーション（PLAN §7.1 / §7.2）。
import Foundation
import GRDB
import VDCore

public final class Store: Sendable {
    let pool: DatabasePool
    let clock: any AppClock
    let zone: ZonedTime
    let url: URL

    static let busyTimeoutMilliseconds = 10_000
    static let recoveryDetail = "recovery"

    public convenience init(url: URL, clock: any AppClock, zone: ZonedTime) throws(StoreError) {
        try self.init(url: url, clock: clock, zone: zone, migrator: Schema.migrator())
    }

    /// テスト用（@testable）。移行器を差し替えてバックアップの条件を試す
    init(url: URL, clock: any AppClock, zone: ZonedTime, migrator: DatabaseMigrator) throws(StoreError)

    public var appliedMigrations: [String] { get throws }
    public func quickCheck() throws -> String
}
```

`init(url:clock:zone:migrator:)` の手順（この順。どれかが失敗したら以降を行わない）:

1. `var config = Configuration()`、`config.label = "VoiceDock"`、`config.foreignKeysEnabled = true`、`config.busyMode = .timeout(10)`、
   `config.prepareDatabase { db in try db.execute(sql: "PRAGMA foreign_keys = ON"); try db.execute(sql: "PRAGMA busy_timeout = 10000"); try db.execute(sql: "PRAGMA synchronous = FULL") }`
2. `pool = try DatabasePool(path: url.path(percentEncoded: false), configuration: config)`（URL からパス文字列を取るのは `path(percentEncoded: false)` だけ。00-api-map §0）。失敗 → `StoreError.open(String(describing: error))`。
   GRDB が WAL を有効にできなかったときの `DatabaseError`（説明に `"could not activate WAL Mode"` を含む）は `StoreError.notWAL` に写す
3. writer で（`pool.writeWithoutTransaction`）:
   - `let mode = try String.fetchOne(db, sql: "PRAGMA journal_mode")`。`mode?.lowercased() != "wal"` → `StoreError.notWAL`
   - `try db.execute(sql: "PRAGMA synchronous = FULL")`（§2.1 の上書き対策）→ `let sync = try Int.fetchOne(db, sql: "PRAGMA synchronous")`。`sync != 2` → `StoreError.open("synchronous is not FULL")`
   - 失敗の写し方: 投げられた `StoreError` はそのまま、それ以外は `.open(String(describing:))`
4. 移行の状態を読む（`pool.read`）: `applied = try migrator.appliedMigrations(db)`、`superseded = try migrator.hasBeenSuperseded(db)`、`completed = try migrator.hasCompletedMigrations(db)`。
   失敗 → `.migration(String(describing:))`
5. `superseded` なら → `StoreError.migration("superseded")`（より新しいアプリが当てた版がある。書かない）
6. `completed` でなく、かつ `applied` が空でない（= **既存の DB に未適用がある**）ときだけバックアップ（§4.4.1）。空なら（初回作成）バックアップしない
7. `try migrator.migrate(pool)`。失敗 → `.migration(String(describing:))`
8. `self.pool` / `clock` / `zone` / `url` を保持する

#### 4.4.1 バックアップ

- 名前: `url.lastPathComponent + ".backup-" + last + "-" + stamp`。`last` は `applied.last`（`applied` が空ならこの手順に来ないので、`guard let last = applied.last` で取り出す。`!` は使わない。到達しない else は `StoreError.migration("no applied migration")`）。
  例 `voicedock.sqlite.backup-v1_initial-20260830T070012+0900`
- `stamp = zone.iso(clock.now())` から `:` と `-` をすべて取り除いた文字列（`2026-08-30T07:00:12+09:00` → `20260830T070012+0900`。voicedock db.py:287-289 と同じ）
- 置き場所: `url` と同じディレクトリ
- 手順: `let destination = try DatabaseQueue(path: backupURL.path(percentEncoded: false))` → `try pool.backup(to: destination)`。失敗 → `StoreError.backup(String(describing:))`。**ファイルコピーは禁止**（WAL の未チェックポイント分が失われる。CONC-04）

#### 4.4.2 その他

- `appliedMigrations`: `try pool.read { try Schema.migrator().appliedMigrations($0) }`（登録順）
- `quickCheck()`: `try pool.read { try String.fetchOne($0, sql: "PRAGMA quick_check") ?? "" }`
- 内部の現在時刻: `func nowISO() -> String { zone.iso(clock.now()) }`（**呼ぶたびに取る**。TIME-04）
- Store のメソッドはすべて同期（GRDB の同期 API）。1 回の呼び出しはミリ秒単位なので actor から直接呼んでよい（PLAN §2.1 の「長い同期処理」に当たらない）。移行とバックアップは起動時の 1 回だけ

### 4.5 `Rows.swift`

```swift
// recordings / sessions / events の 1 行（PLAN §7.2 の列と 1 対 1）。GRDB の永続化 API は使わない（PT-05）。
import GRDB
import VDCore

public struct RecordingRow: Equatable, Sendable {
    public let partkey: String
    public let deviceID: String            // device_id
    public let sourceFolder: String        // source_folder
    public let transmitterID: String       // transmitter_id
    public let micIndex: Int               // mic_index
    public let startedAt: String           // started_at
    public let durationSeconds: Double?    // duration_seconds
    public let endedAt: String?            // ended_at
    public let sourcePath: String?         // source_path
    public let sourceSize: Int64?          // source_size
    public let sourceMtime: Double?        // source_mtime
    public let sha256: String?
    public let sha256Helper: String?       // sha256_helper
    public let inboxPath: String?          // inbox_path
    public let stagingDir: String?         // staging_dir
    public let normalizedPath: String?     // normalized_path
    public let transcriptPath: String?     // transcript_path
    public let sessionKey: String?         // session_key
    public let status: PartStatus
    public let retryCount: Int             // retry_count
    public let errorCode: ErrorCode?       // error_code（未知の文字列は nil）
    public let errorCodeRaw: String?       // error_code の生の文字列（未知のコードもそのまま残す。列ではなく導出。Daily の警告行が使う）
    public let errorMessage: String?       // error_message
    public let sourceDeletedAt: String?    // source_deleted_at
    public let updatedAt: String           // updated_at
    public let deleteRequestID: String?    // delete_request_id
    public let duplicateOf: String?        // duplicate_of
    public let needsRecopy: Bool           // needs_recopy（0 / 1）

    init(row: Row) throws(StoreError)
}

public struct SessionRow: Equatable, Sendable {
    public let sessionKey: String          // session_key
    public let dayDate: String             // day_date
    public let deviceID: String            // device_id
    public let startedAt: String?
    public let endedAt: String?
    public let recordedSeconds: Double?    // recorded_seconds
    public let partCount: Int              // part_count
    public let failedPartCount: Int        // failed_part_count
    public let title: String?
    public let analysisPath: String?       // analysis_path
    public let rawOutputPath: String?      // raw_output_path
    public let rawOutputSHA256: String?    // raw_output_sha256
    public let outputPath: String?         // output_path
    public let outputSHA256: String?       // output_sha256
    public let status: SessionStatus
    public let retryCount: Int
    public let regeneratedCount: Int       // regenerated_count
    public let deleteAttempts: Int         // delete_attempts
    public let errorCode: ErrorCode?
    public let errorMessage: String?
    public let sourceDeletedAt: String?
    public let updatedAt: String

    init(row: Row) throws(StoreError)
}

public struct EventRow: Equatable, Sendable {
    public let id: Int64
    public let entityType: EntityType      // entity_type
    public let entityKey: String           // entity_key
    public let fromStatus: String?         // from_status（行の作成は nil）
    public let toStatus: String            // to_status
    public let errorCode: String?          // error_code（文字列のまま）
    public let detail: String?
    public let createdAt: String           // created_at

    init(row: Row) throws(StoreError)
}

/// 行の作成（insertRecording）に渡す列。status は DISCOVERED 固定、updated_at は now、その他の列は既定（NULL / 0）
public struct NewRecording: Equatable, Sendable {
    public let partkey: String
    public let deviceID: String
    public let sourceFolder: String
    public let transmitterID: String
    public let micIndex: Int
    public let startedAt: String
    public let durationSeconds: Double?
    public let endedAt: String?
    public let sourcePath: String
    public let sourceSize: Int64
    public let sourceMtime: Double
    public let sha256Helper: String
    public let inboxPath: String
    public init(partkey: String, deviceID: String, sourceFolder: String, transmitterID: String, micIndex: Int,
                startedAt: String, durationSeconds: Double?, endedAt: String?, sourcePath: String,
                sourceSize: Int64, sourceMtime: Double, sha256Helper: String, inboxPath: String)
}

/// 行の作成（insertSession）に渡す列。status は OPEN 固定、updated_at は now
public struct NewSession: Equatable, Sendable {
    public let sessionKey: String
    public let dayDate: String   // yyyy-MM-dd
    public let deviceID: String
    public init(sessionKey: String, dayDate: String, deviceID: String)
}
```

`init(row:)` の規則（3 つの行の型で共通）:

- 各列を `try row.decode(T.self, forColumn: "<列名>")`（NULL 可の列は `T?.self`）で読む。`Int` の列は `Int`、`INTEGER` の `source_size` は `Int64`、`REAL` は `Double`、`TEXT` は `String`
- 失敗（NULL であってはならない列が NULL・型違い）→ `StoreError.corruptRow("<table>.<column> key=<主キーの値か ?>")`
- `status`: `PartStatus(rawValue:)` / `SessionStatus(rawValue:)` が nil → `StoreError.corruptRow("recordings.status key=<partkey>")`
- `error_code`: **1 つの列から 2 つのプロパティを作る**。`String?` で読んだ値をそのまま `errorCodeRaw` に入れ、`errorCode` は `errorCodeRaw.flatMap(ErrorCode.init(rawValue:))`。未知の文字列は `errorCode == nil` / `errorCodeRaw == "<その文字列>"`（行は読める）。列は 27 のままで `error_code_raw` 列は作らない
- `needs_recopy`: `Int` で読み、`!= 0` を真
- `entity_type`: `EntityType(rawValue:)` が nil → `corruptRow("events.entity_type id=<id>")`
- `throws(StoreError)` の中で GRDB の例外を捕まえて写す（`do { … } catch { throw .corruptRow(…) }`）

### 4.6 `Transitions.swift`（PT-05 の許可場所。PT-21 の許可場所）

```swift
// 状態を変える唯一の API（遷移と行の作成）。遷移表の検査・楽観的同時実行制御・events を 1 トランザクションで（PLAN §5.2）。
import GRDB
import VDCore

public struct TransitionConflict: Error, Equatable, Sendable {
    public let key: String
    public let expected: String   // 期待した from の rawValue
}

public struct IllegalTransition: Error, Equatable, Sendable {
    public let from: String
    public let to: String
    public let kind: TransitionKind
}

extension Store {
    public func recordPartTransition(partkey: String, from: PartStatus, to: PartStatus, kind: TransitionKind = .normal,
                                     errorCode: ErrorCode? = nil, errorMessage: String? = nil,
                                     detail: String? = nil, resetRetry: Bool = false) throws
    public func recordSessionTransition(sessionKey: String, from: SessionStatus, to: SessionStatus, kind: TransitionKind = .normal,
                                        errorCode: ErrorCode? = nil, errorMessage: String? = nil,
                                        detail: String? = nil, resetRetry: Bool = false) throws
    public func insertRecording(_ row: NewRecording) throws
    public func insertSession(_ row: NewSession) throws
    /// status が期待どおりのときだけ列を更新する（状態は変えない）。更新したら true
    public func updateRecordingIfStatus(_ partkey: String, status: PartStatus, _ fields: [RecordingField]) throws -> Bool
}

enum RetryExpression {
    case reset, increment, keep
    var sql: String {
        switch self {
        case .reset: "0"
        case .increment: "retry_count + 1"
        case .keep: "retry_count"
        }
    }
}
```

`recordPartTransition` の手順（Session も同じ。集合と表だけが違う）:

1. `let edge = Edge(from, to)`（T-08 の `Edge` の init はラベル無し）。`TransitionTable.allows(edge, kind: kind)` が偽 → `throw IllegalTransition(from: from.rawValue, to: to.rawValue, kind: kind)`（DB に触らない）
2. `retry`: `resetRetry || PartStates.retryReset.contains(to)` なら `.reset`、そうでなく `to == .failed` なら `.increment`、それ以外 `.keep`
   （Session は `SessionStates.retryReset`・`.failed`）
3. `let storedDetail = kind == .recovery ? Store.recoveryDetail : detail`（`.recovery` のとき引数の detail は無視）
4. `try transition(entity: .recording, key: partkey, from: from.rawValue, to: to.rawValue, retry: retry, errorCode: errorCode?.rawValue, errorMessage: errorMessage, detail: storedDetail)`

内部の `transition(entity:key:from:to:retry:errorCode:errorMessage:detail:)`:

```swift
let now = nowISO()
try pool.write { db in
    try db.execute(
        sql: "UPDATE \(entity.table) SET status = ?, retry_count = \(retry.sql), error_code = ?, error_message = ?, updated_at = ? "
            + "WHERE \(entity.keyColumn) = ? AND status = ?",
        arguments: [to, errorCode, errorMessage.map(TextLimit.truncate200), now, key, from])
    guard db.changesCount == 1 else { throw TransitionConflict(key: key, expected: from) }
    try Store.insertEvent(db, entity: entity, key: key, from: from, to: to, errorCode: errorCode, detail: detail, createdAt: now)
}
```

- `pool.write` はトランザクション。中で投げるとロールバックされる（UPDATE も events も残らない）
- **行が無いときも** `changesCount == 0` なので `TransitionConflict`
- `error_code` / `error_message` は**無条件に上書き**（nil なら NULL）

`insertEvent`（static、internal）:

```swift
static func insertEvent(_ db: Database, entity: EntityType, key: String, from: String?, to: String,
                        errorCode: String?, detail: String?, createdAt: String) throws {
    try db.execute(
        sql: "INSERT INTO events (entity_type, entity_key, from_status, to_status, error_code, detail, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        arguments: [entity.rawValue, key, from, to, errorCode, detail.map(TextLimit.truncate200), createdAt])
}
```

`insertRecording` の SQL（逐語）と手順:

```swift
let now = nowISO()
try pool.write { db in
    try db.execute(
        sql: "INSERT INTO recordings (partkey, device_id, source_folder, transmitter_id, mic_index, started_at, duration_seconds, ended_at, "
            + "source_path, source_size, source_mtime, sha256_helper, inbox_path, status, updated_at) "
            + "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        arguments: [row.partkey, row.deviceID, row.sourceFolder, row.transmitterID, row.micIndex, row.startedAt,
                    row.durationSeconds, row.endedAt, row.sourcePath, row.sourceSize, row.sourceMtime,
                    row.sha256Helper, row.inboxPath, PartStatus.discovered.rawValue, now])
    try Store.insertEvent(db, entity: .recording, key: row.partkey, from: nil, to: PartStatus.discovered.rawValue,
                          errorCode: nil, detail: nil, createdAt: now)
}
```

`insertSession`:

```swift
"INSERT INTO sessions (session_key, day_date, device_id, status, updated_at) VALUES (?, ?, ?, ?, ?)"
arguments: [row.sessionKey, row.dayDate, row.deviceID, SessionStatus.open.rawValue, now]
→ insertEvent(entity: .session, key: row.sessionKey, from: nil, to: SessionStatus.open.rawValue, …)
```

- 主キーが重複したら GRDB の `DatabaseError`（`resultCode == .SQLITE_CONSTRAINT`）がそのまま投げられる（events も書かれない）。呼び手が扱う
- 状態名は `PartStatus.discovered.rawValue` のように enum から取る（SQL の文字列に書かない。PT-06）

`updateRecordingIfStatus`（Updates の列の組み立てを使う。WHERE に `status` を含むので PT-05 によりこのファイルに置く）:

```swift
guard !fields.isEmpty else { return false }
let assignments = try RecordingField.assignments(fields)          // Updates.swift
let now = nowISO()
return try pool.write { db in
    try db.execute(sql: "UPDATE recordings SET \(assignments.sql), updated_at = ? WHERE partkey = ? AND status = ?",
                   arguments: StatementArguments(assignments.values + [now, partkey, status.rawValue]))
    return db.changesCount == 1
}
```

### 4.7 `Updates.swift`

```swift
// status 以外の列の更新（PLAN §5.2）。updated_at は常に now で上書きする。
import GRDB
import VDCore

public enum RecordingField: Sendable, Equatable {
    // `.swift-format` の OneCasePerLine により、実装では 1 行に 1 つの `case` で書く
    case sessionKey(String?), durationSeconds(Double?), endedAt(String?), sha256(String?), sha256Helper(String?),
         inboxPath(String?), stagingDir(String?), normalizedPath(String?), transcriptPath(String?),
         sourceSize(Int64?), sourceMtime(Double?), errorCode(ErrorCode?), errorMessage(String?),
         sourceDeletedAt(String?), deleteRequestID(String?), duplicateOf(String?), needsRecopy(Bool)
}

public enum SessionField: Sendable, Equatable {
    // 同上（1 行に 1 つの `case`）
    case startedAt(String?), endedAt(String?), recordedSeconds(Double?), partCount(Int), failedPartCount(Int),
         title(String?), analysisPath(String?), rawOutputPath(String?), rawOutputSHA256(String?),
         outputPath(String?), outputSHA256(String?), regeneratedCount(Int), deleteAttempts(Int),
         errorCode(ErrorCode?), errorMessage(String?), sourceDeletedAt(String?)
}

extension Store {
    public func updateRecording(_ partkey: String, _ fields: [RecordingField]) throws
    public func updateSession(_ key: String, _ fields: [SessionField]) throws
}

struct Assignments {  // 実装ではセミコロンを使わず 2 行に分ける（DoNotUseSemicolons）
    let sql: String
    let values: [(any DatabaseValueConvertible)?]
}
```

列の対応（`column` と束縛する値。これ以外の列は更新できない。**`status` を表す case は無い**）:

| RecordingField | 列 | 値 |
|---|---|---|
| `sessionKey` | `session_key` | そのまま |
| `durationSeconds` | `duration_seconds` | そのまま |
| `endedAt` | `ended_at` | そのまま |
| `sha256` | `sha256` | そのまま |
| `sha256Helper` | `sha256_helper` | そのまま |
| `inboxPath` | `inbox_path` | そのまま |
| `stagingDir` | `staging_dir` | そのまま |
| `normalizedPath` | `normalized_path` | そのまま |
| `transcriptPath` | `transcript_path` | そのまま |
| `sourceSize` | `source_size` | そのまま |
| `sourceMtime` | `source_mtime` | そのまま |
| `errorCode` | `error_code` | `rawValue`（nil は NULL） |
| `errorMessage` | `error_message` | `TextLimit.truncate200`（nil は NULL） |
| `sourceDeletedAt` | `source_deleted_at` | そのまま |
| `deleteRequestID` | `delete_request_id` | そのまま |
| `duplicateOf` | `duplicate_of` | そのまま |
| `needsRecopy` | `needs_recopy` | `true` → 1、`false` → 0 |

| SessionField | 列 | 値 |
|---|---|---|
| `startedAt` | `started_at` | そのまま |
| `endedAt` | `ended_at` | そのまま |
| `recordedSeconds` | `recorded_seconds` | そのまま |
| `partCount` | `part_count` | そのまま |
| `failedPartCount` | `failed_part_count` | そのまま |
| `title` | `title` | そのまま |
| `analysisPath` | `analysis_path` | そのまま |
| `rawOutputPath` | `raw_output_path` | そのまま |
| `rawOutputSHA256` | `raw_output_sha256` | そのまま |
| `outputPath` | `output_path` | そのまま |
| `outputSHA256` | `output_sha256` | そのまま |
| `regeneratedCount` | `regenerated_count` | そのまま |
| `deleteAttempts` | `delete_attempts` | そのまま |
| `errorCode` | `error_code` | `rawValue` |
| `errorMessage` | `error_message` | `TextLimit.truncate200` |
| `sourceDeletedAt` | `source_deleted_at` | そのまま |

`assignments(_ fields:)`（`RecordingField` と `SessionField` のそれぞれに static で持つ）:

1. 各 field を `(column, value)` にする（上の表）
2. 同じ列が 2 回現れたら `throw StoreError.invalidUpdate(<列名>)`（黙って後勝ちにしない）
3. `sql` = 渡された順に `"<column> = ?"` を `", "` でつないだもの、`values` = 同じ順の値

`updateRecording` / `updateSession` の手順:

1. `fields` が空なら**何もしない**（`updated_at` も変えない。voicedock db.py:594 と同じ）
2. `let a = try RecordingField.assignments(fields)`、`let now = nowISO()`
3. `try pool.write { db in try db.execute(sql: "UPDATE recordings SET \(a.sql), updated_at = ? WHERE partkey = ?", arguments: StatementArguments(a.values + [now, partkey])) }`
   （Session は `UPDATE sessions … WHERE session_key = ?`）
4. 該当行が無くても例外にしない（voicedock と同じ）

内部用（Queries の `refreshSessionAggregates` が同じトランザクションで使う）: `static func applySessionUpdate(_ db: Database, key: String, fields: [SessionField], now: String) throws`（手順 3 の SQL を与えられた `db` で実行する）。

### 4.8 `Queries.swift`

すべて `pool.read`（`refreshSessionAggregates` と `insertImportedKeys` だけ `pool.write`）。行は §4.5 の `init(row:)` で写す。SQL は逐語:

| メソッド | SQL | 備考 |
|---|---|---|
| `recording(_ partkey: String) -> RecordingRow?` | `SELECT * FROM recordings WHERE partkey = ?` | |
| `session(_ key: String) -> SessionRow?` | `SELECT * FROM sessions WHERE session_key = ?` | |
| `ungroupedRecordings() -> [RecordingRow]` | `SELECT * FROM recordings WHERE session_key IS NULL ORDER BY started_at, partkey` | |
| `recordings(inSession key: String) -> [RecordingRow]` | `SELECT * FROM recordings WHERE session_key = ? ORDER BY started_at, partkey` | |
| `recordings(status: PartStatus) -> [RecordingRow]` | `SELECT * FROM recordings WHERE status = ? ORDER BY started_at, partkey` | |
| `sessions(status: SessionStatus) -> [SessionRow]` | `SELECT * FROM sessions WHERE status = ? ORDER BY session_key` | |
| `nonTerminalPartkeys() -> [String]` | `SELECT partkey FROM recordings WHERE status NOT IN (?, ?, ?, ?, ?, ?) ORDER BY started_at, partkey` | 束縛は `PartStates.terminal` の rawValue を**昇順に並べたもの**。`?` の数は集合の要素数から作る |
| `failedRecordingKeys() -> [String]` | `SELECT partkey FROM recordings WHERE status = ? ORDER BY updated_at, partkey` | `PartStatus.failed.rawValue` |
| `failedSessionKeys() -> [String]` | `SELECT session_key FROM sessions WHERE status = ? ORDER BY updated_at, session_key` | `SessionStatus.failed.rawValue` |
| `failedFromPart(_ partkey: String) -> PartStatus?` | `SELECT from_status FROM events WHERE entity_type = ? AND entity_key = ? AND to_status = ? ORDER BY id DESC LIMIT 1` | `["recording", partkey, "FAILED" の rawValue]`。行が無い・NULL・未知 → nil |
| `failedFromSession(_ key: String) -> SessionStatus?` | 同上 | `["session", key, SessionStatus.failed.rawValue]` |
| `sessionsForDeleteEvaluation() -> [SessionRow]` | `SELECT * FROM sessions ORDER BY updated_at, session_key` | **状態で絞らない**（集合は呼び手の `SessionStates.deleteEvaluated`） |
| `recording(normalizedPath: String) -> RecordingRow?` | `SELECT * FROM recordings WHERE normalized_path = ? ORDER BY partkey LIMIT 1` | 決定性のため `ORDER BY partkey` を足した（voicedock は並びなし） |
| `recording(sha256: String) -> RecordingRow?` | `SELECT * FROM recordings WHERE sha256 = ?` | 部分 UNIQUE なので 0 か 1 行 |
| `recordingsAwaitingDeleteResult() -> [RecordingRow]` | `SELECT * FROM recordings WHERE delete_request_id IS NOT NULL ORDER BY started_at, partkey` | |
| `recordingsNeedingRecopy() -> [RecordingRow]` | `SELECT * FROM recordings WHERE needs_recopy = 1 ORDER BY started_at, partkey` | |
| `partkeys(statuses: Set<PartStatus>) -> [String]` | `SELECT partkey FROM recordings WHERE status IN (?, …) ORDER BY partkey` | 束縛は集合の rawValue を**昇順に並べたもの**。空集合なら問い合わせずに `[]`（inbox の取り残しの判定。T-18） |
| `events(entity: EntityType, key: String) -> [EventRow]` | `SELECT * FROM events WHERE entity_type = ? AND entity_key = ? ORDER BY id` | |
| `knownPartkeys(_ keys: [String]) -> Set<String>` | `SELECT partkey FROM recordings WHERE partkey IN (?, …)` | 500 件ずつに分けて問い合わせ、結果を合わせる。空なら問い合わせずに空集合 |
| `importedKeys() -> Set<String>` | `SELECT partkey FROM imported_keys` | |
| `insertImportedKeys(_ rows: [(partkey: String, sourceNote: String)]) -> Int` | 下記 | 追加した件数 |
| `refreshSessionAggregates(_ key: String)` | 下記 | |

`insertImportedKeys`: 1 つの `pool.write` の中で、各行について

```sql
INSERT OR IGNORE INTO imported_keys (partkey, source_note, imported_at)
SELECT ?, ?, ? WHERE NOT EXISTS (SELECT 1 FROM recordings WHERE partkey = ?)
```

（束縛 `[partkey, sourceNote, nowISO(), partkey]`）を実行し、`db.changesCount` の合計を返す。**アプリの DB に行がある partkey と、既に入っている partkey は入らない**（PLAN §8.13）。

`refreshSessionAggregates(_ key:)`（PLAN §5.6。voicedock session.py:244-270）: 1 つの `pool.write` の中で

```sql
SELECT COUNT(*) AS parts, MIN(started_at) AS first_at, MAX(ended_at) AS last_at,
       SUM(duration_seconds) AS seconds,
       COALESCE(SUM(CASE WHEN status IN (?, ?) THEN 1 ELSE 0 END), 0) AS excluded
FROM recordings WHERE session_key = ?
```

（束縛 `[PartStatus.failed.rawValue, PartStatus.skipped.rawValue, key]`）を読み、
`Store.applySessionUpdate(db, key: key, fields: [.partCount(parts), .startedAt(first_at), .endedAt(last_at), .recordedSeconds(seconds), .failedPartCount(excluded)], now: nowISO())`。
`seconds` は全部 NULL（か 0 行）なら NULL のまま。

- `IN (?, …)` の `?` は束縛する値の数から `Array(repeating: "?", count: n).joined(separator: ", ")` で作る（値を SQL に埋め込まない）

### 4.9 `ReadOnlyStore.swift`

```swift
// 診断と状態の詳細のための読み取り専用の経路。DB ファイルを作らない（CONC-06）。
import Foundation
import GRDB
import VDCore

public final class ReadOnlyStore: Sendable {
    let queue: DatabaseQueue
    public static func open(url: URL) -> ReadOnlyStore?
    public func statusCounts() throws -> (parts: [PartStatus: Int], sessions: [SessionStatus: Int])
    public func backlog() throws -> (count: Int, seconds: Double, unknownDuration: Int)
    public func failedParts(limit: Int) throws -> (rows: [RecordingRow], total: Int)
    public func quickCheck() throws -> String
    public func appliedMigrations() throws -> [String]
    public func awaitingDeleteResultCount() throws -> Int
    public func partkeys(statuses: Set<PartStatus>) throws -> [String]
}
```

- `open(url:)`:
  1. `FileManager.default.fileExists(atPath: url.path(percentEncoded: false))` が偽 → nil（**開こうとしない**。SQLite の既定の開き方はファイルを作るため）
  2. `var config = Configuration(); config.readonly = true; config.busyMode = .timeout(10); config.label = "VoiceDock.readonly"`
  3. `try? DatabaseQueue(path: url.path(percentEncoded: false), configuration: config)` が nil → nil
- `statusCounts`: `SELECT status, COUNT(*) AS n FROM recordings GROUP BY status` と `… FROM sessions GROUP BY status`。
  結果は `PartStatus.allCases` / `SessionStatus.allCases` の全値を 0 で埋めた辞書に上書きする。未知の status の行は数えない
- `backlog`: 非終端（`PartStatus.allCases` のうち `PartStates.terminal` に無いもの。宣言順）を束縛して
  `SELECT COUNT(*) AS parts, COALESCE(SUM(duration_seconds), 0) AS seconds, COALESCE(SUM(CASE WHEN duration_seconds IS NULL THEN 1 ELSE 0 END), 0) AS unknown_parts FROM recordings WHERE status IN (?, …)`
  → `(count: parts, seconds: seconds, unknownDuration: unknown_parts)`（FAILED は終端なので入らない。voicedock status.py:326-348）
- `failedParts(limit:)`: `SELECT COUNT(*) FROM recordings WHERE status = ?` と `SELECT * FROM recordings WHERE status = ? ORDER BY started_at, partkey LIMIT ?`（FAILED の rawValue、limit）
- `quickCheck`: `PRAGMA quick_check` の 1 行目
- `appliedMigrations`: `Schema.migrator().appliedMigrations(db)`（`grdb_migrations` が無ければ空配列）
- `awaitingDeleteResultCount`: `SELECT COUNT(*) FROM recordings WHERE delete_request_id IS NOT NULL`（状態の詳細の「結果待ちの Part の数」。T-32）
- `partkeys(statuses:)`: `Store.partkeys(statuses:)` と同じ SQL・束縛・並び（DR-15。T-32）
- すべて例外を投げうる。呼び手（状態の詳細・診断）は例外を「全 0」「読めない」として扱う（voicedock status.py の `sqlite3.Error` と同じ扱い。呼び手のチケットで実装）

### 4.10 `Tests/TestSupport/Builders.swift`（00-api-map §14・§15 の `Builders`。作り手はこのチケット）

```swift
// テスト用の DB の行の組み立て（T-11 以降の Store を使うテストが共有する。00-api-map §15 の Builders）。
import Foundation
import VDContract  // PartKey・RelPath
import VDCore
import VDStore

public enum Builders {
    /// 既定値: deviceID "DJIMIC3"、folder "TX_MIC001_20260829_071201"、transmitter "TX01"、mic 2、
    /// startedAt "2026-08-29T07:12:04+09:00"、duration 1800.0、endedAt "2026-08-29T07:42:04+09:00"、
    /// sourceSize 345_600_000、sourceMtime 1_787_000_000.0（inbox のコピーより 4 時間 34 分前の原本の時刻。DEL-12）、
    /// sha256Helper は "a" × 64、inboxPath "inbox/DJIMIC3/<relpath>"
    public static func recording(relpath: String = "TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav",
                                 startedAt: String = "2026-08-29T07:12:04+09:00",
                                 durationSeconds: Double? = 1800.0) throws -> NewRecording
    public static func session(key: String = "DJIMIC3:20260829", dayDate: String = "2026-08-29") -> NewSession
    /// 一時ディレクトリに Store を開く（FixedClock 2026-08-30T07:00:12+09:00、Asia/Tokyo）
    public static func openStore(in dir: URL, clock: any AppClock) throws -> Store
}
```

- `recording(relpath:…)`: partkey = `try PartKey.make(deviceID: "DJIMIC3", relpath: relpath)`、`sourceFolder = RelPath.parent(relpath)`、`sourcePath = relpath`、
  `endedAt` は `durationSeconds` が nil なら nil、そうでなければ `startedAt` の文字列を `ZonedTime` で読んで秒を足し ISO に戻したもの（既定値のときは `"2026-08-29T07:42:04+09:00"`）
- `openStore(in:clock:)`: `try Store(url: dir.appendingPathComponent("voicedock.sqlite"), clock: clock, zone: ZonedTime(timeZone: <Asia/Tokyo>))`。Asia/Tokyo の `TimeZone` は `TimeZone(identifier:)` の nil を `throw` に変えて取り出す（`!` を使わない）

## 5. テスト

共通: `.serialized` は不要（テストごとに `TempDirectory()` を作る）。時計は `FixedClock`（`Instant(epochMillis: 1_788_040_812_000)` = `2026-08-30T07:00:12+09:00`）、ゾーンは Asia/Tokyo（`try #require(TimeZone(identifier: "Asia/Tokyo"))`）。Store は `Builders.openStore(in:clock:)` で開く。

### 5.1 `StoreOpenTests.swift` — `@Suite("Store の開設")`

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `newDatabaseUsesWAL` | 新しい DB は WAL で開く | 一時ディレクトリに `Store(url:)` | writer で `PRAGMA journal_mode` = `wal` |
| `writerSynchronousIsFull` | writer の synchronous は FULL（GRDB の NORMAL を上書きする） | 同上 | writer で `PRAGMA synchronous` = 2 |
| `foreignKeysAndBusyTimeout` | foreign_keys ON・busy_timeout 10000 | 同上 | reader と writer の両方で `PRAGMA foreign_keys` = 1、`PRAGMA busy_timeout` = 10000 |
| `appliesV1InitialOnce` | v1_initial を 1 回だけ当てる | 開いて閉じ、もう一度開く | `appliedMigrations == ["v1_initial"]`。ディレクトリに `.backup-` を含むファイルが無い |
| `noSchemaVersionTable` | schema_version 表を作らない | 同上 | `sqlite_master` に `schema_version` が無く、`grdb_migrations` が在る |
| `refusesSupersededDatabase` | 新しいアプリが当てた版があれば開かない | 開いた後に `INSERT INTO grdb_migrations (identifier) VALUES ('v99_future')` を直接実行し、開き直す | `StoreError.migration("superseded")` |
| `quickCheckIsOK` | quick_check が ok | 新しい DB | `"ok"` |

### 5.2 `SchemaTests.swift` — `@Suite("スキーマ")`

スキーマの PRAGMA（`table_info` / `index_list` / `index_info` / `foreign_key_list`）は **writer（`pool.writeWithoutTransaction`）で読む**。reader の接続は `Store.init` の手順 4（移行の前）で開かれるため、スキーマの PRAGMA が移行前の古いスキーマを返すことがある（実装時に `pool.read` の `index_list` と `foreign_key_list` が 0 行を返すのを確認。reader で PRAGMA 全般が使えないという意味ではない）。

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `columnCountsAreFixed` | 列数は recordings 27・sessions 22・events 8・imported_keys 3 | `PRAGMA table_info(<table>)` の行数 |
| `recordingsColumnsMatchPlan` | recordings の列は PLAN §7.2 と同じ（名前・型・NOT NULL・既定値・順） | テストに PLAN §7.2 から写した 27 行の期待表 `(name, type, notnull, dflt_value, pk)` を置き、`PRAGMA table_info(recordings)` と完全一致 |
| `sessionsColumnsMatchPlan` | sessions の列は PLAN §7.2 と同じ | 同上 22 行 |
| `eventsAndImportedKeysColumnsMatchPlan` | events と imported_keys の列は PLAN §7.2 と同じ | 同上 |
| `indexesMatchPlan` | 索引は PLAN §7.2 と同じ | `PRAGMA index_list(<table>)` と `PRAGMA index_info(<index>)`: `idx_sessions_status(status)`、`idx_sessions_day(day_date)`、`idx_recordings_sha(sha256)` は unique=1 partial=1、`idx_recordings_status`、`idx_recordings_session`、`idx_recordings_started`、`idx_events_entity(entity_type, entity_key, id)` |
| `recordingsForeignKeyToSessions` | recordings.session_key は sessions への外部キー（ON DELETE SET NULL） | `PRAGMA foreign_key_list(recordings)` が 1 行、table=sessions、from=session_key、on_delete=SET NULL |
| `partialUniqueIndexOnSHA256` | sha256 は NULL 以外で一意 | 2 行を作り、両方に `updateRecording(.sha256("x"))` → 2 回目が `DatabaseError`（SQLITE_CONSTRAINT）。両方 NULL は可 |

### 5.3 `TransitionsTests.swift` — `@Suite("状態遷移")`

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `insertRecordingWritesBirthEvent` | 行の作成も events に書く | `insertRecording` | 行の status = DISCOVERED、retry_count 0、updated_at = 時計の ISO。events が 1 行: entity_type `recording`、from_status NULL、to_status `DISCOVERED`、error_code NULL、detail NULL、created_at = 同じ ISO |
| `insertSessionWritesBirthEvent` | Session の作成も events に書く | `insertSession` | status OPEN、events 1 行（from NULL → OPEN） |
| `insertDuplicatePartkeyFails` | 同じ partkey の 2 回目は失敗し events を増やさない | 2 回 `insertRecording` | 2 回目が `DatabaseError`、events は 1 行のまま |
| `recordsTransitionAndEvent` | 遷移は行と events を同じトランザクションで書く | DISCOVERED → NORMALIZING（detail "x"） | 行の status、events 2 行目: from `DISCOVERED`、to `NORMALIZING`、detail `x` |
| `conflictWhenFromDoesNotMatch` | 現在の状態が from と違えば TransitionConflict で何も変えない | DISCOVERED の行に from: .normalized で NORMALIZED → TRANSCRIBING | `TransitionConflict(key:, expected: "NORMALIZED")`、行も events も変わらない |
| `conflictWhenRowMissing` | 行が無ければ TransitionConflict | 空の DB | `TransitionConflict` |
| `illegalNormalEdgeIsRejected` | 遷移表に無い辺は IllegalTransition で DB に触らない | DISCOVERED → COMPLETED（normal） | `IllegalTransition(from: "DISCOVERED", to: "COMPLETED", kind: .normal)`、events 1 行のまま |
| `recoveryEdgeNeedsRecoveryKind` | 復旧の辺は recovery でだけ通る | NORMALIZING の行に NORMALIZING → DISCOVERED を normal で | `IllegalTransition(…, kind: .normal)` |
| `recoveryEdgeWritesRecoveryDetail` | recovery の detail は引数によらず recovery | 同じ辺を `.recovery`、detail "ignored" | 成功。events の detail が `recovery` |
| `recoveryKindRejectsNonRecoveryEdge` | recovery は写像の組だけを許す | DISCOVERED → NORMALIZING を `.recovery` | `IllegalTransition(…, kind: .recovery)` |
| `sharedEdgeAllowedByBothKinds` | SOURCE_DELETING→SOURCE_DELETE_PENDING は両方で通る | 2 行で normal と recovery | どちらも成功 |
| `sessionIllegalEdgeIsRejected` | Session も遷移表で検査する | OPEN → ANALYZED | `IllegalTransition` |
| `openToOpenIsATransition` | OPEN→OPEN は遷移として events に書く | OPEN → OPEN（detail partkey） | events 2 行目: from OPEN、to OPEN、detail = partkey |
| `retryCountRules`（引数付き） | retry_count の規則（SM-03 / SM-04） | 下の表の各行: retry_count を初期値にしてから遷移 | 期待値 |
| `errorFieldsAreOverwrittenUnconditionally` | error_code と error_message は無条件に上書き | FAILED（WHISPER_FAILED、"m"）→ TRANSCRIBING（引数なし） | error_code・error_message が NULL |
| `errorMessageTruncatedByScalars`（引数付き） | 200 スカラーで切り詰める（書記素ではない） | 下の表 | 保存された error_message と events.detail |
| `timestampsComeFromClockEachCall` | 時刻は呼ぶたびに時計から取る | `SteppingClock`（1 回ごとに +1 秒）で 2 回遷移 | 2 つの updated_at が 1 秒違う |
| `updateRecordingIfStatusOnlyWhenMatching` | status が一致するときだけ列を更新する | DISCOVERED の行に `status: .normalized` で `[.needsRecopy(true)]` → false、`status: .discovered` で → true | 1 回目は変わらず、2 回目で needs_recopy = 1 |

`retryCountRules` の表（初期 retry_count → 遷移 → 期待）:

| 初期 | 遷移 | resetRetry | 期待 |
|---|---|---|---|
| 2 | NORMALIZING → NORMALIZED | false | 0 |
| 2 | TRANSCRIBING → TRANSCRIBED | false | 0 |
| 2 | RAW_WRITING → RAW_SAVED | false | 0 |
| 1 | NORMALIZING → FAILED | false | 2 |
| 2 | FAILED → NORMALIZING | false | 2 |
| 3 | FAILED → NORMALIZING | true | 0 |
| 1 | DISCOVERED → NORMALIZING | false | 1 |
| 2 | MERGING → MERGED（Session） | false | 0 |
| 2 | ANALYZING → ANALYZED（Session） | false | 0 |
| 2 | WRITING → SAVED（Session） | false | 0 |
| 0 | ANALYZING → FAILED（Session） | false | 1 |

（初期値は `pool.write` で直接 `UPDATE … SET retry_count = ?` するのではなく、FAILED への遷移を必要な回数だけ繰り返して作る。テストが `status` を書く SQL を持たないため。PT-05 は `Tests/` を見ないが、手組みの UPDATE を避ける）

`errorMessageTruncatedByScalars` の表:

| 入力 | 期待 |
|---|---|
| `"a"` × 200 | そのまま（200 スカラー） |
| `"a"` × 201 | `"a"` × 199 + `"…"`（200 スカラー） |
| `"e\u{301}"` × 101（202 スカラー・101 書記素） | 先頭 199 スカラー + `"…"`（書記素で数えると切られないので、ここで食い違いを検出する） |
| `""` | `""` |

### 5.4 `UpdatesTests.swift` — `@Suite("列の更新")`

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `updateRecordingSetsColumnsAndUpdatedAt` | 列を書き updated_at を進める | `SteppingClock`。`[.sha256("s"), .transcriptPath("t")]` → 列が変わり、updated_at が作成時より後、status と events は変わらない |
| `emptyUpdateTouchesNothing` | 空の更新は updated_at も変えない | `[]` → updated_at が作成時のまま |
| `allRecordingFieldsMapToNonStatusColumns` | どの RecordingField も status 以外の列を書く | 全 17 case の見本を 1 つずつ適用し、各列の値を `SELECT` で確かめる。status は DISCOVERED のまま |
| `allSessionFieldsMapToNonStatusColumns` | どの SessionField も status 以外の列を書く | 全 16 case で同様 |
| `duplicateColumnIsRejected` | 同じ列を 2 回渡すと invalidUpdate | `[.sha256("a"), .sha256("b")]` → `StoreError.invalidUpdate("sha256")`、何も書かれない |
| `errorMessageIsTruncatedOnUpdate` | 列更新でも error_message を切り詰める | 201 スカラー → 200 スカラー |
| `needsRecopyIsInteger` | needs_recopy は 0 / 1 で保存する | `.needsRecopy(true)` → 1、`false` → 0 |
| `missingRowIsIgnored` | 行が無くても例外にしない | 存在しない partkey への更新が投げない |

### 5.5 `QueriesTests.swift` — `@Suite("問い合わせ")`

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `ungroupedOrderedByStartedAtThenPartkey` | 未分組は started_at, partkey 順 | started_at と partkey をわざと逆順に 3 行（同じ started_at が 2 行） | 期待の順 |
| `sessionPartsOrdered` | Session の Part は started_at, partkey 順 | 同上で session_key を付ける | 期待の順 |
| `recordingsByStatusOrdered` | 状態別も同じ順 | | |
| `sessionsByStatusOrderedByKey` | Session の状態別は session_key 順 | `DJIMIC3:20260830`、`DJIMIC3:20260829#2`、`DJIMIC3:20260829` | 文字列の昇順 |
| `nonTerminalExcludesSixTerminalStates` | 非終端は終端 6 状態を除く | 12 状態のそれぞれに 1 行（遷移を辿って作る） | DISCOVERED・NORMALIZING・NORMALIZED・TRANSCRIBING・TRANSCRIBED・RAW_WRITING の 6 件だけ |
| `failedKeysOrderedByUpdatedAt` | FAILED の一覧は updated_at, key 順 | `SteppingClock` で 3 件を順に FAILED | 失敗させた順 |
| `failedFromIsLatestFailedEvent` | 戻り先は直近の FAILED の from | NORMALIZING→FAILED、FAILED→NORMALIZING、…→TRANSCRIBING→FAILED | `failedFromPart == .transcribing` |
| `failedFromNilWithoutFailure` | FAILED が無ければ nil | | nil |
| `deleteEvaluationOrderedByUpdatedAt` | 削除評価の Session は全件を updated_at, session_key 順 | 状態の違う 3 Session | 全件・順 |
| `normalizedPathLookup` | normalized_path で引く | | 行が返る。無ければ nil |
| `sha256Lookup` | sha256 で引く | | 行が返る。無ければ nil |
| `awaitingDeleteResult` | delete_request_id を持つ Part だけ | 2 行のうち 1 行に ID | 1 行 |
| `needingRecopy` | needs_recopy = 1 の Part だけ | | |
| `partkeysByStatuses` | 状態の集合で partkey を引く（partkey 順） | DISCOVERED 2 行・NORMALIZED 1 行・FAILED 1 行 | `[.discovered, .failed]` → 3 件を partkey の昇順、`[]` → `[]` |
| `eventsInIdOrder` | events は id 順 | | |
| `unknownErrorCodeKeepsRawString` | 未知の error_code は errorCode nil・errorCodeRaw に文字列のまま残る | 1 行を作り、生の SQL `UPDATE recordings SET error_code = 'FUTURE_CODE_X' WHERE partkey = ?` を実行してから読み直す | 行は読める（`corruptRow` を投げない）。`row.errorCode == nil`、`row.errorCodeRaw == "FUTURE_CODE_X"`。既知のコード（`WHISPER_FAILED`）では `errorCode == .whisperFailed` かつ `errorCodeRaw == "WHISPER_FAILED"`、NULL では両方 nil |
| `knownPartkeysChunks` | 500 件を超える問い合わせも正しい | 1200 行を作り、1200 + 存在しない 3 件を渡す | 1200 件の集合 |
| `knownPartkeysEmpty` | 空の入力は空 | `[]` | 空集合 |
| `importedKeysSkipKnownAndDuplicates` | 取り込み済みの鍵は DB の行と重複を除いて入れる | recordings に A、imported に B を先に入れ、`[A, B, C]` を渡す | 戻り値 1、imported は {B, C} |
| `refreshAggregates` | 集計列を数え直す | 3 Part（duration 100・NULL・50、1 件 SKIPPED） | part_count 3、started_at = 最小、ended_at = 最大、recorded_seconds 150、failed_part_count 1、updated_at が進む |
| `refreshAggregatesAllNullDuration` | duration が全部 NULL なら recorded_seconds は NULL | | NULL |
| `refreshAggregatesNoParts` | Part が 0 件なら 0・NULL | | part_count 0、recorded_seconds NULL、failed_part_count 0 |

### 5.6 `BackupTests.swift` — `@Suite("移行前のバックアップ")`

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `noBackupOnFirstCreation` | 初回作成ではバックアップしない | 新しい DB | `.backup-` を含むファイルが無い |
| `noBackupWhenUpToDate` | 未適用が無ければバックアップしない | 開き直す | 同上 |
| `backupBeforePendingMigration` | 既存 DB に未適用があるとき当てる前にバックアップする | v1 で開き 1 行入れて閉じる → `init(url:clock:zone:migrator:)` に `v1_initial` と `v2_test`（`CREATE TABLE t (x)`）を登録した移行器で開き直す | `voicedock.sqlite.backup-v1_initial-20260830T070012+0900` が在り、それを `DatabaseQueue` で開くと `grdb_migrations` が `v1_initial` だけ・入れた 1 行が在り・表 `t` が無い |
| `backupIncludesUncheckpointedWAL` | バックアップは WAL の未反映分も含む（ファイルコピーではない） | 1 つ目の Store を開いたまま 1 行入れ（チェックポイントしない）、2 つ目を v2 の移行器で開く | バックアップにその行が在る |

### 5.7 `ReadOnlyStoreTests.swift` — `@Suite("読み取り専用")`

| 関数名 | 表示名 | 期待 |
|---|---|---|
| `missingDatabaseReturnsNilAndCreatesNothing` | DB が無ければ nil で、ファイルを何も作らない | 空の一時ディレクトリで `open` → nil、ディレクトリは空のまま |
| `cannotWrite` | 読み取り専用で書けない | 既存の DB を開き、内部の `queue.write { … INSERT … }` が `DatabaseError`（SQLITE_READONLY） |
| `statusCountsAreZeroFilled` | 状態別件数は全状態を 0 で埋める | 2 状態に 1 件ずつ → 辞書のキーが 12 / 13 個、該当だけ 1 |
| `backlogCountsNullDurations` | 未処理は非終端の件数・長さの合計・長さ不明の件数 | 非終端 3 件（100、NULL、50）＋ FAILED 1 件 → (3, 150.0, 1) |
| `failedPartsLimitAndTotal` | FAILED の一覧は started_at 順・上限・総数 | FAILED 25 件、limit 20 → 20 行・total 25・先頭が最も早い started_at |
| `appliedMigrationsReadOnly` | 適用済みの移行を読める | `["v1_initial"]`。Store を閉じた後の DB（`-wal` / `-shm` が無い）を開いても同じ |
| `awaitingDeleteResultCountAndPartkeys` | 結果待ちの数と状態別の partkey を読める | DISCOVERED の 3 行（relpath の違う 3 つ）のうち 2 行に `updateRecording(_, [.deleteRequestID("r")])` → `awaitingDeleteResultCount() == 2`、`partkeys(statuses: [.discovered])` は 3 件を partkey の昇順、`partkeys(statuses: [.failed])` は `[]` |

## 6. 破壊による証明

| # | 壊し方（1 か所だけ） | 落ちるべきテスト |
|---|---|---|
| 1 | `Transitions.swift` の `TransitionTable.allows` の検査を消す | `illegalNormalEdgeIsRejected`、`recoveryEdgeNeedsRecoveryKind`、`recoveryKindRejectsNonRecoveryEdge`、`sessionIllegalEdgeIsRejected` |
| 2 | `db.changesCount == 1` を `>= 0` にする | `conflictWhenFromDoesNotMatch`、`conflictWhenRowMissing` |
| 3 | `insertRecording` の `insertEvent` を消す | `insertRecordingWritesBirthEvent` |
| 4 | `RetryExpression` の判定で `PartStates.retryReset` を見ない | `retryCountRules` |
| 5 | `TextLimit.truncate200` の代わりに `String(prefix(199)) + "…"`（書記素）にする | `errorMessageTruncatedByScalars` の結合文字の行 |
| 6 | `Store.init` の `PRAGMA synchronous = FULL` の再実行を消す | `writerSynchronousIsFull` |
| 7 | バックアップの条件から `!applied.isEmpty` を消す | `noBackupOnFirstCreation` |
| 8 | `ungroupedRecordings` の `, partkey` を消す | `ungroupedOrderedByStartedAtThenPartkey` |
| 9 | `ReadOnlyStore.open` の存在確認と `config.readonly = true` を両方消す（`readonly` の開き方は存在しないファイルを作らないので、存在確認だけを消しても落ちない。存在確認は多重の防御） | `missingDatabaseReturnsNilAndCreatesNothing` |
| 10 | `updateRecording` の `updated_at = ?` を消す | `updateRecordingSetsColumnsAndUpdatedAt` |
| 11 | `insertImportedKeys` の `WHERE NOT EXISTS` を消す | `importedKeysSkipKnownAndDuplicates` |
| 12 | `assignments` の重複検査を消す | `duplicateColumnIsRejected` |
| 13 | `partkeys(statuses:)` の `ORDER BY partkey` を消す（空集合の早期 return を消しても落ちない。SQLite は `IN ()` を構文の誤りにせず 0 行を返すため、早期 return は問い合わせを省くだけ） | `partkeysByStatuses`、`awaitingDeleteResultCountAndPartkeys` |
| 14 | `RecordingRow.init(row:)` で `errorCodeRaw` に `errorCode?.rawValue` を入れる（生の文字列を捨てる） | `unknownErrorCodeKeepsRawString` |
| 15 | `ReadOnlyStore.open` の `config.readonly = true` を消す | `cannotWrite` |

## 7. 受け入れ条件

- [ ] §3 のファイルがすべて在り、`swift build` と `make test` が通る
- [ ] `Sources/VDStore/` に `PersistableRecord` / `MutablePersistableRecord` が無い（PT-05）
- [ ] `UPDATE … SET … status` と `INSERT INTO recordings / sessions` の文字列が `Transitions.swift` にしか無い（PT-05）
- [ ] SQL の文字列に状態名・エラーコード名が無い（すべて束縛。PT-06）
- [ ] `row["…"] as T`（非 Optional の添字）を使っていない（`row.decode` だけ）
- [ ] 破壊による証明の 15 項目で、表のテストが落ちることを確かめ、PR 本文に貼った

## 8. SPEC の変更

なし（`docs/SPEC.md` の表に DB の列は載せない。列は SchemaTests が PLAN §7.2 と照合する）。

## 9. マージ後にやること

なし。

## 10. API 地図への変更提案

1. `StoreError` に `corruptRow(String)` と `invalidUpdate(String)` を足す（行を写せない場合・列の重複を、落とさずに投げるため）。`migration("superseded")` を新しい版の DB の検出に使う → 00-api-map に反映済み（2026-09-18）
2. `updateRecordingIfStatus` の置き場所を `Updates.swift` から `Transitions.swift` へ（WHERE に `status` を含む UPDATE の文字列は PT-05 により `Transitions.swift` にしか置けない） → 00-api-map に反映済み（2026-09-18）
3. `Store` にテスト用の internal な `init(url:clock:zone:migrator:)` を足す（バックアップの条件を試すため） → 00-api-map に反映済み（2026-09-18）
4. `RecordingField` / `SessionField` に `Equatable` を足す（テストで比較する） → 00-api-map に反映済み（2026-09-18）
5. `NewRecording` の `sourcePath` / `sourceSize` / `sourceMtime` / `sha256Helper` / `inboxPath` は非 Optional（登録時には必ず分かっている） → 00-api-map に反映済み（2026-09-18）
6. （後続のチケット向けの提案）`Store.partkeys(statuses: Set<PartStatus>) throws -> Set<String>`（inbox の取り残しの判定に使う）と、`ReadOnlyStore.awaitingDeleteResultCount() throws -> Int`・`ReadOnlyStore.partkeys(statuses:)`（状態の詳細の「結果待ちの Part の数」と DR-15）。必要になったチケット（T-18 / T-32）が足す → 地図 §3 に**本チケットの API** として載った（`Store.partkeys(statuses:)` の戻り値は `[String]`）。地図の形で §4.8・§4.9 に足した（整合修正）
7. （整合修正で追記）TestSupport の行の組み立ては地図 §14・§15 の名前 `Builders` にした（旧名 `StoreFixtures`）
8. （整合修正 M-1）`RecordingRow.errorCodeRaw: String?` を足した。**列は 27 のまま**（`error_code` の 1 列から `errorCode` と `errorCodeRaw` の 2 つを作る導出プロパティ）。未知のコードを表示に残すために T-27 の `ExcludedPart.unknownCode` と T-29 が使う → 00-api-map §3 に反映済み
9. （実装で追記）チケット §4 は `NewSession` に `Equatable`、`EntityType` に `CaseIterable` を付けている（地図 §3 はそれぞれ `Sendable` だけ・`String, Sendable` だけ）。公開する名前は増えないが、地図に適合を書き足すかは利用者の判断
