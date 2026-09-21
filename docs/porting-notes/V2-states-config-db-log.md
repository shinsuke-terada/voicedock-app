# V2 移植メモ: 状態・遷移・エラーコード・設定・DB・ログ（voicedock@d3d595e）

出典はすべて `git -C /Users/terada/Projects/voicedock show d3d595e:<path>`。行番号は d3d595e のもの。
Swift 実装者が Python を読まずに再現できる粒度で書く。**「本計画で変える」点は ★ で示す。**

---

## 1. 状態（src/voicedock/states.py）

### 1.1 列挙（宣言順 = SPEC §9.1 / §9.2 の表の順。status 表示順とは別。states.py:25-57）

- Part: `DISCOVERED, NORMALIZING, NORMALIZED, TRANSCRIBING, TRANSCRIBED, RAW_WRITING, RAW_SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING, COMPLETED, FAILED, SKIPPED`（12）
- Session: `OPEN, READY, MERGING, MERGED, ANALYZING, ANALYZED, WRITING, SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING, CLEANUP, COMPLETED, FAILED`（13）
- 初期状態: Part `DISCOVERED`（行 INSERT で入る）、Session `OPEN`（states.py:62-66）
- rawValue は名前と同じ大文字綴り。Part と Session で同名の値（SOURCE_DELETING, SOURCE_DELETE_PENDING, COMPLETED, FAILED）がある → **entity ごとに型を分ける**（states.py:217-227）

### 1.2 集合（states.py:71-149, 254-384 / errors.py:177 / daily.py:50 / status.py:413 / pipeline.py:71-231）

| 名前（voicedock） | 中身 | 用途 | 出典 |
|---|---|---|---|
| PART_TERMINAL | RAW_SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING, COMPLETED, FAILED, SKIPPED | Session を進めてよいか（READY→MERGING のガード） | states.py:71 |
| PART_DELETABLE | TERMINAL − {FAILED, SKIPPED} = RAW_SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING, COMPLETED | 根拠 A | states.py:89 |
| STAGING_DISPOSABLE | TERMINAL − {FAILED}（5 件） | staging を捨ててよい | states.py:104 |
| AWAITING_DELETION | DELETABLE − {COMPLETED}（3 件） | 空なら SOURCE_DELETE_PENDING セッションを畳む | states.py:120 |
| CLEANUP_FROM（Session） | SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING | CLEANUP へ進める遷移元 | states.py:132 |
| SESSION_TERMINAL | COMPLETED, FAILED | （SPEC に規定なし。voicedock でも実質未使用） | states.py:141 |
| PART_RETRYABLE_FROM_FAILED | NORMALIZING, TRANSCRIBING, RAW_WRITING | FAILED からの戻り先として許す状態 | states.py:254 |
| SESSION_RETRYABLE_FROM_FAILED | MERGING, ANALYZING, WRITING | 同上 | states.py:263 |
| PART_RECOVERY（写像） | NORMALIZING→DISCOVERED, TRANSCRIBING→NORMALIZED, RAW_WRITING→TRANSCRIBED, SOURCE_DELETING→SOURCE_DELETE_PENDING | 起動時の巻き戻し | states.py:271 |
| SESSION_RECOVERY（写像） | MERGING→READY, ANALYZING→MERGED, WRITING→ANALYZED, SOURCE_DELETING→SOURCE_DELETE_PENDING, CLEANUP→SAVED | 同上 | states.py:282 |
| PART_IN_PROGRESS | NORMALIZING, TRANSCRIBING, RAW_WRITING, SOURCE_DELETING | = PART_RECOVERY の定義域 | states.py:295 |
| SESSION_IN_PROGRESS | MERGING, ANALYZING, WRITING, SOURCE_DELETING, CLEANUP | = SESSION_RECOVERY の定義域 | states.py:305 |
| WAITING | {"SOURCE_DELETE_PENDING"} | ING で終わるが進行中でない | states.py:316 |
| PART_RETRY_RESET | NORMALIZED, TRANSCRIBED, RAW_SAVED | retry_count を 0 に戻す遷移先 | states.py:337 |
| SESSION_RETRY_RESET | MERGED, ANALYZED, SAVED | 同上 | states.py:342 |
| RAW_NOTE_MEMBERS | TRANSCRIBED, RAW_WRITING, RAW_SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING, COMPLETED | Raw ノートに載る Part（書き手と検証が共有） | states.py:363 |
| DELETABLE_SKIP_REASONS | DUPLICATE_CONTENT, NO_SPEECH_DETECTED | 根拠 B | errors.py:177 |
| BENIGN_SKIP_REASONS | NO_SPEECH_DETECTED, DUPLICATE_CONTENT | Daily の ⚠ を付けない理由（**DELETABLE_SKIP_REASONS と別定数**。同値でも片方の変更に追随させない） | daily.py:50 |
| ORPHANED_STATES | TERMINAL − {FAILED}（= STAGING_DISPOSABLE と同値だが別の問い） | inbox 取り残し判定（DR-15 相当） | status.py:413 |
| NORMALIZABLE | DISCOVERED, NORMALIZING | ensureNormalized の入口 | pipeline.py:118 |
| TRANSCRIBABLE | NORMALIZED, TRANSCRIBING | ensureTranscribed の入口 | pipeline.py:129 |
| RAW_WRITABLE | TRANSCRIBED, RAW_WRITING | ensureRawNote の入口 | pipeline.py:134 |
| MERGEABLE | READY, MERGING | | pipeline.py:139 |
| ANALYZABLE | MERGED, ANALYZING | | pipeline.py:147 |
| WRITABLE | ANALYZED, WRITING | | pipeline.py:155 |
| PROCESSABLE | MERGEABLE ∪ ANALYZABLE ∪ WRITABLE | processReadySessions の走査対象 | pipeline.py:160 |
| REOPENABLE | SAVED, COMPLETED | 再オープン元 | pipeline.py:170 |
| DELETE_EVALUATED（Session） | SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING, CLEANUP（COMPLETED を含めない） | 削除評価の対象セッション | pipeline.py:104 |
| NORMALIZED_OR_BEYOND 等 | 工程を飛ばしてよい状態（pipeline.py:71-102, 203-231） | ensure* の冪等 | |

不変条件テスト（tests/unit/test_states.py の名前）: DELETABLE ⊂ TERMINAL（真部分集合、差 = {FAILED, SKIPPED}）、IN_PROGRESS = RECOVERY の定義域、RETRYABLE_FROM_FAILED = 「FAILED へ入る辺の遷移元」の集合（`test_failed_recovery_is_symmetric`）、ING で終わる状態は IN_PROGRESS か WAITING、IN_PROGRESS ∩ TERMINAL = ∅、RECOVERY の行き先は遷移表で到達可能、RETRY_RESET は工程通過状態、到達不能な状態が無い。

### 1.3 遷移表（states.py:154-215）— 仕様付録 A.2 と一回限りのスクリプトで照合済み

```
Part  voicedock=23 spec=23   spec-only: []   vd-only: []
Session voicedock=24 spec=25 spec-only: [('ANALYZED','ANALYZING')]  vd-only: []
```
（★ANALYZED→ANALYZING は本計画の追加辺。それ以外は完全一致）

Part（23 辺）:
```
DISCOVERED→NORMALIZING, DISCOVERED→SKIPPED
NORMALIZING→NORMALIZED, NORMALIZING→SKIPPED, NORMALIZING→FAILED
NORMALIZED→TRANSCRIBING, NORMALIZED→NORMALIZING
TRANSCRIBING→NORMALIZING, TRANSCRIBING→TRANSCRIBED, TRANSCRIBING→SKIPPED, TRANSCRIBING→FAILED
TRANSCRIBED→RAW_WRITING
RAW_WRITING→RAW_SAVED, RAW_WRITING→FAILED
RAW_SAVED→SOURCE_DELETING, RAW_SAVED→COMPLETED
SOURCE_DELETING→COMPLETED, SOURCE_DELETING→SOURCE_DELETE_PENDING
SOURCE_DELETE_PENDING→SOURCE_DELETING
COMPLETED→SOURCE_DELETING
FAILED→NORMALIZING, FAILED→TRANSCRIBING, FAILED→RAW_WRITING
```
Session（24 辺 + ★1）:
```
OPEN→OPEN, OPEN→READY, READY→MERGING
MERGING→MERGED, MERGING→COMPLETED, MERGING→FAILED
MERGED→ANALYZING, ANALYZING→ANALYZED, ANALYZING→FAILED
ANALYZED→WRITING, WRITING→SAVED, WRITING→FAILED
SAVED→SOURCE_DELETING, SAVED→CLEANUP, SAVED→MERGING, COMPLETED→MERGING
SOURCE_DELETING→CLEANUP, SOURCE_DELETING→SOURCE_DELETE_PENDING
SOURCE_DELETE_PENDING→SOURCE_DELETING, SOURCE_DELETE_PENDING→CLEANUP
CLEANUP→COMPLETED
FAILED→MERGING, FAILED→ANALYZING, FAILED→WRITING
★ANALYZED→ANALYZING
```
- 自己遷移は OPEN→OPEN だけ（states.py:187, 236-238）。
- `can_transition` は entity の型で表を引き、型が混ざれば TypeError（states.py:230-243）。

### 1.4 復旧の記録方法（重要）

- 復旧は **`record_transition()` をそのまま使い**、`detail="recovery"` で events に 1 行ずつ書く（pipeline.py:1669-1703）。
- **voicedock の `record_transition()` は遷移表を検査しない**（db.py:328「どの遷移が許されるかはここで検査しない」）。だから表に無い復旧の辺（NORMALIZING→DISCOVERED 等 7 本）も通っていた。
- 表に在る復旧の辺は SOURCE_DELETING→SOURCE_DELETE_PENDING（Part / Session）の 2 本だけ。
- 復旧の副作用（pipeline.py:1706-1717）: NORMALIZING なら `normalized_path` を、TRANSCRIBING なら `transcripts/parts/<slug>.json` を `safe_unlink_staging(missing_ok=True)` で消す。失敗は `config_warning rule=§9.4` の WARNING で続行。**RAW_WRITING / WRITING の tmp は消していない**（SPEC §9.4 は「*.tmp を削除してから」と書いているが実装は消さない。本計画 X-14 の指摘どおり）。
- ログ: 1 件以上動いたら `recovery_completed rolled_back=<n>`。

★本計画への反映案: `recordTransition` に `kind: .normal | .recovery | .insert` を持たせる。`.normal` は遷移表、`.recovery` は PART_RECOVERY / SESSION_RECOVERY の写像（from→to がちょうどその組）でだけ許す。どちらにも無ければ `IllegalTransition`。detail は `.recovery` のとき `recovery` 固定。

---

## 2. エラーコード（src/voicedock/errors.py）

### 2.1 宣言順・再試行・分類（errors.py:80-174）

| # | コード | 分類 | retry | aborts_startup（voicedock） | ★本計画 |
|---|---|---|---|---|---|
| 1 | CONFIG_UNKNOWN_KEY | config | none | ○ | 設定エラー状態（停止） |
| 2 | CONFIG_INVALID_VALUE | config | none | ○ | 同上 |
| 3 | CONFIG_LOCK_MISMATCH | config | none | ○ | 削除要求を書かない |
| 4 | DEVICE_NOT_READABLE | device | next_poll | | Python 側で**未使用**（Helper の理由語だった） |
| 5 | DEVICE_UNSUPPORTED | device | none | | **未使用** |
| 6 | FILE_NOT_STABLE | device | next_poll | | **未使用** |
| 7 | DUPLICATE_CONTENT | import | none | | |
| 8 | SOURCE_MISSING | import | none | | |
| 9 | SOURCE_HASH_MISMATCH | import | attempts | | |
| — | HELPER_UNAVAILABLE | helper | **next_eval** | | ★廃止（next_eval も一緒に消える） |
| 10 | DELETE_QUEUE_FAILED | delete | next_connect | | voicedock **未使用** |
| 11 | DELETE_TIMEOUT | delete | next_connect | | |
| 12 | DISK_SPACE_LOW | **import** | next_poll | | |
| 13 | AUDIO_PROBE_FAILED | audio | attempts | | |
| 14 | IMPORT_FAILED | audio | attempts | | |
| 15 | NORMALIZE_VERIFY_FAILED | audio | attempts | | |
| 16 | NORMALIZED_MISSING | audio | next_connect | | |
| 17 | WHISPER_EXEC_MISSING | transcribe | none | **○（起動中止）** | 仕様は「FAILED」 |
| 18 | WHISPER_MODEL_MISSING | transcribe | none | **○（起動中止）** | 仕様は「FAILED」 |
| 19 | WHISPER_FAILED | transcribe | attempts | | |
| 20 | WHISPER_TIMEOUT | transcribe | attempts | | |
| 21 | NO_SPEECH_DETECTED | transcribe | none | | |
| 22 | OBSIDIAN_RAW_WRITE_FAILED | output | attempts | | |
| 23 | OBSIDIAN_RAW_VERIFY_FAILED | output | attempts | | |
| 24 | SESSION_MERGE_FAILED | session | attempts | | |
| 25 | LLM_UNAVAILABLE | llm | attempts | | |
| 26 | LLM_FAILED | llm | attempts | | |
| 27 | LLM_INVALID_JSON | llm | none | | |
| 28 | OBSIDIAN_NOT_FOUND | output | attempts | | Raw（Part）でも Daily（Session）でも使う（pipeline.py:495, 1281） |
| 29 | OBSIDIAN_WRITE_FAILED | output | attempts | | |
| 30 | OBSIDIAN_VERIFY_FAILED | output | attempts | | |
| 31 | SOURCE_IDENTITY_MISMATCH | delete | next_connect | | |
| 32 | SOURCE_DELETE_FAILED | delete | next_connect | | |
| — | LOCAL_DELETE_FAILED | delete | attempts | | ★廃止（src で未使用。paths.py:5 の docstring にだけ出る） |
| — | DB_ERROR | db | attempts | | ★廃止（src で未使用） |

- 仕様 A.3 の宣言順・retry 区分は上表と一致（HELPER_UNAVAILABLE / LOCAL_DELETE_FAILED / DB_ERROR を除いて）。
- `counts_against_max_attempts(code) = retry == attempts`（errors.py:211）。未知のコード文字列は偽（pipeline.py:1882-1887）。
- 表示名（daily.py:62-67）: DUPLICATE_CONTENT→`重複`、SOURCE_MISSING→`元ファイルが見つかりません`、NORMALIZED_MISSING→`元ファイルが見つかりません`、NO_SPEECH_DETECTED→`無音`。未知はコードのまま。`RETRY_ACTION = "デバイスから採り直してください。"`（daily.py:70）。
- `part_skipped` の reason 語（pipeline.py:177-181）: SOURCE_MISSING→`source_missing`、DUPLICATE_CONTENT→`duplicate_content`、NO_SPEECH_DETECTED→`no_speech`。

---

## 3. リトライ（pipeline.py:1750-1900、states.py、db.py）

- `retry_delay(attempt)`: `attempt < 1 || attempt >= maxAttempts` → nil、それ以外 `backoff[attempt-1]`（pipeline.py:1750-1760）。既定 `[3,10,30]`・3 回なら 1→3 秒、2→10 秒、3→nil（30 は使われない）。
- `in_process_retry(entity,key)` が nil を返す条件（pipeline.py:1763-1796）: 行が無い / status ≠ FAILED / error_code が nil か attempts 以外 / 戻り先が取れない。それ以外は `retry_delay(retry_count)`。**待つのは呼び手**。
- `resume_failed(reset_retry:)`（pipeline.py:1799-1832）: 戻り先 = `failed_from`（events の最新の `to_status='FAILED'` 行の `from_status`、`ORDER BY id DESC LIMIT 1`。db.py:489-502）が RETRYABLE_FROM_FAILED に在ればそれ。`record_transition(FAILED→target, detail = reset ? "requeue" : "retry", reset_retry)`。`TransitionConflict` は握って false。
- `requeue_failed()`（pipeline.py:1835-1852）: Part → Session の順、各 `rows_with_status(entity, FAILED)`（`ORDER BY updated_at, <key>`。db.py:504-517）を全部 `resume_failed(reset_retry: true)`。**時間を見ない。上限なし。**1 件以上なら `recovery_completed requeued=<n>`。
- `delete_evaluation_delay(attempts)`（pipeline.py:1855-1868）: backoff が空なら 0、`index = min(max(attempts,1), len) - 1`。**attempts 0 と 1 がどちらも先頭値**（test_retry.py:517 `handles_zero`）。仕様 §8.9.5 の `backoff[delete_attempts]` は 1 つずれる。
- テストで固定していること: ちょうど maxAttempts 回試し、終了時 retry_count == maxAttempts（test_retry.py:229-255）。

---

## 4. recordTransition と行の作成（src/voicedock/db.py）

### 4.1 手順（db.py:304-384）
1. `moment = now(tz)` を ISO8601 秒・オフセット付き（`2026-08-30T07:00:12+09:00`）に（db.py:636-638）。
2. `retry_expr`: `reset_retry || to ∈ RETRY_RESET_STATUSES` → `0`、`to == "FAILED"` → `retry_count + 1`、他 → `retry_count`。**RETRY_RESET_STATUSES は Part/Session 混合の文字列集合 6 件**（states.py:347-355）。
3. 1 トランザクションで
   `UPDATE <table> SET status=?, retry_count=<expr>, error_code=?, error_message=?, updated_at=? WHERE <key>=? AND status=?`
   （error_code / error_message は**無条件に上書き**。渡さなければ NULL。error_message は truncate）
4. `rowcount != 1` → `TransitionConflict`（ロールバック）。行が無い場合も同じ（test_db.py:447）。
5. 同じトランザクションで `INSERT INTO events (entity_type, entity_key, from_status, to_status, error_code, detail, created_at)`（detail は truncate、created_at = moment）。
- **遷移表の検査はしない**（db.py:328）。★本計画は検査する（§1.4 の案）。
- `entity_type` の値は `recording` / `session`（db.py:53-57）。

### 4.2 行の作成（db.py:388-424）
- `insert_recording` / `insert_session`: INSERT と同じトランザクションで **events に `from_status = NULL`, `to_status = 行の status`, error_code NULL, detail NULL** の 1 行（「行の誕生も遷移」。test_db.py:501）。★仕様 §5.2 に記載が無い。
- error_message は INSERT 時も truncate。

### 4.3 列の更新（db.py:562-607）
- `update_recording` / `update_session(**columns)`: `status` を渡すと ValueError、未知の列は ValueError、空なら何もしない。**`updated_at` を常に now で上書き**。error_message は truncate。
- ★仕様に「`updated_at` は遷移と列更新のたびに更新する」を明記すべき（§5.6 の idle 判定・§8.9.7 の期限切れが `updated_at` に依存する）。

### 4.4 truncate（db.py:172-180、log.py:90）
- `len(text) <= 200` ならそのまま。超えたら `text[:199] + "…"`（`MAX_VALUE_CHARS - len("…")`）。**Python の len はコードポイント数**。Swift では `unicodeScalars` で数える（`String.count` は書記素なので使わない）。例外を投げない。対象は `error_message`（INSERT / UPDATE / 遷移）と `events.detail`。

### 4.5 問い合わせ（db.py:436-545）
- `ungrouped_recordings`: `WHERE session_key IS NULL ORDER BY started_at, partkey`
- `recordings_for_session`: `WHERE session_key=? ORDER BY started_at, partkey`
- `sessions_with_status`: `ORDER BY session_key`
- `recordings_with_status`: `ORDER BY started_at, partkey`
- `pending_partkeys(terminal)`: `WHERE status NOT IN (...) ORDER BY started_at, partkey`
- `failed_from`: 上記
- `rows_with_status(entity, status)`: `(key, retry_count, error_code)`、`ORDER BY updated_at, <key>`
- `sessions_for_delete_evaluation`: 全セッション `(session_key, status, delete_attempts, updated_at)`、`ORDER BY updated_at, session_key`。updated_at が壊れていれば datetime.min 扱い（db.py:640-645）
- `recording_by_normalized_path`、`recording_by_sha256`
- `events_for(entity,key)`: `ORDER BY id`

### 4.6 接続（db.py:659-688）
- 親ディレクトリを作る → `PRAGMA journal_mode = WAL`（結果が `wal` でなければ close して例外）→ `foreign_keys = ON` → `busy_timeout = <ms>`（既定 10000）→ `synchronous = FULL` → `migrate` が真なら適用。
- `migrate=False` は診断・status の読み取り経路。**DB ファイルが無ければ開かない**（status.py:271, 295）。

### 4.7 マイグレーションとバックアップ（db.py:259-300）
- `schema_version(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)` に適用した版を 1 行ずつ。適用が無ければ何も書かない。
- **既存 DB（current が非 NULL）に未適用がある時だけ**、適用前に `Connection.backup()` で `<db名>.backup-v<current>-<stamp>`。`stamp = isoformat(秒).replace(":","").replace("-","")`（例 `20260830T070012+0900`）。**初回作成時はバックアップしない**（test_db.py:269）。
- ★GRDB の DatabaseMigrator を使うなら `schema_version` 表は作らない（`grdb_migrations` が代わる）ことを仕様に明記。`<cur>` は最後に適用済みの識別子（例 `v1_initial`）。

---

## 5. DDL（migrations 0001〜0003 の逐語。コメント除去）

```sql
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
    updated_at            TEXT    NOT NULL
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

CREATE TABLE schema_version (
    version    INTEGER PRIMARY KEY,
    applied_at TEXT    NOT NULL
);
-- 0002
ALTER TABLE recordings ADD COLUMN delete_request_id TEXT;
-- 0003
ALTER TABLE recordings ADD COLUMN duplicate_of TEXT;
```
- 作成順は sessions → recordings（FK のため）。recordings は 26 列（test_db.py:103）、sessions 22 列。★本アプリは末尾に `needs_recopy INTEGER NOT NULL DEFAULT 0` を足して 27 列、`imported_keys` 表を追加。
- 列の意味（SPEC §8.2）: `source_path` はボリュームルートからの相対、`partkey == device_id + "/" + source_path` が不変量。`ended_at = started_at + duration_seconds`。`mic_index` は `MIC002 → 2`。`transmitter_id` は `TX01`。重複 Part は **`sha256` を NULL のまま**（部分 UNIQUE のため双子と同値を書けない）で `duplicate_of` に双子の partkey。`duplicate_of` が NULL の重複は根拠 B が成立しない。

---

## 6. 設定（src/voicedock/config.py、config/config.example.yaml、SPEC §7.3）

### 6.1 読み込みの性質
- **全キー必須、コード側に既定値なし**（既定値は config.example.yaml だけ。config.py:8-11）。未知キーは pydantic `extra="forbid"` → V-1。
- 違反は `Violation(rule, code, key, message)` の並びで返す（例外にしない。config.py:543-548）。`render() = "<rule>  <code>  <key>: <message>"`（2 空白区切り。config.py:67-69）。
- キー欠落・型違いは規則 ID `"-"`（NO_RULE）+ CONFIG_INVALID_VALUE（config.py:41, 551-562）。
- `check_files`（V-20/23/24/25）と `check_locks`（V-30/V-33）は解析の後に足す。
- `startup_notices`: 削除有効時に V-26（警告）、V-30 / V-33 の「不明」を警告（config.py:647-676）。

### 6.2 V 規則（config.py:107-135 = SPEC §7.3 の順。欠番含む完全表）

| V | 内容 | コード | ★本アプリでの扱い |
|---|---|---|---|
| V-1 | 未知のキーが無い | CONFIG_UNKNOWN_KEY | 継承（CV-01） |
| ~~V-2~~ | 廃止（transcribe_variant） | — | 欠番 |
| V-3 | audio.target_* が 16000 / 1 / pcm_s16le | INVALID | キーごと廃止 → 欠番 |
| V-4 | device.poll_interval_seconds ≥ 1 | INVALID | 意味が近いのは scanIntervalSeconds（≥60）だが**別物**。仕様の CV-04（includeVolumes 非空要素）と**衝突** |
| ~~V-5~~ | 廃止（stability_checks ≥ 1。Helper 側へ） | — | 仕様の CV-05（mountMode）が**欠番を再利用** |
| ~~V-6~~ | 廃止 | — | 欠番 |
| V-7 | session.group_by == day | INVALID | キー廃止。仕様の CV-07（stabilityFastPath ≥1）と**衝突** |
| V-8 | session.block_gap_seconds ≥ 0 | INVALID | 継承 |
| V-9 | len(retry.backoff_seconds) ≥ retry.max_attempts | INVALID | 継承 |
| V-10 | llm.max_chars_per_request > chunk_overlap_chars × 2 | INVALID | 継承 |
| V-11 | raw / wiki の folder_template が相対で `..` を含まない | INVALID | 継承 |
| V-12 | raw.folder_template ≠ wiki.folder_template | INVALID | 継承 |
| V-13 | テンプレートの未知プレースホルダ無し（許可 `{yyyymmdd}` `{date}` `{time}`。raw.folder / raw.filename / wiki.folder / wiki.filename の 4 つ） | INVALID | 継承 |
| V-14 | wiki.filename_template に `{title}` を含まない（V-13 より先に判定） | INVALID | 継承 |
| ~~V-15~~ | 廃止（granularity） | — | **欠番**（仕様「CV-11〜CV-16」は CV-15 を含めてしまう） |
| V-16 | obsidian.max_title_bytes が 1〜255 | INVALID | 継承 |
| V-17 | analysis.order ⊆ sections のキー、重複なし | INVALID | 継承 |
| V-18 | sections.summary.enabled == true | INVALID | 継承 |
| V-19 | order に載る各 section の heading が非 nil、`#` で始まり改行を含まない | INVALID | 継承 |
| V-20 | llm.prompts.* の 4 ファイルが在る | INVALID | キー廃止（バンドル資源）→ 欠番 |
| V-21 | cleanup.retain_transcript_days == 0 | INVALID | キー廃止 → 欠番 |
| V-22 | import.staging_max_bytes > free_space_margin_bytes | INVALID | 継承（audio.* 側へ移すなら名前も決める） |
| V-23 | transcription.model のファイルが在る | WHISPER_MODEL_MISSING | 仕様 CV-23 は「カタログに在る ID」に意味を変更 |
| V-24 | transcription.executable が在り実行可能 | WHISPER_EXEC_MISSING | キー廃止（DR-04 が担う）→ 欠番 |
| V-25 | vad.enabled なら vad.model が在る | WHISPER_MODEL_MISSING | 継承（ID がカタログに在る、に変更） |
| V-26 | delete_source_audio == true なら起動時警告 | 警告のみ | 仕様に無い（パネルの常時表示が代替）→ 欠番にするか残すか要決定 |
| ~~V-27~~ ~~V-28~~ | 廃止 | — | 欠番 |
| V-29 | import.inbox_retain ∈ {normalized, raw_saved} | INVALID | 継承 |
| V-30 | delete_source_audio == true のとき Helper 側（heartbeat）の delete_source_audio が false と**確定** | CONFIG_LOCK_MISMATCH | 継承（reaper.conf を直接読む） |
| V-31 | import.helper_heartbeat_max_age_seconds ≥ 60 | INVALID | 仕様 CV-31 は snapshotMaxAge > scanInterval に変更 |
| V-32 | timezone が解決できる | INVALID | 継承 |
| V-33 | delete_source_audio == true のとき Helper 側 MOUNT_MODE が ro と**確定** | CONFIG_LOCK_MISMATCH | **仕様に無い**。本アプリでは config 内で `deleteSourceAudio == true && mountMode == ro` を検出できる（確定値）ので CV-33 として残すべき |
| ~~V-34~~ | 廃止 | — | 欠番 |

Helper.conf の検査（SPEC §7.4 の表、番号は V ではなく「検査 1〜7」）: 1 VOLUMES_ROOT がディレクトリ、2 VOICEDOCK_HOME、3 配列宣言、4 **両配列の各要素が空文字でない**、5 MOUNT_MODE ∈ {ro,rw}、6 DELETE_SOURCE_AUDIO ∈ {true,false}、7 STABILITY_CHECKS ≥1 ∧ STABILITY_INTERVAL_SECONDS ≥1 ∧ MAX_SCAN_DEPTH ≥1。**STABILITY_FAST_PATH_SECONDS は検査対象外で、未設定・不正なら 60 に倒す**（0 に倒すと全件即断）。
→ 仕様の CV-04 / CV-05 / CV-07 はこの「検査 4 / 5 / 7」の番号を流用したもので、V-4 / V-5 / V-7 と衝突している。

### 6.3 config.example.yaml の全キーと既定値（config.example.yaml:7-193）

| キー | 既定 | 型・制約 | 読まれているか | ★本アプリ |
|---|---|---|---|---|
| timezone | Asia/Tokyo | str、V-32 | ○ | timeZone（初回 TimeZone.current） |
| device.root | /inbox | Path | **×（死んだ設定）** | 廃止 |
| device.poll_interval_seconds | 5 | int ≥1（V-4） | ○（worker） | 廃止（Worker は 30 秒周期固定） |
| audio.ffmpeg / ffprobe | パス | | ○ | 廃止 |
| audio.target_sample_rate / channels / codec | 16000 / 1 / pcm_s16le | Literal（V-3） | ○ | 廃止（定数） |
| audio.ffprobe_timeout_seconds | 30 | int | ○ | 廃止 |
| audio.ffmpeg_timeout_factor | 0.5 | float | ○ | audio.* |
| audio.ffmpeg_min_timeout_seconds | 180 | int | ○ | audio.* |
| audio.duration_tolerance_seconds | 1.0 | float | ○ | audio.* |
| import.inbox_root / staging_root | /inbox, /data/staging | Path | ○ | 廃止（<HOME> 固定） |
| import.free_space_multiplier | 2.0 | float | ○ | audio.* |
| import.free_space_margin_bytes | 2147483648 | int | ○ | audio.* |
| import.staging_max_bytes | 5368709120 | int、V-22 | ○ | audio.* |
| import.hash_chunk_bytes | 1048576 | int | ○（audio.py:585, 623） | audio.* |
| import.inbox_retain | normalized | normalized/raw_saved（V-29） | ○ | audio.* |
| import.helper_heartbeat_max_age_seconds | 900 | int ≥60（V-31） | ○ | device.snapshotMaxAgeSeconds |
| session.group_by | day | Literal（V-7） | — | 廃止 |
| session.block_gap_seconds | 3600 | int ≥0（V-8） | ○ | |
| session.idle_close_seconds | 1800 | int | ○（session.py:294） | |
| session.allow_reopen | true | bool | ○ | |
| session.max_parts | 64 | int | ○（session.py:214） | |
| session.max_duration_seconds | 86400 | int | ○ | |
| transcription.engine | whisper_cpp | str | **×** | 廃止 |
| transcription.executable | /usr/local/bin/whisper-cli | Path（V-24） | ○ | 廃止（バンドル） |
| transcription.model | …/ggml-large-v3-turbo-q5_0.bin | Path（V-23） | ○ | whisperModelID |
| transcription.language | ja | str | ○ | |
| transcription.threads | 0 | int。0 → **`min(os.cpu_count(), 8)`**（論理 CPU 数。transcribe.py:118-119） | ○ | 仕様は「物理コア」→ 食い違い |
| transcription.timeout_factor / min / max | 3.0 / 600 / 21600 | | ○ | |
| transcription.min_chars | 1 | int | ○ | |
| transcription.vad.enabled | true | bool | ○ | |
| transcription.vad.model | …/ggml-silero-v5.1.2.bin | Path（V-25） | ○ | vad.modelID |
| transcription.vad.threshold | 0.5 | float | ○ | |
| transcription.vad.min_speech_duration_ms | 250 | int | ○ | |
| transcription.vad.min_silence_duration_ms | 1000 | int | ○ | |
| transcription.vad.speech_pad_ms | 200 | int | ○ | |
| llm.endpoint_env / model_env | VOICEDOCK_LLM_URL / _MODEL | str | ○ | 廃止 |
| llm.temperature / top_p | 0.1 / 0.9 | float | ○ | |
| llm.max_output_tokens | 4096 | int | ○ | |
| llm.request_timeout_seconds | 1800 | int | ○ | |
| llm.max_chars_per_request | 20000 | int、V-10 | ○ | |
| llm.max_seconds_per_request | 3600 | int | ○ | |
| llm.chunk_overlap_chars | 500 | int | ○ | |
| llm.repair_attempts | 1 | int | ○ | |
| llm.prompts.analyze/map/reduce/repair | /app/prompts/*.txt | Path（V-20） | ○ | 廃止（バンドル） |
| llm.analysis.sections.summary | {enabled: true, heading: "## Summary"} | V-18/V-19 | ○ | |
| llm.analysis.sections.timeline | {enabled: true, heading: "## Timeline"} | | ○ | |
| llm.analysis.sections.key_points | {enabled: true, heading: "## Key Points", max_items: 20} | | ○ | |
| llm.analysis.sections.tasks | {enabled: true, heading: "## Tasks", max_items: 50} | | ○ | |
| llm.analysis.sections.decisions | {enabled: true, heading: "## Decisions", max_items: 30} | | ○ | |
| llm.analysis.sections.ideas | {enabled: true, heading: "## Ideas", max_items: 30} | | ○ | |
| llm.analysis.sections.tags | {enabled: true, max_items: 15}（heading 無し） | | ○ | |
| llm.analysis.order | [summary, timeline, key_points, tasks, decisions, ideas] | V-17 | ○ | |
| llm.analysis.custom_instructions | "" | str | ○ | |
| obsidian.root | /obsidian | Path | ○ | vault.path |
| obsidian.vault_marker | ".obsidian" | str（空で検査無効） | ○ | vault.marker（空禁止） |
| obsidian.max_title_bytes | 180 | int 1〜255（V-16） | ○ | |
| obsidian.default_tags | [voice, voicedock] | [str] | ○ | |
| obsidian.raw.folder_template | "Daily/Voice/Raw/{yyyymmdd}" | V-11/V-12/V-13 | ○ | |
| obsidian.raw.filename_template | "{date} raw" | V-13 | ○ | |
| obsidian.raw.timestamp_interval_seconds | 300 | int（**0 で見出しを入れない**） | ○ | |
| obsidian.raw.part_boundary_heading | true | bool | ○ | |
| obsidian.wiki.folder_template | "Daily/Voice/Wiki/{yyyymmdd}" | V-11/12/13 | ○ | |
| obsidian.wiki.filename_template | "{date} Voice" | V-13/V-14 | ○ | |
| obsidian.wiki.timeline | true | bool | **×（死んだ設定）** | 廃止（仕様どおり） |
| obsidian.wiki.link_daily_note / link_adjacent_days | true / true | bool | ○ | |
| obsidian.wiki.link_tags | true | bool（**false なら Vault 索引を作らない**。wiki.py:162） | ○ | |
| obsidian.wiki.link_only_existing | true | bool（`link_tags and (existing or not link_only_existing)`。wiki.py:280） | ○ | |
| obsidian.wiki.vault_index_cache_seconds | 300 | int | ○ | |
| obsidian.wiki.max_links | 20 | int | ○ | |
| cleanup.delete_source_audio | false | bool | ○ | |
| cleanup.delete_skipped_source | false | bool | ○ | |
| cleanup.delete_normalized_after_transcribe | true | bool | ○ | |
| cleanup.retain_transcript_days | 0 | Literal[0]（V-21） | — | 廃止 |
| cleanup.delete_evaluation_backoff_seconds | [60, 300, 900, 3600] | [int] | ○ | |
| cleanup.queue_root | /queue | Path | ○ | 廃止 |
| cleanup.delete_result_timeout_seconds | 3600 | int | ○ | |
| retry.max_attempts | 3 | int | ○ | |
| retry.backoff_seconds | [3, 10, 30] | [int]、V-9 | ○ | |
| logging.level | INFO | DEBUG/INFO/WARNING/ERROR（大文字） | ○ | 仕様は `info`（小文字）→ 綴りを決める |
| logging.format | text | text/json | ○ | 廃止 |
| logging.unsafe_log_content | false | bool | ○ | |
| database.path | /data/voicedock.db | Path | ○ | 廃止 |
| database.busy_timeout_ms | 10000 | int | ○ | 廃止（10000 固定） |

helper.conf 由来（SPEC §7.4）: VOLUMES_ROOT=/Volumes、INCLUDE_VOLUMES=()（空 = 制限なし）、EXCLUDE_VOLUMES=("Macintosh HD" "com.apple.TimeMachine.*" ".*")、MOUNT_MODE=ro、DELETE_SOURCE_AUDIO=false、STABILITY_FAST_PATH_SECONDS=60、STABILITY_INTERVAL_SECONDS=3、STABILITY_CHECKS=2、MAX_SCAN_DEPTH=3。仕様 §6.2 の device.* 既定値と一致。

---

## 7. ログ（src/voicedock/log.py、SPEC §16）

### 7.1 イベント（log.py:39-51。29 件。docstring の「28 件」は古い）
```
service_started service_stopping config_warning recovery_completed
helper_heartbeat_stale helper_recovered
part_discovered part_skipped unparsable_filename
normalize_completed normalize_failed
transcription_completed transcription_failed
raw_note_saved raw_note_failed
session_merged session_merge_failed session_empty session_reopened
llm_completed llm_failed analysis_trimmed
obsidian_saved obsidian_failed
delete_requested source_deleted source_delete_skipped source_delete_pending
disk_space_low
```
- 未登録の名前は ValueError。**検証はレベルフィルタより先**（log.py:151-166）。
- 予約フィールド名 `ts` / `level` / `event` は使えない（log.py:99, 158-162）。
- 値の型は str / int / float / bool / nil だけ（log.py:24, 180-184）。

### 7.2 redaction（log.py:64-97, 180-192）
- `CONTENT_FIELDS` = `text, transcript, summary, content, body, prompt, title, tags, key_points, tasks, decisions, ideas, segments, filename, note_name`（15 件）。キー名が一致すれば値を `<redacted>`。
- キー名に関係なく **200 文字（コードポイント）超の str は `<redacted>`**。
- 例外: `unsafe_log_content == true` **かつ** レベル DEBUG のときだけ、両方の遮断を外す。

### 7.3 行の書式（text。log.py:194-223）
- `"<ts> <LEVEL を左寄せ 5 桁> <event>"` + フィールドごと `" k=v"`（渡した順）。
  - ts = 設定のタイムゾーンで ISO8601 秒・オフセット付き。
  - LEVEL は `DEBUG` / `INFO `（空白 1 つ補って 5 桁）/ `WARNING`（7 桁のまま）/ `ERROR`。
- 値: nil→`null`、Bool→`true`/`false`、str は `^[\x21-\x7e]+$` に一致し `"` と `=` を含まなければそのまま、それ以外は JSON 文字列（`ensure_ascii=False`。空白・非 ASCII・空文字列はこちら）。数値は Python の `str()`（float は `1800.0` のように `.0` が付く）。
- 例（SPEC §16.2）: `2026-08-30T07:00:12+09:00 INFO  service_started version=0.1.0`
- レベル: DEBUG 10 / INFO 20 / WARNING 30 / ERROR 40。閾値未満は出さない。

### 7.4 原則（SPEC §16.4）
- 1 工程につき完了 1 件・失敗 1 件。開始イベントを出さない。状態遷移は events 表。分岐は `reason=` / `error_code=`。
- `source_delete_skipped` の reason: `delete_source_audio_disabled` / `device_readonly` / `already_absent` / `status_changed`（WARNING、その Part だけ飛ばす）。
- `part_skipped` の reason: `source_missing` / `duplicate_content` / `no_speech`、および `already_known`（DEBUG）。
- 識別子フィールド名は `recording_key` / `session_key`（完全な鍵。短縮しない）。

---

## 8. status（src/voicedock/status.py）— パネル「状態の詳細」の元

- Part の表示順（status.py:48-61）: DISCOVERED, NORMALIZING, NORMALIZED, TRANSCRIBING, TRANSCRIBED, RAW_WRITING, RAW_SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING, COMPLETED, **SKIPPED, FAILED**（宣言順と SKIPPED/FAILED が逆）。
- Session の表示順（status.py:62-76）: 宣言順と同じ。
- 件数: `SELECT status, COUNT(*) FROM <table> GROUP BY status`、全状態を 0 で埋めてから上書き（status.py:269-283, 319-323）。
- 注記は Part 専用: SKIPPED→`（無音）`、FAILED→`（次回接続時に再試行）`。Session には付けない（status.py:78-90）。
- Backlog（未処理）= 非終端 Part（`PartStatus − PART_TERMINAL`）の件数・`SUM(duration_seconds)`（NULL は 0 として合計し件数を併記）。表示 `未処理 {h:.1f} 時間ぶん（{n} part）`、NULL があれば `、うち {k} part は長さ不明`、0 件なら `未処理なし`（status.py:119-134, 326-348）。
- Failed parts: `WHERE status='FAILED' ORDER BY started_at LIMIT 20`、総数も数え、超過分は `… ほか {n} 件`。1 件 2 行（partkey / `started_at[:16] の T→空白  <code|unknown>  retry <n>/<max>`）。末尾に `→ 次にデバイスを接続したときに自動で再試行される（§15.2）`（status.py:92-117, 351-371, 555-562）。
- ロック表示: lock1 = config && helper が true（両方）。enabled = lock1 && reaper_installed == true && mount_readonly == false。不明は偽側（status.py:137-162）。
- マウント表示語: `no device`（0 台）/ `unknown`（nil）/ `readOnly` / `writable`（status.py:171-194）。**nil を writable に丸めない、0 台を観測扱いしない。**
- DB が無ければ全 0 で表示（DB を作らない）。sqlite3.Error も全 0（落ちない）。
