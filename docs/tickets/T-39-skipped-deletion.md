# T-39 VDPipeline: 根拠 B（無音・重複の元音声の削除要求）と ND の集合の一致

| 項目 | 値 |
|---|---|
| ID | T-39 |
| Phase | 8（削除） |
| 前提 | T-38（`DeletionDependencies`・`RequestWriter`・`ResultCollector`・`RequestExpirer`・`ScriptedIngest`・`DeletionScene+Steps`・`Worker+DeletionStages.swift` の空の段）。間接に T-36（`DeletionPolicy`・`TwinPart`・`DeletionScene`）、T-37（層 R1・R3 の ND）、T-05（`SpecCoverage`） |
| 見積もり | Sources 約 100 行、Tests 約 650 行 |
| 後続 | T-40（`enableSkippedDeletion` で `deleteSkippedSource` を真にする）、T-42 |

## 1. 目的

保全すべき本文が無い SKIPPED の Part（無音・重複）の元音声に、**SKIPPED のまま**削除要求を書く（PLAN §8.9.5 の根拠 B。`settleSkippedDeletions`）。
回収と期限切れは T-38 の全件回収・期限切れがそのまま拾う（規則を共有し、分かれるのは状態の扱いだけ）。
層 A の ND-33〜35 を書き、ND のテストがそろったので SPEC 同期の ND の集合の一致（層ごと）を有効にする。

## 2. 参照

- PLAN §8.9.5「根拠 B（settleSkippedDeletions）」、§8.9.1（`nothingToPreserve`・`skipReasonIsBacked`・SKIPPED のまま。SM-20）、§8.9.6（回収は根拠 A と共有）、§8.9.7（期限切れ）、§5.4（tick の順）、§10.3（SPEC 同期の ND の層）、付録 B.1（ND-03・06・33〜35）
- 00-api-map §11（`SkippedSettler.swift`）
- voicedock@d3d595e: `src/voicedock/pipeline.py:814-884`（`settle_skipped_deletions`）、`:885-919`（`_twin_of`）、
  `tests/unit/test_no_delete.py:435-600`（無音）、`:696-842`（重複）、`:2002-2090`（根拠 B の往復）
- 移植メモ V3 §6.7、§9
- T-05 §4（`SpecCoverage.activated`）

## 3. 作るもの

| パス | 中身 |
|---|---|
| `Sources/VDPipeline/SkippedSettler.swift` | `SkippedSettler`（internal） |
| `Sources/VDPipeline/Worker+DeletionStages.swift`（変更） | `stageSettleSkippedDeletions` の本体 |
| `Tests/PolicyTests/SpecSync/SpecCoverage.swift`（変更） | `activated` に `.nd` を足す |
| `Tests/NoDeleteTests/SkippedSettlerNDTests.swift` | 正の対照（無音・重複）・ND-33・34・35 |
| `Tests/VDPipelineTests/SkippedSettlerTests.swift` | |
| `Tests/VDPipelineTests/SkippedDeletionRoundTripTests.swift` | 根拠 B の往復（回収・拒否・期限切れ。1 本は `.diskImage` で本物の reaper） |
| `Tests/VDPipelineTests/DeletionStagesWiringTests.swift`（行を足す） | tick の中で根拠 B の要求を書く |
| `Tests/PolicyTests/ConfigEffectPending.swift`（変更） | 1 キーを消す（§6.5） |

## 4. 仕様

共通は T-38 §4 と同じ（公開メソッドは例外を投げず、Store の予期しない例外は `deps.warn`。鍵の照合は `DeletionPolicy.sameKey`）。

### 4.1 `SkippedSettler.swift`

```swift
// 根拠 B（PLAN §8.9.5）: 保全すべき本文が無い SKIPPED の Part に、SKIPPED のまま削除要求を書く（①ID → ②要求ファイル。遷移しない。SM-20）。
// 回収・期限切れは T-38 の ResultCollector / RequestExpirer が根拠 A と同じ規則で拾う。
import VDContract
import VDCore
import VDStore

struct SkippedSettler {
    let deps: DeletionDependencies
    /// 書いた要求の数
    func settleSkippedDeletions() async -> Int
}
```

`settleSkippedDeletions()`（逐語。`requested = 0`）:
1. `deps.config.cleanup.deleteSkippedSource == false` なら `return 0`（**何も読まない**）
2. `guard let snapshot = await deps.freshSnapshot() else { return 0 }`（新鮮な snapshot だけを使う。DEL-20）
3. `ctx = await deps.context(snapshot: snapshot)`。`ctx.locks.readiness != .configured` なら `return 0`（式の共通項が必ず落とすので、ノートと transcript を読む前にやめる）
4. `skipped = try deps.store.recordings(status: .skipped)`（started_at, partkey 順。例外 → `deps.warn(e)`、`return 0`）
5. **デバイスに今在るものだけ**（過去の件数に比例させない）:
   `present = skipped.filter { p in guard let rel = p.sourcePath, let obs = snapshot.devices[p.deviceID] else { return false }; return obs.relpaths.contains(where: { DeletionPolicy.sameKey($0, rel) }) }`
6. `first = deps.config.cleanup.deleteEvaluationBackoffSeconds.first ?? 0`（**先頭の値**。最小値ではない）、`now = deps.clock.now()`
7. `for stale in present`（1 件ごとに `do { … } catch { deps.warn(error) }`）:
   1. **読み直す**: `guard let part = try deps.store.recording(stale.partkey), part.status == .skipped else { continue }`
   2. `guard let sessionKey = part.sessionKey else { continue }`
   3. `guard part.sourceDeletedAt == nil, part.deleteRequestID == nil else { continue }`（決着済み・結果待ち）
   4. `guard !deps.pended.contains(part.partkey) else { continue }`（この tick で拒否されたものを再要求しない。DEL-11）
   5. `if let updated = deps.zone.parseISO(part.updatedAt), now - updated < Int64(first) * 1000 { continue }`（間引き。拒否の直後は pend が updated_at を今にするので、次の要求は backoff[0] 秒後。読めない updated_at は間引かない）
   6. `guard let session = try deps.store.session(sessionKey) else { continue }`
   7. `parts = try deps.store.recordings(inSession: sessionKey)`、`twin = try TwinPart.load(for: part, store: deps.store)`（双子の引き方は T-36 §4.7.2）
   8. `DeletionPolicy.canDeleteSource(DeletionCandidate(part: part, session: session, parts: parts, twin: twin), ctx)` が偽なら飛ばす
   9. `guard let id = try RequestWriter(deps: deps).write(part: part, sessionKey: sessionKey) else { continue }`（① の `updateRecordingIfStatus(status: .skipped)` が状態の変化を捕まえる）
   10. `deps.log.info(.deleteRequested, [(.requestID, .string(id)), (.recordingKey, .string(part.partkey)), (.sessionKey, .string(sessionKey))])`
   11. `requested += 1`
8. `return requested`

- **遷移しない**。「結果を待っている」は `delete_request_id != nil` だけで表す（PLAN §8.9.1 の末尾）。`recordPartTransition` を呼ぶと `error_code` が上書きされ、Daily の「（無音）」表示と根拠 B の判定が壊れる（SM-20）
- 結果の扱い（T-38）: DELETED → `source_deleted_at` を書き ID を外す（SKIPPED のまま）、拒否・`still_in_inventory` → ID を外すだけ（`pend` の SKIPPED の分岐）、期限切れ → 要求と結果を取り下げ ID を外すだけ

### 4.2 `Worker+DeletionStages.swift`（本体）

```swift
    func stageSettleSkippedDeletions(_ ctx: TickContext) async {
        _ = await SkippedSettler(deps: DeletionDependencies(ctx: ctx)).settleSkippedDeletions()
    }
```
（tick の中では evaluateDeletions の後・runReaperIfNeeded の前。snapshot が新鮮な tick だけ。T-18 の枠のまま）

### 4.3 `SpecCoverage.swift`（T-05 のファイルの変更）

`static let activated: Set<SpecIDKind>` に `.nd` を足す（既に在る `.cv`・`.dr`・`.rv` は残す）。コメントの「T-39 が `.nd` を足す」をそのまま残す。

これで `activatedKindsMatchSpec`（SPEC の ND の集合 = テストの表示名の ND の集合）と `ndLayersAreCovered`（付録 B.1 の層ごとに 1 本以上）が効く。マージの時点の対応（確かめてから有効にする）:

| ND | 層 | テスト（チケット） |
|---|---|---|
| ND-01〜09 | A | `DeletionPolicyNDTests.nd01…nd09`（T-36） |
| ND-18・19・20・24・25・28・29・37 | R2 | `TargetIdentityTests`（T-07） |
| ND-18・19・20・23・24・25・28・29・31・37・39 | R3 | reaper × ディスクイメージ（T-37） |
| ND-21・22・23・26・31・32・36・41・45 | A | `DeletionPolicyNDTests`（T-36） |
| ND-22・27・38・39・40・43・44 | R1 | reaper × 普通のディレクトリ（T-37） |
| ND-33・34・35 | A | `SkippedSettlerNDTests`（このチケット） |
| ND-41・42・46・47 | A | `DeletionFlowNDTests`（T-38。ND-41 は T-36 にもある） |

- 表示名は `ND-nn [層] …` で始まっていること（T-05 の TestNameIndex が集める）。1 つでも欠けていたら、このチケットで足さずに作り手のチケットに差し戻す（ID を持たないテストで数を合わせない）

## 5. ログ（このチケットが出すもの）

| イベント | レベル | フィールド（この順） | 出す場所 |
|---|---|---|---|
| `delete_requested` | INFO | `request_id`, `recording_key`, `session_key` | settleSkippedDeletions |
| `source_delete_pending` / `source_delete_skipped` | WARNING | T-38 §5 と同じ（RequestWriter の ②失敗・①の衝突） | RequestWriter |

## 6. テスト

共通: T-38 §6 と同じ。無音の舞台 = `DeletionScene(status: .skipped, errorCode: .noSpeechDetected)`。重複の舞台 = 既定の舞台（既定の Part が双子）に
`dup = addPart(fileName: "TX00_MIC002_20260912_093000_orig.wav", startedAt: "2026-09-12T09:30:00+09:00", status: .skipped, errorCode: .duplicateContent, duplicateOf: DeletionScene.partkey, transcript: false, inRawNote: false)`。
「ロック B を開ける」= `updateConfig { $0.cleanup.deleteSkippedSource = true }`（その後で deps を作る）。「間引きを越える」= `clock.advance(seconds: 60)`（既定の backoff の先頭）。
`settle = await SkippedSettler(deps: deps).settleSkippedDeletions()`。

### 6.1 `Tests/NoDeleteTests/SkippedSettlerNDTests.swift`（`@Suite("根拠 B の ND（層 A）")`）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `noSpeechActuallyRequestedWhenLockBIsOpen` | 正の対照 [A] 無音の SKIPPED はロック B を開けると要求が 1 件書かれ SKIPPED のまま | 無音の舞台、ロック B、間引きを越える | `settle == 1`、要求の partkey が既定の partkey、Part は SKIPPED・`errorCode == .noSpeechDetected`・`deleteRequestID` が要求の request_id、events の本数が増えない、`canDeleteSource` が真 |
| `duplicateActuallyRequestedWhenTwinIsPreserved` | 正の対照 [A] 重複は双子の本文が揃えばロック B で要求が 1 件（重複の側に） | 重複の舞台、ロック B、間引きを越える | `settle == 1`、要求の partkey が `dup`（双子ではない）、`dup` は SKIPPED・`errorCode == .duplicateContent`、双子の Part は RAW_SAVED のまま |
| `nd33SourceMissingIsNeverDeleted` | ND-33 [A] SOURCE_MISSING の SKIPPED はロックを開けても消さない | `DeletionScene(status: .skipped, errorCode: .sourceMissing)`、ロック B、間引きを越える | `settle == 0`、`requests() == []`、`canDeleteSource` が偽 |
| `nd34NoSpeechWithoutTranscript` | ND-34 [A] 無音でも transcript が無いか壊れていれば消さない（パラメータ化） | 無音の舞台、ロック B、間引きを越える。(a) transcript を消す (b) `"{こわれた"` を書く | `settle == 0`、要求無し、`skipReasonIsBacked` が偽 |
| `nd35DuplicateWhoseTwinTextIsNotPreserved` | ND-35 [A] 重複は双子の本文が Vault で確認できなければ消さない（パラメータ化） | 重複の舞台、ロック B、間引きを越える。(a) 双子の Raw ノートを消す (b) `replaceInRawNote(DeletionScene.partkey, with: "DJIMIC3/other/other.wav", updateSHA: true)` (c) 双子の transcript を消す | `settle == 0`、要求無し |

### 6.2 `Tests/VDPipelineTests/SkippedSettlerTests.swift`（`@Suite("SkippedSettler")`）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `lockBClosedReadsNothing` | CE cleanup.deleteSkippedSource 偽なら何も読まない | 無音の舞台（ロック B は既定の偽）、間引きを越える。対照はロック B を開けた同じ舞台（`recentSkipWaitsForTheFirstBackoff` の (3) で 1） | 0、`scene.verifier.verifiedURLs == []`（readiness も評価しない） |
| `recentSkipWaitsForTheFirstBackoff` | SKIPPED になった直後は backoff の先頭の秒数だけ待つ | 無音の舞台、ロック B。(1) そのまま (2) `advance(59)` (3) さらに `advance(1)` | 0・0・1 |
| `backoffUsesTheFirstElementNotTheMinimum` | 間引きは backoff の先頭の値（最小値ではない） | `deleteEvaluationBackoffSeconds = [300, 60, 900, 3600]`。(1) `advance(60)` (2) `advance(240)` | 0・1 |
| `onlyPartsOnTheDeviceAreEvaluated` | デバイスに今在るものだけを評価する | 無音の Part を 2 本（既定と、10:00 の `addPart(…, status: .skipped, errorCode: .noSpeechDetected, onDevice: false)`）、ロック B、間引きを越える | 1、要求の partkey は既定の Part だけ |
| `staleSnapshotDoesNothing` | snapshot が古い・無ければ何もしない（パラメータ化） | completedAt = now − 901 秒 / nil | 0 |
| `lockOneAlsoStopsGroundB` | ロック 1 は根拠 B にも掛かる | ロック B を開け `deleteSourceAudio = false` | 0 |
| `readOnlyAlsoStopsGroundB` | ロック 2-B も根拠 B に掛かる | `snapshot(readOnly: true)` | 0 |
| `staysSkippedAndKeepsItsReason` | 要求を書いても SKIPPED と error_code が変わらない（SM-20） | 無音の舞台で settle | SKIPPED、`errorCode == .noSpeechDetected`、`events(entity: .recording, key: pk)` の本数が settle の前と同じ |
| `awaitingPartIsNotRequestedAgain` | 結果待ち（ID が在る）は再要求しない | settle の後にもう一度 settle（`advance(60)`） | 2 回目は 0、要求 1 件のまま |
| `alreadyDeletedIsNotRequested` | source_deleted_at が在れば要求しない | `updateRecording(pk, [.sourceDeletedAt("2026-09-12T11:00:00+09:00")])` | 0 |
| `withoutSessionKeyIsSkipped` | session_key が無ければ飛ばす | `updateRecording(pk, [.sessionKey(nil)])` | 0 |
| `pendedThisTickIsNotRequested` | この tick で拒否した Part は再要求しない（DEL-11） | `pended.insert(pk)` の deps | 0。対照: 新しい PendedPartkeys では 1 |
| `oldSkippedWithoutRequestIsNotTreatedAsWaiting` | 要求を出していない古い SKIPPED を結果待ちと見ない | 無音の舞台、`advance(3600 + 60)`、先に `RequestExpirer(deps:).expireDeleteRequests()` | 期限切れは何もしない（`source_delete_pending` が無い）、その後の settle は 1 |
| `queueWriteFailureKeepsSkipped` | ② が書けなければ ID を外して SKIPPED のまま | queue/delete を `chmod 0o555` | 0、ID nil、SKIPPED、`reason=queue_write_failed error_code=DELETE_QUEUE_FAILED` |
| `duplicateWithoutRecordedTwinIsNotRequested` | duplicate_of が nil の重複は要求しない（v5.55 以前の重複） | 重複を `duplicateOf: nil` で足す | 0 |
| `twinInAnotherSessionIsUsed` | 双子が別の日でも双子の Session で根拠 A を見る | `addSession(key: "DJIMIC3:20260911", dayDate: "2026-09-11")`、双子（`TX_MIC001_20260911_090000/TX00_MIC001_20260911_090000_orig.wav`）をその日に RAW_SAVED で足し `writeRawNote(sessionKey: "DJIMIC3:20260911")`、重複の `duplicateOf` をその双子に | 1 |
| `emptySkippedListDoesNothing` | SKIPPED が無ければ 0（TEST-28） | 既定の舞台、ロック B | 0 |

### 6.3 `Tests/VDPipelineTests/SkippedDeletionRoundTripTests.swift`（`@Suite("根拠 B の往復")`）

準備: 無音の舞台、ロック B、間引きを越える、`settle == 1`（`id` = DB の ID）、要求ファイルを消す（reaper の姿）。回収は `ResultCollector(deps:).collectDeleteResults(reaperScanGeneration: 2)`。

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `deletedNoSpeechIsRecordedAndStaysSkipped` | 往復: DELETED を回収すると SKIPPED のまま source_deleted_at が入る | DELETED の結果、ingest を `snapshot(generation: 2, relpaths: [])` に | SKIPPED・`errorCode == .noSpeechDetected`・`sourceDeletedAt == "2026-09-12T12:01:00+09:00"`・ID nil、結果が無い、`source_deleted` のログ。続けて `advance(60)` で settle → 0 |
| `rejectedNoSpeechIsNotRetriedAtOnce` | 往復: 拒否されたら SKIPPED のまま ID を外し、同じ周回で再要求しない | MISMATCH `size_mismatch`、ingest は既定の snapshot（ファイル在り）。同じ deps で collect → settle | SKIPPED・`errorCode == .noSpeechDetected`・ID nil・`sourceDeletedAt == nil`、`reason=size_mismatch`、settle は 0、`requests() == []`。対照: 新しい deps で `advance(60)` → settle 1 |
| `stillInInventoryKeepsSkipped` | 往復: DELETED なのに走査に在れば SKIPPED のまま ID を外す | DELETED の結果、`snapshot(generation: 2)`（ファイル在り） | SKIPPED、ID nil、`reason=still_in_inventory` |
| `unansweredNoSpeechRequestExpires` | 往復: 結果が来ないまま期限を過ぎたら取り下げる（reaper が居ないときの正常な姿） | 要求ファイルを消さずに `advance(3601)`、`RequestExpirer(deps:).expireDeleteRequests()` | SKIPPED・`errorCode == .noSpeechDetected`・ID nil、`requests() == []` |
| `realReaperDeletesANoSpeechPart` | 往復（本物の reaper × FAT32）: 無音の元音声が消え、SKIPPED のまま記録される（`.diskImage`） | `.enabled(if: TestEnvironment.diskTests)`。T-38 §6.10 の準備を無音の舞台（`DeletionScene(status: .skipped, errorCode: .noSpeechDetected, in: tmp, diskImage: image)`）で。ロック B、`advance(60)`、settle → `runReaperIfNeeded(reaperScanGeneration: 0)` | イメージ上のファイルが無い、SKIPPED・`sourceDeletedAt` 在り・ID nil |

（時計: 往復の準備で `advance(60)` しているので、回収の時刻は `12:01:00+09:00`）

### 6.4 `Tests/VDPipelineTests/DeletionStagesWiringTests.swift`（行を足す）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `tickSettlesSkippedParts` | tick の中で根拠 B の要求を書く（settleSkippedDeletions の段の配線） | T-38 §6.9 の `makeWorld()` に `deleteSkippedSource = true`。`pk = registerPart()` を `StorePaths.advancePart(world.store, partkey: pk, to: .skipped, errorCode: .noSpeechDetected)`、transcript を置き、`addSession(key: "DJIMIC3:20260829", day: "2026-08-29", status: .open)` と `updateRecording(pk, [.sessionKey("DJIMIC3:20260829")])`、`clock.advance(seconds: 60)`、tick | 要求 1 件、Part SKIPPED・ID 在り、`delete_requested` のログ |
| `staleTickDoesNotSettle` | snapshot が古い tick では根拠 B の段を行わない | 上と同じで completedAt = now − 901 秒 | 要求無し |

### 6.5 `ConfigEffectPending.swift`（PolicyTests。T-09 §9）

`cleanup.deleteSkippedSource` の 1 行を消す（CE テストは §6.2 の `lockBClosedReadsNothing`）。

## 7. 破壊による証明

| # | 壊し方（1 か所だけ） | 落ちるべきテスト |
|---|---|---|
| 1 | `deleteSkippedSource` の早期の return を消す（式の項は残る） | `lockBClosedReadsNothing`（readiness を評価する）。ND-03 / ND-06 は T-36 の式の項が受け止める（多重防御。PR に書く） |
| 2 | 手順 5 の「デバイスに在るもの」の絞り込みを消す | 落ちない（式の事前確認が同じ条件を見るので結果は同じ。これは費用の規則: 過去の SKIPPED の件数に比例して読まない）。壊したのに通ったことを PR に書き、レビュー項目として残す |
| 3 | 間引きの `first` を `min()` にする | `backoffUsesTheFirstElementNotTheMinimum` |
| 4 | 間引きを消す | `recentSkipWaitsForTheFirstBackoff`、`rejectedNoSpeechIsNotRetriedAtOnce`（pended も消したとき） |
| 5 | 読み直しを消す（一覧の行を使う） | 落ちない（直列の Worker の中では一覧と読み直しの間に行が変わらない。voicedock と同じ防御）。① の `updateRecordingIfStatus(status: .skipped)` が状態の変化を捕まえることは T-38 の `writerRefusesAStaleRow` が見る。PR に書く |
| 6 | `deleteRequestID == nil` の確認を消す | `awaitingPartIsNotRequestedAgain` |
| 7 | `sourceDeletedAt == nil` の確認を消す | `alreadyDeletedIsNotRequested`（事前確認がデバイスに在ることで通るように、ファイルを置いたまま） |
| 8 | pended の確認を消す | `pendedThisTickIsNotRequested` |
| 9 | 要求の後に `recordPartTransition(.skipped → …)` を足す | `staysSkippedAndKeepsItsReason`（IllegalTransition か error_code の上書き） |
| 10 | twin を nil で渡す | `duplicateActuallyRequestedWhenTwinIsPreserved`、`twinInAnotherSessionIsUsed` |
| 11 | `SpecCoverage.activated` から `.nd` を外す | （外すと検査が止まるだけで落ちない。逆に ND のテストを 1 本消して `activatedKindsMatchSpec`・`ndLayersAreCovered` が落ちることを確かめる） |
| 12 | `stageSettleSkippedDeletions` の本体を空に戻す | `tickSettlesSkippedParts` |

## 8. 受け入れ条件

- [ ] `SkippedSettler` が §4.1 の手順どおりで、要求を書くのは `RequestWriter` 経由だけ（PR-09）
- [ ] 根拠 B の Part を遷移させるコードが無い（`SkippedSettler.swift` に `recordPartTransition` が無い）
- [ ] ND-33・34・35 の `[A]` のテストと、無音・重複の正の対照が通る
- [ ] `SpecCoverage.activated` に `.nd` が在り、`SpecCoverageTests`（`activatedKindsMatchSpec`・`ndLayersAreCovered`）が通る
- [ ] `make test` と `make test-disk`（`realReaperDeletesANoSpeechPart`）が通る
- [ ] 破壊による証明の結果が PR 本文にある

## 9. SPEC の変更

なし（ND の表は付録 B.1 のまま。集合の一致の検査を有効にするだけ）。

## 10. マージ後にやること

- T-40 の `enableSkippedDeletion(confirmation:)` が `deleteSkippedSource = true` を書けば、この段が効く
- T-42 の実機 E2E で、無音の録音 1 本が消えて Daily の「（無音）」表示が残ることを確かめる（【利用者が行う】）

## 11. API 地図への変更提案

1. §11 の `SkippedSettler.swift`: `struct SkippedSettler { let deps: DeletionDependencies; func settleSkippedDeletions() async -> Int }`（internal）
2. PLAN §8.9.5 の根拠 B の手順に「readiness が configured でなければ読まずに 0」（式の共通項が必ず落とすので、ノートと transcript を読む前にやめる）と「この tick で PENDING に落とした Part は飛ばす（DEL-11）」を足す（振る舞いは式と同じ。費用と明示のため）
