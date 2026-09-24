# VoiceDock for Mac 実機 E2E

**この文書が実機手順の正本である。**GitHub issue の本文にも PR の説明にも手順を置かない。

> **なぜ正本をここに置くか。**issue は git 管理外なので、参照実装 voicedock では
> サブコマンドを 6 本削除しても **issue 本文の手順は何も落ちずに残った**（#93）。
> 実機を繋いだ当日、最初の 1 行で止まる。ここに置けば
> `Tests/PolicyTests/RunbookTests.swift` が**手順が参照するスクリプトと make ターゲットの実在**を検査する。

この文書は `docs/SPEC.md` の `S9`（= PLAN 付録 B.3）と **1 対 1・同順**である。
シナリオを足すときは PLAN 付録 B.3 → `make spec` → この文書、の順に直す。

## 0. 記録の規約

`docs/POC.md` §0 と同じ。**要約した数値だけを書かない。生の出力を貼る。**

- 判定は `✅ PASS` / `✗ FAIL` / `⬜ 未実施` / `— 対象外` のいずれかで始める。**空欄にしない。散文で書かない**
- `#### 記録` には、打ったコマンドと出力を ```text のフェンスでそのまま貼る。**端末からのコピーを整形しない**
- 日時・録音の本数・デバイス名を書く。`<VAULT>` と `<HOME>` は伏せてよいが、**行を削らない**
- **`【利用者が行う】` と書いた手順は利用者が自分で実行する。**エージェントは実行しない
- 実機で消えてよいのは「この試験のために新しく録った録音」と「すでに Raw ノートで確認済みの録音」だけである。削除 OFF の試験（§3 の E2E-10・11・17 以外）では 1 本も消えない。**E2E-11 の「過去分を削除対象にする」では、以前の録音（§1 の下準備で取り込んだものを含む）も Raw ノートの検証を通っていれば消える**
- **1 件でも FAIL なら修正チケットを起票し、次の Phase へ進まない**（PLAN §12.4）

## 1. 前提

> **実施は T-38・T-39 のマージ後に行う。**この文書（T-35）が develop に入った時点では、削除の段（T-38 の削除フロー・T-39 の SKIPPED の後始末）がまだ空である。
> そのため Part は `RAW_SAVED`、Session は `SAVED` で止まって `COMPLETED` にならず、`source_delete_skipped` も出ない。
> E2E-03・07・08 などの「`COMPLETED`」「`source_delete_skipped reason=delete_source_audio_disabled`」の期待は、T-38・T-39 が入るまで観測できない。

- `make app` で組み立てた `VoiceDock.app`（T-34）を使う。**ad-hoc 署名では行わない**（TCC の許可がビルドのたびに失効する）。
  署名の確認: `codesign -dvvv <VoiceDock.app のパス> 2>&1 | grep -E 'Identifier=|TeamIdentifier='`
- **削除は OFF のまま行う**（E2E-10 / E2E-11 / E2E-17、§5、§6 を除く）。パネルの「元音声の削除」で三重ロックが 3 つとも掛かっていることを確かめてから始める
- パネルの「詳細・診断 → 診断を実行」がすべて ✓ か ! であること（✗ が残っていたら先に直す）
- 環境変数（各シナリオのコマンドが使う）:

```bash
export VD_HOME="$HOME/Library/Application Support/VoiceDock"
export VD_DB="$VD_HOME/voicedock.sqlite"
export VAULT="<Obsidian の Vault の絶対パス>"
export DEV="<デバイスのボリューム名。例 DJIMIC3>"
export BACKUP="<デバイスの退避先の絶対パス。利用者が決める。/Volumes の外・空か新規>"
```

### 共通のコマンド

| 名前 | コマンド |
|---|---|
| `[C-1]` 状態の件数 | `sqlite3 "$VD_DB" "SELECT status, COUNT(*) FROM recordings GROUP BY status ORDER BY status;" ; sqlite3 "$VD_DB" "SELECT status, COUNT(*) FROM sessions GROUP BY status ORDER BY status;"` |
| `[C-2]` 直近のログ | `tail -n 200 "$VD_HOME/logs/app.log"` |
| `[C-3]` 工程のログ | `grep -E 'part_discovered\|normalize_completed\|transcription_completed\|raw_note_saved\|session_merged\|llm_completed\|obsidian_saved' "$VD_HOME/logs/app.log"` |
| `[C-4]` 遷移の履歴 | `sqlite3 -header -column "$VD_DB" "SELECT id, entity_type, entity_key, from_status, to_status, error_code, detail, created_at FROM events ORDER BY id DESC LIMIT 60;"` |
| `[C-5]` inbox と staging | `find "$VD_HOME/inbox" "$VD_HOME/staging" -type f \| sort ; du -sh "$VD_HOME/inbox" "$VD_HOME/staging"` |
| `[C-6]` 削除キュー | `ls -la "$VD_HOME/queue/delete" "$VD_HOME/queue/result" "$VD_HOME/queue/rejected"` |
| `[C-7]` デバイスの一覧【利用者が行う】 | `find "/Volumes/$DEV" -type f -name '*.wav' -exec stat -f '%z %m %N' {} \; \| sort` |
| `[C-8]` マウントの観測【利用者が行う】 | `/sbin/mount \| grep -F "/Volumes/$DEV"` |
| `[C-9]` ノートの一覧 | `find "$VAULT/Daily/Voice" -type f -name '*.md' -exec stat -f '%z %m %N' {} \; \| sort` |
| `[C-10]` パネルの写し | パネルの「状態」「要対応」「詳細・診断 → 状態の詳細」に出ている文言を**そのまま書き写す**（スクリーンショットは貼らない。文字で残す） |
| `[C-11]` ロックの表示 | パネルの「元音声の削除」の 3 行（`ロック 1  : …` / `ロック 2-A: …` / `ロック 2-B: …`）と、その下の注意書きを**そのまま書き写す** |
| `[C-12]` reaper のログ | `tail -n 100 "$VD_HOME/logs/reaper.log"` |
| `[C-13]` 削除の結果 | `sqlite3 -header -column "$VD_DB" "SELECT partkey, status, delete_request_id, source_deleted_at FROM recordings WHERE source_deleted_at IS NOT NULL OR delete_request_id IS NOT NULL ORDER BY started_at;"` |
| `[C-14]` 削除のログ | `grep -E 'delete_requested\|source_deleted\|source_delete_skipped\|source_delete_pending\|reaper_run\|reaper_failed\|deletion_enabled\|deletion_disabled' "$VD_HOME/logs/app.log"` |
| `[C-15]` デバイスの空き容量【利用者が行う】 | `df -h "/Volumes/$DEV"` |
| `[C-16]` reaper の導入状態 | `ls -l@ "$VD_HOME/bin/" ; cat "$VD_HOME/bin/reaper.conf"` |

- `[C-7]` と `[C-8]` は**読み取りだけ**である。`diskutil`・`hdiutil`・`rm`・`mv` をデバイスに対して打つ手順はこの文書に無い
- `sqlite3` は macOS に最初から在る（`/usr/bin/sqlite3`）。**DB は読み取りだけ**（`SELECT` 以外を打たない）
- `[C-11]`〜`[C-16]` は削除 ON の試験（E2E-10・11・17、§5、§6）で使う。`[C-15]` も読み取りだけである
- `[C-16]` の `reaper.conf` は、一度も有効にしていなければ無い（`cat` が `No such file or directory` を返す）。有効化の後は `DELETE_SOURCE_AUDIO=true`、無効化の後は `DELETE_SOURCE_AUDIO=false` の行を含む
- `[C-7]` はデバイスが挿さっているときしか取れない。「前」の `[C-7]` は、**挿したあと `[C-8]` に `read-only` が出てから**取る（削除 OFF ではアプリはデバイスに書かないので、挿した直後の一覧がそのまま「前」になる。再マウントの途中で打つとマウント先が一瞬無く、`No such file or directory` になる）

### 実機を使う前にやること【利用者が行う】

試験の日の最初に、次の 3 つを順に行う。**1 は実機を挿す前に行う。**デバイスに対しては読み取りだけで、書き込むのはホームの下だけである。

1. **voicedock（参照実装）が動いていないことを確かめる。**このアプリは voicedock との共存を見張らない（PLAN F-61 で共存ガードを取り下げた）。
   voicedock の Helper が登録されたままだと、同じデバイスを 2 つのアプリが同時に扱う。確かめ方は読み取りだけ:

   ```bash
   launchctl print "gui/$(id -u)/com.voicedock.ingest" > /dev/null 2>&1; echo "exit=$?"
   command -v docker && docker ps --format '{{.Names}}' 2>/dev/null | grep -i voicedock
   ```

   期待: 1 行目が `exit=0` **でない**（Helper の LaunchAgent が登録されていない）。2 行目は docker のパスのほかに何も出ない（docker が無ければ何も出さずに終わる）。
   **どちらかが残っていたら試験を始めない。**voicedock の止め方はこの文書に書かない（voicedock の側の手順で止める）

2. **このアプリで下準備の接続を 1 回行う。**このアプリは voicedock の取り込み済みの記録を引き継がない（PLAN F-60）ので、
   最初の接続ではデバイスに残っている以前の録音も**すべて**取り込まれる（削除 OFF なので 1 本も消えない）。
   以前の録音の処理が各シナリオに混ざらないように、E2E-01 の前にいちど挿して、パネルが「待機中」に戻るまで待つ。
   以前の録音のノートが `$VAULT` に書かれる。普段の Vault を汚したくなければ、試験用の Vault を作って「保存先（Vault）」に選んでおく。
   この接続の途中で、次の段を行う:

   - **デバイスの全ファイルの一覧を退避する。**`[C-8]` に `read-only` が出たあとに取る。
     `[C-7]` は `.wav` だけを見るので、ここでは種類を問わず全ファイルを取る:

     ```bash
     mkdir -p "$BACKUP"
     find "/Volumes/$DEV" -type f -exec stat -f '%z %m %N' {} \; | sort | tee "$BACKUP/device-all-before.txt"
     wc -l "$BACKUP/device-all-before.txt"
     ```

     試験をすべて終えたら、同じ `find` の出力を `device-all-after.txt` に取り、`comm -23` で**前にあって後に無い行**が 0 行であることを確かめる
     （削除 OFF の 13 件では録音は 1 本も消えない。後には新しく録った分が増えているだけになる）:

     ```bash
     comm -23 "$BACKUP/device-all-before.txt" "$BACKUP/device-all-after.txt"
     ```

3. 下準備の接続が終わったら、以後の各シナリオはそのシナリオの `#### 前提` どおりに録音を足して挿す

### ログの数え方

`app.log` は大きくなると `app.log.1` へ 1 世代だけ回転する。**前後で件数を比べるときは 2 つを合わせて数える**:

```bash
cat "$VD_HOME/logs/app.log.1" "$VD_HOME/logs/app.log" 2>/dev/null | grep -c -E '<イベント名>'
```

後の件数が前より少なければ、あいだで 2 回以上回転して古い行が落ちている。そのときは件数を比べずに、時刻が試験の開始より後の行だけを貼る。

### 手順の実在確認

この文書が書くリポジトリの中のコマンドは、**いまの develop に在るものだけ**である。

- `make vendor`（T-03。`whisper-cli` と `llama-server` を作る。`make app` の前に 1 回）
- `make app`（T-34。中身は `scripts/make-app.sh` の `debug`。開発用の証明書で署名した `dist/VoiceDock.app` ができる）
- 起動は `open dist/VoiceDock.app`（リポジトリのルートで）。`swift run VoiceDockApp` は使わない（`.app` にならず、署名も TCC の許可も試験の条件と違う）
- `make test`（すべて終えたあとに回す。この文書の書式を `Tests/PolicyTests/RunbookTests.swift` が検査する）
- `make spec`（PLAN 付録 B.3 を直したときだけ）
- `make release`（T-34。中身は `scripts/release.sh`。Developer ID で署名・公証した `.app`。削除 ON の試験は `make app` の `.app` でも行える）
- `make test-nd`（§4.1 の G-1 の記録）と `make test-disk`（§4.3 の G-3 の記録。**実機を抜いてから利用者が行う**）

リポジトリの中のファイルのパスと `make` のターゲットは、`RunbookTests` が**実在を検査する**。無いものを書くと `make test` が落ちる。

## 2. 判定表

| # | シナリオ | 削除 | 判定 | 記録 |
|---|---|---|---|---|
| E2E-01 | 1 本を通しで | OFF | ✅ PASS | §3.1 |
| E2E-02 | コピー中に抜く | OFF | ⬜ 未実施 | §3.2 |
| E2E-03 | 文字起こし中に抜く | OFF | ✅ PASS | §3.3 |
| E2E-04 | Vault を利用不可にする | OFF | ✅ PASS | §3.4 |
| E2E-05 | 抜き挿しを 6 回以上 | OFF | ✅ PASS | §3.5 |
| E2E-06 | 1 日分を 1 セッションに | OFF | ⬜ 未実施 | §3.6 |
| E2E-07 | 無音の Part を混ぜる | OFF | ⬜ 未実施 | §3.7 |
| E2E-08 | 1 本だけ文字起こしを失敗させる | OFF | ⬜ 未実施 | §3.8 |
| E2E-09 | 保存後に同じ日の Part を追加 | OFF | ⬜ 未実施 | §3.9 |
| E2E-10 | 削除 ON で通し | ON | ⬜ 未実施 | §3.10 |
| E2E-11 | 過去分の削除・手動で消した分の完了 | ON | ⬜ 未実施 | §3.11 |
| E2E-12 | 文字起こし中に強制終了 | OFF | ⬜ 未実施 | §3.12 |
| E2E-13 | 処理中にスリープ | OFF | ⬜ 未実施 | §3.13 |
| E2E-14 | アプリが動いていない間に接続 | OFF | ✅ PASS | §3.14 |
| E2E-15 | 取り下げ | — | — 対象外 | §3.15 |
| E2E-16 | リムーバブルボリュームの許可を拒否 | OFF | ⬜ 未実施 | §3.16 |
| E2E-17 | 削除を無効化 | ON→OFF | ⬜ 未実施 | §3.17 |
| E2E-18 | 取り下げ | — | — 対象外 | §3.18 |

## 3. シナリオ

### 3.1 E2E-01 — 1 本を通しで

#### 前提
削除 OFF。**1 分程度を 1 本だけ**新しく録音する。デバイスに他の録音があってもよい（[C-7] で一覧を控える）。§1 の下準備の接続が済んでいる。

#### 手順
【利用者が行う】

1. [C-1]・[C-9] を取る（前）
2. デバイスを USB で挿す
3. [C-8] に `read-only` が出たら [C-7] を取る（前）
4. パネルの「状態」が「取り込み中」→「文字起こし中」→「要約中」と変わるのを見る
5. 「待機中」に戻ったら [C-1]・[C-3]・[C-7]・[C-8]・[C-9]・[C-10] を取る（後）

**落とし穴**: 単一チャンクの Timeline は voicedock でも代替経路。**Timeline のために LLM を 2 回呼んでいないこと**（今回の分の `llm_completed` が 1 件）を確かめる。

#### 期待
`part_discovered` → `normalize_completed` → `transcription_completed` → `raw_note_saved` → `session_merged` → `llm_completed` → `obsidian_saved` がこの順に 1 組出る。
Raw ノートと Daily ノートが各 1 枚できる。**元音声が残る**（[C-7] の前後が一致）。
[C-8] に `read-only` が出る（`device.mountMode` の既定は `ro`。アプリが読み取り専用へ再マウントした）。
**単一チャンクでも Daily に `## Timeline` と時刻の見出しが出る**（Map の中間結果が無くても代替経路が働く）。

#### 記録

実施: 2026-09-24 夜。DEV=DJIMIC3、新規録音 1 本（TX00_MIC006_20260924_211229_orig.wav、約 2 分13秒）。既存の録音 4 本（TX_MIC001_20260915_165730 配下）はそのまま残した状態で試験した。

[C-1]（前）:
```text
recordings: COMPLETED|12 RAW_SAVED|1 SKIPPED|1
sessions:   COMPLETED|2 OPEN|1
```

[C-1]（後・今すぐ要約の前）:
```text
recordings: COMPLETED|12 RAW_SAVED|2 SKIPPED|1
sessions:   COMPLETED|2 OPEN|1
```

[C-1]（今すぐ要約の後）:
```text
recordings: COMPLETED|14 SKIPPED|1
sessions:   COMPLETED|3
```

[C-3]（今回の分。話者分離のイベントも実測どおり載せる。F-89）:
```text
2026-09-24T21:15:16+09:00 INFO  part_discovered recording_key=DJIMIC3/TX_MIC001_20260915_165730/TX00_MIC006_20260924_211229_orig.wav duration_s=133.1
2026-09-24T21:15:16+09:00 INFO  normalize_completed recording_key=DJIMIC3/TX_MIC001_20260915_165730/TX00_MIC006_20260924_211229_orig.wav in_bytes=19199176 out_bytes=4263296 elapsed_s=0.3
2026-09-24T21:15:22+09:00 INFO  transcription_completed recording_key=DJIMIC3/TX_MIC001_20260915_165730/TX00_MIC006_20260924_211229_orig.wav elapsed_s=4.9 chars=594 rtf=0.037 speech_ratio=0.695
2026-09-24T21:15:22+09:00 INFO  diarization_completed recording_key=DJIMIC3/TX_MIC001_20260915_165730/TX00_MIC006_20260924_211229_orig.wav speakers=1 elapsed_s=0.4
2026-09-24T21:15:22+09:00 INFO  raw_note_saved session_key=DJIMIC3:20260924 parts=2 bytes=5922
（パネルの「今すぐ要約」を押した後）
2026-09-24T21:16:42+09:00 INFO  session_merged session_key=DJIMIC3:20260924 parts=2 excluded=0 chars=1783
2026-09-24T21:16:53+09:00 INFO  llm_completed session_key=DJIMIC3:20260924 chunks=1 elapsed_s=10.7
2026-09-24T21:16:53+09:00 INFO  obsidian_saved session_key=DJIMIC3:20260924 path="Daily/Voice/Wiki/20260924/2026-09-24 Voice.md" bytes=3133
```
`llm_completed` は今回のセッション（`DJIMIC3:20260924`）に 1 件だけ（落とし穴クリア。Timeline のために 2 回呼んでいない）。

[C-7]（前後の `diff`。挿した直後 → 全工程の完了後）:
```text
$ diff /tmp/e2e01-device-before.txt /tmp/e2e01-device-final.txt
（差分なし）
```
挿した直後の一覧は新規録音を含む 5 本（TX00_MIC002〜006）。全工程（コピー・変換・文字起こし・話者分離・Raw・統合・要約・Daily 保存）の後でも、この 5 本のサイズ・mtime は 1 バイトも変わらなかった。

[C-8]:
```text
/dev/disk20 on /Volumes/DJIMIC3 (msdos, local, nodev, nosuid, read-only, noowners, noatime, fskit)
```

[C-9]（後。`diff`）:
```text
4d3
< 4012 1790250875 .../Daily/Voice/Raw/20260924/2026-09-24 raw.md
5a5
> 5922 1790252122 .../Daily/Voice/Raw/20260924/2026-09-24 raw.md
（今すぐ要約の後、Wiki/20260924/2026-09-24 Voice.md 3133 バイトが新規に増えた）
```

[C-10]（パネル。スクリーンショットより書き写し）:
```text
待機中
最終接続  接続中 (DJIMIC3) ・未処理なし
デバイスの空き容量 DJIMIC3 27.7 GiB
保存先 (Vault): VoiceDockTestVault
モデル: Whisper large-v3-turbo (q5_0) ✓ / VAD Silero VAD v5.1.2 ✓ / LLM 読み込んだモデル (3605803b) ✓
元音声の削除: 無効
要対応: （表示なし）
```

Daily ノート `## Timeline` の見出し（単一チャンクの代替経路）:
```text
## Timeline

### 20:51–21:14

- 防衛費の増減は単純な戦争意志の問題ではなく、防衛力の構築や技術導入（例：ドローン）への戦略的アプローチが必要であると指摘。
```

#### 判定
✅ PASS

### 3.2 E2E-02 — コピー中に抜く

#### 前提
削除 OFF。**危険な窓はコピー中である**（変換中ではない。変換は inbox から読むのでデバイスと無関係）。
**コピーに数分かかる状態を作る**: 30 分程度の録音を 3 本、新しく録っておく（24 bit / 48 kHz なら 1 本約 259 MB）。

#### 手順
【利用者が行う】

1. [C-1]・[C-5] を取る
2. デバイスを挿す
3. [C-8] に `read-only` が出たら [C-7] を取り、**ファイルに保存する**（[C-7] のコマンドの末尾に `| tee "$BACKUP/e2e02-before.txt"` を足す）
4. パネルが「取り込み中 n/3」の間に、**コピーが始まってから 30 秒待って抜く**
5. [C-5]・[C-2] を取る
6. もう一度挿し、[C-8] に `read-only` が出たら [C-7] を同じく `| tee "$BACKUP/e2e02-after.txt"` で取り、`diff "$BACKUP/e2e02-before.txt" "$BACKUP/e2e02-after.txt"; echo "exit=$?"` を打つ
7. 最後まで待つ
8. [C-1]・[C-5]・[C-7]・[C-10] を取る

**落とし穴**: 10 秒の録音では窓が取れない。**コピーが 30 秒以上続く状態でなければこの試験は空振りする**（voicedock は v5.24 までここを取り違えていた）。

#### 期待
抜いた直後: `.<名前>.partial` が inbox から**消える**（[C-5] に `.partial` が無い）。`copy_failed reason=read_error`（または `changed`）が出る。クラッシュしない。
**デバイスの全ファイルのサイズと mtime が 1 バイトも変わらない**（6 の `diff` が空）。
再接続で**同じファイルを最初から再コピー**し、最後まで通る。
**inbox に取り残しが出ない**（パネルの「状態の詳細」の inbox が「処理待ち n 件」だけで「取り残し」が 0 件。voicedock #120）。

#### 記録
6 の `diff` の**全文**（空なら `（差分なし）` と書いてコマンドと終了コードを貼る）、[C-5] の前後、`copy_failed` の行（`grep copy_failed "$VD_HOME/logs/app.log"`）、[C-10] の inbox の 2 つの件数。

```text
```

#### 判定
⬜ 未実施

### 3.3 E2E-03 — 文字起こし中に抜く

#### 前提
削除 OFF。**数分の録音**を 1 本（10 秒では窓が取れない）。

#### 手順
【利用者が行う】

1. 挿す
2. [C-8] に `read-only` が出たら [C-7] を取る（前）
3. パネルが「文字起こし中」になったら抜く
4. 完走するまで待つ
5. [C-1]・[C-3]・[C-4]・[C-6] を取る
6. 挿し直し、[C-8] に `read-only` が出たら [C-7] を取る（後）

#### 期待
処理はコピー済みの inbox から続き、**削除 OFF なので最終状態は `COMPLETED`**（`SOURCE_DELETE_PENDING` にはならない）。
`source_delete_skipped reason=delete_source_audio_disabled` が 1 件出る。
[C-6] の `queue/delete` と `queue/result` に要求のファイルが無い（削除 OFF なので要求を書かない）。
元音声が残る（[C-7] の前後が一致）。

#### 記録

実施: 2026-09-24 夜。DEV=DJIMIC3。約 5.4 分の新しい録音（TX00_MIC009_20260924_213754_orig.wav。duration_s=325.49）を含む状態で挿し、文字起こし中に実機を抜いた（利用者が確認）。

[C-7]（前後の `diff`。抜く前の挿入時 → 完走後に挿し直して確認）:
```text
$ diff /tmp/e2e03-device-before.txt /tmp/e2e03-device-after.txt
（差分なし）
```
挿した直後の一覧は 8 本。抜いて文字起こし中断→再挿入の後でも、8 本すべてサイズ・mtime が変わっていない。

`part_discovered`〜`source_delete_skipped`（今回の 2 本。MIC008 は 81 秒で窓が短く、MIC009（5.4 分）で実際に抜いた）:
```text
2026-09-24T21:36:09+09:00 INFO  part_discovered recording_key=…TX00_MIC008_20260924_213248_orig.wav duration_s=81.29
2026-09-24T21:36:13+09:00 INFO  transcription_completed recording_key=…TX00_MIC008… elapsed_s=3.1 chars=381
2026-09-24T21:36:13+09:00 INFO  raw_note_saved session_key=DJIMIC3:20260924 parts=4 bytes=8197
2026-09-24T21:36:26+09:00 INFO  source_delete_skipped session_key=DJIMIC3:20260924 reason=delete_source_audio_disabled
2026-09-24T21:44:08+09:00 INFO  part_discovered recording_key=…TX00_MIC009_20260924_213754_orig.wav duration_s=325.49
2026-09-24T21:44:24+09:00 INFO  transcription_completed recording_key=…TX00_MIC009… elapsed_s=14.8 chars=1896
2026-09-24T21:44:24+09:00 INFO  raw_note_saved session_key=DJIMIC3:20260924 parts=5 bytes=14055
2026-09-24T21:44:42+09:00 INFO  source_delete_skipped session_key=DJIMIC3:20260924 reason=delete_source_audio_disabled
```

[C-4]（partkey・status・error_code。当該日の全件）:
```text
DJIMIC3/…/TX00_MIC005_20260924_205130_orig.wav|COMPLETED|
DJIMIC3/…/TX00_MIC006_20260924_211229_orig.wav|COMPLETED|
DJIMIC3/…/TX00_MIC007_20260924_212537_orig.wav|COMPLETED|
DJIMIC3/…/TX00_MIC008_20260924_213248_orig.wav|COMPLETED|
DJIMIC3/…/TX00_MIC009_20260924_213754_orig.wav|COMPLETED|
```
抜いた対象（MIC009）を含め、すべて `COMPLETED`・`error_code` なし。`SOURCE_DELETE_PENDING` にはならなかった。

[C-6]:
```text
$VD_HOME/queue/delete と queue/result はどちらも空（. と .. のみ）。要求のファイルは書かれていない。
```

#### 判定
✅ PASS

### 3.4 E2E-04 — Vault を利用不可にする

#### 前提
削除 OFF。1 分程度の録音を 1 本。**Obsidian を終了しておく**。

#### 手順
【利用者が行う】

1. [C-9] を `/tmp/e2e04-before.txt` に取る
2. `mv "$VAULT/.obsidian" "$VAULT/.obsidian.bak"`
3. 挿す
4. パネルの「要対応」を見る（[C-10]）
5. [C-2]・[C-9] を取る
6. `mv "$VAULT/.obsidian.bak" "$VAULT/.obsidian"`
7. **アプリを再起動せずに**待つ（最大 30 秒 ＋ 1 tick）
8. [C-1]・[C-9]・[C-10]

**落とし穴**: `.obsidian` を消さずに**改名**する（消すと Obsidian の設定が失われる）。
`$VAULT` を丸ごと `mv` しない（Vault のパスが変わると別の経路（`vaultNotConfigured`）に入って別の試験になる）。

#### 期待
4: 要対応に「Vault が使えません」が出て「Vault を選び直す」ボタンが在る。`pipeline_paused reason=vault_unavailable` が出る。
5: **Vault に何も書かれない**（[C-9] の前後が一致。**空のディレクトリを作っていない**。voicedock #134 はここが空振りしていた）。元音声が残る。
7: **再起動なしで** `pipeline_resumed reason=vault_unavailable` が出て、Raw / Daily が書かれる。

#### 記録

実施: 2026-09-24 夜。DEV=DJIMIC3。約 1 分の新しい録音 1 本。Obsidian は途中で起動したが、VoiceDock 自体は再起動していない。

1（前。[C-9]）:
```text
1168 1790088062 .../Raw/20260922/2026-09-22 raw.md
1775 1790089210 .../Wiki/20260922/2026-09-22 Voice.md
3133 1790252213 .../Wiki/20260924/2026-09-24 Voice.md
36252 1790172830 .../Raw/20260923/2026-09-23 raw.md
4673 1790250559 .../Wiki/20260923/2026-09-23 Voice.md
5922 1790252122 .../Raw/20260924/2026-09-24 raw.md
```

2:
```text
$ mv "$VAULT/.obsidian" "$VAULT/.obsidian.bak"
```

4（[C-10]。要対応）:
```text
状態: 停止中: Vault が使えません
要対応: Vault が使えません
  /Users/terada/VoiceDockTestVault に .obsidian/ がありません
  （Vault が未マウントか、別の場所を指しています）
  [Vault を選び直す]
はじめに: 3/4（「Vault を選ぶ」が未完了に戻った）
```

5（[C-9] の diff と、新しく作られたフォルダの確認）:
```text
$ diff /tmp/e2e04-before.txt /tmp/e2e04-during.txt
（差分なし）
$ find "$VAULT/Daily" -type d
（Vault 停止中に新しいフォルダは作られなかった。Daily/Voice/Wiki/Raw の既存 3 日分だけ）
```
`pipeline_paused reason=vault_unavailable` が 1 件出た。**Vault に何も書かれず、空のディレクトリも作られなかった**（voicedock #134 の空振りは再現しなかった）。

6〜7（`.obsidian` を戻して待つ。実施の途中で `$VAULT` が空になったまま `mv` を打ってしまい 1 回失敗したが、環境変数を再設定してやり直した。`.obsidian` のタイムスタンプは Sep 22 のままで、正しく元のフォルダに戻っている）:
```text
$ mv "$VAULT/.obsidian.bak" "$VAULT/.obsidian"
$ ls -la "$VAULT" | grep -i obsidian
drwxr-xr-x@ 2 terada staff 64 Sep 22 23:22 .obsidian
```

8（[C-1]・[C-9]・[C-10]）:
```text
recordings: COMPLETED|15 SKIPPED|1     （TRANSCRIBED で止まっていた 1 件が COMPLETED まで進んだ）
sessions:   COMPLETED|3                （既存の Session が再オープン→自動で再度 COMPLETED まで一巡）

2026-09-24T21:29:20+09:00 INFO  raw_note_saved session_key=DJIMIC3:20260924 parts=3 bytes=6905
2026-09-24T21:29:33+09:00 INFO  pipeline_resumed reason=vault_unavailable

Daily/Voice の一覧（更新後）:
6905 1790252960 .../Raw/20260924/2026-09-24 raw.md      （5922 → 6905。追いついた）
3204 1790252972 .../Wiki/20260924/2026-09-24 Voice.md   （3133 → 3204。ボタンを押さずに自動で更新）

パネル: 待機中。要対応なし。「はじめに」カードも消えた（4/4）。
```
再起動なしで `pipeline_resumed` が出て、Raw・Daily とも自動で書かれた（ログの順は `raw_note_saved` → `pipeline_resumed` だったが、両方とも再起動なしで観測された）。

#### 判定
✅ PASS

### 3.5 E2E-05 — 抜き挿しを 6 回以上

#### 前提
削除 OFF。**処理が全部終わった状態**（パネルが「待機中」）。新しい録音は足さない。

#### 手順
【利用者が行う】

1. [C-1] と `cat "$VD_HOME/logs/app.log.1" "$VD_HOME/logs/app.log" 2>/dev/null | grep -c -E 'part_discovered|copy_completed'` を取る（前。§1「ログの数え方」）
2. 挿す → [C-8] に `read-only` が出る → パネルの「状態」を見る → 「待機中」に戻ったら抜く、を **6 回**繰り返す（各回の [C-8] と、各回に見えた「状態」の文言を取る）
3. [C-1] と 1 と同じ `grep -c` を取る（後）

#### 期待
Part と Session の件数が**1 件も増えない**（[C-1] の前後が完全一致）。
各回に [C-8] に `read-only` が出る（アプリが毎回デバイスを見つけ、読み取り専用へ再マウントした）。
各回、走査のあいだだけ「状態」が一瞬「デバイスを調べています」になり、すぐ「待機中」に戻る（「取り込み中」にはならない）。
`part_discovered`・`copy_completed` の件数が前後で同じ。
`scan_completed devices=1 copied=0` と `file_not_stable` は DEBUG であり、既定（`logging.level` が `INFO`）の `app.log` には出ないので数えない（PLAN 付録 A.4）。

#### 記録

実施: 2026-09-24 夜。DEV=DJIMIC3。処理がすべて終わった「待機中」の状態から、新しい録音を足さずに抜き挿しを 6 回繰り返した。

[C-1]（前）:
```text
recordings: COMPLETED|14 SKIPPED|1
sessions:   COMPLETED|3
```

`part_discovered`/`copy_completed` の件数（前）: **30**

6 回の抜き挿し: 毎回 `read-only` を確認し、パネルは一瞬「デバイスを調べています」に変わってすぐ「待機中」に戻った。「取り込み中」になった回は無く、6 回とも異常なし（利用者の報告）。

[C-1]（後）:
```text
recordings: COMPLETED|14 SKIPPED|1
sessions:   COMPLETED|3
```

`part_discovered`/`copy_completed` の件数（後）: **30**（前後で完全一致。1 件も増えていない）

#### 判定
✅ PASS

### 3.6 E2E-06 — 1 日分を 1 セッションに

#### 前提
削除 OFF。**運用の中で確認してよい**（リリースはこれを待たない。PLAN 付録 B.3）。

#### 手順
【利用者が行う】

1. 1 日 10 時間分を DJI Mic 3 で録る（1 本 30 分で約 20 本）
2. 帰宅して挿す
3. 挿した時刻を記録する
4. パネルが「待機中」に戻った時刻を記録する
5. [C-1]・[C-3]・[C-9]・[C-10]

**目安**: 文字起こしの所要は**文字数で決まる**（voicedock の実測で 3.9〜4.6 字/秒。密な発話 10 時間で約 9.4 時間。16 時間で約 15 時間だった実測を比例で換算）。薄い発話なら大幅に短い。

#### 期待
**1 日分が 1 つの Session にまとまる**（`sessions` が 1 行、`part_count` が本数と一致）。Raw 1 枚・Daily 1 枚。
**次の接続（24 時間後）までに処理が終わる**（3 と 4 の差が 24 時間未満）。

#### 記録
3 と 4 の時刻と差、`sqlite3 "$VD_DB" "SELECT session_key, part_count, failed_part_count, recorded_seconds, status FROM sessions;"`、
`transcription_completed` の `rtf=` の一覧（`grep transcription_completed "$VD_HOME/logs/app.log" | grep -o 'rtf=[0-9.]*'`）。

```text
```

#### 判定
⬜ 未実施

### 3.7 E2E-07 — 無音の Part を混ぜる

#### 前提
削除 OFF。**無音だけの録音 1 本**（マイクを止めて 1 分録る）＋ 普通の録音 1 本。

#### 手順
【利用者が行う】

1. 2 本を録る
2. 挿す
3. 完走を待つ
4. [C-1]・[C-3]・[C-4]・Daily ノートの警告の節

#### 期待
止まらない。無音の Part は `SKIPPED`（`NO_SPEECH_DETECTED`）、もう 1 本は `COMPLETED`。Daily の警告行に**「無音」**と出る。
**`⚠` が付かない**（`⚠` は許可リストで判定する。voicedock #140 は SKIPPED に「再試行されます」と書いていた）。
**無音の元音声は残る**（根拠 B は既定 false）。

#### 記録
Daily ノートの警告の節を**行ごとそのまま**、[C-1]、`grep 'part_skipped\|transcription_completed' "$VD_HOME/logs/app.log"`。

```text
```

#### 判定
⬜ 未実施

### 3.8 E2E-08 — 1 本だけ文字起こしを失敗させる

#### 前提
削除 OFF。3 本程度（うち 1 本を壊す）。

#### 手順
【利用者が行う】

1. 挿す
2. `watch -n 1 'ls -la "$VD_HOME/staging"/*/'` 相当で `audio16k.wav` ができるのを見張る（`watch` が無ければ `while sleep 1; do …; done`）
3. **ある Part が NORMALIZED になった直後**に `printf 'broken' > "$VD_HOME/staging/<slug>/audio16k.wav"` で上書きする
4. 完走を待つ
5. [C-1]・[C-4]・Daily の警告の節
6. `rm "$VD_HOME/staging/<slug>/audio16k.wav"`
7. 抜いてから、**もう一度挿す**
8. [C-4] で、壊した Part が `FAILED`（`NORMALIZED_MISSING`）になったことを見る
9. **挿したまま待つ。**次の走査（`device.scanIntervalSeconds` の既定 300 秒ごと）でデバイスから再コピーされる。待てなければ、抜いてもう一度挿してもよい
10. 完走を待って [C-1]・[C-4]

**落とし穴**: **モデルのファイルを消して失敗させない**（起動時の前提の確認に引っかかって別の経路になる。voicedock #131）。
**壊すのは 16 kHz 音声だけ**。FAILED になった Part の 16 kHz 音声を**勝手に消さない**のが正しい動き（voicedock #133 の逆）。
inbox の原本は触らない（`audio.inboxRetain` の既定 `normalized` では、変換が済んだ時点でアプリが消している）。

#### 期待
5: その Part が `FAILED`（`WHISPER_FAILED`。工程内リトライで 3 回試したあと）、他の Part は進み、Daily に警告行が出る。
**`error_message` がヘルプ全文になっていない**（voicedock #135。`sqlite3 "$VD_DB" "SELECT length(error_message) FROM recordings WHERE status='FAILED';"` が数百文字以内）。
8: 接続の立ち上がりで再評価され（`FAILED→TRANSCRIBING`、detail `requeue`。`recovery_completed requeued=1`）、16 kHz 音声も inbox の原本も無いので `TRANSCRIBING→NORMALIZING→FAILED`（`NORMALIZED_MISSING`）になる。
`normalize_failed` が `reason=input` で出る。この接続の走査は再評価より先に済んでいるので、ここではまだ再コピーされない。
9〜10: 次の走査で**再コピー**され（`copy_completed … recopy=true`）、再コピーの完了を契機に `FAILED→NORMALIZING`（detail `recopied`）、`recovery_completed requeued=1`。
変換し直して（`normalize_completed` が 2 回目）完走し `COMPLETED`。

#### 記録
5 と 10 の [C-1]・[C-4]、8 の [C-4]、`error_message` の全文と長さ、
`grep -E 'normalize_completed|normalize_failed|copy_completed|recovery_completed' "$VD_HOME/logs/app.log"`（`normalize_completed` が当該 Part で 2 回出ていること）。

```text
```

#### 判定
⬜ 未実施

### 3.9 E2E-09 — 保存後に同じ日の Part を追加

#### 前提
削除 OFF。E2E-01 が済んでいる（同じ日の Daily ノートが保存済み）。

#### 手順
【利用者が行う】

1. [C-9] を取る（前。ファイル数を数える）
2. 抜いて、**同じ日に**もう 1 本録る
3. 挿す
4. 完走を待つ
5. [C-9]（後）・[C-3]・[C-4]
6. 2〜5 を**あと 3 回**繰り返す（計 4 回の再オープン）

#### 期待
Daily ノートは**同じ 1 ファイル**が作り直される（[C-9] のファイル数が増えない。` (2)` が生えない）。
`session_reopened` が毎回出て、`llm_completed` も毎回出る（**再オープンで解析をやり直す**。voicedock #108 はやり直していなかった）。Raw ノートも同じ 1 ファイル。

#### 記録
[C-9] の前後（4 回分のファイル数）、`cat "$VD_HOME/logs/app.log.1" "$VD_HOME/logs/app.log" 2>/dev/null | grep -c session_reopened`、同じく `grep -c llm_completed`（1 回目の前と 4 回目の後。§1「ログの数え方」）。

```text
```

#### 判定
⬜ 未実施

### 3.10 E2E-10 — 削除 ON で通し

#### 前提
削除 ON。**この節から実機の録音が本当に消える。**消えてよいのは「この試験のために新しく録った録音」と「すでに Raw ノートで確認済みの録音」だけである。

**止め方（削除 ON の試験すべてに共通。§5・§6 も同じ）**: 想定外のファイルが消えたら、次の順で止める。

1. 直ちにパネルの「元音声の削除」の「無効にする」を押す
2. Finder でデバイスを取り出す
3. その時点の [C-7]・[C-6]・[C-12] を取る（[C-7] はデバイスが要る。無効化の後なので、挿し直すと読み取り専用でマウントされる）
4. 判定を `✗ FAIL` にし、修正チケットを起票する（§0）


- **`make app` か `make release` の `.app` を使う。**`ReaperSignature.requirement`（PLAN §8.9.3）は識別子と Team ID（`certificate leaf[subject.OU]`）で束縛しているので、
  Apple Development の証明書でも Developer ID の証明書でも満たす。**ad-hoc 署名の `.app` では `.disabled(reaper_invalid)` になり、この Phase の試験が全部空振りする**。
  確かめ方（読み取りだけ）: `codesign -dvvv "<VoiceDock.app のパス>/Contents/Helpers/voicedock-reaper" 2>&1 | grep -E 'Identifier=|TeamIdentifier='`。
  `Identifier=` が `identity.env` の `BUNDLE_ID` に `.reaper` を付けたもの、`TeamIdentifier=` が `identity.env` の `TEAM_ID` であること（`not set` なら ad-hoc なので始めない）
- 削除 OFF の 13 件（E2E-01〜09・12〜14・16）が PASS 済み。パネルの「詳細・診断 → 診断を実行」に ✗ が無い
- 削除はまだ OFF。[C-11] が `ロック 1  : アプリ=無効, reaper.conf=無し`（前に無効化していれば `reaper.conf=無効`）と `ロック 2-A: 削除モジュール=未導入` を示している
- デバイスに**未処理の録音が無い**（E2E-01〜09 で処理済み。パネルが「待機中」）
- **消えてよいファイルの範囲を利用者が決めて書き留める。**
- **退避は必須**（手順 1。削除 OFF で読み取り専用の間に行う）。退避先の `$BACKUP/device-backup` は空か、まだ無いこと
- **削除の段で止まっている Session と Part が無い**（手順 1 で確かめる。残っていると、有効にした直後にその Part の元音声が消えうる）
- 1 分程度の**普通の録音 2 本**と**無音の録音 1 本**（マイクを止めて 1 分）を、有効化の後に新しく録る（手順の 4）

#### 手順
【利用者が行う】

1. デバイスを挿し、[C-8] に `read-only` が出たら [C-7]・[C-15]・[C-11]・[C-16]・[C-1] を取る（前。削除 OFF なので読み取り専用で挿さっている）。続けて、読み取り専用のうちに次を行う:
   - 全ファイルの一覧: `find "/Volumes/$DEV" -type f -exec stat -f '%z %m %N' {} \; | sort | tee "$BACKUP/device-all-before-on.txt"`
   - **退避（必須）**: `ditto "/Volumes/$DEV" "$BACKUP/device-backup"`
   - 件数の照合: `find "/Volumes/$DEV" -type f | wc -l` と `find "$BACKUP/device-backup" -type f | wc -l` が同じ数であること（違えば始めない）
   - 削除の段で止まっている Session: `sqlite3 "$VD_DB" "SELECT status, COUNT(*) FROM sessions WHERE status IN ('SAVED','SOURCE_DELETING','SOURCE_DELETE_PENDING','CLEANUP') GROUP BY status;"` が **0 行**
   - `RAW_SAVED` の Part: `sqlite3 "$VD_DB" "SELECT COUNT(*) FROM recordings WHERE status = 'RAW_SAVED';"` が **0**
   - どちらかが 0 でなければ有効化しない（処理が終わるのを待つ。終わらなければ調べる）
2. パネルの「› 元音声の削除」の行を押して、削除の画面で有効化する。まず事前確認の 2 文と、その下の診断の要約（または「診断を実行」のボタン）を書き写す。
   次に赤い「有効にする」を **1 回だけクリック**し、続けて **1 秒ほど押してから離す**。どちらでも何も変わらないこと（[C-16] に `voicedock-reaper` が無いまま）を確かめる。最後に赤い「有効にする」を **3 秒押し続ける**（リングが満ちたら離す）
3. 直ちに [C-11]・[C-16]・[C-14] を取る。3 行の下の注意書きと、メニューバーのアイコンの横のゴミ箱（`trash`）を確かめる
4. Finder でデバイスを**取り出してから抜き**、普通の録音 2 本と無音の録音 1 本を新しく録る
5. 挿す（**有効化してから初めての接続**）。[C-8] を取り、マウントが出たら直ちに [C-7] と [C-15] を取る（前。`read-only` は出ない。最初の削除は Raw ノートの保存の後なので、挿した直後の一覧がそのまま「前」になる）
6. 完走を待つ（パネルが「待機中」に戻る）。**[C-1] を取る前に 1〜2 分待つ**（削除の評価のバックオフ 60 秒。元音声が消えた後、Session が `COMPLETED` になるのは次の評価）
7. [C-1]・[C-13]・[C-14]・[C-12]・[C-6]・[C-7]・[C-15]・[C-9]・[C-11] を取る（後）。無音の Part の行も取る:
   `sqlite3 -header -column "$VD_DB" "SELECT partkey, status, error_code, delete_request_id, source_deleted_at FROM recordings WHERE status='SKIPPED';"`
8. 5 と 7 の [C-7] を `diff` し、消えたファイルが**普通の録音 2 本だけ**であることを確かめる
9. **何も消えないことの確認**（ND-40 / RV-00 の実機での裏取り）。**Finder でデバイスを取り出してから抜き**、[C-6] で `queue/delete` が空であることを確かめ、下の 3 つを順に手で実行する。
   各回の前後で `wc -c "$VD_HOME/logs/reaper.log"` と [C-6] を取る

| # | 手で実行するもの【利用者が行う】 | 期待 |
|---|---|---|
| 10-a | `"<VoiceDock.app のパス>/Contents/Helpers/voicedock-reaper" --home "$VD_HOME"; echo "exit=$?"` | `exit=3`。標準出力にも標準エラーにも何も出ず、`reaper.log` の大きさが変わらず、`queue/delete` も変わらない（RV-00。バンドルの中から起動しても何もしない） |
| 10-b | `"$VD_HOME/bin/voicedock-reaper" --version; echo "exit=$?"` | リポジトリの `VERSION` と同じ 1 行と `exit=0`。`reaper.log` の大きさが変わらない（`--version` は RV-00 より前に処理して終わり、要求を読まない） |
| 10-c | `"$VD_HOME/bin/voicedock-reaper" --home "$VD_HOME"; echo "exit=$?"`（`queue/delete` が空で、デバイスを取り出して抜いてあるときに限る） | `exit=0`。何も消えない。`reaper.log` に `reaper_started` と `reaper_completed requests=0` の 2 行が足される。`exit=4` なら `reaper_busy`（アプリの走査と重なった）なので少し待ってもう一度。**要求がある状態・デバイスが挿さった状態では手で叩かない** |

**落とし穴**: 有効化の直後、挿し直す前のデバイスは観測が `読み取り専用` なので削除されない（その時点で削除の段に来た Session は `source_delete_skipped session_key=… reason=device_readonly` で削除せずに完了する）。
これは正しい動き。消し損ねた分は E2E-11 の「過去分を削除対象にする」で拾う。
10-c は要求が無いので reaper はデバイスを開かない。voicedock で見えた TCC の差（ターミナルから直に叩くと `Operation not permitted`）は**この確認では現れない**。見えたことだけを書く。
デバイスが読み書き可能でマウントされている間は、macOS がデバイスに `.fseventsd` などを作ることがある（PLAN RK-22）。[C-7] は `.wav` だけを見るので差分に出ない。

#### 期待
2: 事前確認の 2 文が「1 日以上の運用で Raw ノートが正しく作られていることを確かめましたか」と「消した録音は戻りません」。
クリック 1 回と、途中で離した長押しでは何も変わらない（リングは離すと 0 に戻り、[C-16] に `voicedock-reaper` が無いまま）。3 秒押し続けると通る。

3: [C-11] が次の 3 行と注意書き（`<VERSION>` は `VERSION` の中身、`<デバイス>` はデバイスの ID）:

```text
ロック 1  : アプリ=有効, reaper.conf=有効
ロック 2-A: 削除モジュール=導入済み（署名 OK, 版 <VERSION>）
ロック 2-B: 設定=rw, <デバイス>=読み取り専用（観測）
読み書きできるようになるのはデバイスを挿し直した後です
```

[C-16] に `voicedock-reaper` と、`DELETE_SOURCE_AUDIO=true` の行を含む `reaper.conf` がある。[C-14] に `deletion_enabled` が 1 行出る（`reason=` は付かない）。

5: [C-8] の行に `read-only` が**無い**（`device.mountMode` が `rw` なので、アプリは読み取り専用へ再マウントしない）。[C-11] の 3 行目が `<デバイス>=読み書き可能（観測）` になる。

7:
- **Raw ノートの検証を通った Part の元音声だけが消える**（8 の `diff` が普通の録音 2 本の行だけ）
- **無音の Part は消えない**。`SKIPPED`・`NO_SPEECH_DETECTED` のまま、`delete_request_id` も `source_deleted_at` も空（根拠 B は既定 false なので要求を書かず、ログも出さない）
- [C-14] に、消えた Part ごとに `delete_requested request_id=… recording_key=… session_key=…` → `reaper_run exit=0` → `source_deleted recording_key=… request_id=…` の順に出る。無音の Part の `recording_key` を持つ `delete_requested` は無い。`reaper_failed` が無い
- [C-12] に `reaper_started`・`source_deleted request_id=… partkey=…`（消えた本数ぶん）・`reaper_completed requests=<n>` が出る。`source_delete_rejected` と `request_rejected` が無い
- [C-6] の `queue/delete`・`queue/result`・`queue/rejected` が**空**に戻っている
- [C-13] の消えた Part の行が `COMPLETED`、`delete_request_id` が空、`source_deleted_at` に時刻。[C-1] の Session が `COMPLETED`
- [C-15] の空き容量が 5 より増えている（消えた 2 本ぶん）
- Daily / Raw ノートは削除 OFF のときと同じ形（[C-9]）

9: 表の期待のとおり。

#### 記録
1 の件数の照合（2 つの `wc -l`）と削除の段の 2 つのクエリの出力、2 の事前確認の 2 文・診断の要約・`enable` を弾いた表示、3 と 7 の [C-11]、[C-16] の前後、5 と 7 の [C-7] の `diff`（**消えたファイルだけが差分**）、[C-15] の前後、[C-13]、[C-14]、[C-12]、[C-6]、無音の Part の行、9 の 3 つの出力（終了コードと `wc -c` の前後）。

```text
```

#### 判定
⬜ 未実施

### 3.11 E2E-11 — 過去分の削除・手動で消した分の完了

#### 前提
削除 ON。E2E-10 が PASS（削除が有効で、デバイスを挿すと読み書き可能でマウントされる）。
**削除 OFF の期間に処理した Part が残っている**（E2E-01〜09 などで処理したもの）。E2E-10 の手順 1 の退避が済んでいる。

- **この試験では以前の録音も消える。**「過去分を削除対象にする」は、条件を満たす過去の Part を 1 件ずつ選ばずに全部消す。§1 の下準備の接続で取り込んだ以前の録音も、Raw ノートの検証を通っていれば対象になる。
  消えてよい範囲に収まらないなら、この試験を行わない（手順 2 のプレビューで「やめる」を押す）
- 対象になりうる Part の一覧（読み取りだけ。実際の対象はこの一覧のうち Raw ノートの検証を通り、デバイスに今在るもの）:
  `sqlite3 -header -column "$VD_DB" "SELECT r.partkey, r.source_path FROM recordings r JOIN sessions s ON r.session_key = s.session_key WHERE s.status = 'COMPLETED' AND r.status IN ('COMPLETED', 'SOURCE_DELETE_PENDING') AND r.source_deleted_at IS NULL AND r.delete_request_id IS NULL ORDER BY r.started_at;"`
- **実機で確かめるのは前半（過去分）だけ**である（PLAN 付録 B.3・F-63）。後半の「手動で消した分を完了にする」は、対象の `SOURCE_DELETE_PENDING` を手の操作で確実に作れないので、
  T-41 の単体テスト（`Tests/VDPipelineTests/BacklogPlannerTests.swift` の resolveAbsent 系）で代える。運用中に `SOURCE_DELETE_PENDING` が出たら、`#### 記録` の末尾に記録する

#### 手順
【利用者が行う】

1. デバイスを挿し、[C-8] にマウントが出て、パネルが「待機中」に戻ったら [C-1]・[C-7]・[C-13] と、前提の「対象になりうる Part の一覧」を取る（前）
2. パネルの「詳細・診断 → 過去分を削除対象にする」を押す。**プレビュー（件数と、対象外の件数と理由）を書き写す**。対象が消えてよい範囲を超えていたら「やめる」を押して終える
3. 「削除要求を書く（<n> 件）」を押して実行する。出た 1 行を書き写す
4. パネルが「待機中」に戻るのを待ち、1〜2 分おいてから [C-1]・[C-7]・[C-13]・[C-14]・[C-12]・[C-6] を取る（後）
5. `SOURCE_DELETE_PENDING` の Part を調べて記録する: `sqlite3 -header -column "$VD_DB" "SELECT partkey, source_path, error_code FROM recordings WHERE status = 'SOURCE_DELETE_PENDING';"`（0 行でよい）

**落とし穴**: 2 のプレビューが 0 件なら**この試験は空振り**（TEST-20）。0 件なら削除 OFF で処理した Part を先に用意する（削除を無効にして 1 本処理し、有効に戻す）。
**録音を手で消さない。**消したファイルはこの試験の対象にならない（`COMPLETED` の Part は `source_deleted_at` が空のまま残り、`RAW_SAVED` の Part は要求が書かれずに Session が削除の段で待ち続ける）。
`RAW_SAVED` で詰まったら、「無効にする」を押し、Session が `COMPLETED` になるのを [C-1] で確かめてから（削除の評価のバックオフにより最大 1 時間ほど）、E2E-10 の手順 2 の 3 秒の長押しで有効に戻す。
無効にしている間の Session は `source_delete_skipped session_key=… reason=delete_source_audio_disabled` で削除せずに完了する。

#### 期待
2: 1 行目が `削除要求を書く対象: <n> 件`（**n ≥ 1**。本アプリは削除 OFF の間も Raw ノートを保存・検証するので、voicedock の「`--backlog` は 0 件」と違って 0 件にならない）。
対象外があれば `対象外: <m> 件` と、理由ごとの `・削除済み: <k> 件`（E2E-10 で消した 2 本を含む）・`・削除の条件を満たさない: <k> 件` が出る。
3: `<n> 件の削除要求を書きました`。
4: 対象の元音声だけが消える（[C-7] の前後の差が対象の本数と一致し、どれも前提の一覧に在る）。[C-13] の対象の行が `COMPLETED`・`delete_request_id` が空・`source_deleted_at` に時刻。
[C-14] に `delete_requested` が n 行、`reaper_run exit=0`、`source_deleted` が n 行。[C-12] に `source_delete_rejected` が無い。[C-6] の `queue/delete`・`queue/result` が空。
5: 行があれば、その Part ごとに [C-14] の `source_delete_pending recording_key=… reason=…` が 1 行以上ある。

後半（手動で消した分）は T-41 の単体テストの期待による: `SOURCE_DELETE_PENDING` → `SOURCE_DELETING`（detail `resolve_absent`）→ `COMPLETED`（detail `already_absent`）、
`source_delete_skipped recording_key=… reason=already_absent`、**`source_deleted_at` は入らない**。

#### 記録
2 のプレビューの全文、3 の実行の 1 行、前提の「対象になりうる Part の一覧」、[C-1]・[C-7]・[C-13] の前後、[C-14]、[C-12]、[C-6]、5 の出力。

```text
```

**運用中の `SOURCE_DELETE_PENDING`（F-63）**: [C-14] に `source_delete_pending` が出たら、その行（`reason=` は RV の理由語・`no_result`・`still_in_inventory`・`queue_write_failed` のどれか。
`queue_write_failed` は要求ファイルを書けなかったもので、状態は `SOURCE_DELETE_PENDING` にならない）と、5 のクエリの出力と、[C-4] の当該 Part の遷移を日時つきでここに貼る。
デバイスにファイルが無いことを確かめられたら、「詳細・診断 → 手動で消した分を完了にする」のプレビューと実行の 1 行も貼る。**そのために録音を手で消さない。**

#### 判定
⬜ 未実施

### 3.12 E2E-12 — 文字起こし中に強制終了

#### 前提
削除 OFF。数分の録音を 3 本。

#### 手順
【利用者が行う】

1. 挿す
2. パネルが「文字起こし中」になったら [C-1]（前）を取る
3. `kill -9 $(pgrep -x VoiceDock)`
4. `pgrep -x whisper-cli` で**孫が残っていないこと**を見る（残っていれば記録する）
5. アプリを起動する（`open dist/VoiceDock.app`）
6. 完走を待って [C-1]（後）・[C-3]・[C-4]

#### 期待
起動時の復旧で途中の状態が巻き戻り、**途中から再開**する。
**二重処理しない**（[C-1] の Part の合計が前後で同じ、`part_discovered` が本数ぶんだけ）。`grep 'recovery_completed rolled_back' "$VD_HOME/logs/app.log"` が 1 行（`rolled_back=<n>`）。

#### 記録
[C-1] の前後、4 の出力、`grep 'recovery_completed rolled_back' "$VD_HOME/logs/app.log"` の出力、[C-4] の巻き戻しの遷移。

```text
```

#### 判定
⬜ 未実施

### 3.13 E2E-13 — 処理中にスリープ

#### 前提
削除 OFF。数分の録音を 2 本以上（処理が数分続く状態）。

#### 手順
【利用者が行う】

1. 挿す
2. 処理中に `pmset -g assertions | grep -A3 'Listed by owning process'` を取る
3. **アップルメニュー → スリープ**（電源ボタンではなく、明示的なスリープ）
4. 数分後にふたを開けて復帰
5. 完走を待って [C-1]・[C-3]・[C-2]

#### 期待
2: `VoiceDock` が `PreventUserIdleSystemSleep` を保持している（処理中だけ）。
3: 明示的なスリープは掛かる（`beginActivity` はアイドルスリープだけを止める）。
4: 復帰後に処理が続き、完走する。Part が `FAILED` にならない。アイドル時には 2 のアサーションが**消えている**。

#### 記録
2 と（待機中に戻ったあとの）`pmset -g assertions` の 2 回分、[C-3]、スリープと復帰の時刻。

```text
```

#### 判定
⬜ 未実施

### 3.14 E2E-14 — アプリが動いていない間に接続

#### 前提
削除 OFF。1 分程度の録音 1 本。**アプリを終了しておく**（パネルの「VoiceDock を終了」）。

#### 手順
【利用者が行う】

1. アプリを終了する（`pgrep -x VoiceDock` が空）
2. 挿す
3. 1 分待つ
4. アプリを起動する（`open dist/VoiceDock.app`）
5. 完走を待って [C-1]・[C-3]・[C-9]

#### 期待
3 の間は何も起きない。4 の起動後の最初の走査で取り込まれ、最後まで通る（`service_started` → `scan_completed copied=1`）。

#### 記録

実施: 2026-09-24 夜。DEV=DJIMIC3。約 1 分の新しい録音 1 本。

[C-1]（前）:
```text
recordings: COMPLETED|15 SKIPPED|1
sessions:   COMPLETED|3
```

手順: `pgrep -x VoiceDock` が空であることを確認 → 録音を作り挿す → 1 分待つ（アプリは起動しないまま）→ `open dist/VoiceDock.app`。

`service_started` と `scan_completed`:
```text
2026-09-24T21:36:07+09:00 INFO  service_started version=0.1.0 schema=v1_initial
2026-09-24T21:36:09+09:00 INFO  scan_completed devices=1 copied=1 elapsed_s=2.1
```
起動の 2 秒後の最初の走査で取り込まれた。

[C-1]（後）:
```text
recordings: COMPLETED|16 SKIPPED|1
sessions:   COMPLETED|3
```

#### 判定
✅ PASS

### 3.15 E2E-15 — 取り下げ

#### 前提
取り下げ（2026-09-22、利用者の決定。PLAN F-61）。**行わない。**

#### 手順
行わない（【利用者が行う】手順は無い）。

#### 期待
PLAN 付録 B.3 の E2E-15 の行（取り下げ）。

#### 記録
（取り下げ）

#### 判定
— 対象外

### 3.16 E2E-16 — リムーバブルボリュームの許可を拒否

#### 前提
削除 OFF。**この試験で TCC の許可が 1 回失われる**（最後に許可し直す）。

#### 手順
【利用者が行う】

1. `tccutil reset SystemPolicyRemovableVolumes <BUNDLE_ID>`
2. アプリを再起動する
3. 挿す
4. 出たダイアログで**「許可しない」**を押す
5. [C-2]・[C-10]・診断の DR-11
6. `tccutil reset SystemPolicyRemovableVolumes <BUNDLE_ID>`
7. アプリを再起動して挿し、**「許可」**を押す
8. 完走を待って [C-1]・[C-3]

**落とし穴**: `tccutil reset` の後は**アプリを再起動しないとダイアログが出ない**。
`<BUNDLE_ID>` は `identity.env` の `BUNDLE_ID` の値（いまは `io.github.shinsuke-terada.VoiceDock`）。

#### 期待
4: 取り込まない。`volume_skipped reason=not_listable`（WARNING）。要対応に「<デバイス名> の中身を読めません」と「システム設定を開く」ボタンが出る。
5: DR-11 が ✗ で、案内の文言が「システム設定 → プライバシーとセキュリティ → ファイルとフォルダ → VoiceDock → リムーバブルボリューム」。
7: 許可すると普通に取り込む。

#### 記録
4 のダイアログの文言（`NSRemovableVolumesUsageDescription` の逐語「録音デバイスから音声を読み込むために使います」が出ること。`Resources/Info.plist.template`）、
[C-10] の要対応、DR-11 の行、8 の [C-1]。

```text
```

#### 判定
⬜ 未実施

### 3.17 E2E-17 — 削除を無効化

#### 前提
削除 ON→OFF。E2E-10 が PASS（削除が有効）。数分の録音を 1 本新しく録っておく（無効化の後に処理が進む状態を作る）。

#### 手順
【利用者が行う】

1. デバイスを挿し、[C-8] にマウントが出たら [C-7] を取る（前）
2. パネルの「状態」が「文字起こし中」になったら（コピーが済んでいる）、[C-11]・[C-16]・[C-8]・[C-1] を取る
3. パネルの「元音声の削除」の「無効にする」を**1 回だけ**押す
4. **直ちに** [C-8]・[C-11]・[C-16]・[C-6]・[C-14] を取る
5. 処理が終わってパネルが「待機中」に戻るまで待つ
6. [C-1]・[C-7]・[C-13]・[C-14] を取る

**落とし穴**: 無効化は「消す能力に近いものから先に止める」順（reaper.conf → reaper の削除 → config → 要求の取り下げ → 再マウント）で、**途中の段が失敗しても残りを続ける**。4 では **5 つとも**を確かめる。
コピーの途中で押すと走査が見送られ、再マウントの段が失敗しうる（`remount`）。2 のとおり「文字起こし中」になってから押す。
§5・§6 に進むなら、この試験の後に E2E-10 の手順 2（3 秒の長押し）で有効に戻し、Finder でデバイスを取り出して挿し直す。

#### 期待
3: 確認のダイアログも長押しも求められない（1 回のクリックで止まる。**止めたいときに止められる**）。
4:
- **接続中のデバイスが直ちに読み取り専用へ再マウントされる**（[C-8] の行に `read-only` が出る。挿し直しを待たない）
- [C-11] が次の 3 行（`<デバイス>` はデバイスの ID）。メニューバーのゴミ箱が消え、「元音声の削除」の画面には事前確認の 2 文と赤い「有効にする」（長押し）が戻る:

```text
ロック 1  : アプリ=無効, reaper.conf=無効
ロック 2-A: 削除モジュール=未導入
ロック 2-B: 設定=ro, <デバイス>=読み取り専用（観測）
```

- [C-16] に `voicedock-reaper` が**無い**。`reaper.conf` が `DELETE_SOURCE_AUDIO=false` の行を含む
- [C-6] の `queue/delete` が**空**（要求が取り下げられた）
- [C-14] に `deletion_disabled` が INFO で出る（`reason=` は付かない）。段が失敗したときは WARNING の `deletion_disabled reason=<段の名前,…>` になり、パネルに `無効にできなかった段: …` が出る
  （段の名前は `reaper_conf`・`remove_reaper`・`config`・`withdraw_requests`・`remount`）。これが出たら FAIL

6: **以後 1 本も消えない**（[C-7] が 1 と一致）。[C-14] に `source_delete_skipped session_key=… reason=delete_source_audio_disabled` が出る。
処理自体は最後まで進み、Part と Session が `COMPLETED` になる。今回の Part は [C-13] に出ない（`source_deleted_at` も `delete_request_id` も空）。

#### 記録
3（クリックだけで止まったこと）、2 と 4 の [C-8]・[C-11]・[C-16]、4 の [C-6] と [C-14]、1 と 6 の [C-7]、6 の [C-1]・[C-13]・[C-14]。

```text
```

#### 判定
⬜ 未実施

### 3.18 E2E-18 — 取り下げ

#### 前提
取り下げ（2026-09-22、利用者の決定。PLAN F-60）。**行わない。**

#### 手順
行わない（【利用者が行う】手順は無い）。

#### 期待
PLAN 付録 B.3 の E2E-18 の行（取り下げ）。

#### 記録
（取り下げ）

#### 判定
— 対象外

## 4. 削除のゲート（PLAN §12.4）

**v1.0 を出す前にすべてを満たす。緩めない。**G-1〜G-5 は PLAN §12.4 の 1〜5 と同じ順・同じ意味である。

| # | 条件 | 判定 | 記録 |
|---|---|---|---|
| G-1 | 付録 B.1 の ND が全件 PASS（アプリ層・reaper 層とも。正の対照を含む） | ⬜ 未実施 | §4.1 |
| G-2 | 付録 B.3 の E2E が全件 PASS（E2E-06 は運用の中で確認してよいが、確認が済むまでゲートは開かない） | ⬜ 未実施 | §2 |
| G-3 | `.diskImage` のテストが CI か手元で PASS し、その記録が PR にある | ⬜ 未実施 | §4.3 |
| G-4 | 実機で「三重ロックを全部外して 1 日流す」を行った | ⬜ 未実施 | §5 |
| G-5 | 削除 ON で E2E-01〜09 を再実行した（本書 §6） | ⬜ 未実施 | §6 |

**ゲート: 閉**

- 最後の 1 行は `**ゲート: 開**` か `**ゲート: 閉**` のどちらかである。散文にしない
- **`開` と書けるのは、判定表（§2）の 18 件と上の G と §6 の R がすべて `✅` か `—` のときだけ**である。`開` と書いたまま 1 件でも `⬜` か `✗` が残っていれば `Tests/PolicyTests/RunbookGateTests.swift` が落ちる
- G-1 と G-3 は、手元で走らせたコマンドの**全出力**を下の節に貼ってから `✅` にする。「全部緑」とだけ書かない

### 4.1 G-1 の記録

【利用者が行う】リポジトリのルートで `make test-nd` を実行し、全出力を貼る。
reaper 層のうち R3（ディスクイメージ）の ND は `.diskImage` のテストなので `make test-nd` では走らない。§4.3 の `make test-disk` の出力と合わせて、両方が緑のときに G-1 を `✅` にする。

```text
```

### 4.3 G-3 の記録

【利用者が行う】**実機を物理的に抜いてから**、リポジトリのルートで `make test-disk` を実行し、全出力を貼る（ディスクイメージは `/Volumes` の外に attach される）。同じ出力を PR の本文にも貼る。

```text
```

## 5. 三重ロックを全部外して 1 日（G-4 の記録）

削除を有効にしたまま、**普段どおりの 1 日**を流す。voicedock ではこれでしか見つからない欠陥が 5 件あった（単体テストは全部緑のままだった）。
想定外のファイルが消えたら §3.10 の「止め方」で止める。削除 ON の間はデバイスが読み書き可能でマウントされるので、**抜く前に Finder で取り出す**。

#### 前提
E2E-10・11・17 と §6 の再実行が PASS。削除を**有効に戻した**状態（E2E-17 で無効化したままにしない。E2E-10 の手順 2 の 3 秒の長押しで有効にする）。
デバイスを挿したときの [C-11] が 3 つとも外れていることを示す:
`ロック 1  : アプリ=有効, reaper.conf=有効`・`ロック 2-A: 削除モジュール=導入済み（署名 OK, 版 <VERSION>）`・`ロック 2-B: 設定=rw, <デバイス>=読み書き可能（観測）`。

#### 手順
【利用者が行う】

1. 開始時刻と [C-1]・[C-7]・[C-15]・[C-9]・[C-16] を取る
2. **普段どおり 1 日録って、帰宅して挿す**（試験用の操作を足さない。抜き挿し・スリープ・アプリの再起動が自然に起きるままにする）
3. 開始から 24 時間後に、終了時刻と [C-1]・[C-7]・[C-15]・[C-9]・[C-13]・[C-14]・[C-12]・[C-6]・[C-10]・[C-11] を取る
4. **Daily / Raw ノートを目視で読む**（内容が壊れていないか。警告行の理由が妥当か）
5. `cat "$VD_HOME/logs/app.log.1" "$VD_HOME/logs/app.log" 2>/dev/null | grep -c ERROR` と、同じく `grep WARNING` の行を全部取る（§1「ログの数え方」）。
   reaper のログの拒否と見送りも取る: `grep -E 'source_delete_rejected|request_rejected|device_absent|mount_readonly|reaper_busy|reaper_disabled' "$VD_HOME/logs/reaper.log"`

**1 日は「24 時間」**（10 時間の録音 ＋ 処理の時間）。短縮しない。
途中で FAIL の兆候が出たら、**その時点で削除を無効化して**（E2E-17 の手順 3）調べる。記録には中断したことと時刻を書く。

#### 期待
Raw が 1 枚・Daily が 1 枚（その日の分）。`FAILED` が 0 件（あれば理由が妥当で、次の接続で再試行される）。
**Raw ノートの検証を通った録音だけが消え、空き容量が戻る**（[C-7] の前後の差が、Raw ノートに載った Part のファイルと一致。[C-15] が増える）。
[C-6] の `queue/delete`・`queue/result` が空に戻っている。[C-14] に `reaper_failed` が無い（あれば `reason=` を 1 件ずつ説明する）。
`reaper.log` に `source_delete_rejected` と `request_rejected` が出ていない（出ていたら `reason=` の語を PLAN 付録 B.2 で引いて調べる）。
`ERROR` の行が 0（あれば 1 件ずつ説明を書く）。

#### 記録
1 と 3 の全部、4 の目視の所見（**何を見て問題ないと判断したか**を文で）、5 の全出力、その日に起きた異常（あれば）。

```text
```

#### 判定
⬜ 未実施

## 6. 削除 ON での E2E-01〜09 の再実行

削除 OFF で PASS した 9 件を、削除が有効なまま通す。**§3 の手順をそのまま使い、下の「削除 ON での違い」だけを足して見る。**

**止め方（削除 ON の試験すべてに共通。§5・§6 も同じ）**: 想定外のファイルが消えたら、次の順で止める。

1. 直ちにパネルの「元音声の削除」の「無効にする」を押す
2. Finder でデバイスを取り出す
3. その時点の [C-7]・[C-6]・[C-12] を取る（[C-7] はデバイスが要る。無効化の後なので、挿し直すと読み取り専用でマウントされる）
4. 判定を `✗ FAIL` にし、修正チケットを起票する（§0）

- E2E-17 の後なら、E2E-10 の手順 2 の 3 秒の長押しで有効に戻し、Finder でデバイスを取り出して挿し直してから始める
- 削除 ON の間はデバイスが読み書き可能でマウントされる。**抜く前に Finder で取り出す**（§3 の手順の「抜く」は「Finder で取り出してから抜く」と読み替える）。急に抜くこと自体が試験である R-02・R-03 だけは例外で、それぞれの節の安全の手順に従う
- 削除 ON では `device.mountMode` が `rw` なので、[C-8] に `read-only` は出ない。§3 の手順の「[C-8] に `read-only` が出たら」は「[C-8] にマウントが出たら」と読み替える
- §3 の期待のうち「元音声が残る」「`source_delete_skipped reason=delete_source_audio_disabled`」は削除 OFF のものである。削除 ON では下の表の期待に置き換わる
- 消えてよいのは各シナリオのために新しく録った録音だけである。前後の [C-7] の差が、そのシナリオで Raw ノートの検証を通った Part のファイルと一致することを毎回確かめる

| # | 元 | 削除 ON での違い（これを確かめる） | 判定 | 記録 |
|---|---|---|---|---|
| R-01 | E2E-01 | Raw ノートの検証を通った直後に要求を書き、元音声が消える（Daily の保存を待たない）。`RAW_SAVED` → `SOURCE_DELETING` → `COMPLETED` | ⬜ 未実施 | §6.1 |
| R-02 | E2E-02 | コピー中に抜いても 1 本も消えない。再接続後の再コピー分も、Raw の検証を経てから消える。[C-7] の差分が「Raw の検証を通った分」と完全に一致 | ⬜ 未実施 | §6.2 |
| R-03 | E2E-03 | 文字起こし中に抜くと、デバイスが未接続なので削除せずに待つ（`sessions.delete_attempts` が増える）。挿し直すと消える。未接続を「書き込み可能」と誤認しない | ⬜ 未実施 | §6.3 |
| R-04 | E2E-04 | Vault が使えない間は 1 本も消えない（Raw ノートが書けない ＝ 根拠 A が成立しない）。戻したら消える | ⬜ 未実施 | §6.4 |
| R-05 | E2E-05 | 抜き挿し 6 回で要求が二重に書かれない（`request_id` が重複しない。`reaper.log` に `reason=replayed` が出ない） | ⬜ 未実施 | §6.5 |
| R-06 | E2E-06 | 1 日分でも要求の回収が追いつく（`queue/result` が溜まらない）。空き容量が録音 1 日分ぶん戻る | ⬜ 未実施 | §6.6 |
| R-07 | E2E-07 | 無音の Part は消えない（根拠 B は既定 false）。根拠 B を有効にすると消える。有効にしたら必ず元に戻す | ⬜ 未実施 | §6.7 |
| R-08 | E2E-08 | `WHISPER_FAILED` の Part は消えない。他の Part は消える。再コピー → 完走の後に消える | ⬜ 未実施 | §6.8 |
| R-09 | E2E-09 | 再オープンしても、すでに消えた Part を消し直さない（`source_deleted_at` が在る Part に要求を書かない） | ⬜ 未実施 | §6.9 |

### 6.1 R-01 — 1 本を通しで（削除 ON）

#### 前提
削除 ON（E2E-10 が PASS）。§3.1 の前提。

#### 手順
【利用者が行う】§3.1 の手順を行う。加えて [C-7]・[C-13]・[C-14] を前後で取り、[C-4] の今回の Part の遷移を取る。

#### 期待
今回の 1 本だけが消える（[C-7] の前後の差がその 1 本）。[C-4] の今回の Part が `RAW_SAVED` → `SOURCE_DELETING` → `COMPLETED`。
[C-14] の今回の `recording_key` の `delete_requested` が `raw_note_saved` の後に出て、`obsidian_saved` を待たない（`obsidian_saved` より前に出る）。そのあと `reaper_run exit=0` と `source_deleted` が出る。
Raw / Daily ノートと `## Timeline` は §3.1 の期待のとおり。

#### 記録
[C-7] の前後の `diff`、[C-13]、[C-14]、[C-4] の今回の Part の遷移、[C-3]。

```text
```

#### 判定
⬜ 未実施

### 6.2 R-02 — コピー中に抜く（削除 ON）

#### 前提
削除 ON。§3.2 の前提（30 分程度の録音を 3 本）。

**危険**: この試験は、読み書き可能でマウントされたデバイスを取り出さずに急に抜く。**FAT が壊れて、デバイスの録音を失うおそれがある。**次の安全の手順を省かない。

- E2E-10 の手順 1 の退避（`device-backup` と件数の照合）が済んでいること
- 抜く直前に、デバイスの全ファイルの一覧を取る: `find "/Volumes/$DEV" -type f -exec stat -f '%z %m %N' {} \; | sort | tee "$BACKUP/device-all-before-r02.txt"`
- 抜く直前に [C-6] で `queue/delete` が**空**であることを確かめる（空でなければ空になるまで待つ。要求が残ったまま抜かない）
- 挿し直したら、同じ `find` を `device-all-after-r02.txt` に取り、`comm -23 "$BACKUP/device-all-before-r02.txt" "$BACKUP/device-all-after-r02.txt"` で**前にあって後に無い行**を出す。
  出た行が、その間に Raw の検証を通って消えた Part のファイル（[C-13] の `source_deleted_at` が入った行）だけであること
- 挿し直したときに macOS がディスクの**修復や初期化**を求めたら、押さずに**中断**する（何もせずに取り出す）。続けるかどうかは利用者が判断する

#### 手順
【利用者が行う】§3.2 の手順を行う。加えて [C-7]・[C-13]・[C-14] を前後で取る。


#### 期待
抜いた時点では 1 本も消えていない（§3.2 の 6 の `diff` が空）。コピー未完了の Part に要求を書かない（抜いた時点までの [C-14] に今回の `delete_requested` が無い）。
再接続後に再コピーされた分も、Raw の検証を経てから消える。最後の [C-7] の差分が「Raw の検証を通った分」（今回の 3 本）と完全に一致する。

#### 記録
§3.2 の記録に加えて、[C-7] の前後、[C-13]、[C-14]、抜く直前の [C-6]、`comm -23` の出力。

```text
```

#### 判定
⬜ 未実施

### 6.3 R-03 — 文字起こし中に抜く（削除 ON）

#### 前提
削除 ON。§3.3 の前提（数分の録音を 1 本）。

**危険**: この試験は、読み書き可能でマウントされたデバイスを取り出さずに急に抜く。**FAT が壊れて、デバイスの録音を失うおそれがある。**次の安全の手順を省かない。

- E2E-10 の手順 1 の退避（`device-backup` と件数の照合）が済んでいること
- 抜く直前に、デバイスの全ファイルの一覧を取る: `find "/Volumes/$DEV" -type f -exec stat -f '%z %m %N' {} \; | sort | tee "$BACKUP/device-all-before-r03.txt"`
- 抜く直前に [C-6] で `queue/delete` が**空**であることを確かめる（空でなければ空になるまで待つ。要求が残ったまま抜かない）
- 挿し直したら、同じ `find` を `device-all-after-r03.txt` に取り、`comm -23 "$BACKUP/device-all-before-r03.txt" "$BACKUP/device-all-after-r03.txt"` で**前にあって後に無い行**を出す。
  出た行が、その間に Raw の検証を通って消えた Part のファイル（[C-13] の `source_deleted_at` が入った行）だけであること
- 挿し直したときに macOS がディスクの**修復や初期化**を求めたら、押さずに**中断**する（何もせずに取り出す）。続けるかどうかは利用者が判断する

#### 手順
【利用者が行う】§3.3 の手順を行う。加えて [C-7]・[C-13]・[C-14] を前後で取る。
挿し直す前（§3.3 の 5）に `sqlite3 -header -column "$VD_DB" "SELECT session_key, status, delete_attempts FROM sessions ORDER BY updated_at DESC LIMIT 3;"` を取り、数分おいてもう一度取る。

#### 期待
挿し直す前: 今回の Part が `RAW_SAVED` のまま、Session が `COMPLETED` にならず、`delete_attempts` が 1 以上で、2 回目の値が 1 回目より小さくない（未接続は待つ）。
`source_delete_skipped … reason=device_readonly` が今回の Session に出ない（**未接続を「読み取り専用」とも「書き込み可能」とも誤認しない**）。
挿し直した後: 今回の 1 本が消え、Part と Session が `COMPLETED` になる。

#### 記録
§3.3 の記録に加えて、挿し直す前の 2 回の `delete_attempts`、[C-7] の前後、[C-13]、[C-14]、抜く直前の [C-6]、`comm -23` の出力。

```text
```

#### 判定
⬜ 未実施

### 6.4 R-04 — Vault を利用不可にする（削除 ON）

#### 前提
削除 ON。§3.4 の前提。

#### 手順
【利用者が行う】§3.4 の手順を行う。加えて [C-7]・[C-13]・[C-14] を前後で取り、§3.4 の 5 の時点でも [C-7] を取る。

#### 期待
Vault が使えない間は 1 本も消えない（5 の [C-7] が前と一致。[C-14] に今回の `delete_requested` が無い）。
戻したあと、Raw ノートが書かれてから今回の 1 本が消える（`raw_note_saved` → `delete_requested` → `source_deleted`）。

#### 記録
§3.4 の記録に加えて、[C-7] の 3 回分、[C-13]、[C-14]。

```text
```

#### 判定
⬜ 未実施

### 6.5 R-05 — 抜き挿しを 6 回以上（削除 ON）

#### 前提
削除 ON。§3.5 の前提に加えて、1 分程度の録音を 1 本だけ新しく録っておく（要求を書く機会を作る）。

#### 手順
【利用者が行う】§3.5 の手順を行う。**各回、抜く前に Finder でデバイスを取り出す**。1 回目の挿入ではパネルが「待機中」に戻るまで待つ（新しい 1 本が消える）。加えて [C-7]・[C-13]・[C-14] を前後で取る。
後に次の 2 つを取る:
`cat "$VD_HOME/logs/app.log.1" "$VD_HOME/logs/app.log" 2>/dev/null | grep delete_requested | grep -o 'request_id=[^ ]*' | sort | uniq -d` と
`grep -c 'reason=replayed' "$VD_HOME/logs/reaper.log"`。

#### 期待
消えるのは新しい 1 本だけ（[C-7] の前後の差が 1 本）。今回の `recording_key` の `delete_requested` が 1 行だけ。
1 つ目のコマンドが何も出さない（`request_id` の重複が無い）。2 つ目が `0`。Part の件数は 1 回目で新しい 1 本の分だけ増え、2 回目以降は増えない。

#### 記録
§3.5 の記録に加えて、[C-7] の前後、[C-13]、[C-14]、上の 2 つのコマンドの出力。

```text
```

#### 判定
⬜ 未実施

### 6.6 R-06 — 1 日分を 1 セッションに（削除 ON）

#### 前提
削除 ON。§3.6 の前提（運用の中で確認してよい）。

#### 手順
【利用者が行う】§3.6 の手順を行う。加えて [C-7]・[C-13]・[C-14] を前後で取り、[C-6] と [C-15] を前後で取る。

#### 期待
§3.6 の期待に加えて、[C-6] の `queue/result` が空に戻っている（回収が追いつく）。[C-15] の空き容量が、その日の録音の分だけ戻る。
[C-7] の差分がその日の Raw ノートに載った Part のファイルと一致する。

#### 記録
§3.6 の記録に加えて、[C-6] と [C-15] の前後、[C-7] の前後の `diff`、[C-13]、[C-14]。

```text
```

#### 判定
⬜ 未実施

### 6.7 R-07 — 無音の Part を混ぜる（削除 ON）

#### 前提
削除 ON。§3.7 の前提（無音だけの録音 1 本 ＋ 普通の録音 1 本）。根拠 B は無効（「元音声の削除」の画面に赤い「無音・重複も消す」（長押し）が出ている）。

#### 手順
【利用者が行う】

1. §3.7 の手順を行う。加えて [C-7]・[C-13]・[C-14] を前後で取る
2. **押す前に、消える範囲を確かめる。過去の無音・重複も消える**（根拠 B は、デバイスに今在る `SKIPPED` の Part を全部対象にする。E2E-07・E2E-10 の無音の録音や、§1 の下準備で取り込んだ録音の重複も含む）。
   次の一覧を取り、ここに載った録音が消えてよいことを利用者が確かめる。消えてよくない録音があれば 3 を行わない:
   `sqlite3 -header -column "$VD_DB" "SELECT partkey, source_path, error_code FROM recordings WHERE status='SKIPPED' AND source_deleted_at IS NULL;"`
3. デバイスを挿したまま、「元音声の削除」の画面で赤い「無音・重複も消す」を 3 秒押し続ける
4. 2 分待って [C-7]・[C-13]・[C-14] を取る
5. **元に戻す**: 「無効にする」を押し、E2E-10 の手順 2 の 3 秒の長押しで有効にし直し、Finder でデバイスを取り出して挿し直す。[C-11] を取り、赤い「無音・重複も消す」（長押し）がまた出ていることを確かめる

#### 期待
1: 普通の 1 本だけが消え、無音の 1 本は残る（`SKIPPED` のまま、`delete_request_id` も `source_deleted_at` も空）。
3〜4: [C-14] に `deletion_enabled reason=skipped_source`、続いて消えた Part ごとに `delete_requested` と `source_deleted` が出る。
消えるのは 2 の一覧のうち、`error_code` が `NO_SPEECH_DETECTED` か `DUPLICATE_CONTENT` で、デバイスに今在る録音である（`DUPLICATE_CONTENT` は双子の Part の Raw ノートの検証も要る。上限は 2 の一覧の本数）。
[C-7] の前後の差がその本数と一致し、どれも 2 の一覧に在る。消えた Part は `SKIPPED` のまま `source_deleted_at` に時刻が入る。今回の無音の 1 本もその中に在る。
5: 根拠 B を戻す操作は「無効にする」だけである（無効化が `deleteSkippedSource` も false にする）。有効にし直した後の [C-11] は E2E-10 の 3 と同じ 3 行になる。

#### 記録
§3.7 の記録に加えて、2 の一覧と利用者が確かめたこと、1 と 4 の [C-7]・[C-13]・[C-14]、5 の [C-11]。

```text
```

#### 判定
⬜ 未実施

### 6.8 R-08 — 1 本だけ文字起こしを失敗させる（削除 ON）

#### 前提
削除 ON。§3.8 の前提。

#### 手順
【利用者が行う】§3.8 の手順を行う。加えて [C-7]・[C-13]・[C-14] を §3.8 の 1 の前・5 の後・10 の後に取る。

#### 期待
5 の後: `WHISPER_FAILED` の Part の元音声は残り、他の Part の元音声は消える。
10 の後: 再コピー → 完走の後に、残っていた 1 本も消える（`COMPLETED`・`source_deleted_at` に時刻）。

#### 記録
§3.8 の記録に加えて、3 回分の [C-7]・[C-13]・[C-14]。

```text
```

#### 判定
⬜ 未実施

### 6.9 R-09 — 保存後に同じ日の Part を追加（削除 ON）

#### 前提
削除 ON。§3.9 の前提（R-01 が済んでいる）。

#### 手順
【利用者が行う】§3.9 の手順を行う。加えて [C-7]・[C-13]・[C-14] を各回の前後で取る。
最後に `grep -c 'reason=target_missing' "$VD_HOME/logs/reaper.log"` を取る。

#### 期待
各回、消えるのはその回に足した 1 本だけ（[C-7] の差が毎回 1 本）。`delete_requested` はその回の `recording_key` の 1 行だけで、`source_deleted_at` が在る Part の `delete_requested` は出ない。
最後のコマンドが `0`（すでに消えたファイルへの要求を書いていない）。Daily / Raw ノートは §3.9 の期待のとおり同じ 1 ファイル。

#### 記録
§3.9 の記録に加えて、4 回分の [C-7] の前後、[C-13]、[C-14]、最後のコマンドの出力。

```text
```

#### 判定
⬜ 未実施
