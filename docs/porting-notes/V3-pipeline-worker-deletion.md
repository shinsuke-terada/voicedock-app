# V3 移植メモ: Worker・Part/Session 工程・分組・削除フロー（アプリ側）

出典はすべて voicedock `d3d595e`。`file:line` はそのコミットの行番号。
Python を読まずに挙動を再現できる粒度で書く。**[差分候補]** は本計画（Swift 版）で直すべき／決めるべき点。

---

## 0. 全体像（voicedock の実装上の呼び出し関係）

```text
Worker.start()                                  worker.py:104-115
  log INFO service_started version=<__version__> schema_version=<n>
  pipeline.recover_interrupted()                pipeline.py:1669
  pipeline.close_stale_open_sessions()          pipeline.py:1720 → session.close_open_sessions
  Worker.requeue_failed(None, startup=True)     → pipeline.requeue_failed

Worker.tick()                                   worker.py:119-157
  inventory = device.read_inventory(state_root)
  helper_fresh = not heartbeat stale
  if helper_fresh: discover_parts()  (= discover.discover + session.group_parts)
  else: log WARNING helper_heartbeat_stale reason="取り込みを見送る"
  close_idle_sessions()                          session.close_open_sessions
  process_pending_parts()                        Pipeline.process_part × N（工程内リトライ付き）
  refresh_vault_index()                          wiki.index_for(cached=)
  process_ready_sessions()                       Pipeline.process_session × N（工程内リトライ付き）
  if helper_fresh:
      evaluate_deletions()                       Pipeline.delete_sources_if_safe × N
      settle_skipped_deletions()                 Pipeline.settle_skipped_deletions
      requeue_failed(inventory)                  立ち上がりエッジのときだけ pipeline.requeue_failed
  return helper_fresh

Worker.run(): stopper.install → start → while !stop { tick; if stop break; sleep(poll_interval_seconds) } → log INFO service_stopping version=
```

テスト `test_worker_loop.py:170-209` が tick の順序を
`[discover_parts, close_idle_sessions, process_pending_parts, process_ready_sessions, evaluate_deletions, settle_skipped_deletions, requeue_failed]`
で固定している（refresh_vault_index は spy していないが実装上は process_pending_parts と process_ready_sessions の間）。

**voicedock には `runReaper` / `collectDeleteResults` / `expire` という独立した段は無い。**
- reaper はホストの Helper が ingest の最後に起動する（helper/voicedock-ingest:875 付近 `run_reaper`）
- 結果の回収は `request_deletions()` の**先頭**（Part 契機・Session 契機の両方）と `settle_skipped_deletions()`（SKIPPED 用）の中で、対象セッションの Part / 待機中 SKIPPED に限って行う
- 期限切れは `collect_delete_results()` の末尾で、渡された Part 集合に対して行う

---

## 1. Worker の各段

### 1.1 立ち上がりエッジ（requeue の契機）worker.py:272-307

```python
last_inventory_empty: bool | None = None       # 起動直後は None（不明）
def should_requeue(inventory, startup=False):
    empty = inventory is None or not inventory.devices      # 読めない = 空
    rising_edge = (last_inventory_empty is not False) and not empty   # None も「前回空」扱い
    last_inventory_empty = empty
    return startup or rising_edge
```
- start() は `requeue_failed(None, startup=True)` を呼ぶ（このとき last_inventory_empty = True になる）
- helper_fresh が偽の周回では should_requeue を呼ばない（= last_inventory_empty を更新しない）
- 固定事例（test_worker_loop.py:334-455）:
  - startup=True → 真
  - last=True, devices 非空 → 真、last=False に
  - last=False, 非空 → 偽（2 周目も偽）
  - last=True, 空 → 偽
  - last=True, inventory=None → 偽、last=True のまま
  - 非空→空→非空 で 3 回目が真

### 1.2 process_pending_parts worker.py:223-270
- 一覧を**先に確定**: `SELECT partkey FROM recordings WHERE status NOT IN (<PART_TERMINAL 6 件>) ORDER BY started_at, partkey`（db.py:475-487）
- 各 partkey: 停止要求なら return → `_with_in_process_retry(process_part(key), RECORDING, key)`
- **Pipeline は 1 周に 1 個作る**（`_pipeline()`、worker.py:170-197）。`now` は本番では None（呼ばれた時点の時刻を使う）

### 1.3 工程内リトライ worker.py:240-262 / pipeline.py:1750-1832
```python
while True:
    run()
    delay = in_process_retry(db, entity, key)       # None なら終わり
    if delay is None or stop: return
    sleep(delay)
    if stop: return
    if not resume_failed(db, entity, key, reset_retry=False): return
```
`in_process_retry` が None を返す条件（pipeline.py:1763-1796）:
1. 行が無い
2. status != "FAILED"
3. error_code が None、または ErrorCode として未知、または retry 区分が ATTEMPTS でない
4. `failed_from` が None、または RETRYABLE 集合外
5. `retry_delay(retry_count)` が None: `retry_count < 1 or retry_count >= max_attempts`

`retry_delay(attempt) = backoff_seconds[attempt - 1]`（pipeline.py:1750-1760）。
既定 max=3, backoff=[3,10,30] → 失敗(rc=1)→3 秒→失敗(rc=2)→10 秒→失敗(rc=3)→終了。30 は使われない。
固定事例: test_worker_loop.py:651-674 `len(calls)==3`, `slept==[3.0,10.0]`。ATTEMPTS 外のコードは 1 回で終わり slept==[]（:676）。
停止要求が 1 回目の run の後に立てば sleep しない（:697）。

`resume_failed(reset_retry)`（pipeline.py:1799-1832）:
- target = `_resume_target` = `failed_from(entity,key)` が RETRYABLE 集合（Part {NORMALIZING, TRANSCRIBING, RAW_WRITING} / Session {MERGING, ANALYZING, WRITING}）に在ればそれ
- `record_transition(FAILED → target, detail = "requeue" if reset_retry else "retry", reset_retry=reset_retry)`
- TransitionConflict は握って False

`failed_from`（db.py:489-502）:
```sql
SELECT from_status FROM events
WHERE entity_type = ? AND entity_key = ? AND to_status = 'FAILED'
ORDER BY id DESC LIMIT 1
```

### 1.4 requeue_failed pipeline.py:1835-1852
```python
for entity in (RECORDING, SESSION):
    for key, _, _ in db.rows_with_status(entity, "FAILED"):   # ORDER BY updated_at, <key>
        if resume_failed(..., reset_retry=True): moved += 1
if moved: log INFO recovery_completed requeued=<moved>
```
`rows_with_status`: `SELECT <key> AS key, retry_count, error_code FROM <table> WHERE status = ? ORDER BY updated_at, <key>`（db.py:504-517）。
**時間・retry_count・error_code を見ない。上限なし。**

### 1.5 process_ready_sessions / ready_session_keys worker.py:326-340, 391-412
```python
ready = []
for status in sorted(PROCESSABLE):                       # 6 状態
    for row in sessions_with_status(status):             # ORDER BY session_key
        parts = recordings_for_session(row.session_key)  # ORDER BY started_at, partkey
        if parts and all(p.status in PART_TERMINAL for p in parts):
            ready.append(row.session_key)
return sorted(ready)                                     # ★最終順序は session_key の昇順
```
PROCESSABLE = {READY, MERGING, MERGED, ANALYZING, ANALYZED, WRITING}（pipeline.py:160）。
**Part 0 件のセッションは ready にしない**（test_worker_loop.py:588）。

### 1.6 evaluate_deletions / deletable_session_keys worker.py:342-389
```python
for key, status, attempts, updated in db.sessions_for_delete_evaluation():   # 全セッション ORDER BY updated_at, session_key
    if status not in DELETE_EVALUATED: continue          # {SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING, CLEANUP}（COMPLETED を含めない）
    if (now - updated).total_seconds() < delete_evaluation_delay(attempts): continue
    found.append(key)
for key in found: (stop なら return) pipeline.delete_sources_if_safe(key)
```
`delete_evaluation_delay(attempts)`（pipeline.py:1855-1868）:
```python
backoff = cleanup.delete_evaluation_backoff_seconds    # [60,300,900,3600]
if not backoff: return 0.0
index = min(max(attempts, 1), len(backoff)) - 1          # ★attempts 0 と 1 はどちらも backoff[0]
return float(backoff[index])
```
固定事例（test_worker_loop.py:869-899）: (attempts=1, 30 秒前)→偽、(1,120)→真、(4,1800)→偽、(4,7200)→真。
`updated_at` が壊れていれば `datetime.min`（= すぐ評価）（db.py:640-645）。

### 1.7 refresh_vault_index worker.py:309-324
`wiki.index_for(cfg, vault_root, cached=self.vault_index)`。OSError は `log DEBUG obsidian_saved reason="vault_index: <exc>"` で握る。`link_tags: false` なら None。

---

## 2. 起動時の復旧 pipeline.py:1669-1728, states.py:271-293

```python
for part_status, target in PART_RECOVERY.items():          # 挿入順: NORMALIZING, TRANSCRIBING, RAW_WRITING, SOURCE_DELETING
    for rec in recordings_with_status(part_status):          # ORDER BY started_at, partkey
        _discard_partial(rec, part_status)
        record_transition(RECORDING, rec.partkey, part_status → target, detail="recovery")
for s_status, target in SESSION_RECOVERY.items():          # MERGING, ANALYZING, WRITING, SOURCE_DELETING, CLEANUP
    for row in sessions_with_status(s_status):
        record_transition(SESSION, key, s_status → target, detail="recovery")
if moved: log INFO recovery_completed rolled_back=<moved>
```
PART_RECOVERY: NORMALIZING→DISCOVERED, TRANSCRIBING→NORMALIZED, RAW_WRITING→TRANSCRIBED, SOURCE_DELETING→SOURCE_DELETE_PENDING
SESSION_RECOVERY: MERGING→READY, ANALYZING→MERGED, WRITING→ANALYZED, SOURCE_DELETING→SOURCE_DELETE_PENDING, CLEANUP→SAVED

`_discard_partial`（:1706-1717）:
- NORMALIZING: `record.normalized_path` **列**が非 NULL ならそのファイル（★通常の初回変換中は列が NULL なので何も消さない。列が入っているのは `_renormalize_or_fail` で戻ってきた行だけ）
- TRANSCRIBING: `transcripts/parts/<slug>.json`（partkey から算出）
- 失敗は `log WARNING config_warning rule="§9.4" message="<path> を消せません: <exc>"`
- **RAW_WRITING / WRITING の Vault の tmp は消さない**（SPEC §9.4 は「*.tmp を削除してから」と書くが未実装）
- **SOURCE_DELETING → SOURCE_DELETE_PENDING で `delete_request_id` を外さない**（列はそのまま残る）

**★重要: voicedock の `record_transition` は遷移表を検査しない**（db.py:328「どの遷移が許されるかはここで検査しない」）。
復旧の 8 辺（NORMALIZING→DISCOVERED ほか。SOURCE_DELETING→SOURCE_DELETE_PENDING 以外の 7 辺）は **`PART_TRANSITIONS` / `SESSION_TRANSITIONS` に無い**。
表を強制する Swift 版では、この 7 辺を表に足すか、復旧専用の API（`PART_RECOVERY` の写像で検査）を別に持つ必要がある。

`close_stale_open_sessions` = `session.close_open_sessions` そのもの（§4.3）。

---

## 3. Part の工程 pipeline.py:266-547, 1537-1660

### 3.0 process_part（:266-282）
```python
rec = get_recording(key); if None: STOPPED
if not ensure_normalized_audio(rec): STOPPED
if not ensure_part_transcript(reload): STOPPED
if not ensure_raw_note(reload): STOPPED
rec = reload
if rec and rec.session_key: request_deletions(rec.session_key)   # ★その Part ではなく「セッションの全 Part」を評価
return READY_FOR_SESSION
```

### 3.1 状態集合（pipeline.py:70-160）
- NORMALIZED_OR_BEYOND = {NORMALIZED, TRANSCRIBING, TRANSCRIBED, RAW_WRITING, RAW_SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING, COMPLETED}
- TRANSCRIBED_OR_BEYOND = {TRANSCRIBED, RAW_WRITING, RAW_SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING, COMPLETED}
- RAW_SAVED_OR_BEYOND = {RAW_SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING, COMPLETED}
- NORMALIZABLE = {DISCOVERED, NORMALIZING} / TRANSCRIBABLE = {NORMALIZED, TRANSCRIBING} / RAW_WRITABLE = {TRANSCRIBED, RAW_WRITING}
- MERGEABLE = {READY, MERGING} / ANALYZABLE = {MERGED, ANALYZING} / WRITABLE = {ANALYZED, WRITING} / PROCESSABLE = 和集合
- REOPENABLE = {SAVED, COMPLETED}
- DELETE_EVALUATED = {SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING, CLEANUP}
- SAVED_OR_BEYOND = {SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING, CLEANUP, COMPLETED}
- ANALYZED_OR_BEYOND = {ANALYZED, WRITING} ∪ SAVED_OR_BEYOND
- MERGED_OR_BEYOND = {MERGED, ANALYZING} ∪ ANALYZED_OR_BEYOND
- SKIP_REASONS（log の reason）: SOURCE_MISSING→`source_missing`, DUPLICATE_CONTENT→`duplicate_content`, NO_SPEECH_DETECTED→`no_speech`

### 3.2 ensure_normalized_audio（:286-373）
```text
if status ∈ NORMALIZED_OR_BEYOND: return True
if status ∉ NORMALIZABLE: return False                       # FAILED/SKIPPED
src = inbox_path
if src is None or not (is_file and size > 0):
    _skip(rec, SOURCE_MISSING, "inbox に原本がありません: {src}")   # from = rec.status（DISCOVERED か NORMALIZING）
    return False
space = audio.check_space(duration)
if not space.ok:
    log WARNING disk_space_low recording_key=<pk> reason=<detail>; return False   # ★遷移しない（ガード）
if status == DISCOVERED: transition DISCOVERED→NORMALIZING         # NORMALIZING なら記録しない
claimed = recording_by_normalized_path(normalized_path_for(pk))     # SELECT * FROM recordings WHERE normalized_path = ?
result = audio.normalize(..., claimed_by=claimed.partkey?, duplicate_of=lambda sha: recording_by_sha256(sha)?.partkey)
if result.error_code == DUPLICATE_CONTENT:
    update_recording(duplicate_of=result.duplicate_of)              # ★遷移より先に列
    _skip(rec, DUPLICATE_CONTENT, result.error_message, from=NORMALIZING); return False
if result.error_code or result.path is None:
    _fail(pk, NORMALIZING, code or IMPORT_FAILED, msg, event="normalize_failed"); return False
update_recording(sha256, normalized_path, staging_dir, error_code=None, error_message=None)
transition NORMALIZING→NORMALIZED
log INFO normalize_completed recording_key in_bytes out_bytes elapsed_s=<round 1>
audio.release_inbox(src)                                            # ★DB 更新の後
return True
```
**[差分候補]** SOURCE_MISSING は `from = rec.status` なので NORMALIZING→SKIPPED も起きる（表に辺あり）。
FAILED(NORMALIZED_MISSING) を requeue すると FAILED→NORMALIZING → inbox 無し → **SKIPPED(SOURCE_MISSING) の終端に落ちる**（本計画の needs_recopy と衝突。報告参照）。

### 3.3 ensure_part_transcript（:388-463）
```text
if rec None: False; if status ∈ TRANSCRIBED_OR_BEYOND: True
if status ∉ TRANSCRIBABLE or normalized_path is None: False
if not usable(normalized_path): return _renormalize_or_fail(rec)
if status == NORMALIZED: transition NORMALIZED→TRANSCRIBING
result = transcribe.transcribe(...)
if NO_SPEECH_DETECTED:
    update_recording(transcript_path=transcripts/parts/<slug>.json)  # ★遷移より先
    _skip(rec, NO_SPEECH_DETECTED, msg, from=TRANSCRIBING); return False
if error or transcript None: _fail(pk, TRANSCRIBING, code or WHISPER_FAILED, msg, event="transcription_failed"); False
update_recording(transcript_path, error_code=None, error_message=None)
transition TRANSCRIBING→TRANSCRIBED
log INFO transcription_completed recording_key + transcribe.metrics(...)
if cleanup.delete_normalized_after_transcribe: _discard_staging(normalized_path)   # 失敗は log WARNING disk_space_low reason="staging を消せません: <exc>"
True
```
`_renormalize_or_fail`（:1623-1652）:
```text
transition rec.status→NORMALIZING                       # NORMALIZED か TRANSCRIBING から
if inbox_path usable: return False                        # 次の周回で作り直す。ログを出さない
_fail(pk, NORMALIZING, NORMALIZED_MISSING,
      "16 kHz 音声も inbox の原本もありません（{normalized_path}）。デバイスから採り直す必要があります",
      event="normalize_failed", reason="input")
return False
```

### 3.4 ensure_raw_note（:467-547）
```text
if rec None: False; if status ∈ RAW_SAVED_OR_BEYOND: True
if status ∉ RAW_WRITABLE or session_key None: False
parts = _raw_parts(session_key); if not parts: False
if status == TRANSCRIBED: transition TRANSCRIBED→RAW_WRITING
if not vault_available: _fail(pk, RAW_WRITING, OBSIDIAN_NOT_FOUND, _vault_detail(), event="raw_note_failed", reason="vault"); False
try raw.write_raw_note(parts, day, session_key, ...)
except OSError/ValueError: _fail(..., OBSIDIAN_RAW_WRITE_FAILED, "<ExcType>: <exc>", event="raw_note_failed", reason="write"); False
if not result.ok: _fail(..., OBSIDIAN_RAW_VERIFY_FAILED, "落ちた規則: R-1, R-5", event="raw_note_failed", reason="verify"); False
update_session(raw_output_path=<vault 相対>, raw_output_sha256=result.sha256)
transition RAW_WRITING→RAW_SAVED
log INFO raw_note_saved session_key parts=<len(parts)> bytes=<size>
reopen_session(session_key)
True
```
`_raw_parts`（:592-623）: `recordings_for_session` の各行で `status ∈ RAW_NOTE_MEMBERS` かつ `load_transcript` が読めるもの。segment は `at = started_at + seg.start` / `end_at = started_at + seg.end`（text は strip しない）。
`_vault_detail`: Vault ルートが無ければ `"<root> がありません"`、あれば `"<root> に <marker>/ がありません（Vault が未マウントか、別の場所を指しています）"`。

### 3.5 _skip / _fail / 再オープン（:1537-1605, :551-590）
- `_skip(rec, code, detail, from=None)`: `record_transition(from or rec.status → SKIPPED, error_code=code, error_message=detail)` → `log INFO part_skipped recording_key reason=<SKIP_REASONS>` → `_reopen_after_exclusion(pk)`
- `_fail(pk, from, code, detail, event, reason=None)`: `record_transition(from→FAILED, error_code, error_message)` → `log ERROR <event> recording_key error_code [reason]` → `_reopen_after_exclusion(pk)`
- `_reopen_after_exclusion`: その Part の session_key で `reopen_session`
- `reopen_session(key)`:
  ```text
  if not session.allow_reopen: False
  s = get_session(key); if s None or s.status ∉ {SAVED, COMPLETED}: False
  try record_transition(s.status→MERGING, detail="reopen") except TransitionConflict: False
  update_session(regenerated_count = s.regenerated_count + 1)
  log INFO session_reopened session_key regenerated_count=<n>
  True
  ```
  契機は RAW_SAVED（ensure_raw_note 末尾）と、Part の SKIPPED / FAILED（全工程）。**分組では再オープンしない**。対象は**その Part のセッション**（同じ日の別の `#2` セッションではない）。

---

## 4. 分組・閉じる・Block・統合 session.py

### 4.1 group_parts（:136-185）
```text
moment = now
for part in ungrouped_recordings():     # SELECT * FROM recordings WHERE session_key IS NULL ORDER BY started_at, partkey
    started = parse(part.started_at)
    key = _target_key(part, started)
    s = get_session(key)
    if s None: insert_session(OPEN 行: session_key=key, day_date=day_of_session(key) 'YYYY-MM-DD', device_id, status=OPEN, updated_at=moment)
               # insert は events に (from NULL → OPEN, detail NULL) を同一トランザクションで 1 行
               status = OPEN
    else: status = s.status
    _attach: UPDATE recordings SET session_key=?, updated_at=? WHERE partkey=?        # status は変えない
    _refresh(key)
    if status == OPEN: record_transition(OPEN→OPEN, detail=<partkey>)                  # 新規作成直後も書く
```
`_target_key`（:188-209）: `key = session_key_for(device_id, started, tz)`; ループ: `s=get_session(key)`; `s None or _has_room(s, part)` なら key、でなければ `next_overflow(key)`（`:YYYYMMDD` → `#2` → `#3`）。
`_has_room`: `part_count >= max_parts → False`; `(recorded_seconds or 0) + (duration or 0) <= max_duration_seconds`。
`_refresh`（:244-270）:
```sql
SELECT COUNT(*) AS parts, MIN(started_at) AS first_at, MAX(ended_at) AS last_at,
       SUM(duration_seconds) AS seconds,
       SUM(CASE WHEN status IN ('FAILED','SKIPPED') THEN 1 ELSE 0 END) AS excluded
FROM recordings WHERE session_key = ?;
UPDATE sessions SET part_count=?, started_at=?, ended_at=?, recorded_seconds=?, failed_part_count=?, updated_at=? WHERE session_key=?;
```
（MIN/MAX は ISO 文字列の比較。全行同じオフセットの前提。SUM は全 NULL なら NULL）

`session_key_for`（paths.py:169-220）: device_id 空・`:`・`/` を含む・`.` 始まり → ValueError。`started.astimezone(tz).strftime("%Y%m%d")`。overflow 1 は接尾辞なし、≥2 は `#n`。

### 4.2 固定事例（test_session_group.py / test_session_reopen.py）
- 同じ日 → 1 セッション、日付違い / デバイス違い → 別
- 23:50 開始・日跨ぎ Part は開始日に属する（tz 変換後）
- 閉じたセッションへの追加は events を書かない（:273）
- max_parts を超えた分は `#2`、duration 上限でも割れる、duration NULL は 0、2 回目の分組は 1 本目の空きから埋める

### 4.3 close_open_sessions（:276-313）
```text
today = now.astimezone(tz).date(); idle_before = now - idle_close_seconds
for s in sessions_with_status(OPEN):                # ORDER BY session_key
    stale_day = date(s.day_date) != today
    idle = parse(s.updated_at) <= idle_before
    if stale_day or idle: record_transition(OPEN→READY, detail = "stale_day" if stale_day else "idle")
```

### 4.4 compute_blocks（:329-367）
- 入力: 統合対象 Part（FAILED/SKIPPED を除く。**transcript が読めない Part も含む**）
- `sorted(key=(started_at, ended_at or ""))`（文字列）
- 最初: `start=began; end = finished or began; unknown_end = finished is None`
- 以降: `gap = began - end`; `unknown_end or gap > gap_seconds` → 区切る（新 block 開始）。そうでなければ `unknown_end = finished is None; end = max(end, finished or began)`
- 固定事例: ちょうど閾値は区切らない、1 秒超で区切る、重なりは 1 つ、内包 Part で短くしない、ended_at NULL は必ず区切りその start を block の end に、gap 0 で連続を 1 つ

### 4.5 build_session_transcript（:373-423）
- valid = status ∉ {FAILED, SKIPPED}; excluded = その逆
- valid を `(started_at, partkey)` 順に load。None は飛ばす
- 各 segment: `text = seg.text.strip()`、空なら捨てる、`at = started + seg.start`、`end_at = started + seg.end`
- segments 0 件 → None（= session_empty）
- `segments.sort(key=(at, end_at))`（安定ソート）
- blocks = compute_blocks(valid, gap_seconds)

### 4.6 transcript_fingerprint（:60-93）
```python
json.dumps({"segments":[{"at": at.isoformat(timespec="seconds"), "end_at": ..., "text": text}],
            "blocks": [[start.isoformat(timespec="seconds"), end.isoformat(timespec="seconds")]]},
           ensure_ascii=False, sort_keys=True, separators=(",", ":"))
sha256(utf-8).hexdigest()
```
- `isoformat(timespec="seconds")` は**秒未満を切り捨て**、オフセット付き（`2026-08-29T07:12:04+09:00`）
- excluded は混ぜない。プロンプト・設定も混ぜない
- `.source.json`（pipeline.py:1451-1468）: `{"schema": 1, "transcript_sha256": "<hex>", "segments": <件数>, "blocks": <件数>}` を indent=2・ensure_ascii=False・末尾改行（**atomic でない write_text**）

---

## 5. Session の工程 pipeline.py:637-1334

### 5.1 process_session（:637-666）
```text
row = get_session; None → STOPPED
if row.status ∈ SAVED_OR_BEYOND: delete_sources_if_safe(key); return SAVED
transcript = build_transcript(key)
if not ensure_merged(row, transcript): return EMPTY if 今 COMPLETED else STOPPED
if not ensure_analysis(key, transcript): STOPPED
if not ensure_daily_note(key, transcript): ANALYZED
delete_sources_if_safe(key)            # ★SAVED 直後に backoff を見ずに 1 回評価（削除無効ならここで CLEANUP→COMPLETED まで進む）
return SAVED
```

### 5.2 ensure_merged（:1103-1138）
```text
if status ∈ MERGED_OR_BEYOND: True ; if status ∉ MERGEABLE: False
excluded = parts with status ∈ {FAILED, SKIPPED}
if status == READY: READY→MERGING
if transcript is None: MERGING→COMPLETED; log INFO session_empty session_key parts=<len(parts)>; return False
update_session(failed_part_count=len(excluded))
MERGING→MERGED; log INFO session_merged session_key parts=<len-excluded> excluded=<n> chars=<Σlen(text)>
True
```
（MERGING→FAILED / SESSION_MERGE_FAILED はここでは使われない。SESSION_MERGE_FAILED は llm.py:841 でチャンク 0 件のとき ANALYZING→FAILED）

### 5.3 ensure_analysis（:1140-1227）
```text
row; if status ∈ ANALYZED_OR_BEYOND: True          # ★ANALYZED / WRITING でも指紋を見ない（潜在バグ）
if status ∉ ANALYZABLE: False
if _analysis_matches(key, transcript):
    record_transition(row.status → ANALYZED)       # ★row.status が MERGED なら MERGED→ANALYZED（遷移表に無い辺）
    True
if status == MERGED: MERGED→ANALYZING
result = llm.analyze_session(transcript)
if not ok: _fail_session(key, ANALYZING, code or LLM_FAILED, msg)  # event llm_failed
if result.trimmed: log INFO analysis_trimmed session_key fields="; ".join(trimmed)
write analysis/<slug>.json（indent 2, ensure_ascii False, 末尾改行）
daily.save_timeline(...)                           # .timeline.json
_write_fingerprint                                 # .source.json（★最後）
  OSError → _fail_session(ANALYZING, LLM_FAILED, "<ExcType>: <exc>")
update_session(analysis_path, title, error_code=None, error_message=None)
ANALYZING→ANALYZED; log INFO llm_completed session_key chunks elapsed_s
```
`_analysis_matches`: analysis JSON が読めて `build_schema(cfg)` 検証を通り、`.source.json` の `transcript_sha256` が現在の指紋と一致。
テスト `test_session_resume.py:309-323` が **MERGED→ANALYZED の遷移が events に在ること**を固定している。

### 5.4 ensure_daily_note（:1229-1334）
```text
if status ∈ SAVED_OR_BEYOND: True
if status ∉ WRITABLE or analysis_path None: False
analysis = _load_analysis; None → _fail_session(key, row.status, OBSIDIAN_WRITE_FAILED, "解析結果を読めません: {analysis_path}", event="obsidian_failed", reason="write")
     # ★row.status が ANALYZED なら ANALYZED→FAILED（遷移表に無い辺）
included/excluded（FAILED/SKIPPED）
if status == ANALYZED: ANALYZED→WRITING
content = _render_daily(...)
if not vault_available: _fail_session(WRITING, OBSIDIAN_NOT_FOUND, detail, event obsidian_failed, reason vault)
write_daily_note: OSError/ValueError → OBSIDIAN_WRITE_FAILED "<ExcType>: <exc>" reason write; not ok → OBSIDIAN_VERIFY_FAILED "落ちた規則: ..." reason verify
update_session(output_path, output_sha256, error_code=None, error_message=None)
WRITING→SAVED; log INFO obsidian_saved session_key path bytes
```
`_fail_session`: `record_transition(from→FAILED, error_code, error_message=detail)` → `log ERROR <event> session_key error_code [reason] [detail]`（Part の `_fail` と違い detail もログに出す）。

---

## 6. 削除（アプリ側）pipeline.py:670-1092, cleaner.py

### 6.1 can_delete_source（cleaner.py:101-260）— 式の形
```python
_deletion_is_identified(part, session, parts, cfg, inventory) and (
    _text_is_preserved(part, session, parts, vault_root) or _nothing_to_preserve(part, cfg, twin, vault_root))

_deletion_is_identified =
    cfg.cleanup.delete_source_audio is True
    and device_is_writable(inventory) is True           # inventory.mount_readonly is False（None / 読めない は偽）
    and part.session_key == session.session_key
    and len(parts) >= 1
    and part.source_path is not None and part.source_path != ""
    and target_is_identical(part, inventory)

_text_is_preserved =
    session.raw_output_path is not None
    and verify_raw_note(session, parts, vault_root) is True
    and part.partkey in frontmatter_keys(vault_root / session.raw_output_path)
    and part.status in PART_DELETABLE
    and part.transcript_path is not None
    and part_transcript_is_valid(part)                  # load_transcript(partkey) is not None（列を見ない）

_nothing_to_preserve =
    cfg.cleanup.delete_skipped_source is True
    and part.status == SKIPPED
    and part.error_code in {DUPLICATE_CONTENT, NO_SPEECH_DETECTED}
    and _skip_reason_is_backed(part, twin, vault_root)

_skip_reason_is_backed:
    NO_SPEECH_DETECTED → part_transcript_is_valid(part)
    DUPLICATE_CONTENT  → part.duplicate_of is not None and twin is not None and twin.part.partkey == part.duplicate_of
                          and twin.part.partkey != part.partkey and twin.part.session_key == twin.session.session_key
                          and _text_is_preserved(twin.part, twin.session, twin.parts, vault_root)   # 双子には同定を要求しない
    その他 → False
```
`verify_raw_note(session, parts, vault_root)`（:285-315）:
- raw_output_path か raw_output_sha256 が None → 偽
- `notes.verify_note(path, kind=RAW, session_key, expected_sha=session.raw_output_sha256, expected_keys=[p.partkey for p in parts if p.transcript_path is not None and p.status in RAW_NOTE_MEMBERS])` が全合格

`target_is_identical(part, inventory)`（:351-385。**アプリ側の事前確認。実ファイルは見ない**）:
inventory None → 偽 / source_path 空 → 偽 / `is_safe_relpath` / `partkey_for(device_id, rel) == partkey` / `inventory.contains(device_id, rel)` / `source_size` と `source_mtime` が非 None。

### 6.2 request_part_deletion（:391-433）
```text
if not can_delete_source(...): None
if source_size or source_mtime is None: None
request = DeleteRequest(request_id=_request_id(partkey, now), created_at=now, device_id, partkey, session_key,
                        targets=(relpath=source_path, size=source_size, mtime=source_mtime))
write_request(request)          # ★ファイルが先
log INFO delete_requested request_id recording_key session_key
return request
```
`write_request`: `queue/delete/.<id>.json.tmp` に `json.dumps(indent=2, ensure_ascii=False) + "\n"` → flush → fsync → `replace` で `<id>.json`。
JSON: `{"schema":1,"request_id","created_at": isoformat(seconds),"device_id","partkey","session_key","targets":[{"relpath","size","mtime"}]}`
`_request_id`: `now.astimezone(tz=None).strftime("%Y%m%dT%H%M%S")`（★ローカル時刻で `Z` を付けない）`-<key_slug(partkey)>-<secrets.token_hex(3)>`

### 6.3 request_deletions（Part 契機・Session 契機の共通入口）pipeline.py:670-748
```text
row = get_session(key); None → 0
parts = recordings_for_session(key)
inventory = read_inventory()
just_pending = collect_delete_results(parts, inventory)     # ★先に回収（期限切れもこの中）
parts = recordings_for_session(key)                         # 読み直し
if not helper_fresh: return 0
if not cfg.cleanup.delete_source_audio: return 0
for part in parts:
    if part.status ∉ PART_DELETABLE: continue
    if part.status == SOURCE_DELETING: continue
    if part.partkey in just_pending: continue               # 同じ周回で保留へ落とした
    if part.status == COMPLETED: continue                   # 通常経路は COMPLETED を消しにいかない
    request = request_part_deletion(part, row, parts, cfg, inventory, now)
    if None: continue
    update_recording(delete_request_id=request.request_id)  # ★ファイルの後、遷移の前
    try: transition part.status → SOURCE_DELETING           # RAW_SAVED か SOURCE_DELETE_PENDING
    except TransitionConflict: continue
    requested += 1
return requested
```
★要求ファイルの書き込み失敗（OSError）は捕まえていない（DELETE_QUEUE_FAILED は未使用）。

### 6.4 delete_sources_if_safe（Session の後始末）pipeline.py:750-812
```text
row; if None or row.status ∉ DELETE_EVALUATED: False
requested = request_deletions(key)
row = reload; parts = recordings_for_session(key)
if not cfg.cleanup.delete_source_audio:
    log INFO source_delete_skipped session_key reason=delete_source_audio_disabled
    return _complete_without_deleting(row, parts)
if not device_is_writable(read_inventory()):               # mount_readonly が True か None
    log INFO source_delete_skipped session_key reason=device_readonly
    return _complete_without_deleting(row, parts)
if not any(p.status ∈ AWAITING_DELETION for p in parts):   # {RAW_SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING}
    return _complete_without_deleting(row, parts)          # ログなし（BG-3）
if requested == 0 and not any(p.status == SOURCE_DELETING):
    update_session(delete_attempts = row.delete_attempts + 1)   # 遷移しない・events を書かない。updated_at は更新される
    return False
if row.status != SOURCE_DELETING: transition row.status → SOURCE_DELETING   # SAVED / SOURCE_DELETE_PENDING（★CLEANUP なら表に無い辺）
return False
```
**Session が SOURCE_DELETE_PENDING に入る経路は復旧（SOURCE_DELETING→SOURCE_DELETE_PENDING）だけ**。通常運用で Session を PENDING にするコードは無い。

**★ロック 2-B の「不明」とデバイス未接続の区別（重要）**: Helper は **デバイス 0 台のとき `mount_readonly: false` を書く**（helper/voicedock-ingest:551, :860-864）。
したがって「未接続」は `device_is_writable == True` 扱いになり、`_complete_without_deleting` へは行かない。
要求は `target_is_identical`（inventory.contains）で偽 → `requested == 0` → `delete_attempts += 1` で**待つ**。
`_complete_without_deleting` へ行くのは「**接続中で ro を観測**」か「inventory の mount_readonly が壊れている/読めない」ときだけ（test_no_delete.py:1574-1597 が True と None の 2 通りを固定）。

`_complete_without_deleting(row, parts)`（:1075-1092）:
```text
for p in parts: if p.status == RAW_SAVED: RAW_SAVED→COMPLETED
if row.status ∈ CLEANUP_FROM({SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING}): row.status→CLEANUP
fresh = reload; if fresh.status != CLEANUP: return False
for p in parts: cleaner.cleanup_staging(p)      # STAGING_DISPOSABLE の Part の normalized_path だけ（ディレクトリも whisper.json も消さない）
CLEANUP→COMPLETED                               # ログなし
return True
```
★cleanup_staging の例外は捕まえていない（SPEC は「LOCAL_DELETE_FAILED、CLEANUP に留める」と書くが未実装）。

### 6.5 collect_delete_results（:921-1002）
```text
by_key = {p.partkey: p for p in parts}; pending = set()
for result in read_results():                    # queue/result/*.json を名前順。壊れた JSON・partkey/request_id 欠落は無視
    part = by_key.get(result.partkey)
    if part None: continue                        # 残す（別セッションかもしれない）
    if not awaits_delete_result(part): discard_result; continue      # delete_request_id が None か、status ∉ {SOURCE_DELETING, SKIPPED}
    if result.request_id != part.delete_request_id: discard_result; continue
    if result.deleted and inventory_is_newer(inventory, result) is False: continue   # ★結果を残して待つ（Swift 版では不要）
    if not result.deleted: _delete_pending(part, SOURCE_IDENTITY_MISMATCH, result.detail); pending.add
    elif not source_is_gone(part, inventory): _delete_pending(part, SOURCE_DELETE_FAILED, "still_in_inventory"); pending.add
    else:
        update_recording(source_deleted_at=now(seconds), delete_request_id=None)
        if part.status != SKIPPED: SOURCE_DELETING→COMPLETED
        log INFO source_deleted recording_key request_id
    discard_result
_expire_delete_requests(parts)                    # 渡された parts（snapshot）を鍵だけ使って読み直す
return pending
```
`source_is_gone`: inventory None → 偽。それ以外は `not inventory.contains(device_id, relpath)`（★デバイス未接続でも真になる）。
`inventory_is_newer`: `generated_at > completed_at`（同じ秒は偽）、どちらか None → None。

`_delete_pending(part, code, reason)`（:1040-1070）:
- SKIPPED: `update_recording(delete_request_id=None)` → `log WARNING source_delete_pending recording_key reason`（状態は動かさない）
- それ以外: `record_transition(SOURCE_DELETING→SOURCE_DELETE_PENDING, error_code=code, detail=reason)` → `update_recording(delete_request_id=None)` → 同じログ

### 6.6 _expire_delete_requests（:1004-1038）
```text
for stale in parts:
    part = get_recording(stale.partkey)                      # 読み直し
    if part None or not awaits_delete_result(part): continue
    if (now - part.updated_at) < delete_result_timeout_seconds: continue
    withdraw_request(partkey)      # queue/delete/*.json を全部読み partkey 一致を消す
    withdraw_result(partkey)       # queue/result/*.json も同様
    try _delete_pending(part, DELETE_TIMEOUT, "no_result") except TransitionConflict: continue
```
固定: test_no_delete.py:2263（読み直しと例外捕捉の 2 層）、:2312（結果も取り下げ）。

### 6.7 settle_skipped_deletions（根拠 B）pipeline.py:814-919
```text
if not cfg.cleanup.delete_skipped_source: 0
inventory = read_inventory(); None → 0
skipped = recordings_with_status(SKIPPED)                                   # ORDER BY started_at, partkey
awaiting = [p for p in skipped if awaits_delete_result(p)]
if awaiting: collect_delete_results(awaiting, inventory)                    # 期限切れもこの中
present = [p for p in skipped if not source_is_gone(p, inventory)]           # デバイスに実在するものだけ
for stale in present:
    part = reload; skip if None or session_key None
    skip if part.source_deleted_at or part.delete_request_id
    skip if (now - part.updated_at) < backoff[0]                             # ★先頭要素（最小値とは限らない）
    row = get_session(part.session_key); skip if None
    request = request_part_deletion(part, row, recordings_for_session(...), twin=_twin_of(part))
    if None: continue
    update_recording(delete_request_id=request.request_id)                  # 状態は動かさない
return requested
```
`_twin_of`: `duplicate_of` → get_recording → その session → TwinPart(part, session, parts)。どれか欠ければ None。

### 6.8 後追い backlog.py
- `plan_backlog`: **status == COMPLETED のセッション**（ORDER BY session_key）の各 Part で、`status == COMPLETED` のものだけ。`source_deleted_at` 非 NULL → skipped `already_deleted`、`can_delete_source` 真 → eligible、偽 → `not_deletable`
- `_request_deletions`: 各 eligible を読み直し、`request_part_deletion`（None なら飛ばす）→ `update_recording(delete_request_id)` → `COMPLETED→SOURCE_DELETING`（TransitionConflict → `log WARNING source_delete_skipped recording_key reason=status_changed`、continue）
- `plan_absent`: `recordings_with_status(SOURCE_DELETE_PENDING)` で inventory None → `no_inventory`、`source_is_gone` → eligible、それ以外 `still_present`
- `_mark_absent`: `PENDING→SOURCE_DELETING (detail resolve_absent)` → `SOURCE_DELETING→COMPLETED (detail already_absent)`（衝突は status_changed で continue）→ withdraw_request → withdraw_result → `delete_request_id=None` → `log INFO source_delete_skipped recording_key reason=already_absent`。**source_deleted_at を入れない**
- 終了コード: 全件成功で 0、1 件でも欠ければ EXIT_ERROR。dry-run と eligible 0 件は何も書かず 0
- ★**voicedock の欠陥**: backlog で SOURCE_DELETING にした Part は、セッションが COMPLETED（DELETE_EVALUATED 外）なので `request_deletions` にも `collect` にも `expire` にも**二度と拾われない**（回収するテストも無い）

---

## 7. ログイベント（この領域で使うもの）

| event | level | fields |
|---|---|---|
| service_started | INFO | version, schema_version |
| service_stopping | INFO | version |
| helper_heartbeat_stale | WARNING | reason（本計画で廃止） |
| recovery_completed | INFO | rolled_back=N（復旧）/ requeued=N（再評価） |
| config_warning | WARNING | rule="§9.4", message（部分出力を消せない） |
| part_skipped | INFO | recording_key, reason ∈ {source_missing, duplicate_content, no_speech} |
| normalize_completed | INFO | recording_key, in_bytes, out_bytes, elapsed_s |
| normalize_failed | ERROR | recording_key, error_code [, reason=input] |
| transcription_completed | INFO | recording_key + metrics |
| transcription_failed | ERROR | recording_key, error_code |
| raw_note_saved | INFO | session_key, parts, bytes |
| raw_note_failed | ERROR | recording_key, error_code, reason ∈ {vault, write, verify} |
| session_merged | INFO | session_key, parts, excluded, chars |
| session_empty | INFO | session_key, parts |
| session_reopened | INFO | session_key, regenerated_count |
| llm_completed | INFO | session_key, chunks, elapsed_s |
| llm_failed | ERROR | session_key, error_code, detail |
| analysis_trimmed | INFO | session_key, fields |
| obsidian_saved | INFO | session_key, path, bytes（DEBUG で vault_index / link 失敗にも流用） |
| obsidian_failed | ERROR | session_key, error_code, reason ∈ {vault, write, verify}, detail |
| delete_requested | INFO | request_id, recording_key, session_key |
| source_deleted | INFO | recording_key, request_id |
| source_delete_skipped | INFO/WARNING | session_key, reason ∈ {delete_source_audio_disabled, device_readonly} / recording_key, reason ∈ {status_changed, already_absent} |
| source_delete_pending | WARNING | recording_key, reason（理由語 / still_in_inventory / no_result） |
| disk_space_low | WARNING | recording_key, reason（ガード）/ reason="staging を消せません: …" |

---

## 8. DB の書き込み規則（この領域の前提）
- `record_transition`（db.py:304-367）: `UPDATE <t> SET status=?, retry_count=<expr>, error_code=?, error_message=truncate(?), updated_at=? WHERE <key>=? AND status=?`。rowcount≠1 → TransitionConflict。同じトランザクションで `INSERT INTO events (entity_type, entity_key, from_status, to_status, error_code, detail, created_at)`（detail も truncate）
  - retry_expr: `reset_retry or to ∈ {NORMALIZED, TRANSCRIBED, RAW_SAVED, MERGED, ANALYZED, SAVED}` → 0 / `to == FAILED` → +1 / それ以外据え置き
  - **error_code / error_message は無条件上書き**（渡さなければ NULL）
- `update_recording` / `update_session`: `status` を拒否、未知列を拒否、`error_message` を truncate、**updated_at を必ず更新**
- truncate: 200 文字以下はそのまま、超えたら先頭 199 + `…`
- insert: 行 INSERT と events(from NULL → 初期状態) を同一トランザクション

---

## 9. テストが固定している主な事例（Swift 版に写す候補）
- tick の順序（§0）。stale でも close/pending/ready は走る（test_worker_loop.py:212）
- 工程内リトライ: calls==3, slept==[3,10]; ATTEMPTS 外は 1 回; 停止要求で sleep しない
- requeue: rc を 0 に戻して FAILED→NORMALIZING（test_worker_loop.py:725）
- 削除評価の backoff 4 事例（§1.6）
- 待つ Part が無ければ完了: Part が COMPLETED / SKIPPED / FAILED の 3 通りでセッション COMPLETED、要求 0（test_no_delete.py:1463）
- RAW_SAVED で式が偽なら完了させない（:1480）
- PENDING→SOURCE_DELETING の再試行で要求が書かれる（:1499）、SOURCE_DELETING は二重要求しない（:1514）、COMPLETED は通常経路で要求しない（:1526）、1 件の衝突で残りを止めない（:1539）
- 読み取り専用（True / 不明）はセッションを COMPLETED、Part を COMPLETED、要求 0、ログ `reason=device_readonly`（:1574）。staging が解放される（:1600）。ロック 1 は `reason=delete_source_audio_disabled`（:1614）
- process_part が raw note の後に request_deletions を呼ぶ（:1627）、セッションの状態で門前払いしない（:1651）、SAVED 前でも回収する（:1668）
- 結果の回収 / 期限切れ（:2092-2320）: 成功→COMPLETED、inventory 不一致→PENDING、同定失敗→PENDING、別 Part の結果は残す、動いた Part の結果は捨てる、別セッションの結果は残す、古い試行は捨てる、reaper が要求を消した後でも回収できる、取り下げ済みは捨てる、期限切れで要求も結果も取り下げ、新しい要求は期限切れにしない、読み直しと例外捕捉
- 根拠 B: 無音は lock B で消える / 古い SKIPPED は待機扱いしない / 直近の試行は繰り返さない / SKIPPED のまま動かない / 無音は transcript_path を記録する / 無音で結果 DELETED → source_deleted_at を書き SKIPPED のまま（:2025）/ 拒否後すぐ再要求しない（:2054）/ 無回答は期限切れ（:2076）
- 解析: 指紋一致なら再実行しない、指紋無し・別 transcript・壊れた解析は再実行、再オープン後は再解析、新 Part が無ければ再解析しない
- session_resume: ANALYZING から再開、幽霊遷移を書かない、MERGED→ANALYZED を記録（★表に無い辺）、WRITING から再開して FAILED
