# T-18 VDPipeline: ConfigStore・Worker の枠・復旧・requeue・工程内リトライ・ガード・Part の変換と文字起こし

| 項目 | 値 |
|---|---|
| ID | T-18 |
| Phase | 4（変換と文字起こし） |
| 前提 | T-15（`IngestService`・`DeviceSnapshot`・`IngestState`）、T-16（`Normalizer`・`SpaceCheck`・`BWFWriter`）、T-17（`Transcriber`・`FakeWhisper`）。間接に T-06・T-08・T-09・T-10・T-11・T-45 |
| 見積もり | Sources 約 1,300 行、Tests 約 1,500 行 |

## 1. 目的

Worker（actor）を 1 本の直列ループとして組み立て、tick の全段の枠（後続チケットが中身を足す場所）を決める。
設定の読み書き（ConfigStore）・起動時の復旧・requeue の 4 つの契機・工程内リトライ・ガード（遷移せずに待つ）・Part の「16 kHz 変換」と「文字起こし」の呼び手の手順を実装する。
Raw ノート（T-29）・Session の工程（T-22）・削除（T-38 以降）・診断の仕事（T-32）は、このチケットでは**空の本体**を置く。

## 2. 参照

- PLAN §2.1、§5.1〜§5.5（全体）、§6.1（ConfigStore）、§8.3・§8.4 の「呼び手の手順」、§8.14（LicenseGate）、§8.15（起動・スリープ・ログ）、付録 A.1〜A.4
- 00-api-map §11（VDPipeline）・§15（TestSupport の作り手）
- voicedock@d3d595e: `src/voicedock/worker.py:104-307`、`src/voicedock/pipeline.py:266-463, 1537-1868`、
  `tests/unit/test_worker_loop.py:170-760`、`tests/unit/test_part_resume.py`、`tests/unit/test_missing_input.py`
- 移植メモ V3 §0〜§3、§8〜§9

## 3. 作るもの

| パス | 中身 |
|---|---|
| `Sources/VDPipeline/ConfigStore.swift` | `ConfigStore`（actor） |
| `Sources/VDPipeline/IngestPort.swift` | `IngestPort`（Worker が IngestService に求めるもの）と `extension IngestService: IngestPort` |
| `Sources/VDPipeline/LicenseGate.swift` | `LicenseGate` / `AlwaysAllowLicenseGate` |
| `Sources/VDPipeline/WorkerDependencies.swift` | `WorkerDependencies` |
| `Sources/VDPipeline/WorkerStatus.swift` | `WorkerStatus` / `WorkerActivity` / `RequeueReason` |
| `Sources/VDPipeline/Worker.swift` | `Worker`（actor）: 状態・start・tick・run・停止・requeue・status |
| `Sources/VDPipeline/Worker+PartStages.swift` | tick の段: groupNewParts・requeueRecopied・closeIdleSessions・processPendingParts・requeueOnConnect・manualRequeue |
| `Sources/VDPipeline/Worker+SessionStages.swift` | 段 processReadySessions（**空。T-22 が書く**） |
| `Sources/VDPipeline/Worker+NoteStages.swift` | 段 refreshVaultIndex（**空。T-29 が書く**） |
| `Sources/VDPipeline/Worker+DeletionStages.swift` | 段 collectDeleteResults・expireDeleteRequests・evaluateDeletions・settleSkippedDeletions・runReaperIfNeeded（**空。T-38 / T-39 が書く**） |
| `Sources/VDPipeline/Worker+Jobs.swift` | 段 pendingJobs（**空。T-32 が書く**） |
| `Sources/VDPipeline/TickStage.swift` | `TickStage`（internal） |
| `Sources/VDPipeline/TickContext.swift` | `TickContext`（internal） |
| `Sources/VDPipeline/StopFlag.swift` | `StopFlag`（internal） |
| `Sources/VDPipeline/ActivityBoard.swift` | `ActivityBoard`・`SleepAssertion`・`ProcessInfoSleepAssertion`（internal） |
| `Sources/VDPipeline/Guards.swift` | `PauseReason`（public） |
| `Sources/VDPipeline/PauseBook.swift` | `PauseBook`（internal。ガードの状態とログ） |
| `Sources/VDPipeline/Recovery.swift` | `Recovery`（internal。PT-21 の許可場所） |
| `Sources/VDPipeline/Recovery+VaultTmp.swift` | Vault の tmp の削除（**空。T-29 が書く**） |
| `Sources/VDPipeline/InboxMaintenance.swift` | `InboxMaintenance`（internal） |
| `Sources/VDPipeline/Requeue.swift` | `Requeue`（internal） |
| `Sources/VDPipeline/InProcessRetry.swift` | `InProcessRetry`（internal） |
| `Sources/VDPipeline/PartSteps.swift` | `PartSteps`・`PartStepResult`（internal）・skip / fail / 再オープンの呼び出し |
| `Sources/VDPipeline/PartSteps+Normalize.swift` | `ensureNormalized` |
| `Sources/VDPipeline/PartSteps+Transcribe.swift` | `ensureTranscribed`・`renormalizeOrFail` |
| `Sources/VDPipeline/PartSteps+RawNote.swift` | `ensureRawNote`（**偽を返すだけ。T-29 が書く**） |
| `Sources/VDPipeline/SessionSteps.swift` | `SessionSteps`・`SessionStepResult` の骨組み（**本体は空。T-22 が書く**） |
| `Sources/VDPipeline/FileProbe.swift` | `FileProbe`（internal。「通常ファイルで size > 0」） |
| `Sources/VDPipeline/ErrorText.swift` | `ErrorText`（internal。`"<型名>: <説明>"`）・`DurationSeconds`（internal） |
| `Tests/TestSupport/FakeIngest.swift` | `FakeIngest`（actor。`IngestPort` の偽物） |
| `Tests/VDPipelineTests/PipelineFixtures.swift` | テストの世界の組み立て（後続チケットが足す） |
| `Tests/VDPipelineTests/ConfigStoreTests.swift` ほか 11 本 | §6 |
| `Tests/PolicyTests/ConfigEffectPending.swift`（変更） | 4 キーを消す（§6.13） |

## 4. 仕様

共通: `p(url)` は `url.path(percentEncoded: false)`。`<HOME>` 相対のパスは `layout.relativePath(of:)` で作り、`layout.url(relative:)` で戻す（文字列で組み立てない。PT-06）。
ログのキーは `LogKey`、値は `LogValue`。`elapsed_s` は `PyRound.round(秒, digits: 1)` の `.double`。

### 4.1 `ErrorText.swift` / `FileProbe.swift`（internal）

```swift
// 例外を error_message とログ用の 1 行にする（PLAN §8.3「<型名>: <説明>」）。
enum ErrorText {
    static func describe(_ error: any Error) -> String { "\(type(of: error)): \(error)" }
}

enum DurationSeconds {
    /// Duration を秒の Double に（`Double(c.seconds) + Double(c.attoseconds) / 1e18`）。
    static func of(_ d: Duration) -> Double
}
```

```swift
// 「通常ファイルで size > 0」（PLAN §8.3 手順 1・§8.4 手順 2。voicedock _usable_source）。symlink は辿る。
import Darwin
enum FileProbe {
    /// `stat(p(url))` が成功し、`S_ISREG` で `st_size > 0`。
    static func isNonEmptyRegularFile(_ url: URL) -> Bool
    /// `stat` が成功し `S_ISREG`、かつ `access(p(url), X_OK) == 0`（T-22 の llama-server のガードが使う）。
    static func isExecutableFile(_ url: URL) -> Bool
}
```

### 4.2 `ConfigStore.swift`（PLAN §6.1）

```swift
// 設定の読み込み・検証・書き込みの唯一の窓口（PLAN §6.1）。GUI と有効化フローの変更もここだけが書く。
import Foundation
import VDContract
import VDCore

public actor ConfigStore {
    /// 00-api-map §11 の `init(layout:catalog:log:observeReaperConf:)` はこの 4 つ。
    /// `defaultTimeZone:` は**既定値つきのテストの口**（本番の Bootstrap は渡さない。T-30 §4.2 の 7）。
    public init(layout: HomeLayout, catalog: ModelCatalog, log: AppLog,
                observeReaperConf: @escaping @Sendable () async -> ReaperConfObservation,
                defaultTimeZone: @escaping @Sendable () -> String = { TimeZone.current.identifier })
    /// 読み込み（初回起動と「設定を読み直す」）。無ければ既定を書く。結果を current / violations に反映する。
    public func load() async -> ConfigLoadResult
    /// 検証を通った設定。設定エラー中は nil。
    public func current() -> AppConfig?
    public func violations() -> [ConfigViolation]
    /// この起動で config.json を新しく書いたか（初回起動。パネルを自動で開く。PLAN §8.12）。
    public func didCreateDefaults() -> Bool
    /// GUI と有効化フローの変更。**書く前に**変更後の値と reaper.conf の観測で検証し、違反なら書かない。
    /// reaperConfObservation が nil なら今の値（observeReaperConf()）で検証する。
    public func update(_ mutate: @Sendable (inout AppConfig) -> Void,
                       reaperConfObservation: ReaperConfObservation? = nil) async -> Result<AppConfig, [ConfigViolation]>
    /// ロック 1 の食い違い（CV-30）の修復口。本体は T-40（DeletionEnabler.reconcileLock1）。
    /// reconcile は reaper.conf を無効側（DELETE_SOURCE_AUDIO=false）に揃え、揃えたら true を返す。
    public func setLock1Reconciler(_ reconcile: @escaping @Sendable () async -> Bool)

    static let fileKeyPath = "<file>"
}
```

- **PT-11**: このファイルに識別子 `reaperConf` を書かない（引数ラベル・仮引数名・ローカル変数名も）。reaper.conf は注入された `observeReaperConf` で読み、T-09 の `ConfigLoader.load` / `ConfigValidator.validate` も `reaperConfObservation:` のラベルで呼ぶ（本番は T-36 の `LockEvaluator.observeReaperConf()`。T-36 より前の Bootstrap は `{ .missing }` を渡す。`observeReaperConf` / `reaperConfObservation` は別の識別子なので PT-11 に当たらない）
- 状態: `private var config: AppConfig?`、`private var lastViolations: [ConfigViolation] = []`、`private var created = false`、`private var reconciler: (@Sendable () async -> Bool)?`

**`load()` の手順**:
1. `url = layout.configFile`。`lstat(p(url))` が `ENOENT` なら（**無いときだけ**。symlink が壊れていても「在る」）:
   `d = AppConfig.defaults(timeZone: defaultTimeZone())` → `AtomicFile.write(ConfigLoader.encode(d), to: url, permissions: 0o644)`。
   失敗 → `violation("既定の設定を書けません: " + ErrorText.describe(e))` で手順 6 へ。成功 → `created = true`
2. `result = read()`（下記）
3. `result` が `.invalid(v)` で `v` に `rule == "CV-30"` が在り、`reconciler` が在るとき（1 回だけ）:
   1. `await reconciler()` が偽 → 手順 6（設定エラー）
   2. `data` を読み直し `JSONDecoder().decode(AppConfig.self, from: data)`。失敗 → 手順 6
   3. `c.cleanup.deleteSourceAudio = false`、`c.cleanup.deleteSkippedSource = false`、`c.device.mountMode = "ro"` → `AtomicFile.write(ConfigLoader.encode(c), to: url, permissions: 0o644)`。失敗 → 手順 6
   4. `log.warning(.configWarning, [(.rule, "CV-30"), (.message, "reaper.conf と config.json の削除の設定を無効側に揃えました")])`
   5. `result = read()`（2 回目は修復しない）
4. `.valid(c)` → `config = c`、`lastViolations = []`
5. `.invalid(v)` → `config = nil`、`lastViolations = v`
6. 設定エラーのとき、違反ごとに `log.error(.configInvalid, [(.rule, v.rule), (.key, v.keyPath), (.message, v.message)])`
7. `result` を返す

`read()`: `data = try Data(contentsOf: url)`。失敗 → `.invalid([violation("読めません: " + ErrorText.describe(e))])`。
成功 → `ConfigLoader.load(data: data, catalog: catalog, reaperConfObservation: await observeReaperConf())`（T-09 §5。ラベルに `reaperConf` の語を使わない。PT-11）。

`violation(_ message:)` = `ConfigViolation(rule: "CV-39", code: .configInvalidValue, keyPath: ConfigStore.fileKeyPath, message: message)`。

**`update(_:reaperConfObservation:)` の手順**:
1. `guard var c = config else { return .failure(lastViolations.isEmpty ? [violation("設定が読み込まれていません")] : lastViolations) }`
2. `mutate(&c)`
3. `obs = reaperConfObservation ?? await observeReaperConf()`、`v = ConfigValidator.validate(c, catalog: catalog, reaperConfObservation: obs)`。空でなければ `.failure(v)`（**書かない**。`config` も変えない）
4. `AtomicFile.write(ConfigLoader.encode(c), to: layout.configFile, permissions: 0o644)`。失敗 → `.failure([violation("書けません: " + ErrorText.describe(e))])`
5. `config = c`、`.success(c)`

- actor の再入: `load()` が `reconciler()` を待つ間に DeletionEnabler が `update` を呼んでも、設定エラー中は手順 1 で失敗するだけで壊れない（T-40 の reconcile は reaper.conf だけを書き、config.json はここで直す）

### 4.3 `IngestPort.swift` / `LicenseGate.swift`

```swift
// Worker が取り込み側に求めるもの（テストで FakeIngest に差し替える）。本番は IngestService（T-15）。
import VDDevice

public protocol IngestPort: Sendable {
    func latestSnapshot() async -> DeviceSnapshot?
    func state() async -> IngestState
    func updates() async -> AsyncStream<Void>
    func scanNow() async -> UInt64?
}
extension IngestService: IngestPort {}
```

```swift
// 課金の差し込み口（PLAN §8.14）。v1 は常に許可。認証サーバと通信しない。
public protocol LicenseGate: Sendable { func allowsProcessing() -> Bool }
public struct AlwaysAllowLicenseGate: LicenseGate {
    public init() {}
    public func allowsProcessing() -> Bool { true }
}
```

### 4.4 `WorkerDependencies.swift`

```swift
// Worker と工程の依存（本番の実装は VoiceDockApp/Bootstrap だけが組み立てる）。後続チケットはフィールドを足すだけ。
import VDContract
import VDCore
import VDProcess
import VDStore

public struct WorkerDependencies: Sendable {
    public let layout: HomeLayout
    public let paths: AppPaths
    public let store: Store
    public let config: ConfigStore
    public let ingest: any IngestPort
    public let runner: any ProcessRunning
    public let catalog: ModelCatalog
    public let license: any LicenseGate
    public let clock: any AppClock
    public let sleeper: any Sleeper
    public let log: AppLog
    public init(layout: HomeLayout, paths: AppPaths, store: Store, config: ConfigStore, ingest: any IngestPort,
                runner: any ProcessRunning, catalog: ModelCatalog, license: any LicenseGate,
                clock: any AppClock, sleeper: any Sleeper, log: AppLog)
}
```

- 足す予定（参考。このチケットでは書かない）: T-22 が `llama: any LLMServerControl`・`chatTransportFactory`・`physicalMemoryBytes`・`verificationCache`、次に T-33 が `importedKeys: ImportedKeysService`、最後に T-36 が `locks`・`volumeOpener`（`reaper` は持たない。`locks.reaper` を使う）。**init の引数は宣言の順**、足すフィールドは末尾に足す
- **最終の並びは 00-api-map §11 の `WorkerDependencies` の行が正**（末尾に足す順: 本チケットの並び → T-33 の `importedKeys` → T-36 の `locks` と `volumeOpener`）
- **タイムゾーンは持たない**: 分組・「今日」・表示の時刻は tick ごとに `config.timeZone`（CV-32 で解決できることが保証済み）から作る（§4.9 `Worker.zone(for:)`）

### 4.5 `WorkerStatus.swift`

```swift
public enum RequeueReason: String, Sendable, Equatable { case startup, connect, manual }

/// パネルの 1 行の状態に使う（PLAN §8.12「文字起こし中 07:12 の録音」「要約中 2026-08-29」）。
public enum WorkerActivity: Equatable, Sendable {
    case idle
    case normalizing(partkey: String, startedAt: String)
    case transcribing(partkey: String, startedAt: String)
    case writingRawNote(sessionKey: String)
    case merging(sessionKey: String)
    case analyzing(sessionKey: String, dayDate: String)
    case writingDailyNote(sessionKey: String, dayDate: String)
}

public struct WorkerStatus: Equatable, Sendable {
    public let activity: WorkerActivity
    public let paused: [PauseReason]        // PauseReason.allCases の順
    public init(activity: WorkerActivity, paused: [PauseReason])
}
```

### 4.6 `Guards.swift` と `PauseBook.swift`

```swift
// ガード（遷移せずに待つ。失敗ではない。PLAN §5.4）の理由。rawValue はログの reason 語（付録 A.4）。
public enum PauseReason: String, Sendable, CaseIterable, Equatable {
    case diskSpaceLow = "disk_space_low", whisperMissing = "whisper_missing", modelMissing = "model_missing",
         vadModelMissing = "vad_model_missing", vaultNotConfigured = "vault_not_configured",
         vaultUnavailable = "vault_unavailable", llmNotSelected = "llm_not_selected",
         llmModelMissing = "llm_model_missing", llmInsufficientMemory = "llm_insufficient_memory",
         llamaServerMissing = "llama_server_missing", license
}
```

```swift
// ガードに入った・出たときだけログを出す（毎 tick 出さない。PLAN §5.4）。
import Synchronization
import VDCore

final class PauseBook: Sendable {
    init(log: AppLog)
    /// ガードに当たった。前の tick から続いておらず、この tick でもまだ当たっていなければログを出す。
    func trip(_ reason: PauseReason, recordingKey: String? = nil, detail: String? = nil)
    /// tick を最後まで回したときに呼ぶ。前の tick に当たり、この tick で当たらなかった理由に pipeline_resumed を出す。
    func finishTick()
    /// previous ∪ current を PauseReason.allCases の順で。
    var paused: [PauseReason] { get }
}
```

- 状態 `Mutex<State>`、`struct State { var previous: Set<PauseReason> = []; var current: Set<PauseReason> = [] }`
- `trip`: ロックの中で `entering = !previous.contains(r) && !current.contains(r)`、`current.insert(r)`。ロックの外で `entering` なら:
  - `r == .diskSpaceLow` → `log.warning(.diskSpaceLow, [(.recordingKey, .of(recordingKey)), (.reason, .of(detail))])`（`pipeline_paused` の代わり。PLAN §5.4）
  - それ以外 → `log.warning(.pipelinePaused, [(.reason, .string(r.rawValue))])`
- `finishTick`: ロックの中で `resumed = previous.subtracting(current)`、`previous = current`、`current = []`。ロックの外で `PauseReason.allCases` の順に、`resumed` に在るものごとに `log.info(.pipelineResumed, [(.reason, .string(r.rawValue))])`
- tick を途中でやめた（停止要求・設定エラー）ときは `finishTick` を呼ばない（状態を保つ）
- **意味**: ある理由の「停止中」は「直前に最後まで回った tick でその理由のガードに当たった」。仕事が無くなれば（例: 待っていた Part が無くなる）次の tick の終わりで解除される

### 4.7 `StopFlag.swift` / `ActivityBoard.swift` / `TickStage.swift` / `TickContext.swift`（internal）

```swift
import Synchronization
/// 停止要求（ハンドラはフラグを立てるだけ。CONC-11）。
final class StopFlag: Sendable {
    init()
    func set()
    var isSet: Bool { get }
}
```

```swift
import Foundation
import Synchronization

/// スリープの抑止（PLAN §8.15）。begin / end は何度呼んでもよい（既に同じ状態なら何もしない）。
protocol SleepAssertion: Sendable { func begin(); func end() }

final class ProcessInfoSleepAssertion: SleepAssertion {
    static let reason = "VoiceDock が録音を処理しています"
    init()
    /// トークンが無ければ ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .suddenTerminationDisabled], reason: Self.reason) を保持する。
    func begin()
    /// トークンが在れば ProcessInfo.processInfo.endActivity(token) して nil に。
    func end()
}

/// 今の工程（status() に出す）。.idle 以外になったら begin、.idle になったら end。
final class ActivityBoard: Sendable {
    init(assertion: any SleepAssertion)
    func set(_ activity: WorkerActivity)
    var current: WorkerActivity { get }
}
```
- `ProcessInfoSleepAssertion` のトークンは `Mutex<(any NSObjectProtocol)?>` で持つ（`@unchecked Sendable` を使わない）

```swift
/// tick の段（PLAN §5.4 の順。この宣言順 = 実行順 = SPEC の「Worker の tick の順」）。
enum TickStage: String, CaseIterable, Sendable {
    case manualRequeue, groupNewParts, requeueRecopied, closeIdleSessions, processPendingParts,
         refreshVaultIndex, processReadySessions, collectDeleteResults, expireDeleteRequests,
         evaluateDeletions, settleSkippedDeletions, runReaperIfNeeded, pendingJobs, requeueOnConnect
    /// snapshot が新鮮なときだけ行う段（PLAN §5.4）。
    static let requiresFreshSnapshot: Set<TickStage> = [.evaluateDeletions, .settleSkippedDeletions, .runReaperIfNeeded]
}
```

```swift
/// 1 tick の間に変わらないもの。工程（PartSteps / SessionSteps）はこれを受けて作る（voicedock の「Pipeline は 1 周に 1 個」）。
struct TickContext: Sendable {
    let deps: WorkerDependencies
    let config: AppConfig
    let zone: ZonedTime
    let snapshot: DeviceSnapshot?     // tick の先頭で取ったもの（起動直後は nil）
    let pauses: PauseBook
    let activity: ActivityBoard
    let stop: StopFlag
    // T-29 が var vaultIndex: VaultIndex? を足す

    /// DB などの予期しない例外を常駐を止めずに記録する（1 件の失敗で残りを止めない。DEL-14）。
    /// `log.warning(.configWarning, [(.rule, .string(rule)), (.message, .string(ErrorText.describe(error)))])`
    func warnStore(_ error: any Error, rule: String = "store")
}
```
- 付録 A.4 に DB の例外の専用イベントが無いので `config_warning rule=store` を使う（§11 の提案 11）

### 4.8 `Worker.swift`

```swift
// 状態機械を 1 本の直列ループで回す（PLAN §5.4）。whisper と LLM を同時に走らせない（LLM-15）。
import Foundation
import VDContract
import VDCore
import VDDevice
import VDStore

public actor Worker {
    public static let pollSeconds = 30

    public init(deps: WorkerDependencies)
    /// テスト用（@testable）。sleep の抑止と、段の実行の記録を差し替える。
    init(deps: WorkerDependencies, assertion: any SleepAssertion, onStage: (@Sendable (TickStage) -> Void)?)

    public func start() async
    public func tick() async
    public func run() async
    public func requestStop()
    public func requeue(_ reason: RequeueReason) async
    public func status() -> WorkerStatus

    static func zone(for config: AppConfig) -> ZonedTime
}
```

状態（actor の中）:
```swift
let deps: WorkerDependencies
let pauses: PauseBook
let board: ActivityBoard
let stop = StopFlag()
let onStage: (@Sendable (TickStage) -> Void)?
var started = false
var pendingStart = false
var lastSeenConnectEpoch: UInt64 = 0
var pendingRequeues: [RequeueReason] = []
var wakeContinuation: AsyncStream<Void>.Continuation?
var stoppingLogged = false
// T-29 が vaultIndex を、T-32 がジョブの列を足す
```

`init(deps:)` = `init(deps: deps, assertion: ProcessInfoSleepAssertion(), onStage: nil)`。`pauses = PauseBook(log: deps.log)`、`board = ActivityBoard(assertion: assertion)`。

`zone(for:)`: `ZonedTime(timeZone: TimeZone(identifier: config.timeZone) ?? TimeZone.current)`（CV-32 があるので後者には来ない）。

**`start()`**（PLAN §5.4 / §5.3。アプリの起動手順は「DB を開く → Worker.start() → IngestService.start()」）:
1. `started` なら何もしない。`started = true`
2. `blocked = await deps.config.current() == nil || await deps.ingest.state() == .coexistenceBlocked`。真なら `pendingStart = true` で終わり（解除された最初の tick の先頭で行う）
3. `await performStart(delayed: false)`

**`performStart(delayed:)`**（internal）:
1. `guard let config = await deps.config.current() else { pendingStart = true; return }`
2. `log.info(.serviceStarted, [(.version, .string(AppVersion.string)), (.schema, .of((try? deps.store.appliedMigrations)?.last))])`
3. `zone = Worker.zone(for: config)`、`ctx = makeContext(config, zone, snapshot: nil)`
4. 復旧: `try Recovery(store: deps.store, layout: deps.layout, log: deps.log, config: config, zone: zone).run()`。投げたら `warnStore(e, rule: "recovery")`
5. `try SessionSteps(ctx: ctx).closeIdleSessions()`（= PLAN の closeStaleOpenSessions。日付が過去の OPEN は `stale_day` で閉じる。本体は T-22）。投げたら `warnStore(e)`
6. `delayed == false` のときだけ inbox の孤児の削除:
   `n = try await BlockingIO.run { try InboxMaintenance(store: s, layout: l, log: g).removeOrphans() }`。`n > 0` なら `log.info(.inboxOrphansRemoved, [(.count, .of(n))])`。投げたら `warnStore(e)`
   - **遅れて行う start（pendingStart）では行わない**: そのときは IngestService が既に動いていて、コピー中の `.partial` と登録前の `_orig.wav` を孤児と見分けられない（次の起動で消える）
7. `requeueFailed(.startup, ctx)`（§4.12）

`warnStore(_ e: any Error, rule: String = "store")`（Worker の internal）: `TickContext.warnStore` と同じ 1 行を出す（DB の例外で常駐を止めない。1 件の失敗で残りを止めない。DEL-14）。

**`tick()`**（PLAN §5.4。この順で。各段の前に `stop.isSet` なら `return`）:
```text
guard let config = await deps.config.current() else { board.set(.idle); return }       // 設定エラー（§6.1）
if await deps.ingest.state() == .coexistenceBlocked { board.set(.idle); return }        // 共存ガード（§8.1）
if pendingStart { pendingStart = false; await performStart(delayed: true) }
guard deps.license.allowsProcessing() else { pauses.trip(.license); pauses.finishTick(); return }   // §8.14
zone = Worker.zone(for: config); snapshot = await deps.ingest.latestSnapshot()
ctx = makeContext(config, zone, snapshot)
if !pendingRequeues.isEmpty: run(.manualRequeue)
run(.groupNewParts); run(.requeueRecopied); run(.closeIdleSessions); run(.processPendingParts)
run(.refreshVaultIndex); run(.processReadySessions); run(.collectDeleteResults); run(.expireDeleteRequests)
if let s = snapshot, s.isFresh(now: deps.clock.now(), maxAgeSeconds: config.device.snapshotMaxAgeSeconds):
    run(.evaluateDeletions); run(.settleSkippedDeletions); run(.runReaperIfNeeded)
run(.pendingJobs); run(.requeueOnConnect)
pauses.finishTick(); board.set(.idle)
```
- `run(stage)`: `if stop.isSet { return 中断 }` → `onStage?(stage)` → 下の対応表の関数を `await`
- 新鮮さの `now` は**その時点の** `deps.clock.now()`（tick の先頭で固定しない。TIME-04）
- 停止要求で中断したら `finishTick()` も `board.set(.idle)` も呼ばない（次回起動の復旧が戻す）

| 段 | 関数（`Worker+*.swift`） | 中身を書くチケット |
|---|---|---|
| manualRequeue | `stageManualRequeue(ctx)`: `reasons = pendingRequeues; pendingRequeues = []`、各 reason で `requeueFailed(reason, ctx)` | T-18 |
| groupNewParts | `stageGroupNewParts(ctx)`: `try SessionSteps(ctx: ctx).groupNewParts()`、投げたら `warnStore` | T-18（SessionSteps の本体は T-22） |
| requeueRecopied | `stageRequeueRecopied(ctx)`: `Requeue(ctx:).requeueRecopied()`、投げたら `warnStore` | T-18 |
| closeIdleSessions | `stageCloseIdleSessions(ctx)`: `try SessionSteps(ctx: ctx).closeIdleSessions()` | T-18（本体は T-22） |
| processPendingParts | `stageProcessPendingParts(ctx)`（§4.14） | T-18 |
| refreshVaultIndex | `stageRefreshVaultIndex(ctx)` | **T-29** |
| processReadySessions | `stageProcessReadySessions(ctx)` | **T-22** |
| collectDeleteResults / expireDeleteRequests | `stageCollectDeleteResults(ctx)` / `stageExpireDeleteRequests(ctx)` | **T-38** |
| evaluateDeletions / runReaperIfNeeded | `stageEvaluateDeletions(ctx)` / `stageRunReaperIfNeeded(ctx)` | **T-38** |
| settleSkippedDeletions | `stageSettleSkippedDeletions(ctx)` | **T-39** |
| pendingJobs | `stagePendingJobs(ctx)` | **T-32**（`WorkerJob`・`enqueue` も T-32 が足す） |
| requeueOnConnect | `stageRequeueOnConnect(ctx)`: `if let s = ctx.snapshot, s.connectEpoch > lastSeenConnectEpoch { requeueFailed(.connect, ctx); lastSeenConnectEpoch = s.connectEpoch }` | T-18 |

- 空の段は `func stageX(_ ctx: TickContext) async {}` とし、1 行の `// T-nn が中身を書く（PLAN §x.y）。` を付ける。**後続チケットはこのファイルの本体だけを書き換える**（段の追加・並べ替えは TickStage と SPEC を同じ PR で直す）

**`run()`**（待ちは「IngestService の通知」「パネルの要求」「30 秒」の早い方。PLAN §5.4 / §8.15）:
```swift
await start()
let (wake, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
wakeContinuation = continuation
let updates = await deps.ingest.updates()
let pump = Task { for await _ in updates { continuation.yield(()) } }
let sleeper = deps.sleeper
let timer = Task {
    while !Task.isCancelled {
        do { try await sleeper.sleep(seconds: Worker.pollSeconds) } catch { return }
        continuation.yield(())
    }
}
var waiting = wake.makeAsyncIterator()
while !stop.isSet {
    await tick()
    if stop.isSet { break }
    if await waiting.next() == nil { break }
}
pump.cancel(); timer.cancel(); continuation.finish(); wakeContinuation = nil
```
- 周期は「tick の終わりから 30 秒」ではなく「30 秒ごとの起こし」（tick 中に溜まった起こしは 1 つにまとまる。アイドル時の CPU を 0 に近く保つ）

**`requestStop()`**: `stop.set()` → `wakeContinuation?.yield(())` → `stoppingLogged` が偽なら `log.info(.serviceStopping, [(.version, .string(AppVersion.string))])` して真に。
実行中の子プロセスは止めない（アプリの終了処理が `ProcessRunner.terminateAll` で止める。PLAN §8.15）。

**`requeue(_:)`**: `pendingRequeues.append(reason)` → `wakeContinuation?.yield(())`（実行は次の tick の先頭の manualRequeue。tick の途中で行を動かさない）。

**`status()`**: `WorkerStatus(activity: board.current, paused: pauses.paused)`。

`makeContext(config, zone, snapshot)` = `TickContext(deps: deps, config: config, zone: zone, snapshot: snapshot, pauses: pauses, activity: board, stop: stop)`。

### 4.9 `Recovery.swift`（PLAN §5.3。PT-21: `.recovery` をここに書く）

```swift
// 起動時の復旧（PLAN §5.3。voicedock pipeline.py:1669-1728 と同じ順）。進行中の状態を 1 つ手前に戻す。
struct Recovery {
    let store: Store
    let layout: HomeLayout
    let log: AppLog
    let config: AppConfig
    let zone: ZonedTime
    /// 戻した行の数。DB の例外は投げる（TransitionConflict は数えずに次へ）。
    func run() throws -> Int
}
```

手順:
1. `moved = 0`
2. `for edge in TransitionTable.partRecovery`（この順）: `for row in try store.recordings(status: edge.from)`（started_at, partkey 順）:
   `discardPartial(part: row, state: edge.from)` → `try store.recordPartTransition(partkey: row.partkey, from: edge.from, to: edge.to, kind: .recovery)`
   （`TransitionConflict` は捕まえて次へ）→ `moved += 1`
3. `for edge in TransitionTable.sessionRecovery`: `for row in try store.sessions(status: edge.from)`（session_key 順）: `discardPartial(session: row, state: edge.from)` → `recordSessionTransition(… kind: .recovery)` → `moved += 1`
4. `moved > 0` なら `log.info(.recoveryCompleted, [(.rolledBack, .of(moved))])`。`moved` を返す

`discardPartial(part:state:)`（`slug = KeySlug.of(row.partkey)`）:
| state | 消すもの（`SafeUnlink.remove(_, under:, layout:)`、`missingOK: true`） |
|---|---|
| NORMALIZING | `layout.normalizedAudio(slug:)`・`layout.normalizedAudioTmp(slug:)`（`.staging`）。**partkey から算出**（列は見ない） |
| TRANSCRIBING | `layout.transcript(slug:)`（`.transcripts`）・`layout.whisperJSON(slug:)`（`.staging`） |
| RAW_WRITING | `discardVaultTmp(part: row)`（`Recovery+VaultTmp.swift`。**T-18 では空。T-29 が書く**） |
| SOURCE_DELETING | 何もしない（`delete_request_id` を外さない。§8.9.6 が回収する） |

`discardPartial(session:state:)`: WRITING → `discardVaultTmp(session: row)`（T-29）。ほかは何もしない。

削除の失敗は `log.warning(.configWarning, [(.rule, "recovery"), (.message, .string("\(layout.relativePath(of: url) ?? p(url)) を消せません: \(ErrorText.describe(e))"))])` を出して続ける。

`Recovery+VaultTmp.swift`（T-18 の中身）:
```swift
// 復旧時の Vault の一時ファイルの削除（PLAN §5.3。本体は T-29）。
extension Recovery {
    func discardVaultTmp(part row: RecordingRow) {}      // T-29 が中身を書く
    func discardVaultTmp(session row: SessionRow) {}     // T-29 が中身を書く
}
```

### 4.10 `InboxMaintenance.swift`

```swift
// inbox の孤児の削除（起動時）と取り残しの集計（DR-15・状態の詳細）。PLAN §5.3・§8.12。
struct InboxMaintenance {
    let store: Store
    let layout: HomeLayout
    let log: AppLog
    /// DB に行の無い _orig.wav と、すべての .partial を消す。消せた数を返す。
    func removeOrphans() throws -> Int
    /// PartStates.inboxLeftover の Part の _orig.wav の件数とバイト数（処理待ちは数えない）。
    func leftovers() throws -> (count: Int, bytes: Int64)
}
```

走査（`walk()`、両方で共通。同期。呼び手が `BlockingIO.run` で包む）:
1. `layout.inbox` の直下の各名前 `d`（`contentsOfDirectory`。読めなければ空の結果）。`lstat` でディレクトリでないもの・symlink は飛ばす
2. `FileManager.default.enumerator(at: <inbox>/d, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [])`（symlink のディレクトリには入らない）で各 URL:
   - `isSymbolicLink == true` か `isRegularFile != true` なら飛ばす
   - `name` のスカラー列が `.` で始まり `.partial` で終わる → `partials` に足す
   - `RecordingName.parseFile(name)?.isOrig == true` → `relpath = RelPath.join(<d からの相対の要素>)`（`url.standardizedFileURL.pathComponents` から `<inbox>/d` の要素数を落としたもの）→ `pk = try? PartKey.make(deviceID: d, relpath: relpath)`（nil なら飛ばす）→ `origs[pk] = (url, size)`
   - それ以外は触らない

`removeOrphans()`:
1. `known = try store.knownPartkeys(Array(origs.keys))`
2. 対象 = `partials` ＋ `origs` のうち `known` に無いもの。`p(url)` のスカラー値の昇順
3. 各対象に `SafeUnlink.remove(url, under: .inbox, layout: layout, missingOK: true)`。成功を数える。失敗は `log.warning(.configWarning, [(.rule, "inbox"), (.message, "<HOME 相対> を消せません: <describe>")])`
4. 数を返す（ログ `inbox_orphans_removed` は呼び手の Worker が出す）

`leftovers()`: `keys = Set(try store.partkeys(statuses: PartStates.inboxLeftover))`、`origs` のうち `keys` に在るものの件数と size の合計。

### 4.11 `InProcessRetry.swift`（PLAN §5.4。voicedock worker.py:240-262 / pipeline.py:1750-1796）

```swift
struct InProcessRetry {
    let ctx: TickContext
    /// step を 1 回実行 → 行が FAILED で工程内リトライの対象なら backoff を待って戻し、もう一度。
    func run(entity: EntityType, key: String, _ step: () async -> Void) async
    /// 待つ秒。対象でなければ nil。
    func delay(entity: EntityType, key: String) -> Int?
}
```

`run`:
```text
while true:
  await step()
  guard let d = delay(entity, key) else return
  if ctx.stop.isSet return
  do { try await ctx.deps.sleeper.sleep(seconds: d) } catch { return }
  if ctx.stop.isSet return
  guard (try? Requeue(ctx: ctx).resumeFailed(entity: entity, key: key, resetRetry: false, detail: "retry")) == true else return
```

`delay`（どれかで nil。DB の例外も nil）:
- Part: `row = store.recording(key)`、`row.status == .failed`、`code = row.errorCode`、`code.retryPolicy == .attempts`、`from = store.failedFromPart(key)` が `PartStates.retryableFromFailed` に在る
- Session: 同じく `store.session(key)`・`SessionStates.retryableFromFailed`・`failedFromSession`
- `RetryDelay.inProcess(retryCount: row.retryCount, maxAttempts: config.retry.maxAttempts, backoff: config.retry.backoffSeconds)`
- 既定（3 回・`[3, 10, 30]`）で「失敗 → 3 秒 → 失敗 → 10 秒 → 失敗 → 終了」。**戻すときは retry_count を据え置く**（detail `retry`）

### 4.12 `Requeue.swift`（PLAN §5.4 の 4 つの契機）

```swift
struct Requeue {
    let ctx: TickContext
    /// FAILED → 戻り先（events の直近の FAILED への遷移元が *RetryableFromFailed に在るときだけ）。TransitionConflict は false。
    func resumeFailed(entity: EntityType, key: String, resetRetry: Bool, detail: String) throws -> Bool
    /// 契機 1〜3（起動・接続・再試行ボタン）。戻した数。
    func requeueFailed(_ reason: RequeueReason) throws -> Int
    /// 契機 4（再コピーの完了）。戻した数。
    func requeueRecopied() throws -> Int
}
```

- `resumeFailed`: Part は `guard let to = try store.failedFromPart(key), PartStates.retryableFromFailed.contains(to) else { return false }` →
  `try store.recordPartTransition(partkey: key, from: .failed, to: to, detail: detail, resetRetry: resetRetry)`、`TransitionConflict` → false、成功 → true。Session も同じ（`failedFromSession`・`SessionStates.retryableFromFailed`・`recordSessionTransition`）
- `requeueFailed(_:)`: 時間・retry_count・RetryPolicy を見ない。上限なし（SM-05）
  1. `for pk in try store.failedRecordingKeys()`（updated_at, partkey 順）: `row = try store.recording(pk)`。`row.needsRecopy` なら飛ばす（**再コピーより先に戻すと、inbox が無いので SOURCE_MISSING の SKIPPED（終端）に落ちる**）。`resumeFailed(.recording, pk, resetRetry: true, detail: "requeue")` が真なら数える
  2. `for key in try store.failedSessionKeys()`: `resumeFailed(.session, key, resetRetry: true, detail: "requeue")`
  3. 1 件以上なら `log.info(.recoveryCompleted, [(.requeued, .of(n))])`
- `requeueRecopied()`: `for pk in try store.failedRecordingKeys()`: `row.errorCode` が `.sourceHashMismatch` か `.normalizedMissing` で `row.needsRecopy == false` のものだけ `resumeFailed(.recording, pk, resetRetry: true, detail: "recopied")`。1 件以上なら `recovery_completed requeued=<n>`
- Worker の `requeueFailed(_ reason:, _ ctx:)` は `try Requeue(ctx:).requeueFailed(reason)` を呼び、投げたら `warnStore`

### 4.13 `PartSteps.swift`（PLAN §5.5）

```swift
enum PartStepResult: Equatable, Sendable { case stopped, readyForSession }

struct PartSteps {
    let ctx: TickContext
    let sessions: SessionSteps
    init(ctx: TickContext)            // sessions = SessionSteps(ctx: ctx)

    func process(partkey: String) async -> PartStepResult
    func ensureNormalized(_ row: RecordingRow) async -> Bool
    func ensureTranscribed(_ row: RecordingRow) async -> Bool
    func ensureRawNote(_ row: RecordingRow) async -> Bool

    /// → SKIPPED（error_code・error_message）→ part_skipped → その Part の Session の再オープン。
    func skip(_ row: RecordingRow, from: PartStatus, code: ErrorCode, message: String) throws
    /// → FAILED → <event>（ERROR）→ その Part の Session の再オープン。
    func fail(_ row: RecordingRow, from: PartStatus, code: ErrorCode, message: String, event: LogEvent, reason: String? = nil) throws
    /// TransitionConflict は偽（何も書かずに次へ。PLAN §5.4）、ほかの例外は ctx.warnStore(e) を出して偽。
    func guarded(_ body: () async throws -> Bool) async -> Bool
}
```
- 共有の短縮: `store = ctx.deps.store`、`layout = ctx.deps.layout`、`clock = ctx.deps.clock`、`log = ctx.deps.log`、`cfg = ctx.config`（computed property）

`process(partkey:)`（voicedock pipeline.py:266-282）:
```text
guard let r0 = try? store.recording(partkey) ?? nil else .stopped
guard await ensureNormalized(r0) else .stopped
guard let r1 = reload(partkey), await ensureTranscribed(r1) else .stopped
guard let r2 = reload(partkey), await ensureRawNote(r2) else .stopped
return .readyForSession
```
（Raw の直後の削除評価の呼び出しは T-29 が足す。`reload` = `(try? store.recording(pk)) ?? nil`）

`skip`:
1. `try store.recordPartTransition(partkey: row.partkey, from: from, to: .skipped, errorCode: code, errorMessage: message)`
2. `log.info(.partSkipped, [(.recordingKey, .string(row.partkey)), (.reason, .string(code.skipReasonWord ?? code.rawValue))])`
3. `if let key = row.sessionKey { _ = sessions.reopenSession(key) }`

`fail`:
1. `try store.recordPartTransition(partkey: row.partkey, from: from, to: .failed, errorCode: code, errorMessage: message)`
2. `fields = [(.recordingKey, .string(row.partkey)), (.errorCode, .string(code.rawValue))]`、`reason` があれば `(.reason, .string(reason))` を足す → `log.error(event, fields)`
3. `if let key = row.sessionKey { _ = sessions.reopenSession(key) }`（本体は T-22。T-18 では常に偽）

`ensureRawNote`（`PartSteps+RawNote.swift`）: T-18 は `{ false }`（コメント `// T-29 が中身を書く（PLAN §8.6〜§8.8）。`）。

### 4.14 `stageProcessPendingParts`（`Worker+PartStages.swift`）

```text
keys = try store.nonTerminalPartkeys()          // 一覧を先に確定（started_at, partkey 順）。投げたら warnStore で終わり
steps = PartSteps(ctx: ctx); retry = InProcessRetry(ctx: ctx)
for key in keys:
   if stop.isSet: return
   await retry.run(entity: .recording, key: key) { _ = await steps.process(partkey: key) }
   ctx.activity.set(.idle)
```
- 停止の確認・活動の表示は `ctx` の `stop` / `activity` だけを使う（Worker の状態に触れない。テストが `ctx` を差し替えて直接呼べる）

### 4.15 `PartSteps+Normalize.swift`（PLAN §8.3「呼び手の手順」を逐語で）

`ensureNormalized(_ row:)`（`pk = row.partkey`、`slug = KeySlug.of(pk)`、`cfg = ctx.config`）:
0. `PartStates.normalizedOrBeyond.contains(row.status)` → `true`。`!PartStates.normalizable.contains(row.status)` → `false`（FAILED / SKIPPED は進めない）。以降は `guarded { … }` の中
1. `inbox = row.inboxPath.map { layout.url(relative: $0) }`。`inbox` が nil か `!FileProbe.isNonEmptyRegularFile(inbox)` なら:
   `row.needsRecopy` なら**何もせず** `false`（再コピーを待つ）。そうでなければ
   `try skip(row, from: row.status, code: .sourceMissing, message: "inbox に原本がありません: \(row.inboxPath ?? "")")` → `false`（遷移元は DISCOVERED か NORMALIZING）
2. 空き容量のガード: `space = (try? await BlockingIO.run { SpaceCheck(config: cfg.audio, layout: layout).check(durationSeconds: row.durationSeconds) }) ?? .insufficient("空き容量を確認できません")`。
   `.insufficient(msg)` → `ctx.pauses.trip(.diskSpaceLow, recordingKey: pk, detail: msg)` → **遷移せず** `false`（SM-18）
3. `row.status == .discovered` なら `try store.recordPartTransition(partkey: pk, from: .discovered, to: .normalizing)`（NORMALIZING から来たら記録しない。SM-08）
4. `ctx.activity.set(.normalizing(partkey: pk, startedAt: row.startedAt))`、`outputRel = layout.relativePath(of: layout.normalizedAudio(slug: slug)) ?? ""`、
   `claimed = try store.recording(normalizedPath: outputRel)?.partkey`、`t0 = clock.uptime()`
   ```swift
   let store = ctx.deps.store
   let outcome = await Normalizer(config: cfg.audio, layout: layout, clock: clock).normalize(NormalizeRequest(
       input: inbox, partkey: pk, durationSeconds: row.durationSeconds, sha256Helper: row.sha256Helper,
       claimedBy: claimed, duplicateOf: { sha in (try? store.recording(sha256: sha))??.partkey }))
   ```
5. `.duplicate(of: other, _)`: `try store.updateRecording(pk, [.duplicateOf(other)])` を**先に**書き、
   `try skip(row, from: .normalizing, code: .duplicateContent, message: "同じ内容の Part が既にあります: \(other)")` → `false`。**`sha256` は書かない**（部分 UNIQUE）
6. `.failure(f)`: `f.code == .sourceHashMismatch` なら**先に** `_ = try store.updateRecordingIfStatus(pk, status: .normalizing, [.needsRecopy(true)])`
   （PLAN は「同じトランザクションで」。Store に遷移と列を 1 トランザクションで書く API が無いので、**列を遷移より先に書く**。落ちても「NORMALIZING で needs_recopy = 1」になるだけで、
   「FAILED(SOURCE_HASH_MISMATCH) で needs_recopy = 0」（契機 4 が再コピー無しに戻し続ける）は起きない。§11 の提案 5）→
   `try fail(row, from: .normalizing, code: f.code, message: f.message, event: .normalizeFailed)` → `false`
7. `.success(sha, output, inBytes, outBytes, _)`:
   `try store.updateRecording(pk, [.sha256(sha), .normalizedPath(layout.relativePath(of: output)), .stagingDir(layout.relativePath(of: layout.stagingDirectory(slug: slug))), .errorCode(nil), .errorMessage(nil)])` →
   `try store.recordPartTransition(partkey: pk, from: .normalizing, to: .normalized)` →
   `log.info(.normalizeCompleted, [(.recordingKey, pk), (.inBytes, .of(inBytes)), (.outBytes, .of(outBytes)), (.elapsedS, .double(PyRound.round(DurationSeconds.of(clock.uptime() - t0), digits: 1)))])` →
   **その後で** `cfg.audio.retain == .normalized` なら `try? SafeUnlink.remove(inbox, under: .inbox, layout: layout)`（CONC-08。失敗は無視）→ `true`
   （`inboxRetain == raw_saved` の削除は T-29 の RAW_SAVED の直後）

### 4.16 `PartSteps+Transcribe.swift`（PLAN §8.4「呼び手の手順」を逐語で）

`ensureTranscribed(_ row:)`:
0. `PartStates.transcribedOrBeyond.contains(row.status)` → `true`。`!PartStates.transcribable.contains(row.status)` か `row.normalizedPath == nil` → `false`。以降 `guarded`
1. ガード: `transcriber = Transcriber(runner: deps.runner, paths: deps.paths, layout: layout, config: cfg.transcription, catalog: deps.catalog, clock: clock)`、
   `missing = transcriber.missingPrerequisites()`。空でなければ各 `m` について `if let r = PauseReason(rawValue: m.rawValue) { ctx.pauses.trip(r) }` → **遷移せず** `false`
2. `input = layout.url(relative: row.normalizedPath!)`（`guard let` で取り出す）。`!FileProbe.isNonEmptyRegularFile(input)` → `return try renormalizeOrFail(row)`（ASR-04 / SM-17）
3. `row.status == .normalized` なら `NORMALIZED→TRANSCRIBING`
4. `ctx.activity.set(.transcribing(partkey: pk, startedAt: row.startedAt))`
5. `outcome = await transcriber.transcribe(TranscribeRequest(partkey: pk, slug: slug, input: input, durationSeconds: row.durationSeconds, startedAt: row.startedAt))`
   （冪等（既存の transcript の再利用）とタイムアウトは Transcriber が行う）。`transcriptRel = layout.relativePath(of: layout.transcript(slug: slug))`
6. 結果の写し方:
   - `.prerequisiteMissing(m)`（ガードの後に欠けた）: `PauseReason(rawValue: m.rawValue)` を trip → `false`（**行に書かない**。TRANSCRIBING のまま。次の周回は TRANSCRIBING から入る）
   - `.noSpeech(_, message)`: `try store.updateRecording(pk, [.transcriptPath(transcriptRel)])` を**先に**書き、`try skip(row, from: .transcribing, code: .noSpeechDetected, message: message)` → `false`
   - `.failure(f)`: `try fail(row, from: .transcribing, code: f.code, message: f.message, event: .transcriptionFailed)` → `false`
   - `.transcribed(_, metrics)`: `try store.updateRecording(pk, [.transcriptPath(transcriptRel), .errorCode(nil), .errorMessage(nil)])` →
     `TRANSCRIBING→TRANSCRIBED` →
     `log.info(.transcriptionCompleted, [(.recordingKey, pk), (.elapsedS, .double(PyRound.round(metrics.elapsedSeconds, digits: 1))), (.chars, .of(metrics.chars)), (.rtf, .of(metrics.rtf)), (.speechRatio, .of(metrics.speechRatio))])` →
     `cfg.cleanup.deleteNormalizedAfterTranscribe` なら `SafeUnlink.remove(input, under: .staging, layout: layout)`、失敗は
     `log.warning(.diskSpaceLow, [(.recordingKey, pk), (.reason, "staging_unlink_failed")])` → `true`

`renormalizeOrFail(_ row:) throws -> Bool`（voicedock pipeline.py:1623-1652）:
1. `try store.recordPartTransition(partkey: pk, from: row.status, to: .normalizing)`（NORMALIZED か TRANSCRIBING から）
2. `row.inboxPath` が在り `FileProbe.isNonEmptyRegularFile(layout.url(relative:))` なら `false`（次の周回で変換し直す。ログ無し）
3. `_ = try store.updateRecordingIfStatus(pk, status: .normalizing, [.needsRecopy(true)])`（遷移より先。§4.15 手順 6 と同じ理由）
4. `try fail(row, from: .normalizing, code: .normalizedMissing, message: "16 kHz 音声も inbox の原本もありません（\(row.normalizedPath ?? "")）。デバイスから採り直す必要があります", event: .normalizeFailed, reason: "input")` → `false`

### 4.17 `SessionSteps.swift`（T-18 は骨組みだけ。T-22 がこのファイルの本体を書き換える）

```swift
// Session の工程（PLAN §5.6・§8.5）。T-18 は Worker と PartSteps が呼ぶ口だけを置く。本体は T-22。
enum SessionStepResult: Equatable, Sendable { case stopped, empty, analyzed, saved }

struct SessionSteps {
    let ctx: TickContext
    init(ctx: TickContext)
    func groupNewParts() throws {}                                           // T-22
    func closeIdleSessions() throws {}                                       // T-22
    /// 再オープン。行えたら true。TransitionConflict は false（PLAN §5.6）。
    func reopenSession(_ sessionKey: String) -> Bool { false }               // T-22
    func process(sessionKey: String) async -> SessionStepResult { .stopped } // T-22
}
```

### 4.18 `Tests/TestSupport/FakeIngest.swift`（00-api-map §15 に足す。作り手 T-18）

```swift
// IngestPort の偽物（Worker のテスト用）。走査もコピーもしない。
public actor FakeIngest: IngestPort {
    public init(snapshot: DeviceSnapshot? = nil, state: IngestState = .idle)
    public func setSnapshot(_ s: DeviceSnapshot?)
    public func setState(_ s: IngestState)
    public func sendUpdate()                         // 購読中の updates() に 1 つ流す
    public var scanNowCalls: Int { get }
    public func latestSnapshot() -> DeviceSnapshot?
    public func state() -> IngestState
    public func updates() -> AsyncStream<Void>       // bufferingNewest(1)
    public func scanNow() async -> UInt64?           // scanNowCalls += 1、snapshot?.generation を返す
    /// テスト用の snapshot（devices は deviceID → relpaths。readOnly false、freeBytes nil、mountPath "/tmp/vd-fake/<id>"）
    public static func snapshot(generation: UInt64 = 1, completedAt: Instant, connectEpoch: UInt64 = 0,
                                devices: [String: Set<String>] = [:]) -> DeviceSnapshot
}
```

## 5. ログ（このチケットが出すもの）

| イベント | レベル | フィールド（この順） | 出す場所 |
|---|---|---|---|
| `service_started` | INFO | `version`, `schema` | performStart |
| `service_stopping` | INFO | `version` | requestStop（1 回だけ） |
| `recovery_completed` | INFO | `rolled_back` / `requeued` | Recovery / Requeue |
| `inbox_orphans_removed` | INFO | `count` | performStart |
| `config_invalid` | ERROR | `rule`, `key`, `message` | ConfigStore.load |
| `config_warning` | WARNING | `rule`（`CV-30` / `recovery` / `inbox` / `store`）, `message` | ConfigStore・Recovery・InboxMaintenance・Worker |
| `part_skipped` | INFO | `recording_key`, `reason` | skip |
| `normalize_completed` | INFO | `recording_key`, `in_bytes`, `out_bytes`, `elapsed_s` | ensureNormalized |
| `normalize_failed` | ERROR | `recording_key`, `error_code`[, `reason=input`] | fail |
| `transcription_completed` | INFO | `recording_key`, `elapsed_s`, `chars`, `rtf`, `speech_ratio` | ensureTranscribed |
| `transcription_failed` | ERROR | `recording_key`, `error_code` | fail |
| `disk_space_low` | WARNING | `recording_key`, `reason` | PauseBook（入ったときだけ）・16 kHz の削除失敗 |
| `pipeline_paused` / `pipeline_resumed` | WARNING / INFO | `reason` | PauseBook |

## 6. テスト

共通: `import Testing`、`@testable import VDPipeline`、`import VDContract`、`import VDCore`、`import VDStore`、`import VDDevice`、`import TestSupport`。
時計は `FixedClock(epochMillis: 1_788_040_812_000)`（2026-08-30T07:00:12+09:00）、ゾーンは Asia/Tokyo、sleeper は `RecordingSleeper()`、ログは `CapturingLogSink`（レベル DEBUG）。

### 6.0 `PipelineFixtures.swift`（VDPipelineTests。後続チケットが足す）

```swift
struct PipelineWorld {
    let tmp: TempDirectory; let layout: HomeLayout; let paths: AppPaths; let store: Store
    let configStore: ConfigStore; let ingest: FakeIngest; let clock: FixedClock; let sleeper: RecordingSleeper
    let sink: CapturingLogSink; let log: AppLog; let assertion: RecordingSleepAssertion
    var deps: WorkerDependencies { get }
    /// config を設定して ConfigStore に書き、load する（検証を通らなければテストを落とす）。
    static func make(configure: (inout AppConfig) -> Void = { _ in }) async throws -> PipelineWorld
    /// 今の設定で TickContext を作る（pauses は新しい PauseBook、activity は assertion を使う ActivityBoard）。
    func context(snapshot: DeviceSnapshot? = nil, stop: StopFlag = StopFlag(),
                 assertion: (any SleepAssertion)? = nil) async throws -> TickContext
    func worker(onStage: (@Sendable (TickStage) -> Void)? = nil) -> Worker   // assertion は self.assertion
    /// FakeWhisper を helpers/whisper-cli に、TestCatalogs.minimal の whisper / vad のファイルを entry.bytes の 0 で置く。
    func installWhisper(utterances: [FakeWhisperUtterance] = FakeWhisper.defaultUtterances, exitCode: Int32 = 0) throws
    /// inbox に BWF（speech・pcm24）を書き、sha256Helper = その SHA-256 の行を登録する。
    func registerPart(relpath: String = PipelineFixtures.relpath, startedAt: String = PipelineFixtures.startedAt,
                      seconds: Double = 2.0) throws -> String   // partkey
}
enum PipelineFixtures {
    static let relpath = "TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"
    static let startedAt = "2026-08-29T07:12:04+09:00"
    static let partkey = "DJIMIC3/TX_MIC001_20260829_071201/TX01_MIC002_20260829_071204_orig.wav"
    /// 既定の設定からの変更: audio.freeSpaceMarginBytes = 0（CI の空き容量に依存させない）
    static func baseConfig() -> AppConfig
}
/// SleepAssertion の記録（begin / end の回数と今の状態。Mutex で守る）。onBegin は begin のたびに呼ぶ。
final class RecordingSleepAssertion: SleepAssertion {
    init(onBegin: (@Sendable () -> Void)? = nil)
    var begins: Int { get }; var ends: Int { get }; var active: Bool { get }
}
```
- `make`: `TempDirectory()` → `layout = HomeLayout(root: tmp.path("home"))`・`createDirectories()` → `paths = AppPaths(resources: PackageRoot.url.appendingPathComponent("Resources"), helpers: tmp.path("helpers"))` →
  `store = Builders.openStore(in: tmp.url, clock: clock)` → `configStore = ConfigStore(layout:, catalog: TestCatalogs.minimal, log:, observeReaperConf: { .missing }, defaultTimeZone: { "Asia/Tokyo" })` →
  `AtomicFile.write(ConfigLoader.encode(設定), to: layout.configFile)` → `await configStore.load()` が `.valid` であること
- `registerPart`: `inbox = layout.inboxFile(deviceID: "DJIMIC3", relpath:)`、`BWFWriter.write(to: inbox, seconds:, format: .pcm24, content: .speech)`、
  `NewRecording(partkey:, deviceID: "DJIMIC3", sourceFolder: RelPath.parent(relpath), transmitterID: "TX01", micIndex: 2, startedAt:, durationSeconds: seconds, endedAt: <startedAt + seconds の ISO>, sourcePath: relpath, sourceSize: <inbox の size>, sourceMtime: 1_787_000_000.0, sha256Helper: FileHasher.sha256(of: inbox, chunkBytes: 1_048_576), inboxPath: layout.relativePath(of: inbox)!)`

### 6.1 `ConfigStoreTests.swift`（`@Suite("ConfigStore")`）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `writesDefaultsWhenAbsent` / 「無ければ既定を書く」 | config.json 無し | `.valid`、ファイルの中身 == `ConfigLoader.encode(AppConfig.defaults(timeZone: "Asia/Tokyo"))`、`didCreateDefaults() == true` |
| `doesNotOverwriteInvalidFile` / 「在るが不正なら上書きしない」 | config.json に `{` | `.invalid`（CV-39）、ファイルは `{` のまま、`current() == nil`、`didCreateDefaults() == false`、ログに `config_invalid rule=CV-39 key=<file>` |
| `danglingSymlinkIsNotAbsent` / 「壊れた symlink は「無い」ではない」 | config.json を存在しない先への symlink に | `.invalid`、symlink のまま |
| `emptyFileIsInvalid` / 「空のファイルは不正（既定で埋めない）」 | 0 バイト | `.invalid`、CV-39 |
| `validFileLoads` / 「正しい設定を読む」 | 既定の vault.path を `/tmp/v` に変えて書く | `current()?.vault.path == "/tmp/v"`、`violations() == []` |
| `logsEveryViolation` / 「違反を 1 件ずつ ERROR で出す」 | `session.maxParts = 0` と `llm.topP = 0` | `config_invalid` の行が 2 本（CV-56 と CV-57 の順） |
| `updateValidatesBeforeWriting` / 「update は書く前に検証する」 | 読み込み後に `update { $0.session.maxParts = 0 }` | `.failure`（CV-57）、ファイルの中身と `current()` は変わらない |
| `updateWrites` / 「update は検証を通れば書く」 | `update { $0.vault.path = "/tmp/w" }` | `.success`、ファイルを読み直すと `/tmp/w`、`current()` も同じ |
| `updateUsesGivenObservation` / 「update は渡された reaper.conf の観測で検証する」 | 観測 `.valid(ReaperConf(deleteSourceAudio: true))` を渡し deleteSourceAudio は false のまま | `.failure`（CV-30） |
| `updateWhileInvalidFails` / 「設定エラー中の update は書かない」 | 不正なファイルで load の後 | `.failure`、ファイルは変わらない |
| `cv30WithoutReconcilerIsInvalid` / 「CV-30 は修復口が無ければ設定エラー」 | 観測 `.valid(true)`、config は削除無効 | `.invalid`、CV-30 を含む |
| `cv30IsReconciled` / 「CV-30 は両方を無効側に揃えて読み直す」 | `deleteSourceAudio = true`・`mountMode = "rw"` の config、観測は最初 `.valid(true)`・修復口が呼ばれた後 `.valid(false)` を返す | 修復口が 1 回呼ばれ、`.valid`、ファイルの `deleteSourceAudio == false`・`deleteSkippedSource == false`・`mountMode == "ro"`、ログ `config_warning rule=CV-30` |
| `cv30ReconcileFailureStaysInvalid` / 「修復口が偽なら設定エラー」 | 修復口が false | `.invalid`、ファイルは変わらない |
| `cv30IsReconciledOnlyOnce` / 「修復は 1 回だけ」 | 修復口は true を返すが観測は `.valid(true)` のまま | 修復口 1 回、`.invalid`（CV-30） |

### 6.2 `RecoveryTests.swift`（`@Suite("Recovery")`）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `rollsBackEveryInProgressState` / 「進行中の状態を全部 1 つ戻す」 | Part を NORMALIZING・TRANSCRIBING・RAW_WRITING・SOURCE_DELETING に 1 件ずつ、Session を MERGING・ANALYZING・WRITING・SOURCE_DELETING・CLEANUP に 1 件ずつ（通常の遷移で作る） | Part は DISCOVERED・NORMALIZED・TRANSCRIBED・SOURCE_DELETE_PENDING、Session は READY・MERGED・ANALYZED・SOURCE_DELETE_PENDING・SAVED。各 events の最後の detail が `recovery`、戻り値 9、ログ `recovery_completed rolled_back=9` |
| `orderIsPlanOrder` / 「戻す順は写像の順・started_at 順」 | TRANSCRIBING（07:00）と NORMALIZING（08:00）の Part | events の id が NORMALIZING の Part の方が小さい |
| `normalizingPartialIsComputedFromPartkey` / 「NORMALIZING の部分出力は partkey から消す（列が NULL でも）」 | `normalized_path` NULL の NORMALIZING、`staging/<slug>/audio16k.wav` と `.tmp` を置く | 2 つとも無い |
| `transcribingPartialIsRemoved` / 「TRANSCRIBING の部分出力を消す」 | transcript と whisper.json を置く | 2 つとも無い |
| `deleteRequestIDIsKept` / 「SOURCE_DELETING→PENDING で delete_request_id を外さない」 | `delete_request_id = "x"` | PENDING、`x` のまま |
| `unlinkFailureWarnsAndContinues` / 「消せなくても続ける」 | `audio16k.wav` の位置にディレクトリを置く | Part は DISCOVERED、ログ `config_warning rule=recovery` |
| `nothingToRecoverLogsNothing` / 「戻すものが無ければ何も出さない」 | 空の DB（TEST-28） | 0、ログ無し |

### 6.3 `InboxMaintenanceTests.swift`

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `removesOrphansAndPartials` / 「行の無い _orig.wav とすべての .partial を消す」 | inbox に行のある _orig.wav 1、行の無い _orig.wav 1、`.x_orig.wav.partial`（行のある Part の名前）1、`notes.txt` 1 | 戻り値 2、行のある _orig.wav と notes.txt は残る |
| `rootLevelRecordingsAreHandled` / 「ボリューム直下の録音も扱う」 | `inbox/DJIMIC3/TX01_MIC002_20260829_071204_orig.wav`（行無し） | 消える |
| `symlinksAreNotFollowed` / 「symlink は辿らず消さない」 | inbox の外の _orig.wav への symlink | 残る、外のファイルも残る |
| `leftoversCountsTerminalOnly` / 「取り残しは終端（FAILED 以外）の Part だけ」 | RAW_SAVED・FAILED・DISCOVERED の Part の _orig.wav（各 10 バイト） | `(1, 10)` |
| `emptyInbox` / 「空の inbox」 | 何も無い（TEST-28） | 0、`(0, 0)` |

### 6.4 `RequeueTests.swift`

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `requeueResetsRetryCount` / 「requeue は戻り先へ戻し retry_count を 0 に」（voicedock :725） | DISCOVERED→NORMALIZING→FAILED(WHISPER_FAILED) を 3 回（retry_count 3） | `requeueFailed(.startup) == 1`、NORMALIZING、retry_count 0、detail `requeue`、ログ `recovery_completed requeued=1` |
| `requeueSkipsNeedsRecopy` / 「needs_recopy の Part は requeue しない」 | FAILED(NORMALIZED_MISSING)、needs_recopy 1 | 0、FAILED のまま |
| `requeueIgnoresRetryPolicy` / 「RetryPolicy を見ずに全部戻す」 | FAILED(LLM_INVALID_JSON) の Session（none）と FAILED(IMPORT_FAILED) の Part | 2 |
| `requeueUsesTheLatestFailedOrigin` / 「戻り先は直近の FAILED への遷移元」 | NORMALIZING→FAILED → FAILED→NORMALIZING → … → RAW_WRITING→FAILED と進めた Part | RAW_WRITING に戻る（最初の NORMALIZING ではない） |
| `requeueRecopiedOnlyAfterRecopy` / 「契機 4: needs_recopy が 0 に戻った SOURCE_HASH_MISMATCH / NORMALIZED_MISSING だけ」 | 3 件: (HASH, recopy 0)、(MISSING, recopy 1)、(WHISPER_FAILED, recopy 0) | 1 件だけ NORMALIZING、detail `recopied`、retry_count 0 |
| `requeuePartsBeforeSessions` / 「Part → Session の順」 | FAILED の Part と Session | events の id が Part の方が小さい |
| `nothingFailed` / 「FAILED が無ければ 0・ログ無し」 | 空（TEST-28） | 0 |

### 6.5 `InProcessRetryTests.swift`

偽の工程: 呼ばれるたびに行を（NORMALIZING でなければ）NORMALIZING にしてから `NORMALIZING→FAILED(code)` を記録し、呼び出しを数える（voicedock `failing_pipeline`）。

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `waitsTheBackoffBetweenAttempts` / 「失敗 → 3 秒 → 失敗 → 10 秒 → 失敗 → 終了」（voicedock :651） | 既定、WHISPER_FAILED | 呼び出し 3 回、sleeper の記録 `[3, 10]`、events に detail `retry` の FAILED→NORMALIZING が 2 本 |
| `exemptCodeRunsOnce` / 「attempts 以外は 1 回で終わる」（voicedock :676） | WHISPER_EXEC_MISSING（RetryPolicy none） | 1 回、記録 `[]` |
| `stopBeforeSleepDoesNotSleep` / 「停止要求の後は待たない」（voicedock :697） | 1 回目の後に stop を立てる | 1 回、記録 `[]` |
| `stopDuringSleepDoesNotResume` / 「待ちの後に停止を見る」 | sleeper が待ちの中で stop を立てる | 1 回、FAILED のまま |
| `cancelledSleepEnds` / 「待ちが取り消されたら終わる」 | sleeper が CancellationError を投げる | 1 回 |
| `sessionRetriesToo` / 「Session も同じ」 | MERGED→ANALYZING→FAILED(LLM_UNAVAILABLE) を繰り返す偽の工程 | 3 回、`[3, 10]` |
| `ceRetryMaxAttempts` / 「CE retry.maxAttempts 2 にすると 2 回で終わる」 | maxAttempts 2 | 2 回、`[3]` |
| `ceRetryBackoffSeconds` / 「CE retry.backoffSeconds [5,7,9] の待ちが使われる」 | backoff `[5, 7, 9]` | `[5, 7]` |

### 6.6 `PauseBookTests.swift`

| 関数名 / 表示名 | 手順 | 期待 |
|---|---|---|
| `pausedOnceWhileContinuing` / 「続く間は 1 回だけ出す」 | tick 1: trip(whisper) ×2、finish。tick 2: trip(whisper)、finish | `pipeline_paused reason=whisper_missing` が 1 本、`paused == [.whisperMissing]` |
| `resumedWhenNotTripped` / 「当たらなくなった tick の終わりで出る」 | tick 1: trip、finish。tick 2: finish | `pipeline_resumed reason=whisper_missing` 1 本、`paused == []` |
| `diskSpaceUsesItsOwnEvent` / 「空き容量は disk_space_low を代わりに出す」 | trip(.diskSpaceLow, recordingKey: "k", detail: "空き 1 バイトが…") | `WARNING disk_space_low recording_key=k reason="空き 1 バイトが…"`、`pipeline_paused` は無い |
| `pausedIsInDeclarationOrder` / 「paused は宣言順」 | trip(license)、trip(diskSpaceLow) | `[.diskSpaceLow, .license]` |
| `reasonWordsMatchPlan` / 「理由の語が付録 A.4 と一致」 | `PauseReason.allCases.map(\.rawValue)` | `["disk_space_low", "whisper_missing", "model_missing", "vad_model_missing", "vault_not_configured", "vault_unavailable", "llm_not_selected", "llm_model_missing", "llm_insufficient_memory", "llama_server_missing", "license"]`（PLAN 付録 A.4 の並びを直書き） |
| `prerequisiteWordsAreReasons` / 「前提の欠けの語は停止理由の語」 | `TranscribePrerequisite` の全ケース | どれも `PauseReason(rawValue:)` が nil でない |

### 6.7 `PartStepsNormalizeTests.swift`（`@Suite(.serialized)`。本物の AVFoundation と BWF）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `normalizesAndReleasesInbox` / 「変換して DB を書き、その後で inbox を消す」 | `registerPart()` | 真、NORMALIZED、`sha256` == inbox の SHA、`normalized_path == "staging/<slug>/audio16k.wav"`、`staging_dir == "staging/<slug>"`、inbox が無い、ログ `normalize_completed recording_key=… in_bytes=<inbox の size> out_bytes=<出力の size> elapsed_s=0.0` |
| `ceAudioInboxRetainRawSaved` / 「CE audio.inboxRetain raw_saved なら NORMALIZED で inbox を消さない」 | `inboxRetain = "raw_saved"` | NORMALIZED、inbox が在る |
| `missingInboxIsSourceMissing` / 「inbox が無ければ SKIPPED(SOURCE_MISSING)」 | inbox を消す | 偽、SKIPPED、error_message `inbox に原本がありません: inbox/DJIMIC3/<relpath>`、`part_skipped reason=source_missing` |
| `emptyInboxIsMissing` / 「0 バイトは無いのと同じ」 | inbox を 0 バイトに | SKIPPED |
| `needsRecopyWaits` / 「needs_recopy なら SKIPPED にせず待つ」 | inbox を消し `needsRecopy(true)` | 偽、DISCOVERED のまま、events 増えない |
| `diskSpaceGuardDoesNotTransition` / 「空き容量が足りなければ遷移しない」 | `freeSpaceMarginBytes = Int.max / 4`・`stagingMaxBytes = Int.max / 2` | 偽、DISCOVERED、`disk_space_low recording_key=…` 1 本、`paused` に `.diskSpaceLow` |
| `normalizingEntryRecordsNoPhantom` / 「NORMALIZING から入っても遷移を記録しない」（voicedock test_part_resume :177） | DISCOVERED→NORMALIZING の後に呼ぶ | NORMALIZED、`DISCOVERED→NORMALIZING` の events が 1 本だけ |
| `duplicateIsSkippedWithDuplicateOf` / 「同じ内容は duplicate_of を先に書いて SKIPPED」 | 同じ BWF を別の relpath で 2 件登録し順に呼ぶ | 2 件目: SKIPPED(DUPLICATE_CONTENT)、`duplicate_of` = 1 件目、`sha256` NULL、message `同じ内容の Part が既にあります: <1 件目>` |
| `hashMismatchSetsNeedsRecopy` / 「SOURCE_HASH_MISMATCH は needs_recopy = 1」 | `sha256Helper` を `"b" × 64` にして登録 | FAILED(SOURCE_HASH_MISMATCH)、needs_recopy 1、`normalize_failed … error_code=SOURCE_HASH_MISMATCH` |
| `alreadyNormalizedIsTrue` / 「NORMALIZED 以降は真を返すだけ」（パラメータ化） | NORMALIZED・TRANSCRIBED・COMPLETED | 真、events 増えない |
| `failedAndSkippedAreFalse` / 「FAILED / SKIPPED は進めない」 | FAILED・SKIPPED | 偽 |

### 6.8 `PartStepsTranscribeTests.swift`（`@Suite(.serialized)`。本物の ProcessRunner と FakeWhisper）

準備: `installWhisper()`、Part を NORMALIZED にし、`staging/<slug>/audio16k.wav` に 16 バイトを置き `normalized_path` を書く（偽 whisper は読まない）。

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `transcribesAndRemovesNormalized` / 「文字起こしして 16 kHz を消す」 | 既定 | 真、TRANSCRIBED、`transcript_path == "transcripts/parts/<slug>.json"`、error_code NULL、audio16k.wav が無い、ログ `transcription_completed recording_key=… elapsed_s=0.0 chars=22` |
| `ceDeleteNormalizedAfterTranscribe` / 「CE cleanup.deleteNormalizedAfterTranscribe false なら 16 kHz を残す」 | false | audio16k.wav が在る |
| `noSpeechRecordsTranscriptPathFirst` / 「無音は transcript_path を先に書いて SKIPPED」 | utterances 空 | SKIPPED(NO_SPEECH_DETECTED)、`transcript_path` が在る、`part_skipped reason=no_speech` |
| `whisperFailureIsFailed` / 「whisper の失敗は FAILED」 | exitCode 3 | FAILED(WHISPER_FAILED)、`transcription_failed recording_key=… error_code=WHISPER_FAILED` |
| `missingWhisperIsAGuard` / 「whisper-cli が無ければ遷移せずに待つ」 | whisper-cli を消す | 偽、NORMALIZED のまま、`pipeline_paused reason=whisper_missing` |
| `missingModelsAreGuards` / 「モデルと VAD モデルの欠けも待つ」 | 両方消す | `paused == [.modelMissing, .vadModelMissing]` |
| `missingInputRenormalizes` / 「16 kHz が無く inbox が在れば NORMALIZING へ戻す」（voicedock test_missing_input :163） | audio16k.wav を消し inbox を置く | 偽、NORMALIZING、ログ無し、needs_recopy 0 |
| `missingInputAndInboxIsNormalizedMissing` / 「どちらも無ければ NORMALIZED_MISSING」（:115, :134） | 両方無し。NORMALIZED と TRANSCRIBING の 2 通り（パラメータ化） | FAILED(NORMALIZED_MISSING)、events の最後 2 本が `<元>→NORMALIZING` と `NORMALIZING→FAILED`、needs_recopy 1、`normalize_failed … reason=input`、message が §4.16 の逐語 |
| `emptyInputCountsAsMissing` / 「0 バイトの 16 kHz は無いのと同じ」（:224） | audio16k.wav を 0 バイトに | NORMALIZING か FAILED（inbox の有無で）、whisper は起動しない（`FakeWhisper.recordedArgv` が空） |
| `transcribingEntryRecordsNoPhantom` / 「TRANSCRIBING から入っても遷移を記録しない」 | NORMALIZED→TRANSCRIBING の後に呼ぶ | TRANSCRIBED、`NORMALIZED→TRANSCRIBING` は 1 本 |

### 6.9 `WorkerTests.swift`（`@Suite("Worker", .serialized)`）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `tickFollowsThePlanOrder` / 「tick の段の順（PLAN §5.4）」（voicedock :170） | 新鮮な snapshot（completedAt = now）、`requeue(.manual)` の後に tick、onStage で記録 | `TickStage.allCases` と同じ列 |
| `staleSnapshotSkipsDeletionStages` / 「snapshot が古ければ削除の 3 段を飛ばす」 | completedAt = now − 901 秒 | 記録に evaluateDeletions・settleSkippedDeletions・runReaperIfNeeded が無く、ほかは在る |
| `nilSnapshotSkipsDeletionStages` / 「snapshot が無ければ（起動直後）削除の 3 段を飛ばす」 | snapshot nil | 同上 |
| `freshnessBoundaryIsInclusive` / 「ちょうど 900 秒は新鮮」 | completedAt = now − 900 秒 | 3 段が在る |
| `configErrorDoesNothing` / 「設定エラー中は何もしない」 | 不正な config.json で load | 記録が空、DB 変わらない |
| `coexistenceBlockedDoesNothing` / 「共存ガード中は何もしない」 | ingest.state = .coexistenceBlocked | 記録が空 |
| `startRecoversAndRequeues` / 「start は復旧 → 閉じる → 孤児 → requeue」 | NORMALIZING の Part、FAILED(IMPORT_FAILED) の Part、行の無い _orig.wav | ログの順に `service_started version=<AppVersion.string> schema=<最後の移行 ID>`・`recovery_completed rolled_back=1`・`inbox_orphans_removed count=1`・`recovery_completed requeued=1` |
| `startWhileBlockedIsDeferred` / 「設定エラー中の start は保留し、解除後の最初の tick で行う」 | 不正な設定で start → 設定を直して load → tick | start の時点で `service_started` 無し、tick の後に在る、孤児の _orig.wav は残る（遅れた start では消さない） |
| `startIsOnce` / 「start は 1 回だけ」 | start を 2 回 | `service_started` 1 本 |
| `connectRisingEdgeRequeues` / 「connectEpoch が増えたら requeue(.connect)」（voicedock :358-455） | FAILED の Part。tick（epoch 0）→ epoch 1 で tick → もう一度 tick → epoch 2 で tick | 1 回目は FAILED のまま、2 回目で戻る。再び FAILED にして 3 回目は戻らない、4 回目で戻る |
| `firstConnectAfterStartupCounts` / 「起動後の最初の接続も契機」 | lastSeen 0、epoch 1 の snapshot | 戻る |
| `manualRequeueRunsAtTickStart` / 「再試行ボタンは次の tick の先頭」 | FAILED の Part、`requeue(.manual)` | requeue 直後は FAILED、tick の後は戻り先 |
| `pendingPartsAreOrderedByStartedAt` / 「Part は started_at 順に処理する」（voicedock :278） | 09:00 を先に・08:00 を後に登録（whisper 無し → 変換の後のガードで止まる） | `NORMALIZING→NORMALIZED` の events の id が 08:00 の Part の方が小さい |
| `terminalPartsAreNotPending` / 「終端の Part は扱わない」（voicedock :289） | FAILED・SKIPPED・RAW_SAVED・COMPLETED の Part | tick の後も events が増えない |
| `stopBetweenPartsStops` / 「停止要求は Part の区切りで効く」（voicedock :514） | 2 件。`world.context(stop: flag, assertion: RecordingSleepAssertion(onBegin: { flag.set() }))` で `worker.stageProcessPendingParts(ctx)` を直接呼ぶ（1 件目の変換が始まると停止が立つ） | 1 件目は NORMALIZED 以降、2 件目は DISCOVERED のまま |
| `licenseGateStopsTheTick` / 「課金の口が偽なら何もしない」 | 常に偽の LicenseGate | 段の記録が空、`pipeline_paused reason=license` |
| `requestStopLogsOnce` / 「service_stopping は 1 回」 | requestStop を 2 回 | 1 本 |
| `runWakesOnUpdates` / 「run は通知で起きる」 | sleeper を `SuspendingSleeper()`（30 秒の周期が来ない）、onStage の groupNewParts を数える、run を Task で開始。数が 1 になるまで待ち（`Task.sleep` 10 ms ずつ最大 5 秒）、`ingest.sendUpdate()` | 数が 2 になる。`requestStop()` の後 run の Task が 5 秒以内に終わる |
| `runWakesOnRequeue` / 「run はパネルの要求で起きる」 | 同上、`requeue(.manual)` | 数が 2、onStage に manualRequeue が 1 回 |
| `runDoesNotTickAfterStop` / 「停止の後は tick しない」（voicedock :489） | 1 回目の tick の onStage(.groupNewParts) で requestStop | 数が 1 のまま run が終わる |
| `sleepAssertionFollowsActivity` / 「工程の間だけスリープを抑止する」 | Part 1 件（whisper を置く）で tick | `assertion.begins >= 1`、tick の後 `active == false`、`status().activity == .idle` |

### 6.10 `WorkerTickTests.swift`（`@Suite(.serialized)`。BWF → 本物の AVFoundation → FakeWhisper）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `tickCarriesAPartToTranscribed` / 「1 tick で DISCOVERED → TRANSCRIBED」 | `installWhisper()`、`registerPart()`、tick | TRANSCRIBED、events の to の列 `[DISCOVERED, NORMALIZING, NORMALIZED, TRANSCRIBING, TRANSCRIBED]`、transcript の中身が T-17 §6.3 の期待（`duration_seconds` は `2.0`）とバイト一致、inbox と audio16k.wav が無い |
| `secondTickIsIdempotent` / 「2 回目の tick は何もしない（Raw は T-29）」 | 上の後にもう一度 tick | events が増えない、whisper が再び起動しない |
| `failedWhisperIsRetriedInProcess` / 「whisper の失敗は工程内で 3 回」 | exitCode 1 | FAILED(WHISPER_FAILED)、retry_count 3、sleeper `[3, 10]` |
| `emptyDatabaseTick` / 「空の DB で tick」（TEST-28） | 何も無い | 例外なし、ログ無し |

### 6.11 `StateHandlerTests.swift`（SM-07。voicedock test_part_resume :129-150）

| 関数名 / 表示名 | 期待 |
|---|---|
| `everyResumeTargetHasAHandler` / 「SM-07 FAILED の戻り先すべてに受け手がいる」 | `PartStates.retryableFromFailed ⊆ normalizable ∪ transcribable ∪ rawWritable` |
| `everyRecoveryTargetHasAHandler` / 「SM-07 復旧の戻り先に受け手がいる」 | `TransitionTable.partRecovery` の to のうち SOURCE_DELETE_PENDING 以外が上の和集合に在る（SOURCE_DELETE_PENDING は削除段が受ける） |
| `stageEntriesDoNotOverlap` / 「工程の入口は重ならない」 | normalizable・transcribable・rawWritable が互いに素 |

### 6.12 `SpecSyncTickOrderTests.swift`

| 関数名 / 表示名 | 期待 |
|---|---|
| `tickOrderMatchesSpec` / 「tick の順が SPEC と一致」 | `SpecDocument` の「Worker の tick の順」の `text` ブロックを空白で分けた列 == `TickStage.allCases.map(\.rawValue)` |

### 6.13 `ConfigEffectPending.swift`（PolicyTests）

`audio.inboxRetain`、`cleanup.deleteNormalizedAfterTranscribe`、`retry.maxAttempts`、`retry.backoffSeconds` の 4 行を消す（CE テストは §6.5・§6.7・§6.8）。

## 7. 破壊による証明

| 壊し方（1 か所だけ） | 落ちるべきテスト |
|---|---|
| tick で groupNewParts と processPendingParts を入れ替える | `tickFollowsThePlanOrder`、`tickOrderMatchesSpec` |
| 新鮮さの比較を `<` にする（900 秒ちょうどを古いとする） | `freshnessBoundaryIsInclusive` |
| requeueFailed で needs_recopy の除外を消す | `requeueSkipsNeedsRecopy` |
| requeueRecopied で `needsRecopy == false` の条件を消す | `requeueRecopiedOnlyAfterRecopy` |
| InProcessRetry で sleep の前の停止の確認を消す | `stopBeforeSleepDoesNotSleep` |
| InProcessRetry の resumeFailed で resetRetry を true にする | `waitsTheBackoffBetweenAttempts`（4 回目が走る） |
| ensureNormalized の needs_recopy の分岐を消す | `needsRecopyWaits` |
| 空き容量のガードで DISCOVERED→NORMALIZING を先に記録する | `diskSpaceGuardDoesNotTransition` |
| NORMALIZING からの入口で遷移を記録する | `normalizingEntryRecordsNoPhantom` |
| inbox の削除を DB 更新の前に動かし、updateRecording を失敗させる注入をする | `normalizesAndReleasesInbox`（inbox が消えた上に NORMALIZED にならない） |
| ensureTranscribed のガードで `NORMALIZED→TRANSCRIBING` を先に記録する | `missingWhisperIsAGuard` |
| renormalizeOrFail の needs_recopy の書き込みを消す | `missingInputAndInboxIsNormalizedMissing` |
| PauseBook で毎回ログを出す | `pausedOnceWhileContinuing` |
| Recovery の NORMALIZING の削除を `normalized_path` 列から取る | `normalizingPartialIsComputedFromPartkey` |
| ConfigStore.load で不正なファイルを既定で上書きする | `doesNotOverwriteInvalidFile` |
| ConfigStore.update で検証の前に書く | `updateValidatesBeforeWriting` |
| 遅れた start でも inbox の孤児を消す | `startWhileBlockedIsDeferred` |
| requeueOnConnect で lastSeenConnectEpoch を更新しない | `connectRisingEdgeRequeues`（3 回目が戻る） |

## 8. 受け入れ条件

- [ ] §3 のファイルがすべて在り、公開宣言が 00-api-map §11（と §11 の提案）に一致する
- [ ] `.recovery` が `Recovery.swift` の外に無い（PT-21）。`reaperConf` の語が VDPipeline の許可ファイルの外に無い（PT-11）
- [ ] 空の段・空の工程に「T-nn が中身を書く」のコメントがある
- [ ] §6 のテストがすべて通り、ConfigEffectCoverage が緑
- [ ] 破壊による証明の各項目で表のテストが落ちることを確かめ、PR 本文に貼った
- [ ] `make lint` が通る

## 9. SPEC の変更

`docs/SPEC.md` に次の節を足す（`tickOrderMatchesSpec` が突き合わせる）:

````markdown
## Worker の tick の順

```text
manualRequeue groupNewParts requeueRecopied closeIdleSessions processPendingParts refreshVaultIndex processReadySessions collectDeleteResults expireDeleteRequests evaluateDeletions settleSkippedDeletions runReaperIfNeeded pendingJobs requeueOnConnect
```
````

## 10. マージ後にやること

- 00-api-map §11・§15 を §11 の提案どおりに直す（同じ PR で直せなかった分）
- T-30 の Bootstrap: `ConfigStore(… observeReaperConf: { .missing })` で作り（T-36 のマージで `locks.observeReaperConf()` に替える）、`Worker(deps:)` を `run()` で回す

## 11. API 地図への変更提案

1. `ConfigStore.init(layout:catalog:locks:)` → `init(layout:catalog:log:observeReaperConf:defaultTimeZone:)`。LockEvaluator は T-36（Phase 8）で、T-18 からは使えない。PT-11 により ConfigStore は `reaperConf` の語を書けないので、観測は注入のクロージャで受ける。`load()` は修復口を待つので `async`。`didCreateDefaults()`・`setLock1Reconciler(_:)` を足す
2. `ConfigStore.update(_:reaperConf:)` → `update(_:reaperConfObservation:)`（ラベルの `reaperConf` が PT-11 の `.word("reaperConf")` に当たる）
3. 同じ理由で `ConfigLoader.load(data:catalog:reaperConf:)`・`ConfigValidator.validate(_:catalog:reaperConf:)`（T-09）の呼び出しも ConfigStore.swift の中で PT-11 に当たる → **決着済み**（00-api-map §11 の `ConfigStore` の行）: T-09 のラベルを `reaperConfObservation:` にする（PT-11 の許可場所は増やさない）。T-09 §5・§6 に反映済み
4. `WorkerDependencies.ingest: IngestService` → `any IngestPort`（新設の公開プロトコル。`extension IngestService: IngestPort`）。`zone` は持たない（設定のタイムゾーンから tick ごとに作る）。T-18 の時点のフィールドは §4.4。`llama`・`chatTransportFactory` は T-22、`locks`・`reaper`・`volumeOpener` は T-36 以降、`verificationCache` は T-32 が足す
5. PLAN §8.3 手順 6・§8.4 手順 2 の「同じトランザクションで needs_recopy = 1」は、Store に遷移と列の更新を 1 トランザクションで行う API が無いため「`updateRecordingIfStatus(status: .normalizing, [.needsRecopy(true)])` を遷移より先に書く」とした。同じ性質を API で保証するなら `recordPartTransition(…, alsoSet: [RecordingField])` を T-11 に足す
6. `WorkerStatus` に `Equatable` と公開の init、`WorkerActivity`（§4.5）の定義を地図に載せる。`RequeueReason` に `String` の rawValue
7. `WorkerJob` と `enqueue(_:)` は T-32 が足す（DiagnosticResult・BacklogAction が T-18 の時点に無い）
8. §15 に `FakeIngest`（作り手 T-18、使う T-22・T-29・T-38）を足す
9. §15 の `Builders` は T-11 の本文では `StoreFixtures` という名前で書かれている。どちらかに揃える（本チケットは地図の `Builders` で書いた）
10. `SessionSteps.swift` の骨組み（§4.17）は T-18 が置き、T-22 が本体を書く。`Worker+SessionStages.swift`・`Worker+NoteStages.swift`・`Worker+DeletionStages.swift`・`Worker+Jobs.swift`・`Recovery+VaultTmp.swift`・`PartSteps+RawNote.swift` も同じ（空の本体を後続が書き換える）
11. 付録 A.4 に「DB の予期しない例外」を出すイベントが無い。本チケットは `config_warning rule=store message=…` で代用した。専用のイベント（例 `worker_error stage=… message=…`）を足すなら A.4・`LogEvent`・SPEC を同じ PR で直す
