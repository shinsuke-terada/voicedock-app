# 進捗と再開の手順（2026-09-21 時点。**実装中**）

## 済んだこと

1. **仕様書の確認と修正（v1.1）** — `tmp/witty-gliding-clover.md`（元の v1 は `tmp/witty-gliding-clover.orig.md`）
   - 参照実装 voicedock@d3d595e と全節を突き合わせ（移植メモ `docs/porting-notes/V1〜V7`）、独立レビュー（`R1-spec-review.md`）とチケット執筆で見つかった問題を反映
   - 変更の一覧は付録 F（**F-01〜F-55**）、voicedock との意図的な差分は付録 D（**X-01〜X-36**）
2. **チケットの土台** — `00-api-map.md`（モジュールをまたぐ名前の契約。§15 に TestSupport の部品の作り手、§16 に地図に行の無い公開 API の索引）、`README.md`（共通規約・チケットの形・依存順の目次）
3. **チケット 45 本（P0 と T-01〜T-45）を全部執筆** — 合計 約 33,000 行
4. **ConfigEffect（CE）のテストの割り当て** — 設定 93 キーのうち 93 キーに `CE <keyPath>` テストを 16 チケットへ配置（新規 52・改名 27）。`ConfigEffectPending.owners` は空にできる
5. **最終の整合確認と修正** — 独立レビュー（`R2-final-consistency.md`。高 4・中 9・低 12）を全件反映し、機械検査（`docs/porting-notes/check-tickets.py`）が **0 件**

### 最終の整合確認で直した主なもの

| 種類 | 内容 |
|---|---|
| 循環 | `GoldenCase.orderedObject` は T-45 の extension（`Tests/TestSupport/GoldenCase+PyJSON.swift`）が持つ。T-25 は本体を持たない |
| Phase をまたぐ依存 | `LockObserving` / `DisabledLockObserver` / `LockObservation` / `LockDisplay` / `ReaperStatus` / `DeletionReadiness` / `DeviceWritability` は **T-32**（Phase 7）が `LockObserving.swift` に作る。T-36（Phase 8）の `LockEvaluator` が準拠して差し替える。T-30 の Bootstrap は Phase 7 だけで組める（`observeReaperConf: { .missing }`、`locks` は `DisabledLockObserver`） |
| PT-11 | 識別子 `reaperConf` を許可場所の外で使わない → ラベルは `reaperConfObservation:`、`LockDisplay` の欄は `confState` |
| F-54 | 効かない設定 `sections.summary.maxItems` / `.timeline.maxItems` を仕様から削除（`maxItems` を持つのは 5 節だけ） |
| M-1 | `RecordingRow.errorCodeRaw`（`error_code` の生の文字列）を足し、未知のコードを Daily の警告に出す（T-11 → T-29 / T-32） |
| 死んだ API | 誰も呼ばない `IngestService.remountAllReadOnly()` を削除（T-40 は `scanNow()` を使う） |
| 表記 | 表の列数・`\|` の退避・`PLAN §` の参照切れ・`Acceptance*` の部品名・init の引数の並び |

## 残っていること（計画側）

**なし。** 機械検査は 0 件:

```
python3 docs/porting-notes/check-tickets.py
```

この検査は、表の列数・目次とファイルの対応・チケット間の参照・`PLAN §` の節・規範 ID（CV / ND / RV / DR / PT / CR / PR）・作るものの重複・PT-11 の語・F-54 で消したキー・地図の未使用の型・チケットの 10 節の形を見る。**チケットを直したら毎回これを回す。**

## 実装の進み具合（2026-09-21）

| チケット | 状態 | 備考 |
|---|---|---|
| P0 | 一部 | 章 1・14（識別子）と章 11（対象外）だけ。残りは下の「実施の予定」 |
| T-01 | マージ済み | PR #2 |
| T-02 | マージ済み | PR #12。CI は開発機のセルフホストランナー（利用者の決定。PLAN §10.8・F-56）。ブランチ保護は 403 で使えない |
| T-03 | マージ済み | PR #6 |
| T-04 | マージ済み | PR #16。PLAN §9.4 より厳しくした（利用者の承認。F-57） |
| T-06 | マージ済み | PR #8 |
| T-07 | マージ済み | PR #14。ディスクイメージのテスト 5 本は未実行（実機を抜いてから `make test-disk`） |
| T-25 | マージ済み | PR #4 |
| T-33 | 取り下げ | 2026-09-22、利用者の決定（voicedock からの乗り換えは考慮しない。PLAN §8.13・F-60）。PR #70 は閉じた。E2E-18 も取り下げ（番号は詰めない） |
| T-45 | マージ済み | PR #10 |
| F-61 | 作業中 | 2026-09-22、利用者の決定（このアプリが完成したら voicedock は動かさないので共存ガードは不要）。`CoexistenceGuard`・`IngestState.coexistenceBlocked`・`coexistence_blocked`・Worker の保留・StatusLine の分岐を外した。DR-13 は打ち消しの行、E2E-15 は取り下げ（番号は詰めない）。診断は 15 件 ＋ DR-09 = 16 件になる |

### 利用者と決めたこと

- Phase 0 は分割する。実機の手順は、それが効くチケットの直前に【利用者が行う】として渡す（`docs/POC.md` の「実施の予定」）
- `BUNDLE_ID=io.github.shinsuke-terada.VoiceDock`、`TEAM_ID=ZCWP35H248`。Developer ID Application の証明書は T-34 までに利用者が作る
- CI は開発機のセルフホストランナー。ディスクイメージのテストは CI で走らせない
- マージは毎回利用者が行う
- voicedock からの乗り換えは考慮しない（2026-09-22）。T-33 と E2E-18 を取り下げた（PLAN F-60）。T-11 の `imported_keys` の表と T-14 の除外は空の表として残る
- voicedock と同時には動かさない（2026-09-22）。共存ガード・DR-13・E2E-15 を取り下げた（PLAN F-61）。T-32・T-35・T-43 のチケットから外し、マージ済みのチケットには注記だけを足した

### 実装で分かった共通の約束（後続のチケットにも効く）

- URL からパス文字列を取るときは `url.path(percentEncoded: false)` だけ（00-api-map §0）。チケットが `.path` と書いていても上位に合わせ、チケットを直す。ディレクトリの URL は末尾に `/` が付く
- 環境変数は `TestEnvironment.value(_:)` を通して読む（PLAN §10.1）
- テスト用のディスクイメージのボリューム名に `DJIMIC3` を使わない（PLAN §10.2。`DiskImageVolume` がコードで拒む）
- macOS の `/bin/bash` は 3.2。全角文字の直前の変数は `${var}` と書く（`$var（` は `set -u` で落ちる）
- チケットの逐語コードが `swift format` で落ちるときは整形に合わせ、チケットも直す
- T-01 の目印（`ModuleMarker.swift`・`TargetMarker.swift`）は、そのモジュールに最初の実ファイルを足す PR で消す

## 次にやること

1. `README.md` の目次の依存順。T-05 → T-08 → T-10 → T-09 / T-11 / T-12 → Phase 3 以降
2. T-13 / T-15 / T-28 の前に、実機の P0-01 / P0-02 / P0-12 を利用者に頼む。T-31 / T-37 の前に P0-03 / P0-08
3. P0-04〜07・09（whisper / llama の実測）は、モデルと音声の用意ができたら行う

実装の進め方は `README.md` の「進め方」（1 チケット = 1 issue = 1 PR、破壊による証明を PR 本文に貼る）。

## 文書の地図

| 文書 | 役割 |
|---|---|
| `tmp/witty-gliding-clover.md` | 計画書（= 実装後の `docs/PLAN.md`）。**最上位** |
| `docs/tickets/00-api-map.md` | モジュールをまたぐ名前の契約。**チケットより上位** |
| `docs/tickets/README.md` | 共通規約・チケットの形・依存順の目次 |
| `docs/tickets/T-*.md` | 実装の詳細仕様 |
| `docs/porting-notes/V1〜V7` | voicedock の逐語の移植メモ（`file:line` つき） |
| `docs/porting-notes/R1・R2` | 独立レビューの報告 |
| `docs/porting-notes/BRIEFING.md` | 作業を頼むときに最初に読ませる説明 |
| `docs/porting-notes/check-tickets.py` | チケット一式の機械検査 |

## 安全の約束（再掲）

- 利用者の実機 DJI Mic 3 が `/Volumes/DJIMIC3` に接続されていることがある。**エージェントもテストも /Volumes 配下の実機に diskutil・書き込み・削除・再マウントを一切行わない**。ディスクイメージは `/Volumes` 以外に attach する
- voicedock の作業ツリー（`/Users/terada/Projects/voicedock`）には書き込まない。読むのは `git show d3d595e:<path>` だけ
- 同時に動かすエージェントは 4 本まで（8 本で使用量の上限に当たった）
