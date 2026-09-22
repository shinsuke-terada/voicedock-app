# 進捗と再開の手順（2026-09-23 時点。**実装中**）

**この文書だけ読めば再開できる**ように書いてある。次のセッションはここから始める。

## 1. いまの状態

| 区分 | 数 |
|---|---|
| チケット（T-01〜T-45） | 45 本 |
| マージ済み | **42 本** |
| 取り下げ | 1 本（T-33。PLAN F-60） |
| 残り | 2 本（T-43 README、T-44 v1.0 リリース） |

`develop` の先頭は `0026249`（PR #110 のマージ）。マージ済みの PR は 59 本。

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
| T-13 | #47 | T-28 | #49 | T-43 | **未着手** |
| T-14 | #53 | T-29 | #66 | T-44 | **未着手** |
| T-15 | #57 | T-30 | #73 | T-45 | #10 |

T-35（削除 OFF）と T-42（削除 ON）は**手順書とテストがマージ済み**で、**実機での実施が残っている**。

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

> **注意**: 本体のチェックアウトの `dist/VoiceDock.app` は古いことがある（実機の確認は、その時々の worktree で組んだ `.app` で行った）。実機に触る前に、必ず develop で `make app` を回し直してから使う。
> 次に実機で触る前に `make app` で組み直す。

## 3. 利用者の環境

| もの | 場所・値 |
|---|---|
| `.app` の作り方 | `make vendor`（whisper.cpp / llama.cpp）→ `make app` → `dist/VoiceDock.app` |
| `<HOME>` | `~/Library/Application Support/VoiceDock`（`config.json`・`ui-state.json`・`voicedock.sqlite`・`logs/`・`inbox`・`staging`・`queue`・`bin`・`models`） |
| whisper モデル | `<HOME>/models/whisper/ggml-large-v3-turbo-q5_0.bin`（547 MB） |
| VAD モデル | `<HOME>/models/vad/ggml-silero-v5.1.2.bin` |
| LLM モデル | `<HOME>/models/llm/custom-3605803b982cb64a.gguf`（2.5 GB。ファイルから取り込み） |
| 試験用 Vault | `~/VoiceDockTestVault`（`.obsidian` あり） |
| 退避先 | `~/VoiceDockE2E`（`device-backup`・`check-before.txt`・`check-after.txt`） |
| 削除 | **有効**（利用者が意図して有効化。`<HOME>/bin/reaper.conf` は `DELETE_SOURCE_AUDIO=true`、`config.json` は `cleanup.deleteSourceAudio=true`・`deleteSkippedSource=true`） |
| 実機 | いまは未接続（`ls /Volumes` は `Macintosh HD` のみ） |

## 4. 2026-09-22〜23 に利用者が決めたこと

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

## 5. 残っている作業

### 開いている issue

| issue | 中身 | 誰がやるか |
|---|---|---|
| #67 | T-24 カタログの確定と LLM 受け入れ試験 | 実装はマージ済み（#68）。**受け入れ試験の実行と `verified` の更新が残り**（`make llm-acceptance`）。実機のモデルで回すので**利用者と一緒に** |
| #77 | T-34 `.app` の組み立て・署名・公証・dmg | スクリプトはマージ済み（#78）。**Developer ID での署名と公証の確認は【利用者が行う】**（TEAM_ID `ZCWP35H248`） |
| #81 | T-35 実機 E2E（削除 OFF） | 手順書とテストはマージ済み（#82）。**実施は【利用者が行う】**（`docs/E2E.md` §2） |
| #95 | T-42 実機 E2E（削除 ON）とゲート | 手順書とテストはマージ済み（#96）。**実施は【利用者が行う】**。`docs/E2E.md` §4 のゲート G-1〜G-5 はいま全部「未実施」で **ゲート: 閉** |
| #103 | Bluetooth 接続での読み込みと削除の調査・実験 | **v1.0 の後**。調査はエージェント、実験は【利用者が行う】 |
| #104 | 文字起こしの話者分離 | **v1.0 の後**。方式の調査から |

PR がマージされても issue が開いたままなのは、**実機・実モデルでの確認がその issue に残っている**ため。

### T-43 と T-44 の前提

- **T-43（README）** — 前提は T-42。「README に書く文言を実機で確かめてから書く」。作るのは `README.md`（約 290 行）と `Tests/PolicyTests/ReadmeTests.swift`（散文の数字と参照が腐らないことを機械で守る）
- **T-44（v1.0 リリース）** — 前提は T-43・T-42・T-34。`docs/RELEASE.md`・`docs/release-notes/TEMPLATE.md`・`ReleaseChecklistTests.swift`、`VERSION` と `AppVersion.string` を `1.0.0` へ（同じ PR で両方）。**削除のゲートが開いていないと出せない**

### Phase 0 の残り

`docs/POC.md`: P0-01・02・03・12 は PASS、P0-10 は対象外。**P0-04〜07・09・11 は未実施**（whisper / llama の実測、SMAppService の P0-08 も未実施）。実機での一通りが動いたので、必要なものだけ拾えばよい。

## 6. 次のセッションで最初にやること

1. `git fetch origin && git switch develop && git pull`（先頭が `0026249` より進んでいないか確かめる）
2. `ls /Volumes` で**実機が挿さっていないこと**を確かめる。挿さっていたら、ディスクを触る作業の前に利用者に抜いてもらう
3. `python3 docs/porting-notes/check-tickets.py` が 0 件、`make lint && make test` が緑であることを確かめる
4. どちらへ進むかを利用者に聞く
   - **(A) 実機試験を進める** — `make vendor && make app` で `dist/VoiceDock.app` を最新にしてから、`docs/E2E.md` §2（削除 OFF・E2E-01〜09）→ §6（削除 ON）→ §4 のゲートを、**手順を提示して利用者に渡す**形で進める。結果は `docs/E2E.md` に貼る。issue #81 → #95 の順
   - **(B) T-43（README）に着手** — 前提は T-42 の実機実施だが、**文言の骨組みは先に書ける**。実機で確かめる数字（診断の件数・削除の手順）だけ後から埋める合意を利用者から取る
5. どちらでもないときは `/next-tickets` ではなく**利用者に聞く**（残りが 2 本なので並列にする意味はもう無い）

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
- 削除まわりで Part が詰まる経路は F-64（一覧に無い）と F-69（一覧に在るが消せない）で塞いだ。**新しい設定キー・遷移の辺・ログのイベントを増やさずに**塞ぐのが方針
- `ui-state.json` の `schema` は 1 のまま。**足す鍵は任意**にして、古い読み手が未知の鍵として無視できるようにする（F-70）

## 9. 文書の地図

| 文書 | 役割 |
|---|---|
| `docs/PLAN.md` | 計画書 v1.1（3,100 行）。**最上位**。付録 A = 状態・エラー・ログ、B = ND / RV / E2E、D = voicedock との差分、F = 改訂（F-01〜F-70） |
| `docs/tickets/00-api-map.md` | モジュールをまたぐ名前の契約。**チケットより上位** |
| `docs/tickets/README.md` | 共通規約・チケットの形（10 節）・依存順の目次 |
| `docs/tickets/T-*.md` | 実装の詳細仕様（45 本） |
| `docs/SPEC.md` | PLAN から `make spec` で生成する機械可読の仕様（S1〜S23）。手で書かない |
| `docs/E2E.md` | **実機手順の正本**（issue や PR 本文に手順を置かない）。§4 が削除のゲート |
| `docs/POC.md` | Phase 0 の**実測の記録**。PLAN と食い違ったら実測が正で、PLAN とチケットを直す |
| `docs/porting-notes/V1〜V7・R1・R2` | voicedock の移植メモと独立レビュー |
| `docs/porting-notes/check-tickets.py` | チケット一式の機械検査 |
