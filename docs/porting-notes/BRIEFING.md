# チケット執筆・整合修正の共通説明（エージェント向け）

## プロジェクト
- VoiceDock for Mac（Swift ネイティブの macOS メニューバーアプリ）。DJI Mic 3 の録音を取り込み、whisper.cpp で文字起こし、llama.cpp の llama-server で要約し、Obsidian の Vault にノートを書く。元音声の削除は三重ロック付き。
- 参照実装 voicedock（Python + Docker）を Swift で書き直す。voicedock は固定コミット d3d595e から読む: `git -C /Users/terada/Projects/voicedock show d3d595e:<path>`。**voicedock の作業ツリーには絶対に書き込まない。**

## 文書（優先順位: 仕様 ＞ API 地図 ＞ 各チケット）
- 仕様書（計画書 v1.1、約 3,100 行）: `/Users/terada/Projects/voicedock_app/tmp/witty-gliding-clover.md`。実装時は `docs/PLAN.md` にコピーされる（チケットでは「PLAN §x.y」と呼ぶ）。付録 F に改訂履歴、付録 A に状態・遷移・エラーコード・ログイベント、付録 B に ND / RV / E2E。
- API 地図（モジュールをまたぐ名前の契約）: `/Users/terada/Projects/voicedock_app/docs/tickets/00-api-map.md`。§15 に TestSupport の部品の作り手（一意）。
- チケットの共通規約と目次: `/Users/terada/Projects/voicedock_app/docs/tickets/README.md`（「チケットの形」の 10 節の順に書く）。
- 既存のチケット: `/Users/terada/Projects/voicedock_app/docs/tickets/T-nn-*.md`（書き方の見本として T-11-store.md や T-17-transcribe.md を参照するとよい）。
- 移植メモ（voicedock の実装の逐語・固定事例・file:line）: `/Users/terada/Projects/voicedock_app/docs/porting-notes/`
  - V1: 契約・デバイス取り込み・reaper、V2: 状態・設定・DB・ログ、V3: Worker・工程・分組・削除フロー、V4: 音声・文字起こし・LLM、V5: ノート、V6: 診断・状態表示・CI・E2E、V7: 外部の事実（HF・llama.cpp・GitHub）
- 第 1 段で出た「API 地図への変更提案」と統合の記録: `/Users/terada/Projects/voicedock_app/docs/porting-notes/stage-a-api-proposals.md`（地図への反映は済んでいる）

## 詳細度
「誰が実装しても同じソースコードになる」水準。作るファイルのパスをすべて列挙し、公開・主要な内部の宣言は Swift のコードで書き、手順は番号付き、定数・文言（日本語の逐語）・SQL・argv・ログのイベントとフィールドは逐語で書く。テストはテストファイルごとに関数名・表示名（規範の ID があれば ID で始める）・準備・期待を表で。破壊による証明（壊し方と落ちるべきテスト）、受け入れ条件、SPEC の変更、マージ後にやること。

## 守ること
- **型・関数の名前は 00-api-map.md と先行チケットから取る。**地図に無いモジュール横断 API が要る・食い違いを見つけたら、チケット末尾の「API 地図への変更提案」節と最終報告に書く（00-api-map.md と仕様書は編集しない）。
- **安全**: 利用者の実機 DJI Mic 3 が `/Volumes/DJIMIC3` に接続されている。/Volumes 配下の実機に対して diskutil・書き込み・削除・再マウントを一切行わない。テストは一時ディレクトリの volumesRoot と、/Volumes 以外に attach した DiskImageVolume だけを使う。
- Sources/ などの実装コードは作らない（チケットの Markdown だけ）。scratchpad での小さな実験はよい。
- GFM の表の中ではコードスパン内の `|` も `\|` にエスケープする。
- 使用量を節約する: 必要な節だけを読む（仕様書は grep で節を探して Read の offset/limit で読む）。同じファイルを何度も全文読みしない。
