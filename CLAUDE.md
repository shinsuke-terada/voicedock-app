# VoiceDock for Mac

DJI Mic 3 の録音を USB 経由で取り込み、whisper.cpp（Metal）で文字起こしし、llama.cpp の `llama-server`（ループバック HTTP のみ）で要約し、Obsidian の Vault にノート（Raw と Daily）を書く **macOS のメニューバーアプリ**。Dock アイコンは持たない。元音声の削除は三重ロック付きで、別の実行ファイル `voicedock-reaper` だけが行う。

Python + Docker の参照実装 `voicedock` を Swift で書き直すもの。参照実装は固定コミット `d3d595e` から**読むだけ**。

## いまの状態

**仕様だけのリポジトリ。ソースコードは 1 行も無く、git リポジトリでもない。** 計画は完了していて、次は実装。

| 次 | 内容 |
|---|---|
| Phase 0 | `docs/tickets/P0-poc.md` の P0-01〜12（実機 PoC）。**実機の操作は利用者が行う**。成果物は `docs/POC.md` |
| Phase 1 | T-01（リポジトリの骨組み。`git init` はここ）→ T-02 / T-03 → T-04 / T-05 / T-25 |
| 以降 | `docs/tickets/README.md` の依存順（Phase 2〜9） |

セッションを再開したら、まず `docs/tickets/STATUS.md` を読む。

## 文書の地図（優先順位: PLAN ＞ 00-api-map ＞ 各チケット）

| 文書 | 役割 |
|---|---|
| `tmp/witty-gliding-clover.md` | 計画書 v1.1（3,100 行）。**最上位**。T-01 が `docs/PLAN.md` にコピーし、以後はそちらが正。チケットでは「PLAN §x.y」と呼ぶ |
| `docs/tickets/00-api-map.md` | モジュールをまたぐ名前の契約。**チケットより上位**。§15 は TestSupport の部品の作り手、§16 は地図に行の無い公開 API の索引 |
| `docs/tickets/README.md` | 共通規約・チケットの形（10 節）・依存順の目次 |
| `docs/tickets/T-*.md`, `P0-poc.md` | 実装の詳細仕様（46 本・約 33,000 行）。「誰が実装しても同じソースコードになる」水準 |
| `docs/tickets/STATUS.md` | 進捗と再開の手順 |
| `docs/porting-notes/V1〜V7` | voicedock の逐語の移植メモ（`file:line` つき） |
| `docs/porting-notes/BRIEFING.md` | 作業を頼むときの説明 |
| `docs/porting-notes/check-tickets.py` | チケット一式の機械検査 |

付録の場所: A = 状態・遷移・エラーコード・ログイベント、B = ND / RV / E2E、D = voicedock との意図的な差分（X-01〜36）、F = v1→v1.1 の改訂（F-01〜55）。

## なぜ `/Volumes` が危ないか

利用者の**実機**の DJI Mic 3 が `/Volumes/DJIMIC3` にマウントされていることがある。そこにあるのは本物の録音で、消したら戻らない。

このアプリ自身、デバイスへは**読み取りと `diskutil` のマウント操作以外を一切しない**設計（PR-11）。原本は `O_RDONLY | O_NOFOLLOW` でしか開かず、削除は `voicedock-reaper` だけが、三重ロックと独立再検証（`openat` の連鎖 → `unlinkat` → `fstatat` で `ENOENT`）を通してから行う。**開発の途中でその設計を破ると、設計が守っているものが先に消える。**

守ることは `.claude/rules/safety.md`。ガードフック（`.claude/hooks/guard-volumes.py`）もあるが、あれは滑りを止めるだけで防壁ではない。

## コマンド

いま使えるのは 1 つだけ:

```bash
python3 docs/porting-notes/check-tickets.py      # チケット一式の機械検査。0 件であること
```

T-01 以降（`Makefile` は T-01 が作る。CI と手元で同じコマンドを使う）:

```bash
make lint          # swift format lint --strict --recursive Sources Tests
make fmt           # 整形
make build         # check-toolchain + swift build --build-tests
make test          # ND → PolicyTests → 残り（CI と同じ順）
make test-disk     # ディスクイメージのテストも含む（実機を抜いてから。利用者の確認が要る）
make vendor        # whisper.cpp / llama.cpp のビルド（T-03）
make app           # .app の組み立て（T-34）
```

## 構成

Swift 6 言語モード（strict concurrency complete、警告はエラー）、SwiftPM のみ（`.xcodeproj` は作らない）、macOS 15+、**arm64 のみ**。外部依存は `GRDB.swift`（exact 7.11.1）と `Yams`（exact 6.2.2）の 2 つだけ。テストは Swift Testing（XCTest は使わない）。

11 のライブラリと 2 つの実行ファイル。`import` はモジュールごとの許可リスト（PLAN §3.4）に収まり、PT-07 が検査する。

| モジュール | 役割 |
|---|---|
| `VDContract` | アプリと reaper が共有する規則（名前規則・JSON・`AtomicFile`・`HomeLayout`・`ReaperConf`・`FileLock`・`TargetIdentity`）。Foundation / Darwin / CryptoKit だけ |
| `VDCore` | 状態・エラーコード・設定・時刻（`Clock`）・ログ・`SafeUnlink`・`AppPaths`・Python 互換（`PyText` / `PyJSON`） |
| `VDStore` | GRDB。状態遷移を書くのは `Transitions.swift` だけ |
| `VDProcess` | 子プロセスの起動（`posix_spawn`）。シェルは経由しない |
| `VDDevice` | デバイス判定・走査・安定性判定・コピー・再マウント・snapshot |
| `VDAudio` | 16 kHz 変換・検証・空き容量（AVFoundation。ffmpeg は使わない） |
| `VDTranscribe` | whisper-cli の呼び出しと JSON の読み取り |
| `VDLLM` | スキーマ・プロンプト・チャンク分割・Map-Reduce・`llama-server`・ループバック HTTP |
| `VDNotes` | sanitize・frontmatter・Raw・Daily・Vault の確認と検証 |
| `VDModels` | モデルのダウンロードと取り込み（**URLSession を使ってよい唯一のモジュール**） |
| `VDPipeline` | Worker・Part / Session の工程・削除フロー・診断 |
| `VoiceDockApp` | AppKit + SwiftUI のメニューバー UI |
| `voicedock-reaper` | 削除の実行者。**Foundation / Darwin / VDContract のみ** |

## 実装の回し方

**1 チケット = 1 issue = 1 PR。** 手順は `.claude/rules/workflow.md`。

```
/next-tickets              次に着手できるチケットを選び、最大 4 本まで並列に投げる
/implement-ticket T-nn     チケット 1 本を実装して PR まで
/prove-by-breaking T-nn    破壊による証明
/poc-measure               Phase 0（実機の手順は利用者に渡す）
```

同時に走らせるのは**最大 4 本**まで（8 本で使用量の上限に当たった）。`settings.json` の `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` で 1 セッションには効くが、端末を 5 つ開けば効かない。

## 文脈の節約

文書は合計 41,885 行ある。PLAN もチケットも全文を読ませる余裕は無い。

- PLAN は `grep -n` で節を探し、`Read` の offset/limit で必要な範囲だけ読む
- チケット §「参照」が指す PLAN の節・API 地図の行・`voicedock@d3d595e` の `file:line` は `ticket-brief` エージェントに**逐語で**引かせる（要約させない。定数・文言・argv・ログのフィールドが命）
- 同じファイルを何度も全文読みしない

## `.claude/` の地図

| 場所 | 何のため |
|---|---|
| `rules/safety.md` | 実機と参照ツリーの保護。**毎セッション読み込まれる** |
| `rules/workflow.md` | 文書の優先順位・チケットの回し方・並列の条件。**毎セッション読み込まれる** |
| `rules/swift-code.md` | `Sources/**/*.swift` を触るときだけ。PLAN §9 の規約と PT-01〜22 の禁止一覧 |
| `rules/swift-tests.md` | `Tests/**/*.swift` を触るときだけ。Swift Testing の書き方と TEST-01 / TEST-28 |
| `rules/tickets.md` | `docs/tickets/**/*.md` を触るときだけ。10 節の形と機械検査 |
| `agents/ticket-implementer` | チケット 1 本を実装する（書ける。並列で走る本体） |
| `agents/ticket-brief` | 読み取り専用。仕様の材料を逐語で集める |
| `agents/ticket-review` | 読み取り専用。受け入れ条件と API 地図に照らした判定 |
| `skills/` | 上の `/` コマンド 4 本 |
| `hooks/guard-volumes.py` | Bash の実行前に破壊的な操作を止める |
| `hooks/guard-volumes.test.py` | そのフックの回帰テスト（45 件）。フックを直したら `python3 .claude/hooks/guard-volumes.test.py` |
| `hooks/session-start.sh` | セッションの先頭に実機の接続状態と「次にやること」を出す |
| `settings.json` | permissions（deny / ask / allow）・フックの登録・並列数 |
