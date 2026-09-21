# T-25 golden 生成ツールと入力 fixture

| 項目 | 値 |
|---|---|
| ID | T-25 |
| 題 | golden（voicedock@d3d595e の出力）の生成ツール・入力 fixture・期待値と、TestSupport の読み込み・比較の API |
| Phase | 1 |
| 前提 | T-01（`Package.swift` の `TestSupport` と `PolicyTests`、`Makefile` の `golden`、`PackageRoot`・`TestEnvironment`） |
| 見積もり | 手で書く行 約 2269（生成ツール 1304、TestSupport 729、テスト 236）。生成物（`inputs/*.json` 31、期待値 294 ファイル・約 153 KiB、`GENERATED_BY.txt`）は数えない。600 行の目安を超えるが、ケースの定義・生成器・読み込みを分けると「期待値が再現しない PR」ができるので 1 つにする（PR 本文に理由を書く） |

## 1. 目的

voicedock@d3d595e の Python の関数そのものを呼んで、移植先の Swift が**バイト単位で一致すべき出力**（golden）を作り、リポジトリにコミットする。
あわせて、後続のチケット（T-09・T-10・T-16・T-17・T-19・T-20・T-26・T-27・T-45）が golden を読む・比べるための TestSupport の API を用意する（使う名前の索引は 4.13）。
voicedock の作業ツリーには一切書き込まない（`git archive` で一時ディレクトリへ展開し、ホストの `uv` で環境を作る）。

## 2. 参照

- PLAN §10.4（golden。ホストの uv・`GENERATED_BY.txt`）、§5.7（Python 互換）、§8.4〜§8.6（転写・LLM・ノート）、§6.2（設定の既定値）、付録 F
- voicedock@d3d595e（読むだけ。`git -C <voicedock> show d3d595e:<path>`）:
  `tests/helpers.py:29-88`（`example_document`・`merge`・`complete_tree`・`parsed`）、`config/config.example.yaml`、
  `src/voicedock/paths.py`・`notes.py`・`raw.py`・`daily.py`・`wiki.py`・`llm.py`・`session.py`（`:74-91` 指紋）・`transcribe.py`・`audio.py`、`prompts/*.txt`、`pyproject.toml`・`uv.lock`
- 設定: golden が使う voicedock の設定は `config/config.example.yaml`（`tests/helpers.complete_tree`）に `overrides` を当てたもの。golden に効く項目（`obsidian.*`・`llm.*`・`session.blockGapSeconds`・`transcription` の timeout・`audio` の timeout）の既定値は PLAN §6.2 の既定値と同じ（確認済み）

## 3. 作るもの

| パス | 内容 |
|---|---|
| `.gitattributes` | 下記の全文（golden と Unicode のデータを改行変換しない） |
| `tools/golden/generate.sh` | 下記の全文。実行権 0755 |
| `tools/golden/make_inputs.py` | 下記の全文。**ケースの定義はここだけに書く** |
| `tools/golden/generate.py` | 下記の全文。voicedock の関数で期待値を作る |
| `Tests/Golden/inputs/<group>.json` | 生成物（31 ファイル）。`make golden` の出力をコミットする。手で直さない |
| `Tests/Golden/expected/<group>/<name>.<ext>` | 生成物（294 ファイル）。同上 |
| `Tests/Golden/GENERATED_BY.txt` | 生成物。同上 |
| `Tests/TestSupport/GoldenJSON.swift` | 下記の全文。値で比べる JSON |
| `Tests/TestSupport/Golden.swift` | 下記の全文。入力と期待値の読み込み |
| `Tests/TestSupport/GoldenAssert.swift` | 下記の全文。比較と差分の記録 |
| `Tests/TestSupport/UnifiedDiff.swift` | 下記の全文。unified diff |
| `Tests/TestSupport/TestEnvironment+Golden.swift` | `TestEnvironment` に `goldenWriteActual` を 1 つ足す **extension**（型の作り手は T-01。地図 §15 の「足したい機能は作り手のチケットの型に extension で足す」に沿い、T-01 の `TestEnvironment.swift` は書き換えない） |
| `Tests/PolicyTests/GoldenInventoryTests.swift` | 下記の全文 |
| `Tests/PolicyTests/GoldenSupportTests.swift` | 下記の全文 |

`Makefile` の `golden` ターゲットは T-01 が作ってある（`tools/golden/generate.sh` が無ければ「T-25」と案内して止まる）。本チケットで `make golden` が動くようになる。

## 4. 仕様

### 4.1 仕組み

1. `make golden`（= `tools/golden/generate.sh`）を開発機で実行する。要るもの: `git`・`uv`（0.12 系で確認）・ネットワーク（初回の Python 3.12 と依存の取得）・voicedock の clone（既定 `/Users/terada/Projects/voicedock`。環境変数 `VOICEDOCK_REPO` で変える）
2. `generate.sh` は voicedock の clone に `d3d595e` が在ることを確かめ、`git archive d3d595e` を `mktemp -d` の一時ディレクトリへ展開する（**voicedock の作業ツリー・index・`.venv` には触らない**）。終わると `trap` で一時ディレクトリごと消す
3. 一時ディレクトリで `uv sync --frozen --python 3.12` を行い、voicedock の `uv.lock` どおりの環境を作る
4. その環境の Python で `make_inputs.py` を実行し、`Tests/Golden/inputs/*.json` を作り直す（古い `*.json` は消してから書く）
5. `Tests/Golden/expected/` を消して作り直し、同じ環境の Python で `generate.py` を実行する。`generate.py` は各入力ケースを voicedock の関数に渡し、結果を `expected/<group>/<name>.<ext>` に書く
6. `generate.py` は最後に `Tests/Golden/GENERATED_BY.txt` を書く
7. 同じ voicedock・同じ `uv.lock` なら何度実行しても同じバイト列になる（`git diff --quiet Tests/Golden` が真。受け入れ条件）

Swift のテストは生成に関わらない。コミットされた `inputs/*.json` を読んで Swift の値を作り、`expected/` と比べるだけ（テストの実行に uv も voicedock も要らない）。

### 4.2 ディレクトリと命名規則

```text
Tests/Golden/
├── GENERATED_BY.txt
├── inputs/
│   └── <group>.json              … 31 ファイル。グループ名は小文字の英字・数字・_（4.4 の表）
└── expected/
    └── <group>/
        └── <name>.<ext>          … 1 ケースにちょうど 1 ファイル
```

- `<group>`: 4.4 の表の 31 個。`generate.py` の `handlers` のキーと `make_inputs.py` の `GROUPS` のキーと `GoldenInventoryTests.requiredGroups` が同じ集合（違えば生成もテストも止まる）
- `<name>`: ケース名。`[a-z0-9_]+`、グループの中で一意（`make_inputs.py` と `GoldenInventoryTests` が検査する）
- `<ext>` と比べ方:
  - `.md` … Markdown のノート。**バイト列で比べる**（`GoldenAssert.matches`）
  - `.out` … その他の文字列（ファイル名・JSON の文字列・プロンプト・指紋など）。**バイト列で比べる**
  - `.json` … 構造化した値。`json.dumps(value, ensure_ascii=False, indent=2) + "\n"` で書く。**値で比べる**（`GoldenAssert.matchesJSON`。キーの順・数の書き方・空白は問わない。文字列は Unicode スカラー列で比べる）
- 拡張子はケースごとに `generate.py` のハンドラが決める（同じグループでも `kind` によって `.out` と `.json` が混ざる: `frontmatter`・`wiki`）
- 同じ名前で拡張子の違う期待値が 2 つ在ってはならない（`Golden.expectedFile` が `expectedAmbiguous` を投げる）

### 4.3 入力 fixture の形式

```json
{
  "schema": 1,
  "group": "<group>",
  "cases": [
    { "name": "<name>", "timeZone": "Asia/Tokyo", "<キー>": <値>, … },
    …
  ]
}
```

- `json.dumps(ensure_ascii=False, indent=2) + "\n"` で書く。ただし**文字列の中の見えない文字**（一般カテゴリ Cc・Cf・Cs・Co・Zl・Zp・Zs・Mn・Mc・Me のうち U+007F 以上）は `\u` ＋ 4 桁の小文字 16 進（U+FFFF を超えるものはサロゲートの組）に書き換える（レビューで読めるようにするため。値は変わらない）
- すべてのケースに `timeZone` が在る（既定 `"Asia/Tokyo"`）。`raw_note`・`daily_note`・`note_filename`・`timeline`・`wiki`・`fingerprint`・`llm_chunks` には `day`（既定 `"2026-08-29"`）、`raw_note`・`daily_note` には `sessionKey`（既定 `"DJIMIC3:20260829"`）が在る。既定はケースが自分で持つ値を上書きしない
- **時刻**: `base`・`startedAt`・`endedAt` は ISO 8601 のオフセット付き文字列（例 `2026-08-29T07:12:04+09:00`）。`atMs`・`endMs`・`startMs` は**基準からのミリ秒の整数**（Python の `datetime + timedelta(milliseconds=…)` と同じ整数演算。Swift では `Instant(epochMillis: 基準.epochMillis + ms)`）。基準は `raw_note` の `segments` では各 Part の `startedAt`、それ以外では同じケース（または同じオブジェクト）の `base`。`blocks` の `startS`・`endS` だけは秒の整数
- **Raw ノートの表示時刻**は、保存された `startedAt` の文字列のオフセット（固定）での壁時計（PLAN §5.7）。`raw_note/dst_fixed_offset` は `America/New_York` の設定で `-05:00` の文字列を渡し、夏時間の規則ではなく文字列のオフセットで表示されること（`02:10`）を固定する
- **日付**: `day` は `YYYY-MM-DD`（`LocalDate`）
- **型付きの値**（JSON だけでは Python の型が決まらないもの）:
  - `frontmatter` の `fields`: `[[キー, 値]…]`。値は `["s", 文字列]`・`["i", 整数]`・`["b", 真偽]`・`["n"]`（None）・`["a", [文字列…]]`
  - `pyjson` の `value` と `pyjson_decode` の期待値の `value`: `["n"]`・`["b", 真偽]`・`["i", 整数]`・`["f", "<Python の repr>"]`・`["s", 文字列]`・`["a", [型付きの値…]]`・`["o", [[キー, 型付きの値]…]]`（キーの順を保つ）。`pyjson_decode` では、Int64 に収まらない整数は `["f", repr(float(値))]`、対にならないサロゲートは U+FFFD にして書く（T-45 の `PyJSON.decode` の仕様と同じ）
- **設定の上書き** `overrides`: `{"<AppConfig の JSON のキーパス>": <JSON の値>}`。キーパスは PLAN §6.2 の JSON のキー（camelCase。節名だけ snake_case）を `.` でつないだもの。**使ってよいキーは次だけ**（`generate.py` の `ALLOWED_OVERRIDES`・`SECTION_OVERRIDE` と `Golden.allowedOverrideKeys`・`isAllowedOverride` が同じ一覧。違うキーは生成もテストも止める）:
  `obsidian.maxTitleBytes`・`obsidian.defaultTags`・`obsidian.raw.folderTemplate`・`obsidian.raw.filenameTemplate`・`obsidian.raw.timestampIntervalSeconds`・`obsidian.raw.partBoundaryHeading`・
  `obsidian.wiki.folderTemplate`・`obsidian.wiki.filenameTemplate`・`obsidian.wiki.linkDailyNote`・`obsidian.wiki.linkAdjacentDays`・`obsidian.wiki.linkTags`・`obsidian.wiki.linkOnlyExisting`・`obsidian.wiki.maxLinks`・
  `llm.maxCharsPerRequest`・`llm.maxSecondsPerRequest`・`llm.chunkOverlapChars`・`llm.analysis.order`・`llm.analysis.customInstructions`・`session.blockGapSeconds`、
  および `llm.analysis.sections.<summary|timeline|key_points|tasks|decisions|ideas|tags>.<enabled|heading>` と `llm.analysis.sections.<key_points|tasks|decisions|ideas|tags>.maxItems`（**`maxItems` を持つのは 5 節だけ**。`summary` / `timeline` の `maxItems` は CV-01。PLAN §6.2・付録 F の F-54）
- `generate.py` は上書きのキーパスの各段を camelCase → snake_case に写して（`to_snake`）voicedock の設定に当てる。Swift 側は 4.12 の `GoldenConfig.make`（T-09 が足す） で `AppConfig` に当てる

### 4.4 グループの一覧

| グループ | ケース数 | 期待値 | 入力のキー（`name`・`timeZone` のほか） | voicedock の関数 | 使うチケット |
|---|---|---|---|---|---|
| `keys` | 7 | `.json` `{key, slug}` | `kind`: `partkey`（`deviceID`・`relpath`）/ `sessionKey`（`deviceID`・`startedAt`・`overflow`） | `paths.partkey_for`・`paths.session_key_for`・`paths.key_slug` | T-10（全ケース。T-06 は本チケットより前に入るので golden を使わない） |
| `sanitize` | 38 | `.out` | `input`・`maxBytes` | `notes.sanitize_filename` | T-26 |
| `frontmatter` | 12 | `render`・`quote`・`escapeBody` は `.out`、`split` は `.json`（`{front, body}` か `null`） | `kind`、`fields`（`[[キー, 型付きの値]…]`）、`text` | `notes.render_frontmatter`・`yaml_quote`・`escape_body`・`split_frontmatter` | T-26 |
| `raw_note` | 9 | `.md` | `parts`（`[{partkey, startedAt, endedAt\|null, segments:[{startMs, endMs, text}]}]`）・`day`・`sessionKey`・`overrides` | `raw.render_raw_note` | T-26 |
| `note_filename` | 8 | `.out` | `kind`: `raw` / `daily` / `rawFolder` / `dailyFolder`、`day`・`overrides` | `raw.raw_filename`・`daily.daily_filename`・`raw.render_template` | T-26（`raw*`）・T-27（`daily*`） |
| `daily_note` | 20 | `.md` | `analysis`・`timeline`（`{base, blocks:[{startMs, endMs, lines}]}`）・`links`（`{dailyNote, adjacent, tags, raw}`）・`recordingKeys`・`excluded`（`[{partkey, status, errorCode}]`）・`recordedSeconds`・`blockCount`・`day`・`sessionKey`・`overrides` | `daily.render_daily_note` | T-27 |
| `daily_parts` | 6 | `.json` | `kind`: `recorded`（`inputs`）/ `tags`（`defaults`・`tags`）/ `warnings`（`sets`）/ `sentences`（`inputs`） | `daily._duration`・`_tags`・`_warnings`・`_sentences` | T-27 |
| `timeline` | 8 | `.out`（`<slug>.timeline.json` のバイト列） | `base`・`partials`・`chunks`（`[{startMs, endMs}]`）・`transcript`（`{segments:[{atMs, endMs, text}], blocks:[{startMs, endMs}]}`）・`summary`・`fingerprint`・`day` | `daily.build_timeline`・`daily.save_timeline` | T-27 |
| `timeline_decode` | 7 | `.json` `[{start, end, lines}]` | `document`（ファイルの中身の文字列）・`fingerprint` | `daily.load_timeline` | T-27 |
| `wiki` | 15 | `rawPrefix` は `.out`、他は `.json` | `kind`: `normalize`（`inputs`）/ `plan`（`day`・`tags`・`indexNames\|null`・`rawNames`・`overrides`）/ `buildIndex`（`files`・`symlinkDirs`・`overrides`）/ `rawPrefix`（`overrides`） | `wiki.normalize_name`・`plan_links`・`build_index`・`raw_folder_prefix` | T-27 |
| `llm_schema_block` | 5 | `.out` | `partial`・`overrides` | `llm.render_schema_block` | T-19 |
| `llm_prompt` | 6 | `.out` | `kind`: `analyze` / `map` / `reduce`、`overrides` | `llm.system_prompt` | T-19 |
| `llm_repair_prompt` | 3 | `.out` | `partial`・`errors`・`previousOutput`・`overrides` | `repair_json.txt` ＋ `"\n{schema_block}\n"`（本計画の差分 X-12。`llm.repair_prompt` と前提を照合） | T-19 |
| `llm_validate` | 23 | `.json` `{ok, errors, result}` | `partial`・`payload`・`overrides` | `llm.build_schema(...).model_validate`・`llm._errors_of` | T-19 |
| `llm_trim` | 5 | `.json` `{trimmed, result}` | `partial`・`payload`・`overrides` | `llm.coerce_limits` | T-19 |
| `llm_extract` | 14 | `.json`（値か `null`） | `text` | `llm.extract_json` | T-19 |
| `llm_strip_think` | 5 | `.out` | `text` | `llm.strip_think` | T-19 |
| `llm_chunks` | 9 | `.json` `[{texts, startMs, endMs, text}]` | `base`・`segments`（`[{atMs, endMs, text}]`）・`day`・`overrides` | `llm.split_chunks` | T-20 |
| `llm_dedupe` | 4 | `.json` | `kind`: `key`（`inputs`）/ `values`（`inputs`）/ `result`（`payload`・`overrides`） | `llm.normalize_for_dedupe`・`dedupe`・`_deduped` | T-20 |
| `llm_as_json` | 3 | `.out` | `partials`・`overrides` | `llm._as_json` | T-20 |
| `llm_bundles` | 3 | `.json`（束ごとの partial の添字の配列） | `partials`・`limit`・`overrides` | `llm._bundles` | T-20 |
| `analysis_json` | 4 | `.out`（indent 2 ＋ `\n`） | `payload`・`overrides` | `llm.build_schema(...).model_validate(...).model_dump()` | T-19 |
| `transcript_json` | 8 | `.out`（indent 2 ＋ `\n`） | `whisper`・`partkey`・`startedAt`・`durationSeconds`・`fallbackLanguage` | `transcribe.normalize(...).to_document()` | T-17 |
| `numbers` | 4 | `.json` | `kind`: `num` / `whisperTimeout` / `convertTimeout` / `expectedBytes`、`inputs` | `transcribe._number`・`timeout_for`・`audio.convert_timeout`・`expected_bytes` | T-17（`num`・`whisperTimeout`）・T-16（`convertTimeout`・`expectedBytes`） |
| `fingerprint` | 3 | `.out`（指紋の入力の JSON ＋ `\n` ＋ sha256 ＋ `\n`） | `base`・`segments`（`[{atMs, endMs, text}]`）・`blocks`（`[{startMs, endMs}]`）・`day` | `session.transcript_fingerprint`（入力の JSON を同じ手順で作り、sha256 が一致することを生成時に確かめる） | T-10 |
| `blocks` | 10 | `.json` `[[start, end]…]` | `base`・`parts`（`[{startS, endS\|null}]`、秒）・`gapSeconds` | `session.compute_blocks` | T-10 |
| `pytext` | 9 | `.json` | `kind`: `enumerations` / `strip` / `stripChars`（`chars`）/ `splitlines` / `collapse` / `casefold` / `nfc` / `nfkc`、`inputs` | Python の `str`・`re.sub(r"\s+", " ", s)`・`unicodedata` | T-45 |
| `pyjson` | 11 | `.out` | `mode`: `compact` / `compact_sorted` / `indent2` / `file`、`value`（型付きの値） | `json.dumps(ensure_ascii=False, …)` | T-45 |
| `pyjson_decode` | 28 | `.json` `{ok, value}` | `text` | `json.loads` | T-45 |
| `pyround` | 3 | `.json`（`repr` の文字列の配列） | `digits`・`inputs`（`repr` の文字列） | `round(float(s), digits)` | T-45 |
| `prompt_files` | 4 | `.out` | （ケース名 = `prompts/<name>.txt`） | voicedock の `prompts/*.txt` のバイト列 | T-19 |

### 4.5 全ケースの一覧

ケースの中身（入力の値）は 4.9 の `make_inputs.py` の全文が正。ここでは名前と期待値のファイル名だけを並べる（`kind` を持つケースは括弧内に書く）。

| グループ | ケース（`kind` があれば括弧内。入力の順） |
|---|---|
| `keys` | `partkey_fixed.json`（partkey）、`partkey_no_name.json`（partkey）、`partkey_root_file.json`（partkey）、`session_fixed.json`（sessionKey）、`session_overflow2.json`（sessionKey）、`session_utc_input_converted.json`（sessionKey）、`session_late_night.json`（sessionKey） |
| `sanitize` | `plain.out`、`colon.out`、`slash_spaces.out`、`dots_around.out`、`dots_inside.out`、`reserved_con.out`、`reserved_com1.out`、`reserved_lpt9_dot.out`、`reserved_nul_space.out`、`console_not_reserved.out`、`com10_not_reserved.out`、`hash_caret_brackets.out`、`wikilink.out`、`tab_del.out`、`empty.out`、`spaces_only.out`、`dots_only.out`、`hashes_only.out`、`controls_only.out`、`brackets_only.out`、`nfd_to_nfc.out`、`combining_tail.out`、`japanese_70.out`、`japanese_80.out`、`ascii_180_bytes.out`、`ascii_181_bytes.out`、`fullwidth_spaces.out`、`forbidden_chars.out`、`nbsp_zwsp.out`、`e_acute_100.out`、`ga_5_max7.out`、`ga_5_max4.out`、`con_max3.out`、`c1_nel.out`、`fs_x1c.out`、`line_separator.out`、`tabs_inside.out`、`spaces_inside.out` |
| `frontmatter` | `all_types.out`（render）、`special_chars.out`（render）、`raw_like.out`（render）、`quote_plain.out`（quote）、`quote_escapes.out`（quote）、`escape_lines.out`（escapeBody）、`escape_crlf.out`（escapeBody）、`escape_none.out`（escapeBody）、`split_ok.json`（split）、`split_no_frontmatter.json`（split）、`split_unclosed.json`（split）、`split_empty_front.json`（split） |
| `raw_note` | `two_parts_reordered.md`、`no_end.md`、`no_headings.md`、`empty.md`、`part_without_text.md`、`two_minute_segments.md`、`boundary_exactly_300s.md`、`subsecond_heading_truncated.md`、`dst_fixed_offset.md` |
| `note_filename` | `raw_default.out`（raw）、`raw_colon_template.out`（raw）、`raw_all_placeholders.out`（raw）、`raw_max_bytes_5.out`（raw）、`daily_default.out`（daily）、`daily_custom.out`（daily）、`raw_folder_default.out`（rawFolder）、`daily_folder_default.out`（dailyFolder） |
| `daily_note` | `full.md`、`minimal.md`、`no_warnings.md`、`failed_only.md`、`skipped_no_speech.md`、`skipped_dup_and_no_speech_reversed.md`、`skipped_actionable_mixed.md`、`skipped_missing_both_codes.md`、`failed_and_skipped_null.md`、`raw_link_only.md`、`no_links.md`、`empty_sections.md`、`order_custom.md`、`ideas_disabled.md`、`headings_custom.md`、`recorded_over_24h.md`、`recorded_negative.md`、`body_dashes.md`、`default_tags_custom.md`、`timeline_empty.md` |
| `daily_parts` | `recorded_values.json`（recorded）、`tags_adversarial.json`（tags）、`tags_missing.json`（tags）、`tags_defaults_dup.json`（tags）、`warnings_cases.json`（warnings）、`sentences_cases.json`（sentences） |
| `timeline` | `single_pass_blocks.out`、`single_pass_fallback_block.out`、`single_pass_empty_summary.out`、`single_pass_no_segments.out`、`map_reduce.out`、`map_reduce_zip_short.out`、`partials_without_chunks.out`、`escapes_in_lines.out` |
| `timeline_decode` | `valid.json`、`wrong_schema.json`、`wrong_fingerprint.json`、`bad_elements_skipped.json`、`not_object.json`、`not_json.json`、`blocks_not_list.json` |
| `wiki` | `normalize_names.json`（normalize）、`plan_basic.json`（plan）、`plan_max_links_2.json`（plan）、`plan_max_links_0.json`（plan）、`plan_link_tags_false.json`（plan）、`plan_link_only_existing_false.json`（plan）、`plan_no_daily_no_adjacent.json`（plan）、`plan_index_null.json`（plan）、`plan_casefold_match.json`（plan）、`plan_month_boundary.json`（plan）、`plan_bad_raw_name.json`（plan）、`index_tree.json`（buildIndex）、`raw_prefix_default.out`（rawPrefix）、`raw_prefix_no_brace.out`（rawPrefix）、`raw_prefix_brace_first.out`（rawPrefix） |
| `llm_schema_block` | `final_default.out`、`partial_default.out`、`final_tags_ideas_disabled.out`、`final_maxitems_null.out`、`partial_tasks_disabled.out` |
| `llm_prompt` | `analyze_default.out`（analyze）、`analyze_custom.out`（analyze）、`map_default.out`（map）、`map_custom_multiline.out`（map）、`reduce_default.out`（reduce）、`analyze_custom_contains_placeholder.out`（analyze） |
| `llm_repair_prompt` | `divergent_final.out`、`divergent_partial.out`、`divergent_placeholders_in_output.out` |
| `llm_validate` | `ok_minimal.json`、`ok_full.json`、`missing_summary.json`、`missing_both.json`、`extra.json`、`empty_summary.json`、`wrong_list.json`、`list_item_type.json`、`task_missing_text.json`、`task_not_dict.json`、`task_extra.json`、`task_due_int.json`、`task_due_missing_ok.json`、`task_text_empty.json`、`task_text_long.json`、`title_int.json`、`title_bool.json`、`title_too_long.json`、`summary_null.json`、`list_null.json`、`multi_order.json`、`partial_with_title_tags.json`、`partial_ok.json` |
| `llm_trim` | `trim_all.json`、`trim_exact_limits.json`、`trim_task_text_not_cut.json`、`trim_maxitems_null.json`、`trim_non_list_ignored.json` |
| `llm_extract` | `think_prefix.json`、`fence_json.json`、`brace_in_string.json`、`array_then_object.json`、`unclosed_think.json`、`fence_not_json_then_object.json`、`two_fences.json`、`plain.json`、`escaped_quote.json`、`nothing.json`、`empty.json`、`think_multiline.json`、`nested.json`、`whitespace.json` |
| `llm_strip_think` | `closed.out`、`two.out`、`unclosed.out`、`multiline.out`、`none.out` |
| `llm_chunks` | `v4_example.json`、`time_cut_no_overlap.json`、`both_exceeded_no_overlap.json`、`overlap_takes_at_least_one.json`、`overlap_whole_drops_first.json`、`single_over_limit.json`、`multibyte_counts_scalars.json`、`empty.json`、`default_limits_one_chunk.json` |
| `llm_dedupe` | `keys.json`（key）、`values_first_wins.json`（values）、`result_all_fields.json`（result）、`result_empty_lists.json`（result） |
| `llm_as_json` | `escapes_partial.out`、`two_partials.out`、`ideas_disabled.out` |
| `llm_bundles` | `limit_120.json`、`limit_300.json`、`single_oversized.json` |
| `analysis_json` | `minimal.out`、`task_due.out`、`tags_disabled.out`、`escapes.out` |
| `transcript_json` | `v4_example.out`、`empty.out`、`language_fallback.out`、`language_en.out`、`not_object.out`、`bad_entries.out`、`rounding_ms.out`、`escapes_text.out` |
| `numbers` | `whisper_num.json`（num）、`whisper_timeout.json`（whisperTimeout）、`convert_timeout.json`（convertTimeout）、`expected_bytes.json`（expectedBytes） |
| `fingerprint` | `v4_example.out`、`empty.out`、`escapes_and_blocks.out` |
| `blocks` | `exactly_gap_not_split.json`、`one_second_over_splits.json`、`overlap_single.json`、`contained_keeps_end.json`、`null_end_forces_split.json`、`zero_gap.json`、`empty.json`、`unsorted_input.json`、`same_start_null_first.json`、`last_null_end.json` |
| `pytext` | `enumerations.json`（enumerations）、`strip_cases.json`（strip）、`strip_dot_cases.json`（stripChars）、`strip_slash_cases.json`（stripChars）、`splitlines_cases.json`（splitlines）、`collapse_cases.json`（collapse）、`casefold_cases.json`（casefold）、`nfc_cases.json`（nfc）、`nfkc_cases.json`（nfkc） |
| `pyjson` | `scalars_compact.out`、`floats_compact.out`、`string_escapes.out`、`indent_nested.out`、`indent_empty_containers.out`、`indent_top_scalar.out`、`file_transcript_like.out`、`file_source_json.out`、`order_preserved_compact.out`、`sort_keys_codepoint.out`、`sort_keys_nested.out` |
| `pyjson_decode` | `object_basic.json`、`duplicate_key_last_wins_first_position.json`、`numbers.json`、`constants.json`、`string_escapes.json`、`lone_surrogate.json`、`ascii_whitespace_around.json`、`ideographic_space_rejected.json`、`extra_data_rejected.json`、`empty_rejected.json`、`bom_rejected.json`、`raw_control_char_rejected.json`、`raw_tab_in_string_rejected.json`、`invalid_escape_rejected.json`、`short_unicode_escape_rejected.json`、`non_string_key_rejected.json`、`trailing_comma_array_rejected.json`、`trailing_comma_object_rejected.json`、`leading_zero_rejected.json`、`minus_only_rejected.json`、`dot_without_digits_rejected.json`、`leading_dot_rejected.json`、`nested_ten.json`、`top_string.json`、`top_number.json`、`top_true.json`、`non_ascii_raw.json`、`empty_containers.json` |
| `pyround` | `digits3_ms.json`、`digits3_ratios.json`、`digits1.json` |
| `prompt_files` | `analyze_ja.out`、`map_ja.out`、`reduce_ja.out`、`repair_json.out` |

合計 294 ケース（= 期待値 294 ファイル）。

入力と期待値の例（生成物からの抜粋）:

`inputs/sanitize.json` の `reserved_con`:

```json
{
  "name": "reserved_con",
  "input": "con",
  "maxBytes": 180,
  "timeZone": "Asia/Tokyo"
}
```

`expected/sanitize/reserved_con.out`（4 バイト）:

```text
con_
```


`inputs/keys.json` の `partkey_fixed`:

```json
{
  "name": "partkey_fixed",
  "kind": "partkey",
  "deviceID": "DJIMIC3",
  "relpath": "TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav",
  "timeZone": "Asia/Tokyo"
}
```

`expected/keys/partkey_fixed.json`（116 バイト）:

```text
{
  "key": "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav",
  "slug": "a5d046dce76cfedc"
}
```


`inputs/blocks.json` の `exactly_gap_not_split`:

```json
{
  "name": "exactly_gap_not_split",
  "base": "2026-08-29T07:00:00+09:00",
  "gapSeconds": 3600,
  "parts": [
    {
      "startS": 0,
      "endS": 1800
    },
    {
      "startS": 5400,
      "endS": 6000
    }
  ],
  "timeZone": "Asia/Tokyo"
}
```

`expected/blocks/exactly_gap_not_split.json`（77 バイト）:

```text
[
  [
    "2026-08-29T07:00:00+09:00",
    "2026-08-29T08:40:00+09:00"
  ]
]
```


`inputs/fingerprint.json` の `v4_example`:

```json
{
  "name": "v4_example",
  "base": "2026-08-29T07:12:04+09:00",
  "segments": [
    {
      "atMs": 0,
      "endMs": 3200,
      "text": "おはようございます。"
    },
    {
      "atMs": 9001,
      "endMs": 12999,
      "text": "今日は/\"x\""
    }
  ],
  "blocks": [
    {
      "startMs": 0,
      "endMs": 1800000
    }
  ],
  "timeZone": "Asia/Tokyo",
  "day": "2026-08-29"
}
```

`expected/fingerprint/v4_example.out`（358 バイト）:

```text
{"blocks":[["2026-08-29T07:12:04+09:00","2026-08-29T07:42:04+09:00"]],"segments":[{"at":"2026-08-29T07:12:04+09:00","end_at":"2026-08-29T07:12:07+09:00","text":"おはようございます。"},{"at":"2026-08-29T07:12:13+09:00","end_at":"2026-08-29T07:12:16+09:00","text":"今日は/\"x\""}]}
894a61422b5c95830fe8b36c33ae2c3af728851d00a5e02e9f691d61ad5fb86f
```


### 4.6 `GENERATED_BY.txt`

`generate.py` が最後に書く。1 行 1 項目の `key=value`、この順、末尾に改行、余分な行なし:

```text
voicedock_ref=d3d595e
voicedock_commit=d3d595ed217afdc89199633562d3003546a0f50e
python=3.12.13
unicodedata=15.0.0
uv=uv 0.12.15 (Homebrew 2026-09-15 aarch64-apple-darwin)
generator=tools/golden/generate.py
```

| キー | 値 |
|---|---|
| `voicedock_ref` | `d3d595e`（`generate.sh` の `VOICEDOCK_REF`） |
| `voicedock_commit` | `git rev-parse d3d595e^{commit}` の 40 桁 |
| `python` | 生成に使った Python の版（`sys.version` の最初の語。3.12.x） |
| `unicodedata` | `unicodedata.unidata_version`（Python 3.12 は `15.0.0`） |
| `uv` | `uv --version` の出力そのまま |
| `generator` | `tools/golden/generate.py` |

`GoldenInventoryTests.generatedByIsComplete` がキーの集合と値の形を検査する。`python`・`uv` の patch 版の違いで期待値は変わらない（違えば、それは voicedock の依存の違いであり、PR で理由を書く）。

### 4.7 作り直しの規則

- 期待値・入力・`GENERATED_BY.txt` を**手で直さない**。変えるときは `make_inputs.py`（ケース）か `generate.py`（呼び方）を直して `make golden` を実行し、生成物ごとコミットする
- ケースを足す・消すときは、使う側のチケットのテストが「そのグループの全ケース」を回すことを確かめる（使う側はケース名を列挙しない。`Golden.cases(group)` を使う）
- グループを足す・消す・改名するときは、`make_inputs.py` の `GROUPS`・`generate.py` の `handlers`・`GoldenInventoryTests.requiredGroups`・4.4 の表・使う側のチケットを同じ PR で直す
- 設定の上書きのキーを足すときは、`generate.py` の `ALLOWED_OVERRIDES`（か `SECTION_OVERRIDE`）と `Golden.allowedOverrideKeys`（か `overridableSections`・`overridableSectionFields`）を同じ PR で直す（`SECTIONS_WITHOUT_MAX_ITEMS` と `Golden.sectionsWithMaxItems` も同じ PR で）
- 本計画が voicedock と**意図して**違う振る舞い（PLAN の X-xx）は、golden を voicedock の出力のまま残し、差分を使う側のテストで別に固定する。例外は `llm_repair_prompt`（X-12 の雛形を `generate.py` の中で作る。voicedock の `repair_prompt` との前提の一致を生成時に確かめる）
- 期待値が変わった PR では、PR 本文に `git diff --stat Tests/Golden` と変わった理由を書く

### 4.8 `.gitattributes`

```gitattributes
# golden の期待値と Unicode のデータはバイト列のまま扱う（改行を変換しない。T-25）
Tests/Golden/** -text
tools/unicode/*.txt -text
```

### 4.9 生成ツール

#### `tools/golden/generate.sh`（全文。35 行）

実行権 0755（`git update-index --chmod=+x` まで行う）。

```bash
#!/bin/bash
# golden を voicedock@d3d595e から作り直す（PLAN §10.4、T-25）。
# voicedock の作業ツリーには触らない: git archive で一時ディレクトリへ展開し、その中でホストの uv を使う。
# 使い方: tools/golden/generate.sh   （環境変数 VOICEDOCK_REPO で voicedock の clone の場所を変えられる）
set -euo pipefail

VOICEDOCK_REPO="${VOICEDOCK_REPO:-/Users/terada/Projects/voicedock}"
VOICEDOCK_REF="d3d595e"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GOLDEN="$REPO_ROOT/Tests/Golden"

if ! command -v uv >/dev/null 2>&1; then
  echo "uv が見つかりません（https://docs.astral.sh/uv/ を入れてください）" >&2
  exit 1
fi
if ! git -C "$VOICEDOCK_REPO" cat-file -e "${VOICEDOCK_REF}^{commit}" 2>/dev/null; then
  echo "voicedock の clone に ${VOICEDOCK_REF} がありません: $VOICEDOCK_REPO" >&2
  exit 1
fi
COMMIT="$(git -C "$VOICEDOCK_REPO" rev-parse "${VOICEDOCK_REF}^{commit}")"
UV_VERSION="$(uv --version)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/voicedock-golden.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

git -C "$VOICEDOCK_REPO" archive --format=tar "$VOICEDOCK_REF" | tar -x -C "$WORK"
(cd "$WORK" && uv sync --frozen --python 3.12 --quiet)

(cd "$WORK" && uv run --frozen --python 3.12 python "$REPO_ROOT/tools/golden/make_inputs.py" "$GOLDEN")
rm -rf "$GOLDEN/expected"
mkdir -p "$GOLDEN/expected"
(cd "$WORK" && uv run --frozen --python 3.12 python "$REPO_ROOT/tools/golden/generate.py" \
  --voicedock-root "$WORK" --golden "$GOLDEN" --ref "$VOICEDOCK_REF" --commit "$COMMIT" \
  --uv-version "$UV_VERSION")
echo "golden を作り直しました: $GOLDEN"
```


#### `tools/golden/make_inputs.py`（全文。720 行）

ケースの定義の正。文字列の中の見えない文字・結合文字は必ず `\U000xxxxx` のエスケープで書き、生の文字をソースに置かない（レビューで見えないため）。

````python
#!/usr/bin/env python3
"""golden の入力 fixture（Tests/Golden/inputs/*.json）を作る（PLAN §10.4、T-25）。

**ケースの定義はこのファイルだけに書く。**inputs/*.json はこのファイルの出力であり、手で編集しない。
Swift のテストは inputs/*.json を読み、generate.py は inputs/*.json を読んで voicedock の関数で期待値を作る。

使い方: python3 tools/golden/make_inputs.py <Tests/Golden>
"""
from __future__ import annotations

import json
import sys
import unicodedata
from pathlib import Path

SCHEMA = 1
TZ = "Asia/Tokyo"
DAY = "2026-08-29"
SK = "DJIMIC3:20260829"
KA = "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"
KB = "DJIMIC3/TX_MIC001_20260829_074201/TX01_MIC002_20260829_074210_orig.wav"
BASE = "2026-08-29T07:12:04+09:00"


def seg(start_ms: int, end_ms: int, text: str) -> dict:
    """Part の started_at からのミリ秒で表した 1 区間（Raw ノート用）。"""
    return {"startMs": start_ms, "endMs": end_ms, "text": text}


def aseg(at_ms: int, end_ms: int, text: str) -> dict:
    """ケースの base からのミリ秒で表した絶対区間（統合結果・チャンク・指紋用）。"""
    return {"atMs": at_ms, "endMs": end_ms, "text": text}


def span(start_ms: int, end_ms: int) -> dict:
    return {"startMs": start_ms, "endMs": end_ms}


# --- keys --------------------------------------------------------------------
KEYS = [
    {"name": "partkey_fixed", "kind": "partkey", "deviceID": "DJIMIC3",
     "relpath": "TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"},
    {"name": "partkey_no_name", "kind": "partkey", "deviceID": "NO NAME",
     "relpath": "TX_MIC001_20260912_120950/TX00_MIC001_20260912_120950_orig.wav"},
    {"name": "partkey_root_file", "kind": "partkey", "deviceID": "DJIMIC3",
     "relpath": "TX01_MIC001_20260829_071204_orig.wav"},
    {"name": "session_fixed", "kind": "sessionKey", "deviceID": "DJIMIC3",
     "startedAt": "2026-08-29T07:12:04+09:00", "overflow": 1},
    {"name": "session_overflow2", "kind": "sessionKey", "deviceID": "DJIMIC3",
     "startedAt": "2026-08-29T07:12:04+09:00", "overflow": 2},
    {"name": "session_utc_input_converted", "kind": "sessionKey", "deviceID": "DJIMIC3",
     "startedAt": "2026-08-28T23:50:00+00:00", "overflow": 1},
    {"name": "session_late_night", "kind": "sessionKey", "deviceID": "DJIMIC3",
     "startedAt": "2026-08-29T23:50:00+09:00", "overflow": 1},
]

# --- sanitize ----------------------------------------------------------------
SANITIZE = [
    ("plain", "2026-08-29 raw", 180), ("colon", "{date}:raw", 180), ("slash_spaces", "  a / b  ", 180),
    ("dots_around", "..hidden..", 180), ("dots_inside", "a.b.c", 180), ("reserved_con", "con", 180),
    ("reserved_com1", "Com1", 180), ("reserved_lpt9_dot", "LPT9.", 180), ("reserved_nul_space", "NUL ", 180),
    ("console_not_reserved", "CONSOLE", 180), ("com10_not_reserved", "COM10", 180),
    ("hash_caret_brackets", "a#b^c[d]e", 180), ("wikilink", "[[Note]]", 180), ("tab_del", "tab\there\x7f", 180),
    ("empty", "", 180), ("spaces_only", "   ", 180), ("dots_only", "...", 180), ("hashes_only", "###", 180),
    ("controls_only", "\x00\x01", 180), ("brackets_only", "[[]]", 180), ("nfd_to_nfc", "か\U00003099", 180),
    ("combining_tail", "q\U00000301", 180), ("japanese_70", "あ" * 70, 180), ("japanese_80", "あ" * 80, 180),
    ("ascii_180_bytes", "a" * 178 + "é", 180), ("ascii_181_bytes", "a" * 179 + "é", 180),
    ("fullwidth_spaces", "x\U00003000\U00003000y", 180), ("forbidden_chars", "a|b<c>d*e?f\"g\\h", 180),
    ("nbsp_zwsp", "a\U000000a0b\U0000200bc", 180), ("e_acute_100", "é" * 100, 180), ("ga_5_max7", "が" * 5, 7),
    ("ga_5_max4", "が" * 5, 4), ("con_max3", "CON", 3), ("c1_nel", "a\U00000085b", 180), ("fs_x1c", "a\x1cb", 180),
    ("line_separator", "a\U00002028b", 180), ("tabs_inside", "a\t\tb", 180), ("spaces_inside", "  a   b  ", 180),
]

# --- frontmatter -------------------------------------------------------------
# 値は型付きの配列で表す: ["s", 文字列] / ["i", 整数] / ["b", 真偽] / ["n"] / ["a", [文字列…]]
FRONTMATTER = [
    {"name": "all_types", "kind": "render", "fields": [
        ["s", ["s", "text"]], ["i", ["i", 3]], ["b", ["b", True]], ["f", ["b", False]], ["n", ["n"]],
        ["e", ["a", []]], ["l", ["a", ["x", "y\""]]]]},
    {"name": "special_chars", "kind": "render", "fields": [
        ["s", ["s", "a\"b\\c\x01d\x7fe\U00000085f\U00002028g"]], ["colon", ["s", "a: b #c"]],
        ["jp", ["s", "日本語"]], ["empty", ["s", ""]]]},
    {"name": "raw_like", "kind": "render", "fields": [
        ["type", ["s", "voice-raw"]], ["voicedock_session_key", ["s", SK]],
        ["voicedock_recording_keys", ["a", [KA, KB]]], ["date", ["s", DAY]], ["parts", ["i", 2]],
        ["source", ["s", "DJI Mic 3"]]]},
    {"name": "quote_plain", "kind": "quote", "text": "abc"},
    {"name": "quote_escapes", "kind": "quote", "text": "a\"b\\c\x00\x1f\x7f\U00000085"},
    {"name": "escape_lines", "kind": "escapeBody", "text": "---\na\n --- \n----x\n"},
    {"name": "escape_crlf", "kind": "escapeBody", "text": "a\r\n---\r\nx\r---\n"},
    {"name": "escape_none", "kind": "escapeBody", "text": "no dashes here\n"},
    {"name": "split_ok", "kind": "split", "text": "---\na: 1\n---   \nbody\n"},
    {"name": "split_no_frontmatter", "kind": "split", "text": "a: 1\n---\n"},
    {"name": "split_unclosed", "kind": "split", "text": "---\na: 1\n"},
    {"name": "split_empty_front", "kind": "split", "text": "---\n---\nbody"},
]

# --- raw_note ----------------------------------------------------------------
PA = {"partkey": KA, "startedAt": "2026-08-29T07:12:04+09:00", "endedAt": "2026-08-29T07:42:04+09:00",
      "segments": [seg(0, 10000, "おはようございます。"),
                   seg(300000, 310000, "削除条件を整理します。")]}
PB = {"partkey": KB, "startedAt": "2026-08-29T07:42:10+09:00", "endedAt": "2026-08-29T08:12:10+09:00",
      "segments": [seg(0, 10000, "続きです。")]}
RAW_NOTE = [
    {"name": "two_parts_reordered", "overrides": {}, "parts": [PB, PA]},
    {"name": "no_end", "overrides": {}, "parts": [
        {"partkey": KA, "startedAt": "2026-08-29T07:12:04+09:00", "endedAt": None, "segments": [
            seg(0, 10000, "  x  "), seg(56000, 60000, "   "), seg(60000, 70000, "---"),
            seg(359000, 360000, "y"), seg(360000, 361000, "z")]}]},
    {"name": "no_headings", "overrides": {"obsidian.raw.timestampIntervalSeconds": 0,
                                          "obsidian.raw.partBoundaryHeading": False}, "parts": [PA, PB]},
    {"name": "empty", "overrides": {}, "parts": []},
    {"name": "part_without_text", "overrides": {}, "parts": [
        PA, {"partkey": KB, "startedAt": "2026-08-29T07:42:10+09:00", "endedAt": "2026-08-29T08:12:10+09:00",
             "segments": [seg(0, 10000, "   ")]}]},
    {"name": "two_minute_segments", "overrides": {}, "parts": [
        {"partkey": KA, "startedAt": "2026-08-29T07:00:00+09:00", "endedAt": "2026-08-29T07:20:00+09:00",
         "segments": [seg(i * 120000, i * 120000 + 5000, f"発話{i}") for i in range(10)]}]},
    {"name": "boundary_exactly_300s", "overrides": {}, "parts": [
        {"partkey": KA, "startedAt": "2026-08-29T07:00:00+09:00", "endedAt": "2026-08-29T07:30:00+09:00",
         "segments": [seg(0, 1000, "a"), seg(299999, 300000, "b"), seg(300000, 301000, "c"),
                      seg(599999, 600000, "d"), seg(600001, 601000, "e")]}]},
    {"name": "subsecond_heading_truncated", "overrides": {}, "parts": [
        {"partkey": KA, "startedAt": "2026-08-29T07:00:00+09:00", "endedAt": "2026-08-29T07:10:00+09:00",
         "segments": [seg(999, 2000, "a"), seg(301999, 302500, "b")]}]},
    {"name": "dst_fixed_offset", "timeZone": "America/New_York", "day": "2026-03-08",
     "sessionKey": "DJIMIC3:20260308", "overrides": {}, "parts": [
        {"partkey": "DJIMIC3/TX_MIC001_20260308_013000/TX01_MIC002_20260308_013000_orig.wav",
         "startedAt": "2026-03-08T01:30:00-05:00", "endedAt": "2026-03-08T03:30:00-05:00",
         "segments": [seg(0, 5000, "before"), seg(2400000, 2405000, "after")]}]},
]

NOTE_FILENAME = [
    {"name": "raw_default", "kind": "raw", "overrides": {}},
    {"name": "raw_colon_template", "kind": "raw", "overrides": {"obsidian.raw.filenameTemplate": "{date}:raw"}},
    {"name": "raw_all_placeholders", "kind": "raw",
     "overrides": {"obsidian.raw.filenameTemplate": "{yyyymmdd}-{date}-{time}"}},
    {"name": "raw_max_bytes_5", "kind": "raw", "overrides": {"obsidian.maxTitleBytes": 5}},
    {"name": "daily_default", "kind": "daily", "overrides": {}},
    {"name": "daily_custom", "kind": "daily", "day": "2026-01-02",
     "overrides": {"obsidian.wiki.filenameTemplate": "{yyyymmdd} 声"}},
    {"name": "raw_folder_default", "kind": "rawFolder", "overrides": {}},
    {"name": "daily_folder_default", "kind": "dailyFolder", "overrides": {}},
]

# --- daily_note --------------------------------------------------------------
ANALYSIS_FULL = {
    "title": "開発と打ち合わせの一日",
    "summary": "VoiceDock の削除条件を整理した。午後に MVP の範囲を確定した。",
    "key_points": ["削除の根拠をテキストの保全に置く"],
    "tasks": [{"text": "DJI Mic 3 のマウント構造を確認する", "due": None},
              {"text": "Whisper の速度を実測する", "due": "2026-09-05"}],
    "decisions": ["MVP では GUI を作らない"],
    "ideas": ["将来的に話者識別を追加する"],
    "tags": ["VoiceDock", "DJI Mic", "a: b", "c \"d\"", "e\\f", "  ", "全角\U00003000空白"],
}
ANALYSIS_MIN = {"title": "題", "summary": "一文目。二文目。", "key_points": [],
                "tasks": [], "decisions": [], "ideas": [], "tags": []}
LINKS_FULL = {"dailyNote": "[[2026-08-29]]", "adjacent": ["[[2026-08-28 Voice]]", "[[2026-08-30 Voice]]"],
              "tags": ["[[VoiceDock]]", "#DJI-Mic"], "raw": ["[[2026-08-29 raw]]"]}
LINKS_RAW_ONLY = {"dailyNote": None, "adjacent": [], "tags": [], "raw": ["[[2026-08-29 raw]]"]}
LINKS_EMPTY = {"dailyNote": None, "adjacent": [], "tags": [], "raw": []}
TL_FULL = {"base": "2026-08-29T07:12:00+09:00", "blocks": [
    {"startMs": 0, "endMs": 4 * 3600000, "lines": ["朝の移動中に整理した", "二点目"]},
    {"startMs": 6 * 3600000, "endMs": 12 * 3600000, "lines": ["MVP を確定した"]}]}
TL_EMPTY = {"base": BASE, "blocks": []}
EX_F = {"partkey": "DJIMIC3/F/f_orig.wav", "status": "FAILED", "errorCode": "WHISPER_FAILED"}
EX_NS = {"partkey": "DJIMIC3/S/s1_orig.wav", "status": "SKIPPED", "errorCode": "NO_SPEECH_DETECTED"}
EX_DUP = {"partkey": "DJIMIC3/S/s2_orig.wav", "status": "SKIPPED", "errorCode": "DUPLICATE_CONTENT"}
EX_SM = {"partkey": "DJIMIC3/S/s3_orig.wav", "status": "SKIPPED", "errorCode": "SOURCE_MISSING"}
EX_NULL = {"partkey": "DJIMIC3/S/s4_orig.wav", "status": "SKIPPED", "errorCode": None}
EX_UNKNOWN = {"partkey": "DJIMIC3/S/s5_orig.wav", "status": "SKIPPED", "errorCode": "LLM_FAILED"}
EX_NM = {"partkey": "DJIMIC3/S/s6_orig.wav", "status": "SKIPPED", "errorCode": "NORMALIZED_MISSING"}


def daily(name: str, **kw) -> dict:
    case = {"name": name, "overrides": {}, "analysis": ANALYSIS_FULL, "recordingKeys": [KA, KB], "excluded": [],
            "recordedSeconds": 34880.9, "blockCount": 2, "timeline": TL_FULL, "links": LINKS_FULL}
    case.update(kw)
    return case


DAILY_NOTE = [
    daily("full", excluded=[EX_F, EX_NS, EX_DUP]),
    daily("minimal", analysis=ANALYSIS_MIN, recordingKeys=[], excluded=[EX_SM, EX_NULL, EX_UNKNOWN],
          recordedSeconds=None, blockCount=0, timeline=TL_EMPTY, links=LINKS_EMPTY),
    daily("no_warnings"),
    daily("failed_only", excluded=[EX_F]),
    daily("skipped_no_speech", excluded=[EX_NS]),
    daily("skipped_dup_and_no_speech_reversed", excluded=[EX_NS, EX_DUP]),
    daily("skipped_actionable_mixed", excluded=[EX_DUP, EX_SM]),
    daily("skipped_missing_both_codes", excluded=[EX_NM, EX_SM]),
    daily("failed_and_skipped_null", excluded=[EX_NULL, EX_F]),
    daily("raw_link_only", links=LINKS_RAW_ONLY),
    daily("no_links", links=LINKS_EMPTY),
    daily("empty_sections", analysis={"title": "空の節", "summary": "要約だけ。",
                                      "key_points": [], "tasks": [], "decisions": [], "ideas": [], "tags": []}),
    daily("order_custom", overrides={"llm.analysis.order": ["summary", "key_points", "timeline"]}),
    daily("ideas_disabled", overrides={"llm.analysis.sections.ideas.enabled": False},
          analysis={k: v for k, v in ANALYSIS_FULL.items() if k != "ideas"}),
    daily("headings_custom", overrides={"llm.analysis.sections.summary.heading": "### 要約",
                                        "llm.analysis.sections.tasks.heading": "## やること"}),
    daily("recorded_over_24h", recordedSeconds=90061.7),
    daily("recorded_negative", recordedSeconds=-5.0),
    daily("body_dashes", analysis={"title": "---題", "summary": "---区切り\n---次",
                                   "key_points": ["---点"], "tasks": [], "decisions": [], "ideas": [], "tags": []}),
    daily("default_tags_custom", overrides={"obsidian.defaultTags": ["Voice", "録音", "voice"]}),
    daily("timeline_empty", timeline=TL_EMPTY),
]

DAILY_PARTS = [
    {"name": "recorded_values", "kind": "recorded",
     "inputs": [None, -1.0, 0.0, 59.999, 60.0, 3599.9, 3600.0, 34880.9, 90061.7, 360000.0]},
    {"name": "tags_adversarial", "kind": "tags", "defaults": ["voice", "voicedock"],
     "tags": ["VoiceDock", "DJI Mic", "a: b", "c \"d\"", "e\\f", "  ", "全角\U00003000空白",
              "Straße", "STRASSE"]},
    {"name": "tags_missing", "kind": "tags", "defaults": ["voice", "voicedock"], "tags": None},
    {"name": "tags_defaults_dup", "kind": "tags", "defaults": ["Voice", "voice", " x "], "tags": ["X"]},
    {"name": "warnings_cases", "kind": "warnings", "sets": [
        [], [EX_F], [EX_F, EX_F], [EX_NS], [EX_DUP, EX_NS], [EX_SM], [EX_NULL], [EX_UNKNOWN], [EX_NM, EX_SM],
        [EX_F, EX_NS, EX_SM]]},
    {"name": "sentences_cases", "kind": "sentences", "inputs": [
        "", "A。B。 C", "一文目。二文目。\n三文目 。 \n\n四",
        "。。", "no period", "a\U00002028b。c\x1cd"]},
]

# --- timeline ----------------------------------------------------------------
TL_TRANSCRIPT = {
    "segments": [aseg(0, 3200, "一"), aseg(600000, 610000, "二"),
                 aseg(3 * 3600000, 3 * 3600000 + 5000, "三")],
    "blocks": [span(0, 1800000), span(3 * 3600000, 3 * 3600000 + 5000)]}
TIMELINE = [
    {"name": "single_pass_blocks", "base": BASE, "fingerprint": "fp1", "transcript": TL_TRANSCRIPT,
     "summary": "A。B。 C", "partials": [], "chunks": []},
    {"name": "single_pass_fallback_block", "base": BASE, "fingerprint": "fp2",
     "transcript": {"segments": TL_TRANSCRIPT["segments"], "blocks": []},
     "summary": "午前に作業した。午後に会議。", "partials": [], "chunks": []},
    {"name": "single_pass_empty_summary", "base": BASE, "fingerprint": "fp3", "transcript": TL_TRANSCRIPT,
     "summary": "", "partials": [], "chunks": []},
    {"name": "single_pass_no_segments", "base": BASE, "fingerprint": "fp4",
     "transcript": {"segments": [], "blocks": []}, "summary": "A。", "partials": [], "chunks": []},
    {"name": "map_reduce", "base": BASE, "fingerprint": "fp5", "transcript": TL_TRANSCRIPT, "summary": "全体。",
     "partials": [{"summary": "朝。", "key_points": ["点1", "点2"]},
                  {"summary": "X。Y。", "key_points": []}, {"summary": " ", "key_points": []}],
     "chunks": [span(0, 600000), span(600000, 1200000), span(1200000, 1800000)]},
    {"name": "map_reduce_zip_short", "base": BASE, "fingerprint": "fp6", "transcript": TL_TRANSCRIPT,
     "summary": "全体。",
     "partials": [{"summary": "a。", "key_points": []}, {"summary": "b。", "key_points": []},
                  {"summary": "c。", "key_points": []}], "chunks": [span(0, 1000), span(1000, 2000)]},
    {"name": "partials_without_chunks", "base": BASE, "fingerprint": "fp7", "transcript": TL_TRANSCRIPT,
     "summary": "単一。", "partials": [{"summary": "a。", "key_points": []}], "chunks": []},
    {"name": "escapes_in_lines", "base": BASE, "fingerprint": "fp8", "transcript": TL_TRANSCRIPT,
     "summary": "引用\"と\\と/。改行\tタブ。", "partials": [], "chunks": []},
]

TIMELINE_DECODE = [
    {"name": "valid", "fingerprint": "abc", "document":
        '{"schema": 2, "transcript_sha256": "abc", "blocks": [{"start_at": "2026-08-29T07:12:04+09:00", '
        '"end_at": "2026-08-29T07:42:04+09:00", "lines": ["a", "b"]}]}'},
    {"name": "wrong_schema", "fingerprint": "abc",
     "document": '{"schema": 1, "transcript_sha256": "abc", "blocks": []}'},
    {"name": "wrong_fingerprint", "fingerprint": "abc", "document":
        '{"schema": 2, "transcript_sha256": "xyz", "blocks": [{"start_at": "2026-08-29T07:12:04+09:00", '
        '"end_at": "2026-08-29T07:42:04+09:00", "lines": ["a"]}]}'},
    {"name": "bad_elements_skipped", "fingerprint": "abc", "document":
        '{"schema": 2, "transcript_sha256": "abc", "blocks": [1, {"start_at": "x", '
        '"end_at": "2026-08-29T07:42:04+09:00", "lines": []}, {"start_at": "2026-08-29T07:12:04+09:00", '
        '"end_at": "2026-08-29T07:42:04+09:00", "lines": "a"}, {"start_at": "2026-08-29T08:00:00+09:00", '
        '"end_at": "2026-08-29T09:00:00+09:00", "lines": ["ok", 3]}, {"end_at": "2026-08-29T09:00:00+09:00", '
        '"lines": []}]}'},
    {"name": "not_object", "fingerprint": "abc", "document": "[1, 2]"},
    {"name": "not_json", "fingerprint": "abc", "document": "{"},
    {"name": "blocks_not_list", "fingerprint": "abc",
     "document": '{"schema": 2, "transcript_sha256": "abc", "blocks": {}}'},
]

# --- wiki ----------------------------------------------------------------------
WIKI = [
    {"name": "normalize_names", "kind": "normalize",
     "inputs": ["VoiceDock", "Straße", "STRASSE", "İ", "ﬁle", "ΣΑΣ", "か\U00003099",
                "ＡＢＣ"]},
    {"name": "plan_basic", "kind": "plan", "overrides": {},
     "tags": ["VoiceDock", "none", "a#b", "2026-08-29 Voice"], "indexNames": ["voicedock"],
     "rawNames": ["2026-08-29 raw"]},
    {"name": "plan_max_links_2", "kind": "plan", "overrides": {"obsidian.wiki.maxLinks": 2},
     "tags": ["VoiceDock"], "indexNames": ["VoiceDock"], "rawNames": ["2026-08-29 raw"]},
    {"name": "plan_max_links_0", "kind": "plan", "overrides": {"obsidian.wiki.maxLinks": 0},
     "tags": ["VoiceDock"], "indexNames": ["VoiceDock"], "rawNames": ["2026-08-29 raw"]},
    {"name": "plan_link_tags_false", "kind": "plan", "overrides": {"obsidian.wiki.linkTags": False},
     "tags": ["VoiceDock"], "indexNames": None, "rawNames": ["2026-08-29 raw"]},
    {"name": "plan_link_only_existing_false", "kind": "plan", "overrides": {"obsidian.wiki.linkOnlyExisting": False},
     "tags": ["VoiceDock", "新しい"], "indexNames": [], "rawNames": []},
    {"name": "plan_no_daily_no_adjacent", "kind": "plan",
     "overrides": {"obsidian.wiki.linkDailyNote": False, "obsidian.wiki.linkAdjacentDays": False},
     "tags": ["VoiceDock"], "indexNames": ["voicedock"], "rawNames": ["2026-08-29 raw"]},
    {"name": "plan_index_null", "kind": "plan", "overrides": {}, "tags": ["VoiceDock", " "],
     "indexNames": None, "rawNames": []},
    {"name": "plan_casefold_match", "kind": "plan", "overrides": {}, "tags": ["STRASSE", "ǅ"],
     "indexNames": ["straße", "ǆ"], "rawNames": []},
    {"name": "plan_month_boundary", "kind": "plan", "day": "2026-03-01", "overrides": {}, "tags": [],
     "indexNames": [], "rawNames": ["2026-03-01 raw (2)"]},
    {"name": "plan_bad_raw_name", "kind": "plan", "overrides": {}, "tags": [],
     "indexNames": [], "rawNames": ["a|b", "2026-08-29 raw"]},
    {"name": "index_tree", "kind": "buildIndex", "overrides": {}, "files": [
        "Top.md", "Notes/VoiceDock.md", "Notes/deep/Straße.md", "Notes/UPPER.MD", "Notes/readme.txt",
        ".obsidian/workspace.md", "Notes/.hidden.md", ".trash/old.md",
        "Daily/Voice/Raw/20260829/2026-08-29 raw.md", "Daily/Voice/Rawish/keep.md",
        "Daily/Voice/Wiki/20260829/2026-08-29 Voice.md"],
     "symlinkDirs": [["linked", "Notes"]]},
    {"name": "raw_prefix_default", "kind": "rawPrefix", "overrides": {}},
    {"name": "raw_prefix_no_brace", "kind": "rawPrefix", "overrides": {"obsidian.raw.folderTemplate": "Raw/Notes/"}},
    {"name": "raw_prefix_brace_first", "kind": "rawPrefix",
     "overrides": {"obsidian.raw.folderTemplate": "{yyyymmdd}/raw"}},
]

# --- llm -----------------------------------------------------------------------
LLM_SCHEMA_BLOCK = [
    {"name": "final_default", "partial": False, "overrides": {}},
    {"name": "partial_default", "partial": True, "overrides": {}},
    {"name": "final_tags_ideas_disabled", "partial": False,
     "overrides": {"llm.analysis.sections.tags.enabled": False, "llm.analysis.sections.ideas.enabled": False}},
    {"name": "final_maxitems_null", "partial": False,
     "overrides": {"llm.analysis.sections.key_points.maxItems": None}},
    {"name": "partial_tasks_disabled", "partial": True, "overrides": {"llm.analysis.sections.tasks.enabled": False}},
]
LLM_PROMPT = [
    {"name": "analyze_default", "kind": "analyze", "overrides": {}},
    {"name": "analyze_custom", "kind": "analyze",
     "overrides": {"llm.analysis.customInstructions": "健康の話題は要約しない"}},
    {"name": "map_default", "kind": "map", "overrides": {}},
    {"name": "map_custom_multiline", "kind": "map",
     "overrides": {"llm.analysis.customInstructions": "一行目\n二行目"}},
    {"name": "reduce_default", "kind": "reduce", "overrides": {}},
    {"name": "analyze_custom_contains_placeholder", "kind": "analyze",
     "overrides": {"llm.analysis.customInstructions": "{schema_block} は置換しない"}},
]
LLM_REPAIR_PROMPT = [
    {"name": "divergent_final", "partial": False, "overrides": {}, "errors": "- summary: Field required",
     "previousOutput": "{\"title\": \"t\"}"},
    {"name": "divergent_partial", "partial": True, "overrides": {},
     "errors": "- title: Extra inputs are not permitted", "previousOutput": "{\"title\": \"t\", \"summary\": \"s\"}"},
    {"name": "divergent_placeholders_in_output", "partial": False, "overrides": {},
     "errors": "応答から JSON を抽出できませんでした",
     "previousOutput": "{schema_block} {errors} {previous_output}"},
]
LLM_VALIDATE = [
    {"name": n, "partial": p, "overrides": {}, "payload": v} for n, p, v in [
        ("ok_minimal", False, {"title": "t", "summary": "s"}),
        ("ok_full", False, {"title": "t", "summary": "s", "key_points": ["a"], "tasks": [{"text": "x", "due": None}],
                            "decisions": [], "ideas": [], "tags": ["t"]}),
        ("missing_summary", False, {"title": "t"}),
        ("missing_both", False, {}),
        ("extra", False, {"title": "t", "summary": "s", "mood": "x"}),
        ("empty_summary", False, {"title": "t", "summary": ""}),
        ("wrong_list", False, {"title": "t", "summary": "s", "key_points": "文字列"}),
        ("list_item_type", False, {"title": "t", "summary": "s", "key_points": ["a", 1]}),
        ("task_missing_text", False, {"title": "t", "summary": "s", "tasks": [{"due": None}]}),
        ("task_not_dict", False, {"title": "t", "summary": "s", "tasks": ["x"]}),
        ("task_extra", False, {"title": "t", "summary": "s", "tasks": [{"text": "a", "x": 1}]}),
        ("task_due_int", False, {"title": "t", "summary": "s", "tasks": [{"text": "a", "due": 3}]}),
        ("task_due_missing_ok", False, {"title": "t", "summary": "s", "tasks": [{"text": "a"}]}),
        ("task_text_empty", False, {"title": "t", "summary": "s", "tasks": [{"text": ""}]}),
        ("task_text_long", False, {"title": "t", "summary": "s", "tasks": [{"text": "あ" * 501}]}),
        ("title_int", False, {"title": 5, "summary": "s"}),
        ("title_bool", False, {"title": True, "summary": "s"}),
        ("title_too_long", False, {"title": "あ" * 121, "summary": "s"}),
        ("summary_null", False, {"title": "t", "summary": None}),
        ("list_null", False, {"title": "t", "summary": "s", "tags": None}),
        ("multi_order", False, {"mood": 1, "summary": 3, "tags": [1], "zzz": 2}),
        ("partial_with_title_tags", True, {"title": "t", "summary": "s", "tags": ["a"]}),
        ("partial_ok", True, {"summary": "s", "key_points": ["a"]}),
    ]
]
LLM_TRIM = [
    {"name": "trim_all", "partial": False, "overrides": {}, "payload": {
        "title": "あ" * 121, "summary": "s", "tags": [f"t{i}" for i in range(20)],
        "key_points": [f"k{i}" for i in range(25)]}},
    {"name": "trim_exact_limits", "partial": False, "overrides": {}, "payload": {
        "title": "a" * 120, "summary": "s", "tags": [f"t{i}" for i in range(15)]}},
    {"name": "trim_task_text_not_cut", "partial": False, "overrides": {}, "payload": {
        "title": "t", "summary": "s", "tasks": [{"text": "a" * 501, "due": None}]}},
    {"name": "trim_maxitems_null", "partial": False, "overrides": {"llm.analysis.sections.key_points.maxItems": None},
     "payload": {"title": "t", "summary": "s", "key_points": [str(i) for i in range(40)]}},
    {"name": "trim_non_list_ignored", "partial": False, "overrides": {}, "payload": {
        "title": 5, "summary": "s", "tags": "x" * 30}},
]
LLM_EXTRACT = [
    {"name": n, "text": t} for n, t in [
        ("think_prefix", '<think>x</think> {"a":1}'), ("fence_json", '```json\n{"a":1}\n```'),
        ("brace_in_string", 'pre {"a":"}"} post'), ("array_then_object", '[{"a":1}]'),
        ("unclosed_think", '<think>{"a":1}'), ("fence_not_json_then_object", '```\nnot json\n```\n{"b":2}'),
        ("two_fences", '```json\n[1]\n```\n```json\n{"c":3}\n```'), ("plain", '{"x": [1, 2], "y": "z"}'),
        ("escaped_quote", 'noise {"a": "q\\"}"} tail'), ("nothing", "no json here"), ("empty", ""),
        ("think_multiline", '<think>\n{"no":1}\n</think>\n{"yes": true}'), ("nested", '{"a": {"b": {"c": [1]}}}'),
        ("whitespace", '\U00003000 {"a": 1} \U00003000'),
    ]
]
LLM_STRIP_THINK = [
    {"name": n, "text": t} for n, t in [
        ("closed", "<think>x</think>rest"), ("two", "<think>a</think>b<think>c</think>d"),
        ("unclosed", "a<think>b"), ("multiline", "<think>\nx\n</think>\ny"), ("none", "plain"),
    ]
]


def limits(max_chars: int, overlap: int, max_seconds: int) -> dict:
    return {"llm.maxCharsPerRequest": max_chars, "llm.chunkOverlapChars": overlap, "llm.maxSecondsPerRequest": max_seconds}


LLM_CHUNKS = [
    {"name": "v4_example", "base": BASE, "overrides": limits(10, 4, 3600),
     "segments": [aseg(0, 5000, "aaa"), aseg(10000, 15000, "bbb"), aseg(20000, 25000, "ccc"),
                  aseg(30000, 35000, "dd"), aseg(40000, 45000, "eeeee"), aseg(5000000, 5005000, "ff")]},
    {"name": "time_cut_no_overlap", "base": BASE, "overrides": limits(100, 4, 60),
     "segments": [aseg(0, 5000, "a"), aseg(30000, 35000, "b"), aseg(60000, 65000, "c"), aseg(70000, 75000, "d")]},
    {"name": "both_exceeded_no_overlap", "base": BASE, "overrides": limits(5, 2, 60),
     "segments": [aseg(0, 5000, "aaa"), aseg(100000, 105000, "bbb")]},
    {"name": "overlap_takes_at_least_one", "base": BASE, "overrides": limits(10, 1, 3600),
     "segments": [aseg(0, 1000, "aaaa"), aseg(1000, 2000, "bbbbb"), aseg(2000, 3000, "cc")]},
    {"name": "overlap_whole_drops_first", "base": BASE, "overrides": limits(6, 2, 3600),
     "segments": [aseg(0, 1000, "a"), aseg(1000, 2000, "b"), aseg(2000, 3000, "ccccc")]},
    {"name": "single_over_limit", "base": BASE, "overrides": limits(3, 1, 3600),
     "segments": [aseg(0, 1000, "abcdef"), aseg(1000, 2000, "g")]},
    {"name": "multibyte_counts_scalars", "base": BASE, "overrides": limits(5, 2, 3600),
     "segments": [aseg(0, 1000, "あいう"), aseg(1000, 2000, "えお"), aseg(2000, 3000, "か")]},
    {"name": "empty", "base": BASE, "overrides": {}, "segments": []},
    {"name": "default_limits_one_chunk", "base": BASE, "overrides": {},
     "segments": [aseg(0, 1000, "一"), aseg(3000000, 3001000, "二")]},
]
LLM_DEDUPE = [
    {"name": "keys", "kind": "key", "inputs": [" VoiceDock ", "ＶｏｉｃｅＤｏｃｋ",
                                               "ﾃｽﾄ", "Straße", "ﬁle", "ΣΑΣ",
                                               "\U00003000全角空白\U00003000", "\x1cX\x1f", "\U0000200bX", "が",
                                               "か\U00003099"]},
    {"name": "values_first_wins", "kind": "values",
     "inputs": ["A", "a", " A ", "Ａ", "b", "B", "Straße", "STRASSE"]},
    {"name": "result_all_fields", "kind": "result", "overrides": {}, "payload": {
        "title": "t", "summary": "s", "key_points": ["x", "X"],
        "tasks": [{"text": "やる", "due": None}, {"text": " やる ", "due": "2026-09-01"}],
        "decisions": ["d"], "ideas": ["i", "I", "j"], "tags": ["Tag", "tag"]}},
    {"name": "result_empty_lists", "kind": "result", "overrides": {}, "payload": {"title": "t", "summary": "s"}},
]
LLM_AS_JSON = [
    {"name": "escapes_partial", "overrides": {}, "partials": [
        {"summary": "朝/昼\n\"引用\"\t\\\x01", "key_points": ["a"], "tasks": [{"text": "x"}]}]},
    {"name": "two_partials", "overrides": {}, "partials": [{"summary": "s0"}, {"summary": "s1", "ideas": ["i"]}]},
    {"name": "ideas_disabled", "overrides": {"llm.analysis.sections.ideas.enabled": False},
     "partials": [{"summary": "s"}]},
]
LLM_BUNDLES = [
    {"name": "limit_120", "limit": 120, "overrides": {}, "partials": [{"summary": f"s{i}"} for i in range(5)]},
    {"name": "limit_300", "limit": 300, "overrides": {}, "partials": [{"summary": f"s{i}"} for i in range(5)]},
    {"name": "single_oversized", "limit": 10, "overrides": {}, "partials": [{"summary": "long" * 10}, {"summary": "x"}]},
]
ANALYSIS_JSON = [
    {"name": "minimal", "overrides": {}, "payload": {"title": "t", "summary": "s"}},
    {"name": "task_due", "overrides": {}, "payload": {"title": "t", "summary": "s",
                                                      "tasks": [{"text": "x", "due": "2026-09-20"}, {"text": "y"}]}},
    {"name": "tags_disabled", "overrides": {"llm.analysis.sections.tags.enabled": False},
     "payload": {"title": "t", "summary": "s"}},
    {"name": "escapes", "overrides": {}, "payload": {"title": "題/\"x\"", "summary": "改行\nタブ\t\x01",
                                                     "ideas": ["é"]}},
]

# --- transcript / numbers / fingerprint / blocks ------------------------------------
TRANSCRIPT_JSON = [
    {"name": "v4_example", "partkey": KA, "startedAt": BASE, "durationSeconds": 1800.0, "fallbackLanguage": "ja",
     "whisper": {"result": {"language": "ja"}, "transcription": [
         {"offsets": {"from": 0, "to": 3200}, "text": " おはようございます。"},
         {"offsets": {"from": 5500, "to": 9000}, "text": "  "},
         {"offsets": {"from": 9001, "to": 12345}, "text": " 今日は。"},
         {"offsets": {"from": True, "to": 1}, "text": "bool"},
         {"offsets": {"from": 1.5, "to": 2}, "text": "float"}]}},
    {"name": "empty", "partkey": "k", "startedAt": BASE, "durationSeconds": None, "fallbackLanguage": "ja",
     "whisper": {"transcription": []}},
    {"name": "language_fallback", "partkey": KA, "startedAt": BASE, "durationSeconds": 12.5, "fallbackLanguage": "ja",
     "whisper": {"result": {"language": ""}, "transcription": [{"offsets": {"from": 0, "to": 1000}, "text": "a"}]}},
    {"name": "language_en", "partkey": KA, "startedAt": BASE, "durationSeconds": 3.0, "fallbackLanguage": "ja",
     "whisper": {"result": {"language": "en"}, "transcription": [{"offsets": {"from": 0, "to": 1000}, "text": " hi "}]}},
    {"name": "not_object", "partkey": KA, "startedAt": BASE, "durationSeconds": None, "fallbackLanguage": "ja",
     "whisper": [1, 2]},
    {"name": "bad_entries", "partkey": KA, "startedAt": BASE, "durationSeconds": 10.0, "fallbackLanguage": "ja",
     "whisper": {"transcription": [1, {"offsets": [0, 1], "text": "x"}, {"offsets": {"from": 0}, "text": "y"},
                                   {"offsets": {"from": 0, "to": 10}, "text": 5},
                                   {"offsets": {"from": "0", "to": 10}, "text": "z"},
                                   {"offsets": {"from": 1234, "to": 5678}, "text": "\U00003000ok\U00003000"}]}},
    {"name": "rounding_ms", "partkey": KA, "startedAt": BASE, "durationSeconds": 7200.0, "fallbackLanguage": "ja",
     "whisper": {"transcription": [{"offsets": {"from": 1, "to": 999}, "text": "a"},
                                   {"offsets": {"from": 1234567, "to": 7199999}, "text": "b"},
                                   {"offsets": {"from": 0.4, "to": 0.6}, "text": "c"}]}},
    {"name": "escapes_text", "partkey": KA, "startedAt": BASE, "durationSeconds": 1.0, "fallbackLanguage": "ja",
     "whisper": {"transcription": [{"offsets": {"from": 0, "to": 500}, "text": " \"引用\"\\/\t"}]}},
]
NUMBERS = [
    {"name": "whisper_num", "kind": "num", "inputs": [0.5, 1.0, 0.25, 2.0, 0.1, 0.0, 250.0, 1000.0, 0.35]},
    {"name": "whisper_timeout", "kind": "whisperTimeout", "inputs": [None, 10, 199.9, 200, 1800, 7200, 1e9, 0, 200.4]},
    {"name": "convert_timeout", "kind": "convertTimeout", "inputs": [None, 100, 360, 361, 1800.7, 0, 1e6]},
    {"name": "expected_bytes", "kind": "expectedBytes", "inputs": [None, 0, 1.5, 1800, 1800.99999, -5]},
]
FINGERPRINT = [
    {"name": "v4_example", "base": BASE,
     "segments": [aseg(0, 3200, "おはようございます。"),
                  aseg(9001, 12999, "今日は/\"x\"")],
     "blocks": [span(0, 1800000)]},
    {"name": "empty", "base": BASE, "segments": [], "blocks": []},
    {"name": "escapes_and_blocks", "base": BASE,
     "segments": [aseg(0, 1000, "a\nb\t\x01"), aseg(3600000, 3601000, "é\U0001d11e")],
     "blocks": [span(0, 1000), span(3600000, 3601000)]},
]
BLOCKS = [
    {"name": n, "base": "2026-08-29T07:00:00+09:00", "gapSeconds": g, "parts": p} for n, g, p in [
        ("exactly_gap_not_split", 3600, [{"startS": 0, "endS": 1800}, {"startS": 5400, "endS": 6000}]),
        ("one_second_over_splits", 3600, [{"startS": 0, "endS": 1800}, {"startS": 5401, "endS": 6000}]),
        ("overlap_single", 3600, [{"startS": 0, "endS": 1800}, {"startS": 1000, "endS": 2000}]),
        ("contained_keeps_end", 3600, [{"startS": 0, "endS": 7200}, {"startS": 100, "endS": 200}]),
        ("null_end_forces_split", 3600, [{"startS": 0, "endS": None}, {"startS": 60, "endS": 120}]),
        ("zero_gap", 0, [{"startS": 0, "endS": 60}, {"startS": 60, "endS": 120}, {"startS": 121, "endS": 180}]),
        ("empty", 3600, []),
        ("unsorted_input", 3600, [{"startS": 7200, "endS": 7300}, {"startS": 0, "endS": 60}]),
        ("same_start_null_first", 3600, [{"startS": 0, "endS": 60}, {"startS": 0, "endS": None}]),
        ("last_null_end", 3600, [{"startS": 0, "endS": 60}, {"startS": 100, "endS": None}]),
    ]
]

# --- pytext / pyjson ------------------------------------------------------------------
PYTEXT = [
    {"name": "enumerations", "kind": "enumerations"},
    {"name": "strip_cases", "kind": "strip", "inputs": [
        "", "  a  ", "\U00003000a\U00003000", "\x1ca\x1f", "\U0000200ba\U0000200b", "\U00000085a\U000000a0", "\t\n\x0b\x0c\ra b\r\n", "a"]},
    {"name": "strip_dot_cases", "kind": "stripChars", "chars": ".", "inputs": ["..a..", "a.b", "...", "", ". a ."]},
    {"name": "strip_slash_cases", "kind": "stripChars", "chars": "/", "inputs": ["/Daily/Voice/Raw/", "Raw", "//", "/a//"]},
    {"name": "splitlines_cases", "kind": "splitlines", "inputs": [
        "", "\n", "a\n", "a", "a\r\nb\rc\n\nd\x0be\x0cf\x1cg\x1dh\x1ei\x85j\U00002028k\U00002029l\n", "\r\n\r", "a\x1fb",
        "a\r\r\nb"]},
    {"name": "collapse_cases", "kind": "collapse",
     "inputs": ["a  b", "a\t\tb", "a\U00003000\U00003000b", " a ", "a\U0000200bb", "a\x1c\x1db", "a\U000000a0b"]},
    {"name": "casefold_cases", "kind": "casefold", "inputs": [
        "Straße", "ǅ", "ΣΑΣ", "İ", "ﬁ", "ΐ", "ＡＢＣ", "ẞ",
        "Ǆ", "ﬀ", "ŉ", "abc"]},
    {"name": "nfc_cases", "kind": "nfc", "inputs": ["か\U00003099", "e\U00000301", "\U0000212b", "\U00001112\U00001161\U000011ab"]},
    {"name": "nfkc_cases", "kind": "nfkc",
     "inputs": ["ﾃｽﾄ", "Ｖｏｉｃｅ", "①", "㍍", "ﬁ", "\U00003000"]},
]

# PyJSON の値は型付きの配列で表す（整数と浮動小数を区別するため）:
# ["n"] / ["b", 真偽] / ["i", 整数] / ["f", "Python の repr の文字列"] / ["s", 文字列] / ["a", [値…]] / ["o", [[キー, 値]…]]
PYJSON = [
    {"name": "scalars_compact", "mode": "compact", "value": ["a", [
        ["n"], ["b", True], ["b", False], ["i", 0], ["i", -7], ["i", 9007199254740993], ["s", ""]]]},
    {"name": "floats_compact", "mode": "compact", "value": ["a", [["f", r] for r in [
        "0.0", "-0.0", "3.2", "1800.0", "12.345", "1e-05", "0.0001", "1e+16", "1000000000000000.0", "1.5e+300",
        "0.30000000000000004", "123456789.123", "1.2345678901234567e+19", "5e-324", "1.7976931348623157e+308",
        "0.002", "9.001", "2.5e-05", "100.0", "1e+22", "9007199254740992.0", "9007199254740994.0",
        "9500000000000000.0", "-9999999999999998.0", "9.999e-05"]]]},
    {"name": "string_escapes", "mode": "compact",
     "value": ["s", "x\x7f\U00002028/\x01\x1f\b\f\n\r\t\"\\é\U0001d11e"]},
    {"name": "indent_nested", "mode": "indent2", "value": ["o", [
        ["a", ["a", [["i", 1], ["o", [["b", ["a", []]]]]]]], ["c", ["o", []]], ["d", ["s", "日本語"]]]]},
    {"name": "indent_empty_containers", "mode": "indent2", "value": ["a", [["a", []], ["o", []]]]},
    {"name": "indent_top_scalar", "mode": "indent2", "value": ["s", "x"]},
    {"name": "file_transcript_like", "mode": "file", "value": ["o", [
        ["partkey", ["s", KA]], ["language", ["s", "ja"]], ["duration_seconds", ["f", "1800.0"]],
        ["started_at", ["s", BASE]], ["text", ["s", "おはよう"]],
        ["segments", ["a", [["o", [["start", ["f", "0.0"]], ["end", ["f", "3.2"]],
                                   ["text", ["s", "おはよう"]]]]]]]]]},
    {"name": "file_source_json", "mode": "file", "value": ["o", [
        ["schema", ["i", 1]],
        ["transcript_sha256", ["s", "894a61422b5c95830fe8b36c33ae2c3af728851d00a5e02e9f691d61ad5fb86f"]],
        ["segments", ["i", 2]], ["blocks", ["i", 1]]]]},
    {"name": "order_preserved_compact", "mode": "compact", "value": ["o", [["b", ["i", 1]], ["a", ["i", 2]]]]},
    {"name": "sort_keys_codepoint", "mode": "compact_sorted", "value": ["o", [
        ["b", ["i", 1]], ["\U0001d11e", ["i", 2]], ["Ａ", ["i", 3]], ["a", ["i", 4]], ["ab", ["i", 5]],
        ["a\U00000301", ["i", 6]], ["e", ["i", 7]], ["é", ["i", 8]], ["Z", ["i", 9]]]]},
    {"name": "sort_keys_nested", "mode": "compact_sorted", "value": ["o", [
        ["z", ["o", [["y", ["i", 1]], ["x", ["i", 2]]]]], ["a", ["a", [["o", [["d", ["n"]], ["c", ["b", True]]]]]]]]]},
]

# PyJSON.decode（Python の json.loads 互換）。JSON の本文の中のバックスラッシュは BS で組み立てる。
BS = chr(92)
U = BS + "u"
PYJSON_DECODE = [
    {"name": n, "text": s} for n, s in [
        ("object_basic", '{"a": 1, "b": [true, false, null], "c": "x"}'),
        ("duplicate_key_last_wins_first_position", '{"b":1,"a":2,"b":3}'),
        ("numbers", '[0, -0, 1.0, 1e5, 1E-5, -1.5e+2, 12345678901234567890, 9223372036854775807, '
                    '-9223372036854775808, 9223372036854775808, 0.1, 1e400]'),
        ("constants", '[NaN, Infinity, -Infinity]'),
        ("string_escapes", '"' + U + '3042' + U + 'd834' + U + 'dd1e' + BS + 'n' + BS + '/' + BS + BS + BS + '"'
                           + BS + 'b' + BS + 'f' + BS + 'r' + BS + 't' + U + '00E9"'),
        ("lone_surrogate", '"' + U + 'd800x"'),
        ("ascii_whitespace_around", ' ' + chr(9) + chr(10) + chr(13) + '{"a":1}' + chr(13) + chr(10) + ' '),
        ("ideographic_space_rejected", chr(0x3000) + '{"a":1}'),
        ("extra_data_rejected", '{"a":1} x'),
        ("empty_rejected", ''),
        ("bom_rejected", chr(0xFEFF) + '{}'),
        ("raw_control_char_rejected", '"a' + chr(1) + 'b"'),
        ("raw_tab_in_string_rejected", '"a' + chr(9) + 'b"'),
        ("invalid_escape_rejected", '"' + BS + 'x"'),
        ("short_unicode_escape_rejected", '"' + U + '12"'),
        ("non_string_key_rejected", '{1: 2}'),
        ("trailing_comma_array_rejected", '[1,]'),
        ("trailing_comma_object_rejected", '{"a":1,}'),
        ("leading_zero_rejected", '01'),
        ("minus_only_rejected", '-'),
        ("dot_without_digits_rejected", '1.'),
        ("leading_dot_rejected", '.5'),
        ("nested_ten", '[[[[[[[[[[1]]]]]]]]]]'),
        ("top_string", '"x"'), ("top_number", '3'), ("top_true", 'true'),
        ("non_ascii_raw", '{"' + chr(0x65E5) + '": "' + chr(0x672C) + chr(0x2028) + '"}'),
        ("empty_containers", '{"a": [], "b": {}}'),
    ]
]

# PyRound.round(x, digits)（Python の round(x, n)）。値は repr の文字列で渡す。
PYROUND = [
    {"name": "digits3_ms", "digits": 3, "inputs": ["0.0015", "0.0005", "0.0025", "0.001", "1.2345", "12.3455", "0.0",
                                                  "3.2", "9.001", "1234.5675", "-0.0015", "2.675"]},
    {"name": "digits3_ratios", "digits": 3, "inputs": [repr(1 / 3), repr(2 / 3), repr(12.5 / 1800), repr(0.0625),
                                                      repr(1.0005), repr(123.4565)]},
    {"name": "digits1", "digits": 1, "inputs": ["12.34", "0.05", "0.25", "0.35", "0.45", "2.5", "1e+16", "0.0"]},
]

PROMPT_FILES = [{"name": n} for n in ("analyze_ja", "map_ja", "reduce_ja", "repair_json")]

GROUPS = {
    "keys": KEYS,
    "sanitize": [{"name": n, "input": s, "maxBytes": m} for n, s, m in SANITIZE],
    "frontmatter": FRONTMATTER,
    "raw_note": RAW_NOTE,
    "note_filename": NOTE_FILENAME,
    "daily_note": DAILY_NOTE,
    "daily_parts": DAILY_PARTS,
    "timeline": TIMELINE,
    "timeline_decode": TIMELINE_DECODE,
    "wiki": WIKI,
    "llm_schema_block": LLM_SCHEMA_BLOCK,
    "llm_prompt": LLM_PROMPT,
    "llm_repair_prompt": LLM_REPAIR_PROMPT,
    "llm_validate": LLM_VALIDATE,
    "llm_trim": LLM_TRIM,
    "llm_extract": LLM_EXTRACT,
    "llm_strip_think": LLM_STRIP_THINK,
    "llm_chunks": LLM_CHUNKS,
    "llm_dedupe": LLM_DEDUPE,
    "llm_as_json": LLM_AS_JSON,
    "llm_bundles": LLM_BUNDLES,
    "analysis_json": ANALYSIS_JSON,
    "transcript_json": TRANSCRIPT_JSON,
    "numbers": NUMBERS,
    "fingerprint": FINGERPRINT,
    "blocks": BLOCKS,
    "pytext": PYTEXT,
    "pyjson": PYJSON,
    "pyjson_decode": PYJSON_DECODE,
    "pyround": PYROUND,
    "prompt_files": PROMPT_FILES,
}

# ケースに足す既定（ケースが持っていれば上書きしない）。timeZone は全ケース、day / sessionKey は使うグループだけ
DAY_GROUPS = {"raw_note", "daily_note", "note_filename", "timeline", "wiki", "fingerprint", "llm_chunks"}
SESSION_KEY_GROUPS = {"raw_note", "daily_note"}


def defaults_for(group: str) -> dict:
    values: dict = {"timeZone": TZ}
    if group in DAY_GROUPS:
        values["day"] = DAY
    if group in SESSION_KEY_GROUPS:
        values["sessionKey"] = SK
    return values


INVISIBLE_CATEGORIES = {"Cc", "Cf", "Cs", "Co", "Zl", "Zp", "Zs", "Mn", "Mc", "Me"}


def escape_invisible(text: str) -> str:
    """json.dumps(ensure_ascii=False) の結果の中の、見えない文字・空白・結合文字を \\uXXXX にする。

    値は変わらない（JSON の文字列の中にしか現れないため）。レビューで読めるようにするためだけの処理。
    """
    out = []
    for ch in text:
        code = ord(ch)
        if code > 0x7E and unicodedata.category(ch) in INVISIBLE_CATEGORIES:
            if code > 0xFFFF:
                code -= 0x10000
                out.append("\\u%04x\\u%04x" % (0xD800 + (code >> 10), 0xDC00 + (code & 0x3FF)))
            else:
                out.append("\\u%04x" % code)
        else:
            out.append(ch)
    return "".join(out)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: make_inputs.py <Tests/Golden>", file=sys.stderr)
        return 2
    inputs = Path(sys.argv[1]) / "inputs"
    inputs.mkdir(parents=True, exist_ok=True)
    for old in inputs.glob("*.json"):
        old.unlink()
    for group, cases in GROUPS.items():
        names = [c["name"] for c in cases]
        if len(names) != len(set(names)):
            raise SystemExit(f"{group}: ケース名が重複しています")
        for name in names:
            if not name.replace("_", "").isalnum() or not name.isascii() or name != name.lower():
                raise SystemExit(f"{group}: ケース名は小文字の英数字と _ だけ: {name}")
        extra = defaults_for(group)
        filled = [{**case, **{k: v for k, v in extra.items() if k not in case}} for case in cases]
        doc = {"schema": SCHEMA, "group": group, "cases": filled}
        text = escape_invisible(json.dumps(doc, ensure_ascii=False, indent=2)) + "\n"
        (inputs / f"{group}.json").write_text(text, encoding="utf-8")
    print(f"{len(GROUPS)} グループを書きました: {inputs}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
````


#### `tools/golden/generate.py`（全文。549 行）

voicedock のモジュールは `Generator.__init__` の中で import する（`generate.sh` が作る uv 環境にだけ在る）。一時ファイルは展開した木の中に作り、`generate.sh` の `trap` が消す。

```python
#!/usr/bin/env python3
"""voicedock@d3d595e の関数で golden の期待値を作る（PLAN §10.4、T-25）。

generate.sh が `git archive` で展開した voicedock の木の中で、その木の `uv` 環境で実行する。
**voicedock の作業ツリーには触らない。**入力は Tests/Golden/inputs/*.json（make_inputs.py の出力）。

出力: Tests/Golden/expected/<group>/<case>.<ext>
  - .md / .out  … voicedock の出力文字列の UTF-8 バイト列そのもの（Swift 側はバイト列で比べる）
  - .json       … 構造化した値。json.dumps(ensure_ascii=False, indent=2) + "\\n"（Swift 側は値で比べる）
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
import unicodedata
from datetime import date, datetime, timedelta
from pathlib import Path, PurePosixPath
from typing import Any, Callable
from zoneinfo import ZoneInfo

ALLOWED_OVERRIDES = {
    "obsidian.maxTitleBytes", "obsidian.defaultTags",
    "obsidian.raw.folderTemplate", "obsidian.raw.filenameTemplate",
    "obsidian.raw.timestampIntervalSeconds", "obsidian.raw.partBoundaryHeading",
    "obsidian.wiki.folderTemplate", "obsidian.wiki.filenameTemplate",
    "obsidian.wiki.linkDailyNote", "obsidian.wiki.linkAdjacentDays", "obsidian.wiki.linkTags",
    "obsidian.wiki.linkOnlyExisting", "obsidian.wiki.maxLinks",
    "llm.maxCharsPerRequest", "llm.maxSecondsPerRequest", "llm.chunkOverlapChars",
    "llm.analysis.order", "llm.analysis.customInstructions",
    "session.blockGapSeconds",
}
SECTION_OVERRIDE = re.compile(
    r"^llm\.analysis\.sections\.(summary|timeline|key_points|tasks|decisions|ideas|tags)\.(enabled|heading|maxItems)$")
# maxItems を持たない節（PLAN §6.2・付録 F の F-54。書けば CV-01）。
SECTIONS_WITHOUT_MAX_ITEMS = {"summary", "timeline"}


def is_allowed_override(key: str) -> bool:
    if key in ALLOWED_OVERRIDES:
        return True
    m = SECTION_OVERRIDE.match(key)
    if m is None:
        return False
    return not (m.group(2) == "maxItems" and m.group(1) in SECTIONS_WITHOUT_MAX_ITEMS)


def to_snake(segment: str) -> str:
    """AppConfig の JSON キー（camelCase）を voicedock の設定キー（snake_case）へ写す。"""
    return re.sub(r"(?<=[a-z0-9])([A-Z])", lambda m: "_" + m.group(1).lower(), segment)


class Generator:
    def __init__(self, voicedock_root: Path, golden: Path) -> None:
        sys.path.insert(0, str(voicedock_root))
        # voicedock のモジュールは実行時に import する（generate.sh の uv 環境にだけ在る）
        from tests import helpers  # type: ignore
        from voicedock import audio, daily, llm, notes, paths, raw, session, transcribe, wiki  # type: ignore
        self.helpers, self.audio, self.daily, self.llm = helpers, audio, daily, llm
        self.notes, self.paths, self.raw, self.session = notes, paths, raw, session
        self.transcribe, self.wiki = transcribe, wiki
        self.voicedock_root = voicedock_root
        self.golden = golden
        # 一時ファイルは展開した木の中に作る（generate.sh の trap が木ごと消す）
        self.tmp = Path(tempfile.mkdtemp(prefix="golden-", dir=voicedock_root))
        (self.tmp / "config").mkdir()
        self.base_document = helpers.complete_tree(self.tmp / "config")  # ファイル実在検査を通す設定
        self.handlers: dict[str, Callable[[dict], tuple[str, Any]]] = {
            "keys": self.keys, "sanitize": self.sanitize, "frontmatter": self.frontmatter,
            "raw_note": self.raw_note, "note_filename": self.note_filename, "daily_note": self.daily_note,
            "daily_parts": self.daily_parts, "timeline": self.timeline, "timeline_decode": self.timeline_decode,
            "wiki": self.wiki_case, "llm_schema_block": self.llm_schema_block, "llm_prompt": self.llm_prompt,
            "llm_repair_prompt": self.llm_repair_prompt, "llm_validate": self.llm_validate,
            "llm_trim": self.llm_trim, "llm_extract": self.llm_extract, "llm_strip_think": self.llm_strip_think,
            "llm_chunks": self.llm_chunks, "llm_dedupe": self.llm_dedupe, "llm_as_json": self.llm_as_json,
            "llm_bundles": self.llm_bundles, "analysis_json": self.analysis_json,
            "transcript_json": self.transcript_json, "numbers": self.numbers, "fingerprint": self.fingerprint,
            "blocks": self.blocks, "pytext": self.pytext, "pyjson": self.pyjson, "pyjson_decode": self.pyjson_decode,
            "pyround": self.pyround, "prompt_files": self.prompt_files,
        }

    # --- 共通 ------------------------------------------------------------------
    def config(self, case: dict) -> Any:
        patch: dict[str, Any] = {"timezone": case["timeZone"]}
        for key, value in case.get("overrides", {}).items():
            if not is_allowed_override(key):
                raise SystemExit(f"{case['name']}: 許可されていない上書き {key}")
            parts = [to_snake(p) for p in key.split(".")]
            cursor = patch
            for part in parts[:-1]:
                cursor = cursor.setdefault(part, {})
            cursor[parts[-1]] = value
        return self.helpers.parsed(self.helpers.merge(self.base_document, patch))

    @staticmethod
    def at(base: str, millis: int) -> datetime:
        return datetime.fromisoformat(base) + timedelta(milliseconds=millis)

    @staticmethod
    def iso(moment: datetime) -> str:
        return moment.isoformat(timespec="seconds")

    @staticmethod
    def day(case: dict) -> date:
        return date.fromisoformat(case["day"])

    def transcript(self, case: dict, payload: dict) -> Any:
        base = case["base"]
        return self.session.SessionTranscript(
            day_date=self.day(case),
            segments=[self.session.AbsoluteSegment(at=self.at(base, s["atMs"]), end_at=self.at(base, s["endMs"]),
                                                   text=s["text"]) for s in payload["segments"]],
            blocks=[(self.at(base, b["startMs"]), self.at(base, b["endMs"])) for b in payload["blocks"]],
            excluded_partkeys=[],
        )

    # --- グループごと -------------------------------------------------------------
    def keys(self, case: dict) -> tuple[str, Any]:
        if case["kind"] == "partkey":
            key = self.paths.partkey_for(case["deviceID"], PurePosixPath(case["relpath"]))
        else:
            key = self.paths.session_key_for(case["deviceID"], datetime.fromisoformat(case["startedAt"]),
                                             tz=ZoneInfo(case["timeZone"]), overflow=case["overflow"])
        return "json", {"key": str(key), "slug": self.paths.key_slug(key)}

    def sanitize(self, case: dict) -> tuple[str, Any]:
        return "out", self.notes.sanitize_filename(case["input"], max_bytes=case["maxBytes"])

    @staticmethod
    def fm_value(tagged: list) -> Any:
        kind = tagged[0]
        if kind == "s":
            return str(tagged[1])
        if kind == "i":
            return int(tagged[1])
        if kind == "b":
            return bool(tagged[1])
        if kind == "n":
            return None
        if kind == "a":
            return [str(x) for x in tagged[1]]
        raise SystemExit(f"frontmatter: 未知の型 {kind}")

    def frontmatter(self, case: dict) -> tuple[str, Any]:
        kind = case["kind"]
        if kind == "render":
            fields = {key: self.fm_value(value) for key, value in case["fields"]}
            return "out", self.notes.render_frontmatter(fields)
        if kind == "quote":
            return "out", self.notes.yaml_quote(case["text"])
        if kind == "escapeBody":
            return "out", self.notes.escape_body(case["text"])
        if kind == "split":
            result = self.notes.split_frontmatter(case["text"])
            return "json", None if result is None else {"front": result[0], "body": result[1]}
        raise SystemExit(f"frontmatter: 未知の kind {kind}")

    def raw_note(self, case: dict) -> tuple[str, Any]:
        cfg = self.config(case)
        parts = []
        for part in case["parts"]:
            started = datetime.fromisoformat(part["startedAt"])
            ended = datetime.fromisoformat(part["endedAt"]) if part["endedAt"] else None
            segments = tuple(self.raw.RawSegment(at=started + timedelta(milliseconds=s["startMs"]),
                                                 end_at=started + timedelta(milliseconds=s["endMs"]), text=s["text"])
                             for s in part["segments"])
            parts.append(self.raw.RawPart(part["partkey"], started, ended, segments))
        return "md", self.raw.render_raw_note(parts, day=self.day(case), session_key=case["sessionKey"],
                                              cfg=cfg.obsidian.raw)

    def note_filename(self, case: dict) -> tuple[str, Any]:
        cfg = self.config(case)
        day = self.day(case)
        kind = case["kind"]
        if kind == "raw":
            return "out", self.raw.raw_filename(cfg.obsidian.raw, day, max_bytes=cfg.obsidian.max_title_bytes)
        if kind == "daily":
            return "out", self.daily.daily_filename(cfg, day)
        if kind == "rawFolder":
            return "out", self.raw.render_template(cfg.obsidian.raw.folder_template, day)
        if kind == "dailyFolder":
            return "out", self.raw.render_template(cfg.obsidian.wiki.folder_template, day)
        raise SystemExit(f"note_filename: 未知の kind {kind}")

    def excluded(self, items: list[dict]) -> list:
        return [self.daily.ExcludedPart(self.paths.PartKey(e["partkey"]), e["status"], e["errorCode"]) for e in items]

    def daily_note(self, case: dict) -> tuple[str, Any]:
        cfg = self.config(case)
        analysis = self.llm.build_schema(cfg).model_validate(case["analysis"])
        tl = case["timeline"]
        blocks = [self.daily.TimelineBlock(self.at(tl["base"], b["startMs"]), self.at(tl["base"], b["endMs"]),
                                           tuple(b["lines"])) for b in tl["blocks"]]
        links = case["links"]
        plan = self.wiki.LinkPlan(daily_note=links["dailyNote"], adjacent=tuple(links["adjacent"]),
                                  tags=tuple(links["tags"]), raw=tuple(links["raw"]))
        text = self.daily.render_daily_note(
            analysis, day=self.day(case), session_key=self.paths.SessionKey(case["sessionKey"]),
            recording_keys=[self.paths.PartKey(k) for k in case["recordingKeys"]],
            excluded=self.excluded(case["excluded"]), recorded_seconds=case["recordedSeconds"],
            block_count=case["blockCount"], timeline=blocks, links=plan, cfg=cfg)
        return "md", text

    def daily_parts(self, case: dict) -> tuple[str, Any]:
        kind = case["kind"]
        if kind == "recorded":
            return "json", [self.daily._duration(v) for v in case["inputs"]]
        if kind == "tags":
            cfg = self.config({**case, "overrides": {"obsidian.defaultTags": case["defaults"]}})
            payload: dict[str, Any] = {"title": "t", "summary": "s"}
            if case["tags"] is not None:
                payload["tags"] = case["tags"]
            analysis = self.llm.build_schema(cfg).model_validate(payload)
            return "json", self.daily._tags(analysis, cfg)
        if kind == "warnings":
            out = []
            for items in case["sets"]:
                parts = self.excluded(items)
                failed = [p for p in parts if p.status == "FAILED"]
                skipped = [p for p in parts if p.status != "FAILED"]
                out.append(self.daily._warnings(failed, skipped))
            return "json", out
        if kind == "sentences":
            return "json", [self.daily._sentences(s) for s in case["inputs"]]
        raise SystemExit(f"daily_parts: 未知の kind {kind}")

    def timeline(self, case: dict) -> tuple[str, Any]:
        cfg = self.config(case)
        pm = self.llm.build_schema(cfg, partial=True)
        base = case["base"]
        blocks = self.daily.build_timeline(
            partials=[pm.model_validate(p) for p in case["partials"]],
            chunks=[self.llm.Chunk(text="", start_at=self.at(base, c["startMs"]), end_at=self.at(base, c["endMs"]),
                                   segments=()) for c in case["chunks"]],
            transcript=self.transcript(case, case["transcript"]), summary=case["summary"])
        work = self.tmp / "timeline" / case["name"]
        work.mkdir(parents=True, exist_ok=True)
        self.daily.save_timeline(work / "a.json", blocks, fingerprint=case["fingerprint"])
        return "out", (work / "a.timeline.json").read_text(encoding="utf-8")

    def timeline_decode(self, case: dict) -> tuple[str, Any]:
        work = self.tmp / "timeline_decode" / case["name"]
        work.mkdir(parents=True, exist_ok=True)
        (work / "a.timeline.json").write_text(case["document"], encoding="utf-8")
        blocks = self.daily.load_timeline(work / "a.json", fingerprint=case["fingerprint"])
        return "json", [{"start": self.iso(b.start_at), "end": self.iso(b.end_at), "lines": list(b.lines)}
                        for b in blocks]

    def wiki_case(self, case: dict) -> tuple[str, Any]:
        kind = case["kind"]
        if kind == "normalize":
            return "json", [self.wiki.normalize_name(s) for s in case["inputs"]]
        cfg = self.config(case)
        if kind == "plan":
            day = self.day(case)
            names = case["indexNames"]
            index = None if names is None else self.wiki.VaultIndex(
                names=frozenset(self.wiki.normalize_name(n) for n in names), built_at=0.0)
            plan = self.wiki.plan_links(cfg=cfg, day=day, tags=case["tags"], index=index,
                                        self_name=self.daily.daily_filename(cfg, day),
                                        name_for_day=lambda d: self.daily.daily_filename(cfg, d),
                                        raw_names=case["rawNames"])
            return "json", {"dailyNote": plan.daily_note, "adjacent": list(plan.adjacent), "tags": list(plan.tags),
                            "raw": list(plan.raw), "dropped": list(plan.dropped)}
        if kind == "buildIndex":
            root = self.tmp / "vault" / case["name"]
            for rel in case["files"]:
                target = root / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("", encoding="utf-8")
            for link, target in case["symlinkDirs"]:
                os.symlink(root / target, root / link)
            index = self.wiki.build_index(root, exclude_prefixes=(self.wiki.raw_folder_prefix(cfg),), now=0.0)
            return "json", sorted(index.names)
        if kind == "rawPrefix":
            return "out", self.wiki.raw_folder_prefix(cfg)
        raise SystemExit(f"wiki: 未知の kind {kind}")

    def llm_schema_block(self, case: dict) -> tuple[str, Any]:
        return "out", self.llm.render_schema_block(self.config(case), partial=case["partial"])

    def llm_prompt(self, case: dict) -> tuple[str, Any]:
        kind = self.llm.PromptKind(case["kind"])
        return "out", self.llm.system_prompt(self.config(case), kind)

    def llm_repair_prompt(self, case: dict) -> tuple[str, Any]:
        """本計画の差分（X-12）: voicedock の repair_json.txt の末尾に "\\n{schema_block}\\n" を足した雛形。"""
        cfg = self.config(case)
        original = (self.voicedock_root / "prompts" / "repair_json.txt").read_text(encoding="utf-8")
        # 前提の確認: voicedock の修復プロンプトは errors → previous_output の順の単純置換である
        expected_vd = original.replace("{errors}", case["errors"]).replace("{previous_output}", case["previousOutput"])
        actual_vd = self.llm.repair_prompt(cfg, errors=case["errors"], previous_output=case["previousOutput"])
        if expected_vd != actual_vd:
            raise SystemExit(f"{case['name']}: voicedock の修復プロンプトの前提が崩れました")
        template = original + "\n{schema_block}\n"
        block = self.llm.render_schema_block(cfg, partial=case["partial"])
        text = (template.replace("{schema_block}", block).replace("{errors}", case["errors"])
                .replace("{previous_output}", case["previousOutput"]))
        return "out", text

    def llm_validate(self, case: dict) -> tuple[str, Any]:
        from pydantic import ValidationError  # type: ignore
        model = self.llm.build_schema(self.config(case), partial=case["partial"])
        try:
            result = model.model_validate(case["payload"])
        except ValidationError as error:
            return "json", {"ok": False, "errors": self.llm._errors_of(error), "result": None}
        return "json", {"ok": True, "errors": None, "result": result.model_dump()}

    def llm_trim(self, case: dict) -> tuple[str, Any]:
        model = self.llm.build_schema(self.config(case), partial=case["partial"])
        document, trimmed = self.llm.coerce_limits(dict(case["payload"]), model)
        return "json", {"trimmed": list(trimmed), "result": document}

    def llm_extract(self, case: dict) -> tuple[str, Any]:
        return "json", self.llm.extract_json(case["text"])

    def llm_strip_think(self, case: dict) -> tuple[str, Any]:
        return "out", self.llm.strip_think(case["text"])

    def llm_chunks(self, case: dict) -> tuple[str, Any]:
        cfg = self.config(case)
        base = datetime.fromisoformat(case["base"])
        chunks = self.llm.split_chunks(self.transcript(case, {"segments": case["segments"], "blocks": []}), cfg)
        millis = lambda moment: (moment - base) // timedelta(milliseconds=1)  # noqa: E731
        return "json", [{"texts": [s.text for s in c.segments], "startMs": millis(c.start_at),
                         "endMs": millis(c.end_at), "text": c.text} for c in chunks]

    def llm_dedupe(self, case: dict) -> tuple[str, Any]:
        kind = case["kind"]
        if kind == "key":
            return "json", [self.llm.normalize_for_dedupe(s) for s in case["inputs"]]
        if kind == "values":
            return "json", self.llm.dedupe(case["inputs"])
        if kind == "result":
            model = self.llm.build_schema(self.config(case))
            return "json", self.llm._deduped(model.model_validate(case["payload"])).model_dump()
        raise SystemExit(f"llm_dedupe: 未知の kind {kind}")

    def llm_as_json(self, case: dict) -> tuple[str, Any]:
        pm = self.llm.build_schema(self.config(case), partial=True)
        return "out", self.llm._as_json([pm.model_validate(p) for p in case["partials"]])

    def llm_bundles(self, case: dict) -> tuple[str, Any]:
        pm = self.llm.build_schema(self.config(case), partial=True)
        items = [pm.model_validate(p) for p in case["partials"]]
        index = {id(item): i for i, item in enumerate(items)}
        return "json", [[index[id(item)] for item in bundle] for bundle in self.llm._bundles(items, case["limit"])]

    def analysis_json(self, case: dict) -> tuple[str, Any]:
        model = self.llm.build_schema(self.config(case))
        dumped = model.model_validate(case["payload"]).model_dump()
        return "out", json.dumps(dumped, ensure_ascii=False, indent=2) + "\n"

    def transcript_json(self, case: dict) -> tuple[str, Any]:
        transcript = self.transcribe.normalize(case["whisper"], partkey=self.paths.PartKey(case["partkey"]),
                                               started_at=case["startedAt"],
                                               duration_seconds=case["durationSeconds"],
                                               fallback_language=case["fallbackLanguage"])
        return "out", json.dumps(transcript.to_document(), ensure_ascii=False, indent=2) + "\n"

    def numbers(self, case: dict) -> tuple[str, Any]:
        cfg = self.config(case)
        kind = case["kind"]
        if kind == "num":
            return "json", [self.transcribe._number(v) for v in case["inputs"]]
        if kind == "whisperTimeout":
            return "json", [self.transcribe.timeout_for(v, cfg.transcription) for v in case["inputs"]]
        if kind == "convertTimeout":
            return "json", [self.audio.convert_timeout(v, cfg) for v in case["inputs"]]
        if kind == "expectedBytes":
            return "json", [self.audio.expected_bytes(v) for v in case["inputs"]]
        raise SystemExit(f"numbers: 未知の kind {kind}")

    def fingerprint(self, case: dict) -> tuple[str, Any]:
        transcript = self.transcript(case, case)
        payload = json.dumps({
            "segments": [{"at": self.iso(s.at), "end_at": self.iso(s.end_at), "text": s.text}
                         for s in transcript.segments],
            "blocks": [[self.iso(a), self.iso(b)] for a, b in transcript.blocks],
        }, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        digest = hashlib.sha256(payload.encode("utf-8")).hexdigest()
        if digest != self.session.transcript_fingerprint(transcript):
            raise SystemExit(f"{case['name']}: 指紋の再現が voicedock と一致しません")
        return "out", payload + "\n" + digest + "\n"

    def blocks(self, case: dict) -> tuple[str, Any]:
        class Part:
            def __init__(self, started_at: str, ended_at: str | None) -> None:
                self.started_at, self.ended_at = started_at, ended_at

        base = datetime.fromisoformat(case["base"])
        parts = [Part(self.iso(base + timedelta(seconds=p["startS"])),
                      None if p["endS"] is None else self.iso(base + timedelta(seconds=p["endS"])))
                 for p in case["parts"]]
        result = self.session.compute_blocks(parts, gap_seconds=case["gapSeconds"])
        return "json", [[self.iso(a), self.iso(b)] for a, b in result]

    def pytext(self, case: dict) -> tuple[str, Any]:
        kind = case["kind"]
        if kind == "enumerations":
            scalars = [c for c in range(0x110000) if not 0xD800 <= c <= 0xDFFF]
            assigned = [c for c in scalars if unicodedata.category(chr(c)) != "Cn"]
            ranges: list[list[int]] = []
            for c in assigned:
                if ranges and ranges[-1][1] == c - 1:
                    ranges[-1][1] = c
                else:
                    ranges.append([c, c])
            return "json", {
                "unicodeVersion": unicodedata.unidata_version,
                "isspace": [c for c in scalars if chr(c).isspace()],
                "splitlinesSeparators": [c for c in scalars if len(("a" + chr(c) + "b").splitlines()) == 2],
                "casefold": {str(c): [ord(x) for x in chr(c).casefold()] for c in scalars
                             if chr(c).casefold() != chr(c)},
                "combining": [c for c in assigned if unicodedata.combining(chr(c)) != 0],
                "assignedRanges": ranges,
            }
        inputs = case["inputs"]
        if kind == "strip":
            return "json", [s.strip() for s in inputs]
        if kind == "stripChars":
            return "json", [s.strip(case["chars"]) for s in inputs]
        if kind == "splitlines":
            return "json", [s.splitlines() for s in inputs]
        if kind == "collapse":
            return "json", [re.sub(r"\s+", " ", s) for s in inputs]
        if kind == "casefold":
            return "json", [s.casefold() for s in inputs]
        if kind == "nfc":
            return "json", [unicodedata.normalize("NFC", s) for s in inputs]
        if kind == "nfkc":
            return "json", [unicodedata.normalize("NFKC", s) for s in inputs]
        raise SystemExit(f"pytext: 未知の kind {kind}")

    def py_value(self, tagged: list) -> Any:
        kind = tagged[0]
        if kind == "n":
            return None
        if kind == "b":
            return bool(tagged[1])
        if kind == "i":
            return int(tagged[1])
        if kind == "f":
            value = float(tagged[1])
            if repr(value) != tagged[1]:
                raise SystemExit(f"pyjson: 浮動小数の表記が repr と違います: {tagged[1]}")
            return value
        if kind == "s":
            return str(tagged[1])
        if kind == "a":
            return [self.py_value(x) for x in tagged[1]]
        if kind == "o":
            keys = [k for k, _ in tagged[1]]
            if len(keys) != len(set(keys)):
                raise SystemExit("pyjson: キーが重複しています")
            return {k: self.py_value(v) for k, v in tagged[1]}
        raise SystemExit(f"pyjson: 未知の型 {kind}")

    def pyjson(self, case: dict) -> tuple[str, Any]:
        value = self.py_value(case["value"])
        mode = case["mode"]
        if mode == "compact":
            return "out", json.dumps(value, ensure_ascii=False, separators=(",", ":"))
        if mode == "compact_sorted":
            return "out", json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        if mode == "indent2":
            return "out", json.dumps(value, ensure_ascii=False, indent=2)
        if mode == "file":
            return "out", json.dumps(value, ensure_ascii=False, indent=2) + "\n"
        raise SystemExit(f"pyjson: 未知の mode {mode}")

    @staticmethod
    def to_tagged(value: Any) -> list:
        """json.loads の結果を型付きの配列へ（make_inputs.py の PyJSON と同じ表し方）。対にならないサロゲートは U+FFFD。"""
        if value is None:
            return ["n"]
        if isinstance(value, bool):
            return ["b", value]
        if isinstance(value, int):
            return ["i", value] if -(2 ** 63) <= value < 2 ** 63 else ["f", repr(float(value))]
        if isinstance(value, float):
            return ["f", repr(value)]
        if isinstance(value, str):
            return ["s", "".join(chr(0xFFFD) if 0xD800 <= ord(c) <= 0xDFFF else c for c in value)]
        if isinstance(value, list):
            return ["a", [Generator.to_tagged(v) for v in value]]
        if isinstance(value, dict):
            return ["o", [[k, Generator.to_tagged(v)] for k, v in value.items()]]
        raise SystemExit(f"pyjson_decode: 未知の型 {type(value)}")

    def pyjson_decode(self, case: dict) -> tuple[str, Any]:
        try:
            value = json.loads(case["text"])
        except ValueError:
            return "json", {"ok": False, "value": None}
        return "json", {"ok": True, "value": self.to_tagged(value)}

    def pyround(self, case: dict) -> tuple[str, Any]:
        return "json", [repr(round(float(s), case["digits"])) for s in case["inputs"]]

    def prompt_files(self, case: dict) -> tuple[str, Any]:
        data = (self.voicedock_root / "prompts" / f"{case['name']}.txt").read_bytes()
        return "out", data.decode("utf-8")

    # --- 実行 -------------------------------------------------------------------------
    def run(self) -> int:
        inputs = sorted((self.golden / "inputs").glob("*.json"))
        groups = {p.stem for p in inputs}
        if groups != set(self.handlers):
            raise SystemExit(f"入力と生成器のグループが一致しません: {sorted(groups ^ set(self.handlers))}")
        expected = self.golden / "expected"
        count = 0
        for path in inputs:
            document = json.loads(path.read_text(encoding="utf-8"))
            if document.get("schema") != 1 or document.get("group") != path.stem:
                raise SystemExit(f"{path.name}: schema か group が不正です")
            out_dir = expected / path.stem
            out_dir.mkdir(parents=True, exist_ok=True)
            for case in document["cases"]:
                ext, value = self.handlers[path.stem](case)
                target = out_dir / f"{case['name']}.{ext}"
                if ext == "json":
                    text = json.dumps(value, ensure_ascii=False, indent=2) + "\n"
                else:
                    text = value
                target.write_bytes(text.encode("utf-8"))
                count += 1
        print(f"{count} 件の期待値を書きました: {expected}")
        return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--voicedock-root", required=True, type=Path)
    parser.add_argument("--golden", required=True, type=Path)
    parser.add_argument("--ref", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--uv-version", required=True)
    args = parser.parse_args()
    generator = Generator(args.voicedock_root.resolve(), args.golden.resolve())
    status = generator.run()
    stamp = (
        f"voicedock_ref={args.ref}\n"
        f"voicedock_commit={args.commit}\n"
        f"python={sys.version.split()[0]}\n"
        f"unicodedata={unicodedata.unidata_version}\n"
        f"uv={args.uv_version}\n"
        "generator=tools/golden/generate.py\n"
    )
    (args.golden / "GENERATED_BY.txt").write_text(stamp, encoding="utf-8")
    return status


if __name__ == "__main__":
    sys.exit(main())
```


### 4.10 TestSupport の API

`TestSupport`（T-01 の `.target`、`path: "Tests/TestSupport"`）に足す公開 API:

| 型 | API | 説明 |
|---|---|---|
| `GoldenJSON` | `indirect enum GoldenJSON: Sendable, Equatable, Decodable, CustomStringConvertible`、`case null, bool(Bool), integer(Int64), number(Double), string(String), array([GoldenJSON]), object([String: GoldenJSON])` | 値で比べる JSON。`JSONDecoder` で読む（`JSONSerialization` は文字列の先頭の U+FEFF を落とすので使わない）。`==` は数を数値として（`integer(2) == number(2.0)`）、文字列をスカラー列で、オブジェクトをキーの集合で比べる。`description` はキーをスカラー順に並べた indent 2 の JSON（差分の表示用）。リテラル（`"a"`・`1`・`[…]`・`[キー: 値]`）で書ける |
| | `init?(any: Any)`、`stringValue`・`boolValue`・`intValue`・`doubleValue`・`arrayValue`・`objectValue`・`isNull`・`foundationObject` | 取り出し。`foundationObject` は `NSNull`・`NSNumber`・`String`・`[Any]`・`[String: Any]` |
| `GoldenError` | `unreadable(String)`・`malformedInput(String)`・`noSuchCase(group:name:)`・`expectedMissing(group:name:)`・`expectedAmbiguous(group:name:)`・`missingKey(group:name:key:)`・`typeMismatch(group:name:key:expected:)` | 読み込みの誤り（テストの準備の誤り。不一致ではない） |
| `GoldenCase` | `group`・`name`・`fields`、`subscript(_:)`、`value(_:)`・`string(_:)`・`optionalString(_:)`・`int(_:)`・`double(_:)`・`optionalDouble(_:)`・`bool(_:)`・`array(_:)`・`strings(_:)`・`object(_:)`・`overrides()`（**`orderedObject(_:)` は本チケットには無い**。`PyJSONValue` を使うので T-45 が `Tests/TestSupport/GoldenCase+PyJSON.swift` の extension で足す。使うのは T-19） | 1 ケース。`CustomTestStringConvertible`（パラメータ化テストで `group/name` と表示される）。型が違えば `typeMismatch` を投げる |
| `Golden` | `root`・`inputsDirectory`・`expectedDirectory`、`groupNames()`・`cases(_:)`・`testCase(_:_:)`・`expectedFile(_:_:)`・`expectedBytes(_:_:)`・`expectedJSON(_:_:)`、`byteExtensions`・`jsonExtension`・`allowedOverrideKeys`・`overridableSections`・`overridableSectionFields`・`isAllowedOverride(_:)` | 読み込み |
| `GoldenAssert` | `matches(_ actual: String, group:name:sourceLocation:)`・`matches(bytes: Data, group:name:sourceLocation:)`・`matchesJSON(_ actual: GoldenJSON, group:name:sourceLocation:)` | 比較。違えば `Issue.record`（テストを止めない）。メッセージは「golden 不一致: <パス>（期待 n バイト、実際 m バイト）」＋ unified diff。`.json` の期待値に `matches` を使う・その逆は取り違えとして記録する |
| `UnifiedDiff` | `render(expected:actual:expectedLabel:actualLabel:context: = 3) -> String` | 同じなら `""`。行は U+000A だけで分ける。見えない文字は `\u{…}`、タブは `\t`、CR は `\r` で見せる |
| `TestEnvironment` | `goldenWriteActual: Bool` | `VOICEDOCK_GOLDEN_WRITE_ACTUAL=1` のとき、不一致の実際の出力を `.build/golden-actual/<group>/<name>.<ext>` に書く（手元で `diff` や作り直しの確認に使う） |

#### `Tests/TestSupport/GoldenJSON.swift`（全文。257 行）

```swift
// golden の JSON の値（入力と .json の期待値）。JSONDecoder で読み、Unicode スカラー列で比べる（PLAN §10.4、T-25）。
import Foundation

/// golden の JSON の値。
///
/// - 読み取りは `JSONDecoder`（`JSONSerialization` は文字列の先頭の U+FEFF を落とすので使わない。Xcode 27.0 で確認）
/// - 文字列の比較は Unicode スカラー列（Swift の `==` は正準等価で比べ、NFC の有無を見逃すため）
/// - 数は整数の字面なら `.integer`、それ以外は `.number`。`.integer` と `.number` は数として等しければ等しい
public indirect enum GoldenJSON: Sendable, Equatable, Decodable, CustomStringConvertible {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([GoldenJSON])
    case object([String: GoldenJSON])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let integer = try? container.decode(Int64.self) {
            self = .integer(integer)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let text = try? container.decode(String.self) {
            self = .string(text)
        } else if let items = try? container.decode([GoldenJSON].self) {
            self = .array(items)
        } else {
            self = .object(try container.decode([String: GoldenJSON].self))
        }
    }

    /// Swift / Foundation の値から作る（`String`・`Bool`・整数・`Double`・`NSNumber`・配列・辞書・`nil`・`NSNull`）。
    /// 表せない値は nil。
    public init?(any value: Any?) {
        guard let value else {
            self = .null
            return
        }
        switch value {
        case is NSNull:
            self = .null
        case let json as GoldenJSON:
            self = json
        case let text as String:
            self = .string(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number as CFNumber) {
                self = .number(number.doubleValue)
            } else {
                self = .integer(number.int64Value)
            }
        case let flag as Bool:
            self = .bool(flag)
        case let integer as Int:
            self = .integer(Int64(integer))
        case let integer as Int64:
            self = .integer(integer)
        case let number as Double:
            self = .number(number)
        case let items as [Any?]:
            var converted: [GoldenJSON] = []
            for item in items {
                guard let json = GoldenJSON(any: item) else {
                    return nil
                }
                converted.append(json)
            }
            self = .array(converted)
        case let pairs as [String: Any?]:
            var converted: [String: GoldenJSON] = [:]
            for (key, item) in pairs {
                guard let json = GoldenJSON(any: item) else {
                    return nil
                }
                converted[key] = json
            }
            self = .object(converted)
        default:
            return nil
        }
    }

    public static func == (lhs: GoldenJSON, rhs: GoldenJSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case (.bool(let a), .bool(let b)):
            return a == b
        case (.integer(let a), .integer(let b)):
            return a == b
        case (.number(let a), .number(let b)):
            return a == b
        case (.integer(let a), .number(let b)), (.number(let b), .integer(let a)):
            return Double(a) == b
        case (.string(let a), .string(let b)):
            return a.unicodeScalars.elementsEqual(b.unicodeScalars)
        case (.array(let a), .array(let b)):
            return a == b
        case (.object(let a), .object(let b)):
            let left = GoldenJSON.sortedPairs(a)
            let right = GoldenJSON.sortedPairs(b)
            return left.count == right.count
                && zip(left, right).allSatisfy { pair in
                    pair.0.0.unicodeScalars.elementsEqual(pair.1.0.unicodeScalars) && pair.0.1 == pair.1.1
                }
        default:
            return false
        }
    }

    public var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let flag) = self { return flag }
        return nil
    }

    /// 整数の字面か、整数に等しい小数なら Int。
    public var intValue: Int? {
        switch self {
        case .integer(let integer): return Int(exactly: integer)
        case .number(let number): return Int(exactly: number)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .integer(let integer): return Double(integer)
        case .number(let number): return number
        default: return nil
        }
    }

    public var arrayValue: [GoldenJSON]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var objectValue: [String: GoldenJSON]? {
        if case .object(let pairs) = self { return pairs }
        return nil
    }

    /// Foundation の値（`NSNull`・`NSNumber`・`String`・`[Any]`・`[String: Any]`）。AppConfig への上書きなどに使う。
    public var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let flag): return NSNumber(value: flag)
        case .integer(let integer): return NSNumber(value: integer)
        case .number(let number): return NSNumber(value: number)
        case .string(let text): return text
        case .array(let items): return items.map(\.foundationObject)
        case .object(let pairs): return pairs.mapValues(\.foundationObject)
        }
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// 差分の表示用の JSON（キーはスカラー値の順、2 空白の字下げ、末尾改行なし）。
    public var description: String {
        var out = ""
        render(level: 0, into: &out)
        return out
    }

    static func sortedPairs(_ pairs: [String: GoldenJSON]) -> [(String, GoldenJSON)] {
        pairs.map { ($0.key, $0.value) }.sorted { lhs, rhs in
            lhs.0.unicodeScalars.map(\.value).lexicographicallyPrecedes(rhs.0.unicodeScalars.map(\.value))
        }
    }

    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029, 0xFEFF:
                out += "\\u{" + String(scalar.value, radix: 16) + "}"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    func render(level: Int, into out: inout String) {
        let pad = String(repeating: " ", count: 2 * (level + 1))
        let close = String(repeating: " ", count: 2 * level)
        switch self {
        case .null: out += "null"
        case .bool(let flag): out += flag ? "true" : "false"
        case .integer(let integer): out += String(integer)
        case .number(let number): out += number.description
        case .string(let text): out += GoldenJSON.quoted(text)
        case .array(let items):
            if items.isEmpty {
                out += "[]"
                return
            }
            out += "[\n"
            for (index, item) in items.enumerated() {
                out += pad
                item.render(level: level + 1, into: &out)
                out += index + 1 < items.count ? ",\n" : "\n"
            }
            out += close + "]"
        case .object(let pairs):
            if pairs.isEmpty {
                out += "{}"
                return
            }
            let sorted = GoldenJSON.sortedPairs(pairs)
            out += "{\n"
            for (index, pair) in sorted.enumerated() {
                out += pad + GoldenJSON.quoted(pair.0) + ": "
                pair.1.render(level: level + 1, into: &out)
                out += index + 1 < sorted.count ? ",\n" : "\n"
            }
            out += close + "}"
        }
    }
}

extension GoldenJSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: GoldenJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, GoldenJSON)...) {
        var pairs: [String: GoldenJSON] = [:]
        for (key, value) in elements {
            pairs[key] = value
        }
        self = .object(pairs)
    }
}
```

#### `Tests/TestSupport/Golden.swift`（全文。235 行）

```swift
// golden（voicedock@d3d595e の出力）の入力と期待値を読む（PLAN §10.4、T-25）。
import Foundation
import Testing

/// golden の読み込みで起きる誤り（テストの準備の誤り。期待値の不一致ではない）。
public enum GoldenError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case malformedInput(String)
    case noSuchCase(group: String, name: String)
    case expectedMissing(group: String, name: String)
    case expectedAmbiguous(group: String, name: String)
    case missingKey(group: String, name: String, key: String)
    case typeMismatch(group: String, name: String, key: String, expected: String)

    public var description: String {
        switch self {
        case .unreadable(let path): return "golden を読めません: \(path)"
        case .malformedInput(let path): return "golden の入力の形が不正です: \(path)"
        case .noSuchCase(let group, let name): return "golden のケースがありません: \(group)/\(name)"
        case .expectedMissing(let group, let name): return "golden の期待値がありません: \(group)/\(name)"
        case .expectedAmbiguous(let group, let name): return "golden の期待値が 2 つ以上あります: \(group)/\(name)"
        case .missingKey(let group, let name, let key): return "golden の入力に \(key) がありません: \(group)/\(name)"
        case .typeMismatch(let group, let name, let key, let expected):
            return "golden の入力の \(key) が \(expected) ではありません: \(group)/\(name)"
        }
    }
}

/// golden の 1 ケース（`Tests/Golden/inputs/<group>.json` の `cases` の 1 要素）。
public struct GoldenCase: Sendable, CustomTestStringConvertible {
    public let group: String
    public let name: String
    public let fields: [String: GoldenJSON]

    public var testDescription: String { "\(group)/\(name)" }

    public subscript(_ key: String) -> GoldenJSON? { fields[key] }

    public func value(_ key: String) throws -> GoldenJSON {
        guard let value = fields[key] else {
            throw GoldenError.missingKey(group: group, name: name, key: key)
        }
        return value
    }

    public func string(_ key: String) throws -> String {
        guard let text = try value(key).stringValue else { throw mismatch(key, "文字列") }
        return text
    }

    // orderedObject(_:)（キーの順を保ったオブジェクト）は **本チケットには書かない**。`PyJSONValue` を使うので
    // T-45 が `Tests/TestSupport/GoldenCase+PyJSON.swift` の extension で足す（`GoldenCase` 自体は VDCore に依存しない）。

    /// null なら nil。
    public func optionalString(_ key: String) throws -> String? {
        let json = try value(key)
        if json.isNull { return nil }
        guard let text = json.stringValue else { throw mismatch(key, "文字列か null") }
        return text
    }

    public func int(_ key: String) throws -> Int {
        guard let integer = try value(key).intValue else { throw mismatch(key, "整数") }
        return integer
    }

    public func double(_ key: String) throws -> Double {
        guard let number = try value(key).doubleValue else { throw mismatch(key, "数") }
        return number
    }

    /// null なら nil。
    public func optionalDouble(_ key: String) throws -> Double? {
        let json = try value(key)
        if json.isNull { return nil }
        guard let number = json.doubleValue else { throw mismatch(key, "数か null") }
        return number
    }

    public func bool(_ key: String) throws -> Bool {
        guard let flag = try value(key).boolValue else { throw mismatch(key, "真偽値") }
        return flag
    }

    public func array(_ key: String) throws -> [GoldenJSON] {
        guard let items = try value(key).arrayValue else { throw mismatch(key, "配列") }
        return items
    }

    public func strings(_ key: String) throws -> [String] {
        let items = try array(key)
        let texts = items.compactMap(\.stringValue)
        guard texts.count == items.count else { throw mismatch(key, "文字列の配列") }
        return texts
    }

    public func object(_ key: String) throws -> [String: GoldenJSON] {
        guard let pairs = try value(key).objectValue else { throw mismatch(key, "オブジェクト") }
        return pairs
    }

    /// 設定の上書き（`overrides` の各キーと値。キーの昇順）。許されないキーがあれば誤り。
    /// キーは AppConfig の JSON のキーパス（`obsidian.raw.timestampIntervalSeconds` など。PLAN §6.2）。
    public func overrides() throws -> [(key: String, value: GoldenJSON)] {
        guard let pairs = fields["overrides"]?.objectValue else {
            return []
        }
        for key in pairs.keys where !Golden.isAllowedOverride(key) {
            throw mismatch("overrides." + key, "許された設定の上書き")
        }
        return pairs.map { (key: $0.key, value: $0.value) }.sorted { $0.key < $1.key }
    }

    func mismatch(_ key: String, _ expected: String) -> GoldenError {
        GoldenError.typeMismatch(group: group, name: name, key: key, expected: expected)
    }
}

/// golden の入力と期待値。
///
/// - 入力: `Tests/Golden/inputs/<group>.json`（`{"schema": 1, "group": <group>, "cases": [{"name": …}, …]}`）
/// - 期待値: `Tests/Golden/expected/<group>/<name>.<ext>`。`.md` / `.out` はバイト列、`.json` は値で比べる
public enum Golden {
    /// バイト列で比べる期待値の拡張子。
    public static let byteExtensions: Set<String> = ["md", "out"]
    /// 値で比べる期待値の拡張子。
    public static let jsonExtension = "json"

    /// golden の入力で上書きしてよい設定のキー（tools/golden/generate.py の ALLOWED_OVERRIDES と同じ）。
    public static let allowedOverrideKeys: Set<String> = [
        "obsidian.maxTitleBytes", "obsidian.defaultTags", "obsidian.raw.folderTemplate",
        "obsidian.raw.filenameTemplate", "obsidian.raw.timestampIntervalSeconds", "obsidian.raw.partBoundaryHeading",
        "obsidian.wiki.folderTemplate", "obsidian.wiki.filenameTemplate", "obsidian.wiki.linkDailyNote",
        "obsidian.wiki.linkAdjacentDays", "obsidian.wiki.linkTags", "obsidian.wiki.linkOnlyExisting",
        "obsidian.wiki.maxLinks", "llm.maxCharsPerRequest", "llm.maxSecondsPerRequest", "llm.chunkOverlapChars",
        "llm.analysis.order", "llm.analysis.customInstructions", "session.blockGapSeconds",
    ]
    /// `llm.analysis.sections.<節>.<項目>` の上書きで許す節と項目。
    public static let overridableSections: Set<String> = [
        "summary", "timeline", "key_points", "tasks", "decisions", "ideas", "tags",
    ]
    public static let overridableSectionFields: Set<String> = ["enabled", "heading", "maxItems"]
    /// `maxItems` を持つ節（PLAN §6.2・付録 F の F-54。`summary` / `timeline` には無い）。
    public static let sectionsWithMaxItems: Set<String> = [
        "key_points", "tasks", "decisions", "ideas", "tags",
    ]

    public static func isAllowedOverride(_ key: String) -> Bool {
        if allowedOverrideKeys.contains(key) {
            return true
        }
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, parts[0] == "llm", parts[1] == "analysis", parts[2] == "sections",
              overridableSections.contains(parts[3]), overridableSectionFields.contains(parts[4]) else {
            return false
        }
        // summary / timeline に maxItems は無い（書けば CV-01。PLAN §6.2・F-54）。
        return parts[4] != "maxItems" || sectionsWithMaxItems.contains(parts[3])
    }

    public static var root: URL { PackageRoot.file("Tests/Golden") }
    public static var inputsDirectory: URL { root.appendingPathComponent("inputs", isDirectory: true) }
    public static var expectedDirectory: URL { root.appendingPathComponent("expected", isDirectory: true) }

    /// 入力のあるグループの名前（ファイル名の昇順）。
    public static func groupNames() throws -> [String] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: inputsDirectory.path)
        } catch {
            throw GoldenError.unreadable(inputsDirectory.path)
        }
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    /// そのグループの全ケース（入力の順）。
    public static func cases(_ group: String) throws -> [GoldenCase] {
        let url = inputsDirectory.appendingPathComponent("\(group).json")
        guard let data = try? Data(contentsOf: url) else {
            throw GoldenError.unreadable(url.path)
        }
        let document: GoldenJSON
        do {
            document = try JSONDecoder().decode(GoldenJSON.self, from: data)
        } catch {
            throw GoldenError.malformedInput(url.path)
        }
        guard let top = document.objectValue, top["schema"]?.intValue == 1, top["group"]?.stringValue == group,
            let items = top["cases"]?.arrayValue
        else {
            throw GoldenError.malformedInput(url.path)
        }
        var result: [GoldenCase] = []
        for item in items {
            guard let fields = item.objectValue, let name = fields["name"]?.stringValue else {
                throw GoldenError.malformedInput(url.path)
            }
            result.append(GoldenCase(group: group, name: name, fields: fields))
        }
        return result
    }

    /// 名前で 1 ケースを引く。
    public static func testCase(_ group: String, _ name: String) throws -> GoldenCase {
        guard let found = try cases(group).first(where: { $0.name == name }) else {
            throw GoldenError.noSuchCase(group: group, name: name)
        }
        return found
    }

    /// 期待値のファイル（`<name>.md` / `.out` / `.json` のちょうど 1 つ）。
    public static func expectedFile(_ group: String, _ name: String) throws -> URL {
        let directory = expectedDirectory.appendingPathComponent(group, isDirectory: true)
        let candidates = (byteExtensions.sorted() + [jsonExtension]).map {
            directory.appendingPathComponent("\(name).\($0)")
        }
        let existing = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let first = existing.first else {
            throw GoldenError.expectedMissing(group: group, name: name)
        }
        guard existing.count == 1 else {
            throw GoldenError.expectedAmbiguous(group: group, name: name)
        }
        return first
    }

    public static func expectedBytes(_ group: String, _ name: String) throws -> Data {
        let url = try expectedFile(group, name)
        guard let data = try? Data(contentsOf: url) else {
            throw GoldenError.unreadable(url.path)
        }
        return data
    }

    public static func expectedJSON(_ group: String, _ name: String) throws -> GoldenJSON {
        let url = try expectedFile(group, name)
        guard url.pathExtension == jsonExtension, let data = try? Data(contentsOf: url) else {
            throw GoldenError.unreadable(url.path)
        }
        do {
            return try JSONDecoder().decode(GoldenJSON.self, from: data)
        } catch {
            throw GoldenError.unreadable(url.path)
        }
    }
}
```

#### `Tests/TestSupport/GoldenAssert.swift`（全文。84 行）

```swift
// golden の期待値と実際の出力を比べ、違えば unified diff を付けて記録する（PLAN §10.4、T-25）。
import Foundation
import Testing

/// golden の比較。違いは `Issue.record` で記録する（テストを止めない。1 本のテストで全ケースを見るため）。
public enum GoldenAssert {
    /// `.md` / `.out` の期待値と、文字列の UTF-8 のバイト列で比べる。
    public static func matches(
        _ actual: String, group: String, name: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        matches(bytes: Data(actual.utf8), group: group, name: name, sourceLocation: sourceLocation)
    }

    /// `.md` / `.out` の期待値とバイト列で比べる。
    public static func matches(
        bytes actual: Data, group: String, name: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let url: URL
        let expected: Data
        do {
            url = try Golden.expectedFile(group, name)
            expected = try Golden.expectedBytes(group, name)
        } catch {
            Issue.record(Comment(rawValue: "\(error)"), sourceLocation: sourceLocation)
            return
        }
        guard Golden.byteExtensions.contains(url.pathExtension) else {
            Issue.record(
                Comment(rawValue: "golden \(group)/\(name) は値で比べる期待値です（matchesJSON を使う）"),
                sourceLocation: sourceLocation)
            return
        }
        if actual == expected {
            return
        }
        let label = "Tests/Golden/expected/\(group)/\(name).\(url.pathExtension)"
        var message = "golden 不一致: \(label)（期待 \(expected.count) バイト、実際 \(actual.count) バイト）\n"
        let diff = UnifiedDiff.render(
            expected: String(decoding: expected, as: UTF8.self), actual: String(decoding: actual, as: UTF8.self),
            expectedLabel: label, actualLabel: "actual")
        message += diff.isEmpty ? "（UTF-8 の文字列としては同じ。BOM・不正な UTF-8 などバイト列の違い）\n" : diff
        message += writeActual(actual, group: group, name: name, ext: url.pathExtension)
        Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
    }

    /// `.json` の期待値と値で比べる（文字列は Unicode スカラー列、オブジェクトはキーの順を問わない）。
    public static func matchesJSON(
        _ actual: GoldenJSON, group: String, name: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let expected: GoldenJSON
        do {
            expected = try Golden.expectedJSON(group, name)
        } catch {
            Issue.record(Comment(rawValue: "\(error)"), sourceLocation: sourceLocation)
            return
        }
        if actual == expected {
            return
        }
        let label = "Tests/Golden/expected/\(group)/\(name).json"
        var message = "golden 不一致: \(label)\n"
        message += UnifiedDiff.render(
            expected: expected.description, actual: actual.description, expectedLabel: label + "（キーを並べ替えて表示）",
            actualLabel: "actual")
        message += writeActual(Data((actual.description + "\n").utf8), group: group, name: name, ext: "json")
        Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
    }

    /// `VOICEDOCK_GOLDEN_WRITE_ACTUAL=1` のとき、実際の出力を `.build/golden-actual/<group>/<name>.<ext>` に書く。
    static func writeActual(_ data: Data, group: String, name: String, ext: String) -> String {
        guard TestEnvironment.goldenWriteActual else {
            return ""
        }
        let directory = PackageRoot.file(".build/golden-actual/\(group)")
        let file = directory.appendingPathComponent("\(name).\(ext)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file)
            return "実際の出力: \(file.path)\n"
        } catch {
            return "実際の出力を書けませんでした: \(file.path)\n"
        }
    }
}
```

#### `Tests/TestSupport/UnifiedDiff.swift`（全文。150 行）

```swift
// golden の不一致を読むための unified diff（行単位、前後 3 行）（PLAN §10.4、T-25）。
import Foundation

/// 2 つの文字列の unified diff。
///
/// - 行は U+000A だけで分ける（`\r\n` の `\r` は行の中身に残り、`\r` と表示される）。末尾が `\n` なら最後に空の行が 1 つある
/// - 見えない文字は見える形にする（`\t`・`\r`・`\u{…}`）
/// - 同じ文字列なら空文字列を返す
public enum UnifiedDiff {
    enum Operation: Equatable {
        case same(Int, Int)
        case removed(Int)
        case added(Int)
    }

    public static func render(
        expected: String, actual: String, expectedLabel: String, actualLabel: String, context: Int = 3
    ) -> String {
        let old = lines(expected)
        let new = lines(actual)
        let operations = diff(old, new)
        guard operations.contains(where: { if case .same = $0 { return false } else { return true } }) else {
            return ""
        }
        var out = "--- \(expectedLabel)\n+++ \(actualLabel)\n"
        for hunk in hunks(operations, context: context) {
            out += header(hunk)
            for operation in hunk {
                switch operation {
                case .same(let index, _): out += " " + visible(old[index]) + "\n"
                case .removed(let index): out += "-" + visible(old[index]) + "\n"
                case .added(let index): out += "+" + visible(new[index]) + "\n"
                }
            }
        }
        return out
    }

    /// U+000A で分けた行（空の区切りも残す）。
    static func lines(_ text: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value == 0x0A {
                result.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        result.append(String(current))
        return result
    }

    /// 最長共通部分列による差分（行の比較は Unicode スカラー列）。
    static func diff(_ old: [String], _ new: [String]) -> [Operation] {
        let rows = old.count
        let columns = new.count
        var table = Array(repeating: Array(repeating: 0, count: columns + 1), count: rows + 1)
        for row in stride(from: rows - 1, through: 0, by: -1) {
            for column in stride(from: columns - 1, through: 0, by: -1) {
                if old[row].unicodeScalars.elementsEqual(new[column].unicodeScalars) {
                    table[row][column] = table[row + 1][column + 1] + 1
                } else {
                    table[row][column] = max(table[row + 1][column], table[row][column + 1])
                }
            }
        }
        var operations: [Operation] = []
        var row = 0
        var column = 0
        while row < rows, column < columns {
            if old[row].unicodeScalars.elementsEqual(new[column].unicodeScalars) {
                operations.append(.same(row, column))
                row += 1
                column += 1
            } else if table[row + 1][column] >= table[row][column + 1] {
                operations.append(.removed(row))
                row += 1
            } else {
                operations.append(.added(column))
                column += 1
            }
        }
        while row < rows {
            operations.append(.removed(row))
            row += 1
        }
        while column < columns {
            operations.append(.added(column))
            column += 1
        }
        return operations
    }

    /// 変更のまとまりごとに、前後 `context` 行の同じ行を付けたハンク。近いハンクは 1 つにまとめる。
    static func hunks(_ operations: [Operation], context: Int) -> [[Operation]] {
        let changed = operations.indices.filter {
            if case .same = operations[$0] { return false } else { return true }
        }
        var ranges: [ClosedRange<Int>] = []
        for index in changed {
            let lower = max(0, index - context)
            let upper = min(operations.count - 1, index + context)
            if let last = ranges.last, lower <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, upper)
            } else {
                ranges.append(lower...upper)
            }
        }
        return ranges.map { Array(operations[$0]) }
    }

    /// `@@ -開始,行数 +開始,行数 @@`（開始は 1 始まり）。
    static func header(_ hunk: [Operation]) -> String {
        var oldIndices: [Int] = []
        var newIndices: [Int] = []
        for operation in hunk {
            switch operation {
            case .same(let old, let new):
                oldIndices.append(old)
                newIndices.append(new)
            case .removed(let old):
                oldIndices.append(old)
            case .added(let new):
                newIndices.append(new)
            }
        }
        // 片側が空のハンク（context が 0 の純粋な挿入など）は開始を 0 と書く
        let oldStart = oldIndices.first.map { $0 + 1 } ?? 0
        let newStart = newIndices.first.map { $0 + 1 } ?? 0
        return "@@ -\(oldStart),\(oldIndices.count) +\(newStart),\(newIndices.count) @@\n"
    }

    /// 見えない文字を見える形にする。
    static func visible(_ line: String) -> String {
        var out = ""
        for scalar in line.unicodeScalars {
            switch scalar.value {
            case 0x09: out += "\\t"
            case 0x0D: out += "\\r"
            case 0x00...0x1F, 0x7F...0x9F, 0x00A0, 0x2000...0x200F, 0x2028...0x202F, 0x205F, 0x3000, 0xFEFF:
                out += "\\u{" + String(scalar.value, radix: 16) + "}"
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
```


#### `Tests/TestSupport/TestEnvironment+Golden.swift`（T-01 の `TestEnvironment` への extension。全文）

T-01 の `TestEnvironment.swift` は**書き換えない**（地図 §15 の規約。T-24 も extension で足している）。
`value(_:)` は T-01 では `private` なので、この extension は環境変数を自分で読む。

```swift
// golden の道具のための TestEnvironment の追加（T-25）。型の作り手は T-01。
import Foundation

extension TestEnvironment {
    /// `VOICEDOCK_GOLDEN_WRITE_ACTUAL=1` のとき、golden の不一致で実際の出力を `.build/golden-actual/` に書く（T-25）。
    public static var goldenWriteActual: Bool {
        ProcessInfo.processInfo.environment["VOICEDOCK_GOLDEN_WRITE_ACTUAL"] == "1"
    }
}
```

### 4.11 使う側の書き方

- テストは**グループの全ケースを回す**（ケース名を列挙しない）。パラメータ化テストの引数に `try Golden.cases("<group>")` を渡すと、各ケースが `<group>/<name>` と表示される
- パラメータ化テストは引数が 0 件だと何もせずに通るので、同じスイートに「ケースが在る」テストを 1 本置く（TEST-28）
- 入力の読み出しは `GoldenCase` の型付きの取り出しを使い、`fields` を直接たどらない（キーの綴りの誤りが `missingKey` で分かる）
- `.md`・`.out` は `GoldenAssert.matches`、`.json` は `GoldenAssert.matchesJSON` で比べる。`.json` の実際の値は `GoldenJSON` のリテラルで組む
- 時刻は 4.3 の約束で `Instant` にする（`Double` の秒で足さない）

```swift
// 使う側のチケットのテストの形（例: T-26 の sanitize）。
@Test("golden sanitize", arguments: try Golden.cases("sanitize"))
func goldenSanitize(item: GoldenCase) throws {
    let actual = Sanitize.filename(try item.string("input"), maxBytes: try item.int("maxBytes"))
    GoldenAssert.matches(actual, group: item.group, name: item.name)
}

@Test("golden sanitize のケースが在る")
func goldenSanitizeHasCases() throws {
    #expect(!(try Golden.cases("sanitize")).isEmpty)
}
```

### 4.12 設定の上書きを `AppConfig` にする（T-09 が足す `GoldenConfig`）

`AppConfig` は T-09 で入るので、本チケットでは作らない。T-09 が `Tests/TestSupport/GoldenConfig.swift` として次の全文を足す（**未検証**。`AppConfig`・`ConfigLoader.encode` が入った時点で T-09 のテストで確かめる。T-09 のチケットの §10 と `GoldenConfigTests` に反映済み。00-api-map §15 の作り手は T-09）:

```swift
// golden の入力の timeZone と overrides から AppConfig を作る（PLAN §10.4。規約は T-25、実装は T-09）。
import Foundation
import VDCore

/// golden のケースの設定。`AppConfig.defaults(timeZone:)` に `overrides` を JSON のキーパスで当てる。
public enum GoldenConfig {
    public enum Failure: Error, Equatable {
        case notAnObject
        case missingPath(String)
        case undecodable(String)
    }

    public static func make(_ item: GoldenCase) throws -> AppConfig {
        let base = AppConfig.defaults(timeZone: try item.string("timeZone"))
        guard var root = try JSONSerialization.jsonObject(with: ConfigLoader.encode(base)) as? [String: Any] else {
            throw Failure.notAnObject
        }
        for (key, value) in try item.overrides() {
            try set(&root, path: key.split(separator: ".").map(String.init)[...], value: value.foundationObject)
        }
        let data = try JSONSerialization.data(withJSONObject: root)
        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            throw Failure.undecodable(item.testDescription)
        }
    }

    /// 途中のキーは既定の設定に在るオブジェクトでなければならない。最後のキーは無くてもよい（null を省く符号化のため）。
    static func set(_ object: inout [String: Any], path: ArraySlice<String>, value: Any) throws {
        guard let key = path.first else {
            throw Failure.missingPath("")
        }
        if path.count == 1 {
            object[key] = value
            return
        }
        guard var child = object[key] as? [String: Any] else {
            throw Failure.missingPath(path.joined(separator: "."))
        }
        try set(&child, path: path.dropFirst(), value: value)
        object[key] = child
    }
}
```

- `AppConfig.defaults(timeZone:)` を `ConfigLoader.encode` で JSON にし、`overrides()`（キーの昇順）を 1 つずつキーパスの位置に置き、`JSONDecoder` で `AppConfig` に戻す
- 途中のキーが無い・オブジェクトでない → `missingPath`。戻せない（型が違う）→ `undecodable`
- `overrides` の無いケースは `AppConfig.defaults(timeZone:)` と等しい

### 4.13 後続のチケットが参照する名前（索引）

後続のチケットは golden を**グループ名**（`Golden.cases("<group>")`・`GoldenAssert.matches(…, group: "<group>", name: …)`）で参照する。期待値のファイルは `Tests/Golden/expected/<group>/<name>.<ext>`、入力は `Tests/Golden/inputs/<group>.json` だけで、**ここと 4.4・4.5 に無い名前（`Tests/Golden/manifest`、`Tests/Golden/expected/llm/*.txt` など）は存在しない**。ケース名は 4.5 が正（テストはケース名を列挙せずグループの全ケースを回す。4.11）。

| チケット | 使うグループ（`Golden.cases` の引数） |
|---|---|
| T-09 | `GoldenConfig.make` の検査に全グループの `overrides`（`Golden.groupNames()`） |
| T-10 | `keys`（全ケース）・`fingerprint`・`blocks` |
| T-16 | `numbers`（`kind` が `convertTimeout`・`expectedBytes` のケース） |
| T-17 | `transcript_json`・`numbers`（`kind` が `num`・`whisperTimeout` のケース） |
| T-19 | `llm_schema_block`・`llm_prompt`・`llm_repair_prompt`・`llm_validate`・`llm_trim`・`llm_extract`・`llm_strip_think`・`analysis_json`・`prompt_files` |
| T-20 | `llm_chunks`・`llm_dedupe`・`llm_as_json`・`llm_bundles` |
| T-26 | `sanitize`・`frontmatter`・`raw_note`・`note_filename`（`kind` が `raw`・`rawFolder`） |
| T-27 | `note_filename`（`kind` が `daily`・`dailyFolder`）・`daily_note`・`daily_parts`・`timeline`・`timeline_decode`・`wiki` |
| T-45 | `pytext`・`pyjson`・`pyjson_decode`・`pyround` |

`GoldenCase.orderedObject(_:)`（キーの順を保った `[(String, PyJSONValue)]`）は**本チケットには無い**。`PyJSONValue` / `PyJSON.decode` は T-45 が VDCore に作るので、T-45 が `Tests/TestSupport/GoldenCase+PyJSON.swift` の extension で足す（本チケットの `GoldenCase` は VDCore に依存しない）。最初に使うのは T-19。

旧い名前の読み替え（T-19 §5.0 が書いていた名前 → 実際の `<group>/<name>.<ext>`）:

| 旧い名前 | 実際 |
|---|---|
| `llm/schema_block_final.txt` | `llm_schema_block/final_default.out` |
| `llm/schema_block_partial.txt` | `llm_schema_block/partial_default.out` |
| `llm/schema_block_final_no_tags_ideas.txt` | `llm_schema_block/final_tags_ideas_disabled.out` |
| `llm/system_analyze.txt` | `llm_prompt/analyze_default.out` |
| `llm/system_analyze_custom.txt` | `llm_prompt/analyze_custom.out`（`llm.analysis.customInstructions` = `健康の話題は要約しない`） |
| `llm/system_map.txt` | `llm_prompt/map_default.out` |
| `llm/system_reduce.txt` | `llm_prompt/reduce_default.out` |

## 5. テスト

### `Tests/PolicyTests/GoldenInventoryTests.swift`（`@Suite("GoldenInventory")`）

| 関数名 | 表示名 | 確かめること |
|---|---|---|
| `groupsArePresent` | golden の入力のグループが決めたとおりそろっている | `inputs/*.json` のグループの集合が 4.4 の 31 個とちょうど同じ |
| `everyCaseHasExactlyOneExpected` | 各ケースに期待値がちょうど 1 つあり、余分な期待値が無い | 各グループにケースが在る・名前が一意で `[a-z0-9_]+`・各ケースに期待値がちょうど 1 つ・入力の無い期待値のファイルもグループも無い |
| `generatedByIsComplete` | GENERATED_BY.txt に生成の条件がそろっている | 4.6 の 6 項目がそろい、値の形が正しい |
| `generatorToolsExist` | 生成ツールがリポジトリに在り、generate.sh は実行できる | 3 つの生成ツールが在り、`generate.sh` が実行できる |

### `Tests/PolicyTests/GoldenSupportTests.swift`（`@Suite("GoldenSupport")`）

| 関数名 | 表示名 | 確かめること |
|---|---|---|
| `bytesMatchRecordsNothing` | 一致すれば何も記録しない（バイト列） | `sanitize/plain` の期待値 `2026-08-29 raw` と一致すれば何も記録しない |
| `bytesMismatchRecordsIssue` | 違えば記録する（バイト列） | 末尾に空白を足すと記録する（`withKnownIssue`） |
| `jsonMatchRecordsNothing` | 一致すれば何も記録しない（値。PLAN §4.2 の固定値） | `keys/partkey_fixed` が PLAN §4.2 の固定値（slug `a5d046dce76cfedc`）と値で一致 |
| `jsonMismatchRecordsIssue` | 違えば記録する（値） | slug の最後の 1 文字を変えると記録する |
| `wrongComparisonKindRecordsIssue` | 比べ方を取り違えたら記録する | `.json` の期待値を `matches` で比べると記録する |
| `goldenJSONComparesScalars` | GoldenJSON の文字列はスカラー列で比べる（NFC と NFD を区別する） | NFC と NFD の文字列を区別する |
| `goldenJSONNumbers` | GoldenJSON の数は整数と小数を数として比べ、真偽値とは区別する | `integer(2) == number(2.0)`、`integer(1) != bool(true)`、`init?(any:)` が真偽値の `NSNumber` を `bool` にする |
| `goldenJSONObjectOrder` | GoldenJSON のオブジェクトはキーの順を問わない | キーの順の違う 2 つのオブジェクトが等しい |
| `goldenJSONKeepsLeadingBOM` | GoldenJSON は文字列の先頭の U+FEFF を保つ（JSONSerialization は落とす） | JSON のエスケープで書いた先頭の U+FEFF が残る。`pyjson_decode/bom_rejected` の `text` も U+FEFF で始まる |
| `goldenCaseAccessors` | GoldenCase の型付きの取り出しと誤り | `string`・`int` の取り出し、`missingKey`・`typeMismatch`・`noSuchCase` |
| `overridesAreAllowed` | 入力の設定の上書きはすべて許されたキー（generate.py と同じ一覧） | 全ケースの `overrides` が許されたキーだけ（1 件以上ある）。許されないキーを拒む |
| `overrideListMatchesGenerator` | 許された上書きの一覧が generate.py の ALLOWED_OVERRIDES・SECTION_OVERRIDE と同じ | `Golden` の許可の一覧が `generate.py` の `ALLOWED_OVERRIDES`・`SECTION_OVERRIDE` と同じ集合（2 か所の一覧のずれを落とす） |
| `diffOfSameTextIsEmpty` | unified diff: 同じなら空 | 同じ文字列の差分は空 |
| `diffOfOneLine` | unified diff: 1 行の変更 | 1 行の変更のハンクが逐語で一致 |
| `diffShowsTrailingNewlineAndInvisibles` | unified diff: 末尾の改行の有無と見えない文字 | 末尾の改行の有無が行の差として出て、タブと U+3000 がエスケープで見える |
| `diffSeparatesDistantHunks` | unified diff: 離れた変更は別のハンク | 離れた 2 か所の変更が 2 つのハンクになり、見出しが逐語で一致 |

#### `Tests/PolicyTests/GoldenInventoryTests.swift`（全文。75 行）

```swift
// golden の入力と期待値がそろっていることを確かめる（PLAN §10.4、T-25）。
import Foundation
import Testing

@testable import TestSupport

@Suite("GoldenInventory")
struct GoldenInventoryTests {
    /// 後続のチケットが使うグループ（T-25 の表と同じ）。名前を変えるときは使う側のチケットと同じ PR で直す。
    static let requiredGroups: Set<String> = [
        "analysis_json", "blocks", "daily_note", "daily_parts", "fingerprint", "frontmatter", "keys", "llm_as_json",
        "llm_bundles", "llm_chunks", "llm_dedupe", "llm_extract", "llm_prompt", "llm_repair_prompt",
        "llm_schema_block", "llm_strip_think", "llm_trim", "llm_validate", "note_filename", "numbers",
        "prompt_files", "pyjson", "pyjson_decode", "pyround", "pytext", "raw_note", "sanitize", "timeline",
        "timeline_decode", "transcript_json", "wiki",
    ]

    @Test("golden の入力のグループが決めたとおりそろっている")
    func groupsArePresent() throws {
        #expect(Set(try Golden.groupNames()) == Self.requiredGroups)
    }

    @Test("各ケースに期待値がちょうど 1 つあり、余分な期待値が無い")
    func everyCaseHasExactlyOneExpected() throws {
        let fileManager = FileManager.default
        for group in try Golden.groupNames() {
            let cases = try Golden.cases(group)
            #expect(!cases.isEmpty, "\(group) にケースがありません")
            let names = cases.map(\.name)
            #expect(Set(names).count == names.count, "\(group) のケース名が重複しています")
            for name in names {
                let allowed = "abcdefghijklmnopqrstuvwxyz0123456789_".unicodeScalars
                #expect(name.unicodeScalars.allSatisfy { allowed.contains($0) }, "\(group)/\(name): 名前は小文字の英数字と _")
                #expect(throws: Never.self) { _ = try Golden.expectedFile(group, name) }
            }
            let directory = Golden.expectedDirectory.appendingPathComponent(group, isDirectory: true)
            let files = try fileManager.contentsOfDirectory(atPath: directory.path).sorted()
            let expectedFiles = try names.map { try Golden.expectedFile(group, $0).lastPathComponent }.sorted()
            #expect(files == expectedFiles, "\(group) に入力の無い期待値があります")
        }
        let expectedGroups = try fileManager.contentsOfDirectory(atPath: Golden.expectedDirectory.path).sorted()
        #expect(expectedGroups == (try Golden.groupNames()), "入力の無い期待値のグループがあります")
    }

    @Test("GENERATED_BY.txt に生成の条件がそろっている")
    func generatedByIsComplete() throws {
        let text = try String(contentsOf: Golden.root.appendingPathComponent("GENERATED_BY.txt"), encoding: .utf8)
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            #expect(parts.count == 2, "形式が不正な行: \(line)")
            if parts.count == 2 {
                fields[parts[0]] = parts[1]
            }
        }
        #expect(Set(fields.keys) == ["voicedock_ref", "voicedock_commit", "python", "unicodedata", "uv", "generator"])
        #expect(fields["voicedock_ref"] == "d3d595e")
        #expect(fields["voicedock_commit"]?.hasPrefix("d3d595e") == true)
        #expect(fields["voicedock_commit"]?.count == 40)
        #expect(fields["python"]?.hasPrefix("3.12.") == true)
        #expect(fields["unicodedata"] == "15.0.0")
        #expect(fields["uv"]?.hasPrefix("uv ") == true)
        #expect(fields["generator"] == "tools/golden/generate.py")
        #expect(text.hasSuffix("\n"))
    }

    @Test("生成ツールがリポジトリに在り、generate.sh は実行できる")
    func generatorToolsExist() {
        let fileManager = FileManager.default
        for file in ["tools/golden/generate.sh", "tools/golden/generate.py", "tools/golden/make_inputs.py"] {
            #expect(fileManager.fileExists(atPath: PackageRoot.file(file).path), "\(file) がありません")
        }
        #expect(fileManager.isExecutableFile(atPath: PackageRoot.file("tools/golden/generate.sh").path))
    }
}
```


#### `Tests/PolicyTests/GoldenSupportTests.swift`（全文。161 行）

```swift
// TestSupport の golden の道具（GoldenJSON・Golden・GoldenAssert・UnifiedDiff）そのものを確かめる（TEST-05、T-25）。
import Foundation
import Testing

@testable import TestSupport

@Suite("GoldenSupport")
struct GoldenSupportTests {
    static let fixedPartkey = "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"

    @Test("一致すれば何も記録しない（バイト列）")
    func bytesMatchRecordsNothing() {
        // PLAN §8.6 SN: 変える文字が無い名前はそのまま
        GoldenAssert.matches("2026-08-29 raw", group: "sanitize", name: "plain")
    }

    @Test("違えば記録する（バイト列）")
    func bytesMismatchRecordsIssue() {
        withKnownIssue {
            GoldenAssert.matches("2026-08-29 raw ", group: "sanitize", name: "plain")
        }
    }

    @Test("一致すれば何も記録しない（値。PLAN §4.2 の固定値）")
    func jsonMatchRecordsNothing() {
        GoldenAssert.matchesJSON(
            ["key": .string(Self.fixedPartkey), "slug": "a5d046dce76cfedc"], group: "keys", name: "partkey_fixed")
    }

    @Test("違えば記録する（値）")
    func jsonMismatchRecordsIssue() {
        withKnownIssue {
            GoldenAssert.matchesJSON(
                ["key": .string(Self.fixedPartkey), "slug": "a5d046dce76cfedd"], group: "keys", name: "partkey_fixed")
        }
    }

    @Test("比べ方を取り違えたら記録する")
    func wrongComparisonKindRecordsIssue() {
        withKnownIssue {
            GoldenAssert.matches("{}", group: "keys", name: "partkey_fixed")
        }
    }

    @Test("GoldenJSON の文字列はスカラー列で比べる（NFC と NFD を区別する）")
    func goldenJSONComparesScalars() {
        #expect(GoldenJSON.string("\u{304C}") != GoldenJSON.string("\u{304B}\u{3099}"))
        #expect(GoldenJSON.string("a") == GoldenJSON.string("a"))
    }

    @Test("GoldenJSON の数は整数と小数を数として比べ、真偽値とは区別する")
    func goldenJSONNumbers() {
        #expect(GoldenJSON.integer(2) == GoldenJSON.number(2.0))
        #expect(GoldenJSON.integer(1) != GoldenJSON.bool(true))
        #expect(GoldenJSON(any: NSNumber(value: true)) == .bool(true))
        #expect(GoldenJSON(any: 3) == .integer(3))
        #expect(GoldenJSON(any: 1.5) == .number(1.5))
    }

    @Test("GoldenJSON のオブジェクトはキーの順を問わない")
    func goldenJSONObjectOrder() throws {
        let a = try JSONDecoder().decode(GoldenJSON.self, from: Data(#"{"b": 1, "a": [true, null]}"#.utf8))
        let b = try JSONDecoder().decode(GoldenJSON.self, from: Data(#"{"a": [true, null], "b": 1}"#.utf8))
        #expect(a == b)
    }

    @Test("GoldenJSON は文字列の先頭の U+FEFF を保つ（JSONSerialization は落とす）")
    func goldenJSONKeepsLeadingBOM() throws {
        // JSON の本文は ["\u{FEFF}x"] を JSON のエスケープ（バックスラッシュ・u・feff）で書いたもの
        let json = "[\"" + "\\" + "ufeffx\"]"
        let value = try JSONDecoder().decode(GoldenJSON.self, from: Data(json.utf8))
        #expect(value.arrayValue?.first?.stringValue?.unicodeScalars.first?.value == 0xFEFF)
        // 入力の読み込みも同じ（pyjson_decode/bom_rejected の text は U+FEFF で始まる）
        let text = try Golden.testCase("pyjson_decode", "bom_rejected").string("text")
        #expect(text.unicodeScalars.first?.value == 0xFEFF)
    }

    @Test("GoldenCase の型付きの取り出しと誤り")
    func goldenCaseAccessors() throws {
        let item = try Golden.testCase("keys", "session_overflow2")
        #expect(try item.string("deviceID") == "DJIMIC3")
        #expect(try item.int("overflow") == 2)
        #expect(throws: GoldenError.missingKey(group: "keys", name: "session_overflow2", key: "nope")) {
            _ = try item.string("nope")
        }
        let mismatch = GoldenError.typeMismatch(
            group: "keys", name: "session_overflow2", key: "overflow", expected: "文字列")
        #expect(throws: mismatch) {
            _ = try item.string("overflow")
        }
        #expect(throws: GoldenError.noSuchCase(group: "keys", name: "nope")) {
            _ = try Golden.testCase("keys", "nope")
        }
    }

    @Test("入力の設定の上書きはすべて許されたキー（generate.py と同じ一覧）")
    func overridesAreAllowed() throws {
        var count = 0
        for group in try Golden.groupNames() {
            for item in try Golden.cases(group) {
                count += try item.overrides().count
            }
        }
        #expect(count > 0)
        #expect(!Golden.isAllowedOverride("llm.analysis.sections.mood.enabled"))
        #expect(!Golden.isAllowedOverride("cleanup.deleteSourceAudio"))
        #expect(Golden.isAllowedOverride("llm.analysis.sections.key_points.maxItems"))
        #expect(Golden.isAllowedOverride("llm.analysis.sections.summary.heading"))
        // F-54: maxItems を持つのは 5 節だけ。
        #expect(!Golden.isAllowedOverride("llm.analysis.sections.summary.maxItems"))
        #expect(!Golden.isAllowedOverride("llm.analysis.sections.timeline.maxItems"))
    }

    @Test("許された上書きの一覧が generate.py の ALLOWED_OVERRIDES・SECTION_OVERRIDE と同じ")
    func overrideListMatchesGenerator() throws {
        let source = try String(contentsOf: PackageRoot.file("tools/golden/generate.py"), encoding: .utf8)
        guard let start = source.range(of: "ALLOWED_OVERRIDES = {"),
            let end = source.range(of: "}", range: start.upperBound..<source.endIndex),
            let open = source.range(of: #"sections\.("#),
            let middle = source.range(of: #")\.("#, range: open.upperBound..<source.endIndex),
            let close = source.range(of: ")$", range: middle.upperBound..<source.endIndex)
        else {
            Issue.record("generate.py に ALLOWED_OVERRIDES か SECTION_OVERRIDE がありません")
            return
        }
        let quoted = source[start.upperBound..<end.lowerBound].split(separator: "\"", omittingEmptySubsequences: false)
        let keys = quoted.enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
        #expect(keys.count == Golden.allowedOverrideKeys.count)
        #expect(Set(keys) == Golden.allowedOverrideKeys)
        let sections = source[open.upperBound..<middle.lowerBound].split(separator: "|").map(String.init)
        let fields = source[middle.upperBound..<close.lowerBound].split(separator: "|").map(String.init)
        #expect(Set(sections) == Golden.overridableSections)
        #expect(Set(fields) == Golden.overridableSectionFields)
        // F-54: maxItems を持たない節の一覧も 2 か所で同じ。
        guard let without = source.range(of: "SECTIONS_WITHOUT_MAX_ITEMS = {"),
            let withoutEnd = source.range(of: "}", range: without.upperBound..<source.endIndex)
        else {
            Issue.record("generate.py に SECTIONS_WITHOUT_MAX_ITEMS がありません")
            return
        }
        let excluded = source[without.upperBound..<withoutEnd.lowerBound]
            .split(separator: "\"", omittingEmptySubsequences: false)
            .enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
        #expect(Set(excluded) == Golden.overridableSections.subtracting(Golden.sectionsWithMaxItems))
    }

    @Test("unified diff: 同じなら空")
    func diffOfSameTextIsEmpty() {
        #expect(UnifiedDiff.render(expected: "a\nb\n", actual: "a\nb\n", expectedLabel: "e", actualLabel: "a").isEmpty)
    }

    @Test("unified diff: 1 行の変更")
    func diffOfOneLine() {
        let text = UnifiedDiff.render(expected: "a\nb\nc\n", actual: "a\nB\nc\n", expectedLabel: "e", actualLabel: "a")
        #expect(text == "--- e\n+++ a\n@@ -1,4 +1,4 @@\n a\n-b\n+B\n c\n \n")
    }

    @Test("unified diff: 末尾の改行の有無と見えない文字")
    func diffShowsTrailingNewlineAndInvisibles() {
        let text = UnifiedDiff.render(
            expected: "x\t\u{3000}\n", actual: "x\t\u{3000}", expectedLabel: "e", actualLabel: "a")
        #expect(text == "--- e\n+++ a\n@@ -1,2 +1,1 @@\n x\\t\\u{3000}\n-\n")
    }

    @Test("unified diff: 離れた変更は別のハンク")
    func diffSeparatesDistantHunks() {
        var lines = (1...20).map(String.init)
        let old = lines.joined(separator: "\n")
        lines[1] = "two"
        lines[18] = "nineteen"
        let text = UnifiedDiff.render(
            expected: old, actual: lines.joined(separator: "\n"), expectedLabel: "e", actualLabel: "a")
        #expect(text.components(separatedBy: "\n@@ ").count == 3)
        #expect(text.hasPrefix("--- e\n+++ a\n@@ -1,5 +1,5 @@\n 1\n-2\n+two\n 3\n 4\n 5\n@@ -16,5 +16,5 @@\n"))
    }
}
```


## 6. 破壊による証明

| 壊し方 | 落ちるべきテスト |
|---|---|
| `Tests/Golden/expected/sanitize/plain.out` の末尾に空白を 1 つ足す | `bytesMatchRecordsNothing`・`bytesMismatchRecordsIssue`（known issue が起きなくなる） |
| `Tests/Golden/expected/keys/partkey_fixed.json` の `slug` を `a5d046dce76cfedd` にする | `jsonMatchRecordsNothing`・`jsonMismatchRecordsIssue` |
| `Tests/Golden/expected/sanitize/plain.out` を消す | `everyCaseHasExactlyOneExpected`・`bytesMatchRecordsNothing` |
| `Tests/Golden/expected/sanitize/extra.out` を作る | `everyCaseHasExactlyOneExpected` |
| `Tests/Golden/inputs/pyround.json` を消す | `groupsArePresent`・`everyCaseHasExactlyOneExpected` |
| `GENERATED_BY.txt` の `unicodedata=15.0.0` の行を消す | `generatedByIsComplete` |
| `chmod -x tools/golden/generate.sh` | `generatorToolsExist` |
| `GoldenJSON.==` の `.string` の比較を `a == b`（Swift の正準等価）にする | `goldenJSONComparesScalars` |
| `Golden.cases` の `JSONDecoder().decode(GoldenJSON.self, from: data)` を `GoldenJSON(any: JSONSerialization.jsonObject(with: data))` にする | `goldenJSONKeepsLeadingBOM` |
| `Golden.allowedOverrideKeys` から `"session.blockGapSeconds"` を消す | `overrideListMatchesGenerator` |
| `generate.py` の `SECTION_OVERRIDE` から `ideas\|` を消す | `overrideListMatchesGenerator` |
| `UnifiedDiff.render` の `context: Int = 3` を `2` にする | `diffSeparatesDistantHunks` |

`make_inputs.py` を変えて `make golden` を実行し忘れた、というずれはテストでは検出しない（テストは生成物だけを見る）。7 章の「もう一度実行して差分が無い」で検出する。

## 7. 受け入れ条件

- [ ] `make golden` が voicedock の作業ツリーを変えずに終わる（前後で `git -C <voicedock> status --porcelain` が同じ・`git -C <voicedock> stash list` が同じ）
- [ ] `make golden` をもう一度実行しても `git diff --quiet Tests/Golden` が真（生成が再現する）
- [ ] `Tests/Golden/inputs/` が 31 ファイル、`Tests/Golden/expected/` が 294 ファイル、`GENERATED_BY.txt` が 4.6 の形
- [ ] `generate.py` の `SystemExit`（許されない上書き・指紋の再現の不一致・修復プロンプトの前提の崩れ・未知の kind）が 1 つも出ない
- [ ] `make test` が通る（`GoldenInventory`・`GoldenSupport` の全テスト。`withKnownIssue` の 3 本は「known issue」として通る）
- [ ] `make lint` が通る
- [ ] 6 章の破壊による証明を行い、落ちたテスト名を PR 本文に貼った
- [ ] PR 本文に `du -sh Tests/Golden` の結果を書いた（期待値だけで約 153 KiB）

## 8. SPEC の変更

なし

## 9. マージ後にやること

- T-09 に 4.12 の `GoldenConfig.swift` を足す（T-09 のチケットへ追記。`AppConfig` の JSON のキーが PLAN §6.2 と違えば、`overrides` のキーパスが通らないので T-09 のテストで分かる） → T-09 のチケットに反映済み（2026-09-19。T-09 §10）
- 使う側のチケットのテストの形を 4.11 に揃える:
  - T-26: 「`Tests/Golden/manifest` から読む」を `Golden.cases(<group>)` に直す（`manifest` は作らない）
  - T-19: §5.0 の golden のファイル名を次に読み替える（拡張子は `.out`、置き場所はグループのディレクトリ）: `llm/schema_block_final.txt` → `llm_schema_block/final_default.out`、`schema_block_partial.txt` → `llm_schema_block/partial_default.out`、`schema_block_final_no_tags_ideas.txt` → `llm_schema_block/final_tags_ideas_disabled.out`、`system_analyze.txt` → `llm_prompt/analyze_default.out`、`system_analyze_custom.txt` → `llm_prompt/analyze_custom.out`、`system_map.txt` → `llm_prompt/map_default.out`、`system_reduce.txt` → `llm_prompt/reduce_default.out`。ほかに `final_maxitems_null`・`partial_tasks_disabled`・`map_custom_multiline`・`analyze_custom_contains_placeholder` と `llm_repair_prompt`・`llm_validate` などのグループもある（4.4）
- voicedock の参照コミットを変えるとき（本計画では変えない）は `generate.sh` の `VOICEDOCK_REF` を変え、`make golden` の差分を 1 つずつ PLAN の X-xx と照らしてから PR にする

## 10. API 地図への変更提案

- `00-api-map.md` の TestSupport の節（または新しい「テスト用の共有」節）に 4.10 の表を載せる: `GoldenJSON`・`GoldenError`・`GoldenCase`・`Golden`・`GoldenAssert`・`UnifiedDiff`、`TestEnvironment.goldenWriteActual` → 00-api-map に反映済み（2026-09-18。§14・§15 に型の名前。API の細部は 4.10 が正）
- T-09 の行に TestSupport の `GoldenConfig.make(_ item: GoldenCase) throws -> AppConfig` を足す（4.12） → 00-api-map に反映済み（2026-09-18。§15）
- README の索引: T-25 の前提は T-01 のまま（PolicyTests のターゲットは T-01 が作る。T-04 は不要） → README に反映済み
- （整合修正で追記）後続のチケットが参照する名前の索引を 4.13 に足した。T-19 §5.0 の旧い名前（`Tests/Golden/expected/llm/*.txt`）の読み替えも 4.13 に載せた
- （整合修正 H-1）`GoldenCase.orderedObject(_:)` を本チケットから外した（`PyJSONValue` を使うため T-25 → T-45 の循環になる）。T-45 が `Tests/TestSupport/GoldenCase+PyJSON.swift` の extension で足す → 00-api-map §15 に反映済み
- （整合修正 M-9）`TestEnvironment.goldenWriteActual` は T-01 の `TestEnvironment.swift` を全文で置き換えず、`Tests/TestSupport/TestEnvironment+Golden.swift` の extension で足す（§15 の規約）
- （整合修正 F-54）`Golden.isAllowedOverride` から `llm.analysis.sections.summary.maxItems` と `.timeline.maxItems` を外した（仕様 §6.2 で `maxItems` を持つのは 5 節だけになった）。`tools/golden/generate.py` の `SECTION_OVERRIDE` も同じ（`SECTIONS_WITHOUT_MAX_ITEMS` と `is_allowed_override`）
