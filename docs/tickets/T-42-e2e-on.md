# T-42 実機 E2E（削除 ON）と削除のゲート

| 項目 | 値 |
|---|---|
| ID | T-42 |
| 題 | 削除 ON の E2E-10・11・17、E2E-01〜09 の再実行、削除のゲート（PLAN §12.4）、三重ロックを外して 1 日 |
| Phase | 8 |
| 前提 | T-36（ロックの評価）、T-37（reaper）、T-38（要求・回収）、T-39（根拠 B）、T-40（有効化・無効化）、T-41（後追い）、T-35（`docs/E2E.md` の書式と文書テスト）、T-34（`make app` / `make release`） |
| 見積もり | `docs/E2E.md` への追記 約 400 行（文書）＋ `Tests/PolicyTests/RunbookGateTests.swift` 約 150 行 |

## 1. 目的

削除を**実際に有効にして**実機で 3 件（E2E-10・11・17）を通し、削除 OFF で通した 9 件（E2E-01〜09）を**削除 ON でもう一度**通す。
PLAN §12.4 の削除のゲート（5 条件。5 番目「削除 ON で E2E-01〜09 を再実行」は PLAN に反映済み）の判定を `docs/E2E.md` に記録し、**ゲートが開いたことを機械で確かめられる形にする**。

> voicedock では E2E が揃う前に削除を有効にし、**単体テストが全部緑のまま実機で 5 件の欠陥**（#151 / #152 / #154 / #156 ほか）が見つかった。
> 「三重ロックを全部外して 1 日流す」でしか見つからない欠陥がある（PLAN §12.4 の 4）。

## 2. 参照

- PLAN §12.4（削除のゲート。**緩めない**）、付録 B.3（E2E-10・11・17）、§13（検証の段。1 日運用）、§12.1（リリースと削除の有効化を分ける）
- PLAN §8.9.1（削除の必要十分条件）、§8.9.2（三重ロック・`DeletionReadiness` / `DeviceWritability`）、§8.9.3（ロック 2-A）、§8.9.5〜§8.9.7（要求・回収・期限切れ）、§8.9.8（有効化・無効化・常時表示）、§8.9.9（後追い）、付録 B.1（ND）、付録 B.2（RV）
- 先行チケット: T-35（`docs/E2E.md` の書式・`RunbookTests`）、T-36（`LockEvaluator`）、T-38（`RequestWriter`・`ResultCollector`）、T-40（`DeletionEnabler`）、T-41（`BacklogPlanner`）、T-37（`reaper.log` の行）
- 移植メモ `docs/porting-notes/V6-doctor-ci-e2e-docs.md` §9.2（E2E-10 / E2E-11 の要点と、そこで見つかった欠陥）
- voicedock@d3d595e `docs/E2E.md` §3.10・§3.11

## 3. 安全の規則（T-35 と同じ。ここでは実際に録音が消える）

- **実機に触れる手順はすべて `【利用者が行う】`。**エージェントは実行しない
- **この Phase では実機の録音が本当に消える。**消えてよいのは「この試験のために新しく録った録音」と「すでに Raw ノートで確認済みの録音」だけ。
  試験を始める前に **[C-7] の一覧を保存し、消えてよいファイルの範囲を利用者が明示的に決める**
- **`diskutil` を手で打たない。**読み取り専用への再マウントはアプリ（IngestService）が行う
- reaper を**手で起動しない**（ND-40 の確認を除く。その確認は「何も消えないこと」を見るもの）
- 削除 ON の試験は、`make app`（Apple Development 署名）の `.app` でも `make release`（Developer ID 署名・公証）の `.app` でも行える。`ReaperSignature.requirement`（PLAN §8.9.3）は
  識別子と Team ID（`certificate leaf[subject.OU]`）で束縛しており、証明書の種類は問わない（T-34 で確かめた）。**ad-hoc 署名（`--sign -`）の `.app` では `.disabled(reaper_invalid)` になり、この Phase の試験が全部空振りする**
- **退避は必須**: E2E-10 の手順 1（削除 OFF で読み取り専用の間）に `ditto "/Volumes/$DEV" "$HOME/VoiceDockE2E/device-backup"` を行い、`find … | wc -l` で件数を照合して記録に入れる
- **有効化の前に、削除の段で止まっている Session（`SAVED`・`SOURCE_DELETING`・`SOURCE_DELETE_PENDING`・`CLEANUP`）が 0 行、`RAW_SAVED` の Part が 0 件であることを確かめる**（残っていると有効化の直後にその元音声が消えうる）
- **止め方**（`docs/E2E.md` §3.10 と §6 の冒頭に置く）: 想定外のファイルが消えたら ① 直ちに「無効にする」 ② Finder でデバイスを取り出す ③ その時点の [C-7]・[C-6]・[C-12] を取る ④ `✗ FAIL`
- **削除 ON の間は、抜く前に Finder で取り出す**（E2E-10 の 4 と 9、E2E-11、R-05、§5、E2E-17 の後の挿し直し）。急に抜くこと自体が試験である R-02・R-03 は例外で、退避済み・抜く直前の `queue/delete` が空・抜いた後に `device-all-before-*.txt` と `comm -23` で照合・修復や初期化を求められたら中断（利用者が判断）の手順を踏み、FAT が壊れて録音を失う危険を冒頭に書く。R-02・R-03 は必須（利用者の決定。任意にしない）
- **根拠 B（R-07）はデバイスに在る `SKIPPED` を全部対象にする。**押す前に `SELECT partkey, source_path, error_code FROM recordings WHERE status='SKIPPED' AND source_deleted_at IS NULL` を取り、消える範囲を利用者が確かめる。過去の無音・重複も消えることを太字で書く
- **文書テストの安全の検査を強める**: T-35 の `RunbookTests.isSafeForTheDevice` に、`ditto`・`cp`・`rsync`・`tee` の**最後の引数**が `/Volumes/` を含む形（デバイスへ写す向き）を拒む検査 `copiesIntoTheDevice` を足す。`/Volumes/` から写す向き（退避の `ditto`、一覧の `tee "$HOME/…"`）は通す。T-35 のファイル（持ち主は T-35 のまま）を本チケットの PR で直す（§13 の 2）

## 4. 作るもの

| パス | 内容 |
|---|---|
| `docs/E2E.md` | `### 3.10` / `### 3.11` / `### 3.17` の中身（T-35 の骨組みを置き換える）、`## 4. 削除のゲート`、`## 5. 三重ロックを全部外して 1 日`、`## 6. 削除 ON での E2E-01〜09 の再実行` |
| `Tests/PolicyTests/RunbookGateTests.swift` | 下記 §8 の全文 |

`docs/E2E.md` の `## 0` 〜 `## 3` の書式は T-35 のまま。**判定表の E2E-10 / 11 / 17 の判定も同じ PR で更新する**（`sectionVerdictMatchesTheTable` が落ちる）。

表に無いファイル（T-35 の文書テスト・PLAN・SPEC・`docs/E2E.md` の `## 0` と `## 1` の行）も同じ PR で直す。持ち主は変わらない（§11 の直前の「同じ PR で直すもの」）。

## 5. 削除 ON の 3 件

### 5.1 共通のコマンド（`## 1. 前提` の表に追記する）

| 名前 | コマンド |
|---|---|
| `[C-11]` ロックの表示 | パネルの「元音声の削除」の 3 行（`ロック 1  : …` / `ロック 2-A: …` / `ロック 2-B: …`）を**そのまま書き写す** |
| `[C-12]` reaper のログ | `tail -n 100 "$VD_HOME/logs/reaper.log"` |
| `[C-13]` 削除の結果 | `sqlite3 -header -column "$VD_DB" "SELECT partkey, status, delete_request_id, source_deleted_at FROM recordings WHERE source_deleted_at IS NOT NULL OR delete_request_id IS NOT NULL ORDER BY started_at;"` |
| `[C-14]` 削除のログ | `grep -E 'delete_requested\|source_deleted\|source_delete_skipped\|source_delete_pending\|reaper_run\|reaper_failed\|deletion_enabled\|deletion_disabled' "$VD_HOME/logs/app.log"` |
| `[C-15]` デバイスの空き容量【利用者が行う】 | `df -h "/Volumes/$DEV"` |
| `[C-16]` reaper の導入状態 | `ls -l@ "$VD_HOME/bin/" ; cat "$VD_HOME/bin/reaper.conf"` |

`[C-11]`〜`[C-16]` も T-35 の `theCommandTableIsUsed` の対象になる（定義したら使う）。

### 5.2 E2E-10 — 削除 ON で通し

| | |
|---|---|
| 題 | `削除 ON で通し` |
| 削除 | ON |
| 前提 | **`make app` か `make release` の `.app`**（ad-hoc 署名でないもの。`codesign -dvvv` で reaper の `Identifier=` と `TeamIdentifier=` を確かめる）。削除 OFF の 13 件が PASS 済み。デバイスに未処理の録音が無い。**無音の録音 1 本**と普通の録音 2 本を**有効化の後に**新しく録る。§3 の「止め方」を冒頭に置く |
| 手順 | ① 挿して [C-8] に `read-only` が出たら [C-7]・[C-15]・[C-11]・[C-16]・[C-1] を取る（前。削除 OFF なので読み取り専用）。続けて全ファイルの一覧（`device-all-before-on.txt`）、**退避の `ditto`（必須）と件数の照合**、削除の段で止まっている Session のクエリ（0 行）と `RAW_SAVED` の Part の数（0）。0 でなければ有効化しない<br>② パネルの「元音声の削除」で有効化する。**事前確認の 2 文と診断の要約、赤い「有効にする」を 3 秒押し続けるところ**を記録する。クリック 1 回と途中で離した長押しでは通らないことも 1 回ずつ試す（F-65）<br>③ 直ちに [C-11]・[C-16]・[C-14] を取る（`deletion_enabled` が出ている。注意書き「読み書きできるようになるのはデバイスを挿し直した後です」を書き写す。デバイスが挿さっているときだけ出る）<br>④ Finder で取り出してから抜き、3 本を新しく録る<br>⑤ 挿す（**有効化してから初めての接続**）。[C-8] で `read-only` が**無い**ことを確かめ、直ちに [C-7]・[C-15]（前）<br>⑥ 完走を待ち、[C-1] の前に 1〜2 分待つ（削除の評価のバックオフ 60 秒）<br>⑦ [C-1]・[C-13]・[C-14]・[C-12]・[C-6]・[C-7]・[C-15]・[C-9]・[C-11] と無音の Part の行を取る（後） |
| 期待 | ③ `ロック 1  : アプリ=有効, reaper.conf=有効`、`ロック 2-A: 削除モジュール=導入済み（署名 OK, 版 <VERSION>）`、`ロック 2-B: 設定=rw, <デバイス>=読み取り専用（観測）`（挿し直す前）<br>⑤ 挿し直した後は観測が `読み書き可能（観測）`<br>⑦ **Raw ノートの検証を通った Part の元音声だけが消える**（[C-7] の前後の差が、その Part のファイルだけ）。`delete_requested` → `reaper_run exit=0` → `source_deleted` の順にログが出る。`queue/delete` と `queue/result` が**空**に戻る（[C-6]）。`recordings.source_deleted_at` が入る（[C-13]）。**空き容量が戻る**（[C-15] の前後）。**無音の Part は消えない**（`SKIPPED` のまま `delete_request_id` も `source_deleted_at` も空。根拠 B は既定 false なので `SkippedSettler` は何も読まずに 0 を返し、**ログも出さない**）。Daily / Raw ノートは削除 OFF のときと同じ形 |
| 記録 | ② の事前確認の文言と、クリック 1 回・途中で離した長押しで何も変わらなかったこと（[C-16]）、③ と ⑦ の [C-11]、[C-7] の前後の `diff`（**消えたファイルだけが差分**）、[C-15] の前後、[C-13]、[C-14]、[C-12]、[C-6] |
| 落とし穴 | **有効化の直後、挿し直す前のデバイスは観測が `readOnly` なので削除されない**（`source_delete_skipped reason=device_readonly`）。これは正しい動き。消し損ねた分は E2E-11 の「過去分を削除対象にする」で拾う |

追加で必ず行う 3 つの確認（**何も消えないことの確認**。ND-40 / RV-00 の実機での裏取り。**Finder でデバイスを取り出してから抜き、`queue/delete` が空のときに**行う）:

| # | 手順【利用者が行う】 | 期待 |
|---|---|---|
| 10-a | `"<VoiceDock.app のパス>/Contents/Helpers/voicedock-reaper" --home "$VD_HOME"` を手で実行する | **終了コード 3**、標準出力も `reaper.log` も**何も書かれない**、`queue/delete` が変わらない（RV-00。バンドル内から起動しても動かない） |
| 10-b | `"$VD_HOME/bin/voicedock-reaper" --version` を手で実行する | `VERSION` と同じ 1 行。**要求は処理されない**（`--version` は RV-00 より前に処理して終わる） |
| 10-c | `"$VD_HOME/bin/voicedock-reaper" --home "$VD_HOME"` を**手で**実行する（`queue/delete` が空で、デバイスを抜いてあるときに限る） | 終了コード 0（4 なら `reaper_busy`。少し待ってもう一度）。何も消えない（要求が無い）。`reaper.log` に `reaper_started` と `reaper_completed requests=0`。要求が無いと reaper はデバイスを開かないので、voicedock で見えた **TCC の差**（ターミナルから直に叩くと `Operation not permitted`）は**この確認では現れない**。要求がある状態・デバイスが挿さった状態で手で叩かない |

### 5.3 E2E-11 — 過去分の削除・手動で消した分の完了

| | |
|---|---|
| 題 | `過去分の削除・手動で消した分の完了` |
| 削除 | ON |
| 前提 | E2E-10 が PASS。**削除 OFF の期間に処理した Part が残っている**（E2E-01〜09 で処理したもの）。E2E-10 の退避が済んでいる。**この試験では以前の録音も消える**（下準備で取り込んだものを含む）。**実機で確かめるのは前半（過去分）だけ**（PLAN 付録 B.3・F-63。利用者の決定）。後半（手動で消した分）は T-41 の `BacklogPlannerTests` の resolveAbsent 系の単体テストで代える |
| 手順 | ① [C-1]・[C-7]・[C-13] と「対象になりうる Part の一覧」（COMPLETED の Session の COMPLETED / SOURCE_DELETE_PENDING の Part で、`source_deleted_at` と `delete_request_id` が空のもの）を取る（前）<br>② パネルの「詳細・診断 → 過去分を削除対象にする」を押す。**プレビュー（件数と、対象外の件数と理由）を書き写す**。消えてよい範囲を超えていたら「やめる」<br>③ 「削除要求を書く（n 件）」を押して実行する<br>④ 完走を待ち、1〜2 分おいて [C-1]・[C-7]・[C-13]・[C-14]・[C-12]・[C-6]<br>⑤ `SOURCE_DELETE_PENDING` の Part を `sqlite3` で調べて記録する（0 行でよい） |
| 期待 | ② 対象は「COMPLETED の Session の Part で、`canDeleteSource` が真のもの」。プレビューは `削除要求を書く対象: n 件`、対象外は `・削除済み: k 件`（`already_deleted`）/ `・削除の条件を満たさない: k 件`（`not_deletable`）。**削除 OFF の期間の Part も、Raw ノートの検証を経ていれば対象になる**（voicedock では Raw 検証を経ていないため `--backlog` が 0 件だったが、本アプリは Raw ノートの保存・検証を削除 OFF でも行うので対象になる）<br>④ 対象の元音声だけが消え（どれも前提の一覧に在る）、`source_deleted_at` が入る<br>⑤ 行があれば、その Part ごとに `source_delete_pending recording_key=… reason=…` が在る。後半の期待（`SOURCE_DELETE_PENDING` → `SOURCE_DELETING`（detail `resolve_absent`）→ `COMPLETED`（detail `already_absent`）、`source_delete_skipped reason=already_absent`、`source_deleted_at` は入らない）は T-41 の単体テストが持つ |
| 記録 | ② のプレビューの全文、③ の 1 行、「対象になりうる Part の一覧」、[C-1]・[C-7]・[C-13] の前後、[C-14]、[C-12]、[C-6]、⑤ の出力。**運用中に `source_delete_pending` が出たら**（`reason=` は RV の理由語・`no_result`・`still_in_inventory`・`queue_write_failed`。`queue_write_failed` は状態を変えない）、その行と ⑤ の出力と [C-4] を日時つきで追記する。デバイスに無いことを確かめられたら「手動で消した分を完了にする」のプレビューと実行の 1 行も追記する（そのために録音を手で消さない） |
| 落とし穴 | ② のプレビューが 0 件なら**この試験は空振り**（TEST-20）。0 件なら削除 OFF で処理した Part を先に用意する。**「過去分」は 1 件ずつ選べず、§1 の下準備で取り込んだ以前の録音も対象になる**。「手動で消した分を完了にする」の対象は `SOURCE_DELETE_PENDING` の Part だけ（PLAN §8.9.9）で、それは reaper の拒否・期限切れ（`no_result`）・`still_in_inventory` でしか生じず手の操作で確実には作れないので、実機では確かめない（F-63）。E2E-11 は前半が PASS なら `✅ PASS`。**録音を手で消さない**（`COMPLETED` は `source_deleted_at` が空のまま残り、`RAW_SAVED` は要求が書かれず Session が削除の段で待ち続ける。`RAW_SAVED` で詰まったら「無効にする」→ Session が `COMPLETED` になるのを [C-1] で確かめて（削除の評価のバックオフで最大 1 時間ほど）→ `ENABLE` で有効に戻す。この不具合の修正は別の PR） |

### 5.4 E2E-17 — 削除を無効化

| | |
|---|---|
| 題 | `削除を無効化` |
| 削除 | ON→OFF |
| 前提 | E2E-10 が PASS（削除が有効）。数分の録音を 1 本新しく録り、挿して読み書き可能でマウントさせる（無効化の後に処理が進む状態を作る） |
| 手順 | ① 挿して [C-7]、パネルが「文字起こし中」になったら [C-11]・[C-16]・[C-8]・[C-1] を取る（前。コピーの途中で押すと再マウントの段が失敗しうる）<br>② パネルの「元音声の削除」の「無効にする」で**無効化**する（**確認は求められない**。1 回のクリックで止まる）<br>③ **直ちに** [C-8]・[C-11]・[C-16]・[C-6]・[C-14] を取る<br>④ 未処理の録音の処理が終わるまで待つ<br>⑤ [C-1]・[C-7]・[C-13]・[C-14] |
| 期待 | ② 確認ダイアログも長押しも求められない（1 回のクリックで止まる。**止めたいときに止められる**）<br>③ **接続中のデバイスが直ちに読み取り専用へ再マウントされる**（[C-8] に `read-only` が出る。挿し直しを待たない）。`bin/voicedock-reaper` が**消えている**（[C-16]）。`bin/reaper.conf` が `DELETE_SOURCE_AUDIO=false`。`queue/delete` が**空**（要求が取り下げられた）。`deletion_disabled` が出る。ロックの表示が 3 つとも掛かった状態（`ロック 1  : アプリ=無効, reaper.conf=無効` / `ロック 2-A: 削除モジュール=未導入` / `ロック 2-B: 設定=ro, <デバイス>=読み取り専用（観測）`）。段が失敗すれば WARNING の `deletion_disabled reason=<段,…>` とパネルの `無効にできなかった段: …`（FAIL）<br>⑤ **以後 1 本も消えない**（[C-7] の件数が変わらない）。`source_delete_skipped reason=delete_source_audio_disabled` が出る。処理自体は最後まで進み `COMPLETED` になる |
| 記録 | ②（クリックだけで止まったこと）、③ の [C-8]・[C-11]・[C-16]・[C-6]、⑤ の [C-7] の前後と [C-14] |
| 落とし穴 | 無効化は「消す能力に近いものから先に止める」順（reaper.conf → reaper の削除 → config → 要求の取り下げ → 再マウント）。**途中の段が失敗しても残りを続ける**ので、③ の記録では**5 つとも**を確かめる |

## 6. `## 6. 削除 ON での E2E-01〜09 の再実行`

削除 OFF で PASS した 9 件を、**削除が有効なまま**もう一度通す。表は `docs/E2E.md` に次の形で置く（判定表とは別の表。ID は `R-01`〜`R-09`）:

```markdown
## 6. 削除 ON での E2E-01〜09 の再実行

削除 OFF で PASS した 9 件を、削除が有効なまま通す。**§3 の手順をそのまま使い、下の「削除 ON での違い」だけを足して見る。**

| # | 元 | 削除 ON での違い（これを確かめる） | 判定 | 記録 |
|---|---|---|---|---|
| R-01 | E2E-01 | Raw の検証を通った後に元音声が消える。Daily の保存は待たない | ✅ PASS | §6.1 |
…
```

| # | 元 | 削除 ON での違い（これを確かめる） |
|---|---|---|
| R-01 | E2E-01 | **Raw ノートの検証を通った直後**に元音声が消える（Daily の保存を待たない）。`RAW_SAVED` → `SOURCE_DELETING` → `COMPLETED` |
| R-02 | E2E-02 | **コピー中に抜いても 1 本も消えない**（コピー未完了の Part に要求を書かない）。再接続後の再コピー分も、Raw の検証を経てから消える。`[C-7]` の差分が「Raw の検証を通った分」と完全に一致 |
| R-03 | E2E-03 | 文字起こし中に抜くと、デバイスが `.absent` なので**待つ**（`sessions.delete_attempts` が増える）。挿し直すと消える。**未接続を「書き込み可能」と誤認しない** |
| R-04 | E2E-04 | Vault が使えない間は**1 本も消えない**（Raw ノートが書けない ＝ 根拠 A が成立しない）。戻したら消える |
| R-05 | E2E-05 | 抜き挿し 6 回で**要求が二重に書かれない**（`queue/delete` の request_id が重複しない。`reaper.log` に `reason=replayed` が出ない） |
| R-06 | E2E-06 | 1 日分でも要求の回収が追いつく（`queue/result` が溜まらない）。空き容量が**録音 1 日分ぶん**戻る |
| R-07 | E2E-07 | **無音の Part は消えない**（根拠 B は既定 false）。根拠 B を有効にすると消える。**有効にしたら必ず元に戻す** |
| R-08 | E2E-08 | **`WHISPER_FAILED` の Part は消えない**。他の Part は消える。再コピー → 完走の後に消える |
| R-09 | E2E-09 | 再オープンしても**すでに消えた Part を消し直さない**（`source_deleted_at` が在る Part に要求を書かない） |

- `## 6` の冒頭に §3 の「止め方」と、「E2E-17 の後なら 3 秒の長押しで有効に戻し、Finder で取り出して挿し直してから始める」「抜く前に Finder で取り出す（R-02・R-03 を除く）」を置く
- R-02・R-03 の `#### 前提` の冒頭に、§3 の急に抜く試験の安全の手順と「FAT が壊れて録音を失うおそれ」を置く（`device-all-before-r02.txt` / `-r03.txt`、`comm -23`）。R-05 は各回 Finder で取り出してから抜く
- R-07 は赤い「無音・重複も消す」を 3 秒押し続ける前に `SKIPPED` の一覧を取り、利用者が消える範囲を確かめる。期待は「一覧のうち `NO_SPEECH_DETECTED` / `DUPLICATE_CONTENT` でデバイスに今在る録音が消える（上限は一覧の本数）」
- 各行に `### 6.N R-0N — <題>` の節を置き、`#### 前提` / `#### 手順` / `#### 期待` / `#### 記録` / `#### 判定` の 5 つを持たせる（§3 と同じ形。文書テストが見る）
- `#### 手順` は「§3.N の手順を行う。加えて [C-7]・[C-13]・[C-14] を前後で取る」でよい（**手順を 2 回書かない**）
- R-06 は E2E-06 と同じく運用の中で確認してよい（`⬜ 未実施`）

## 7. `## 4. 削除のゲート` と `## 5. 三重ロックを全部外して 1 日`

### 7.1 `## 4. 削除のゲート（PLAN §12.4）`（形）

```markdown
## 4. 削除のゲート（PLAN §12.4）

**v1.0 を出す前にすべてを満たす。緩めない。**

| # | 条件 | 判定 | 記録 |
|---|---|---|---|
| G-1 | 付録 B.1 の ND が全件 PASS（アプリ層・reaper 層とも。正の対照を含む） | ✅ PASS | §4.1 |
| G-2 | 付録 B.3 の E2E が全件 PASS（E2E-06 は運用の中で確認してよいが、確認が済むまでゲートは開かない） | ✅ PASS | §2 |
| G-3 | `.diskImage` のテストが CI か手元で PASS し、その記録が PR にある | ✅ PASS | §4.3 |
| G-4 | 実機で「三重ロックを全部外して 1 日流す」を行った | ✅ PASS | §5 |
| G-5 | 削除 ON で E2E-01〜09 を再実行した（本書 §6） | ✅ PASS | §6 |

**ゲート: 閉**

### 4.1 G-1 の記録
（`make test-nd` の全出力を ```text で貼る）

### 4.3 G-3 の記録
（`make test-disk` の全出力を ```text で貼る）
```

- `G-1`〜`G-5` は PLAN §12.4 の 1〜5 と**同じ順・同じ意味**（5 番目は PLAN に反映済み）
- 最後の 1 行は **`**ゲート: 閉**` か `**ゲート: 開**` のどちらか**。散文にしない
- **`開` と書けるのは、判定表（§2）の 18 件が `✅` か `—`（`—` は取り下げた E2E-15・18）、§4 の G と §6 の R が**すべて `✅`** のときだけ**。G と R に `— 対象外` は許さない（R-02・R-03 も必須。利用者の決定）。これを `RunbookGateTests.theGateIsClosedUntilEverythingPasses` が機械で見る
- G-1 / G-3 は手元で走らせたコマンドの**全出力**を貼ってから `✅` にする（`make test-nd` / `make test-disk`）。「全部緑」とだけ書かない。実施前（`⬜ 未実施`）はフェンスが空でよい

### 7.2 `## 5. 三重ロックを全部外して 1 日`（形と中身）

```markdown
## 5. 三重ロックを全部外して 1 日（G-4 の記録）

削除を有効にしたまま、**普段どおりの 1 日**を流す。voicedock ではこれでしか見つからない欠陥が 5 件あった。

#### 前提
#### 手順
#### 期待
#### 記録
#### 判定
```

| | |
|---|---|
| 前提 | E2E-10・11・17 と §6 の再実行が PASS。削除を**有効に戻した**状態（E2E-17 で無効化したままにしない）。[C-11] が 3 つとも解除を示している |
| 手順【利用者が行う】 | ① 開始時刻と [C-1]・[C-7]・[C-15]・[C-9]・[C-16] を取る<br>② **普段どおり 1 日録って、帰宅して挿す**（試験用の操作を足さない。抜き挿し・スリープ・アプリの再起動が自然に起きるままにする）<br>③ 24 時間後に終了時刻と [C-1]・[C-7]・[C-15]・[C-9]・[C-13]・[C-14]・[C-12]・[C-6]・[C-10] を取る<br>④ **Daily / Raw ノートを目視で読む**（内容が壊れていないか。警告行の理由が妥当か）<br>⑤ `grep -c ERROR "$VD_HOME/logs/app.log"` と、`WARNING` の行を全部 |
| 期待 | Raw が 1 枚・Daily が 1 枚。`FAILED` が 0 件（あれば理由が妥当で、次の接続で再試行される）。**Raw の検証を通った録音だけが消え、空き容量が戻る**。`queue/delete`・`queue/result` が空に戻っている。`reaper.log` に `source_delete_rejected` と `request_rejected` が出ていない（`SOURCE_IDENTITY_MISMATCH` は結果ファイルの status で、`reaper.log` には出ない。出ていたら `reason=` の語を付録 B.2 で引いて調べる）。`ERROR` の行が 0（あれば 1 件ずつ説明を書く） |
| 記録 | ①③ の全部、④ の目視の所見（**何を見て問題ないと判断したか**を文で）、⑤ の全出力、その日に起きた異常（あれば） |
| 判定 | `✅ PASS` / `✗ FAIL` |

- **1 日は「24 時間」**（10 時間の録音 ＋ 処理の時間）。短縮しない
- 途中で FAIL の兆候が出たら、**その時点で削除を無効化して**（E2E-17 の手順）調査する。記録には中断したことと時刻を書く

## 8. 文書テスト

### `Tests/PolicyTests/RunbookGateTests.swift`（全文の構成）

T-35 の `Runbook` 型（`Tests/PolicyTests/RunbookTests.swift`）をそのまま使い、**ゲートと再実行の表だけ**を読む型を足す。

```swift
// docs/E2E.md の「削除のゲート」と「削除 ON での再実行」の検査（PLAN §12.4。T-42）。
// T-35 の Runbook 型を使う（同じターゲットなので import は要らない）。
import Foundation
import TestSupport
import Testing

/// `## 4. 削除のゲート` と `## 6. 削除 ON での E2E-01〜09 の再実行` の読み取り。
struct RunbookGate: Sendable {
    /// 表の 1 行（`| G-1 | 条件 | 判定 | 記録 |` と `| R-01 | 元 | 違い | 判定 | 記録 |`）。
    struct Row: Equatable, Sendable {
        let id: String
        let verdict: String
    }

    let runbook: Runbook

    static func load() throws -> RunbookGate { RunbookGate(runbook: try Runbook.load()) }

    /// ゲートの行（先頭の列が `G-<n>`、判定は 3 列目）。
    func gateRows() throws -> [Row] {
        var found: [Row] = []
        for table in MarkdownDocument.tables(in: try runbook.document.section("4. 削除のゲート")) {
            for cells in table.rows where cells.count == 4 && cells[0].hasPrefix("G-") {
                found.append(Row(id: cells[0], verdict: cells[2]))
            }
        }
        return found
    }

    /// 再実行の行（先頭の列が `R-<nn>`、判定は 4 列目）。
    func rerunRows() throws -> [Row] {
        var found: [Row] = []
        for table in MarkdownDocument.tables(in: try runbook.document.section("6. 削除 ON")) {
            for cells in table.rows where cells.count == 5 && cells[0].hasPrefix("R-") {
                found.append(Row(id: cells[0], verdict: cells[3]))
            }
        }
        return found
    }

    /// `**ゲート: 開**` / `**ゲート: 閉**` の 1 行（フェンスの外。無ければ nil）。
    func gateState() throws -> String? {
        var inFence = false
        for line in try runbook.document.section("4. 削除のゲート") {
            if MarkdownDocument.isFence(line) {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "**ゲート: 開**" || trimmed == "**ゲート: 閉**" { return trimmed }
        }
        return nil
    }

    /// 判定が「通った」と言えるか（`✅` か `—` で始まる）。
    static func passes(_ verdict: String) -> Bool { verdict.hasPrefix("✅") || verdict.hasPrefix("—") }
}
```

上の型には、次の 3 つも置く（下の表のテストが使う。いずれも `RunbookGate` の中。公開 API ではない）:

- `func gateConditions() throws -> [String]` — `gateRows()` と同じ行の「条件」の列（2 列目）
- `static func wasRun(_ verdict: String) -> Bool` — `✅` か `✗` で始まる（生の出力を要求する条件。T-35 の `aVerdictNeedsEvidence` と同じ考え）
- `static func nonEmptyFences(_ lines: [String]) -> Int` — 中身が空でないコードフェンスの数（`####` の見出しを問わない。`### 4.1` / `### 4.3` は `#### 記録` を持たないため `Runbook.evidenceBlocks` を使えない）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `thePassPredicateIsExact()` | **陽性対照**: 「通った」の判定が正確 | 文字列を直に渡す | `✅ PASS` は真、`— 対象外` は真、`⬜ 未実施` は偽、`✗ FAIL` は偽、`PASS`（記号なし）は偽、空文字列は偽 |
| `theGatePassPredicateIsExact()` | **陽性対照**: G と R の「通った」は ✅ だけ | 文字列を直に渡す（`gatePasses`） | `✅ PASS` は真。`— 対象外`・`⬜ 未実施`・`✗ FAIL`・`PASS`（記号なし）・空文字列は偽 |
| `theGateTableCoversPlanSection124()` | ゲートの 4 条件が PLAN §12.4 と対応する | `SpecDocument.plan().document.section("12.4")` の本文の番号付きの行（`^[0-9]+\. `） | PLAN の条件が 4 つ以上。ゲートの行が `G-1`〜`G-N`（N ≧ 4 かつ N ≧ PLAN の条件の数）で連番。`付録 B.1`・`付録 B.3`・`.diskImage`・`1 日`・`E2E-01〜09`（G-5）の 5 つの語が、それぞれ**どれかの行の条件の列**（`gateConditions()`）に現れる |
| `theGateHasAState()` | ゲートの開閉が 1 行で書いてある | `gateState()` | nil でない（**散文で書かない**） |
| `theGateIsClosedUntilEverythingPasses()` | ゲートを開けるのは全部通ってから | 判定表・G の表・R の表 | `gateState() == "**ゲート: 開**"` なら、§2 の 18 件が `passes`（`✅` か `—`）を、G の全行・R の全行が `gatePasses`（`✅` だけ）を**すべて**満たし、3 つの表がどれも空でない。満たさないものがあれば、その ID を並べて失敗させる |
| `everyGateVerdictStartsWithAMarker(_:)` | G の判定が 4 つの記号のどれかで始まる | `gateRows()` で parametrize | `✅` / `✗` / `⬜` / `—` のどれかで始まる |
| `everyRerunVerdictStartsWithAMarker(_:)` | R の判定が 4 つの記号のどれかで始まる | `rerunRows()` で parametrize | 同上 |
| `theRerunTableCoversOneToNine()` | 再実行の表が R-01〜R-09 の 9 行 | `rerunRows()` | `["R-01", …, "R-09"]` と完全一致 |
| `everyRerunHasASection(_:)` | 再実行のそれぞれに節が在る | `rerunRows()` で parametrize | `### 6.<n> R-0<n> — ` の見出しが在り、`前提`・`手順`・`期待`・`記録`・`判定` の 5 つの `####` を持つ |
| `theRerunSectionVerdictMatchesTheTable(_:)` | 節の判定と表の判定が一致 | 同上 | 一字一句一致 |
| `theOneDaySectionExists()` | 「三重ロックを全部外して 1 日」の節が在る | `## 5.` の節 | 見出しが在り、`前提`・`手順`・`期待`・`記録`・`判定` の 5 つの `####` を持ち、判定が記号で始まる |
| `theOneDaySectionHasEvidence()` | 1 日運用に生の出力が在る | 同上 | 判定が `✅` か `✗` で始まるなら、空でないコードフェンスが 1 つ以上 |
| `theGateRecordsAreRaw(_:)` | G-1 と G-3 の記録に生の出力が在る | `### 4.1` と `### 4.3` の節で parametrize | 対応する G の判定が `✅` か `✗` で始まるなら（`wasRun`）、その節が空でないコードフェンス（`nonEmptyFences`）を 1 つ以上持つ。`⬜ 未実施` の間は問わない（利用者が走らせる前に出力を捏造しない） |
| `theFenceCountIgnoresEmptyFences()` | **陽性対照**: 空のフェンスは生の出力と数えない | 行の配列を直に渡す | 中身のあるフェンスは 1、空行だけのフェンスは 0、空の配列は 0 |
| `theScenariosThatDeleteAreMarked()` | 削除 ON の 3 件が判定表で `ON` になっている | 判定表 | `E2E-10` と `E2E-11` の「削除」の列が `ON`、`E2E-17` が `ON→OFF`（SPEC の S9 と一致することは T-35 の `theDeletionColumnMatchesTheSpec` が見る） |

`RunbookGate` には `static func gatePasses(_ verdict: String) -> Bool { verdict.hasPrefix("✅") }` も置く（G と R の判定に使う）。

T-35 の `Tests/PolicyTests/RunbookTests.swift` に足すもの（§3）:

- `static let copyCommands: Set<String> = ["ditto", "cp", "rsync", "tee"]`、`static func commandSegments(_ line: String) -> [[String]]`（`|`・`;`・`&`・括弧・バッククォートで分け、空白で語に分ける。引用符の中は分けず、引用符は除く。`\|` は `|`）、`static func copiesIntoTheDevice(_ line: String) -> Bool`（区切りの先頭の語が `copyCommands` のどれかで、語が 2 つ以上あり、最後の語が `/Volumes/` を含む）。`isSafeForTheDevice` は `/Volumes/` を含む行でこれも偽であることを求める

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `theCopyDirectionIsChecked()` | **陽性対照**: デバイスへ写す向きを拒み、デバイスから写す向きは通す | 行を直に渡す | `ditto "/Volumes/$DEV" "$HOME/…"` は安全、`ditto "$HOME/…" "/Volumes/$DEV"`・`cp a.wav "/Volumes/$DEV/"`・`rsync -a x/ "/Volumes/$DEV/y"`・`… \| tee "/Volumes/$DEV/list.txt"` は危険、`find "/Volumes/$DEV" … \| sort \| tee "$HOME/a.txt"` は安全、空文字列は安全、`commandSegments("")` は空 |

- T-35 の全テスト（判定表と SPEC の 1 対 1、5 つの `####`、証拠のフェンス、`【利用者が行う】`、`/Volumes` に書く手順が無いこと）が、**足した 3 節と §6 の 9 節にもそのまま掛かる**
- `theGateIsClosedUntilEverythingPasses` が本チケットの中心。**「開」と書いた瞬間に、通っていない試験が 1 件でもあれば `make test` が落ちる**

## 9. 破壊による証明

| # | 壊し方 | 落ちるべきテスト |
|---|---|---|
| 1 | 判定表の `E2E-10` を `⬜ 未実施` に戻したまま `**ゲート: 開**` にする | `theGateIsClosedUntilEverythingPasses` |
| 2 | `G-4` の判定を `⬜ 未実施` にしたまま `**ゲート: 開**` にする | 同上 |
| 3 | `R-05` の判定を `✗ FAIL` にしたまま `**ゲート: 開**` にする | 同上 |
| 4 | `**ゲート: 閉**` の行を `ゲートはまだ開けていない` に書き換える | `theGateHasAState` |
| 5 | `G-3`（`.diskImage`）の行を消す | `theGateTableCoversPlanSection124` |
| 6 | `G-1` の判定を `だいたい通った` にする | `everyGateVerdictStartsWithAMarker("G-1")` |
| 7 | `G-1` の判定を `✅ PASS` にし、`### 4.1 G-1 の記録` のフェンスを空のままにする | `theGateRecordsAreRaw("4.1 G-1 の記録")` |
| 8 | `## 5.` の `#### 記録` を消す | `theOneDaySectionExists` |
| 9 | `## 6.` の表から `R-07` の行を消す | `theRerunTableCoversOneToNine` |
| 10 | `### 6.7 R-07 — …` の節を消す | `everyRerunHasASection("R-07")` |
| 11 | `### 3.17 E2E-17 — …` の `#### 記録` のフェンスを空にする（判定は `✅ PASS` のまま） | T-35 の `aVerdictNeedsEvidence("E2E-17")` |
| 12 | `### 3.10` の手順から `【利用者が行う】` を消す | T-35 の `everySectionSaysWhoRunsIt("E2E-10")` |
| 13 | `### 3.11` の手順に `diskutil unmount "/Volumes/$DEV"` を書く | T-35 の `theRunbookNeverTellsYouToWriteToTheDevice` |
| 14 | `RunbookGate.passes` を `verdict.contains("PASS")` に変える | `thePassPredicateIsExact`（`PASS`（記号なし）が真になり、`— 対象外` が偽になる） |
| 15 | 判定表・G・R・各節の判定をすべて `✅ PASS` にし（取り下げの 2 件は `—` のまま）、`R-02` だけを `— 対象外` にして `**ゲート: 開**` にする | `theGateIsClosedUntilEverythingPasses`（`R-02` を挙げる） |
| 16 | `RunbookGate.gatePasses` を `passes` と同じ（`✅` か `—`）にする | `theGatePassPredicateIsExact` |
| 17 | `docs/E2E.md` の退避の行の `ditto` の引数を逆にする（`ditto "$HOME/VoiceDockE2E/device-backup" "/Volumes/$DEV"`） | T-35 の `theRunbookNeverTellsYouToWriteToTheDevice` |
| 18 | `RunbookTests.copiesIntoTheDevice` を常に偽にする | T-35 の `theCopyDirectionIsChecked` |
| 19 | `## 4` の表から `G-5` の行を消す | `theGateTableCoversPlanSection124`（`E2E-01〜09` が無く、行数が PLAN の 5 条件より少ない） |

## 10. 受け入れ条件

- [ ] `docs/E2E.md` に `### 3.10` / `### 3.11` / `### 3.17` の中身、`## 4`・`## 5`・`## 6` が在り、T-35 と T-42 の全テストが通る
- [ ] 【利用者が行う】E2E-10・11・17 が `✅ PASS`（生の出力つき。E2E-11 は前半（過去分）。後半は T-41 の単体テストで代える。F-63）
- [ ] 【利用者が行う】E2E-10 の手順 1 の退避（`ditto`）と件数の照合、削除の段の 2 つのクエリが 0 であることが記録に在る
- [ ] 【利用者が行う】E2E-10 の 10-a・10-b・10-c の 3 つの確認が記録に在る（**10-a で終了コード 3 と「何も書かれない」を確かめた**）
- [ ] 【利用者が行う】§6 の R-01〜R-09 が `✅ PASS`（R-02・R-03 も必須。R-06 は運用の中で確認してよいが、`✅` になるまでゲートは開かない）
- [ ] 【利用者が行う】§5 の 1 日運用を実施し、`✅ PASS` と生の出力が在る
- [ ] `make test-nd` と `make test-disk` の**全出力**が `### 4.1` と `### 4.3` に貼ってあり、PR 本文にも在る
- [ ] E2E-10 の [C-7] の差分が、**消えるべき Part のファイルと完全に一致**している（1 本も余計に消えていない）
- [ ] `**ゲート: 開**` になっており、`theGateIsClosedUntilEverythingPasses` が通る（**E2E-06 と R-06 の確認が済むまで開けない**）
- [ ] 破壊による証明の結果が PR 本文にある
- [ ] 試験の後、削除を有効に戻すか無効にするかを利用者が**明示的に決めて**記録した

### 同じ PR で直すもの（表に無いファイル）

- `Tests/PolicyTests/RunbookTests.swift`（T-35）: §3 の `copiesIntoTheDevice` と陽性対照 1 本（§8 の末尾）
- `docs/PLAN.md` 付録 B.3 の E2E-11 の行の注記と付録 F の F-63、`docs/SPEC.md`（`python3 tools/spec/make-spec.py` で作り直す）: **利用者が承認した変更**（2026-09-22）。E2E-11 の後半を実機の試験から外す（§5.3）
- `docs/E2E.md` の `## 0` の「消えてよいのは」の行と `## 1` の「削除は OFF のまま行う」の行（E2E-11 で以前の録音も消えること、§5・§6 も削除 ON であること）

## 11. SPEC の変更

`S9` の E2E-11 の行（PLAN 付録 B.3 の写し）に「手動で消した分の完了は実機では確かめない（F-63）」の注記が入る。`python3 tools/spec/make-spec.py` で作り直した。ID・並び・「削除」の列は変わらない（T-35 の 1 対 1 は崩れない）。

## 12. マージ後にやること

- T-43 の README の「元音声の削除」の章は、E2E-10 / E2E-17 で確かめた**実際の文言**（事前確認・3 秒の長押し・無効化の即時再マウント）と一致させる
- T-44 は `docs/E2E.md` の `**ゲート: 開**` と E2E-06 の記録をリリースの条件にする

## 13. API 地図への変更提案

（2026-09-22 時点で 1・3・4・5 は反映済み。あわせて、利用者の承認を得て PLAN 付録 B.3 の E2E-11 に注記を足し、付録 F に F-63 を足した（本 PR）。1 は 00-api-map §14 の `PolicyTests` の行、3 は PLAN §12.4 の 5、4 は PLAN 付録 B.3 の E2E-11、5 は PLAN §8.9.8 の無効化の段にある。）

1. §14 の `PolicyTests` の「主な中身」に `RunbookGateTests`（T-42）を足す（`RunbookTests`（T-35）と同じ行でよい）
2. `Runbook` 型（T-35）は `PolicyTests` の中に置いたまま。T-42 は**同じターゲットに `RunbookGate` を足すだけ**で、`Runbook` を変更しない（変更が要るなら T-35 のファイルを同じ PR で直す）
3. **PLAN §12.4 に 5 番目の条件を足すことを提案する**: 「削除 ON で E2E-01〜09 を再実行する」。理由: 現在の §12.4 の 2 は「付録 B.3 の E2E が全件 PASS」だが、
   付録 B.3 の E2E-01〜09 は**削除 OFF での試験**なので、これだけでは「削除が有効なときに E2E-01〜09 の状況で余計な録音が消えないこと」を実機で一度も見ない。
   voicedock の #151 / #152 / #154 / #156 はいずれも「削除 ON にして初めて出た」欠陥だった
4. **PLAN 付録 B.3 の E2E-11 の記述を見直したい**: 「削除 OFF の期間の Part は Raw の検証を経ていれば対象」とあるが、voicedock では `--backlog` が 0 件だった理由が
   「削除 OFF の期間は Raw の検証をしていなかった」ことにある。本アプリは削除 OFF でも Raw ノートの保存・検証を行うので**対象は 0 件にならない**。
   PLAN の書き方はそのままで正しいが、移植メモ V6 §9.2 の「`--backlog` は 0 件が正しい」と読み比べると誤解を招くので、付録 B.3 に「voicedock と異なり 0 件にはならない」の注記を足したい
5. **PLAN §8.9.8 の無効化の「直ちに読み取り専用へ再マウント」の観測手段**が PLAN に無い。E2E-17 の ③ は `/sbin/mount` の出力で観測する。
   §8.9.8 に「観測は `statfs` の `MNT_RDONLY`（利用者は `/sbin/mount` で確認できる）」を足すことを提案する
