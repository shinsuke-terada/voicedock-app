# VoiceDock 規範の表（docs/SPEC.md）

> この文書は `docs/PLAN.md` の規範の表の写しで、`tools/spec/make-spec.py` が作る。**手で直さない。**
> テスト（SPEC 同期）がこの文書を読み、実装の enum・定数・テストの表示名と突き合わせる。
> 表を変えるときは PLAN を直し、同じ PR で `python3 tools/spec/make-spec.py` を実行する（SpecMatchesPlanTests が食い違いを落とす）。
> 見出しの `S1.`〜`S9.` はテストが節を探す鍵なので変えない。

## S1. 状態と復旧写像（PLAN 付録 A.1）

Part の状態（宣言順。初期状態 DISCOVERED）:

| # | Part の状態 |
|---|---|
| 1 | `DISCOVERED` |
| 2 | `NORMALIZING` |
| 3 | `NORMALIZED` |
| 4 | `TRANSCRIBING` |
| 5 | `TRANSCRIBED` |
| 6 | `RAW_WRITING` |
| 7 | `RAW_SAVED` |
| 8 | `SOURCE_DELETING` |
| 9 | `SOURCE_DELETE_PENDING` |
| 10 | `COMPLETED` |
| 11 | `FAILED` |
| 12 | `SKIPPED` |

Session の状態（宣言順。初期状態 OPEN）:

| # | Session の状態 |
|---|---|
| 1 | `OPEN` |
| 2 | `READY` |
| 3 | `MERGING` |
| 4 | `MERGED` |
| 5 | `ANALYZING` |
| 6 | `ANALYZED` |
| 7 | `WRITING` |
| 8 | `SAVED` |
| 9 | `SOURCE_DELETING` |
| 10 | `SOURCE_DELETE_PENDING` |
| 11 | `CLEANUP` |
| 12 | `COMPLETED` |
| 13 | `FAILED` |

- 進行中（復旧で戻す）: Part `NORMALIZING, TRANSCRIBING, RAW_WRITING, SOURCE_DELETING`、Session `MERGING, ANALYZING, WRITING, SOURCE_DELETING, CLEANUP`。
  **`SOURCE_DELETE_PENDING` は名前に ING を含むが進行中ではない**（接尾辞で判定しない。SM-10）

復旧写像（`kind: .recovery` でだけ許す辺。この順に処理する。voicedock states.py:271-293）:
```text
Part:    NORMALIZING→DISCOVERED | TRANSCRIBING→NORMALIZED | RAW_WRITING→TRANSCRIBED | SOURCE_DELETING→SOURCE_DELETE_PENDING
Session: MERGING→READY | ANALYZING→MERGED | WRITING→ANALYZED | SOURCE_DELETING→SOURCE_DELETE_PENDING | CLEANUP→SAVED
```

## S2. 遷移表（PLAN 付録 A.2）

Part:
```text
DISCOVERED→NORMALIZING | DISCOVERED→SKIPPED(SOURCE_MISSING)
NORMALIZING→NORMALIZED | NORMALIZING→SKIPPED(DUPLICATE_CONTENT, SOURCE_MISSING) | NORMALIZING→FAILED
NORMALIZED→TRANSCRIBING | NORMALIZED→NORMALIZING(16kHz 消失) | TRANSCRIBING→NORMALIZING(同)
TRANSCRIBING→TRANSCRIBED | TRANSCRIBING→SKIPPED(NO_SPEECH_DETECTED) | TRANSCRIBING→FAILED
TRANSCRIBED→RAW_WRITING | RAW_WRITING→RAW_SAVED | RAW_WRITING→FAILED
RAW_SAVED→SOURCE_DELETING | RAW_SAVED→COMPLETED(削除しない)
SOURCE_DELETING→COMPLETED | SOURCE_DELETING→SOURCE_DELETE_PENDING | SOURCE_DELETE_PENDING→SOURCE_DELETING
COMPLETED→SOURCE_DELETING(過去分)
FAILED→NORMALIZING | FAILED→TRANSCRIBING | FAILED→RAW_WRITING
```
（「手動で消した分を完了にする」は直通の辺を足さず、voicedock backlog.py と同じく SOURCE_DELETE_PENDING→SOURCE_DELETING→COMPLETED の 2 遷移で行う。
RAW_SAVED で結果を待っていた Part の DELETED も RAW_SAVED→SOURCE_DELETING→COMPLETED の 2 遷移で進める）

Session:
```text
OPEN→OPEN(Part 追加) | OPEN→READY
READY→MERGING | MERGING→MERGED | MERGING→COMPLETED(session_empty) | MERGING→FAILED
MERGED→ANALYZING | ANALYZING→ANALYZED | ANALYZING→FAILED
★ MERGED→ANALYZED(analysis_reused)
★ ANALYZED→ANALYZING(stale_analysis) | ★ WRITING→ANALYZING(stale_analysis)
ANALYZED→WRITING | WRITING→SAVED | WRITING→FAILED
SAVED→SOURCE_DELETING | SAVED→CLEANUP | SAVED→MERGING(再オープン) | COMPLETED→MERGING(再オープン)
★ SOURCE_DELETING→MERGING(再オープン) | ★ SOURCE_DELETE_PENDING→MERGING(再オープン) | ★ CLEANUP→MERGING(再オープン)
SOURCE_DELETING→CLEANUP | SOURCE_DELETING→SOURCE_DELETE_PENDING
SOURCE_DELETE_PENDING→SOURCE_DELETING | SOURCE_DELETE_PENDING→CLEANUP | CLEANUP→COMPLETED
FAILED→MERGING | FAILED→ANALYZING | FAILED→WRITING
```

> ★ を除いた辺の集合は voicedock `d3d595e:src/voicedock/states.py` の `PART_TRANSITIONS`（23 本）/ `SESSION_TRANSITIONS`（24 本）と一回限りのスクリプトで照合済み（v1.1）。
> **voicedock の `record_transition` は遷移表を検査していなかった**（db.py:328）。そのため voicedock は表に無い辺（復旧の 7 本、`MERGED→ANALYZED`、`ANALYZED→FAILED`、`CLEANUP→SOURCE_DELETING`）を実際に使っていた。
> 本アプリは表を強制するので、復旧は復旧写像（A.1）に分け、`MERGED→ANALYZED` は ★ で足し（ほかの ★ は stale_analysis の 2 本と、削除段からの再オープンの 3 本）、`ANALYZED→FAILED` と `CLEANUP→SOURCE_DELETING` は経路を直して不要にした（§5.6 / §8.9.5）。
> T-08 ではこの一致を、voicedock のファイルから辺を抜き出す一回限りのスクリプトでもう一度確かめ、結果を PR に貼る。

## S3. エラーコード（PLAN 付録 A.3）

RetryPolicy: `none`（再評価の契機まで待たない。FAILED なら requeue で戻る）/ `nextPoll`（行に書かない観測・ガード）/ `nextConnect`（次の接続の立ち上がりで requeue）/ `attempts`（工程内リトライの対象）。

| # | コード | 再試行 | 行き先 | 本アプリでの扱い |
|---|---|---|---|---|
| 1 | `CONFIG_UNKNOWN_KEY` | none | 設定エラー状態 | 終了ではなく停止（CV-01） |
| 2 | `CONFIG_INVALID_VALUE` | none | 同上 | |
| 3 | `CONFIG_LOCK_MISMATCH` | none | 設定エラー状態（CV-30 / CV-33） | 削除要求も書かない |
| 4 | `DEVICE_NOT_READABLE` | nextPoll | — | **DB の行には書かない**。snapshot の `unavailable`・パネル・ログの `error_code=` だけ |
| 5 | `DEVICE_UNSUPPORTED` | none | — | 同上 |
| 6 | `FILE_NOT_STABLE` | nextPoll | — | 同上 |
| 7 | `DUPLICATE_CONTENT` | none | Part SKIPPED | |
| 8 | `SOURCE_MISSING` | none | Part SKIPPED | `needs_recopy = 1` のときは SKIPPED にせず待つ（§8.3） |
| 9 | `SOURCE_HASH_MISMATCH` | attempts | FAILED | `needs_recopy = 1` |
| — | ~~`HELPER_UNAVAILABLE`~~ | | | **廃止**（番号を詰めない） |
| 10 | `DELETE_QUEUE_FAILED` | nextConnect | 状態は動かさず ID を外す | 要求ファイルが書けないとき（voicedock は未使用だった）。ログだけ |
| 11 | `DELETE_TIMEOUT` | nextConnect | PENDING（SKIPPED・RAW_SAVED は ID を外すだけ） | |
| 12 | `DISK_SPACE_LOW` | nextPoll | ガード | 行には書かない（変換中の再確認で失敗したときだけ FAILED） |
| 13 | `AUDIO_PROBE_FAILED` | attempts | 続行（ログのみ） | |
| 14 | `IMPORT_FAILED` | attempts | FAILED | 変換の失敗・時間超過・slug の衝突 |
| 15 | `NORMALIZE_VERIFY_FAILED` | attempts | FAILED | |
| 16 | `NORMALIZED_MISSING` | nextConnect | FAILED | `needs_recopy = 1` |
| 17 | `WHISPER_EXEC_MISSING` | none | FAILED | 起動に失敗したときだけ。**実行ファイルが無いことは工程に入る前のガード**（§5.4） |
| 18 | `WHISPER_MODEL_MISSING` | none | — | **ガードの理由（要対応の表示）にだけ使い、行には書かない**（voicedock では設定検証のコード） |
| 19 | `WHISPER_FAILED` | attempts | FAILED | 終了コード ≠ 0、または生 JSON が無い・読めない |
| 20 | `WHISPER_TIMEOUT` | attempts | FAILED | |
| 21 | `NO_SPEECH_DETECTED` | none | SKIPPED | |
| 22 | `OBSIDIAN_RAW_WRITE_FAILED` | attempts | Part FAILED | 99 を超えた同名ファイルも |
| 23 | `OBSIDIAN_RAW_VERIFY_FAILED` | attempts | Part FAILED | |
| 24 | `SESSION_MERGE_FAILED` | attempts | Session FAILED | チャンクが 0 個 |
| 25 | `LLM_UNAVAILABLE` | attempts | Session FAILED | 起動失敗（`server_start_failed`）・接続失敗・HTTP 400 以上。**モデル未選択・無い・メモリ不足はガード** |
| 26 | `LLM_FAILED` | attempts | Session FAILED | 解析結果の書き込み失敗 |
| 27 | `LLM_INVALID_JSON` | none | Session FAILED | |
| 28 | `OBSIDIAN_NOT_FOUND` | attempts | FAILED | ガードを通った後に Vault が消えたとき（§8.7） |
| 29 | `OBSIDIAN_WRITE_FAILED` | attempts | FAILED | |
| 30 | `OBSIDIAN_VERIFY_FAILED` | attempts | FAILED | |
| 31 | `SOURCE_IDENTITY_MISMATCH` | nextConnect | PENDING | |
| 32 | `SOURCE_DELETE_FAILED` | nextConnect | PENDING | |
| — | ~~`LOCAL_DELETE_FAILED`~~, ~~`DB_ERROR`~~ | | | **廃止**（voicedock でも未使用） |

表示名（警告行）: DUPLICATE_CONTENT→重複、SOURCE_MISSING→元ファイルが見つかりません、NORMALIZED_MISSING→元ファイルが見つかりません、NO_SPEECH_DETECTED→無音。未知はコードのまま、無ければ「理由不明」。
`part_skipped` の reason 語: SOURCE_MISSING→`source_missing`、DUPLICATE_CONTENT→`duplicate_content`、NO_SPEECH_DETECTED→`no_speech`。

## S4. ログイベント（PLAN 付録 A.4）

voicedock の 29 件から `helper_heartbeat_stale` / `helper_recovered` を廃止し、`config_invalid` 以下を足す（`remount_readonly_failed` は voicedock v5.0 で消えた名前なので再利用せず `remount_failed` にした）:

```text
service_started service_stopping config_warning config_invalid recovery_completed
part_discovered part_skipped unparsable_filename
normalize_completed normalize_failed transcription_completed transcription_failed
raw_note_saved raw_note_failed session_merged session_merge_failed session_empty session_reopened
llm_completed llm_failed analysis_trimmed obsidian_saved obsidian_failed
delete_requested source_deleted source_delete_skipped source_delete_pending disk_space_low
scan_completed volume_skipped file_not_stable copy_completed copy_failed remount_failed coexistence_blocked
inbox_orphans_removed imported_keys_added pipeline_paused pipeline_resumed
llm_server_started llm_server_stopped reaper_run reaper_failed deletion_enabled deletion_disabled
model_downloaded model_download_failed diagnostics_completed
```

主な reason / フィールド（逐語。新しい語を足すときはここに足す）:
- `recovery_completed`: `rolled_back=<n>`（復旧）/ `requeued=<n>`（再評価）
- `source_delete_skipped`: `reason=delete_source_audio_disabled|lock_mismatch|mount_mode_ro|reaper_not_installed|reaper_invalid|device_readonly|already_absent|status_changed`
- `source_delete_pending`: `reason=<RV の理由語>|still_in_inventory|no_result|queue_write_failed`
- `disk_space_low`: `reason=<空き容量の文言>|staging_unlink_failed`
- `pipeline_paused` / `pipeline_resumed`: `reason=disk_space_low|whisper_missing|model_missing|vad_model_missing|vault_not_configured|vault_unavailable|llm_not_selected|llm_model_missing|llm_insufficient_memory|llama_server_missing|license`
- `volume_skipped`: `reason=not_included|excluded|symlink|not_a_mount_point|not_listable|no_recordings|mount_name_mismatch|invalid_device_id`（DEBUG。not_listable / mount_name_mismatch / invalid_device_id は前回の走査から変わったときだけ WARNING）
- `copy_failed`: `reason=copy_size_mismatch|read_error|write_error|changed`
- `remount_failed`: `reason=no_device_node|unmount_failed|mount_failed|still_writable`
- `raw_note_failed` / `obsidian_failed`: `reason=vault|write|verify`
- `reaper_failed`: `reason=version_mismatch|signature|exit_<n>|timeout|busy`（`reaper_run exit=<n>` は起動したら常に出す。シグナルで終わったときは `exit=<128 + シグナル番号>`、起動に失敗したときは `exit=127`、タイムアウトのときは `exit=null`）
- `pipeline_paused` は WARNING、`pipeline_resumed` は INFO
- DB の例外（`StoreError` など、工程の外で起きたもの）は `config_warning rule=store message=<型名>` を WARNING で出す（専用のイベントを増やさない）
- 出す場所とフィールド（本文に無いもの）:
  - `unparsable_filename relpath=…`（DEBUG）: 走査で、ファイル規則の形には一致するが日時が不正な名前（`RecordingName.parseFile` が nil。例 `…_20260230_…`）
  - `scan_completed devices=<n> copied=<n> elapsed_s=<x>`: 走査の終わり。コピーが 1 件以上なら INFO、0 件なら DEBUG
  - `transcription_failed recording_key=… error_code=…`（ERROR）: 文字起こしの FAILED
  - `llm_failed session_key=… error_code=… detail=…`（ERROR）: 解析の FAILED（`SESSION_MERGE_FAILED` を除く）
  - `session_merge_failed session_key=… error_code=SESSION_MERGE_FAILED`（ERROR）: チャンク 0 個
  - `diagnostics_completed passed=<n> failed=<n> notices=<n>`（INFO）: 診断の終わり
  - `part_discovered recording_key=… duration_s=<x|null> [error_code=AUDIO_PROBE_FAILED]`（INFO）: 登録
  - `deletion_enabled [reason=skipped_source]`（根拠 B の有効化のときだけ reason を付ける）、`deletion_disabled [reason=<失敗した段>]`
  - `normalize_failed` の `reason=input`（16 kHz も inbox の原本も無い）
  - `model_download_failed` の `reason=sha256_mismatch|size_mismatch|http_<code>|network|cancelled|bad_url|bad_file_name|io`

reaper は別のログ（`logs/reaper.log`）に固定のイベントを書く（§8.9.4）。`LogEvent` には含めない。

原則（voicedock §16.4）: 1 工程につき「完了」1 件と「失敗」1 件だけ。開始イベントは出さない（状態遷移は `events` テーブルが持つ）。細かい分岐は名前を増やさず `reason=` / `error_code=` で表す。

## S5. 設定の検証 CV（PLAN §6.4）

番号は voicedock の V と**意味が同じものだけ**同じ番号にする。欠番（再利用しない）: CV-02〜07（V-2〜7 はキー廃止か別物）、CV-15、CV-20、CV-21、CV-23〜28（V-23/24 はファイル検査で意味が違う・V-25 はパス → ID に変わった・V-26 はパネルの常時表示で代替・V-27/28 は廃止）、CV-31（V-31 は別物）、CV-34〜38。

| # | 規則 | コード | 由来 |
|---|---|---|---|
| CV-01 | 未知のキーが無い（全階層） | CONFIG_UNKNOWN_KEY | V-1 |
| CV-08 | `session.blockGapSeconds >= 0` | CONFIG_INVALID_VALUE | V-8 |
| CV-09 | `retry.backoffSeconds.count >= retry.maxAttempts` | CONFIG_INVALID_VALUE | V-9 |
| CV-10 | `llm.maxCharsPerRequest > llm.chunkOverlapChars * 2` | CONFIG_INVALID_VALUE | V-10 |
| CV-11 | raw / wiki の `folderTemplate` が相対パス（`/` で始まらない）で、`/` で分けた要素に `..` が無い | CONFIG_INVALID_VALUE | V-11 |
| CV-12 | `raw.folderTemplate != wiki.folderTemplate` | CONFIG_INVALID_VALUE | V-12 |
| CV-13 | 4 つのテンプレート（raw.folder / raw.filename / wiki.folder / wiki.filename）の `{…}` が `{yyyymmdd}` `{date}` `{time}` だけ | CONFIG_INVALID_VALUE | V-13 |
| CV-14 | `wiki.filenameTemplate` に `{title}` を含まない（**CV-13 より先に判定し、該当したら CV-13 はそのテンプレートについて出さない**） | CONFIG_INVALID_VALUE | V-14 |
| CV-16 | `obsidian.maxTitleBytes` が 1〜255 | CONFIG_INVALID_VALUE | V-16 |
| CV-17 | `analysis.order` の各要素が sections の 7 キーのどれかで、重複が無い | CONFIG_INVALID_VALUE | V-17 |
| CV-18 | `sections.summary.enabled == true`（DN-8 の前提） | CONFIG_INVALID_VALUE | V-18 |
| CV-19 | `order` に載る各節の `heading` が null でなく、`#` で始まり、改行（`\n` `\r`）を含まない | CONFIG_INVALID_VALUE | V-19 |
| CV-22 | `audio.stagingMaxBytes > audio.freeSpaceMarginBytes` | CONFIG_INVALID_VALUE | V-22 |
| CV-29 | `audio.inboxRetain` が `normalized` か `raw_saved` | CONFIG_INVALID_VALUE | V-29 |
| CV-30 | ロック 1 が食い違っていない: reaper.conf が読めるとき（`.valid`）、`cleanup.deleteSourceAudio == reaperConf.deleteSourceAudio`（どちら向きの食い違いも違反）。reaper.conf が無い・読めないときはこの規則を評価しない（不明は §8.9.2 が「要求を書かない」側に倒す）。違反は §6.1 の修復を先に試す | CONFIG_LOCK_MISMATCH | V-30 |
| CV-32 | `TimeZone(identifier: timeZone) != nil` | CONFIG_INVALID_VALUE | V-32 |
| CV-33 | `!(cleanup.deleteSourceAudio == true && device.mountMode == "ro")` | CONFIG_LOCK_MISMATCH | V-33 |
| CV-39 | JSON として読め、全階層で必要なキーがすべて在り、型が合う（`schemaVersion` が 1 であることを含む） | CONFIG_INVALID_VALUE | voicedock の規則 ID `-` |
| CV-40 | `vault.path` が null か、`/` で始まる絶対パスの文字列（**存在は検査しない**。未接続の外付けは実行時のガード。§8.7） | CONFIG_INVALID_VALUE | 新規 |
| CV-41 | `vault.marker` が空でなく、`/` を含まず、`.` でも `..` でもない | CONFIG_INVALID_VALUE | 新規（X-18） |
| CV-42 | `llm.modelID` が null か、カタログの LLM の ID か、`custom:<64 桁の小文字 16 進>` | CONFIG_INVALID_VALUE | 新規 |
| CV-43 | `cleanup.deleteSkippedSource == true` なら `cleanup.deleteSourceAudio == true` | CONFIG_INVALID_VALUE | 新規 |
| CV-44 | `transcription.whisperModelID` がカタログの whisper の ID（**ファイルの有無は検査しない**。未入手は実行時のガード） | CONFIG_INVALID_VALUE | 新規 |
| CV-45 | `transcription.vad.enabled` なら `vad.modelID` がカタログの vad の ID（同上） | CONFIG_INVALID_VALUE | 新規 |
| CV-46 | `device.snapshotMaxAgeSeconds > device.scanIntervalSeconds` | CONFIG_INVALID_VALUE | 新規（DH-17 相当） |
| CV-47 | `device.includeVolumes` と `excludeVolumes` の各要素が空文字でない | CONFIG_INVALID_VALUE | helper.conf 検査 4 |
| CV-48 | `device.mountMode` が `ro` か `rw` | CONFIG_INVALID_VALUE | helper.conf 検査 5 |
| CV-49 | `device.stabilityFastPathSeconds >= 1`、`stabilityIntervalSeconds >= 1`、`stabilityChecks >= 1`、`maxScanDepth >= 1` | CONFIG_INVALID_VALUE | helper.conf 検査 7 |
| CV-50 | `device.scanIntervalSeconds >= 60` | CONFIG_INVALID_VALUE | 新規 |
| CV-51 | `llm.contextSize >= llm.maxCharsPerRequest + llm.maxOutputTokens + 2048`（20,000 文字のチャンクが収まらないと HTTP 400 を繰り返す） | CONFIG_INVALID_VALUE | 新規 |
| CV-52 | `cleanup.deleteEvaluationBackoffSeconds` が空でなく各要素 `>= 0`、`cleanup.deleteResultTimeoutSeconds >= 60` | CONFIG_INVALID_VALUE | 新規 |
| CV-53 | `retry.maxAttempts >= 1`、`retry.backoffSeconds` の各要素 `>= 0` | CONFIG_INVALID_VALUE | 新規 |
| CV-54 | `logging.level` が `DEBUG` / `INFO` / `WARNING` / `ERROR` のどれか | CONFIG_INVALID_VALUE | 新規 |
| CV-55 | transcription の数値: `threads >= 0`、`timeoutFactor > 0`、`1 <= minTimeoutSeconds <= maxTimeoutSeconds`、`minChars >= 1`、`0 < vad.threshold < 1`、vad の 3 つの ms `>= 0`、`language` が空でない | CONFIG_INVALID_VALUE | 新規 |
| CV-56 | llm の数値: `0 <= temperature <= 2`、`0 < topP <= 1`、`maxOutputTokens >= 1`、`requestTimeoutSeconds >= 1`、`maxSecondsPerRequest >= 1`、`chunkOverlapChars >= 0`、`repairAttempts >= 0`、各節（`maxItems` を持つ 5 つ）の `maxItems` は null か `>= 1` | CONFIG_INVALID_VALUE | 新規 |
| CV-57 | session の数値: `idleCloseSeconds >= 1`、`maxParts >= 1`、`maxDurationSeconds >= 1` | CONFIG_INVALID_VALUE | 新規 |
| CV-58 | audio の数値: `timeoutFactor > 0`、`minTimeoutSeconds >= 1`、`durationToleranceSeconds >= 0`、`freeSpaceMultiplier >= 1`、`freeSpaceMarginBytes >= 0`、`hashChunkBytes >= 4096` | CONFIG_INVALID_VALUE | 新規 |
| CV-59 | obsidian の数値: `raw.timestampIntervalSeconds >= 0`（0 は「見出しを入れない」。voicedock と同じ）、`wiki.vaultIndexCacheSeconds >= 0`、`wiki.maxLinks >= 0`、`defaultTags` の各要素が空でない | CONFIG_INVALID_VALUE | 新規 |

- 各 CV にテストを 1 本以上（違反の例で落ちる・境界値で通る）。テストの表示名は `CV-nn` で始める（§10.3 の SPEC 同期が SPEC の表とテストを結ぶ）

## S6. 診断 DR（PLAN §8.11）

| ID | 順 | 検査 | fail / notice | 致命 |
|---|---|---|---|---|
| DR-01 | 1 | 設定が CV をすべて満たす（違反を 1 件 1 行で出す） | fail | ○ |
| DR-16 | 2 | タイムゾーンが解決できる | fail | ○ |
| DR-02 | 3 | DB: ファイルが在れば読み取り専用で開き `PRAGMA quick_check` が `ok`、適用済みマイグレーションが最新。無ければ notice「まだ作られていません」（作らない） | fail | ○ |
| DR-13 | 4 | voicedock の Helper の LaunchAgent が登録されていない（`launchctl print` が 0 以外） | fail |  |
| DR-03 | 5 | `<HOME>` の空き容量: `SpaceCheck`（設定値を使う）を duration 1800 秒で呼んで `.ok` | notice |  |
| DR-04 | 6 | whisper-cli が在り、`--help` に VAD の 6 フラグが逐語で在る（VAD 無効なら無くても notice） | fail |  |
| DR-05 | 7 | Whisper モデルが在り SHA-256 が一致 | fail |  |
| DR-06 | 8 | VAD モデルが在り SHA-256 が一致。VAD 無効なら notice「無音から幻覚が生成され、13 倍以上遅くなります」（ASR-02） | fail / notice |  |
| DR-07 | 9 | llama-server が在り、使うフラグがすべて `--help` に在る | fail |  |
| DR-08 | 10 | LLM モデルが選ばれて在り SHA-256 が一致（custom は ID の SHA と一致するかだけ）、メモリが足りる（custom はメモリの目安が無いので `.ok` とし、詳細に「動作保証外のモデルです」と出す） | fail |  |
| DR-10 | 11 | Vault: `VaultCheck` が `.available`（`.notReadable(EPERM)` は許可の案内）かつ `access(W_OK)`。**ファイルもフォルダも作らない**（NOTE-16）。「書けない」と「Vault でない」を別の文言で出す | fail |  |
| DR-11 | 12 | 接続中のデバイスを列挙できる（snapshot の `unavailable` に `not_listable` が無い）。不可なら「システム設定 → プライバシーとセキュリティ → ファイルとフォルダ → VoiceDock → リムーバブルボリューム」を案内。**デバイス未接続なら skip** | fail |  |
| DR-12 | 13 | ログイン項目の状態（`SMAppService.mainApp.status`）。`.enabled` 以外は notice | notice |  |
| DR-15 | 14 | inbox の取り残し（`inboxLeftoverStates` の Part の inbox ファイルが残っている）。件数と合計サイズ。**自動では消さない** | notice |  |
| DR-17 | 15 | アプリ自身の署名が有効で ad-hoc でない（Team ID を持つ）。ad-hoc なら「ビルドのたびにリムーバブルボリュームの許可が失効します」（voicedock DH-16 相当） | notice |  |
| DR-14 | 16 | 三重ロックを個別に表示（§8.9.8 の表示。`LockEvaluator` を使い、式を書き直さない）。常に notice | notice | （必ず最後） |
| DR-09 | 別 | LLM に実リクエスト（別のボタン。Worker の直列ループに 1 件の仕事として入れ、`LlamaServerSupervisor` の単一インスタンスを使う。数十秒かかる）。結果「<model>（<秒 小数 1 桁>s）」 | fail |  |

## S7. 削除禁止テスト ND（PLAN 付録 B.1）

番号は voicedock を**そのまま引き継ぐ**（再割当てしない。ND-10〜17 は voicedock v5.37 で廃止済み、ND-30 は Docker 固有のため欠番。再利用しない）。ND-36 以降は本計画で新設。
層（§10.5）: A = アプリ（NoDeleteTests）、R1 = reaper 実行ファイル × 普通のディレクトリ、R2 = `TargetIdentity` の単体（FakeVolume）、R3 = reaper 実行ファイル × FAT32 ディスクイメージ（`.diskImage`）。
層を複数書いたものは**層ごとに 1 本ずつ**テストを置く（片方の層を消しても別の層が受け止めて緑になるのを防ぐ。TEST-17）。

| # | 故障 | 期待 | 層 |
|---|---|---|---|
| ND-01 | 変換中に I/O エラー | 元音声が残る。部分出力が消える | A |
| ND-02 | 変換結果の長さが 1 秒を超えてずれる | 残る（NORMALIZE_VERIFY_FAILED） | A |
| ND-03 | 内容が同一の重複、`deleteSkippedSource = false` | 残る | A |
| ND-04 | whisper が終了コード ≠ 0 | 残る | A |
| ND-05 | whisper タイムアウト | 残る。プロセス（孫も）が残らない | A |
| ND-06 | 発話なし、`deleteSkippedSource = false` | 残る | A |
| ND-07 | Raw ノートの書き込み失敗 | 残る | A |
| ND-08 | Raw ノートを保存後に外部から削除 / 改変 | 残る（RN を実ファイルで再実行） | A |
| ND-09 | Raw ノートの鍵に当該 Part が無い | 残る | A |
| ND-18 | 削除直前にサイズが変わる | `size_mismatch` | R2・R3 |
| ND-19 | 削除直前に mtime が変わる | `mtime_mismatch` | R2・R3 |
| ND-20 | 対象自身か経路の途中に symlink | 他の場所に触れない（`target_is_symlink` / `path_contains_symlink`） | R2・R3 |
| ND-21 | Part 0 件の Session / `source_path` が nil か空 | 要求を書かない | A |
| ND-22 | ロック 1 の片方だけ false（アプリ側 / reaper.conf 側をそれぞれ） | 要求しない / `reaper_disabled reason=lock1`（要求に触らない） | A・R1 |
| ND-23 | デバイスが読み取り専用（観測） | 要求しない / RV-07 で残す | A・R3 |
| ND-24 | relpath に `../` | `relpath_unsafe` | R2・R3 |
| ND-25 | symlink 経由でボリューム外 | `path_contains_symlink` | R2・R3 |
| ND-26 | `bin/voicedock-reaper` が無い（ロック 2-A） | 要求を書かず、何も消えない（voicedock では「要求はキューに残りタイムアウト」だった。意味を変えた） | A |
| ND-27 | 同じ request_id を 2 回 | 2 回目は `replayed` | R1 |
| ND-28 | `.Trashes/...` などの `.` 始まり | `relpath_unsafe` | R2・R3 |
| ND-29 | 親フォルダ名が規則外（ボリューム直下のファイルを含む） | `folder_rule` | R2・R3 |
| ~~ND-30~~ | ~~欠番: voicedock の「コンテナから state/ を改ざん」は Docker 固有のため廃止~~ | — | — |
| ND-31 | device_id だけが違う同名ファイル | 別デバイスの録音を消さない | A・R3 |
| ND-32 | Part の transcript が無いか壊れている | 残る | A |
| ND-33 | `SOURCE_MISSING` の SKIPPED | 残る | A |
| ND-34 | 無音だが whisper 出力の JSON が無いか壊れている | 残る | A |
| ND-35 | 重複だが双子の本文が Vault で確認できない | 残る | A |
| ND-36 | Vault の `.obsidian` が無い（空の Vault） | ノートを書かず、要求も書かない | A |
| ND-37 | denoised（`_orig` 無し）のファイルを指す要求 | `filename_rule` | R2・R3 |
| ND-38 | request_id やファイル名に `/` や `..` を含む | `rejected/` へ移し、結果ファイルを外へ書かない | R1 |
| ND-39 | `<VOLUMES_ROOT>/<device_id>` がマウント点でない（ただのディレクトリ）/ FS が msdos でない（HFS+ のイメージ） | `not_a_mount_point` / `unexpected_fs` | R1・R3 |
| ND-40 | バンドル内の reaper（`<HOME>/bin/` 以外の場所）を直接起動 | 終了コード 3、何も消えない、何も書かない（RV-00） | R1 |
| ND-41 | reaper の署名が不正 / 版が違う | アプリが起動しない | A |
| ND-42 | 古い試行の DELETED 結果（request_id 不一致） | 捨てる。消えていないものを消えたと判定しない | A |
| ND-43 | reaper.conf に未知のキー・重複・不正値・必須の欠落 | 無効側（終了コード 2、`reaper_disabled reason=conf_invalid`、要求に触らない） | R1 |
| ND-44 | 要求の device_id / relpath と partkey が食い違う | `partkey_mismatch` | R1 |
| ND-45 | reaper.conf が無い・読めない（ロック 1 の片方が不明） | 要求を書かない（不明は安全側） | A |
| ND-46 | DELETED の結果に対して、reaper の後の走査がまだ無い（`generation < reaperScanGeneration`）か、デバイスが snapshot に無い | 完了にしない（結果を残して観測を待つ） | A |
| ND-47 | デバイスが接続中で `readOnly == nil`（観測できない） | 要求を書かない | A |

**正の対照**（必須）: A `deletionActuallyHappensWhenEverythingIsValid`（要求ファイルが書かれ `RAW_SAVED→SOURCE_DELETING` が記録される）、R3 `aValidRequestActuallyDeletes`（本物の FAT で実際に消える）。
R1 と R2 にもそれぞれ「同じ準備で故障を入れなければ次の段へ進む」ことを確かめる対照を置く（R1: RV-06 まで進んで `not_a_mount_point` になる、R2: `withVerifiedTarget` の body が呼ばれる）。

## S8. reaper の検証 RV（PLAN 付録 B.2）

| # | 検証 | 理由語 | 要求の扱い | voicedock の検証 |
|---|---|---|---|---|
| RV-00 | 自分の置き場所が `<HOME>/bin/voicedock-reaper`（通常ファイル、`.app/Contents/` を含まない） | （終了コード 3） | 触らない | （無し） |
| RV-01 | reaper.conf が正しく読め `DELETE_SOURCE_AUDIO=true` | `lock1`（false）/ `conf_invalid`（不正。終了コード 2） | 触らない | 1 |
| RV-02 | ファイル名が `<request_id>.json` の形（02a）、JSON の request_id がファイル名と一致（02b） | `malformed_request_id` | `rejected/` へ | （無し。d419397 で後から追加） |
| RV-03 | JSON の形（キー集合・型・targets がちょうど 1） | `malformed_request` | 拒否 | （無し） |
| RV-04 | リプレイでない | `replayed` | 拒否 | 11 |
| RV-05 | partkey と一致 | `partkey_mismatch` | 拒否 | 12 |
| RV-06 | `DeviceID.isValid`・symlink でない・マウント点・FS 種別 `msdos` | `device_absent` / `not_a_mount_point` / `unexpected_fs` | absent は残す、他は拒否 | 3（ディレクトリの有無だけだった） |
| RV-07 | 読み取り専用でない（観測） | `mount_readonly` | 残す | 2（観測値側が BSD sed で素通り） |
| RV-08 | relpath の健全性 | `relpath_unsafe` | 拒否 | 4・9 |
| RV-09 | openat 連鎖 | `path_contains_symlink` / `target_missing` | 拒否 | 5（realpath 比較） |
| RV-10 | symlink でない通常ファイル | `target_is_symlink` / `not_regular_file` | 拒否 | 6 |
| RV-11 | ファイル名（`_orig` 必須）・親フォルダ名 | `filename_rule` / `folder_rule` | 拒否 | 7・8（denoised も通していた） |
| RV-12 | size 一致・mtime 差 < 2.0 | `size_mismatch` / `mtime_mismatch` | 拒否 | 10（整数秒の差 ≥ 2 で不一致） |
| RV-13 | unlink と不在確認 | `unlink_failed` / `still_present` | 拒否 | （番号なし） |

「拒否」= processed.log に追記 → 結果 `SOURCE_IDENTITY_MISMATCH` → 要求を消す。「残す」= 何も書かず次回に回す（アプリ側の期限切れで取り下げられる）。
旧 reaper の理由語 `realpath_failed` / `outside_volume` / `stat_failed` は openat 連鎖では出ない。

## S9. 実機試験 E2E（PLAN 付録 B.3）

判定は `✅ PASS` / `✗ FAIL` / `⬜ 未実施` / `— 対象外` のどれかで始める（空欄・散文にしない。`✗` は **U+2717**。`❌` や `×` と混ぜない。機械検査が落ちる）。1 件でも FAIL なら修正チケットを起票し、次の Phase へ進まない。

| # | 内容 | 削除 |
|---|---|---|
| E2E-01 | 1 本を通しで（接続 → Raw / Daily）。単一チャンクでも Timeline が出る | OFF |
| E2E-02 | **コピー中に抜く**（危険な窓はコピー中。数本の長い録音でコピーに数分かかる状態で、開始 30 秒後に抜く）→ `.partial` が消え、再接続で再コピー、**デバイスの全ファイルのサイズと mtime が 1 バイトも変わらない**（前後の一覧を貼る） | OFF |
| E2E-03 | 文字起こし中に抜く（数分の録音で。処理はコピーから続き、削除 OFF なら COMPLETED） | OFF |
| E2E-04 | Vault を利用不可にする（外付けを外す / `.obsidian` を一時的に改名）→ 何も書かず（ガードで待つ）、要対応に出て、元音声が残り、戻すと**再起動なしで**再開 | OFF |
| E2E-05 | 抜き挿し 6 回以上で二重処理しない（前後の件数表） | OFF |
| E2E-06 | 1 日分（16 時間・約 32 本）が 1 セッションにまとまり、**次の接続（24 時間）までに処理が終わる**（運用で確認してよい） | OFF |
| E2E-07 | 無音の Part があっても止まらない（警告行が「無音」、⚠ が付かない） | OFF |
| E2E-08 | 1 本だけ文字起こしを失敗させる: その Part が NORMALIZED になった直後に `staging/<slug>/audio16k.wav` を壊れたデータで上書き → WHISPER_FAILED、他は進み、Daily に警告行。その後 16 kHz 音声を消して再接続 → NORMALIZED_MISSING → 再コピー → 再評価で完走する | OFF |
| E2E-09 | 保存後に同じ日の Part を追加 → 再オープンで作り直す（ファイルが増えない） | OFF |
| E2E-10 | 削除 ON で通し（Raw の検証を通った分だけ元音声が消え、空き容量が戻る。無音は根拠 B を有効にしない限り残る） | ON |
| E2E-11 | 過去分の削除・手動で消した分の完了（削除 OFF の期間の Part も Raw の検証を経ているので**対象は 0 件にならない**。voicedock の「`--backlog` は 0 件が正しい」は当時 Raw 検証を経ていなかったため。対象外は理由を表示） | ON |
| E2E-12 | 文字起こし中にアプリを強制終了（`kill -9`）→ 再起動で途中から再開し、**二重処理しない**（前後の件数表） | OFF |
| E2E-13 | 処理中にスリープ → 復帰後に続行（処理中はアイドルスリープしない） | OFF |
| E2E-14 | アプリが動いていない間に接続 → 起動後に取り込む | OFF |
| E2E-15 | voicedock の Helper の LaunchAgent が登録されている → 取り込まない（共存ガード・DR-13） | OFF |
| E2E-16 | リムーバブルボリュームの許可を拒否 → パネルに案内が出る。許可後に取り込む | OFF |
| E2E-17 | 削除を無効化（確認なし）→ 直ちに読み取り専用へ再マウントされ、以後削除されない | ON→OFF |
| E2E-18 | voicedock からの乗り換え: voicedock が書いた Raw / Daily がある Vault を選ぶ → `imported_keys` に入った録音はコピーされず、同じ日の新しい録音は ` (2)` のノートに書かれ、voicedock のノートは 1 バイトも変わらない | OFF |
