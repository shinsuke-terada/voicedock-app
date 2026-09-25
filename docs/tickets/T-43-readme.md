# T-43 利用者向け README と文書テスト

> （F-98。2026-09-25。利用者の依頼「README に書かなければならない内容を書いた？」）`### データを初期化する`（F-95）を `### バックアップ` の後に足し（見出しは 26 個。下の §4.1 の表も直した）、「状況を見る」の「詳細・診断」に「データの初期化」を足した。
> RK-28 の文（逐語 V-2 と既知の制約の表）を、名前を変えると残っている録音をもう一度取り込んで「重複」になることに直した（F-94 のレビューの指摘）。「困ったとき」の「録音が取り込まれない」に、`config.json` を変えた後はつなぎ直すことを足した。

> （F-94。2026-09-25。利用者の決定）取り込む名前の既定が `VOICEDOCK` になったので、README の「動作環境」の名前・改名の手順の一文・⑤・トラブルシュートの名前を `VOICEDOCK` にした（下の逐語 V-2 と §4.5 も直した）。

| 項目 | 値 |
|---|---|
| ID | T-43 |
| 題 | 利用者向け `README.md`（導入・TCC・削除の有効化と戻し方・既知の制約・トラブルシュート）と文書テスト |
| Phase | 9 |
| 前提 | T-42（削除 ON の E2E とゲート。README に書く文言を実機で確かめてから書く） |
| 見積もり | `README.md` 約 290 行（文書）＋ `Tests/PolicyTests/ReadmeTests.swift` 約 220 行 |

## 1. 目的

T-01 が置いた仮の `README.md` を、**利用者向けの正本**に置き換える。**散文の数字と参照が腐らないことを機械で守る**
（voicedock では診断の件数が実装・SPEC・README の 3 か所に散り、同じずれが 2 度起きた。`詳細仕様書 v5.2` の表記は v5.30 まで放置された）。

## 2. 参照

- PLAN §1.1（利用者から見た動き）、§1.2〜§1.5（含める・含めない・優先順位・動作環境）、§2.3（`<HOME>`）、§8.9.1〜§8.9.3・§8.9.8・§8.9.9（削除）、§8.11（診断 DR・要対応）、§8.12（パネル）、§10.8（CI と `.diskImage`）、§11.1（TCC の説明文）、§12.4（削除のゲート）、§14（RK。既知の制約）
- PLAN §10.3（文書テスト: 「診断は 16 件」などの散文の数字も機械で見る）
- 先行チケット: T-05（`SpecDocument`・`SpecIDKind`）、T-04（`MarkdownDocument`）、T-01（`README.md` の仮版・`Makefile`・`PackageRoot`）、T-34（`scripts/*`・dmg）、T-35（`docs/E2E.md`）、T-42（`docs/E2E.md` のゲート）、T-32（診断の実装）
- 移植メモ `docs/porting-notes/V6-doctor-ci-e2e-docs.md` §4.4（`test_readme.py`）
- voicedock@d3d595e `README.md`（章立ての見本）、`tests/unit/test_readme.py`（件数・参照・版の直書き）

## 3. 作るもの

| パス | 内容 |
|---|---|
| `README.md` | T-01 の仮版を**全面的に置き換える**（下記 §4） |
| `Tests/PolicyTests/ReadmeTests.swift` | 下記 §5 の全文 |
| `docs/DEVELOPMENT.md` | （F-93）README から分けた開発者向けの節（コマンド・文書・ディスクイメージのテスト・ライセンスの表示・状態） |
| `LICENSE`・`NOTICE` | （F-93）本体のライセンス（Apache License 2.0 の全文）と著作権表示 |
| `THIRD_PARTY_NOTICES.md` | （F-93）同梱物の著作権表示とライセンス文（上流のものをそのまま） |
| `Tests/PolicyTests/LicenseFilesTests.swift` | （F-93）上の 3 つと、`make-app.sh`・`Resources/bundle-manifest.txt` の同梱の検査（§5 の 2 つ目の表） |
| `scripts/make-app.sh`（変更。F-93） | 3 つの文書を `Contents/Resources/` に入れる 3 行を足す（§4.18）。ファイルの持ち主は T-34 |
| `Resources/bundle-manifest.txt`（変更。F-93） | 許可リストに 3 行を足す（§4.18）。ファイルの持ち主は T-34 |

## 4. `README.md` の章立てと中身

### 4.0 書き方の規則

1. **見出しは下の表の文字列を一字一句そのまま使う**（`theHeadingsAreInOrder` が順序込みで見る）
2. **件数を直書きしない。**`docs/SPEC.md` の表から数えた値を書き、テストが照合する（§4.11）
3. **版を直書きしない。**計画書・SPEC の版番号を書かない。`X.Y.Z` の形の数は、`Vendor/versions.env` に在るもの（whisper.cpp / llama.cpp の版）以外は書かない
4. 参照するファイルは**リポジトリからの相対パス**（`docs/E2E.md`）。存在しないパスを書かない
5. `make <ターゲット>` は `Makefile` に在るものだけ
6. **voicedock（参照実装）の語を持ち込まない**: `docker` / `Docker` / `Helper` / `LaunchAgent` / `compose` を書かない（voicedock からの乗り換えの章は置かない。PLAN §8.13・F-60）
7. 日本語。利用者は「Mac を普通に使える人」。**シェルを開かなくても導入が終わる**ように書く（トラブルシュートと「データと更新」だけシェルを使う。F-93）

### 4.1 見出し（この順・この文字列）

> **F-93（2026-09-25。利用者の決定）**: README を利用者向けだけにした。`## 何が動いているか` を `## できること` に、`## データの置き場所`・`## 保守` を `## データと更新` にまとめ、使い方に `### 設定を変える`、末尾に `## ライセンス` と `## 開発者の方へ` を置いた。
> `## 開発`・`## 状態` は `docs/DEVELOPMENT.md` へ移し、`## 出典`（T-49）は `## ライセンス` にまとめた。下の §4.3・§4.12〜§4.17 はこの形で読む。

| # | 見出し | 深さ |
|---|---|---|
| 1 | `# VoiceDock for Mac` | 1 |
| 2 | `## できること` | 2 |
| 3 | `## 必要なもの` | 2 |
| 4 | `## インストール` | 2 |
| 5 | `### 1. dmg から入れる` | 3 |
| 6 | `### 2. 最初の起動と、許可の出し方` | 3 |
| 7 | `### 3. 「はじめに」を上から済ませる` | 3 |
| 8 | `## 使い方` | 2 |
| 9 | `### できあがるもの` | 3 |
| 10 | `### 状況を見る` | 3 |
| 11 | `### 設定を変える` | 3 |
| 12 | `## 元音声の削除` | 2 |
| 13 | `### 三重ロック` | 3 |
| 14 | `### 削除の根拠` | 3 |
| 15 | `### 有効にする` | 3 |
| 16 | `### 元に戻す` | 3 |
| 17 | `## 困ったとき` | 2 |
| 18 | `## 既知の制約` | 2 |
| 19 | `## データと更新` | 2 |
| 20 | `### データの置き場所` | 3 |
| 21 | `### バックアップ` | 3 |
| 22 | `### データを初期化する` | 3 |
| 23 | `### 更新` | 3 |
| 24 | `### アンインストール` | 3 |
| 25 | `## ライセンス` | 2 |
| 26 | `## 開発者の方へ` | 2 |

### 4.2 `# VoiceDock for Mac`（導入）

- 1 行の説明: **DJI Mic 3 で録音した音声を Mac へ挿すだけで、文字起こし・要約して Obsidian に残す。**
- 流れの図（```text のフェンス）:

```text
DJI Mic 3 で録音 → 帰宅 → Mac へ USB 接続 → （以降すべて自動）
```

- 「挿したあとに人がすることはありません」の段落
- **逐語 V-1**: `**クラウドの AI は使いません。音声もテキストも外部へ出ません。**`
  - 続けて「外部へ出さないことは方針としてだけでなく、テストで強制しています（ネットワークを使うのはモデルのダウンロードだけで、そこ以外の経路が無いことを静的検査が見ています）」

### 4.3 `## できること`

できることの箇条書き（取り込み・文字起こし・要約・元音声の削除（任意））に続けて、表（工程 / 使うもの）。**すべて Mac の中で動くことが分かる形**にする:

| 工程 | 使うもの |
|---|---|
| デバイスの読み取り・コピー | VoiceDock 本体（macOS の標準機能だけ） |
| 16 kHz への変換 | AVFoundation（Mac 内蔵） |
| 文字起こし | whisper.cpp（Metal） |
| 要約・タスク抽出 | llama.cpp の `llama-server`（Metal） |
| ノート生成 | VoiceDock 本体 |
| 元音声の削除 | `voicedock-reaper`（**既定では導入されない**別の実行ファイル） |

- メニューバーに常駐し、Dock には出ないことを 1 行で

### 4.4 `## 必要なもの`（PLAN §1.5）

| | |
|---|---|
| Mac | Apple Silicon、macOS 15.0 以上 |
| メモリ | 選べる LLM がメモリ量で決まる。既定のモデルは 32 GB 以上 |
| ディスク | モデルに 3〜20 GB、作業領域に数 GB |
| Obsidian | Vault を 1 つ作り、**一度 Obsidian で開いておく**（`.obsidian` が作られる） |
| 録音デバイス | DJI Mic 3（USB で Mac につなげること。F-93） |

- **逐語 V-2**: `**使い始める前に、デバイスのボリューム名を決めてください。**`（RK-28）
  - 続けて「取り込みの後にボリューム名を変えると、それ以前に取り込んだ録音は削除の対象から外れ、デバイスに残っている録音は次につないだときにもう一度取り込まれて「重複」になります（「無音・重複も消す」が有効なら、その元音声は消えます。文字起こしは前に取り込んだ分が Vault に残っています）。後から名前を戻しても元には戻りません。名前を変えるなら、先に「データを初期化する」（下の「データと更新」）で取り込みの記録を消すと、新しい名前で最初から取り込み直せます。`NO NAME` や `DJIMIC3` のままなら、Finder かディスクユーティリティで改名してから使い始めてください。**アプリはデバイスに書き込まないので、改名はアプリからは行えません。**」

### 4.5 `## インストール`

#### `### 1. dmg から入れる`

- `VoiceDock-<版>.dmg` を開き、`VoiceDock` を `Applications` へドラッグする、と書く（**具体的な版番号を書かない**）
- （F-99）その前に、Releases の最新版へのリンク（`https://github.com/shinsuke-terada/voicedock-app/releases/latest`）と「非公開リポジトリなので、招待されてサインインしている人だけが開ける」ことを書く。
  dmg を開くと左に `VoiceDock`・右に `Applications` のウィンドウが出ること、コピーの後はディスクイメージ（`VoiceDock <版>`）を取り出すことを書く
- 「配布物は Apple の公証を受けています。初回起動で警告が出る場合は、いったん dmg を閉じて開き直してください」

#### `### 2. 最初の起動と、許可の出し方`

**この章が TCC の説明。**次の 3 つを順に書く:

1. **リムーバブルボリューム**: 初めてデバイスを挿したときに「VoiceDock がリムーバブルボリューム上のファイルにアクセスしようとしています」が出る。**「許可」を押す**。
   ダイアログに出る説明は `録音デバイスから音声を読み込むために使います`（`Info.plist` の逐語と一致させる）
   - 拒否した場合の戻し方: **逐語 V-3**: `システム設定 → プライバシーとセキュリティ → ファイルとフォルダ → VoiceDock → リムーバブルボリューム`
   - パネルの「要対応」からこの画面を開くボタンが出ることも書く
2. **Vault のあるフォルダ**: Vault を書類・デスクトップ・ダウンロードのどれかに置いていると、同じ形の許可を求められることがある（P0-12 では、NSOpenPanel で選んだ Vault は再起動後もダイアログ無しで書けた）。説明は
   `Obsidian の保管庫がこのフォルダにある場合に、ノートを書き込むために使います`
3. **ログイン時に起動**: 「はじめに」の 4 つ目で選ぶ。システム設定の「ログイン項目」に承認待ちが出た場合はそこで許可する

- 注意の段落: 「**許可はアプリの署名に結び付いています。**配布物を入れ替える（新しい版に更新する）と、許可はそのまま引き継がれます。
  自分でビルドしたものと配布物を行き来すると、許可を出し直すことがあります」

#### `### 3. 「はじめに」を上から済ませる`

パネルの「はじめに」の 5 項目を順に説明する（① Vault を選ぶ ② Whisper モデルを入手 ③ LLM を選んで入手 ④ ログイン時に起動 ⑤ デバイスの名前を変える。名前が `VOICEDOCK` でないデバイスがつながっているときだけ出て、完了にはならない。F-81・F-94）。
モデルのダウンロードは数 GB あり時間がかかること、途中で中断してよい（再開する）ことを書く。

### 4.6 `## 使い方`

- **逐語 V-4**: `**録って、挿す。以上です。**`
- 手順の図（```text）:

```text
1. DJI Mic 3 で録音する
2. Mac へ USB で挿す
3. 待つ（メニューバーのアイコンが動く）
4. Obsidian にノートが増える
```

- **逐語 V-5**: `**コピーが終われば抜いて大丈夫です。**`（以降の処理はコピー済みのファイルから進む）
- **要約の契機（F-66。0:00 の自動要約は廃止した）**: その日の録音に動きが無いまま `session.idleCloseSeconds`（既定 1800 秒）たつと自動で要約する。待たずに要約したいときはパネルの「状態」の「今すぐ要約」
- 注意: 「**接続すると録音は自動的に停止します**（DJI Mic 3 の仕様）。録音中に挿すとその 1 本は途中で切れます」

#### `### できあがるもの`

| ノート | 場所 | 中身 |
|---|---|---|
| Raw ノート | `Daily/Voice/Raw/<yyyymmdd>/` | 文字起こしの全文。時刻の見出し付き |
| Daily ノート | `Daily/Voice/Wiki/<yyyymmdd>/` | 要約・Timeline・キーポイント・タスク・決定事項 |

- **逐語 V-6**: `Raw ノートと Daily ノートは自動で作り直されます。**手で書き加えた内容は次の再生成で失われます。**`（RK-18。書き足したいことは別のノートに書き、リンクで結ぶ）

#### `### 状況を見る`

メニューバーのアイコン（待機中 / 取り込み中 / 文字起こし・要約中 / 要対応 / 削除が有効）と、パネルの「状態」「要対応」「詳細・診断 → 状態の詳細」を説明する。

### 4.7 `### 設定を変える`（F-93。旧 4.7 は欠番だった）

- パネルの ⚙ から変えられること、変えなくても使えること
- 話者分離（⚙ →「一般」。既定はオフ。`**話者A**: …` の行。名前は付けず録音ごとに振り直す。T-51 の文）
- 要約の指示（⚙ →「要約プロンプトを編集…」。3 本・`{schema_block}` と `{custom_instructions}` は消さない・次に要約する日から・「既定に戻す」。F-92 の文）

### 4.8 `## 元音声の削除`

- **逐語 V-8**: `**既定では削除しません。**デバイス上の録音はそのまま残ります。`
- **逐語 V-9**: `**元音声の削除は、Raw ノートの検証を通った録音だけを対象にします。**`（要約（Daily ノート）は待たない。要約は元音声を使わないため）

#### `### 三重ロック`

| ロック | 内容 |
|---|---|
| 1. 設定 | アプリの設定と、削除モジュールの設定ファイルの**両方**で有効にする必要がある |
| 2-A. 実行できる場所に無い | 削除を行うプログラムは、有効化するまで**実行できる場所に置かれない**。置かれた後も、起動する前に毎回、署名と版を確かめる |
| 2-B. OS レベル | デバイスは**読み取り専用**で再マウントされる（有効にするまで、OS が書き込みを拒む） |

- 「さらに、削除の判断（アプリ）と実行（別の実行ファイル）を分け、**実行側が判断を信用せず 14 項目を独立に再検証します**」
  - 「14 項目」は SPEC の `S8`（RV）の件数。**直書きせず数えた値を書く**（§4.11）
- 「片方だけ解除された状態は起動時に見つけて、安全な側（無効）へ揃えます」

#### `### 削除の根拠`

| 場所 | 確かめ方 |
|---|---|
| Obsidian の Raw ノート | 実ファイルを読み直してハッシュを照合し、その録音の鍵が載っていることを確認 |
| アプリの中の文字起こし JSON | **無期限に保持**され、Raw ノートの再生成元になる |

- 「**どちらか一方でも欠けていれば削除しません。**」
- 「無音・重複と判定した録音は、**別の操作で有効にしない限り**消しません」

#### `### 有効にする`

- パネルの「元音声の削除」で行うこと、事前確認が出ること、**赤い「有効にする」を 3 秒押し続ける**こと（クリック 1 回・チェックボックスでは有効にならない。途中で離すと取り消し。F-65）
- **逐語 V-10**: `**消した録音は戻りません。**`
- 「**読み書きできるようになるのはデバイスを挿し直した後です**（それまでは消えません）」
- 有効な間はメニューバーのアイコンの右上に赤い点が**常に**出ること（F-91 で `trash` の印から変えた）。抜く前に Finder で取り出すこと（F-93）
- 「有効にする前に溜まっていた録音は、パネルの「詳細・診断 → 過去分を削除対象にする」で後から対象にできます（**先に件数のプレビューが出ます**）」

#### `### 元に戻す`

- 「**確認は求められません。**押した時点で止まります」（止めたいときに止められること）
- 止まる順（消す能力に近いものから）: 削除モジュールの設定を無効 → 削除モジュールを取り除く → アプリの設定を無効 → 未処理の削除要求を取り下げ → **接続中のデバイスを直ちに読み取り専用へ戻す**
- 「**挿し直しを待ちません。**」

### 4.9 `## 既知の制約`

`docs/PLAN.md` §14 の RK から、**利用者に影響するものだけ**を選んで表にする。`#` の列に RK の ID を書く（`theKnownLimitationsAreRealRisks` が PLAN と照合する）。

| # | 制約 | どうなるか |
|---|---|---|
| RK-07 | 送信機 2 台のときの動きは実機で確かめていない | 2 台でも扱える作りだが、保証はしない。同時に挿すと 2 台目は取り込まず、「はじめに」の⑤で案内する（F-81）。1 台ずつ挿す |
| RK-18 | Raw / Daily ノートを手で編集すると、再生成で上書きされる | 書き足したいことは別のノートに書く。編集中は削除の根拠が崩れるので**元音声は消えない**（安全側） |
| RK-28 | 取り込みの後にボリューム名を変えると、それ以前の録音が削除対象から外れ、デバイスに残っている録音はもう一度取り込まれて「重複」になる | 使い始める前に名前を決める（§必要なもの）。変えるなら先に「データを初期化する」 |
| RK-31 | ちょうど 30 分で 0 文字になった録音を「無音」と判定しうる | 無音・重複の削除は既定で無効。文字起こしの JSON は残る |
| RK-32 | 使い始めた後にタイムゾーンを変えると、日付の境界がずれる | **逐語 V-11**: `**使い始めた後に、設定のタイムゾーンを変えないでください。**` すでに書いた記録は書き換えません |

- 「v1 に無いもの」を 1 段落で（自動アップデート、通知センター、話者識別、Intel Mac、Mac App Store 版）

### 4.10 `## 困ったとき`

- まずパネルの「詳細・診断 → 診断を実行」。**逐語 V-12 の形**（§4.11 で数える）: `診断は **<n> 件**（うち **<k> 件** は LLM への実リクエストで、別のボタンから実行します）。`
- 表（症状 → 見るところ）。**「見るところ」に書く DR の ID は SPEC の `S6` に在るものだけ**（`everyDiagnosticIDExists` が見る）:

| 症状 | 見るところ |
|---|---|
| 録音が取り込まれない | 診断の DR-11（デバイスを列挙できるか）、パネルの「要対応」 |
| ノートが書かれない | 診断の DR-10（Vault が使えるか）。Obsidian で Vault を一度開いたか |
| 文字起こしが始まらない | 診断の DR-04・DR-05・DR-06（whisper とモデル） |
| 要約が始まらない | 診断の DR-07・DR-08（llama-server とモデル、メモリ）。「LLM の疎通確認」ボタン（DR-09） |
| 途中で止まったように見える | パネルの「詳細・診断 → 状態の詳細」。失敗した録音は**次の接続で自動的に再試行**されます |
| 途中で電源が落ちた | **起動時に自動で巻き戻します。**完了した工程は飛ばすので二重処理しません |
| 削除が起きない | パネルの「元音声の削除」の 3 行（どのロックが掛かっているかが出ます）と診断の DR-14 |
| ビルドのたびに許可を聞かれる | 診断の DR-17（配布物ではなく自分でビルドしたものを使っていませんか） |

- 「診断は**何も書き換えません**」の 1 行

### 4.11 件数を書く 3 か所（SPEC から数える）

| 章 | 書く文 | 数える元 |
|---|---|---|
| 困ったとき | `診断は **<n> 件**（うち **<k> 件** は LLM への実リクエストで、別のボタンから実行します）。` | `S6` の生きた ID の数 `n`、「順」の列が `別` の行の数 `k` |
| 三重ロック | `実行側が判断を信用せず **<r> 項目**を独立に再検証します。` | `S8`（RV）の生きた ID の数 `r` |
| 元音声の削除（F-93。旧 `## 状態`） | `削除禁止テスト **<d> 件**（ND）・実機試験 **<e> 件**（E2E）で守っています。` | `S7`（ND）の生きた ID の数 `d`、`S9`（E2E）の数 `e` |

- **この 3 文はテストが SPEC から組み立てて `contains` で照合する。**実装者は SPEC を数えて書く（PLAN v1.1 の時点では `n=16`（F-61 で DR-13 を取り下げた後）・`k=1`・`r=14`・`d=38`・`e=16`（F-85 で取り下げた E2E-15・18 を数えない）。**この数字をチケットから写さず、必ず `docs/SPEC.md` を数える**）

### 4.12 `## データと更新`

- `### データの置き場所`: `~/Library/Application Support/VoiceDock/` をフェンスで示し、中身の説明（設定・DB・作業領域・文字起こし・ログ・モデル）を 1 行で。**パスを 1 つずつ列挙しない**（1 つずつのパスは `docs/DEVELOPMENT.md` から `docs/PLAN.md` §2.3 を指す）。「アプリはここと Obsidian の Vault 以外には書きません」
- `### バックアップ`: DB は SQLite を WAL で開いているので**単純なファイルコピーをしない**。Vault のノートと `transcripts/` があれば Raw ノートは作り直せること
- `### 更新`: 新しい dmg を開いて `Applications` へ上書きする。許可は引き継がれる。**削除が有効なときは、削除モジュールの版もアプリに合わせて更新が要る**
  （版が違うと削除が止まり、パネルに「削除モジュールの更新が必要です」と出る。有効化の操作をもう一度通す）
- `### アンインストール`: `/Applications` からアプリを消し、このフォルダを消す（**先に削除を無効にしてから**）

### 4.13 （F-93 で §4.12 に統合。旧 `## 保守`）

### 4.14 `docs/DEVELOPMENT.md`（F-93。旧 `## 開発`・`## 状態`）

- コマンドの表（`make test` / `make lint` / `make vendor` / `make app` / `make release` / `make test-disk`。**`Makefile` に在るものだけ**）
- 文書へのリンク: `docs/PLAN.md`（設計）、`docs/SPEC.md`（規範の表）、`docs/E2E.md`（実機試験）、`docs/POC.md`（実測）、`docs/tickets/README.md`（タスク）。「矛盾する場合は `docs/PLAN.md` を優先します」（**版番号は書かない**）
- ディスクイメージのテストは CI で走らないので「削除に触れる PR では手元で回した結果を PR に貼る」旨（PLAN §10.8）
- ライセンスの表示の直し方（版を上げたら `THIRD_PARTY_NOTICES.md` も直す）
- `## 状態` の表（Phase 0〜9）。T-44 が Phase 9 の行を更新する

### 4.15 （F-93 で §4.14 に移した。旧 `## 状態`）

### 4.16 `## ライセンス`（F-93）

- 本体は Apache License 2.0（`LICENSE` へのリンク、著作権表示は `NOTICE`）
- 同梱物の表（whisper.cpp・llama.cpp とその部品・argmax-oss-swift・GRDB.swift と Yams・話者分離のモデル）と、全文は `THIRD_PARTY_NOTICES.md`（アプリの `Contents/Resources/` にも同梱）
- 話者分離のモデルの出典（旧 `## 出典`。T-49 の文をそのまま）
- 「はじめに」でダウンロードするモデルは同梱せず、それぞれの配布元のライセンスに従うこと（Whisper・VAD は MIT、LLM は Apache-2.0。`Resources/ModelCatalog.json` の `license`）。**版番号は書かない**

### 4.17 `## 開発者の方へ`（F-93）

- `docs/DEVELOPMENT.md` へのリンクだけを置く

### 4.18 `make-app.sh` と許可リストの変更（F-93）

`scripts/make-app.sh` の `ModelCatalog.json` の `install` の行の直後に、次の注釈と 3 行を足す（`makeAppInstallsEveryManifestEntry` が `"$app/<行>"` の形で探すので、ループにしない）:

```bash
# ライセンス（F-93）: 本体の LICENSE・NOTICE と、同梱物の著作権表示とライセンス文
install -m 0644 "$root/LICENSE" "$app/Contents/Resources/LICENSE"
install -m 0644 "$root/NOTICE" "$app/Contents/Resources/NOTICE"
install -m 0644 "$root/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
```

`Resources/bundle-manifest.txt` に次の 3 行を足す（並びは `LC_ALL=C` の辞書順）:

```text
Contents/Resources/LICENSE
Contents/Resources/NOTICE
Contents/Resources/THIRD_PARTY_NOTICES.md
```

## 5. 文書テスト

### `Tests/PolicyTests/ReadmeTests.swift`（構成）

```swift
// README.md の件数・参照・逐語の文・見出しの順序の検査（PLAN §10.3 の「文書」。T-43）。
// voicedock tests/unit/test_readme.py と同じ考え: 件数を直書きすると、実装を直したときに文書だけが古くなる。
import Foundation
import TestSupport
import Testing

struct Readme: Sendable {
    static let path = "README.md"

    let document: MarkdownDocument
    let text: String

    static func load() throws -> Readme {
        let document = try MarkdownDocument.load(path)
        return Readme(document: document, text: document.lines.joined(separator: "\n"))
    }

    /// 見出し（深さと本文。フェンスの中は数えない）。
    func headings() -> [(depth: Int, text: String)] {
        var inFence = false
        var found: [(Int, String)] = []
        for line in document.lines {
            if MarkdownDocument.isFence(line) {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if let body = MarkdownDocument.headingText(line) {
                found.append((line.prefix { $0 == "#" }.count, body))
            }
        }
        return found.map { (depth: $0.0, text: $0.1) }
    }

    /// 本文が指すリポジトリ内のパス。
    static func referencedPaths(_ text: String) -> Set<String> {
        let pattern = "(?:^|[\\s`(\\[])((?:docs|scripts|Resources|Vendor|tools)/[A-Za-z0-9._/-]+)"
        return Self.captures(pattern, in: text)
    }

    /// 本文が挙げる `make <target>`。
    static func makeTargets(_ text: String) -> Set<String> { Self.captures("\\bmake ([a-z][a-z-]*)\\b", in: text) }

    /// 本文に現れる `X.Y.Z` の形の数（版の直書きを探す）。
    static func versionLikeNumbers(_ text: String) -> Set<String> {
        Self.captures("(?<![0-9.])([0-9]+\\.[0-9]+\\.[0-9]+)(?![0-9]|\\.[0-9])", in: text)
    }

    /// 本文が挙げる DR の ID。
    static func diagnosticIDs(_ text: String) -> Set<String> { Self.captures("\\b(DR-[0-9]+)\\b", in: text) }

    /// 本文が挙げる RK の ID。
    static func riskIDs(_ text: String) -> Set<String> { Self.captures("\\b(RK-[0-9]+)\\b", in: text) }

    static func captures(_ pattern: String, in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        var found: Set<String> = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)) {
            if let range = Range(match.range(at: 1), in: text) {
                found.insert(String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,`)]")))
            }
        }
        return found
    }
}

/// SPEC から数えた件数。**README の数字の唯一の出所。**
struct DocumentedCounts: Sendable {
    let diagnostics: Int        // S6 の生きた ID
    let diagnosticsOnDemand: Int  // S6 の「順」の列が `別` の行
    let reaperChecks: Int       // S8（RV）
    let noDelete: Int           // S7（ND）
    let e2e: Int                // S9

    static func load() throws -> DocumentedCounts {
        let spec = try SpecDocument.load()
        var onDemand = 0
        for table in MarkdownDocument.tables(in: try spec.document.section("S6")) where table.header.first == "ID" {
            onDemand += table.rows.filter { $0.count > 1 && $0[0].hasPrefix("DR-") && $0[1] == "別" }.count
        }
        return DocumentedCounts(
            diagnostics: try spec.ids(.dr).count, diagnosticsOnDemand: onDemand,
            reaperChecks: try spec.ids(.rv).count, noDelete: try spec.ids(.nd).count, e2e: try spec.ids(.e2e).count)
    }

    var diagnosticsSentence: String {
        "診断は **\(diagnostics) 件**（うち **\(diagnosticsOnDemand) 件** は LLM への実リクエストで、別のボタンから実行します）。"
    }
    var reaperSentence: String { "実行側が判断を信用せず **\(reaperChecks) 項目**を独立に再検証します。" }
    var safetySentence: String { "削除禁止テスト **\(noDelete) 件**（ND）・実機試験 **\(e2e) 件**（E2E）で守っています。" }
}
```

逐語の文（`static let verbatim: [String]`。**この配列がチケットと README をつなぐ唯一の点**）:

| # | 文 |
|---|---|
| V-1 | `**クラウドの AI は使いません。音声もテキストも外部へ出ません。**` |
| V-2 | `**使い始める前に、デバイスのボリューム名を決めてください。**` |
| V-3 | `システム設定 → プライバシーとセキュリティ → ファイルとフォルダ → VoiceDock → リムーバブルボリューム` |
| V-4 | `**録って、挿す。以上です。**` |
| V-5 | `**コピーが終われば抜いて大丈夫です。**` |
| V-6 | `**手で書き加えた内容は次の再生成で失われます。**` |
| V-8 | `**既定では削除しません。**` |
| V-9 | `**元音声の削除は、Raw ノートの検証を通った録音だけを対象にします。**` |
| V-10 | `**消した録音は戻りません。**` |
| V-11 | `**使い始めた後に、設定のタイムゾーンを変えないでください。**` |
| V-12 | `**どちらか一方でも欠けていれば削除しません。**` |
| V-13 | `録音デバイスから音声を読み込むために使います` |
| V-14 | `Obsidian の保管庫がこのフォルダにある場合に、ノートを書き込むために使います` |

テストの表（`@Suite("Readme") struct ReadmeTests`）:

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `theExtractionFindsAPath()` | **陽性対照**: 参照の抽出が効く | 文字列を直に渡す | `"[手順](docs/E2E.md) と `scripts/release.sh`"` から `["docs/E2E.md", "scripts/release.sh"]`。`"AVFoundation/CoreAudio"` からは何も拾わない |
| `theExtractionFindsAVersionNumber()` | **陽性対照**: 版の抽出が効く | 同上 | `"VoiceDock-1.0.0.dmg"` から `["1.0.0"]`（末尾の `.dmg` の `.` は版の続きと見ない）、`"macOS 15.0 以上"` からは空、`"約 18.6 GB"` からは空、`"1.2.3.4"`（4 つ組）からは空 |
| `theExtractionOfEmptyTextFindsNothing()` | 空の文字列からは何も抽出しない（TEST-28） | 空文字を直に渡す | `referencedPaths`・`makeTargets`・`versionLikeNumbers`・`diagnosticIDs`・`riskIDs` がすべて空 |
| `theReadmeExists()` | README.md が在る | — | `Readme.load()` が投げない |
| `theHeadingsAreInOrder()` | 見出しが §4.1 の表のとおり | `headings()` | 深さと本文の列が §4.1 の 25 行（F-93）と完全一致 |
| `everyVerbatimSentenceIsPresent(_:)` | 逐語の文が在る | V-1〜V-14（V-7 は欠番）で parametrize | `text.contains(_)` |
| `theUsageDescriptionsMatchTheInfoPlist(_:)` | TCC の説明文が Info.plist と一字一句同じ | V-13・V-14 | `Resources/Info.plist.template` にも同じ文字列が在る（**2 か所の文言がずれない**。T-34） |
| `theDiagnosticsCountMatchesTheSpec()` | 診断の件数が SPEC と一致 | `DocumentedCounts.load()` | `text.contains(counts.diagnosticsSentence)` |
| `theReaperCheckCountMatchesTheSpec()` | reaper の検証の件数が SPEC と一致 | 同上 | `text.contains(counts.reaperSentence)` |
| `theSafetyCountsMatchTheSpec()` | ND と E2E の件数が SPEC と一致 | 同上 | `text.contains(counts.safetySentence)` |
| `theCountsAreNotZero()` | **土台**: 数える元が空でない | 同上 | 4 つの件数がすべて 1 以上（**SPEC の節を取り違えて 0 件で緑になるのを防ぐ**） |
| `everyReferencedPathExists(_:)` | README が指すファイルが実在 | `referencedPaths(text)` で parametrize | `PackageRoot.file(_)` が在る |
| `everyMakeTargetExists(_:)` | README が挙げる make のターゲットが実在 | `makeTargets(text)` で parametrize | `Makefile` に `^<name>:` が在る |
| `everyDiagnosticIDExists(_:)` | README が挙げる DR が SPEC に在る | `diagnosticIDs(text)` で parametrize | `SpecDocument.load().ids(.dr)` に含まれる |
| `everyRiskIDExists(_:)` | README が挙げる RK が PLAN §14 に在る | `riskIDs(text)` で parametrize | `SpecDocument.plan().document.section("14.")` の行から `^\| RK-[0-9]+ \|` で読んだ集合に含まれる |
| `theKnownLimitationsCoverTheUserFacingRisks(_:)` | 利用者に効く RK が README に在る | `RK-18`・`RK-28`・`RK-32` で parametrize | `riskIDs(text)` に含まれる |
| `theReadmeDoesNotPinAnyVersion(_:)` | 版を直書きしない | `versionLikeNumbers(text)` で parametrize | その数が `Vendor/versions.env` に現れる（= whisper.cpp / llama.cpp の版だけが書ける） |
| `theReadmeDoesNotNameTheSpecVersion()` | SPEC・計画書の版を書かない | `text` | `計画書 v<数>.<数>` / `SPEC v<数>` / `詳細仕様書 v<数>` に一致しない |
| `theReadmeCarriesNoDockerLeftovers(_:)` | voicedock（Docker 版）の語を持ち込まない | `docker`・`Docker`・`compose`・`LaunchAgent`・`launchctl`・`ffmpeg` で parametrize | `text` に含まれない |
| `theReadmeLinksTheDevelopmentGuide()` | README が開発者向けの文書を指す（F-93） | `referencedPaths(text)` | `docs/DEVELOPMENT.md` を含む |
| `theDevelopmentGuideLinksTheKeyDocuments(_:)` | 主要な文書へのリンクが開発者向けの文書に在る（F-93） | `docs/PLAN.md`・`docs/SPEC.md`・`docs/E2E.md`・`docs/POC.md`・`docs/tickets/README.md` で parametrize | `docs/DEVELOPMENT.md` の `referencedPaths` に含まれる |
| `everyPathInTheDevelopmentGuideExists(_:)` | 開発者向けの文書が指すファイルが実在（F-93） | `docs/DEVELOPMENT.md` の `referencedPaths` で parametrize | `PackageRoot.file(_)` が在る |
| `theLicenseChapterLinksTheLicenseFiles(_:)` | ライセンスの章が本体と同梱物のライセンスを指す（F-93） | `LICENSE`・`NOTICE`・`THIRD_PARTY_NOTICES.md` で parametrize。`## ライセンス` の節 | `(<名前>)` のリンクを含む |
| `theLicenseChapterNamesTheLicense()` | ライセンスの章が本体のライセンスの名前を書く（F-93） | `## ライセンス` の節 | `Apache License 2.0` を含む |
| `theReadmeTellsYouHowToTurnDeletionOff()` | 元に戻す手順が在る | `## 元に戻す` の節 | 「確認は求められません」と「読み取り専用」を含む |
| `theInstallChapterExplainsTCC()` | インストールの章が TCC を説明する | `### 2. 最初の起動と、許可の出し方` の節 | V-3（システム設定の経路）と V-13 を含む |

- **`MarkdownDocument.section(_:)` は「見出しの本文が鍵で始まる最初の節」を返す**（T-04）。`## 元に戻す` は数字でも英大文字でも「付録」でも始まらないので**節の境界にならない**。
  `section("元に戻す")` は「`### 元に戻す` の次の行から、次の `^#{1,6} (?:[0-9A-Z]|付録)` まで」＝ **ファイルの終わりまで**、になる（`## 既知の制約` 以降の見出しもどれも数字・英大文字・「付録」で始まらないので、節の境界にならない）。**この振る舞いでよい**。
  節の切り出しに依存するテストは **`theReadmeTellsYouHowToTurnDeletionOff`・`theInstallChapterExplainsTCC`・`theLicenseChapterLinksTheLicenseFiles`・`theLicenseChapterNamesTheLicense` の 4 本だけ**にし（後ろの 2 本は F-93。`## ライセンス` の後ろは `## 開発者の方へ` だけなので揺れない）、残りは全文を見る（境界の揺れで落ちないようにする）
- `theCountsAreNotZero` を必ず置く（**parametrize の元を空にすると全部緑になる**形を防ぐ。TEST-01）

テストの表（`@Suite("LicenseFiles") struct LicenseFilesTests`。F-93）:

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `nothingIsMissingFromAnEmptyList()` | 空の必須語からは何も欠けない（TEST-28） | `missingMentions(in: "", required: [])` | 空 |
| `aMissingWordIsReported()` | **陽性対照**: 無い語を欠けとして返す | `"whisper.cpp v1.9.4"` と `["v1.9.4", "b11033"]` | `["b11033"]` |
| `theLicenseIsApache2()` | LICENSE が Apache License 2.0 の全文 | `LICENSE` | `Apache License`・`Version 2.0, January 2004`・`END OF TERMS AND CONDITIONS` を含む |
| `theNoticeNamesTheHolderAndTheThirdPartyFile()` | NOTICE が著作権者と THIRD_PARTY_NOTICES.md を示す | `NOTICE` | `Copyright 2026 Shinsuke Terada` と `THIRD_PARTY_NOTICES.md` を含む |
| `theNoticesCarryTheVendorVersions()` | THIRD_PARTY_NOTICES.md が versions.env の版とコミットを載せている | `Vendor/versions.env` の whisper.cpp・llama.cpp・argmax-oss-swift の `_REF` と `_SHA` の先頭 7 桁、`SPEAKER_MODELS_SHA` の先頭 7 桁 | 全部を含む |
| `theNoticesCarryThePackageVersions()` | THIRD_PARTY_NOTICES.md が GRDB と Yams の版を載せている | `Package.resolved` の `grdb.swift`・`yams` の `version` | 全部を含む |
| `theNoticesCarryEveryLicenseText()` | THIRD_PARTY_NOTICES.md が同梱物ごとのライセンス文を載せている | 固定の語: The ggml authors・argmax, inc.・Mozilla Foundation（sgemm）・Jeffrey Quesnelle and Bowen Peng（YaRN）・Gwendal Roué・JP Simard・Kirill Simonov・Yann Collet・Runtime Library Exception・Creative Commons Attribution 4.0 International | 全部を含む |
| `theAppBundlesTheDocument(_:)` | make-app.sh が 3 つの文書を Resources に入れる | `LICENSE`・`NOTICE`・`THIRD_PARTY_NOTICES.md` で parametrize | `make-app.sh` に §4.18 の `install` の行、許可リストに `Contents/Resources/<名前>`、リポジトリにファイルが在る |

- swift-argument-parser の版（argmax-oss-swift の `Package.resolved`）は `Vendor/work/` にしか無く CI では読めないので照合しない。argmax-oss-swift の版を上げたときは手で確かめる（`docs/DEVELOPMENT.md` の「ライセンスの表示」）

## 6. 破壊による証明

| # | 壊し方 | 落ちるべきテスト |
|---|---|---|
| 1 | README の「診断は **16 件**…」の 16 を 15 にする | `theDiagnosticsCountMatchesTheSpec` |
| 2 | `docs/SPEC.md` の `S6` から DR-15 の行を消す（`make spec` を回さずに） | `theDiagnosticsCountMatchesTheSpec`（README が古くなる側で落ちる）、T-05 の `specMatchesPlan` |
| 3 | README の「**14 項目**を独立に再検証」を「12 項目」にする | `theReaperCheckCountMatchesTheSpec` |
| 4 | README の `**消した録音は戻りません。**` を消す | `everyVerbatimSentenceIsPresent("**消した録音は戻りません。**")` |
| 5 | `Resources/Info.plist.template` の `NSRemovableVolumesUsageDescription` の文言だけ変える | `theUsageDescriptionsMatchTheInfoPlist` |
| 6 | README に `VoiceDock-1.0.0.dmg` と書く | `theReadmeDoesNotPinAnyVersion("1.0.0")` |
| 7 | README に `計画書 v1.1 を参照` と書く | `theReadmeDoesNotNameTheSpecVersion` |
| 8 | README に `docs/GUIDE.md`（存在しない）へのリンクを足す | `everyReferencedPathExists("docs/GUIDE.md")` |
| 9 | README に `make doctor` と書く | `everyMakeTargetExists("doctor")` |
| 10 | README のトラブルシュートに `DR-99` と書く | `everyDiagnosticIDExists("DR-99")` |
| 11 | README の既知の制約から `RK-32` の行を消す | `theKnownLimitationsCoverTheUserFacingRisks("RK-32")` |
| 12 | README に `docker compose logs` と書く | `theReadmeCarriesNoDockerLeftovers("docker")` |
| 13 | `## 元音声の削除` と `## 既知の制約` の順を入れ替える | `theHeadingsAreInOrder` |
| 14 | `### 元に戻す` から「確認は求められません」を消す | `theReadmeTellsYouHowToTurnDeletionOff` |
| 15 | `DocumentedCounts.load()` の `.dr` を `.cv` に変える | `theDiagnosticsCountMatchesTheSpec`（README の 16 と CV の件数が合わない） |
| 16 | `Readme.versionLikeNumbers` の正規表現から後読み `(?<![0-9.])` を外す（`1.2.3.4` から `2.3.4` を拾うようにする。`18.6` は 2 つ組なので後読みの有無に関係なく拾われない） | `theExtractionFindsAVersionNumber`（`"1.2.3.4"` の行） |
| 17 | `Vendor/versions.env` の `LLAMA_CPP_REF` を `b12000` に上げ、`THIRD_PARTY_NOTICES.md` を直さない（F-93） | `theNoticesCarryTheVendorVersions` |
| 18 | README の `## ライセンス` の `[Apache License 2.0](LICENSE)` のリンクを外す（F-93） | `theLicenseChapterLinksTheLicenseFiles("LICENSE")` |
| 19 | `make-app.sh` の `NOTICE` の `install` の行を消す（F-93） | `theAppBundlesTheDocument("NOTICE")`、`makeAppInstallsEveryManifestEntry`（T-34） |

## 7. 受け入れ条件

- [ ] `README.md` が §4.1 の 25 見出し（F-93）をその順で持ち、T-01 の仮版の文（`利用者向けの説明は T-43 で書く。`）が残っていない
- [ ] 13 個の逐語の文（V-1〜V-14。V-7 は欠番）がすべて在る
- [ ] 件数の 3 文が `docs/SPEC.md` から数えた値と一致する（**チケットの数字を写していない**ことを、`docs/SPEC.md` を数えて確かめた）
- [ ] TCC の 2 つの説明文が `Resources/Info.plist.template` と一字一句同じ
- [ ] README が指すファイルと make ターゲットがすべて実在する
- [ ] 既知の制約に RK-18・RK-28・RK-32 が在り、PLAN §14 に実在する ID だけを書いている
- [ ] 版番号（`X.Y.Z`）を書いていない（`Vendor/versions.env` の値を除く）
- [ ] **陽性対照 2 本**（`theExtractionFindsAPath`・`theExtractionFindsAVersionNumber`）と**土台 1 本**（`theCountsAreNotZero`）が在る
- [ ] 【利用者が行う】README のとおりに、**新しいユーザアカウント**（または `~/Library/Application Support/VoiceDock` が無い状態）で最初から導入してみて、詰まった箇所が無い。詰まったら README を直す
- [ ] 破壊による証明の結果が PR 本文にある
- [ ] （F-93）`LICENSE`・`NOTICE`・`THIRD_PARTY_NOTICES.md` が在り、`make app` の `.app` の `Contents/Resources/` に 3 つが入る（`verify-bundle.sh --files-only` が通る）
- [ ] （F-93）`THIRD_PARTY_NOTICES.md` のライセンス文が上流のファイルと一字一句同じ

## 8. SPEC の変更

なし（チケットとしては）。ただし本 PR で PLAN 付録 B.3 の E2E-15・E2E-18 を `~~` で打ち消し（F-85。利用者の決定）、`make spec` で `docs/SPEC.md` を同期した。README の「実機試験 **16 件**」はその値。

## 9. マージ後にやること

- T-44 が `docs/DEVELOPMENT.md` の `## 状態` の表を v1.0 の内容に更新する（F-93。`theHeadingsAreInOrder` はそのまま通る）
- 診断を足す・減らす PR は、**同じ PR で** PLAN §8.11 → `make spec` → README の 3 か所を直す（`theDiagnosticsCountMatchesTheSpec` が落ちて気づく）

## 10. API 地図への変更提案

1. §14 の `PolicyTests` の「主な中身」に `ReadmeTests`（T-43）を足す
2. **`DocumentedCounts` を `Tests/PolicyTests/` に置く**（TestSupport に置かない）。README 以外に件数を書く文書が増えたときに初めて TestSupport へ上げる
3. **件数の連鎖に穴がある。**本チケットは「README ↔ SPEC」を閉じるが、「SPEC ↔ 実装（診断の件数）」は `PolicyTests` から見えない
   （`PolicyTests` は `TestSupport` にしか依存しないので `VDPipeline` の `Diagnostics` を数えられない）。
   **T-32 に `diagnosticsCountMatchesSpec`（`Tests/VDPipelineTests/` で `Diagnostics` の検査の数と `SpecDocument.load().ids(.dr).count` を比べる）を足すことを提案する。**
   T-32 が `SpecCoverage.activated` に `.dr` を足す（ID の集合の一致）だけでは、**実装の「検査の配列の長さ」とはつながらない**
4. PLAN §14 の RK の表に「利用者に見せるか」の列は無い。README に載せる RK（RK-07・18・28・31・32）を PLAN §14 に注記として記すことを提案する（README から落ちたときに気づける）
5. PLAN §11.1 の TCC の説明文（2 種）は `Resources/Info.plist.template`（T-34）と README（T-43）の 2 か所に現れる。
   **PLAN にも「この 2 文は逐語で 2 か所に置き、テストが照合する」と書くことを提案する**
