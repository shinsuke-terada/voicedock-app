# 進捗と再開の手順（2026-09-24 夜・話者分離の実装の後。**実装中**）

**この文書だけ読めば再開できる**ように書いてある。次のセッションはここから始める。

## 1. いまの状態

| 区分 | 数 |
|---|---|
| チケット（T-01〜T-51） | 51 本（T-46〜T-51 は話者分離。PLAN F-89） |
| マージ済み | **49 本**（T-46〜T-51 が加わった） |
| 取り下げ | 1 本（T-33。PLAN F-60） |
| 残り | 1 本（T-44 v1.0 リリース。未着手） |

`develop` の先頭は `36b2b80`（PR #169 のマージ。E2E 削除 OFF 10/16 本の記録）。話者分離は #153（計画）→ #160〜#165（実装）→ #166（後始末）→ #167（コードレビューの修正。F-90）でマージ済み。**2026-09-24 に利用者が実機の録音で確認し、issue #104 を閉じた**（`diarization_completed speakers=2 elapsed_s=4.5`）。**2026-09-25 未明、削除 ON の 13 本のうち 6 本（E2E-10・11・17、R-01・04・05）を実施・全件 PASS**（下の §2.6）。記録は PR 未作成（このセッションで出す）。

2026-09-23 に**全体コードレビュー**を行い、見つかった不具合を F-71〜F-78 の 8 本の PR と、残り（issue #118・#119）を F-79〜F-84 の 6 本の PR で直した（§4）。レビューの issue（#112〜#120・#124）はすべて閉じた。

| チケット | PR | チケット | PR | チケット | PR |
|---|---|---|---|---|---|
| T-01 | #2 | T-16 | #55 | T-31 | #76 |
| T-02 | #12 | T-17 | #39 | T-32 | #80 |
| T-03 | #6 | T-18 | #60 | T-33 | 取り下げ（#70 は閉じた） |
| T-04 | #16 | T-19 | #33 | T-34 | #78 |
| T-05 | #20 | T-20 | #37 | T-35 | #82 |
| T-06 | #8 | T-21 | #44 | T-36 | #84 |
| T-07 | #14 | T-22 | #62 | T-37 | #64 |
| T-08 | #22 | T-23 | #51 | T-38 | #86 |
| T-09 | #28 | T-24 | #68 | T-39 | #89 |
| T-10 | #24 | T-25 | #4 | T-40 | #91 |
| T-11 | #26 | T-26 | #35 | T-41 | #94 |
| T-12 | #30 | T-27 | #41 | T-42 | #96 |
| T-13 | #47 | T-28 | #49 | T-43 | #140 |
| T-14 | #53 | T-29 | #66 | T-44 | **未着手** |
| T-15 | #57 | T-30 | #73 | T-45 | #10 |

| 話者分離 | T-46 #160 | T-47 #161 | T-48 #163 | T-49 #165 | T-50 #162 | T-51 #164 |
|---|---|---|---|---|---|---|

T-35（削除 OFF）と T-42（削除 ON）は**手順書とテストがマージ済み**で、**実機での実施が残っている**。

## 1.5 2026-09-24 に進めたこと

T-43（README）を実装し、レビュー（Critical 0）を経て PR #140 をマージした。その後、8 本の PR を続けて出した:

| PR | 内容 |
|---|---|
| #141 | STATUS.md を 2026-09-23 夜の状態に合わせる（この節の前の版） |
| #142 | `verify-bundle.sh` が、staple 後の `.app` に増える `Contents/CodeResources` を許可リストに含めていなかった不具合を修正（初めて `make release` を通したときに見つかった） |
| #143 | Qwen3 4B の LLM 受け入れ試験の結果（✗ FAIL）を `docs/POC.md` に記録 |
| #144 | 「1 日分」の想定を 16 時間・約 350,000 文字から **10 時間・約 220,000 文字**に下げた（F-86。利用者の決定: 音声は 30 分ごとに区切られ、16 時間しゃべり続ける使い方は無い） |
| #145 | **X-43**: 単一パス Reduce の判定に件数の上限（`reduceMaxItems`＝4）を追加。4B・30B のどちらも、10 時間分の受け入れ試験の最後の 1 要求（18 個の中間結果を 1 回でまとめる Reduce）が `LLM_INVALID_JSON` で落ちていた不具合の修正 |
| #146 | **X-44**: `maxOutputTokens` の既定を 4096 → 8192 に。X-43 の後も、1 チャンク単体の map 呼び出しが同じ理由で落ちたため（利用者の決定: 内容が特に濃いチャンクでは稀に失敗しうることは許容する） |
| #147 | 30B（`qwen3-30b-a3b-instruct-2507-q4_k_m`）の再試験が合格。`verified: true` に。**issue #67 を閉じた**（v1.0 で選べる LLM が 1 つ以上になった） |
| #148 | STATUS.md を #140〜#147 のマージに合わせる |
| #149 | 作業用のログの置き場所をプロジェクト内の `local/`（gitignore 済み）にし、`~` に書かないようにする（利用者の指摘） |
| #150 | 実機の退避先を固定パス（`$HOME/VoiceDockE2E`）から利用者が決める `$BACKUP` 環境変数に |
| #151 | `local/`（作業用ログの置き場所）が #150 の作業中に誤って develop へコミットされていたのを取り除く（エージェントの手順ミス。git rm --cached で追跡だけ外した） |

**発見の経緯**: #67 の受け入れ試験を回すと、4B・30B とも長文（1 日分）の解析だけが `LLM_INVALID_JSON` で落ちた。原因は 2 段あった。
(1) 多数の中間結果を 1 回の Reduce でまとめようとして出力が `maxOutputTokens` を超えて切れる（X-43 で対応）、
(2) 1 チャンク単体の map 呼び出しでも、内容が濃いと同じ理由で切れることがある（X-44 で対応）。
どちらも参照実装 voicedock にも同じ弱点があるが、実機の本物のモデルで長文を通して初めて見つかった（`git show d3d595e:src/voicedock/llm.py` の `reduce_phase`・`strip_think` のコメント参照）。

Developer ID の署名の準備（公証のキーチェーンプロファイル `VOICEDOCK_NOTARY`・Developer ID Application 証明書）も 2026-09-23 夜〜24 に整い、`make release` を利用者が通した。`verify-bundle` の全項目 OK・公証・staple まで通り、**issue #77 を閉じた**（出力と sha256 は issue #77 のコメントに記録）。dmg 自体はこのセッションでは配布していない。

続けて、公証済みの `dist/VoiceDock.app` で T-43 の受け入れ条件の 1 つ（新しいアカウント相当での導入確認）を行った。既存の `~/Library/Application Support/VoiceDock` を退避して起動し、README の「インストール」〜「はじめに」①〜④を上から進めて**詰まった箇所は無かった**（issue #139 に記録）。終わって元の環境に復元済み。issue #139 の残りは、T-42 の実機実施（#95）の後の文言確認だけ。

## 2. アプリの完成度（2026-09-22〜23 に利用者と確かめた）

取り込み → 文字起こし → Raw ノート → 要約 → Daily ノート → 元音声の削除まで、**実機で一通り動いた**。
根拠は `<HOME>/logs/app.log`・`reaper.log`・DB・Vault に残っている。

- **起動**: `service_started version=0.1.0 schema=v1_initial`（2026-09-22 23:17）。メニューバーに常駐し Dock アイコンは出ない
- **Vault の選択**: 「はじめに」の NSOpenPanel で `~/VoiceDockTestVault` を選び、`config.json` の `vault.path` に入った
- **モデルの入手**: `model_downloaded id=silero-v5.1.2` と `id=large-v3-turbo-q5_0`。LLM は `.gguf` をファイルから取り込み（`custom:3605803b…`、2.5 GB）
- **診断**: `diagnostics_completed passed=11 failed=1 notices=2`
- **実機の取り込み**: DJI Mic 3 を USB で挿し `part_discovered` → `copy_completed` → 正規化 → 文字起こし → `raw_note_saved`（parts=1 → 2 → 3）。DB は `recordings` が COMPLETED 3・SKIPPED 1、`sessions` が COMPLETED 1
- **削除 ON の小さな実験**: `deletion_enabled` → `delete_requested` 3 件 → `reaper_run exit=0` → `source_deleted` 3 件（`reaper.log` にも同じ 3 件と `reaper_completed requests=3`）。退避（`~/VoiceDockE2E/device-backup`）を取ってから行った
- **LLM の疎通**: `session_merged parts=3 excluded=1 chars=205` → `llm_completed chunks=1 elapsed_s=3.5`
- **Daily ノート**: `obsidian_saved path="Daily/Voice/Wiki/20260922/2026-09-22 Voice.md" bytes=1775`。Raw は `Daily/Voice/Raw/20260922/2026-09-22 raw.md`
- **要約の契機**: 2026-09-23 00:00 の Daily ノートは、当時の 0:00 の自動要約で走った。その後 F-66 で 0:00 の自動要約を**廃止**し、パネルの「今すぐ要約」に置き換えた（PR #102・#107）。「今すぐ要約」ボタンは、レビュー用のビルド（worktree の dist）で利用者が押し、「新しく要約する録音はありません」が出て 4 秒で消えることを確かめた

> **注意**: 本体のチェックアウトの `dist/VoiceDock.app` は古いことがある。実機に触る前に、必ず develop で `make vendor && make app` を回し直してから使う。
> `dist/VoiceDock.app` は 2026-09-23 20:37 に develop（`44cb84c`。F-71〜F-84 をすべて含む）で組み直した。F-77 より前のビルドで NORMALIZED 以降になった Part は再検査されない。

### F-71〜F-84 の後の実機の確認（2026-09-23 夜に利用者と行った。組み直した `.app`）

**確認できたもの**

| 項目 | 結果 |
|---|---|
| 終了の後に `whisper-cli` / `llama-server` が残らない（F-76） | ✅ 終了は 1 秒未満、`pgrep` は空 |
| 2 つ目の起動が何も表示せずに終わる（F-76） | ✅ `open -n` の後、`service_stopping reason=already_running`、アイコンは 1 つ |
| `logging.level` を変えて「設定を読み直す」→「再起動で反映される設定あり」（F-84） | ✅ 通知・ログのレベルの行・主画面の印の 3 つが出て、元に戻すと 3 つとも消えた |
| `state/app.lock` を開けないときの NSAlert（F-84） | ✅ `chmod 000` で起動 → NSAlert → 閉じるとアプリは終わる。`chmod 644` で戻して通常起動 |
| 名前が DJIMIC3 でない DJI 形式のボリューム（F-81） | ✅ `BACKUP`（読み取り専用の dmg）で `volume_skipped reason=not_included`、取り込まず「はじめに」の⑤の案内。detach で案内も消えた |
| 取り込み中のツールチップ（F-84） | ✅ 表示された |
| 取り込み中に「無効にする」→「読み取り専用へ戻しています…」（F-84） | ✅ 約 1 秒残り、その後「有効」に戻らなかった。`deletion_disabled`・`config.json` と `reaper.conf` は `false`・`mountMode` は `ro` |
| 取り込みの途中でデバイスを抜いた後・「無効にする」を押した後の削除（観察） | ✅ 抜いた後は文字起こしと Raw の保存が最後まで進み、`delete_requested` は出ず `RAW_SAVED` のまま。挿し直した直後に「無効にする」を押すと、3 本とも `source_deleted_at` が空のまま残った（どの修正の効果かの切り分けはしていない） |

**確かめられなかったもの**

- **モデルの読み込み中に終了すると 10 秒以内に終わる（F-76）** — 使っているモデルが 2.5 GB で、疎通確認が 1〜3 秒で終わるため、読み込み中を狙えない。`LlamaServerSupervisor.stop()` が起動中のプロセスを待たずに止めるコードで確かめた（実機では未確認）。読み込みに時間がかかる大きなモデル（PLAN の想定は 18 GB 級）なら狙える
- **終了の後始末の最中にログアウトしても中断されず、子も残らない（F-76）** — ログアウトを伴うので未実施。次に、ほかの作業をしていないときに行う
- 「再試行」の後の状態の詳細の読み直し（F-84）— FAILED の Part が無く、変化が見えない。FAILED が出たときに確かめる
- 「モデルの節を開く」の枠がファイル選択の後も残る（F-84）— 要対応の「モデルの節を開く」が出るのは、処理待ちがあるのにモデルが無い・LLM が未選択のとき。出たときに確かめる
- 「更新する」（F-84）— 次に版を上げたとき（T-44）
- 任意: P0-05 のついでに、32 bit float の設定の録音・電池切れや録音中の電源断で止まった録音がどういう WAV になるか（F-77。`docs/tickets/P0-poc.md` §7 の 5）

> **この確認は `docs/E2E.md` の E2E-02・10・17 の実施にはならない**（利用者と確認した）。E2E.md は決まった記録（[C-1]〜[C-16]・`diff`・退避）と前提（E2E-10 は削除 OFF の 13 件が PASS 済み）を求める。今回のログは下見として使い、判定表は「未実施」のままにする。

`make test-disk`（R3）は F-73 の PR の先端と、F-80 の PR の先端（F-79〜F-82 を含む）で、実機を抜いてから利用者が回し、どちらも全部緑だった（2026-09-23）。

### 2.5 2026-09-24 夜: E2E（削除 OFF）10/16 本を実施

`docs/E2E.md` §2 の判定表のうち、E2E-01・03・04・05・07・08・09・12・14・16 の 10 本を実機（DJIMIC3）で実施し、すべて `✅ PASS`。各シナリオの生の出力は `docs/E2E.md` の該当節に記録済み（PR #169）。

- E2E-07 は当初「無音 1 本＋普通の録音 1 本」の想定に対し実際は無音 2 本になったが、無音判定・警告・`⚠` 無し・元音声が残ることはすべて確認できたため、その旨を記録したうえで PASS とした（利用者の判断）
- E2E-09（同日への再オープン ×4）・E2E-12（文字起こし中の強制終了）・E2E-08（工程内リトライ→再コピー→完走）・E2E-16（TCC の拒否→許可し直し）は、いずれも期待どおりの遷移・ログ・件数一致を確認
- 残り: **E2E-02**（30 分×3 の長時間録音が要る）と **E2E-13**（スリープ）は別日に、**E2E-06**（1 日 10 時間分）は実運用の中で確認する（利用者の決定。PLAN §12.4 の条件どおり、この 3 本が揃うまでゲートは開かない）
- 削除 ON 関連（E2E-10・11・17、§5 の G-4、§6 の R-01〜R-09）は未着手。削除を有効にする大きな作業なので別セッションに回す

### 2.6 2026-09-25 未明: 削除 ON 6/13 本を実施

`docs/E2E.md` の削除 ON 系のうち、E2E-10・E2E-11・E2E-17・R-01・R-04・R-05 の 6 本を実機（DJIMIC3）で実施し、すべて `✅ PASS`。各シナリオの生の出力は `docs/E2E.md` の該当節に記録済み。

- **E2E-10**（削除 ON で通し）: 普通の録音 2 本の元音声が消え、無音の録音は消えないことを確認。`voicedock-reaper` の単体実行 3 パターン（バンドル内起動拒否・`--version`・要求無しでの実行）も期待どおり
- **E2E-11**（過去分の削除。前半のみ）: 17 件の削除要求を一括で書き、全件削除を確認。後半（手動で消した分の完了）は F-63 の合意どおり単体テストで代替
- **E2E-17**（削除を無効化）: クリック1回で即座に無効化・読み取り専用へ再マウント。`reason=lock_mismatch` という、ドキュメントの想定 `reason=delete_source_audio_disabled` とは異なる理由語が出たが、`PLAN.md:1953-1954` の無効化 5 段階（reaper.conf → config の順）のレース窓に起因する正当な挙動と確認した（バグではない。記録に経緯を残した）
- **R-01**（1本を通しで・ON）: `delete_requested` が `raw_note_saved` の直後、`obsidian_saved` を待たずに出ることを確認
- **R-04**（Vault利用不可・ON）: Vault が使えない間は1本も消えず、戻すと再起動なしで自動再開して消えることを確認
- **R-05**（抜き挿し6回・ON）: `request_id` の重複・`reason=replayed` とも0件

作業中に見つかった軽微な手違い（`$BACKUP` の誤設定による退避の二重コピー、`.Trashes/._501` という macOS のゴミ箱メタデータ1件が退避漏れ）はいずれもデバイス側には影響せず、経緯を `docs/E2E.md` §3.10 の記録に残した。

残り: **R-02**（コピー中に抜く。30分×3本の長時間録音＋危険な手順）・**R-03**（文字起こし中に抜く。危険な手順）・**R-06**（1日分。運用の中で確認してよい）・**R-07**（無音・重複を混ぜる）・**R-08**（文字起こし失敗）・**R-09**（同日再オープン。日付が跨いだため前提の作り直しが要る）・**§5 G-4**（三重ロックを外して24時間）は未着手（利用者の決定で別セッションに回した）。
削除は**有効なまま**セッションを終えた（次回 R-02 以降も削除 ON で行うため）。

## 3. 利用者の環境

| もの | 場所・値 |
|---|---|
| `.app` の作り方 | `make vendor`（whisper.cpp / llama.cpp）→ `make app` → `dist/VoiceDock.app` |
| `<HOME>` | `~/Library/Application Support/VoiceDock`（`config.json`・`ui-state.json`・`voicedock.sqlite`・`logs/`・`inbox`・`staging`・`queue`・`bin`・`models`） |
| whisper モデル | `<HOME>/models/whisper/ggml-large-v3-turbo-q5_0.bin`（547 MB） |
| VAD モデル | `<HOME>/models/vad/ggml-silero-v5.1.2.bin` |
| LLM モデル | `<HOME>/models/llm/custom-3605803b982cb64a.gguf`（2.5 GB。4B と同一。`verified: false`）と `Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf`（18.6 GB。カタログから取り込み。**`verified: true`**。2026-09-24） |
| 試験用 Vault | `~/VoiceDockTestVault`（`.obsidian` あり） |
| 退避先 | 2026-09-22〜23 は `~/VoiceDockE2E`（`device-backup`・`check-before.txt`・`check-after.txt`）に固定していたが、2026-09-24 に利用者の決定で `docs/E2E.md`・T-35・T-42 の固定パスを `$BACKUP`（利用者が試験のたびに決める環境変数）へ変えた（PR #150）。この行の値は当時の記録として残す |
| 削除 | **有効**（2026-09-25 未明、削除 ON の実機試験のためにパネルの3秒長押しで有効化し、そのままにしてセッションを終えた。`config.json` は `cleanup.deleteSourceAudio=true`・`device.mountMode=rw`、`reaper.conf` は `DELETE_SOURCE_AUDIO=true`）。**無効に戻すときは削除の画面の「無効にする」をクリック1回**（E2E-17 参照） |
| 取り込むデバイスの名前 | `config.json` の `device.includeVolumes` は `["DJIMIC3"]`（F-81 の既定に合わせて 2026-09-23 に利用者が手で直した。控えは `config.json.bak`） |
| 実機 | 2026-09-24 夜〜25 未明、E2E（削除 OFF・ON）の試験で長時間 `/Volumes/DJIMIC3` に接続していた（削除 ON 中は読み書き可能でマウント）。セッション終了時点では接続中の可能性がある。次のセッションはまず `ls /Volumes` で確かめる |

## 4. 2026-09-22〜23 に利用者が決めたこと・直したこと

| F | 決めたこと | PR |
|---|---|---|
| F-60 | **T-33（voicedock からの乗り換え）を取り下げ**。E2E-18 も取り下げ（番号は詰めない）。`imported_keys` の表と除外は空のまま無害に残る | #71（#70 は閉じた） |
| F-61 | **共存ガードを廃止**（このアプリが完成したら voicedock は動かさない）。DR-13 は打ち消しの行、E2E-15 は取り下げ。診断は 15 件 ＋ DR-09 = 16 件 | #74 |
| F-62 | **dmg は `/Volumes` の外にマウントして作る**。空の HFS+ を `hdiutil attach -nobrowse -mountpoint dist/…` に付け `ditto` → detach → `convert -format UDZO`。`makehybrid` は署名が壊れるので却下 | #78（T-34） |
| F-63 | **E2E-11 の後半（手動で消した分の完了）は単体テストで代える**（`BacklogPlannerTests` の resolveAbsent 系）。手の操作で `SOURCE_DELETE_PENDING` を確実に作れないため。E2E-11 は前半が PASS なら PASS | #96（T-42） |
| F-64 | **元ファイルが無いと観測できた RAW_SAVED は消さずに完了**（detail `already_absent`）。新鮮でその Part の取り込みより後の snapshot で、接続中・列挙でき・relpath が一覧に無いときだけ | #99 |
| F-65 | **パネルをカード型に作り直し**、主画面はスクロールなし。長い中身は popover 内の別画面（「‹ 戻る」）。**削除の有効化と根拠 B は赤いボタンの 3 秒長押し**（`DeletionEnabler` の `ENABLE` 完全一致は内部に残す） | #101（高さの件は #100） |
| F-66 | **「今すぐ要約」を足し、0:00 の自動要約を廃止**。Session を閉じる契機は無通信 `idleCloseSeconds` の `idle`（自動。これは残す）と今すぐ要約（手動）の 2 つだけ | #102・#107 |
| F-67 | **一覧の完全さ**。`DeviceReader.scan` の `lstat` が `ENOENT` 以外で失敗したら `complete = false`（F-64 の自動完了の根拠を固める） | #106（issue #97） |
| F-68 | **SPEC 同期の拡張**。S10（名前の正規表現）・S11（whisper-cli の argv）・S12（保存検証 RN/DN）・S13（tick の段）・S20（パネルの節と画面）・S21（アイコン）・S22（はじめに）・S23（ui-state.json） | #108（issue #18） |
| F-69 | **消せないまま期限を過ぎた RAW_SAVED の決着と要対応**。期限（backoff を使い切る）＋ 観測できた失敗が同じ `connectEpoch` で 2 回続いたら、消さずに COMPLETED（detail `not_deletable`、原因語 `source_info`/`pre_identity`/`transcript`/`raw_note`）。要対応に `undeletableSources(n)` | #110（issue #98） |
| F-70 | **最終接続の保存**。`<HOME>/ui-state.json` の `lastConnectedAt`（epoch ミリ秒）に残し、再起動後も「最終接続」を表示する（`LastConnected.resolve` / `valueToSave`） | #109（issue #105） |
| F-71 | **（全体コードレビュー）トラップの一掃**。設定の検証そのものの桁あふれ（起動のたびに落ちていた）・秒 / バイト / 文字数のキーに CV の上限（秒は 365 日、`hashChunkBytes` は 64 MiB、文字数・トークン数は 10^9）・frontmatter は `Yams.compose` で読む（60 進の int で落ちていた。str でない鍵があれば全体を読めない扱い）・transcript の秒は有限で絶対値 10 億秒以下・`f_bavail`・安定性判定の重複 relpath | #125（issue #120） |
| F-72 | **（全体コードレビュー）削除の同意**。後追いの実行はプレビューで見せた対象 ∩ 立て直した計画だけ・診断の結果はパネルを閉じたら捨てる・`RequestWriter` が要求ファイルの前後で reaper.conf を読み直す・無効化の再マウントは全デバイスの `.readOnly` の観測で判定 | #121（issue #112） |
| F-73 | **（全体コードレビュー）reaper とデバイスの防御**。`RelPath` をスカラー（UTF-8 の `/`）で分割・openat 連鎖は `O_NOFOLLOW_ANY`・reaper は unlink の直前に reaper.conf を読み直す・`ENOENT` の要求は何も書かずに飛ばす・FIFO / symlink への備え・再マウントは今の statfs の node と照らしてから diskutil | #122（issue #113） |
| F-74 | **（全体コードレビュー）永久に終わらない状態**。F-69 の決着を ID の無い SOURCE_DELETE_PENDING にも（既存の 2 遷移）・partkey が空の結果で期限切れを止めない・取り下げきれない要求があれば ID を外さない・後追いの ③ の前に止まった COMPLETED の回収・transcript が読めない Session は `SESSION_MERGE_FAILED` | #123（issue #114） |
| F-75 | **（全体コードレビュー）Raw ノートの本文を守る**。書き直しで RAW_SAVED 以降の Part の本文が消えるなら書かずに FAILED、要対応「書き直せない Raw ノート」（利用者の決定）・トリガが載らなければ RAW_SAVED にしない（X-38）・上書きは `type` も一致・親フォルダが無ければ基本名から探す | #126（issue #115） |
| F-76 | **（全体コードレビュー）終了と子プロセス**。起動の途中の llama-server を直ちに止める・`terminateAll` で閉じて以後の起動を拒む・終了の後始末全体を 10 秒で打ち切る・DR-09 の llama を応答の後で止める・単一起動（`state/app.lock`）・前回の whisper.json を消す・閉じた後の reaper の版の確認は `DeletionReadiness.unconfirmed` | #128（issue #116） |
| F-77 | **（全体コードレビュー。利用者の決定で実機の確認より先）WAV ヘッダの長さ**。data の宣言が実データより短い入力は `NORMALIZE_VERIFY_FAILED`（inbox を消さない）。実機の `_orig.wav`（24 bit mono・data は 32776 から・後ろに何も無い）は合格 | #127（issue #117） |
| F-78 | **（F-74 の続き。利用者の決定）** 一覧に無い ID の無い SOURCE_DELETE_PENDING を F-64 と同じ条件で自動で完了・reaper の拒否が 3 回続いた Part は消さずに決着（DB の events で数える）・決着した Part を後追いでまた拒否されたら決着し直す・要対応の説明文を 5a / 5b の両方に合わせた | #129（issue #124） |
| F-79 | **（全体コードレビューの残り）Worker の空回りと LLM のリダイレクト**。reaper は要求の宛先が書き込み可能で走査中でないときだけ起動し、何も処理しなかった回は走査しない。LLM の HTTP はリダイレクトに従わず 2xx 以外を `LLM_UNAVAILABLE`（X-39）、/health の 200 の後に子の生存を確かめる | #131（issue #118） |
| F-80 | **（同）削除まわりの残り**。連続の 2 回目は 60 秒以上あけ node の変化でも数え直す、FAILED の兄弟は戻りうる間だけ待つ、`SourcePresence.of` に一本化、reaper の processed.log に `<id> DELETED`（RV-04 で書き直し）、`allowReopen=false` の後から RAW_SAVED を自動で評価（その Part だけ）、`mount_failed` を「つなぎ直して」に、reaper の更新の要対応は削除が有効な間だけ | #134（issue #119） |
| F-81 | **（同。利用者の決定）デバイス・文字列・取り込む名前**。書記素の比較の残りをスカラーに、列挙の後にマウントを確かめ直す、mount の失敗を `unavailable` に、ネットワークの FS を除外、**`includeVolumes` の既定を `["DJIMIC3"]`**（名前が合わない DJI 形式のボリュームは取り込まず⑤で案内。X-42）、再コピーで長さを測り直す、A8 は RK-07 に記録だけ | #133（issue #119） |
| F-82 | **（同）パイプラインの中核**。取り直しの順序・needs_recopy（ヘッダの不合格でも立てる）、分組を 1 トランザクション（`Store.groupPart`）、inbox の孤児判定を相対位置で（symlink で既知の原本を消していた）、終了で止めた whisper / LLM を失敗にしない、一時的な起動の失敗は再試行、whisper の JSON を寛容に読む（直した transcript は無音にしない。X-41） | #132（issue #119） |
| F-83 | **（同）ノート・モデル・設定・ログ**。frontmatter の C1 を `\uXXXX`（X-40）、ノートと transcript を F_FULLFSYNC、ノートの読み書きに 64 MiB の上限、モデルの再開データを残す（終了でも）・取り込みの残りを掃除、**config.json は書く前に読み直して変更を当てる**（手編集を消さない）、CV の書記素・backoff の要素数 | #135（issue #119） |
| F-84 | **（同）UI**。削除が有効で版が違う間の「更新する」、refresh と状態の詳細の世代、無効化の待ちの表示、ツールチップ、閉じたら枠と失敗を戻す、**単一起動のロックを開けないときは NSAlert**、読み直しで変わらない設定の「再起動で反映される設定あり」 | #136（issue #119） |
| F-85 | **（T-43 の作成中に発見。利用者の決定）** 取り下げた E2E-15・E2E-18 に `~~` が付いておらず、SPEC が E2E を 18 件と数えていた（生きているのは **16 件**）。DR-13 と同じ打ち消しの形にし、`make spec` で同期。`RunbookTests` は取り下げの行を除いて S9 と 1 対 1 で比べる | #140 |
| F-86 | **（利用者の決定）** 「1 日分」の想定を 16 時間・約 350,000 文字から **10 時間・約 220,000 文字**に下げた。音声は 30 分ごとに区切られ、16 時間しゃべり続ける使い方は無い。P0-07・P0-09・E2E-06・T-24 の長文 fixture を合わせた | #144 |
| F-87 | **X-43。**4B・30B の受け入れ試験で見つかった Map-Reduce の不具合。単一パス Reduce の判定に件数の上限（`reduceMaxItems`＝4）を追加。文字数だけで単一パスにすると、束ねる中間結果が多いときに出力が `maxOutputTokens` を超えて切れることがあった | #145 |
| F-88 | **X-44。**F-87 の後も、1 チャンク単体の map 呼び出しが同じ理由で落ちたため、`maxOutputTokens` の既定を 4096 → 8192 に（`CV-51` の範囲内）。内容が特に濃いチャンクでは稀に失敗しうることは許容する（利用者の決定） | #146 |
| F-91 | **（利用者の依頼）** 削除が有効な間のメニューバーの印を、横に並ぶ `trash` から状態の記号の右上の赤い点（`StatusIconBadge`）に。画像はテンプレートのまま、パネルの `trash` と表示の条件は変えない | feat/deletion-dot-and-prompt-editor |
| F-92 | **X-46。（利用者の依頼）** 要約プロンプト（analyze / map / reduce）を ⚙ → 「要約プロンプトを編集…」の別の窓で編集できるように。`llm.analysis.prompts.*`（null = 同梱）、`schemaVersion` 3（2 → 3 の移行）、CV-60。D-7 に編集の窓 1 つだけの例外 | feat/deletion-dot-and-prompt-editor |

## 5. 残っている作業

### 開いている issue

| issue | 中身 | 誰がやるか |
|---|---|---|
| #139 | T-43 README と文書テスト | 実装はマージ済み（#140）。**新しいアカウント相当での導入確認は済んだ**（2026-09-24。詰まり無し）。残りは**T-42 の実機の後**に README の実機未確認の文言（PR #140 の「マージ後にやること」）を確かめることだけ |
| #81 | T-35 実機 E2E（削除 OFF） | 手順書とテストはマージ済み（#82）。**2026-09-24 夜に 10/16 本を実施・PASS**（E2E-01・03・04・05・07・08・09・12・14・16）。残り: E2E-02（30分×3の長時間録音）・E2E-13（スリープ）は別日、E2E-06（1日分）は実運用で確認 |
| #95 | T-42 実機 E2E（削除 ON）とゲート | 手順書とテストはマージ済み（#96）。**実施は【利用者が行う】**。2026-09-25 未明に E2E-10・11・17・R-01・04・05 の 6/13 本を実施・PASS（§2.6）。残り R-02・03・06・07・08・09・G-4。`docs/E2E.md` §4 のゲート G-1〜G-5 はいま全部「未実施」で **ゲート: 閉** |
| #103 | Bluetooth 接続での読み込みと削除の調査・実験 | **v1.0 の後**。調査はエージェント、実験は【利用者が行う】 |

**2026-09-24 に閉じた issue**: #67（T-24。30B が `verified: true` に。v1.0 で選べる LLM が 1 つ以上になった）、#77（T-34。`make release` が通り、署名・公証・dmg まで確認済み）。

PR がマージされても issue が開いたままなのは、**実機・実モデルでの確認がその issue に残っている**ため。

### T-43 と T-44 の前提

- **T-43（README）** — **完了（PR #140。2026-09-24）**。実機で確かめる文言は T-42 の後に確かめる合意（issue #139 に残る）
- **T-44（v1.0 リリース）** — 前提は T-43・T-42・T-34 と、話者分離の T-46〜T-51（F-89）。`docs/RELEASE.md`・`docs/release-notes/TEMPLATE.md`・`ReleaseChecklistTests.swift`、`VERSION` と `AppVersion.string` を `1.0.0` へ（同じ PR で両方）。**削除のゲートが開いていないと出せない**

### 話者分離（F-89・F-90。issue #104。v1.0 に含める。**完了**。2026-09-24 に利用者が実機で確認）

パネルでオン／オフ（既定オフ）、表示は Raw の `**話者A**: …` の行、単語単位の時刻は使わない、精度は利用者が使って判断する（2026-09-24 の利用者の決定）。

| チケット | 中身 | 前提 | 並列 |
|---|---|---|---|
| T-46 | argmax-cli のビルドとモデルの同梱（Vendor・make-app・verify-bundle） | T-03, T-34 | T-47 と並列 |
| T-47 | VDCore: `speaker`・`SpeakerLabel`・設定キーと schemaVersion 2・ログ・AppPaths | T-09, T-10 | T-46 と並列 |
| T-48 | VDTranscribe: `Diarizer`・RTTM・割り当て・`Transcriber` | T-46, T-47 | T-50 と並列 |
| T-49 | VDPipeline: 配線・ログ・DR-18・README の件数と出典 | T-48 | T-51 と並列 |
| T-50 | VDNotes / VDLLM: Raw の話者の行・チャンクの前置き | T-47 | T-48 と並列 |
| T-51 | UI: 「一般」のトグル | T-47, T-48 | T-49 と並列 |

T-44（v1.0 リリース）は T-46〜T-51 の後。

### Phase 0 の残り

`docs/POC.md`: P0-01・02・03・12 は PASS、P0-10 は対象外。**P0-04〜07・09・11 は未実施**（whisper / llama の実測、SMAppService の P0-08 も未実施）。実機での一通りが動いたので、必要なものだけ拾えばよい。

## 6. 次のセッションで最初にやること

1. `git fetch origin && git switch develop && git pull`（先頭が `36b2b80` より進んでいないか確かめる。今回の削除 ON 6/13 本の PR がマージされていれば E2E の記録も入っている）
2. `ls /Volumes` で**実機の接続状態**を確かめる。削除は**有効なまま**セッションを終えているので、挿さっていたら読み書き可能でマウントされている可能性がある。ディスクを触る作業（`make test-disk` 等）の前には利用者に抜いてもらう
3. `python3 docs/porting-notes/check-tickets.py` が 0 件、`make lint && make test` が緑であることを確かめる
4. `gh pr list --state open` で開いている PR が無いことを確かめる
5. **残っている実機作業は E2E（issue #81 → #95）**。削除 OFF は 16 本中 10 本（2026-09-24 夜）、削除 ON は 13 本中 6 本（2026-09-25 未明。§2.6）が完了。`make vendor && make app` で `dist/VoiceDock.app` を最新にしてから（すでに公証済みの `dist/VoiceDock.app`／`dist/VoiceDock-0.1.0.dmg` があるが、develop が進んでいれば作り直す）、**残り** E2E-02・06・13（削除 OFF）→ R-02・03・06・07・08・09・§5 G-4（削除 ON）→ §4 のゲートを、**手順を提示して利用者に渡す**形で進める。R-02・R-03 は「読み書き可能な状態で不意に抜く」危険な手順を含むので `docs/E2E.md` §6.2・§6.3 の安全手順（退避・`comm -23` での差分確認）を省略しない。結果は `docs/E2E.md` に貼る
6. #81・#95 が両方終われば、issue #139 の最後の項目（README の実機未確認の文言）も片付けられる。その後 T-44（v1.0 リリース）に進める
7. **ブランチを切り替える前に、必ず `git status --short` で作業ツリーが clean か確かめる**（`local/` のような gitignore 対象でも、切り替え元でコミットされていると `git switch` で消えることがある。2026-09-24 にこれで事故を起こした。§1.5 参照）

## 7. 進め方の決まり

- **1 チケット = 1 issue = 1 PR。** `main` ← `develop` ← `feat/T-nn-*`。ブランチ名は `feat/` / `fix/` / `docs/` ＋ 短い英語名
- **マージは利用者が行う。** エージェントは `gh pr merge` を実行しない
- **PR がマージされたら、対応する issue をすぐ閉じる**（実機の確認が残る issue は、その旨を書いて開けておく）
- CI は開発機のセルフホストランナー `voicedock-local`。ブランチ保護は無料プランで使えないので、**CI が緑のときだけマージする**
- 同時に走らせるエージェントは**最大 4 本**（8 本で使用量の上限に当たった）
- **`ticket-review` は本体のセッションから回す**（実装エージェントの中からではなく、差分を見せて Critical が無いことを確かめる）
- **実機の手順は【利用者が行う】と書いてそこで止まる。** 自分で実行しない
- **`/Volumes` に触れない。** 読み取り（`ls`・`stat`・`find -print`）だけ。ディスクイメージは `hdiutil attach -nobrowse -mountpoint ~/VoiceDockPoC/mnt/<名前>` で `/Volumes` の外へ。ボリューム名に `DJIMIC3` を使わない
- `sudo` を使わない。参照実装 `/Users/terada/Projects/voicedock` は `git show d3d595e:<path>` でしか読まない
- 文書の優先順位は **PLAN ＞ 00-api-map ＞ 各チケット**。食い違ったら実装を止め、上位に合わせ、**同じ PR の中で**直す。`00-api-map.md` と PLAN をチケットの都合で編集しない（§「API 地図への変更提案」に書いて利用者に上げる）
- チケットを直したら `python3 docs/porting-notes/check-tickets.py` を回す（0 件であること）

## 8. 実装で分かった共通の約束（後続にも効く）

- URL からパス文字列を取るのは `url.path(percentEncoded: false)` だけ（00-api-map §0）。ディレクトリの URL は末尾に `/` が付く
- 環境変数は `TestEnvironment.value(_:)` を通して読む（PLAN §10.1）
- テスト用のディスクイメージのボリューム名に `DJIMIC3` を使わない（`DiskImageVolume` がコードで拒む）
- macOS の `/bin/bash` は 3.2。全角文字の直前の変数は `${var}` と書く（`$var（` は `set -u` で落ちる）
- チケットの逐語コードが `swift format` で落ちるときは整形に合わせ、チケットも直す
- SPEC に節を足す順: PLAN の該当節に表 → `make spec` → `SpecDocument` の extension に読み取り口 → 照合のテストは実装を import できる各モジュールのテストへ（PolicyTests は TestSupport にしか依存しない）。SPEC と PLAN の一致は `SpecExtendedSectionsTests`（F-68）
- **パネルの主画面に `ScrollView` を置かない**（F-65）。高さは `NSHostingController.sizingOptions = .preferredContentSize`。固定の 640pt に戻すと popover が 1pt に潰れる（PR #100）
- 削除まわりで Part が詰まる経路は F-64（一覧に無い）・F-69（一覧に在るが消せない）・F-74（ID の無い PENDING）・F-78（一覧に無い PENDING・reaper の拒否が続く）で塞いだ。**新しい設定キー・遷移の辺・ログのイベントを増やさずに**塞ぐのが方針
- 秒・バイト・文字数を掛け算や sleep に使う設定キーには **CV の上限**を付ける（F-71）。使う側で `* 1000` をあふれさせない
- 文字列の区切り・前方一致・鍵の照合は **Unicode スカラー単位**（`unicodeScalars`・UTF-8 のバイト）で行う。Swift の `split(separator:)`・`hasPrefix`・`==`・`Set<String>` は書記素・正準等価で比べるので、パスや鍵には使わない（F-71・F-73・F-75）
- ファイルを読む前に `lstat` で通常ファイルと上限サイズを確かめ、`O_NOFOLLOW | O_NONBLOCK` で開いて `fstat` で確かめ直す（FIFO・symlink への備え。F-71・F-73）
- 並列の修正の PR は付録 F の末尾で必ず衝突する。**F 番号を先に割り当て**、マージの順に**前の PR を merge コミットで取り込んで 1 列につなぐ**と、利用者は順に続けてマージできる（2026-09-23。squash / rebase でマージすると列が崩れるので「Create a merge commit」で）
- 並列のエージェントはスクラッチパッドを共有する。一時ファイルは `scratchpad/<F 番号>/` のように分ける（コミットメッセージが上書きされる事故があった）
- 付録 D（X-nn）の番号も F と同じく**先に割り当てる**（並列の修正が同じ X-39 を使ってぶつかった）。2 つの PR の API をつなぐ配線は、1 列につなぐ統合の段で入れる
- `device.includeVolumes` の既定値の変更は既存の `config.json` を書き換えない（既定値は config.json が無いときだけ書く）。利用者の環境に効かせるには手で直してもらう
- `ConfigStore.update` は書く前に今の `config.json` を読み直して変更を当てる（F-83）。`update` の中から `load()` や修復口を呼ばない（`DeletionEnabler.serially` の中でデッドロックする）
- `ui-state.json` の `schema` は 1 のまま。**足す鍵は任意**にして、古い読み手が未知の鍵として無視できるようにする（F-70）

## 9. 文書の地図

| 文書 | 役割 |
|---|---|
| `docs/PLAN.md` | 計画書 v1.1（3,100 行）。**最上位**。付録 A = 状態・エラー・ログ、B = ND / RV / E2E、D = voicedock との差分（X-01〜X-46）、F = 改訂（F-01〜F-92） |
| `docs/tickets/00-api-map.md` | モジュールをまたぐ名前の契約。**チケットより上位** |
| `docs/tickets/README.md` | 共通規約・チケットの形（10 節）・依存順の目次 |
| `docs/tickets/T-*.md` | 実装の詳細仕様（45 本） |
| `docs/SPEC.md` | PLAN から `make spec` で生成する機械可読の仕様（S1〜S23）。手で書かない |
| `docs/E2E.md` | **実機手順の正本**（issue や PR 本文に手順を置かない）。§4 が削除のゲート |
| `docs/POC.md` | Phase 0 の**実測の記録**。PLAN と食い違ったら実測が正で、PLAN とチケットを直す |
| `docs/porting-notes/V1〜V7・R1・R2` | voicedock の移植メモと独立レビュー |
| `docs/porting-notes/check-tickets.py` | チケット一式の機械検査 |
