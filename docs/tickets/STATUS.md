# 進捗と再開の手順（2026-10-01・**v0.9.0 を公開した後**。E2E-06・R-06・G-4 が PASS。v1.0 に向けて E2E-13 だけが残る）

**この文書だけ読めば再開できる**ように書いてある。次のセッションはここから始める。

## 1. いまの状態

| 区分 | 数 |
|---|---|
| チケット（T-01〜T-51） | 51 本（T-46〜T-51 は話者分離。PLAN F-89） |
| マージ済み | **49 本**（T-46〜T-51 が加わった） |
| 取り下げ | 1 本（T-33。PLAN F-60） |
| 残り | 1 本（T-44 v1.0 リリース。未着手。削除のゲートが開いてから） |
| 配布 | **v0.9.0 を公開済み**（2026-09-26。§1.6） |

**`main` の先頭は `aea41da`（PR #186。注釈付きタグ `v0.9.0`）、`develop` の先頭は `03a3fa4`（PR #185）**。2026-09-25 夜〜26 の作業は §1.6。以下はそれより前の記録: 話者分離は #153（計画）→ #160〜#165（実装）→ #166（後始末）→ #167（コードレビューの修正。F-90）でマージ済み。**2026-09-24 に利用者が実機の録音で確認し、issue #104 を閉じた**（`diarization_completed speakers=2 elapsed_s=4.5`）。**2026-09-25 未明、削除 ON の 13 本のうち 10 本（E2E-10・11・17、R-01・03・04・05・07・08・09）を実施・全件 PASS**（下の §2.6。PR #170 ほか）。**2026-09-25 午後、E2E-02（削除 OFF）と G-1・G-3 を PASS**（§2.7）。

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

## 1.8 2026-09-30〜10-01 に進めたこと（G-4）

**§5 G-4（三重ロックを全部外して 1 日）を行い ✅ PASS**（記録は `docs/E2E.md` §5。生の出力の控えは `~/VoiceDockE2E-G4/`）。2026-09-30 11:12:49 に開始の記録を取り、利用者が普段どおり約 8 時間 22 分（17 本）を録って 19:57 に挿し、20:45 に完走、2026-10-01 11:15 に締めの記録を取った。

- その日の 17 本がすべて消え、Raw ノートに載った 17 本と `source_deleted` の 17 件が一致。開始時からあった無音の 1 本は残った。Raw 1 枚・Daily 1 枚、`FAILED` 0、キューは空、`reaper_failed`・拒否は 0、24 時間の ERROR・WARNING は 0 行。Daily / Raw は利用者が目視して「問題ありません」
- 要約は 508.8 秒（9 チャンク・48,181 字）。挿してから完走まで 47 分半
- **ゲートは G-2（E2E-13）だけが残る**。削除は有効のまま

## 1.7 2026-09-30 に進めたこと（E2E-06・R-06）

利用者が 2026-09-29 の勤務時間中に普段どおり録った約 7 時間 4 分（30 分 × 14 本と約 4 分 1 本）で、**E2E-06（削除 OFF）と R-06（削除 ON）を続けて行い、どちらも ✅ PASS**（記録は `docs/E2E.md` §3.6・§6.6。生の出力の控えは `~/VoiceDockE2E-0930/`）。§6 の R-01〜09 がすべて PASS になったので **G-5 も ✅**。

- **E2E-06**（01:11〜01:57。46 分）: 2026-09-29 の Session が 1 行（`part_count=15`）、Raw 1 枚・Daily 1 枚、元音声は残った。内訳は文字起こしまで約 8 分・無通信の待ち 30 分・要約 448.7 秒（7 チャンク・49,990 字）
- **R-06**（02:12〜02:57。45 分）: E2E-06 の後に利用者がノートを消し、**データを初期化し、削除を有効にして、同じ録音を取り込み直した**（利用者の判断。記録に差として書いた）。消えた 16 本と `source_deleted` の 16 件が完全に一致、無音の 1 本は残った、`queue/*` は空、空き容量が 3.4 GiB 戻った
- 観察（FAIL ではない）: 走査が終わる前に Raw ノートを保存した Part は、Raw の直後には要求されず、後の契機（次の Raw の直後・`SAVED` の直後）でまとめて要求された。遅れる側に倒れているだけ（§6.6 の箇条書き）
- **削除は有効のまま**（利用者の決定。2026-09-30 02:07:58 `deletion_enabled`）

## 1.6 2026-09-25 夜〜26 に進めたこと（v0.9.0 の公開まで）

| PR | F | 内容 |
|---|---|---|
| #179 | F-94 | 取り込むデバイスの名前の既定を `VOICEDOCK` に（利用者が実機を Finder で改名する。アプリは改名しない） |
| #181 | F-95 | 「詳細・診断」にデータの初期化（3 秒の長押しで予約して終了し、次の起動で DB を開く前に消す） |
| #183 | F-96・F-97 | 「初期化して終了」で固まる不具合（Task の中から `terminate`）と、F-94〜F-96 のコードレビューの指摘（予約の段階・結果の表示・終了の返事を main run loop から） |
| #184 | F-98 | README にデータの初期化を足し、RK-28 の文を直す |
| #185 | F-99・F-100 | dmg を開くと背景の上にアプリと Applications が並ぶウィンドウに（ボリューム名は `VoiceDock <版>`）。**v1.0.0 ではなく v0.9.0**（削除のゲートが閉じているため。PLAN §12.4 は緩めない）。README に Releases のリンク |
| #186 | — | `develop` → `main`（v0.9.0） |

- **利用者の環境で行ったこと**（2026-09-25 23:07〜23:35）: 削除を無効に → データを初期化（`data_reset count=79 failed=0`）→ 実機を `VOICEDOCK` に改名 → `config.json` の `includeVolumes` を `["VOICEDOCK"]` に。以前の DB（`DJIMIC3` の行）は残っていない
- **v0.9.0 の公開**（2026-09-26）: `main` に注釈付きタグ `v0.9.0` → `make release`（全テスト・Developer ID 署名・公証 2 回とも Accepted・dmg・verify-bundle すべて OK。ビルド 436）→ `gh release create v0.9.0 --verify-tag`（通常のリリース。プレリリースにすると README の `releases/latest` が指さない）。dmg の SHA-256 は `85d170254c353916e14267931dce9c58f958b0ad5c785971ffd3f2eae74f57e1`（Releases から落とし直して一致を確かめた）
- **v1.0.0 の前に残るもの**: 実機の確認（E2E-13 だけ。E2E-06・R-06・G-5 は 2026-09-30、G-4 は 2026-10-01 に PASS。§1.7・§1.8）→ 削除のゲートが開く → T-44（`docs/RELEASE.md`・`ReleaseChecklistTests`・版を 1.0.0 に）

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

### 2.6 2026-09-25 未明: 削除 ON 10/13 本を実施

`docs/E2E.md` の削除 ON 系のうち、E2E-10・E2E-11・E2E-17・R-01・R-04・R-05 の 6 本を実機（DJIMIC3）で実施し、すべて `✅ PASS`。続けて R-03・R-07・R-08・R-09 の 4 本も実施・PASS（コミット `283076a`。下の箇条書きには無い）。各シナリオの生の出力は `docs/E2E.md` の該当節に記録済み。

- **E2E-10**（削除 ON で通し）: 普通の録音 2 本の元音声が消え、無音の録音は消えないことを確認。`voicedock-reaper` の単体実行 3 パターン（バンドル内起動拒否・`--version`・要求無しでの実行）も期待どおり
- **E2E-11**（過去分の削除。前半のみ）: 17 件の削除要求を一括で書き、全件削除を確認。後半（手動で消した分の完了）は F-63 の合意どおり単体テストで代替
- **E2E-17**（削除を無効化）: クリック1回で即座に無効化・読み取り専用へ再マウント。`reason=lock_mismatch` という、ドキュメントの想定 `reason=delete_source_audio_disabled` とは異なる理由語が出たが、`PLAN.md:1953-1954` の無効化 5 段階（reaper.conf → config の順）のレース窓に起因する正当な挙動と確認した（バグではない。記録に経緯を残した）
- **R-01**（1本を通しで・ON）: `delete_requested` が `raw_note_saved` の直後、`obsidian_saved` を待たずに出ることを確認
- **R-04**（Vault利用不可・ON）: Vault が使えない間は1本も消えず、戻すと再起動なしで自動再開して消えることを確認
- **R-05**（抜き挿し6回・ON）: `request_id` の重複・`reason=replayed` とも0件

作業中に見つかった軽微な手違い（`$BACKUP` の誤設定による退避の二重コピー、`.Trashes/._501` という macOS のゴミ箱メタデータ1件が退避漏れ）はいずれもデバイス側には影響せず、経緯を `docs/E2E.md` §3.10 の記録に残した。

残り: **R-02**（コピー中に抜く。30分×3本の長時間録音＋危険な手順）・**R-06**（1日分。運用の中で確認してよい）・**§5 G-4**（三重ロックを外して24時間）。

### 2.7 2026-09-25 午後: E2E-02・G-1・G-3

- **G-1**（`make test-nd`）・**G-3**（`make test-disk`）: 実機を抜いた状態で、利用者の許可を得てエージェントが実行し、どちらも失敗 0。全出力は `docs/e2e-logs/2026-09-25-make-test-{nd,disk}.txt`、`docs/E2E.md` §4.1・§4.3 には集計の行だけを貼った（出力が 970 KB あり、本文にも PR の本文にも入らないため。利用者の決定）
- **E2E-02**（コピー中に抜く・削除 OFF）: 新しい録音 5 本（約 855 MB）。**抜く合図を「コピー開始から 30 秒」ではなく「最初の `copy_completed`」にした**（利用者の決定）。コピーは毎秒約 12 MB（30 分の 1 本に約 20 秒）で、30 秒待つと空振りのおそれがあった。前後の `diff` は空、`.partial` と取り残しは 0、再接続で 4 本を再コピーして完走
- 削除は E2E-02 の前に**無効にした**（14:57:40 `deletion_disabled`）。いまは OFF のまま
- **E2E-13**（スリープ）は 2 回行い、2 回とも空振り（Claude Code の `caffeinate -ims` の `PreventSystemSleep` でスリープが DarkWake になった。PR #175）。期待 2 と 4 の後半は確認できた。**やり直しは別の日**（Claude Code を終了し、`PreventSystemSleep 0` を確かめてから。手順は `~/VoiceDockE2E-ON/e2e13-retry.md`）
- **R-02**（コピー中に抜く・削除 ON）: 18:19〜19:54 に実施し **PASS**。アプリを止めて退避してから有効化し、4 本目のコピー中に抜いた。消えた `.wav` は今回の 5 本（MIC034〜038）と完全に一致。記録は `docs/E2E.md` §6.2、全出力は `docs/e2e-logs/2026-09-25-r02/`
- 削除は R-02 の後も**有効のまま**（利用者の決定）。E2E-06・R-06（1 日分）は溜まった段階で行う（利用者の決定）

## 3. 利用者の環境

| もの | 場所・値 |
|---|---|
| `.app` の作り方 | `make vendor`（whisper.cpp / llama.cpp）→ `make app` → `dist/VoiceDock.app`（開発用の署名）。配布版は `make release` → `dist/VoiceDock-<版>.dmg`（Developer ID・公証。`main` のタグの上で作業ツリーを clean にして行う） |
| 配布 | **v0.9.0**: https://github.com/shinsuke-terada/voicedock-app/releases/tag/v0.9.0（非公開リポジトリなので招待された人だけ）。いまの `dist/VoiceDock.app` は v0.9.0 の配布版（ビルド 436） |
| 公証 | キーチェーンのプロファイル `VOICEDOCK_NOTARY`（2026-09-26 に利用者が登録し直した。`xcrun notarytool history --keychain-profile VOICEDOCK_NOTARY` で確かめられる） |
| `<HOME>` | `~/Library/Application Support/VoiceDock`（`config.json`・`ui-state.json`・`voicedock.sqlite`・`logs/`・`inbox`・`staging`・`queue`・`bin`・`models`） |
| whisper モデル | `<HOME>/models/whisper/ggml-large-v3-turbo-q5_0.bin`（547 MB） |
| VAD モデル | `<HOME>/models/vad/ggml-silero-v5.1.2.bin` |
| LLM モデル | `<HOME>/models/llm/custom-3605803b982cb64a.gguf`（2.5 GB。4B と同一。`verified: false`）と `Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf`（18.6 GB。カタログから取り込み。**`verified: true`**。2026-09-24） |
| 試験用 Vault | `~/VoiceDockTestVault`（`.obsidian` あり） |
| 退避先 | 2026-09-22〜23 は `~/VoiceDockE2E`（`device-backup`・`check-before.txt`・`check-after.txt`）に固定していたが、2026-09-24 に利用者の決定で `docs/E2E.md`・T-35・T-42 の固定パスを `$BACKUP`（利用者が試験のたびに決める環境変数）へ変えた（PR #150）。この行の値は当時の記録として残す |
| 削除 | **有効**（2026-09-30 02:07:58 に R-06 のために有効にし、利用者の決定でそのまま。`config.json` は `cleanup.deleteSourceAudio=true`・`device.mountMode=rw`、`reaper.conf` は `DELETE_SOURCE_AUDIO=true`、`bin/voicedock-reaper` は 0.9.0。**抜く前に Finder で取り出す**）。以下はそれより前の記録: **無効**（2026-09-25 23:07 にデータの初期化の前に「無効にする」を押した。`config.json` は `cleanup.deleteSourceAudio=false`・`device.mountMode=ro`、`reaper.conf` は `DELETE_SOURCE_AUDIO=false`、`bin/voicedock-reaper` は無い）。それまでは 18:32 から有効だった（R-02） |
| 取り込むデバイスの名前 | **`VOICEDOCK`**。2026-09-25 に利用者が実機を Finder で `VOICEDOCK` に改名し、`config.json` の `device.includeVolumes` を手で `["VOICEDOCK"]` に直して「設定を読み直す」を押した（F-94。アプリの既定も `["VOICEDOCK"]`）。その前にデータを初期化した（F-95。`data_reset count=79 failed=0`）ので、`DJIMIC3` として取り込んだ行は残っていない。控えの `config.json.bak` は F-81 の時点のもの |
| 実機 | E2E の試験でたびたび `/Volumes/VOICEDOCK`（F-94 の改名の前は `/Volumes/DJIMIC3`）に接続する（削除 OFF の間は読み取り専用でマウント）。次のセッションはまず `ls /Volumes` で確かめる |

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
| F-91 | **（利用者の依頼）** 削除が有効な間のメニューバーの印を、横に並ぶ `trash` から状態の記号の右上の赤い点（`StatusIconBadge`）に。画像はテンプレートのまま、パネルの `trash` と表示の条件は変えない | #172 |
| F-92 | **X-46。（利用者の依頼）** 要約プロンプト（analyze / map / reduce）を ⚙ → 「要約プロンプトを編集…」の別の窓で編集できるように。`llm.analysis.prompts.*`（null = 同梱）、`schemaVersion` 3（2 → 3 の移行）、CV-60。D-7 に編集の窓 1 つだけの例外 | #172 |
| F-93 | **（利用者の決定）** 本体のライセンスを Apache License 2.0 に（`LICENSE`・`NOTICE`）。同梱物（whisper.cpp・llama.cpp とその部品・argmax-oss-swift・GRDB・Yams・話者分離のモデル）の著作権表示とライセンス文を `THIRD_PARTY_NOTICES.md` にまとめ、`make-app.sh` が 3 つを `.app` の `Contents/Resources/` に入れる。README を利用者向けに書き直し、`## 開発`・`## 状態` を `docs/DEVELOPMENT.md` へ移した（T-43・T-44 のチケットも合わせた）。issue #139 の残り（実機未確認の文言）は E2E の記録で裏付けが取れた | #176（issue #139） |
| F-94 | **（利用者の依頼と決定）** 取り込むデバイスの名前の既定（`device.includeVolumes`）を `["DJIMIC3"]` から `["VOICEDOCK"]` に。改名は利用者が Finder で行う（アプリは改名しない）。既存の `config.json` は手で直す（移行なし）。⑤と `deviceNameInvalid` の文言、テストの実機の名前の拒否（`VOICEDOCK` も）、セッション開始のフックの実機の検出も合わせた | #179（issue #178） |
| F-95 | **（利用者の依頼と決定）** 「詳細・診断」にデータの初期化。3 秒の長押しで `run/data-reset-requested` を書いて終了し、次の起動で DB を開く前に DB・inbox・staging・transcripts・analysis・queue の要求と結果を消す（設定・モデル・ログ・reaper・Vault は残す）。元音声の削除が有効な間・消す能力が残っている間は押せない。削除は `SafeUnlink`（ルート `database` を足した）だけ | #181（issue #180。#179 の上に積んだ） |
| F-96 | **（F-95 の実機の確認で発見）** 「初期化して終了」で予約の後にアプリが固まった（Task の中から `NSApp.terminate` を直に呼ぶと `.terminateLater` の待ちでデッドロック）。`requestTerminate` を run loop の次の周回で呼ぶように。2026-09-25 の初期化は、固まったアプリを SIGTERM で終えた後の起動で行われた（`data_reset count=79 failed=0`） | #183（issue #182） |
| F-97 | **（F-94〜F-96 のコードレビュー。利用者の決定）** 予約後は終了まで押せない・予約に段階（途中で落ちても続きを行い、消し直さない）・初期化の結果を次の起動のパネルに 1 回出す・終了の返事を main run loop から返す（固まる原因を根本から）・テストの実機の名前の拒否を大文字小文字を問わずに・テストの規則の文言 | #183（issue #182） |
| F-98 | **（利用者の依頼）** README に「データを初期化する」（F-95）を足し、RK-28 の文を「名前を変えると残っている録音をもう一度取り込んで重複になる」に直した。`config.json` を変えた後はつなぎ直すことを「困ったとき」に | #184 |
| F-99 | **（利用者の依頼と決定）** dmg を開くと背景（矢印と案内）の上に左にアプリ・右に Applications が並ぶウィンドウに。ボリューム名は `VoiceDock <版>`（実機の `VOICEDOCK` とぶつけない） | #185 |
| F-100 | **（利用者の決定）** 削除のゲートが閉じたままなので v1.0.0 ではなく **v0.9.0** を先に出す（§12.4 は緩めない）。README に Releases のリンク（非公開なので招待された人だけ）。リリースノート `docs/release-notes/0.9.0.md` | #185 |

## 5. 残っている作業

### 開いている issue

| issue | 中身 | 誰がやるか |
|---|---|---|
| #81 | T-35 実機 E2E（削除 OFF） | 手順書とテストはマージ済み（#82）。**12/16 本が PASS**（2026-09-24 夜に E2E-01・03・04・05・07・08・09・12・14・16、2026-09-25 に E2E-02、2026-09-30 に E2E-06）。残り: E2E-13（スリープ。削除 OFF で行う） |
| #95 | T-42 実機 E2E（削除 ON）とゲート | 手順書とテストはマージ済み（#96）。**実施は【利用者が行う】**。**13/13 本が PASS**（2026-09-25 未明に E2E-10・11・17・R-01・03・04・05・07・08・09、18 時台に R-02、2026-09-30 に R-06）と **§5 G-4 も PASS**（2026-10-01）。削除は 2026-09-30 02:07:58 から**有効**（§3）。`docs/E2E.md` §4 のゲートは G-1・G-3・G-4・G-5 が PASS、G-2（E2E-13 待ち）だけが未実施で **ゲート: 閉** |
| #103 | Bluetooth 接続での読み込みと削除の調査・実験 | **2026-09-26 に実施（P0-14。`docs/POC.md` 17 章）。✗ FAIL**: DJI Mic 3 の BLE はペアリング・機器情報・送信機の Wi-Fi の接続情報の受け渡しだけで、ファイルの一覧・取得は Wi-Fi、DJI Mimo には削除が無い。**Bluetooth のみでのファイル操作はできない**。Wi-Fi の経路を調べるかは利用者の判断（別の計画） |

**2026-09-24 に閉じた issue**: #67（T-24。30B が `verified: true` に。v1.0 で選べる LLM が 1 つ以上になった）、#77（T-34。`make release` が通り、署名・公証・dmg まで確認済み）。

PR がマージされても issue が開いたままなのは、**実機・実モデルでの確認がその issue に残っている**ため。

### T-43 と T-44 の前提

- **T-43（README）** — **完了（PR #140。2026-09-24）**。F-93 で README を利用者向けに書き直し、ライセンスを置いた（issue #139 は閉じた）。F-98・F-100 でデータの初期化と Releases のリンクを足した
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

1. `git fetch origin && git switch develop && git pull`（`main` は v0.9.0。次に `main` へ入れるのは v1.0.0 のとき）
2. `ls /Volumes` で**実機（`VOICEDOCK`）の接続状態**と、§3 の「削除」の行の状態（いまは**有効**。抜く前に Finder で取り出す）を確かめる。ディスクを触る作業（`make test-disk`・`make release`・dmg の作成）の前には利用者に抜いてもらう
3. `python3 docs/porting-notes/check-tickets.py` が 0 件、`make lint && make test` が緑であることを確かめる
4. `gh pr list --state open` で開いている PR が無いことを確かめる
5. **残っている実機作業は E2E（issue #81 → #95）とゲート**:
   - 削除 OFF: **E2E-13**（スリープ。Claude Code を終了し `PreventSystemSleep 0` を確かめてから。手順は `~/VoiceDockE2E-ON/e2e13-retry.md`）。削除を無効にしてから行う。これが PASS すると G-2 が満たされる
   - データを初期化し実機を `VOICEDOCK` に改名したので、E2E の手順の `$DEV` は `VOICEDOCK`
6. ゲートが開いたら T-44（v1.0 リリース）: 版を 1.0.0 に上げる PR → `develop` → `main` → タグ `v1.0.0` → `make release` → Releases
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
- テスト用のディスクイメージのボリューム名に実機の名前 `VOICEDOCK`・`DJIMIC3` を使わない（`DiskImageVolume` がコードで拒む）
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
| `docs/PLAN.md` | 計画書 v1.1（3,100 行）。**最上位**。付録 A = 状態・エラー・ログ、B = ND / RV / E2E、D = voicedock との差分（X-01〜X-46）、F = 改訂（F-01〜F-93） |
| `docs/tickets/00-api-map.md` | モジュールをまたぐ名前の契約。**チケットより上位** |
| `docs/tickets/README.md` | 共通規約・チケットの形（10 節）・依存順の目次 |
| `docs/tickets/T-*.md` | 実装の詳細仕様（45 本） |
| `docs/SPEC.md` | PLAN から `make spec` で生成する機械可読の仕様（S1〜S23）。手で書かない |
| `docs/E2E.md` | **実機手順の正本**（issue や PR 本文に手順を置かない）。§4 が削除のゲート |
| `docs/POC.md` | Phase 0 の**実測の記録**。PLAN と食い違ったら実測が正で、PLAN とチケットを直す |
| `docs/porting-notes/V1〜V7・R1・R2` | voicedock の移植メモと独立レビュー |
| `docs/porting-notes/check-tickets.py` | チケット一式の機械検査 |
