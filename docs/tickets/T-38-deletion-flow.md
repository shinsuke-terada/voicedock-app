# T-38 VDPipeline: 削除要求・Session の削除段・reaper の起動・結果の回収・期限切れ・後始末

> （F-67・issue #97、2026-09-23）走査の `lstat` が `ENOENT` 以外で失敗したら一覧は不完全（`complete = false`）になり、そのデバイスは snapshot の `devices` に載らない。以後、深さの上限の内側では一覧は完全な列挙で、F-64 の `sourceIsObservedAbsent` の「一覧は完全な列挙を保証しない」という記述は上限の外（と `maxScanDepth` を下げた場合）に限られる（PLAN §8.1・§8.9.5）。

> （F-74・issue #114、2026-09-23。マージ後の追記）手順 5a の決着を ID の無い SOURCE_DELETE_PENDING にも広げた（辺を足さず既存の PENDING→SOURCE_DELETING→COMPLETED、両方 detail `not_deletable`）。`undeletableCause` は何も見つからなければ nil を返し、決着を見送って連続を切る。
> `TickContext.undeletableStreaks` と `DeletionDependencies.init(streaks:)` の既定値を外した。期限切れは読めて request_id と partkey が一致する結果のときだけ飛ばし、取り下げの後に要求が残れば pend しない（`DeleteQueue.hasRequest`・`DeleteQueue.result(requestID:)`）。
> 回収は ID を持つ COMPLETED も拾い（遷移させずに `source_deleted_at` と ID）、DELETED の後始末は遷移が先で ID を外すのは最後。§6.5 の `resultForAPartNotWaitingIsDiscarded` から COMPLETED の場合を外した。テストは `PendingSettlementTests`・`StuckDeleteResultTests`（PLAN §8.9.5〜§8.9.7）。

> （F-69・issue #98、2026-09-23）一覧に在るのに `canDeleteSource` が偽のまま変わらない RAW_SAVED の Part は、期限（backoff を使い切った）を過ぎ、観測できた失敗が同じ接続で 2 回続いたら、消さずに RAW_SAVED→COMPLETED（detail `not_deletable`、原因の語を `error_message` に）にする（§4.5 の手順 5a・`UndeletableStreaks`）。要対応の `undeletableSources` と状態の詳細の一覧は T-32 の型に足した（PLAN §8.9.2・§8.9.5・§8.11・§8.12）。テストは §6.13。

> （F-72・issue #112、2026-09-23。マージ後の追記）`RequestWriter.write` は `async` になり、② の前後で reaper.conf を読み直す（`observeLock1`。本番は `deps.locks.observeReaperConf()`）。
> ② の前に `DELETE_SOURCE_AUDIO=true` で読めなければ書かずに ID を外す。② の後に読めなければ書いた要求を自分で取り下げて ID を外す（取り下げに失敗したら ID を外さずに nil）。どれも `source_delete_skipped recording_key=… reason=lock_mismatch`。
> readiness は各段の先頭で 1 回だけ評価するので、その後に無効化が走っても要求を残さないため（PLAN §8.9.5）。呼び手（§4.5 の手順 6・根拠 B（T-39）・T-41 の後追い）は `try await`。下の §4.4・§4.5・§5 はその分を直した。テストは `RequestWriterRecheckTests`。

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
| `Sources/VDPipeline/UndeletableStreaks.swift`（F-69 で追加） | `UndeletableStreaks`（internal。観測できた失敗の連続回数。Worker が tick をまたいで持ち、`TickContext.undeletableStreaks` → `DeletionDependencies.streaks` で渡す） |
| `Tests/VDPipelineTests/UndeletableSettlementTests.swift`（F-69 で追加） | 期限での決着と、要対応・状態の詳細の数え方（§6.13） |
| `Tests/VDPipelineTests/PendingSettlementTests.swift`（F-74 で追加） | ID の無い SOURCE_DELETE_PENDING の決着・原因が見つからないときの見送り・連続回数の記録の配線 |
| `Tests/VDPipelineTests/StuckDeleteResultTests.swift`（F-74 で追加） | partkey の合わない結果・取り下げきれない要求・ID を持つ COMPLETED の回収・遷移が先の後始末 |
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
    /// （F-74）取り下げの後にこの Part の要求が残っているか: `<requestID>.json` が在る（読めなくても。requestID が RequestID の形のときだけ名前で見る）か、読めて partkey が一致する要求が在る
    static func hasRequest(partkey: String, requestID: String, layout: HomeLayout) -> Bool
    /// （F-74）`queue/result/<requestID>.json`（lstat で在るときだけ。読めなければ result が nil）。requestID が RequestID の形でなければ nil
    static func result(requestID: String, layout: HomeLayout) -> QueuedResult?
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
- `hasRequest`・`result(requestID:)`（F-74）は期限切れ（§4.8）だけが使う。`RequestID.isValid` で名前を確かめてから `requestURL` / `resultURL` を `lstat` する（信用できない値でパスを組まない）
- 取り下げ・捨てるの失敗（`try?`）は記録しない: 残った要求を reaper が処理しても、結果の request_id が DB と合わないので回収で捨てられる（DEL-08）。残った結果は次の回収で同じ判定になる（冪等）

### 4.4 `RequestWriter.swift`

```swift
// 削除要求の ①ID → ②要求ファイル（PLAN §4.4 の書く順）。③の遷移は呼び手（根拠 A と後追いは SOURCE_DELETING へ、根拠 B は遷移しない）。
import VDContract
import VDCore
import VDStore

struct RequestWriter {
    let deps: DeletionDependencies
    /// ロック 1（reaper.conf）の読み。本番は `deps.locks.observeReaperConf()`（F-72）
    let observeLock1: @Sendable () async -> ReaperConfObservation
    /// `self.init(deps: deps, observeLock1: { await locks.observeReaperConf() })`（`let locks = deps.locks`）
    init(deps: DeletionDependencies)
    /// テスト用（@testable）: ロック 1 の読みを差し替える（② の前後で無効化が走った状況を作る）
    init(deps: DeletionDependencies, observeLock1: @escaping @Sendable () async -> ReaperConfObservation)
    /// 書けたら request_id。書けなければ nil（理由はログに出してある）。Store の予期しない例外は投げる
    func write(part: RecordingRow, sessionKey: String) async throws -> String?
    /// `guard case .valid(let conf) = await observeLock1() else { return false }; return conf.deleteSourceAudio`
    private func lock1IsReleased() async -> Bool
    /// `deps.log.log(level, .sourceDeleteSkipped, [(.recordingKey, .string(partkey)), (.reason, .string(DeletionReason.lockMismatch))])`
    private func logLockMismatch(_ partkey: String, level: LogLevel)
}
```

手順:
1. `guard let relpath = part.sourcePath, let size = part.sourceSize, let mtime = part.sourceMtime else { return nil }`（削除条件が真なら揃っている。防御）
2. `now = deps.clock.now()`、`seconds = now.epochMillis >= 0 ? now.epochMillis / 1000 : -((-now.epochMillis + 999) / 1000)`、
   `id = RequestID.make(partkey: part.partkey, utcEpochSeconds: seconds, randomHex6: RequestID.randomHex6())`
3. **① ID を先に**: `guard try deps.store.updateRecordingIfStatus(part.partkey, status: part.status, [.deleteRequestID(id)]) else { deps.logStatusChanged(recordingKey: part.partkey); return nil }`
4. （F-72）**ロック 1 を読み直す**: `guard await lock1IsReleased() else { try deps.store.updateRecording(part.partkey, [.deleteRequestID(nil)]); logLockMismatch(part.partkey, level: .info); return nil }`
5. `request = DeleteRequest(requestID: id, createdAt: deps.zone.iso(now), deviceID: part.deviceID, partkey: part.partkey, sessionKey: sessionKey, target: DeleteTarget(relpath: relpath, size: size, mtime: mtime))`
   （size / mtime は **DB の値 = デバイス上の原本**。DEL-12。絶対パスを持たない。PR-17）
6. **② 要求ファイル**: `do { try DeleteQueue.write(request, layout: deps.layout) } catch {` `try deps.store.updateRecording(part.partkey, [.deleteRequestID(nil)])`、
   `deps.log.warning(.sourceDeletePending, [(.recordingKey, .string(part.partkey)), (.reason, .string(DeletionReason.queueWriteFailed)), (.errorCode, .string(ErrorCode.deleteQueueFailed.rawValue))])`、`return nil }`
7. （F-72）**② の後にもう一度読む**: `guard await lock1IsReleased() else {`
   `do { try SafeUnlink.remove(DeleteQueue.requestURL(id, layout: deps.layout), under: .queueDelete, layout: deps.layout, missingOK: true) } catch { logLockMismatch(part.partkey, level: .warning); return nil }`（取り下げられなければ ID を持ったまま。期限切れが片付ける）、
   `try deps.store.updateRecording(part.partkey, [.deleteRequestID(nil)])`、`logLockMismatch(part.partkey, level: .info)`、`return nil }`
   （偽が見えたなら無効化の段 1 は済んでいるので自分で取り下げる。真が見えたなら段 1 はこの後なので段 4 が取り下げる。PLAN §8.9.5）
8. `return id`

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
   4a. （**F-64 で追加**）`part.status == .rawSaved && Self.sourceIsObservedAbsent(part, in: snapshot, zone: deps.zone)` なら、要求を書かずに
       `do { try deps.store.recordPartTransition(partkey: part.partkey, from: .rawSaved, to: .completed, detail: DeletionReason.alreadyAbsent) } catch is TransitionConflict { deps.logStatusChanged(recordingKey: part.partkey); continue }`、
       `deps.log.info(.sourceDeleteSkipped, [(.recordingKey, .string(part.partkey)), (.reason, .string(DeletionReason.alreadyAbsent))])`、飛ばす（`source_deleted_at` は入れない）
   5. `DeletionPolicy.canDeleteSource(DeletionCandidate(part: part, session: session, parts: parts, twin: nil), ctx)` が偽なら飛ばす。
   5a. （**F-69 で追加**。F-74 で SOURCE_DELETE_PENDING も）5 が偽で `settleableStatuses`（RAW_SAVED・SOURCE_DELETE_PENDING）に在れば、飛ばす前に `considerSettling(part, session:, parts:, snapshot:, ctx:)`:
       `failureIsObserved` が偽なら `deps.streaks.reset(partkey)`、真なら `n = deps.streaks.record(partkey, connectEpoch: snapshot.connectEpoch)`。
       `n >= observedFailuresToSettle`（2）かつ `deadlineHasPassed` なら、`undeletableCause(…)` が nil（F-74）なら `reset` して飛ばし、あれば `settleAsNotDeletable(part, cause:)` して `reset`:
       RAW_SAVED は `recordPartTransition(partkey:, from: .rawSaved, to: .completed, errorMessage: cause, detail: DeletionReason.notDeletable)`、
       SOURCE_DELETE_PENDING は `from: .sourceDeletePending, to: .sourceDeleting, detail: notDeletable` → `from: .sourceDeleting, to: .completed, errorMessage: cause, detail: notDeletable`（F-74）（TransitionConflict → `deps.logStatusChanged(recordingKey:)`）、
       `deps.log.info(.sourceDeleteSkipped, [(.recordingKey, …), (.reason, .string(DeletionReason.notDeletable)), (.detail, .string(cause))])`（`source_deleted_at` は入れない。消していない）。
       5 が真なら `deps.streaks.reset(partkey)` してから 6 へ
   6. `guard let id = try await RequestWriter(deps: deps).write(part: part, sessionKey: session.sessionKey) else { continue }`（①②。F-72 で `await`）
   7. ③ `do { try deps.store.recordPartTransition(partkey: part.partkey, from: part.status, to: .sourceDeleting) } catch is TransitionConflict { deps.logStatusChanged(recordingKey: part.partkey); continue }`（RAW_SAVED か SOURCE_DELETE_PENDING から）
   8. `deps.log.info(.deleteRequested, [(.requestID, .string(id)), (.recordingKey, .string(part.partkey)), (.sessionKey, .string(session.sessionKey))])`
   9. `requested += 1`
5. `return requested`

- `static func sourceIsObservedAbsent(_ part: RecordingRow, in snapshot: DeviceSnapshot, zone: ZonedTime) -> Bool`（internal。**F-64 で追加**）:
  `snapshot.unavailable[part.deviceID] == nil`、`snapshot.devices[part.deviceID]` が在る、`part.sourcePath` が nil でも空でもない、
  `zone.parseISO(part.updatedAt)` が読めて `snapshot.completedAt.epochMillis >= updated.epochMillis + 1000`（取り込み前の snapshot で「無い」と言わない。updated_at は秒に切り捨て）、のすべてを満たし、
  その relpath が `observation.relpaths` に（`DeletionPolicy.sameKey` で）**無い**ときだけ真。新鮮さは手順 1 が確かめる。`readOnly` は見ない（消さないので）。
  一覧は深さの上限の外と読めないディレクトリを含まない（完全な列挙の保証ではない）。照合はスカラー列の一致で NFC / NFD を正規化しない。どちらも「無い」に見えうるが、完了は消さない側（PLAN §8.9.5）。
  これが無いと、削除が有効なのに元ファイルが消えた RAW_SAVED の Part は事前確認が永久に偽で、削除段が `delete_attempts += 1` を繰り返し Session が完了しなかった（PLAN §8.9.5・F-64）
- 決着の関数（internal。**F-69 で追加**。PLAN §8.9.5）:
  - `static let observedFailuresToSettle = 2`
  - `static func deadlineHasPassed(_ part: RecordingRow, session: SessionRow, backoff: [Int], now: Instant, zone: ZonedTime) -> Bool`:
    backoff が空でなく、`session.deleteAttempts >= backoff.count`、`zone.parseISO(part.updatedAt)` が読めて `now − updated >= backoff の合計 × 1000` ミリ秒
  - `static func failureIsObserved(_ part: RecordingRow, parts: [RecordingRow], snapshot: DeviceSnapshot, ctx: DeletionContext) -> Bool`:
    (a) `parts` がすべて `PartStates.terminal`、(b) `snapshot.unavailable[part.deviceID] == nil`・`snapshot.devices[part.deviceID]` が在り `DeviceWritability.observe` が `.writable`、
    (c) `VaultCheck.evaluate(path:marker:).isAvailable`、(d) `part.sourcePath` が nil か空なら真、そうでなければ relpath が一覧に（`sameKey` で）**在る**ときだけ真
    （無い RAW_SAVED は 4a の F-64 が先に拾うので RAW_SAVED にとって d は防御。無い SOURCE_DELETE_PENDING は d が偽で待つ。F-74）
  - `static func undeletableCause(_ part:, session:, parts:, ctx:) -> String?`: `source_info`（source_path・size・mtime のどれかが無い）→ `pre_identity`（`preIdentityCheck` が偽）→ `transcript` → `raw_note`、どれでもなければ nil（F-74）
  - `func considerSettling(…)`・`func settleAsNotDeletable(_ part: RecordingRow, cause: String)`（衝突のテストから直接呼ぶ）
  - 新しい設定キーは作らない（既定の backoff で SAVED から約 81 分。PLAN §8.9.5）
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
    /// 回収を待つ Part の状態（PLAN §8.9.6）= awaitingDeletion ∪ {SKIPPED, COMPLETED}（COMPLETED は F-74）
    static let collectableStatuses: Set<PartStatus> = PartStates.awaitingDeletion.union([.skipped, .completed])
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
            advanceToCompleted(part)                                      // SKIPPED・COMPLETED 以外。遷移が先（F-74）
            store.updateRecording(pk, [.sourceDeletedAt(zone.iso(clock.now())), .deleteRequestID(nil)])
            log.info(.sourceDeleted, [(.recordingKey, pk), (.requestID, result.requestID)])
            discard(q.url)
```
- `advanceToCompleted(part)`: `.skipped`・`.completed` → 何もしない。`.sourceDeleting` → `→COMPLETED`。`.rawSaved`・`.sourceDeletePending` → `→SOURCE_DELETING` → `→COMPLETED`（付録 A.2 の 2 遷移）。`TransitionConflict` → `logStatusChanged(recordingKey:)`（呼び手は続けて source_deleted_at を書き、結果を捨てる）。ほかの例外は投げる（ID と結果が残り、次の tick でやり直す。F-74）
- `source_path` が nil なら「消えた」と判定しない（観測と照らせない。消さない側）
- **時刻を比べない**。reaper の終了を待ってから始まった走査の generation で判定する（voicedock #156 / #182）

**`pend(part, code:, reason:)`**（逐語）:
```text
if part.status == .sourceDeleting:
    do { recordPartTransition(pk, from: .sourceDeleting, to: .sourceDeletePending, errorCode: code, detail: reason) }
    catch is TransitionConflict { logStatusChanged(recordingKey: pk); return false }
    store.updateRecording(pk, [.deleteRequestID(nil)])
else:                                                                   // SKIPPED・RAW_SAVED・SOURCE_DELETE_PENDING・COMPLETED は状態を動かさない（SM-20・F-74）
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
    own = DeleteQueue.result(requestID: id, layout)                       // <id>.json（在れば。読めなければ result が nil）
    if let r = own?.result, sameKey(r.requestID, id), sameKey(r.partkey, pk): continue   // 回収がいずれ拾える結果（DELETED の観測待ち）。取り下げない（F-74: 読めない・partkey が合わない結果は妨げない）
    DeleteQueue.withdrawRequests(partkey: pk, layout)
    if DeleteQueue.hasRequest(partkey: pk, requestID: id, layout): continue   // 取り下げきれない要求が残る → ID を外さずに次の tick で（F-74）
    DeleteQueue.withdrawResults(partkey: pk, layout)
    guard try ResultCollector(deps).pend(part, code: .deleteTimeout, reason: DeletionReason.noResult) else continue   // 層 2: 衝突は pend の中で捕まえる（status_changed）
    if let own, let r = own.result, sameKey(r.requestID, id), !sameKey(r.partkey, pk): DeleteQueue.discard(own.url, layout)   // 回収できない結果を捨てる（F-74）
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
| `source_delete_skipped` | INFO | `recording_key`, `reason=lock_mismatch` | RequestWriter（② の前後の reaper.conf の読み直し。F-72） |
| `source_delete_skipped` | WARNING | `recording_key`, `reason=lock_mismatch` | RequestWriter（② の後の取り下げに失敗して ID を残したとき。F-72） |
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
| `listedSourceIsRequested` | F-64 一覧に在る RAW_SAVED は無いと扱わず、要求を書く通常の経路へ進む | 時計を 60 秒進め、`snapshot(relpaths: [DeletionScene.relpath, 上の別の録音])`（取り込みより後の走査） | 1、SOURCE_DELETING、`source_delete_skipped` のログが無い |
| `absentRawSavedCompletesWithoutRequest` | F-64 一覧に無い RAW_SAVED は要求を書かずに RAW_SAVED→COMPLETED（detail already_absent） | `snapshot(relpaths: ["TX_MIC001_20260912_100000/TX00_MIC001_20260912_100000_orig.wav"])` | 0、`requests() == []`、COMPLETED、`sourceDeletedAt == nil`、`deleteRequestID == nil`、`source_delete_skipped recording_key=<pk> reason=already_absent` |
| `snapshotBeforeIngestionDoesNotComplete` | F-64 取り込み前の snapshot では完了にしない（updated_at と同じ秒・前の走査。境界: ちょうど 1 秒後なら完了） | 時計を 60 秒進め、`completedAt: now + (−60000 / 0 / 999 / 1000) ミリ秒` | 0、`requests() == []`、RAW_SAVED / RAW_SAVED / RAW_SAVED / COMPLETED |
| `absentPendingIsLeftForResolveAbsent` | F-64 SOURCE_DELETE_PENDING は一覧に無くても自動で完了にしない（手動で消した分を完了にする の対象。§8.9.9） | `movePart(pk, to: .sourceDeletePending)`、上と同じ snapshot | 0、SOURCE_DELETE_PENDING のまま、`source_delete_skipped` のログが無い |
| `absentAwaitingResultIsNotCompleted` | F-64 結果待ち（delete_request_id が在る）の RAW_SAVED は一覧に無くても完了にしない | `updateRecording(pk, [.deleteRequestID(…)])`、上と同じ snapshot | 0、RAW_SAVED |
| `missingSourcePathIsNotAbsent` | F-64 source_path が無い・空なら無いと確かめられないので完了にしない（パラメータ化） | `StorePaths.setSourcePath(store, partkey: pk, nil / "")`、上と同じ snapshot | 0、RAW_SAVED、`source_delete_skipped` のログが無い |
| `absentOnReadOnlyDeviceCompletes` | F-64 読み取り専用で接続中でも、無いと観測できれば完了する（消さないので観測値の書き込み可否は問わない） | `snapshot(readOnly: true, relpaths: [上と同じ])` | 0、COMPLETED |
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
| `observedAbsentSourceCompletes` | F-64 接続中で列挙できた一覧に元ファイルが無い RAW_SAVED は、要求を書かずに完了する（source_deleted_at は入れない） | `snapshot(relpaths: ["TX_MIC001_20260912_100000/TX00_MIC001_20260912_100000_orig.wav"])` | `requests() == []`、Part COMPLETED・`sourceDeletedAt == nil`・`deleteRequestID == nil`、最後の event が `RAW_SAVED→COMPLETED` で detail `already_absent`、`source_delete_skipped recording_key=<pk> reason=already_absent`、Session COMPLETED・`deleteAttempts == 0` |
| `emptyListingCompletes` | TEST-28 一覧が空（録音 0 件）でも、接続中で列挙できていれば無いと観測できたとして完了する | `snapshot(relpaths: [])` | 上と同じ |
| `unobservedAbsenceWaits` | F-64 無いと観測できなければ完了にしない（パラメータ化: 未接続・列挙できない・unavailable が観測より優先・snapshot が古い・取り込み前の snapshot） | 時計を 60 秒進め、一覧は上と同じで (a) `includeDevice: false` (b) devices 空・`unavailable: [deviceID: "not_listable"]`（IngestService の姿） (c) 観測は在り `unavailable` にも載る (d) 取り込みの後の snapshot を作ってから時計を 901 秒進める (e) `completedAt: DeletionScene.now + 999 ミリ秒`（updated_at と同じ秒） | Session SAVED・`deleteAttempts == 1`、Part RAW_SAVED・`sourceDeletedAt == nil`、`requests() == []`、`source_delete_skipped` のログが無い |
| `rawSavedWithRequestIDDoesNotComplete` | RAW_SAVED で ID を持つ Part が在れば完了させない | `deleteSourceAudio = false`、`updateRecording(pk, [.deleteRequestID("20260912T030000Z-8483e42457304a9d-abcdef")])` | Session SAVED、`deleteAttempts == 1`、Part RAW_SAVED |
| `cleanupFreesStagingButKeepsFailed` | 完了のとき staging を消し、FAILED の 16 kHz は残す（SM-23） | readOnly true。既定の Part と、10:00 の FAILED(WHISPER_FAILED) の兄弟の両方に `staging/<slug>/audio16k.wav`・`audio16k.wav.tmp`・`whisper.json` を置く | 既定の Part の `staging/<slug>` が無い、兄弟の `audio16k.wav` が在る、Session COMPLETED |
| `stagingUnlinkFailureStaysInCleanup` | staging を消せなければ CLEANUP のまま、次でやり直す | readOnly true、既定の Part の `audio16k.wav` の位置にディレクトリを作る | Session CLEANUP、`disk_space_low session_key=DJIMIC3:20260912 reason=staging_unlink_failed`（WARNING）。ディレクトリを消してもう一度 → COMPLETED |
| `cleanupSessionOnlyFinishes` | CLEANUP の Session は後始末だけ（ロックを見ない） | `moveSession(to: .cleanup)` | COMPLETED、要求無し、`runner.recorded == []` |
| `notEvaluatedStatesAreIgnored` | deleteEvaluated に無い Session は何もしない（パラメータ化: READY・COMPLETED） | `DeletionScene(sessionStatus:)` | 状態も要求も変わらない |
| `pendingSessionRequestsAgain` | SOURCE_DELETE_PENDING の Session から再要求して SOURCE_DELETING へ | `movePart(pk, to: .sourceDeletePending)`、`moveSession(to: .sourceDeletePending)` | 要求 1 件、Session SOURCE_DELETING |
| `pendedPartIsNotRequestedInTheSameTick` | DEL-11 回収で PENDING に落とした Part を同じ周回で再要求しない（#156） | 要求を 1 件書いた状態 → 要求ファイルを消し（reaper の姿）、MISMATCH（`size_mismatch`）の結果 → 同じ deps で collect(0) → 同じ deps で deleteSourcesIfSafe | Part SOURCE_DELETE_PENDING、`requests() == []`。対照: 新しい PendedPartkeys の deps では要求 1 件 |
| `dueFollowsBackoff` | CE cleanup.deleteEvaluationBackoffSeconds 削除評価の backoff（voicedock の 4 事例と境界。パラメータ化） | `isDue(updatedAt: zone.iso(now − 秒), attempts:, now:, backoff: [60, 300, 900, 3600]（既定）, zone:)` の (1, 30)・(1, 120)・(4, 1800)・(4, 7200)・(0, 60)・(0, 59)・(1, 60)。加えて `backoff: [5]` で (1, 30) | 偽・真・偽・真・真・偽・真。`[5]` の (1, 30) は真（既定では偽） |
| `brokenUpdatedAtIsDue` | updated_at が読めなければすぐ評価 | `"not-a-time"` | 真 |
| `emptySessionCompletesWithoutRequest` | TEST-28 Part 0 件の Session は要求を書かずに完了する | `addSession(key: "DJIMIC3:20260913", dayDate: "2026-09-13")`・`moveSession(to: .saved, sessionKey:)` で deleteSourcesIfSafe | 要求無し、その Session は COMPLETED、`source_delete_skipped` が無い |
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
| `resultForAPartNotWaitingIsDiscarded` | 待っていない Part の結果は捨てる（#160。パラメータ化: ID nil・対象外の状態（FAILED）で ID を持つ） | (a) `updateRecording(pk, [.deleteRequestID(nil)])` (b) `DeletionScene(status: .failed, errorCode: .whisperFailed)` で要求を書かずに `updateRecording(pk, [.deleteRequestID(id)])`（F-74 で ID を持つ COMPLETED は回収の対象になったので、その場合は `StuckDeleteResultTests` へ） | 結果が無い、Part の状態は変わらない、`sourceDeletedAt == nil` |
| `collectedAfterTheReaperRemovedTheRequest` | reaper が要求を消した後でも回収できる（BH-1） | 要求ファイルを消し、DELETED | COMPLETED |
| `collectionIsNotLimitedToEvaluatedSessions` | 回収は Session で絞らない（COMPLETED の Session の Part も） | `moveSession(to: .completed)`（Part は SOURCE_DELETING のまま）、DELETED | Part COMPLETED |
| `skippedPartStaysSkippedWhenDeleted` | 根拠 B の DELETED は SKIPPED のまま source_deleted_at を書く | `DeletionScene(status: .skipped, errorCode: .noSpeechDetected)`、`updateRecording(pk, [.deleteRequestID(id)])`、DELETED | SKIPPED、`errorCode == .noSpeechDetected`、`sourceDeletedAt` 在り、ID nil、events が増えない、結果が無い、`config_warning` が無い |
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
| `nonZeroExitIsLogged` | 0 以外は reaper_failed exit_<n>（4 は busy。パラメータ化: 4・2・3） | `.exited(n)` | `reaper_run exit=<n>`、`reaper_failed reason=exit_<n>`（4 は `reason=busy` で、`reason=exit_4` は出ない）、scanNow は呼ぶ |
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
| `nextTickCollectsTheResult` | 次の tick で結果を回収して完了する | 上の後、要求ファイルを消し（reaper の姿。次の tick で reaper を起動させず、回収を段 collectDeleteResults だけにする）、DELETED の結果を置き、`setSnapshot(generation: 2, devices: ["DJIMIC3": []])`、tick | Part COMPLETED、`sourceDeletedAt` 在り、`--home` の起動は 1 回のまま |
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

### 6.13 `Tests/VDPipelineTests/UndeletableSettlementTests.swift`（`@Suite("UndeletableSettlement")`。F-69 で追加）

舞台は `DeletionScene`。原因は `appendToRawNote`（Raw ノートの手の編集 → `raw_note`）・`updateRecording(pk, [.sourceSize(8192)])`（→ `pre_identity`）・transcript の削除（→ `transcript`）・`setSourcePath(nil)`（→ `source_info`）。
期限は `updateSession(key, [.deleteAttempts(n)])` と時計（Part の updated_at は `DeletionScene.now`）で作る。連続回数は 1 本のテストの中で 1 つの `UndeletableStreaks` を `deletionDependencies(…, streaks:)` に渡して共有する。
一時的な失敗はテストの中の `RejectingVolumeOpener`（`.rejected(not_a_mount_point)`）で作る。

| 関数名 | 表示名 | 入力 | 期待 |
|---|---|---|---|
| `beforeTheDeadlineWaits` | F-69 期限の前は待つ（パラメータ化: backoff を使い切っていない・RAW_SAVED から合計に 1 秒足りない） | (attempts 2, 100000 秒)・(4, 4859 秒)、2 回評価 | Session SAVED・attempts + 2、Part RAW_SAVED、`reason=not_deletable` のログが無い |
| `atTheDeadlineSettlesWithoutDeleting` | F-69 期限を過ぎ、観測できた失敗が 2 回続いたら消さずに RAW_SAVED→COMPLETED（detail not_deletable・原因を記録）で Session も完了する（パラメータ化: 原因 4 つ） | (4, 4860 秒)、1 回目・2 回目 | 1 回目は待つ。2 回目で Part COMPLETED・`sourceDeletedAt == nil`・`errorMessage` が原因の語、最後の遷移の detail `not_deletable`、ログ `… reason=not_deletable detail=<語>`、要求なし、元ファイルが残る、Session COMPLETED |
| `evaluationsFollowTheBackoffUntilSettled` | F-69 backoff どおりに評価を重ねると、直後の 1 回と backoff の 3 回が偽で、backoff の 4 回目（SAVED から 4860 秒）の評価で決着する | SAVED の直後の 1 回と `dueSessionKeys` に従う 4 回 | 3 回目までは RAW_SAVED、4 回目で COMPLETED |
| `firstEvaluationAfterLongAbsenceDoesNotSettle` | F-69 長く抜いた後の最初の評価では、一時的な失敗で決着しない（パラメータ化: ボリュームを開けない・後続の Part が処理中で Raw ノートが未更新） | attempts 30・7 日後・connectEpoch 2。(a) `RejectingVolumeOpener` で 1 回、次に通常の opener で 1 回 (b) TRANSCRIBED の Part を足して 3 回 | (a) 1 回目は待ち、2 回目は SOURCE_DELETING・要求 1 件 (b) 決着しない |
| `streakRestartsOnReconnect` | F-69 観測できた失敗が同じ接続で 2 回続いて初めて決着する。挿し直す（connectEpoch が変わる）と数え直す | epoch 1 → 2 → 2 | 2 回目の後は待った姿、3 回目で決着 |
| `unobservedDoesNotSettle` | F-69 期限を過ぎても観測できなければ決着しない（パラメータ化: 未接続・列挙できない・unavailable が優先・snapshot が古い（呼び手の新鮮さで）・Vault が使えない） | (4, 4860 秒) と各 snapshot / `.obsidian` の削除、2 回評価 | 待った姿 |
| `absentSourceIsLeftToF64` | F-69 一覧に無いのは F-64 の担当（detail already_absent。not_deletable にしない） | 別の録音だけの一覧 | detail `already_absent`、数えない |
| `readOnlyDeviceIsNotSettledAsUndeletable` | F-69 接続中で読み取り専用なら従来どおり device_readonly の完了（not_deletable にしない・要対応に数えない） | `readOnly: true` | COMPLETED・detail nil、数えない |
| `deletablePartIsRequestedEvenPastTheDeadline` | F-69 消せるなら期限を過ぎていても要求を書く（決着は canDeleteSource が偽のときだけ） | 原因なし・(4, 4860 秒) | SOURCE_DELETING、要求 1 件 |
| `mixedSessionRequestsOneAndSettlesTheOther` | F-69 同じ Session に消せる Part と決着する Part が混ざれば、前者は要求を書き、後者だけ消さずに完了する | 2 本目の Part（size を壊す）、(4, 4860 秒)、2 回評価 | 1 本目 SOURCE_DELETING・要求 1 件、2 本目 COMPLETED・detail `not_deletable`、Session SOURCE_DELETING |
| `settleConflictLogsStatusChanged` | F-69 決着の遷移が衝突したら status_changed を出して飛ばす（not_deletable のログを出さない） | 読んだ行の後に COMPLETED へ進め、`settleAsNotDeletable` を直接呼ぶ | `reason=status_changed`、`not_deletable` のログ・`config_warning` が無い |
| `onlyStillListedPartsAreAttention` | F-69 要対応に数えるのは、最新の snapshot で接続中かつ一覧にまだ在るものだけ（抜いている・一覧に無い・snapshot 無しは数えない） | 決着後 | `completedParts(lastDetail:)` が 1 件、`undeletableStillListed` が在る → 1 件・未接続 / 一覧に無い / nil → 0 件、`items == [.undeletableSources(1)]`・操作 `[.openDetails]` |
| `settledWithoutSourcePathIsNotAttention` | F-69 source_path が無いまま決着した Part は要対応に数えない（一覧と照らせない） | `source_path` が無いまま決着 | DB に 1 件、要対応 0 件 |
| `deletedOrRetargetedPartIsNotCounted` | F-69 過去分の削除で消えた（source_deleted_at が在る）・再び対象になった Part は数えない | `sourceDeletedAt` を入れる・COMPLETED→SOURCE_DELETING | 0 件 |
| `settledPartIsRetargetedByBacklog` | F-69 決着した Part は「過去分を削除対象にする」で再び評価され、原因が直れば対象になる | 決着後に `planBacklog`、size を戻して再び | 対象外 `not_deletable` → 対象 |
| `statusReportListsSettledParts` | F-69 状態の詳細に決着した Part を全部、原因とデバイスでの在否を添えて出す（パラメータ化: 在る・一覧に無い・観測できない） | Raw ノートの編集で決着、各 snapshot で `StatusReporter.build` | 「消せなかった録音（1 件。消さずに完了にしたもの）」、次の行が `  <partkey>`、その次が `    Raw ノートの照合が合わない、デバイスに在る / デバイスの一覧に無い / デバイスを観測できない` |
| `noSettledPartsIsEmpty` | TEST-28 決着した Part が 0 件なら空・要対応に出さない・状態の詳細に行を出さない | 既定の舞台 | `[]`・items `[]`・「消せなかった録音」の行が無い |

### 6.14 `Tests/VDPipelineTests/PendingSettlementTests.swift`（`@Suite("PendingSettlement")`。F-74 で追加）

舞台は `DeletionScene(status: .sourceDeletePending, errorCode: .sourceIdentityMismatch, sessionStatus: .sourceDeleting)`（reaper の拒否で ID の無い PENDING になった姿）。原因・期限・連続回数の作り方は §6.13 と同じ。
2 遷移の間で落ちた姿は、SQLite のトリガ（`SOURCE_DELETING→COMPLETED` の更新を `RAISE(ABORT)`）で 2 つ目の遷移だけを失敗させて作る。

| 関数名 | 表示名 | 入力 | 期待 |
|---|---|---|---|
| `pendingPartSettlesWithoutDeleting` | F-74 ID の無い SOURCE_DELETE_PENDING も期限を過ぎ観測できた失敗が 2 回続いたら、消さずに PENDING→SOURCE_DELETING→COMPLETED（detail not_deletable・原因を記録）で Session も完了する（パラメータ化: 原因 4 つ） | (4, 4860 秒)、1 回目・2 回目 | 1 回目は待つ（Part PENDING・Session SOURCE_DELETING・attempts + 1）。2 回目で Part COMPLETED・`errorCode == nil`・`errorMessage` が原因の語・`sourceDeletedAt == nil`、最後の 2 本の遷移 `SOURCE_DELETE_PENDING→SOURCE_DELETING`・`SOURCE_DELETING→COMPLETED` の detail が両方 `not_deletable`、ログ `… reason=not_deletable detail=<語>`、要求なし、元ファイルが残る、Session COMPLETED |
| `pendingPartBeforeTheDeadlineWaits` | F-74 期限の前（PENDING にしてから backoff の合計に 1 秒足りない）は SOURCE_DELETE_PENDING のまま待つ | (4, 4859 秒)、2 回評価 | 待った姿 |
| `absentPendingIsNotSettled` | F-74 一覧に無い SOURCE_DELETE_PENDING は not_deletable で決着させない（「手動で消した分を完了にする」の担当） | 別の録音だけの一覧、(4, 4860 秒)、2 回評価 | 待った姿、`completedParts(lastDetail:)` が 0 件 |
| `settledPendingIsCountedAndRetargeted` | F-74 SOURCE_DELETE_PENDING から決着した Part も要対応・状態の詳細に数え、「過去分を削除対象にする」で再評価され、原因が直れば対象になる | size を壊して決着、`StatusReporter.build`、`planBacklog`、size を戻して再び | `completedParts` と `undeletableStillListed` が 1 件、「消せなかった録音（1 件。…）」の次の行が `  <partkey>`・`    事前確認で原本が合わない（サイズ・時刻・場所）、デバイスに在る`、Session COMPLETED、対象外 `not_deletable` → 対象 |
| `pendingSettleConflictLogsStatusChanged` | F-74 PENDING の決着の 1 つ目の遷移が衝突したら status_changed を出して飛ばす（not_deletable のログも遷移も書かない） | 読んだ行の後に `PENDING→SOURCE_DELETING` へ進め、`settleAsNotDeletable` を直接呼ぶ | `reason=status_changed`、`not_deletable` のログ・`config_warning`・detail `not_deletable` の遷移が無い |
| `pendingAwaitingAResultIsNotSettled` | F-74 結果待ち（delete_request_id を持つ）SOURCE_DELETE_PENDING は、原因があり期限を過ぎていても決着させない（結果か期限切れを待つ） | `updateRecording(pk, [.deleteRequestID(id)])`、size を壊す、(4, 4860 秒)、2 回評価 | Part PENDING・ID のまま、`not_deletable` のログが無い、数えない、Session SOURCE_DELETING |
| `interruptedSettleIsRecoveredAndSettledAgain` | F-74 PENDING の決着の 2 遷移の間で落ちたら ID の無い SOURCE_DELETING が残るが、起動時の復旧が PENDING に戻し、次の評価で決着し直す | トリガで 2 つ目の遷移を失敗させて 2 回評価 → トリガを消す → `Recovery.run()` → (4, 4860 秒) → 新しい連続回数の記録で 2 回評価 | 1 段目: Part SOURCE_DELETING・ID nil・`config_warning rule=store`・`not_deletable` のログ無し。復旧: 戻した数 2、Part・Session とも SOURCE_DELETE_PENDING。2 段目: Part COMPLETED・`errorMessage == "pre_identity"`・最後の detail `not_deletable`・数える、Session COMPLETED |
| `noCauseFoundDoesNotSettleAndRestartsTheStreak` | F-74 決着の直前に調べ直して原因が見つからなければ決着させず（pre_identity にしない）、連続を切る | 既定の舞台（消せる Part）・(4, 4860 秒)。`considerSettling` を直接 2 回、Raw ノートを壊して 1 回・もう 1 回 | `undeletableCause == nil`、2 回では RAW_SAVED のまま・ログ無し、壊した後の 1 回目も RAW_SAVED（連続が切れている）、2 回目で COMPLETED・`errorMessage == "raw_note"` |
| `workerSharesOneStreakRecordAcrossTicks` | F-74 Worker は tick をまたいで同じ連続回数の記録を TickContext と削除の段の依存に渡す | `PipelineWorld` の Worker で `makeContext` を 2 回 | `DeletionDependencies(ctx: 1 回目).streaks.record(pk, 1) == 1`、2 回目の ctx から `== 2`、`ctx.undeletableStreaks.record == 3` |

### 6.15 `Tests/VDPipelineTests/StuckDeleteResultTests.swift`（`@Suite("StuckDeleteResult")`。F-74 で追加）

舞台は `DeletionScene`。後追いの ③ の前に止まった姿は `movePart(pk, to: .completed)` → `updateRecording(pk, [.deleteRequestID(id)])`。遷移の DB の失敗は SQLite のトリガ（COMPLETED への更新を `RAISE(ABORT)`）で作る。

| 関数名 | 表示名 | 入力 | 期待 |
|---|---|---|---|
| `emptyPartkeyResultDoesNotBlockExpiry` | F-74 partkey が空の結果（reaper が読めない要求に書いたもの）は期限切れを妨げず、pend の後に捨てる | 要求 1 件 → 要求を消し `writeResult(partkey: "", requestID: id, status: .sourceIdentityMismatch, detail: "malformed_request")` → 回収 → `advance(3600)` → 期限切れ | 回収の後も結果は残り SOURCE_DELETING。期限切れで PENDING・`DELETE_TIMEOUT`・ID nil・`sourceDeletedAt == nil`、結果が無い、`source_delete_pending … reason=no_result` |
| `undecodableResultDoesNotBlockExpiry` | F-74 読めない結果は期限切れを妨げない（結果のファイルは回収と同じく残す） | 要求を消し `<id>.json` に `{` → `advance(3600)` → 期限切れ | PENDING・ID nil、結果のファイルは残る |
| `leftoverRequestKeepsTheID` | F-74 取り下げきれない要求（読めない <request_id>.json）が残れば pend せず ID を持ったまま次の tick でやり直す | 要求ファイルを `{` にする → `advance(3601)` → 期限切れ → 要求を消す → 期限切れ | 1 回目: SOURCE_DELETING・ID のまま・要求 1 件・`source_delete_pending` が無い。2 回目: PENDING・`DELETE_TIMEOUT`・ID nil |
| `deletedResultOfCompletedPartIsCollected` | F-74 後追いの ③ の前に止まった COMPLETED の Part（ID を持つ）の DELETED を回収し、遷移させずに source_deleted_at を書いて ID を外す | COMPLETED・ID、DELETED の結果、消えた後の走査で回収 | COMPLETED のまま・`sourceDeletedAt == "2026-09-12T12:00:00+09:00"`・ID nil、events が増えない、結果が無い、`source_deleted recording_key=… request_id=…`、`config_warning` が無い |
| `failedResultOfCompletedPartOnlyClearsTheID` | F-74 ID を持つ COMPLETED の拒否・一覧にまだ在るは ID を外すだけ（COMPLETED のまま、source_deleted_at は入れない）（パラメータ化） | (a) `SOURCE_IDENTITY_MISMATCH`（`size_mismatch`） (b) DELETED で一覧にまだ在る | COMPLETED・ID nil・`sourceDeletedAt == nil`、events が増えない、結果が無い、`source_delete_pending … reason=size_mismatch / still_in_inventory` |
| `failedTransitionKeepsTheIDAndResult` | F-74 DELETED の遷移が DB で失敗したら ID と結果を残し（ID の無い SOURCE_DELETING を残さない）、次の回収でやり直す | 要求 1 件・DELETED の結果、トリガで COMPLETED への遷移を失敗させて回収 → トリガを消して回収 | 1 回目: SOURCE_DELETING・ID のまま・`sourceDeletedAt == nil`・結果が残る・`config_warning rule=store`。2 回目: COMPLETED・ID nil・`sourceDeletedAt` が入る・結果が無い |
| `emptyQueueHasNoRequestOrResult` | F-74 TEST-28 queue が空なら要求は残っておらず結果も無い（request_id が空文字でも） | 既定の舞台。request_id は RequestID の形のものと `""` | `hasRequest == false`・`result(requestID:) == nil` |

## 7. 破壊による証明

| # | 壊し方（1 か所だけ） | 落ちるべきテスト |
|---|---|---|
| 1 | RequestWriter で ① と ② の順を入れ替える（ファイルを先に書く） | `writerRefusesAStaleRow`（① が状態の変化で弾かれても要求ファイルが残る。ID の巻き戻しは 2 が確かめる） |
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
| 18 | collect の `!collectableStatuses.contains(part.status)` の確認を消す（対象外の状態で ID を持つ Part の結果を回収する） | `resultForAPartNotWaitingIsDiscarded`(FAILED で ID を持つ) |
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
| 33 | （F-64）requestDeletions の手順 4a を消す（不具合の再現） | `observedAbsentSourceCompletes`、`emptyListingCompletes`、`absentRawSavedCompletesWithoutRequest`、`absentOnReadOnlyDeviceCompletes`、`snapshotBeforeIngestionDoesNotComplete`(1000) |
| 34 | （F-64）`sourceIsObservedAbsent` でデバイスが snapshot に無いときに真を返す | `unobservedAbsenceWaits`(未接続)、`absentDeviceWaits` |
| 35 | （F-64）`sourceIsObservedAbsent` の `unavailable` の確認を消す | `unobservedAbsenceWaits`(unavailable が優先) |
| 36 | （F-64）手順 1 の freshSnapshot を `ingest.latestSnapshot()` にする（3 と同じ壊し方） | `unobservedAbsenceWaits`(snapshot が古い)、`staleSnapshotWritesNothing` |
| 37 | （F-64）`sourceIsObservedAbsent` が一覧を見ずに真を返す | `listedSourceIsRequested`（ほかのテストの snapshot は updated_at と同じ時刻なので「取り込みより後」で先に偽になり、これだけが落ちる） |
| 38 | （F-64）手順 4a の `part.status == .rawSaved` を外す | `absentPendingIsLeftForResolveAbsent` |
| 39 | （F-64）`sourceIsObservedAbsent` の `!relpath.isEmpty` を消す | `missingSourcePathIsNotAbsent`("") |
| 40 | （F-64）手順 4a で `source_deleted_at` を入れる | `observedAbsentSourceCompletes`、`emptyListingCompletes`、`absentRawSavedCompletesWithoutRequest` |
| 41 | （F-64）手順 4a の遷移に detail を付けない | `observedAbsentSourceCompletes`、`emptyListingCompletes` |
| 42 | （F-64）`sourceIsObservedAbsent` の「取り込みより後」の条件を消す | `snapshotBeforeIngestionDoesNotComplete`(−60000・0・999)、`unobservedAbsenceWaits`(取り込み前) |
| 43 | （F-64）「取り込みより後」の `+ 1000` を消す（秒の切り捨てを考えない） | `snapshotBeforeIngestionDoesNotComplete`(999) |
| 44 | （F-64）手順 4a を手順 3（`delete_request_id` の飛ばし）より前に移す | `absentAwaitingResultIsNotCompleted` |
| 45 | （F-69）`deadlineHasPassed` の期限を消す（即決着） | `beforeTheDeadlineWaits`(両方)、`evaluationsFollowTheBackoffUntilSettled` |
| 46 | （F-69）`failureIsObserved` の観測 (b) を消す（未接続でも決着） | `unobservedDoesNotSettle`(未接続・列挙できない・unavailable が優先) |
| 47 | （F-69）手順 5a で `source_deleted_at` を入れる | `atTheDeadlineSettlesWithoutDeleting`、`mixedSessionRequestsOneAndSettlesTheOther`、`onlyStillListedPartsAreAttention`、`settledWithoutSourcePathIsNotAttention`、`statusReportListsSettledParts`、`settledPartIsRetargetedByBacklog`（source_deleted_at が在ると数えない・過去分の対象外） |
| 48 | （F-69）`AttentionEvaluator.items` が `undeletableSources` を出さない | `onlyStillListedPartsAreAttention`、`orderFollowsTheSpecTable` |
| 49 | （F-69）`failureIsObserved` の (a)（Part がすべて終端）を消す | `firstEvaluationAfterLongAbsenceDoesNotSettle`(Raw ノートが未更新) |
| 50 | （F-69）`observedFailuresToSettle` を 1 にする（連続を求めない） | `firstEvaluationAfterLongAbsenceDoesNotSettle`(開けない)、`streakRestartsOnReconnect`、`atTheDeadlineSettlesWithoutDeleting` |
| 51 | （F-69）`failureIsObserved` の (c)（Vault）を消す | `unobservedDoesNotSettle`(Vault が使えない) |
| 52 | （F-69）`undeletableStillListed` が `.unobserved` も数える（抜いている間・source_path が無いものも要対応に出す） | `onlyStillListedPartsAreAttention`、`settledWithoutSourcePathIsNotAttention` |
| 53 | （F-69・F-74）`failureIsObserved` の (d)（一覧に在る）を常に真にする | `absentPendingIsNotSettled`（一覧に無い SOURCE_DELETE_PENDING は d だけが止める。RAW_SAVED は手順 4a（F-64）が先に `already_absent` で完了させるので、RAW_SAVED のテストは落ちない） |
| 54 | （F-74）`settleableStatuses` を `[.rawSaved]` に戻す | `pendingPartSettlesWithoutDeleting`、`settledPendingIsCountedAndRetargeted`、`interruptedSettleIsRecoveredAndSettledAgain` |
| 55 | （F-74）PENDING の 2 つ目の遷移の detail `not_deletable` を外す | `pendingPartSettlesWithoutDeleting`、`settledPendingIsCountedAndRetargeted`（最後の遷移の detail で数える） |
| 56 | （F-74）`settleAsNotDeletable` の `.sourceDeletePending` の枝を消す | `pendingPartSettlesWithoutDeleting`、`settledPendingIsCountedAndRetargeted`、`pendingSettleConflictLogsStatusChanged` |
| 57 | （F-74）手順 5a の期限（`deadlineHasPassed`）の確認を消す | `pendingPartBeforeTheDeadlineWaits` |
| 58 | （F-74）手順 3（`deleteRequestID != nil` の飛ばし）を消す | `pendingAwaitingAResultIsNotSettled`（と 4 の `skipsPartsAwaitingAResult`） |
| 59 | （F-74）起動時の復旧の写像から Part の `SOURCE_DELETING→SOURCE_DELETE_PENDING` を外す | `interruptedSettleIsRecoveredAndSettledAgain` |
| 60 | （F-74）`undeletableCause` の最後を `pre_identity` に戻す | `noCauseFoundDoesNotSettleAndRestartsTheStreak` |
| 61 | （F-74）原因が nil のときに連続を切らない | `noCauseFoundDoesNotSettleAndRestartsTheStreak` |
| 62 | （F-74）`Worker.makeContext` で `UndeletableStreaks()` を新しく作って渡す | `workerSharesOneStreakRecordAcrossTicks` |
| 63 | （F-74）期限切れの飛ばしを「その request_id の結果ファイルが在れば」に戻す（自分の結果の partkey を照合しない） | `emptyPartkeyResultDoesNotBlockExpiry`、`undecodableResultDoesNotBlockExpiry` |
| 64 | （F-74）pend の後に partkey の合わない自分の結果を捨てない | `emptyPartkeyResultDoesNotBlockExpiry` |
| 65 | （F-74）期限切れの `hasRequest` の確認を消す | `leftoverRequestKeepsTheID` |
| 66 | （F-74）`collectableStatuses` から COMPLETED を外す | `deletedResultOfCompletedPartIsCollected`、`failedResultOfCompletedPartOnlyClearsTheID` |
| 67 | （F-74）DELETED の後始末を「`source_deleted_at` と ID → 遷移」の順に戻す | `failedTransitionKeepsTheIDAndResult` |
| 68 | （F-74）`DeleteQueue.result(requestID:)` の lstat による存在の確認を消す | `emptyQueueHasNoRequestOrResult` |

## 8. 受け入れ条件

- [ ] §3 のファイルがすべて在り、T-18 / T-22 / T-29 の空の口（settleSkippedDeletions を除く）が埋まっている
- [ ] 要求を書くのは `RequestWriter` だけ（`DeleteQueue.write` の呼び出しが RequestWriter.swift にしか無い。PR-09）
- [ ] `reaperExecutable` の語が VDPipeline では `ReaperRunner.swift`・`LockEvaluator.swift` だけ（PT-11）
- [ ] 正の対照 `deletionActuallyHappensWhenEverythingIsValid`、ND-41（起動）・42・46・47 の `[A]` のテストが通る
- [ ] `make test` が通り、`make test-disk` で `DeletionRoundTripTests` が通る（出力を PR に貼る）
- [ ] 破壊による証明の各項目で表のテストが落ちることを確かめ、PR 本文に貼った

## 9. SPEC の変更

なし（A.4 は反映済み）。F-64 で A.2 の注記に「元ファイルが無いと観測できた RAW_SAVED は既存の RAW_SAVED→COMPLETED を detail `already_absent` で使う」を足した（辺も語も増やさない。`tools/spec/make-spec.py` で SPEC を作り直した）。
F-69 で A.2 の注記に detail `not_deletable` を、A.4 の `source_delete_skipped` の理由語に `not_deletable` と原因の `detail=source_info|pre_identity|transcript|raw_note` を足した（辺は増やさない。SPEC を作り直した）。

## 10. マージ後にやること

- T-39 が `stageSettleSkippedDeletions` の本体と `SkippedSettler` を書く
- T-42 の実機 E2E（削除 ON）で、この往復が本物の DJI Mic 3 でも成り立つことを利用者が確かめる（【利用者が行う】）

## 11. API 地図への変更提案

1. §11 の `DeletionRequester.swift / SessionDeletionStage.swift / ResultCollector.swift / RequestExpirer.swift` はすべて internal。宣言は本チケット §4。ほかに `DeletionDependencies`・`PendedPartkeys`・`DeleteQueue`・`RequestWriter`（internal）を足す
2. 地図 §11 の `ReaperRunOutcome` の説明を `.notLaunched(reason:)` / `.finished(ProcessResult)` に直す（起動の直前の署名検証の失敗を ProcessResult に偽装しない）
3. `TickContext` に `let pendedPartkeys = PendedPartkeys()`、`Worker` に `var reaperScanGeneration: UInt64 = 0`
4. §15 に `ScriptedIngest`（作り手 T-38、使う T-39・T-41）と `DeletionScene.installRealReaper()`（T-38）を足す。`ReaperBinary.url() throws -> URL`（T-37）をこの名前で使う（T-37 と名前が違えば T-37 に合わせてここを直す）
5. T-18 §4.13 の「Raw の直後の削除評価の呼び出しは T-29 が足す」と T-29 の口（`requestDeletionsAfterRawNote`）・T-22 の口（`deleteSourcesIfSafe`）は本チケットが本体を書く、で整合している
6. （PLAN に反映済み）PLAN 付録 A.4 の `reaper_run exit=<n>` / `reaper_failed reason=exit_<n>` に、シグナルで終わった場合（`exit=128+s`）と起動に失敗した場合（`exit=127`）、タイムアウト（`exit=null`）の写し方が在る。本チケットはこの形で実装した
7. PLAN §8.9.6「0 以外なら reaper_failed reason=exit_<n>（4 は busy。タイムアウトは reason=timeout）」は、付録 A.4 の列挙に `busy` が在ることから「4 のときは `reason=busy`」と読んで実装した（`DeletionReason.busy`）。「`exit_4` が busy を意味する」の読みなら A.4 の `busy` を消す。どちらの読みかを PLAN の本文に明記したい
8. §16 の public の一覧から `DeleteQueue.withdrawAllRequests` を外す（T-40 §4.2 も internal と宣言し、呼び手は同じモジュールの DeletionEnabler）。`DeleteQueue` は internal のまま
