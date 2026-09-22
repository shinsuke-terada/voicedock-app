# VoiceDock for Mac（Swift ネイティブ版）実装計画 v1.1

> **この文書は別リポジトリでの実装に使う。**実装者はこの計画と、参照実装 voicedock（固定コミット）
> だけを根拠に作業する。本書と voicedock が食い違うときの優先順位は §0.3 にある。
>
> **使い方:** 新リポジトリの `docs/PLAN.md` にこの文書をそのままコピーし、§12.2 の Phase 0 → §12.3 の T-01 から順に進める。
> 1 タスク = 1 PR（§12.1）。迷ったら §1.4 の優先順位と §9.1 の 2 原則に戻る。
> 各タスクの詳細仕様（ファイル・型・関数・テスト名まで）は `docs/tickets/T-nn-*.md` にある。**チケットと本書が食い違うときは本書が正**で、食い違いを見つけたら両方を同じ PR で直す。
>
> **v1.1（2026-09-18）:** 参照実装 voicedock@d3d595e と全節を突き合わせ、誤り・欠落・曖昧さを直した。変更の一覧は付録 F。

---

## 0. 読み方と前提

### 0.1 Context（なぜ作るか）

voicedock は「DJI Mic 3 を Mac に挿すだけで、文字起こしと要約を Obsidian に残す」仕組みである。
Docker（ffmpeg / whisper.cpp CPU / Python）＋ホスト側 bash Helper ＋ Docker Model Runner で動いている。
これを **Docker 不要の macOS アプリ（.dmg 配布、将来は有償）** にする。

- 利用者の手順を「アプリを入れて、録って、挿す」だけにする
- whisper.cpp を Metal で動かして速くする（voicedock の CPU 実測 RTF は 1.04〜1.55）
- LLM（Qwen）は利用者が一覧から選び、自分でダウンロードする
- Obsidian に書くノートは voicedock と**バイト単位で同じ形式**にする（同じ Vault で乗り換えられる）

voicedock は 1,500 本超のテストと 56 版の仕様改訂で、多くの失敗を経験済みである。
**本計画の目的の半分は、その失敗を新実装で繰り返さないこと**にある（§9 と付録 C）。

### 0.2 決定済み事項（利用者が決めた。再論しない）

| # | 事項 | 決定 |
|---|---|---|
| D-1 | 実装方式 | **Swift で書き直す。**voicedock のコードは移植しない。仕様・テスト ID・教訓の参照元として使う |
| D-2 | 元音声の自動削除 | **v1 に含める**（三重ロック・ND テスト群ごと移植する） |
| D-3 | ノート形式 | **voicedock と同一**（Raw / Daily の 2 枚、パス、frontmatter） |
| D-4 | 課金 | **v1 には入れない**（無償配布）。将来の差し込み口だけ残す（§8.14） |
| D-5 | ロック 2-A | **reaper を .app に同梱し、有効化フローで `bin/` へ複製したときだけ実行可能にする**（§8.9） |
| D-6 | CI | **開発機のセルフホストランナー**（非公開リポジトリ。GitHub の macOS ランナーは分数が 10 倍のため。2026-09-21 利用者の決定。§10.8） |
| D-7 | 画面 | **起動するとメニューバーにアイコンが出て、バックグラウンドで動く。アイコンを押すと設定パネルが出る。**それ以外の画面は作らない（§8.12） |
| D-8 | voicedock 本体 | **変更しない。**参照のみ |

### 0.3 参照実装と優先順位

- 参照実装: `/Users/terada/Projects/voicedock`（GitHub: `shinsuke-terada/voicedock`、公開）
- **固定コミット: `d3d595e`**（SPEC v5.56）。以後の voicedock の変更は追わない
- 読み方: 作業ツリーではなく必ず固定コミットから読む
  ```bash
  git -C /Users/terada/Projects/voicedock show d3d595e:docs/SPEC.md
  git -C /Users/terada/Projects/voicedock show d3d595e:src/voicedock/daily.py
  ```
- **voicedock の作業ツリーに書き込まない。**golden 生成も `git archive` で一時ディレクトリへ展開して行う（§10.4）

食い違ったときの優先順位:

| 対象 | 正とするもの |
|---|---|
| Obsidian ノートのバイト列・パス・frontmatter | **voicedock の実装**（SPEC の例ではない。SPEC の例は一部の値だけ引用符付きで、Sources に別名付きリンク、Timeline に Raw へのリンクがあるが、どれも実装と違う）。golden で固定する |
| 内部 JSON（transcript・analysis・timeline・指紋）の書式 | **voicedock の実装**（Python `json.dumps` と同じ書式。§5.7） |
| 削除の安全条件・ロック | **本計画**（voicedock の既知の穴を塞いである。§8.9 / 付録 C-DEL） |
| 状態機械・エラーコード・リトライ | **本計画の付録 A**（voicedock 実装 + 本計画の意図的な差分） |
| それ以外 | 本計画 → voicedock 実装 → voicedock SPEC の順 |

### 0.4 用語

| 語 | 意味 |
|---|---|
| Part | デバイス上の録音ファイル 1 本（`_orig.wav`）。DB の `recordings` 1 行 |
| Session | 1 デバイス × 1 日の Part の集まり。DB の `sessions` 1 行。ノート 2 枚に対応 |
| partkey | `<device_id>/<relpath>`。ノートの frontmatter に載る恒久キー |
| device_id | デバイスのマウント点 `/Volumes/<name>` の basename（例 `DJIMIC3`）。ボリューム名と一致しないものは取り込まない（§8.1 規則 8） |
| inbox | デバイスから吸い出したコピーの置き場 |
| staging | 16 kHz 変換後の音声などの作業領域 |
| reaper | デバイス上のファイルを削除できる**唯一の**プログラム `voicedock-reaper` |
| snapshot | ある時点のデバイス観測（マウント・読み取り専用か・ファイル一覧）。世代番号付き |

### 0.5 ID の接頭辞（体系ごとに一意。voicedock では R-/N-/D- が衝突していた）

| 接頭辞 | 体系 | voicedock での対応 |
|---|---|---|
| `CV-nn` | 設定の検証 | V-nn（**意味が同じものだけ同じ番号**で継承。キーを廃止した V・意味を変えた V は欠番。新規は CV-39 と CV-40 以降。§6.4） |
| `ND-nn` | 削除禁止テスト | ND-nn（**番号をそのまま引き継ぐ**。ND-10〜17・ND-30 は欠番。ND-36 以降は本計画で新設） |
| `RV-nn` | reaper の検証項目 | reaper 検証 1〜12（対応表は付録 B.2） |
| `RN-n` / `DN-n` | Raw / Daily ノートの保存検証 | R-n / W-n |
| `SN-n` | ファイル名 sanitize | S-n |
| `PR-nn` | 実装上の禁止事項（静的検査で強制） | N-nn |
| `PT-nn` | 静的ポリシーテスト | AST テスト群 |
| `DR-nn` | 診断（doctor） | D-nn / DH-nn |
| `E2E-nn` | 実機試験 | E2E-nn |
| `P0-nn` | Phase 0 の実機 PoC | P0-nn |
| `T-nn` | 実装タスク（= 1 PR） | issue |
| `RK-nn` | リスク | R-nn |
| `F-nn` | 本書の改訂項目（付録 F） | — |

**廃止した番号は詰めない・再利用しない。**
（注）`PR-nn` は「実装上の禁止事項」の ID であり、プルリクエストを指すときは「PR」と単独で書き番号を付けない。

---

## 1. 製品仕様（v1）

### 1.1 利用者から見た動き

```text
初回:  アプリを起動 → メニューバーにアイコン → パネルの「はじめに」を上から順に済ませる
        （Vault を選ぶ → Whisper モデルを入手 → LLM を選んで入手 → ログイン時に起動）
日常:  DJI Mic 3 で録音 → Mac へ USB 接続 → 以降すべて自動
        取り込み（コピー）が終われば抜いてよい。処理はコピーから続く
結果:  Vault の Daily/Voice/Raw/<yyyymmdd>/<date> raw.md と Daily/Voice/Wiki/<yyyymmdd>/<date> Voice.md
```

### 1.2 v1 に含める

- メニューバー常駐（Dock に出ない）。ログイン時起動（利用者が選ぶ）
- デバイス検出・読み取り専用での再マウント・安定性判定・inbox へのコピー（SHA-256 付き）
- 16 kHz 変換（AVFoundation。ffmpeg を使わない）
- whisper.cpp（Metal）による文字起こし（VAD 必須）
- llama.cpp `llama-server`（Metal）による要約・タスク抽出（Map-Reduce）
- Raw / Daily ノートの生成（voicedock と同一形式）・保存検証
- 状態管理・クラッシュ復旧・再試行（SQLite）
- 元音声の削除（三重ロック。既定はすべて掛かった状態）
- モデル管理（Whisper / VAD / LLM の選択・ダウンロード・SHA-256 検証・ローカルファイル取り込み）
- 診断（パネルの「診断を実行」）

### 1.3 v1 に含めない（非目標）

課金・ライセンス認証、自動アップデート、通知センター、話者識別、送信機 2 台の実機保証（コードは複数台を扱う）、
受信機側ストレージ、Mac App Store 配布（サンドボックス下で 2-B が成立するか未検証）、Intel Mac、voicedock からの乗り換え（§8.13。F-60）、voicedock との同時稼働（F-61）。

### 1.4 判断が割れたときの優先順位（voicedock §1.3 を継承）

**記録の保護 ＞ 継続性 ＞ 再実行性 ＞ 二重処理防止 ＞ 自動化 ＞ 文字起こし精度 ＞ 要約精度**

「録音を失わない」がすべてに優先する。消してしまった録音は戻らない。

### 1.5 動作環境

- macOS **15.0 以上**、**Apple Silicon のみ**（arm64）
- メモリ: LLM の選択肢がメモリ量で決まる（§8.10）。既定モデル（Qwen3-30B-A3B Q4_K_M、約 18.6 GB）は 32 GB 以上
- ディスク: モデル（Whisper 約 0.6 GB ＋ LLM 2.5〜19 GB）＋作業領域数 GB

---

## 2. アーキテクチャ

### 2.1 プロセス構成

```text
VoiceDock.app（常駐・非サンドボックス・Hardened Runtime）
 ├─ UI: NSStatusItem + NSPopover（SwiftUI の PanelView をホスト）       … MainActor
 ├─ IngestService（actor）: マウント監視・走査・安定性判定・コピー・再マウント・snapshot
 ├─ Worker（actor）: 状態機械を 1 本の直列ループで回す（Part → Session → 削除）
 ├─ LlamaServerSupervisor（actor）: llama-server の起動・停止
 ├─ ModelManager（actor）: モデルの一覧・ダウンロード・検証
 └─ Store: GRDB DatabasePool（WAL）
       │ posix_spawn（新しいプロセスグループ。responsible process はアプリのまま）
       ├─ Contents/Helpers/whisper-cli        （Metal、静的リンク）
       ├─ Contents/Helpers/llama-server       （Metal、静的リンク、curl 無効、127.0.0.1 のみ）
       └─ ~/Library/Application Support/VoiceDock/bin/voicedock-reaper
             ↑ 有効化フローで Contents/Helpers/voicedock-reaper から複製したときだけ存在（ロック 2-A）
```

- **whisper と LLM を同時に走らせない**（Worker が直列。LLM-15）。診断 DR-09 の LLM 実リクエストも Worker の直列ループに 1 件の仕事として入れる（§8.11）
- **llama-server は解析が要るときに初めて起動し、`processReadySessions` の終わりで必ず止める**（18 GB を常駐させない。次の tick の Part 工程とは重ならない）
- デバイス上のファイルを削除できるのは reaper だけ（PR-16）。アプリ本体はデバイス上のファイルを unlink するコードを持たない（`SafeUnlink` は `<HOME>` と Vault の tmp だけ。CR-10）
- reaper は実行中ずっと `<HOME>/state/reaper.lock` に排他の `flock` を掛ける（`LOCK_EX | LOCK_NB`。取れなければ何もせず終了コード 4）。IngestService は走査の前に同じロックを取る（`LOCK_NB` を 1 秒ごとに最大 130 回試す）。アプリが落ちて reaper だけが生き残った場合も「reaper の後の観測」を保証する（§8.9.6）。ロックは `FileLock`（VDContract）だけが扱い、ファイルが無ければ作る（0644）
- **actor の中で長い同期処理をしない**: コピー・ハッシュ・16 kHz 変換・ディレクトリ走査のような数秒以上かかる同期 I/O は `BlockingIO.run { … }`（VDCore。専用の並行 DispatchQueue で実行し continuation で待つ）で行い、actor は状態だけを持つ。子プロセスの終了は `DispatchSource.makeProcessSource(identifier:eventMask: .exit)` と continuation で待ち（kqueue の登録より前に終わった子を取りこぼさないよう、`waitpid(WNOHANG)` の予備のタイマー（DispatchSourceTimer）も併用する。T-12）、`waitpid` で actor を止めない（whisper の実行中に diskutil が待たされないようにする）

### 2.2 voicedock の構成要素との対応

| voicedock | 本アプリ | 備考 |
|---|---|---|
| Helper `voicedock-ingest`（bash、LaunchAgent） | `IngestService` | 起動契機は NSWorkspace のマウント通知＋周期走査 |
| `.meta.json`（墓標） | `recordings` の行（`source_size` / `source_mtime` / `sha256_helper`） | **デバイス上の原本の値だけを入れる**（DEL-12） |
| `inventory.json` | `DeviceSnapshot`（メモリ内、**世代番号付き**） | 同じ秒問題（#182）を構造的に消す（§8.9.6） |
| `heartbeat.json` | 不要（同一プロセス）。「最終走査時刻」を snapshot が持つ | H-8 相当は「沈黙の検出」として §8.11 |
| コンテナの `worker.py` | `Worker` | tick の順序は §5.4 |
| `voicedock-reaper`（bash） | `voicedock-reaper`（Swift 実行ファイル） | 既知の穴を塞ぐ（§8.9.4） |
| `helper.conf` | `bin/reaper.conf`（reaper 側のロック 1）＋ `config.json`（アプリ設定） | |
| ffmpeg / ffprobe | AVFoundation | |
| Docker Model Runner | `llama-server` | OpenAI 互換 `chat/completions` を維持 |
| `make status` / `doctor` | パネルの状態表示 / 「診断を実行」 | |
| `make enable-deletion` | パネルの有効化フロー（赤いボタンの 3 秒長押し。F-65） | |
| `cleanup --backlog` / `--resolve-absent` | パネルの「過去分を削除対象にする」「手動で消した分を完了にする」（どちらもプレビュー付き） | |

**廃止するもの（Docker 由来）:** VirtioFS 回避、`/Users` 配下要件、compose、named volume、bind mount の inode 問題、
bash 3.2 互換、C ランチャ（ただし「responsible process を保つには posix_spawn」の教訓は残す）、tini。

### 2.3 実行時のデータ配置

`~/Library/Application Support/VoiceDock/`（以下 `<HOME>`。voicedock の `~/VoiceDock` とは別の場所なので衝突しない）

```text
<HOME>/
├── config.json                      # AppConfig（アプリが書く。§6）
├── voicedock.sqlite (+ -wal, -shm)  # §7
├── inbox/<device_id>/<folder>/<name>_orig.wav      # コピー（NORMALIZED 後に削除）。ボリューム直下の録音は inbox/<device_id>/<name>
├── inbox/<device_id>/<folder>/.<name>_orig.wav.partial  # コピー中
├── staging/<slug>/audio16k.wav(.tmp), whisper.json  # 作業領域（slug = partkey の key_slug）
├── transcripts/parts/<slug>.json    # 正規化 transcript。**無期限保持**（削除根拠 A の 2 つ目のコピー）
├── analysis/<session_slug>.json, <session_slug>.timeline.json, <session_slug>.source.json
├── queue/delete/<request_id>.json   # 削除要求（アプリが書き、reaper が消す）
├── queue/result/<request_id>.json   # 削除結果（reaper が書き、アプリが消す）
├── queue/rejected/<name>            # ファイル名・request_id が不正な要求（reaper が移す）
├── state/processed.log              # reaper のリプレイ防止（reaper だけが書く。1 行 1 request_id）
├── state/reaper.lock                # reaper の実行中ロック（flock。§2.1）
├── run/llama-api-key                # llama-server の起動ごとの API キー（0600。起動のたびに書き直す。§8.5）
├── ui-state.json                    # パネルの状態（「はじめに」のログイン項目の選択・最終接続。§8.12。F-70）
├── bin/voicedock-reaper, bin/reaper.conf   # **既定では存在しない**（ロック 2-A）
├── models/whisper/, models/vad/, models/llm/, models/.<file>.resume, models/<kind>/.<file>.part
└── logs/app.log(.1), logs/reaper.log(.1)
```

- `<HOME>` と Vault 以外には書かない（PR-03）
- パスは DB に `<HOME>` からの相対 POSIX パスで持つ（ノートは Vault からの相対）
- `<HOME>` 配下のパスはすべて `HomeLayout`（VDContract。アプリと reaper が共有）の計算プロパティから得る。パス文字列を他で組み立てない

---

## 3. リポジトリとツールチェーン

### 3.1 固定する識別子（Phase 0 で決め、初回リリース後は変更禁止）

| 名前 | 値 | 変えると何が起きるか |
|---|---|---|
| 製品名 | `VoiceDock` | — |
| `BUNDLE_ID` | 候補 `io.github.shinsuke-terada.VoiceDock`（T-01 で確定） | TCC の許可・ログイン項目・設定の場所がすべて失われる |
| reaper の識別子 | `<BUNDLE_ID>.reaper` | 署名検証（§8.9.3）が通らなくなる |
| `TEAM_ID` | Apple Developer Program のチーム ID | 同上 |
| `<HOME>` | `~/Library/Application Support/VoiceDock` | 既存データを見失う |

**前提:** Apple Developer Program への加入（Developer ID 署名と公証に必須）。

### 3.2 リポジトリ

- 新規の**非公開**リポジトリ（名前の候補 `voicedock-app`）。既定ブランチ `main`、作業は `develop` へ PR
- **ビルドは SwiftPM だけで行う。**Xcode プロジェクト（`.xcodeproj`）は作らない。`.app` はスクリプトで組み立てる（§11.1）
  - 理由: すべてがテキストで差分が読める。`swift build` / `swift test` が CI でそのまま動く。生成物の食い違いが起きない

```text
voicedock-app/
├── Package.swift / Package.resolved   # Package.resolved はコミットする
├── VERSION                            # 例 1.0.0（唯一の出所。Version.swift はテストで一致を確かめる）
├── .xcode-version                     # 使う Xcode の版（CI と揃える）
├── .swift-format                      # 整形規則
├── Makefile
├── Sources/
│   ├── VDContract/      # アプリと reaper が共有する唯一のモジュール（Foundation と Darwin のみ）
│   ├── VDCore/          # ドメイン: 状態・遷移・設定・エラー・鍵・分組・削除条件・時計・ログ
│   ├── VDStore/         # GRDB。スキーマ・マイグレーション・recordPartTransition / recordSessionTransition
│   ├── VDProcess/       # 子プロセス実行（posix_spawn・プロセスグループ・タイムアウト）
│   ├── VDDevice/        # マウント監視・走査・安定性判定・コピー・再マウント・snapshot
│   ├── VDAudio/         # AVFoundation による検査と 16 kHz 変換
│   ├── VDTranscribe/    # whisper-cli の起動と出力の正規化
│   ├── VDLLM/           # llama-server の管理・ループバック HTTP・スキーマ・Map-Reduce・修復
│   ├── VDNotes/         # sanitize・frontmatter・Raw/Daily レンダリング・atomic write・保存検証・WikiLink
│   ├── VDPipeline/      # Worker・各工程（ensure_*）・削除要求・結果回収・reaper の起動
│   ├── VDModels/        # モデル一覧・ダウンロード（**インターネットに出る唯一のモジュール**）
│   ├── VoiceDockApp/    # 実行ファイル。AppKit + SwiftUI の UI
│   └── voicedock-reaper/  # 実行ファイル。VDContract にだけ依存
├── Resources/
│   ├── prompts/analyze_ja.txt, map_ja.txt, reduce_ja.txt, repair_json_ja.txt
│   ├── ModelCatalog.json
│   └── AppIcon.icns, Info.plist.template, VoiceDock.entitlements, reaper.entitlements
├── Tests/
│   ├── VDContractTests/ VDCoreTests/ VDStoreTests/ VDProcessTests/ VDDeviceTests/ VDAudioTests/
│   ├── VDTranscribeTests/ VDLLMTests/ VDNotesTests/ VDPipelineTests/ VDModelsTests/ VoiceDockAppTests/
│   ├── NoDeleteTests/       # ND（アプリ層）
│   ├── ReaperTests/         # ND（reaper 層）。reaper 実行ファイルを実際に起動する
│   ├── PolicyTests/         # PT（静的検査）・SPEC 同期・文書テスト
│   ├── TestSupport/         # 偽 whisper・偽 LLM 転送・BWF 生成・偽ボリューム・固定時計（Package.swift では通常の `.target`。テストターゲットから依存する）
│   ├── LLMAcceptance/       # 本物のモデルで回す受け入れ試験（§10.6。CI では走らせない）
│   └── Golden/              # voicedock から生成した期待値（§10.4）
├── Vendor/
│   ├── build-whisper.sh, build-llama.sh   # 固定した版をソースからビルド（成果物はコミットしない）
│   └── versions.env                       # WHISPER_CPP_REF / LLAMA_CPP_REF と、取得物の SHA-256
├── tools/golden/generate.sh, generate.py  # voicedock@d3d595e から golden を作る
├── tools/unicode/CaseFolding-15.0.0.txt, gen-casefold.py  # casefold 表の生成元（§5.7。生成物 VDCore/PyCaseFoldTable.swift はコミットする）
├── scripts/make-app.sh, sign.sh, notarize.sh, make-dmg.sh, release.sh, verify-bundle.sh
├── docs/SPEC.md        # 規範の表（付録 A〜B を移したもの）。テストが parse して実装と突き合わせる
├── docs/PLAN.md        # 本計画の写し（設計の理由）
├── docs/tickets/       # タスクごとの詳細仕様（T-nn-*.md）
├── docs/POC.md         # Phase 0 の実測（コマンドと生の出力をそのまま貼る）
├── docs/RELEASE.md     # リリースの手順と確認表（T-44）
├── docs/release-notes/ # 版ごとのリリースノート
├── docs/E2E.md         # 実機試験の手順と結果
└── .github/workflows/ci.yml
```

Makefile のターゲット（CI と手元で同じコマンドを使う）:

| ターゲット | 中身 |
|---|---|
| `make lint` / `make fmt` | `swift format lint --strict --recursive Sources Tests` / `swift format --in-place --recursive Sources Tests` |
| `make test` | CI の `check` と同じ順（ND → policy → 残り） |
| `make test-disk` | `VOICEDOCK_DISK_TESTS=1` を付けて `.diskImage` のテストを含めて全部（`swift test` はタグで絞れないため、環境変数と `.enabled(if:)` で有効化する。§10.1） |
| `make vendor` | `Vendor/build-*.sh`（whisper-cli と llama-server） |
| `make app` | `scripts/make-app.sh debug`（Apple Development 署名） |
| `make golden` | `tools/golden/generate.sh`（ホストの `uv` と voicedock のローカルの clone が要る。Docker は不要） |
| `make llm-acceptance MODEL=<id>` | §10.6 |
| `make release` | §11.3 の全手順 → `verify-bundle.sh` |

### 3.3 ツールチェーンと依存（すべて固定）

| 項目 | 固定の仕方 |
|---|---|
| Xcode / Swift | `.xcode-version` に 1 つ書く。**2026-09-18 時点: `27.0`（27A266a、Swift 6.4）**。CI も同じ版（§10.8）。CI は `sudo xcode-select -s /Applications/Xcode_<ver>.app` |
| Package の tools-version | `// swift-tools-version: 6.2`（`treatAllWarnings` のため） |
| 言語モード | Swift 6（`swiftLanguageModes: [.v6]`）、strict concurrency complete。警告はエラー（自分のターゲットに `.treatAllWarnings(as: .error)`。依存には掛けない） |
| デプロイ対象 | `.macOS("15.0")`、arm64 のみ |
| サードパーティ依存 | **2 つだけ**: `GRDB.swift`（SQLite。`exact: "7.11.1"`）、`Yams`（frontmatter の**読み取り**だけ。書き出しは自前。`exact: "6.2.2"`）。T-01 で最新の版を確かめて `exact:` で固定する |
| 整形・lint | ツールチェーン同梱の `swift format`（`swift format lint --strict --recursive Sources Tests`。**存在しないパスを渡しても 0 で終わる**ので Makefile は先に両ディレクトリの存在を確かめる） |
| whisper.cpp | **`v1.9.4`**（voicedock と同じ。コミット `927cfce34f31707e17f2bff35c349632fb9e2c3a`。voicedock が記録した `7d75b149…` は注釈付きタグのオブジェクトの SHA）。偽 whisper の JSON 形がこの版に合わせてある |
| llama.cpp | T-03 時点のリリースタグ 1 つ（`b<番号>`。2026-09-18 時点の最新は `b11033`、コミット `8ed1a55efcd7424d2c592f6cbc9f97756db1d74d`）。`Vendor/versions.env` に記録 |
| GitHub Actions | action は**コミット SHA で固定**（タグは付け替えられる）。ランナーのラベルも固定（`latest` 禁止） |
| モデルの URL | Hugging Face の **`resolve/<40 桁のコミット SHA>/`**（`resolve/main/` は禁止。voicedock の fetch-models は main を見ていた） |
| golden の生成 | ホストの `uv`（`uv sync --frozen --python 3.12`。版は `Tests/Golden/GENERATED_BY.txt` に記録） |

`latest` / `main` / `master` / 浮動タグへの依存を禁止する（PT-13 が検査する）。更新は手動 PR だけで行う。

### 3.4 モジュールの依存関係（PT-07 が import を検査して固定する）

**完全な許可リスト**（ここに無い import は PT-07 が落とす。「Apple 標準なら何でもよい」ではない）。**`Synchronization`（`Mutex`）はすべてのモジュールで import してよい**（`@unchecked Sendable` を使わずに共有状態を持つため）:

| モジュール | import してよいもの |
|---|---|
| VDContract | Foundation, Darwin, CryptoKit |
| VDCore | Foundation, Darwin, os, CryptoKit, VDContract |
| VDStore | Foundation, VDContract, VDCore, GRDB |
| VDProcess | Foundation, Darwin, VDCore |
| VDDevice | Foundation, Darwin, AppKit（NSWorkspace の通知だけ）, CryptoKit, VDContract, VDCore, VDProcess, VDStore, VDAudio（`AudioProbe` だけ） |
| VDAudio | Foundation, AVFoundation, CryptoKit, VDContract（`HomeLayout`）, VDCore |
| VDTranscribe | Foundation, VDContract, VDCore, VDProcess |
| VDLLM | Foundation, Darwin, VDContract, VDCore, VDProcess（**URLSession はループバック専用ファイル `LoopbackHTTP.swift` だけ**。PT-02） |
| VDNotes | Foundation, CryptoKit, VDContract, VDCore, Yams |
| VDModels | Foundation, CryptoKit, VDContract, VDCore（URLSession を使ってよい唯一のモジュール） |
| VDPipeline | Foundation, Darwin, Security（署名検証）, CryptoKit, VDContract, VDCore, VDStore, VDProcess, VDDevice, VDAudio, VDTranscribe, VDLLM, VDNotes |
| VoiceDockApp | Foundation, AppKit, SwiftUI, ServiceManagement, os, すべての VD モジュール |
| voicedock-reaper | **Foundation, Darwin, VDContract のみ**（Process / URLSession / diskutil / removeItem の文字列を禁止。PT-15） |
| TestSupport（テスト用ライブラリ） | Foundation, Darwin, AVFoundation, Testing, すべての VD モジュール |

**置き場所の決定（v1.1）:**
- `AtomicFile`・要求／結果のコーデック・`ReaperConf`（読み書き）・`HomeLayout`・`TargetIdentity` は **VDContract**（reaper も使うため）
- モデルカタログの型と読み込み（`ModelCatalog`）は **VDCore**（CV-44/45・Worker のモデルパス解決・診断が使う）。VDModels はダウンロードと取り込みだけ
- 診断（DR）は **VDPipeline/Diagnostics/**。DR-12（ログイン項目）だけは VoiceDockApp から値を注入する
- バンドル内の資源（prompts・ModelCatalog.json）と Helpers のパスは `AppPaths`（VDCore）で注入する。SwiftPM の `Bundle.module` は使わない（.app の署名と衝突するため）。テストはリポジトリの `Resources/` を注入する

---

## 4. VDContract（アプリと reaper の共有規則）

**同じ規則を 2 か所に書かない。**voicedock では bash と Python に同じ規則を書き、片方だけずれる事故が続いた
（MTIME_TOLERANCE、ファイル名 glob）。Swift ではアプリと reaper が**同じソースを import する**。

### 4.1 録音の名前規則（voicedock SPEC §5.2 / `device.py:36-45` と一字一句同じ意味）

```swift
// 正規表現は下の表（SPEC S10）を逐語で持つ
public enum RecordingName {
    public static let filePattern: String     // 下の表の 1 行目を逐語で
    public static let folderPattern: String   // 下の表の 2 行目を逐語で
    public static func parseFile(_ name: String) -> ParsedFile?     // 存在しない日時（2/30 等）は nil
    public static func isFolder(_ name: String) -> Bool
}
public struct ParsedFile: Sendable, Equatable {
    public let transmitterID: String   // "TX01"（文字列のまま）
    public let micIndex: Int           // "MIC002" → 2
    public let local: LocalDateTime    // 年月日時分秒（オフセット無し）
    public let isOrig: Bool
    public let ext: String             // "wav" / "WAV"
}
```

名前の正規表現（SPEC S10。実装の定数と逐語で一致させる。表の中の `\|` は `|` と読む）:

| 定数 | 正規表現 |
|---|---|
| `RecordingName.filePattern` | `^(TX[0-9]{2})_(MIC[0-9]{3})_([0-9]{8})_([0-9]{6})(_orig)?\.(wav\|WAV)$` |
| `RecordingName.folderPattern` | `^TX_(MIC[0-9]{3})_([0-9]{8})_([0-9]{6})$` |

- **取り込みも削除も `_orig` だけ**（denoised は読まないので消さない。DEL-34）
- 日付は**ファイル名の時刻**から取る。フォルダ名の日付は最初の録音の時刻で、中身の日付を縛らない（DEV-11）
- ファイル名の時刻は**オフセット無しのローカル時刻**。設定のタイムゾーンを**付与するだけ**で変換しない（TIME-03）
- 正規表現は `Regex` リテラルではなく、テストで表をそのまま照合できるよう `NSRegularExpression` の文字列定数で持つ（SPEC 同期テストがこの文字列を読む）
- **voicedock との差（意図的）:** `\d` ではなく `[0-9]`（Python の `\d` は全角数字などにも一致し、reaper の bash とも食い違っていた）。
  `$` は末尾の改行の直前にも一致するので、**一致範囲が文字列全体（UTF-16 長）と等しい**ことを別に確かめる
- 日時の妥当性は `Calendar` に任せず整数範囲で判定する: 年 1〜9999、月 1〜12、日 1〜その月の日数（グレゴリオ暦の閏年規則）、時 0〜23、分 0〜59、秒 0〜59
- 固定例（テスト）: `TX01_MIC002_20260829_071204.wav`→denoised、`…_orig.WAV`→orig、`TX00_MIC000`・`TX99_MIC999` は可、
  `TX1_`・`TX001_`・`MIC02`・`MIC0002`・日付 7 桁・時刻 5 桁・`.mp3`・`_ORIG`・`_orig_orig`・`._TX…`・`prefix_TX…`・`….wav.partial`・`20260230`・`20261301`・`076104`・`00000000_000000`・末尾改行付き → nil

### 4.2 鍵（**算出規則を将来変えてはならない**。ノートに載るため）

| 鍵 | 規則 | 固定値（テストでバイト単位に固定） |
|---|---|---|
| partkey | `"\(deviceID)/\(relpath)"` | `DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav` |
| session_key | `"\(deviceID):\(yyyyMMdd in tz)"`、溢れた分は `#2`, `#3`…（`#1` は付けない） | `DJIMIC3:20260829` |
| key_slug | `sha256(key.utf8)` の hex 先頭 16 文字 | partkey → `a5d046dce76cfedc`、`DJIMIC3:20260829` → `43a71bce144be7a7` |

- `DeviceID.isValid`: 空・`/` を含む・`:` を含む・`.` で始まる・制御文字を含む → 偽。空白は可（`NO NAME`）。
  voicedock の partkey は `:` を拒否しなかったが、本アプリは partkey と session_key で同じ検査を使う（macOS では Finder 上の `/` が `:` として現れるので実際に起こる。§8.1 規則 9 で取り込み対象から外す）
- `relpath` は `RelPath.isSafe` を通すこと（4.3）
- **partkey を組み立てるのは `PartKey.make(deviceID:relpath:)` だけ**（PT-06 が文字列連結を検査）。分解は `PartKey.deviceID(of:)`（**最初の** `/` より前）と `PartKey.relpath(of:)`
- session_key の分解: `SessionKey.deviceID(of:)` は**最後の** `:` より前。`day` は `:` の後から `#n` を除いた `yyyyMMdd`。`#` の後が整数でない・2 未満 → 不正（`#1` を作らない）。`SessionKey.nextOverflow`: 接尾辞無し → `#2`、`#n` → `#(n+1)`
- 固定値のテストの doc コメントに「期待値を書き換えて通すな。規則を変えると、それ以前に保存した録音が永久に削除対象外になる」と書く（DEL-01、RK-27）

### 4.3 relpath の健全性（RV-08 と、アプリ側の事前確認で共有）

生の文字列を `/` で分割する（空の部分列を省かない）。偽になる条件（どれか 1 つで偽）: 空文字 / `/` で始まる / 空要素（`//`・末尾の `/`）/ 要素が `.` か `..` / 要素が `.` で始まる /
制御文字（U+0000–U+001F, U+007F）/ `\` を含む / UTF-8 で 1024 バイト超。

- **voicedock より厳しい（意図的）:** voicedock の Python は `PurePosixPath` の正規化で `./a.wav` と `a//b.wav` を真にしていた。本アプリは両方偽
- 固定例: `TX_MIC001_…/TX01_…_orig.wav`・`a.wav` → 真。`/TX01/a.wav`・`""`・`../a.wav`・`TX01/../a.wav`・`.Trashes/a.wav`・`TX01/.fseventsd`・`TX01/a\nb.wav`・`TX01/a\u{7f}b.wav`・`./a.wav`・`a//b.wav`・`a\b.wav`・`a/` → 偽

### 4.4 削除要求と結果（JSON、`schema: 1`）

**要求** `queue/delete/<request_id>.json`（アプリが書く。**絶対パスを持たない**）

```json
{
  "schema": 1,
  "request_id": "20260912T090000Z-a5d046dce76cfedc-a1b2c3",
  "created_at": "2026-09-12T18:00:00+09:00",
  "device_id": "DJIMIC3",
  "partkey": "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav",
  "session_key": "DJIMIC3:20260829",
  "targets": [{"relpath": "TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav",
               "size": 345600000, "mtime": 1787000000.0}]
}
```

- `request_id` = `<UTC の yyyyMMdd'T'HHmmss'Z'>-<partkey の key_slug>-<乱数 6 hex>`。正規表現は下の表（SPEC S10）
  （voicedock は docstring が UTC、実装がシステムのローカル時刻で、しかも `Z` が付かなかった。**UTC・`Z` 付きに統一**）。乱数は `SystemRandomNumberGenerator` から 3 バイト

| 定数 | 正規表現 |
|---|---|
| `RequestID.pattern` | `^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}-[0-9a-f]{6}$` |

- 再試行のたびに新しい ID。**DB の `delete_request_id` を先に書き、その後で要求ファイルを置く**
  （voicedock はファイルが先だった。ID が先なら、ファイルの書き込み後に落ちても結果を引ける。§8.9.1 の末尾の「待っている」の定義と組で使う）
- `targets` はちょうど 1 要素
- `size` / `mtime` は **DB の `source_size` / `source_mtime`（デバイス上の原本の値）**。inbox のコピーを stat した値を入れない（DEL-12: 4.5 時間ずれて永久に一致しなかった）
- 符号化（要求・結果とも。アプリと reaper が同じ `ContractJSON` を使う）: `JSONEncoder`、`outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`、末尾に `\n`。
  voicedock と同一である必要はない（読み手も書き手も本アプリ）。`mtime` の Double は整数値だと `.0` 無しで出るので、読み手は整数・小数の両方を受ける

**結果** `queue/result/<request_id>.json`（reaper が書く）

```json
{"schema": 1, "request_id": "...", "completed_at": "2026-09-12T18:00:05+09:00",
 "reaper_version": "1.0.0", "device_id": "DJIMIC3", "partkey": "...",
 "status": "DELETED", "detail": "<relpath> | <理由語>"}
```

- `status` は `DELETED` か `SOURCE_IDENTITY_MISMATCH` の 2 値だけ
- `partkey` を必ず載せる（アプリは `request_id` を解析しない）。**引き方は partkey、照合は request_id**（DEL-08）
- `detail` は **どちらか一方**: `DELETED` なら relpath、`SOURCE_IDENTITY_MISMATCH` なら理由語（付録 B.2 の固定語だけ。ロケール依存のメッセージを混ぜない）。2 つを連結しない
- `completed_at` は reaper のシステムのローカル時刻（reaper は config.json を読まない）で `yyyy-MM-dd'T'HH:mm:ssxxxxx`

書き方: 同じディレクトリの `.<name>.tmp` へ書く → `fsync` → `rename`（アトミック。`AtomicFile`）。読み手は `.` 始まりを無視する。

### 4.5 共有定数

```swift
public enum Contract {
    public static let mtimeToleranceSeconds = 2.0      // RV-12。アプリの事前確認も同じ値
    public static let requestSchema = 1, resultSchema = 1
    public static let reaperConfSchema = 1
    public static let reaperFileName = "voicedock-reaper"
    public static let volumesRoot = "/Volumes"         // reaper.conf の VOLUMES_ROOT で上書き可（テスト用）
    public static let expectedFilesystem = "msdos"     // RV-06。DJI Mic 3 は MS-DOS FAT32（実機: `msdos, local, nodev, nosuid, noowners, noatime, fskit`）
    public static let maxRequestBytes = 65_536         // 要求ファイルと reaper.conf の上限
}
```

### 4.6 対象の同定（`TargetIdentity`）

**検証済みの親ディレクトリ fd を unlink まで保持する API にする**（`Verdict` だけを返すと、reaper は unlink の前にパスを開き直すことになり、openat 連鎖で消した TOCTOU の窓が戻る）。

```swift
public enum TargetIdentity {
    /// RV-06 / RV-07。<volumesRoot の realpath>/<deviceID> を開き、開いた fd に fstatfs する
    public static func openVolume(volumesRoot: String, deviceID: String) -> VolumeOpenResult
    /// RV-08〜RV-12。検証が通れば、検証済みの親 fd を持つ VerifiedTarget を body に貸す（body を抜けたら close）
    public static func withVerifiedTarget<R>(volume: VolumeHandle, relpath: String,
        expectedSize: Int64, expectedMtime: Double, _ body: (VerifiedTarget) -> R) -> Result<R, IdentityMismatch>
}
public enum VolumeOpenResult: Sendable { case opened(VolumeHandle), absent, rejected(IdentityMismatch) }  // rejected: not_a_mount_point / unexpected_fs
public final class VolumeHandle: Sendable { public let fd: Int32; public let readOnly: Bool; public let mountPath: String }  // deinit で close。init は internal
public struct VerifiedTarget { public let parentFD: Int32; public let name: String }  // body の外へ持ち出さない（fd は body の後で close される）
public struct IdentityMismatch: Error, Equatable, Sendable { public let reason: String }   // 付録 B.2 の理由語
```

- **reaper の RV-06〜RV-12 そのもの**で、アプリの事前確認（§8.9.5）も同じ関数を呼ぶ（アプリは body で何もしない）
- `VolumeHandle.readOnly` は同じ `fstatfs` の `f_flags & MNT_RDONLY`。reaper の RV-07 はこの値を使う。アプリのロック 2-B の観測は snapshot（IngestService の statfs）で行い、事前確認（§8.9.5）ではさらに `VolumeHandle.readOnly == false` も確かめる（二重。どちらかが偽なら要求を書かない）
- アプリは `TargetIdentity.openVolume` を直接呼ばず、`VolumeOpener` プロトコル（VDContract。本番の実装 `SystemVolumeOpener` は `openVolume` を呼ぶだけ）を注入で受ける。テストは `@testable import VDContract` で `VolumeHandle` の internal な初期化子を使い、普通のディレクトリを包む `FakeVolumeOpener` を使う（CR-25。`VolumeHandle(` を本番のソースで呼んでよいのは `TargetIdentity.swift` だけ。PT-22）
- `openVolume`: `DeviceID.isValid` 偽 → `rejected(not_a_mount_point)`。`open(O_RDONLY | O_DIRECTORY | O_NOFOLLOW)` が `ENOENT` → `.absent`、`ELOOP` / `ENOTDIR` → `not_a_mount_point`（macOS の `O_DIRECTORY|O_NOFOLLOW` は symlink でも ENOTDIR を返す）、それ以外の errno（`EACCES`・`EPERM`。TCC の拒否など）→ `.absent`（要求を残し、アプリ側の期限切れに任せる。消さない側）。
  開いた fd に `fstatfs`: `f_mntonname` が「`volumesRoot` を realpath したもの + `/` + deviceID」と一致しなければ `not_a_mount_point`、`f_fstypename != "msdos"` → `unexpected_fs`。
  （比較は realpath 済みのパスで行う。テストの一時ディレクトリは `/var/folders` → `/private/var` なので、realpath しないと hdiutil の `f_mntonname` と一致しない）
- ボリュームの fd に `fstatfs` する（`statfs(path)` → `open(path)` の間に差し替えられる窓を消す）

実装は **`openat` の連鎖**で行う（voicedock の `realpath` 比較より強い。TOCTOU で symlink に差し替えられる窓が無い）:

1. relpath を `RelPath.isSafe` で確かめる（偽 → `relpath_unsafe`。RV-08）
2. 中間要素ごとに `openat(dirfd, comp, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)`。`ELOOP` / `ENOTDIR` → `path_contains_symlink`、`ENOENT` → `target_missing`、その他の errno → `target_missing`
3. 最後の要素を `fstatat(parentfd, name, AT_SYMLINK_NOFOLLOW)`。`ENOENT` → `target_missing`、symlink → `target_is_symlink`、通常ファイルでない → `not_regular_file`
4. ファイル名が `_orig` 付きの規則に一致（`filename_rule`）、親フォルダ名が規則に一致（`folder_rule`。relpath が 1 要素＝ボリューム直下のファイルは常に `folder_rule`）
5. `st_size == expectedSize`（`size_mismatch`）、`abs((Double(st_mtimespec.tv_sec) + Double(st_mtimespec.tv_nsec) / 1e9) - expectedMtime) < 2.0`（`mtime_mismatch`）

旧 reaper の理由語 `realpath_failed` / `outside_volume` / `stat_failed` は openat 連鎖では出ない（付録 B.2 に載せない）。

### 4.7 VDContract のその他の共有物

| 型 | 役割 |
|---|---|
| `HomeLayout` | `<HOME>` 配下の全パス（§2.3）。`init(root: URL)`、`static func production() -> HomeLayout` |
| `AtomicFile` | CR-01 の唯一の実装。`write(_ data: Data, to: URL, permissions: mode_t = 0o644, verifyReadBack: Bool = false) throws`。tmp の後始末もここだけが行う |
| `ContractJSON` | 要求・結果の符号化と厳格な復号（キー集合の完全一致、bool を数として受けない） |
| `ReaperConf` | `bin/reaper.conf` の書式（§8.9.4）の parse と render。アプリ（有効化フロー・ロック観測）と reaper が同じ関数を使う |
| `Version` | `VERSION` ファイルと一致する定数（§11.4）。数値の組で比較する |
| `KeySlug` | `sha256(key.utf8)` の hex 先頭 16 文字 |

---

## 5. ドメイン（voicedock から移植する規則）

### 5.1 状態と集合

状態・遷移表・復旧写像は**付録 A にそのまま載せる**（voicedock `states.py:154-293` ＋ 本計画の差分 ★）。集合はすべて `VDCore/States.swift` に定義し、**書き手と検証側が同じ定数を使う**（DEL-21）:

| 集合（v1.1 の説明用の名前。Swift では `PartStates.terminal` のように型の中に置く。対応は T-08） | 型 | 中身 | 使い道 | voicedock |
|---|---|---|---|---|
| `partTerminal` | Part | RAW_SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING, COMPLETED, FAILED, SKIPPED | Session を進めてよいか | PART_TERMINAL |
| `partDeletable` | Part | partTerminal − {FAILED, SKIPPED} | 根拠 A で消してよいか | PART_DELETABLE |
| `stagingDisposable` | Part | partTerminal − {FAILED} | staging を消してよいか（FAILED の 16 kHz は再試行の入力） | STAGING_DISPOSABLE |
| `awaitingDeletion` | Part | partDeletable − {COMPLETED} | 空なら Session の削除段を畳む | AWAITING_DELETION |
| `rawNoteMembers` | Part | TRANSCRIBED, RAW_WRITING, RAW_SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING, COMPLETED | Raw ノートに載る Part | RAW_NOTE_MEMBERS |
| `inboxLeftoverStates` | Part | partTerminal − {FAILED}（stagingDisposable と同値だが別の問い。別定数） | inbox の取り残し判定（DR-15・状態の詳細） | ORPHANED_STATES |
| `partInProgress` | Part | NORMALIZING, TRANSCRIBING, RAW_WRITING, SOURCE_DELETING（= partRecovery の定義域） | 復旧 | PART_IN_PROGRESS |
| `partRetryableFromFailed` | Part | NORMALIZING, TRANSCRIBING, RAW_WRITING | FAILED からの戻り先 | PART_RETRYABLE_FROM_FAILED |
| `partRetryReset` | Part | NORMALIZED, TRANSCRIBED, RAW_SAVED | retry_count を 0 に戻す遷移先 | PART_RETRY_RESET |
| `normalizable` / `transcribable` / `rawWritable` | Part | {DISCOVERED, NORMALIZING} / {NORMALIZED, TRANSCRIBING} / {TRANSCRIBED, RAW_WRITING} | 各工程の入口 | NORMALIZABLE 等 |
| `normalizedOrBeyond` | Part | NORMALIZED, TRANSCRIBING, TRANSCRIBED, RAW_WRITING, RAW_SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING, COMPLETED | ensureNormalized の冪等 | NORMALIZED_OR_BEYOND |
| `transcribedOrBeyond` | Part | TRANSCRIBED, RAW_WRITING, RAW_SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING, COMPLETED | ensureTranscribed の冪等 | TRANSCRIBED_OR_BEYOND |
| `rawSavedOrBeyond` | Part | RAW_SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING, COMPLETED | ensureRawNote の冪等 | RAW_SAVED_OR_BEYOND |
| `sessionInProgress` | Session | MERGING, ANALYZING, WRITING, SOURCE_DELETING, CLEANUP（= sessionRecovery の定義域） | 復旧 | SESSION_IN_PROGRESS |
| `sessionRetryableFromFailed` | Session | MERGING, ANALYZING, WRITING | FAILED からの戻り先 | SESSION_RETRYABLE_FROM_FAILED |
| `sessionRetryReset` | Session | MERGED, ANALYZED, SAVED | retry_count を 0 に戻す遷移先 | SESSION_RETRY_RESET |
| `mergeable` / `analyzable` / `writable` | Session | {READY, MERGING} / {MERGED, ANALYZING} / {ANALYZED, WRITING} | 各工程の入口 | MERGEABLE 等 |
| `processable` | Session | mergeable ∪ analyzable ∪ writable | processReadySessions の対象 | PROCESSABLE |
| `reopenable` | Session | SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING, CLEANUP, COMPLETED（**v1.1 で広げた**。voicedock は SAVED, COMPLETED） | 再オープン元 | REOPENABLE |
| `deleteEvaluated` | Session | SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING, CLEANUP（COMPLETED を含めない） | 削除評価の対象 | DELETE_EVALUATED |
| `cleanupFrom` | Session | SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING | CLEANUP へ進める遷移元 | CLEANUP_FROM |
| `savedOrBeyond` | Session | SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING, CLEANUP, COMPLETED | ensureDailyNote の冪等 | SAVED_OR_BEYOND |
| `mergedOrBeyond` | Session | MERGED, ANALYZING, ANALYZED, WRITING ∪ savedOrBeyond | ensureMerged の冪等 | MERGED_OR_BEYOND |
| `deletableSkipReasons` | ErrorCode | DUPLICATE_CONTENT, NO_SPEECH_DETECTED | 根拠 B | DELETABLE_SKIP_REASONS |
| `benignSkipReasons` | ErrorCode | NO_SPEECH_DETECTED, DUPLICATE_CONTENT（**deletableSkipReasons と同値でも別定数**。片方の変更に追随させない） | Daily の ⚠ を付けない理由 | BENIGN_SKIP_REASONS |

- 状態は `enum PartStatus: String` と `enum SessionStatus: String`（rawValue = 大文字の名前）。**状態名の文字列は `States.swift` の enum の rawValue にしか書かない**（PT-06）
- 集合は**エンティティごとに別の型**（`Set<PartStatus>` と `Set<SessionStatus>`）。rawValue で 1 つの集合に混ぜない（SM-21）
- `SOURCE_DELETE_PENDING` は名前に ING を含むが進行中ではない（接尾辞で判定しない。SM-10）
- 不変条件テスト（`StatesInvariantTests`）: `partDeletable ⊂ partTerminal`（真部分集合、差 = {FAILED, SKIPPED}）、`partInProgress == partRecovery.keys`、
  `sessionInProgress == sessionRecovery.keys`、`partRetryableFromFailed ==`「遷移表で FAILED へ入る辺の遷移元」、Session も同じ、名前が `ING` で終わる状態は `InProgress` か `SOURCE_DELETE_PENDING`、
  `inProgress ∩ (terminal − {SOURCE_DELETING}) = ∅`（Part の SOURCE_DELETING は進行中でもあり終端でもある。voicedock も除いて検査していた）、復旧写像の行き先は遷移表で到達可能、到達不能な状態が無い、`processable == mergeable ∪ analyzable ∪ writable`（DEL-02 / TEST-08）

### 5.2 状態を変える API は 2 つ（遷移と行の作成）。どちらも `VDStore/Transitions.swift` にだけ在る

```swift
public enum TransitionKind: Sendable { case normal, recovery }
func recordPartTransition(partkey: String, from: PartStatus, to: PartStatus, kind: TransitionKind = .normal,
                          errorCode: ErrorCode? = nil, errorMessage: String? = nil, detail: String? = nil, resetRetry: Bool = false) throws
func recordSessionTransition(sessionKey: String, from: SessionStatus, to: SessionStatus, kind: TransitionKind = .normal,
                             errorCode: ErrorCode? = nil, errorMessage: String? = nil, detail: String? = nil, resetRetry: Bool = false) throws
func insertRecording(_ row: NewRecording) throws     // status = DISCOVERED 固定
func insertSession(_ row: NewSession) throws         // status = OPEN 固定
```

- **辺の検査（本計画の差分）:** voicedock の `record_transition` は遷移表を検査しなかった（db.py:328）。本アプリは検査する:
  `kind == .normal` は付録 A.2 の遷移表、`kind == .recovery` は付録 A.1 の復旧写像（from→to がちょうどその組）でだけ許す。どちらでもなければ `IllegalTransition` を投げる
  （`precondition` にしない。常駐プロセスを落とさない）。`.recovery` の detail は `recovery` 固定（引数の detail は無視）
- `UPDATE <table> SET status = ?, retry_count = <式>, error_code = ?, error_message = ?, updated_at = ? WHERE <key> = ? AND status = ?`（楽観的同時実行制御）。変更行数が 1 でなければ（行が無い場合も）`TransitionConflict` を投げてロールバック
- 同じトランザクションで `INSERT INTO events (entity_type, entity_key, from_status, to_status, error_code, detail, created_at)`。`entity_type` は `recording` / `session`
- `retry_count`: `resetRetry` か `to ∈ partRetryReset / sessionRetryReset` なら 0、`to == FAILED` なら +1、それ以外は据え置き（SM-03 / SM-04）
- `error_code` / `error_message` は**無条件に上書き**（渡さなければ NULL）。`error_message` と `detail` は 200 文字に切り詰める（拒否ではなく切り詰め）
- **行の作成も遷移として記録する:** `insertRecording` / `insertSession` は INSERT と同じトランザクションで events に `from_status = NULL, to_status = 初期状態, error_code = NULL, detail = NULL` の 1 行を書く（voicedock db.py:399-424）
- **`updated_at` は遷移のたびと、Store の列更新メソッド（`updateRecording` / `updateSession`。status 以外の列を変える）のたびに Clock の now で上書きする。**
  列更新メソッドは `status` を受け付けない（型で表す。列ごとの引数を持つ）。§5.6 の idle 判定と §8.9.7 の期限切れはこの値に依存する
- 「X のまま」は遷移ではない（events を書かない）。`OPEN→OPEN` だけは遷移（SM-02）
- **文字数の数え方（全体の規則。CR-23）:** 「N 文字」は **Unicode スカラー数**で数え、切り詰めも Unicode スカラー単位で行う（Python の `len` と同じ）。
  `String.count`（書記素数）は使わない。200 文字の切り詰めは「スカラー数 ≤ 200 ならそのまま、超えたら先頭 199 スカラー + `…`」
- PT-05: `status` を書く SQL（`UPDATE … SET … status`）と `INSERT INTO recordings / sessions` は `Transitions.swift` の中にしか無い

### 5.3 クラッシュ復旧（起動時に 1 回。voicedock §9.4 と同じ順）

```text
Part（partRecovery。この順）:    NORMALIZING→DISCOVERED, TRANSCRIBING→NORMALIZED, RAW_WRITING→TRANSCRIBED, SOURCE_DELETING→SOURCE_DELETE_PENDING
Session（sessionRecovery。この順）: MERGING→READY, ANALYZING→MERGED, WRITING→ANALYZED, SOURCE_DELETING→SOURCE_DELETE_PENDING, CLEANUP→SAVED
```

- 各状態の行を `started_at, partkey`（Session は `session_key`）の順に、`kind: .recovery` で戻す。1 件以上戻したら `recovery_completed rolled_back=<n>`
- 戻す前の部分出力の削除（`SafeUnlink`。失敗は `config_warning rule=recovery` を WARNING で出して続行）:
  - NORMALIZING: **partkey から算出した** `staging/<slug>/audio16k.wav` と `audio16k.wav.tmp`（voicedock は `normalized_path` 列を見ていたが、初回変換中は列が NULL で何も消さなかった）
  - TRANSCRIBING: `transcripts/parts/<slug>.json` と `staging/<slug>/whisper.json`
  - RAW_WRITING / WRITING（**本計画の差分**。voicedock は残していた）: Vault の確認（§8.7 手順 0）が通ったときだけ、そのノートの一時ファイルを消す。
    対象は DB の `raw_output_path` / `output_path` があればそのファイル名の `.<ファイル名>.tmp`（例 `.2026-08-29 raw.md.tmp`。**`.md` を含む**。voicedock notes.py:248 と同じ）、無ければ §8.8 の候補名（基本名と ` (2)`〜` (99)`）それぞれの `.<基本名>.md.tmp` の**名前が完全一致するものだけ**
- SOURCE_DELETING→SOURCE_DELETE_PENDING では `delete_request_id` を**外さない**（結果が届けば回収できる。§8.9.6）
- 続けて: `closeIdleSessions`（無通信が `idleCloseSeconds` を過ぎた OPEN を READY、detail `idle`。日付が過去の OPEN も同じ規則で、夜の間止まっていたアプリは起動時にここで閉じる。v1.1 までの `closeStaleOpenSessions`（日付が過去の OPEN を `stale_day` で閉じる）は F-66 で廃止）→ **inbox の孤児**（DB に行の無い `_orig.wav` と、すべての `.partial`）を削除（`inbox_orphans_removed count=<n>`）→ 起動契機の再評価（§5.4）
- 復旧は IngestService が最初の走査を始める**前に**終える（アプリの起動手順: DB を開く → Worker.start() → IngestService.start()）。
  設定エラーなどで start が遅れた場合（§5.4 の `pendingStart`）は、IngestService が既に走っていてコピー中のファイルと孤児を見分けられないので、**inbox の孤児の削除だけを飛ばす**（復旧と閉じる処理と requeue は行う）
- 各工程の入口は進行中の状態も受け付ける（`normalizable = {DISCOVERED, NORMALIZING}` など）。進行中から入っても遷移を記録しない（SM-08）
- **「戻りうる全状態に受け手がいる」**を不変条件としてテストする（SM-07）

### 5.4 Worker のループ

```text
start():   // 設定エラー中は何もしない（pendingStart を立て、解除された最初の tick の先頭で行う）
  log service_started version=<VERSION> schema=<最後に適用したマイグレーション識別子>
  recoverInterrupted → closeIdleSessions → removeInboxOrphans → requeueFailed(.startup)

tick():   // 待ちは「IngestService からの通知」「パネルからの要求」「30 秒」の早い方。直列に実行
  if 設定エラー状態: return                                          // §6.1。何もしない
  snapshot = await ingest.latestSnapshot()                            // 起動直後は nil（まだ走査していない）
  manualRequeue                 // パネルの「再試行」の要求があるときだけ requeueFailed(.manual)（下の契機 3）
  groupNewParts
  requeueRecopied                                                     // 契機 4（下記）
  closeIdleSessions             // idle だけで閉じる（§5.6）。続けて、パネルが要求した「今すぐ要約」（summarizeNow）を行う（下記。F-66）
  processPendingParts          // 一覧を先に確定: 非終端 Part を started_at, partkey 昇順。1 件ごとに工程内リトライ
  refreshVaultIndexIfExpired   // TTL 300 秒。ContinuousClock で測る（TIME-06）
  processReadySessions         // 一覧を先に確定（下記）。終わりで llama-server を必ず止める
  collectDeleteResults         // 常に行う（新しい要求は書かない）。§8.9.6
  expireDeleteRequests         // 常に行う。§8.9.7
  if snapshot が新鮮:           // snapshot != nil かつ 最終走査から snapshotMaxAgeSeconds（900）以内
     evaluateDeletions → settleSkippedDeletions → runReaperIfNeeded（→ scanNow → collectDeleteResults）
  pendingDiagnostics            // パネルが要求した DR-09（LLM 実リクエスト）をここで 1 件ずつ実行（§8.11）
  if snapshot.connectEpoch > lastSeenConnectEpoch: requeueFailed(.connect); lastSeenConnectEpoch = snapshot.connectEpoch
```

tick の段（SPEC S13。「段」の列は `TickStage` の case で、宣言順 = 実行の順。「条件」の列が `snapshot が新鮮` の段が `TickStage.requiresFreshSnapshot`）:

| # | 段 | 上の擬似コードの行 | 条件 |
|---|---|---|---|
| 1 | `manualRequeue` | manualRequeue | 要求があるときだけ |
| 2 | `groupNewParts` | groupNewParts | — |
| 3 | `requeueRecopied` | requeueRecopied | — |
| 4 | `closeIdleSessions` | closeIdleSessions（今すぐ要約を含む） | — |
| 5 | `processPendingParts` | processPendingParts | — |
| 6 | `refreshVaultIndex` | refreshVaultIndexIfExpired | — |
| 7 | `processReadySessions` | processReadySessions | — |
| 8 | `collectDeleteResults` | collectDeleteResults | — |
| 9 | `expireDeleteRequests` | expireDeleteRequests | — |
| 10 | `evaluateDeletions` | evaluateDeletions | snapshot が新鮮 |
| 11 | `settleSkippedDeletions` | settleSkippedDeletions | snapshot が新鮮 |
| 12 | `runReaperIfNeeded` | runReaperIfNeeded | snapshot が新鮮 |
| 13 | `pendingJobs` | pendingDiagnostics（今すぐ要約を除くパネルの仕事） | — |
| 14 | `requeueOnConnect` | connectEpoch の増加で `requeueFailed(.connect)` | — |

- **今すぐ要約（手動。F-66）:** パネルの要求（`WorkerJob.summarizeNow(reply:)`）は、`closeIdleSessions` の段の終わりで列から取り出して入れた順に行う（ほかの仕事は `pendingDiagnostics` の段のまま）。
  Session を閉じる契機は、無通信の `idle`（自動）とこの今すぐ要約（手動）の 2 つだけ（日付が変わった 0:00 の `stale_day` は F-66 で廃止）。1 件ごとに:
  1. 停止要求が立っていれば何もせずに失敗（「終了中のため実行しませんでした」）
  2. 解析の前のガード（下記・§8.5）の LLM の条件（未選択・モデルが無い・メモリ不足・llama-server が無い）を**積まずに**判定し、当たれば何も閉じずに失敗。文言は当たった理由の `StatusTexts.pauseWord` を `、` で繋いだもの（例「LLM が未選択」）
  3. 押した時点の OPEN を**日付を問わず**全部（過去の日の取り残しも）`session_key` 順に `OPEN→READY`（detail `summarize_now`）。`TransitionConflict` は数えずに次へ。返事は閉じた数（無ければ 0）。DB の例外は `config_warning rule=store` を出して失敗
  - 返事はその場で返し、要約は同じ tick の `processReadySessions` が進める（Part が全部終端でなければ、終端になった tick で進む）。ログのイベントは増やさない（遷移は `events` が持つ）
  - 閉じた後に同じ日の録音が届けば、既存の再オープン（§5.6。Raw の保存で `reopenable` の Session を `→MERGING`）で要約し直す。`allowReopen = false` なら要約し直さない（自動の閉じ方と同じ）
  - `pendingDiagnostics` の段に残っていた分（`closeIdleSessions` の段より後に入った分）はそこで実行せず、ループの後で列の**先頭**に戻して（入れた順を保つ）次の tick で行う。その段の途中の await の間に停止要求が来ていれば、戻さずに停止の失敗を返す
  - 設定エラー中の tick は「設定が読めていません」、停止要求（`requestStop`・停止後の `enqueue`）は「終了中のため実行しませんでした」で失敗の返事をする（返事は必ず 1 回）
- `processReadySessions` の対象: `processable` の各状態の Session（`ORDER BY session_key`）のうち、Part が **1 件以上**あり**全件が `partTerminal`**のもの。最終的な処理順は **session_key の昇順**（voicedock worker.py:391-412）
- 停止要求は各 Part / 各 Session の区切りと、工程内リトライの待ちの前後で確認する（停止ハンドラはフラグを立てるだけ。CONC-11）
- `now` は `AppClock` プロトコル（標準ライブラリの `Clock` と名前を分ける）から毎回取る。tick の先頭で固定しない（TIME-04）。`Date()` を直接呼ぶのは `SystemClock` だけ（PT-09）
- 1 件の `TransitionConflict` で残りを止めない（DEL-14 / DEL-19）。捕まえて `source_delete_skipped recording_key=… reason=status_changed`（WARNING。削除の経路）か、
  工程の経路なら何も書かずに次へ進む
- **失敗した工程の戻り先**は、`events` の直近の `to_status = FAILED` 行の `from_status`（`Store.failedFrom`: `ORDER BY id DESC LIMIT 1`）。それが `*RetryableFromFailed` に在るときだけ戻す
- **工程内リトライ**（voicedock pipeline.py:1750-1832）: 工程を 1 回実行 → 行が FAILED で、error_code の RetryPolicy が `attempts` で、戻り先が取れ、
  `1 <= retry_count < maxAttempts` なら `backoff[retry_count - 1]` 秒待って `FAILED→<戻り先>`（detail `retry`、retry_count は据え置き）→ もう一度。
  既定 3 回・`[3,10,30]` のとき「失敗 → 3 秒 → 失敗 → 10 秒 → 失敗 → 終了」（30 は使われない。テストで calls == 3、sleeps == [3, 10] を固定）
- **再評価（requeue）の契機は次の 4 つだけ。**時間経過では再評価しない。上限なし（SM-05）:
  1. 起動（`requeueFailed(.startup)`）
  2. デバイス接続の立ち上がり（`connectEpoch` が増えた。§8.1。起動後の最初の接続も含む）
  3. パネルの「再試行」ボタン（`requeueFailed(.manual)`）
  4. **再コピーの完了（v1.1 で追加）**: `requeueRecopied` が、FAILED で error_code が `SOURCE_HASH_MISMATCH` か `NORMALIZED_MISSING` かつ `needs_recopy = 0` の Part だけを戻す
     （これらのコードは失敗時に必ず `needs_recopy = 1` を立てるので、0 に戻っていれば再コピーが済んでいる）。`FAILED→<戻り先>`（detail `recopied`、`resetRetry: true`）、1 件以上なら `recovery_completed requeued=<n>`
- `requeueFailed`: Part → Session の順に、FAILED の行を `ORDER BY updated_at, <key>` で全部 `FAILED→<戻り先>`（detail `requeue`、`resetRetry: true`）。
  **`needs_recopy = 1` の Part は除く**（再コピーより先に戻すと、inbox が無いので SOURCE_MISSING の SKIPPED（終端）に落ちる）。1 件以上戻したら `recovery_completed requeued=<n>`
- **ガード（遷移せずに待つ。失敗ではない）:** 次の条件では工程に入らず、行を動かさず、パネルの「要対応」に理由を出す（SM-18 と同じ扱い）。条件が解消すれば次の tick で自然に再開する
  - 変換の前: 空き容量不足（`DISK_SPACE_LOW`。§8.3）
  - 文字起こしの前: whisper-cli・Whisper モデル・（VAD 有効なら）VAD モデルのどれかが無い
  - Raw / Daily の書き込みの前: Vault が未設定・見つからない・目印が無い・読めない（§8.7 手順 0）
  - 解析の前: LLM モデルが未選択・無い・メモリ不足、llama-server が無い
  - ガードに入った・出たときだけ `pipeline_paused reason=<語>` / `pipeline_resumed reason=<語>` を 1 回ずつ出す（毎 tick 出さない）。空き容量のガードだけは、入ったときに `pipeline_paused` の代わりに `disk_space_low reason=<空き容量の文言>`（WARNING）を 1 回出す
- RetryPolicy（付録 A.3）が振る舞いを変えるのは「工程内リトライをするか」（`attempts` だけ）だけである。requeue は RetryPolicy を見ず、FAILED の行をすべて戻す（`none` / `nextPoll` / `nextConnect` は voicedock の表との対応と表示のために残す）

### 5.5 Part の処理（1 件）

```text
ensureNormalized → ensureTranscribed → ensureRawNote → requestDeletions(その Part の Session の全 Part)
```

- すべての `ensure*` は冪等。偽を返したら以降の工程を実行しない
- Raw ノートを保存した直後の削除評価は、**その Part だけでなく Session の全 Part** を対象にする（voicedock pipeline.py:281, 703）。SOURCE_DELETING と COMPLETED の Part は飛ばす
- 削除要求を書く直前に**その時点の最新 snapshot** の新鮮さを確かめる（tick の先頭ではない。Part の処理は数時間かかる。§8.9.5）
- 詳細は §8.3（変換）、§8.4（文字起こし）、§8.6（Raw ノート）、§8.9（削除）
- 結果の写し方（voicedock pipeline.py:1537-1605）:
  - SKIPPED にするとき: `→SKIPPED`（error_code・error_message）→ `part_skipped recording_key=… reason=<source_missing|duplicate_content|no_speech>` → その Part の Session の再オープン（§5.6）
  - FAILED にするとき: `→FAILED`（error_code・error_message）→ `<工程の失敗イベント> recording_key=… error_code=… [reason=…]`（ERROR）→ その Part の Session の再オープン

### 5.6 分組・Block・統合（voicedock `session.py` と同じ。詳細は voicedock SPEC §10.4 / §10.8）

- 分組対象は `session_key IS NULL` の Part（`started_at, partkey` 順）
- 鍵は `started_at` を設定のタイムゾーンへ**変換してから**日付を取る（TIME-02。23:50 開始・日跨ぎの Part でテスト）
- 空きの判定（`_has_room`）: `part_count >= maxParts(64)` なら入らない。そうでなければ `(recorded_seconds ?? 0) + (duration ?? 0) <= maxDuration(86400)` なら入る。
  入らなければ `SessionKey.nextOverflow` で `#2`, `#3`… と進め、最初に入れる（か、まだ無い）鍵にする
- Session が無ければ `insertSession`（OPEN。events に NULL→OPEN）。Part に session_key を書き（`updateRecording`）、集計列を数え直す:
  `SELECT COUNT(*), MIN(started_at), MAX(ended_at), SUM(duration_seconds), SUM(CASE WHEN status IN (?, ?) THEN 1 ELSE 0 END) FROM recordings WHERE session_key = ?`（`IN` には FAILED と SKIPPED の rawValue を束縛する。SQL に状態名を書かない。PT-06）
  → `part_count / started_at / ended_at / recorded_seconds / failed_part_count`（SUM は全部 NULL なら NULL）。Session が OPEN なら `OPEN→OPEN`（detail = partkey。新規作成の直後も書く）。閉じた Session への追加は events を書かない
- OPEN を閉じる（`closeIdleSessions`、`ORDER BY session_key`）: `updated_at <= now − idleClose(1800 秒)` なら `OPEN→READY`（detail `idle`。読めない `updated_at` は古い側）。**日付では閉じない**（日付が過去の OPEN も同じ規則。無通信は最後の活動＝`updated_at` から測る）。
  パネルの「今すぐ要約」は OPEN を日付を問わず detail `summarize_now` で閉じる（§5.4）。
  **本計画の差分（F-66。X-37）**: voicedock は `day_date != today(tz)` の OPEN も `stale_day` で閉じていた（0:00 の自動要約）。利用者の決定で廃止した。日付をまたいだ録音は、分組の規則（開始時刻の日付）どおり新しい日の Session に入る
- Block（`computeBlocks`）: 入力は FAILED / SKIPPED を除く Part（**transcript が読めない Part も含む**）を `(started_at, ended_at ?? "")` で並べたもの。
  最初の Part で `start = started_at, end = ended_at ?? started_at, unknownEnd = (ended_at == nil)`。以降、`gap = started_at − end` が `unknownEnd || gap > blockGap(3600)` なら区切って新しい Block、
  そうでなければ `unknownEnd = (ended_at == nil); end = max(end, ended_at ?? started_at)`。**ちょうど閾値は区切らない**
- 統合（`buildSessionTranscript`）: FAILED / SKIPPED を除外し、`(started_at, partkey)` 順に transcript を読む（読めない Part は飛ばす）。各 segment の text を **Python 互換の strip**（§5.7）で整え、空は捨てる。
  `at = part.started_at + seg.start`、`end_at = part.started_at + seg.end` の**絶対時刻**（相対オフセットを足し込まない。TIME-01。時刻は §5.7 の `Instant`）。`(at, end_at)` で安定ソート。
  0 件なら `MERGING→COMPLETED`（`session_empty session_key=… parts=<n>`）でノートを作らない
- 統合の成功: `updateSession(failed_part_count = 除外数)` → `MERGING→MERGED` → `session_merged session_key=… parts=<有効数> excluded=<除外数> chars=<text のスカラー数の合計>`
- **再オープン**（`reopenSession`）: `allowReopen` かつ **その Part の Session** が `reopenable`（SAVED / SOURCE_DELETING / SOURCE_DELETE_PENDING / CLEANUP / COMPLETED）のとき、Part が RAW_SAVED / FAILED / SKIPPED に到達したら `→MERGING`（detail `reopen`）→
  `regenerated_count += 1` → `session_reopened session_key=… regenerated_count=<n>`。`TransitionConflict` は偽を返すだけ。分組（DISCOVERED）は契機にしない（SM-11 / SM-12）
  - **本計画の差分（v1.1）**: voicedock は SAVED / COMPLETED からしか再オープンしなかったので、削除段（SOURCE_DELETING / SOURCE_DELETE_PENDING / CLEANUP）の間に同じ日の Part が増えると、その Part は Raw には載るが Daily には永久に載らなかった（X-13 と同じ型の潜在バグ）。★辺 3 本を足して、削除段からも再オープンする。削除待ちの Part の状態は動かさない（結果は §8.9.6 の全件回収が拾う）
- **解析の再利用（voicedock どおり、★辺を明示）:** `ensureAnalysis` は MERGED / ANALYZING の Session で、既存の `analysis/<slug>.json` が読めて最終スキーマで検証を通り、
  `.source.json` の `transcript_sha256` が現在の指紋と一致すれば、LLM を呼ばずに `updateSession(analysis_path, title)` を書いてから `→ANALYZED`（MERGED からなら ★`MERGED→ANALYZED`、detail `analysis_reused`）。**voicedock は再利用のときに `analysis_path` を書かなかったので、解析を書いた後・DB 更新の前に落ちた Session が ANALYZED のまま永久に止まった（潜在バグの修正。X-36）**
- **本計画の差分（voicedock の潜在バグ 15 の修正）:** `ensureAnalysis` は Session が **ANALYZED または WRITING** のときも、統合結果の指紋を `.source.json` と比べ、
  解析 JSON が読めて検証を通るかも確かめる。どちらかが偽なら ★`ANALYZED→ANALYZING` / ★`WRITING→ANALYZING`（detail `stale_analysis`）でやり直す
  - 理由: クラッシュ復旧で WRITING→ANALYZED に戻った間、または FAILED(WRITING) の再評価で WRITING に戻った間に同じ日の Part が増えると、voicedock は古い解析のまま Daily を書く（再オープンの契機が SAVED / COMPLETED にしか無いため）
  - 副作用: voicedock にあった「解析 JSON が読めないと ANALYZED→FAILED（表に無い辺。しかも戻り先が無く永久に FAILED）」が消える
- `ensureDailyNote` は **`ANALYZED→WRITING` を記録してから**解析 JSON を読む。読めなければ `WRITING→FAILED`（`OBSIDIAN_WRITE_FAILED`、「解析結果を読めません: <analysis_path>」）

### 5.7 時刻・文字列・JSON の表現（Python 互換。`VDCore`）

golden（voicedock とのバイト一致）と指紋を守るため、Python の振る舞いに合わせた部品を **VDCore に 1 か所だけ**置き、固定テストを付ける。Swift 標準の近いものを代わりに使わない。

**時刻**
- 絶対時刻は `struct Instant: Comparable, Hashable, Sendable { let epochMillis: Int64 }` で持つ（**Double の `Date` で加算しない**。Python の `datetime + timedelta` は整数演算で、300 秒見出し・Block の間隔・チャンクの実時間は等号の境界で決まる）
- whisper の offsets（ミリ秒）を秒へ直した値 `round(ms / 1000, 3)` は、`Instant` に足すときミリ秒の整数 `Int64((秒 × 1000).rounded())` に戻す
- DB・JSON・ログの時刻文字列は **ISO 8601、秒まで（秒未満は切り捨て）、設定のタイムゾーンのオフセット付き**（`2026-08-30T07:00:12+09:00`）。`ZonedTime.iso(_:)` だけが作る
- 表示の `HH:MM` / `HH:MM:SS` は、保存された文字列のオフセット（= 設定のタイムゾーン）での壁時計。秒未満は切り捨て
- DB の時刻列の大小比較（`MIN(started_at)` など）は文字列で行う（全行が同じオフセットである前提。タイムゾーンを変えた場合の影響は RK-32）

**文字列（`PyText`）**
- `PyText.isSpace(_:)`（Python `str.isspace`）: U+0009–000D, U+001C–001F, U+0020, U+0085, U+00A0, U+1680, U+2000–200A, U+2028, U+2029, U+202F, U+205F, U+3000。
  `CharacterSet.whitespacesAndNewlines` とは U+001C–001F の有無が違う
- `PyText.strip(_:)` / `strip(_:chars:)`、`PyText.splitLines(_:)`（`\r\n`・U+000A・000B・000C・000D・001C・001D・001E・0085・2028・2029 で分割。末尾の区切りの後に空要素を作らない）、
  `PyText.collapseWhitespace(_:)`（`\s+` → U+0020）
- `PyText.casefold(_:)`: Unicode 15.0.0 の CaseFolding.txt の C + F（完全ケースフォールディング。語末シグマ規則なし）。表は `tools/unicode/gen-casefold.py` で生成し
  `VDCore/PyCaseFoldTable.swift` としてコミットする。`lowercased()` は使わない（`ß` が `ss` にならず、`ΣΑΣ` が `σας` になる）
- `PyText.isCombining(_:)`: `canonicalCombiningClass != .notReordered`
- 文字数は Unicode スカラー数（§5.2）
- 固定テスト: `Straße`→`strasse`、`ΣΑΣ`→`σασ`、`İ`→`i̇`、`ﬁ`→`fi`、`"\u{1c}X\u{1f}".strip`→`X`、`"a\u{a0}b\u{200b}c"` の空白畳み込み→`a b\u{200b}c`、`"A。B。 C"` の文分割→`["A。","B。","C"]`

**JSON（`PyJSON`）**
- 内部 JSON（正規化 transcript・analysis・timeline・source・Reduce の入力・指紋の入力）は Python `json.dumps(…, ensure_ascii=False)` と同じ書式を自前で書く:
  - `indent=2` 形式（`"key": value`、コロンの後に空白 1 つ、前には無い。要素ごとに改行と 2 空白の字下げ。空配列は `[]`、空オブジェクトは `{}`）＋ 末尾に `\n`
  - コンパクト形式（`separators=(",", ":")`）
  - 文字列のエスケープ: `"`→`\"`、`\`→`\\`、`\n \r \t \b \f` はその記号、その他の U+0000–001F は `\u00xx`（**小文字** 16 進）、`/` はエスケープしない、非 ASCII はそのまま
  - 浮動小数は `PyJSON.formatDouble`: 基本は Swift の `Double.description`（`1800.0`、`3.2`、`1e-05`）だが、**絶対値が 2^53 以上 1e16 未満では Python の `repr` と表記が違う**ので直す（115,222 個の値で Python と一致を確認。T-45）。整数は 10 進。`null` / `true` / `false`
  - キー順は呼び手が決める（順序付きの値を渡す）。`sortKeys: true` のときはキーを UTF-16 ではなく**コードポイント順**で並べる（Python の `sort_keys`）
- `JSONEncoder` と `JSONSerialization` は内部 JSON の**書き出しにも読み取りにも**使わない（Date を数値で出す・`" : "` を出す。読み取りではキーの順を失い、文字列の先頭の U+FEFF を黙って落とし、`NaN` を受けない）。読み取りは `PyJSON.decode`（Python の `json.loads` 互換。キーの順を保つ、重複キーは後勝ちで位置は最初、`NaN` / `Infinity` を受ける、入れ子は 64 段まで（voicedock より浅い。X-33））を使い、真偽値を数として受けない。要求・結果（VDContract の `ContractJSON`）と config.json は例外で、`JSONEncoder` / `JSONSerialization` を使う（本アプリだけが読み書きする）
- 固定テスト: voicedock で実測した出力（transcript・analysis・timeline・指紋 `894a6142…b86f`）をバイト単位で照合（golden。§10.4）

**数値の丸め（`PyRound`）**: ログの `elapsed_s`・メトリクス・whisper の ms→秒は Python の `round(x, n)`（最近接偶数、10 進表現を往復して決める）と同じ結果にする。`PyRound.round(_:digits:)` だけを使う

**Swift の文字列比較の注意**: `==`・ハッシュ・辞書のキー・`<` は**正準等価**（NFC に揃えた上）で比べる（「が」と「か＋U+3099」が等しい）。
Python はコードポイント列で比べるので、sanitize・重複除去・Vault 索引・JSON のキー・partkey の照合・golden の比較では `PyText.scalarsEqual`（スカラー列の比較）を使う

**表示時刻とタイムゾーンの夏時間**: voicedock は Part の `started_at` の**固定オフセット**に秒を足して時刻を描いていた。本アプリの Raw の見出し（`##`・`###`）は保存文字列のオフセットを固定して描く（`ZonedTime(fixedOffsetSeconds:)`）ので一致する。
Timeline の見出しと `ZonedTime.iso` はタイムゾーンの規則で描くので、夏時間の切り替えをまたぐと voicedock と違う値になる（夏時間の無い地域では一致。X-32）。golden は Asia/Tokyo で作り、固定オフセットの例（`raw_note/dst_fixed_offset`）を 1 つ置く

---

## 6. 設定（`config.json`）

### 6.1 方針

- `AppConfig`（`Codable, Equatable, Sendable` の入れ子の struct）。JSON で `<HOME>/config.json`。**アプリが書く**（利用者が手で書く前提ではない）
- 先頭に `"schemaVersion": 1`。版が上がるときは `ConfigMigrator` が旧版から移行する（キーを足す PR で再起動ループに落ちた教訓 CFG-01 の置き換え）。v1 の移行器は「1 ならそのまま」だけを持つ
- **既定値は `AppConfig.defaults(timeZone:)` の 1 か所だけ**に書く。デコード時の欠落を既定値で埋めない（欠落は CV-39 違反）。例外は移行処理が明示的に足す場合だけ
- 読み込みの手順（`ConfigLoader.load(data:catalog:reaperConfObservation:) -> ConfigLoadResult`）:
  1. `JSONSerialization` で辞書にする（失敗 → CV-39）
  2. 全階層のキー集合を `AppConfig` の定義と照合: 未知のキー → CV-01（`CONFIG_UNKNOWN_KEY`）、欠けたキー → CV-39
  3. `JSONDecoder` で型に写す（型違い → CV-39、キーのパスを添える）
  4. 意味の検証（§6.4 の CV を表の順に全部。1 つ目で止めない）
- 違反は `ConfigViolation(rule: "CV-nn", code: ErrorCode, keyPath: String, message: String)` の配列で返す（例外にしない）。表示は `"<rule>  <code>  <keyPath>: <message>"`（区切りは空白 2 つ。voicedock config.py:67-69）
- **違反してもアプリを落とさない・再起動ループにしない。**「設定エラー」状態に入り、取り込み・処理・削除をすべて止め、パネルに違反の CV 番号と内容を出す（`config_invalid rule=… key=…` を ERROR で 1 件ずつ）。
  `config.json` を直して保存すれば（パネルの「設定を読み直す」か次回起動）解除される
- `config.json` が**無い**ときだけ `AppConfig.defaults(timeZone: TimeZone.current.identifier)` を書く（初回起動）。**在るが読めない・不正なときは上書きしない**
- **「無制限」を意味する既定値を置かない**。欠落・不正は規定の制限へ倒す（DEV-13: `0` は「即断しない」ではなく「全件即断」だった）。
  例外は明示された 2 つだけ: `transcription.threads = 0`（自動）と `sections.*.maxItems = null`（件数上限なし。voicedock と同じ）
- 書き込みは `AtomicFile`（`.config.json.tmp` → fsync → rename）。符号化は `JSONEncoder`（`[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`）＋ 末尾 `\n`
- GUI からの変更（Vault・Whisper モデル・LLM モデル）と有効化フローの変更は `ConfigStore`（actor）の `update(_:reaperConfObservation:)` だけが書く。**書く前に**、変更後の値と「これから（または今）の reaper.conf の値」で検証し、違反なら書かずに違反を返す
- **ロック 1 の食い違いの自動修復**: 読み込みで CV-30（config と reaper.conf の削除有効が食い違う）が出たら、設定エラーにする前に `DeletionEnabler.reconcileLock1()` で**両方を無効側に揃える**（reaper.conf を false → config を `deleteSourceAudio = false`・`deleteSkippedSource = false`・`mountMode = ro`）→ `config_warning rule=CV-30` を出して読み直す。揃えられなかったときだけ設定エラー（有効化・無効化の途中で落ちた場合の片方だけの状態を、安全側で終わらせる）

### 6.2 JSON の形と既定値（voicedock の値を継承。Docker のパスは廃止）

```json
{
  "schemaVersion": 1,
  "timeZone": "<初回起動時の TimeZone.current.identifier>",
  "vault": { "path": null, "marker": ".obsidian" },
  "device": {
    "includeVolumes": [],
    "excludeVolumes": ["Macintosh HD", "com.apple.TimeMachine.*", ".*"],
    "mountMode": "ro",
    "stabilityFastPathSeconds": 60, "stabilityIntervalSeconds": 3, "stabilityChecks": 2,
    "maxScanDepth": 3, "scanIntervalSeconds": 300, "snapshotMaxAgeSeconds": 900
  },
  "audio": {
    "timeoutFactor": 0.5, "minTimeoutSeconds": 180, "durationToleranceSeconds": 1.0,
    "freeSpaceMultiplier": 2.0, "freeSpaceMarginBytes": 2147483648, "stagingMaxBytes": 5368709120,
    "hashChunkBytes": 1048576, "inboxRetain": "normalized"
  },
  "session": { "blockGapSeconds": 3600, "idleCloseSeconds": 1800, "allowReopen": true, "maxParts": 64, "maxDurationSeconds": 86400 },
  "transcription": {
    "whisperModelID": "large-v3-turbo-q5_0", "language": "ja", "threads": 0,
    "timeoutFactor": 3.0, "minTimeoutSeconds": 600, "maxTimeoutSeconds": 21600, "minChars": 1,
    "vad": { "enabled": true, "modelID": "silero-v5.1.2", "threshold": 0.5,
             "minSpeechDurationMs": 250, "minSilenceDurationMs": 1000, "speechPadMs": 200 }
  },
  "llm": {
    "modelID": null, "contextSize": 32768, "temperature": 0.1, "topP": 0.9, "maxOutputTokens": 4096,
    "requestTimeoutSeconds": 1800, "maxCharsPerRequest": 20000, "maxSecondsPerRequest": 3600,
    "chunkOverlapChars": 500, "repairAttempts": 1,
    "analysis": {
      "sections": {
        "summary":    { "enabled": true, "heading": "## Summary" },
        "timeline":   { "enabled": true, "heading": "## Timeline" },
        "key_points": { "enabled": true, "heading": "## Key Points", "maxItems": 20 },
        "tasks":      { "enabled": true, "heading": "## Tasks",      "maxItems": 50 },
        "decisions":  { "enabled": true, "heading": "## Decisions",  "maxItems": 30 },
        "ideas":      { "enabled": true, "heading": "## Ideas",      "maxItems": 30 },
        "tags":       { "enabled": true, "heading": null,            "maxItems": 15 }
      },
      "order": ["summary", "timeline", "key_points", "tasks", "decisions", "ideas"],
      "customInstructions": ""
    }
  },
  "obsidian": {
    "maxTitleBytes": 180, "defaultTags": ["voice", "voicedock"],
    "raw":  { "folderTemplate": "Daily/Voice/Raw/{yyyymmdd}", "filenameTemplate": "{date} raw",
              "timestampIntervalSeconds": 300, "partBoundaryHeading": true },
    "wiki": { "folderTemplate": "Daily/Voice/Wiki/{yyyymmdd}", "filenameTemplate": "{date} Voice",
              "linkDailyNote": true, "linkAdjacentDays": true, "linkTags": true, "linkOnlyExisting": true,
              "vaultIndexCacheSeconds": 300, "maxLinks": 20 }
  },
  "cleanup": {
    "deleteSourceAudio": false, "deleteSkippedSource": false, "deleteNormalizedAfterTranscribe": true,
    "deleteEvaluationBackoffSeconds": [60, 300, 900, 3600], "deleteResultTimeoutSeconds": 3600
  },
  "retry": { "maxAttempts": 3, "backoffSeconds": [3, 10, 30] },
  "logging": { "level": "INFO", "unsafeLogContent": false }
}
```

- 型: 秒・バイト・件数・ミリ秒は整数（`Int`）。`timeoutFactor`・`durationToleranceSeconds`・`freeSpaceMultiplier`・`threshold`・`temperature`・`topP` は `Double`。`vault.path`・`llm.modelID`・`heading`・`maxItems` は null を許す
- `llm.analysis.sections` の 7 つのキー（voicedock の節名。LLM の JSON のキーと同じなので snake_case のまま）は固定。これ以外のキーは CV-01。**`maxItems` を持つのは `key_points` / `tasks` / `decisions` / `ideas` / `tags` の 5 つだけ**（voicedock と同じ。`summary` は文字数の上限 4000 がスキーマ側にあり、`timeline` は LLM のスキーマに入らないので、両者に `maxItems` を置くと「受理されるのに効かない設定」になる。CR-14）。`summary` / `timeline` に `maxItems` を書いたら CV-01
- `vault.path` と `llm.modelID` の **null は違反ではなく「未設定」**。処理を止め（§5.4 のガード）、パネルの「はじめに」と「要対応」に出す
- `transcription.threads = 0` は `min(ProcessInfo.processInfo.activeProcessorCount, 8)`（voicedock は `os.cpu_count()` = 論理 CPU 数）
- `logging.level` の綴りは voicedock と同じ大文字。ログ行の表記は §8.15
- GUI・由来の対応:

| キー | GUI | voicedock の由来 |
|---|---|---|
| `timeZone` | 詳細に表示のみ | timezone |
| `vault.path` | ○（Vault を選ぶ） | obsidian.root |
| `vault.marker` | × | obsidian.vault_marker（**空で無効化は廃止**。X-18） |
| `device.*` | × | helper.conf（INCLUDE_VOLUMES 等）、`scanIntervalSeconds` は StartInterval、`snapshotMaxAgeSeconds` は import.helper_heartbeat_max_age_seconds |
| `audio.*` | × | audio.ffmpeg_timeout_factor / ffmpeg_min_timeout_seconds / duration_tolerance_seconds と import.free_space_multiplier / free_space_margin_bytes / staging_max_bytes / hash_chunk_bytes / inbox_retain |
| `session.*` | × | session.* |
| `transcription.whisperModelID` | ○ | transcription.model（パス → カタログ ID） |
| `transcription.vad.modelID` | × | transcription.vad.model（パス → カタログ ID） |
| `llm.modelID` | ○ | compose.yaml の models |
| `llm.contextSize` | × | compose.yaml の context_size |
| `llm.*`（その他）・`obsidian.*` | × | 同名（snake_case → camelCase） |
| `cleanup.deleteSourceAudio` / `deleteSkippedSource` | 有効化フローだけ（§8.9.8） | cleanup.* |
| その他の `cleanup.*`・`retry.*`・`logging.*` | × | 同名 |

- **廃止する voicedock のキー（読まれていなかったもの・Docker 由来・固定値になったもの）:** `device.root`、`device.poll_interval_seconds`（Worker は 30 秒周期固定）、`transcription.engine`、
  `transcription.executable`（バンドル）、`wiki.timeline`、`audio.ffmpeg` / `ffprobe` / `ffprobe_timeout_seconds` / `target_*`、`import.inbox_root` / `staging_root`、`session.group_by`、
  `llm.endpoint_env` / `model_env`、`llm.prompts.*`（プロンプトはバンドルの固定資源）、`cleanup.queue_root`、`cleanup.retain_transcript_days`（常に無期限）、`database.*`（busy_timeout は 10000 固定）、`logging.format`
- 「受理されるのに効かない設定」を作らない（NOTE-01 / NOTE-02 / CFG-02）。**全キーに「そのキーを変えると振る舞いが変わる」テストを 1 本以上置く**（`ConfigEffectTests`。キーの一覧は `AppConfig` の定義から機械的に作り、テストの無いキーがあれば落ちる）

### 6.3 GUI に出すのは 4 つだけ

Vault の場所、Whisper モデル、LLM モデル、ログイン時に起動（SMAppService の状態であって `config.json` には持たない）。
削除関連は有効化フロー経由でしか変えられない。それ以外は `config.json` を Finder で開くボタン（詳細）と「設定を読み直す」ボタンだけ。
手で編集された場合は次回読み込みで検証し、違反なら設定エラー状態（6.1）。

### 6.4 検証規則（CV。「満たすべき条件」を書く。この表の順に全部評価する。ただし CV-14 は CV-13 より先に判定する）

番号は voicedock の V と**意味が同じものだけ**同じ番号にする。欠番（再利用しない）: CV-02〜07（V-2〜7 はキー廃止か別物）、CV-15、CV-20、CV-21、CV-23〜28（V-23/24 はファイル検査で意味が違う・V-25 はパス → ID に変わった・V-26 はパネルの常時表示で代替・V-27/28 は廃止）、CV-31（V-31 は別物）、CV-34〜38。

| # | 規則 | コード | 由来 |
|---|---|---|---|
| CV-01 | 未知のキーが無い（全階層） | CONFIG_UNKNOWN_KEY | V-1 |
| CV-08 | `session.blockGapSeconds >= 0` | CONFIG_INVALID_VALUE | V-8 |
| CV-09 | `retry.backoffSeconds.count >= retry.maxAttempts` | CONFIG_INVALID_VALUE | V-9 |
| CV-10 | `llm.maxCharsPerRequest > llm.chunkOverlapChars * 2` | CONFIG_INVALID_VALUE | V-10 |
| CV-11 | raw / wiki の `folderTemplate` が相対パス（`/` で始まらない）で、`/` で分けた要素に `..` が無い | CONFIG_INVALID_VALUE | V-11 |
| CV-12 | `raw.folderTemplate != wiki.folderTemplate` | CONFIG_INVALID_VALUE | V-12 |
| CV-13 | 4 つのテンプレート（raw.folder / raw.filename / wiki.folder / wiki.filename）の `{…}` が `{yyyymmdd}` `{date}` `{time}` だけ | CONFIG_INVALID_VALUE | V-13 |
| CV-14 | `wiki.filenameTemplate` に `{title}` を含まない（**CV-13 より先に判定し、該当したら CV-13 はそのテンプレートについて出さない**） | CONFIG_INVALID_VALUE | V-14 |
| CV-16 | `obsidian.maxTitleBytes` が 1〜255 | CONFIG_INVALID_VALUE | V-16 |
| CV-17 | `analysis.order` の各要素が sections の 7 キーのどれかで、重複が無い | CONFIG_INVALID_VALUE | V-17 |
| CV-18 | `sections.summary.enabled == true`（DN-8 の前提） | CONFIG_INVALID_VALUE | V-18 |
| CV-19 | `order` に載る各節の `heading` が null でなく、`#` で始まり、改行（`\n` `\r`）を含まない | CONFIG_INVALID_VALUE | V-19 |
| CV-22 | `audio.stagingMaxBytes > audio.freeSpaceMarginBytes` | CONFIG_INVALID_VALUE | V-22 |
| CV-29 | `audio.inboxRetain` が `normalized` か `raw_saved` | CONFIG_INVALID_VALUE | V-29 |
| CV-30 | ロック 1 が食い違っていない: reaper.conf が読めるとき（`.valid`）、`cleanup.deleteSourceAudio == reaperConf.deleteSourceAudio`（どちら向きの食い違いも違反）。reaper.conf が無い・読めないときはこの規則を評価しない（不明は §8.9.2 が「要求を書かない」側に倒す）。違反は §6.1 の修復を先に試す | CONFIG_LOCK_MISMATCH | V-30 |
| CV-32 | `TimeZone(identifier: timeZone) != nil` | CONFIG_INVALID_VALUE | V-32 |
| CV-33 | `!(cleanup.deleteSourceAudio == true && device.mountMode == "ro")` | CONFIG_LOCK_MISMATCH | V-33 |
| CV-39 | JSON として読め、全階層で必要なキーがすべて在り、型が合う（`schemaVersion` が 1 であることを含む） | CONFIG_INVALID_VALUE | voicedock の規則 ID `-` |
| CV-40 | `vault.path` が null か、`/` で始まる絶対パスの文字列（**存在は検査しない**。未接続の外付けは実行時のガード。§8.7） | CONFIG_INVALID_VALUE | 新規 |
| CV-41 | `vault.marker` が空でなく、`/` を含まず、`.` でも `..` でもない | CONFIG_INVALID_VALUE | 新規（X-18） |
| CV-42 | `llm.modelID` が null か、カタログの LLM の ID か、`custom:<64 桁の小文字 16 進>` | CONFIG_INVALID_VALUE | 新規 |
| CV-43 | `cleanup.deleteSkippedSource == true` なら `cleanup.deleteSourceAudio == true` | CONFIG_INVALID_VALUE | 新規 |
| CV-44 | `transcription.whisperModelID` がカタログの whisper の ID（**ファイルの有無は検査しない**。未入手は実行時のガード） | CONFIG_INVALID_VALUE | 新規 |
| CV-45 | `transcription.vad.enabled` なら `vad.modelID` がカタログの vad の ID（同上） | CONFIG_INVALID_VALUE | 新規 |
| CV-46 | `device.snapshotMaxAgeSeconds > device.scanIntervalSeconds` | CONFIG_INVALID_VALUE | 新規（DH-17 相当） |
| CV-47 | `device.includeVolumes` と `excludeVolumes` の各要素が空文字でない | CONFIG_INVALID_VALUE | helper.conf 検査 4 |
| CV-48 | `device.mountMode` が `ro` か `rw` | CONFIG_INVALID_VALUE | helper.conf 検査 5 |
| CV-49 | `device.stabilityFastPathSeconds >= 1`、`stabilityIntervalSeconds >= 1`、`stabilityChecks >= 1`、`maxScanDepth >= 1` | CONFIG_INVALID_VALUE | helper.conf 検査 7 |
| CV-50 | `device.scanIntervalSeconds >= 60` | CONFIG_INVALID_VALUE | 新規 |
| CV-51 | `llm.contextSize >= llm.maxCharsPerRequest + llm.maxOutputTokens + 2048`（20,000 文字のチャンクが収まらないと HTTP 400 を繰り返す） | CONFIG_INVALID_VALUE | 新規 |
| CV-52 | `cleanup.deleteEvaluationBackoffSeconds` が空でなく各要素 `>= 0`、`cleanup.deleteResultTimeoutSeconds >= 60` | CONFIG_INVALID_VALUE | 新規 |
| CV-53 | `retry.maxAttempts >= 1`、`retry.backoffSeconds` の各要素 `>= 0` | CONFIG_INVALID_VALUE | 新規 |
| CV-54 | `logging.level` が `DEBUG` / `INFO` / `WARNING` / `ERROR` のどれか | CONFIG_INVALID_VALUE | 新規 |
| CV-55 | transcription の数値: `threads >= 0`、`timeoutFactor > 0`、`1 <= minTimeoutSeconds <= maxTimeoutSeconds`、`minChars >= 1`、`0 < vad.threshold < 1`、vad の 3 つの ms `>= 0`、`language` が空でない | CONFIG_INVALID_VALUE | 新規 |
| CV-56 | llm の数値: `0 <= temperature <= 2`、`0 < topP <= 1`、`maxOutputTokens >= 1`、`requestTimeoutSeconds >= 1`、`maxSecondsPerRequest >= 1`、`chunkOverlapChars >= 0`、`repairAttempts >= 0`、各節（`maxItems` を持つ 5 つ）の `maxItems` は null か `>= 1` | CONFIG_INVALID_VALUE | 新規 |
| CV-57 | session の数値: `idleCloseSeconds >= 1`、`maxParts >= 1`、`maxDurationSeconds >= 1` | CONFIG_INVALID_VALUE | 新規 |
| CV-58 | audio の数値: `timeoutFactor > 0`、`minTimeoutSeconds >= 1`、`durationToleranceSeconds >= 0`、`freeSpaceMultiplier >= 1`、`freeSpaceMarginBytes >= 0`、`hashChunkBytes >= 4096` | CONFIG_INVALID_VALUE | 新規 |
| CV-59 | obsidian の数値: `raw.timestampIntervalSeconds >= 0`（0 は「見出しを入れない」。voicedock と同じ）、`wiki.vaultIndexCacheSeconds >= 0`、`wiki.maxLinks >= 0`、`defaultTags` の各要素が空でない | CONFIG_INVALID_VALUE | 新規 |

- 各 CV にテストを 1 本以上（違反の例で落ちる・境界値で通る）。テストの表示名は `CV-nn` で始める（§10.3 の SPEC 同期が SPEC の表とテストを結ぶ）

---

## 7. データベース

### 7.1 接続

GRDB の `DatabasePool`（WAL）。接続ごとに `PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 10000; PRAGMA synchronous = FULL;`（`Configuration.prepareDatabase` で設定）。**GRDB 7.11.1 はプールを作った後に writer で `PRAGMA synchronous = NORMAL` を実行する**（Database.swift:531-539）ので、プールを作った後に writer で `synchronous = FULL` を設定し直し、`PRAGMA synchronous` が `2` であることを確かめる（違えば起動エラー）。`Row` の非 Optional の添字は NULL・型違いでプロセスを落とすので、行の読み取りは `Row` から Optional で読んで検査する（`StoreError.corruptRow`）。
開いた直後に `PRAGMA journal_mode` が `wal` であることを確かめ、でなければ起動エラー（CONC-03）。
**診断や状態表示が DB ファイルを作らない**ように、読み取り専用の経路（`ReadOnlyStore.open(url:)`）ではファイルの存在を確かめてから `Configuration.readonly = true` で開き、マイグレーションを当てない。
ファイルが無ければ「全件 0」として表示する（CONC-06）。

### 7.2 スキーマ（初版 = voicedock のマイグレーション 0001〜0003 を 1 本にまとめたもの＋差分）

voicedock `migrations/0001_initial.sql`、`0002_delete_request_id.sql`、`0003_duplicate_of.sql` を**列名・型・制約・索引とも同一**で 1 本にまとめる
（列の意味は voicedock SPEC §8.2 / §8.3）。**列名を変えない**（移植時の取り違えを防ぐ）。作成順は sessions → recordings（外部キーのため）。

```sql
CREATE TABLE sessions (
    session_key         TEXT    PRIMARY KEY NOT NULL,
    day_date            TEXT    NOT NULL,
    device_id           TEXT    NOT NULL,
    started_at          TEXT,
    ended_at            TEXT,
    recorded_seconds    REAL,
    part_count          INTEGER NOT NULL DEFAULT 0,
    failed_part_count   INTEGER NOT NULL DEFAULT 0,
    title               TEXT,
    analysis_path       TEXT,
    raw_output_path     TEXT,
    raw_output_sha256   TEXT,
    output_path         TEXT,
    output_sha256       TEXT,
    status              TEXT    NOT NULL,
    retry_count         INTEGER NOT NULL DEFAULT 0,
    regenerated_count   INTEGER NOT NULL DEFAULT 0,
    delete_attempts     INTEGER NOT NULL DEFAULT 0,
    error_code          TEXT,
    error_message       TEXT,
    source_deleted_at   TEXT,
    updated_at          TEXT    NOT NULL
);
CREATE INDEX idx_sessions_status ON sessions (status);
CREATE INDEX idx_sessions_day    ON sessions (day_date);

CREATE TABLE recordings (
    partkey               TEXT    PRIMARY KEY NOT NULL,
    device_id             TEXT    NOT NULL,
    source_folder         TEXT    NOT NULL,
    transmitter_id        TEXT    NOT NULL,
    mic_index             INTEGER NOT NULL,
    started_at            TEXT    NOT NULL,
    duration_seconds      REAL,
    ended_at              TEXT,
    source_path           TEXT,
    source_size           INTEGER,
    source_mtime          REAL,
    sha256                TEXT,
    sha256_helper         TEXT,
    inbox_path            TEXT,
    staging_dir           TEXT,
    normalized_path       TEXT,
    transcript_path       TEXT,
    session_key           TEXT REFERENCES sessions(session_key) ON DELETE SET NULL,
    status                TEXT    NOT NULL,
    retry_count           INTEGER NOT NULL DEFAULT 0,
    error_code            TEXT,
    error_message         TEXT,
    source_deleted_at     TEXT,
    updated_at            TEXT    NOT NULL,
    delete_request_id     TEXT,                          -- voicedock 0002
    duplicate_of          TEXT,                          -- voicedock 0003
    needs_recopy          INTEGER NOT NULL DEFAULT 0     -- 本アプリ（v1_initial に含める）
);
CREATE UNIQUE INDEX idx_recordings_sha ON recordings (sha256) WHERE sha256 IS NOT NULL;
CREATE INDEX idx_recordings_status   ON recordings (status);
CREATE INDEX idx_recordings_session  ON recordings (session_key);
CREATE INDEX idx_recordings_started  ON recordings (started_at);

CREATE TABLE events (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type   TEXT NOT NULL,
    entity_key    TEXT NOT NULL,
    from_status   TEXT,
    to_status     TEXT NOT NULL,
    error_code    TEXT,
    detail        TEXT,
    created_at    TEXT NOT NULL
);
CREATE INDEX idx_events_entity ON events (entity_type, entity_key, id);

-- 本アプリ: 取り込みで飛ばす録音（§8.13）。v1 では書く者がいないので常に空（F-60）
CREATE TABLE imported_keys (
    partkey      TEXT PRIMARY KEY NOT NULL,
    source_note  TEXT NOT NULL,          -- Vault からの相対パス
    imported_at  TEXT NOT NULL
);
```

- 列数: recordings 27（voicedock 26 + `needs_recopy`）、sessions 22、events 8、imported_keys 3。テストで固定する
- voicedock の `schema_version` 表は**作らない**（GRDB の `grdb_migrations` 表が代わる）
- 列の意味の読み替え:

| 列 | 本アプリでの意味 |
|---|---|
| `recordings.source_path` | ボリュームルートからの relpath（`partkey == device_id + "/" + source_path` が不変量） |
| `recordings.transmitter_id` / `mic_index` | ファイル名の `TX01` / `MIC002 → 2` |
| `recordings.started_at` / `ended_at` | ファイル名の時刻に設定のタイムゾーンを付与した ISO 文字列 / `started_at + duration_seconds`（秒未満切り捨て。duration が NULL なら NULL） |
| `recordings.sha256_helper` | IngestService がコピー時に計算した原本の SHA-256 |
| `recordings.sha256` | 変換時に再計算した SHA-256。**重複 Part は NULL のまま**（部分 UNIQUE のため双子と同値を書けない）で `duplicate_of` に双子の partkey |
| `recordings.source_size` / `source_mtime` | **デバイス上の原本**を stat した値（`st_mtimespec` の小数付き） |
| `recordings.inbox_path` / `normalized_path` / `transcript_path` / `staging_dir` | `<HOME>` からの相対パス |
| `recordings.needs_recopy` | 1 = inbox の原本を取り直す必要がある（NORMALIZED_MISSING / SOURCE_HASH_MISMATCH で立つ。再コピーの登録で 0 に戻す） |
| `sessions.raw_output_path` / `output_path` | Vault からの相対パス |
| `sessions.day_date` | `YYYY-MM-DD`（`#2` の Session も同じ日付） |

- マイグレーションは GRDB の `DatabaseMigrator`。識別子は `v1_initial`、`v2_...`。**列の追加は末尾へ。テーブルの作り直しをしない**
- **既存 DB に未適用のマイグレーションがあるときだけ**、当てる前に SQLite の backup API（`try pool.backup(to: DatabaseQueue(path: <backup path>))`）で
  `voicedock.sqlite.backup-<最後に適用済みの識別子>-<stamp>` を作る（`stamp` は ISO 秒・オフセット付きから `:` と `-` を除いたもの。例 `20260830T070012+0900`）。
  **初回作成時はバックアップしない。ファイルコピーは禁止**（WAL。CONC-04）
- `events` は追記のみ。時刻列はすべて §5.7 の ISO 文字列（例 `2026-08-30T07:00:12+09:00`）
- `recordings (sha256) WHERE sha256 IS NOT NULL` の UNIQUE 部分索引が二重処理の最終防壁（DEL-25）
- **recordings / sessions に GRDB の永続化 API（`PersistableRecord` / `MutablePersistableRecord` の `insert` / `update` / `save`）を使わない。**SQL は `VDStore` の中の関数だけが書く（PT-05）
- 同じ問い合わせを複数箇所に手書きしない。`Store` のメソッドに寄せる（CONC-02）。問い合わせの並び順（voicedock db.py:436-545 と同じ）:
  - Part の一覧: `ORDER BY started_at, partkey`（未分組・Session の Part・状態別・非終端）
  - Session の状態別: `ORDER BY session_key`
  - FAILED の一覧（requeue）: `ORDER BY updated_at, <key>`
  - 削除評価の Session: `ORDER BY updated_at, session_key`
  - `failedFrom`: `SELECT from_status FROM events WHERE entity_type = ? AND entity_key = ? AND to_status = ? ORDER BY id DESC LIMIT 1`（3 つ目に `FAILED` の rawValue を束縛する。SQL の文字列に状態名を書かない。PT-06）

---

## 8. コンポーネント仕様

### 8.1 IngestService（デバイス → inbox）

参照: voicedock `helper/voicedock-ingest`、SPEC §5.4 / §10.1〜§10.3、POC.md。

**起動契機**
- `NSWorkspace.didMountNotification` / `didUnmountNotification` / `didWakeNotification`、IngestService の開始時（Worker.start() の後）、`scanIntervalSeconds`（300）ごと、Worker からの `scanNow()`（reaper の後）
- 走査は actor 内で直列。**走査中に届いた契機は 1 つの「再走査要求」フラグにまとめ、走査が終わった後に 1 回だけ走査し直す**（voicedock のロック `already_running` の置き換え）。
  自分の再マウントで起きるマウント／アンマウント通知もこれでまとまる（途中で 0 台の snapshot を作らない）

**1 回の走査の手順**
1. （欠番。v1.1 の共存ガード（voicedock の Helper が登録されていたら走査しない）は F-61 で取り下げた。voicedock と同時には動かさない）
2. `FileLock` で `<HOME>/state/reaper.lock` に `flock(LOCK_EX | LOCK_NB)` を掛ける。取れなければ 1 秒待って再試行し、130 回で諦めてこの回を見送る（`scanNow()` は nil を返す）。走査が終わるまで保持する
3. `/Volumes` 直下を列挙し（`.` で始まる名前は黙って無視）、各エントリにデバイス判定（下記）を適用する
4. 判定を通った各デバイスで、読み取り専用の確保（`mountMode == ro` のとき）→ `statfs` で `readOnly` と空き容量を観測 → ファイルの走査 → 安定性判定 → コピー
5. 全デバイスを終えたら snapshot を**1 つ**作って公開する（途中経過は snapshot にしない。進捗は別の値 `IngestActivity` で UI に出す）→ ロックを外す

**デバイス判定**（この順に適用し、最初に当たった理由で対象外にする。voicedock §5.4 ＋ 本計画の追加）
1. `includeVolumes` が空でなければ、名前がどの glob にも一致しないものを除外（`not_included`）。**空なら規則 1 を適用しない**（全エントリが規則 2 へ進む）。名前だけで判定し stat しない（DEV-05）
2. `excludeVolumes` のどれかの glob に一致するものを除外（`excluded`。`fnmatch(pattern, name, 0)`。正規表現ではない。`.*` は「`.` で始まる」。DEV-07）
3. エントリ自体が symlink（`lstat`）なら除外（`symlink`。`/Volumes/Macintosh HD -> /` が実在する。DEV-08）
4. マウント点であること: `statfs` の `f_mntonname` が、エントリの realpath と一致（`not_a_mount_point`。本計画の追加。判定は `MountInspector` プロトコル経由にし、単体テストでは差し替える）
5. **列挙できるか**: `opendir` を試す。**失敗したら errno によらず `not_listable`**（errno を detail に残す）。`EPERM` のときだけ TCC の案内（DR-11）を出す。
   `access(2)` は TCC の拒否に対する結果が OS の版で変わる（voicedock の時点では成功した。macOS 26.6 では EPERM。P0-01）ので判定に使わない（DEV-03）。テストの `chmod 000` は `EACCES` になるので、EPERM だけを見ると「録音なし」に化ける
6. 直下に（`.` 始まりを除き）「フォルダ規則に一致するディレクトリ」か「ファイル規則に一致するファイル（denoised も可）」が 1 つ以上ある。無ければ対象外（`no_recordings`）。
   全部消した後もフォルダは残る（reaper はディレクトリを消さない）ので、録音 0 件のデバイスはここを通る（DEV-19）
7. （欠番。v1 の規則 7 は走査の規則へ移した）
8. エントリ名（= device_id の候補）がボリューム名（`URLResourceValues.volumeName`）と一致する（`mount_name_mismatch`。本計画の追加）。
   同名のボリュームがあったり再マウントでパスに ` 1` が付くと、partkey が変わって全件を再コピーし DUPLICATE_CONTENT が並ぶため。パネルの「要対応」に「デバイスを挿し直してください」と出す
9. `DeviceID.isValid(name)`（§4.2。`:` を含む名前など）（`invalid_device_id`。本計画の追加。パネルに改名の案内を出す）

- 対象外の理由は `volume_skipped name=… reason=…`（DEBUG）。規則 5・8・9 で外れたものは利用者の操作が要るので、snapshot の `unavailable` に載せる（規則 5 は errno も `notListableErrno` に載せる。DR-11 の「EPERM のときだけ TCC の案内」に使う）
- 合格したものが「デバイス」。**device_id = エントリ名**

**読み取り専用の確保（ロック 2-B の実施側）** — `mountMode == ro` のとき、各デバイスで（`Remounter` プロトコル経由。単体テストでは差し替える）:

```text
statfs(path).f_flags & MNT_RDONLY != 0 → 何もしない（既に ro。毎回 unmount し直さない: DEL-31）
node = statfs(path).f_mntfromname                         // 例 /dev/disk4（diskutil info の解析は不要）。/dev/ で始まらなければ reason=no_device_node
/usr/sbin/diskutil unmount <path>                         // ProcessRunner、argv 配列、LC_ALL=C、タイムアウト 60 秒。失敗 → reason=unmount_failed
/usr/sbin/diskutil mount readOnly <node>                  // 同上。失敗 → reason=mount_failed
マウント一覧（getmntinfo）から f_mntfromname == node の項目を探し直し、そのパスで規則 8 を再判定（一致しなければ mount_name_mismatch）
再度 statfs で MNT_RDONLY を観測 → 偽なら reason=still_writable
```

- 失敗しても取り込みは続行する（記録の保護が優先）。理由語は `no_device_node` / `unmount_failed` / `mount_failed` / `still_writable` の固定語で、`remount_failed name=… reason=…`（WARNING）。diskutil の出力文言は使わない
- **snapshot に書く `readOnly` は必ず statfs の観測値**。試行の成否から推論しない（DEL-31）。`mountMode == rw` でも観測する。観測できなければ nil
- `diskutil mount readOnly -mountPoint <元のパス> <node>` でパスが保たれるかは P0-02 で確かめ、保たれるならそちらを使う（その場合も探し直しと規則 8 の再判定は残す）
- `rw` へ戻すのは挿し直し（アプリは rw への再マウントをしない。有効化フローも「挿し直してください」と表示するだけ）
- DiskArbitration は ro ボリュームの unmount を拒むことがあり、5 分ごとの unmount で 34 回中 3 回 EBUSY になった（voicedock #107）。既に ro なら何もしないのはこのため

**ファイルの走査**（voicedock-ingest:321-352 と同じ深さ。本計画は symlink を辿らない）
- ルートから再帰し、ファイルは最大 `maxScanDepth` 階層（既定 3: `root/a/b/file`）まで。ルート直下のファイルが 1 階層目
- `.` で始まるエントリは黙って無視する（`.Trashes`・`.Spotlight-V100`・`._*` を含む。DEV-09）
- `lstat` で判定し、**symlink はファイルもディレクトリも無視する**（voicedock はファイルの symlink を辿っていた）。ディレクトリはフォルダ規則を見ずに全部降りる
- ファイル規則に一致する通常ファイルを relpath の一覧に入れる（`_orig` も denoised も。削除の確認用）。`_orig` だけが取り込みの候補
- ボリューム直下の録音は取り込むが、親フォルダが規則外なので削除対象にはならない（RV-11 `folder_rule`）
- **サブディレクトリの列挙（`opendir` / `readdir`。途中の失敗も含む）に失敗したら、または項目の `lstat` が `ENOENT` 以外で失敗したら**（`complete == false`）、そのデバイスは snapshot の `devices` に入れず `unavailable`（`not_listable`）に載せる（一覧に載らないファイルを「消えた」と誤読させない。F-67）。
  `lstat` の `ENOENT` は列挙から `lstat` までの間に消えた項目なので、無いものとして飛ばす（`complete` は偽にしない）。`notListableErrno` は規則 5（ボリュームのルートの `opendir`）の errno だけで、走査の途中の失敗では載せない（TCC の案内を出さない）
- **深さの上限の外は観測しない**: 上限の外（`maxScanDepth` を超える階層）は列挙も `lstat` もしないので、そこに在るものは一覧に含まれず、`complete` も偽にしない（F-67）。
  上限の外の録音は取り込みの候補にならないので Part にならず、削除（`preIdentityCheck` は一覧に relpath が在ることを要る）の対象にも、F-64 の自動完了の対象（Part を持つ RAW_SAVED だけ）にもならない。
  上限ちょうどの階層のディレクトリがあっても偽にしないのは、偽にすると取り込みの範囲に無いものでデバイスごと `not_listable` になり、削除と F-64 の完了が止まるだけで守るものが無いため。
  例外は設定で `maxScanDepth` を下げたとき: 以前の深さで取り込んだ Part の元ファイルは一覧に無く見え、RAW_SAVED なら F-64 で完了しうる（消さない側。元ファイルはデバイスに残る）
- `complete == false` になっても、その回の取り込み（列挙できた範囲の候補の安定性判定とコピー）は続ける。観測に載せないのは snapshot だけで、前回の snapshot の一覧を持ち越さない（古い一覧を今の観測として使わない）。
  一時的な失敗（抜き差しの途中の `EIO` など）なら、次の走査（契機のたび・最長 `scanIntervalSeconds`）で `devices` に戻る。その間は削除の要求・F-64 の完了・根拠 B が待ち、パネルの「要対応」に「中身を読めません」が出る。
  そのデバイスが唯一の接続だったなら、戻ったときに `connectEpoch` が 1 増え、接続の立ち上がり（§5.4 契機 2）として FAILED の再評価が 1 回余分に走る（従来のサブディレクトリの列挙の失敗と同じ扱い）
- 再マウントの途中でデバイスが外れた（マウント点でなくなった）場合は、そのデバイスを観測しない（親の FS を観測しない）

**安定性判定**（voicedock §10.3 の原文どおり）
1. 候補（`_orig` かつ「DB に行が無い」か「行の `needs_recopy = 1`」、かつ `imported_keys` に無い）の `(size, mtime)` を一括取得（取れないものは今回見送り）
2. `mtime <= now − stabilityFastPathSeconds(60)` は即「安定」（fast path）
3. 残りについて、**ちょうど `stabilityChecks`（2）回**「値を控える → `stabilityIntervalSeconds`（3）秒待つ → 一括再取得」を繰り返し、size と mtime が控えと一致した回数を数える。
   1 度でも不一致ならこの回は見送り（`file_not_stable relpath=…` は DEBUG。次の走査で再判定）
- 待ち時間は `interval × checks` でファイル数に比例しない（DEV-14。25 件で 20 秒未満のテスト）

**コピー**（1 ファイルずつ。`DeviceReader` だけがデバイス上のファイルを開く）
1. 宛先 `inbox/<device_id>/<folder>/<name>`（ボリューム直下なら `inbox/<device_id>/<name>`）。親ディレクトリを作り、`.<name>.partial` を `O_WRONLY|O_CREAT|O_TRUNC` で開く
2. デバイス上の原本を `open(O_RDONLY | O_NOFOLLOW)` で開き、`fstat` の size・mtime が安定性判定の値と一致することを確かめる（違えば `copy_failed recording_key=… reason=changed`（INFO）を出して見送り、次の走査で再判定）。
   `audio.hashChunkBytes`（1 MiB）ずつ読み、`SHA256` を更新しながら書く（**USB は 1 回だけ読む**）
3. `fsync` → 書いたバイト数が控えの size と一致するか確認（違えば `copy_failed reason=copy_size_mismatch`、`.partial` を消して次へ）
4. `rename` で `<name>` に確定 → **その後で** DB に登録する。この順序を変えない（DEV-16。「本体が先、記録が後」。静的検査 PT-16 でも固定）
   - 行が無い: `insertRecording`（DISCOVERED）。`source_size` / `source_mtime` は**原本の stat 値**、`sha256_helper`、`inbox_path`、`source_path = relpath`、
     `source_folder` = relpath の親（直下なら空文字）、`transmitter_id` / `mic_index` / `started_at`（ファイル名の時刻にタイムゾーンを付与）、`duration_seconds`（下記）、`ended_at`。`part_discovered recording_key=…`
   - `needs_recopy = 1` の行: `inbox_path`・`sha256_helper`・`source_size`・`source_mtime` を更新し `needs_recopy = 0`（状態は変えない。§5.4 の契機 4 が再評価する）
   - どちらも `copy_completed recording_key=… bytes=… recopy=<true|false>`
5. 読み取りエラー（抜かれた等）→ `.partial` を削除し `copy_failed recording_key=… reason=read_error`。inbox 側の書き込み・rename・DB 登録の失敗は `reason=write_error`。次の走査で再試行
- デバイスへは**読み取りと diskutil のマウント操作以外を一切しない**（PR-11）。原本は `O_RDONLY | O_NOFOLLOW` でしか開かない
- 1 本コピーするたびに `IngestActivity`（走査中か・デバイス名・何件中何件・`lastActivityAt`）を更新して UI に出す。1 日分で約 11 分かかる（POC 実測 11.9 MB/s）。**「コピーが終われば抜いてよい」を表示する**
- 登録時に `duration` を `AudioProbe`（VDAudio。`AVAudioFile` の `length / fileFormat.sampleRate`）で調べる。失敗しても NULL のまま登録する（`part_discovered … error_code=AUDIO_PROBE_FAILED`）
- DJI Mic 3 は PC に接続すると録音を自動停止する（voicedock POC）。録音中のファイルが残ることはまれだが、安定性判定はそのまま行う

**snapshot（`DeviceSnapshot`）**

```swift
public struct DeviceSnapshot: Sendable {
    public let generation: UInt64            // 走査ごとに +1（単調増加。時刻比較をしない）
    public let completedAt: Instant          // 表示と「新鮮さ」の判定用
    public let connectEpoch: UInt64          // 「前回公開した snapshot のデバイスが 0 台（か前回が無い）→ 今回 1 台以上」のたびに +1
    public let devices: [String: DeviceObservation]      // key = device_id
    public let unavailable: [String: String]             // 利用者の操作が要る対象外（名前 → 理由語: not_listable / mount_name_mismatch / invalid_device_id）
    public func isFresh(now: Instant, maxAgeSeconds: Int) -> Bool   // now − completedAt <= maxAge
}
public struct DeviceObservation: Sendable {
    public let deviceID: String
    public let mountPath: String
    public let deviceNode: String?
    public let readOnly: Bool?               // nil = 観測できなかった（「偽」と区別する）
    public let freeBytes: Int64?             // statfs の f_bavail × f_bsize。取れなければ nil
    public let relpaths: Set<String>         // _orig も denoised も全部（削除確認用）
}
public struct IngestActivity: Sendable { public let scanning: Bool; public let deviceID: String?; public let copied: Int; public let total: Int; public let lastActivityAt: Instant? }
```

- デバイス 0 台のときは `devices` が空。**「0 台」と「読み取り専用かどうか不明」を混同しない**（DEL-32。voicedock の Helper は 0 台のとき `mount_readonly: false` を書いていた）
- 録音 0 件のデバイスも `relpaths` が空の観測として載せる（全部消した後は 0 件が定常状態。DEV-19）
- Worker は `connectEpoch` の増加を「接続の立ち上がり」として使う（§5.4 契機 2）。snapshot はコピーの後に公開するので、立ち上がりの再評価は再コピーの後になる
- **沈黙の判定**（§8.11）: 走査中か、`max(completedAt, lastActivityAt)` が `snapshotMaxAgeSeconds` 以内なら「沈黙」とみなさない（voicedock #117: 11 分のコピー中に「止まっている」と誤報した）

### 8.2 VDProcess（子プロセス）

- **`Foundation.Process` を使わない。**`posix_spawn` を直接使う（プロセスグループを分けるため）
  - `POSIX_SPAWN_SETPGROUP`（pgroup 0 = 新しいグループ）、`POSIX_SPAWN_CLOEXEC_DEFAULT`。stdin は `/dev/null`、stdout / stderr はパイプ（`posix_spawn_file_actions_adddup2`）
  - `posix_spawn` で子として起動することで、TCC の responsible process がアプリのまま保たれる（voicedock で `execv` だと許可が届かなかった。DEV-04）
- API は 2 つ（どちらも `ProcessRunner` actor）:

```swift
public struct ProcessSpec: Sendable { public let executable: URL; public let arguments: [String]; public let environment: [String: String] }
public struct ProcessResult: Sendable {
    public enum Termination: Sendable, Equatable { case exited(Int32), signaled(Int32), timedOut, spawnFailed(errno: Int32) }
    public let termination: Termination
    public let stdoutTail: Data      // 末尾 64 KiB（--help の検査用）
    public let stderrTail: Data      // 末尾 4 KiB
}
/// 完了まで待つ（whisper-cli・diskutil・reaper・--help 検査）
func run(_ spec: ProcessSpec, timeout: Duration) async -> ProcessResult
/// 起動して手放す（llama-server）。止めるのは RunningProcess.terminate
func spawn(_ spec: ProcessSpec) async throws(SpawnError) -> RunningProcess
public final class RunningProcess: Sendable {
    public let pid: pid_t
    func terminate(grace: Duration) async -> ProcessResult.Termination   // SIGTERM(-pgid) → grace 待つ → SIGKILL(-pgid)
    var isRunning: Bool { get async }
}
```

  - 引数は**配列だけ**。シェルを経由しない（PR-05 / PR-06）
  - タイムアウト時: `kill(-pgid, SIGTERM)` → 5 秒待つ → `kill(-pgid, SIGKILL)`。**子だけでなく孫も殺す**（ASR-07。テストでは偽 whisper に孫を作らせ、孫も消えることを確かめる）
  - アプリ終了時は実行中の全グループに同じ手順を行う（`ProcessRunner.terminateAll(grace:)`）
- 環境変数は呼び手が明示する（`ProcessSpec.environment` だけを子に渡す。親の環境を引き継がない）。既定の組は `ProcessEnvironment.standard` = `PATH=/usr/bin:/bin:/usr/sbin:/sbin`、`LANG=en_US.UTF-8`、
  diskutil は `ProcessEnvironment.cLocale` = 同じ PATH と `LC_ALL=C`
- stderr は最後の 4 KiB だけメモリに持ち、失敗時の `error_message` に使う（200 文字に切り詰まる）。whisper の失敗文言は voicedock と同じく stderr の末尾 1000 文字（§8.4）
- `spawnFailed` は `posix_spawn` の戻り値（errno）。実行ファイルが無い・実行権が無いときにこれになる

### 8.3 VDAudio（16 kHz 変換）

参照: voicedock `audio.py`（379-500, 264-349, 672-739）、`pipeline.ensure_normalized_audio`（286-373）、SPEC §10.5。**ffmpeg を AVFoundation で置き換える。**

入力は DJI の Broadcast Wave（48 kHz、24 bit PCM または 32 bit float、モノラル、`fmt/bext/iXML/cue/PAD/data`、`data` は offset 32,776）。

**呼び手の手順（`ensureNormalized`。VDPipeline）**
0. `status ∈ normalizedOrBeyond` → 真。`status ∉ normalizable` → 偽（FAILED / SKIPPED は進めない）
1. inbox の原本（`inbox_path`）が「通常ファイルで size > 0」でなければ:
   `needs_recopy = 1` なら**何もせず偽**（再コピーを待つ。v1.1）。そうでなければ `→SKIPPED`（`SOURCE_MISSING`、「inbox に原本がありません: <inbox_path>」）で偽（遷移元は DISCOVERED か NORMALIZING）
2. 空き容量のガード（下記）。足りなければ `disk_space_low recording_key=… reason=<詳細>`（WARNING）を出し、**遷移せず**偽（SM-18）
3. DISCOVERED なら `DISCOVERED→NORMALIZING`（NORMALIZING から来たら記録しない）
4. `normalize(…)`（下記）を呼ぶ。`claimedBy` = `normalized_path` がこの Part の出力パスである行の partkey、`duplicateOf` = 同じ sha256 を持つ行の partkey を返す関数
5. 結果が DUPLICATE_CONTENT: `updateRecording(duplicate_of = 相手)` を**先に**書き、`NORMALIZING→SKIPPED`（「同じ内容の Part が既にあります: <相手>」）で偽。**`sha256` は書かない**（部分 UNIQUE）
6. 結果が失敗: `NORMALIZING→FAILED`（コード、無ければ `IMPORT_FAILED`）、`normalize_failed recording_key=… error_code=…`。`SOURCE_HASH_MISMATCH` なら**遷移の前に** `updateRecordingIfStatus`（status が変わっていなければ列だけ更新）で `needs_recopy = 1` を書く（Store に遷移と列更新を 1 トランザクションで行う API は無い。先に列を書けば、途中で落ちても「再コピーが要る」印だけが残り安全側）。偽
7. 成功: `updateRecording(sha256, normalized_path, staging_dir, error_code = NULL, error_message = NULL)` → `NORMALIZING→NORMALIZED` →
   `normalize_completed recording_key=… in_bytes=… out_bytes=… elapsed_s=<小数 1 桁>` → **その後で** `inboxRetain == normalized` なら inbox の原本を削除（CONC-08: 消すのは DB 更新の後。失敗は無視）。
   `inboxRetain == raw_saved` のときは、Part が `RAW_WRITING→RAW_SAVED` になった直後に同じ規則で消す（voicedock は raw_saved の経路を持たなかった。受理して効かない設定を作らないため実装する。ConfigEffectTests で固定）

**`normalize(input:partkey:duration:sha256Helper:claimedBy:duplicateOf:)` の順序（voicedock audio.py:379-500 と同じ）**
1. `claimedBy != nil && claimedBy != partkey` → `IMPORT_FAILED`「staging の slug が衝突しています（<slug> は <claimedBy> が使用中）」（CONC-13）
2. 冪等: 既存の出力が検証（下記）を通れば再利用。**その場合も入力の SHA-256 を計算し直して照合する**（DEV-18）。照合と重複の判定は 5・7 と同じ
3. 空き容量を再確認（呼び手が先にガード済みなので通常は通る。通らなければ `DISK_SPACE_LOW` で失敗）
4. 変換: 入力全体を `hashChunkBytes` ずつ読んで SHA-256 を計算 → `AVAudioFile(forReading:)` → `AVAudioConverter`（出力 16000 Hz / 1 ch / Float32、
   `sampleRateConverterQuality = .max`、2 ch 以上なら `downmix = true`）→ Int16 へ `clamp(lrint(x × 32768), −32768, 32767)` →
   `AVAudioFile(forWriting:settings:commonFormat: .pcmFormatInt16, interleaved: true)` で `staging/<slug>/audio16k.wav.tmp` へ書き（Int16 のバッファをそのまま書くため。`forWriting:settings:` だけだと処理形式が Float32 になる）、閉じてから rename。
   settings は `AVFormatIDKey = kAudioFormatLinearPCM`、`AVSampleRateKey = 16000`、`AVNumberOfChannelsKey = 1`、`AVLinearPCMBitDepthKey = 16`、
   `AVLinearPCMIsFloatKey = false`、`AVLinearPCMIsBigEndianKey = false`、`AVLinearPCMIsNonInterleaved = false`、**`AVAudioFileTypeKey = kAudioFileWAVEType`**
   （`AVAudioFile` は拡張子から形式を決めるので、`.tmp` で終わる名前には必須）
   - 時間上限 `Int(max(audio.minTimeoutSeconds(180), duration × audio.timeoutFactor(0.5)))` 秒（切り捨て。duration 不明なら 180。ASR-08）。バッファごとに経過を確かめ、超えたら中断して部分出力を消す
   - 失敗は `IMPORT_FAILED`: 読み取り・変換の失敗「<型名>: <説明>」、時間超過「<n> 秒を超えました」
5. `sha256Helper == nil` か `sha != sha256Helper` → 出力を削除し `SOURCE_HASH_MISMATCH`「再計算した SHA-256 がコピー時の値と一致しません（<sha 先頭 16>… ≠ <helper 先頭 16>…）」（helper が nil のときは `≠ 記録なし）`）
   （voicedock は helper が nil なら照合を飛ばした。本アプリは常に値があるので nil は「照合不能 = 失敗」。DEV-17）
6. 出力の検証（`verifyOutput`）→ 失敗は出力を削除し `NORMALIZE_VERIFY_FAILED`（ASR-01）。文言: 「<path> がありません」「<path> が 0 バイトです」「出力を読めません: <err>」
   「sample_rate が <n>（期待 16000）」「channels が <n>（期待 1）」「sample_fmt が <fmt>（期待 s16）」「長さが入力と <gap 小数 2 桁> 秒ずれています（許容 1.0 秒）」。
   長さは `gap > durationToleranceSeconds(1.0)` で失敗（1.0 ちょうどは合格）。入力か出力の長さが不明なら長さの照合を飛ばす
7. `duplicateOf(sha)` が自分以外を返したら出力を削除し `DUPLICATE_CONTENT`
8. 成功（`sha256`、`inBytes`、`outBytes` = 出力の size）

**空き容量**（voicedock audio.py:292-349）
```text
expected = Int(max(0, duration ?? 1800) × 32000)                    // 0 方向への切り捨て
required = Int(Double(expected) × freeSpaceMultiplier(2.0)) + freeSpaceMarginBytes(2 GiB)
free     = statfs(<HOME>/staging).f_bavail × f_bsize               // 取れなければ ok=false「空き容量を取得できません: <err>」
used     = staging 配下の全通常ファイルの st_size の合計（再帰。読めないものは飛ばす）
free < required                    → 「空き <free> バイトが必要量 <required> バイトを下回る」
used + expected > stagingMaxBytes  → 「staging 使用量 <used> + 想定 <expected> が上限 <stagingMaxBytes> を超える」
```

**ffmpeg を偽物にしなかった理由を守る**: 変換こそが要なので、変換テストは本物の AVFoundation で、実機と同じ BWF（24 bit・32 bit float、
ヘッダ約 32 KB）を `TestSupport/BWFWriter` で作って回す（ASR-15。44 バイトヘッダ前提の実装を見逃さない）。fmt が 16 バイト・tag 3 の float WAV を
`AVAudioFile` が読めることは P0-05 でも確かめる。

### 8.4 VDTranscribe（whisper-cli）

参照: voicedock `transcribe.py`、`pipeline.ensure_part_transcript`（388-463）、SPEC §10.6、`tests/fixtures/fake_whisper.py`。

argv（既定値。voicedock `build_argv` と同じ並び。`vad.enabled == false` なら VAD の 6 フラグを 1 つも渡さない。SPEC S11。先頭の語は実行ファイルで argv に含めない。`<threads>` は下の threads）:

```text
<bundle>/Contents/Helpers/whisper-cli -m <HOME>/models/whisper/ggml-large-v3-turbo-q5_0.bin -f <HOME>/staging/<slug>/audio16k.wav
  -l ja -t <threads>
  --vad --vad-model <HOME>/models/vad/ggml-silero-v5.1.2.bin --vad-threshold 0.5
  --vad-min-speech-duration-ms 250 --vad-min-silence-duration-ms 1000 --vad-speech-pad-ms 200
  -oj -of <HOME>/staging/<slug>/whisper -np
```

- 数値の書式（`num`）: 値が整数に等しければ整数の 10 進、そうでなければ `Double.description`（`0.5`→`"0.5"`、`1.0`→`"1"`、`0.25`→`"0.25"`。voicedock と同じ）。ms の 3 つは整数
- threads: `transcription.threads > 0` ならその値、0 なら `min(ProcessInfo.processInfo.activeProcessorCount, 8)`
- 環境変数は `ProcessEnvironment.standard`。起動は `ProcessRunner.run`

**呼び手の手順（`ensureTranscribed`）**
0. `status ∈ transcribedOrBeyond` → 真。`status ∉ transcribable` か `normalized_path == nil` → 偽
1. ガード（§5.4）: `Transcriber.missingPrerequisites()`（whisper-cli・Whisper モデル・（VAD 有効なら）VAD モデル）が空でなければ遷移せず偽。Transcriber も起動の直前に同じ確認をし、欠けていれば `.prerequisiteMissing` を返す（呼び手はガードとして扱い、行に書かない）
2. 入力（16 kHz 音声）が「通常ファイルで size > 0」でなければ（ASR-04 / SM-17。`renormalizeOrFail`）: `→NORMALIZING`（NORMALIZED か TRANSCRIBING から）。
   inbox の原本があれば偽（次の周回で変換し直す。ログ無し）。無ければ `NORMALIZING→FAILED`（`NORMALIZED_MISSING`、
   「16 kHz 音声も inbox の原本もありません（<normalized_path>）。デバイスから採り直す必要があります」、`normalize_failed … reason=input`）。`needs_recopy = 1` は**遷移の前に** `updateRecordingIfStatus` で書く
3. NORMALIZED なら `NORMALIZED→TRANSCRIBING`
4. 冪等: 既存の正規化 transcript が読めて（下記の形）text のスカラー数が `minChars` 以上なら whisper を起動しない
5. whisper を実行（タイムアウト `Int(min(max(duration × timeoutFactor(3.0), minTimeoutSeconds(600)), maxTimeoutSeconds(21600)))`、duration 不明なら maxTimeout。ASR-08）
6. 結果の写し方（どの失敗でも staging の `whisper.json` を削除する）:

| 事象 | コード | error_message |
|---|---|---|
| 起動失敗（`spawnFailed`） | WHISPER_EXEC_MISSING | `spawn: errno <n>` |
| タイムアウト（プロセスグループごと kill） | WHISPER_TIMEOUT | `<秒> 秒を超えました` |
| 終了コード ≠ 0 | WHISPER_FAILED | `終了コード <n>: <stderr の末尾 1000 スカラー>` |
| シグナルで終了（`signaled`） | WHISPER_FAILED | `シグナル <n>: <stderr の末尾 1000 スカラー>` |
| 終了コード 0 だが `whisper.json` が無い・JSON として読めない | WHISPER_FAILED | `生 JSON を読めません: <HOME からの相対パス>` |
| text のスカラー数 < minChars | NO_SPEECH_DETECTED（**SKIPPED**。失敗ではない） | `<n> 文字（min_chars=<m>）` |
| 正規化 transcript を書けない | WHISPER_FAILED | `正規化 transcript を書けません: <説明>` |

   - **whisper.cpp は不明な引数・読めない音声でも終了コード 0 を返すことがある**（v1.9.4 の cli.cpp。V7 調査）。成功の判定は「終了コード 0 **かつ** JSON が在って読める」
7. 生 JSON の読み方（voicedock transcribe.py:333-389）: 全体が辞書でなければ空扱い。`language` = `result.language`（空でない文字列）、無ければ設定の language。
   `transcription` の各要素で、辞書・`offsets` が辞書・`text` が文字列でなければ飛ばす。`start = round(offsets.from / 1000, 3)`、`end = round(offsets.to / 1000, 3)`
   （数値のみ。bool は不可。ms は float でも受ける。ASR-05）、どちらか取れなければ飛ばす。`text` を Python 互換の strip（§5.7）で整え、空なら飛ばす。
   全体の text = 各 segment の text を区切り無しで連結して strip
8. 正規化 transcript を `transcripts/parts/<slug>.json` へ `AtomicFile` で書く（**無音判定より前**。根拠 B の証拠になる。ASR-09）。形は PyJSON の indent 2 ＋ 末尾改行、キーはこの順:
   `partkey, language, duration_seconds（null 可）, started_at（Part の started_at 文字列）, text, segments[{start, end, text}]`。その後 staging の `whisper.json` を削除
9. 無音: `updateRecording(transcript_path)` を**先に**書き、`TRANSCRIBING→SKIPPED`（`NO_SPEECH_DETECTED`）で偽
10. 成功: `updateRecording(transcript_path, error_code = NULL, error_message = NULL)` → `TRANSCRIBING→TRANSCRIBED` →
   `transcription_completed recording_key=… elapsed_s=… chars=… rtf=… speech_ratio=…`（rtf = elapsed / duration を小数 3 桁、duration が無いか 0 以下なら null。
   speech_ratio = Σmax(0, end − start) / duration を小数 3 桁）→ `deleteNormalizedAfterTranscribe` なら 16 kHz 音声を削除（失敗は `disk_space_low reason=staging_unlink_failed` を WARNING）
- 読み戻しの合格条件（冪等・削除条件 `partTranscriptIsValid` で共有）: 辞書で 6 つのキーを全部持つ、`segments` が配列で各要素が辞書・start / end が数値（bool 不可）・text が文字列、
  `text` / `started_at` / `language` が文字列、`duration_seconds` が null か数値。1 つでも不正なら「読めない」
- Metal: whisper.cpp は Metal ビルドなら既定で GPU を使う。**Phase 0 で確認していないフラグを足さない**（例: flash attention 系）
- 診断 DR-04: `whisper-cli --help` の出力（stdout と stderr を連結）に VAD の 6 フラグ（`--vad`、`--vad-model`、`--vad-threshold`、`--vad-min-speech-duration-ms`、
  `--vad-min-silence-duration-ms`、`--vad-speech-pad-ms`）が**逐語で**在ること（**本アプリで強化**。voicedock doctor の D-7 は `--vad` の部分一致だけで、無くても notice だった）

---

### 8.5 VDLLM（llama-server と解析）

参照: voicedock `llm.py`、`pipeline.ensure_analysis`（1140-1227, 1402-1479）、`session.transcript_fingerprint`（60-93）、SPEC §12、`prompts/*.txt`。

**llama-server の起動**（`LlamaServerSupervisor` actor。単一インスタンスを Worker と診断 DR-09 が共有する）

```text
<bundle>/Contents/Helpers/llama-server --model <GGUF> --host 127.0.0.1 --port <空きポート> --api-key-file <HOME>/run/llama-api-key
  --ctx-size <contextSize> --n-gpu-layers 999 --jinja --parallel 1 --no-webui --offline
```

- 長い形のフラグを使う（`-c` は PT-04 の誤検知を招く）。使うフラグはすべて固定した版の `--help` に在ることをテストで確かめる（`LlamaArgsTests`。T-03 の成果物の `--help` 出力を `Tests/Fixtures/llama-server-help.txt` にコミットして照合）
- API キーは起動ごとに `SystemRandomNumberGenerator` の 16 バイトを小文字 16 進 32 文字にし、`AtomicFile` で `run/llama-api-key`（パーミッション 0600）へ書いてから起動する（引数に置くと `ps` で見える）
- ビルドで**モデルをダウンロードする能力を持たせない**: `LLAMA_OPENSSL=OFF`（HTTPS を無くす。`LLAMA_CURL` は b11033 で廃止済み）、`LLAMA_USE_PREBUILT_UI=OFF`（ビルド時に HF から UI を落とさない）。実行時は `--offline`
- 空きポート: `socket` → `bind(127.0.0.1:0)` → `getsockname` でポートを得て閉じ、そのポートを渡す。起動に失敗したら別のポートで最大 3 回
- 起動後 `GET /health` を 1 秒ごとに呼び、200 になるまで待つ（読み込み中は 503。API キーは不要。上限 300 秒。18 GB の読み込みを見込む）。
  途中でプロセスが終了した・300 秒を超えた → 止めて `LLM_UNAVAILABLE`（error_message `server_start_failed: <理由: exited(<n>) / signaled(<n>) / timeout / no_port / spawn_failed / api_key_file / cancelled>: <stderr の末尾 150 スカラー>`。stderr が空なら `: ` 以降を付けない）。成功で `llm_server_started port=… elapsed_s=…`。停止したときと起動に失敗したときは `run/llama-api-key` を消す
- **停止**: `processReadySessions` の終わりで必ず（§2.1）。アプリ終了時も。`RunningProcess.terminate(grace: 10 秒)`（SIGTERM → 10 秒 → SIGKILL、プロセスグループ）→ `llm_server_stopped`
- stdout / stderr はファイルに残さない（プロンプト本文が混ざりうる。PR-08）。末尾 4 KiB をメモリに持ち、失敗時だけ `error_message` に使う
- 解析の前のガード（§5.4）: `llm.modelID` が設定済み、モデルファイルが在る、llama-server が在る、`ProcessInfo.physicalMemory >= minMemoryGB × 1024³`（カタログのモデルだけ。custom は警告だけで起動する）。偽なら遷移せずに待つ

**HTTP**（`LoopbackHTTP.swift` だけが URLSession を使う）
- URL は `LoopbackEndpoint(port:)` からしか作れない（ホストは `127.0.0.1` 固定の型）。PT-02 が検査する
- `POST http://127.0.0.1:<port>/v1/chat/completions`、ヘッダ `Authorization: Bearer <api-key>`、`Content-Type: application/json`
- 本体（voicedock と同じキーと値。符号化は `JSONSerialization` でよい。サーバが読むだけなのでバイト一致は不要）:
  ```json
  {"model": "<modelID>", "messages": [{"role": "system", "content": "<prompt>"}, {"role": "user", "content": "<body>"}],
   "temperature": 0.1, "top_p": 0.9, "max_tokens": 4096, "response_format": {"type": "json_object"}}
  ```
- タイムアウト `requestTimeoutSeconds`（1800 秒。`timeoutIntervalForRequest` と `timeoutIntervalForResource` の両方）。リクエストごとに新しい `URLSession`（`.ephemeral`）。**クライアントを使い回さない**（LLM-10）。
  `URLSessionConfiguration` は注入されたファクトリから作る（テストで差し替える。§10.1）
- 応答の写し方（voicedock llm.py:350-436）:
  - 接続失敗・タイムアウト → `LLM_UNAVAILABLE`「URLError <code>」（ロケールに依存する説明文を入れない）
  - HTTP 400 以上 → `LLM_UNAVAILABLE`「HTTP <code>: <本文の先頭 200 スカラー>」
  - 本文が JSON でない・`choices` が空・`choices[0].message.content` が文字列でない → **content を `""` として検証へ回す**（失敗にせず修復へ回る。voicedock どおり）
- `ChatTransport` プロトコル（`func complete(system: String, user: String) async -> ChatResult`）の背後に置き、テストは `FakeChatTransport` を使う

**スキーマ**（config の `sections` から生成。voicedock `build_schema`、llm.py:81-131 と同じ）
- フィールドの並び（= analysis.json のキー順・schema_block の行順・切り詰めの順・検証エラーの順）: `title`（最終形で summary が有効なとき。文字列 1〜120）、
  `summary`（summary が有効なとき。1〜4000）、続いて `key_points, tasks, decisions, ideas, tags` の**固定順**（config の `order` ではない）のうち enabled のもの（中間形は `tags` を除く）
- 配列の要素は文字列（tasks は `Task = {text: 文字列 1〜500, due: 文字列か null}`、未知キー拒否）。件数上限は `maxItems`（null なら無し）
- **必須は `title` と `summary` だけ**。配列のキーが欠けたら空配列、`due` が欠けたら null として扱う。全体も未知キーを拒否
- 中間形（Map・多段 Reduce の束ね）は `title` と `tags` を持たない
- `{schema_block}` の描画は voicedock `llm.py:134-184` と同一（最終形と中間形の実出力を golden に置く）。**件数の上限をモデルに見せない**（LLM-01）
- 検証は `PyJSON.decode` で**キーの順を保った**オブジェクトにしてから自前で行う（辞書にするとキーの順が失われ、未知キーのエラーの順が決まらない。`Codable` の既定は未知キーを黙って捨てるので使わない。bool を文字列・数として受けない）。
  エラーは `- <loc>: <msg>` の行を改行でつないだもの。**入力値を含めない**（LLM-09）。loc は `.` でつなぐ（`tasks.0.text`）。順序はフィールドの並び → 最後に未知キー（入力の順）。
  msg は voicedock（pydantic v2）の文言と同じ固定語（`LLMValidationMessages`）: `Field required` / `Extra inputs are not permitted` / `String should have at least 1 character` /
  `String should have at most <n> characters` / `Input should be a valid list` / `Input should be a valid string` / `Input should be a valid dictionary or instance of Task`。
  JSON を取り出せなかったときは行形式ではなく「応答から JSON を抽出できませんでした」

**プロンプト**
- `Resources/prompts/` に voicedock `d3d595e:prompts/` の 3 ファイル（`analyze_ja.txt` / `map_ja.txt` / `reduce_ja.txt`）を**バイト単位で**コピーする（LF、末尾改行 1 つ）
- 差し込みは文字列置換を **`{schema_block}` → `{custom_instructions}` の順に 1 回ずつ**（`format` 相当の機能を使わない）。Map は中間形、analyze / reduce は最終形の schema_block
- **本計画の差分:** 修復プロンプトは `repair_json_ja.txt` = voicedock `repair_json.txt` の内容（末尾 `…付けないでください。\n`）の後ろに `\n{schema_block}\n` を足したもの（voicedock は修復時にスキーマを渡していなかった。X-12）。
  置換は `{schema_block}` → `{errors}` → `{previous_output}` の順（信用できない入力を最後にする）。スキーマは元の種類のもの（Map の修復なら中間形）。user メッセージは空文字列（transcript を再送しない）
- DR-09 の疎通確認: system `{"ok": true} と返してください。`、user `ping`

**JSON の取り出し**（順に試す。voicedock llm.py:238-307）
1. `<think>.*?</think>`（改行も含めて最短一致）を全部除去し、残りに `<think>` があればその手前だけ残す。Python 互換の strip
2. 全体をパース → 3. フェンス ```` ```(?:json)?\s*\n(.*?)\n?``` ```` の全一致を出現順に → 4. 最初の `{` から、文字列リテラル（`"…"`、`\` のエスケープを追う）の外の `{` `}` の深さが 0 に戻るまで。
   **結果は辞書に限る**（配列・数値は次の候補へ）。どれも駄目なら「取り出せない」
- **検証の前に上限へ切り詰める**（LLM-02）: フィールドの並びの順に、トップレベルの値が配列か文字列で長さ（スカラー数・要素数）が上限を超えるものだけ先頭から上限までにし、
  `"<name>: <元の長さ> -> <上限>"` を記録する（単一パスでは段の前置きを付けない。voicedock どおり）。Task.text（入れ子）は切らない。記録があれば `analysis_trimmed session_key=… fields=<"; " でつないだもの>`
- 検証に失敗したら修復を `repairAttempts`（1）回（`previous_output` は直前の生の応答）。それでも失敗 → `LLM_INVALID_JSON`（error_message は最後の検証エラー）

**Map-Reduce**（voicedock `llm.py:700-1066` と同一）
- 分割（`chunkSegments`）: 統合済み・時刻順の segment を順に見る。現在のチャンクが空なら入れる。そうでなければ
  `chars = Σ(現在の text のスカラー数) + 次の text のスカラー数`（**区切りの `\n` は数えない**）、`secs = 次.end_at − 現在[0].at`。
  `chars > maxCharsPerRequest` か `secs > maxSecondsPerRequest` なら現在を確定し、**実時間で超えたときは重ねず空から**、文字数だけで超えたときは重なりから始める。
  重なり: 末尾から、合計スカラー数が `chunkOverlapChars` を超える手前まで（ただし最低 1 つ）の segment。現在の全部になるなら先頭の 1 つを落とす。**両方超えたら重ねない**（LLM-05）
  最後の残りは、直前のチャンクの segment の部分集合（重なりだけ）でなければ確定する
- チャンク本文は text を `\n` でつないだもの。`start_at = 最初の at`、`end_at = end_at の最大`。**時刻は LLM に渡さない**
- チャンク 0 → `SESSION_MERGE_FAILED`「チャンクが 0 個です（統合結果が空）」、1 → analyze 1 回（重複除去なし。Timeline は単一パス）、2 以上 → 各チャンクを Map（1 つでも失敗したら即終了）→ Reduce
- Reduce（深さ 1 から）: 中間結果の配列を PyJSON のコンパクト形式（キーはフィールドの並び、空配列も `due: null` も出す）にした本文が `maxCharsPerRequest` 以下か、中間結果が 1 個なら
  REDUCE プロンプトで最終形 → 重複除去。そうでなく深さ 3 以上なら `LLM_INVALID_JSON`「多段 Reduce が上限 3 段に達しました」。
  それ以外は時刻順のまま、束ねた本文が上限を超える手前で区切って束にし、各束を MAP プロンプトで中間形にして深さ +1
- 重複除去（Reduce 経路だけ）: `key_points` / `decisions` / `ideas` / `tags` は「空でない配列で全要素が文字列」のときだけ、`tasks` は `text` で、
  キー `PyText.casefold(PyText.strip(NFKC(s)))` の完全一致で最初の出現を残す
- 切り詰めの記録には段を前置する（`map: …`、`reduce: …`、`reduce2: …`）
- 失敗: `LLM_UNAVAILABLE` / `LLM_FAILED` は工程内リトライ（§5.4。毎回 Map からやり直し）。`LLM_INVALID_JSON` は次の再評価まで待つ（RetryPolicy `none`）

**成功時の書き込み**（この順。LLM-03 / CONC-09）
1. `analysis/<slug>.json`: 最終形を PyJSON の indent 2 ＋ 末尾改行（キーはフィールドの並び、空配列も出す）。`AtomicFile`
2. `analysis/<slug>.timeline.json`（§8.6 の Timeline。**書けなくても失敗にしない**）
3. **最後に** `analysis/<slug>.source.json` = `{"schema": 1, "transcript_sha256": "<指紋>", "segments": <件数>, "blocks": <件数>}`（PyJSON indent 2 ＋ 末尾改行、このキー順）。`AtomicFile`
4. `updateSession(analysis_path, title, error_code = NULL, error_message = NULL)` → `ANALYZING→ANALYZED` → `llm_completed session_key=… chunks=… elapsed_s=…`
- 1 か 3 の書き込み失敗 → `ANALYZING→FAILED`（`LLM_FAILED`「<型名>: <説明>」）
- **指紋**（voicedock と同一定義）: `{"segments": [{"at": <ISO>, "end_at": <ISO>, "text": <text>}…], "blocks": [[<ISO>, <ISO>]…]}` を PyJSON のコンパクト形式・`sortKeys`・非 ASCII そのままで書いた
  UTF-8 の SHA-256 の小文字 16 進。`<ISO>` は §5.7 の ISO 文字列（秒未満切り捨て）。除外 Part・プロンプト・設定は混ぜない（voicedock 実測値 `894a61422b5c95830fe8b36c33ae2c3af728851d00a5e02e9f691d61ad5fb86f` を golden に置く）
- トークン数の集計はしない（voicedock も診断以外で使っていない）

### 8.6 VDNotes（Obsidian 出力）— **voicedock の実装とバイト単位で一致させる**

参照: voicedock `notes.py` / `raw.py` / `daily.py` / `wiki.py`、`pipeline._raw_parts` / `_render_daily` / `_plan_links`、SPEC §13。**SPEC の例ではなく実装が正**（§0.3）。
正しさは golden（§10.4）で担保する。以下は実装の手順で、golden と食い違えば golden（= voicedock の実出力）が正。

**パス**（raw.py:97-129, 243-247、daily.py:375-434）
- `renderTemplate(t, day)`: `{yyyymmdd}` → `yyyyMMdd`、`{date}` → `yyyy-MM-dd`、`{time}` → `000000`。それ以外の `{…}` は残す（CV-13 が起動時に弾く）
- フォルダ = `<vault>/<renderTemplate(folderTemplate)>`（**sanitize しない**。Vault の確認の**後**に中間も含めて作る。Vault のルートは作らない）
- basename = `sanitize(renderTemplate(filenameTemplate), maxTitleBytes)`。出力パス = §8.8 の規則で決める
- `day` は Session の `day_date`（`#2` も同じ日付・同じフォルダ・同じ基本名）

**sanitize（SN-1〜SN-9。ファイル名にだけ適用する。タグ・リンク候補・フォルダには適用しない）**（notes.py:42-105。voicedock の S-1〜S-9 と同じ番号）
| SN | 処理（この順） |
|---|---|
| SN-1 | NFC 正規化（`precomposedStringWithCanonicalMapping`） |
| SN-2 | U+0000–001F と U+007F を除去（C1 制御 U+0080–009F は残す） |
| SN-3 | `/ \ : * ? " < > \|` の各 1 文字を `-` に置換 |
| SN-4 | `# ^ [ ]` を除去 |
| SN-5 | Python の空白（§5.7 `PyText.isSpace`）の連続を U+0020 1 つに畳み、前後を strip |
| SN-6 | 前後の `.`（ASCII）を除去 |
| SN-7 | UTF-8 のバイト数が `maxTitleBytes` を超える間、末尾の Unicode スカラーを 1 つずつ削る。**その後（削ったかどうかにかかわらず）**末尾が結合文字（§5.7）である限り削る |
| SN-8 | 空なら `Untitled` |
| SN-9 | 大文字にしたものが `CON PRN AUX NUL COM1〜COM9 LPT1〜LPT9` のどれかなら末尾に `_`（SN-7 の後なので上限を 1 バイト超えうる。voicedock どおり） |

固定例: `'  a / b  '`→`a - b`、`'..hidden..'`→`hidden`、`con`→`con_`、`LPT9.`→`LPT9_`、`a#b^c[d]e`→`abcde`、`tab\there\x7f`→`tabhere`、`''`・`'...'`→`Untitled`、
`q\u0301`→`q`、`'あ'×70`→`'あ'×60`、`'a'×179+'é'`→`'a'×179`、`'a\u00a0b\u200bc'`→`a b\u200bc`、`CON`（上限 3）→`CON_`

**frontmatter の書き出し（自前。汎用シリアライザを使わない。NOTE-06）**（notes.py:108-161）
```text
lines = ["---"]
各 (key, value) を渡された順に:
  文字列 → key + ": " + quote(value)
  Bool   → key + ": " + ("true" | "false")
  整数   → key + ": " + 10 進（浮動小数は渡さない）
  nil    → key + ": null"
  配列   → 空なら key + ": []"、そうでなければ key + ":" の行と、要素ごとに "  - " + quote(要素)
lines += ["---"];  結果 = lines を "\n" でつなぎ + "\n"
quote(s) = "\"" + (s の `\` → `\\`、`"` → `\"` の後、U+0000–001F と U+007F を除去) + "\""
```
- C1 制御・U+2028 / U+2029 は残す（バイト一致のため「改善」しない）
- 本文のエスケープ（`escapeBody`）: 文字列の先頭と各 `\n` の直後にある `---` を `\---` にする（`\r` の後は対象外）。本文にだけ適用する
- 改行 LF、UTF-8（BOM なし）、末尾改行ちょうど 1 つ（本文の行を `\n` でつなぎ、末尾の `\n` を全部落としてから `\n` を 1 つ足す）

**Raw ノート**（raw.py:135-218、pipeline.py:592-623）
- 載せる Part: `RawNoteMembership.isMember(status:transcriptReadable:)` で絞った Session の Part = Session の Part（`started_at, partkey` 順）のうち `rawNoteMembers` に在り、transcript が読めるもの（検証側も同じ関数を使う。§8.7）。segment の `at = started_at + start`、`end_at = started_at + end`（§5.7 の `Instant`）
- frontmatter: `type: "voice-raw"`, `voicedock_session_key`, `voicedock_recording_keys`（載せた Part の partkey）, `date: "<yyyy-MM-dd>"`, `parts: <件数>`, `source: "DJI Mic 3"`
```text
lines = ["", "# <date> の文字起こし（生データ）", "", "> 自動文字起こしの生データ。未編集。", ""]     // 括弧は全角 U+FF08 / U+FF09
for part in 載せる Part:
  if partBoundaryHeading: lines += ["## " + HH:MM(started_at) + "–" + (ended_at ? HH:MM(ended_at) : ""), ""]   // – は U+2013
  chunk = []; nextMark = nil
  for seg in part.segments（与えられた順）:
    text = PyText.strip(seg.text); if text == "": continue
    if timestampIntervalSeconds > 0 and (nextMark == nil or seg.at >= nextMark):
      if chunk 非空: lines += [chunk を " " でつなぐ, ""]; chunk = []
      lines += ["### " + HH:MM:SS(seg.at), ""]; nextMark = seg.at + timestampIntervalSeconds 秒
    chunk.append(text)
  if chunk 非空: lines += [chunk を " " でつなぐ, ""]
本文 = escapeBody(整形(lines))
```
- 見出しの時刻は**実際の segment の時刻**（NOTE-04）。本文の無い Part でも `##` 見出しは出る。Part が 1 本 RAW_SAVED に届くたびに、その日の分を全体書き直す

**Daily ノート**（daily.py:189-252, 300-369）
- 入力: `included` = Session の Part のうち FAILED / SKIPPED 以外（`started_at, partkey` 順）、`failed` / `skipped` = 除外 Part を状態で分けたもの、`recorded_seconds`（Session の列。**除外 Part も含む**）、
  `blocks`（included で算出した Block の数）、解析、Timeline、リンク計画
- frontmatter の並び: `type: "voice-daily"`, `voicedock_session_key`, `voicedock_recording_keys`（included の partkey）, `voicedock_failed_parts`, `voicedock_skipped_parts`,
  `date`, `recorded: "HH:MM:SS"`, `parts`（included の件数）, `blocks`, `status: "processed"`, `tags`
- `recorded`: nil か負なら `00:00:00`。そうでなければ `t = Int(recorded_seconds)`（0 方向へ切り捨て）、`%02d:%02d:%02d`（時は 2 桁を超えうる: 90061.7 → `25:01:01`）
- `tags`: `defaultTags` の後に解析の `tags`（配列なら各要素を文字列に）を順に、Python 互換の strip → U+0020 と U+3000 だけを `-` に置換 → 空なら捨てる →
  `PyText.casefold` が既出なら捨てる（先勝ち）。**sanitize は通さない**
```text
lines = ["", "# " + (解析の title が空でなければそれ、でなければ date), ""]
for 警告行 w: lines += [w, ""]
for name in config の order:
  sec = sections[name]; if !sec.enabled: continue
  heading = sec.heading ?? "## " + name
  rendered = name == "timeline" ? timelineLines(timeline) : sectionLines(name)
  if rendered が空: continue                                  // 見出しごと省く
  lines += [heading, ""] + rendered
lines += sourcesLines() + linksLines()
sectionLines: summary → PyText.strip(summary) が空なら []、でなければ [それ, ""]
              配列でない・空 → []
              tasks → 各 "- [ ] " + text + (due が空でなければ " 📅 " + due) の後に ""
              その他 → 各 "- " + 要素（strip しない）の後に ""
timelineLines: 各ブロック ["### " + HH:MM(start) + "–" + HH:MM(end), "", ("- " + 行)…, ""]
sourcesLines: リンク計画の raw が空なら []、でなければ ["## Sources", "", ("- " + raw)…, ""]
linksLines: 値 = [dailyNote（あれば）] + adjacent + tags のうち "[[" で始まるもの。空なら []、でなければ ["## Links", "", ("- " + 値)…, ""]
```
- **Timeline は `order` の中の 1 節**（既定では summary の次）。「セクションの後に Timeline」ではない
- `📅` は U+1F4C5

**警告行**（voicedock `daily.py:300-340`、NOTE-05）:
- FAILED（1 件以上）: `> ⚠ この日の録音のうち {n} 本が処理できませんでした。次にデバイスを接続したときに自動で再試行されます。`
- SKIPPED（1 件以上）: `> {mark}この日の録音のうち {n} 本を除外しました（{理由}）。自動では再試行されません。{action}`
  - `actionable` = SKIPPED のどれかの error_code が `benignSkipReasons`（無音・重複）に無い（nil も actionable）。真なら `mark = "⚠ "`（U+26A0 と半角空白）、`action = "デバイスから採り直してください。"`、偽なら両方空
  - 理由: SKIPPED の error_code（nil は空文字）の**重複を除いた集合**を ErrorCode の宣言順で並べる（未知・空は末尾。同じ順位はコード文字列の昇順。voicedock は set の順で非決定だった）→
    表示名に写して `・`（U+30FB）でつなぐ。表示名: DUPLICATE_CONTENT→重複、SOURCE_MISSING→元ファイルが見つかりません、NORMALIZED_MISSING→元ファイルが見つかりません、
    NO_SPEECH_DETECTED→無音、表に無いコード→コードそのまま、空→理由不明（表示名の重複は除かない）
- **SKIPPED に「自動で再試行されます」と書かない**

**Timeline**（daily.py:88-183, 440-521）
- 作る（解析の直後。`buildTimeline`）: Map-Reduce なら 1 段目の Map 結果とチャンクを組にし（短い方で打ち切り）、各組の点（Map 結果の key_points が空でなければそれ、無ければ summary の文分割）が空でないものだけ
  `(chunk.start_at, chunk.end_at, 点)` の Block にする。単一パスなら `sentences(最終 summary)` を、Session の各 Block（無ければ `(最初の segment の at, end_at の最大)`、segment も無ければ無し）に**同じ全文を繰り返して**付ける
- `sentences(text)`: 各 `。` の直後に `\n` を入れ → `PyText.splitLines` → 各行を strip → 空を捨てる
- 保存: `analysis/<slug>.timeline.json` = `{"schema": 2, "transcript_sha256": <指紋>, "blocks": [{"start_at": <ISO>, "end_at": <ISO>, "lines": [...]}]}`（PyJSON indent 2 ＋ 末尾改行、`AtomicFile`）。書けなくても失敗にしない
- 読み込み（Daily を書くとき）: 読めない・辞書でない・`schema != 2`・**`transcript_sha256` が現在の指紋と違う**・`blocks` が配列でない → 空。要素ごとに不正なら飛ばす。
  空なら代替経路（単一パスの作り方を、解析済みの summary で行う）

**WikiLink**（NOTE-10、PR-15。wiki.py:46-310）: LLM に `[[ ]]` を作らせない。リンクはレンダラが付ける
- Vault 索引（`VaultIndex`）: Vault のルートから深さ優先で列挙（読めないディレクトリは飛ばす）。`.` で始まる名前はファイルもディレクトリも無視、**symlink のディレクトリは辿らない**、
  Vault からの相対パスが除外接頭辞と一致するか `接頭辞/` で始まるディレクトリには入らない（除外接頭辞 = `raw.folderTemplate` の最初の `{` より前を `/` で strip。既定 `Daily/Voice/Raw`）。
  名前が `.md`（大小区別）で終わるファイルの、`.md` を除いた名前を `PyText.casefold(NFC(名前))` にした集合。`linkTags == false` なら作らない。Worker が保持し `vaultIndexCacheSeconds` で作り直す（ContinuousClock。NOTE-11）
- リンク計画（`planLinks`）: `budget = maxLinks`
  - 使える候補か: strip が空、`[ ] | # ^` のどれかを含む、自分自身（`casefold(NFC(候補)) == casefold(NFC(自分の Daily の basename))`）→ 使わない
  - `linkDailyNote` なら `yyyy-MM-dd` が使え budget > 0 なら `[[yyyy-MM-dd]]`（budget −1）
  - `linkAdjacentDays` なら前日・翌日の Daily の basename（sanitize 済み、` (2)` を含まない）が使え budget > 0 なら `[[…]]`。**実在を確かめない**（voicedock どおり）
  - タグ: 候補は**解析の `tags` そのもの**（既定タグ・空白置換・strip を通さない）。使えない候補は捨てる。`wanted = linkTags && (索引に在る || !linkOnlyExisting)`。
    wanted かつ budget > 0 なら `[[tag]]`（budget −1）、そうでなければ `#tag`（本文には出ない）
  - raw: `[[<Raw の basename>]]`（上限の対象外）。**Raw の basename は `sessions.raw_output_path` の basename から `.md` を除いたもの**（NULL なら基本名）。
    **本計画の差分（X-15）**: voicedock は常に基本名を指し、` (2)` 付きの Raw を指せなかった
  - 例外（ファイル I/O の失敗など）は空の計画にし、検証に影響させない

### 8.7 Vault の確認・atomic write・保存検証

**Vault の確認（手順 0。`VaultCheck.evaluate(path:marker:)`）**（notes.py:470-496 ＋ 本計画の強化）。判定関数は 1 つで、ガード・Raw・Daily・診断・削除条件が共有する:

| 結果 | 条件 | 表示・error_message |
|---|---|---|
| `.notConfigured` | `vault.path == nil` | 「Vault が選ばれていません」 |
| `.missingRoot` | パスが（symlink を辿って）ディレクトリでない（stat が ENOENT・ENOTDIR） | 「<path> がありません」 |
| `.notReadable(errno)` | stat が `EPERM` / `EACCES` で失敗、または `opendir(path)` が失敗（`EPERM` は TCC。書類フォルダ・iCloud Drive の Vault で起こる） | 「<path> を読めません（errno <n>）」。EPERM ならシステム設定の案内 |
| `.missingMarker` | `<path>/<marker>` が（symlink を辿って）ディレクトリでない | 「<path> に <marker>/ がありません（Vault が未マウントか、別の場所を指しています）」 |
| `.available` | 上のどれでもない | — |

- **Vault のルートを作らない**（外付けが未接続・iCloud 未同期で「空の Vault」に書くと、同じ幻の中で読み直すので検証を全部通る。DEL-06）
- `.available` 以外は**ガード**（遷移せずに待つ。§5.4）。ガードを通った後、遷移（`TRANSCRIBED→RAW_WRITING` / `ANALYZED→WRITING`）を記録してからもう一度確かめ、
  `.available` でなくなっていたら `→FAILED`（`OBSIDIAN_NOT_FOUND`、上の文言）（voicedock は遷移を先に記録してから確かめていた。本アプリはガードを前に足した）

**書き込み**（`NoteWriter.write(content:to:)`。notes.py:223-288 と同じ）: UTF-8 → SHA-256 → 同じディレクトリの `.<ファイル名>.tmp`（`.md` を含む。例 `.2026-08-29 raw.md.tmp`。既存なら切り詰めて使う）→ write → `fsync` → close →
読み直して SHA 照合（不一致なら rename しない）→ `rename` → 親ディレクトリを `fsync`（開けない・失敗は無視）→ 保存検証。
途中で失敗したら tmp を消し、最終ファイルは差し替えない。後片付けの失敗で元の失敗を隠さない（NOTE-14）。実装は `AtomicFile.write(…, verifyReadBack: true)`

**保存検証**（`NoteVerifier`。SPEC S12。規則の ID は「#」の列の番号に RN- / DN- を付けたもの。— の欄は規則が無い。全部合格してから DB の `*_output_path` / `*_sha256` を書き、その後に RAW_SAVED / SAVED へ遷移。**DB 更新が成功するまで保存済みとみなさない**）

| # | Raw（RN。voicedock R-n） | Daily（DN。voicedock W-n） |
|---|---|---|
| 1 | 通常ファイル（symlink でない）。stat できなければ偽 | 同左 |
| 2 | size > 0 | 同左 |
| 3 | UTF-8 として読める | 同左 |
| 4 | SHA-256 が期待値と一致 | 同左 |
| 5 | frontmatter が YAML として読め（Yams）、`voicedock_session_key` が文字列として一致 | 先頭が `---\n` で、その後に `^---\s*$` の行がある（`splitFrontmatter` が成功） |
| 6 | `voicedock_recording_keys`（配列でなければ空集合。要素は文字列化）が期待する鍵を**すべて含む**（包含） | frontmatter が YAML として読め、session_key が一致 |
| 7 | — | recording_keys が期待する鍵と集合として**完全一致**（RN-6 と混同しない。NOTE-12） |
| 8 | — | summary の見出し（`sections.summary.heading`）に一致する行 `^<見出しを正規表現用にエスケープ>\s*$` が在り、その次の行から次の `^#{1,6} ` の行の手前までを strip して空でない（NOTE-13） |
| 9 | — | `\[\[[^\]]+\]\]` が 1 つ以上ある（NOTE-01） |

- 評価の打ち切り（voicedock notes.py:319-454。落ちた規則の列 = error_message に効く）: 1 が偽なら 1 だけ、2 が偽なら 1〜2、3 が偽なら 1〜3 を返して終わる。4 は偽でも続ける。
  frontmatter が YAML として読めないとき、Raw は RN-5・RN-6 を偽にして終わる。Daily は DN-6・DN-7 を偽にし、DN-8・DN-9 は評価して終わる
- 検証は bool ではなく規則ごとの結果（落ちた規則の ID の列）を返す
- 期待値: 書き込みの直後は「書いた内容の SHA」と「載せた Part の鍵」。**削除条件の再検証（§8.9.1 の `verifyRawNote`）では、期待 SHA = DB の `raw_output_sha256`、
  期待する鍵 = `RawNoteMembership.isMember(status:transcriptReadable:)` で絞った Session の Part（書き手と同じ関数: Session の Part のうち `rawNoteMembers` に在り transcript が**読める**もの）**。`raw_output_path` か `raw_output_sha256` が NULL なら偽。
  （voicedock は検証側だけ「`transcript_path` が在る」を使い、書き手と集合が食い違っていた。transcript が壊れた Part が 1 本あると RN-6 が永久に偽になる。§9.1 原則 2 に従い 1 つの関数に寄せる。壊れた Part 自身は `partTranscriptIsValid` が偽なので消えない）
- 失敗の写し方: Raw の検証失敗 → `OBSIDIAN_RAW_VERIFY_FAILED`「落ちた規則: RN-1, RN-5」、書き込みの例外（99 超えを含む）→ `OBSIDIAN_RAW_WRITE_FAILED`「<型名>: <説明>」。
  Daily は `OBSIDIAN_VERIFY_FAILED` / `OBSIDIAN_WRITE_FAILED`。ログは `raw_note_failed recording_key=… error_code=… reason=<vault|write|verify>` /
  `obsidian_failed session_key=… error_code=… reason=… detail=…`
- Raw の失敗で FAILED にするのは書き直しを起こした Part 1 件だけ（SM-15）
- 成功: Raw は `updateSession(raw_output_path, raw_output_sha256)` → `RAW_WRITING→RAW_SAVED` → `raw_note_saved session_key=… parts=… bytes=…` → 再オープン（§5.6）。
  Daily は `updateSession(output_path, output_sha256, error_code = NULL, error_message = NULL)` → `WRITING→SAVED` → `obsidian_saved session_key=… path=<Vault からの相対> bytes=…`

### 8.8 既存ノートの扱い（**本計画の差分**。X-11）

voicedock は「同じ名前のファイルがあり `voicedock_session_key` が一致すれば、誰が書いたものでも上書き」だった（notes.py:499-524）。乗り換え時に voicedock が書いたノートを
アプリが上書きすると、**アプリの DB に無い Part の文字起こしが Raw ノートから消える。**一方、DB だけで所有を決めると、rename の後・DB 更新の前に落ちたとき自分のノートを他人のものと判定し、
` (2)` が増え続ける。そこで次の規則にする（`OutputPathResolver.resolve(folder:baseName:existing:sessionKey:ownedPartkeys:kind:)`）:

1. DB の当該 Session の `raw_output_path` / `output_path` が在れば、そのパスについて「ファイルが無い」か「上書きしてよい」なら**そこへ書く**
2. そうでなければ、基本名 → ` (2)` → … → ` (99)` の順に、「ファイルが無い」か「上書きしてよい」最初の候補へ書く。99 を超えたら書かない
   （Raw は `OBSIDIAN_RAW_WRITE_FAILED`、Daily は `OBSIDIAN_WRITE_FAILED`、「同名ファイルが多すぎます」）

- **上書きしてよい** = UTF-8 で読め、frontmatter が YAML として読め、`voicedock_session_key` がこの Session の鍵と一致し、かつ `voicedock_recording_keys`
  （Daily は `voicedock_failed_parts` と `voicedock_skipped_parts` も）の全要素がアプリの DB でこの Session に属する Part の partkey であること
- 「ファイルが無い」は symlink を辿って判定する（壊れた symlink は「無い」。rename が symlink 自体を置き換える。voicedock どおり）
- 利用者がアプリの書いたノートを編集していても、上の条件を満たせば上書きする（利用者の編集は失われる。voicedock と同じ。RK-18）
- `OutputPathResolver.resolve(folder:baseName:existing:sessionKey:ownedPartkeys:kind:)`（`existing` = DB の出力パス、`ownedPartkeys` = アプリの DB でこの Session に属する Part の partkey）
- voicedock が書いたノート（鍵がアプリの DB に無い）・利用者が作ったノート・読めないノートは上書きしない

### 8.9 元音声の削除

参照: voicedock SPEC §14（全体）、`cleaner.py`、`pipeline.py`（request_deletions 670-748 / delete_sources_if_safe 750-812 / settle_skipped_deletions 814-919 / collect_delete_results 921-1002 / _expire_delete_requests 1004-1038 / _complete_without_deleting 1075-1092）、
`backlog.py`、`helper/voicedock-reaper`、`tests/unit/test_no_delete.py` / `test_reaper.py`。

**絶対ルール: 文字起こし本文が Obsidian に保存・検証される前に元音声を削除してはならない。**

#### 8.9.1 削除の必要十分条件（形を変えない）

```swift
// 共通の同定 AND（根拠 A OR 根拠 B）。|| を共通項の外へ出してはならない（出すと根拠 B がロックも番犬も通らずに真になる）
func canDeleteSource(part, session, parts, config, snapshot, locks, vault, twin) -> Bool {
    deletionIsIdentified(part, session, parts, config, snapshot, locks)
        && (textIsPreserved(part, session, parts, vault) || nothingToPreserve(part, config, twin, vault))
}
func deletionIsIdentified(...) -> Bool {
    locks.allReleased(for: part.deviceID)          // §8.9.2 の 3 つ全部（観測値）
    && part.sessionKey == session.sessionKey
    && parts.count >= 1                            // 番犬: 空集合で真にしない（DEL-03）
    && part.sourcePath != nil && part.sourcePath != ""   // 番犬: "" はボリュームのルートを指す
    && preIdentityCheck(part, snapshot)            // §8.9.5
}
func textIsPreserved(part, session, parts, vault) -> Bool {       // 根拠 A: テキストが 2 か所に在る
    session.rawOutputPath != nil
    && verifyRawNote(session, parts, vault) == .passed   // RN-1〜6 を実ファイルで再実行（DB の status を信用しない。期待値は §8.7）
    && frontmatterKeys(session.rawOutputPath).contains(part.partkey)
    && partDeletable.contains(part.status)
    && part.transcriptPath != nil
    && partTranscriptIsValid(part)                  // 実ファイルを読む（列は見ない。§8.4 の合格条件）
}
func nothingToPreserve(part, config, twin, vault) -> Bool {  // 根拠 B: 保全すべき本文が無い
    config.cleanup.deleteSkippedSource == true
    && part.status == .skipped
    && deletableSkipReasons.contains(part.errorCode)
    && skipReasonIsBacked(part, twin, vault)
}
func skipReasonIsBacked(...) -> Bool {
    switch part.errorCode {
    case .noSpeechDetected: return partTranscriptIsValid(part)
    case .duplicateContent:
        guard let twinKey = part.duplicateOf, let twin, twin.part.partkey == twinKey,
              twin.part.partkey != part.partkey, twin.part.sessionKey == twin.session.sessionKey else { return false }
        return textIsPreserved(twin.part, twin.session, twin.parts, vault)   // 双子には同定を要求しない
    default: return false                                         // 表に無い理由は消さない側（SOURCE_MISSING も）
    }
}
```

- `frontmatterKeys(path)`: 読めない・UTF-8 でない・frontmatter が無い・`voicedock_recording_keys` が配列でない → 空集合。要素は文字列化（notes.py:194-211）
- 要約（Daily ノート・解析）の成否を条件にしない。1 本詰まってもその日全体を止めない。評価は Part ごと（DEL-04）
- **式の形そのものをテストで固定する**（`||` が共通項の内側にあること、番犬の項が在ること）。振る舞いでは落とせない冗長な項は、
  ソースに項が在ることを PolicyTests で検査し、テストの doc コメントに「振る舞いでは落とせない理由」を書く（TEST-30）
- **論理式のすべての項に ND テストを 1 本ずつ**持たせる（DEL-05: `part_transcript_is_valid` を消しても落ちるテストが無かった）
- 状態遷移: 根拠 A は `RAW_SAVED→SOURCE_DELETING`。**根拠 B は SKIPPED のまま**（遷移させると `error_code` が上書きされ「（無音）」表示と根拠 B が壊れる。SM-20）。
  **「結果を待っている」は `delete_request_id != nil` だけで表す**（状態は RAW_SAVED / SOURCE_DELETING / SOURCE_DELETE_PENDING / SKIPPED のどれでもよい）。決着は `source_deleted_at` で表す

#### 8.9.2 三重ロック（本アプリ版）

| ロック | 実体 | 既定 | 観測のしかた |
|---|---|---|---|
| **1: 設定** | `config.json` の `cleanup.deleteSourceAudio` **と** `bin/reaper.conf` の `DELETE_SOURCE_AUDIO=true`（**両方**） | false | アプリは両方を読む（reaper.conf は `ReaperConf.parse`。無い・読めない・不正は「不明」）。reaper は reaper.conf だけを読む |
| **2-A: 実行可能なコードの不在** | `<HOME>/bin/voicedock-reaper` が**存在しない** | 不在 | ファイルの有無（`lstat`。通常ファイルに限る）＋ 署名検証 ＋ 版（§8.9.3） |
| **2-B: OS レベル** | `device.mountMode = ro` → IngestService が読み取り専用で再マウント | ro | **statfs の `MNT_RDONLY` の観測値**（設定値ではない。デバイスごと） |

ロックの評価は 2 段に分ける（**v1.1 で修正**。v1 の「揃っていないなら完了」は、抜いた後に RAW_SAVED になる通常の流れで全 Part を COMPLETED に流し、削除が起きなかった）:

1. **設定上の準備（`DeletionReadiness`。待っても変わらない）** — `LockEvaluator.readiness()`:
   - `config.cleanup.deleteSourceAudio == false` → `.disabled(delete_source_audio_disabled)`
   - reaper.conf が `DELETE_SOURCE_AUDIO=false`・無い・読めない・不正 → `.disabled(lock_mismatch)`（食い違いが確定していれば CV-30 で設定エラーにもなる）
   - `device.mountMode == ro` → `.disabled(mount_mode_ro)`（CV-33 で設定エラーにもなる）
   - `bin/voicedock-reaper` が無い → `.disabled(reaper_not_installed)`、署名か版が合わない → `.disabled(reaper_invalid)`
   - どれでもなければ `.configured`
   - 署名検証と `--version` の結果は、`bin/voicedock-reaper` の `(inode, size, mtime)` が変わらない限り `LockEvaluator` がキャッシュする（Session ごと・tick ごとに子プロセスを起動しない）。reaper を起動する直前だけはキャッシュを使わない
2. **デバイスの観測（`DeviceWritability`。挿し直しで変わる）** — snapshot から: そのデバイスが snapshot に**無い** → `.absent`、`readOnly == false` → `.writable`、`true` → `.readOnly`、`nil` → `.unknown`

- `locks.allReleased(for: deviceID)` = `readiness == .configured && writability(deviceID) == .writable`。**設定値と観測値を混同しない**（`mountMode` は「そうしたい」、`readOnly` は「そうなっている」）
- 「削除できない」ときの Session の扱い（voicedock pipeline.py:750-812 と同じ判定。§8.9.5 の `deleteSourcesIfSafe`）:
  - `readiness` が `.disabled` → 削除せずに完了する（`source_delete_skipped session_key=… reason=<語>`）。待っても変わらない条件で待たない（DEL-15 / DEL-16）
  - デバイスが**接続中で** `.readOnly` か `.unknown` → 削除せずに完了する（`reason=device_readonly`。voicedock と同じ。有効化の直後で挿し直す前のデバイスもここに入る。消し損ねた分は「過去分を削除対象にする」で拾える）
  - デバイスが **`.absent`（未接続）なら待つ**（`delete_attempts += 1` して backoff。voicedock は未接続を「書き込み可能」扱いにして要求を書かず待っていた）
  - デバイスが**接続中で列挙でき**、RAW_SAVED の Part の元ファイルが一覧に**無い** → その Part は消す必要が無いので、要求を書かずに完了する（§8.9.5 の `requestDeletions`。F-64）。
    事前確認（`preIdentityCheck`）は不在のファイルを同定できず永久に偽なので、待っても変わらない（CR-15）。未接続・列挙できない・snapshot が古いときは「無い」と判定せず待つ
- 消し損ねた分は「過去分を削除対象にする」（§8.9.9）で後から拾える

#### 8.9.3 ロック 2-A: 同梱して複製で解除（D-5）

reaper の本体は `Contents/Helpers/voicedock-reaper`（署名済み）として .app に入れる。**その場所からは決して実行しない。**

1. **起動できる場所は `<HOME>/bin/voicedock-reaper` だけ。**`ReaperRunner` は `HomeLayout.reaperExecutable` 以外のパスを受け付けない（引数にパスを取らない）
2. **複製するのは有効化フロー（`DeletionEnabler`）だけ。**バンドル内の reaper のパスを参照してよいファイルは `DeletionEnabler.swift` 1 つ、`<HOME>/bin/` へ書いてよいのも同じファイルだけ（PT-11）
3. **reaper 自身が置き場所を確かめる（RV-00）:** `_NSGetExecutablePath` → `realpath` した自分のパスが、`--home` の realpath + `/bin/voicedock-reaper` と一致しない、
   または `.app/Contents/` を含む、または `<HOME>/bin/voicedock-reaper` が（`lstat` で）通常ファイルでないなら、何も書かずに終了コード 3。
   アプリの不具合でバンドル内の reaper が起動されても、何も消えない
4. **起動前に毎回、署名を検証する**（`SignatureVerifier` プロトコル。本番は `CodeSignatureVerifier`）: `SecStaticCodeCreateWithPath` → `SecRequirementCreateWithString` →
   `SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement)`、要件
   `anchor apple generic and identifier "<BUNDLE_ID>.reaper" and certificate leaf[subject.OU] = "<TEAM_ID>"`（`ReaperSignature.requirement` の定数 1 つ）。
   失敗したら起動せず `.disabled(reaper_invalid)`。テストは `FakeSignatureVerifier` を注入する（本番のコードに「テストなら」分岐を作らない）
5. **版の一致**: 署名検証の後に `voicedock-reaper --version` を実行（タイムアウト 10 秒）し、stdout が `<アプリの版>\n` と一致しなければ起動しない（`.disabled(reaper_invalid)`、`reaper_failed reason=version_mismatch`）。
   パネルに「削除モジュールの更新が必要です」と出し、更新は有効化フローをもう一度通す（自動で複製し直さない）
6. 複製は同じ `bin/` 内の `.voicedock-reaper.tmp` へ書いて `fsync` → 署名検証 → `chmod 0755` → `rename`

> **この方式で弱くなる点を記録しておく**（利用者が選んだトレードオフ）: voicedock の 2-A は「削除できるコードが手元に無い」だった。
> 本方式では**コードは手元に在り、「実行できる場所に無い」**に弱まる。アプリの不具合が複製して実行する経路が原理的に残るので、
> 上の 2・3 を静的検査（PT-11）と ND テスト（ND-26 / ND-40）で固定する。

#### 8.9.4 reaper（`voicedock-reaper`、Swift 実行ファイル）

- 依存は VDContract・Foundation・Darwin だけ。**子プロセスを起動しない（diskutil も呼ばない。PR-19）、ネットワークを使わない、ディレクトリを再帰削除しない**
- 削除は `unlinkat(verifiedParentFD, name, 0)` だけ（`Unlinker.swift`）。`FileManager.removeItem` は**ディレクトリを再帰的に消す**ので使わない（PT-01）
- 引数: `voicedock-reaper --home <HOME>` か `voicedock-reaper --version`。`--version` は **RV-00 より前に**処理し、`<VERSION>\n` を stdout に出して 0（ほかの I/O はしない）
- 終了コード: 0 = 正常（ロック 1 が false で何もしなかった場合も 0）、2 = 引数不正か reaper.conf が無い・読めない・不正（**キューに触らない**）、3 = RV-00（置き場所不正。何も書かない）、4 = ロックが取れない（走査中。何もしない）
- 起動時の検査（RV-00・conf・RV-01）の後、`<HOME>/state/reaper.lock` に `flock(LOCK_EX | LOCK_NB)` を掛け、終わるまで持ち続ける（§2.1）。取れなければ（IngestService の走査中）`reaper_busy` を出して何もせず終了コード 4。
  SIGTERM を受けたら処理中の 1 件を終えてから終わる（次の要求に進まない）
- 設定 `bin/reaper.conf`（`ReaperConf`。VDContract。アプリの有効化フローと同じ関数で読み書きする）:
  ```text
  SCHEMA=1
  DELETE_SOURCE_AUDIO=true
  VOLUMES_ROOT=/Volumes
  ```
  - `open(O_RDONLY | O_NOFOLLOW)`、通常ファイル、64 KiB 以下。行は `\n` 区切り。空行と `#` で始まる行は無視。それ以外の行は `^[A-Z_]+=[^[:space:]]*$` に完全一致しなければ不正
  - 必須: `SCHEMA`（`1` のみ）、`DELETE_SOURCE_AUDIO`（`true` / `false` のみ）。任意: `VOLUMES_ROOT`（`/` で始まる絶対パス。既定 `/Volumes`。テスト用）
  - **未知のキー・重複・不正な値・必須の欠落はすべて「不正」**（fail-closed。exit 2、`reaper_disabled reason=conf_invalid`）
  - アプリが書くときの内容は上の 3 行（`DELETE_SOURCE_AUDIO` の値だけ変える）＋ 末尾改行。`AtomicFile`、パーミッション 0644
- ログ `logs/reaper.log`（5 MiB を超えたら `.1` へ rename して 1 世代）。行は `<ts> <LEVEL を 5 桁左寄せ> <event> k=v …`（値の書式は §8.15 と同じ）、`ts` はシステムのローカル時刻で `yyyy-MM-dd'T'HH:mm:ssxxxxx`。
  イベントは固定: `reaper_started`、`reaper_busy`、`reaper_disabled reason=lock1|conf_invalid`、`request_rejected file=<name> reason=malformed_request_id`、`source_delete_rejected request_id=… reason=<理由語>`、
  `device_absent request_id=… device=…`、`mount_readonly request_id=… device=…`、`source_deleted request_id=… partkey=…`、`reaper_completed requests=<N>`
- `state/processed.log`: 1 行 1 request_id。`O_APPEND` で書いて `fsync`。照合は行の完全一致

**処理の順序（RV。1 つでも偽なら削除しない。理由語は付録 B.2）**

| 段 | 内容 | 偽のとき |
|---|---|---|
| 起動時 | RV-00 置き場所 | 終了コード 3（何も書かない） |
| | reaper.conf を読む | 不正 → 終了コード 2、`reaper_disabled reason=conf_invalid`（**要求に触らない**） |
| | RV-01 ロック 1: `DELETE_SOURCE_AUDIO=true` | `reaper_disabled reason=lock1`、終了コード 0（**要求に触らない**） |
| 走査 | `queue/delete` を列挙。`.` で始まる名前は無視。名前の**バイト順昇順**で 1 件ずつ | — |
| 要求ごと | RV-02a ファイル名が `^<request_id の正規表現の本体>\.json$` に完全一致 | `queue/rejected/<name>` へ rename（同名は上書き）。**結果も processed.log も書かない**（信用できない値をファイル名に使わない）。`request_rejected` |
| | 読み取り: `openat(O_RDONLY \| O_NOFOLLOW)`、通常ファイル、64 KiB 以下、UTF-8 の JSON オブジェクト | 拒否 `malformed_request`（request_id はファイル名の stem。RV-02a を通過済みなので安全） |
| | RV-02b JSON の `request_id` が文字列でファイル名の stem と一致 | RV-02a と同じく `rejected/` へ |
| | RV-03 形: キー集合がちょうど `{schema, request_id, created_at, device_id, partkey, session_key, targets}`、`schema` は整数 1（bool 不可）、文字列 5 つが文字列、`targets` がちょうど 1 要素でキー集合 `{relpath, size, mtime}`、`size` は 0 以上の整数（bool 不可）、`mtime` は有限の数（bool 不可） | 拒否 `malformed_request` |
| | RV-04 リプレイ: request_id が `state/processed.log` に無い | 拒否 `replayed`（processed.log に再追記しない）。**同じ名前の結果ファイルが既に在れば結果は書かず、要求だけ消す**（結果を書いた後・要求を消す前に落ちた場合に、DELETED を MISMATCH で上書きしない） |
| | RV-05 `device_id + "/" + relpath == partkey` | 拒否 `partkey_mismatch` |
| | RV-06 `TargetIdentity.openVolume(VOLUMES_ROOT, device_id)`（§4.6。`DeviceID.isValid`、symlink でない、マウント点、`msdos`） | `.absent` → `device_absent`（**要求を残し processed にも書かない**）。それ以外 → 拒否 `not_a_mount_point` / `unexpected_fs` |
| | RV-07 ロック 2-B の観測: 同じ fd の `fstatfs` で `MNT_RDONLY` が立っていない | `mount_readonly`（**要求を残す**） |
| | RV-08〜RV-12 `TargetIdentity.withVerifiedTarget`（§4.6: relpath の健全性・openat 連鎖・symlink 拒否・通常ファイル・`_orig` 付きファイル名・親フォルダ名・size 一致・mtime 差 < 2.0） | 拒否（各理由語） |
| | RV-13 検証済みの親 fd に `unlinkat` → 続けて同じ fd に `fstatat(AT_SYMLINK_NOFOLLOW)` が `ENOENT` | 拒否 `unlink_failed` / `still_present` |

- 「拒否」= processed.log に追記（`fsync`）→ 結果 `SOURCE_IDENTITY_MISMATCH`（detail = 理由語）を `AtomicFile` で書く → 要求を unlink → `source_delete_rejected`
- **書き込みに失敗したとき**: processed.log の追記の失敗は無視して続ける（リプレイの防止が弱まるだけで、消しすぎには向かわない）。結果を書けなければ**要求を残して次の要求へ**（拒否なら `source_delete_rejected` も出さない。成功していれば `source_deleted` は出す）。要求の unlink の失敗は無視する（次回は RV-04 の `replayed` で止まる）
- 要求ファイルの unlink も `Unlinker.swift`（`removeRequest(named:)`。`queue/delete` 直下の `.json` に限る）が行う。デバイス上の unlink（`unlinkTarget(_:)`）と同じファイルに置く（PT-01）
- 成功 = unlink（RV-13）→ processed.log に追記（`fsync`）→ 結果 `DELETED`（detail = relpath）→ 要求を unlink → `source_deleted`
- 走査の終わりに `reaper_completed requests=<N>` を必ず出す（0 件でも出す）
- 「残す」= 何も書かず次回に回す（アプリ側の期限切れで取り下げられる）
- **voicedock の reaper から直した穴**（付録 C-DEL の最後）:
  - ロック 2-B の**観測値側**（heartbeat の `mount_readonly`）の確認が macOS の BSD sed で常に素通りしていた（設定値側の `MOUNT_MODE` の比較は効いていた）→ statfs で直接観測する
  - 検証 3 がディレクトリの有無だけだった → マウント点と FS 種別まで見る
  - denoised も通していた → `_orig` 必須
  - `request_id` の文字種を見ておらず、結果ファイルのパスに `/` を含められた → RV-02
  - request_id の無い要求が永久に残った → `rejected/` へ移す
  - heartbeat が読めないと素通り（fail-open）だった → 観測できなければ削除しない（fail-closed）
  - reaper.conf を bash で `source` していた（任意コード実行・未知キーを無視）→ 固定書式を厳格に parse する

---

#### 8.9.5 アプリ側: 要求を書く

**Session の削除段（`deleteSourcesIfSafe(sessionKey)`。voicedock pipeline.py:750-812 ＋ v1.1 の修正）** — 呼ばれる契機は 2 つ:
`processReadySessions` で Session が SAVED になった直後（backoff を見ずに 1 回）と、`evaluateDeletions`（backoff に従って再評価。DEL-14）

```text
row = Session; row.status ∉ deleteEvaluated → 何もしない
row.status == CLEANUP → finishCleanup(row); 終わり
requested = requestDeletions(row)                         // 下記
row, parts = 読み直し
readiness = LockEvaluator.readiness()
if readiness == .disabled(reason): log source_delete_skipped session_key reason=<reason>; completeWithoutDeleting(row, parts); 終わり
w = writability(row.device_id)
if w == .readOnly or w == .unknown: log source_delete_skipped session_key reason=device_readonly; completeWithoutDeleting(row, parts); 終わり
if parts のどれも awaitingDeletion に無い: completeWithoutDeleting(row, parts); 終わり          // ログなし
if requested == 0 and SOURCE_DELETING の Part が無い: updateSession(delete_attempts += 1); 終わり    // 遷移しない（未接続など）。updated_at が進む
if row.status != SOURCE_DELETING: row.status → SOURCE_DELETING                                    // SAVED か SOURCE_DELETE_PENDING から

completeWithoutDeleting(row, parts):
  RAW_SAVED で delete_request_id != nil の Part が在れば、今回は完了させず delete_attempts += 1 で終わる（結果か期限切れを待つ。期限切れで ID が外れた後の評価で完了する）
  RAW_SAVED の Part をすべて RAW_SAVED→COMPLETED
  row.status ∈ cleanupFrom なら row.status → CLEANUP
  finishCleanup(読み直した row)
finishCleanup(row):   // row.status == CLEANUP のときだけ
  stagingDisposable の各 Part について SafeUnlink で staging/<slug>/ の audio16k.wav・audio16k.wav.tmp・whisper.json を消し、空になったディレクトリを消す（FAILED の 16 kHz は残す。SM-23）
  1 つでも失敗 → disk_space_low session_key=… reason=staging_unlink_failed（WARNING）で CLEANUP のまま終わる（次の評価でやり直す）
  全部成功 → CLEANUP→COMPLETED
```

**Part の要求（`requestDeletions(session)`）** — Raw を保存した直後（§5.5）と上の削除段から呼ばれる:

```text
snapshot = その時点の最新（nil か新鮮でなければ 0 を返す。DEL-20）
if LockEvaluator.readiness() != .configured: 0 を返す
for part in Session の Part（started_at, partkey 順）:
  part.status ∉ partDeletable → 飛ばす
  part.status ∈ {SOURCE_DELETING, COMPLETED} → 飛ばす（通常経路は COMPLETED を消しにいかない）
  part.delete_request_id != nil → 飛ばす（結果待ち）
  part.partkey ∈ この tick で PENDING に落とした集合 → 飛ばす（同じ周回で再要求しない。DEL-11）
  part.status == RAW_SAVED かつ sourceIsObservedAbsent(part, snapshot):                          // F-64。要求を書かない
      part.status RAW_SAVED→COMPLETED（detail already_absent）                                  // TransitionConflict → source_delete_skipped … reason=status_changed、飛ばす
      log source_delete_skipped recording_key reason=already_absent; 飛ばす                    // source_deleted_at は入れない（アプリが消したのではない）
  canDeleteSource(...) が偽 → 飛ばす
  id = RequestID.make(partkey, now)
  updateRecording(delete_request_id = id)                         // ① ID を先に
  要求ファイルを AtomicFile で書く                                 // ② 失敗 → updateRecording(delete_request_id = nil)、
                                                                  //    source_delete_pending recording_key reason=queue_write_failed error_code=DELETE_QUEUE_FAILED（WARNING）、飛ばす
  part.status → SOURCE_DELETING                                   // ③ RAW_SAVED か SOURCE_DELETE_PENDING から。TransitionConflict → source_delete_skipped … reason=status_changed、飛ばす
  log delete_requested request_id recording_key session_key
  requested += 1
```

- **事前確認 `preIdentityCheck(part, snapshot)`**（voicedock cleaner.py:351-388 ＋ 本アプリの強化）: `source_path` が空でない、`RelPath.isSafe(source_path)`、
  `PartKey.make(device_id, source_path) == partkey`、snapshot にそのデバイスが在り relpath が在る、`source_size` / `source_mtime` が nil でない、
  そして**アプリも実ファイルに検証をかける**: 注入された `VolumeOpener` でボリュームを開き（本番は `TargetIdentity.openVolume`）、`VolumeHandle.readOnly == false` を確かめ、`TargetIdentity.withVerifiedTarget` をかける（body では何もしない）。
  これは事前確認であり、**reaper は同じ検証を unlink の直前に独立してやり直す**（判断と直前の再検証を分ける。DEL-26）
- **元ファイルが無いと観測できた `sourceIsObservedAbsent(part, snapshot)`**（F-64）: 上の新鮮な snapshot で、`snapshot.unavailable[device_id]` が無く、
  `snapshot.devices[device_id]` が在り（接続中で列挙できた。列挙に失敗したと分かったデバイスは IngestService が devices に載せない）、`source_path` が nil でも空でもなく、
  **snapshot がその Part の取り込みより後の観測である**（`snapshot.completedAt ≥ updated_at + 1 秒`。updated_at は RAW_SAVED にした時刻で取り込みより後。秒に切り捨てて記録されるので 1 秒足す。読めなければ偽）、
  そしてその relpath が一覧に**無い**。どれかが欠ければ偽（観測できたときだけ「無い」と言う。安全側は「待つ」）。書き込み可否（`readOnly`）は問わない（消さないので）。
  取り込みより後の条件が無いと、Raw の直後（§5.5）に 1 つ前の走査（その Part を取り込む前）の snapshot が経過時間だけで新鮮とされ、挿し直した直後の新しい録音を「無い」と判定しうる。
  `devices` に載った一覧（`DeviceObservation.relpaths`）は、深さの上限（§8.1）の内側では完全な列挙: 読めないディレクトリ（`opendir` / `readdir` の失敗）か `ENOENT` 以外で `lstat` が失敗した項目が 1 つでもあれば `complete == false` になり、そのデバイスは `devices` に載らない（F-67）。
  含まれないのは、深さの上限の外（取り込みの範囲の外なので Part にならない。ただし `maxScanDepth` を下げる前に取り込んだ Part は例外）と、列挙から `lstat` までの間に消えた項目（`ENOENT`。本当に無い）だけ。
  前者の例外と下の正規化の違いでは在る元ファイルが「無い」に見えうるが、完了は消さない側なので録音は失われない（消し損ねは「過去分を削除対象にする」では拾えず、デバイスに残る）。
  照合は `sameKey`（Unicode のスカラー列の一致。NFC / NFD の正規化はしない）。`source_path` は同じデバイスの走査の一覧から取った列なので通常は一致するが、正規化の違う名前は「無い」に見えうる（上と同じく消さない側）
  RAW_SAVED だけが対象で、SOURCE_DELETE_PENDING は従来どおり「手動で消した分を完了にする」（§8.9.9）に任せる。`delete_request_id` を持つ Part は結果待ちなので手前で飛ぶ。
  これが無いと、削除が有効（`.configured`・`.writable`）なのに元ファイルが消えている RAW_SAVED の Part は、事前確認が永久に偽で要求が書かれず、
  削除段が `requested == 0` のまま `delete_attempts += 1` を繰り返して Session が COMPLETED にならない（抜け道は削除を無効にすることだけだった。CR-15・DEL-15/16）
- 書く順は ①ID → ②要求ファイル → ③遷移（§4.4）。②の後・③の前に落ちても、Part は RAW_SAVED のまま ID を持ち「結果待ち」として回収される（§8.9.6）
- `evaluateDeletions`: 全 Session を `ORDER BY updated_at, session_key` で見て、`deleteEvaluated` に在り、`now − updated_at >= delay(delete_attempts)` のものに `deleteSourcesIfSafe`。
  `delay(a) = backoff[min(max(a, 1), backoff.count) − 1]`（**a = 0 と 1 はどちらも先頭の値**。voicedock pipeline.py:1855-1868。テスト: (1, 30 秒前)→評価しない、(1, 120)→する、(4, 1800)→しない、(4, 7200)→する）
- **根拠 B（`settleSkippedDeletions`）**: `deleteSkippedSource == false` なら何もしない。`LockEvaluator.readiness()` が `.configured` でなければ、ノートも transcript も読まずに何もしない。この tick で PENDING に落とした Part は飛ばす。SKIPPED の Part（`started_at, partkey` 順）のうち、**新鮮な snapshot にデバイスと relpath が載っているものだけ**を
  （過去の件数に比例させない）読み直して、`session_key` が在り、`source_deleted_at` と `delete_request_id` が nil で、`now − updated_at >= backoff[0]`（**先頭の値**）のものについて、
  双子（`duplicate_of` → その Part → その Session と Part 群）を引いて `canDeleteSource` が真なら ①ID → ②要求ファイルを書く（**遷移しない**）

#### 8.9.6 reaper の起動と結果の回収（**同じ秒問題を構造的に消す**）

```text
runReaperIfNeeded:     // snapshot が新鮮な tick だけ
  queue/delete に `.` 始まりでない .json が 1 つ以上在る
  かつ readiness == .configured（署名と版の検証を含む。起動の直前は**キャッシュを使わず必ず**検証し直す）
  かつ snapshot のどれかのデバイスが .writable
  → ProcessRunner.run(<HOME>/bin/voicedock-reaper --home <HOME>, timeout 120 秒)  → 常に reaper_run exit=<n>。0 以外なら reaper_failed reason=exit_<n>（4 は busy。タイムアウトは reason=timeout）
  → G = await ingest.scanNow()（**呼び出しの後に始まり完了した**走査の generation。見送りなら nil）; G が nil でなければ reaperScanGeneration = G
    （nil のときは reaperScanGeneration を「現在の generation + 1」にして、次に完了する走査を待つ。DELETED の結果はそれまで残る）
  → collectDeleteResults

collectDeleteResults:  // 毎 tick（新鮮でなくても）と reaper の後
  queue/result の `.` 始まりでない .json を名前順に:
    ContractJSON で読めない → 残す
    part = partkey で引く。無い → 残す（別の用途かもしれない）
    part.delete_request_id == nil、または part.status ∉ {RAW_SAVED, SOURCE_DELETING, SOURCE_DELETE_PENDING, SKIPPED} → 結果を捨てる
    result.request_id != part.delete_request_id → 結果を捨てる（古い試行。DEL-08）
    SOURCE_IDENTITY_MISMATCH → pend(part, SOURCE_IDENTITY_MISMATCH, 理由語)、結果を捨てる
    DELETED:
      snapshot == nil か snapshot.generation < reaperScanGeneration か、そのデバイスが snapshot に無い → **残す**（判定できる観測を待つ）
      relpath が snapshot に在る → pend(part, SOURCE_DELETE_FAILED, "still_in_inventory")、結果を捨てる
      無い → updateRecording(source_deleted_at = now, delete_request_id = nil)、SKIPPED 以外は COMPLETED まで進める
             （RAW_SAVED / SOURCE_DELETE_PENDING → SOURCE_DELETING → COMPLETED、SOURCE_DELETING → COMPLETED）、source_deleted recording_key request_id、結果を捨てる

pend(part, code, reason):   // 根拠 A と B で共有。分かれるのは状態の扱いだけ
  SOURCE_DELETING → SOURCE_DELETE_PENDING（error_code = code、detail = reason）→ delete_request_id = nil
  それ以外（SKIPPED・RAW_SAVED・SOURCE_DELETE_PENDING）→ 状態を動かさず delete_request_id = nil
  log source_delete_pending recording_key reason=<reason>（WARNING）; この tick で PENDING に落とした集合へ入れる
```

- voicedock は「inventory の `generated_at` が結果の `completed_at` より新しいか」を**秒単位の時刻**で比べ、同じ秒で判定を誤った（#156 / #182）。
  本アプリは**reaper の終了を待ってから走査する**ので、「reaper より後の観測」が構造で保証される。**時刻を比べない**
- 起動直後は `reaperScanGeneration = 0`。reaper は `state/reaper.lock` を実行中ずっと持ち、IngestService は走査の前に同じロックを取るので、アプリが落ちて reaper だけが生き残っていても、
  起動後の最初の走査はその reaper の後になる
- 結果の回収は snapshot で絞らない（reaper が消した後のファイルは snapshot に載らない。絞ると回収できる瞬間に対象から外れる）。**回収は結果ファイル全件が対象**
  （voicedock は Session の Part に限っていたので、「過去分」で SOURCE_DELETING にした Part を二度と回収できなかった）
- 根拠 A と B で**回収規則は同じ関数を共有**し、分かれるのは後始末だけ（成功: `source_deleted_at` を書き ID を外す／失敗・期限切れ: ID を外すだけ）

#### 8.9.7 期限切れ

```text
expireDeleteRequests:   // 毎 tick
  delete_request_id IS NOT NULL の Part（started_at, partkey 順）ごとに:
    DB から読み直す。無い・ID が nil → 飛ばす
    now − updated_at < deleteResultTimeoutSeconds(3600) → 飛ばす
    その request_id の結果ファイルが在る → 飛ばす（DELETED の判定を観測待ちで残している。取り下げない）
    queue/delete と queue/result のうち partkey がこの Part のものを全部取り下げる（SafeUnlink）
    pend(part, DELETE_TIMEOUT, "no_result")。TransitionConflict → 飛ばす
```

- 読み直しと `TransitionConflict` の捕捉の 2 層を、**それぞれ独立したテスト**で固定する（DEL-18 / TEST-17）
- 対象は全 Part（voicedock は Session の Part に限っていた）

#### 8.9.8 有効化・無効化（パネルの「元音声の削除」）

**有効化**（`DeletionEnabler.enable(confirmation:)`。すべて成功するか、1 つも変えないか）:
1. 事前確認を表示する: 「1 日以上の運用で Raw ノートが正しく作られていることを確かめましたか」「消した録音は戻りません」と、最新の診断結果
2. **赤いボタンを 3 秒長押しさせる**（クリック 1 回やチェックボックスでは通らない。押している間はリングが満ち、途中で離すと取り消し。GUI のチェックボックス 1 つは摩擦そのものを消す。UI は長押しの完了で `confirmation` に定数 `"ENABLE"`（`DeletionStrings.confirmationWord`）を渡し、`DeletionEnabler` は `confirmation == "ENABLE"` の完全一致で確かめる（安全の二重化）。F-65）
3. 複製（§8.9.3 の 6）→ `bin/reaper.conf` を `DELETE_SOURCE_AUDIO=true` で書く → `config.json` の `cleanup.deleteSourceAudio = true`・`device.mountMode = rw` を書く（いずれも `AtomicFile`）
4. どれかが失敗したら、書いたものを全部元に戻す（元の reaper.conf・config.json の内容を控えておき書き戻す。新しく置いた reaper は消す）
5. 「読み書きできるようになるのはデバイスを挿し直した後です」と表示する。`deletion_enabled`

**根拠 B（無音・重複も消す）**は別の操作（`enableSkippedDeletion(confirmation:)`）。削除が有効なときだけ出し、同じく赤いボタンの 3 秒長押し（`confirmation` は定数 `"ENABLE"`）で `cleanup.deleteSkippedSource = true` にする。

**無効化**（`DeletionEnabler.disable()`）: **確認を求めない**（止めたいときに止められること）。この順で（**消す能力に近いものから先に止める**）、途中で失敗しても残りを続ける:
reaper.conf を false（reaper 側のロック 1 を先に掛ける）→ `bin/voicedock-reaper` を削除 → config を `ConfigStore.update(_, reaperConfObservation: false)` で `deleteSourceAudio = false`・`deleteSkippedSource = false`・`mountMode = ro` に →
`queue/delete` の要求を全部取り下げる → 接続中のデバイスを直ちに読み取り専用へ再マウント（`ingest.scanNow()`。再マウントできたかは §8.9.2 と同じ `statfs` の `MNT_RDONLY` の観測で確かめる。実機の試験では `/sbin/mount` の出力を貼る）。`deletion_disabled`。失敗した段の名前を返し、パネルに出す

**ロック 1 の修復**（`DeletionEnabler.reconcileLock1()`。§6.1）: **reaper.conf を false にするだけ**（reaper の削除・要求の取り下げ・config の書き換えはしない）。`config_warning rule=CV-30`。
config 側（`deleteSourceAudio` / `deleteSkippedSource` / `mountMode`）は `ConfigStore.load()` が自分で無効側に直す（設定エラー中は `ConfigStore.update` が通らないので、DeletionEnabler から config を書けない）

**有効化の書き込み順**（§8.9.8 の 3）は「reaper を複製 → reaper.conf を true → config を `update(_, reaperConfObservation: true)` で有効」。途中で落ちて片方だけ有効になった場合は、次の読み込みで reconcileLock1 が無効側へ揃える

**常時表示**: 削除が有効な間（`config.cleanup.deleteSourceAudio` が真 **または** reaper.conf が有効。片方だけ有効な中途の状態でも出す）は、メニューバーのアイコンの横に `trash` シンボルを常に出す。パネルの「元音声の削除」には 3 つのロックを**個別に**、設定値と観測値を並べて出す（voicedock の起動時警告と voicedock doctor の D-17 に相当。DR-14 と同じ `LockEvaluator` を使い、式を書き直さない）:

```text
ロック 1  : アプリ=有効, reaper.conf=有効
ロック 2-A: 削除モジュール=導入済み（署名 OK, 版 1.0.0）
ロック 2-B: 設定=rw, DJIMIC3=読み書き可能（観測）
```

- 観測の表示語: デバイス 0 台 → `デバイス未接続`、観測できない → `不明`、`読み取り専用` / `読み書き可能`（**nil を「読み書き可能」に丸めない、0 台を観測扱いしない**。#107 / #148）

#### 8.9.9 後追い（voicedock の `cleanup --backlog` / `--resolve-absent`）

パネルの「詳細」に 2 つのボタン。**どちらも先にプレビュー（件数と、対象外の件数と理由）を出し、もう一度押して実行する**（`--dry-run` に相当。TEST-20: 対象 1 件以上でテストする）。
実行は Worker の直列ループに 1 件の仕事として入れる。

- 「過去分を削除対象にする」（`BacklogPlanner.planBacklog`）: **COMPLETED の Session** の Part のうち、状態が COMPLETED か SOURCE_DELETE_PENDING のもの。
  `source_deleted_at` が在る → 対象外 `already_deleted`、`delete_request_id` が在る（結果待ち。復旧後の PENDING など）→ 対象外 `not_deletable`（二重に要求しない）、`canDeleteSource` が偽 → `not_deletable`、真 → 対象。
  実行: 各対象を読み直し、ID → 要求ファイル → `COMPLETED→SOURCE_DELETING` / `SOURCE_DELETE_PENDING→SOURCE_DELETING`（回収は §8.9.6 の全件回収が拾う）
- 「手動で消した分を完了にする」（`planResolveAbsent`）: SOURCE_DELETE_PENDING の Part のうち（RAW_SAVED の Part は §8.9.5 の `requestDeletions` が同じ観測の条件で自動で完了にする。F-64）、**新鮮な snapshot にそのデバイスが載っていて relpath が無い**もの
  （デバイスが無い・snapshot が古い → 対象外 `device_absent`、relpath が在る → `still_present`、`source_path` が無い → `still_present`。voicedock は未接続でも「無い」と判定していた）。
  実行: `SOURCE_DELETE_PENDING→SOURCE_DELETING`（detail `resolve_absent`）→ `SOURCE_DELETING→COMPLETED`（detail `already_absent`）→ 要求・結果を取り下げ → ID を外す →
  `source_delete_skipped recording_key=… reason=already_absent`。**`source_deleted_at` は入れない**（不可逆操作の記録に嘘を混ぜない）
- 実行中に状態が変わった Part は `source_delete_skipped … reason=status_changed` で飛ばし、残りを続ける（DEL-19）

---

### 8.10 VDModels（モデルの一覧とダウンロード）

**インターネットに出るのはこのモジュールだけ**で、しかも**利用者がボタンを押したときだけ**（PT-02）。カタログの型と読み込み（`ModelCatalog`）は VDCore に置く（§3.4）。

`Resources/ModelCatalog.json`（`schema: 1`。whisper と vad の値は 2026-09-18 に HF API で確認した実値。T-24 でもう一度確かめる）:

```json
{
  "schema": 1,
  "whisper": [{"id": "large-v3-turbo-q5_0", "displayName": "Whisper large-v3-turbo (q5_0)", "file": "ggml-large-v3-turbo-q5_0.bin",
               "url": "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin",
               "sha256": "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2", "bytes": 574041195, "license": "MIT"}],
  "vad":     [{"id": "silero-v5.1.2", "displayName": "Silero VAD v5.1.2", "file": "ggml-silero-v5.1.2.bin",
               "url": "https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v5.1.2.bin",
               "sha256": "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf", "bytes": 885098, "license": "MIT"}],
  "llm":     [{"id": "qwen3-30b-a3b-instruct-2507-q4_k_m", "displayName": "Qwen3 30B-A3B（推奨・32 GB 以上）",
               "file": "Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf",
               "url": "https://huggingface.co/unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF/resolve/eea7b2be5805a5f151f8847ede8e5f9a9284bf77/Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf",
               "sha256": "6c997b8af17debdfb01d890214400ccbab00db6acc0ba8da5de1cc906c4774d0", "bytes": 18556686752,
               "minMemoryGB": 32, "license": "Apache-2.0", "verified": false},
              {"id": "qwen3-4b-instruct-2507-q4_k_m", "displayName": "Qwen3 4B（16 GB の Mac 向け）",
               "file": "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
               "url": "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/a06e946bb6b655725eafa393f4a9745d460374c9/Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
               "sha256": "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597", "bytes": 2497281120,
               "minMemoryGB": 16, "license": "Apache-2.0", "verified": false}]
}
```

- **値（URL のコミット SHA、sha256、bytes、license）は推測で埋めない。**上の値は HF API（`/api/models/<repo>?blobs=true` の LFS oid と size）で確かめたもの。T-24 で再確認し、LLM の `verified` は §10.6 の受け入れ試験に合格したものだけ `true` にする
- LLM は公式（Qwen）の GGUF が無く、ggml-org には Q4_K_M が無い（2026-09 時点）。unsloth と lmstudio-community の 2 つが候補で、T-24 で決める（上は unsloth を仮に置いた）。
  **思考モード付きのモデルは載せない**（`<think>` 除去はあるが、出力が長くなり時間を食う）
- 一覧に載せる条件（`verified: true`）: §10.6 の LLM 受け入れ試験に合格、ライセンスが再配布ではなく利用者のダウンロードを許すこと。`verified: false` のものは一覧に出さない（T-24 まではテスト用に読み込むだけ）
- `ProcessInfo.physicalMemory < minMemoryGB × 1024³` のモデルは選べない（理由を表示）
- **ファイルから読み込む**: 利用者が選んだ `.gguf` を読みながら SHA-256 を計算して `models/llm/.custom-import-<乱数 16 hex>.gguf.part` へコピー → SHA が出たら rename で `custom-<sha256 先頭 16>.gguf`（既に在れば `.part` を消して既存を使う）、`modelID = custom:<sha256>`。
  「動作保証外」と表示し、メモリ確認は警告だけ
- ダウンロード（`ModelDownloader`）: 始める前に `ModelFiles.isPresent` が真なら、何もせず成功を返す（18.6 GB を無駄に落とさない）。`URLSessionDownloadTask`（`URLSessionConfiguration` は注入されたファクトリから）→ 完了したファイルを `models/<kind>/.<file>.part` へ移す →
  **ストリームで SHA-256 照合**（`hashChunkBytes` ずつ）とサイズ照合 → 一致したら `models/<kind>/<file>` へ rename、`model_downloaded id=…`。
  不一致は `.part` を消してエラー表示（`model_download_failed id=… reason=sha256_mismatch|size_mismatch|http_<code>|network`）。キャンセル・失敗時の再開データは `models/.<file>.resume` に保存し、次回はそこから再開する
- ファイル名は `[A-Za-z0-9._-]` だけ・`..` を含まない・`.` で始まらない（OPS-19。カタログ読み込み時に検査し、違反する項目は捨てる）
- カタログの URL は `https://huggingface.co/` で始まり、`/resolve/<40 桁の 16 進>/` を含むこと（PT-13 も検査する。リダイレクト先の CDN は許す）。利用者が URL を入力する機能は作らない
- 「在る」の判定（ガード・はじめに）はファイルが在り size が `bytes` と一致すること（速い）。SHA-256 の照合はダウンロード・取り込みの直後と診断（DR-05 / DR-08）で行う
  （18.6 GB の照合は数十秒かかる。照合済みの `(path, inode, size, mtime) → sha256` を `ModelVerificationCache`（VDCore の actor）がメモリに覚え、ModelManager と診断が共有する。変わっていなければ飛ばす）

### 8.11 診断（DR）と沈黙の検出

**診断**（パネル「詳細・診断 → 診断を実行」。**何も書き換えない**。OPS-14。`VDPipeline/Diagnostics/`）

- 結果は 4 値: `ok`（✓）/ `notice`（!）/ `fail`（✗）/ `skip`（-）（voicedock doctor.py:45-57）。サマリは「合格 <n>・失敗 <n>・注意 <n>」（skip は数えない）
- 実行規則（voicedock doctor.py:617-656）: 下の表の順に実行する。**「致命」の検査が fail を出したら、以降の検査は実行せず skip（「先行する致命的な検査が失敗」）**。
  ただし DR-14（削除モードの表示）だけは設定が読めていれば必ず実行し、**最後に**置く
- 診断のコードは書き込み・削除の API を呼ばない（PT-17）。DB は `ReadOnlyStore.open`、Vault は `access` と `opendir` だけ

| ID | 順 | 検査 | fail / notice | 致命 |
|---|---|---|---|---|
| DR-01 | 1 | 設定が CV をすべて満たす（違反を 1 件 1 行で出す） | fail | ○ |
| DR-16 | 2 | タイムゾーンが解決できる | fail | ○ |
| DR-02 | 3 | DB: ファイルが在れば読み取り専用で開き `PRAGMA quick_check` が `ok`、適用済みマイグレーションが最新。無ければ notice「まだ作られていません」（作らない） | fail | ○ |
| ~~DR-13~~ | — | ~~取り下げ（F-61）: voicedock の Helper の LaunchAgent が登録されていない~~ | — |  |
| DR-03 | 4 | `<HOME>` の空き容量: `SpaceCheck`（設定値を使う）を duration 1800 秒で呼んで `.ok` | notice |  |
| DR-04 | 5 | whisper-cli が在り、`--help` に VAD の 6 フラグが逐語で在る（VAD 無効なら無くても notice） | fail |  |
| DR-05 | 6 | Whisper モデルが在り SHA-256 が一致 | fail |  |
| DR-06 | 7 | VAD モデルが在り SHA-256 が一致。VAD 無効なら notice「無音から幻覚が生成され、13 倍以上遅くなります」（ASR-02） | fail / notice |  |
| DR-07 | 8 | llama-server が在り、使うフラグがすべて `--help` に在る | fail |  |
| DR-08 | 9 | LLM モデルが選ばれて在り SHA-256 が一致（custom は ID の SHA と一致するかだけ）、メモリが足りる（custom はメモリの目安が無いので `.ok` とし、詳細に「動作保証外のモデルです」と出す） | fail |  |
| DR-10 | 10 | Vault: `VaultCheck` が `.available`（`.notReadable(EPERM)` は許可の案内）かつ `access(W_OK)`。**ファイルもフォルダも作らない**（NOTE-16）。「書けない」と「Vault でない」を別の文言で出す | fail |  |
| DR-11 | 11 | 接続中のデバイスを列挙できる（snapshot の `unavailable` に `not_listable` が無い）。不可なら「システム設定 → プライバシーとセキュリティ → ファイルとフォルダ → VoiceDock → リムーバブルボリューム」を案内。**デバイス未接続なら skip** | fail |  |
| DR-12 | 12 | ログイン項目の状態（`SMAppService.mainApp.status`）。`.enabled` 以外は notice | notice |  |
| DR-15 | 13 | inbox の取り残し（`inboxLeftoverStates` の Part の inbox ファイルが残っている）。件数と合計サイズ。**自動では消さない** | notice |  |
| DR-17 | 14 | アプリ自身の署名が有効で ad-hoc でない（Team ID を持つ）。ad-hoc なら「ビルドのたびにリムーバブルボリュームの許可が失効します」（voicedock DH-16 相当） | notice |  |
| DR-14 | 15 | 三重ロックを個別に表示（§8.9.8 の表示。`LockEvaluator` を使い、式を書き直さない）。常に notice | notice | （必ず最後） |
| DR-09 | 別 | LLM に実リクエスト（別のボタン。Worker の直列ループに 1 件の仕事として入れ、`LlamaServerSupervisor` の単一インスタンスを使う。数十秒かかる）。結果「<model>（<秒 小数 1 桁>s）」 | fail |  |

- 件数（15 + DR-09 = 16。取り下げた DR-13 は数えない。F-61）は SPEC の表から数え、README と文書テストで突き合わせる（§10.3）

**要対応（沈黙の検出を含む。`AttentionItem`）**（無人稼働で最も起きやすい故障は「何も起きない」。SM-24 / RK-23）— パネル上部と、アイコンの「要対応」表示に出す。
**利用者の操作が要るものだけを「要対応」にする**（警告が鳴り続けると本物が埋もれる。OPS-12）:

| 項目 | 条件 | 操作ボタン |
|---|---|---|
| `configInvalid` | 設定エラー状態 | 設定ファイルを Finder で表示 / 読み直す |
| `vaultNotConfigured` / `vaultUnavailable` | Vault のガード（§8.7） | Vault を選び直す / システム設定を開く（EPERM） |
| `modelMissing(kind)` / `llmNotSelected` / `llmInsufficientMemory` | 文字起こし・解析のガード | モデルの節を開く |
| `toolMissing(kind)` | whisper-cli か llama-server がバンドルに無い（`PauseReason.whisperMissing` / `llamaServerMissing`）。処理が完全に止まるので必ず出す | 診断を実行 |
| `deviceNotListable(name)` | snapshot の `unavailable` に `not_listable` | システム設定を開く |
| `deviceNeedsReplug(name)` / `deviceNameInvalid(name)` | `mount_name_mismatch` / `invalid_device_id` | —（手順を表示） |
| `ingestSilent` | デバイスが接続されているのに、走査中でもなく `max(completedAt, lastActivityAt)` が `snapshotMaxAgeSeconds` より古い（#117: コピー中に誤報しない） | — |
| `diskSpaceLow` | 変換のガード中 | — |
| `lockMismatch` | CV-30 / CV-33 | — |
| `reaperUpdateRequired` | reaper の版が違う | 有効化フローを開く |

- **要対応にしないもの**: FAILED の Part / Session（次の接続で必ず再評価される。状態の詳細に件数と「次の接続で再試行」を出す「注意」）、ログイン項目（「はじめに」で選んだ後は出さない）

### 8.12 UI（D-7: メニューバーのアイコン → 設定パネル。これ以外の画面を作らない。パネルの中の画面の切り替えは可。F-65）

**構成**: `NSApplication` の `.accessory`（`Info.plist` の `LSUIElement = YES`。Dock に出ない）。`NSStatusItem` ＋ `NSPopover`（`behavior = .transient`）で
SwiftUI の `PanelView` をホストする。`MenuBarExtra` は使わない（プログラムから開けないため。初回起動時に自動で開きたい）。
パネルを開くとき `NSApp.activate()`（パネルの操作に最初のクリックから反応させるため）。
popover の高さは中身に合わせる（`NSHostingController.sizingOptions = .preferredContentSize`。固定の高さを持たない。F-65）

**アイコン**（SF Symbols、テンプレート画像。`IconState` を AppModel が計算する。SPEC S21。「IconState」の列は case、`trash` は case ではなく並べて出す記号）:

| 状態 | IconState | シンボル |
|---|---|---|
| 待機中 | `idle` | `waveform` |
| 取り込み中 | `ingesting` | `arrow.down.circle` |
| 文字起こし・要約中 | `processing` | `text.bubble` |
| 要対応あり（上の 3 つより優先） | `attention` | `exclamationmark.triangle` |
| 削除が有効（上記に**並べて**常時表示） | — | `trash` |

**パネル**（幅 380pt 前後、カード型。**主画面はスクロールしない**。長い中身（7・8、要対応の多数、6 の完了後）は popover の中の**別の画面**に切り替え、見出しに「‹ 戻る」を置く。別の画面の中身が長いときだけ、その画面の中でスクロールする。閉じたら次は主画面から開く。F-65。上から）:

1. **状態**: 1 行の文言（例「待機中」「DJIMIC3 から取り込み中 3/12 — コピーが終われば抜いて大丈夫です」「文字起こし中 07:12 の録音」「要約中 2026-08-29」）、
   最終接続、未処理（合計時間と件数）、デバイスの空き容量
   - **最終接続**（F-70）: デバイスを観測している間は「接続中（<名前>、…）」（名前はバイト順）。観測していなければ、`devices` が空でない snapshot を最後に見た時刻（snapshot の `completedAt`）を「yyyy-MM-dd HH:mm」、一度も見ていなければ「まだありません」。
     時刻は `<HOME>/ui-state.json` の `lastConnectedAt`（epoch ミリ秒の整数。`AtomicFile`）に残し、**再起動の後も**出す（起動直後の、メモリに値が無い間だけファイルの値を使う）。
     書くのは AppModel で、この起動で最後に書こうとした値（無ければファイルの値）と**違う**ときだけ（時計が戻って小さくなった値も書く。等しい値は書き直さない）。接続中は観測時刻がその値から 60 秒以上（前後どちらへでも）動いたときだけ、切れたら最後に見た時刻を 1 回だけ書く（走査のたびには書かない）。書けなくても表示は変えず、同じ値を書き直し続けない。
     refresh が重なって古い `ui-state.json` を読んだ read が後から終わっても、この起動で書いた `loginItemDecided = true` と最終接続を古い値で戻さない（AppModel が書いた値を覚え、書くたびに合わせる）。
     DB（取り込みの時刻）からは導かない（新しい録音が無かった接続を拾えない）
   - その下に小さな「今すぐ要約」ボタン（SF Symbol `sparkles`）。押すと `WorkerJob.summarizeNow(reply:)` を入れ（§5.4）、返事を数秒の短い通知にする（閉じた数 n > 0 なら「要約を始めました（n 件）」、0 なら「新しく要約する録音はありません」、失敗は `SummarizeNowFailure.message` のまま）。返事を待つ間は押せない。DR-09 と同じく世代を持ち、閉じた後の返事は捨てる（F-66）
2. **要対応**（ある時だけ。状態の直下のカード）: §8.11 の項目ごとに説明と操作ボタン（「再試行」= requeue(.manual)、「システム設定を開く」、「Vault を選び直す」など）。主画面には先頭の 2 件と「ほか n 件 ›」（押すと全件の画面）
3. **はじめに**（未完了の項目がある間だけ、状態・要対応の下に出す）: 項目（①〜⑤）と完了の条件は下の「はじめに」の項目の表（SPEC S22）のとおり。
   ⑤ はデバイス名が `NO NAME` のときの改名の案内（**アプリは改名しない**。デバイスに書かない。Finder か ディスクユーティリティで行う手順を表示。DEV-10）
   - ④の「今はしない」は `<HOME>/ui-state.json`（`HomeLayout.uiState`。§2.3）（`{"schema": 1, "loginItemDecided": true}`。`AtomicFile`）に記録する（UserDefaults を使わない。PR-03）。
     同じファイルに 1 の最終接続 `lastConnectedAt`（整数。一度も観測していなければキーを書かない）を持つ（F-70。schema は 1 のまま）。
     読むときは、無い・壊れた・`schema` が 1 でないファイルは既定、未知のキーは無視、`lastConnectedAt` が無い・型が違う・0 以下のときはそれだけを nil にする（「今はしない」を失わない）
4. **保存先（Vault）**: フォルダ名の 1 行（押すと「変更…」。`NSOpenPanel`、ディレクトリのみ、`VaultCheck` が `.available` でなければ拒否）
5. **モデル**: 1 モデル 1 行。Whisper（状態・入手）、LLM（カタログから選ぶ `Picker` を `Menu` の中に。メモリ不足のものは選べない理由付き、「ファイルから読み込む…」も `Menu` の中、進捗バー、キャンセル）
6. **一般**: 「ログイン時に起動」トグル（`SMAppService.mainApp.register()` / `unregister()`。`requiresApproval` なら `SMAppService.openSystemSettingsLoginItems()` を開くボタン）。状態の見出しの ⚙ から開く「設定」の画面に置く（「はじめに」の④が未完了の間は「はじめに」のカードにも置く）
7. **元音声の削除**（主画面は「› 元音声の削除  有効／無効」の行。押すと別の画面）: §8.9.8 のロック表示・事前確認・有効化（赤いボタンの 3 秒長押し）・無効化（確認なしの 1 クリック）・無音と重複の削除（同じ長押し）
8. **詳細・診断**（主画面は行。押すと別の画面。状態の詳細はこの画面にいる間だけ読む）: 状態の詳細（下記）、診断を実行・LLM の疎通確認、過去分の削除・手動で消した分（§8.9.9）、ログと設定ファイルを Finder で表示、設定を読み直す、版
9. **終了**ボタン

節と画面（SPEC S20。「#」は上の番号。「主画面」の列は主画面での出し方（— は主画面に出さない）、「画面」の列は別の画面の `PanelScreen` の case（— は別の画面を持たない））:

| # | 節 | 主画面 | 画面 |
|---|---|---|---|
| 1 | 状態 | カード | — |
| 2 | 要対応 | カード（先頭の 2 件と「ほか n 件 ›」） | `attention` |
| 3 | はじめに | カード（未完了の項目がある間だけ） | — |
| 4 | 保存先（Vault） | カード | — |
| 5 | モデル | カード | — |
| 6 | 一般 | —（「はじめに」の④が未完了の間は「はじめに」のカードに置く） | `settings` |
| 7 | 元音声の削除 | 行 | `deletion` |
| 8 | 詳細・診断 | 行 | `details` |
| 9 | 終了 | ボタン | — |

「はじめに」の項目（SPEC S22。上の 3 の ①〜⑤ の順。「項目」の列はパネルの文言、「OnboardingStep」の列は case）:

| # | 項目 | OnboardingStep | 完了の条件 |
|---|---|---|---|
| ① | Vault を選ぶ | `vault` | `VaultCheck` が `.available` |
| ② | Whisper モデルを入手する | `whisperModel` | Whisper モデルが在り、VAD が有効なら VAD モデルも在る |
| ③ | LLM を選んで入手する | `llmModel` | LLM が選ばれ、そのモデルが在る |
| ④ | ログイン時に起動する | `loginItem` | ログイン項目が有効、または「今はしない」を選んだ（`loginItemDecided`） |
| ⑤ | デバイスの名前を変える | `deviceName` | 完了にしない（改名の要るデバイス（`NO NAME`）が在る間だけ出す。DEV-10） |

`<HOME>/ui-state.json` の鍵（SPEC S23。この 3 つだけを書き、値の列が「任意」の鍵は値があるときだけ書く。読むときは `schema` が 1 でなければ既定値、未知の鍵は無視、任意の鍵が無い・型が違うときはそれだけを既定にする）:

| 鍵 | 型 | 値 |
|---|---|---|
| `schema` | 整数 | `1` |
| `loginItemDecided` | 真偽 | 「ログイン時に起動」をオンにしたか「今はしない」を選んだら `true`（既定 `false`） |
| `lastConnectedAt` | 整数 | 任意。デバイスを最後に観測した時刻（epoch ミリ秒。1 の最終接続。一度も観測していなければ書かない。0 以下は無いものとして読む。F-70） |

**状態の詳細**（voicedock `status.py` 相当。DB が無ければ全 0。DB を作らない）:
- Part / Session の状態別件数（enum の全値を 0 件も含めて出す。Part の表示順は宣言順だが SKIPPED を FAILED の前に置く）。注記は**エンティティごとの辞書**で持ち、Part の FAILED にだけ「次回接続時に再試行」を付ける
  （Session へ流用しない。voicedock の SKIPPED の「（無音）」は重複・元ファイル不在も含むので写さない）
- 未処理: 非終端 Part の件数と `duration_seconds` の合計（NULL は 0 として足し、件数を併記）。「未処理 <h 小数 1 桁> 時間ぶん（<n> 件）」、NULL があれば「、うち <k> 件は長さ不明」、0 件なら「未処理なし」
- FAILED の一覧: `started_at` 昇順で最大 20 件（partkey と「<yyyy-MM-dd HH:mm>  <error_code か unknown>  retry <n>/<max>」）、超過は「… ほか <n> 件」
- 削除キュー: 要求ファイルの数、結果待ちの Part の数
- staging の使用量（「<x.x> GiB / <上限> GiB」）、inbox の「処理待ち」と「取り残し」を分けた件数とサイズ（#120）
- デバイス: 名前、観測（`デバイス未接続` / `不明` / `読み取り専用` / `読み書き可能`）、空き容量

- 初回起動時だけパネルを自動で開く（`config.json` が無かった起動）
- `NSOpenPanel` などで popover が閉じたら、終わった後に開き直す
- 文言は日本語のみ（v1）。文言は `Strings.swift` に集める
- UI は `@MainActor @Observable final class AppModel` を見るだけ。AppModel は IngestService / Worker / ModelManager から来る値の写しで、UI から DB を直接触らない

### 8.13 voicedock からの乗り換え（v1 では実装しない）

利用者の決定（2026-09-22。F-60）により、voicedock の Vault に載っている録音を `imported_keys` に取り込む処理（`ImportedKeysScanner`）は v1 では作らない。
T-11・T-14 で実装済みの `imported_keys` の表と IngestService の除外（§8.1 の安定性判定の候補から外す）はそのまま残る。書く者がいないので表は常に空で、無害である。
既存ノートを上書きしない規則（§8.8）は乗り換えと関係なく要るので残る。

### 8.14 課金の差し込み口（v1 では実装しない）

- `LicenseGate` プロトコル（`func allowsProcessing() -> Bool`）を VDPipeline に置き、v1 は常に true を返す実装（`AlwaysAllowLicenseGate`）だけを入れる。Worker は tick の先頭で見る
- 将来の実装はオフラインで検証できる署名付きキーにする（**認証サーバとの通信を足さない**。「音声もテキストも外に出ない」を守る）

### 8.15 ライフサイクル・電源・ログ

- **起動**: `<HOME>` と下位ディレクトリを作る（`HomeLayout.createDirectories()`。`bin/` は作らない）→ 設定を読む（無ければ既定を書く）→ DB を開く（マイグレーション）→ Worker.start()（復旧）→ IngestService.start() → UI
- **起動に失敗したとき**（`<HOME>` を作れない・DB を開けない）: `NSAlert` を 1 枚出して終了する（メニューバーに出さない。パネルからは直せないため）
- **終了**: 「終了」→ 新しい工程を始めない → 実行中の子プロセスをプロセスグループごと止める → 最大 10 秒待って終了（`applicationShouldTerminate` で `.terminateLater`）。
  中途の状態は次回起動時の復旧（§5.3）が戻す。`service_stopping`
- **スリープ**: Worker が工程を実行している間だけ `ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .suddenTerminationDisabled], reason:)`。アイドルになったら `endActivity`
- **アイドル時の CPU は 0 に近く保つ**: 常時ポーリングしない。Worker は通知か 30 秒の遅い周期、IngestService は通知か 300 秒
- **ログ**（`VDCore/Log.swift`。voicedock log.py と同じ規則）: `os.Logger`（subsystem = BUNDLE_ID、category = モジュール名）と `<HOME>/logs/app.log`（5 MiB を超えたら `.1` へ rename して 1 世代）
  - 行: `<ts> <LEVEL> <event>` の後に `" k=v"` を渡した順に。`ts` は §5.7 の ISO 文字列。LEVEL は `DEBUG` / `INFO `（空白を補って 5 桁）/ `WARNING` / `ERROR`
  - 値: nil → `null`、Bool → `true` / `false`、整数 → 10 進、浮動小数 → `Double.description`、文字列は `^[\x21-\x7e]+$` に一致し `"` と `=` を含まなければそのまま、それ以外（空白・非 ASCII・空文字列を含む）は PyJSON の文字列表記
  - 予約キー `ts` / `level` / `event` は使えない（型で防ぐ）。値の型は `LogValue`（string / int / double / bool / null）だけ
  - レベル: DEBUG 10 / INFO 20 / WARNING 30 / ERROR 40。`logging.level` 未満は出さない。**イベント名の検証はレベルの絞り込みより先**
  - イベント名は登録制（`LogEvent` enum。付録 A.4）。登録外の名前は書けない（型で強制）
  - **本文を運ぶ値は `<redacted>`**: キーが `text, transcript, summary, content, body, prompt, title, tags, key_points, tasks, decisions, ideas, segments, filename, note_name`（15 個）のどれか、
    またはキーによらず 200 スカラーを超える文字列。例外は `unsafeLogContent == true` **かつ**その行のレベルが DEBUG のときだけ（voicedock と同じ意味。PR-08）。値の引用は「全体が `^[\x21-\x7e]+$` に一致」で判定する（voicedock は Python の `$` の性質で末尾に改行の付いた値を引用せずに出していた。本アプリは必ず引用する）
  - 識別子のキー名は `recording_key` / `session_key`（完全な鍵。短縮しない）。ログに出すパスは日付ベースの固定名と partkey だけ
  - 原則（voicedock §16.4）: 1 工程につき「完了」1 件と「失敗」1 件だけ。開始イベントは出さない（状態遷移は `events` テーブルが持つ）。細かい分岐は名前を増やさず `reason=` / `error_code=` で表す

---

## 9. コーディング規約（全員が同じ品質で書くための規則）

### 9.1 原則（レビューで最初に探す 2 つの欠陥）

voicedock の欠陥はほぼ 2 つの形に収まった。**設計・実装・レビューのたびに、まずこの 2 つを探す。**

1. **「観測していない」を「無い／偽」として書く・表示する。**
   未観測は `Optional` の `nil` のまま持ち、書かないか「不明」として表示する。不明は常に安全側（削除しない・警告する）へ倒す。
   `Bool` で済ませず、観測値は `Bool?` か専用の enum（`.observed(Bool)` / `.unknown`）で持つ
2. **同じ規則を 2 か所に書き、片方だけずれる。**
   規則は定数か関数 1 つに寄せ、書き手と検証側の両方が同じものを使う。**寄せただけでは足りない。**書き手と検証側を、それぞれ単独で落とせるテストで固定する

### 9.2 規則一覧（`R-` ではなく `CR-nn`。強制手段つき）

| # | 規則 | 強制 |
|---|---|---|
| CR-01 | ファイルを書き換えるときは同じディレクトリの `.<name>.tmp` → `fsync` → `rename`。途中で失敗したら tmp を消し、最終ファイルは差し替えない | `AtomicFile`（VDContract）以外で書き込み API を使わない（PT-12） |
| CR-02 | 子プロセスは `ProcessRunner` だけ、引数は配列だけ、シェルを通さない | PT-03 / PT-04 |
| CR-03 | タイムアウトはプロセスグループごと殺す | VDProcess のテスト（孫まで消える） |
| CR-04 | 不明は安全側。例外で落とさず「不明」として扱う | 各所のテスト（壊れた JSON・欠けたキー・読めないファイル） |
| CR-05 | 既定値は「規定の制限」。「無制限」「0 = 無効」を既定にしない（例外は §6.1 の 2 つだけ） | CV のテスト、キー欠落のテスト |
| CR-06 | 定数・集合・問い合わせは 1 か所。状態名・エラーコード名を再掲しない | PT-06、集合の包含テスト |
| CR-07 | 状態を変えるのは `recordPartTransition` / `recordSessionTransition`（と行の作成）だけ | PT-05 |
| CR-08 | 時刻は `AppClock` から毎回取る。キャッシュの TTL は `AppClock.uptime()`（単調時計。壁時計を使わない）。待ちは注入した `Sleeper` | PT-09 |
| CR-09 | 空集合で真になる述語（`allSatisfy` / `contains(where:)` の否定）を安全条件に使うときは、非空を別の項で明示する | ND-21、レビュー項目 |
| CR-10 | 削除（unlink）は `SafeUnlink`（下記のルートごとに realpath で配下を確かめる）、`AtomicFile` の自分の tmp、reaper の `Unlinker`、`DeletionEnabler`（`bin/` の reaper だけ）に限る | PT-01 |
| CR-11 | デバイス上のパスは `DevicePath`（I/O を持たない struct）で表す。デバイス上のファイルを開くのは `DeviceReader`（読み取り専用）と `TargetIdentity` だけ | PT-10 |
| CR-12 | ネットワークは VDModels と `LoopbackHTTP.swift` だけ | PT-02 |
| CR-13 | ログに本文を出さない。イベント名は登録制 | 型、PT-08 |
| CR-14 | 「受理するが効かない設定」を作らない。全キーに振る舞いのテスト | §6.2 `ConfigEffectTests` |
| CR-15 | 待っても変わらない条件で待たない。1 件の失敗で全体を止めない | DEL-15/16、SM-14 |
| CR-16 | 例外で安全経路を表さない。`assert` / `precondition` / `fatalError` / `try!` / `as!` を本番コードで使わない（リリースビルドで消える・プロセスが落ちる）。bool を返す関数に `assert` で始まる名前を付けない | PT-19 |
| CR-17 | 誤検知する検査を置かない（検査が無いより悪い） | 各 PT の「散文・コメント・文字列では落ちない」自己テスト |
| CR-18 | 識別子に短い別名を作らない。ID の接頭辞は体系ごとに一意（§0.5）。廃止した番号は詰めない・再利用しない | PolicyTests（SPEC の表の重複と欠番の再利用を検査） |
| CR-19 | 失敗を黙って通さない。切り詰めたら `analysis_trimmed` のようにログに出す | レビュー項目 |
| CR-20 | 並行性は actor とメッセージで表す。`@unchecked Sendable` と `nonisolated(unsafe)` を使わない | PT-14 |
| CR-21 | 後片付けで元の失敗を隠さない（`defer` 内の失敗は握りつぶしてよいが、元のエラーを上書きしない） | テスト |
| CR-22 | バージョン・URL・action・ランナーは固定 | PT-13 |
| CR-23 | 「N 文字」は Unicode スカラー数で数え、切り詰めもスカラー単位（Python の `len` と同じ）。`String.count` を長さの規則に使わない | レビュー項目、各所の固定テスト（結合文字・絵文字を含む例） |
| CR-24 | Python 互換が要る処理（strip・空白・行分割・casefold・JSON の書き出し・時刻の算術）は `PyText` / `PyJSON` / `Instant`（§5.7）だけを使う | golden、固定テスト |
| CR-25 | 本番のコードパスに「テストなら」分岐を作らない。時計・ルート・ツールのパス・署名検証・URLSession・diskutil・statfs は注入で差し替える | PT-18（環境変数を読まない）、レビュー項目 |

**`SafeUnlink`**（`VDCore/SafeUnlink.swift`。voicedock paths.py:335-421 の強化版）:

```swift
public enum SafeUnlinkRoot: Sendable { case inbox, staging, transcripts, analysis, queueDelete, queueResult, models, run, vaultTmp(vault: URL) }
public enum SafeUnlink {
    static func remove(_ target: URL, under root: SafeUnlinkRoot, layout: HomeLayout, missingOK: Bool = true) throws
    static func removeEmptyDirectory(_ target: URL, under root: SafeUnlinkRoot, layout: HomeLayout) throws   // rmdir。中身があれば何もしない
}
```
- 検査の順: 対象が絶対パスで `..` を含まない → 親ディレクトリの realpath がルートの realpath の**真の配下か同じ**、かつ対象そのものはルートでない
  （root 自身は消させない。接頭辞だけ一致する兄弟 `data-old` は配下ではない）→ 無ければ `missingOK` なら何もしない → `lstat` で symlink なら拒否（リンクも消さない）→ 通常ファイルでなければ拒否 → `unlink`
- `queueDelete` / `queueResult` はそのディレクトリ直下の `*.json` だけ（reaper は `SafeUnlink` を使えないので、同じ規則を `voicedock-reaper/Unlinker.swift` の `removeRequest(named:)` が持つ）。`vaultTmp` は名前が `.` で始まり `.tmp` で終わり長さが 5 より大きいものだけ（Vault 内の symlink 経由のディレクトリは許す。voicedock どおり）
- 拒否は `SafeUnlinkError`（プログラムの誤りであり ErrorCode を持たない）。呼び手が文脈に応じて写す

### 9.3 実装上の禁止事項（PR。voicedock の N を本アプリ向けに引き直した。PolicyTests で検査する）

| # | 禁止 | 由来 |
|---|---|---|
| PR-03 | `<HOME>` と Vault 以外への書き込み（AppKit が自動で書く preferences を除く。UserDefaults を自分で使わない） | N-3/N-4 |
| PR-05 | シェル経由の起動（`/bin/sh -c`、`bash -c`、`system()`、`popen()`） | N-5 |
| PR-06 | コマンド文字列の連結 | N-6 |
| PR-07 | 外部 LLM API へのフォールバック・外部への送信 | N-7 |
| PR-08 | transcript / summary 本文のログ出力（`unsafeLogContent` が false のとき）、llama-server の出力をファイルに残すこと | N-8 |
| PR-09 | 削除要求を `requestDeletions` / `settleSkippedDeletions` / 後追い以外から書くこと | N-9 |
| PR-10 | アプリ本体からデバイス上のファイルを削除すること | N-10 |
| PR-11 | デバイス上のファイルへの書き込み・改名・移動（アプリも reaper も。reaper は unlink だけ） | N-11/N-18 |
| PR-12 | DB の状態だけを根拠にした削除判断 | N-12 |
| PR-13 | 127.0.0.1 以外で待ち受けること | N-13 |
| PR-14 | openat 連鎖か realpath 後の封じ込め確認をせずに削除すること | N-14 |
| PR-15 | LLM に `[[ ]]` を作らせること | N-15 |
| PR-16 | reaper 以外がデバイス上のファイルを削除すること。reaper がディレクトリを削除すること | N-16 |
| PR-17 | 削除要求に絶対パス・`..`・`.` 始まりの要素を書くこと | N-17 |
| PR-19 | reaper が子プロセスを起動すること（diskutil を含む） | N-19 |
| PR-20 | バンドル内の reaper を実行すること、有効化フロー以外から `bin/` に書くこと | 本計画（D-5） |

（N-1 / N-2 は Docker 固有のため廃止。N-18 は PR-11 に統合。番号は詰めない）

### 9.4 静的ポリシーテスト（PT。`Tests/PolicyTests`）

ソースを読む簡易字句解析器（`SourceScanner`）を作り、**コメントと文字列リテラルの中身を空白に置き換えたコード**（行番号を保つ。文字列補間 `\( … )` の中身はコードとして残す）と、
**文字列リテラルの中身の一覧**（行番号付き）の 2 通りの見え方を提供する（voicedock の教訓: 文字列検索は散文や説明コメントに引っかかる。TEST-09 / TEST-26）。
扱う字句: `//` 行コメント、入れ子の `/* */`、`"…"`（エスケープと補間。補間の中の文字列・括弧の入れ子を含む）、`"""` 複数行、`#"…"#`（`#` の数は任意）の raw 文字列。
**照合はトークン単位**: コード側の語は識別子として完全一致させる（前後が識別子の文字 `[A-Za-z0-9_]` でない）。`name(` の形の語は「直前が `.` でない（自由関数の呼び出し）か、`Darwin.` / `Foundation.` / `Glibc.` で修飾されている」ものだけを対象にする（`SafeUnlink.remove(` や `Set.remove(` は PT-01 の `remove(` に当たらない。`ProcessedLog` は PT-15 の `Process` に、`reaperConfSchema` は PT-11 の `reaperConf` に、`.recoveryCompleted` は PT-21 の `.recovery` に当たらない）。メンバーとして書く語（`removeItem`・`trashItem`・`.write(to:` など）は修飾に関係なく対象にする
swift-syntax は使わない（CI のビルド時間が増えるため）。対象は `Sources/` 配下の全 `.swift`（`Tests/` は対象外。PT ごとに断りがあるものを除く）。

| # | 検査（コード側で探すもの / 文字列側で探すもの） | 許可する場所 |
|---|---|---|
| PT-01 | コード: `removeItem`、`trashItem`、`unlink(`、`unlinkat(`、`rmdir(`、`remove(`、`removefile(`（`Darwin.` などで修飾されていても同じ） | `VDCore/SafeUnlink.swift`、`VDContract/AtomicFile.swift`、`voicedock-reaper/Unlinker.swift`、`VDPipeline/DeletionEnabler.swift` |
| PT-02 | コード: `URLSession`、`import Network`、`CFNetwork`、`NWConnection`、`CFSocket`、`socket(`（`LoopbackHTTP.swift` の空きポート取得を除く） | `VDModels/`、`VDLLM/LoopbackHTTP.swift`（URL を `LoopbackEndpoint` 以外から作らない: `URL(string:` を含まない） |
| PT-03 | コード: `posix_spawn`、`posix_spawnp`、`Process(`、`NSTask`、`fork(`、`vfork(`、`execv`、`execve(`、`execvp(`、`execl` | `VDProcess/` |
| PT-04 | 文字列: `/bin/sh`、`/bin/bash`、`/bin/zsh`、`/usr/bin/env`。コード: `system(`、`popen(`（`"-c"` 単独は検出しない。llama-server は長い形のフラグを使う） | どこにも無い |
| PT-05 | 文字列: 大小を無視して `UPDATE` と `SET` と語 `status` を同じリテラルに含むもの、`INSERT INTO recordings`、`INSERT INTO sessions`。コード: `PersistableRecord`、`MutablePersistableRecord` | 文字列の 3 つは `VDStore/Transitions.swift`。コードの 2 つはどこにも無い |
| PT-06 | 文字列: 状態名（Part と Session の全 rawValue）かエラーコード名（全 rawValue）を語として含むもの（**大文字小文字を区別する**。区別しないとログイベントの `disk_space_low` などに当たる。語の一覧は SPEC.md から読み、空なら違反）。文字列: `\(…)/\(…)` の形（補間の中の括弧の入れ子 `\(key(for: p))/\(r)` と raw 文字列の `\#(…)/\#(…)` も含む。partkey・relpath の手組み。relpath の結合は `RelPath.join(_:)` だけで行う） | 状態名は `VDCore/States.swift`、エラーコード名は `VDCore/ErrorCode.swift`（例外: 結果の status 値 `SOURCE_IDENTITY_MISMATCH` を持つ `VDContract/DeleteResult.swift`）、手組みは `VDContract/PartKey.swift` と `VDContract/RelPath.swift` |
| PT-07 | `Sources/` の各モジュールの `import` が §3.4 の許可リストに収まる（`Tests/` は対象外） | — |
| PT-08 | コード: `Logger(`、`os_log(`、`NSLog(`、`print(`、`debugPrint(`、`dump(`（`Swift.` で修飾した呼び出しも含む） | `VDCore/Log.swift`、`voicedock-reaper/ReaperLog.swift`、`voicedock-reaper/main.swift`（`--version` の出力だけ） |
| PT-09 | コード: `Date()`、`Date.now`、`Date(timeIntervalSinceNow:`、`CFAbsoluteTimeGetCurrent(`、`DispatchTime.now(`、`ContinuousClock()`、`SuspendingClock()`、`ContinuousClock.now`、`SuspendingClock.now`、`gettimeofday(`、`clock_gettime(`、`time(nil)` | `VDCore/Clock.swift`（`SystemClock`）、`voicedock-reaper/ReaperClock.swift` |
| PT-10 | (a) `VDDevice/` の中で `open(`、`openat(`、`opendir(`、`fopen(`、`FileHandle(`、`Data(contentsOf:`、`InputStream(` を使ってよいのは `DeviceReader.swift` と `InboxWriter.swift` だけ。(b) `VDDevice/DeviceReader.swift` と `VDContract/TargetIdentity.swift` に `O_WRONLY`・`O_RDWR`・`O_CREAT`・`O_TRUNC`・`O_APPEND`・`forWriting`・`forUpdating` が無い | 左記 |
| PT-11 | コード: `bundledReaperURL` は `VDCore/AppPaths.swift` と `VDPipeline/DeletionEnabler.swift` だけ。`binDirectory` は `VDContract/HomeLayout.swift` と `DeletionEnabler.swift` だけ。`reaperExecutable` / `reaperConf` は `HomeLayout.swift`・`DeletionEnabler.swift`・`VDPipeline/ReaperRunner.swift`・`VDPipeline/LockEvaluator.swift`・`voicedock-reaper/` だけ（ConfigStore は `LockEvaluator.observeReaperConf()` で読む。reaper.conf を**書く**のは DeletionEnabler だけ） | 左記 |
| PT-12 | コード: `.write(to:`、`write(toFile:`、`createFile(`、`FileHandle(forWriting…`（`forWritingTo:`・`forWritingAtPath:`）、`FileHandle(forUpdating…`、`copyItem(`、`moveItem(`、`replaceItem`、`rename(`、`renameat(`、`O_CREAT` | `VDContract/AtomicFile.swift`、`VDContract/FileLock.swift`（ロックファイルを作る）、`VDCore/LogFile.swift`、`VDDevice/InboxWriter.swift`、`VDModels/ModelDownloader.swift`、`VDModels/ModelImporter.swift`、`VDAudio/Normalizer.swift`、`voicedock-reaper/ProcessedLog.swift`、`voicedock-reaper/ReaperLog.swift`、`voicedock-reaper/QueueFiles.swift`、`VDPipeline/DeletionEnabler.swift`（reaper の複製） |
| PT-13 | `Package.swift` の依存が `exact:`、`Package.resolved` がコミットされている、`Vendor/versions.env` の REF がタグで SHA が 40 桁、`ModelCatalog.json` の URL が `https://huggingface.co/…/resolve/<40hex>/…`、ci.yml の `uses:` が 40 桁 SHA、`runs-on:` に `latest` を含まない、`.xcode-version` が 1 行 | — |
| PT-14 | コード: `@unchecked Sendable`、`nonisolated(unsafe)` | どこにも無い |
| PT-15 | `voicedock-reaper/` のコードに `Process`、`posix_spawn`、`URLSession`、`removeItem`、`import VDCore`（VDContract 以外の VD モジュール）が無い。文字列に `diskutil` が無い | — |
| PT-16 | 「本体が先、記録が後」: `VDDevice/IngestService.swift` の `func copyOne(` の本体で、`commitPartial(` の呼び出しが `registerCopied(` より前にある（DEV-16） | — |
| PT-17 | `VDPipeline/Diagnostics/` のコードに PT-01 と PT-12 の API、`AtomicFile`、`Store(`（書き込みのできる Store の初期化。`ReadOnlyStore.open(` は可）が無い（OPS-14。診断は何も書き換えない） | — |
| PT-18 | コード: `ProcessInfo.processInfo.environment`、`getenv(`、`setenv(` | どこにも無い（テストの有効化は `Tests/` の中だけで読む） |
| PT-19 | コード: `precondition(`、`preconditionFailure(`、`assert(`、`assertionFailure(`、`fatalError(`（`Swift.` で修飾した呼び出しも含む）、`try!`、`as!` | どこにも無い（CR-16） |
| PT-20 | コード: `Regex<`、`Regex(`、語 `Regex`（型注釈 `: Regex` も）、`firstMatch(of:`、`wholeMatch(of:`、`prefixMatch(of:`（スラッシュの正規表現リテラル `/…/` を渡す呼び出し）、`#/`（Swift の Regex。正規表現は `NSRegularExpression` の文字列定数で持つ。§4.1） | どこにも無い |
| PT-21 | コード: `.recovery`（`TransitionKind`） | `VDCore/States.swift`（定義と表）、`VDStore/Transitions.swift`、`VDPipeline/Recovery.swift` |
| PT-22 | コード: `VolumeHandle(`（初期化子の呼び出し） | `VDContract/TargetIdentity.swift`（本番のコードは `openVolume` 経由でしか `VolumeHandle` を作らない。テストは対象外） |

- PT の語の一部（状態名・エラーコード名など）は `docs/SPEC.md` から読む。**SPEC.md が無ければ PT も含めて落ちる**（skip にしない）
- 既知の限界: PT-06 は `a + "/" + b` のような連結による partkey の手組みは検出しない（レビュー項目で補う）
- 既知の限界（未対応）: PT-03 は `execv` などの関数参照（呼び出しでない形）を検出しない。PT-09・PT-17・PT-22 は暗黙メンバーの `.init(`・`.now`（`let d: Date = .now` など）を検出しない（レビュー項目で補う）

**各 PT には 2 本の自己テストを付ける**: 違反を 1 つ仕込んだ一時ソースで PT が**落ちる**こと（検査が空振りしていないことの証明）と、禁止語をコメント・文字列（PT-04〜06 はコード）に書いた一時ソースで**落ちない**こと（CR-17）。
`SourceScanner` 自体にも、字句ごとの固定テストを置く。

---

## 10. テスト戦略

### 10.1 枠組み

- **Swift Testing**（`import Testing`、`@Test`、`#expect`、パラメータ化テスト）。XCTest は使わない
- **`swift test` はタグで絞り込めない**（Xcode 27.0 で確認。`--filter tag:` / `--skip tag:` は効かない）。そのため次の 3 種は**環境変数と `.enabled(if:)` で有効化**する（タグも付けて意味を示す）:
  - `.diskImage`（hdiutil で FAT32 イメージを作る）: `VOICEDOCK_DISK_TESTS=1` のときだけ
  - `.realTools`（本物の whisper-cli / llama-server とモデルが要る。ローカルのみ）: `VOICEDOCK_REAL_TOOLS=1` のときだけ
  - `LLMAcceptance` のテスト: `VOICEDOCK_LLM_MODEL=<id>` のときだけ
  - 環境変数は `Tests/TestSupport/TestEnvironment.swift` だけが読む（本番コードは読まない。PT-18）
- **ネットワークの遮断**: 実際の防壁は PT-02（URLSession を使えるのは VDModels と `LoopbackHTTP.swift` だけ）。加えて、両者は `URLSessionConfiguration` を**注入されたファクトリ**から作るので、
  テストでは `protocolClasses = [BlockingURLProtocol.self]`（ループバック以外への要求を失敗させる）を設定したファクトリを渡す（TEST-12。URLProtocol の登録は注入したセッションにしか効かないため、
  「全スイートに付けるトレイト」では遮断を保証できない）
- 時計・ファイルシステムのルート（`HomeLayout`・`/Volumes` の代わり）・ツールのパス（`AppPaths`）・署名検証・`MountInspector`・`Remounter`・`Sleeper` は**すべて注入**する。本番のコードパスで「テストなら」分岐を作らない（CR-25）
- 差し替えはテスト 1 本の範囲に閉じる（差し替えが最後の検証まで汚した事故。TEST-18）
- 並行実行: Swift Testing は既定で並行に走る。一時ディレクトリはテストごとに作る。ディスクイメージ・プロセスグループ・ポートを扱うスイートは `.serialized` にする
- テストの表示名: ND・RV・CV・DR・SN・RN・DN・PT・E2E に対応するテストは表示名をその ID で始める（例 `@Test("ND-18 削除直前にサイズが変わると size_mismatch")`）。SPEC 同期がこれを集める（§10.3）

### 10.2 偽物（`Tests/TestSupport`）

| 偽物 | 中身 | 由来 |
|---|---|---|
| `FakeWhisper` | 一時ディレクトリに作る実行可能スクリプト（`#!/bin/sh`）。最初に受け取った argv を 1 行ずつ `<script>.argv` に記録。`--help` / `-h` なら help 文（VAD の 6 フラグあり / なし）を出して 0。`-of` の次の引数を base とし、`<base>.json` に **whisper.cpp v1.9.4 の `-oj` と同じ形**（`offsets` はミリ秒、`timestamps` も持つ、1 行の JSON）を書く。終了コード・stderr・sleep・孫プロセス生成・JSON を書かない・壊れた JSON を選べる | voicedock `tests/fixtures/fake_whisper.py` |
| `FakeChatTransport` | `ChatTransport` の実装。応答の列を返す。HTTP エラー・接続失敗・壊れた JSON・`<think>` 付き・フェンス付き・外形の壊れた応答を返せる。受け取った system / user を記録する | voicedock `tests/fixtures/llm_responses/` |
| `BWFWriter` | 実機と同じ Broadcast Wave（48 kHz / 24 bit・32 bit float・16 bit / mono、fmt 16（cbSize 無し）・bext 602（0 埋め）・iXML 1092（`<BWFXML></BWFXML>` を空白で右詰め）・cue 28・PAD 30978、data は offset 32776。奇数長は 1 バイトのパッド）を生成。無音・発話（0.8 秒鳴らし 0.4 秒休む `0.1 × (sin θ + 0.5 sin 2θ + 0.25 sin 4θ)`、θ = 2π × 220 × t）・指定長。44 バイトの最小ヘッダも作れる | voicedock `tests/fixtures/make_wav.py`（ASR-15） |
| `FakeVolume` | 一時ディレクトリに DJI と同じ木（`TX_MIC001_YYYYMMDD_HHMMSS/TX00_MIC00N_…_orig.wav`、denoised、`._*`、`.Spotlight-V100`、`.Trashes`、symlink、深い階層）を作る。原本の mtime はコピー時刻の 4 時間 34 分前 | `fake_tree.py` |
| `FakeMountInspector` / `FakeRemounter` | `MountInspector` / `Remounter` の差し替え（マウント点・`MNT_RDONLY`・再マウントの成否・パスの変化を表で与える） | — |
| `DiskImageVolume` | `hdiutil create -size 64m -fs "MS-DOS FAT32" -volname <一意の名前 VDTxxxx> <tmp>/img.dmg` → `hdiutil attach -nobrowse -mountpoint <tmp>/Volumes/<同じ名前>`（**実機と同じ `DJIMIC3` を名前に使わない。`/Volumes` の下に attach しない**）。読み取り専用での再マウント・statfs・reaper の unlink を**本物の FAT で**確かめる（`.diskImage`）。後片付けは `hdiutil detach -force` | POC の `mkimg.sh` |
| `FixedClock` / `SteppingClock` / `RecordingSleeper` | 時計と待ち（待った秒数を記録し、実際には待たない） | |
| `FakeSignatureVerifier` | reaper の署名検証の差し替え | |
| `ReaperBinary` | テストから reaper の実行ファイルを見つける: ReaperTests は `voicedock-reaper` ターゲットに依存し（`swift build --build-tests` で必ずビルドされる）、テストバンドル（`.xctest`）と同じディレクトリの `voicedock-reaper` を使う。見つからなければ skip ではなく fail | — |

**偽物そのものもテストする**（fixture が実機と違う形だったため欠陥が隠れた。TEST-05）: BWFWriter の出力のチャンク構成とオフセット、FakeWhisper の JSON の形、FakeVolume の木。
**fixture は実機どおりにする**: 例えば `source_mtime` は inbox のコピーの時刻ではなく、4.5 時間ずれた原本の時刻を入れる（DEL-12）。
reaper は偽物を作らず本物を起動する。本物は「結果を書いた直後に要求を消す」（DEL-09）。

### 10.3 テストの種類

| 種類 | 何を | 例 |
|---|---|---|
| 単体 | 純粋な規則 | 鍵の固定値、名前規則、分組、Block、チャンク分割、スキーマ生成、JSON 取り出し、sanitize、frontmatter、状態遷移、CV、PyText / PyJSON |
| golden | voicedock とのバイト一致 | Raw / Daily ノート、schema_block、プロンプト描画、sanitize、チャンク境界、指紋、内部 JSON（§10.4） |
| 結合 | 工程をまたぐ往復 | inbox → 変換（本物の AVFoundation）→ 偽 whisper → Raw → 統合 → 偽 LLM → Daily → 保存検証 → 削除要求 → 本物の reaper（`.diskImage`）→ 回収 |
| Worker | **`Worker.tick()` を回す**（`ensure*` を直接呼ぶだけでは配線の欠落が見えない。TEST-06 / TEST-07） | tick の順序、再評価の 4 つの契機、停止、ガード |
| ND | 削除禁止（付録 B.1） | NoDeleteTests / ReaperTests |
| PT | 静的検査（§9.4） | PolicyTests |
| SPEC 同期 | `docs/SPEC.md` の表 ↔ 実装の enum・定数・テストの表示名 | 状態・遷移・復旧写像・エラーコード（宣言順）・CV・ND・RV・DR・ログイベント（登録順）・理由語（付録 B.2）・名前の正規表現・whisper-cli の argv・RN / DN・tick の段・パネルの節と画面・アイコン・はじめに・ui-state.json（S10〜S13・S20〜S23。F-68） |
| 文書 | README / E2E.md の件数・手順・番号 | 「診断は 16 件」などの散文の数字も機械で見る（voicedock で古くなった箇所が多数あった） |
| 実機 | E2E（付録 B.3） | docs/E2E.md に手順・生の出力・判定 |

**SPEC 同期の読み方**（voicedock `tests/spec_sync.py` と同じ規則）:
- 節は、見出し行 `^#{1,6} ` の本文が指定の語で始まる最初の行から、次の `^#{1,6} (?:[0-9A-Z]|付録)` の行まで。**コードフェンスの中の行は見出しとして扱わない**（`# 2026-…` で節が切れた事故 #13）
- 表の行の ID は `^\| \*{0,2}(<接頭辞>-[0-9]+)\*{0,2} \|`。本文が `~~` で始まる行は廃止として除く
- 状態は付録 A.1 の 2 つの表（見出しの列が「Part の状態」「Session の状態」）から、エラーコードは付録 A.3 の表から、`^\| [0-9]+ \| \`([A-Z_]+)\`` を出現順に読む（宣言順と一致すること）
- 遷移表と復旧写像は `text` フェンスの中の `A→B` を辺として読む（`|` 区切り、`★` と括弧の注記は無視）。付録 A.2 はフェンスの直前の段落 `Part:` / `Session:` でエンティティを分け、付録 A.1 の復旧写像のフェンスは行頭の `Part:` / `Session:` で分ける
- ログイベントは付録 A.4 の `text` フェンスを空白と改行で分け、出現順 = `LogEvent` の宣言順
- `docs/SPEC.md` が無ければ **skip ではなく fail**
- S10〜S13・S20〜S23（F-68）は PLAN の該当節の表（S11 だけは §8.4 の最初の `text` フェンス）を 1 つずつ写したもの。照合のテストは実装の型を import できる各モジュールのテストターゲットに置き（PolicyTests は TestSupport にしか依存しない）、`SpecDocument` の読み取り口で SPEC を読む。理由語は付録 B.2 の「理由語」の列のバッククォートの語を出現順に読み、`IdentityReason.all` と一致すること
- RN / DN は S12 の表の「#」に RN- / DN- を付けた ID（— の欄は無い）の集合と、テストの表示名の先頭の ID（`RN-5 / DN-6 …` のように ` / ` で並べてよい）の集合が一致すること
- ND・RV・CV・DR は「SPEC の表の ID の集合」と「テストの表示名の先頭の ID の集合」が一致すること。ND は付録 B.1 の「層」の列に書いた層（A / R1 / R2 / R3）ごとに 1 本以上のテストがあること（テストの表示名は `ND-18 [R2] …` のように ID の後に層を角括弧で書く）。DR の表は ID が先頭の列

**不変条件は列挙全体に対して書く**: 例「戻りうる全状態に受け手がいる」「deletableSkipReasons の全理由に根拠の分岐がある」「全エラーコードに RetryPolicy がある」（TEST-08）。
**空の状態を必ずテストする**: 0 台、0 件、0 セグメント、空の Vault（TEST-28 / DEV-19）。
**件数を直書きしない**: 件数は SPEC の表から読む。parametrize の元を検証対象そのものにしない（空にすると 0 件で緑になる。TEST-01）。
**弾かせたい条件以外はすべて満たしておく**（どの理由で弾かれたか分からないテストを書かない。TEST-19）。

### 10.4 golden（voicedock とのバイト一致）

- `tools/golden/generate.sh`: `git -C /Users/terada/Projects/voicedock archive d3d595e | tar -x -C <一時ディレクトリ>` → その中で `uv sync --frozen --python 3.12` →
  `uv run --frozen python <repo>/tools/golden/generate.py <repo>/Tests/Golden`。**voicedock の作業ツリーを触らない**。
  ホストの `uv` を使う（Docker 不要。v1.1 で変更）。`uv --version` と Python の版（3.12.x、unicodedata 15.0.0）を `Tests/Golden/GENERATED_BY.txt` に書き、テストはこのファイルが在ることを確かめる
- `generate.py` は入力の fixture（`Tests/Golden/inputs/*.json`: Part の一覧、transcript、解析結果、Vault 索引、設定の上書き）を読み、voicedock の関数（`notes.sanitize_filename`・`render_frontmatter`・
  `raw.render_raw_note`・`daily.render_daily_note`・`daily.build_timeline`・`wiki.plan_links`・`session.transcript_fingerprint`・`session.compute_blocks`・`llm` の schema_block / プロンプト描画 / チャンク分割 / 重複除去など）で出力を作って
  `Tests/Golden/expected/<名前>.<拡張子>` に書く。入力の時刻は「タイムゾーン名 + オフセット付き ISO 8601」で持つ
- 対象（最低限）: Raw ノート（1 Part / 複数 Part / 5 分見出し / 見出し無効 / 終了時刻不明 / 本文の無い Part / 空）、Daily ノート（単一パス / Map-Reduce / FAILED と SKIPPED の警告の組み合わせ全種 / タグの正規化 / リンク有無 / 空セクション / 最小形）、
  frontmatter の特殊文字（`"` `\` 制御文字 C0・C1 `:` `#`、空配列）、sanitize（SN-1〜9 の各規則、180 バイト境界の結合文字、予約名）、schema_block（既定・中間形・セクション無効化）、
  プロンプトの描画（custom_instructions の空と非空、修復）、チャンク分割の境界（文字数で切れる / 実時間で切れる / 両方 / 重なり）、Block、重複除去（`Straße`・`ΣΑΣ`・全角・`\x1c`）、
  正規化 transcript・analysis・timeline・source の JSON、指紋、key_slug・partkey・session_key、Timeline の文分割
- Swift 側のテストは同じ入力から出力を作り、**バイト列で比較**する。差分があれば unified diff を表示する
- golden を作り直すのは「意図して出力を変える」ときだけ。PR 本文に理由を書く。本計画の差分（§8.6 の Sources のリンク先など）は、**その場合だけ期待値を上書きする入力を別に用意**し、差分であることをテスト名に書く

### 10.5 ND（削除禁止）の書き方

- **三重ロックを全部外した状態**で、故障を 1 つだけ注入して「消えない」ことを確かめる（ロックが掛かっていて消えないのは何も試していない。TEST-04）
- **正の対照**: 同じ準備で故障を入れなければ**実際に消える**テストを必ず並べる（アプリ層 `deletionActuallyHappensWhenEverythingIsValid`、reaper 層 `aValidRequestActuallyDeletes`）。
  これが無いと「緑なのは安全だからではなく、何も動いていないから」を見逃す（TEST-03）
- 防御が多重なので、**層ごとに独立して観測できる結果**を探して別のテストに分ける（片方の層を消しても別の層が受け止めて緑になる。TEST-17）
- **reaper 層の置き場所（v1.1 で修正）:** RV-06 は「マウント点かつ `msdos`」を要求するので、普通のディレクトリをボリュームにしたベンチでは全要求が RV-06 で弾かれ、RV-08 以降と正の対照が空振りで緑になる（TEST-19 違反）。そこで 3 層に分ける:
  1. **reaper 実行ファイル × 普通のディレクトリ**（CI で常に回る）: RV-00〜RV-06 の拒否（置き場所・conf・lock1・ファイル名・JSON の形・リプレイ・partkey 不一致・マウント点でない・device_absent）。ND-22（R）・27・38・39（マウント点でない）・40・43・44
  2. **`TargetIdentity` の単体テスト × FakeVolume**（CI で常に回る。プロセス内）: RV-08〜RV-12 の各理由語。ND-18〜20・24・25・28・29・37。ボリュームのハンドルは `VolumeHandle` の internal な初期化子を `@testable import VDContract` で作る（本番のコードはこれを呼ばない。PT-22）
  3. **reaper 実行ファイル × `DiskImageVolume`**（`.diskImage`）: 正の対照 `aValidRequestActuallyDeletes`、ND-18〜20・23〜25・28・29・31・37・39（unexpected_fs。HFS+ のイメージ）、RV-07（ro で再マウントしたイメージ）、RV-13、FAT の特性（mtime の 2 秒分解能）
- reaper 層は**ビルドした reaper の実行ファイルを実際に起動**する（`ReaperBinary`。§10.2）
- アプリ層の ND は `FakeMountInspector` で観測を与え、事前確認のボリュームは `FakeVolumeOpener`（普通のディレクトリを包む。§4.6）で開く（正の対照 `deletionActuallyHappensWhenEverythingIsValid` はアプリ層の要求ファイルが書かれ、遷移が起きることまでを確かめる。
  実際の unlink までの往復は結合テスト（`.diskImage`）で確かめる）

### 10.6 LLM の受け入れ試験（モデルを一覧に載せる条件。`.realTools`、ローカル）

`Tests/LLMAcceptance/`（`VOICEDOCK_LLM_MODEL` が無ければ全部無効。`make llm-acceptance MODEL=<id>`）:
1. 10 セッション分の transcript fixture をすべて ANALYZED にできる。**fixture は T-24 で作る**（voicedock には LLM 応答の fixture が 2 本あるだけで、transcript の fixture は無い）:
   合成した日本語の会話 9 本（5,000〜60,000 文字）＋長文 1 本（約 350,000 文字）。利用者の実録音から作る場合はリポジトリに入れず `~/VoiceDockAcceptance/` に置き、パスを環境変数で渡す
2. 修復なしで検証を通る割合 ≥ 90%、修復込みで 100%
3. 出力に `[[` が無い、期限の無い task の due が null
4. 350,000 文字の Map-Reduce が**参照機で 30 分以内**（voicedock Phase 3 の基準）
5. 結果（割合・時間・機種・モデルの sha256）を docs/POC.md に貼る

### 10.7 破壊による証明（PR ごと）

実装を**1 回に 1 か所だけ**壊し、対応するテストが落ちることを確かめ、**落ちたテスト名を PR 本文に貼る**（voicedock §20.6）。
- 壊す前に、そのファイルに未コミットの変更が無いこと（`git diff --quiet -- <file>` が真）を確かめる（先にコミットしておく）
- 壊したことを `git diff --quiet -- <file>` が偽になることで毎回確かめる（置換の空振りを防ぐ）
- 戻すのは `git checkout -- <そのファイル>` だけ（範囲の広い checkout で未コミットの作業を消した事故がある）
- 「壊したのに通った」を放置しない。多重防御なら層を分けたテストを足し、空振りならテストを直す

### 10.8 CI（GitHub Actions、開発機のセルフホストランナー、非公開リポジトリ）

分数を節約するため **job は 1 つ**にし、ステップ名で見分ける（voicedock は ND を別 job にしていたが、macOS は分数が 10 倍）。ND と Policy は最後のステップで**もう一度走らせない**。

```yaml
name: ci
on:
  push: { branches: [main, develop] }
  pull_request: { branches: [main, develop, "feat/**"] }
concurrency: { group: "ci-${{ github.ref }}", cancel-in-progress: true }
permissions: { contents: read }
jobs:
  check:
    runs-on: [self-hosted, macOS, ARM64]   # 開発機のセルフホストランナー（Xcode 27.0）。利用者の決定（T-02）
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1   # v7.0.1
      - run: make check-toolchain
      - uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9      # v6.1.0。.build を Package.resolved と .xcode-version のハッシュで
        with:
          path: .build
          key: spm-${{ runner.os }}-${{ hashFiles('Package.resolved', '.xcode-version') }}
      - name: lint
        run: make lint
      - name: build
        run: swift build --build-tests
      - name: ND（削除禁止。最初に走らせる）
        run: swift test --skip-build --filter "NoDeleteTests|ReaperTests"
      - name: policy + spec sync
        run: swift test --skip-build --filter PolicyTests
      - name: other tests
        run: swift test --skip-build --skip "NoDeleteTests|ReaperTests|PolicyTests|LLMAcceptance"
```

- 警告はエラー: `-Xswiftc -warnings-as-errors` ではなく、`Package.swift` の自分のターゲットに `swiftSettings: [.treatAllWarnings(as: .error)]`（SE-0480、tools-version 6.2 以上。リモートの依存には掛からない）
- ランナー: 開発機（実機 DJI Mic 3 がつながることがある Mac）のセルフホストランナー。ラベルは既定の `self-hosted`・`macOS`・`ARM64` で固定し、`runs-on` に `latest` を使わない（PT-13）。
  CI では `sudo` を使わず、Xcode の版は `make check-toolchain` で確かめるだけにする（`.xcode-version` と開発機の Xcode を利用者がそろえる）
- `main` のブランチ保護で `check` を必須にする（**非公開リポジトリで GitHub の無料プランだとブランチ保護が使えない**（API が 403）。その場合は T-02 に記録し、「保護した」とは書かない）
- `.diskImage` のテストは **CI で走らせない**（`VOICEDOCK_DISK_TESTS` を付けない）。ランナーが開発機なので、CI が走るたびに実機が抜いてあることを保証できないため（P0-10 は行わない）。
  CI の ND は層 1・2 だけになることを README に書き、**削除に触れる PR では、実機を抜いたことを利用者が確かめてから手元で `make test-disk` を回した結果を PR 本文に貼る**ことを必須にする
- `.app` の組み立て・署名・公証は CI で行わない（手元の `make release`。証明書を CI に置かない）

---

## 11. ビルド・署名・公証・配布

### 11.1 `.app` の組み立て（`scripts/make-app.sh <debug|release>`）

```text
VoiceDock.app/Contents/
├── Info.plist          # Resources/Info.plist.template から生成（版は VERSION、ビルド番号は git のコミット数）
├── MacOS/VoiceDock     # swift build -c release --arch arm64 --product VoiceDockApp（debug は -c debug）
├── Helpers/whisper-cli, llama-server, voicedock-reaper    # voicedock-reaper も swift build --product voicedock-reaper
└── Resources/prompts/*, ModelCatalog.json, AppIcon.icns
```

Info.plist の必須キー: `CFBundleIdentifier`、`CFBundleName = VoiceDock`、`CFBundleExecutable = VoiceDock`、`CFBundlePackageType = APPL`、`CFBundleIconFile = AppIcon`、`CFBundleDevelopmentRegion = ja`、`CFBundleShortVersionString`、`CFBundleVersion`、
`LSMinimumSystemVersion = 15.0`、`LSUIElement = YES`、
`NSRemovableVolumesUsageDescription`（「録音デバイスから音声を読み込むために使います」）、`NSDocumentsFolderUsageDescription` / `NSDesktopFolderUsageDescription` /
`NSDownloadsFolderUsageDescription`（「Obsidian の保管庫がこのフォルダにある場合に、ノートを書き込むために使います」）。
この 2 種の説明文は README にも逐語で載せ、文書テストが Info.plist と README の一致を照合する。

- アプリは資源とヘルパーを `AppPaths`（`Bundle.main.bundleURL` から `Contents/Resources` と `Contents/Helpers` を組み立てる）で得る。SwiftPM の `Bundle.module` は使わない（§3.4）

**開発中も Apple Development 証明書で署名する。**ad-hoc 署名だとビルドのたびに署名が変わり、TCC の許可（リムーバブルボリューム・書類フォルダ）が毎回失効する（DR-17 が警告する）。

### 11.2 外部バイナリ（`Vendor/build-*.sh`）

```bash
# Vendor/versions.env（例）
WHISPER_CPP_REF=v1.9.4
WHISPER_CPP_SHA=927cfce34f31707e17f2bff35c349632fb9e2c3a
LLAMA_CPP_REF=b11033
LLAMA_CPP_SHA=8ed1a55efcd7424d2c592f6cbc9f97756db1d74d

# whisper.cpp（voicedock と同じ版）
cmake -S src -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_NATIVE=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_BUILD_EXAMPLES=ON \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
cmake --build build --config Release --target whisper-cli -j        # → build/bin/whisper-cli
# llama.cpp <LLAMA_CPP_REF>
cmake -S src -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_NATIVE=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_USE_PREBUILT_UI=OFF -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=ON \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
cmake --build build --config Release --target llama-server -j       # → build/bin/llama-server
```

- ソースは `git clone --depth 1 --branch <REF>` の後、**`git rev-parse HEAD` を `versions.env` の SHA と照合**してからビルドする（注釈付きタグは `^{commit}` で剥がした値を記録する）
- 成果物は `Vendor/build/bin/` に置き、コミットしない。`whisper-cli --help` と `llama-server --help` の出力を `Tests/Fixtures/` にコミットする（引数の照合テスト用。版を上げる PR で更新）
- `GGML_NATIVE=OFF`: ビルドした Mac の CPU 専用命令を使わない（M1 で動かなくなるのを防ぐ）
- `LLAMA_CURL` は b11033 で廃止済み（指定しても無視される）。ダウンロード能力は `LLAMA_OPENSSL=OFF`（HTTPS を無くす）と実行時の `--offline` で断つ。`LLAMA_USE_PREBUILT_UI=OFF` はビルド中に HF から UI を落とさないため
- **whisper.cpp のリリース・llama.cpp の配布バイナリは使わない**（dylib 構成で ad-hoc 署名のため。ソースから静的にビルドする）
- `otool -L` の出力が `/usr/lib/` と `/System/Library/` だけであること（libssl・libcurl・`@rpath` を含まない）を `verify-bundle.sh` が確かめる（静的リンクの確認）

### 11.3 署名・公証・dmg（`make release`。手元の Mac で実行）

1. すべての Mach-O を**内側から**署名: `codesign --force --options runtime --timestamp --sign "Developer ID Application: … (<TEAM_ID>)"`
   - reaper は `--identifier <BUNDLE_ID>.reaper` と `reaper.entitlements`（空）。**アプリ本体にも `--identifier <BUNDLE_ID>` を明示する**（`CFBundleIdentifier` と署名の識別子の食い違いに気づけるように）
   - アプリ本体は `VoiceDock.entitlements`（Hardened Runtime のみ。サンドボックスなし。追加の例外エンタイトルメントなし）
2. `.app` を `ditto -c -k --keepParent` で zip → `xcrun notarytool submit --keychain-profile VOICEDOCK_NOTARY --wait` → `xcrun stapler staple VoiceDock.app`
3. dmg: `hdiutil create -size <余裕を足した大きさ> -fs HFS+ -volname VoiceDock -layout NONE <作業用>.dmg`（`-srcfolder` は使わない） → `hdiutil attach -nobrowse -mountpoint <dist/ の中の一時ディレクトリ>`（**/Volumes の外にだけマウントする**。マウント先が指定どおりかを確かめ、違えば即座に detach） → `VoiceDock.app` を `ditto` で入れ、`/Applications` への symlink を置く → detach → `hdiutil convert -format UDZO -o VoiceDock-<ver>.dmg`（途中で失敗しても trap で必ず detach する。F-62）
   → dmg に署名 → 公証 → staple
4. `scripts/verify-bundle.sh`（リリースの必須ゲート）:
   - `codesign --verify --deep --strict --verbose=2 VoiceDock.app`
   - `spctl -a -t exec -vv VoiceDock.app`、`spctl -a -t open --context context:primary-signature -v VoiceDock-<ver>.dmg`、`xcrun stapler validate`
   - **バンドルの中身が決めたファイル一覧と完全一致**（余計な実行ファイルが入っていない）
   - reaper の署名の識別子が `<BUNDLE_ID>.reaper`、Team ID が一致
   - `otool -L` の確認（11.2）

### 11.4 版の付け方

- `VERSION` が唯一の出所（SemVer）。`VDContract/Version.swift` の定数と一致することをテストで確かめる。reaper の `--version` も同じ値
- **版を文字列の辞書順で比べない**（`1.10.0 < 1.9.0` になる）。比べるときは数値の組にする（`AppVersion.components`）
- リリース: タグは `v<VERSION>` の注釈付きタグ、`gh release create v<VERSION> --verify-tag`（手順は `docs/RELEASE.md`。T-44）。**非公開リポジトリのリリース資産は匿名で配れない**（配るなら公開リポジトリか別の置き場が要る）

---

## 12. フェーズとタスク

### 12.1 進め方（voicedock の運用を引き継ぐ）

- 1 タスク = 1 issue = 1 PR。PR は `develop` へ向け、**利用者が 1 本ずつ確かめてマージする**。PR を積み上げない（base の付け替え事故があった）
- `develop` へのマージでは issue が自動で閉じないので、マージ後に手で閉じる
- PR 本文の必須節: 目的 / 変更 / テスト / **破壊による証明（落ちたテスト名）** / SPEC の変更 / **マージ後にやること**（無ければ「なし」）。issue の本文はチケット（`docs/tickets/T-nn-*.md`）の写しにする
- 差分の目安は 600 行以内（golden と生成物を除く）。超えるならタスクを割る。例外: T-04（PT の検査と自己テストは切り離すと「空振りしない証明」が別の PR になる）・T-25・T-45（生成物と固定テストが大半）。T-06 はチケットの A 群・B 群の 2 PR に分ける
- `docs/SPEC.md` の表を変える PR は、同じ PR で実装と SPEC 同期テストを揃える
- **「リリース」と「削除を実運用で有効にすること」を分ける。**削除 OFF での日常利用は Phase 7 の後から始めてよい。削除のゲート（Phase 8）は緩めない。
  voicedock では E2E が揃う前に削除を有効にし、単体テストが全部緑のまま 5 件の欠陥が実機で見つかった

### 12.2 Phase 0: 実機 PoC（コードは使い捨て。結果を docs/POC.md に**コマンドと生の出力**で残す。詳細は `docs/tickets/P0-poc.md`）

| # | 確かめること | 合格条件 |
|---|---|---|
| P0-01 | 署名した最小アプリ（NSStatusItem だけ）で DJI Mic 3 のマウント通知を受け、TCC の許可ダイアログが出て、許可後に列挙できる。システム設定の該当画面を開く URL（`x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders`）が効くか | 挿してから検出まで 10 秒以内。拒否したとき `opendir` が EPERM になり区別できる。URL の可否を記録 |
| P0-02 | アプリから `diskutil unmount` → `diskutil mount readOnly <node>` → statfs で `MNT_RDONLY` を観測。再マウント後のマウントパス（` 1` が付くか）と、`-mountPoint <元のパス>` を付けたときにパスが保たれるか | 20 回連続で ro を観測。既に ro のとき何もしないこと。パスの挙動を記録（§8.1） |
| P0-03 | アプリの子（posix_spawn）の実行ファイルが、ディスクイメージ上と**実機上**でファイルを unlink できる（アプリの TCC の許可で） | 実機で**試験用に録った 1 本**を消せる。手で直接起動した場合との差を記録 |
| P0-04 | whisper.cpp v1.9.4 を Metal でビルドし、実音声 30 分の RTF を測る。出力 JSON の形が CPU 版と同じ | RTF を記録（判定は P0-09）。`-oj` の形が同じ |
| P0-05 | AVAudioConverter で BWF（24 bit・32 bit float。fmt 16 バイト・tag 3 を含む）を 16 kHz s16 mono にし、ffmpeg 版との長さの差と、whisper の文字起こしの差を見る | 長さの差 ≤ 1.0 秒。文字起こしが実用上同等（差分を貼る） |
| P0-06 | llama.cpp（固定した版）の llama-server を Metal で起動し、Qwen3-30B-A3B-Instruct-2507 Q4_K_M で `response_format: json_object` が効く。`--api-key-file`・`--offline`・`--no-webui` が効く。起動時間とメモリ | JSON が返る。起動時間・常駐メモリを記録 |
| P0-07 | 1 日分（約 350,000 文字）の Map-Reduce | 30 分以内 |
| P0-08 | SwiftPM で組み立てた .app で `SMAppService.mainApp.register()` が効き、再ログイン後に起動する | 起動する |
| P0-09 | 1 日分（16 時間の密な発話）の処理見込み（P0-04 の RTF × 文字数で外挿。**音声の長さではなく文字数で外挿する**。ASR-10） | 次の接続（24 時間）までに終わる |
| P0-10 | GitHub の macOS ランナーで `hdiutil` の FAT32 イメージを attach・再マウント・statfs・unlink できるか | **行わない**（CI は開発機のセルフホストランナー。§10.8）。対象外と記録する |
| P0-11 | `DADiskMountApprovalCallback` で最初から読み取り専用にマウントできるか（任意。できれば rw の窓が消える） | 可否を記録。**v1 では採用しない**（採用は別計画） |
| P0-12 | Vault が `~/Documents` と iCloud Drive にあるとき、非サンドボックスのアプリの `opendir` / `access(W_OK)` / 書き込みに TCC がどう掛かるか（許可前・拒否・許可後） | 挙動を記録（§8.7 の `.notReadable` の文言と DR-10 に反映） |

**Phase 0 で決めること**: `BUNDLE_ID`、`TEAM_ID`、llama.cpp の版、Xcode の版と CI のランナー（P0-10 と T-02）、再マウントで `-mountPoint` を使うか（P0-02）。

### 12.3 タスク一覧（依存順。T 番号は詰めない。T-45 は v1.1 で追加し、依存の位置に置いた）

各タスクの詳細（作るファイル・型・関数・手順・テスト名・破壊による証明）は `docs/tickets/T-nn-*.md`。

| T | 内容 | 主な成果物 | 受け入れ（テスト） |
|---|---|---|---|
| **Phase 1: 骨組みと防護柵** ||||
| T-01 | リポジトリ・Package.swift・モジュール・VERSION・.xcode-version・.swift-format・Makefile・docs/PLAN.md | §3.2 の木 | `swift build` / `swift test` が通る、`make lint` が通る |
| T-02 | CI（§10.8）と P0-10 の反映 | ci.yml | 故意に lint 違反を入れた PR で落ちる |
| T-03 | Vendor ビルドスクリプト（whisper / llama）と versions.env、`--help` の fixture | `Vendor/`、`Tests/Fixtures/*-help.txt` | ビルドでき `otool -L` が通る、SHA 照合で不一致なら止まる |
| T-04 | PolicyTests の基盤（SourceScanner）と PT-01〜22、各 PT の自己テスト | PolicyTests | 違反を仕込んだ一時ソースで各 PT が落ち、コメント・文字列では落ちない |
| T-05 | docs/SPEC.md（付録 A・B と §6.4・§8.11 の表）と SPEC 同期テストの基盤 | SPEC.md | 表の 1 行を消すと落ちる、コードフェンスの中の `#` で節が切れない |
| T-25 | golden 生成ツールと入力 fixture（ノート・LLM・PyJSON・指紋など、voicedock の出力をすべてここで作る。後続のタスクが使う） | tools/golden, Tests/Golden | 生成が再現する（2 回生成してバイト一致） |
| T-06 | VDContract: 名前規則・DeviceID・PartKey・SessionKey・KeySlug・RelPath・HomeLayout・AtomicFile・ContractJSON（要求／結果）・ReaperConf・定数・Version | VDContract | 鍵の固定値、名前規則の表、relpath の全拒否条件、AtomicFile の失敗注入、ReaperConf の fail-closed |
| T-07 | VDContract: TargetIdentity（openVolume・openat 連鎖・withVerifiedTarget） | TargetIdentity | FakeVolume で RV-08〜12 の各理由語、`.diskImage` で RV-06・07 |
| **Phase 2: 記録の土台** ||||
| T-08 | VDCore: 状態・遷移表・復旧写像・集合・ErrorCode・RetryPolicy | States, ErrorCode | 包含関係と不変条件、遷移表 = SPEC、全コードに RetryPolicy |
| T-09 | VDCore: AppConfig・ConfigLoader（CV-01〜59）・ConfigMigrator・既定値・ModelCatalog | Config | CV ごとの違反、未知キー、欠落、全キーの振る舞い（§6.2） |
| T-10 | VDCore: Instant・AppClock・SystemClock・ZonedTime・Sleeper・BlockingIO・Log（登録制イベント・redaction）・LogFile・SafeUnlink・AppPaths | | redaction、ログ行の書式、SafeUnlink がルート外・symlink を拒否 |
| T-45 | VDCore: Python 互換（PyText・PyJSON・casefold 表の生成） | PyText, PyJSON, `tools/unicode/` | §5.7 の固定テスト、voicedock の実出力とのバイト一致 |
| T-11 | VDStore: スキーマ・マイグレーション・backup・recordPartTransition / recordSessionTransition（normal / recovery）・insert・列更新・failedFrom・問い合わせ・読み取り専用 | Store | 楽観的制御の衝突、IllegalTransition、events、retry_count、updated_at、DB ファイルを作らない読み取り |
| T-12 | VDProcess: ProcessRunner（run / spawn / terminateAll） | | 引数の配列渡し、タイムアウトで孫まで消える、環境変数、spawn の停止 |
| **Phase 3: 取り込み** ||||
| T-13 | VDDevice: デバイス判定（規則 1〜9）・MountInspector・列挙不可の区別（共存ガードは F-61 で取り下げ） | | 規則ごとのテスト、`._*` を黙って無視、symlink のボリューム除外、EACCES も not_listable |
| T-14 | VDDevice: ファイルの走査・安定性判定・コピー（SHA-256）・登録・needs_recopy・imported_keys の除外。VDAudio の `AudioProbe` もここで作る | | fast path、不一致で見送り、抜去で partial が消える、本体→記録の順（PT-16） |
| T-15 | VDDevice: 再マウント（Remounter）・statfs 観測・snapshot（世代・connectEpoch）・IngestActivity・reaper.lock・通知のまとめ | | 既に ro なら何もしない、観測値だけを書く、0 台と不明の区別、0 件デバイス、途中で 0 台の snapshot を作らない |
| **Phase 4: 変換と文字起こし** ||||
| T-16 | VDAudio: AudioProbe・16 kHz 変換・出力の検証・空き容量 | | BWF 24 bit / 32 bit float、長さ照合、SHA 照合、重複、空き容量の式 |
| T-17 | VDTranscribe: argv・実行・出力の正規化・無音判定・冪等・`--help` 検査 | | argv の逐語照合、ms→秒、無音の transcript が先に書かれる、終了 0 でも JSON が無ければ失敗 |
| T-18 | VDPipeline: Worker の骨組み・Part の工程（ensureNormalized / ensureTranscribed）・工程内リトライ・復旧・requeue（4 契機）・ガード | | 復旧の全辺、受け手の不変条件、NORMALIZED_MISSING と再コピーの経路、ガードで遷移しない |
| **Phase 5: LLM とモデル** ||||
| T-19 | VDLLM: スキーマ・schema_block・プロンプト描画・JSON 取り出し・切り詰め・検証・修復 | | golden、`<think>`、フェンス、括弧、修復に入力値を含めない、検証文言 |
| T-20 | VDLLM: チャンク分割・Map-Reduce・重複除去 | | golden、深さ上限 |
| T-21 | VDLLM: LlamaServerSupervisor・LoopbackHTTP・ChatTransport | | 起動失敗の再試行、停止、127.0.0.1 固定、ループバック以外は型で作れない、`--help` との照合 |
| T-22 | VDPipeline: Session の工程（分組・閉じる・統合・解析・指紋・解析の再利用・stale_analysis） | | 分組の境界、Block、統合、指紋、書き込み順、stale_analysis の辺 |
| T-23 | VDModels: ダウンロード・SHA 検証・再開・取り込み・ModelManager | | 不一致で削除、名前の検証、ホスト制限 |
| T-24 | カタログの値を再確認（URL の SHA、sha256、bytes、license）と LLM 受け入れ試験（fixture を含む） | ModelCatalog.json、POC.md | §10.6 |
| **Phase 6: ノート** ||||
| T-26 | VDNotes: sanitize・frontmatter・Raw レンダリング | | golden |
| T-27 | VDNotes: Daily レンダリング・警告行・Timeline・WikiLink・Vault 索引 | | golden、TTL |
| T-28 | VDNotes: VaultCheck・NoteWriter・RN / DN 検証・OutputPathResolver | | 空の Vault に書かない、各検証規則と打ち切り、(2) の規則 |
| T-29 | VDPipeline: Raw / Daily の工程・再オープン・Worker.tick の配線 | | Worker を回す結合テスト（偽 whisper・偽 LLM） |
| **Phase 7: UI と配布（削除 OFF）** ||||
| T-30 | UI: NSStatusItem・パネル・AppModel・アイコン状態・起動と終了 | VoiceDockApp | AppModel の単体テスト（UI の見た目はテストしない） |
| T-31 | UI: はじめに・Vault 選択・モデル・ログイン項目 | | AppModel のテスト |
| T-32 | 診断（DR）・要対応（沈黙の検出）・状態の詳細 | | DR ごとのテスト、診断が何も書かないこと（PT-17） |
| T-33 | — 取り下げ（F-60。voicedock からの乗り換えは v1 で扱わない） | | — |
| T-34 | make-app / sign / notarize / dmg / verify-bundle | scripts | verify-bundle が通る |
| T-35 | 実機 E2E（削除 OFF）: E2E-01〜09, 12〜14, 16（E2E-15 は F-61 で取り下げ） | docs/E2E.md | 付録 B.3 |
| **Phase 8: 削除（ゲートあり）** ||||
| T-36 | canDeleteSource・LockEvaluator（readiness と観測）・事前確認 | | ND（アプリ層）と正の対照、式の形の固定 |
| T-37 | reaper 実行ファイル（RV-00〜13） | voicedock-reaper | ND（reaper 層）と正の対照、`.diskImage` |
| T-38 | 要求の書き込み・Session の削除段・reaper の起動と署名検証・結果の回収・期限切れ・staging 後始末 | | 往復テスト（本物の reaper）、古い試行、同じ周回で再要求しない、未接続は待つ |
| T-39 | 根拠 B（settleSkippedDeletions） | | ND-33〜35 |
| T-40 | 有効化・無効化フロー（DeletionEnabler）と常時表示 | | all-or-nothing、失敗時の巻き戻し、`ENABLE` 以外で通らない（UI は 3 秒の長押し。F-65）、無効化は確認なし |
| T-41 | 後追い（過去分・手動で消した分） | | プレビュー、対象 1 件以上で試す |
| T-42 | 実機 E2E（削除 ON）: E2E-10, 11, 17 と、E2E-01〜09 を削除 ON で再実行 | docs/E2E.md | **ゲート（12.4）** |
| **Phase 9: v1.0** ||||
| T-43 | README（利用者向け: 導入・TCC・削除の有効化と戻し方・既知の制約）と文書テスト | | 文書テスト |
| T-44 | v1.0 のリリース | dmg | verify-bundle、E2E-06（1 日運用）の記録 |

### 12.4 削除のゲート（Phase 8 の完了条件。緩めない）

v1.0 を出す前に**すべて**を満たす:
1. 付録 B.1 の ND が全件 PASS（アプリ層・reaper 層とも。正の対照を含む）
2. 付録 B.3 の E2E が全件 PASS（E2E-06 は運用の中で確認してよいが、確認が済むまでゲートは開かない）
3. `.diskImage` のテストが CI か手元で PASS し、その記録が PR にある
4. 実機で「三重ロックを全部外して 1 日流す」を行い、E2E.md に記録する（voicedock ではこれでしか見つからない欠陥が 5 件あった）
5. **削除 ON の状態で E2E-01〜09 を再実行**して全件 PASS（E2E-01〜09 は削除 OFF の試験なので、これをやらないと「消えてはいけない録音が消えない」を実機で一度も見ないまま出すことになる。voicedock の #151 / #152 / #154 / #156 はすべて ON にして初めて出た）

---

## 13. 検証（完成をどう確かめるか）

| 段 | 方法 | 合格 |
|---|---|---|
| 毎 PR | CI の `check`（lint → build → ND → policy / SPEC 同期 → 全テスト）＋破壊による証明 | すべて緑、落ちたテスト名が PR にある |
| 削除に触れる PR | 実機を抜いてから手元で `make test-disk`（CI では走らせない。§10.8） | 結果を PR に貼る |
| ノート形式 | golden（voicedock@d3d595e とのバイト一致） | 差分なし |
| LLM | `make llm-acceptance MODEL=<id>` | §10.6 |
| リリース | `make release` → `verify-bundle.sh` | 全項目 |
| 実機 | docs/E2E.md の手順を実機（DJI Mic 3）で。**生の出力を貼る** | 付録 B.3 |
| 1 日運用 | 削除 OFF で 1 日 → 削除 ON で 1 日。パネルの状態表示とノートを目視 | Raw / Daily が各 1 枚、FAILED なし（または理由が妥当）、削除 ON で元音声が消え空き容量が戻る |

---

## 14. リスクと未確定事項（Phase 0 か実装中に確かめる）

**README に載せる（利用者に見せる）もの: RK-07・RK-18・RK-28・RK-31・RK-32。**それ以外は開発側の記録。

| # | 内容 | 対応 |
|---|---|---|
| RK-01 | TCC の許可が子プロセス（reaper・whisper）に届くか | P0-03。届かなければ reaper を XPC サービスにする等の別計画を立てる（**推測で進めない**） |
| RK-02 | SwiftPM で組み立てた .app でログイン項目が効くか | P0-08 |
| RK-03 | whisper.cpp v1.9.4 の Metal ビルドの速度と安定性 | P0-04 / P0-09。問題があれば v1.9.4 のまま CPU に戻す選択肢を残す（`-ng`） |
| RK-04 | llama-server の引数・`response_format` の対応が版によって変わる | 版を固定し、`--help` 照合テスト（DR-07） |
| RK-05 | AVAudioConverter と ffmpeg のリサンプルの差が文字起こしに効くか | P0-05 |
| RK-06 | ディスクイメージのテストが CI で動くか | CI では走らせない（§10.8）。手元の `make test-disk` で回す |
| RK-07 | 送信機 2 台のときボリュームがどう見えるか | 実機未検証のまま（voicedock と同じ）。コードは複数台を扱い、テストで担保 |
| RK-18 | Daily / Raw ノートを利用者が編集すると、再生成で上書きされる | 受容（voicedock と同じ）。README に書く。編集中は RN-4 が落ちて削除が止まる（安全側） |
| RK-19 | `/Volumes/Macintosh HD` は `/` への symlink | デバイス判定の規則 3 と openat 連鎖 |
| RK-22 | macOS がデバイスに `._*`・`.Spotlight-V100`・`.fseventsd` を作る（rw でマウントされてから ro に直すまでの間） | `.` 始まりを無視、RV-08 で拒否。P0-11 は将来 |
| RK-23 | 沈黙（何も取り込まれない） | §8.11 |
| RK-25 | 読み取り専用での再マウントが失敗する（使用中） | 取り込みは続行、理由語、観測値の表示、削除は起きない（RV-07） |
| RK-27 | partkey / session_key の算出規則を将来変えてしまう | 固定値テスト（§4.2） |
| RK-28 | 取り込み後にボリュームを改名すると、それ以前の録音が削除対象から永久に外れる | 使い始める前の改名を「はじめに」で案内。検査は置けない（消えない側なので事故ではない） |
| RK-29 | ロック 2-A を「同梱・複製」にしたことで弱まった部分（§8.9.3 の注記） | PT-11、RV-00、ND-26 / ND-40 |
| RK-30 | 利用者が編集した frontmatter を Obsidian が書き換える（引用符が外れる等） | 読み取りは Yams（YAML として読む）。書き出しは自前 |
| RK-31 | 30 分ちょうどで 0 文字の NO_SPEECH（whisper の取りこぼし）を根拠 B で消しうる | 根拠 B の既定は false、有効化は別の 3 秒の長押し。transcript の JSON は残る |
| RK-32 | 利用者が `timeZone` を変えると、DB の時刻文字列のオフセットが混ざり、文字列比較（`MIN(started_at)` など）と日付の境界がずれる | 受容（voicedock と同じ）。README に「使い始めた後にタイムゾーンを変えない」と書く。変えたときの挙動は既存行を書き換えない |
| RK-33 | CI のセルフホストランナー（開発機）が止まっていると CI が進まない | 開発機の再起動後に `~/actions-runner/svc.sh status` を確かめる（§10.8） |
| RK-34 | whisper.cpp は不明な引数・読めない音声でも終了コード 0 を返すことがある | 成功の判定を「終了 0 かつ JSON が在って読める」にした（§8.4） |
| RK-35 | Qwen3-2507 の GGUF に公式の配布元が無い（unsloth / lmstudio-community） | T-24 でライセンスと中身（受け入れ試験）を確かめ、コミット SHA と sha256 で固定する |
| RK-36 | reaper がアプリより長生きした場合（アプリのクラッシュ）に、走査が reaper より前の観測になる | `state/reaper.lock` の flock（§2.1）。reaper は SIGTERM で 1 件を終えてから止まる |

---

## 付録 A. 状態・遷移・エラーコード・ログ（docs/SPEC.md へ移す規範の表）

### A.1 状態と復旧写像

Part の状態（宣言順。初期状態 DISCOVERED）:

| # | Part の状態 |
|---|---|
| 1 | `DISCOVERED` |
| 2 | `NORMALIZING` |
| 3 | `NORMALIZED` |
| 4 | `TRANSCRIBING` |
| 5 | `TRANSCRIBED` |
| 6 | `RAW_WRITING` |
| 7 | `RAW_SAVED` |
| 8 | `SOURCE_DELETING` |
| 9 | `SOURCE_DELETE_PENDING` |
| 10 | `COMPLETED` |
| 11 | `FAILED` |
| 12 | `SKIPPED` |

Session の状態（宣言順。初期状態 OPEN）:

| # | Session の状態 |
|---|---|
| 1 | `OPEN` |
| 2 | `READY` |
| 3 | `MERGING` |
| 4 | `MERGED` |
| 5 | `ANALYZING` |
| 6 | `ANALYZED` |
| 7 | `WRITING` |
| 8 | `SAVED` |
| 9 | `SOURCE_DELETING` |
| 10 | `SOURCE_DELETE_PENDING` |
| 11 | `CLEANUP` |
| 12 | `COMPLETED` |
| 13 | `FAILED` |

- 進行中（復旧で戻す）: Part `NORMALIZING, TRANSCRIBING, RAW_WRITING, SOURCE_DELETING`、Session `MERGING, ANALYZING, WRITING, SOURCE_DELETING, CLEANUP`。
  **`SOURCE_DELETE_PENDING` は名前に ING を含むが進行中ではない**（接尾辞で判定しない。SM-10）

復旧写像（`kind: .recovery` でだけ許す辺。この順に処理する。voicedock states.py:271-293）:
```text
Part:    NORMALIZING→DISCOVERED | TRANSCRIBING→NORMALIZED | RAW_WRITING→TRANSCRIBED | SOURCE_DELETING→SOURCE_DELETE_PENDING
Session: MERGING→READY | ANALYZING→MERGED | WRITING→ANALYZED | SOURCE_DELETING→SOURCE_DELETE_PENDING | CLEANUP→SAVED
```

### A.2 遷移表（`kind: .normal`。voicedock `states.py:154-215` と同一 ＋ ★ 6 辺）

Part:
```text
DISCOVERED→NORMALIZING | DISCOVERED→SKIPPED(SOURCE_MISSING)
NORMALIZING→NORMALIZED | NORMALIZING→SKIPPED(DUPLICATE_CONTENT, SOURCE_MISSING) | NORMALIZING→FAILED
NORMALIZED→TRANSCRIBING | NORMALIZED→NORMALIZING(16kHz 消失) | TRANSCRIBING→NORMALIZING(同)
TRANSCRIBING→TRANSCRIBED | TRANSCRIBING→SKIPPED(NO_SPEECH_DETECTED) | TRANSCRIBING→FAILED
TRANSCRIBED→RAW_WRITING | RAW_WRITING→RAW_SAVED | RAW_WRITING→FAILED
RAW_SAVED→SOURCE_DELETING | RAW_SAVED→COMPLETED(削除しない)
SOURCE_DELETING→COMPLETED | SOURCE_DELETING→SOURCE_DELETE_PENDING | SOURCE_DELETE_PENDING→SOURCE_DELETING
COMPLETED→SOURCE_DELETING(過去分)
FAILED→NORMALIZING | FAILED→TRANSCRIBING | FAILED→RAW_WRITING
```
（「手動で消した分を完了にする」は直通の辺を足さず、voicedock backlog.py と同じく SOURCE_DELETE_PENDING→SOURCE_DELETING→COMPLETED の 2 遷移で行う。
RAW_SAVED で結果を待っていた Part の DELETED も RAW_SAVED→SOURCE_DELETING→COMPLETED の 2 遷移で進める。
元ファイルが無いと観測できた RAW_SAVED の Part は、既存の RAW_SAVED→COMPLETED を detail `already_absent` で使う（§8.9.5。F-64。辺は増やさない））

（Session の OPEN→READY の detail は `idle` / `summarize_now`（パネルの今すぐ要約。§5.4。F-66。辺は増やさない）。`stale_day` は F-66 で使わなくなった（過去の記録に残る））

Session:
```text
OPEN→OPEN(Part 追加) | OPEN→READY
READY→MERGING | MERGING→MERGED | MERGING→COMPLETED(session_empty) | MERGING→FAILED
MERGED→ANALYZING | ANALYZING→ANALYZED | ANALYZING→FAILED
★ MERGED→ANALYZED(analysis_reused)
★ ANALYZED→ANALYZING(stale_analysis) | ★ WRITING→ANALYZING(stale_analysis)
ANALYZED→WRITING | WRITING→SAVED | WRITING→FAILED
SAVED→SOURCE_DELETING | SAVED→CLEANUP | SAVED→MERGING(再オープン) | COMPLETED→MERGING(再オープン)
★ SOURCE_DELETING→MERGING(再オープン) | ★ SOURCE_DELETE_PENDING→MERGING(再オープン) | ★ CLEANUP→MERGING(再オープン)
SOURCE_DELETING→CLEANUP | SOURCE_DELETING→SOURCE_DELETE_PENDING
SOURCE_DELETE_PENDING→SOURCE_DELETING | SOURCE_DELETE_PENDING→CLEANUP | CLEANUP→COMPLETED
FAILED→MERGING | FAILED→ANALYZING | FAILED→WRITING
```

> ★ を除いた辺の集合は voicedock `d3d595e:src/voicedock/states.py` の `PART_TRANSITIONS`（23 本）/ `SESSION_TRANSITIONS`（24 本）と一回限りのスクリプトで照合済み（v1.1）。
> **voicedock の `record_transition` は遷移表を検査していなかった**（db.py:328）。そのため voicedock は表に無い辺（復旧の 7 本、`MERGED→ANALYZED`、`ANALYZED→FAILED`、`CLEANUP→SOURCE_DELETING`）を実際に使っていた。
> 本アプリは表を強制するので、復旧は復旧写像（A.1）に分け、`MERGED→ANALYZED` は ★ で足し（ほかの ★ は stale_analysis の 2 本と、削除段からの再オープンの 3 本）、`ANALYZED→FAILED` と `CLEANUP→SOURCE_DELETING` は経路を直して不要にした（§5.6 / §8.9.5）。
> T-08 ではこの一致を、voicedock のファイルから辺を抜き出す一回限りのスクリプトでもう一度確かめ、結果を PR に貼る。

### A.3 エラーコード（**宣言順を voicedock `errors.py` と同じにする**。Daily ノートの警告行の並びがこれに依存する）

RetryPolicy: `none`（再評価の契機まで待たない。FAILED なら requeue で戻る）/ `nextPoll`（行に書かない観測・ガード）/ `nextConnect`（次の接続の立ち上がりで requeue）/ `attempts`（工程内リトライの対象）。

| # | コード | 再試行 | 行き先 | 本アプリでの扱い |
|---|---|---|---|---|
| 1 | `CONFIG_UNKNOWN_KEY` | none | 設定エラー状態 | 終了ではなく停止（CV-01） |
| 2 | `CONFIG_INVALID_VALUE` | none | 同上 | |
| 3 | `CONFIG_LOCK_MISMATCH` | none | 設定エラー状態（CV-30 / CV-33） | 削除要求も書かない |
| 4 | `DEVICE_NOT_READABLE` | nextPoll | — | **DB の行には書かない**。snapshot の `unavailable`・パネル・ログの `error_code=` だけ |
| 5 | `DEVICE_UNSUPPORTED` | none | — | 同上 |
| 6 | `FILE_NOT_STABLE` | nextPoll | — | 同上 |
| 7 | `DUPLICATE_CONTENT` | none | Part SKIPPED | |
| 8 | `SOURCE_MISSING` | none | Part SKIPPED | `needs_recopy = 1` のときは SKIPPED にせず待つ（§8.3） |
| 9 | `SOURCE_HASH_MISMATCH` | attempts | FAILED | `needs_recopy = 1` |
| — | ~~`HELPER_UNAVAILABLE`~~ | | | **廃止**（番号を詰めない） |
| 10 | `DELETE_QUEUE_FAILED` | nextConnect | 状態は動かさず ID を外す | 要求ファイルが書けないとき（voicedock は未使用だった）。ログだけ |
| 11 | `DELETE_TIMEOUT` | nextConnect | PENDING（SKIPPED・RAW_SAVED は ID を外すだけ） | |
| 12 | `DISK_SPACE_LOW` | nextPoll | ガード | 行には書かない（変換中の再確認で失敗したときだけ FAILED） |
| 13 | `AUDIO_PROBE_FAILED` | attempts | 続行（ログのみ） | |
| 14 | `IMPORT_FAILED` | attempts | FAILED | 変換の失敗・時間超過・slug の衝突 |
| 15 | `NORMALIZE_VERIFY_FAILED` | attempts | FAILED | |
| 16 | `NORMALIZED_MISSING` | nextConnect | FAILED | `needs_recopy = 1` |
| 17 | `WHISPER_EXEC_MISSING` | none | FAILED | 起動に失敗したときだけ。**実行ファイルが無いことは工程に入る前のガード**（§5.4） |
| 18 | `WHISPER_MODEL_MISSING` | none | — | **ガードの理由（要対応の表示）にだけ使い、行には書かない**（voicedock では設定検証のコード） |
| 19 | `WHISPER_FAILED` | attempts | FAILED | 終了コード ≠ 0、または生 JSON が無い・読めない |
| 20 | `WHISPER_TIMEOUT` | attempts | FAILED | |
| 21 | `NO_SPEECH_DETECTED` | none | SKIPPED | |
| 22 | `OBSIDIAN_RAW_WRITE_FAILED` | attempts | Part FAILED | 99 を超えた同名ファイルも |
| 23 | `OBSIDIAN_RAW_VERIFY_FAILED` | attempts | Part FAILED | |
| 24 | `SESSION_MERGE_FAILED` | attempts | Session FAILED | チャンクが 0 個 |
| 25 | `LLM_UNAVAILABLE` | attempts | Session FAILED | 起動失敗（`server_start_failed`）・接続失敗・HTTP 400 以上。**モデル未選択・無い・メモリ不足はガード** |
| 26 | `LLM_FAILED` | attempts | Session FAILED | 解析結果の書き込み失敗 |
| 27 | `LLM_INVALID_JSON` | none | Session FAILED | |
| 28 | `OBSIDIAN_NOT_FOUND` | attempts | FAILED | ガードを通った後に Vault が消えたとき（§8.7） |
| 29 | `OBSIDIAN_WRITE_FAILED` | attempts | FAILED | |
| 30 | `OBSIDIAN_VERIFY_FAILED` | attempts | FAILED | |
| 31 | `SOURCE_IDENTITY_MISMATCH` | nextConnect | PENDING | |
| 32 | `SOURCE_DELETE_FAILED` | nextConnect | PENDING | |
| — | ~~`LOCAL_DELETE_FAILED`~~, ~~`DB_ERROR`~~ | | | **廃止**（voicedock でも未使用） |

表示名（警告行）: DUPLICATE_CONTENT→重複、SOURCE_MISSING→元ファイルが見つかりません、NORMALIZED_MISSING→元ファイルが見つかりません、NO_SPEECH_DETECTED→無音。未知はコードのまま、無ければ「理由不明」。
`part_skipped` の reason 語: SOURCE_MISSING→`source_missing`、DUPLICATE_CONTENT→`duplicate_content`、NO_SPEECH_DETECTED→`no_speech`。

### A.4 ログイベント（登録制。この順が `LogEvent` の宣言順）

voicedock の 29 件から `helper_heartbeat_stale` / `helper_recovered` を廃止し、`config_invalid` 以下を足す（`remount_readonly_failed` は voicedock v5.0 で消えた名前なので再利用せず `remount_failed` にした）:

```text
service_started service_stopping config_warning config_invalid recovery_completed
part_discovered part_skipped unparsable_filename
normalize_completed normalize_failed transcription_completed transcription_failed
raw_note_saved raw_note_failed session_merged session_merge_failed session_empty session_reopened
llm_completed llm_failed analysis_trimmed obsidian_saved obsidian_failed
delete_requested source_deleted source_delete_skipped source_delete_pending disk_space_low
scan_completed volume_skipped file_not_stable copy_completed copy_failed remount_failed
inbox_orphans_removed imported_keys_added pipeline_paused pipeline_resumed
llm_server_started llm_server_stopped reaper_run reaper_failed deletion_enabled deletion_disabled
model_downloaded model_download_failed diagnostics_completed
```

主な reason / フィールド（逐語。新しい語を足すときはここに足す）:
- `recovery_completed`: `rolled_back=<n>`（復旧）/ `requeued=<n>`（再評価）
- `source_delete_skipped`: `reason=delete_source_audio_disabled|lock_mismatch|mount_mode_ro|reaper_not_installed|reaper_invalid|device_readonly|already_absent|status_changed`
- `source_delete_pending`: `reason=<RV の理由語>|still_in_inventory|no_result|queue_write_failed`
- `disk_space_low`: `reason=<空き容量の文言>|staging_unlink_failed`
- `pipeline_paused` / `pipeline_resumed`: `reason=disk_space_low|whisper_missing|model_missing|vad_model_missing|vault_not_configured|vault_unavailable|llm_not_selected|llm_model_missing|llm_insufficient_memory|llama_server_missing|license`
- `volume_skipped`: `reason=not_included|excluded|symlink|not_a_mount_point|not_listable|no_recordings|mount_name_mismatch|invalid_device_id`（DEBUG。not_listable / mount_name_mismatch / invalid_device_id は前回の走査から変わったときだけ WARNING）
- `copy_failed`: `reason=copy_size_mismatch|read_error|write_error|changed`
- `remount_failed`: `reason=no_device_node|unmount_failed|mount_failed|still_writable`
- `raw_note_failed` / `obsidian_failed`: `reason=vault|write|verify`
- `reaper_failed`: `reason=version_mismatch|signature|exit_<n>|timeout|busy`（`reaper_run exit=<n>` は起動したら常に出す。シグナルで終わったときは `exit=<128 + シグナル番号>`、起動に失敗したときは `exit=127`、タイムアウトのときは `exit=null`）
- `pipeline_paused` は WARNING、`pipeline_resumed` は INFO
- DB の例外（`StoreError` など、工程の外で起きたもの）は `config_warning rule=store message=<型名>` を WARNING で出す（専用のイベントを増やさない）
- 出す場所とフィールド（本文に無いもの）:
  - `unparsable_filename relpath=…`（DEBUG）: 走査で、ファイル規則の形には一致するが日時が不正な名前（`RecordingName.parseFile` が nil。例 `…_20260230_…`）
  - `scan_completed devices=<n> copied=<n> elapsed_s=<x>`: 走査の終わり。コピーが 1 件以上なら INFO、0 件なら DEBUG
  - `transcription_failed recording_key=… error_code=…`（ERROR）: 文字起こしの FAILED
  - `llm_failed session_key=… error_code=… detail=…`（ERROR）: 解析の FAILED（`SESSION_MERGE_FAILED` を除く）
  - `session_merge_failed session_key=… error_code=SESSION_MERGE_FAILED`（ERROR）: チャンク 0 個
  - `diagnostics_completed passed=<n> failed=<n> notices=<n>`（INFO）: 診断の終わり
  - `part_discovered recording_key=… duration_s=<x|null> [error_code=AUDIO_PROBE_FAILED]`（INFO）: 登録
  - `deletion_enabled [reason=skipped_source]`（根拠 B の有効化のときだけ reason を付ける）、`deletion_disabled [reason=<失敗した段>]`
  - `normalize_failed` の `reason=input`（16 kHz も inbox の原本も無い）
  - `model_download_failed` の `reason=sha256_mismatch|size_mismatch|http_<code>|network|cancelled|bad_url|bad_file_name|io`

reaper は別のログ（`logs/reaper.log`）に固定のイベントを書く（§8.9.4）。`LogEvent` には含めない。

原則（voicedock §16.4）: 1 工程につき「完了」1 件と「失敗」1 件だけ。開始イベントは出さない（状態遷移は `events` テーブルが持つ）。細かい分岐は名前を増やさず `reason=` / `error_code=` で表す。

---

## 付録 B. 削除禁止テスト・reaper の検証・実機試験

### B.1 ND（削除禁止）。**三重ロックを全部外した状態**で故障を 1 つ注入 → 期待

番号は voicedock を**そのまま引き継ぐ**（再割当てしない。ND-10〜17 は voicedock v5.37 で廃止済み、ND-30 は Docker 固有のため欠番。再利用しない）。ND-36 以降は本計画で新設。
層（§10.5）: A = アプリ（NoDeleteTests）、R1 = reaper 実行ファイル × 普通のディレクトリ、R2 = `TargetIdentity` の単体（FakeVolume）、R3 = reaper 実行ファイル × FAT32 ディスクイメージ（`.diskImage`）。
層を複数書いたものは**層ごとに 1 本ずつ**テストを置く（片方の層を消しても別の層が受け止めて緑になるのを防ぐ。TEST-17）。

| # | 故障 | 期待 | 層 |
|---|---|---|---|
| ND-01 | 変換中に I/O エラー | 元音声が残る。部分出力が消える | A |
| ND-02 | 変換結果の長さが 1 秒を超えてずれる | 残る（NORMALIZE_VERIFY_FAILED） | A |
| ND-03 | 内容が同一の重複、`deleteSkippedSource = false` | 残る | A |
| ND-04 | whisper が終了コード ≠ 0 | 残る | A |
| ND-05 | whisper タイムアウト | 残る。プロセス（孫も）が残らない | A |
| ND-06 | 発話なし、`deleteSkippedSource = false` | 残る | A |
| ND-07 | Raw ノートの書き込み失敗 | 残る | A |
| ND-08 | Raw ノートを保存後に外部から削除 / 改変 | 残る（RN を実ファイルで再実行） | A |
| ND-09 | Raw ノートの鍵に当該 Part が無い | 残る | A |
| ND-18 | 削除直前にサイズが変わる | `size_mismatch` | R2・R3 |
| ND-19 | 削除直前に mtime が変わる | `mtime_mismatch` | R2・R3 |
| ND-20 | 対象自身か経路の途中に symlink | 他の場所に触れない（`target_is_symlink` / `path_contains_symlink`） | R2・R3 |
| ND-21 | Part 0 件の Session / `source_path` が nil か空 | 要求を書かない | A |
| ND-22 | ロック 1 の片方だけ false（アプリ側 / reaper.conf 側をそれぞれ） | 要求しない / `reaper_disabled reason=lock1`（要求に触らない） | A・R1 |
| ND-23 | デバイスが読み取り専用（観測） | 要求しない / RV-07 で残す | A・R3 |
| ND-24 | relpath に `../` | `relpath_unsafe` | R2・R3 |
| ND-25 | symlink 経由でボリューム外 | `path_contains_symlink` | R2・R3 |
| ND-26 | `bin/voicedock-reaper` が無い（ロック 2-A） | 要求を書かず、何も消えない（voicedock では「要求はキューに残りタイムアウト」だった。意味を変えた） | A |
| ND-27 | 同じ request_id を 2 回 | 2 回目は `replayed` | R1 |
| ND-28 | `.Trashes/...` などの `.` 始まり | `relpath_unsafe` | R2・R3 |
| ND-29 | 親フォルダ名が規則外（ボリューム直下のファイルを含む） | `folder_rule` | R2・R3 |
| ~~ND-30~~ | ~~欠番: voicedock の「コンテナから state/ を改ざん」は Docker 固有のため廃止~~ | — | — |
| ND-31 | device_id だけが違う同名ファイル | 別デバイスの録音を消さない | A・R3 |
| ND-32 | Part の transcript が無いか壊れている | 残る | A |
| ND-33 | `SOURCE_MISSING` の SKIPPED | 残る | A |
| ND-34 | 無音だが whisper 出力の JSON が無いか壊れている | 残る | A |
| ND-35 | 重複だが双子の本文が Vault で確認できない | 残る | A |
| ND-36 | Vault の `.obsidian` が無い（空の Vault） | ノートを書かず、要求も書かない | A |
| ND-37 | denoised（`_orig` 無し）のファイルを指す要求 | `filename_rule` | R2・R3 |
| ND-38 | request_id やファイル名に `/` や `..` を含む | `rejected/` へ移し、結果ファイルを外へ書かない | R1 |
| ND-39 | `<VOLUMES_ROOT>/<device_id>` がマウント点でない（ただのディレクトリ）/ FS が msdos でない（HFS+ のイメージ） | `not_a_mount_point` / `unexpected_fs` | R1・R3 |
| ND-40 | バンドル内の reaper（`<HOME>/bin/` 以外の場所）を直接起動 | 終了コード 3、何も消えない、何も書かない（RV-00） | R1 |
| ND-41 | reaper の署名が不正 / 版が違う | アプリが起動しない | A |
| ND-42 | 古い試行の DELETED 結果（request_id 不一致） | 捨てる。消えていないものを消えたと判定しない | A |
| ND-43 | reaper.conf に未知のキー・重複・不正値・必須の欠落 | 無効側（終了コード 2、`reaper_disabled reason=conf_invalid`、要求に触らない） | R1 |
| ND-44 | 要求の device_id / relpath と partkey が食い違う | `partkey_mismatch` | R1 |
| ND-45 | reaper.conf が無い・読めない（ロック 1 の片方が不明） | 要求を書かない（不明は安全側） | A |
| ND-46 | DELETED の結果に対して、reaper の後の走査がまだ無い（`generation < reaperScanGeneration`）か、デバイスが snapshot に無い | 完了にしない（結果を残して観測を待つ） | A |
| ND-47 | デバイスが接続中で `readOnly == nil`（観測できない） | 要求を書かない | A |

**正の対照**（必須）: A `deletionActuallyHappensWhenEverythingIsValid`（要求ファイルが書かれ `RAW_SAVED→SOURCE_DELETING` が記録される）、R3 `aValidRequestActuallyDeletes`（本物の FAT で実際に消える）。
R1 と R2 にもそれぞれ「同じ準備で故障を入れなければ次の段へ進む」ことを確かめる対照を置く（R1: RV-06 まで進んで `not_a_mount_point` になる、R2: `withVerifiedTarget` の body が呼ばれる）。

### B.2 reaper の検証（RV）と理由語

| # | 検証 | 理由語 | 要求の扱い | voicedock の検証 |
|---|---|---|---|---|
| RV-00 | 自分の置き場所が `<HOME>/bin/voicedock-reaper`（通常ファイル、`.app/Contents/` を含まない） | （終了コード 3） | 触らない | （無し） |
| RV-01 | reaper.conf が正しく読め `DELETE_SOURCE_AUDIO=true` | `lock1`（false）/ `conf_invalid`（不正。終了コード 2） | 触らない | 1 |
| RV-02 | ファイル名が `<request_id>.json` の形（02a）、JSON の request_id がファイル名と一致（02b） | `malformed_request_id` | `rejected/` へ | （無し。d419397 で後から追加） |
| RV-03 | JSON の形（キー集合・型・targets がちょうど 1） | `malformed_request` | 拒否 | （無し） |
| RV-04 | リプレイでない | `replayed` | 拒否 | 11 |
| RV-05 | partkey と一致 | `partkey_mismatch` | 拒否 | 12 |
| RV-06 | `DeviceID.isValid`・symlink でない・マウント点・FS 種別 `msdos` | `device_absent` / `not_a_mount_point` / `unexpected_fs` | absent は残す、他は拒否 | 3（ディレクトリの有無だけだった） |
| RV-07 | 読み取り専用でない（観測） | `mount_readonly` | 残す | 2（観測値側が BSD sed で素通り） |
| RV-08 | relpath の健全性 | `relpath_unsafe` | 拒否 | 4・9 |
| RV-09 | openat 連鎖 | `path_contains_symlink` / `target_missing` | 拒否 | 5（realpath 比較） |
| RV-10 | symlink でない通常ファイル | `target_is_symlink` / `not_regular_file` | 拒否 | 6 |
| RV-11 | ファイル名（`_orig` 必須）・親フォルダ名 | `filename_rule` / `folder_rule` | 拒否 | 7・8（denoised も通していた） |
| RV-12 | size 一致・mtime 差 < 2.0 | `size_mismatch` / `mtime_mismatch` | 拒否 | 10（整数秒の差 ≥ 2 で不一致） |
| RV-13 | unlink と不在確認 | `unlink_failed` / `still_present` | 拒否 | （番号なし） |

「拒否」= processed.log に追記 → 結果 `SOURCE_IDENTITY_MISMATCH` → 要求を消す。「残す」= 何も書かず次回に回す（アプリ側の期限切れで取り下げられる）。
旧 reaper の理由語 `realpath_failed` / `outside_volume` / `stat_failed` は openat 連鎖では出ない。

### B.3 実機試験（E2E。docs/E2E.md に手順・生の出力・判定を書く）

判定は `✅ PASS` / `✗ FAIL` / `⬜ 未実施` / `— 対象外` のどれかで始める（空欄・散文にしない。`✗` は **U+2717**。`❌` や `×` と混ぜない。機械検査が落ちる）。1 件でも FAIL なら修正チケットを起票し、次の Phase へ進まない。

| # | 内容 | 削除 |
|---|---|---|
| E2E-01 | 1 本を通しで（接続 → Raw / Daily）。単一チャンクでも Timeline が出る | OFF |
| E2E-02 | **コピー中に抜く**（危険な窓はコピー中。数本の長い録音でコピーに数分かかる状態で、開始 30 秒後に抜く）→ `.partial` が消え、再接続で再コピー、**デバイスの全ファイルのサイズと mtime が 1 バイトも変わらない**（前後の一覧を貼る） | OFF |
| E2E-03 | 文字起こし中に抜く（数分の録音で。処理はコピーから続き、削除 OFF なら COMPLETED） | OFF |
| E2E-04 | Vault を利用不可にする（外付けを外す / `.obsidian` を一時的に改名）→ 何も書かず（ガードで待つ）、要対応に出て、元音声が残り、戻すと**再起動なしで**再開 | OFF |
| E2E-05 | 抜き挿し 6 回以上で二重処理しない（前後の件数表） | OFF |
| E2E-06 | 1 日分（16 時間・約 32 本）が 1 セッションにまとまり、**次の接続（24 時間）までに処理が終わる**（運用で確認してよい） | OFF |
| E2E-07 | 無音の Part があっても止まらない（警告行が「無音」、⚠ が付かない） | OFF |
| E2E-08 | 1 本だけ文字起こしを失敗させる: その Part が NORMALIZED になった直後に `staging/<slug>/audio16k.wav` を壊れたデータで上書き → WHISPER_FAILED、他は進み、Daily に警告行。その後 16 kHz 音声を消して再接続 → NORMALIZED_MISSING → 再コピー → 再評価で完走する | OFF |
| E2E-09 | 保存後に同じ日の Part を追加 → 再オープンで作り直す（ファイルが増えない） | OFF |
| E2E-10 | 削除 ON で通し（Raw の検証を通った分だけ元音声が消え、空き容量が戻る。無音は根拠 B を有効にしない限り残る） | ON |
| E2E-11 | 過去分の削除・手動で消した分の完了（削除 OFF の期間の Part も Raw の検証を経ているので**対象は 0 件にならない**。voicedock の「`--backlog` は 0 件が正しい」は当時 Raw 検証を経ていなかったため。対象外は理由を表示）。**手動で消した分の完了は実機では確かめない**（`SOURCE_DELETE_PENDING` を手の操作で確実に作れない。T-41 の `BacklogPlannerTests` の resolveAbsent 系の単体テストで代え、運用中に `SOURCE_DELETE_PENDING` が出たら E2E.md に記録する。F-63） | ON |
| E2E-12 | 文字起こし中にアプリを強制終了（`kill -9`）→ 再起動で途中から再開し、**二重処理しない**（前後の件数表） | OFF |
| E2E-13 | 処理中にスリープ → 復帰後に続行（処理中はアイドルスリープしない） | OFF |
| E2E-14 | アプリが動いていない間に接続 → 起動後に取り込む | OFF |
| E2E-15 | — 取り下げ（F-61） | — |
| E2E-16 | リムーバブルボリュームの許可を拒否 → パネルに案内が出る。許可後に取り込む | OFF |
| E2E-17 | 削除を無効化（確認なし）→ 直ちに読み取り専用へ再マウントされ、以後削除されない | ON→OFF |
| E2E-18 | — 取り下げ（F-60） | — |

---

## 付録 C. voicedock の教訓（本文で参照している ID の索引）

出典は voicedock の issue / PR 番号と SPEC 付録の変更記号。詳細を読みたいときは `git -C /Users/terada/Projects/voicedock log --grep '#<番号>'` と SPEC の付録を見る。
「適用」は本計画のどこで守っているか。

### C-DEL 削除の安全性

| ID | 何が起きたか（原因） | 教訓 | 適用 |
|---|---|---|---|
| DEL-01 | ノートの整数 ID と DB の ID が振り直しで別物を指しうる（#60） | ノートに載せる鍵は不変の自然キー。算出規則を変えない | §4.2 |
| DEL-02 | 「終端 6 件」と「削除可 4 件」が同じ名前だった（K-1） | 集合を分けて命名し、包含関係をテストする | §5.1 |
| DEL-03 | 空集合の `all()` が真、`join(volume, "")` はルート（A-14） | 非空・非空文字の番犬項を明示 | §8.9.1、CR-09 |
| DEL-04 | 要約の失敗で容量が永久に解放されない、1 本詰まると全日止まる（#143） | 根拠は「テキストが 2 か所に在る」。評価は Part ごと | §8.9.1 |
| DEL-05 | 式の 1 項を消しても落ちるテストが無かった（#143） | 全項に ND | §8.9.1、B.1 |
| DEL-06 | Docker が作った空の Vault に書いて検証も通った（#134） | 書く前に `.obsidian` を確認、Vault を作らない | §8.7、ND-36 |
| DEL-08 | 古い試行の DELETED が新しい要求に適用されうる（#160） | 引き方は partkey、照合は request_id | §8.9.6、ND-42 |
| DEL-09 | reaper が消す要求ファイルを台帳にして全結果を捨てた。fixture が要求を消していなかった（#162） | 境界の向こうが所有するファイルを台帳にしない。fixture を実機どおりに | §4.4、§10.2 |
| DEL-10 | 観測が行為より古い／同じ秒で成功を「保留」にした（#156 / #182） | 時刻比較をやめ、reaper の後に走査する | §8.9.6 |
| DEL-11 | 保留にした直後に同じ周回で再要求（#156） | 同じ周回で再要求しない | §8.9.5 |
| DEL-12 | size / mtime を inbox のコピーから取り 4.5 時間ずれた（#151） | デバイスの事実は原本の stat だけ | §8.1、§4.4 |
| DEL-14 | SAVED のセッションを誰も再評価しなかった、1 件の衝突でループが止まった（#154） | tick に削除評価を入れ、衝突で全体を止めない | §5.4 |
| DEL-15/16 | ロックの片方だけ解除でセッションが永久に進まない（#145 / #160） | 待っても変わらない条件で待たない | §8.9.2 |
| DEL-18 | 期限切れ処理が古い snapshot から遷移して常駐が死んだ（#162） | 読み直し＋例外捕捉、2 層を別々にテスト | §8.9.7 |
| DEL-19 | CLI の後追いが途中で落ちた（#162） | Part ごとに捕捉して続ける | §8.9.9 |
| DEL-20 | 古い観測のまま新しい要求を書きうる | 観測が古いときは回収だけ | §5.4 |
| DEL-21 | 書き手と検証側が別の集合を持ち、FAILED 1 本で全日消せない（#164） | 同じ定数を両側が使い、両側を別々に固定 | §5.1 |
| DEL-25 | 重複の双子が文字列にしか無かった（#180） | 列で持つ。文字列を解析しない | §7.2 |
| DEL-26 | 実行者が判断者を信じて消していた（v3.x） | 判断と直前の独立再検証を分ける | §8.9.4 / §8.9.5 |
| DEL-31 | 試行の成否から「ro でない」と報告した（#107） | 観測値を書く。既に ro なら何もしない | §8.1 |
| DEL-32 | 未接続を「読み書き可能」と表示した（#148） | 0 台と不明を分ける | §8.1 |
| DEL-34 | denoised を読まずに消す誘惑 | 読んでいないファイルを消さない | §4.1、RV-11 |
| — | reaper のロック 2-B の**観測値側**（heartbeat の `mount_readonly`）の確認が macOS の BSD sed で常に素通り（`\|` 非対応。設定値側の `MOUNT_MODE` の比較は効いていた）、テストは Linux の GNU sed で緑（本計画の調査で発見、実機で再現。voicedock 658adde で修正） | **対象 OS でテストを回す**。観測は構文解析ではなく API（statfs）で | §8.9.4、§10.8 |
| — | reaper の検証 3 がディレクトリの有無だけ、request_id の文字種未検証、形式不正の要求が永久に残る（同上） | マウント点・FS 種別・文字種・rejected | RV-02 / RV-06 |

### C-DEV デバイスと取り込み

| ID | 何が起きたか | 教訓 | 適用 |
|---|---|---|---|
| DEV-03 | TCC の拒否を「録音が無い」と表示（`access` は通り `opendir` が EPERM）（#3） | 列挙で判定し、理由を分ける | §8.1 規則 5 |
| DEV-04 | LaunchAgent から直接起動すると TCC の許可が届かない（`execv` 不可、`posix_spawn` で通った） | responsible process を保つ | §8.2、P0-03 |
| DEV-05 | stat の多発で固まった | 名前だけで判定できる規則を先に | §8.1 規則 1〜2 |
| DEV-07 | `.*` を正規表現として読むと全除外 | glob と明記 | §8.1 |
| DEV-08 | `/Volumes/Macintosh HD -> /` | symlink のボリュームを除外、封じ込め | §8.1、§4.6 |
| DEV-09 | AppleDouble 等で警告が溢れた | `.` 始まりを黙って無視 | §8.1 |
| DEV-10 | 出荷時名 `NO NAME` の衝突 | 使用前に改名 | §8.12 |
| DEV-11 | フォルダ名の日付と中身の日付が違う | 日付はファイル名から | §4.1 |
| DEV-13 | 設定欠落を 0 に倒して安定性判定が全面無効（#162） | 規定の制限へ倒す | §6.1 |
| DEV-14 | ファイルごとの直列待機 | 一括判定 | §8.1 |
| DEV-16 | 書きかけを読む | partial → rename、本体が先・記録が後 | §8.1 |
| DEV-17 | 壊れたコピーを文字起こしすると削除条件が真になる | 変換時に SHA-256 照合 | §8.3 |
| DEV-18 | 再利用経路が `sha256=None` を書いた（#164） | どの経路でも SHA を出す | §8.3 |
| DEV-19 | 録音 0 件のデバイスで中断し、以後の削除が止まった（#177） | 空は定常状態。0 件をテスト | §8.1 |

### C-SM 状態機械とリトライ

| ID | 教訓 | 適用 |
|---|---|---|
| SM-02 | 「X のまま」は遷移ではない | §5.2 |
| SM-03/04 | 失敗回数は FAILED 入りでだけ +1、工程通過で 0 | §5.2 |
| SM-05 | FAILED は接続・起動で無条件に再投入（上限なし） | §5.4 |
| SM-07/08 | 戻りうる全状態に受け手がいる。進行中の状態も入口で受ける | §5.3 |
| SM-10 | 接尾辞 ING で判定しない | 付録 A.1 |
| SM-11/12 | 再オープンの契機は「行き先が決まった時点」。FAILED / SKIPPED も契機 | §5.6 |
| SM-14 | 無音・失敗 1 本で 1 日を止めない | §5.6 |
| SM-15 | 失敗の帰属はトリガの Part だけ | §8.7 |
| SM-17 | 入力欠落は必ず NORMALIZING を経由 | §8.4 |
| SM-18 | 空き容量不足はガード（遷移しない） | §8.3 |
| SM-20 | SKIPPED を遷移させると error_code が消える | §8.9.1 |
| SM-21 | rawValue で集合を混ぜない | §5.1 |
| SM-23 | FAILED の 16 kHz を消すと復旧不能 | §8.9.5（finishCleanup） |
| SM-24 | 最優先で検出すべきは沈黙 | §8.11 |

---

### C-その他

| ID | 教訓 | 適用 |
|---|---|---|
| NOTE-01/02 | 受理されるのに効かない設定を置かない（`include_transcript` / `granularity`） | §6.2、CR-14 |
| NOTE-04 | Raw の段落は見出しごとに 1 つ、半角空白でつなぐ | §8.6 |
| NOTE-05 | SKIPPED に「再試行されます」と書かない。⚠ は許可リスト判定 | §8.6 |
| NOTE-06 | frontmatter は自前で書く。文字列は常に二重引用 | §8.6 |
| NOTE-08 | ファイル名は UTF-8 のバイト数で切る | §8.6 |
| NOTE-10/11 | リンクはレンダラが付ける。Vault 索引は Worker が保持し TTL を守る | §8.6 |
| NOTE-12/13 | RN-6（包含）と DN-7（完全一致）を混同しない。空の Summary を成功にしない | §8.7 |
| NOTE-14 | 後片付けの例外で元の例外を隠さない | §8.7、CR-21 |
| NOTE-16 | 診断が Vault にフォルダを作らない | DR-10 |
| LLM-01 | 件数の上限をプロンプトに見せない（数を埋めに来る） | §8.5 |
| LLM-02 | 検証の前に上限へ切り詰め、ログに出す | §8.5 |
| LLM-03 | 解析の入力の指紋を本体の後に書く。一致しなければやり直す | §8.5、§5.6 |
| LLM-05 | 実時間で切れたチャンクは重ねない | §8.5 |
| LLM-09 | 修復要求に入力値（transcript の断片）を含めない | §8.5 |
| LLM-10 | HTTP クライアントを使い回さない | §8.5 |
| LLM-15 | whisper と LLM を同時に走らせない | §2.1 |
| ASR-01 | 16 kHz / mono / s16 と長さの照合 | §8.3 |
| ASR-02 | VAD は前提（切ると 13.4 倍遅く、178 区間中 170 が幻覚） | §6.2、DR-06 |
| ASR-04 | 起動前に入力の実在を確認 | §8.4 |
| ASR-05 | whisper の offsets はミリ秒 | §8.4 |
| ASR-07 | 孫プロセスまで殺す | §8.2 |
| ASR-08 | duration 不明時、whisper は上限側・変換は下限側に倒す | §8.3 / §8.4 |
| ASR-09 | 無音でも正規化 JSON を判定の前に書く | §8.4 |
| ASR-10 | 性能は音声の長さではなく文字数で外挿。ほぼ無音の素材で測らない | P0-09 |
| ASR-15 | fixture は実機どおりの BWF（ヘッダ約 32 KB） | §10.2 |
| CFG-01 | 設定キーの増減で再起動ループ | §6.1（版と移行、落とさない） |
| CFG-02 | 設定が嘘をつく 3 つの形 | CR-14 |
| CONC-02 | 同じ問い合わせを複数箇所に手書きしない | §7.2 |
| CONC-03/04 | WAL・FULL・busy_timeout。バックアップは backup API | §7.1 / §7.2 |
| CONC-06 | 読み取りの経路が DB ファイルを作らない | §7.1 |
| CONC-08/09 | 消すのは DB 更新の後。指紋は本体の後 | §8.3 / §8.5 |
| CONC-11 | 停止ハンドラはフラグを立てるだけ | §5.4 |
| CONC-13 | slug の衝突は持ち主を照合する | §8.3 |
| TIME-01/02/03 | 絶対時刻で統合、タイムゾーン変換してから日付、ファイル名の時刻にはタイムゾーンを付与するだけ | §5.6、§4.1 |
| TIME-04 | tick の先頭で now を固定しない | §5.4 |
| TIME-06 | TTL は monotonic | §5.4 |
| TEST-01 | テストの空振り 7 型（環境を握っていない・検証対象を parametrize の元に・件数の直書き・実行後の値だけ・文言の前半だけ・多重防御・壊す箇所と非対応） | §10.3 |
| TEST-03/04 | 正の対照。ND はロックを全部外して | §10.5 |
| TEST-05 | fixture を実機どおりに、fixture もテスト | §10.2 |
| TEST-06/07 | 往復テスト。配線（tick）そのものをテスト | §10.3 |
| TEST-08 | 列挙全体の不変条件 | §10.3 |
| TEST-09/26 | 静的検査は構文を見る（文字列検索は散文に引っかかる） | §9.4 |
| TEST-12 | 全テストでネットワーク遮断 | §10.1 |
| TEST-17/18/19 | 層ごとに独立したテスト、差し替えの範囲を閉じる、弾かせたい条件以外は満たす | §10.1 / §10.5 |
| TEST-20/28 | 対象 1 件以上で dry-run を試す、空の状態をテスト | §8.9.9、§10.3 |
| TEST-22/23 | E2E でしか見つからない欠陥がある。ディスクイメージの成功は USB の成功を保証しない | §12.4 |
| TEST-30 | 振る舞いで落とせない項は「在ること」を固定し理由を書く | §8.9.1 |
| OPS-01 | develop 向け、1 本ずつ手でマージ、積み上げない、issue は手で閉じる | §12.1 |
| OPS-07 | リリースと削除の有効化を分ける。ゲートを緩めない | §12.1 / §12.4 |
| OPS-12 | 利用者の操作が要るものだけ警告 | §8.11 |
| OPS-14 | 診断は何も書き換えない | §8.11 |
| OPS-19 | ダウンロードは .part → 検証 → rename。名前を先に検証 | §8.10 |

---

## 付録 D. voicedock との意図的な差分（一覧）

| # | voicedock | 本アプリ | 理由 |
|---|---|---|---|
| X-01 | ffmpeg で変換 | AVFoundation | 同梱しない（GPL ビルドの回避・サイズ） |
| X-02 | Helper と コンテナが JSON（heartbeat / inventory）でやりとり | 同一プロセスの snapshot（世代番号） | 境界が無くなった。同じ秒問題を消す |
| X-03 | 結果の新しさを秒の時刻で比較 | reaper の終了後に走査し、時刻を比べない | #156 / #182 |
| X-04 | 墓標ファイル `.meta.json` | DB の列 | 同上 |
| X-05 | reaper の 2-B 確認の観測値側は heartbeat の文字列解析（macOS で素通り） | statfs で直接観測 | バグの修正 |
| X-06 | 検証 3 はディレクトリの有無 | マウント点と FS 種別 | 穴の修正 |
| X-07 | 検証 7 は denoised も通す | `_orig` 必須 | 穴の修正 |
| X-08 | request_id の文字種を見ない | RV-02 | 穴の修正 |
| X-09 | realpath で封じ込め | openat 連鎖 | TOCTOU を消す |
| X-10 | ロック 2-A = reaper が配置されない | reaper は同梱、`bin/` へ複製したときだけ実行可能＋自己位置確認 | 利用者の決定（D-5） |
| X-11 | 既存ノートは session_key が一致すれば上書き | session_key が一致し、鍵がすべてアプリの DB のこの Session の Part であるときだけ上書き、それ以外は (2)（§8.8） | 乗り換え時の文字起こし消失を防ぐ |
| X-12 | 修復プロンプトにスキーマが無い | 末尾に `{schema_block}` | 修復の成功率 |
| X-13 | ANALYZED / WRITING のセッションに Part が増えても古い解析のまま書く | 指紋を比べて `ANALYZED→ANALYZING` / `WRITING→ANALYZING` | 潜在バグの修正 |
| X-14 | 復旧時に Vault の tmp を消さない | 名前が完全一致するものを消す | 潜在バグの修正 |
| X-15 | `## Sources` が ` (2)` を無視 | 実際の basename | 潜在バグの修正 |
| X-16 | request_id は（文書は UTC、実装は）システムのローカル時刻で `Z` も付かない | UTC・`Z` 付きに統一 | 食い違いの解消 |
| X-17 | 設定エラーで exit 2（再起動ループ） | 停止状態でパネルに表示、版と移行 | CFG-01 |
| X-18 | `vault_marker: ""` で確認を無効化できる | 無効化できない | DEL-06 の逃げ道を塞ぐ |
| X-19 | モデルの URL が `resolve/main` | コミット SHA で固定 | §18.5 の徹底 |
| X-20 | ND を別 job | 1 job の先頭ステップ | macOS の分数 |
| X-21 | `record_transition` は遷移表を検査しない | 遷移表（normal）と復旧写像（recovery）で検査し、表に無い辺は `IllegalTransition` | 表の外の遷移を見えなくする |
| X-22 | 削除要求はファイルが先、ID が後 | ID が先、ファイルが後。「待っている」は ID の有無だけ | 途中で落ちても結果を引ける |
| X-23 | 結果の回収・期限切れは Session の Part だけ | 結果ファイル全件・ID を持つ全 Part | 過去分の Part を回収できなかった |
| X-24 | 過去分は COMPLETED の Part だけ。手動で消した分は未接続でも「無い」と判定 | COMPLETED の Session の PENDING も対象。未接続は `device_absent` で対象外 | 消えていないものを完了にしない |
| X-25 | 名前規則の `\d` と `$`、relpath の `./a`・`a//b` を許す | `[0-9]` と全体一致、relpath は厳格 | Python と bash の食い違いを消す |
| X-26 | device_id はマウント点の basename で、再マウントでパスが変わると partkey が変わる | basename とボリューム名が違えば取り込まない | 全件再コピーと重複の警告を防ぐ |
| X-27 | whisper の成功は終了コードだけで判定 | 終了 0 かつ JSON が在って読める | whisper.cpp は失敗でも 0 を返すことがある |
| X-28 | モデルが無いと設定エラーで起動しない | 工程の前のガード（遷移せずに待つ）と要対応 | モデルを後から入手するアプリの流れに合わせる |
| X-29 | Vault が無いと遷移してから FAILED（戻り先が次の接続） | 工程の前のガード。戻せば再起動なしで再開 | E2E-04「戻すと再開」を満たす |
| X-30 | FAILED(NORMALIZED_MISSING) の requeue が再コピーより先に走ると SKIPPED（終端）に落ちる | `needs_recopy` の Part は requeue せず、再コピーの完了を契機 4 にする | 再コピーで復旧できるようにする |
| X-31 | 再オープンは SAVED / COMPLETED からだけ（削除段の間に増えた Part が Daily に載らない） | 削除段（SOURCE_DELETING / SOURCE_DELETE_PENDING / CLEANUP）からも再オープン | 潜在バグの修正 |
| X-32 | 表示時刻は Part の started_at の固定オフセットで描く | Raw の見出しは同じ（固定オフセット）。Timeline の見出しと ISO はタイムゾーンの規則で描く（夏時間の切り替えをまたぐと違う） | Instant で時刻を持つため。夏時間の無い地域では一致 |
| X-33 | JSON の入れ子の深さに実用上の上限が無い | `PyJSON.decode` は 64 段まで | Debug ビルドのスタックが溢れる |
| X-34 | frontmatter の重複キーは後勝ち（PyYAML）、検証中にノートを読めないと例外、timeline.json のオフセット無しの時刻を受ける、transcript の bool を数として受ける | 重複キーは「読めない」、読めなければ規則 3 を偽にして打ち切り、オフセット無しは受けない、bool は受けない | すべて安全側 |
| X-35 | ログの値の引用は Python の `$`（末尾の改行を許す） | 全体一致で判定し、末尾に改行があれば引用する | 1 行 1 イベントを守る |
| X-36 | 解析を再利用するとき `analysis_path` を書かない | 再利用でも書く | 書いた後・DB 更新の前に落ちた Session が ANALYZED で永久に止まる（潜在バグの修正） |
| X-37 | 日付が過去の OPEN を `stale_day` で閉じる（0:00 の自動要約） | 閉じる契機は無通信の `idle` とパネルの今すぐ要約（`summarize_now`）だけ | 利用者の決定（2026-09-23。F-66） |

**意図して変えないもの**（voicedock の実装どおりにする。SPEC の記述と違っても）: frontmatter の文字列を常に引用、Timeline の区切り（Map-Reduce はチャンク単位）、
Raw の `###` は実際の segment 時刻、前日・翌日リンクは実在を確かめない、`recorded` は除外 Part を含む、重複除去は Reduce 経路だけ、
多段 Reduce の深さ上限で `LLM_INVALID_JSON`、sanitize はファイル名だけ（タグには通さない）、whisper の `-of` は staging、`error_message` は 200 文字（コードポイント数）、
指紋・内部 JSON の書式（Python `json.dumps` と同じ）、切り詰め・文字数はコードポイント、Raw の見出し時刻は保存された文字列のオフセット、未接続のデバイスでは削除を「待つ」、backoff の添字（0 と 1 が同じ先頭値）。

---

## 付録 E. 移植元の早見表（実装者が読む voicedock のファイル。すべて `d3d595e`）

| 本アプリのモジュール | voicedock のソース | voicedock SPEC | voicedock のテスト（何を固定しているかの参考） |
|---|---|---|---|
| VDContract | `device.py`（正規表現）、`paths.py`（鍵・relpath） | §5.2、§8.1、§14.1.1 | `test_paths.py`、`test_device_parse.py` |
| VDCore（状態・エラー・設定） | `states.py`、`errors.py`、`config.py`、`log.py` | §7、§9、§15、§16 | `test_states.py`、`test_errors.py`、`test_config.py`、`test_log.py` |
| VDStore | `db.py`、`migrations/*.sql` | §8 | `test_db.py`、`test_migration_rules.py` |
| VDDevice | `helper/voicedock-ingest`、`device.py`、`discover.py` | §5.4、§10.1〜§10.3 | `test_helper_ingest.py`、`test_discover.py` |
| VDAudio | `audio.py` | §10.5 | `test_normalize.py`、`test_probe.py` |
| VDTranscribe | `transcribe.py`、`tests/fixtures/fake_whisper.py` | §10.6 | `test_transcribe.py`、`test_missing_input.py` |
| VDLLM | `llm.py`、`prompts/*.txt` | §12 | `test_llm_schema.py`、`test_json_extract.py`、`test_chunking.py`、`test_reduce.py`、`test_llm_client.py` |
| VDNotes | `notes.py`、`raw.py`、`daily.py`、`wiki.py` | §13 | `test_raw_render.py`、`test_daily_render.py`、`test_verify.py`、`test_sanitize.py`、`test_wikilink.py`、`test_atomic_write.py` |
| VDPipeline | `pipeline.py`、`worker.py`、`session.py`、`cleaner.py`、`backlog.py` | §10.0、§10.4、§10.8〜§10.12、§14 | `test_no_delete.py`、`test_worker_loop.py`、`test_session_*.py`、`test_backlog.py`、`tests/integration/*` |
| voicedock-reaper | `helper/voicedock-reaper` | §14.1.1、§14.2 | `test_reaper.py` |
| 診断 | `doctor.py`、`health.py`、`scripts/doctor.sh` | §19 | `test_doctor.py`、`test_health.py` |
| 実機試験 | `docs/E2E.md`、`docs/POC.md` | §20.3、§21 | `test_runbook.py` |

---

## 付録 F. v1 → v1.1 の改訂一覧（2026-09-18。参照実装 voicedock@d3d595e との全節の突き合わせによる）

重大度: **誤** = このまま実装すると誤動作する、**欠** = 実装者によって結果が変わる（仕様の欠落）、**曖** = 読み方が割れる、**事** = 外部の事実に合わせた更新。

| # | 重大度 | 節 | 内容 |
|---|---|---|---|
| F-01 | 誤 | §5.2・§5.3・付録 A | voicedock の `record_transition` は遷移表を検査していなかった。表を強制する v1 のままだと起動時の復旧（表に無い 7 辺）が必ず `IllegalTransition` で失敗する → `TransitionKind`（normal / recovery）と復旧写像の表を追加 |
| F-02 | 誤 | §8.9.2・§8.9.5 | 「ロックが揃っていないなら RAW_SAVED→COMPLETED」は、デバイスを抜いた後に RAW_SAVED になる通常の流れで全 Part を COMPLETED に流し、削除が起きない → 設定上の準備（待たない）とデバイスの観測（未接続は待つ）の 2 段に分けた（voicedock と同じ判定） |
| F-03 | 誤 | §5.6・付録 A | voicedock は `MERGED→ANALYZED`（解析の再利用）・`ANALYZED→FAILED`・`CLEANUP→SOURCE_DELETING` を表の外で使っていた → ★`MERGED→ANALYZED` を足し、他の 2 つは経路を直して不要にした |
| F-04 | 誤 | §8.5 | 指紋の定義が voicedock と違った（`JSONEncoder` は Date を数値で出す）→ voicedock と同一定義（Python `json.dumps` 互換の `PyJSON`）にし、golden に実測値を置いた |
| F-05 | 誤 | §8.6 | Daily の本文の並び: Timeline は `order` の中の 1 節で、既定では summary の次（v1 は「セクションの後に Timeline」） |
| F-06 | 誤 | §10.5・付録 B.1 | reaper 層のテストを普通のディレクトリで回すと、RV-06（マウント点・msdos）で全部弾かれ、RV-08 以降と正の対照が空振りで緑になる → R1 / R2 / R3 の 3 層に分けた |
| F-07 | 誤 | §9.4 | PT-04 が llama-server の `-c` を誤検知、PT-05 が `SELECT … WHERE status = ?` を誤検知 → 検査を作り直し、llama-server は長い形のフラグにした。PT-16〜21 を追加 |
| F-08 | 誤 | §6.2・§6.4・§0.5 | CV 番号が voicedock の V と衝突・欠番を再利用していた → 意味が同じものだけ継承、全検証に ID を振った完全な表（CV-01〜59）を追加。V-33 相当（削除有効なのに ro）を CV-33 として追加 |
| F-09 | 誤 | §0.5・付録 B.1 | ND 番号は再割当てしていない（voicedock の番号をそのまま引き継ぐ）。「対応表あり」を削除 |
| F-10 | 誤 | §6.2 | `llm.contextSize ≥ 8192` では 20,000 文字のチャンクが収まらない → CV-51（`≥ maxChars + maxOutputTokens + 2048`） |
| F-11 | 誤 | §8.9.5 | backoff の添字は `[min(max(a,1),n)-1]`（a = 0 と 1 がどちらも先頭の値）。根拠 B は最小値ではなく先頭の値 |
| F-12 | 誤 | §12.3 | E2E-17 がどのタスクにも無かった → T-42 に追加。乗り換えの E2E-18 を追加 |
| F-13 | 誤 | §3.4 | AtomicFile が VDCore にあると reaper が結果を atomic に書けない、ModelCatalog が VDModels にだけあると CV・Worker・診断が使えない、VDDevice が AVFoundation の probe を import できない → 置き場所を決め直し、import の完全な許可リストにした |
| F-14 | 欠 | §4.6 | `TargetIdentity.verify` が Verdict だけを返すと reaper が unlink の前にパスを開き直し TOCTOU が戻る → 検証済みの親 fd を貸す API にした。`f_mntonname` は realpath で比べる |
| F-15 | 欠 | §5.4・§8.1・§8.3 | 再コピー（needs_recopy）と requeue の順序: 起動時の requeue が再コピーより先に走ると SKIPPED（終端）に落ちる → requeue から除外し、再コピーの完了を 4 つ目の契機にした。snapshot はコピーの後に公開し、接続の立ち上がりは `connectEpoch` で数える |
| F-16 | 欠 | §8.1 | 再マウントや同名のボリュームでパスに ` 1` が付くと partkey が変わり全件を再コピーする → 規則 8（ボリューム名との一致）。`:` を含む名前 → 規則 9。`opendir` の失敗は errno によらず not_listable |
| F-17 | 欠 | §8.9.6・§8.9.7・§8.9.9 | 回収と期限切れが Session の Part に限られ、過去分の Part を二度と回収できなかった（voicedock の欠陥）→ 全件対象。手動で消した分は未接続を対象外にした |
| F-18 | 欠 | §8.9.5・§4.4 | 要求の書き込み順（ID が先）と「待っている」の定義（ID の有無だけ）、要求ファイルが書けないとき（DELETE_QUEUE_FAILED）の扱いを明記 |
| F-19 | 欠 | §2.1・§8.9.4 | アプリが落ちて reaper だけが生き残った場合の「reaper の後の観測」の保証 → `state/reaper.lock` の flock |
| F-20 | 欠 | §8.9.4 | reaper の終了コード、reaper.conf の書式（fail-closed）、処理の順序（RV-02a / 02b）、processed.log とログの形式、`--version` の扱い |
| F-21 | 欠 | §5.7・CR-23・CR-24 | Python と Swift の違い（文字数はコードポイント、strip の空白集合、splitlines、casefold、JSON の書式、時刻の整数演算）→ `PyText` / `PyJSON` / `Instant` を VDCore に 1 か所。T-45 を追加 |
| F-22 | 欠 | §5.4・§8.7・付録 A.3 | モデル未入手・Vault 不在で全 Part が FAILED になる / E2E-04「戻すと再開」を満たせない → 工程の前のガード（遷移せずに待つ）と要対応 |
| F-23 | 欠 | §8.8 | 所有を DB だけで判定すると、rename の後・DB 更新の前に落ちたとき ` (2)` が増え続ける → 「session_key が一致し鍵がすべてこの Session の Part」なら上書き |
| F-24 | 欠 | §8.3・§8.4・§8.5・§8.6・§8.7 | 失敗文言・書き込み順・JSON の形・検証の打ち切り・タグの正規化・Timeline の保存と読み戻し・Vault の確認の順序など、voicedock の実装の逐語を追記 |
| F-25 | 欠 | §7.2 | DDL を逐語で掲載。`schema_version` 表を作らない、backup の名前と条件、`updated_at` の更新規則、行の作成も events に書く |
| F-26 | 欠 | §8.11 | 診断の 4 値と実行規則、DR-17（アプリの署名）、DR-09 を Worker の直列ループで実行、コピー中の沈黙の誤報（#117）の回避、要対応の定義（FAILED とログイン項目は要対応にしない） |
| F-27 | 欠 | §8.2・§8.5 | llama-server を起動したままにする API（`spawn` / `RunningProcess`）、API キーはファイル渡し（`ps` で見えない） |
| F-28 | 欠 | §10.1・§10.8 | `swift test` はタグで絞れない → 環境変数と `.enabled(if:)`。URLProtocol の差し替えは注入したセッションにしか効かない → URLSessionConfiguration のファクトリを注入。CI の最後のステップで ND と Policy を二度走らせない |
| F-29 | 曖 | §4.1・§4.3 | 正規表現は `[0-9]` と全体一致、relpath は voicedock より厳格（`./a`・`a//b` を拒否）、日時は整数範囲で判定 |
| F-30 | 曖 | §8.1・DR-13 | 共存ガードの `launchctl print` の 0 は「LaunchAgent が登録されている」（常駐ではない）。文言を修正 |
| F-31 | 曖 | 付録 C・D | reaper の BSD sed の素通りは観測値側だけ（設定値側の比較は効いていた）。request_id は実装がローカル時刻で `Z` も無かった |
| F-32 | 事 | §3.3・§10.8・§11.2 | Xcode 27.0 / Swift 6.4、tools-version 6.2 と `treatAllWarnings`、GRDB 7.11.1・Yams 6.2.2、whisper.cpp v1.9.4 のコミットは `927cfce…`（`7d75b149…` はタグオブジェクト）、llama.cpp b11033、`LLAMA_CURL` は廃止済みで `LLAMA_OPENSSL=OFF` と `--offline`、`LLAMA_USE_PREBUILT_UI=OFF`、CI は `xcode-27` ラベル、actions の SHA |
| F-33 | 事 | §8.10 | whisper / VAD モデルの URL・sha256・bytes を HF API の実値で記入。Qwen3-2507 の Q4_K_M は公式の GGUF が無い（unsloth / lmstudio-community） |
| F-34 | 事 | §8.4 | whisper.cpp は不明な引数・読めない音声でも終了コード 0 を返すことがある → 成功は「終了 0 かつ JSON が在って読める」 |
| F-35 | 事 | §10.4 | golden の生成はホストの `uv` で動く（Docker 不要）。voicedock の LLM fixture は応答 2 本だけで transcript の fixture は無い → T-24 で作る |
| F-36 | 欠 | §12.2 | P0-12（Vault が書類フォルダ・iCloud Drive にあるときの TCC）を追加。P0-02 に再マウント後のパスの確認、P0-01 にシステム設定の URL の確認を追加 |
| F-37 | 誤 | §6.1・§8.9.8 | （独立レビューで発見）無効化が自分の CV-30 に阻まれて止められなかった → 書く前に「これからの reaper.conf」で検証、無効化は reaper.conf を先に、片方だけ有効な状態は起動時に無効側へ自動修復 |
| F-38 | 誤 | §4.6・§10.5 | アプリ層の正の対照が、事前確認のマウント点検査で必ず弾かれていた → `VolumeOpener` を注入。PT-22 |
| F-39 | 誤 | §9.4 | PT の字句照合が `SafeUnlink.remove(` などを誤検知した → トークン単位の完全一致 |
| F-40 | 誤 | §10.3・§8.11・付録 A.1・B.1 | SPEC 同期の読み方と表の形が合わず、DR・状態が空で緑になった → DR の ID を先頭の列へ、状態を表へ、ND-30 を打ち消し、層ごとのテスト数の規則 |
| F-41 | 欠 | §5.6・付録 A.2 | 削除段の間に増えた Part が Daily に載らない → 削除段からの再オープン（★3 辺） |
| F-42 | 欠 | §2.1・§8.1・§8.9.4・§8.9.6 | reaper.lock の待ち方（reaper は NB で取れなければ終了コード 4、IngestService は 1 秒ごとに 130 回）、`scanNow()` の戻り値、actor の中で長い同期処理をしない（`BlockingIO`） |
| F-43 | 欠 | §5.4・§8.9.2・§8.9.4・§8.9.5 | requeueRecopied の detail と resetRetry、readiness のキャッシュ、replayed が DELETED の結果を上書きしない、結果待ちの RAW_SAVED がある Session は完了させない |
| F-44 | 欠 | §8.3・§8.4・§8.6・§8.7・§8.10 | Int16 の WAV の書き方、whisper のシグナル終了、`.md` を含む tmp 名、Raw の書き手と検証側で同じ Part 集合、`inboxRetain = raw_saved` の動作、モデル取り込みの一時名、照合キャッシュを VDCore へ |
| F-45 | 誤 | §5.7・§8.5 | （チケット執筆で発見）`JSONSerialization` の読み取りはキーの順を失い U+FEFF を落とし NaN を受けない → `PyJSON.decode`。`Double.description` は 2^53〜1e16 で Python と違う → `formatDouble`。Swift の文字列比較は正準等価 → スカラー列で比べる所を明記。`PyRound` |
| F-46 | 誤 | §7.1 | GRDB がプールを作った後に `synchronous = NORMAL` に戻す → 作った後に FULL を設定し直して確かめる。`Row` の非 Optional の添字はプロセスを落とす |
| F-47 | 誤 | §5.1 | 不変条件「進行中 ∩ 終端 = ∅」は Part の SOURCE_DELETING で成り立たない → 除いて検査 |
| F-48 | 欠 | §3.4・§4.6・§8.1・§8.3・§8.4・§8.5・§8.7・§8.15 | `Synchronization` の許可、openVolume のその他の errno、列挙の不完全・errno・再マウント中の抜去・launchctl の失敗、SHA 記録なしの文言、transcript の書き込み失敗、前提の確認の分担、切り詰めの前置き、起動失敗の文言と API キーの後始末、Vault の stat の EPERM、redaction の例外の意味 |
| F-49 | 欠 | §9.4・§10.8・§12.1・§12.3 | PT-06 は大小を区別・語が空なら違反、PT-09 に `.now`、PT-17 の語、SPEC.md 必須、ブランチ保護の制約、600 行の例外、T-04 は PT-22 まで |
| F-50 | 欠 | 付録 D | X-32〜X-35（夏時間の表示、JSON の深さ、YAML の重複キーなど安全側の差、ログの引用） |
| F-51 | 欠 | §5.3・§5.6・§8.3・§8.4・§8.9.5・§8.9.9・付録 A.4・付録 D | （第 2 段のチケット執筆で発見）解析の再利用で `analysis_path` を書く（X-36）、遅れた start では inbox の孤児を消さない、`needs_recopy` は遷移の前に書く、根拠 B は readiness を先に見る、後追いの除外理由 2 つ、reaper の `exit` の書き方、`pipeline_paused` のレベル、DB の例外のログ |
| F-52 | 欠 | 00-api-map | ConfigStore はクロージャで reaper.conf の観測を受ける（LockEvaluator は後から作られる）、引数ラベルに `reaperConf` を使わない（PT-11）、WorkerDependencies は `IngestPort` / `LLMServerControl` を注入で受け `zone` を持たない、`RecordingRow.errorCodeRaw`（未知のコードを警告行に出すため）、LockEvaluator は `reaper` を持つ、BacklogPlan は `BacklogSkip` の配列 |
| F-53 | 欠 | §6.1・§8.9.4・§8.9.8・§8.10・§8.13・§8.11・§8.15・§11.1・§11.3・§11.4・§12.4・付録 A.4・付録 B.3・§14 | （第 2 段の B3〜B6 のチケット執筆で発見）`reconcileLock1` は reaper.conf だけを書く、reaper の書き込み失敗の扱いと `reaper_completed requests=0`、trash の表示条件、ダウンロード前の `isPresent`、乗り換えの 2 規則、要対応に `toolMissing`、起動に失敗したときの `NSAlert`、Info.plist の 2 キーと TCC 文の逐語の共有、本体の `--identifier`、リリースの作り方、削除のゲートの 5 番目（削除 ON で E2E-01〜09 を再実行）、`✗` は U+2717、E2E-11 は 0 件にならない、README に載せる RK |
| F-54 | 誤 | §6.2・§6.4 | （ConfigEffect の設計で発見）`sections.summary.maxItems` と `sections.timeline.maxItems` はどこからも読まれない「効かない設定」だった（voicedock にも無い）→ この 2 つのキーを無くした（`maxItems` を持つのは 5 節だけ） |
| F-55 | 誤・欠 | 00-api-map・目次・付録 A.4 | （最終の整合確認で発見）T-25 と T-45 の循環（`GoldenCase.orderedObject` は T-45 の extension に）、Phase 7 の UI・診断が Phase 8 の型を使っていた（`LockObserving` と既定の無効実装を T-32 に置き、T-36 が差し替える）、`reaperConf` の引数ラベル（PT-11）、`RecordingRow.errorCodeRaw`、`ChatTransportFactory` の引数、`BacklogAction` の戻り、`ConfigStore.init`、`ModelManager` / `ModelDownloader` の init、`WorkerDependencies` の末尾に足す順、TestSupport の置き場所、目次の前提の抜け、`normalize_failed reason=input` ほかの reason 語 |
| F-56 | 事 | §2 D-6・§10.8・§12.2・§14 | （T-02 の着手時に利用者が決定）CI のランナーを開発機のセルフホストランナーにした。`sudo xcode-select` の代わりに `make check-toolchain`、`.diskImage` のテストは CI で走らせない、P0-10 は行わない、RK-06・RK-33 を書き換えた |
| F-57 | 事 | §9.4 | （T-04 のレビューで発見、利用者が承認）PT-08・PT-19 は `Swift.` 修飾の呼び出しも検出、PT-20 に `Regex` の語と `firstMatch(of:` などを追加（Swift 6 のスラッシュ正規表現リテラル対策）、PT-12 は `FileHandle(forWriting…` の接頭辞、PT-06 は補間の入れ子と raw 文字列。PT-03 の関数参照と PT-09・PT-17・PT-22 の暗黙メンバーは既知の限界として残した |
| F-58 | 事 | §2.1・§6.1・00-api-map §2.2・§3 | （T-09・T-11・T-12 の実装で発見、利用者が承認）子の終了の待ちに `waitpid(WNOHANG)` の予備のタイマーを併用（kqueue の登録前に終わった子の取りこぼし）、`ConfigLoader.load`・`ConfigStore.update` のラベルは `reaperConfObservation:`（PT-11）、地図に `ConfigViolation: Error`・`NewSession: Equatable`・`EntityType: CaseIterable` を明記。整数の位置の小数の CV-39 の表示を「型が違います」に揃えた |
| F-59 | 事 | §8.1 規則 5・§8.1（再マウント） | （P0-01・P0-02 の実測）`access(2)` は macOS 26.6 では TCC の拒否で EPERM になる（「成功する」は版による）。判定は従来どおり列挙で行う。実機の再マウントでは `-mountPoint` は使えない（アンマウントで `/Volumes/<名前>` が消える）ので本番は `useMountPoint: false` |
| F-60 | 事 | §1.2・§1.3・§7.2・§8.12・§8.13・§12.3・付録 B.3 | （2026-09-22 に利用者が決定）voicedock からの乗り換えを v1 で扱わない。§8.13（`ImportedKeysScanner`）と T-33・E2E-18 を取り下げた（番号は詰めない）。`imported_keys` の表と IngestService の除外は実装済みのまま残り、空の表として無害。§8.8 は残す |
| F-61 | 事 | §1.3・§2.1・§5.4・§8.1・§8.2・§8.11・§10.3・§12・付録 A.4・付録 B.3 | （2026-09-22 に利用者が決定）このアプリが完成したら voicedock は動かさないので、共存ガード（voicedock の Helper の LaunchAgent が登録されていたら取り込み・処理・削除を止める）を取り下げた。§8.1 の手順 1 は欠番、DR-13 は打ち消しの行、E2E-15 は取り下げ（番号は詰めない）。`coexistence_blocked`・要対応の `coexistenceBlocked` を消した。読み取り専用の再マウント・原本を `O_RDONLY` で開くことなど、ほかの取り込みの安全策は変えない |
| F-62 | 事 | §11.3 | （2026-09-22 に利用者が決定）dmg の作成を `hdiutil create -srcfolder`（内部でイメージを既定の場所に attach しうる）から、空の HFS+ イメージを `hdiutil attach -nobrowse -mountpoint` で `dist/` の中にだけマウントして `ditto` で書き、detach して `convert -format UDZO` する方式に変えた。マウントを伴わない `makehybrid -hfs` は全ファイルに `com.apple.FinderInfo` を付けて `.app` の署名が `codesign --strict` で落ち、`-udf` は `/Applications` への symlink が壊れるので却下した |
| F-63 | 事 | 付録 B.3 | （2026-09-22 に利用者が決定）E2E-11 の後半「手動で消した分の完了」を実機の試験から外し、T-41 の単体テスト（`BacklogPlannerTests` の resolveAbsent 系）で代えた。対象の `SOURCE_DELETE_PENDING` は reaper の拒否・期限切れ（`no_result`）・`still_in_inventory` でしか生じず、要求を書いてから reaper が動くまでが同じ tick の中にあるので、手の操作で確実に作れない。運用中に `SOURCE_DELETE_PENDING` が出たら docs/E2E.md §3.11 に記録する。E2E-11 は前半（過去分を削除対象にする）が PASS なら PASS とし、削除のゲート（§12.4 の 2）もそれで満たす |
| F-64 | 誤 | §8.9.2・§8.9.5・§8.9.9・付録 A.2 | （2026-09-22 に利用者が承認）削除が有効（`.configured`・`.writable`）なのに RAW_SAVED の Part の元ファイルがデバイスから消えていると、事前確認（`preIdentityCheck`）が永久に偽で要求が書かれず、削除段が `requested == 0` のまま `delete_attempts += 1` を繰り返して Session が COMPLETED にならなかった（「手動で消した分を完了にする」は SOURCE_DELETE_PENDING だけが対象で救えず、抜け道は削除の無効化だけ。CR-15・DEL-15/16 に反する）→ `requestDeletions` が、新鮮で**その Part の取り込み（updated_at）より後の** snapshot でデバイスが接続中で列挙でき relpath が一覧に無い RAW_SAVED の Part を、要求を書かずに RAW_SAVED→COMPLETED（detail `already_absent`、`source_delete_skipped recording_key=… reason=already_absent`）にする。`source_deleted_at` は入れない。未接続・列挙できない・snapshot が古い・取り込み前の snapshot のときは従来どおり待つ（一覧は深さの上限の外と読めないディレクトリを含まないので、そこでは消し損ねうるが録音は失われない）。遷移とログの語は既存のもの（A.2・A.4 の語は増やさない）。根拠 B（SKIPPED）は Session の完了を待たせず、不在の Part は要求の対象から外れるので同じ詰まりは無い |
| F-65 | 事 | §2.2・§8.9.8・§8.12・§12.3・§14 | （2026-09-23 に利用者が決定）パネルをカード型に作り直し、**主画面をスクロールなしで収める**。長い中身（元音声の削除・詳細と診断・要対応の多数・一般）は popover の中の別の画面に切り替え（「‹ 戻る」。窓は増やさない。D-7）、高さは中身に合わせる（`NSHostingController.sizingOptions = .preferredContentSize`。固定の 640pt をやめた。主画面に ScrollView を置かないので 1pt に潰れない。PR #100）。削除の有効化と根拠 B の「`ENABLE` を入力させる」を「赤いボタンを 3 秒長押しさせる」に変えた（クリック 1 回・チェックボックスでは通らない。途中で離すと取り消し。押している間はリングが満ちる）。UI は長押しの完了で `confirmation` に定数 `"ENABLE"` を渡し、`DeletionEnabler.enable(confirmation:)` の完全一致の判定は残す（安全の二重化）。`EnableError.notConfirmed` の文言は「赤いボタンを 3 秒長押ししてください」。無効化は確認なしの 1 クリックのまま。docs/E2E.md の E2E-10・E2E-17・§3.7（根拠 B）の手順を長押しに直した |
| F-66 | 欠 | §5.3・§5.4・§5.6・付録 A.2・付録 D | （2026-09-23 に利用者が決定）今すぐ要約を足し、0:00 の自動要約（`stale_day`）を廃止した。Session を閉じる契機は、無通信 `idleCloseSeconds` の `idle`（自動。日付が過去の OPEN も同じ規則で、起動時の `closeIdleSessions` も同じ）と、パネルの今すぐ要約（手動）の 2 つだけ（X-37）。今すぐ要約は `WorkerJob.summarizeNow(reply:)` を `closeIdleSessions` の段の終わりで行い、LLM のガードを積まずに判定して当たれば何も閉じずに失敗、通れば押した時点の OPEN を日付を問わず `OPEN→READY`（detail `summarize_now`）にして閉じた数を返す。要約は同じ tick の `processReadySessions` が進め、その後に届いた同じ日の録音は既存の再オープン（§5.6）で要約し直す。辺・ログのイベント・設定キーは増やさない。パネルのボタンと `AppServices` の口はパネルの作り直しの後に足す |
| F-67 | 誤 | §8.1・§8.9.5 | （2026-09-23。issue #97。F-64 のレビューで判明）`DeviceReader.scan` は `lstat` の失敗を errno によらず黙って飛ばしていたので、`complete == true` でも一覧が欠けることがあり、F-64 の自動完了（一覧に無い RAW_SAVED を完了にする）の根拠として弱かった → `lstat` が `ENOENT` 以外で失敗した項目があれば `complete = false`（`readdir` の途中の失敗は従来どおり偽）。`ENOENT`（列挙から `lstat` までの間に消えた）は飛ばして偽にしない。深さの上限の外は列挙も `lstat` もせず、偽にもしない（上限の外の録音は Part にならず、削除にも F-64 にも関わらない。`maxScanDepth` を下げる前に取り込んだ Part だけは完了しうるが消さない側）。偽のデバイスは従来どおり `devices` に載せず `unavailable`（`not_listable`）。取り込みは続け、前回の snapshot の一覧は持ち越さない（一時的な失敗は次の走査で戻る）。`notListableErrno` は規則 5 の errno だけ。`DeviceReader` の `lstat` は internal の `init(lstat:)` で差し替えられる（テストが失敗を注入する。公開 API は増やさない）。理由語・ログの語・設定キーは増やさない |
| F-68 | 欠 | §4.1・§4.4・§5.4・§8.4・§8.7・§8.12・§10.3 | （2026-09-23。issue #18。利用者が任せた）SPEC 同期を広げた。PLAN に表を置き（§4.1・§4.4 の名前の正規表現、§5.4 の tick の段、§8.12 の節と画面・はじめにの項目・ui-state.json の鍵。§8.12 のアイコンの表には `IconState` の列を足した）、`tools/spec/make-spec.py` が SPEC の S10（名前の正規表現）・S11（whisper-cli の argv。§8.4 の `text` フェンスをそのまま）・S12（保存検証 RN / DN。§8.7 の表）・S13（tick の段）・S20（パネルの節と画面）・S21（アイコン）・S22（はじめに）・S23（ui-state.json）に写す。付録 B.2 の理由語は既存の S8 の列から読む。照合のテストは実装を import できる各モジュールのテストに置き（PolicyTests は TestSupport にしか依存しない。Package.swift は変えない）、`SpecDocument` の読み取り口は extension で足した（00-api-map §15）。RN / DN はテストの表示名の先頭に ` / ` で ID を並べてよい（§10.3）。S20 は F-65 の後のカード型に合わせ、T-30 の案の「チケット」の列をやめて主画面での出し方と `PanelScreen` の case を持つ。要対応（§8.11）・状態の詳細・reaper の終了コードとイベント・削除の有効化と無効化の段は、PLAN が散文か実装に列挙できる列が無いので足していない（T-32・T-37・T-40 に理由を書いた） |
| F-70 | 誤 | §2.3・§8.12 | （2026-09-23。issue #105。利用者との実機の動作確認で判明）パネルの「最終接続」を AppModel のメモリにだけ持っていたので、アプリを再起動すると「まだありません」に戻った → デバイスを最後に観測した時刻を `<HOME>/ui-state.json` の `lastConnectedAt`（epoch ミリ秒の整数。一度も観測していなければキーを書かない）に残し、起動直後の（メモリに値が無い）`read` はその値を使う（`LastConnected.resolve`）。書くのは AppModel の `refresh` で、この起動で最後に書こうとした値（無ければファイルの値）と違うときだけ（時計が戻った値も書く。差は桁あふれでトラップさせない）、接続中は観測時刻が 60 秒以上動いたときだけ、切れたら最後に見た時刻を 1 回だけ（`LastConnected.valueToSave`）。refresh が重なっても、この起動で書いた `loginItemDecided = true` と最終接続を古い read の値で戻さない（書くたびに AppModel が覚えた値と合わせる）。書けなくても表示は変えず、同じ値を書き直し続けない（「今はしない」の `uiStateSaveFailed` とは別）。`schema` は 1 のまま（足した鍵は任意で、F-70 より前の版の読み手は未知の鍵として無視する）。`lastConnectedAt` が無い・型が違う・0 以下のときはそれだけを nil にし、`loginItemDecided` を失わない。DB の取り込みの時刻から導く案は、新しい録音が無かった接続を拾えないので採らない。表示の文言は変えない |
