# T-38 VDPipeline: 削除要求・Session の削除段・reaper の起動・結果の回収・期限切れ・後始末

| 項目 | 値 |
|---|---|
| ID | T-38 |
| Phase | 8（削除） |
| 前提 | T-36（`DeletionPolicy`・`LockEvaluator`・`ReaperRunner` の検証・`DeletionScene`・`StorePaths`・`FakeSignatureVerifier`）、T-37（reaper 実行ファイル・`ReaperBinary`）。間接に T-18（Worker の段・`TickContext`・`IngestPort`・`FakeIngest`・`PipelineWorld`）、T-22（`SessionSteps+Deletion.swift` の口）、T-29（`PartSteps+Deletion.swift` の口・`installVault`）、T-07（`DiskImageVolume`）、T-10（`SafeUnlink`）、T-11（`Store`）、T-12（`ProcessRunner`） |
| 見積もり | Sources 約 750 行、Tests 約 1,600 行 |
| 後続 | T-39（根拠 B の要求）、T-40（有効化）、T-41（後追い）、T-42（実機 E2E） |

## 1. 目的

PLAN §8.9.5〜§8.9.7 のアプリ側の削除の流れを実装する: Part の要求（①ID → ②要求ファイル → ③遷移）、Session の削除段（削除できなければ完了させて staging を片付ける、未接続なら待つ）、
reaper の起動（署名と版を検証し直してから）と、**reaper の後に始まった走査**を待ってからの結果の回収（同じ秒問題を構造で消す）、期限切れ、backoff に従う再評価。
Worker の tick の空の段（T-18）と、Raw の直後・SAVED の直後の空の口（T-29・T-22）に中身を入れる。

## 2. 参照

- PLAN §8.9.5（`deleteSourcesIfSafe`・`completeWithoutDeleting`・`finishCleanup`・`requestDeletions`・事前確認・`evaluateDeletions` の backoff）、§8.9.6（`runReaperIfNeeded`・`collectDeleteResults`・`pend`）、§8.9.7（期限切れ）、
  §8.9.1（「結果を待っている」= `delete_request_id != nil`）、§8.9.2（readiness と writability で分ける扱い）、§8.9.3（起動の直前の検証）、§4.4（要求と結果の JSON・書く順）、§5.4（tick の順・`TransitionConflict`）、§5.5（Raw の直後の評価）、
  §9.2（SafeUnlink の `queueDelete` / `queueResult` / `staging`）、§10.5（層 A・正の対照・往復は結合テスト）、付録 A.2（遷移）、付録 A.3（DELETE_QUEUE_FAILED・DELETE_TIMEOUT・SOURCE_IDENTITY_MISMATCH・SOURCE_DELETE_FAILED）、付録 A.4、付録 B.1（ND-42・46・47）
- 00-api-map §11（`DeletionRequester.swift` / `SessionDeletionStage.swift` / `ResultCollector.swift` / `RequestExpirer.swift`・`ReaperRunner.swift`）、§15
- voicedock@d3d595e:
  - `src/voicedock/pipeline.py:670-748`（`request_deletions`）、`:750-812`（`delete_sources_if_safe`）、`:921-1002`（`collect_delete_results`）、`:1004-1038`（`_expire_delete_requests`）、`:1040-1070`（`_delete_pending`）、`:1075-1092`（`_complete_without_deleting`）、`:1855-1868`（`delete_evaluation_delay`）
  - `src/voicedock/cleaner.py:391-460`（`request_part_deletion`・`write_request`・`_request_id`）、`:461-488`（`cleanup_staging`）、`:489-514`（`awaits_delete_result`）、`:531-564`（`read_results`）、`:601-690`（`source_is_gone`・`withdraw_*`・`discard_result`）
  - `src/voicedock/worker.py:342-389`（`evaluate_deletions`）
  - `tests/unit/test_no_delete.py:326-381`（正の対照）、`:1463-1680`（削除段と配線）、`:1888-2000`（同じ秒・同じ周回）、`:2092-2405`（回収・期限切れ）、`tests/unit/test_worker_loop.py:869-899`（backoff の 4 事例）、`tests/integration/test_delete_roundtrip.py:43-120`
- 移植メモ V3 §6.2〜§6.6、§7、§9

## 3. 作るもの

| パス | 中身 |
|---|---|
| `Sources/VDPipeline/DeletionDependencies.swift` | `DeletionDependencies`（internal。1 tick 分の依存） |
| `Sources/VDPipeline/PendedPartkeys.swift` | `PendedPartkeys`（internal。この tick で PENDING に落とした Part） |
| `Sources/VDPipeline/DeleteQueue.swift` | `DeleteQueue`・`DeleteQueueError`・`QueuedResult`（internal。queue/delete と queue/result の読み書き） |
| `Sources/VDPipeline/RequestWriter.swift` | `RequestWriter`（internal。①ID → ②要求ファイル） |
| `Sources/VDPipeline/DeletionRequester.swift` | `DeletionRequester`（internal。`requestDeletions`） |
| `Sources/VDPipeline/SessionDeletionStage.swift` | `SessionDeletionStage`（internal。`deleteSourcesIfSafe`・`completeWithoutDeleting`・`finishCleanup`・`dueSessionKeys`・`isDue`） |
| `Sources/VDPipeline/ResultCollector.swift` | `ResultCollector`（internal。`collectDeleteResults`・`pend`・`runReaperIfNeeded`） |
| `Sources/VDPipeline/RequestExpirer.swift` | `RequestExpirer`（internal。`expireDeleteRequests`） |
| `Sources/VDPipeline/ReaperRunner.swift`（変更） | `run()`・`runTimeout`・`ReaperRunOutcome` を足す |
| `Sources/VDPipeline/DeletionReason.swift`（変更） | `busy` を足す（PLAN §8.9.6「4 は busy」・付録 A.4 の `reaper_failed reason=…\|busy`。§4.7 の `logRun`） |
| `Sources/VDPipeline/TickContext.swift`（変更） | `let pendedPartkeys = PendedPartkeys()` を足す |
| `Sources/VDPipeline/Worker.swift`（変更） | 状態 `var reaperScanGeneration: UInt64 = 0` を足す |
| `Sources/VDPipeline/Worker+DeletionStages.swift`（本体） | 段 collectDeleteResults・expireDeleteRequests・evaluateDeletions・runReaperIfNeeded（settleSkippedDeletions は T-39） |
| `Sources/VDPipeline/PartSteps+Deletion.swift`（本体） | `requestDeletionsAfterRawNote(sessionKey:)` |
| `Sources/VDPipeline/SessionSteps+Deletion.swift`（本体） | `deleteSourcesIfSafe(_:)` |
| `Tests/TestSupport/ScriptedIngest.swift` | `IngestPort` の偽物（scanNow の台本。作り手 T-38） |
| `Tests/TestSupport/DeletionScene+Reaper.swift` | `DeletionScene.installRealReaper()` |
| `Tests/NoDeleteTests/DeletionScene+Steps.swift` | `DeletionScene.deletionDependencies(…)`（internal 型のため test ターゲットごとに置く。下と同じ内容） |
| `Tests/VDPipelineTests/DeletionScene+Steps.swift` | 同上 |
| `Tests/NoDeleteTests/DeletionFlowNDTests.swift` | 正の対照・ND-41（起動）・42・46・47・層 A の全故障 |
| `Tests/VDPipelineTests/DeleteQueueTests.swift` | |
| `Tests/VDPipelineTests/DeletionRequesterTests.swift` | |
| `Tests/VDPipelineTests/SessionDeletionStageTests.swift` | |
| `Tests/VDPipelineTests/ResultCollectorTests.swift` | |
| `Tests/VDPipelineTests/RunReaperTests.swift` | |
| `Tests/VDPipelineTests/RequestExpirerTests.swift` | |
| `Tests/VDPipelineTests/ReaperRunnerTests.swift`（行を足す） | `run()` |
| `Tests/VDPipelineTests/DeletionStagesWiringTests.swift` | Worker の tick を回す（TEST-06） |
| `Tests/VDPipelineTests/DeletionRoundTripTests.swift` | 本物の reaper × FAT32 のディスクイメージ（`.diskImage`） |
| `Tests/PolicyTests/ConfigEffectPending.swift`（変更） | 4 キーを消す（§6.11） |
| `Tests/VDPipelineTests/PipelineIntegrationTests.swift`（変更） | T-29 §6.6 の期待を直す（§6.12。SAVED の直後の削除段が動くので、削除が無効なら Part は COMPLETED、Session は SAVED→CLEANUP→COMPLETED まで進む） |

## 4. 仕様

共通: `p(url)` は `url.path(percentEncoded: false)`。鍵の照合は `DeletionPolicy.sameKey`（スカラー列）。状態名・エラーコード名は enum から取る（PT-06）。reason 語は `DeletionReason` / `IdentityReason` の定数（逐語を書かない）。
**ここの型の公開メソッドは例外を投げない**: Store の予期しない例外は `deps.warn(error)`（= T-18 の `TickContext.warnStore`。`config_warning rule=store`）で記録し、その 1 件を飛ばして残りを続ける（DEL-14）。`TransitionConflict` は個別に扱う。

### 4.1 `PendedPartkeys.swift`

```swift
// この tick で PENDING に落とした（delete_request_id を外した）Part（PLAN §8.9.5 DEL-11: 同じ周回で再要求しない）。
// TickContext が 1 tick に 1 つ持つ（tick ごとに新しくなる）。
import Synchronization

final class PendedPartkeys: Sendable {
    private let keys = Mutex<Set<String>>([])
    init() {}
    func insert(_ partkey: String)
    func contains(_ partkey: String) -> Bool
}
```

`TickContext.swift` に `let pendedPartkeys = PendedPartkeys()` を足す（初期値つきの `let` なので、既存の `TickContext(…)` の呼び出しは変えない。T-29 の `var c = ctx` の複製は同じ集合を共有する）。

### 4.2 `DeletionDependencies.swift`

```swift
// 削除の段の 1 tick 分の依存（PLAN §8.9.5〜§8.9.7）。本番は TickContext から、テストは DeletionScene から作る。
import VDContract
import VDCore
import VDDevice
import VDStore

struct DeletionDependencies: Sendable {
    let layout: HomeLayout
    let store: Store
    let config: AppConfig           // tick の設定（tick の中で変えない）
    let zone: ZonedTime
    let ingest: any IngestPort
    let locks: LockEvaluator
    let volumeOpener: any VolumeOpener
    let clock: any AppClock
    let log: AppLog
    let pended: PendedPartkeys
    let warn: @Sendable (any Error) -> Void

    init(layout: HomeLayout, store: Store, config: AppConfig, zone: ZonedTime, ingest: any IngestPort, locks: LockEvaluator,
         volumeOpener: any VolumeOpener, clock: any AppClock, log: AppLog, pended: PendedPartkeys, warn: @escaping @Sendable (any Error) -> Void)
    /// ctx.deps.layout / store / ingest / locks / volumeOpener / clock / log、ctx.config、ctx.zone、ctx.pendedPartkeys、warn = { ctx.warnStore($0) }
    init(ctx: TickContext)

    var reaper: ReaperRunner { locks.reaper }
    /// その時点の最新の snapshot。無いか新鮮でなければ nil（DEL-20。tick の先頭の snapshot ではない。Part の処理は数時間かかる）
    func freshSnapshot() async -> DeviceSnapshot?
    /// 削除条件の評価の環境（LockEvaluator.observe。useCache は既定で真）
    func context(snapshot: DeviceSnapshot?, useCache: Bool = true) async -> DeletionContext
    /// warn に渡さず TransitionConflict を「状態が変わった」として記録する（WARNING）
    func logStatusChanged(recordingKey: String)
    func logStatusChanged(sessionKey: String)
}
```

- `freshSnapshot()`: `guard let s = await ingest.latestSnapshot(), s.isFresh(now: clock.now(), maxAgeSeconds: config.device.snapshotMaxAgeSeconds) else { return nil }; return s`
- `context(snapshot:useCache:)`: `DeletionContext(config: config, locks: await locks.observe(config: config, snapshot: snapshot, useCache: useCache), layout: layout, volumeOpener: volumeOpener)`
- `logStatusChanged(recordingKey:)`: `log.warning(.sourceDeleteSkipped, [(.recordingKey, .string(k)), (.reason, .string(DeletionReason.statusChanged))])`。`sessionKey:` は `(.sessionKey, …)`

### 4.3 `DeleteQueue.swift`

```swift
// queue/delete と queue/result のファイルの読み書き（PLAN §4.4・§8.9.6・§8.9.7）。要求を書くのは RequestWriter 経由だけ（PR-09）。
import Darwin
import Foundation
import VDContract
import VDCore

enum DeleteQueueError: Error, Equatable {
    case encode(ContractEncodeError)
    case write(AtomicFileError)
}

struct QueuedResult: Sendable {
    let url: URL
    /// ContractJSON で読めなければ nil（残す）
    let result: DeleteResult?
}

enum DeleteQueue {
    /// `.` で始まらない `*.json` の名前を UTF-8 のバイト順に。ディレクトリが読めなければ []
    static func names(in directory: URL) -> [String]
    static func requestURL(_ requestID: String, layout: HomeLayout) -> URL     // queue/delete/<id>.json
    static func resultURL(_ requestID: String, layout: HomeLayout) -> URL      // queue/result/<id>.json
    static func write(_ request: DeleteRequest, layout: HomeLayout) throws(DeleteQueueError)
    static func hasPendingRequests(layout: HomeLayout) -> Bool                 // names(in: queueDelete) が空でない
    static func results(layout: HomeLayout) -> [QueuedResult]                   // names(in: queueResult) の順
    /// partkey がこの Part の要求を全部取り下げる。読めない要求は残す。消した数
    static func withdrawRequests(partkey: String, layout: HomeLayout) -> Int
    /// 同じく結果
    static func withdrawResults(partkey: String, layout: HomeLayout) -> Int
    /// 結果を捨てる（SafeUnlink.remove(url, under: .queueResult)）
    static func discard(_ url: URL, layout: HomeLayout)
    /// lstat が通常ファイルで st_size <= Contract.maxRequestBytes のときだけ読む。それ以外・失敗は nil
    static func readSmallFile(_ url: URL) -> Data?
}
```

- `names(in:)`: `try? FileManager.default.contentsOfDirectory(atPath: p(directory))`（nil → `[]`）→ `!$0.hasPrefix(".") && $0.hasSuffix(".json")` → `sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }`
- `requestURL`: `layout.queueDelete.appendingPathComponent(requestID + ".json", isDirectory: false)`（`resultURL` は `queueResult`）
- `write`: `data = try ContractJSON.encode(request)`（`catch` → `.encode(e)`）→ `try AtomicFile.write(data, to: requestURL(request.requestID, layout:), permissions: 0o644)`（`catch` → `.write(e)`）
- `results`: 各名前の `url` について `result = readSmallFile(url).flatMap { try? ContractJSON.decodeResult($0).get() }`
- `withdrawRequests`: 各名前の `url` の `readSmallFile` → `ContractJSON.decodeRequest` が `.success(r)` で `DeletionPolicy.sameKey(r.partkey, partkey)` なら `try? SafeUnlink.remove(url, under: .queueDelete, layout:)`、例外が無ければ数える。`withdrawResults` は `decodeResult` と `.queueResult`
- 取り下げ・捨てるの失敗（`try?`）は記録しない: 残った要求を reaper が処理しても、結果の request_id が DB と合わないので回収で捨てられる（DEL-08）。残った結果は次の回収で同じ判定になる（冪等）

### 4.4 `RequestWriter.swift`

```swift
// 削除要求の ①ID → ②要求ファイル（PLAN §4.4 の書く順）。③の遷移は呼び手（根拠 A と後追いは SOURCE_DELETING へ、根拠 B は遷移しない）。
import VDContract
import VDCore
import VDStore

struct RequestWriter {
    let deps: DeletionDependencies
    /// 書けたら request_id。書けなければ nil（理由はログに出してある）。Store の予期しない例外は投げる
    func write(part: RecordingRow, sessionKey: String) throws -> String?
}
```

手順:
1. `guard let relpath = part.sourcePath, let size = part.sourceSize, let mtime = part.sourceMtime else { return nil }`（削除条件が真なら揃っている。防御）
2. `now = deps.clock.now()`、`seconds = now.epochMillis >= 0 ? now.epochMillis / 1000 : -((-now.epochMillis + 999) / 1000)`、
   `id = RequestID.make(partkey: part.partkey, utcEpochSeconds: seconds, randomHex6: RequestID.randomHex6())`
3. **① ID を先に**: `guard try deps.store.updateRecordingIfStatus(part.partkey, status: part.status, [.deleteRequestID(id)]) else { deps.logStatusChanged(recordingKey: part.partkey); return nil }`
4. `request = DeleteRequest(requestID: id, createdAt: deps.zone.iso(now), deviceID: part.deviceID, partkey: part.partkey, sessionKey: sessionKey, target: DeleteTarget(relpath: relpath, size: size, mtime: mtime))`
   （size / mtime は **DB の値 = デバイス上の原本**。DEL-12。絶対パスを持たない。PR-17）
5. **② 要求ファイル**: `do { try DeleteQueue.write(request, layout: deps.layout) } catch {` `try deps.store.updateRecording(part.partkey, [.deleteRequestID(nil)])`、
   `deps.log.warning(.sourceDeletePending, [(.recordingKey, .string(part.partkey)), (.reason, .string(DeletionReason.queueWriteFailed)), (.errorCode, .string(ErrorCode.deleteQueueFailed.rawValue))])`、`return nil }`
6. `return id`

- ②の後・③の前に落ちても、Part は ID を持ち「結果待ち」として回収か期限切れで決着する（PLAN §8.9.5）

### 4.5 `DeletionRequester.swift`（PLAN §8.9.5 `requestDeletions`。voicedock pipeline.py:670-748 ＋ 本計画の差分）

```swift
// Part の削除要求（根拠 A）。Raw を保存した直後（§5.5）と Session の削除段から呼ばれる。
struct DeletionRequester {
    let deps: DeletionDependencies
    /// 書いた要求の数
    func requestDeletions(sessionKey: String) async -> Int
}
```

手順（逐語。`requested = 0`）:
1. `guard let snapshot = await deps.freshSnapshot() else { return 0 }`（**その時点の最新**。nil か新鮮でなければ 0。DEL-20）
2. `ctx = await deps.context(snapshot: snapshot)`。`ctx.locks.readiness != .configured` なら `return 0`（Part を読まない）
3. `session = try deps.store.session(sessionKey)`、nil なら `return 0`。`parts = try deps.store.recordings(inSession: sessionKey)`（started_at, partkey 順）。例外 → `deps.warn(e)`、`return 0`
4. `for part in parts`（1 件ごとに `do { … } catch { deps.warn(error) }` で囲み、例外でも次へ）:
   1. `PartStates.deletable.contains(part.status)` でなければ飛ばす
   2. `part.status == .sourceDeleting || part.status == .completed` なら飛ばす（通常経路は COMPLETED を消しにいかない。二重に要求しない）
   3. `part.deleteRequestID != nil` なら飛ばす（結果待ち）
   4. `deps.pended.contains(part.partkey)` なら飛ばす（同じ周回で再要求しない。DEL-11）
   5. `DeletionPolicy.canDeleteSource(DeletionCandidate(part: part, session: session, parts: parts, twin: nil), ctx)` が偽なら飛ばす
   6. `guard let id = try RequestWriter(deps: deps).write(part: part, sessionKey: session.sessionKey) else { continue }`（①②）
   7. ③ `do { try deps.store.recordPartTransition(partkey: part.partkey, from: part.status, to: .sourceDeleting) } catch is TransitionConflict { deps.logStatusChanged(recordingKey: part.partkey); continue }`（RAW_SAVED か SOURCE_DELETE_PENDING から）
   8. `deps.log.info(.deleteRequested, [(.requestID, .string(id)), (.recordingKey, .string(part.partkey)), (.sessionKey, .string(session.sessionKey))])`
   9. `requested += 1`
5. `return requested`

- **Session の状態で門前払いしない**（OPEN・READY でも評価する。AY-1）
- 結果の回収はここでしない（voicedock は先頭で回収していた。本アプリは tick の段で全件を回収する。§8.9.6）

### 4.6 `SessionDeletionStage.swift`（PLAN §8.9.5 `deleteSourcesIfSafe`。voicedock pipeline.py:750-812・1075-1092 ＋ v1.1 の修正）

```swift
// Session の削除段と後始末。呼ばれる契機は SAVED になった直後（backoff を見ずに 1 回）と evaluateDeletions（backoff に従う。DEL-14）。
struct SessionDeletionStage {
    let deps: DeletionDependencies
    func deleteSourcesIfSafe(sessionKey: String) async
    func completeWithoutDeleting(_ row: SessionRow, _ parts: [RecordingRow]) throws
    func finishCleanup(_ row: SessionRow) throws
    /// evaluateDeletions の対象（deleteEvaluated に在り、backoff を過ぎた Session。updated_at, session_key 順）
    func dueSessionKeys() -> [String]
    /// now − updated_at >= delay(delete_attempts)。updated_at が読めなければ真（voicedock db.py:640-645 の datetime.min と同じ）
    static func isDue(updatedAt: String, attempts: Int, now: Instant, backoff: [Int], zone: ZonedTime) -> Bool
}
```

**`deleteSourcesIfSafe(sessionKey:)`**（全体を `do { … } catch { deps.warn(error) }` で囲む。逐語）:
```text
row = store.session(key); nil か row.status ∉ SessionStates.deleteEvaluated → 何もしない
row.status == .cleanup → finishCleanup(row); 終わり
requested = await DeletionRequester(deps).requestDeletions(sessionKey: key)
row = store.session(key)（読み直し。nil か deleteEvaluated に無ければ終わり）; parts = store.recordings(inSession: key)
readiness = await deps.locks.readiness(config: deps.config)
if case .disabled(let reason) = readiness:
    log.info(.sourceDeleteSkipped, [(.sessionKey, key), (.reason, reason)]); completeWithoutDeleting(row, parts); 終わり
w = DeviceWritability.observe(deviceID: row.deviceID, snapshot: await deps.ingest.latestSnapshot())
if w == .readOnly || w == .unknown:
    log.info(.sourceDeleteSkipped, [(.sessionKey, key), (.reason, DeletionReason.deviceReadonly)]); completeWithoutDeleting(row, parts); 終わり
if !parts.contains(where: { PartStates.awaitingDeletion.contains($0.status) }): completeWithoutDeleting(row, parts); 終わり      // ログなし
if requested == 0 && !parts.contains(where: { $0.status == .sourceDeleting }):
    store.updateSession(key, [.deleteAttempts(row.deleteAttempts + 1)]); 終わり          // 遷移しない（未接続など。updated_at が進み backoff が効く）
if row.status == .saved || row.status == .sourceDeletePending:
    recordSessionTransition(key, from: row.status, to: .sourceDeleting)（TransitionConflict → deps.logStatusChanged(sessionKey: key)）
```
- 未接続（`.absent`）は完了させずに待つ（voicedock は未接続を「書き込み可能」扱いにしていた。PLAN §8.9.2）。有効化の直後で挿し直す前（`.readOnly`）は完了する（消し損ねた分は後追いで拾う）
- `readiness` は `requestDeletions` の中でも評価済み（キャッシュが効く）

**`completeWithoutDeleting(row, parts)`**（逐語）:
```text
if parts.contains(where: { $0.status == .rawSaved && $0.deleteRequestID != nil }):
    store.updateSession(key, [.deleteAttempts(row.deleteAttempts + 1)]); 終わり      // ②の後・③の前に落ちた Part の結果か期限切れを待つ
for p in parts where p.status == .rawSaved:
    recordPartTransition(p.partkey, from: .rawSaved, to: .completed)（TransitionConflict → logStatusChanged(recordingKey:)、次へ）
if SessionStates.cleanupFrom.contains(row.status):
    recordSessionTransition(key, from: row.status, to: .cleanup)（TransitionConflict → logStatusChanged(sessionKey:)、終わり）
fresh = store.session(key); fresh?.status == .cleanup なら finishCleanup(fresh)
```

**`finishCleanup(row)`**（逐語。`row.status != .cleanup` なら何もしない）:
```text
failed = false
for p in store.recordings(inSession: key) where PartStates.stagingDisposable.contains(p.status):     // FAILED の 16 kHz は残す（SM-23）
    slug = KeySlug.of(p.partkey)
    for url in [layout.normalizedAudio(slug:), layout.normalizedAudioTmp(slug:), layout.whisperJSON(slug:)]:
        do { try SafeUnlink.remove(url, under: .staging, layout: layout) } catch { failed = true }     // 無いものは missingOK
    do { try SafeUnlink.removeEmptyDirectory(layout.stagingDirectory(slug: slug), under: .staging, layout: layout) } catch { failed = true }
if failed:
    log.warning(.diskSpaceLow, [(.sessionKey, key), (.reason, DeletionReason.stagingUnlinkFailed)]); 終わり     // CLEANUP のまま。次の評価でやり直す
recordSessionTransition(key, from: .cleanup, to: .completed)（TransitionConflict → logStatusChanged(sessionKey:)）
```

**`dueSessionKeys()`**: `rows = try deps.store.sessionsForDeleteEvaluation()`（例外 → `deps.warn(e)`、`[]`）。`now = deps.clock.now()`。
`rows.filter { SessionStates.deleteEvaluated.contains($0.status) && Self.isDue(updatedAt: $0.updatedAt, attempts: $0.deleteAttempts, now: now, backoff: deps.config.cleanup.deleteEvaluationBackoffSeconds, zone: deps.zone) }.map(\.sessionKey)`（順は問い合わせのまま）。

**`isDue`**: `guard let updated = zone.parseISO(updatedAt) else { return true }`、`return now - updated >= Int64(RetryDelay.deleteEvaluation(attempts: attempts, backoff: backoff)) * 1000`
（`delay(a) = backoff[min(max(a, 1), backoff.count) − 1]`。a = 0 と 1 はどちらも先頭。T-08）。

### 4.7 `ResultCollector.swift`（PLAN §8.9.6。**同じ秒問題を構造的に消す**）

```swift
// reaper の起動と結果の回収。回収は結果ファイル全件が対象（snapshot で絞らない）。根拠 A と B で同じ規則を使い、分かれるのは状態の扱いだけ。
struct ResultCollector {
    let deps: DeletionDependencies
    /// 回収を待つ Part の状態（PLAN §8.9.6）= awaitingDeletion ∪ {SKIPPED}
    static let collectableStatuses: Set<PartStatus> = PartStates.awaitingDeletion.union([.skipped])
    func collectDeleteResults(reaperScanGeneration: UInt64) async
    /// 失敗・期限切れの後始末。状態を動かす／ID を外す。衝突したら status_changed を出して偽
    func pend(_ part: RecordingRow, code: ErrorCode, reason: String) throws -> Bool
    /// snapshot が新鮮な tick だけ呼ぶ（呼び手が確かめる）。戻り値は新しい reaperScanGeneration（起動しなければ引数のまま）
    func runReaperIfNeeded(reaperScanGeneration: UInt64) async -> UInt64
    func logRun(_ result: ProcessResult)
}
```

**`collectDeleteResults(reaperScanGeneration:)`**（毎 tick（新鮮でなくても）と reaper の後。逐語。結果 1 件ごとに `do { … } catch { deps.warn(error) }`）:
```text
snapshot = await deps.ingest.latestSnapshot()
for q in DeleteQueue.results(layout):                                   // . 始まりでない .json を名前順
    guard let result = q.result else continue                            // 読めない → 残す
    guard let part = store.recording(result.partkey) else continue        // 無い → 残す（別の用途かもしれない）
    if part.deleteRequestID == nil || !collectableStatuses.contains(part.status): discard(q.url); continue     // 待っていない → 捨てる
    if !sameKey(result.requestID, part.deleteRequestID): discard(q.url); continue      // 古い試行（DEL-08 / ND-42）
    switch result.status:
    case .sourceIdentityMismatch:
        if pend(part, code: .sourceIdentityMismatch, reason: result.detail) { discard(q.url) }
    case .deleted:
        guard let s = snapshot, s.generation >= reaperScanGeneration, let obs = s.devices[part.deviceID] else continue    // 残す（判定できる観測を待つ。ND-46）
        if part.sourcePath == nil || obs.relpaths.contains(where: { sameKey($0, part.sourcePath) }):
            if pend(part, code: .sourceDeleteFailed, reason: DeletionReason.stillInInventory) { discard(q.url) }
        else:
            store.updateRecording(pk, [.sourceDeletedAt(zone.iso(clock.now())), .deleteRequestID(nil)])
            advanceToCompleted(part)                                      // SKIPPED 以外
            log.info(.sourceDeleted, [(.recordingKey, pk), (.requestID, result.requestID)])
            discard(q.url)
```
- `advanceToCompleted(part)`: `.skipped` → 何もしない。`.sourceDeleting` → `→COMPLETED`。`.rawSaved`・`.sourceDeletePending` → `→SOURCE_DELETING` → `→COMPLETED`（付録 A.2 の 2 遷移）。`TransitionConflict` → `logStatusChanged(recordingKey:)`（source_deleted_at は既に書いた。結果は捨てる）
- `source_path` が nil なら「消えた」と判定しない（観測と照らせない。消さない側）
- **時刻を比べない**。reaper の終了を待ってから始まった走査の generation で判定する（voicedock #156 / #182）

**`pend(part, code:, reason:)`**（逐語）:
```text
if part.status == .sourceDeleting:
    do { recordPartTransition(pk, from: .sourceDeleting, to: .sourceDeletePending, errorCode: code, detail: reason) }
    catch is TransitionConflict { logStatusChanged(recordingKey: pk); return false }
    store.updateRecording(pk, [.deleteRequestID(nil)])
else:                                                                   // SKIPPED・RAW_SAVED・SOURCE_DELETE_PENDING は状態を動かさない（SM-20）
    guard store.updateRecordingIfStatus(pk, status: part.status, [.deleteRequestID(nil)]) else { logStatusChanged(recordingKey: pk); return false }
log.warning(.sourceDeletePending, [(.recordingKey, pk), (.reason, reason)])
deps.pended.insert(pk)
return true
```
- `errorMessage` は渡さない（voicedock と同じ。理由語は events.detail とログに残る）

**`runReaperIfNeeded(reaperScanGeneration:)`**（逐語）:
```text
guard DeleteQueue.hasPendingRequests(layout) else return reaperScanGeneration
guard let snapshot = await deps.ingest.latestSnapshot(),
      snapshot.devices.keys.contains(where: { DeviceWritability.observe(deviceID: $0, snapshot: snapshot) == .writable }) else return reaperScanGeneration
guard await deps.locks.readiness(config: deps.config, useCache: false) == .configured else return reaperScanGeneration   // 起動の直前はキャッシュを使わない
switch await deps.reaper.run():
case .notLaunched(let reason): log.warning(.reaperFailed, [(.reason, reason)]); return reaperScanGeneration
case .finished(let result): logRun(result)
next: UInt64
if let g = await deps.ingest.scanNow() { next = g }                     // 呼び出しの後に始まり完了した走査
else { next = ((await deps.ingest.latestSnapshot())?.generation ?? 0) + 1 }   // 見送り → 次に完了する走査を待つ（DELETED はそれまで残る）
await collectDeleteResults(reaperScanGeneration: next)
return next
```

**`logRun(result)`**（`reaper_run exit=<n>` は起動したら常に出す。PLAN 付録 A.4）:

| `result.termination` | `reaper_run`（INFO） | `reaper_failed`（WARNING） |
|---|---|---|
| `.exited(0)` | `exit=0` | 出さない |
| `.exited(4)` | `exit=4` | `reason=busy`（`DeletionReason.busy`。reaper が reaper.lock を取れなかった。PLAN §8.9.6「4 は busy」・付録 A.4） |
| `.exited(n)`（0・4 以外） | `exit=n` | `reason=exit_<n>`（`DeletionReason.exit(n)`） |
| `.signaled(s)` | `exit=<128 + s>` | `reason=exit_<128 + s>` |
| `.spawnFailed` | `exit=127` | `reason=exit_127` |
| `.timedOut` | `exit=null` | `reason=timeout` |

（signaled・spawnFailed・timedOut の写し方は PLAN 付録 A.4 に在る。4 と 127 は `ResultCollector` の `static let busyExitCode: Int32 = 4`・`spawnFailedExitCode: Int32 = 127`（internal）に置き、ほかに書かない。CR-06）

### 4.8 `RequestExpirer.swift`（PLAN §8.9.7。voicedock pipeline.py:1004-1038）

```swift
// 結果の来ない要求の期限切れ。対象は全 Part（Session で絞らない）。読み直しと衝突の捕捉の 2 層を、それぞれ独立したテストで固定する（DEL-18 / TEST-17）。
struct RequestExpirer {
    let deps: DeletionDependencies
    func expireDeleteRequests() async                 // = expire(candidates: store.recordingsAwaitingDeleteResult(), reread: { try deps.store.recording($0) })
    /// テスト用（@testable）: 候補の一覧と読み直しを差し替える
    func expire(candidates: [RecordingRow], reread: (String) throws -> RecordingRow?)
}
```

`expire`（逐語。候補ごとに `do { … } catch { deps.warn(error) }`）:
```text
now = clock.now(); timeoutMillis = Int64(config.cleanup.deleteResultTimeoutSeconds) * 1000
for stale in candidates:                                                 // started_at, partkey 順
    guard let part = try reread(stale.partkey), let id = part.deleteRequestID else continue     // 層 1: 読み直す（一覧の写しの updated_at を使わない）
    if let updated = zone.parseISO(part.updatedAt), now - updated < timeoutMillis: continue      // 読めない updated_at は期限切れ扱い（取り下げるだけで消さない）
    if RequestID.isValid(id), lstat(p(DeleteQueue.resultURL(id, layout))) が成功: continue       // その request_id の結果が在る（DELETED の観測待ち）。取り下げない
    DeleteQueue.withdrawRequests(partkey: pk, layout); DeleteQueue.withdrawResults(partkey: pk, layout)
    _ = try ResultCollector(deps).pend(part, code: .deleteTimeout, reason: DeletionReason.noResult)   // 層 2: 衝突は pend の中で捕まえる（status_changed）
```

### 4.9 `ReaperRunner.swift`（T-36 のファイルに足す）

```swift
public enum ReaperRunOutcome: Equatable, Sendable {
    case notLaunched(reason: String)     // DeletionReason.signature
    case finished(ProcessResult)
}

extension ReaperRunner {
    public static let runTimeout: Duration = .seconds(120)
    /// 起動の直前に署名を検証し（ND-41 の 2 層目）、<HOME>/bin/voicedock-reaper --home <HOME> を起動して終わりを待つ。パスを引数に取らない（§8.9.3 の 1）
    public func run() async -> ReaperRunOutcome
}
```
1. `guard signatureIsValid() else { return .notLaunched(reason: DeletionReason.signature) }`
2. `spec = ProcessSpec(executable: layout.reaperExecutable, arguments: ["--home", p(layout.root)], environment: ProcessEnvironment.standard)`
3. `return .finished(await runner.run(spec, timeout: Self.runTimeout))`
- 版は `runReaperIfNeeded` の直前の `readiness(useCache: false)` が確かめる（子プロセスを 2 回起動しない）

### 4.10 Worker・工程の口（本体を書く）

`Worker.swift` の状態に `var reaperScanGeneration: UInt64 = 0` を足す（§8.9.6「起動直後は 0」。reaper は実行中ずっと reaper.lock を持つので、アプリが落ちて reaper だけが残っていても起動後の最初の走査はその後になる）。

`Worker+DeletionStages.swift`:
```swift
// 削除の段（PLAN §5.4・§8.9.5〜§8.9.7）。settleSkippedDeletions は T-39。
extension Worker {
    func stageCollectDeleteResults(_ ctx: TickContext) async {
        await ResultCollector(deps: DeletionDependencies(ctx: ctx)).collectDeleteResults(reaperScanGeneration: reaperScanGeneration)
    }
    func stageExpireDeleteRequests(_ ctx: TickContext) async {
        await RequestExpirer(deps: DeletionDependencies(ctx: ctx)).expireDeleteRequests()
    }
    /// deleteEvaluated の Session を updated_at, session_key の順に、backoff を過ぎたものだけ（DEL-14）
    func stageEvaluateDeletions(_ ctx: TickContext) async {
        let stage = SessionDeletionStage(deps: DeletionDependencies(ctx: ctx))
        for key in stage.dueSessionKeys() {
            if ctx.stop.isSet { return }
            await stage.deleteSourcesIfSafe(sessionKey: key)
        }
    }
    func stageRunReaperIfNeeded(_ ctx: TickContext) async {
        let current = reaperScanGeneration
        reaperScanGeneration = await ResultCollector(deps: DeletionDependencies(ctx: ctx)).runReaperIfNeeded(reaperScanGeneration: current)
    }
    func stageSettleSkippedDeletions(_ ctx: TickContext) async {}   // T-39 が中身を書く（PLAN §8.9.5 根拠 B）。
}
```

`PartSteps+Deletion.swift`（T-29 の口の本体。Raw の直後。**その Part だけでなく Session の全 Part**）:
```swift
extension PartSteps {
    func requestDeletionsAfterRawNote(sessionKey: String) async -> Int {
        await DeletionRequester(deps: DeletionDependencies(ctx: ctx)).requestDeletions(sessionKey: sessionKey)
    }
}
```

`SessionSteps+Deletion.swift`（T-22 の口の本体。SAVED の直後に backoff を見ずに 1 回）:
```swift
extension SessionSteps {
    func deleteSourcesIfSafe(_ key: String) async {
        await SessionDeletionStage(deps: DeletionDependencies(ctx: ctx)).deleteSourcesIfSafe(sessionKey: key)
    }
}
```

tick の中の順（T-18 の枠のまま）: … processPendingParts（Raw の直後の要求）→ processReadySessions（SAVED の直後の削除段）→ **collectDeleteResults → expireDeleteRequests** →
snapshot が新鮮なら **evaluateDeletions** → settleSkippedDeletions（T-39）→ **runReaperIfNeeded**（→ scanNow → collectDeleteResults）→ …。`pendedPartkeys` は tick ごとに新しい。

### 4.11 TestSupport

#### `ScriptedIngest.swift`

```swift
// IngestPort の偽物（削除の流れのテスト用）。scanNow の台本を持つ（FakeIngest は scanNow で generation を進められないため）。作り手 T-38。
import VDDevice
import VDPipeline

public actor ScriptedIngest: IngestPort {
    public enum Scan: Sendable { case publish(DeviceSnapshot), skip }
    public init(snapshot: DeviceSnapshot?)
    public func setSnapshot(_ s: DeviceSnapshot?)
    /// scanNow の台本（先頭から使う）
    public func script(_ scans: [Scan])
    /// 台本が尽きたときに使う走査（次の generation を渡す。nil を返すと見送り）
    public func setScanner(_ f: @escaping @Sendable (UInt64) -> DeviceSnapshot?)
    public var scanNowCalls: Int { get }
    public func latestSnapshot() -> DeviceSnapshot?
    public func state() -> IngestState          // .idle
    public func updates() -> AsyncStream<Void>  // 何も流さない
    public func scanNow() async -> UInt64?
}
```
`scanNow`: `scanNowCalls += 1`。台本が在れば先頭を取り出し、`.publish(s)` → `snapshot = s`、`s.generation` を返す。`.skip` → nil。
台本が無く scanner が在れば `s = scanner((snapshot?.generation ?? 0) + 1)`。nil → nil、在れば `snapshot = s`、`s.generation`。どちらも無ければ nil。

#### `DeletionScene+Reaper.swift`

```swift
extension DeletionScene {
    /// ビルドした本物の reaper（T-37 の ReaperBinary.url()）を bin/voicedock-reaper に複製し 0o755 にする（スタブは消す）
    public func installRealReaper() throws
}
```

#### `DeletionScene+Steps.swift`（NoDeleteTests と VDPipelineTests に同じ内容で置く）

```swift
// DeletionScene から削除の段の依存を作る（T-38）。DeletionDependencies は internal なので test ターゲットごとに置く。
import TestSupport
import VDContract
import VDCore
@testable import VDPipeline

extension DeletionScene {
    /// 今の設定で 1 tick 分の依存を作る（設定を変えたら作り直す）。warn は config_warning rule=store を出す
    func deletionDependencies(ingest: any IngestPort, pended: PendedPartkeys = PendedPartkeys(),
                              locks: LockEvaluator? = nil, opener: (any VolumeOpener)? = nil) -> DeletionDependencies {
        let log = self.log
        return DeletionDependencies(
            layout: layout, store: store, config: config, zone: zone, ingest: ingest, locks: locks ?? self.locks,
            volumeOpener: opener ?? self.opener, clock: clock, log: log, pended: pended,
            warn: { error in log.warning(.configWarning, [(.rule, "store"), (.message, .string(String(describing: error)))]) })
    }
}
```

## 5. ログ（このチケットが出すもの）

| イベント | レベル | フィールド（この順） | 出す場所 |
|---|---|---|---|
| `delete_requested` | INFO | `request_id`, `recording_key`, `session_key` | requestDeletions |
| `source_deleted` | INFO | `recording_key`, `request_id` | collectDeleteResults |
| `source_delete_skipped` | INFO | `session_key`, `reason`（readiness の 5 語・`device_readonly`） | deleteSourcesIfSafe |
| `source_delete_skipped` | WARNING | `recording_key` か `session_key`, `reason=status_changed` | 衝突 |
| `source_delete_pending` | WARNING | `recording_key`, `reason`（RV の理由語・`still_in_inventory`・`no_result`） | pend |
| `source_delete_pending` | WARNING | `recording_key`, `reason=queue_write_failed`, `error_code=DELETE_QUEUE_FAILED` | RequestWriter |
| `disk_space_low` | WARNING | `session_key`, `reason=staging_unlink_failed` | finishCleanup |
| `reaper_run` | INFO | `exit` | runReaperIfNeeded |
| `reaper_failed` | WARNING | `reason`（`exit_<n>`・`busy`・`timeout`・`signature`） | runReaperIfNeeded（`version_mismatch` と検証の `signature` は T-36 の LockEvaluator） |

## 6. テスト

共通: `import Testing`、`import TestSupport`、`@testable import VDPipeline`、`import VDContract`、`import VDCore`、`import VDStore`、`import VDDevice`。
既定の準備: `scene = try DeletionScene()`、`ingest = ScriptedIngest(snapshot: scene.snapshot())`、`deps = scene.deletionDependencies(ingest: ingest)`。
「要求を 1 件書いた状態」= `await DeletionRequester(deps: deps).requestDeletions(sessionKey: DeletionScene.sessionKey) == 1` の後（Part は SOURCE_DELETING、`id` = DB の `deleteRequestID`）。
「DELETED の結果」= `scene.writeResult(partkey: DeletionScene.partkey, requestID: id, status: .deleted, detail: DeletionScene.relpath)`。
「消えた後の走査」= `scene.snapshot(generation: 2, relpaths: [])`（デバイスは在り、ファイルが無い）。

### 6.1 `Tests/NoDeleteTests/DeletionFlowNDTests.swift`（`@Suite("削除の流れの ND（層 A）")`）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `deletionActuallyHappensWhenEverythingIsValid` | 正の対照 [A] 三重ロックを外し本文が揃えば要求ファイルが書かれ RAW_SAVED→SOURCE_DELETING が記録される | 既定で requestDeletions | 戻り値 1。`requests().count == 1`、その JSON を `ContractJSON.decodeRequest` で読むと `schema == 1`・`partkey == DeletionScene.partkey`・`deviceID == "DJIMIC3"`・`sessionKey == DeletionScene.sessionKey`・`target == DeleteTarget(relpath: DeletionScene.relpath, size: 4096, mtime: DB の sourceMtime)`、`requestID` が `RequestID.isValid` で DB の `deleteRequestID` と等しく、ファイル名 = `requestID + ".json"`。Part は SOURCE_DELETING、最後の events が `RAW_SAVED→SOURCE_DELETING`。ログに `delete_requested request_id=<id> recording_key=<pk> session_key=DJIMIC3:20260912` |
| `everyLayerAFaultWritesNoRequest` | 層 A の全故障で要求ファイルが書かれない（パラメータ化: 下の `LayerAFault.allCases`） | 故障ごとに新しい舞台で注入し requestDeletions | 0、`requests() == []`、Part の状態が変わらない、`deleteRequestID == nil` |
| `nd41ReaperNotLaunchedWhenInvalid` | ND-41 [A] 署名が不正・版が違えば reaper を起動しない（パラメータ化） | 要求を `DeleteQueue.write` で 1 件置く（有効な DeleteRequest）。(a) 新しい舞台で `verifier.setValid(false)` (b) `DeletionScene(reaperVersionOutput: "0.0.1\n")`。`runReaperIfNeeded(reaperScanGeneration: 0)` | `scene.runner.recorded` に `--home` の起動が無い、戻り値 0、`ingest.scanNowCalls == 0`、ログに (a) `reaper_failed reason=signature` (b) `reaper_failed reason=version_mismatch` |
| `nd42OlderAttemptResultIsDiscarded` | ND-42 [A] 古い試行の DELETED 結果（request_id 不一致）は捨て、消えたと判定しない | 要求を 1 件書いた状態、`writeResult(…, requestID: "20260101T000000Z-0000000000000000-000000", status: .deleted, …)`、消えた後の走査、collect(2) | 結果ファイルが無い、Part は SOURCE_DELETING のまま、`sourceDeletedAt == nil`、`deleteRequestID == id` |
| `nd46DeletedWaitsForAScanAfterTheReaper` | ND-46 [A] reaper の後の走査が無い・デバイスが snapshot に無ければ DELETED でも完了にしない（パラメータ化） | 要求を 1 件、DELETED の結果。(a) `snapshot(generation: 1, relpaths: [])` で collect(2) (b) `snapshot(generation: 2, includeDevice: false)` で collect(2) (c) `setSnapshot(nil)` で collect(2) | 結果が残る、SOURCE_DELETING のまま、`sourceDeletedAt == nil`。対照: その後 `snapshot(generation: 2, relpaths: [])` で collect(2) → COMPLETED |
| `nd47UnknownReadOnlyWritesNoRequest` | ND-47 [A] 接続中で readOnly が nil（観測できない）なら要求を書かない | `ScriptedIngest(snapshot: scene.snapshot(readOnly: nil))` で `SessionDeletionStage.deleteSourcesIfSafe` | `requests() == []`、Part COMPLETED、Session COMPLETED、ログに `source_delete_skipped session_key=DJIMIC3:20260912 reason=device_readonly` |

`LayerAFault`（このファイルの中の `enum LayerAFault: String, CaseIterable, Sendable`。`func scene() throws -> DeletionScene` と `func inject(_ s: DeletionScene) throws` を持つ。T-36 §6.1 と同じ注入）:
`normalizing`（ND-01）、`normalizeVerifyFailed`（ND-02）、`whisperFailed`（ND-04）、`whisperTimeout`（ND-05）、`noSpeechLockB`（ND-06。SKIPPED は deletable に無いので requester は飛ばす）、
`rawOutputPathNil`（ND-07）、`rawNoteRemoved`・`rawNoteTampered`（ND-08）、`keyMissing`（ND-09）、`sourcePathNil`・`sourcePathEmpty`（ND-21）、`appLockOff`・`confLockOff`（ND-22）、
`readOnlyObserved`・`readOnlyHandle`（ND-23。readOnlyHandle は deps の `opener: FakeVolumeOpener(readOnly: true)`）、`reaperMissing`（ND-26）、`otherDeviceKey`（ND-31）、
`transcriptPathNil`・`transcriptMissing`・`transcriptBroken`（ND-32）、`emptyVault`（ND-36）、`signatureInvalid`・`versionMismatch`（ND-41）、`confMissing`・`confInvalid`（ND-45）、
`emptySession`（ND-21。`addSession(key: "DJIMIC3:20260913", dayDate: "2026-09-13")` を評価する）、`staleSnapshot`（DEL-20。`snapshot` の completedAt を now − 901 秒）。
readOnlyObserved・staleSnapshot は ingest の snapshot を差し替える。パラメータ化の元が空で緑にならないよう、`@Test("層 A の故障の一覧が空でない") func layerAFaultsAreNotEmpty() { #expect(!LayerAFault.allCases.isEmpty) }` を置く（件数は直書きしない。TEST-01）。

### 6.2 `Tests/VDPipelineTests/DeleteQueueTests.swift`（`@Suite("DeleteQueue")`）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `namesIgnoreHiddenAndOtherFiles` | . 始まりと .json 以外を無視し、バイト順に並べる | queue/delete に `.x.json`・`a.txt`・`b.json`・`A.json` | `["A.json", "b.json"]` |
| `emptyDirectoryHasNoNames` | 空（TEST-28） | 何も無い | `[]`、`hasPendingRequests == false` |
| `writeUsesContractJSON` | 要求は ContractJSON の符号化で書く（tmp を残さない） | `write(DeleteRequest(…))` | ファイルの中身 == `ContractJSON.encode` の値、`.20…json.tmp` が無い |
| `withdrawOnlyThatPartkey` | 取り下げは同じ partkey の要求だけ | pk の要求 2 件・別の partkey 1 件・`"{"` の壊れた要求 1 件 | 戻り値 2、残りの 2 件が在る |
| `withdrawResultsToo` | 結果も partkey で取り下げる | pk の結果 1 件・別 1 件 | 1、別が残る |
| `readSmallFileRejectsLargeAndSymlink` | 64 KiB を超えるものと symlink は読まない（パラメータ化） | 65_537 バイト / 通常ファイルへの symlink | nil |
| `undecodableResultIsNil` | 読めない結果は result が nil | `"{"` | `results()` の 1 件の `result == nil` |

### 6.3 `Tests/VDPipelineTests/DeletionRequesterTests.swift`（`@Suite("DeletionRequester")`）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `requestCarriesOriginalValues` | DEL-12 要求の size / mtime は DB の値（原本）、時刻は UTC の Z 付き | 既定 | `target.size == 4096`、`target.mtime == sourceMtime`、`createdAt == "2026-09-12T12:00:00+09:00"`、`requestID` が `"20260912T030000Z-8483e42457304a9d-"` で始まる |
| `requestHasNoAbsolutePath` | PR-17 要求に絶対パス・`..`・`.` 始まりの要素が無い | 既定 | JSON の文字列に `p(scene.volumesRoot)` と `"/Volumes"` を含まない、`relpath` の各要素が空・`.`・`..`・`.` 始まりでない |
| `queueWriteFailureRollsBackTheID` | ②が失敗したら ID を外し DELETE_QUEUE_FAILED を出して遷移しない | queue/delete を `chmod 0o555`（後で 0o755 に戻す） | 0、`deleteRequestID == nil`、RAW_SAVED、ログに `source_delete_pending recording_key=<pk> reason=queue_write_failed error_code=DELETE_QUEUE_FAILED`（WARNING） |
| `writerRefusesAStaleRow` | ① は状態が変わっていれば書かない（status_changed） | `stale = store.recording(pk)`、`movePart(pk, to: .completed)`、`RequestWriter(deps:).write(part: stale, sessionKey:)` | nil、`deleteRequestID == nil`、`requests() == []`、`source_delete_skipped recording_key=<pk> reason=status_changed` |
| `staleSnapshotWritesNothing` | DEL-20 snapshot が古い・無ければ 0（パラメータ化） | completedAt = now − 901 秒 / nil | 0、`scene.verifier.verifiedURLs == []`（ロックも評価しない） |
| `freshnessBoundaryIsInclusive` | ちょうど 900 秒は新鮮 | completedAt = now − 900 秒 | 1 |
| `ceSnapshotMaxAgeSeconds` | CE device.snapshotMaxAgeSeconds が新鮮さの境になる | `snapshotMaxAgeSeconds = 61`（`scanIntervalSeconds` は既定の 300 では CV-46 を満たさないので 60 にする）、completedAt = now − 100 秒 | 0（既定の 900 では 1）。`completedAt = now − 61` なら 1 |
| `disabledReadinessWritesNothing` | CE cleanup.deleteSourceAudio false なら要求を 1 件も書かない | `updateConfig { $0.cleanup.deleteSourceAudio = false }` の後に deps を作る（既定の舞台は true で 1 件書く） | 0 |
| `skipsSourceDeletingAndCompleted` | SOURCE_DELETING と COMPLETED は飛ばす（パラメータ化） | `movePart(pk, to: .sourceDeleting)` / `.completed` | 0、`requests() == []` |
| `skipsPartsAwaitingAResult` | delete_request_id が在れば飛ばす | `updateRecording(pk, [.deleteRequestID("20260912T030000Z-8483e42457304a9d-abcdef")])` | 0 |
| `skipsPartsPendedThisTick` | DEL-11 この tick で PENDING に落とした Part は再要求しない | `movePart(pk, to: .sourceDeletePending)`、`pended.insert(pk)` | 0。対照: 新しい `PendedPartkeys()` の deps では 1、SOURCE_DELETING |
| `pendingPartIsRetried` | SOURCE_DELETE_PENDING から再要求できる（#154） | `movePart(pk, to: .sourceDeletePending)` | 1、events の最後が `SOURCE_DELETE_PENDING→SOURCE_DELETING` |
| `oneSkippedPartDoesNotStopTheRest` | 先の Part を飛ばしても残りを評価する | 08:00 の兄弟を SOURCE_DELETING で足し（`inRawNote: true`、`writeRawNote()`）、既定の Part（09:00）は RAW_SAVED | 1、既定の Part が SOURCE_DELETING |
| `everyEligiblePartIsRequested` | Session の全 Part を評価する（その Part だけでない） | 10:00 の兄弟を RAW_SAVED で足し `writeRawNote()` | 2、要求 2 件 |
| `doesNotGateOnSessionStatus` | Session が OPEN でも要求を書く（AY-1） | `DeletionScene(sessionStatus: .open)` | 1 |
| `emptySessionWritesNothing` | TEST-28 Part 0 件の Session は 0 | `addSession(key: "DJIMIC3:20260913", dayDate: "2026-09-13")` を評価 | 0 |
| `missingSessionWritesNothing` | Session が無ければ 0 | `"DJIMIC3:20990101"` | 0、ログに config_warning が無い |

### 6.4 `Tests/VDPipelineTests/SessionDeletionStageTests.swift`（`@Suite("SessionDeletionStage")`）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `requestMovesTheSessionToSourceDeleting` | 要求を書いたら Session は SOURCE_DELETING | 既定で deleteSourcesIfSafe | Session SOURCE_DELETING、Part SOURCE_DELETING、要求 1 件 |
| `secondEvaluationDoesNotRequestAgain` | SOURCE_DELETING の Part が在れば requested 0 でも待たずにそのまま | 上の後にもう一度 | 要求 1 件のまま、`deleteAttempts == 0`、Session SOURCE_DELETING |
| `nothingToDeleteCompletes` | 待つ Part が無ければ完了する（#160。パラメータ化: COMPLETED・SKIPPED(NO_SPEECH)・FAILED(WHISPER_FAILED)） | `DeletionScene(status:errorCode:)` | Session COMPLETED、`requests() == []`、`source_delete_skipped` のログが無い |
| `waitingPartKeepsTheSessionOpen` | RAW_SAVED で条件が偽なら完了させない（待てば真になりうる） | `replaceInRawNote(pk, with: "DJIMIC3/other/other.wav", updateSHA: true)` | Session SAVED、`deleteAttempts == 1`、Part RAW_SAVED |
| `disabledReadinessCompletesWithReason` | readiness が disabled なら理由を出して完了（パラメータ化: 5 語） | (a) `deleteSourceAudio = false` (b) `writeReaperConf(deleteSourceAudio: false)` (c) `mountMode = "ro"` (d) `removeReaper()` (e) 新しい舞台で `verifier.setValid(false)` | ログに `source_delete_skipped session_key=DJIMIC3:20260912 reason=<delete_source_audio_disabled / lock_mismatch / mount_mode_ro / reaper_not_installed / reaper_invalid>`、Part COMPLETED、Session COMPLETED |
| `readOnlyOrUnknownCompletes` | 接続中で読み取り専用・不明なら device_readonly で完了（パラメータ化: true・nil） | `snapshot(readOnly:)` | `reason=device_readonly`、COMPLETED、要求無し |
| `absentDeviceWaits` | 未接続なら待つ（delete_attempts += 1、遷移しない） | `snapshot(includeDevice: false)` | Session SAVED、`deleteAttempts == 1`、Part RAW_SAVED、`source_delete_skipped` が無い |
| `rawSavedWithRequestIDDoesNotComplete` | RAW_SAVED で ID を持つ Part が在れば完了させない | `deleteSourceAudio = false`、`updateRecording(pk, [.deleteRequestID("20260912T030000Z-8483e42457304a9d-abcdef")])` | Session SAVED、`deleteAttempts == 1`、Part RAW_SAVED |
| `cleanupFreesStagingButKeepsFailed` | 完了のとき staging を消し、FAILED の 16 kHz は残す（SM-23） | readOnly true。既定の Part と、10:00 の FAILED(WHISPER_FAILED) の兄弟の両方に `staging/<slug>/audio16k.wav`・`audio16k.wav.tmp`・`whisper.json` を置く | 既定の Part の `staging/<slug>` が無い、兄弟の `audio16k.wav` が在る、Session COMPLETED |
| `stagingUnlinkFailureStaysInCleanup` | staging を消せなければ CLEANUP のまま、次でやり直す | readOnly true、既定の Part の `audio16k.wav` の位置にディレクトリを作る | Session CLEANUP、`disk_space_low session_key=DJIMIC3:20260912 reason=staging_unlink_failed`（WARNING）。ディレクトリを消してもう一度 → COMPLETED |
| `cleanupSessionOnlyFinishes` | CLEANUP の Session は後始末だけ（ロックを見ない） | `moveSession(to: .cleanup)` | COMPLETED、要求無し、`runner.recorded == []` |
| `notEvaluatedStatesAreIgnored` | deleteEvaluated に無い Session は何もしない（パラメータ化: READY・COMPLETED） | `DeletionScene(sessionStatus:)` | 状態も要求も変わらない |
| `pendingSessionRequestsAgain` | SOURCE_DELETE_PENDING の Session から再要求して SOURCE_DELETING へ | `movePart(pk, to: .sourceDeletePending)`、`moveSession(to: .sourceDeletePending)` | 要求 1 件、Session SOURCE_DELETING |
| `pendedPartIsNotRequestedInTheSameTick` | DEL-11 回収で PENDING に落とした Part を同じ周回で再要求しない（#156） | 要求を 1 件書いた状態 → 要求ファイルを消し（reaper の姿）、MISMATCH（`size_mismatch`）の結果 → 同じ deps で collect(0) → 同じ deps で deleteSourcesIfSafe | Part SOURCE_DELETE_PENDING、`requests() == []`。対照: 新しい PendedPartkeys の deps では要求 1 件 |
| `dueFollowsBackoff` | CE cleanup.deleteEvaluationBackoffSeconds 削除評価の backoff（voicedock の 4 事例と境界。パラメータ化） | `isDue(updatedAt: zone.iso(now − 秒), attempts:, now:, backoff: [60, 300, 900, 3600]（既定）, zone:)` の (1, 30)・(1, 120)・(4, 1800)・(4, 7200)・(0, 60)・(0, 59)・(1, 60)。加えて `backoff: [5]` で (1, 30) | 偽・真・偽・真・真・偽・真。`[5]` の (1, 30) は真（既定では偽） |
| `brokenUpdatedAtIsDue` | updated_at が読めなければすぐ評価 | `"not-a-time"` | 真 |
| `dueSessionKeysFiltersAndOrders` | 対象は deleteEvaluated だけ、updated_at, session_key の順 | `clock.set(now − 3600 秒)` で `addSession(key: "DJIMIC3:20260911", dayDate: "2026-09-11")`・`moveSession(to: .saved, sessionKey:)`、`clock.set(now − 7200 秒)` で `"DJIMIC3:20260910"` を SAVED と `"DJIMIC3:20260909"` を COMPLETED に、`clock.set(now)`。既定の Session は now に SAVED（attempts 0 → 60 秒待ち） | `["DJIMIC3:20260910", "DJIMIC3:20260911"]`（COMPLETED と既定の Session は入らない） |

### 6.5 `Tests/VDPipelineTests/ResultCollectorTests.swift`（`@Suite("ResultCollector")`）

準備: 要求を 1 件書いた状態、ingest を消えた後の走査にして `collectDeleteResults(reaperScanGeneration: 2)`。

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `deletedCompletesThePart` | DELETED で、reaper の後の走査に無ければ COMPLETED | DELETED の結果 | COMPLETED、`sourceDeletedAt == "2026-09-12T12:00:00+09:00"`、`deleteRequestID == nil`、結果ファイルが無い、`source_deleted recording_key=<pk> request_id=<id>` |
| `deletedFromRawSavedOrPendingTakesTwoSteps` | RAW_SAVED・SOURCE_DELETE_PENDING で待っていた Part は 2 遷移で完了（パラメータ化） | (a) 要求を書かずに `updateRecording(pk, [.deleteRequestID(id)])`（RAW_SAVED） (b) `movePart(pk, to: .sourceDeletePending)` の後に ID を書く | COMPLETED、最後の 2 本の events が `→SOURCE_DELETING`・`SOURCE_DELETING→COMPLETED` |
| `stillInInventoryGoesPending` | 走査にまだ在れば SOURCE_DELETE_FAILED で PENDING | DELETED、`snapshot(generation: 2)`（relpath 在り） | SOURCE_DELETE_PENDING、`errorCode == .sourceDeleteFailed`、ID nil、結果が無い、`source_delete_pending recording_key=<pk> reason=still_in_inventory`、`pended.contains(pk)` |
| `identityMismatchGoesPending` | 拒否は SOURCE_IDENTITY_MISMATCH で PENDING、理由語を残す | `status: .sourceIdentityMismatch, detail: "size_mismatch"` | PENDING、`errorCode == .sourceIdentityMismatch`、最後の events の detail `size_mismatch`、ログ `reason=size_mismatch` |
| `unknownPartkeyIsKept` | DB に無い Part の結果は残す | `writeResult(partkey: "DJIMIC3/other/other_orig.wav", …)` | 結果が在る |
| `undecodableResultIsKept` | 読めない結果は残す | queue/result/x.json に `"{"` | 在る |
| `hiddenResultIsIgnored` | . 始まりの結果は見ない | 正しい DELETED の結果を `.` 始まりの名前に rename | Part は SOURCE_DELETING のまま、ファイルは在る |
| `resultForAPartNotWaitingIsDiscarded` | 待っていない Part の結果は捨てる（#160。パラメータ化: ID nil・COMPLETED） | (a) `updateRecording(pk, [.deleteRequestID(nil)])` (b) 要求を書かずに `movePart(pk, to: .completed)` → `updateRecording(pk, [.deleteRequestID(id)])` | 結果が無い、Part の状態は変わらない、`sourceDeletedAt == nil` |
| `collectedAfterTheReaperRemovedTheRequest` | reaper が要求を消した後でも回収できる（BH-1） | 要求ファイルを消し、DELETED | COMPLETED |
| `collectionIsNotLimitedToEvaluatedSessions` | 回収は Session で絞らない（COMPLETED の Session の Part も） | `moveSession(to: .completed)`（Part は SOURCE_DELETING のまま）、DELETED | Part COMPLETED |
| `skippedPartStaysSkippedWhenDeleted` | 根拠 B の DELETED は SKIPPED のまま source_deleted_at を書く | `DeletionScene(status: .skipped, errorCode: .noSpeechDetected)`、`updateRecording(pk, [.deleteRequestID(id)])`、DELETED | SKIPPED、`errorCode == .noSpeechDetected`、`sourceDeletedAt` 在り、ID nil、events が増えない |
| `skippedPartRejectedKeepsItsReason` | 根拠 B の拒否は SKIPPED のまま ID だけ外す | 同上、MISMATCH `size_mismatch` | SKIPPED、`errorCode == .noSpeechDetected`、ID nil、`sourceDeletedAt == nil`、ログ `reason=size_mismatch` |
| `missingSourcePathIsNotGone` | source_path が無ければ消えたと判定しない | `StorePaths.setSourcePath(store, partkey: pk, nil)`、DELETED | SOURCE_DELETE_PENDING、`reason=still_in_inventory` |
| `emptyQueueDoesNothing` | 結果が無ければ何もしない（TEST-28） | 結果無し | 状態もログも変わらない |

### 6.6 `Tests/VDPipelineTests/RunReaperTests.swift`（`@Suite("runReaperIfNeeded")`）

準備: 要求を 1 件書いた状態。起動を記録するため `runner = ScriptedProcessRunner(results: [ScriptedProcessRunner.version(), <reaper の結果>])`、
`locks = LockEvaluator(layout: scene.layout, verifier: scene.verifier, runner: runner, log: scene.log)` を作り `scene.deletionDependencies(ingest:locks:)` で渡す（要求は `scene.locks` の deps で書く）。

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `launchesAndCollectsAfterTheScan` | 要求と書き込み可能なデバイスがあれば起動し、走査の後に回収する | reaper の結果 `.exited(0)`、`ingest.script([.publish(消えた後の走査)])`、DELETED の結果を先に置く、`runReaperIfNeeded(reaperScanGeneration: 0)` | 戻り値 2、`runner.recorded[1]` が `executable == layout.reaperExecutable`・`arguments == ["--home", p(layout.root)]`・`environment == ProcessEnvironment.standard`、`recordedTimeouts[1] == .seconds(120)`、`reaper_run exit=0`、`scanNowCalls == 1`、Part COMPLETED |
| `noRequestsNoLaunch` | 要求が無ければ起動しない | 要求ファイルを消す | `runner.recorded == []`、`scanNowCalls == 0`、戻り値は引数のまま |
| `noWritableDeviceNoLaunch` | 書き込み可能なデバイスが無ければ起動しない（パラメータ化: readOnly true・nil・0 台・snapshot nil） | | `runner.recorded == []` |
| `readinessIsVerifiedWithoutCache` | 起動の直前は署名と版を検証し直す | runner の台本を `[version(), version(), .exited(0)]` にする。先に `locks.readiness(config:)` を 1 回（キャッシュを作る）→ runReaperIfNeeded | 署名検証の回数が 2 増え（起動の直前の `readiness(useCache: false)` と `ReaperRunner.run` の 2 層）、記録が `--version`・`--version`・`--home` の順 |
| `disabledReadinessNoLaunch` | 準備が崩れていれば起動しない | `removeReaperConf()` | `--home` の起動が無い |
| `nonZeroExitIsLogged` | 0 以外は reaper_failed exit_<n>（4 は busy。パラメータ化: 4・2・3） | `.exited(n)` | `reaper_run exit=<n>`、`reaper_failed reason=exit_<n>`（4 は `reason=busy`）、scanNow は呼ぶ |
| `timeoutIsLogged` | タイムアウトは reason=timeout | `.timedOut` | `reaper_run exit=null`、`reaper_failed reason=timeout` |
| `signalAndSpawnFailureAreLogged` | シグナルは 128+s、起動失敗は 127（パラメータ化） | `.signaled(9)` / `.spawnFailed(errno: 2)` | `exit=137`・`reason=exit_137` / `exit=127`・`reason=exit_127` |
| `skippedScanWaitsForTheNextScan` | 走査が見送られたら「今の generation + 1」を待つ | `ingest.script([.skip])`、snapshot の generation 5（rw、ファイル無し）、DELETED の結果 | 戻り値 6、結果が残る、SOURCE_DELETING のまま |
| `signatureCheckedRightBeforeLaunch` | ReaperRunner.run は起動の直前に署名を見る（ND-41 の 2 層目） | `ReaperRunner(layout:, runner: ScriptedProcessRunner(results: []), verifier: FakeSignatureVerifier(valid: false)).run()` | `.notLaunched(reason: "signature")`、runner の記録が空 |

### 6.7 `Tests/VDPipelineTests/RequestExpirerTests.swift`（`@Suite("RequestExpirer")`）

準備: 要求を 1 件書いた状態（updated_at = now）。時計は `scene.clock.advance(seconds:)`。

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `expiresAfterTimeoutAndWithdraws` | 期限を過ぎたら要求と結果を取り下げ DELETE_TIMEOUT で PENDING | 別の request_id の古い結果（同じ partkey）を置く、`advance(3600)` | SOURCE_DELETE_PENDING、`errorCode == .deleteTimeout`、events の detail `no_result`、ID nil、`requests() == []`、`results() == []`、`source_delete_pending recording_key=<pk> reason=no_result` |
| `freshRequestIsNotExpired` | 期限前は取り下げない | `advance(3599)` | SOURCE_DELETING、要求が在る |
| `ceDeleteResultTimeoutSeconds` | CE cleanup.deleteResultTimeoutSeconds が期限になる | `deleteResultTimeoutSeconds = 60`、`advance(61)` | SOURCE_DELETE_PENDING、`errorCode == .deleteTimeout`（既定の 3600 では `advance(61)` で SOURCE_DELETING のまま） |
| `resultWaitingForObservationIsNotExpired` | その request_id の結果が在れば取り下げない（DELETED の観測待ち） | DELETED の結果、`advance(3601)` | SOURCE_DELETING、要求と結果が在る |
| `rereadsTheCurrentRow` | 層 1: 期限は読み直した行の updated_at で判定する | `stale = store.recording(pk)`、`advance(3600)`、`updateRecording(pk, [.needsRecopy(false)])`（updated_at が今になる）、`advance(1)`、`expire(candidates: [stale], reread: { try store.recording($0) })` | SOURCE_DELETING のまま、要求が在る |
| `survivesAConflict` | 層 2: 読み直しの後に状態が変わっていても落ちない | `stale = store.recording(pk)`。DELETED の結果と消えた後の走査で collect(2) して COMPLETED にする。`advance(3601)`、`expire(candidates: [stale], reread: { _ in stale })` | Part COMPLETED のまま、`source_delete_skipped recording_key=<pk> reason=status_changed`、`config_warning` が無い |
| `skippedExpiryKeepsSkipped` | 根拠 B の要求の期限切れは SKIPPED のまま ID を外す | 無音の舞台、`updateRecording(pk, [.deleteRequestID(id)])`、`advance(3601)` | SKIPPED、`errorCode == .noSpeechDetected`、ID nil |
| `targetsAllParts` | 対象は全 Part（Session で絞らない） | `moveSession(to: .completed)`、`advance(3601)` | SOURCE_DELETE_PENDING |
| `noAwaitingPartsDoNothing` | 待つ Part が無ければ何もしない（TEST-28） | 既定の舞台（要求を書かない） | 状態もログも変わらない |

### 6.8 `Tests/VDPipelineTests/ReaperRunnerTests.swift`（行を足す）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `runArgvIsExact` | 起動は bin/voicedock-reaper --home <HOME> だけ | `ScriptedProcessRunner(results: [.exited(0)])`、`FakeSignatureVerifier()` | `.finished(…)`、`recorded == [ProcessSpec(executable: layout.reaperExecutable, arguments: ["--home", p(layout.root)], environment: ProcessEnvironment.standard)]`、`recordedTimeouts == [.seconds(120)]` |
| `runRefusesInvalidSignature` | 署名が不正なら起動しない | `FakeSignatureVerifier(valid: false)` | `.notLaunched(reason: "signature")`、`recorded == []` |

### 6.9 `Tests/VDPipelineTests/DeletionStagesWiringTests.swift`（`@Suite("削除の段の配線", .serialized)`。Worker の tick を回す。TEST-06）

準備（`makeWorld()`）: `PipelineWorld.make { $0.cleanup.deleteSourceAudio = true; $0.device.mountMode = "rw" }`、`installVault()`（T-29）、`installWhisper()`、`pk = registerPart()`（T-18）。
デバイス: `<tmp>/Volumes/DJIMIC3/<PipelineFixtures.relpath>` に inbox と同じバイト列を置き mtime を `1_787_000_000` に（登録の source_size / source_mtime と一致させる）。
`layout.binDirectory` を作り、スタブの reaper と `ReaperConf(deleteSourceAudio: true, volumesRoot: p(<tmp>/Volumes))` を置く。
`world.ingest.setSnapshot(FakeIngest.snapshot(generation: 1, completedAt: world.clock.now(), devices: ["DJIMIC3": [PipelineFixtures.relpath]]))`。

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `tickRequestsDeletionAfterTheRawNote` | 1 tick で Raw の直後に要求を書き、reaper を起動する | `world.worker().tick()` | Part SOURCE_DELETING、要求 1 件、ログに `delete_requested`・`reaper_run exit=0`（スタブの runner の結果）、`world.ingest.scanNowCalls == 1` |
| `nextTickCollectsTheResult` | 次の tick で結果を回収して完了する | 上の後、DELETED の結果を置き、`setSnapshot(generation: 2, devices: ["DJIMIC3": []])`、tick | Part COMPLETED、`sourceDeletedAt` 在り |
| `staleSnapshotDoesNotLaunch` | snapshot が古い tick では reaper を起動しない | completedAt = now − 901 秒 | runner の記録に `--home` が無い（Raw の直後の要求も書かない。DEL-20） |
| `savedHookRunsTheStage` | SAVED の直後の口（SessionSteps.deleteSourcesIfSafe）が削除段を呼ぶ | 既定の設定（削除無効）の world、`addSession(key: "DJIMIC3:20260829", day: "2026-08-29", status: .saved)`・`addPart(partA, status: .rawSaved)`（T-29 の部品）、`SessionSteps(ctx: try await world.context()).deleteSourcesIfSafe("DJIMIC3:20260829")` | Session COMPLETED、Part COMPLETED、`source_delete_skipped session_key=DJIMIC3:20260829 reason=delete_source_audio_disabled` |
| `scanGenerationStartsAtZero` | 起動直後の reaperScanGeneration は 0（どの generation の走査でも判定できる） | Part を SOURCE_DELETING・ID 付きにして（`world.forcePart` と `updateRecording`）DELETED の結果、snapshot generation 1（ファイル無し）、新しい Worker で tick | COMPLETED |

### 6.10 `Tests/VDPipelineTests/DeletionRoundTripTests.swift`（`@Suite("削除の往復", .serialized, .enabled(if: TestEnvironment.diskTests))`）

準備: `tmp = TempDirectory()`、`image = DiskImageVolume(in: tmp, deviceID: DiskImageVolume.uniqueName(), filesystem: .fat32)`（`<tmp>/Volumes/VDT…`。**`/Volumes` の下には決して attach しない**。ボリューム名に `DJIMIC3` を使わない。PLAN §10.2・`DiskImageVolume` がコードで拒む）。Part と Session は `scene.partkey`・`scene.sessionKey`・`scene.deviceID`（インスタンスの値。T-36 §4.10）で指し、static の `DeletionScene.partkey` は使わない、
`scene = DeletionScene(in: tmp, diskImage: image)`、`scene.installRealReaper()`、`locks = LockEvaluator(layout:, verifier: FakeSignatureVerifier(), runner: ProcessRunner(), log: scene.log)`、
`ingest = ScriptedIngest(snapshot: scene.scannedSnapshot(generation: 1))`、`ingest.setScanner { scene.scannedSnapshot(generation: $0) }`、`deps = scene.deletionDependencies(ingest: ingest, locks: locks)`。

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `realReaperDeletesAndTheAppCollects` | 往復: 要求 → 本物の reaper → 走査 → 回収で COMPLETED（FAT32） | requestDeletions → `runReaperIfNeeded(reaperScanGeneration: 0)` | 要求 1 件 → 戻り値 2、イメージ上のファイルが無い、Part COMPLETED・`sourceDeletedAt` 在り・ID nil、`requests() == []`、`results() == []`、`state/processed.log` に request_id の行、`logs/reaper.log` に `source_deleted request_id=<id> partkey=<pk>`、アプリのログに `reaper_run exit=0` と `source_deleted` |
| `realReaperRejectsAChangedFile` | 往復: 要求の後にファイルが変わると reaper が拒否し PENDING | 要求の後にイメージ上のファイルに 1 バイト追記し mtime を戻す → runReaperIfNeeded | Part SOURCE_DELETE_PENDING・`errorCode == .sourceIdentityMismatch`・detail `size_mismatch`、ファイルが残る |
| `readOnlyImageCompletesWithoutRequest` | 読み取り専用で再マウントしたイメージでは要求を書かず device_readonly で完了 | `image.reattach(readOnly: true)`、ingest を `scannedSnapshot(generation: 2)` に → deleteSourcesIfSafe | 要求無し、Session COMPLETED、ファイルが残る |
| `copyTimestampWritesNoRequest` | DEL-12 inbox のコピーの時刻を DB に入れると事前確認で弾く | `updateRecording(pk, [.sourceMtime(<DB の値> + 16_440)])` → requestDeletions | 0、ファイルが残る |

### 6.11 `ConfigEffectPending.swift`（PolicyTests。T-09 §9）

`device.snapshotMaxAgeSeconds`・`cleanup.deleteSourceAudio`・`cleanup.deleteEvaluationBackoffSeconds`・`cleanup.deleteResultTimeoutSeconds` の 4 行を消す（CE テストは §6.3・§6.4・§6.7）。

### 6.12 `PipelineIntegrationTests.swift`（T-29 §6.6 の期待を直す）

本チケットで SAVED の直後の口（`SessionSteps.deleteSourcesIfSafe`）が中身を持つので、既定の設定（削除無効）では PLAN §8.9.5 のとおり
`source_delete_skipped session_key=DJIMIC3:20260829 reason=delete_source_audio_disabled` → Part RAW_SAVED→COMPLETED → Session SAVED→CLEANUP→COMPLETED まで進む。3 本の期待をこれに合わせる（テストを足さない）:

| 関数名 | 直す期待 |
|---|---|
| `oneTickFromBWFToVerifiedDaily` | Part COMPLETED（events の to の列の末尾に `COMPLETED`）、Session COMPLETED（events の to の列の末尾に `CLEANUP`・`COMPLETED`）、ログに上の `source_delete_skipped` |
| `secondPartReopensAndRewrites` | 1 tick 目の後の Session は COMPLETED。2 tick 目の後は Part A・B とも COMPLETED、Session COMPLETED、足された events の to が `MERGING`〜`SAVED`・`CLEANUP`・`COMPLETED`（COMPLETED の Session も再オープンできる。`SessionStates.reopenable`） |
| `missingVaultPausesThenResumes` | 2 回目の tick の後は Part COMPLETED、Session COMPLETED |

## 7. 破壊による証明

| # | 壊し方（1 か所だけ） | 落ちるべきテスト |
|---|---|---|
| 1 | RequestWriter で ① と ② の順を入れ替える（ファイルを先に書く）。② の失敗を注入すると ID が残らない | `queueWriteFailureRollsBackTheID`（ID の巻き戻しを消すと落ちる。順の入れ替えは `deletionActuallyHappensWhenEverythingIsValid` の ID とファイル名の一致で確かめる） |
| 2 | ② の失敗で ID を nil に戻さない | `queueWriteFailureRollsBackTheID` |
| 3 | requestDeletions の freshSnapshot を `ingest.latestSnapshot()`（新鮮さを見ない）にする | `staleSnapshotWritesNothing`、`everyLayerAFaultWritesNoRequest(staleSnapshot)`、`staleSnapshotDoesNotLaunch` |
| 4 | requestDeletions の `deleteRequestID != nil` の飛ばしを消す | `skipsPartsAwaitingAResult` |
| 5 | pended の確認を消す | `skipsPartsPendedThisTick`、`pendedPartIsNotRequestedInTheSameTick` |
| 6 | `.completed` の飛ばしを消す | `skipsSourceDeletingAndCompleted`(completed) |
| 7 | canDeleteSource の呼び出しを消す（常に要求） | `everyLayerAFaultWritesNoRequest`（全件） |
| 8 | deleteSourcesIfSafe の `.unknown` を読み取り専用の扱いから外す | `nd47UnknownReadOnlyWritesNoRequest`、`readOnlyOrUnknownCompletes`(nil) |
| 9 | 未接続（`.absent`）を完了側に入れる | `absentDeviceWaits` |
| 10 | completeWithoutDeleting の「RAW_SAVED で ID を持つ」確認を消す | `rawSavedWithRequestIDDoesNotComplete` |
| 11 | finishCleanup で stagingDisposable の代わりに全 Part の staging を消す | `cleanupFreesStagingButKeepsFailed` |
| 12 | finishCleanup の失敗でも COMPLETED にする | `stagingUnlinkFailureStaysInCleanup` |
| 13 | isDue の `max(a, 1)` を `a` にする（RetryDelay を使わずに式を書き直す） | `dueFollowsBackoff`（(0, 60)・(0, 59)） |
| 14 | isDue の `>=` を `>` にする | `dueFollowsBackoff`（(1, 60)） |
| 15 | collect の request_id の照合を消す | `nd42OlderAttemptResultIsDiscarded` |
| 16 | collect の `s.generation >= reaperScanGeneration` を消す | `nd46DeletedWaitsForAScanAfterTheReaper`(a)、`skippedScanWaitsForTheNextScan` |
| 17 | collect で「デバイスが snapshot に無い」を「消えた」扱いにする | `nd46DeletedWaitsForAScanAfterTheReaper`(b) |
| 18 | collect の対象外の状態の結果を捨てずに残す | `resultForAPartNotWaitingIsDiscarded` |
| 19 | 回収の対象を DeletionScene の Session の Part に絞る（voicedock の形） | `collectionIsNotLimitedToEvaluatedSessions` |
| 20 | pend で SKIPPED も SOURCE_DELETE_PENDING へ遷移させる | `skippedPartRejectedKeepsItsReason`（IllegalTransition か error_code の上書き） |
| 21 | DELETED の SKIPPED を COMPLETED へ進める | `skippedPartStaysSkippedWhenDeleted` |
| 22 | runReaperIfNeeded の readiness を `useCache: true` にする | `readinessIsVerifiedWithoutCache` |
| 23 | scanNow の後に collect しない | `launchesAndCollectsAfterTheScan` |
| 24 | scanNow が nil のときに reaperScanGeneration を変えない | `skippedScanWaitsForTheNextScan` |
| 25 | ReaperRunner.run の署名検証を消す | `runRefusesInvalidSignature`、`signatureCheckedRightBeforeLaunch` |
| 26 | expire の読み直しを消す（一覧の行を使う） | `rereadsTheCurrentRow` |
| 27 | pend の TransitionConflict の捕捉を消す | `survivesAConflict`（config_warning が出る） |
| 28 | expire の「その request_id の結果が在る」確認を消す | `resultWaitingForObservationIsNotExpired` |
| 29 | expire で結果を取り下げない | `expiresAfterTimeoutAndWithdraws` |
| 30 | PartSteps.requestDeletionsAfterRawNote を `{ 0 }` に戻す | `tickRequestsDeletionAfterTheRawNote` |
| 31 | `stageCollectDeleteResults` の本体を空に戻す | `nextTickCollectsTheResult` |
| 32 | `SessionSteps.deleteSourcesIfSafe` の本体を空に戻す | `savedHookRunsTheStage` |

## 8. 受け入れ条件

- [ ] §3 のファイルがすべて在り、T-18 / T-22 / T-29 の空の口（settleSkippedDeletions を除く）が埋まっている
- [ ] 要求を書くのは `RequestWriter` だけ（`DeleteQueue.write` の呼び出しが RequestWriter.swift にしか無い。PR-09）
- [ ] `reaperExecutable` の語が VDPipeline では `ReaperRunner.swift`・`LockEvaluator.swift` だけ（PT-11）
- [ ] 正の対照 `deletionActuallyHappensWhenEverythingIsValid`、ND-41（起動）・42・46・47 の `[A]` のテストが通る
- [ ] `make test` が通り、`make test-disk` で `DeletionRoundTripTests` が通る（出力を PR に貼る）
- [ ] 破壊による証明の各項目で表のテストが落ちることを確かめ、PR 本文に貼った

## 9. SPEC の変更

なし（reason 語・イベントは付録 A.4 のまま。signaled / spawnFailed の exit の写し方は §11 の提案 6 で PLAN を直すなら SPEC も同じ PR で）。

## 10. マージ後にやること

- T-39 が `stageSettleSkippedDeletions` の本体と `SkippedSettler` を書く
- T-42 の実機 E2E（削除 ON）で、この往復が本物の DJI Mic 3 でも成り立つことを利用者が確かめる（【利用者が行う】）

## 11. API 地図への変更提案

1. §11 の `DeletionRequester.swift / SessionDeletionStage.swift / ResultCollector.swift / RequestExpirer.swift` はすべて internal。宣言は本チケット §4。ほかに `DeletionDependencies`・`PendedPartkeys`・`DeleteQueue`・`RequestWriter`（internal）を足す
2. `ReaperRunner.run() async -> ProcessResult` → `run() async -> ReaperRunOutcome`（`.notLaunched(reason:)` / `.finished(ProcessResult)`）。起動の直前の署名検証の失敗を ProcessResult に偽装しない
3. `TickContext` に `let pendedPartkeys = PendedPartkeys()`、`Worker` に `var reaperScanGeneration: UInt64 = 0`
4. §15 に `ScriptedIngest`（作り手 T-38、使う T-39・T-41）と `DeletionScene.installRealReaper()`（T-38）を足す。`ReaperBinary.url() throws -> URL`（T-37）をこの名前で使う（T-37 と名前が違えば T-37 に合わせてここを直す）
5. T-18 §4.13 の「Raw の直後の削除評価の呼び出しは T-29 が足す」と T-29 の口（`requestDeletionsAfterRawNote`）・T-22 の口（`deleteSourcesIfSafe`）は本チケットが本体を書く、で整合している
6. （PLAN に反映済み）PLAN 付録 A.4 の `reaper_run exit=<n>` / `reaper_failed reason=exit_<n>` に、シグナルで終わった場合（`exit=128+s`）と起動に失敗した場合（`exit=127`）、タイムアウト（`exit=null`）の写し方が在る。本チケットはこの形で実装した
7. PLAN §8.9.6「0 以外なら reaper_failed reason=exit_<n>（4 は busy。タイムアウトは reason=timeout）」は、付録 A.4 の列挙に `busy` が在ることから「4 のときは `reason=busy`」と読んで実装した（`DeletionReason.busy`）。「`exit_4` が busy を意味する」の読みなら A.4 の `busy` を消す。どちらの読みかを PLAN の本文に明記したい
8. 00-api-map §16 の「`DeleteQueue.withdrawAllRequests`（T-40）は public」は、本チケットの `DeleteQueue` が internal なので、T-40 で型ごと public にするか、別の public の入口を置くかを決める必要がある
