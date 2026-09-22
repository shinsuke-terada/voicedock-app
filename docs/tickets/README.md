# チケット（1 チケット = 1 issue = 1 PR）

VoiceDock for Mac の実装タスクごとの詳細仕様。**誰が実装しても同じソースコードになる**ことを目標に、作るファイル・型・関数・手順・定数・文言・テスト名まで決めてある。

- 計画書（設計の理由と規範の表）: `docs/PLAN.md`（= `tmp/witty-gliding-clover.md` の v1.1。T-01 でコピーする）
- **安全の約束**: テストも PoC も `/Volumes` 配下の実機（DJI Mic 3）に触れない。ディスクイメージは `/Volumes` 以外に attach する。実機を使う手順はチケットに【利用者が行う】と書き、利用者が明示的に行う
- モジュールをまたぐ名前の契約: [`00-api-map.md`](00-api-map.md)
- 優先順位: **PLAN ＞ 00-api-map ＞ 各チケット**。食い違いを見つけたら、実装を止めて上位の文書に合わせ、両方を同じ PR で直す

## 進め方（PLAN §12.1）

1. チケットの「前提」のチケットがすべて `develop` にマージ済みであることを確かめる
2. `develop` から `feat/T-nn-<短い英語名>` を切る
3. チケットの「作るもの」を上から順に作る。**チケットに書いていない公開 API を足さない**（足す必要があれば 00-api-map とチケットを先に直す）
4. 「テスト」の節のテストを全部書き、`make test` が通ることを確かめる
5. 「破壊による証明」の節の各項目を 1 つずつ行い、落ちたテスト名を PR 本文に貼る（PLAN §10.7）
6. PR 本文の必須節: 目的 / 変更 / テスト / 破壊による証明 / SPEC の変更 / マージ後にやること
7. 利用者が確かめて `develop` にマージする。issue は手で閉じる

## 共通の書き方（全チケットに適用。チケットでは繰り返さない）

### ソース
- Swift 6 言語モード、strict concurrency complete、警告はエラー（`treatAllWarnings(as: .error)`）
- 整形は `swift format`（`.swift-format` は T-01 で固定）。`make lint` が通らない PR は出さない
- 1 ファイル 1 主要型。ファイル名 = 型名。ファイルの先頭に 1 行のコメントでファイルの役割を書く（例 `// 削除要求と結果の JSON（PLAN §4.4）。アプリと reaper が共有する。`）
- ドキュメントコメント（`///`）は日本語。安全に関わる規則には根拠の ID を書く（例 `/// DEL-12: size と mtime はデバイス上の原本の値。`）
- 名前: 型は UpperCamelCase、関数・変数は lowerCamelCase。DB の列・JSON のキー・ログのキーは snake_case の文字列のまま（Swift 側の名前とは CodingKeys や定数で対応させる）
- 定数は `static let` で型の中に置く。同じ値を 2 か所に書かない（CR-06）
- `public` はモジュールをまたぐものだけ。テストからだけ使うものは `internal` にして `@testable import`
- 禁止: `Date()`（Clock 以外）、`print`（Log 以外）、`try!`・`as!`・`fatalError`・`precondition`・`assert`、`@unchecked Sendable`、`nonisolated(unsafe)`、Swift の `Regex`、`FileManager.removeItem`、シェル経由の起動（PT-01〜21）
- 文字数は `TextLimit.scalarCount`、Python 互換の処理は `PyText` / `PyJSON`、時刻は `Instant` と `ZonedTime`

### テスト
- Swift Testing（`import Testing`）。XCTest は使わない
- ファイル: `Tests/<モジュール>Tests/<対象の型>Tests.swift`。スイートは `@Suite("<対象の型>") struct <対象の型>Tests`
- テスト関数名は lowerCamelCase の英語、表示名は日本語。規範の ID に対応するテストは表示名を ID で始める（例 `@Test("ND-18 削除直前にサイズが変わると size_mismatch") func nd18SizeChangedJustBeforeDeletion()`）
- 一時ディレクトリは `TempDirectory()`（TestSupport）でテストごとに作り、テストの終わりに消す
- 時計は `FixedClock` / `SteppingClock`、待ちは `RecordingSleeper`（実際には待たない）
- ディスクイメージは `.enabled(if: TestEnvironment.diskTests)`、本物のツールは `.enabled(if: TestEnvironment.realTools)`
- 期待値は仕様の表や固定値から書く。**実装を呼んで得た値を期待値にしない**（TEST-01）
- 空の入力（0 件・0 台・空文字）を必ず 1 本入れる（TEST-28）

### 破壊による証明（PR ごと）
- チケットの表にある「壊し方」を 1 つずつ行う（1 回に 1 か所）。壊す前に `git diff --quiet -- <file>` が真、壊した後に偽であることを確かめ、`make test` を回し、落ちたテスト名を記録し、`git checkout -- <file>` で戻す
- 「壊したのに通った」ら、テストを足すか直してからやり直す

## チケットの形

各チケットは次の節をこの順に持つ:

1. **ヘッダ**: ID・題・Phase・前提（先にマージが要るチケット）・見積もり（差分の行数の目安）
2. **目的**: 1〜3 行
3. **参照**: PLAN の節、voicedock@d3d595e のファイル（`file:line`）
4. **作るもの**: ファイルの一覧（パス）
5. **仕様**: ファイルごとに、宣言（Swift のコード）・手順（番号付き）・定数・文言（逐語）・エラーの写し方・ログ
6. **テスト**: テストファイルごとに、テスト名（関数名と表示名）・準備・期待の表
7. **破壊による証明**: 壊し方と、落ちるべきテスト
8. **受け入れ条件**: チェックリスト
9. **SPEC の変更**: `docs/SPEC.md` に足す・変える表（無ければ「なし」）
10. **マージ後にやること**: 無ければ「なし」

例外: 実機 E2E と文書のチケット（T-35・T-42・T-43・T-44）は作るものが文書なので、5 の「仕様」の代わりに「`docs/E2E.md` の書式」「シナリオ」「文書テスト」の節を持つ。ほかの節の順と名前は同じ。

## 一覧（依存順）

| ID | 題 | Phase | 前提 |
|---|---|---|---|
| [P0](P0-poc.md) | 実機 PoC（P0-01〜12） | 0 | — |
| [T-01](T-01-repository-skeleton.md) | リポジトリの骨組み | 1 | P0 の BUNDLE_ID 等の決定 |
| [T-02](T-02-ci.md) | CI | 1 | T-01 |
| [T-03](T-03-vendor-builds.md) | whisper.cpp / llama.cpp のビルド | 1 | T-01 |
| [T-04](T-04-policy-tests.md) | PolicyTests（PT-01〜22） | 1 | T-01, T-02, T-03 |
| [T-05](T-05-spec-sync.md) | docs/SPEC.md と SPEC 同期 | 1 | T-04 |
| [T-25](T-25-golden-tools.md) | golden 生成ツールと入力 fixture | 1 | T-01 |
| [T-06](T-06-contract-core.md) | VDContract: 鍵・名前・JSON・AtomicFile・HomeLayout・ReaperConf・FileLock | 1 | T-01 |
| [T-07](T-07-target-identity.md) | VDContract: TargetIdentity | 1 | T-06 |
| [T-08](T-08-states-errors.md) | VDCore: 状態・遷移・エラーコード | 2 | T-05, T-06 |
| [T-45](T-45-python-compat.md) | VDCore: Python 互換（PyText・PyJSON・PyRound・casefold） | 2 | T-25 |
| [T-10](T-10-clock-log-files.md) | VDCore: 時刻・ログ・SafeUnlink・AppPaths・Transcript 型 | 2 | T-08, T-45 |
| [T-09](T-09-config.md) | VDCore: 設定と CV・モデルカタログ | 2 | T-04, T-05, T-08, T-10, T-25 |
| [T-11](T-11-store.md) | VDStore | 2 | T-08, T-10 |
| [T-12](T-12-process-runner.md) | VDProcess | 2 | T-10 |
| [T-13](T-13-device-detection.md) | VDDevice: デバイス判定（共存ガードは F-61 で外した） | 3 | T-07, T-09, T-12 |
| [T-14](T-14-ingest-copy.md) | VDDevice: 走査・安定性判定・コピー・登録（＋ AudioProbe） | 3 | T-11, T-13 |
| [T-15](T-15-remount-snapshot.md) | VDDevice: 再マウント・snapshot・IngestService | 3 | T-14 |
| [T-16](T-16-audio.md) | VDAudio: 16 kHz 変換・検証・空き容量 | 4 | T-14 |
| [T-17](T-17-transcribe.md) | VDTranscribe | 4 | T-03, T-09, T-10, T-12, T-45 |
| [T-18](T-18-worker-part-steps.md) | VDPipeline: Worker と Part の工程 | 4 | T-15, T-16, T-17 |
| [T-19](T-19-llm-schema-json.md) | VDLLM: スキーマ・プロンプト・JSON | 5 | T-09, T-45, T-25 |
| [T-20](T-20-llm-mapreduce.md) | VDLLM: チャンク分割・Map-Reduce | 5 | T-19 |
| [T-21](T-21-llama-server.md) | VDLLM: llama-server・ループバック HTTP | 5 | T-03, T-12, T-19 |
| [T-22](T-22-session-steps.md) | VDPipeline: Session の工程 | 5 | T-18, T-20, T-21 |
| [T-23](T-23-models.md) | VDModels | 5 | T-09, T-10, T-21（TestSupport の `BlockingURLProtocol`・`BlockingSessionFactory`） |
| [T-24](T-24-catalog-acceptance.md) | カタログの確定と LLM 受け入れ試験 | 5 | T-22, T-23 |
| [T-26](T-26-notes-raw.md) | VDNotes: sanitize・frontmatter・Raw | 6 | T-09, T-25, T-45 |
| [T-27](T-27-notes-daily.md) | VDNotes: Daily・Timeline・WikiLink | 6 | T-26 |
| [T-28](T-28-notes-write-verify.md) | VDNotes: Vault 確認・書き込み・検証・出力先 | 6 | T-26 |
| [T-29](T-29-pipeline-notes-wiring.md) | VDPipeline: Raw / Daily の工程と tick の配線 | 6 | T-22, T-27, T-28 |
| [T-30](T-30-ui-shell.md) | UI: メニューバーとパネル・AppModel | 7 | T-29 |
| [T-31](T-31-ui-onboarding.md) | UI: はじめに・Vault・モデル・ログイン項目 | 7 | T-30, T-23 |
| [T-32](T-32-diagnostics-attention.md) | 診断・要対応・状態の詳細（`LockObserving` と既定の「無効」実装もここで作る。T-36 が差し替える） | 7 | T-30 |
| [T-33](T-33-migration.md) | voicedock からの乗り換え — 取り下げ（2026-09-22、利用者の決定。PLAN F-60） | 7 | T-29 |
| [T-34](T-34-release-scripts.md) | .app の組み立て・署名・公証・dmg | 7 | T-01, T-03, T-30 |
| [T-35](T-35-e2e-off.md) | 実機 E2E（削除 OFF） | 7 | T-30〜T-32, T-34（実施の前提: T-38, T-39） |
| [T-36](T-36-deletion-policy.md) | 削除条件・ロックの評価 | 8 | T-29, T-07, T-30, T-32 |
| [T-37](T-37-reaper.md) | reaper 実行ファイル | 8 | T-07 |
| [T-38](T-38-deletion-flow.md) | 要求・Session の削除段・reaper の起動・回収・期限切れ・後始末 | 8 | T-36, T-37 |
| [T-39](T-39-skipped-deletion.md) | 根拠 B | 8 | T-38 |
| [T-40](T-40-deletion-enabler.md) | 有効化・無効化と常時表示 | 8 | T-38, T-30 |
| [T-41](T-41-backlog.md) | 後追い（過去分・手動で消した分） | 8 | T-30, T-32, T-38 |
| [T-42](T-42-e2e-on.md) | 実機 E2E（削除 ON）とゲート | 8 | T-34, T-35, T-36〜T-41 |
| [T-43](T-43-readme.md) | README と文書テスト | 9 | T-42 |
| [T-44](T-44-release-v1.md) | v1.0 のリリース | 9 | T-34, T-42, T-43 |
