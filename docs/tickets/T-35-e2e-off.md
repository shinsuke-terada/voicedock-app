# T-35 実機 E2E（削除 OFF）と E2E.md の文書テスト

| 項目 | 値 |
|---|---|
| ID | T-35 |
| 題 | `docs/E2E.md` の書式と、削除 OFF の E2E-01〜09・12〜16・18 の手順・実施・記録 |
| Phase | 7 |
| 前提 | T-30（UI）、T-31（はじめに・Vault・モデル）、T-32（診断・要対応・状態の詳細）、T-33（乗り換え）、T-34（`make app`） |
| 見積もり | `docs/E2E.md` 約 700 行（文書。差分の目安の 600 行には数えない）＋ `Tests/PolicyTests/RunbookTests.swift` 約 230 行 |

## 1. 目的

実機（DJI Mic 3）で行う試験の**正本**を `docs/E2E.md` に置き、書式を機械で守る。削除 OFF の 15 件（E2E-01〜09・12〜16・18）を実機で通し、
**要約した数値ではなく生の出力**を貼る。**この文書が腐らないことを文書テストが保証する**（voicedock では手順の正本を GitHub issue に置いたため、
削除したコマンドの手順が何も落ちずに残り、実機を繋いだ当日に最初の 1 行で止まった。#93）。

削除 ON の 3 件（E2E-10・11・17）と削除のゲート（PLAN §12.4）は T-42。

## 2. 参照

- PLAN 付録 B.3（E2E の表。`docs/SPEC.md` の `S9` に写されている）、§10.3（文書テスト・SPEC 同期の読み方）、§12.1（リリースと削除の有効化を分ける）、§13（検証の段）
- PLAN §8.1（取り込み・共存ガード）、§8.7（Vault のガード）、§8.11（診断・要対応）、§8.12（パネルの文言）、§8.13（乗り換え）、§8.15（スリープ）、付録 A.4（ログイベント）、§7.2（DB のスキーマ）、§14（RK-07・RK-22・RK-23・RK-25）
- 先行チケット: T-04（`MarkdownDocument`）、T-05（`SpecDocument`・`SpecIDKind.e2e`・`SpecCoverage`）、T-01（`PackageRoot`・`Makefile`）、T-34（`scripts/*`）、P0（`docs/POC.md` の §0 記録の規約と【利用者が行う】の扱い）
- 移植メモ `docs/porting-notes/V6-doctor-ci-e2e-docs.md` §4.4（`test_runbook.py`）・§9（E2E.md の書式と、voicedock の E2E で見つかった欠陥）
- voicedock@d3d595e: `docs/E2E.md`（書式）、`tests/unit/test_runbook.py`（判定表と SPEC の 1 対 1、判定欄の書式、手順節の存在、参照するスクリプトの実在、**検査自体の陽性対照**）

## 3. 安全の規則（最初に読む）

- **実機に触れる手順はすべて `【利用者が行う】` と書く。**エージェント（Claude など）は実行しない（PLAN の安全の約束、`docs/tickets/README.md`）
- `/Volumes` 配下の実機に対して **`diskutil`・`hdiutil`・書き込み・削除・再マウントのコマンドを手順に書かない**。読み取り（`find` / `stat` / `ls` / `/sbin/mount`）だけを書く。
  読み取り専用への再マウントは**アプリが行う**（手で `diskutil` を打つ手順を書かない）
- 実機で消えてよいのは「この試験のために新しく録った録音」だけ。試験を始める前に、**デバイスの全ファイルの一覧（`[C-7]`）を退避する**
- 削除 OFF の 15 件では**録音は 1 本も消えない**。1 本でも消えたら FAIL にして原因を調べる（ND の穴）

## 4. 作るもの

| パス | 内容 |
|---|---|
| `docs/E2E.md` | 下記 §5 の書式で新規作成（`## 0` 〜 `## 3`。`## 4` 以降は T-42） |
| `Tests/PolicyTests/RunbookTests.swift` | 下記 §7 の全文 |
| `Makefile` | 変更なし |

## 5. `docs/E2E.md` の書式

### 5.1 全体の形（見出しはこの順・この文字列）

```text
# VoiceDock for Mac 実機 E2E
（前書き 3 段落。§5.2 の逐語）
## 0. 記録の規約
## 1. 前提
## 2. 判定表
## 3. シナリオ
### 3.1 E2E-01 — <題>
#### 前提
#### 手順
#### 期待
#### 記録
#### 判定
### 3.2 E2E-02 — <題>
…
### 3.18 E2E-18 — <題>
```

- **節の番号は E2E の番号と同じ**（`### 3.<n> E2E-<nn> — ` で `n` と `nn` の整数が等しい。`3.10` ↔ `E2E-10`）。テスト `sectionNumberMatchesTheScenario` が見る
- シナリオの節は**必ず 5 つの `####` を持つ**（`前提`・`手順`・`期待`・`記録`・`判定`）。順序もこのとおり
- `#### 判定` の**直後の空でない行**が判定（`✅ PASS` / `✗ FAIL` / `⬜ 未実施` / `— 対象外` のどれかで始まる）。判定表の同じ ID の判定と**一字一句一致**させる
- `#### 記録` には生の出力を ```` ```text ```` のフェンスで貼る。**判定が `✅ PASS` か `✗ FAIL` のシナリオは、空でないフェンスを 1 つ以上持つ**（テスト `aVerdictNeedsEvidence`）
- 実機に触れるシナリオの `#### 手順` には `【利用者が行う】` を書く（全 18 件が該当する）

### 5.2 `## 0. 記録の規約`（逐語。この節をそのまま置く）

```markdown
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
```

### 5.3 `## 1. 前提`（逐語。共通のコマンドをここで名前を付けて置く）

各シナリオは `[C-1]` のような名前で参照する。**同じコマンドを 2 か所に書かない**（CR-06 と同じ考え）。

````markdown
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
````

### 5.4 `## 2. 判定表`（形）

```markdown
## 2. 判定表

| # | シナリオ | 削除 | 判定 | 記録 |
|---|---|---|---|---|
| E2E-01 | 1 本を通しで | OFF | ✅ PASS | §3.1 |
…
| E2E-18 | voicedock からの乗り換え | OFF | ✅ PASS | §3.18 |
```

- 行は **`docs/SPEC.md` の `S9` の ID と 1 対 1・同順**（18 行）。ID を勝手に足さない・飛ばさない
- 「シナリオ」の列は SPEC の「内容」の列の**先頭の短い題**（`### 3.N E2E-nn — <題>` の `<題>` と同じ文字列）
- 「削除」の列は SPEC の「削除」の列と同じ（`OFF` / `ON` / `ON→OFF`）
- T-35 では E2E-10・11・17 の判定を `⬜ 未実施`、記録を `§3.10`（T-42 で実施）とする

### 5.5 T-35 が置くシナリオの節

**18 件すべての節を置く**（文書テストが 18 件の節の存在を要求する）。E2E-10・11・17 は次の形の**骨組みだけ**を置き、T-42 が中身を書く:

```markdown
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
```

## 6. 削除 OFF の 15 件の中身

以下を §5.1 の型に流し込む。**「記録」の列のコマンドを打ち、その出力を `#### 記録` に貼る。**
すべてのシナリオの `#### 手順` の冒頭に `【利用者が行う】` を書く（実機の抜き挿しが要るため）。

### 6.1 E2E-01 — 1 本を通しで

| | |
|---|---|
| 題 | `1 本を通しで` |
| 前提 | 削除 OFF。**1 分程度を 1 本だけ**新しく録音する。デバイスに他の録音があってもよい（[C-7] で一覧を控える） |
| 手順 | ① [C-1]・[C-7]・[C-9] を取る（前） ② デバイスを USB で挿す ③ パネルの「状態」が「取り込み中」→「文字起こし中」→「要約中」と変わるのを見る ④ 「待機中」に戻ったら [C-1]・[C-3]・[C-7]・[C-9]・[C-10] を取る（後） |
| 期待 | `part_discovered` → `normalize_completed` → `transcription_completed` → `raw_note_saved` → `session_merged` → `llm_completed` → `obsidian_saved` がこの順に 1 組出る。Raw ノートと Daily ノートが各 1 枚できる。**元音声が残る**（[C-7] の前後が一致）。**単一チャンクでも Daily に `## Timeline` と時刻の見出しが出る**（Map の中間結果が無くても代替経路が働く） |
| 記録 | [C-1]（前後）、[C-3]、[C-7]（前後の `diff`）、[C-9]（後）、Daily ノートの `## Timeline` の見出しから 5 行 |
| 落とし穴 | 単一チャンクの Timeline は voicedock でも代替経路。**Timeline のために LLM を 2 回呼んでいないこと**（`llm_completed` が 1 件）を確かめる |

### 6.2 E2E-02 — コピー中に抜く

| | |
|---|---|
| 題 | `コピー中に抜く` |
| 前提 | 削除 OFF。**危険な窓はコピー中である**（変換中ではない。変換は inbox から読むのでデバイスと無関係）。**コピーに数分かかる状態を作る**: 30 分程度の録音を 3 本、新しく録っておく（24 bit / 48 kHz なら 1 本約 259 MB） |
| 手順 | ① [C-7] を取り、**ファイルに保存する**（`> /tmp/e2e02-before.txt`） ② [C-1]・[C-5] を取る ③ デバイスを挿す ④ **30 秒待って抜く**（パネルが「取り込み中 n/3」の間） ⑤ [C-5]・[C-2] を取る ⑥ [C-7] を `/tmp/e2e02-after.txt` に取り、`diff` する ⑦ もう一度挿して最後まで待つ ⑧ [C-1]・[C-5]・[C-7]・[C-10] を取る |
| 期待 | 抜いた直後: `.<名前>.partial` が inbox から**消える**（[C-5] に `.partial` が無い）。`copy_failed reason=read_error`（または `changed`）が出る。クラッシュしない。**デバイスの全ファイルのサイズと mtime が 1 バイトも変わらない**（⑥ の `diff` が空）。再接続で**同じファイルを最初から再コピー**し、最後まで通る。**inbox に取り残しが出ない**（パネルの「状態の詳細」の inbox が「処理待ち n 件」だけで「取り残し」が 0 件。voicedock #120） |
| 記録 | ⑥ の `diff` の**全文**（空なら `（差分なし）` と書いてコマンドと終了コードを貼る）、[C-5] の前後、`copy_failed` の行、[C-10] の inbox の 2 つの件数 |
| 落とし穴 | 10 秒の録音では窓が取れない。**コピーが 30 秒以上続く状態でなければこの試験は空振りする**（voicedock は v5.24 までここを取り違えていた） |

### 6.3 E2E-03 — 文字起こし中に抜く

| | |
|---|---|
| 題 | `文字起こし中に抜く` |
| 前提 | 削除 OFF。**数分の録音**を 1 本（10 秒では窓が取れない） |
| 手順 | ① 挿す ② パネルが「文字起こし中」になったら抜く ③ 完走するまで待つ ④ [C-1]・[C-3]・[C-4]・[C-7] |
| 期待 | 処理はコピー済みの inbox から続き、**削除 OFF なので最終状態は `COMPLETED`**（`SOURCE_DELETE_PENDING` にはならない）。`source_delete_skipped reason=delete_source_audio_disabled` が 1 件出る。元音声が残る |
| 記録 | [C-1]（後）、[C-4] の当該 Part の遷移、`source_delete_skipped` の行 |

### 6.4 E2E-04 — Vault を利用不可にする

| | |
|---|---|
| 題 | `Vault を利用不可にする` |
| 前提 | 削除 OFF。1 分程度の録音を 1 本。**Obsidian を終了しておく** |
| 手順 | ① [C-9] を `/tmp/e2e04-before.txt` に取る ② `mv "$VAULT/.obsidian" "$VAULT/.obsidian.bak"` ③ 挿す ④ パネルの「要対応」を見る（[C-10]） ⑤ [C-2]・[C-9] を取る ⑥ `mv "$VAULT/.obsidian.bak" "$VAULT/.obsidian"` ⑦ **アプリを再起動せずに**待つ（最大 30 秒 ＋ 1 tick） ⑧ [C-1]・[C-9]・[C-10] |
| 期待 | ④ 要対応に「保存先（Vault）が使えません」が出て「Vault を選び直す」ボタンが在る。`pipeline_paused reason=vault_unavailable` が出る。⑤ **Vault に何も書かれない**（[C-9] の前後が一致。**空のディレクトリを作っていない**。voicedock #134 はここが空振りしていた）。元音声が残る。⑦ **再起動なしで** `pipeline_resumed reason=vault_unavailable` が出て、Raw / Daily が書かれる |
| 記録 | ⑤ の `diff /tmp/e2e04-before.txt <(…)` の全文、`pipeline_paused` と `pipeline_resumed` の行、④ と ⑧ の [C-10] |
| 落とし穴 | `.obsidian` を消さずに**改名**する（消すと Obsidian の設定が失われる）。`$VAULT` を丸ごと `mv` しない（Vault のパスが変わると別の経路（`vaultNotConfigured`）に入って別の試験になる） |

### 6.5 E2E-05 — 抜き挿しを 6 回以上

| | |
|---|---|
| 題 | `抜き挿しを 6 回以上` |
| 前提 | 削除 OFF。**処理が全部終わった状態**（パネルが「待機中」） |
| 手順 | ① [C-1] を取る（前） ② 挿す → パネルが「待機中」に戻る → 抜く、を **6 回**繰り返す ③ [C-1]（後）・[C-2] |
| 期待 | Part と Session の件数が**1 件も増えない**（[C-1] の前後が完全一致）。各回に `scan_completed devices=1 copied=0` が出る。`file_not_stable` も `part_discovered` も出ない |
| 記録 | [C-1] の前後の表、`grep -c scan_completed`、`grep 'scan_completed'` の 6 行 |

### 6.6 E2E-06 — 1 日分（16 時間・約 32 本）

| | |
|---|---|
| 題 | `1 日分を 1 セッションに` |
| 前提 | 削除 OFF。**運用の中で確認してよい**（リリースはこれを待たない。PLAN 付録 B.3） |
| 手順 | ① 丸 1 日 DJI Mic 3 で録る（1 本 30 分で約 32 本） ② 帰宅して挿す ③ 挿した時刻を記録する ④ パネルが「待機中」に戻った時刻を記録する ⑤ [C-1]・[C-3]・[C-9]・[C-10] |
| 期待 | **1 日分が 1 つの Session にまとまる**（`sessions` が 1 行、`part_count` が本数と一致）。Raw 1 枚・Daily 1 枚。**次の接続（24 時間後）までに処理が終わる**（③ と ④ の差が 24 時間未満） |
| 記録 | ③ と ④ の時刻と差、`sqlite3 "$VD_DB" "SELECT session_key, part_count, failed_part_count, recorded_seconds, status FROM sessions;"`、`transcription_completed` の `rtf=` の一覧（`grep -o 'rtf=[0-9.]*'`） |
| 目安 | 文字起こしの所要は**文字数で決まる**（voicedock の実測で 3.9〜4.6 字/秒。密な発話 16 時間で約 15 時間）。薄い発話なら大幅に短い |

### 6.7 E2E-07 — 無音の Part を混ぜる

| | |
|---|---|
| 題 | `無音の Part を混ぜる` |
| 前提 | 削除 OFF。**無音だけの録音 1 本**（マイクを止めて 1 分録る）＋ 普通の録音 1 本 |
| 手順 | ① 2 本を録る ② 挿す ③ 完走を待つ ④ [C-1]・[C-3]・[C-4]・Daily ノートの警告の節 |
| 期待 | 止まらない。無音の Part は `SKIPPED`（`NO_SPEECH`）、もう 1 本は `COMPLETED`。Daily の警告行に**「無音」**と出る。**`⚠` が付かない**（`⚠` は許可リストで判定する。voicedock #140 は SKIPPED に「再試行されます」と書いていた）。**無音の元音声は残る**（根拠 B は既定 false） |
| 記録 | Daily ノートの警告の節を**行ごとそのまま**、[C-1]、`grep 'part_skipped\|transcription_completed' "$VD_HOME/logs/app.log"` |

### 6.8 E2E-08 — 1 本だけ文字起こしを失敗させる

| | |
|---|---|
| 題 | `1 本だけ文字起こしを失敗させる` |
| 前提 | 削除 OFF。3 本程度（うち 1 本を壊す） |
| 手順 | ① 挿す ② `watch -n 1 'ls -la "$VD_HOME/staging"/*/'` 相当で `audio16k.wav` ができるのを見張る（`watch` が無ければ `while sleep 1; do …; done`） ③ **ある Part が NORMALIZED になった直後**に `printf 'broken' > "$VD_HOME/staging/<slug>/audio16k.wav"` で上書きする ④ 完走を待つ ⑤ [C-1]・[C-4]・Daily の警告の節 ⑥ `rm "$VD_HOME/staging/<slug>/audio16k.wav"` ⑦ **もう一度挿す** ⑧ 完走を待って [C-1]・[C-4] |
| 期待 | ⑤ その Part が `FAILED`（`WHISPER_FAILED`）、他の Part は進み、Daily に警告行が出る。**`error_message` がヘルプ全文になっていない**（voicedock #135。`sqlite3 "$VD_DB" "SELECT length(error_message) FROM recordings WHERE status='FAILED';"` が数百文字以内） ⑧ 16 kHz 音声が無いので `NORMALIZED_MISSING` → **再コピー** → 再評価で完走して `COMPLETED` |
| 記録 | ⑤ と ⑧ の [C-1]・[C-4]、`error_message` の全文と長さ、`normalize_completed` が 2 回出ていること |
| 落とし穴 | **モデルのファイルを消して失敗させない**（起動時の前提の確認に引っかかって別の経路になる。voicedock #131）。**壊すのは 16 kHz 音声だけ**。FAILED になった Part の 16 kHz 音声を**勝手に消さない**のが正しい動き（voicedock #133 の逆） |

### 6.9 E2E-09 — 保存後に同じ日の Part を追加

| | |
|---|---|
| 題 | `保存後に同じ日の Part を追加` |
| 前提 | 削除 OFF。E2E-01 が済んでいる（同じ日の Daily ノートが保存済み） |
| 手順 | ① [C-9] を取る（前。ファイル数を数える） ② **同じ日に**もう 1 本録る ③ 挿す ④ 完走を待つ ⑤ [C-9]（後）・[C-3]・[C-4] ⑥ ②〜⑤ を**あと 3 回**繰り返す（計 4 回の再オープン） |
| 期待 | Daily ノートは**同じ 1 ファイル**が作り直される（[C-9] のファイル数が増えない。` (2)` が生えない）。`session_reopened` が毎回出て、`llm_completed` も毎回出る（**再オープンで解析をやり直す**。voicedock #108 はやり直していなかった）。Raw ノートも同じ 1 ファイル |
| 記録 | [C-9] の前後（4 回分のファイル数）、`grep -c session_reopened`、`grep -c llm_completed` |

### 6.10 E2E-12 — 文字起こし中に強制終了

| | |
|---|---|
| 題 | `文字起こし中に強制終了` |
| 前提 | 削除 OFF。数分の録音を 3 本 |
| 手順 | ① 挿す ② パネルが「文字起こし中」になったら [C-1]（前）を取る ③ `kill -9 $(pgrep -x VoiceDock)` ④ `pgrep -x whisper-cli` で**孫が残っていないこと**を見る（残っていれば記録する） ⑤ アプリを起動する ⑥ 完走を待って [C-1]（後）・[C-3]・[C-4] |
| 期待 | 起動時の復旧で途中の状態が巻き戻り、**途中から再開**する。**二重処理しない**（[C-1] の Part の合計が前後で同じ、`part_discovered` が本数ぶんだけ）。`recovery_completed rolled_back=<n>` が 1 件出る |
| 記録 | [C-1] の前後、④ の出力、`recovery_completed` の行、[C-4] の巻き戻しの遷移 |

### 6.11 E2E-13 — 処理中にスリープ

| | |
|---|---|
| 題 | `処理中にスリープ` |
| 前提 | 削除 OFF。数分の録音を 2 本以上（処理が数分続く状態） |
| 手順 | ① 挿す ② 処理中に `pmset -g assertions \| grep -A3 'Listed by owning process'` を取る ③ **アップルメニュー → スリープ**（電源ボタンではなく、明示的なスリープ） ④ 数分後にふたを開けて復帰 ⑤ 完走を待って [C-1]・[C-3]・[C-2] |
| 期待 | ② `VoiceDock` が `PreventUserIdleSystemSleep` を保持している（処理中だけ）。③ 明示的なスリープは掛かる（`beginActivity` はアイドルスリープだけを止める）。④ 復帰後に処理が続き、完走する。Part が `FAILED` にならない。アイドル時には ② のアサーションが**消えている** |
| 記録 | ② と（待機中に戻ったあとの）`pmset -g assertions` の 2 回分、[C-3]、スリープと復帰の時刻 |

### 6.12 E2E-14 — アプリが動いていない間に接続

| | |
|---|---|
| 題 | `アプリが動いていない間に接続` |
| 前提 | 削除 OFF。1 分程度の録音 1 本。**アプリを終了しておく**（パネルの「終了」） |
| 手順 | ① アプリを終了する（`pgrep -x VoiceDock` が空） ② 挿す ③ 1 分待つ ④ アプリを起動する ⑤ 完走を待って [C-1]・[C-3]・[C-9] |
| 期待 | ③ の間は何も起きない。④ の起動後の最初の走査で取り込まれ、最後まで通る（`service_started` → `scan_completed copied=1`） |
| 記録 | [C-1]（前後）、`service_started` と最初の `scan_completed` の行と時刻 |

### 6.13 E2E-15 — voicedock の Helper が登録されている

| | |
|---|---|
| 題 | `voicedock の Helper が登録されている` |
| 前提 | 削除 OFF。`launchctl print gui/$(id -u)/com.voicedock.ingest` が現在 0 以外（登録されていない）であることを確かめる |
| 手順 | ① 空の LaunchAgent を作って登録する（**何も起動しない plist**。voicedock 本体は要らない）<br>`cat > ~/Library/LaunchAgents/com.voicedock.ingest.plist <<'EOF'`<br>`<?xml version="1.0" encoding="UTF-8"?>`<br>`<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">`<br>`<plist version="1.0"><dict><key>Label</key><string>com.voicedock.ingest</string>`<br>`<key>ProgramArguments</key><array><string>/usr/bin/true</string></array>`<br>`<key>RunAtLoad</key><false/></dict></plist>`<br>`EOF`<br>`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.voicedock.ingest.plist` ② アプリを再起動する ③ 挿す ④ [C-1]・[C-2]・[C-10] ⑤ パネルの「詳細 → 診断を実行」で DR-13 を見る ⑥ **後始末**: `launchctl bootout gui/$(id -u)/com.voicedock.ingest ; rm ~/Library/LaunchAgents/com.voicedock.ingest.plist` ⑦ アプリを再起動して ③ をやり直す |
| 期待 | ③ **取り込まない**（Part が増えない）。`coexistence_blocked` が **1 回だけ**出る（毎回出ない）。要対応に「voicedock の Helper が登録されています」が出る。⑤ DR-13 が ✗。⑦ 後始末の後は普通に取り込む |
| 記録 | ①の `launchctl print gui/$(id -u)/com.voicedock.ingest \| head -5`、[C-1]（③ の前後）、`grep -c coexistence_blocked`、⑤ の診断の DR-13 の行、⑦ の [C-1] |
| 落とし穴 | **voicedock を実際に動かさない**（実機に触れる別のプログラムを走らせない）。`/usr/bin/true` を `RunAtLoad false` で登録するだけ。**必ず ⑥ で後始末する** |

### 6.14 E2E-16 — リムーバブルボリュームの許可を拒否

| | |
|---|---|
| 題 | `リムーバブルボリュームの許可を拒否` |
| 前提 | 削除 OFF。**この試験で TCC の許可が 1 回失われる**（最後に許可し直す） |
| 手順 | ① `tccutil reset SystemPolicyRemovableVolumes <BUNDLE_ID>` ② アプリを再起動する ③ 挿す ④ 出たダイアログで**「許可しない」**を押す ⑤ [C-2]・[C-10]・診断の DR-11 ⑥ `tccutil reset SystemPolicyRemovableVolumes <BUNDLE_ID>` ⑦ アプリを再起動して挿し、**「許可」**を押す ⑧ 完走を待って [C-1]・[C-3] |
| 期待 | ④ 取り込まない。`volume_skipped reason=not_listable`（WARNING）。要対応に「デバイスを読み取れません」と「システム設定を開く」ボタンが出る。⑤ DR-11 が ✗ で、案内の文言が「システム設定 → プライバシーとセキュリティ → ファイルとフォルダ → VoiceDock → リムーバブルボリューム」。⑦ 許可すると普通に取り込む |
| 記録 | ④ のダイアログの文言（`NSRemovableVolumesUsageDescription` の逐語が出ること）、[C-10] の要対応、DR-11 の行、⑧ の [C-1] |
| 落とし穴 | `tccutil reset` の後は**アプリを再起動しないとダイアログが出ない**。`<BUNDLE_ID>` は `identity.env` の値 |

### 6.15 E2E-18 — voicedock からの乗り換え

| | |
|---|---|
| 題 | `voicedock からの乗り換え` |
| 前提 | 削除 OFF。**voicedock が書いた Raw / Daily ノートがある Vault**（無ければ、voicedock の Raw ノートの frontmatter（`voicedock_recording_keys` を持つ）を手で 1 枚作る）。**voicedock の Helper が止まっている**（E2E-15 の後始末が済んでいる） |
| 手順 | ① `[C-9]` を取り、**voicedock のノートの一覧と mtime とサイズを控える** ② `shasum -a 256` を voicedock の Raw / Daily ノート全部に取る（`/tmp/e2e18-before.txt`） ③ アプリでその Vault を選ぶ ④ `[C-2]` で `imported_keys_added count=<n>` を見る ⑤ `sqlite3 "$VD_DB" "SELECT COUNT(*) FROM imported_keys;"` ⑥ **voicedock が処理済みの録音が載っているデバイス**を挿す ⑦ [C-1]・[C-3]・[C-9] ⑧ ② と同じ `shasum` を取って `diff` する |
| 期待 | ④ `imported_keys_added count=<n>` が出て、⑤ の件数が voicedock のノートに載っている partkey の数と一致。⑥ **`imported_keys` の録音はコピーされない**（`part_discovered` が出ない。[C-5] の inbox に入らない）。同じ日に新しく録った録音があれば、**` (2)` の付いたノート**に書かれる。⑧ **voicedock のノートが 1 バイトも変わらない**（`diff` が空） |
| 記録 | ④ の行、⑤ の件数、⑧ の `diff` の全文（空なら `（差分なし）`）、` (2)` のノートのパス |

## 7. 文書テスト

### `Tests/PolicyTests/RunbookTests.swift`（全文）

```swift
// docs/E2E.md が docs/SPEC.md の S9 と 1 対 1 で、書式が守られ、参照先が実在することの検査（PLAN §10.3 の「文書」。T-35）。
// voicedock tests/unit/test_runbook.py（#93・#55）と同じ考え: 手順の正本を git の中に置き、腐らないことを機械で守る。
import Foundation
import TestSupport
import Testing

/// `docs/E2E.md` の読み取り。**先に抽出だけを固定し（陽性・陰性対照）、その上で本体を検査する。**
struct Runbook: Sendable {
    /// 判定表の 1 行。
    struct Row: Equatable, Sendable {
        let id: String
        let title: String
        let deletion: String
        let verdict: String
        let record: String
    }

    /// シナリオの節。
    struct Section: Equatable, Sendable {
        let number: Int
        let id: String
        let title: String
        /// `####` の見出しの本文（出現順）。
        let subheadings: [String]
        /// `#### 判定` の直後の空でない行。
        let verdict: String
        /// `#### 記録` の中の空でないコードフェンスの数。
        let evidenceBlocks: Int
        /// 節の全文。
        let body: String
    }

    static let path = "docs/E2E.md"

    let document: MarkdownDocument

    static func load() throws -> Runbook { Runbook(document: try MarkdownDocument.load(path)) }

    /// 判定表（`## 2. 判定表` の中の、見出しの先頭が `#` の表）。
    func rows() throws -> [Row] {
        var found: [Row] = []
        for table in MarkdownDocument.tables(in: try document.section("2. 判定表")) where table.header.first == "#" {
            for cells in table.rows where cells.count == 5 && cells[0].hasPrefix("E2E-") {
                found.append(
                    Row(id: cells[0], title: cells[1], deletion: cells[2], verdict: cells[3], record: cells[4]))
            }
        }
        return found
    }

    /// シナリオの節（`### 3.<n> E2E-<nn> — <題>`）。
    func sections() -> [Section] {
        var found: [Section] = []
        var current: (number: Int, id: String, title: String, start: Int)?
        var inFence = false
        func close(_ end: Int) {
            guard let open = current else { return }
            let lines = Array(document.lines[open.start..<end])
            found.append(
                Section(
                    number: open.number, id: open.id, title: open.title,
                    subheadings: Self.subheadings(lines), verdict: Self.verdict(lines),
                    evidenceBlocks: Self.evidenceBlocks(lines), body: lines.joined(separator: "\n")))
            current = nil
        }
        for (index, line) in document.lines.enumerated() {
            if MarkdownDocument.isFence(line) {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if let head = Self.scenarioHeading(line) {
                close(index)
                current = (head.number, head.id, head.title, index + 1)
            } else if MarkdownDocument.headingText(line) != nil, Self.depth(line) <= 3 {
                close(index)
            }
        }
        close(document.lines.count)
        return found
    }

    static func depth(_ line: String) -> Int { line.prefix { $0 == "#" }.count }

    /// `### 3.<n> E2E-<nn> — <題>` を読む（フェンスの外だけで使う）。
    static func scenarioHeading(_ line: String) -> (number: Int, id: String, title: String)? {
        guard let text = MarkdownDocument.headingText(line), depth(line) == 3 else { return nil }
        let pattern = "^3\\.([0-9]+) (E2E-[0-9]+) — (.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
            let number = Range(match.range(at: 1), in: text), let id = Range(match.range(at: 2), in: text),
            let title = Range(match.range(at: 3), in: text), let n = Int(text[number])
        else { return nil }
        return (n, String(text[id]), String(text[title]))
    }

    static func subheadings(_ lines: [String]) -> [String] {
        var inFence = false
        var found: [String] = []
        for line in lines {
            if MarkdownDocument.isFence(line) {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if depth(line) == 4, let text = MarkdownDocument.headingText(line) { found.append(text) }
        }
        return found
    }

    static func verdict(_ lines: [String]) -> String {
        var seen = false
        var inFence = false
        for line in lines {
            if MarkdownDocument.isFence(line) {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if depth(line) == 4, MarkdownDocument.headingText(line) == "判定" {
                seen = true
                continue
            }
            if seen, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                return line.trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    static func evidenceBlocks(_ lines: [String]) -> Int {
        var inRecord = false
        var count = 0
        var inFence = false
        var bodyLines = 0
        for line in lines {
            if MarkdownDocument.isFence(line) {
                if inFence {
                    if inRecord, bodyLines > 0 { count += 1 }
                    bodyLines = 0
                }
                inFence.toggle()
                continue
            }
            if inFence {
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { bodyLines += 1 }
                continue
            }
            if depth(line) == 4, let text = MarkdownDocument.headingText(line) { inRecord = (text == "記録") }
        }
        return count
    }

    /// 本文が参照するリポジトリ内のパス（`scripts/x.sh`・`Vendor/x.sh`・`tools/x/y.py`・`docs/X.md`・`Tests/…`）。
    static func referencedPaths(_ text: String) -> Set<String> {
        let pattern = "(?:^|[\\s`(])((?:scripts|Vendor|tools|docs|Resources|Tests)/[A-Za-z0-9._/-]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        var found: Set<String> = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)) {
            if let range = Range(match.range(at: 1), in: text) {
                found.insert(String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,`)")))
            }
        }
        return found
    }

    /// 本文が挙げる `make <target>`。
    static func makeTargets(_ text: String) -> Set<String> {
        let pattern = "\\bmake ([a-z][a-z-]*)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var found: Set<String> = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)) {
            if let range = Range(match.range(at: 1), in: text) { found.insert(String(text[range])) }
        }
        return found
    }
}
```

テストの表（`@Suite("Runbook") struct RunbookTests`）:

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `theHeadingExtractionWorks()` | **陽性対照**: シナリオの見出しを拾える | 文字列を直に渡す | `"### 3.10 E2E-10 — 削除 ON で通し"` から `(10, "E2E-10", "削除 ON で通し")`。`"### 3.1 E2E-01 — 1 本を通しで"` から `(1, "E2E-01", "1 本を通しで")` |
| `theHeadingExtractionIgnoresOtherHeadings()` | **陰性対照**: 別の見出しは拾わない | 同上 | `"## 3. シナリオ"`・`"#### 手順"`・`"### 3.1 E2E-01 削除"`（`—` が無い）はすべて nil |
| `theVerdictExtractionWorks()` | **陽性対照**: 判定を拾える | 5 行の小さな節 | `#### 判定` の次の空行を飛ばして `✅ PASS` を返す。`判定` の節が無ければ空文字列 |
| `theEvidenceCountIgnoresEmptyFences()` | **陽性対照**: 空のフェンスは証拠と数えない | 小さな節 | 中身のあるフェンス 1 個で 1、空のフェンス 1 個で 0、`#### 手順` の中のフェンスは数えない |
| `theRunbookExists()` | docs/E2E.md が在る | — | `Runbook.load()` が投げない（**無ければ skip ではなく fail**） |
| `theVerdictTableMatchesTheSpec()` | E2E-nn の並びが SPEC の S9 と 1 対 1・同順 | `SpecDocument.load().ids(.e2e)` | `rows().map(\.id)` と完全一致（空でない） |
| `theDeletionColumnMatchesTheSpec(_:)` | 判定表の「削除」の列が SPEC と一致 | S9 の表の「削除」の列で parametrize | 各 ID で一致 |
| `everyVerdictStartsWithAMarker(_:)` | 判定が 4 つの記号のどれかで始まる | `rows()` で parametrize | `✅` / `✗` / `⬜` / `—` のどれかで始まる（空欄・散文を許さない） |
| `everyScenarioHasASection(_:)` | シナリオごとに手順の節が在る | S9 の ID で parametrize | 同じ ID の `Section` がちょうど 1 つ |
| `sectionNumberMatchesTheScenario(_:)` | 節の番号と E2E の番号が同じ | `sections()` で parametrize | `number == Int(id の数字部分)` |
| `sectionTitleMatchesTheTable(_:)` | 節の題が判定表の題と同じ | `sections()` で parametrize | 判定表の同じ ID の `title` と一致 |
| `sectionVerdictMatchesTheTable(_:)` | 節の判定と判定表の判定が一致 | 同上 | 一字一句一致（**2 か所に書いた判定がずれない**） |
| `everySectionHasTheFiveSubheadings(_:)` | 節は 前提・手順・期待・記録・判定 をこの順に持つ | `sections()` で parametrize | `subheadings == ["前提", "手順", "期待", "記録", "判定"]` |
| `aVerdictNeedsEvidence(_:)` | PASS / FAIL のシナリオは生の出力を持つ | `sections()` のうち判定が `✅` か `✗` で始まるもの | `evidenceBlocks >= 1`（**「通った」と書くだけを許さない**） |
| `everySectionSaysWhoRunsIt(_:)` | 実機の手順に【利用者が行う】が在る | `sections()` で parametrize | 本文に `【利用者が行う】` を含む |
| `referencedPathsExist(_:)` | 手順が指すリポジトリ内のファイルが実在 | `Runbook` 全文の `referencedPaths` で parametrize | `PackageRoot.file(_)` が在る（ディレクトリでもよい） |
| `referencedMakeTargetsExist(_:)` | 手順が挙げる make のターゲットが実在 | 全文の `makeTargets` で parametrize | `Makefile` に `^<name>:` の行が在る |
| `theRunbookNamesNoRemovedScript()` | 消えたスクリプト名を書いていない | 全文 | `helper/`・`docker compose`・`voicedock-ingest` を含まない（voicedock の手順の写し残し） |
| `theRunbookDoesNotPinTheSpecVersion()` | SPEC の版を直書きしない | 全文 | `計画書 v<数>.<数>` と `SPEC.md v<数>` に一致しない（版は SPEC 自身が名乗る） |
| `theRunbookNeverTellsYouToWriteToTheDevice()` | **安全**: デバイスへ書く手順が無い | 全文 | `/Volumes/` を含む行に `diskutil`・`hdiutil`・`rm `・`mv `・`touch `・`> ` が現れない |
| `theSafetyCheckWouldCatchIt()` | **陽性対照**: 上の検査が効く | 文字列を直に渡す | `rm -rf "/Volumes/$DEV/x"` を含む行で判定関数が偽、`find "/Volumes/$DEV" -type f` で真 |
| `theCommandTableIsUsed(_:)` | `## 1. 前提` の共通コマンドが使われている | **`## 1. 前提` の「共通のコマンド」の表の「名前」の列から `[C-<n>]` を読んで** parametrize（**件数を直書きしない**。T-42 が `[C-11]` 以降を足しても自動で対象になる） | その名前が `## 3.` より後の本文に 1 回以上現れる（**死んだ定義を残さない**） |
| `theCommandTableIsNotEmpty()` | **土台**: 共通のコマンドの表が空でない | 同上 | 5 つ以上あり、`[C-1]` と `[C-7]` を含む（parametrize の元が空になって全部緑になるのを防ぐ。TEST-01） |

- `SpecCoverage.activated` には `.e2e` を**足さない**。E2E のテストは `@Test` の表示名を持たない（実機の手順なので）。
  **E2E は「SPEC の ID の集合 = `docs/E2E.md` の判定表の ID の集合」で担保する**（`theVerdictTableMatchesTheSpec`）。T-05 の `testIDsExistInSpec` は E2E を対象に含んだままでよい（表示名に `E2E-` を書いたテストがあれば SPEC に在ることを確かめる）
- `MarkdownDocument.section("2. 判定表")` は T-04 の規則（見出しの本文が鍵で始まる最初の節。次の `^#{1,6} (?:[0-9A-Z]|付録)` まで）で切れる。`## 3. シナリオ` で止まる

## 8. 実機での実施【利用者が行う】

1. `make app` で `.app` を作り、パネルの「はじめに」を済ませる（Vault・Whisper モデル・LLM・ログイン項目）
2. §6 の 15 件を**番号順に**行う。1 件ごとに `#### 記録` へ生の出力を貼り、`#### 判定` と判定表の両方を同時に更新する
3. FAIL が出たら**そこで止める**。修正チケットを起票し、直してから**その 1 件をやり直す**（先へ進まない。PLAN §12.4）
4. E2E-06 は運用の中で確認してよい（`⬜ 未実施` のまま T-44 まで持ち越せる。**ただしゲートは開かない**）
5. すべて終えたら `make test` を回す（文書テストが判定表と節の整合を見る）

## 9. 破壊による証明

| # | 壊し方 | 落ちるべきテスト |
|---|---|---|
| 1 | `docs/E2E.md` の判定表から `E2E-09` の行を消す | `theVerdictTableMatchesTheSpec`、`everyScenarioHasASection` は通る（節は残る）ので**表だけが落ちる**ことを確かめる |
| 2 | `### 3.9 E2E-09 — …` の節を丸ごと消す | `everyScenarioHasASection("E2E-09")` |
| 3 | `### 3.9 E2E-09 — …` を `### 3.90 E2E-09 — …` にする | `sectionNumberMatchesTheScenario` |
| 4 | `E2E-05` の判定を `だいたい通った` にする | `everyVerdictStartsWithAMarker("E2E-05")`、`sectionVerdictMatchesTheTable` |
| 5 | `E2E-05` の判定表の判定だけ `✗ FAIL` にする（節は `✅ PASS` のまま） | `sectionVerdictMatchesTheTable` |
| 6 | `E2E-07` の `#### 記録` のフェンスを空にする | `aVerdictNeedsEvidence("E2E-07")` |
| 7 | `E2E-07` の `#### 期待` の見出しを消す | `everySectionHasTheFiveSubheadings` |
| 8 | `E2E-12` の手順から `【利用者が行う】` を消す | `everySectionSaysWhoRunsIt("E2E-12")` |
| 9 | 手順に `scripts/make-image.sh`（存在しない）を書く | `referencedPathsExist("scripts/make-image.sh")` |
| 10 | 手順に `make e2e` と書く | `referencedMakeTargetsExist("e2e")` |
| 11 | 手順に `rm -f "/Volumes/$DEV/TX00_MIC001_20260101_000000_orig.wav"` を書く | `theRunbookNeverTellsYouToWriteToTheDevice` |
| 12 | 手順に `docker compose exec voicedock voicedock status` を書く | `theRunbookNamesNoRemovedScript` |
| 13 | 前書きに `計画書 v1.1 に従う` と書く | `theRunbookDoesNotPinTheSpecVersion` |
| 14 | `## 1. 前提` の表から `[C-7]` の行を消す | `theCommandTableIsNotEmpty` |
| 14b | `### 3.2 E2E-02` の本文から `[C-7]` の参照を全部消す | `theCommandTableIsUsed("[C-7]")` |
| 15 | `Runbook.scenarioHeading` の正規表現の `—` を ` ` にする | `theHeadingExtractionIgnoresOtherHeadings` |
| 16 | `Runbook.evidenceBlocks` を「フェンスの数」に変える（空も数える） | `theEvidenceCountIgnoresEmptyFences` |

## 10. 受け入れ条件

- [ ] `docs/E2E.md` が §5 の書式どおりで、18 件の判定表と 18 件の節（うち 3 件は T-42 の骨組み）が在る
- [ ] `Tests/PolicyTests/RunbookTests.swift` の全テストが通り、**陽性対照 4 本**（`theHeadingExtractionWorks`・`theVerdictExtractionWorks`・`theEvidenceCountIgnoresEmptyFences`・`theSafetyCheckWouldCatchIt`）が在る
- [ ] 【利用者が行う】E2E-01〜05・07〜09・12〜16・18 の 14 件が `✅ PASS`（E2E-06 は `⬜ 未実施`（運用の中で確認）でもよい）
- [ ] 各節の `#### 記録` に**生の出力**が貼ってある（要約だけの節が 1 つも無い）
- [ ] E2E-02 の `diff`（デバイスのサイズと mtime）と E2E-18 の `shasum` の `diff` が**空**であることが記録に在る
- [ ] E2E-15 の後始末（`launchctl bootout` と plist の削除）を行い、その出力が記録に在る
- [ ] E2E-16 の後で TCC の許可が元に戻っている（診断の DR-11 が ✓）
- [ ] 削除 OFF の 15 件で**元音声が 1 本も消えていない**（[C-7] の総ファイル数が試験の前後で同じ）
- [ ] 破壊による証明の結果が PR 本文にある

## 11. SPEC の変更

なし（`S9` は PLAN 付録 B.3 の写しのまま。`docs/E2E.md` が SPEC に合わせる側）。

## 12. マージ後にやること

- T-42 が `docs/E2E.md` に `### 3.10` / `### 3.11` / `### 3.17` の中身と `## 4. 削除のゲート` / `## 5. 三重ロックを外して 1 日` を足す（本チケットのテストはそのまま効く）
- T-43 の README は `docs/E2E.md` を指す。**件数を README に直書きしない**（SPEC の `S9` から数える）
- T-44 は E2E-06 の記録が済んでいることをリリースの条件にする

## 13. API 地図への変更提案

1. §14（テスト）の `PolicyTests` の「主な中身」に **「文書テスト（`RunbookTests`（T-35）・`ReadmeTests`（T-43））」**を明記する（現在は「PT・SPEC 同期・文書テスト」とだけ書いてある）
2. §15 に `Runbook`（`Tests/PolicyTests/RunbookTests.swift` の中の `struct`）は載せない。**TestSupport には置かない**（`docs/E2E.md` を読むのは PolicyTests だけ）。T-42 は同じ型に extension を足さず、テストを足すだけにする
3. PLAN 付録 B.3 の判定の記号のうち `✗ FAIL` は U+2717。**`❌` や `×` と混ぜない**ことを PLAN に明記したい（判定の書式を機械で見るため、記号がぶれると `everyVerdictStartsWithAMarker` が落ちる）
4. PLAN 付録 B.3 の E2E-13〜E2E-18 には「削除」の列が `OFF` とだけ書かれているが、E2E-15 は**共存ガードで取り込み自体が止まる**シナリオなので、削除の可否を問わない。表の意味を変えずに済むため提案は「注記だけ」（`— 対象外` でもよい旨）
