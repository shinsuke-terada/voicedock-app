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
- 実機で消えてよいのは「この試験のために新しく録った録音」だけである
- **1 件でも FAIL なら修正チケットを起票し、次の Phase へ進まない**（PLAN §12.4）

## 1. 前提

- `make app` で組み立てた `VoiceDock.app`（T-34）を使う。**ad-hoc 署名では行わない**（TCC の許可がビルドのたびに失効する）。
  署名の確認: `codesign -dvvv <VoiceDock.app のパス> 2>&1 | grep -E 'Identifier=|TeamIdentifier='`
- **削除は OFF のまま行う**（E2E-10 / E2E-11 / E2E-17 を除く）。パネルの「元音声の削除」で三重ロックが 3 つとも掛かっていることを確かめてから始める
- パネルの「詳細 → 診断を実行」がすべて ✓ か ! であること（✗ が残っていたら先に直す）
- 環境変数（各シナリオのコマンドが使う）:

```bash
export VD_HOME="$HOME/Library/Application Support/VoiceDock"
export VD_DB="$VD_HOME/voicedock.sqlite"
export VAULT="<Obsidian の Vault の絶対パス>"
export DEV="<デバイスのボリューム名。例 DJIMIC3>"
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
| `[C-10]` パネルの写し | パネルの「状態」「要対応」「詳細 → 状態の詳細」に出ている文言を**そのまま書き写す**（スクリーンショットは貼らない。文字で残す） |

- `[C-7]` と `[C-8]` は**読み取りだけ**である。`diskutil`・`hdiutil`・`rm`・`mv` をデバイスに対して打つ手順はこの文書に無い
- `sqlite3` は macOS に最初から在る（`/usr/bin/sqlite3`）。**DB は読み取りだけ**（`SELECT` 以外を打たない）
- `[C-7]` はデバイスが挿さっているときしか取れない。「前」の `[C-7]` は、**挿したあと `[C-8]` に `read-only` が出てから**取る（削除 OFF ではアプリはデバイスに書かないので、挿した直後の一覧がそのまま「前」になる。再マウントの途中で打つとマウント先が一瞬無く、`No such file or directory` になる）

### 実機を使う前にやること【利用者が行う】

試験の日の最初に、次の 4 つを順に行う。**1 は実機を挿す前に行う。**デバイスに対しては読み取りだけで、書き込むのはホームの下だけである。

1. **voicedock（参照実装）が動いていないことを確かめる。**このアプリは voicedock との共存を見張らない（PLAN F-61 で共存ガードを取り下げた）。
   voicedock の Helper が登録されたままだと、同じデバイスを 2 つのアプリが同時に扱う。確かめ方は読み取りだけ:

   ```bash
   launchctl print "gui/$(id -u)/com.voicedock.ingest" > /dev/null 2>&1; echo "exit=$?"
   command -v docker && docker ps --format '{{.Names}}' | grep -i voicedock
   ```

   期待: 1 行目が `exit=0` **でない**（Helper の LaunchAgent が登録されていない）。2 行目は docker のパスのほかに何も出ない（docker が無ければ何も出さずに終わる）。
   **どちらかが残っていたら試験を始めない。**voicedock の止め方はこの文書に書かない（voicedock の側の手順で止める）

2. **このアプリで下準備の接続を 1 回行う。**このアプリは voicedock の取り込み済みの記録を引き継がない（PLAN F-60）ので、
   最初の接続ではデバイスに残っている以前の録音も**すべて**取り込まれる（削除 OFF なので 1 本も消えない）。
   以前の録音の処理が各シナリオに混ざらないように、E2E-01 の前にいちど挿して、パネルが「待機中」に戻るまで待つ。
   以前の録音のノートが `$VAULT` に書かれる。普段の Vault を汚したくなければ、試験用の Vault を作って「保存先（Vault）」に選んでおく

3. **デバイスの全ファイルの一覧を退避する。**下準備の接続のあいだ（`[C-8]` に `read-only` が出たあと）に取る。
   `[C-7]` は `.wav` だけを見るので、ここでは種類を問わず全ファイルを取る:

   ```bash
   mkdir -p "$HOME/VoiceDockE2E"
   find "/Volumes/$DEV" -type f -exec stat -f '%z %m %N' {} \; | sort | tee "$HOME/VoiceDockE2E/device-all-before.txt"
   wc -l "$HOME/VoiceDockE2E/device-all-before.txt"
   ```

   試験をすべて終えたら、同じ `find` の出力を `device-all-after.txt` に取り、`comm -23` で**前にあって後に無い行**が 0 行であることを確かめる
   （削除 OFF の 13 件では録音は 1 本も消えない。後には新しく録った分が増えているだけになる）:

   ```bash
   comm -23 "$HOME/VoiceDockE2E/device-all-before.txt" "$HOME/VoiceDockE2E/device-all-after.txt"
   ```

4. 下準備の接続が終わったら、以後の各シナリオはそのシナリオの `#### 前提` どおりに録音を足して挿す

### 手順の実在確認

この文書が書くリポジトリの中のコマンドは、**いまの develop に在るものだけ**である。

- `make vendor`（T-03。`whisper-cli` と `llama-server` を作る。`make app` の前に 1 回）
- `make app`（T-34。中身は `scripts/make-app.sh` の `debug`。開発用の証明書で署名した `dist/VoiceDock.app` ができる）
- 起動は `open dist/VoiceDock.app`（リポジトリのルートで）。`swift run VoiceDockApp` は使わない（`.app` にならず、署名も TCC の許可も試験の条件と違う）
- `make test`（すべて終えたあとに回す。この文書の書式を `Tests/PolicyTests/RunbookTests.swift` が検査する）
- `make spec`（PLAN 付録 B.3 を直したときだけ）

リポジトリの中のファイルのパスと `make` のターゲットは、`RunbookTests` が**実在を検査する**。無いものを書くと `make test` が落ちる。

## 2. 判定表

| # | シナリオ | 削除 | 判定 | 記録 |
|---|---|---|---|---|
| E2E-01 | 1 本を通しで | OFF | ⬜ 未実施 | §3.1 |
| E2E-02 | コピー中に抜く | OFF | ⬜ 未実施 | §3.2 |
| E2E-03 | 文字起こし中に抜く | OFF | ⬜ 未実施 | §3.3 |
| E2E-04 | Vault を利用不可にする | OFF | ⬜ 未実施 | §3.4 |
| E2E-05 | 抜き挿しを 6 回以上 | OFF | ⬜ 未実施 | §3.5 |
| E2E-06 | 1 日分を 1 セッションに | OFF | ⬜ 未実施 | §3.6 |
| E2E-07 | 無音の Part を混ぜる | OFF | ⬜ 未実施 | §3.7 |
| E2E-08 | 1 本だけ文字起こしを失敗させる | OFF | ⬜ 未実施 | §3.8 |
| E2E-09 | 保存後に同じ日の Part を追加 | OFF | ⬜ 未実施 | §3.9 |
| E2E-10 | 削除 ON で通し | ON | ⬜ 未実施 | §3.10 |
| E2E-11 | 過去分の削除・手動で消した分の完了 | ON | ⬜ 未実施 | §3.11 |
| E2E-12 | 文字起こし中に強制終了 | OFF | ⬜ 未実施 | §3.12 |
| E2E-13 | 処理中にスリープ | OFF | ⬜ 未実施 | §3.13 |
| E2E-14 | アプリが動いていない間に接続 | OFF | ⬜ 未実施 | §3.14 |
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
[C-1]（前後）、[C-3]、[C-7]（前後の `diff`）、[C-8]、[C-9]（後）、Daily ノートの `## Timeline` の見出しから 5 行。

```text
```

#### 判定
⬜ 未実施

### 3.2 E2E-02 — コピー中に抜く

#### 前提
削除 OFF。**危険な窓はコピー中である**（変換中ではない。変換は inbox から読むのでデバイスと無関係）。
**コピーに数分かかる状態を作る**: 30 分程度の録音を 3 本、新しく録っておく（24 bit / 48 kHz なら 1 本約 259 MB）。

#### 手順
【利用者が行う】

1. [C-1]・[C-5] を取る
2. デバイスを挿す
3. [C-8] に `read-only` が出たら [C-7] を取り、**ファイルに保存する**（[C-7] のコマンドの末尾に `> /tmp/e2e02-before.txt` を足す）
4. パネルが「取り込み中 n/3」の間に、**コピーが始まってから 30 秒待って抜く**
5. [C-5]・[C-2] を取る
6. もう一度挿し、[C-8] に `read-only` が出たら [C-7] を `/tmp/e2e02-after.txt` に取り、`diff /tmp/e2e02-before.txt /tmp/e2e02-after.txt; echo "exit=$?"` を打つ
7. 最後まで待つ
8. [C-1]・[C-5]・[C-7]・[C-10] を取る

**落とし穴**: 10 秒の録音では窓が取れない。**コピーが 30 秒以上続く状態でなければこの試験は空振りする**（voicedock は v5.24 までここを取り違えていた）。

#### 期待
抜いた直後: `.<名前>.partial` が inbox から**消える**（[C-5] に `.partial` が無い）。`copy_failed reason=read_error`（または `changed`）が出る。クラッシュしない。
**デバイスの全ファイルのサイズと mtime が 1 バイトも変わらない**（6 の `diff` が空）。
再接続で**同じファイルを最初から再コピー**し、最後まで通る。
**inbox に取り残しが出ない**（パネルの「状態の詳細」の inbox が「処理待ち n 件」だけで「取り残し」が 0 件。voicedock #120）。

#### 記録
6 の `diff` の**全文**（空なら `（差分なし）` と書いてコマンドと終了コードを貼る）、[C-5] の前後、`copy_failed` の行、[C-10] の inbox の 2 つの件数。

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
[C-1]（後）、[C-4] の当該 Part の遷移、`source_delete_skipped` の行、[C-6]、[C-7] の前後の `diff`。

```text
```

#### 判定
⬜ 未実施

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
5 の `diff /tmp/e2e04-before.txt <(…)` の全文、`pipeline_paused` と `pipeline_resumed` の行、4 と 8 の [C-10]。

```text
```

#### 判定
⬜ 未実施

### 3.5 E2E-05 — 抜き挿しを 6 回以上

#### 前提
削除 OFF。**処理が全部終わった状態**（パネルが「待機中」）。新しい録音は足さない。

#### 手順
【利用者が行う】

1. [C-1] と `grep -c -E 'part_discovered|copy_completed|file_not_stable' "$VD_HOME/logs/app.log"` を取る（前）
2. 挿す → [C-8] に `read-only` が出る → パネルが「待機中」のままであることを見る → 抜く、を **6 回**繰り返す（各回の [C-8] を取る）
3. [C-1] と 1 と同じ `grep -c` を取る（後）

#### 期待
Part と Session の件数が**1 件も増えない**（[C-1] の前後が完全一致）。
各回に [C-8] に `read-only` が出る（アプリが毎回デバイスを見つけ、読み取り専用へ再マウントした）。
`part_discovered`・`copy_completed`・`file_not_stable` の件数が前後で同じ。
`scan_completed devices=1 copied=0` はコピーが 0 件なので DEBUG であり、既定（`logging.level` が `INFO`）の `app.log` には出ない（PLAN 付録 A.4）。

#### 記録
[C-1] の前後の表、1 と 3 の `grep -c` の出力、6 回分の [C-8]。

```text
```

#### 判定
⬜ 未実施

### 3.6 E2E-06 — 1 日分を 1 セッションに

#### 前提
削除 OFF。**運用の中で確認してよい**（リリースはこれを待たない。PLAN 付録 B.3）。

#### 手順
【利用者が行う】

1. 丸 1 日 DJI Mic 3 で録る（1 本 30 分で約 32 本）
2. 帰宅して挿す
3. 挿した時刻を記録する
4. パネルが「待機中」に戻った時刻を記録する
5. [C-1]・[C-3]・[C-9]・[C-10]

**目安**: 文字起こしの所要は**文字数で決まる**（voicedock の実測で 3.9〜4.6 字/秒。密な発話 16 時間で約 15 時間）。薄い発話なら大幅に短い。

#### 期待
**1 日分が 1 つの Session にまとまる**（`sessions` が 1 行、`part_count` が本数と一致）。Raw 1 枚・Daily 1 枚。
**次の接続（24 時間後）までに処理が終わる**（3 と 4 の差が 24 時間未満）。

#### 記録
3 と 4 の時刻と差、`sqlite3 "$VD_DB" "SELECT session_key, part_count, failed_part_count, recorded_seconds, status FROM sessions;"`、
`transcription_completed` の `rtf=` の一覧（`grep -o 'rtf=[0-9.]*'`）。

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
止まらない。無音の Part は `SKIPPED`（`NO_SPEECH`）、もう 1 本は `COMPLETED`。Daily の警告行に**「無音」**と出る。
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
8. 完走を待って [C-1]・[C-4]

**落とし穴**: **モデルのファイルを消して失敗させない**（起動時の前提の確認に引っかかって別の経路になる。voicedock #131）。
**壊すのは 16 kHz 音声だけ**。FAILED になった Part の 16 kHz 音声を**勝手に消さない**のが正しい動き（voicedock #133 の逆）。

#### 期待
5: その Part が `FAILED`（`WHISPER_FAILED`）、他の Part は進み、Daily に警告行が出る。
**`error_message` がヘルプ全文になっていない**（voicedock #135。`sqlite3 "$VD_DB" "SELECT length(error_message) FROM recordings WHERE status='FAILED';"` が数百文字以内）。
8: 16 kHz 音声が無いので `NORMALIZED_MISSING` → **再コピー** → 再評価で完走して `COMPLETED`。

#### 記録
5 と 8 の [C-1]・[C-4]、`error_message` の全文と長さ、`normalize_completed` が 2 回出ていること。

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
[C-9] の前後（4 回分のファイル数）、`grep -c session_reopened`、`grep -c llm_completed`。

```text
```

#### 判定
⬜ 未実施

### 3.10 E2E-10 — 削除 ON で通し

#### 前提
削除 ON。**T-42（Phase 8）で実施する。**

#### 手順
T-42 で書く（【利用者が行う】）。

#### 期待
PLAN 付録 B.3 の E2E-10 の行。

#### 記録
（T-42）

#### 判定
⬜ 未実施

### 3.11 E2E-11 — 過去分の削除・手動で消した分の完了

#### 前提
削除 ON。**T-42（Phase 8）で実施する。**

#### 手順
T-42 で書く（【利用者が行う】）。

#### 期待
PLAN 付録 B.3 の E2E-11 の行。

#### 記録
（T-42）

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
**二重処理しない**（[C-1] の Part の合計が前後で同じ、`part_discovered` が本数ぶんだけ）。`recovery_completed rolled_back=<n>` が 1 件出る。

#### 記録
[C-1] の前後、4 の出力、`recovery_completed` の行、[C-4] の巻き戻しの遷移。

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
削除 OFF。1 分程度の録音 1 本。**アプリを終了しておく**（パネルの「終了」）。

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
[C-1]（前後）、`service_started` と最初の `scan_completed` の行と時刻。

```text
```

#### 判定
⬜ 未実施

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
削除 ON→OFF。**T-42（Phase 8）で実施する。**

#### 手順
T-42 で書く（【利用者が行う】）。

#### 期待
PLAN 付録 B.3 の E2E-17 の行。

#### 記録
（T-42）

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
