# V6 移植メモ: 診断・状態表示・CI・E2E・文書テスト・版の固定

出典はすべて voicedock `d3d595e`。`file:line` は `git show d3d595e:<file> | cat -n` の行番号。
Swift 版の対応先は仕様書（tmp/witty-gliding-clover.md）の節番号で示す。

---

## 1. 診断（doctor）— voicedock の実装

### 1.1 枠組み（`src/voicedock/doctor.py`）

- 状態は 4 値（`doctor.py:45-57`）: `ok`=`✓` / `notice`=`!` / `fail`=`✗` / `skip`=`-`
- 行の書式（`doctor.py:74-77`）: `[<記号>] <ラベル 21 桁左詰め><詳細>`、続き行は 27 桁インデント。
  区切り線 `─`×56、見出し `VoiceDock doctor`（`doctor.py:59-62`）
- サマリ（`doctor.py:669-674`）: `"{passed} checks passed, {failed} failed, {notices} notices"`。**skip は数えない**
- 実行規則（`doctor.py:617-656`）:
  - 検査は登録順に走る。**fatal な検査が 1 行でも fail を出したら、以降の検査は実行せず skip 行**
    （`"skipped（先行する致命的な検査が失敗）"`）を出す
  - 例外: `always=True` の検査（D-17 削除モードの表示だけ）は、設定が読めていれば先行 fail でも実行（`doctor.py:105-112, 640-641`）
  - 終了コードは fail が 1 行でもあれば 4、無ければ 0。**notice は失敗ではない**（D-17 は常に notice）
- **副作用を持たない**（`doctor.py:10-11`）: DB は `migrate=False`、存在確認してから開く（`doctor.py:156-190`）。
  ただし voicedock は D-3 / D-13 で一時ファイル `.voicedock-doctor-probe.tmp` を書いて消していた（`doctor.py:199-206, 424-436`）。
  フォルダは作らない（`doctor.py:374-376`、テンプレートの `{yyyymmdd}` フォルダが増えるため）。
  health（120 秒ごと）は `os.access` だけ（`health.py:109-125, 211-219`）
- 登録順（`doctor.py:589-614`、`tests/unit/test_doctor.py:246-270` が固定）:
  `D-1, D-2, D-3, D-7, D-8, D-9, D-10, D-11, D-12, D-13, D-18, D-20, D-17`（**D-17 は最後**）
- 欠番: D-4〜D-6, D-14〜D-16, D-19（番号を詰めない・再利用しない。D-19 と同題の検査は D-20 として戻した。`test_doctor.py:247-255`）
- SPEC 同期: §19.2 表の `D-\d+` 集合 = 登録集合、件数 13（`test_doctor.py:273-282`）

### 1.2 各検査（コンテナ側 13 件）

| ID | 検査 | 判定・文言（逐語） | 出典 |
|---|---|---|---|
| D-1 | 設定ファイルが在り全 V 規則を通る | OK: `Config file` / `Config validation  {keys} keys, 0 errors`。違反は続き行に 1 件 1 行 | `doctor.py:115-147` |
| D-2 | DB へ接続でき schema 版が最新 | 無い: `{path}  （ありません）`（**作らない**）。版違い: `（schema v{v} は未対応。v{N} を期待）`。OK: `{path} (schema v{v}, {n} recordings, {n} sessions, {n} events, {x.x} MiB)` | `doctor.py:156-190` |
| D-3 | データ領域が書込可・空き ≥ margin | 書込は probe ファイル。空き不足は fail | `doctor.py:193-219` |
| D-7 | whisper-cli が在り `--help` 成功 | VAD フラグが無ければ **notice**（fail ではない）: `(VAD: NOT supported)`。**版文字列で判定しない**（VAD はビルド設定で落ちる） | `doctor.py:222-234` |
| D-8 | Whisper モデルが在り size>0 | 0 バイト: `（0 バイト。取得が途中で止まっている）` | `doctor.py:237-283` |
| D-9 | VAD モデル（enabled 時） | 無効なら notice: `transcription.vad.enabled: false  <- 無音から幻覚が生成され、13 倍以上遅くなります` | `doctor.py:242-271` |
| D-10 | ffmpeg/ffprobe | （Swift 版では不要） | `doctor.py:286-322` |
| D-11 | LLM エンドポイント env | （Swift 版では不要。URL を表示する方針だけ参考） | `doctor.py:325-343` |
| D-12 | **LLM へ実リクエスト** | OK: `{model}  ({elapsed:.1f}s, {tokens} tokens)`、usage が無ければ `? tokens`。D-11 失敗なら skip | `doctor.py:346-366` |
| D-13 | Vault が書込可・目印在り・出力フォルダ作成可 | 「書けない」と「Vault でない」を**別文言**: `（{marker}/ がありません。Vault が未マウントか、別の場所を指しています。新しい Vault なら Obsidian で 1 度開いてください）` | `doctor.py:369-421` |
| D-18 | Helper 稼働（heartbeat 鮮度） | 不明（読めない）は stale 扱い（`heartbeat.py:55-58`: `age is None or age > max`） | `doctor.py:439-484` |
| D-20 | inbox の取り残し | **notice（fail にしない）・自動で消さない**。対象状態 = `PART_TERMINAL − {FAILED}`（`status.py:413`、status と**同じ定数**を共有） | `doctor.py:487-525` |
| D-17 | 削除モード（三重ロックを個別に） | **判定は `status.Locks` を使い、ここで論理式を書き直さない**（`doctor.py:533-535`、`test_doctor.py:862`）。0 台なら `no device connected`（#148）。不明は `unknown` | `doctor.py:528-586` |

D-17 の表示（SPEC §19.2 と逐語一致をテスト `test_doctor.py:753-797`）:

```text
[!] Source deletion      DISABLED
      lock 1  : config.yaml=false, helper.conf=false
      lock 2-A: voicedock-reaper is NOT installed  <- deletion is impossible
      lock 2-B: MOUNT_MODE=ro (device mounted read-only)
```

### 1.3 ホスト側（`scripts/doctor.sh`、7 件。Docker 由来が大半）

実行順 `doctor.sh:396-402`: DH-1 → DH-10 → DH-13 → DH-12 → DH-16 → DH-17 → DH-15。
Swift 版に意味が残るもの:

| ID | 内容 | Swift 版での扱い |
|---|---|---|
| DH-12 | `launchctl print gui/$(id -u)/com.voicedock.ingest` が 0 = **load 済み**（`doctor.sh:260-272`） | 共存ガード（仕様 §8.1）/ DR-13。**「稼働中」ではなく「load 済み」**（StartOnMount で起動される） |
| DH-16 | ラッパが**署名済み**で plist がそれを経由（TCC の許可先を決めるため）（`doctor.sh:283-310`） | アプリ自身の署名（ad-hoc だと TCC がビルドごとに失効）を診断する検査は仕様に無い |
| DH-17 | heartbeat 閾値 > StartInterval（**等しくても不可**）。実行中も heartbeat を更新する前提（#117）（`doctor.sh:312-354`） | CV-31 と、沈黙の検出の誤報（§3 参照） |

### 1.4 health（`src/voicedock/health.py`）

- 目的が doctor と違うので**実装を共有しない**（`health.py:14-16`）
- **デバイス未接続を unhealthy にしない**、Helper 停止は unhealthy（`health.py:18-24`）
- 1 つ失敗しても全検査を実行（`health.py:222-228`）
- 静的検査: health は書き込み・削除の呼び出しを持たない（`tests/unit/test_health.py:105-`）

---

## 2. 状態表示（status）— パネル「詳細」の中身の参考

`src/voicedock/status.py`。**落ちない・DB を作らない**（`status.py:16-17, 266-285`）。

レイアウト（`status.py:530-563`、SPEC §17.2）:

```text
VoiceDock v1.0.0
────────────────────────────────────────────────────────
Helper                : running   (last seen 42s ago, v5.5.0, mount=readOnly (MOUNT_MODE=ro))
Devices connected     : 1  (DJIMIC3, readOnly)
Device free space     : DJIMIC3 4.2 GiB
Inbox                 : 3 parts pending, 1.1 GiB  (+ 取り残し 1 件 0.2 GiB)
Delete queue          : 0 requested, 0 awaiting result
Source deletion       : DISABLED  (lock1=false, lock2A=reaper absent, lock2B=readOnly)

Parts
  DISCOVERED          : 6
  ...（PartStatus の全値。表示順 status.py:48-61）
  SKIPPED             : 18    (無音)
  FAILED              : 2    (次回接続時に再試行)

Sessions
  ...（SessionStatus の全値。表示順 status.py:62-76。注記なし）

Backlog               : 未処理 3.2 時間ぶん（6 part）、うち 1 part は長さ不明
Staging usage         : 0.1 GiB / 5.0 GiB
Free disk (/data)     : 58.1 GiB

Failed parts
  <partkey>
    2026-08-29 07:12  WHISPER_TIMEOUT  retry 3/3
  … ほか N 件
  → 次にデバイスを接続したときに自動で再試行される（§15.2）
```

規則:
- ラベル幅 22、バケット字下げ 2・幅 20（`status.py:38-44`）
- 状態の件数は **enum の全値を回す**（表示順だけを持つ）。0 件も出す（`status.py:269-270`）
- 注記は **entity ごとの辞書**。Part 用を Session へ流用しない（Session の FAILED に「次回接続時に再試行」が付いた事故）（`status.py:78-90`）
- **注意**: Part SKIPPED の注記「（無音）」は不正確（重複・元ファイル不在も SKIPPED）。Swift 版では写さない
- Backlog = 非終端 Part の件数・`duration` 合計、**NULL は 0 として数え件数を併記**（`status.py:326-348, 128-134`）。FAILED は Backlog に入れない
- Failed 一覧: `started_at` 昇順、最大 20 件、`partkey` を 1 行目・詳細を次行（`status.py:95-116, 351-371`）。`error_code` が無ければ `unknown`
- ロック表示: lock1 は**両方 true のときだけ true**、enabled は `lock1 && reaper_installed is True && mount_readonly is False`（**不明は起こらない側**）（`status.py:137-162`）
- マウント表示語: 0 台 → `no device`、観測不明 → `unknown`、それ以外 `readOnly` / `writable`（`status.py:175-194`、#107 / #148）
- inbox: 「処理待ち」と「取り残し（終端 − FAILED）」を分ける（#120、`status.py:424-467`）。**取り残しを pending に数えない**
- 終了コードは FAILED があっても 0（`status.py:577-600`）

---

## 3. 沈黙の検出と #117（heartbeat の鮮度）

- voicedock の Helper は**実行の最後にしか** heartbeat を書かず、1 日分のコピー（見込み 11.1 分、POC `docs/POC.md:788-863`）が
  閾値 900 秒を超え、**動いている Helper を死んだと報告してパイプラインを止めた**（#117）。
  結論: 「生きていること」を表す値は**長い処理の途中でも更新する**（`docs/POC.md:844-863`、SPEC §19.2 DH-17 の注記）
- コピー速度 11.9 MB/s、安定性判定は候補数に依らず約 6 秒（`docs/POC.md:790-812`）
- **DJI Mic 3 は PC 接続で録音を自動停止する**（`docs/POC.md:741`）

---

## 4. SPEC 同期（`tests/spec_sync.py`）

### 4.1 節の切り出し（`spec_sync.py:34-68`）
- 見出し行 `^#{1,6} ` の後が `<heading>` で始まる最初の行から、**次の見出し**まで。
  「次の見出し」は `^#{1,6} (?:\d|付録)` に一致する行（数字か「付録」で始まる見出しだけ）
- **コードフェンス（行頭空白 + ```）の中は見出しとして扱わない**（bash コメント `# 2026-...` で節が切れた事故 #13）
- SPEC が見つからなければ **skip ではなく fail**（`spec_sync.py:24-31`）

### 4.2 表の行の取り出し
- 規則 ID: `^\| \*{0,2}(<PREFIX>-\d+)\*{0,2} \|`（太字 `**ND-24**` を許す）（`spec_sync.py:293-305`）
- 打ち消し行（本文が `~~` で始まる）は**廃止**として除外（`spec_sync.py:358-368`）
- エラーコード表: `^\| \`([A-Z][A-Z_]*)\` \| ...` の 5 列。**宣言順を enum と一致**（`test_errors.py:67`）
- 状態: `^\| \`([A-Z_]+)\` \|` を出現順（`spec_sync.py:456-461`、`test_states.py:66-72` が enum の順序と一致を見る）
- 遷移表: 5 列表を辺集合に正規化。現状態 `—`（行の作成）/ 注記行 / 次状態 `（遷移なし）` / `X のまま` は辺にしない。
  `` `A` / `B` `` は両方に展開（`spec_sync.py:489-518`）
- 復旧表: ```text ブロック内の `A -> B` 行（`spec_sync.py:521-526`）
- ログイベント: §16.4 の ```text ブロックを `/` と改行で分割、**出現順 = 実装の登録順**（`spec_sync.py:116-121`、`test_log.py:116,141`）
- 本文が `LEVEL event_name` の形で指示するイベント名が §16.4 に在ること（O-5: 書けば必ず落ちるコード）（`spec_sync.py:124-142`）
- コードブロックの写し: `spec_section_code(section, language, index)`（正規表現・argv・スキーマなど、実装が SPEC の写しであることを固定）
- 本文の `reason=<name>` を SPEC の語として集める（定数と一緒に動くテストを避ける）（`spec_sync.py:232-241`）
- 件数を直書きしない。件数の literal は 1 か所（`test_readme.py:37-40` が唯一の突き合わせ点）

### 4.3 ND と テストの結び付け
- voicedock は **ND 番号を SPEC から機械的に読んでいない**。`test_ndNN_...` という関数名と docstring の慣習だけ（`tests/unit/test_no_delete.py:375-1223`）。
  SPEC §20.4 の ND 表とテストの 1 対 1 は機械検査されていない
- 廃止 ND（ND-10〜17、旧 ND-09 Daily 側）は**反転テスト**（「もう止めない」ことを固定）として残した（`test_no_delete.py:990-1149`）

### 4.4 文書テスト
- `test_spec_docs.py`: §6 の木 ⊇ 実装モジュール、木に在って未実装 = `PLANNED`、版・付録の連番
- `test_readme.py`: 診断件数（ホスト 7 / コンテナ 13）を**実装から数え**、README と SPEC の散文に同じ数字が在ること。README に SPEC の版を直書きしない。README が指すファイル・make ターゲットの実在
- `test_runbook.py`: `docs/E2E.md` の `## 2. 判定表` の `E2E-nn` 行が SPEC §20.3 と**1 対 1・同順**、判定欄が `✅/✗/⬜/—` で始まる（空欄・散文を許さない）、
  各シナリオに `### 3.N E2E-nn — ` の手順節が在る、手順が参照する `./scripts/*` `./helper/*` が実在、**検査自体の陽性対照**（抽出正規表現が拾えること）
- `test_coverage_doc.py` + `docs/TEST_COVERAGE.md`: SPEC §20.1 の対象と 1 対 1、列はテストファイルか `#NN` のみ、未カバーの上限 2

---

## 5. 静的検査（AST テスト）一覧と仕様 PT の対応

| voicedock | 内容 | 仕様 PT |
|---|---|---|
| `test_no_device_delete.py:23-65` | 削除呼び出し（`unlink/remove/rmdir/removedirs/rmtree`）は `paths.py` だけ。**属性呼び出しと裸の名前呼び出しの両方** | PT-01 |
| `test_no_device_delete.py:68-86` | 削除関数名の import による迂回（`from os import remove`）も禁止 | PT-01（Swift では `Darwin.unlink` 等の修飾形と `removefile` を足す） |
| `test_no_device_delete.py:89-111` | `DevicePath` を受け取る関数が削除しない | PT-10 相当 |
| `test_no_device_delete.py:124-149` | `PurePosixPath` に I/O が無い（型による保証の前提） | CR-11 |
| `test_no_device_delete.py:155-185` | `safe_unlink_queue` は `delete/` `result/` 直下の `.json` だけ | CR-10 |
| `test_states.py:~420-445` | 状態名の文字列定数が `states.py` 以外に無い＋自己テスト | PT-06 |
| `test_states.py:447` | `states.py` は他モジュールを import しない | PT-07 |
| `test_db.py:~699` | `status` を書く SQL は record_transition だけ（f-string も見る） | PT-05 |
| `test_retry.py:~438-451` | requeue が時刻を見ない | （PT 無し） |
| `test_no_delete.py:~1425-1434` | `can_delete_source` の式の形（外側が And、`||` が内側） | §8.9.1 / TEST-30 |
| `test_transcribe.py:~327` | 子プロセス起動の場所 | PT-03 |
| `test_health.py:93-115` | health の import 制限と**書き込み・削除の呼び出しが無い** | （PT 無し。DR に相当） |
| `test_config.py:~410` | config は環境変数を読まない | （PT 無し） |
| `test_helper_portability.py:121-131` | **検査自体が違反を検出できること**・**コメントで誤検出しないこと** | PT 各項の自己テスト |
| `test_helper_portability.py:187-215` | ingest はデバイスへ rm/mv/リダイレクトを書かない、diskutil は ingest だけ | PR-11 / PR-19 |
| `test_helper_portability.py:217` | 既定で reaper を配置しない | PT-11 |
| `test_helper_portability.py:309-322` | **`.wav` 確定の後に墓標**（本体→記録の順）を静的に | （PT 無し。T-14 の「静的検査も」に番号が無い） |
| `test_version_pinning.py` | §6 参照 | PT-13 |
| ruff `S602/S604/S605`（`pyproject.toml:51-53`） | shell=True 等 | PT-04 |

---

## 6. 版の固定（`tests/unit/test_version_pinning.py`）

- コメント除去後に `:(latest|master|main)\b` を Dockerfile / compose / Makefile / ci.yml から禁止（`:27-32, 64-72`）
- base image は digest 固定（`@sha256:`）（`:46-52`）、whisper.cpp は `ARG WHISPER_CPP_REF=vX.Y.Z` のタグ（`:75-83`）
- `UV_IMAGE` のタグ固定（`:86-90`。`Makefile:1` = `ghcr.io/astral-sh/uv:0.12.13-python3.12-trixie-slim`）
- lock ファイルがコミット済み（`:93-96`）
- Actions は `vX.Y.Z` か 40 桁 SHA（`:99-110`）
- **穴**: `runs-on: ubuntu-latest`（`ci.yml:23,58`）は `:latest` 形でないので素通りしていた

---

## 7. CI（`.github/workflows/ci.yml`）

- トリガ: push `[main, develop]`、pull_request `[main, develop, "feat/**", "docs/**"]`（stacked PR のため）（`ci.yml:3-12`）
- `permissions: contents: read`
- job `check`: checkout → setup-uv（版 0.12.13）→ `uv sync --frozen` → ruff check → ruff format --check → mypy --strict → pytest（`ci.yml:21-46`）
- job `no-delete`（**別 job**、main の required check）: `test_no_delete.py test_reaper.py test_no_device_delete.py`。
  正の対照を同じ job で回す（`ci.yml:48-74`）
- CI はプロジェクトイメージをビルドしない。ffmpeg / whisper が要るテストは `needs_*` マーカーで自動 skip（`conftest.py:37-52`、理由文に「make test で走る」）

---

## 8. ネットワーク遮断（`tests/conftest.py:55-101`、`tests/unit/test_no_network.py`）

- **autouse fixture で全テストに掛ける**。`socket.socket.connect` / `connect_ex` / `socket.create_connection` を差し替え、
  `AF_INET` / `AF_INET6` なら `NetworkBlocked` を投げる。**ループバック（`::1`）も遮断**（`test_no_network.py:39-41`）
- `AF_UNIX` は塞がない。`socket()` の生成は許す（初期化エラーと区別するため）
- 子プロセスには効かない（別テストが見る）
- 陽性対照（外へ出ると落ちる）と陰性対照（MockTransport は通る・UNIX ソケットは通る）の両方がある

---

## 9. E2E（`docs/E2E.md`）

### 9.1 書式
- `## 0. 記録の規約`: 生の出力を貼る。判定は `✅ PASS` / `✗ FAIL` / `⬜ 未実施` / `— 対象外`。空欄にしない（`E2E.md:24-29`）
- `## 2. 判定表`: `| E2E-nn | シナリオ | 判定 | 記録 |`（`E2E.md:42-57`）
- `## 3. シナリオ` の各節は `### 3.N E2E-nn — <題>`、中に **手順 / 期待 / 判定 / 生の出力**
- 1 件でも FAIL なら修正チケットを起票し次の Phase へ進まない

### 9.2 各シナリオの要点と見つかった欠陥

| # | 要点 | 見つかった欠陥 |
|---|---|---|
| E2E-01 | 1 本通し。単一チャンクでも Timeline が出る（代替経路） | — |
| E2E-02 | **危険な窓はコピー中**（変換中ではない）。コピーに時間がかかる状態を作る（再コピーさせる）→ 30 秒で抜く。`.partial` が消え、**デバイス 12 件のサイズが 1 バイトも変わらない**ことを一覧で確認。再接続で再コピー | #120（再コピー分が inbox の取り残しになり `pending` と誤報） |
| E2E-03 | whisper 中に抜いても完走。**削除 OFF なら COMPLETED**（`SOURCE_DELETE_PENDING` は v3 の名残）。**10 秒の録音では窓が取れない**（数分の録音が要る） | — |
| E2E-04 | Vault を `mv` で退避 → 再起動 → `OBSIDIAN_NOT_FOUND`、書かない、元音声が残る、診断が「.obsidian/ がありません」と別文言 → 戻して再起動で再開。**v5.33 まで手順が空振り**（空ディレクトリに書いていた。#134） | #134 |
| E2E-05 | 抜き挿し 6 回以上。`candidates=0`、件数が増えない | — |
| E2E-06 | 1 日分（16 時間・32 Part）: Raw 1 + Daily 1、**次の接続（24 時間）までに処理が終わる**。**RTF は文字数で決まる**（3.9〜4.6 字/秒、密な発話 16 時間で約 15 時間） | 未実施（運用で確認） |
| E2E-07 | 無音 1 本。警告行の理由の並びは ErrorCode の宣言順、`⚠` は許可リスト判定 | #140（SKIPPED に「再試行されます」と書いていた） |
| E2E-08 | 1 本だけ whisper を失敗させる。**失敗のさせ方**: モデルのパスを実在する別ファイル（VAD モデル）へ向けた（モデルを消すと起動時検査で再起動ループ） | #131 / #133（FAILED の 16 kHz まで消した）/ #135（error_message がヘルプ全文） |
| E2E-09 | 保存後に同じ日の Part を追加 → 再オープン 4 回で 1 ファイルのまま | #108（再オープンで解析がやり直されなかった） |
| E2E-10 | 削除 ON。Raw 検証を通った分だけ消え、無音は残る（根拠 B 導入前）。**手で叩いた reaper は `Operation not permitted`、LaunchAgent の子として通る（TCC）** | #151 / #152 / #154 / #156（**単体テストは全部緑のまま**） |
| E2E-11 | `--resolve-absent`（`source_deleted_at` を入れない）、`--backlog` は **0 件が正しい**（削除 OFF 期間の Part は Raw 検証を経ていない）。対象外の理由を出す | — |
| E2E-12 | 再起動で途中から再開・**二重処理しない**（前後の件数表） | — |

---

## 10. 破壊による証明（SPEC §20.6）

- 1 回に 1 か所、落ちたテスト名を PR に書く、「通ってしまった」を放置しない
- voicedock の「同じ inode へ書き戻す」は Docker bind mount 由来（Swift 版では不要）
- §20.5 の「テストが試験にならない 7 形」（`SPEC.md` §20.5）: 環境を fixture が握っていない / 検証対象を parametrize の元に / 件数直書き /
  実行後の値だけ / 文言の前半だけ / 多重防御が破損を隠す / 壊す箇所と落ちるテストが非対応
