# T-42 実機 E2E（削除 ON）と削除のゲート

| 項目 | 値 |
|---|---|
| ID | T-42 |
| 題 | 削除 ON の E2E-10・11・17、E2E-01〜09 の再実行、削除のゲート（PLAN §12.4）、三重ロックを外して 1 日 |
| Phase | 8 |
| 前提 | T-36（ロックの評価）、T-37（reaper）、T-38（要求・回収）、T-39（根拠 B）、T-40（有効化・無効化）、T-41（後追い）、T-35（`docs/E2E.md` の書式と文書テスト）、T-34（`make release`） |
| 見積もり | `docs/E2E.md` への追記 約 400 行（文書）＋ `Tests/PolicyTests/RunbookGateTests.swift` 約 150 行 |

## 1. 目的

削除を**実際に有効にして**実機で 3 件（E2E-10・11・17）を通し、削除 OFF で通した 9 件（E2E-01〜09）を**削除 ON でもう一度**通す。
PLAN §12.4 の削除のゲート（4 条件。本チケットで 1 つ足して 5 条件）の判定を `docs/E2E.md` に記録し、**ゲートが開いたことを機械で確かめられる形にする**。

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
- 削除 ON の試験は **`make release` で Developer ID 署名・公証した `.app`** で行う（`ReaperSignature.requirement` が Developer ID を要求するため。
  Apple Development 署名では `.disabled(reaper_invalid)` になり、**この Phase の試験が全部空振りする**）

## 4. 作るもの

| パス | 内容 |
|---|---|
| `docs/E2E.md` | `### 3.10` / `### 3.11` / `### 3.17` の中身（T-35 の骨組みを置き換える）、`## 4. 削除のゲート`、`## 5. 三重ロックを全部外して 1 日`、`## 6. 削除 ON での E2E-01〜09 の再実行` |
| `Tests/PolicyTests/RunbookGateTests.swift` | 下記 §8 の全文 |

`docs/E2E.md` の `## 0` 〜 `## 3` の書式は T-35 のまま。**判定表の E2E-10 / 11 / 17 の判定も同じ PR で更新する**（`sectionVerdictMatchesTheTable` が落ちる）。

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
| 前提 | **`make release` の `.app`**。削除 OFF の 15 件が PASS 済み。**無音の録音 1 本**と普通の録音 2 本を新しく録る。[C-7]・[C-15] を保存する |
| 手順 | ① [C-7]・[C-15]・[C-11]・[C-16]・[C-1] を取る（前）<br>② パネルの「元音声の削除」で有効化する。**事前確認の文言と、入力欄に `ENABLE` を打つところ**を記録する。`y` や `enable`（小文字）では通らないことも 1 回試す<br>③ [C-11]・[C-16]・[C-14] を取る（`deletion_enabled` が出ている。**「挿し直した後に読み書きできる」旨の表示**を書き写す）<br>④ 挿す（**有効化してから初めての接続**）<br>⑤ [C-8] で**読み書き可能で**マウントされていることを確かめる<br>⑥ 完走を待つ<br>⑦ [C-1]・[C-13]・[C-14]・[C-12]・[C-6]・[C-7]・[C-15]・[C-9]・[C-11] を取る（後） |
| 期待 | ③ ロック 1 = アプリ有効・reaper.conf 有効、ロック 2-A = 導入済み（署名 OK・版が `VERSION` と一致）、ロック 2-B = 設定 rw・観測は**まだ読み取り専用**（挿し直す前）<br>⑤ 挿し直した後は観測が「読み書き可能」<br>⑦ **Raw ノートの検証を通った Part の元音声だけが消える**（[C-7] の前後の差が、その Part のファイルだけ）。`delete_requested` → `reaper_run exit=0` → `source_deleted` の順にログが出る。`queue/delete` と `queue/result` が**空**に戻る（[C-6]）。`recordings.source_deleted_at` が入る（[C-13]）。**空き容量が戻る**（[C-15] の前後）。**無音の Part は消えない**（`source_delete_skipped reason=…`。根拠 B は既定 false）。Daily / Raw ノートは削除 OFF のときと同じ形 |
| 記録 | ② の事前確認の文言と `ENABLE` 以外が弾かれた表示、③ と ⑦ の [C-11]、[C-7] の前後の `diff`（**消えたファイルだけが差分**）、[C-15] の前後、[C-13]、[C-14]、[C-12]、[C-6] |
| 落とし穴 | **有効化の直後、挿し直す前のデバイスは観測が `readOnly` なので削除されない**（`source_delete_skipped reason=device_readonly`）。これは正しい動き。消し損ねた分は E2E-11 の「過去分を削除対象にする」で拾う |

追加で必ず行う 2 つの確認（**何も消えないことの確認**。ND-40 / RV-00 の実機での裏取り）:

| # | 手順【利用者が行う】 | 期待 |
|---|---|---|
| 10-a | `"<VoiceDock.app のパス>/Contents/Helpers/voicedock-reaper" --home "$VD_HOME"` を手で実行する | **終了コード 3**、標準出力も `reaper.log` も**何も書かれない**、`queue/delete` が変わらない（RV-00。バンドル内から起動しても動かない） |
| 10-b | `"$VD_HOME/bin/voicedock-reaper" --version` を手で実行する | `VERSION` と同じ 1 行。**要求は処理されない**（`--version` は RV-00 より前に処理して終わる） |
| 10-c | `"$VD_HOME/bin/voicedock-reaper" --home "$VD_HOME"` を**手で**実行する（`queue/delete` が空のときに限る） | 終了コード 0。何も消えない（要求が無い）。**TCC の差**（voicedock ではターミナルから直に叩くと `Operation not permitted` だった）を記録する。要求がある状態で手で叩かない |

### 5.3 E2E-11 — 過去分の削除・手動で消した分の完了

| | |
|---|---|
| 題 | `過去分の削除・手動で消した分の完了` |
| 削除 | ON |
| 前提 | E2E-10 が PASS。**削除 OFF の期間に処理した Part が残っている**（E2E-01〜09 で処理したもの）。[C-7] を保存する |
| 手順 | ① [C-1]・[C-7]・[C-13] を取る（前）<br>② パネルの「詳細 → 過去分を削除対象にする」を押す。**プレビュー（件数と、対象外の件数と理由）を書き写す**<br>③ もう一度押して実行する<br>④ 完走を待って [C-1]・[C-7]・[C-13]・[C-14]・[C-12]<br>⑤ 【利用者が行う】**手で 1 本だけ**デバイスから録音を消す（Finder で削除。まだアプリに要求を書かせていない Part を選ぶ）。消す前に `stat -f '%z %m %N'` を取る<br>⑥ 挿し直して新しい snapshot を取らせる<br>⑦ 「手動で消した分を完了にする」のプレビューを書き写し、実行する<br>⑧ [C-1]・[C-13]・[C-14] |
| 期待 | ② 対象は「COMPLETED の Session の Part で、`canDeleteSource` が真のもの」。対象外には理由（`already_deleted` / `not_deletable`）と件数が出る。**削除 OFF の期間の Part も、Raw ノートの検証を経ていれば対象になる**（voicedock では Raw 検証を経ていないため `--backlog` が 0 件だったが、本アプリは Raw ノートの保存・検証を削除 OFF でも行うので対象になる）<br>④ 対象の元音声が消え、`source_deleted_at` が入る<br>⑦ 手で消した Part が `SOURCE_DELETE_PENDING` → `SOURCE_DELETING`（detail `resolve_absent`）→ `COMPLETED`（detail `already_absent`）。`source_delete_skipped reason=already_absent`。**`source_deleted_at` は入らない**（消したのはアプリではない） |
| 記録 | ② と ⑦ のプレビューの全文、[C-1]・[C-7]・[C-13] の前後、[C-14]、[C-4] の当該 Part の遷移 3 行 |
| 落とし穴 | ② のプレビューが 0 件なら**この試験は空振り**（TEST-20）。0 件なら削除 OFF で処理した Part を先に用意する。⑤ で消すのは**この試験用に録った 1 本**に限る |

### 5.4 E2E-17 — 削除を無効化

| | |
|---|---|
| 題 | `削除を無効化` |
| 削除 | ON→OFF |
| 前提 | E2E-10 が PASS（削除が有効で、デバイスが読み書き可能で接続中）。未処理の録音が 1 本以上ある（無効化の後に処理が進む状態を作る） |
| 手順 | ① [C-11]・[C-16]・[C-8]・[C-1] を取る（前）<br>② パネルの「元音声の削除」で**無効化**する（**確認は求められない**。1 回のクリックで止まる）<br>③ **直ちに** [C-8]・[C-11]・[C-16]・[C-6]・[C-14] を取る<br>④ 未処理の録音の処理が終わるまで待つ<br>⑤ [C-1]・[C-7]・[C-13]・[C-14] |
| 期待 | ② 確認ダイアログも入力欄も出ない（**止めたいときに止められる**）<br>③ **接続中のデバイスが直ちに読み取り専用へ再マウントされる**（[C-8] に `read-only` が出る。挿し直しを待たない）。`bin/voicedock-reaper` が**消えている**（[C-16]）。`bin/reaper.conf` が `DELETE_SOURCE_AUDIO=false`。`queue/delete` が**空**（要求が取り下げられた）。`deletion_disabled` が出る。ロックの表示が 3 つとも掛かった状態<br>⑤ **以後 1 本も消えない**（[C-7] の件数が変わらない）。`source_delete_skipped reason=delete_source_audio_disabled` が出る。処理自体は最後まで進み `COMPLETED` になる |
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
| R-03 | E2E-03 | 文字起こし中に抜くと、デバイスが `.absent` なので**待つ**（`delete_attempts` が増える）。挿し直すと消える。**未接続を「書き込み可能」と誤認しない** |
| R-04 | E2E-04 | Vault が使えない間は**1 本も消えない**（Raw ノートが書けない ＝ 根拠 A が成立しない）。戻したら消える |
| R-05 | E2E-05 | 抜き挿し 6 回で**要求が二重に書かれない**（`queue/delete` の request_id が重複しない。`reaper.log` に `replayed` が出ない） |
| R-06 | E2E-06 | 1 日分でも要求の回収が追いつく（`queue/result` が溜まらない）。空き容量が**録音 1 日分ぶん**戻る |
| R-07 | E2E-07 | **無音の Part は消えない**（根拠 B は既定 false）。根拠 B を有効にすると消える。**有効にしたら必ず元に戻す** |
| R-08 | E2E-08 | **`WHISPER_FAILED` の Part は消えない**。他の Part は消える。再コピー → 完走の後に消える |
| R-09 | E2E-09 | 再オープンしても**すでに消えた Part を消し直さない**（`source_deleted_at` が在る Part に要求を書かない） |

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

- `G-1`〜`G-4` は PLAN §12.4 の 1〜4 と**同じ順・同じ意味**。`G-5` は本チケットで足す条件（緩めず、強める方向。PLAN への追記を §11 で提案する）
- 最後の 1 行は **`**ゲート: 閉**` か `**ゲート: 開**` のどちらか**。散文にしない
- **`開` と書けるのは、判定表（§2）の 18 件と §4 の G と §6 の R がすべて `✅` か `—` のときだけ**。これを `RunbookGateTests.theGateIsClosedUntilEverythingPasses` が機械で見る
- G-1 / G-3 は手元で走らせたコマンドの**全出力**を貼る（`make test-nd` / `make test-disk`）。「全部緑」とだけ書かない

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
| 期待 | Raw が 1 枚・Daily が 1 枚。`FAILED` が 0 件（あれば理由が妥当で、次の接続で再試行される）。**Raw の検証を通った録音だけが消え、空き容量が戻る**。`queue/delete`・`queue/result` が空に戻っている。`reaper.log` に `SOURCE_IDENTITY_MISMATCH` の理由語が出ていない（出ていたらその理由を調べる）。`ERROR` の行が 0（あれば 1 件ずつ説明を書く） |
| 記録 | ①③ の全部、④ の目視の所見（**何を見て問題ないと判断したか**を文で）、⑤ の全出力、その日に起きた異常（あれば） |
| 判定 | `✅ PASS` / `✗ FAIL` |

- **1 日は「24 時間」**（16 時間の録音 ＋ 処理の時間）。短縮しない
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

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `thePassPredicateIsExact()` | **陽性対照**: 「通った」の判定が正確 | 文字列を直に渡す | `✅ PASS` は真、`— 対象外` は真、`⬜ 未実施` は偽、`✗ FAIL` は偽、`PASS`（記号なし）は偽、空文字列は偽 |
| `theGateTableCoversPlanSection124()` | ゲートの 4 条件が PLAN §12.4 と対応する | `SpecDocument.plan().document.section("12.4")` の本文 | ゲートの行が `G-1`〜`G-N`（N ≧ 4）で連番。`付録 B.1`・`付録 B.3`・`.diskImage`・`1 日` の 4 つの語が、それぞれ**どれかの行の条件の列**に現れる |
| `theGateHasAState()` | ゲートの開閉が 1 行で書いてある | `gateState()` | nil でない（**散文で書かない**） |
| `theGateIsClosedUntilEverythingPasses()` | ゲートを開けるのは全部通ってから | 判定表・G の表・R の表 | `gateState() == "**ゲート: 開**"` なら、§2 の 18 件・G の全行・R の全行の判定が**すべて** `passes` を満たす。満たさないものがあれば、その ID を並べて失敗させる |
| `everyGateVerdictStartsWithAMarker(_:)` | G の判定が 4 つの記号のどれかで始まる | `gateRows()` で parametrize | `✅` / `✗` / `⬜` / `—` のどれかで始まる |
| `everyRerunVerdictStartsWithAMarker(_:)` | R の判定が 4 つの記号のどれかで始まる | `rerunRows()` で parametrize | 同上 |
| `theRerunTableCoversOneToNine()` | 再実行の表が R-01〜R-09 の 9 行 | `rerunRows()` | `["R-01", …, "R-09"]` と完全一致 |
| `everyRerunHasASection(_:)` | 再実行のそれぞれに節が在る | `rerunRows()` で parametrize | `### 6.<n> R-0<n> — ` の見出しが在り、`前提`・`手順`・`期待`・`記録`・`判定` の 5 つの `####` を持つ |
| `theRerunSectionVerdictMatchesTheTable(_:)` | 節の判定と表の判定が一致 | 同上 | 一字一句一致 |
| `theOneDaySectionExists()` | 「三重ロックを全部外して 1 日」の節が在る | `## 5.` の節 | 見出しが在り、`前提`・`手順`・`期待`・`記録`・`判定` の 5 つの `####` を持ち、判定が記号で始まる |
| `theOneDaySectionHasEvidence()` | 1 日運用に生の出力が在る | 同上 | 判定が `✅` か `✗` で始まるなら、空でないコードフェンスが 1 つ以上 |
| `theGateRecordsAreRaw(_:)` | G-1 と G-3 の記録に生の出力が在る | `### 4.1` と `### 4.3` の節で parametrize | それぞれ空でないコードフェンスを 1 つ以上持つ |
| `theScenariosThatDeleteAreMarked()` | 削除 ON の 3 件が判定表で `ON` になっている | 判定表 | `E2E-10` と `E2E-11` の「削除」の列が `ON`、`E2E-17` が `ON→OFF`（SPEC の S9 と一致することは T-35 の `theDeletionColumnMatchesTheSpec` が見る） |

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
| 7 | `### 4.1 G-1 の記録` のフェンスを空にする | `theGateRecordsAreRaw` |
| 8 | `## 5.` の `#### 記録` を消す | `theOneDaySectionExists` |
| 9 | `## 6.` の表から `R-07` の行を消す | `theRerunTableCoversOneToNine` |
| 10 | `### 6.7 R-07 — …` の節を消す | `everyRerunHasASection("R-07")` |
| 11 | `### 3.17 E2E-17 — …` の `#### 記録` のフェンスを空にする（判定は `✅ PASS` のまま） | T-35 の `aVerdictNeedsEvidence("E2E-17")` |
| 12 | `### 3.10` の手順から `【利用者が行う】` を消す | T-35 の `everySectionSaysWhoRunsIt("E2E-10")` |
| 13 | `### 3.11` の手順に `diskutil unmount "/Volumes/$DEV"` を書く | T-35 の `theRunbookNeverTellsYouToWriteToTheDevice` |
| 14 | `RunbookGate.passes` を `verdict.contains("PASS")` に変える | `thePassPredicateIsExact`（`✗ FAIL` が真になる…ではなく、`PASS`（記号なし）が真になって落ちる） |

## 10. 受け入れ条件

- [ ] `docs/E2E.md` に `### 3.10` / `### 3.11` / `### 3.17` の中身、`## 4`・`## 5`・`## 6` が在り、T-35 と T-42 の全テストが通る
- [ ] 【利用者が行う】E2E-10・11・17 が `✅ PASS`（生の出力つき）
- [ ] 【利用者が行う】E2E-10 の 10-a・10-b・10-c の 3 つの確認が記録に在る（**10-a で終了コード 3 と「何も書かれない」を確かめた**）
- [ ] 【利用者が行う】§6 の R-01〜R-09 が `✅ PASS`（R-06 は `⬜ 未実施`（運用の中で確認）でもよい）
- [ ] 【利用者が行う】§5 の 1 日運用を実施し、`✅ PASS` と生の出力が在る
- [ ] `make test-nd` と `make test-disk` の**全出力**が `### 4.1` と `### 4.3` に貼ってあり、PR 本文にも在る
- [ ] E2E-10 の [C-7] の差分が、**消えるべき Part のファイルと完全に一致**している（1 本も余計に消えていない）
- [ ] `**ゲート: 開**` になっており、`theGateIsClosedUntilEverythingPasses` が通る（**E2E-06 と R-06 の確認が済むまで開けない**）
- [ ] 破壊による証明の結果が PR 本文にある
- [ ] 試験の後、削除を有効に戻すか無効にするかを利用者が**明示的に決めて**記録した

## 11. SPEC の変更

なし。ただし PLAN §12.4 への追記を §13 で提案する（`G-5`）。`docs/SPEC.md` の `S9` は変わらない。

## 12. マージ後にやること

- T-43 の README の「元音声の削除」の章は、E2E-10 / E2E-17 で確かめた**実際の文言**（事前確認・`ENABLE`・無効化の即時再マウント）と一致させる
- T-44 は `docs/E2E.md` の `**ゲート: 開**` と E2E-06 の記録をリリースの条件にする

## 13. API 地図への変更提案

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
