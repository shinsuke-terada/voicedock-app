# V5 移植メモ: Obsidian ノート（Raw / Daily）・保存検証・WikiLink・sanitize

出典はすべて voicedock `d3d595e`。`file:line` はそのコミットの行番号。
サンプル出力は `git archive d3d595e` を scratchpad に展開し、**voicedock のコードそのもの**
（Python 3.12.13 / unicodedata 15.0.0、`uv sync --frozen`）で生成した実出力を写した。
生成スクリプト: `scratchpad/v5_samples.py`、出力: `scratchpad/v5_samples.out`。
（Docker なしでもホストの `uv` で golden 生成が回ることの実証を兼ねる。）

---

## 0. 全体の流れ（呼び出し関係）

| 段 | voicedock | 要点 |
|---|---|---|
| Raw 保存 | `pipeline.Pipeline.ensure_raw_note`（pipeline.py:467-547） | TRANSCRIBED→RAW_WRITING を**先に**記録 → Vault 確認 → `raw.write_raw_note` → 検証 → DB 更新 → RAW_WRITING→RAW_SAVED → `reopen_session` |
| Raw の Part 集め | `Pipeline._raw_parts`（pipeline.py:592-623） | `recordings_for_session`（`ORDER BY started_at, partkey`、db.py:447-453）のうち `RAW_NOTE_MEMBERS` で transcript が読めるもの |
| Daily 保存 | `Pipeline.ensure_daily_note`（pipeline.py:1229-1334） | ANALYZED→WRITING を**先に**記録 → `_render_daily` → Vault 確認 → `daily.write_daily_note` → 検証 → DB 更新（error_code/message を NULL）→ WRITING→SAVED |
| Daily 描画 | `Pipeline._render_daily`（pipeline.py:1336-1379） | Timeline は `load_timeline`（指紋一致時）→ 無ければ `build_timeline(partials=(), chunks=())`（要約の文を Block ごと） |
| リンク計画 | `Pipeline._plan_links`（pipeline.py:1381-1400） | `wiki.plan_links`。`OSError`/`ValueError` は空の `LinkPlan()` に落とす |
| 削除側の再検証 | `cleaner.verify_raw_note`（cleaner.py:285-315） | 期待 SHA = DB の `raw_output_sha256`、期待鍵 = `transcript_path` 有り かつ `RAW_NOTE_MEMBERS` の Part |

---

## 1. sanitize（notes.py:42-105）— **ファイル名にだけ**適用

適用先は `raw.raw_filename`（raw.py:127-129）と `daily.daily_filename`（daily.py:379-387）だけ。
**タグ・リンク候補には適用しない**（SPEC §13.5 の「タグ名と `[[]]` のリンク先に適用する」は実装と違う。実装が正）。
フォルダテンプレートにも適用しない。

`sanitize_filename(name, max_bytes)`（`max_bytes` = `obsidian.max_title_bytes`、既定 180）。**この順で**:

| SN | voicedock | 処理（逐語で再現する） |
|---|---|---|
| SN-1 | S-1 | NFC 正規化（Swift: `precomposedStringWithCanonicalMapping`） |
| SN-2 | S-2 | `[\x00-\x1f\x7f]` を除去（**C1 制御 U+0080–U+009F は除去しない**） |
| SN-3 | S-3 | `/ \ : * ? " < > \|` の各 1 文字を `-` へ置換 |
| SN-4 | S-4 | `# ^ [ ]` を除去 |
| SN-5 | S-5 | Python `re` の `\s+` を `" "`（U+0020）1 個へ、その後 `str.strip()`。空白集合は §8 の PY_WS |
| SN-6 | S-6 | 前後の `.`（ASCII のみ）を `strip(".")` |
| SN-7 | S-7 | UTF-8 バイト数 > max_bytes の間、末尾の**コードポイント**を 1 つずつ削る。**その後（切り詰めの有無にかかわらず）**末尾が結合文字（`unicodedata.combining(c) != 0` = Canonical_Combining_Class ≠ 0）である限り削り続ける |
| SN-8 | S-8 | 空なら `Untitled` |
| SN-9 | S-9 | `text.upper()` が `CON PRN AUX NUL COM1..COM9 LPT1..LPT9` のどれかなら末尾に `_`（**S-7 の後**なので max_bytes を 1 バイト超えうる。`CON`/max 3 → `CON_`） |

実出力（max_bytes=180。v5_samples.out）:

```text
'2026-08-29 raw'  -> '2026-08-29 raw'
'{date}:raw'      -> '{date}-raw'
'  a / b  '       -> 'a - b'            （SN-3 が SN-5 より先）
'..hidden..'      -> 'hidden'
'con'             -> 'con_'
'Com1'            -> 'Com1_'
'LPT9.'           -> 'LPT9_'            （SN-6 で '.' が落ちてから SN-9）
'NUL '            -> 'NUL_'
'a#b^c[d]e'       -> 'abcde'
'tab\there\x7f'   -> 'tabhere'          （タブは SN-2 で消える。空白にならない）
''                -> 'Untitled'
'...'             -> 'Untitled'
'q́'         -> 'q'                （切り詰め不要でも末尾の結合文字を削る）
'が'         -> 'が'                （SN-1 で合成済み）
'あ'*70 (210B)    -> 'あ'*60 (180B)
'a'*178+'é' (180B)-> そのまま
'a'*179+'é' (181B)-> 'a'*179
'x　　y'  -> 'x y'
'a|b<c>d*e?f"g\\h'-> 'a-b-c-d-e-f-g-h'
'a\xa0b​c'   -> 'a b​c'        （NBSP は空白、ZWSP は空白ではない）
'é'*100     -> 'é'*90             （NFC 後 2B×90=180B）
```

テスト（test_sanitize.py）の固定点: S-1 NFD→NFC、S-2 の `\x00 \x01 \x1f \x7f`、U+00A0 は制御文字ではない、S-3 全 9 文字、`[[Note]]`→`Note`、
`"  a   b  "`→`"a b"`、`"a\t\tb"`→`"ab"`、`"a / b"`→`"a - b"`、`".hidden."`→`"hidden"`、`"a.b.c"` 不変、`"あ"*80` ≤180B、
`"が"*5` を各上限で切っても結合文字で終わらない、S-8 は `"" "   " "..." "###" "\x00\x01" "[[]]"`、S-9 は大小無視・`CONSOLE`/`COM10` 不変、`CON`(max 3)→`CON_`。

---

## 2. frontmatter（notes.py:108-220）

### 2.1 値の書き出し `render_frontmatter(fields)`（notes.py:133-161）

```text
lines = ["---"]
for (key, value) in fields（挿入順）:
  str   → key + ": " + yaml_quote(value)
  bool  → key + ": " + ("true" | "false")
  int   → key + ": " + 10 進        （float は使わない。渡さない）
  nil   → key + ": null"
  配列  → 空なら key + ": []"
          そうでなければ key + ":" の行、続けて要素ごとに "  - " + yaml_quote(String(要素))
lines.append("---")
return lines.joined("\n") + "\n"
```

`yaml_quote(s)`（notes.py:121-130）: `\` → `\\`、`"` → `\"`、その後 `[\x00-\x1f\x7f]` を除去、全体を `"` で囲む。
**C1 制御（U+0085 等）・U+2028/2029 はそのまま残す**（実出力 `s: "a\"b\\cde\x85f"`）。バイト一致のため「改善」しない。

### 2.2 読み取り

- `split_frontmatter(text)`（notes.py:164-175）: `text` が `"---\n"` で始まらなければ nil。残り（先頭 4 文字の後）から
  正規表現 `^---\s*$`（MULTILINE）の最初の一致を探し、無ければ nil。`(rest[..<match.start], rest[match.end...])`。
  閉じ行の末尾空白は許す（`"---   "` 可）。
- `parse_frontmatter`（notes.py:178-191）: 上の前半を `yaml.safe_load`。例外・非辞書は nil。**例外を投げない。**
- `frontmatter_keys(path)`（notes.py:194-211）: 読めない・UTF-8 でない・frontmatter が無い・`voicedock_recording_keys` が配列でない → 空。要素は `str(item)`。

### 2.3 本文のエスケープ `escape_body`（notes.py:214-220）

`re.sub(r"^---", r"\\---", body, flags=re.M)`: **各行頭（文字列先頭と各 `\n` の直後。`\r` の後ではない）**の `---` を `\---` へ。
`----x` → `\----x`、行中の ` --- ` は不変。**本文にだけ**適用（frontmatter には適用しない）。

---

## 3. Raw ノート（raw.py）

### 3.1 固定文字列（raw.py:32-46）

| 名前 | 値（逐語） |
|---|---|
| type | `voice-raw` |
| source | `DJI Mic 3` |
| タイトル行 | `# {date} の文字起こし（生データ）` （括弧は全角 U+FF08 / U+FF09） |
| 導入行 | `> 自動文字起こしの生データ。未編集。` |
| 段落の連結 | 半角空白 1 つ `" "` |
| 範囲の区切り | `–`（U+2013 EN DASH） |

### 3.2 パス（raw.py:97-129, 243-247）

- `render_template(t, day)`: `{yyyymmdd}`→`%Y%m%d`、`{date}`→`YYYY-MM-DD`、`{time}`→`000000`。未知のプレースホルダは**残す**（検証 V-13 が起動時に弾く）。
- フォルダ = `vault_root / render_template(folder_template)`（sanitize しない）。`mkdir -p`（Vault 確認の**後**）。
- basename = `sanitize(render_template(filename_template), max_title_bytes)`。
- 出力パス = `notes.resolve_output_path(folder, basename, session_key)`（§6）。
- `day` = `paths.day_of_session(session_key)`（`#2` 接尾辞を落とした `YYYYMMDD`。paths.py:223-233）。

### 3.3 描画 `render_raw_note(parts, day, session_key, cfg)`（raw.py:135-218）

```text
ordered = parts を (started_at, partkey) 昇順        # 時刻は瞬間として比較
fm = render_frontmatter([
  ("type", "voice-raw"),
  ("voicedock_session_key", session_key),
  ("voicedock_recording_keys", ordered.map(partkey)),
  ("date", day.isoformat()),          # 文字列 → "2026-08-29"（引用される）
  ("parts", ordered.count),           # int
  ("source", "DJI Mic 3"),
])
lines = ["", "# \(date) の文字起こし（生データ）", "", "> 自動文字起こしの生データ。未編集。", ""]
for part in ordered:
  if cfg.part_boundary_heading:
    lines += ["## " + range(part), ""]       # range = "HH:MM–HH:MM"、ended_at 無しなら "HH:MM–"
  lines += segments(part, cfg.timestamp_interval_seconds)
body = lines.joined("\n") の末尾の "\n" を全部削って + "\n"
return fm + escape_body(body)

segments(part, interval):
  out = []; chunk = []; next_mark = nil
  for seg in part.segments（与えられた順）:
    text = seg.text.strip()                  # PY_WS で strip
    if text == "": continue
    if interval > 0 and (next_mark == nil or seg.at >= next_mark):
      if chunk: out += [chunk.joined(" "), ""]; chunk = []
      out += ["### " + seg.at の %H:%M:%S, ""]
      next_mark = seg.at + interval 秒
    chunk.append(text)
  if chunk: out += [chunk.joined(" "), ""]
  return out
```

- `HH:MM` / `HH:MM:SS` は **DB に保存された `started_at` 文字列のオフセット**（= 設定のタイムゾーン）での壁時計。小数秒は**切り捨て**。
- `seg.at = datetime.fromisoformat(record.started_at) + timedelta(seconds=segment.start)`（pipeline.py:592-623）。
  `segment.start` は正規化 transcript の秒（whisper の ms / 1000 を小数 3 桁に丸めたもの）。
  **Python の datetime はマイクロ秒の整数演算**なので、`seg.at >= next_mark` の等号境界も厳密。Swift で `Date`（Double）加算にすると
  境界で判定が割れうる → **時刻は整数（ミリ秒かマイクロ秒）で持つ**こと（§9 の注意 1）。
- テキストの無い Part でも `##` 見出しは出る（下の「raw_part_without_text」）。
- `parts` が空でも描画できる（`voicedock_recording_keys: []`、`parts: 0`）。

### 3.4 実出力（全文。`\n` 区切り、末尾改行 1 つ）

**raw_2parts**（part_b, part_a の順で渡しても同じ。既定設定）:

```markdown
---
type: "voice-raw"
voicedock_session_key: "DJIMIC3:20260829"
voicedock_recording_keys:
  - "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"
  - "DJIMIC3/TX_MIC001_20260829_074201/TX01_MIC002_20260829_074210_orig.wav"
date: "2026-08-29"
parts: 2
source: "DJI Mic 3"
---

# 2026-08-29 の文字起こし（生データ）

> 自動文字起こしの生データ。未編集。

## 07:12–07:42

### 07:12:04

おはようございます。

### 07:17:04

削除条件を整理します。

## 07:42–08:12

### 07:42:10

続きです。
```

**raw_noend**（ended_at=nil。区間 `"  x  "`@07:12:04, `"   "`@07:13:00, `"---"`@07:13:04, `"y"`@07:18:03, `"z"`@07:18:04）:
本文部分は
```markdown
## 07:12–

### 07:12:04

x ---

### 07:18:03

y z
```
（行頭でない `---` はエスケープされない。07:17:04 に達した最初の区間が 07:18:03。）

**raw_noheadings**（`timestamp_interval_seconds: 0`, `part_boundary_heading: false`）本文:
```markdown
> 自動文字起こしの生データ。未編集。

おはようございます。 削除条件を整理します。

続きです。
```

**raw_empty**: frontmatter が `voicedock_recording_keys: []` / `parts: 0`、本文は導入行で終わる。

**raw_part_without_text**（2 本目の Part の区間が空白だけ）: 本文の最後が `## 07:42–08:12\n` で終わる（見出しだけ残る）。

テストの固定点（test_raw_render.py）: `### 07:00:00/07:06:00/07:12:00/07:18:00`（2 分刻み、300 秒）、見出しをまたぐと段落を切る
（`"### 07:12:04\n\nおはようございます。\n\n### 07:17:04\n\n削除条件を整理します。"`）、同一見出し下は `"… 、 やれば、…"` と半角空白、
`"---"` だけの区間は `\---` に、`{date}:raw` → `2026-08-29-raw`、別 session_key だと ` (2).md`。

---

## 4. Daily ノート（daily.py）

### 4.1 固定文字列（daily.py:37-71）

| 名前 | 値（逐語） |
|---|---|
| type | `voice-daily` |
| status | `processed` |
| 期限マーク | `📅`（U+1F4C5） |
| FAILED 行 | `> ⚠ この日の録音のうち {n} 本が処理できませんでした。次にデバイスを接続したときに自動で再試行されます。` |
| SKIPPED 行 | `> {mark}この日の録音のうち {n} 本を除外しました（{reasons}）。自動では再試行されません。{action}` |
| mark / action | 操作要なら `"⚠ "`（⚠ = U+26A0 の後に半角空白）/ `"デバイスから採り直してください。"`、不要なら両方 `""` |
| 理由の区切り | `・`（U+30FB） |
| 理由の表示名 | DUPLICATE_CONTENT→`重複`、SOURCE_MISSING→`元ファイルが見つかりません`、NORMALIZED_MISSING→`元ファイルが見つかりません`、NO_SPEECH_DETECTED→`無音`、表に無いコード→コードそのまま、`None`/空→`理由不明` |
| 操作不要の理由（許可リスト） | `{NO_SPEECH_DETECTED, DUPLICATE_CONTENT}` だけ |
| 見出し（既定。config.example.yaml） | summary `## Summary` / timeline `## Timeline` / key_points `## Key Points` / tasks `## Tasks` / decisions `## Decisions` / ideas `## Ideas`（tags は見出しを持たず order にも無い） |
| 既定の order | `[summary, timeline, key_points, tasks, decisions, ideas]` |
| Sources / Links 見出し | `## Sources` / `## Links` |

### 4.2 入力の作り方（pipeline.py:1229-1379）

- `parts = recordings_for_session(key)`（`ORDER BY started_at, partkey`）。
- `included` = status ∉ {FAILED, SKIPPED}、`excluded` = status ∈ {FAILED, SKIPPED}（session.py:30）。
- `recording_keys = included.map(partkey)`（この順）、`recorded_seconds = sessions.recorded_seconds`
  （= 分組時の `SUM(duration_seconds)`。**FAILED/SKIPPED も含む**。NULL は無視、全部 NULL なら NULL。session.py:244-271）。
- `block_count = len(transcript.blocks)`（blocks は included だけで算出。session.py:329-370, 373-415）。
- `timeline` = `load_timeline(analysis_path, fingerprint)`、空なら `build_timeline(partials=(), chunks=(), transcript, summary)`。
- `links` = `_plan_links(...)`（§7）。例外 `OSError`/`ValueError` は空の `LinkPlan()`。

### 4.3 描画 `render_daily_note`（daily.py:189-252）

```text
tags = _tags(analysis, cfg)
failed  = excluded.filter(status == FAILED)
skipped = excluded.filter(status != FAILED)            # = SKIPPED
fm = render_frontmatter([
  ("type", "voice-daily"),
  ("voicedock_session_key", session_key),
  ("voicedock_recording_keys", recording_keys),
  ("voicedock_failed_parts", failed.map(partkey)),
  ("voicedock_skipped_parts", skipped.map(partkey)),
  ("date", day.isoformat()),
  ("recorded", duration(recorded_seconds)),           # 文字列 → 引用される
  ("parts", recording_keys.count),
  ("blocks", block_count),
  ("status", "processed"),
  ("tags", tags),
])
title = analysis.title が空でなければそれ、空/無しなら day.isoformat()   # strip しない
lines = ["", "# " + title, ""]
for w in warnings(failed, skipped): lines += [w, ""]
for name in cfg.analysis.order:
  sec = cfg.analysis.sections[name]; if sec 無し or !sec.enabled: continue
  heading = sec.heading ?? "## " + name
  rendered = (name == "timeline") ? timeline_lines(timeline) : section_lines(name, analysis)
  if rendered 空: continue                             # 見出しごと省く
  lines += [heading, ""] + rendered
lines += sources(links) + links_section(links)
body = lines.joined("\n") の末尾 "\n" を全部削って + "\n"
return fm + escape_body(body)

section_lines(name, analysis):
  summary: t = summary.strip()（PY_WS）; t 空なら [] ; そうでなければ [t, ""]
  配列でない/空: []
  tasks:   [ task(x) for x ] + [""]      task = "- [ ] " + text + (due が真なら " 📅 " + due)
  その他:  [ "- " + String(x) for x ] + [""]     # 要素は strip しない
timeline_lines: 各ブロック [ "### " + HH:MM + "–" + HH:MM, "", ("- " + line)..., "" ]
sources(links): links.raw が空なら []、でなければ ["## Sources", "", ("- " + l)..., ""]
links_section: values = [daily_note(非 nil)] + adjacent + tags.filter(hasPrefix "[[")
               空なら []、でなければ ["## Links", "", ("- " + v)..., ""]
```

- `duration(s)`（daily.py:364-369）: nil または < 0 → `"00:00:00"`。それ以外は `t = int(s)`（0 方向へ切り捨て）、
  `"%02d:%02d:%02d" % (t/3600, t/60%60, t%60)`。**時は 2 桁を超えうる**（90061.7 → `"25:01:01"`）。
- `_tags`（daily.py:343-361）: `default_tags + (analysis.tags が配列なら各 str)` を順に、`strip()`（PY_WS）→ `" "`（U+0020）と
  `"　"`（U+3000）だけを `-` へ置換 → 空なら捨てる → `casefold()` で既出なら捨てる（先勝ち）。**sanitize は通さない。**
  実出力: 入力 `["VoiceDock","DJI Mic","a: b",'c "d"',"e\\f","  ","全角　空白"]` →
  `["voice","voicedock","DJI-Mic","a:-b",'c-"d"',"e\\f","全角-空白"]`。
- `warnings`（daily.py:300-340）: FAILED 行（あれば）→ SKIPPED 行（あれば）。最大 2 行。
  - `actionable = skipped のどれかの error_code ∉ 許可リスト`（nil も actionable）。
  - `reasons`: `seen = {error_code ?? ""}` の集合を **ErrorCode の宣言順インデックス**で昇順（未知・空は末尾 = `len(ErrorCode)`）、
    表示名へ写して `・` で連結。**表示名の重複除去はしない**（コードの重複だけ除く）。
  - voicedock の注意: 未知コードが 2 種以上あると同順位の並びは Python の set 順（ハッシュ依存）で**非決定**。現実には起きないが、
    Swift では同順位を**コード文字列の昇順**で決めること（決定性の確保。golden はこの組み合わせを作らない）。
- ErrorCode の宣言順（errors.py、実行結果）:
  `CONFIG_UNKNOWN_KEY, CONFIG_INVALID_VALUE, CONFIG_LOCK_MISMATCH, DEVICE_NOT_READABLE, DEVICE_UNSUPPORTED, FILE_NOT_STABLE,
  DUPLICATE_CONTENT, SOURCE_MISSING, SOURCE_HASH_MISMATCH, HELPER_UNAVAILABLE, DELETE_QUEUE_FAILED, DELETE_TIMEOUT, DISK_SPACE_LOW,
  AUDIO_PROBE_FAILED, IMPORT_FAILED, NORMALIZE_VERIFY_FAILED, NORMALIZED_MISSING, WHISPER_EXEC_MISSING, WHISPER_MODEL_MISSING,
  WHISPER_FAILED, WHISPER_TIMEOUT, NO_SPEECH_DETECTED, OBSIDIAN_RAW_WRITE_FAILED, OBSIDIAN_RAW_VERIFY_FAILED, SESSION_MERGE_FAILED,
  LLM_UNAVAILABLE, LLM_FAILED, LLM_INVALID_JSON, OBSIDIAN_NOT_FOUND, OBSIDIAN_WRITE_FAILED, OBSIDIAN_VERIFY_FAILED,
  SOURCE_IDENTITY_MISMATCH, SOURCE_DELETE_FAILED, LOCAL_DELETE_FAILED, DB_ERROR`
  （本計画 A.3 はここから 3 つを廃止するだけなので相対順は保たれる。）
- 実出力の警告行:
  - 無音 1: `> この日の録音のうち 1 本を除外しました（無音）。自動では再試行されません。`
  - 無音+重複（渡す順は逆でも）: `> この日の録音のうち 2 本を除外しました（重複・無音）。自動では再試行されません。`
  - SOURCE_MISSING + None + LLM_FAILED: `> ⚠ この日の録音のうち 3 本を除外しました（元ファイルが見つかりません・LLM_FAILED・理由不明）。自動では再試行されません。デバイスから採り直してください。`
- `title`: スキーマ上 `title` は 1〜120 文字の必須（summary 有効時）。V-18 が summary の有効を強制するので、`day.isoformat()` の代替は実質使われない。

### 4.4 Timeline（daily.py:88-183, 440-521）

- `build_timeline(partials, chunks, transcript, summary)`:
  - `partials` と `chunks` がどちらも非空: `zip(partials, chunks)`（短い方で打ち切り）の各組で `points(partial)` が非空のものだけ、
    `TimelineBlock(chunk.start_at, chunk.end_at, points)`。`points` = `key_points` が非空配列なら各 `str`、無ければ `sentences(partial.summary)`。
    `partials` は **1 段目の Map 結果（チャンクごと）**（llm.py:865-889）。
  - それ以外: `s = sentences(summary)`。空なら `[]`。`blocks = transcript.blocks`、空なら
    `[(segments[0].at, max(segments.end_at))]`（segments も空なら `[]`）。各 block に**同じ全文の列 s** を付ける。
- `sentences(text)`: `text` の各 `。` の直後に `\n` を挿入 → Python `str.splitlines()`（区切り集合は §8 の PY_LINES）→ 各要素を `strip()` → 空を捨てる。
  例: `"A。B。 C"` → `["A。","B。","C"]`。
- 保存 `save_timeline`（daily.py:449-482）: `<analysis の拡張子を .timeline.json に>`、
  `{"schema": 2, "transcript_sha256": <指紋>, "blocks": [{"start_at": iso秒, "end_at": iso秒, "lines": [...]}]}` を
  `json.dumps(ensure_ascii=False, indent=2) + "\n"`。**書けなくても例外にしない**（非 atomic の write_text）。
- 読み込み `load_timeline`: 読めない / JSON でない / 辞書でない / `schema != 2` / 指紋不一致 / `blocks` が配列でない → `[]`。
  要素ごとに辞書でない・`start_at`/`end_at` が無いか ISO でない・`lines` が配列でない → その要素だけ飛ばす。`lines` は各 `str`。
- 指紋 `session.transcript_fingerprint`（session.py:60-93）:
  `json.dumps({"segments":[{"at": iso秒, "end_at": iso秒, "text": t}], "blocks":[[iso秒, iso秒]]}, ensure_ascii=False, sort_keys=True, separators=(",",":"))`
  の UTF-8 の SHA-256 hex。`iso秒` は `isoformat(timespec="seconds")`（小数秒切り捨て、`+09:00` 形式）。
  （本計画 §8.5 は Swift `JSONEncoder` での指紋を規定しており voicedock と一致しないが、指紋はアプリ内部でしか使わないので互換は不要。§8.5 側の担当。）

### 4.5 実出力（全文）

入力: test_daily_render.py の ANALYSIS（tags は §4.3 の敵対的な値に差し替え）、recording_keys 2 件、
excluded = FAILED(WHISPER_FAILED) 1 + SKIPPED(NO_SPEECH) 1 + SKIPPED(DUPLICATE) 1、recorded_seconds 34880.9、block_count 2、
timeline 2 ブロック、links = 日付・前後日・`[[VoiceDock]]`・`#DJI-Mic`・raw `[[2026-08-29 raw]]`。

```markdown
---
type: "voice-daily"
voicedock_session_key: "DJIMIC3:20260829"
voicedock_recording_keys:
  - "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"
  - "DJIMIC3/TX_MIC001_20260829_074201/TX01_MIC002_20260829_074210_orig.wav"
voicedock_failed_parts:
  - "DJIMIC3/F/f_orig.wav"
voicedock_skipped_parts:
  - "DJIMIC3/S/s1_orig.wav"
  - "DJIMIC3/S/s2_orig.wav"
date: "2026-08-29"
recorded: "09:41:20"
parts: 2
blocks: 2
status: "processed"
tags:
  - "voice"
  - "voicedock"
  - "DJI-Mic"
  - "a:-b"
  - "c-\"d\""
  - "e\\f"
  - "全角-空白"
---

# 開発と打ち合わせの一日

> ⚠ この日の録音のうち 1 本が処理できませんでした。次にデバイスを接続したときに自動で再試行されます。

> この日の録音のうち 2 本を除外しました（重複・無音）。自動では再試行されません。

## Summary

VoiceDock の削除条件を整理した。午後に MVP の範囲を確定した。

## Timeline

### 07:12–11:12

- 朝の移動中に整理した
- 二点目

### 13:12–19:12

- MVP を確定した

## Key Points

- 削除の根拠をテキストの保全に置く

## Tasks

- [ ] DJI Mic 3 のマウント構造を確認する
- [ ] Whisper の速度を実測する 📅 2026-09-05

## Decisions

- MVP では GUI を作らない

## Ideas

- 将来的に話者識別を追加する

## Sources

- [[2026-08-29 raw]]

## Links

- [[2026-08-29]]
- [[2026-08-28 Voice]]
- [[2026-08-30 Voice]]
- [[VoiceDock]]
```

最小形（recording_keys 空、FAILED 無し、SKIPPED 3 件、recorded nil、timeline 空、links 空、summary 以外空）:

```markdown
---
type: "voice-daily"
voicedock_session_key: "DJIMIC3:20260829"
voicedock_recording_keys: []
voicedock_failed_parts: []
voicedock_skipped_parts:
  - "DJIMIC3/S/s3_orig.wav"
  - "DJIMIC3/S/s4_orig.wav"
  - "DJIMIC3/S/s5_orig.wav"
date: "2026-08-29"
recorded: "00:00:00"
parts: 0
blocks: 0
status: "processed"
tags:
  - "voice"
  - "voicedock"
---

# 題

> ⚠ この日の録音のうち 3 本を除外しました（元ファイルが見つかりません・LLM_FAILED・理由不明）。自動では再試行されません。デバイスから採り直してください。

## Summary

一文目。二文目。
```

（この形は `## Sources` も `[[…]]` も無いので DN-9 で落ちる。実運用では Raw リンクが必ず付く。）

### 4.6 パス（daily.py:375-434）

- フォルダ = `vault_root / render_template(wiki.folder_template)`、basename = `sanitize(render_template(wiki.filename_template), max_title_bytes)`。
- 出力パス = `resolve_output_path(folder, basename, session_key)`。
- **`## Sources` のリンク先は `raw_note_names()` = `[sanitize(render_template(raw.filename_template))]`**（daily.py:428-434）。
  **実際に書いた Raw のパス（` (2)` 付きかもしれない）ではない**（X-15 は事実）。

---

## 5. 保存検証（notes.py:294-464）

`verify_note(path, kind, session_key, expected_sha, expected_keys, summary_heading)` は規則ごとの結果列を返す。
**途中で打ち切るケースがある**（落ちた規則の列＝ `error_message` の中身に影響）:

```text
[1] 通常ファイルで symlink でない（is_file は symlink を辿る → さらに not is_symlink）
    stat 例外 → [1]=false で終了。偽 → [1] だけ返して終了
[2] size > 0。size == 0 → [1],[2] で終了
[3] UTF-8 デコード。失敗 → [1..3] で終了
[4] SHA-256(読み直したバイト列) == expected_sha      （偽でも続行）
Daily のみ [W-5] split_frontmatter が成功
frontmatter を YAML で読めない（nil）:
    Raw  → R-5=false, R-6=false で終了
    Daily→ W-6=false, W-7=false, 続けて W-8, W-9 を評価して終了
R-5 / W-6: frontmatter["voicedock_session_key"] == session_key（型も文字列として一致）
R-6: expected_keys ⊆ { str(x) for x in frontmatter["voicedock_recording_keys"] }（配列でなければ空集合）
W-7: 上の集合 == set(expected_keys)
W-8: 正規表現 ^<re.escape(heading)>\s*$（MULTILINE）の最初の行が在り、その直後から次の ^#{1,6}␠ の行の手前までを
     strip()（PY_WS）して非空。heading = sections.summary.heading（無ければ "## Summary"）
W-9: \[\[[^\]]+\]\] が 1 つ以上（Raw へのリンクかどうかは見ない）
```

- 呼び手の失敗の写し方（pipeline.py）: Raw 検証失敗 → `OBSIDIAN_RAW_VERIFY_FAILED`「落ちた規則: R-1, …」、
  書き込み例外（`OSError`/`ValueError`。`(99)` 超過も ValueError）→ `OBSIDIAN_RAW_WRITE_FAILED`、Daily は `OBSIDIAN_VERIFY_FAILED` / `OBSIDIAN_WRITE_FAILED`、
  Vault 不在 → `OBSIDIAN_NOT_FOUND`（Raw は RAW_WRITING→FAILED、Daily は WRITING→FAILED。**遷移は Vault 確認より先に記録済み**）、
  Daily の解析 JSON が読めない → `OBSIDIAN_WRITE_FAILED`「解析結果を読めません: …」（ANALYZED/WRITING から FAILED）。
- 削除側の再検証（cleaner.py:285-315）: `raw_output_path`/`raw_output_sha256` のどちらかが NULL → 偽。
  `expected_sha = raw_output_sha256`（DB）、`expected_keys = parts.filter(transcript_path != NULL && status ∈ RAW_NOTE_MEMBERS)`。
- V-18（config.py:268-272）が `summary.enabled == true` を強制、V-19（274-280）が order 中の各見出しを「`#` で始まる 1 行」に強制。
  → **W-8 は summary を無効にした設定では起きない**（無効化自体が設定エラー）。

---

## 6. 出力先の決定と既存ファイル（notes.py:499-524）

```text
resolve_output_path(folder, basename, session_key):
  c = folder/basename.md
  if !exists(c) or belongs(c): return c
  for i in 2...99: c = folder/"basename (i).md"; if !exists(c) or belongs(c): return c
  raise ValueError("同名ファイルが多すぎます")
belongs(p) = UTF-8 で読め、frontmatter が読め、voicedock_session_key == session_key
```

- `exists` は symlink を辿る（壊れた symlink は「無い」→ そこへ書く。atomic_write の rename が symlink 自体を置き換える）。
- voicedock は**同じ session_key の frontmatter を持つファイルなら誰が書いたものでも上書きする**。

---

## 7. WikiLink と Vault 索引（wiki.py）

### 7.1 索引（wiki.py:46-167）

- `normalize_name(s) = NFC(s).casefold()`（Python の完全ケースフォールディング。`Straße`↔`STRASSE`、`İ`→`i̇`、`ﬁ`→`fi`、`Σ`→`σ`）。
- `build_index(root, exclude_prefixes)`: 深さ優先のスタック。各ディレクトリで `scandir`（失敗は飛ばす）。
  名前が `.` で始まるエントリは**ファイルもディレクトリも**無視。`is_dir(follow_symlinks=False)`（**symlink のディレクトリは辿らない**）。
  ディレクトリは Vault ルートからの相対 POSIX パスが除外接頭辞と一致するか `接頭辞/` で始まれば入らない。
  ファイルは名前が `.md`（**大小区別**）で終わるものだけ、`normalize_name(name から .md を除く)` を集合へ。存在しないルートは空集合。
- 除外接頭辞 = `raw_folder_prefix` = `raw.folder_template` の最初の `{` より前を `/` で strip（`{` が無ければ全体を strip）。既定 `Daily/Voice/Raw`。
- `index_for`: `link_tags == false` なら索引を作らず nil。キャッシュは呼び手（Worker）が持ち、`now - built_at >= ttl` で作り直す（monotonic）。

### 7.2 リンク計画 `plan_links`（wiki.py:230-310）

```text
budget = max_links; dropped = []
usable(c): c.strip()（PY_WS）が空 or c が {[ ] | # ^} のどれかを含む → dropped に入れて偽
           normalize_name(c) == normalize_name(self_name) → dropped に入れて偽
daily_note = nil
if link_daily_note: c = day の "YYYY-MM-DD"; if usable(c) and budget > 0: daily_note = "[[c]]"; budget -= 1
adjacent = []
if link_adjacent_days: for off in [-1, +1]:
   c = daily_filename(day+off)（sanitize 済みの "YYYY-MM-DD Voice"）; if !usable(c): continue
   if budget <= 0: dropped += c; continue
   adjacent += "[[c]]"; budget -= 1
tags_out = []
for c in tags:                                   # ★ LLM の analysis.tags をそのまま（既定タグなし・空白置換なし・strip なし）
   if !usable(c): continue                       # 使えない候補は #タグ にもならず消える
   existing = index != nil and index.contains(c)
   wanted = link_tags and (existing or !link_only_existing)
   if wanted and budget > 0: tags_out += "[[c]]"; budget -= 1; continue
   if wanted: dropped += c
   tags_out += "#c"
raw = raw_names.filter(is_linkable).map("[[name]]")   # 上限の対象外。自己参照判定もしない
```

- self_name = `daily_filename(cfg, day)`（` (2)` を含まない）。
- `## Links` に出るのは `daily_note`、`adjacent`、`tags_out` のうち `[[` で始まるものだけ（`#タグ` は本文に出ない）。
- 実出力: tags `["VoiceDock","none","a#b","2026-08-29 Voice"]`、索引 `{voicedock}` →
  `tags_out = ("[[VoiceDock]]", "#none")`、`dropped = ("a#b", "2026-08-29 Voice")`、`raw = ("[[2026-08-29 raw]]",)`。
- `max_links: 0` は許される（日付・前後日・タグのリンクが全部消え、Raw だけ残る）。

---

## 8. Python 互換のための文字集合（Swift で自前に持つ）

- **PY_WS**（`str.isspace()` / `str.strip()` / `re` の `\s`）: U+0009–000D, U+001C–001F, U+0020, U+0085, U+00A0, U+1680, U+2000–200A,
  U+2028, U+2029, U+202F, U+205F, U+3000。
  Swift の `CharacterSet.whitespacesAndNewlines` とは **U+001C–U+001F の有無が違う**。`Unicode.Scalar.Properties.isWhitespace`（White_Space）も U+001C–001F を含まない。
- **PY_LINES**（`str.splitlines()` の区切り）: `\r\n`（2 文字で 1 区切り）, U+000A, U+000B, U+000C, U+000D, U+001C, U+001D, U+001E, U+0085, U+2028, U+2029。
  末尾の区切りの後に空要素は作らない（`"a\n".splitlines() == ["a"]`）。
- **結合文字**: `unicodedata.combining(c) != 0` ↔ `c.properties.canonicalCombiningClass != .notReordered`。
- **casefold**: Unicode 完全ケースフォールディング（CaseFolding.txt の C+F）。Swift 標準に同等 API は無い。
  `lowercased()` は不可（`ß` が `ss` にならない）。実装を 1 関数に閉じ、`Straße/STRASSE`・`İ`・`ﬁ`・`ΣΑΣ`（Python は `σασ`。語末シグマを作らない）の固定テストを置く。
- Python の unicodedata は 15.0.0（Python 3.12）。Swift 側の Unicode 版との差は稀な文字だけ。golden の入力に新しい文字を使わない。

## 9. Swift 実装時の注意（バイト一致を壊しやすい点）

1. **時刻の算術を整数で**: Python の `datetime + timedelta` はマイクロ秒の整数演算。`seg.at >= next_mark`（300 秒境界）・Block のギャップ比較・
   チャンクの実時間比較は等号境界を含む。`Date` は Double 秒なので境界で割れうる。**絶対時刻は Int64 ミリ秒（whisper の offsets と同じ単位）で持ち、表示の直前にだけ暦へ変換する。**
2. 時刻の表示（`HH:MM`、`HH:MM:SS`、ISO）は**保存された文字列のオフセット（= 設定のタイムゾーン）**で行い、小数秒は切り捨て。
3. 文字列の strip・空白判定・splitlines は §8 の集合で。`Character` 単位ではなく `Unicode.Scalar` 単位で処理（sanitize の切り詰め、結合文字判定）。
4. `escape_body` は `\n` の直後と先頭だけ。`\r\n` の文書でも `\r` の後は対象外。
5. frontmatter は**汎用 YAML ライターを使わない**。読み取り（検証・`frontmatter_keys`・`belongs`）だけ Yams。
6. 要素の文字列化: 配列要素は `str(item)`。数値を渡さない（partkey/タグは常に文字列）。

---

## 10. atomic write（notes.py:223-288）

```text
expected = sha256(content)
tmp = 同じディレクトリの "." + 最終ファイル名 + ".tmp"
try:
  open(tmp, "wb")（既存 tmp は切り詰めて上書き）→ write → flush → fsync → close
  actual = sha256(tmp を読み直した内容); 不一致 → ValueError（rename しない）
  os.replace(tmp, target)
except 何でも（KeyboardInterrupt を含む）:
  tmp の削除を試みる（失敗は握りつぶす。元の例外を再送出）
  raise
親ディレクトリを open(O_RDONLY) → fsync（open 失敗・fsync 失敗とも無視）→ close
return expected
```

- 一時ファイル削除は `paths.safe_unlink_tmp`（paths.py:373-393）: 名前が `.` で始まり `.tmp` で終わり長さ > 5、かつ realpath が Vault か `/data` の配下。
- **クラッシュ復旧で Vault の tmp は消さない**（pipeline.py:1669-1717 の `_discard_partial` は staging と transcript だけ）。次回の書き込みが同名 tmp を切り詰めて使うので実害は無い（X-14 は掃除の改善）。

## 11. Vault の確認（notes.py:470-496、pipeline.py:1607-1621）

- `root.is_dir()`（symlink を辿る）が偽 → 偽。`marker.strip()` が空 → 真（本計画は CV-41 で空を禁止）。`(root/marker).is_dir()`（symlink を辿る。ファイルは不可）。
- 詳細文: ルートが無い → `"{root} がありません"`、marker が無い → `"{root} に {marker}/ がありません（Vault が未マウントか、別の場所を指しています）"`。
- 出力フォルダは Vault 確認の**後**に `mkdir -p`（Vault ルートは作らない）。

---

## 12. golden 生成（§10.4）で generate.py が呼ぶ入口

`git archive d3d595e | tar -x` した木で、`sys.path` に木のルートを入れて import（`uv sync --frozen` → `uv run python`。**ホストの uv で動くことを確認済み**、Docker 不要）。

| 対象 | 関数（引数の形） |
|---|---|
| 設定 | `voicedock.config.parse_config(merge(tests.helpers.example_document(), 上書き))` → `(Config, violations)`。ファイル実在検査は別関数なので素の example で通る |
| sanitize | `notes.sanitize_filename(name, max_bytes=int)` |
| frontmatter | `notes.render_frontmatter(dict)`（挿入順）、`notes.yaml_quote(str)`、`notes.escape_body(str)` |
| Raw | `raw.render_raw_note(parts: [raw.RawPart(partkey, started_at: aware datetime, ended_at: aware datetime|None, segments: tuple[raw.RawSegment(at, end_at, text)])], day: date, session_key: str, cfg: Config.obsidian.raw)`、`raw.raw_filename(cfg.obsidian.raw, day, max_bytes=)` |
| Daily | `daily.render_daily_note(analysis, day=, session_key=, recording_keys=[str], excluded=[daily.ExcludedPart(partkey, status: str, error_code: str|None)], recorded_seconds=float|None, block_count=int, timeline=[daily.TimelineBlock(start_at, end_at, lines: tuple[str])], links=wiki.LinkPlan(...), cfg=Config)`。`analysis = llm.build_schema(cfg).model_validate(dict)` |
| Timeline | `daily.build_timeline(partials=[llm.build_schema(cfg, partial=True).model_validate(dict)], chunks=[llm.Chunk(text, start_at, end_at, segments=())], transcript=session.SessionTranscript(day_date, segments=[session.AbsoluteSegment(at, end_at, text)], blocks=[(start,end)], excluded_partkeys=[]), summary=str)` |
| リンク | `wiki.plan_links(cfg=, day=, tags=[str], index=wiki.VaultIndex(names=frozenset(normalize済み), built_at=0.0) or None, self_name=daily.daily_filename(cfg, day), name_for_day=lambda d: daily.daily_filename(cfg, d), raw_names=[str])`、`wiki.normalize_name`、`wiki.build_index(実ディレクトリ, exclude_prefixes=(wiki.raw_folder_prefix(cfg),))` |
| 指紋・Block | `session.transcript_fingerprint(SessionTranscript)`、`session.compute_blocks([obj with started_at: str, ended_at: str|None], gap_seconds=)` |
| 警告行だけ | 私有関数 `daily._warnings` / `_skip_reasons` / `_tags` / `_duration`（私有だが固定コミットなので呼んでよい。golden は `render_daily_note` 経由を主にする） |

入力 fixture の時刻は「タイムゾーン名 + ISO 8601（オフセット付き）」で持ち、generate.py で `datetime.fromisoformat` → `ZoneInfo` 付与。
