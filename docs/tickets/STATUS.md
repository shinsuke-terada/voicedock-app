# 進捗と再開の手順（2026-09-21 時点。**計画は完了。次は実装**）

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

## 次にやること（実装）

1. **Phase 0: P0（実機 PoC）** — `P0-poc.md` の P0-01〜12。**実機の操作は利用者が行う**（DJI Mic 3 の接続・`diskutil` の観察・BUNDLE_ID と Team ID の決定）。ここで決めた値が T-01 の前提
2. **Phase 1: T-01 → T-02 / T-03 → T-04 / T-05 / T-25** — リポジトリの骨組み・CI・vendor のビルド・PolicyTests・SPEC 同期・golden 生成
3. 以降は `README.md` の目次の依存順（Phase 2〜9）

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
