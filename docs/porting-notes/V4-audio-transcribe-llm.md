# V4 移植メモ: 16 kHz 変換・文字起こし・LLM 解析（voicedock@d3d595e）

出典はすべて `git -C /Users/terada/Projects/voicedock show d3d595e:<path>`。行番号は d3d595e のもの。
「実測」とある値は、voicedock@d3d595e を scratchpad に `git archive` で展開し、voicedock 自身の関数を
呼んで得た出力である（`scratchpad/gen_v4.py` / `gen_v4.out`）。**golden にそのまま使える。**

---

## 0. 固定値・版

| 項目 | 値 | 出典 |
|---|---|---|
| whisper.cpp | `v1.9.4`、commit `7d75b14994ae7f59623e2471445e2355fe506ed2`、clone 元 `https://github.com/ggml-org/whisper.cpp.git` | Dockerfile:9,15 / SPEC.md §10.6 の注記 |
| whisper ビルド（Docker CPU 版） | `-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16`、成果物 `build/bin/whisper-cli` | Dockerfile:19-26,37 |
| Whisper モデル | `ggml-large-v3-turbo-q5_0.bin`、取得元 `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-<MODEL>.bin`（**main を見ている**。本アプリはコミット SHA 固定に直す） | fetch-models.sh:22,25,87 |
| VAD モデル | `ggml-silero-v5.1.2.bin`、`https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin` | fetch-models.sh:23,28 |
| モデル名の検証 | `'' \| *[!A-Za-z0-9._-]* \| .* \| *..*` を拒否 | fetch-models.sh:44-50 |
| LLM | `ai/qwen3:30b-a3b-instruct-2507-q4_K_M`（約 18.6 GB）、`context_size: 32768` | compose.yaml:78-79 |
| RTF（実運用） | `rtf 1.04〜1.55`（16 時間の密な発話で約 15 時間）。POC の 0.434 は代表値でない | SPEC.md:5375（R-4） |
| LLM 性能基準 | 1 日分（約 350,000 文字 / 約 18 チャンク）を 30 分以内 | SPEC.md:5274（Phase 3） |

---

## 1. 16 kHz 変換（`audio.py` + `pipeline.ensure_normalized_audio`）

### 1.1 定数（audio.py / config.example.yaml）

| 名前 | 値 | 出典 |
|---|---|---|
| BYTES_PER_SECOND | 32000 | audio.py:212 |
| DEFAULT_DURATION_SECONDS | 1800.0 | audio.py:215 |
| NORMALIZED_FILENAME | `audio16k.wav` | audio.py:218 |
| 目標 | 16000 Hz / 1 ch / `s16`（pcm_s16le） | audio.py:219-221, config.example.yaml:25-27 |
| ffmpeg_timeout_factor / min | 0.5 / 180 | config.example.yaml:29-30 |
| duration_tolerance_seconds | 1.0 | config.example.yaml:31 |
| free_space_multiplier / margin | 2.0 / 2147483648 | config.example.yaml:38-39 |
| staging_max_bytes | 5368709120 | config.example.yaml:41 |
| hash_chunk_bytes | 1048576 | config.example.yaml:42 |
| inbox_retain | `normalized`（他に `raw_saved`） | config.example.yaml:46, config.py:191（V-29） |
| V-22 | `staging_max_bytes > free_space_margin_bytes` | config.py:193-201 |

### 1.2 呼び手の手順（pipeline.py:286-373 `ensure_normalized_audio`）

```text
if status ∈ NORMALIZED_OR_BEYOND → return true          # {NORMALIZED, TRANSCRIBING, TRANSCRIBED, RAW_WRITING, RAW_SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING, COMPLETED}（pipeline.py:71-82）
if status ∉ NORMALIZABLE={DISCOVERED, NORMALIZING} → return false   # FAILED/SKIPPED はここで進めない（pipeline.py:118）
source = record.inbox_path
if source == nil || !(isFile(source) && size(source) > 0):                                  # _usable_source（375-380）
    SKIPPED(SOURCE_MISSING, "inbox に原本がありません: {source}")  from record.status         # ★仕様 §8.3 に無い手順
    return false
space = check_space(duration)
if !space.ok: log.warning("disk_space_low", recording_key, reason=space.detail); return false   # ガード。遷移しない
if status == DISCOVERED: transition DISCOVERED→NORMALIZING                                   # NORMALIZING から来たら記録しない
claimed = db.recording_by_normalized_path(staging/<slug>/audio16k.wav)
result = normalize(source, partkey, duration, sha256_helper, claimed_by=claimed?.partkey, duplicate_of=db.recording_by_sha256)
if result.code == DUPLICATE_CONTENT:
    db.update(duplicate_of = result.duplicate_of)          # 列を先に書く（sha256 は書かない: UNIQUE）
    SKIPPED(DUPLICATE_CONTENT, "同じ内容の Part が既にあります: {other}") from NORMALIZING
    return false
if result.code != nil || result.path == nil:
    FAILED(result.code ?? IMPORT_FAILED, message) from NORMALIZING, event "normalize_failed"
    return false
db.update(sha256, normalized_path, staging_dir, error_code=NULL, error_message=NULL)
transition NORMALIZING→NORMALIZED
log.info("normalize_completed", recording_key, in_bytes, out_bytes, elapsed_s=round(elapsed,1))
release_inbox(source)       # DB 更新と遷移の後（CONC-08）。inbox_retain != normalized なら何もしない
return true
```

- `_skip` は `part_skipped reason=<SKIP_REASONS.get(code)>` を info で出し、`_reopen_after_exclusion` を呼ぶ（pipeline.py:1556-1580）
- `_fail` は `<event> recording_key error_code [reason]` を error で出し、`_reopen_after_exclusion` を呼ぶ（pipeline.py:1582-1605）

### 1.3 `normalize()`（audio.py:379-500）の順序（**仕様 §8.3 の 1〜8 と一致**）

```text
1. claimed_by != nil && claimed_by != partkey
      → IMPORT_FAILED "staging の slug が衝突しています（{slug} は {claimed_by} が使用中）"
2. verify_output(out) が真 → _reuse():
      digest = sha256(入力全体, 1 MiB 刻み)   失敗 → IMPORT_FAILED "{型名}: {exc}"
      sha256_helper != nil && digest != sha256_helper → 出力を削除、SOURCE_HASH_MISMATCH（下記の文言）
      duplicate_of(digest) = other && other != partkey → 出力を削除、DUPLICATE_CONTENT
      それ以外 → 成功（reused=true、sha256=digest）
3. check_space → 偽なら DISK_SPACE_LOW（呼び手が先にガード済みなので通常は到達しない。到達すると NORMALIZING→FAILED）
4. 変換しながら SHA-256（入力を 1 回だけ読む）。失敗 → 出力削除、IMPORT_FAILED
      起動失敗: "{型名}: {exc}" / 読み取り失敗: "{型名}: {exc}" / タイムアウト: "{timeout} 秒を超えました"
      ffmpeg 非 0: "ffmpeg 終了コード {rc}: {stderr の strip 後の末尾 200 文字}"
5. sha256_helper != nil && digest != sha256_helper → 出力削除、SOURCE_HASH_MISMATCH
      "再計算した SHA-256 が .meta.json と一致しません（{digest[:16]}… ≠ {sha256_helper[:16]}…）"
6. verify_output 偽 → 出力削除、NORMALIZE_VERIFY_FAILED（detail は下記）
7. duplicate_of(digest)=other && other != partkey → 出力削除、DUPLICATE_CONTENT "同じ内容の Part が既にあります: {other}"
8. 成功（sha256=digest, in_bytes, out_bytes=出力の size）
```

- **SHA 照合は `sha256_helper` が nil なら飛ばす**（audio.py:453, 540）。本アプリは常に値があるので nil は「照合不能 = 失敗」側へ倒すことを推奨
- **変換の失敗（タイムアウト含む）の ErrorCode は `IMPORT_FAILED`**（仕様 §8.3 に明記が無い）

### 1.4 `verify_output()`（audio.py:672-712）— 失敗文言（detail）

| 条件 | 文言 |
|---|---|
| ファイルが無い | `{path} がありません` |
| size 0 | `{path} が 0 バイトです` |
| 形式が読めない | `出力を ffprobe で読めません: {error}` |
| sample_rate ≠ 16000 | `sample_rate が {sr}（期待 16000）` |
| channels ≠ 1 | `channels が {ch}（期待 1）` |
| sample_fmt ≠ s16 | `sample_fmt が {fmt}（期待 s16）` |
| 長さ | `gap = abs(出力 − 入力)`; **`gap > 1.0` で失敗**（= 1.0 ちょうどは合格）。`長さが入力と {gap:.2f} 秒ずれています（許容 1.0 秒）` |
| 入力か出力の長さが不明 | 長さ照合を飛ばして合格 |

### 1.5 空き容量（audio.py:292-349）

```text
expected = Int(max(0, duration ?? 1800) × 32000)                    # int() は 0 方向への切り捨て
required = Int(expected × 2.0 + 2147483648)
free    = statfs(staging_root があればそれ、無ければ DATA_ROOT).空き   # 取得失敗 → ok=false "空き容量を取得できません: {exc}"
used    = staging_root 配下の全「通常ファイル」の st_size の合計（再帰。読めないものは飛ばす。ブロック数ではない）
free < required         → "空き {free} バイトが必要量 {required} バイトを下回る"
used + expected > 5 GiB → "staging 使用量 {used} + 想定 {expected} が上限 5368709120 を超える"
```

実測: `expected_bytes(None)=57600000, (0)=0, (1.5)=48000, (1800)=57600000`。

### 1.6 タイムアウト（audio.py:264-275）

`duration == nil → 180`、それ以外 `Int(max(180, duration × 0.5))`（切り捨て）。
実測: `None→180, 100→180, 360→180, 361→180（180.5 の切り捨て）, 1800.7→900`。

### 1.7 inbox の解放（audio.py:724-739）

`inbox_retain == "normalized"` のときだけ `safe_unlink_inbox(missing_ok)`。例外は握りつぶして false。**normalize() からは呼ばない。**

---

## 2. 文字起こし（`transcribe.py` + `pipeline.ensure_part_transcript`）

### 2.1 argv（transcribe.py:138-174。逐語）

```text
[executable, "-m", model, "-f", audio, "-l", language, "-t", threads,
 ( "--vad", "--vad-model", vad_model, "--vad-threshold", num(threshold),
   "--vad-min-speech-duration-ms", str(int), "--vad-min-silence-duration-ms", str(int),
   "--vad-speech-pad-ms", str(int) )   ← vad.enabled のときだけ。偽なら 1 つも渡さない
 "-oj", "-of", out_base, "-np"]
```

- `out_base = <audio の親ディレクトリ>/whisper` → 出力は `<staging>/<slug>/whisper.json`（transcribe.py:36, 236-237）
- `num(x)`: `x == Int(x)` なら `String(Int(x))`、それ以外 Python `str(float)`（実測 `0.5→"0.5", 1.0→"1", 0.25→"0.25", 2.0→"2", 0.1→"0.1"`。transcribe.py:177-179）
- threads: `configured > 0 ? configured : min(os.cpu_count() ?? 1, 8)`。**`os.cpu_count()` は論理 CPU 数**（transcribe.py:118-122）

### 2.2 タイムアウト（transcribe.py:125-135）

`duration == nil → 21600`、それ以外 `Int(min(max(duration × 3.0, 600), 21600))`。
実測: `None→21600, 10→600, 199.9→600, 200→600, 1800→5400, 7200→21600`。

### 2.3 実行と失敗（transcribe.py:290-319, 213-281）

| 事象 | コード | error_message（逐語） |
|---|---|---|
| 起動失敗（OSError） | WHISPER_EXEC_MISSING | `{型名}: {exc}` |
| タイムアウト | WHISPER_TIMEOUT | `{timeout} 秒を超えました`（killpg SIGKILL → communicate） |
| 終了コード ≠ 0 | WHISPER_FAILED | `終了コード {rc}: {stderr[-1000:]}`（strip しない。DB で 200 文字に切られる） |
| 生 JSON が読めない | WHISPER_FAILED | `生 JSON を読めません: {raw_json のパス}` ★仕様に無い |
| 文字数 < min_chars | NO_SPEECH_DETECTED（SKIPPED） | `{len(text)} 文字（min_chars={min_chars}）` |

- どの失敗でも staging の `whisper.json` を削除（transcribe.py:246, 255）
- **正規化 transcript は min_chars 判定より前に書く**（transcribe.py:271-273）
- stdin は `/dev/null`、`start_new_session=True`（新しいプロセスグループ）
- WHISPER_MODEL_MISSING は voicedock では**設定検証（V-23 / V-25）のコード**で、transcribe.py は出さない（config.py:126-128）

### 2.4 生 JSON（whisper.cpp v1.9.4 `-oj`）の読み方（transcribe.py:333-389）

```text
body = document が dict ならそれ、でなければ {}
language = body.result.language（非空文字列）?? fallback_language(= transcription.language)
for entry in body.transcription（list でなければ空）:
    entry が dict、entry.offsets が dict、entry.text が str でなければ飛ばす
    start = sec(offsets.from), end = sec(offsets.to)   # sec(x): bool は不可、int/float のみ。round(x / 1000.0, 3)
    どちらか nil なら飛ばす
    t = text.strip(); 空なら飛ばす
text = "".join(t for 各 segment).strip()
```

- `timestamps`（"00:00:03,200"）は読まない
- 実測: `{"from":1.5,"to":2}` → start 0.002 / end 0.002（float の ms も受理）。`{"from":true}` は飛ばす

### 2.5 正規化 transcript（transcripts/parts/<slug>.json）の形（transcribe.py:78-86, 392-398）

`json.dumps(doc, ensure_ascii=False, indent=2) + "\n"`、キー順固定。実測:

```json
{
  "partkey": "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav",
  "language": "ja",
  "duration_seconds": 1800.0,
  "started_at": "2026-08-29T07:12:04+09:00",
  "text": "おはようございます。今日は。float",
  "segments": [
    {
      "start": 0.0,
      "end": 3.2,
      "text": "おはようございます。"
    },
    {
      "start": 9.001,
      "end": 12.345,
      "text": "今日は。"
    }
  ]
}
```

- duration 不明は `"duration_seconds": null`。セグメント 0 件は `"segments": []`、`"text": ""`
- `started_at` は Part の `started_at`（`isoformat(timespec="seconds")`、オフセット付き。transcribe.py:483-485）
- voicedock は atomic ではない（`write_text`）。本アプリは atomic にする（改善）

### 2.6 読み戻しと冪等（transcribe.py:410-444, 232-234）

- 合格条件: dict で `{partkey, language, duration_seconds, started_at, text, segments}` をすべて含む／segments は list で、各要素が dict・start/end が数値・text が str（1 つでも不正なら全体を None）／text・started_at・language が str／duration は null か数値
- **冪等: 読めて `len(text) >= min_chars` なら whisper を起動しない**（`len` は**コードポイント数**）

### 2.7 呼び手（pipeline.py:388-463 `ensure_part_transcript`）

```text
if status ∈ TRANSCRIBED_OR_BEYOND → true
if status ∉ {NORMALIZED, TRANSCRIBING} || normalized_path == nil → false
if !usable(normalized_path):  → _renormalize_or_fail
if status == NORMALIZED: NORMALIZED→TRANSCRIBING
result = transcribe(...)
NO_SPEECH → db.update(transcript_path) を先に → SKIPPED(NO_SPEECH_DETECTED) from TRANSCRIBING → false
失敗 → FAILED(code ?? WHISPER_FAILED) from TRANSCRIBING, event "transcription_failed" → false
成功 → db.update(transcript_path, error_code=NULL, error_message=NULL) → TRANSCRIBING→TRANSCRIBED
      → log.info("transcription_completed", recording_key, elapsed_s, chars, rtf, speech_ratio)
      → delete_normalized_after_transcribe なら 16 kHz を削除（失敗は log.warning("disk_space_low", reason="staging を消せません: …")）
```

`_renormalize_or_fail`（pipeline.py:1623-1652）:
```text
transition record.status → NORMALIZING           # NORMALIZED→NORMALIZING か TRANSCRIBING→NORMALIZING
inbox に原本あり → return false（ログ無し。次の周回で変換し直す）
無い → FAILED(NORMALIZED_MISSING) from NORMALIZING, event "normalize_failed", reason="input",
       message "16 kHz 音声も inbox の原本もありません（{normalized_path}）。デバイスから採り直す必要があります"
```

metrics（transcribe.py:463-480）: `elapsed_s=round(e,1)`, `chars=len(text)`, `rtf=round(e/duration,3)`（duration が nil か ≤0 なら nil）, `speech_ratio=round(Σmax(0,end-start)/duration,3)`。

### 2.8 `--help` 検査（transcribe.py:185-207, doctor.py:222-234）

voicedock は **`"--vad"` の部分一致だけ**を見る（6 フラグの逐語照合ではない）。VAD 無しは FAIL ではなく NOTICE。
終了コードは見ない（stdout+stderr を連結して検索）。

### 2.9 復旧時の部分出力（pipeline.py:1669-1717）

NORMALIZING → `normalized_path` があれば削除、TRANSCRIBING → `transcripts/parts/<slug>.json` を削除。遷移 detail は `recovery`、最後に `recovery_completed rolled_back=<n>`。

---

## 3. LLM（`llm.py` + `pipeline.ensure_analysis`）

### 3.1 定数（llm.py:38-57, 671-678）

`CHAT_PATH="chat/completions"`、`THINK_RE=r"<think>.*?</think>"`（DOTALL）、`FENCE_RE=r"```(?:json)?\s*\n(.*?)\n?```"`（DOTALL）、
`TITLE_MAX=120`、`SUMMARY_MAX=4000`、`TASK_TEXT_MAX=500`、`NOT_A_SECTION={"timeline"}`、
`LIST_SECTIONS=("key_points","tasks","decisions","ideas","tags")`、`PARTIAL_EXCLUDED={"title","tags"}`、
`REDUCE_MAX_DEPTH=3`、`DEDUPE_FIELDS=("key_points","decisions","ideas","tags")`。

設定（config.example.yaml:96-123）: temperature 0.1 / top_p 0.9 / max_output_tokens 4096 / request_timeout 1800 /
max_chars 20000 / max_seconds 3600 / overlap 500 / repair_attempts 1 /
sections: `summary {enabled, heading "## Summary"}`, `timeline {enabled, heading "## Timeline"}`,
`key_points {…, "## Key Points", 20}`, `tasks {…, "## Tasks", 50}`, `decisions {…, "## Decisions", 30}`,
`ideas {…, "## Ideas", 30}`, `tags {enabled, max_items 15}`（heading 無し）、order `[summary, timeline, key_points, tasks, decisions, ideas]`、custom_instructions `""`。
`max_items` は **null を許す**（null = 上限なし。config.py:251、test_llm_schema.py:164-176）。V-10: `max_chars > overlap × 2`。

### 3.2 スキーマ（llm.py:81-131）

フィールドの**並び**（= model_dump のキー順・schema_block の行順・trimmed の順・エラーの順）:

```text
title    (partial でなく summary 有効時)  str 1..120
summary  (summary 有効時)                str 1..4000
key_points, tasks, decisions, ideas, tags  ← LIST_SECTIONS の順（config の order ではない）
   enabled のものだけ。partial なら tags を除く。要素は str（tasks は Task）
   max_items があれば件数上限、無ければ上限なし。**既定値は空配列（キー欠落を許す）**
Task = {text: str 1..500, due: str | null（キー欠落可 = null）}、未知キー拒否
全体も未知キー拒否（extra="forbid"）
```

- **必須は title と summary だけ。配列は欠落で空配列**（test_llm_schema.py:292-296）★仕様 §8.5 に明記が無い

### 3.3 `{schema_block}`（llm.py:134-184。実測、末尾改行なし）

既定（全有効、final）:
```text
{
  "title": "内容を表す簡潔な日本語（120 文字以内）",
  "summary": "全体の要約（4000 文字以内）",
  "key_points": ["..."],
  "tasks": [{"text": "やること", "due": "2026-08-30 または null"}],
  "decisions": ["..."],
  "ideas": ["..."],
  "tags": ["..."]
}
```
partial（Map / 中間段）:
```text
{
  "summary": "全体の要約（4000 文字以内）",
  "key_points": ["..."],
  "tasks": [{"text": "やること", "due": "2026-08-30 または null"}],
  "decisions": ["..."],
  "ideas": ["..."]
}
```
組み立て: `["{", 各行 "  \"<name>\": <例>" を ",\n" で連結, "}"]` を `"\n"` で連結。例は title → `"内容を表す簡潔な日本語（{max}文字以内）"` の形（`（120 文字以内）`、全角括弧、数字の前後に半角空白）、summary → `"全体の要約（4000 文字以内）"`、tasks → 上記固定、その他 → `["..."]`。**件数上限は出さない。**

### 3.4 プロンプト（prompts/*.txt。全ファイル LF・末尾改行 1 つ）

- analyze_ja.txt / map_ja.txt / reduce_ja.txt / repair_json.txt の本文は voicedock のファイルを**バイト単位で複製**する（`{custom_instructions}` は独立行、`{schema_block}` は最終行）
- 差し込み（llm.py:198-223）: `str.replace("{key}", value)` を **schema_block → custom_instructions の順**に 1 回ずつ。`format()` は使わない
- Map は partial の schema_block、analyze / reduce は final
- 実測（既定、custom 空）: `…書かないでください。\n\n\n以下の JSON のみを…\n\n{…}\n`（custom が空だと空行が 2 つ続く）。custom あり: `…書かないでください。\n健康の話題は要約しない\n\n以下の…`
- 修復（llm.py:226-232）: `repair_json.txt` に **errors → previous_output の順**で置換。**schema_block も custom_instructions も差し込まない**。user メッセージは `""`
  - 実測: `'前回の出力は JSON として不正でした。\n\nエラー内容:\n- summary: Field required\n\n前回の出力:\n{"title": "t"}\n\n同じ内容を、指定されたスキーマに厳密に従う有効な JSON のみで出力し直してください。\n説明文やコードフェンスを付けないでください。\n'`
  - 修復で使うスキーマ（検証）は元の kind のもの（Map なら partial）
- probe（DR-09 相当。llm.py:633-664）: system `{"ok": true} と返してください。`、user `ping`

### 3.5 要求と応答（llm.py:350-436）

```json
{"model": "<model>", "messages": [{"role": "system", "content": "<system>"}, {"role": "user", "content": "<body>"}],
 "temperature": 0.1, "top_p": 0.9, "max_tokens": 4096, "response_format": {"type": "json_object"}}
```

| 事象 | 結果 |
|---|---|
| 接続失敗・タイムアウト（httpx.HTTPError） | LLM_UNAVAILABLE `{型名}: {exc}` |
| HTTP ≥ 400 | LLM_UNAVAILABLE `HTTP {code}: {本文[:200]}` |
| 本文が JSON でない / choices が空 / message.content が str でない | **content = nil → "" として検証へ**（失敗扱いにせず修復へ回る） |
| usage.total_tokens | int なら記録（ログ用） |

URL は `base.rstrip("/") + "/chat/completions"`。voicedock は認証ヘッダを送らない（テストで固定）。

### 3.6 JSON 取り出し（llm.py:238-307）

```text
strip_think(text): THINK_RE を全置換で除去 → 残りに "<think>" があればその手前だけ残す
cleaned = strip_think(text).strip()               # Python の strip（str.isspace の文字）
候補 = [cleaned] + FENCE_RE の全一致を出現順 + balanced(cleaned)
各候補を json.loads し、dict なら返す。どれも駄目なら nil
balanced: 最初の "{" から走査。in_string/escaped を追い、文字列外の { } で深さを数え、0 に戻った位置まで。閉じなければ候補なし
```

実測: `'<think>x</think> {"a":1}'→{a:1}`、`'pre {"a":"}"} post'→{a:"}"}`、`'[{"a":1}]'→{a:1}`、`'<think>{"a":1}'→nil`、
`'```\nnot json\n```\n{"b":2}'→{b:2}`、`'```json\n[1]\n```\n```json\n{"c":3}\n```'→{c:3}`、`'{"a":1,"a":2}'→{a:2}`（後勝ち）、
`'{"a": NaN}'→{a: nan}`（Python は NaN を受理。Swift の JSONSerialization は拒否する。どちらも最終的に修復へ回る）。

### 3.7 上限への切り詰め（llm.py:559-603）

スキーマのフィールド順に、**トップレベルの値が list か str で `len(value) > max_length` のものだけ** `value[:max]` にし、
`"{name}: {len} -> {max}"` を記録。`len` と切り方は**コードポイント**。Task.text（入れ子）は切らない。min は扱わない。
実測: `("title: 121 -> 120", "key_points: 25 -> 20", "tags: 20 -> 15")`。上限ちょうどは切らない。

### 3.8 検証エラーの行（llm.py:606-616。pydantic v2 の文言。実測）

形式 `- {loc を "." で連結}: {msg}`、改行区切り。**順序はスキーマのフィールド順 → 最後に未知キー（入力の順）。**

| 入力 | 行 |
|---|---|
| summary 欠落 | `- summary: Field required` |
| title も summary も欠落 | `- title: Field required` / `- summary: Field required` |
| 未知キー mood | `- mood: Extra inputs are not permitted` |
| summary = "" | `- summary: String should have at least 1 character` |
| key_points = "文字列" / tags = null | `- key_points: Input should be a valid list` |
| key_points = ["a", 1] | `- key_points.1: Input should be a valid string` |
| tasks = [{"due": null}] | `- tasks.0.text: Field required` |
| tasks = ["x"] | `- tasks.0: Input should be a valid dictionary or instance of Task` |
| tasks = [{"text":"a","x":1}] | `- tasks.0.x: Extra inputs are not permitted` |
| due = 3 | `- tasks.0.due: Input should be a valid string` |
| task text "" / 501 文字 | `- tasks.0.text: String should have at least 1 character` / `… at most 500 characters` |
| title = 5 / true、summary = null | `- title: Input should be a valid string` など（bool も文字列扱いしない） |
| 複合 `{"mood":1,"summary":3,"tags":[1],"zzz":2}` | `- title: Field required\n- summary: Input should be a valid string\n- tags.0: Input should be a valid string\n- mood: Extra inputs are not permitted\n- zzz: Extra inputs are not permitted` |
| Map に title/tags | `- title: Extra inputs are not permitted\n- tags: Extra inputs are not permitted` |
| JSON が取れない | `応答から JSON を抽出できませんでした`（行形式ではない。llm.py:551） |

リスト件数の超過（`List should have at most N items after validation, not M`）は切り詰めの後なので実際には出ない。

### 3.9 analyze（llm.py:460-544）

```text
completion = complete(system(kind), user=body); エラー → そのまま返す
raw = content ?? ""
for attempt in 0...repair_attempts:
    (v, failure, trimmed) = extract → coerce_limits → validate
    v あり → 成功（repairs = attempt）
    attempt == repair_attempts → LLM_INVALID_JSON(failure)
    retry = complete(repair_prompt(errors=failure, previous_output=raw), user="")
    retry エラー → そのエラーで終了（repairs = attempt+1）
    raw = retry.content ?? ""
```

### 3.10 チャンク分割（llm.py:700-786）

```text
for seg in segments（統合済み・時刻順）:
    current が空 → 追加して次へ
    chars = Σ len(current の text) + len(seg.text)       # コードポイント。区切りの "\n" は数えない
    secs  = seg.end_at − current[0].at
    over_chars = chars > max_chars ; over_time = secs > max_seconds
    どちらか真 → chunks.append(chunk(current)); current = over_time ? [] : overlap(current)
    current.append(seg)
末尾: current 非空 かつ「current ⊆ 直前チャンクの segments」でなければ追加
overlap(current, limit): limit <= 0 → []; 末尾から、(total + len > limit かつ taken 非空) で止まるまで先頭へ積む
                         taken が current 全部なら先頭 1 つを落とす
chunk: text = "\n".join(texts)、start_at = segments[0].at、end_at = max(end_at)
```

- **両方超えたら重ねない**（over_time 優先）
- 実測（max_chars=10, overlap=4, max_seconds=3600、各 segment 長 5 秒）: `aaa@0,bbb@10,ccc@20,dd@30,eeeee@40,ff@5000` →
  `[aaa,bbb,ccc] 07:12:04–07:12:29`、`[ccc,dd,eeeee] 07:12:24–07:12:49`、`[ff] 08:35:24–08:35:29`

### 3.11 Map-Reduce（llm.py:821-1066）

```text
chunks 0 → SESSION_MERGE_FAILED "チャンクが 0 個です（統合結果が空）"
chunks 1 → analyze(ANALYZE) 1 回。partials=()（単一パス）。重複除去なし
chunks ≥2 → 各 chunk を analyze(MAP)。1 つでも失敗で即終了。trimmed に "map: " を前置
reduce_phase(partials, depth=1):
    body = as_json(partials)
    len(body) <= max_chars || partials.count <= 1 → analyze(REDUCE, body) → dedupe → trimmed に "reduce: "
    depth >= 3 → LLM_INVALID_JSON "多段 Reduce が上限 3 段に達しました"
    bundles(partials, max_chars) を各 analyze(MAP, as_json(bundle))。trimmed に "reduce{depth}: "。失敗で即終了
    reduce_phase(folded, depth+1)
bundles: 時刻順のまま貪欲に。current が非空で as_json(current+[item]) の長さ > limit なら確定して [item] から
as_json: json.dumps([model_dump...], ensure_ascii=False, separators=(",", ":"))
```

- `as_json` の実測: `[{"summary":"朝/昼\n\"引用\"\t\\","key_points":["a"],"tasks":[{"text":"x","due":null}],"decisions":[],"ideas":[]}]`
  → キー順はスキーマ順、空配列も出す、`due` は常に出す、`/` はエスケープしない、制御文字は `\n \r \t \b \f` 以外 `\u00XX`（小文字 16 進）、非 ASCII はそのまま
- dedupe（llm.py:1015-1066）: キー = `unicodedata.normalize("NFKC", s).strip().casefold()`、最初の出現を残す。
  DEDUPE_FIELDS は「非空の list で全要素 str」のときだけ、tasks は text で（due が違っても 1 件）
  - 実測: `" VoiceDock "→"voicedock"`、`"ＶｏｉｃｅＤｏｃｋ"→"voicedock"`、`"ﾃｽﾄ"→"テスト"`、`"Straße"→"strasse"`、`"ΣΑΣ"→"σασ"`、
    `"　全角空白　"→"全角空白"`、`"\x1cX\x1f"→"x"`、`"​X"→"​x"`
- 失敗は例外にせず、Raw ノートは残る

### 3.12 解析工程（pipeline.py:1140-1227, 1402-1479）

```text
row.status ∈ ANALYZED_OR_BEYOND → true（★本アプリはここで指紋を比べる差分を入れる）
row.status ∉ ANALYZABLE={MERGED, ANALYZING} → false
_analysis_matches: analysis.json が読めて final スキーマで検証が通り、source.json の transcript_sha256 == 指紋
    → row.status → ANALYZED（MERGED→ANALYZED もありうる。V2 で辺の有無を確認のこと）→ true
MERGED なら MERGED→ANALYZING
result = analyze_session(...)
失敗 → FAILED(code ?? LLM_FAILED) from ANALYZING、event "llm_failed"、detail=error_message をログに載せる
trimmed → log.info("analysis_trimmed", session_key, fields="; ".join(trimmed))
書き込み（OSError → FAILED(LLM_FAILED, "{型名}: {exc}")）:
    1. analysis/<slug>.json = json.dumps(model_dump, ensure_ascii=False, indent=2) + "\n"
    2. analysis/<slug>.timeline.json（save_timeline。**OSError を握りつぶす**）
    3. analysis/<slug>.source.json = {"schema": 1, "transcript_sha256": fp, "segments": n, "blocks": m}（indent 2 + "\n"）
db.update(analysis_path, title, error_code=NULL, error_message=NULL) → ANALYZING→ANALYZED
log.info("llm_completed", session_key, chunks, elapsed_s)
```

analysis.json 実測:
```json
{
  "title": "t",
  "summary": "s",
  "key_points": [],
  "tasks": [
    {
      "text": "x",
      "due": "2026-09-20"
    }
  ],
  "decisions": [],
  "ideas": [],
  "tags": []
}
```

### 3.13 指紋（session.py:60-93）

```text
payload = json.dumps({
  "segments": [{"at": iso(s.at), "end_at": iso(s.end_at), "text": s.text} ...],
  "blocks":   [[iso(start), iso(end)] ...]
}, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
fp = sha256(payload.utf8).hex
iso(t) = t.isoformat(timespec="seconds")   # 設定のタイムゾーン、オフセット付き、**秒未満は切り捨て**
```

実測（at=07:12:04+0 / +3.2、+9.001 / +12.999、block 07:12:04–07:42:04）:
`{"blocks":[["2026-08-29T07:12:04+09:00","2026-08-29T07:42:04+09:00"]],"segments":[{"at":"2026-08-29T07:12:04+09:00","end_at":"2026-08-29T07:12:07+09:00","text":"おはようございます。"},{"at":"2026-08-29T07:12:13+09:00","end_at":"2026-08-29T07:12:16+09:00","text":"今日は/\"x\""}]}`
→ `894a61422b5c95830fe8b36c33ae2c3af728851d00a5e02e9f691d61ad5fb86f`（12.999 秒が :16 になる = 切り捨て）

`AbsoluteSegment.at = part.started_at + seg.start`（session.py:373-428）。統合は FAILED/SKIPPED を除外、`(started_at, partkey)` 順に読み、text を strip して空を捨て、`(at, end_at)` で安定ソート。

### 3.14 Timeline（daily.py:87-183, 437-521）

- build: partials と chunks があれば `zip(partials, chunks)` で、points が非空のものだけ `TimelineBlock(chunk.start_at, chunk.end_at, points)`。
  points = key_points が非空ならそれ、無ければ `sentences(summary)`
- 単一パス: `sentences(final.summary)`。空なら []。blocks = `transcript.blocks` か（空なら）`[(segments[0].at, max(end_at))]`、各 block に**全文を繰り返す**
- sentences: `text.replace("。", "。\n")` を Python `splitlines()` で割り、各行 strip、空を捨てる（実測 `"一文目。二文目。\n三文目 。 \n\n四"→["一文目。","二文目。","三文目 。","四"]`）
- timeline.json（schema 2）:
```json
{
  "schema": 2,
  "transcript_sha256": "<fp>",
  "blocks": [
    {
      "start_at": "2026-08-29T07:12:04+09:00",
      "end_at": "2026-08-29T07:42:04+09:00",
      "lines": [
        "午前に作業した。",
        "午後に会議。"
      ]
    }
  ]
}
```
- load: 読めない・schema ≠ 2・**transcript_sha256 ≠ 現在の指紋**・blocks が list でない → []（代替経路へ）。壊れた要素は飛ばす
- render: `### HH:MM–HH:MM`（U+2013）、空行、`- <line>` 各行、空行

---

## 4. テスト用の偽物

### 4.1 偽 whisper（tests/fixtures/fake_whisper.py）

- `#!/bin/sh` スクリプト。最初に `printf '%s\n' "$@" > '<path>.argv'`（argv を 1 行ずつ記録）
- `--help` / `-h` があれば help_text を出して exit 0。HELP_WITH_VAD は `--vad` と VAD 5 フラグを含む（6 フラグすべて在る）、HELP_WITHOUT_VAD は含まない
- `-of` の次の引数を base とし、`write_output` なら `<base>.json` に生 JSON を書く。`exit_code`・`stderr`・`sleep_seconds`・孫プロセス（`( sleep N; touch marker ) &\nwait`）を選べる
- 生 JSON（`json.dumps(ensure_ascii=False)`、1 行）:
```json
{"systeminfo": "AVX = 0 | NEON = 1 |", "model": {"type": "large", "multilingual": true},
 "params": {"model": "ggml-large-v3-turbo-q5_0.bin", "language": "ja"}, "result": {"language": "ja"},
 "transcription": [{"timestamps": {"from": "00:00:00,000", "to": "00:00:03,200"}, "offsets": {"from": 0, "to": 3200}, "text": " おはようございます。"},
                   {"timestamps": {"from": "00:00:05,500", "to": "00:00:09,000"}, "offsets": {"from": 5500, "to": 9000}, "text": " 今日の予定を確認します。"}]}
```
  （既定の発話 2 件: `(0.0, 3.2, " おはようございます。")`, `(5.5, 9.0, " 今日の予定を確認します。")`。offsets は `round(秒×1000)`）

### 4.2 WAV 生成（tests/fixtures/make_wav.py）

- 形式: PCM24（既定。tag 1、144000 B/s）、FLOAT32（tag 3、192000 B/s）、PCM16（tag 1。**変換後の形式を作り verify を試すため**）。fmt は 16 バイト（cbSize 無し）、EXTENSIBLE は使わない
- 標本: 無音 = 0.0。発話 = 0.8 秒鳴らし 0.4 秒休み、`0.1 × (sin θ + 0.5 sin 2θ + 0.25 sin 4θ)`、θ = 2π × 220 × t。乱数なし
- 量子化: PCM24 `Int(clamp(v, −1, 1) × 0x7FFFFF)`（0 方向切り捨て）を LE int32 にして上位 1 バイトを捨てる。PCM16 `× 0x7FFF`。FLOAT32 はそのまま LE
- チャンク: `RIFF` / `WAVE` / `fmt `(16) / `bext`(602, 0 埋め) / `iXML`(1092, `<BWFXML></BWFXML>` を空白で右詰め) / `cue `(28, 0 埋め) / `PAD `(30978, 0 埋め) / `data`。奇数長は 1 バイトのパッド（サイズ欄に含めない）
- data の開始オフセット 32776（BWF）、最小ヘッダ 44（`minimal_header`）。`frames = round(rate × seconds)`

### 4.3 LLM 応答 fixture（tests/fixtures/llm_responses/）

session_analysis.json（final の完全形）と partial_analysis.json（Map 形）の 2 本だけ。**「10 セッション分の transcript fixture」は voicedock に存在しない。**

---

## 5. Swift へ移すときの落とし穴（検証済みの具体例付き）

1. **文字数はコードポイント**（Python `len`）。`String.count`（書記素）を使わない: min_chars、チャンクの文字数、切り詰め、`as_json` の長さ、`body[:200]`
2. **Python の `strip()` の空白集合**は `str.isspace`（`\t\n\v\f\r`、`\x1c-\x1f`、空白、`\x85`、`\xa0`、` `、` - `、` `、` `、` `、` `、`　`）。`CharacterSet.whitespacesAndNewlines` と一致しない（`\x1c-\x1f` を含まない）
3. **`casefold()` は完全ケースフォールディング**（`ß→ss`、`Σ→σ` で語末シグマ規則なし）。`lowercased()` は `ß` をそのまま、`ΣΑΣ→σας` にするので**一致しない**
4. **`splitlines()`** は `\n \r \r\n \v \f \x1c \x1d \x1e \x85    ` で割る
5. **isoformat(timespec="seconds") は切り捨て**。`Date` の秒未満を丸めない。Part 内オフセットは整数ミリ秒で持つと誤差が出ない
6. **JSON の数値と真偽**: `JSONSerialization` は bool を `NSNumber` にするので、`CFBooleanGetTypeID()` で区別して「文字列でない」と判定する（pydantic は `true` を文字列として受けない）
7. **JSON の書式**: 内部 JSON（transcript / analysis / timeline / source / Reduce 入力 / 指紋）は Python `json.dumps` と同じ書式を自前で書く必要がある。`JSONEncoder` は Date を数値で出し、`JSONSerialization.prettyPrinted` は `"key" : value`（コロン前に空白）を出す。浮動小数は Swift の `Double.description`（`1800.0`、`3.2`、`1e-05`、`1e+16`）が Python の `repr` と一致する
8. **`AVAudioFile(forWriting:)` は拡張子からファイル形式を決める**。`audio16k.wav.tmp` のように `.tmp` で終わる名前へ書くなら `settings[AVAudioFileTypeKey] = kAudioFileWAVEType` を必ず入れる（入れないと WAV にならない）
9. Python の `json.loads` は NaN / Infinity と重複キー（後勝ち）を受理する。Swift で NaN が拒否されても修復へ回るだけで結果は同じ（どちらも LLM_INVALID_JSON か修復成功）
