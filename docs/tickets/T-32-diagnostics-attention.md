# T-32 診断（DR）・要対応（沈黙の検出）・状態の詳細

> （F-80・issue #119、2026-09-23。マージ後の追記）(1) 「一覧に在るか」は `SourcePresence.of(_:in:)`（internal）の 1 か所にまとめ、`AttentionEvaluator.sourcePresence` を置き換えた（削除の段と共有。PLAN §8.9.5）。
> (2) 要対応の `undeletableSources` と状態の詳細の在否は、`snapshotMaxAgeSeconds` より古い snapshot では「一覧に在る」と数えない（`AttentionEvaluator.freshSnapshot`。状態の詳細は「デバイスを観測できない」）。
> (3) DB から数える 2 つの件数は `AttentionInput.countStoredItems(from: ReadOnlyStore)`（public）で入れ、AppServices（`LiveServices.read`）はそれを呼ぶだけ（配線は PolicyTests の `AttentionWiringTests` がトークンで固定）。
> (4) 設定エラー中（`configPresent == false`）は、停止理由（`PauseReason`）から作る項目を出さない（Worker は設定エラー中に停止理由を更新しない。PLAN §8.11）。§5 の `orderFollowsTheSpecTable` は設定が読めている入力で全部を並べる形に直した（18 件）。
> (5) 状態の詳細の失敗した Part は、F-75 の定型の error_message（`OBSIDIAN_RAW_WRITE_FAILED` で PLAN §8.6 の 2 つの文言で始まるもの）だけを 3 行目 `    <error_message>` に出す（`StatusReport.FailedPart.note`・`StatusReporter.failureNote`。PLAN §8.12）。
> (6) VDPipeline の中だけで使う `public` を internal にした（`undeletableStillListed`・`rawNoteBlockedSessions`・`isIngestSilent`・`StatusReporter` の表・`FailedPart` / `UndeletablePart` の init と `detail`）。下の §4 のコードの `public` はその分を読み替える。テストは T-38 の `DeletionRemainderTests`。
> (7) `snapshot.unavailable` の理由語 `mount_failed`（F-81。再マウントの mount の失敗）も `deviceNeedsReplug` に写す（`AttentionEvaluator.mountFailedReason`・`replugReasons`）。
> (8) `reaperUpdateRequired` は削除が有効な間だけ出す（`AttentionInput.deletionEnabled`（public。既定 false）。AppServices が `config.cleanup.deleteSourceAudio` を入れる）。§5 の `reaperUpdateRequired`・`orderFollowsTheSpecTable` は `deletionEnabled = true` で試す。

> （F-81・issue #119。2026-09-23）DR-11 は `not_included`（改名の案内だけ）を数えず、`not_listable` が無く `mount_failed`（再マウントでアンマウントされたまま）が在れば 0 台でも ok にせず notice
> 「<名前> は読み取り専用への切り替えの途中でアンマウントされたままです。取り外して、もう一度つなぎ直してください」（`DiagnosticTexts.leftUnmounted`）。PLAN §8.11 の表（SPEC S6）。テストは `DiagnosticDeviceNoticeTests`。

> （F-78・issue #124、2026-09-23。マージ後の追記）reaper の拒否が 3 回続いて打ち切った Part（T-38 §4.5 の手順 5b）も最後の遷移が detail `not_deletable` の COMPLETED なので、`undeletableSources` と「消せなかった録音」に同じ数え方で入る。原因の語は reaper の理由語（付録 B.2）なので、
> `StatusReporter.causeText(_:)`（internal）を足し、`causeTexts` に無く `IdentityReason.all` に在る語を「削除モジュールの検証で拒否され続けた（<理由語>）」と出す（`UndeletablePart.detail` はこれを使う。型は変えない。テストは T-38 の `ReaperRejectionSettlementTests`）。
> 要対応 `undeletableSources` の説明を、5a（直せば再評価できる）と 5b（削除モジュールの拒否。再評価しても同じ）の両方に合う文言に直した（下の表・`AttentionTextsTests`。PLAN §8.11）。

> （F-76・issue #116。2026-09-23）DR-09（`LLMProbeCheck`）は `ensureRunning` を呼んだら、応答の後（成功でも失敗でも）`llama.stop()` を呼ぶ（止めないと `pendingJobs` で起動したサーバが次の tick の Part 工程（whisper）と重なる。PLAN §2.1・LLM-15）。下の §4 の「llama-server を止めない」・§5 の `probeDoesNotStopTheServer`・§6 の 19 は記録として残す（テストは `probeStopsTheServerAfterTheReply` ほか 3 本に置き換えた）。`DeletionReadiness` に `unconfirmed`（reaper の版を観測できなかった。T-36 の注記）を足した。

> （F-75・issue #115、2026-09-23。マージ後の追記）要対応の末尾に `rawNoteBlocked(Int)`（「書き直せない Raw ノート <n> 件」、操作 `[.openDetails]`）と `AttentionInput.rawNoteBlocked`、
> `AttentionEvaluator.rawNoteBlockedSessions(_:)`（FAILED・`OBSIDIAN_RAW_WRITE_FAILED`・error_message が PLAN §8.6 の文言で始まる Part の Session の数）を足した。
> AppServices は `ReadOnlyStore.failedParts(limit: Int.max)` の全件から数える。「FAILED は要対応にしない」の例外（PLAN §8.11）。テストは `RawNoteBlockedAttentionTests.swift`。

> （F-74・issue #114、2026-09-23。マージ後の追記）SOURCE_DELETE_PENDING から決着した Part も最後の遷移が detail `not_deletable` の COMPLETED なので、`undeletableSources` と状態の詳細の「消せなかった録音」に同じ数え方で入る（型・文言は変えない。テストは T-38 の `PendingSettlementTests`）。

> （F-69・issue #98、2026-09-23。マージ後の追記）要対応の末尾に `undeletableSources(Int)`（「消せなかった録音 <n> 本」、操作 `[.openDetails]` =「詳細・診断を開く」）、`AttentionInput.undeletableSources`、
> `SourcePresence`・`AttentionEvaluator.sourcePresence(_:snapshot:)`・`undeletableStillListed(_:snapshot:)`、`ReadOnlyStore.completedParts(lastDetail:)`、`StatusReport.UndeletablePart`・`undeletable` / `undeletableTotal` と状態の詳細の「消せなかった録音」の行を足した（PLAN §8.11・§8.12。決着そのものは T-38 §4.5 の手順 5a）。
> 下の表はその分を直した。テストは T-38 §6.13 の `UndeletableSettlementTests`。

> （F-72・issue #112、2026-09-23。マージ後の追記）診断の結果（`AppModel.diagnostics`）は `panelDidClose` で `.idle` に戻し、閉じた後に届いた結果も捨てる（`diagnosticsGeneration`。DR-09 の `probeGeneration` と同じ形）。「元音声の削除」の事前確認に前に開いたときの結果を「最新」として出さないため（PLAN §8.9.8 の 1）。
> 閉じる前に始めた診断が走っている間に開き直して押されたら、その診断が終わるのを待ってから次を起動する（`diagnosticsTask` を持って直列にする。診断を同時に 2 本走らせない。前の結果は世代で捨てる）。下の §4 の `runDiagnostics()`・`panelDidClose()` の箇条はその分を直した。テストは `AppModelConsentTests`。

| 項目 | 内容 |
|---|---|
| ID | T-32 |
| Phase | 7（UI と配布） |
| 前提 | T-30（`AppModel`・`AppSnapshot`・`AppServices`・`Strings`・`StatusTexts`・`LoginItemStatus`・空の `AttentionSection` / `DetailsSection`）。間接に T-11（`ReadOnlyStore`）、T-16（`SpaceCheck`）、T-17（`WhisperHelpCheck`）、T-18（`Worker` の `stagePendingJobs` の空の段・`PauseReason`）、T-21（`LlamaArgs.missingFlags`）、T-22（`LlamaServerSupervisor`・`chatTransportFactory`）、T-28（`VaultCheck`）。**T-36 は前提ではない**（Phase 8。ロックの観測は本チケットが作る `LockObserving` と `DisabledLockObserver` で足り、T-36 が `LockEvaluator` をこのプロトコルに準拠させて差し替える。§4.11） |
| 見積もり | 本体 約 1,500 行、テスト 約 1,700 行 |

## 1. 目的

3 つを作る。どれも**何も書き換えない**:

1. **診断（DR-01〜17 のうち 15 件 ＋ DR-09。DR-13 は取り下げ。PLAN F-61）** — パネルの「詳細・診断 → 診断を実行」。voicedock の `doctor` の実行規則（致命の fail 以降は skip・DR-14 は最後）をそのまま移す
2. **要対応（`AttentionItem`）** — 無人稼働で最も起きやすい故障「何も起きない」を検出する（SM-24 / RK-23）。**利用者の操作が要るものだけ**を出す（OPS-12）
3. **状態の詳細（`StatusReport`）** — voicedock の `status` に当たる。**DB が無ければ全 0**、DB を作らない

あわせて `WorkerJob` と `Worker.enqueue(_:)`（T-18 が空けた `pendingJobs` の段）を足す。DR-09（LLM の実リクエスト）は Worker の直列ループに 1 件の仕事として入れる。

## 2. 参照

- PLAN §8.11（DR の表・実行規則・要対応の表）、§8.12（状態の詳細の全項目・パネルの 8「詳細」）、§8.9.8（ロックの個別表示。DR-14）、§8.3（空き容量の式と文言）、§8.7（Vault の判定）、§8.4（whisper の VAD フラグ）、§8.5（llama-server のフラグ）、§8.10（モデルの在否と SHA・`ModelVerificationCache`）、§5.4（ガード＝`PauseReason`）、§9.4 PT-17、付録 A.4（`diagnostics_completed`）、§10.3（件数を README と突き合わせる）
- 00-api-map.md §11（`Diagnostics/`・`AttentionItems.swift`・`StatusReport.swift`・`Worker`・`WorkerJob`・**`LockObserving.swift`（本チケットが作る）**・`LockEvaluator`）、§3（`ReadOnlyStore`）、§6（`SpaceCheck`）、§7（`WhisperHelpCheck`）、§8（`LlamaArgs` / `LLMProbe`）、§9（`VaultCheck`）
- 先行チケット: T-30 §4.7〜§4.13（`AppSnapshot` / `AppServices` / `AppModel` / `StatusTexts`）、T-18 §4.7〜§4.8（`TickContext` / `TickStage` / `PauseBook`）
- **後続**チケット: T-36 §4.5（`LockEvaluator` が本チケットの `LockObserving` に準拠し、Bootstrap の `DisabledLockObserver` を差し替える）、T-41 §4.2（`WorkerJob` に 2 ケースを足す。本チケットは `.llmProbe` だけを宣言する）
- voicedock@d3d595e: `src/voicedock/doctor.py:45-77`（4 値・記号・行）、`doctor.py:105-112, 589-674`（`always` と実行規則とサマリ）、`doctor.py:115-586`（各検査）、`src/voicedock/status.py:38-200, 260-480, 530-563`（状態の詳細）、`src/voicedock/health.py:14-24`（doctor と実装を共有しない理由）
- 移植メモ: `docs/porting-notes/V6-doctor-ci-e2e-docs.md` §1〜§3

## 3. 作るもの

| パス | 内容 |
|---|---|
| `Sources/VDPipeline/Diagnostics/DiagnosticResult.swift` | `DiagnosticStatus`、`DiagnosticResult` |
| `Sources/VDPipeline/Diagnostics/DiagnosticCheck.swift` | `DiagnosticCheck`（1 件の検査の定義）、`DiagnosticID` |
| `Sources/VDPipeline/Diagnostics/DiagnosticsDependencies.swift` | `DiagnosticsDependencies`、`AppSignatureReading`、`AppSignatureInfo`、`SecAppSignatureReader` |
| `Sources/VDPipeline/Diagnostics/Diagnostics.swift` | `Diagnostics`（登録表と実行規則とサマリ） |
| `Sources/VDPipeline/Diagnostics/DiagnosticChecks.swift` | DR-01〜17 のうち 15 件の本体（DR-09 は別、DR-13 は取り下げ） |
| `Sources/VDPipeline/Diagnostics/DiagnosticTexts.swift` | ラベルと文言（逐語） |
| `Sources/VDPipeline/Diagnostics/LLMProbeCheck.swift` | DR-09 |
| `Sources/VDPipeline/LockObserving.swift` | `LockObserving`・`DisabledLockObserver`・`LockObservation`・`LockDisplay`・`ReaperStatus`・`DeletionReadiness`・`DeviceWritability`（00-api-map §11。§4.11。**T-36 の `LockEvaluator` がこのプロトコルに準拠する**） |
| 変更 `Sources/VDPipeline/StatusTexts.swift` | `writabilityWord(_:)` を足す（T-30 から移した。`DeviceWritability` はこのチケットが作るため。§4.12） |
| `Sources/VDPipeline/InboxScan.swift` | `InboxCounts`、`InboxScan`（読むだけ。DR-15 と状態の詳細が共有） |
| `Sources/VDPipeline/AttentionItems.swift` | `AttentionItem`、`AttentionAction`、`AttentionInput`、`AttentionEvaluator` |
| `Sources/VDPipeline/StatusReport.swift` | `StatusReport`、`StatusReporter`、`BacklogCounts`（T-30 の `AppSnapshot.swift` から移す。§4.9。`StatusReport` が public なので VDPipeline に置く） |
| 変更 `Sources/VDStore/ReadOnlyStore.swift` | `inboxPaths(statuses:)`（00-api-map §16 の VDStore の行。§10 の 6） |
| 変更 `Sources/VDStore/Store.swift` | `static let migrationIdentifiers`（00-api-map §16。§10 の 7） |
| 変更 `Sources/VDPipeline/Worker.swift` | `WorkerJob`、`enqueue(_:)`、`pendingJobs` |
| 変更 `Sources/VDPipeline/Worker+Jobs.swift` | `stagePendingJobs(_:)`（T-18 の空の段に中身を入れる） |
| `Sources/VoiceDockApp/AttentionTexts.swift` | 要対応の説明とボタンの文言（逐語） |
| `Sources/VoiceDockApp/AppModel+Diagnostics.swift` | 診断・LLM の疎通確認・状態の詳細の操作 |
| `Sources/VoiceDockApp/Panel/AttentionSection.swift` | §8.12 の 2（T-30 の空を置き換え） |
| `Sources/VoiceDockApp/Panel/DetailsSection.swift` | §8.12 の 8（同上） |
| 変更 `Sources/VoiceDockApp/AppSnapshot.swift` / `AppServices.swift` / `AppModel.swift` / `Strings.swift` / `Bootstrap.swift` | §4.10（`Bootstrap` は `locks` と `diagnostics` を組み立てる。`AppSnapshot.swift` から `BacklogCounts` を消す） |
| `Tests/VDPipelineTests/DiagnosticsRunTests.swift` | 実行規則・サマリ・`diagnostics_completed` |
| `Tests/VDPipelineTests/DiagnosticChecksTests.swift` | DR ごとに ok / notice / fail / skip |
| `Tests/VDPipelineTests/DiagnosticsNoWriteTests.swift` | 診断が何も書かないこと |
| `Tests/VDPipelineTests/LLMProbeCheckTests.swift` | DR-09 |
| `Tests/VDPipelineTests/AttentionEvaluatorTests.swift` | 要対応の各項目・沈黙の判定 |
| `Tests/VDPipelineTests/StatusReporterTests.swift` | 状態の詳細の書式 |
| `Tests/VDPipelineTests/InboxScanTests.swift` | |
| `Tests/VDPipelineTests/LockObservingTests.swift` | `DisabledLockObserver` と `LockDisplay.lines`（§5.10） |
| 変更 `Tests/VDPipelineTests/StatusTextsTests.swift` | `writabilityWords`（§5.11） |
| `Tests/VDPipelineTests/WorkerJobsTests.swift` | `enqueue` と `stagePendingJobs` |
| `Tests/VoiceDockAppTests/AttentionTextsTests.swift` | 文言と操作の対応 |
| `Tests/VoiceDockAppTests/AppModelDiagnosticsTests.swift` | |
| 変更 `Tests/VoiceDockAppTests/FakeServices.swift` | `AppServices` に足した 4 つ（§4.10）の偽物と記録 |
| 変更 `Tests/VoiceDockAppTests/AppModelTests.swift` | `AppContext` の init に `locks` / `diagnostics` を渡す（`bootWithoutDatabaseShowsZero`） |
| 変更 `Tests/PolicyTests/SpecSync/SpecCoverage.swift` | `activated` に `.dr` を足す（T-05 §4。DR の表示名と SPEC の S6 の集合を一致させる） |

## 4. 仕様

### 4.0 全体の規則（PT-17）

**`Sources/VDPipeline/Diagnostics/` のコードは何も書き換えない**（OPS-14）。PT-17 が次を検査する:
- PT-01 の API（`removeItem` / `unlink(` など）、PT-12 の API（`.write(to:` / `createFile(` / `renameat(` など）、`AtomicFile`、`Store(`（書ける `Store` の初期化）が 1 つも無い
- DB は `ReadOnlyStore.open(url:)` だけ。Vault は `access` と `opendir` だけ。**一時ファイルを書かない**（voicedock は D-3 / D-13 で `.voicedock-doctor-probe.tmp` を書いていた。本アプリは書かない）
- フォルダを作らない（voicedock `doctor.py:374-376`。テンプレートの `{yyyymmdd}` フォルダが増える）

`Diagnostics` は `WorkerDependencies` を受け取らない（書ける `Store` を持っているため）。専用の `DiagnosticsDependencies` を受け取る。

---

### 4.1 `DiagnosticResult.swift` と `DiagnosticCheck.swift`

```swift
// 診断の 1 件の結果（PLAN §8.11。voicedock doctor.py:45-57）。
public enum DiagnosticStatus: String, Sendable, Equatable, CaseIterable {
    case ok, notice, fail, skip
    /// voicedock doctor.py:52-57 と同じ記号
    public var mark: String {
        switch self { case .ok: "✓"; case .notice: "!"; case .fail: "✗"; case .skip: "-" }
    }
}

public struct DiagnosticResult: Sendable, Equatable {
    public let id: String            // "DR-01" … "DR-17"（2 桁。ゼロ詰め）
    public let status: DiagnosticStatus
    public let label: String         // DiagnosticTexts の日本語のラベル
    public let details: [String]     // 続きの行。0 件でもよい
    public init(id: String, status: DiagnosticStatus, label: String, details: [String] = [])
}
```

```swift
// 1 件の検査の定義（voicedock doctor.py:100-112 の Check）。
struct DiagnosticCheck: Sendable {
    let id: String
    /// この検査が fail を出したら以降を skip にするか（PLAN §8.11 の「致命」列）
    let fatal: Bool
    /// 先行する致命的な検査が失敗しても実行するか（**DR-14 だけが真**。設定が読めていることは前提にする）
    let always: Bool
    let run: @Sendable (DiagnosticsContext) async -> DiagnosticResult
}

/// 検査の間で共有する読み取り専用の値（voicedock doctor.py:80-98 の Context）。
struct DiagnosticsContext: Sendable {
    let deps: DiagnosticsDependencies
    let config: AppConfig?             // 読めなければ nil（DR-01 が fail を出している）
    let violations: [ConfigViolation]
    let snapshot: DeviceSnapshot?
    let loginItem: LoginItemStatus
    let now: Instant
}
```

### 4.2 `DiagnosticsDependencies.swift`

```swift
// 診断が触る口（すべて読むだけ）。Worker とは別に組み立てる（書ける Store を渡さない。PT-17）。
import Foundation
import Security
import VDContract
import VDCore
import VDDevice
import VDProcess

public struct DiagnosticsDependencies: Sendable {
    public let layout: HomeLayout
    public let paths: AppPaths
    public let catalog: ModelCatalog
    public let config: ConfigStore
    public let ingest: any IngestPort
    public let locks: any LockObserving      // Phase 7 は DisabledLockObserver、T-36 が LockEvaluator に差し替える（§4.11）
    public let runner: any ProcessRunning
    public let verificationCache: ModelVerificationCache
    public let signature: any AppSignatureReading
    public let bundleURL: URL
    public let physicalMemoryBytes: UInt64
    public let clock: any AppClock
    public let log: AppLog
    public init(…上の順に全フィールド…)
}

/// アプリ自身の署名（DR-17）。
public struct AppSignatureInfo: Equatable, Sendable {
    public let valid: Bool
    /// ad-hoc 署名では nil
    public let teamID: String?
    public let message: String?      // 検査自体が失敗した理由
    public init(valid: Bool, teamID: String?, message: String?)
}

public protocol AppSignatureReading: Sendable {
    func read(bundle: URL) -> AppSignatureInfo
}

/// 本番の実装（Security.framework）。
public struct SecAppSignatureReader: AppSignatureReading {
    public init()
    public func read(bundle: URL) -> AppSignatureInfo
}
```

`SecAppSignatureReader.read` の手順:
1. `var code: SecStaticCode?`。`SecStaticCodeCreateWithPath(bundle as CFURL, [], &code)` が `errSecSuccess` でなければ `AppSignatureInfo(valid: false, teamID: nil, message: DiagnosticTexts.signatureUnreadable)`
2. `SecStaticCodeCheckValidity(code, [], nil)` が `errSecSuccess` でなければ `AppSignatureInfo(valid: false, teamID: nil, message: nil)`
3. `var info: CFDictionary?`。`SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)`
4. `teamID = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String`（ad-hoc なら無い）
5. `AppSignatureInfo(valid: true, teamID: teamID, message: nil)`

---

### 4.3 `Diagnostics.swift`（登録表・実行規則・サマリ）

```swift
// 診断（PLAN §8.11）。何も書き換えない（PT-17）。voicedock doctor.py:589-674 と同じ実行規則。
public struct Diagnostics: Sendable {
    public init(deps: DiagnosticsDependencies)
    /// 15 件を PLAN §8.11 の表の順に実行する。DR-09 は含まない（別のボタン）。
    public func run(loginItemStatus: LoginItemStatus) async -> [DiagnosticResult]
    /// 「合格 <n>・失敗 <n>・注意 <n>」（**skip は数えない**）
    public static func summary(_ results: [DiagnosticResult]) -> String
    public static func counts(_ results: [DiagnosticResult]) -> (passed: Int, failed: Int, notices: Int)
    /// PLAN §8.11 の表の順。宣言順 = 実行順（SPEC と突き合わせる）
    static let checks: [DiagnosticCheck]
}
```

`checks` の並び（**この順**。PLAN §8.11 の「順」の列）:

| 順 | id | fatal | always |
|---|---|---|---|
| 1 | `DR-01` | ○ | |
| 2 | `DR-16` | ○ | |
| 3 | `DR-02` | ○ | |
| 4 | `DR-03` | | |
| 5 | `DR-04` | | |
| 6 | `DR-05` | | |
| 7 | `DR-06` | | |
| 8 | `DR-07` | | |
| 9 | `DR-08` | | |
| 10 | `DR-10` | | |
| 11 | `DR-11` | | |
| 12 | `DR-12` | | |
| 13 | `DR-15` | | |
| 14 | `DR-17` | | |
| 15 | `DR-14` | | ○ |

- **欠番は DR-13 だけ**（DR-01〜17 の 17 個のうち DR-09 は別、DR-13 は共存ガードとともに取り下げた。PLAN F-61。15 + 1 = 16。件数は SPEC の表から数え、README と文書テストで突き合わせる。PLAN §8.11 の最後）

**`run(loginItemStatus:)` の手順**:
1. `let config = await deps.config.current()`、`let violations = await deps.config.violations()`
2. `let snapshot = await deps.ingest.latestSnapshot()`
3. `let ctx = DiagnosticsContext(deps: deps, config: config, violations: violations, snapshot: snapshot, loginItem: loginItemStatus, now: deps.clock.now())`
4. `var results: [DiagnosticResult] = []`、`var blocked = false`
5. `for check in Self.checks`:
   - `if blocked && !(check.always && ctx.config != nil)`:
     `results.append(DiagnosticResult(id: check.id, status: .skip, label: DiagnosticTexts.label(check.id), details: [DiagnosticTexts.skipped]))`、`continue`
   - `let r = await check.run(ctx)`、`results.append(r)`
   - `if check.fatal && r.status == .fail { blocked = true }`
6. `let c = Self.counts(results)`。`deps.log.info(.diagnosticsCompleted, [(.passed, .of(c.passed)), (.failed, .of(c.failed)), (.notices, .of(c.notices))])`
7. `return results`

- `DR-14` は `always: true`。**設定が読めていれば（`ctx.config != nil`）先行の fail でも実行する**（voicedock `doctor.py:640-641`。削除モードの表示は「見落としてよい行」ではない）
- `counts`: `passed = ok の数`、`failed = fail の数`、`notices = notice の数`。**skip は数えない**（voicedock `doctor.py:669-674`）
- `summary` = `"合格 " + passed + "・失敗 " + failed + "・注意 " + notices`

---

### 4.4 `DiagnosticChecks.swift`（15 件の本体）

共通: ラベルは `DiagnosticTexts.label(id)`。詳細は `DiagnosticTexts` の関数（§4.5）。**すべて読むだけ**。

**DR-01 設定**（fatal）
1. `ctx.config != nil && ctx.violations.isEmpty` → `.ok`、details `[DiagnosticTexts.configOK]`
2. そうでなければ `.fail`、details = `ctx.violations.map(\.rendered)`（1 件 1 行）。違反が空で config が nil なら `[DiagnosticTexts.configUnreadable]`

**DR-16 タイムゾーン**（fatal）
1. `guard let c = ctx.config else { return .fail(details: [DiagnosticTexts.configMissing]) }`
2. `TimeZone(identifier: c.timeZone) != nil` → `.ok`、details `[c.timeZone]`
3. そうでなければ `.fail`、details `[DiagnosticTexts.timeZoneUnresolved(c.timeZone)]`
   （CV-32 が先に落とすので普通は起こらない。**式を 2 か所に書かない**ため `TimeZone(identifier:)` をそのまま使う）

**DR-02 データベース**（fatal）
1. `let url = ctx.deps.layout.database`。`FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) == false` → `.notice`、details `[DiagnosticTexts.dbNotCreated]`（**作らない**）
2. `guard let ro = ReadOnlyStore.open(url: url) else { return .fail(details: [DiagnosticTexts.dbUnopenable]) }`
3. `guard let qc = try? ro.quickCheck() else { return .fail(details: [DiagnosticTexts.dbUnopenable]) }`（投げたら「開けない」。空の結果を quick_check の文言で出さない）。`qc != "ok"` → `.fail`、details `[DiagnosticTexts.dbQuickCheck(qc)]`
4. `let applied = (try? ro.appliedMigrations()) ?? []`。`applied != Store.migrationIdentifiers` → `.fail`、details `[DiagnosticTexts.dbMigrations(applied: applied.last, expected: Store.migrationIdentifiers.last)]`
5. `.ok`、details `[DiagnosticTexts.dbOK(applied.last ?? "")]`

**DR-13**（取り下げ。PLAN F-61。作らない）

**DR-03 空き容量**
1. `guard let c = ctx.config else { … .fail(configMissing) }`
2. `let r = SpaceCheck(config: c.audio, layout: ctx.deps.layout).check(durationSeconds: DiagnosticTexts.probeDurationSeconds)`（`probeDurationSeconds = 1800`）
3. `.ok` → `.ok`、details `[DiagnosticTexts.spaceOK(freeBytes)]`（`freeBytes` は `statfs` から。取れなければ details を空にする）
4. `.insufficient(let m)` → **`.notice`**（PLAN §8.11 の「fail / notice」列は notice）、details `[m]`（§8.3 の文言をそのまま）

**DR-04 whisper-cli**
1. `let exe = ctx.deps.paths.whisperCLI`。ファイルが無い → `.fail`、details `[DiagnosticTexts.executableMissing(exe)]`
2. `let r = await ctx.deps.runner.run(ProcessSpec(executable: exe, arguments: ["--help"], environment: ProcessEnvironment.cLocale), timeout: .seconds(20))`
3. `r.termination != .exited(0)` → `.fail`、details `[DiagnosticTexts.helpFailed(r.termination)]`
4. `let missing = WhisperHelpCheck.missingVADFlags(helpOutput: r.stdoutText + r.stderrText)`
5. `missing.isEmpty` → `.ok`、details `[DiagnosticTexts.vadFlagsOK(WhisperHelpCheck.vadFlags.count)]`
6. `ctx.config?.transcription.vad.enabled == false` → `.notice`、details `[DiagnosticTexts.vadFlagsMissing(missing)]`（**VAD 無効なら無くても notice**）
7. それ以外 → `.fail`、details `[DiagnosticTexts.vadFlagsMissing(missing)]`

**DR-05 Whisper モデル** / **DR-06 VAD モデル** / **DR-08 LLM モデル**
共通の下請け `modelCheck(kind:entry:ctx:)`:
1. `entry == nil` → `.fail`、details `[DiagnosticTexts.modelNotSelected]`
2. `let url = ModelFiles.url(kind: kind, entry: entry, layout: layout)`。ファイルが無い → `.fail`、details `[DiagnosticTexts.modelMissing(entry.file)]`
3. サイズが `entry.bytes` と違う → `.fail`、details `[DiagnosticTexts.modelSize(actual, entry.bytes)]`
4. **SHA-256 の照合**（`ModelVerificationCache` を通す。PLAN §8.10）:
   - `stat` で `(inode, size, mtime)` を取り、`await cache.verifiedSHA256(path:inode:size:mtime:)` が在ればそれを使う
   - 無ければ `FileHasher.sha256(of: url, chunkBytes: config.audio.hashChunkBytes)` を `BlockingIO.run` で計算し、`await cache.record(…)`
   - 値が `entry.sha256` と違う → `.fail`、details `[DiagnosticTexts.modelSHA]`
5. `.ok`、details `[DiagnosticTexts.modelOK(entry.displayName)]`

- **DR-05**: `entry = catalog.entry(kind: .whisper, id: config.transcription.whisperModelID)`
- **DR-06**: `config.transcription.vad.enabled == false` → `.notice`、details `[DiagnosticTexts.vadDisabled]`（ASR-02 の逐語）。有効なら `modelCheck(kind: .vad, …)`
- **DR-08**:
  1. `config.llm.modelID == nil` → `.fail`、details `[DiagnosticTexts.llmNotSelected]`
  2. `custom:<sha>` なら: ファイル `ModelFiles.customLLMURL(id:layout:)` が在り、その SHA が `<sha>` と一致（**サイズの照合はしない**。カタログに `bytes` が無い）→ `.ok`、details `[DiagnosticTexts.customModelOK(sha 先頭 8), DiagnosticTexts.customModelUnsupported]`。
     メモリの確認は行わない（`minMemoryGB` が不明）
  3. カタログの ID なら `modelCheck(kind: .llm, …)` → `.ok` になったら、`ModelMemory.hasEnough(minMemoryGB: entry.minMemoryGB, physicalMemoryBytes: ctx.deps.physicalMemoryBytes)`（VDCore。T-30 §4.10b）が偽なら `.fail` に落とし、details に `DiagnosticTexts.notEnoughMemory(required: entry.minMemoryGB ?? 0, actual: ModelMemory.gb(ctx.deps.physicalMemoryBytes))` を足す（**式を書き直さない**。T-31 の `Picker` と T-22 のガードと同じ関数）
     （custom は `.notice`——PLAN §8.11 の「custom は notice」——だが、custom は 2 でメモリを見ないので `.notice` を出す場面が無い。**2 の details の 2 行目 `customModelUnsupported` を notice の代わりとし、結果は `.ok`**。§11 の 3 に書いた）

**DR-07 llama-server**
1. `let exe = ctx.deps.paths.llamaServer`。無い → `.fail`、details `[DiagnosticTexts.executableMissing(exe)]`
2. `--help` を実行（DR-04 と同じ形）。`.exited(0)` でなければ `.fail`
3. `let missing = LlamaArgs.missingFlags(helpOutput: r.stdoutText + r.stderrText)`
4. `missing.isEmpty` → `.ok`、details `[DiagnosticTexts.llamaFlagsOK(LlamaArgs.usedFlags.count)]`
5. そうでなければ `.fail`、details `[DiagnosticTexts.llamaFlagsMissing(missing)]`

**DR-10 Vault**
1. `guard let c = ctx.config else { … }`
2. `let st = VaultCheck.evaluate(path: c.vault.path, marker: c.vault.marker)`（**ファイルもフォルダも作らない**。NOTE-16）
3. `st == .notReadable(let e)` で `e == EPERM` → `.fail`、details `[st.message(path:marker:), DiagnosticTexts.tccFolders]`
4. `st != .available` → `.fail`、details `[st.message(path: c.vault.path ?? "", marker: c.vault.marker)]`
   （**「書けない」と「Vault でない」を別の文言で出す**——`VaultStatus.message` が既に別の文言を持つ。T-28 §4.1）
5. `access(path, W_OK) != 0` → `.fail`、details `[DiagnosticTexts.vaultNotWritable(path, errno)]`
6. `.ok`、details `[path]`

**DR-11 デバイスの列挙**
1. `guard let s = ctx.snapshot else { return .skip(details: [DiagnosticTexts.noSnapshot]) }`
2. `s.devices.isEmpty && s.unavailable.isEmpty` → `.skip`、details `[DiagnosticTexts.noDevice]`（**デバイス未接続なら skip**）
3. `let bad = s.unavailable.filter { $0.value == DetectionReason.notListable.rawValue }.keys` をバイト順に
4. `bad.isEmpty` → `.ok`、details `[DiagnosticTexts.devicesListed(s.devices.count)]`
5. そうでなければ `.fail`、details = 各 `name` について `DiagnosticTexts.notListable(name, errno: s.notListableErrno[name])`、末尾に `DiagnosticTexts.tccRemovableVolumes`
   （逐語: `システム設定 → プライバシーとセキュリティ → ファイルとフォルダ → VoiceDock → リムーバブルボリューム`）

**DR-12 ログイン項目**
- `ctx.loginItem == .enabled` → `.ok`、details `[DiagnosticTexts.loginItemEnabled]`
- それ以外 → **`.notice`**、details `[DiagnosticTexts.loginItem(ctx.loginItem)]`

**DR-15 inbox の取り残し**
1. `guard let ro = ReadOnlyStore.open(url: layout.database) else { return .ok(details: [DiagnosticTexts.leftoversNone]) }`（DB が無ければ取り残しも無い）
2. `let paths = (try? ro.inboxPaths(statuses: PartStates.inboxLeftover)) ?? []`
3. `let c = InboxScan.leftovers(layout: layout, relativePaths: paths)`
4. `c.count == 0` → `.ok`、details `[DiagnosticTexts.leftoversNone]`
5. そうでなければ **`.notice`**、details `[DiagnosticTexts.leftovers(count: c.count, bytes: c.bytes)]`（**自動では消さない**の一文を含む）

**DR-17 アプリの署名**
1. `let info = ctx.deps.signature.read(bundle: ctx.deps.bundleURL)`
2. `info.valid == false` → `.notice`、details `[info.message ?? DiagnosticTexts.signatureInvalid]`
3. `info.teamID == nil` → `.notice`、details `[DiagnosticTexts.adhocSignature]`（逐語: `ad-hoc 署名です。ビルドのたびにリムーバブルボリュームの許可が失効します`）
4. `.ok`、details `[DiagnosticTexts.signatureOK(info.teamID!)]`

**DR-14 元音声の削除**（`always: true`。**常に notice**。必ず最後）
1. `guard let c = ctx.config else { return .skip(details: [DiagnosticTexts.skipped]) }`（`always` の前提）
2. `let d = await ctx.deps.locks.display(config: c, snapshot: ctx.snapshot)`（`LockObserving` の既定実装。§4.11）
3. `.notice`、details = `d.lines`（**3 行。式も語も書き直さない**。§4.11 の `LockDisplay.lines` をそのまま）
4. `locks` が `DisabledLockObserver`（Phase 7）でも成り立つ: `readiness` は `.disabled`、`confState` は `.missing`、`reaper` は `.notInstalled` になり、3 行は組める（DR-14 は `always: true` なので設定さえ読めれば必ず出る）

---

### 4.5 `DiagnosticTexts.swift`（逐語）

```swift
// 診断の日本語のラベルと文言（PLAN §8.11）。ここ以外に書かない（CR-06）。
enum DiagnosticTexts {
    static let probeDurationSeconds: Double = 1800
    static func label(_ id: String) -> String
    …
}
```

ラベル（`label(_:)`）:

| id | ラベル |
|---|---|
| `DR-01` | `設定` |
| `DR-02` | `データベース` |
| `DR-03` | `空き容量` |
| `DR-04` | `whisper-cli` |
| `DR-05` | `Whisper モデル` |
| `DR-06` | `VAD モデル` |
| `DR-07` | `llama-server` |
| `DR-08` | `LLM モデル` |
| `DR-09` | `LLM の疎通` |
| `DR-10` | `Vault` |
| `DR-11` | `デバイスの列挙` |
| `DR-12` | `ログイン項目` |
| `DR-14` | `元音声の削除` |
| `DR-15` | `inbox の取り残し` |
| `DR-16` | `タイムゾーン` |
| `DR-17` | `アプリの署名` |

文言（逐語。`<…>` は差し込み）:

| 名前 | 値 |
|---|---|
| `skipped` | `先行する致命的な検査が失敗` |
| `configOK` | `違反はありません` |
| `configUnreadable` | `設定ファイルを読めません` |
| `configMissing` | `設定が読めていません` |
| `timeZoneUnresolved(_:)` | `タイムゾーン <id> を解決できません` |
| `dbNotCreated` | `まだ作られていません` |
| `dbUnopenable` | `読み取り専用で開けません` |
| `dbQuickCheck(_:)` | `PRAGMA quick_check が ok ではありません: <s>` |
| `dbMigrations(applied:expected:)` | `適用済みのマイグレーションが <applied> です（最新は <expected>）`（nil はどちらも `なし`） |
| `dbOK(_:)` | `quick_check ok、マイグレーション <last>` |
| `spaceOK(_:)` | `空き <x.x> GiB`（`StatusTexts.gib`） |
| `executableMissing(_:)` | `<path> がありません` |
| `helpFailed(_:)` | `--help が失敗しました（<終了の説明>）`（`exited(n)` → `exit <n>`、`signaled(n)` → `signal <n>`、`timedOut` → `時間切れ`、`spawnFailed(e)` → `起動できません（errno <e>）`） |
| `vadFlagsOK(_:)` | `VAD のフラグ <n> 個が在ります` |
| `vadFlagsMissing(_:)` | `VAD のフラグがありません: <flags を半角空白でつないだもの>` |
| `vadDisabled` | `無音から幻覚が生成され、13 倍以上遅くなります` |
| `llamaFlagsOK(_:)` | `使うフラグ <n> 個が在ります` |
| `llamaFlagsMissing(_:)` | `使えないフラグがあります: <flags を半角空白でつないだもの>` |
| `modelNotSelected` | `選ばれていません` |
| `llmNotSelected` | `LLM モデルが選ばれていません` |
| `modelMissing(_:)` | `<file> がありません` |
| `modelSize(actual:expected:)` | `サイズが <actual> バイトです（期待 <expected>）` |
| `modelSHA` | `SHA-256 が一致しません` |
| `modelOK(_:)` | `<displayName>（SHA-256 一致）` |
| `customModelOK(_:)` | `読み込んだモデル <sha 先頭 8>（SHA-256 一致）` |
| `customModelUnsupported` | `動作保証外のモデルです` |
| `notEnoughMemory(required:actual:)` | `メモリが足りません（<required> GB 以上が必要。この Mac は <actual> GB）` |
| `tccFolders` | `システム設定 → プライバシーとセキュリティ → ファイルとフォルダ で VoiceDock に許可してください` |
| `vaultNotWritable(_:errno:)` | `<path> に書き込めません（errno <n>）` |
| `noSnapshot` | `まだ走査していません` |
| `noDevice` | `デバイスが接続されていません` |
| `devicesListed(_:)` | `<n> 台を列挙できました` |
| `notListable(_:errno:)` | `<name> を列挙できません（errno <n>）`（errno が nil なら `（errno 不明）`） |
| `tccRemovableVolumes` | `システム設定 → プライバシーとセキュリティ → ファイルとフォルダ → VoiceDock → リムーバブルボリューム` |
| `loginItemEnabled` | `登録されています` |
| `loginItem(_:)` | `.requiresApproval` → `許可が要ります`、`.notRegistered` → `登録されていません`、`.notFound` → `アプリの場所が不明です` |
| `leftoversNone` | `ありません` |
| `leftovers(count:bytes:)` | `<n> 件 <x.x> GiB（自動では消しません）` |
| `signatureInvalid` | `署名が無効です` |
| `signatureUnreadable` | `署名を読めません` |
| `adhocSignature` | `ad-hoc 署名です。ビルドのたびにリムーバブルボリュームの許可が失効します` |
| `signatureOK(_:)` | `有効（Team ID <id>）` |
| `probeOK(model:seconds:)` | `<model>（<x.x>s）` |
| `probeFailed(_:)` | `<message>` |
| `probeStopped` | `終了中のため実行しませんでした` |

---

### 4.6 `LLMProbeCheck.swift`（DR-09）

```swift
// DR-09: LLM に実リクエストを 1 回送る（PLAN §8.11。別のボタン。Worker の直列ループで実行する）。
struct LLMProbeCheck: Sendable {
    let ctx: TickContext
    func run() async -> DiagnosticResult
}
```

**手順**:
1. `let c = ctx.config`。`guard let id = c.llm.modelID else { return fail(DiagnosticTexts.llmNotSelected) }`
2. モデルの在否とメモリと llama-server: **解析のガード（T-22 の `LLMGuard`）をそのまま呼ぶ**（式を書き直さない）。`ctx.pauses`（前回の tick の結果）は見ず、書きもしない:
   使い捨ての `PauseBook`（何も書かない `LogSink` の `AppLog` を渡す。`pipeline_paused` を出さない）を持つ `TickContext` を作って `LLMGuard(ctx:).evaluate()` を呼ぶ。
   `nil` なら、その `PauseBook.paused`（`PauseReason.allCases` の順）の先頭 `r` で `.fail`、details `[StatusTexts.pauseWord(r)]`（T-30 §4.10 の 11 語）
   （`LLMReadiness.check` は T-22 が作っていない。`LLMGuard` は VDPipeline の internal で同じモジュールから呼べるので公開 API を足さない。§10 の 16）
3. `let model = target.model`（`LLMGuard` が返す `LLMTarget`。custom なら `customLLMURL` が入っている）
4. `let started = ctx.deps.clock.uptime()`
5. `switch await ctx.deps.llama.ensureRunning(model: model, modelID: id, config: c.llm)`:
   - `.failure(let f)` → `.fail`、details `[f.message]`
   - `.success(let handle)`: 続ける
6. `let transport = ctx.deps.chatTransportFactory(handle, c.llm)`
7. `switch await transport.complete(system: LLMProbe.system, user: LLMProbe.user)`:
   - `.content` → `.ok`、details `[DiagnosticTexts.probeOK(model: id, seconds: 経過)]`
   - `.failure(let f)` → `.fail`、details `[f.message]`
8. 経過秒 = `(ctx.deps.clock.uptime() - started)` を秒の `Double` にして小数 1 桁

- **llama-server を止めない**（`processReadySessions` の終わりで Worker が止める。T-22）。`pendingJobs` の段は `processReadySessions` より後なので、DR-09 で起動したサーバは**次の tick の `processReadySessions` の終わりまで残る**。`LlamaServerSupervisor` の単一インスタンスを使う（PLAN §8.11）
- 応答の中身は見ない（`{"ok": true}` を要求しない。**疎通の確認**であり、JSON の検証は AnalysisCall の仕事）

---

### 4.7 `Worker.swift` / `Worker+Jobs.swift` への追加

```swift
// Worker.swift に足す
public enum WorkerJob: Sendable {
    /// DR-09。返事は Worker の文脈で呼ばれる（受け手が MainActor へ移す）
    case llmProbe(reply: @Sendable (DiagnosticResult) -> Void)
    // T-41 が case backlog(BacklogAction) / case resolveAbsent(BacklogAction) を足す
}

extension Worker {
    public func enqueue(_ job: WorkerJob) async {
        pendingJobs.append(job)
        wakeContinuation?.yield(())
    }
}
```
actor の状態に `var pendingJobs: [WorkerJob] = []` を足す（T-18 §4.8 の「T-32 がジョブの列を足す」）。

```swift
// Worker+Jobs.swift（T-18 が空で置いた段の中身）
extension Worker {
    func stagePendingJobs(_ ctx: TickContext) async {
        let jobs = pendingJobs
        pendingJobs = []
        for job in jobs {
            switch job {
            case .llmProbe(let reply):
                if ctx.stop.isSet { reply(DiagnosticResult(id: "DR-09", status: .skip, label: DiagnosticTexts.label("DR-09"), details: [DiagnosticTexts.probeStopped])); continue }
                reply(await LLMProbeCheck(ctx: ctx).run())
            }
        }
    }
}
```

- **停止要求が来ていても返事は必ず返す**（`.skip` で返す）。返事を返さないと、パネルが「実行中…」のまま固まる
  - 設定エラー中（`config.current() == nil`）の `tick` は段を回さないので、`guard let config` の else で列を空にし、各仕事に `.fail`（details `[DiagnosticTexts.configMissing]`。`LLMProbeCheck.unavailable`）で返事をする（`static func replyUnavailable(_ job: WorkerJob)`。`replyStopped` と同じ形）
  - `tick` は `stop.isSet` なら段を回さないので、`stagePendingJobs` の分岐だけでは足りない。`enqueue` は `stop.isSet` なら列に入れずにその場で `.skip` を返し、
    `requestStop()` は列に残っている仕事にも `.skip` を返して列を空にする（どちらも `static func replyStopped(_ job: WorkerJob)`、返す値は `LLMProbeCheck.stopped` の 1 か所）
- 仕事は**入れた順に 1 回ずつ**実行される。`pendingJobs` を先に空にしてから回す（実行中に入った仕事は次の tick）
- この段は snapshot の新鮮さによらず毎 tick 行う（T-18 §4.8 の並び）

---

### 4.8 `AttentionItems.swift`

```swift
// 要対応（PLAN §8.11 の表）。**利用者の操作が要るものだけ**（OPS-12）。
import VDCore
import VDDevice
import VDNotes

public enum AttentionAction: Equatable, Sendable {
    case revealConfig          // 設定ファイルを Finder で表示
    case reloadConfig          // 設定を読み直す
    case chooseVault           // Vault を選び直す
    case openSystemSettings    // システム設定を開く
    case openModels            // モデルの節を開く
    case openDeletionFlow      // 有効化フローを開く
    case runDiagnostics        // 「詳細」を開いて診断を実行する（PLAN §8.11 の toolMissing の操作）
    case openDetails           // 「詳細・診断」を開く（F-69 の undeletableSources・F-75 の rawNoteBlocked の操作）
}

/// PLAN §8.11 の表の 1 行。宣言順 = 表示順。
public enum AttentionItem: Equatable, Sendable {
    case configInvalid
    case vaultNotConfigured
    case vaultUnavailable(VaultStatus)
    case modelMissing(ModelKind)
    case llmNotSelected
    case llmInsufficientMemory
    case toolMissing(ToolKind)              // whisper-cli / llama-server（§11 の 2）
    case deviceNotListable(String)
    case deviceNeedsReplug(String)
    case deviceNameInvalid(String)
    case ingestSilent
    case diskSpaceLow
    case lockMismatch
    case reaperUpdateRequired
    case undeletableSources(Int)            // F-69。消せないまま完了にした録音で、デバイスの一覧にまだ在るものの本数（1 以上）
    case rawNoteBlocked(Int)                // F-75。書き直すと本文が消えるので Raw ノートを書かずに止めた Session の数（1 以上）

    public enum ToolKind: String, Equatable, Sendable { case whisperCLI, llamaServer }
    /// 表示の順（宣言順に振った 0 始まりの番号）
    public var order: Int { get }
    public var actions: [AttentionAction] { get }
}

public struct AttentionInput: Equatable, Sendable {
    public var configPresent = false
    public var violations: [ConfigViolation] = []
    public var ingestActivity: IngestActivity = .idle
    public var snapshot: DeviceSnapshot? = nil
    public var paused: [PauseReason] = []
    public var vault: VaultStatus = .notConfigured
    public var reaper: ReaperStatus = .notInstalled
    public var snapshotMaxAgeSeconds = 900
    public var undeletableSources = 0       // F-69。undeletableStillListed の件数（AppServices が DB と最新の snapshot から数える）
    public var rawNoteBlocked = 0           // F-75。rawNoteBlockedSessions の件数（AppServices が DB の FAILED の全件から数える）
    public var now: Instant
    public init(now: Instant)
}

public enum AttentionEvaluator {
    /// PLAN §8.11 の表の順に、条件を満たす項目だけを返す。
    public static func items(_ input: AttentionInput) -> [AttentionItem]
    /// 沈黙の検出（#117。コピー中に誤報しない）。テストから直接呼ぶ。
    public static func isIngestSilent(_ input: AttentionInput) -> Bool
    /// F-69。元ファイルがいまデバイスに在るか。snapshot が無い・unavailable・devices に無い・source_path が無いか空 → .unobserved、一覧に在る → .listed、無い → .notListed
    public static func sourcePresence(_ part: RecordingRow, snapshot: DeviceSnapshot?) -> SourcePresence
    /// F-69。消せないまま完了にした録音のうち sourcePresence が .listed のものだけ（抜いている間・一覧に無い・source_path が無いものは要対応に出さない）
    public static func undeletableStillListed(_ parts: [RecordingRow], snapshot: DeviceSnapshot?) -> [RecordingRow]
    /// F-75。書き直すと本文が消えるので Raw ノートを書かずに FAILED にした Part（PartSteps.isRawNoteBlocked）が居る Session の数
    public static func rawNoteBlockedSessions(_ parts: [RecordingRow]) -> Int
}
```

`actions`（PLAN §8.11 の「操作ボタン」の列）:

| 項目 | actions |
|---|---|
| `configInvalid` | `[.revealConfig, .reloadConfig]` |
| `vaultNotConfigured` | `[.chooseVault]` |
| `vaultUnavailable(.notReadable(EPERM))` | `[.chooseVault, .openSystemSettings]` |
| `vaultUnavailable(その他)` | `[.chooseVault]` |
| `modelMissing` / `llmNotSelected` / `llmInsufficientMemory` | `[.openModels]` |
| `toolMissing` | `[.runDiagnostics]`（PLAN §8.11 の「診断を実行」） |
| `deviceNotListable` | `[.openSystemSettings]` |
| `deviceNeedsReplug` / `deviceNameInvalid` | `[]`（手順を表示するだけ） |
| `ingestSilent` / `diskSpaceLow` / `lockMismatch` | `[]` |
| `reaperUpdateRequired` | `[.openDeletionFlow]` |
| `undeletableSources` | `[.openDetails]`（F-69） |
| `rawNoteBlocked` | `[.openDetails]`（F-75） |

**`items(_:)`**（この順に判定し、当たったものを並べる）:

| # | 項目 | 条件 |
|---|---|---|
| 1 | `configInvalid` | `!input.configPresent` |
| 2 | `vaultNotConfigured` | `input.paused.contains(.vaultNotConfigured)` |
| 3 | `vaultUnavailable(input.vault)` | `input.paused.contains(.vaultUnavailable)` |
| 4 | `modelMissing(.whisper)` | `input.paused.contains(.modelMissing)` |
| 5 | `modelMissing(.vad)` | `input.paused.contains(.vadModelMissing)` |
| 6 | `modelMissing(.llm)` | `input.paused.contains(.llmModelMissing)` |
| 7 | `llmNotSelected` | `input.paused.contains(.llmNotSelected)` |
| 8 | `llmInsufficientMemory` | `input.paused.contains(.llmInsufficientMemory)` |
| 9 | `toolMissing(.whisperCLI)` | `input.paused.contains(.whisperMissing)` |
| 10 | `toolMissing(.llamaServer)` | `input.paused.contains(.llamaServerMissing)` |
| 11 | `deviceNotListable(name)` | `snapshot.unavailable` の値が `not_listable` の名前（バイト順に 1 件ずつ） |
| 12 | `deviceNeedsReplug(name)` | 同じく `mount_name_mismatch` |
| 13 | `deviceNameInvalid(name)` | 同じく `invalid_device_id` |
| 14 | `ingestSilent` | `isIngestSilent(input)` |
| 15 | `diskSpaceLow` | `input.paused.contains(.diskSpaceLow)` |
| 16 | `lockMismatch` | `input.violations` に `rule == "CV-30"` か `"CV-33"` が在る |
| 17 | `reaperUpdateRequired` | `if case .versionMismatch = input.reaper` |
| 18 | `undeletableSources(n)` | `input.undeletableSources > 0`（F-69） |
| 19 | `rawNoteBlocked(n)` | `input.rawNoteBlocked > 0`（F-75） |

- **ガードの判定を書き直さない**（2〜10・15 は `PauseReason`（Worker の `PauseBook`）をそのまま読む。§9.1 原則 2 / CR-06）。
  `PauseReason.license` は要対応にしない（v1 は常に許可。PLAN §8.14）
- **要対応にしないもの**（PLAN §8.11 の最後）: FAILED の Part / Session（状態の詳細に出す）、ログイン項目（「はじめに」で選んだ後は出さない）。
  例外は F-75 の `rawNoteBlocked`（再評価しても利用者が直すまで同じ失敗を繰り返す。FAILED の Part そのものではなく Session の数だけを受ける）

**`isIngestSilent(_:)`**（PLAN §8.11 の `ingestSilent` の逐語。#117）:
```swift
guard let s = input.snapshot, !s.devices.isEmpty else { return false }   // デバイスが接続されている
guard !input.ingestActivity.scanning else { return false }               // 走査中でもなく
let last = max(s.completedAt.epochMillis, input.ingestActivity.lastActivityAt?.epochMillis ?? Int64.min)
return input.now.epochMillis - last > Int64(input.snapshotMaxAgeSeconds) * 1000
```
- **`>` であって `>=` ではない**（`snapshotMaxAgeSeconds` ちょうどは沈黙ではない。`DeviceSnapshot.isFresh` が `<=` を新鮮としているのと裏表になる）
- **`lastActivityAt` を足すのが #117 の対策**: 1 日分のコピーが 900 秒を超えても、コピーが進んでいる限り `lastActivityAt` が更新されるので誤報しない

---

### 4.9 `InboxScan.swift` と `StatusReport.swift`

```swift
// inbox の中身を数える（読むだけ。DR-15 と状態の詳細が共有する。#120）。
public struct InboxCounts: Equatable, Sendable {
    public let pendingCount: Int
    public let pendingBytes: Int64
    public let leftoverCount: Int
    public let leftoverBytes: Int64
    public static let empty = InboxCounts(pendingCount: 0, pendingBytes: 0, leftoverCount: 0, leftoverBytes: 0)
}

public enum InboxScan {
    /// relativePaths は DB の inbox_path（<HOME> からの相対）。存在する通常ファイルだけを数える。
    public static func leftovers(layout: HomeLayout, relativePaths: [String]) -> (count: Int, bytes: Int64)
    /// inbox 配下の *.wav を再帰で数え、leftovers に当たるものを除いたものを「処理待ち」にする。
    public static func counts(layout: HomeLayout, leftoverRelativePaths: [String]) -> InboxCounts
    /// 通常ファイルのサイズの合計（再帰。読めないものは飛ばす）
    public static func directoryBytes(_ url: URL) -> Int64
}
```
- **取り残しを処理待ちに数えない**（#120。voicedock `status.py:424-467`。2026-09-15 に実機で 259 MB を `1 parts pending` と報告し続けた）
- 名前が規則に合わないファイルも「ディスクは使っている」ので `pending` に数える（voicedock と同じ）
- 対象の状態は `PartStates.inboxLeftover`（VDCore。`terminal − {FAILED}`）。**ここで集合を書き直さない**

```swift
// 「状態の詳細」（PLAN §8.12。voicedock status.py 相当）。DB が無ければ全 0。DB を作らない。
public struct StatusReport: Equatable, Sendable {
    public struct FailedPart: Equatable, Sendable {
        public let partkey: String
        public let startedAt: String
        public let errorCode: String?      // DB の error_code の**生の文字列**（`RecordingRow.errorCodeRaw`。未知のコードもそのまま出す。M-1）
        public let retryCount: Int
        public init(partkey:startedAt:errorCode:retryCount:)
        /// 「<yyyy-MM-dd HH:mm>  <error_code か unknown>  retry <n>/<max>」（間は半角空白 2 つ）
        public func detail(maxAttempts: Int) -> String
    }
    public struct Device: Equatable, Sendable {
        public let deviceID: String
        public let writability: DeviceWritability
        public let freeBytes: Int64?
    }
    public let partCounts: [(PartStatus, Int)]        // 表示順。0 件も含む
    public let sessionCounts: [(SessionStatus, Int)]
    public let backlog: BacklogCounts                  // count / seconds / unknownDuration（下記。T-30 の AppSnapshot.swift から移す）
    public let failedParts: [FailedPart]               // 最大 20 件
    public let failedTotal: Int
    public let maxAttempts: Int
    public let deleteRequested: Int                    // queue/delete の *.json の数
    public let awaitingDeleteResult: Int               // 結果待ちの Part の数
    public let stagingBytes: Int64
    public let stagingMaxBytes: Int64
    public let inbox: InboxCounts
    public let devices: [Device]                       // バイト順。0 台なら空
    public let deviceSnapshotPresent: Bool             // false = まだ走査していない
    /// パネルに出す行（逐語。§4.9 の表）
    public var lines: [String] { get }
}

public enum StatusReporter {
    public static func build(layout: HomeLayout, config: AppConfig?, snapshot: DeviceSnapshot?, now: Instant, zone: ZonedTime) -> StatusReport
    /// Part の表示順（**宣言順だが SKIPPED を FAILED の前に置く**。PLAN §8.12）
    public static let partOrder: [PartStatus]
    public static let sessionOrder: [SessionStatus]
    /// エンティティごとの注記（**Part 用を Session へ流用しない**。voicedock status.py:78-90）
    public static let partNotes: [PartStatus: String]
    public static let sessionNotes: [SessionStatus: String]
}
```

- `BacklogCounts` は T-30 が VoiceDockApp（`AppSnapshot.swift`）に置いた internal の型だが、public の `StatusReport` の欄なので **VDPipeline の `StatusReport.swift` に移して public にする**
  （`public struct BacklogCounts: Equatable, Sendable { public var count: Int = 0; public var seconds: Double = 0; public var unknownDuration: Int = 0; public init(count:seconds:unknownDuration:)（既定値つき）; public static let empty }`）。パネルの上端（T-30）も同じ型を使う
- `partCounts` / `sessionCounts` はタプルの配列なので `Equatable` が合成されない。`StatusReport` は `==` を欄ごとに手で書く（タプルは `elementsEqual(_:by:)`）
- `StatusReport.Device` の init は internal（`StatusReporter` だけが作る）

`partOrder`: `PartStatus.allCases`（宣言順 = 付録 A.1）から `.skipped` と `.failed` を取り除き、末尾に `[.skipped, .failed]` を足す（**手で 12 個を並べない**。状態が増えたら自動で入る）。
`sessionOrder` = `SessionStatus.allCases`（並べ替えなし）。
`partNotes` = `[.failed: "次回接続時に再試行"]`。`sessionNotes` = `[:]`（**空でも明示する**。Part 用を流用させない）。
**voicedock の SKIPPED の「（無音）」は写さない**（重複・元ファイル不在も SKIPPED。PLAN §8.12）。

**`build(...)` の手順**:
1. `var counts = partOrder の全値 → 0`、`sessionCounts` も同様（**DB が無ければこのまま全 0**）
2. `if let ro = ReadOnlyStore.open(url: layout.database)`:
   - `if let c = try? ro.statusCounts() { counts をマージ }`
   - `if let b = try? ro.backlog() { backlog = … }`
   - `if let f = try? ro.failedParts(limit: 20) { failedParts = f.rows.map { FailedPart(partkey: $0.partkey, startedAt: $0.startedAt, errorCode: $0.errorCodeRaw, retryCount: $0.retryCount) }、failedTotal = f.total }`（**`errorCode?.rawValue` ではなく `errorCodeRaw`**。未知のコードを `unknown` に潰さない。T-11 §4.5）
   - `awaitingDeleteResult = (try? ro.awaitingDeleteResultCount()) ?? 0`
   - `let leftoverPaths = (try? ro.inboxPaths(statuses: PartStates.inboxLeftover)) ?? []`
   - （F-69）`undeletable = ((try? ro.completedParts(lastDetail: DeletionReason.notDeletable)) ?? []).map { UndeletablePart(partkey: $0.partkey, cause: $0.errorMessage, presence: AttentionEvaluator.sourcePresence($0, snapshot: snapshot)) }`（決着した Part を全部）。報告には先頭 20 件と総数
3. `inbox = InboxScan.counts(layout: layout, leftoverRelativePaths: leftoverPaths)`
4. `deleteRequested = queue/delete 直下の *.json の数`（`contentsOfDirectory`。読めなければ 0）
5. `stagingBytes = InboxScan.directoryBytes(layout.staging)`、`stagingMaxBytes = config?.audio.stagingMaxBytes ?? 0`
6. `maxAttempts = config?.retry.maxAttempts ?? 0`
7. `devices` = `snapshot?.devices` を鍵のバイト順に。各 `Device(deviceID:, writability: DeviceWritability.observe(deviceID:snapshot:), freeBytes:)`。`deviceSnapshotPresent = (snapshot != nil)`

**`lines`**（逐語。この順）:

| # | 行 |
|---|---|
| 1 | `Part` |
| 2… | `  <状態の rawValue>: <n>`（`partOrder` の順。0 件も出す）。注記が在れば `（<注記>）` を末尾に。例 `  FAILED: 2（次回接続時に再試行）` |
| — | `Session` |
| … | 同じ形（注記なし） |
| — | `未処理: ` ＋ `StatusTexts.backlogLine(count:seconds:unknownDuration:)` |
| — | `削除キュー: 要求 <n> 件、結果待ち <m> 件` |
| — | `staging: <x.x> GiB / <y.y> GiB`（`StatusTexts.gib` を 2 回） |
| — | `inbox: 処理待ち <n> 件 <x.x> GiB、取り残し <m> 件 <y.y> GiB` |
| — | `デバイス: ` ＋ 観測（下記） |
| — | `失敗した Part（<failedTotal> 件）`（`failedTotal == 0` ならこの行と以降を出さない） |
| … | `  <partkey>` と `    <detail>` の 2 行を `failedParts` の順に |
| — | `  … ほか <failedTotal - failedParts.count> 件`（超過があるときだけ） |
| — | （F-69）`消せなかった録音（<undeletableTotal> 件。消さずに完了にしたもの）`（0 件なら以降を出さない。失敗した Part の有無によらない） |
| … | `  <partkey>` と `    <原因>、<在否>` の 2 行を partkey 順に最大 20 件（原因は `StatusReporter.causeTexts`、付録 B.2 の reaper の理由語なら `削除モジュールの検証で拒否され続けた（<理由語>）`（F-78。`StatusReporter.causeText`）、どれでもなければ `原因不明`。在否は `presenceTexts`: `デバイスに在る` / `デバイスの一覧に無い` / `デバイスを観測できない`。文言は PLAN §8.12） |
| — | `  … ほか <undeletableTotal - undeletable.count> 件`（超過があるときだけ） |

- `デバイス:` の観測: `deviceSnapshotPresent == false` → `まだ走査していません`。`devices.isEmpty` → `StatusTexts.writabilityWord(.absent)`（`デバイス未接続`）。
  それ以外 → 各台の `"<id> " + StatusTexts.writabilityWord(w) + " 空き " + StatusTexts.gib(free)`（`freeBytes` が nil なら `空き 不明`）を `"、"` でつないだもの
- `FailedPart.detail(maxAttempts:)` = `startedAt` の先頭 16 文字の `T` を半角空白に替えたもの ＋ `"  "` ＋ `errorCode ?? "unknown"` ＋ `"  retry " + retryCount + "/" + maxAttempts`
  （voicedock `status.py:104-116` と同じ。**partkey を 1 行目、詳細を次の行**。70 文字の鍵を表の 1 列目に入れると読めない）
- `failedParts` の並びは `started_at` の昇順（`ReadOnlyStore.failedParts(limit:)` が保証する）

---

### 4.10 UI 側（`AttentionTexts` / `AppModel+Diagnostics` / 2 つの節）

`AppSnapshot` に足す:
```swift
    // T-32
    var attention: [AttentionItem] = []
    var statusReport: StatusReport? = nil      // 「詳細」を開いている間だけ作る（毎回 inbox を走査しない）
```
`AppServices` に足す:
```swift
    func runDiagnostics() async -> [DiagnosticResult]
    func enqueue(_ job: WorkerJob) async
    func statusReport() async -> StatusReport
    func openSystemSettingsPrivacyFilesAndFolders()   // NSWorkspace を開く口（テストでシステム設定を開かないため。LiveServices が URLComponents で作って開く）
```
`LiveServices`: `runDiagnostics` = `await Diagnostics(deps: context.diagnostics).run(loginItemStatus: context.loginItem.status())`、
`enqueue` = `await context.worker.enqueue(job)`、`statusReport` = `StatusReporter.build(layout:config:snapshot:now:zone:)`。
`AppContext` に `locks: any LockObserving` と `diagnostics: DiagnosticsDependencies` を足す。`Bootstrap`（T-30 §4.2）の変更:

- 手順 6（T-30 が「まだ作らない」と空けたところ）に `let locks: any LockObserving = DisabledLockObserver()` を入れる（§4.11。**何も読まない・何も起動しない**）
- 手順 12 の後に `let diagnostics = DiagnosticsDependencies(layout: layout, paths: paths, catalog: catalog, config: config, ingest: ingest, locks: locks, runner: runner, verificationCache: verificationCache, signature: SecAppSignatureReader(), bundleURL: Bundle.main.bundleURL, physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory, clock: clock, log: log.withCategory("pipeline"))` を組み立て、`AppContext` に渡す
- **`observeReaperConf` は `{ .missing }` のまま**（T-30 §4.2 の 7）。reaper.conf を読むのは T-36 から

`LiveServices.read` に足す（T-30 §4.8 の 6 の後。`AttentionInput` の public な init は `init(now:)` だけなので、欄に代入して作る）:
```swift
var attention = AttentionInput(now: s.now)
attention.configPresent = s.configPresent
attention.violations = s.configViolations
attention.ingestActivity = s.ingestActivity
attention.snapshot = s.device
attention.paused = s.worker.paused
attention.vault = s.vault
attention.reaper = await context.locks.reaperStatus()
attention.snapshotMaxAgeSeconds = config?.device.snapshotMaxAgeSeconds ?? 900
s.attention = AttentionEvaluator.items(attention)
```
`AppModel.refresh()` の 4 に `hasAttention = !snapshot.attention.isEmpty` を入れる（T-30 §4.11 が空けた場所）。

`AppModel` に足す:
```swift
    enum DiagnosticsPanelState: Equatable { case idle, running, done([DiagnosticResult]) }
    // 書くのは AppModel+Diagnostics（別ファイルの拡張）なので private(set) にできない（T-31 の欄と同じ）
    var diagnostics: DiagnosticsPanelState = .idle
    @ObservationIgnored var diagnosticsGeneration = 0                           // F-72。押すたび・閉じるたびに 1 増やす
    @ObservationIgnored var diagnosticsTask: Task<[DiagnosticResult], Never>?   // F-72。最後に起動した診断（閉じた後も走り続けうる）
    var probe: DiagnosticsPanelState = .idle   // DR-09（結果は 1 件）
    var detailsExpanded = false
    var modelsHighlighted = false
    var deletionHighlighted = false
    func setStatusReport(_ report: StatusReport?)   // snapshot は private(set) なので、状態の詳細を差し込む口を AppModel.swift に置く

    func runDiagnostics() async
    func runLLMProbe() async
    func toggleDetails() async
    func perform(_ action: AttentionAction)
```
- `runDiagnostics()`: `.running` にして `diagnostics = .done(await services.runDiagnostics())`。**実行中は二重に押せない**
  - （F-72 で直した手順）`guard diagnostics != .running else { return }` → `diagnostics = .running` → `diagnosticsGeneration += 1` して控える →
    `let previous = diagnosticsTask`、`let task = Task { _ = await previous?.value; return await services.runDiagnostics() }`、`diagnosticsTask = task` →
    `let results = await task.value` → 世代が控えと違えば捨てる（閉じた後に届いた結果）→ `diagnostics = .done(results)`。
    前の診断（閉じる前に始めたもの）が終わるまで次を起動しない（閉じて開き直した後の押下で 2 本同時に走らせない）
- `runLLMProbe()`: `probe = .running` → `await services.enqueue(.llmProbe(reply: { r in Task { @MainActor in self.receiveProbe(r) } }))`。
  `receiveProbe`: `guard probe == .running else { return }`（閉じた後の返事は捨てる）→ `probe = .done([r])`
- `toggleDetails()`: `detailsExpanded.toggle()`。真にしたときだけ `statusReport` を読み直す（**閉じている間は inbox も staging も走査しない**）。偽にしたら `setStatusReport(nil)`
- `refresh()`: `services.read` は `statusReport` を作らないので、`detailsExpanded` の間は前の `snapshot.statusReport` を持ち越す（偽なら nil）
- `panelDidClose()`: `probe = .idle` にする（閉じた後に届いた DR-09 の返事を `receiveProbe` が捨てる）。F-72: `diagnostics = .idle`、`diagnosticsGeneration += 1`（閉じた後に届いた診断の結果を `runDiagnostics` が捨てる。T-30 §4.11 の `panelDidClose()`）
- `perform(_:)`: `.revealConfig` → `revealConfigInFinder()`、`.reloadConfig` → `Task { await reloadConfig() }`、`.chooseVault` → `Task { await chooseVault() }`（T-31）、
  `.openSystemSettings` → `openSystemSettingsPrivacyFilesAndFolders()`（`NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)`。**`URL(string:)` は PT-02 の対象外**（`URLSession` ではない）だが、`!` を使わないよう `URLComponents` で作る）、
  `.openModels` → `modelsHighlighted = true`（節を目立たせるだけ。F-65 で `show(.main)` も）、`.openDeletionFlow` → `deletionHighlighted = true`（F-65 で `show(.deletion)` も）、
  `.runDiagnostics` → `Task { await show(.details); await runDiagnostics() }`（F-65。「詳細・診断」の画面へ移ってから診断を実行する。`show` は T-30 §4.11b）
- `runLLMProbe()` は押すたびに `probeGeneration`（`@ObservationIgnored var probeGeneration = 0`）を 1 増やし、返事のクロージャに開始時の世代を持たせる。`receiveProbe(_:generation:)` は `probe == .running` かつ世代が同じときだけ受け取る（`panelDidClose()` も世代を 1 増やす。閉じて押し直した後に届いた古い返事を捨てる）
- `toggleDetails()` は `await services.statusReport()` の後に `guard detailsExpanded` を置く（待っている間に閉じられたら差し込まない）
- `LiveServices.privacyFilesAndFoldersURL() -> URL?`（static。`URLComponents` で作る）を切り出し、`openSystemSettingsPrivacyFilesAndFolders()` はこれを開く

`AttentionTexts.swift`（VoiceDockApp。逐語）:

| 項目 | `title` | `detail` |
|---|---|---|
| `configInvalid` | `設定にエラーがあります` | `設定ファイルを直してから「設定を読み直す」を押してください` |
| `vaultNotConfigured` | `Vault が選ばれていません` | `「保存先（Vault）」で Obsidian の Vault を選んでください` |
| `vaultUnavailable(st)` | `Vault が使えません` | `st.message(path:marker:)`（`.notReadable(EPERM)` のときは ＋ 改行 ＋ `システム設定 → プライバシーとセキュリティ → ファイルとフォルダ で VoiceDock に許可してください`） |
| `modelMissing(.whisper)` | `Whisper モデルがありません` | `「モデル」で入手してください` |
| `modelMissing(.vad)` | `VAD モデルがありません` | 同上 |
| `modelMissing(.llm)` | `LLM モデルがありません` | 同上 |
| `llmNotSelected` | `LLM が選ばれていません` | `「モデル」で選んでください` |
| `llmInsufficientMemory` | `LLM にメモリが足りません` | `「モデル」で小さいモデルを選んでください` |
| `toolMissing(.whisperCLI)` | `whisper-cli がありません` | `アプリが壊れています。入れ直してください` |
| `toolMissing(.llamaServer)` | `llama-server がありません` | 同上 |
| `deviceNotListable(n)` | `<n> の中身を読めません` | `システム設定 → プライバシーとセキュリティ → ファイルとフォルダ → VoiceDock → リムーバブルボリューム` |
| `deviceNeedsReplug(n)` | `<n> を挿し直してください` | `同じ名前のボリュームがあるか、マウント先の名前が変わっています。取り外して、もう一度つなぎ直してください` |
| `deviceNameInvalid(n)` | `<n> は使えない名前です` | `Finder でデバイスの名前を「DJIMIC3」などに変えてから、つなぎ直してください（VoiceDock はデバイスに書き込みません）` |
| `ingestSilent` | `取り込みが止まっているようです` | `デバイスはつながっていますが、しばらく何も起きていません。ログを確かめてください` |
| `diskSpaceLow` | `空き容量が足りません` | `不要なファイルを消すか、staging の上限を上げてください` |
| `lockMismatch` | `削除の設定が食い違っています` | `アプリと reaper.conf の設定が合いません。「元音声の削除」を開いて無効化し直してください` |
| `reaperUpdateRequired` | `削除モジュールの更新が必要です` | `「元音声の削除」を開いて有効化をやり直してください` |
| `undeletableSources(n)` | `消せなかった録音 <n> 本` | `消せない状態が続いたので、元の録音を消さずに完了にしました。原因は「詳細・診断」の状態の詳細で確かめられます。Raw ノート・文字起こし・元のファイルの問題なら、直してから「過去分を削除対象にする」で再評価できます。削除モジュールの検証で拒否され続けたものは、再評価しても同じ結果になります。手で消す前に、Raw ノートと文字起こしが残っていることを確かめてください`（F-69） |
| `rawNoteBlocked(n)` | `書き直せない Raw ノート <n> 件` | `文字起こしを読めなくなった録音があり、Raw ノートを書き直すとその本文が消えるので、書き直さずに止めています（その後の録音はまだ Raw ノートに載っていません）。文字起こしのファイルをバックアップから戻すか、Obsidian でその Raw ノートの名前を変えてから（新しい Raw ノートが書かれ、古い本文は名前を変えたノートにそのまま残ります）、「詳細・診断」の「再試行」を押してください`（F-75） |

ボタンの文言（`AttentionTexts.button(_:)`）: `.revealConfig` → `設定ファイルを Finder で表示`、`.reloadConfig` → `設定を読み直す`、
`.chooseVault` → `Vault を選び直す`、`.openSystemSettings` → `システム設定を開く`、`.openModels` → `モデルの節を開く`、`.openDeletionFlow` → `有効化フローを開く`、`.runDiagnostics` → `診断を実行`（`Strings.buttonRunDiagnostics` をそのまま使う）、`.openDetails` → `詳細・診断を開く`（F-69。`AppModel.perform` は `show(.details)` だけ）。

`AttentionSection`: `snapshot.attention` が空なら何も出さない。そうでなければ `SectionBox(title: Strings.sectionAttention)` に 1 項目 1 ブロック（`title` を太字、`detail`、`actions` のボタン）。
F-65: 主画面では状態の直下のカードで、先頭の `AttentionSection.mainLimit`（2）件と `Strings.attentionMore(n)` のボタン（`show(.attention)`）。要対応の画面（`limit: nil`）では全件。件数の切り方は `static func split(_:limit:)`（T-30 §5.6）。
`DetailsSection`: （F-65 で `DisclosureGroup` をやめ、主画面の「詳細・診断」の行から開く別の画面の中身になった。状態の詳細はこの画面にいる間だけ読む。T-30 §4.11b）以下は実装時の形の記録。`DisclosureGroup(Strings.sectionDetails, isExpanded:)`。開いたら
`Button(Strings.buttonRunDiagnostics)`（結果は `mark + " " + label` と `details` を字下げ、末尾に `Diagnostics.summary`）、
`Button(Strings.buttonRunLLMProbe)`、`statusReport?.lines` の `Text`、`Button(Strings.buttonRetry)`（= `requeueManual()`）、
`Button(Strings.buttonRevealConfig)`・`Button(Strings.buttonRevealLogs)`・`Button(Strings.buttonReloadConfig)`、`Text(model.versionLine)`、
そして `BacklogControls(model: model)`（T-41 が足す）。

`Strings` に足す: `buttonRunDiagnostics` = `診断を実行`、`buttonRunLLMProbe` = `LLM の疎通確認`、`diagnosticsRunning` = `診断を実行しています…`、`probeRunning` = `LLM に問い合わせています…`、`labelStatusDetails` = `状態の詳細`。

### 4.11 `LockObserving.swift`（ロックの観測の口と Phase 7 の既定。00-api-map §11）

Phase 7（UI と診断）は Phase 8（削除）の型に依存しない。**ロックの観測の口と、それが返す値の型はここ（T-32）に置き**、
T-36 の `LockEvaluator` がこのプロトコルに準拠する（T-36 はこれらの型を**作り直さない**）。

```swift
// ロックの観測の口（PLAN §8.9.2・§8.9.8）。診断・状態の詳細・パネルが読む。
// Phase 7 は DisabledLockObserver（常に「削除は無効」）、Phase 8 で T-36 の LockEvaluator が差し替える。
import Foundation
import VDContract
import VDCore
import VDDevice

public enum DeletionReadiness: Equatable, Sendable {
    case configured
    case disabled(String)          // T-36 の DeletionReason の readiness の 5 語のどれか
}

public enum DeviceWritability: Equatable, Sendable {
    case absent                    // snapshot が無い、またはそのデバイスが snapshot に無い（未接続）
    case writable                  // readOnly == false（観測）
    case readOnly                  // readOnly == true（観測）
    case unknown                   // readOnly == nil（観測できない。「読み書き可能」に丸めない。#107 / #148）

    /// PLAN §8.9.2 の 2。snapshot の観測だけを見る（設定値 mountMode を見ない）
    public static func observe(deviceID: String, snapshot: DeviceSnapshot?) -> DeviceWritability {
        guard let observation = snapshot?.devices[deviceID] else { return .absent }
        switch observation.readOnly {
        case .some(false): return .writable
        case .some(true): return .readOnly
        case .none: return .unknown
        }
    }
}

/// reaper の実行ファイルの状態（常時表示とキャッシュ）。
public enum ReaperStatus: Equatable, Sendable {
    case notInstalled
    case signatureInvalid
    case versionMismatch(found: String?)   // --version の stdout から末尾の "\n" を 1 つ除いたもの。読めなければ nil
    case valid(version: String)
}

/// ある時点のロックの観測（削除条件の 1 回の評価に渡す値）。
public struct LockObservation: Equatable, Sendable {
    public let readiness: DeletionReadiness
    public let snapshot: DeviceSnapshot?
    /// reaper の設定ファイルの VOLUMES_ROOT（reaper が開くのと同じボリュームの親。事前確認もここを開く）。設定が読めなければ nil
    public let volumesRoot: String?
    /// 設定ファイルの状態（表示の 1 行目。PT-11 のため `reaperConf` という名前にしない）
    public let confState: LockDisplay.ConfState
    public init(readiness: DeletionReadiness, snapshot: DeviceSnapshot?, volumesRoot: String?, confState: LockDisplay.ConfState)
    public func writability(_ deviceID: String) -> DeviceWritability {
        DeviceWritability.observe(deviceID: deviceID, snapshot: snapshot)
    }
    /// `locks.allReleased(for:)`（PLAN §8.9.2）= readiness == .configured && writability == .writable
    public func allReleased(for deviceID: String) -> Bool {
        readiness == .configured && writability(deviceID) == .writable
    }
    /// 鍵のバイト順の一覧（snapshot が無ければ nil）。表示の 3 行目が使う
    public var devices: [LockDisplay.Device]? { … }
}

/// パネルの「元音声の削除」と DR-14 に出す 3 つのロックの個別表示（PLAN §8.9.8）。設定値と観測値を並べる。
public struct LockDisplay: Equatable, Sendable {
    public enum ConfState: Equatable, Sendable { case enabled, disabled, missing, invalid }
    public struct Device: Equatable, Sendable {
        public let deviceID: String
        public let writability: DeviceWritability
        public init(deviceID: String, writability: DeviceWritability)
    }
    public let appEnabled: Bool
    public let confState: ConfState         // reaper の設定ファイルの状態（PT-11 のため `reaperConf` という名前にしない）
    public let reaper: ReaperStatus
    public let mountMode: String            // config.device.mountMode のまま
    public let devices: [Device]?           // nil = snapshot が無い（観測なし）、[] = 0 台
    public let readiness: DeletionReadiness
    public init(appEnabled: Bool, confState: ConfState, reaper: ReaperStatus, mountMode: String, devices: [Device]?, readiness: DeletionReadiness)
    /// 3 行（逐語。下の表）
    public var lines: [String] { get }
}

/// ロックの観測の口。DiagnosticsDependencies・StatusReporter・パネルはこれだけを見る。
public protocol LockObserving: Sendable {
    func observe(config: AppConfig, snapshot: DeviceSnapshot?) async -> LockObservation
    func reaperStatus() async -> ReaperStatus
}

extension LockObserving {
    /// 3 行の個別表示（PLAN §8.9.8）。**式はここ 1 か所**（DR-14・T-40 のパネルが共有し、書き直さない）。
    public func display(config: AppConfig, snapshot: DeviceSnapshot?) async -> LockDisplay {
        let observation = await observe(config: config, snapshot: snapshot)
        return LockDisplay(
            appEnabled: config.cleanup.deleteSourceAudio,
            confState: observation.confState,
            reaper: await reaperStatus(),
            mountMode: config.device.mountMode,
            devices: observation.devices,
            readiness: observation.readiness)
    }
}

/// Phase 7 の既定（削除の機能がまだ無い間）。常に「削除は無効」。何も読まない・何も起動しない。
public struct DisabledLockObserver: LockObserving {
    /// T-36 の `DeletionReason.deleteSourceAudioDisabled` と同じ語。T-36 がこのファイルを変更して
    /// `DeletionReason.deleteSourceAudioDisabled` を参照するように直す（CR-06。T-36 §4.2）。
    public static let disabledReason = "delete_source_audio_disabled"
    public init()
    public func observe(config: AppConfig, snapshot: DeviceSnapshot?) async -> LockObservation {
        LockObservation(readiness: .disabled(Self.disabledReason), snapshot: snapshot, volumesRoot: nil, confState: .missing)
    }
    public func reaperStatus() async -> ReaperStatus { .notInstalled }
}
```

- `LockObservation.devices`: `snapshot` が nil なら nil。在れば `snapshot.devices.keys` を **UTF-8 のバイト順**に並べ、各 `LockDisplay.Device(deviceID: id, writability: DeviceWritability.observe(deviceID: id, snapshot: snapshot))`
- `LockDisplay.lines`（逐語。区切りの `, ` は半角のカンマと空白、括弧は全角 `（` `）`。`ロック 1  :` はコロンの前に空白 2 つ）:

| 行 | 形 |
|---|---|
| 1 | `"ロック 1  : アプリ=" + (appEnabled ? "有効" : "無効") + ", reaper.conf=" + 語`（語: enabled `有効`・disabled `無効`・missing `無し`・invalid `不正`） |
| 2 | `"ロック 2-A: 削除モジュール=" + 語`（notInstalled `未導入`、signatureInvalid `導入済み（署名 NG）`、valid(v) `"導入済み（署名 OK, 版 " + v + "）"`、versionMismatch(f) `"導入済み（署名 OK, 版 " + (f ?? "不明") + "）。削除モジュールの更新が必要です"`） |
| 3 | `"ロック 2-B: 設定=" + mountMode + ", " + 観測`（観測: devices が nil → `観測=不明`、`[]` → `デバイス未接続`、それ以外 → 各デバイスの `id + "=" + 語 + "（観測）"` を `", "` でつなぐ。語: writable `読み書き可能`・readOnly `読み取り専用`・unknown `不明`（absent は devices に現れない）） |

  例（PLAN §8.9.8）: `ロック 1  : アプリ=有効, reaper.conf=有効` / `ロック 2-A: 削除モジュール=導入済み（署名 OK, 版 1.0.0）` / `ロック 2-B: 設定=rw, DJIMIC3=読み書き可能（観測）`
- **PT-11**: このファイルは許可場所ではないので、識別子 `reaperConf` を使わない（`confState`）。文字列 `"reaper.conf="` は表示の文言なので当たらない（PLAN §9.4 の照合はトークン単位。コメント・文字列は対象外）
- T-36 がこのファイルに足すもの（§4.11 は Phase 7 の形）: `DisabledLockObserver.disabledReason` を `DeletionReason.deleteSourceAudioDisabled` に置き換える。**型の定義は動かさない**

### 4.12 `StatusTexts.writabilityWord(_:)`（T-30 から移したもの）

T-30 の `StatusTexts`（VDPipeline）に 1 つ足す。T-30 の時点では `DeviceWritability` が無かったので、型を作るこのチケットが足す（T-30 §4.10 の申し送り）。

```swift
    /// PLAN §8.9.8 の観測の表示語（#107 / #148）
    public static func writabilityWord(_ w: DeviceWritability) -> String {
        switch w {
        case .absent: "デバイス未接続"
        case .unknown: "不明"
        case .readOnly: "読み取り専用"
        case .writable: "読み書き可能"
        }
    }
```

- **`nil` を「読み書き可能」に丸めない。0 台を観測扱いにしない**（#107 / #148。voicedock `status.py:175-194`）
- `switch` に `default` を置かない（ケースが増えたらコンパイルで落ちる）
- §4.9 の `デバイス:` の行と §4.11 の `LockDisplay.lines` の 3 行目の語は、この関数を使う（4 語を 2 か所に書かない。CR-06）


## 5. テスト

### 5.1 `DiagnosticsRunTests.swift`（`@Suite("Diagnostics の実行規則")`）

`Diagnostics.checks` を差し替えられるよう、`internal init(deps:checks:)` を用意する（`@testable`）。

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `orderIsTheSpecOrder` / 「15 件が PLAN §8.11 の順」 | 既定の `checks` | `map(\.id) == ["DR-01","DR-16","DR-02","DR-03","DR-04","DR-05","DR-06","DR-07","DR-08","DR-10","DR-11","DR-12","DR-15","DR-17","DR-14"]` |
| `countIs15` / 「DR-09 を除いて 15 件」 | 同上 | `checks.count == 15`、`DR-09` と取り下げた `DR-13` を含まない |
| `onlyDR14IsAlways` / 「always は DR-14 だけ」 | 同上 | `checks.filter(\.always).map(\.id) == ["DR-14"]` |
| `fatalSetIsTheSpecSet` / 「致命は DR-01 / DR-16 / DR-02 の 3 つ」 | 同上 | `checks.filter(\.fatal).map(\.id) == ["DR-01","DR-16","DR-02"]` |
| `fatalFailSkipsTheRest` / 「致命の fail 以降は skip」 | 2 番目が fatal で fail を返す偽の `checks` 4 件 | 3・4 番目が `.skip`、details が `["先行する致命的な検査が失敗"]` |
| `alwaysRunsAfterFatalFail` / 「always は先行の fail でも実行する」 | 1 番目が fatal で fail、最後が `always` | 最後が `.notice`（実行された） |
| `alwaysSkipsWhenConfigIsNil` / 「設定が読めないときは always も skip」 | `config = nil`、1 番目が fatal で fail | 最後の `always` も `.skip` |
| `nonFatalFailDoesNotBlock` / 「致命でない fail は止めない」 | 1 番目が fatal でない fail | 2 番目が実行される |
| `summaryDoesNotCountSkip` / 「サマリは skip を数えない」 | ok 2・fail 1・notice 1・skip 3 | `合格 2・失敗 1・注意 1` |
| `summaryOfEmpty` / 「TEST-28 0 件」 | `[]` | `合格 0・失敗 0・注意 0` |
| `logsDiagnosticsCompleted` / 「終わりに 1 行だけ出す」 | `CapturingLogSink` | `diagnostics_completed passed=2 failed=1 notices=1` が 1 行、ほかの行は出ない |

### 5.2 `DiagnosticChecksTests.swift`（`@Suite("DR ごとの検査")`）

各 DR について **ok / notice / fail / skip のうち起こりうるものを全部**。`TempDirectory` で `<HOME>` を作り、`AppPaths(resources:helpers:)` を一時ディレクトリに向け、`ScriptedProcessRunner`（T-13）で `--help` を返す。

| 関数名 / 表示名 | 準備 | 期待（id・status・details の逐語） |
|---|---|---|
| `dr01OKWhenNoViolations` | 設定が読め違反 0 | `DR-01` `.ok` `["違反はありません"]` |
| `dr01FailListsEachViolation` | 違反 2 件 | `.fail`、details が 2 行で各 `rendered` |
| `dr01FailWhenUnreadable` | `config == nil`、違反も空 | `.fail` `["設定ファイルを読めません"]` |
| `dr16OK` | `timeZone = "Asia/Tokyo"` | `.ok` `["Asia/Tokyo"]` |
| `dr16Fail` | `timeZone = "Nowhere/Nope"` | `.fail` `["タイムゾーン Nowhere/Nope を解決できません"]` |
| `dr02NoticeWhenMissing` | DB ファイルが無い | `.notice` `["まだ作られていません"]`、**実行後も DB が無い** |
| `dr02OK` | `Store` で 1 回作った DB | `.ok`、details が `quick_check ok、マイグレーション ` で始まる |
| `dr02FailOnBadMigrations` | `appliedMigrations` が最新でない DB（`Store` の internal init で古い migrator を使う） | `.fail`、details が `適用済みのマイグレーションが ` で始まる（知らない識別子は GRDB の `appliedMigrations` に現れないので `適用済みのマイグレーションが  です（最新は v1_initial）`） |
| `dr03OK` | 空き容量が十分な一時ディレクトリ | `.ok`、details が `空き ` で始まる |
| `dr03NoticeWhenStagingOverLimit` | `stagingMaxBytes` を 1 にする | `.notice`、details が `staging 使用量 ` で始まる（§8.3 の文言） |
| `dr04FailWhenMissing` | `whisper-cli` を置かない | `.fail` `["<path> がありません"]` |
| `dr04FailWhenHelpFails` | exit 2 | `.fail` `["--help が失敗しました（exit 2）"]` |
| `dr04OKWithAllVADFlags` | `WhisperHelpCheck.vadFlags` を全部含む help | `.ok` `["VAD のフラグ 6 個が在ります"]` |
| `dr04NoticeWhenVADDisabled` | フラグ欠け＋`vad.enabled = false` | `.notice` |
| `dr04FailWhenVADEnabled` | フラグ欠け＋`vad.enabled = true` | `.fail` |
| `dr05OK` / `dr05FailMissing` / `dr05FailSHA` | モデルを置く / 置かない / 中身を変える | `.ok` / `.fail`（逐語 3 通り） |
| `dr05UsesTheVerificationCache` | 2 回実行し `ModelVerificationCache` に記録させる。1 回目の後に inode・サイズ・mtime を保ったまま中身だけ変える（`FileHandle(forUpdating:)` で上書きし mtime を戻す） | 2 回目も `.ok`（記録を使いハッシュを計算し直していない。`FileHasher` を差し替える口は作らない） |
| `dr06NoticeWhenDisabled` | `vad.enabled = false` | `.notice` `["無音から幻覚が生成され、13 倍以上遅くなります"]` |
| `dr06OK` / `dr06Fail` | VAD 有効でモデル在り / 無し | |
| `dr07FailWhenMissing` / `dr07FailWhenFlagsMissing` / `dr07OK` | `llama-server` を置く・help を作る | `.fail` / `.fail`（`使えないフラグがあります: `） / `.ok` |
| `dr08FailWhenNotSelected` | `llm.modelID = nil` | `.fail` `["LLM モデルが選ばれていません"]` |
| `dr08FailWhenNotEnoughMemory` | `minMemoryGB = 32`、`physicalMemoryBytes = 16 GiB`、ファイルと SHA は正しい | `.fail`、details に `メモリが足りません（32 GB 以上が必要。この Mac は 16 GB）` |
| `dr08OKForCustom` | `custom:<sha>` とその中身 | `.ok`、details が `読み込んだモデル ` と `動作保証外のモデルです` の 2 行 |
| `dr10OKWhenVaultAvailable` | `.obsidian/` 在り | `.ok` `[path]` |
| `dr10FailWhenMarkerMissing` | `.obsidian/` 無し | `.fail`、details が `に .obsidian/ がありません` を含む |
| `dr10FailWhenNotWritable` | `chmod 0o500` の Vault（`.obsidian` 在り） | `.fail`、details が `に書き込めません（errno ` を含む |
| `dr10CreatesNothing` | `.available` の Vault | 実行の前後で Vault の中身が同じ（NOTE-16） |
| `dr11SkipWhenNoSnapshot` | `snapshot = nil` | `.skip` `["まだ走査していません"]` |
| `dr11SkipWhenNoDevice` | `devices` も `unavailable` も空 | `.skip` `["デバイスが接続されていません"]` |
| `dr11OK` | 2 台 | `.ok` `["2 台を列挙できました"]` |
| `dr11FailWithErrno` | `unavailable = ["X": "not_listable"]`、`notListableErrno = ["X": EPERM]` | `.fail`、details が `X を列挙できません（errno 1）` と逐語の案内の 2 行 |
| `dr12OK` / `dr12NoticeForEachStatus` | `.enabled` / 残り 3 値 | `.ok` / `.notice`（逐語 3 通り） |
| `dr15OKWhenNone` | 取り残し 0 件 | `.ok` `["ありません"]` |
| `dr15NoticeWithCountAndBytes` | 終端状態の Part 2 件の inbox ファイルを置く | `.notice` `["2 件 0.0 GiB（自動では消しません）"]`、**実行後もファイルが残っている** |
| `dr17OK` | `FakeSignature`（valid・teamID あり） | `.ok` `["有効（Team ID ABCDE12345）"]` |
| `dr17NoticeForAdhoc` | valid・teamID nil | `.notice` `["ad-hoc 署名です。ビルドのたびにリムーバブルボリュームの許可が失効します"]` |
| `dr17NoticeForInvalid` | valid が偽 | `.notice` `["署名が無効です"]` |
| `dr14AlwaysNotice` | 任意（`locks` は `DisabledLockObserver`） | `.notice`、details が `locks.display(config:snapshot:).lines` と**同一の配列**（`LockDisplay` を直接作った期待と比べる。式を書き直していないこと） |
| `dr14HasThreeLines` | 既定 | `details.count == 3`、1 行目が `ロック 1  : ` で始まる |

### 5.3 `DiagnosticsNoWriteTests.swift`（`@Suite("診断は何も書かない")`）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `diagnosticsChangeNothingInHome` / 「OPS-14 `<HOME>` を書き換えない（-shm の索引を除く）」 | `<HOME>` に config・DB・inbox・staging・models を用意し、`run()` の前後で全パスの（相対パス・サイズ・mtime）の一覧を取る（`voicedock.sqlite-shm`（完全一致）だけは在否とサイズ。§11 の 8。WAL の共有メモリの索引は読み取り専用の接続でも読み手の印を書くので mtime が動く） | 前後で一致 |
| `diagnosticsChangeNothingInVault` / 「Vault にファイルもフォルダも作らない」 | `.obsidian/` だけの Vault | 同上 |
| `diagnosticsDoNotCreateTheDatabase` / 「DB を作らない」 | DB 無し | `run()` の後も `voicedock.sqlite` が無い |
| `diagnosticsDoNotCreateNoteFolders` / 「テンプレートのフォルダを作らない」 | `raw.folderTemplate` が `Daily/Voice/Raw/{yyyymmdd}` | Vault に `Daily/` ができていない |
| `statusReportChangesNothing` / 「状態の詳細も書かない」 | `StatusReporter.build` を呼ぶ | 同じ突き合わせで一致 |

### 5.4 `LLMProbeCheckTests.swift`（`@Suite("DR-09")`）

`PipelineWorld`（T-18）と `FakeLLMServer`（T-22）・`FakeChatTransport`（T-19）を使う。

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `probeOK` | 応答 `{"ok": true}`、`SteppingClock` で 1.5 秒進む | `DR-09` `.ok`、details `["<modelID>（1.5s）"]` |
| `probeFailWhenNotSelected` | `llm.modelID = nil` | `.fail` `["LLM モデルが選ばれていません"]` |
| `probeFailWhenModelMissing` | ファイルが無い | `.fail`、details が `LLM モデルがありません` |
| `probeFailWhenServerFails` | `ensureRunning` が `.failure` | `.fail`、details が `StageFailure.message` |
| `probeFailWhenTransportFails` | `complete` が `.failure` | 同上 |
| `probeDoesNotStopTheServer` | 成功した後 | `FakeLLMServer.stopCount == 0`（Worker が止める） |
| `probeUsesTheProbePrompts` | 成功 | `FakeChatTransport` が受けた `system == LLMProbe.system`、`user == LLMProbe.user` |
| `probeIgnoresTheBody` | 応答が `にゃー` | `.ok`（疎通の確認であって JSON の検証ではない） |

### 5.5 `WorkerJobsTests.swift`（`@Suite("Worker の仕事")`）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `probeRunsAsAJob` | `enqueue(.llmProbe(reply:))` → `tick()` | reply が 1 回、`DR-09` |
| `jobRunsOnceAcrossTicks` | enqueue → tick → tick | reply が 1 回 |
| `jobsRunInOrder` | 3 件 enqueue → tick | reply の順が enqueue の順 |
| `configErrorRepliesWithFail` / 「DR-09 設定エラー中の enqueue → tick は fail で返事をする」 | 設定ファイルを壊して読み直す（`current() == nil`）→ enqueue → tick | reply が `.fail` `["設定が読めていません"]`、列が空、`ensureRunning` は呼ばれない |
| `stopRepliesWithSkip` | (a) enqueue → `stop` の立った `TickContext` で `stagePendingJobs` を直接呼ぶ、(b) `requestStop()` の後に enqueue → tick、(c) enqueue → `requestStop()`（tick を回さない） | どれも reply が `.skip` `["終了中のため実行しませんでした"]`（**返事は必ず返る**） |
| `enqueueWakesTheLoop` | `run()` 中に enqueue（sleeper は `SuspendingSleeper`。`RecordingSleeper` は待たないので周期の tick と区別できない） | 30 秒待たずに tick が回り、返事が届く |
| `noJobsIsCheap` | 仕事 0 件で tick | reply も LLM の呼び出しも無い（TEST-28） |

### 5.6 `AttentionEvaluatorTests.swift`（`@Suite("AttentionEvaluator")`）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `emptyInputHasNoItems` / 「TEST-28 何も無ければ 0 件」 | `AttentionInput(now:)` に `configPresent = true` | `[]` |
| `configInvalid` | `configPresent = false` | `[.configInvalid]`、`actions == [.revealConfig, .reloadConfig]` |
| `vaultNotConfiguredFromPause` | `paused = [.vaultNotConfigured]` | `[.vaultNotConfigured]`、`actions == [.chooseVault]` |
| `vaultUnavailableCarriesStatus` | `paused = [.vaultUnavailable]`、`vault = .missingMarker` | `.vaultUnavailable(.missingMarker)` |
| `vaultEPERMOffersSystemSettings` | `vault = .notReadable(errno: EPERM)` | `actions == [.chooseVault, .openSystemSettings]` |
| `modelMissingPerKind` | `paused` に 3 つのモデルの理由 | `.modelMissing(.whisper)`・`.modelMissing(.vad)`・`.modelMissing(.llm)` がこの順 |
| `llmNotSelectedAndMemory` | `paused = [.llmNotSelected, .llmInsufficientMemory]` | 2 件、`actions` はどちらも `[.openModels]` |
| `toolMissing` | `paused = [.whisperMissing, .llamaServerMissing]` | `.toolMissing(.whisperCLI)`・`.toolMissing(.llamaServer)`、`actions` はどちらも `[.runDiagnostics]` |
| `licenseIsNotAnAttention` | `paused = [.license]` | `[]` |
| `deviceUnavailableReasonsSplit` | `unavailable = ["B": "not_listable", "A": "mount_name_mismatch", "C": "invalid_device_id"]` | `.deviceNotListable("B")`・`.deviceNeedsReplug("A")`・`.deviceNameInvalid("C")` がこの順（理由ごとに、名前はバイト順） |
| `unknownUnavailableReasonIsIgnored` | `unavailable = ["X": "no_recordings"]` | `[]` |
| `silentWhenStale` / 「沈黙: 接続中・走査していない・古い」 | 1 台、`scanning = false`、`completedAt` が 901 秒前、`lastActivityAt = nil` | `.ingestSilent` を含む |
| `notSilentWhileScanning` / 「#117 走査中は誤報しない」 | 同じで `scanning = true` | 含まない |
| `notSilentWhileCopying` / 「#117 コピー中は誤報しない」 | `completedAt` が 3600 秒前、`lastActivityAt` が 10 秒前 | 含まない |
| `notSilentAtExactlyMaxAge` / 「ちょうどは沈黙ではない」 | `completedAt` がちょうど 900 秒前 | 含まない |
| `notSilentWithoutDevice` / 「0 台なら沈黙ではない」 | `devices` が空 | 含まない |
| `notSilentWithoutSnapshot` / 「まだ走査していなければ沈黙ではない」 | `snapshot = nil` | 含まない |
| `diskSpaceLow` | `paused = [.diskSpaceLow]` | 含む |
| `lockMismatchFromCV30` / `lockMismatchFromCV33` | `violations` に `rule: "CV-30"` / `"CV-33"` | 含む |
| `noLockMismatchForOtherRules` | `rule: "CV-01"` | 含まない |
| `reaperUpdateRequired` | `reaper = .versionMismatch(found: "0.9.0")` | 含む、`actions == [.openDeletionFlow]` |
| `reaperValidIsQuiet` | `.valid(version: "1.0.0")` | 含まない |
| `orderFollowsTheSpecTable` / 「並びは §8.11 の表の順」 | 全部の条件を同時に立てる（F-69 で `undeletableSources = 2`、F-75 で `rawNoteBlocked = 1` も） | 19 件、`map(\.order)` が昇順で、`configInvalid` が先頭・`rawNoteBlocked(1)` が末尾 |
| `failedPartsAreNotAttention` / 「FAILED は要対応にしない（F-75 の本文を守って止めた Session の数だけは別の項目）」 | FAILED の Part が在る DB（`AttentionInput` に FAILED の Part を渡す口が無いことを型で確かめる。F-75 の `rawNoteBlocked` は Session の数だけを受ける） | `AttentionItem` に FAILED を表す case が無い（コンパイル時に保証。テストは `allCases` 相当の列挙で件数 16 を固定。F-61 で `coexistenceBlocked` を外し、F-69 で `undeletableSources`、F-75 で `rawNoteBlocked` を足した） |

### 5.7 `StatusReporterTests.swift`（`@Suite("StatusReporter")`）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `allZeroWithoutDatabase` / 「DB が無ければ全 0」 | 空の `<HOME>` | `partCounts` の 12 件が全部 0、`sessionCounts` の 13 件も 0、`backlog == .empty`、`failedTotal == 0`、**DB が作られていない** |
| `everyStatusAppearsEvenAtZero` / 「0 件の状態も出す」 | DISCOVERED の Part 1 件だけ | `partCounts.count == PartStatus.allCases.count`、DISCOVERED だけ 1 |
| `partOrderPutsSkippedBeforeFailed` / 「SKIPPED を FAILED の前に置く」 | — | `partOrder.suffix(2) == [.skipped, .failed]`、それ以外は `PartStatus.allCases` の順 |
| `sessionOrderIsDeclarationOrder` | — | `sessionOrder == SessionStatus.allCases` |
| `onlyPartFailedHasANote` / 「注記は Part の FAILED だけ」 | — | `partNotes == [.failed: "次回接続時に再試行"]`、`sessionNotes.isEmpty` |
| `sessionFailedHasNoNote` / 「Session の FAILED に注記を付けない」 | Session が FAILED 1 件 | その行に `（` が無い |
| `skippedHasNoSilenceNote` / 「（無音）を写さない」 | SKIPPED 3 件 | 行が `  SKIPPED: 3` ちょうど |
| `backlogLineIsShared` / 「未処理の行は StatusTexts と同じ」 | 6 件・11,520 秒・不明 1 | `未処理: 未処理 3.2 時間ぶん（6 件）、うち 1 件は長さ不明` |
| `failedPartsAscendingByStartedAt` / 「started_at 昇順」 | 3 件（順不同に挿入） | `failedParts.map(\.partkey)` が `started_at` 昇順 |
| `failedPartDetailFormat` / 「1 行目が partkey、2 行目が詳細」 | `startedAt = "2026-08-29T07:12:33+09:00"`、`errorCode = "WHISPER_TIMEOUT"`、`retryCount = 3`、`maxAttempts = 3` | `    2026-08-29 07:12  WHISPER_TIMEOUT  retry 3/3` |
| `failedPartUnknownErrorCode` / 「error_code が無ければ unknown」 | `errorCode = nil` | `  unknown  ` を含む |
| `failedPartKeepsUnknownCodeString` / 「`ErrorCode` に無いコードも生のまま出す（M-1）」 | DB の `error_code` が `FUTURE_CODE_X` の FAILED の Part | 行に `  FUTURE_CODE_X  ` を含む（`unknown` にしない）。`FailedPart.errorCode == "FUTURE_CODE_X"` |
| `failedPartsCapAt20` / 「21 件目以降は『… ほか』」 | 25 件 | `failedParts.count == 20`、行に `  … ほか 5 件` |
| `noFailedSectionWhenZero` / 「0 件なら見出しごと出さない」 | FAILED 0 件 | `lines` に `失敗した Part` が無い |
| `deleteQueueCounts` / 「要求ファイルと結果待ち」 | `queue/delete` に 2 つの `.json`、結果待ちの Part 1 件 | `削除キュー: 要求 2 件、結果待ち 1 件` |
| `deleteQueueIgnoresNonJSON` | `.json` 以外を混ぜる | 数に入らない |
| `stagingUsage` / 「staging の使用量と上限」 | 合計 1 GiB、上限 5 GiB | `staging: 1.0 GiB / 5.0 GiB` |
| `inboxSplitsPendingAndLeftover` / 「#120 処理待ちと取り残しを分ける」 | 終端の Part の `.wav` 1 件と、非終端の `.wav` 2 件 | `inbox: 処理待ち 2 件 <x.x> GiB、取り残し 1 件 <y.y> GiB`、**取り残しを処理待ちに数えない** |
| `deviceLineWhenNoSnapshot` | `snapshot = nil` | `デバイス: まだ走査していません` |
| `deviceLineWhenZeroDevices` / 「#148 0 台は観測ではない」 | `devices` が空の snapshot | `デバイス: デバイス未接続` |
| `deviceLineWordsFollowObservation` / 「#107 nil を読み書き可能に丸めない」 | `readOnly = nil` の 1 台 | `デバイス: DJIMIC3 不明 空き 4.2 GiB` |
| `deviceLineUnknownFreeSpace` | `freeBytes = nil` | `空き 不明` |
| `reportIsEquatable` / 「同じ入力なら等しい」 | 同じ `<HOME>` で 2 回 | 2 つの `StatusReport` が等しい（`refresh` で無駄に描き直さない） |

### 5.8 `InboxScanTests.swift`（`@Suite("InboxScan")`）

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `emptyInbox` / 「TEST-28 空」 | 何も無い | `InboxCounts.empty` |
| `countsNestedWav` / 「サブディレクトリの .wav も数える」 | 2 階層 | 件数とバイト数が合う |
| `leftoversAreExcludedFromPending` / 「#120」 | 3 件のうち 1 件が取り残し | `pendingCount == 2`、`leftoverCount == 1` |
| `missingLeftoverPathIsNotCounted` / 「DB に在ってファイルが無ければ数えない」 | 取り残しのパスが実在しない | `leftoverCount == 0` |
| `nonWavFilesAreIgnoredInPending` / 「.meta.json は数えない」 | `.meta.json` だけ | `pendingCount == 0` |
| `unreadableEntriesAreSkipped` / 「読めないものは飛ばす」 | `chmod 0o000` のサブディレクトリ | 投げない |
| `directoryBytesSumsRegularFilesOnly` / 「通常ファイルだけ足す」 | ファイル 2 つとサブディレクトリ | サイズの合計が一致 |

### 5.9 `AttentionTextsTests.swift` / `AppModelDiagnosticsTests.swift`

`AttentionTextsTests`: 16 の項目すべてについて `title` と `detail` が §4.10 の表と逐語で一致すること、`button(_:)` が 8 つの `AttentionAction` それぞれで逐語一致すること（`.runDiagnostics` → `診断を実行`、`.openDetails` → `詳細・診断を開く`）、
`AttentionItem` の全ケースに `title` が在ること（`switch` の網羅で保証。表の件数 16 を 1 本のテストで固定（F-61 で coexistenceBlocked を外し、F-69 で undeletableSources、F-75 で rawNoteBlocked を足した））。

`AppModelDiagnosticsTests`:

| 関数名 / 表示名 | 準備 | 期待 |
|---|---|---|
| `runDiagnosticsShowsResults` | `FakeServices` が 2 件返す | `diagnostics == .done([…])` |
| `runDiagnosticsIsNotStartedTwice` | 実行中にもう一度押す | `runDiagnostics` の呼び出しが 1 回 |
| `probeGoesThroughTheWorker` | `runLLMProbe()` | `enqueue(.llmProbe)` が 1 回、返事で `probe == .done([r])` |
| `lateProbeReplyIsDropped` | 返事の前に `panelDidClose()` | `probe == .idle` のまま |
| `staleProbeReplyIsDropped` | 押す → 閉じる → 押し直す → 1 回目の返事 → 2 回目の返事 | 1 回目の返事では `.running` のまま、2 回目の返事で `.done` |
| `privacyURLIsFixed` | `LiveServices.privacyFilesAndFoldersURL()` | `x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders` |
| `detailsLoadsTheReportOnlyWhenOpen` | `toggleDetails()` を 2 回 | `statusReport()` の呼び出しが 1 回（閉じたときは呼ばない） |
| `attentionSetsTheIcon` | `read` が `attention: [.diskSpaceLow]` を返す | `hasAttention == true`、`iconState == .attention` |
| `performActionsAreRouted` | 7 つの `AttentionAction` | それぞれ対応する操作が 1 回ずつ呼ばれる（`.runDiagnostics` は詳細が開き、`runDiagnostics` が 1 回） |

### 5.10 `LockObservingTests.swift`（`@Suite("LockObserving")`）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `disabledObserverIsAlwaysDisabled` | `DisabledLockObserver は常に削除無効` | `deleteSourceAudio = true`・`mountMode = "rw"` の設定と、`readOnly == false` のデバイス 1 台の snapshot | `observe(...).readiness == .disabled("delete_source_audio_disabled")`、`allReleased(for:) == false`、`reaperStatus() == .notInstalled`、`volumesRoot == nil` |
| `disabledObserverDisplaysThreeLines` | `DisabledLockObserver でも 3 行が組める（DR-14）` | 同上 | `display(config:snapshot:).lines` が 3 行。1 行目 `ロック 1  : アプリ=有効, reaper.conf=無し`、2 行目 `ロック 2-A: 削除モジュール=未導入`、3 行目 `ロック 2-B: 設定=rw, DJIMIC3=読み書き可能（観測）` |
| `displayWithoutSnapshotSaysUnknown` | `snapshot が無ければ観測=不明` | snapshot nil | 3 行目が `ロック 2-B: 設定=ro, 観測=不明`、`devices == nil` |
| `displayWithZeroDevices` | `0 台なら デバイス未接続`（TEST-28） | `devices` が空の snapshot | 3 行目が `ロック 2-B: 設定=ro, デバイス未接続`、`devices == []` |
| `writabilityObservesOnly` | `writability は観測だけを見る` | `readOnly` が `true` / `false` / `nil` / そのデバイスが無い | `.readOnly` / `.writable` / `.unknown` / `.absent` |
| `devicesAreInByteOrder` | `devices は鍵のバイト順` | 鍵が `b`・`a`・`A` の 3 台 | `["A", "a", "b"]` の順 |

### 5.11 `StatusTextsTests.swift` への追加（`@Suite("StatusTexts")`。T-30 が作ったファイル）

| 関数名 | 表示名 | 準備 | 期待 |
|---|---|---|---|
| `writabilityWords` | `#107 / #148 観測の 4 語` | `.absent` / `.unknown` / `.readOnly` / `.writable` | `デバイス未接続` / `不明` / `読み取り専用` / `読み書き可能` |


## 6. 破壊による証明

| # | 壊し方（1 か所） | 落ちるべきテスト |
|---|---|---|
| 1 | `Diagnostics.checks` の DR-14 を先頭に移す | `orderIsTheSpecOrder`（`alwaysRunsAfterFatalFail` は偽の `checks` を使うので落ちない。実装で確かめた） |
| 2 | DR-03 の `fatal` を真にする | `fatalSetIsTheSpecSet`（`nonFatalFailDoesNotBlock` は偽の `checks` を使うので落ちない） |
| 3 | `run` の `blocked` の判定から `check.always` を外す | `alwaysRunsAfterFatalFail` |
| 4 | `run` の `always` の `ctx.config != nil` を外す | `alwaysSkipsWhenConfigIsNil` |
| 5 | `counts` が skip を `passed` に数える | `summaryDoesNotCountSkip` |
| 6 | DR-02 で `ReadOnlyStore.open` の前にファイルの有無を見ない | `dr02NoticeWhenMissing`（`ReadOnlyStore.open` 自身が無いファイルを開かないので `diagnosticsDoNotCreateTheDatabase` は落ちない） |
| 7 | DR-04 の VAD 無効の分岐を消す（常に fail） | `dr04NoticeWhenVADDisabled` |
| 8 | DR-05 の SHA の照合を size の照合だけにする | `dr05FailSHA` |
| 9 | DR-05 が `ModelVerificationCache` を見ない | `dr05UsesTheVerificationCache` |
| 10 | DR-08 のメモリの確認を消す | `dr08FailWhenNotEnoughMemory` |
| 11 | DR-10 で `access(W_OK)` を見ない | `dr10FailWhenNotWritable` |
| 12 | DR-11 の「0 台なら skip」を消す | `dr11SkipWhenNoDevice` |
| 13 | DR-12 を fail にする | `dr12NoticeForEachStatus` |
| 14 | DR-15 を fail にする | `dr15NoticeWithCountAndBytes`（「自動で消す」は `Diagnostics/` に削除の API を書くことになり PT-17 が落とす。`diagnosticsChangeNothingInHome` は fail にしただけでは落ちない） |
| 15 | DR-17 で `teamID == nil` を ok にする | `dr17NoticeForAdhoc` |
| 16 | DR-14 が `LockDisplay.lines` を使わず自前で 3 行を組み立てる（語が 1 つでもずれたもの。完全に同じ文字列の写しは区別できない） | `dr14AlwaysNotice`（配列の一致） |
| 17a | `DisabledLockObserver.observe` が `.configured` を返す | `disabledObserverIsAlwaysDisabled`（`LockDisplay.lines` は readiness を出さないので `dr14AlwaysNotice` は落ちない） |
| 17b | `stagePendingJobs` が `stop.isSet` のとき返事を返さない | `stopRepliesWithSkip`（(a) の返事が空） |
| 18 | `stagePendingJobs` が `pendingJobs` を空にしない | `jobRunsOnceAcrossTicks` |
| 18a | `tick` の設定エラーの分岐で `replyUnavailable` を呼ばない（列に残す） | `configErrorRepliesWithFail` |
| 18b | `requestStop` が列を空にしない（残った仕事に返事をしない） | `stopRepliesWithSkip`（(c) の返事が空） |
| 19 | `LLMProbeCheck` が `llama.stop()` を呼ぶ | `probeDoesNotStopTheServer` |
| 20 | `isIngestSilent` から `!scanning` を外す | `notSilentWhileScanning` |
| 21 | `isIngestSilent` から `lastActivityAt` を外す | `notSilentWhileCopying` |
| 22 | `isIngestSilent` の `>` を `>=` にする | `notSilentAtExactlyMaxAge` |
| 23 | `AttentionEvaluator` が `paused` ではなく自前でモデルの在否を見る | （検出できない）**`AttentionInput` にファイルの口を持たせないことを型で守る**。§7 のチェックリスト |
| 23a | `toolMissing` の `actions` を `[]` にする | `toolMissing`（AttentionEvaluatorTests） |
| 24 | `lockMismatch` の条件に `CV-01` を足す | `noLockMismatchForOtherRules` |
| 25 | `AttentionEvaluator` が `.license` を出す | `licenseIsNotAnAttention` |
| 26 | `partOrder` を `PartStatus.allCases` のままにする | `partOrderPutsSkippedBeforeFailed` |
| 27 | `sessionNotes` に `.failed` の注記を入れる | `sessionFailedHasNoNote` |
| 28 | `partNotes` に `.skipped: "（無音）"` を足す | `skippedHasNoSilenceNote` |
| 29 | `failedParts(limit:)` の 20 を 100 にする | `failedPartsCapAt20` |
| 30a | `FailedPart` に `row.errorCode?.rawValue` を渡す（生の文字列を捨てる） | `failedPartKeepsUnknownCodeString` |
| 30b | `InboxScan.counts` が取り残しを pending から除かない | `leftoversAreExcludedFromPending`・`inboxSplitsPendingAndLeftover` |
| 31 | `StatusReporter` が DB を `Store` で開く | `allZeroWithoutDatabase`（DB ができる）と PT-17 |
| 32 | デバイスの行で `readOnly == nil` を `読み書き可能` にする | `deviceLineWordsFollowObservation` |
| 33 | 0 台を `不明` にする | `deviceLineWhenZeroDevices` |
| 34 | `writabilityWord` の `.unknown` を `読み書き可能` にする（T-30 の証明 11 を移したもの） | `writabilityWords` |

## 7. 受け入れ条件

- [ ] `make test` が通り、§5 の全テストが在る
- [ ] **PT-17 が通る**: `Sources/VDPipeline/Diagnostics/` に PT-01・PT-12 の API、`AtomicFile`、`Store(` が無い
- [ ] `DiagnosticsNoWriteTests` の 5 本が通る（`<HOME>` と Vault が 1 バイトも変わらない）
- [ ] 診断の件数が 15（DR-09 を入れて 16。取り下げた DR-13 は数えない）で、`docs/SPEC.md` の表・README の散文・`Diagnostics.checks.count` の 3 か所が一致する（文書テスト。§10.3）
- [ ] `AttentionItem` の全ケースに `AttentionTexts.title` と `actions` が在る（`switch` の網羅）
- [ ] `StatusReport.lines` が §4.9 の表と逐語で一致する
- [ ] `WorkerJob` に `.llmProbe` だけが在る（`.backlog` / `.resolveAbsent` は T-41）
- [ ] `make lint` が通る

## 8. SPEC の変更

**実装で分かったこと**: `docs/SPEC.md` には診断の表が既に `## S6. 診断 DR（PLAN §8.11）` として在る（`make-spec.py` が PLAN から作る。手で直さない）。
本チケットは SPEC を変えず、`SpecCoverage.activated` に `.dr` を足し（DR の表示名で始まるテストの ID の集合 = S6 の生きた ID の集合。DR-09 を含み DR-13 を含まない）、
`DiagnosticsRunTests.orderIsTheSpecOrder` が `SpecDocument.ids(.dr)`（DR-09 を除く）と `Diagnostics.checks` の順を突き合わせる。
下の S24〜S26 は `make-spec.py`（T-05）と PLAN の変更が要るので、本チケットでは行わず §10 の 15 に回した（元の案を残す）:

1. `## S24. 診断（DR）` — PLAN §8.11 の表を `| ID | 順 | 検査 | fail / notice | 致命 |` の 5 列で写す。`DiagnosticsRunTests` が `DR-\d+` の集合・順・`fatal` 列・`always`（DR-14）を `Diagnostics.checks` と突き合わせる。**件数の literal は README の 1 か所だけ**（§10.3）
2. `## S25. 要対応` — PLAN §8.11 の要対応の表を `| 項目 | 条件 | 操作ボタン |` で写す。`AttentionEvaluatorTests` が case の集合と順を突き合わせる
3. `## S26. 状態の詳細` — §4.9 の `lines` の書式を ```text ブロックで写す。`StatusReporterTests` が `spec_section_code` 相当（`SpecDocument.codeBlock(heading:language:)`）で突き合わせる

→ **issue #18（SPEC 同期の拡張。PLAN F-68）で検討し、足さなかった**: S24 は既存の `S6.` と同じ（照合は済んでいる）。S25 は PLAN §8.11 に表が在るが、1 行に複数の case（`vaultNotConfigured` / `vaultUnavailable`）と付随値（`modelMissing(kind)`）を持ち、`AttentionItem` は付随値を持つので case を列挙できない（テストの側に見本の列を手で持つと、case を足しても落ちない）。照合するなら `Sources/VDPipeline` に case の名前の列（例 `AttentionItem.Kind: CaseIterable`）を足す別の PR で行う。S26 は PLAN §8.12 の状態の詳細が散文の箇条書きで、書式の原本は本チケット §4.9 に在り PLAN に無い（機械的に写せない）。SPEC の番号 S24〜S26 は空けたまま（#18 は S10〜S13・S20〜S23 を使った）

## 9. マージ後にやること

1. T-41 が `WorkerJob` に `.backlog` / `.resolveAbsent` を足し、`stagePendingJobs` の `switch` に 2 ケースを足す
2. T-40 が `DetailsSection` の下に「元音声の削除」の有効化フローへの導線（`deletionHighlighted`）をつなぐ
3. T-43（README）が診断の件数 16 を 1 か所だけに書き、文書テストがここと突き合わせる
4. T-35 の E2E-04（診断）で、実機に DJI Mic 3 をつないだ状態の DR-11 が `.ok` になることを【利用者が行う】

## 10. API 地図への変更提案

1. §11 の `Diagnostics/` の行を 7 ファイルに分ける: `DiagnosticResult.swift`（`DiagnosticStatus` / `DiagnosticResult`）、`DiagnosticCheck.swift`、`DiagnosticsDependencies.swift`（`DiagnosticsDependencies` / `AppSignatureReading` / `AppSignatureInfo` / `SecAppSignatureReader`）、`Diagnostics.swift`、`DiagnosticChecks.swift`、`DiagnosticTexts.swift`、`LLMProbeCheck.swift`。`Diagnostics.init(deps: DiagnosticsDependencies)` と `summary(_:)` / `counts(_:)` を載せる
2. §11 の `AttentionItems.swift` を `AttentionItem`（14 ケース。`coexistenceBlocked` は取り下げ。PLAN F-61）・`AttentionAction`（7 ケース。`runDiagnostics` は toolMissing の「診断を実行」）・`AttentionInput`・`AttentionEvaluator.items(_:)` / `isIngestSilent(_:)` にする
3. §11 の `StatusReport.swift` を §4.9 の形（`StatusReport` / `StatusReport.FailedPart` / `StatusReport.Device` / `StatusReporter.build(layout:config:snapshot:now:zone:)` / `partOrder` / `sessionOrder` / `partNotes` / `sessionNotes`）にする
4. §11 に `InboxScan.swift`（`InboxCounts` / `InboxScan`。**作り手 T-32**、DR-15 と `StatusReporter` が使う）を足す。`InboxMaintenance.leftovers()` はこれを呼ぶよう T-18 側を直す（同じ数え方を 2 か所に持たない）
5. （T-30 §4.10 の `StatusTexts.pauseWord(_:)` をそのまま使う。新しい提案は無い）
6. §3 の `ReadOnlyStore` に `func inboxPaths(statuses: Set<PartStatus>) throws -> [String]`（`inbox_path` が NULL でない行の値。`<HOME>` からの相対）を足す（**T-32 が T-11 のファイルに足す**）
7. §3 の `Store` に `public static let migrationIdentifiers: [String]`（`Schema.migrator()` に登録した識別子の並び）を足す（DR-02 が最新かどうかを判定するため。**T-32 が T-11 のファイルに足す**）
8. §6 の `SpaceMath` に `public static func usedBytes(directory: URL) -> Int64` を足すか、`InboxScan.directoryBytes` に一本化する（今は `SpaceCheck` の内部に同じ走査が在る）
9. §8（VDLLM）か §11 に `LLMReadiness.check(config:layout:catalog:paths:physicalMemoryBytes:) -> PauseReason?`（T-22 の解析のガードの判定を関数にしたもの）を足し、DR-09 と Worker のガードが同じ関数を使うようにする（**T-22 が正**。T-22 が内部に持っているなら公開にする）
10. §11 の `Worker` の `WorkerJob` を `case llmProbe(reply: @Sendable (DiagnosticResult) -> Void)` だけにし、`.backlog` / `.resolveAbsent` は「T-41 が足す」と注記する
11. §12 に `AttentionTexts.swift`・`AppModel+Diagnostics.swift` を足す
12. （整合修正 H-3）§11 に `LockObserving.swift`（`LockObserving` / `DisabledLockObserver` / `LockObservation` / `LockDisplay` / `ReaperStatus` / `DeletionReadiness` / `DeviceWritability`。**作り手 T-32**、T-36 の `LockEvaluator` が準拠）を足し、`DiagnosticsDependencies.locks` を `any LockObserving` にする → 00-api-map §11 に反映済み。`display(config:snapshot:)` は `LockObserving` の既定実装（§4.11）で、地図の `LockEvaluator` の行の `display` と同じもの
13. （整合修正）`LockObservation` に `confState: LockDisplay.ConfState` を足し、`LockDisplay` の欄の名前を `reaperConf` から **`confState`** に替える（`LockObserving.swift` は PT-11 の許可場所ではない）。T-40 §4 の `display.reaperConf` もこの名前に直す
14. （整合修正 M-1）`StatusReport.FailedPart.errorCode` には `RecordingRow.errorCodeRaw`（生の文字列）を渡す（§4.9 の 2）
15. （実装で分かったこと）§8 の S24〜S26 は SPEC の S6 と重なる。S25（要対応）・S26（状態の詳細）を SPEC に足すなら PLAN の表と `make-spec.py` の変更が要る
16. （実装で分かったこと）§16 の `LLMReadiness.check`（T-22）は作られていない。DR-09 は VDPipeline の internal の `LLMGuard` を使い捨ての `PauseBook` で呼ぶ（§4.6）。§16 の行を「DR-09 は `LLMGuard` を共有する（公開しない）」に直す
17. （実装で分かったこと）`BacklogCounts` を VDPipeline（`StatusReport.swift`）の public に移した（§4.9）。§12 の `AppSnapshot.swift` の行から `BacklogCounts` を外し、§11 の `StatusReport.swift` の行に足す
18. （実装で分かったこと）`AppServices`（VoiceDockApp の internal）に `openSystemSettingsPrivacyFilesAndFolders()` を足した（§4.10）
19. （実装で分かったこと）`WorkerDependencies.verificationCache`（地図 §11 の並び）は本チケットでは要らない。診断は `DiagnosticsDependencies.verificationCache` に Bootstrap の同じインスタンス（ModelManager と共有）を渡し、DR-09 はガードと同じくサイズでしか在否を見ない。足すのは Worker 側で SHA を見るチケットが出たとき
20. （レビューで分かったこと）DR-02 は「DB がこのアプリより新しい版で作られた」（適用済みに知らない識別子が在る）を区別できない（GRDB の `appliedMigrations` は登録済みの識別子しか返さない）。`Store` の `hasBeenSuperseded` 相当を `ReadOnlyStore` に足し、専用の文言を出したい（本チケットは公開 API を足さない）
21. （レビューで分かったこと・CR-06）同じ文言が 2 か所に在る: `DiagnosticTexts.tccFolders` と `AttentionTexts.tccFolders`、`DiagnosticTexts.tccRemovableVolumes` と `AttentionTexts` の `deviceNotListable` の説明、`DiagnosticTexts.notEnoughMemory` と `Strings.notEnoughMemory`、`DiagnosticTexts.customModelUnsupported` と `Strings.customModelUnsupported`。VDPipeline の `StatusTexts` に寄せて両方から参照したい（本チケットではコードを変えない）

## 11. 仕様の問題（PLAN に直したいこと）

1. **DR-15 の検査と「状態の詳細」の inbox の行が同じ集合を使うことが §8.11 / §8.12 に明記されていない**（voicedock は `status.py:287-307` で「判定が 2 本に分かれると片方だけ直す」事故を書いている）。本チケットは `InboxScan` に一本化した。PLAN に 1 行足したい
2. **要対応の表に whisper-cli / llama-server が無い**。`PauseReason` には `whisper_missing` / `llama_server_missing` が在り、これらが立つと処理が完全に止まるのに、パネルに何も出ない。本チケットは `toolMissing(ToolKind)` を足した（操作ボタンは無し、説明は「アプリが壊れています。入れ直してください」）。**PLAN §8.11 の表に 1 行足したい**
3. **DR-08 の「custom は notice」の意味が曖昧**。custom はメモリの上限が不明なのでメモリの確認ができず、「notice を出す」場面が無い。本チケットは「custom は `.ok` にし、details の 2 行目に `動作保証外のモデルです` を出す」とした。PLAN の文を直したい
4. **`configInvalid` と `lockMismatch` が同時に出る**。CV-30 / CV-33 の違反は設定エラー状態（§6.1）も引き起こすので、要対応に 2 件並ぶ。本チケットはそのまま 2 件出す（どちらも利用者が知るべき事実で、直し方が違う）。PLAN §8.11 に注記したい
5. **§8.12 の 2 の例に「再試行」= `requeue(.manual)` とあるが、§8.11 の要対応の表には「再試行」を持つ項目が無い**（FAILED は要対応にしない、と同じ節が書いている）。本チケットは「再試行」を「詳細」の節（FAILED の一覧の下）に置いた。PLAN §8.12 の 2 の例から「再試行」を外すか、置き場所を 8 に直したい
6. **DR-03 の「`expected(1800 秒) × 2.0 + 2 GiB`」が設定値（`freeSpaceMultiplier` / `freeSpaceMarginBytes`）の既定値を書き写している**。本チケットは `SpaceCheck`（設定値を使う）を呼ぶことにした。PLAN の式を「§8.3 の `SpaceCheck` を duration 1800 秒で呼ぶ」に直したい
7. **DR-09 の「結果「<model>（<秒 小数 1 桁>s）」」の `<model>` がカタログの `id` か `displayName` か決まっていない**。本チケットは `llm.modelID`（custom も含めてそのまま出る）にした
8. **OPS-14「1 バイトも変わらない」は `voicedock.sqlite-shm` の mtime について守れない**。WAL の共有メモリの索引は、読み取り専用の接続でも読み手の印（read mark）を書く（SQLite の仕組み。データではない）。テストは `voicedock.sqlite-shm`（完全一致）だけ在否とサイズで比べる。PLAN の OPS-14 に注記したい
